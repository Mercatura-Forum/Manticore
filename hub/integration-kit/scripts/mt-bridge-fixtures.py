#!/usr/bin/env python3
"""mt-bridge-fixtures.py — the FIN fixture set of the MT bridge (`motoko/iso/MtBridge.mo`): one or more messages
of each of the twelve types (and MT103 in the same envelope), written deterministically to
`integration-kit/legacy/mt/`, with `integration-kit/legacy/mt-manifest.json` naming each fixture's type, the ISO
family it reads into, and the field values the bridge runner checks against Prowide's reading.

The mapping tables (`integration-kit/legacy/mt-mappings.json`) are not written here: they are printed by the
canister's own table (`MtBridge.mappings()`) through the bridge runner, so the fixture set and the code cannot drift.
"""
import argparse
import hashlib
import json
import os
import random
import sys

NBE = "NBEGEGCX"          # National Bank of Egypt
CIB = "CIBEEGCX"          # Commercial International Bank
DEUT = "DEUTDEFF"         # a correspondent
CHAS = "CHASUS33"         # an intermediary
IBAN_EG = "EG380019000500000000263180002"
IBAN_EG2 = "EG800002000156789012345180002"
IBAN_DE = "DE89370400440532013000"


def uetr(rng):
    h = "%032x" % rng.getrandbits(128)
    return f"{h[:8]}-{h[8:12]}-4{h[13:16]}-{'89ab'[rng.randrange(4)]}{h[17:20]}-{h[20:32]}"


def amt(rng, lo=100, hi=250000):
    return f"{rng.randrange(lo, hi)},{rng.randrange(100):02d}"


def fin(mt, sender, receiver, body, uetr_=None, cov=False):
    lt = lambda b: b[:8] + "A" + (b[8:11] if len(b) == 11 else "XXX")
    b3 = ""
    if cov or uetr_:
        b3 = "{3:" + ("{119:COV}" if cov else "") + ("{121:%s}" % uetr_ if uetr_ else "") + "}"
    return "{1:F01" + lt(sender) + "0000000000}{2:I" + mt + lt(receiver) + "N}" + b3 + "{4:\n" + body + "-}"


def mt101(rng):
    ref = f"MT101{rng.randrange(10**8):08d}"
    body = f":20:{ref}\n:28D:1/1\n:30:260915\n"
    first = None
    for i in range(1, 3):
        tx = f"TX{i}-{rng.randrange(10**6):06d}"
        first = first or tx
        body += f":21:{tx}\n:32B:EGP{amt(rng)}\n:50K:/{IBAN_EG}\nCairo Water Utility\n12 Corniche El Nil\nCairo EG\n:52A:{NBE}\n:57A:{CIB}\n:59:/{IBAN_EG2}\nHousehold {i}\n:70:water bill 2026-08 part {i}\n:71A:SHA\n"
    # the compact pain.001 carries one transaction: the bridge writes the first transaction's reference as 20
    return fin("101", NBE, CIB, body), {"20": ref}, {"20": first}


def mt103(rng):
    ref = f"MT103{rng.randrange(10**8):08d}"
    u = uetr(rng)
    body = f":20:{ref}\n:23B:CRED\n:32A:260912EGP{amt(rng)}\n:50K:/{IBAN_EG}\nExample Debtor SAE\n1 Nile Corniche\nCairo EG\n:52A:{NBE}\n:57A:{CIB}\n:59:/EG800002000156789012345180002\nExample Creditor LLC\n10 Port Road\nAlexandria EG\n:70:Invoice INV-2026-001\n:71A:SHA\n"
    return fin("103", NBE, CIB, body, u), {"20": ref, "121": u}


def mt104(rng):
    ref = f"MT104{rng.randrange(10**8):08d}"
    body = f":20:{ref}\n:30:260920\n:50K:/ACC{rng.randrange(10**8):08d}\nCairo Water Utility\n:52A:{NBE}\n"
    for i in range(1, 3):
        body += f":21:COLL{i}-{rng.randrange(10**6):06d}\n:21C:MANDATE-{rng.randrange(10**6):06d}\n:23E:OTHR\n:32B:EGP{amt(rng, 10, 900)}\n:57A:{CIB}\n:59:/{IBAN_EG}\nHousehold {i}\n:70:water bill 2026-08\n"
    return fin("104", NBE, CIB, body), {"20": ref}


def mt202(rng):
    ref = f"MT202{rng.randrange(10**8):08d}"
    u = uetr(rng)
    body = f":20:{ref}\n:21:REL{rng.randrange(10**8):08d}\n:32A:260912USD{amt(rng, 10000, 5000000)}\n:52A:{NBE}\n:56A:{CHAS}\n:57A:{DEUT}\n:58A:{CIB}\n:72:/INS/{NBE}\n"
    return fin("202", NBE, DEUT, body, u), {"20": ref, "121": u}


def mt202cov(rng):
    ref = f"MT202C{rng.randrange(10**7):07d}"
    related = f"MT103{rng.randrange(10**8):08d}"
    u = uetr(rng)
    body = (f":20:{ref}\n:21:{related}\n:32A:260912USD{amt(rng, 1000, 90000)}\n:52A:{NBE}\n:57A:{DEUT}\n:58A:{CIB}\n"
            f":50K:/{IBAN_EG}\nExample Debtor SAE\n1 Nile Corniche\nCairo EG\n:52A:{NBE}\n:57A:{CIB}\n:59:/{IBAN_DE}\nExample Creditor GmbH\n10 Market Platz\nBerlin DE\n:70:Cross-border invoice 2026-001\n:33B:USD{amt(rng, 1000, 90000)}\n")
    return fin("202", NBE, DEUT, body, u, cov=True), {"20": ref, "21": related, "121": u}


def mt900(rng):
    ref = f"MT900{rng.randrange(10**8):08d}"
    u = uetr(rng)
    body = f":20:{ref}\n:21:REL{rng.randrange(10**8):08d}\n:25:{IBAN_EG}\n:32A:260912EGP{amt(rng)}\n:52A:{CIB}\n:72:/UETR/{u}\n/BNF/settlement of ACH cycle 1\n"
    return fin("900", NBE, CIB, body), {"20": ref}


def mt910(rng):
    ref = f"MT910{rng.randrange(10**8):08d}"
    body = f":20:{ref}\n:21:REL{rng.randrange(10**8):08d}\n:25:{IBAN_EG}\n:32A:260912EGP{amt(rng)}\n:50K:Salary Payroll Ltd\n:72:/BNF/payroll September\n"
    return fin("910", NBE, CIB, body), {"20": ref}


def statement(rng, mt, with86):
    ref = f"MT{mt}{rng.randrange(10**8):08d}"
    body = f":20:{ref}\n:25:{IBAN_EG}\n:28C:1/1\n:60F:C260911EGP{amt(rng, 1000, 90000)}\n"
    first = None
    for i in range(1, 4):
        side = "C" if i % 2 else "D"
        line_ref = f"REF{i}-{rng.randrange(10**6):06d}"
        first = first or line_ref
        body += f":61:260912{side}{amt(rng, 10, 9000)}NTRFNONREF//{line_ref}\n"
        if with86:
            body += f":86:/UETR/{uetr(rng)}\n/NAME/Counterparty {i}\nremittance line {i}\n"
    body += f":62F:C260912EGP{amt(rng, 1000, 90000)}\n"
    # the compact camt.053 record carries no statement id: the bridge writes the first line's reference as 20
    return fin(mt, NBE, CIB, body), {"20": ref}, {"20": first}


def mt942(rng):
    ref = f"MT942{rng.randrange(10**8):08d}"
    body = f":20:{ref}\n:25:{IBAN_EG}\n:28C:1/1\n:34F:EGP0,00\n:13D:2609121030+0200\n"
    for i in range(1, 3):
        side = "C" if i % 2 else "D"
        body += f":61:260912{side}{amt(rng, 10, 9000)}NTRFNONREF//INT{i}-{rng.randrange(10**6):06d}\n:86:/UETR/{uetr(rng)}\n/NAME/Intraday counterparty {i}\nintraday line {i}\n"
    body += ":90D:1EGP100,00\n:90C:1EGP200,00\n"
    return fin("942", NBE, CIB, body), {"20": ref}


def mt192(rng):
    ref = f"MT192{rng.randrange(10**8):08d}"
    related = f"MT103{rng.randrange(10**8):08d}"
    body = f":20:{ref}\n:21:{related}\n:11S:103\n260912\n:79:/CUST/customer asked to cancel before settlement\n/ACTION/CANCEL\n/UETR/{uetr(rng)}\nplease return funds to the ordering customer\n"
    return fin("192", NBE, CIB, body), {"20": ref, "21": related}


def mt196(rng):
    ref = f"MT196{rng.randrange(10**8):08d}"
    related = f"MT192{rng.randrange(10**8):08d}"
    body = f":20:{ref}\n:21:{related}\n:76:/CNCL/cancellation accepted\n/ACTION/CANCELLED\nfunds returned under our reference {ref}\n:11R:192\n260912\n"
    return fin("196", CIB, NBE, body), {"20": ref, "21": related}


def mt199(rng):
    ref = f"MT199{rng.randrange(10**8):08d}"
    related = f"MT103{rng.randrange(10**8):08d}"
    body = f":20:{ref}\n:21:{related}\n:79:/INFO/beneficiary claims non-receipt\n/ACTION/INVESTIGATE\nplease confirm the value date applied\n"
    return fin("199", CIB, NBE, body), {"20": ref, "21": related}


GEN = [("MT101", "pain.001", mt101), ("MT103", "pain.001", mt103), ("MT104", "pain.008", mt104), ("MT202", "pacs.009", mt202), ("MT202COV", "pacs.009 COV + pacs.008", mt202cov),
       ("MT900", "camt.054", mt900), ("MT910", "camt.054", mt910), ("MT940", "camt.053", lambda r: statement(r, "940", True)), ("MT950", "camt.053", lambda r: statement(r, "950", False)),
       ("MT942", "camt.052", mt942), ("MT192", "camt.056", mt192), ("MT196", "camt.029", mt196), ("MT199", "camt.110", mt199)]


def moc_text(t):
    return '"' + t.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


TEST_HEAD = r'''// MtBridge.test.mo; GENERATED by integration-kit/scripts/mt-bridge-fixtures.py from the FIN fixture set
// (integration-kit/legacy/mt-manifest.json). Do not edit: regenerate. Every fixture is read into its record,
// written back, and read again equal; the Prowide swift-core cross-parse and the XML round trips are the
// runner's (integration-kit/scripts/mt-bridge-roundtrip.py).
import Text "mo:core/Text";
import ISO "../ISO20022";
import MT "../iso/MtBridge";

func minorUnitsOf(c : Text) : ?Nat8 { switch (c) { case ("EGP" or "USD" or "EUR" or "GBP") ?2; case (_) null } };
let g = ISO.crossBorderEducationGuideline();
func versions(kind : Text) : Text { for (v in g.messageVersions.vals()) { if (v.kind == kind) return v.version }; "001.01" };
let options : MT.Options = { creationDateTime = "2026-09-12T10:00:00Z"; settlementMethod = g.settlementMethod; country = "EG"; versions };
let parties : MT.Party = { sender = "NBEGEGCX"; receiver = "CIBEEGCX" };

func roundTrip(mt : Text, iso : Text, fin : Text) {
  let d = MT.decode(Text.encodeUtf8(fin), null, options, minorUnitsOf);
  assert (d.mtType == mt);
  assert (d.iso == iso);
  switch (d.message) {
    case (#err(_)) { assert false };
    case (#ok(m)) {
      switch (MT.encode(m, mt, parties, minorUnitsOf)) {
        case (#err(_)) { assert false };
        case (#ok(written)) {
          let again = MT.decode(Text.encodeUtf8(written), null, options, minorUnitsOf);
          assert (again.mtType == mt);
          switch (again.message) { case (#ok(m2)) { assert (MT.equalMessage(m, m2)) }; case (#err(_)) { assert false } };
        };
      };
    };
  };
};

// the mapping tables name every one of the bridge's types
assert (MT.mappings().size() == 13);
for (m in MT.mappings().vals()) { assert (m.fields.size() > 3) };
// block-4-only text needs the caller's hint; the wrong hint is a typed refusal
let bare = Text.encodeUtf8("{4:\n:20:REF\n-}");
switch (MT.decode(bare, null, options, minorUnitsOf).message) { case (#err(is)) { assert (is[0].ruleId == "MT-TYPE") }; case (#ok(_)) { assert false } };
switch (MT.decode(bare, ?"MT999", options, minorUnitsOf).message) { case (#err(is)) { assert (is[0].ruleId == "MT-UNSUPPORTED") }; case (#ok(_)) { assert false } };
'''


def write_test(path, manifest):
    out = [TEST_HEAD]
    for f in manifest["fixtures"]:
        out.append(f"// {f['id']}\nroundTrip({moc_text(f['mt'])}, {moc_text(f['iso'])}, {moc_text(open(f['path']).read())});")
    out.append(f"\n// {len(manifest['fixtures'])} FIN fixtures across 13 types read, written and read again.")
    open(path, "w").write("\n".join(out) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="integration-kit/legacy/mt")
    ap.add_argument("--seed", type=int, default=20260912)
    ap.add_argument("--test-out", default="motoko/test/MtBridge.test.mo")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    manifest = {"version": "thebes-mt-bridge-fixtures-v1", "seed": a.seed, "fixtures": []}
    for mt, iso, gen in GEN:
        for k in range(2):
            out = gen(rng)
            text, keys = out[0], out[1]
            written_keys = out[2] if len(out) > 2 else keys   # what the bridge's own FIN must carry (differs where a record has no place for a field)
            name = f"{mt.lower()}-{k + 1}.fin"
            path = os.path.join(a.out, name)
            open(path, "w").write(text)
            manifest["fixtures"].append({"id": name, "path": path, "mt": mt, "iso": iso, "keys": keys, "writtenKeys": written_keys, "sha256": hashlib.sha256(text.encode()).hexdigest()})
    json.dump(manifest, open("integration-kit/legacy/mt-manifest.json", "w"), indent=2)
    write_test(a.test_out, manifest)
    print(f"{len(manifest['fixtures'])} FIN fixtures across {len(GEN)} types")


if __name__ == "__main__":
    sys.exit(main())
