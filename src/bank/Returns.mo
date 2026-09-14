/// Returns.mo; regulatory returns as mapped data and declared arithmetic.
///
/// A return is a mapping from the chart of accounts to return lines, plus arithmetic over
/// the mapped figures. Two properties make the difference between a return a regulator can
/// rely on and one it cannot, and both are enforced here rather than documented:
///
///   1. **Every account falls in at most one line.** A chart account mapped twice is
///      refused at registration, naming both lines. A template that can double-count is
///      not a template.
///   2. **Accounts mapped to no line are reported with their balances, and a return whose
///      unmapped total is non-zero is flagged on its face.** A regulator receiving that is
///      being told the truth; a regulator receiving a return whose residual was swept into
///      "other assets" is not. This is the same discipline the audit product's leadsheet
///      mapping already carries, and it is the decision most likely to matter in an
///      inspection.
///
/// No prudential opinion is formed anywhere. Risk weights, haircuts and run-off factors are
/// declared parameters on the template, recorded in a block; the engine multiplies and
/// sums. A ratio's behaviour when its denominator is zero is declared too, because a
/// capital ratio computed on no capital is a number somebody will otherwise invent.

import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Map "mo:core/Map";
import Result "mo:core/Result";
import Sha256 "mo:sha2/Sha256";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";
import JC "mo:journal/Canonical";

import RT "ReportTypes";
import Reports "Reports";

module {

  type Template = RT.ReturnTemplate;

  // ═══════════════════════════════════════════════════════════
  //  VALIDATION: THE TWO PROPERTIES, CHECKED
  // ═══════════════════════════════════════════════════════════

  /// Every line a template refers to, by code.
  func lineCodes(t : Template) : Map.Map<Text, RT.ReturnLine> {
    let m = Map.empty<Text, RT.ReturnLine>();
    for (l in t.lines.vals()) { Map.add(m, Text.compare, l.code, l) };
    m
  };

  /// Which line claims an account, so "mapped at most once" is a check and not a hope.
  /// A range and an explicit account list are both claims, and they are compared in the
  /// same space: the four-digit prefix.
  ///
  /// A claim is keyed by **(measure, account)** and not by the account alone, because the two
  /// readings of one account are different figures: a return that shows customer deposits as a
  /// closing credit on one line and the period's movement on another is not double-counting
  /// anything, and a rule that forbade it would forbid a shape every regulator asks for. What
  /// the rule catches is the real error; the same figure of the same account reaching two
  /// lines, which is what makes a total wrong.
  public func claimsOf(t : Template) : Result.Result<Map.Map<Text, Text>, RT.ReportError> {
    let claimed = Map.empty<Text, Text>();      // (measure, account or prefix) -> line code
    func claim(measure : RT.Measure, who : Text, line : Text) : ?RT.ReportError {
      let key = measureTag(measure) # "|" # who;
      switch (Map.get(claimed, Text.compare, key)) {
        case (?first) ?#AccountMappedTwice({ account = who; first; second = line });
        case null { Map.add(claimed, Text.compare, key, line); null };
      }
    };
    // Ranges first, so an explicit account code can then be checked against every range that
    // exists. A line naming account 1001 and a line summing the range 1000–1999 both count
    // that account, and the clash is only visible once both kinds of claim are in one space.
    for (l in t.lines.vals()) {
      switch (l.source) {
        case (#sumOfRanges(s)) {
          for (r in s.ranges.vals()) {
            if (r.lo > r.hi) return #err(#InvalidTemplate({ reason = "line " # l.code # " has a range whose low prefix exceeds its high prefix" }));
            var p = r.lo;
            while (p <= r.hi) {
              switch (claim(s.measure, "#" # Nat.toText(p), l.code)) { case (?e) return #err(e); case null {} };
              p += 1;
            };
          };
        };
        case (_) {};
      };
    };
    for (l in t.lines.vals()) {
      switch (l.source) {
        case (#sumOfAccounts(s)) {
          for (a in s.accounts.vals()) {
            // the account's own prefix, against the ranges already claimed
            let prefixKey = measureTag(s.measure) # "|#" # Nat.toText(Reports.accountPrefix(a));
            switch (Map.get(claimed, Text.compare, prefixKey)) {
              case (?first) {
                if (not Text.equal(first, l.code)) {
                  return #err(#AccountMappedTwice({ account = a; first; second = l.code }));
                };
              };
              case null {};
            };
            // and the exact code, against the other lists
            switch (claim(s.measure, a, l.code)) { case (?e) return #err(e); case null {} };
          };
        };
        case (_) {};     // a derived line claims no account
      };
    };
    #ok(claimed)
  };

  /// A short tag per measure, used to key a claim. Distinct per measure and stable, because
  /// the claim map is what the double-mapping rule is decided on.
  public func measureTag(m : RT.Measure) : Text {
    switch (m) {
      case (#periodDebits) "pd";
      case (#periodCredits) "pc";
      case (#closingDebits) "cd";
      case (#closingCredits) "cc";
      case (#netMovement) "nm";
      case (#closingBalance) "cb";
      case (#entryCount) "ec";
      case (#balanceAsOf(d)) "ba" # Nat.toText(d);
      case (#valueDatedBalance(d)) "vd" # Nat.toText(d);
    }
  };

  /// Is this account claimed by any line, under any measure? An account claimed by none is
  /// unmapped and is reported with its balance.
  func isClaimed(claimed : Map.Map<Text, Text>, account : JT.AccountCode, prefix : Nat) : Bool {
    for ((k, _) in Map.entries(claimed)) {
      let suffix = "|" # account;
      let prefixSuffix = "|#" # Nat.toText(prefix);
      if (Text.endsWith(k, #text suffix) or Text.endsWith(k, #text prefixSuffix)) return true;
    };
    false
  };

  public func validate(t : Template) : ?RT.ReportError {
    if (Text.encodeUtf8(t.id).size() == 0) return ?#InvalidTemplate({ reason = "a template states its identifier" });
    if (Text.encodeUtf8(t.title).size() == 0) return ?#InvalidTemplate({ reason = "a template states its title" });
    if (Text.encodeUtf8(t.authority).size() == 0) return ?#InvalidTemplate({ reason = "a template names the authority it is filed with" });
    if (t.lines.size() == 0 or t.lines.size() > RT.MAX_RETURN_LINES) {
      return ?#InvalidTemplate({ reason = "a template has between 1 and " # Nat.toText(RT.MAX_RETURN_LINES) # " lines" });
    };
    let codes = lineCodes(t);
    if (Map.size(codes) != t.lines.size()) return ?#InvalidTemplate({ reason = "two lines share a code" });
    for (l in t.lines.vals()) {
      if (Text.encodeUtf8(l.code).size() == 0) return ?#InvalidTemplate({ reason = "a line states its code" });
      if (Text.encodeUtf8(l.caption).size() == 0) return ?#InvalidTemplate({ reason = "line " # l.code # " states its caption" });
      // every line a derived line refers to must exist
      switch (l.source) {
        case (#sumOfLines(s)) {
          if (s.lines.size() == 0) return ?#InvalidTemplate({ reason = "line " # l.code # " sums no lines" });
          for (x in s.lines.vals()) { if (Map.get(codes, Text.compare, x) == null) return ?#UnknownLine({ line = x }) };
        };
        case (#difference(d)) {
          if (Map.get(codes, Text.compare, d.minuend) == null) return ?#UnknownLine({ line = d.minuend });
          if (Map.get(codes, Text.compare, d.subtrahend) == null) return ?#UnknownLine({ line = d.subtrahend });
        };
        case (#ratio(r)) {
          if (Map.get(codes, Text.compare, r.numerator) == null) return ?#UnknownLine({ line = r.numerator });
          if (Map.get(codes, Text.compare, r.denominator) == null) return ?#UnknownLine({ line = r.denominator });
          if (r.scale == 0) return ?#InvalidTemplate({ reason = "line " # l.code # " is a ratio with a zero scale" });
        };
        case (#weighted(x)) {
          if (Map.get(codes, Text.compare, x.line) == null) return ?#UnknownLine({ line = x.line });
          if (x.denominator == 0) return ?#InvalidTemplate({ reason = "line " # l.code # " has a weight with a zero denominator" });
        };
        case (#sumOfAccounts(s)) { if (s.accounts.size() == 0) return ?#InvalidTemplate({ reason = "line " # l.code # " sums no accounts" }) };
        case (#sumOfRanges(s)) { if (s.ranges.size() == 0) return ?#InvalidTemplate({ reason = "line " # l.code # " sums no ranges" }) };
        case (#declared(_)) {};
      };
    };
    // no line may depend on itself, directly or through other lines: a return with a
    // circular definition has no value at all, and finding out by trapping is not an option
    switch (orderOf(t)) { case (#err(e)) return ?e; case (#ok(_)) {} };
    switch (claimsOf(t)) { case (#err(e)) return ?e; case (#ok(_)) {} };
    null
  };

  /// The order the lines must be evaluated in, by topological sort over the references.
  /// Returns `#CircularLine` naming a line in the cycle.
  public func orderOf(t : Template) : Result.Result<[Text], RT.ReportError> {
    let deps = Map.empty<Text, [Text]>();
    for (l in t.lines.vals()) {
      let d = switch (l.source) {
        case (#sumOfLines(s)) s.lines;
        case (#difference(x)) [x.minuend, x.subtrahend];
        case (#ratio(x)) [x.numerator, x.denominator];
        case (#weighted(x)) [x.line];
        case (_) [];
      };
      Map.add(deps, Text.compare, l.code, d);
    };
    let state = Map.empty<Text, Nat>();      // 0 unvisited, 1 in progress, 2 done
    let out = List.empty<Text>();
    // an explicit stack rather than recursion, so a deep template cannot exhaust anything
    for (l in t.lines.vals()) {
      if (Map.get(state, Text.compare, l.code) == null) {
        let stack = List.empty<(Text, Nat)>();
        List.add(stack, (l.code, 0));
        label walk loop {
          let ?(code, step) = List.removeLast(stack) else break walk;
          if (step == 0) {
            switch (Map.get(state, Text.compare, code)) {
              case (?2) { };
              case (?1) return #err(#CircularLine({ line = code }));
              case (_) {
                Map.add(state, Text.compare, code, 1);
                List.add(stack, (code, 1));
                let ds = switch (Map.get(deps, Text.compare, code)) { case (?x) x; case null [] };
                for (d in ds.vals()) {
                  switch (Map.get(state, Text.compare, d)) {
                    case (?1) return #err(#CircularLine({ line = d }));
                    case (?2) {};
                    case (_) List.add(stack, (d, 0));
                  };
                };
              };
            };
          } else {
            Map.add(state, Text.compare, code, 2);
            List.add(out, code);
          };
        };
      };
    };
    #ok(List.toArray(out))
  };

  // ═══════════════════════════════════════════════════════════
  //  THE TEMPLATE'S CANONICAL BYTES
  // ═══════════════════════════════════════════════════════════

  public func templateBytes(t : Template) : Blob {
    let w = JC.Writer();
    w.text("thebes.bank.return.template.v1");
    w.text(t.id);
    w.nat(t.version);
    w.text(t.title);
    w.text(t.authority);
    w.text(t.currency);
    switch (t.taxonomy) { case null w.byte(0); case (?x) { w.byte(1); w.text(x) } };
    w.nat(t.parameters.size());
    for (p in t.parameters.vals()) { w.text(p.name); w.nat(p.numerator); w.nat(p.denominator) };
    w.nat(t.lines.size());
    for (l in t.lines.vals()) {
      w.text(l.code);
      w.text(l.caption);
      switch (l.binding) { case null w.byte(0); case (?b) { w.byte(1); w.text(b) } };
      switch (l.source) {
        case (#sumOfAccounts(s)) {
          w.byte(0x01); w.nat(s.accounts.size());
          for (a in s.accounts.vals()) w.text(a);
          wMeasure(w, s.measure);
        };
        case (#sumOfRanges(s)) {
          w.byte(0x02); w.nat(s.ranges.size());
          for (r in s.ranges.vals()) { w.nat(r.lo); w.nat(r.hi) };
          wMeasure(w, s.measure);
        };
        case (#sumOfLines(s)) { w.byte(0x03); w.nat(s.lines.size()); for (x in s.lines.vals()) w.text(x) };
        case (#difference(d)) { w.byte(0x04); w.text(d.minuend); w.text(d.subtrahend) };
        case (#ratio(r)) {
          w.byte(0x05); w.text(r.numerator); w.text(r.denominator); w.nat(r.scale);
          w.byte(switch (r.whenZero) { case (#reportZero) 0; case (#reportUnmeasurable) 1; case (#refuse) 2 });
        };
        case (#weighted(x)) { w.byte(0x06); w.text(x.line); w.nat(x.numerator); w.nat(x.denominator) };
        case (#declared(d)) { w.byte(0x07); if (d.value < 0) { w.byte(1); w.nat(Int.abs(d.value)) } else { w.byte(0); w.nat(Int.abs(d.value)) } };
      };
    };
    Blob.fromArray(w.toArray())
  };

  func wMeasure(w : JC.Writer, m : RT.Measure) {
    switch (m) {
      case (#periodDebits) w.byte(0x11);
      case (#periodCredits) w.byte(0x12);
      case (#closingDebits) w.byte(0x13);
      case (#closingCredits) w.byte(0x14);
      case (#netMovement) w.byte(0x15);
      case (#closingBalance) w.byte(0x16);
      case (#entryCount) w.byte(0x17);
      case (#balanceAsOf(d)) { w.byte(0x18); w.nat(d) };
      case (#valueDatedBalance(d)) { w.byte(0x19); w.nat(d) };
    };
  };

  public func templateHash(t : Template) : Blob { Sha256.fromBlob(#sha256, templateBytes(t)) };

  // ═══════════════════════════════════════════════════════════
  //  EVALUATION
  // ═══════════════════════════════════════════════════════════

  /// Evaluate a template over a period. Every figure is a fold over the trial balance at
  /// the stated height; the unmapped section is built in the same pass, so it cannot be
  /// forgotten or suppressed.
  public func evaluate(
    js : JCore.State,
    t : Template,
    book : RT.BookId,
    period : JT.PeriodId,
  ) : Result.Result<RT.ReturnResult, RT.ReportError> {
    switch (validate(t)) { case (?e) return #err(e); case null {} };
    let ?tb = JCore.trialBalance(js, period) else return #err(#UnknownPeriod({ period }));
    let claimed = switch (claimsOf(t)) { case (#err(e)) return #err(e); case (#ok(m)) m };
    let order = switch (orderOf(t)) { case (#err(e)) return #err(e); case (#ok(o)) o };
    let codes = lineCodes(t);

    func sign(account : JT.AccountCode) : Int {
      switch (JCore.getAccount(js, account)) {
        case (?a) { switch (a.normalSide) { case (#debit) 1; case (#credit) -1 } };
        case null 1;
      }
    };
    func measureOf(m : RT.Measure, r : JT.TrialBalanceRow) : Int {
      switch (m) {
        case (#periodDebits) r.periodDebits;
        case (#periodCredits) r.periodCredits;
        case (#closingDebits) r.closingDebits;
        case (#closingCredits) r.closingCredits;
        case (#netMovement) sign(r.account) * (r.periodDebits - r.periodCredits : Int);
        case (#closingBalance) sign(r.account) * (r.closingDebits - r.closingCredits : Int);
        case (#entryCount) 0;
        case (#balanceAsOf(d)) {
          let b = JCore.balanceAsOf(js, r.account, null, r.currency, d);
          sign(r.account) * (b.debits - b.credits : Int)
        };
        case (#valueDatedBalance(d)) {
          let b = JCore.valueDatedBalance(js, r.account, null, r.currency, d);
          sign(r.account) * (b.debits - b.credits : Int)
        };
      }
    };

    // the rows of the return's own currency, which is the currency it is filed in
    let rows = List.empty<JT.TrialBalanceRow>();
    for (r in tb.rows.vals()) { if (Text.equal(r.currency, t.currency)) List.add(rows, r) };

    let values = Map.empty<Text, Int>();
    let measurable = Map.empty<Text, Bool>();
    for (code in order.vals()) {
      let ?l = Map.get(codes, Text.compare, code) else return #err(#UnknownLine({ line = code }));
      var amount : Int = 0;
      var ok = true;
      switch (l.source) {
        case (#sumOfAccounts(s)) {
          for (r in List.values(rows)) {
            for (a in s.accounts.vals()) { if (Text.equal(a, r.account)) amount += measureOf(s.measure, r) };
          };
        };
        case (#sumOfRanges(s)) {
          for (r in List.values(rows)) {
            let p = Reports.accountPrefix(r.account);
            for (g in s.ranges.vals()) { if (p >= g.lo and p <= g.hi) amount += measureOf(s.measure, r) };
          };
        };
        case (#sumOfLines(s)) {
          for (x in s.lines.vals()) {
            amount += switch (Map.get(values, Text.compare, x)) { case (?v) v; case null 0 };
            switch (Map.get(measurable, Text.compare, x)) { case (?false) ok := false; case (_) {} };
          };
        };
        case (#difference(d)) {
          let a = switch (Map.get(values, Text.compare, d.minuend)) { case (?v) v; case null 0 };
          let b = switch (Map.get(values, Text.compare, d.subtrahend)) { case (?v) v; case null 0 };
          amount := a - b;
        };
        case (#ratio(r)) {
          let n = switch (Map.get(values, Text.compare, r.numerator)) { case (?v) v; case null 0 };
          let d = switch (Map.get(values, Text.compare, r.denominator)) { case (?v) v; case null 0 };
          if (d == 0) {
            switch (r.whenZero) {
              case (#reportZero) { amount := 0 };
              case (#reportUnmeasurable) { amount := 0; ok := false };
              case (#refuse) return #err(#ZeroDenominator({ line = code }));
            };
          } else {
            // the declared scale makes a ratio an integer: a scale of 10,000 reports basis
            // points, which is how a capital ratio is filed
            let neg = (n < 0) != (d < 0);
            let an = Int.abs(n) * r.scale;
            let ad = Int.abs(d);
            let q = (an * 2 + ad) / (ad * 2);
            amount := if (neg) -q else q;
          };
        };
        case (#weighted(x)) {
          let v = switch (Map.get(values, Text.compare, x.line)) { case (?y) y; case null 0 };
          let neg = v < 0;
          let a = Int.abs(v);
          let q = (a * x.numerator * 2 + x.denominator) / (x.denominator * 2);
          amount := if (neg) -q else q;
          switch (Map.get(measurable, Text.compare, x.line)) { case (?false) ok := false; case (_) {} };
        };
        case (#declared(d)) { amount := d.value };
      };
      Map.add(values, Text.compare, code, amount);
      Map.add(measurable, Text.compare, code, ok);
    };

    // the unmapped section, built in the same pass over the same rows
    let unmapped = List.empty<{ account : JT.AccountCode; currency : JT.Currency; amount : Int }>();
    var unmappedTotal : Int = 0;
    for (r in List.values(rows)) {
      if (not isClaimed(claimed, r.account, Reports.accountPrefix(r.account))) {
        let amount = sign(r.account) * (r.closingDebits - r.closingCredits : Int);
        if (amount != 0 or r.periodDebits != 0 or r.periodCredits != 0) {
          List.add(unmapped, { account = r.account; currency = r.currency; amount });
          unmappedTotal += amount;
        };
      };
    };

    let out = Array.map<RT.ReturnLine, RT.ReturnValue>(t.lines, func(l) {
      {
        code = l.code; caption = l.caption;
        amount = switch (Map.get(values, Text.compare, l.code)) { case (?v) v; case null 0 };
        measurable = switch (Map.get(measurable, Text.compare, l.code)) { case (?b) b; case null true };
        binding = l.binding;
      }
    });
    let result : RT.ReturnResult = {
      template = t.id; version = t.version; templateHash = templateHash(t);
      book; period; currency = t.currency;
      values = out;
      unmapped = List.toArray(unmapped);
      unmappedTotal;
      flagged = unmappedTotal != 0;
      atHeight = JCore.height(js);
      contentHash = "";
    };
    #ok({ result with contentHash = resultHash(result) })
  };

  public func resultBytes(r : RT.ReturnResult) : Blob {
    let w = JC.Writer();
    w.text("thebes.bank.return.result.v1");
    w.text(r.template);
    w.nat(r.version);
    w.blob(r.templateHash);
    w.text(r.book);
    w.text(r.period);
    w.text(r.currency);
    w.nat(r.atHeight);
    w.nat(r.values.size());
    for (v in r.values.vals()) {
      w.text(v.code);
      w.text(v.caption);
      if (v.amount < 0) { w.byte(1); w.nat(Int.abs(v.amount)) } else { w.byte(0); w.nat(Int.abs(v.amount)) };
      w.byte(if (v.measurable) 1 else 0);
      switch (v.binding) { case null w.byte(0); case (?b) { w.byte(1); w.text(b) } };
    };
    w.nat(r.unmapped.size());
    for (u in r.unmapped.vals()) {
      w.text(u.account); w.text(u.currency);
      if (u.amount < 0) { w.byte(1); w.nat(Int.abs(u.amount)) } else { w.byte(0); w.nat(Int.abs(u.amount)) };
    };
    if (r.unmappedTotal < 0) { w.byte(1); w.nat(Int.abs(r.unmappedTotal)) } else { w.byte(0); w.nat(Int.abs(r.unmappedTotal)) };
    w.byte(if (r.flagged) 1 else 0);
    Blob.fromArray(w.toArray())
  };

  public func resultHash(r : RT.ReturnResult) : Blob { Sha256.fromBlob(#sha256, resultBytes(r)) };
};
