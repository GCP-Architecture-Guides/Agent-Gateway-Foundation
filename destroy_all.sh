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
# destroy_all.sh
# End-to-end teardown pipeline for Agent Gateway — mirrors deploy_all.sh in
# reverse. Cleans up everything created by deploy_all.sh.
#
# Phases (reverse of deploy):
#   1. SGP Policy Deletion
#   2. Agent (Reasoning Engine) Deletion
#   3. Local Artifact Cleanup
#   4. Infrastructure Destruction (Terraform)
#
# Usage:
#   bash destroy_all.sh
#
# Prerequisites:
#   - terraform.tfvars populated (project_id, location, prefix, agent_name)
#   - gcloud authenticated
# =============================================================================

set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$DIR"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║         Agent Gateway — End-to-End Teardown             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# Pre-flight checks
# =============================================================================
echo "▶ Pre-flight Checks..."
for cmd in terraform python3 gcloud; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ Required command '$cmd' not found in PATH."
        exit 1
    fi
done

if [[ ! -f "terraform.tfvars" ]]; then
    echo "❌ terraform.tfvars not found."
    exit 1
fi

# Read shared values from terraform.tfvars
PROJECT_ID=$(grep -oP '^project_id\s*=\s*"\K[^"]+' terraform.tfvars)
REGION=$(grep -oP '^location\s*=\s*"\K[^"]+' terraform.tfvars 2>/dev/null \
  || grep -oP '^region\s*=\s*"\K[^"]+' terraform.tfvars)
PREFIX=$(grep -oP '^prefix\s*=\s*"\K[^"]+' terraform.tfvars 2>/dev/null || echo "")
AGENT_NAME=$(grep -oP '^agent_name\s*=\s*"\K[^"]+' terraform.tfvars 2>/dev/null || echo "my-agent")

if [[ -z "$PROJECT_ID" || -z "$REGION" ]]; then
    echo "❌ Could not read PROJECT_ID or REGION from terraform.tfvars."
    exit 1
fi

# Derive the same SGP policy name used by create_sgp_policy.sh
SAFE_AGENT=$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr ' ' '-')
SGP_POLICY_NAME="${PREFIX:+${PREFIX}-}${SAFE_AGENT}-sgp"

echo "✅ Pre-flight passed."
echo "   Project : $PROJECT_ID  |  Region : $REGION  |  Agent : $AGENT_NAME"
echo "   SGP     : $SGP_POLICY_NAME"
echo ""

# Use the .venv created by deploy_chat_agent.sh if available
PYTHON_BIN="$DIR/.venv/bin/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
    PYTHON_BIN="python3"
fi

# =============================================================================
# Phase 1: SGP NLC Policy Deletion
# =============================================================================
echo "▶ [1/4] Deleting SGP NLC Policy..."
echo ""

# Delete the policy created by create_sgp_policy.sh
echo "  Deleting SGP policy: $SGP_POLICY_NAME..."
gcloud beta ai semantic-governance-policies delete "$SGP_POLICY_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --quiet 2>/dev/null \
  && echo "  ✅ Deleted: $SGP_POLICY_NAME" \
  || echo "  ⚠️  $SGP_POLICY_NAME not found (may have been manually deleted — continuing)."

# Clean up any legacy policy names from earlier sessions
for legacy_policy in "my-brand-ambassador" "${PREFIX:+${PREFIX}-}agent-sgp"; do
  gcloud beta ai semantic-governance-policies delete "$legacy_policy" \
    --location="$REGION" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null \
    && echo "  ✅ Deleted legacy policy: $legacy_policy" \
    || true  # silent no-op if not found
done

echo ""
echo "✅ Phase 1 complete — SGP policies removed."
echo ""

# =============================================================================
# Phase 2: Agent (Reasoning Engine) Deletion
# =============================================================================
echo "▶ [2/4] Deleting Reasoning Engine: $AGENT_NAME..."
echo ""

# Inline Python — finds all REs matching agent_name, deletes them, polls LRO
"$PYTHON_BIN" - <<PYEOF
import sys, time
import google.auth
import google.auth.transport.requests
import requests as http

try:
    credentials, _ = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    auth_req = google.auth.transport.requests.Request()
    credentials.refresh(auth_req)
    token = credentials.token
except Exception as e:
    print(f"  ❌ Auth failed: {e}")
    sys.exit(1)

project  = "${PROJECT_ID}"
region   = "${REGION}"
name     = "${AGENT_NAME}"
headers  = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
base_url = f"https://{region}-aiplatform.googleapis.com/v1beta1/projects/{project}/locations/{region}/reasoningEngines"

resp = http.get(base_url, headers=headers)
resp.raise_for_status()
engines = resp.json().get("reasoningEngines", [])
matches = [e for e in engines if e.get("displayName") == name]

if not matches:
    print(f"  ℹ️  No Reasoning Engines found with displayName='{name}' — already clean.")
    sys.exit(0)

for engine in matches:
    resource_name = engine["name"]
    created       = engine.get("createTime", "unknown")
    print(f"  Deleting: {resource_name}  (created: {created})")

    del_resp = http.delete(
        f"https://{region}-aiplatform.googleapis.com/v1beta1/{resource_name}?force=true",
        headers=headers,
    )
    del_resp.raise_for_status()
    op = del_resp.json()

    if op.get("done"):
        print("  ✅ Deleted synchronously.")
        continue

    op_name   = op.get("name", "")
    op_url    = f"https://{region}-aiplatform.googleapis.com/v1beta1/{op_name}"
    max_polls = 30   # 30 × 10s = 5 minutes max
    print(f"  ⏳ Delete LRO in progress: {op_name}")

    for poll_i in range(max_polls):
        time.sleep(10)
        op_resp = http.get(op_url, headers=headers)
        op_resp.raise_for_status()
        op_data = op_resp.json()
        if op_data.get("done"):
            if "error" in op_data:
                print(f"  ❌ Deletion error: {op_data['error']}")
                sys.exit(1)
            print("  ✅ Deleted.")
            break
        print(f"  Waiting ({poll_i+1}/{max_polls})...")
    else:
        print(f"  ⚠️  LRO did not complete within {max_polls * 10}s — check GCP console.")

print("  All engines processed.")
PYEOF

echo ""
echo "✅ Phase 2 complete — Reasoning Engine removed."
echo ""

# =============================================================================
# Phase 3: Local Artifact Cleanup
# =============================================================================
echo "▶ [3/4] Cleaning Up Local Artifacts..."
echo ""

# Guardrail test results
TEST_RESULTS_DIR="$DIR/test-agent/results"
if [[ -d "$TEST_RESULTS_DIR" ]]; then
    rm -rf "$TEST_RESULTS_DIR"
    echo "  ✅ Removed: test-agent/results/"
fi

# .env file written by deploy_chat_agent.sh (contains project credentials)
AGENT_ENV="$DIR/agents/chat-agent/.env"
if [[ -f "$AGENT_ENV" ]]; then
    rm -f "$AGENT_ENV"
    echo "  ✅ Removed: agents/chat-agent/.env"
fi

# Leftover SDK bundle if deploy was interrupted
SDK_BUNDLE="$DIR/agents/chat-agent/gateway_agent"
if [[ -d "$SDK_BUNDLE" ]]; then
    rm -rf "$SDK_BUNDLE"
    echo "  ✅ Removed: agents/chat-agent/gateway_agent (leftover bundle)"
fi

# Python bytecode caches
find "$DIR/test-agent" "$DIR/lib" "$DIR/scripts" \
  -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
echo "  ✅ Cleaned __pycache__ directories"

# Generated SGP policy helper temp files
rm -f /tmp/agentregistry_list.json /tmp/adk_deploy_*.log 2>/dev/null || true

echo ""
echo "✅ Phase 3 complete — local artifacts cleaned."
echo ""

# =============================================================================
# Phase 4: Infrastructure Destruction (Terraform)
# =============================================================================
echo "▶ [4/4] Destroying Infrastructure (Terraform)..."
echo "  Note: PSC endpoint cleanup can take 60-90s — Terraform retries up to 15×."
echo ""

MAX_RETRIES=15
RETRY_COUNT=0
TF_SUCCESS=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  echo "  terraform destroy (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)..."
  if terraform destroy -auto-approve -input=false; then
    TF_SUCCESS=true
    break
  fi
  echo "  ⚠️  Destroy failed — often PSC endpoints cleaning up. Retrying in 60s..."
  sleep 60
  RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ "$TF_SUCCESS" = false ]; then
  echo "❌ Terraform destroy failed after $MAX_RETRIES attempts."
  echo "   Some resources may need manual cleanup. Check:"
  echo "   gcloud compute network-attachments list --region=$REGION --project=$PROJECT_ID"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              ✅  Teardown Complete                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Project : $PROJECT_ID"
echo "  Agent   : $AGENT_NAME  (deleted)"
echo "  SGP     : $SGP_POLICY_NAME  (deleted)"
echo "  Infra   : destroyed via Terraform"
echo ""
echo "  Clean slate achieved. To redeploy: bash deploy_all.sh"
echo ""
