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
#
# This code is for PoC environment only.
# This demo code is not built for production workload.

# Auto-provisions the SGP Engine and extracts the dynamic pscServiceAttachment string.
# Returns a JSON object required by Terraform external data source.

PROJECT_ID=$1
LOCATION=$2

# Kick off the Google-managed provisioning (this command is asynchronous internally if the VPC networking is not yet ready)
# We omit gateway-config to just trigger the judge service creation
gcloud beta ai semantic-governance-policy-engine update \
  --location="$LOCATION" \
  --project="$PROJECT_ID" >/dev/null 2>&1 || true


# Poll the describe command until the Google judge service exposes the PSC attachment URI
# Timeout after 20 minutes (1200 seconds / 15 seconds = 80 attempts)
MAX_ATTEMPTS=80
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  # Extract the pscServiceAttachment string
  ATTACHMENT=$(gcloud beta ai semantic-governance-policy-engine describe \
    --location="$LOCATION" \
    --project="$PROJECT_ID" \
    --format="value(pscServiceAttachment)" 2>/dev/null)
  
  if [ -n "$ATTACHMENT" ]; then
    # Return valid JSON for Terraform to parse
    jq -n --arg psc "$ATTACHMENT" '{"psc_service_attachment":$psc}'
    exit 0
  fi
  
  sleep 15
  ATTEMPT=$((ATTEMPT + 1))
done

# If we hit the timeout, return an error block
jq -n '{"error":"Timed out waiting for SGP Engine pscServiceAttachment"}'
exit 1
