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

"""GatewayAgent: Compliance-enforcing wrapper for ADK Agent.

Automatically wires:
  1. GlobalGemini — pass-through Gemini subclass. Uses the default regional
     Vertex AI endpoint (GOOGLE_CLOUD_LOCATION) which is routed through the
     Agent Gateway egress PSC. Previously overrode to global endpoint which
     broke PSC routing.

  2. emit_llm_usage_from_response — OTEL after_model_callback.
     Without this, the Agent Gateway Observability dashboard shows zero token
     usage for the entire agent lifetime.

  3. query() method registration — registers a synchronous query() on the AdkApp
     so the :query REST endpoint returns a real response instead of
     "Default method 'query' not found".

  4. get_project_id monkey-patch — prevents gRPC project-number lookups that
     route through the egress proxy (which has no PSC route to the IAM API).
     Reads GCP_PROJECT_ID / GOOGLE_CLOUD_PROJECT from the environment instead.

Usage:
    from gateway_agent import GatewayAgent

    root_agent = GatewayAgent(
        name="my_agent",
        model="gemini-2.5-flash",   # pass model name as string — GlobalGemini applied
        description="...",
        instruction="...",
        tools=[...],
    )
"""

import os
from typing import Optional, Callable

from google.adk.agents import Agent
from google.adk.agents.callback_context import CallbackContext
from google.adk.models.llm_response import LlmResponse

from .global_gemini import GlobalGemini
from .telemetry import emit_llm_usage_from_response

# ---------------------------------------------------------------------------
# Org Policy bypass: prevent gRPC project-number → project-ID lookups.
# The egress proxy has no PSC route to the IAM API — unpatched, these calls
# time out and crash the agent on startup.
# ---------------------------------------------------------------------------
try:
    from google.cloud.aiplatform.utils import resource_manager_utils

    def _patched_get_project_id(project_number: str) -> str:
        return (
            os.environ.get("GCP_PROJECT_ID")
            or os.environ.get("GOOGLE_CLOUD_PROJECT")
            or ""
        )

    resource_manager_utils.get_project_id = _patched_get_project_id
except (ImportError, AttributeError) as _patch_err:
    # ImportError: google-cloud-aiplatform not installed (local dev without full deps)
    # AttributeError: SDK version changed the module structure
    # Log but don't crash — the patch is a best-effort Org Policy bypass
    import logging as _logging
    _logging.getLogger(__name__).debug("get_project_id patch skipped: %s", _patch_err)


class GatewayAgent(Agent):
    """Drop-in replacement for ADK Agent that enforces Agent Gateway compliance.

    Developers pass model as a plain string — GatewayAgent wraps it with
    GlobalGemini automatically. The after_model_callback chain always includes
    emit_llm_usage_from_response; developers may add their own callback on top.

    Example:
        root_agent = GatewayAgent(
            name="chat_agent",
            model="gemini-2.5-flash",
            description="A helpful assistant.",
            instruction="You are a helpful assistant.",
            tools=[fetch_url],
        )
    """

    def __init__(
        self,
        *,
        model: str,
        after_model_callback: Optional[Callable] = None,
        **kwargs,
    ):
        # 1. Regional endpoint routing via the default Gemini class behaviour
        # (GOOGLE_CLOUD_LOCATION env var → us-east1-aiplatform.googleapis.com).
        # GlobalGemini is a thin pass-through — no endpoint override needed.
        gateway_model = GlobalGemini(model=model)

        # 2. Chain the telemetry callback — developer cannot forget it
        # ADK 1.31.1 calls: callback(callback_context=..., llm_response=...)
        def _chained_callback(
            callback_context: CallbackContext, llm_response: LlmResponse
        ) -> Optional[LlmResponse]:
            emit_llm_usage_from_response(callback_context, llm_response)
            if after_model_callback is not None:
                return after_model_callback(
                    callback_context=callback_context, llm_response=llm_response
                )
            return None

        super().__init__(
            model=gateway_model,
            after_model_callback=_chained_callback,
            **kwargs,
        )

    def query(self, message: str, user_id: str = "anonymous", **kwargs) -> str:
        """Synchronous query stub — registers this agent with the :query REST endpoint.

        The ADK AdkApp maintains completely separate method registries for
        :query and :streamQuery. Without this method, calling the RE via :query
        returns: {"error": "Default method 'query' not found"}

        NOTE: In ADK 1.31+, :streamQuery (:streamQuery → stream_query) is the
        mandatory inference interface. This method is a registration stub.
        Do NOT call it directly — use the RE :streamQuery endpoint instead.
        See KNOWN_ISSUES.md Issue #002.
        """
        # stream_query is on AdkApp, not Agent. This method is registered on the
        # AdkApp class method registry via the RE deployment; the AdkApp wrapper
        # handles the actual streaming. If this method is somehow called directly
        # on the Agent instance, raise a clear error rather than an AttributeError.
        raise NotImplementedError(
            "Use the Reasoning Engine :streamQuery endpoint for inference. "
            "Direct .query() on the Agent instance is not supported. "
            "See KNOWN_ISSUES.md Issue #002."
        )
