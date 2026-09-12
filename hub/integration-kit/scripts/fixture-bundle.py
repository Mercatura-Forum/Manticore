#!/usr/bin/env python3
"""Create, sign, and verify fixture-bundle hash manifests."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_GLOBS = [
    "integration-kit/README.md",
    "integration-kit/xml/**/*.xml",
    "integration-kit/legacy/*",
    "integration-kit/profiles/*.json",
    "integration-kit/connectors/*",
    "integration-kit/candid/*",
    "integration-kit/expected/*",
    "integration-kit/cookbooks/*",
    "integration-kit/profile-runner/*.json",
    "integration-kit/profile-runner/*.md",
    "integration-kit/scripts/*.py",
    "integration-kit/fixtures/README.md",
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
      for chunk in iter(lambda: f.read(1024 * 1024), b""):
        h.update(chunk)
    return h.hexdigest()


def manifest(root: Path, out: Path) -> int:
    files = []
    for pattern in DEFAULT_GLOBS:
        for path in root.glob(pattern):
            if path.is_file():
                rel = path.relative_to(root).as_posix()
                files.append({"path": rel, "sha256": sha256_file(path), "bytes": path.stat().st_size})
    files.sort(key=lambda item: item["path"])
    bundle_preimage = "".join(f"{item['path']}\0{item['sha256']}\n" for item in files).encode()
    doc = {
        "manifestVersion": "thebes-fixture-bundle-v1",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "hashAlgorithm": "SHA-256",
        "fileCount": len(files),
        "bundleHash": hashlib.sha256(bundle_preimage).hexdigest(),
        "files": files,
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"out": str(out), "fileCount": len(files), "bundleHash": doc["bundleHash"]}, sort_keys=True))
    return 0


def sign(manifest_path: Path, private_key: Path, signature: Path) -> int:
    signature.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(private_key), "-out", str(signature), str(manifest_path)],
        check=False,
    )
    return proc.returncode


def verify(manifest_path: Path, public_key: Path, signature: Path) -> int:
    proc = subprocess.run(
        ["openssl", "dgst", "-sha256", "-verify", str(public_key), "-signature", str(signature), str(manifest_path)],
        check=False,
    )
    return proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_manifest = sub.add_parser("manifest")
    p_manifest.add_argument("--out", default="integration-kit/fixtures/fixture-bundle.json")
    p_sign = sub.add_parser("sign")
    p_sign.add_argument("--manifest", default="integration-kit/fixtures/fixture-bundle.json")
    p_sign.add_argument("--private-key", required=True)
    p_sign.add_argument("--signature", default="integration-kit/fixtures/fixture-bundle.sig")
    p_verify = sub.add_parser("verify")
    p_verify.add_argument("--manifest", default="integration-kit/fixtures/fixture-bundle.json")
    p_verify.add_argument("--public-key", required=True)
    p_verify.add_argument("--signature", default="integration-kit/fixtures/fixture-bundle.sig")
    args = parser.parse_args()

    root = Path.cwd()
    if args.cmd == "manifest":
        return manifest(root, root / args.out)
    if args.cmd == "sign":
        return sign(root / args.manifest, root / args.private_key, root / args.signature)
    if args.cmd == "verify":
        return verify(root / args.manifest, root / args.public_key, root / args.signature)
    return 2


if __name__ == "__main__":
    sys.exit(main())
