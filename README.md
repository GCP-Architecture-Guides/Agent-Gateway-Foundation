# Agent Gateway Foundation

## Overview
The Agent Gateway Foundation (`mod-agw-foundation`) is an infrastructure-as-code (IaC) deployment pipeline for securely provisioning, managing, and governing AI Agents (Reasoning Engines) in a restricted Google Cloud Platform environment.

It establishes a secure network perimeter and deploys a Reasoning Engine Agent behind an Agent Gateway with strict organizational and security policies enforced natively via Terraform and the Vertex AI Python SDK.

## Key Features
- **Streamlined Deployment**: A single `deploy_all.sh` script orchestrates the entire deployment process, eliminating the need for manual intervention or monkey-patching.
- **Secure Networking**: Provisions VPC, private subnets, PSC (Private Service Connect) Network Attachments, and Ingress/Egress Agent Gateways.
- **Automated Agent Provisioning**: Intelligently creates or updates the AI Agent (Reasoning Engine) while dynamically injecting required Organizational Policy metadata and network routing rules.
- **Robust Teardown**: A single `destroy_all.sh` script gracefully tears down the infrastructure, natively handling REST API force-deletions of locked agents and eventual consistency delays of PSC attachments.
- **Single Source of Truth**: All configurations are centrally driven by a single `terraform.tfvars` file.

## Deployment Architecture & Flow

```mermaid
graph TD
    A[deploy_all.sh] --> B[Pre-flight Checks]
    B --> C[Terraform Apply Phases 1-5]
    
    subgraph Infrastructure [Terraform Provisioning]
        C1(Enable GCP APIs)
        C2(Provision VPC & Subnets)
        C3(Create Agent Gateways & Network Attachments)
        C4(Enforce Security & Org Policies)
        C1 --> C2 --> C3 --> C4
    end
    
    C --> Infrastructure
    Infrastructure --> D[Terraform Code Gen Phase 6]
    D --> E>scripts/deploy_chat_agent.py]
    
    E --> F{Agent Already Exists?}
    F -- Yes --> G[.update() Agent via Python SDK]
    F -- No --> H[.create() Agent via Python SDK]
    
    G --> I((Agent Deployed))
    H --> I((Agent Deployed))
    I --> J[External Endpoint Registration]
```

## Repository Structure
The Terraform pipeline is logically modularized into distinct deployment phases:

- `01_apis.tf`: Enables required Google Cloud APIs (Vertex AI, Compute Engine, Network Services, etc.).
- `02_network.tf`: Provisions the global VPC, regional subnets, and PSC Network Attachments.
- `03_security_and_gateways.tf`: Deploys the secure Agent Gateway (Ingress and Egress) and associated security policies.
- `04_observability.tf`: Configures logging, monitoring, and telemetry.
- `05_org_policies.tf`: Enforces Organizational Policies (e.g., allowed APIs, compliance rules) and includes a `time_sleep` block to handle eventual consistency delays.
- `06_agent_provisioning.tf`: Automatically generates the secure Python deployment script (`scripts/deploy_chat_agent.py`). This dynamically creates a Python script that orchestrates the Reasoning Engine creation/update using the Vertex AI SDK and injects the necessary metadata to bypass gateway restrictions.

## Resources Created
When successfully deployed, the following core GCP resources are created:
1. **Network Infrastructure**: A Global VPC Network and Regional Private Subnetworks.
2. **Gateways**: Google Network Services Agent Gateway (Ingress & Egress) for robust traffic inspection.
3. **Connectivity**: Compute Network Attachments (PSC) to securely connect the Reasoning Engine to the VPC enclave.
4. **Vertex AI Resources**: A Vertex AI Reasoning Engine (Agent) backed by a Cloud Storage staging bucket (`agentic-ai-lens-staging`).
5. **IAM and Security**: Organizational policies, required Service Accounts, and appropriate IAM role bindings.

## Getting Started

### Prerequisites

| Tool | Version | Install |
|---|---|---|
| `terraform` | >= 1.5 | [Install](https://developer.hashicorp.com/terraform/install) |
| `python3` | >= 3.10 | System or [pyenv](https://github.com/pyenv/pyenv) |
| `gcloud` CLI | latest | [Install](https://cloud.google.com/sdk/docs/install) |

**GCP Requirements:**
- A GCP project with billing enabled
- A GCP Organization (org policies are applied at org level)
- `gcloud auth application-default login` configured
- The following IAM roles on the project: `roles/owner` or (`roles/editor` + `roles/orgpolicy.policyAdmin` + `roles/networkservices.admin`)

---

### 1. Clone and Configure

```bash
git clone https://github.com/YOUR_ORG/mod-agw-foundation.git
cd mod-agw-foundation

# Copy the example vars file and fill in your project details
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set:
#   project_id, organization_id, prefix, region, location
```

**`terraform.tfvars` minimum required fields:**

```hcl
project_id      = "your-gcp-project-id"
organization_id = "123456789012"      # gcloud organizations list
prefix          = "your-org-prefix"   # used to name all GCP resources
region          = "us-east1"
location        = "us-east1"
agent_name      = "chat-agent-v1"     # must be a Python identifier (no hyphens)
```

### 2. Deploy

```bash
# Deploy everything: infra + org policies + agent + guardrail tests
./deploy_all.sh
```

**What happens:**
1. `terraform apply` — provisions VPC, PSC, gateways, Model Armor, org policies (~10 min)
2. `terraform` generates `scripts/deploy_chat_agent.sh` with your project values
3. Agent is deployed to Vertex AI Reasoning Engines via `adk deploy`
4. 8 guardrail tests run automatically to verify all security layers

### 3. Verify Guardrails

The deploy automatically runs `test-agent/run_guardrail_tests.py` at the end.
You can also run it independently:

```bash
.venv/bin/python test-agent/run_guardrail_tests.py \
  --project  YOUR_PROJECT_ID \
  --location us-east1 \
  --agent-name chat-agent-v1
```

Expected: **8/8 PASS** covering prompt injection, egress blocking, DLP, and legitimate allow-through.

### 4. Destroy

```bash
# Tear down everything cleanly
./destroy_all.sh
```

---

## How to Customize the Agent

The sample agent lives in [`agents/chat-agent/agent.py`](agents/chat-agent/agent.py).
It uses the `GatewayAgent` SDK wrapper from [`lib/gateway_agent/`](lib/gateway_agent/) which provides:
- Automatic routing via the `GlobalGemini` regional endpoint override
- OTEL telemetry wired via `after_model_callback`
- Agent Gateway compliance enforcement

To add your own agent logic, edit `agents/chat-agent/agent.py` and add tools/instructions.
The model is set to `gemini-2.5-flash` by default — change it in `agent.py`.

> **SDK Version Pinning:** `requirements.txt` in the agent folder pins `google-adk==1.31.1`.
> Do NOT remove this pin. See [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) for the full explanation.

---

## Troubleshooting

See [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) for a comprehensive runbook covering all known
failure modes, root causes, and fixes. Key issues documented:

| Symptom | Issue # |
|---|---|
| `gRPC INTERNAL (code 13)` on RE create | #001, #002 |
| `FAILED_PRECONDITION` (org policy) | #008 |
| Container startup `ValidationError` | #008, #009 |
| OTEL crash after first query | #007 |
| Model Armor 403 on all responses | #001 |

---

## How to Destroy

```bash
./destroy_all.sh
```

**What happens:**
- Force-deletes the Reasoning Engine via REST API (`?force=true`)
- Removes all dynamically created authz policies and SGP policies
- Runs `terraform destroy` with up to 15 retries (PSC eventual consistency)
- Cleans up local generated files (`.env`, `__pycache__`, test results)

---

## Important Notes
- **`agent_name` must be a Python identifier** — use underscores, not hyphens (`chat_agent` ✅, `chat-agent` ❌)
- **Never commit `terraform.tfvars`** — it contains your project ID and org ID (it is gitignored)
- **`scripts/deploy_chat_agent.sh` is generated** — it is gitignored; `terraform apply` recreates it with your project values
- **SDK version pins are mandatory** — see `KNOWN_ISSUES.md #008` before upgrading `google-adk` or `google-cloud-aiplatform`
