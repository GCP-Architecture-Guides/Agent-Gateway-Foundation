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
# deploy_pizza_agent.sh — Deploy the Pizza Specialist A2A agent
#
# 1. Installs A2A-compatible SDK versions into .venv
# 2. Applies gateway patch (incl. async httpx fix for cross-agent A2A calls)
# 3. Calls deploy_a2a_specialist.py to create the A2aAgent RE
# 4. Captures RE_ID and CARD_URL from Python script output
# 5. Grants 6 IAM roles to the Agent Identity SA
# 6. Registers the agent card with Agent Registry
# 7. Appends PIZZA_AGENT_CARD_URL to agents/orchestrator/.env
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

DISPLAY_NAME="pizza_specialist"
AGENT_DIR="$WORKSPACE/agents/pizza-agent"
ORCH_ENV="$WORKSPACE/agents/orchestrator/.env"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║       Deploying Pizza Specialist (A2A)                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo "  Project: $PROJECT_ID | Region: $REGION | Agent: $DISPLAY_NAME"
echo ""

# ── Validate agent directory ────────────────────────────────────────────────
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
echo "▶ Installing A2A SDK versions (this may take a few minutes)..."
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

# ── Apply gateway patch (including async httpx for A2A cross-agent auth) ────
echo "▶ Applying gateway patch (incl. async httpx for A2A auth)..."
export AGENT_GATEWAY_INGRESS="$INGRESS_GW"
export AGENT_GATEWAY_EGRESS="$EGRESS_GW"

python3 "$SCRIPT_DIR/patch_sdk_for_rest_create.py" \
  --ingress "$INGRESS_GW" \
  --egress  "$EGRESS_GW"  \
  --agent-name "$DISPLAY_NAME" \
  --venv .venv

# ── Copy gateway_agent lib into agent dir for bundling ──────────────────────
echo "▶ Bundling gateway_agent SDK..."
cp -r "lib/gateway_agent" "$AGENT_DIR/gateway_agent"

# ── Deploy via Python deploy script ─────────────────────────────────────────
echo "▶ Deploying A2A specialist to Vertex AI RE..."
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
echo "✅ Cleaned up bundled gateway_agent copy."

# ── Parse output ─────────────────────────────────────────────────────────────
RE_ID=$(echo "$DEPLOY_OUTPUT" | grep '^RE_ID=' | cut -d= -f2)
CARD_URL=$(echo "$DEPLOY_OUTPUT" | grep '^CARD_URL=' | cut -d= -f2)

if [[ -z "$RE_ID" || -z "$CARD_URL" ]]; then
  echo "❌ Could not parse RE_ID or CARD_URL from deploy output."
  echo "   DEPLOY_OUTPUT was: $DEPLOY_OUTPUT"
  exit 1
fi

echo ""
echo "✅ Pizza specialist deployed:"
echo "   RE_ID    : $RE_ID"
echo "   CARD_URL : $CARD_URL"
echo ""

# ── Wait for RE to become ACTIVE ─────────────────────────────────────────────
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
    echo "✅ RE is ACTIVE."
    break
  fi
done

if [[ "$RE_STATE" != "ACTIVE" ]]; then
  echo "⚠️  RE did not reach ACTIVE in 300s — final state: $RE_STATE"
  echo "   Continuing with IAM grants anyway."
fi

# ── Grant 6 IAM roles to Agent Identity SA ──────────────────────────────────
echo "▶ Granting IAM roles..."
source "$SCRIPT_DIR/grant_agent_iam_roles.sh"
grant_agent_iam_roles "$PROJECT_ID" "$REGION" "$RE_ID" "$TOKEN"

# ── Register agent card with Agent Registry ──────────────────────────────────
echo "▶ Registering agent card with Agent Registry..."
SERVICE_ID="pizza-specialist"
gcloud alpha agent-registry agents create "$SERVICE_ID" \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --display-name="Pizza Specialist" \
  --description="A2A specialist agent for pizza menu, customization, and pricing." \
  --agent-card-uri="$CARD_URL" \
  --quiet 2>&1 || echo "  (already registered or non-fatal — continuing)"

echo "✅ Agent card registered: $SERVICE_ID"

# ── Write card URL to orchestrator .env ─────────────────────────────────────
echo "▶ Writing PIZZA_AGENT_CARD_URL to orchestrator .env..."
mkdir -p "$(dirname "$ORCH_ENV")"
# Remove existing entry if present, then append
grep -v '^PIZZA_AGENT_CARD_URL=' "$ORCH_ENV" > "${ORCH_ENV}.tmp" 2>/dev/null || true
echo "PIZZA_AGENT_CARD_URL=${CARD_URL}" >> "${ORCH_ENV}.tmp"
mv "${ORCH_ENV}.tmp" "$ORCH_ENV"
echo "✅ Written: PIZZA_AGENT_CARD_URL to $ORCH_ENV"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║    ✅  Pizza Specialist Deploy Complete                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  RE_ID    : $RE_ID"
echo "  CARD_URL : $CARD_URL"
echo ""
echo "  Quick test (direct sub-agent):"
echo "  curl -X POST \\"
echo "    \"https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${RE_ID}:streamQuery\" \\"
echo "    -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -d '{\"input\":{\"user_id\":\"test\",\"session_id\":\"s1\",\"message\":\"What pizzas do you have?\"}}'"
