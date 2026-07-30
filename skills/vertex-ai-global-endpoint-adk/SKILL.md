---
name: gateway-agent-sdk
description: >
  Use this skill when building a new ADK agent for deployment on the Agent Gateway
  (Vertex AI Reasoning Engine + PSC egress), migrating an existing agent.py, or
  debugging OTEL / model-not-found / event-loop-closed / silent-response errors.
  The skill documents the GatewayAgent SDK pattern — a thin ADK wrapper that
  automatically enforces regional endpoint routing, OTEL token telemetry, and
  :streamQuery compliance. It also captures the 3-layer OTEL fix required for all
  RE deployments (mTLS SSL corruption, PSC TCP block, aiohttp singleton event-loop crash).
---

# Agent Gateway SDK — Building & Deploying ADK Agents on Reasoning Engine

## Overview

All agents deployed on this platform run as **Vertex AI Reasoning Engines** behind the
Agent Gateway egress PSC. The `GatewayAgent` SDK (in `lib/gateway_agent/`) is the
mandatory base class — it enforces:

| Feature | What it does | Why mandatory |
|---|---|---|
| `GlobalGemini` | Pass-through `Gemini` subclass using regional endpoint | Enables PSC egress routing |
| `emit_llm_usage_from_response` | OTEL after_model_callback | Dashboard token metrics require `jsonPayload` |
| `query()` stub | Registers method with RE `:query` endpoint | Prevents "method not found" errors |
| `get_project_id` patch | Reads project from env vars | Prevents gRPC IAM lookups that timeout through PSC |

---

## 1. Agent File Pattern (Minimal)

**File:** `agents/chat-agent/agent.py`

```python
"""Chat Agent — business logic only.

All Agent Gateway compliance (GlobalGemini routing, OTEL telemetry,
query() REST endpoint, get_project_id patch) is enforced by GatewayAgent.

The gateway_agent package is bundled into this directory at deploy time by
deploy_chat_agent.sh from lib/gateway_agent/.
"""

import os
import sys

# Make gateway_agent importable from the bundled copy in this directory.
# deploy_chat_agent.sh copies lib/gateway_agent/ → agents/chat-agent/gateway_agent/
# before adk deploy, so __file__ directory contains the gateway_agent package.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import requests
from gateway_agent import GatewayAgent


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
            "This host is not in the Agent Gateway egress allowlist."
        )
    except Exception as e:
        return f"[FETCH FAILED] Could not retrieve '{url}': {e}"


root_agent = GatewayAgent(
    name="chat_agent",
    model="gemini-2.5-flash",        # pass as plain string — GatewayAgent wraps with GlobalGemini
    description="A helpful chat agent secured by the Agent Gateway.",
    instruction=(
        "You are a helpful assistant. "
        "Use the fetch_url tool to read web content when asked."
    ),
    tools=[fetch_url],
)
```

**Key rules:**
- Import `GatewayAgent` from `gateway_agent` — never use bare `google.adk.agents.Agent`
- Pass `model` as a plain string — `GatewayAgent` wraps it with `GlobalGemini` automatically
- Do NOT manually wire `after_model_callback` for telemetry — `GatewayAgent` chains it
- Do NOT manually patch `Agent.query` — `GatewayAgent.query()` registers the stub

---

## 2. GlobalGemini — Regional Endpoint (NOT Global)

**Important:** For Agent Gateway RE deployments, `GlobalGemini` is a **pass-through** that
uses the **regional** Vertex AI endpoint. It does NOT override to `location="global"`.

```python
# lib/gateway_agent/global_gemini.py
from google.adk.models.google_llm import Gemini

class GlobalGemini(Gemini):
    """Pass-through — uses default regional ADK endpoint via GOOGLE_CLOUD_LOCATION env var.

    The RE is deployed in us-east1. GOOGLE_CLOUD_LOCATION=us-east1 routes inference to
    us-east1-aiplatform.googleapis.com, which is reachable through the PSC egress attachment.

    DO NOT override api_client to location="global" — the global endpoint
    (aiplatform.googleapis.com) is NOT reachable via the regional PSC attachment.
    """
    pass  # No overrides needed
```

**When to use `location="global"` instead:**
Only if you're deploying to Cloud Run (not RE) AND using Gemini 3.x models that are not
yet available in your region. In that case, restore the `api_client` property override.
See `global_gemini.py` history comments for the snippet to restore.

---

## 3. GatewayAgent SDK Structure

```
lib/gateway_agent/
├── __init__.py          # exports: GatewayAgent, GlobalGemini, emit_llm_usage_from_response
├── agent.py             # GatewayAgent(Agent) — main wrapper class
├── global_gemini.py     # GlobalGemini(Gemini) — regional pass-through
├── telemetry.py         # emit_llm_usage_from_response — OTEL after_model_callback
└── setup.py             # package metadata
```

The SDK is **bundled at deploy time** by `scripts/deploy_chat_agent.sh`:
```bash
cp -r lib/gateway_agent agents/chat-agent/gateway_agent
# ... adk deploy agents/chat-agent ...
rm -rf agents/chat-agent/gateway_agent   # cleanup after deploy
```

Do not edit files inside `agents/chat-agent/gateway_agent/` — it is a temporary copy.
The source of truth is `lib/gateway_agent/`.

---

## 4. OTEL Telemetry — Critical: Use print(), NOT logging.info()

The OTEL callback (`telemetry.py`) emits token usage events. **Must use `print()` to stdout,
not `logging.info()`**.

| Method | Cloud Logging field | Log-based metric matches? |
|---|---|---|
| `logging.info(json.dumps(event))` | `textPayload` | ❌ NO — metrics filter `jsonPayload.event` |
| `print(json.dumps(event), flush=True)` | `jsonPayload` | ✅ YES |

The event format consumed by `agent_observability/log_metrics.tf`:
```json
{
  "event": "llm_usage",
  "agent": "chat_agent",
  "model": "gemini-2.5-flash",
  "input_tokens": 166,
  "output_tokens": 84,
  "thoughts_tokens": 0,
  "total_tokens": 250
}
```

`GatewayAgent` wires this automatically via `_chained_callback`. No manual wiring needed.

---

## 5. OTEL 3-Layer Fix — Mandatory for All RE Deployments

RE containers have mTLS certs provisioned. Without these three env vars, agents will:
- **Layer 1**: Fail silently on Q2+ (SSL context corruption)
- **Layer 2**: Hang 10–15s per query (TCP blocked on OTEL export)
- **Layer 3**: Crash on Q2+ with `RuntimeError: Event loop is closed`

These env vars are injected via `agents/chat-agent/.env` by `scripts/deploy_chat_agent.sh`:

```bash
# LAYER 1 — SSL Context Fix
# RE mTLS certs trigger configure_mtls_channel() in the OTEL BatchSpanProcessor.
# This corrupts the pyopenssl SSL context on the 2nd flush, crashing Thread-2.
# Standard TLS (never) avoids this entirely.
GOOGLE_API_USE_MTLS_ENDPOINT=never

# LAYER 2 — PSC TCP Block Fix
# telemetry.googleapis.com is NOT in the PSC egress routing table.
# OTEL export attempts block on TCP SYN for the OS timeout (~10–15s).
# Short timeout (2s) makes the export fail fast and non-blocking.
OTEL_EXPORTER_OTLP_TIMEOUT=2000
OTEL_BSP_EXPORT_TIMEOUT_MILLIS=2000
OTEL_BSP_SCHEDULE_DELAY_MILLIS=15000

# LAYER 3 — aiohttp Singleton Event Loop Fix (ROOT CAUSE)
# google.genai._api_client creates AsyncAuthorizedSession as a module-level singleton
# when mtls.should_use_client_cert() returns True (RE containers have mTLS certs).
# This session is bound to the event loop from Query 1's asyncio.run() thread.
# When Query 1 completes, asyncio.run() closes that loop. Query 2 starts a new
# asyncio.run() with a new loop, but the singleton still references the closed loop.
# Result: RuntimeError: Event loop is closed (asyncio/base_events.py:545 _check_closed)
# on EVERY query after the first.
#
# Fix: GOOGLE_API_USE_CLIENT_CERTIFICATE=false makes should_use_client_cert() return
# False, disabling the aiohttp path entirely. google.genai falls back to httpx, which
# creates a fresh AsyncClient per event loop — no singleton, no closed-loop crash.
GOOGLE_API_USE_CLIENT_CERTIFICATE=false
```

**Reference:** `KNOWN_ISSUES.md` Issue #007 (full root cause analysis with stack traces).

---

## 6. Deploy Sequence

```
mod-agw-foundation-pub/
├── lib/gateway_agent/          ← SDK source of truth
├── agents/chat-agent/          ← Agent business logic
│   ├── agent.py
│   ├── requirements.txt
│   └── .env                    ← written by deploy_chat_agent.sh (3-layer OTEL fix)
└── scripts/
    └── deploy_chat_agent.sh    ← orchestrates everything below
```

**Deploy steps (automated by `scripts/deploy_chat_agent.sh`):**
1. Create `.venv` at project root, install ADK + deps
2. Delete any existing RE with display name `chat-agent-v2` (no upsert path in ADK)
3. Write `agents/chat-agent/.env` with 3-layer OTEL env vars
4. Apply `patch_sdk_for_rest_create.py` — injects `agentGatewayConfig` into RE create payload
5. Compliance check — fails build if `agent.py` doesn't import `GatewayAgent`
6. Apply `patch_add_context_spec.py` — prevents platform from injecting `memoryBankConfig`
7. Bundle `lib/gateway_agent/` → `agents/chat-agent/gateway_agent/` (temporary)
8. `adk deploy agent_engine ... agents/chat-agent`
9. Cleanup `agents/chat-agent/gateway_agent/` (temp copy removed)
10. PATCH RE `contextSpec: null` — strips server-injected contextSpec
11. Poll RE state until `ACTIVE`
12. Verify exactly 1 RE with the expected display name

**To deploy:**
```bash
cd mod-agw-foundation-pub
bash scripts/deploy_chat_agent.sh
```

---

## 7. :streamQuery vs :query

| Endpoint | Status | Notes |
|---|---|---|
| `POST .../reasoningEngines/{id}:streamQuery` | ✅ Mandatory | Session-based inference — the only supported inference path |
| `POST .../reasoningEngines/{id}:query` with `class_method: create_session` | ✅ Required first | Creates the session before streamQuery |
| `POST .../reasoningEngines/{id}:query` with inference | ❌ Not supported | ADK 1.31.1 does not register inference methods on :query |

**Correct flow:**
```python
# 1. Create session
session = re.create_session(user_id="uid-123")
sid = session["id"]

# 2. Stream query (inference)
events = list(re.stream_query(
    message="What is the capital of France?",
    user_id="uid-123",
    session_id=sid,
))

# 3. Extract text
text = "".join(
    p.get("text", "")
    for e in events
    for p in e.get("content", {}).get("parts", [])
    if p.get("text", "")
)
```

**Reference:** `KNOWN_ISSUES.md` Issue #002.

---

## 8. Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `RuntimeError: Event loop is closed` on Q2+ | Layer 3: aiohttp singleton bound to Q1's closed loop | `GOOGLE_API_USE_CLIENT_CERTIFICATE=false` |
| Q1 works, Q2/Q4/Q6 fail silently | Layer 2: OTEL export blocking on PSC TCP for 10–15s | `OTEL_EXPORTER_OTLP_TIMEOUT=2000` + `OTEL_BSP_SCHEDULE_DELAY_MILLIS=15000` |
| All responses 403 `Prompt violates content security` | Layer 1: `response_template_id=security-high` flags SSE frames as PI | Remove `response_template_id` from authz extension |
| `Default method 'query' not found` | ADK 1.31.1 doesn't register inference on :query | Use `:streamQuery` for inference — see Issue #002 |
| `BaseModel.__init__() takes 1 positional argument` | Pydantic v2: `GlobalGemini(model_name)` not `GlobalGemini(model_name)` positional | Use `GlobalGemini(model="...")` keyword arg |
| Dashboard shows zero token usage | `logger.info()` writes `textPayload` not `jsonPayload` | Use `print(json.dumps(event), flush=True)` in telemetry |
| `Error loading ASGI app factory` at RE startup | Import error in `agent.py` (e.g., missing dep, stale module) | Check Cloud Logging RE startup logs |
| Agent answers Q1 but hangs on Q2 without error | aiohttp singleton (Layer 3) before fix | `GOOGLE_API_USE_CLIENT_CERTIFICATE=false` |
| `404 Model not found` on regional endpoint | Model requires global endpoint (Cloud Run deployments only) | Only for Cloud Run: restore `api_client` override in `GlobalGemini` |
| PSC timeout on IAM/project-number lookup | gRPC lookup for project ID routes through PSC (no IAM route) | `get_project_id` patch in `GatewayAgent.__init__()` — already handled |
| `Compliance Error: agent.py must import GatewayAgent` | Bare `Agent()` used instead of `GatewayAgent()` | Replace `from google.adk.agents import Agent` with `from gateway_agent import GatewayAgent` |

---

## 9. Adding a New Agent

1. Copy `agents/chat-agent/` to `agents/your-agent/`
2. Edit `agent.py` — keep `GatewayAgent`, change `name`, `instruction`, `tools`
3. Update `requirements.txt` if new deps needed
4. Copy `scripts/deploy_chat_agent.sh` → `scripts/deploy_your_agent.sh`
5. In the new deploy script, change:
   - `--display_name="your-agent-name"`
   - `agents/chat-agent` → `agents/your-agent` (all occurrences)
   - Agent name in cleanup pre-check
6. Deploy: `bash scripts/deploy_your_agent.sh`

**Do NOT:**
- Import `Agent` directly from `google.adk.agents` — use `GatewayAgent`
- Set `after_model_callback` manually — `GatewayAgent` chains it
- Override `GlobalGemini.api_client` to `location="global"` — breaks PSC egress
- Omit the 3-layer OTEL env vars from `.env` — agent will crash on Q2+
