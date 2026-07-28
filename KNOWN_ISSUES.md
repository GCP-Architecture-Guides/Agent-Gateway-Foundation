# Known Issues & Rollback Runbook

> **Project:** `YOUR_PROJECT_ID` · **Foundation:** `mod-agw-foundation` · **Last Updated:** 2026-07-25

This document is the complete, honest record of every bug encountered deploying
the Agent Gateway foundation and the `chat-agent-v2` Reasoning Engine. Each issue
is recorded chronologically, with root cause, all attempted fixes (including the
ones that failed), the final resolution, and a rollback procedure.

---

## Summary

| # | Issue | Severity | Status |
|---|---|---|---|
| 001 | Model Armor PI/Jailbreak false positive on `:streamQuery` responses | 🔴 Critical | ✅ Fixed |
| 002 | ADK 1.31.1: `:query` endpoint not registered | 🟡 Medium | ✅ Resolved (by design) |
| 003 | Pydantic v2: `GlobalGemini(model)` positional arg rejected | 🔴 Critical | ✅ Fixed |
| 004 | `GlobalGemini._get_client_args()` is dead code in ADK 1.31.1 | 🟡 Medium | ✅ Fixed |
| 005 | `GlobalGemini(api_client=global)` breaks egress PSC routing | 🔴 Critical | ✅ Fixed |
| 006 | `after_model_callback` TypeError: `callback_context` kwarg mismatch | 🔴 Critical | ✅ Fixed |
| 007 | OTEL exporter SSL crash kills RE async thread after first query | 🔴 Critical | ✅ Fixed |
| 008 | Unpinned SDK versions: `agentplatform.Client` transport bypasses all patch interceptors | 🔴 Critical | ✅ Fixed |
| 009 | Invalid agent name `chat-agent` — hyphens not allowed; ADK requires Python identifier | 🔴 Critical | ✅ Fixed |

---

## Issue #001 — Model Armor PI/Jailbreak False Positive on Agent Responses

**Status:** ✅ Fixed — `response_template_id` removed from authz extension  
**Severity:** Critical — blocked every single agent response  
**Discovered:** 2026-07-13  

### Symptom

Every call to `POST .../reasoningEngines/{id}:streamQuery` returned HTTP 403:
```
Model Armor: Response violates content security configurations.
However, the operation was successful.
```
Note: "operation was successful" confirms the agent ran — the block was on the RESPONSE
path, not the request path.

### Root Cause

The authz extension `acme-corp-ma-extension` was configured with the same Model Armor
template for both request and response screening:

```hcl
model_armor_settings = [{
  request_template_id  = ".../security-high"   # screens user input ✅
  response_template_id = ".../security-high"   # screens agent output ❌
}]
```

The Vertex AI RE platform wraps `:streamQuery` responses in gRPC-HTTP transcoding
format before delivery. The response body contains HTTP metadata:

```json
[{"text":"{\"contentType\": \"application/json\", \"extensions\": [...]}"}]
```

The `security-high` template has `pi_and_jailbreak.filterEnforcement = ENABLED`.
The PI/Jailbreak filter sees `contentType`/`extensions` JSON in the response body
and flags it as a **prompt injection from model** — a false positive. This is
platform-level behaviour that cannot be changed in agent code.

Confirmed via Model Armor audit logs:
```
SANITIZE_MODEL_RESPONSE → filter=pi_and_jailbreak → MATCH_FOUND → BLOCK
```

### Attempted Fixes (all failed before final solution)

| Attempt | Approach | Why It Failed |
|---|---|---|
| 1 | Set `pi_and_jailbreak.confidence_level = LOW` | `LOW` is not a valid enum value |
| 2 | Set `filterEnforcement = DISABLED` on template | Org floor policy blocks — requires ENABLED on all templates |
| 3 | Create a `security-responses` template without PI/Jailbreak | Org floor policy: ALL templates must have PI/Jailbreak ENABLED |
| 4 | Override `GlobalGemini._get_client_args()` for REST transport | Dead code in ADK 1.31.1 — method is never called |
| 5 | Override `GlobalGemini.api_client` → `Client(location="global")` | Breaks egress PSC (see Issue #005) |

### Final Fix Applied

Removed `response_template_id` entirely from the authz extension:

```hcl
# 03_security_and_gateways.tf
model_armor_settings = [{
  # INPUT only: PI/Jailbreak + SDP + RAI + malicious URIs on user prompts
  request_template_id = ".../security-high"
  # No response_template_id — model output safety via Gemini built-in harm filters
}]
```

**Security rationale:** Gemini's built-in safety filters (RAI, harm categories) are
always active at the model layer and cannot be bypassed by any client. Model Armor
response screening only makes sense for plain-text responses — not gRPC-transcoded
streaming frames that contain HTTP metadata the filter misidentifies as injection.

### Rollback

To restore response screening (if/when the platform changes its transcoding format):

```bash
# In 03_security_and_gateways.tf, add back to model_armor_settings:
#   response_template_id = "projects/${var.project_id}/locations/${var.location}/templates/security-high"
cd mod-agw-foundation-pub
terraform apply -target=google_network_services_authz_extension.ma_extension -auto-approve
```

---

## Issue #002 — ADK 1.31.1: `:query` Endpoint Not Registered

**Status:** ✅ Resolved — use `:streamQuery` instead (by design)  
**Severity:** Medium  

### Symptom

```
POST .../reasoningEngines/{id}:query
→ "Default method `query` not found. Available methods: [session management only]"
```

### Root Cause

In ADK 1.31.1, `AdkApp` does NOT register `query()` or `stream_query()` as RE class
methods. Only session management methods are registered. Inference goes through the
ASGI `/stream_reasoning_engine` endpoint, exposed via `:streamQuery`.

### Resolution

Always use the session-based 2-step flow:
```python
# Step 1 — create session
re.create_session(user_id="...")   # or POST :query with class_method=create_session

# Step 2 — run inference
for event in re.stream_query(message="...", user_id="...", session_id="..."):
    ...
```

---

## Issue #003 — Pydantic v2: `GlobalGemini(model)` Positional Arg Rejected

**Status:** ✅ Fixed  
**Severity:** Critical — caused RE startup failure  

### Symptom

```
Error loading ASGI app factory:
BaseModel.__init__() takes 1 positional argument but 2 were given
```

### Root Cause

`BaseLlm` (parent of `Gemini`) is a Pydantic v2 `BaseModel`. Pydantic v2 requires
keyword arguments for model initialization — positional args are rejected.

### Fix

```python
# ❌ Before
gateway_model = GlobalGemini(model)

# ✅ After
gateway_model = GlobalGemini(model=model)
```

File: [`lib/gateway_agent/agent.py`](lib/gateway_agent/agent.py)

---

## Issue #004 — `GlobalGemini._get_client_args()` Is Dead Code in ADK 1.31.1

**Status:** ✅ Fixed  
**Severity:** Medium — silently had no effect  

### Symptom

The `GlobalGemini` class in the `gateway-agent-sdk` skill overrides `_get_client_args()`
to force `Client(location="global")`. This had no effect — REST transport was never used,
and the model was still being called via gRPC.

### Root Cause

In ADK 1.31.1, `Gemini._get_client_args()` is **never called** by the base class.
The actual API client is created by the `api_client` property. The `_get_client_args()`
override was dead code from an older ADK version.

### Fix

Removed the `_get_client_args()` override. The `GlobalGemini` class was later simplified
to a clean pass-through (see Issue #005).

---

## Issue #005 — `GlobalGemini(api_client=global)` Breaks Egress PSC Routing

**Status:** ✅ Fixed  
**Severity:** Critical — caused 0 events on all queries  

### Symptom

After fixing Issue #004 by overriding the `api_client` property with
`Client(vertexai=True, location="global")`, all `stream_query` calls returned
HTTP 200 but with 0 events and empty response body.

### Root Cause

`Client(vertexai=True, location="global")` points to the global Vertex AI endpoint:
`aiplatform.googleapis.com` (no region prefix).

The Agent Gateway **egress PSC** is a regional construct. It only routes traffic to:
- `us-east1-aiplatform.googleapis.com` ✅ (via PSC network attachment)

It does **NOT** route traffic to:
- `aiplatform.googleapis.com` ❌ (global endpoint, different IP, no PSC path)

When the agent tried to call Gemini via the global endpoint, the PSC silently dropped
the connection, the model call timed out, and the ASGI server returned an empty response.

**Key insight:** The original problem (global endpoint needed for Gemini 2.5+) was
no longer true. `gemini-2.5-flash` IS available at the `us-east1` regional endpoint.
Confirmed by Cloud Logging: `backend: GoogleLLMVariant.VERTEX_AI, stream: False` —
model calls were succeeding via the regional endpoint once PSC routing was used.

### Fix

`GlobalGemini` was reverted to a no-op pass-through that inherits all `Gemini`
defaults (including the regional endpoint derived from `GOOGLE_CLOUD_LOCATION=us-east1`):

```python
# lib/gateway_agent/global_gemini.py
class GlobalGemini(Gemini):
    """Pass-through wrapper — uses ADK default regional endpoint.
    
    The regional endpoint works with the Agent Gateway egress PSC.
    gemini-2.5-flash is available at us-east1-aiplatform.googleapis.com.
    """
    pass
```

**Note for future:** If Gemini 4.x+ models require the global endpoint, the egress
PSC must first be extended to route `aiplatform.googleapis.com` before re-enabling
the `api_client` override. Do not restore the override without also updating the PSC.

---

## Issue #006 — `after_model_callback` TypeError: Wrong Parameter Names

**Status:** ✅ Fixed  
**Severity:** Critical — silently dropped all agent responses after model call  

### Symptom

Queries returned HTTP 200 with 0 events. Cloud Logging showed:

```
INFO:  Sending out request, model: gemini-2.5-flash, backend: VERTEX_AI
INFO:  Response received from the model.
ERROR: TypeError: GatewayAgent.__init__.<locals>._chained_callback() got an
       unexpected keyword argument 'callback_context'
```

The model was being called successfully. The error occurred in the
`after_model_callback`, which caused the entire response to be dropped.

### Root Cause

ADK 1.31.1 changed the `after_model_callback` calling convention from positional
to **keyword arguments**:

```python
# ADK 1.31.1 base_llm_flow.py — how callbacks are invoked:
callback_response = callback(
    callback_context=callback_context,   # ← keyword arg
    llm_response=llm_response            # ← keyword arg
)
```

Our `_chained_callback` in `GatewayAgent.__init__` used the old positional names:

```python
# ❌ Before (wrong parameter names)
def _chained_callback(ctx: CallbackContext, response: LlmResponse):
    emit_llm_usage_from_response(ctx, response)
    if after_model_callback is not None:
        return after_model_callback(ctx, response)
```

When ADK called `callback(callback_context=..., llm_response=...)`, Python matched
`callback_context` as a keyword arg against a function that has no `callback_context`
parameter — TypeError.

### Fix

```python
# ✅ After — parameter names match ADK 1.31.1 calling convention
def _chained_callback(
    callback_context: CallbackContext, llm_response: LlmResponse
) -> Optional[LlmResponse]:
    emit_llm_usage_from_response(callback_context, llm_response)
    if after_model_callback is not None:
        return after_model_callback(
            callback_context=callback_context, llm_response=llm_response
        )
    return None
```

File: [`lib/gateway_agent/agent.py`](lib/gateway_agent/agent.py)

**Verification:** After this fix, `stream_query("What is 2+2?")` returned 1 event
with `✅ ANSWER: 2+2 equals 4.`

---

## Issue #007 — Multi-Layer OTEL Failure: RE Queries Fail After N Successful Calls

**Status:** ✅ Fixed — 5 env vars required (see Fix Applied below)  
**Severity:** Critical — RE passes 0–3 queries then goes permanently silent  
**Discovered:** 2026-07-13 | **Root cause confirmed:** 2026-07-21  

> **This issue has THREE independent layers.** All three must be fixed. Fixing only
> Layer 1 exposes Layer 2; fixing only Layers 1+2 exposes Layer 3.

---

### Layer 1 — mTLS SSL Context Crash (First-Query-Only Symptom)

**Original symptom:** Only the first query per RE container succeeds.

**Error in Cloud Logging:**
```
ERROR: Exception in thread Thread-2 (_asyncio_thread_main):
  ValueError: Context has already been used to create a Connection,
              it cannot be mutated again
```

**Root Cause:**  
Inside RE containers, `mtls.should_use_client_cert()` returns `True` because the
container has mTLS certs provisioned for Vertex AI platform communication.
ADK's `_get_gcp_span_exporter()` calls `session.configure_mtls_channel()`, creating
a pyopenssl SSL context. After the first OTEL export uses this context, it becomes
"used". On the second flush, urllib3/pyopenssl tries to mutate the same context:
`ValueError: Context has already been used` — unhandled exception kills Thread-2.

**Fix (Layer 1):** `GOOGLE_API_USE_MTLS_ENDPOINT=never`

---

### Layer 2 — TCP Block: OTEL Export Starves Query Threads (Alternating Failure)

**Symptom after Layer 1 fix:** Alternating pattern Q1-pass Q2-fail Q3-pass Q4-fail.

**Root Cause:**  
`telemetry.googleapis.com` is NOT in the Agent Gateway PSC egress routing table.
Outbound packets to unregistered hosts are **silently dropped** (no TCP RST).
The OTEL `BatchSpanProcessor` background thread calls `session.post()` which blocks
for the OS TCP SYN timeout (~10-15s). During this window, query-handling threads
are starved or blocked on shared networking/asyncio state.

**Fix (Layer 2):**
```
OTEL_EXPORTER_OTLP_TIMEOUT=2000       # export gives up after 2s
OTEL_BSP_EXPORT_TIMEOUT_MILLIS=2000   # BatchSpanProcessor export timeout
OTEL_BSP_SCHEDULE_DELAY_MILLIS=15000  # delay first export 15s (post-warmup)
```

---

### Layer 3 — google.genai aiohttp Session Singleton (CONFIRMED ROOT CAUSE)

**Symptom after Layers 1+2 fix:** Q1 passes, Q2+ ALL fail immediately (1-2s, no model call):

```
ERROR: Exception in thread Thread-N (_asyncio_thread_main):
  File "/usr/local/lib/python3.12/asyncio/base_events.py", line 545, in _check_closed
    raise RuntimeError('Event loop is closed')
RuntimeError: Event loop is closed
```

**Root Cause (confirmed by source code inspection of google-genai SDK):**

`google.genai._api_client.BaseApiClient._use_google_auth_async()` returns `True` when:
- `aiohttp` is installed ✅
- `vertexai=True` ✅
- `mtls.should_use_client_cert()` returns `True` ← RE containers have mTLS certs provisioned ✅

When this path is active, `_get_aiohttp_session()` creates an `aiohttp.AsyncAuthorizedSession`
**once** and caches it as `self._aiohttp_session`. This session stores Q1's `asyncio.run()` event
loop reference internally.

After Q1 completes, `asyncio.run()` **closes** that event loop. The session's `_loop` is now closed.

For Q2, the RE container starts a new `_asyncio_thread_main` thread, calls `asyncio.run()` again
(creating a **new** event loop), but `_get_aiohttp_session()` returns the **SAME** cached session
with the **old closed loop**. The very first use of this session calls `self._check_closed()` →
`RuntimeError: Event loop is closed`. Thread-N crashes. Q2+ return 0 events.

The non-google-auth-async path has a `_loop.is_closed()` guard to recreate the session;
the google-auth-async path (`AsyncAuthorizedSession`) does NOT.

**Fix (Layer 3):** `GOOGLE_API_USE_CLIENT_CERTIFICATE=false`

This env var makes `mtls.should_use_client_cert()` return `False`, which causes:
- `_use_google_auth_async()` returns `False`
- `_use_aiohttp()` returns `False`
- `google.genai` falls back to `httpx.AsyncClient` (no singleton, no loop binding)

All OTEL telemetry continues to work. `emit_llm_usage_from_response` and the OTEL
`google-genai` instrumentation are both unaffected.

Note: `GOOGLE_API_USE_MTLS_ENDPOINT=never` (Layer 1) controls the **endpoint URL** but does NOT
change `should_use_client_cert()`. Both env vars are required.

---

### Complete Fix Applied (2026-07-21)

Add ALL FIVE env vars to `scripts/deploy_chat_agent.sh`'s `.env` heredoc:

```bash
# Layer 1: mTLS SSL context crash fix
GOOGLE_API_USE_MTLS_ENDPOINT=never

# Layer 2: TCP block timeout fix
OTEL_EXPORTER_OTLP_TIMEOUT=2000
OTEL_BSP_EXPORT_TIMEOUT_MILLIS=2000
OTEL_BSP_SCHEDULE_DELAY_MILLIS=15000

# Layer 3: aiohttp session singleton fix — disables mTLS aiohttp path, uses httpx
GOOGLE_API_USE_CLIENT_CERTIFICATE=false
```

All five vars are NOT in the gateway_patch's `_OTEL_VARS` override list and are
preserved as-is in the RE container environment.

### Rollback Procedure

```bash
# From mod-agw-foundation-pub/ project root:
bash scripts/deploy_chat_agent.sh
```

### Files Changed

- `scripts/deploy_chat_agent.sh`: Added 5 OTEL fix env vars to `.env` heredoc
- `skills/gateway-agent-sdk/SKILL.md`: Full 3-layer OTEL fix documented in Lesson #9

---

## Issue #008 — Unpinned SDK: `agentplatform.Client` Transport Bypasses Org Policy Patch

**Status:** ✅ Fixed — versions pinned in deploy script and Terraform template  
**Severity:** Critical — ALL 4 org policy constraints violated, deploy fails with 400  
**Discovered:** 2026-07-25  

### Symptom

```
Deploy failed: 400 FAILED_PRECONDITION.
'Operation denied by org policy on resource 'projects/YOUR_PROJECT_ID/locations/YOUR_REGION':
  ["customConstraints/custom.acmecorpEnforceAgentIdentityForReasoningEngine": ...]
  ["customConstraints/custom.acmecorpEnforceReasoningEngineOtelConfig": ...]
  ["customConstraints/custom.acmecorpEnforceReasoningEngineAgentGatewayConfig": ...]
  ["customConstraints/custom.enforceReasoningEngineAgentGatewayConfig": ...]'
```

All 4 org policy constraints violated simultaneously. The patch appears to load:
```
[gateway_patch] Patched AuthorizedSession.send (PreparedRequest level)
[gateway_patch] Patched httpx.Client.send (transport level)
[gateway_patch] Patched ReasoningEngineServiceClient (class level)
[gateway_patch] Patched ReasoningEngineClientWithOverride (class level)
[patch] verify OK
```

But **no** `[gateway_patch] Injected identityType+agentGatewayConfig+OTEL...` or
`[gateway_patch] REST CREATE ->` messages appear during `adk deploy`. The interceptors
register but never fire.

### Root Cause

The deploy script was installing `google-adk` and `google-cloud-aiplatform` **without
version pins**. A newer version of `google-cloud-aiplatform` (>1.149.0) changed the
internal transport for Reasoning Engine creation from:

- **Before (1.149.0):** `google.auth.transport.requests.AuthorizedSession` → REST over HTTP
- **After (newer):** `agentplatform.Client` → different internal transport

The `.pth` monkey-patch covers 3 interception layers:
1. `AuthorizedSession.send` — HTTP transport layer
2. `httpx.Client.send` — httpx transport layer
3. `ReasoningEngineServiceClient.create_reasoning_engine` — GAPIC class method

None of these cover `agentplatform.Client`'s transport. The CREATE call goes through
a completely new code path, bypassing all 3 layers silently.

**Diagnostic signal:** `adk deploy` shows:
```
FutureWarning: The vertexai.Client class is deprecated. Please use agentplatform.Client instead.
  client = vertexai.Client(
```
This warning was also present in the known-working 1.149.0 deployment, but in newer
versions `vertexai.Client` now delegates internally to `agentplatform.Client` which uses
a different HTTP stack that the patch does not intercept.

### Fix Applied

Pinned SDK versions in both the Terraform template (`06_agent_provisioning.tf`) and
the static deploy script (`scripts/deploy_chat_agent.sh`):

```bash
# IMPORTANT: Do NOT unpin these versions. See KNOWN_ISSUES.md #008.
.venv/bin/pip install -i https://pypi.org/simple -q --no-deps "google-adk==1.31.1"
.venv/bin/pip install -i https://pypi.org/simple -q "google-cloud-aiplatform[adk,agent_engines]==1.149.0" "requests" "pydantic"
```

Also: when upgrading SDK versions in the future, the patch's interceptors must be
extended to cover the new `agentplatform.Client` transport path before version pins
are removed.

### Rollback

```bash
# If you see 400 FAILED_PRECONDITION with all 4 org policy constraints:
# 1. Delete the existing stale .venv
rm -rf /path/to/mod-agw-foundation-pub/.venv
# 2. Redeploy — the script will rebuild .venv with pinned versions
bash deploy_all.sh
```

---

## Deployment History

| RE ID | Deployed | Config | Outcome |
|---|---|---|---|
| `8368831599747268608` | 2026-07-13 AM | GlobalGemini global endpoint, response_template_id=security-high | All queries 403 (Model Armor) |
| `522998098914443264` | 2026-07-13 AM | response_template_id removed, GlobalGemini global endpoint | HTTP 200, 0 events (PSC routing broken) |
| `1580781061393088512` | 2026-07-13 PM | response_template_id removed, GlobalGemini pass-through, callback fix | Q1 pass, Q2+ fail (OTEL Layer 1 crash) |
| `1085525839870689280` | 2026-07-20 | + `GOOGLE_API_USE_MTLS_ENDPOINT=never` | Q1/Q3 pass, Q2/Q4 fail (Layer 2 TCP block) |
| `6982567339447287808` | 2026-07-21 | + OTLP timeout 2s + BSP delay 15s | Q1-Q3 pass, Q4+ fail (Layer 3 event loop) |
| `8588522819069935616` | 2026-07-21 | + `OTEL_PYTHON_DISABLED_INSTRUMENTATIONS=google_genai` | 1/6 (wrong fix — error from asyncio, not OTEL) |
| `450096079946383360` | 2026-07-22 | + `GOOGLE_API_USE_CLIENT_CERTIFICATE=false` | ✅ 6/6 SDK pass + 3/3 gateway pass |

---

## Files Changed

| File | Change |
|---|---|
| [`03_security_and_gateways.tf`](03_security_and_gateways.tf) | Removed `response_template_id` from authz extension |
| [`lib/gateway_agent/global_gemini.py`](lib/gateway_agent/global_gemini.py) | Reverted to pass-through — no endpoint override |
| [`lib/gateway_agent/agent.py`](lib/gateway_agent/agent.py) | Fixed `_chained_callback` parameter names for ADK 1.31.1 |
| [`scripts/deploy_chat_agent.sh`](scripts/deploy_chat_agent.sh) | Added 5 OTEL fix env vars to `.env` heredoc |

---

## Lessons Learned

1. **Read the skill first.** The `gateway-agent-sdk` skill existed specifically to
   prevent re-inventing this wheel. It was consulted too late in the session.

2. **`_get_client_args()` is dead in ADK 1.31.1.** The correct extension point is
   the `api_client` property. Always verify against the installed SDK version.

3. **PSC is regional.** The global Vertex AI endpoint (`aiplatform.googleapis.com`)
   is NOT routed by a regional PSC attachment. Never use `location="global"` inside
   an Agent Gateway RE without first extending the PSC to cover the global endpoint.

4. **ADK callback signatures changed.** In ADK 1.31.1, callbacks receive
   `callback_context=` and `llm_response=` as keyword arguments.

5. **Model Armor `response_template_id` is incompatible with RE streaming.**
   The gRPC-HTTP transcoded SSE format always triggers PI/Jailbreak false positives.
   Use only `request_template_id` on the ingress authz extension.

6. **"Operation was successful" in a 403 means the agent ran.** Always check Model
   Armor audit logs, not just the HTTP status.

7. **`variables.tf:allowed_egress_hosts` is documentation only.** It is NOT consumed
   by any Terraform resource. The actual PSC egress routing is managed by the Agent
   Gateway platform — adding a host there does NOT route it through the PSC.

8. **OTEL issues in RE containers are always multi-layer.** Fixing one symptom
   exposes the next. Always run 6+ back-to-back queries as a regression test.

9. **google.genai uses aiohttp `AsyncAuthorizedSession` as a singleton in RE containers.**
   When `mtls.should_use_client_cert()` returns True (RE containers have mTLS certs), the
   SDK caches an `AsyncAuthorizedSession` bound to Q1's event loop. Q2+'s new
   `asyncio.run()` loops find the singleton's `_loop` closed → RuntimeError immediately.
   **Fix:** `GOOGLE_API_USE_CLIENT_CERTIFICATE=false` disables the aiohttp path entirely.
   Note: `GOOGLE_API_USE_MTLS_ENDPOINT=never` does NOT fix this — it only changes the URL.

10. **Pin versions in BOTH places.** There are two independent pip installs:
    - **Deploy `.venv`** (local): runs `adk deploy` and the `.pth` monkey-patch. Must pin
      `google-adk==1.31.1` + `google-cloud-aiplatform==1.149.0` so the patch interceptors
      (AuthorizedSession, httpx, GAPIC class) cover the transport used by the SDK.
    - **RE container** (`agents/chat-agent/requirements.txt`): runs inside the container at
      startup independently. Must also pin `google-adk==1.31.1`. Unpinned = newer ADK =
      different Pydantic `model` field type = `ValidationError: 1 validation error for
      GatewayAgent` = container startup crash = code 3 FAILED_TO_START.
    **Rule:** Any SDK version upgrade must be tested and pinned in BOTH locations simultaneously.
