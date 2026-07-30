# Antigravity Prompt — Agent Gateway Foundation (Path C)

> Copy and paste the prompt below into Antigravity as-is.
> No values are hardcoded — Antigravity will ask you for everything it needs.

---

```
Read the skill at skills/agw-foundation-adoption/SKILL.md before doing anything else.

I am using Path C (gitignored subfolder). This means:
- My team repo is on GitHub (or local git)
- The Agent Gateway Foundation is (or will be) cloned into foundation/ inside my repo
- foundation/ is gitignored — it never gets pushed
- I do NOT use git submodules

Before you do anything, check the following to determine which scenario I am in:

SCENARIO A — First-time setup (foundation not yet cloned):
  Check: does foundation/terraform.tfvars exist?
  If NO → I need the full setup: bootstrap APIs, clone foundation, fill in tfvars,
           deploy infrastructure, deploy my first agent.

SCENARIO B — Gateway already deployed, adding a new agent:
  Check: does foundation/terraform.tfvars exist AND does it have a project_id value?
  If YES → Skip infrastructure. Just deploy a new agent to the existing gateway.

---

SCENARIO A INSTRUCTIONS (if foundation/terraform.tfvars does not exist):

Ask me for the following values one at a time, then execute each step:

  1. project_id       — GCP project ID (e.g. my-project-id)
  2. location         — GCP region (e.g. us-east1)
  3. prefix           — Short identifier, no spaces or hyphens (e.g. myteam)
  4. agent_name       — Python identifier for first agent (underscores, no hyphens)
  5. agent_description — One sentence describing what this agent does
  6. agent_path       — Path to my agent folder relative to repo root (e.g. ./src/my-agent)
  7. allowed_egress_hosts — List of external hostnames this agent calls (comma-separated, or "none")
  8. sgp_nlc_constraint   — In plain English: what is this agent allowed and NOT allowed to do?
  9. organization_id  — GCP Org ID (12-digit number) — needed for org policies

Then execute in order:

  Step 0 — Bootstrap prerequisite APIs:
    gcloud services enable cloudresourcemanager.googleapis.com agentregistry.googleapis.com \
      --project=[project_id]

  Step 1 — Gitignore the foundation folder:
    echo "foundation/" >> .gitignore
    echo "[agent_path]/.env" >> .gitignore
    git add .gitignore && git commit -m "chore: gitignore AGW foundation"

  Step 2 — Clone foundation (one time):
    git clone https://github.com/GCP-Architecture-Guides/Agent-Gateway-Foundation.git foundation

  Step 3 — Fill in terraform.tfvars:
    cp foundation/terraform.tfvars.example foundation/terraform.tfvars
    Then write the values I gave you into foundation/terraform.tfvars.
    Include anchor comments at the top:
      # FOUNDATION_ROOT: foundation/
      # AGENT_PATH: [agent_path]
      # DEPLOY_TARGET: reasoning_engine

  Step 4 — Pre-deploy checklist (verify before running terraform):
    - [ ] agent_name has no hyphens (Python identifier only)
    - [ ] requirements.txt in agent folder has pinned versions for google-adk and google-cloud-aiplatform
    - [ ] agent.py imports GatewayAgent from gateway_agent SDK (not bare Agent from google.adk.agents)
    - [ ] I have roles/orgpolicy.policyAdmin at the GCP ORG level (not just project)
    If any check fails, fix it before proceeding.

  Step 5 — Deploy infrastructure:
    terraform -chdir=foundation init
    terraform -chdir=foundation apply -auto-approve
    (Terraform waits 180s for org policy propagation — this is normal)

  Step 6 — Deploy first agent:
    bash foundation/scripts/deploy_chat_agent.sh --agent-path [agent_path]

  Step 7 — Register SGP policy:
    bash foundation/scripts/create_sgp_policy.sh

  Step 8 — Wire Antigravity skills (once per developer):
    mkdir -p ~/.gemini/config/skills
    for d in foundation/skills/*/; do
      ln -sf "$(pwd)/$d" ~/.gemini/config/skills/"$(basename $d)"
    done

  Step 9 — Confirm success:
    Report the Reasoning Engine resource ID and state (should be ACTIVE).
    Show the terraform outputs: ingress_gateway, egress_gateway, project_id.

---

SCENARIO B INSTRUCTIONS (if foundation/ already exists and gateway is deployed):

Ask me for the following, then execute:

  1. agent_path        — Path to the NEW agent folder (e.g. ./src/agent-two)
  2. agent_name        — Python identifier for this agent (underscores, no hyphens)
  3. agent_description — One sentence describing what this agent does
  4. new_egress_hosts  — Any NEW external hostnames this agent calls that are NOT already
                         in foundation/terraform.tfvars allowed_egress_hosts (or "none")
  5. sgp_nlc_constraint — In plain English: what is this agent allowed and NOT allowed to do?

Then execute in order:

  Step 1 — Pre-deploy checklist:
    - [ ] agent_name has no hyphens
    - [ ] requirements.txt has pinned versions for google-adk and google-cloud-aiplatform
    - [ ] agent.py imports GatewayAgent from gateway_agent SDK

  Step 2 — If new_egress_hosts were provided:
    Add them to foundation/terraform.tfvars allowed_egress_hosts list, then:
    terraform -chdir=foundation apply -auto-approve

  Step 3 — Deploy the new agent:
    bash foundation/scripts/deploy_chat_agent.sh \
      --agent-path [agent_path] \
      --agent-name [agent_name] \
      --agent-description "[agent_description]"

  Step 4 — Register SGP policy:
    Update foundation/terraform.tfvars: set agent_name and sgp_nlc_constraint
    to the values for this new agent, then:
    bash foundation/scripts/create_sgp_policy.sh

  Step 5 — Confirm success:
    Report the new Reasoning Engine resource ID and state (should be ACTIVE).

---

If anything fails, read foundation/KNOWN_ISSUES.md for root causes and fixes.
Also read the gateway-agent-sdk skill if agent.py needs to be migrated to GatewayAgent.
```
