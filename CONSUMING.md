# Consuming mod-agw-foundation as a Reusable Security Platform

This guide walks a new team through setting up their own isolated Agent Gateway
security stack using `mod-agw-foundation` as a Terraform module, then deploying
their own agent on top of it.

---

## Prerequisites

1. A GCP project with billing enabled
2. `gcloud`, `terraform >= 1.5`, `python3 >= 3.11` installed
3. Authenticated: `gcloud auth application-default login`
4. The `gateway-agent-sdk` published to Artifact Registry (see [Publishing the SDK](#publishing-the-sdk))

---

## Step 1 — Set Up Your Project Terraform

Create a new directory for your project. You do NOT need to clone or copy this
entire repository — Terraform will pull it directly from GitHub.

```bash
mkdir my-team-infra && cd my-team-infra
```

**`main.tf`**
```hcl
# Pull the foundation module directly from GitHub.
# Pin to a specific tag (e.g., v1.0.0) for stability.
module "agw_foundation" {
  source = "github.com/your-org/mod-agw-foundation?ref=v1.0.0"

  # Required
  project_id      = var.project_id
  organization_id = var.organization_id
  region          = var.region
  location        = var.location
  prefix          = var.prefix

  # Skip the built-in chat-agent — you'll deploy your own
  create_agent = false

  # Add your agent's egress dependencies
  allowed_egress_hosts = concat(
    [
      "aiplatform.googleapis.com",
      "telemetry.googleapis.com",
      "logging.googleapis.com",
      "cloudtrace.googleapis.com",
      "oauth2.googleapis.com",
      "iamcredentials.googleapis.com",
      "secretmanager.googleapis.com",
    ],
    var.custom_egress_hosts
  )
}

# Expose gateway paths so your agent deploy script can read them
output "ingress_gateway_name" { value = module.agw_foundation.ingress_gateway_name }
output "egress_gateway_name"  { value = module.agw_foundation.egress_gateway_name }
output "project_number"       { value = module.agw_foundation.project_number }
```

**`variables.tf`**
```hcl
variable "project_id"       { type = string }
variable "organization_id"  { type = string }
variable "region"           { type = string; default = "us-east1" }
variable "location"         { type = string; default = "us-east1" }
variable "prefix"           { type = string }
variable "custom_egress_hosts" { type = list(string); default = [] }
```

**`terraform.tfvars`** (copy from `template/terraform.tfvars.example`, fill in):
```hcl
project_id      = "my-team-project-id"
organization_id = "123456789012"
region          = "us-east1"
location        = "us-east1"
prefix          = "my-team"
custom_egress_hosts = [
  "api.github.com",
]
```

---

## Step 2 — Provision the Security Infrastructure

```bash
terraform init
terraform plan   # review — should create ~40 resources
terraform apply  # takes ~5 minutes (PSC propagation)
```

This creates:
- ✅ Ingress + Egress Agent Gateways
- ✅ PSC network attachment (egress routing)
- ✅ Model Armor templates (security-high, security-responses)
- ✅ SGP Authz Extension + Policy
- ✅ DLP Inspect + Deidentify templates
- ✅ Org Policy constraints
- ✅ Cloud Monitoring dashboards + log metrics

---

## Step 2.5 — Generate Agent Configuration

After `terraform apply`, generate the `agent.env` config file that your
deploy script reads. This bridges Terraform outputs → agent environment:

```bash
# If using the foundation as a module, copy the script first:
# cp path/to/mod-agw-foundation/scripts/generate_agent_config.sh scripts/

bash scripts/generate_agent_config.sh
# Writes: agent.env (gitignored)
```

The generated `agent.env` contains **everything** your agent deploy needs:

```bash
# agent.env (auto-generated — never commit this file)
export GOOGLE_CLOUD_PROJECT="my-team-project"
export GOOGLE_CLOUD_LOCATION="us-east1"
export PROJECT_NUMBER="123456789012"

# Agent Gateway — injected by .pth patch at deploy time
export AGENT_GATEWAY_INGRESS="projects/my-team-project/locations/us-east1/agentGateways/my-team-ingress-gateway"
export AGENT_GATEWAY_EGRESS="projects/my-team-project/locations/us-east1/agentGateways/my-team-egress-gateway"

# SDK install source
export AR_PYTHON_INDEX="https://us-east1-python.pkg.dev/sdk-project/agw-python-packages/simple/"

# OTEL — auto-configured by GatewayAgent SDK, no manual setup needed
export OTEL_EXPORTER_OTLP_ENDPOINT="https://telemetry.googleapis.com"
export OTEL_RESOURCE_ATTRIBUTES="gcp.project.id=my-team-project,deployment.region=us-east1"

# SDK version pins (do not change)
export GATEWAY_AGENT_SDK_VERSION="1.0.0"
export GOOGLE_ADK_VERSION="1.31.1"
export GOOGLE_CLOUD_AIPLATFORM_VERSION="1.149.0"
```

> **Add `agent.env` to your `.gitignore`** — it contains project-specific
> resource paths. Each team member runs `generate_agent_config.sh` once locally.

---

## Step 3 — Copy the Agent Template

```bash
# From your project directory
cp -r path/to/mod-agw-foundation/template/agents/my-agent ./agents/my-agent
```

Edit `agents/my-agent/agent.py` with your business logic:
```python
root_agent = GatewayAgent(
    name="my_team_agent",       # valid Python identifier, no hyphens
    model=gateway_model,
    description="What my agent does",
    instruction="Your system prompt here",
    tools=[your_tools_here],
)
```

Update `agents/my-agent/requirements.txt`:
```
--extra-index-url https://REGION-python.pkg.dev/SDK_PROJECT_ID/agw-python-packages/simple/
gateway-agent-sdk==1.0.0
google-adk==1.31.1
google-cloud-aiplatform[adk,agent_engines]==1.149.0
```

---

## Step 4 — Deploy Your Agent

Source the generated config and run the template deploy script:

```bash
# Source the config generated in Step 2.5
source agent.env

# Copy the template deploy script (one-time setup)
cp path/to/mod-agw-foundation/template/deploy_agent.sh ./deploy_agent.sh
chmod +x deploy_agent.sh

# Also copy the required patch scripts
mkdir -p scripts
cp path/to/mod-agw-foundation/scripts/patch_sdk_for_rest_create.py scripts/
cp path/to/mod-agw-foundation/scripts/generate_agent_config.sh scripts/

# Deploy
bash deploy_agent.sh
```

**What `deploy_agent.sh` does automatically:**
1. Validates all required env vars from `agent.env`
2. Creates a `.venv` with pinned SDK versions
3. Installs your `requirements.txt` from Artifact Registry
4. Applies the `.pth` gateway patch (injects `agentGatewayConfig` into `adk deploy`)
5. Runs `adk deploy agent_engine` with correct project/region/display_name

> [!IMPORTANT]
> The `.pth` patch in Step 4 is what actually binds the Reasoning Engine to the
> Agent Gateway. Without it, the RE deploys but governance (Model Armor, SGP)
> is **not enforced** even though the infra is fully deployed.
> See [KNOWN_ISSUES.md](../KNOWN_ISSUES.md) and the `agent-gateway-deploy-patch` skill.

---

## Step 5 — Verify Gateway Binding

```bash
TOKEN=$(gcloud auth print-access-token)

# Confirm agent is bound to the gateway
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines" \
  | python3 -c "
import json, sys
for e in json.load(sys.stdin).get('reasoningEngines', []):
    gw = e.get('spec',{}).get('deploymentSpec',{}).get('agentGatewayConfig')
    print(f'{e.get(\"displayName\")}: {\"✅ Gateway bound\" if gw else \"❌ No gateway\"}')
"
```

---

## Publishing the SDK

Before teams can `pip install gateway-agent-sdk`, publish it once to Artifact Registry:

```bash
# From mod-agw-foundation root:
bash scripts/publish_sdk.sh YOUR_PROJECT_ID us-east1 agw-python-packages
```

Then grant consuming projects read access to the repository:
```bash
gcloud artifacts repositories add-iam-policy-binding agw-python-packages \
  --location=us-east1 \
  --project=YOUR_PROJECT_ID \
  --member="serviceAccount:CONSUMING_PROJECT_SA@CONSUMING_PROJECT.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"
```

---

## What Each Team Owns vs What's Shared

| Layer | Who Manages | Changes When |
|---|---|---|
| Gateway infra, Model Armor, SGP, PSC | **Platform team** via Terraform module | New GCP APIs, policy updates |
| `gateway-agent-sdk` (AR package) | **Platform team** via `scripts/publish_sdk.sh` | Bug fixes, new SDK features |
| Agent code (`agents/my-agent/`) | **Your team** | Your business logic changes |
| `terraform.tfvars` | **Your team** | Your egress hosts, alert channels |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `code 13` on deploy with gateway config | See [KNOWN_ISSUES.md](../KNOWN_ISSUES.md) — usually ADK version mismatch |
| `ValidationError` on RE startup | Agent `name` has hyphens — use underscores |
| Gateway blocks all egress | Add missing hosts to `custom_egress_hosts` in tfvars |
| SGP blocks tool calls | Check `allowed_egress_hosts` — domain must be registered as PSC endpoint |
| `AgentService not supported` | See [sgp-network-authz-pattern skill](../skills/) — use Network Authz, not AI-native SGP |
