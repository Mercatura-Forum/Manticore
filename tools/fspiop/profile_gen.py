#!/usr/bin/env python3
"""profile_gen.py — the FSPIOP v1.1 request profile, derived from the official OpenAPI snippets
(mojaloop/api-snippets, fspiop/v1_1/openapi3), written as Motoko data:

  src/bank/FspiopProfiles.mo   every path and operation of the specification (method, path template,
                               operationId, the request-body schema, the declared response statuses)
                               and every schema those bodies reach: objects with their required
                               properties, arrays with their bounds, strings with their pattern,
                               enumeration and length facets, the anyOf/allOf compositions
  src/bank/UnicodeClasses.mo   the Unicode general-category tables the specification's name patterns
                               use (\\p{L}, \\p{gc=Mark}, \\p{digit}, \\p{gc=Connector_Punctuation},
                               \\p{Join_Control}), from Python's unicodedata at the stated version
  tools/fspiop/snippets.json   the snippets' version, commit and the sha256 of every file read

The canister enforces this profile on every request body (FspiopSchema.mo) before its own business
rules, the way the core messaging set enforces the XSD-derived profile on every ISO 20022 message. The snippets use only
these constructs — anything else fails the generation loudly rather than being silently dropped:

  schema := object(properties, required) | array(items, minItems?, maxItems?) | string(pattern?,
            enum?, minLength?, maxLength?) | integer | number | boolean | $ref | anyOf[schema] |
            allOf[schema] | oneOf[schema]

Usage: profile_gen.py [--snippets $ORACLES/mojaloop/api-snippets] [--out-dir src/bank]
"""
import argparse
import hashlib
import json
import os
import subprocess
import unicodedata

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
KNOWN_SCHEMA_KEYS = {"title", "type", "description", "example", "pattern", "enum", "minLength", "maxLength", "properties",
                     "required", "items", "minItems", "maxItems", "$ref", "anyOf", "allOf", "oneOf", "nullable", "format", "minimum", "maximum"}
read_files = {}


def fail(msg):
    raise SystemExit(f"profile_gen: {msg}")


def load_yaml(path):
    data = open(path, "rb").read()
    read_files[os.path.relpath(path, ROOT)] = hashlib.sha256(data).hexdigest()
    return yaml.safe_load(data)


def ref_name(ref):
    base = os.path.basename(ref)
    if not base.endswith(".yaml"):
        fail(f"$ref {ref} is not a file reference")
    return base[:-5]


class Profile:
    def __init__(self, schemas_dir):
        self.schemas_dir = schemas_dir
        self.schemas = {}     # name -> normalised schema
        self.order = []

    def need(self, name):
        if name in self.schemas:
            return
        self.schemas[name] = None   # cycle guard
        raw = load_yaml(os.path.join(self.schemas_dir, name + ".yaml"))
        self.schemas[name] = self.norm(raw, name)
        self.order.append(name)

    def norm(self, s, where):
        unknown = set(s) - KNOWN_SCHEMA_KEYS
        if unknown:
            fail(f"{where}: schema keys not in the subset: {sorted(unknown)}")
        if "$ref" in s:
            n = ref_name(s["$ref"])
            self.need(n)
            return {"ref": n}
        for comp in ("anyOf", "allOf", "oneOf"):
            if comp in s:
                alts = [self.norm(a, f"{where}.{comp}") for a in s[comp]]
                out = {comp: alts}
                if "pattern" in s:
                    out["pattern"] = s["pattern"]
                return out
        t = s.get("type")
        if t == "object":
            props = [(k, self.norm(v, f"{where}.{k}")) for k, v in (s.get("properties") or {}).items()]
            req = list(s.get("required") or [])
            for r in req:
                if r not in dict(props):
                    fail(f"{where}: required {r} is not a property")
            return {"object": {"properties": props, "required": req}}
        if t == "array":
            if "items" not in s:
                fail(f"{where}: array without items")
            return {"array": {"items": self.norm(s["items"], f"{where}[]"), "minItems": s.get("minItems"), "maxItems": s.get("maxItems")}}
        if t == "string":
            return {"string": {"pattern": s.get("pattern"), "enum": s.get("enum"), "minLength": s.get("minLength"), "maxLength": s.get("maxLength")}}
        if t == "integer":
            return {"integer": {"minimum": s.get("minimum"), "maximum": s.get("maximum")}}
        if t == "number":
            return {"number": None}
        if t == "boolean":
            return {"boolean": None}
        if t is None and "properties" in s:
            return self.norm(dict(s, type="object"), where)
        fail(f"{where}: schema of type {t!r} is not in the subset: {s}")


def mo_text(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def mo_opt_nat(v):
    return "null" if v is None else f"?{v}"


def mo_opt_int(v):
    return "null" if v is None else f"?({v})"


def mo_schema(s):
    if "ref" in s:
        return f"#ref({mo_text(s['ref'])})"
    for comp in ("anyOf", "allOf", "oneOf"):
        if comp in s:
            alts = ", ".join(mo_schema(a) for a in s[comp])
            pat = "null" if s.get("pattern") is None else f"?{mo_text(s['pattern'])}"
            return f"#{comp}({{ alternatives = [{alts}]; pattern = {pat} }})"
    if "object" in s:
        o = s["object"]
        props = ", ".join(f"({mo_text(k)}, {mo_schema(v)})" for k, v in o["properties"])
        req = ", ".join(mo_text(r) for r in o["required"])
        return f"#object_({{ properties = [{props}]; required = [{req}] }})"
    if "array" in s:
        a = s["array"]
        return f"#array_({{ items = {mo_schema(a['items'])}; minItems = {mo_opt_nat(a['minItems'])}; maxItems = {mo_opt_nat(a['maxItems'])} }})"
    if "string" in s:
        st = s["string"]
        pat = "null" if st["pattern"] is None else f"?{mo_text(st['pattern'])}"
        en = "null" if st["enum"] is None else "?[" + ", ".join(mo_text(e) for e in st["enum"]) + "]"
        return f"#string({{ pattern = {pat}; enum_ = {en}; minLength = {mo_opt_nat(st['minLength'])}; maxLength = {mo_opt_nat(st['maxLength'])} }})"
    if "integer" in s:
        return f"#integer({{ minimum = {mo_opt_int(s['integer']['minimum'])}; maximum = {mo_opt_int(s['integer']['maximum'])} }})"
    if "number" in s:
        return "#number"
    if "boolean" in s:
        return "#boolean"
    fail(f"cannot emit {s}")


def ranges(pred):
    out, start = [], None
    for cp in range(0x110000):
        ok = False if 0xD800 <= cp <= 0xDFFF else pred(chr(cp))
        if ok and start is None:
            start = cp
        if not ok and start is not None:
            out.append((start, cp - 1))
            start = None
    if start is not None:
        out.append((start, 0x10FFFF))
    return out


def emit_unicode(path):
    tables = [
        ("LETTER", "\\p{L}: general categories Lu Ll Lt Lm Lo", lambda c: unicodedata.category(c)[0] == "L"),
        ("MARK", "\\p{gc=Mark}: general categories Mn Mc Me", lambda c: unicodedata.category(c)[0] == "M"),
        ("DECIMAL_DIGIT", "\\p{digit}: general category Nd", lambda c: unicodedata.category(c) == "Nd"),
        ("CONNECTOR_PUNCTUATION", "\\p{gc=Connector_Punctuation}: general category Pc", lambda c: unicodedata.category(c) == "Pc"),
    ]
    lines = [
        "// UnicodeClasses.mo — GENERATED by tools/fspiop/profile_gen.py from Python's unicodedata",
        f"// (Unicode {unicodedata.unidata_version}). Do not edit: regenerate.",
        "//",
        "// The code-point ranges of the Unicode properties the FSPIOP specification's name patterns use",
        "// (FirstName, MiddleName, LastName: `[\\p{L}\\p{gc=Mark}\\p{digit}\\p{gc=Connector_Punctuation}\\p{Join_Control} .,'-]`),",
        "// as (low, high) inclusive pairs, for Rx.mo.",
        "",
        "module {",
        f"  public let UNICODE_VERSION = \"{unicodedata.unidata_version}\";",
    ]
    for name, doc, pred in tables:
        rs = ranges(pred)
        lines.append(f"  /// {doc} — {len(rs)} ranges")
        body = ", ".join(f"(0x{lo:X}, 0x{hi:X})" for lo, hi in rs)
        lines.append(f"  public let {name} : [(Nat32, Nat32)] = [{body}];")
    lines.append("  /// \\p{Join_Control}: ZERO WIDTH NON-JOINER and ZERO WIDTH JOINER")
    lines.append("  public let JOIN_CONTROL : [(Nat32, Nat32)] = [(0x200C, 0x200D)];")
    lines.append("}")
    open(path, "w").write("\n".join(lines) + "\n")
    return {n: len(ranges(p)) for n, _, p in tables}


def main():
    global ROOT
    ap = argparse.ArgumentParser()
    ap.add_argument("--snippets", default=os.environ.get("ORACLES", "oracles") + "/mojaloop/api-snippets")
    ap.add_argument("--out-dir", default=os.path.join(HERE, "..", "..", "src", "bank"))
    a = ap.parse_args()
    ROOT = os.path.join(a.snippets, "fspiop", "v1_1", "openapi3")
    root = load_yaml(os.path.join(ROOT, "openapi.yaml"))
    assert root["info"]["version"] == "1.1", root["info"]
    prof = Profile(os.path.join(ROOT, "components", "schemas"))
    operations = []
    for path, item in root["paths"].items():
        if path == "/interface":
            continue   # the bundle's type-inclusion trick, not an operation of the API
        if "$ref" in item:
            item = load_yaml(os.path.join(ROOT, item["$ref"]))
        for method in ("get", "post", "put", "patch", "delete"):
            if method not in item:
                continue
            op = item[method]
            req = None
            if "requestBody" in op:
                sch = op["requestBody"]["content"]["application/json"]["schema"]
                if "$ref" not in sch:
                    fail(f"{method} {path}: request body schema is inline")
                req = ref_name(sch["$ref"])
                prof.need(req)
            statuses = sorted(int(k) for k in op["responses"])
            operations.append({"method": method.upper(), "path": path, "operationId": op["operationId"], "request": req, "responses": statuses})
    # the operations the specification defines and the components they reach
    version = json.load(open(os.path.join(a.snippets, "package.json")))["version"]
    commit = subprocess.run(["git", "-C", a.snippets, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    unicode_counts = emit_unicode(os.path.join(a.out_dir, "UnicodeClasses.mo"))
    lines = [
        "// FspiopProfiles.mo — GENERATED by tools/fspiop/profile_gen.py from the official OpenAPI snippets",
        f"// (mojaloop/api-snippets {version}, commit {commit[:12]}, fspiop/v1_1/openapi3). Do not edit: regenerate.",
        "//",
        f"// {len(operations)} operations on {len(set(o['path'] for o in operations))} paths; {len(prof.order)} schemas reached from their",
        "// request bodies. FspiopSchema.mo validates a body against `schema(name)`; FspiopCore.mo routes a request",
        "// by `OPERATIONS`.",
        "",
        "module {",
        "  public type Schema = {",
        "    #object_ : { properties : [(Text, Schema)]; required : [Text] };",
        "    #array_ : { items : Schema; minItems : ?Nat; maxItems : ?Nat };",
        "    #string : { pattern : ?Text; enum_ : ?[Text]; minLength : ?Nat; maxLength : ?Nat };",
        "    #integer : { minimum : ?Int; maximum : ?Int };",
        "    #number;",
        "    #boolean;",
        "    #ref : Text;",
        "    #anyOf : { alternatives : [Schema]; pattern : ?Text };",
        "    #allOf : { alternatives : [Schema]; pattern : ?Text };",
        "    #oneOf : { alternatives : [Schema]; pattern : ?Text };",
        "  };",
        "  public type Operation = { method : Text; path : Text; operationId : Text; request : ?Text; responses : [Nat] };",
        "",
        f"  public let SOURCE = {{ package = \"mojaloop/api-snippets\"; version = \"{version}\"; commit = \"{commit}\"; api = \"fspiop/v1_1/openapi3\" }};",
        "",
        "  public let OPERATIONS : [Operation] = [",
    ]
    for o in operations:
        req = "null" if o["request"] is None else f"?{mo_text(o['request'])}"
        lines.append(f"    {{ method = {mo_text(o['method'])}; path = {mo_text(o['path'])}; operationId = {mo_text(o['operationId'])}; request = {req}; responses = [{', '.join(str(s) for s in o['responses'])}] }},")
    lines.append("  ];")
    lines.append("")
    lines.append("  public let SCHEMAS : [(Text, Schema)] = [")
    for name in sorted(prof.order):
        lines.append(f"    ({mo_text(name)}, {mo_schema(prof.schemas[name])}),")
    lines.append("  ];")
    lines.append("")
    lines.append("  public func schema(name : Text) : ?Schema { for ((n, s) in SCHEMAS.vals()) { if (n == name) return ?s }; null };")
    lines.append("}")
    open(os.path.join(a.out_dir, "FspiopProfiles.mo"), "w").write("\n".join(lines) + "\n")
    json.dump({"package": "mojaloop/api-snippets", "version": version, "commit": commit, "api": "fspiop/v1_1/openapi3",
               "unicode": unicodedata.unidata_version, "unicodeRanges": unicode_counts,
               "operations": len(operations), "schemas": len(prof.order), "files": dict(sorted(read_files.items()))},
              open(os.path.join(HERE, "snippets.json"), "w"), indent=2)
    print(f"{len(operations)} operations, {len(prof.order)} schemas, {len(read_files)} files hashed; Unicode {unicodedata.unidata_version}")
    for name in sorted(prof.order):
        s = prof.schemas[name]
        pats = []
        def walk(x):
            if isinstance(x, dict):
                if "pattern" in x and x["pattern"]:
                    pats.append(x["pattern"])
                if "string" in x and x["string"].get("pattern"):
                    pats.append(x["string"]["pattern"])
                for v in x.values():
                    walk(v)
            elif isinstance(x, list):
                for v in x:
                    walk(v)
        walk(s)
        for p in pats:
            print(f"  pattern {name}: {p}")


if __name__ == "__main__":
    main()
