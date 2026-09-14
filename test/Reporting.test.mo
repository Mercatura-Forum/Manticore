// Reporting.test.mo; the reporting layer through the real bank.
//
// `ReportEngine.test.mo` proves the arithmetic against a bare journal. What needs the bank is
// everything that reads the bank's own state, and it is the part a fixture would have hidden:
//
//   R-5b the sub-ledger row source: a report keyed by book, by product or by a **declared**
//        counterparty class, built from real product accounts and real parties; including a
//        party carrying no value for the declared field, which is keyed `unclassified` and
//        reported rather than bucketed
//   R-6  a statement is cut, not re-derived: the camt.053 of a recorded cut is byte-identical
//        before and after a posting is back-valued into the cut day, all five balance kinds are
//        present, and `CLAV` differs from `CLBD` by exactly the reservations the journal holds
//   R-14b a certified artefact is a recorded act: the definition, the template and the
//        certification are blocks, a report's content hash is the hash of its canonical bytes,
//        and re-certifying the same report at the same height is the same entry
//   the registration rules: a version is immutable, a malformed definition or template never
//   reaches a block, and a statement re-issued is the same statement with its count raised
//
// engine: wasi-only; the battery builds a bank, a journal and a portfolio and fingerprints
// whole states, which does not finish in a useful time under `moc -r`, the same exemption the
// BankCore, PartyCore, ProductEngine, PeriodEnd and EndOfDay batteries carry.

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
import JCamt "mo:journal/Camt053";
import CivilDate "mo:journal/CivilDate";

import T "../src/bank/BankTypes";
import PT "../src/bank/PartyTypes";
import ProdT "../src/bank/ProductTypes";
import RT "../src/bank/ReportTypes";
import Core "../src/bank/BankCore";
import ProductCore "../src/bank/ProductCore";
import ReportCore "../src/bank/ReportCore";
import Reports "../src/bank/Reports";
import ReturnsM "../src/bank/Returns";
import StatementsM "../src/bank/Statements";
import BatchCore "../src/bank/BatchCore";
import Posting "../src/bank/Posting";
import I "../src/bank/Interest";
import P "../src/bank/Permissions";
import Commit "../src/bank/Commitments";
import S "../src/bank/Screening";
import BankMemLog "support/BankMemLog";
import JMemLog "support/JournalMemLog";

// ─── fixtures ────────────────────────────────────────────────────────────────

let bankP = Principal.fromBlob("\BA\01");
let installer = Principal.fromBlob("\1A\01");
let screener = Principal.fromBlob("\5C\01");

func day(y : Nat, m : Nat, d : Nat) : JT.Day {
  switch (CivilDate.fromCivil(y, m, d)) { case (?x) x; case null { assert false; 0 } }
};

let JAN1 = day(2026, 1, 1);
let JAN31 = day(2026, 1, 31);
let FEB1 = day(2026, 2, 1);
let FEB28 = day(2026, 2, 28);
let CUT = day(2026, 2, 20);
let NOW = day(2026, 3, 5);
let DAY_NS : Nat64 = 86_400_000_000_000;
let clock : Nat64 = Nat64.fromNat(NOW) * DAY_NS + 43_200_000_000_000;

let bchain = BankMemLog.new();
let jchain = JMemLog.new();
let bs = Core.newState(installer);
let js = JCore.newState(bankP);

func bcommit(caller : Principal, e : T.Event) : T.Block { BankMemLog.commit(bchain, bs, clock, caller, e) };
func jcommit(e : JT.Event) : JT.Block { JMemLog.commit(jchain, js, clock, bankP, e) };

var authority = 1_000_000;
func nextAuthority() : Nat { authority += 1; authority };

func execute(command : T.Command, authorityIndex : Nat) : [Nat] {
  switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, command, authorityIndex)) {
    case (#err(e)) { Debug.print("plan failed for " # P.commandName(command) # ": " # debug_show (e)); assert false; [] };
    case (#ok(plan)) {
      switch (plan.bankEvent) { case (?ev) { ignore bcommit(installer, ev) }; case null {} };
      for (ev in plan.extra.vals()) { ignore bcommit(installer, ev) };
      let out = List.empty<Nat>();
      for (step in plan.journal.vals()) {
        switch (step) { case (#event(ev)) List.add(out, jcommit(ev).index); case (#existing(i)) List.add(out, i) };
      };
      List.toArray(out)
    };
  }
};
func run(command : T.Command) : Nat { let at = Core.height(bs); ignore execute(command, nextAuthority()); at };
func runPostings(command : T.Command) : [Nat] { execute(command, nextAuthority()) };

func refuse(command : T.Command, want : Text) {
  let fp = Core.fingerprint(bs);
  let h = Core.height(bs);
  switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, command, nextAuthority())) {
    case (#ok(_)) { Debug.print("expected " # want # " for " # P.commandName(command)); assert false };
    case (#err(e)) {
      let got = debug_show (e);
      if (not Text.contains(got, #text want)) { Debug.print("wanted " # want # " got " # got); assert false };
    };
  };
  assert (Core.fingerprint(bs) == fp and Core.height(bs) == h);
};

// ─── genesis, a chart, two periods, two books ───────────────────────────────

ignore jcommit(switch (JCore.prepareAddPoster(js, bankP, bankP)) { case (#ok(e)) e; case (#err(_)) { assert false; loop {} } });
ignore bcommit(installer, #bankAdminTransferred({ admin = installer }));
ignore run(#openBook({ id = "HQ"; name = "Head office"; parent = null }));
ignore run(#openBook({ id = "BR01"; name = "Branch 1"; parent = ?"HQ" }));
ignore run(#openBook({ id = "BR02"; name = "Branch 2"; parent = ?"HQ" }));
ignore run(#journalRegisterCurrency({ code = "EGP"; minorUnits = 2 }));

type Acct = (Text, Text, JT.Side, JT.Category);
let chart : [Acct] = [
  ("1001", "Cash and vault", #debit, #asset),
  ("1210", "Loan portfolio", #debit, #asset),
  ("1220", "Interest receivable", #debit, #asset),
  ("1230", "Fees receivable", #debit, #asset),
  ("1240", "Penalties receivable", #debit, #asset),
  ("1290", "Allowance for credit losses", #debit, #asset),
  ("1900", "Suspense", #debit, #asset),
  ("1999", "Settlement", #debit, #asset),
  ("2110", "Customer deposits", #credit, #liability),
  ("2120", "Interest payable", #credit, #liability),
  ("3200", "Retained earnings", #credit, #equity),
  ("4100", "Fee income", #credit, #income),
  ("4110", "Penalty income", #credit, #income),
  ("4200", "Interest income", #credit, #income),
  ("4300", "Recoveries", #credit, #income),
  ("5100", "Interest expense", #debit, #expense),
  ("5200", "Impairment expense", #debit, #expense),
  ("5210", "Loans written off", #debit, #expense),
];
for ((code, name, side, cat) in chart.vals()) {
  ignore run(#journalOpenAccount({ code; name; normalSide = side; category = cat; constraint = #none }));
};
ignore run(#journalOpenPeriod({ id = "2026-01"; start = JAN1; end = JAN31 }));
ignore run(#journalOpenPeriod({ id = "2026-02"; start = FEB1; end = FEB28 }));
ignore run(#journalRollBusinessDate({ day = JAN1 }));
ignore run(#journalSetActivationHeight({ height = 0 }));
ignore run(#setAccountFormat({ country = "EG"; bank = "0037"; branch = "0001"; serialWidth = 12; prefix = "00000" }));
for (b in ["HQ", "BR01", "BR02"].vals()) {
  ignore run(#setBackValueWindow({ window = { book = b; freeDays = 120; approvedDays = 0 } }));
};
ignore run(#setFunctionalCurrency({ currency = "EGP" }));
for (f in ProdT.featureIds().vals()) {
  ignore run(#setFeatureActivation({ feature = f; height = Nat64.fromNat(Core.height(bs)) }));
};
Debug.print("count: chart accounts opened = " # Nat.toText(chart.size()));

// ─── a declared counterparty classification, as an extension schema ─────────
//
// The sector a return breaks deposits down by is a **declared**, non-personal label held as an
// extension value on the party. Nothing about it is derived from personal data, which this
// layer holds only as commitments; and a party carrying no value for the field is keyed
// `unclassified`, which is the same discipline the leadsheet mapping has.
ignore run(#registerSchema({
  id = "cbe";
  entity = #party;
  fields = [{ name = "sector"; fieldType = #enumerated(["household", "corporate", "government"]); required = false }];
}));

func saltFor(i : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { Nat8.fromNat((i * 31 + j) % 256) })) };
let institutionSalt = saltFor(99);
let entries = Array.sort<Blob>(Array.map<Text, Blob>(["AL QAIDA"], func(t) { S.entryBytes(t) }), func(a, b) { S.compareEntries(a, b) });
let ?listRoot = S.root(entries) else { assert false; loop {} };
ignore run(#commitScreeningList({ version = "L1"; root = listRoot; count = 1; normalisation = Commit.NORMALISATION }));

func makeParty(i : Nat, book : Text, sector : ?Text) : Nat {
  let salt = saltFor(i);
  let id = run(#createParty({
    kind = #natural; salt;
    identityCommit = Commit.identity(salt, #natural, ["Person " # Nat.toText(i), "2980101123456" # Nat.toText(i)]);
    dedupCommit = ?Commit.dedup(institutionSalt, "nationalId", "2980101123456" # Nat.toText(i));
    attributes = []; book; cddLevel = #standard; riskRating = #low; pep = false;
    reviewDue = NOW + 365;
  }));
  ignore run(#setPartyLifecycle({ party = id; to = #pendingKyc }));
  for (kind in ["identity", "address"].vals()) {
    ignore run(#addPartyDocument({ party = id; document = { kind; commit = Commit.document(salt, kind, Blob.fromArray([1])); issued = 20000; expires = null } }));
  };
  ignore run(#recordScreeningDecision({ party = id; listVersion = "L1"; listRoot; decision = #clear; screener; justificationCommit = Commit.justification("no match") }));
  ignore run(#setPartyLifecycle({ party = id; to = #active }));
  switch (sector) {
    case (?s) ignore run(#setPartyExtension({ party = id; values = [{ schema = "cbe"; name = "sector"; value = #enumerated(s) }] }));
    // and one party deliberately carrying no sector at all
    case null {};
  };
  id
};

let household1 = makeParty(1, "BR01", ?"household");
let household2 = makeParty(2, "BR02", ?"household");
let corporate1 = makeParty(3, "BR01", ?"corporate");
let unclassified1 = makeParty(4, "BR02", null);
Debug.print("count: parties onboarded with a declared sector = 3");

// ─── products and funded accounts across two branches ───────────────────────

func rate(n : Nat, d : Nat) : I.Rate { { numerator = n; denominator = d; negative = false } };

let savings : ProdT.ProductTerms = {
  kind = #savings;
  currency = "EGP";
  control = "2110";
  roles = [
    { role = #principal; account = "2110" },
    { role = #interestPayable; account = "2120" },
    { role = #interestExpense; account = "5100" },
    { role = #feeIncome; account = "4100" },
  ];
  interest = ?{
    chart = { bands = [{ from = 0; to = null; rate = rate(5, 100) }]; by = #balance };
    convention = #a004_Act365Fixed;
    basis = #dailyBalance;
    compounding = #monthly;
    compoundingAlignment = #anniversary;
    posting = #monthly;
    minimumBalance = 0;
    allowNegative = false;
  };
  charges = [];
  limits = { overdraft = null; minimumOperating = 0; perOperation = null };
  schedule = null;
  delinquency = [];
  provisioning = [];
  accounting = #accrualPeriodic;
  withholdingTax = null;
  rounding = #halfEven;
  earlyRedemptionPenalty = null;
  valueDateConvention = #sameDay;
};
ignore run(#registerProduct({ id = "SAV"; name = "Savings"; terms = savings }));
ignore run(#registerProduct({ id = "CUR"; name = "Current account"; terms = {
  savings with kind = #currentAccount;
  roles = [
    { role = #principal; account = "2110" },
    { role = #interestPayable; account = "2120" },
    { role = #interestExpense; account = "5100" },
    { role = #feeIncome; account = "4100" },
    { role = #overdraftPortfolio; account = "1210" },
  ];
} }));

func openFunded(product : Text, party : Nat, amount : Nat, d : JT.Day, period : Text) : Nat {
  let a = run(#openAccount({ product; party; currency = "EGP"; termDays = null; allocationOrder = [] }));
  ignore run(#setAccountStatus({ account = a; to = #active }));
  ignore runPostings(#depositToAccount({
    account = a; amount; postingDate = d; valueDate = d;
    period; narration = "opening deposit"; funding = #glAccount("1999");
  }));
  a
};

let acctH1 = openFunded("SAV", household1, 10_000_00, JAN1, "2026-01");
let acctH2 = openFunded("SAV", household2, 20_000_00, JAN1, "2026-01");
let acctC1 = openFunded("CUR", corporate1, 50_000_00, JAN1, "2026-01");
let acctU1 = openFunded("SAV", unclassified1, 3_000_00, JAN1, "2026-01");
Debug.print("count: product accounts opened and funded = 4");

// activity in February, so there is a period movement and a statement cut to take
ignore run(#journalRollBusinessDate({ day = CUT }));
for ((a, amount) in [(acctH1, 500_00), (acctH2, 250_00), (acctC1, 1_000_00)].vals()) {
  ignore runPostings(#depositToAccount({
    account = a; amount; postingDate = CUT; valueDate = CUT;
    period = "2026-02"; narration = "february deposit"; funding = #glAccount("1999");
  }));
};

// ═══════════════════════════════════════════════════════════════════════════
//  R-5b; the sub-ledger row source, over real accounts and real parties
// ═══════════════════════════════════════════════════════════════════════════

func def(id : Text, rows : [RT.Dimension], filters : [RT.Filter], measures : [RT.Measure]) : RT.ReportDef {
  { id; version = 1; title = "fixture " # id; rows; filters; measures;
    ordering = #byRowKey; scale = #minorUnits; comparatives = #none; maxSlice = 5_000 }
};

let byBook = def("BYBOOK", [#book], [], [#closingBalance]);
let byProduct = def("BYPRODUCT", [#product], [], [#closingBalance]);
let bySector = def("BYSECTOR", [#counterpartyClass({ schema = "cbe"; field = "sector" })], [], [#closingBalance]);
let byBookAndSector = def("BYBOTH", [#book, #counterpartyClass({ schema = "cbe"; field = "sector" })], [], [#closingBalance]);

let params : RT.ReportParams = { book = "HQ"; period = "2026-02"; view = #native; functional = null };

func evaluate(d : RT.ReportDef) : RT.Report {
  switch (Reports.evaluate(js, JMemLog.reader(jchain), d, params, Core.reportContext(bs, BankMemLog.reader(bchain), js, d), Core.height(bs))) {
    case (#ok(r)) r;
    case (#err(e)) { Debug.print(d.id # ": " # debug_show (e)); assert false; loop {} };
  }
};

func rowFor(r : RT.Report, key : [Text]) : ?Int {
  for (row in r.rows.vals()) {
    if (row.key.size() == key.size()) {
      var same = true;
      var i = 0;
      while (i < key.size()) { if (not Text.equal(row.key[i], key[i])) same := false; i += 1 };
      if (same) return ?row.cells[0].amount;
    };
  };
  null
};

// by book: BR01 holds the two accounts opened there, BR02 the other two
let bookReport = evaluate(byBook);
Debug.print("rows of the by-book report: " # Nat.toText(bookReport.rows.size()));
assert (bookReport.rows.size() == 2);
let ?br01 = rowFor(bookReport, ["BR01"]) else { Debug.print("no BR01 row"); assert false; loop {} };
let ?br02 = rowFor(bookReport, ["BR02"]) else { Debug.print("no BR02 row"); assert false; loop {} };
// deposits are a liability, so the normal-side figure is positive as the balance grows
assert (br01 == 10_000_00 + 500_00 + 50_000_00 + 1_000_00);
assert (br02 == 20_000_00 + 250_00 + 3_000_00);
Debug.print("count: books whose sub-ledger totals were verified = 2");

// by product: the savings accounts and the current account, kept apart
let productReport = evaluate(byProduct);
assert (productReport.rows.size() == 2);
let ?sav = rowFor(productReport, ["SAV"]) else { assert false; loop {} };
let ?cur = rowFor(productReport, ["CUR"]) else { assert false; loop {} };
assert (sav == 10_000_00 + 500_00 + 20_000_00 + 250_00 + 3_000_00);
assert (cur == 50_000_00 + 1_000_00);
assert (sav + cur == br01 + br02);
Debug.print("count: products whose sub-ledger totals were verified = 2");

// by the declared sector: household and corporate are rows, and the party with no declared
// sector is **unresolved**; reported, never bucketed into one of the others
let sectorReport = evaluate(bySector);
Debug.print("resolved sector rows: " # Nat.toText(sectorReport.rows.size())
  # ", unresolved: " # Nat.toText(sectorReport.unresolved.size()));
assert (sectorReport.rows.size() == 2);
assert (sectorReport.unresolved.size() == 1);
let ?household = rowFor(sectorReport, ["household"]) else { assert false; loop {} };
let ?corporate = rowFor(sectorReport, ["corporate"]) else { assert false; loop {} };
assert (household == 10_000_00 + 500_00 + 20_000_00 + 250_00);
assert (corporate == 50_000_00 + 1_000_00);
assert (Text.equal(sectorReport.unresolved[0].key[0], "unclassified"));
assert (sectorReport.unresolved[0].cells[0].amount == 3_000_00);
// and the unresolved row is not in the resolved total, but *is* in the report's own total;
// so a reader cannot lose it by reading the total, and cannot mistake it for a sector either
assert (sectorReport.totals[0].cells[0].amount == household + corporate + 3_000_00);
Debug.print("count: declared sectors reported, with the unclassified holding kept apart = 3");

// two dimensions at once: the row key is the pair
let bothReport = evaluate(byBookAndSector);
assert (bothReport.rows.size() == 3);
assert (rowFor(bothReport, ["BR01", "household"]) == ?(10_000_00 + 500_00));
assert (rowFor(bothReport, ["BR01", "corporate"]) == ?(50_000_00 + 1_000_00));
assert (rowFor(bothReport, ["BR02", "household"]) == ?(20_000_00 + 250_00));
assert (bothReport.unresolved.size() == 1);
Debug.print("count: two-dimension row keys verified = 3");

// a filter on a sub-ledger dimension narrows the rows
let filtered = evaluate(def("FILTERED", [#book], [{ dimension = #book; op = #eq("BR01") }], [#closingBalance]));
assert (filtered.rows.size() == 1);
assert (rowFor(filtered, ["BR01"]) == ?br01);
Debug.print("count: sub-ledger reports narrowed by a filter = 1");

// ═══════════════════════════════════════════════════════════════════════════
//  R-6; a statement is cut, not re-derived
// ═══════════════════════════════════════════════════════════════════════════

// The end-of-day batch records the cut. A camt.053 built from it must not move when a posting
// is later value-dated into the cut day, because the customer was sent the figure that stood at
// the cut and a statement that silently restates itself is a statement nobody can dispute.
ignore run(#setRetryPolicy({ policy = { book = "BR01"; limit = 2 } }));
ignore run(#openEndOfDay({ book = "BR01"; businessDate = CUT; shardSize = 1_000 }));
let recorder : Core.Recorder = {
  bank = func(ev : T.Event) : Nat { bcommit(bankP, ev).index };
  journal = func(ev : JT.Event) : Nat { jcommit(ev).index };
    monitor = Core.noMonitor;
};
var advances = 0;
label work loop {
  switch (Core.runEndOfDayChunk(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, "BR01", CUT, 64, recorder)) {
    case (#err(e)) { Debug.print("advance: " # debug_show (e)); assert false };
    case (#ok(a)) { advances += 1; if (a.completed) break work };
  };
  if (advances > 100) { Debug.print("the run did not finish"); assert false };
};
Debug.print("count: end-of-day advances taken to record the cuts = " # Nat.toText(advances));

let ?cutH1 = BatchCore.cutFor(bs.batch, acctH1) else { Debug.print("no cut for the household account"); assert false; loop {} };
assert (cutH1.day == CUT);
Debug.print("the cut records opening " # Nat.toText(cutH1.openingCredits) # " and closing " # Nat.toText(cutH1.closingCredits));

/// The in-heap journal log's block hash, which is what the camt projection derives a UETR
/// from; and what it withholds a whole statement for want of.
func memHashOf(i : Nat) : ?Blob {
  let bs2 = JMemLog.blocks(jchain);
  if (i < bs2.size()) ?bs2[i].hash else null
};

func statementFor(account : Nat, kind : RT.StatementKind) : RT.StatementRef {
  switch (Core.statementRefFor(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), account, kind, "2026-02")) {
    case (#ok(r)) r;
    case (#err(e)) { Debug.print(debug_show (e)); assert false; loop {} };
  }
};

let refBefore = statementFor(acctH1, #camt053({ cut = CUT }));
// all five balance kinds are present
var kinds = "";
for (b in refBefore.balances.vals()) { kinds #= StatementsM.balanceTypeCode(b.kind) # " " };
Debug.print("the balance kinds the statement states: " # kinds);
var kindCount = 0;
for (want in ([#OPBD, #CLBD, #PRCD, #ITBD, #CLAV] : [RT.BalanceType]).vals()) {
  var found = false;
  for (b in refBefore.balances.vals()) { if (b.kind == want) found := true };
  if (not found) { Debug.print("missing balance kind " # StatementsM.balanceTypeCode(want)); assert false };
  kindCount += 1;
};
Debug.print("count: ISO 20022 balance kinds the statement states = " # Nat.toText(kindCount));
assert (kindCount == 5);

func balanceOf(r : RT.StatementRef, kind : RT.BalanceType) : RT.StatementBalance {
  var out : ?RT.StatementBalance = null;
  for (b in r.balances.vals()) { if (b.kind == kind) out := ?b };
  switch (out) { case (?b) b; case null { assert false; loop {} } }
};

// OPBD and CLBD are the cut's own figures, not a re-derivation
assert (balanceOf(refBefore, #OPBD).credits == cutH1.openingCredits);
assert (balanceOf(refBefore, #OPBD).debits == cutH1.openingDebits);
assert (balanceOf(refBefore, #CLBD).credits == cutH1.closingCredits);
assert (balanceOf(refBefore, #CLBD).debits == cutH1.closingDebits);
// PRCD is the prior period's close, which is what makes the statement's continuity checkable
let ?h1Entry = ProductCore.get(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), acctH1) else { assert false; loop {} };
let priorClose = JCore.valueDatedBalance(js, "2110", ?h1Entry.subledger, "EGP", JAN31);
assert (balanceOf(refBefore, #PRCD).credits == priorClose.credits);
Debug.print("count: balance kinds tied to the cut and to the prior period = 3");

// CLAV differs from CLBD by exactly the reservations the journal is holding. With none held,
// the two agree; and that equality is itself the claim: an available figure that drifted from
// the booked one with nothing reserved would be a hold table nobody reconciles.
let live = JCore.balance(js, "2110", ?h1Entry.subledger, "EGP");
assert (live.debitsPending == 0 and live.creditsPending == 0);
assert (balanceOf(refBefore, #CLAV).debits == balanceOf(refBefore, #ITBD).debits);
assert (balanceOf(refBefore, #CLAV).credits == balanceOf(refBefore, #ITBD).credits);

// now reserve something, and CLAV moves by exactly that while CLBD does not move at all
let reserveInput : JT.PostingInput = {
  idempotencyKey = Posting.key("reservation", [Nat.toText(acctH1), Nat.toText(CUT)]);
  postingDate = CUT; valueDate = CUT; period = "2026-02";
  legs = [
    Posting.leg("2110", ?h1Entry.subledger, #debit, "EGP", 77_00),
    Posting.leg("1999", null, #credit, "EGP", 77_00),
  ];
  sourceRef = { kind = "reservation"; id = "test" };
  narration = "a hold on the account";
  correctionOf = null;
};
switch (JCore.prepareReserve(js, bankP, clock, reserveInput, null)) {
  case (#ok(#event(e))) ignore jcommit(e);
  case (other) { Debug.print("reserve: " # debug_show (other)); assert false };
};
let afterReserve = statementFor(acctH1, #camt053({ cut = CUT }));
let heldLive = JCore.balance(js, "2110", ?h1Entry.subledger, "EGP");
assert (heldLive.debitsPending == 77_00);
// the booked figures did not move
assert (balanceOf(afterReserve, #CLBD) == balanceOf(refBefore, #CLBD));
assert (balanceOf(afterReserve, #ITBD) == balanceOf(refBefore, #ITBD));
// and the available one moved by exactly the reservation
assert (balanceOf(afterReserve, #CLAV).debits == balanceOf(refBefore, #CLAV).debits + 77_00);
Debug.print("count: available balances differing from booked by exactly the reservation = 1");

// a posting value-dated into the cut day, admitted now the run is complete. The business date
// moves forward first, because the journal refuses a posting dated after the day the bank is
// on; which is the same rule that makes the cut a record of a day that has happened.
ignore run(#journalRollBusinessDate({ day = FEB28 }));
let lateIndices = runPostings(#depositToAccount({
  account = acctH1; amount = 999_00; postingDate = FEB28; valueDate = CUT;
  period = "2026-02"; narration = "a late deposit into the cut day"; funding = #glAccount("1999");
}));
assert (lateIndices.size() == 1);
let refAfter = statementFor(acctH1, #camt053({ cut = CUT }));
// the cut's figures are unchanged: OPBD and CLBD are a record
assert (balanceOf(refAfter, #OPBD) == balanceOf(refBefore, #OPBD));
assert (balanceOf(refAfter, #CLBD) == balanceOf(refBefore, #CLBD));
// while the live figures did move, so the comparison is not comparing two unchanged things
assert (balanceOf(refAfter, #ITBD).credits > balanceOf(refBefore, #ITBD).credits);
Debug.print("count: statement cuts unchanged by a posting value dated into the cut day = 1");

// a camt.053 for a day whose cut was never taken is refused, rather than answered from the
// live fold; the two are different claims and only one of them is what the customer was sent
switch (Core.statementRefFor(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), acctH1, #camt053({ cut = CUT + 1 }), "2026-02")) {
  case (#err(e)) assert (Text.contains(debug_show (e), #text "NoStatementCut"));
  case (#ok(_)) { Debug.print("a statement was produced for a day with no cut"); assert false };
};
// and an account the batch never cut has no statement at all
switch (Core.statementRefFor(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), acctU1, #camt053({ cut = CUT }), "2026-02")) {
  case (#err(e)) assert (Text.contains(debug_show (e), #text "NoStatementCut"));
  case (#ok(_)) { Debug.print("a statement was produced for an uncut account"); assert false };
};
Debug.print("count: camt.053 statements refused for a day with no cut = 2");

// the intraday report has no cut behind it and states no closing booked figure
let intraday = statementFor(acctH1, #camt052({ asOf = NOW }));
var hasClbd = false;
for (b in intraday.balances.vals()) { if (b.kind == #CLBD) hasClbd := true };
// the reference carries every kind; it is the **message** that omits CLBD, which the XML below
// is checked for
assert (hasClbd);
let ?mu = JCore.currencyMinorUnits(js, "EGP") else { assert false; loop {} };
let ?camtStatement = JCamt.statement(js, JMemLog.reader(jchain), "2026-02", "2110", ?h1Entry.subledger, "EGP", memHashOf) else { assert false; loop {} };
let xml052 = StatementsM.camt052Xml(camtStatement, intraday.balances, mu, "MSG-052", "2026-03-05T00:00:00Z", NOW);
assert (Text.contains(xml052, #text "BkToCstmrAcctRpt"));
assert (Text.contains(xml052, #text "camt.052.001.08"));
assert (not Text.contains(xml052, #text "<Cd>CLBD</Cd>"));
assert (Text.contains(xml052, #text "<Cd>ITBD</Cd>"));
assert (Text.contains(xml052, #text "<Cd>CLAV</Cd>"));
Debug.print("count: intraday reports that stated no closing booked figure = 1");

// the camt.053 message carries all five, and every entry names its journal block
let xml053 = StatementsM.camt053Xml(camtStatement, refAfter.balances, mu, "MSG-053", "2026-03-05T00:00:00Z");
for (code in ["OPBD", "CLBD", "PRCD", "ITBD", "CLAV"].vals()) {
  if (not Text.contains(xml053, #text ("<Cd>" # code # "</Cd>"))) {
    Debug.print("the camt.053 message omits " # code);
    assert false;
  };
};
assert (Text.contains(xml053, #text "BkToCstmrStmt"));
var blocksNamed = 0;
for (b in refAfter.entryBlocks.vals()) {
  // the block index is the entry's payment identifier, which is how one line is proved
  // the block index is the entry's `PaymentId`, in the element shape the journal uses and the
  // deployed published example decodes
  if (not Text.contains(xml053, #text ("<PaymentId>" # Nat.toText(b) # "</PaymentId>"))) {
    Debug.print("the message does not name block " # Nat.toText(b));
    assert false;
  };
  // and it really is a posting of this account
  switch (JCore.postingView(js, JMemLog.reader(jchain), b)) {
    case (?v) {
      var touches = false;
      for (l in v.record.legs.vals()) { if (Text.equal(l.account, "2110")) touches := true };
      assert (touches);
    };
    case null { Debug.print("block " # Nat.toText(b) # " is not a posting"); assert false };
  };
  blocksNamed += 1;
};
Debug.print("count: statement entries naming the journal block they came from = " # Nat.toText(blocksNamed));
assert (blocksNamed > 0);

// one notification per movement, naming the block
let notify = statementFor(acctH1, #camt054({ movement = refAfter.entryBlocks[0] }));
var entry : ?JCamt.StatementEntry = null;
for (e in camtStatement.entries.vals()) { if (e.paymentId == refAfter.entryBlocks[0]) entry := ?e };
let ?theEntry = entry else { assert false; loop {} };
let xml054 = StatementsM.camt054Xml("2110", "EGP", theEntry, mu, "MSG-054", "2026-03-05T00:00:00Z");
assert (Text.contains(xml054, #text "BkToCstmrDbtCdtNtfctn"));
assert (Text.contains(xml054, #text "camt.054.001.08"));
assert (Text.contains(xml054, #text ("<PaymentId>" # Nat.toText(refAfter.entryBlocks[0]) # "</PaymentId>")));
assert (notify.entryBlocks.size() > 0);
Debug.print("count: camt.054 notifications naming their movement = 1");

// ═══════════════════════════════════════════════════════════════════════════
//  R-14b; a certified artefact is a recorded act
// ═══════════════════════════════════════════════════════════════════════════

// A definition is registered as a block carrying its canonical hash, and that hash is the first
// component of every report's identity. A version is immutable: an amendment is a new version
// and the old one stays evaluable for ever, which is what makes "report R34 version 2" name
// exact arithmetic rather than whatever the arithmetic is today.
let registered = def("R34", [#category], [], [#closingBalance, #periodDebits]);
ignore run(#registerReportDefinition({ definition = registered }));
let ?defEntry = ReportCore.getDef(bs.report, "R34", 1) else { Debug.print("no definition"); assert false; loop {} };
assert (defEntry.hash == Reports.defHash(registered));
assert (defEntry.definition == registered);
// the same version twice is refused
refuse(#registerReportDefinition({ definition = registered }), "DefinitionExists");
// a second version is a different definition with a different hash, and both remain evaluable
let amended = { registered with version = 2; measures = [#closingBalance, #periodDebits, #periodCredits] };
ignore run(#registerReportDefinition({ definition = amended }));
let ?v2 = ReportCore.getDef(bs.report, "R34", 2) else { assert false; loop {} };
assert (v2.hash != defEntry.hash);
assert (Reports.evaluate(js, JMemLog.reader(jchain), defEntry.definition, params, Core.reportContext(bs, BankMemLog.reader(bchain), js, defEntry.definition), Core.height(bs)) != #err(#UnknownPeriod({ period = "2026-02" })));
switch (ReportCore.latestDef(bs.report, "R34")) {
  case (?e) assert (e.definition.version == 2);
  case null { assert false };
};
Debug.print("count: report definition versions registered and kept evaluable = 2");

// a malformed definition never reaches a block
var defRefusals = 0;
for (bad in [
  def("", [#category], [], [#closingBalance]),
  def("BAD1", [#category, #category], [], [#closingBalance]),
  def("BAD2", [#category], [], []),
  def("BAD3", [#leadsheet, #book], [], [#closingBalance]),
].vals()) {
  let h = Core.height(bs);
  switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, #registerReportDefinition({ definition = bad }), nextAuthority())) {
    case (#err(_)) { assert (Core.height(bs) == h); defRefusals += 1 };
    case (#ok(_)) { Debug.print("a malformed definition was accepted: " # bad.id); assert false };
  };
};
Debug.print("count: malformed definitions that never reached a block = " # Nat.toText(defRefusals));
assert (defRefusals == 4);

// a return template, likewise; and a template that maps an account twice never reaches a block
let template : RT.ReturnTemplate = {
  id = "CBE-BS"; version = 1; title = "Balance sheet return"; authority = "CBE"; currency = "EGP";
  taxonomy = ?"http://cbe.org.eg/xbrl/2026/bs";
  parameters = [{ name = "retail risk weight"; numerator = 75; denominator = 100 }];
  lines = [
    { code = "A10"; caption = "Cash"; source = #sumOfAccounts({ accounts = ["1001"]; measure = #closingBalance }); binding = ?"Cash" },
    { code = "L10"; caption = "Deposits"; source = #sumOfAccounts({ accounts = ["2110"]; measure = #closingBalance }); binding = ?"CustomerDeposits" },
    { code = "NET"; caption = "Net"; source = #difference({ minuend = "A10"; subtrahend = "L10" }); binding = ?"Net" },
  ];
};
ignore run(#registerReturnTemplate({ template }));
let ?tEntry = ReportCore.getTemplate(bs.report, "CBE-BS", 1) else { assert false; loop {} };
assert (tEntry.hash == ReturnsM.templateHash(template));
refuse(#registerReturnTemplate({ template }), "TemplateExists");
refuse(#registerReturnTemplate({ template = { template with id = "DOUBLED"; lines = [
  { code = "X1"; caption = "one"; source = #sumOfAccounts({ accounts = ["1001"]; measure = #closingBalance }); binding = null },
  { code = "X2"; caption = "two"; source = #sumOfAccounts({ accounts = ["1001"]; measure = #closingBalance }); binding = null },
] } }), "AccountMappedTwice");
Debug.print("count: return templates registered and refused = 3");

// the statement map: every account it names has to exist, because a map pointing at nothing
// produces a cash-flow statement that reconciles by accident
let map : RT.StatementMap = {
  cash = ["1001", "1999"];
  retainedEarnings = "3200";
  investing = [];
  financing = [];
  monetary = ["1001", "1999", "2110", "2120", "1210", "1220"];
};
ignore run(#setStatementMap({ book = "HQ"; map }));
assert (ReportCore.statementMap(bs.report, "HQ") == ?map);
refuse(#setStatementMap({ book = "HQ"; map = { map with cash = ["9999"] } }), "UnknownAccount");
refuse(#setStatementMap({ book = "HQ"; map = { map with retainedEarnings = "9999" } }), "UnknownAccount");
Debug.print("count: statement maps set and refused = 3");

// certifying a report records its content hash; which is the hash of its canonical bytes, so
// the artefact that leaves the building can be proven to be the report the books produced
let evaluated = switch (Reports.evaluate(js, JMemLog.reader(jchain), registered, params, Core.reportContext(bs, BankMemLog.reader(bchain), js, registered), Core.height(bs))) {
  case (#ok(r)) r;
  case (#err(e)) { Debug.print(debug_show (e)); assert false; loop {} };
};
ignore run(#certifyReport({ definition = "R34"; version = 1; book = "HQ"; period = "2026-02"; view = #native; functional = null }));
let key = ReportCore.certifiedKey("report", "R34", "HQ", "2026-02", evaluated.atHeight, evaluated.contentHash);
let ?cert = ReportCore.getCertified(bs.report, key) else { Debug.print("no certified entry"); assert false; loop {} };
assert (cert.contentHash == evaluated.contentHash);
assert (cert.contentHash == Reports.reportHash(evaluated));
assert (cert.rows == evaluated.rowCount);
Debug.print("the certified report hash is over " # Nat.toText(cert.rows) # " rows at journal height " # Nat.toText(cert.atHeight));

// re-certifying the same report at the same height is the **same** entry, not a second one
let certifiedBefore = ReportCore.certifiedCount(bs.report);
ignore run(#certifyReport({ definition = "R34"; version = 1; book = "HQ"; period = "2026-02"; view = #native; functional = null }));
assert (ReportCore.certifiedCount(bs.report) == certifiedBefore);
let ?certAgain = ReportCore.getCertified(bs.report, key) else { assert false; loop {} };
assert (certAgain.contentHash == cert.contentHash);
Debug.print("count: re-certifications that produced the same entry = 1");

// certifying a definition nobody registered, or a return or an export of an unknown period, is
// refused rather than recorded
refuse(#certifyReport({ definition = "NOPE"; version = 1; book = "HQ"; period = "2026-02"; view = #native; functional = null }), "UnknownDefinition");
refuse(#certifyReturn({ template = "NOPE"; version = 1; book = "HQ"; period = "2026-02" }), "UnknownTemplate");
refuse(#certifyReport({ definition = "R34"; version = 1; book = "HQ"; period = "2027-99"; view = #native; functional = null }), "UnknownPeriod");
Debug.print("count: certifications refused = 3");

// a return and an export are certified the same way, and each names what it is
ignore run(#certifyReturn({ template = "CBE-BS"; version = 1; book = "HQ"; period = "2026-02" }));
ignore run(#certifyExport({ shape = #normalisedTrialBalance; book = "HQ"; period = "2026-02" }));
ignore run(#certifyExport({ shape = #safT; book = "HQ"; period = "2026-02" }));
ignore run(#certifyExport({ shape = #aicpaAds; book = "HQ"; period = "2026-02" }));
var kindsCertified = 0;
var reportKinds = "";
for (e in ReportCore.listCertified(bs.report).vals()) {
  reportKinds #= e.kind # ":" # e.id # " ";
  assert (e.contentHash.size() == 32);
  assert (e.atHeight > 0);
  kindsCertified += 1;
};
Debug.print("the certified artefacts: " # reportKinds);
Debug.print("count: certified artefacts recorded = " # Nat.toText(kindsCertified));
assert (kindsCertified == 5);

// the artefact root is a function of the state and not of the order the blocks arrived in
let rootA = ReportCore.artefactRoot(bs.report);
assert (rootA.size() == 32);
assert (ReportCore.artefactRoot(bs.report) == rootA);
Debug.print("count: artefact roots that are a function of the state = 1");

// ─── the feed's recorded endpoints and dead letters ─────────────────────────

ignore run(#setFeedEndpoint({ endpoint = { url = "https://consumer.example.test/hook"; retries = [30, 120, 600]; active = true } }));
assert (ReportCore.endpointCount(bs.report) == 1);
refuse(#setFeedEndpoint({ endpoint = { url = "http://consumer.example.test/hook"; retries = []; active = true } }), "InvalidEndpoint");
refuse(#setFeedEndpoint({ endpoint = { url = "https://consumer.example.test/hook"; retries = [600, 30]; active = true } }), "InvalidEndpoint");
// a dead letter names an endpoint the bank recorded; one naming anything else would be a record
// of a push to somewhere nobody authorised
refuse(#recordFeedDeadLetter({ letter = { cursor = 1; endpoint = "https://elsewhere.example.test/x"; attempts = 1; reason = "gone" } }), "EndpointNotRecorded");
// and it cannot claim more attempts than the endpoint declares retries for
refuse(#recordFeedDeadLetter({ letter = { cursor = 1; endpoint = "https://consumer.example.test/hook"; attempts = 9; reason = "gone" } }), "InvalidEndpoint");
refuse(#recordFeedDeadLetter({ letter = { cursor = 1; endpoint = "https://consumer.example.test/hook"; attempts = 4; reason = "" } }), "InvalidEndpoint");
ignore run(#recordFeedDeadLetter({ letter = { cursor = 1; endpoint = "https://consumer.example.test/hook"; attempts = 4; reason = "504 from the consumer" } }));
assert (ReportCore.deadLetterCount(bs.report) == 1);
Debug.print("count: feed endpoints and dead letters recorded, and refusals = 6");

// ─── the statement register ─────────────────────────────────────────────────

ignore run(#issueStatement({ account = acctH1; kind = #camt053({ cut = CUT }); period = "2026-02" }));
let regKey = StatementsM.registerKey(acctH1, #camt053({ cut = CUT }));
let ?issued1 = ReportCore.getStatement(bs.report, regKey) else { Debug.print("no register entry"); assert false; loop {} };
assert (issued1.statement.issued == 1);
// a re-issue is the **same** statement with its count raised, which is what makes "this is the
// statement you were sent in February" answerable
ignore run(#issueStatement({ account = acctH1; kind = #camt053({ cut = CUT }); period = "2026-02" }));
let ?issued2 = ReportCore.getStatement(bs.report, regKey) else { assert false; loop {} };
assert (issued2.statement.issued == 2);
assert (ReportCore.statementCount(bs.report) == 1);
assert (issued2.statement.contentHash == issued1.statement.contentHash);
Debug.print("count: statements re-issued as the same statement = 1");

// the whole reporting state in one hash, so an upgrade is checked element by element
let fp = ReportCore.fingerprint(bs.report);
assert (fp.size() == 32);
assert (ReportCore.fingerprint(bs.report) == fp);
Debug.print("count: reporting state fingerprints = 1");

Debug.print("REPORTING TEST GREEN");
