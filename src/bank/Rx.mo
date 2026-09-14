/// Rx.mo: the regular-expression subset the schemas the bank enforces are written in: the XSD
/// patterns of the ISO 20022 base schemas (IsoSchema.mo, twenty distinct patterns across seven
/// schemas) and the JSON-schema patterns of the FSPIOP v1.1 OpenAPI snippets (FspiopSchema.mo,
/// eighteen distinct patterns). This module parses that subset and matches a whole text against it
/// by backtracking. A pattern outside the subset is refused at parse time (`#err`), never silently
/// accepted: a constraint that cannot be enforced is reported, not dropped.
///
/// Supported:
///   classes      `[...]` and `[^...]` with ranges, the escapes below, and `\p{...}` properties
///   escapes      `\d \D \w \W \s \S` (the ECMAScript sets the reference validates with: `\d` is
///                [0-9], `\w` is [A-Za-z0-9_], `\s` is the WhiteSpace and LineTerminator set) and
///                `\- \+ \( \) \. \\ \[ \] \{ \} \* \? \| \^ \$ \/`
///   properties   `\p{L}` `\p{gc=Mark}` `\p{digit}` `\p{gc=Connector_Punctuation}` `\p{Join_Control}`
///                from the generated Unicode tables (UnicodeClasses.mo)
///   groups       `(...)` and the non-capturing `(?:...)`; alternation `|` between the branches of
///                a group or of the whole pattern
///   lookahead    the negative `(?!...)`, zero-width
///   anchors      `^` and `$`, zero-width (every pattern is anchored at both ends implicitly; the
///                anchors matter inside a lookahead or an alternation branch)
///   quantifiers  `{m}`, `{m,n}`, `{m,}`, `?`, `*`, `+`
/// Refused: the any-character atom `.`, back-references, positive lookahead, lookbehind, flags.

import Char "mo:core/Char";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Result "mo:core/Result";
import Text "mo:core/Text";

import U "UnicodeClasses";

module {

  public type Atom = {
    #class_ : { ranges : [(Nat32, Nat32)]; negated : Bool };
    #literal : Char;
    #group : [Node];
    #alt : [[Node]];
    #notAhead : [Node];
    #start;
    #end;
  };
  public type Node = { atom : Atom; min : Nat; max : ?Nat };

  public type Pattern = [Node];

  let DIGITS : [(Nat32, Nat32)] = [(0x30, 0x39)];
  let WORD : [(Nat32, Nat32)] = [(0x30, 0x39), (0x41, 0x5A), (0x5F, 0x5F), (0x61, 0x7A)];
  // ECMAScript WhiteSpace ∪ LineTerminator
  let SPACE : [(Nat32, Nat32)] = [(0x09, 0x0D), (0x20, 0x20), (0xA0, 0xA0), (0x1680, 0x1680), (0x2000, 0x200A), (0x2028, 0x2029), (0x202F, 0x202F), (0x205F, 0x205F), (0x3000, 0x3000), (0xFEFF, 0xFEFF)];

  func property(name : Text) : ?[(Nat32, Nat32)] {
    switch (name) {
      case ("L" or "Letter") ?U.LETTER;
      case ("M" or "Mark" or "gc=Mark" or "gc=M") ?U.MARK;
      case ("Nd" or "digit" or "gc=Nd" or "gc=Decimal_Number") ?U.DECIMAL_DIGIT;
      case ("Pc" or "gc=Pc" or "gc=Connector_Punctuation" or "Connector_Punctuation") ?U.CONNECTOR_PUNCTUATION;
      case ("Join_Control" or "Join_C") ?U.JOIN_CONTROL;
      case (_) null;
    }
  };

  /// The complement of sorted, disjoint ranges over the scalar values.
  func complement(ranges : [(Nat32, Nat32)]) : [(Nat32, Nat32)] {
    let out = List.empty<(Nat32, Nat32)>();
    var next : Nat32 = 0;
    for ((lo, hi) in ranges.vals()) {
      if (lo > next) List.add(out, (next, lo - 1));
      next := hi + 1;
    };
    if (next <= 0x10FFFF) List.add(out, (next, 0x10FFFF : Nat32));
    List.toArray(out)
  };

  func sortRanges(rs : [(Nat32, Nat32)]) : [(Nat32, Nat32)] {
    // insertion sort on the few ranges a class carries; the property tables are already sorted
    let a = List.fromArray<(Nat32, Nat32)>(rs);
    let n = List.size(a);
    var i = 1;
    while (i < n) {
      let x = List.at(a, i);
      var j = i;
      while (j > 0 and List.at(a, j - 1).0 > x.0) { List.put(a, j, List.at(a, j - 1)); j -= 1 };
      List.put(a, j, x);
      i += 1;
    };
    List.toArray(a)
  };

  public func compile(pattern : Text) : Result.Result<Pattern, Text> {
    let chars = Iter.toArray(pattern.chars());
    var pos = 0;
    let n = chars.size();

    func peek() : ?Char { if (pos < n) ?chars[pos] else null };
    func take() : ?Char { if (pos < n) { let c = chars[pos]; pos += 1; ?c } else null };

    // an escape, as the ranges it stands for (negated for the upper-case sets) or a literal
    type Esc = { #ranges : ([(Nat32, Nat32)], Bool); #literal : Char };
    func escape(c : Char) : Result.Result<Esc, Text> {
      switch (c) {
        case ('d') #ok(#ranges((DIGITS, false)));
        case ('D') #ok(#ranges((DIGITS, true)));
        case ('w') #ok(#ranges((WORD, false)));
        case ('W') #ok(#ranges((WORD, true)));
        case ('s') #ok(#ranges((SPACE, false)));
        case ('S') #ok(#ranges((SPACE, true)));
        case ('p' or 'P') {
          switch (take()) { case (?'{') {}; case (_) return #err("Rx: \\p without {") };
          var name = "";
          label rd loop { let ?k = take() else return #err("Rx: unterminated \\p{"); if (k == '}') break rd; name #= Char.toText(k) };
          switch (property(name)) { case (?rs) #ok(#ranges((rs, c == 'P'))); case null #err("Rx: unsupported Unicode property \\p{" # name # "}") }
        };
        case ('-' or '+' or '(' or ')' or '.' or '\\' or '[' or ']' or '{' or '}' or '*' or '?' or '|' or '^' or '$' or '/') #ok(#literal(c));
        case ('t') #ok(#literal('\t'));
        case ('n') #ok(#literal('\n'));
        case ('r') #ok(#literal('\r'));
        case (_) #err("Rx: unsupported escape \\" # Char.toText(c));
      }
    };

    func parseClass() : Result.Result<Atom, Text> {
      // after '['
      let ranges = List.empty<(Nat32, Nat32)>();
      var negated = false;
      switch (peek()) { case (?'^') { negated := true; pos += 1 }; case (_) {} };
      label scan loop {
        let ?c = take() else return #err("Rx: unterminated class");
        if (c == ']') break scan;
        var lo = Char.toNat32(c);
        if (c == '\\') {
          let ?e = take() else return #err("Rx: dangling escape in class");
          switch (escape(e)) {
            case (#ok(#literal(l))) lo := Char.toNat32(l);
            case (#ok(#ranges((rs, neg)))) { for (r in (if (neg) complement(rs) else rs).vals()) List.add(ranges, r); continue scan };
            case (#err(m)) return #err(m);
          };
        };
        // a range lo-hi, unless '-' is the last character of the class
        switch (peek()) {
          case (?'-') {
            if (pos + 1 < n and chars[pos + 1] != ']') {
              pos += 1;
              let ?h = take() else return #err("Rx: unterminated range");
              var hi = Char.toNat32(h);
              if (h == '\\') {
                let ?e = take() else return #err("Rx: dangling escape in class");
                switch (escape(e)) { case (#ok(#literal(l))) hi := Char.toNat32(l); case (_) return #err("Rx: bad range end") };
              };
              if (hi < lo) return #err("Rx: range out of order");
              List.add(ranges, (lo, hi));
            } else { List.add(ranges, (lo, lo)) };
          };
          case (_) List.add(ranges, (lo, lo));
        };
      };
      #ok(#class_({ ranges = sortRanges(List.toArray(ranges)); negated }))
    };

    func parseQuantifier() : Result.Result<(Nat, ?Nat), Text> {
      switch (peek()) {
        case (?'{') {
          pos += 1;
          var a = 0; var sawA = false;
          label da loop { switch (peek()) { case (?c) { if (Char.isDigit(c)) { a := a * 10 + Nat32.toNat(Char.toNat32(c) - 48); sawA := true; pos += 1 } else break da }; case null return #err("Rx: unterminated quantifier") } };
          if (not sawA) return #err("Rx: quantifier without a minimum");
          switch (take()) {
            case (?'}') #ok((a, ?a));
            case (?',') {
              var b = 0; var sawB = false;
              label db loop { switch (peek()) { case (?c) { if (Char.isDigit(c)) { b := b * 10 + Nat32.toNat(Char.toNat32(c) - 48); sawB := true; pos += 1 } else break db }; case null return #err("Rx: unterminated quantifier") } };
              switch (take()) { case (?'}') {}; case (_) return #err("Rx: unterminated quantifier") };
              if (sawB) { if (b < a) return #err("Rx: quantifier out of order"); #ok((a, ?b)) } else #ok((a, null))
            };
            case (_) #err("Rx: malformed quantifier");
          }
        };
        case (?'?') { pos += 1; #ok((0, ?1)) };
        case (?'*') { pos += 1; #ok((0, null)) };
        case (?'+') { pos += 1; #ok((1, null)) };
        case (_) #ok((1, ?1));
      }
    };

    // a sequence of branches separated by '|', ending at ')' (in a group) or at the end of the pattern;
    // one branch is the sequence itself, several are one #alt node
    func parseSeq(inGroup : Bool) : Result.Result<[Node], Text> {
      let branches = List.empty<[Node]>();
      var out = List.empty<Node>();
      label items loop {
        let ?c = take() else { if (inGroup) return #err("Rx: unterminated group"); break items };
        let atom : Atom = switch (c) {
          case (')') { if (inGroup) break items else return #err("Rx: stray )") };
          case ('|') { List.add(branches, List.toArray(out)); out := List.empty<Node>(); continue items };
          case ('[') { switch (parseClass()) { case (#ok(a)) a; case (#err(m)) return #err(m) } };
          case ('(') {
            var lookahead = false;
            if (peek() == ?'?') {
              pos += 1;
              switch (take()) {
                case (?':') {};
                case (?'!') lookahead := true;
                case (?'=') return #err("Rx: positive lookahead is not in the subset");
                case (?'<') return #err("Rx: lookbehind is not in the subset");
                case (_) return #err("Rx: malformed group");
              };
            };
            switch (parseSeq(true)) { case (#ok(nodes)) { if (lookahead) #notAhead(nodes) else #group(nodes) }; case (#err(m)) return #err(m) }
          };
          case ('\\') {
            let ?e = take() else return #err("Rx: dangling escape");
            switch (escape(e)) {
              case (#ok(#literal(l))) #literal(l);
              case (#ok(#ranges((rs, neg)))) #class_({ ranges = rs; negated = neg });
              case (#err(m)) return #err(m);
            }
          };
          case ('^') #start;
          case ('$') #end;
          case ('.') return #err("Rx: the any-character atom is not in the subset");
          case ('*' or '+' or '?') return #err("Rx: a quantifier with nothing to quantify");
          case (_) #literal(c);
        };
        switch (parseQuantifier()) {
          case (#ok((mn, mx))) {
            switch (atom) { case (#start or #end or #notAhead(_)) { if (mn != 1 or mx != ?1) return #err("Rx: a zero-width atom cannot be quantified") }; case (_) {} };
            List.add(out, { atom; min = mn; max = mx })
          };
          case (#err(m)) return #err(m);
        };
      };
      if (List.isEmpty(branches)) return #ok(List.toArray(out));
      List.add(branches, List.toArray(out));
      #ok([{ atom = #alt(List.toArray(branches)); min = 1; max = ?1 }])
    };

    parseSeq(false)
  };

  func inRanges(ranges : [(Nat32, Nat32)], v : Nat32) : Bool {
    // binary search: the property tables are hundreds of ranges
    var lo = 0; var hi = ranges.size();
    while (lo < hi) {
      let mid = (lo + hi) / 2;
      let (a, b) = ranges[mid];
      if (v < a) hi := mid else if (v > b) lo := mid + 1 else return true;
    };
    false
  };

  /// Whether the whole text matches: every schema pattern is implicitly anchored at both ends.
  public func matches(p : Pattern, text : Text) : Bool {
    let cs = Iter.toArray(text.chars());
    // match nodes[i..] against cs[pos..], then the continuation
    func matchNodes(nodes : [Node], i : Nat, pos : Nat, k : Nat -> Bool) : Bool {
      if (i == nodes.size()) return k(pos);
      let node = nodes[i];
      // one occurrence of the atom at pos, then the rest of this node's count
      func one(pos : Nat, k2 : Nat -> Bool) : Bool {
        switch (node.atom) {
          case (#literal(c)) { if (pos < cs.size() and cs[pos] == c) k2(pos + 1) else false };
          case (#class_(cl)) { if (pos < cs.size() and inRanges(cl.ranges, Char.toNat32(cs[pos])) != cl.negated) k2(pos + 1) else false };
          case (#group(inner)) matchNodes(inner, 0, pos, k2);
          case (#alt(branches)) { for (b in branches.vals()) { if (matchNodes(b, 0, pos, k2)) return true }; false };
          case (#notAhead(inner)) { if (matchNodes(inner, 0, pos, func(_ : Nat) : Bool { true })) false else k2(pos) };
          case (#start) { if (pos == 0) k2(pos) else false };
          case (#end) { if (pos == cs.size()) k2(pos) else false };
        }
      };
      func rep(count : Nat, pos : Nat) : Bool {
        // greedy: try one more occurrence first, then stop if the minimum is met
        let canMore = switch (node.max) { case (?m) count < m; case null true };
        if (canMore and one(pos, func(p2 : Nat) : Bool { if (p2 == pos and count >= node.min) false else rep(count + 1, p2) })) return true;
        if (count >= node.min) matchNodes(nodes, i + 1, pos, k) else false
      };
      rep(0, pos)
    };
    matchNodes(p, 0, 0, func(end : Nat) : Bool { end == cs.size() })
  };

  /// Compile and match in one step; a pattern outside the subset is `null`, never a match.
  public func test(pattern : Text, text : Text) : ?Bool {
    switch (compile(pattern)) { case (#ok(p)) ?matches(p, text); case (#err(_)) null }
  };

}
