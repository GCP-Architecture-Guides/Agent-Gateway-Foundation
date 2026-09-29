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

# ===========================================================================
# run_e2e.sh  —  Full E2E deploy + classify + test pipeline
#
# What this runs:
#
#   PHASE 1 — Deploy agents (~20-30 min)
#             bash scripts/deploy_a2a_agents.sh
#             Deploys pizza_specialist, burger_specialist, sushi_specialist,
#             and store_concierge (orchestrator) as Vertex AI Reasoning Engines.
#             Applies capability labels for AgentRegistry discovery.
#             Grants IAM roles to each Agent Identity SA.
#
#   PHASE 2 — google-adk(a2a) classification (~1 min)
#             python scripts/patch_a2a_classification.py --team food-court
#             Applies 3 metadata PATCHes to all food-court REs:
#               PATCH 1: agentFramework=google-adk + classMethods (24 total)
#               PATCH 2: Strip contextSpec
#               PATCH 3: agentCard (required for console classification label)
#
#   PHASE 3 — E2E tests (~5-10 min)
#             python scripts/e2e_test.py
#             17 queries across 4 agents. REs are auto-discovered by displayName
#             — no hardcoded RE IDs.
#
# Usage:
#   bash run_e2e.sh                    # full pipeline (deploy + classify + test)
#   bash run_e2e.sh --skip-deploy      # skip deploy, classify + test only
#   bash run_e2e.sh --skip-classify    # skip classification patch
#   bash run_e2e.sh --test-only        # just run E2E tests (agents must be up)
#   bash run_e2e.sh --help
#
# Requirements:
#   - gcloud auth active (gcloud auth print-access-token works)
#   - terraform.tfvars populated with project_id, location, prefix
#   - fiveg-ran-agent venv present (aiplatform==1.162.0, adk==2.5.0)
#     OR local .venv (will be created by deploy_a2a_agents.sh)
# ===========================================================================

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
cd "$SCRIPT_DIR"

# ── Parse flags ───────────────────────────────────────────────────────────────
SKIP_DEPLOY=false
SKIP_CLASSIFY=false
TEST_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --skip-deploy)   SKIP_DEPLOY=true ;;
    --skip-classify) SKIP_CLASSIFY=true ;;
    --test-only)     SKIP_DEPLOY=true; SKIP_CLASSIFY=true; TEST_ONLY=true ;;
    --help|-h)
      grep "^#" "$0" | head -50 | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown flag: $arg (use --help)"; exit 1 ;;
  esac
done

# ── Read config from terraform.tfvars ─────────────────────────────────────────
TFVARS="$SCRIPT_DIR/terraform.tfvars"
if [[ ! -f "$TFVARS" ]]; then
  echo "❌ terraform.tfvars not found at $TFVARS"
  exit 1
fi
PROJECT=$(grep -oP '^project_id\s*=\s*"\K[^"]+' "$TFVARS")
REGION=$(grep -oP '^location\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null \
         || grep -oP '^region\s*=\s*"\K[^"]+' "$TFVARS")

# ── Resolve Python (fiveg venv preferred, local .venv fallback) ───────────────
FIVEG_VENV="$HOME/Desktop/Workspace/fiveg-ran-agent/foundation/.venv"
LOCAL_VENV="$SCRIPT_DIR/.venv"

if [[ -x "$FIVEG_VENV/bin/python" ]]; then
  PYTHON="$FIVEG_VENV/bin/python"
  VENV_LABEL="fiveg venv (aiplatform==1.162.0, adk==2.5.0)"
elif [[ -x "$LOCAL_VENV/bin/python" ]]; then
  PYTHON="$LOCAL_VENV/bin/python"
  VENV_LABEL="local .venv"
else
  # Will be created by deploy_a2a_agents.sh — bootstrap for test-only mode
  PYTHON=""
  VENV_LABEL="(not found — will be created on deploy)"
fi

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║          Food Court — Full E2E Pipeline (run_e2e.sh)            ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo "  Project  : $PROJECT"
echo "  Region   : $REGION"
echo "  Python   : ${PYTHON:-TBD} ($VENV_LABEL)"
echo "  Flags    : skip-deploy=$SKIP_DEPLOY  skip-classify=$SKIP_CLASSIFY"
echo ""

PASS=()
FAIL=()
SKIP=()

# ── PHASE 1: Deploy ───────────────────────────────────────────────────────────
if [[ "$SKIP_DEPLOY" == "false" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PHASE 1 — Deploy all food-court agents"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Script : scripts/deploy_a2a_agents.sh"
  echo "  Agents : pizza_specialist · burger_specialist · sushi_specialist · store_concierge"
  echo "  ETA    : ~20–30 minutes"
  echo ""

  if bash scripts/deploy_a2a_agents.sh; then
    echo "  ✅ Phase 1 complete — all agents deployed"
    PASS+=("Phase 1: Deploy")
    # Refresh PYTHON after deploy_a2a_agents.sh may have created .venv
    [[ -z "$PYTHON" && -x "$LOCAL_VENV/bin/python" ]] && PYTHON="$LOCAL_VENV/bin/python"
  else
    echo "  ❌ Phase 1 FAILED — see logs above"
    FAIL+=("Phase 1: Deploy")
    echo ""
    echo "  ⚠️  Deploy failed. Stopping pipeline."
    echo "  Fix the error above and re-run: bash run_e2e.sh --skip-deploy"
    exit 1
  fi
  echo ""
else
  SKIP+=("Phase 1: Deploy (--skip-deploy)")
  echo "  ⏭️  Phase 1 skipped (--skip-deploy)"
fi

# Ensure we have a Python after skipping deploy
if [[ -z "$PYTHON" ]]; then
  if [[ -x "$FIVEG_VENV/bin/python" ]]; then
    PYTHON="$FIVEG_VENV/bin/python"
  elif [[ -x "$LOCAL_VENV/bin/python" ]]; then
    PYTHON="$LOCAL_VENV/bin/python"
  else
    echo "❌ No Python venv found. Run without --skip-deploy or create .venv manually."
    exit 1
  fi
fi

# ── PHASE 2: google-adk(a2a) Classification ───────────────────────────────────
if [[ "$SKIP_CLASSIFY" == "false" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PHASE 2 — Apply google-adk(a2a) classification (3-PATCH)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Script : scripts/patch_a2a_classification.py --team food-court"
  echo "  Action : agentFramework=google-adk, 24 classMethods, agentCard"
  echo "  ETA    : ~1 minute"
  echo ""

  if "$PYTHON" scripts/patch_a2a_classification.py \
      --project "$PROJECT" \
      --region  "$REGION"  \
      --team    "food-court"; then
    echo ""
    echo "  ✅ Phase 2 complete — all food-court REs classified google-adk(a2a)"
    PASS+=("Phase 2: A2A classification")
  else
    echo ""
    echo "  ❌ Phase 2 FAILED — classification not applied (non-fatal, continuing)"
    FAIL+=("Phase 2: A2A classification")
    echo "  ⚠️  E2E tests will still run — a2a badge may not show in console"
  fi
  echo ""
else
  SKIP+=("Phase 2: A2A classification (--skip-classify)")
  echo "  ⏭️  Phase 2 skipped (--skip-classify)"
fi

# ── PHASE 3: E2E Tests ────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PHASE 3 — E2E Tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Script : scripts/e2e_test.py"
echo "  Method : Auto-discovers RE IDs by displayName (no hardcoded IDs)"
echo "  Tests  : 5 groups — health, pizza, burger, sushi, orchestrator"
echo "  ETA    : ~5–10 minutes (17 queries)"
echo ""

if "$PYTHON" scripts/e2e_test.py \
    --project "$PROJECT" \
    --region  "$REGION"; then
  PASS+=("Phase 3: E2E tests")
else
  FAIL+=("Phase 3: E2E tests")
fi
echo ""

# ── Final Summary ─────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║   run_e2e.sh — Final Summary                                    ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
for s in "${PASS[@]+${PASS[@]}}"; do
  echo "  ✅ $s"
done
for s in "${SKIP[@]+${SKIP[@]}}"; do
  echo "  ⏭️  $s"
done
for s in "${FAIL[@]+${FAIL[@]}}"; do
  echo "  ❌ $s"
done
echo ""
echo "  Agent Registry:"
echo "  https://console.cloud.google.com/vertex-ai/agent-registry?project=$PROJECT"
echo ""

if [[ "${#FAIL[@]}" -eq 0 ]]; then
  echo "  🎉 All phases passed! Food court is fully operational."
  exit 0
else
  echo "  ⚠️  ${#FAIL[@]} phase(s) failed — see logs above."
  exit 1
fi
