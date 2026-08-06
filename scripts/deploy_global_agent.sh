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
# deploy_global_agent.sh — Deploy an ADK agent using the Vertex AI GLOBAL
# endpoint (aiplatform.googleapis.com) with gemini-3.5-flash (or any Gemini
# 3.x model not yet available at regional endpoints).
#
# KEY DIFFERENCE from deploy_chat_agent.sh:
#   chat-agent:    GOOGLE_CLOUD_LOCATION=us-east1  → us-east1-aiplatform.googleapis.com
#   global-agent:  GOOGLE_CLOUD_LOCATION=global    → aiplatform.googleapis.com
#
# The RE itself is still deployed in the real region (from terraform.tfvars).
# Only the model inference call uses the global endpoint.
# GCP_REGION is set separately so non-model calls (sessions, registry) still
# use the real region and don't break.
#
# Confirmed working pattern from:
#   cloud-networking-solutions/demos/agent-gateway (Google reference demo)
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "$0" )" &> /dev/null && pwd )"
SCRIPT_WORKSPACE="$( dirname "$SCRIPT_DIR" )"
CALLER_CWD="$(pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────
AGENT_PATH_ARG=""
AGENT_NAME_ARG=""
AGENT_DESC_ARG=""
AGENT_MODEL_ARG=""     # override model (default: gemini-3.5-flash)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-path)        AGENT_PATH_ARG="$2"; shift 2 ;;
    --agent-name)        AGENT_NAME_ARG="$2"; shift 2 ;;
    --agent-description) AGENT_DESC_ARG="$2"; shift 2 ;;
    --model)             AGENT_MODEL_ARG="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--agent-path PATH] [--agent-name NAME] [--agent-description DESC] [--model MODEL]"
      echo ""
      echo "  --agent-path         Directory containing agent.py + requirements.txt."
      echo "                       Default: \$FOUNDATION/agents/global-agent/"
      echo ""
      echo "  --agent-name         Override display name (default: agent_name from terraform.tfvars)."
      echo "                       Must be a valid Python identifier (underscores, not hyphens)."
      echo ""
      echo "  --agent-description  Override agent description."
      echo ""
      echo "  --model              Gemini model to use (default: gemini-3.5-flash)."
      echo "                       Any Gemini 3.x model available on the global endpoint."
      echo ""
      echo "  Examples:"
      echo "    # Deploy the built-in global-agent example"
      echo "    bash foundation/scripts/deploy_global_agent.sh"
      echo ""
      echo "    # Deploy your own agent using the global endpoint"
      echo "    bash foundation/scripts/deploy_global_agent.sh --agent-path ./src/my-agent --agent-name my_agent"
      echo ""
      echo "    # Use a different Gemini 3.x model"
      echo "    bash foundation/scripts/deploy_global_agent.sh --model gemini-3.1-flash-lite"
      exit 0 ;;
    *) echo "❌ Unknown argument: $1  (run with --help for usage)"; exit 1 ;;
  esac
done

cd "$SCRIPT_WORKSPACE"

# ── Read all values from terraform.tfvars ────────────────────────────────
TFVARS="$SCRIPT_WORKSPACE/terraform.tfvars"
if [[ ! -f "$TFVARS" ]]; then
  echo "❌ terraform.tfvars not found at $TFVARS — cannot deploy."
  exit 1
fi
PROJECT_ID=$(grep -oP '^project_id\s*=\s*"\K[^"]+' "$TFVARS")
REGION=$(grep -oP '^location\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null \
  || grep -oP '^region\s*=\s*"\K[^"]+' "$TFVARS")
PREFIX=$(grep -oP '^prefix\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null || echo "")
AGENT_NAME=$(grep -oP '^agent_name\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null || echo "global_agent")
AGENT_DESC=$(grep -oP '^agent_description\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null \
  || echo "A foundational agent demonstrating the Vertex AI global endpoint with Gemini 3.5 Flash behind Agent Gateway.")
AGENT_MODEL="gemini-3.5-flash"

# CLI flags override terraform.tfvars values
[[ -n "$AGENT_NAME_ARG"  ]] && AGENT_NAME="$AGENT_NAME_ARG"
[[ -n "$AGENT_DESC_ARG"  ]] && AGENT_DESC="$AGENT_DESC_ARG"
[[ -n "$AGENT_MODEL_ARG" ]] && AGENT_MODEL="$AGENT_MODEL_ARG"

# Validate agent_name: must be a Python identifier
if [[ ! "$AGENT_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
  echo "❌ agent_name '$AGENT_NAME' is not a valid Python identifier."
  echo "   Use underscores, not hyphens. Example: global_agent (not global-agent)"
  exit 1
fi

if [[ -z "$PROJECT_ID" || -z "$REGION" ]]; then
  echo "❌ terraform.tfvars is missing project_id or location/region — cannot deploy."
  exit 1
fi

INGRESS_GW="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${PREFIX}-ingress-gateway"
EGRESS_GW="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${PREFIX}-egress-gateway"

# ---------------------------------------------------------------------------
# CRITICAL: Two-env-var pattern for global endpoint
#
#   GOOGLE_CLOUD_LOCATION=global   → model inference → aiplatform.googleapis.com
#   GCP_REGION=$REGION             → sessions, registry, OTEL → us-east1-*
#
# DO NOT set GOOGLE_CLOUD_LOCATION=$REGION here — that would route to the
# regional endpoint and gemini-3.5-flash would return 404 model-not-found.
# ---------------------------------------------------------------------------
export GCP_PROJECT_ID="$PROJECT_ID"
export GCP_REGION="$REGION"                   # real region for non-model calls
export GOOGLE_CLOUD_LOCATION="global"         # model endpoint: aiplatform.googleapis.com
export AGENT_DISPLAY_NAME="$AGENT_NAME"
export AGENT_GATEWAY_INGRESS="$INGRESS_GW"
export AGENT_GATEWAY_EGRESS="$EGRESS_GW"
export AGENT_MODEL="$AGENT_MODEL"

echo "▶ Configuration loaded from terraform.tfvars:"
echo "  project_id      : $PROJECT_ID"
echo "  region (deploy) : $REGION"
echo "  model endpoint  : global  (→ aiplatform.googleapis.com)"
echo "  model           : $AGENT_MODEL"
echo "  prefix          : $PREFIX"
echo "  agent_name      : $AGENT_NAME"
echo "  ingress_gw      : $INGRESS_GW"
echo ""

# ── Resolve agent source directory ───────────────────────────────────────
if [[ -n "$AGENT_PATH_ARG" ]]; then
  if [[ "$AGENT_PATH_ARG" = /* ]]; then
    AGENT_SOURCE_DIR="$AGENT_PATH_ARG"
  else
    AGENT_SOURCE_DIR="$(cd "$CALLER_CWD/$AGENT_PATH_ARG" 2>/dev/null && pwd)" \
      || { echo "❌ --agent-path not found: $CALLER_CWD/$AGENT_PATH_ARG"; exit 1; }
  fi
else
  AGENT_SOURCE_DIR="$SCRIPT_WORKSPACE/agents/global-agent"
fi
export AGENT_SOURCE_DIR

if [[ ! -f "$AGENT_SOURCE_DIR/agent.py" ]]; then
  echo "❌ agent.py not found at: $AGENT_SOURCE_DIR/agent.py"
  echo "   Check --agent-path, or ensure agents/global-agent/agent.py exists."
  exit 1
fi

echo "  agent_source    : $AGENT_SOURCE_DIR"
echo ""

echo "Checking if .venv exists..."
if [[ ! -x ".venv/bin/python" ]]; then
    python3 -m venv .venv
fi

# ---------------------------------------------------------------------------
# PRE-FLIGHT: Validate requirements.txt version pins
# ---------------------------------------------------------------------------
echo "Pre-flight: Checking requirements.txt version pins..."
REQS_FILE="$AGENT_SOURCE_DIR/requirements.txt"
PIN_ERRORS=0
for pkg in "google-adk" "google-cloud-aiplatform"; do
    if ! grep -qE "^${pkg}[^=!<>]*(==|>=.*,<)" "$REQS_FILE" 2>/dev/null; then
        echo "  ❌ '${pkg}' in $REQS_FILE is UNPINNED — must use == or bounded >= ... , <"
        PIN_ERRORS=$((PIN_ERRORS + 1))
    fi
done
if [ "${PIN_ERRORS:-0}" -gt 0 ]; then
    echo ""
    echo "  FATAL: Unpinned dependencies will cause container startup failure."
    echo "  See KNOWN_ISSUES.md #008 for root cause and fix."
    exit 1
fi
echo "  ✅ Version pins OK."

echo "Installing ADK and requirements (pinned to known-working versions)..."
.venv/bin/pip install -i https://pypi.org/simple -q --no-deps "google-adk==1.31.1"
.venv/bin/pip install -i https://pypi.org/simple -q "google-cloud-aiplatform[adk,agent_engines]==1.149.0" "requests" "pydantic"

# ---------------------------------------------------------------------------
# PRE-DEPLOY CLEANUP: Delete existing REs with same display name.
# Uses GCP_REGION (real region) for RE control-plane API calls,
# NOT GOOGLE_CLOUD_LOCATION (which is "global" here).
# ---------------------------------------------------------------------------
echo "Checking for existing Reasoning Engines named '$AGENT_NAME'..."
.venv/bin/python - <<'PYEOF'
import os, sys, time
import google.auth
import google.auth.transport.requests
import requests as http

PROJECT  = os.environ.get("GCP_PROJECT_ID", "")
# Use GCP_REGION (real region) for RE API — GOOGLE_CLOUD_LOCATION is "global"
# and the RE control plane does not accept "global" as a location.
LOCATION = os.environ.get("GCP_REGION", "")
NAME     = os.environ.get("AGENT_DISPLAY_NAME", "")

creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
creds.refresh(google.auth.transport.requests.Request())
token = creds.token

base = f"https://{LOCATION}-aiplatform.googleapis.com/v1beta1/projects/{PROJECT}/locations/{LOCATION}/reasoningEngines"
resp = http.get(base, headers={"Authorization": f"Bearer {token}"})
resp.raise_for_status()
engines = resp.json().get("reasoningEngines", [])
matches = [e for e in engines if e.get("displayName") == NAME]

if not matches:
    print(f"  No existing engines named '{NAME}' — clean slate.")
    sys.exit(0)

for engine in matches:
    resource_name = engine["name"]
    created = engine.get("createTime", "unknown")
    print(f"  Deleting: {resource_name}  (created: {created})")
    del_resp = http.delete(
        f"https://{LOCATION}-aiplatform.googleapis.com/v1beta1/{resource_name}?force=true",
        headers={"Authorization": f"Bearer {token}"},
    )
    if del_resp.status_code in (200, 204):
        op = del_resp.json()
        if op.get("done"):
            print(f"  ✅ Deleted synchronously.")
        else:
            op_name = op.get("name", "")
            print(f"  ⏳ Delete in progress: {op_name}. Waiting up to 90s...")
            for _ in range(18):
                time.sleep(5)
                poll = http.get(
                    f"https://{LOCATION}-aiplatform.googleapis.com/v1beta1/{op_name}",
                    headers={"Authorization": f"Bearer {token}"},
                )
                if poll.json().get("done"):
                    print(f"  ✅ Deleted.")
                    break
            else:
                print(f"  ⚠️  Delete did not complete in 90s — continuing anyway.")
    else:
        print(f"  ⚠️  Delete returned HTTP {del_resp.status_code}: {del_resp.text}")

print("  Cleanup complete.")
PYEOF

# ---------------------------------------------------------------------------
# Write .env — CRITICAL: GOOGLE_CLOUD_LOCATION=global here so the RE container
# routes model inference to the global Vertex AI endpoint.
# GCP_REGION provides the real region for non-model API calls.
# ---------------------------------------------------------------------------
echo "Writing $AGENT_SOURCE_DIR/.env with global endpoint env vars..."
cat > "$AGENT_SOURCE_DIR/.env" << ENVEOF
GCP_PROJECT_ID=${PROJECT_ID}
GOOGLE_CLOUD_PROJECT=${PROJECT_ID}
# GLOBAL ENDPOINT: ADK Gemini reads GOOGLE_CLOUD_LOCATION and constructs the
# model inference URL. "global" → aiplatform.googleapis.com (not regional).
GOOGLE_CLOUD_LOCATION=global
# REAL REGION: used for RE control-plane, session management, and OTEL calls
# that do not accept "global" as a location value.
GCP_REGION=${REGION}
AGENT_MODEL=${AGENT_MODEL}
AGENT_GATEWAY_INGRESS=${INGRESS_GW}
AGENT_GATEWAY_EGRESS=${EGRESS_GW}
# OTEL mTLS FIX (Layer 1): RE containers have mTLS certs — prevents SSL context corruption.
GOOGLE_API_USE_MTLS_ENDPOINT=never
# OTEL TCP-BLOCK FIX (Layer 2): telemetry.googleapis.com not in PSC routing — fail fast.
OTEL_EXPORTER_OTLP_TIMEOUT=2000
OTEL_BSP_EXPORT_TIMEOUT_MILLIS=2000
OTEL_BSP_SCHEDULE_DELAY_MILLIS=15000
# aiohttp SINGLETON FIX (Layer 3): disables mTLS aiohttp path, forces httpx per-loop client.
GOOGLE_API_USE_CLIENT_CERTIFICATE=false
ENVEOF
echo "  GOOGLE_CLOUD_LOCATION=global  (model → aiplatform.googleapis.com)"
echo "  GCP_REGION=${REGION}  (sessions, registry, OTEL)"
echo "  AGENT_MODEL=${AGENT_MODEL}"
echo "  OTEL 3-layer fix vars written"

echo "Applying ADK monkey-patch for org policy bypass..."
.venv/bin/python scripts/patch_sdk_for_rest_create.py \
  --ingress "$AGENT_GATEWAY_INGRESS" \
  --egress "$AGENT_GATEWAY_EGRESS" \
  --agent-name "$AGENT_NAME" \
  --venv .venv

# ---------------------------------------------------------------------------
# COMPLIANCE CHECK: agent.py must import GatewayAgent
# ---------------------------------------------------------------------------
echo "Running GatewayAgent compliance check..."
if ! .venv/bin/python - <<'PYEOF'
import ast, os, sys
_agent_src = os.environ.get("AGENT_SOURCE_DIR", "agents/global-agent")
try:
    tree = ast.parse(open(os.path.join(_agent_src, "agent.py")).read())
except FileNotFoundError:
    print(f"  ❌ agent.py not found at: {_agent_src}/agent.py")
    sys.exit(1)
uses_gateway = any(
    (isinstance(n, ast.ImportFrom) and n.module and "gateway_agent" in n.module)
    or (isinstance(n, ast.Import) and any("gateway_agent" in a.name for a in n.names))
    for n in ast.walk(tree)
)
if not uses_gateway:
    print("  ❌ Gateway Compliance Error: agent.py must import GatewayAgent from the gateway_agent SDK.")
    print("     Replace: from google.adk.agents import Agent")
    print("     With:    from gateway_agent import GatewayAgent")
    sys.exit(1)
print("  ✅ Compliance check passed — GatewayAgent SDK detected.")
PYEOF
then
    exit 1
fi

# ---------------------------------------------------------------------------
# SDK BUNDLE: Copy lib/gateway_agent/ into agent directory
# ---------------------------------------------------------------------------
SDK_SRC="lib/gateway_agent"
SDK_DST="$AGENT_SOURCE_DIR/gateway_agent"

echo "Applying contextSpec injection patch..."
.venv/bin/python scripts/patch_add_context_spec.py --venv .venv

if [[ -d "$SDK_SRC" ]]; then
    echo "Bundling GatewayAgent SDK into $AGENT_SOURCE_DIR/ for deployment..."
    cp -r "$SDK_SRC" "$SDK_DST"
    echo "  ✅ Copied lib/gateway_agent → $AGENT_SOURCE_DIR/gateway_agent"
else
    echo "  ❌ SDK source not found at $SDK_SRC — cannot bundle GatewayAgent"
    exit 1
fi

echo "Deploying ADK Agent (global endpoint)..."
DEPLOY_TMPLOG=$(mktemp /tmp/adk_deploy_XXXXXX.log)
# adk deploy uses $REGION for the RE deployment location (control plane).
# The GOOGLE_CLOUD_LOCATION=global is injected via .env into the container runtime.
.venv/bin/adk deploy agent_engine \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --display_name="$AGENT_NAME" \
  --description="${AGENT_DESC}" \
  "$AGENT_SOURCE_DIR" 2>&1 | tee "$DEPLOY_TMPLOG"

DEPLOY_EXIT=${PIPESTATUS[0]}

# ---------------------------------------------------------------------------
# SDK CLEANUP
# ---------------------------------------------------------------------------
echo "Cleaning up bundled SDK copy..."
rm -rf "$SDK_DST"
echo "  ✅ Removed $AGENT_SOURCE_DIR/gateway_agent (cleaned up after deploy)"

if [ "$DEPLOY_EXIT" -ne 0 ]; then
  echo "  ❌ adk deploy failed with exit code $DEPLOY_EXIT — stopping."
  exit "$DEPLOY_EXIT"
fi

# ---------------------------------------------------------------------------
# Post-deploy: source shared IAM grant helper.
# ---------------------------------------------------------------------------
# shellcheck source=scripts/grant_agent_iam_roles.sh
source "$(dirname "$0")/grant_agent_iam_roles.sh"

# ---------------------------------------------------------------------------
# Post-deploy: strip server-injected contextSpec.memoryBankConfig
# Uses GCP_REGION for RE API calls (not "global")
# ---------------------------------------------------------------------------
echo "Stripping server-injected contextSpec from the new RE..."
PATCH_TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null)

NEW_RE_ID=$(grep -oP 'reasoningEngines/\K[0-9]+' "$DEPLOY_TMPLOG" | tail -1)
rm -f "$DEPLOY_TMPLOG"

if [ -z "$NEW_RE_ID" ]; then
  echo "  RE ID not found in deploy output — falling back to API list..."
  NEW_RE_ID=$(
    curl -s -H "Authorization: Bearer $PATCH_TOKEN" \
      "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines" \
    | python3 -c "
import json,sys
engines = json.load(sys.stdin).get('reasoningEngines', [])
matches = [e for e in engines if e.get('displayName') == '$AGENT_NAME']
if matches:
    latest = sorted(matches, key=lambda e: e.get('createTime',''), reverse=True)[0]
    print(latest['name'].split('/')[-1])
" 2>/dev/null
  )
fi

if [ -n "$NEW_RE_ID" ]; then
  echo "  RE ID: $NEW_RE_ID — patching contextSpec..."
  PATCH_RESULT=$(
    curl -s -X PATCH \
      -H "Authorization: Bearer $PATCH_TOKEN" \
      -H "Content-Type: application/json" \
      "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/$NEW_RE_ID?updateMask=contextSpec" \
      -d '{"contextSpec": null}'
  )
  echo "  PATCH sent — response: $(echo $PATCH_RESULT | head -c 200)"

  echo "  Waiting for RE $NEW_RE_ID to become ACTIVE..."
  RE_STATE="UNKNOWN"
  for i in $(seq 1 60); do
    sleep 5
    RE_STATE=$(
      curl -s -H "Authorization: Bearer $PATCH_TOKEN" \
        "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/$NEW_RE_ID" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state','UNKNOWN'))" 2>/dev/null
    )
    echo "  [attempt $i/60] state=$RE_STATE"
    if [ "$RE_STATE" = "ACTIVE" ]; then
      echo "  ✅ RE is ACTIVE — contextSpec stripped successfully."
      break
    fi
  done
  if [ "$RE_STATE" != "ACTIVE" ]; then
    echo "  ⚠️  RE did not reach ACTIVE in 300s — final state: $RE_STATE"
    echo "  ⚠️  Check Cloud Logging for startup errors."
  fi

  # -------------------------------------------------------------------------
  # Grant 5 required IAM roles to the Agent Identity SA.
  # Runs unconditionally once RE ID is known — idempotent on re-deploy.
  # -------------------------------------------------------------------------
  grant_agent_iam_roles "$PROJECT_ID" "$REGION" "$NEW_RE_ID" "$PATCH_TOKEN"
else
  echo "  ⚠️  Could not locate RE — contextSpec PATCH skipped."
fi

# ---------------------------------------------------------------------------
# Verify deployment
# ---------------------------------------------------------------------------
echo "Verifying — listing deployed Reasoning Engines..."
.venv/bin/python - <<'PYEOF'
import os
import google.auth, google.auth.transport.requests, requests as http
PROJECT  = os.environ.get("GCP_PROJECT_ID", "")
LOCATION = os.environ.get("GCP_REGION", "")   # real region for RE API
NAME     = os.environ.get("AGENT_DISPLAY_NAME", "")
creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
creds.refresh(google.auth.transport.requests.Request())
base = f"https://{LOCATION}-aiplatform.googleapis.com/v1beta1/projects/{PROJECT}/locations/{LOCATION}/reasoningEngines"
engines = http.get(base, headers={"Authorization": f"Bearer {creds.token}"}).json().get("reasoningEngines", [])
matches = [e for e in engines if e.get("displayName") == NAME]
if len(matches) == 1:
    re_id = matches[0]['name'].split('/')[-1]
    print(f"  ✅ Exactly 1 engine deployed: {matches[0]['name']}")
    print(f"")
    print(f"  ── Quick test ──────────────────────────────────────────────────────")
    print(f"  curl -X POST \\")
    print(f"    \"https://{LOCATION}-aiplatform.googleapis.com/v1beta1/projects/{PROJECT}/locations/{LOCATION}/reasoningEngines/{re_id}:streamQuery\" \\")
    print(f"    -H \"Authorization: Bearer $(gcloud auth print-access-token)\" \\")
    print(f"    -H \"Content-Type: application/json\" \\")
    print(f"    -d '{{\"input\":{{\"user_id\":\"test\",\"session_id\":\"s1\",\"message\":\"Hello, which Gemini model are you?\"}}}}'")
elif len(matches) == 0:
    print(f"  ❌ No engine found with name '{NAME}' — deploy may have failed.")
else:
    print(f"  ⚠️  {len(matches)} engines found with name '{NAME}' — unexpected duplicate!")
    for m in matches:
        print(f"     {m['name']}  (created: {m.get('createTime','?')})")
PYEOF
