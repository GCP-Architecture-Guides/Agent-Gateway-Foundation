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

# =============================================================================
# scripts/publish_sdk.sh
#
# Builds and publishes gateway-agent-sdk to Google Artifact Registry.
#
# Usage:
#   bash scripts/publish_sdk.sh [PROJECT_ID] [REGION] [REPO_NAME]
#
# Defaults:
#   PROJECT_ID  — from gcloud config
#   REGION      — us-east1
#   REPO_NAME   — agw-python-packages
#
# Prerequisites:
#   - gcloud authenticated with roles/artifactregistry.writer
#   - python3, pip, build, twine installed
#   - Artifact Registry API enabled: artifactregistry.googleapis.com
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( dirname "$SCRIPT_DIR" )"
SDK_DIR="$REPO_ROOT/lib/gateway_agent"

PROJECT_ID="${1:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${2:-us-east1}"
REPO_NAME="${3:-agw-python-packages}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "❌ PROJECT_ID is required. Pass as arg or set: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi

AR_URL="https://${REGION}-python.pkg.dev/${PROJECT_ID}/${REPO_NAME}/"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║         gateway-agent-sdk — Artifact Registry Publish    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo "  Project  : $PROJECT_ID"
echo "  Region   : $REGION"
echo "  Repo     : $REPO_NAME"
echo "  AR URL   : $AR_URL"
echo ""

# --- Step 1: Ensure Artifact Registry repo exists ---
echo "▶ [1/4] Ensuring Artifact Registry repo exists..."
gcloud artifacts repositories create "$REPO_NAME" \
  --repository-format=python \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --description="Agent Gateway SDK and shared Python packages" \
  --quiet 2>/dev/null \
  || echo "  ℹ️  Repo '$REPO_NAME' already exists — skipping creation."

# --- Step 2: Install build tools ---
echo "▶ [2/4] Installing build tools..."
python3 -m pip install --quiet --upgrade build twine

# --- Step 3: Build the package ---
echo "▶ [3/4] Building gateway-agent-sdk..."
cd "$SDK_DIR"
rm -rf dist/ build/ *.egg-info
python3 -m build
echo "  Built artifacts:"
ls -la dist/

# --- Step 4: Publish to Artifact Registry ---
echo "▶ [4/4] Publishing to Artifact Registry..."
TOKEN=$(gcloud auth print-access-token)

python3 -m twine upload \
  --repository-url "$AR_URL" \
  --username "oauth2accesstoken" \
  --password "$TOKEN" \
  --non-interactive \
  dist/*

echo ""
echo "✅ Published: gateway-agent-sdk → $AR_URL"
echo ""
echo "To install in a new project's requirements.txt:"
echo ""
echo "  # requirements.txt"
echo "  --extra-index-url $AR_URL"
echo "  gateway-agent-sdk==1.0.0"
echo ""
echo "To configure keyring auth (recommended for CI):"
echo "  pip install keyrings.google-artifactregistry-auth"
echo "  gcloud auth application-default login"
