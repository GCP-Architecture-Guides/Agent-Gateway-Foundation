#!/usr/bin/env python3
# Copyright 2025 Google LLC
# PoC environment only.
"""
e2e_test.py — End-to-End test suite for Food Court multi-agent system.

Tests (in order):
  [1] RE health: all 4 specialist REs + orchestrator are ACTIVE
  [2] Pizza specialist:   menu, dietary filter, order
  [3] Burger specialist:  menu, nutrition, order
  [4] Sushi specialist:   menu, nigiri options, dietary filter, order
  [5] Orchestrator:       cross-agent routing → pizza / burger / sushi
  [6] Orchestrator:       wait time, cross-cuisine question

Usage:
    # Auto-discover RE IDs by display name (recommended — no stale IDs)
    python scripts/e2e_test.py --project geap-agw --region us-east1

    # Explicit RE IDs (override discovery)
    python scripts/e2e_test.py --project geap-agw --region us-east1 \\
        --re-ids pizza_specialist=123 burger_specialist=456 sushi_specialist=789 store_concierge=101
"""

import argparse
import asyncio
import json
import logging
import sys
import time
import urllib.request
import uuid

import google.auth
import google.auth.transport.requests
import vertexai
from vertexai.agent_engines import get as get_engine

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s: %(message)s",
)
logger = logging.getLogger("e2e")

# ── Display names → agent keys ────────────────────────────────────────────
# Maps Vertex AI RE displayName → the key used in this test suite.
# Discovery uses displayName matching so RE IDs never need to be hardcoded.
DISPLAY_NAME_MAP = {
    "pizza_specialist": "pizza_specialist",
    "burger_specialist": "burger_specialist",
    "sushi_specialist": "sushi_specialist",
    "store_concierge": "store_concierge",
}


def discover_re_ids(project: str, region: str, tok: str) -> dict:
    """Query the Vertex AI RE list API and match by displayName.

    Returns a dict of {agent_key: re_id} for all agents found.
    Prints a warning for any agent not found.
    """
    url = (
        f"https://{region}-aiplatform.googleapis.com/v1beta1/"
        f"projects/{project}/locations/{region}/reasoningEngines"
    )
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read())
    except Exception as e:  # noqa: BLE001
        print(f"  ⚠️  Could not list REs: {e}")
        return {}

    engines = data.get("reasoningEngines", [])
    found = {}
    for engine in engines:
        display = engine.get("displayName", "")
        re_id = engine["name"].split("/")[-1]
        if display in DISPLAY_NAME_MAP:
            key = DISPLAY_NAME_MAP[display]
            found[key] = re_id
            print(f"    Discovered {display} → RE {re_id}")

    for key in DISPLAY_NAME_MAP:
        if key not in found:
            print(f"    ⚠️  Not found: {key} (not deployed?)")
    return found

# ── Colors ────────────────────────────────────────────────────────────────
G = "\033[92m"  # green
R = "\033[91m"  # red
Y = "\033[93m"  # yellow
B = "\033[94m"  # blue
W = "\033[97m"  # white bold
N = "\033[0m"   # reset


def token():
    creds, _ = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    creds.refresh(google.auth.transport.requests.Request())
    return creds.token


def get_re_info(project, region, re_id, tok):
    """Returns (reachable:bool, display_name:str, n_methods:int)."""
    url = (
        f"https://{region}-aiplatform.googleapis.com/v1beta1"
        f"/projects/{project}/locations/{region}/reasoningEngines/{re_id}"
    )
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read())
    # v1beta1 has no 'state' field — presence of 'name' means it's deployed
    reachable = bool(data.get("name"))
    display   = data.get("displayName", "?")
    n_methods = len(data.get("spec", {}).get("classMethods", []))
    framework = data.get("spec", {}).get("agentFramework", "?")
    return reachable, display, n_methods, framework


def _extract_text(event) -> str:
    """Extract text from any event format (dict or ADK object)."""
    if isinstance(event, dict):
        content = event.get("content", {})
        if isinstance(content, dict):
            return " ".join(
                p["text"] for p in content.get("parts", [])
                if isinstance(p, dict) and p.get("text")
            )
        return ""
    if hasattr(event, "content") and event.content:
        return " ".join(
            p.text for p in getattr(event.content, "parts", [])
            if hasattr(p, "text") and p.text
        )
    return ""


async def _async_stream(engine, message: str, uid: str) -> str:
    """Use async_stream_query (the correct SDK method for ADK agents)."""
    parts = []
    async for event in engine.async_stream_query(message=message, user_id=uid):
        text = _extract_text(event)
        if text:
            parts.append(text)
    return " ".join(parts).strip() or "(empty response)"


def stream_query(engine, message: str, user_id: str = None) -> str:
    """Invoke async_stream_query via asyncio.run() — correct for all ADK agents."""
    uid = user_id or f"e2e-{uuid.uuid4().hex[:6]}"
    try:
        return asyncio.run(_async_stream(engine, message, uid))
    except Exception as exc:
        return f"ERROR: {exc}"


def check(label: str, response: str, must_contain: list[str],
          must_not: list[str] | None = None) -> bool:
    resp_lower = response.lower()
    missing = [kw for kw in must_contain if kw.lower() not in resp_lower]
    blocked = [kw for kw in (must_not or []) if kw.lower() in resp_lower]
    if missing or blocked:
        print(f"    {R}✗ FAIL{N} — {label}")
        if missing:
            print(f"       missing keywords: {missing}")
        if blocked:
            print(f"       found blocked phrase: {blocked}")
        print(f"       got: {response[:200]}")
        return False
    print(f"    {G}✓ PASS{N} — {label}")
    return True


def run_test(label: str, engine, query: str, must_contain: list[str],
             must_not: list[str] | None = None) -> bool:
    print(f"\n  {W}▶ {label}{N}")
    print(f"    Q: \"{query}\"")
    t0 = time.time()
    resp = stream_query(engine, query)
    elapsed = time.time() - t0
    print(f"    A ({elapsed:.1f}s): {resp[:300]}{'...' if len(resp)>300 else ''}")
    return check(label, resp, must_contain, must_not)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--project", default="geap-agw")
    p.add_argument("--region", default="us-east1")
    p.add_argument("--skip-orchestrator", action="store_true",
                   help="Skip orchestrator tests (faster)")
    p.add_argument("--re-ids", nargs="+", metavar="KEY=ID",
                   help="Override RE IDs: pizza_specialist=123 burger_specialist=456 ...")
    args = p.parse_args()

    # staging_bucket is optional — omit if bucket doesn't exist yet
    try:
        vertexai.init(
            project=args.project,
            location=args.region,
            staging_bucket=f"gs://{args.project}-staging",
        )
    except Exception:  # noqa: BLE001
        vertexai.init(project=args.project, location=args.region)

    results = {}  # test_name → bool
    total_start = time.time()

    print(f"\n{B}{'='*65}{N}")
    print(f"{W}   Food Court E2E Test Suite — {args.project}/{args.region}{N}")
    print(f"{B}{'='*65}{N}")

    # ── [1] Health check: discover + verify all REs ───────────────────────
    print(f"\n{Y}[1] RE Health Check{N}")
    tok = token()

    # Build RE_MAP: explicit overrides first, then auto-discovery
    re_map: dict[str, str] = {}
    if args.re_ids:
        for pair in args.re_ids:
            if "=" in pair:
                k, v = pair.split("=", 1)
                re_map[k.strip()] = v.strip()
        print(f"  Using explicit RE IDs ({len(re_map)} provided)")
    else:
        print(f"  Auto-discovering RE IDs by display name...")
        re_map = discover_re_ids(args.project, args.region, tok)
        if not re_map:
            print(f"  {R}❌ No REs discovered — are agents deployed?{N}")
            print(f"     Run: bash scripts/deploy_a2a_agents.sh")
            sys.exit(1)

    engines = {}
    health_ok = True
    resource_base = f"projects/{args.project}/locations/{args.region}/reasoningEngines"
    for name, re_id in re_map.items():
        try:
            reachable, display, n_methods, framework = get_re_info(
                args.project, args.region, re_id, tok
            )
            icon = G + "✓" + N if reachable else R + "✗" + N
            a2a_badge = (G + "google-adk(a2a)" + N
                         if framework == "google-adk" and n_methods >= 24
                         else Y + f"{framework}/{n_methods}m" + N)
            print(f"    {icon} {display:<30} {a2a_badge}  RE={re_id}")
            if reachable:
                engines[name] = get_engine(f"{resource_base}/{re_id}")
            else:
                health_ok = False
        except Exception as e:
            print(f"    {R}✗ {name} (RE={re_id}): {e}{N}")
            health_ok = False
    results["[1] Health"] = health_ok
    if not health_ok:
        print(f"  {R}❌ Some REs not reachable — tests may fail{N}")
    else:
        print(f"  {G}✅ All REs reachable{N}")

    # ── [2] Pizza specialist ──────────────────────────────────────────────
    print(f"\n{Y}[2] Pizza Specialist{N}")
    pizza = engines.get("pizza_specialist")
    if pizza:
        r1 = run_test("Pizza menu",             pizza, "Show me the pizza menu",
                      ["pizza", "margherita"])
        r2 = run_test("Pizza dietary filter",   pizza, "Which pizzas are vegetarian?",
                      ["vegetarian", "margherita"])  # agent lists items, no need to say 'pizza'
        r3 = run_test("Pizza order",            pizza,
                      "Place a large Margherita pizza order right now. No special requests. Customer ID: e2e-test.",
                      ["order", "ord-"])
        results["[2] Pizza"] = all([r1, r2, r3])
    else:
        print(f"  {R}SKIP — engine not available{N}")
        results["[2] Pizza"] = False

    # ── [3] Burger specialist ─────────────────────────────────────────────
    print(f"\n{Y}[3] Burger Specialist{N}")
    burger = engines.get("burger_specialist")
    if burger:
        r1 = run_test("Burger menu",           burger, "What burgers do you have?",
                      ["burger"])
        r2 = run_test("Burger nutrition",      burger,
                      "What's the nutrition info for a Classic Smash Burger?",
                      ["calorie", "protein"])
        r3 = run_test("Burger dietary filter",
                      burger, "Which burgers can be made gluten-free?",
                      ["gluten"])
        r4 = run_test("Burger order",          burger,
                      "Place an order for one Classic Smash Burger right now. No customizations. Customer ID: e2e-test.",
                      ["order", "ord-"])
        results["[3] Burger"] = all([r1, r2, r3, r4])
    else:
        print(f"  {R}SKIP — engine not available{N}")
        results["[3] Burger"] = False

    # ── [4] Sushi specialist ──────────────────────────────────────────────
    print(f"\n{Y}[4] Sushi Specialist{N}")
    sushi = engines.get("sushi_specialist")
    if sushi:
        r1 = run_test("Sushi menu",             sushi, "Show me your full sushi menu",
                      ["roll", "nigiri"])
        r2 = run_test("Nigiri options",         sushi, "What nigiri do you have today?",
                      ["salmon", "tuna"])
        r3 = run_test("Sushi dietary filter",   sushi, "What sushi is gluten-free?",
                      ["gluten", "tamari"])
        r4 = run_test("Sushi roll details",     sushi, "Tell me about the Dragon Roll",
                      ["shrimp", "avocado"])
        r5 = run_test("Sushi order",            sushi,
                      "Place an order for one Dragon Roll and two Salmon Nigiri right now. No special requests. Customer ID: e2e-test.",
                      ["order", "ord-"])
        results["[4] Sushi"] = all([r1, r2, r3, r4, r5])
    else:
        print(f"  {R}SKIP — engine not available{N}")
        results["[4] Sushi"] = False

    # ── [5] Orchestrator: routing ─────────────────────────────────────────
    if not args.skip_orchestrator:
        print(f"\n{Y}[5] Orchestrator — Cross-Agent Routing{N}")
        orch = engines.get("store_concierge")
        if orch:
            r1 = run_test("Route → Pizza",  orch,
                          "I want to order a Margherita pizza",
                          ["margherita", "pizza"], must_not=["currently unavailable", "offline"])
            r2 = run_test("Route → Burger", orch,
                          "What burgers do you serve?",
                          ["burger", "smash"], must_not=["currently unavailable", "offline"])
            r3 = run_test("Route → Sushi",  orch,
                          "Do you have any vegan sushi options?",
                          ["vegan", "sushi"], must_not=["currently unavailable", "offline", "unresponsive"])
            r4 = run_test("Wait time",      orch,
                          "How long is the wait right now?",
                          ["minute", "wait"])
            r5 = run_test("Cross-cuisine",  orch,
                          "Do you have any spicy pizza options?",
                          ["spicy", "pizza"], must_not=["currently unavailable", "offline", "policy restriction"])
            results["[5] Orchestrator"] = all([r1, r2, r3, r4, r5])
        else:
            print(f"  {R}SKIP — orchestrator not available{N}")
            results["[5] Orchestrator"] = False
    else:
        print(f"\n{Y}[5] Orchestrator — SKIPPED (--skip-orchestrator){N}")

    # ── Summary ───────────────────────────────────────────────────────────
    elapsed_total = time.time() - total_start
    passed = sum(1 for v in results.values() if v)
    failed = sum(1 for v in results.values() if not v)

    print(f"\n{B}{'='*65}{N}")
    print(f"{W}   E2E Test Results — {elapsed_total:.0f}s total{N}")
    print(f"{B}{'='*65}{N}")
    for name, ok in results.items():
        icon = G + "✅ PASS" + N if ok else R + "❌ FAIL" + N
        print(f"   {icon}  {name}")
    print(f"\n   {passed}/{len(results)} test groups passed", end="")
    if failed == 0:
        print(f"  {G}🎉 All green!{N}")
    else:
        print(f"  {R}({failed} failed){N}")
    print(f"{B}{'='*65}{N}\n")

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
