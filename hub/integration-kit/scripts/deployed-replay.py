#!/usr/bin/env python3
"""Replay integration-kit fixtures against a deployed ISO 20022 canister.

Drives the deployed hub end to end through the Thebes CLI (`thebes-deploy`):
`thebes-deploy call`  submits update calls, `thebes-deploy query` runs queries.
Method arguments are passed in Candid's textual form via `--arg`. No external
tooling — the hub lives on Thebes.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "thebes.toml"


def blob_text(payload: bytes) -> str:
    return 'blob "' + "".join(f"\\{byte:02x}" for byte in payload) + '"'


def file_blob(path: Path) -> str:
    return blob_text(path.read_bytes())


def sha_blob(path: Path) -> str:
    return blob_text(hashlib.sha256(path.read_bytes()).digest())


def sha_blob_bytes(payload: bytes) -> str:
    return blob_text(hashlib.sha256(payload).digest())


def replay_suffix() -> str:
    return f"R{int(time.time() * 1000) % 1_000_000_000:09d}"


def unique_replay_payloads(fixtures: Path, suffix: str) -> tuple[bytes, bytes, bytes, str, str]:
    original_msg_id = "ISO-HUB-20260622-000001"
    original_uetr = "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011"
    msg_id = f"ISO-HUB-{suffix}"
    uetr = str(uuid.uuid4())

    pain001 = (fixtures / "valid" / "pain001-eg-domestic.xml").read_text()
    pain001 = pain001.replace(original_msg_id, msg_id).replace(original_uetr, uetr)

    settled = (fixtures / "valid" / "status-pacs002-settled.xml").read_text()
    settled = (
        settled.replace(f"PACS002-{original_msg_id}", f"PACS002-{suffix}")
        .replace(original_msg_id, msg_id)
        .replace(original_uetr, uetr)
    )

    mismatch = (fixtures / "invalid" / "status-uetr-mismatch.xml").read_text()
    mismatch = mismatch.replace("PACS002-UETR-MISMATCH-000001", f"PACS002-MISMATCH-{suffix}").replace(original_msg_id, msg_id)

    return pain001.encode(), settled.encode(), mismatch.encode(), msg_id, uetr


def thebes(args: argparse.Namespace, method: str, candid_arg: str | None = None, query: bool = False) -> str:
    """Submit a call/query through the Thebes CLI and return its stdout.

    Global flags (`--manifest`, `--network`, `--identity`) precede the verb,
    matching `thebes-deploy [OPTIONS] <COMMAND>`.
    """
    cmd = ["thebes-deploy", "--manifest", str(args.manifest)]
    if args.network:
        cmd += ["--network", args.network]
    if args.identity:
        cmd += ["--identity", args.identity]
    cmd += ["query" if query else "call", args.canister, method]
    display = list(cmd)
    if candid_arg is not None:
        cmd += ["--arg", candid_arg]
        display += ["--arg", "..." if len(candid_arg) > 120 else candid_arg]
    print("$ " + " ".join(display), flush=True)
    if args.dry_run:
        return ""
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    print(proc.stdout.strip(), flush=True)
    if proc.returncode != 0:
        raise RuntimeError(f"{method} failed with exit code {proc.returncode}")
    return proc.stdout


def transport_arg(connector_id: str, remote_id: str, sequence: int, fmt: str, fixture: Path, endpoint: str | None) -> str:
    return transport_arg_payload(connector_id, remote_id, sequence, fmt, fixture.read_bytes(), endpoint)


def transport_arg_payload(connector_id: str, remote_id: str, sequence: int, fmt: str, payload: bytes, endpoint: str | None) -> str:
    endpoint_arg = f'opt "{endpoint}"' if endpoint else "null"
    sent_at = int(time.time() * 1_000_000_000)
    return f"""(record {{
  connectorId = "{connector_id}";
  remoteId = "{remote_id}";
  sequence = {sequence} : nat;
  format = "{fmt}";
  payload = {blob_text(payload)};
  payloadHash = {sha_blob_bytes(payload)};
  signature = null;
  sentAt = {sent_at} : int;
  traceId = "TRACE-{remote_id}";
  endpoint = {endpoint_arg};
}})"""


def connector_registration_arg(connector_id: str, endpoint: str | None) -> str:
    endpoint_vec = f'vec {{ "{endpoint}" }}' if endpoint else "vec {}"
    return f"""(
  "{connector_id}",
  null,
  vec {{
    "pain.001.xml";
    "pain.008.xml";
    "pacs.003.xml";
    "pacs.008.xml";
    "pacs.009.xml";
    "cover.payment.xml";
    "pain.002.xml";
    "pacs.002.xml";
    "pacs.004.xml";
    "camt.056.xml";
    "camt.029.xml";
    "pacs.028.xml";
    "camt.110.xml";
    "camt.111.xml";
    "pain.013.xml";
    "pain.014.xml";
    "camt.055.xml";
    "admi.002.xml";
    "admi.004.xml";
    "admi.007.xml";
    "admi.011.xml";
    "camt.053.xml";
    "camt.054.xml";
    "mt103";
    "mt940";
    "mt942";
    "csv.payments";
    "fixed.payments";
  }},
  {endpoint_vec}
)"""


def extract_payment_id(output: str) -> int:
    patterns = [
        r"variant\s*\{\s*ok\s*=\s*record\s*\{.*?\bid\s*=\s*([0-9_]+)\s*:\s*nat",
        r"#ok\s*\(\s*record\s*\{.*?\bid\s*=\s*([0-9_]+)",
        r"\bid\s*=\s*([0-9_]+)\s*:\s*nat",
    ]
    for pattern in patterns:
        match = re.search(pattern, output, re.S)
        if match:
            return int(match.group(1).replace("_", ""))
    raise RuntimeError("could not extract payment id from submitPain001Xml output")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--canister", default="iso20022", help="canister name in thebes.toml (or an explicit cid)")
    parser.add_argument("--manifest", default=str(MANIFEST), help="path to thebes.toml")
    parser.add_argument("--network", default="", help="override the manifest's default network")
    parser.add_argument("--identity", default="", help="override the active thebes-deploy identity")
    parser.add_argument("--connector-id", default="", help="connector id to reuse; default creates a per-run connector id")
    parser.add_argument("--endpoint", default="sftp://bank-eg-001/incoming")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--skip-lifecycle", action="store_true")
    parser.add_argument("--skip-c7-c8", action="store_true")
    parser.add_argument("--skip-dispatch", action="store_true")
    parser.add_argument("--include-dispatch", action="store_true")
    parser.add_argument("--preserve-compliance-profile", action="store_true")
    parser.add_argument("--payment-id", type=int, help="resume lifecycle replay from an existing payment id")
    args = parser.parse_args()

    fixtures = ROOT / "integration-kit" / "xml"
    suffix = replay_suffix()
    if not args.connector_id:
        args.connector_id = f"bank-eg-001-{suffix.lower()}"
    pain001_payload, settled_payload, mismatch_payload, _, _ = unique_replay_payloads(fixtures, suffix)
    thebes(args, "supportedStandards", query=True)
    thebes(args, "capabilities", query=True)
    thebes(args, "verifyOracleReadiness", query=True)
    thebes(args, "xmlProfileFixtureRegistry", query=True)

    validation_calls = [
        ("validatePain001Xml", fixtures / "valid" / "pain001-eg-domestic.xml"),
        ("validatePacs008Xml", fixtures / "valid" / "pacs008-eg-domestic.xml"),
        ("validatePacs009Xml", fixtures / "valid" / "pacs009-cbprplus-core.xml"),
        ("validateDirectDebitXml", fixtures / "valid" / "direct-debit-pain008-sdd.xml"),
        ("validateDirectDebitXml", fixtures / "valid" / "direct-debit-pacs003-sdd.xml"),
        ("validateInvestigationXml", fixtures / "valid" / "investigation-camt110-request.xml"),
        ("validateRequestToPayXml", fixtures / "valid" / "request-pain013-rfp.xml"),
        ("validateAdministrativeXml", fixtures / "valid" / "admin-admi007-ack.xml"),
        ("validateStatusReportXml", fixtures / "valid" / "status-pacs002-settled.xml"),
        ("validateCamt053Xml", fixtures / "valid" / "camt053-statement.xml"),
        ("validateCamt054Xml", fixtures / "valid" / "camt054-notification.xml"),
    ]
    for method, fixture in validation_calls:
        arg = f"({file_blob(fixture)})" if method != "validateStatusReportXml" else f"({file_blob(fixture)}, opt \"pacs.002\")"
        thebes(args, method, arg, query=True)

    if not args.skip_c7_c8:
        thebes(args, "claimOwner")
        thebes(args, "seedDemoParticipantDirectory")
        thebes(args, "correlateDemoDirectDebitReturnWorkflow")
        thebes(args, "correlateDemoRequestToPayWorkflow")
        thebes(args, "listParticipantDirectory", "(0 : nat, 20 : nat)", query=True)
        thebes(args, "listWorkflowStates", "(0 : nat, 20 : nat)", query=True)
        thebes(args, "verifyParticipantWorkflowCorrelation", query=True)
        thebes(args, "pfmiSelfAssessment", query=True)
        thebes(args, "verifyPfmiSelfAssessment", query=True)
        thebes(args, "verifyOracleReadiness", query=True)

    if args.skip_lifecycle:
        return 0

    if args.payment_id is None:
        thebes(args, "claimOwner")
        if not args.preserve_compliance_profile:
            thebes(args, "resetComplianceProfile")
        thebes(args, "registerConnector", connector_registration_arg(args.connector_id, args.endpoint))
        thebes(args, "useThebesCallerAuth", f'("{args.connector_id}")')

        submit_out = thebes(args, "submitPain001Xml", f"({blob_text(pain001_payload)})")
        payment_id = 0 if args.dry_run else extract_payment_id(submit_out)
    else:
        payment_id = args.payment_id
    if args.include_dispatch and not args.skip_dispatch:
        thebes(args, "dispatchPacs008", f"({payment_id} : nat)")
    thebes(args, "submitTransportEnvelope", transport_arg_payload(args.connector_id, f"REPLAY-PACS002-SETTLED-{suffix}", 0, "pacs.002.xml", settled_payload, args.endpoint))
    thebes(args, "submitTransportEnvelope", transport_arg_payload(args.connector_id, f"REPLAY-PACS002-MISMATCH-{suffix}", 1, "pacs.002.xml", mismatch_payload, args.endpoint))
    thebes(args, "verifyPaymentPhases", f"({payment_id} : nat)", query=True)
    thebes(args, "paymentXmlBundle", f"({payment_id} : nat)", query=True)
    thebes(args, "auditTip", query=True)
    thebes(args, "secondaryIndexHealth", query=True)
    thebes(args, "listDeadLetters", "(0 : nat, 20 : nat)", query=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
