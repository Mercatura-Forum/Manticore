#!/usr/bin/env python3
"""Emit Candid text for file bytes as a blob."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


def blob_text(payload: bytes) -> str:
    return 'blob "' + "".join(f"\\{byte:02x}" for byte in payload) + '"'


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("file")
    parser.add_argument("--sha256", action="store_true", help="emit the SHA-256 digest bytes instead of file bytes")
    parser.add_argument("--wrap", action="store_true", help="wrap as a single Candid argument tuple")
    args = parser.parse_args()

    payload = Path(args.file).read_bytes()
    if args.sha256:
        payload = hashlib.sha256(payload).digest()
    text = blob_text(payload)
    if args.wrap:
        text = f"({text})"
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
