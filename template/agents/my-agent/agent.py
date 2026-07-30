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

"""
My Agent — Agent Gateway compliant agent template.

Replace this business logic with your own. The GatewayAgent wrapper handles:
  - Regional Vertex AI endpoint routing (PSC-compatible)
  - OTEL token telemetry (feeds Agent Observability dashboards)
  - GlobalGemini model wrapper (Gemini 3.x via global endpoint)
  - Org policy compliance (get_project_id patch)

To use:
  pip install gateway-agent-sdk==1.0.0  # from Artifact Registry
  OR (during development): pip install -e ../../lib/gateway_agent/
"""

import os
from gateway_agent import GatewayAgent, GlobalGemini

# Add your tool imports here, e.g.:
# from google.adk.tools import google_search
# from google.adk.tools.agent_tool import AgentTool

# ---------------------------------------------------------------------------
# Model — GlobalGemini routes through the global Vertex AI endpoint.
# Required for Gemini 2.x/3.x models which are not available regionally.
# ---------------------------------------------------------------------------
MODEL = os.environ.get("AGENT_MODEL", "gemini-2.5-pro")
gateway_model = GlobalGemini(model=MODEL)

# ---------------------------------------------------------------------------
# Agent — GatewayAgent is a drop-in replacement for google.adk.agents.Agent.
# Replace the tools list and instructions with your use case.
# ---------------------------------------------------------------------------
root_agent = GatewayAgent(
    name="my_agent",           # Must be a valid Python identifier (no hyphens)
    model=gateway_model,
    description="Describe what this agent does in one sentence.",
    instruction="""
    You are a helpful assistant. Replace this with your agent's system prompt.

    Guidelines:
    - Be concise and accurate
    - Do not access URLs not provided by the user
    - Do not repeat sensitive information back to the user
    """,
    tools=[
        # Add your tools here — see google.adk.tools for built-ins
        # google_search,
    ],
)
