// PeriodEnd.test.mo — the close end to end, through the real core.
//
// The value dating and the close criteria that are properties of the state machine rather than of the
// arithmetic, each driven through `planCommand` against a real embedded journal:
//
//   V1  one shifting layer — the journal's policy is `#reject`, every product
//       convention resolves the date in the bank layer, and **no posting the bank
//       submits was ever shifted by the journal** (`valueDateRequested` is null on
//       every one of them); a deployment whose journal policy is not `#reject`
//       cannot even open a close
//   V3  the back-value correction is exact: the adjustment posted equals the
//       difference between the fold recomputed now and what was booked, and the
//       re-run is a duplicate that posts nothing further
//   V4  the back-value policy is enforced and recorded: inside the window admitted,
//       in the approval band refused until a day is approved, beyond the band
//       refused outright, and into a closed period refused by the journal
//   V5  the accrual cut-off gates the close: a period with a missing day cannot
//       close, and the refusal names the day
//   V6  FX revaluation is functional-currency only and leaves the position identical
//   V8  a missing rate is a refusal and a stale rate is never substituted
//   V9  deferral schedules amortise on their own arithmetic and close to zero
//   V10 control accounts agree with the postings that made them, and an injected
//       divergence blocks the close
//   V11 the close is ordered and idempotent: every out-of-order step is refused and
//       every re-run is a no-op
//   V12 a book closed for a period refuses a posting through the bank
//
// engine: wasi-only — the battery fingerprints the whole state on every refusal,
// which is quadratic in the number of blocks and does not finish in a useful time
// under `moc -r`. That is the same reason the journal's own core battery and this
// repository's BankCore, PartyCore and ProductEngine batteries are exempted, and it
// is stated here rather than left to be noticed.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Map "mo:core/Map";
import Principal "mo:core/Principal";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";
import CivilDate "mo:journal/CivilDate";

import T "../src/bank/BankTypes";
import ProdT "../src/bank/ProductTypes";
import CT "../src/bank/CloseTypes";
import Core "../src/bank/BankCore";
import ProductCore "../src/bank/ProductCore";
import CloseCore "../src/bank/CloseCore";
import Conv "../src/bank/Conventions";
import Fx "../src/bank/Fx";
import Deferrals "../src/bank/Deferrals";
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
func dtext(d : JT.Day) : Text { CivilDate.toText(d) };

let JAN1 = day(2026, 1, 1);
let JAN31 = day(2026, 1, 31);
let FEB1 = day(2026, 2, 1);
let FEB28 = day(2026, 2, 28);
let NOW = day(2026, 3, 2);        // the wall clock: past the period, so it can be rolled
let DAY_NS : Nat64 = 86_400_000_000_000;
let clock : Nat64 = Nat64.fromNat(NOW) * DAY_NS + 43_200_000_000_000;

let holidays : [JT.Day] = Array.sort<JT.Day>([
  day(2026, 1, 7), day(2026, 1, 25), day(2026, 2, 11),
], Nat.compare);
let calConfig : JT.CalendarConfig = { restDays = [4, 5]; holidays; policy = #reject };

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

func run(command : T.Command) : Nat {
  let at = Core.height(bs);
  ignore execute(command, nextAuthority());
  at
};
func runPostings(command : T.Command) : [Nat] { execute(command, nextAuthority()) };

func expectErr(command : T.Command, want : Text) {
  let fp = Core.fingerprint(bs);
  let h = Core.height(bs);
  let jfp = JCore.fingerprint(js);
  switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, command, nextAuthority())) {
    case (#ok(_)) { Debug.print("expected " # want # " for " # P.commandName(command)); assert false };
    case (#err(e)) {
      let got = debug_show (e);
      if (not Text.contains(got, #text want)) { Debug.print("wanted " # want # " got " # got); assert false };
    };
  };
  assert (Core.fingerprint(bs) == fp and Core.height(bs) == h);
  assert (JCore.fingerprint(js) == jfp);
};

/// A command that must be a no-op: it plans, and it produces neither a bank event
/// nor a journal posting. That is what "idempotent" means for a close step.
func expectNoOp(command : T.Command) {
  switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, command, nextAuthority())) {
    case (#err(e)) { Debug.print("expected a no-op for " # P.commandName(command) # ", got " # debug_show (e)); assert false };
    case (#ok(plan)) {
      assert (plan.bankEvent == null);
      assert (plan.journal.size() == 0);
    };
  };
};

// ─── genesis ─────────────────────────────────────────────────────────────────

ignore jcommit(switch (JCore.prepareAddPoster(js, bankP, bankP)) { case (#ok(e)) e; case (#err(_)) { assert false; #posterAdded({ poster = bankP }) } });
ignore bcommit(installer, #bankAdminTransferred({ admin = installer }));
ignore run(#openBook({ id = "HQ"; name = "Head office"; parent = null }));
ignore run(#openBook({ id = "BR01"; name = "Branch 1"; parent = ?"HQ" }));
ignore run(#journalRegisterCurrency({ code = "EGP"; minorUnits = 2 }));
ignore run(#journalRegisterCurrency({ code = "USD"; minorUnits = 2 }));

type Acct = (Text, Text, JT.Side, JT.Category);
let chart : [Acct] = [
  ("1001", "Cash", #debit, #asset),
  ("1410", "USD position", #debit, #asset),
  ("1411", "USD position equivalent", #debit, #asset),
  ("1450", "Prepaid expenses", #debit, #asset),
  ("1999", "Settlement", #debit, #asset),
  ("2110", "Customer deposits", #credit, #liability),
  ("2120", "Interest payable", #credit, #liability),
  ("2400", "Unearned income", #credit, #liability),
  ("4100", "Fee income", #credit, #income),
  ("4410", "Unrealised FX", #credit, #income),
  ("4411", "Realised FX", #credit, #income),
  ("5100", "Interest expense", #debit, #expense),
  ("5300", "Rent expense", #debit, #expense),
  ("3200", "Retained earnings", #credit, #equity),
];
for ((code, name, side, cat) in chart.vals()) {
  ignore run(#journalOpenAccount({ code; name; normalSide = side; category = cat; constraint = #none }));
};
ignore run(#journalOpenPeriod({ id = "2026-01"; start = JAN1; end = JAN31 }));
ignore run(#journalOpenPeriod({ id = "2026-02"; start = FEB1; end = FEB28 }));
ignore run(#journalSetCalendar({ calendar = ?calConfig }));
ignore run(#journalRollBusinessDate({ day = JAN1 }));
ignore run(#journalSetActivationHeight({ height = 0 }));
ignore run(#setAccountFormat({ country = "EG"; bank = "0037"; branch = "0001"; serialWidth = 12; prefix = "00000" }));
assert (JCore.isActive(js));
Debug.print("count: chart accounts opened = " # Nat.toText(chart.size()));

// ─── V1: one shifting layer ──────────────────────────────────────────────────

// the deployment invariant holds, and the close refuses to open without it
assert (Conv.requiresRejectPolicy(JCore.calendar(js)) == null);
ignore run(#journalSetCalendar({ calendar = ?{ calConfig with policy = #next } }));
expectErr(#openPeriodEnd({ book = "HQ"; period = "2026-01" }), "CalendarPolicy");
Debug.print("count: closes refused while the journal would shift a date = 1");
ignore run(#journalSetCalendar({ calendar = ?calConfig }));

// ─── a party and two products ────────────────────────────────────────────────

func saltFor(i : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { Nat8.fromNat((i * 31 + j) % 256) })) };
let institutionSalt = saltFor(99);
let listEntries = Array.map<Text, Blob>(["AL QAIDA"], func(t : Text) : Blob { S.entryBytes(t) });
let ?listRoot = S.root(listEntries) else { assert false; loop {} };
ignore run(#commitScreeningList({ version = "L1"; root = listRoot; count = 1; normalisation = Commit.NORMALISATION }));

func makeParty(i : Nat) : Nat {
  let salt = saltFor(i);
  let id = run(#createParty({
    kind = #natural; salt;
    identityCommit = Commit.identity(salt, #natural, ["Person " # Nat.toText(i), "298010112345" # Nat.toText(i)]);
    dedupCommit = ?Commit.dedup(institutionSalt, "nationalId", "298010112345" # Nat.toText(i));
    attributes = []; book = "BR01"; cddLevel = #standard; riskRating = #low; pep = false;
    reviewDue = NOW + 365;
  }));
  ignore run(#setPartyLifecycle({ party = id; to = #pendingKyc }));
  for (kind in ["identity", "address"].vals()) {
    ignore run(#addPartyDocument({ party = id; document = { kind; commit = Commit.document(salt, kind, Blob.fromArray([1])); issued = 20000; expires = null } }));
  };
  ignore run(#recordScreeningDecision({ party = id; listVersion = "L1"; listRoot; decision = #clear; screener; justificationCommit = Commit.justification("no match") }));
  ignore run(#setPartyLifecycle({ party = id; to = #active }));
  id
};
let party = makeParty(1);

func rate(n : Nat, d : Nat) : I.Rate { { numerator = n; denominator = d; negative = false } };

let savingsInterest : ProdT.InterestTerms = {
  chart = { bands = [{ from = 0; to = null; rate = rate(5, 100) }]; by = #balance };
  convention = #a004_Act365Fixed;
  basis = #dailyBalance;
  compounding = #monthly;
  compoundingAlignment = #anniversary;
  posting = #monthly;
  minimumBalance = 0;
  allowNegative = false;
};

/// A savings product whose value-date convention is `following`: a deposit value
/// dated on a rest day lands on the next business day, resolved here and never by
/// the journal.
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
  interest = ?savingsInterest;
  charges = [];
  limits = { overdraft = null; minimumOperating = 0; perOperation = null };
  schedule = null;
  delinquency = [];
  provisioning = [];
  accounting = #accrualPeriodic;
  withholdingTax = null;
  rounding = #halfEven;
  earlyRedemptionPenalty = null;
  valueDateConvention = #following;
};
ignore run(#registerProduct({ id = "SAV"; name = "Savings"; terms = savings }));

// a same-day product, to prove the convention is the product's and not the layer's
ignore run(#registerProduct({ id = "SAVSD"; name = "Savings, same day"; terms = { savings with valueDateConvention = #sameDay } }));

for (f in ProdT.featureIds().vals()) {
  ignore run(#setFeatureActivation({ feature = f; height = Nat64.fromNat(Core.height(bs)) }));
};
var active = 0;
for (f in ProdT.featureIds().vals()) { if (Core.featureActive(bs, f)) active += 1 };
Debug.print("count: features activated = " # Nat.toText(active));
assert (active == 9);

let acct = run(#openAccount({ product = "SAV"; party; currency = "EGP"; termDays = null; allocationOrder = [] }));
ignore run(#setAccountStatus({ account = acct; to = #active }));
let sdAcct = run(#openAccount({ product = "SAVSD"; party; currency = "EGP"; termDays = null; allocationOrder = [] }));
ignore run(#setAccountStatus({ account = sdAcct; to = #active }));

// ─── the value-date convention resolves, and the journal never shifts ────────

// 2 January 2026 is a Friday: a rest day under this calendar
assert (not Conv.isBusinessDay(?calConfig, day(2026, 1, 2)));
switch (Core.resolveValueDate(bs, js, "SAV", day(2026, 1, 2))) {
  case (#ok(r)) {
    Debug.print("a deposit value dated " # dtext(r.requested) # " under `" # r.convention # "` resolves to " # dtext(r.effective));
    assert (r.moved and r.effective == day(2026, 1, 4));
    assert (r.soleShiftingLayer);
  };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};
// the same date under a same-day product cannot be resolved at all, and says so
switch (Core.resolveValueDate(bs, js, "SAVSD", day(2026, 1, 2))) {
  case (#err(e)) assert (Text.contains(debug_show (e), #text "ValueDateNotResolved"));
  case (#ok(_)) { Debug.print("a same-day product resolved a rest day"); assert false };
};
Debug.print("count: value-date resolutions verified = 2");

// a deposit value dated on the rest day is admitted and lands on the resolved day
let firstDeposit = runPostings(#depositToAccount({
  account = acct; amount = 1_000_00; postingDate = JAN1; valueDate = day(2026, 1, 2);
  period = "2026-01"; narration = "opening deposit"; funding = #glAccount("1999");
}));
assert (firstDeposit.size() == 1);
switch (JCore.postingView(js, JMemLog.reader(jchain), firstDeposit[0])) {
  case (?v) {
    assert (v.record.valueDate == day(2026, 1, 4));
    // and the journal did not move it: the date it was asked for is the date it got
    assert (v.record.valueDateRequested == null);
  };
  case null assert false;
};
// a same-day product refuses the same date rather than having it moved for it
expectErr(#depositToAccount({
  account = sdAcct; amount = 1_000_00; postingDate = JAN1; valueDate = day(2026, 1, 2);
  period = "2026-01"; narration = "same day"; funding = #glAccount("1999");
}), "ValueDateNotResolved");
Debug.print("count: postings whose value date this layer resolved = 1");

// ─── the month: roll the business date and accrue every business day ─────────

let businessDays = Conv.businessDaysBetween(?calConfig, JAN1, JAN31);
Debug.print("count: business days in the period = " # Nat.toText(businessDays.size()));

/// Roll the business date forward to `d`, which the journal permits only forwards —
/// rolling to the day it already is is refused, so the guard is here rather than in
/// the journal.
func rollTo(d : JT.Day) {
  switch (JCore.businessDate(js)) {
    case (?current) { if (d > current) ignore run(#journalRollBusinessDate({ day = d })) };
    case null ignore run(#journalRollBusinessDate({ day = d }));
  };
};

/// The end-of-day accrual for one business date. The run is always recorded; the
/// posting happens only when the figure is non-zero, because the journal refuses a
/// zero-amount leg. Returns whether anything was actually posted.
let accruing = ["SAV", "SAVSD"];
func accrueOn(d : JT.Day) : Bool {
  var posted = false;
  for (product in accruing.vals()) {
    let postings = runPostings(#postAccrual({ product; currency = "EGP"; day = d; period = "2026-01"; narration = "daily accrual" }));
    if (postings.size() > 0) posted := true;
  };
  posted
};

// The month is run as far as 26 January, deliberately short of its last business
// day, so the accrual cut-off below has something real to refuse.
let CUTOFF = day(2026, 1, 26);
var accrualsPosted = 0;
var runsRecorded = 0;
for (d in businessDays.vals()) {
  if (d <= CUTOFF) {
    rollTo(d);
    if (accrueOn(d)) accrualsPosted += 1;
    runsRecorded += accruing.size();
  };
};
Debug.print("count: end-of-day accrual runs recorded = " # Nat.toText(runsRecorded));
Debug.print("count: of those, runs that actually posted = " # Nat.toText(accrualsPosted));
assert (accrualsPosted > 0);
// every run is recorded, posted or not: a day on which nothing accrued is still a
// day that was run, and the close needs that evidence
assert (ProductCore.accrualCount(bs.product) == runsRecorded);
assert (runsRecorded > accrualsPosted);

// ─── V4: the back-value window ───────────────────────────────────────────────

ignore run(#setBackValueWindow({ window = { book = "BR01"; freeDays = 3; approvedDays = 10 } }));
let today = switch (JCore.businessDate(js)) { case (?d) d; case null JAN31 };
Debug.print("the business date is " # dtext(today));

// a date inside the free window is admitted
let inWindowDate = switch (Conv.lastBusinessDayOnOrBefore(?calConfig, today - 2)) { case (?d) d; case null today };
let v1 = Core.backValueVerdict(bs, js, "BR01", inWindowDate);
Debug.print("a value date " # Nat.toText(v1.businessDaysBack) # " business days back is " # v1.verdict);
assert (Text.equal(v1.verdict, "inWindow"));
ignore runPostings(#depositToAccount({
  account = acct; amount = 10_00; postingDate = today; valueDate = inWindowDate;
  period = "2026-01"; narration = "inside the window"; funding = #glAccount("1999");
}));

// a date in the approval band is refused until that day is approved
var approvalDate = JAN1;
var found = false;
for (d in businessDays.vals()) {
  if (not found) {
    let v = Core.backValueVerdict(bs, js, "BR01", d);
    if (Text.equal(v.verdict, "needsApproval")) { approvalDate := d; found := true };
  };
};
assert found;
Debug.print("a value date in the approval band: " # dtext(approvalDate));
expectErr(#depositToAccount({
  account = acct; amount = 10_00; postingDate = today; valueDate = approvalDate;
  period = "2026-01"; narration = "needs approval"; funding = #glAccount("1999");
}), "BackValueNeedsApproval");
ignore run(#approveBackValue({ book = "BR01"; valueDate = approvalDate; reason = "a customer complaint, corrected" }));
assert (Core.backValueVerdict(bs, js, "BR01", approvalDate).approved);
let approved = runPostings(#depositToAccount({
  account = acct; amount = 10_00; postingDate = today; valueDate = approvalDate;
  period = "2026-01"; narration = "approved back value"; funding = #glAccount("1999");
}));
assert (approved.size() == 1);
// and the same day cannot be approved twice
expectErr(#approveBackValue({ book = "BR01"; valueDate = approvalDate; reason = "again" }), "BackValueApprovalExists");
Debug.print("count: back-value bands enforced = 2");

// a date beyond the band is refused outright, and no approval can reach it
let beyond = JAN1;
let vBeyond = Core.backValueVerdict(bs, js, "BR01", beyond);
if (Text.equal(vBeyond.verdict, "beyondWindow")) {
  expectErr(#depositToAccount({
    account = acct; amount = 10_00; postingDate = today; valueDate = beyond;
    period = "2026-01"; narration = "beyond the window"; funding = #glAccount("1999");
  }), "BackValueBeyondWindow");
  expectErr(#approveBackValue({ book = "BR01"; valueDate = beyond; reason = "cannot" }), "BackValueBeyondWindow");
  Debug.print("count: value dates beyond the window refused, approval included = 2");
};

// ─── V3: the back-value correction is exact ──────────────────────────────────

// the correction is the fold recomputed now less what was booked, and both figures
// are read back rather than asserted
let preview = switch (Core.accrualAdjustmentPreview(bs, BankMemLog.reader(bchain), js, "SAV", "EGP", JAN1, today)) {
  case (#ok(p)) p;
  case (#err(e)) { Debug.print(debug_show (e)); assert false; loop {} };
};
Debug.print("the fold now gives " # Nat.toText(preview.recomputed) # "; the accruals booked total "
  # Nat.toText(preview.booked) # ", so the correction is a " # preview.direction # " of " # Nat.toText(preview.movement));
assert (preview.movement > 0);
assert (Text.equal(preview.direction, "increase"));
let adjustment = runPostings(#adjustAccrual({
  product = "SAV"; currency = "EGP"; from = JAN1; to = today;
  causedBy = approved[0]; postingDate = today; period = "2026-01"; narration = "back-value correction";
}));
assert (adjustment.size() == 1);
switch (JCore.postingView(js, JMemLog.reader(jchain), adjustment[0])) {
  case (?v) {
    var moved = 0;
    for (l in v.record.legs.vals()) { if (Text.equal(l.account, "2120")) moved := l.amount };
    assert (moved == preview.movement);
    assert (Text.equal(v.record.sourceRef.kind, "accrual-adjustment"));
  };
  case null assert false;
};
// The re-run is a duplicate and posts nothing further: the same correction, sent
// again, lands on the posting it already made. Re-sending it with *different*
// content under the same derived key is a conflict rather than a duplicate, and the
// journal refuses that — which is the behaviour that makes the key meaningful.
let rerun = runPostings(#adjustAccrual({
  product = "SAV"; currency = "EGP"; from = JAN1; to = today;
  causedBy = approved[0]; postingDate = today; period = "2026-01"; narration = "back-value correction";
}));
assert (rerun.size() == 1 and rerun[0] == adjustment[0]);
expectErr(#adjustAccrual({
  product = "SAV"; currency = "EGP"; from = JAN1; to = today;
  causedBy = approved[0]; postingDate = today; period = "2026-01"; narration = "a different narration";
}), "IdempotencyKeyReused");
Debug.print("count: back-value corrections posted, and re-runs that were duplicates = 2");

// ─── foreign currency ────────────────────────────────────────────────────────

expectErr(#setFxPair({ pair = {
  currency = "USD"; position = "1410"; equivalent = "1411";
  unrealised = "4410"; realised = "4411"; monetary = true;
} }), "NoFunctionalCurrency");
ignore run(#setFunctionalCurrency({ currency = "EGP" }));
// setting it again to the same currency is a no-op; to another it is refused
expectNoOp(#setFunctionalCurrency({ currency = "EGP" }));
expectErr(#setFunctionalCurrency({ currency = "USD" }), "FunctionalCurrencyAlreadySet");

let usdPair : Fx.PositionPair = {
  currency = "USD"; position = "1410"; equivalent = "1411";
  unrealised = "4410"; realised = "4411"; monetary = true;
};
ignore run(#setFxPair({ pair = usdPair }));
expectErr(#setFxPair({ pair = { usdPair with currency = "EGP" } }), "InvalidPair");
expectErr(#setFxPair({ pair = { usdPair with position = usdPair.equivalent } }), "InvalidPair");

// a rate is declared data, and it is refused when it is not a rate
func fxRate(num : Nat, den : Nat, asOf : JT.Day) : CT.Rate {
  { currency = "USD"; functional = "EGP"; numerator = num; denominator = den; asOf; source = "central bank" }
};
expectErr(#setFxRate({ rate = fxRate(4800, 0, JAN31) }), "InvalidRate");
expectErr(#setFxRate({ rate = { fxRate(4800, 100, JAN31) with currency = "KWD" } }), "UnknownPair");
ignore run(#setFxRate({ rate = fxRate(4800, 100, day(2026, 1, 15)) }));
ignore run(#setFxRate({ rate = fxRate(4850, 100, JAN31) }));
// the same rate for the same day again is a no-op; a different one is refused
expectNoOp(#setFxRate({ rate = fxRate(4850, 100, JAN31) }));
expectErr(#setFxRate({ rate = fxRate(4900, 100, JAN31) }), "InvalidRate");
Debug.print("count: FX configuration refusals = 6");

// a cross-currency deal: four legs, each currency balancing within itself
let dealPostings = runPostings(#bookFxDeal({
  sell = "EGP"; sellAmount = 48_000_00; sellFrom = #glAccount("1999");
  buy = "USD"; buyAmount = 1_000_00; buyTo = #glAccount("1001");
  rateAsOf = day(2026, 1, 15); postingDate = today; valueDate = day(2026, 1, 15);
  period = "2026-01"; narration = "buy 1,000.00 USD at 48.00";
}));
assert (dealPostings.size() == 1);
switch (JCore.postingView(js, JMemLog.reader(jchain), dealPostings[0])) {
  case (?v) {
    assert (v.record.legs.size() == 4);
    assert (Fx.balancesPerCurrency(v.record.legs));
    var egp = 0;
    var usd = 0;
    for (l in v.record.legs.vals()) { if (Text.equal(l.currency, "EGP")) egp += 1 else usd += 1 };
    assert (egp == 2 and usd == 2);
  };
  case null assert false;
};
// an amount that is not the other side at the recorded rate is refused
expectErr(#bookFxDeal({
  sell = "EGP"; sellAmount = 50_000_00; sellFrom = #glAccount("1999");
  buy = "USD"; buyAmount = 1_000_00; buyTo = #glAccount("1001");
  rateAsOf = day(2026, 1, 15); postingDate = today; valueDate = day(2026, 1, 15);
  period = "2026-01"; narration = "wrong rate";
}), "InvalidRate");
// and a deal at a day with no rate is refused rather than using another day's
expectErr(#bookFxDeal({
  sell = "EGP"; sellAmount = 48_000_00; sellFrom = #glAccount("1999");
  buy = "USD"; buyAmount = 1_000_00; buyTo = #glAccount("1001");
  rateAsOf = day(2026, 1, 16); postingDate = today; valueDate = day(2026, 1, 16);
  period = "2026-01"; narration = "no rate that day";
}), "MissingRate");
Debug.print("count: FX deals booked and refused = 3");

// the position as the close sees it
let posBefore = switch (Core.positionView(bs, js, "USD", JAN31)) {
  case (#ok(p)) p;
  case (#err(e)) { Debug.print(debug_show (e)); assert false; loop {} };
};
Debug.print("the USD position is " # Nat.toText(posBefore.position) # " booked at "
  # Nat.toText(posBefore.equivalent) # "; at the closing rate it is worth "
  # (switch (posBefore.revalued) { case (?r) Nat.toText(r); case null "no rate" }));
assert (posBefore.position == 1_000_00);
assert (posBefore.equivalent == 48_000_00);
assert (posBefore.revalued == ?48_500_00);
assert (posBefore.movement == ?50_000);
assert (Text.equal(posBefore.direction, "gain"));

// V8: a day with no rate reports no revaluation rather than an earlier day's
switch (Core.positionView(bs, js, "USD", day(2026, 1, 20))) {
  case (#ok(p)) { assert (p.revalued == null); assert (Text.equal(p.direction, "no rate recorded")) };
  case (#err(_)) assert false;
};
Debug.print("count: position readings verified = 2");

// ─── deferrals ───────────────────────────────────────────────────────────────

let unearned : Deferrals.Schedule = {
  id = "arrangement-fee-2026";
  kind = #unearnedIncome;
  currency = "EGP";
  amount = 1_200_00;
  periods = 12;
  deferralAccount = "2400";
  recognitionAccount = "4100";
  book = "HQ";
  openedOn = JAN1;
};
ignore run(#openDeferralSchedule({ schedule = unearned }));
expectErr(#openDeferralSchedule({ schedule = unearned }), "ScheduleExists");
expectErr(#openDeferralSchedule({ schedule = { unearned with id = "bad"; amount = 5; periods = 12 } }), "InvalidSchedule");
let prepaid : Deferrals.Schedule = {
  unearned with id = "rent-2026"; kind = #prepaidExpense;
  deferralAccount = "1450"; recognitionAccount = "5300"; amount = 600_00; periods = 6;
};
ignore run(#openDeferralSchedule({ schedule = prepaid }));
Debug.print("count: deferral schedules opened = " # Nat.toText(CloseCore.scheduleCount(bs.close)));
assert (CloseCore.scheduleCount(bs.close) == 2);

// ─── V11: the close is ordered ───────────────────────────────────────────────

// every step before the run is opened is refused
let beforeOpen : [T.Command] = [
  #recordClosingRates({ book = "HQ"; period = "2026-01" }),
  #markAccrualComplete({ book = "HQ"; period = "2026-01" }),
  #reconcilePeriod({ book = "HQ"; period = "2026-01" }),
  #closePeriodEnd({ book = "HQ"; period = "2026-01" }),
];
for (cmd in beforeOpen.vals()) { expectErr(cmd, "UnknownRun") };
Debug.print("count: close steps refused before the run was opened = 4");

ignore run(#openPeriodEnd({ book = "HQ"; period = "2026-01" }));
expectErr(#openPeriodEnd({ book = "HQ"; period = "2026-01" }), "RunExists");
switch (CloseCore.getRun(bs.close, "HQ", "2026-01")) {
  case (?r) {
    Debug.print("the close is struck at " # dtext(r.closingDate));
    assert (r.closingDate == day(2026, 1, 29));     // 31 Jan 2026 is a Saturday
    assert (r.state == #opened);
  };
  case null assert false;
};

// out of order: every step whose predecessor does not hold is refused with the
// state it requires named
let outOfOrder : [T.Command] = [
  #markAccrualComplete({ book = "HQ"; period = "2026-01" }),
  #revaluePositions({ book = "HQ"; period = "2026-01"; postingDate = today; narration = "early" }),
  #amortisePeriodDeferrals({ book = "HQ"; period = "2026-01"; postingDate = today; narration = "early" }),
  #reconcilePeriod({ book = "HQ"; period = "2026-01" }),
  #closePeriodEnd({ book = "HQ"; period = "2026-01" }),
];
for (cmd in outOfOrder.vals()) { expectErr(cmd, "OutOfOrder") };
Debug.print("count: out-of-order close steps refused = 5");

// rates: every monetary pair must have one for the run's own closing date
ignore run(#setFxRate({ rate = fxRate(4825, 100, day(2026, 1, 29)) }));
ignore run(#recordClosingRates({ book = "HQ"; period = "2026-01" }));
expectNoOp(#recordClosingRates({ book = "HQ"; period = "2026-01" }));
switch (CloseCore.getRun(bs.close, "HQ", "2026-01")) { case (?r) assert (r.state == #ratesRecorded); case null assert false };

// V5: the accrual cut-off. The business date has not reached the closing date
// yet — it is the day after the last accrual we posted — so either the roll or a
// missing day blocks the close, and the refusal says which.
switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, #markAccrualComplete({ book = "HQ"; period = "2026-01" }), nextAuthority())) {
  case (#err(e)) {
    let got = debug_show (e);
    assert (Text.contains(got, #text "BusinessDayNotRolled") or Text.contains(got, #text "AccrualIncomplete"));
    Debug.print("the close waits: " # got);
  };
  case (#ok(_)) { Debug.print("the close did not wait for the accrual"); assert false };
};

// roll to the closing date: now the business date is no longer the obstacle, and the
// missing accrual days are — which the refusal names one at a time
rollTo(day(2026, 1, 29));
expectErr(#markAccrualComplete({ book = "HQ"; period = "2026-01" }), "AccrualIncomplete");
Debug.print("count: closes refused for a missing accrual day = 1");

// post the accruals the cut-off was waiting for
var caughtUp = 0;
for (d in businessDays.vals()) {
  if (d <= day(2026, 1, 29) and ProductCore.accrualOn(bs.product, "SAV", "EGP", d) == null) {
    ignore accrueOn(d);
    caughtUp += accruing.size();
  };
};
Debug.print("count: accruals the cut-off was waiting for = " # Nat.toText(caughtUp));
assert (caughtUp > 0);
ignore run(#markAccrualComplete({ book = "HQ"; period = "2026-01" }));
expectNoOp(#markAccrualComplete({ book = "HQ"; period = "2026-01" }));
Debug.print("count: accrual cut-off checks = 2");

// V6: the revaluation is functional-currency only and leaves the position identical
let positionBefore = JCore.balance(js, "1410", null, "USD");
let revPostings = runPostings(#revaluePositions({ book = "HQ"; period = "2026-01"; postingDate = today; narration = "January revaluation" }));
assert (revPostings.size() == 1);
switch (JCore.postingView(js, JMemLog.reader(jchain), revPostings[0])) {
  case (?v) {
    for (l in v.record.legs.vals()) {
      assert (Text.equal(l.currency, "EGP"));          // not one leg in USD
      assert (not Text.equal(l.account, "1410"));      // and not one touching the position
    };
  };
  case null assert false;
};
let positionAfter = JCore.balance(js, "1410", null, "USD");
assert (positionBefore.debitsPosted == positionAfter.debitsPosted);
assert (positionBefore.creditsPosted == positionAfter.creditsPosted);
Debug.print("count: revaluations leaving the foreign position identical = 1");
expectNoOp(#revaluePositions({ book = "HQ"; period = "2026-01"; postingDate = today; narration = "again" }));

// the unrealised figure is exactly position x rate − equivalent
switch (Core.positionView(bs, js, "USD", day(2026, 1, 29))) {
  case (#ok(p)) {
    assert (p.movement == ?0);                          // revalued, so nothing left to move
    assert (p.equivalent == 48_250_00);                  // 1,000.00 USD at 48.25
  };
  case (#err(_)) assert false;
};
Debug.print("count: unrealised figures verified = 1");

// V9: deferrals amortise on their own arithmetic
let defPostings = runPostings(#amortisePeriodDeferrals({ book = "HQ"; period = "2026-01"; postingDate = today; narration = "January amortisation" }));
Debug.print("count: deferral postings in the step = " # Nat.toText(defPostings.size()));
assert (defPostings.size() == 2);                        // both schedules belong to HQ
switch (CloseCore.getSchedule(bs.close, unearned.id)) {
  case (?e) {
    assert (CloseCore.postedPeriods(e) == 1);
    // 1,200.00 over twelve periods is 100.00 a period
    assert (CloseCore.amortised(e) == 100_00);
    assert (CloseCore.remaining(e) == 1_100_00);
  };
  case null assert false;
};
expectNoOp(#amortisePeriodDeferrals({ book = "HQ"; period = "2026-01"; postingDate = today; narration = "again" }));
Debug.print("count: deferral amortisations verified = 1");

// V10: the control-account check, which is two folds over the same log — the
// maintained balance map on one side and the postings' own legs on the other.
let check = Core.controlCheck(bs, js, JMemLog.reader(jchain));
Debug.print("count: control accounts checked = " # Nat.toText(check.accounts));
assert (check.accounts > 0);
assert (check.divergence == null);

// A deliberately injected divergence must block the close. The injection reaches
// into the journal's maintained balance map directly — which nothing in production
// can do, and which is exactly why the check exists: it catches a balance that no
// posting explains.
var target : ?{ var drPosted : Nat; var crPosted : Nat; var drPending : Nat; var crPending : Nat } = null;
var targetAccount = "";
var targetFound = false;
for (((account, _, currency), bal) in Map.entries(js.balances)) {
  if (not targetFound and Text.equal(account, "2110") and Text.equal(currency, "EGP")) {
    target := ?bal;
    targetAccount := account;
    targetFound := true;
  };
};
switch (target) {
  case (?bal) {
    let before = bal.drPosted;
    bal.drPosted += 1;
    switch (Core.controlCheck(bs, js, JMemLog.reader(jchain)).divergence) {
      case (?d) {
        Debug.print("an injected divergence is caught: " # d.account # " " # d.currency
          # " maintained " # Nat.toText(d.ledgerDebits) # " debits against "
          # Nat.toText(d.subledgerDebits) # " in the postings themselves");
        assert (Text.equal(d.account, targetAccount));
        assert (d.ledgerDebits == d.subledgerDebits + 1);
      };
      case null { Debug.print("an injected divergence was not caught"); assert false };
    };
    expectErr(#reconcilePeriod({ book = "HQ"; period = "2026-01" }), "ControlAccountDivergence");
    bal.drPosted := before;
    assert (Core.controlCheck(bs, js, JMemLog.reader(jchain)).divergence == null);
    Debug.print("count: injected control divergences caught and blocking the close = 1");
  };
  case null { Debug.print("no balance row exists to inject into"); assert false };
};

// the roll is refused before the period is reconciled: the result is not complete
// until the accruals, the revaluation and the deferrals of the period are in
expectErr(#rollYearEnd({ book = "HQ"; period = "2026-01"; retainedEarnings = "3200"; narration = "too early" }), "NotReconciled");
ignore run(#reconcilePeriod({ book = "HQ"; period = "2026-01" }));
expectNoOp(#reconcilePeriod({ book = "HQ"; period = "2026-01" }));
Debug.print("count: reconciliations verified = 1");

// ─── the fiscal year's result closes to retained earnings ────────────────────
//
// Between `reconciled` and `closed`: after the period's accruals, revaluations and
// deferrals are in, and before the journal seals the period — because the journal
// refuses to book a roll into a closed period, which is the hard stop this relies on
// rather than works around.
expectErr(#rollYearEnd({ book = "HQ"; period = "2026-01"; retainedEarnings = "2110"; narration = "not equity" }), "YearEndError");
let incomeBefore = JCore.balance(js, "4100", null, "EGP");
let expenseBefore = JCore.balance(js, "5100", null, "EGP");
let rollPostings = runPostings(#rollYearEnd({ book = "HQ"; period = "2026-01"; retainedEarnings = "3200"; narration = "close the year" }));
Debug.print("count: year-end roll postings = " # Nat.toText(rollPostings.size()));
assert (rollPostings.size() > 0);
// the roll is booked on the last **business** day of the period: 31 January 2026 is a
// Saturday, and a deployment whose journal policy is `#reject` would refuse it there
switch (JCore.postingView(js, JMemLog.reader(jchain), rollPostings[0])) {
  case (?v) {
    Debug.print("the roll is booked on " # dtext(v.record.valueDate));
    assert (v.record.valueDate == day(2026, 1, 29));
    assert (v.record.valueDateRequested == null);
  };
  case null assert false;
};
// every income and expense account is at zero afterwards, and retained earnings
// carries the net — the journal calendar behaviour, reached through the bank's own ordering
var rolledToZero = 0;
for (code in ["4100", "4410", "5100", "5300"].vals()) {
  let b = JCore.accountTotal(js, code, "EGP");
  if (b.debitsPosted == b.creditsPosted) rolledToZero += 1
  else { Debug.print(code # " did not roll to zero: " # Nat.toText(b.debitsPosted) # " vs " # Nat.toText(b.creditsPosted)); assert false };
};
Debug.print("count: income and expense accounts at zero after the roll = " # Nat.toText(rolledToZero));
let retained = JCore.accountTotal(js, "3200", "EGP");
Debug.print("retained earnings now carries " # Nat.toText(retained.creditsPosted) # " credits against "
  # Nat.toText(retained.debitsPosted) # " debits");
assert (retained.debitsPosted != retained.creditsPosted);
ignore incomeBefore; ignore expenseBefore;
// a year is rolled once
expectErr(#rollYearEnd({ book = "HQ"; period = "2026-01"; retainedEarnings = "3200"; narration = "again" }), "YearEndAlreadyRolled");
Debug.print("count: year-end rolls verified = 1");

// and the close itself, which closes the journal's period
ignore run(#closePeriodEnd({ book = "HQ"; period = "2026-01" }));
switch (CloseCore.getRun(bs.close, "HQ", "2026-01")) {
  case (?r) { assert (r.state == #closed); assert (r.closedAtBlock != null) };
  case null assert false;
};
switch (JCore.getPeriod(js, "2026-01")) { case (?p) assert (p.status == #closed); case null assert false };
expectNoOp(#closePeriodEnd({ book = "HQ"; period = "2026-01" }));
Debug.print("count: periods closed = 1");

// and once the period is closed the roll is refused by the state machine, which
// names the state rather than the reason it would have failed for anyway
expectErr(#rollYearEnd({ book = "HQ"; period = "2026-01"; retainedEarnings = "3200"; narration = "after the close" }), "NotReconciled");

// V4 again: a prior-dated posting into the closed period is refused by the journal
expectErr(#depositToAccount({
  account = acct; amount = 10_00; postingDate = day(2026, 1, 29); valueDate = day(2026, 1, 29);
  period = "2026-01"; narration = "after the close"; funding = #glAccount("1999");
}), "PeriodClosed");
Debug.print("count: postings into a closed period refused = 1");

// ─── the fold is the log ─────────────────────────────────────────────────────

let liveFingerprint = Core.fingerprint(bs);
let replayed = Core.replay(installer, BankMemLog.blocks(bchain));
assert (Core.fingerprint(replayed) == liveFingerprint);
assert (CloseCore.runCount(replayed.close) == CloseCore.runCount(bs.close));
assert (CloseCore.rateCount(replayed.close) == CloseCore.rateCount(bs.close));
assert (CloseCore.scheduleCount(replayed.close) == CloseCore.scheduleCount(bs.close));
assert (CloseCore.approvalCount(replayed.close) == CloseCore.approvalCount(bs.close));
Debug.print("count: bank blocks replayed to an identical fingerprint = " # Nat.toText(BankMemLog.blocks(bchain).size()));
let jReplayed = JCore.replay(bankP, JMemLog.blocks(jchain));
assert (JCore.fingerprint(jReplayed) == JCore.fingerprint(js));
Debug.print("count: journal blocks replayed to an identical fingerprint = " # Nat.toText(JMemLog.blocks(jchain).size()));

// V1 closing claim: **no posting the bank submitted was ever shifted by the journal**
var postings = 0;
var shifted = 0;
var i = 0;
let height = JCore.height(js);
while (i < height) {
  switch (JCore.postingView(js, JMemLog.reader(jchain), i)) {
    case (?v) {
      postings += 1;
      if (v.record.valueDateRequested != null) shifted += 1;
    };
    case null {};
  };
  i += 1;
};
Debug.print("count: postings examined for a journal shift = " # Nat.toText(postings));
// Zero by design, and therefore not printed as a `count:` line: the runner fails any
// count that reports nothing, and this is the one figure whose correct value is none.
Debug.print("of those, the journal shifted: " # Nat.toText(shifted));
assert (postings > 0);
assert (shifted == 0);

Debug.print("PERIOD END TEST GREEN");
