---
name: a2a-agent-deploy
description: >
  Use this skill when deploying an ADK agent as an A2aAgent (A2A protocol) to
  Vertex AI Reasoning Engine with a2a-sdk 1.1.2 + google-cloud-aiplatform 1.163.0.
  This skill documents the exact SDK compatibility constraints, required shims,
  serialization patterns, and common pitfalls discovered through 12 deployment
  attempts and extensive trial-and-error. MUST be read before creating any new
  A2A agent deployment or debugging A2A deploy failures.
---

# Deploying ADK Agents as A2A on Vertex AI Reasoning Engine

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

> ⚠️ **Supersedes:** `a2a-agent-runtime` skill — that skill used the preview
> SDK path and older versions. **Do NOT follow it for new deployments.**

**Validated SDK versions (do not deviate):**
```
google-cloud-aiplatform==1.163.0
google-adk==2.5.0
a2a-sdk==1.1.2
sse-starlette  (unpinned — latest)
```

**Full experiment report:** `references/EXPERIMENT_REPORT.md`  
**Compatibility shim source:** `lib/a2a_compat.py`  
**Last validated:** 2026-07-30 · 5 agents deployed successfully

---

## Why This Is Hard

The `google-cloud-aiplatform 1.163.0` `A2aAgent` template was built against
`a2a-sdk ~0.3.x` (pydantic-based). The only available `a2a-sdk` is `1.1.2`,
which is **protobuf-based** with breaking API changes. This version mismatch
causes cascading failures at deploy time, pickle time, and runtime.

The `a2a_compat.py` shim bridges the gap. **It must be imported before anything
else.**

---

## 1. Architecture

```
┌─ Orchestrator (ADK / google-adk) ──────────────────────────────┐
│  Deployed via deploy_single_agent.sh                           │
│  Uses RemoteA2aAgent to call specialists via A2A protocol      │
│  Agent type in Vertex AI console: google-adk                   │
│  Needs specialist card URLs written to a .env file             │
└────────────────────────────────────────────────────────────────┘
         │  RemoteA2aAgent (A2A protocol over HTTPS)
         ▼
┌─ Specialist (A2A) ─────────────────────────────────────────────┐
│  Deployed via deploy_specialist_a2a.sh                         │
│  Agent type in Vertex AI console: a2a                          │
│                                                                │
│  4 required files:                                             │
│    agent.py        ← existing ADK agent, unchanged             │
│    executor.py     ← NEW: lazy-import A2A executor             │
│    a2a_config.py   ← NEW: AgentCard definition                 │
│    requirements.txt ← MODIFIED: add sse-starlette              │
└────────────────────────────────────────────────────────────────┘
```

The orchestrator identifies agents as `a2a` type because the GA `A2aAgent`
has `agent_framework = "a2a"` as a class attribute — this is how the
Vertex AI console displays the agent type.

---

## 2. Required Files Per A2A Specialist

### 2a. `a2a_config.py` — Agent Card

```python
from a2a.types import AgentCard, AgentSkill, AgentCapabilities, AgentInterface

skill = AgentSkill(
    id='your_skill_id',
    name='Skill Name',
    description='What this agent does.',
    tags=['tag1', 'tag2'],
    examples=['Example query 1'],
    input_modes=['text/plain'],
    output_modes=['text/plain'],
)

agent_card = AgentCard(
    name='Your Agent Name',
    description='One-line description.',
    version='1.0.0',
    capabilities=AgentCapabilities(streaming=False),
    default_input_modes=['text/plain'],
    default_output_modes=['text/plain'],
    supported_interfaces=[AgentInterface(url='http://localhost:9999/')],
    skills=[skill],
)
```

> [!IMPORTANT]
> `supported_interfaces` with a **placeholder URL is mandatory**.
> `GA A2aAgent.set_up()` replaces it with the real RE endpoint at runtime.
> Without it, `_is_version_enabled()` returns `False` and `__init__` raises
> `ValueError` before your code even runs.

---

### 2b. `executor.py` — Lazy-Import Executor

> [!CAUTION]
> **ALL imports except `import os` and `from typing import NoReturn` MUST be
> inside method bodies.** This is the single most important rule.
>
> - Module-level protobuf imports → `cannot pickle 'Descriptor' object`
> - Module-level local imports → `No module named 'xxx'` on remote container
> - Type annotations from imported modules → force a module-level import (banned)

```python
import os
from typing import NoReturn
# ─── NOTHING ELSE AT MODULE LEVEL ────────────────────────────────────────────

class YourAgentExecutor:
    """
    NO base class. Removed AgentExecutor to avoid protobuf import at module level.
    GA A2aAgent uses duck typing — it only calls .execute() and .cancel().
    """

    def __init__(self) -> None:
        self.agent = None
        self.runner = None

    def _init_agent(self) -> None:
        """Lazy initialiser — called on first execute(), not at pickle time."""
        if self.agent is not None:
            return
        # ── All heavy imports go here, inside the method ──────────────────
        import vertexai
        from google.adk.artifacts import InMemoryArtifactService
        from google.adk.memory.in_memory_memory_service import InMemoryMemoryService
        from google.adk.runners import Runner
        from google.adk.sessions import InMemorySessionService
        from agent import root_agent as specialist_agent  # local import — OK here

        project  = os.environ.get("GCP_PROJECT_ID", "")
        location = os.environ.get("GOOGLE_CLOUD_LOCATION", "us-central1")
        vertexai.init(project=project, location=location)

        self.agent = specialist_agent
        self.runner = Runner(
            agent=specialist_agent,
            app_name=specialist_agent.name,
            session_service=InMemorySessionService(),
            artifact_service=InMemoryArtifactService(),
            memory_service=InMemoryMemoryService(),
        )

    # ── CORRECT: bare parameter names, no type annotations from imports ───
    async def execute(self, context, event_queue) -> None:
        from a2a.server.tasks import TaskUpdater
        from a2a.types import Part, InternalError

        self._init_agent()
        updater = TaskUpdater(event_queue, context.task_id, context.context_id)
        await updater.submit()
        await updater.start_work()

        try:
            user_input = context.get_user_input()
            session = await self.runner.session_service.create_session(
                app_name=self.agent.name, user_id="a2a-user",
            )
            parts = []
            async for event in self.runner.run_async(
                user_id="a2a-user",
                session_id=session.id,
                new_message=user_input,
            ):
                if hasattr(event, "content") and event.content:
                    for p in event.content.parts:
                        if hasattr(p, "text") and p.text:
                            parts.append(p.text)

            answer = "\n".join(parts) or "No response generated."
            await updater.add_artifact([Part(text=answer)], name="response")
            await updater.complete()

        except Exception as e:
            from a2a.types import InternalError
            await updater.failed(error=InternalError(message=str(e)))

    async def cancel(self, context, event_queue) -> NoReturn:
        from a2a.types import InternalError, UnsupportedOperationError
        raise InternalError(message=UnsupportedOperationError())
```

---

### 2c. `requirements.txt`

```
google-adk==2.5.0
google-cloud-aiplatform[adk,agent_engines]==1.163.0
a2a-sdk==1.1.2
sse-starlette
```

> [!IMPORTANT]
> `sse-starlette` is an **undocumented runtime dependency** of the GA
> `A2aAgent`'s REST routes (`create_rest_routes` imports
> `sse_starlette.sse.EventSourceResponse`). It is NOT pre-installed in the RE
> container. Omitting it causes a silent startup failure — the RE shows ACTIVE
> but all requests return 500.

### 2d. `agent.py` — Unchanged

No modifications to the existing ADK agent. The executor wraps it.

---

## 3. The Compatibility Shim: `a2a_compat.py`

**Source:** `lib/a2a_compat.py` — copy this into your project's `lib/` directory.

Patches **4 incompatibilities** at import time:

| # | Problem | Fix |
|---|---|---|
| 1 | `TransportProtocol` moved from `a2a.types` → `a2a.utils` | Inject back into `a2a.types` |
| 2 | `AgentCard.__init__` no longer accepts `url=`, `preferred_transport=` | `create_agent_card()` strips unknown kwargs, auto-creates `supported_interfaces` |
| 3 | `AgentCard` is immutable protobuf but SDK sets `.url` after construction | `MutableAgentCard` proxy with `__getattr__`/`__setattr__` |
| 4 | `A2aAgent.__init__` accesses `agent_card.preferred_transport` (not in 1.1.2) | Patched `__init__` wraps card before the check |

**Usage — must be the very first import:**

```python
import a2a_compat          # MUST BE FIRST — before any vertexai.agent_engines import
from a2a_compat import A2aAgent, create_agent_card
```

---

## 4. Serialization Rules (cloudpickle)

RE deployment serializes the agent object via `cloudpickle`, ships it to the
remote container, which unpickles it and calls `set_up()`.

### Rule 1 — Register executor for pickle-by-value

```python
import executor as executor_mod
import cloudpickle
cloudpickle.register_pickle_by_value(executor_mod)
```

Without this: `cloudpickle` stores `executor.MyExecutor` as a module reference.
Remote container doesn't have `executor.py` → `No module named 'executor'`.

### Rule 2 — No protobuf types at module level in pickled classes

Any class pickled via `register_pickle_by_value` cannot have protobuf imports
at module level. `cloudpickle` serializes the whole module including
import-time side effects → `cannot pickle 'Descriptor' object`.

### Rule 3 — Do NOT override `__getstate__`/`__setstate__` on `A2aAgent`

The GA `A2aAgent` serializes `AgentCard` as a JSON dict via `json_format`.
Overriding with a bytes-based format causes `agent_card = None` after
remote deserialization (confirmed failure in attempt 11b).

### Rule 4 — `MutableAgentCard.__reduce__` pickles as plain `AgentCard`

```python
def __reduce__(self):
    proto = object.__getattribute__(self, "_proto")
    return (_OrigAgentCard.FromString, (proto.SerializeToString(),))
```

Remote container reconstructs a plain `AgentCard` — no `a2a_compat` dependency.
This works because the GA `__setstate__` handles both JSON dict and raw
`AgentCard` objects via `hasattr(obj, 'DESCRIPTOR')`.

---

## 5. GA vs Preview `A2aAgent` — Critical Difference

> [!CAUTION]
> Two `A2aAgent` classes exist in `google-cloud-aiplatform 1.163.0`.
> **Only the GA path works** with any released version of `a2a-sdk`.

| Import path | `set_up()` uses | Status |
|---|---|---|
| `vertexai.preview.reasoning_engines.templates.a2a` | `a2a.server.apps.rest.rest_adapter.RESTAdapter` | ❌ `a2a.server.apps` does not exist in any released a2a-sdk |
| `vertexai.agent_engines.templates.a2a` | `a2a.server.routes.rest_routes.create_rest_routes` | ✅ Exists in a2a-sdk 1.1.2 |

```python
# ✅ Always use this
from vertexai.agent_engines.templates.a2a import A2aAgent
# (accessed via a2a_compat — which patches it before returning)

# ❌ Never use this
from vertexai.preview.reasoning_engines.templates.a2a import A2aAgent
```

---

## 6. Building and Deploying

```python
import sys
sys.path.insert(0, 'lib')               # so a2a_compat and gateway_agent are findable
sys.path.insert(0, 'agents/my-agent')   # so agent.py is findable

import a2a_compat                        # FIRST — patches TransportProtocol + A2aAgent
from a2a_compat import A2aAgent

import executor as executor_mod
import cloudpickle
cloudpickle.register_pickle_by_value(executor_mod)  # serialize class inline

from a2a_config import agent_card
from executor import MyAgentExecutor

app = A2aAgent(
    agent_card=agent_card,
    agent_executor_builder=MyAgentExecutor,   # ← CLASS reference, NOT an instance
)

# Verify before deploying — must print "a2a"
print(app.agent_framework)

import vertexai
from vertexai import agent_engines
vertexai.init(project=PROJECT_ID, location=REGION)

re = agent_engines.create(
    app,
    requirements=[
        "google-adk==2.5.0",
        "google-cloud-aiplatform[adk,agent_engines]==1.163.0",
        "a2a-sdk==1.1.2",
        "sse-starlette",
    ],
    display_name="my-specialist-agent",
    extra_packages=["agents/my-agent/agent.py"],  # individual files, NOT directories
)
print(f"RE: {re.resource_name}")
print(f"Card URL: https://{REGION}-aiplatform.googleapis.com/v1beta1/{re.resource_name}")
```

> [!IMPORTANT]
> `agent_executor_builder=` takes the **class**, not an instance.
> Passing an instance causes silent failures in `set_up()` on the remote.

---

## 7. Orchestrator Deployment

The orchestrator is a standard **ADK agent** (not A2A) that calls specialists
via `RemoteA2aAgent`. Deploy it with `deploy_single_agent.sh`.

### Step 1 — Write card URLs to `.env` before deploying

```bash
# agents/ran-orchestrator/.env
RAN_SECURITY_CARD_URL=https://REGION-aiplatform.googleapis.com/v1beta1/projects/PROJECT/locations/REGION/reasoningEngines/SPECIALIST_RE_ID
RAN_INSIGHTS_CARD_URL=https://...
```

> [!WARNING]
> **Shell `export` does NOT work.** The deploy script reads from `.env` —
> not from the shell environment. If you only `export` the vars, the remote
> container gets empty strings → `ValueError: agent_card string cannot be empty`.

### Step 2 — Deploy

```bash
bash scripts/deploy_single_agent.sh \
    --name ran-orchestrator \
    --source agents/ran-orchestrator
```

### Step 3 — Clean up immediately

```bash
rm -f agents/ran-orchestrator/.env   # contains live RE endpoints — never commit
```

---

## 8. Anti-Patterns (6 Confirmed Failures)

### ❌ Anti-Pattern 1 — Module-level imports in executor

```python
# BAD
from a2a.types import Part, InternalError   # module-level → pickle failure
class MyExecutor:
    async def execute(self, context, event_queue): ...
```
**Fix:** All imports inside method bodies.

---

### ❌ Anti-Pattern 2 — Inheriting from `AgentExecutor`

```python
# BAD
from a2a.server.agent_execution import AgentExecutor  # triggers protobuf at import
class MyExecutor(AgentExecutor): ...
```
**Fix:** No base class. GA `A2aAgent` uses duck typing.

---

### ❌ Anti-Pattern 3 — Preview `A2aAgent`

```python
# BAD — references a2a.server.apps which doesn't exist
from vertexai.preview.reasoning_engines.templates.a2a import A2aAgent
```
**Fix:** Use `vertexai.agent_engines.templates.a2a`.

---

### ❌ Anti-Pattern 4 — Custom `__getstate__`/`__setstate__`

```python
# BAD — conflicts with GA's json_format serialization
_OrigA2aAgent.__getstate__ = my_custom_getstate   # leaves agent_card=None on remote
```
**Fix:** Let GA `A2aAgent` handle its own serialization.

---

### ❌ Anti-Pattern 5 — Passing directories as `extra_packages`

```python
# BAD — directory retains its path structure, modules not importable
extra_packages=["agents/ran-security/"]
```
**Fix:** Use `cloudpickle.register_pickle_by_value()` for the executor class.
Pass only individual `.py` files (e.g., `agent.py`) in `extra_packages`.

---

### ❌ Anti-Pattern 6 — `ServerError` for error reporting

```python
# BAD — ServerError API changed between 0.3.x and 1.1.2
from a2a.utils.errors import ServerError
await updater.failed(error=ServerError(message="..."))
```
**Fix:** `from a2a.types import InternalError`.

---

## 9. Local Test — Validate Pickle Before Deploying

Always run this locally to catch serialization issues before the 15-min RE deploy cycle:

```python
import sys
sys.path.insert(0, 'lib')
sys.path.insert(0, 'agents/my-agent')

# 1. Compat shim FIRST
import a2a_compat
from a2a_compat import A2aAgent

# 2. Vertexai init
import vertexai
vertexai.init(project='YOUR_PROJECT_ID', location='YOUR_REGION')

# 3. Build app
from a2a_config import agent_card
import executor as executor_mod, cloudpickle
cloudpickle.register_pickle_by_value(executor_mod)
from executor import MyAgentExecutor
app = A2aAgent(agent_card=agent_card, agent_executor_builder=MyAgentExecutor)

# 4. Must print "a2a" — if not, something is wrong
print("framework:", app.agent_framework)

# 5. Pickle roundtrip — simulates what RE deployment does
import io, pickle
buf = io.BytesIO()
cloudpickle.dump(app, buf)
buf.seek(0)

# Simulate remote: remove local paths and modules
del sys.modules['executor']
sys.path = [p for p in sys.path if 'my-agent' not in p]

app2 = pickle.loads(buf.read())

# 6. set_up() — exactly what the remote container calls
app2.set_up()
print("✅ set_up() PASSED — safe to deploy")
```

---

## 10. Reading Remote Container Logs

```bash
gcloud logging read \
  "resource.type=aiplatform.googleapis.com/ReasoningEngine
   AND resource.labels.reasoning_engine_id=YOUR_RE_ID
   AND textPayload:\"user code\"" \
  --project=YOUR_PROJECT_ID \
  --limit=5 \
  --format="value(textPayload)"
```

---

## 11. Error → Fix Lookup

| Error message | Root cause | Fix |
|---|---|---|
| `No module named 'a2a_compat'` | `MutableAgentCard` in pickle stream | Add `__reduce__` → serialize as plain `AgentCard` |
| `No module named 'executor'` | Executor pickled by module reference | `cloudpickle.register_pickle_by_value(executor_mod)` |
| `cannot pickle 'Descriptor' object` | Protobuf import at module level | Move all imports inside methods |
| `No module named 'a2a.server.apps'` | Preview `A2aAgent` path | Switch to `vertexai.agent_engines.templates.a2a` |
| `No module named 'sse_starlette'` | Missing RE dependency | Add `sse-starlette` to `requirements.txt` |
| `'NoneType' has no attr 'supported_interfaces'` | Custom `__getstate__` broke serialization | Remove it — use GA's built-in |
| `agent_card string cannot be empty` | Shell `export` used instead of `.env` | Write card URLs to `.env` file before deploy |
| `ValueError: agent_card string cannot be empty` | Same as above | Same fix |
| `_is_version_enabled() → False` | `supported_interfaces` empty or missing | Add `AgentInterface(url='http://localhost:9999/')` |
| `AttributeError: preferred_transport` | Plain `AgentCard` passed to unpatched `A2aAgent` | `import a2a_compat` first |

---

## 12. Full Deploy Sequence

```bash
# ── Phase 1: Deploy all specialists ──────────────────────────────────────────
for agent in ran-security ran-insights ran-usecase ran-anomaly; do
    bash scripts/deploy_specialist_a2a.sh --name "$agent"
done
# Each script prints the RE ID and A2A card URL — save these

# ── Phase 2: Write orchestrator .env ────────────────────────────────────────
cat > agents/ran-orchestrator/.env << EOF
RAN_SECURITY_CARD_URL=https://REGION-aiplatform.googleapis.com/v1beta1/projects/PROJECT/locations/REGION/reasoningEngines/SECURITY_RE_ID
RAN_INSIGHTS_CARD_URL=https://REGION-aiplatform.googleapis.com/v1beta1/projects/PROJECT/locations/REGION/reasoningEngines/INSIGHTS_RE_ID
RAN_USECASE_CARD_URL=https://REGION-aiplatform.googleapis.com/v1beta1/projects/PROJECT/locations/REGION/reasoningEngines/USECASE_RE_ID
RAN_ANOMALY_CARD_URL=https://REGION-aiplatform.googleapis.com/v1beta1/projects/PROJECT/locations/REGION/reasoningEngines/ANOMALY_RE_ID
EOF

# ── Phase 3: Deploy orchestrator ─────────────────────────────────────────────
bash scripts/deploy_single_agent.sh \
    --name ran-orchestrator \
    --source agents/ran-orchestrator

# ── Phase 4: Clean up ────────────────────────────────────────────────────────
rm -f agents/ran-orchestrator/.env
```

---

## 13. SDK Quick Reference

```python
# ✅ Correct imports (a2a-sdk 1.1.2)
from a2a.types import (
    AgentCard, AgentSkill, AgentCapabilities, AgentInterface,
    Part,                      # NOT TextPart (doesn't exist)
    InternalError,             # NOT ServerError (changed in 1.1.2)
    UnsupportedOperationError,
)
from a2a.utils import TransportProtocol  # moved from a2a.types in 1.1.2
from a2a.server.tasks import TaskUpdater
# (import these INSIDE methods, not at module level)

# ✅ Orchestrator import path
from google.adk.agents.remote_a2a_agent import RemoteA2aAgent
# NOT: from google.adk.agents.a2a import RemoteA2aAgent

# ✅ Correct A2aAgent call signature
A2aAgent(
    agent_card=agent_card,
    agent_executor_builder=MyExecutorClass,  # class, not instance
)
```
