---
name: agent-gateway-deploy-patch
description: >
  Use this skill when deploying Reasoning Engines with Agent Gateway config in
  an org-policy-enforced GCP environment. It documents the .pth monkey-patch
  pattern that injects agentGatewayConfig into CreateReasoningEngine calls,
  avoiding the code 13 (INTERNAL) error caused by missing gateway fields.
  MUST be read before modifying _gateway_patch.py or deploy.sh gateway logic.
---

# Agent Gateway Deploy Patch

## Overview

In GCP environments with custom Org Policies, every Reasoning Engine (RE)
**must** be created with `agentGatewayConfig` inside `spec.deploymentSpec`.
The native `adk deploy agent_engine` CLI has **no flag** for this field.
Without intervention, the deploy sends a POST payload missing the field →
Org Policy constraint evaluates → **gRPC INTERNAL (code 13)**.

## Critical Findings & Operational Updates (Post-Org Migration)

> [!IMPORTANT]
> **Key Operational Findings & Updates**
>
> 1. **agentGatewayConfig injection CRASHES containers (code 13)**:
>    In the `agentic-security-prd` project (`446959546335`), injecting `agentGatewayConfig` into `CreateReasoningEngine` or `UpdateReasoningEngine` causes the container to crash on startup with error code 13 (`INTERNAL`). This occurs on **BOTH CREATE and PATCH** operations. The root cause is likely the gateway infrastructure (PSC network attachment, SWP) needing reconfiguration after org migration.
>
> 2. **Two-Step Working Pattern**:
>    The recommended working pattern is two-step:
>    - **Step 1**: CREATE Reasoning Engines *without* gateway config (works reliably).
>    - **Step 2**: Optionally PATCH to add gateway config later (currently crashes until gateway infrastructure is reconfigured).
>
> 3. **Org Policy does NOT enforce agentGatewayConfig**:
>    In the `agentic-security-prd` project, Reasoning Engines can be created successfully without `agentGatewayConfig`. The org policy constraint may have been relaxed or removed during the org migration.
>
> 4. **Project Number vs. Project Name**:
>    Gateway resources in the `networkservices` API are keyed by **project NUMBER** (`446959546335`), not project NAME (`agentic-security-prd`). `versions.env` was updated to use project number for gateway URIs.
>
> 5. **`_gateway_patch.py` updated to SKIP gateway injection on POST (CREATE)**:
>    The patch script now passes through POST (CREATE) requests without modifying the body. PATCH injection logic remains in the code but currently causes code 13 until gateway infra is fixed.
>
> 6. **Dependency pinning fix (`xray_specialist`)**:
>    `xray_specialist` had pinned `google-adk==1.35.2`, which caused `code 3` (build failure). This was fixed by updating the requirement to `google-adk>=1.5.0`.
>
> 7. **Bootstrap block accumulation in `deploy.sh`**:
>    `deploy.sh`'s `merge_agent_vertex_env` function keeps prepending bootstrap blocks on every deployment run, inflating `agent.py` files. Always check and deduplicate `agent.py` files before each deploy.

## Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────────────────────┐
│ deploy.sh   │────▶│ .pth auto-import │────▶│ _gateway_patch.py            │
│ (calls ADK) │     │ at Python startup│     │ patches AuthorizedSession    │
└─────────────┘     └──────────────────┘     │ .send() to inject gateway    │
                                              │ config into every POST       │
                                              │ /reasoningEngines            │
                                              └──────────────────────────────┘
```

## Files

| File | Location | Purpose |
|------|----------|---------|
| `_gateway_patch.py` | `<venv>/lib/python3.12/site-packages/` | The monkey-patch (auto-loaded) |
| `_gateway_patch.pth` | `<venv>/lib/python3.12/site-packages/` | Triggers auto-import at Python startup |
| `patch_sdk_for_rest_create.py` | `scripts/` | Generator script that writes both files |
| `versions.env` | `agentic-lens/app/` | Defines `AGENT_GATEWAY_INGRESS` and `AGENT_GATEWAY_EGRESS` |

## What the Patch Injects

```json
{
  "spec": {
    "identityType": "AGENT_IDENTITY",
    "deploymentSpec": {
      "agentGatewayConfig": {
        "clientToAgentConfig":   { "agentGateway": "<INGRESS>" },
        "agentToAnywhereConfig": { "agentGateway": "<EGRESS>" }
      },
      "env": [
        { "name": "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY", "value": "true" },
        { "name": "agent_name",       "value": "..." },
        { "name": "agent_department", "value": "..." }
      ]
    }
  }
}
```

## What the Patch Strips

- **`contextSpec`** — SDK 1.149+ auto-injects `contextSpec.memoryBankConfig`
  pointing to `gemini-3.5-flash`. That model is only available via the global
  Vertex AI endpoint; the RE container tries to initialize it against the
  regional endpoint on startup and crashes with `FAILED_PRECONDITION`.

## How to Apply

```bash
# 1. Set env vars in versions.env
AGENT_GATEWAY_INGRESS=projects/<PROJECT_ID>/locations/<REGION>/agentGateways/<ingress-gw>
AGENT_GATEWAY_EGRESS=projects/<PROJECT_ID>/locations/<REGION>/agentGateways/<egress-gw>

# 2. Run the generator script (writes both files to venv)
.venv/bin/python scripts/patch_sdk_for_rest_create.py \
    --ingress "$AGENT_GATEWAY_INGRESS" \
    --egress  "$AGENT_GATEWAY_EGRESS" \
    --venv    agentic-lens/app/agentic-lens/.venv

# 3. Deploy normally — patch fires automatically
SKIP_PREFLIGHT=1 bash deploy.sh chat
```

## Critical Rules — DO NOT VIOLATE

> [!CAUTION]
> ### Never inject an empty `contextSpec`
> ```python
> # ❌ NEVER DO THIS — causes code 13 (container crash)
> body["contextSpec"] = {}
> ```
> An empty `contextSpec` forces the server to initialize a memory bank context
> with no valid configuration. The container crashes on startup → code 13.
> The correct behavior is to **strip** `contextSpec` if present, and
> **not re-add it**.

> [!CAUTION]
> ### Never put `agent_gateway_config` in BOTH the JSON config AND the patch
> ```python
> # ❌ NEVER have gateway config in .agent_engine_config.json
> # when the .pth patch is also injecting it
> {"agent_gateway_config": {...}}  # in .agent_engine_config.json
> ```
> The `.pth` patch handles injection at the HTTP transport layer.
> Having it in the JSON config creates **duplication** — the SDK serializes
> it once, then the patch adds it again. Remove `agent_gateway_config` from
> all `.agent_engine_config.json` files.

> [!NOTE]
> ### Both project ID and project number work in gateway paths
> ```bash
> # Both are valid:
> AGENT_GATEWAY_INGRESS=projects/446959546335/locations/...
> AGENT_GATEWAY_INGRESS=projects/agentic-security-prd/locations/...
> ```
> The Network Services API lists gateways with project ID, but the
> working supervisor engine uses project NUMBER in its `agentGatewayConfig`.
> Either format is accepted. **The gateway binding failure post-org-migration
> is NOT caused by the path format** — it affects both formats equally.

> [!WARNING]
> ### The patch intercepts ALL POST /reasoningEngines requests
> This means it fires for both CREATE and any other POST to that endpoint.
> The `_inject_gateway` function must be idempotent.

## IAM Prerequisites

The following roles must be granted to the Vertex AI service agents:

```bash
# RE service agent needs Network Services access to bind gateways
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-aiplatform.iam.gserviceaccount.com" \
  --role="roles/networkservices.admin"

gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-aiplatform-re.iam.gserviceaccount.com" \
  --role="roles/networkservices.admin"
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `code: 13` or `400 FAILED_PRECONDITION` (all 4 constraints) | Newer `google-cloud-aiplatform` switched transport from `AuthorizedSession` → `agentplatform.Client` — patch interceptors don't fire | Pin `google-cloud-aiplatform[adk,agent_engines]==1.149.0` and `google-adk==1.31.1` in the deploy `.venv` pip install. Delete `.venv` and re-run deploy. |
| `ValidationError: 1 validation error for GatewayAgent` (container startup crash) | RE container `requirements.txt` is unpinned — installs newer ADK that changed the `Agent` Pydantic `model` field type | Pin `google-adk==1.31.1` in `agents/chat-agent/requirements.txt`. Both the deploy `.venv` AND the container requirements must be pinned. |
| `code: 13` on CREATE | Missing `agentGatewayConfig` or bad `contextSpec` | Verify patch is loaded (check stderr for `[gateway_patch]` messages). Ensure no `contextSpec: {}`. |
| `SyntaxError` in `_gateway_patch.py` | Broken f-strings or edit artifacts | Re-run `patch_sdk_for_rest_create.py` to regenerate a clean copy. |
| `[gateway_patch] No AGENT_GATEWAY_INGRESS/EGRESS — skipping.` | Env vars not set | Export `AGENT_GATEWAY_INGRESS` and `AGENT_GATEWAY_EGRESS` in the shell before `deploy.sh`. They must be in `versions.env`. |
| Gateway config not appearing in body | Patch not loaded at startup | Check `_gateway_patch.pth` exists in site-packages and contains `import _gateway_patch`. |
| `code: 9` (FAILED_PRECONDITION) on query | Engine deployed without gateway but org policy requires it | Redeploy with gateway config enabled. |

## Debugging the Patch

Add temporary logging to `_inject_gateway()` to inspect the body:

```python
# Add inside _inject_gateway, before return body:
print("[gateway_patch] spec keys: %s" % list(body.get('spec', {}).keys()),
      file=_sys.stderr, flush=True)
print("[gateway_patch] deploymentSpec keys: %s" % list(ds.keys()),
      file=_sys.stderr, flush=True)
```

**Never use multi-line f-strings** in the patch file — they break when the
heredoc/pth loader processes them. Use `%` formatting instead.

## Verification

After deploying, verify gateway config is bound:

```bash
TOKEN=$(gcloud auth application-default print-access-token)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://REGION-aiplatform.googleapis.com/v1beta1/projects/PROJECT_ID/locations/REGION/reasoningEngines/ENGINE_ID" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('spec',{}).get('deploymentSpec',{}).get('agentGatewayConfig',{}), indent=2))"
```
