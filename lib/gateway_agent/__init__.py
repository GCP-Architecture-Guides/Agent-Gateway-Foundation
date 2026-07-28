"""GatewayAgent SDK — Agent Gateway compliance wrapper for ADK agents.

Exports:
    GatewayAgent: Drop-in replacement for ADK Agent that enforces:
        - GlobalGemini regional-endpoint routing (pass-through to GOOGLE_CLOUD_LOCATION)
        - OTEL token telemetry via after_model_callback (emits jsonPayload for dashboards)
        - Synchronous query() stub for :query REST endpoint registration
        - get_project_id monkey-patch for Org Policy bypass
"""

from .agent import GatewayAgent
from .global_gemini import GlobalGemini
from .telemetry import emit_llm_usage_from_response

__all__ = ["GatewayAgent", "GlobalGemini", "emit_llm_usage_from_response"]
