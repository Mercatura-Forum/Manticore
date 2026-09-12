/// IsoSchema.mo — vendored from thebes-banking-core (src/bank/IsoSchema.mo, commit f7e3563); unchanged except this note
/// and the profile import (the hub generates its own IsoProfiles.mo for its families; `schemaFor` asks the
/// generated `byNamespace`, which builds the one schema named rather than all of them).
/// IsoSchema.mo — validation of a parsed message against a generated ISO 20022 profile (IsoProfiles.mo).
///
/// The profile is the schema's own tree: content models with cardinalities, simple types with
/// facets. This walks an element tree against it and reports every disagreement with a stable rule
/// id and the element's path, so the integration kit and the harness (`tools/iso20022/profile_check.py`,
/// which runs `xmllint --schema` on the same instances) can compare verdict for verdict:
///
///   ISO-XSD-ROOT        the root element is not the schema's, or not in its namespace
///   ISO-XSD-NAMESPACE   an element outside the target namespace (elementFormDefault is qualified)
///   ISO-XSD-UNEXPECTED  an element the content model does not allow at that position
///   ISO-XSD-MISSING     a required element absent
///   ISO-XSD-TOO-MANY    more occurrences than maxOccurs
///   ISO-XSD-CHOICE      a choice with no alternative, or more than one
///   ISO-XSD-ATTRIBUTE   an attribute the type does not declare, or its required one missing
///   ISO-XSD-TEXT        child elements under a simple-typed element, or text where none is allowed
///   ISO-XSD-LENGTH      minLength / maxLength
///   ISO-XSD-PATTERN     the pattern facet
///   ISO-XSD-ENUM        the enumeration facet
///   ISO-XSD-DECIMAL     not a decimal, or totalDigits / fractionDigits / minInclusive
///   ISO-XSD-BOOLEAN, ISO-XSD-DATE, ISO-XSD-DATETIME, ISO-XSD-TIME, ISO-XSD-YEARMONTH  the lexical types
///   ISO-XSD-UNENFORCED  a pattern outside the enforced regular-expression subset (Rx.mo) — reported,
///                       never silently passed
///
/// What is enforced is exactly what the profile carries; the harness's agreement check is the claim.

import Array "mo:core/Array";
import Char "mo:core/Char";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Text "mo:core/Text";

import P "IsoProfiles";
import Rx "Rx";
import Xml "Xml";

module {

  public type Issue = { rule : Text; path : Text; detail : Text };

  public func validate(schema : P.Schema, root : Xml.Element) : [Issue] {
    let issues = List.empty<Issue>();
    func add(rule : Text, path : Text, detail : Text) { List.add(issues, { rule; path; detail }) };
    if (root.name != schema.rootName or root.namespace != schema.namespace) {
      add("ISO-XSD-ROOT", "/" # root.name, "expected <" # schema.rootName # "> in " # schema.namespace # ", got <" # root.name # "> in " # (if (root.namespace == "") "no namespace" else root.namespace));
      return List.toArray(issues);
    };
    element(schema, root, schema.root, "/" # root.name, add);
    List.toArray(issues)
  };

  func element(schema : P.Schema, e : Xml.Element, typ : Nat, path : Text, add : (Text, Text, Text) -> ()) {
    if (e.namespace != schema.namespace) add("ISO-XSD-NAMESPACE", path, "element outside " # schema.namespace);
    switch (schema.types[typ]) {
      case (#simple(s)) {
        if (e.attributes.size() > 0) add("ISO-XSD-ATTRIBUTE", path, "attribute " # e.attributes[0].0 # " not declared");
        if (e.children.size() > 0) { add("ISO-XSD-TEXT", path, "child elements under a simple-typed element"); return };
        simple(s, e.text, path, add);
      };
      case (#simpleContent(sc)) {
        if (e.children.size() > 0) { add("ISO-XSD-TEXT", path, "child elements under a simple-content element"); return };
        var seen = false;
        for ((k, v) in e.attributes.vals()) {
          if (k == sc.attribute) {
            seen := true;
            switch (schema.types[sc.attributeType]) { case (#simple(s)) simple(s, v, path # "/@" # k, add); case (_) {} };
          } else add("ISO-XSD-ATTRIBUTE", path, "attribute " # k # " not declared");
        };
        if (not seen) add("ISO-XSD-ATTRIBUTE", path, "required attribute " # sc.attribute # " missing");
        switch (schema.types[sc.simple]) { case (#simple(s)) simple(s, e.text, path, add); case (_) {} };
      };
      case (#sequence(seq)) {
        if (e.attributes.size() > 0) add("ISO-XSD-ATTRIBUTE", path, "attribute " # e.attributes[0].0 # " not declared");
        if (Text.size(e.text) > 0 and Text.size(Xml.trim(e.text)) > 0) add("ISO-XSD-TEXT", path, "text where child elements are expected");
        sequence(schema, e, seq.particles, path, add);
      };
      case (#choice(ch)) {
        if (e.attributes.size() > 0) add("ISO-XSD-ATTRIBUTE", path, "attribute " # e.attributes[0].0 # " not declared");
        if (Text.size(e.text) > 0 and Text.size(Xml.trim(e.text)) > 0) add("ISO-XSD-TEXT", path, "text where child elements are expected");
        choice(schema, e, ch.particles, path, add);
      };
    };
  };

  func particleOf(particles : [P.Particle], name : Text, from : Nat) : ?Nat {
    var i = from;
    while (i < particles.size()) { if (particles[i].name == name) return ?i; i += 1 };
    null
  };

  func sequence(schema : P.Schema, e : Xml.Element, particles : [P.Particle], path : Text, add : (Text, Text, Text) -> ()) {
    var ci = 0;
    let kids = e.children;
    var pi = 0;
    while (pi < particles.size()) {
      let p = particles[pi];
      var count = 0;
      if (p.name == "*") {
        // xs:any, lax: anything not claimed by a later particle, up to max
        label anyLoop while (ci < kids.size()) {
          switch (particleOf(particles, kids[ci].name, pi + 1)) { case (?_) break anyLoop; case null {} };
          switch (p.max) { case (?m) { if (count >= m) break anyLoop }; case null {} };
          ci += 1; count += 1;
        };
      } else {
        while (ci < kids.size() and kids[ci].name == p.name) {
          count += 1;
          let childPath = path # "/" # p.name # (if (count > 1) "[" # Nat.toText(count) # "]" else "");
          switch (p.max) { case (?m) { if (count > m) add("ISO-XSD-TOO-MANY", childPath, "at most " # Nat.toText(m) # " of " # p.name) }; case null {} };
          element(schema, kids[ci], p.typ, childPath, add);
          ci += 1;
        };
      };
      if (count < p.min) {
        // is the child at this position an element of a later particle (so this one is missing),
        // or something the model does not allow here at all?
        if (ci < kids.size()) {
          switch (particleOf(particles, kids[ci].name, pi + 1)) {
            case (?_) add("ISO-XSD-MISSING", path # "/" # p.name, "required element " # p.name # " missing");
            case null {
              add("ISO-XSD-UNEXPECTED", path # "/" # kids[ci].name, "element " # kids[ci].name # " not expected here; expected " # p.name);
              ci += 1;
              continue;   // the same particle again, against the next child
            };
          };
        } else add("ISO-XSD-MISSING", path # "/" # p.name, "required element " # p.name # " missing");
      };
      pi += 1;
    };
    while (ci < kids.size()) { add("ISO-XSD-UNEXPECTED", path # "/" # kids[ci].name, "element " # kids[ci].name # " not expected here"); ci += 1 };
  };

  func choice(schema : P.Schema, e : Xml.Element, particles : [P.Particle], path : Text, add : (Text, Text, Text) -> ()) {
    let kids = e.children;
    if (kids.size() == 0) { add("ISO-XSD-CHOICE", path, "one of " # names(particles) # " is required"); return };
    let ?pi = particleOf(particles, kids[0].name, 0) else { add("ISO-XSD-UNEXPECTED", path # "/" # kids[0].name, "element " # kids[0].name # " is not one of " # names(particles)); return };
    let p = particles[pi];
    var count = 0;
    for (k in kids.vals()) {
      if (k.name != p.name) { add("ISO-XSD-CHOICE", path # "/" # k.name, "more than one alternative of " # names(particles)); continue };
      count += 1;
      let childPath = path # "/" # p.name # (if (count > 1) "[" # Nat.toText(count) # "]" else "");
      switch (p.max) { case (?m) { if (count > m) add("ISO-XSD-TOO-MANY", childPath, "at most " # Nat.toText(m) # " of " # p.name) }; case null {} };
      element(schema, k, p.typ, childPath, add);
    };
    if (count < p.min) add("ISO-XSD-MISSING", path # "/" # p.name, "required element " # p.name # " missing");
  };

  func names(particles : [P.Particle]) : Text { var out = ""; for (p in particles.vals()) { out #= (if (out == "") "" else " | ") # p.name }; out };

  // ─── simple types ───

  /// The decoded length of a base64Binary lexical value (RFC 4648 alphabet, `=` padding, whitespace
  /// between characters allowed by XSD), or null when it is not one.
  func base64Octets(raw : Text) : ?Nat {
    var chars = 0; var pad = 0; var ended = false;
    for (c in raw.chars()) {
      if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {}
      else if (c == '=') { pad += 1; ended := true; if (pad > 2) return null }
      else if (ended) return null
      else if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '+' or c == '/') chars += 1
      else return null;
    };
    if ((chars + pad) % 4 != 0) return null;
    if (pad > 0 and chars % 4 == 0) return null;
    ?((chars + pad) / 4 * 3 - pad)
  };

  func simple(s : P.Simple, raw : Text, path : Text, add : (Text, Text, Text) -> ()) {
    switch (s.base) {
      case (#string) {
        let len = Text.size(raw);
        switch (s.minLength) { case (?m) { if (len < m) add("ISO-XSD-LENGTH", path, "shorter than " # Nat.toText(m)) }; case null {} };
        switch (s.maxLength) { case (?m) { if (len > m) add("ISO-XSD-LENGTH", path, "longer than " # Nat.toText(m)) }; case null {} };
        if (s.enums.size() > 0) { var ok = false; for (v in s.enums.vals()) { if (v == raw) ok := true }; if (not ok) add("ISO-XSD-ENUM", path, "'" # raw # "' is not an allowed value of " # s.name) };
        switch (s.pattern) {
          case (?pat) { switch (Rx.test(pat, raw)) { case (?true) {}; case (?false) add("ISO-XSD-PATTERN", path, "'" # raw # "' does not match " # pat); case null add("ISO-XSD-UNENFORCED", path, "pattern " # pat # " is outside the enforced subset") } };
          case null {};
        };
      };
      case (#base64Binary) {
        // XSD Part 2 §3.2.16: the canonical lexical form, whitespace allowed between groups; the length
        // facets count decoded octets
        switch (base64Octets(raw)) {
          case (?n) {
            switch (s.minLength) { case (?m) { if (n < m) add("ISO-XSD-LENGTH", path, Nat.toText(n) # " octets, shorter than " # Nat.toText(m)) }; case null {} };
            switch (s.maxLength) { case (?m) { if (n > m) add("ISO-XSD-LENGTH", path, Nat.toText(n) # " octets, longer than " # Nat.toText(m)) }; case null {} };
          };
          case null add("ISO-XSD-BASE64", path, "not base64Binary");
        };
      };
      case (#decimal) decimal(s, Xml.trim(raw), path, add);
      case (#boolean) { let t = Xml.trim(raw); if (t != "true" and t != "false" and t != "1" and t != "0") add("ISO-XSD-BOOLEAN", path, "'" # raw # "' is not a boolean") };
      case (#date) { if (not isDate(Xml.trim(raw), true)) add("ISO-XSD-DATE", path, "'" # raw # "' is not a date") };
      case (#dateTime) { if (not isDateTime(Xml.trim(raw))) add("ISO-XSD-DATETIME", path, "'" # raw # "' is not a dateTime") };
      case (#time) { if (not isTime(Xml.trim(raw), true)) add("ISO-XSD-TIME", path, "'" # raw # "' is not a time") };
      case (#yearMonth) { if (not isYearMonth(Xml.trim(raw))) add("ISO-XSD-YEARMONTH", path, "'" # raw # "' is not a gYearMonth") };
      case (#year) { if (not isYear(Xml.trim(raw))) add("ISO-XSD-YEAR", path, "'" # raw # "' is not a gYear") };
    };
  };

  func digitsOnly(t : Text) : Bool { if (Text.size(t) == 0) return false; for (c in t.chars()) { if (not Char.isDigit(c)) return false }; true };

  func decimal(s : P.Simple, t : Text, path : Text, add : (Text, Text, Text) -> ()) {
    // lexical: [+-]? digits [. digits]  with at least one digit somewhere
    var body = t;
    var negative = false;
    if (Text.startsWith(body, #text "-")) { negative := true; body := Text.trimStart(body, #text "-") }
    else if (Text.startsWith(body, #text "+")) body := Text.trimStart(body, #text "+");
    let parts = Array.fromIter<Text>(Text.split(body, #char '.'));
    if (parts.size() == 0 or parts.size() > 2) { add("ISO-XSD-DECIMAL", path, "'" # t # "' is not a decimal"); return };
    let intPart = parts[0];
    let fracPart = if (parts.size() == 2) parts[1] else "";
    if ((Text.size(intPart) > 0 and not digitsOnly(intPart)) or (Text.size(fracPart) > 0 and not digitsOnly(fracPart)) or (Text.size(intPart) == 0 and Text.size(fracPart) == 0)) { add("ISO-XSD-DECIMAL", path, "'" # t # "' is not a decimal"); return };
    // canonical digits: no leading zeros in the integer part, no trailing zeros in the fraction
    let canonInt = Text.trimStart(intPart, #char '0');
    let canonFrac = Text.trimEnd(fracPart, #char '0');
    let total = Text.size(canonInt) + Text.size(canonFrac);
    switch (s.totalDigits) { case (?m) { if (total > m) add("ISO-XSD-DECIMAL", path, "more than " # Nat.toText(m) # " digits") }; case null {} };
    switch (s.fractionDigits) { case (?m) { if (Text.size(canonFrac) > m) add("ISO-XSD-DECIMAL", path, "more than " # Nat.toText(m) # " fraction digits") }; case null {} };
    switch (s.minInclusive) {
      case (?minText) {
        // the schemas' only minimum is 0: a negative non-zero value is below it
        let isZero = total == 0;
        if (minText == "0") { if (negative and not isZero) add("ISO-XSD-DECIMAL", path, "below the minimum 0") }
        else add("ISO-XSD-UNENFORCED", path, "minInclusive " # minText # " is outside the enforced subset");
      };
      case null {};
    };
  };

  func cs(t : Text) : [Char] { Iter.toArray(t.chars()) };
  func d(c : Char) : Bool { Char.isDigit(c) };

  /// `(Z|[+-]hh:mm)?` at `from`; returns whether the rest is a valid zone (or empty).
  func zone(a : [Char], from : Nat) : Bool {
    if (from == a.size()) return true;
    if (a[from] == 'Z') return from + 1 == a.size();
    if ((a[from] == '+' or a[from] == '-') and from + 6 == a.size()) {
      return d(a[from + 1]) and d(a[from + 2]) and a[from + 3] == ':' and d(a[from + 4]) and d(a[from + 5]) and twoDigit(a, from + 1) <= 14 and twoDigit(a, from + 4) <= 59
    };
    false
  };
  func twoDigit(a : [Char], i : Nat) : Nat { Nat32.toNat(Char.toNat32(a[i]) - 48) * 10 + Nat32.toNat(Char.toNat32(a[i + 1]) - 48) };

  /// `-?YYYY-MM-DD` (at least four year digits), then a zone when `withZone`.
  func dateAt(a : [Char], start : Nat) : ?Nat {
    var i = start;
    if (i < a.size() and a[i] == '-') i += 1;
    let y0 = i;
    while (i < a.size() and d(a[i])) i += 1;
    if (i - y0 < 4) return null;
    if (i - y0 > 4 and a[y0] == '0') return null;
    if (i + 6 > a.size() or a[i] != '-' or not d(a[i + 1]) or not d(a[i + 2]) or a[i + 3] != '-' or not d(a[i + 4]) or not d(a[i + 5])) return null;
    let m = twoDigit(a, i + 1); let dd = twoDigit(a, i + 4);
    if (m < 1 or m > 12 or dd < 1 or dd > 31) return null;
    if (dd > 30 and (m == 4 or m == 6 or m == 9 or m == 11)) return null;
    if (m == 2 and dd > 29) return null;
    ?(i + 6)
  };
  func isDate(t : Text, withZone : Bool) : Bool { let a = cs(t); switch (dateAt(a, 0)) { case (?e) { if (withZone) zone(a, e) else e == a.size() }; case null false } };
  /// `hh:mm:ss(.s+)?` at `start`.
  func timeAt(a : [Char], start : Nat) : ?Nat {
    var i = start;
    if (i + 8 > a.size()) return null;
    if (not (d(a[i]) and d(a[i + 1]) and a[i + 2] == ':' and d(a[i + 3]) and d(a[i + 4]) and a[i + 5] == ':' and d(a[i + 6]) and d(a[i + 7]))) return null;
    let h = twoDigit(a, i); let mi = twoDigit(a, i + 3); let s = twoDigit(a, i + 6);
    if (h > 24 or mi > 59 or s > 59) return null;
    if (h == 24 and (mi != 0 or s != 0)) return null;
    i += 8;
    if (i < a.size() and a[i] == '.') {
      i += 1;
      let f0 = i;
      while (i < a.size() and d(a[i])) i += 1;
      if (i == f0) return null;
    };
    ?i
  };
  func isTime(t : Text, withZone : Bool) : Bool { let a = cs(t); switch (timeAt(a, 0)) { case (?e) { if (withZone) zone(a, e) else e == a.size() }; case null false } };
  func isDateTime(t : Text) : Bool {
    let a = cs(t);
    switch (dateAt(a, 0)) {
      case (?e) { if (e >= a.size() or a[e] != 'T') return false; switch (timeAt(a, e + 1)) { case (?e2) zone(a, e2); case null false } };
      case null false;
    }
  };
  /// xs:gYear: an optional sign, at least four digits, an optional timezone.
  func isYear(t : Text) : Bool {
    let a = cs(t);
    var i = 0;
    if (i < a.size() and a[i] == '-') i += 1;
    let y0 = i;
    while (i < a.size() and d(a[i])) i += 1;
    if (i - y0 < 4) return false;
    zone(a, i)
  };
  func isYearMonth(t : Text) : Bool {
    let a = cs(t);
    var i = 0;
    if (i < a.size() and a[i] == '-') i += 1;
    let y0 = i;
    while (i < a.size() and d(a[i])) i += 1;
    if (i - y0 < 4) return false;
    if (i + 3 > a.size() or a[i] != '-' or not d(a[i + 1]) or not d(a[i + 2])) return false;
    let m = twoDigit(a, i + 1);
    if (m < 1 or m > 12) return false;
    zone(a, i + 3)
  };

  /// The schema for a message family by its namespace, if it is one this component carries.
  public func schemaFor(namespace : Text) : ?P.Schema { P.byNamespace(namespace) };
}
