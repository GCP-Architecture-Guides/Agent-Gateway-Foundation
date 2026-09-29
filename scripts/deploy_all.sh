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

# ---------------------------------------------------------------------------
# deploy_all.sh — One-shot deploy + classify + validate for all food-court agents.
#
# What this script does:
#
#   STEP 0 — [--fresh only] Deploy specialists
#             Deploy pizza_specialist, burger_specialist, sushi_specialist from scratch.
#             Required after a full destroy_all.sh teardown. Skipped by default
#             (assumes specialists are already deployed and just need patching).
#             script: scripts/deploy_a2a_agents.sh --only pizza burger sushi
#
#   STEP 1 — Path A: Metadata PATCH  (no redeploy, < 10s)
#             Apply google-adk(a2a) classification (24 classMethods) to all
#             food-court specialist agents already deployed. Zero downtime.
#             script: scripts/patch_a2a_classification.py
#
#   STEP 2 — Deploy orchestrator  (~5 min)
#             Deploy store_concierge (store concierge) via AdkApp + AgentEngine.create().
#             Uses the fiveg venv (aiplatform==1.162.0, adk==2.5.0, a2a-sdk==1.1.2).
#             After deploy applies google-adk(a2a) classification PATCH.
#             script: scripts/redeploy_orchestrator.py
#             config: agents/orchestrator/agent.py
#
#   STEP 3 — E2E validation
#             Runs scripts/e2e_test.py against all deployed agents.
#             Passes only if all specialist AND orchestrator tests pass.
#
#   STEP 4 — SGP Policy creation (per food-court agent)
#             Waits 90s for Vertex AI to auto-register REs in Agent Registry,
#             then calls scripts/create_sgp_policy.sh for each food-court agent.
#             Skipped with --skip-sgp (useful when re-deploying with existing SGPs).
#             Reads sgp_nlc_constraint from terraform.tfvars or SGP_NLC_CONSTRAINT env.
#
# Usage:
#   bash scripts/deploy_all.sh                   # full deploy + SGP
#   bash scripts/deploy_all.sh --fresh           # deploy specialists first (after full destroy)
#   bash scripts/deploy_all.sh --skip-orchestrator   # just classify + test + SGP
#   bash scripts/deploy_all.sh --skip-e2e            # classify + deploy + SGP, no E2E test
#   bash scripts/deploy_all.sh --skip-sgp            # skip SGP creation (re-deploy with existing SGPs)
#   bash scripts/deploy_all.sh --e2e-only            # just run E2E tests (no deploy, no SGP)
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
ROOT="$(dirname "$SCRIPT_DIR")"

# ── Parse flags ──────────────────────────────────────────────────────────────
SKIP_ORCHESTRATOR=false
SKIP_E2E=false
E2E_ONLY=false
DEPLOY_SPECIALISTS=false
SKIP_SGP=false

for arg in "$@"; do
  case "$arg" in
    --fresh)             DEPLOY_SPECIALISTS=true ;;
    --skip-orchestrator) SKIP_ORCHESTRATOR=true ;;
    --skip-e2e)          SKIP_E2E=true ;;
    --skip-sgp)          SKIP_SGP=true ;;
    --e2e-only)          E2E_ONLY=true; SKIP_ORCHESTRATOR=true; SKIP_SGP=true ;;
    --help|-h)
      grep "^#" "$0" | head -55 | sed 's/^# \?//'
      exit 0 ;;
  esac
done

# ── Read config from terraform.tfvars ────────────────────────────────────────
TFVARS="$ROOT/terraform.tfvars"
if [[ ! -f "$TFVARS" ]]; then
  echo "❌ terraform.tfvars not found at $TFVARS"
  exit 1
fi
PROJECT_ID=$(grep -oP '^project_id\s*=\s*"\K[^"]+' "$TFVARS")
REGION=$(grep -oP '^location\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null \
         || grep -oP '^region\s*=\s*"\K[^"]+' "$TFVARS")
PREFIX=$(grep -oP '^prefix\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null || echo "geap")
# Alias — internal scripts use $PROJECT for brevity
PROJECT="$PROJECT_ID"

# ── Venv with A2A packages ────────────────────────────────────────────────────
# Reuse fiveg venv (aiplatform==1.162.0, adk==2.5.0, a2a-sdk==1.1.2).
# Airlock mirror does not have these versions, so we borrow from an existing
# validated environment.
FIVEG_VENV="$HOME/Desktop/Workspace/fiveg-ran-agent/foundation/.venv"
WORKSPACE_VENV="$HOME/Desktop/Workspace/.venv"

if [[ -x "$FIVEG_VENV/bin/python" ]]; then
  VENV="$FIVEG_VENV"
elif [[ -x "$WORKSPACE_VENV/bin/python" ]]; then
  VENV="$WORKSPACE_VENV"
else
  echo "❌ No A2A-capable venv found. Need aiplatform==1.162.0 + adk==2.5.0"
  echo "   Expected at: $FIVEG_VENV"
  exit 1
fi
PYTHON="$VENV/bin/python"

INGRESS="projects/${PROJECT}/locations/${REGION}/agentGateways/${PREFIX}-ingress-gateway"
EGRESS="projects/${PROJECT}/locations/${REGION}/agentGateways/${PREFIX}-egress-gateway"

export AGENT_GATEWAY_INGRESS="$INGRESS"
export AGENT_GATEWAY_EGRESS="$EGRESS"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       Food Court — deploy_all.sh                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Project : $PROJECT_ID  |  Region  : $REGION"
echo "  Ingress : $INGRESS"
echo "  Egress  : $EGRESS"
echo "  Venv    : $VENV"
echo "  Fresh   : $DEPLOY_SPECIALISTS  (--fresh deploys specialists before patching)"
echo ""

STEP_PASS=()
STEP_FAIL=()

# ────────────────────────────────────────────────────────────────────────────
# STEP 1 — Path A: Metadata PATCH for google-adk(a2a) on all specialists
# ────────────────────────────────────────────────────────────────────────────
if [[ "$E2E_ONLY" == "false" ]]; then

  # ── STEP 0 (--fresh only): Deploy specialists from scratch ────────────────
  if [[ "$DEPLOY_SPECIALISTS" == "true" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  STEP 0 — Deploy food-court specialists (--fresh)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Agents  : pizza_specialist · burger_specialist · sushi_specialist"
    echo "  ETA     : ~10–15 minutes"
    echo ""

    # deploy_a2a_agents.sh --only accepts ONE agent at a time; loop per specialist
    STEP0_FAIL=false
    for specialist in pizza burger sushi; do
      echo "  Deploying $specialist..."
      bash "$SCRIPT_DIR/deploy_a2a_agents.sh" \
        --only "$specialist" 2>&1
      if [[ $? -ne 0 ]]; then
        echo "  ❌ Specialist deploy failed: $specialist"
        STEP0_FAIL=true
      else
        echo "  ✅ $specialist deployed"
      fi
      echo ""
    done

    if [[ "$STEP0_FAIL" == "true" ]]; then
      echo "  ❌ Step 0 FAILED — one or more specialists not deployed; aborting"
      STEP_FAIL+=("Step 0: Specialist deploy")
      exit 1
    else
      echo "  ✅ Step 0 complete — all specialists deployed"
      STEP_PASS+=("Step 0: Specialist deploy")
    fi
    echo ""
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  STEP 1 — Path A: Classify all food-court REs as google-adk(a2a)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Allow STEP 1 failure to be caught by PIPESTATUS rather than set -e
  "$PYTHON" "$SCRIPT_DIR/patch_a2a_classification.py" \
    --project "$PROJECT_ID" \
    --region  "$REGION"  \
    --team    "food-court" 2>&1 | grep -v "^bash:" | grep -v "error importing" || true

  if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
    echo "  ✅ Step 1 complete — all food-court agents classified google-adk(a2a)"
    STEP_PASS+=("Step 1: Path A classification")
  else
    echo "  ❌ Step 1 FAILED — check logs above"
    STEP_FAIL+=("Step 1: Path A classification")
  fi
  echo ""
fi

# ────────────────────────────────────────────────────────────────────────────
# STEP 2 — Deploy store_concierge orchestrator
# ────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_ORCHESTRATOR" == "false" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  STEP 2 — Deploy store_concierge orchestrator"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Agent   : store_concierge (food-court orchestrator)"
  echo "  Script  : scripts/redeploy_orchestrator.py → AdkApp + AgentEngine.create()"
  echo "  Post    : contextSpec + classMethods (24) + agentCard + labels + IAM (7 roles)"
  echo "  ETA     : ~5 minutes"
  echo ""

  "$PYTHON" "$SCRIPT_DIR/redeploy_orchestrator.py" \
    --project "$PROJECT_ID" \
    --region  "$REGION"  \
    2>&1 | grep -v "^bash:" | grep -v "error importing"

  DEPLOY_EXIT=${PIPESTATUS[0]}
  if [[ "$DEPLOY_EXIT" -eq 0 ]]; then
    echo ""
    echo "  ✅ Orchestrator deployed"
    STEP_PASS+=("Step 2: Orchestrator deploy")

    # Apply Path A classification to the freshly deployed orchestrator too
    echo "  Applying google-adk(a2a) classification to orchestrator..."
    "$PYTHON" "$SCRIPT_DIR/patch_a2a_classification.py" \
      --project "$PROJECT_ID" \
      --region  "$REGION"  \
      --team    "food-court" 2>&1 | grep -E "✅|❌|PATCH|methods|Classification"
    echo ""
  else
    echo "  ❌ Step 2 FAILED — check logs above"
    STEP_FAIL+=("Step 2: Orchestrator deploy")
  fi
fi

# ────────────────────────────────────────────────────────────────────────────
# STEP 3 — E2E validation
# ────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_E2E" == "false" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  STEP 3 — E2E Validation"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Script  : scripts/e2e_test.py"
  echo "  Agents  : pizza · burger · sushi specialists + store_concierge orchestrator"
  echo "  ETA     : ~2 minutes (17 queries across 4 agents)"
  echo ""

  "$PYTHON" "$SCRIPT_DIR/e2e_test.py" \
    --project "$PROJECT_ID" \
    --region  "$REGION"  \
    2>&1 | grep -v "^bash:" | grep -v "error importing"

  E2E_EXIT=${PIPESTATUS[0]}
  if [[ "$E2E_EXIT" -eq 0 ]]; then
    STEP_PASS+=("Step 3: E2E tests")
  else
    STEP_FAIL+=("Step 3: E2E tests")
  fi
fi

# ────────────────────────────────────────────────────────────────────────────
# STEP 4 — SGP NLC Policy creation (all food-court agents)
# Must run after RE is ACTIVE. AgentEngine.create() blocks until ACTIVE,
# but Agent Registry auto-registration lags ~90s behind RE becoming ACTIVE.
# ────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_SGP" == "false" && "$E2E_ONLY" == "false" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  STEP 4 — SGP NLC Policy creation (all food-court agents)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Agents  : store_concierge · pizza_specialist · burger_specialist · sushi_specialist"
  echo "  Waiting 90s for Agent Registry to register REs..."
  echo ""
  sleep 90

  SGP_AGENTS=("store_concierge" "pizza_specialist" "burger_specialist" "sushi_specialist")
  SGP_ALL_OK=true

  for sgp_agent in "${SGP_AGENTS[@]}"; do
    echo "  Creating SGP for: $sgp_agent"
    # Check script exit code directly — not grep output which is unreliable
    AGENT_NAME="$sgp_agent" bash "$SCRIPT_DIR/create_sgp_policy.sh" 2>&1
    if [[ $? -eq 0 ]]; then
      echo "  ✅ SGP done: $sgp_agent"
    else
      echo "  ⚠️  SGP incomplete for: $sgp_agent"
      echo "     Retry: AGENT_NAME=$sgp_agent bash scripts/create_sgp_policy.sh"
      SGP_ALL_OK=false
    fi
    echo ""
  done

  if [[ "$SGP_ALL_OK" == "true" ]]; then
    STEP_PASS+=("Step 4: SGP policy creation (4/4 agents)")
  else
    STEP_PASS+=("Step 4: SGP policy creation (partial -- retry above)")
  fi
  echo ""
fi


# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   deploy_all.sh — Summary                                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
for s in "${STEP_PASS[@]+"${STEP_PASS[@]}"}"; do
  echo "  ✅ $s"
done
for s in "${STEP_FAIL[@]+"${STEP_FAIL[@]}"}"; do
  echo "  ❌ $s"
done

echo ""
echo "  Agent Registry:"
echo "  https://console.cloud.google.com/vertex-ai/agent-registry?project=$PROJECT_ID"
echo ""

if [[ "${#STEP_FAIL[@]}" -eq 0 ]]; then
  echo "  🎉 All steps passed!"
  echo ""
  echo "  Food-court is live!"
  echo ""
  exit 0
else
  echo "  ⚠️  ${#STEP_FAIL[@]} step(s) failed — see logs above"
  exit 1
fi
