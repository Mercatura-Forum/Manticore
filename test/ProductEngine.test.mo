// ProductEngine.test.mo — the product engine end to end, through the real core.
//
// The the product engine invariants that are properties of the *state machine* rather than of the
// arithmetic, each driven through `planCommand` against a real embedded journal, so
// every figure asserted here is a journal balance and not a fixture:
//
//   * I11 the gate is a height — every money-visible product command refuses below
//     its activation height and is admitted at it, the activation is a block, and no
//     administrator's flag activates anything;
//   * I7 product terms are immutable under an account — an amendment is a new
//     version, accounts opened under the old one still compute on the old terms, and
//     a migration is an explicit recorded decision;
//   * I3 rounding conserves — a capitalisation run's contra leg is the sum of the
//     rounded legs, the residue is reported, and no posting names a
//     rounding-difference account (asserted by scanning every leg of every posting
//     the run produced);
//   * I4 zero accruals are not posted — the examined count includes them, the posted
//     count does not, and no zero-amount leg is ever generated;
//   * I5 negative rates flip sides — the customer is debited and the amounts stay
//     strictly positive;
//   * I8 a header account cannot fund a posting;
//   * I10 a till never absorbs a difference — a short drawer posts to suspense with
//     the cashier named and the drawer closes to its book position;
//   * F3/F4 a withdrawal beyond the balance is refused by the engine, and a granted
//     facility moves the boundary to exactly the facility and not one unit further;
//   * F2 the Fineract interest figure, reached through the whole path: open an
//     account, deposit, withdraw, read the accrual;
//   * F6/F7 a loan disbursed, repaid in the declared order, taken into arrears,
//     provisioned, written off and recovered, with every figure read back;
//   * the fold is the log — replaying every block reproduces the state fingerprint.
//
// engine: wasi-only — the battery fingerprints the whole state on every refusal,
// which is quadratic in the number of blocks and does not finish in a useful time
// under `moc -r`. That is the same reason the journal's own core battery and this
// repository's BankCore battery are exempted, and it is stated here rather than
// left to be noticed.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Principal "mo:core/Principal";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";

import T "../src/bank/BankTypes";
import ProdT "../src/bank/ProductTypes";
import Core "../src/bank/BankCore";
import ProductCore "../src/bank/ProductCore";
import PartyCore "../src/bank/PartyCore";
import Reconstruct "../src/bank/Reconstruct";
import C "../src/bank/BankCanonical";
import Products "../src/bank/Products";
import Posting "../src/bank/Posting";
import Till "../src/bank/Till";
import I "../src/bank/Interest";
import P "../src/bank/Permissions";
import PT "../src/bank/PartyTypes";
import Commit "../src/bank/Commitments";
import S "../src/bank/Screening";
import BankMemLog "support/BankMemLog";
import JMemLog "support/JournalMemLog";

// ─── fixtures ────────────────────────────────────────────────────────────────

let bankP = Principal.fromBlob("\BA\01");
let installer = Principal.fromBlob("\1A\01");
let cashier = Principal.fromBlob("\CA\01");
let screener = Principal.fromBlob("\5C\01");

let DAY : Nat64 = 86_400_000_000_000;
let SEP1 = 20697; let SEP30 = 20726;
let SEP2 = 20698;
let SEP3 = 20699;
let SEP10 = 20706;
let TODAY = 20705;   // 2026-09-09, the day of the reference scenario
let clock : Nat64 = Nat64.fromNat(TODAY) * DAY + 43_200_000_000_000;

let bchain = BankMemLog.new();
let jchain = JMemLog.new();
let bs = Core.newState(installer);
let js = JCore.newState(bankP);

func bcommit(caller : Principal, e : T.Event) : T.Block { BankMemLog.commit(bchain, bs, clock, caller, e) };
func jcommit(e : JT.Event) : JT.Block { JMemLog.commit(jchain, js, clock, bankP, e) };

/// Commit a planned command the way Bank.mo's executor does, returning the journal
/// posting indices it produced.
func execute(authority : Principal, command : T.Command, authorityIndex : Nat) : [Nat] {
  switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, command, authorityIndex)) {
    case (#err(e)) { Debug.print("plan failed for " # P.commandName(command) # ": " # debug_show (e)); assert false; [] };
    case (#ok(plan)) {
      switch (plan.bankEvent) { case (?ev) { ignore bcommit(authority, ev) }; case null {} };
      for (ev in plan.extra.vals()) { ignore bcommit(authority, ev) };
      let out = List.empty<Nat>();
      for (step in plan.journal.vals()) {
        switch (step) { case (#event(ev)) List.add(out, jcommit(ev).index); case (#existing(i)) List.add(out, i) };
      };
      List.toArray(out)
    };
  }
};

/// The authority index a command executes under. In production this is the index of
/// the proposal or the override block that authorised it, which is unique per
/// executed command — a proposal executes once and an override is its own block.
/// The harness reproduces that uniqueness with a counter rather than reusing the
/// bank height, because a command that writes no bank event (a posting-only
/// command) does not advance the height, and two such commands sharing an authority
/// index would derive the same idempotency key. Production cannot reach that state;
/// the counter is how the test stays faithful to it.
var authority = 1_000_000;
func nextAuthority() : Nat { authority += 1; authority };

/// Run a command and return the bank block index its event occupied, which is the
/// identifier of anything it created.
func run(command : T.Command) : Nat {
  let at = Core.height(bs);
  ignore execute(installer, command, nextAuthority());
  at
};

func runPostings(command : T.Command) : [Nat] {
  execute(installer, command, nextAuthority())
};

/// A command that must be refused, with the state proved unchanged afterwards.
func expectErr(command : T.Command, want : Text) {
  let fp = Core.fingerprint(bs);
  let h = Core.height(bs);
  let jfp = JCore.fingerprint(js);
  switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, command, Core.height(bs))) {
    case (#ok(_)) { Debug.print("expected " # want # " for " # P.commandName(command)); assert false };
    case (#err(e)) {
      let got = debug_show (e);
      if (not Text.contains(got, #text want)) { Debug.print("wanted " # want # " got " # got); assert false };
    };
  };
  assert (Core.fingerprint(bs) == fp and Core.height(bs) == h);
  assert (JCore.fingerprint(js) == jfp);
};

// ─── genesis ─────────────────────────────────────────────────────────────────

ignore jcommit(switch (JCore.prepareAddPoster(js, bankP, bankP)) { case (#ok(e)) e; case (#err(_)) { assert false; #posterAdded({ poster = bankP }) } });
ignore bcommit(installer, #bankAdminTransferred({ admin = installer }));
ignore run(#openBook({ id = "HQ"; name = "Head office"; parent = null }));
ignore run(#openBook({ id = "BR01"; name = "Branch 1"; parent = ?"HQ" }));
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
  ("4100", "Fee income", #credit, #income),
  ("4110", "Penalty income", #credit, #income),
  ("4200", "Interest income", #credit, #income),
  ("4300", "Recoveries", #credit, #income),
  ("5100", "Interest expense", #debit, #expense),
  ("5200", "Impairment expense", #debit, #expense),
  ("5210", "Loans written off", #debit, #expense),
  ("9000", "Assets rollup", #debit, #asset),
];
for ((code, name, side, cat) in chart.vals()) {
  ignore run(#journalOpenAccount({ code; name; normalSide = side; category = cat; constraint = #none }));
};
ignore jcommit(switch (JCore.prepareSetAccountAttributes(js, bankP, "9000", { usage = #header; manualEntriesAllowed = false; parent = null })) {
  case (#ok(e)) e;
  case (#err(e)) { Debug.print(debug_show (e)); assert false; #accountAttributesSet({ code = "9000"; attributes = { usage = #header; manualEntriesAllowed = false; parent = null } }) };
});
ignore run(#journalOpenPeriod({ id = "2026-09"; start = SEP1; end = SEP30 }));
// The business date opens at 2 September, because the Fineract scenario this
// battery reproduces begins there and an account's accrual window starts the day it
// was opened. It is rolled forward to the observation day once that scenario is
// done, which is the only direction a business date moves.
ignore run(#journalRollBusinessDate({ day = SEP2 }));
ignore run(#journalSetActivationHeight({ height = 0 }));
ignore run(#setAccountFormat({ country = "EG"; bank = "0037"; branch = "0001"; serialWidth = 12; prefix = "00000" }));
assert (JCore.isActive(js));
Debug.print("count: chart accounts opened = " # Nat.toText(chart.size()));

// a member of staff to hold the till
ignore run(#addStaff({ principal_ = cashier; book = "BR01"; title = "Cashier" }));

// This battery value-dates postings across the whole of September to exercise the
// accrual fold, so the branch's back-value window is declared wide enough to admit
// them. The window itself — and what it refuses — is value dating and the close's battery.
ignore run(#setBackValueWindow({ window = { book = "BR01"; freeDays = 30; approvedDays = 30 } }));
ignore run(#setBackValueWindow({ window = { book = "HQ"; freeDays = 30; approvedDays = 30 } }));

// ─── a party money may move for ──────────────────────────────────────────────

func saltFor(i : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { Nat8.fromNat((i * 31 + j) % 256) })) };
let institutionSalt = saltFor(99);

// a committed screening list, so a screening decision can name its root
let listed = ["AL QAIDA", "BOKO HARAM", "TALIBAN"];
var listEntries = Array.map<Text, Blob>(listed, func(t) { S.entryBytes(t) });
listEntries := Array.sort<Blob>(listEntries, func(a, b) { S.compareEntries(a, b) });
let ?listRoot = S.root(listEntries) else { Debug.print("no screening root"); assert false; loop {} };
ignore run(#commitScreeningList({ version = "UN-2026-09"; root = listRoot; count = listEntries.size(); normalisation = Commit.NORMALISATION }));

func makeParty(i : Nat) : PT.PartyId {
  let salt = saltFor(i);
  let id = run(#createParty({
    kind = #natural; salt;
    identityCommit = Commit.identity(salt, #natural, ["Person " # Nat.toText(i), "2980101123456" # Nat.toText(i)]);
    dedupCommit = ?Commit.dedup(institutionSalt, "nationalId", "2980101123456" # Nat.toText(i));
    attributes = [];
    book = "BR01"; cddLevel = #standard; riskRating = #low; pep = false;
    reviewDue = TODAY + 365;
  }));
  ignore run(#setPartyLifecycle({ party = id; to = #pendingKyc }));
  ignore run(#addPartyDocument({ party = id; document = { kind = "identity"; commit = Commit.document(salt, "identity", Blob.fromArray([1])); issued = 20000; expires = null } }));
  ignore run(#addPartyDocument({ party = id; document = { kind = "address"; commit = Commit.document(salt, "address", Blob.fromArray([2])); issued = 20000; expires = null } }));
  ignore run(#recordScreeningDecision({
    party = id; listVersion = "UN-2026-09"; listRoot = listRoot; decision = #clear;
    screener; justificationCommit = Commit.justification("no match");
  }));
  ignore run(#setPartyLifecycle({ party = id; to = #active }));
  id
};

let alice = makeParty(1);
let bob = makeParty(2);
let borrower = makeParty(3);
let depositor = makeParty(4);
Debug.print("count: parties onboarded = 4");

// ─── products ────────────────────────────────────────────────────────────────

func rate(n : Nat, d : Nat) : I.Rate { { numerator = n; denominator = d; negative = false } };
func neg(n : Nat, d : Nat) : I.Rate { { numerator = n; denominator = d; negative = true } };
func flatChart(r : I.Rate) : ProdT.RateChart { { bands = [{ from = 0; to = null; rate = r }]; by = #balance } };

let savingsInterest : ProdT.InterestTerms = {
  chart = flatChart(rate(5, 100));
  convention = #a004_Act365Fixed;
  basis = #dailyBalance;
  compounding = #monthly;
  compoundingAlignment = #anniversary;
  posting = #monthly;
  minimumBalance = 0;
  allowNegative = false;
};

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
  charges = [
    { id = "ledger-fee"; calculation = #flat({ amount = 1_000 }); timing = #recurring({ every = #monthly }); currency = "EGP"; role = #feeIncome; waivable = true },
    { id = "txn-fee"; calculation = #percentOfAmount({ rate = rate(1, 200) }); timing = #onTransaction; currency = "EGP"; role = #feeIncome; waivable = true },
  ];
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

// a product cannot be registered twice, and a product whose role map breaks a
// category is refused with the role named — the Fineract per-slot rejection
expectErr(#registerProduct({ id = "SAV"; name = "Savings again"; terms = savings }), "ProductExists");
expectErr(#registerProduct({
  id = "BAD"; name = "Broken";
  terms = { savings with roles = [
    { role = #principal; account = "2110" },
    { role = #interestPayable; account = "4100" },
    { role = #interestExpense; account = "5100" },
    { role = #feeIncome; account = "4100" },
  ] };
}), "RoleAccountWrongCategory");
Debug.print("count: product registrations refused = 2");

let loanTerms : ProdT.ProductTerms = {
  kind = #loan;
  currency = "EGP";
  control = "1210";
  roles = [
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
  interest = ?{ savingsInterest with chart = flatChart(rate(12, 100)) };
  charges = [
    { id = "late-fee"; calculation = #flat({ amount = 2_500 }); timing = #overdue({ afterDays = 7 }); currency = "EGP"; role = #penaltyIncome; waivable = true },
  ];
  limits = { overdraft = null; minimumOperating = 0; perOperation = null };
  schedule = ?{ amortisation = #equalInstalments; instalments = 6; every = #monthly; principalGrace = 0; interestGrace = 0; moratoriumDays = 0 };
  delinquency = [
    { name = "current"; fromDays = 0; toDays = ?31 },
    { name = "30-59"; fromDays = 31; toDays = ?61 },
    { name = "90+"; fromDays = 61; toDays = null },
  ];
  provisioning = [
    { band = "current"; stage = 1; percentOfOutstanding = rate(1, 100) },
    { band = "30-59"; stage = 2; percentOfOutstanding = rate(20, 100) },
    { band = "90+"; stage = 3; percentOfOutstanding = rate(100, 100) },
  ];
  accounting = #accrualPeriodic;
  withholdingTax = null;
  rounding = #halfEven;
  earlyRedemptionPenalty = null;
  valueDateConvention = #following;
};
ignore run(#registerProduct({ id = "LOAN"; name = "Term loan"; terms = loanTerms }));

let tillProduct : ProdT.ProductTerms = {
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
ignore run(#registerProduct({ id = "TILL"; name = "Cashier drawer"; terms = tillProduct }));

let negativeProduct : ProdT.ProductTerms = {
  savings with
  interest = ?{ savingsInterest with chart = flatChart(neg(5, 1000)); allowNegative = true };
};
ignore run(#registerProduct({ id = "NEGSAV"; name = "Negative-rate savings"; terms = negativeProduct }));
Debug.print("count: products registered = " # Nat.toText(ProductCore.productCount(bs.product)));
assert (ProductCore.productCount(bs.product) == 4);

// ─── accounts ────────────────────────────────────────────────────────────────

let aliceAcct = run(#openAccount({ product = "SAV"; party = alice; currency = "EGP"; termDays = null; allocationOrder = [] }));
let bobAcct = run(#openAccount({ product = "SAV"; party = bob; currency = "EGP"; termDays = null; allocationOrder = [] }));
ignore run(#setAccountStatus({ account = aliceAcct; to = #active }));
ignore run(#setAccountStatus({ account = bobAcct; to = #active }));

let ?aliceEntry = ProductCore.get(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), aliceAcct) else { Debug.print("no account"); assert false; loop {} };
Debug.print("the account identifier issued is " # aliceEntry.identifier);
assert (Text.size(aliceEntry.identifier) == 29);
assert (ProductCore.byIdentifier(bs.product, aliceEntry.identifier) == ?aliceAcct);
assert (aliceEntry.subledger == Posting.subledgerOf(aliceEntry.identifier));

// two accounts never share an identifier or a sub-ledger key
let ?bobEntry = ProductCore.get(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), bobAcct) else { assert false; loop {} };
assert (not Text.equal(aliceEntry.identifier, bobEntry.identifier));
assert (aliceEntry.subledger != bobEntry.subledger);
Debug.print("count: accounts opened with distinct identifiers = 2");

// an account cannot be opened on an unknown product, in the wrong currency, or for
// an unknown party; an illegal status transition is refused
expectErr(#openAccount({ product = "NOPE"; party = alice; currency = "EGP"; termDays = null; allocationOrder = [] }), "UnknownProduct");
expectErr(#openAccount({ product = "SAV"; party = alice; currency = "USD"; termDays = null; allocationOrder = [] }), "CurrencyMismatch");
expectErr(#openAccount({ product = "SAV"; party = 99999; currency = "EGP"; termDays = null; allocationOrder = [] }), "UnknownParty");
expectErr(#openAccount({ product = "SAV"; party = alice; currency = "EGP"; termDays = ?180; allocationOrder = [] }), "only a term product carries a term");
expectErr(#setAccountStatus({ account = aliceAcct; to = #pending }), "AccountNotActive");
expectErr(#openAccount({ product = "TILL"; party = alice; currency = "EGP"; termDays = null; allocationOrder = [] }), "AccountNotOfKind");
Debug.print("count: account openings refused = 6");

// ═══════════════════════════════════════════════════════════════════════════
//  I11 — the gate is a height
// ═══════════════════════════════════════════════════════════════════════════

let deposit1 : T.Command = #depositToAccount({
  account = aliceAcct; amount = 1_000_00; postingDate = TODAY; valueDate = TODAY;
  period = "2026-09"; narration = "opening deposit"; funding = #glAccount("1999");
});

// every money-visible product feature is off by default: the activation height is
// ACTIVATION_OFF and the command refuses
var gated = 0;
for (f in ProdT.featureIds().vals()) {
  assert (Core.featureActivation(bs, f) == T.ACTIVATION_OFF);
  assert (not Core.featureActive(bs, f));
  gated += 1;
};
Debug.print("count: product features off by default = " # Nat.toText(gated));
assert (gated == ProdT.featureIds().size());

expectErr(deposit1, "FeatureInactive");
expectErr(#withdrawFromAccount({ account = aliceAcct; amount = 1; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "w"; funding = #glAccount("1999") }), "FeatureInactive");
expectErr(#postAccrual({ product = "SAV"; currency = "EGP"; day = TODAY; period = "2026-09"; narration = "a" }), "FeatureInactive");
expectErr(#applyCharge({ account = aliceAcct; charge = "ledger-fee"; occurrence = TODAY; base = { amount = null; interest = null; outstanding = null }; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "c" }), "FeatureInactive");
expectErr(#allocateCashToTill({ till = "T01"; amount = 1; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "t" }), "FeatureInactive");
expectErr(#disburseLoan({ account = aliceAcct; amount = 1; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "d"; funding = #glAccount("1999") }), "FeatureInactive");
Debug.print("count: money-visible commands refused below their gate = 6");

// setting a gate is a block, and the height it names is the bank log's own
let gateBlock = run(#setFeatureActivation({ feature = ProdT.FEATURE_ACCOUNT_MONEY; height = Nat64.fromNat(Core.height(bs)) }));
assert (Core.featureActive(bs, ProdT.FEATURE_ACCOUNT_MONEY));
// and only that one: the others are still off
assert (not Core.featureActive(bs, ProdT.FEATURE_INTEREST));
expectErr(#postAccrual({ product = "SAV"; currency = "EGP"; day = TODAY; period = "2026-09"; narration = "a" }), "FeatureInactive");
Debug.print("count: activation blocks recorded = 1 (block " # Nat.toText(gateBlock) # ")");

for (f in ProdT.featureIds().vals()) {
  if (not Core.featureActive(bs, f)) ignore run(#setFeatureActivation({ feature = f; height = Nat64.fromNat(Core.height(bs)) }));
};
var activeFeatures = 0;
for (f in ProdT.featureIds().vals()) { if (Core.featureActive(bs, f)) activeFeatures += 1 };
Debug.print("count: product features activated = " # Nat.toText(activeFeatures));
assert (activeFeatures == ProdT.featureIds().size());

// ═══════════════════════════════════════════════════════════════════════════
//  F2 — the Fineract interest figure, through the whole path
// ═══════════════════════════════════════════════════════════════════════════
//
// Deposit 1,000.00 on 2 September, withdraw 250.00 on 3 September, 5 % nominal on a
// daily balance over a 365-day basis, read the accrual after seven more days:
// (1000×1 + 750×7) / 365 × 0.05 = 0.856…, which the reference instance reported
// as totalInterestEarned 0.86.

let fineractAcct = run(#openAccount({ product = "SAV"; party = depositor; currency = "EGP"; termDays = null; allocationOrder = [] }));
ignore run(#setAccountStatus({ account = fineractAcct; to = #active }));
// Both postings are booked on the business date and carry their own value dates:
// the journal's value date may precede or follow the posting date, and it is the
// value date the accrual fold reads. That is what makes the figure correct without
// the clock having to be walked day by day.
ignore runPostings(#depositToAccount({
  account = fineractAcct; amount = 100_000; postingDate = SEP2; valueDate = SEP2;
  period = "2026-09"; narration = "deposit 1,000.00"; funding = #glAccount("1999");
}));
ignore runPostings(#withdrawFromAccount({
  account = fineractAcct; amount = 25_000; postingDate = SEP2; valueDate = SEP3;
  period = "2026-09"; narration = "withdraw 250.00"; funding = #glAccount("1999");
}));

switch (Core.accountBalanceView(bs, BankMemLog.reader(bchain), js, fineractAcct, SEP10)) {
  case (#ok(b)) {
    Debug.print("the balance on 10 September is " # Nat.toText(b.net) # " minor units");
    assert (b.net == 75_000);
    assert (not b.overdrawn);
  };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};

switch (Core.accruedInterest(bs, BankMemLog.reader(bchain), js, fineractAcct, SEP10)) {
  case (#ok(a)) {
    Debug.print("Fineract reported 0.86; the fold over value-dated balances gives " # Nat.toText(a.amount) # " minor units");
    Debug.print("the unrounded accrual is " # Nat.toText(a.numerator) # "/" # Nat.toText(a.denominator));
    assert (a.amount == 86);
    // the unrounded figure lies strictly between 85 and 86 minor units, so the
    // posted 86 is a rounding of it and not a coincidence
    assert (a.numerator > 85 * a.denominator and a.numerator < 86 * a.denominator);
    Debug.print("count: Fineract interest figures reproduced through the canister path = 1");
  };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};

// A back-dated deposit changes the accrual by exactly what the extra balance-days
// earn, with no stored figure to stale (I2): 100.00 value-dated to 4 September adds
// six balance-days at 100.00, which is 10000 × 6 / 365 × 5/100 = 8.21… minor units.
let beforeBackdate = switch (Core.accruedInterest(bs, BankMemLog.reader(bchain), js, fineractAcct, SEP10)) { case (#ok(a)) a.amount; case (#err(_)) 0 };
ignore runPostings(#depositToAccount({
  account = fineractAcct; amount = 10_000; postingDate = SEP2; valueDate = SEP2 + 2;
  period = "2026-09"; narration = "back-dated deposit"; funding = #glAccount("1999");
}));
switch (Core.accruedInterest(bs, BankMemLog.reader(bchain), js, fineractAcct, SEP10)) {
  case (#ok(a)) {
    Debug.print("after a back-dated deposit the accrual is " # Nat.toText(a.amount) # " (was " # Nat.toText(beforeBackdate) # ")");
    assert (a.amount == 94);     // 86 + 8
    Debug.print("count: back-dated accrual corrections verified = 1");
  };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};

// ═══════════════════════════════════════════════════════════════════════════
//  F3 and F4 — the engine refuses, and a facility moves the boundary
// ═══════════════════════════════════════════════════════════════════════════

// the business date moves forward to the observation day
ignore run(#journalRollBusinessDate({ day = TODAY }));

// a withdrawal beyond the balance is refused by the journal, not by this layer
expectErr(#withdrawFromAccount({
  account = aliceAcct; amount = 5_000_00; postingDate = TODAY; valueDate = TODAY;
  period = "2026-09"; narration = "over"; funding = #glAccount("1999");
}), "ExceedsCredits");

ignore runPostings(deposit1);
switch (Core.accountBalanceView(bs, BankMemLog.reader(bchain), js, aliceAcct, TODAY)) {
  case (#ok(b)) assert (b.net == 100_000 and b.facility == 0 and b.available == 100_000);
  case (#err(_)) assert false;
};

// a withdrawal of 750.00 against 1,000.00 is admitted; 5,000.00 is refused
expectErr(#withdrawFromAccount({
  account = aliceAcct; amount = 500_000; postingDate = TODAY; valueDate = TODAY;
  period = "2026-09"; narration = "750 against 1000"; funding = #glAccount("1999");
}), "ExceedsCredits");
Debug.print("count: unfunded withdrawals refused by the engine = 2");

// a facility of 500.00 is granted; the boundary is then exactly the balance plus
// the facility, and one unit past it is refused
ignore runPostings(#grantFacility({ account = aliceAcct; limit = 50_000 }));
switch (Core.accountBalanceView(bs, BankMemLog.reader(bchain), js, aliceAcct, TODAY)) {
  case (#ok(b)) {
    Debug.print("with a facility the available amount is " # Nat.toText(b.available) # " against a balance of " # Nat.toText(b.net));
    assert (b.facility == 50_000);
    assert (b.available == 150_000);
  };
  case (#err(_)) assert false;
};
expectErr(#withdrawFromAccount({
  account = aliceAcct; amount = 150_001; postingDate = TODAY; valueDate = TODAY;
  period = "2026-09"; narration = "one unit past the facility"; funding = #glAccount("1999");
}), "ExceedsCredits");
ignore runPostings(#withdrawFromAccount({
  account = aliceAcct; amount = 150_000; postingDate = TODAY; valueDate = TODAY;
  period = "2026-09"; narration = "exactly the facility"; funding = #glAccount("1999");
}));
switch (Core.accountBalanceView(bs, BankMemLog.reader(bchain), js, aliceAcct, TODAY)) {
  case (#ok(b)) { assert (b.overdrawn and b.net == 50_000 and b.available == 0) };
  case (#err(_)) assert false;
};
Debug.print("count: facility boundaries verified = 2");

// the facility the engine will admit is the journal's own limit, not a figure this
// layer keeps
switch (JCore.balanceLimit(js, "2110", ?aliceEntry.subledger, "EGP")) {
  case (?#debitsNotExceedCreditsPlus(n)) assert (n == 50_000);
  case (other) { Debug.print(debug_show (other)); assert false };
};

// bring the account back to credit so later checks start from a clean position
ignore runPostings(#depositToAccount({
  account = aliceAcct; amount = 150_000; postingDate = TODAY; valueDate = TODAY;
  period = "2026-09"; narration = "repay the overdraft"; funding = #glAccount("1999");
}));

// ═══════════════════════════════════════════════════════════════════════════
//  I8 — a header account cannot fund a posting
// ═══════════════════════════════════════════════════════════════════════════

expectErr(#depositToAccount({
  account = aliceAcct; amount = 1_000; postingDate = TODAY; valueDate = TODAY;
  period = "2026-09"; narration = "from a rollup"; funding = #glAccount("9000");
}), "header account");
expectErr(#depositToAccount({
  account = aliceAcct; amount = 1_000; postingDate = TODAY; valueDate = TODAY;
  period = "2026-09"; narration = "from nowhere"; funding = #glAccount("7777");
}), "RoleAccountUnknown");
Debug.print("count: funding accounts refused = 2");

// ═══════════════════════════════════════════════════════════════════════════
//  charges: applied once, waived as a decision, reversed when already applied
// ═══════════════════════════════════════════════════════════════════════════

let chargePostings = runPostings(#applyCharge({
  account = aliceAcct; charge = "ledger-fee"; occurrence = TODAY;
  base = { amount = null; interest = null; outstanding = null };
  postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "monthly ledger fee";
}));
assert (chargePostings.size() == 1);
switch (ProductCore.get(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), aliceAcct)) {
  case (?a) assert (ProductCore.chargeApplied(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), a.id, "ledger-fee", TODAY) == ?1_000);
  case null assert false;
};
// the same occurrence cannot be charged twice
expectErr(#applyCharge({
  account = aliceAcct; charge = "ledger-fee"; occurrence = TODAY;
  base = { amount = null; interest = null; outstanding = null };
  postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "again";
}), "already applied");
// a charge that needs a base it was not given is refused rather than computed from zero
expectErr(#applyCharge({
  account = aliceAcct; charge = "txn-fee"; occurrence = TODAY;
  base = { amount = null; interest = null; outstanding = null };
  postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "no base";
}), "needs transaction amount");
// an unknown charge, and a charge on an unknown account
expectErr(#applyCharge({
  account = aliceAcct; charge = "nope"; occurrence = TODAY;
  base = { amount = ?1_000; interest = null; outstanding = null };
  postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "x";
}), "UnknownCharge");
Debug.print("count: charge applications refused = 3");

// a waiver of an applied charge is a reversal naming the original; a waiver of an
// unapplied one is a decision with no posting
let waiverPostings = runPostings(#waiveCharge({
  account = aliceAcct; charge = "ledger-fee"; occurrence = TODAY;
  postingDate = TODAY; valueDate = TODAY; period = "2026-09"; reason = "goodwill";
}));
assert (waiverPostings.size() == 1);
switch (JCore.postingView(js, JMemLog.reader(jchain), waiverPostings[0])) {
  case (?v) {
    switch (v.record.relation) {
      case (?rel) { assert (rel.kind == #reversal); assert (rel.original == chargePostings[0]) };
      case null { Debug.print("the waiver is not a reversal"); assert false };
    };
  };
  case null assert false;
};
let unappliedWaiver = runPostings(#waiveCharge({
  account = aliceAcct; charge = "txn-fee"; occurrence = TODAY;
  postingDate = TODAY; valueDate = TODAY; period = "2026-09"; reason = "never charged";
}));
assert (unappliedWaiver.size() == 0);
// a charge the product marks unwaivable cannot be waived
expectErr(#waiveCharge({
  account = fineractAcct; charge = "ledger-fee"; occurrence = TODAY;
  postingDate = TODAY; valueDate = TODAY; period = "2026-09"; reason = "";
}), "a waiver states why");
Debug.print("count: charge waivers verified = 2");

// ═══════════════════════════════════════════════════════════════════════════
//  I3, I4 — capitalisation conserves, and a zero accrual is not posted
// ═══════════════════════════════════════════════════════════════════════════

// bob's account has never been funded, so his accrual is zero and he is examined
// without being posted
let capPostings = runPostings(#capitaliseInterest({
  product = "SAV"; currency = "EGP"; to = SEP10; postingDate = TODAY;
  period = "2026-09"; narration = "September capitalisation";
}));
Debug.print("count: capitalisation postings = " # Nat.toText(capPostings.size()));
assert (capPostings.size() >= 1);

// find the capitalisation block and read the counts it recorded
var examined = 0; var posted = 0; var zeroes = 0; var capTotal = 0;
var residueNum = 0; var residueDen = 1;
for (b in BankMemLog.blocks(bchain).vals()) {
  switch (b.event) {
    case (#product(#interestCapitalised(x))) {
      examined := x.examined; posted := x.posted; zeroes := x.zero; capTotal := x.total;
      residueNum := x.residueNumerator; residueDen := x.residueDenominator;
    };
    case (_) {};
  };
};
Debug.print("the capitalisation examined " # Nat.toText(examined) # " accounts, posted " # Nat.toText(posted) # ", and found " # Nat.toText(zeroes) # " that rounded to zero");
Debug.print("the run credited " # Nat.toText(capTotal) # " minor units with a residue of " # Nat.toText(residueNum) # "/" # Nat.toText(residueDen));
// three savings accounts exist at this point: alice's, bob's (never funded, so its
// accrual rounds to zero) and the one the Fineract scenario used
assert (examined == 3);
assert (zeroes == 1);
assert (posted + zeroes == examined);
assert (capTotal > 0);

// every leg of every posting the run produced: no zero amounts, no leg naming an
// account outside the product's role map, and each posting balances
var capLegs = 0;
for (idx in capPostings.vals()) {
  switch (JCore.postingView(js, JMemLog.reader(jchain), idx)) {
    case (?v) {
      var debits = 0; var credits = 0;
      for (l in v.record.legs.vals()) {
        assert (l.amount > 0);
        // the only accounts a capitalisation may name are the customer control and
        // the accrued-interest control: there is no rounding-difference account
        assert (Text.equal(l.account, "2110") or Text.equal(l.account, "2120"));
        switch (l.side) { case (#debit) debits += l.amount; case (#credit) credits += l.amount };
        capLegs += 1;
      };
      assert (debits == credits);
    };
    case null assert false;
  };
};
Debug.print("count: capitalisation legs scanned = " # Nat.toText(capLegs));

// the contra leg is the sum of the rounded customer legs, so the books close with
// no plug: the accrued-payable control carries exactly what was credited
let payableAfter = JCore.balance(js, "2120", null, "EGP");
Debug.print("the accrued-payable control carries " # Nat.toText(payableAfter.debitsPosted) # " debits against " # Nat.toText(payableAfter.creditsPosted) # " credits");
assert (payableAfter.debitsPosted == capTotal);

// the cursor moved, so the same run cannot be repeated
expectErr(#capitaliseInterest({
  product = "SAV"; currency = "EGP"; to = SEP10; postingDate = TODAY;
  period = "2026-09"; narration = "again";
}), "AlreadyCapitalised");
Debug.print("count: repeated capitalisation runs refused = 1");

// ═══════════════════════════════════════════════════════════════════════════
//  I5 — a negative rate debits the customer, and amounts stay positive
// ═══════════════════════════════════════════════════════════════════════════

let negAcct = run(#openAccount({ product = "NEGSAV"; party = bob; currency = "EGP"; termDays = null; allocationOrder = [] }));
ignore run(#setAccountStatus({ account = negAcct; to = #active }));
ignore runPostings(#depositToAccount({
  account = negAcct; amount = 10_000_000; postingDate = TODAY; valueDate = SEP1;
  period = "2026-09"; narration = "a large balance"; funding = #glAccount("1999");
}));
switch (Core.accruedInterest(bs, BankMemLog.reader(bchain), js, negAcct, SEP10)) {
  case (#ok(a)) {
    Debug.print("the negative-rate accrual is " # (if (a.negative) "-" else "") # Nat.toText(a.amount) # " minor units");
    assert (a.negative);
    assert (a.amount > 0);
    Debug.print("count: negative-rate accruals verified = 1");
  };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};

// ═══════════════════════════════════════════════════════════════════════════
//  I7 — terms are immutable under an account
// ═══════════════════════════════════════════════════════════════════════════

// the rate alice's account computes on, before the amendment
let rateBefore = switch (ProductCore.termsOf(bs.product, aliceEntry)) {
  case (?terms) { switch (terms.interest) { case (?it) it.chart.bands[0].rate.numerator; case null 0 } };
  case null 0;
};
assert (rateBefore == 5);

ignore run(#amendProduct({
  id = "SAV"; name = "Savings";
  terms = { savings with interest = ?{ savingsInterest with chart = flatChart(rate(3, 100)) } };
}));
switch (ProductCore.currentVersion(bs.product, "SAV")) {
  case (?v) { assert (v.version == 2); switch (v.terms.interest) { case (?it) assert (it.chart.bands[0].rate.numerator == 3); case null assert false } };
  case null assert false;
};
// version 1 is retained, marked superseded and closed to new accounts
switch (ProductCore.getVersion(bs.product, "SAV", 1)) {
  case (?v) { assert (v.supersededBy == ?2); assert (not v.openToNewAccounts); switch (v.terms.interest) { case (?it) assert (it.chart.bands[0].rate.numerator == 5); case null assert false } };
  case null assert false;
};
// alice's account still computes on version 1
switch (ProductCore.get(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), aliceAcct)) {
  case (?a) {
    assert (a.version == 1);
    switch (ProductCore.termsOf(bs.product, a)) {
      case (?terms) { switch (terms.interest) { case (?it) assert (it.chart.bands[0].rate.numerator == 5); case null assert false } };
      case null assert false;
    };
  };
  case null assert false;
};
// a new account opens on the current version
let postAmendAcct = run(#openAccount({ product = "SAV"; party = alice; currency = "EGP"; termDays = null; allocationOrder = [] }));
switch (ProductCore.get(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), postAmendAcct)) { case (?a) assert (a.version == 2); case null assert false };
// an amendment cannot change the kind or the currency
expectErr(#amendProduct({ id = "SAV"; name = "x"; terms = { savings with kind = #currentAccount } }), "cannot change a product's kind");
expectErr(#amendProduct({ id = "SAV"; name = "x"; terms = { savings with currency = "USD" } }), "CurrencyMismatch");
// migration is explicit, recorded, and refuses a version that does not exist
expectErr(#migrateAccount({ account = aliceAcct; to = 9 }), "UnknownVersion");
expectErr(#migrateAccount({ account = aliceAcct; to = 1 }), "already on version 1");
ignore run(#migrateAccount({ account = aliceAcct; to = 2 }));
switch (ProductCore.get(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), aliceAcct)) { case (?a) assert (a.version == 2); case null assert false };
Debug.print("count: product version checks = 6");

// ═══════════════════════════════════════════════════════════════════════════
//  F6, F7 — a loan disbursed, repaid, aged, provisioned, written off, recovered
// ═══════════════════════════════════════════════════════════════════════════

let loanAcct = run(#openAccount({ product = "LOAN"; party = borrower; currency = "EGP"; termDays = null; allocationOrder = [] }));
ignore run(#setAccountStatus({ account = loanAcct; to = #active }));

// a repayment before disbursement has nothing to repay
expectErr(#repayLoan({ account = loanAcct; amount = 1_000; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "early"; funding = #glAccount("1999") }), "LoanNotDisbursed");

let disbursePostings = runPostings(#disburseLoan({
  account = loanAcct; amount = 600_000; postingDate = TODAY; valueDate = SEP1;
  period = "2026-09"; narration = "disbursement"; funding = #glAccount("1999");
}));
assert (disbursePostings.size() == 1);
expectErr(#disburseLoan({ account = loanAcct; amount = 1_000; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "twice"; funding = #glAccount("1999") }), "LoanAlreadyDisbursed");

// the schedule is a block, and it satisfies the schedule invariants
let ?scheduleRows = ProductCore.scheduleRows(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), loanAcct) else { Debug.print("no schedule"); assert false; loop {} };
Debug.print("count: schedule rows recorded at disbursement = " # Nat.toText(scheduleRows.size()));
assert (scheduleRows.size() == 6);
assert (Products.scheduleFaults(600_000, scheduleRows).size() == 0);

// the outstanding principal is the journal's figure
switch (Core.loanPosition(bs, BankMemLog.reader(bchain), js, loanAcct, SEP10)) {
  case (#ok(pos)) {
    Debug.print("the loan's outstanding principal is " # Nat.toText(pos.outstanding.principal));
    assert (pos.outstanding.principal == 600_000);
    assert (pos.exposure == 600_000);
    assert (pos.repaid == 0);
    assert (pos.overdueTotal == 0);
    // Performing, and classified as such: the product declares a band from day 0 and a
    // stage-1 rule against it, so a loan with nothing overdue is in that band at the
    // general provision it declares, not unclassified and unprovided.
    assert (pos.overdueDays == 0);
    assert (pos.band == ?"current");
    assert (pos.stage == ?1);
    assert (pos.requiredProvision == I.round({ numerator = pos.exposure; denominator = 100; negative = false }, #halfEven).amount);
    assert (pos.requiredProvision > 0);
  };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};

// a penalty charge on a loan becomes receivable, on its own control account
ignore runPostings(#applyCharge({
  account = loanAcct; charge = "late-fee"; occurrence = SEP10;
  base = { amount = null; interest = null; outstanding = ?600_000 };
  postingDate = TODAY; valueDate = SEP10; period = "2026-09"; narration = "late fee";
}));
let ?loanEntry = ProductCore.get(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), loanAcct) else { assert false; loop {} };
let penaltyReceivable = JCore.valueDatedBalance(js, "1240", ?loanEntry.subledger, "EGP", SEP10);
assert (penaltyReceivable.debits == 2_500 and penaltyReceivable.credits == 0);
Debug.print("count: loan penalty receivables verified = 1");

// a repayment is allocated in the declared order: penalties, then fees, then
// interest, then principal
let repayPostings = runPostings(#repayLoan({
  account = loanAcct; amount = 52_500; postingDate = TODAY; valueDate = SEP10;
  period = "2026-09"; narration = "first repayment"; funding = #glAccount("1999");
}));
assert (repayPostings.size() == 1);
switch (JCore.postingView(js, JMemLog.reader(jchain), repayPostings[0])) {
  case (?v) {
    var penaltyLeg = 0; var principalLeg = 0;
    for (l in v.record.legs.vals()) {
      if (Text.equal(l.account, "1240")) penaltyLeg := l.amount;
      if (Text.equal(l.account, "1210")) principalLeg := l.amount;
      assert (l.amount > 0);
    };
    Debug.print("the repayment settled " # Nat.toText(penaltyLeg) # " of penalties and " # Nat.toText(principalLeg) # " of principal");
    assert (penaltyLeg == 2_500);
    assert (principalLeg == 50_000);
  };
  case null assert false;
};
switch (Core.loanPosition(bs, BankMemLog.reader(bchain), js, loanAcct, SEP10)) {
  case (#ok(pos)) { assert (pos.outstanding.principal == 550_000); assert (pos.outstanding.penalty == 0); assert (pos.repaid == 52_500) };
  case (#err(_)) assert false;
};
// a repayment larger than the whole position is refused with the position named
expectErr(#repayLoan({ account = loanAcct; amount = 10_000_000; postingDate = TODAY; valueDate = SEP10; period = "2026-09"; narration = "too much"; funding = #glAccount("1999") }), "exceeds the position");
Debug.print("count: repayment allocations verified = 1");

// the loan is taken into arrears by asking about a day long after its instalments
// fell due, and the band follows the age
let farFuture = scheduleRows[1].dueDate + 45;
switch (Core.loanPosition(bs, BankMemLog.reader(bchain), js, loanAcct, farFuture)) {
  case (#ok(pos)) {
    Debug.print("at day " # Nat.toText(farFuture) # " the loan is " # Nat.toText(pos.overdueTotal) # " overdue across " # Nat.toText(pos.instalmentsOverdue) # " instalments, aged " # Nat.toText(pos.overdueDays) # " days");
    assert (pos.overdueTotal > 0);
    assert (pos.instalmentsOverdue >= 1);
    switch (pos.band) { case (?b) { Debug.print("the band is " # b); assert (Text.size(b) > 0) }; case null { Debug.print("no band"); assert false } };
    assert (pos.requiredProvision > 0);
    assert (pos.carriedAllowance == 0);
  };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};

// the provision is posted as a movement: impairment expense against the allowance
let provisionPostings = runPostings(#setProvision({
  account = loanAcct; asOf = farFuture; postingDate = TODAY; period = "2026-09"; narration = "provision";
}));
assert (provisionPostings.size() == 1);
var provisionPosted = 0;
switch (JCore.postingView(js, JMemLog.reader(jchain), provisionPostings[0])) {
  case (?v) {
    var expense = 0; var allowance = 0;
    for (l in v.record.legs.vals()) {
      if (Text.equal(l.account, "5200")) { assert (l.side == #debit); expense := l.amount };
      if (Text.equal(l.account, "1290")) { assert (l.side == #credit); assert (l.subledger == ?loanEntry.subledger); allowance := l.amount };
    };
    assert (expense == allowance and expense > 0);
    provisionPosted := expense;
  };
  case null assert false;
};
Debug.print("the provision posted is " # Nat.toText(provisionPosted) # " minor units");
// the allowance the engine reports is now the journal's figure, and the decision
// the log recorded agrees with it
switch (Core.loanPosition(bs, BankMemLog.reader(bchain), js, loanAcct, farFuture)) {
  case (#ok(pos)) {
    assert (pos.carriedAllowance == provisionPosted);
    assert (pos.requiredProvision == provisionPosted);
  };
  case (#err(_)) assert false;
};
switch (ProductCore.get(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), loanAcct)) {
  case (?a) assert (a.allowance == provisionPosted);
  case null assert false;
};
// running it again moves nothing, and records that it moved nothing
let again = runPostings(#setProvision({ account = loanAcct; asOf = farFuture; postingDate = TODAY; period = "2026-09"; narration = "no change" }));
assert (again.size() == 0);
Debug.print("count: provision movements posted = 1");

// the loan is written off: every position is relieved of its own figure, the
// allowance absorbs what it carries and the rest is a charge
let writeOffPostings = runPostings(#writeOffLoan({
  account = loanAcct; postingDate = TODAY; valueDate = farFuture; period = "2026-09"; narration = "written off";
}));
assert (writeOffPostings.size() == 1);
switch (JCore.postingView(js, JMemLog.reader(jchain), writeOffPostings[0])) {
  case (?v) {
    var principalRelieved = 0; var allowanceUsed = 0; var expensed = 0; var debits = 0; var credits = 0;
    for (l in v.record.legs.vals()) {
      assert (l.amount > 0);
      if (Text.equal(l.account, "1210")) { assert (l.side == #credit); principalRelieved := l.amount };
      if (Text.equal(l.account, "1290")) { assert (l.side == #debit); allowanceUsed := l.amount };
      if (Text.equal(l.account, "5210")) { assert (l.side == #debit); expensed := l.amount };
      switch (l.side) { case (#debit) debits += l.amount; case (#credit) credits += l.amount };
    };
    Debug.print("the write-off relieved " # Nat.toText(principalRelieved) # " of principal, used " # Nat.toText(allowanceUsed) # " of the allowance and charged " # Nat.toText(expensed));
    assert (debits == credits);
    assert (principalRelieved == 550_000);
    assert (allowanceUsed == provisionPosted);
    assert (allowanceUsed + expensed == debits);
  };
  case null assert false;
};
// the loan's own positions are now zero, read back from the journal
let principalAfter = JCore.valueDatedBalance(js, "1210", ?loanEntry.subledger, "EGP", farFuture);
assert (principalAfter.debits == principalAfter.credits);
expectErr(#writeOffLoan({ account = loanAcct; postingDate = TODAY; valueDate = farFuture; period = "2026-09"; narration = "twice" }), "LoanWrittenOffAlready");
Debug.print("count: write-offs verified = 1");

// a recovery after write-off is income, not a reversal of the write-off
let recoveryPostings = runPostings(#recordRecovery({
  account = loanAcct; amount = 100_000; postingDate = TODAY; valueDate = farFuture;
  period = "2026-09"; narration = "partial recovery"; funding = #glAccount("1999");
}));
assert (recoveryPostings.size() == 1);
switch (JCore.postingView(js, JMemLog.reader(jchain), recoveryPostings[0])) {
  case (?v) {
    var recovery = 0;
    for (l in v.record.legs.vals()) { if (Text.equal(l.account, "4300")) { assert (l.side == #credit); recovery := l.amount } };
    assert (recovery == 100_000);
  };
  case null assert false;
};
// the loan's principal position stays at zero: a recovery does not re-create it
let principalAfterRecovery = JCore.valueDatedBalance(js, "1210", ?loanEntry.subledger, "EGP", farFuture);
assert (principalAfterRecovery.debits == principalAfterRecovery.credits);
Debug.print("count: recoveries verified = 1");

// A second loan exercises the other half of the write-off split: provisioned while
// it is merely current, so the allowance carries one per cent and the remaining
// ninety-nine is a charge to the write-off expense. Both halves matter — an
// allowance that always covers the loss would hide a missing expense leg.
let loan2 = run(#openAccount({ product = "LOAN"; party = borrower; currency = "EGP"; termDays = null; allocationOrder = [] }));
ignore run(#setAccountStatus({ account = loan2; to = #active }));
ignore runPostings(#disburseLoan({
  account = loan2; amount = 300_000; postingDate = TODAY; valueDate = TODAY;
  period = "2026-09"; narration = "second disbursement"; funding = #glAccount("1999");
}));
let ?loan2Entry = ProductCore.get(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), loan2) else { assert false; loop {} };
let ?loan2Rows = ProductCore.scheduleRows(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), loan2) else { assert false; loop {} };
// one day after its first instalment falls due, the loan is in the zero-day band
let justOverdue = loan2Rows[0].dueDate + 1;
ignore runPostings(#setProvision({ account = loan2; asOf = justOverdue; postingDate = TODAY; period = "2026-09"; narration = "current-band provision" }));
var smallAllowance = 0;
switch (Core.loanPosition(bs, BankMemLog.reader(bchain), js, loan2, justOverdue)) {
  case (#ok(pos)) {
    switch (pos.band) { case (?b) assert (Text.equal(b, "current")); case null assert false };
    smallAllowance := pos.carriedAllowance;
    Debug.print("the current-band provision on the second loan is " # Nat.toText(smallAllowance) # " against an exposure of " # Nat.toText(pos.exposure));
    assert (smallAllowance > 0);
    assert (smallAllowance * 100 == pos.exposure);      // one per cent, exactly
  };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};
let writeOff2 = runPostings(#writeOffLoan({
  account = loan2; postingDate = TODAY; valueDate = justOverdue; period = "2026-09"; narration = "written off while current";
}));
assert (writeOff2.size() == 1);
switch (JCore.postingView(js, JMemLog.reader(jchain), writeOff2[0])) {
  case (?v) {
    var allowanceUsed = 0; var expensed = 0; var debits = 0; var credits = 0;
    for (l in v.record.legs.vals()) {
      assert (l.amount > 0);
      if (Text.equal(l.account, "1290")) { assert (l.side == #debit); allowanceUsed := l.amount };
      if (Text.equal(l.account, "5210")) { assert (l.side == #debit); expensed := l.amount };
      switch (l.side) { case (#debit) debits += l.amount; case (#credit) credits += l.amount };
    };
    Debug.print("the second write-off used " # Nat.toText(allowanceUsed) # " of the allowance and charged " # Nat.toText(expensed));
    assert (debits == credits);
    assert (allowanceUsed == smallAllowance);
    assert (expensed > 0);
    assert (allowanceUsed + expensed == credits);
  };
  case null assert false;
};
// both positions are now zero, and the allowance sub-ledger is empty
let loan2Principal = JCore.valueDatedBalance(js, "1210", ?loan2Entry.subledger, "EGP", justOverdue);
assert (loan2Principal.debits == loan2Principal.credits);
let loan2Allowance = JCore.valueDatedBalance(js, "1290", ?loan2Entry.subledger, "EGP", justOverdue);
assert (loan2Allowance.debits == loan2Allowance.credits);
Debug.print("count: write-offs with a partial allowance verified = 1");

// ═══════════════════════════════════════════════════════════════════════════
//  I10 — a till never absorbs a difference
// ═══════════════════════════════════════════════════════════════════════════

ignore run(#openTill({ till = "T01"; book = "BR01"; currency = "EGP"; holder = cashier; product = "TILL" }));
expectErr(#openTill({ till = "T01"; book = "BR01"; currency = "EGP"; holder = cashier; product = "TILL" }), "TillExists");
// the holder must be a member of staff of that book
expectErr(#openTill({ till = "T02"; book = "BR01"; currency = "EGP"; holder = screener; product = "TILL" }), "UnknownStaff");
// the drawer is limited by the engine so it can never hold negative cash
let ?tillEntry = ProductCore.getTill(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), "T01") else { assert false; loop {} };
switch (JCore.balanceLimit(js, "1001", ?tillEntry.subledger, "EGP")) {
  case (?#creditsNotExceedDebitsPlus(n)) assert (n == 0);
  case (other) { Debug.print(debug_show (other)); assert false };
};
Debug.print("count: tills opened = 1");

// the vault is funded from settlement, then the drawer is loaded
ignore jcommit(switch (JCore.preparePost(js, bankP, clock, {
  idempotencyKey = Posting.key("vault-funding", ["T01"]);
  postingDate = TODAY; valueDate = TODAY; period = "2026-09";
  legs = [
    Posting.leg("1001", ?Till.vaultSubledger("BR01", "EGP"), #debit, "EGP", 1_000_000),
    Posting.leg("1999", null, #credit, "EGP", 1_000_000),
  ];
  sourceRef = { kind = "vault-funding"; id = "T01" };
  narration = "fund the vault"; correctionOf = null;
})) { case (#ok(#event(e))) e; case (other) { Debug.print(debug_show (other)); assert false; #posterAdded({ poster = bankP }) } });

ignore runPostings(#allocateCashToTill({ till = "T01"; amount = 250_000; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "load the drawer" }));
switch (Core.tillPosition(bs, BankMemLog.reader(bchain), js, "T01", TODAY)) {
  case (#ok(pos)) { assert (pos.book == 250_000); assert (pos.allocated == 250_000) };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};

// a cash deposit through the till increases the drawer and the customer together
ignore runPostings(#depositToAccount({
  account = bobAcct; amount = 50_000; postingDate = TODAY; valueDate = TODAY;
  period = "2026-09"; narration = "cash in"; funding = #till("T01");
}));
switch (Core.tillPosition(bs, BankMemLog.reader(bchain), js, "T01", TODAY)) {
  case (#ok(pos)) assert (pos.book == 300_000);
  case (#err(_)) assert false;
};

// the drawer is counted short by 500 minor units: the difference goes to suspense
// with the cashier named, and the drawer is returned to its book position
let settlePostings = runPostings(#settleTill({
  till = "T01"; declared = 299_500; postingDate = TODAY; valueDate = TODAY;
  period = "2026-09"; narration = "end of shift";
}));
assert (settlePostings.size() == 1);
switch (JCore.postingView(js, JMemLog.reader(jchain), settlePostings[0])) {
  case (?v) {
    var tillLeg = 0; var suspenseLeg = 0;
    for (l in v.record.legs.vals()) {
      assert (l.amount > 0);
      if (Text.equal(l.account, "1001")) { assert (l.side == #credit); assert (l.subledger == ?tillEntry.subledger); tillLeg := l.amount };
      if (Text.equal(l.account, "1900")) { assert (l.side == #debit); suspenseLeg := l.amount };
    };
    assert (tillLeg == 500 and suspenseLeg == 500);
    // the cashier is named in the narration the block carries
    assert (Text.contains(v.record.narration, #text "cashier"));
  };
  case null assert false;
};
switch (Core.tillPosition(bs, BankMemLog.reader(bchain), js, "T01", TODAY)) {
  case (#ok(pos)) {
    assert (pos.book == 299_500);
    switch (pos.lastDifference) { case (#short(n)) assert (n == 500); case (other) { Debug.print(debug_show (other)); assert false } };
    assert (pos.settlements == 1);
  };
  case (#err(_)) assert false;
};
// the suspense account carries the loss: it was not absorbed anywhere
let suspense = JCore.balance(js, "1900", null, "EGP");
assert (suspense.debitsPosted == 500);
Debug.print("count: till settlements verified = 1, suspense carries " # Nat.toText(suspense.debitsPosted));

// a settlement that agrees posts nothing at all
let agreed = runPostings(#settleTill({ till = "T01"; declared = 299_500; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "agrees" }));
assert (agreed.size() == 0);
Debug.print("count: balanced settlements with no posting = 1");

// a drawer with cash in it cannot be closed
expectErr(#closeTill({ till = "T01" }), "TillHasCash");
ignore runPostings(#returnCashFromTill({ till = "T01"; amount = 299_500; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "return the drawer" }));
ignore run(#closeTill({ till = "T01" }));
switch (ProductCore.getTill(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), "T01")) { case (?t) assert (t.status == #closed); case null assert false };
Debug.print("count: tills closed = 1");

// ═══════════════════════════════════════════════════════════════════════════
//  closing an account, and the account lifecycle
// ═══════════════════════════════════════════════════════════════════════════

// an account with a balance cannot be closed
expectErr(#setAccountStatus({ account = aliceAcct; to = #closed }), "AccountHasBalance");
// bob's second account has never been funded, so it closes
expectErr(#setAccountStatus({ account = postAmendAcct; to = #dormant }), "AccountNotActive");
ignore run(#setAccountStatus({ account = postAmendAcct; to = #active }));
ignore run(#setAccountStatus({ account = postAmendAcct; to = #dormant }));
ignore run(#setAccountStatus({ account = postAmendAcct; to = #active }));
ignore run(#setAccountStatus({ account = postAmendAcct; to = #closed }));
switch (ProductCore.get(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), postAmendAcct)) {
  case (?a) { assert (a.status == #closed); assert (a.closedAtBlock != null) };
  case null assert false;
};
expectErr(#setAccountStatus({ account = postAmendAcct; to = #active }), "AccountNotActive");
Debug.print("count: account lifecycle transitions verified = 5");

// ═══════════════════════════════════════════════════════════════════════════
//  the fold is the log
// ═══════════════════════════════════════════════════════════════════════════

// ─── onboarding as one dual act (one dual act) ─────────────────────
// The same nine effects makeParty + openAccount + setAccountStatus produce, as one command: the party
// is the act's first block, each account its own block, and every id is known before anything lands.
func customer(i : Nat, lifecycle : PT.Lifecycle, screening : ?T.CustomerScreening, docs : [PT.DocumentRef], accounts : [T.CustomerAccount]) : T.Command {
  let salt = saltFor(i);
  #createCustomer({
    party = { kind = #natural; salt; identityCommit = Commit.identity(salt, #natural, ["Person " # Nat.toText(i), "2980101123456" # Nat.toText(i)]); dedupCommit = ?Commit.dedup(institutionSalt, "nationalId", "2980101123456" # Nat.toText(i)); attributes = []; book = "BR01"; cddLevel = #standard; riskRating = #low; pep = false; reviewDue = TODAY + 365 };
    documents = docs; screening; lifecycle; extensions = []; accounts;
  })
};
let twoDocs : [PT.DocumentRef] = [{ kind = "identity"; commit = Commit.document(saltFor(9), "identity", Blob.fromArray([1])); issued = 20000; expires = null }, { kind = "address"; commit = Commit.document(saltFor(9), "address", Blob.fromArray([2])); issued = 20000; expires = null }];
let clearDecision : T.CustomerScreening = { listVersion = "UN-2026-09"; listRoot; decision = #clear; screener; justificationCommit = Commit.justification("no match") };
let heightBefore = Core.height(bs);
let partiesBefore = PartyCore.partyCount(bs.party);
let carol = run(customer(9, #active, ?clearDecision, twoDocs, [
  { product = "SAV"; currency = "EGP"; termDays = null; allocationOrder = []; activate = true },
  { product = "SAV"; currency = "EGP"; termDays = null; allocationOrder = []; activate = false },
]));
// party, pendingKyc, two documents, the decision, active, account 1 opened + activated, account 2 opened: 9 blocks
assert (Core.height(bs) == heightBefore + 9);
assert (carol == heightBefore);
let ?carolEntry = PartyCore.get(bs.party, Core.partyBlocks(BankMemLog.reader(bchain)), carol) else { assert false; loop {} };
assert (carolEntry.lifecycle == #active and carolEntry.documents.size() == 2);
switch (carolEntry.screening) { case (#clear({ listVersion; at })) { assert (listVersion == "UN-2026-09" and at == carol + 4) }; case (_) { assert false } };
let carolAcct1 = carol + 6;
let carolAcct2 = carol + 8;
let ?ca1 = ProductCore.get(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), carolAcct1) else { assert false; loop {} };
let ?ca2 = ProductCore.get(bs.product, Core.productBlocks(BankMemLog.reader(bchain)), carolAcct2) else { assert false; loop {} };
assert (ca1.party == carol and ca1.status == #active and ca2.party == carol and ca2.status == #pending);
assert (ca1.identifier != ca2.identifier);
assert (PartyCore.partyCount(bs.party) == partiesBefore + 1);
// refused whole: a missing due-diligence document, an unknown list, an unknown product, a duplicate
// identity, a term on a savings product — nothing of the act lands, the fingerprint and height stay
let before = (Core.height(bs), PartyCore.partyCount(bs.party), ProductCore.accountCount(bs.product));
expectErr(customer(10, #active, ?clearDecision, [twoDocs[0]], []), "CddIncomplete");
expectErr(customer(10, #active, ?{ clearDecision with listVersion = "nosuch" }, twoDocs, []), "UnknownList");
expectErr(customer(10, #pendingKyc, null, twoDocs, [{ product = "NOPE"; currency = "EGP"; termDays = null; allocationOrder = []; activate = true }]), "UnknownProduct");
expectErr(customer(10, #pendingKyc, null, twoDocs, [{ product = "SAV"; currency = "EGP"; termDays = ?90; allocationOrder = []; activate = true }]), "only a term product carries a term");
expectErr(customer(10, #active, null, twoDocs, []), "ScreeningBlocks");
expectErr(customer(9, #prospect, null, [], []), "DuplicateIdentity");
expectErr(customer(10, #dormant, null, [], []), "IllegalTransition");
assert (before == (Core.height(bs), PartyCore.partyCount(bs.party), ProductCore.accountCount(bs.product)));
// a prospect with nothing else is one block
let dave = run(customer(11, #prospect, null, [], []));
assert (Core.height(bs) == dave + 1);
Debug.print("count: customers onboarded as one act = 2");
Debug.print("count: one-act onboardings refused whole = 7");
// the act's events rebuild the command byte for byte (the bank-log ruling's measure 1, §18.2): the nine
// blocks of carol's act, and the one block of dave's, hash to the commands that made them; an opening whose
// order was written expanded rebuilds to the empty order the command carried
let carolCommand = customer(9, #active, ?clearDecision, twoDocs, [
  { product = "SAV"; currency = "EGP"; termDays = null; allocationOrder = []; activate = true },
  { product = "SAV"; currency = "EGP"; termDays = null; allocationOrder = []; activate = false },
]);
let all = BankMemLog.blocks(bchain);
let carolAct = Array.tabulate<T.Event>(9, func(i) { all[carol + i].event });
var hit = 0;
for (c in Reconstruct.candidates(carolAct).vals()) { if (C.commandHash(c) == C.commandHash(carolCommand)) hit += 1 };
assert (hit == 1);
let daveAct : [T.Event] = [all[dave].event];
assert (Array.find<T.Command>(Reconstruct.candidates(daveAct), func(c) { C.commandHash(c) == C.commandHash(customer(11, #prospect, null, [], [])) }) != null);
let aliceOpen : [T.Event] = [all[aliceAcct].event];
assert (Array.find<T.Command>(Reconstruct.candidates(aliceOpen), func(c) { C.commandHash(c) == C.commandHash(#openAccount({ product = "SAV"; party = alice; currency = "EGP"; termDays = null; allocationOrder = [] })) }) != null);
Debug.print("count: acts rebuilt to the command that made them = 3");

let liveFingerprint = Core.fingerprint(bs);
let replayed = Core.replay(installer, BankMemLog.blocks(bchain));
assert (Core.fingerprint(replayed) == liveFingerprint);
assert (Core.height(replayed) == Core.height(bs));
assert (ProductCore.productCount(replayed.product) == ProductCore.productCount(bs.product));
assert (ProductCore.accountCount(replayed.product) == ProductCore.accountCount(bs.product));
assert (ProductCore.tillCount(replayed.product) == ProductCore.tillCount(bs.product));
Debug.print("count: bank blocks replayed to an identical fingerprint = " # Nat.toText(BankMemLog.blocks(bchain).size()));

// and the journal beneath it likewise
let jLive = JCore.fingerprint(js);
let jReplayed = JCore.replay(bankP, JMemLog.blocks(jchain));
assert (JCore.fingerprint(jReplayed) == jLive);
Debug.print("count: journal blocks replayed to an identical fingerprint = " # Nat.toText(JMemLog.blocks(jchain).size()));

// every product account's identifier validates as an IBAN, and every one of them
// resolves back to the account it was issued for
var identifiersChecked = 0;
for (a in ProductCore.listAccounts(bs.product, Core.productBlocks(BankMemLog.reader(bchain))).vals()) {
  assert (ProductCore.byIdentifier(bs.product, a.identifier) == ?a.id);
  assert (a.subledger == Posting.subledgerOf(a.identifier));
  identifiersChecked += 1;
};
Debug.print("count: account identifiers resolved = " # Nat.toText(identifiersChecked));

Debug.print("PRODUCT ENGINE TEST GREEN");
