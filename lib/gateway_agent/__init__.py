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
