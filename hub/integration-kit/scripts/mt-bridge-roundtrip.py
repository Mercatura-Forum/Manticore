#!/usr/bin/env python3
"""mt-bridge-roundtrip.py — the runner of the MT bridge (`motoko/iso/MtBridge.mo`).

For every FIN fixture of `integration-kit/legacy/mt-manifest.json`, in the Motoko interpreter from the same
source the canister is built from:

  1. MT → record → MT → record: the second reading equals the first (the bridge's own round trip);
  2. record → XML → record: the record written by the hub's codec (the compact codec for pain.001, pain.008,
     pacs.008, pacs.009, camt.053, camt.054 and the investigations; the schema-profile codec for camt.052,
     whose document is also checked with `xmllint --schema`) and read back equals the record;
  3. the FIN the bridge wrote is parsed by Prowide swift-core (SRU2025) as the same message type, with the
     fixture's field 20 / 21 / 32A / UETR values; the fixture itself parses the same way.

The mapping tables the canister carries (`MtBridge.mappings()`) are printed and written to
`integration-kit/legacy/mt-mappings.json`; with `--check-mappings` the file must already equal them.
Writes `integration-kit/profile-runner/mt-bridge-report.json`. Exit 0 only when every check holds.
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
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Result "mo:core/Result";
import ISO "../../../motoko/ISO20022";
import Xml "../../../motoko/ISO20022Xml";
import B "../../../motoko/iso/IsoBreadth";
import MT "../../../motoko/iso/MtBridge";

func minorUnitsOf(c : Text) : ?Nat8 { switch (c) { case ("EGP" or "USD" or "EUR" or "GBP") ?2; case ("JPY") ?0; case (_) null } };
let g = ISO.crossBorderEducationGuideline();
func versions(kind : Text) : Text { for (v in g.messageVersions.vals()) { if (v.kind == kind) return v.version }; "001.01" };
let options : MT.Options = { creationDateTime = "2026-09-12T10:00:00Z"; settlementMethod = g.settlementMethod; country = "EG"; versions };
let parties : MT.Party = { sender = "NBEGEGCX"; receiver = "CIBEEGCX" };
func hex(b : Blob) : Text {
  let d = Text.toArray("0123456789abcdef");
  var o = "";
  for (x in b.vals()) { let n = Nat8.toNat(x); o #= Text.fromChar(d[n / 16]) # Text.fromChar(d[n % 16]) };
  o
};
func issues(is : [ISO.ValidationIssue]) : Text { var o = ""; for (i in is.vals()) o #= i.ruleId # "@" # i.path # ";"; o };
func xmlOf(m : MT.Message) : (Text, Text) {
  switch (m) {
    case (#pain001(ds)) ("pain.001", Xml.pain001ToXml(ds[0]));
    case (#pain008(ds)) ("pain.008", Xml.directDebitToXml(ds[0]));
    case (#pacs009(d)) ("pacs.009", Xml.pacs009ToXml(d));
    case (#cover(c)) ("cover.payment", Xml.coverPaymentToXml(c));
    case (#camt054(e)) ("camt.054", Xml.camt054ToXml(e));
    case (#camt053(es)) ("camt.053", Xml.camt053ToXml(es));
    case (#camt052(r)) ("camt.052", switch (B.accountReportXml(r, minorUnitsOf)) { case (#ok(x)) x; case (#err(_)) "" });
    case (#investigation(d)) ("investigation", Xml.investigationToXml(d));
  }
};
func backFromXml(m : MT.Message, xml : Text) : ?MT.Message {
  let b = Text.encodeUtf8(xml);
  switch (m) {
    case (#pain001(ds)) { switch (Xml.decodePain001(b)) { case (#ok(d)) ?#pain001([d]); case (#err(_)) null } };
    case (#pain008(ds)) { switch (Xml.decodeDirectDebit(b)) { case (#ok(d)) ?#pain008([d]); case (#err(_)) null } };
    case (#pacs009(_)) { switch (Xml.decodePacs009(b)) { case (#ok(d)) ?#pacs009(d); case (#err(_)) null } };
    case (#cover(_)) { switch (Xml.decodeCoverPayment(b)) { case (#ok(c)) ?#cover(c); case (#err(_)) null } };
    case (#camt054(_)) { switch (Xml.decodeCamt054(b)) { case (#ok(es)) { if (es.size() == 1) ?#camt054(es[0]) else null }; case (#err(_)) null } };
    case (#camt053(_)) { switch (Xml.decodeCamt053(b)) { case (#ok(es)) ?#camt053(es); case (#err(_)) null } };
    case (#camt052(_)) { let d = B.decode(b, minorUnitsOf); switch (d.message) { case (#ok(#accountReport(r))) ?#camt052(r); case (_) null } };
    case (#investigation(_)) { switch (Xml.decodeInvestigation(b)) { case (#ok(d)) ?#investigation(d); case (#err(_)) null } };
  }
};
func firstOnly(m : MT.Message) : MT.Message { switch (m) { case (#pain001(ds)) #pain001([ds[0]]); case (#pain008(ds)) #pain008([ds[0]]); case (x) x } };
func run(name : Text, mt : Text, fin : Text) {
  let d = MT.decode(Text.encodeUtf8(fin), null, options, minorUnitsOf);
  switch (d.message) {
    case (#err(e)) { Debug.print("DECODE " # name # " " # d.mtType # " err " # issues(e)); return };
    case (#ok(m)) {
      Debug.print("DECODE " # name # " " # d.mtType # " ok " # d.iso);
      switch (MT.encode(m, d.mtType, parties, minorUnitsOf)) {
        case (#err(e)) Debug.print("ENCODE " # name # " err " # issues(e));
        case (#ok(fin2)) {
          Debug.print("FIN " # name # " " # hex(Text.encodeUtf8(fin2)));
          let d2 = MT.decode(Text.encodeUtf8(fin2), null, options, minorUnitsOf);
          switch (d2.message) {
            case (#ok(m2)) Debug.print("EQ-MT " # name # " " # (if (MT.equalMessage(m, m2) and d2.mtType == d.mtType) "true" else "false"));
            case (#err(e)) Debug.print("EQ-MT " # name # " false " # issues(e));
          };
        };
      };
      // the XML round trip: the compact codecs read one message; a batch is checked on its first
      let (family, xml) = xmlOf(m);
      if (xml == "") { Debug.print("XML " # name # " " # family # " err"); return };
      Debug.print("XML " # name # " " # family # " " # hex(Text.encodeUtf8(xml)));
      switch (backFromXml(m, xml)) {
        case (?m2) Debug.print("EQ-XML " # name # " " # (if (MT.equalMessage(firstOnly(m), m2)) "true" else "false"));
        case null Debug.print("EQ-XML " # name # " false decode");
      };
    };
  };
};
func printMappings() {
  var o = "[";
  var first = true;
  for (m in MT.mappings().vals()) {
    o #= (if (first) "" else ",") # "{\"mt\":\"" # m.mt # "\",\"iso\":\"" # m.iso # "\",\"fields\":[";
    first := false;
    var f1 = true;
    for (f in m.fields.vals()) {
      o #= (if (f1) "" else ",") # "{\"field\":\"" # f.field # "\",\"element\":\"" # f.element # "\",\"note\":\"" # f.note # "\"}";
      f1 := false;
    };
    o #= "]}";
  };
  Debug.print("MAPPINGS " # o # "]");
};
printMappings();
'''


def moc_text(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def prowide(paths, work):
    if not paths or not os.path.isdir(PROWIDE) or shutil.which("java") is None:
        return None
    jars = ":".join(os.path.join(PROWIDE, j) for j in sorted(os.listdir(PROWIDE)) if j.endswith(".jar"))
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prowide", "ProwideMt.java")
    subprocess.run(["javac", "-cp", jars, "-d", work, src], check=True, capture_output=True)
    r = subprocess.run(["java", "-cp", jars + ":" + work, "ProwideMt", *paths], capture_output=True, text=True, timeout=1800)
    out = {}
    for l in r.stdout.splitlines():
        parts = l.split(" ", 3)
        if len(parts) == 4 and parts[0] in ("OK", "ROUNDTRIP-FAILED"):
            out[parts[3]] = {"ok": parts[0] == "OK", "type": parts[1], "fields": dict(kv.split("=", 1) for kv in parts[2].split(";"))}
        elif parts and parts[0] == "PARSE-FAILED":
            out[parts[1]] = {"ok": False, "type": "-", "fields": {}, "why": l}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="integration-kit/legacy/mt-manifest.json")
    ap.add_argument("--mappings", default="integration-kit/legacy/mt-mappings.json")
    ap.add_argument("--schemas", default="integration-kit/profile-runner/official-schemas/iso-base")
    ap.add_argument("--report", default="integration-kit/profile-runner/mt-bridge-report.json")
    ap.add_argument("--check-mappings", action="store_true", help="the mappings file must equal the canister's table (instead of being written)")
    ap.add_argument("--no-prowide", action="store_true")
    a = ap.parse_args()
    m = json.load(open(a.manifest))
    driver = DRIVER + "".join(f"run({moc_text(f['id'])}, {moc_text(f['mt'])}, {moc_text(open(f['path']).read())});\n" for f in m["fixtures"])
    work = tempfile.mkdtemp(prefix="mt-", dir="integration-kit/profile-runner")
    try:
        dp = os.path.join(work, "Driver.mo")
        open(dp, "w").write(driver)
        sources = subprocess.run(["mops", "sources"], cwd="motoko", capture_output=True, text=True, check=True).stdout.split()
        sources = [s if not s.startswith(".") and not s.startswith("thebes-lib") else os.path.abspath(os.path.join("motoko", s)) for s in sources]
        r = subprocess.run([MOC, "-r", *sources, dp], capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr[:3000], file=sys.stderr)
            return 2
        rows = {f["id"]: {"id": f["id"], "mt": f["mt"], "iso": f["iso"]} for f in m["fixtures"]}
        fins, xmls, mappings = {}, {}, None
        for l in (r.stdout + r.stderr).splitlines():
            p = l.split(" ", 2)
            if l.startswith("MAPPINGS "):
                mappings = json.loads(l[len("MAPPINGS "):])
            elif p[0] == "DECODE":
                _, name, rest = p; t, status, detail = rest.split(" ", 2)
                rows[name].update({"decodedType": t, "decode": status, "decodeDetail": detail})
            elif p[0] == "ENCODE":
                rows[p[1]]["encode"] = p[2]
            elif p[0] == "FIN":
                fins[p[1]] = bytes.fromhex(p[2].strip()).decode()
            elif p[0] == "EQ-MT":
                rows[p[1]]["mtRoundTrip"] = p[2]
            elif p[0] == "XML":
                fam, rest = p[2].split(" ", 1)
                rows[p[1]]["xmlFamily"] = fam
                if rest != "err":
                    xmls[p[1]] = bytes.fromhex(rest.strip()).decode()
                else:
                    rows[p[1]]["xml"] = "err"
            elif p[0] == "EQ-XML":
                rows[p[1]]["xmlRoundTrip"] = p[2]
        # the mapping tables: written, or checked
        if mappings is None:
            print("no mappings printed", file=sys.stderr)
            return 2
        if a.check_mappings:
            on_disk = json.load(open(a.mappings))
            if on_disk != mappings:
                print("MAPPINGS DRIFT: integration-kit/legacy/mt-mappings.json differs from MtBridge.mappings()", file=sys.stderr)
                return 1
        else:
            json.dump(mappings, open(a.mappings, "w"), indent=2)
        # camt.052 written by the schema-profile codec is xmllint-valid
        for name, xml in xmls.items():
            if rows[name].get("xmlFamily") == "camt.052":
                tp = os.path.join(work, name + ".xml")
                open(tp, "w").write(xml)
                x = subprocess.run(["xmllint", "--noout", "--schema", os.path.join(a.schemas, "camt.052.001.08.xsd"), tp], capture_output=True, text=True)
                rows[name]["camt052Xmllint"] = "schema-valid" if x.returncode == 0 else (x.stdout + x.stderr).strip()
        # Prowide on the fixtures and on what the bridge wrote
        pw_fixture = pw_written = None
        if not a.no_prowide:
            written = {}
            for name, fin in fins.items():
                wp = os.path.join(work, "written-" + name)
                open(wp, "w").write(fin)
                written[wp] = name
            pw_fixture = prowide([f["path"] for f in m["fixtures"]], work)
            pw_written = prowide(list(written.keys()), work)
            for f in m["fixtures"]:
                v = None if pw_fixture is None else pw_fixture.get(f["path"])
                rows[f["id"]]["prowideFixture"] = v
            for wp, name in written.items():
                v = None if pw_written is None else pw_written.get(wp)
                rows[name]["prowideWritten"] = v
        counts = {"fixtures": len(rows), "decoded": 0, "mtRoundTrip": 0, "xmlRoundTrip": 0, "prowideFixture": 0, "prowideWritten": 0, "types": sorted({r_["mt"] for r_ in rows.values()})}
        ok_all = True
        for f in m["fixtures"]:
            row = rows[f["id"]]
            good = row.get("decode") == "ok" and row.get("decodedType") == f["mt"]
            counts["decoded"] += int(good)
            good = good and row.get("mtRoundTrip") == "true"; counts["mtRoundTrip"] += int(row.get("mtRoundTrip") == "true")
            good = good and row.get("xmlRoundTrip") == "true"; counts["xmlRoundTrip"] += int(row.get("xmlRoundTrip") == "true")
            if row.get("xmlFamily") == "camt.052":
                good = good and row.get("camt052Xmllint") == "schema-valid"
            if not a.no_prowide:
                def agrees(v, keys):
                    if not v or not v["ok"] or v["type"] != f["mt"]:
                        return False
                    for k, want in keys.items():
                        if v["fields"].get(k, "") != want:
                            return False
                    return True
                pf, pwv = agrees(row.get("prowideFixture"), f["keys"]), agrees(row.get("prowideWritten"), f.get("writtenKeys", f["keys"]))
                counts["prowideFixture"] += int(pf); counts["prowideWritten"] += int(pwv)
                good = good and pf and pwv
            row["ok"] = good
            ok_all = ok_all and good
        report = {"summary": counts, "fixtures": list(rows.values()), "mappings": mappings}
        json.dump(report, open(a.report, "w"), indent=2)
        for row in rows.values():
            if not row["ok"]:
                print("FAIL", json.dumps(row)[:700])
        print(json.dumps(counts))
        return 0 if ok_all else 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
