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

"""redeploy_orchestrator.py — Deploy store_concierge orchestrator.

Deploys the store_concierge orchestrator using AdkApp + AgentEngine.create().
Uses the same cloudpickle + gateway_patch pattern as deploy_a2a_agent.py,
but is streamlined for the orchestrator-specific layout.

Post-deploy applies:
  1. contextSpec PATCH   — prevents DNS crash on container startup
  2. classMethods PATCH  — 24 methods (google-adk(a2a) classification)
  3. agentCard PATCH     — required for A2A badge in console
  4. labels PATCH        — role=orchestrator, team=food-court
  5. IAM grants          — 7 roles to WIF principal (same as specialists)

Usage:
    python scripts/redeploy_orchestrator.py --project geap-agw --region us-east1
"""

import argparse
import importlib
import json
import logging
import sys
import urllib.request

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("redeploy_orch")

# The 13 standard ADK classMethods
ADK_METHODS = [
    {"name": "stream_query",
     "description": "ADK stream query",
     "parameters": {"type": "object", "properties": {
         "message": {"type": "string"}, "user_id": {"type": "string"}
     }, "required": ["message"]}, "api_mode": "stream"},
    {"name": "query",
     "description": "ADK query (non-streaming)",
     "parameters": {"type": "object", "properties": {
         "message": {"type": "string"}, "user_id": {"type": "string"}
     }, "required": ["message"]}, "api_mode": ""},
    {"name": "get_session",          "description": "ADK get session",    "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "list_sessions",        "description": "ADK list sessions",  "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "create_session",       "description": "ADK create session", "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "delete_session",       "description": "ADK delete session", "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "list_turns",           "description": "ADK list turns",     "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "list_events",          "description": "ADK list events",    "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "register_operations",  "description": "ADK register ops",   "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "get_session_metadata", "description": "ADK session meta",   "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "update_session_metadata", "description": "ADK update meta", "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "clone_session",        "description": "ADK clone session",  "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "delete_sessions",      "description": "ADK delete sessions","parameters": {"type": "object"}, "api_mode": ""},
]

# The 11 A2A protocol methods
A2A_METHODS = [
    {"name": "on_message_send",                        "description": "A2A send message",             "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "on_get_task",                            "description": "A2A get task",                 "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "on_list_tasks",                          "description": "A2A list tasks",               "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "on_cancel_task",                         "description": "A2A cancel task",              "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "on_create_task_push_notification_config","description": "A2A create push notif",        "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "on_get_task_push_notification_config",   "description": "A2A get push notif",           "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "on_list_task_push_notification_configs", "description": "A2A list push notifs",         "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "on_delete_task_push_notification_config","description": "A2A delete push notif",        "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "on_message_send_stream",                 "description": "A2A stream message",           "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "on_subscribe_to_task",                   "description": "A2A subscribe to task",        "parameters": {"type": "object"}, "api_mode": ""},
    {"name": "on_get_extended_agent_card",             "description": "A2A get agent card",           "parameters": {"type": "object"}, "api_mode": ""},
]


def get_token():
    import google.auth
    import google.auth.transport.requests
    creds, _ = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    creds.refresh(google.auth.transport.requests.Request())
    return creds.token


def api_patch(url, token, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url, data=data, method="PATCH",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def delete_existing(project, region, display_name, token):
    url = (f"https://{region}-aiplatform.googleapis.com/v1beta1/"
           f"projects/{project}/locations/{region}/reasoningEngines")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        engines = json.loads(resp.read()).get("reasoningEngines", [])
    deleted = 0
    for e in engines:
        if e.get("displayName") == display_name:
            del_url = (f"https://{region}-aiplatform.googleapis.com/v1beta1/"
                       f"{e['name']}?force=true")
            req = urllib.request.Request(del_url, method="DELETE",
                                         headers={"Authorization": f"Bearer {token}"})
            with urllib.request.urlopen(req, timeout=30) as r:
                logger.info("Deleted existing RE: %s → %s", e["name"], r.status)
            deleted += 1
    return deleted


def patch_a2a_classification(project, region, re_id, token):
    base = f"https://{region}-aiplatform.googleapis.com/v1beta1"
    re_url = f"{base}/projects/{project}/locations/{region}/reasoningEngines/{re_id}"

    req = urllib.request.Request(re_url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        current = json.loads(resp.read())

    existing_methods = current.get("spec", {}).get("classMethods", [])
    existing_names = {m["name"] if isinstance(m, dict) else m for m in existing_methods}

    combined = list(existing_methods)
    for m in A2A_METHODS:
        if m["name"] not in existing_names:
            combined.append(m)

    patch_url = f"{re_url}?updateMask=spec.agentFramework,spec.classMethods"
    code, _ = api_patch(patch_url, token, {
        "spec": {"agentFramework": "google-adk", "classMethods": combined}
    })
    logger.info("A2A classification PATCH: HTTP %d — %d methods total", code, len(combined))
    return code in (200, 202)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--project", required=True, help="GCP project ID")
    p.add_argument("--region",  required=True, help="GCP region (e.g. us-east1)")
    p.add_argument("--agent-dir",  default=None,
                   help="Path to orchestrator agent dir (default: agents/orchestrator)")
    args = p.parse_args()

    # Locate orchestrator
    import os
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    agent_dir = args.agent_dir or os.path.join(root, "agents", "orchestrator")

    logger.info("Agent dir: %s", agent_dir)
    logger.info("Project  : %s / %s", args.project, args.region)

    # Load orchestrator requirements
    reqs_file = os.path.join(agent_dir, "requirements.txt")
    requirements = []
    if os.path.exists(reqs_file):
        with open(reqs_file) as f:
            requirements = [l.strip() for l in f if l.strip() and not l.startswith("#") and not l.startswith("--")]
    # Ensure core packages are present. Pinned versions are the validated
    # combination for google-adk(a2a) on Vertex AI RE. Read from
    # requirements.txt where possible; script pins are last-resort fallbacks.
    core = {"google-adk", "google-cloud-aiplatform", "cloudpickle", "requests"}
    req_names = {r.split("==")[0].split(">=")[0].split("[")[0].lower() for r in requirements}
    if "cloudpickle" not in req_names:
        requirements.append("cloudpickle>=3.0.0")
    logger.info("Requirements: %d packages", len(requirements))

    import cloudpickle
    import vertexai
    from vertexai.agent_engines import AgentEngine

    vertexai.init(
        project=args.project,
        location=args.region,
        staging_bucket=f"gs://{args.project}-staging",
    )

    token = get_token()

    # gateway_agent is a package at lib/gateway_agent/ — add lib/ to sys.path
    lib_dir = os.path.join(root, "lib")
    for d in [lib_dir, agent_dir]:
        if d not in sys.path:
            sys.path.insert(0, d)

    # Set env vars needed by orchestrator at import time
    os.environ.setdefault("GCP_PROJECT_ID", args.project)
    os.environ.setdefault("GCP_REGION", args.region)
    os.environ.setdefault("GOOGLE_CLOUD_PROJECT", args.project)

    # Import using import statement so cloudpickle.register_pickle_by_value works.
    # spec_from_file_location won't work — cloudpickle requires sys.modules entry.
    import gateway_agent as gwa_mod
    cloudpickle.register_pickle_by_value(gwa_mod)

    # Remove stale 'agent' module if this script has been run before
    sys.modules.pop("agent", None)
    agent_module = importlib.import_module("agent")
    cloudpickle.register_pickle_by_value(agent_module)

    root_agent = agent_module.root_agent
    logger.info("Loaded root_agent: %s (model=%s)", root_agent.name,
                getattr(root_agent, "model", "?"))

    # Record existing REs to clean up AFTER successful deploy
    display_name = "store_concierge"
    logger.info("Recording existing '%s' REs for post-deploy cleanup...", display_name)
    existing_re_ids = []
    try:
        url = (f"https://{args.region}-aiplatform.googleapis.com/v1beta1/"
               f"projects/{args.project}/locations/{args.region}/reasoningEngines")
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            engines = json.loads(resp.read()).get("reasoningEngines", [])
        existing_re_ids = [e["name"] for e in engines if e.get("displayName") == display_name]
        logger.info("Found %d existing '%s' RE(s) to clean up post-deploy.", len(existing_re_ids), display_name)
    except Exception as e:
        logger.warning("Could not list existing REs: %s", e)

    # Deploy
    logger.info("Deploying %s to %s/%s ...", display_name, args.project, args.region)
    logger.info("This takes 3–6 minutes.")

    # Pass gateway_agent as extra_packages so it gets installed in the container.
    # The RE container runs 'pip install extra_packages/*.whl' at startup.
    # Without this, import gateway_agent fails at module load time.
    gateway_agent_dir = os.path.join(root, "lib", "gateway_agent")

    remote = AgentEngine.create(
        agent_engine=root_agent,
        requirements=requirements,
        extra_packages=[gateway_agent_dir],
        display_name=display_name,
        description="Store Concierge — routes food orders to pizza, burger, and sushi specialists.",
    )

    re_id = remote.resource_name.split("/")[-1]
    logger.info("✅ Deployed: %s (RE ID: %s)", remote.resource_name, re_id)

    # Post-deploy cleanup: remove old store_concierge REs now that new one is live
    if existing_re_ids:
        logger.info("Cleaning up %d old RE(s)...", len(existing_re_ids))
        token = get_token()  # refresh token after long deploy
        for old_name in existing_re_ids:
            try:
                del_url = (f"https://{args.region}-aiplatform.googleapis.com/v1beta1/"
                           f"{old_name}?force=true")
                req = urllib.request.Request(del_url, method="DELETE",
                                             headers={"Authorization": f"Bearer {token}"})
                with urllib.request.urlopen(req, timeout=30) as r:
                    logger.info("  Deleted old RE %s → HTTP %d", old_name.split("/")[-1], r.status)
            except Exception as e:
                logger.warning("  Could not delete old RE %s: %s", old_name, e)

    # Strip contextSpec
    base_url = (f"https://{args.region}-aiplatform.googleapis.com/v1beta1/"
                f"{remote.resource_name}")
    code, _ = api_patch(f"{base_url}?updateMask=contextSpec", token,
                        {"contextSpec": {}})
    logger.info("contextSpec PATCH: HTTP %d", code)

    # Apply google-adk(a2a) classification
    logger.info("Applying google-adk(a2a) classification...")
    ok = patch_a2a_classification(args.project, args.region, re_id, token)
    if ok:
        logger.info("✅ google-adk(a2a) classification applied")
    else:
        logger.warning("⚠️ Classification PATCH failed — apply manually")

    # agentCard — required for A2A badge in console
    # updateMask MUST be snake_case: spec.agent_card (not spec.agentCard)
    token = get_token()  # refresh after long classMethods PATCH

    # project_num is the numeric project number (not project ID string).
    # Resolved here early so it can be reused for both agentCard URL and IAM WIF.
    import subprocess as _sp
    try:
        project_num_str = _sp.check_output(
            ["gcloud", "projects", "describe", args.project,
             "--format=value(projectNumber)"],
            stderr=_sp.DEVNULL,
        ).decode().strip()
        org_id = _sp.check_output(
            ["gcloud", "organizations", "list", "--format=value(ID)", "--limit=1"],
            stderr=_sp.DEVNULL,
        ).decode().strip()
    except _sp.CalledProcessError:
        project_num_str = ""
        org_id = ""

    agent_card_body = {
        "name": display_name,
        "description": "Store Concierge — routes food orders to pizza, burger, and sushi specialists.",
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
        "skills": [{
            "id": "food-concierge-skill",
            "name": display_name,
            "description": "Routes food orders to the right specialist (pizza, burger, sushi).",
            "tags": ["food-court", "orchestrator"],
        }],
        "url": (
            f"https://{args.region}-aiplatform.googleapis.com/v1beta1/"
            f"projects/{project_num_str or args.project}/locations/{args.region}/"
            f"reasoningEngines/{re_id}/a2a"
        ),
    }
    code, _ = api_patch(
        f"{base_url}?updateMask=spec.agent_card", token,
        {"spec": {"agentCard": agent_card_body}},
    )
    logger.info("agentCard PATCH: HTTP %d", code)

    # Labels
    code, _ = api_patch(f"{base_url}?updateMask=labels", token, {
        "labels": {
            "role": "orchestrator",
            "team": "food-court",
            "capability": "food-concierge",
        }
    })
    logger.info("Labels PATCH: HTTP %d", code)

    # IAM — same 7 roles as deploy_a2a_agent.py (project_num_str + org_id resolved above)
    import subprocess
    if not project_num_str or not org_id:
        # Retry in case the earlier _sp call failed
        try:
            project_num_str = project_num_str or subprocess.check_output(
                ["gcloud", "projects", "describe", args.project,
                 "--format=value(projectNumber)"],
                stderr=subprocess.DEVNULL,
            ).decode().strip()
            org_id = org_id or subprocess.check_output(
                ["gcloud", "organizations", "list", "--format=value(ID)", "--limit=1"],
                stderr=subprocess.DEVNULL,
            ).decode().strip()
        except subprocess.CalledProcessError:
            pass

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
        logger.warning("⚠️ Could not determine project number or org ID — IAM grant skipped for RE %s", re_id)

    print(f"\n{'='*60}")
    print(f"  ✅ store_concierge Deploy Complete")
    print(f"{'='*60}")
    print(f"  Agent   : {display_name}")
    print(f"  RE ID   : {re_id}")
    print(f"  Project : {args.project} / {args.region}")
    print(f"  Console : https://console.cloud.google.com/vertex-ai/agent-registry?project={args.project}")
    print(f"\n  RE_ID={re_id}")
    print(f"  RESOURCE={remote.resource_name}")


if __name__ == "__main__":
    main()
