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
# bootstrap_project.sh
# One-time project bootstrap — requires elevated IAM permissions that the
# Cloud Build SA does NOT have. Run this ONCE per environment with your
# own ADC (gcloud auth application-default login) before triggering a build.
#
# Usage:
#   bash scripts/bootstrap_project.sh <project-id> <region>
#
# Examples:
#   bash scripts/bootstrap_project.sh YOUR_PROJECT_ID     us-central1
#   bash scripts/bootstrap_project.sh agentic-security-qa  us-central1
#   bash scripts/bootstrap_project.sh YOUR_PROJECT_ID us-central1
#
# Required caller role:
#   roles/orgpolicy.policyAdmin   (to set custom org policy enforcement)
#
# What this does (idempotent — safe to re-run):
#   1. Enables custom org policies required for Vertex AI Reasoning Engines
#      with AGENT_IDENTITY type and agent_gateway_config.
#      Constraints are defined at org level; this enforces them per-project.
#
# Why not in Terraform?
#   Cloud Build SA (PROJECT_NUMBER@cloudbuild.gserviceaccount.com) lacks
#   orgpolicy.policies.create permission. These are applied here with
#   elevated ADC and maintained as code in this script.
# =============================================================================

set -euo pipefail

PROJECT="${1:?Usage: $0 <project-id> <region>}"
REGION="${2:?Usage: $0 <project-id> <region>}"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         Bootstrap: $PROJECT"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Verify caller has necessary permissions
echo "▶ Verifying active account..."
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
echo "  Active account: ${ACTIVE_ACCOUNT}"
echo ""

# =============================================================================
# 1. Custom Org Policies
#    Required for Reasoning Engine AGENT_IDENTITY type + agent_gateway_config.
#    Without these, deploy-agents fails with code 3 (INVALID_ARGUMENT).
#    Custom constraints must already exist at org level (created once by org admin).
# =============================================================================
echo "▶ [1/1] Applying custom org policies (enforce: true at project level)..."
echo ""

echo "▶ Custom Org Policies are now natively managed and enforced via Terraform"
echo "  (see mod-agw-foundation/org_policies.tf)"
echo ""

echo "✅  Bootstrap complete for $PROJECT — ready to run Cloud Build."
echo ""
