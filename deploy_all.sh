#!/usr/bin/env bash
# =============================================================================
# deploy_all.sh
# End-to-end deployment pipeline for Agent Gateway.
#
# Phases:
#   1. Infrastructure & Security (Terraform)
#   2. Agent Deployment (adk deploy via deploy_chat_agent.sh)
#   3. SGP Policy Registration (create_sgp_policy.sh)
#   4. Guardrail Smoke Tests (run_guardrail_tests.py)
#
# Usage:
#   bash deploy_all.sh
#
# Prerequisites:
#   - terraform.tfvars populated (project_id, prefix, agent_name, etc.)
#   - gcloud authenticated: gcloud auth application-default login
#   - terraform, python3, gcloud in PATH
# =============================================================================

set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$DIR"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║         Agent Gateway — End-to-End Deployment           ║"
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

# Validate terraform.tfvars exists and has required fields
if [[ ! -f "terraform.tfvars" ]]; then
    echo "❌ terraform.tfvars not found. Copy terraform.tfvars.example and fill in your values."
    exit 1
fi
for field in project_id region prefix agent_name; do
    if ! grep -qP "^${field}\s*=" terraform.tfvars 2>/dev/null; then
        echo "❌ terraform.tfvars is missing required field: $field"
        exit 1
    fi
done

# Read shared values once — all scripts use these
PROJECT_ID=$(grep -oP '^project_id\s*=\s*"\K[^"]+' terraform.tfvars)
REGION=$(grep -oP '^location\s*=\s*"\K[^"]+' terraform.tfvars 2>/dev/null \
  || grep -oP '^region\s*=\s*"\K[^"]+' terraform.tfvars)
PREFIX=$(grep -oP '^prefix\s*=\s*"\K[^"]+' terraform.tfvars 2>/dev/null || echo "")
AGENT_NAME=$(grep -oP '^agent_name\s*=\s*"\K[^"]+' terraform.tfvars 2>/dev/null || echo "my-agent")

echo "✅ Pre-flight passed."
echo "   Project : $PROJECT_ID  |  Region : $REGION  |  Agent : $AGENT_NAME"
echo ""

# =============================================================================
# Phase 1: Infrastructure & Security (Terraform)
# =============================================================================
echo "▶ [1/4] Applying Infrastructure and Security (Terraform)..."
echo "  Note: Terraform retries up to 12× for Org Policy propagation delays."
echo ""

mkdir -p scripts
terraform init -upgrade -input=false

MAX_RETRIES=12
RETRY_COUNT=0
TF_SUCCESS=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  echo "  terraform apply (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)..."
  if terraform apply -auto-approve -input=false; then
    TF_SUCCESS=true
    break
  fi
  echo "  ⚠️  Apply failed — usually transient 409 during Org Policy propagation."
  echo "  Retrying in 30s..."
  sleep 30
  RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ "$TF_SUCCESS" = false ]; then
  echo "❌ Terraform apply failed after $MAX_RETRIES attempts."
  echo "   Check logs above for non-transient errors."
  exit 1
fi

echo ""
echo "✅ Phase 1 complete — infrastructure deployed."
echo ""

# =============================================================================
# Phase 2: Agent Deployment (adk deploy via deploy_chat_agent.sh)
# =============================================================================
echo "▶ [2/4] Deploying Reasoning Engine Agent..."
echo ""

AGENT_SCRIPT="$DIR/scripts/deploy_chat_agent.sh"
if [[ ! -f "$AGENT_SCRIPT" ]]; then
    echo "❌ $AGENT_SCRIPT not found."
    exit 1
fi

bash "$AGENT_SCRIPT"

echo ""
echo "✅ Phase 2 complete — agent deployed and ACTIVE."
echo ""

# =============================================================================
# Phase 3: SGP NLC Policy Registration
# =============================================================================
echo "▶ [3/4] Creating SGP NLC Policy for agent..."
echo "  The Agent Registry entry is auto-created by Vertex AI when the RE"
echo "  becomes ACTIVE. This step creates the semantic governance policy"
echo "  that controls what this agent is allowed to do via the gateway."
echo ""

SGP_SCRIPT="$DIR/scripts/create_sgp_policy.sh"
if [[ ! -f "$SGP_SCRIPT" ]]; then
    echo "❌ $SGP_SCRIPT not found."
    exit 1
fi

# Retry up to 3× — Agent Registry entry may take 30-60s after RE becomes ACTIVE
SGP_SUCCESS=false
for attempt in 1 2 3; do
  if bash "$SGP_SCRIPT"; then
    SGP_SUCCESS=true
    break
  fi
  if [ $attempt -lt 3 ]; then
    echo "  ⚠️  SGP policy creation failed (attempt $attempt/3) — Agent Registry may"
    echo "  not be ready yet. Waiting 60s before retry..."
    sleep 60
  fi
done

if [ "$SGP_SUCCESS" = false ]; then
  echo "  ⚠️  SGP policy creation failed after 3 attempts."
  echo "  The agent is deployed and operational but WITHOUT semantic governance."
  echo "  To create the policy manually after the RE stabilises:"
  echo "    bash scripts/create_sgp_policy.sh"
  echo ""
  echo "  Deployment continues — guardrail tests will run without SGP enforcement."
fi

echo ""

# =============================================================================
# Phase 4: Guardrail Smoke Tests
# =============================================================================
echo "▶ [4/4] Running Guardrail Smoke Tests..."
echo "  8 tests across 4 layers:"
echo "    • Prompt Injection ×2  — Model Armor PI filter → expect HTTP 403"
echo "    • URL Egress Block ×2  — SGP allowlist enforcement → blocked"
echo "    • DLP Redact ×2        — Model Armor SDP → SSN/CC deidentified"
echo "    • Legitimate Allow ×2  — Clean prompt through GlobalGemini → real response"
echo ""

TEST_SCRIPT="$DIR/test-agent/run_guardrail_tests.py"
if [[ ! -f "$TEST_SCRIPT" ]]; then
    echo "⚠️  $TEST_SCRIPT not found — skipping guardrail tests."
else
    PYTHON_BIN="$DIR/.venv/bin/python"
    if [[ ! -x "$PYTHON_BIN" ]]; then
        PYTHON_BIN="python3"
    fi

    echo "  Python  : $PYTHON_BIN"
    echo "  Project : $PROJECT_ID  |  Region: $REGION  |  Agent: $AGENT_NAME"
    echo "  Results : $DIR/test-agent/results/"
    echo ""

    if "$PYTHON_BIN" "$TEST_SCRIPT" \
            --project "$PROJECT_ID" \
            --location "$REGION" \
            --agent-name "$AGENT_NAME" \
            --output-dir "$DIR/test-agent/results"; then
        echo "✅ All guardrail tests passed."
    else
        echo "⚠️  One or more guardrail tests did not pass. See $DIR/test-agent/results/"
        echo ""
        echo "  Common root causes:"
        echo "  [PI]    HTTP 403 expected. Check: Model Armor template 'security-high'"
        echo "          pi_and_jailbreak_filter_settings must be ENABLED."
        echo "  [DLP]   Model Armor SDP uses deidentify (not block) — expect HTTP 200"
        echo "          with SSN/CC REDACTED, not HTTP 400."
        echo "  [URL]   Gateway is deny-by-default. Blocked hosts must NOT be in"
        echo "          allowed_egress_hosts (terraform.tfvars). Expect timeout ~15s."
        echo "  [ALLOW] Ensure 'aiplatform.googleapis.com' is in allowed_egress_hosts."
        echo ""
        echo "  Deployment complete — tests are advisory, not blocking."
    fi
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              ✅  Deployment Complete                     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Project : $PROJECT_ID"
echo "  Agent   : $AGENT_NAME"
echo "  Region  : $REGION"
echo ""
echo "  Next steps:"
echo "  • Verify SGP policy:"
echo "    gcloud beta ai semantic-governance-policies list \\"
echo "      --location=$REGION --project=$PROJECT_ID"
echo "  • Send a test query:"
echo "    bash test-agent/send_query.sh"
echo "  • View dashboards in Cloud Monitoring for project: $PROJECT_ID"
echo ""
