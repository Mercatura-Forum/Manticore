// Products.test.mo — the product engine's pure arithmetic and validation.
//
// Everything in the product engine that is a function rather than a state machine, proved on its
// own terms before the state machine uses it:
//
//   * registration validates the role-to-account map against the real chart of
//     accounts — every role requires a category, and a product whose mapping breaks
//     one of them is refused with the role, the account and both categories named
//     (criterion F1, which reproduces Fineract's per-slot rejection);
//   * rate charts must partition the space: a gap is a balance with no rate and an
//     overlap is two, and both are refused when the product is written;
//   * schedule generation is exact — the principal column sums to the advance, the
//     closing balance is zero, and every row opens where the previous closed, for
//     each amortisation method, with grace and a moratorium (criterion F6);
//   * charges compute from a declared base and refuse to compute from a missing
//     one; a charge that rounds to zero is not a posting (criterion F5);
//   * a repayment allocation settles the declared components in the declared order
//     and reports an overpayment rather than absorbing it;
//   * arrears and delinquency bands are a cumulative fold, so a back-dated
//     repayment needs no recalculation (criterion F7);
//   * a term deposit's maturity value compounds exactly, and an early redemption
//     recomputes at the penalised rate and reports the shortfall (criterion F8);
//   * a till settled short posts its difference to suspense and can never absorb
//     it, because the suspense leg is what makes the posting balance (I10).
//
// engine: wasi-only — the journal core now keeps its per-posting state in a stable-memory Region, and
// the moc interpreter provides no Region. The dual-engine check this loses was worth having, and the
// loss is stated rather than hidden: the reason the state moved is that a heap map per posting makes
// the heap grow with the journal. Every test below still runs under wasmtime, the engine the chain runs.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Principal "mo:core/Principal";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";
import CivilDate "mo:journal/CivilDate";

import T "../src/bank/ProductTypes";
import I "../src/bank/Interest";
import Products "../src/bank/Products";
import Charges "../src/bank/Charges";
import Loans "../src/bank/Loans";
import TermProducts "../src/bank/TermProducts";
import Till "../src/bank/Till";
import Posting "../src/bank/Posting";
import Limits "../src/bank/Limits";
import JMemLog "support/JournalMemLog";

// ─── a chart of accounts to validate against ─────────────────────────────────

let bankP = Principal.fromBlob("\BA\01");
let jchain = JMemLog.new();
let js = JCore.newState(bankP);
let clock : Nat64 = 1_788_000_000_000_000_000;

func jcommit(e : JT.Event) : JT.Block { JMemLog.commit(jchain, js, clock, bankP, e) };
func jok(r : { #ok : JT.Event; #err : JT.ConfigError }) {
  switch (r) { case (#ok(e)) ignore jcommit(e); case (#err(e)) { Debug.print("journal config failed: " # debug_show (e)); assert false } };
};

jok(JCore.prepareAddPoster(js, bankP, bankP));
jok(JCore.prepareRegisterCurrency(js, bankP, "EGP", 2 : Nat8));
jok(JCore.prepareRegisterCurrency(js, bankP, "USD", 2 : Nat8));

type Acct = (Text, Text, JT.Side, JT.Category);
let chart : [Acct] = [
  ("1001", "Cash and vault", #debit, #asset),
  ("1210", "Loan portfolio", #debit, #asset),
  ("1220", "Interest receivable", #debit, #asset),
  ("1230", "Fees receivable", #debit, #asset),
  ("1240", "Penalties receivable", #debit, #asset),
  ("1290", "Allowance for credit losses", #debit, #asset),
  ("1300", "Overdraft portfolio", #debit, #asset),
  ("1900", "Suspense", #debit, #asset),
  ("2110", "Customer deposits", #credit, #liability),
  ("2120", "Interest payable", #credit, #liability),
  ("2300", "Withholding tax payable", #credit, #liability),
  ("3100", "Share capital", #credit, #equity),
  ("4100", "Fee income", #credit, #income),
  ("4110", "Penalty income", #credit, #income),
  ("4200", "Interest income", #credit, #income),
  ("4300", "Recoveries", #credit, #income),
  ("5100", "Interest expense", #debit, #expense),
  ("5200", "Impairment expense", #debit, #expense),
  ("5210", "Loans written off", #debit, #expense),
  ("9000", "Assets (header)", #debit, #asset),
];
for ((code, name, side, cat) in chart.vals()) {
  jok(JCore.prepareOpenAccount(js, bankP, code, name, side, cat, #none));
};
jok(JCore.prepareSetAccountAttributes(js, bankP, "9000", { usage = #header; manualEntriesAllowed = false; parent = null }));
Debug.print("count: chart accounts opened = " # Nat.toText(chart.size()));

// ─── product fixtures ────────────────────────────────────────────────────────

func rate(n : Nat, d : Nat) : I.Rate { { numerator = n; denominator = d; negative = false } };
func neg(n : Nat, d : Nat) : I.Rate { { numerator = n; denominator = d; negative = true } };
func flatChart(r : I.Rate) : T.RateChart { { bands = [{ from = 0; to = null; rate = r }]; by = #balance } };

let savingsInterest : T.InterestTerms = {
  chart = flatChart(rate(5, 100));
  convention = #a004_Act365Fixed;
  basis = #dailyBalance;
  compounding = #monthly;
  compoundingAlignment = #anniversary;
  posting = #monthly;
  minimumBalance = 0;
  allowNegative = false;
};

let savingsRoles : [T.RoleMapping] = [
  { role = #principal; account = "2110" },
  { role = #interestPayable; account = "2120" },
  { role = #interestExpense; account = "5100" },
  { role = #feeIncome; account = "4100" },
];

let savings : T.ProductTerms = {
  kind = #savings;
  currency = "EGP";
  control = "2110";
  roles = savingsRoles;
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

assert (Products.validateTerms(js, "SAV", savings) == null);
Debug.print("count: valid products accepted = 1");

// ─── 1. the role-to-account category check ───────────────────────────────────
//
// Each role requires a category. A mapping that breaks one is refused with the
// role, the account, and both categories named — which is what makes the refusal
// actionable rather than only correct.

var categoryRefusals = 0;
let wrongSlots : [(T.Role, JT.AccountCode, Text, Text)] = [
  (#interestPayable, "4100", "liability", "income"),
  (#interestExpense, "2120", "expense", "liability"),
  (#feeIncome, "5100", "income", "expense"),
  (#principal, "1210", "liability", "asset"),
];
for ((role, account, expected, actual) in wrongSlots.vals()) {
  let broken = Array.map<T.RoleMapping, T.RoleMapping>(savingsRoles, func(m) {
    if (m.role == role) ({ role; account }) else m
  });
  let terms = { savings with roles = broken; control = (if (role == #principal) account else savings.control) };
  switch (Products.validateTerms(js, "SAV", terms)) {
    case (?#RoleAccountWrongCategory(d)) {
      assert (Text.equal(d.role, T.roleText(role)));
      assert (Text.equal(d.account, account));
      assert (Text.equal(d.expected, expected));
      assert (Text.equal(d.actual, actual));
      categoryRefusals += 1;
    };
    case (other) { Debug.print("expected a category refusal, got " # debug_show (other)); assert false };
  };
};
Debug.print("count: role slots refused for the wrong category = " # Nat.toText(categoryRefusals));
assert (categoryRefusals == wrongSlots.size());

// an unmapped required role, an unknown account, a closed account, a header account
var structuralRefusals = 0;
switch (Products.validateTerms(js, "SAV", { savings with roles = [{ role = #principal; account = "2110" }] })) {
  case (?#RoleUnmapped(d)) { assert (Text.equal(d.product, "SAV")); structuralRefusals += 1 };
  case (other) { Debug.print(debug_show (other)); assert false };
};
switch (Products.validateTerms(js, "SAV", { savings with roles = Array.map<T.RoleMapping, T.RoleMapping>(savingsRoles, func(m) { if (m.role == #feeIncome) ({ role = #feeIncome; account = "4999" }) else m }) })) {
  case (?#RoleAccountUnknown(d)) { assert (Text.equal(d.account, "4999")); structuralRefusals += 1 };
  case (other) { Debug.print(debug_show (other)); assert false };
};
// the control account must be the principal account
switch (Products.validateTerms(js, "SAV", { savings with control = "1001" })) {
  case (?#ControlIsNotPrincipal(d)) { assert (Text.equal(d.control, "1001")); structuralRefusals += 1 };
  case (other) { Debug.print(debug_show (other)); assert false };
};
// an unregistered currency
switch (Products.validateTerms(js, "SAV", { savings with currency = "ZZZ" })) {
  case (?#InvalidTerms(_)) structuralRefusals += 1;
  case (other) { Debug.print(debug_show (other)); assert false };
};
Debug.print("count: structural registration refusals = " # Nat.toText(structuralRefusals));
assert (structuralRefusals == 4);

// ─── 2. rate charts partition the space ──────────────────────────────────────

var chartRefusals = 0;
let badCharts : [T.RateChart] = [
  { bands = []; by = #balance },                                                           // no bands
  { bands = [{ from = 100; to = null; rate = rate(5, 100) }]; by = #balance },              // does not start at zero
  { bands = [{ from = 0; to = ?100; rate = rate(5, 100) }]; by = #balance },                // last band not open
  { bands = [{ from = 0; to = ?100; rate = rate(5, 100) }, { from = 200; to = null; rate = rate(6, 100) }]; by = #balance },  // a gap
  { bands = [{ from = 0; to = ?100; rate = rate(5, 100) }, { from = 50; to = null; rate = rate(6, 100) }]; by = #balance },   // an overlap
  { bands = [{ from = 0; to = ?100; rate = rate(5, 100) }, { from = 100; to = ?200; rate = rate(6, 100) }]; by = #balance },  // open band not last
  { bands = [{ from = 0; to = null; rate = { numerator = 5; denominator = 0; negative = false } }]; by = #balance },          // zero denominator
  { bands = [{ from = 0; to = null; rate = neg(5, 100) }]; by = #balance },                 // negative without opting in
];
for (c in badCharts.vals()) {
  switch (Products.validateChart(c, false)) {
    case (?_) chartRefusals += 1;
    case null { Debug.print("a bad chart was accepted"); assert false };
  };
};
Debug.print("count: rate charts refused = " # Nat.toText(chartRefusals));
assert (chartRefusals == badCharts.size());

// a negative rate is accepted when the product opts in
assert (Products.validateChart({ bands = [{ from = 0; to = null; rate = neg(5, 1000) }]; by = #balance }, true) == null);

// a banded chart resolves on the documented side of the boundary: bands are
// [from, to), so a balance exactly on a boundary belongs to the upper band
let banded : T.RateChart = {
  bands = [
    { from = 0; to = ?100_000; rate = rate(2, 100) },
    { from = 100_000; to = ?1_000_000; rate = rate(4, 100) },
    { from = 1_000_000; to = null; rate = rate(6, 100) },
  ];
  by = #balance;
};
assert (Products.validateChart(banded, false) == null);
switch (Products.rateAt(banded, 99_999)) { case (?r) assert (r.numerator == 2); case null assert false };
switch (Products.rateAt(banded, 100_000)) { case (?r) assert (r.numerator == 4); case null assert false };
switch (Products.rateAt(banded, 999_999)) { case (?r) assert (r.numerator == 4); case null assert false };
switch (Products.rateAt(banded, 1_000_000)) { case (?r) assert (r.numerator == 6); case null assert false };
Debug.print("count: rate band boundary resolutions verified = 4");

// ─── 3. schedules are exact ──────────────────────────────────────────────────

let loanRoles : [T.RoleMapping] = [
  { role = #principal; account = "1210" },
  { role = #interestReceivable; account = "1220" },
  { role = #interestIncome; account = "4200" },
  { role = #feeIncome; account = "4100" },
  { role = #penaltyIncome; account = "4110" },
  { role = #feeReceivable; account = "1230" },
  { role = #penaltyReceivable; account = "1240" },
  { role = #writeOff; account = "5210" },
  { role = #recovery; account = "4300" },
  { role = #allowance; account = "1290" },
  { role = #impairmentExpense; account = "5200" },
];

let loanSchedule : T.ScheduleTerms = {
  amortisation = #equalInstalments;
  instalments = 12;
  every = #monthly;
  principalGrace = 0;
  interestGrace = 0;
  moratoriumDays = 0;
};

let loan : T.ProductTerms = {
  kind = #loan;
  currency = "EGP";
  control = "1210";
  roles = loanRoles;
  interest = ?{ savingsInterest with chart = flatChart(rate(12, 100)); convention = #a006_Thirty360Isda; basis = #dailyBalance };
  charges = [];
  limits = { overdraft = null; minimumOperating = 0; perOperation = null };
  schedule = ?loanSchedule;
  delinquency = [
    { name = "current"; fromDays = 0; toDays = ?31 },
    { name = "30-59"; fromDays = 31; toDays = ?61 },
    { name = "60-89"; fromDays = 61; toDays = ?91 },
    { name = "90+"; fromDays = 91; toDays = null },
  ];
  provisioning = [
    { band = "current"; stage = 1; percentOfOutstanding = rate(1, 100) },
    { band = "30-59"; stage = 2; percentOfOutstanding = rate(10, 100) },
    { band = "60-89"; stage = 2; percentOfOutstanding = rate(25, 100) },
    { band = "90+"; stage = 3; percentOfOutstanding = rate(100, 100) },
  ];
  accounting = #accrualPeriodic;
  withholdingTax = null;
  rounding = #halfEven;
  earlyRedemptionPenalty = null;
  valueDateConvention = #following;
};
switch (Products.validateTerms(js, "LOAN", loan)) {
  case (?e) { Debug.print("the loan product was refused: " # debug_show (e)); assert false };
  case null {};
};

// A header account can carry the category a role requires and still must not be
// mapped to it: a header is a rollup and cannot carry postings. Account 9000 is an
// asset, so it satisfies the category the allowance role requires, and it is refused
// anyway — on being a header, not on its category.
switch (Products.validateTerms(js, "LOANH", {
  loan with
  roles = Array.map<T.RoleMapping, T.RoleMapping>(loanRoles, func(m) { if (m.role == #allowance) ({ role = #allowance; account = "9000" }) else m })
})) {
  case (?#InvalidTerms(d)) { assert (Text.contains(d.reason, #text "header account")); Debug.print("count: header accounts refused as posting targets = 1") };
  case (other) { Debug.print(debug_show (other)); assert false };
};

let START = CivilDate.fromCivil(2026, 1, 31);
let start = switch (START) { case (?d) d; case null 0 };
assert (start > 0);

var scheduleCases = 0;
var instalmentRows = 0;
let methods : [T.Amortisation] = [#equalInstalments, #equalPrincipal, #flat, #balloon({ finalPrincipal = 200_000 })];
for (method in methods.vals()) {
  for (grace in [0, 2].vals()) {
    let sch : T.ScheduleTerms = { loanSchedule with amortisation = method; principalGrace = grace; moratoriumDays = grace * 5 };
    let out = Products.schedule(1_000_000, rate(12, 100), sch, #halfEven, start);
    let faults = Products.scheduleFaults(1_000_000, out.rows);
    if (faults.size() > 0) { Debug.print("schedule fault: " # faults[0] # " (" # debug_show (method) # ", grace " # Nat.toText(grace) # ")"); assert false };
    assert (out.rows.size() == 12);
    instalmentRows += out.rows.size();
    scheduleCases += 1;
  };
};
Debug.print("count: schedules generated and checked = " # Nat.toText(scheduleCases));
Debug.print("count: instalment rows checked = " # Nat.toText(instalmentRows));

// the day-of-month clamp: a loan drawn on the 31st pays on the 30th in a
// thirty-day month and returns to the 31st afterwards
let jan31 = switch (CivilDate.fromCivil(2026, 1, 31)) { case (?d) d; case null 0 };
let feb28 = switch (CivilDate.fromCivil(2026, 2, 28)) { case (?d) d; case null 0 };
let mar31 = switch (CivilDate.fromCivil(2026, 3, 31)) { case (?d) d; case null 0 };
let apr30 = switch (CivilDate.fromCivil(2026, 4, 30)) { case (?d) d; case null 0 };
assert (Products.addMonths(jan31, 1) == feb28);
assert (Products.addMonths(jan31, 2) == mar31);
assert (Products.addMonths(jan31, 3) == apr30);
Debug.print("count: month-end clamps verified = 3");

// an equal-instalment schedule's payment is level except for the last row, which
// absorbs the residue so the principal column sums to the advance exactly
let emi = Products.schedule(1_000_000, rate(12, 100), loanSchedule, #halfEven, start);
var levelPayments = 0;
var i = 0;
while (i + 1 < emi.rows.size()) {
  let a = emi.rows[i];
  let b = emi.rows[i + 1];
  if (a.principal + a.interest == b.principal + b.interest) levelPayments += 1;
  i += 1;
};
Debug.print("count: level equal-instalment payments = " # Nat.toText(levelPayments));
assert (levelPayments >= 8);
Debug.print("the twelve-month EMI schedule's total interest = " # Nat.toText(emi.totalInterest) # " minor units");

// a zero-rate loan still amortises, and still closes at zero
let zeroRate = Products.schedule(1_200_000, rate(0, 100), loanSchedule, #halfEven, start);
assert (Products.scheduleFaults(1_200_000, zeroRate.rows).size() == 0);
assert (zeroRate.totalInterest == 0);
Debug.print("count: zero-rate schedules verified = 1");

// a schedule whose terms are refused when written
var scheduleRefusals = 0;
for (bad in [
  { loanSchedule with instalments = 0 },
  { loanSchedule with instalments = T.MAX_INSTALMENTS + 1 },
  { loanSchedule with principalGrace = 12 },
  { loanSchedule with interestGrace = 13 },
  { loanSchedule with every = #atMaturity },
].vals()) {
  switch (Products.validateTerms(js, "LOAN", { loan with schedule = ?bad })) {
    case (?#InvalidSchedule(_)) scheduleRefusals += 1;
    case (other) { Debug.print(debug_show (other)); assert false };
  };
};
// a loan with no schedule at all
switch (Products.validateTerms(js, "LOAN", { loan with schedule = null })) {
  case (?#ScheduleRequired(_)) scheduleRefusals += 1;
  case (other) { Debug.print(debug_show (other)); assert false };
};
Debug.print("count: schedule terms refused = " # Nat.toText(scheduleRefusals));
assert (scheduleRefusals == 6);

// ─── 4. charges ──────────────────────────────────────────────────────────────

let chargeSet : [T.Charge] = [
  { id = "ledger-fee"; calculation = #flat({ amount = 1_000 }); timing = #recurring({ every = #monthly }); currency = "EGP"; role = #feeIncome; waivable = true },
  { id = "txn-fee"; calculation = #percentOfAmount({ rate = rate(1, 200) }); timing = #onTransaction; currency = "EGP"; role = #feeIncome; waivable = true },
  { id = "open-fee"; calculation = #flat({ amount = 5_000 }); timing = #onActivation; currency = "EGP"; role = #feeIncome; waivable = false },
  { id = "late-fee"; calculation = #percentOfPrincipalOutstanding({ rate = rate(2, 100) }); timing = #overdue({ afterDays = 7 }); currency = "EGP"; role = #penaltyIncome; waivable = true },
  { id = "tax-on-interest"; calculation = #percentOfInterest({ rate = rate(20, 100) }); timing = #recurring({ every = #annual }); currency = "EGP"; role = #feeIncome; waivable = false },
];
// the penalty charge needs a penalty-income role, so the product maps one; a
// charge naming a role the product does not map is refused below
let charged : T.ProductTerms = {
  savings with
  charges = chargeSet;
  roles = Array.tabulate<T.RoleMapping>(savingsRoles.size() + 1, func(i) {
    if (i < savingsRoles.size()) savingsRoles[i] else ({ role = #penaltyIncome; account = "4110" })
  });
};
switch (Products.validateTerms(js, "SAVC", charged)) {
  case (?e) { Debug.print("the charged product was refused: " # debug_show (e)); assert false };
  case null {};
};

// each calculation type computes from its own base, and refuses to compute from a
// base the caller did not supply
var chargeAmounts = 0;
var baseRefusals = 0;
let base : Charges.Base = { amount = ?200_000; interest = ?5_000; outstanding = ?750_000 };
let expected : [(Text, Nat)] = [("ledger-fee", 1_000), ("txn-fee", 1_000), ("open-fee", 5_000), ("late-fee", 15_000), ("tax-on-interest", 1_000)];
for ((id, want) in expected.vals()) {
  let ?c = Charges.find(charged, id) else { Debug.print("charge " # id # " not found"); assert false; loop {} };
  switch (Charges.amountOf(c, base, #halfEven)) {
    case (#ok(r)) { assert (r.amount == want); chargeAmounts += 1 };
    case (#err(e)) { Debug.print("charge " # id # " failed: " # debug_show (e)); assert false };
  };
  switch (Charges.amountOf(c, Charges.emptyBase(), #halfEven)) {
    case (#err(#baseMissing(_))) baseRefusals += 1;
    case (#ok(r)) { assert (Text.equal(id, "ledger-fee") or Text.equal(id, "open-fee")); assert (r.amount == want) };
    case (#err(e)) { Debug.print(debug_show (e)); assert false };
  };
};
Debug.print("count: charge amounts verified = " # Nat.toText(chargeAmounts));
Debug.print("count: charges refused for a missing base = " # Nat.toText(baseRefusals));
assert (chargeAmounts == 5);
assert (baseRefusals == 3);

// a charge that rounds to zero is not a posting
let tiny : T.Charge = { id = "tiny"; calculation = #percentOfAmount({ rate = rate(1, 1_000_000) }); timing = #onTransaction; currency = "EGP"; role = #feeIncome; waivable = true };
switch (Charges.amountOf(tiny, { base with amount = ?100 }, #halfEven)) {
  case (#err(#roundsToZero(d))) assert (Text.equal(d.charge, "tiny"));
  case (other) { Debug.print(debug_show (other)); assert false };
};
Debug.print("count: charges refused for rounding to zero = 1");

// the charge calendar: a monthly fee falls due on the anniversary day of month,
// clamped at a short month end, and nowhere else
let opened = jan31;
// The window is half-open, so a fee opened on 31 January falls due on the eleven
// month-ends from February to December and the first anniversary lands on the
// excluded end day — which is the right answer for a window, and is stated here
// because "twelve months" and "a year's window" are not the same count.
let monthlyDue = Charges.dueDays(#recurring({ every = #monthly }), opened, opened + 365, opened, null, func(_) { 0 });
Debug.print("count: monthly charge occurrences in a year = " # Nat.toText(monthlyDue.size()));
assert (monthlyDue.size() == 11);
assert (Charges.dueDays(#recurring({ every = #monthly }), opened, opened + 366, opened, null, func(_) { 0 }).size() == 12);
assert (monthlyDue[0] == feb28);
assert (monthlyDue[1] == mar31);
assert (monthlyDue[2] == apr30);

// an overdue penalty falls due on exactly the declared age, once
let overdueDue = Charges.dueDays(#overdue({ afterDays = 7 }), opened, opened + 60, opened, null, func(d) { if (d > opened + 10) d - (opened + 10) else 0 });
Debug.print("count: overdue penalty occurrences = " # Nat.toText(overdueDue.size()));
assert (overdueDue.size() == 1);
assert (overdueDue[0] == opened + 17);

// an activation charge falls due on the day the account opened and never again
let activationDue = Charges.dueDays(#onActivation, opened, opened + 400, opened, null, func(_) { 0 });
assert (activationDue.size() == 1 and activationDue[0] == opened);
// a transaction charge is never on the calendar: it is driven by the transaction
assert (Charges.dueDays(#onTransaction, opened, opened + 400, opened, null, func(_) { 0 }).size() == 0);
Debug.print("count: charge timing shapes verified = 4");

// charge validation: a currency that is not the product's, a duplicate id, a zero
// flat amount, a role the product does not map
var chargeRefusals = 0;
for (bad in [
  [{ chargeSet[0] with currency = "USD" }],
  [chargeSet[0], chargeSet[0]],
  [{ chargeSet[0] with calculation = #flat({ amount = 0 }) }],
  [{ chargeSet[0] with role = #recovery }],
].vals()) {
  switch (Products.validateTerms(js, "SAVC", { savings with charges = bad })) {
    case (?_) chargeRefusals += 1;
    case null { Debug.print("a bad charge set was accepted"); assert false };
  };
};
Debug.print("count: charge sets refused = " # Nat.toText(chargeRefusals));
assert (chargeRefusals == 4);

// ─── 5. repayment allocation ─────────────────────────────────────────────────

let position : T.Allocation = { penalty = 1_500; fee = 2_000; interest = 10_000; principal = 100_000 };
let total = Loans.allocationTotal(position);

// the declared order is honoured, component by component
let partial = Loans.allocate(12_000, position, Loans.defaultOrder());
assert (partial.applied.penalty == 1_500);
assert (partial.applied.fee == 2_000);
assert (partial.applied.interest == 8_500);
assert (partial.applied.principal == 0);
assert (partial.overpayment == 0);
assert (Loans.allocationTotal(partial.applied) == 12_000);

// principal first, when that is what the product declares
let principalFirst = Loans.allocate(12_000, position, [#principal, #interest, #fee, #penalty]);
assert (principalFirst.applied.principal == 12_000);
assert (principalFirst.applied.interest == 0);

// an exact settlement leaves nothing, and an excess is reported rather than absorbed
let exact = Loans.allocate(total, position, Loans.defaultOrder());
assert (Loans.allocationTotal(exact.applied) == total and exact.overpayment == 0);
let over = Loans.allocate(total + 777, position, Loans.defaultOrder());
assert (over.overpayment == 777);
assert (Loans.allocationTotal(over.applied) == total);
Debug.print("count: repayment allocations verified = 4");

// an order that drops or repeats a component is refused when it is written
var orderRefusals = 0;
for (bad in [
  ([] : [T.Component]),
  ([#penalty, #fee, #interest] : [T.Component]),
  ([#penalty, #penalty, #interest, #principal] : [T.Component]),
  ([#penalty, #fee, #interest, #principal, #principal] : [T.Component]),
].vals()) {
  switch (Loans.validOrder(bad)) { case (?_) orderRefusals += 1; case null { Debug.print("a bad order was accepted"); assert false } };
};
assert (Loans.validOrder(Loans.defaultOrder()) == null);
Debug.print("count: allocation orders refused = " # Nat.toText(orderRefusals));
assert (orderRefusals == 4);

// ─── 6. arrears and delinquency ──────────────────────────────────────────────

let sch12 = Products.schedule(1_200_000, rate(12, 100), loanSchedule, #halfEven, start);
let rows = sch12.rows;

// Nothing due yet and nothing paid: no arrears — and the performing band, which is the
// one the product declares from day 0. A performing loan is classified, not unclassified:
// under IFRS 9 it is stage 1 with a twelve-month expected-loss allowance, and the band is
// what carries that rate. A product that declares no band covering zero days still gets
// none.
let fresh = Loans.arrears(rows, 0, start);
assert (fresh.overdueTotal == 0 and fresh.instalmentsOverdue == 0 and fresh.overdueDays == 0);
assert (Loans.band(loan, fresh) == ?"current");
assert (Loans.band({ loan with delinquency = [{ name = "31+"; fromDays = 31; toDays = null }] }, fresh) == null);

// the first instalment falls due and is unpaid: the age is measured from its due
// date, and the band follows the age
let firstDue = rows[0].dueDate;
var bandChecks = 0;
let ages : [(Nat, Text)] = [(0, "current"), (30, "current"), (31, "30-59"), (60, "30-59"), (61, "60-89"), (90, "60-89"), (91, "90+"), (365, "90+")];
for ((age, want) in ages.vals()) {
  let a = Loans.arrears(rows, 0, firstDue + age);
  switch (Loans.band(loan, a)) {
    case (?b) { assert (Text.equal(b, want)); bandChecks += 1 };
    case null { Debug.print("no band at age " # Nat.toText(age)); assert false };
  };
};
Debug.print("count: delinquency band assignments verified = " # Nat.toText(bandChecks));
assert (bandChecks == ages.size());

// A repayment moves the position by construction: the fold is cumulative over the
// instalments that have fallen due, so a payment recorded with any value date
// changes the arrears figure with no recalculation step anywhere.
func instalmentAmount(r : T.Instalment) : Nat { r.principal + r.interest + r.fees };
let firstAmount = instalmentAmount(rows[0]);
let secondDue = rows[1].dueDate;

// ten days after the first instalment, only it has fallen due; paying it clears
var arrearsChecks = 0;
let cleared = Loans.arrears(rows, firstAmount, firstDue + 10);
assert (cleared.dueToDate == firstAmount);
assert (cleared.overdueTotal == 0 and cleared.instalmentsOverdue == 0);
assert (cleared.overdueDays == 0);
// paid up, so back in the performing band rather than out of the classification
assert (Loans.band(loan, cleared) == ?"current");
arrearsChecks += 1;

// one unit short leaves exactly one unit overdue, aged from the first instalment
let oneShort = Loans.arrears(rows, firstAmount - 1, firstDue + 10);
assert (oneShort.overdueTotal == 1 and oneShort.instalmentsOverdue == 1);
assert (oneShort.overdueDays == 10);
switch (Loans.band(loan, oneShort)) { case (?b) assert (Text.equal(b, "current")); case null assert false };
arrearsChecks += 1;

// ten days after the second instalment, two have fallen due: paying only the first
// leaves the second overdue, aged from *its* due date and not from the first's
let partlyPaid = Loans.arrears(rows, firstAmount, secondDue + 10);
assert (partlyPaid.dueToDate == firstAmount + instalmentAmount(rows[1]));
assert (partlyPaid.overdueTotal == instalmentAmount(rows[1]));
assert (partlyPaid.instalmentsOverdue == 1);
assert (partlyPaid.overdueDays == 10);
arrearsChecks += 1;

// paying both clears the position entirely
let bothPaid = Loans.arrears(rows, firstAmount + instalmentAmount(rows[1]), secondDue + 10);
assert (bothPaid.overdueTotal == 0 and bothPaid.instalmentsOverdue == 0);
assert (bothPaid.overdueDays == 0);
assert (Loans.band(loan, bothPaid) == ?"current");
arrearsChecks += 1;

// and paying nothing at all leaves both overdue, aged from the oldest
let nothingPaid = Loans.arrears(rows, 0, secondDue + 10);
assert (nothingPaid.instalmentsOverdue == 2);
assert (nothingPaid.overdueDays == secondDue + 10 - firstDue);
arrearsChecks += 1;
Debug.print("count: arrears fold checks = " # Nat.toText(arrearsChecks));
assert (arrearsChecks == 5);

// the provision is the declared percentage of the exposure, exactly
var provisionChecks = 0;
let provisionCases : [(Nat, Text, Nat, Nat)] = [(0, "current", 1_000_000, 10_000), (35, "30-59", 1_000_000, 100_000), (65, "60-89", 1_000_000, 250_000), (200, "90+", 1_000_000, 1_000_000)];
for ((age, band, exposure, want) in provisionCases.vals()) {
  let a = Loans.arrears(rows, 0, firstDue + age);
  let req = Loans.requiredProvision(loan, a, exposure, #halfEven);
  switch (req.band) { case (?b) assert (Text.equal(b, band)); case null assert false };
  assert (req.amount == want);
  provisionChecks += 1;
};
Debug.print("count: provisions computed from declared parameters = " # Nat.toText(provisionChecks));
assert (provisionChecks == provisionCases.size());

// the movement is against what is already carried, never a restatement
switch (Loans.provisionMovement(10_000, 100_000)) { case (#increase(n)) assert (n == 90_000); case (_) assert false };
switch (Loans.provisionMovement(100_000, 10_000)) { case (#release(n)) assert (n == 90_000); case (_) assert false };
switch (Loans.provisionMovement(50_000, 50_000)) { case (#unchanged) {}; case (_) assert false };
Debug.print("count: provision movements verified = 3");

// a write-off takes what the allowance carries and charges the rest
let exposureNow : T.Allocation = { penalty = 1_000; fee = 2_000; interest = 7_000; principal = 90_000 };
let wo1 = Loans.writeOff(exposureNow, 30_000);
assert (wo1.fromAllowance == 30_000 and wo1.toExpense == 70_000);
let wo2 = Loans.writeOff(exposureNow, 200_000);
assert (wo2.fromAllowance == 100_000 and wo2.toExpense == 0);
assert (Loans.allocationTotal(wo1.components) == 100_000);
Debug.print("count: write-off splits verified = 2");

// a reschedule retains what already fell due and re-amortises the rest
let reschedTerms : T.ScheduleTerms = { loanSchedule with instalments = 18 };
let resched = Loans.reschedule(rows, { effective = rows[3].dueDate; terms = reschedTerms; rate = rate(10, 100) }, #halfEven);
assert (resched.retained == 3);
assert (resched.reamortised == 18);
assert (resched.outstandingAtEffective == rows[2].closingPrincipal);
assert (resched.rows.size() == 21);
var numbered = true;
var k = 0;
while (k < resched.rows.size()) { if (resched.rows[k].number != k + 1) numbered := false; k += 1 };
assert numbered;
assert (resched.rows[resched.rows.size() - 1].closingPrincipal == 0);
Debug.print("count: reschedules verified = 1");

// ─── 7. term products ────────────────────────────────────────────────────────

let termChart : T.RateChart = {
  bands = [
    { from = 0; to = ?91; rate = rate(6, 100) },
    { from = 91; to = ?181; rate = rate(8, 100) },
    { from = 181; to = null; rate = rate(10, 100) },
  ];
  by = #termDays;
};
let termInterest : T.InterestTerms = {
  chart = termChart;
  convention = #a004_Act365Fixed;
  basis = #dailyBalance;
  compounding = #atMaturity;
  compoundingAlignment = #anniversary;
  posting = #atMaturity;
  minimumBalance = 0;
  allowNegative = false;
};
let termDeposit : T.ProductTerms = {
  kind = #termDeposit;
  currency = "EGP";
  control = "2110";
  roles = [
    { role = #principal; account = "2110" },
    { role = #interestPayable; account = "2120" },
    { role = #interestExpense; account = "5100" },
    { role = #penaltyIncome; account = "4110" },
  ];
  interest = ?termInterest;
  charges = [];
  limits = { overdraft = null; minimumOperating = 0; perOperation = null };
  schedule = null;
  delinquency = [];
  provisioning = [];
  accounting = #accrualPeriodic;
  withholdingTax = null;
  rounding = #halfEven;
  earlyRedemptionPenalty = ?rate(2, 100);
  valueDateConvention = #modifiedFollowing;
};
assert (Products.validateTerms(js, "FD", termDeposit) == null);

// the rate is the band the term falls in, and a chart banded by balance cannot
// answer a question about a term
switch (TermProducts.rateForTerm(termChart, 180)) { case (#ok(r)) assert (r.numerator == 8); case (#err(_)) assert false };
switch (TermProducts.rateForTerm(termChart, 181)) { case (#ok(r)) assert (r.numerator == 10); case (#err(_)) assert false };
switch (TermProducts.rateForTerm(flatChart(rate(5, 100)), 180)) { case (#err(#chartIsByBalance)) {}; case (_) assert false };
switch (TermProducts.rateForBalance(termChart, 1_000)) { case (#err(#chartIsByTerm)) {}; case (_) assert false };
Debug.print("count: term rate resolutions verified = 4");

// simple interest at maturity: 1,000,000 minor units for 182 days at 10 % on a
// 365-day basis is 1,000,000 × 0.10 × 182/365 = 49,863.01…, which rounds to 49,863
let maturity = TermProducts.maturityValue(1_000_000, rate(10, 100), termInterest, #halfEven, start, start + 182);
Debug.print("a 182-day deposit of 1,000,000 at 10 percent matures at " # Nat.toText(maturity.value) # " with interest " # Nat.toText(maturity.interest));
assert (maturity.interest == 49_863);
assert (maturity.value == 1_049_863);

// compounding monthly over a year is strictly more than simple interest, and the
// carried balance is exact until the single rounding at the end
let compounded = TermProducts.maturityValue(1_000_000, rate(12, 100), { termInterest with compounding = #monthly }, #halfEven, start, start + 365);
let simple = TermProducts.maturityValue(1_000_000, rate(12, 100), { termInterest with compounding = #atMaturity }, #halfEven, start, start + 365);
Debug.print("one year at 12 percent: simple " # Nat.toText(simple.interest) # ", compounded monthly " # Nat.toText(compounded.interest));
assert (compounded.interest > simple.interest);
assert (compounded.compoundings == 12);
Debug.print("count: maturity values verified = 3");

// early redemption recomputes at the penalised rate and recovers the difference
let early = TermProducts.earlyRedemption(1_000_000, rate(10, 100), rate(2, 100), termInterest, #halfEven, start, start + 91, 49_863);
Debug.print("redeemed at day 91: entitled " # Nat.toText(early.entitled) # ", recoverable " # Nat.toText(early.recoverable) # ", penalised rate " # Nat.toText(early.penalisedRate.numerator) # "/" # Nat.toText(early.penalisedRate.denominator));
assert (early.daysHeld == 91);
assert (early.penalisedRate.numerator * 100 == 8 * early.penalisedRate.denominator);
assert (early.entitled < 49_863);
assert (early.recoverable == 49_863 - early.entitled);
assert (early.payable == 0);

// and where less was credited than the recomputation allows, the shortfall is
// payable rather than silently zero
let under = TermProducts.earlyRedemption(1_000_000, rate(10, 100), rate(2, 100), termInterest, #halfEven, start, start + 91, 0);
assert (under.recoverable == 0 and under.payable == under.entitled and under.payable > 0);
Debug.print("count: early redemptions verified = 2");

// a penalty at or above the opening rate floors at zero rather than going negative
let floored = TermProducts.earlyRedemption(1_000_000, rate(10, 100), rate(25, 100), termInterest, #halfEven, start, start + 91, 10_000);
assert (floored.penalisedRate.numerator == 0);
assert (floored.entitled == 0);
assert (floored.recoverable == 10_000);
Debug.print("count: penalty floors verified = 1");

// a recurring plan's shortfall is the difference between what was expected and
// what arrived, never a figure anyone maintained
let expectedDeposits = TermProducts.expectedDeposits(50_000, { loanSchedule with instalments = 6 }, start);
assert (expectedDeposits.size() == 6);
let short = TermProducts.shortfall(expectedDeposits, 120_000, expectedDeposits[3].dueDate);
assert (short.expectedToDate == 200_000);
assert (short.shortfall == 80_000);
assert (short.instalmentsMissed == 2);
Debug.print("count: recurring deposit shortfalls verified = 1");

// a term product refuses terms that do not belong to it
var termRefusals = 0;
switch (Products.validateTerms(js, "FD", { termDeposit with earlyRedemptionPenalty = ?neg(2, 100) })) {
  case (?#InvalidTerms(_)) termRefusals += 1;
  case (other) { Debug.print(debug_show (other)); assert false };
};
switch (Products.validateTerms(js, "SAV", { savings with earlyRedemptionPenalty = ?rate(2, 100) })) {
  case (?#InvalidTerms(_)) termRefusals += 1;
  case (other) { Debug.print(debug_show (other)); assert false };
};
// a period-only convention cannot serve a daily-balance product
switch (Products.validateTerms(js, "FD", { termDeposit with interest = ?{ termInterest with convention = #a001_ActActIcma({ couponsPerYear = 2 }); basis = #dailyBalance } })) {
  case (?#ConventionNotDailyBalance(d)) { assert (Text.equal(d.code, "A001")); termRefusals += 1 };
  case (other) { Debug.print(debug_show (other)); assert false };
};
Debug.print("count: term product refusals = " # Nat.toText(termRefusals));
assert (termRefusals == 3);

// ─── 8. tills: a difference is posted, never absorbed ────────────────────────

let tillTerms : T.ProductTerms = {
  kind = #till;
  currency = "EGP";
  control = "1001";
  roles = [
    { role = #principal; account = "1001" },
    { role = #cash; account = "1001" },
    { role = #suspense; account = "1900" },
  ];
  interest = null;
  charges = [];
  limits = { overdraft = null; minimumOperating = 0; perOperation = null };
  schedule = null;
  delinquency = [];
  provisioning = [];
  accounting = #cash;
  withholdingTax = null;
  rounding = #halfEven;
  earlyRedemptionPenalty = null;
  valueDateConvention = #following;
};
assert (Products.validateTerms(js, "TILL", tillTerms) == null);

assert (Till.difference(100_000, 100_000) == #balanced);
switch (Till.difference(99_500, 100_000)) { case (#short(n)) assert (n == 500); case (_) assert false };
switch (Till.difference(100_500, 100_000)) { case (#over(n)) assert (n == 500); case (_) assert false };

let tillSub = Till.tillSubledger("T01");
let vaultSub = Till.vaultSubledger("BR01", "EGP");
assert (tillSub != vaultSub);

// a balanced settlement has no posting at all, because a posting that moves
// nothing is not made
assert (Till.settlementLegs("1001", tillSub, "1900", "EGP", #balanced) == null);

var tillChecks = 0;
for (d in [#short(500), #over(500)].vals()) {
  let ?legs = Till.settlementLegs("1001", tillSub, "1900", "EGP", d) else { Debug.print("no legs"); assert false; loop {} };
  assert (legs.size() == 2);
  assert (Posting.balances(legs));
  // one leg is the till's own sub-ledger and the other is suspense: the suspense
  // leg is what makes the posting balance, so a difference cannot be absorbed
  var sawTill = false;
  var sawSuspense = false;
  for (l in legs.vals()) {
    if (Text.equal(l.account, "1001")) { sawTill := true; assert (l.subledger == ?tillSub) };
    if (Text.equal(l.account, "1900")) { sawSuspense := true; assert (l.subledger == null) };
    assert (l.amount == 500);
  };
  assert (sawTill and sawSuspense);
  tillChecks += 1;
};
Debug.print("count: till settlement shapes verified = " # Nat.toText(tillChecks));
assert (tillChecks == 2);

// loading a drawer moves cash between two sub-ledgers of the same control
// account, so the bank's total cash does not change
let alloc = Till.allocationLegs("1001", vaultSub, tillSub, "EGP", 250_000);
assert (Posting.balances(alloc));
assert (Text.equal(alloc[0].account, "1001") and Text.equal(alloc[1].account, "1001"));
let ret = Till.returnLegs("1001", vaultSub, tillSub, "EGP", 250_000);
assert (Posting.balances(ret));
// the drawer is debited when it is loaded and credited when it is emptied; the
// vault is the mirror, and both legs name the same control account throughout
func sideOf(legs : [JT.Leg], sub : Blob) : ?JT.Side {
  for (l in legs.vals()) { if (l.subledger == ?sub) return ?l.side };
  null
};
assert (sideOf(alloc, tillSub) == ?#debit);
assert (sideOf(alloc, vaultSub) == ?#credit);
assert (sideOf(ret, tillSub) == ?#credit);
assert (sideOf(ret, vaultSub) == ?#debit);
Debug.print("count: till cash movements verified = 2");

// ─── 9. derived keys and sub-ledgers ─────────────────────────────────────────

// a sub-ledger key is a function of the identifier, fixed width, and no
// identifier's key is another's
let identifiers = ["EG380019000500000000263180002", "EG380019000500000000263180003", "EG380019000500000000263180004"];
let keys = Array.map<Text, Blob>(identifiers, Posting.subledgerOf);
var distinct = 0;
var ki = 0;
while (ki < keys.size()) {
  assert (keys[ki].size() == 32);
  assert (keys[ki] == Posting.subledgerOf(identifiers[ki]));
  var kj = ki + 1;
  while (kj < keys.size()) { assert (keys[ki] != keys[kj]); kj += 1 };
  distinct += 1;
  ki += 1;
};
Debug.print("count: sub-ledger keys verified = " # Nat.toText(distinct));

// a derived idempotency key is a function of the purpose and the parts, and the
// parts are length-prefixed so no two different splits collide
assert (Posting.key("deposit", ["1", "2"]) == Posting.key("deposit", ["1", "2"]));
assert (Posting.key("deposit", ["1", "2"]) != Posting.key("deposit", ["12"]));
assert (Posting.key("deposit", ["1", "2"]) != Posting.key("withdrawal", ["1", "2"]));
assert (Posting.key("deposit", ["1", "2"]) != Posting.key("deposit", ["12", ""]));
assert (Posting.subledgerOf("x") != Posting.key("x", []));
Debug.print("count: derived key separations verified = 5");

// the chunk bound agrees with the journal's own leg bound
assert (Posting.chunkBoundAgrees());
let chunks = Posting.chunk<Nat>(Array.tabulate<Nat>(300, func(i) { i }), Posting.CAPITALISATION_CHUNK);
assert (chunks.size() == 3);
assert (chunks[0].size() == 127 and chunks[1].size() == 127 and chunks[2].size() == 46);
var chunked = 0;
for (c in chunks.vals()) { chunked += c.size() };
assert (chunked == 300);
Debug.print("count: capitalisation chunk elements = " # Nat.toText(chunked));

// a capitalisation posting's contra leg is the **sum of the rounded legs**, so the
// posting balances by construction and no rounding-difference account exists;
// accounts whose figure rounded to zero contribute no leg
let capRows = [
  { sub = keys[0]; amount = 86 },
  { sub = keys[1]; amount = 0 },
  { sub = keys[2]; amount = 41 },
];
let ?built = Posting.capitalisation("2110", "2120", "EGP", #credit, capRows, ["SAV", "EGP", "1"], start, start, "2026-01", "capitalisation")
  else { Debug.print("no capitalisation posting"); assert false; loop {} };
assert (built.examined == 3 and built.posted == 2 and built.zero == 1);
assert (built.posting.legs.size() == 3);      // two customers and one contra
assert (Posting.balances(built.posting.legs));
var contra = 0;
for (l in built.posting.legs.vals()) { if (Text.equal(l.account, "2120")) contra := l.amount };
assert (contra == 86 + 41);
Debug.print("count: capitalisation legs verified = " # Nat.toText(built.posting.legs.size()));

// a run in which every figure rounds to zero produces no posting at all
assert (Posting.capitalisation("2110", "2120", "EGP", #credit, [{ sub = keys[0]; amount = 0 }], ["SAV", "EGP", "0"], start, start, "2026-01", "n") == null);
Debug.print("count: zero-only capitalisation runs refused = 1");

// the residue is reported, not absorbed: two exact figures of 0.5 rounding to a
// total of 1 leaves a residue the run can state
let res = Posting.residue([{ numerator = 1; denominator = 2; negative = false }, { numerator = 1; denominator = 2; negative = false }], 1);
assert (res.numerator == 0);
let res2 = Posting.residue([{ numerator = 3; denominator = 2; negative = false }], 1);
assert (res2.numerator * 2 == res2.denominator);   // exactly one half left over
assert (not res2.negative);
Debug.print("count: capitalisation residues verified = 2");

// ─── 10. the facility is the journal's own numeric limit ─────────────────────

// a deposit account with a facility becomes a numeric debit limit; a loan account
// may not go credit at all
switch (Limits.journalLimit(#credit, ?50_000_00)) { case (#debitsNotExceedCreditsPlus(n)) assert (n == 5_000_000); case (_) assert false };
switch (Limits.journalLimit(#credit, null)) { case (#debitsNotExceedCreditsPlus(n)) assert (n == 0); case (_) assert false };
switch (Limits.journalLimit(#debit, null)) { case (#creditsNotExceedDebitsPlus(n)) assert (n == 0); case (_) assert false };
Debug.print("count: journal limits derived from product terms = 3");

// the product-level checks the engine cannot make
var limitFaults = 0;
switch (Limits.checkWithdrawal({ overdraft = null; minimumOperating = 0; perOperation = ?10_000 }, 10_001, 0, false)) {
  case (?#overPerOperation(d)) { assert (d.limit == 10_000); limitFaults += 1 };
  case (_) assert false;
};
switch (Limits.checkWithdrawal({ overdraft = null; minimumOperating = 5_000; perOperation = null }, 1_000, 4_999, false)) {
  case (?#belowMinimumOperating(d)) { assert (d.wouldLeave == 4_999); limitFaults += 1 };
  case (_) assert false;
};
switch (Limits.checkWithdrawal({ overdraft = ?1_000; minimumOperating = 5_000; perOperation = null }, 1_000, 0, true)) {
  case (?#belowMinimumOperating(d)) { assert (d.wouldLeave == 0); limitFaults += 1 };
  case (_) assert false;
};
assert (Limits.checkWithdrawal({ overdraft = null; minimumOperating = 5_000; perOperation = ?10_000 }, 1_000, 5_000, false) == null);
Debug.print("count: product limit faults verified = " # Nat.toText(limitFaults));
assert (limitFaults == 3);

// ─── 11. versions: an amendment cannot restate an account's terms ────────────
//
// The immutability of a registered version is a property of the state machine and
// is proved there; what is provable here is that the *vocabulary* keeps both
// versions distinguishable, which is what the state machine relies on.

let v1 : T.Product = { id = "SAV"; version = 1; name = "Savings"; terms = savings; registeredAtBlock = 10; supersededBy = ?2 };
let v2 : T.Product = { id = "SAV"; version = 2; name = "Savings"; terms = { savings with interest = ?{ savingsInterest with chart = flatChart(rate(3, 100)) } }; registeredAtBlock = 20; supersededBy = null };
assert (v1.version != v2.version);
switch (v1.terms.interest, v2.terms.interest) {
  case (?a, ?b) assert (a.chart.bands[0].rate.numerator != b.chart.bands[0].rate.numerator);
  case (_, _) assert false;
};
Debug.print("count: product versions distinguishable = 2");

// every role the vocabulary names has a required category, and the required
// category of `principal` follows the product kind rather than a field
var roleCategories = 0;
for (kind in [#currentAccount, #savings, #termDeposit, #recurringDeposit, #loan, #shareAccount, #till].vals()) {
  for (role in T.requiredRoles(kind).vals()) {
    let c = T.requiredCategoryFor(kind, role);
    assert (Text.encodeUtf8(T.categoryText(c)).size() > 0);
    roleCategories += 1;
  };
};
Debug.print("count: required role categories enumerated = " # Nat.toText(roleCategories));
assert (T.requiredCategoryFor(#loan, #principal) == #asset);
assert (T.requiredCategoryFor(#savings, #principal) == #liability);
assert (T.requiredCategoryFor(#shareAccount, #principal) == #equity);

Debug.print("PRODUCTS TEST GREEN");
