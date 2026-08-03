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

import os
import sys
import requests

# gateway_agent SDK is bundled at deploy time by deploy_global_agent.sh
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gateway_agent import GatewayAgent

# ---------------------------------------------------------------------------
# Global Endpoint Agent — gemini-3.5-flash via Vertex AI global endpoint
#
# DEPLOYMENT PATTERN:
#   This agent uses GOOGLE_CLOUD_LOCATION=global (set by deploy_global_agent.sh).
#   ADK's base Gemini class reads this env var and constructs the global URL:
#     aiplatform.googleapis.com  (not us-east1-aiplatform.googleapis.com)
#   The Agent Gateway SWP proxy routes this through to the global Vertex AI
#   frontend, which serves Gemini 3.x models unavailable at regional endpoints.
#
#   Non-model calls (RE control-plane, session management) use GCP_REGION
#   (also set by deploy_global_agent.sh) as a fallback for the real region.
#
# CONTRAST with chat-agent:
#   chat-agent:    GOOGLE_CLOUD_LOCATION=us-east1  → regional endpoint (2.5-flash)
#   global-agent:  GOOGLE_CLOUD_LOCATION=global    → global endpoint  (3.5-flash)
#
# See: skills/vertex-ai-global-endpoint-adk/SKILL.md
# ---------------------------------------------------------------------------


def fetch_url(url: str) -> str:
    """Fetches the content of a URL and returns it as text."""
    try:
        response = requests.get(url, timeout=5)
        response.raise_for_status()
        return response.text
    except Exception as e:
        return f"[GATEWAY BLOCKED or unreachable] Failed to fetch URL: {e}"


root_agent = GatewayAgent(
    name=os.environ.get("AGENT_NAME", "global_agent"),
    model=os.environ.get("AGENT_MODEL", "gemini-3.5-flash"),
    description=os.environ.get(
        "AGENT_DESCRIPTION",
        "A foundational chat agent demonstrating the Vertex AI global endpoint "
        "pattern with Gemini 3.5 Flash behind Agent Gateway.",
    ),
    instruction=(
        "You are a helpful assistant deployed on the Vertex AI global endpoint "
        "behind the Agent Gateway. Use 'fetch_url' to read URLs when asked. "
        "Be concise and factual."
    ),
    tools=[fetch_url],
)

# GatewayAgent automatically wires emit_llm_usage_from_response via _chained_callback.
# GOOGLE_CLOUD_LOCATION=global (set by deploy_global_agent.sh) routes all model
# inference calls to aiplatform.googleapis.com — no api_client override needed.
