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

MAX_RETRIES=15
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  echo "Running terraform destroy..."
  terraform destroy -auto-approve
  if [ $? -eq 0 ]; then
    echo "Destroy successful!"
    exit 0
  fi
  echo "Terraform destroy failed. Retrying in 60 seconds (Attempt $((RETRY_COUNT+1)) of $MAX_RETRIES)..."
  sleep 60
  RETRY_COUNT=$((RETRY_COUNT+1))
done
echo "Max retries reached. Exiting."
exit 1
