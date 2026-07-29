#!/usr/bin/env bash
set -euo pipefail

# Foundation root = the folder containing this scripts/ directory.
# Use --agent-path to deploy an agent that lives outside the foundation
# (e.g. in a parent repo when the foundation is used as a git submodule).
SCRIPT_DIR="$( cd "$( dirname "$0" )" &> /dev/null && pwd )"
SCRIPT_WORKSPACE="$( dirname "$SCRIPT_DIR" )"  # = foundation root
CALLER_CWD="$(pwd)"  # saved before cd — used to resolve relative --agent-path

# ── Argument parsing ─────────────────────────────────────────────
AGENT_PATH_ARG=""
AGENT_NAME_ARG=""        # overrides terraform.tfvars agent_name
AGENT_DESC_ARG=""        # overrides terraform.tfvars agent_description
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-path)
      AGENT_PATH_ARG="$2"; shift 2 ;;
    --agent-name)
      AGENT_NAME_ARG="$2"; shift 2 ;;
    --agent-description)
      AGENT_DESC_ARG="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--agent-path PATH] [--agent-name NAME] [--agent-description DESC]"
      echo ""
      echo "  --agent-path         Directory containing agent.py + requirements.txt."
      echo "                       Accepts absolute or relative paths (resolved from your"
      echo "                       current working directory, not the foundation root)."
      echo "                       Default: \$FOUNDATION/agents/chat-agent/"
      echo ""
      echo "  --agent-name         Override the agent display name (default: agent_name"
      echo "                       from terraform.tfvars). Use this to deploy multiple"
      echo "                       agents to the same project without editing terraform.tfvars."
      echo "                       Must be a valid Python identifier (underscores, not hyphens)."
      echo ""
      echo "  --agent-description  Override the agent description (default: agent_description"
      echo "                       from terraform.tfvars)."
      echo ""
      echo "  Examples:"
      echo "    # Single agent (uses terraform.tfvars agent_name)"
      echo "    bash foundation/scripts/deploy_chat_agent.sh --agent-path ./src/my-agent"
      echo ""
      echo "    # Multiple agents — same gateway, different names"
      echo "    bash foundation/scripts/deploy_chat_agent.sh --agent-path ./src/agent-1 --agent-name agent_one --agent-description 'Agent one'"
      echo "    bash foundation/scripts/deploy_chat_agent.sh --agent-path ./src/agent-2 --agent-name agent_two --agent-description 'Agent two'"
      exit 0 ;;
    *) echo "❌ Unknown argument: $1  (run with --help for usage)"; exit 1 ;;
  esac
done

# All paths below are relative to SCRIPT_WORKSPACE (the foundation root).
cd "$SCRIPT_WORKSPACE"

# ── Read all values from terraform.tfvars ───────────────────────────────────
# Single source of truth — no hardcoded project/region/prefix/agent values.
TFVARS="$SCRIPT_WORKSPACE/terraform.tfvars"
if [[ ! -f "$TFVARS" ]]; then
  echo "❌ terraform.tfvars not found at $TFVARS — cannot deploy."
  exit 1
fi
PROJECT_ID=$(grep -oP '^project_id\s*=\s*"\K[^"]+' "$TFVARS")
REGION=$(grep -oP '^location\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null \
  || grep -oP '^region\s*=\s*"\K[^"]+' "$TFVARS")
PREFIX=$(grep -oP '^prefix\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null || echo "")
AGENT_NAME=$(grep -oP '^agent_name\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null || echo "my_agent")
AGENT_DESC=$(grep -oP '^agent_description\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null \
  || echo "A foundational agent demonstrating Agent Gateway security integrations.")

# CLI flags override terraform.tfvars values — allows multi-agent deploys
# to the same project without editing terraform.tfvars.
[[ -n "$AGENT_NAME_ARG" ]] && AGENT_NAME="$AGENT_NAME_ARG"
[[ -n "$AGENT_DESC_ARG" ]] && AGENT_DESC="$AGENT_DESC_ARG"

# Validate agent_name: must be a Python identifier (underscores, not hyphens)
if [[ ! "$AGENT_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
  echo "❌ agent_name '$AGENT_NAME' is not a valid Python identifier."
  echo "   Use underscores, not hyphens. Example: agent_two (not agent-two)"
  exit 1
fi

if [[ -z "$PROJECT_ID" || -z "$REGION" ]]; then
  echo "❌ terraform.tfvars is missing project_id or location/region — cannot deploy."
  exit 1
fi


# Derive gateway resource names from prefix (matches Terraform naming convention)
INGRESS_GW="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${PREFIX}-ingress-gateway"
EGRESS_GW="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${PREFIX}-egress-gateway"

# Export for child processes and Python heredocs (read via os.environ)
export GCP_PROJECT_ID="$PROJECT_ID"
export GOOGLE_CLOUD_LOCATION="$REGION"
export AGENT_DISPLAY_NAME="$AGENT_NAME"
export AGENT_GATEWAY_INGRESS="$INGRESS_GW"
export AGENT_GATEWAY_EGRESS="$EGRESS_GW"

echo "▶ Configuration loaded from terraform.tfvars:"
echo "  project_id  : $PROJECT_ID"
echo "  region      : $REGION"
echo "  prefix      : $PREFIX"
echo "  agent_name  : $AGENT_NAME"
echo "  ingress_gw  : $INGRESS_GW"
echo ""

# ── Resolve agent source directory ─────────────────────────────────────────
# Absolute --agent-path used as-is; relative resolved from CALLER_CWD so that
# `bash foundation/scripts/deploy_chat_agent.sh --agent-path ./src/my-agent`
# works correctly when run from the parent repo root.
if [[ -n "$AGENT_PATH_ARG" ]]; then
  if [[ "$AGENT_PATH_ARG" = /* ]]; then
    AGENT_SOURCE_DIR="$AGENT_PATH_ARG"
  else
    AGENT_SOURCE_DIR="$(cd "$CALLER_CWD/$AGENT_PATH_ARG" 2>/dev/null && pwd)" \
      || { echo "❌ --agent-path not found: $CALLER_CWD/$AGENT_PATH_ARG"; exit 1; }
  fi
else
  AGENT_SOURCE_DIR="$SCRIPT_WORKSPACE/agents/chat-agent"
fi
export AGENT_SOURCE_DIR  # exported so Python <<'PYEOF' heredocs read it via os.environ

if [[ ! -f "$AGENT_SOURCE_DIR/agent.py" ]]; then
  echo "❌ agent.py not found at: $AGENT_SOURCE_DIR/agent.py"
  echo "   Check --agent-path, or ensure agents/chat-agent/agent.py exists."
  exit 1
fi

echo "  agent_source  : $AGENT_SOURCE_DIR"
echo ""

echo "Checking if .venv exists..."
if [[ ! -x ".venv/bin/python" ]]; then
    python3 -m venv .venv
fi

# ---------------------------------------------------------------------------
# PRE-FLIGHT: Validate that the agent's requirements.txt has pinned
# versions. Unpinned packages in the RE container install LATEST, which may:
#   - Change the Agent Pydantic model → ValidationError on startup
#   - Change internal transport → .pth patch interceptors don't fire
# See KNOWN_ISSUES.md #008 for full root cause.
# ---------------------------------------------------------------------------
echo "Pre-flight: Checking requirements.txt version pins..."
REQS_FILE="$AGENT_SOURCE_DIR/requirements.txt"
PIN_ERRORS=0
for pkg in "google-adk" "google-cloud-aiplatform"; do
    if ! grep -qE "^${pkg}[^=!<>]*(==|>=.*,<)" "$REQS_FILE" 2>/dev/null; then
        echo "  ❌ '${pkg}' in $REQS_FILE is UNPINNED — must use == or bounded >= ... , <"
        PIN_ERRORS=${PIN_ERRORS:-0}
        PIN_ERRORS=$((PIN_ERRORS + 1))
    fi
done
if [ "${PIN_ERRORS:-0}" -gt 0 ]; then
    echo ""
    echo "  FATAL: Unpinned dependencies will cause container startup failure."
    echo "  The RE container runs 'pip install -r requirements.txt' at startup."
    echo "  See KNOWN_ISSUES.md #008 for root cause and fix."
    exit 1
fi
echo "  ✅ Version pins OK."

echo "Installing ADK and requirements (pinned to known-working versions)..."
# IMPORTANT: Do NOT unpin these versions. The .pth monkey-patch that injects
# agentGatewayConfig was written for google-cloud-aiplatform==1.149.0.
# Newer versions changed the internal transport (agentplatform.Client) and the
# patch interceptors (AuthorizedSession + httpx + GAPIC class) no longer fire,
# causing ALL 4 org policy constraints to be violated (400 FAILED_PRECONDITION).
# See KNOWN_ISSUES.md #008.
.venv/bin/pip install -i https://pypi.org/simple -q --no-deps "google-adk==1.31.1"
.venv/bin/pip install -i https://pypi.org/simple -q "google-cloud-aiplatform[adk,agent_engines]==1.149.0" "requests" "pydantic"

# AGENT_GATEWAY_INGRESS/EGRESS already exported from terraform.tfvars block at top of script

# ---------------------------------------------------------------------------
# PRE-DEPLOY CLEANUP: Delete any existing Reasoning Engines with the same
# display name. adk deploy agent_engine always creates a NEW RE — it has no
# upsert / update path. Without this step, each deploy adds a duplicate instance.
# force=true deletes child session resources automatically.
# ---------------------------------------------------------------------------
echo "Checking for existing Reasoning Engines named '$AGENT_NAME'..."
.venv/bin/python - <<'PYEOF'
import os, sys, time
import google.auth
import google.auth.transport.requests
import requests as http

PROJECT  = os.environ.get("GCP_PROJECT_ID", "")
LOCATION = os.environ.get("GOOGLE_CLOUD_LOCATION", "")
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
# Inject correct project into the agent's .env so GatewayAgent uses the
# right project inside the Reasoning Engine runtime.
# The adk CLI bundles .env files from the agent directory into the deployment.
# ---------------------------------------------------------------------------
echo "Writing $AGENT_SOURCE_DIR/.env with project env vars..."
# Note: unquoted heredoc (ENVEOF not 'ENVEOF') so bash expands $PROJECT_ID etc.
cat > "$AGENT_SOURCE_DIR/.env" << ENVEOF
GCP_PROJECT_ID=${PROJECT_ID}
GOOGLE_CLOUD_PROJECT=${PROJECT_ID}
GOOGLE_CLOUD_LOCATION=${REGION}
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
echo "  GCP_PROJECT_ID=${PROJECT_ID}"
echo "  AGENT_GATEWAY_INGRESS=${INGRESS_GW}"
echo "  OTEL 3-layer fix vars written"

echo "Applying ADK monkey-patch for org policy bypass..."
.venv/bin/python scripts/patch_sdk_for_rest_create.py --ingress "$AGENT_GATEWAY_INGRESS" --egress "$AGENT_GATEWAY_EGRESS" --agent-name "$AGENT_NAME" --venv .venv


# ---------------------------------------------------------------------------
# COMPLIANCE CHECK: agent.py must import GatewayAgent from the gateway_agent SDK.
# Fails the build immediately if bare Agent() is used — ensures telemetry,
# GlobalGemini routing, and query() registration are always enforced.
# ---------------------------------------------------------------------------
echo "Running GatewayAgent compliance check..."
if ! .venv/bin/python - <<'PYEOF'
import ast, os, sys
_agent_src = os.environ.get("AGENT_SOURCE_DIR", "agents/chat-agent")
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
# SDK BUNDLE: Copy lib/gateway_agent/ into the agent directory so adk deploy
# includes it in the Reasoning Engine deployment package.
# The source of truth stays in lib/gateway_agent/ inside the foundation.
# This copy is temporary — cleaned up immediately after deploy.
# ---------------------------------------------------------------------------
SDK_SRC="lib/gateway_agent"
SDK_DST="$AGENT_SOURCE_DIR/gateway_agent"

echo "Applying contextSpec injection patch (prevents platform memoryBankConfig auto-injection)..."
.venv/bin/python scripts/patch_add_context_spec.py --venv .venv
if [[ -d "$SDK_SRC" ]]; then
    echo "Bundling GatewayAgent SDK into $AGENT_SOURCE_DIR/ for deployment..."
    cp -r "$SDK_SRC" "$SDK_DST"
    echo "  ✅ Copied lib/gateway_agent → $AGENT_SOURCE_DIR/gateway_agent"
else
    echo "  ❌ SDK source not found at $SDK_SRC — cannot bundle GatewayAgent"
    exit 1
fi

echo "Deploying ADK Agent natively..."
DEPLOY_TMPLOG=$(mktemp /tmp/adk_deploy_XXXXXX.log)
.venv/bin/adk deploy agent_engine \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --display_name="$AGENT_NAME" \
  --description="${AGENT_DESC}" \
  "$AGENT_SOURCE_DIR" 2>&1 | tee "$DEPLOY_TMPLOG"

DEPLOY_EXIT=${PIPESTATUS[0]}

# ---------------------------------------------------------------------------
# SDK CLEANUP: Remove the temporary SDK copy from the agent directory.
# ---------------------------------------------------------------------------
echo "Cleaning up bundled SDK copy..."
rm -rf "$SDK_DST"
echo "  ✅ Removed $AGENT_SOURCE_DIR/gateway_agent (cleaned up after deploy)"

if [ "$DEPLOY_EXIT" -ne 0 ]; then
  echo "  ❌ adk deploy failed with exit code $DEPLOY_EXIT — stopping."
  exit "$DEPLOY_EXIT"
fi

# ---------------------------------------------------------------------------
# Post-deploy: strip server-injected contextSpec.memoryBankConfig.
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

  # Wait for RE to become ACTIVE after contextSpec strip (up to 150s)
  echo "  Waiting for RE $NEW_RE_ID to become ACTIVE..."
  RE_STATE="UNKNOWN"
  for i in $(seq 1 30); do
    sleep 5
    RE_STATE=$(
      curl -s -H "Authorization: Bearer $PATCH_TOKEN" \
        "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/$NEW_RE_ID" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state','UNKNOWN'))" 2>/dev/null
    )
    echo "  [attempt $i/30] state=$RE_STATE"
    if [ "$RE_STATE" = "ACTIVE" ]; then
      echo "  ✅ RE is ACTIVE — contextSpec stripped successfully."
      break
    fi
  done
  if [ "$RE_STATE" != "ACTIVE" ]; then
    echo "  ⚠️  RE did not reach ACTIVE in 150s — final state: $RE_STATE"
    echo "  ⚠️  Check Cloud Logging for startup errors."
  fi
else
  echo "  ⚠️  Could not locate RE — contextSpec PATCH skipped. Check deploy logs."
fi

echo "Verifying — listing deployed Reasoning Engines..."
.venv/bin/python - <<'PYEOF'
import os
import google.auth, google.auth.transport.requests, requests as http
PROJECT  = os.environ.get("GCP_PROJECT_ID", "")
LOCATION = os.environ.get("GOOGLE_CLOUD_LOCATION", "")
NAME     = os.environ.get("AGENT_DISPLAY_NAME", "")
creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
creds.refresh(google.auth.transport.requests.Request())
base = f"https://{LOCATION}-aiplatform.googleapis.com/v1beta1/projects/{PROJECT}/locations/{LOCATION}/reasoningEngines"
engines = http.get(base, headers={"Authorization": f"Bearer {creds.token}"}).json().get("reasoningEngines", [])
matches = [e for e in engines if e.get("displayName") == NAME]
if len(matches) == 1:
    print(f"  ✅ Exactly 1 engine deployed: {matches[0]['name']}")
elif len(matches) == 0:
    print(f"  ❌ No engine found with name '{NAME}' — deploy may have failed.")
else:
    print(f"  ⚠️  {len(matches)} engines found with name '{NAME}' — unexpected duplicate!")
    for m in matches:
        print(f"     {m['name']}  (created: {m.get('createTime','?')})")
PYEOF
