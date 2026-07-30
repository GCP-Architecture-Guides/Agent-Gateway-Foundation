<!-- Copyright 2025 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

This code is for PoC environment only.
This demo code is not built for production workload. -->

# VPC Service Controls — Agent Gateway Setup Guide

> ⚠️ **Disclaimer:** This code is for PoC environment only.
> This demo code is not built for production workload.

This guide covers deploying the Agent Gateway Foundation inside a VPC Service
Controls (VPC-SC) perimeter. The perimeter setup is **manual and optional** —
the core `deploy_all.sh` is unchanged.

---

## Overview

When your GCP project is inside a VPC-SC perimeter, Agent Gateway
provisioning **fails by default** because its control-plane service agents
run in Google-managed infrastructure outside your perimeter. You must add
ingress rules to allow these service agents through before deploying.

```
┌────────────────────────────────────────────────────────────┐
│  Your VPC-SC Perimeter                                     │
│                                                            │
│   ┌──────────────────────────────────────────────────┐    │
│   │  Your GCP Project                                │    │
│   │                                                  │    │
│   │  PSC endpoints, Model Armor, Agent Gateway       │    │
│   │  Reasoning Engines, gateways                     │    │
│   └──────────────────────────────────────────────────┘    │
│                                                            │
│  ← Ingress rules allow →  Google-managed control planes   │
│    (actuation-a, pipeline-robot, cluster-manager, etc.)   │
└────────────────────────────────────────────────────────────┘
```

---

## Root Cause

Agent Gateway provisioning delegates to **Infrastructure Manager**, which
runs Terraform in Google Cloud Build workers inside a Google-managed project.
These workers set `X-Goog-User-Project` to the tenant project number (treated
as inside your perimeter), but the API calls originate from outside it.

VPC-SC blocks these with: `NETWORK_NOT_IN_SAME_SERVICE_PERIMETER`

The long-term fix requires changes to the VPC-SC policy engine (tracked
internally as b/512913707). Until then, the ingress rules below are required.

---

## Deployment Sequence

```
Step 1  — You create a VPC-SC perimeter (manually in GCP Console or gcloud)
Step 2  — Add your project to the perimeter (manually)
Step 3  — Run setup_vpc_sc_ingress.sh  ← adds the 8 ingress rules
Step 4  — Wait 5–15 minutes for VPC-SC propagation
Step 5  — Run deploy_all.sh  ← unchanged, works as normal
```

---

## Step 1 — Create a VPC-SC Perimeter

```bash
# Get your Access Context Manager policy ID
gcloud access-context-manager policies list \
  --organization=YOUR_ORG_ID

# Create a new perimeter (enforced mode)
gcloud access-context-manager perimeters create agw-perimeter \
  --policy=YOUR_POLICY_ID \
  --title="Agent Gateway Perimeter" \
  --resources=projects/YOUR_PROJECT_NUMBER \
  --restricted-services=aiplatform.googleapis.com,networkservices.googleapis.com \
  --type=REGULAR
```

> **Dry-run mode first (recommended):** Add `--type=REGULAR` and initially
> set the perimeter to dry-run mode (`gcloud access-context-manager perimeters
> dry-run create ...`) so you can observe violations before enforcing.

---

## Step 2 — Add Your Project to the Perimeter

If you created the perimeter without adding the project in Step 1:

```bash
gcloud access-context-manager perimeters update agw-perimeter \
  --policy=YOUR_POLICY_ID \
  --add-resources=projects/YOUR_PROJECT_NUMBER
```

---

## Step 3 — Add Agent Gateway Ingress Rules

This is what `scripts/setup_vpc_sc_ingress.sh` automates. It:

1. Reads `project_id` and `organization_id` from `terraform.tfvars`
2. Looks up the numeric project number automatically
3. Generates a YAML file with all 8 required ingress rules
4. Applies it to your perimeter using `--set-ingress-policies`

```bash
# Find your ACM policy ID
gcloud access-context-manager policies list \
  --organization=$(grep -oP 'organization_id.*"\K[^"]+' terraform.tfvars)

# Run the script
bash scripts/setup_vpc_sc_ingress.sh \
  --policy-id  YOUR_POLICY_ID \
  --perimeter  agw-perimeter

# With Shared VPC (only needed if using Shared VPC):
bash scripts/setup_vpc_sc_ingress.sh \
  --policy-id  YOUR_POLICY_ID \
  --perimeter  agw-perimeter \
  --shared-vpc-host-project-number YOUR_HOST_PROJECT_NUMBER

# Preview without applying (generates YAML only):
bash scripts/setup_vpc_sc_ingress.sh \
  --policy-id  YOUR_POLICY_ID \
  --perimeter  agw-perimeter \
  --dry-run
```

> **IAM requirement:** The caller needs
> `roles/accesscontextmanager.policyEditor` at the **organization level**.

---

## Step 4 — Wait for Propagation

VPC-SC policy changes propagate globally over 5–15 minutes. Do **not**
run `deploy_all.sh` until propagation is complete.

Verify the rules are applied:
```bash
gcloud access-context-manager perimeters describe agw-perimeter \
  --policy=YOUR_POLICY_ID \
  --format='yaml(spec.ingressPolicies)'
```

You should see all 8 ingress rules listed.

---

## Step 5 — Deploy Normally

```bash
bash deploy_all.sh
```

No changes to `deploy_all.sh` are needed. The VPC-SC ingress rules allow
the Agent Gateway control plane through the perimeter transparently.

---

## The 8 Ingress Rules — What Each Does

| # | Identity | Services Allowed | Purpose |
|---|---|---|---|
| 1 | `cloud-aiplatform-pipeline-robot-prod@system` | DNS, monitoring, networksecurity, networkservices, servicedirectory | Agent Runtime control plane: mTLS, TCP routes, DNS peering, metrics |
| 2 | `actuation-a@networkservices-prod` | compute (method-scoped), certificatemanager, networksecurity, networkservices, privateca, serviceusage, cloudresourcemanager | Agent Gateway lifecycle: provision, update, teardown gateway resources |
| 3 | `cloud-gatekeeper-*@system` | agentregistry, run | IAP/IAM evaluation for agent identity enforcement |
| 4 | `cloud-cluster-manager@system` | networkservices | Agent Gateway service bindings (traffic routing stitch) |
| 5 | `service-PROJECT_NUMBER@gcp-sa-aiplatform` | networkservices, storage | Agent Platform platform operations and staging GCS |
| 6 | `service-PROJECT_NUMBER@gcp-sa-aiplatform-re` | artifactregistry, logging, storage | Agent Runtime: pull images, write logs, read/write state |
| 7 | `principalSet://agents.global.org-ORG_ID` | trafficdirector | Agent workloads receive xDS routing from Traffic Director |
| 8 | `principalSet://agents.global.org-ORG_ID` | containerthreatdetection | Agent workloads stream security telemetry |

---

## Teardown — VPC-SC Cleanup

When you run `destroy_all.sh`, the VPC-SC perimeter and ingress rules are
**not touched** — they were created manually and must be removed manually.

After `destroy_all.sh` completes:

```bash
# Remove ingress rules (set to empty)
gcloud access-context-manager perimeters update agw-perimeter \
  --policy=YOUR_POLICY_ID \
  --clear-ingress-policies

# Remove project from perimeter
gcloud access-context-manager perimeters update agw-perimeter \
  --policy=YOUR_POLICY_ID \
  --remove-resources=projects/YOUR_PROJECT_NUMBER

# (Optional) Delete the perimeter entirely
gcloud access-context-manager perimeters delete agw-perimeter \
  --policy=YOUR_POLICY_ID
```

---

## Troubleshooting

### Agent Gateway provisioning still fails after ingress rules

1. **Check propagation**: Rules take 5–15 min. Verify with `describe` command above.
2. **Check audit logs**: In Cloud Logging, filter for `protoPayload.metadata.violationReason="NETWORK_NOT_IN_SAME_SERVICE_PERIMETER"` to identify which service agent is still blocked.
3. **Check the perimeter type**: If using `spec` (dry-run) mode, switch to enforced mode or test accordingly.
4. **Project number mismatch**: Ensure the project number in the ingress rules matches your actual project: `gcloud projects describe YOUR_PROJECT_ID --format='value(projectNumber)'`

### `PERMISSION_DENIED` running setup_vpc_sc_ingress.sh

The caller needs `roles/accesscontextmanager.policyEditor` at the **organization level** — not the project level. Contact your GCP org admin.

### `--set-ingress-policies` removed existing rules I needed

The script warns you and asks for confirmation before applying. If you accidentally overwrote rules, use Cloud Audit Logs → `SetServicePerimeter` events to see the previous configuration.
