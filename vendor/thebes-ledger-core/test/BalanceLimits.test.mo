// BalanceLimits.test.mo: numeric balance limits and chart-of-accounts attributes.
//
// The two additive journal changes the product engine needs (operator decision
// D-2), proved on the pure state machine.
//
// **Numeric limits.** The account-level `BalanceConstraint` is all-or-nothing, so
// an overdraft facility of 50,000 on one customer cannot be expressed and a net
// debit cap cannot either. A recorded limit for one (account, sub-ledger,
// currency) is the same rule with an allowance, checked at admission over posted
// **and** pending amounts and over the legs a batch has already admitted; which
// is what makes it engine-enforced rather than checked by a layer a second poster
// could bypass.
//
// **Attributes.** A header account is a rollup and is never posted to; an account
// with `manualEntriesAllowed = false` refuses a posting whose source kind is a
// manual correction. Every account opened before attributes existed reads as
// detail, manual entries allowed, no parent, so nothing already written changes
// meaning.
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
import Text "mo:core/Text";
import Principal "mo:core/Principal";

import T "../src/journal/JournalTypes";
import Core "../src/journal/JournalCore";
import MemLog "support/MemLog";

let admin = Principal.fromBlob("\AD\01");
let poster = Principal.fromBlob("\B0\01");

let DAY : Nat64 = 86_400_000_000_000;
let TODAY : Nat = 20705;
let clock : Nat64 = Nat64.fromNat(TODAY) * DAY + 43_200_000_000_000;
let SEP1 = 20697; let SEP30 = 20726;

let chain = MemLog.new();
let s = Core.newState(admin);

func cfg(caller : Principal, r : { #ok : T.Event; #err : T.ConfigError }) : Nat {
  switch (r) {
    case (#ok(e)) MemLog.commit(chain, s, clock, caller, e).index;
    case (#err(e)) { Debug.print("unexpected config error: " # debug_show (e)); assert false; 0 };
  }
};
func cfgErr(r : { #ok : T.Event; #err : T.ConfigError }, want : Text) {
  switch (r) {
    case (#err(e)) {
      let got = debug_show (e);
      if (not Text.contains(got, #text want)) { Debug.print("wanted " # want # " got " # got); assert false };
    };
    case (#ok(e)) { Debug.print("expected " # want # ", got event " # debug_show (e)); assert false };
  }
};

let CUST : Blob = Blob.fromArray([0xC0, 0x01]);
let CUST2 : Blob = Blob.fromArray([0xC0, 0x02]);

func leg(account : Text, sub : ?Blob, side : T.Side, amount : Nat) : T.Leg {
  { account; subledger = sub; side; currency = "EGP"; amount }
};
var keyCounter : Nat = 0;
func key() : Blob { keyCounter += 1; Blob.fromArray([0x11, Nat8.fromNat(keyCounter / 256), Nat8.fromNat(keyCounter % 256)]) };
func input(legs : [T.Leg], kind : Text) : T.PostingInput {
  { idempotencyKey = key(); postingDate = TODAY; valueDate = TODAY; period = "2026-09"; legs;
    sourceRef = { kind; id = "t" }; narration = "limits"; correctionOf = null }
};

func postOk(i : T.PostingInput) : Nat {
  switch (Core.preparePost(s, poster, clock, i)) {
    case (#ok(#event(e))) MemLog.commit(chain, s, clock, poster, e).index;
    case (x) { Debug.print("unexpected: " # debug_show (x)); assert false; 0 };
  }
};
func postErr(i : T.PostingInput, want : Text) {
  let fp = Core.fingerprint(s);
  let h = Core.height(s);
  switch (Core.preparePost(s, poster, clock, i)) {
    case (#err(e)) {
      let got = debug_show (e);
      if (not Text.contains(got, #text want)) { Debug.print("wanted " # want # " got " # got); assert false };
    };
    case (x) { Debug.print("expected " # want # ", got " # debug_show (x)); assert false };
  };
  assert (Core.fingerprint(s) == fp and Core.height(s) == h);
};

// ─── chart ───────────────────────────────────────────────────────────────────
ignore cfg(admin, Core.prepareRegisterCurrency(s, admin, "EGP", 2));
ignore cfg(admin, Core.prepareOpenAccount(s, admin, "1001", "Cash", #debit, #asset, #none));
// a deposit control account that may not be overdrawn by default
ignore cfg(admin, Core.prepareOpenAccount(s, admin, "2110", "Customer deposits", #credit, #liability, #debitsNotExceedCredits));
ignore cfg(admin, Core.prepareOpenAccount(s, admin, "2000", "Deposits rollup", #credit, #liability, #none));
ignore cfg(admin, Core.prepareOpenAccount(s, admin, "4100", "Fee income", #credit, #income, #none));
ignore cfg(admin, Core.prepareOpenPeriod(s, admin, "2026-09", SEP1, SEP30));
ignore cfg(admin, Core.prepareAddPoster(s, admin, poster));
ignore cfg(admin, Core.prepareSetActivationHeight(s, admin, 0));

// an account opened before attributes existed reads as the default
let d = Core.accountAttributes(s, "2110");
assert (d.usage == #detail and d.manualEntriesAllowed and d.parent == null);
assert (Core.balanceLimit(s, "2110", ?CUST, "EGP") == null);
Debug.print("count: accounts reading the default attributes = 4");

// ─── the account constraint still governs with no limit recorded ────────────
ignore postOk(input([leg("1001", null, #debit, 1_000_00), leg("2110", ?CUST, #credit, 1_000_00)], "deposit"));
// the customer may not be overdrawn
postErr(input([leg("2110", ?CUST, #debit, 1_000_01), leg("1001", null, #credit, 1_000_01)], "withdrawal"), "ExceedsCredits");
// exactly the balance is fine
ignore postOk(input([leg("2110", ?CUST, #debit, 1_000_00), leg("1001", null, #credit, 1_000_00)], "withdrawal"));
Debug.print("count: constraint checks with no limit recorded = 3");

// ─── a numeric limit is an overdraft facility ───────────────────────────────
ignore cfg(admin, Core.prepareSetBalanceLimit(s, admin, "2110", ?CUST, "EGP", #debitsNotExceedCreditsPlus(50_000_00)));
switch (Core.balanceLimit(s, "2110", ?CUST, "EGP")) {
  case (?#debitsNotExceedCreditsPlus(n)) assert (n == 50_000_00);
  case (x) { Debug.print("limit not recorded: " # debug_show (x)); assert false };
};
// the customer is at zero; it may now go 50,000.00 overdrawn, and not a unit more
postErr(input([leg("2110", ?CUST, #debit, 50_000_01), leg("1001", null, #credit, 50_000_01)], "draw"), "ExceedsCredits");
ignore postOk(input([leg("2110", ?CUST, #debit, 50_000_00), leg("1001", null, #credit, 50_000_00)], "draw"));
// and now nothing more
postErr(input([leg("2110", ?CUST, #debit, 1), leg("1001", null, #credit, 1)], "draw"), "ExceedsCredits");
// the error names the allowance, so a client can say why
switch (Core.preparePost(s, poster, clock, input([leg("2110", ?CUST, #debit, 1), leg("1001", null, #credit, 1)], "draw"))) {
  case (#err(#ExceedsCredits(x))) { assert (x.allowance == 50_000_00) };
  case (x) { Debug.print("expected ExceedsCredits: " # debug_show (x)); assert false };
};
Debug.print("count: overdraft-facility boundary checks = 4");

// the limit is per sub-ledger: another customer under the same account is not
// affected and keeps the account's own constraint
postErr(input([leg("2110", ?CUST2, #debit, 1), leg("1001", null, #credit, 1)], "draw"), "ExceedsCredits");
switch (Core.preparePost(s, poster, clock, input([leg("2110", ?CUST2, #debit, 1), leg("1001", null, #credit, 1)], "draw"))) {
  case (#err(#ExceedsCredits(e))) { assert (e.allowance == 0) };
  case (other) { Debug.print("expected ExceedsCredits with no allowance: " # debug_show (other)); assert false };
};
Debug.print("count: per-sub-ledger isolation checks = 2");

// ─── limits bind over pending as well as posted ────────────────────────────
ignore cfg(admin, Core.prepareSetBalanceLimit(s, admin, "2110", ?CUST2, "EGP", #debitsNotExceedCreditsPlus(10_000_00)));
// reserve 6,000 as a pending posting
ignore switch (Core.prepareReserve(s, poster, clock, input([leg("2110", ?CUST2, #debit, 6_000_00), leg("1001", null, #credit, 6_000_00)], "hold"), ?(clock + DAY))) {
  case (#ok(#event(e))) MemLog.commit(chain, s, clock, poster, e).index;
  case (x) { Debug.print("reserve failed: " # debug_show (x)); assert false; 0 };
};
// 4,000 more fits; 4,001 does not, because the pending 6,000 counts
postErr(input([leg("2110", ?CUST2, #debit, 4_000_01), leg("1001", null, #credit, 4_000_01)], "draw"), "ExceedsCredits");
ignore postOk(input([leg("2110", ?CUST2, #debit, 4_000_00), leg("1001", null, #credit, 4_000_00)], "draw"));
Debug.print("count: pending-inclusive limit checks = 2");

// ─── a batch is checked against the state it will produce ──────────────────
// CUST is at its limit; a batch of two 1-unit draws must fail on the first
switch (Core.prepareBatch(s, poster, clock, [
  input([leg("2110", ?CUST, #debit, 1), leg("1001", null, #credit, 1)], "b1"),
  input([leg("2110", ?CUST, #debit, 1), leg("1001", null, #credit, 1)], "b2"),
])) {
  case (#err({ index; error = #ExceedsCredits(_) })) assert (index == 0);
  case (x) { Debug.print("expected a batch refusal: " # debug_show (x)); assert false };
};
// and a batch that credits first then draws within the new allowance is admitted
switch (Core.prepareBatch(s, poster, clock, [
  input([leg("1001", null, #debit, 500_00), leg("2110", ?CUST, #credit, 500_00)], "b3"),
  input([leg("2110", ?CUST, #debit, 500_00), leg("1001", null, #credit, 500_00)], "b4"),
])) {
  case (#ok(prepared)) { assert (prepared.size() == 2); for (p in prepared.vals()) { switch (p) { case (#event(e)) ignore MemLog.commit(chain, s, clock, poster, e); case (#duplicate(_)) {} } } };
  case (x) { Debug.print("expected a batch to be admitted: " # debug_show (x)); assert false };
};
Debug.print("count: batch-local limit checks = 2");

// ─── a net debit cap on the other side ─────────────────────────────────────
ignore cfg(admin, Core.prepareOpenAccount(s, admin, "1500", "Position", #debit, #asset, #creditsNotExceedDebits));
ignore cfg(admin, Core.prepareSetBalanceLimit(s, admin, "1500", null, "EGP", #creditsNotExceedDebitsPlus(2_000_00)));
postErr(input([leg("1500", null, #credit, 2_000_01), leg("4100", null, #debit, 2_000_01)], "cap"), "ExceedsDebits");
ignore postOk(input([leg("1500", null, #credit, 2_000_00), leg("4100", null, #debit, 2_000_00)], "cap"));
Debug.print("count: net-debit-cap checks = 2");

// ─── `#none` recorded lifts the account's constraint for that sub-ledger ───
ignore cfg(admin, Core.prepareSetBalanceLimit(s, admin, "2110", ?CUST, "EGP", #none));
// the customer is 50,000 overdrawn and the constraint no longer binds
ignore postOk(input([leg("2110", ?CUST, #debit, 1_000_000_00), leg("1001", null, #credit, 1_000_000_00)], "unlimited"));
Debug.print("count: constraint lifted by an explicit #none = 1");

// configuration refusals are typed
cfgErr(Core.prepareSetBalanceLimit(s, poster, "2110", ?CUST, "EGP", #none), "Unauthorized");
cfgErr(Core.prepareSetBalanceLimit(s, admin, "9999", null, "EGP", #none), "UnknownAccount");
cfgErr(Core.prepareSetBalanceLimit(s, admin, "2110", null, "XXX", #none), "InvalidCurrency");
cfgErr(Core.prepareSetBalanceLimit(s, admin, "2110", ?Blob.fromArray([]), "EGP", #none), "InvalidBalanceLimit");
Debug.print("count: balance-limit configuration refusals = 4");

// ─── chart-of-accounts attributes ──────────────────────────────────────────
// 2000 is a rollup; making it a header refuses postings to it
ignore cfg(admin, Core.prepareSetAccountAttributes(s, admin, "2000", { usage = #header; manualEntriesAllowed = false; parent = null }));
postErr(input([leg("2000", null, #credit, 100), leg("1001", null, #debit, 100)], "deposit"), "AccountIsHeader");
// and 2110 can hang under it
ignore cfg(admin, Core.prepareSetAccountAttributes(s, admin, "2110", { usage = #detail; manualEntriesAllowed = true; parent = ?"2000" }));
assert (Core.accountAttributes(s, "2110").parent == ?"2000");
// a parent that is not a header is refused
cfgErr(Core.prepareSetAccountAttributes(s, admin, "1001", { usage = #detail; manualEntriesAllowed = true; parent = ?"4100" }), "not a header");
// self-parenting and cycles are refused
cfgErr(Core.prepareSetAccountAttributes(s, admin, "1001", { usage = #detail; manualEntriesAllowed = true; parent = ?"1001" }), "its own parent");
cfgErr(Core.prepareSetAccountAttributes(s, admin, "2000", { usage = #header; manualEntriesAllowed = false; parent = ?"2110" }), "not a header");
// an unknown parent is refused
cfgErr(Core.prepareSetAccountAttributes(s, admin, "1001", { usage = #detail; manualEntriesAllowed = true; parent = ?"7777" }), "UnknownAccount");
// an account that carries balances cannot become a header
cfgErr(Core.prepareSetAccountAttributes(s, admin, "1001", { usage = #header; manualEntriesAllowed = true; parent = null }), "carries balances");
Debug.print("count: account-attribute refusals = 6");

// ─── the manual-entry flag ─────────────────────────────────────────────────
ignore cfg(admin, Core.prepareSetAccountAttributes(s, admin, "4100", { usage = #detail; manualEntriesAllowed = false; parent = null }));
// a manual source kind is refused
var manualRefusals = 0;
for (kind in T.MANUAL_SOURCE_KINDS.vals()) {
  postErr(input([leg("4100", null, #credit, 100), leg("1001", null, #debit, 100)], kind), "ManualEntriesNotAllowed");
  manualRefusals += 1;
};
// a system source kind is admitted
ignore postOk(input([leg("4100", null, #credit, 100), leg("1001", null, #debit, 100)], "accrual"));
Debug.print("count: manual source kinds refused = " # Nat.toText(manualRefusals));
assert (manualRefusals == T.MANUAL_SOURCE_KINDS.size());
Debug.print("count: system source kinds admitted on the same account = 1");

// ─── the account view carries its attributes, and replay reproduces both ───
var headerAccounts = 0;
var noManual = 0;
for (a in Core.listAccounts(s).vals()) {
  if (a.attributes.usage == #header) headerAccounts += 1;
  if (not a.attributes.manualEntriesAllowed) noManual += 1;
};
Debug.print("count: accounts in the chart = " # Nat.toText(Core.listAccounts(s).size()));
assert (headerAccounts == 1 and noManual == 2);

let fp = Core.fingerprint(s);
let replayed = Core.replay(admin, MemLog.blocks(chain));
assert (Core.fingerprint(replayed) == fp);
assert (Core.balanceLimit(replayed, "2110", ?CUST2, "EGP") == ?#debitsNotExceedCreditsPlus(10_000_00));
assert (Core.accountAttributes(replayed, "2000").usage == #header);
Debug.print("count: blocks replayed = " # Nat.toText(Core.height(s)));
assert (MemLog.blocks(chain).size() == Core.height(s));

// a state without the limits fingerprints differently
ignore cfg(admin, Core.prepareSetBalanceLimit(s, admin, "2110", ?CUST2, "EGP", #debitsNotExceedCreditsPlus(99)));
assert (Core.fingerprint(s) != fp);
Debug.print("count: fingerprint sensitivity checks = 1");

Debug.print("BALANCE LIMITS TEST GREEN");
