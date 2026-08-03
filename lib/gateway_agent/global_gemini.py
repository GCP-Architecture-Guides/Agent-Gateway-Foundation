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

"""GlobalGemini: Thin wrapper over Gemini for Agent Gateway deployments.

TWO DEPLOYMENT MODES — controlled by container env vars, not code:

  Regional (gemini-2.5-flash):
    Deploy with: scripts/deploy_chat_agent.sh
    Container env: GOOGLE_CLOUD_LOCATION=us-east1
    ADK Gemini constructs: https://us-east1-aiplatform.googleapis.com/...
    Agent Gateway SWP routes to regional Vertex AI frontend.
    Model availability: gemini-2.5-flash, gemini-2.5-pro (confirmed)

  Global (gemini-3.5-flash, gemini-3.1-flash-lite, etc.):
    Deploy with: scripts/deploy_global_agent.sh
    Container env: GOOGLE_CLOUD_LOCATION=global
    ADK Gemini constructs: https://aiplatform.googleapis.com/...
    Agent Gateway SWP routes to global Vertex AI frontend.
    Model availability: all Gemini 3.x models
    Requires separately: GCP_REGION=<real-region> for session management,
    RE control-plane, and OTEL calls that do not accept "global" as location.

WHY GlobalGemini IS A NO-OP:
  The endpoint is derived entirely from GOOGLE_CLOUD_LOCATION at runtime.
  No api_client override needed — the base Gemini class handles it correctly.
  This matches the pattern used in Google's official reference demo:
  cloud-networking-solutions/demos/agent-gateway (gemini-3.1-flash-lite, global)

HISTORY:
  - Tried overriding _get_client_args() → dead code in ADK 1.31.1.
  - Tried overriding api_client property → broke PSC routing (empty 500).
  - Confirmed: env var pattern is the canonical, working approach.
  - See: skills/vertex-ai-global-endpoint-adk/SKILL.md for full context.
"""

from google.adk.models.google_llm import Gemini


class GlobalGemini(Gemini):
    """Drop-in replacement for Gemini() for Agent Gateway deployments.

    Currently identical to Gemini() — uses the default regional ADK endpoint
    which works with the Agent Gateway egress PSC.

    Usage:
        from gateway_agent import GlobalGemini
        model = GlobalGemini(model="gemini-2.5-flash")
    """
    # No overrides needed — base Gemini class handles endpoint routing correctly
    # for regionally-deployed Reasoning Engines via GOOGLE_CLOUD_LOCATION env var.
    pass
