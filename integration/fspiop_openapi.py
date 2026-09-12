"""fspiop_openapi.py — the FSPIOP v1.1 OpenAPI snippets (mojaloop/api-snippets, fspiop/v1_1/openapi3) as an
independent validator for the FSPIOP interoperability battery: the operations with their request schemas and declared
statuses, every component schema resolved, and `jsonschema` judging request and callback bodies.

Nothing here shares code with the canister: tools/fspiop/profile_gen.py reads the same files to generate
the canister's profile, and this module reads them again for the oracle's verdicts.
"""
import os

import jsonschema
import regex
import yaml

# the snippets' patterns are ECMAScript (Unicode property escapes in the name patterns): `regex` reads
# them; Python's `re` does not, so the pattern keyword is re-bound
def _pattern(validator, patrn, instance, schema):
    if validator.is_type(instance, "string") and not regex.search(patrn, instance):
        yield jsonschema.ValidationError(f"{instance!r} does not match {patrn!r}")


Validator = jsonschema.validators.extend(jsonschema.Draft7Validator, {"pattern": _pattern})

ROOT = os.environ.get("FSPIOP_SNIPPETS", os.environ.get("ORACLES", "oracles") + "/mojaloop/api-snippets/fspiop/v1_1/openapi3")


class Api:
    def __init__(self, root=ROOT):
        self.root = root
        self.defs = {}
        self.operations = []      # dicts: method, path, operationId, request (schema name or None), statuses
        spec = yaml.safe_load(open(os.path.join(root, "openapi.yaml"), "rb"))
        assert spec["info"]["version"] == "1.1", spec["info"]
        for path, item in spec["paths"].items():
            if path == "/interface":
                continue
            if "$ref" in item:
                item = yaml.safe_load(open(os.path.join(root, item["$ref"]), "rb"))
            for method in ("get", "post", "put", "patch", "delete"):
                if method in item:
                    op = item[method]
                    req = None
                    if "requestBody" in op:
                        req = self._name(op["requestBody"]["content"]["application/json"]["schema"]["$ref"])
                        self._load(req)
                    self.operations.append({"method": method.upper(), "path": path, "operationId": op["operationId"],
                                            "request": req, "statuses": sorted(int(k) for k in op["responses"])})
        for extra in ("ErrorInformationObject", "ErrorInformationResponse", "TransfersIDPutResponse", "ParticipantsTypeIDPutResponse", "PartiesTypeIDPutResponse", "QuotesIDPutResponse"):
            self._load(extra)

    @staticmethod
    def _name(ref):
        return os.path.basename(ref)[:-5]

    def _load(self, name):
        if name in self.defs:
            return
        self.defs[name] = None
        raw = yaml.safe_load(open(os.path.join(self.root, "components", "schemas", name + ".yaml"), "rb"))
        self.defs[name] = self._rewrite(raw)

    def _rewrite(self, node):
        """`$ref: ./X.yaml` → `#/$defs/X`, loading X; OpenAPI-only keys dropped for the JSON-schema validator."""
        if isinstance(node, dict):
            out = {}
            for k, v in node.items():
                if k == "$ref":
                    n = self._name(v)
                    self._load(n)
                    out["$ref"] = f"#/$defs/{n}"
                elif k in ("example", "nullable", "description", "title"):
                    continue
                else:
                    out[k] = self._rewrite(v)
            return out
        if isinstance(node, list):
            return [self._rewrite(v) for v in node]
        return node

    def schema(self, name):
        self._load(name)
        return {"$ref": f"#/$defs/{name}", "$defs": self.defs}

    def issues(self, name, value):
        """The validator's messages for `value` against the named schema; [] when it conforms."""
        v = Validator(self.schema(name), format_checker=None)
        return [f"{'/'.join(str(p) for p in e.absolute_path) or '$'}: {e.message}" for e in sorted(v.iter_errors(value), key=lambda e: list(e.absolute_path))]

    def operation(self, method, path):
        segs = [s for s in path.split("/") if s]
        for op in self.operations:
            if op["method"] != method:
                continue
            tsegs = [s for s in op["path"].split("/") if s]
            if len(tsegs) == len(segs) and all(t.startswith("{") or t == s for t, s in zip(tsegs, segs)):
                return op
        return None

    def callback_schema(self, method, path):
        """The schema a callback body must satisfy: the request-body schema of the operation the callback is."""
        op = self.operation(method, path)
        return op["request"] if op else None
