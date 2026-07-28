---
name: gateway-agent-sdk
description: >
  Use this skill when building a new ADK agent, migrating an existing agent.py,
  or debugging missing telemetry / model-not-found / silent-response errors in
  an Agent Gateway deployment. The skill installs the GatewayAgent SDK — a thin
  wrapper over the ADK Agent class that automatically enforces: (1) regional
  Vertex AI endpoint routing compatible with PSC egress, (2) OTEL token telemetry
  wired via after_model_callback, (3) async_stream_query() for RE inference, and
  (4) get_project_id patch for Org Policy compliance.
  After applying this skill, an agent's agent.py is reduced to pure business
  logic — no boilerplate, no silent compliance gaps.
---

# GatewayAgent SDK Skill

> [!IMPORTANT]
> This skill creates the `lib/gateway_agent/` package and rewrites `agent.py`
> to use `GatewayAgent`. Run it against **any** agent that is deployed through
> the `mod-agw-foundation` pipeline. It is idempotent — safe to re-run.

> [!CAUTION]
> **Read the Tribal Knowledge section before touching GlobalGemini, callbacks,
> or OTEL.** This skill encodes hard-won fixes from a full day of debugging.
> Each section explains WHY, not just WHAT.

---

## When to Use This Skill

- Building a **new agent** from scratch inside the Agent Gateway environment
- **Migrating** an existing `agent.py` that uses bare `Agent()` + inline boilerplate
- The observability dashboard shows **zero token usage** (telemetry not wired)
- Agent returns **0 events** on `stream_query` / `async_stream_query` calls
- `:query` REST endpoint returns **`Default method not found`**
- Agent works for the **first query only**, then goes silent (OTEL thread crash)

---

## What This Skill Does

1. Creates `lib/gateway_agent/` with the full SDK package
2. Rewrites `agent.py` to use `GatewayAgent` — removing all boilerplate
3. Adds `GOOGLE_API_USE_MTLS_ENDPOINT=never` to `agent/.env` (OTEL crash fix)
4. Adds the pre-deploy compliance check to `scripts/deploy_chat_agent.sh`
5. Verifies the wiring by running a local import check

---

## ADK Version Compatibility

| ADK Version | `after_model_callback` signature | Streaming method | Notes |
|---|---|---|---|
| < 1.31 | `callback(ctx, response)` positional | `stream_query` | Legacy |
| 1.31.x | `callback(callback_context=, llm_response=)` keyword | `stream_query` | **Breaking change in callback** |
| 1.35.x+ | `callback(callback_context=, llm_response=)` keyword | `async_stream_query` | `stream_query` deprecated |

Always verify installed version: `pip show google-adk | grep Version`

---

## Step 1 — Understand the Current State

Before making changes, read the target agent:

```bash
pip show google-adk | grep Version     # confirm ADK version
cat agent/agent.py
ls agent/
cat agent/requirements.txt 2>/dev/null || cat agent/pyproject.toml
cat agent/.env
```

Identify:
- [ ] ADK version — determines callback signature and which streaming method to use
- [ ] Is `GlobalGemini` defined inline or imported?
- [ ] Is `after_model_callback` wired? (if not → telemetry is silent)
- [ ] Does `_chained_callback` use `callback_context=` / `llm_response=` kwargs? (ADK 1.31+)
- [ ] Is `get_project_id` patched? (needed for Org Policy bypass)
- [ ] Is `GOOGLE_API_USE_MTLS_ENDPOINT=never` in `agent/.env`? (OTEL crash fix)
- [ ] Is there already a `lib/` or `gateway_agent/` directory?

---

## Step 2 — Create the SDK Package

Create the following structure inside the agent's workspace root
(the directory that contains `agent/`, not inside `agent/` itself):

```
lib/
└── gateway_agent/
    ├── __init__.py
    ├── agent.py          ← GatewayAgent class
    ├── global_gemini.py  ← GlobalGemini (PSC-compatible regional endpoint)
    └── telemetry.py      ← emit_llm_usage_from_response callback
```

### `lib/gateway_agent/__init__.py`

```python
"""GatewayAgent SDK — Agent Gateway compliance wrapper for ADK agents.

Exports:
    GatewayAgent: Drop-in replacement for ADK Agent that enforces:
        - Regional Vertex AI endpoint routing compatible with PSC egress
        - OTEL token telemetry via after_model_callback
        - get_project_id monkey-patch for Org Policy bypass
"""

from .agent import GatewayAgent
from .global_gemini import GlobalGemini
from .telemetry import emit_llm_usage_from_response

__all__ = ["GatewayAgent", "GlobalGemini", "emit_llm_usage_from_response"]
```

### `lib/gateway_agent/global_gemini.py`

```python
"""GlobalGemini: PSC-compatible Gemini wrapper for Agent Gateway deployments.

⚠️  CRITICAL — READ BEFORE MODIFYING ⚠️

WHAT THIS IS:
    A pass-through subclass of Gemini that makes NO changes to the endpoint.
    The ADK Gemini class uses GOOGLE_CLOUD_LOCATION to derive the regional
    endpoint (e.g. us-east1-aiplatform.googleapis.com). This is CORRECT for
    Agent Gateway deployments.

WHY IT IS A PASS-THROUGH (not a global-endpoint override):
    The Agent Gateway egress PSC is a REGIONAL construct. It only routes
    traffic to the regional Vertex AI endpoint:
        ✅  us-east1-aiplatform.googleapis.com  (PSC-routed)
        ❌  aiplatform.googleapis.com            (global endpoint, NOT PSC-routed)

    Attempts to use `Client(location="global")` will succeed at the API layer
    but the PSC will silently drop the connection, returning HTTP 200 with 0
    streaming events and no error message.

WHY THE OLD SKILL HAD _get_client_args():
    In ADK < 1.30, `_get_client_args()` was used to configure the API client.
    In ADK 1.31+, this method is DEAD CODE — it is never called. The correct
    extension point is the `api_client` property, but overriding it to use
    `location="global"` breaks PSC routing (see above).

WHEN TO RE-ENABLE GLOBAL ENDPOINT:
    Only if all of the following are true:
    1. The specific Gemini model returns 404 at the regional endpoint
    2. The PSC egress has been extended to also route aiplatform.googleapis.com
       (the global endpoint, no region prefix)
    3. The gateway team has confirmed the global routing is supported
"""

from google.adk.models.google_llm import Gemini


class GlobalGemini(Gemini):
    """Drop-in replacement for Gemini() — uses regional endpoint via PSC.

    Keep this as a named class (not just use Gemini directly) so:
    1. The compliance check can detect it in agent.py imports
    2. Future global-endpoint support can be added here without touching agent.py
    3. The deploy script's compliance gate recognises the SDK is in use

    Usage:
        from gateway_agent import GlobalGemini
        model = GlobalGemini(model="gemini-2.5-flash")
        # Note: always use keyword arg 'model=' — Pydantic v2 rejects positional
    """
    pass
```

### `lib/gateway_agent/telemetry.py`

```python
"""Telemetry utilities for the Agent Gateway.

Provides the after_model_callback that emits structured JSON token usage events.
These events are consumed by the log-based metrics in the Agent Observability
dashboard (modules/agent_observability) to power token usage widgets and alerts.

WITHOUT this callback, the dashboard shows zero usage for the entire agent lifetime.
This callback uses Python's standard logging module — it does NOT depend on OTEL.
Even if OTEL is disabled or broken, this callback continues to work.
"""

import json
import logging
from typing import Optional

from google.adk.agents.callback_context import CallbackContext
from google.adk.models.llm_response import LlmResponse

logger = logging.getLogger(__name__)


def emit_llm_usage_from_response(
    callback_context: CallbackContext,
    llm_response: LlmResponse,
) -> Optional[LlmResponse]:
    """ADK after_model_callback that emits a structured JSON usage event.

    ⚠️  PARAMETER NAMES ARE NOT OPTIONAL (ADK 1.31+ breaking change):
    ADK 1.31+ calls this as: callback(callback_context=..., llm_response=...)
    Using positional names like (ctx, response) causes TypeError and silently
    drops ALL agent responses — the model runs but output is never delivered.

    Attach to any ADK Agent as after_model_callback=emit_llm_usage_from_response
    (or use GatewayAgent which wires this automatically).

    Emits a structured log line consumed by the Agent Gateway Observability
    dashboard log-based metrics:
        {"event": "llm_usage", "agent": "...", "model": "...",
         "input_tokens": 100, "output_tokens": 50, "total_tokens": 150}

    Returns:
        None — does not modify the LLM response.
    """
    try:
        usage = llm_response.usage_metadata
        if usage is None:
            return None

        event = {
            "event":         "llm_usage",
            "agent":         callback_context.agent_name,
            "model":         getattr(llm_response, "model_version", "unknown"),
            "input_tokens":  getattr(usage, "prompt_token_count",     0),
            "output_tokens": getattr(usage, "candidates_token_count", 0),
            "total_tokens":  getattr(usage, "total_token_count",      0),
        }
        logger.info(json.dumps(event))
    except Exception as exc:
        logger.warning("emit_llm_usage_from_response failed: %s", exc)

    return None
```

### `lib/gateway_agent/agent.py`

```python
"""GatewayAgent: Compliance-enforcing wrapper for ADK Agent.

Automatically wires:
  1. GlobalGemini — uses regional endpoint compatible with Agent Gateway PSC egress.
     DO NOT change to global endpoint without also extending the PSC.

  2. emit_llm_usage_from_response — after_model_callback for token telemetry.
     Without this, the Agent Gateway Observability dashboard shows zero token
     usage for the entire agent lifetime.

  3. get_project_id monkey-patch — prevents gRPC project-number lookups that
     route through the egress proxy (which has no PSC route to the IAM API).
     Reads GCP_PROJECT_ID / GOOGLE_CLOUD_PROJECT from the environment instead.

⚠️  ADK 1.31+ CALLBACK SIGNATURE CHANGE:
  ADK 1.31+ calls after_model_callback with KEYWORD args:
      callback(callback_context=ctx, llm_response=response)
  Using positional names (ctx, response) causes TypeError that silently drops
  ALL agent responses. The parameter names in _chained_callback MUST match.

Usage:
    from gateway_agent import GatewayAgent

    root_agent = GatewayAgent(
        name="my_agent",
        model="gemini-2.5-flash",   # pass model name as string — GlobalGemini applied
        description="...",
        instruction="...",
        tools=[...],
    )
"""

import os
from typing import Optional, Callable

from google.adk.agents import Agent
from google.adk.agents.callback_context import CallbackContext
from google.adk.models.llm_response import LlmResponse

from .global_gemini import GlobalGemini
from .telemetry import emit_llm_usage_from_response

# ---------------------------------------------------------------------------
# Org Policy bypass: prevent gRPC project-number → project-ID lookups.
# The egress proxy has no PSC route to the IAM API — unpatched, these calls
# time out and crash the agent on startup.
# ---------------------------------------------------------------------------
try:
    from google.cloud.aiplatform.utils import resource_manager_utils

    def _patched_get_project_id(project_number: str) -> str:
        return (
            os.environ.get("GCP_PROJECT_ID")
            or os.environ.get("GOOGLE_CLOUD_PROJECT")
            or ""
        )

    resource_manager_utils.get_project_id = _patched_get_project_id
except Exception:
    pass


class GatewayAgent(Agent):
    """Drop-in replacement for ADK Agent that enforces Agent Gateway compliance.

    Developers pass model as a plain string — GatewayAgent wraps it with
    GlobalGemini automatically. The after_model_callback chain always includes
    emit_llm_usage_from_response; developers may add their own callback on top.

    Example:
        root_agent = GatewayAgent(
            name="chat_agent",
            model="gemini-2.5-flash",
            description="A helpful assistant.",
            instruction="You are a helpful assistant.",
            tools=[fetch_url],
        )
    """

    def __init__(
        self,
        *,
        model: str,
        after_model_callback: Optional[Callable] = None,
        **kwargs,
    ):
        # 1. Use regional endpoint routing via GlobalGemini pass-through.
        #    ⚠️  Always use keyword arg 'model=' — Pydantic v2 rejects positional args.
        gateway_model = GlobalGemini(model=model)

        # 2. Chain the telemetry callback — developer cannot forget it.
        #    ⚠️  Parameter names MUST be callback_context and llm_response.
        #    ADK 1.31+ calls: callback(callback_context=..., llm_response=...)
        #    Wrong names (e.g. ctx, response) → TypeError → ALL responses silently dropped.
        def _chained_callback(
            callback_context: CallbackContext, llm_response: LlmResponse
        ) -> Optional[LlmResponse]:
            emit_llm_usage_from_response(callback_context, llm_response)
            if after_model_callback is not None:
                return after_model_callback(
                    callback_context=callback_context, llm_response=llm_response
                )
            return None

        super().__init__(
            model=gateway_model,
            after_model_callback=_chained_callback,
            **kwargs,
        )
```

---

## Step 3 — Add `GOOGLE_API_USE_MTLS_ENDPOINT=never` to the Deploy Script

> [!CAUTION]
> **Do NOT add this to `agent/.env` directly.** The deploy script (`deploy_chat_agent.sh`)
> **overwrites `agent/.env` on every run** via a heredoc. Edits to `agent/.env` are silently
> discarded at deploy time. The fix must live inside the deploy script's heredoc block.

Find the `cat > agent/.env << 'ENVEOF'` block in `scripts/deploy_chat_agent.sh` and add:

```bash
cat > agent/.env << 'ENVEOF'
GCP_PROJECT_ID=...
GOOGLE_CLOUD_LOCATION=...
AGENT_GATEWAY_INGRESS=...
AGENT_GATEWAY_EGRESS=...
# OTEL FIX: RE containers have mTLS certs provisioned, causing mtls.should_use_client_cert()
# to return True. This makes OTEL BatchSpanProcessor call configure_mtls_channel(),
# creating an SSL context that crashes (ValueError: Context already used) on second
# flush — killing Thread-2 and silencing all queries after the first.
# "never" forces standard TLS on telemetry.googleapis.com. See KNOWN_ISSUES.md #007.
GOOGLE_API_USE_MTLS_ENDPOINT=never
ENVEOF
```

**Why this happens (detailed):**

ADK's `google_cloud.py` exporter checks `mtls.should_use_client_cert()`. Inside
---

## Step 4 — Add `telemetry.googleapis.com` to PSC Egress Allowlist

Add to `variables.tf` in the `allowed_egress_hosts` default list:

```hcl
"telemetry.googleapis.com"
```

**Why:** The ADK OTEL exporter sends traces to `https://telemetry.googleapis.com/v1/traces`.
The Agent Gateway PSC egress only routes hosts in `allowed_egress_hosts`. Without
this entry, trace exports fail with a connection timeout — which, with the mTLS
fix above, is now a graceful failure (not a crash). But adding the host makes
traces actually appear in Cloud Trace.

After adding, run:
```bash
terraform apply -target=module.gateway_observability -auto-approve
# or if the host list feeds into the gateway resource:
terraform apply -auto-approve
```

---

## Step 5 — Rewrite `agent.py`

Replace the existing `agent.py` with the minimal business-logic-only version:

```python
"""Chat Agent — business logic only. All gateway compliance is in GatewayAgent SDK."""

import sys
import os

# Add lib/ to path so gateway_agent package is importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))

from gateway_agent import GatewayAgent
import requests


def fetch_url(url: str) -> str:
    """Fetch a URL through the Agent Gateway egress proxy."""
    proxies = {}
    if p := os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy"):
        proxies["https"] = p
    if p := os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy"):
        proxies["http"] = p

    try:
        r = requests.get(url, timeout=10, proxies=proxies or None)
        r.raise_for_status()
        return r.text
    except requests.exceptions.ConnectionError:
        return (
            f"[GATEWAY BLOCKED] Cannot reach '{url}'. "
            f"This host is not in the egress allowlist."
        )
    except requests.exceptions.Timeout:
        return f"[GATEWAY BLOCKED] Request to '{url}' timed out (PSC routing rejection)."
    except Exception as e:
        return f"[FETCH FAILED] Could not retrieve '{url}': {e}"


root_agent = GatewayAgent(
    name="chat_agent",
    model="gemini-2.5-flash",
    description="A helpful chat agent secured by the Agent Gateway.",
    instruction="You are a helpful assistant. Use the fetch_url tool to read web content when asked.",
    tools=[fetch_url],
)
```

---

## Step 6 — Add Pre-Deploy Compliance Check

Add to `scripts/deploy_chat_agent.sh` **before** the `adk deploy` call:

```bash
echo "Running GatewayAgent compliance check..."
if ! python3 - <<'PYEOF'
import ast, sys
try:
    tree = ast.parse(open("agent/agent.py").read())
except FileNotFoundError:
    print("  ❌ agent/agent.py not found"); sys.exit(1)
uses_gateway = any(
    (isinstance(n, ast.ImportFrom) and n.module and "gateway_agent" in n.module)
    or (isinstance(n, ast.Import) and any("gateway_agent" in a.name for a in n.names))
    for n in ast.walk(tree)
)
if not uses_gateway:
    print("  ❌ Gateway Compliance Error: agent.py must import GatewayAgent.")
    sys.exit(1)
print("  ✅ Compliance check passed — GatewayAgent SDK detected.")
PYEOF
then exit 1; fi
```

---

## Step 7 — Verify the Wiring

```bash
cd <workspace_root>   # directory containing both agent/ and lib/
GOOGLE_CLOUD_PROJECT=YOUR_PROJECT_ID \
  python3 -c "
import sys; sys.path.insert(0, 'lib')
from gateway_agent import GatewayAgent, GlobalGemini, emit_llm_usage_from_response
print('✅ gateway_agent SDK imports OK')
print('  GatewayAgent:', GatewayAgent)
print('  GlobalGemini:', GlobalGemini)
print('  Telemetry callback:', emit_llm_usage_from_response)
"
```

Expected output:
```
✅ gateway_agent SDK imports OK
  GatewayAgent: <class 'gateway_agent.agent.GatewayAgent'>
  GlobalGemini: <class 'gateway_agent.global_gemini.GlobalGemini'>
  Telemetry callback: <function emit_llm_usage_from_response at 0x...>
```

---

## Step 8 — Calling the Agent (Client Side)

### ADK 1.35+ (current)

```python
import vertexai
from vertexai import agent_engines

vertexai.init(project="YOUR_PROJECT_ID", location="YOUR_REGION")
re = agent_engines.get("projects/.../reasoningEngines/<ID>")

# Create session
sess = re.create_session(user_id="my-user")     # deprecated in 1.35 but still works
# OR: sess = re.async_create_session(user_id="my-user")
sid = sess.get("id") or sess.get("session_id")

# Run inference — use async_stream_query (stream_query is deprecated in 1.35+)
for event in re.stream_query(message="Hello", user_id="my-user", session_id=sid):
    for part in event.get("content", {}).get("parts", []):
        print(part.get("text", ""), end="")
```

> [!IMPORTANT]
> Use **one fresh session per user conversation**. Each session stores turn history.
> Do NOT create a new session for every message in the same conversation — that
> loses context. Do NOT reuse sessions across different users.

### What Happened to `:query` (Synchronous Endpoint)

In ADK 1.31–1.35, there is **no synchronous inference endpoint**. The `:query`
REST endpoint only handles session management methods (`create_session`, etc.).
All inference must go through `:streamQuery` / `stream_query` / `async_stream_query`.

The `query` field you see in `_AGENT_ENGINE_CLASS_METHODS` belongs to
`async_search_memory` (memory search) — it is NOT an inference endpoint.

---

## Architecture Reference

```
agent/
├── agent.py          ← ONLY business logic (tools, instructions)
│                        imports GatewayAgent from lib/
└── .env              ← Includes GOOGLE_API_USE_MTLS_ENDPOINT=never

lib/
└── gateway_agent/
    ├── __init__.py   ← exports GatewayAgent, GlobalGemini, telemetry
    ├── agent.py      ← GatewayAgent class (all compliance enforcement)
    ├── global_gemini.py  ← pass-through Gemini (PSC-compatible)
    └── telemetry.py  ← OTEL token usage callback (uses Python logging)

scripts/
└── deploy_chat_agent.sh  ← compliance gate before adk deploy

mod-agw-foundation/variables.tf  ← allowed_egress_hosts includes telemetry.googleapis.com
```

### What GatewayAgent Enforces

| Enforcement | Bare Agent | GatewayAgent |
|---|---|---|
| PSC-compatible regional routing | Manual — easily broken | ✅ Always enforced |
| OTEL token telemetry | Manual — currently MISSING | ✅ Always wired |
| Correct callback kwarg names (ADK 1.31+) | Must know the change | ✅ In SDK |
| Org Policy `get_project_id` patch | Manual in agent.py | ✅ In SDK `__init__` |
| Compliance gate at deploy | None | ✅ Fails build |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ModuleNotFoundError: gateway_agent` | `lib/` not on `sys.path` | Add `sys.path.insert(0, "../lib")` in `agent.py` |
| RE startup fails: `BaseModel.__init__() takes 1 positional argument` | `GlobalGemini(model_string)` positional arg | Use `GlobalGemini(model=model_string)` — Pydantic v2 requires keywords |
| All queries return 0 events, no error | `after_model_callback` TypeError | Check param names: must be `callback_context` and `llm_response`, not `ctx`/`response` |
| First query works, all others return 0 events | OTEL mTLS SSL context crash in Thread-2 | Add `GOOGLE_API_USE_MTLS_ENDPOINT=never` to deploy `.env` heredoc |
| Q2+ all fail immediately (1-2s), logs show `RuntimeError: Event loop is closed` from `asyncio/base_events.py:545` | `google.genai` aiohttp `AsyncAuthorizedSession` singleton bound to Q1's event loop | Add `GOOGLE_API_USE_CLIENT_CERTIFICATE=false` to deploy `.env` heredoc |
| Q2/Q4 fail, Q1/Q3/Q5 pass (alternating pattern) | OTEL BatchSpanProcessor blocking 10-15s on TCP SYN to `telemetry.googleapis.com` (PSC drop) | Add `OTEL_EXPORTER_OTLP_TIMEOUT=2000`, `OTEL_BSP_EXPORT_TIMEOUT_MILLIS=2000`, `OTEL_BSP_SCHEDULE_DELAY_MILLIS=15000` |
| Traces not appearing in Cloud Trace | `telemetry.googleapis.com` not in PSC egress allowlist | Add to `allowed_egress_hosts` in `variables.tf` |
| Token usage still zero in dashboard | `after_model_callback` overridden downstream | Pass your callback as `after_model_callback=` arg — GatewayAgent chains it |
| 0 events and logs show `ValueError: Context has already been used` | OTEL mTLS crash (see above) | `GOOGLE_API_USE_MTLS_ENDPOINT=never` |
| Model returns 404 at regional endpoint | Model not yet available regionally | Check Vertex AI model availability table; do NOT blindly add `location="global"` to GlobalGemini — extend PSC first |
| `_get_client_args` override has no effect | Dead code in ADK 1.31+ | Override `api_client` property instead; but read PSC warning above |

---

## Tribal Knowledge — Hard-Won Lessons

> [!WARNING]
> **Read this before debugging any Agent Gateway issue.** This section encodes
> a full day of troubleshooting. Each entry is a real bug that took hours to find.

### 1. `_get_client_args()` is dead code in ADK 1.31+
The original skill overrode `_get_client_args()` to set `location="global"`.
In ADK 1.31+, this method is never called. The override had zero effect.
The real extension point is the `api_client` property — but see #2.

### 2. `location="global"` breaks PSC routing
The Agent Gateway egress PSC routes `*.us-east1-aiplatform.googleapis.com`.
It does NOT route `aiplatform.googleapis.com` (global). Using
`Client(vertexai=True, location="global")` causes the PSC to silently drop
connections. The agent appears to run (HTTP 200 returned) but produces 0 events.
There is no error message. This is the hardest bug to diagnose.

### 3. ADK 1.31+ callback signature changed from positional to keyword
**Old (broken):** `def callback(ctx, response):`
**New (correct):** `def callback(callback_context, llm_response):`
ADK calls `callback(callback_context=..., llm_response=...)`. Wrong parameter names
cause `TypeError` that is silently caught inside ADK's event loop — the model
runs successfully but all output is discarded. Cloud Logging shows the error buried
after "Response received from the model."

### 4. Pydantic v2: always use keyword args with Gemini subclasses
`GlobalGemini(model_name)` → `TypeError: BaseModel.__init__() takes 1 positional argument`
`GlobalGemini(model=model_name)` → works correctly
`BaseLlm` (parent of `Gemini`) is a Pydantic v2 `BaseModel`. All fields must be
passed as keyword arguments.

### 5. Three-Layer OTEL / genai SDK crash — all queries fail after Q1
RE containers have a unique environment that triggers THREE independent failures.
All three fixes must be in the `.env` heredoc in `deploy_chat_agent.sh`:

**Layer 1 — OTEL mTLS SSL crash (symptom: Q1 passes, Q2+ silent):**
`ValueError: Context has already been used to create a Connection` in Cloud Logging.
OTEL BatchSpanProcessor calls `configure_mtls_channel()`, corrupting the pyopenssl
SSL context on the second flush. Fix: `GOOGLE_API_USE_MTLS_ENDPOINT=never`.

**Layer 2 — OTEL TCP block (symptom: alternating Q1/Q3 pass, Q2/Q4 fail):**
`telemetry.googleapis.com` is not in the Agent Gateway PSC egress routing table.
OTEL export blocks for the OS TCP SYN timeout (~10-15s), starving query threads.
Fix: `OTEL_EXPORTER_OTLP_TIMEOUT=2000` + `OTEL_BSP_EXPORT_TIMEOUT_MILLIS=2000` +
`OTEL_BSP_SCHEDULE_DELAY_MILLIS=15000`.

**Layer 3 — google.genai aiohttp singleton (symptom: Q1 passes, Q2+ fail in 1-2s):**
`google.genai._api_client._use_google_auth_async()` returns `True` in RE containers
(has aiohttp + vertexai + mTLS certs). `_get_aiohttp_session()` creates an
`AsyncAuthorizedSession` **once**, binding it to Q1's asyncio event loop. After Q1's
`asyncio.run()` closes that loop, Q2's thread creates a new loop — but the session's
`_loop` is still the old closed one. The very first `_check_closed()` call raises
`RuntimeError: Event loop is closed`. All Q2+ fail immediately.
Fix: `GOOGLE_API_USE_CLIENT_CERTIFICATE=false` — makes `should_use_client_cert()`
return False, disabling the aiohttp path, using httpx (no singleton, no loop binding).

> [!IMPORTANT]
> `GOOGLE_API_USE_MTLS_ENDPOINT=never` does NOT fix Layer 3 — it only changes the
> endpoint URL. `GOOGLE_API_USE_CLIENT_CERTIFICATE=false` disables the cert detection.
> Both env vars are required and serve different purposes.

### 6. Model Armor `response_template_id` is incompatible with RE streaming
The `pi_and_jailbreak` filter flags gRPC-HTTP transcoded SSE frames as prompt injection.
Use `request_template_id` only on the authz extension. Never set `response_template_id`
to a template with PI/Jailbreak enabled — it will block every response.
Org floor policies prevent disabling PI/Jailbreak on existing templates — create
a separate response template without PI/Jailbreak, or remove `response_template_id`.

### 7. `:query` is not an inference endpoint
In ADK 1.31–1.35, `:query` only serves session management methods.
All inference goes through `:streamQuery` → `stream_query` (deprecated 1.35) →
`async_stream_query` (current). There is no synchronous inference endpoint.

### 8. The RE state stays UNKNOWN during deploy — this is normal
The `deploy_chat_agent.sh` script waits 150s for the RE to reach ACTIVE state.
It will always time out and report UNKNOWN — this is a platform state reporting lag,
not an error. The RE is actually running. Wait 3-5 minutes after the script completes
before running E2E tests.

### 9. `deploy_chat_agent.sh` overwrites `agent/.env` on every run
The deploy script has a `cat > agent/.env << 'ENVEOF' ... ENVEOF` heredoc block
that regenerates the entire `.env` file on every deploy. Any manual edits to
`agent/.env` are silently discarded. Environment variables that must persist across
deploys must be added inside this heredoc block in the deploy script — NOT in
`agent/.env` directly. The mandatory OTEL env vars are:
```
GOOGLE_API_USE_MTLS_ENDPOINT=never          # Layer 1: OTEL SSL crash fix
OTEL_EXPORTER_OTLP_TIMEOUT=2000             # Layer 2: TCP block timeout fix
OTEL_BSP_EXPORT_TIMEOUT_MILLIS=2000         # Layer 2
OTEL_BSP_SCHEDULE_DELAY_MILLIS=15000        # Layer 2
GOOGLE_API_USE_CLIENT_CERTIFICATE=false     # Layer 3: aiohttp singleton fix
```

### 10. `GOOGLE_API_USE_MTLS_ENDPOINT` vs `GOOGLE_API_USE_CLIENT_CERTIFICATE`
These are two different env vars that look similar but control different things:
- `GOOGLE_API_USE_MTLS_ENDPOINT=never` — controls which **URL** the SDK uses for
  the Vertex AI API endpoint. It does NOT affect `mtls.should_use_client_cert()`.
- `GOOGLE_API_USE_CLIENT_CERTIFICATE=false` — tells `google-auth` to NOT use client
  certificates. This makes `mtls.should_use_client_cert()` return `False`, which
  causes `google.genai` to use `httpx` instead of `aiohttp.AsyncAuthorizedSession`.

Both are needed. Layer 1 fix (mTLS SSL crash) needs `GOOGLE_API_USE_MTLS_ENDPOINT=never`.
Layer 3 fix (aiohttp singleton) needs `GOOGLE_API_USE_CLIENT_CERTIFICATE=false`.
