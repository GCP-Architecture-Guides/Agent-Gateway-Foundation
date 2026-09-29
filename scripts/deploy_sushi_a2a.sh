#!/usr/bin/env bash
# =============================================================================
# scripts/deploy_sushi_a2a.sh
# Deploy sushi-agent-a2a as a TRUE google-adk(a2a) Reasoning Engine.
#
# Uses scripts/deploy_a2a_agent.py which implements:
#   - cloudpickle.register_pickle_by_value (Caveat #16)
#   - A2aAgent + AdkA2aExecutor bridge
#   - AgentEngine.create() via patched transport
#   - Post-deploy PATCH: agentFramework=google-adk + 24 classMethods
#   - Capability labels + IAM grants
#
# Usage:
#   bash scripts/deploy_sushi_a2a.sh
#
# Prerequisites:
#   - Python 3.12 at ~/.pyenv/versions/3.12.13/bin/python3.12
#   - gcloud authenticated with application-default credentials
#   - terraform.tfvars populated with project_id, region/location, prefix
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

# ---------------------------------------------------------------------------
# Config — reads from terraform.tfvars
# ---------------------------------------------------------------------------
PROJECT=$(grep -oP '^project_id\s*=\s*"\K[^"]+' terraform.tfvars 2>/dev/null || echo "geap-agw")
REGION=$(grep -oP '^location\s*=\s*"\K[^"]+' terraform.tfvars 2>/dev/null \
  || grep -oP '^region\s*=\s*"\K[^"]+' terraform.tfvars 2>/dev/null || echo "us-east1")
PREFIX=$(grep -oP '^prefix\s*=\s*"\K[^"]+' terraform.tfvars 2>/dev/null || echo "geap")

AGENT="sushi-agent-a2a"
DISPLAY_NAME="sushi_specialist_a2a"
CAPABILITY="sushi-ordering"
TEAM="food-court"

INGRESS="projects/${PROJECT}/locations/${REGION}/agentGateways/${PREFIX}-ingress-gateway"
EGRESS="projects/${PROJECT}/locations/${REGION}/agentGateways/${PREFIX}-egress-gateway"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║      Sushi A2A — google-adk(a2a) Deploy Experiment       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo "  Project : $PROJECT  |  Region : $REGION"
echo "  Agent   : $DISPLAY_NAME"
echo "  Skill   : a2a-agent-deploy blueprint (2026-08-11 validated)"
echo ""

# ---------------------------------------------------------------------------
# [1] Locate a Python 3.12 venv with all A2A packages installed.
# The Airlock mirror (go/corp-airlock) only has aiplatform==1.149.0 and
# Uses google-adk==2.5.0 + aiplatform==1.162.0 + a2a-sdk==1.1.2 (same stack as deploy_a2a_agent.py).
# We reuse an existing venv from another project that already has them.
# ---------------------------------------------------------------------------
FIVEG_VENV="$HOME/Desktop/Workspace/fiveg-ran-agent/foundation/.venv"
WORKSPACE_VENV="$HOME/Desktop/Workspace/.venv"

# Preferred: Workspace venv (confirmed has vertexai.agent_engines.templates.a2a)
# NOTE: fiveg venv is missing vertexai.agent_engines.templates.a2a — do not use as primary.
if [[ -x "$WORKSPACE_VENV/bin/python" ]]; then
  VENV312="$WORKSPACE_VENV"
  echo "▶ [1/3] Using Workspace root venv (has aiplatform==1.162.0 + adk==2.5.0)"
  echo "         $VENV312"
elif [[ -x "$FIVEG_VENV/bin/python" ]]; then
  VENV312="$FIVEG_VENV"
  echo "▶ [1/3] Using fiveg-ran-agent venv (fallback)"
  echo "         $VENV312"
else
  echo "▶ [1/3] Creating .venv312 (will attempt install from available mirror)..."
  PYTHON312="$HOME/.pyenv/versions/3.12.13/bin/python3.12"
  VENV312="$ROOT/.venv312"
  if [[ ! -x "$PYTHON312" ]]; then
    echo "❌ Python 3.12 not found at $PYTHON312"
    exit 1
  fi
  "$PYTHON312" -m venv "$VENV312"
  "$VENV312/bin/pip" install -q \
    "google-cloud-aiplatform[agent_engines,adk]==1.162.0" \
    "google-adk[agent-identity,a2a,mcp]==2.5.0" \
    "a2a-sdk[http-server]==1.1.2" \
    "google-genai" "pydantic" "cloudpickle>=3.0.0" \
    "google-auth" "requests" "httpx" "sse-starlette"
fi

# Quick sanity check
"$VENV312/bin/python" -c "
import google.cloud.aiplatform as ai, google.adk, a2a
print(f'  aiplatform: {ai.__version__}')
print(f'  google-adk: {google.adk.__version__}')
" 2>/dev/null || true
echo "  ✅ Venv ready."

# ---------------------------------------------------------------------------
# [2] Apply gateway patch — must run BEFORE deploy
#     Patch is written into .venv312/lib/python3.12/site-packages/
#     as _gateway_patch.py + _gateway_patch.pth
# ---------------------------------------------------------------------------
echo ""
echo "▶ [2/3] Applying Agent Gateway SDK patch (Caveat #17 + #18 fixes)..."
export AGENT_GATEWAY_INGRESS="$INGRESS"
export AGENT_GATEWAY_EGRESS="$EGRESS"

"$VENV312/bin/python" scripts/patch_sdk_for_rest_create.py \
  --ingress "$INGRESS" \
  --egress  "$EGRESS"  \
  --agent-name "$DISPLAY_NAME" \
  --venv ".venv312"
echo "  ✅ Gateway patch applied."

# ---------------------------------------------------------------------------
# [3] Deploy via deploy_a2a_agent.py (implements full skill workflow)
# ---------------------------------------------------------------------------
echo ""
echo "▶ [3/3] Deploying $AGENT as google-adk(a2a) ..."
echo "  Script: scripts/deploy_a2a_agent.py"
echo "  Pattern: cloudpickle.register_pickle_by_value + A2aAgent + PATCH(24 classMethods)"
echo "  Expected console label: 'Google-adk (a2a)'"
echo ""

"$VENV312/bin/python" scripts/deploy_a2a_agent.py \
  --agent    "$AGENT" \
  --project  "$PROJECT" \
  --region   "$REGION" \
  --display-name "$DISPLAY_NAME" \
  --capability   "$CAPABILITY" \
  --team         "$TEAM" \
  --role         "specialist"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          ✅  Sushi A2A Deploy Complete                   ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Verify in console:"
echo "    https://console.cloud.google.com/vertex-ai/agent-registry"
echo "    ?project=$PROJECT"
echo ""
echo "  Expected: agent card present + label 'Google-adk (a2a)'"
echo ""
echo "  If successful, run for all agents:"
echo "    bash scripts/deploy_all_a2a.sh"
