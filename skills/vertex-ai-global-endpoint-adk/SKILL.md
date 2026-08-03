---
name: vertex-ai-global-endpoint-adk
description: >
  Use this skill when building or debugging ADK agents that call Gemini 3.x
  models (gemini-3.1-pro-preview, gemini-2.5-pro, gemini-3.5-flash, etc.) from
  a regionally deployed Cloud Run service OR a Vertex AI Reasoning Engine behind
  Agent Gateway. These models are only available via the Vertex AI global
  endpoint — regional endpoints return 404/model-not-found.

  CRITICAL FOR AGENT GATEWAY: The Model Armor egress authz policy MUST NOT have
  hosts { exact = "aiplatform.googleapis.com" } — the regional MA extension
  returns PERMISSION_DENIED for global-endpoint requests, producing a 500 with
  empty message. Remove the exact match and rely on GOOGLE_CLOUD_LOCATION=global
  in the container .env to route inference. See Section 5 for the full fix.

  Read this BEFORE building any agent with a Gemini 3.x model OR before
  debugging 500 empty-message errors from agents using gemini-3.5-flash.
---

# Gemini 3.x via Vertex AI Global Endpoint — ADK + Agent Gateway

## 1. The Problem

Gemini 3.x models are **only served from the Vertex AI global endpoint**:

```
https://aiplatform.googleapis.com   (location = "global")
```

Regional endpoints return 404 or invalid-location errors:

```
404 GET https://us-east1-aiplatform.googleapis.com/v1/.../gemini-3.5-flash
{"error": {"code": 404, "message": "Model not found"}}
```

ADK's `Gemini` base class constructs its endpoint URL from the
`GOOGLE_CLOUD_LOCATION` env var. If that env var is `us-east1`, the regional
URL is used — gemini-3.5-flash returns 404.

---

## 2. Two Deployment Contexts — Different Approaches

### Context A: Cloud Run (no Agent Gateway)

Override the `api_client` property in a `GlobalGemini` subclass:

```python
import os
from google import genai
from google.adk.models.google_llm import Gemini

class GlobalGemini(Gemini):
    """Routes inference to the global Vertex AI endpoint for Gemini 3.x models."""
    @property
    def api_client(self):
        project = (
            os.environ.get("GCP_PROJECT_ID") or
            os.environ.get("GOOGLE_CLOUD_PROJECT")
        )
        return genai.Client(vertexai=True, project=project, location="global")
```

Use exactly where you'd use `Gemini()`:

```python
from google.adk import Agent

agent = Agent(
    name="my_agent",
    model=GlobalGemini(model="gemini-3.5-flash"),
    ...
)
```

### Context B: Vertex AI Reasoning Engine + Agent Gateway

**Do NOT use the `api_client` override.** Use env vars instead:

```bash
# In the container .env (written by deploy_global_agent.sh)
GOOGLE_CLOUD_LOCATION=global   # → ADK Gemini routes to aiplatform.googleapis.com
GCP_REGION=us-east1            # → RE control-plane, sessions, OTEL use real region
```

The `GatewayAgent` SDK passes `model` as a plain string to ADK's `Gemini` class.
ADK reads `GOOGLE_CLOUD_LOCATION` and constructs the global URL automatically.
No `api_client` override needed.

```python
# agents/global-agent/agent.py — no api_client override
root_agent = GatewayAgent(
    name="global_agent",
    model="gemini-3.5-flash",   # plain string; GatewayAgent wraps with GlobalGemini
    ...
)
```

Deploy with:
```bash
bash scripts/deploy_global_agent.sh
# Sets GOOGLE_CLOUD_LOCATION=global and GCP_REGION=us-east1 in .env
```

---

## 3. WHY Two Different Approaches

In Cloud Run (Context A), the env var approach also works but causes a different
problem: `GOOGLE_CLOUD_LOCATION=global` breaks session management because ADK
uses this var for session API calls too (which don't accept "global" as a
region). Cloud Run manages its own sessions differently so the api_client
property override is cleaner and scoped.

In Reasoning Engine (Context B), the RE platform manages sessions separately
from the model inference call. `GCP_REGION` provides the real region for
non-model calls while `GOOGLE_CLOUD_LOCATION=global` only affects model
inference URL construction. This is the pattern used in Google's official
reference implementation:
`cloud-networking-solutions/demos/agent-gateway`

---

## 4. Side-by-Side: Regional vs Global Agents in the Foundation

| | `agents/chat-agent/` | `agents/global-agent/` |
|---|---|---|
| Model | `gemini-2.5-flash` | `gemini-3.5-flash` |
| Container env | `GOOGLE_CLOUD_LOCATION=us-east1` | `GOOGLE_CLOUD_LOCATION=global` |
| Endpoint constructed | `us-east1-aiplatform.googleapis.com` | `aiplatform.googleapis.com` |
| Deploy script | `deploy_chat_agent.sh` | `deploy_global_agent.sh` |
| `api_client` override | Not needed | Not needed (env var sufficient) |
| Model Armor egress | Screened (suffix match) | NOT screened (exact match removed — see §5) |

---

## 5. CRITICAL: Model Armor Egress Fix for Global Endpoint

> ⚠️ **THIS IS A PRODUCTION BLOCKER.** If you skip this, gemini-3.5-flash
> returns `500 Internal Server Error` with empty message.

### The Problem

The MA egress policy `http_rules` intercepts requests matching the host rules
and sends them to the MA authz extension for content screening. The extension
service is **regional**: `modelarmor.us-east1.rep.googleapis.com`.

If the http_rules include `hosts { exact = "aiplatform.googleapis.com" }`,
requests to the global endpoint are routed to the regional MA extension.
The regional MA extension **cannot process global endpoint requests** and
returns `PERMISSION_DENIED` at the header level. The Agent Gateway translates
this into a `500` with empty message — the agent appears to respond but
returns nothing.

### Diagnosis

Check gateway logs with this filter:
```
resource.type="networkservices.googleapis.com/Gateway"
resource.labels.gateway_name="YOUR_EGRESS_GATEWAY"
severity>=WARNING
```

Key fields indicating this failure:
- `authzPolicyInfo.result: DENIED`
- `serviceExtensionInfo.grpcStatus: PERMISSION_DENIED`
- `enforcedGatewaySecurityPolicy.matchedRules.action: ALLOWED`

> The SWP and MA layers are independent — SWP can ALLOW while MA DENIES.
> This makes the failure especially confusing.

### The Fix — Terraform

Remove `hosts { exact = "aiplatform.googleapis.com" }` from the MA egress
policy `http_rules`. Keep ONLY the suffix match for regional endpoints:

```hcl
# 03_security_and_gateways.tf — egress_ma_policy http_rules
http_rules {
  to {
    operations {
      # Regional endpoint ONLY — suffix matches us-east1-aiplatform.googleapis.com etc.
      # DELIBERATELY OMIT: hosts { exact = "aiplatform.googleapis.com" }
      # The regional MA extension (modelarmor.us-east1.rep.googleapis.com) returns
      # PERMISSION_DENIED for global endpoint requests → 500 empty message.
      # Global endpoint requests bypass MA but are still subject to model-level
      # Gemini safety filters which are always active and cannot be bypassed.
      hosts { suffix = ".aiplatform.googleapis.com" }
      paths { contains = "generatecontent"; ignore_case = true }
      paths { contains = "predict";         ignore_case = true }
      paths { contains = "streamquery";     ignore_case = true }
      paths { contains = "sessions";        ignore_case = true }
      paths { contains = "events";          ignore_case = true }
    }
  }
}
```

> After this fix, requests to `aiplatform.googleapis.com` (global) do NOT
> match the http_rules and are therefore NOT sent to the MA extension.
> They pass through the SWP routing layer unscreened by Model Armor.
> Gemini's built-in harm filters remain active at the model layer.

### Quick Fix via gcloud (for existing deployments)

If you need to fix a live deployment without running terraform apply, you can
update the authz policy via the REST API. The safest path is terraform apply
after updating the http_rules block.

---

## 6. Host Registration in Agent Registry

The Agent Registry (Vertex AI control plane) must have `aiplatform.googleapis.com`
registered as an allowed egress host. In Terraform, this is already covered by
the foundation's `allowed_egress_hosts` list in `terraform.tfvars`:

```hcl
allowed_egress_hosts = [
  ...
  "aiplatform.googleapis.com"   # required for global endpoint (Gemini 3.x)
]
```

The host is registered in the Agent Registry AND added to the SWP egress
routing rules by the Terraform foundation. No additional changes needed for
SWP-level routing — only the MA authz policy needs the fix above.

---

## 7. Model Selection Guide

| Task | Model | Endpoint |
|---|---|---|
| Standard chat, coding assistant | `gemini-2.5-flash` | regional |
| Heavy reasoning, long context analysis | `gemini-2.5-pro` | regional |
| Latest generation, fastest 3.x | `gemini-3.5-flash` | **global** |
| Deep reasoning, complex architecture | `gemini-3.1-pro-preview` | **global** |
| Lightweight 3.x tasks | `gemini-3.1-flash-lite` | **global** |

---

## 8. `GCP_REGION` — The Critical Second Env Var

When using `GOOGLE_CLOUD_LOCATION=global` in an RE deployment, ALL API calls
that use `GOOGLE_CLOUD_LOCATION` for the region would use `global` — including
session management and RE control-plane calls that don't accept `global`.

The fix is `GCP_REGION` — a separate env var that `GatewayAgent` uses for
non-model API calls:

```bash
# Container .env written by deploy_global_agent.sh:
GOOGLE_CLOUD_LOCATION=global   # model inference → aiplatform.googleapis.com
GCP_REGION=us-east1            # sessions, RE API, OTEL → us-east1-aiplatform...
```

The `deploy_global_agent.sh` script uses `GCP_REGION` (not
`GOOGLE_CLOUD_LOCATION`) for all RE control-plane calls (cleanup, contextSpec
PATCH, state polling, verification).

---

## 9. Checking Regional Model Availability

When a Gemini 3.x model becomes available at a regional endpoint, revert:

```bash
# Check if gemini-3.5-flash is now available regionally
curl -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://us-east1-aiplatform.googleapis.com/v1/publishers/google/models" \
  | python3 -c "import json,sys; [print(m['name']) for m in json.load(sys.stdin).get('publisherModels',[]) if 'gemini-3' in m.get('name','')]"
```

If available, switch the `.env` back to `GOOGLE_CLOUD_LOCATION=us-east1` (or
use `deploy_chat_agent.sh`). The MA egress `exact` match can then be restored.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `500` empty message, global-endpoint agent | MA egress `exact` match blocks global requests | Remove `hosts { exact = "aiplatform.googleapis.com" }` from MA egress http_rules |
| `404 Model not found` on regional endpoint | Model only on global endpoint | Set `GOOGLE_CLOUD_LOCATION=global` in container .env OR use `api_client` override (Cloud Run only) |
| `authzPolicyInfo.result: DENIED` in gateway logs | MA PERMISSION_DENIED on global endpoint | Same as above — remove exact match |
| Session management fails with `global` region | `GOOGLE_CLOUD_LOCATION=global` used for session API | Add `GCP_REGION=us-east1` as separate env var; deploy script must use it for RE API calls |
| `403 PERMISSION_DENIED` on global endpoint | SA missing `roles/aiplatform.user` | Grant to RE SA |
| Quota exhausted on global endpoint | Separate quota pool from regional | Request quota increase for `aiplatform.googleapis.com` globally |
| `invalid argument: location` | Wrong location string | Use exactly `"global"` (not `"us"`, `"worldwide"`) |
