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

# ---------------------------------------------------------------------------
# deploy_orchestrator.sh — Deploy the Store Concierge Orchestrator A2A Agent
#
# MUST be run AFTER deploy_pizza_agent.sh and deploy_burger_agent.sh.
# Reads specialist CARD_URLs from agents/orchestrator/.env (written by each
# specialist deploy script).
#
# Flow:
#   1. Validate orchestrator/.env has specialist URLs
#   2. Install A2A SDK versions
#   3. Apply gateway patch
#   4. Deploy A2aAgent RE (orchestrator)
#   5. Wait for ACTIVE, grant IAM roles
#   6. Register orchestrator agent card
#   7. Write orchestrator RE ID to agents/orchestrator/.env
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
WORKSPACE="$(dirname "$SCRIPT_DIR")"

cd "$WORKSPACE"

# ── Read config from terraform.tfvars ──────────────────────────────────────
TFVARS="$WORKSPACE/terraform.tfvars"
if [[ ! -f "$TFVARS" ]]; then
  echo "❌ terraform.tfvars not found — cannot deploy."
  exit 1
fi

PROJECT_ID=$(grep -oP '^project_id\s*=\s*"\K[^"]+' "$TFVARS")
REGION=$(grep -oP '^location\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null \
         || grep -oP '^region\s*=\s*"\K[^"]+' "$TFVARS")
PREFIX=$(grep -oP '^prefix\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null || echo "agw")
BUCKET=$(grep -oP '^staging_bucket\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null \
         || echo "gs://${PROJECT_ID}-staging")

INGRESS_GW="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${PREFIX}-ingress-gateway"
EGRESS_GW="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${PREFIX}-egress-gateway"

DISPLAY_NAME="store_concierge"
AGENT_DIR="$WORKSPACE/agents/orchestrator"
ORCH_ENV="$WORKSPACE/agents/orchestrator/.env"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║      Deploying Store Concierge Orchestrator (A2A)       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo "  Project: $PROJECT_ID | Region: $REGION | Agent: $DISPLAY_NAME"
echo ""

# ── Validate specialist URLs are available ──────────────────────────────────
if [[ ! -f "$ORCH_ENV" ]]; then
  echo "❌ $ORCH_ENV not found."
  echo "   Run deploy_pizza_agent.sh and deploy_burger_agent.sh first."
  exit 1
fi

PIZZA_URL=$(grep '^PIZZA_AGENT_CARD_URL=' "$ORCH_ENV" | cut -d= -f2 || true)
BURGER_URL=$(grep '^BURGER_AGENT_CARD_URL=' "$ORCH_ENV" | cut -d= -f2 || true)

if [[ -z "$PIZZA_URL" ]]; then
  echo "❌ PIZZA_AGENT_CARD_URL missing from $ORCH_ENV"
  echo "   Run deploy_pizza_agent.sh first."
  exit 1
fi

if [[ -z "$BURGER_URL" ]]; then
  echo "❌ BURGER_AGENT_CARD_URL missing from $ORCH_ENV"
  echo "   Run deploy_burger_agent.sh first."
  exit 1
fi

echo "✅ Specialist URLs found:"
echo "   Pizza : $PIZZA_URL"
echo "   Burger: $BURGER_URL"
echo ""

# ── Validate orchestrator directory ──────────────────────────────────────────
for f in agent.py executor.py a2a_config.py requirements.txt; do
  if [[ ! -f "$AGENT_DIR/$f" ]]; then
    echo "❌ Missing $f in $AGENT_DIR"
    exit 1
  fi
done

# ── Activate / create venv ──────────────────────────────────────────────────
if [[ ! -x ".venv/bin/python" ]]; then
  echo "Creating .venv..."
  python3 -m venv .venv
fi
source .venv/bin/activate

# ── Install A2A-compatible SDK versions ────────────────────────────────────
echo "▶ Installing A2A SDK versions..."
pip install -q --no-deps "google-adk==2.5.0"
pip install -q \
  "google-cloud-aiplatform[adk,agent_engines]==1.163.0" \
  "a2a-sdk==1.1.2" \
  "sse-starlette" \
  "cloudpickle" \
  "requests>=2.31.0,<3.0.0"

# ── Install gateway_agent lib ────────────────────────────────────────────────
echo "▶ Installing gateway_agent SDK..."
pip install -q -e "$WORKSPACE/lib/gateway_agent/"

# ── Apply gateway patch ──────────────────────────────────────────────────────
echo "▶ Applying gateway patch (incl. async httpx for A2A auth)..."
export AGENT_GATEWAY_INGRESS="$INGRESS_GW"
export AGENT_GATEWAY_EGRESS="$EGRESS_GW"

python3 "$SCRIPT_DIR/patch_sdk_for_rest_create.py" \
  --ingress "$INGRESS_GW" \
  --egress  "$EGRESS_GW"  \
  --agent-name "$DISPLAY_NAME" \
  --venv .venv

# ── Bundle gateway_agent lib ─────────────────────────────────────────────────
echo "▶ Bundling gateway_agent SDK..."
cp -r "lib/gateway_agent" "$AGENT_DIR/gateway_agent"

# ── Deploy with specialist URLs as environment variables ─────────────────────
echo "▶ Deploying orchestrator to Vertex AI RE..."
echo "   (PIZZA_AGENT_CARD_URL and BURGER_AGENT_CARD_URL will be injected)"

# The Python deploy script reads env vars from the agent's .env at runtime,
# but we need to inject them at deploy time as RE environment_variables.
# We pass them via the PIZZA_AGENT_CARD_URL / BURGER_AGENT_CARD_URL env vars
# so deploy_a2a_specialist.py picks them up and passes them to the RE.
export PIZZA_AGENT_CARD_URL="$PIZZA_URL"
export BURGER_AGENT_CARD_URL="$BURGER_URL"

DEPLOY_OUTPUT=$(python3 "$SCRIPT_DIR/deploy_a2a_specialist.py" \
  --agent-dir    "$AGENT_DIR" \
  --display-name "$DISPLAY_NAME" \
  --project      "$PROJECT_ID" \
  --region       "$REGION" \
  --bucket       "$BUCKET" \
  --ingress      "$INGRESS_GW" \
  --egress       "$EGRESS_GW" \
  --agent-name   "$DISPLAY_NAME" 2>&1 | tee /dev/stderr | grep -E '^(RE_ID|CARD_URL|RESOURCE_NAME)=')

# ── Cleanup bundled SDK ──────────────────────────────────────────────────────
rm -rf "$AGENT_DIR/gateway_agent"

# ── Parse output ──────────────────────────────────────────────────────────────
RE_ID=$(echo "$DEPLOY_OUTPUT" | grep '^RE_ID=' | cut -d= -f2)
CARD_URL=$(echo "$DEPLOY_OUTPUT" | grep '^CARD_URL=' | cut -d= -f2)

if [[ -z "$RE_ID" || -z "$CARD_URL" ]]; then
  echo "❌ Could not parse RE_ID or CARD_URL from deploy output."
  exit 1
fi

echo ""
echo "✅ Orchestrator deployed: RE_ID=$RE_ID"

# ── Wait for ACTIVE ───────────────────────────────────────────────────────────
echo "▶ Waiting for RE to become ACTIVE..."
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null)
RE_STATE="UNKNOWN"
for i in $(seq 1 60); do
  sleep 5
  RE_STATE=$(
    curl -s -H "Authorization: Bearer $TOKEN" \
      "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${RE_ID}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state','UNKNOWN'))" 2>/dev/null
  )
  echo "  [attempt $i/60] state=$RE_STATE"
  if [[ "$RE_STATE" == "ACTIVE" ]]; then
    echo "✅ Orchestrator RE is ACTIVE."
    break
  fi
done

# ── Grant IAM roles ───────────────────────────────────────────────────────────
echo "▶ Granting IAM roles to orchestrator agent identity..."
source "$SCRIPT_DIR/grant_agent_iam_roles.sh"
grant_agent_iam_roles "$PROJECT_ID" "$REGION" "$RE_ID" "$TOKEN"

# ── Register with Agent Registry ─────────────────────────────────────────────
echo "▶ Registering orchestrator agent card with Agent Registry..."
gcloud alpha agent-registry agents create "store-concierge" \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --display-name="Store Concierge" \
  --description="Orchestrator that routes food orders to pizza/burger specialists via A2A." \
  --agent-card-uri="$CARD_URL" \
  --quiet 2>&1 || echo "  (already registered or non-fatal — continuing)"

echo "✅ Orchestrator agent card registered."

# ── Write RE ID to orchestrator .env ─────────────────────────────────────────
echo "▶ Writing orchestrator RE_ID and CARD_URL to $ORCH_ENV..."
grep -v '^ORCHESTRATOR_' "$ORCH_ENV" > "${ORCH_ENV}.tmp" 2>/dev/null || true
echo "ORCHESTRATOR_RE_ID=${RE_ID}" >> "${ORCH_ENV}.tmp"
echo "ORCHESTRATOR_CARD_URL=${CARD_URL}" >> "${ORCH_ENV}.tmp"
mv "${ORCH_ENV}.tmp" "$ORCH_ENV"
echo "✅ Written: ORCHESTRATOR_RE_ID and ORCHESTRATOR_CARD_URL to $ORCH_ENV"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║    ✅  Orchestrator Deploy Complete                      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  RE_ID    : $RE_ID"
echo "  CARD_URL : $CARD_URL"
echo ""
echo "  3-Agent Mesh Summary:"
echo "    🍕 pizza_specialist  → $(grep '^PIZZA_AGENT_CARD_URL=' "$ORCH_ENV" | cut -d= -f2 | tail -c 50)"
echo "    🍔 burger_specialist → $(grep '^BURGER_AGENT_CARD_URL=' "$ORCH_ENV" | cut -d= -f2 | tail -c 50)"
echo "    🤖 store_concierge  → $CARD_URL"
echo ""
echo "  E2E test:"
echo "  bash test-agent/e2e_test_a2a.sh"
