---
name: agw-foundation-adoption
description: >
  Use this skill when onboarding a new team to the Agent-Gateway-Foundation.
  Covers all three adoption paths: Path A (standalone new project), Path B
  (git submodule sidecar in existing repo), and Path C (gitignored subfolder
  in team repo — one-time clone, no submodule). Documents terraform.tfvars
  anchor comments, --agent-path flag, Antigravity skills symlink,
  multi-agent deploy, and foundation update patterns. Read this before
  touching any config or deploy commands.
---

# Agent-Gateway-Foundation — Adoption Guide

> [!IMPORTANT]
> **One source of truth:** `terraform.tfvars` is the ONLY file a team fills in.
> Everything else — gateway paths, project ID, OTEL env vars — flows down
> from it automatically. Never hardcode these values in agent code.

## Which Path Applies?

| Path | When to use |
|---|---|
| **A — Standalone** | New GCP project, no existing agent code — clone and go |
| **B — Sidecar** | Existing GitHub repo with existing agent — git submodule |
| **C — Gitignored Subfolder** | Existing repo, no submodule complexity — one-time clone into `foundation/`, gitignored, relative paths |

---

## Pre-Deploy Checklist

Run through this BEFORE `terraform apply` or `deploy_chat_agent.sh`. Fix anything
that fails before proceeding — these are the most common sources of wasted time.

- [ ] **APIs bootstrapped** — required on any fresh project BEFORE `terraform init`:
  ```bash
  gcloud services enable cloudresourcemanager.googleapis.com agentregistry.googleapis.com \
    --project=YOUR_PROJECT_ID
  ```
- [ ] **`agent_name` is a Python identifier** — underscores only, no hyphens.
  `my_agent` ✅ · `my-agent` ❌ (deploy script validates and fails fast)
- [ ] **`requirements.txt` has pinned versions** — `google-adk==X.Y.Z` and
  `google-cloud-aiplatform==X.Y.Z` must use `==`. Unpinned versions install latest
  in the RE container and cause startup failures. See `KNOWN_ISSUES.md #008`.
- [ ] **`agent.py` uses `GatewayAgent`** — NOT bare `Agent` from `google.adk.agents`.
  Read the `gateway-agent-sdk` skill if migration is needed.
- [ ] **`roles/orgpolicy.policyAdmin` at ORG level** — NOT project level. This is the
  #1 first-deploy failure. Ask your GCP org admin to grant it at the org level.
- [ ] **`terraform.tfvars` has anchor comments** at the top:
  ```hcl
  # FOUNDATION_ROOT: foundation/
  # AGENT_PATH: src/my-agent
  # DEPLOY_TARGET: reasoning_engine
  ```

---

 (Existing GitHub Repo)

The recommended team pattern. The foundation handles infrastructure;
your agent code stays where it is in your existing repo.

```
my-team-repo/                   ← your existing repo
  ├── src/
  │   └── my-agent/             ← your existing agent code
  │       ├── agent.py
  │       └── requirements.txt
  └── foundation/               ← Agent-Gateway-Foundation as git submodule
        ├── terraform.tfvars    ← ONLY file you fill in (gitignored)
        ├── deploy_all.sh
        └── scripts/
              └── deploy_chat_agent.sh  ← accepts --agent-path ../src/my-agent
```

Antigravity acts as the integration layer: it reads Terraform outputs from
`foundation/` and wires them into your agent code automatically using the skills.

---

## Step 1 — Add Foundation as Git Submodule

```bash
# From your existing repo root
git submodule add https://github.com/GCP-Architecture-Guides/Agent-Gateway-Foundation.git foundation
git commit -m "feat: add Agent-Gateway-Foundation as submodule"

# Pin to a stable release (recommended for production)
cd foundation && git checkout v1.0.0 && cd ..
git add foundation && git commit -m "chore: pin foundation to v1.0.0"
```

**To update the foundation later:**
```bash
cd foundation && git checkout v1.1.0 && cd ..
git add foundation && git commit -m "chore: bump foundation to v1.1.0"
# Review CHANGELOG.md before re-running deploy_all.sh — check for breaking changes
```

> [!CAUTION]
> Do NOT use `git clone` into a subfolder. Git treats a nested `.git` directory
> as an untracked path and silently ignores it — the foundation never gets
> committed to your repo. Always use `git submodule add`.

---

## Step 2 — Add Foundation to Your Parent Repo's .gitignore

Add these lines to YOUR repo's `.gitignore` (not the foundation's):

```gitignore
# Agent-Gateway-Foundation — never commit project-specific config
foundation/terraform.tfvars
foundation/*.tfvars
!foundation/*.tfvars.example
foundation/.terraform/
foundation/*.tfstate*
foundation/agents/*/.env
```

This prevents `terraform.tfvars` (which contains your project ID and org ID)
from accidentally being committed to your public repo.

---

## Step 3 — Fill in terraform.tfvars

```bash
cp foundation/terraform.tfvars.example foundation/terraform.tfvars
```

Add three anchor comments at the top so Antigravity knows your repo layout:

```hcl
# FOUNDATION_ROOT: foundation/
# AGENT_PATH: src/my-agent
# DEPLOY_TARGET: reasoning_engine

# ── Required fields ───────────────────────────────────────────────────────────
project_id      = "your-gcp-project-id"
organization_id = "123456789012"        # GCP org ID — needed for org policies
location        = "us-east1"
prefix          = "myteam"             # short, no spaces (e.g. "acme-ml")

agent_name        = "my_agent"
agent_description = "What this agent does."

allowed_egress_hosts = [
  "api.example.com",          # every external host your agent calls
]

sgp_nlc_constraint = <<-EOT
  This agent helps with [YOUR TOPIC]. It may only answer questions about
  [ALLOWED SCOPE]. It must NOT discuss competitor products or generate
  code outside of Python, Terraform, and Bash.
EOT
```

> [!CAUTION]
> `organization_id` requires `roles/orgpolicy.policyAdmin` at the **org level**.
> This is the #1 first-deploy failure. If your account lacks it, ask your
> GCP org admin to grant it — or ask the foundation owner to run the org
> policy resources once with elevated credentials:
> `terraform -chdir=foundation apply -target=google_org_policy_custom_constraint.*`

---

## Step 4 — Wire Antigravity Skills (Once Per Developer)

```bash
# From your repo root — creates symlinks to the foundation's skills
mkdir -p ~/.gemini/config/skills
for d in foundation/skills/*/; do
  ln -sf "$(pwd)/$d" ~/.gemini/config/skills/"$(basename $d)"
done
echo "✅ $(ls foundation/skills/ | wc -l) skills linked"
```

**Verify:** Ask Antigravity: *"What Agent Gateway skills do you have?"*
It will list them and automatically read the right skill for any task.

Skills update automatically when you `git checkout` a new foundation version
(symlinks point into the submodule which updates in place).

---

## Step 5 — Deploy Infrastructure

```bash
# Run Terraform from your repo root using -chdir
terraform -chdir=foundation init
terraform -chdir=foundation apply -auto-approve
```

Or run the full end-to-end pipeline:
```bash
# Phase 1 only (infra) — if you want to wire agent code before deploying it
bash foundation/deploy_all.sh --phases infra
```

**After apply, read the outputs — these are what flow into your agent:**
```bash
terraform -chdir=foundation output -json
# Returns: ingress_gateway, egress_gateway, project_id, region, prefix
```

---

## Step 6 — Deploy Your Agent

### Deploy — Reasoning Engine (Vertex AI Agent Engine)

```bash
# Your agent code stays in src/my-agent/ — pass the path to the deploy script
bash foundation/scripts/deploy_chat_agent.sh --agent-path ./src/my-agent
```

The script will:
1. Validate `src/my-agent/requirements.txt` has pinned versions
2. Write `src/my-agent/.env` with gateway env vars (from tfvars)
3. Bundle the GatewayAgent SDK into `src/my-agent/` temporarily
4. Run `adk deploy agent_engine` pointing at your directory
5. Clean up the bundle after deploy

> [!IMPORTANT]
> The script writes `.env` directly into your agent directory at deploy time.
> Add `src/my-agent/.env` to your repo's `.gitignore` — it contains live
> project credentials and is regenerated on every deploy.

---

## Config Flow Reference

| Value in agent | Source | How It Gets There |
|---|---|---|
| `GCP_PROJECT_ID` | `terraform.tfvars: project_id` | Written to `.env` by deploy script |
| `GOOGLE_CLOUD_LOCATION` | `terraform.tfvars: location` | Written to `.env` |
| `AGENT_GATEWAY_INGRESS` | Derived: `prefix + project + location` | Written to `.env` |
| `AGENT_GATEWAY_EGRESS` | Derived: `prefix + project + location` | Written to `.env` |
| Egress allowlist | `terraform.tfvars: allowed_egress_hosts` | PSC routing via Terraform |
| Topic constraint | `terraform.tfvars: sgp_nlc_constraint` | SGP engine via `create_sgp_policy.sh` |
| OTEL tags | `terraform.tfvars: agent_name, agent_description` | Injected by `.pth` patch |

> [!WARNING]
> `.env` is **overwritten on every `deploy_chat_agent.sh` run**. Never edit it
> directly. If you need persistent env vars, add them inside the `.env`
> heredoc block in `foundation/scripts/deploy_chat_agent.sh`.

---

## Adding a Second Agent (or More)

The gateway is deployed once and shared. Each additional agent needs only its own
deploy — no `terraform apply` unless it calls new external hosts.

```bash
# Use --agent-name to set a different name without changing terraform.tfvars
bash foundation/scripts/deploy_chat_agent.sh \
  --agent-path ./src/my-second-agent \
  --agent-name agent_two \
  --agent-description "What agent two does"

# Register a new SGP policy for it
# (Read the agw-add-sgp-policy skill for the full workflow)
bash foundation/scripts/create_sgp_policy.sh
```

> [!NOTE]
> `--agent-name` must be a Python identifier — underscores only.
> The deploy script validates this and fails fast if hyphens are used.

---


## Path C — Gitignored Subfolder (No Submodule Complexity)

**One git clone. Then everything is local.** No scripts, no submodule,
no ongoing git relationship with the foundation.

```
my-team-repo/                ← team repo (pushed to GitHub)
  ├── src/my-agent/          ← agent code (tracked, pushed)
  ├── .gitignore             ← includes "foundation/"
  └── foundation/            ← one-time clone (stays local, never pushed)
        └── terraform.tfvars ← gitignored, fill it in once
```

### C-1 — One-time setup

```bash
# From team repo root:

# Gitignore the foundation folder
echo "foundation/" >> .gitignore
echo "src/my-agent/.env" >> .gitignore
git add .gitignore && git commit -m "chore: gitignore AGW foundation"

# Clone once — not a submodule, just files
git clone https://github.com/GCP-Architecture-Guides/Agent-Gateway-Foundation.git foundation

# Create config
cp foundation/terraform.tfvars.example foundation/terraform.tfvars
# Fill in foundation/terraform.tfvars — the ONLY file you edit from here
```

After this: `foundation/` is a regular folder on your machine.
No tracking, no pushing, no git commands against it.

### C-2 — Configure terraform.tfvars

```hcl
# FOUNDATION_ROOT: foundation/
# AGENT_PATH: src/my-agent
# DEPLOY_TARGET: reasoning_engine

project_id = "your-project-id"
# ... rest of fields same as Path B
```

### C-3 — Deploy infrastructure

```bash
terraform -chdir=foundation init
terraform -chdir=foundation apply -auto-approve
```

### C-4 — Deploy your agent

```bash
bash foundation/scripts/deploy_chat_agent.sh --agent-path ./src/my-agent
```


### C-5 — Wire Antigravity skills (once per developer)

```bash
mkdir -p ~/.gemini/config/skills
for d in foundation/skills/*/; do
  ln -sf "$(pwd)/$d" ~/.gemini/config/skills/"$(basename $d)"
done
```

### C-6 — Need a newer foundation version?

Delete and re-clone. That's it:

```bash
# Back up terraform.tfvars first!
cp foundation/terraform.tfvars ~/terraform.tfvars.backup

rm -rf foundation
git clone https://github.com/GCP-Architecture-Guides/Agent-Gateway-Foundation.git foundation

# Restore your config
cp ~/terraform.tfvars.backup foundation/terraform.tfvars

terraform -chdir=foundation init
terraform -chdir=foundation apply -auto-approve
```

### C-7 — Onboarding a new developer

They clone the team repo, then do the same one-time clone:

```bash
git clone https://github.com/my-team/my-agent-repo.git
cd my-agent-repo
git clone https://github.com/GCP-Architecture-Guides/Agent-Gateway-Foundation.git foundation
cp foundation/terraform.tfvars.example foundation/terraform.tfvars
# Fill in terraform.tfvars — done
```

---

## Adding a New Egress Endpoint

When an agent needs to call an external host that is NOT already in the gateway:

```bash
# 1. Add the hostname to terraform.tfvars (hostname only — no https://, no path)
allowed_egress_hosts = [
  "api.existing-host.com",   # already there
  "api.new-host.com",        # ADD THIS
]

# 2. Apply — PSC route is added automatically
terraform -chdir=foundation apply -auto-approve

# No agent redeploy. No gateway restart needed.
# The gateway is deny-by-default: hosts not listed have no PSC route
# and outbound connections are silently dropped.
```

> [!NOTE]
> Only the hostname goes in `allowed_egress_hosts` — not the full URL.
> For HTTPS APIs: `api.example.com` (no `https://`, no path, no port).

---

## Common First-Deploy Failures

| Error / Symptom | Root Cause | Fix |
|---|---|---|
| `403: Cloud Resource Manager API disabled` | CRM must be enabled BEFORE `terraform init` (chicken-and-egg) | `gcloud services enable cloudresourcemanager.googleapis.com agentregistry.googleapis.com --project=PROJECT_ID` |
| `403 on org policy resources` | Missing `roles/orgpolicy.policyAdmin` at ORG level (not project) | Ask GCP org admin to grant at org level, or run with `--target=google_org_policy_custom_constraint.*` |
| `400 FAILED_PRECONDITION` on RE create | Org policy propagation lag (terraform waits 180s — sometimes needs extra 60s) | Wait 3 min, re-run `deploy_chat_agent.sh` |
| `agent.py not found` | Wrong `--agent-path` — path is relative to your CWD, not foundation root | Use `./src/my-agent` from repo root, not from inside `foundation/` |
| `ModuleNotFoundError: gateway_agent` | GatewayAgent SDK not bundled | Confirm `foundation/lib/gateway_agent/` exists; deploy script auto-bundles it |
| RE state `UNKNOWN` for 5+ min | Platform state propagation lag — normal on first deploy | Wait 5 min, run `test-agent/run_guardrail_tests.py` — agent is likely running |
| `agent_name` rejected / Python identifier error | Hyphen in agent name | Rename: `agent_two` ✅ not `agent-two` ❌ — deploy script validates this |
| `BaseModel.__init__() takes 1 positional argument` | Pydantic v2 change in `GlobalGemini` | Use `GlobalGemini(model=model)` keyword arg — see `KNOWN_ISSUES.md #003` |
| Model Armor 403 on ALL agent responses | PI/Jailbreak filter on `response_template_id` | Remove `response_template_id` — only `request_template_id` — see `KNOWN_ISSUES.md #001` |
| OTEL SSL crash / RE silent after 1-2 queries | mTLS + aiohttp session singleton (3-layer bug) | Deploy script auto-fixes via 5 OTEL env vars in `.env` — see `KNOWN_ISSUES.md #007` |
| SGP policy creation fails with `RuntimeIdentity` error | RE not yet ACTIVE / using wrong agent registry entry | Wait 2-3 min after deploy; use only `agentregistry-UUID` entries with `runtimeIdentity` |
| `contextSpec.memoryBankConfig` on RE create | Platform auto-injects field on CREATE | Deploy script patches this via REST after deploy — expected behaviour |
| Unpinned `requirements.txt` fails at startup | Latest SDK changes internal transport, breaks `.pth` patch | Pin `google-adk==X.Y.Z` and `google-cloud-aiplatform==X.Y.Z` — see `KNOWN_ISSUES.md #008` |

See `foundation/KNOWN_ISSUES.md` for full root-cause analysis and rollback procedures.
