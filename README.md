<!-- Copyright 2025 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. -->

# Agent-Gateway-Foundation

> ⚠️ **Disclaimer:** This code is for PoC environment only.
> This demo code is not built for production workload.

> Production-hardened infrastructure-as-code for deploying AI agents — single or
> multi-agent — secured by Google Cloud **Agent Gateway**: PSC routing, Model Armor,
> DLP, IAP, SGP semantic guardrails, org policies, and OTEL observability. Battle-tested
> over 6+ weeks in a fully org-policy-enforced GCP environment.

**Version:** `1.0.2` · **Region tested:** `us-east1` · **ADK:** `2.5.0` · **aiplatform:** `1.162.0`

---

## What You Get

Every agent deployed through this foundation automatically receives:

| Layer | What it does |
|---|---|
| **Agent Gateway (Ingress)** | All inbound traffic screened — Model Armor + IAP identity validation before it reaches your agent |
| **Agent Gateway (Egress)** | All outbound traffic (LLM calls, tool calls) routed through the gateway — unlisted hosts are blocked at the PSC routing level |
| **PSC (Private Service Connect)** | Agents reach Vertex AI and other GCP APIs without traversing the public internet |
| **Model Armor** | Dual extensions on ingress + egress: prompt injection, jailbreak, PII, malicious URL, RAI filters. Ingress fail-closed; egress fail-open |
| **DLP Templates** | Inspect + deidentify templates wired into Model Armor: SSN, email, API keys, credentials, medical codes |
| **IAP** | Ingress: fail-closed identity validation (caller must hold `roles/iap.egressor`). Egress: audit-only DRY_RUN mode |
| **SGP (Semantic Governance)** | Per-agent NLC (Natural Language Constraint) policy — blocks off-topic or disallowed requests semantically, not just by keyword |
| **3 Org Policies** | `AgentGatewayConfig`, `AgentIdentity`, `OtelConfig` enforced at project level — any RE deploy without gateway config is rejected |
| **Observability** | Token usage dashboards, gateway security dashboards, org-level rollup, BigQuery audit sink, 6 token alert policies |
| **GatewayAgent SDK** | One import in `agent.py` handles all compliance boilerplate — OTEL telemetry, PSC-compatible endpoint routing, global Gemini 3.x support |
| **Antigravity Skills** | Your AI coding assistant knows exactly how to set up, maintain, debug, and extend every layer — including A2A multi-agent |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Agent Gateway Foundation                              │
│                                                                              │
│  User / Client                                                               │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────┐                                                     │
│  │   Ingress Gateway   │  ← IAP (fail-closed) + Model Armor (fail-closed)   │
│  └─────────┬───────────┘                                                     │
│            │ authorized request                                              │
│            ▼                                                                 │
│  ┌─────────────────────┐                                                     │
│  │  Reasoning Engine   │  ← Your agent (AdkApp + GatewayAgent SDK)          │
│  │  (Vertex AI RE)     │    WIF identity · org policies enforced at deploy   │
│  └─────────┬───────────┘                                                     │
│            │ outbound (LLM / tools)                                          │
│            ▼                                                                 │
│  ┌─────────────────────┐                                                     │
│  │   Egress Gateway    │  ← Model Armor (fail-open) + SGP + IAP DRY_RUN     │
│  └─────────┬───────────┘                                                     │
│            │ PSC route (allowlisted hosts only)                              │
│            ▼                                                                 │
│  aiplatform.googleapis.com  ·  your-api.example.com  ·  (others allowlisted)│
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Three Ways to Adopt

### Path A — Standalone (new GCP project, no existing agent)
Clone this repo, fill in `terraform.tfvars`, run `deploy_all.sh`.
Your agent code goes in `agents/my-agent/`.

### Path B — Sidecar (existing GitHub repo + existing agent) ← recommended for teams
Add this as a **git submodule** inside your existing repo.
Your agent code stays where it is. Use `--agent-path` to point the deploy script at it.

### Path C — Gitignored Subfolder (no submodule complexity) ← simplest
One-time `git clone` into a `foundation/` subfolder of your team repo. Gitignore it.
Everything stays local — no ongoing git relationship with the foundation.

---

## Prerequisites

| Tool | Version |
|---|---|
| `terraform` | ≥ 1.5 · [Install](https://developer.hashicorp.com/terraform/install) |
| `gcloud` CLI | latest · [Install](https://cloud.google.com/sdk/docs/install) |
| `python3` | ≥ 3.11 |

**GCP IAM requirements:**

| Scope | Role needed |
|---|---|
| Project | `roles/owner` OR (`roles/editor` + `roles/networkservices.admin`) |
| **Org level** | `roles/orgpolicy.policyAdmin` ← **most teams are missing this** |

> [!CAUTION]
> `roles/orgpolicy.policyAdmin` must be granted at the **GCP Organization level**,
> not the project level. This is the #1 first-deploy failure. If your account
> doesn't have it, ask your GCP org admin.

**Authenticate before starting:**
```bash
gcloud auth application-default login
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

**Bootstrap APIs (one-time, idempotent):**
```bash
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  agentregistry.googleapis.com \
  --project=YOUR_PROJECT_ID
```

---

## Path A — Standalone Setup

### 1. Clone and configure

```bash
git clone https://github.com/GCP-Architecture-Guides/Agent-Gateway-Foundation.git
cd Agent-Gateway-Foundation

cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars is gitignored — never committed
```

Edit `terraform.tfvars` — minimum required fields:

```hcl
project_id      = "your-gcp-project-id"
organization_id = "123456789012"         # gcloud organizations list
location        = "us-east1"
prefix          = "myteam"              # short prefix, no spaces, no hyphens
agent_name      = "my_agent"            # Python identifier: underscores only

allowed_egress_hosts = [
  "api.example.com",   # every external host your agent needs to call
]

sgp_nlc_constraint = <<-EOT
  This agent helps with [YOUR TOPIC]. It may only answer questions about
  [ALLOWED SCOPE].
EOT
```

### 2. Add your agent code

```
agents/
└── my-agent/
    ├── agent.py          ← your agent logic
    └── requirements.txt  ← pinned versions required
```

Use the `GatewayAgent` SDK — it handles all compliance automatically:

```python
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
from gateway_agent import GatewayAgent

root_agent = GatewayAgent(
    name="my_agent",
    model="gemini-2.5-flash",          # regional endpoint
    # model="gemini-3.5-flash",        # global endpoint — use GlobalGemini wrapper
    description="My agent.",
    instruction="You are a helpful assistant.",
    tools=[],
)
```

### 3. Deploy

```bash
bash deploy_all.sh
```

**What happens:**

| Phase | Script | Duration | What it does |
|---|---|---|---|
| **Infra** | `terraform apply` | ~10 min | VPC · PSC · Agent Gateways · Model Armor · IAP · SGP engine · DLP · Org Policies · BigQuery sink · Dashboards |
| **Agent** | `deploy_chat_agent.sh` | ~5 min | Packages + deploys your agent to Vertex AI RE · strips contextSpec · grants 7 IAM roles to WIF identity |
| **SGP** | `create_sgp_policy.sh` | ~1 min | Registers NLC topic constraint in Agent Registry |

### 4. Tear down

```bash
bash destroy_all.sh
```

---

## Multi-Agent A2A Mesh — Food Court Reference Implementation

This foundation ships with a **production-validated 4-agent A2A mesh** as a reference implementation. It demonstrates the complete pattern for building multi-agent systems where specialists are dynamically discovered — zero hardcoded RE IDs.

### Architecture

```
User
  │
  ▼
Ingress Gateway
  │  IAP (identity check) + Model Armor (content scan)
  ▼
store_concierge (Orchestrator RE)
  │
  │  1. Classify user intent (LLM)
  │  2. Call specialist tool: call_pizza_agent() / call_burger_agent() / call_sushi_agent()
  │  3. Discover specialist RE via labels (AgentRegistry.find capability=X)
  │  4. Forward query via REST SSE → specialist RE
  │
  ├─────────────────────────────────────────────────────────────┐
  │                               │                             │
  ▼                               ▼                             ▼
pizza_specialist RE         burger_specialist RE          sushi_specialist RE
  │                               │                             │
  └───────────────────────────────┴─────────────────────────────┘
                                  │
                            Egress Gateway
                     Model Armor + SGP + IAP DRY_RUN
                                  │
                            PSC → aiplatform.googleapis.com
                            (gemini-3.5-flash, global endpoint)
```

**Key design properties:**
- **Zero hardcoded specialist URLs or RE IDs** — all discovery is runtime via `labels.capability`
- **Adding a specialist = deploy + label** → orchestrator auto-discovers, no redeployment
- **google-adk(a2a) classification** — 24 classMethods (13 ADK + 11 A2A protocol) applied post-deploy
- **agentCard** on every RE — enables A2A badge in Vertex AI console
- **WIF identity (7 roles)** — every RE has its own Workload Identity Federation principal

### Agent Structure

```
agents/
├── orchestrator/           ← Store Concierge — routes to specialists
│   ├── agent.py            ← GatewayAgent + call_X_agent() tools + AgentRegistry discovery
│   └── requirements.txt
├── pizza-agent/            ← Pizza Specialist
│   ├── agent.py            ← GatewayAgent + pizza ordering tools
│   └── requirements.txt
├── burger-agent/           ← Burger Specialist
│   ├── agent.py
│   └── requirements.txt
└── sushi-agent/            ← Sushi Specialist
    ├── agent.py
    └── requirements.txt
```

---

## Deploy Workflow — `deploy_all.sh`

The main deploy script handles the full end-to-end flow for the A2A mesh.
**`deploy_all.sh` is always the source of truth** — `destroy_all.sh` mirrors it exactly.

### Usage

```bash
bash scripts/deploy_all.sh                    # default: classify + orchestrator + E2E + SGP
bash scripts/deploy_all.sh --fresh           # full deploy from scratch (after destroy_all.sh)
bash scripts/deploy_all.sh --skip-orchestrator  # classify + E2E + SGP only
bash scripts/deploy_all.sh --skip-e2e           # skip E2E tests
bash scripts/deploy_all.sh --skip-sgp           # skip SGP creation (re-deploy with existing SGPs)
bash scripts/deploy_all.sh --e2e-only           # run E2E tests only (no deploy, no SGP)
```

### Step-by-Step Flow

#### STEP 0 — Deploy Specialists `[--fresh only]`

```bash
# Triggered only with --fresh flag (after a full destroy_all.sh teardown)
# Deploys each specialist independently via deploy_a2a_agents.sh
for specialist in pizza burger sushi; do
  bash scripts/deploy_a2a_agents.sh --only "$specialist"
done
```

**Per-specialist what happens (via `deploy_a2a_agent.py`):**

1. Load `agent.py` + `requirements.txt` from `agents/<specialist>/`
2. Bundle with `cloudpickle.register_pickle_by_value` (cloudpickle caveat #16)
3. `AgentEngine.create()` — `_gateway_patch.pth` intercepts and injects:
   - `agentGatewayConfig.clientToAgentConfig` → ingress gateway
   - `agentGatewayConfig.agentToAnywhereConfig` → egress gateway
   - `identityType: AGENT_IDENTITY` (org policy requirement)
   - OTEL env vars (org policy requirement)
4. GCS upload: `gs://{project}-staging/{display_name}/`
5. **POST-DEPLOY PATCHes** (all via REST API, no redeploy):
   - `contextSpec → {}` — prevents DNS crash from auto-injected `memoryBankConfig`
   - `classMethods = 24` (13 ADK + 11 A2A) + `agentFramework = google-adk`
   - `agentCard` — url, skills, capabilities (required for A2A badge in console)
   - `labels`: `role=specialist`, `team=food-court`, `capability={pizza|burger|sushi}-specialist`
6. **IAM grants** — 7 roles to WIF principal:
   - `roles/aiplatform.user` · `roles/cloudtrace.agent` · `roles/logging.logWriter`
   - `roles/aiplatform.sessionUser` · `roles/serviceusage.serviceUsageConsumer`
   - `roles/iap.egressor` · `roles/datastore.user`

**ETA: ~10–15 minutes total (3 specialists × ~4 min each)**

---

#### STEP 1 — Classify All Specialists as `google-adk(a2a)`

```bash
python scripts/patch_a2a_classification.py \
  --project "$PROJECT_ID" --region "$REGION" --team food-court
```

- Discovers all REs with `labels.team=food-court`
- Merges 24 classMethods (idempotent — won't duplicate)
- Refreshes `agentCard` on each specialist

This step runs even on a default (non-`--fresh`) deploy to ensure classification is current without redeploying the RE container.

**ETA: < 30 seconds**

---

#### STEP 2 — Deploy `store_concierge` Orchestrator

```bash
python scripts/redeploy_orchestrator.py \
  --project "$PROJECT_ID" --region "$REGION"
```

1. Record existing `store_concierge` REs (for blue/green cleanup post-deploy)
2. `AgentEngine.create()` with `extra_packages=[lib/gateway_agent/]`
   - `gateway_agent` package installed in the container at startup
3. Delete old `store_concierge` RE(s) after new one is ACTIVE (blue/green swap)
4. **POST-DEPLOY PATCHes:**
   - `contextSpec → {}`
   - `classMethods = 24` + `agentFramework = google-adk`
   - `agentCard` — url, skills, capabilities
   - `labels`: `role=orchestrator`, `team=food-court`, `capability=food-concierge`
5. **IAM grants** — same 7 roles as specialists (org_id + project_num resolved dynamically via `gcloud`)
6. **Re-run classification** — `patch_a2a_classification.py --team food-court`
   (catches the newly deployed orchestrator in the same pass)

**ETA: ~5 minutes**

---

#### STEP 3 — E2E Validation

```bash
python scripts/e2e_test.py --project "$PROJECT_ID" --region "$REGION"
```

Runs 17 queries across all 4 agents:

| Agent | Queries | What's tested |
|---|---|---|
| `pizza_specialist` | 4 | Direct specialist queries |
| `burger_specialist` | 4 | Direct specialist queries |
| `sushi_specialist` | 4 | Direct specialist queries |
| `store_concierge` | 5 | Orchestrator routing + direct answers |

All queries go through the full gateway stack (ingress → RE → egress → Vertex AI).
Pass = non-empty response for every query.

**ETA: ~2 minutes**

---

#### STEP 4 — SGP NLC Policy Creation

```bash
# Waits 90s for Agent Registry auto-registration (RE must be ACTIVE first)
sleep 90

for agent in store_concierge pizza_specialist burger_specialist sushi_specialist; do
  AGENT_NAME="$agent" bash scripts/create_sgp_policy.sh
done
```

**Why 90s wait?** `AgentEngine.create()` returns when the RE reaches `ACTIVE` state. But Vertex AI auto-registers the RE in the **Agent Registry** asynchronously — typically 60–90 seconds after ACTIVE. `create_sgp_policy.sh` needs the Agent Registry entry to attach the NLC policy.

**SGP is non-fatal** — agents function without it. It is the governance/content layer only. If SGP creation fails, the deploy script reports it as a warning with the retry command.

**ETA: ~2 minutes (4 policies)**

---

### Deploy Flags Matrix

| Flag | Step 0 (specialists) | Step 1 (classify) | Step 2 (orchestrator) | Step 3 (E2E) | Step 4 (SGP) |
|---|---|---|---|---|---|
| *(default)* | ❌ | ✅ | ✅ | ✅ | ✅ |
| `--fresh` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `--skip-orchestrator` | ❌ | ✅ | ❌ | ✅ | ✅ |
| `--skip-e2e` | ❌ | ✅ | ✅ | ❌ | ✅ |
| `--skip-sgp` | ❌ | ✅ | ✅ | ✅ | ❌ |
| `--e2e-only` | ❌ | ❌ | ❌ | ✅ | ❌ |

> [!TIP]
> **Most common re-deploy:** `bash scripts/deploy_all.sh` (no flags)
> Reclassifies all specialists, redeploys orchestrator, runs E2E, recreates SGP.
>
> **After full teardown:** `bash scripts/deploy_all.sh --fresh`
> Deploys everything from scratch.

---

## Destroy Workflow — `destroy_all.sh`

Mirrors `deploy_all.sh` exactly — tears down every resource it creates.

```bash
bash destroy_all.sh          # interactive (prompts for confirmation)
bash destroy_all.sh --force  # non-interactive (CI/CD)
```

**What gets deleted:**

| Phase | Resources | How |
|---|---|---|
| **Phase 1 — SGP policies** | NLC policies for all 4 food-court agents | `gcloud beta ai semantic-governance-policies delete` |
| **Phase 2 — Reasoning Engines** | All REs with `labels.team=food-court` (pizza, burger, sushi, store_concierge) | REST API delete with `?force=true` |
| **Phase 3 — GCS staging** | `gs://{project}-staging/{agent_name}/` for all 4 agents | `gsutil -m rm -r` |
| **Phase 4 — Local cleanup** | `__pycache__`, `*.pyc`, leftover `food_court_backend.py` | `find + rm` |

> [!NOTE]
> `destroy_all.sh` does **NOT** run `terraform destroy` — infrastructure (gateways, VPC, Model Armor) stays up.
> Terraform teardown is intentionally manual to prevent accidental infra destruction.
> Run `terraform destroy` separately when you want to remove the full stack.

---

## Adding a New Specialist (Zero-Touch Discovery)

1. **Create the agent:**
   ```
   agents/my-specialist/
   ├── agent.py          ← GatewayAgent + your specialist tools
   └── requirements.txt  ← pinned deps
   ```

2. **Add deploy entry to `scripts/deploy_a2a_agents.sh`:**
   ```bash
   if [[ -z "$ONLY_AGENT" || "$ONLY_AGENT" == "my-specialist" ]]; then
     deploy_agent "my-specialist" "my_specialist" \
       "my-description" \
       "my-capability" "specialist"
   fi
   ```

3. **Deploy:**
   ```bash
   bash scripts/deploy_a2a_agents.sh --only my-specialist
   ```

4. **Done** — the orchestrator discovers it automatically via `AgentRegistry` labels.
   No orchestrator redeployment needed.

> [!TIP]
> Optionally add a `call_my_specialist_agent()` tool to `agents/orchestrator/agent.py`
> to improve LLM intent classification. Discovery works regardless.

---

## Runtime Request Flow

```
User sends query
    │
    ▼
Ingress Gateway (Agent Gateway)
    ├── IAP Extension (fail-closed)
    │     └── validates caller has roles/iap.egressor
    └── Model Armor Extension (fail-closed, timeout=3s)
          └── DLP scan · prompt injection · jailbreak · malicious URL · RAI

    │ authorized
    ▼
store_concierge RE (Vertex AI Reasoning Engine)
    ├── Classifies intent via LLM (gemini-3.5-flash, global endpoint)
    ├── Routes to specialist tool: call_pizza_agent() etc.
    └── Specialist RE called via REST (direct PSC, bypasses gateway for cross-agent)

Specialist RE (pizza / burger / sushi)
    └── LLM call → Egress Gateway

Egress Gateway (Agent Gateway)
    ├── Model Armor Extension (fail-open, suffix match *.aiplatform.googleapis.com)
    │     └── response DLP scan · RAI filter
    ├── SGP Extension (fail-closed)
    │     └── NLC semantic content check (ALLOW/DENY per agent policy)
    └── IAP Extension (fail-open, DRY_RUN audit-only)

    │ PSC route (allowlisted hosts only)
    ▼
aiplatform.googleapis.com (global endpoint)
    └── gemini-3.5-flash / gemini-3.1-pro-preview

    │ response
    ▼
User
```

**Observability side-channel:**
- Cloud Trace ← OTEL token callback in `gateway_agent` (every LLM call)
- BigQuery `llm_audit_logs` ← `aiplatform` data access + `networksecurity` authz logs
- Cloud Monitoring ← 6 alert policies (token spike, runaway loop, zero traffic, etc.)

---

## Config Flow

Everything flows from `terraform.tfvars`. Nothing is hardcoded anywhere else.

```
terraform.tfvars
  │
  ├─▶ terraform apply
  │     Creates: VPC · PSC · Ingress/Egress Gateways · Model Armor · DLP
  │              IAP extensions · SGP engine + PSC DNS
  │              Org Policies (3) · GCS staging bucket
  │              BigQuery audit dataset · Logging sink · Dashboards
  │
  ├─▶ scripts/deploy_all.sh  (reads tfvars for project_id, location, prefix)
  │     Deploys: Reasoning Engines (4 agents)
  │     Applies: agentGatewayConfig via _gateway_patch.pth
  │     Grants: IAM roles to WIF principals
  │     Creates: SGP NLC policies per agent
  │
  └─▶ scripts/destroy_all.sh  (reads same tfvars)
        Deletes: SGP policies → REs → GCS objects → local cache
```

---

## Repository Structure

```
Agent-Gateway-Foundation/
├── terraform.tfvars.example        ← copy this, fill in your values
├── deploy_all.sh                   ← root convenience wrapper → scripts/deploy_all.sh
├── destroy_all.sh                  ← full teardown (mirrors deploy_all.sh)
│
├── 01_apis.tf                      ← GCP API enablement
├── 02_network.tf                   ← VPC · subnets · PSC · Agent Gateways · SGP DNS
├── 03_security_and_gateways.tf     ← Model Armor · DLP · IAP · SGP authz infra
├── 04_observability.tf             ← Dashboards · log sink · alert policies
├── 05_org_policies.tf              ← 3 custom org policy constraints
├── 06_agent_provisioning.tf        ← GCS staging bucket · Vertex AI SA IAM
├── 07_agent_registry.tf            ← Egress endpoint registration · RE viewer IAM
│
├── agents/
│   ├── orchestrator/               ← store_concierge (A2A orchestrator)
│   │   ├── agent.py                ← GatewayAgent + routing tools + AgentRegistry
│   │   └── requirements.txt
│   ├── pizza-agent/                ← pizza_specialist
│   ├── burger-agent/               ← burger_specialist
│   ├── sushi-agent/                ← sushi_specialist
│   └── chat-agent/                 ← single-agent reference (regional Gemini)
│
├── lib/
│   └── gateway_agent/              ← GatewayAgent SDK
│       ├── agent.py                ← GatewayAgent class (ADK Agent wrapper)
│       ├── global_gemini.py        ← PSC-compatible global Gemini 3.x wrapper
│       └── telemetry.py            ← OTEL token usage callback
│
├── scripts/
│   ├── deploy_all.sh               ← ✅ PRIMARY: full A2A mesh deploy + E2E + SGP
│   ├── deploy_a2a_agents.sh        ← Deploy individual specialists
│   ├── deploy_a2a_agent.py         ← Core specialist deploy logic (AgentEngine.create)
│   ├── redeploy_orchestrator.py    ← Orchestrator deploy logic
│   ├── patch_a2a_classification.py ← Apply google-adk(a2a) classification PATCHes
│   ├── create_sgp_policy.sh        ← SGP NLC policy registration
│   ├── e2e_test.py                 ← 17-query E2E test suite
│   ├── deploy_chat_agent.sh        ← Single-agent deploy (regional Gemini)
│   └── deploy_global_agent.sh      ← Single-agent deploy (global Gemini 3.x)
│
├── skills/                         ← Antigravity skill library (9 skills)
├── policies/                       ← SGP NLC policy templates
├── template/                       ← Starter templates for new agents
├── docs/                           ← Extended documentation
├── KNOWN_ISSUES.md                 ← 13 production failure runbooks
├── CHANGELOG.md
└── VERSION
```

---

## Antigravity Skills Setup

The `skills/` directory teaches your AI coding assistant (Antigravity) exactly
how to set up, maintain, debug, and extend every layer.

**One-time setup:**
```bash
mkdir -p ~/.gemini/config/skills
for d in skills/*/; do
  ln -sf "$(pwd)/$d" ~/.gemini/config/skills/"$(basename $d)"
done
echo "✅ Skills linked"
```

**Available skills:**

| Skill | When to use |
|---|---|
| `a2a-agent-deploy` | Building or debugging A2A multi-agent systems on Vertex AI RE |
| `a2a-multi-agent-troubleshooting` | 401/403/500 errors, empty responses, cross-agent call failures |
| `agw-foundation-adoption` | Onboarding a new team to this foundation (Path A/B/C) |
| `agw-add-sgp-policy` | Adding an SGP NLC policy to a deployed agent |
| `agw-model-armor-content-authz` | Configuring Model Armor CONTENT_AUTHZ — silent failure prevention |
| `agw-egress-iap-pitfall` | IAP on egress breaks outbound traffic — root cause + fix |
| `gateway-agent-sdk` | Adding GatewayAgent SDK, debugging missing telemetry |
| `sgp-network-authz-pattern` | SGP infra setup — the correct Network Authz path |
| `sgp-policy-rules` | Writing, testing, and debugging SGP NLC rules |
| `agent-gateway-deploy-patch` | RE deploy fails with code 13 / org policy error |
| `vertex-ai-global-endpoint-adk` | Gemini 3.x 404 / model-not-found on regional endpoint |

---

## Troubleshooting

See [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) for full runbooks. Quick reference:

| Symptom | Cause | Fix |
|---|---|---|
| `403 org policy` on first deploy | Missing `roles/orgpolicy.policyAdmin` at org level | Get org admin to grant at org scope |
| `400 FAILED_PRECONDITION` on RE create | Org policy not propagated (needs 180s) | Wait and re-run |
| `gRPC code 13 INTERNAL` on RE create | `agentGatewayConfig` missing — `_gateway_patch.pth` not active | Check venv has the `.pth` file |
| `307 → 404` on stream_query | `A2aAgent` wrapper used instead of `AdkApp` | Use `AdkApp` — see `a2a-agent-deploy` skill |
| Agent returns empty response | `classMethods` not patched, or `contextSpec` not stripped | Re-run `patch_a2a_classification.py` |
| SGP `policy created` but no enforcement | Model Armor extension prerequisite missing | See `agw-model-armor-content-authz` skill |
| Model Armor `500` on global endpoint | Exact host match for `aiplatform.googleapis.com` in egress MA | Use suffix match only — see `vertex-ai-global-endpoint-adk` skill |
| E2E passes but orchestrator silent | Cross-agent call using wrong user_id or gRPC path | Check `redeploy_orchestrator.py` REST SSE routing |
| IAP `403` on egress | `egress_iap_policy` set to ENFORCED not DRY_RUN | See `agw-egress-iap-pitfall` skill |

---

## Validated Results

Latest E2E validation: **2026-09-29** · Project: `geap-agw` · Region: `us-east1`

| Test | Agent | Result |
|------|-------|--------|
| Pizza order routing | `pizza_specialist` | ✅ PASS |
| Burger order routing | `burger_specialist` | ✅ PASS |
| Sushi order routing | `sushi_specialist` | ✅ PASS |
| Orchestrator direct answer | `store_concierge` | ✅ PASS |
| Orchestrator → specialist routing | `store_concierge` | ✅ PASS |
| Model Armor prompt injection block | Ingress gateway | ✅ PASS (HTTP 403) |
| SGP off-topic block | Egress gateway | ✅ PASS |
| OTEL token telemetry | Cloud Trace | ✅ PASS |

**SDK stack:** `google-adk==2.5.0` · `google-cloud-aiplatform==1.162.0` · `a2a-sdk==1.1.2` · `gemini-3.5-flash`

---

## Important Notes

- **`agent_name` must be a Python identifier** — underscores only (`my_agent` ✅, `my-agent` ❌)
- **Never commit `terraform.tfvars`** — it contains your project ID and org ID (gitignored by default)
- **SDK version pins are mandatory** — do NOT remove pins in `requirements.txt`. See `KNOWN_ISSUES.md` before upgrading
- **`--region` and `--project` are required** — all scripts fail fast if not supplied; no hidden defaults
- **`localhost:9999` in agentCard** — intentional A2A protocol sentinel. The real endpoint is in `agentCard.url`. The `supportedInterfaces.url` field is required by the A2A spec but unused at runtime
- **SGP is non-fatal** — agents work without it. It is the semantic governance layer only
- **Blue/green orchestrator deploy** — old `store_concierge` REs are deleted after the new one is ACTIVE. There is a brief window where both exist

---

## License

See [LICENSE](LICENSE) file.
