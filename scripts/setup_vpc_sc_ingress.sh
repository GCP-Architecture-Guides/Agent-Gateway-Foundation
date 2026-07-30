#!/usr/bin/env bash

# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This code is for PoC environment only.
# This demo code is not built for production workload.

# =============================================================================
# setup_vpc_sc_ingress.sh
#
# Adds the 8 required Agent Gateway + Agent Runtime ingress rules to an
# existing VPC Service Controls perimeter. Run this ONCE after creating your
# VPC-SC perimeter manually and BEFORE running deploy_all.sh.
#
# Why these rules are needed:
#   Agent Gateway provisioning uses Google-managed service agents that run
#   outside your project's VPC-SC perimeter. Without these ingress rules,
#   VPC-SC blocks them with NETWORK_NOT_IN_SAME_SERVICE_PERIMETER and
#   provisioning fails silently or with cryptic errors.
#   See: docs/VPC_SC.md for full root cause explanation.
#
# Usage:
#   bash scripts/setup_vpc_sc_ingress.sh \
#     --policy-id  1234567890 \
#     --perimeter  my-perimeter-name
#
#   # With Shared VPC:
#   bash scripts/setup_vpc_sc_ingress.sh \
#     --policy-id  1234567890 \
#     --perimeter  my-perimeter-name \
#     --shared-vpc-host-project-number 987654321098
#
#   # Preview only (no changes):
#   bash scripts/setup_vpc_sc_ingress.sh \
#     --policy-id 1234567890 --perimeter my-perimeter --dry-run
#
# Prerequisites:
#   - terraform.tfvars populated (project_id, organization_id)
#   - gcloud authenticated with access to the VPC-SC perimeter
#   - Caller needs: roles/accesscontextmanager.policyEditor (org level)
#
# IMPORTANT: --set-ingress-policies REPLACES all existing ingress rules.
#            If you have other ingress rules in this perimeter, the script
#            will show them and ask for confirmation before proceeding.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
FOUNDATION_ROOT="$( dirname "$SCRIPT_DIR" )"
cd "$FOUNDATION_ROOT"

# =============================================================================
# Argument parsing
# =============================================================================
POLICY_ID=""
PERIMETER_NAME=""
SHARED_VPC_HOST_PROJECT_NUMBER=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy-id)
      POLICY_ID="$2"; shift 2 ;;
    --perimeter)
      PERIMETER_NAME="$2"; shift 2 ;;
    --shared-vpc-host-project-number)
      SHARED_VPC_HOST_PROJECT_NUMBER="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    --help|-h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
      exit 0 ;;
    *)
      echo "❌ Unknown argument: $1  (use --help for usage)"
      exit 1 ;;
  esac
done

# =============================================================================
# Validation
# =============================================================================
if [[ -z "$POLICY_ID" || -z "$PERIMETER_NAME" ]]; then
  echo "❌ --policy-id and --perimeter are required."
  echo ""
  echo "   Find your Access Context Manager policy ID:"
  echo "   gcloud access-context-manager policies list \\"
  echo "     --organization=\$(grep -oP 'organization_id.*\"\\K[^\"]+' terraform.tfvars)"
  echo ""
  echo "   Usage: bash scripts/setup_vpc_sc_ingress.sh --policy-id ID --perimeter NAME"
  exit 1
fi

if [[ ! -f "terraform.tfvars" ]]; then
  echo "❌ terraform.tfvars not found. Run from the foundation root directory."
  exit 1
fi

# =============================================================================
# Read values from terraform.tfvars
# =============================================================================
PROJECT_ID=$(grep -oP '^project_id\s*=\s*"\K[^"]+' terraform.tfvars)
ORG_ID=$(grep -oP '^organization_id\s*=\s*"\K[^"]+' terraform.tfvars)

if [[ -z "$PROJECT_ID" || -z "$ORG_ID" ]]; then
  echo "❌ Could not read project_id or organization_id from terraform.tfvars."
  exit 1
fi

echo "╔══════════════════════════════════════════════════════════╗"
echo "║     Agent Gateway — VPC-SC Ingress Rule Setup           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "▶ Looking up project number for: $PROJECT_ID"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" \
  --format='value(projectNumber)' 2>/dev/null)

if [[ -z "$PROJECT_NUMBER" ]]; then
  echo "❌ Could not get project number for '$PROJECT_ID'."
  echo "   Ensure you are authenticated: gcloud auth application-default login"
  exit 1
fi

echo ""
echo "  Project ID             : $PROJECT_ID"
echo "  Project Number         : $PROJECT_NUMBER"
echo "  Organization ID        : $ORG_ID"
echo "  ACM Policy ID          : $POLICY_ID"
echo "  Perimeter              : $PERIMETER_NAME"
if [[ -n "$SHARED_VPC_HOST_PROJECT_NUMBER" ]]; then
  echo "  Shared VPC Host Proj # : $SHARED_VPC_HOST_PROJECT_NUMBER"
fi
[[ "$DRY_RUN" == "true" ]] && echo "  Mode                   : DRY RUN (no changes will be made)"
echo ""

# =============================================================================
# Check for existing ingress rules — warn before overwriting
# =============================================================================
echo "▶ Checking existing ingress rules on perimeter '$PERIMETER_NAME'..."

EXISTING_RULES=$(gcloud access-context-manager perimeters describe \
  "$PERIMETER_NAME" \
  --policy="$POLICY_ID" \
  --format='value(spec.ingressPolicies)' 2>/dev/null || echo "")

if [[ -n "$EXISTING_RULES" && "$EXISTING_RULES" != "None" && "$EXISTING_RULES" != "[]" ]]; then
  echo ""
  echo "  ⚠️  WARNING: This perimeter already has ingress rules:"
  echo ""
  gcloud access-context-manager perimeters describe \
    "$PERIMETER_NAME" \
    --policy="$POLICY_ID" \
    --format='yaml(spec.ingressPolicies)' 2>/dev/null || true
  echo ""
  echo "  ─────────────────────────────────────────────────────────"
  echo "  --set-ingress-policies will REPLACE all existing rules."
  echo "  The Agent Gateway rules will be the ONLY rules after this."
  echo "  ─────────────────────────────────────────────────────────"
  echo ""
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] Would prompt for confirmation here."
  else
    read -r -p "  Continue and replace existing rules? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "  Aborted. No changes made."
      exit 0
    fi
  fi
else
  echo "  ✅ No existing ingress rules — safe to apply."
fi
echo ""

# =============================================================================
# Generate ingress rules YAML
# =============================================================================
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

INGRESS_YAML="$TMPDIR_WORK/agw_ingress_rules.yaml"

# Build actuation-a resource list (include shared VPC host if provided)
ACTUATION_RESOURCES="    - projects/${PROJECT_NUMBER}"
if [[ -n "$SHARED_VPC_HOST_PROJECT_NUMBER" ]]; then
  ACTUATION_RESOURCES="${ACTUATION_RESOURCES}
    - projects/${SHARED_VPC_HOST_PROJECT_NUMBER}"
fi

cat > "$INGRESS_YAML" << YAML
# Agent Gateway + Agent Runtime VPC-SC Ingress Rules
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Project:   ${PROJECT_ID} (${PROJECT_NUMBER})
# Org:       ${ORG_ID}
# Perimeter: ${PERIMETER_NAME}
# Source:    scripts/setup_vpc_sc_ingress.sh

# ─────────────────────────────────────────────────────────────────────────────
# Rule 1: Agent Runtime Control Plane
# Allows cloud-aiplatform-pipeline-robot-prod to configure mTLS, TCP routes,
# DNS peering, monitoring metrics, and Service Directory entries.
# ─────────────────────────────────────────────────────────────────────────────
- ingressFrom:
    identities:
    - serviceAccount:cloud-aiplatform-pipeline-robot-prod@system.gserviceaccount.com
    sources:
    - accessLevel: '*'
  ingressTo:
    operations:
    - serviceName: dns.googleapis.com
      methodSelectors:
      - method: '*'
    - serviceName: monitoring.googleapis.com
      methodSelectors:
      - method: '*'
    - serviceName: networksecurity.googleapis.com
      methodSelectors:
      - method: '*'
    - serviceName: networkservices.googleapis.com
      methodSelectors:
      - method: '*'
    - serviceName: servicedirectory.googleapis.com
      methodSelectors:
      - method: '*'
    resources:
    - projects/${PROJECT_NUMBER}

# ─────────────────────────────────────────────────────────────────────────────
# Rule 2: Agent Gateway Infrastructure Lifecycle Management
# Allows actuation-a@networkservices-prod to provision, update, and remove
# compute/network/cert resources for the Agent Gateway. Scope is deliberately
# limited to GET and DELETE operations on gateway-managed resources only.
# ─────────────────────────────────────────────────────────────────────────────
- ingressFrom:
    identities:
    - serviceAccount:actuation-a@networkservices-prod.iam.gserviceaccount.com
    sources:
    - accessLevel: '*'
  ingressTo:
    operations:
    - serviceName: certificatemanager.googleapis.com
      methodSelectors:
      - method: '*'
    - serviceName: networksecurity.googleapis.com
      methodSelectors:
      - method: '*'
    - serviceName: networkservices.googleapis.com
      methodSelectors:
      - method: '*'
    - serviceName: privateca.googleapis.com
      methodSelectors:
      - method: '*'
    - serviceName: serviceusage.googleapis.com
      methodSelectors:
      - method: '*'
    - serviceName: compute.googleapis.com
      methodSelectors:
      - method: FirewallsService.Delete
      - method: FirewallsService.Get
      - method: GlobalOperationsService.Get
      - method: HealthChecksService.Delete
      - method: HealthChecksService.Get
      - method: InstanceTemplatesService.Delete
      - method: InstanceTemplatesService.Get
      - method: InstanceTemplatesService.Insert
      - method: NetworksService.Delete
      - method: NetworksService.Get
      - method: RegionAddressesService.Delete
      - method: RegionBackendServicesService.Delete
      - method: RegionBackendServicesService.Get
      - method: RegionForwardingRulesService.Delete
      - method: RegionForwardingRulesService.Get
      - method: RegionInstanceGroupManagersService.Delete
      - method: RegionInstanceGroupManagersService.Get
      - method: RegionInstanceGroupManagersService.Patch
      - method: RegionOperationsService.Get
      - method: RegionRoutersService.Delete
      - method: RegionRoutersService.Get
      - method: RoutesService.Delete
      - method: RoutesService.Get
      - method: ServiceAttachmentsService.Delete
      - method: ServiceAttachmentsService.Get
      - method: ServiceAttachmentsService.Patch
      - method: SubnetworksService.Delete
      - method: SubnetworksService.Get
      - method: SubnetworksService.List
      - method: ZonesService.List
    - serviceName: cloudresourcemanager.googleapis.com
      methodSelectors:
      - method: Projects.SetIamPolicy
    resources:
${ACTUATION_RESOURCES}

# ─────────────────────────────────────────────────────────────────────────────
# Rule 3: IAP and IAM Policy Evaluation
# Allows Cloud Gatekeeper (IAP backend) to evaluate permissions for Agent
# Registry and Cloud Run, and perform wipeout/compliance operations.
# ─────────────────────────────────────────────────────────────────────────────
- ingressFrom:
    identities:
    - serviceAccount:cloud-gatekeeper-wipeout-batch@system.gserviceaccount.com
    - serviceAccount:cloud-gatekeeper-iam-admin-api@system.gserviceaccount.com
    sources:
    - accessLevel: '*'
  ingressTo:
    operations:
    - serviceName: agentregistry.googleapis.com
      methodSelectors:
      - method: '*'
    - serviceName: run.googleapis.com
      methodSelectors:
      - method: '*'
    resources:
    - projects/${PROJECT_NUMBER}

# ─────────────────────────────────────────────────────────────────────────────
# Rule 4: Agent Gateway Service Bindings
# Allows cloud-cluster-manager to configure Network Services bindings that
# stitch agent compute infrastructure to gateway routing.
# ─────────────────────────────────────────────────────────────────────────────
- ingressFrom:
    identities:
    - serviceAccount:cloud-cluster-manager@system.gserviceaccount.com
    sources:
    - accessLevel: '*'
  ingressTo:
    operations:
    - serviceName: networkservices.googleapis.com
      methodSelectors:
      - method: '*'
    resources:
    - projects/${PROJECT_NUMBER}

# ─────────────────────────────────────────────────────────────────────────────
# Rule 5: Agent Platform Service Agent
# Allows the project's Agent Platform service agent to manage network services
# and access Cloud Storage for staging and model artifact retrieval.
# ─────────────────────────────────────────────────────────────────────────────
- ingressFrom:
    identities:
    - serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com
    sources:
    - accessLevel: '*'
  ingressTo:
    operations:
    - serviceName: networkservices.googleapis.com
      methodSelectors:
      - method: '*'
    - serviceName: storage.googleapis.com
      methodSelectors:
      - method: '*'
    resources:
    - projects/${PROJECT_NUMBER}

# ─────────────────────────────────────────────────────────────────────────────
# Rule 6: Agent Runtime Service Agent
# Allows the project's Agent Runtime service agent to pull container images
# from Artifact Registry, write logs, and access Cloud Storage for agent state.
# ─────────────────────────────────────────────────────────────────────────────
- ingressFrom:
    identities:
    - serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com
    sources:
    - accessLevel: '*'
  ingressTo:
    operations:
    - serviceName: artifactregistry.googleapis.com
      methodSelectors:
      - method: '*'
    - serviceName: logging.googleapis.com
      methodSelectors:
      - method: '*'
    - serviceName: storage.googleapis.com
      methodSelectors:
      - method: '*'
    resources:
    - projects/${PROJECT_NUMBER}

# ─────────────────────────────────────────────────────────────────────────────
# Rule 7: Agent Identities — Traffic Director
# Allows deployed agent workloads (via AgentIdentity) to receive xDS routing
# configs from Traffic Director for service mesh and load balancing.
# ─────────────────────────────────────────────────────────────────────────────
- ingressFrom:
    identities:
    - principalSet://agents.global.org-${ORG_ID}.system.id.goog/*
    sources:
    - accessLevel: '*'
  ingressTo:
    operations:
    - serviceName: trafficdirector.googleapis.com
      methodSelectors:
      - method: '*'
    resources:
    - projects/${PROJECT_NUMBER}

# ─────────────────────────────────────────────────────────────────────────────
# Rule 8: Agent Identities — Container Threat Detection
# Allows deployed agent workloads to stream security telemetry to Container
# Threat Detection for runtime security monitoring.
# ─────────────────────────────────────────────────────────────────────────────
- ingressFrom:
    identities:
    - principalSet://agents.global.org-${ORG_ID}.system.id.goog/*
    sources:
    - accessLevel: '*'
  ingressTo:
    operations:
    - serviceName: containerthreatdetection.googleapis.com
      methodSelectors:
      - method: '*'
    resources:
    - projects/${PROJECT_NUMBER}
YAML

# =============================================================================
# Preview the rules
# =============================================================================
echo "▶ Ingress rules to be applied (8 rules):"
echo ""
cat "$INGRESS_YAML"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "ℹ️  DRY RUN — no changes made."
  echo "   Generated YAML saved to: $INGRESS_YAML"
  cp "$INGRESS_YAML" "${FOUNDATION_ROOT}/agw_ingress_rules_preview.yaml"
  echo "   Copy saved to: agw_ingress_rules_preview.yaml"
  exit 0
fi

# =============================================================================
# Apply the ingress rules
# =============================================================================
echo "▶ Applying ingress rules to perimeter '$PERIMETER_NAME'..."
echo "   Policy: $POLICY_ID"
echo ""

gcloud access-context-manager perimeters update "$PERIMETER_NAME" \
  --policy="$POLICY_ID" \
  --set-ingress-policies="$INGRESS_YAML" \
  --quiet

echo ""
echo "✅ Ingress rules applied successfully."
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                  ⏳  IMPORTANT: Wait                    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  VPC-SC policy changes take 5–15 minutes to propagate."
echo "  Do NOT run deploy_all.sh yet."
echo ""
echo "  You can verify propagation by checking:"
echo "  gcloud access-context-manager perimeters describe '$PERIMETER_NAME' \\"
echo "    --policy='$POLICY_ID' \\"
echo "    --format='yaml(spec.ingressPolicies)'"
echo ""
echo "  Once propagated, run:"
echo "    bash deploy_all.sh"
echo ""
echo "  Ingress rules summary:"
echo "    Rule 1 — Agent Runtime control plane (mTLS, DNS, monitoring)"
echo "    Rule 2 — Agent Gateway lifecycle (compute, network, certs)"
echo "    Rule 3 — IAP / IAM policy evaluation"
echo "    Rule 4 — Agent Gateway service bindings"
echo "    Rule 5 — Agent Platform service agent (networkservices, GCS)"
echo "    Rule 6 — Agent Runtime service agent (AR, logging, GCS)"
echo "    Rule 7 — Agent identities → Traffic Director"
echo "    Rule 8 — Agent identities → Container Threat Detection"
echo ""
