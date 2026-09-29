# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This code is for PoC environment only.
# This demo code is not built for production workload.

"""orchestrator/agent.py — Store Concierge Orchestrator Agent.

Phase 2: Dynamic Agent Discovery via AgentRegistry + SDK gRPC Data Plane.

  The orchestrator has ZERO hardcoded knowledge of which specialists exist
  or where they live. At routing time it:
    1. Calls AgentRegistry.find(capability) → queries Vertex AI RE list API
       filtered by labels.capability=<X> AND labels.role=specialist
    2. Gets the specialist RE resource name back
    3. Calls the specialist via SDK gRPC (ReasoningEngineExecutionServiceClient)
       → stream_query_reasoning_engine → through Egress Gateway

  Adding a new specialist (zero-touch):
    1. Deploy the specialist RE
    2. Label it: capability=<X>, role=specialist
    3. Orchestrator discovers it automatically — NO orchestrator redeployment.

Architecture:
  User → Ingress Gateway → [Store Concierge RE]
                               │ AgentRegistry.find("pizza-ordering")
                               │   → GET /reasoningEngines → filter labels
                               │
                               ├─→ SDK gRPC → [Pizza Specialist RE]
                               ├─→ SDK gRPC → [Burger Specialist RE]
                               └─→ SDK gRPC → [Sushi Specialist RE]

Data Plane: SDK gRPC (ReasoningEngineExecutionServiceClient)
  WHY: Handles auth through gateway patch automatically. More reliable than
  raw HTTP POST behind egress gateways that require mTLS certificate validation.
  The SDK client is patched by _gateway_patch.py at RE container startup.
"""

import json
import logging
import os
import time
import uuid

from google import genai
from google.adk.agents import Agent

try:
    from google.adk.models import Gemini as _GeminiBase
except ImportError:
    _GeminiBase = None

logger = logging.getLogger(__name__)

# NOTE: Do NOT read PROJECT/REGION at module level — env_vars are applied by
# AdkApp.set_up() AFTER the pkl is loaded. Read lazily inside functions instead.
PROJECT = os.environ.get("GCP_PROJECT_ID", os.environ.get("GOOGLE_CLOUD_PROJECT", ""))
REGION = os.environ.get("GCP_REGION", "us-east1")

# ---------------------------------------------------------------------------
# GlobalGemini: routes gemini-3.5-flash through Vertex AI global endpoint.
# Regional us-east1 endpoint returns 404 for Gemini 3.x models.
# ---------------------------------------------------------------------------
if _GeminiBase is not None:
    class GlobalGemini(_GeminiBase):
        @property
        def api_client(self):
            project = (
                os.environ.get("GCP_PROJECT_ID")
                or os.environ.get("GOOGLE_CLOUD_PROJECT")
            )
            return genai.Client(vertexai=True, project=project, location="global")
else:
    GlobalGemini = None

_MODEL = GlobalGemini(model="gemini-3.5-flash") if GlobalGemini else "gemini-3.5-flash"

# ---------------------------------------------------------------------------
# Org Policy patch: prevent gRPC project-number → project-ID lookups.
# ADK's adk.py set_up() calls project_id() → get_project_id(project) where
# project is None (vertexai not initialized in RE container at startup).
# This causes AttributeError: 'NoneType' has no attribute 'project_id'.
# ---------------------------------------------------------------------------
try:
    from google.cloud.aiplatform.utils import resource_manager_utils as _rmutils
    _orig_get_project_id = _rmutils.get_project_id

    def _patched_get_project_id(project):
        if project is not None:
            try:
                return _orig_get_project_id(project)
            except Exception:
                pass
        return (
            os.environ.get("GCP_PROJECT_ID")
            or os.environ.get("GOOGLE_CLOUD_PROJECT")
            or ""
        )

    _rmutils.get_project_id = _patched_get_project_id
except Exception:
    pass



# ---------------------------------------------------------------------------
# food_court_backend — bundled by deploy_a2a_agents.sh alongside gateway_agent.
# Provides wait times (get_wait_times) and order history (get_order_history).
# Orchestrator is the only agent with cross-cuisine history access.
# ---------------------------------------------------------------------------
try:
    from food_court_backend import (
        get_wait_times as _get_wait_times,
        get_order_history as _get_order_history,
        get_order_status as _get_order_status,
    )
    _BACKEND = True
except ImportError:
    _BACKEND = False
    logger.warning("food_court_backend not available — wait times and history disabled")


# ---------------------------------------------------------------------------
# AgentRegistry — wraps Vertex AI RE list API with 5-minute cache
# ---------------------------------------------------------------------------

class AgentRegistry:
    """Discovers specialist REs via Vertex AI RE list API + label filtering.

    Caches results for 5 minutes. First call: ~12-15s. Cached: ~1s.

    Specialists register themselves by having these labels on their RE:
      capability = <e.g. pizza-ordering>
      role       = specialist

    The orchestrator calls find() at routing time — zero hardcoded URLs.
    """

    _cache: dict = {}
    _cache_ttl: int = 300  # 5 minutes

    def __init__(self) -> None:
        # Lazy — read env at call time so env_vars from set_up() are visible
        pass

    @property
    def project(self) -> str:
        return os.environ.get("GCP_PROJECT_ID", os.environ.get("GOOGLE_CLOUD_PROJECT", ""))

    @property
    def region(self) -> str:
        return os.environ.get("GCP_REGION", "us-east1")

    def find(self, capability: str) -> dict | None:
        """Return RE info for the first RE with matching capability label.

        Resolution order:
          1. Env var SPECIALIST_{CAP_UPPER}_RE_NAME (no network call, fastest)
          2. In-memory cache (TTL 5 min)
          3. Vertex AI RE list API (urllib.request, stdlib only)

        Returns:
            dict with 'name' (full resource name) and 're_id', or None.
        """
        # --- Env-var override (no auth, no network, works inside container) ---
        env_key = "SPECIALIST_" + capability.upper().replace("-", "_") + "_RE_NAME"
        env_val = os.environ.get(env_key, "")
        if env_val:
            re_id = env_val.split("/")[-1]
            data = {"name": env_val, "re_id": re_id}
            logger.info("[registry] Env-var override: capability=%s → RE %s",
                       capability, re_id)
            return data

        now = time.time()
        cache_key = f"{self.project}/{self.region}/{capability}"

        if cache_key in self._cache:
            entry = self._cache[cache_key]
            if now - entry["ts"] < self._cache_ttl:
                logger.info("[registry] Cache hit: capability=%s → RE %s",
                           capability, entry["data"]["re_id"])
                return entry["data"]

        # Cache miss — query via SDK gRPC (patched by _gateway_patch, works in PSC VPC).
        # urllib.request is NOT patched and is blocked by PSC VPC egress controls.
        logger.info("[registry] Network lookup: capability=%s project=%s region=%s",
                    capability, self.project, self.region)
        try:
            from google.cloud.aiplatform_v1beta1 import ReasoningEngineServiceClient
            from google.cloud.aiplatform_v1beta1.types import ListReasoningEnginesRequest

            client = ReasoningEngineServiceClient(
                client_options={
                    "api_endpoint": f"{self.region}-aiplatform.googleapis.com"
                }
            )
            parent = f"projects/{self.project}/locations/{self.region}"
            engines = client.list_reasoning_engines(
                request=ListReasoningEnginesRequest(parent=parent)
            )
            re_list = list(engines)
        except Exception as exc:  # noqa: BLE001
            logger.error("[registry] RE list gRPC error: %s: %s", type(exc).__name__, exc)
            return None

        for re in re_list:
            labels = dict(re.labels)
            if (labels.get("capability") == capability
                    and labels.get("role") == "specialist"):
                re_name = re.name
                data = {"name": re_name, "re_id": re_name.split("/")[-1]}
                self._cache[cache_key] = {"data": data, "ts": now}
                logger.info("[registry] Discovered %s → RE %s",
                           capability, data["re_id"])
                return data

        logger.warning("[registry] No specialist for capability=%s", capability)
        return None


_registry = AgentRegistry()


# ---------------------------------------------------------------------------
# Routing — SDK gRPC data plane (stream_query_reasoning_engine)
# ---------------------------------------------------------------------------

def _route_to_specialist(capability: str, label: str, query: str) -> str:
    """Discover specialist by capability + call via SDK gRPC stream_query.

    Uses ReasoningEngineExecutionServiceClient.stream_query_reasoning_engine()
    which is the proven working data plane for google-adk(a2a) classified agents.

    IMPORTANT: class_method MUST be "stream_query" (not on_message_send).
    The google-adk(a2a) classification is metadata-only — the data plane
    is still stream_query. on_message_send returns 404 on all RE containers.

    The SDK client routes through the egress gateway automatically via the
    _gateway_patch.py that is active in the RE container environment.

    Args:
        capability: The capability label, e.g. "pizza-ordering".
        label: Human-readable label for logging, e.g. "pizza_agent".
        query: The user's request to forward to the specialist.

    Returns:
        The specialist's response text, or a graceful error string.
    """
    re_info = _registry.find(capability)
    if not re_info:
        return (
            f"I'm sorry, our {label.replace('_', ' ')} is currently unavailable. "
            f"No registered specialist found for capability '{capability}'."
        )

    resource_name = re_info["name"]
    region = os.environ.get("GCP_REGION", "us-east1")

    # Data plane: raw requests.Session with bearer token (NOT AuthorizedSession).
    # WHY NOT AuthorizedSession:
    #   _gateway_patch intercepts AuthorizedSession.send and routes through egress gateway.
    #   The egress gateway intermittently returns 403 for specific specialist REs (pizza: RE
    #   7834090716648177664 confirmed 403 in cloud logs). Burger and sushi pass because they
    #   were recently deployed and the gateway may have cached IAP tokens for them.
    # WHY NOT gRPC ReasoningEngineExecutionServiceClient:
    #   ReasoningEngineClientWithOverride patch routes all gRPC to egress gateway → 0 chunks.
    # SOLUTION: raw requests.Session.send() is not patched — goes directly to PSC aiplatform
    #   endpoint. Credentials are manually refreshed via google.auth.transport.requests.Request().
    try:
        import google.auth
        import google.auth.transport.requests
        import requests as _requests

        creds, _ = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        # Refresh via google.auth.transport.requests.Request (not AuthorizedSession —
        # that would be intercepted). This uses the metadata server directly.
        creds.refresh(google.auth.transport.requests.Request())

        url = (
            f"https://{region}-aiplatform.googleapis.com/v1beta1"
            f"/{resource_name}:streamQuery"
        )
        payload = {
            "input": {
                # Unique session ID per call — prevents ADK session memory
                # contamination when the orchestrator calls the same specialist
                # multiple times in one user turn (e.g. route + cross-cuisine).
                "user_id": f"orch-{uuid.uuid4().hex[:8]}",
                "message": query,
            },
            "classMethod": "stream_query",
        }
        # Use raw requests.Session (not AuthorizedSession) to bypass _gateway_patch
        raw_session = _requests.Session()
        resp = raw_session.post(
            url,
            headers={
                "Authorization": f"Bearer {creds.token}",
                "Content-Type": "application/json",
            },
            json=payload,
            stream=True,
            timeout=60,
        )
        resp.raise_for_status()

        texts = []
        diag = []
        chunk_count = 0
        for raw_line in resp.iter_lines():
            if not raw_line:
                continue
            chunk_count += 1
            try:
                # SSE lines: "data: {...}" or raw JSON
                line = raw_line.decode("utf-8") if isinstance(raw_line, bytes) else raw_line
                if line.startswith("data:"):
                    line = line[5:].strip()
                data = json.loads(line) if line else {}
                if isinstance(data, dict):
                    for part in data.get("content", {}).get("parts", []):
                        if isinstance(part, dict) and "text" in part:
                            texts.append(part["text"])
                        elif isinstance(part, dict) and "function_call" in part:
                            diag.append(f"chunk{chunk_count}:fn_call={part['function_call'].get('name','?')}")
            except (json.JSONDecodeError, AttributeError) as e:
                diag.append(f"chunk{chunk_count}:parse_err={type(e).__name__}:{str(e)[:60]}")
            except Exception as e:  # noqa: BLE001
                diag.append(f"chunk{chunk_count}:exc={type(e).__name__}:{str(e)[:60]}")

        result = "\n".join(texts).strip()
        if result:
            logger.info("[orch] %s: %d chunks → %d chars", label, chunk_count, len(result))
            return result
        diag_str = " | ".join(diag) if diag else "no_chunks"
        logger.warning("[orch] %s: no text in %d chunks. diag=%s", label, chunk_count, diag_str)
        return f"[DIAG chunks={chunk_count} {diag_str}] {label} returned no text."

    except Exception as e:  # noqa: BLE001
        logger.error("[orch] %s call failed: %s: %s | re=%s",
                     label, type(e).__name__, e, resource_name)
        return f"Error calling {label}: {type(e).__name__}: {e}"


# ---------------------------------------------------------------------------
# Tool functions — one thin wrapper per specialist capability
# Better LLM intent classification than a single generic discover_and_route.
# ---------------------------------------------------------------------------

def call_pizza_agent(user_query: str) -> str:
    """Call the Pizza Specialist for pizza orders, menu questions, and customization."""
    return _route_to_specialist("pizza-ordering", "pizza_agent", user_query)


def call_burger_agent(user_query: str) -> str:
    """Call the Burger Specialist for burger orders, menu browsing, and customization."""
    return _route_to_specialist("burger-ordering", "burger_agent", user_query)


def call_sushi_agent(user_query: str) -> str:
    """Call the Sushi Specialist for sushi orders, rolls, sashimi, and Japanese cuisine."""
    return _route_to_specialist("sushi-ordering", "sushi_agent", user_query)


# ---------------------------------------------------------------------------
# Tier 1: get_estimated_wait — live kitchen queue from Firestore
# ---------------------------------------------------------------------------

def get_estimated_wait() -> str:
    """Get current estimated kitchen wait times for all food stations in the food court.

    Returns:
        Formatted table of wait times per cuisine, refreshed every 5 minutes from Firestore.
        Falls back to static estimates if Firestore is unavailable.
    """
    if _BACKEND:
        return _get_wait_times()
    # Static fallback
    return (
        "⏱️  Estimated Kitchen Wait Times:\n"
        "  🍕 Pizza  : ~15–20 minutes\n"
        "  🍔 Burger : ~10–15 minutes\n"
        "  🍣 Sushi  : ~8–12 minutes\n\n"
        "  Wait times update every 5 minutes based on kitchen queue."
    )


# ---------------------------------------------------------------------------
# Tier 2: get_my_order_history — cross-cuisine order history from Firestore
# ---------------------------------------------------------------------------

def get_my_order_history(customer_id: str) -> str:
    """Look up a customer's complete order history across all cuisines (pizza, burger, sushi).

    This is a cross-cutting view — the orchestrator is the only agent with
    access to the full order history regardless of cuisine.

    Args:
        customer_id: Customer identifier string (e.g. "cust001", "john_doe").

    Returns:
        Formatted order history with timestamps, items, and loyalty points.
    """
    if _BACKEND:
        return _get_order_history(customer_id)
    return (
        "Order history is not available right now.\n"
        "Please provide your customer ID at the front desk for order tracking."
    )


# ---------------------------------------------------------------------------
# check_order_status — live status for a specific order
# ---------------------------------------------------------------------------

def check_order_status(order_id: str) -> str:
    """Check the live kitchen status of a specific order by Order ID.

    Args:
        order_id: The Order ID from the order confirmation (e.g. ORD-ABC12345).

    Returns:
        Current status: RECEIVED, PREPARING, ALMOST READY, or READY for pickup.
    """
    if _BACKEND:
        return _get_order_status(order_id)
    return (
        f"Order tracking unavailable offline.\n"
        f"Your order '{order_id}' was confirmed — please check with kitchen staff."
    )


# ---------------------------------------------------------------------------
# Root agent — pure LLM orchestrator, zero specialist-specific knowledge
# ---------------------------------------------------------------------------

root_agent = Agent(
    name=os.environ.get("AGENT_NAME", "store_concierge"),
    model=_MODEL,
    description=(
        "Store Concierge — dynamically discovers and routes to food specialist agents "
        "via the Agent Registry. Handles pizza, burger, and sushi orders."
    ),
    instruction="""You are the front desk concierge for a premium food court with three specialists: Pizza, Burger, and Sushi.

You do NOT handle food orders directly. You route to the right specialist.

ROUTING RULES:
- Pizza requests → call_pizza_agent(user_query)
- Burger requests → call_burger_agent(user_query)
- Sushi, Japanese food → call_sushi_agent(user_query)
- Pass the user's EXACT message as user_query — do not paraphrase.
- Wait time questions → get_estimated_wait()
- Order history / loyalty points → get_my_order_history(customer_id)
- Order status check → check_order_status(order_id)

MULTI-CUISINE ORDERS:
If the user asks for items from MORE THAN ONE cuisine in a single message,
call ALL relevant specialist tools in sequence, then combine their responses
into one cohesive reply. Examples:
  "I want pizza and sushi" → call call_pizza_agent() THEN call_sushi_agent()
  "Get me a burger and a California roll" → call call_burger_agent() THEN call_sushi_agent()

RULES:
- Do NOT output any intermediate text before the specialist responds.
- Only provide a final answer AFTER the specialist tool returns.
- For general questions (hours, what food types, location), answer directly.
- If a specialist is unavailable, apologize warmly and offer what help you can.

EXAMPLES:
  User: "I want a pepperoni pizza"
  → call_pizza_agent("I want a pepperoni pizza")

  User: "What burgers do you have?"
  → call_burger_agent("What burgers do you have?")

  User: "I'd like a salmon roll"
  → call_sushi_agent("I'd like a salmon roll")

  User: "I want pizza AND a cheeseburger"
  → call_pizza_agent("I want a pizza") then call_burger_agent("I want a cheeseburger")

  User: "How long is the wait for sushi?"
  → get_estimated_wait()

  User: "What did I order last time? My ID is cust001"
  → get_my_order_history("cust001")

  User: "What's the status of my order ORD-ABC123?"
  → check_order_status("ORD-ABC123")

You represent a premium food court — be warm, efficient, and helpful.
""",
    tools=[
        call_pizza_agent,
        call_burger_agent,
        call_sushi_agent,
        get_estimated_wait,
        get_my_order_history,
        check_order_status,
    ],
)
