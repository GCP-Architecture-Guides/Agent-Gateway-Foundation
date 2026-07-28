#!/usr/bin/env python3
"""
patch_sdk_for_rest_create.py  (v4 — wheel-injecting)

Extends v3 with a new capability: when GATEWAY_AGENT_WHEEL_PATH env var is
set (pointing to a local .whl file), the patch intercepts the CREATE body's
inline_source.source_archive (a BASE64 gzip tarball) and injects the wheel
at the TARBALL ROOT level (not inside agent_tmp.../).

Background
----------
The Vertex AI RE container extracts the source_archive tarball under /code/.
The staging dir (agent_tmp.../) becomes a subdirectory:
    /code/agent_tmp.../requirements.txt
    /code/agent_tmp.../gateway_agent/

pip is invoked as:
    poetry run pip install -r ./agent_tmp.../requirements.txt

pip resolves `./gateway_agent-X.whl` relative to CWD (/code/), so it looks
at /code/gateway_agent-X.whl.  If the wheel is ONLY inside agent_tmp.../,
pip can't find it.

Fix: add the wheel at the tarball root (no directory prefix), so after
extraction:
    /code/gateway_agent-0.1.0-py3-none-any.whl   ← pip finds it ✅
    /code/agent_tmp.../gateway_agent-0.1.0-...whl ← still there too (harmless)

The requirements.txt (already modified by deploy_chat_agent.sh) has:
    ./gateway_agent-0.1.0-py3-none-any.whl

pip resolves this relative to /code/ → /code/gateway_agent-0.1.0-py3-none-any.whl
→ found → installs successfully → `from gateway_agent import GatewayAgent` works.

Method: writes _gateway_patch.py + _gateway_patch.pth into the ADK venv's
site-packages. Python auto-processes .pth files at startup — so the patch
applies before any SDK code runs, for ALL Python subprocesses.
"""
import argparse
import glob
import os
import sys


PATCH_MODULE = "_gateway_patch"


def find_site_packages(venv_dir: str) -> str:
    matches = glob.glob(
        os.path.join(venv_dir, "lib", "python*", "site-packages")
    )
    if not matches:
        raise FileNotFoundError(
            f"Cannot find site-packages in venv: {venv_dir!r}"
        )
    return sorted(matches)[-1]


# --------------------------------------------------------------------------
# The code that will be written into <site-packages>/_gateway_patch.py
# ALL print() calls use file=_sys.stderr to avoid stdout pollution.
# --------------------------------------------------------------------------
PATCH_PY = r'''
"""
_gateway_patch.py — auto-imported via _gateway_patch.pth at Python startup.

Monkey-patches ReasoningEngineClientWithOverride.create_reasoning_engine
so every gRPC CREATE call is redirected to a REST v1beta1 API call that
includes the 3 org-policy-required fields.

Also intercepts the inline_source.source_archive in the CREATE body to
inject the gateway_agent wheel at the tarball root level so the RE container
can find it as /code/gateway_agent-X.whl when pip installs requirements.

ALL output goes to STDERR — never stdout.
"""
import os as _os
import sys as _sys
import json as _json
import urllib.request as _urllib
import urllib.error as _urlerr

_INGRESS = _os.environ.get("AGENT_GATEWAY_INGRESS", "")
_EGRESS  = _os.environ.get("AGENT_GATEWAY_EGRESS", "")
_OTEL_VARS = [
    ("GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY",         "true"),
    ("OTEL_SEMCONV_STABILITY_OPT_IN",                      "gen_ai_latest_experimental"),
    ("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT", "EVENT_ONLY"),
    ("agent_name", "chat-agent-v1"),
    ("agent_description", "A foundational chat agent demonstrating security integrations."),
    ("agent_department", "engineering"),
    ("agent_team", "sec-ops"),
    ("agent_role", "customer-support"),
]


def _inject_wheel_into_archive(body):
    """
    If GATEWAY_AGENT_WHEEL_PATH env var is set, inject the wheel at the
    root level of the BASE64 gzip source_archive in the body so the RE
    container's pip can find it at /code/<wheel>.whl.
    """
    wheel_path = _os.environ.get("GATEWAY_AGENT_WHEEL_PATH", "")
    if not wheel_path or not _os.path.isfile(wheel_path):
        return body  # no wheel to inject

    import base64 as _b64
    import io as _io
    import tarfile as _tf
    import os.path as _op

    wheel_basename = _op.basename(wheel_path)

    # Navigate the body to find the source_archive field.
    # The SDK may use either camelCase or snake_case keys.
    try:
        spec = body.get("spec", {})
        # Try camelCase (standard REST JSON)
        src_spec = spec.get("sourceCodeSpec", spec.get("source_code_spec", {}))
        inline = src_spec.get("inlineSource", src_spec.get("inline_source", {}))
        archive_b64 = inline.get("sourceArchive", inline.get("source_archive", ""))

        if not archive_b64:
            print("[gateway_patch] No source_archive found in body — skipping wheel inject",
                  file=_sys.stderr, flush=True)
            return body

        # Decode and re-pack with wheel at root level
        archive_bytes = _b64.b64decode(archive_b64)
        new_buf = _io.BytesIO()

        with _tf.open(fileobj=_io.BytesIO(archive_bytes), mode="r:gz") as old_tar, \
             _tf.open(fileobj=new_buf, mode="w:gz") as new_tar:
            # Copy all existing members from the original archive
            for member in old_tar.getmembers():
                file_obj = old_tar.extractfile(member)
                if file_obj is not None:
                    new_tar.addfile(member, file_obj)
                else:
                    new_tar.addfile(member)  # directory entries

            # Add wheel at the ARCHIVE ROOT (no agent_tmp.../ prefix)
            # This puts it at /code/<wheel>.whl after extraction
            with open(wheel_path, "rb") as wf:
                wheel_data = wf.read()
            info = _tf.TarInfo(name=wheel_basename)
            info.size = len(wheel_data)
            import time as _time
            info.mtime = int(_time.time())
            info.mode = 0o644
            new_tar.addfile(info, _io.BytesIO(wheel_data))

        new_buf.seek(0)
        new_b64 = _b64.b64encode(new_buf.read()).decode("utf-8")

        # Write back to body — handle both camelCase and snake_case
        if "sourceCodeSpec" in spec:
            if "inlineSource" in spec["sourceCodeSpec"]:
                spec["sourceCodeSpec"]["inlineSource"]["sourceArchive"] = new_b64
            elif "inline_source" in spec["sourceCodeSpec"]:
                spec["sourceCodeSpec"]["inline_source"]["source_archive"] = new_b64
        elif "source_code_spec" in spec:
            if "inline_source" in spec["source_code_spec"]:
                spec["source_code_spec"]["inline_source"]["source_archive"] = new_b64

        old_kb = len(archive_bytes) // 1024
        new_kb = len(_b64.b64decode(new_b64)) // 1024
        print(f"[gateway_patch] Injected wheel '{wheel_basename}' into source_archive "
              f"({old_kb}KB → {new_kb}KB, +{len(wheel_data)}B)",
              file=_sys.stderr, flush=True)
    except Exception as exc:
        import traceback as _tb
        print(f"[gateway_patch] Wheel injection failed (non-fatal): {exc}",
              file=_sys.stderr, flush=True)
        _tb.print_exc(file=_sys.stderr)

    return body


def _rest_create(original_self, request=None, *, parent=None,
                 reasoning_engine=None, retry=None, timeout=None,
                 metadata=None, **kw):
    """REST replacement for gRPC create_reasoning_engine."""
    import google.auth as _ga
    import google.auth.transport.requests as _gatr
    from google.protobuf import json_format as _jf

    # Normalise args: gRPC client accepts a request wrapper OR keyword args
    if request is not None and hasattr(request, "reasoning_engine"):
        _re  = request.reasoning_engine
        _par = request.parent
    else:
        _re  = reasoning_engine
        _par = parent

    # proto -> dict (camelCase for REST)
    re_dict = _jf.MessageToDict(_re._pb, preserving_proto_field_name=False)

    # Inject org-policy mandatory fields
    spec = re_dict.setdefault("spec", {})
    spec["identityType"] = "AGENT_IDENTITY"

    ds = spec.setdefault("deploymentSpec", {})
    ds["agentGatewayConfig"] = {
        "clientToAgentConfig":   {"agentGateway": _INGRESS},
        "agentToAnywhereConfig": {"agentGateway": _EGRESS},
    }
    env   = ds.setdefault("env", [])
    have  = {e.get("name") for e in env}
    for k, v in _OTEL_VARS:
        if k not in have:
            env.append({"name": k, "value": v})

    # Parse project + location from parent path
    parts   = (_par or "").split("/")
    project = parts[1] if len(parts) > 1 else ""
    loc     = parts[3] if len(parts) > 3 else "us-central1"
    url = (f"https://{loc}-aiplatform.googleapis.com/v1beta1/"
           f"projects/{project}/locations/{loc}/reasoningEngines")

    creds, _ = _ga.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    creds.refresh(_gatr.Request())

    body = _json.dumps(re_dict).encode()
    req  = _urllib.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {creds.token}",
        "Content-Type":  "application/json",
    })
    display = re_dict.get("displayName", "?")
    print(f"[gateway_patch] REST CREATE -> {display}", file=_sys.stderr, flush=True)
    try:
        with _urllib.urlopen(req, timeout=120) as resp:
            op_data = _json.loads(resp.read())
    except _urlerr.HTTPError as exc:
        err = exc.read().decode(errors="replace")
        raise RuntimeError(f"[gateway_patch] REST failed {exc.code}: {err}") from exc

    op_name = op_data.get("name", "")
    print(f"[gateway_patch] LRO -> {op_name}", file=_sys.stderr, flush=True)
    return _GwFuture(op_name, creds, loc, project)


class _GwFuture:
    """Polls the REST LRO and returns a name-compatible stub."""

    def __init__(self, op_name, creds, location, project):
        self._op   = op_name
        self._cred = creds
        self._loc  = location
        self._proj = project

    def result(self, timeout=900):
        import time
        import google.auth.transport.requests as _gatr

        deadline = time.time() + timeout
        while time.time() < deadline:
            self._cred.refresh(_gatr.Request())
            url = (f"https://{self._loc}-aiplatform.googleapis.com/v1/"
                   f"{self._op}")
            req = _urllib.Request(
                url, headers={"Authorization": f"Bearer {self._cred.token}"}
            )
            with _urllib.urlopen(req, timeout=30) as resp:
                op = _json.loads(resp.read())
            if op.get("done"):
                if "error" in op:
                    raise RuntimeError(
                        f"[gateway_patch] LRO error: {op['error']}"
                    )
                raw = op.get("response", {})
                # Return a lightweight stub — ADK only needs .name / .display_name
                class _Stub:
                    name         = raw.get("name", "")
                    display_name = raw.get("displayName", "")
                res = _Stub()
                print(f"[gateway_patch] DONE -> {res.name}",
                      file=_sys.stderr, flush=True)
                return res
            time.sleep(15)
        raise TimeoutError(f"[gateway_patch] LRO timed out: {self._op}")

    def add_done_callback(self, fn): pass
    def cancelled(self): return False
    def running(self): return True


def _apply():
    if not _INGRESS or not _EGRESS:
        print("[gateway_patch] No AGENT_GATEWAY_INGRESS/EGRESS — skipping.",
              file=_sys.stderr, flush=True)
        return

    # ------------------------------------------------------------------ #
    # PRIMARY: Transport-level HTTP interception                           #
    # google-cloud-aiplatform REST transport uses AuthorizedSession for    #
    # ALL HTTP calls.  Patching at this layer catches every               #
    # CreateReasoningEngine call regardless of inner class structure.      #
    # ------------------------------------------------------------------ #
    def _inject_gateway(body, url):
        """Inject org-policy fields and gateway_agent wheel into a CreateReasoningEngine body.

        Injects:
          - identityType: AGENT_IDENTITY       (org-policy required)
          - agentGatewayConfig                  (org-policy required)
          - OTEL env vars                       (observability)
          - gateway_agent wheel at tarball root  (dependency packaging fix)

        Strips:
          - contextSpec                         (google-cloud-aiplatform 1.149+
                                                 auto-injects contextSpec.memoryBankConfig
                                                 pointing to gemini-3.5-flash. That model
                                                 is only available via the global endpoint;
                                                 the RE container tries to initialise it
                                                 against the regional endpoint on startup
                                                 and crashes with FAILED_PRECONDITION.)
        """
        # ── Strip contextSpec before it reaches the server ──────────────────
        removed_ctx = body.pop("contextSpec", None)
        if removed_ctx:
            print(f"[gateway_patch] Stripped contextSpec from POST body: {list(removed_ctx.keys())}",
                  file=_sys.stderr, flush=True)

        # ── Inject gateway_agent wheel into the source archive ───────────────
        # This must happen BEFORE we serialize env/gateway so size is correct
        body = _inject_wheel_into_archive(body)

        spec = body.setdefault("spec", {})
        if "identity_type" in spec:
            spec["identity_type"] = "AGENT_IDENTITY"
        else:
            spec["identityType"] = "AGENT_IDENTITY"

        # Inject gateway config — handle both snake_case and camelCase SDKs
        if "deployment_spec" in spec:
            ds = spec["deployment_spec"]
            ds["agent_gateway_config"] = {
                "client_to_agent_config":   {"agent_gateway": _INGRESS},
                "agent_to_anywhere_config": {"agent_gateway": _EGRESS},
            }
        else:
            ds = spec.setdefault("deploymentSpec", {})
            ds["agentGatewayConfig"] = {
                "clientToAgentConfig":   {"agentGateway": _INGRESS},
                "agentToAnywhereConfig": {"agentGateway": _EGRESS},
            }

        env = ds.setdefault("env", [])
        print(f"[gateway_patch] env before: {env}", file=_sys.stderr, flush=True)
        # Build a lookup of vars already in the env list
        otel_keys = {k for k, _ in _OTEL_VARS}
        # Force-override any OTEL var already present
        env[:] = [
            e if (not isinstance(e, dict) or e.get("name") not in otel_keys)
            else next(({"name": k, "value": v} for k, v in _OTEL_VARS if k == e["name"]), e)
            for e in env
        ]
        have = {e.get("name") for e in env if isinstance(e, dict)}
        print(f"[gateway_patch] have after override: {have}", file=_sys.stderr, flush=True)
        for k, v in _OTEL_VARS:
            if k not in have:
                env.append({"name": k, "value": v})

        env_count = len(env)
        print(f"[gateway_patch] env after: {env}", file=_sys.stderr, flush=True)
        print(f"[gateway_patch] Injected identityType+agentGatewayConfig+OTEL into "
              f"POST {url} (env={env_count})",
              file=_sys.stderr, flush=True)
        return body

    def _is_create_re(method, url):
        url_str = str(url)
        if method.upper() != "POST":
            return False
        if "reasoningEngines" not in url_str:
            return False
        return True  # inject on ALL POST to reasoningEngines

    try:
        from google.auth.transport.requests import AuthorizedSession as _ASession
        _orig_send = _ASession.send

        def _patched_send(self, request, **kwargs):
            url_str = str(request.url)
            if (request.method.upper() == "POST" and
                    "reasoningEngines" in url_str):
                try:
                    raw_body = request.body
                    if isinstance(raw_body, bytes):
                        body = _json.loads(raw_body)
                    elif isinstance(raw_body, str):
                        body = _json.loads(raw_body)
                    else:
                        body = None

                    if body is not None:
                        body = _inject_gateway(body, url_str)
                        encoded = _json.dumps(body).encode()
                        request.body = encoded
                        request.headers.pop("Content-Length", None)
                        request.headers.pop("content-length", None)
                        request.headers["Content-Type"] = "application/json"
                        print(
                            f"[gateway_patch] body={len(encoded)}B "
                            f"cl_after={request.headers.get('Content-Length','(removed)')}",
                            file=_sys.stderr, flush=True)
                except Exception as exc:
                    print(f"[gateway_patch] send() injection failed: {exc}",
                          file=_sys.stderr, flush=True)
            return _orig_send(self, request, **kwargs)

        _ASession.send = _patched_send
        print("[gateway_patch] Patched AuthorizedSession.send (PreparedRequest level)",
              file=_sys.stderr, flush=True)
    except Exception as exc:
        print(f"[gateway_patch] AuthorizedSession patch failed: {exc}",
              file=_sys.stderr, flush=True)

    # ------------------------------------------------------------------ #
    # SECONDARY: Also try to patch httpx (used by some SDK versions)      #
    # ------------------------------------------------------------------ #
    try:
        import httpx as _httpx
        _orig_httpx_send = _httpx.Client.send

        def _patched_httpx_send(self, request, **kwargs):
            url_str = str(request.url)
            if (request.method.upper() == "POST" and
                    "reasoningEngines" in url_str):
                try:
                    body = _json.loads(request.content)
                    body = _inject_gateway(body, url_str)
                    encoded = _json.dumps(body).encode()
                    clean_headers = {
                        k: v for k, v in dict(request.headers).items()
                        if k.lower() != "content-length"
                    }
                    request = _httpx.Request(
                        method=request.method,
                        url=request.url,
                        headers=clean_headers,
                        content=encoded,
                    )
                    print(
                        f"[gateway_patch] httpx body={len(encoded)}B "
                        f"cl={request.headers.get('content-length','?')}",
                        file=_sys.stderr, flush=True,
                    )
                except Exception as e:
                    print(f"[gateway_patch] httpx body injection failed: {e}",
                          file=_sys.stderr, flush=True)
            return _orig_httpx_send(self, request, **kwargs)

        _httpx.Client.send = _patched_httpx_send
        print("[gateway_patch] Patched httpx.Client.send (transport level)",
              file=_sys.stderr, flush=True)
    except Exception as exc:
        print(f"[gateway_patch] httpx patch skipped: {exc}",
              file=_sys.stderr, flush=True)

    # ------------------------------------------------------------------ #
    # BELT-AND-SUSPENDERS: patch known GAPIC client classes directly      #
    # ------------------------------------------------------------------ #
    for module_path, class_name in [
        ("google.cloud.aiplatform_v1beta1.services.reasoning_engine_service.client",
         "ReasoningEngineServiceClient"),
        ("google.cloud.aiplatform_v1beta1.services.reasoning_engine_service",
         "ReasoningEngineServiceClient"),
        ("google.cloud.aiplatform_v1.services.reasoning_engine_service.client",
         "ReasoningEngineServiceClient"),
        ("google.cloud.aiplatform_v1.services.reasoning_engine_service",
         "ReasoningEngineServiceClient"),
        ("google.cloud.aiplatform.utils",
         "ReasoningEngineClientWithOverride"),
    ]:
        try:
            import importlib
            mod = importlib.import_module(module_path)
            cls = getattr(mod, class_name)
            cls.create_reasoning_engine = _rest_create
            print(f"[gateway_patch] Patched {class_name} (class level)",
                  file=_sys.stderr, flush=True)
        except Exception as e:
            print(f"[gateway_patch] Skip {class_name}: {e}",
                  file=_sys.stderr, flush=True)


_apply()

'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ingress", required=True)
    parser.add_argument("--egress",  required=True)
    parser.add_argument("--agent-name", default="chat-agent-v1", help="Name of the agent to deploy")
    parser.add_argument("--venv",    default="agentic-lens/.venv",
                        help="Path to the ADK venv (default: agentic-lens/.venv)")
    args = parser.parse_args()

    try:
        sp = find_site_packages(args.venv)
    except FileNotFoundError as exc:
        print(f"[patch] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

    print(f"[patch] Target venv site-packages: {sp}")

    # 1. Write _gateway_patch.py (the actual monkey-patch code)
    patch_py = os.path.join(sp, f"{PATCH_MODULE}.py")

    # Inject the agent name dynamically
    final_patch_py = PATCH_PY.replace('"chat-agent-v1"', f'"{args.agent_name}"')

    with open(patch_py, "w") as f:
        f.write(final_patch_py)
    print(f"[patch] Wrote {patch_py} (agent_name={args.agent_name})")

    # 2. Write _gateway_patch.pth  (Python auto-imports this at startup)
    patch_pth = os.path.join(sp, f"{PATCH_MODULE}.pth")
    with open(patch_pth, "w") as f:
        f.write(f"import {PATCH_MODULE}\n")
    print(f"[patch] Wrote {patch_pth}")

    print(f"[patch] ingress: {args.ingress}")
    print(f"[patch] egress:  {args.egress}")
    print("[patch] IMPORTANT: AGENT_GATEWAY_INGRESS and AGENT_GATEWAY_EGRESS")
    print("[patch]            must be exported in the shell before deploy.sh runs")
    print("[patch] IMPORTANT: Set GATEWAY_AGENT_WHEEL_PATH to wheel file path")
    print("[patch]            to inject the wheel into the source_archive tarball")

    # 3. Verify the patch can be imported and applies cleanly
    print("[patch] Verifying patch loads in target Python...")
    import subprocess

    # Find the Python in the target venv
    target_python = os.path.join(args.venv, "bin", "python")
    if not os.path.isfile(target_python):
        target_python = sys.executable
        print(f"[patch] WARNING: {args.venv}/bin/python not found, using {target_python}")

    result = subprocess.run(
        [target_python, "-c",
         f"import sys; sys.path.insert(0, {sp!r}); "
         f"import os; os.environ['AGENT_GATEWAY_INGRESS']={args.ingress!r}; "
         f"os.environ['AGENT_GATEWAY_EGRESS']={args.egress!r}; "
         f"import {PATCH_MODULE}; print('verify OK')"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"[patch] Verify FAILED:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    # Print stderr from the verification (the [gateway_patch] messages)
    if result.stderr:
        for line in result.stderr.strip().splitlines():
            print(f"[patch]  {line}")
    out = result.stdout.strip()
    if out:
        print(f"[patch] {out}")
    print("[patch] Done ✅")


if __name__ == "__main__":
    main()
