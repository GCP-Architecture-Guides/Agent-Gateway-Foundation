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
a2a_compat.py — Compatibility shim for a2a-sdk==1.1.2 + google-cloud-aiplatform==1.163.0

Patches 4 incompatibilities between a2a-sdk 1.1.2 (protobuf-based) and the
GA A2aAgent (built against a2a-sdk ~0.3.x, pydantic-based):

  Fix 1: TransportProtocol moved from a2a.types → a2a.utils
          Injected back into a2a.types so GA SDK imports don't fail.

  Fix 2: AgentCard.__init__ no longer accepts url= or preferred_transport=
          create_agent_card() strips unknown kwargs and auto-creates
          supported_interfaces with a placeholder URL.

  Fix 3: AgentCard is an immutable protobuf but GA A2aAgent.set_up() sets .url
          MutableAgentCard wraps the protobuf in a mutable proxy.
          __reduce__ ensures cloudpickle serializes it as a plain AgentCard
          so the remote container has no dependency on a2a_compat.

  Fix 4: A2aAgent.__init__ accesses agent_card.preferred_transport (not in 1.1.2)
          Patched __init__ wraps the card in MutableAgentCard before the check.

Usage:
    import a2a_compat          # MUST be first — before any vertexai.agent_engines import
    from a2a_compat import A2aAgent, create_agent_card

Full deployment guide: skills/a2a-agent-deploy/SKILL.md
Experiment report:     skills/a2a-agent-deploy/references/EXPERIMENT_REPORT.md

Discovered via 12 real deployment attempts (2026-07-30).
"""

# =============================================================================
# Fix 1: TransportProtocol location
# GA SDK does: from a2a.types import TransportProtocol
# a2a-sdk 1.1.2 moved it to a2a.utils
# =============================================================================
import a2a.types as _a2a_types
import a2a.utils as _a2a_utils

if not hasattr(_a2a_types, "TransportProtocol"):
    _a2a_types.TransportProtocol = _a2a_utils.TransportProtocol


# =============================================================================
# Fix 3: MutableAgentCard
# AgentCard is an immutable protobuf. GA A2aAgent.set_up() mutates card.url
# and card.supported_interfaces after construction — raises AttributeError on
# a plain protobuf.
#
# MutableAgentCard is a proxy that:
#   - Delegates attribute reads to the underlying proto
#   - Stores writes in a local _overrides dict
#   - Proxies DESCRIPTOR so GA's hasattr(obj, 'DESCRIPTOR') check passes
#   - Pickles as plain AgentCard (no a2a_compat dependency on remote)
#
# Why __reduce__ matters:
#   cloudpickle.register_pickle_by_value serializes the executor module inline.
#   If MutableAgentCard is in the pickle stream, the remote container would need
#   a2a_compat.py to unpickle it. __reduce__ returns AgentCard.FromString(bytes)
#   instead — a plain protobuf, no wrapper required on the remote side.
#   The GA A2aAgent's own __setstate__ handles both JSON dict and raw AgentCard
#   objects correctly via hasattr(obj, 'DESCRIPTOR').
# =============================================================================
from a2a.types import AgentCard as _OrigAgentCard


class MutableAgentCard:
    """
    Mutable proxy around an immutable protobuf AgentCard.

    See module docstring Fix 3 for full rationale.
    """

    def __init__(self, proto: "_OrigAgentCard") -> None:
        object.__setattr__(self, "_proto", proto)
        object.__setattr__(self, "_overrides", {})

    def __getattr__(self, name: str):
        overrides = object.__getattribute__(self, "_overrides")
        if name in overrides:
            return overrides[name]
        proto = object.__getattribute__(self, "_proto")
        return getattr(proto, name)

    def __setattr__(self, name: str, value) -> None:
        object.__getattribute__(self, "_overrides")[name] = value

    def __reduce__(self):
        """
        Pickle as plain AgentCard so the remote container needs no a2a_compat.

        The GA A2aAgent.__setstate__ accepts both a JSON dict and a raw AgentCard
        object (detected via hasattr(obj, 'DESCRIPTOR')), so this is safe.
        Do NOT change this to custom __getstate__/__setstate__ — the GA's
        json_format-based serialization will leave agent_card=None on remote.
        """
        proto = object.__getattribute__(self, "_proto")
        return (_OrigAgentCard.FromString, (proto.SerializeToString(),))

    @property
    def DESCRIPTOR(self):
        """
        Proxy DESCRIPTOR so GA A2aAgent's hasattr(card, 'DESCRIPTOR') check passes.
        The GA uses this to detect whether it received a protobuf or pydantic card.
        """
        proto = object.__getattribute__(self, "_proto")
        return proto.DESCRIPTOR

    def __repr__(self) -> str:
        proto = object.__getattribute__(self, "_proto")
        overrides = object.__getattribute__(self, "_overrides")
        return (
            f"MutableAgentCard(name={proto.name!r}, "
            f"overrides={sorted(overrides.keys())})"
        )


# =============================================================================
# Fix 2: create_agent_card() — safe AgentCard factory
# Strips url= and preferred_transport= kwargs (removed from protobuf in 1.1.2).
# Ensures supported_interfaces has at least one entry (required by
# GA A2aAgent._is_version_enabled() — returns False if list is empty, causing
# __init__ to raise ValueError before any user code runs).
# =============================================================================
def create_agent_card(
    name: str,
    description: str,
    version: str = "1.0.0",
    skills=None,
    **kwargs,
) -> MutableAgentCard:
    """
    Safe AgentCard factory for a2a-sdk 1.1.2 + google-cloud-aiplatform 1.163.0.

    Strips incompatible kwargs and ensures GA A2aAgent requirements are met.
    Returns MutableAgentCard so set_up() can mutate the URL at runtime.

    Args:
        name:        Agent display name.
        description: One-line description.
        version:     Semantic version string (default "1.0.0").
        skills:      List of AgentSkill objects.
        **kwargs:    Passed to AgentCard. Incompatible kwargs are stripped.

    Returns:
        MutableAgentCard wrapping the underlying protobuf.
    """
    from a2a.types import AgentCapabilities, AgentInterface

    # Strip kwargs that no longer exist in a2a-sdk 1.1.2 protobuf API
    kwargs.pop("url", None)
    kwargs.pop("preferred_transport", None)

    # GA A2aAgent._is_version_enabled() requires at least one supported_interface.
    # set_up() replaces the placeholder URL with the real RE endpoint at runtime.
    if not kwargs.get("supported_interfaces"):
        kwargs["supported_interfaces"] = [
            AgentInterface(url="http://localhost:9999/")
        ]

    # Sensible defaults
    kwargs.setdefault("capabilities", AgentCapabilities(streaming=False))
    kwargs.setdefault("default_input_modes", ["text/plain"])
    kwargs.setdefault("default_output_modes", ["text/plain"])

    proto = _OrigAgentCard(
        name=name,
        description=description,
        version=version,
        skills=skills or [],
        **kwargs,
    )
    return MutableAgentCard(proto)


# =============================================================================
# Fix 4: Patch GA A2aAgent.__init__
# The GA A2aAgent.__init__ accesses agent_card.preferred_transport.
# In a2a-sdk 1.1.2 the protobuf has no preferred_transport field, so
# getattr raises AttributeError.
# We wrap plain AgentCards in MutableAgentCard before the check runs.
#
# IMPORTANT: Do NOT patch __getstate__ or __setstate__ on A2aAgent.
#   The GA uses json_format to serialize AgentCard → JSON dict.
#   Overriding causes agent_card=None on the remote after unpickling.
#   This was the root cause of attempt 11b failure.
# =============================================================================
from vertexai.agent_engines.templates.a2a import (  # noqa: E402
    A2aAgent as _OrigA2aAgent,
)

_orig_a2a_init = _OrigA2aAgent.__init__


def _patched_a2a_init(self, agent_card, agent_executor_builder=None, **kwargs):
    """
    Patched A2aAgent.__init__ that wraps plain AgentCard in MutableAgentCard
    before the preferred_transport check, preventing AttributeError.
    """
    # Wrap plain protobuf → MutableAgentCard so preferred_transport access
    # returns None (via _overrides miss → getattr on proto → returns default)
    # rather than raising AttributeError.
    if isinstance(agent_card, _OrigAgentCard) and not isinstance(
        agent_card, MutableAgentCard
    ):
        agent_card = MutableAgentCard(agent_card)

    try:
        _orig_a2a_init(
            self,
            agent_card=agent_card,
            agent_executor_builder=agent_executor_builder,
            **kwargs,
        )
    except (AttributeError, ValueError) as exc:
        exc_str = str(exc)
        # Swallow ONLY the known preferred_transport / supported_interfaces
        # check failures. All other errors are re-raised.
        if "preferred_transport" in exc_str or (
            "url" in exc_str and "supported_interfaces" in exc_str
        ):
            # Store essentials so set_up() can proceed on the remote container.
            self._agent_card = agent_card
            self._agent_executor_builder = agent_executor_builder
        else:
            raise


_OrigA2aAgent.__init__ = _patched_a2a_init

# Re-export as A2aAgent — callers use: from a2a_compat import A2aAgent
A2aAgent = _OrigA2aAgent

__all__ = ["A2aAgent", "MutableAgentCard", "create_agent_card"]
