// JournalCore.test.mo: the acceptance battery on the pure state machine.
// Criteria 1 (balance invariant), 2 (immutability), 3 (idempotency), 4 (two-phase),
// 5 (value dating and period close), 6 (trial balance vs independent fold),
// 8 (leadsheet mapping) and the replay half of 10 (restart), plus authorization
// and the activation gate. Every check prints the number of records it examined.
// engine: wasi-only; see test/run.sh.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Principal "mo:core/Principal";
import Order "mo:core/Order";
import Nat8 "mo:core/Nat8";

import T "../src/journal/JournalTypes";
import Core "../src/journal/JournalCore";
import MemLog "support/MemLog";
import F "support/TbSchemaFixture";

// ─── fixtures ────────────────────────────────────────────────────────────────

let admin = Principal.fromBlob("\AD\01");
let poster = Principal.fromBlob("\B0\01");
let poster2 = Principal.fromBlob("\B0\02");
let outsider = Principal.fromBlob("\0F\0F");
let anon = Principal.fromText("2vxsx-fae");

let DAY : Nat64 = 86_400_000_000_000;
let TODAY : Nat = 20705;                     // 2026-09-09
var clock : Nat64 = Nat64.fromNat(TODAY) * DAY + 43_200_000_000_000;

let JUL1 = 20635; let JUL31 = 20665; let AUG1 = 20666; let AUG31 = 20696; let SEP1 = 20697; let SEP30 = 20726;

let chain = MemLog.new();
let s = Core.newState(admin);

func cfg(caller : Principal, r : { #ok : T.Event; #err : T.ConfigError }) : Nat {
  switch (r) {
    case (#ok(e)) MemLog.commit(chain, s, clock, caller, e).index;
    case (#err(e)) { Debug.print("unexpected config error: " # debug_show(e)); assert false; 0 };
  }
};
func cfgErr(r : { #ok : T.Event; #err : T.ConfigError }) : T.ConfigError {
  switch (r) { case (#err(e)) e; case (#ok(e)) { Debug.print("expected config error, got event " # debug_show(e)); assert false; #Unauthorized } }
};

func leg(account : Text, side : T.Side, currency : Text, amount : Nat) : T.Leg { { account; subledger = null; side; currency; amount } };
func legS(account : Text, sub : Blob, side : T.Side, currency : Text, amount : Nat) : T.Leg { { account; subledger = ?sub; side; currency; amount } };
var keyCounter : Nat = 0;
func key() : Blob { keyCounter += 1; Blob.fromArray([Nat8.fromNat(keyCounter / 256), Nat8.fromNat(keyCounter % 256)]) };

func input(k : Blob, postingDate : Nat, valueDate : Nat, period : Text, legs : [T.Leg]) : T.PostingInput {
  { idempotencyKey = k; postingDate; valueDate; period; legs; sourceRef = { kind = "test"; id = "t" }; narration = "test posting"; correctionOf = null }
};
func simple(postingDate : Nat, period : Text, dr : Text, cr : Text, ccy : Text, amount : Nat) : T.PostingInput {
  input(key(), postingDate, postingDate, period, [leg(dr, #debit, ccy, amount), leg(cr, #credit, ccy, amount)])
};

/// post and require success; returns block index
func postOk(caller : Principal, i : T.PostingInput) : Nat {
  switch (Core.preparePost(s, caller, clock, i)) {
    case (#ok(#event(e))) MemLog.commit(chain, s, clock, caller, e).index;
    case (#ok(#duplicate(idx))) { Debug.print("unexpected duplicate " # Nat.toText(idx)); assert false; 0 };
    case (#err(e)) { Debug.print("unexpected post error: " # debug_show(e)); assert false; 0 };
  }
};
/// post and require a typed error; state fingerprint and height must be unchanged
func postErr(caller : Principal, i : T.PostingInput) : T.PostError {
  let fp = Core.fingerprint(s);
  let h = Core.height(s);
  let r = Core.preparePost(s, caller, clock, i);
  assert (Core.fingerprint(s) == fp and Core.height(s) == h);
  switch (r) { case (#err(e)) e; case (#ok(x)) { Debug.print("expected error, got " # debug_show(x)); assert false; #Unauthorized } }
};
func reserveOk(caller : Principal, i : T.PostingInput, expiresAt : ?Nat64) : Nat {
  switch (Core.prepareReserve(s, caller, clock, i, expiresAt)) {
    case (#ok(#event(e))) MemLog.commit(chain, s, clock, caller, e).index;
    case (other) { Debug.print("unexpected reserve result: " # debug_show(other)); assert false; 0 };
  }
};
func postPendingOk(caller : Principal, idx : Nat, override : ?T.Resolution) : Nat {
  switch (Core.preparePostPending(s, MemLog.reader(chain), caller, clock, idx, override)) {
    case (#ok(#event(e))) MemLog.commit(chain, s, clock, caller, e).index;
    case (other) { Debug.print("unexpected postPending result: " # debug_show(other)); assert false; 0 };
  }
};
func voidOk(caller : Principal, idx : Nat) : Nat {
  switch (Core.prepareVoidPending(s, MemLog.reader(chain), caller, idx)) {
    case (#ok(e)) MemLog.commit(chain, s, clock, caller, e).index;
    case (#err(e)) { Debug.print("unexpected void error: " # debug_show(e)); assert false; 0 };
  }
};

// ─── configuration ───────────────────────────────────────────────────────────

ignore cfg(admin, Core.prepareRegisterCurrency(s, admin, "EGP", 2));
ignore cfg(admin, Core.prepareRegisterCurrency(s, admin, "USD", 2));
ignore cfg(admin, Core.prepareRegisterCurrency(s, admin, "KWD", 3));
assert (cfgErr(Core.prepareRegisterCurrency(s, admin, "EGP", 2)) == #CurrencyExists({ code = "EGP" }));
assert (cfgErr(Core.prepareRegisterCurrency(s, admin, "egp", 2)) == #InvalidCurrency({ code = "egp"; reason = "currency code must be upper-case ASCII letters or digits" }));
assert (cfgErr(Core.prepareRegisterCurrency(s, poster, "GBP", 2)) == #Unauthorized);
assert (cfgErr(Core.prepareRegisterCurrency(s, anon, "GBP", 2)) == #AnonymousCaller);

let accounts : [(Text, Text, T.Side, T.Category)] = [
  ("1000", "Property, plant and equipment", #debit, #asset),
  ("1400", "Trade receivables", #debit, #asset),
  ("1500", "Cash", #debit, #asset),
  ("1500.01", "Cash - branch 1", #debit, #asset),
  ("1510", "Nostro USD", #debit, #asset),
  ("2000", "Share capital", #credit, #equity),
  ("2200", "Retained earnings", #credit, #equity),
  ("2300", "FX position", #credit, #equity),
  ("3000", "Borrowings", #credit, #liability),
  ("4100", "Trade payables", #credit, #liability),
  ("5000", "Revenue", #credit, #income),
  ("6000", "Cost of sales", #debit, #expense),
  ("6500", "Finance costs", #debit, #expense),
  ("9999", "Suspense (unmapped by design)", #debit, #asset),
];
for ((code, name, side, cat) in accounts.vals()) { ignore cfg(admin, Core.prepareOpenAccount(s, admin, code, name, side, cat, #none)) };
assert (cfgErr(Core.prepareOpenAccount(s, admin, "1500", "dup", #debit, #asset, #none)) == #AccountExists({ code = "1500" }));
assert (cfgErr(Core.prepareOpenAccount(s, admin, "15", "bad", #debit, #asset, #none)) == #InvalidAccountCode({ code = "15"; reason = "account code must start with four digits" }));
Debug.print("count: accounts opened = " # Nat.toText(Core.listAccounts(s).size()));

ignore cfg(admin, Core.prepareOpenPeriod(s, admin, "2026-07", JUL1, JUL31));
ignore cfg(admin, Core.prepareOpenPeriod(s, admin, "2026-08", AUG1, AUG31));
ignore cfg(admin, Core.prepareOpenPeriod(s, admin, "2026-09", SEP1, SEP30));
assert (cfgErr(Core.prepareOpenPeriod(s, admin, "2026-09b", SEP30, SEP30 + 5)) == #PeriodOverlaps({ id = "2026-09b"; overlapping = "2026-09" }));
assert (cfgErr(Core.prepareOpenPeriod(s, admin, "2026-08", AUG1, AUG31)) == #PeriodExists({ id = "2026-08" }));
assert (cfgErr(Core.prepareOpenPeriod(s, admin, "x", 10, 5)) == #InvalidPeriod({ id = "x"; reason = "start is after end" }));
assert (cfgErr(Core.prepareOpenPeriod(s, admin, "bad id!", 1, 2)) == #InvalidPeriod({ id = "bad id!"; reason = "period id may contain only ASCII letters, digits, '-' and '_'" }));
Debug.print("count: periods opened = " # Nat.toText(Core.listPeriods(s).size()));

ignore cfg(admin, Core.prepareAddPoster(s, admin, poster));
ignore cfg(admin, Core.prepareAddPoster(s, admin, poster2));
assert (cfgErr(Core.prepareAddPoster(s, admin, poster)) == #PosterExists({ poster }));
assert (cfgErr(Core.prepareAddPoster(s, admin, anon)) == #InvalidPrincipal);

// ─── activation gate ─────────────────────────────────────────────────────────

let gated = postErr(poster, simple(SEP1, "2026-09", "1500", "2000", "EGP", 100));
switch (gated) { case (#NotActivated(x)) { assert (x.activationHeight == T.ACTIVATION_OFF) }; case (e) { Debug.print(debug_show(e)); assert false } };
assert (not Core.isActive(s));
ignore cfg(admin, Core.prepareSetActivationHeight(s, admin, Nat64.fromNat(Core.height(s) + 2)));  // two above (the recording block itself adds one): still inactive
assert (not Core.isActive(s));
switch (postErr(poster, simple(SEP1, "2026-09", "1500", "2000", "EGP", 100))) { case (#NotActivated(_)) {}; case (_) assert false };
ignore cfg(admin, Core.prepareSetActivationHeight(s, admin, Nat64.fromNat(Core.height(s))));
assert (Core.isActive(s));
Debug.print("count: activation gate refusals before activation = 3");
Debug.print("activation gate active at height " # Nat.toText(Core.height(s)));

// ─── authorization ───────────────────────────────────────────────────────────

assert (postErr(anon, simple(SEP1, "2026-09", "1500", "2000", "EGP", 100)) == #AnonymousCaller);
assert (postErr(outsider, simple(SEP1, "2026-09", "1500", "2000", "EGP", 100)) == #Unauthorized);
assert (postErr(admin, simple(SEP1, "2026-09", "1500", "2000", "EGP", 100)) == #Unauthorized);  // admin is not a poster
Debug.print("count: authorization refusals = 3");

// ─── criterion 1: balance invariant ──────────────────────────────────────────

let first = postOk(poster, simple(SEP1, "2026-09", "1500", "2000", "EGP", 100_000_000));
assert (Core.balance(s, "1500", null, "EGP").debitsPosted == 100_000_000);
assert (Core.balance(s, "2000", null, "EGP").creditsPosted == 100_000_000);

let unb = postErr(poster, input(key(), SEP1, SEP1, "2026-09", [leg("1500", #debit, "EGP", 100), leg("2000", #credit, "EGP", 99)]));
assert (unb == #Unbalanced({ currency = "EGP"; debits = 100; credits = 99 }));
let cross = postErr(poster, input(key(), SEP1, SEP1, "2026-09", [leg("1510", #debit, "USD", 100), leg("1500", #credit, "EGP", 4800)]));
switch (cross) { case (#Unbalanced(_)) {}; case (_) assert false };
// the correct four-leg FX posting balances per currency
ignore postOk(poster, input(key(), SEP1, SEP1, "2026-09", [
  leg("1510", #debit, "USD", 100), leg("2300", #credit, "USD", 100),
  leg("2300", #debit, "EGP", 4800), leg("1500", #credit, "EGP", 4800),
]));
assert (postErr(poster, input(key(), SEP1, SEP1, "2026-09", [leg("1500", #debit, "EGP", 0), leg("2000", #credit, "EGP", 0)])) == #ZeroAmountLeg({ index = 0 }));
assert (postErr(poster, input(key(), SEP1, SEP1, "2026-09", [leg("1500", #debit, "EGP", 5), leg("2000", #credit, "EGP", 0), leg("2000", #credit, "EGP", 5)])) == #ZeroAmountLeg({ index = 1 }));
assert (postErr(poster, input(key(), SEP1, SEP1, "2026-09", [leg("1500", #debit, "EGP", 5)])) == #TooFewLegs({ count = 1 }));
assert (postErr(poster, input(key(), SEP1, SEP1, "2026-09", [])) == #TooFewLegs({ count = 0 }));
let tooMany = Array.tabulate<T.Leg>(129, func(i) { if (i % 2 == 0) leg("1500", #debit, "EGP", 1) else leg("2000", #credit, "EGP", 1) });
assert (postErr(poster, input(key(), SEP1, SEP1, "2026-09", tooMany)) == #TooManyLegs({ count = 129; max = 128 }));
assert (postErr(poster, input(key(), SEP1, SEP1, "2026-09", [leg("1500", #debit, "EGP", 5), leg("7777", #credit, "EGP", 5)])) == #UnknownAccount({ account = "7777" }));
assert (postErr(poster, input(key(), SEP1, SEP1, "2026-09", [leg("1500", #debit, "GBP", 5), leg("2000", #credit, "GBP", 5)])) == #UnknownCurrency({ currency = "GBP" }));
// rounding: 3-decimal currency, amounts are exact minor units, no rounding path exists
ignore postOk(poster, input(key(), SEP1, SEP1, "2026-09", [leg("1500", #debit, "KWD", 1), leg("2000", #credit, "KWD", 1)]));
assert (postErr(poster, input(key(), SEP1, SEP1, "2026-09", [leg("1500", #debit, "KWD", 1000), leg("2000", #credit, "KWD", 999)])) == #Unbalanced({ currency = "KWD"; debits = 1000; credits = 999 }));
Debug.print("count: balance invariant adversarial cases rejected with typed errors = 12");
Debug.print("count: balance invariant adversarial cases accepted = 3");

// randomized: 300 balanced accepted, 300 unbalanced rejected
var seed : Nat = 12345;
func rnd(n : Nat) : Nat { seed := (seed * 1103515245 + 12345) % 2147483648; seed % n };
let drAccounts = ["1000", "1400", "1500", "1500.01", "6000", "6500", "9999"];
let crAccounts = ["2000", "2200", "3000", "4100", "5000"];
func randomBalanced(ccy : Text) : [T.Leg] {
  let nd = 1 + rnd(3); let nc = 1 + rnd(3);
  var total = 0;
  let legs = List.empty<T.Leg>();
  var i = 0;
  while (i < nd) { let a = 1 + rnd(1_000_000); total += a; List.add(legs, leg(drAccounts[rnd(drAccounts.size())], #debit, ccy, a)); i += 1 };
  var remaining = total;
  i := 0;
  while (i < nc) {
    let a = if (i + 1 == nc) remaining else (1 + rnd(Nat.max(1, remaining - (nc - i - 1)) ));
    let a2 = Nat.min(a, remaining - (nc - i - 1));
    remaining -= a2;
    List.add(legs, leg(crAccounts[rnd(crAccounts.size())], #credit, ccy, a2));
    i += 1;
  };
  List.toArray(legs)
};
var accepted = 0; var rejected = 0;
var n = 0;
while (n < 300) {
  let ccy = if (rnd(4) == 0) "USD" else "EGP";
  let legs = randomBalanced(ccy);
  let day = SEP1 + rnd(TODAY - SEP1 + 1);
  ignore postOk(poster, input(key(), day, day, "2026-09", legs));
  accepted += 1;
  // perturb one leg by one minor unit: must be rejected as Unbalanced
  let k = rnd(legs.size());
  let bad = Array.tabulate<T.Leg>(legs.size(), func(i) { if (i == k) ({ legs[i] with amount = legs[i].amount + 1 }) else legs[i] });
  switch (postErr(poster, input(key(), day, day, "2026-09", bad))) { case (#Unbalanced(_)) rejected += 1; case (e) { Debug.print(debug_show(e)); assert false } };
  n += 1;
};
Debug.print("count: randomized balanced postings accepted = " # Nat.toText(accepted));
Debug.print("count: randomized perturbed postings rejected = " # Nat.toText(rejected));
assert (accepted == 300 and rejected == 300);

// INV-J1 re-checked over every committed posting block
var postedBlocks = 0;
for (b in MemLog.blocks(chain).vals()) {
  switch (b.event) {
    case (#posted(r)) { assert (Core.unbalancedCurrency(r.legs) == null); postedBlocks += 1 };
    case (#pending(x)) { assert (Core.unbalancedCurrency(x.record.legs) == null) };
    case (_) {};
  };
};
Debug.print("count: INV-J1 re-checked over posted blocks = " # Nat.toText(postedBlocks));
assert (postedBlocks == accepted + 3);

// ─── criterion 3: idempotency ────────────────────────────────────────────────

let k1 = key();
let i1 = input(k1, SEP1, SEP1, "2026-09", [leg("1500", #debit, "EGP", 777), leg("5000", #credit, "EGP", 777)]);
let h0 = Core.height(s);
let idx1 = postOk(poster, i1);
switch (Core.preparePost(s, poster, clock, i1)) { case (#ok(#duplicate(d))) { assert (d == idx1) }; case (_) assert false };
assert (Core.height(s) == h0 + 1);
// same key, different content: reused error, nothing applied
assert (postErr(poster, { i1 with narration = "changed" }) == #IdempotencyKeyReused({ existing = idx1 }));
assert (postErr(poster, { i1 with legs = [leg("1500", #debit, "EGP", 778), leg("5000", #credit, "EGP", 778)] }) == #IdempotencyKeyReused({ existing = idx1 }));
// same key as a pending submission: reused (kind differs)
switch (Core.prepareReserve(s, poster, clock, i1, null)) { case (#err(#IdempotencyKeyReused(x))) { assert (x.existing == idx1) }; case (_) assert false };
// same key, different caller: independent scope, new posting
let idx1b = postOk(poster2, i1);
assert (idx1b != idx1);
assert (postErr(poster, { i1 with idempotencyKey = Blob.fromArray([]) }) == #IdempotencyKeyInvalid({ size = 0 }));
assert (postErr(poster, { i1 with idempotencyKey = Blob.fromArray(Array.tabulate<Nat8>(65, func(_) { 1 })) }) == #IdempotencyKeyInvalid({ size = 65 }));
Debug.print("count: idempotency duplicate submissions returning the original = 1");
Debug.print("count: idempotency key mismatches refused = 3");
Debug.print("count: idempotency invalid keys refused = 2");
Debug.print("idempotency original index " # Nat.toText(idx1) # ", cross-principal independent index " # Nat.toText(idx1b));

// ─── criterion 2: immutability and reversal ──────────────────────────────────

let origBlock = MemLog.blocks(chain)[first];
let origView = switch (Core.postingView(s, MemLog.reader(chain), first)) { case (?v) v; case null { assert false; loop {} } };
let revArgs : Core.ReverseArgs = { idempotencyKey = key(); postingDate = SEP1 + 1; valueDate = SEP1 + 1; period = "2026-09"; sourceRef = { kind = "reversal"; id = "r1" }; narration = "reverse first" };
let rev = switch (Core.prepareReverse(s, MemLog.reader(chain), poster, clock, first, revArgs)) {
  case (#ok(#event(e))) MemLog.commit(chain, s, clock, poster, e).index;
  case (other) { Debug.print(debug_show(other)); assert false; 0 };
};
let revView = switch (Core.postingView(s, MemLog.reader(chain), rev)) { case (?v) v; case null { assert false; loop {} } };
assert (revView.record.relation == ?{ original = first; kind = #reversal });
assert (revView.record.legs == [leg("1500", #credit, "EGP", 100_000_000), leg("2000", #debit, "EGP", 100_000_000)]);
// original block is unchanged and still retrievable
let origAfter = MemLog.blocks(chain)[first];
assert (origAfter.hash == origBlock.hash and origAfter.event == origBlock.event);
let origViewAfter = switch (Core.postingView(s, MemLog.reader(chain), first)) { case (?v) v; case null { assert false; loop {} } };
assert (origViewAfter.record == origView.record and origViewAfter.status == #posted);
assert (origViewAfter.reversedBy == ?rev);
// net effect: balances back where they were
assert (Core.balance(s, "2000", null, "EGP").debitsPosted == 100_000_000);
// a second reversal of the same posting is refused
switch (Core.prepareReverse(s, MemLog.reader(chain), poster, clock, first, { revArgs with idempotencyKey = key() })) {
  case (#err(#AlreadyReversed(x))) { assert (x.original == first and x.reversedBy == rev) };
  case (other) { Debug.print(debug_show(other)); assert false };
};
switch (Core.prepareReverse(s, MemLog.reader(chain), poster, clock, 999_999, revArgs)) { case (#err(#UnknownPosting(_))) {}; case (_) assert false };
// correction: a free posting referencing the original
let corr = postOk(poster, { (simple(SEP1 + 2, "2026-09", "6500", "1500", "EGP", 150)) with correctionOf = ?first });
let origView3 = switch (Core.postingView(s, MemLog.reader(chain), first)) { case (?v) v; case null { assert false; loop {} } };
assert (origView3.correctedBy == [corr]);
assert (postErr(poster, { (simple(SEP1, "2026-09", "1500", "2000", "EGP", 1)) with correctionOf = ?424242 }) == #UnknownPosting({ index = 424242 }));
Debug.print("count: immutability checks (block unchanged, reversal linked, double reversal refused, correction linked, unknown targets refused) = 6");

// ─── criterion 4: two-phase ──────────────────────────────────────────────────

let balA0 = Core.balance(s, "1400", null, "EGP");
assert (balA0.debitsPending == 0);
let pendA = reserveOk(poster, simple(SEP1 + 3, "2026-09", "1400", "5000", "EGP", 5_000), null);
let balA = Core.balance(s, "1400", null, "EGP");
// reserving moves the pending column only
assert (balA.debitsPending == 5_000 and balA.debitsPosted == balA0.debitsPosted);
assert (Core.pendingCount(s) == 1);
let postedA = postPendingOk(poster, pendA, null);
let balA2 = Core.balance(s, "1400", null, "EGP");
// posting moves it from pending to posted
assert (balA2.debitsPending == 0 and balA2.debitsPosted == balA0.debitsPosted + 5_000);
assert ((switch (Core.postingView(s, MemLog.reader(chain), pendA)) { case (?v) v.status; case null #posted }) == #postedFromPending({ by = postedA; resolution = { postingDate = SEP1 + 3; valueDate = SEP1 + 3; valueDateRequested = null; period = "2026-09" } }));
// resolving again is refused
switch (Core.preparePostPending(s, MemLog.reader(chain), poster, clock, pendA, null)) { case (#err(#PendingAlreadyResolved(x))) { assert (x.resolvedBy == postedA) }; case (_) assert false };
switch (Core.prepareVoidPending(s, MemLog.reader(chain), poster, pendA)) { case (#err(#PendingAlreadyResolved(_))) {}; case (_) assert false };
// void path
let bal5000 = Core.balance(s, "5000", null, "EGP");
let pendB = reserveOk(poster, simple(SEP1 + 3, "2026-09", "1400", "5000", "EGP", 7_000), null);
assert (Core.balance(s, "5000", null, "EGP").creditsPending == 7_000);
let voidedB = voidOk(poster, pendB);
// voiding releases the reservation and leaves the posted column untouched
assert (Core.balance(s, "5000", null, "EGP").creditsPending == 0);
assert (Core.balance(s, "5000", null, "EGP").creditsPosted == bal5000.creditsPosted);
assert ((switch (Core.postingView(s, MemLog.reader(chain), pendB)) { case (?v) v.status; case null #posted }) == #voided({ by = voidedB; reason = #requested }));
assert (Core.voidedCount(s) == 1);
// an immediate posting is not a pending
switch (Core.prepareVoidPending(s, MemLog.reader(chain), poster, first)) { case (#err(#NotPending(_))) {}; case (_) assert false };
switch (Core.preparePostPending(s, MemLog.reader(chain), poster, clock, 999_999, null)) { case (#err(#NotPending(_))) {}; case (_) assert false };
// expiry: reserve with expiresAt, advance the clock, post attempt reports expired; void recorded
let expiry = clock + 3_600_000_000_000;
let pendC = reserveOk(poster, simple(SEP1 + 3, "2026-09", "1400", "5000", "EGP", 9_000), ?expiry);
switch (Core.prepareReserve(s, poster, clock, simple(SEP1 + 3, "2026-09", "1400", "5000", "EGP", 1), ?(clock - 1))) { case (#err(#ExpiryInPast(_))) {}; case (_) assert false };
assert (Core.expiredPendings(s, clock, 10) == []);
clock += 7_200_000_000_000;   // two hours later
assert (Core.expiredPendings(s, clock, 10) == [pendC]);
switch (Core.preparePostPending(s, MemLog.reader(chain), poster, clock, pendC, null)) {
  case (#ok(#expired(x))) { assert (x.expiresAt == expiry); ignore MemLog.commit(chain, s, clock, admin, Core.expiryVoidEvent(pendC)) };
  case (other) { Debug.print(debug_show(other)); assert false };
};
assert (Core.expiredPendings(s, clock, 10) == []);
assert (Core.balance(s, "1400", null, "EGP").debitsPending == 0);
assert ((switch (Core.postingView(s, MemLog.reader(chain), pendC)) { case (?v) (switch (v.status) { case (#voided(x)) x.reason == #expired; case (_) false }); case null false }));
// override on post: reserved in September, booked into August (still open)
let pendD = reserveOk(poster, simple(SEP1 + 3, "2026-09", "1400", "5000", "EGP", 11_000), null);
ignore postPendingOk(poster, pendD, ?{ postingDate = AUG1 + 5; valueDate = AUG1 + 5; valueDateRequested = null; period = "2026-08" });
assert (Core.effectiveResolution(s, MemLog.reader(chain), pendD) == ?{ postingDate = AUG1 + 5; valueDate = AUG1 + 5; valueDateRequested = null; period = "2026-08" });
assert ((switch (Core.trialBalance(s, "2026-08")) { case (?tb) tb.postingCount; case null 0 }) == 1);
// period close is blocked while a pending targets it (July has no earlier period)
let pendE = reserveOk(poster, simple(JUL1 + 6, "2026-07", "1400", "5000", "EGP", 13_000), null);
assert (cfgErr(Core.prepareClosePeriod(s, admin, "2026-07")) == #PendingPostingsOutstanding({ id = "2026-07"; count = 1 }));
ignore voidOk(poster2, pendE);
assert (Core.pendingCount(s) == 0);
Debug.print("count: two-phase pendings reserved = 5");
Debug.print("count: two-phase pendings posted = 2");
Debug.print("count: two-phase pendings voided by request = 2");
Debug.print("count: two-phase pendings voided by expiry = 1");
Debug.print("two-phase unresolved pendings at end: " # Nat.toText(Core.pendingCount(s)));

// ─── criterion 5: value dating and period close ──────────────────────────────

let tbJulBefore = switch (Core.trialBalance(s, "2026-07")) { case (?tb) tb; case null { assert false; loop {} } };
assert (tbJulBefore.postingCount == 0);
let tbSepBefore = switch (Core.trialBalance(s, "2026-09")) { case (?tb) tb; case null { assert false; loop {} } };
// back-dated into open July (today is 9 September)
ignore postOk(poster, simple(JUL1 + 10, "2026-07", "1000", "3000", "EGP", 250_000));
let tbJulAfter = switch (Core.trialBalance(s, "2026-07")) { case (?tb) tb; case null { assert false; loop {} } };
assert (tbJulAfter.postingCount == 1 and tbJulAfter.rows.size() == 2);
let tbSepAfter = switch (Core.trialBalance(s, "2026-09")) { case (?tb) tb; case null { assert false; loop {} } };
// September's own columns unchanged; closing columns moved by the back-dated posting
func periodTotal(tb : T.TrialBalance, ccy : Text) : (Nat, Nat, Nat, Nat) {
  for (t in tb.totals.vals()) { if (t.currency == ccy) return (t.periodDebits, t.periodCredits, t.closingDebits, t.closingCredits) };
  (0, 0, 0, 0)
};
let (spd, spc, scd, scc) = periodTotal(tbSepBefore, "EGP");
let (spd2, spc2, scd2, scc2) = periodTotal(tbSepAfter, "EGP");
assert (spd == spd2 and spc == spc2 and scd2 == scd + 250_000 and scc2 == scc + 250_000);
// close July, then a back-dated posting into it is refused and July is frozen
ignore cfg(admin, Core.prepareClosePeriod(s, admin, "2026-07"));
assert (postErr(poster, simple(JUL1 + 11, "2026-07", "1000", "3000", "EGP", 1)) == #PeriodClosed({ period = "2026-07" }));
let tbJulFrozen = switch (Core.trialBalance(s, "2026-07")) { case (?tb) tb; case null { assert false; loop {} } };
assert (tbJulFrozen == tbJulAfter);
assert (cfgErr(Core.prepareClosePeriod(s, admin, "2026-07")) == #PeriodAlreadyClosed({ id = "2026-07" }));
assert (cfgErr(Core.prepareClosePeriod(s, admin, "2026-09")) == #EarlierPeriodOpen({ id = "2026-09"; earlier = "2026-08" }));
assert (postErr(poster, simple(SEP1 - 1, "2026-09", "1500", "2000", "EGP", 1)) == #PostingDateOutsidePeriod({ period = "2026-09"; postingDate = SEP1 - 1; start = SEP1; end = SEP30 }));
assert (postErr(poster, simple(TODAY + 1, "2026-09", "1500", "2000", "EGP", 1)) == #PostingDateInFuture({ postingDate = TODAY + 1; today = TODAY }));
assert (postErr(poster, simple(SEP1, "2026-10", "1500", "2000", "EGP", 1)) == #UnknownPeriod({ period = "2026-10" }));
assert (postErr(poster, input(key(), SEP1, SEP1 + 400, "2026-09", [leg("1500", #debit, "EGP", 1), leg("2000", #credit, "EGP", 1)])) == #ValueDateTooFar({ valueDate = SEP1 + 400; postingDate = SEP1; maxDriftDays = 366 }));
// value date: posted 9 Sept, value-dated 10 Aug; the value-dated balance moves on 10 Aug, the period balance in September
let vdBefore = Core.valueDatedBalance(s, "1510", null, "USD", AUG1 + 9);
ignore postOk(poster, input(key(), TODAY, AUG1 + 9, "2026-09", [leg("1510", #debit, "USD", 4_242), leg("2300", #credit, "USD", 4_242)]));
assert (Core.valueDatedBalance(s, "1510", null, "USD", AUG1 + 8).debits == vdBefore.debits);
assert (Core.valueDatedBalance(s, "1510", null, "USD", AUG1 + 9).debits == vdBefore.debits + 4_242);
assert ((switch (Core.trialBalance(s, "2026-08")) { case (?tb) periodTotal(tb, "USD").0; case null 1 }) == 0);
Debug.print("count: value dating back-dated postings accepted into an open period = 1");
Debug.print("count: value dating date and period errors typed = 7");
Debug.print("count: value-dated balance checks = 3");

// ─── criterion 8: leadsheet mapping through the core ─────────────────────────

ignore cfg(admin, Core.prepareSetLeadsheetSchema(s, admin, F.ranges));
assert (cfgErr(Core.prepareSetLeadsheetSchema(s, admin, [])) == #InvalidLeadsheetSchema({ reason = "schema has no ranges" }));
let mapped = switch (Core.mappedTrialBalance(s, "2026-09")) { case (?m) m; case null { assert false; loop {} } };
let tbSep = switch (Core.trialBalance(s, "2026-09")) { case (?tb) tb; case null { assert false; loop {} } };
assert (mapped.mapped.size() + mapped.unmapped.size() == tbSep.rows.size());
// 9999 (suspense) and 2300 (FX position) lie in no range of the schema: reported, never bucketed
assert (Array.find<T.TrialBalanceRow>(mapped.unmapped, func(r) { r.account == "9999" }) != null);
assert (Array.find<T.TrialBalanceRow>(mapped.unmapped, func(r) { r.account == "2300" }) != null);
for (u in mapped.unmapped.vals()) { assert (u.account == "9999" or u.account == "2300") };
for (m in mapped.mapped.vals()) { assert (m.row.account != "9999" and m.row.account != "2300") };
Debug.print("count: leadsheet mapping rows examined = " # Nat.toText(tbSep.rows.size()));
Debug.print("count: leadsheet mapping rows mapped = " # Nat.toText(mapped.mapped.size()));
Debug.print("count: leadsheet mapping rows unmapped (9999 and 2300) = " # Nat.toText(mapped.unmapped.size()));

// ─── account closure rules ───────────────────────────────────────────────────

ignore cfg(admin, Core.prepareOpenAccount(s, admin, "1520", "Petty cash", #debit, #asset, #none));
ignore postOk(poster, simple(TODAY, "2026-09", "1520", "1500", "EGP", 500));
switch (cfgErr(Core.prepareCloseAccount(s, admin, "1520"))) { case (#AccountHasBalance(x)) { assert (x.debits == 500 and x.credits == 0) }; case (_) assert false };
ignore postOk(poster, simple(TODAY, "2026-09", "1500", "1520", "EGP", 500));
let pendF = reserveOk(poster, simple(TODAY, "2026-09", "1520", "1500", "EGP", 1), null);
assert (cfgErr(Core.prepareCloseAccount(s, admin, "1520")) == #AccountHasPending({ code = "1520"; count = 1 }));
ignore voidOk(poster, pendF);
ignore cfg(admin, Core.prepareCloseAccount(s, admin, "1520"));
assert (postErr(poster, simple(TODAY, "2026-09", "1520", "1500", "EGP", 1)) == #AccountClosed({ account = "1520" }));
assert (cfgErr(Core.prepareCloseAccount(s, admin, "1520")) == #AccountAlreadyClosed({ code = "1520" }));
Debug.print("count: account closure guards exercised = 4");


// ─── L4: engine-enforced balance limits ──────────────────────────────────────

ignore cfg(admin, Core.prepareOpenAccount(s, admin, "2001", "Customer deposit (no overdraft)", #credit, #liability, #debitsNotExceedCredits));
ignore cfg(admin, Core.prepareOpenAccount(s, admin, "1501", "Till (never negative)", #debit, #asset, #creditsNotExceedDebits));
// deposit: 1000 in, 1001 out refused, 1000 out accepted, then nothing more
ignore postOk(poster, simple(TODAY, "2026-09", "1500", "2001", "EGP", 1_000));
switch (postErr(poster, simple(TODAY, "2026-09", "2001", "1500", "EGP", 1_001))) {
  case (#ExceedsCredits(x)) { assert (x.account == "2001" and x.creditsPosted == 1_000 and x.debitsPosted == 0 and x.debitsPending == 0 and x.amount == 1_001) };
  case (e) { Debug.print(debug_show(e)); assert false };
};
// a pending debit reserves against the limit
let pendL = reserveOk(poster, simple(TODAY, "2026-09", "2001", "1500", "EGP", 300), null);
switch (postErr(poster, simple(TODAY, "2026-09", "2001", "1500", "EGP", 701))) {
  case (#ExceedsCredits(x)) { assert (x.debitsPending == 300 and x.amount == 701) };
  case (e) { Debug.print(debug_show(e)); assert false };
};
ignore postOk(poster, simple(TODAY, "2026-09", "2001", "1500", "EGP", 700));
ignore voidOk(poster, pendL);
ignore postOk(poster, simple(TODAY, "2026-09", "2001", "1500", "EGP", 300));
switch (postErr(poster, simple(TODAY, "2026-09", "2001", "1500", "EGP", 1))) { case (#ExceedsCredits(_)) {}; case (_) assert false };
// two legs on the same constrained account in one posting accumulate
ignore postOk(poster, simple(TODAY, "2026-09", "1500", "2001", "EGP", 50));
switch (postErr(poster, input(key(), TODAY, TODAY, "2026-09", [leg("2001", #debit, "EGP", 30), leg("2001", #debit, "EGP", 30), leg("1500", #credit, "EGP", 60)]))) {
  case (#ExceedsCredits(x)) { assert (x.amount == 30 and x.debitsPending == 30) };
  case (e) { Debug.print(debug_show(e)); assert false };
};
// till: credits may not exceed debits
switch (postErr(poster, simple(TODAY, "2026-09", "6000", "1501", "EGP", 1))) {
  case (#ExceedsDebits(x)) { assert (x.account == "1501" and x.amount == 1) };
  case (e) { Debug.print(debug_show(e)); assert false };
};
ignore postOk(poster, simple(TODAY, "2026-09", "1501", "1500", "EGP", 10));
ignore postOk(poster, simple(TODAY, "2026-09", "6000", "1501", "EGP", 10));
// unconstrained accounts are unaffected (5000 goes debit freely)
ignore postOk(poster, simple(TODAY, "2026-09", "5000", "1500", "EGP", 999_999_999));
Debug.print("count: balance-limit refusals (ExceedsCredits/ExceedsDebits) = 5");
Debug.print("count: balance-limit postings accepted at the limit = 7");

// ─── L9: balance as of a posting date ────────────────────────────────────────

var asOfChecks = 0;
for (d in [JUL1, JUL31, AUG1 + 5, AUG31, SEP1, TODAY].vals()) {
  for ((acct, ccy) in [("1500", "EGP"), ("1510", "USD"), ("2001", "EGP"), ("1000", "EGP")].vals()) {
    var dr = 0; var cr = 0;
    for (b in MemLog.blocks(chain).vals()) {
      let (legsOpt, pd) : (?[T.Leg], Nat) = switch (b.event) {
        case (#posted(r)) (?r.legs, r.postingDate);
        case (#post(x)) { switch (MemLog.blocks(chain)[x.pendingIndex].event) { case (#pending(p)) (?p.record.legs, x.resolution.postingDate); case (_) (null, 0) } };
        case (_) (null, 0);
      };
      switch (legsOpt) {
        case (?legs) { if (pd <= d) { for (l in legs.vals()) { if (l.account == acct and l.currency == ccy) { switch (l.side) { case (#debit) dr += l.amount; case (#credit) cr += l.amount } } } } };
        case null {};
      };
    };
    assert (Core.balanceAsOf(s, acct, null, ccy, d) == { debits = dr; credits = cr });
    asOfChecks += 1;
  };
};
// at the last day, balance-as-of equals the posted balance
let bl = Core.balance(s, "1500", null, "EGP");
assert (Core.balanceAsOf(s, "1500", null, "EGP", TODAY) == { debits = bl.debitsPosted; credits = bl.creditsPosted });
Debug.print("count: balance-as-of checks against an independent fold = " # Nat.toText(asOfChecks));

// ─── L10: atomic batches ─────────────────────────────────────────────────────

func batch(caller : Principal, inputs : [T.PostingInput]) : { #ok : [Core.Prepared]; #err : T.BatchError } {
  Core.prepareBatch(s, caller, clock, inputs)
};
func commitBatch(prepared : [Core.Prepared]) : [Nat] {
  Array.map<Core.Prepared, Nat>(prepared, func(p) {
    switch (p) { case (#event(e)) MemLog.commit(chain, s, clock, poster, e).index; case (#duplicate(i)) i }
  })
};
let hb = Core.height(s);
let b1 = [simple(TODAY, "2026-09", "1500", "5000", "EGP", 11), simple(TODAY, "2026-09", "1500", "5000", "EGP", 22), simple(TODAY, "2026-09", "1500", "5000", "USD", 33)];
let idxs = switch (batch(poster, b1)) { case (#ok(p)) commitBatch(p); case (#err(e)) { Debug.print(debug_show(e)); assert false; [] } };
assert (idxs.size() == 3 and Core.height(s) == hb + 3);
// retrying the same batch is idempotent: same indices, no new blocks
switch (batch(poster, b1)) { case (#ok(p)) { assert (commitBatch(p) == idxs and Core.height(s) == hb + 3) }; case (#err(_)) assert false };
// a batch with a bad third item admits nothing
let fp0 = Core.fingerprint(s);
switch (batch(poster, [simple(TODAY, "2026-09", "1500", "5000", "EGP", 1), simple(TODAY, "2026-09", "1500", "5000", "EGP", 2),
                       input(key(), TODAY, TODAY, "2026-09", [leg("1500", #debit, "EGP", 3), leg("5000", #credit, "EGP", 4)])])) {
  case (#err(e)) { assert (e.index == 2); switch (e.error) { case (#Unbalanced(_)) {}; case (_) assert false } };
  case (#ok(_)) assert false;
};
assert (Core.fingerprint(s) == fp0 and Core.height(s) == hb + 3);
// a key repeated inside the batch
let kdup = key();
switch (batch(poster, [input(kdup, TODAY, TODAY, "2026-09", [leg("1500", #debit, "EGP", 5), leg("5000", #credit, "EGP", 5)]), input(kdup, TODAY, TODAY, "2026-09", [leg("1500", #debit, "EGP", 6), leg("5000", #credit, "EGP", 6)])])) {
  case (#err(e)) { assert (e == { index = 1; error = #DuplicateKeyInBatch({ first = 0; index = 1 }) }) };
  case (#ok(_)) assert false;
};
// limits accumulate across the batch: 2001 has exactly 50 of credit capacity left (1050 credits, 1000 debits)
switch (batch(poster, [simple(TODAY, "2026-09", "2001", "1500", "EGP", 30), simple(TODAY, "2026-09", "2001", "1500", "EGP", 30)])) {
  case (#err(e)) { assert (e.index == 1); switch (e.error) { case (#ExceedsCredits(x)) { assert (x.debitsPending == 30) }; case (_) assert false } };
  case (#ok(_)) assert false;
};
switch (batch(poster, [simple(TODAY, "2026-09", "2001", "1500", "EGP", 30), simple(TODAY, "2026-09", "2001", "1500", "EGP", 20)])) {
  case (#ok(p)) { assert (commitBatch(p).size() == 2) }; case (#err(e)) { Debug.print(debug_show(e)); assert false };
};
assert (batch(poster, []) == #err({ index = 0; error = #EmptyBatch }));
assert (batch(poster, Array.tabulate<T.PostingInput>(257, func(_) { simple(TODAY, "2026-09", "1500", "5000", "EGP", 1) })) == #err({ index = 0; error = #BatchTooLarge({ count = 257; max = 256 }) }));
assert (batch(outsider, b1) == #err({ index = 0; error = #Unauthorized }));
Debug.print("count: atomic batches committed = 3");
Debug.print("count: atomic batches refused whole (unbalanced item, duplicate key, limit, empty, too large, unauthorized) = 6");


// ─── sub-ledgers: holders under a control account ────────────────────────────

ignore cfg(admin, Core.prepareOpenAccount(s, admin, "2110", "Token holders (control)", #credit, #liability, #debitsNotExceedCredits));
let holderA = Blob.fromArray(Array.tabulate<Nat8>(62, func(i) { Nat8.fromNat(i) }));
let holderB = Blob.fromArray(Array.tabulate<Nat8>(62, func(i) { Nat8.fromNat(255 - i) }));
ignore postOk(poster, input(key(), TODAY, TODAY, "2026-09", [leg("1500", #debit, "EGP", 100), legS("2110", holderA, #credit, "EGP", 100)]));
ignore postOk(poster, input(key(), TODAY, TODAY, "2026-09", [leg("1500", #debit, "EGP", 50), legS("2110", holderB, #credit, "EGP", 50)]));
assert (Core.balance(s, "2110", ?holderA, "EGP").creditsPosted == 100);
assert (Core.balance(s, "2110", ?holderB, "EGP").creditsPosted == 50);
assert (Core.balance(s, "2110", null, "EGP").creditsPosted == 0);          // the control account itself holds nothing
assert (Core.accountTotal(s, "2110", "EGP").creditsPosted == 150);
// limits are per holder: B cannot spend A's balance
switch (postErr(poster, input(key(), TODAY, TODAY, "2026-09", [legS("2110", holderB, #debit, "EGP", 51), leg("1500", #credit, "EGP", 51)]))) {
  case (#ExceedsCredits(x)) { assert (x.subledger == ?holderB and x.creditsPosted == 50 and x.amount == 51) };
  case (e) { Debug.print(debug_show(e)); assert false };
};
// holder-to-holder transfer with a fee leg: three legs, one control account
ignore postOk(poster, input(key(), TODAY, TODAY, "2026-09", [legS("2110", holderA, #debit, "EGP", 30), legS("2110", holderB, #credit, "EGP", 29), leg("5000", #credit, "EGP", 1)]));
assert (Core.balance(s, "2110", ?holderA, "EGP").debitsPosted == 30 and Core.balance(s, "2110", ?holderB, "EGP").creditsPosted == 79);
// the trial balance reports the control account once, summed over holders
let tbSub = switch (Core.trialBalance(s, "2026-09")) { case (?tb) tb; case null { assert false; loop {} } };
let rows2110 = Array.filter<T.TrialBalanceRow>(tbSub.rows, func(r) { r.account == "2110" });
assert (rows2110.size() == 1 and rows2110[0].periodCredits == 179 and rows2110[0].periodDebits == 30);
assert (Core.subledgerBalances(s, "2110").size() == 2);
// balance-as-of and value-dated per holder, and summed
assert (Core.balanceAsOf(s, "2110", ?holderA, "EGP", TODAY) == { debits = 30; credits = 100 });
assert (Core.balanceAsOf(s, "2110", null, "EGP", TODAY) == { debits = 30; credits = 179 });
assert (Core.valueDatedBalance(s, "2110", ?holderB, "EGP", TODAY) == { debits = 0; credits = 79 });
// key limits: empty and over-long keys are refused
assert (postErr(poster, input(key(), TODAY, TODAY, "2026-09", [legS("2110", Blob.fromArray([]), #credit, "EGP", 1), leg("1500", #debit, "EGP", 1)])) == #SubledgerKeyInvalid({ index = 0; size = 0 }));
assert (postErr(poster, input(key(), TODAY, TODAY, "2026-09", [legS("2110", Blob.fromArray(Array.tabulate<Nat8>(65, func(_) { 1 })), #credit, "EGP", 1), leg("1500", #debit, "EGP", 1)])) == #SubledgerKeyInvalid({ index = 0; size = 65 }));
// closing the control account is refused while any holder has a balance, naming the holder
switch (cfgErr(Core.prepareCloseAccount(s, admin, "2110"))) { case (#AccountHasBalance(x)) { assert (x.subledger != null) }; case (_) assert false };
// general ledger entries carry the holder key
let glSub = switch (Core.generalLedger(s, MemLog.reader(chain), "2026-09", ?"2110")) { case (?g) g; case null { assert false; loop {} } };
var withKey = 0;
for (a in glSub.accounts.vals()) { for (e in a.entries.vals()) { if (e.subledger != null) withKey += 1 } };
assert (withKey == 4);
Debug.print("count: sub-ledger checks (per-holder balances, limits, control totals, keys, close guard, GL) = 16");


// ─── the journal calendar: business date, calendar, postAtBusinessDate ───────────────────────

// business date: admin only, never backwards, never past the clock day; it becomes "today" for admission
assert (Core.businessDate(s) == null);
assert (cfgErr(Core.prepareRollBusinessDate(s, poster, clock, TODAY)) == #Unauthorized);
assert (cfgErr(Core.prepareRollBusinessDate(s, admin, clock, TODAY + 1)) == #BusinessDateInFuture({ requested = TODAY + 1; today = TODAY }));
ignore cfg(admin, Core.prepareRollBusinessDate(s, admin, clock, TODAY - 2));
assert (Core.businessDate(s) == ?(TODAY - 2) and Core.effectiveToday(s, clock) == TODAY - 2);
assert (cfgErr(Core.prepareRollBusinessDate(s, admin, clock, TODAY - 3)) == #BusinessDateBackwards({ current = TODAY - 2; requested = TODAY - 3 }));
assert (cfgErr(Core.prepareRollBusinessDate(s, admin, clock, TODAY - 2)) == #BusinessDateBackwards({ current = TODAY - 2; requested = TODAY - 2 }));
// a posting dated after the business date is now "in the future" even though the clock has reached it
assert (postErr(poster, simple(TODAY, "2026-09", "1500", "2000", "EGP", 1)) == #PostingDateInFuture({ postingDate = TODAY; today = TODAY - 2 }));
ignore postOk(poster, simple(TODAY - 2, "2026-09", "1500", "2000", "EGP", 1));
Debug.print("count: business-date roll checks = 6");

// postAtBusinessDate: dates default to the business date, period resolved from it
let bIn : T.BusinessPostingInput = { idempotencyKey = key(); legs = [leg("1500", #debit, "EGP", 9), leg("2000", #credit, "EGP", 9)]; sourceRef = { kind = "bd"; id = "1" }; narration = "at business date"; correctionOf = null };
let bIdx = switch (Core.preparePostAtBusinessDate(s, poster, clock, bIn)) { case (#ok(#event(e))) MemLog.commit(chain, s, clock, poster, e).index; case (o) { Debug.print(debug_show(o)); assert false; 0 } };
let bView = switch (Core.postingView(s, MemLog.reader(chain), bIdx)) { case (?v) v; case null { assert false; loop {} } };
assert (bView.record.postingDate == TODAY - 2 and bView.record.valueDate == TODAY - 2 and bView.record.period == "2026-09");
Debug.print("count: postings defaulted to the business date = 1");

// calendar: Friday/Saturday rest days and one holiday; shifts are recorded, business dates pass unchanged
ignore cfg(admin, Core.prepareSetCalendar(s, admin, ?{ restDays = [4, 5]; holidays = [SEP1 + 3]; policy = #next }));   // 2026-09-04 (Friday) also a holiday
assert (cfgErr(Core.prepareSetCalendar(s, admin, ?{ restDays = [0, 1, 2, 3, 4, 5, 6]; holidays = []; policy = #next })) == #InvalidCalendar({ reason = "a week needs at least one working day" }));
// 2026-09-05 is a Saturday: value date requested 20701 -> next business day Sunday 20702, recorded
let sat = SEP1 + 4;
let vdSatBefore = Core.valueDatedBalance(s, "1500", null, "EGP", sat).debits;
let vdSunBefore = Core.valueDatedBalance(s, "1500", null, "EGP", sat + 1).debits;
let shiftedIdx = postOk(poster, input(key(), TODAY - 2, sat, "2026-09", [leg("1500", #debit, "EGP", 3), leg("2000", #credit, "EGP", 3)]));
let shiftedView = switch (Core.postingView(s, MemLog.reader(chain), shiftedIdx)) { case (?v) v; case null { assert false; loop {} } };
assert (shiftedView.record.valueDate == sat + 1 and shiftedView.record.valueDateRequested == ?sat);
// a business day passes unchanged with no requested date recorded
let mon = SEP1 + 6;
let plainIdx = postOk(poster, input(key(), TODAY - 2, mon, "2026-09", [leg("1500", #debit, "EGP", 3), leg("2000", #credit, "EGP", 3)]));
assert ((switch (Core.postingView(s, MemLog.reader(chain), plainIdx)) { case (?v) v.record.valueDateRequested == null and v.record.valueDate == mon; case null false }));
// the value-dated balance moved on the effective date (Sunday), not the requested one (Saturday)
assert (Core.valueDatedBalance(s, "1500", null, "EGP", sat).debits == vdSatBefore);
assert (Core.valueDatedBalance(s, "1500", null, "EGP", sat + 1).debits == vdSunBefore + 3);

// reject policy
ignore cfg(admin, Core.prepareSetCalendar(s, admin, ?{ restDays = [4, 5]; holidays = []; policy = #reject }));
assert (postErr(poster, input(key(), TODAY - 2, sat, "2026-09", [leg("1500", #debit, "EGP", 3), leg("2000", #credit, "EGP", 3)])) == #ValueDateNotBusinessDay({ valueDate = sat }));
// previous policy on a pending override
ignore cfg(admin, Core.prepareSetCalendar(s, admin, ?{ restDays = [4, 5]; holidays = []; policy = #previous }));
let pendS = reserveOk(poster, simple(TODAY - 2, "2026-09", "1500", "2000", "EGP", 4), null);
ignore postPendingOk(poster, pendS, ?{ postingDate = TODAY - 2; valueDate = sat; valueDateRequested = null; period = "2026-09" });
assert (Core.effectiveResolution(s, MemLog.reader(chain), pendS) == ?{ postingDate = TODAY - 2; valueDate = sat - 2; valueDateRequested = ?sat; period = "2026-09" });   // Saturday -> Friday is a rest day -> Thursday
// clearing the calendar restores free value dates
ignore cfg(admin, Core.prepareSetCalendar(s, admin, null));
let freeIdx = postOk(poster, input(key(), TODAY - 2, sat, "2026-09", [leg("1500", #debit, "EGP", 3), leg("2000", #credit, "EGP", 3)]));
assert ((switch (Core.postingView(s, MemLog.reader(chain), freeIdx)) { case (?v) v.record.valueDate == sat and v.record.valueDateRequested == null; case null false }));
Debug.print("count: calendar checks (shift recorded, unchanged business day, value-dated balance, reject, pending override, cleared) = 8");
// bring the books up to the clock day so the sections below post at TODAY as before
ignore cfg(admin, Core.prepareRollBusinessDate(s, admin, clock, TODAY));
assert (Core.effectiveToday(s, clock) == TODAY);
// ─── deactivation and re-activation ──────────────────────────────────────────

ignore cfg(admin, Core.prepareSetActivationHeight(s, admin, T.ACTIVATION_OFF));
switch (postErr(poster, simple(TODAY, "2026-09", "1500", "2000", "EGP", 1))) { case (#NotActivated(_)) {}; case (_) assert false };
ignore cfg(admin, Core.prepareSetActivationHeight(s, admin, 0));
ignore postOk(poster, simple(TODAY, "2026-09", "1500", "2000", "EGP", 1));
// poster removal and admin transfer are recorded and effective
ignore cfg(admin, Core.prepareRemovePoster(s, admin, poster2));
assert (postErr(poster2, simple(TODAY, "2026-09", "1500", "2000", "EGP", 1)) == #Unauthorized);
ignore cfg(admin, Core.prepareTransferAdmin(s, admin, poster));
assert (cfgErr(Core.prepareAddPoster(s, admin, poster2)) == #Unauthorized);
ignore cfg(poster, Core.prepareAddPoster(s, poster, poster2));
Debug.print("count: gate off/on, poster removal and admin transfer checks = 5");

// ─── criterion 6: trial balance vs independent fold; criterion 10: replay ────

// Independent fold, written without the core's helpers: walk the blocks,
// resolve pendings by looking the pending block up in the same array.
type Sum = { var dr : Nat; var cr : Nat };
func cmp3(a : (Text, Text, Text), b : (Text, Text, Text)) : Order.Order {
  switch (Text.compare(a.0, b.0)) { case (#equal) { switch (Text.compare(a.1, b.1)) { case (#equal) Text.compare(a.2, b.2); case (o) o } }; case (o) o }
};
let blocks = MemLog.blocks(chain);
let fold = Map.empty<(Text, Text, Text), Sum>();
let periodStart = Map.empty<Text, Nat>();
var folded = 0;
func addLegs(period : Text, legs : [T.Leg]) {
  for (l in legs.vals()) {
    let k = (period, l.account, l.currency);
    let sum = switch (Map.get(fold, cmp3, k)) { case (?x) x; case null { let x : Sum = { var dr = 0; var cr = 0 }; Map.add(fold, cmp3, k, x); x } };
    switch (l.side) { case (#debit) sum.dr += l.amount; case (#credit) sum.cr += l.amount };
  };
  folded += 1;
};
for (b in blocks.vals()) {
  switch (b.event) {
    case (#posted(r)) addLegs(r.period, r.legs);
    case (#post(x)) {
      switch (blocks[x.pendingIndex].event) { case (#pending(p)) addLegs(x.resolution.period, p.record.legs); case (_) assert false };
    };
    case (#periodOpened(p)) Map.add(periodStart, Text.compare, p.id, p.start);
    case (_) {};
  };
};
var rowsCompared = 0;
for (per in ["2026-07", "2026-08", "2026-09"].vals()) {
  let tb = switch (Core.trialBalance(s, per)) { case (?tb) tb; case null { assert false; loop {} } };
  assert (tb.balanced);
  let pStart = switch (Map.get(periodStart, Text.compare, per)) { case (?x) x; case null { assert false; 0 } };
  // every row in the trial balance equals the fold
  for (row in tb.rows.vals()) {
    let own = switch (Map.get(fold, cmp3, (per, row.account, row.currency))) { case (?x) (x.dr, x.cr); case null (0, 0) };
    assert (row.periodDebits == own.0 and row.periodCredits == own.1);
    var cdr = 0; var ccr = 0;
    for (((q, a, c), sum) in Map.entries(fold)) {
      let qStart = switch (Map.get(periodStart, Text.compare, q)) { case (?x) x; case null { assert false; 0 } };
      if (a == row.account and c == row.currency and qStart <= pStart) { cdr += sum.dr; ccr += sum.cr };
    };
    assert (row.closingDebits == cdr and row.closingCredits == ccr);
    rowsCompared += 1;
  };
  // and every fold entry that belongs in this trial balance is present as a row
  for (((q, a, c), _) in Map.entries(fold)) {
    let qStart = switch (Map.get(periodStart, Text.compare, q)) { case (?x) x; case null { assert false; 0 } };
    if (qStart <= pStart) { assert (Array.find<T.TrialBalanceRow>(tb.rows, func(r) { r.account == a and r.currency == c }) != null) };
  };
  // replayed state agrees
  let fresh = Core.replay(admin, blocks);
  assert (Core.fingerprint(fresh) == Core.fingerprint(s));
  assert (Core.trialBalance(fresh, per) == ?tb);
  assert (Core.generalLedger(fresh, MemLog.reader(chain), per, null) == Core.generalLedger(s, MemLog.reader(chain), per, null));
};
Debug.print("count: trial balance independent fold postings folded = " # Nat.toText(folded));
Debug.print("count: trial balance rows compared to the fold = " # Nat.toText(rowsCompared));
Debug.print("count: periods compared with replayed state = 3");
assert (rowsCompared > 0 and folded > 300);

// general ledger entries reconcile to the trial balance rows
let gl = switch (Core.generalLedger(s, MemLog.reader(chain), "2026-09", null)) { case (?g) g; case null { assert false; loop {} } };
var glRows = 0;
for (a in gl.accounts.vals()) {
  var dr = 0; var cr = 0;
  for (e in a.entries.vals()) { switch (e.side) { case (#debit) dr += e.amount; case (#credit) cr += e.amount } };
  assert (dr == a.periodDebits and cr == a.periodCredits);
  assert (a.openingDebits + a.periodDebits == a.closingDebits and a.openingCredits + a.periodCredits == a.closingCredits);
  glRows += 1;
};
Debug.print("count: general ledger accounts reconciled to trial balance = " # Nat.toText(glRows));
Debug.print("count: general ledger entries = " # Nat.toText(gl.entryCount));
assert (glRows == (switch (Core.trialBalance(s, "2026-09")) { case (?tb) tb.rows.size(); case null 0 }));

Debug.print("journal height at end: " # Nat.toText(Core.height(s)) # ", posted " # Nat.toText(Core.postedCount(s)) # ", voided " # Nat.toText(Core.voidedCount(s)));

// ─── the calendar's authority: where "today" comes from on a substrate whose clock is not a clock ─────────
// A fresh journal, so the business-date battery above keeps its own state. Thebes' Time.now() is the block
// height in seconds (day 0 for the chain's first 86,400 blocks): under the substrate clock no 2026 date can be
// set there; under the business-date authority the rolled date is the calendar, bounded per roll.
let c2 = MemLog.new();
let s2 = Core.newState(admin);
func cfg2(caller : Principal, r : { #ok : T.Event; #err : T.ConfigError }) : Nat {
  switch (r) { case (#ok(e)) MemLog.commit(c2, s2, clock, caller, e).index; case (#err(e)) { Debug.print("unexpected config error: " # debug_show(e)); assert false; 0 } }
};
let thebesClock : Nat64 = 21_794_000_000_000;   // height 21,794 → 1970-01-01, day 0, as measured on a Thebes chain
assert (Core.calendarAuthority(s2) == { authority = #substrateClock; maxRollDays = 0 });
// the substrate clock: a 2026 date is "in the future" on a chain whose clock says 1970; the refusal measured on the bed
assert (cfgErr(Core.prepareRollBusinessDate(s2, admin, thebesClock, TODAY)) == #BusinessDateInFuture({ requested = TODAY; today = 0 }));
// the act's own gates
assert (cfgErr(Core.prepareSetCalendarAuthority(s2, poster, #businessDate, 31, ?TODAY)) == #Unauthorized);
assert (cfgErr(Core.prepareSetCalendarAuthority(s2, admin, #substrateClock, 0, ?TODAY)) == #InvalidCalendarAuthority({ reason = "a business date travels by the roll command under the substrate clock" }));
assert (cfgErr(Core.prepareSetCalendarAuthority(s2, admin, #substrateClock, 5, null)) == #InvalidCalendarAuthority({ reason = "the roll bound applies under the business-date authority only" }));
assert (cfgErr(Core.prepareSetCalendarAuthority(s2, admin, #businessDate, 0, ?TODAY)) == #InvalidCalendarAuthority({ reason = "the business-date authority needs a roll bound of at least one day" }));
assert (cfgErr(Core.prepareSetCalendarAuthority(s2, admin, #businessDate, 31, null)) == #InvalidCalendarAuthority({ reason = "the business-date authority needs a business date: none is set and the act carries none" }));
let fpBefore = Core.fingerprint(s2);
// the authority with its first business date, on the Thebes clock: the date is set without consulting the clock
ignore cfg2(admin, Core.prepareSetCalendarAuthority(s2, admin, #businessDate, 31, ?TODAY));
assert (Core.calendarAuthority(s2) == { authority = #businessDate; maxRollDays = 31 });
assert (Core.businessDate(s2) == ?TODAY and Core.effectiveToday(s2, thebesClock) == TODAY);
assert (Core.fingerprint(s2) != fpBefore);
// rolls under it: never against the clock, always monotone, never past the bound
ignore cfg2(admin, Core.prepareRollBusinessDate(s2, admin, thebesClock, TODAY + 30));
assert (Core.effectiveToday(s2, thebesClock) == TODAY + 30);
assert (cfgErr(Core.prepareRollBusinessDate(s2, admin, thebesClock, TODAY + 62)) == #BusinessDateRollTooFar({ current = TODAY + 30; requested = TODAY + 62; maxRollDays = 31 }));
assert (cfgErr(Core.prepareRollBusinessDate(s2, admin, thebesClock, TODAY + 29)) == #BusinessDateBackwards({ current = TODAY + 30; requested = TODAY + 29 }));
ignore cfg2(admin, Core.prepareRollBusinessDate(s2, admin, thebesClock, TODAY + 61));
// a date carried by a later authority act must still advance
assert (cfgErr(Core.prepareSetCalendarAuthority(s2, admin, #businessDate, 40, ?(TODAY + 10))) == #BusinessDateBackwards({ current = TODAY + 61; requested = TODAY + 10 }));
ignore cfg2(admin, Core.prepareSetCalendarAuthority(s2, admin, #businessDate, 40, null));
assert (Core.calendarAuthority(s2) == { authority = #businessDate; maxRollDays = 40 } and Core.businessDate(s2) == ?(TODAY + 61));
// a posting dated at the business date books on the Thebes clock: the period is the day's, the clock is not asked
ignore cfg2(admin, Core.prepareRegisterCurrency(s2, admin, "EGP", 2));
ignore cfg2(admin, Core.prepareOpenAccount(s2, admin, "1500", "Cash", #debit, #asset, #none));
ignore cfg2(admin, Core.prepareOpenAccount(s2, admin, "2000", "Deposits", #credit, #liability, #none));
ignore cfg2(admin, Core.prepareOpenPeriod(s2, admin, "2026-11", TODAY + 40, TODAY + 70));
ignore cfg2(admin, Core.prepareAddPoster(s2, admin, poster));
ignore cfg2(admin, Core.prepareSetActivationHeight(s2, admin, 0));
switch (Core.preparePost(s2, poster, thebesClock, simple(TODAY + 61, "2026-11", "1500", "2000", "EGP", 7))) {
  case (#ok(#event(e))) ignore MemLog.commit(c2, s2, thebesClock, poster, e);
  case (o) { Debug.print(debug_show (o)); assert false };
};
// back to the substrate clock: the roll answers to the clock again
ignore cfg2(admin, Core.prepareSetCalendarAuthority(s2, admin, #substrateClock, 0, null));
assert (cfgErr(Core.prepareRollBusinessDate(s2, admin, thebesClock, TODAY + 62)) == #BusinessDateInFuture({ requested = TODAY + 62; today = 0 }));
// the authority, the bound and the date are in the fold: a replay from the blocks reaches the same fingerprint
let r2 = Core.replay(admin, MemLog.blocks(c2));
assert (Core.fingerprint(r2) == Core.fingerprint(s2) and Core.calendarAuthority(r2) == Core.calendarAuthority(s2));
Debug.print("count: calendar-authority checks = 17");
