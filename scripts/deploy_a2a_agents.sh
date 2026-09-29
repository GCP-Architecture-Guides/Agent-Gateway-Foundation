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
# This code is not built for production workload.

# ---------------------------------------------------------------------------
# deploy_a2a_agents.sh  —  Deploy the 4-agent A2A mesh (Dynamic Discovery)
#
# Deploy path: Python deploy_a2a_agent.py → AgentEngine.create()
#   WHY: adk deploy agent_engine (ADK 2.5.0) uses agentplatform.Client which
#   bypasses AuthorizedSession — the gateway patch cannot intercept it.
#   AgentEngine.create() goes through the patched transport layer.
#   (See a2a-agent-deploy SKILL.md §13 Caveat #15)
#
# Per-agent flow:
#   1. Bundle food_court_backend.py into agent dir (Firestore backend)
#   2. python deploy_a2a_agent.py --agent <dir> ...
#      → cloudpickle.register_pickle_by_value (Caveat #16)
#      → A2aAgent + AdkA2aExecutor
#      → AgentEngine.create() (gateway patch injects org-policy fields)
#      → Post-deploy: strip contextSpec, PATCH classMethods (24), labels, IAM
#   3. Remove bundled food_court_backend.py (keep source dir clean)
#
# Usage:
#   bash scripts/deploy_a2a_agents.sh               # deploy all 4 agents
#   bash scripts/deploy_a2a_agents.sh --only pizza   # redeploy pizza only
#   bash scripts/deploy_a2a_agents.sh --only burger  # redeploy burger only
#   bash scripts/deploy_a2a_agents.sh --only sushi   # redeploy sushi only
#   bash scripts/deploy_a2a_agents.sh --only orch          # redeploy orchestrator only
#   bash scripts/deploy_a2a_agents.sh --only orchestrator   # redeploy orchestrator only
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
WORKSPACE="$(dirname "$SCRIPT_DIR")"
cd "$WORKSPACE"

# Parse --only flag
ONLY_AGENT=""
if [[ "${1:-}" == "--only" && -n "${2:-}" ]]; then
  ONLY_AGENT="${2}"
  echo "  ⚡ --only mode: deploying '$ONLY_AGENT' only"
fi

# ── Read config ───────────────────────────────────────────────────────────────
TFVARS="$WORKSPACE/terraform.tfvars"
[[ -f "$TFVARS" ]] || { echo "❌ terraform.tfvars not found"; exit 1; }

PROJECT_ID=$(grep -oP '^project_id\s*=\s*"\K[^"]+' "$TFVARS")
REGION=$(grep -oP '^location\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null \
         || grep -oP '^region\s*=\s*"\K[^"]+' "$TFVARS")
PREFIX=$(grep -oP '^prefix\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null || echo "geap")

INGRESS_GW="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${PREFIX}-ingress-gateway"
EGRESS_GW="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${PREFIX}-egress-gateway"

export GCP_PROJECT_ID="$PROJECT_ID"
export GCP_REGION="$REGION"
export GOOGLE_CLOUD_LOCATION="global"
export AGENT_GATEWAY_INGRESS="$INGRESS_GW"
export AGENT_GATEWAY_EGRESS="$EGRESS_GW"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║     Deploying 4-Agent Concierge Mesh (AgentEngine)      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo "  Project : $PROJECT_ID | Region : $REGION"
echo "  Path    : deploy_a2a_agent.py → AgentEngine.create()"
echo "  Deps    : google-adk==2.5.0 + aiplatform==1.162.0 + a2a-sdk==1.1.2"
echo ""

# ── Venv: prefer fiveg-ran-agent (aiplatform==1.162.0, adk==2.5.0) ─────────
FIVEG_VENV="$HOME/Desktop/Workspace/fiveg-ran-agent/foundation/.venv"
LOCAL_VENV="$WORKSPACE/.venv"

if [[ -x "$FIVEG_VENV/bin/python" ]]; then
  PYTHON="$FIVEG_VENV/bin/python"
  PIP="$FIVEG_VENV/bin/pip"
  echo "  Using fiveg venv: $(${PYTHON} --version 2>&1)"
elif [[ -x "$LOCAL_VENV/bin/python" ]]; then
  PYTHON="$LOCAL_VENV/bin/python"
  PIP="$LOCAL_VENV/bin/pip"
  echo "  Using local .venv"
else
  echo "▶ Creating local .venv..."
  /usr/bin/python3 -m venv "$LOCAL_VENV"
  PYTHON="$LOCAL_VENV/bin/python"
  PIP="$LOCAL_VENV/bin/pip"
fi

# ── Install deps into venv ────────────────────────────────────────────────────
echo "▶ Installing/verifying dependencies..."
"$PIP" install -q --no-deps "google-adk==2.5.0"
"$PIP" install -q \
  "google-cloud-aiplatform[agent_engines,adk]==1.162.0" \
  "a2a-sdk[http-server]==1.1.2" \
  "requests>=2.31.0,<3.0.0" \
  "pydantic" \
  "cloudpickle>=3.0.0" \
  "google-auth" \
  "httpx" \
  "google-cloud-firestore"
echo "✅ Dependencies ready."
echo ""

# ── Apply gateway patch ───────────────────────────────────────────────────────
# Critical: must patch the venv we're using, not the local .venv (if using fiveg).
VENV_DIR="$(dirname "$(dirname "$PYTHON")")"
echo "▶ Applying gateway patch to $VENV_DIR ..."
"$PYTHON" scripts/patch_sdk_for_rest_create.py \
  --ingress "$INGRESS_GW" \
  --egress  "$EGRESS_GW"  \
  --agent-name "store_concierge" \
  --venv "$VENV_DIR"
echo "✅ Gateway patch applied."
echo ""

# ── Helper: deploy one agent via deploy_a2a_agent.py ─────────────────────────
# Sets global LAST_RE_ID after each deploy (populated from deploy output)
LAST_RE_ID=""

deploy_agent() {
  local AGENT_DIR_NAME="$1"      # e.g. "pizza-agent"
  local DISPLAY_NAME="$2"        # e.g. "pizza_specialist"
  local DESCRIPTION="$3"
  local CAPABILITY="${4:-}"      # e.g. "pizza-ordering"
  local ROLE="${5:-specialist}"  # "specialist" or "orchestrator"
  # extra_envs: optional array of KEY=VALUE strings appended as --extra-env
  # passed via deploy_agent_with_envs() wrapper
  local EXTRA_ENV_ARGS=("${@:6}")

  echo "────────────────────────────────────────────────────────"
  echo "▶ Deploying: $DISPLAY_NAME (dir: agents/$AGENT_DIR_NAME)"
  echo ""

  local AGENT_DIR="$WORKSPACE/agents/$AGENT_DIR_NAME"
  [[ -d "$AGENT_DIR" ]] || { echo "❌ Missing agents/$AGENT_DIR_NAME"; exit 1; }
  [[ -f "$AGENT_DIR/agent.py" ]] || { echo "❌ Missing agent.py"; exit 1; }

  # Write fresh .env
  cat > "$AGENT_DIR/.env" <<ENVEOF
GCP_PROJECT_ID=${PROJECT_ID}
GOOGLE_CLOUD_PROJECT=${PROJECT_ID}
GOOGLE_CLOUD_LOCATION=global
GCP_REGION=${REGION}
AGENT_NAME=${DISPLAY_NAME}
AGENT_GATEWAY_INGRESS=${INGRESS_GW}
AGENT_GATEWAY_EGRESS=${EGRESS_GW}
GOOGLE_API_USE_MTLS_ENDPOINT=never
OTEL_EXPORTER_OTLP_TIMEOUT=2000
OTEL_BSP_EXPORT_TIMEOUT_MILLIS=2000
OTEL_BSP_SCHEDULE_DELAY_MILLIS=15000
GOOGLE_API_USE_CLIENT_CERTIFICATE=false
ENVEOF

  # Bundle food_court_backend.py (required by agent at import time)
  BACKEND_SRC="$WORKSPACE/lib/food_court_backend.py"
  BACKEND_DST="$AGENT_DIR/food_court_backend.py"
  if [[ -f "$BACKEND_SRC" ]]; then
    cp "$BACKEND_SRC" "$BACKEND_DST"
    echo "  ✅ Bundled food_court_backend.py"
  else
    echo "  ⚠️  lib/food_court_backend.py not found — Firestore backend unavailable"
  fi

  # Build args for deploy_a2a_agent.py
  local DEPLOY_ARGS=(
    --agent  "$AGENT_DIR_NAME"
    --project "$PROJECT_ID"
    --region  "$REGION"
    --display-name "$DISPLAY_NAME"
    --team   "food-court"
    --role   "$ROLE"
  )
  [[ -n "$CAPABILITY" ]] && DEPLOY_ARGS+=(--capability "$CAPABILITY")
  # Append any --extra-env args (for orchestrator specialist RE injection)
  for env_kv in "${EXTRA_ENV_ARGS[@]:-}"; do
    [[ -n "$env_kv" ]] && DEPLOY_ARGS+=(--extra-env "$env_kv")
  done

  echo "  Running deploy_a2a_agent.py (3–8 min)..."
  local DEPLOY_LOG
  DEPLOY_LOG=$(
    GCP_PROJECT_ID="$PROJECT_ID" \
    GCP_REGION="$REGION" \
    AGENT_GATEWAY_INGRESS="$INGRESS_GW" \
    AGENT_GATEWAY_EGRESS="$EGRESS_GW" \
    "$PYTHON" scripts/deploy_a2a_agent.py "${DEPLOY_ARGS[@]}" 2>&1 | tee /dev/stderr
  )

  local DEPLOY_EXIT=${PIPESTATUS[0]}

  # Extract RE_ID from deploy output for orchestrator injection
  LAST_RE_ID=$(echo "$DEPLOY_LOG" | grep -o 'RE_ID=[0-9]*' | tail -1 | cut -d= -f2)

  # Cleanup bundled backend
  rm -f "$BACKEND_DST"
  echo "  ✅ Cleaned up food_court_backend.py"

  [[ $DEPLOY_EXIT -eq 0 ]] || { echo "❌ deploy_a2a_agent.py failed (exit $DEPLOY_EXIT)"; exit $DEPLOY_EXIT; }
  echo ""
}

# Track specialist RE resource names for orchestrator injection (PSC VPC: no runtime discovery)
PIZZA_RE_NAME=""
BURGER_RE_NAME=""
SUSHI_RE_NAME=""

# ── Step 1: Pizza Specialist ──────────────────────────────────────────────────
if [[ -z "$ONLY_AGENT" || "$ONLY_AGENT" == "pizza" ]]; then
  deploy_agent "pizza-agent" "pizza_specialist" \
    "Pizza Specialist: menu, customization, ingredients, pricing." \
    "pizza-ordering" "specialist"
  # Capture RE name for orchestrator env injection
  if [[ -n "$LAST_RE_ID" ]]; then
    PIZZA_RE_NAME="projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${LAST_RE_ID}"
    echo "  📌 pizza RE captured: $PIZZA_RE_NAME"
  fi
  echo "✅ pizza_specialist deployed."
else
  # When --only=orchestrator, look up existing pizza specialist RE from labels
  if [[ -z "$PIZZA_RE_NAME" ]]; then
    PIZZA_RE_NAME=$("$PYTHON" -c "
import google.auth, google.auth.transport.requests, requests
creds,_ = google.auth.default(scopes=['https://www.googleapis.com/auth/cloud-platform'])
creds.refresh(google.auth.transport.requests.Request())
h = {'Authorization': f'Bearer {creds.token}'}
r = requests.get('https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines', headers=h)
for re in r.json().get('reasoningEngines',[]):
    if re.get('labels',{}).get('capability') == 'pizza-ordering':
        print(re['name']); break
" 2>/dev/null)
    [[ -n "$PIZZA_RE_NAME" ]] && echo "  📌 pizza RE discovered: $PIZZA_RE_NAME"
  fi
  echo "  Skipping pizza (--only=$ONLY_AGENT)"
fi
echo ""

# ── Step 2: Burger Specialist ─────────────────────────────────────────────────
if [[ -z "$ONLY_AGENT" || "$ONLY_AGENT" == "burger" ]]; then
  deploy_agent "burger-agent" "burger_specialist" \
    "Burger Specialist: menu, customization, grill options, nutrition." \
    "burger-ordering" "specialist"
  if [[ -n "$LAST_RE_ID" ]]; then
    BURGER_RE_NAME="projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${LAST_RE_ID}"
    echo "  📌 burger RE captured: $BURGER_RE_NAME"
  fi
  echo "✅ burger_specialist deployed."
else
  if [[ -z "$BURGER_RE_NAME" ]]; then
    BURGER_RE_NAME=$("$PYTHON" -c "
import google.auth, google.auth.transport.requests, requests
creds,_ = google.auth.default(scopes=['https://www.googleapis.com/auth/cloud-platform'])
creds.refresh(google.auth.transport.requests.Request())
h = {'Authorization': f'Bearer {creds.token}'}
r = requests.get('https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines', headers=h)
for re in r.json().get('reasoningEngines',[]):
    if re.get('labels',{}).get('capability') == 'burger-ordering':
        print(re['name']); break
" 2>/dev/null)
    [[ -n "$BURGER_RE_NAME" ]] && echo "  📌 burger RE discovered: $BURGER_RE_NAME"
  fi
  echo "  Skipping burger (--only=$ONLY_AGENT)"
fi
echo ""

# ── Step 3: Sushi Specialist ──────────────────────────────────────────────────
if [[ -z "$ONLY_AGENT" || "$ONLY_AGENT" == "sushi" ]]; then
  deploy_agent "sushi-agent" "sushi_specialist" \
    "Sushi Specialist: rolls, nigiri, sashimi, omakase." \
    "sushi-ordering" "specialist"
  if [[ -n "$LAST_RE_ID" ]]; then
    SUSHI_RE_NAME="projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${LAST_RE_ID}"
    echo "  📌 sushi RE captured: $SUSHI_RE_NAME"
  fi
  echo "✅ sushi_specialist deployed."
else
  if [[ -z "$SUSHI_RE_NAME" ]]; then
    SUSHI_RE_NAME=$("$PYTHON" -c "
import google.auth, google.auth.transport.requests, requests
creds,_ = google.auth.default(scopes=['https://www.googleapis.com/auth/cloud-platform'])
creds.refresh(google.auth.transport.requests.Request())
h = {'Authorization': f'Bearer {creds.token}'}
r = requests.get('https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines', headers=h)
for re in r.json().get('reasoningEngines',[]):
    if re.get('labels',{}).get('capability') == 'sushi-ordering':
        print(re['name']); break
" 2>/dev/null)
    [[ -n "$SUSHI_RE_NAME" ]] && echo "  📌 sushi RE discovered: $SUSHI_RE_NAME"
  fi
  echo "  Skipping sushi (--only=$ONLY_AGENT)"
fi
echo ""

# ── Step 4: Orchestrator (Store Concierge) ─────────────────────────────────────
if [[ -z "$ONLY_AGENT" || "$ONLY_AGENT" == "orch" || "$ONLY_AGENT" == "orchestrator" ]]; then
  # Build --extra-env args to inject specialist RE names (PSC VPC: no runtime discovery via API)
  ORCH_EXTRA_ENVS=()
  if [[ -n "$PIZZA_RE_NAME" ]]; then
    ORCH_EXTRA_ENVS+=("SPECIALIST_PIZZA_ORDERING_RE_NAME=${PIZZA_RE_NAME}")
    echo "  ➡ Injecting pizza RE: $PIZZA_RE_NAME"
  else
    echo "  ⚠️  Pizza RE name unknown — orchestrator will fall back to gRPC discovery"
  fi
  if [[ -n "$BURGER_RE_NAME" ]]; then
    ORCH_EXTRA_ENVS+=("SPECIALIST_BURGER_ORDERING_RE_NAME=${BURGER_RE_NAME}")
    echo "  ➡ Injecting burger RE: $BURGER_RE_NAME"
  else
    echo "  ⚠️  Burger RE name unknown — orchestrator will fall back to gRPC discovery"
  fi
  if [[ -n "$SUSHI_RE_NAME" ]]; then
    ORCH_EXTRA_ENVS+=("SPECIALIST_SUSHI_ORDERING_RE_NAME=${SUSHI_RE_NAME}")
    echo "  ➡ Injecting sushi RE: $SUSHI_RE_NAME"
  else
    echo "  ⚠️  Sushi RE name unknown — orchestrator will fall back to gRPC discovery"
  fi

  deploy_agent "orchestrator" "store_concierge" \
    "Store Concierge Orchestrator: routes to specialists via env-injected RE names (PSC VPC safe)." \
    "" "orchestrator" "${ORCH_EXTRA_ENVS[@]:-}"
  echo "✅ store_concierge (orchestrator) deployed."
else
  echo "  Skipping orchestrator (--only=$ONLY_AGENT)"
fi
echo ""

echo "╔══════════════════════════════════════════════════════════╗"
if [[ -z "$ONLY_AGENT" ]]; then
  echo "║    ✅  All 4 Agents Deployed (Phase 2: Dynamic Discovery)  ║"
else
  echo "║    ✅  Specialist Deployed — Zero Orchestrator Redeploy    ║"
fi
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Orchestrator uses env-injected RE names for PSC VPC-safe routing."
echo "  When redeploying a specialist, re-run orchestrator deploy to update:"
echo "    bash scripts/deploy_a2a_agents.sh --only orchestrator"
echo "  (RE names are auto-discovered from labels and injected)"
echo ""
echo "  E2E tests:"
echo "  python scripts/e2e_test.py --project $PROJECT_ID --region $REGION"
