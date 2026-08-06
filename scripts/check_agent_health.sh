#!/usr/bin/env bash
# Copyright 2025 Google LLC
# Licensed under the Apache License, Version 2.0.
# This code is for PoC environment only.

# ===========================================================================
# check_agent_health.sh — Two must-have sanity checks for every deployed RE
#
# Check 1: agentGatewayConfig is populated (gateway patch fired)
# Check 2: mTLS cert timestamp ≠ 1970-01-01 (Agent Identity cert provisioned)
# Check 3: E2E round-trip (agent actually responds)
#
# Usage:
#   bash scripts/check_agent_health.sh [RE_ID]
#
#   RE_ID is optional — if omitted, auto-discovers from terraform.tfvars agent_name.
#   Project and region are always read from terraform.tfvars.
#
# Examples:
#   bash scripts/check_agent_health.sh
#   bash scripts/check_agent_health.sh 8650939895155523584
# ===========================================================================

set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "$0" )" >/dev/null && pwd )"
WORKSPACE="$( dirname "$SCRIPT_DIR" )"

PASS="✅"; FAIL="❌"; WARN="⚠️ "
FAILS=0
pass()  { echo "  $PASS $*"; }
fail()  { echo "  $FAIL $*"; FAILS=$((FAILS+1)); }
warn()  { echo "  $WARN $*"; }

# ── Config from terraform.tfvars ─────────────────────────────────────────────
TFVARS="$WORKSPACE/terraform.tfvars"
PROJECT=$(grep -oP '^project_id\s*=\s*"\K[^"]+' "$TFVARS")
REGION=$(grep -oP '^location\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null || grep -oP '^region\s*=\s*"\K[^"]+' "$TFVARS")
AGENT_NAME=$(grep -oP '^agent_name\s*=\s*"\K[^"]+' "$TFVARS" 2>/dev/null || echo "")
RE_API="https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT}/locations/${REGION}/reasoningEngines"
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null | tail -1)

echo ""
echo "Agent Health Check — $PROJECT / $REGION"
echo "────────────────────────────────────────"

# ── Resolve RE ID ─────────────────────────────────────────────────────────────
RE_ID="${1:-}"
if [[ -z "$RE_ID" ]]; then
  [[ -z "$AGENT_NAME" ]] && { fail "No RE ID given and agent_name missing from terraform.tfvars"; exit 1; }
  RE_ID=$(curl -s -H "Authorization: Bearer $TOKEN" "$RE_API" | python3 -c "
import json,sys
engines=json.load(sys.stdin).get('reasoningEngines',[])
matches=[e for e in engines if e.get('displayName')=='$AGENT_NAME']
latest=sorted(matches,key=lambda e:e.get('createTime',''),reverse=True)
print(latest[0]['name'].split('/')[-1] if latest else '')
" 2>/dev/null)
  [[ -z "$RE_ID" ]] && { fail "No RE found with displayName='$AGENT_NAME'"; exit 1; }
fi

RE=$(curl -s -H "Authorization: Bearer $TOKEN" "${RE_API}/${RE_ID}")
RE_NAME=$(echo "$RE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('displayName','?'))" 2>/dev/null)
echo "  RE: $RE_NAME ($RE_ID)"
echo ""

# ── CHECK 1: agentGatewayConfig ≠ {} ─────────────────────────────────────────
echo "Check 1 — agentGatewayConfig populated (gateway patch fired)"
AGW_CONFIG=$(echo "$RE" | python3 -c "
import json,sys
spec=json.load(sys.stdin).get('spec',{})
cfg=spec.get('agentGatewayConfig', spec.get('deploymentSpec',{}).get('agentGatewayConfig',{}))
print('EMPTY' if not cfg else 'OK:'+json.dumps(cfg)[:120])
" 2>/dev/null)
if echo "$AGW_CONFIG" | grep -q "^OK:"; then
  pass "agentGatewayConfig is set: ${AGW_CONFIG#OK:}"
else
  fail "agentGatewayConfig = {} or missing — gateway patch did NOT fire"
  warn "RE will not route traffic through the Agent Gateway."
  warn "Fix: redeploy using deploy_chat_agent.sh or deploy_global_agent.sh"
  warn "     which runs patch_sdk_for_rest_create.py before adk deploy."
fi

echo ""

# ── CHECK 2: mTLS cert timestamp ≠ 1970-01-01 ────────────────────────────────
echo "Check 2 — Agent Identity mTLS cert valid (timestamp ≠ epoch)"
CERT_LOG=$(gcloud logging read \
  "resource.type=\"networkservices.googleapis.com/Gateway\" AND jsonPayload.mtls.clientCertPresent=\"true\" AND jsonPayload.httpRequest.requestUrl:\"${RE_ID}\"" \
  --project="$PROJECT" --limit=3 --format=json 2>/dev/null || echo "[]")

CERT_STATUS=$(echo "$CERT_LOG" | python3 -c "
import json,sys
entries=json.load(sys.stdin)
if not entries:
    print('NO_LOGS')
    sys.exit(0)
for e in entries:
    mtls=e.get('jsonPayload',{}).get('mtls',{})
    verified=mtls.get('clientCertChainVerified','')
    expiry=mtls.get('clientCertValidEndTime','')
    if '1970-01-01' in expiry or verified=='false':
        print(f'INVALID|chainVerified={verified}|expiry={expiry}')
        sys.exit(0)
    elif verified=='true':
        print(f'VALID|expiry={expiry}')
        sys.exit(0)
print('NO_LOGS')
" 2>/dev/null)

if echo "$CERT_STATUS" | grep -q "^VALID"; then
  EXPIRY="${CERT_STATUS#VALID|expiry=}"
  pass "mTLS cert valid — chainVerified=true, expiry=$EXPIRY"
elif echo "$CERT_STATUS" | grep -q "^INVALID"; then
  fail "mTLS cert is INVALID — ${CERT_STATUS#INVALID|}"
  warn "Agent Identity cert was NOT provisioned by Google CA (P2 known bug)."
  warn "IAP ENFORCED on egress will DENY all traffic — keep DRY_RUN."
  warn "Try redeploying the RE. See KNOWN_ISSUES.md #013."
else
  warn "No gateway logs found for RE $RE_ID — cert status unknown."
  warn "Send a test query first, then re-run this check."
fi

echo ""

# ── CHECK 3: E2E round-trip ───────────────────────────────────────────────────
echo "Check 3 — End-to-end inference (agent responds)"
RESP=$(curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "${RE_API}/${RE_ID}:streamQuery" \
  -d '{"input":{"user_id":"health-check","session_id":"hc-1","message":"Reply with OK only."}}' \
  --max-time 45 2>/dev/null || echo "")

TEXT=$(echo "$RESP" | python3 -c "
import json,sys
for line in sys.stdin.read().strip().split('\n'):
    try:
        for p in json.loads(line).get('content',{}).get('parts',[]):
            t=p.get('text','')
            if t: print(t[:100]); sys.exit(0)
    except: pass
print('')
" 2>/dev/null)

if [[ -n "$TEXT" ]]; then
  pass "Agent responded: \"$TEXT\""
elif echo "$RESP" | grep -qi "403\|PERMISSION_DENIED"; then
  fail "E2E blocked — 403 PERMISSION_DENIED (IAP ENFORCED + invalid cert, or missing queryer role)"
elif echo "$RESP" | grep -qi "400\|FAILED_PRECONDITION"; then
  fail "E2E failed — 400 FAILED_PRECONDITION (agentGatewayConfig missing, see Check 1)"
else
  fail "E2E returned no text (empty response — RE may be cold-starting, retry in 2 min)"
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
if [[ "$FAILS" -eq 0 ]]; then
  echo "  $PASS All checks passed."
else
  echo "  $FAIL $FAILS check(s) failed — see above."
fi
echo ""
exit "$FAILS"
