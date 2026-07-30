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

"""Structured llm_usage events for per-agent token observability.

Emits a JSON line to stdout so Cloud Logging ingests it as jsonPayload
(not textPayload). The log-based metrics in agent_observability/log_metrics.tf
filter on jsonPayload.event="llm_usage" and extract jsonPayload.agent_id,
jsonPayload.total_tokens, etc.

Key contract:
  - Field names MUST match the label_extractors in log_metrics.tf:
      agent_id, department, model, total_tokens, prompt_tokens, output_tokens
  - Emit via print() to stdout, NOT logging.info() — the latter produces
    textPayload which the metric filters never match.
"""
from __future__ import annotations

import json
import time
from typing import Any, Mapping, Optional


def _coerce_int(value: Any, default: int = 0) -> int:
    try:
        if value is None:
            return default
        return int(value)
    except (TypeError, ValueError):
        return default


def _field(source: Any, *keys: str) -> Any:
    """Try multiple field names; return first non-None value found."""
    if source is None:
        return None
    if isinstance(source, Mapping):
        for k in keys:
            v = source.get(k)
            if v is not None:
                return v
        return None
    for k in keys:
        v = getattr(source, k, None)
        if v is not None:
            return v
    return None


def parse_usage_metadata(llm_response: Any) -> dict[str, int]:
    """Extract token counts from ADK LlmResponse or Vertex GenerateContentResponse."""
    usage = _field(llm_response, "usage_metadata")
    if usage is None and hasattr(llm_response, "model_dump"):
        try:
            usage = llm_response.model_dump().get("usage_metadata")
        except Exception:
            usage = None
    if usage is None:
        return {}

    prompt = _coerce_int(
        _field(usage, "prompt_token_count", "prompt_tokens", "input_tokens")
    )
    output = _coerce_int(
        _field(usage, "candidates_token_count", "output_token_count",
               "response_token_count", "completion_token_count", "output_tokens")
    )
    thoughts = _coerce_int(
        _field(usage, "thoughts_token_count", "thoughts_tokens")
    )
    total = _coerce_int(
        _field(usage, "total_token_count", "total_tokens")
    )
    if total <= 0:
        total = prompt + output + thoughts
    return {
        "prompt_tokens": prompt,
        "output_tokens": output,
        "thoughts_tokens": thoughts,
        "total_tokens": total,
    }


def emit_llm_usage(
    *,
    agent_id: str,
    department: str,
    agent_role: str = "supervisor",
    model: Optional[str] = None,
    prompt_tokens: int = 0,
    output_tokens: int = 0,
    thoughts_tokens: int = 0,
    total_tokens: int = 0,
    session_id: Optional[str] = None,
    status: str = "ok",
    **kwargs: Any,
) -> None:
    """Emit one llm_usage JSON line per LLM completion.

    Uses print() to stdout so Cloud Run / Vertex AI Reasoning Engine
    picks it up as jsonPayload in Cloud Logging.
    """
    if total_tokens <= 0:
        total_tokens = prompt_tokens + output_tokens + thoughts_tokens
    if total_tokens <= 0:
        return

    payload: dict[str, Any] = {
        "event": "llm_usage",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "agent_id": agent_id,
        "department": department,
        "agent_role": agent_role,
        "model": (model or "unknown")[:80],
        "prompt_tokens": prompt_tokens,
        "output_tokens": output_tokens,
        "thoughts_tokens": thoughts_tokens,
        "total_tokens": total_tokens,
        "llm_call_count": 1,
        "status": status,
    }
    if session_id:
        payload["session_id"] = str(session_id)[:36]
    for key, value in kwargs.items():
        if value is not None:
            payload[key] = value

    try:
        line = json.dumps(payload, default=str)
    except Exception:
        line = json.dumps({
            "event": "llm_usage",
            "agent_id": agent_id,
            "department": department,
            "total_tokens": total_tokens,
            "status": "serialization_failed",
        })
    # stdout → Cloud Logging jsonPayload (not textPayload via logging.info)
    print(line, flush=True)


def emit_llm_usage_from_response(
    llm_response: Any,
    *,
    agent_id: str,
    department: str,
    agent_role: str = "supervisor",
    model: Optional[str] = None,
    session_id: Optional[str] = None,
    status: str = "ok",
) -> None:
    """Parse usage_metadata from an ADK/Vertex response and emit llm_usage."""
    usage = parse_usage_metadata(llm_response)
    if not usage.get("total_tokens"):
        return
    resolved_model = model
    if not resolved_model:
        resolved_model = (getattr(llm_response, "model_version", None)
                          or getattr(llm_response, "model", None))
    emit_llm_usage(
        agent_id=agent_id,
        department=department,
        agent_role=agent_role,
        model=str(resolved_model) if resolved_model else None,
        session_id=session_id,
        status=status,
        **usage,
    )
