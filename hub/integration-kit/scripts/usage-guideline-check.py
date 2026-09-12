#!/usr/bin/env python3
"""usage-guideline-check.py — the runner of the CBPR+ and HVPS+ rule sets (`motoko/iso/RuleSets.mo`, row M5).

Prints the implemented-rule count per set and per family as the canister carries it (before), evaluates every
fixture of `integration-kit/xml/guidelines-manifest.json` in the Motoko interpreter from the same source the
canister is built from — the official schema first (AppHdr and Document), then the rule set — and checks that
each conforming message passes and each violation is refused with exactly its rule id; prints the counts again
(after), so the number is measured, not claimed. Writes the rule tables to
`integration-kit/profiles/CBPRPLUS-RULES.json` and `HVPSPLUS-RULES.json` (or checks them with --check-rules)
and the report to `integration-kit/profile-runner/usage-guideline-report.json`.

The MyStandards limitation, stated once more here because it belongs on every report: the rule sets are the
hub's reading of the public descriptions of CBPR+ and HVPS+; the usage guidelines on MyStandards, with their
rule identifiers, are access-controlled and were not fetched; no identifier-by-identifier reconciliation exists.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

MOC = os.environ.get("MOC", os.path.expanduser("~/.cache/mops/moc/1.4.1/moc"))

DRIVER = r'''
import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Xml "../../../motoko/iso/Xml";
import IsoSchema "../../../motoko/iso/IsoSchema";
import RS "../../../motoko/iso/RuleSets";

func esc(t : Text) : Text { Text.replace(Text.replace(t, #text "\\", "\\\\"), #text "\"", "\\\"") };
func short(f : Text) : Text { let p = Text.split(f, #char '.'); let a = p.next(); let b = p.next(); switch (a, b) { case (?x, ?y) x # "." # y; case (_) f } };
func printSets() {
  for (rs in RS.all().vals()) {
    var imp = "";
    for ((f, n) in RS.implemented(rs).vals()) imp #= (if (imp == "") "" else ",") # "\"" # f # "\":" # Nat.toText(n);
    var rules = "";
    for (r in rs.rules.vals()) {
      var fams = "";
      for (f in r.families.vals()) fams #= (if (fams == "") "" else ",") # "\"" # f # "\"";
      rules #= (if (rules == "") "" else ",") # "{\"id\":\"" # r.id # "\",\"families\":[" # fams # "],\"check\":\"" # esc(RS.checkText(r.check)) # "\",\"basis\":\"" # esc(r.basis) # "\"}";
    };
    var basis = "";
    for (b in rs.basis.vals()) basis #= (if (basis == "") "" else ",") # "\"" # esc(b) # "\"";
    Debug.print("RULESET {\"id\":\"" # rs.id # "\",\"name\":\"" # esc(rs.name) # "\",\"authority\":\"" # esc(rs.authority) # "\",\"basis\":[" # basis # "],\"reconciliation\":\"" # esc(rs.reconciliation) # "\",\"ruleCount\":" # Nat.toText(rs.rules.size()) # ",\"implemented\":{" # imp # "},\"rules\":[" # rules # "]}");
  };
};
func judge(name : Text, setId : Text, xml : Text) {
  let ?rs = RS.byId(setId) else { Debug.print("VERDICT " # name # " no-such-set"); return };
  switch (Xml.parseMessage(Text.encodeUtf8(xml))) {
    case (#err(e)) Debug.print("VERDICT " # name # " schema " # e.rule);
    case (#ok(roots)) {
      let hasHeader = roots.size() == 2;
      let doc = roots[roots.size() - 1];
      var schema : [IsoSchema.Issue] = [];
      if (hasHeader) { switch (IsoSchema.schemaFor(roots[0].namespace)) { case (?hs) schema := IsoSchema.validate(hs, roots[0]); case null schema := [{ rule = "ISO-XSD-ROOT"; path = "/AppHdr"; detail = "" }] } };
      switch (IsoSchema.schemaFor(doc.namespace)) {
        case null Debug.print("VERDICT " # name # " schema ISO-XSD-ROOT");
        case (?sc) {
          if (schema.size() == 0) schema := IsoSchema.validate(sc, doc);
          if (schema.size() > 0) { Debug.print("VERDICT " # name # " schema " # schema[0].rule # " " # schema[0].path); return };
          let msgRoot = if (doc.children.size() == 1) doc.children[0] else doc;
          let issues = RS.evaluate(rs, short(sc.family), msgRoot, hasHeader);
          var ids = "";
          for (i in issues.vals()) ids #= (if (ids == "") "" else ",") # i.rule;
          Debug.print("VERDICT " # name # " " # (if (issues.size() == 0) "conforms -" else "violates " # ids));
        };
      };
    };
  };
};
printSets();
'''


def moc_text(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="integration-kit/xml/guidelines-manifest.json")
    ap.add_argument("--report", default="integration-kit/profile-runner/usage-guideline-report.json")
    ap.add_argument("--profiles-dir", default="integration-kit/profiles")
    ap.add_argument("--check-rules", action="store_true", help="the rule-table files must equal the canister's sets (instead of being written)")
    a = ap.parse_args()
    m = json.load(open(a.manifest))
    fixtures = [(f, "conforming") for f in m["conforming"]] + [(f, "violating") for f in m["violating"]]
    driver = DRIVER + "".join(f"judge({moc_text(f['id'])}, {moc_text(f['ruleSet'])}, {moc_text(open(f['path']).read())});\n" for f, _ in fixtures)
    work = tempfile.mkdtemp(prefix="ug-", dir="integration-kit/profile-runner")
    try:
        dp = os.path.join(work, "Driver.mo")
        open(dp, "w").write(driver)
        sources = subprocess.run(["mops", "sources"], cwd="motoko", capture_output=True, text=True, check=True).stdout.split()
        sources = [s if not s.startswith(".") and not s.startswith("thebes-lib") else os.path.abspath(os.path.join("motoko", s)) for s in sources]
        r = subprocess.run([MOC, "-r", *sources, dp], capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr[:3000], file=sys.stderr)
            return 2
        sets, verdicts = {}, {}
        for l in (r.stdout + r.stderr).splitlines():
            if l.startswith("RULESET "):
                rs = json.loads(l[len("RULESET "):]); sets[rs["id"]] = rs
            elif l.startswith("VERDICT "):
                p = l.split(" ", 3); verdicts[p[1]] = (p[2], p[3] if len(p) > 3 else "")
        print("implemented rules, before:")
        for rs in sets.values():
            print(f"  {rs['id']}: {rs['ruleCount']} rules — " + ", ".join(f"{f} {n}" for f, n in rs["implemented"].items()))
            print(f"    reconciliation: {rs['reconciliation']}")
        rows, ok_all = [], True
        counts = {"conforming": 0, "conformingOk": 0, "violating": 0, "violatingOk": 0, "rulesExercised": set()}
        for f, kind in fixtures:
            v, detail = verdicts.get(f["id"], ("missing", ""))
            row = {"id": f["id"], "ruleSet": f["ruleSet"], "messageKind": f["messageKind"], "verdict": v, "detail": detail, "xmllint": f["xmllint"]}
            if kind == "conforming":
                counts["conforming"] += 1
                row["ok"] = v == "conforms"
                counts["conformingOk"] += int(row["ok"])
            else:
                counts["violating"] += 1
                # exactly the expected rules, and nothing else, is what the violation proves
                row["expectedRules"] = f["rules"]
                row["ok"] = v == "violates" and sorted(detail.split(",")) == sorted(f["rules"])
                counts["violatingOk"] += int(row["ok"])
                if row["ok"]:
                    counts["rulesExercised"].update(f["rules"])
            ok_all = ok_all and row["ok"]
            rows.append(row)
        # every rule of every set has a violation fixture, or the count is not measured
        all_rule_ids = {r_["id"] for rs in sets.values() for r_ in rs["rules"]}
        unexercised = sorted(all_rule_ids - counts["rulesExercised"])
        counts["rulesExercised"] = sorted(counts["rulesExercised"])
        counts["rulesWithoutViolationFixture"] = unexercised
        if unexercised:
            ok_all = False
        # the tables
        for rs in sets.values():
            path = os.path.join(a.profiles_dir, f"{rs['id']}-RULES.json")
            if a.check_rules:
                if json.load(open(path)) != rs:
                    print(f"RULES DRIFT: {path} differs from RuleSets.{rs['id']}", file=sys.stderr); ok_all = False
            else:
                json.dump(rs, open(path, "w"), indent=2)
        print("implemented rules, after (every rule exercised by a violation fixture, every conforming fixture passing):")
        for rs in sets.values():
            ex = sum(1 for r_ in rs["rules"] if r_["id"] in counts["rulesExercised"])
            print(f"  {rs['id']}: {rs['ruleCount']} rules, {ex} exercised")
        json.dump({"summary": counts, "sets": list(sets.values()), "fixtures": rows}, open(a.report, "w"), indent=2)
        for row in rows:
            if not row["ok"]:
                print("FAIL", json.dumps(row))
        print(json.dumps({k: v for k, v in counts.items() if k != "rulesExercised"}))
        return 0 if ok_all else 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
