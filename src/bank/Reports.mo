/// Reports.mo; the report engine and the primary statements.
///
/// Everything here **reads**. Nothing in this module posts, and nothing in it stores a
/// figure: a report is a fold over the journal at a stated height, so a back-dated posting
/// needs no recalculation anywhere for a report to be right about the height it names.
///
/// The engine has no expression surface. A definition names row dimensions from a fixed
/// set, filters from three fixed operators and measures from a fixed set of folds the
/// journal already computes, and the evaluator is a loop over the trial balance. There is
/// nothing to evaluate but arithmetic.

import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Int "mo:core/Int";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";
import List "mo:core/List";
import Map "mo:core/Map";
import Order "mo:core/Order";
import Result "mo:core/Result";
import Sha256 "mo:sha2/Sha256";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";
import JC "mo:journal/Canonical";

import RT "ReportTypes";

module {

  type Def = RT.ReportDef;

  // ═══════════════════════════════════════════════════════════
  //  WHERE A ROW COMES FROM
  // ═══════════════════════════════════════════════════════════

  public type Source = { #chart; #subledger };

  /// Which source a dimension can be answered from. `#account` and `#currency` are
  /// available on both, so they do not decide.
  public func sourceOfDimension(d : RT.Dimension) : ?Source {
    switch (d) {
      case (#account) null;
      case (#currency) null;
      case (#accountRange(_)) ?#chart;
      case (#leadsheet) ?#chart;
      case (#category) ?#chart;
      case (#book) ?#subledger;
      case (#product) ?#subledger;
      case (#counterpartyClass(_)) ?#subledger;
    }
  };

  /// The source a definition reads from, or an error naming the two dimensions that cannot
  /// be answered together. A definition with no deciding dimension reads the chart, which
  /// is the cheaper and more exact of the two.
  public func sourceOf(def : Def) : Result.Result<Source, RT.ReportError> {
    var decided : ?Source = null;
    var decidedBy = "";
    for (d in def.rows.vals()) {
      switch (sourceOfDimension(d)) {
        case null {};
        case (?s) {
          switch (decided) {
            case null { decided := ?s; decidedBy := dimensionName(d) };
            case (?have) {
              if (have != s) {
                return #err(#MixedRowSources({
                  reason = "`" # decidedBy # "` is a chart dimension and `" # dimensionName(d)
                    # "` is a sub-ledger dimension; one report cannot be keyed by both, "
                    # "because a posting carries a sub-ledger key and not a branch";
                }));
              };
            };
          };
        };
      };
    };
    switch (decided) { case (?s) #ok(s); case null #ok(#chart) }
  };

  public func dimensionName(d : RT.Dimension) : Text {
    switch (d) {
      case (#account) "account";
      case (#accountRange(r)) "accountRange " # Nat.toText(r.lo) # "-" # Nat.toText(r.hi);
      case (#leadsheet) "leadsheet";
      case (#category) "category";
      case (#currency) "currency";
      case (#book) "book";
      case (#product) "product";
      case (#counterpartyClass(c)) "counterpartyClass " # c.schema # "." # c.field;
    }
  };

  public func measureName(m : RT.Measure) : Text {
    switch (m) {
      case (#periodDebits) "periodDebits";
      case (#periodCredits) "periodCredits";
      case (#closingDebits) "closingDebits";
      case (#closingCredits) "closingCredits";
      case (#netMovement) "netMovement";
      case (#closingBalance) "closingBalance";
      case (#entryCount) "entryCount";
      case (#balanceAsOf(d)) "balanceAsOf " # Nat.toText(d);
      case (#valueDatedBalance(d)) "valueDatedBalance " # Nat.toText(d);
    }
  };

  /// A measure that needs a per-account read rather than a trial-balance column. Sizing
  /// counts these separately, because they are the ones whose cost grows with the journal
  /// rather than with the chart.
  public func measureReadsPostings(m : RT.Measure) : Bool {
    switch (m) {
      case (#entryCount) true;
      case (#balanceAsOf(_)) true;
      case (#valueDatedBalance(_)) true;
      case (_) false;
    }
  };

  // ═══════════════════════════════════════════════════════════
  //  VALIDATION
  // ═══════════════════════════════════════════════════════════

  public func validateDef(def : Def) : ?RT.ReportError {
    if (Text.encodeUtf8(def.id).size() == 0 or Text.encodeUtf8(def.id).size() > RT.MAX_DEF_ID_BYTES) {
      return ?#InvalidDefinition({ reason = "the identifier is empty or longer than " # Nat.toText(RT.MAX_DEF_ID_BYTES) # " bytes" });
    };
    if (Text.encodeUtf8(def.title).size() == 0) {
      return ?#InvalidDefinition({ reason = "a definition states its title" });
    };
    if (def.rows.size() == 0 or def.rows.size() > RT.MAX_DIMENSIONS) {
      return ?#InvalidDefinition({ reason = "a report is keyed by between 1 and " # Nat.toText(RT.MAX_DIMENSIONS) # " dimensions" });
    };
    if (def.measures.size() == 0 or def.measures.size() > RT.MAX_MEASURES) {
      return ?#InvalidDefinition({ reason = "a report has between 1 and " # Nat.toText(RT.MAX_MEASURES) # " measures" });
    };
    if (def.filters.size() > RT.MAX_FILTERS) {
      return ?#InvalidDefinition({ reason = "at most " # Nat.toText(RT.MAX_FILTERS) # " filters" });
    };
    if (def.maxSlice == 0 or def.maxSlice > RT.MAX_SLICE) {
      return ?#InvalidDefinition({ reason = "the declared slice bound is between 1 and " # Nat.toText(RT.MAX_SLICE) });
    };
    // no dimension twice: a row keyed by the same thing twice is a row key with a
    // redundant component, and the ordering would then be ambiguous
    var i = 0;
    while (i < def.rows.size()) {
      var j = i + 1;
      while (j < def.rows.size()) {
        if (Text.equal(dimensionName(def.rows[i]), dimensionName(def.rows[j]))) {
          return ?#InvalidDefinition({ reason = "dimension `" # dimensionName(def.rows[i]) # "` appears twice" });
        };
        j += 1;
      };
      i += 1;
    };
    for (f in def.filters.vals()) {
      switch (f.op) {
        case (#inSet(xs)) {
          if (xs.size() == 0 or xs.size() > RT.MAX_SET_MEMBERS) {
            return ?#InvalidDefinition({ reason = "an `inSet` filter names between 1 and " # Nat.toText(RT.MAX_SET_MEMBERS) # " members" });
          };
        };
        case (#range(r)) {
          if (r.lo > r.hi) return ?#InvalidDefinition({ reason = "a range filter's low bound exceeds its high bound" });
        };
        case (#eq(v)) {
          if (Text.encodeUtf8(v).size() == 0) return ?#InvalidDefinition({ reason = "an `eq` filter compares against something" });
        };
      };
    };
    for (d in def.rows.vals()) {
      switch (d) {
        case (#accountRange(r)) {
          if (r.lo > r.hi) return ?#InvalidDefinition({ reason = "an account range's low prefix exceeds its high prefix" });
        };
        case (#counterpartyClass(c)) {
          if (Text.encodeUtf8(c.schema).size() == 0 or Text.encodeUtf8(c.field).size() == 0) {
            return ?#InvalidDefinition({ reason = "a counterparty class names a schema and a field" });
          };
        };
        case (_) {};
      };
    };
    switch (def.ordering) {
      case (#byMeasureDescending(k)) {
        if (k >= def.measures.size()) {
          return ?#InvalidDefinition({ reason = "the ordering names measure " # Nat.toText(k) # " and there are " # Nat.toText(def.measures.size()) });
        };
      };
      case (_) {};
    };
    switch (sourceOf(def)) { case (#err(e)) return ?e; case (#ok(_)) {} };
    null
  };

  // ═══════════════════════════════════════════════════════════
  //  THE DEFINITION'S CANONICAL BYTES AND HASH
  // ═══════════════════════════════════════════════════════════

  func wDimension(w : JC.Writer, d : RT.Dimension) {
    switch (d) {
      case (#account) w.byte(0x01);
      case (#accountRange(r)) { w.byte(0x02); w.nat(r.lo); w.nat(r.hi) };
      case (#leadsheet) w.byte(0x03);
      case (#category) w.byte(0x04);
      case (#currency) w.byte(0x05);
      case (#book) w.byte(0x06);
      case (#product) w.byte(0x07);
      case (#counterpartyClass(c)) { w.byte(0x08); w.text(c.schema); w.text(c.field) };
    };
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

  func wScale(w : JC.Writer, s : RT.Scale) {
    w.byte(switch (s) { case (#minorUnits) 0; case (#units) 1; case (#thousands) 2; case (#millions) 3 });
  };

  /// The canonical bytes of a definition. This is what the report triple's first component
  /// hashes, so "report R34 version 2" names exact arithmetic and changing the arithmetic
  /// means a new version with the old one still evaluable.
  public func defBytes(def : Def) : Blob {
    let w = JC.Writer();
    w.text("thebes.bank.report.def.v1");
    w.text(def.id);
    w.nat(def.version);
    w.text(def.title);
    w.nat(def.rows.size());
    for (d in def.rows.vals()) wDimension(w, d);
    w.nat(def.filters.size());
    for (f in def.filters.vals()) {
      wDimension(w, f.dimension);
      switch (f.op) {
        case (#eq(v)) { w.byte(0x21); w.text(v) };
        case (#inSet(xs)) { w.byte(0x22); w.nat(xs.size()); for (x in xs.vals()) w.text(x) };
        case (#range(r)) { w.byte(0x23); w.nat(r.lo); w.nat(r.hi) };
      };
    };
    w.nat(def.measures.size());
    for (m in def.measures.vals()) wMeasure(w, m);
    switch (def.ordering) {
      case (#byRowKey) w.byte(0x31);
      case (#byCategoryThenAccount) w.byte(0x32);
      case (#byMeasureDescending(k)) { w.byte(0x33); w.nat(k) };
    };
    wScale(w, def.scale);
    w.byte(switch (def.comparatives) { case (#none) 0; case (#priorPeriod) 1; case (#priorYear) 2 });
    w.nat(def.maxSlice);
    Blob.fromArray(w.toArray())
  };

  public func defHash(def : Def) : Blob { Sha256.fromBlob(#sha256, defBytes(def)) };

  // ═══════════════════════════════════════════════════════════
  //  EVALUATION
  // ═══════════════════════════════════════════════════════════

  /// What the caller supplies so the engine need not know about the bank's own state: the
  /// leadsheet of an account, the book and product of a sub-ledger, a party's declared
  /// class, and the accounts of the chart. Passing these in is what keeps this module a
  /// fold with no dependencies on the layers above it.
  public type Context = {
    /// The leadsheet an account's four-digit prefix falls in, or null when it falls in
    /// none; which is reported, never bucketed.
    leadsheetOf : AccountCode -> ?Text;
    /// One row per product account: its account code, currency, book, product and
    /// declared counterparty class, with the figures already folded.
    subledgerRows : () -> [SubledgerRow];
  };

  public type AccountCode = JT.AccountCode;

  public type SubledgerRow = {
    account : AccountCode;
    currency : JT.Currency;
    book : Text;
    product : Text;
    /// The declared class for the dimension the definition named, or null.
    class_ : ?Text;
    periodDebits : Nat;
    periodCredits : Nat;
    closingDebits : Nat;
    closingCredits : Nat;
    entryCount : Nat;
    balanceAsOf : Nat -> { debits : Nat; credits : Nat };
    valueDated : Nat -> { debits : Nat; credits : Nat };
  };

  /// The size of the slice a definition would read, computed **before** evaluating. A
  /// definition whose slice exceeds its declared bound is refused naming the size, rather
  /// than trapping halfway through.
  public func sliceSize(js : JCore.State, def : Def, params : RT.ReportParams, ctx : Context) : Result.Result<Nat, RT.ReportError> {
    let ?tb = JCore.trialBalance(js, params.period) else return #err(#UnknownPeriod({ period = params.period }));
    switch (sourceOf(def)) {
      case (#err(e)) #err(e);
      case (#ok(#chart)) {
        var n = 0;
        for (r in tb.rows.vals()) { if (passesChart(def, r, ctx, js)) n += 1 };
        // a measure that reads postings rather than a column multiplies the work by the
        // number of entries in the period
        var perRow = 1;
        for (m in def.measures.vals()) { if (measureReadsPostings(m)) perRow += 1 };
        #ok(n * perRow)
      };
      case (#ok(#subledger)) {
        var n = 0;
        for (r in ctx.subledgerRows().vals()) { if (passesSub(def, r)) n += 1 };
        var perRow = 1;
        for (m in def.measures.vals()) { if (measureReadsPostings(m)) perRow += 1 };
        #ok(n * perRow)
      };
    }
  };

  // ─── filters ───────────────────────────────────────────────────────────────

  func prefixOf(code : AccountCode) : Nat {
    // the leading four digits, which is the granularity leadsheets and return ranges use
    var n = 0;
    var taken = 0;
    for (c in code.chars()) {
      if (taken < 4) {
        let d = Nat32.toNat(Nat32.fromNat(0) + (switch (c) {
          case ('0') 0; case ('1') 1; case ('2') 2; case ('3') 3; case ('4') 4;
          case ('5') 5; case ('6') 6; case ('7') 7; case ('8') 8; case ('9') 9;
          case (_) 10;
        }));
        if (d <= 9) { n := n * 10 + d; taken += 1 };
      };
    };
    var i = taken;
    while (i < 4) { n := n * 10; i += 1 };
    n
  };

  public func accountPrefix(code : AccountCode) : Nat { prefixOf(code) };

  func matches(op : RT.FilterOp, value : Text, numeric : ?Nat) : Bool {
    switch (op) {
      case (#eq(v)) Text.equal(v, value);
      case (#inSet(xs)) {
        var found = false;
        for (x in xs.vals()) { if (Text.equal(x, value)) found := true };
        found
      };
      case (#range(r)) {
        switch (numeric) { case (?n) n >= r.lo and n <= r.hi; case null false }
      };
    }
  };

  func categoryText(c : JT.Category) : Text {
    switch (c) { case (#asset) "asset"; case (#liability) "liability"; case (#equity) "equity"; case (#income) "income"; case (#expense) "expense" }
  };

  func chartValue(d : RT.Dimension, r : JT.TrialBalanceRow, ctx : Context, js : JCore.State) : (Text, ?Nat) {
    switch (d) {
      case (#account) (r.account, ?prefixOf(r.account));
      case (#accountRange(_)) (r.account, ?prefixOf(r.account));
      case (#currency) (r.currency, null);
      case (#leadsheet) { switch (ctx.leadsheetOf(r.account)) { case (?l) (l, null); case null ("unmapped", null) } };
      case (#category) {
        switch (JCore.getAccount(js, r.account)) {
          case (?a) (categoryText(a.category), null);
          case null ("unknown", null);
        }
      };
      case (_) ("", null);      // a sub-ledger dimension never reaches a chart row
    }
  };

  func passesChart(def : Def, r : JT.TrialBalanceRow, ctx : Context, js : JCore.State) : Bool {
    // a row dimension that is a range is itself a filter: a report keyed by a range
    // covers only the accounts inside it
    for (d in def.rows.vals()) {
      switch (d) {
        case (#accountRange(range)) {
          let p = prefixOf(r.account);
          if (p < range.lo or p > range.hi) return false;
        };
        case (_) {};
      };
    };
    for (f in def.filters.vals()) {
      let (value, numeric) = chartValue(f.dimension, r, ctx, js);
      if (not matches(f.op, value, numeric)) return false;
    };
    true
  };

  func subValue(d : RT.Dimension, r : SubledgerRow) : (Text, ?Nat) {
    switch (d) {
      case (#account) (r.account, ?prefixOf(r.account));
      case (#currency) (r.currency, null);
      case (#book) (r.book, null);
      case (#product) (r.product, null);
      case (#counterpartyClass(_)) { switch (r.class_) { case (?c) (c, null); case null ("unclassified", null) } };
      case (_) ("", null);
    }
  };

  func passesSub(def : Def, r : SubledgerRow) : Bool {
    for (f in def.filters.vals()) {
      let (value, numeric) = subValue(f.dimension, r);
      if (not matches(f.op, value, numeric)) return false;
    };
    true
  };

  // ─── measures ──────────────────────────────────────────────────────────────

  func normalSign(js : JCore.State, account : AccountCode) : Int {
    switch (JCore.getAccount(js, account)) {
      case (?a) { switch (a.normalSide) { case (#debit) 1; case (#credit) -1 } };
      case null 1;
    }
  };

  func scaled(amount : Int, scale : RT.Scale) : Int {
    switch (scale) {
      case (#minorUnits) amount;
      case (#units) divRound(amount, 100);
      case (#thousands) divRound(amount, 100_000);
      case (#millions) divRound(amount, 100_000_000);
    }
  };

  /// Half-away-from-zero on the presentation scale, so a scaled report is not silently
  /// biased downwards and a negative figure scales the same way as its positive twin.
  func divRound(amount : Int, by : Int) : Int {
    let neg = amount < 0;
    let a = if (neg) -amount else amount;
    let q = (a * 2 + by) / (by * 2);
    if (neg) -q else q
  };

  func chartMeasure(js : JCore.State, m : RT.Measure, r : JT.TrialBalanceRow, entries : Nat) : Int {
    switch (m) {
      case (#periodDebits) r.periodDebits;
      case (#periodCredits) r.periodCredits;
      case (#closingDebits) r.closingDebits;
      case (#closingCredits) r.closingCredits;
      case (#netMovement) normalSign(js, r.account) * (r.periodDebits - r.periodCredits : Int);
      case (#closingBalance) normalSign(js, r.account) * (r.closingDebits - r.closingCredits : Int);
      case (#entryCount) entries;
      case (#balanceAsOf(d)) {
        let b = JCore.balanceAsOf(js, r.account, null, r.currency, d);
        normalSign(js, r.account) * (b.debits - b.credits : Int)
      };
      case (#valueDatedBalance(d)) {
        let b = JCore.valueDatedBalance(js, r.account, null, r.currency, d);
        normalSign(js, r.account) * (b.debits - b.credits : Int)
      };
    }
  };

  func subMeasure(js : JCore.State, m : RT.Measure, r : SubledgerRow) : Int {
    switch (m) {
      case (#periodDebits) r.periodDebits;
      case (#periodCredits) r.periodCredits;
      case (#closingDebits) r.closingDebits;
      case (#closingCredits) r.closingCredits;
      case (#netMovement) normalSign(js, r.account) * (r.periodDebits - r.periodCredits : Int);
      case (#closingBalance) normalSign(js, r.account) * (r.closingDebits - r.closingCredits : Int);
      case (#entryCount) r.entryCount;
      case (#balanceAsOf(d)) { let b = r.balanceAsOf(d); normalSign(js, r.account) * (b.debits - b.credits : Int) };
      case (#valueDatedBalance(d)) { let b = r.valueDated(d); normalSign(js, r.account) * (b.debits - b.credits : Int) };
    }
  };

  // ─── the evaluation ────────────────────────────────────────────────────────

  func keyText(k : RT.RowKey) : Text { Text.join(k.vals(), "\u{1f}") };

  func compareKeys(a : RT.RowKey, b : RT.RowKey) : Order.Order { Text.compare(keyText(a), keyText(b)) };

  type Acc = { key : RT.RowKey; var cells : [var Int]; var resolved : Bool };

  /// Evaluate a definition. Deterministic in (definition, parameters, journal height): the
  /// rows come out in the declared order, the cells are the declared measures, and the
  /// canonical bytes are hashed into `contentHash`.
  public func evaluate(
    js : JCore.State,
    jb : JCore.Blocks,
    def : Def,
    params : RT.ReportParams,
    ctx : Context,
    bankHeight : Nat,
  ) : Result.Result<RT.Report, RT.ReportError> {
    switch (validateDef(def)) { case (?e) return #err(e); case null {} };
    let slice = switch (sliceSize(js, def, params, ctx)) { case (#err(e)) return #err(e); case (#ok(n)) n };
    if (slice > def.maxSlice) return #err(#SliceTooLarge({ slice; bound = def.maxSlice }));
    let ?tb = JCore.trialBalance(js, params.period) else return #err(#UnknownPeriod({ period = params.period }));
    let source = switch (sourceOf(def)) { case (#err(e)) return #err(e); case (#ok(s)) s };

    // entry counts, only when a measure asks for them
    var wantsEntries = false;
    for (m in def.measures.vals()) { if (m == #entryCount) wantsEntries := true };
    let entryCounts = Map.empty<Text, Nat>();
    if (wantsEntries and source == #chart) {
      switch (JCore.generalLedger(js, jb, params.period, null)) {
        case (?gl) { for (a in gl.accounts.vals()) { Map.add(entryCounts, Text.compare, a.account # "|" # a.currency, a.entries.size()) } };
        case null {};
      };
    };

    let rows = Map.empty<Text, Acc>();
    let order = List.empty<RT.RowKey>();
    func bump(key : RT.RowKey, resolved : Bool, cell : Nat -> Int) {
      let k = keyText(key);
      let acc = switch (Map.get(rows, Text.compare, k)) {
        case (?a) a;
        case null {
          let a : Acc = { key; var cells = VarArray.tabulate<Int>(def.measures.size(), func(_) { 0 }); var resolved };
          Map.add(rows, Text.compare, k, a);
          List.add(order, key);
          a
        };
      };
      if (not resolved) acc.resolved := false;
      var i = 0;
      while (i < def.measures.size()) {
        acc.cells[i] := acc.cells[i] + cell(i);
        i += 1;
      };
    };

    switch (source) {
      case (#chart) {
        for (r in tb.rows.vals()) {
          if (passesChart(def, r, ctx, js)) {
            let key = List.empty<Text>();
            var resolved = true;
            for (d in def.rows.vals()) {
              let (v, _) = chartValue(d, r, ctx, js);
              if (Text.equal(v, "unmapped") or Text.equal(v, "unknown")) resolved := false;
              List.add(key, v);
            };
            let entries = switch (Map.get(entryCounts, Text.compare, r.account # "|" # r.currency)) { case (?n) n; case null 0 };
            bump(List.toArray(key), resolved, func(i) { chartMeasure(js, def.measures[i], r, entries) });
          };
        };
      };
      case (#subledger) {
        for (r in ctx.subledgerRows().vals()) {
          if (passesSub(def, r)) {
            let key = List.empty<Text>();
            var resolved = true;
            for (d in def.rows.vals()) {
              let (v, _) = subValue(d, r);
              if (Text.equal(v, "unclassified")) resolved := false;
              List.add(key, v);
            };
            bump(List.toArray(key), resolved, func(i) { subMeasure(js, def.measures[i], r) });
          };
        };
      };
    };

    if (Map.size(rows) > RT.MAX_REPORT_ROWS) {
      return #err(#SliceTooLarge({ slice = Map.size(rows); bound = RT.MAX_REPORT_ROWS }));
    };

    // order the keys as declared
    let keys = List.toArray(order);
    let sorted = switch (def.ordering) {
      case (#byRowKey) Array.sort<RT.RowKey>(keys, compareKeys);
      case (#byCategoryThenAccount) Array.sort<RT.RowKey>(keys, compareKeys);
      case (#byMeasureDescending(k)) {
        Array.sort<RT.RowKey>(keys, func(a, b) {
          let av = switch (Map.get(rows, Text.compare, keyText(a))) { case (?x) x.cells[k]; case null 0 };
          let bv = switch (Map.get(rows, Text.compare, keyText(b))) { case (?x) x.cells[k]; case null 0 };
          if (av > bv) #less else if (av < bv) #greater else compareKeys(a, b)
        })
      };
    };

    let out = List.empty<RT.ReportRow>();
    let unresolved = List.empty<RT.ReportRow>();
    let totals = VarArray.tabulate<Int>(def.measures.size(), func(_) { 0 });
    for (key in sorted.vals()) {
      let ?acc = Map.get(rows, Text.compare, keyText(key)) else return #err(#InvalidDefinition({ reason = "a row vanished between folding and ordering" }));
      let cells = Array.tabulate<RT.Cell>(def.measures.size(), func(i) {
        { measure = def.measures[i]; amount = scaled(acc.cells[i], def.scale); currency = null }
      });
      var i = 0;
      while (i < def.measures.size()) { totals[i] := totals[i] + acc.cells[i]; i += 1 };
      let row : RT.ReportRow = { key; cells; comparative = null };
      if (acc.resolved) List.add(out, row) else List.add(unresolved, row);
    };

    let totalCells = Array.tabulate<RT.Cell>(def.measures.size(), func(i) {
      { measure = def.measures[i]; amount = scaled(totals[i], def.scale); currency = null }
    });
    let report : RT.Report = {
      definition = def.id;
      version = def.version;
      definitionHash = defHash(def);
      params;
      atHeight = JCore.height(js);
      atBankHeight = bankHeight;
      rows = List.toArray(out);
      totals = [{ currency = null; cells = totalCells }];
      unresolved = List.toArray(unresolved);
      contentHash = "";
      rowCount = List.size(out) + List.size(unresolved);
      sliceSize = slice;
    };
    #ok({ report with contentHash = reportHash(report) })
  };

  // ═══════════════════════════════════════════════════════════
  //  THE REPORT'S CANONICAL BYTES
  // ═══════════════════════════════════════════════════════════

  func wInt(w : JC.Writer, x : Int) {
    if (x < 0) { w.byte(1); w.nat(Int.abs(x)) } else { w.byte(0); w.nat(Int.abs(x)) };
  };

  func wCells(w : JC.Writer, cells : [RT.Cell]) {
    w.nat(cells.size());
    for (c in cells.vals()) {
      wMeasure(w, c.measure);
      wInt(w, c.amount);
      switch (c.currency) { case null w.byte(0); case (?x) { w.byte(1); w.text(x) } };
    };
  };

  func wRows(w : JC.Writer, rows : [RT.ReportRow]) {
    w.nat(rows.size());
    for (r in rows.vals()) {
      w.nat(r.key.size());
      for (k in r.key.vals()) w.text(k);
      wCells(w, r.cells);
      switch (r.comparative) { case null w.byte(0); case (?c) { w.byte(1); wCells(w, c) } };
    };
  };

  /// The bytes that are hashed into the certified tree. They cover the report's identity
  ///the definition hash, the parameters and **both** heights; and every row, so an
  /// artefact that leaves the building can be proven to be the report the books produced.
  public func reportBytes(r : RT.Report) : Blob {
    let w = JC.Writer();
    w.text("thebes.bank.report.v1");
    w.text(r.definition);
    w.nat(r.version);
    w.blob(r.definitionHash);
    w.text(r.params.book);
    w.text(r.params.period);
    w.byte(switch (r.params.view) { case (#native) 0; case (#functional) 1 });
    switch (r.params.functional) { case null w.byte(0); case (?c) { w.byte(1); w.text(c) } };
    w.nat(r.atHeight);
    // `atBankHeight` is deliberately **not** hashed. A report's identity is (definition hash,
    // parameters, journal height), and the definition hash already pins the arithmetic that
    // was in force. Hashing the bank height as well would mean the same report over the same
    // journal hashed differently because something unrelated happened in the bank; so the
    // triple would no longer be the identity, and "recompute it and compare" would stop
    // working. It stays on the record as context: which registration a reader was looking at.
    wRows(w, r.rows);
    wRows(w, r.unresolved);
    w.nat(r.totals.size());
    for (t in r.totals.vals()) {
      switch (t.currency) { case null w.byte(0); case (?x) { w.byte(1); w.text(x) } };
      wCells(w, t.cells);
    };
    Blob.fromArray(w.toArray())
  };

  public func reportHash(r : RT.Report) : Blob { Sha256.fromBlob(#sha256, reportBytes(r)) };

  /// A small writer for the hashes the reporting layer folds over its own state. It is the
  /// journal's canonical writer with a digest on the end, so every hash in this layer is
  /// built by the same length-prefixed encoder as every block in the estate.
  public func certifiedRootWriter() : { text : Text -> (); nat : Nat -> (); blob : Blob -> (); byte : Nat8 -> (); digest : () -> Blob } {
    let w = JC.Writer();
    {
      text = func(t : Text) { w.text(t) };
      nat = func(n : Nat) { w.nat(n) };
      blob = func(b : Blob) { w.blob(b) };
      byte = func(b : Nat8) { w.byte(b) };
      digest = func() : Blob { Sha256.fromBlob(#sha256, Blob.fromArray(w.toArray())) };
    }
  };

  // ═══════════════════════════════════════════════════════════
  //  THE PRIMARY STATEMENTS
  // ═══════════════════════════════════════════════════════════
  //
  // Each is a fold over the same trial balance the report engine reads, grouped by the
  // category the chart declares. Two of them assert an identity rather than presenting a
  // total: a balance sheet that does not balance and a cash-flow statement that does not
  // reconcile are **refused**, because a statement whose total does not add up is worse
  // than no statement.

  /// The exchange rate to translate one currency into the functional currency, as an exact
  /// ratio. Supplied by the caller because the rates are the close layer's recorded data,
  /// not this module's.
  public type RateFn = (JT.Currency, JT.Day) -> ?{ numerator : Nat; denominator : Nat };

  func rowsOf(js : JCore.State, tb : JT.TrialBalance, want : JT.Category, ccy : JT.Currency) : [JT.TrialBalanceRow] {
    let out = List.empty<JT.TrialBalanceRow>();
    for (r in tb.rows.vals()) {
      if (Text.equal(r.currency, ccy)) {
        switch (JCore.getAccount(js, r.account)) {
          case (?a) { if (a.category == want) List.add(out, r) };
          case null {};
        };
      };
    };
    List.toArray(out)
  };

  func lineFor(js : JCore.State, r : JT.TrialBalanceRow, closing : Bool) : RT.StatementLine {
    let name = switch (JCore.getAccount(js, r.account)) { case (?a) a.name; case null r.account };
    let amount = if (closing) normalSign(js, r.account) * (r.closingDebits - r.closingCredits : Int)
                 else normalSign(js, r.account) * (r.periodDebits - r.periodCredits : Int);
    { caption = r.account # " " # name; accounts = [r.account]; amount; comparative = null }
  };

  func sumLines(lines : [RT.StatementLine]) : Int {
    var t : Int = 0;
    for (l in lines.vals()) t += l.amount;
    t
  };

  /// The income statement for a period, with its result reconciled against the movement in
  /// retained earnings. A statement that cannot reconcile its own result says so on its
  /// face rather than presenting a figure nobody can tie out.
  public func incomeStatement(
    js : JCore.State,
    book : RT.BookId,
    period : JT.PeriodId,
    ccy : JT.Currency,
    map : RT.StatementMap,
    bankHeight : Nat,
  ) : Result.Result<RT.IncomeStatement, RT.ReportError> {
    ignore bankHeight;
    let ?tb = JCore.trialBalance(js, period) else return #err(#UnknownPeriod({ period }));
    let income = Array.map<JT.TrialBalanceRow, RT.StatementLine>(
      rowsOf(js, tb, #income, ccy), func(r) { lineFor(js, r, false) });
    let expense = Array.map<JT.TrialBalanceRow, RT.StatementLine>(
      rowsOf(js, tb, #expense, ccy), func(r) { lineFor(js, r, false) });
    let totalIncome = sumLines(income);
    let totalExpense = sumLines(expense);
    // income accounts are credit-normal, so their normal-side movement is positive when
    // income is earned; the result is income less expense in that orientation
    let result = totalIncome - totalExpense;
    // the same figure from the other side: the movement in retained earnings for the
    // period, which the year-end roll is what moves
    var reMovement : ?Int = null;
    for (r in tb.rows.vals()) {
      if (Text.equal(r.account, map.retainedEarnings) and Text.equal(r.currency, ccy)) {
        reMovement := ?(normalSign(js, r.account) * (r.periodDebits - r.periodCredits : Int));
      };
    };
    let reconciles = switch (reMovement) {
      case null true;                 // nothing rolled in this period, so nothing to tie to
      case (?m) m == 0 or m == result;
    };
    #ok({
      book; period; currency = ccy; view = #native;
      income; expense; totalIncome; totalExpense; result;
      retainedEarningsMovement = reMovement; reconciles;
      atHeight = JCore.height(js);
    })
  };

  /// The identity a balance sheet must satisfy, as a function of four figures.
  ///
  /// It is exported so it can be tested against a deliberately unbalanced input. The journal
  /// enforces debits = credits per currency at admission, so a balance sheet built from it
  /// cannot fail this; which means the only way to prove the refusal works is to call the
  /// check with figures that do not add up. A check nobody can see fail is a check nobody
  /// should trust.
  public func balanceSheetIdentity(assets : Int, liabilities : Int, equity : Int, result : Int) : Bool {
    assets == liabilities + equity + result
  };

  /// The same for the cash-flow statement: opening cash plus the net movement is closing cash.
  public func cashFlowIdentity(openingCash : Int, netMovement : Int, closingCash : Int) : Bool {
    openingCash + netMovement == closingCash
  };

  /// The balance sheet, with `assets = liabilities + equity + result` **asserted**. The
  /// period's result is carried as its own line until the year-end roll moves it, because
  /// a balance sheet that quietly folded an unrolled result into equity would balance for
  /// the wrong reason.
  public func balanceSheet(
    js : JCore.State,
    book : RT.BookId,
    period : JT.PeriodId,
    ccy : JT.Currency,
    bankHeight : Nat,
  ) : Result.Result<RT.BalanceSheet, RT.ReportError> {
    ignore bankHeight;
    let ?tb = JCore.trialBalance(js, period) else return #err(#UnknownPeriod({ period }));
    let assets = Array.map<JT.TrialBalanceRow, RT.StatementLine>(
      rowsOf(js, tb, #asset, ccy), func(r) { lineFor(js, r, true) });
    let liabilities = Array.map<JT.TrialBalanceRow, RT.StatementLine>(
      rowsOf(js, tb, #liability, ccy), func(r) { lineFor(js, r, true) });
    let equity = Array.map<JT.TrialBalanceRow, RT.StatementLine>(
      rowsOf(js, tb, #equity, ccy), func(r) { lineFor(js, r, true) });
    let totalAssets = sumLines(assets);
    let totalLiabilities = sumLines(liabilities);
    let totalEquity = sumLines(equity);
    // the cumulative result: income less expense to the end of this period, which is what
    // has not yet been rolled into equity
    var cumIncome : Int = 0;
    var cumExpense : Int = 0;
    for (r in rowsOf(js, tb, #income, ccy).vals()) {
      cumIncome += normalSign(js, r.account) * (r.closingDebits - r.closingCredits : Int);
    };
    for (r in rowsOf(js, tb, #expense, ccy).vals()) {
      cumExpense += normalSign(js, r.account) * (r.closingDebits - r.closingCredits : Int);
    };
    let periodResult = cumIncome - cumExpense;
    let balances = balanceSheetIdentity(totalAssets, totalLiabilities, totalEquity, periodResult);
    if (not balances) {
      return #err(#DoesNotBalance({
        assets = totalAssets; liabilities = totalLiabilities; equity = totalEquity; result = periodResult;
      }));
    };
    #ok({
      book; period; currency = ccy; view = #native;
      assets; liabilities; equity;
      totalAssets; totalLiabilities; totalEquity; periodResult; balances;
      translationDifference = null;
      atHeight = JCore.height(js);
    })
  };

  /// The cash-flow statement, indirect method. Which accounts are cash, investing and
  /// financing is **declared** in the statement map and recorded; nothing is inferred from
  /// an account's name or its code.
  public func cashFlow(
    js : JCore.State,
    book : RT.BookId,
    period : JT.PeriodId,
    ccy : JT.Currency,
    map : RT.StatementMap,
    priorPeriod : ?JT.PeriodId,
  ) : Result.Result<RT.CashFlow, RT.ReportError> {
    let ?tb = JCore.trialBalance(js, period) else return #err(#UnknownPeriod({ period }));
    func isIn(xs : [RT.AccountCode], code : RT.AccountCode) : Bool {
      var found = false;
      for (x in xs.vals()) { if (Text.equal(x, code)) found := true };
      found
    };
    let operating = List.empty<RT.StatementLine>();
    let investing = List.empty<RT.StatementLine>();
    let financing = List.empty<RT.StatementLine>();
    var openingCash : Int = 0;
    var closingCash : Int = 0;
    // The indirect method rests on one identity: over every account of a currency, debits
    // less credits is zero. So the movement in cash is the **negation** of the movement in
    // everything else, and the sections are built from the raw figure rather than from each
    // account's normal-side figure; applying the normal sign would flip it for every
    // credit-normal account and the identity would not hold. A source of cash therefore reads
    // positive: `credits − debits` for a non-cash account, which is also how a cash-flow
    // statement is conventionally presented.
    func sourceLine(r : JT.TrialBalanceRow) : RT.StatementLine {
      let name = switch (JCore.getAccount(js, r.account)) { case (?a) a.name; case null r.account };
      { caption = r.account # " " # name; accounts = [r.account];
        amount = r.periodCredits - r.periodDebits : Int; comparative = null }
    };
    for (r in tb.rows.vals()) {
      if (Text.equal(r.currency, ccy)) {
        if (isIn(map.cash, r.account)) {
          // cash itself: the raw figure, so an overdrawn cash account reads negative rather
          // than being turned positive by a normal side somebody declared
          closingCash += r.closingDebits - r.closingCredits : Int;
          openingCash += (r.closingDebits - r.periodDebits : Int) - (r.closingCredits - r.periodCredits : Int);
        } else if (isIn(map.investing, r.account)) {
          List.add(investing, sourceLine(r));
        } else if (isIn(map.financing, r.account)) {
          List.add(financing, sourceLine(r));
        } else {
          List.add(operating, sourceLine(r));
        };
      };
    };
    ignore priorPeriod;
    let totalOperating = sumLines(List.toArray(operating));
    let totalInvesting = sumLines(List.toArray(investing));
    let totalFinancing = sumLines(List.toArray(financing));
    let netMovement = totalOperating + totalInvesting + totalFinancing;
    // Asserted, not presented: an indirect cash-flow statement that does not tie to the cash
    // accounts is wrong, and this one refuses rather than printing it.
    let reconciles = cashFlowIdentity(openingCash, netMovement, closingCash);
    if (not reconciles) {
      return #err(#DoesNotReconcile({ stated = closingCash; computed = openingCash + netMovement }));
    };
    #ok({
      book; period; currency = ccy;
      operating = List.toArray(operating);
      investing = List.toArray(investing);
      financing = List.toArray(financing);
      totalOperating; totalInvesting; totalFinancing;
      netMovement; openingCash; closingCash; reconciles;
      atHeight = JCore.height(js);
    })
  };

  // ═══════════════════════════════════════════════════════════
  //  IAS 21 TRANSLATION, WHICH POSTS NOTHING
  // ═══════════════════════════════════════════════════════════

  /// Translate a balance sheet into the functional currency for **presentation only**.
  ///
  /// Monetary items translate at the closing rate and non-monetary at the historic rate,
  /// and which is which is the declared `monetary` list rather than a judgement the engine
  /// makes. The difference the two rates produce is reported as **its own line** and is
  /// never absorbed into a total; which is the whole reason this returns a balance sheet
  /// carrying `translationDifference` rather than quietly balanced figures.
  ///
  /// It writes nothing and posts nothing: the journal state is untouched, which the battery
  /// asserts by fingerprint.
  public func translate(
    native : RT.BalanceSheet,
    functional : JT.Currency,
    closingDay : JT.Day,
    historicDay : JT.Day,
    map : RT.StatementMap,
    rateFor : RateFn,
  ) : Result.Result<RT.BalanceSheet, RT.ReportError> {
    if (Text.equal(native.currency, functional)) {
      // nothing to translate: the functional view of the functional currency is itself,
      // and the difference is exactly zero rather than absent
      return #ok({ native with view = #functional; translationDifference = ?0 });
    };
    func isMonetary(code : RT.AccountCode) : Bool {
      var found = false;
      for (x in map.monetary.vals()) { if (Text.equal(x, code)) found := true };
      found
    };
    let closing = switch (rateFor(native.currency, closingDay)) {
      case (?r) r;
      case null return #err(#MissingRate({ currency = native.currency; asOf = closingDay }));
    };
    let historic = switch (rateFor(native.currency, historicDay)) {
      case (?r) r;
      case null return #err(#MissingRate({ currency = native.currency; asOf = historicDay }));
    };
    func at(r : { numerator : Nat; denominator : Nat }, amount : Int) : Int {
      // exact ratio arithmetic, rounded half away from zero once
      let neg = amount < 0;
      let a = Int.abs(amount);
      let q = (a * r.numerator * 2 + r.denominator) / (r.denominator * 2);
      if (neg) -q else q
    };
    func translateLines(ls : [RT.StatementLine]) : [RT.StatementLine] {
      Array.map<RT.StatementLine, RT.StatementLine>(ls, func(l) {
        let rate = if (isMonetary(l.accounts[0])) closing else historic;
        { l with amount = at(rate, l.amount) }
      })
    };
    let assets = translateLines(native.assets);
    let liabilities = translateLines(native.liabilities);
    let equity = translateLines(native.equity);
    let totalAssets = sumLines(assets);
    let totalLiabilities = sumLines(liabilities);
    let totalEquity = sumLines(equity);
    // income and expense translate at the period's rate, which for a presentation
    // translation of the result is the closing rate of the period being presented
    let periodResult = at(closing, native.periodResult);
    // what the two rates did to the identity, shown rather than absorbed
    let difference = totalAssets - (totalLiabilities + totalEquity + periodResult);
    #ok({
      book = native.book; period = native.period; currency = functional; view = #functional;
      assets; liabilities; equity;
      totalAssets; totalLiabilities; totalEquity; periodResult;
      // the identity holds **with** the difference line, which is what IAS 21 presentation
      // means; it is asserted in that form rather than by dropping the residue
      balances = totalAssets == totalLiabilities + totalEquity + periodResult + difference;
      translationDifference = ?difference;
      atHeight = native.atHeight;
    })
  };
};
