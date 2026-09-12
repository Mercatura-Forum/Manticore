#!/usr/bin/env python3
"""profile_gen.py — the element-and-cardinality profile of each ISO 20022 family, derived from the
official XSD, written as Motoko data (src/bank/IsoProfiles.mo) and as JSON (tools/iso20022/profiles/).

The canister cannot ship a general XSD processor; what it enforces is this profile: every complex
type's content model (sequence or choice of elements with their minOccurs/maxOccurs, or simple
content with its one attribute), every simple type's facets (length, pattern, enumeration, decimal
digits, minimum), and the base lexical type. The profile is the schema's own tree, not a hand-written
shape, and tools/iso20022/profile_check.py shows it agrees with `xmllint --schema` on generated
valid and invalid instances. The ISO schemas use only these constructs (checked here: anything else
fails the generation loudly rather than being silently dropped):

  complexType := sequence(element*, any?) | choice(element*) | simpleContent(extension(attribute))
  simpleType  := restriction(base, facet*)   facets: minLength maxLength pattern enumeration
                                                      fractionDigits totalDigits minInclusive
  bases: xs:string decimal boolean date dateTime time gYearMonth gYear base64Binary (the length facets of a
  base64Binary count its decoded octets, as XSD Part 2 §3.2.16 defines them)

Usage: profile_gen.py [--schemas tools/iso20022/schemas] [--out src/bank/IsoProfiles.mo]
"""
import argparse
import hashlib
import json
import os
import xml.etree.ElementTree as ET

XS = "{http://www.w3.org/2001/XMLSchema}"
FAMILIES = [
    # the core messaging set: the rail's credit transfers, statuses, returns, statements, the business application header
    ("pacs.008.001.08", "PACS_008"), ("pacs.009.001.08", "PACS_009"), ("pacs.002.001.10", "PACS_002"),
    ("pacs.004.001.09", "PACS_004"), ("camt.053.001.08", "CAMT_053"), ("camt.054.001.08", "CAMT_054"),
    ("head.001.001.02", "HEAD_001"),
    # the extended target list — reversals, FI direct debit, the
    # multilateral settlement request; the mandate cycle; cash management, liquidity and the
    # exceptions-and-investigations set; system administration; the business file header
    ("pacs.003.001.08", "PACS_003"), ("pacs.007.001.10", "PACS_007"), ("pacs.010.001.04", "PACS_010"), ("pacs.029.001.02", "PACS_029"),
    ("pain.007.001.10", "PAIN_007"), ("pain.009.001.07", "PAIN_009"), ("pain.010.001.07", "PAIN_010"),
    ("pain.011.001.07", "PAIN_011"), ("pain.012.001.07", "PAIN_012"),
    ("camt.052.001.08", "CAMT_052"), ("camt.057.001.06", "CAMT_057"), ("camt.060.001.05", "CAMT_060"),
    ("camt.050.001.05", "CAMT_050"), ("camt.025.001.05", "CAMT_025"), ("camt.026.001.07", "CAMT_026"),
    ("camt.027.001.07", "CAMT_027"), ("camt.028.001.09", "CAMT_028"), ("camt.087.001.06", "CAMT_087"),
    ("admi.006.001.01", "ADMI_006"), ("admi.007.001.01", "ADMI_007"), ("admi.017.001.01", "ADMI_017"),
    ("head.002.001.01", "HEAD_002"),
]
BASES = {"xs:string": "string", "xs:decimal": "decimal", "xs:boolean": "boolean", "xs:date": "date",
         "xs:dateTime": "dateTime", "xs:time": "time", "xs:gYearMonth": "yearMonth", "xs:gYear": "year", "xs:base64Binary": "base64Binary"}


def fail(msg):
    raise SystemExit(f"profile_gen: {msg}")


def load(path):
    root = ET.parse(path).getroot()
    ns = root.attrib["targetNamespace"]
    types = {}
    order = []
    root_elems = [e for e in root.findall(XS + "element")]
    # one root element: Document for a business message, AppHdr for head.001, Xchg for the head.002 file header
    if len(root_elems) != 1 or root_elems[0].attrib["name"] not in ("Document", "AppHdr", "Xchg"):
        fail(f"{path}: expected one root element Document/AppHdr/Xchg, got {[e.attrib.get('name') for e in root_elems]}")
    root_name, root_type = root_elems[0].attrib["name"], root_elems[0].attrib["type"]
    for node in root:
        tag = node.tag.replace(XS, "")
        if tag == "element":
            continue
        name = node.attrib["name"]
        if tag == "simpleType":
            kids = list(node)
            if len(kids) != 1 or kids[0].tag != XS + "restriction":
                fail(f"{path}: simpleType {name} is not one restriction")
            r = kids[0]
            base = r.attrib.get("base")
            if base not in BASES:
                fail(f"{path}: simpleType {name} has base {base}")
            t = {"kind": "simple", "base": BASES[base], "minLength": None, "maxLength": None, "pattern": None,
                 "enums": [], "fractionDigits": None, "totalDigits": None, "minInclusive": None}
            for f in r:
                ft = f.tag.replace(XS, "")
                v = f.attrib["value"]
                if ft == "minLength": t["minLength"] = int(v)
                elif ft == "maxLength": t["maxLength"] = int(v)
                elif ft == "pattern":
                    if t["pattern"] is not None: fail(f"{path}: two patterns on {name}")
                    t["pattern"] = v
                elif ft == "enumeration": t["enums"].append(v)
                elif ft == "fractionDigits": t["fractionDigits"] = int(v)
                elif ft == "totalDigits": t["totalDigits"] = int(v)
                elif ft == "minInclusive": t["minInclusive"] = v
                else: fail(f"{path}: facet {ft} on {name}")
            types[name] = t
        elif tag == "complexType":
            kids = list(node)
            if len(kids) != 1:
                fail(f"{path}: complexType {name} has {len(kids)} children")
            body = kids[0]
            bt = body.tag.replace(XS, "")
            if bt in ("sequence", "choice"):
                if body.attrib.get("minOccurs") or body.attrib.get("maxOccurs"):
                    fail(f"{path}: {name}: occurrence on the {bt} itself")
                parts = []
                for p in body:
                    pt = p.tag.replace(XS, "")
                    mn = int(p.attrib.get("minOccurs", "1"))
                    mx = p.attrib.get("maxOccurs", "1")
                    mx = None if mx == "unbounded" else int(mx)
                    if pt == "element":
                        if "type" not in p.attrib: fail(f"{path}: anonymous element in {name}")
                        parts.append({"name": p.attrib["name"], "type": p.attrib["type"], "min": mn, "max": mx})
                    elif pt == "any":
                        if bt != "sequence": fail(f"{path}: any outside a sequence in {name}")
                        parts.append({"name": "*", "type": None, "min": mn, "max": mx, "namespace": p.attrib.get("namespace", "##any")})
                    else:
                        fail(f"{path}: particle {pt} in {name}")
                types[name] = {"kind": "complex", "model": bt, "particles": parts}
            elif bt == "simpleContent":
                ext = list(body)
                if len(ext) != 1 or ext[0].tag != XS + "extension": fail(f"{path}: simpleContent of {name} is not one extension")
                attrs = list(ext[0])
                if len(attrs) != 1 or attrs[0].tag != XS + "attribute" or attrs[0].attrib.get("use") != "required":
                    fail(f"{path}: simpleContent of {name} has unexpected attributes")
                types[name] = {"kind": "complex", "model": "simpleContent", "simple": ext[0].attrib["base"],
                               "attribute": {"name": attrs[0].attrib["name"], "type": attrs[0].attrib["type"]}}
            else:
                fail(f"{path}: complexType {name} body {bt}")
        else:
            fail(f"{path}: top-level {tag}")
        order.append(name)
    # every referenced type exists
    for n, t in types.items():
        if t["kind"] == "complex":
            if t["model"] == "simpleContent":
                for ref in (t["simple"], t["attribute"]["type"]):
                    if ref not in types: fail(f"{path}: {n} references {ref}")
            else:
                for p in t["particles"]:
                    if p["type"] is not None and p["type"] not in types: fail(f"{path}: {n} references {p['type']}")
    if root_type not in types: fail(f"{path}: root type {root_type}")
    return {"namespace": ns, "rootName": root_name, "rootType": root_type, "order": order, "types": types}


def mo_text(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def mo_opt_nat(v):
    return "null" if v is None else f"?{v}"


def mo_opt_text(v):
    return "null" if v is None else f"?{mo_text(v)}"


RS, US, GS, FS = "\x1e", "\x1f", "\x1d", "\x1c"   # record, field, list-item, particle-field separators


def enc_text(t):
    """A Motoko text literal of the encoded profile: control separators as \\u{..} escapes."""
    out = t.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    for ch in (RS, US, GS, FS):
        out = out.replace(ch, "\\u{%02X}" % ord(ch))
    return '"' + out + '"'


def emit(schema, family, const, src_hash):
    """One schema as one function over one encoded text literal. A record per type, in declaration order:
    S <name> <base> <minLength> <maxLength> <pattern> <enums> <fractionDigits> <totalDigits> <minInclusive>
    C <name> <simple index> <attribute name> <attribute type index>
    Q|H <name> <particles>   (sequence | choice; a particle is name FS typ FS min FS max, particles GS-separated)
    Empty fields are null. The parser is `decode` in the module header. One literal per schema keeps the
    compiler's static-root initializer small: a program with tens of thousands of text literals exceeds the
    IC's per-function complexity limit in that one function."""
    idx = {name: i for i, name in enumerate(schema["order"])}
    def opt(v): return "" if v is None else str(v)
    recs = []
    for name in schema["order"]:
        t = schema["types"][name]
        for ch in (RS, US, GS, FS):
            assert ch not in json.dumps(t), f"{family}: {name} contains a separator byte"
        if t["kind"] == "simple":
            recs.append(US.join(["S", name, t["base"], opt(t["minLength"]), opt(t["maxLength"]), opt(t["pattern"]), GS.join(t["enums"]), opt(t["fractionDigits"]), opt(t["totalDigits"]), opt(t["minInclusive"])]))
        elif t["model"] == "simpleContent":
            recs.append(US.join(["C", name, str(idx[t["simple"]]), t["attribute"]["name"], str(idx[t["attribute"]["type"]])]))
        else:
            parts = GS.join(FS.join([pt["name"], str(idx[pt["type"]] if pt["type"] is not None else 0), str(pt["min"]), opt(pt["max"])]) for pt in t["particles"])
            recs.append(US.join(["Q" if t["model"] == "sequence" else "H", name, parts]))
    body = RS.join(recs)
    return (f"  /// {family} — generated from {family}.xsd (SHA-256 {src_hash}); {len(recs)} types.\n"
            f"  public func {const}() : Schema {{ decode({mo_text(family)}, {mo_text(schema['namespace'])}, {mo_text(schema['rootName'])}, {idx[schema['rootType']]}, {mo_text(src_hash)}, {enc_text(body)}) }};\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--schemas", default=os.path.join(os.path.dirname(__file__), "schemas"))
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "..", "src", "bank", "IsoProfiles.mo"))
    ap.add_argument("--json-dir", default=os.path.join(os.path.dirname(__file__), "profiles"))
    a = ap.parse_args()
    os.makedirs(a.json_dir, exist_ok=True)
    consts = []
    names = []
    namespaces = []
    total_types = 0
    for family, const in FAMILIES:
        path = os.path.join(a.schemas, family + ".xsd")
        src_hash = hashlib.sha256(open(path, "rb").read()).hexdigest()
        schema = load(path)
        total_types += len(schema["order"])
        json.dump({"family": family, "schemaSha256": src_hash, **schema}, open(os.path.join(a.json_dir, family + ".json"), "w"), indent=1)
        consts.append(emit(schema, family, const, src_hash))
        names.append(const)
        namespaces.append(schema['namespace'])
        print(f"{family}: {len(schema['order'])} types, root {schema['rootName']} : {schema['rootType']}")
    header = r'''/// IsoProfiles.mo — GENERATED by tools/iso20022/profile_gen.py from the official ISO 20022 schemas.
/// Do not edit: regenerate. Each schema is a function; `byNamespace` builds only the one asked for. Each schema's
/// types are listed in the order the XSD declares them, so a
/// particle's `typ` is an index into `types`; a sequence's `*` particle is the schema's `xs:any`.
/// The validator that enforces these profiles is IsoSchema.mo; tools/iso20022/profile_check.py shows the
/// enforcement agrees with `xmllint --schema`.
/// Each schema is one encoded text literal decoded on use (`decode`): a program carrying the tens of
/// thousands of literals the record form needs exceeds the IC's per-function complexity limit in the
/// compiler's static-root initializer; forty-three literals do not.

import Array "mo:core/Array";
import Char "mo:core/Char";
import Iter "mo:core/Iter";
import Nat32 "mo:core/Nat32";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

module {

  public type Base = { #string; #decimal; #boolean; #date; #dateTime; #time; #yearMonth; #year; #base64Binary };

  public type Simple = {
    name : Text; base : Base; minLength : ?Nat; maxLength : ?Nat; pattern : ?Text; enums : [Text];
    fractionDigits : ?Nat; totalDigits : ?Nat; minInclusive : ?Text;
  };

  /// One element of a content model: its local name, its type (an index into `types`), and how
  /// many times it may occur (`max = null` is unbounded). The name `*` is the schema's `xs:any`.
  public type Particle = { name : Text; typ : Nat; min : Nat; max : ?Nat };

  public type Type = {
    #simple : Simple;
    #sequence : { name : Text; particles : [Particle] };
    #choice : { name : Text; particles : [Particle] };
    /// Text of the `simple` type, with exactly one required attribute of `attributeType`.
    #simpleContent : { name : Text; simple : Nat; attribute : Text; attributeType : Nat };
  };

  public type Schema = { family : Text; namespace : Text; rootName : Text; root : Nat; schemaSha256 : Text; types : [Type] };

  // ─── the decoder of the encoded profiles (the format is documented in the generator's `emit`) ───

  func fields(rec : Text, sep : Char) : [Text] { Iter.toArray(Text.split(rec, #char sep)) };
  func nat(t : Text) : Nat { var n = 0; for (c in t.chars()) { n := n * 10 + Nat32.toNat(Char.toNat32(c) - 48) }; n };
  func optNat(t : Text) : ?Nat { if (t == "") null else ?nat(t) };
  func optText(t : Text) : ?Text { if (t == "") null else ?t };
  func base(t : Text) : Base {
    switch (t) {
      case ("string") #string; case ("decimal") #decimal; case ("boolean") #boolean; case ("date") #date; case ("dateTime") #dateTime;
      case ("time") #time; case ("yearMonth") #yearMonth; case ("year") #year; case ("base64Binary") #base64Binary;
      case (other) Runtime.trap("IsoProfiles: unknown base " # other);
    }
  };
  func particles(t : Text) : [Particle] {
    if (t == "") return [];
    Array.map<Text, Particle>(fields(t, '\u{1D}'), func(p) { let f = fields(p, '\u{1C}'); { name = f[0]; typ = nat(f[1]); min = nat(f[2]); max = optNat(f[3]) } })
  };
  func decode(family : Text, namespace : Text, rootName : Text, root : Nat, schemaSha256 : Text, encoded : Text) : Schema {
    let types = Array.map<Text, Type>(fields(encoded, '\u{1E}'), func(rec) {
      let f = fields(rec, '\u{1F}');
      switch (f[0]) {
        case ("S") #simple({ name = f[1]; base = base(f[2]); minLength = optNat(f[3]); maxLength = optNat(f[4]); pattern = optText(f[5]); enums = (if (f[6] == "") [] else fields(f[6], '\u{1D}')); fractionDigits = optNat(f[7]); totalDigits = optNat(f[8]); minInclusive = optText(f[9]) });
        case ("C") #simpleContent({ name = f[1]; simple = nat(f[2]); attribute = f[3]; attributeType = nat(f[4]) });
        case ("Q") #sequence({ name = f[1]; particles = particles(f[2]) });
        case ("H") #choice({ name = f[1]; particles = particles(f[2]) });
        case (other) Runtime.trap("IsoProfiles: unknown record " # other);
      }
    });
    { family; namespace; rootName; root; schemaSha256; types }
  };

'''
    # one function per schema: a single module-initialisation function holding every profile literal exceeds the
    # IC's per-function complexity limit (1,000,000) past ~30 families; `byNamespace` builds only the one asked for
    calls = ", ".join(f"{n}()" for n in names)
    cases = "".join(f"      case ({mo_text(ns)}) ?{n}();\n" for n, ns in zip(names, namespaces))
    footer = (f"  /// The profile of one family by its namespace — the one schema built, nothing else.\n"
              f"  public func byNamespace(namespace : Text) : ?Schema {{\n    switch (namespace) {{\n{cases}      case (_) null;\n    }}\n  }};\n"
              f"  /// Every profile, built on each call (the caller keeps it if it needs it more than once).\n"
              f"  public func all() : [Schema] {{ [{calls}] }};\n}}\n")
    open(a.out, "w").write(header + "\n".join(consts) + "\n" + footer)
    print(f"wrote {a.out}: {total_types} types over {len(FAMILIES)} families")


if __name__ == "__main__":
    main()
