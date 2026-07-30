---
name: a2a-agent-runtime
description: >
  Use this skill when deploying a multi-agent A2A (Agent-to-Agent) system on
  Vertex AI Reasoning Engines using google-adk==1.31.1, google-cloud-aiplatform==1.149.0,
  and a2a-sdk==1.1.2. Covers the complete workflow: redeploying specialist agents
  as A2aAgent, building the orchestrator with RemoteA2aAgent, and the SDK-version-
  specific gotchas discovered through real-world test deployment. MUST be read
  before writing any a2a_config.py, executor.py, or orchestrator agent.py.
---

# A2A Agent Runtime Skill

<!-- Copyright 2025 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

This code is for PoC environment only.
This demo code is not built for production workload. -->

## Overview

This skill documents deploying a multi-agent A2A system where:
- **Specialists** are existing ADK/GatewayAgent Reasoning Engines, redeployed
  as `A2aAgent` (wrapping an `AgentExecutor` that calls the existing agent).
- **Orchestrator** is a new `LlmAgent` (or `GatewayAgent`) with `RemoteA2aAgent`
  sub-agents, each pointing to a specialist's A2A card URL.

**Validated SDK versions:**
```
google-cloud-aiplatform==1.149.0
google-adk==1.31.1
a2a-sdk==1.1.2
```

---

## CRITICAL: Four Bugs in Official Docs (Read Before Writing Any Code)

### Bug 1 — `A2aApp` Does Not Exist → Use `A2aAgent`

```python
# ❌ WRONG — A2aApp is not in google-cloud-aiplatform==1.149.0
from vertexai.preview.reasoning_engines.templates.a2a import A2aApp

# ✅ CORRECT
from vertexai.preview.reasoning_engines.templates.a2a import A2aAgent
```

### Bug 2 — `create_agent_card()` Is Broken → Build `AgentCard` Directly

```python
# ❌ BROKEN — internally imports TransportProtocol from a2a.types (doesn't exist in 1.1.2)
from vertexai.preview.reasoning_engines.templates.a2a import create_agent_card

# ✅ CORRECT — construct directly
from a2a.types import AgentCard, AgentCapabilities, AgentInterface, AgentSkill

agent_card = AgentCard(
    name="My Agent",
    description="...",
    version="1.0.0",
    capabilities=AgentCapabilities(streaming=False),
    default_input_modes=["text/plain"],
    default_output_modes=["text/plain"],
    # AgentCard is PROTOBUF — url is NOT a top-level field
    supported_interfaces=[AgentInterface(url="http://localhost:9999/")],
    skills=[skill],
)
```

> **Important:** `AgentCard` is a **protobuf class**, not Pydantic, in a2a-sdk==1.1.2.
> Field names differ from older docs. There is no top-level `url=` field;
> use `supported_interfaces=[AgentInterface(url="...")]`.

### Bug 3 — `TextPart` Does Not Exist → Use `Part`

```python
# ❌ WRONG — TextPart is not in a2a-sdk==1.1.2
from a2a.types import TextPart
await updater.add_artifact([TextPart(text=answer)], name="response")

# ✅ CORRECT
from a2a.types import Part
await updater.add_artifact([Part(text=answer)], name="response")
```

`Part` fields in 1.1.2: `text`, `raw`, `url`, `data`, `metadata`, `filename`, `media_type`.

### Bug 4 — `google-adk[a2a]` Installs a Non-Existent a2a-sdk Version

```bash
# ❌ WRONG — [a2a] extra pins a2a-sdk>=0.3.4,<0.4.0 which is NOT on PyPI
pip install "google-adk[a2a]==1.31.1"

# ✅ CORRECT — install a2a-sdk separately
pip install google-adk==1.31.1 a2a-sdk==1.1.2
```

---

## Verified Code Patterns

### `a2a_config.py` — Skill and AgentCard

```python
from a2a.types import AgentSkill, AgentCard, AgentCapabilities, AgentInterface

skill = AgentSkill(
    id="my_agent_skill",
    name="My Agent Skill",
    description="What this specialist does.",
    tags=["tag1", "tag2"],
    examples=["Example query the user might ask"],
    input_modes=["text/plain"],
    output_modes=["text/plain"],
)

AGENT_CARD = AgentCard(
    name="My Agent",
    description="What this specialist does.",
    version="1.0.0",
    capabilities=AgentCapabilities(streaming=False),
    default_input_modes=["text/plain"],
    default_output_modes=["text/plain"],
    supported_interfaces=[AgentInterface(url="http://localhost:9999/")],
    skills=[skill],
)
```

### `executor.py` — AgentExecutor Wrapping an Existing Agent

```python
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import TaskUpdater
from a2a.types import UnsupportedOperationError, Part   # ← Part, NOT TextPart
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from .agent import root_agent   # your existing ADK/GatewayAgent


class MyAgentExecutor(AgentExecutor):

    def __init__(self):
        session_service = InMemorySessionService()
        self._runner = Runner(
            agent=root_agent,
            app_name=root_agent.name,
            session_service=session_service,
        )

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        updater = TaskUpdater(event_queue, context.task_id, context.context_id)
        await updater.submit()
        await updater.start_work()
        try:
            query = context.get_user_input()
            session = await self._runner.session_service.create_session(
                app_name=root_agent.name, user_id="a2a-user",
            )
            parts = []
            async for event in self._runner.run_async(
                user_id="a2a-user", session_id=session.id, new_message=query,
            ):
                if hasattr(event, "content") and event.content:
                    for p in event.content.parts:
                        if hasattr(p, "text") and p.text:
                            parts.append(p.text)

            answer = "\n".join(parts) or "No response generated."
            await updater.add_artifact([Part(text=answer)], name="response")
            await updater.complete()
        except Exception as e:
            await updater.failed(str(e))

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        raise UnsupportedOperationError()
```

### `agent.py` — Specialist RE Entry Point

```python
from vertexai.preview.reasoning_engines.templates.a2a import A2aAgent  # NOT A2aApp
from .a2a_config import AGENT_CARD
from .executor import MyAgentExecutor

app = A2aAgent(
    agent_card=AGENT_CARD,
    agent_executor=MyAgentExecutor(),
)
```

### Orchestrator `agent.py`

```python
import os, httpx
from google.auth import default
from google.auth.transport.requests import Request as AuthRequest
# ✅ CORRECT import — NOT from google.adk.agents.a2a
from google.adk.agents.remote_a2a_agent import RemoteA2aAgent
from google.adk.agents import LlmAgent


class GoogleCloudAuth(httpx.Auth):
    def __init__(self):
        self.credentials, _ = default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
    def auth_flow(self, request):
        if not self.credentials.valid:
            self.credentials.refresh(AuthRequest())
        request.headers["Authorization"] = f"Bearer {self.credentials.token}"
        yield request


def _remote(env_var: str, name: str, description: str) -> RemoteA2aAgent:
    url = os.environ.get(env_var, "")
    if not url:
        raise EnvironmentError(f"{env_var} is not set — deploy the specialist RE first.")
    return RemoteA2aAgent(
        agent_card_url=url, agent_name=name,
        description=description, http_auth=GoogleCloudAuth(),
    )


root_agent = LlmAgent(
    name="orchestrator",
    model="gemini-2.5-flash",
    description="Orchestrates specialist agents.",
    instruction="Route queries to specialist sub-agents and synthesize responses.",
    sub_agents=[
        _remote("SPECIALIST_1_CARD_URL", "specialist_1", "Does X"),
        _remote("SPECIALIST_2_CARD_URL", "specialist_2", "Does Y"),
    ],
)
```

---

## requirements.txt (Verified)

**Specialists:**
```
google-adk>=1.31.1
google-cloud-aiplatform[adk,agent_engines]==1.149.0
a2a-sdk==1.1.2
```

**Orchestrator:**
```
google-adk>=1.31.1
google-cloud-aiplatform[adk,agent_engines]==1.149.0
a2a-sdk==1.1.2
httpx>=0.27.0
google-auth>=2.29.0
```

---

## Deployment Order

1. **Delete old specialist REs** — `A2aAgent` can't update an existing `AdkApp` RE in-place.
2. **Deploy each specialist** as `A2aAgent` via `ReasoningEngine.create(app, ...)`.
3. **Wait for ACTIVE**, then **wait 2-3 more minutes** for the `/.a2a` endpoint to initialize.
4. **Collect A2A card URLs** → format: `https://REGION-aiplatform.googleapis.com/v1beta1/projects/PROJECT/locations/REGION/reasoningEngines/RE_ID/.a2a`
5. **Set env vars** in orchestrator's `.env`: `SPECIALIST_1_CARD_URL=...`
6. **Deploy orchestrator** as standard `AdkApp` (or `GatewayAgent` if behind Agent Gateway).

---

## Confirmed Gotchas

| Gotcha | Status | Fix |
|---|---|---|
| `A2aApp` vs `A2aAgent` | ✅ Confirmed | Use `A2aAgent` |
| `create_agent_card()` broken | ✅ Confirmed | Build `AgentCard` directly |
| `TextPart` missing | ✅ Confirmed | Use `Part` |
| `google-adk[a2a]` wrong dep | ✅ Confirmed | Install `a2a-sdk==1.1.2` separately |
| Old RE not deleted before redeploy | ✅ Confirmed | Always delete first — no upsert path |
| Card URL 404 right after ACTIVE | ⚠️ Not yet tested | Wait 2-3 min after ACTIVE |
| `httpx.AsyncClient` pickling | ⚠️ Not yet tested | Move auth client init inside `_init_agent()` if hit |
| Module import path in container | ✅ Confirmed | Use `from agent import root_agent` (flat package) |
| Env vars not set | ✅ Confirmed | `RemoteA2aAgent` crashes on empty URL — validate first |
| `new_agent_text_message` missing | ⚠️ Likely | Not in `a2a.utils` 1.1.2 — use `Part(text=...)` |
| `TransportProtocol` in `a2a.types` | ✅ Confirmed missing | It's in `a2a.utils`, not `a2a.types` |

---

## SDK Quick Reference (a2a-sdk==1.1.2)

```python
# a2a.types — available
from a2a.types import (
    AgentSkill, AgentCard, AgentCapabilities, AgentInterface,
    Part,                    # ← NOT TextPart
    UnsupportedOperationError,
)

# a2a.utils — available
from a2a.utils import (
    AGENT_CARD_WELL_KNOWN_PATH, DEFAULT_RPC_URL,
    TransportProtocol,       # ← moved here from types
    constants, errors, proto_utils, to_stream_response,
)

# a2a.server — available
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import TaskUpdater

# google.adk.agents — correct import path
from google.adk.agents.remote_a2a_agent import RemoteA2aAgent   # ← correct
# NOT: from google.adk.agents.a2a import RemoteA2aAgent         # ← wrong module

# vertexai — correct class name
from vertexai.preview.reasoning_engines.templates.a2a import A2aAgent   # ← correct
# NOT: A2aApp                                                             # ← doesn't exist
```
