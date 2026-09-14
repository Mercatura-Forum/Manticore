/// FspiopSchema.mo; a JSON body against the FSPIOP v1.1 request profile (FspiopProfiles.mo,
/// generated from the official OpenAPI snippets), the way IsoSchema.mo holds an ISO 20022 message
/// against its XSD-derived profile. Every issue names a rule, the JSON path and what was found:
///
///   FSPIOP-JSON-REQUIRED  a required property is absent
///   FSPIOP-JSON-TYPE      a value of another JSON type than the schema's
///   FSPIOP-JSON-PATTERN   a string outside its pattern (Rx.mo)
///   FSPIOP-JSON-ENUM      a string outside its enumeration
///   FSPIOP-JSON-LENGTH    a string shorter or longer than its bounds (in characters)
///   FSPIOP-JSON-ITEMS     an array with fewer or more items than its bounds
///   FSPIOP-JSON-RANGE     an integer outside its minimum/maximum
///   FSPIOP-JSON-ANYOF     a value matching none of the alternatives (anyOf), or not exactly one (oneOf)
///   FSPIOP-JSON-UNENFORCED a pattern outside Rx's subset; reported, never silently passed
///
/// Properties the schema does not name are allowed, as OpenAPI 3.0 allows them by default and as the
/// reference's validator does; the business rules of FspiopCore.mo read what they need afterwards.

import Char "mo:core/Char";
import Int "mo:core/Int";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Text "mo:core/Text";

import Json "Json";
import P "FspiopProfiles";
import Rx "Rx";

module {

  public type Issue = { rule : Text; path : Text; detail : Text };

  /// The issues of `value` against the named schema; empty when it conforms. An unknown schema name
  /// is one issue naming it (a generation defect, never a silent pass).
  public func validate(name : Text, value : Json.Json) : [Issue] {
    let out = List.empty<Issue>();
    switch (P.schema(name)) {
      case (?s) check(s, value, "$", out);
      case null List.add(out, { rule = "FSPIOP-JSON-UNENFORCED"; path = "$"; detail = "no schema named " # name });
    };
    List.toArray(out)
  };

  func typeName(v : Json.Json) : Text {
    switch (v) { case (#object_(_)) "object"; case (#array(_)) "array"; case (#string(_)) "string"; case (#number(_)) "number"; case (#bool(_)) "boolean"; case (#null_) "null" }
  };

  func isInteger(n : Text) : ?Int {
    var neg = false; var v : Int = 0; var digits = 0;
    for (c in n.chars()) {
      if (c == '-' and digits == 0 and not neg) neg := true
      else if (Char.isDigit(c)) { v := v * 10 + Nat32.toNat(Char.toNat32(c) - 48); digits += 1 }
      else return null;
    };
    if (digits == 0) return null;
    ?(if (neg) -v else v)
  };

  func check(s : P.Schema, v : Json.Json, path : Text, out : List.List<Issue>) {
    func add(rule : Text, detail : Text) { List.add(out, { rule; path; detail }) };
    switch (s) {
      case (#ref(name)) {
        switch (P.schema(name)) { case (?t) check(t, v, path, out); case null add("FSPIOP-JSON-UNENFORCED", "no schema named " # name) }
      };
      case (#object_(o)) {
        switch (v) {
          case (#object_(members)) {
            for (r in o.required.vals()) { if (not Json.has(v, r)) List.add(out, { rule = "FSPIOP-JSON-REQUIRED"; path = path # "." # r; detail = "required property absent" }) };
            for ((k, sub) in o.properties.vals()) {
              switch (Json.get(v, k)) { case (?x) check(sub, x, path # "." # k, out); case null {} };
            };
            ignore members;
          };
          case (_) add("FSPIOP-JSON-TYPE", "expected an object, found " # typeName(v));
        }
      };
      case (#array_(a)) {
        switch (v) {
          case (#array(xs)) {
            switch (a.minItems) { case (?m) { if (xs.size() < m) add("FSPIOP-JSON-ITEMS", Nat.toText(xs.size()) # " items, at least " # Nat.toText(m) # " required") }; case null {} };
            switch (a.maxItems) { case (?m) { if (xs.size() > m) add("FSPIOP-JSON-ITEMS", Nat.toText(xs.size()) # " items, at most " # Nat.toText(m) # " allowed") }; case null {} };
            var i = 0;
            for (x in xs.vals()) { check(a.items, x, path # "[" # Nat.toText(i) # "]", out); i += 1 };
          };
          case (_) add("FSPIOP-JSON-TYPE", "expected an array, found " # typeName(v));
        }
      };
      case (#string(st)) {
        switch (v) {
          case (#string(t)) {
            let n = Text.size(t);
            switch (st.minLength) { case (?m) { if (n < m) add("FSPIOP-JSON-LENGTH", Nat.toText(n) # " characters, at least " # Nat.toText(m) # " required") }; case null {} };
            switch (st.maxLength) { case (?m) { if (n > m) add("FSPIOP-JSON-LENGTH", Nat.toText(n) # " characters, at most " # Nat.toText(m) # " allowed") }; case null {} };
            switch (st.enum_) { case (?vals) { var ok = false; for (e in vals.vals()) { if (e == t) ok := true }; if (not ok) add("FSPIOP-JSON-ENUM", "'" # t # "' is not one of the enumeration") }; case null {} };
            switch (st.pattern) { case (?pat) checkPattern(pat, t, path, out); case null {} };
          };
          case (_) add("FSPIOP-JSON-TYPE", "expected a string, found " # typeName(v));
        }
      };
      case (#integer(r)) {
        switch (v) {
          case (#number(n)) {
            switch (isInteger(n)) {
              case (?i) {
                switch (r.minimum) { case (?m) { if (i < m) add("FSPIOP-JSON-RANGE", n # " is below the minimum " # Int.toText(m)) }; case null {} };
                switch (r.maximum) { case (?m) { if (i > m) add("FSPIOP-JSON-RANGE", n # " is above the maximum " # Int.toText(m)) }; case null {} };
              };
              case null add("FSPIOP-JSON-TYPE", "expected an integer, found " # n);
            }
          };
          case (_) add("FSPIOP-JSON-TYPE", "expected an integer, found " # typeName(v));
        }
      };
      case (#number) { switch (v) { case (#number(_)) {}; case (_) add("FSPIOP-JSON-TYPE", "expected a number, found " # typeName(v)) } };
      case (#boolean) { switch (v) { case (#bool(_)) {}; case (_) add("FSPIOP-JSON-TYPE", "expected a boolean, found " # typeName(v)) } };
      case (#allOf(c)) {
        for (alt in c.alternatives.vals()) check(alt, v, path, out);
        switch (c.pattern, v) { case (?pat, #string(t)) checkPattern(pat, t, path, out); case (_, _) {} };
      };
      case (#anyOf(c)) {
        if (matching(c.alternatives, v, path) == 0) add("FSPIOP-JSON-ANYOF", "matches none of the " # Nat.toText(c.alternatives.size()) # " alternatives");
        switch (c.pattern, v) { case (?pat, #string(t)) checkPattern(pat, t, path, out); case (_, _) {} };
      };
      case (#oneOf(c)) {
        let n = matching(c.alternatives, v, path);
        if (n != 1) add("FSPIOP-JSON-ANYOF", "matches " # Nat.toText(n) # " of the " # Nat.toText(c.alternatives.size()) # " alternatives, exactly one required");
        switch (c.pattern, v) { case (?pat, #string(t)) checkPattern(pat, t, path, out); case (_, _) {} };
      };
    }
  };

  func matching(alternatives : [P.Schema], v : Json.Json, path : Text) : Nat {
    var n = 0;
    for (alt in alternatives.vals()) { let probe = List.empty<Issue>(); check(alt, v, path, probe); if (List.isEmpty(probe)) n += 1 };
    n
  };

  func checkPattern(pat : Text, t : Text, path : Text, out : List.List<Issue>) {
    switch (Rx.test(pat, t)) {
      case (?true) {};
      case (?false) List.add(out, { rule = "FSPIOP-JSON-PATTERN"; path; detail = "'" # t # "' does not match " # pat });
      case null List.add(out, { rule = "FSPIOP-JSON-UNENFORCED"; path; detail = "pattern " # pat # " is outside the enforced subset" });
    }
  };

  /// The operation a request names: the specification's entry whose method and path template match
  /// (`{…}` segments match any one segment); null when the path is not one of the API's.
  public func operation(method : Text, path : Text) : ?P.Operation {
    let segs = split(path);
    for (op in P.OPERATIONS.vals()) {
      if (op.method == method) {
        let tsegs = split(op.path);
        if (tsegs.size() == segs.size()) {
          var ok = true;
          var i = 0;
          while (i < segs.size() and ok) {
            let t = tsegs[i];
            if (not (Text.startsWith(t, #text "{") and Text.endsWith(t, #text "}")) and t != segs[i]) ok := false;
            i += 1;
          };
          if (ok) return ?op;
        };
      };
    };
    null
  };

  /// Whether any operation of the specification has this path (so a wrong method is 405-class, a
  /// wrong path 3002).
  public func pathKnown(path : Text) : Bool {
    for (op in P.OPERATIONS.vals()) { if (operation(op.method, path) != null) return true };
    false
  };

  func split(path : Text) : [Text] {
    let out = List.empty<Text>();
    for (sg in Text.split(path, #char '/')) { if (Text.size(sg) > 0) List.add(out, sg) };
    List.toArray(out)
  };
}
