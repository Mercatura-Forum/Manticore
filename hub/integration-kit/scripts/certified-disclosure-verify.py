#!/usr/bin/env python3
"""Externally recompute and check the C6 certified disclosure commitment.

Drives the deployed hub through the Thebes CLI (`thebes-deploy query`). The
canister exposes JSON twins of the certified-disclosure methods
(`certifiedAuditDisclosureJson`, `certifiedDisclosureCertificateJson`,
`listCertifiedParticipantBalancesJson`, `verifyCertifiedDisclosureJson`) that
return their fields as a JSON string — blobs as byte arrays, optionals as
`[]`/`[value]`, big integers as decimal strings — so every hash is recomputed
here with no Candid decoder and no external client library. The CLI's `--json`
mode surfaces the substrate reply wrapper `{status, reply (hex), error}`; this
script hex-decodes `reply` (canonical Candid for a single `text` return) and
parses the embedded JSON."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "thebes.toml"

ZERO_HASH = bytes(32)


@dataclass
class Check:
    name: str
    ok: bool
    detail: str = ""


def candid_int(value: Any, path: str) -> int:
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value.replace("_", ""))
    raise TypeError(f"{path} is not a Candid integer: {value!r}")


def candid_nat(value: Any, path: str) -> int:
    n = candid_int(value, path)
    if n < 0:
        raise ValueError(f"{path} must be non-negative")
    return n


def candid_blob(value: Any, path: str) -> bytes:
    if isinstance(value, list) and all(isinstance(item, int) for item in value):
        return bytes(value)
    raise TypeError(f"{path} is not a Candid blob byte array")


def candid_opt(value: Any, path: str) -> Any | None:
    if value == []:
        return None
    if isinstance(value, list) and len(value) == 1:
        return value[0]
    raise TypeError(f"{path} is not a Candid optional value")


def opt_blob(value: Any, path: str) -> bytes | None:
    raw = candid_opt(value, path)
    return None if raw is None else candid_blob(raw, path)


def opt_nat(value: Any, path: str) -> int | None:
    raw = candid_opt(value, path)
    return None if raw is None else candid_nat(raw, path)


def opt_text(value: Any, path: str) -> str | None:
    raw = candid_opt(value, path)
    if raw is None:
        return None
    if not isinstance(raw, str):
        raise TypeError(f"{path} is not optional text")
    return raw


def opt_principal(value: Any, path: str) -> str | None:
    return opt_text(value, path)


def hex_blob(value: bytes) -> str:
    return value.hex()


def principal_blob(text: str) -> bytes:
    compact = text.replace("-", "").upper()
    padded = compact + "=" * ((8 - len(compact) % 8) % 8)
    raw = base64.b32decode(padded)
    if len(raw) < 4:
        raise ValueError(f"invalid principal text: {text}")
    checksum = raw[:4]
    body = raw[4:]
    expected = (zlib.crc32(body) & 0xFFFFFFFF).to_bytes(4, "big")
    if checksum != expected:
        raise ValueError(f"principal checksum mismatch for {text}")
    return body


def append_nat(base: bytes, n: int) -> bytes:
    if n < 0:
        raise ValueError("Nat cannot be negative")
    if n == 0:
        return base + b"\x01\x00"
    byte_count = (n.bit_length() + 7) // 8
    if byte_count > 255:
        raise ValueError("Nat is too large for the canister's one-byte length prefix")
    return base + bytes([byte_count]) + n.to_bytes(byte_count, "big")


def append_blob(base: bytes, value: bytes) -> bytes:
    return append_nat(base, len(value)) + value


def append_text(base: bytes, value: str) -> bytes:
    raw = value.encode("utf-8")
    return append_blob(append_nat(base, len(raw)), raw)


def append_opt_blob(base: bytes, value: bytes | None) -> bytes:
    if value is None:
        return base + b"\x00"
    return append_blob(base + b"\x01", value)


def append_opt_nat(base: bytes, value: int | None) -> bytes:
    if value is None:
        return base + b"\x00"
    return append_nat(base + b"\x01", value)


def append_opt_text(base: bytes, value: str | None) -> bytes:
    if value is None:
        return base + b"\x00"
    return append_text(base + b"\x01", value)


def append_icrc_account(base: bytes, account: dict[str, Any]) -> bytes:
    owner = account.get("owner")
    if not isinstance(owner, str):
        raise TypeError("$.account.owner must be a principal string")
    preimage = append_blob(base, principal_blob(owner))
    return append_opt_blob(preimage, opt_blob(account.get("subaccount"), "$.account.subaccount"))


def sha256(value: bytes) -> bytes:
    return hashlib.sha256(value).digest()


def hash_node(left: bytes, right: bytes) -> bytes:
    return sha256(append_blob(append_blob(b"\x01", left), right))


def certified_audit_snapshot_hash(snapshot: dict[str, Any]) -> bytes:
    preimage = b"CERT-AUDIT"
    preimage = append_text(preimage, str(candid_int(snapshot["capturedAt"], "$.audit.capturedAt")))
    preimage = append_nat(preimage, candid_nat(snapshot["count"], "$.audit.count"))
    preimage = append_opt_nat(preimage, opt_nat(snapshot["lastAuditId"], "$.audit.lastAuditId"))
    preimage = append_opt_blob(preimage, opt_blob(snapshot["lastAuditHash"], "$.audit.lastAuditHash"))
    preimage = append_opt_blob(preimage, opt_blob(snapshot["merkleRoot"], "$.audit.merkleRoot"))
    preimage = append_opt_blob(preimage, opt_blob(snapshot["mmrRoot"], "$.audit.mmrRoot"))
    preimage = append_nat(preimage, candid_nat(snapshot["mmrLeafCount"], "$.audit.mmrLeafCount"))
    preimage = append_nat(preimage, candid_nat(snapshot["mmrPeakCount"], "$.audit.mmrPeakCount"))
    preimage = append_text(preimage, snapshot["guidelineId"])
    return sha256(preimage)


def certified_participant_balance_hash(snapshot: dict[str, Any]) -> bytes:
    preimage = b"CERT-BAL"
    preimage = append_text(preimage, snapshot["bicfi"])
    preimage = append_icrc_account(preimage, snapshot["account"])
    ledger = opt_principal(snapshot["ledgerCanister"], "$.balance.ledgerCanister")
    if ledger is None:
        preimage += b"\x00"
    else:
        preimage = append_blob(preimage + b"\x01", principal_blob(ledger))
    preimage = append_opt_text(preimage, opt_text(snapshot["currency"], "$.balance.currency"))
    preimage = append_nat(preimage, candid_nat(snapshot["balance"], "$.balance.balance"))
    preimage = append_text(preimage, str(candid_int(snapshot["capturedAt"], "$.balance.capturedAt")))
    return sha256(preimage)


def certified_balance_root(balances: list[dict[str, Any]]) -> bytes:
    if not balances:
        return ZERO_HASH
    level = [candid_blob(balance["snapshotHash"], "$.balance.snapshotHash") for balance in balances]
    while len(level) > 1:
        next_level = []
        for i in range(0, len(level), 2):
            left = level[i]
            right = level[i + 1] if i + 1 < len(level) else left
            next_level.append(hash_node(left, right))
        level = next_level
    return level[0]


def certified_disclosure_root_hash(root: dict[str, Any]) -> bytes:
    preimage = b"CERT-DISC"
    preimage = append_text(preimage, root["version"])
    preimage = append_text(preimage, str(candid_int(root["updatedAt"], "$.root.updatedAt")))
    preimage = append_blob(preimage, candid_blob(root["auditSnapshotHash"], "$.root.auditSnapshotHash"))
    preimage = append_blob(preimage, candid_blob(root["balanceRoot"], "$.root.balanceRoot"))
    preimage = append_nat(preimage, candid_nat(root["balanceCount"], "$.root.balanceCount"))
    return sha256(preimage)


def flatten_forks(tree: Any) -> list[Any]:
    if not isinstance(tree, list) or not tree:
        return []
    if tree[0] == 0:
        return []
    if tree[0] == 1:
        return flatten_forks(tree[1]) + flatten_forks(tree[2])
    return [tree]


def lookup_hash_tree(path: list[bytes], tree: Any) -> bytes | None:
    if not path:
        if isinstance(tree, list) and len(tree) == 2 and tree[0] == 3:
            return tree[1]
        return None
    label = path[0]
    for candidate in flatten_forks(tree):
        if isinstance(candidate, list) and len(candidate) == 3 and candidate[0] == 2 and candidate[1] == label:
            return lookup_hash_tree(path[1:], candidate[2])
    return None


def certified_data_from_certificate(certificate: bytes, canister_id: str) -> bytes:
    try:
        import cbor2  # type: ignore
    except ImportError as exc:
        raise RuntimeError("certificate-tree verification requires the cbor2 Python package") from exc
    decoded = cbor2.loads(certificate)
    tree = decoded.get("tree")
    if tree is None:
        raise ValueError("certificate is missing a hash tree")
    leaf = lookup_hash_tree([b"canister", principal_blob(canister_id), b"certified_data"], tree)
    if leaf is None:
        raise ValueError("certificate does not reveal /canister/<id>/certified_data")
    return leaf


def run(cmd: list[str]) -> str:
    """Run a command, returning stdout. stderr is kept separate so validator
    probe diagnostics never contaminate the JSON wrapper on stdout."""
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if proc.returncode != 0:
        detail = (proc.stdout + proc.stderr).strip()
        raise RuntimeError(f"{' '.join(cmd)} failed:\n{detail}")
    return proc.stdout


def _read_uleb(buf: bytes, pos: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        if pos >= len(buf):
            raise ValueError("truncated LEB128 integer in Candid reply")
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not (byte & 0x80):
            return result, pos
        shift += 7


def _read_sleb(buf: bytes, pos: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        if pos >= len(buf):
            raise ValueError("truncated SLEB128 integer in Candid reply")
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if not (byte & 0x80):
            if byte & 0x40:
                result |= -(1 << shift)
            return result, pos


CANDID_TEXT_OPCODE = -15  # primitive `text` in Candid's type grammar


def decode_candid_text_reply(raw: bytes) -> str:
    """Decode canonical Candid wire bytes for a single `text` return value.

    All four disclosure methods return `async Text`, so the reply is always
    `DIDL` + an empty type table + one argument of primitive type `text`. We
    decode exactly that shape rather than pulling in a full Candid library."""
    if raw[:4] != b"DIDL":
        raise ValueError("reply is not Candid-encoded (missing DIDL magic)")
    pos = 4
    type_table_len, pos = _read_uleb(raw, pos)
    if type_table_len != 0:
        raise ValueError(
            f"reply carries a {type_table_len}-entry Candid type table; "
            "a `query Text` method emits only the primitive `text` opcode"
        )
    arg_count, pos = _read_uleb(raw, pos)
    if arg_count != 1:
        raise ValueError(f"expected exactly one return value, got {arg_count}")
    opcode, pos = _read_sleb(raw, pos)
    if opcode != CANDID_TEXT_OPCODE:
        raise ValueError(f"expected a text return (opcode {CANDID_TEXT_OPCODE}), got {opcode}")
    length, pos = _read_uleb(raw, pos)
    end = pos + length
    if end > len(raw):
        raise ValueError("declared text length exceeds the reply size")
    return raw[pos:end].decode("utf-8")


def thebes_text_reply(args: argparse.Namespace, method: str, candid_arg: str | None = None) -> str:
    """Query a method through `thebes-deploy --json` and return its text reply.

    Global flags (`--manifest`, `--network`, `--identity`, `--json`) precede the
    verb, matching `thebes-deploy [OPTIONS] <COMMAND>`."""
    cmd = ["thebes-deploy", "--manifest", str(args.manifest), "--json"]
    if args.network:
        cmd += ["--network", args.network]
    if args.identity:
        cmd += ["--identity", args.identity]
    cmd += ["query", args.canister, method]
    if candid_arg is not None:
        cmd += ["--arg", candid_arg]
    out = run(cmd).strip()
    brace = out.find("{")
    if brace == -1:
        raise RuntimeError(f"{method}: no JSON reply wrapper in CLI output:\n{out}")
    wrapper = json.loads(out[brace:])
    status = wrapper.get("status")
    if status != "success":
        raise RuntimeError(f"{method}: query status={status!r} error={wrapper.get('error')!r}")
    hex_reply = wrapper.get("reply")
    if not hex_reply:
        raise RuntimeError(f"{method}: query returned no reply payload")
    return decode_candid_text_reply(bytes.fromhex(hex_reply))


def thebes_json(args: argparse.Namespace, method: str, candid_arg: str | None = None) -> Any:
    return json.loads(thebes_text_reply(args, method, candid_arg))


def thebes_canister_id(args: argparse.Namespace) -> str:
    """Resolve the canister id used for the certificate-tree lookup and the
    report. Mirrors how `thebes-deploy` maps a `--canister <alias>` to its
    numeric cid in the manifest; an explicit `--canister-id` always wins."""
    if args.canister_id:
        return args.canister_id
    try:
        text = Path(args.manifest).read_text()
    except OSError:
        return args.canister
    section = f"[canisters.{args.canister}]"
    idx = text.find(section)
    if idx != -1:
        rest = text[idx + len(section):]
        nxt = rest.find("\n[")
        block = rest if nxt == -1 else rest[:nxt]
        m = re.search(r"^\s*cid\s*=\s*([0-9_]+)", block, re.MULTILINE)
        if m:
            return m.group(1).replace("_", "")
    return args.canister


def add_check(checks: list[Check], name: str, ok: bool, detail: str = "") -> None:
    checks.append(Check(name, ok, detail))


def fetch_balances(args: argparse.Namespace) -> tuple[list[dict[str, Any]], int]:
    balances: list[dict[str, Any]] = []
    offset = 0
    total = 0
    while True:
        page = thebes_json(args, "listCertifiedParticipantBalancesJson", f"({offset} : nat, {args.balance_page_size} : nat)")
        items = page.get("items", [])
        if not isinstance(items, list):
            raise TypeError("listCertifiedParticipantBalances returned non-list items")
        balances.extend(items)
        total = candid_nat(page["total"], "$.balances.total")
        next_offset = opt_nat(page["nextOffset"], "$.balances.nextOffset")
        if next_offset is None:
            break
        if next_offset <= offset:
            raise ValueError("balance pagination did not advance")
        offset = next_offset
    return balances, total


def verify(args: argparse.Namespace) -> dict[str, Any]:
    checks: list[Check] = []
    canister_id = thebes_canister_id(args)
    disclosure = thebes_json(args, "certifiedAuditDisclosureJson")
    certificate_envelope = thebes_json(args, "certifiedDisclosureCertificateJson")
    balances, total = fetch_balances(args)
    root = disclosure["root"]
    audit = disclosure["audit"]
    ordered_balances = sorted(balances, key=lambda item: item["bicfi"])

    audit_snapshot_hash = certified_audit_snapshot_hash(audit)
    audit_hash = candid_blob(audit["snapshotHash"], "$.audit.snapshotHash")
    add_check(checks, "audit.snapshotHash", audit_snapshot_hash == audit_hash, hex_blob(audit_snapshot_hash))
    add_check(
        checks,
        "root.auditSnapshotHash",
        candid_blob(root["auditSnapshotHash"], "$.root.auditSnapshotHash") == audit_hash,
        hex_blob(audit_hash),
    )

    for balance in ordered_balances:
        computed = certified_participant_balance_hash(balance)
        stored = candid_blob(balance["snapshotHash"], "$.balance.snapshotHash")
        add_check(checks, f"balance.{balance['bicfi']}.snapshotHash", computed == stored, hex_blob(computed))

    add_check(
        checks,
        "balances.sortedByBicfi",
        [item["bicfi"] for item in balances] == [item["bicfi"] for item in ordered_balances],
        ",".join(item["bicfi"] for item in ordered_balances),
    )
    balance_root = certified_balance_root(ordered_balances)
    add_check(
        checks,
        "root.balanceRoot",
        candid_blob(root["balanceRoot"], "$.root.balanceRoot") == balance_root,
        hex_blob(balance_root),
    )
    add_check(
        checks,
        "root.balanceCount",
        candid_nat(root["balanceCount"], "$.root.balanceCount") == len(ordered_balances) == total,
        f"root={candid_nat(root['balanceCount'], '$.root.balanceCount')} fetched={len(ordered_balances)} total={total}",
    )

    root_hash = certified_disclosure_root_hash(root)
    stored_root_hash = candid_blob(root["rootHash"], "$.root.rootHash")
    add_check(checks, "root.rootHash", root_hash == stored_root_hash, hex_blob(root_hash))

    certificate_root = certificate_envelope["root"]
    add_check(
        checks,
        "certificateEnvelope.rootHash",
        candid_blob(certificate_root["rootHash"], "$.certificate.root.rootHash") == stored_root_hash,
        hex_blob(candid_blob(certificate_root["rootHash"], "$.certificate.root.rootHash")),
    )

    certificate = opt_blob(disclosure["certificate"], "$.certificate")
    if certificate is None:
        add_check(checks, "certificate.present", args.allow_missing_certificate, "missing")
    else:
        add_check(checks, "certificate.present", True, f"{len(certificate)} bytes")
        if not args.skip_certificate_tree:
            leaf = certified_data_from_certificate(certificate, canister_id)
            add_check(checks, "certificate.certified_data", leaf == stored_root_hash, hex_blob(leaf))

    if not args.skip_canister_verifier:
        report = thebes_json(args, "verifyCertifiedDisclosureJson")
        add_check(
            checks,
            "canister.verifyCertifiedDisclosure",
            bool(report.get("ok")) and candid_nat(report.get("issueCount", "0"), "$.verify.issueCount") == 0,
            f"ok={report.get('ok')} issues={report.get('issueCount')}",
        )

    ok = all(check.ok for check in checks)
    return {
        "ok": ok,
        "canisterId": canister_id,
        "rootHash": hex_blob(stored_root_hash),
        "balanceRoot": hex_blob(candid_blob(root["balanceRoot"], "$.root.balanceRoot")),
        "balanceCount": len(ordered_balances),
        "certificateTreeChecked": bool(certificate is not None and not args.skip_certificate_tree),
        "networkCertificateSignatureVerified": False,
        "networkCertificateSignatureNote": (
            "Deployment-network certificate/quorum signature validation is not implemented by this helper. "
            "For IC-compatible ICP deployments this means IC root-key/BLS validation; "
            "for Thebes production this means the Thebes network root or quorum proof."
        ),
        "checks": [check.__dict__ for check in checks],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--canister", default="iso20022", help="canister name in thebes.toml (or an explicit cid)")
    parser.add_argument("--canister-id", default="", help="canister id used for the certificate-tree lookup and report; defaults to the manifest cid")
    parser.add_argument("--manifest", default=str(MANIFEST), help="path to thebes.toml")
    parser.add_argument("--network", default="", help="override the manifest's default network")
    parser.add_argument("--identity", default="", help="override the active thebes-deploy identity")
    parser.add_argument("--balance-page-size", type=int, default=100)
    parser.add_argument("--skip-canister-verifier", action="store_true")
    parser.add_argument("--skip-certificate-tree", action="store_true")
    parser.add_argument("--allow-missing-certificate", action="store_true")
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args()

    if args.balance_page_size <= 0:
        raise ValueError("--balance-page-size must be positive")

    result = verify(args)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        status = "ok" if result["ok"] else "failed"
        print(f"certified disclosure verification: {status}")
        print(f"canisterId={result['canisterId']}")
        print(f"rootHash={result['rootHash']}")
        print(f"balanceRoot={result['balanceRoot']}")
        print(f"balanceCount={result['balanceCount']}")
        print(f"certificateTreeChecked={str(result['certificateTreeChecked']).lower()}")
        print("networkCertificateSignatureVerified=false")
        for check in result["checks"]:
            marker = "ok" if check["ok"] else "FAIL"
            suffix = f" ({check['detail']})" if check["detail"] else ""
            print(f"- {marker} {check['name']}{suffix}")
        print(
            "note: deployment-network certificate/quorum signature validation remains an operator hardening item "
            "(IC root-key/BLS for ICP, Thebes network proof for Thebes production)."
        )
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
