/// Json.mo: JSON (RFC 8259) parsed to a tree and written back, for the FSPIOP adapter.
///
/// Numbers are kept as their text (an FSPIOP `Amount` is a string anyway, and nothing here does
/// arithmetic on a JSON number); strings are decoded with every escape of the grammar, surrogate
/// pairs included; objects keep their members in document order and a duplicated member name is
/// refused (RFC 8259 §4 leaves it undefined, the interoperability profile of FSPIOP does not want
/// it). Depth is bounded, so a hostile document cannot exhaust the stack.

import Array "mo:core/Array";
import Char "mo:core/Char";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Result "mo:core/Result";
import Text "mo:core/Text";

module {

  public type Json = {
    #object_ : [(Text, Json)];
    #array : [Json];
    #string : Text;
    #number : Text;
    #bool : Bool;
    #null_;
  };

  public let MAX_DEPTH : Nat = 64;

  public func parse(text : Text) : Result.Result<Json, Text> {
    let cs = Iter.toArray(text.chars());
    var pos = 0;
    let n = cs.size();
    func peek() : ?Char { if (pos < n) ?cs[pos] else null };
    func ws() { while (pos < n and (cs[pos] == ' ' or cs[pos] == '\t' or cs[pos] == '\n' or cs[pos] == '\r')) pos += 1 };
    func expect(c : Char) : ?Text { if (pos < n and cs[pos] == c) { pos += 1; null } else ?("expected '" # Char.toText(c) # "' at " # Nat.toText(pos)) };
    func hex4() : ?Nat32 {
      if (pos + 4 > n) return null;
      var v : Nat32 = 0;
      var i = 0;
      while (i < 4) {
        let c = cs[pos + i];
        let d : Nat32 = if (Char.isDigit(c)) Char.toNat32(c) - 48 else if (c >= 'a' and c <= 'f') Char.toNat32(c) - 97 + 10 else if (c >= 'A' and c <= 'F') Char.toNat32(c) - 65 + 10 else return null;
        v := v * 16 + d;
        i += 1;
      };
      pos += 4;
      ?v
    };
    func string() : Result.Result<Text, Text> {
      switch (expect('\u{22}')) { case (?e) return #err(e); case null {} };
      var out = "";
      label scan loop {
        let ?c = peek() else return #err("unterminated string");
        pos += 1;
        if (c == '\u{22}') break scan;
        if (c == '\\') {
          let ?e = peek() else return #err("dangling escape");
          pos += 1;
          switch (e) {
            case ('\u{22}') out #= "\u{22}"; case ('\\') out #= "\\"; case ('/') out #= "/";
            case ('b') out #= "\u{08}"; case ('f') out #= "\u{0C}"; case ('n') out #= "\n"; case ('r') out #= "\r"; case ('t') out #= "\t";
            case ('u') {
              let ?hi = hex4() else return #err("bad \\u escape");
              if (hi >= 0xD800 and hi <= 0xDBFF) {
                // a surrogate pair
                if (pos + 6 > n or cs[pos] != '\\' or cs[pos + 1] != 'u') return #err("lone high surrogate");
                pos += 2;
                let ?lo = hex4() else return #err("bad \\u escape");
                if (lo < 0xDC00 or lo > 0xDFFF) return #err("bad low surrogate");
                out #= Char.toText(Char.fromNat32(0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)));
              } else if (hi >= 0xDC00 and hi <= 0xDFFF) return #err("lone low surrogate")
              else out #= Char.toText(Char.fromNat32(hi));
            };
            case (_) return #err("bad escape");
          };
        } else {
          if (Char.toNat32(c) < 0x20) return #err("control character in string");
          out #= Char.toText(c);
        };
      };
      #ok(out)
    };
    func number() : Result.Result<Text, Text> {
      let start = pos;
      if (peek() == ?'-') pos += 1;
      switch (peek()) {
        case (?'0') pos += 1;
        case (?c) { if (c >= '1' and c <= '9') { while (pos < n and Char.isDigit(cs[pos])) pos += 1 } else return #err("bad number") };
        case null return #err("bad number");
      };
      if (peek() == ?'.') { pos += 1; let f = pos; while (pos < n and Char.isDigit(cs[pos])) pos += 1; if (pos == f) return #err("bad fraction") };
      switch (peek()) {
        case (?'e' or ?'E') { pos += 1; switch (peek()) { case (?'+' or ?'-') pos += 1; case (_) {} }; let f = pos; while (pos < n and Char.isDigit(cs[pos])) pos += 1; if (pos == f) return #err("bad exponent") };
        case (_) {};
      };
      #ok(Text.fromIter(Iter.fromArray(Array.tabulate<Char>(pos - start, func(i) { cs[start + i] }))))
    };
    func value(depth : Nat) : Result.Result<Json, Text> {
      if (depth > MAX_DEPTH) return #err("nesting deeper than " # Nat.toText(MAX_DEPTH));
      ws();
      let ?c = peek() else return #err("unexpected end");
      switch (c) {
        case ('{') {
          pos += 1;
          let members = List.empty<(Text, Json)>();
          ws();
          if (peek() == ?'}') { pos += 1; return #ok(#object_([])) };
          label members loop {
            ws();
            let key = switch (string()) { case (#ok(k)) k; case (#err(e)) return #err(e) };
            for ((k, _) in List.values(members)) { if (k == key) return #err("duplicate member " # key) };
            ws();
            switch (expect(':')) { case (?e) return #err(e); case null {} };
            let v = switch (value(depth + 1)) { case (#ok(v)) v; case (#err(e)) return #err(e) };
            List.add(members, (key, v));
            ws();
            switch (peek()) { case (?',') { pos += 1 }; case (?'}') { pos += 1; break members }; case (_) return #err("expected , or } at " # Nat.toText(pos)) };
          };
          #ok(#object_(List.toArray(members)))
        };
        case ('[') {
          pos += 1;
          let items = List.empty<Json>();
          ws();
          if (peek() == ?']') { pos += 1; return #ok(#array([])) };
          label items loop {
            let v = switch (value(depth + 1)) { case (#ok(v)) v; case (#err(e)) return #err(e) };
            List.add(items, v);
            ws();
            switch (peek()) { case (?',') { pos += 1 }; case (?']') { pos += 1; break items }; case (_) return #err("expected , or ] at " # Nat.toText(pos)) };
          };
          #ok(#array(List.toArray(items)))
        };
        case ('\u{22}') { switch (string()) { case (#ok(s)) #ok(#string(s)); case (#err(e)) #err(e) } };
        case ('t') { if (pos + 4 <= n and cs[pos + 1] == 'r' and cs[pos + 2] == 'u' and cs[pos + 3] == 'e') { pos += 4; #ok(#bool(true)) } else #err("bad literal") };
        case ('f') { if (pos + 5 <= n and cs[pos + 1] == 'a' and cs[pos + 2] == 'l' and cs[pos + 3] == 's' and cs[pos + 4] == 'e') { pos += 5; #ok(#bool(false)) } else #err("bad literal") };
        case ('n') { if (pos + 4 <= n and cs[pos + 1] == 'u' and cs[pos + 2] == 'l' and cs[pos + 3] == 'l') { pos += 4; #ok(#null_) } else #err("bad literal") };
        case (_) { switch (number()) { case (#ok(t)) #ok(#number(t)); case (#err(e)) #err(e) } };
      }
    };
    switch (value(0)) {
      case (#err(e)) #err(e);
      case (#ok(v)) { ws(); if (pos != n) #err("trailing content at " # Nat.toText(pos)) else #ok(v) }
    }
  };

  public func escape(t : Text) : Text {
    var out = "";
    for (c in t.chars()) {
      switch (c) {
        case ('\u{22}') out #= "\\\u{22}"; case ('\\') out #= "\\\\"; case ('\n') out #= "\\n"; case ('\r') out #= "\\r"; case ('\t') out #= "\\t";
        case (_) { if (Char.toNat32(c) < 0x20) { out #= "\\u00" # hex2(Char.toNat32(c)) } else out #= Char.toText(c) };
      };
    };
    out
  };
  func hex2(v : Nat32) : Text { let d = Text.toArray("0123456789abcdef"); Char.toText(d[Nat32.toNat(v / 16)]) # Char.toText(d[Nat32.toNat(v % 16)]) };

  public func emit(j : Json) : Text {
    switch (j) {
      case (#object_(ms)) { var out = "{"; var first = true; for ((k, v) in ms.vals()) { if (not first) out #= ","; first := false; out #= "\"" # escape(k) # "\":" # emit(v) }; out # "}" };
      case (#array(xs)) { var out = "["; var first = true; for (x in xs.vals()) { if (not first) out #= ","; first := false; out #= emit(x) }; out # "]" };
      case (#string(s)) "\"" # escape(s) # "\"";
      case (#number(t)) t;
      case (#bool(b)) if (b) "true" else "false";
      case (#null_) "null";
    }
  };

  // ─── reading ───

  public func get(j : Json, key : Text) : ?Json { switch (j) { case (#object_(ms)) { for ((k, v) in ms.vals()) { if (k == key) return ?v }; null }; case (_) null } };
  public func str(j : Json, key : Text) : ?Text { switch (get(j, key)) { case (?#string(s)) ?s; case (_) null } };
  public func obj(j : Json, key : Text) : ?Json { switch (get(j, key)) { case (?v) { switch (v) { case (#object_(_)) ?v; case (_) null } }; case null null } };
  public func arr(j : Json, key : Text) : ?[Json] { switch (get(j, key)) { case (?#array(xs)) ?xs; case (_) null } };
  public func keys(j : Json) : [Text] { switch (j) { case (#object_(ms)) Array.map<(Text, Json), Text>(ms, func((k, _)) { k }); case (_) [] } };
  public func has(j : Json, key : Text) : Bool { get(j, key) != null };
}
