#!/usr/bin/env python3
"""Run external XML/XSD profile checks over integration-kit fixtures.

The canister deliberately keeps XML validation compact and deterministic. This
runner is the off-canister gate for full XSD/profile evidence. Provide official
or licensed schema bundles through --schema-dir.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_PROFILE_MAP = "integration-kit/profile-runner/profile-map.json"
DEFAULT_SOURCE_MANIFEST = "integration-kit/profile-runner/source-manifest.json"
DEFAULT_REPORT = "integration-kit/profile-runner/profile-report.json"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def run_xmllint(schema: Path, fixture: Path) -> tuple[str, str]:
    if shutil.which("xmllint") is None:
        return "tool-missing", "xmllint is not installed"
    proc = subprocess.run(
        ["xmllint", "--noout", "--schema", str(schema), str(fixture)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    output = (proc.stdout + proc.stderr).strip()
    if proc.returncode == 0:
        return "schema-valid", output
    return "schema-invalid", output


def portable_detail(detail: str, actual_fixture: Path, display_path: str) -> str:
    return detail.replace(str(actual_fixture), display_path)


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def document_fragment(raw: bytes) -> tuple[bytes, str]:
    """Return the XML document payload that should be checked against message XSD.

    Some integration fixtures preserve a Business Application Header beside the
    ISO Document because that is what the canister ingests. XSD validation for a
    message schema must target the `Document` fragment itself.
    """
    text = raw.decode("utf-8-sig")
    stripped = text.lstrip()
    # a business file (head.002) is rooted at Xchg, its payloads inside: the whole file is what the schema sees
    if "<Xchg" in text and text.find("<Xchg") < (text.find("<Document") if "<Document" in text else len(text)):
        return raw, "raw-fixture"
    if stripped.startswith("<?xml"):
        after_decl = stripped.split("?>", 1)
        if len(after_decl) == 2 and after_decl[1].lstrip().startswith("<Document"):
            return raw, "raw-fixture"
    elif stripped.startswith("<Document"):
        return raw, "raw-fixture"

    doc_start = text.find("<Document")
    doc_end = text.rfind("</Document>")
    if doc_start < 0 or doc_end < 0:
        return raw, "raw-fixture"
    doc_end += len("</Document>")
    fragment = text[doc_start:doc_end].encode("utf-8")
    return fragment, "document-fragment"


def rooted(root: Path, value: str) -> Path:
    path = Path(value)
    if path.is_absolute():
        return path
    return root / path


def load_source_manifest(path: Path) -> tuple[dict, bool]:
    if path.exists():
        return json.loads(path.read_text()), True
    return {"schemaFiles": {}, "customProfiles": {}, "sources": {}}, False


def item_source(item: dict, source_manifest: dict) -> tuple[dict | None, str]:
    schema_file = item.get("schemaFile")
    if schema_file is not None:
        source = source_manifest.get("schemaFiles", {}).get(schema_file)
        if source is not None:
            return source, "documented"
        return None, "missing-source-metadata"

    custom_profiles = source_manifest.get("customProfiles", {})
    for key in (item.get("id"), item.get("messageKind"), item.get("profile")):
        if key in custom_profiles:
            return custom_profiles[key], "custom-profile-documented"
    return None, "custom-profile"


def required_schema_rows(profile_map: dict, source_manifest: dict) -> tuple[list[dict], list[str]]:
    by_schema: dict[str, dict] = {}
    for item in profile_map["fixtures"]:
        schema_file = item.get("schemaFile")
        if schema_file is None:
            continue
        row = by_schema.setdefault(
            schema_file,
            {
                "schemaFile": schema_file,
                "messageKinds": set(),
                "profiles": set(),
                "fixtures": [],
            },
        )
        row["messageKinds"].add(item["messageKind"])
        row["profiles"].add(item["profile"])
        row["fixtures"].append(item["id"])

    missing = []
    rows = []
    for schema_file in sorted(by_schema):
        row = by_schema[schema_file]
        source = source_manifest.get("schemaFiles", {}).get(schema_file)
        out = {
            "schemaFile": schema_file,
            "messageKinds": sorted(row["messageKinds"]),
            "profiles": sorted(row["profiles"]),
            "fixtures": sorted(row["fixtures"]),
            "sourceStatus": "documented" if source is not None else "missing-source-metadata",
        }
        if source is not None:
            out["source"] = source
        else:
            missing.append(schema_file)
        rows.append(out)
    return rows, missing


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--map", default=DEFAULT_PROFILE_MAP)
    parser.add_argument("--schema-dir")
    parser.add_argument("--source-manifest", default=DEFAULT_SOURCE_MANIFEST)
    parser.add_argument("--out", default=DEFAULT_REPORT)
    parser.add_argument("--list-required-schemas", action="store_true")
    parser.add_argument("--require-all-schemas", action="store_true")
    parser.add_argument("--strict-source-manifest", action="store_true")
    args = parser.parse_args()

    root = Path.cwd()
    profile_map_path = rooted(root, args.map)
    source_manifest_path = rooted(root, args.source_manifest)
    out_path = rooted(root, args.out)
    profile_map = json.loads(profile_map_path.read_text())
    source_manifest, source_manifest_found = load_source_manifest(source_manifest_path)
    required_schemas, missing_source_metadata = required_schema_rows(profile_map, source_manifest)

    if args.list_required_schemas:
        print(json.dumps({
            "runner": "thebes-xsd-profile-runner-v1",
            "map": args.map,
            "sourceManifest": args.source_manifest,
            "sourceManifestFound": source_manifest_found,
            "requiredSchemaCount": len(required_schemas),
            "missingSourceMetadata": missing_source_metadata,
            "requiredSchemas": required_schemas,
        }, indent=2, sort_keys=True))
        if args.strict_source_manifest and missing_source_metadata:
            return 1
        return 0

    if args.schema_dir is None:
        parser.error("--schema-dir is required unless --list-required-schemas is used")
    schema_dir = rooted(root, args.schema_dir)

    results = []
    failing = len(missing_source_metadata) if args.strict_source_manifest else 0
    with tempfile.TemporaryDirectory(prefix="thebes-xsd-fixtures-") as tmp:
        tmp_dir = Path(tmp)
        for item in profile_map["fixtures"]:
            fixture = root / item["path"]
            schema_file = item.get("schemaFile")
            source, source_status = item_source(item, source_manifest)
            result = {
                "id": item["id"],
                "path": item["path"],
                "profile": item["profile"],
                "messageKind": item["messageKind"],
                "schemaFile": schema_file,
                "expected": item["expected"],
                "sha256": sha256_file(fixture) if fixture.exists() else None,
                "sourceStatus": source_status,
                "status": "not-run",
                "detail": "",
            }
            if source is not None:
                result["source"] = source
            if not fixture.exists():
                result["status"] = "fixture-missing"
                result["detail"] = "fixture file is missing"
                failing += 1
            elif schema_file is None:
                result["status"] = "custom-profile"
                result["detail"] = "no standalone XSD; verify through canister/profile-specific runner"
            else:
                schema = schema_dir / schema_file
                if not schema.exists():
                    result["status"] = "schema-missing"
                    result["detail"] = f"missing schema {schema_file}"
                    if args.require_all_schemas:
                        failing += 1
                else:
                    raw = fixture.read_bytes()
                    xsd_payload, xsd_input = document_fragment(raw)
                    xsd_fixture = fixture
                    result["xsdInput"] = xsd_input
                    if xsd_input != "raw-fixture":
                        result["xsdSha256"] = sha256_bytes(xsd_payload)
                        xsd_fixture = tmp_dir / fixture.name
                        xsd_fixture.write_bytes(xsd_payload)
                    status, detail = run_xmllint(schema, xsd_fixture)
                    display_path = item["path"]
                    if xsd_input != "raw-fixture":
                        display_path += "#Document"
                    detail = portable_detail(detail, xsd_fixture, display_path)
                    result["status"] = status
                    result["detail"] = detail
                    # the verdict is judged against the map's expectation: a negative fixture is meant to be
                    # schema-invalid, a business-invalid one schema-valid
                    want_valid = item["expected"] != "schema-invalid"
                    result["asExpected"] = (status == "schema-valid") == want_valid
                    if not result["asExpected"]:
                        failing += 1
            results.append(result)

    report = {
        "runner": "thebes-xsd-profile-runner-v1",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "schemaDir": args.schema_dir,
        "map": args.map,
        "sourceManifest": args.source_manifest,
        "sourceManifestFound": source_manifest_found,
        "requiredSchemaCount": len(required_schemas),
        "requiredSchemas": required_schemas,
        "missingSourceMetadata": missing_source_metadata,
        "fixtureCount": len(results),
        "failingCount": failing,
        "ok": failing == 0,
        "results": results,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"ok": report["ok"], "failingCount": failing, "out": str(out_path)}, sort_keys=True))
    return 0 if failing == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
