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

# ===========================================================================
# grant_agent_iam_roles.sh
#
# Grants the 5 required IAM roles to the Agent Identity SA of a deployed
# Reasoning Engine. Called by deploy_chat_agent.sh and deploy_global_agent.sh
# immediately after the RE becomes ACTIVE.
#
# Usage (called by deploy scripts — not intended for direct invocation):
#   source scripts/grant_agent_iam_roles.sh
#   grant_agent_iam_roles <project_id> <region> <re_id> <token>
#
# Required roles granted to agent-RE_ID@PROJECT_ID.iam.gserviceaccount.com:
#   roles/aiplatform.user            — Agent Platform User
#   roles/cloudtrace.agent           — Cloud Trace Agent
#   roles/logging.logWriter          — Logs Writer
#   roles/aiplatform.sessionUser     — Reasoning Engine Session User
#   roles/serviceusage.serviceUsageConsumer — Service Usage Consumer
#
# WHY these roles:
#   aiplatform.user          — Lets the agent call Vertex AI APIs (model inference,
#                              session management, Agent Registry reads).
#   cloudtrace.agent         — Lets the agent write distributed traces to Cloud Trace
#                              for observability of LLM calls.
#   logging.logWriter        — Lets the agent write structured logs to Cloud Logging.
#   aiplatform.sessionUser   — Lets the agent create, read, and append to RE sessions
#                              (required for multi-turn conversations).
#   serviceUsageConsumer     — Lets the agent consume enabled GCP APIs without hitting
#                              quota/billing errors on API calls.
#
# Identity type: AGENT_IDENTITY (injected by gateway patch).
# SA format: agent-RE_ID@PROJECT_ID.iam.gserviceaccount.com
# ===========================================================================

grant_agent_iam_roles() {
  local PROJECT_ID="$1"
  local REGION="$2"
  local RE_ID="$3"
  local TOKEN="$4"

  if [[ -z "$RE_ID" || -z "$PROJECT_ID" ]]; then
    echo "  ⚠️  grant_agent_iam_roles: missing RE_ID or PROJECT_ID — skipping IAM grants."
    return 0
  fi

  # ---------------------------------------------------------------------------
  # Derive the Agent Identity SA from the RE spec.
  # The RE is deployed with identityType=AGENT_IDENTITY (injected by the
  # gateway patch). This creates a dedicated SA:
  #   agent-RE_ID@PROJECT_ID.iam.gserviceaccount.com
  #
  # Fetch it from the API to be certain — don't construct it by convention.
  # ---------------------------------------------------------------------------
  echo ""
  echo "── Post-deploy IAM grants ──────────────────────────────────────────────"
  echo "  Looking up Agent Identity SA for RE $RE_ID..."

  local AGENT_SA
  AGENT_SA=$(
    curl -s -H "Authorization: Bearer $TOKEN" \
      "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${RE_ID}" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
sa = d.get('spec', {}).get('serviceAccount', '')
if sa:
    print(sa)
" 2>/dev/null
  )

  if [[ -z "$AGENT_SA" ]]; then
    # Fallback: derive by convention (works when identityType=AGENT_IDENTITY)
    AGENT_SA="agent-${RE_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
    echo "  ⚠️  Could not read SA from API — using convention: $AGENT_SA"
  else
    echo "  ✅ Agent Identity SA: $AGENT_SA"
  fi

  # ---------------------------------------------------------------------------
  # Grant the 5 required roles at project level.
  # Each grant is idempotent — re-applying an existing binding is a no-op.
  # Failures are non-fatal (|| true) so a partial permission failure doesn't
  # abort the deploy; warnings are printed instead.
  # ---------------------------------------------------------------------------
  local ROLES=(
    "roles/aiplatform.user"
    "roles/cloudtrace.agent"
    "roles/logging.logWriter"
    "roles/aiplatform.sessionUser"
    "roles/serviceusage.serviceUsageConsumer"
  )

  local ROLE_LABELS=(
    "Agent Platform User"
    "Cloud Trace Agent"
    "Logs Writer"
    "Reasoning Engine Session User (aiplatform.sessionUser)"
    "Service Usage Consumer"
  )

  local GRANT_ERRORS=0
  for i in "${!ROLES[@]}"; do
    local ROLE="${ROLES[$i]}"
    local LABEL="${ROLE_LABELS[$i]}"
    echo "  Granting $LABEL ($ROLE)..."
    if gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${AGENT_SA}" \
        --role="$ROLE" \
        --condition=None \
        --quiet 2>/dev/null; then
      echo "    ✅ Granted"
    else
      echo "    ⚠️  Grant failed (non-fatal) — check manually:"
      echo "       gcloud projects add-iam-policy-binding $PROJECT_ID \\"
      echo "         --member=\"serviceAccount:${AGENT_SA}\" \\"
      echo "         --role=\"$ROLE\" --condition=None"
      GRANT_ERRORS=$((GRANT_ERRORS + 1))
    fi
  done

  if [ "$GRANT_ERRORS" -eq 0 ]; then
    echo ""
    echo "  ✅ All 5 IAM roles granted to $AGENT_SA"
  else
    echo ""
    echo "  ⚠️  $GRANT_ERRORS role grant(s) failed — agent may lack some permissions."
    echo "  Re-run the grants manually using the commands above."
  fi
  echo "────────────────────────────────────────────────────────────────────────"
  echo ""
}
