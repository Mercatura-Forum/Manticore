#!/usr/bin/env python3
"""minimal_instance.py — a schema-valid instance of an ISO 20022 family generated from its profile (the official
XSD's own tree as tools/iso20022/profile_gen.py wrote it), not from a hand-written template.

Every required particle is emitted once; a choice takes its first branch; a simple value is the first enumeration,
else a string that satisfies the pattern, else the shortest value the length facets allow, else a decimal, date,
time or boolean of the base type. The point is not a meaningful message but a message the official schema accepts
from nothing but the schema; which `xmllint --schema` then confirms. Optional particles can be forced in by name
(`--with`) so a battery can exercise the elements it cares about, and the generated tree can be edited by a caller
before serialising (`instance()` returns nested dicts/lists).

Usage: minimal_instance.py cain.001.001.04 [--profiles tools/iso20022/profiles] [--with Tkn,Card] [--seed 7]
"""
import argparse
import json
import os
import random
import re

PROFILES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "profiles")


def load_profile(family, profiles=PROFILES):
    return json.load(open(os.path.join(profiles, family + ".json")))


class Gen:
    def __init__(self, profile, rng=None, force=()):
        self.p = profile
        self.types = profile["types"]
        self.rng = rng or random.Random(7)
        self.force = set(force)
        self.depth = 0

    # ── simple values ──
    def simple(self, t):
        if t["enums"]:
            return t["enums"][0]
        base = t["base"]
        if base == "boolean":
            return "false"
        if base == "date":
            return "2026-09-14"
        if base == "dateTime":
            return "2026-09-14T12:00:00Z"
        if base == "time":
            return "12:00:00"
        if base == "yearMonth":
            return "2026-09"
        if base == "year":
            return "2026"
        if base == "base64Binary":
            n = t.get("minLength") or 1
            return "QUFB" * ((n + 2) // 3)
        if base == "decimal":
            frac = t.get("fractionDigits")
            v = "1" if (t.get("minInclusive") is None or float(t["minInclusive"]) <= 1) else str(t["minInclusive"])
            if frac and frac > 0 and t.get("totalDigits") and t["totalDigits"] > frac:
                return v + "." + "0" * min(frac, 2)
            return v
        if t.get("pattern"):
            return self.from_pattern(t["pattern"])
        lo = t.get("minLength") or 1
        return "A" * max(lo, 1)

    def from_pattern(self, pattern):
        """A string matching the ISO schemas' regular expressions: sequences of literals and character classes
        with {m,n}/{m}/+/*/? quantifiers, groups, and top-level alternation (first branch taken)."""
        s = pattern
        if s.startswith("^"):
            s = s[1:]
        if s.endswith("$"):
            s = s[:-1]
        out, i = [], 0
        alt = self._split_top_alternation(s)
        s = alt[0]
        while i < len(s):
            c = s[i]
            if c == "(":
                j = self._match_paren(s, i)
                inner = s[i + 1:j]
                i = j + 1
                q, i = self._quant(s, i)
                piece = self.from_pattern(inner)
                out.append(piece * q)
                continue
            if c == "[":
                j = s.index("]", i + 1)
                while s[j - 1] == "\\":
                    j = s.index("]", j + 1)
                cls = s[i + 1:j]
                i = j + 1
                q, i = self._quant(s, i)
                ch = self._class_char(cls)
                out.append(ch * q)
                continue
            if c == "\\":
                esc = s[i + 1]
                i += 2
                q, i = self._quant(s, i)
                ch = {"d": "1", "s": " ", "w": "a", ".": ".", "-": "-", "+": "+", "(": "(", ")": ")", "/": "/", "\\": "\\"}.get(esc, esc)
                out.append(ch * q)
                continue
            if c == ".":
                i += 1
                q, i = self._quant(s, i)
                out.append("a" * q)
                continue
            i += 1
            q, i = self._quant(s, i)
            out.append(c * q)
        return "".join(out)

    def _split_top_alternation(self, s):
        parts, depth, cur, i = [], 0, "", 0
        while i < len(s):
            c = s[i]
            if c == "\\":
                cur += s[i:i + 2]; i += 2; continue
            if c == "[":
                j = s.index("]", i + 1)
                cur += s[i:j + 1]; i = j + 1; continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            if c == "|" and depth == 0:
                parts.append(cur); cur = ""
            else:
                cur += c
            i += 1
        parts.append(cur)
        return parts

    def _match_paren(self, s, i):
        depth, j = 0, i
        while j < len(s):
            if s[j] == "\\":
                j += 2; continue
            if s[j] == "[":
                j = s.index("]", j + 1) + 1; continue
            if s[j] == "(":
                depth += 1
            elif s[j] == ")":
                depth -= 1
                if depth == 0:
                    return j
            j += 1
        raise ValueError("unbalanced pattern " + s)

    def _quant(self, s, i):
        if i < len(s) and s[i] == "{":
            j = s.index("}", i)
            m = s[i + 1:j].split(",")[0]
            return max(int(m), 1 if len(s[i + 1:j].split(",")) > 1 and s[i + 1:j].split(",")[1] != "0" else int(m)), j + 1
        if i < len(s) and s[i] in "+":
            return 1, i + 1
        if i < len(s) and s[i] in "*?":
            return 0, i + 1
        return 1, i

    def _class_char(self, cls):
        neg = cls.startswith("^")
        body = cls[1:] if neg else cls
        i = 0
        chars = []
        while i < len(body):
            c = body[i]
            if c == "\\":
                e = body[i + 1]
                chars.append({"d": "0", "s": " ", "w": "a", "-": "-", ".": ".", "+": "+"}.get(e, e)); i += 2; continue
            if i + 2 < len(body) and body[i + 1] == "-":
                chars.append(body[i]); i += 3; continue
            chars.append(c); i += 1
        if neg:
            for cand in "AB1 ":
                if cand not in chars:
                    return cand
            return "A"
        # prefer a digit or a capital letter so numeric and BIC-like patterns read naturally
        for pref in ("0", "1", "A", "a"):
            if pref in chars:
                return pref
        return chars[0] if chars else "A"

    # ── the tree ──
    def element(self, name, tname):
        t = self.types[tname]
        if t["kind"] == "simple":
            return self.simple(t)
        model = t["model"]
        if model == "simpleContent":
            attr = t["attribute"]
            return {"@" + attr["name"]: self.simple(self.types[attr["type"]]), "#text": self.simple(self.types[t["simple"]])}
        if model == "choice":
            p = t["particles"][0]
            return {p["name"]: self.element(p["name"], p["type"])}
        out = {}
        for p in t["particles"]:
            if p["name"] == "*":
                continue
            if p["min"] == 0 and p["name"] not in self.force:
                continue
            self.depth += 1
            if self.depth > 60:
                raise ValueError("profile recursion too deep at " + name)
            out[p["name"]] = self.element(p["name"], p["type"])
            self.depth -= 1
        return out

    def instance(self):
        return {self.p["rootName"]: self.element(self.p["rootName"], self.p["rootType"])}


def serialise(tree, ns, indent=0):
    """Nested dicts to XML; a dict with '#text' carries attributes ('@x') and text."""
    (name, body), = tree.items()
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + _el(name, body, ns, 0)


def _el(name, body, ns, depth, top=True):
    pad = "  " * depth
    nsattr = f' xmlns="{ns}"' if depth == 0 and ns else ""
    if isinstance(body, dict) and "#text" in body:
        attrs = "".join(f' {k[1:]}="{v}"' for k, v in body.items() if k.startswith("@"))
        return f"{pad}<{name}{nsattr}{attrs}>{body['#text']}</{name}>\n"
    if isinstance(body, dict):
        inner = "".join(_el(k, v, ns, depth + 1) for k, v in body.items())
        return f"{pad}<{name}{nsattr}>\n{inner}{pad}</{name}>\n"
    if isinstance(body, list):
        return "".join(_el(name, v, ns, depth) for v in body)
    return f"{pad}<{name}{nsattr}>{body}</{name}>\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("family")
    ap.add_argument("--profiles", default=PROFILES)
    ap.add_argument("--with", dest="force", default="")
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    prof = load_profile(a.family, a.profiles)
    g = Gen(prof, random.Random(a.seed), [x for x in a.force.split(",") if x])
    print(serialise(g.instance(), prof["namespace"]), end="")


if __name__ == "__main__":
    main()
