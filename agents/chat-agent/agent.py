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

# gateway_agent SDK is bundled at deploy time by deploy_chat_agent.sh
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gateway_agent import GatewayAgent

# NOTE: GatewayAgent wires query() registration automatically via its own
# query() stub method. No manual monkey-patching needed.



# ---------------------------------------------------------------------------
# Agent Definition
# ---------------------------------------------------------------------------
def fetch_url(url: str) -> str:
    """Fetches the content of a URL and returns it as text."""
    try:
        response = requests.get(url, timeout=5)
        response.raise_for_status()
        return response.text
    except Exception as e:
        return f"Failed to fetch URL: {e}"


root_agent = GatewayAgent(
    name=os.environ.get("AGENT_NAME", "chat_agent"),  # underscore required — ADK validates as Python identifier
    model="gemini-2.5-flash",   # corrected from stale "gemini-3.5-flash"
    description=os.environ.get("AGENT_DESCRIPTION", "A foundational chat agent demonstrating security integrations."),
    instruction="You are a helpful assistant deployed behind the Agent Gateway. Use 'fetch_url' to read URLs.",
    tools=[fetch_url],
)

# GatewayAgent automatically wires emit_llm_usage_from_response via _chained_callback.
