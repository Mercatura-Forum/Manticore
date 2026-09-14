// YearEnd.test.mo: the journal calendar year-end roll on the pure core: after the roll every
// income and expense account has zero cumulative balance per currency, retained
// earnings moved by the net, the roll is idempotent, and a fresh year starts clean.
//
// engine: wasi-only; the journal core now keeps its per-posting state in a stable-memory Region
// (`JournalCore.postingRows`), and the moc interpreter provides no Region. The dual-engine check this
// loses was worth having, and the loss is stated here rather than hidden: the reason the state moved
// is that a heap map per posting makes the heap grow with the journal, which is the one thing a
// contract's heap must not do. Every test below still runs under wasmtime, which is the engine the
// chain runs.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Principal "mo:core/Principal";
import T "../src/journal/JournalTypes";
import Core "../src/journal/JournalCore";
import YearEnd "../src/journal/YearEnd";
import MemLog "support/MemLog";

let admin = Principal.fromBlob("\AD\01");
let poster = Principal.fromBlob("\B0\01");
let DAY : Nat64 = 86_400_000_000_000;
let JAN1 = 20454; let DEC31 = 20818; let NJAN1 = 20819; let NJAN31 = 20849;   // 2026 and January 2027
var clock : Nat64 = Nat64.fromNat(NJAN1 + 5) * DAY;
let chain = MemLog.new();
let s = Core.newState(admin);
func cfg(r : { #ok : T.Event; #err : T.ConfigError }) { switch (r) { case (#ok(e)) ignore MemLog.commit(chain, s, clock, admin, e); case (#err(e)) { Debug.print(debug_show(e)); assert false } } };
cfg(Core.prepareRegisterCurrency(s, admin, "EGP", 2));
cfg(Core.prepareRegisterCurrency(s, admin, "USD", 2));
for ((c, n, sd, cat) in [("1500", "Cash", #debit, #asset), ("2200", "Retained earnings", #credit, #equity), ("2000", "Share capital", #credit, #equity),
                          ("5000", "Revenue", #credit, #income), ("5100", "Other income", #credit, #income), ("6000", "Cost of sales", #debit, #expense), ("6500", "Finance costs", #debit, #expense)].vals()) {
  cfg(Core.prepareOpenAccount(s, admin, c, n, sd, cat, #none));
};
// one period for the whole of 2026 (the roll needs only "the last period of the year"), then January 2027
cfg(Core.prepareOpenPeriod(s, admin, "2026", JAN1, DEC31));
cfg(Core.prepareOpenPeriod(s, admin, "2027-01", NJAN1, NJAN31));
cfg(Core.prepareAddPoster(s, admin, poster));
cfg(Core.prepareSetActivationHeight(s, admin, 0));
var k = 0;
func post(day : Nat, period : Text, legs : [T.Leg]) {
  k += 1;
  let input : T.PostingInput = { idempotencyKey = Blob.fromArray([Nat8.fromNat(k)]); postingDate = day; valueDate = day; period; legs; sourceRef = { kind = "t"; id = "t" }; narration = "y"; correctionOf = null };
  switch (Core.preparePost(s, poster, clock, input)) { case (#ok(#event(e))) ignore MemLog.commit(chain, s, clock, poster, e); case (o) { Debug.print(debug_show(o)); assert false } };
};
func L(a : Text, sd : T.Side, c : Text, n : Nat) : T.Leg { { account = a; subledger = null; side = sd; currency = c; amount = n } };
post(JAN1, "2026", [L("1500", #debit, "EGP", 1_000_000), L("2000", #credit, "EGP", 1_000_000)]);
post(JAN1 + 40, "2026", [L("1500", #debit, "EGP", 300_000), L("5000", #credit, "EGP", 300_000)]);
post(JAN1 + 80, "2026", [L("1500", #debit, "EGP", 20_000), L("5100", #credit, "EGP", 20_000)]);
post(JAN1 + 120, "2026", [L("6000", #debit, "EGP", 120_000), L("1500", #credit, "EGP", 120_000)]);
post(JAN1 + 200, "2026", [L("6500", #debit, "EGP", 5_000), L("1500", #credit, "EGP", 5_000)]);
post(JAN1 + 210, "2026", [L("6000", #debit, "USD", 700), L("1500", #credit, "USD", 700)]);       // a USD loss year
post(JAN1 + 220, "2026", [L("1500", #debit, "USD", 100), L("5000", #credit, "USD", 100)]);
Debug.print("count: postings booked in the year = 7");

let args : YearEnd.RollArgs = { closingPeriod = "2026"; retainedEarnings = "2200"; keyPrefix = Blob.fromArray([0xFE, 0x26]); narration = "year-end 2026" };
let plan = switch (YearEnd.plan(s, args)) { case (#ok(p)) p; case (#err(e)) { Debug.print(debug_show(e)); assert false; loop {} } };
assert (plan.postings.size() == 2 and plan.accountsClosed == 6);   // 5000, 5100, 6000, 6500 in EGP; 5000, 6000 in USD
for (r in plan.results.vals()) {
  if (r.currency == "EGP") { assert (r.profitCredits == 320_000 and r.lossDebits == 125_000) };
  if (r.currency == "USD") { assert (r.profitCredits == 100 and r.lossDebits == 700) };
};
// every roll posting balances per currency and is admitted as a batch
switch (Core.prepareBatch(s, poster, clock, plan.postings)) {
  case (#ok(prepared)) { for (p in prepared.vals()) { switch (p) { case (#event(e)) ignore MemLog.commit(chain, s, clock, poster, e); case (#duplicate(_)) assert false } } };
  case (#err(e)) { Debug.print(debug_show(e)); assert false };
};
let tb = switch (Core.trialBalance(s, "2026")) { case (?t) t; case null { assert false; loop {} } };
assert (tb.balanced);
var pnlRows = 0; var zero = 0;
for (row in tb.rows.vals()) {
  switch (Core.getAccount(s, row.account)) {
    case (?a) { if (a.category == #income or a.category == #expense) { pnlRows += 1; if (row.closingDebits == row.closingCredits) zero += 1 } };
    case null {};
  };
};
Debug.print("count: income and expense rows examined after the roll = " # Nat.toText(pnlRows));
Debug.print("count: income and expense rows at zero = " # Nat.toText(zero));
assert (pnlRows == 6 and zero == 6);
// retained earnings carries the result: EGP profit 195,000 credit; USD loss 600 debit
let reEgp = Core.balance(s, "2200", null, "EGP"); assert (reEgp.creditsPosted - reEgp.debitsPosted == 195_000);
let reUsd = Core.balance(s, "2200", null, "USD"); assert (reUsd.debitsPosted - reUsd.creditsPosted == 600);
// the roll is idempotent: the same plan is all duplicates, nothing new
let h = Core.height(s);
switch (Core.prepareBatch(s, poster, clock, plan.postings)) {
  case (#ok(prepared)) { for (p in prepared.vals()) { switch (p) { case (#duplicate(_)) {}; case (#event(_)) assert false } } };
  case (#err(e)) { Debug.print(debug_show(e)); assert false };
};
assert (Core.height(s) == h);
assert (YearEnd.plan(s, args) == #err(#NothingToRoll));
Debug.print("count: idempotency and nothing-to-roll checks = 2");
// close the year, book January: the new year starts from zero for P&L and keeps retained earnings
cfg(Core.prepareClosePeriod(s, admin, "2026"));
post(NJAN1 + 3, "2027-01", [L("1500", #debit, "EGP", 50_000), L("5000", #credit, "EGP", 50_000)]);
let tbJan = switch (Core.trialBalance(s, "2027-01")) { case (?t) t; case null { assert false; loop {} } };
for (row in tbJan.rows.vals()) {
  if (row.account == "5000" and row.currency == "EGP") { assert (row.periodCredits == 50_000 and row.closingCredits - row.closingDebits == 50_000) };
  if (row.account == "2200" and row.currency == "EGP") { assert (row.closingCredits - row.closingDebits == 195_000) };
};
// errors
assert (YearEnd.plan(s, { args with closingPeriod = "2030" }) == #err(#UnknownPeriod("2030")));
assert (YearEnd.plan(s, { args with retainedEarnings = "1500"; closingPeriod = "2027-01" }) == #err(#RetainedEarningsNotEquity("1500")));
assert (YearEnd.plan(s, { args with retainedEarnings = "9999"; closingPeriod = "2027-01" }) == #err(#UnknownRetainedEarnings("9999")));
assert (YearEnd.plan(s, { args with keyPrefix = Blob.fromArray(Array.tabulate<Nat8>(57, func(_) { 1 })); closingPeriod = "2027-01" }) == #err(#KeyPrefixTooLong(57)));
assert (YearEnd.plan(s, args) == #err(#PeriodClosed("2026")));
Debug.print("count: year-end error checks = 5");
// replay agrees
assert (Core.fingerprint(Core.replay(admin, MemLog.blocks(chain))) == Core.fingerprint(s));
Debug.print("count: replayed state equal after the roll = 1");
