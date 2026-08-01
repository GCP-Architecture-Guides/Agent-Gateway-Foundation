# A2A Migration Experiment Report

<!-- Copyright 2025 Google LLC
Licensed under the Apache License, Version 2.0 -->

> This report documents a real 12-attempt migration of 4 ADK specialist agents
> to native A2A protocol on Vertex AI Reasoning Engine. It is the empirical
> basis for the patterns in `SKILL.md`. Read it when debugging new failures
> or when the error timeline is useful context.

**Date:** 2026-07-29 → 2026-07-30  
**Outcome:** ✅ All 5 agents deployed successfully (4 specialists + 1 orchestrator)

---

## Final Deployed Fleet

| Agent | RE Type | Notes |
|---|---|---|
| orchestrator | `google-adk` | Calls specialists via `RemoteA2aAgent` |
| specialist-1 | `a2a` ✅ | Deployed on attempt 12 |
| specialist-2 | `a2a` ✅ | |
| specialist-3 | `a2a` ✅ | |
| specialist-4 | `a2a` ✅ | |

---

## The Core Problem

`google-cloud-aiplatform 1.163.0` ships an `A2aAgent` template built against
`a2a-sdk ~0.3.x` (pydantic-based). The only available `a2a-sdk` on PyPI is
`1.1.2`, which is **protobuf-based** with breaking API changes. This mismatch
cascades into failures at deploy time, pickle time, and runtime.

---

## Error Timeline — 12 Attempts

### Attempts 1–6: Discovery Phase

Early attempts used `adk deploy` CLI and other approaches that couldn't wrap
agents in `A2aAgent` programmatically. Switched to a Python SDK deploy script
(`deploy_specialist_a2a.sh`) to get full control over the pickle process.

---

### Attempt 7: `No module named 'a2a_compat'`

**Root cause:** `MutableAgentCard` was being pickled by class reference.
The remote container didn't have `a2a_compat.py` and couldn't reconstruct it.

**Fix:** Added `__reduce__` to `MutableAgentCard` to serialize as
`AgentCard.FromString(bytes)` — the remote unpickles a plain `AgentCard`
with no `a2a_compat` dependency.

---

### Attempts 8–9: `No module named 'executor'`

**Root cause (first layer):** `cloudpickle` serialized `MyExecutor` as a
module reference (`executor.MyExecutor`). The remote container had `executor.py`
in `extra_packages` but it wasn't on `sys.path`.

**Fix:** `cloudpickle.register_pickle_by_value(executor_mod)` — serializes
the class definition **inline** in the pickle stream.

**Root cause (second layer, exposed by the first fix):** With pickle-by-value
active, module-level imports of protobuf types
(`from a2a.types import Part, InternalError`) caused
`cannot pickle 'Descriptor' object` because cloudpickle serialized the entire
module including its import-time protobuf dependencies.

**Fix:** Moved **ALL** imports inside method bodies (lazy imports). Only
`import os` and `from typing import NoReturn` allowed at module level.
This single pattern solved BOTH the pickle-descriptor error AND the
module-not-found error.

---

### Attempt 10: `No module named 'a2a.server.apps'`

**Root cause:** The preview `A2aAgent`
(`vertexai.preview.reasoning_engines.templates.a2a`) calls
`from a2a.server.apps.rest.rest_adapter import RESTAdapter` in `set_up()`.
This module does not exist in any released version of `a2a-sdk`.

**Fix:** Switched to the GA `A2aAgent` (`vertexai.agent_engines.templates.a2a`)
which uses `from a2a.server.routes.rest_routes import create_rest_routes` —
this path exists in `a2a-sdk 1.1.2`.

---

### Attempt 11a: `No module named 'sse_starlette'`

**Root cause:** The GA `A2aAgent`'s `create_rest_routes` imports
`sse_starlette.sse.EventSourceResponse` for SSE streaming. This package is
not pre-installed in the RE container. This dependency is **undocumented**.

**Fix:** Added `sse-starlette` to `requirements.txt`.

---

### Attempt 11b: `'NoneType' has no attribute 'supported_interfaces'`

**Root cause:** Custom `__getstate__`/`__setstate__` on `A2aAgent` converted
`AgentCard` to raw protobuf bytes. The GA `A2aAgent`'s built-in `__setstate__`
expects a JSON dict format (`{'__protobuf_AgentCard__': {...}}` via
`json_format`). The format mismatch caused `agent_card` to be `None` after
deserialization, so `set_up()` failed immediately.

**Fix:** Removed all custom `__getstate__`/`__setstate__`. The GA `A2aAgent`
handles serialization correctly. It checks `hasattr(obj, 'DESCRIPTOR')` to
detect protobuf cards — `MutableAgentCard` satisfies this via its `DESCRIPTOR`
property proxy.

---

### Attempt 12: ✅ SUCCESS

All fixes in place. Specialist deployed and confirmed `a2a` type in the
Vertex AI console.

---

### Orchestrator Attempt 1: `agent_card string cannot be empty`

**Root cause:** Specialist card URLs were set via shell `export`. The deploy
script reads from a `.env` file, not the shell environment. The remote
container received empty strings for all card URL env vars, causing
`RemoteA2aAgent` to raise `ValueError`.

**Fix:** Wrote card URLs to `agents/ran-orchestrator/.env` before deploying.

---

### Orchestrator Attempt 2: ✅ SUCCESS

---

## Key Technical Discoveries

1. **Two `A2aAgent` classes exist** in `aiplatform 1.163.0` — only the GA path
   (`vertexai.agent_engines`) works with any released `a2a-sdk`.

2. **`agent_framework = "a2a"`** is a class attribute on GA `A2aAgent` — this
   is how the Vertex AI console identifies the agent type as `a2a`.

3. **GA `A2aAgent` has its own `__getstate__`/`__setstate__`** that converts
   `AgentCard` protobuf to/from JSON dict using `json_format`. Do not override.

4. **`sse-starlette` is an undocumented runtime dependency** of the GA
   `A2aAgent`'s REST routes. Missing it causes silent startup failure.

5. **`MutableAgentCard.DESCRIPTOR` works** because `__getattr__` proxies to
   the underlying protobuf. The GA's `hasattr(obj, 'DESCRIPTOR')` check passes,
   allowing it to use the correct serialization path.

6. **Lazy imports solve two problems at once:** module-not-found on remote
   AND protobuf pickle failures — because the executor class is "hollow" at
   pickle time.

7. **Python SDK deploy script beats `adk deploy` CLI** for A2A deployment —
   full control over pickle registration, `extra_packages`, and shim injection.

---

## What Worked

| Pattern | Why It Works |
|---|---|
| `a2a_compat.py` shim | Single import patches all 4 incompatibilities at import time |
| `MutableAgentCard.__reduce__` | Remote unpickles plain `AgentCard` — no wrapper dependency |
| Lazy imports in executor | "Hollow" class at pickle time — no protobuf at module level |
| GA `A2aAgent` path | Uses actually-released `a2a-sdk` internals |
| Python SDK deploy script | Full control over `cloudpickle` registration |

## What Did NOT Work

| Approach | Why It Failed |
|---|---|
| Preview `A2aAgent` | References `a2a.server.apps` (unreleased) |
| Custom `__getstate__`/`__setstate__` | Conflicts with GA's `json_format` serialization |
| Module-level imports in pickled classes | Protobuf `Descriptor` not picklable |
| Shell `export` for orchestrator env vars | Deploy script reads `.env` file, not shell env |
| Inheriting from `AgentExecutor` | Base class import brings in protobuf at module level |
| Passing directories as `extra_packages` | Path structure preserved — modules not importable |
