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
