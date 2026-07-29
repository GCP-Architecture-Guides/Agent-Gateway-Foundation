# Agent-Gateway-Foundation

> Production-tested infrastructure-as-code for deploying AI agents secured by  
> Google Cloud **Agent Gateway** — PSC routing, Model Armor, org policies,  
> SGP semantic guardrails, and OTEL observability. Battle-hardened over 6 weeks  
> in a fully org-policy-enforced GCP environment.

**Version:** `1.0.0` · **Region tested:** `us-east1` · **ADK:** `1.31.1`

---

## What You Get

Every agent deployed through this foundation gets:

| Layer | What it does |
|---|---|
| **PSC egress** | All outbound traffic routed through the gateway — unlisted hosts are blocked |
| **Model Armor** | Dual templates: `security-high` screens user input, `security-responses` screens model output |
| **3 Org Policies** | `AgentGatewayConfig`, `AgentIdentity`, `OtelConfig` enforced at project level |
| **SGP NLC engine** | Semantic topic guardrails — blocks off-topic or disallowed requests |
| **Observability** | Token usage dashboard, latency alerts, log-based metrics — wired automatically |
| **GatewayAgent SDK** | One import replaces all boilerplate in your `agent.py` |
| **7 Antigravity Skills** | Your AI coding assistant knows exactly how to set up and maintain every layer |

---

## Three Ways to Adopt

### Path A — Standalone (new GCP project, no existing agent)
Clone this repo, fill in `terraform.tfvars`, run `deploy_all.sh`.
Your agent code goes in `agents/my-agent/`.

### Path B — Sidecar (existing GitHub repo + existing agent) ← recommended for teams
Add this as a **git submodule** inside your existing repo.
Your agent code stays where it is. Use `--agent-path` to point the deploy script at it.

### Path C — Gitignored Subfolder (existing repo, no submodule complexity) ← simplest
One-time `git clone` of the foundation into a `foundation/` subfolder of your
team repo. Gitignore it. From then on everything is local — no more git,
no scripts. Relative paths work. Antigravity sees everything in one workspace.

---

## Prerequisites

| Tool | Version |
|---|---|
| `terraform` | ≥ 1.5 · [Install](https://developer.hashicorp.com/terraform/install) |
| `gcloud` CLI | latest · [Install](https://cloud.google.com/sdk/docs/install) |
| `python3` | ≥ 3.10 |

**GCP IAM requirements:**

| Scope | Role needed |
|---|---|
| Project | `roles/owner` OR (`roles/editor` + `roles/networkservices.admin`) |
| **Org level** | `roles/orgpolicy.policyAdmin` ← **most teams are missing this** |

> [!CAUTION]
> `roles/orgpolicy.policyAdmin` must be granted at the **GCP Organization level**,
> not the project level. This is the #1 first-deploy failure. If your account
> doesn't have it, ask your GCP org admin — or have the foundation owner run
> `terraform apply -target=google_org_policy_custom_constraint.*` once with
> elevated credentials.

**Authenticate:**
```bash
gcloud auth application-default login
gcloud auth login
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
organization_id = "123456789012"          # gcloud organizations list
location        = "us-east1"
prefix          = "myteam"               # short prefix, no spaces
agent_name      = "my_agent"             # must be a Python identifier (underscores, not hyphens)
agent_description = "What my agent does."

allowed_egress_hosts = [
  "api.example.com",   # every external host your agent needs to call
]

sgp_nlc_constraint = <<-EOT
  This agent helps with [YOUR TOPIC]. It may only answer questions about
  [ALLOWED SCOPE]. Allowed code: Python, Terraform, Bash only.
EOT
```

### 2. Add your agent code

```
agents/
└── my-agent/
    ├── agent.py          ← your agent logic (see template/ for a starter)
    └── requirements.txt  ← must have pinned versions (google-adk==X.Y.Z)
```

Use the `GatewayAgent` SDK — it handles all compliance automatically:

```python
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))
from gateway_agent import GatewayAgent

root_agent = GatewayAgent(
    name="my_agent",
    model="gemini-2.5-flash",
    description="My agent.",
    instruction="You are a helpful assistant.",
    tools=[],
)
```

### 3. Deploy

```bash
bash deploy_all.sh
```

**4 phases, ~20 minutes total:**

| Phase | What runs | Duration |
|---|---|---|
| 1 — Infra | `terraform apply` — VPC, PSC, Model Armor, org policies, dashboard | ~10 min |
| 2 — Agent | `deploy_chat_agent.sh` — packages and deploys to Vertex AI RE | ~8 min |
| 3 — SGP | `create_sgp_policy.sh` — registers NLC topic constraint | ~1 min |
| 4 — Tests | `run_guardrail_tests.py` — 8 guardrail tests | ~2 min |

### 4. Tear down

```bash
bash destroy_all.sh
```

---

## Path B — Sidecar Setup (Existing Repo)

### 1. Add as git submodule

```bash
# From your existing repo root
git submodule add https://github.com/GCP-Architecture-Guides/Agent-Gateway-Foundation.git foundation
git commit -m "feat: add Agent-Gateway-Foundation as submodule"

# Pin to a release
cd foundation && git checkout v1.0.0 && cd ..
git add foundation && git commit -m "chore: pin foundation to v1.0.0"
```

> [!CAUTION]
> Use `git submodule add` — NOT `git clone`. A plain clone creates a nested
> `.git` that your parent repo cannot track. The foundation will silently
> be missing from your commits.

### 2. Add to your parent repo's .gitignore

```gitignore
# Agent-Gateway-Foundation — never commit project-specific config
foundation/terraform.tfvars
foundation/*.tfvars
!foundation/*.tfvars.example
foundation/.terraform/
foundation/*.tfstate*
foundation/agents/*/.env
```

### 3. Configure

```bash
cp foundation/terraform.tfvars.example foundation/terraform.tfvars
```

Add three anchor comments at the top so Antigravity knows your layout:

```hcl
# FOUNDATION_ROOT: foundation/
# AGENT_PATH: src/my-agent
# DEPLOY_TARGET: reasoning_engine

project_id      = "your-gcp-project-id"
organization_id = "123456789012"
location        = "us-east1"
prefix          = "myteam"
agent_name      = "my_agent"
agent_description = "What my agent does."
# ... rest of fields same as Path A
```

### 4. Deploy infrastructure

```bash
terraform -chdir=foundation init
terraform -chdir=foundation apply -auto-approve
```

### 5. Deploy your existing agent

```bash
# Your agent code stays where it is — pass its path to the deploy script
bash foundation/scripts/deploy_chat_agent.sh --agent-path ./src/my-agent

# The script will:
# - Write ./src/my-agent/.env with gateway env vars (from terraform outputs)
# - Bundle the GatewayAgent SDK into your agent dir temporarily
# - Deploy to Vertex AI RE via adk deploy
# - Clean up the bundle
```

> [!IMPORTANT]
> Add `src/my-agent/.env` to your `.gitignore` — it contains live project
> credentials and is regenerated on every deploy.


### 6. Update the foundation

```bash
cd foundation && git checkout v1.1.0 && cd ..
git add foundation && git commit -m "chore: bump foundation to v1.1.0"

# Re-apply — only changed resources update
terraform -chdir=foundation apply -auto-approve
```

---

## Path C — Gitignored Subfolder (No Submodule Complexity)

**One git clone. Then everything is local.** No submodule, no scripts, no
ongoing git relationship with the foundation.

```
my-team-repo/                ← your repo (pushed to GitHub normally)
  ├── src/
  │   └── my-agent/          ← your agent code (tracked, pushed)
  ├── .gitignore             ← includes "foundation/"
  └── foundation/            ← one-time clone (gitignored, stays local)
        └── terraform.tfvars ← gitignored, you fill this in once
```

### 1. One-time setup

```bash
# From your team repo root:

# Step 1 — gitignore the foundation folder
echo "foundation/" >> .gitignore
echo "src/my-agent/.env" >> .gitignore
git add .gitignore && git commit -m "chore: gitignore AGW foundation"

# Step 2 — clone the foundation once (not a submodule, just files)
git clone https://github.com/GCP-Architecture-Guides/Agent-Gateway-Foundation.git foundation

# Step 3 — create your config
cp foundation/terraform.tfvars.example foundation/terraform.tfvars
# Fill in foundation/terraform.tfvars — that's the only file you ever edit
```

> [!NOTE]
> After the clone, `foundation/` is just a folder of files on your machine.
> It is **not tracked** by your team repo. No `git push`, no `git pull`,
> no submodule commands. It stays local.

### 2. Configure terraform.tfvars

Anchor comments use relative paths — works for every developer:

```hcl
# FOUNDATION_ROOT: foundation/
# AGENT_PATH: src/my-agent
# DEPLOY_TARGET: reasoning_engine

project_id      = "your-gcp-project-id"
organization_id = "123456789012"
location        = "us-east1"
prefix          = "myteam"
agent_name      = "my_agent"
agent_description = "What my agent does."
# ... rest of fields same as Path A
```

### 3. Deploy infrastructure

```bash
terraform -chdir=foundation init
terraform -chdir=foundation apply -auto-approve
```

### 4. Deploy your agent

```bash
bash foundation/scripts/deploy_chat_agent.sh --agent-path ./src/my-agent
```


### 5. Wire Antigravity skills (once per developer)

```bash
mkdir -p ~/.gemini/config/skills
for d in foundation/skills/*/; do
  ln -sf "$(pwd)/$d" ~/.gemini/config/skills/"$(basename $d)"
done
```

### 6. When you need a newer foundation version

Delete and re-clone. That's it:

```bash
rm -rf foundation
git clone https://github.com/GCP-Architecture-Guides/Agent-Gateway-Foundation.git foundation
cp foundation/terraform.tfvars.example foundation/terraform.tfvars
# Re-fill in your values (or keep a backup of your old terraform.tfvars)
terraform -chdir=foundation init
terraform -chdir=foundation apply -auto-approve
```

### Onboarding a new developer

They clone the team repo, then do the same one-time clone:

```bash
git clone https://github.com/my-team/my-agent-repo.git
cd my-agent-repo
git clone https://github.com/GCP-Architecture-Guides/Agent-Gateway-Foundation.git foundation
cp foundation/terraform.tfvars.example foundation/terraform.tfvars
# Fill in terraform.tfvars — done
```

---

## Antigravity Skills Setup (AI Coding Assistant)

The `skills/` directory contains SKILL.md files that teach Antigravity
exactly how to set up and maintain every layer of this foundation.

**One-time setup — run after cloning or adding the submodule:**

```bash
# Standalone (run from repo root)
mkdir -p ~/.gemini/config/skills
for d in skills/*/; do
  ln -sf "$(pwd)/$d" ~/.gemini/config/skills/"$(basename $d)"
done

# Sidecar (run from parent repo root)
mkdir -p ~/.gemini/config/skills
for d in foundation/skills/*/; do
  ln -sf "$(pwd)/$d" ~/.gemini/config/skills/"$(basename $d)"
done

echo "✅ $(ls skills/ 2>/dev/null || ls foundation/skills/) skills linked"
```

**What each skill does:**

| Skill | When Antigravity reads it |
|---|---|
| `agw-foundation-adoption` | "Set up the gateway" / "Wire my agent to it" |
| `gateway-agent-sdk` | "My agent has no telemetry" / "Add GatewayAgent to my agent" |
| `sgp-network-authz-pattern` | "Set up the SGP policy engine" |
| `sgp-policy-rules` | "Add/change what my agent is allowed to discuss" |
| `agent-gateway-deploy-patch` | "RE deploy fails with code 13 / org policy error" |
| `cloud-run-deploy-guardrails` | "Deploy my backend to Cloud Run with IAP" |
| `vertex-ai-global-endpoint-adk` | "My agent returns 404 for the model" |

---

## Config Flow — Where Values Come From

Everything flows from one file. Nothing is hardcoded anywhere else.

```
terraform.tfvars
  │
  ├─▶ terraform apply
  │     Creates: PSC, Model Armor, Org Policies, SGP engine, dashboard
  │
  ├─▶ deploy_chat_agent.sh  (reads tfvars directly)
  │     Writes: agents/MY-AGENT/.env
  │       GCP_PROJECT_ID
  │       GOOGLE_CLOUD_LOCATION
  │       AGENT_GATEWAY_INGRESS   ← derived from prefix + project + location
  │       AGENT_GATEWAY_EGRESS    ← derived from prefix + project + location
  │       OTEL 3-layer fix vars   ← mandatory, prevents OTEL crashes in RE
  │
  └─▶ create_sgp_policy.sh
        Registers: NLC topic constraint from sgp_nlc_constraint field
```

---

## Repository Structure

```
Agent-Gateway-Foundation/
├── terraform.tfvars.example    ← copy this, fill in your values
├── deploy_all.sh               ← 4-phase end-to-end deploy
├── destroy_all.sh              ← 4-phase mirrored teardown
├── 01_apis.tf                  ← GCP API enablement
├── 02_network.tf               ← VPC, subnets, PSC
├── 03_security_and_gateways.tf ← Agent Gateway, Model Armor, Cloud Armor
├── 04_observability.tf         ← dashboards, log metrics, alerts
├── 05_org_policies.tf          ← 3 custom org policy constraints
├── 06_agent_provisioning.tf    ← IAM for agent identity
├── agents/
│   └── chat-agent/             ← reference agent (uses GatewayAgent SDK)
├── lib/
│   └── gateway_agent/          ← GatewayAgent SDK (copy into your agent)
│       ├── agent.py            ← GatewayAgent class
│       ├── global_gemini.py    ← PSC-compatible regional Gemini wrapper
│       └── telemetry.py        ← OTEL token usage callback
├── scripts/
│   ├── deploy_chat_agent.sh    ← agent deploy (supports --agent-path)
│   ├── create_sgp_policy.sh    ← SGP NLC policy registration
│   └── patch_sdk_for_rest_create.py  ← org policy bypass monkey-patch
├── skills/                     ← Antigravity skill library
├── test-agent/                 ← 8 guardrail tests
├── template/                   ← starter templates for new agents
├── KNOWN_ISSUES.md             ← 8 production failure runbooks
└── CHANGELOG.md
```

---

## Troubleshooting

See [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) for the full runbook. Quick reference:

| Symptom | Issue | Fix |
|---|---|---|
| `403 org policy` on first deploy | Missing `orgpolicy.policyAdmin` at org level | Get org admin to grant it, or run org policy targets separately |
| `400 FAILED_PRECONDITION` on RE create | Org policy not propagated (needs 180s) | Wait and re-run `deploy_chat_agent.sh` |
| `gRPC code 13 INTERNAL` on RE create | `agentGatewayConfig` missing from request | Check `.pth` monkey-patch ran correctly |
| Agent returns 0 events, no error | `after_model_callback` TypeError (ADK 1.31+) | Use `GatewayAgent` — fixes callback signature automatically |
| First query works, rest silent | OTEL mTLS SSL crash | `GOOGLE_API_USE_MTLS_ENDPOINT=never` in `.env` (deploy script does this) |
| Container startup `ValidationError` | Unpinned `google-adk` or `google-cloud-aiplatform` | Pin to exact versions in `requirements.txt` |
| `ModuleNotFoundError: gateway_agent` | `lib/` not on Python path | Add `sys.path.insert(0, "../../lib")` at top of `agent.py` |

---

## Important Notes

- **`agent_name` must be a Python identifier** — use underscores, not hyphens (`my_agent` ✅, `my-agent` ❌)
- **Never commit `terraform.tfvars`** — it contains your project ID and org ID (gitignored by default)
- **SDK version pins are mandatory** — do NOT remove pins in `requirements.txt`. See `KNOWN_ISSUES.md` before upgrading `google-adk` or `google-cloud-aiplatform`
- **RE state shows UNKNOWN after deploy** — this is normal platform lag. Wait 5 minutes before running tests
- **`.env` is overwritten on every deploy** — never edit it directly; add env vars to the deploy script's heredoc

---

## License

See [LICENSE](LICENSE) file.
