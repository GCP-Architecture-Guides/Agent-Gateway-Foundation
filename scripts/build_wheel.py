#!/usr/bin/env python3
"""
Build a PEP 427 wheel for gateway_agent WITHOUT requiring setuptools/wheel.
Wheels are just ZIP files with a specific structure — no build tools needed.

Usage:
    python3 build_wheel.py [--src <lib/gateway_agent dir>] [--out <output dir>]
"""

import argparse
import base64
import hashlib
import io
import os
import sys
import zipfile
from pathlib import Path

PACKAGE_NAME = "gateway_agent"
DIST_NAME = "gateway_agent"
VERSION = "0.1.0"
WHEEL_TAG = "py3-none-any"

METADATA_CONTENT = """\
Metadata-Version: 2.1
Name: gateway-agent
Version: {version}
Summary: GatewayAgent SDK — ADK wrapper enforcing GlobalGemini routing, OTEL telemetry and query() registration
Requires-Python: >=3.10
""".format(version=VERSION)

WHEEL_CONTENT = """\
Wheel-Version: 1.0
Generator: build_wheel.py (manual)
Root-Is-Purelib: true
Tag: {tag}
""".format(tag=WHEEL_TAG)


def sha256_hash(data: bytes) -> str:
    digest = hashlib.sha256(data).digest()
    return "sha256=" + base64.urlsafe_b64encode(digest).rstrip(b"=").decode()


def build_wheel(src_dir: Path, out_dir: Path) -> Path:
    dist_info = f"{DIST_NAME}-{VERSION}.dist-info"
    wheel_filename = f"{DIST_NAME}-{VERSION}-{WHEEL_TAG}.whl"
    wheel_path = out_dir / wheel_filename

    # Collect module files (*.py only, skip build artifacts)
    module_files = sorted(
        p for p in src_dir.iterdir()
        if p.is_file() and p.suffix == ".py"
        and p.name not in ("setup.py",)  # exclude setup.py from the package
    )

    if not module_files:
        print(f"ERROR: No .py files found in {src_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Building wheel: {wheel_filename}", file=sys.stderr)
    print(f"  Package files: {[f.name for f in module_files]}", file=sys.stderr)

    records: list[tuple[str, str, int]] = []
    buf = io.BytesIO()

    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        # 1. Package module files
        for src_file in module_files:
            arc_name = f"{PACKAGE_NAME}/{src_file.name}"
            data = src_file.read_bytes()
            zf.writestr(arc_name, data)
            records.append((arc_name, sha256_hash(data), len(data)))
            print(f"  + {arc_name}", file=sys.stderr)

        # 2. dist-info/METADATA
        meta_bytes = METADATA_CONTENT.encode()
        zf.writestr(f"{dist_info}/METADATA", meta_bytes)
        records.append((f"{dist_info}/METADATA", sha256_hash(meta_bytes), len(meta_bytes)))

        # 3. dist-info/WHEEL
        wheel_bytes = WHEEL_CONTENT.encode()
        zf.writestr(f"{dist_info}/WHEEL", wheel_bytes)
        records.append((f"{dist_info}/WHEEL", sha256_hash(wheel_bytes), len(wheel_bytes)))

        # 4. dist-info/RECORD (must be last; its own entry has empty hash/size)
        record_lines = [f"{path},{h},{sz}" for path, h, sz in records]
        record_lines.append(f"{dist_info}/RECORD,,")  # self-referential empty entry
        record_content = "\n".join(record_lines) + "\n"
        zf.writestr(f"{dist_info}/RECORD", record_content)

    wheel_path.write_bytes(buf.getvalue())
    print(f"  Wrote {wheel_path} ({wheel_path.stat().st_size} bytes)", file=sys.stderr)
    return wheel_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", default=None,
                        help="Path to the gateway_agent source directory "
                             "(default: lib/gateway_agent relative to this script's parent)")
    parser.add_argument("--out", default=None,
                        help="Output directory for the .whl file (default: same as --src)")
    args = parser.parse_args()

    script_dir = Path(__file__).parent
    src_dir = Path(args.src) if args.src else (script_dir.parent / "lib" / "gateway_agent")
    out_dir = Path(args.out) if args.out else src_dir

    if not src_dir.is_dir():
        print(f"ERROR: Source dir not found: {src_dir}", file=sys.stderr)
        sys.exit(1)
    out_dir.mkdir(parents=True, exist_ok=True)

    whl = build_wheel(src_dir, out_dir)
    print(whl)  # stdout: path to the wheel (for shell capture)


if __name__ == "__main__":
    main()
