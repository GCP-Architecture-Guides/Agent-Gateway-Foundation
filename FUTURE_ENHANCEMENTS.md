# Agent Gateway Foundation - Future Enhancements

This document tracks planned architectural improvements, refactoring tasks, and feature enhancements for the `mod-agw-foundation` module. 

It is designed as a living document. Add new enhancements to the top of the list as they are discovered.

---

## 1. Internal Agent Gateway SDK (Wrapper Library)
**Status:** Planned  
**Category:** Developer Experience / Security Enforcement  

### The Problem
Currently, to ensure compliance with the Agent Gateway's strict networking policies, developers must manually add boilerplate code to every new agent they build. This includes:
1. **Global Endpoint Routing**: Wrapping the model with `GlobalGemini` to ensure Gemini 3.x models route to the global Vertex AI endpoint instead of regional endpoints (which return 404s).
2. **Observability Wiring**: Manually hooking `emit_llm_usage_from_response` into the agent's `after_model_callback` to ensure telemetry reaches the Agent Gateway dashboards.

> **Note:** A third item — the `query() → stream_query()` monkey-patch — was originally in scope here but has been resolved at the platform level (see Enhancement 2). The gateway now natively governs both methods and no agent-side workaround is needed.

Relying on developers to copy-paste this boilerplate is error-prone and cannot be enforced via GCP Organization Policies (since Org Policies cannot inspect Python source code inside the deployment tarball).

### The Proposed Solution
Create an internal Python SDK (e.g., `agent-gateway-sdk`) that handles all boilerplate natively.

1. **Build `GatewayAgent` Class**:
   Create a new SDK folder (e.g., `lib/agent-gateway-sdk`). Inside, subclass the base ADK `Agent` to natively bake in the `GlobalGemini` model configuration and the telemetry callbacks. No `query()` override is required — the gateway handles both methods natively.
2. **Local Installation**:
   Package this SDK as a local wheel or simply include it in the agent's virtual environment prior to uploading the deployment package to Vertex AI.
3. **Pipeline Enforcement**:
   Update `scripts/deploy_chat_agent.sh` to perform static analysis on the agent's `requirements.txt` or `agent.py` file before running `terraform apply`. If the agent does not import and use the custom `GatewayAgent` class, the deployment pipeline explicitly fails the build (e.g., `❌ Gateway Compliance Error: Agent must use the GatewayAgent SDK.`).

### Benefits
- **Developer Velocity**: Developers can focus strictly on prompt engineering and tool creation rather than infrastructure wiring.
- **Consistency**: GlobalGemini routing and observability callbacks are guaranteed correct across every agent — no risk of a developer forgetting them.

---

## 2. Remove `query() → stream_query()` Monkey-Patch
**Status:** Ready to implement  
**Category:** Code Cleanup / Security Hygiene  
**Triggered by:** Agent Gateway Platform Advisory — July 1, 2026

### Background
When this foundation was originally built, the Agent Gateway only intercepted the `streamQuery` path in Client-to-Agent (ingress) mode. A monkey-patch was applied at module level in `agent.py` to ensure all `query()` calls were transparently proxied through `stream_query()`:

```python
def _patched_query(self, *args, **kwargs):
    return "".join(self.stream_query(*args, **kwargs))

Agent.query = _patched_query
```

This was **mandatory for security compliance** — without it, direct `query()` calls bypassed Model Armor, SGP, and DLP enforcement entirely.

### What Changed (Platform Advisory, July 1 2026)
The Agent Gateway now natively governs **both** `query` and `streamQuery` methods in ingress mode:

> *"In Client-to-Agent (ingress) mode, Agent Gateway can only govern Agent Runtime's query and streamQuery methods."*  
> — GCP Agent Gateway Product Documentation

Direct `query()` calls are now fully intercepted and governed by the gateway without any agent-side workaround.

### The Proposed Solution
Remove the monkey-patch block from `agent.py` and update Enhancement 1 (`GatewayAgent` SDK) to drop the `query` override from its boilerplate requirements:

1. **Delete** the `_patched_query` function and `Agent.query = _patched_query` line from `agent/agent.py`.
2. **Update** `lib/agent-gateway-sdk` (when built) — the `GatewayAgent` subclass no longer needs to override `query()`.
3. **Update** any pipeline compliance checks in `scripts/deploy_chat_agent.sh` that enforced the monkey-patch import pattern.
4. **Regression test**: Run the full guardrail suite (`run_guardrail_tests.py`) after removal and confirm PI-01, PI-02, DLP-01, DLP-02 still return HTTP 403 — proving the gateway natively intercepts `query()` calls.

### Benefits
- Eliminates a class-level global mutation (`Agent.query = ...`) that affected all `Agent` instances in the process.
- Removes copy-paste boilerplate from every agent deployment.
- Reduces onboarding confusion — new developers no longer need to understand why the patch existed before safely deploying an agent.
- Paves the way for the cleaner `GatewayAgent` subclass pattern in Enhancement 1 (no `query` override needed there either).

### Test Finding — July 1, 2026 (two test runs)

**Run 1** — `:query` without `classMethod`:

| Test | Result | Time | Notes |
|---|---|---|---|
| PI-01/02, URL-01/02, DLP-01/02 | ✅ PASS | ~0.5s | Gateway blocked at ingress (HTTP 400) |
| ALLOW-01/02 | ❌ FAIL | ~0.5s | RE: **`Default method 'query' not found`** |

**Run 2** — `:query` with `classMethod: "stream_query"` (per API docs):

| Test | Result | Time | Notes |
|---|---|---|---|
| PI-01/02, URL-01/02, DLP-01/02 | ✅ PASS | ~0.5s | Gateway blocked at ingress (HTTP 400) |
| ALLOW-01/02 | ❌ FAIL | ~0.5s | RE: **`User-specified method 'stream_query' not found`** |

**Definitive architectural finding:** The `:query` and `:streamQuery` REST endpoints maintain **completely separate method registries** on the AdkApp. `stream_query` is registered exclusively for the `:streamQuery` endpoint. The `:query` endpoint exposes only explicitly registered synchronous Python methods — and our AdkApp registers none.

Specifying `classMethod: "stream_query"` in the `:query` payload correctly routes the method name to the RE, but the RE's `:query` registry does not contain `stream_query`, so it still fails.

**What this means:**
- The monkey-patch (`Agent.query = _patched_query`) is Python-level only. It reroutes in-process `agent.query()` → `stream_query()` but has no effect on the REST API registry.
- The 6 block tests passing via `:query` (HTTP 400, ~0.5s) **confirm the gateway enforces both REST endpoints** — this is the platform advisory claim validated.
- The 2 ALLOW failures are a consequence of the AdkApp not registering any synchronous method under `:query`.

**Implication for Enhancement 1 (SDK):** The `GatewayAgent` subclass must explicitly register a synchronous `query()` method on the AdkApp to make `:query` work end-to-end. This is a new, confirmed requirement — separate from removing the monkey-patch.

### Risk
Low (for patch removal itself). Medium for full `:query` REST endpoint support — requires explicit synchronous `query()` method registration in the GatewayAgent SDK (Enhancement 1).

---

## 3. Token Tracking & Cost Aggregation Architecture
**Status:** Planned  
**Category:** Observability / FinOps  
**Proposed:** July 1, 2026

### The Problem

Multi-Agent Quest coordinates complex, multi-turn conversations using a tree of specialized sub-agents. Because a single user prompt might trigger multiple nested model calls (e.g. root agent routing to a domain discovery agent, which in turn calls a translator tool), tracking consumption at the API level is insufficient.

We need a system that maps **every model execution back to its originating user, session, agent, and project** — and aggregates that into queryable cost data without adding latency to the user path.

### Architectural Overview

```
[ User Interaction ]
         │ (propagates User ID, Session ID)
         ▼
┌──────────────────────────────────────┐
│       Root Orchestrator Agent        │
└──────────────────┬───────────────────┘
                   │ (delegates to)
                   ▼
┌──────────────────────────────────────┐
│        Specialized Sub-Agent         │
└──────────────────┬───────────────────┘
                   │ (calls)
                   ▼
┌──────────────────────────────────────┐
│           Gemini API Call            │
│  - Captures usage metadata:          │
│    * input_tokens                    │
│    * output_tokens                   │
│    * total_tokens                    │
└──────────────────┬───────────────────┘
                   │ (publishes OTel events)
                   ▼
┌──────────────────────────────────────┐
│    OpenTelemetry GenAI Collector     │
└──────────────────┬───────────────────┘
                   │ (exports)
                   ▼
┌──────────────────────────────────────┐
│          Google Cloud Storage        │
│       (JSONL partition logs)         │
└──────────────────────────────────────┘
```

### Telemetry Context Propagation

The Vertex AI GenAI SDK supports OpenTelemetry instrumentation. Context variables are propagated using **OTel Baggage** or custom span/resource attributes.

#### Context Variables Required on Every API Call

| Attribute Key | Description | Example |
| :--- | :--- | :--- |
| `gen_ai.request.user_id` | Unique ID of the customer | `usr_99283` |
| `gen_ai.request.session_id` | Unique chat session ID | `sess_441029` |
| `gen_ai.request.agent_name` | Name of the active sub-agent | `oracle_to_bigquery_translator` |
| `gen_ai.request.project_id` | GCP Project ID | `my-fsi-prod-project` |

### The Proposed Solution

#### Option A: Serverless ELT via Google Cloud Storage (Recommended)

Separates collection from execution — no latency overhead for users.

1. **Instrumentation Setup** in `agent_bar_v2/app_utils/telemetry.py`:
   ```python
   import os

   def setup_telemetry():
       os.environ["GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY"] = "true"
       os.environ["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"] = "NO_CONTENT"  # Metadata only
       os.environ["OTEL_INSTRUMENTATION_GENAI_UPLOAD_FORMAT"] = "jsonl"
       os.environ["OTEL_INSTRUMENTATION_GENAI_COMPLETION_HOOK"] = "upload"
       os.environ["OTEL_INSTRUMENTATION_GENAI_UPLOAD_BASE_PATH"] = f"gs://{LOGS_BUCKET}/completions"
   ```

2. **JSONL Output Log Structure** — on completion of any LLM call:
   ```json
   {
     "event_time": "2026-07-01T17:42:21.082Z",
     "service_name": "adk-multiagent",
     "attributes": {
       "gen_ai.request.user_id": "usr_99283",
       "gen_ai.request.session_id": "sess_441029",
       "gen_ai.request.agent_name": "oracle_to_bigquery_translator",
       "gen_ai.request.project_id": "my-fsi-prod-project",
       "gen_ai.response.model": "gemini-2.5-flash"
     },
     "usage": {
       "input_tokens": 14205,
       "output_tokens": 2840,
       "total_tokens": 17045
     }
   }
   ```

#### Option B: Transactional Logging via Firestore

Use when real-time budget enforcement or hard per-user billing limits are required. A callback hook increments and validates quotas **before** making model calls.

```python
from google.adk.agents.callback_context import CallbackContext
from google.cloud import firestore

db = firestore.Client()

def check_user_quota_callback(callback_context: CallbackContext):
    user_id = callback_context.state.get("user_id")
    user_ref = db.collection("users").document(user_id)
    doc = user_ref.get()
    if doc.exists:
        daily_spend = doc.to_dict().get("daily_spend_usd", 0.0)
        daily_limit = doc.to_dict().get("daily_limit_usd", 5.0)
        if daily_spend >= daily_limit:
            raise PermissionError(f"User {user_id} has exceeded daily token limit.")
```

### Cost Aggregation & Analytics (BigQuery)

Create a BigQuery external table pointing directly at the GCS telemetry bucket — no double ingestion cost.

#### External Table DDL
```sql
CREATE OR REPLACE EXTERNAL TABLE `my-gcp-project.telemetry.genai_usage_logs`
OPTIONS (
  format = 'JSON',
  uris   = ['gs://my-logs-bucket/completions/*.jsonl']
);
```

#### Aggregation Queries

**Total cost & tokens per user:**
```sql
SELECT
  attributes.gen_ai_request_user_id                       AS user_id,
  COUNT(1)                                                 AS total_model_calls,
  SUM(usage.input_tokens)                                  AS total_input_tokens,
  SUM(usage.output_tokens)                                 AS total_output_tokens,
  SUM(usage.total_tokens)                                  AS total_tokens,
  SUM(
    CASE
      WHEN attributes.gen_ai_response_model LIKE '%flash%'
        THEN (usage.input_tokens * 0.000075 / 1000) + (usage.output_tokens * 0.0003 / 1000)
      WHEN attributes.gen_ai_response_model LIKE '%pro%'
        THEN (usage.input_tokens * 0.00125 / 1000)  + (usage.output_tokens * 0.005 / 1000)
      ELSE 0.0
    END
  )                                                        AS total_cost_usd
FROM  `my-gcp-project.telemetry.genai_usage_logs`
GROUP BY user_id
ORDER BY total_cost_usd DESC;
```

**Cost distribution by agent:**
```sql
SELECT
  attributes.gen_ai_request_agent_name                    AS agent_name,
  SUM(usage.total_tokens)                                  AS total_tokens,
  SUM(
    CASE
      WHEN attributes.gen_ai_response_model LIKE '%flash%'
        THEN (usage.input_tokens * 0.000075 / 1000) + (usage.output_tokens * 0.0003 / 1000)
      ELSE 0.0
    END
  )                                                        AS total_cost_usd
FROM  `my-gcp-project.telemetry.genai_usage_logs`
GROUP BY agent_name
ORDER BY total_cost_usd DESC;
```

**Session-level trace:**
```sql
SELECT
  event_time,
  attributes.gen_ai_request_agent_name   AS agent_name,
  attributes.gen_ai_response_model        AS model,
  usage.total_tokens                      AS tokens,
  usage.input_tokens                      AS input,
  usage.output_tokens                     AS output
FROM  `my-gcp-project.telemetry.genai_usage_logs`
WHERE attributes.gen_ai_request_session_id = 'sess_441029'
ORDER BY event_time ASC;
```

### Identity & Context Extraction by Deployment Pattern

#### Scenario A: Cloud Run UI Secured with IAP

When users access the Agent UI via Google Cloud IAP, IAP injects identity headers into each request.

```
[ User Browser ]
       │ (Requests protected page)
       ▼
┌──────────────────────────────┐
│  Google Cloud IAP (OAuth)    │  ── Validates user session
└──────────────┬───────────────┘
               │ (Injects assertion headers)
               ▼
┌──────────────────────────────┐
│  Cloud Run Frontend (UI)     │  ── Decodes & verifies IAP JWT
└──────────────┬───────────────┘
               │ (Passes verified email/ID in request context)
               ▼
┌──────────────────────────────┐
│  Agent BFF / ADK Backend     │  ── Populates telemetry baggage
└──────────────────────────────┘
```

IAP injects three headers:
- `x-goog-authenticated-user-id` — unique alphanumeric user ID
- `x-goog-authenticated-user-email` — e.g. `user@enterprise.com`
- `x-goog-iap-jwt-assertion` — signed JWT containing user details

FastAPI middleware example:
```python
@app.middleware("http")
async def add_identity_context(request: Request, call_next):
    jwt_assertion = request.headers.get("x-goog-iap-jwt-assertion")
    if jwt_assertion:
        user_info = verify_iap_jwt(jwt_assertion)  # Decodes & verifies signature
        request.state.user_id = user_info["email"]
    else:
        request.state.user_id = "anonymous"
    return await call_next(request)
```

When launching the ADK session, `user_id` from IAP is set on `CallbackContext.state`, which automatically propagates into the OTel span resource.

#### Scenario B: Agent Exposed as a Gemini Enterprise Extension

When the agent is exposed inside Gemini Enterprise (via Extensions), the execution trigger shifts to the Gemini orchestrator.

```
[ User in Gemini UI ]
       │ (Prompts: "@MyAgent review this contract")
       ▼
┌──────────────────────────────┐
│     Gemini Enterprise        │  ── Authenticates user session
└──────────────┬───────────────┘
               │ (Triggers Extension callback via OAuth 2.0)
               ▼
┌──────────────────────────────┐
│    ADK extension endpoint    │  ── Verifies Bearer Token
└──────────────────────────────┘
```

Gemini sends callbacks using OAuth 2.0 Bearer tokens. Token claims contain:
- `email` — user email (maps to `user_id`)
- `hd` — hosted domain, e.g. `my-enterprise.com` (maps to `project_id` / `workspace_id`)
- `session_id` — parsed from the Gemini invocation session trace ID

### Benefits
- Full cost attribution per user, session, agent, and project with zero platform coupling
- No latency added to the hot path — GCS upload is async post-completion
- BigQuery external table = zero ingestion cost, SQL-native analysis
- Firestore option enables hard real-time budget enforcement when needed
- Works with both IAP-secured Cloud Run and Gemini Enterprise Extension deployments

---

## 4. IAM Deny Policy — Block Direct Reasoning Engine Access (Gateway Bypass)
**Status:** Blocked — IAM v2 API unreachable from deployment environment  
**Category:** Security / Access Control  
**Discovered:** July 2, 2026

### The Problem

Any GCP principal with `roles/owner` (including the Vertex AI Agent Playground's logged-in user) can invoke the Reasoning Engine's `streamQuery` or `query` API directly using their own identity credentials. This call reaches the RE without going through the Agent Gateway's ingress authz extension, meaning:

- Model Armor, DLP, and SGP content policies are **not evaluated** for direct calls
- The gateway is an advisory routing hint, not a mandatory enforcement boundary
- The Playground can successfully instruct the agent to fetch external URLs that bypass the egress allowlist if the model hallucinates a response instead of using `fetch_url`

### What Was Tried

An `IAM Deny Policy` (IAM v2 API) was the correct fix — it can override `roles/owner` and deny `aiplatform.googleapis.com/reasoningEngines.query` + `streamQuery` for all human principals, with exceptions only for the gateway SA and Vertex AI service agents.

However, the IAM v2 API endpoint (`iam.googleapis.com/v2/policies`) is **not reachable** from this deployment environment (network-level block). Both Terraform (`google_iam_deny_policy`) and direct REST API calls (`curl`) time out or return 404.

### Current Mitigations (Defence in Depth)

The following layers are active and enforce security for the **majority** of real-world attacks, but do not close the IAM Deny gap:

| Layer | Mechanism | What it blocks |
|---|---|---|
| 1 | RE `agentGatewayConfig.clientToAgentConfig` | Content violations via authz extension (PI, DLP, RAI) |
| 2 | RE `agentGatewayConfig.agentToAnywhereConfig` | Outbound traffic to non-allowlisted hosts (PSC routing) |
| 3 | `fetch_url()` `[GATEWAY BLOCKED]` messages | Model hallucination when egress is blocked |
| 4 | Gateway SA `roles/aiplatform.reasoningEngines.queryer` | Explicit audit trail for gateway-mediated calls |

### Paths to Close the Gap

**Option A: IAM Deny Policy (Preferred)** — once the IAM v2 API is reachable:
```hcl
resource "google_iam_deny_policy" "block_direct_re_access" {
  provider     = google-beta
  parent       = "cloudresourcemanager.googleapis.com/projects/${data.google_project.project.number}"
  name         = "${var.prefix}-block-direct-re-access"
  rules {
    deny_rule {
      denied_principals    = ["principalSet://goog/public:all"]
      exception_principals = [
        "principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/serviceAccounts/service-${PROJECT_NUMBER}@gcp-sa-agentgateway.iam.gserviceaccount.com",
        "principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/serviceAccounts/service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com",
        "principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/serviceAccounts/service-${PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com",
      ]
      denied_permissions = [
        "aiplatform.googleapis.com/reasoningEngines.query",
        "aiplatform.googleapis.com/reasoningEngines.streamQuery",
      ]
    }
  }
}
```

**Option B: VPC Service Controls** — Create a VPC-SC perimeter around `aiplatform.googleapis.com` that restricts RE access to requests originating from the Agent Gateway's network attachment. This is network-level enforcement that doesn't require IAM v2.

**Option C: Scoped IAM Roles** — Remove `roles/owner` from human principals and grant minimal scoped roles (e.g. `roles/aiplatform.viewer`, `roles/aiplatform.user`) that do NOT include `reasoningEngines.query`. Humans access the RE only via the Playground's gateway-mediated path using a service account with the `reasoningEngines.queryer` role.

### Benefits (when closed)
- 100% of RE traffic enforced through gateway — no bypass path
- All content policies (MA/DLP/SGP) apply universally regardless of client
- Audit logs show only gateway SA calls to the RE, not raw user calls

---

## 5. [Template for Future Enhancement]
**Status:** Idea / Planned  
**Category:** [e.g. Networking, Terraform, Security]  

### The Problem
[Describe the current limitation or technical debt]

### The Proposed Solution
[Describe the architecture or code changes required to implement the fix]

### Benefits
[List the benefits of this enhancement]

---
