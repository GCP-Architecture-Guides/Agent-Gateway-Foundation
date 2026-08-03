---
name: agw-egress-iap-pitfall
description: >
  CRITICAL: Read this skill BEFORE adding any IAP REQUEST_AUTHZ policy to an
  Agent Gateway egress gateway. IAP identity validation on egress BREAKS all
  outbound HTTP from Reasoning Engine containers because they don't carry
  IAP tokens on outbound calls. This skill documents the root cause, the
  misleading error message, how to diagnose it, and the correct architecture.
  Also read this when debugging 403 "Egress request is not authorized. The
  endpoint is either incorrect or unregistered" errors — the error is NOT
  about endpoint registration; it's about IAP identity validation.
---

# Agent Gateway: IAP on Egress is a Trap

## Overview

Applying an IAP `REQUEST_AUTHZ` authz policy to an Agent Gateway **egress**
gateway (`AGENT_TO_ANYWHERE`) will silently break ALL outbound HTTP from
every Reasoning Engine in the project. This includes LLM calls, OTEL
telemetry, session management — everything.

> [!CAUTION]
> **NEVER apply IAP REQUEST_AUTHZ to an egress gateway.**
> IAP identity validation is for INGRESS only.

---

## Production Post-Mortem (2026-08-03)

- **Project**: `charter-poc-test` (185602934768)
- **Impact**: ALL Reasoning Engines → zero LLM responses
- **Duration**: ~2 days of debugging
- **Resolution**: Deleting one authz policy (2 minutes)
- **Agents affected**: chat-agent, ran-security, ran-orchestrator, and all others

### The Symptom

Every agent returned HTTP 200 with **empty responses** — no LLM content,
no tool calls, nothing. No obvious errors surfaced.

```json
{
  "message": "Egress request is not authorized. The endpoint is either incorrect or unregistered in the Agent Registry.",
  "status": "Forbidden"
}
```

> [!CAUTION]
> **HTTP 200 ≠ working.** ADK's `streamQuery` returns HTTP 200 even when
> the internal LLM call fails with a 403. The empty response body was the
> only signal — we missed it for an entire day. Always verify the response
> body contains actual LLM content, not just a 200 status.

### Wrong Hypotheses (Day 1)

We initially observed that `chat-agent` (agentFramework: `google-adk`)
returned HTTP 200 while `ran-security` (agentFramework: `a2a`) returned
400/500. This led to a false hypothesis:

> *"The `a2a` framework label causes Vertex AI to skip egress sidecar provisioning."*

We spent a full day trying to fix the wrong thing:

| Attempt | Result |
|---|---|
| Spoof `agentFramework` to `google-adk` | ❌ Same 403 |
| Deploy via `adk deploy agent_engine` instead of `vertexai.Client` | ❌ Same 403 |
| Pin SDK versions to match chat-agent | ❌ Same 403 |
| Switch from global to regional Gemini endpoints | ❌ Same 403 |
| Inject `GOOGLE_CLOUD_LOCATION` env vars | ❌ Same 403 |
| Update IAP org ID in egressor binding | ❌ Same 403 |

### The Breakthrough (Day 2)

After deploying `ran-security` via the identical pipeline as `chat-agent`
and still getting 403, we checked `chat-agent` Cloud Logs. The chat-agent
had the **same error all along**. Its HTTP 200 was the ADK streaming framework
silently catching the error and returning an empty stream.

**Lesson: When ALL agents fail identically, it's infrastructure — not agent code.**

### Infrastructure Audit

Full read-only audit of all layers:

| Layer | Check | Status |
|---|---|---|
| Agent Gateways | `networkservices.googleapis.com` | ✅ Both exist and active |
| Agent Registry | `gcloud alpha agent-registry services list` | ✅ 22 endpoints registered |
| IAM (RE SA) | `roles/iap.httpsResourceAccessor` | ✅ Granted |
| IAP Web Policy | `roles/iap.egressor` | ✅ Granted to org pool |

Everything looked correct. Then we checked Cloud Logging:

```bash
gcloud logging read 'resource.type="iap_web" severity=ERROR' \
  --project=charter-poc-test --limit=10 --freshness=1h
```

Output:
```
method: AuthorizeUser
code: 7 (Permission Denied)
PRINCIPAL_EMAIL: (EMPTY)
```

IAP saw **no identity** on egress calls. The RE container's outbound HTTP
doesn't carry IAP tokens through the egress proxy. Case closed.

---

## The Misleading Error

```
google.genai.errors.ClientError: 403 Forbidden. {
  'message': 'Egress request is not authorized. The endpoint is either
   incorrect or unregistered in the Agent Registry.',
  'status': 'Forbidden'
}
```

This error makes it look like an **Agent Registry** problem — missing endpoint
registration. **It is NOT.** The error originates from the IAP extension
denying the request before endpoint lookup even happens.

> [!WARNING]
> This error message sent us to investigate the Agent Registry for hours.
> The actual cause was IAP identity validation. Always check `iap_web` logs
> first when you see this message.

---

## Root Cause: Why IAP on Egress Fails

### The Egress Call Flow

```
RE Container
    │ outbound HTTP (no IAP token)
    ▼
Egress PSC Proxy
    │ intercepts call
    ▼
IAP REQUEST_AUTHZ Extension
    │ AuthorizeUser() — looks for IAP bearer token
    │ finds PRINCIPAL_EMAIL = (empty)
    ▼
gRPC code 7: Permission Denied
    │ translated by egress proxy to misleading message:
    ▼
"Egress request is not authorized. The endpoint is either
 incorrect or unregistered in the Agent Registry."
```

### Why Ingress IAP Works But Egress Doesn't

| Direction | IAP behaviour | Works? |
|---|---|---|
| **Ingress** | External callers present OAuth/IAP tokens → IAP extracts identity → ALLOW | ✅ |
| **Egress** | RE container outbound HTTP carries no IAP token → IAP sees empty identity → DENY | ❌ |

IAP `REQUEST_AUTHZ` is designed to validate **who is calling into a service**.
On egress, the question is reversed — you're asking the container's *outbound
call* to prove its identity. RE containers don't attach IAP credentials to
outbound HTTP, so IAP always sees an empty principal and denies.

The `iap.egressor` grant and `roles/iap.httpsResourceAccessor` on the RE SA
don't help because IAP can't even extract an identity to check against those grants.

---

## How to Diagnose

### Step 1: Check IAP logs in Cloud Logging

```bash
gcloud logging read \
  'resource.type="iap_web" severity=ERROR method=AuthorizeUser' \
  --project=PROJECT_ID --limit=5 --freshness=30m \
  --format='table(timestamp, protoPayload.status.code, protoPayload.authenticationInfo.principalEmail)'
```

Look for: `code=7`, `principalEmail=(empty)` → IAP on egress is the cause.

### Step 2: List authz policies on the egress gateway

```bash
gcloud beta network-security authz-policies list \
  --project=PROJECT_ID --location=LOCATION \
  --format="table(name, action, policyProfile, target.resources)"
```

Look for any policy with `policyProfile: REQUEST_AUTHZ` targeting the egress gateway.

### Step 3: Verify response body — not just HTTP status

```python
resp = requests.post(url, json=payload, headers=headers, stream=True)
body = resp.text
# HTTP 200 with empty body = broken!
if not body.strip():
    raise AssertionError("BROKEN: 200 with empty body — internal LLM call failed")
assert '"text"' in body, "No LLM content in response"
```

---

## The Fix

### Immediate (gcloud delete)

```bash
gcloud beta network-security authz-policies delete ${PREFIX}-iap-egress-policy \
  --project=PROJECT_ID --location=LOCATION --quiet
```

### Permanent (Terraform)

The `egress_iap_policy` resource has been **removed** from
`03_security_and_gateways.tf` and replaced with a tombstone comment.
Do NOT re-add it. Running `terraform apply` will NOT recreate it.

If you accidentally added it back, running apply will **destroy it** (correct behaviour).

---

## Correct Architecture

### Egress Gateway — Allowed Policies

| Profile | Extension | Purpose | OK on Egress? |
|---|---|---|---|
| `CONTENT_AUTHZ` | Model Armor | Content safety screening | ✅ Yes |
| `CONTENT_AUTHZ` | SGP | Semantic governance | ✅ Yes |
| `REQUEST_AUTHZ` | IAP | Identity validation | ❌ **NO — BREAKS EVERYTHING** |

### Ingress Gateway — Allowed Policies

| Profile | Extension | Purpose | OK on Ingress? |
|---|---|---|---|
| `CONTENT_AUTHZ` | Model Armor | Content safety screening | ✅ Yes |
| `REQUEST_AUTHZ` | IAP | Identity validation | ✅ Yes |

### Working Policy Matrix (Post-Fix)

| Policy | Gateway | Profile | Purpose | Status |
|---|---|---|---|---|
| `{prefix}-iap-ingress-policy` | ingress | `REQUEST_AUTHZ` | Validates caller identity on inbound | ✅ Keep |
| `{prefix}-ma-policy` | ingress | `CONTENT_AUTHZ` | Model Armor on inbound prompts | ✅ Keep |
| `{prefix}-ma-egress-policy` | egress | `CONTENT_AUTHZ` | Model Armor on outbound LLM calls | ✅ Keep |
| `{prefix}-sgp-egress-policy` | egress | `CONTENT_AUTHZ` | SGP semantic governance on outbound | ✅ Keep |
| `{prefix}-iap-egress-policy` | egress | `REQUEST_AUTHZ` | IAP on outbound | ❌ DELETED |

### Rule of Thumb

- **Ingress**: IAP (who can call the agent) + Model Armor (what content is allowed in)
- **Egress**: Model Armor + SGP only (what the agent can send outbound). **No IAP. Ever.**

---

## Validation After Fix

Run an E2E smoke test immediately after removing the policy:

```bash
# Deploy guardrail tests
python3 foundation/test-agent/run_guardrail_tests.py \
  --project=PROJECT_ID --location=LOCATION --agent-name=AGENT_NAME
```

Expected results:

| Test | Expected |
|---|---|
| Greeting | ✅ Non-empty LLM response |
| Valid query | ✅ APPROVED with reasoning |
| SQL injection | ⚠️ Model Armor blocked (correct) |
| DELETE statement | ⚠️ Model Armor blocked (correct) |

---

## Lessons Learned

1. **Verify response CONTENT, not just HTTP status.** ADK `streamQuery` returns 200 with empty body on internal errors. Always check the response has actual text.

2. **IAP REQUEST_AUTHZ is for ingress only.** Never apply identity validation to outbound (egress) traffic — containers don't carry IAP tokens on outbound calls.

3. **When all agents fail identically, it's infrastructure.** If both `google-adk` and `a2a` framework agents fail the same way, the agent framework field isn't the cause.

4. **Cloud Logging is the single source of truth.** The `iap_web` logs with `AuthorizeUser` / `code=7` / empty `PRINCIPAL_EMAIL` gave the root cause in seconds — check there first.

5. **The error message is deliberately misleading.** "The endpoint is either incorrect or unregistered" made us investigate the Agent Registry for hours. The actual cause was IAP identity validation.
