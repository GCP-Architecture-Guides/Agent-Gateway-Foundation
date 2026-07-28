#!/usr/bin/env python3
"""Post-process the generated _gateway_patch.py to inject contextSpec: {}
into every CreateReasoningEngine request body.

The Vertex AI platform auto-injects contextSpec.memoryBankConfig on every
new Reasoning Engine. The injected model (gemini-3.5-flash) is only available
via the global endpoint; the RE container tries to init it at the regional
endpoint on startup and crashes. The platform then auto-deletes the failed RE
before any post-creation PATCH can fix it.

The only reliable fix is to include contextSpec: {} in the initial CREATE body
so the platform has nothing to inject on top of.

Usage:
    python3 patch_add_context_spec.py --venv /path/to/.venv
"""

import argparse
import re
import sys
from pathlib import Path


def find_gateway_patch(venv: Path) -> Path:
    candidates = list(venv.glob("lib/python*/site-packages/_gateway_patch.py"))
    if not candidates:
        print(f"  [context_spec_patch] _gateway_patch.py not found in {venv}",
              file=sys.stderr)
        sys.exit(1)
    return candidates[0]


def patch_inject_gateway(source: str) -> str:
    """Insert body["contextSpec"] = {} before every `return body` in _inject_gateway."""

    # Target: the _inject_gateway function's return statement
    # We insert the contextSpec clear immediately before `return body`
    # Using a unique marker so we don't double-patch on re-runs.
    marker = "# [context_spec_patch] prevent platform memoryBankConfig injection"

    if marker in source:
        print("  [context_spec_patch] Already applied — skipping.",
              file=sys.stderr)
        return source

    # Insert before `    return body` inside _inject_gateway
    # The function ends with `    return body` (4-space indent)
    injection = (
        f"\n        {marker}\n"
        f"        body[\"contextSpec\"] = {{}}\n"
    )

    # Match `    return body` at the end of _inject_gateway
    # We look for the last `return body` before the function closes
    patched, n = re.subn(
        r'(\n        return body\n)',
        injection + r'\1',
        source,
        count=1,   # only the first match — inside _inject_gateway
    )

    if n == 0:
        # Fallback: look for 8-space indent (some formatting variants)
        patched, n = re.subn(
            r'(\n    return body\n)',
            f"\n    {marker}\n    body[\"contextSpec\"] = {{}}\n" + r'\1',
            source,
            count=1,
        )

    if n == 0:
        print("  [context_spec_patch] WARNING: Could not locate `return body` "
              "in _inject_gateway — patch NOT applied.", file=sys.stderr)
        return source

    print(f"  [context_spec_patch] Injected contextSpec clear into _inject_gateway.",
          file=sys.stderr)
    return patched


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--venv", required=True,
                        help="Path to the Python venv (e.g. .venv)")
    args = parser.parse_args()

    venv = Path(args.venv)
    patch_file = find_gateway_patch(venv)

    print(f"  [context_spec_patch] Patching: {patch_file}", file=sys.stderr)

    source = patch_file.read_text(encoding="utf-8")
    patched = patch_inject_gateway(source)
    patch_file.write_text(patched, encoding="utf-8")

    print("  [context_spec_patch] Done ✅", file=sys.stderr)


if __name__ == "__main__":
    main()
