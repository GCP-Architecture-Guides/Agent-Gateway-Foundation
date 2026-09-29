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
# This demo code is not built for production workload.

"""deploy_a2a_specialist.py — Deploy a single A2A specialist agent to Vertex AI RE.

WHY a Python script instead of `adk deploy agent_engine` CLI:
  `adk deploy` creates a standard AdkApp / ReasoningEngine, NOT an A2aAgent.
  A2aAgent requires different RE routes (/a2a/message:send) that only
  vertexai.agent_engines.create() sets up correctly via the A2aAgent template.

Usage:
    python3 scripts/deploy_a2a_specialist.py \\
        --agent-dir     agents/pizza-agent \\
        --display-name  pizza_specialist \\
        --project       PROJECT_ID \\
        --region        us-east1 \\
        --bucket        gs://PROJECT_ID-staging \\
        --ingress       projects/P/locations/R/agentGateways/PREFIX-ingress-gateway \\
        --egress        projects/P/locations/R/agentGateways/PREFIX-egress-gateway

Output (on success, printed to stdout):
    RE_ID=1234567890
    CARD_URL=https://us-east1-aiplatform.googleapis.com/v1beta1/projects/.../reasoningEngines/1234567890

These lines are captured by the shell wrapper scripts (deploy_pizza_agent.sh etc.)
and written to agents/orchestrator/.env so the orchestrator knows the sub-agent URLs.
"""

import argparse
import os
import sys

# ---------------------------------------------------------------------------
# CRITICAL: a2a_compat MUST be imported before ANY vertexai or a2a import.
# Patches TransportProtocol, MutableAgentCard, and A2aAgent.__init__
# incompatibilities between a2a-sdk 1.1.2 and google-cloud-aiplatform 1.163.0.
# ---------------------------------------------------------------------------
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_LIB_DIR = os.path.join(_SCRIPT_DIR, "..", "lib")
sys.path.insert(0, _LIB_DIR)

import a2a_compat  # noqa: E402, F401  — patches applied on import
from a2a_compat import A2aAgent  # noqa: E402

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parser = argparse.ArgumentParser(
    description="Deploy an A2A specialist agent to Vertex AI Reasoning Engine.",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog=__doc__,
)
parser.add_argument("--agent-dir",     required=True,  help="Directory containing agent.py, executor.py, a2a_config.py")
parser.add_argument("--display-name",  required=True,  help="RE display name (valid Python identifier; use underscores)")
parser.add_argument("--project",       required=True,  help="GCP project ID")
parser.add_argument("--region",        required=True,  help="GCP region for RE deployment (e.g. us-east1)")
parser.add_argument("--bucket",        required=True,  help="GCS staging bucket (gs://...)")
parser.add_argument("--ingress",       default="",     help="Ingress gateway resource name")
parser.add_argument("--egress",        default="",     help="Egress gateway resource name")
parser.add_argument("--agent-name",    default="",     help="AGENT_NAME env var (defaults to --display-name)")
args = parser.parse_args()

agent_dir    = os.path.abspath(args.agent_dir)
display_name = args.display_name
project      = args.project
region       = args.region
bucket       = args.bucket
ingress      = args.ingress
egress       = args.egress
agent_name   = args.agent_name or display_name

# ---------------------------------------------------------------------------
# Validate agent directory
# ---------------------------------------------------------------------------
for required_file in ("agent.py", "executor.py", "a2a_config.py"):
    path = os.path.join(agent_dir, required_file)
    if not os.path.isfile(path):
        print(f"[deploy_a2a] ERROR: {required_file} not found at {path}", file=sys.stderr)
        sys.exit(1)

print(f"[deploy_a2a] Deploying '{display_name}' from {agent_dir}", file=sys.stderr)
print(f"[deploy_a2a] Project: {project} | Region: {region} | Bucket: {bucket}", file=sys.stderr)

# ---------------------------------------------------------------------------
# Add agent directory to sys.path so executor.py / a2a_config.py are importable
# (they are imported lazily inside A2aAgent or cloudpickle, but must be findable)
# ---------------------------------------------------------------------------
if agent_dir not in sys.path:
    sys.path.insert(0, agent_dir)

# ---------------------------------------------------------------------------
# Import executor module and register for pickle-by-value.
# CRITICAL: cloudpickle serialises executor class by reference by default.
# register_pickle_by_value forces inline serialisation so the RE container
# doesn't need to import the executor module from pip — it has the code inline.
# ---------------------------------------------------------------------------
import importlib.util
import cloudpickle

# Load executor module from agent directory
_executor_spec = importlib.util.spec_from_file_location(
    "executor", os.path.join(agent_dir, "executor.py")
)
executor_mod = importlib.util.module_from_spec(_executor_spec)
_executor_spec.loader.exec_module(executor_mod)
sys.modules["executor"] = executor_mod

cloudpickle.register_pickle_by_value(executor_mod)
print("[deploy_a2a] Registered executor module for pickle-by-value", file=sys.stderr)

# Find the executor class (first class defined in executor.py)
executor_class = None
for attr_name in dir(executor_mod):
    attr = getattr(executor_mod, attr_name)
    if (
        isinstance(attr, type)
        and attr.__module__ == executor_mod.__name__
        and hasattr(attr, "execute")
        and hasattr(attr, "cancel")
    ):
        executor_class = attr
        print(f"[deploy_a2a] Found executor class: {attr_name}", file=sys.stderr)
        break

if executor_class is None:
    print("[deploy_a2a] ERROR: No executor class with execute() + cancel() found in executor.py", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Load agent card from a2a_config.py
# ---------------------------------------------------------------------------
_config_spec = importlib.util.spec_from_file_location(
    "a2a_config", os.path.join(agent_dir, "a2a_config.py")
)
config_mod = importlib.util.module_from_spec(_config_spec)
_config_spec.loader.exec_module(config_mod)

agent_card = getattr(config_mod, "agent_card", None)
if agent_card is None:
    print("[deploy_a2a] ERROR: 'agent_card' not found in a2a_config.py", file=sys.stderr)
    sys.exit(1)
print(f"[deploy_a2a] Agent card: {agent_card.name}", file=sys.stderr)

# ---------------------------------------------------------------------------
# Wrap in MutableAgentCard if not already (a2a_compat fix 3)
# ---------------------------------------------------------------------------
from a2a_compat import MutableAgentCard  # noqa: E402
if not isinstance(agent_card, MutableAgentCard):
    agent_card = MutableAgentCard(agent_card)

# ---------------------------------------------------------------------------
# Build A2aAgent app (patched via a2a_compat)
# ---------------------------------------------------------------------------
print("[deploy_a2a] Building A2aAgent...", file=sys.stderr)
app = A2aAgent(
    agent_card=agent_card,
    agent_executor_builder=executor_class,
)

# Verify A2aAgent framework label (must be 'a2a' not 'google-adk')
try:
    framework = getattr(app, "agent_framework", getattr(app, "_agent_framework", "unknown"))
    print(f"[deploy_a2a] agent_framework = {framework!r}", file=sys.stderr)
    if str(framework) not in ("a2a", "unknown"):
        print(f"[deploy_a2a] WARNING: unexpected agent_framework '{framework}' — expected 'a2a'", file=sys.stderr)
except Exception:
    pass

# ---------------------------------------------------------------------------
# Delete any existing RE with the same display name (clean re-deploy)
# ---------------------------------------------------------------------------
import vertexai  # noqa: E402
import google.auth  # noqa: E402
import google.auth.transport.requests  # noqa: E402
import requests as _http_requests  # noqa: E402

vertexai.init(project=project, location=region, staging_bucket=bucket)

print(f"[deploy_a2a] Checking for existing REs named '{display_name}'...", file=sys.stderr)
creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
creds.refresh(google.auth.transport.requests.Request())

_base_url = f"https://{region}-aiplatform.googleapis.com/v1beta1/projects/{project}/locations/{region}/reasoningEngines"
_headers = {"Authorization": f"Bearer {creds.token}"}

try:
    resp = _http_requests.get(_base_url, headers=_headers, timeout=30)
    resp.raise_for_status()
    existing = [
        e for e in resp.json().get("reasoningEngines", [])
        if e.get("displayName") == display_name
    ]
    for eng in existing:
        eng_name = eng["name"]
        print(f"[deploy_a2a] Deleting existing RE: {eng_name}", file=sys.stderr)
        del_resp = _http_requests.delete(
            f"https://{region}-aiplatform.googleapis.com/v1beta1/{eng_name}?force=true",
            headers=_headers, timeout=30,
        )
        print(f"[deploy_a2a] Delete response: {del_resp.status_code}", file=sys.stderr)
        if del_resp.status_code in (200, 202):
            import time
            for _ in range(18):
                time.sleep(5)
                op = del_resp.json()
                op_name = op.get("name", "")
                if op.get("done"):
                    break
                if op_name:
                    poll = _http_requests.get(
                        f"https://{region}-aiplatform.googleapis.com/v1beta1/{op_name}",
                        headers=_headers, timeout=30,
                    )
                    if poll.json().get("done"):
                        break
            print(f"[deploy_a2a] Deleted: {eng_name}", file=sys.stderr)
except Exception as e:
    print(f"[deploy_a2a] WARNING: cleanup check failed: {e} — continuing", file=sys.stderr)

# ---------------------------------------------------------------------------
# Build extra_packages list
# ---------------------------------------------------------------------------
_lib_dir = os.path.join(_SCRIPT_DIR, "..", "lib")
_gateway_agent_dir = os.path.join(_lib_dir, "gateway_agent")
_a2a_compat_file = os.path.join(_lib_dir, "a2a_compat.py")

extra_packages = []

# Agent source files
for fname in ("agent.py", "executor.py", "a2a_config.py"):
    fpath = os.path.join(agent_dir, fname)
    if os.path.isfile(fpath):
        extra_packages.append(fpath)

# a2a_compat shim — must be in container for MutableAgentCard.__reduce__ reference
if os.path.isfile(_a2a_compat_file):
    extra_packages.append(_a2a_compat_file)

# gateway_agent SDK library (GatewayAgent, GlobalGemini, telemetry)
if os.path.isdir(_gateway_agent_dir):
    extra_packages.append(_gateway_agent_dir)
else:
    print(f"[deploy_a2a] WARNING: gateway_agent dir not found at {_gateway_agent_dir}", file=sys.stderr)

print(f"[deploy_a2a] extra_packages: {[os.path.basename(p) for p in extra_packages]}", file=sys.stderr)

# ---------------------------------------------------------------------------
# Deploy to Vertex AI RE
# GOOGLE_CLOUD_LOCATION=global is passed as an env var so the GatewayAgent
# inside the executor routes model inference to aiplatform.googleapis.com.
# The RE itself is deployed in `region` (control plane location).
# ---------------------------------------------------------------------------
print("[deploy_a2a] Creating Reasoning Engine (this takes 3-8 minutes)...", file=sys.stderr)

remote_app = vertexai.agent_engines.create(
    app,
    requirements=[
        "google-adk==2.5.0",
        "google-cloud-aiplatform[adk,agent_engines]==1.163.0",
        "a2a-sdk==1.1.2",
        "sse-starlette",
        "httpx>=0.27.0",
        "requests>=2.31.0,<3.0.0",
    ],
    extra_packages=extra_packages,
    display_name=display_name,
    environment_variables={
        "GOOGLE_CLOUD_PROJECT":   project,
        "GOOGLE_CLOUD_LOCATION":  "global",      # model endpoint: aiplatform.googleapis.com
        "GCP_REGION":             region,         # real region for sessions / OTEL
        "AGENT_NAME":             agent_name,
        "AGENT_GATEWAY_INGRESS":  ingress,
        "AGENT_GATEWAY_EGRESS":   egress,
        # OTEL mTLS / timeout fixes (same as deploy_global_agent.sh)
        "GOOGLE_API_USE_MTLS_ENDPOINT":     "never",
        "OTEL_EXPORTER_OTLP_TIMEOUT":       "2000",
        "OTEL_BSP_EXPORT_TIMEOUT_MILLIS":   "2000",
        "OTEL_BSP_SCHEDULE_DELAY_MILLIS":   "15000",
        "GOOGLE_API_USE_CLIENT_CERTIFICATE": "false",
    },
)

# ---------------------------------------------------------------------------
# Extract RE ID and card URL
# ---------------------------------------------------------------------------
re_resource_name = remote_app.resource_name
re_id = re_resource_name.split("/")[-1]
card_url = (
    f"https://{region}-aiplatform.googleapis.com/v1beta1/{re_resource_name}"
)

print(f"[deploy_a2a] SUCCESS: RE deployed: {re_resource_name}", file=sys.stderr)

# Output to stdout — captured by shell wrapper
print(f"RE_ID={re_id}")
print(f"CARD_URL={card_url}")
print(f"RESOURCE_NAME={re_resource_name}")
