#!/usr/bin/env python3
"""iso-breadth-roundtrip.py — the off-canister oracle for `motoko/iso/IsoBreadth.mo`.

For every fixture in `integration-kit/xml/breadth-manifest.json` the module is run in the Motoko
interpreter (`moc -r`, the same source the canister is built from):

  * valid fixtures: the schema tier passes, the business tier reads a record, the record is written back,
    the written document is (a) valid under `xmllint --schema` against the official XSD, (b) read again into
    an equal record; and, when the Prowide jars are present, (c) parsed by Prowide's MX classes with the
    message id and the family agreeing;
  * invalid fixtures: the canister's first issue carries the expected rule id in the expected tier, and
    xmllint's verdict on the file is the one the manifest records.

Writes `integration-kit/profile-runner/breadth-report.json`. Exit 0 only when every check holds.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

MOC = os.environ.get("MOC", os.path.expanduser("~/.cache/mops/moc/1.4.1/moc"))
PROWIDE = os.environ.get("PROWIDE_JARS", os.path.join(os.environ.get("ORACLES", "oracles"), "iso20022"))

DRIVER = r'''
import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Result "mo:core/Result";
import B "../../../motoko/iso/IsoBreadth";

func minorUnitsOf(c : Text) : ?Nat8 { switch (c) { case ("EGP" or "USD" or "EUR" or "GBP") ?2; case ("JPY") ?0; case (_) null } };
let options = B.defaultEmitOptions("2026-09-12");
func hex(b : Blob) : Text {
  let d = "0123456789abcdef";
  var o = "";
  for (x in b.vals()) { let n = Nat8.toNat(x); o #= Text.fromChar(Text.toArray(d)[n / 16]) # Text.fromChar(Text.toArray(d)[n % 16]) };
  o
};
func issues(is : [B.Issue]) : Text { var o = ""; for (i in is.vals()) o #= i.rule # "@" # i.path # ";"; o };
func run(name : Text, xml : Text) {
  let bytes = Text.encodeUtf8(xml);
  let d = B.decode(bytes, minorUnitsOf);
  Debug.print("DECODE " # name # " family=" # d.family # " schema=" # issues(d.schemaIssues) # " business=" # (switch (d.message) { case (#ok(_)) "ok"; case (#err(e)) issues(e) }));
  switch (B.roundTrip(bytes, minorUnitsOf, options)) {
    case (#ok(out)) Debug.print("EMIT " # name # " " # hex(Text.encodeUtf8(out)));
    case (#err(e)) Debug.print("NOEMIT " # name # " " # issues(e));
  };
};
'''


def moc_text(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def prowide_batch(paths, work):
    """Prowide's verdicts for many documents at once: {path: (ok, mxId, messageId)}; None when the jars or java are absent."""
    if not paths or not os.path.isdir(PROWIDE) or shutil.which("java") is None:
        return None
    jars = ":".join(os.path.join(PROWIDE, j) for j in sorted(os.listdir(PROWIDE)) if j.endswith(".jar"))
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prowide", "ProwideParse.java")
    subprocess.run(["javac", "-cp", jars, "-d", work, src], check=True, capture_output=True)
    r = subprocess.run(["java", "-cp", jars + ":" + work, "ProwideParse", *paths], capture_output=True, text=True, timeout=1800)
    out = {}
    for l in r.stdout.splitlines():
        parts = l.split()
        if len(parts) >= 4 and parts[0] in ("OK", "ROUNDTRIP-FAILED"):
            out[parts[3]] = (parts[0] == "OK", parts[1], parts[2])
        elif parts and parts[0] == "PARSE-FAILED":
            out[parts[1]] = (False, "-", "-")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="integration-kit/xml/breadth-manifest.json")
    ap.add_argument("--schemas", default="integration-kit/profile-runner/official-schemas/iso-base")
    ap.add_argument("--report", default="integration-kit/profile-runner/breadth-report.json")
    ap.add_argument("--no-prowide", action="store_true")
    a = ap.parse_args()
    m = json.load(open(a.manifest))
    fixtures = [(f, "valid") for f in m["valid"]] + [(f, "invalid") for f in m["invalid"]]
    driver = DRIVER
    for f, _ in fixtures:
        driver += f"run({moc_text(f['id'])}, {moc_text(open(f['path']).read())});\n"
    work = tempfile.mkdtemp(prefix="breadth-", dir="integration-kit/profile-runner")
    try:
        drv = os.path.join(work, "Driver.mo")
        open(drv, "w").write(driver)
        sources = subprocess.run(["mops", "sources"], cwd="motoko", capture_output=True, text=True, check=True).stdout.split()
        # mops prints package paths relative to motoko/; the driver lives two levels below the repo root
        sources = [s if not s.startswith(".") and not s.startswith("thebes-lib") else os.path.abspath(os.path.join("motoko", s)) for s in sources]
        r = subprocess.run([MOC, "-r", *sources, drv], capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
            return 2
        lines = [l for l in (r.stdout + r.stderr).splitlines()]
        decode = {}
        emit = {}
        for l in lines:
            if l.startswith("DECODE "):
                _, name, rest = l.split(" ", 2)
                decode[name] = dict(kv.split("=", 1) for kv in re.findall(r"\w+=\S*", rest))
            elif l.startswith("EMIT "):
                _, name, hx = l.split(" ", 2)
                emit[name] = bytes.fromhex(hx.strip()).decode()
            elif l.startswith("NOEMIT "):
                _, name, why = l.split(" ", 2)
                emit[name] = ("ERR", why)
        report = {"fixtures": [], "summary": {}}
        prowide_jobs = []   # (emitted document path, report row, fixture); Prowide runs once over all of them
        ok_all = True
        counts = {"valid": 0, "valid_ok": 0, "invalid": 0, "invalid_ok": 0, "xmllint_emitted_valid": 0, "prowide_parsed": 0, "prowide_checked": 0}
        for f, kind in fixtures:
            name = f["id"]
            d = decode.get(name, {})
            row = {"id": name, "messageKind": f["messageKind"], "family": d.get("family"), "schema": d.get("schema", ""), "business": d.get("business", "")}
            if kind == "valid":
                counts["valid"] += 1
                good = d.get("schema", "x") == "" and d.get("business") == "ok" and isinstance(emit.get(name), str)
                if good:
                    out = emit[name]
                    xsd = os.path.join(a.schemas, f["schemaFile"])
                    with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False, dir=work) as t:
                        t.write(out)
                    x = subprocess.run(["xmllint", "--noout", "--schema", xsd, t.name], capture_output=True, text=True)
                    row["emittedXmllint"] = "schema-valid" if x.returncode == 0 else (x.stdout + x.stderr).strip()
                    good = x.returncode == 0
                    if good:
                        counts["xmllint_emitted_valid"] += 1
                    if not a.no_prowide and f["messageKind"] != "head.002":
                        prowide_jobs.append((t.name, row, f))
                    row["emitted"] = out
                else:
                    row["roundTrip"] = emit.get(name)
                row["ok"] = good
                counts["valid_ok"] += int(good)
            else:
                counts["invalid"] += 1
                first_schema = d.get("schema", "").split(";")[0].split("@")[0]
                first_biz = d.get("business", "").split(";")[0].split("@")[0]
                if f["tier"] == "schema":
                    good = first_schema == f["rule"]
                else:
                    good = d.get("schema", "x") == "" and first_biz == f["rule"]
                # and the emitter must not have produced anything
                good = good and not isinstance(emit.get(name), str)
                good = good and f["xmllint"] == f["xmllintExpected"]
                row.update({"expectedTier": f["tier"], "expectedRule": f["rule"], "ok": good})
                counts["invalid_ok"] += int(good)
            report["fixtures"].append(row)
        if prowide_jobs:
            verdicts = prowide_batch([p for p, _, _ in prowide_jobs], work)
            for path, row, f in prowide_jobs:
                counts["prowide_checked"] += 1
                v = None if verdicts is None else verdicts.get(path)
                if v is None:
                    row["prowide"] = "not run (jars or java absent)" if verdicts is None else "no verdict"
                    row["ok"] = False
                    continue
                good, mx_id, msg_id = v
                # the identifier Prowide must have kept: the message id, or an investigation's assignment id
                src_id = re.search(r"<(?:MsgId|PyldIdr)>([^<]+)</(?:MsgId|PyldIdr)>|<Assgnmt>\s*<Id>([^<]+)</Id>", open(f["path"]).read())
                src_id = next(g for g in src_id.groups() if g)
                row["prowide"] = {"ok": good, "mxId": mx_id, "messageId": msg_id}
                if good and mx_id == f["schemaFile"][:-4] and msg_id == src_id:
                    counts["prowide_parsed"] += 1
                else:
                    row["ok"] = False
        for row in report["fixtures"]:
            ok_all = ok_all and row["ok"]
        report["summary"] = counts
        json.dump(report, open(a.report, "w"), indent=2)
        for r_ in report["fixtures"]:
            if not r_["ok"]:
                print("FAIL", json.dumps({k: v for k, v in r_.items() if k != "emitted"})[:600])
        print(json.dumps(counts))
        return 0 if ok_all else 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
