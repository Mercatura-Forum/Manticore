#!/usr/bin/env python3
"""iso-breadth-mutations.py — the schema-derived profile check of the breadth families, in situ.

Every valid fixture of `integration-kit/xml/breadth-manifest.json` is mutated many times (an element deleted,
duplicated, renamed or swapped with its neighbour; a text emptied, lengthened past its facet, or corrupted as
an amount, a date, a BIC, a boolean; an attribute added or its currency lower-cased) and each mutant is judged
twice: by `xmllint --schema` against the official XSD and by the canister's generated profile
(`motoko/iso/IsoProfiles.mo` under `motoko/iso/IsoSchema.mo`, run in the Motoko interpreter from the same
source the canister is built from). The claim is zero disagreements — measured, not asserted. A business
file's payloads are judged against their own schemas on both sides, the way the canister reads them.

Writes `integration-kit/profile-runner/breadth-mutations-report.json`.
"""
import argparse
import copy
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

MOC = os.environ.get("MOC", os.path.expanduser("~/.cache/mops/moc/1.4.1/moc"))

DRIVER = r'''
import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Xml "../../../motoko/iso/Xml";
import IsoSchema "../../../motoko/iso/IsoSchema";

func judge(name : Text, xml : Text) {
  switch (Xml.parseMessage(Text.encodeUtf8(xml))) {
    case (#err(e)) Debug.print("VERDICT " # name # " invalid " # e.rule);
    case (#ok(roots)) {
      if (roots.size() != 1) { Debug.print("VERDICT " # name # " invalid XML-ROOT"); return };
      let root = roots[0];
      switch (IsoSchema.schemaFor(root.namespace)) {
        case null Debug.print("VERDICT " # name # " invalid ISO-XSD-ROOT");
        case (?sc) {
          var issues = IsoSchema.validate(sc, root);
          if (root.name == "Xchg") {
            for (pl in Xml.children(root, "Pyld").vals()) {
              for (payload in pl.children.vals()) {
                switch (IsoSchema.schemaFor(payload.namespace)) {
                  case (?ps) { for (i in IsoSchema.validate(ps, payload).vals()) issues := [i] };
                  case null { issues := [{ rule = "ISO-XSD-ROOT"; path = "/Xchg/Pyld"; detail = "" }] };
                };
              };
            };
          };
          if (issues.size() == 0) Debug.print("VERDICT " # name # " valid -") else Debug.print("VERDICT " # name # " invalid " # issues[0].rule # " " # issues[0].path);
        };
      };
    };
  };
};
'''

def moc_text(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def local(tag):
    return tag.split("}", 1)[1] if "}" in tag else tag


def all_elements(root):
    return [e for e in root.iter()]


def parent_map(root):
    return {c: p for p in root.iter() for c in p}


AMOUNT_TAGS = {"Amt", "IntrBkSttlmAmt", "RvsdIntrBkSttlmAmt", "RvsdInstdAmt", "MaxAmt", "AmtWthCcy", "OrgnlIntrBkSttlmAmt"}
DATE_TAGS = {"IntrBkSttlmDt", "ReqdColltnDt", "FrstColltnDt", "FrDt", "ToDt", "Dt", "XpctdValDt", "SttlmDt", "BizDt", "OrgnlIntrBkSttlmDt", "DtOfSgntr"}
DATETIME_TAGS = {"CreDtTm", "FrDtTm", "ToDtTm", "CreDtAndTm"}
BIC_TAGS = {"BICFI", "AnyBIC"}
BOOL_TAGS = {"TrckgInd", "Accptd", "PssblDplctFlg", "AnyInf"}


def mutate(root, rng):
    """One mutation of a copy of `root`; returns (kind, mutant) — kind names what was done."""
    m = copy.deepcopy(root)
    pm = parent_map(m)
    candidates = [e for e in all_elements(m) if e is not m and e in pm]
    e = rng.choice(candidates)
    p = pm[e]
    leafs = [x for x in candidates if len(x) == 0 and (x.text or "").strip()]
    kind = rng.choice(["delete", "duplicate", "swap", "rename", "empty", "lengthen", "corrupt", "attribute", "currency", "unknown-child"])
    if kind == "delete":
        p.remove(e)
    elif kind == "duplicate":
        idx = list(p).index(e)
        p.insert(idx + 1, copy.deepcopy(e))
    elif kind == "swap":
        kids = list(p)
        if len(kids) < 2:
            return mutate(root, rng)
        i = rng.randrange(len(kids) - 1)
        a, b = kids[i], kids[i + 1]
        p.remove(a); p.remove(b)
        p.insert(i, b); p.insert(i + 1, a)
    elif kind == "rename":
        e.tag = e.tag + "X"
    elif kind == "empty":
        if not leafs:
            return mutate(root, rng)
        l = rng.choice(leafs); l.text = ""
    elif kind == "lengthen":
        if not leafs:
            return mutate(root, rng)
        l = rng.choice(leafs); l.text = (l.text or "") + "Y" * rng.choice([1, 8, 40, 200])
    elif kind == "corrupt":
        if not leafs:
            return mutate(root, rng)
        l = rng.choice(leafs)
        t = local(l.tag)
        if t in AMOUNT_TAGS:
            l.text = rng.choice(["12.3.4", "-5.00", "1,000.00", "abc", "1234567890123456789.00", "0.000001"])
        elif t in DATE_TAGS:
            l.text = rng.choice(["2026-13-40", "20260912", "2026-09-12T10:00:00Z", "12/09/2026", "2026-02-30"])
        elif t in DATETIME_TAGS:
            l.text = rng.choice(["2026-09-12", "2026-09-12 10:00:00", "2026-09-12T25:00:00Z", "yesterday"])
        elif t in BIC_TAGS:
            l.text = rng.choice(["nbegegcxxxx", "NBEG", "NBEGEGCXXXXX", "NBEGEG1X", "12345678"])
        elif t in BOOL_TAGS:
            l.text = rng.choice(["yes", "TRUE", "2", ""])
        else:
            l.text = rng.choice(["", " ", "x" * 36, "<", "ÄÖÜ", "café"])
    elif kind == "attribute":
        e.set("unexpected", "1")
    elif kind == "currency":
        ccy = [x for x in candidates if x.get("Ccy")]
        if not ccy:
            return mutate(root, rng)
        c = rng.choice(ccy)
        c.set("Ccy", rng.choice(["egp", "EG", "EGPP", "123", ""]))
    elif kind == "unknown-child":
        ET.SubElement(e, e.tag.split("}")[0] + "}Unknwn").text = "1"
    return kind, m


def serialize(root):
    ET.register_namespace("", root.tag.split("}")[0][1:])
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(root, encoding="unicode")


def xmllint(schema_dir, families, xml_text, work, name):
    """xmllint's verdict; a head.002 file is its own verdict plus each payload's against its own schema."""
    root = ET.fromstring(xml_text.encode())
    ns = root.tag.split("}")[0][1:]
    fam = ns.rsplit(":", 1)[1]
    if fam + ".xsd" not in os.listdir(schema_dir):
        return "invalid"
    path = os.path.join(work, name + ".xml")
    open(path, "w").write(xml_text)
    r = subprocess.run(["xmllint", "--noout", "--schema", os.path.join(schema_dir, fam + ".xsd"), path], capture_output=True, text=True)
    if r.returncode != 0:
        return "invalid"
    if local(root.tag) == "Xchg":
        for i, pl in enumerate(root):
            if local(pl.tag) != "Pyld":
                continue
            for j, payload in enumerate(pl):
                pns = payload.tag.split("}")[0][1:]
                pfam = pns.rsplit(":", 1)[1]
                if pfam + ".xsd" not in os.listdir(schema_dir):
                    return "invalid"
                ppath = os.path.join(work, f"{name}-p{i}-{j}.xml")
                ET.register_namespace("", pns)
                open(ppath, "w").write(ET.tostring(payload, encoding="unicode"))
                pr = subprocess.run(["xmllint", "--noout", "--schema", os.path.join(schema_dir, pfam + ".xsd"), ppath], capture_output=True, text=True)
                if pr.returncode != 0:
                    return "invalid"
    return "valid"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="integration-kit/xml/breadth-manifest.json")
    ap.add_argument("--schemas", default="integration-kit/profile-runner/official-schemas/iso-base")
    ap.add_argument("--report", default="integration-kit/profile-runner/breadth-mutations-report.json")
    ap.add_argument("--per-fixture", type=int, default=60)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    m = json.load(open(a.manifest))
    work = tempfile.mkdtemp(prefix="mut-", dir="integration-kit/profile-runner")
    try:
        mutants = []   # (name, kind, xml, xmllint verdict)
        for f in m["valid"]:
            root = ET.fromstring(open(f["path"], "rb").read())
            for k in range(a.per_fixture):
                kind, mut = mutate(root, rng)
                xml_text = serialize(mut)
                name = f"{f['id'].split('/')[1][:-4]}-{k}"
                mutants.append((name, kind, xml_text, xmllint(a.schemas, m["families"], xml_text, work, name)))
        # the canister's side, in batches the interpreter takes comfortably
        verdicts = {}
        sources = subprocess.run(["mops", "sources"], cwd="motoko", capture_output=True, text=True, check=True).stdout.split()
        sources = [s if not s.startswith(".") and not s.startswith("thebes-lib") else os.path.abspath(os.path.join("motoko", s)) for s in sources]
        B = 200
        for start in range(0, len(mutants), B):
            drv = DRIVER + "".join(f"judge({moc_text(n)}, {moc_text(x)});\n" for n, _, x, _ in mutants[start:start + B])
            dp = os.path.join(work, f"Driver{start}.mo")
            open(dp, "w").write(drv)
            r = subprocess.run([MOC, "-r", *sources, dp], capture_output=True, text=True)
            if r.returncode != 0:
                print(r.stderr[:2000], file=sys.stderr)
                return 2
            for l in (r.stdout + r.stderr).splitlines():
                if l.startswith("VERDICT "):
                    parts = l.split(" ", 3)
                    verdicts[parts[1]] = (parts[2], parts[3] if len(parts) > 3 else "")
        rows, disagreements, kinds = [], [], {}
        for name, kind, xml_text, lint in mutants:
            v, why = verdicts.get(name, ("missing", ""))
            agree = v == lint
            kinds.setdefault(kind, {"n": 0, "invalid": 0})
            kinds[kind]["n"] += 1
            kinds[kind]["invalid"] += int(lint == "invalid")
            row = {"mutant": name, "kind": kind, "xmllint": lint, "canister": v, "rule": why.split(" ")[0] if why else "", "agree": agree}
            rows.append(row)
            if not agree:
                disagreements.append(row)
                open(os.path.join("integration-kit/profile-runner", f"disagreement-{name}.xml"), "w").write(xml_text)
        summary = {"mutants": len(mutants), "xmllintInvalid": sum(1 for r_ in rows if r_["xmllint"] == "invalid"), "xmllintValid": sum(1 for r_ in rows if r_["xmllint"] == "valid"), "disagreements": len(disagreements), "byKind": kinds,
                   "rulesSeen": sorted({r_["rule"] for r_ in rows if r_["rule"]})}
        json.dump({"summary": summary, "disagreements": disagreements, "mutants": rows}, open(a.report, "w"), indent=2)
        for d in disagreements[:20]:
            print("DISAGREE", d)
        print(json.dumps(summary))
        return 1 if disagreements else 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
