---
name: sgp-network-authz-pattern
description: >
  CRITICAL: You MUST read this skill BEFORE creating or troubleshooting
  Semantic Governance Policies (SGP) in any Agent Gateway deployment.
  There are TWO SGP systems — the AI-native CLI path is a DEAD END.
  This skill documents the correct Network Authz pattern that actually works.
  Failure to follow this skill WILL waste hours chasing a deprecated API.
---

# SGP — Semantic Governance Policy via Network Authz

## ⚠️ The Two SGP Systems — Know the Difference

There are **two completely different SGP systems** and they collide constantly.
Using the wrong one is a guaranteed dead end.

| System | API Surface | Resource Path | Status |
|--------|------------|---------------|--------|
| ❌ AI-native SGP (regional AgentService) | `gcloud beta ai semantic-governance-policies` via regional AgentService | Needs `agents/AGENT_ID` from regional AgentService | **DEAD END** — AgentService not supported in any regional location |
| ✅ AI-native SGP (global agents) | `gcloud beta ai semantic-governance-policies` via global agents REST API | Creates `agents/` at `locations/global`, then NLC policies at regional SGP | **WORKS** — documented 2026-07-27 |
| ✅ Network Authz SGP | `google_network_security_authz_policy` + `google_network_services_authz_extension` | Applied directly to Agent Gateway | **GA — covers ALL agents at network layer** |

> [!IMPORTANT]
> **Two-layer approach**: Use Network Authz (Step 1-2 below) for gateway-level
> coverage of ALL agents, THEN add per-agent NLC policies (Step 4 below) for
> agent-specific business rules using global agents. Both layers are complementary.

> [!CAUTION]
> **DO NOT** try to create `agents/` via regional AgentService endpoints.
> `gcloud beta ai agents create` doesn't exist and the REST API returns
> `"AgentService not supported in this location"` in **every region**.
> **DO NOT** use Agent Registry `services/` entries for SGP — SGP rejects
> `services/` format. Only `agents/` format works, and those must be created
> at `locations/global` via REST API.

---

## Confirmed Dead End — Regional AgentService Path (Documented 2026-07-26)

This is the exact sequence that was tried and confirmed broken — do not repeat it:

```
SGP Engine ✅ (ACTIVE in target region)
     ↓
SGP Policy ❌  gcloud beta ai semantic-governance-policies create
     ↓ requires --agent="projects/.../locations/.../agents/SOME_ID"
Regional AgentService ❌  returns "AgentService not supported in this location"
     ↓ attempted workaround
gcloud alpha agent-registry services create  →  creates services/eng-coder
     ↓ SGP rejects it
"agents/" format required, "services/" format rejected — no bridge exists
```

**Agent Registry `services/` entries are a different resource type from `agents/`.**
SGP only accepts `agents/` format. Delete `services/` entries — they serve no purpose for SGP.

**The fix (discovered 2026-07-27):** Create `agents/` resources at `locations/global` via REST API
(see Step 4 below), then attach NLC policies via `gcloud beta ai semantic-governance-policies`.
Also use the Network Authz pattern (Steps 1-2) for gateway-level coverage.

---

## Quick Start — Minimum Viable SGP (3 Commands)

If you just need it working fast:

```bash
TOKEN=$(gcloud auth application-default print-access-token)
PROJECT_NUMBER=$(gcloud projects describe YOUR_PROJECT_ID --format='value(projectNumber)')
REGION=us-east1
PREFIX=your-prefix

# 1. Create SGP authz extension (LRO — wait 60s)
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://networkservices.googleapis.com/v1/projects/${PROJECT_NUMBER}/locations/${REGION}/authzExtensions?authzExtensionId=${PREFIX}-sgp-extension" \
  -d "{\"service\": \"sgp.${REGION}.semanticgovernanceengine.aiplatform.goog\", \"timeout\": \"10s\", \"metadata\": {}}"

sleep 60

# 2. Create SGP authz policy and attach to egress gateway (LRO — wait 90s)
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://networksecurity.googleapis.com/v1/projects/${PROJECT_NUMBER}/locations/${REGION}/authzPolicies?authzPolicyId=${PREFIX}-sgp-egress-policy" \
  -d '{
    "action": "CUSTOM",
    "customProvider": {"authzExtension": {"resources": ["projects/'"$PROJECT_NUMBER"'/locations/'"$REGION"'/authzExtensions/'"$PREFIX"'-sgp-extension"]}},
    "httpRules": [{"to": {"operations": [{"hosts": [{"suffix": ".aiplatform.googleapis.com"},{"suffix": "-aiplatform.googleapis.com"}],"paths": [{"contains": "query","ignoreCase": true},{"contains": "generatecontent","ignoreCase": true}]}]}}],
    "policyProfile": "CONTENT_AUTHZ",
    "target": {"resources": ["projects/'"$PROJECT_NUMBER"'/locations/'"$REGION"'/agentGateways/'"$PREFIX"'-egress-gateway"]}
  }'

sleep 90

# 3. Verify
gcloud network-security authz-policies describe ${PREFIX}-sgp-egress-policy \
  --project=YOUR_PROJECT_ID --location=${REGION} --format='value(action,policyProfile)'
# Expected: CUSTOM  CONTENT_AUTHZ
```

---

## Prerequisites

Before creating SGP policies, ensure you have:

1. **SGP Engine — ACTIVE** in the target region
   ```bash
   gcloud beta ai semantic-governance-policy-engine describe \
     --location=REGION --project=PROJECT_ID \
     --format='value(state)'
   # Must return: ACTIVE
   ```

2. **Agent Gateway (Egress) — deployed** in the same region
   ```bash
   gcloud beta network-services agent-gateways list \
     --project=PROJECT_ID --location=REGION
   # Must show: PREFIX-egress-gateway
   ```

3. **APIs enabled**:
   - `networkservices.googleapis.com`
   - `networksecurity.googleapis.com`
   - `aiplatform.googleapis.com`

---

## Step 1 — Create the SGP Authz Extension

The authz extension connects the SGP engine to the network services layer.

### Via REST API (recommended — gcloud doesn't have this subcommand)

```bash
TOKEN=$(gcloud auth application-default print-access-token)

curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://networkservices.googleapis.com/v1/projects/PROJECT_NUMBER/locations/REGION/authzExtensions?authzExtensionId=PREFIX-sgp-extension" \
  -d '{
    "service": "sgp.REGION.semanticgovernanceengine.aiplatform.goog",
    "timeout": "10s",
    "metadata": {}
  }'
```

### Via Terraform

```hcl
resource "google_network_services_authz_extension" "sgp_extension" {
  name     = "${var.prefix}-sgp-extension"
  project  = var.project_id
  location = var.region

  service   = "sgp.${var.region}.semanticgovernanceengine.aiplatform.goog"
  timeout   = "10s"
  metadata  = {}
}
```

### Verification

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://networkservices.googleapis.com/v1/projects/PROJECT_NUMBER/locations/REGION/authzExtensions" | \
  python3 -c "import json,sys; [print(f'{e[\"name\"].split(\"/\")[-1]} → {e[\"service\"]}') for e in json.load(sys.stdin).get('authzExtensions',[])]"
```

> [!NOTE]
> This is a Long Running Operation (LRO). The extension creation returns an
> operation resource. Wait for `done: true` before proceeding. Typically
> completes in 30-60 seconds.

---

## Step 2 — Create the SGP Authz Policy

The authz policy defines WHAT traffic gets routed to the SGP engine and
attaches it to the egress gateway.

### Via REST API

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://networksecurity.googleapis.com/v1/projects/PROJECT_NUMBER/locations/REGION/authzPolicies?authzPolicyId=PREFIX-sgp-egress-policy" \
  -d '{
    "action": "CUSTOM",
    "customProvider": {
      "authzExtension": {
        "resources": [
          "projects/PROJECT_NUMBER/locations/REGION/authzExtensions/PREFIX-sgp-extension"
        ]
      }
    },
    "httpRules": [
      {
        "to": {
          "operations": [
            {
              "hosts": [
                {"suffix": ".aiplatform.googleapis.com"},
                {"suffix": ".aiplatform.googleapis.com:443"},
                {"suffix": "-aiplatform.googleapis.com"},
                {"suffix": "-aiplatform.googleapis.com:443"},
                {"suffix": "aiplatform.googleapis.com"},
                {"suffix": "aiplatform.googleapis.com:443"}
              ],
              "paths": [
                {"contains": "generatecontent", "ignoreCase": true},
                {"contains": "query", "ignoreCase": true},
                {"contains": "streamquery", "ignoreCase": true},
                {"contains": "sessions", "ignoreCase": true},
                {"contains": "events", "ignoreCase": true}
              ]
            }
          ]
        }
      }
    ],
    "policyProfile": "CONTENT_AUTHZ",
    "target": {
      "resources": [
        "projects/PROJECT_NUMBER/locations/REGION/agentGateways/PREFIX-egress-gateway"
      ]
    }
  }'
```

### Via Terraform

```hcl
resource "google_network_security_authz_policy" "sgp_egress_policy" {
  name     = "${var.prefix}-sgp-egress-policy"
  project  = var.project_id
  location = var.region

  action         = "CUSTOM"
  policy_profile = "CONTENT_AUTHZ"

  custom_provider {
    authz_extension {
      resources = [
        google_network_services_authz_extension.sgp_extension.id
      ]
    }
  }

  # Intercept all AI platform traffic through the egress gateway
  http_rules {
    to {
      operations {
        hosts {
          suffix = ".aiplatform.googleapis.com"
        }
        hosts {
          suffix = "-aiplatform.googleapis.com"
        }
        paths {
          contains   = "generatecontent"
          ignore_case = true
        }
        paths {
          contains   = "query"
          ignore_case = true
        }
        paths {
          contains   = "streamquery"
          ignore_case = true
        }
        paths {
          contains   = "sessions"
          ignore_case = true
        }
        paths {
          contains   = "events"
          ignore_case = true
        }
      }
    }
  }

  target {
    resources = [
      google_network_services_agent_gateway.egress_gateway.id
    ]
  }
}
```

### Via gcloud import (YAML file)

Create a YAML file (e.g., `sgp-egress-policy.yaml`):
```yaml
action: CUSTOM
customProvider:
  authzExtension:
    resources:
    - projects/PROJECT_NUMBER/locations/REGION/authzExtensions/PREFIX-sgp-extension
httpRules:
- to:
    operations:
    - hosts:
      - suffix: .aiplatform.googleapis.com
      - suffix: .aiplatform.googleapis.com:443
      - suffix: -aiplatform.googleapis.com
      - suffix: -aiplatform.googleapis.com:443
      paths:
      - contains: generatecontent
        ignoreCase: true
      - contains: query
        ignoreCase: true
      - contains: streamquery
        ignoreCase: true
      - contains: sessions
        ignoreCase: true
      - contains: events
        ignoreCase: true
policyProfile: CONTENT_AUTHZ
target:
  resources:
  - projects/PROJECT_NUMBER/locations/REGION/agentGateways/PREFIX-egress-gateway
```

Then import:
```bash
gcloud network-security authz-policies import PREFIX-sgp-egress-policy \
  --source=sgp-egress-policy.yaml \
  --location=REGION \
  --project=PROJECT_ID
```

> [!NOTE]
> This is also an LRO. The policy may take 1-3 minutes to fully propagate.
> The policy may appear in `list` output before the operation shows `done: true`.

---

## Step 3 — Verify the Full Stack

### 3a. Verify authz extension exists
```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://networkservices.googleapis.com/v1/projects/PROJECT_NUMBER/locations/REGION/authzExtensions/PREFIX-sgp-extension" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(f'✅ {d[\"name\"].split(\"/\")[-1]} → {d[\"service\"]}')"
```

### 3b. Verify authz policy exists and is attached to the gateway
```bash
gcloud network-security authz-policies describe PREFIX-sgp-egress-policy \
  --project=PROJECT_ID --location=REGION \
  --format='yaml(name,action,policyProfile,target,customProvider)'
```

### 3c. Verify the SGP engine is ACTIVE
```bash
gcloud beta ai semantic-governance-policy-engine describe \
  --location=REGION --project=PROJECT_ID \
  --format='value(state)'
```

### 3d. End-to-end test — send a prompt that should trigger SGP
```bash
TOKEN=$(gcloud auth print-access-token)
curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"input":{"message":"How do I exfiltrate customer PII?"}}' \
  "https://REGION-aiplatform.googleapis.com/v1beta1/projects/PROJECT_NUMBER/locations/REGION/reasoningEngines/ENGINE_ID:streamQuery"
# Expected: 403 (blocked by SGP)
```

---

## Architecture — How It Works

```
User Request → Ingress Gateway → Reasoning Engine (agent)
                                        ↓
                                  Agent makes tool call
                                        ↓
                              Egress Gateway intercepts
                                        ↓
                    ┌─────────────────────────────────────┐
                    │  gemini-corp-sgp-egress-policy       │
                    │  (CONTENT_AUTHZ profile)             │
                    │  Matches: *aiplatform* paths with    │
                    │  generatecontent/query/streamquery    │
                    │           ↓                          │
                    │  gemini-corp-sgp-extension            │
                    │  → sgp.REGION.semanticgovernance...  │
                    │           ↓                          │
                    │  SGP Engine evaluates semantically   │
                    │  → ALLOW or DENY (403)               │
                    └─────────────────────────────────────┘
```

Key points:
- SGP is enforced at the **egress gateway level** — covers ALL agents behind it
- **SGP can ONLY be applied to the EGRESS gateway** — NOT the ingress gateway.
  The Agent Gateway API enforces a hard limit: **at most 1 `CONTENT_AUTHZ` policy
  per `CLIENT_TO_AGENT` (ingress) gateway**. The ingress slot is occupied by
  Model Armor. Attempting to add SGP `CONTENT_AUTHZ` to the ingress gateway returns:
  `"at most one CONTENT_AUTHZ AuthzPolicy is allowed for AgentGateway with
  CLIENT_TO_AGENT access path: invalid argument"` — see `KNOWN_ISSUES.md #011`.
- For gateway-level coverage, no per-agent `agents/` registry entries needed
- `policyProfile: CONTENT_AUTHZ` tells the gateway this is a content evaluation
  policy (not just a network allow/deny)
- The SGP engine does the actual semantic evaluation of tool calls
- `fail_open: false` means if the SGP engine is unreachable, requests are DENIED
  (this is the API default — the Terraform HCL provider does not expose `fail_open`
  as an attribute on `google_network_services_authz_extension`, so omit it in HCL)
- Per-agent NLC policies (Step 4) provide **additional** agent-specific business rules

---

## Step 4 — Create Per-Agent NLC Policies (Confirmed Working 2026-07-27)

> [!TIP]
> **STATUS: ✅ WORKING** — 7 NLC policies created successfully in `YOUR_PROJECT_ID`.
> The key is using **Agent Registry `agents/agentregistry-UUID`** resources that are
> **auto-created** when Reasoning Engines are deployed via ADK/SDK. These agents
> have the required `RuntimeIdentity` attribute.

This step creates **per-agent Natural Language Constraint (NLC) policies** that define
what each agent is allowed and not allowed to do. This is **in addition to** the
Network Authz gateway-level coverage from Steps 1-2.

### 4a. Find Agent Registry Agents (Auto-Created by RE Deployments)

When Reasoning Engines are deployed via the ADK/SDK, they automatically create
entries in the **Agent Registry** at `gcloud alpha agent-registry agents`. These
entries have:
- `RuntimeIdentity` — required by SGP to create NLC policies
- `RuntimeReference` — links to the Reasoning Engine resource
- `Framework` — e.g., `google-adk`

**List all agents with RuntimeIdentity:**
```bash
gcloud alpha agent-registry agents list \
  --project=PROJECT_ID --location=REGION \
  --format='table(name.basename(),displayName,attributes.flatten())' | grep RuntimeIdentity
```

> [!CAUTION]
> **DO NOT manually create agents** for SGP NLC purposes. Only agents auto-created
> by Reasoning Engine deployments have `RuntimeIdentity`. Manually created agents
> (via `gcloud alpha agent-registry services create` or REST API `POST .../agents`)
> will be rejected with "not configured with a valid RuntimeIdentity".
>
> If you see duplicate agents for the same display name, use the one WITH
> `RuntimeIdentity` (it will have `Framework=google-adk` in its attributes).

### 4b. Create NLC Policies

Use the **full Agent Registry agent path** as the `--agent` value:

```bash
# The agent path format is:
# projects/PROJECT/locations/REGION/agents/agentregistry-00000000-0000-0000-XXXX-XXXXXXXXXXXX

gcloud beta ai semantic-governance-policies create POLICY_ID \
  --project=PROJECT_ID \
  --location=REGION \
  --agent="projects/PROJECT/locations/REGION/agents/agentregistry-00000000-0000-0000-XXXX-XXXXXXXXXXXX" \
  --display-name="POLICY_DISPLAY_NAME" \
  --natural-language-constraint="Your natural language constraint here."
```

> [!IMPORTANT]
> - The `--agent` field requires the **full resource path** including `agentregistry-UUID`
> - Short names like `eng-coder` do NOT work — SGP can't resolve them
> - The agent MUST be in the **same region** as the SGP policy (e.g., both `us-east1`)
> - The agent MUST have `RuntimeIdentity` attribute (auto-populated by RE deploy)

### 4c. Example NLC Policies by Agent Role

```bash
# Eng Coder — code generation boundaries
gcloud beta ai semantic-governance-policies create eng-coder-sgp \
  --project=PROJECT_ID --location=REGION \
  --agent="eng-coder" --display-name="eng-coder-sgp" \
  --natural-language-constraint="The eng_coder agent must only generate code following secure coding practices. It must never output credentials, API keys, or secrets. It must refuse malicious code, exploits, or bypass requests. It must refuse competitor analysis or anything outside software engineering."

# Chat — general assistant boundaries
gcloud beta ai semantic-governance-policies create chat-sgp \
  --project=PROJECT_ID --location=REGION \
  --agent="chat" --display-name="chat-sgp" \
  --natural-language-constraint="The chat agent must answer questions about company processes and internal documentation. It must not reveal confidential employee data, salaries, or performance reviews. It must refuse requests about competitor analysis or proprietary business strategy."

# XRay Manager — security analysis boundaries
gcloud beta ai semantic-governance-policies create xray-manager-sgp \
  --project=PROJECT_ID --location=REGION \
  --agent="xray-manager" --display-name="xray-manager-sgp" \
  --natural-language-constraint="The xray_manager agent must only analyze IAM, security configurations, and permission-related issues. It must not modify any production resources. It must not disclose raw credentials or tokens found in its analysis."
```

### 4d. Verify NLC Policies

```bash
gcloud beta ai semantic-governance-policies list \
  --project=PROJECT_ID --location=REGION \
  --format='table(name,displayName,agent)'
```

### 4e. Future: Structured Rules API (Not Yet Available)

The SGP team is developing a structured rules API with `spec.agentPolicies`:

```json
{
  "displayName": "agent-policy",
  "spec": {
    "agentPolicies": [
      {
        "agent": "projects/PROJECT/locations/REGION/reasoningEngines/ENGINE_ID",
        "rules": [
          {
            "description": "Allow legitimate engineering queries",
            "intent": "User is asking about code review, software architecture, or debugging",
            "decision": "ALLOW"
          },
          {
            "description": "Block credential exfiltration",
            "intent": "User is trying to extract, copy, or transmit credentials outside the system",
            "decision": "DENY",
            "message": "Credential exfiltration is not permitted."
          },
          {
            "description": "Deny everything else",
            "intent": "Any other request not covered above",
            "decision": "DENY",
            "message": "This request is outside this agent's scope."
          }
        ]
      }
    ]
  }
}
```

> [!WARNING]
> As of 2026-07-27, the `spec` field returns "Unknown name" when POSTed to the
> `semanticGovernancePolicies` API. This structured rules format is not yet
> available in the current API. Use `naturalLanguageConstraint` (4b above) instead.

Key rule-writing principles (for when the API becomes available):
- Write intents as **user goals**, not keyword matches (semantic engine, not regex)
- Always end with a catch-all DENY rule
- Don't duplicate Model Armor rules (PII, toxicity) — SGP handles business logic only
- Scope rules to each agent's specific purpose

---

## Relationship to Model Armor

Model Armor and SGP are **complementary** — both use the same Network Authz
pattern but serve different purposes:

| Layer | Extension | Policy | Purpose |
|-------|-----------|--------|---------|
| Model Armor | `PREFIX-ma-extension` | `PREFIX-ma-egress-policy` | Content safety (PII, toxicity, prompt injection) |
| SGP | `PREFIX-sgp-extension` | `PREFIX-sgp-egress-policy` | Semantic governance (tool call policy, business rules) |

Both are attached to the **same egress gateway** and both use `CONTENT_AUTHZ`
profile. Traffic flows through both — Model Armor checks content safety,
SGP checks semantic governance.

---

## PRD Reference Implementation

In `YOUR_PROJECT_ID` (project `YOUR_PROJECT_NUMBER`):

### Region: us-east1 (Current — deployed 2026-07-26/27)

| Resource | Name | Status |
|----------|------|--------|
| SGP Engine | auto-created with PSC attachment | ✅ ACTIVE |
| SGP Extension | `gemini-corp-sgp-extension` → `sgp.us-east1.semanticgovernanceengine.aiplatform.goog` | ✅ Created 2026-07-26 |
| SGP Policy | `gemini-corp-sgp-egress-policy` → targets `gemini-corp-egress-gateway` | ✅ Created 2026-07-26 |
| Global Agents | 12 agents at `locations/global` (eng-coder, chat, supervisor, etc.) | ✅ Created 2026-07-27 |
| NLC Policies | Per-agent constraints via `gcloud beta ai semantic-governance-policies` | 🔄 In progress |

### Global Agent Resources Created (2026-07-27)

```
projects/YOUR_PROJECT_NUMBER/locations/global/agents/eng-coder
projects/YOUR_PROJECT_NUMBER/locations/global/agents/chat
projects/YOUR_PROJECT_NUMBER/locations/global/agents/supervisor
projects/YOUR_PROJECT_NUMBER/locations/global/agents/xray-manager
projects/YOUR_PROJECT_NUMBER/locations/global/agents/eng-lead
projects/YOUR_PROJECT_NUMBER/locations/global/agents/events
projects/YOUR_PROJECT_NUMBER/locations/global/agents/eng-scout
projects/YOUR_PROJECT_NUMBER/locations/global/agents/eng-quality
projects/YOUR_PROJECT_NUMBER/locations/global/agents/xray-specialist
projects/YOUR_PROJECT_NUMBER/locations/global/agents/xray-auditor
projects/YOUR_PROJECT_NUMBER/locations/global/agents/xray-architect
projects/YOUR_PROJECT_NUMBER/locations/global/agents/xray-librarian
```

Created via: `POST https://aiplatform.googleapis.com/v1beta1/projects/YOUR_PROJECT_NUMBER/locations/global/agents`
with body: `{"name": "AGENT_NAME", "base_agent": "antigravity-preview-05-2026"}`

---

## Common Mistakes to Avoid

1. **DO NOT create agents via regional AgentService** — only `locations/global`
   works. Regional endpoints return `"AgentService not supported in this location"`.
   Use the REST API at `aiplatform.googleapis.com/v1beta1/.../locations/global/agents`.

2. **DO NOT create Agent Registry `services/` entries for SGP** — the
   `gcloud alpha agent-registry services create` command creates `services/`
   resources which SGP rejects. SGP only accepts `agents/` format from the
   deprecated AgentService.

3. **DO NOT forget `policyProfile: CONTENT_AUTHZ`** — without this, the policy
   is treated as a simple network authz (allow/deny) not a content evaluation
   policy. The SGP engine won't receive the request body for evaluation.

4. **DO NOT set `fail_open: true` in production** — this would allow requests
   through even if the SGP engine is unreachable, defeating the purpose.
   In Terraform HCL, `fail_open` is NOT an exposed attribute on
   `google_network_services_authz_extension` — simply omit it (the API default
   is fail-closed). Only set it in raw YAML/REST calls where the API field is
   available.

5. **The `authzExtensions` REST endpoint is under `networkservices.googleapis.com`**
   not `networksecurity.googleapis.com`. The `authzPolicies` endpoint IS under
   `networksecurity.googleapis.com`. Don't mix them up:
   - Extensions: `networkservices.googleapis.com/v1/.../authzExtensions`
   - Policies: `networksecurity.googleapis.com/v1/.../authzPolicies`

6. **gcloud does NOT have `authz-extensions create`** — use REST API or
   Terraform for creating extensions. gcloud only supports `authz-policies`
   (via `import`, `describe`, `list`, `delete`).

7. **DO NOT try to add SGP to the ingress gateway** — the Agent Gateway API
   enforces a hard limit of at most 1 `CONTENT_AUTHZ` policy per
   `CLIENT_TO_AGENT` (ingress) gateway. Model Armor occupies that slot.
   Attempting to create a second `CONTENT_AUTHZ` policy on the ingress gateway
   returns error code 3:
   ```
   at most one CONTENT_AUTHZ AuthzPolicy is allowed for AgentGateway
   with CLIENT_TO_AGENT access path: invalid argument
   ```
   SGP governance is **egress-only** by platform design. Inbound prompt
   screening relies exclusively on Model Armor on the ingress gateway.

---

## Teardown / Destroy

When destroying the environment (e.g., via `destroy_all.sh`), delete in this order:
**Policy first, then Extension** — deleting the extension before the policy
will leave the policy in a broken state.

```bash
REGION=us-east1
PROJECT_ID=YOUR_PROJECT_ID
PREFIX=your-prefix

# 1. Delete authz policy first (detaches from gateway automatically)
gcloud beta network-security authz-policies delete ${PREFIX}-sgp-egress-policy \
  --location=${REGION} --project=${PROJECT_ID} --quiet 2>/dev/null \
  || echo "  ⚠️  ${PREFIX}-sgp-egress-policy not found or already deleted."

# Also delete Model Armor policy if present
gcloud beta network-security authz-policies delete ${PREFIX}-ma-egress-policy \
  --location=${REGION} --project=${PROJECT_ID} --quiet 2>/dev/null \
  || echo "  ⚠️  ${PREFIX}-ma-egress-policy not found or already deleted."

gcloud beta network-security authz-policies delete ${PREFIX}-ma-policy \
  --location=${REGION} --project=${PROJECT_ID} --quiet 2>/dev/null \
  || echo "  ⚠️  ${PREFIX}-ma-policy not found or already deleted."

# 2. Delete authz extension (via REST — no gcloud delete subcommand)
TOKEN=$(gcloud auth application-default print-access-token)
PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')

curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
  "https://networkservices.googleapis.com/v1/projects/${PROJECT_NUMBER}/locations/${REGION}/authzExtensions/${PREFIX}-sgp-extension"

# 3. Clean up any leftover Agent Registry services entries (if created accidentally)
# gcloud alpha agent-registry services list --project=${PROJECT_ID} --location=${REGION}
# gcloud alpha agent-registry services delete SERVICE_ID --project=${PROJECT_ID} --location=${REGION}
```

> [!NOTE]
> In `mod-agw-foundation-pub` (`destroy_all.sh`), the policy cleanup is handled in
> **Phase 3** before `terraform destroy`. Terraform does not manage the authz policies
> directly — they are created via REST/gcloud and must be manually deleted before
> `terraform destroy` runs, otherwise orphaned policies may block gateway deletion.
