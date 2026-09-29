#!/usr/bin/env python3
"""patch_a2a_classification.py — Post-deploy 3-PATCH for google-adk(a2a) classification.

CRITICAL FINDING (charter-poc-test, 6/6 E2E, google-adk(a2a) ✅, 2026-08-12):
  Deploy with plain Agent (stream_query works, 13 classMethods).
  Apply 3 metadata PATCHes post-deploy for google-adk(a2a) console classification.

  PATCH 1: spec.agentFramework=google-adk + spec.classMethods (13 ADK + 11 A2A = 24)
  PATCH 2: Strip contextSpec (prevents memory/session config bleed)
  PATCH 3: spec.agentCard — REQUIRED for console to show google-adk(a2a)
            updateMask MUST use snake_case: spec.agent_card (NOT spec.agentCard)

  Classification is metadata-driven. stream_query remains the data plane.
  on_message_send methods exist in metadata only — the A2A protocol is NOT functional.

Usage:
    python scripts/patch_a2a_classification.py \\
        --project geap-agw --region us-east1 \\
        --re-ids RE_ID_1 RE_ID_2 RE_ID_3

    # Auto-discover all REs with team label:
    python scripts/patch_a2a_classification.py \\
        --project geap-agw --region us-east1 --team food-court

    # Verify only (no PATCH):
    python scripts/patch_a2a_classification.py \\
        --project geap-agw --region us-east1 --team food-court --verify-only
"""

import argparse
import json
import sys
import time
import urllib.request
import urllib.error

import google.auth
import google.auth.transport.requests

# ---------------------------------------------------------------------------
# The 11 A2A protocol methods — from charter-poc-test working reference
# ---------------------------------------------------------------------------
A2A_METHODS = [
    {"name": "on_message_send",
     "description": "A2A send a message",
     "parameters": {"type": "object", "properties": {}},
     "api_mode": ""},
    {"name": "on_get_task",
     "description": "A2A get task",
     "parameters": {"type": "object", "properties": {}},
     "api_mode": ""},
    {"name": "on_list_tasks",
     "description": "A2A list tasks",
     "parameters": {"type": "object", "properties": {}},
     "api_mode": ""},
    {"name": "on_cancel_task",
     "description": "A2A cancel task",
     "parameters": {"type": "object", "properties": {}},
     "api_mode": ""},
    {"name": "on_create_task_push_notification_config",
     "description": "A2A create push notification config",
     "parameters": {"type": "object", "properties": {}},
     "api_mode": ""},
    {"name": "on_get_task_push_notification_config",
     "description": "A2A get push notification config",
     "parameters": {"type": "object", "properties": {}},
     "api_mode": ""},
    {"name": "on_list_task_push_notification_configs",
     "description": "A2A list push notification configs",
     "parameters": {"type": "object", "properties": {}},
     "api_mode": ""},
    {"name": "on_delete_task_push_notification_config",
     "description": "A2A delete push notification config",
     "parameters": {"type": "object", "properties": {}},
     "api_mode": ""},
    {"name": "on_message_send_stream",
     "description": "A2A stream message send",
     "parameters": {"type": "object", "properties": {}},
     "api_mode": ""},
    {"name": "on_subscribe_to_task",
     "description": "A2A subscribe to task",
     "parameters": {"type": "object", "properties": {}},
     "api_mode": ""},
    {"name": "on_get_extended_agent_card",
     "description": "A2A get extended agent card",
     "parameters": {"type": "object", "properties": {}},
     "api_mode": ""},
]


def refresh_token(creds):
    creds.refresh(google.auth.transport.requests.Request())
    return creds.token


def get_creds():
    creds, _ = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    creds.refresh(google.auth.transport.requests.Request())
    return creds


def list_res_by_team(project: str, region: str, team: str, token: str) -> list[dict]:
    url = (
        f"https://{region}-aiplatform.googleapis.com/v1beta1/"
        f"projects/{project}/locations/{region}/reasoningEngines"
    )
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read())
    results = []
    for re in data.get("reasoningEngines", []):
        if re.get("labels", {}).get("team") == team:
            re_id = re["name"].split("/")[-1]
            display = re.get("displayName", "?")
            print(f"  Found: {display} → RE {re_id}")
            results.append({"re_id": re_id, "display": display, "re": re})
    return results


def build_agent_card(re_id: str, display: str, re_data: dict,
                     project: str, project_num: str, region: str) -> dict:
    """Build the agentCard payload for this RE."""
    labels = re_data.get("labels", {})
    capability = labels.get("capability", display.lower().replace(" ", "-"))
    role = labels.get("role", "specialist")
    description = re_data.get("description", f"{display} — food court agent")

    return {
        "name": display,
        "description": description,
        "version": "1.0.0",
        "url": (
            f"https://{region}-aiplatform.googleapis.com/v1beta1/"
            f"projects/{project_num}/locations/{region}/"
            f"reasoningEngines/{re_id}/a2a"
        ),
        "supportedInterfaces": [{
            "url": "http://localhost:9999/",
            "protocolBinding": "HTTP+JSON",
            "protocolVersion": "1.0",
        }],
        "capabilities": {
            "streaming": True,
            "extendedAgentCard": True,
        },
        "defaultInputModes": ["text/plain"],
        "defaultOutputModes": ["application/json"],
        "skills": [{
            "id": f"{capability}-skill",
            "name": display,
            "description": description,
            "tags": ["food-court", role, capability],
        }],
    }


def do_patch(url: str, body: dict, token: str, label: str) -> dict | None:
    """Execute a PATCH request. Returns parsed response or None on error."""
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
            result = json.loads(resp.read())
            print(f"  ✅ {label}")
            return result
    except urllib.error.HTTPError as e:
        err = e.read().decode(errors="replace")
        print(f"  ❌ {label} FAILED {e.code}: {err[:300]}")
        return None


def verify_re(project: str, region: str, re_id: str, token: str):
    """Print classification status for an RE."""
    base = (
        f"https://{region}-aiplatform.googleapis.com/v1beta1/"
        f"projects/{project}/locations/{region}/reasoningEngines/{re_id}"
    )
    req = urllib.request.Request(base, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        print(f"  ❌ GET failed: {e}")
        return

    spec = data.get("spec", {})
    af = spec.get("agentFramework", "NONE")
    cm = len(spec.get("classMethods", []))
    has_card = "agentCard" in spec
    ctx = bool(spec.get("contextSpec", {}).get("memoryStoreId") or
               spec.get("contextSpec", {}))
    ok = af == "google-adk" and cm >= 20 and has_card
    print(f"  agentFramework : {af}")
    print(f"  classMethods   : {cm}")
    print(f"  agentCard      : {'✅' if has_card else '❌ MISSING'}")
    print(f"  contextSpec    : {'⚠️  present (needs strip)' if ctx else '✅ clean'}")
    print(f"  Classification : {'google-adk(a2a) ✅' if ok else '❌ NOT google-adk(a2a)'}")
    if not has_card:
        print("  ⚠️  Missing agentCard — console will show Non-A2A!")
    return ok


def patch_re(project: str, region: str, project_num: str,
             re_id: str, display: str, re_data: dict, creds) -> bool:
    base = (
        f"https://{region}-aiplatform.googleapis.com/v1beta1/"
        f"projects/{project}/locations/{region}/reasoningEngines/{re_id}"
    )

    # ── GET current state ────────────────────────────────────────────────
    token = refresh_token(creds)
    req = urllib.request.Request(base, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            existing_re = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"  ❌ GET failed {e.code}: {e.read().decode()[:200]}")
        return False

    existing_methods = existing_re.get("spec", {}).get("classMethods", [])
    existing_names = {m["name"] for m in existing_methods}
    new_methods = [m for m in A2A_METHODS if m["name"] not in existing_names]
    combined = existing_methods + new_methods
    print(f"  {display}: existing={len(existing_methods)} → combined={len(combined)} (+{len(new_methods)} A2A)")

    # ── PATCH 1: agentFramework + classMethods (merge to 24) ─────────────
    token = refresh_token(creds)
    result1 = do_patch(
        f"{base}?updateMask=spec.agentFramework,spec.classMethods",
        {"spec": {"agentFramework": "google-adk", "classMethods": combined}},
        token,
        f"PATCH 1: agentFramework=google-adk, classMethods={len(combined)}",
    )
    if not result1:
        return False

    # ── PATCH 2: Strip contextSpec ────────────────────────────────────────
    time.sleep(0.5)
    token = refresh_token(creds)
    result2 = do_patch(
        f"{base}?updateMask=contextSpec",
        {"contextSpec": {}},
        token,
        "PATCH 2: contextSpec stripped",
    )
    if not result2:
        return False

    # ── PATCH 3: agentCard — REQUIRED for google-adk(a2a) console label ──
    # updateMask MUST be spec.agent_card (snake_case) — spec.agentCard → 400
    time.sleep(0.5)
    token = refresh_token(creds)
    agent_card = build_agent_card(re_id, display, re_data, project, project_num, region)
    result3 = do_patch(
        f"{base}?updateMask=spec.agent_card",  # ← snake_case CRITICAL
        {"spec": {"agentCard": agent_card}},
        token,
        f"PATCH 3: agentCard set (url={agent_card['url'][-40:]})",
    )
    if not result3:
        return False

    # ── Final verification ────────────────────────────────────────────────
    time.sleep(0.5)
    token = refresh_token(creds)
    final_spec = result3.get("spec", {})
    final_cm = len(final_spec.get("classMethods", []))
    has_card = "agentCard" in final_spec
    framework = final_spec.get("agentFramework", "?")
    ok = framework == "google-adk" and final_cm >= 20 and has_card
    print(f"  ✅ DONE: framework={framework}, classMethods={final_cm}, agentCard={has_card}")
    if ok:
        print(f"  🎯 Classification: google-adk(a2a) ✅")
    else:
        print(f"  ⚠️  Classification NOT complete — check agentCard or classMethods")
    return ok


def get_project_number(project: str, token: str) -> str:
    """Look up project number from project ID."""
    url = f"https://cloudresourcemanager.googleapis.com/v1/projects/{project}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
            return data.get("projectNumber", "")
    except Exception:
        return ""


def main():
    parser = argparse.ArgumentParser(
        description="Apply 3-PATCH metadata to achieve google-adk(a2a) classification"
    )
    parser.add_argument("--project", required=True)
    parser.add_argument("--region", required=True, help="GCP region (e.g. us-east1)")
    parser.add_argument("--project-num", help="Project number (auto-detected if omitted)")
    parser.add_argument("--re-ids", nargs="+", help="Specific RE IDs to patch")
    parser.add_argument("--team", help="Auto-discover all REs with this team label")
    parser.add_argument("--verify-only", action="store_true",
                        help="Only verify current state — do not PATCH")
    args = parser.parse_args()

    print(f"=== google-adk(a2a) Classification PATCH — {args.project}/{args.region} ===\n")
    creds = get_creds()
    token = creds.token

    # Resolve project number
    project_num = args.project_num or get_project_number(args.project, token)
    if not project_num:
        print("⚠️  Could not resolve project number — agentCard URL will be incomplete")
        project_num = args.project

    print(f"Project      : {args.project}")
    print(f"Project Num  : {project_num}")
    print(f"Region       : {args.region}\n")

    # Collect RE IDs + metadata
    re_entries: list[dict] = []

    if args.team:
        print(f"Discovering REs with team={args.team}...")
        token = refresh_token(creds)
        entries = list_res_by_team(args.project, args.region, args.team, token)
        if not entries:
            print("No REs found.")
            sys.exit(1)
        re_entries = entries
        print()
    elif args.re_ids:
        # Fetch metadata for each RE ID
        for re_id in args.re_ids:
            token = refresh_token(creds)
            base = (
                f"https://{args.region}-aiplatform.googleapis.com/v1beta1/"
                f"projects/{args.project}/locations/{args.region}/reasoningEngines/{re_id}"
            )
            req = urllib.request.Request(base, headers={"Authorization": f"Bearer {token}"})
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    re_data = json.loads(resp.read())
                display = re_data.get("displayName", re_id)
                print(f"  Found: {display} → RE {re_id}")
                re_entries.append({"re_id": re_id, "display": display, "re": re_data})
            except urllib.error.HTTPError as e:
                print(f"  ❌ Could not fetch RE {re_id}: {e.code}")
        print()
    else:
        print("Error: provide --re-ids or --team")
        sys.exit(1)

    ok = 0
    for entry in re_entries:
        re_id = entry["re_id"]
        display = entry["display"]
        re_data = entry["re"]
        print(f"--- {display} (RE {re_id}) ---")

        if args.verify_only:
            token = refresh_token(creds)
            verify_re(args.project, args.region, re_id, token)
        else:
            if patch_re(args.project, args.region, project_num,
                        re_id, display, re_data, creds):
                ok += 1
        print()

    if not args.verify_only:
        print(f"Done: {ok}/{len(re_entries)} REs patched to google-adk(a2a) ✅")
        if ok < len(re_entries):
            sys.exit(1)


if __name__ == "__main__":
    main()
