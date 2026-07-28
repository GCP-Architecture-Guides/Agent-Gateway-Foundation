"""Telemetry utilities for the Agent Gateway.

Provides the after_model_callback that emits structured JSON token usage events.
These events are consumed by the log-based metrics in the Agent Observability
dashboard (modules/agent_observability) to power token usage widgets and alerts.

Without this callback wired into every agent, the dashboard shows zero usage
for the entire agent lifetime — there is no other signal source.

CRITICAL: Use print() to stdout, NOT logging.info().
logging.info() writes to Cloud Logging as textPayload.
print() to stdout writes as jsonPayload — which log-based metrics require.
"""

import json
import logging
import sys
from typing import Optional

from google.adk.agents.callback_context import CallbackContext
from google.adk.models.llm_response import LlmResponse

logger = logging.getLogger(__name__)


def emit_llm_usage_from_response(
    callback_context: CallbackContext,
    llm_response: LlmResponse,
) -> Optional[LlmResponse]:
    """ADK after_model_callback that emits a structured JSON usage event.

    Attach to any ADK Agent as after_model_callback=emit_llm_usage_from_response
    (or use GatewayAgent which wires this automatically).

    Emits a structured log line consumed by the Agent Gateway Observability
    dashboard log-based metrics:
        {"event": "llm_usage", "agent": "...", "model": "...",
         "input_tokens": 100, "output_tokens": 50, "total_tokens": 150}

    Returns:
        None — does not modify the LLM response.
    """
    try:
        usage = llm_response.usage_metadata
        if usage is None:
            return None

        prompt  = getattr(usage, "prompt_token_count",      0) or 0
        output  = getattr(usage, "candidates_token_count", 0) or 0
        thoughts = getattr(usage, "thoughts_token_count",  0) or 0
        total   = getattr(usage, "total_token_count",       0) or 0
        if total <= 0:
            total = prompt + output + thoughts
        if total <= 0:
            return None  # Nothing to emit — no tokens tracked yet

        event = {
            "event":           "llm_usage",
            "agent":           callback_context.agent_name,
            "model":           getattr(llm_response, "model_version", None) or "unknown",
            "input_tokens":    prompt,
            "output_tokens":   output,
            "thoughts_tokens": thoughts,
            "total_tokens":    total,
        }
        # stdout → Cloud Logging jsonPayload (NOT textPayload via logger.info).
        # The log-based metrics in agent_observability/log_metrics.tf filter on
        # jsonPayload.event="llm_usage" — textPayload never matches.
        print(json.dumps(event), flush=True)
    except Exception as exc:
        logger.warning("emit_llm_usage_from_response failed: %s", exc)

    return None
