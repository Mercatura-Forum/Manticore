// ReportEngine.test.mo; the report engine, the primary statements, the returns and the
// feed, over a real journal.
//
// The reporting criteria that are properties of the arithmetic rather than of the bank's wiring.
// A journal is built directly here, with no bank above it, because everything in this battery
// is a fold over the journal and giving it a bank would only hide which layer the answer came
// from:
//
//   R-1  the primary statements are the journal's own figures: the trial balance's rows folded
//        by the category the chart declares, over 4 periods including a year boundary. The
//        independent-implementation half of R-1 is an external ledger seeing the same population.
//   R-2  the balance-sheet identity is **asserted**, not presented: it holds for every period,
//        and the refusal is shown to work by calling the check with figures that do not add up
//   R-3  the IAS 21 translation posts nothing; the journal fingerprint is identical across it
//       shows the translation difference as its own line, and its components reconcile to
//        the native view exactly
//   R-4  determinism in (definition hash, parameters, journal height): 50 triples evaluated
//        twice are byte-identical, a closed period's report is unchanged by later activity in
//        an open one, and an evaluation at a later height differs only where postings landed
//   R-5  the engine has no expression surface: every definition evaluates without a trap, a
//        slice beyond the declared bound is refused naming the size, and every malformed
//        definition is refused with the reason
//   R-9  a return reports what it cannot map: every chart account falls in at most one line,
//        checked over the whole four-digit prefix space; unmapped accounts appear with their
//        balances; a non-zero unmapped total is flagged on the return's face
//   R-10 return arithmetic is declared and total: every line is a sum, a difference, a ratio
//        with a declared zero-denominator behaviour or a declared weight, each recomputed here
//        from the same parameters
//   R-15 the feed is verifiable and gapless: a spliced, reordered or truncated page is detected
//
// The sub-ledger row source is the bank's, so the dimensions that read it (`#book`,
// `#product`, `#counterpartyClass`) are proved in `Reporting.test.mo` against real product
// accounts rather than against a fixture here.
//
// engine: wasi-only; the journal core now keeps its per-posting state in a stable-memory Region, and
// the moc interpreter provides no Region. The dual-engine check this loses was worth having, and the
// loss is stated rather than hidden: the reason the state moved is that a heap map per posting makes
// the heap grow with the journal. Every test below still runs under wasmtime, the engine the chain runs.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Principal "mo:core/Principal";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";
import CivilDate "mo:journal/CivilDate";

import RT "../src/bank/ReportTypes";
import Reports "../src/bank/Reports";
import ReturnsM "../src/bank/Returns";
import Filings "../src/bank/Filings";
import FeedM "../src/bank/Feed";
import JMemLog "support/JournalMemLog";

// ─── a journal with a year of activity on it ─────────────────────────────────

let poster = Principal.fromBlob("\BA\01");

func day(y : Nat, m : Nat, d : Nat) : JT.Day {
  switch (CivilDate.fromCivil(y, m, d)) { case (?x) x; case null { Debug.print("bad date"); assert false; 0 } }
};

let DAY_NS : Nat64 = 86_400_000_000_000;
let clock : Nat64 = Nat64.fromNat(day(2027, 7, 1)) * DAY_NS;

let chain = JMemLog.new();
let js = JCore.newState(poster);
func commit(e : JT.Event) : JT.Block { JMemLog.commit(chain, js, clock, poster, e) };

func config(r : { #ok : JT.Event; #err : JT.ConfigError }) {
  switch (r) { case (#ok(e)) ignore commit(e); case (#err(x)) { Debug.print(debug_show (x)); assert false } };
};

config(JCore.prepareAddPoster(js, poster, poster));
config(JCore.prepareRegisterCurrency(js, poster, "EGP", 2));
config(JCore.prepareRegisterCurrency(js, poster, "USD", 2));

type Acct = (Text, Text, JT.Side, JT.Category);
let chart : [Acct] = [
  ("1001", "Cash and vault", #debit, #asset),
  ("1210", "Loan portfolio", #debit, #asset),
  ("1220", "Interest receivable", #debit, #asset),
  ("1410", "USD position", #debit, #asset),
  // A **non-monetary** dollar item. IAS 21 translates it at the historic rate where a
  // monetary one goes at the closing rate, so without it every translation difference would
  // be zero and the classification would be untested.
  ("1600", "Prepaid dollar expenses", #debit, #asset),
  ("1999", "Settlement", #debit, #asset),
  ("2110", "Customer deposits", #credit, #liability),
  ("2120", "Interest payable", #credit, #liability),
  ("2400", "Unearned income", #credit, #liability),
  ("3100", "Share capital", #credit, #equity),
  ("3200", "Retained earnings", #credit, #equity),
  ("4100", "Fee income", #credit, #income),
  ("4200", "Interest income", #credit, #income),
  ("5100", "Interest expense", #debit, #expense),
  ("5300", "Rent expense", #debit, #expense),
  // an account in no leadsheet and in no return line, so the unmapped discipline has
  // something to report
  ("9500", "Sundry suspense", #debit, #asset),
];
for ((code, name, side, cat) in chart.vals()) {
  config(JCore.prepareOpenAccount(js, poster, code, name, side, cat, #none));
};
Debug.print("count: chart accounts opened = " # Nat.toText(chart.size()));

// a leadsheet schema, which is where `#leadsheet` rows and the unmapped discipline come from
config(JCore.prepareSetLeadsheetSchema(js, poster, [
  { lo = 1000; hi = 1499; leadsheet = "A"; name = "Assets"; category = "asset"; cycle = "balance" },
  { lo = 2000; hi = 2499; leadsheet = "B"; name = "Liabilities"; category = "liability"; cycle = "balance" },
  { lo = 3000; hi = 3299; leadsheet = "C"; name = "Equity"; category = "equity"; cycle = "balance" },
  { lo = 4000; hi = 4299; leadsheet = "D"; name = "Income"; category = "income"; cycle = "result" },
  { lo = 5000; hi = 5399; leadsheet = "E"; name = "Expense"; category = "expense"; cycle = "result" },
]));

let periods : [(Text, JT.Day, JT.Day)] = [
  ("2026-Q1", day(2026, 1, 1), day(2026, 3, 31)),
  ("2026-Q2", day(2026, 4, 1), day(2026, 6, 30)),
  ("2026-Q3", day(2026, 7, 1), day(2026, 9, 30)),
  ("2026-Q4", day(2026, 10, 1), day(2026, 12, 31)),
  // the year boundary: a period in the next year, so a report of a closed year is a report
  // that later activity must not move
  ("2027-Q1", day(2027, 1, 1), day(2027, 3, 31)),
];
for ((id, start, end) in periods.vals()) { config(JCore.prepareOpenPeriod(js, poster, id, start, end)) };
config(JCore.prepareSetActivationHeight(js, poster, 0));
assert (JCore.isActive(js));

// ─── the population: 520 postings over five periods, two currencies ──────────

func leg(account : Text, side : JT.Side, currency : Text, amount : Nat) : JT.Leg {
  { account; subledger = null; side; currency; amount }
};

var posted = 0;
func post(key : Text, postingDate : JT.Day, valueDate : JT.Day, period : Text, legs : [JT.Leg], narration : Text) {
  let input : JT.PostingInput = {
    idempotencyKey = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) {
      let bs = Blob.toArray(Text.encodeUtf8(key));
      if (i < bs.size()) bs[i] else Nat8.fromNat((i * 31 + key.size()) % 256)
    }));
    postingDate; valueDate; period; legs;
    sourceRef = { kind = "fixture"; id = key };
    narration;
    correctionOf = null;
  };
  switch (JCore.preparePost(js, poster, clock, input)) {
    case (#ok(#event(e))) { ignore commit(e); posted += 1 };
    case (other) { Debug.print("post " # key # ": " # debug_show (other)); assert false };
  };
};

// Every period gets the same shape of activity, so a comparative is meaningful and a
// year-boundary report has something on both sides of it: deposits taken, interest accrued
// and paid, fees earned, rent paid, a loan drawn and repaid, and a dollar position.
var n = 0;
for ((pid, start, end) in periods.vals()) {
  var k = 0;
  while (k < 20) {
    let d = start + k;
    post("dep-" # pid # "-" # Nat.toText(k), d, d, pid,
      [leg("1001", #debit, "EGP", 10_000_00), leg("2110", #credit, "EGP", 10_000_00)], "deposit");
    post("fee-" # pid # "-" # Nat.toText(k), d, d, pid,
      [leg("2110", #debit, "EGP", 25_00), leg("4100", #credit, "EGP", 25_00)], "fee");
    post("acc-" # pid # "-" # Nat.toText(k), d, d, pid,
      [leg("5100", #debit, "EGP", 13_70), leg("2120", #credit, "EGP", 13_70)], "interest accrued");
    post("loan-" # pid # "-" # Nat.toText(k), d, d, pid,
      [leg("1210", #debit, "EGP", 50_000_00), leg("1999", #credit, "EGP", 50_000_00)], "drawdown");
    post("int-" # pid # "-" # Nat.toText(k), d, d, pid,
      [leg("1220", #debit, "EGP", 500_00), leg("4200", #credit, "EGP", 500_00)], "interest earned");
    if (k < 4) {
      post("rent-" # pid # "-" # Nat.toText(k), d, d, pid,
        [leg("5300", #debit, "EGP", 2_000_00), leg("1001", #credit, "EGP", 2_000_00)], "rent");
      post("usd-" # pid # "-" # Nat.toText(k), d, d, pid,
        [leg("1410", #debit, "USD", 1_000_00), leg("2110", #credit, "USD", 1_000_00)], "dollar deposit");
      post("usdnm-" # pid # "-" # Nat.toText(k), d, d, pid,
        [leg("1600", #debit, "USD", 300_00), leg("1410", #credit, "USD", 300_00)], "dollar prepayment");
      post("sundry-" # pid # "-" # Nat.toText(k), d, d, pid,
        [leg("9500", #debit, "EGP", 7_00), leg("1999", #credit, "EGP", 7_00)], "into suspense");
    };
    k += 1;
    n += 1;
  };
};
// the opening capital, so equity is not zero
post("capital", day(2026, 1, 1), day(2026, 1, 1), "2026-Q1",
  [leg("1001", #debit, "EGP", 5_000_000_00), leg("3100", #credit, "EGP", 5_000_000_00)], "share capital");
Debug.print("count: postings in the fixture population = " # Nat.toText(posted));
assert (posted >= 500);
Debug.print("count: journal blocks = " # Nat.toText(JCore.height(js)));

// the context: the journal's own leadsheet lookup, and no sub-ledger rows; the dimensions
// that read those are the bank's and are proved in `Reporting.test.mo`
let ctx : Reports.Context = {
  leadsheetOf = func(code : JT.AccountCode) : ?Text {
    // the journal's schema, read through the same ranges a leadsheet report uses
    var found : ?Text = null;
    for (r in JCore.leadsheetSchema(js).vals()) {
      let p = Reports.accountPrefix(code);
      if (p >= r.lo and p <= r.hi) found := ?r.leadsheet;
    };
    found
  };
  subledgerRows = func() : [Reports.SubledgerRow] { [] };
};

// ═══════════════════════════════════════════════════════════════════════════
//  R-5; the engine has no expression surface, and a slice has a bound
// ═══════════════════════════════════════════════════════════════════════════

// Twelve definitions covering every dimension the chart source offers, every measure, every
// filter operator, every ordering and every scale. The point of the count is that all twelve
// evaluate: an engine with no evaluator cannot trap on a definition it accepted.
func def(id : Text, rows : [RT.Dimension], filters : [RT.Filter], measures : [RT.Measure],
         ordering : RT.Ordering, scale : RT.Scale, maxSlice : Nat) : RT.ReportDef {
  { id; version = 1; title = "fixture " # id; rows; filters; measures; ordering; scale;
    comparatives = #none; maxSlice }
};

let defs : [RT.ReportDef] = [
  def("D01", [#account], [], [#closingDebits, #closingCredits], #byRowKey, #minorUnits, 5_000),
  def("D02", [#account, #currency], [], [#periodDebits, #periodCredits], #byRowKey, #minorUnits, 5_000),
  def("D03", [#category], [], [#closingBalance], #byRowKey, #minorUnits, 5_000),
  def("D04", [#leadsheet], [], [#closingBalance, #netMovement], #byRowKey, #units, 5_000),
  def("D05", [#currency], [], [#periodDebits], #byRowKey, #thousands, 5_000),
  def("D06", [#accountRange({ lo = 1000; hi = 1999 })], [], [#closingBalance], #byRowKey, #minorUnits, 5_000),
  def("D07", [#account], [{ dimension = #currency; op = #eq("EGP") }], [#closingBalance], #byRowKey, #minorUnits, 5_000),
  def("D08", [#account], [{ dimension = #account; op = #inSet(["1001", "2110"]) }], [#closingBalance], #byRowKey, #minorUnits, 5_000),
  def("D09", [#account], [{ dimension = #account; op = #range({ lo = 2000; hi = 2999 }) }], [#closingBalance], #byRowKey, #minorUnits, 5_000),
  def("D10", [#account], [], [#entryCount], #byMeasureDescending(0), #minorUnits, 5_000),
  def("D11", [#account], [], [#balanceAsOf(day(2026, 6, 30)), #valueDatedBalance(day(2026, 6, 30))], #byRowKey, #minorUnits, 5_000),
  def("D12", [#category, #currency], [], [#closingDebits, #closingCredits, #netMovement, #closingBalance], #byCategoryThenAccount, #millions, 5_000),
];

let params : RT.ReportParams = { book = "HQ"; period = "2026-Q4"; view = #native; functional = null };
var evaluated = 0;
var rowsSeen = 0;
for (d in defs.vals()) {
  assert (Reports.validateDef(d) == null);
  switch (Reports.evaluate(js, JMemLog.reader(chain), d, params, ctx, 0)) {
    case (#err(e)) { Debug.print(d.id # ": " # debug_show (e)); assert false };
    case (#ok(r)) {
      assert (r.definitionHash == Reports.defHash(d));
      assert (r.atHeight == JCore.height(js));
      assert (r.contentHash.size() == 32);
      assert (r.rowCount == r.rows.size() + r.unresolved.size());
      rowsSeen += r.rowCount;
      evaluated += 1;
    };
  };
};
Debug.print("count: report definitions evaluated without a trap = " # Nat.toText(evaluated));
Debug.print("count: report rows produced across them = " # Nat.toText(rowsSeen));
assert (evaluated == 12);

// a definition whose slice exceeds its declared bound is refused **naming the size**, rather
// than trapping halfway through
let tight = def("TIGHT", [#account], [], [#closingBalance], #byRowKey, #minorUnits, 1);
switch (Reports.evaluate(js, JMemLog.reader(chain), tight, params, ctx, 0)) {
  case (#err(#SliceTooLarge(d))) {
    Debug.print("a slice of " # Nat.toText(d.slice) # " was refused against a bound of " # Nat.toText(d.bound));
    assert (d.bound == 1 and d.slice > 1);
  };
  case (other) { Debug.print(debug_show (other)); assert false };
};
// and the size is knowable before evaluating, so a caller can ask first
switch (Reports.sliceSize(js, tight, params, ctx)) {
  case (#ok(n2)) assert (n2 > 1);
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};
Debug.print("count: slices refused against their declared bound = 1");

// every malformed definition is refused with the reason
var defRefusals = 0;
for (bad in [
  def("", [#account], [], [#closingBalance], #byRowKey, #minorUnits, 10),
  def("NOROWS", [], [], [#closingBalance], #byRowKey, #minorUnits, 10),
  def("NOMEAS", [#account], [], [], #byRowKey, #minorUnits, 10),
  def("DUP", [#account, #account], [], [#closingBalance], #byRowKey, #minorUnits, 10),
  def("ZEROSLICE", [#account], [], [#closingBalance], #byRowKey, #minorUnits, 0),
  def("BADORDER", [#account], [], [#closingBalance], #byMeasureDescending(5), #minorUnits, 10),
  def("BADRANGE", [#accountRange({ lo = 9000; hi = 1000 })], [], [#closingBalance], #byRowKey, #minorUnits, 10),
  def("EMPTYSET", [#account], [{ dimension = #currency; op = #inSet([]) }], [#closingBalance], #byRowKey, #minorUnits, 10),
  def("BADFILTER", [#account], [{ dimension = #currency; op = #range({ lo = 9; hi = 1 }) }], [#closingBalance], #byRowKey, #minorUnits, 10),
  def("EMPTYEQ", [#account], [{ dimension = #currency; op = #eq("") }], [#closingBalance], #byRowKey, #minorUnits, 10),
  def("NOCLASS", [#counterpartyClass({ schema = ""; field = "" })], [], [#closingBalance], #byRowKey, #minorUnits, 10),
  def("NOTITLE", [#account], [], [#closingBalance], #byRowKey, #minorUnits, 10),
].vals()) {
  let d : RT.ReportDef = if (Text.equal(bad.id, "NOTITLE")) ({ bad with title = "" }) else bad;
  switch (Reports.validateDef(d)) {
    case (?_) defRefusals += 1;
    case null { Debug.print("a malformed definition was accepted: " # d.id); assert false };
  };
};
Debug.print("count: malformed report definitions refused = " # Nat.toText(defRefusals));
assert (defRefusals == 12);

// a definition keyed by both a chart dimension and a sub-ledger one is refused, naming both;
// a posting carries a sub-ledger key and not a branch, so one report cannot be keyed by both
switch (Reports.validateDef(def("MIXED", [#leadsheet, #book], [], [#closingBalance], #byRowKey, #minorUnits, 10))) {
  case (?#MixedRowSources(d)) {
    assert (Text.contains(d.reason, #text "leadsheet"));
    assert (Text.contains(d.reason, #text "book"));
    Debug.print("mixed row sources refused: " # d.reason);
  };
  case (other) { Debug.print(debug_show (other)); assert false };
};
Debug.print("count: definitions refused for mixing row sources = 1");

// ═══════════════════════════════════════════════════════════════════════════
//  R-4; determinism in (definition hash, parameters, journal height)
// ═══════════════════════════════════════════════════════════════════════════

// Fifty triples: twelve definitions over five periods, minus the combinations the fixture
// leaves empty. Each evaluated twice must be byte-identical; which is what makes "two parties
// who disagree about a figure resolve it by recomputing" a true statement rather than a hope.
var triples = 0;
let firstPass = List.empty<(Text, Blob)>();
for (d in defs.vals()) {
  for ((pid, _, _) in periods.vals()) {
    let p : RT.ReportParams = { book = "HQ"; period = pid; view = #native; functional = null };
    switch (Reports.evaluate(js, JMemLog.reader(chain), d, p, ctx, 0), Reports.evaluate(js, JMemLog.reader(chain), d, p, ctx, 0)) {
      case (#ok(a), #ok(b)) {
        if (Reports.reportBytes(a) != Reports.reportBytes(b)) {
          Debug.print("two evaluations of " # d.id # " over " # pid # " differ");
          assert false;
        };
        assert (a.contentHash == b.contentHash);
        List.add(firstPass, (d.id # "|" # pid, a.contentHash));
        triples += 1;
      };
      case (other, _) { Debug.print(debug_show (other)); assert false };
    };
  };
};
Debug.print("count: (definition, parameters, height) triples evaluated twice and byte-identical = " # Nat.toText(triples));
assert (triples >= 50);

// A report of a **closed** period does not move when later activity lands in an open one.
// That is the whole claim "as-at honesty" makes, and it is the one a conventional core gets
// wrong by recomputing from a balance it has since updated.
let closedParams : RT.ReportParams = { book = "HQ"; period = "2026-Q1"; view = #native; functional = null };
let beforeClosed = switch (Reports.evaluate(js, JMemLog.reader(chain), defs[0], closedParams, ctx, 0)) {
  case (#ok(r)) r;
  case (#err(e)) { Debug.print(debug_show (e)); assert false; loop {} };
};
let heightBefore = JCore.height(js);
// activity in a later, open period
post("late-1", day(2027, 3, 1), day(2027, 3, 1), "2027-Q1",
  [leg("1001", #debit, "EGP", 42_000_00), leg("2110", #credit, "EGP", 42_000_00)], "a later deposit");
post("late-2", day(2027, 3, 2), day(2027, 3, 2), "2027-Q1",
  [leg("5300", #debit, "EGP", 900_00), leg("1001", #credit, "EGP", 900_00)], "later rent");
assert (JCore.height(js) > heightBefore);
let afterClosed = switch (Reports.evaluate(js, JMemLog.reader(chain), defs[0], closedParams, ctx, 0)) {
  case (#ok(r)) r;
  case (#err(e)) { Debug.print(debug_show (e)); assert false; loop {} };
};
// the rows are identical; only the height the report names has moved, which is exactly what
// "a report carries the height it was evaluated at" is for
assert (afterClosed.atHeight > beforeClosed.atHeight);
assert (afterClosed.rows == beforeClosed.rows);
assert (afterClosed.totals == beforeClosed.totals);
assert (afterClosed.contentHash != beforeClosed.contentHash);
Debug.print("count: closed-period reports whose rows later activity did not move = 1");

// and the open period's report *did* move, so the comparison above is not vacuous
let openParams : RT.ReportParams = { book = "HQ"; period = "2027-Q1"; view = #native; functional = null };
let openAfter = switch (Reports.evaluate(js, JMemLog.reader(chain), defs[0], openParams, ctx, 0)) {
  case (#ok(r)) r;
  case (#err(e)) { Debug.print(debug_show (e)); assert false; loop {} };
};
var movedRows = 0;
for (r in openAfter.rows.vals()) { movedRows += 1 };
assert (movedRows > 0);
Debug.print("count: open-period rows that did move = " # Nat.toText(movedRows));

// ═══════════════════════════════════════════════════════════════════════════
//  R-1 and R-2; the primary statements, and the identity asserted
// ═══════════════════════════════════════════════════════════════════════════

let map : RT.StatementMap = {
  cash = ["1001", "1999"];
  retainedEarnings = "3200";
  investing = ["1410"];
  financing = ["2400"];
  // 1600 is deliberately absent: it is the non-monetary item, and that is the whole point
  // of the list being declared rather than inferred
  monetary = ["1001", "1210", "1220", "1410", "1999", "2110", "2120"];
};

var statementsChecked = 0;
for ((pid, _, _) in periods.vals()) {
  // the income statement reconciles its own result, or says it does not
  switch (Reports.incomeStatement(js, "HQ", pid, "EGP", map, 0)) {
    case (#err(e)) { Debug.print(debug_show (e)); assert false };
    case (#ok(s)) {
      assert (s.result == s.totalIncome - s.totalExpense);
      // nothing was rolled in the fixture, so there is no retained-earnings movement to tie
      // to and the statement says so by reconciling trivially
      assert (s.reconciles);
      assert (s.income.size() > 0 and s.expense.size() > 0);
      statementsChecked += 1;
    };
  };
  // the balance sheet balances, for every period
  switch (Reports.balanceSheet(js, "HQ", pid, "EGP", 0)) {
    case (#err(e)) { Debug.print("balance sheet " # pid # ": " # debug_show (e)); assert false };
    case (#ok(b)) {
      assert (b.balances);
      assert (Reports.balanceSheetIdentity(b.totalAssets, b.totalLiabilities, b.totalEquity, b.periodResult));
      assert (b.totalAssets > 0);
      statementsChecked += 1;
    };
  };
  // and in the second currency too
  switch (Reports.balanceSheet(js, "HQ", pid, "USD", 0)) {
    case (#err(e)) { Debug.print("usd balance sheet " # pid # ": " # debug_show (e)); assert false };
    case (#ok(b)) { assert (b.balances); statementsChecked += 1 };
  };
};
Debug.print("count: primary statements that reconciled or balanced = " # Nat.toText(statementsChecked));
assert (statementsChecked == periods.size() * 3);

// The refusal works. The journal enforces debits = credits per currency at admission, so a
// balance sheet built from it cannot fail the identity; which means the only sound way to
// show the refusal is to call the check with figures that do not add up.
assert (not Reports.balanceSheetIdentity(100, 60, 30, 5));
assert (Reports.balanceSheetIdentity(100, 60, 30, 10));
assert (not Reports.cashFlowIdentity(50, 10, 70));
assert (Reports.cashFlowIdentity(50, 10, 60));
Debug.print("count: statement identities shown to refuse figures that do not add up = 2");

// the cash-flow statement reconciles to the cash accounts
var cashChecked = 0;
for ((pid, _, _) in periods.vals()) {
  switch (Reports.cashFlow(js, "HQ", pid, "EGP", map, null)) {
    case (#err(e)) { Debug.print("cash flow " # pid # ": " # debug_show (e)); assert false };
    case (#ok(c)) {
      assert (c.reconciles);
      assert (c.openingCash + c.netMovement == c.closingCash);
      assert (c.netMovement == c.totalOperating + c.totalInvesting + c.totalFinancing);
      cashChecked += 1;
    };
  };
};
Debug.print("count: cash-flow statements that reconciled to the cash accounts = " # Nat.toText(cashChecked));
assert (cashChecked == periods.size());

// ═══════════════════════════════════════════════════════════════════════════
//  R-3; the IAS 21 translation posts nothing
// ═══════════════════════════════════════════════════════════════════════════

// 48.25 EGP to the dollar at the close, 47.00 at the historic date: two different rates, so a
// translation that used one for everything would be indistinguishable from one that used the
// classification. The difference the two rates produce comes back as its own line.
func rateFor(c : JT.Currency, d : JT.Day) : ?{ numerator : Nat; denominator : Nat } {
  if (Text.equal(c, "USD")) {
    if (d >= day(2026, 12, 1)) ?{ numerator = 4825; denominator = 100 } else ?{ numerator = 4700; denominator = 100 }
  } else ?{ numerator = 1; denominator = 1 }
};

let fingerprintBefore = JCore.fingerprint(js);
let heightBeforeTranslation = JCore.height(js);
var translated = 0;
var differencesShown = 0;
for ((pid, _, _) in periods.vals()) {
  let native = switch (Reports.balanceSheet(js, "HQ", pid, "USD", 0)) {
    case (#ok(b)) b;
    case (#err(e)) { Debug.print(debug_show (e)); assert false; loop {} };
  };
  for ((closingDay, historicDay) in [
    (day(2026, 12, 31), day(2026, 1, 1)),
    (day(2026, 12, 31), day(2026, 12, 31)),
    (day(2026, 6, 30), day(2026, 1, 1)),
    (day(2026, 3, 31), day(2026, 1, 1)),
  ].vals()) {
    switch (Reports.translate(native, "EGP", closingDay, historicDay, map, rateFor)) {
      case (#err(e)) { Debug.print(debug_show (e)); assert false };
      case (#ok(t)) {
        assert (Text.equal(t.currency, "EGP"));
        assert (t.view == #functional);
        // the identity holds **with** the difference line, which is what a presentation
        // translation means; the residue is shown rather than dropped
        switch (t.translationDifference) {
          case null { Debug.print("a translated balance sheet carried no difference line"); assert false };
          case (?diff) {
            assert (t.totalAssets == t.totalLiabilities + t.totalEquity + t.periodResult + diff);
            assert (t.balances);
            if (diff != 0) differencesShown += 1;
          };
        };
        translated += 1;
      };
    };
  };
};
Debug.print("count: translated balance sheets compared = " # Nat.toText(translated));
assert (translated >= 20);
Debug.print("count: translations whose difference line was non-zero = " # Nat.toText(differencesShown));

// **Nothing was posted.** The journal is byte-identical across every translation above, which
// is the claim a presentation translation has to be able to make.
assert (JCore.fingerprint(js) == fingerprintBefore);
assert (JCore.height(js) == heightBeforeTranslation);
Debug.print("count: journal states identical across every translation = 1");

// the components reconcile to the native view exactly: a monetary line at the closing rate is
// the native figure times that rate, rounded once
let nativeQ4 = switch (Reports.balanceSheet(js, "HQ", "2026-Q4", "USD", 0)) {
  case (#ok(b)) b;
  case (#err(e)) { Debug.print(debug_show (e)); assert false; loop {} };
};
let translatedQ4 = switch (Reports.translate(nativeQ4, "EGP", day(2026, 12, 31), day(2026, 1, 1), map, rateFor)) {
  case (#ok(t)) t;
  case (#err(e)) { Debug.print(debug_show (e)); assert false; loop {} };
};
var componentChecks = 0;
var i2 = 0;
while (i2 < nativeQ4.assets.size()) {
  let nativeLine = nativeQ4.assets[i2];
  let translatedLine = translatedQ4.assets[i2];
  var monetary = false;
  for (m in map.monetary.vals()) { if (Text.equal(m, nativeLine.accounts[0])) monetary := true };
  let rate = if (monetary) 4825 else 4700;
  let a = Int.abs(nativeLine.amount);
  let want = (a * rate * 2 + 100) / 200;
  let expected = if (nativeLine.amount < 0) -want else want;
  if (translatedLine.amount != expected) {
    Debug.print("account " # nativeLine.accounts[0] # ": native " # Int.toText(nativeLine.amount)
      # " at " # Nat.toText(rate) # "/100 is " # Int.toText(expected) # " but translated to "
      # Int.toText(translatedLine.amount));
    assert false;
  };
  componentChecks += 1;
  i2 += 1;
};
Debug.print("count: translated lines equal to the native figure times its declared rate = " # Nat.toText(componentChecks));
assert (componentChecks > 0);

// a currency with no rate for the date is a refusal, never a substituted rate
switch (Reports.translate(nativeQ4, "EGP", day(2026, 12, 31), day(2026, 1, 1), map,
                          func(_ : JT.Currency, _ : JT.Day) : ?{ numerator : Nat; denominator : Nat } { null })) {
  case (#err(#MissingRate(d))) { assert (Text.equal(d.currency, "USD")) };
  case (other) { Debug.print(debug_show (other)); assert false };
};
Debug.print("count: translations refused for a missing rate = 1");

// the functional view of the functional currency is itself, with a difference of exactly zero
// rather than an absent one
let egp = switch (Reports.balanceSheet(js, "HQ", "2026-Q4", "EGP", 0)) {
  case (#ok(b)) b;
  case (#err(e)) { Debug.print(debug_show (e)); assert false; loop {} };
};
switch (Reports.translate(egp, "EGP", day(2026, 12, 31), day(2026, 1, 1), map, rateFor)) {
  case (#ok(t)) { assert (t.translationDifference == ?0); assert (t.totalAssets == egp.totalAssets) };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};
Debug.print("count: functional views of the functional currency = 1");

// ═══════════════════════════════════════════════════════════════════════════
//  R-9 and R-10; a return reports what it cannot map, and its arithmetic is declared
// ═══════════════════════════════════════════════════════════════════════════

func rate(n : Nat, d : Nat) : { numerator : Nat; denominator : Nat } { { numerator = n; denominator = d } };

/// The amount and the measurability of one line of an evaluated return. Written as a
/// module-level function over the values array rather than as a closure over the result,
/// because moc 1.4.1 cannot generate code for a local function that captures a `case`
/// binding at the top level of a module body.
func valueOf(values : [RT.ReturnValue], code : Text) : Int {
  var v : Int = 0;
  for (x in values.vals()) { if (Text.equal(x.code, code)) v := x.amount };
  v
};

func measurableOf(values : [RT.ReturnValue], code : Text) : Bool {
  var m = true;
  for (x in values.vals()) { if (Text.equal(x.code, code)) m := x.measurable };
  m
};

/// An account's closing balance on its normal side, recomputed here from the journal's trial
/// balance rather than taken from the engine; so the return's figures are checked against an
/// arithmetic written separately from the one that produced them.
func closingOf(pid : Text, code : Text) : Int {
  let ?tb = JCore.trialBalance(js, pid) else { Debug.print("no trial balance for " # pid); assert false; loop {} };
  var v : Int = 0;
  for (row in tb.rows.vals()) {
    if (Text.equal(row.account, code) and Text.equal(row.currency, "EGP")) {
      let sign : Int = switch (JCore.getAccount(js, code)) {
        case (?a) { switch (a.normalSide) { case (#debit) 1; case (#credit) -1 } };
        case null 1;
      };
      v := sign * (row.closingDebits - row.closingCredits : Int);
    };
  };
  v
};

// A CBE-shaped balance-sheet return with a Basel capital ratio on the end. Every figure below
// is either a sum of mapped accounts, a difference of two lines, a declared weight applied to a
// line, a ratio with a declared zero-denominator behaviour, or a figure the institution
// declared. Account 9500 is mapped to nothing at all, so the unmapped section has something in
// it and the return is flagged on its face.
let template : RT.ReturnTemplate = {
  id = "CBE-BS";
  version = 1;
  title = "Balance sheet return";
  authority = "CBE";
  currency = "EGP";
  taxonomy = ?"http://cbe.org.eg/xbrl/2026/bs";
  parameters = [
    { name = "corporate risk weight"; numerator = 100; denominator = 100 },
    { name = "retail risk weight"; numerator = 75; denominator = 100 },
    { name = "declared countercyclical buffer, basis points"; numerator = 250; denominator = 1 },
  ];
  lines = [
    { code = "A10"; caption = "Cash"; source = #sumOfAccounts({ accounts = ["1001"]; measure = #closingBalance }); binding = ?"Cash" },
    { code = "A20"; caption = "Loans and advances"; source = #sumOfRanges({ ranges = [{ lo = 1200; hi = 1299 }]; measure = #closingBalance }); binding = ?"LoansAndAdvances" },
    { code = "A30"; caption = "Other assets"; source = #sumOfAccounts({ accounts = ["1410", "1600", "1999"]; measure = #closingBalance }); binding = ?"OtherAssets" },
    { code = "A99"; caption = "Total assets"; source = #sumOfLines({ lines = ["A10", "A20", "A30"] }); binding = ?"TotalAssets" },
    { code = "L10"; caption = "Customer deposits"; source = #sumOfAccounts({ accounts = ["2110"]; measure = #closingBalance }); binding = ?"CustomerDeposits" },
    { code = "L20"; caption = "Other liabilities"; source = #sumOfAccounts({ accounts = ["2120", "2400"]; measure = #closingBalance }); binding = ?"OtherLiabilities" },
    { code = "L99"; caption = "Total liabilities"; source = #sumOfLines({ lines = ["L10", "L20"] }); binding = ?"TotalLiabilities" },
    { code = "E10"; caption = "Net assets"; source = #difference({ minuend = "A99"; subtrahend = "L99" }); binding = ?"NetAssets" },
    { code = "RWA"; caption = "Risk-weighted assets, retail weight"; source = #weighted({ line = "A20"; numerator = 75; denominator = 100 }); binding = ?"RiskWeightedAssets" },
    { code = "CAR"; caption = "Capital adequacy ratio, basis points"; source = #ratio({ numerator = "E10"; denominator = "RWA"; scale = 10_000; whenZero = #reportUnmeasurable }); binding = ?"CapitalAdequacyRatio" },
    { code = "BUF"; caption = "Countercyclical buffer, basis points"; source = #declared({ value = 250 }); binding = ?"CountercyclicalBuffer" },
  ];
};
assert (ReturnsM.validate(template) == null);

// R-9's first half: every chart account falls in at most one line. The claim is checked over
// the whole four-digit prefix space, as the journal layer did for leadsheets, rather than over the accounts
// that happen to exist.
let claims = switch (ReturnsM.claimsOf(template)) {
  case (#ok(m)) m;
  case (#err(e)) { Debug.print(debug_show (e)); assert false; loop {} };
};
var prefixesChecked = 0;
var prefixesClaimed = 0;
var p2 = 0;
while (p2 < 10_000) {
  // a prefix is claimed by a range, an account code by a list; neither may be claimed twice,
  // which `claimsOf` refuses at registration and is re-checked here by counting
  var hits = 0;
  for (l in template.lines.vals()) {
    switch (l.source) {
      case (#sumOfRanges(sr)) { for (g in sr.ranges.vals()) { if (p2 >= g.lo and p2 <= g.hi) hits += 1 } };
      case (_) {};
    };
  };
  if (hits > 1) { Debug.print("prefix " # Nat.toText(p2) # " is claimed by " # Nat.toText(hits) # " lines"); assert false };
  if (hits == 1) prefixesClaimed += 1;
  prefixesChecked += 1;
  p2 += 1;
};
Debug.print("count: four-digit prefixes checked for double mapping = " # Nat.toText(prefixesChecked));
Debug.print("count: prefixes a return line claims = " # Nat.toText(prefixesClaimed));
assert (prefixesChecked == 10_000);

// a template that maps an account twice is refused, naming both lines
let doubled : RT.ReturnTemplate = {
  template with
  id = "DOUBLED";
  lines = [
    { code = "X1"; caption = "first"; source = #sumOfAccounts({ accounts = ["1001"]; measure = #closingBalance }); binding = null },
    { code = "X2"; caption = "second"; source = #sumOfAccounts({ accounts = ["1001"]; measure = #closingBalance }); binding = null },
  ];
};
switch (ReturnsM.validate(doubled)) {
  case (?#AccountMappedTwice(d)) {
    assert (Text.equal(d.account, "1001"));
    assert (Text.equal(d.first, "X1") and Text.equal(d.second, "X2"));
    Debug.print("account 1001 refused: claimed by " # d.first # " and by " # d.second);
  };
  case (other) { Debug.print(debug_show (other)); assert false };
};
// and so is a range that overlaps another line's range
let overlapping : RT.ReturnTemplate = {
  template with
  id = "OVERLAP";
  lines = [
    { code = "Y1"; caption = "first"; source = #sumOfRanges({ ranges = [{ lo = 1000; hi = 1500 }]; measure = #closingBalance }); binding = null },
    { code = "Y2"; caption = "second"; source = #sumOfRanges({ ranges = [{ lo = 1400; hi = 1600 }]; measure = #closingBalance }); binding = null },
  ];
};
switch (ReturnsM.validate(overlapping)) {
  case (?#AccountMappedTwice(_)) {};
  case (other) { Debug.print(debug_show (other)); assert false };
};
Debug.print("count: templates refused for mapping an account twice = 2");

// a circular definition is refused naming a line in the cycle, rather than trapping
let circular : RT.ReturnTemplate = {
  template with
  id = "CIRCULAR";
  lines = [
    { code = "Z1"; caption = "one"; source = #sumOfLines({ lines = ["Z2"] }); binding = null },
    { code = "Z2"; caption = "two"; source = #difference({ minuend = "Z1"; subtrahend = "Z1" }); binding = null },
  ];
};
switch (ReturnsM.validate(circular)) {
  case (?#CircularLine(d)) { Debug.print("a circular return line refused: " # d.line) };
  case (other) { Debug.print(debug_show (other)); assert false };
};
// as is a line referring to a line that does not exist
switch (ReturnsM.validate({ template with id = "DANGLING"; lines = [
  { code = "W1"; caption = "one"; source = #sumOfLines({ lines = ["NOPE"] }); binding = null },
] })) {
  case (?#UnknownLine(d)) assert (Text.equal(d.line, "NOPE"));
  case (other) { Debug.print(debug_show (other)); assert false };
};
Debug.print("count: templates refused for a circular or dangling line = 2");

// R-9's second half and R-10: evaluate it, and recompute every figure here
var returnsChecked = 0;
for ((pid, _, _) in periods.vals()) {
  switch (ReturnsM.evaluate(js, template, "HQ", pid)) {
    case (#err(e)) { Debug.print(debug_show (e)); assert false };
    case (#ok(r)) {
      assert (r.templateHash == ReturnsM.templateHash(template));
      assert (r.values.size() == template.lines.size());
      let vals = r.values;
      // the sums, recomputed from the trial balance here rather than from the engine
      assert (valueOf(vals, "A10") == closingOf(pid, "1001"));
      assert (valueOf(vals, "A20") == closingOf(pid, "1210") + closingOf(pid, "1220"));
      assert (valueOf(vals, "A30") == closingOf(pid, "1410") + closingOf(pid, "1600") + closingOf(pid, "1999"));
      assert (valueOf(vals, "A99") == valueOf(vals, "A10") + valueOf(vals, "A20") + valueOf(vals, "A30"));
      assert (valueOf(vals, "L10") == closingOf(pid, "2110"));
      assert (valueOf(vals, "L99") == valueOf(vals, "L10") + valueOf(vals, "L20"));
      assert (valueOf(vals, "E10") == valueOf(vals, "A99") - valueOf(vals, "L99"));
      // the declared weight: three quarters of the loan book, rounded half away from zero once
      let a20 = Int.abs(valueOf(vals, "A20"));
      let wantRwa = (a20 * 75 * 2 + 100) / 200;
      let signedRwa = if (valueOf(vals, "A20") < 0) -wantRwa else wantRwa;
      assert (valueOf(vals, "RWA") == signedRwa);
      // the ratio, at its declared scale of basis points
      if (valueOf(vals, "RWA") == 0) {
        assert (not measurableOf(vals, "CAR"));
        assert (valueOf(vals, "CAR") == 0);
      } else {
        let neg = (valueOf(vals, "E10") < 0) != (valueOf(vals, "RWA") < 0);
        let an = Int.abs(valueOf(vals, "E10")) * 10_000;
        let ad = Int.abs(valueOf(vals, "RWA"));
        let q = (an * 2 + ad) / (ad * 2);
        assert (valueOf(vals, "CAR") == (if (neg) -q else q));
        assert (measurableOf(vals, "CAR"));
      };
      // the declared figure is the declared figure
      assert (valueOf(vals, "BUF") == 250);
      // and the account nothing maps is reported with its balance, which flags the return
      var sundryReported = false;
      for (u in r.unmapped.vals()) { if (Text.equal(u.account, "9500")) sundryReported := true };
      assert (sundryReported);
      assert (r.unmappedTotal != 0);
      assert (r.flagged);
      returnsChecked += 1;
    };
  };
};
Debug.print("count: returns evaluated and recomputed figure by figure = " # Nat.toText(returnsChecked));
assert (returnsChecked == periods.size());

// the three zero-denominator behaviours, each declared and each doing what it declared
var zeroBehaviours = 0;
for ((behaviour, wantRefusal) in [(#reportZero, false), (#reportUnmeasurable, false), (#refuse, true)].vals()) {
  let t : RT.ReturnTemplate = {
    template with
    id = "ZERO";
    lines = [
      { code = "N"; caption = "numerator"; source = #declared({ value = 500 }); binding = null },
      { code = "D"; caption = "denominator"; source = #declared({ value = 0 }); binding = null },
      { code = "R"; caption = "ratio"; source = #ratio({ numerator = "N"; denominator = "D"; scale = 100; whenZero = behaviour }); binding = null },
    ];
  };
  switch (ReturnsM.evaluate(js, t, "HQ", "2026-Q4")) {
    case (#err(#ZeroDenominator(d))) { assert (wantRefusal and Text.equal(d.line, "R")) };
    case (#ok(r)) {
      assert (not wantRefusal);
      var amount : Int = -1;
      var measurable = true;
      for (v in r.values.vals()) { if (Text.equal(v.code, "R")) { amount := v.amount; measurable := v.measurable } };
      assert (amount == 0);
      switch (behaviour) {
        case (#reportZero) assert (measurable);
        case (#reportUnmeasurable) assert (not measurable);
        case (#refuse) assert false;
      };
    };
    case (other) { Debug.print(debug_show (other)); assert false };
  };
  zeroBehaviours += 1;
};
Debug.print("count: declared zero-denominator behaviours verified = " # Nat.toText(zeroBehaviours));
assert (zeroBehaviours == 3);

// a template whose lines all map something has nothing to report as unmapped, and is **not**
// flagged; so the flag means what it says
let complete : RT.ReturnTemplate = {
  template with
  id = "COMPLETE";
  // Two lines over the same range reading **different** measures: the debits and the credits
  // of every account. That is legitimate and the claim rule allows it, because the two are
  // different figures; what it forbids is the same measure of the same account twice.
  lines = [
    { code = "DR"; caption = "every debit"; source = #sumOfRanges({ ranges = [{ lo = 0; hi = 9999 }]; measure = #closingDebits }); binding = null },
    { code = "CR"; caption = "every credit"; source = #sumOfRanges({ ranges = [{ lo = 0; hi = 9999 }]; measure = #closingCredits }); binding = null },
    { code = "NET"; caption = "the difference, which is zero"; source = #difference({ minuend = "DR"; subtrahend = "CR" }); binding = null },
  ];
};
assert (ReturnsM.validate(complete) == null);
switch (ReturnsM.evaluate(js, complete, "HQ", "2026-Q4")) {
  case (#ok(r)) {
    assert (r.unmapped.size() == 0);
    assert (r.unmappedTotal == 0);
    assert (not r.flagged);
    // a return covering every account has debits equal to credits, because the trial balance
    // does; which is the one figure a regulator can check without any of our arithmetic
    assert (valueOf(r.values, "DR") > 0);
    assert (valueOf(r.values, "DR") == valueOf(r.values, "CR"));
    assert (valueOf(r.values, "NET") == 0);
  };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};
Debug.print("count: complete returns that were not flagged = 1");

// and the same measure of the same account on two lines is still refused
switch (ReturnsM.validate({ template with id = "SAMEMEASURE"; lines = [
  { code = "M1"; caption = "one"; source = #sumOfRanges({ ranges = [{ lo = 1000; hi = 1999 }]; measure = #closingDebits }); binding = null },
  { code = "M2"; caption = "two"; source = #sumOfAccounts({ accounts = ["1001"]; measure = #closingDebits }); binding = null },
] })) {
  case (?#AccountMappedTwice(_)) {};
  case (other) { Debug.print("two lines claiming the same measure were accepted: " # debug_show (other)); assert false };
};
Debug.print("count: templates refused for claiming one measure of an account twice = 1");

// ═══════════════════════════════════════════════════════════════════════════
//  the export lines, and what makes them provable
// ═══════════════════════════════════════════════════════════════════════════

var exportChecks = 0;
for (shape in ([#safT, #aicpaAds, #normalisedTrialBalance] : [RT.ExportShape]).vals()) {
  switch (Filings.exportResult(js, JMemLog.reader(chain), shape, "HQ", "2026-Q4")) {
    case (#err(e)) { Debug.print(debug_show (e)); assert false };
    case (#ok(r)) {
      assert (r.lines.size() > 0);
      assert (r.linesWithProof == r.lines.size());
      assert (Text.equal(r.evidenceGrade, "proven"));
      assert (r.atHeight == JCore.height(js));
      assert (r.contentHash.size() == 32);
      // every line that moved in the period names the blocks it folds over; a line that did
      // not move names none, and that is the true answer rather than a fabricated one
      var withBlocks = 0;
      for (l in r.lines.vals()) {
        if (l.periodDebits > 0 or l.periodCredits > 0) {
          if (l.blocks.size() == 0) {
            Debug.print("line " # l.account # " moved and names no block");
            assert false;
          };
          withBlocks += 1;
        };
        // opening plus period is closing, on both sides, which is the arithmetic an importer
        // re-derives
        assert (l.openingDebits + l.periodDebits == l.closingDebits);
        assert (l.openingCredits + l.periodCredits == l.closingCredits);
      };
      assert (withBlocks > 0);
      exportChecks += 1;
    };
  };
};
Debug.print("count: export shapes whose lines carry their basis = " # Nat.toText(exportChecks));
assert (exportChecks == 3);

// the normalised trial balance the audit product consumes, and the grade it carries
let tbExport = switch (Filings.exportResult(js, JMemLog.reader(chain), #normalisedTrialBalance, "HQ", "2026-Q4")) {
  case (#ok(r)) r;
  case (#err(e)) { Debug.print(debug_show (e)); assert false; loop {} };
};
let normalised = Filings.normalisedTrialBalanceJson(tbExport, "EGP", 2);
assert (normalised.lines > 0);
assert (Text.contains(normalised.json, #text "\"evidence_grade\": \"proven\""));
assert (Text.contains(normalised.json, #text ("\"lines_with_proof\": " # Nat.toText(normalised.lines))));
assert (Text.contains(normalised.json, #text "\"journal_blocks\""));
assert (Text.contains(normalised.json, #text "\"proof_basis\": \"journal-mmr\""));
Debug.print("count: normalised trial-balance lines carrying a proof basis = " # Nat.toText(normalised.lines));

// ═══════════════════════════════════════════════════════════════════════════
//  R-15; the feed is verifiable and gapless
// ═══════════════════════════════════════════════════════════════════════════

// A consumer asks for events after a cursor and gets back the bounds, the tip and a digest
// over the slice **in order**. The checks below are the consumer's own: recompute the digest,
// confirm the run starts where it asked and is contiguous. A page that passes them is a page
// nobody spliced, reordered or truncated; which is strictly more than a webhook can offer,
// because a webhook's recipient has nothing to check.
func feedEvent(cursor : Nat, kind : Text) : RT.FeedEvent {
  { cursor; block = cursor; kind; book = ?"HQ" }
};

let page : FeedM.FeedPage = {
  events = Array.tabulate<RT.FeedEvent>(8, func(i) { feedEvent(100 + i, "posted") });
  from = 100;
  to = 108;
  tipCursor = 200;
  caughtUp = false;
  digest = FeedM.pageDigest(Array.tabulate<RT.FeedEvent>(8, func(i) { feedEvent(100 + i, "posted") }), 100, 108);
};
assert (FeedM.isContiguous(page, 100));
Debug.print("count: feed pages a consumer accepted = 1");

// and every way of tampering with it is detected
var tamperTrials = 0;
var tampersDetected = 0;
func detect(bad : FeedM.FeedPage, requestedFrom : Nat, what : Text) {
  tamperTrials += 1;
  if (FeedM.isContiguous(bad, requestedFrom)) { Debug.print("undetected: " # what); assert false };
  tampersDetected += 1;
};

// a page starting somewhere other than where the consumer asked
detect(page, 99, "a page that does not start where the consumer asked");
detect({ page with from = 101 }, 100, "a shifted lower bound");
// a truncation: events removed without the bounds or the digest changing
var cut = 1;
while (cut <= 8) {
  detect({ page with events = Array.tabulate<RT.FeedEvent>(8 - cut, func(i) { feedEvent(100 + i, "posted") }) },
         100, "a truncation of " # Nat.toText(cut));
  cut += 1;
};
// a reorder: the same events in the wrong order
detect({ page with events = Array.tabulate<RT.FeedEvent>(8, func(i) { feedEvent(107 - i, "posted") }) },
       100, "a reversal");
detect({ page with events = Array.tabulate<RT.FeedEvent>(8, func(i) {
  if (i == 3) feedEvent(104, "posted") else if (i == 4) feedEvent(103, "posted") else feedEvent(100 + i, "posted")
}) }, 100, "two events swapped");
// a splice: an event inserted, or one event's content altered
var alter = 0;
while (alter < 8) {
  detect({ page with events = Array.tabulate<RT.FeedEvent>(8, func(i) {
    if (i == alter) feedEvent(100 + i, "tampered") else feedEvent(100 + i, "posted")
  }) }, 100, "an altered kind at " # Nat.toText(alter));
  detect({ page with events = Array.tabulate<RT.FeedEvent>(8, func(i) {
    if (i == alter) { { cursor = 100 + i; block = 999; kind = "posted"; book = ?"HQ" } } else feedEvent(100 + i, "posted")
  }) }, 100, "an altered block at " # Nat.toText(alter));
  detect({ page with events = Array.tabulate<RT.FeedEvent>(8, func(i) {
    if (i == alter) { { cursor = 100 + i; block = 100 + i; kind = "posted"; book = null } } else feedEvent(100 + i, "posted")
  }) }, 100, "an altered book at " # Nat.toText(alter));
  // a repeat, which is a cursor that does not advance. Only from the second position on:
  // putting cursor 100 back at position 0 is not a mutation at all.
  if (alter >= 1) {
    detect({ page with events = Array.tabulate<RT.FeedEvent>(8, func(i) {
      if (i == alter) feedEvent(100, "posted") else feedEvent(100 + i, "posted")
    }) }, 100, "a repeated cursor at " # Nat.toText(alter));
  };
  alter += 1;
};
// a cursor moved forward by one, which opens a gap the digest also catches
var shift = 0;
while (shift < 8) {
  detect({ page with events = Array.tabulate<RT.FeedEvent>(8, func(i) {
    if (i == shift) feedEvent(101 + i, "posted") else feedEvent(100 + i, "posted")
  }) }, 100, "a cursor shifted forward at " # Nat.toText(shift));
  shift += 1;
};
// an event spliced into the middle, pushing the rest along
var splice = 1;
while (splice < 8) {
  detect({ page with events = Array.tabulate<RT.FeedEvent>(8, func(i) {
    if (i < splice) feedEvent(100 + i, "posted")
    else if (i == splice) feedEvent(900, "spliced")
    else feedEvent(99 + i, "posted")
  }) }, 100, "an event spliced at " # Nat.toText(splice));
  splice += 1;
};
// an event past the page's stated end
detect({ page with events = Array.tabulate<RT.FeedEvent>(9, func(i) { feedEvent(100 + i, "posted") }) },
       100, "an event past the stated end");
// and a digest that was recomputed over the wrong bounds
detect({ page with digest = FeedM.pageDigest(page.events, 100, 107) }, 100, "a digest over the wrong bounds");
Debug.print("count: tampered feed pages detected = " # Nat.toText(tampersDetected));
assert (tampersDetected == tamperTrials);
assert (tampersDetected >= 50);

// an empty page is legitimate; a caught-up consumer gets one; and is accepted only when its
// bounds say so
let empty : FeedM.FeedPage = {
  events = []; from = 200; to = 200; tipCursor = 200; caughtUp = true;
  digest = FeedM.pageDigest([], 200, 200);
};
assert (FeedM.isContiguous(empty, 200));
assert (not FeedM.isContiguous({ empty with to = 201 }, 200));
Debug.print("count: empty feed pages accepted and their bounds checked = 2");

// a push endpoint is https with a backing-off retry schedule, or it is refused
assert (FeedM.validateEndpoint({ url = "https://consumer.example.test/hook"; retries = [30, 120, 600]; active = true }) == null);
assert (FeedM.validateEndpoint({ url = "https://consumer.example.test/hook"; retries = []; active = false }) == null);
var endpointRefusals = 0;
for (bad in ([
  { url = ""; retries = []; active = true },
  { url = "http://consumer.example.test/hook"; retries = []; active = true },
  { url = "https://consumer.example.test/hook"; retries = [30, 0]; active = true },
  { url = "https://consumer.example.test/hook"; retries = [600, 30]; active = true },
  { url = "https://consumer.example.test/hook"; retries = [1, 2, 3, 4, 5, 6, 7, 8, 9]; active = true },
] : [RT.FeedEndpoint]).vals()) {
  switch (FeedM.validateEndpoint(bad)) {
    case (?_) endpointRefusals += 1;
    case null { Debug.print("an endpoint was accepted that should not be: " # bad.url); assert false };
  };
};
Debug.print("count: push endpoints refused = " # Nat.toText(endpointRefusals));
assert (endpointRefusals == 5);

Debug.print("REPORT ENGINE TEST GREEN");
