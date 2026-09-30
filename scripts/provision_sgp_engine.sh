#!/bin/bash

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

# Auto-provisions the SGP Engine and extracts the dynamic pscServiceAttachment.
# Returns a JSON object required by Terraform external data source.
#
# RESILIENCE STRATEGY (three-tier):
#   1. LIVE: Try gcloud describe — returns immediately if engine is ready
#   2. CACHE: If live call fails with PERMISSION_DENIED or transient error,
#             read cached value from terraform.tfstate (safe: attachment is stable)
#   3. WAIT: Only poll if the engine is provisioning (PENDING state) on a fresh project
#
# WHY THIS MATTERS:
#   data.external re-runs on every terraform plan/apply. If the active gcloud account
#   lacks aiplatform.semanticGovernancePolicyEngine.get, the old script would poll for
#   20 minutes before failing — blocking all unrelated resource updates. This version
#   detects permission errors immediately and falls back to the cached tfstate value.

set -uo pipefail

PROJECT_ID="${1:-}"
LOCATION="${2:-}"

if [[ -z "$PROJECT_ID" || -z "$LOCATION" ]]; then
  echo "Usage: $0 <project_id> <location>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFSTATE="$SCRIPT_DIR/../terraform.tfstate"

# ─── Helper: read cached pscServiceAttachment from terraform.tfstate ──────────
get_cached_attachment() {
  if [ ! -f "$TFSTATE" ]; then
    return 1
  fi
  python3 - << PYEOF 2>/dev/null
import json, sys
try:
    with open("$TFSTATE") as f:
        state = json.load(f)
    for res in state.get("resources", []):
        if res.get("type") == "external" and res.get("name") == "sgp_engine":
            for inst in res.get("instances", []):
                psc = inst.get("attributes", {}).get("result", {}).get("psc_service_attachment", "")
                if psc:
                    print(psc)
                    sys.exit(0)
except Exception:
    pass
PYEOF
}

# ─── Step 1: Try to update/provision the SGP engine (async, best-effort) ─────
gcloud beta ai semantic-governance-policy-engine update \
  --location="$LOCATION" \
  --project="$PROJECT_ID" >/dev/null 2>&1 || true

# ─── Step 2: Single live describe attempt — check for PERMISSION_DENIED fast ──
DESCRIBE_OUTPUT=$(gcloud beta ai semantic-governance-policy-engine describe \
  --location="$LOCATION" \
  --project="$PROJECT_ID" \
  --format="json" 2>&1 || true)

# Fast path: check for permission error — no point polling if we lack permission
if echo "$DESCRIBE_OUTPUT" | grep -q "PERMISSION_DENIED\|permission denied\|IAM_PERMISSION_DENIED"; then
  echo "[provision_sgp_engine] PERMISSION_DENIED on describe — falling back to tfstate cache." >&2
  CACHED=$(get_cached_attachment)
  if [ -n "$CACHED" ]; then
    echo "[provision_sgp_engine] Using cached pscServiceAttachment from tfstate." >&2
    jq -n --arg psc "$CACHED" '{"psc_service_attachment":$psc}'
    exit 0
  fi
  echo "[provision_sgp_engine] No cache available. Grant aiplatform.semanticGovernancePolicyEngine.get to the active gcloud account and re-run." >&2
  exit 1
fi

# Fast path: attachment is already present
ATTACHMENT=$(echo "$DESCRIBE_OUTPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('pscServiceAttachment',''))
except: pass
" 2>/dev/null || true)

if [ -n "$ATTACHMENT" ]; then
  jq -n --arg psc "$ATTACHMENT" '{"psc_service_attachment":$psc}'
  exit 0
fi

# ─── Step 3: Engine is provisioning — poll (fresh project only) ───────────────
# Only reached if describe succeeded but pscServiceAttachment is not yet populated.
# This happens on a brand-new project where the SGP engine is still initializing.
echo "[provision_sgp_engine] SGP engine provisioning — polling for pscServiceAttachment..." >&2
MAX_ATTEMPTS=20   # 20 x 15s = 5 minutes
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  ATTACHMENT=$(gcloud beta ai semantic-governance-policy-engine describe \
    --location="$LOCATION" \
    --project="$PROJECT_ID" \
    --format="value(pscServiceAttachment)" 2>/dev/null || true)

  if [ -n "$ATTACHMENT" ]; then
    jq -n --arg psc "$ATTACHMENT" '{"psc_service_attachment":$psc}'
    exit 0
  fi

  sleep 15
  ATTEMPT=$((ATTEMPT + 1))
  echo "[provision_sgp_engine] Attempt $ATTEMPT/$MAX_ATTEMPTS — still waiting..." >&2
done

# ─── Step 4: Polling timed out — try cache one more time ─────────────────────
CACHED=$(get_cached_attachment)
if [ -n "$CACHED" ]; then
  echo "[provision_sgp_engine] Polling timed out — using cached value from tfstate." >&2
  jq -n --arg psc "$CACHED" '{"psc_service_attachment":$psc}'
  exit 0
fi

# ─── Step 5: Hard failure — fresh project, no cache, engine not ready ─────────
echo "[provision_sgp_engine] ERROR: SGP engine not ready after ${MAX_ATTEMPTS} attempts." >&2
echo "  Wait 5-10 minutes for SGP engine initialization and re-run terraform apply." >&2
jq -n '{"error":"SGP engine pscServiceAttachment not yet available"}'
exit 1
