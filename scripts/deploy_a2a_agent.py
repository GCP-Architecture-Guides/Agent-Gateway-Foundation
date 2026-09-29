#!/usr/bin/env python3
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

"""deploy_a2a_agent.py — Deploy food-court agents as google-adk(a2a) using AgentEngine.create().

Validated pattern (mirrors fiveg-ran-agent/foundation/scripts/deploy_a2a_agent.py):
  1. A2aAgent wrapper with AgentCard + A2aAgentExecutor
  2. AgentEngine.create() (gateway patch injects org-policy fields via .pth)
  3. Post-deploy PATCH: agentFramework=google-adk + merged 24 classMethods
  4. Strip contextSpec (prevents DNS crash on startup — Caveat #8)
  5. Set agentCard (required for console A2A label — Caveat #19)
  6. Capability labels for AgentRegistry discovery
  7. IAM grants to WIF principal (all 6 mandatory roles)

WHY AgentEngine.create() not adk deploy:
  adk deploy agent_engine (ADK 2.5.0) uses vertexai.Client/agentplatform.Client
  which bypasses AuthorizedSession — gateway patch cannot intercept.
  AgentEngine.create() goes through the patched transport layer.
  (Caveat #15 in a2a-agent-deploy skill)

Requirements (exact versions):
  google-cloud-aiplatform[agent_engines,adk]==1.162.0
  google-adk[agent-identity,a2a,mcp]==2.5.0
  a2a-sdk[http-server]==1.1.2

Usage:
    cd mod-agw-foundation-pub/
    export AGENT_GATEWAY_INGRESS="projects/geap-agw/.../geap-ingress-gateway"
    export AGENT_GATEWAY_EGRESS="projects/geap-agw/.../geap-egress-gateway"

    .venv/bin/python scripts/deploy_a2a_agent.py \\
        --agent pizza-agent \\
        --project geap-agw \\
        --region us-east1 \\
        --display-name pizza_specialist \\
        --capability pizza-ordering \\
        --team food-court
"""

import argparse
import importlib
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error
import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("deploy_a2a")


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--agent", required=True,
                   help="Agent directory name under agents/ (e.g. 'pizza-agent')")
    p.add_argument("--project", required=True, help="GCP project ID")
    p.add_argument("--region", required=True, help="GCP region (e.g. us-east1)")
    p.add_argument("--display-name", default=None,
                   help="RE display name (default: agent dir name)")
    p.add_argument("--capability", default=None,
                   help="Capability label for AgentRegistry discovery")
    p.add_argument("--team", default="food-court",
                   help="Team label")
    p.add_argument("--role", default="specialist",
                   help="Role label: 'specialist' or 'orchestrator'")
    p.add_argument("--org-id", default=None,
                   help="GCP org ID for WIF principal (auto-detected via gcloud if omitted)")
    p.add_argument("--extra-env", action="append", default=[], metavar="KEY=VALUE",
                   help="Extra env var to inject into AdkApp env_vars (repeatable). "
                        "Used to pass SPECIALIST_*_RE_NAME for orchestrator PSC VPC discovery.")
    return p.parse_args()


def get_token():
    import google.auth
    import google.auth.transport.requests
    creds, _ = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    creds.refresh(google.auth.transport.requests.Request())
    return creds.token


def rest_patch(region, project, re_id, token, update_mask, body):
    url = (
        f"https://{region}-aiplatform.googleapis.com/v1beta1"
        f"/projects/{project}/locations/{region}/reasoningEngines/{re_id}"
        f"?updateMask={update_mask}"
    )
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        method="PATCH",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return 200, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        err = e.read().decode(errors="replace")
        logger.warning("PATCH %s → HTTP %d: %s", update_mask, e.code, err[:400])
        return e.code, {}


def rest_get(region, project, re_id, token):
    url = (
        f"https://{region}-aiplatform.googleapis.com/v1beta1"
        f"/projects/{project}/locations/{region}/reasoningEngines/{re_id}"
    )
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def delete_existing(region, project, display_name, token):
    """Delete any existing RE with matching displayName (idempotent redeploy)."""
    url = (
        f"https://{region}-aiplatform.googleapis.com/v1beta1"
        f"/projects/{project}/locations/{region}/reasoningEngines"
    )
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            engines = json.loads(resp.read()).get("reasoningEngines", [])
    except Exception:
        return

    for engine in [e for e in engines if e.get("displayName") == display_name]:
        rname = engine["name"]
        logger.info("Deleting existing RE: %s", rname)
        del_req = urllib.request.Request(
            f"https://{region}-aiplatform.googleapis.com/v1beta1/{rname}?force=true",
            method="DELETE",
            headers={"Authorization": f"Bearer {token}"},
        )
        try:
            with urllib.request.urlopen(del_req, timeout=30) as resp:
                op = json.loads(resp.read())
            op_name = op.get("name", "")
            for _ in range(24):
                if op.get("done"):
                    break
                time.sleep(5)
                try:
                    poll = urllib.request.Request(
                        f"https://{region}-aiplatform.googleapis.com/v1beta1/{op_name}",
                        headers={"Authorization": f"Bearer {token}"},
                    )
                    with urllib.request.urlopen(poll, timeout=30) as pr:
                        op = json.loads(pr.read())
                except Exception:
                    pass
            logger.info("Deleted: %s", rname)
        except Exception as e:
            logger.warning("Delete failed: %s", e)


def main():
    args = parse_args()

    root_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    agent_dir = os.path.join(root_dir, "agents", args.agent)
    display_name = args.display_name or args.agent

    if not os.path.isdir(agent_dir):
        logger.error("Agent directory not found: %s", agent_dir)
        sys.exit(1)

    # Set env vars for agent module import
    os.environ["GCP_PROJECT_ID"] = args.project
    os.environ["GOOGLE_CLOUD_PROJECT"] = args.project
    os.environ["GOOGLE_CLOUD_LOCATION"] = args.region

    # ── [1] Import agent module with cloudpickle.register_pickle_by_value ──────
    # Caveat #16: cloudpickle records defining module name 'agent'.
    # RE container won't have 'agent' on sys.path → ModuleNotFoundError.
    # register_pickle_by_value serializes module contents INLINE.
    import cloudpickle

    if agent_dir not in sys.path:
        sys.path.insert(0, agent_dir)

    logger.info("Importing agent module from %s ...", agent_dir)
    if "agent" in sys.modules:
        del sys.modules["agent"]

    agent_module = importlib.import_module("agent")
    cloudpickle.register_pickle_by_value(agent_module)
    logger.info("Registered agent module for inline pickle serialization")

    # Register transitive local modules (food_court_backend, prompt, etc.)
    for mod_name, mod in list(sys.modules.items()):
        if (mod and hasattr(mod, "__file__") and mod.__file__
                and agent_dir in (mod.__file__ or "")):
            try:
                cloudpickle.register_pickle_by_value(mod)
                logger.info("Registered transitive module: %s", mod_name)
            except Exception as e:
                logger.warning("Could not register %s: %s", mod_name, e)

    root_agent = agent_module.root_agent
    logger.info("Loaded root_agent: %s (model=%s)",
                root_agent.name, getattr(root_agent, "model", "?"))

    # ── [2] Build AgentSkill metadata (for post-deploy agentCard PATCH) ──────────
    # NOTE: We use AdkApp (not A2aAgent) because A2aAgent creates an A2A-only
    # HTTP container that rejects stream_query with 307 Redirect → 404.
    # AdkApp serves the standard stream_reasoning_engine endpoint (stream_query).
    # The google-adk(a2a) console badge is metadata-only — achieved via
    # post-deploy PATCH (classMethods + agentCard). No container change needed.
    # See: a2a-agent-deploy skill §8 Path A vs Path B.
    from a2a.types import AgentSkill

    skills_config = getattr(agent_module, "AGENT_SKILLS_CONFIG", None)
    if skills_config:
        skills = [
            AgentSkill(
                id=s["id"],
                name=s["name"],
                description=s["description"],
                tags=s.get("tags", []),
            )
            for s in skills_config
        ]
    else:
        skills = [
            AgentSkill(
                id=f"{display_name}-skill",
                name=display_name,
                description=root_agent.description or f"{display_name} specialist",
                tags=[display_name, args.team],
            )
        ]

    # ── [3] Init Vertex AI ─────────────────────────────────────────────────────
    import vertexai
    from vertexai.agent_engines import AgentEngine

    vertexai.init(
        project=args.project,
        location=args.region,
        # Use the shared staging bucket but a per-agent GCS dir to prevent
        # race conditions when deploying in parallel (Caveat: bucket names
        # cannot contain slashes — per-agent isolation is via gcs_dir_name).
        staging_bucket=f"gs://{args.project}-staging",
    )
    logger.info("vertexai.init() done → project=%s location=%s", args.project, args.region)

    # ── [4] Wrap in AdkApp (standard ADK container — serves stream_query) ────────
    _agent = root_agent
    _app_name = display_name
    from vertexai.preview.reasoning_engines import AdkApp
    from google.adk.sessions.in_memory_session_service import InMemorySessionService as _IMSS
    from google.adk.memory.in_memory_memory_service import InMemoryMemoryService as _IMMS
    from google.adk.artifacts.in_memory_artifact_service import InMemoryArtifactService as _IMAS
    # ── PSC VPC hardening: patch AdkApp + register module for value-based pickle ──
    #
    # PROBLEM: AdkApp in PSC VPC containers crashes at set_up() with Code 3.
    # TWO crash paths confirmed from live container logs (2026-09-15):
    #
    #   PATH 1 — set_up() line 883: self.project_id()
    #     → resource_manager_utils.get_project_id(project) → gRPC to Cloud Resource Manager
    #     → PSC VPC raises ServiceUnavailable (code 14) — NOT caught by base failsafe
    #       (only catches PermissionDenied/Unauthenticated)
    #     FIX: patch project_id() to return project string directly, zero network calls.
    #
    #   PATH 2 — set_up() line 882: _default_instrumentor_builder(enable_logging=True)
    #     → CloudLoggingExporter.__init__() → network call to Cloud Logging API → blocked
    #     → NOTE: env_vars applied at line 888 AFTER instrumentor at line 882 — too late!
    #     FIX: patch _telemetry_enabled()/_tracing_enabled() to return False,
    #          preventing CloudLoggingExporter from being constructed at all.
    #
    # WHY MONKEYPATCH ALONE FAILS:
    #   cloudpickle serializes installed packages by MODULE REFERENCE (path string only).
    #   Container unpickles → imports fresh AdkApp from package → gets unpatched original.
    #   Local tests pass (same process has patched class) but container always gets original.
    #
    # THE FIX: cloudpickle.register_pickle_by_value(adk_module)
    #   Forces cloudpickle to embed the patched AdkApp CLASS BYTECODE inline in the pickle.
    #   Container unpickles → uses embedded class definition with patches → no network calls.
    #   Verified in fresh subprocess simulating PSC VPC: set_up() completes, Runner created.
    #
    # WHY NOT SafeAdkApp SUBCLASS:
    #   AgentEngine.create() calls clone() before pickling (SDK line 1067-1069).
    #   AdkApp.clone() hardcodes `return AdkApp(...)` — subclass is stripped silently.
    #
    adk_module = importlib.import_module(
        "vertexai.preview.reasoning_engines.templates.adk"
    )
    cloudpickle.register_pickle_by_value(adk_module)

    AdkApp.project_id = lambda self: self._tmpl_attrs.get("project")
    AdkApp._telemetry_enabled = lambda self: False
    AdkApp._tracing_enabled = lambda self: False
    logger.info(
        "Registered adk module for value-based pickling + patched AdkApp "
        "(project_id, telemetry, tracing) for PSC VPC Code 3 fix"
    )

    # Build base env_vars
    _env_vars = {
        # Disable MTLS/Certificate-based access — blocked in PSC VPC
        "GOOGLE_API_USE_CLIENT_CERTIFICATE": "false",
        "GOOGLE_API_USE_MTLS_ENDPOINT": "never",
        # Defense-in-depth: disable telemetry via env var too
        # (_telemetry_enabled() patch handles set_up() but this covers other paths)
        "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY": "false",
        # Ensure correct project is set (read lazily by @property in agent code)
        "GOOGLE_CLOUD_PROJECT": args.project,
        "GOOGLE_CLOUD_LOCATION": args.region,
        "GCP_PROJECT_ID": args.project,
        "GCP_REGION": args.region,
    }
    # Merge --extra-env flags (e.g. SPECIALIST_PIZZA_ORDERING_RE_NAME=projects/...)
    for kv in getattr(args, "extra_env", []):
        if "=" in kv:
            k, v = kv.split("=", 1)
            _env_vars[k.strip()] = v.strip()
            logger.info("Extra env: %s=%s", k.strip(), v.strip())
        else:
            logger.warning("Skipping malformed --extra-env (no '='): %s", kv)

    adk_app = AdkApp(
        agent=_agent,
        session_service_builder=lambda: _IMSS(),
        memory_service_builder=lambda: _IMMS(),
        artifact_service_builder=lambda: _IMAS(),
        env_vars=_env_vars,
    )
    logger.info("AdkApp wrapper created for agent: %s", _app_name)

    # ── [5] Read requirements.txt ───────────────────────────────────────────────
    req_file = os.path.join(agent_dir, "requirements.txt")
    if os.path.exists(req_file):
        with open(req_file) as f:
            requirements = [
                line.strip() for line in f
                if line.strip() and not line.startswith("#")
            ]
    else:
        # Fallback requirements when agent has no requirements.txt.
        # Versions pinned here are the validated combination for google-adk(a2a) on
        # Vertex AI RE. Update when upgrading the stack.
        requirements = [
            "google-cloud-aiplatform[agent_engines,adk]==1.162.0",
            "google-adk[agent-identity,a2a,mcp]==2.5.0",
            "a2a-sdk[http-server]==1.1.2",
            "google-genai",
            "pydantic",
            "cloudpickle>=3.0.0",
            "google-auth",
            "requests",
            "google-cloud-firestore",
        ]
    logger.info("Requirements: %d packages", len(requirements))

    # ── [6] Cleanup existing RE with same display name ──────────────────────────
    token = get_token()
    logger.info("Checking for existing '%s' RE...", display_name)
    delete_existing(args.region, args.project, display_name, token)

    # ── [6] Deploy via AgentEngine.create() ────────────────────────────────────
    # The gateway .pth patch intercepts this REST call and injects:
    #   - agentGatewayConfig into spec.deploymentSpec (Caveat #17)
    #   - identityType=AGENT_IDENTITY (required by org policy)
    #   - OTEL env vars (required by org policy)
    logger.info("Deploying %s → %s/%s (3–8 min)...", display_name, args.project, args.region)

    remote = AgentEngine.create(
        agent_engine=adk_app,
        requirements=requirements,
        display_name=display_name,
        description=root_agent.description or f"{display_name} agent",
        gcs_dir_name=display_name,  # per-agent subdir prevents parallel-deploy GCS race condition
    )

    re_id = remote.resource_name.split("/")[-1]
    logger.info("✅ Deployed: %s  RE_ID=%s", remote.resource_name, re_id)

    # Refresh token after long deploy
    token = get_token()

    # ── [7] Post-deploy: Strip contextSpec (Caveat #8) ─────────────────────────
    logger.info("Stripping contextSpec...")
    code, _ = rest_patch(
        args.region, args.project, re_id, token,
        update_mask="contextSpec",
        body={"contextSpec": {}},
    )
    logger.info("contextSpec PATCH → HTTP %d", code)

    # ── [8] Post-deploy: google-adk(a2a) classification (24 classMethods) ──────
    # AdkApp sets agentFramework='google-adk' + 13 ADK methods.
    # google-adk(a2a) requires agentFramework='google-adk' + 24 merged methods.
    # We PATCH to merge 13 ADK methods + 11 A2A protocol methods = 24 total.
    # This is pure metadata — the container behavior is unchanged (stream_query works).
    logger.info("Patching for google-adk(a2a) (24 classMethods)...")
    try:
        from google.adk.cli.cli_deploy import _AGENT_ENGINE_CLASS_METHODS
        adk_methods = list(_AGENT_ENGINE_CLASS_METHODS)
    except ImportError:
        logger.warning("Could not import _AGENT_ENGINE_CLASS_METHODS — using fallback list")
        adk_methods = [
            {"name": m, "description": m, "parameters": {"type": "object"}, "api_mode": ""}
            for m in [
                "stream_query", "query", "set_up", "clone", "delete",
                "get_schema", "predict", "explain", "batch_predict",
                "raw_predict", "raw_predict_sse", "list_operations", "get_operation",
            ]
        ]

    re_data = rest_get(args.region, args.project, re_id, token)
    a2a_methods = re_data.get("spec", {}).get("classMethods", [])
    adk_names = {(m["name"] if isinstance(m, dict) else m) for m in adk_methods}
    a2a_only = [m for m in a2a_methods
                if (m["name"] if isinstance(m, dict) else m) not in adk_names]
    combined = list(adk_methods) + a2a_only
    logger.info("classMethods: %d ADK + %d A2A-only = %d total",
                len(adk_methods), len(a2a_only), len(combined))

    code, _ = rest_patch(
        args.region, args.project, re_id, token,
        update_mask="spec.agentFramework,spec.classMethods",
        body={"spec": {"agentFramework": "google-adk", "classMethods": combined}},
    )
    logger.info("classMethods PATCH → HTTP %d", code)

    # ── [9] Post-deploy: agentCard (required for console A2A label) ────────────
    # updateMask MUST be snake_case: spec.agent_card (not spec.agentCard)
    token = get_token()
    project_num = re_data.get("name", "").split("/")[1]
    agent_card_body = {
        "name": display_name,
        "description": root_agent.description or f"{display_name} specialist",
        "supportedInterfaces": [{
            # localhost:9999 is an intentional A2A protocol sentinel —
            # Vertex AI RE has no public hostname; the real endpoint is
            # set in agentCard.url below. The supportedInterfaces.url
            # field is required by the A2A spec but unused at runtime.
            "url": "http://localhost:9999/",
            "protocolBinding": "HTTP+JSON",
            "protocolVersion": "1.0",
        }],
        "version": "1.0.0",
        "capabilities": {"streaming": True, "extendedAgentCard": True},
        "defaultInputModes": ["text/plain"],
        "defaultOutputModes": ["application/json"],
        "skills": [
            {"id": s.id, "name": s.name, "description": s.description,
             "tags": list(s.tags or [])}
            for s in skills
        ],
        "url": (
            f"https://{args.region}-aiplatform.googleapis.com/v1beta1/"
            f"projects/{project_num}/locations/{args.region}/"
            f"reasoningEngines/{re_id}/a2a"
        ),
    }
    code, _ = rest_patch(
        args.region, args.project, re_id, token,
        update_mask="spec.agent_card",
        body={"spec": {"agentCard": agent_card_body}},
    )
    logger.info("agentCard PATCH → HTTP %d", code)

    # ── [10] Apply capability labels ────────────────────────────────────────────
    labels = {"role": args.role, "team": args.team}
    if args.capability:
        labels["capability"] = args.capability

    token = get_token()
    code, _ = rest_patch(
        args.region, args.project, re_id, token,
        update_mask="labels",
        body={"labels": labels},
    )
    logger.info("Labels PATCH → HTTP %d  labels=%s", code, labels)

    # ── [11] Grant IAM roles to WIF principal ───────────────────────────────────
    try:
        project_num_str = subprocess.check_output(
            ["gcloud", "projects", "describe", args.project,
             "--format=value(projectNumber)"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        org_id = args.org_id or subprocess.check_output(
            ["gcloud", "organizations", "list", "--format=value(ID)", "--limit=1"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except subprocess.CalledProcessError:
        project_num_str = ""
        org_id = args.org_id

    if project_num_str and org_id:
        wif = (
            f"principal://agents.global.org-{org_id}.system.id.goog"
            f"/resources/aiplatform/projects/{project_num_str}"
            f"/locations/{args.region}/reasoningEngines/{re_id}"
        )
        logger.info("Granting IAM to WIF: %s", wif)
        iam_roles = [
            "roles/aiplatform.user",
            "roles/cloudtrace.agent",
            "roles/logging.logWriter",
            "roles/aiplatform.sessionUser",
            "roles/serviceusage.serviceUsageConsumer",
            "roles/iap.egressor",
            "roles/datastore.user",
        ]
        for role in iam_roles:
            result = subprocess.run(
                ["gcloud", "projects", "add-iam-policy-binding", args.project,
                 f"--member={wif}", f"--role={role}",
                 "--condition=None", "--quiet"],
                capture_output=True, text=True,
            )
            status = "✅" if result.returncode == 0 else "⚠️ "
            logger.info("  %s %s", status, role)
    else:
        logger.warning("Could not determine project number — IAM grant skipped for RE %s", re_id)

    # ── Summary ─────────────────────────────────────────────────────────────────
    print(f"\n{'='*60}")
    print(f"  ✅ google-adk(a2a) Deploy Complete")
    print(f"{'='*60}")
    print(f"  Agent     : {args.agent}")
    print(f"  Display   : {display_name}")
    print(f"  RE ID     : {re_id}")
    print(f"  Resource  : {remote.resource_name}")
    print(f"  Labels    : {labels}")
    print(f"  Methods   : {len(combined)} (target=24 for google-adk(a2a))")
    print(f"\n  RE_ID={re_id}")
    print(f"  RESOURCE={remote.resource_name}")


if __name__ == "__main__":
    main()
