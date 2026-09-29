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
# Mirror teardown of deploy_all.sh — cleans up exactly what deploy_all.sh creates.
#
# Source of truth: scripts/deploy_all.sh
# This script MUST be updated whenever deploy_all.sh is updated.
#
# deploy_all.sh creates:             This script cleans:
#   store_concierge RE (orchestrator) Phase 1 — RE deletion (team=food-court)
#   pizza/burger/sushi REs (if any)   Phase 1 — same label-based sweep
#   GCS objects in gs://{proj}-staging Phase 2 — GCS cleanup
#   gateway_agent bundles in agents/  Phase 3 — local artifact cleanup
#   __pycache__ dirs                   Phase 3 — local artifact cleanup
#   agents/orchestrator/.env RE IDs   Phase 3 — local artifact cleanup
#
# NOT in deploy_all.sh scope (handled separately, outside this script):
#   SGP policies        → use create_sgp_policy.sh / manual
#   Terraform infra     → run: terraform destroy  (after this script)
#   Firestore data      → use: gcloud firestore ... / manual
#
# Usage:
#   bash destroy_all.sh           # prompts Y/N before deleting
#   bash destroy_all.sh --force   # skip confirmation (CI/CD)
#
# Prerequisites:
#   - terraform.tfvars populated (project_id, location/region, prefix)
#   - gcloud authenticated with aiplatform.reasoningEngines.delete permission
# =============================================================================

set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$DIR"

# ── Parse flags ───────────────────────────────────────────────────────────────
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=true ;;
    --help|-h)
      grep "^#" "$0" | head -35 | sed 's/^# \?//'
      exit 0 ;;
  esac
done

echo "╔══════════════════════════════════════════════════════════╗"
echo "║     Food Court — destroy_all.sh                         ║"
echo "║     Mirrors: scripts/deploy_all.sh (source of truth)    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# Pre-flight checks
# =============================================================================
echo "▶ Pre-flight Checks..."
for cmd in python3 gcloud; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ Required command '$cmd' not found in PATH."
        exit 1
    fi
done

if [[ ! -f "terraform.tfvars" ]]; then
    echo "❌ terraform.tfvars not found."
    exit 1
fi

# Read the same values that deploy_all.sh reads
PROJECT_ID=$(grep -oP '^project_id\s*=\s*"\K[^"]+' terraform.tfvars)
REGION=$(grep -oP '^location\s*=\s*"\K[^"]+' terraform.tfvars 2>/dev/null \
  || grep -oP '^region\s*=\s*"\K[^"]+' terraform.tfvars)

if [[ -z "$PROJECT_ID" || -z "$REGION" ]]; then
    echo "❌ Could not read project_id or location/region from terraform.tfvars."
    exit 1
fi

# Use the same A2A-capable venv that deploy_all.sh uses
# Priority: fiveg-ran-agent venv → workspace venv → system python3
FIVEG_VENV="$HOME/Desktop/Workspace/fiveg-ran-agent/foundation/.venv"
WORKSPACE_VENV="$HOME/Desktop/Workspace/.venv"

if [[ -x "$FIVEG_VENV/bin/python" ]]; then
    PYTHON_BIN="$FIVEG_VENV/bin/python"
elif [[ -x "$WORKSPACE_VENV/bin/python" ]]; then
    PYTHON_BIN="$WORKSPACE_VENV/bin/python"
else
    PYTHON_BIN="python3"
fi

echo "✅ Pre-flight passed."
echo "   Project : $PROJECT_ID  |  Region : $REGION"
echo "   Python  : $PYTHON_BIN"
echo ""

# =============================================================================
# Confirmation prompt (skipped with --force)
# =============================================================================
if [[ "$FORCE" == "false" ]]; then
    echo "⚠️  This will permanently delete all food-court Reasoning Engines"
    echo "   and local build artifacts for project: $PROJECT_ID"
    echo ""
    echo "   Resources that will be deleted:"
    echo "     • All REs with label team=food-court (pizza, burger, sushi, store_concierge)"
    echo "     • GCS staging objects in gs://${PROJECT_ID}-staging"
    echo "     • Local gateway_agent bundles, .env RE IDs, __pycache__"
    echo ""
    read -rp "   Type 'yes' to confirm: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

PHASE_PASS=()
PHASE_FAIL=()

# =============================================================================
# Phase 1: SGP Policy Deletion
#
# create_sgp_policy.sh is called as part of the food-court deployment workflow
# (a mandatory post-deploy step). destroy_all.sh must be its complete inverse.
# Policy name pattern (from create_sgp_policy.sh): {prefix}-{safe_agent_name}-sgp
# Sweep all food-court agent names — only fails noisily if gcloud itself errors.
# =============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Phase 1 — Delete SGP NLC Policies (post-deploy step of deploy_all.sh)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

PREFIX=$(grep -oP '^prefix\s*=\s*"\K[^"]+' terraform.tfvars 2>/dev/null || echo "")

# All food-court agent names that create_sgp_policy.sh may have been run against
FOOD_COURT_AGENT_NAMES=("store_concierge" "pizza_specialist" "burger_specialist" "sushi_specialist")

for raw_name in "${FOOD_COURT_AGENT_NAMES[@]}"; do
    # Same slug logic as create_sgp_policy.sh
    safe=$(echo "$raw_name" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr ' ' '-')
    policy_name="${PREFIX:+${PREFIX}-}${safe}-sgp"

    gcloud beta ai semantic-governance-policies delete "$policy_name" \
        --location="$REGION" \
        --project="$PROJECT_ID" \
        --quiet 2>/dev/null \
        && echo "  ✅ Deleted SGP policy: $policy_name" \
        || echo "  ℹ️  SGP policy not found (skipping): $policy_name"
done

PHASE_PASS+=("Phase 1: SGP policy deletion")
echo ""
echo "✅ Phase 1 complete."
echo ""

# =============================================================================
# Phase 2: Delete all food-court Reasoning Engines (by label team=food-court)
#
# deploy_all.sh creates:
#   - store_concierge (orchestrator): label team=food-court, role=orchestrator
#   - pizza_specialist, burger_specialist, sushi_specialist: label team=food-court
#
# Uses label-based sweep — no hardcoded RE IDs needed.
# =============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Phase 1 — Delete food-court Reasoning Engines (team=food-court)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

"$PYTHON_BIN" - <<PYEOF
import sys, time
import google.auth
import google.auth.transport.requests
import requests as http

try:
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    creds.refresh(google.auth.transport.requests.Request())
    token = creds.token
except Exception as e:
    print(f"  ❌ Auth failed: {e}")
    sys.exit(1)

project = "${PROJECT_ID}"
region  = "${REGION}"
headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
base_url = f"https://{region}-aiplatform.googleapis.com/v1beta1/projects/{project}/locations/{region}/reasoningEngines"

resp = http.get(base_url, headers=headers)
resp.raise_for_status()
engines = resp.json().get("reasoningEngines", [])

# Match by label team=food-court (the label deploy_all.sh / redeploy_orchestrator.py applies)
# Also catch display names in case labels weren't applied (partially deployed state)
FOOD_COURT_NAMES = {"pizza_specialist", "burger_specialist", "sushi_specialist", "store_concierge"}
matches = [
    e for e in engines
    if (e.get("labels", {}).get("team") == "food-court"
        or e.get("displayName", "") in FOOD_COURT_NAMES)
]

if not matches:
    print("  ℹ️  No food-court Reasoning Engines found — already clean.")
    sys.exit(0)

print(f"  Found {len(matches)} food-court RE(s) to delete:")
for engine in matches:
    resource_name = engine["name"]
    display_name  = engine.get("displayName", "?")
    created       = engine.get("createTime", "?")[:10]
    labels        = engine.get("labels", {})
    print(f"  • {display_name:<22} RE={resource_name.split('/')[-1]}  created={created}  labels={labels}")

print("")

failed = []
for engine in matches:
    resource_name = engine["name"]
    display_name  = engine.get("displayName", "?")
    print(f"  Deleting {display_name} ({resource_name.split('/')[-1]})...")

    del_resp = http.delete(
        f"https://{region}-aiplatform.googleapis.com/v1beta1/{resource_name}?force=true",
        headers=headers,
    )
    del_resp.raise_for_status()
    op = del_resp.json()

    if op.get("done"):
        print(f"  ✅ Deleted {display_name} (synchronous).")
        continue

    op_name   = op.get("name", "")
    op_url    = f"https://{region}-aiplatform.googleapis.com/v1beta1/{op_name}"
    max_polls = 30    # 30 × 10s = 5 min max
    print(f"  ⏳ LRO in progress ({op_name.split('/')[-1]})...")

    for poll_i in range(max_polls):
        time.sleep(10)
        op_resp = http.get(op_url, headers=headers)
        op_resp.raise_for_status()
        op_data = op_resp.json()
        if op_data.get("done"):
            if "error" in op_data:
                print(f"  ❌ Delete error for {display_name}: {op_data['error']}")
                failed.append(display_name)
            else:
                print(f"  ✅ Deleted {display_name}.")
            break
        if poll_i % 3 == 0:
            print(f"  ... waiting ({(poll_i+1)*10}s / {max_polls*10}s max)")
    else:
        print(f"  ⚠️  LRO for {display_name} did not complete in {max_polls*10}s.")
        print(f"      Check: gcloud ai reasoning-engines list --project={project} --region={region}")
        failed.append(display_name)

if failed:
    print(f"\n  ⚠️  {len(failed)} deletion(s) incomplete: {failed}")
    sys.exit(1)
print("\n  All food-court REs processed.")
PYEOF

if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
    PHASE_PASS+=("Phase 1: RE deletion")
else
    PHASE_FAIL+=("Phase 1: RE deletion")
fi

echo ""
echo "✅ Phase 1 complete."
echo ""

# =============================================================================
# Phase 2: GCS Staging Cleanup
#
# deploy_all.sh (via redeploy_orchestrator.py + AgentEngine.create()) writes
# agent code archives to gs://{project}-staging/ under the RE's display name.
# =============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Phase 2 — GCS Staging Cleanup (gs://${PROJECT_ID}-staging)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

GCS_BUCKET="gs://${PROJECT_ID}-staging"

# Delete food-court agent staging objects by display name prefix
for agent_prefix in "store_concierge" "pizza_specialist" "burger_specialist" "sushi_specialist"; do
    GCS_PATH="${GCS_BUCKET}/${agent_prefix}/"
    if gcloud storage ls "${GCS_PATH}" --project="${PROJECT_ID}" &>/dev/null 2>&1; then
        echo "  Removing ${GCS_PATH} ..."
        gcloud storage rm -r "${GCS_PATH}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
            && echo "  ✅ Removed ${GCS_PATH}" \
            || echo "  ⚠️  Could not remove ${GCS_PATH} (may already be gone)"
    else
        echo "  ℹ️  ${GCS_PATH} not found — skipping."
    fi
done

PHASE_PASS+=("Phase 2: GCS staging cleanup")
echo ""
echo "✅ Phase 2 complete."
echo ""

# =============================================================================
# Phase 3: Local Artifact Cleanup
#
# Removes ONLY what deploy_all.sh and its sub-scripts create locally:
#   - gateway_agent bundles copied into agents/* during deploy packaging
#   - food_court_backend.py copied into agents/* during deploy packaging
#   - stale RE IDs written into agents/orchestrator/.env
#   - __pycache__ dirs in scripts/, lib/, agents/
#   - /tmp files written by deploy tooling
# =============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Phase 3 — Local Artifact Cleanup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# gateway_agent bundles and food_court_backend.py copied into each agent dir at deploy time
for agent_dir in "$DIR/agents"/*/; do
    if [[ -d "${agent_dir}gateway_agent" ]]; then
        rm -rf "${agent_dir}gateway_agent"
        echo "  ✅ Removed leftover gateway_agent bundle: $(basename "$agent_dir")/"
    fi
    if [[ -f "${agent_dir}food_court_backend.py" ]]; then
        rm -f "${agent_dir}food_court_backend.py"
        echo "  ✅ Removed leftover food_court_backend.py: $(basename "$agent_dir")/"
    fi
done

# agents/orchestrator/.env — clear stale RE IDs (keep GCP config lines)
ORCH_ENV="$DIR/agents/orchestrator/.env"
if [[ -f "$ORCH_ENV" ]]; then
    grep -v -E '^(PIZZA|BURGER|SUSHI|ORCHESTRATOR)_(RE_ID|RE_NAME|AGENT_CARD_URL|RE_URL)=' \
        "$ORCH_ENV" > "${ORCH_ENV}.tmp" 2>/dev/null || true
    mv "${ORCH_ENV}.tmp" "$ORCH_ENV"
    echo "  ✅ Cleared stale RE IDs from agents/orchestrator/.env"
fi

# __pycache__ in deploy tooling directories
find "$DIR/scripts" "$DIR/lib" "$DIR/agents" \
    -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
echo "  ✅ Cleaned __pycache__ dirs (scripts/, lib/, agents/)"

# /tmp files written by deploy scripts
rm -f /tmp/agentregistry_list.json /tmp/adk_deploy_*.log 2>/dev/null || true
echo "  ✅ Cleaned /tmp deploy artifacts"

PHASE_PASS+=("Phase 3: Local artifact cleanup")
echo ""
echo "✅ Phase 3 complete."
echo ""

# =============================================================================
# Summary
# =============================================================================
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   destroy_all.sh — Summary                              ║"
echo "╚══════════════════════════════════════════════════════════╝"
for s in "${PHASE_PASS[@]+${PHASE_PASS[@]}}"; do
    echo "  ✅ $s"
done
for s in "${PHASE_FAIL[@]+${PHASE_FAIL[@]}}"; do
    echo "  ❌ $s"
done

echo ""
echo "  Out of scope for this script (handled separately):"
echo "  • SGP policies   → bash scripts/create_sgp_policy.sh (to recreate)"
echo "  • Terraform infra → terraform destroy  (run manually if full teardown needed)"
echo "  • Firestore data  → gcloud firestore ... (run manually if needed)"
echo ""

if [[ "${#PHASE_FAIL[@]}" -eq 0 ]]; then
    echo "  🎉 Food-court resources cleaned."
    echo ""
    echo "  To redeploy from scratch:"
    echo "    bash scripts/deploy_all.sh --fresh"
    echo ""
    exit 0
else
    echo "  ⚠️  ${#PHASE_FAIL[@]} phase(s) failed — see logs above."
    echo "     Some resources may need manual cleanup."
    echo "     gcloud ai reasoning-engines list --project=$PROJECT_ID --region=$REGION"
    exit 1
fi
