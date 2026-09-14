// PosterScope.test.mo: account-scoped posters (proposal entitlements and maker-checker section 1.5).
//
// The journal's poster set was a flat list: any poster could post to any
// account. A recorded scope turns "only this principal posts to these control
// accounts" into an engine rule, which is what makes book-scoped closure and
// the bank's sole-poster property enforceable rather than conventional.
//
// Proved here: an unrestricted poster is unaffected; a scoped poster is refused
// on every admission path (post, batch, reserve, post-pending, void-pending,
// reverse) when any leg names an account outside its scope and admitted when
// every leg is inside it; the refusal changes nothing; the scope is part of the
// state fingerprint and survives replay; and every configuration error is typed.
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
import MemLog "support/MemLog";

let admin = Principal.fromBlob("\AD\01");
let bank = Principal.fromBlob("\B0\01");       // scoped to the product accounts
let other = Principal.fromBlob("\B0\02");      // left unrestricted
let outsider = Principal.fromBlob("\0F\0F");

let DAY : Nat64 = 86_400_000_000_000;
let TODAY : Nat = 20705;
let clock : Nat64 = Nat64.fromNat(TODAY) * DAY + 43_200_000_000_000;
let SEP1 = 20697; let SEP30 = 20726;

let chain = MemLog.new();
let s = Core.newState(admin);

func cfg(caller : Principal, r : { #ok : T.Event; #err : T.ConfigError }) : Nat {
  switch (r) {
    case (#ok(e)) MemLog.commit(chain, s, clock, caller, e).index;
    case (#err(e)) { Debug.print("unexpected config error: " # debug_show(e)); assert false; 0 };
  }
};
func cfgErr(r : { #ok : T.Event; #err : T.ConfigError }) : T.ConfigError {
  switch (r) { case (#err(e)) e; case (#ok(e)) { Debug.print("expected config error, got " # debug_show(e)); assert false; #Unauthorized } }
};

func leg(account : Text, side : T.Side, amount : Nat) : T.Leg { { account; subledger = null; side; currency = "EGP"; amount } };
var keyCounter : Nat = 0;
func key() : Blob { keyCounter += 1; Blob.fromArray([0x5C, Nat8.fromNat(keyCounter / 256), Nat8.fromNat(keyCounter % 256)]) };
func input(legs : [T.Leg]) : T.PostingInput {
  { idempotencyKey = key(); postingDate = TODAY; valueDate = TODAY; period = "2026-09"; legs; sourceRef = { kind = "scope"; id = "t" }; narration = "scope test"; correctionOf = null }
};

// ─── chart: two product control accounts, one treasury account ───────────────
ignore cfg(admin, Core.prepareRegisterCurrency(s, admin, "EGP", 2));
for ((code, name, side, cat) in [
  ("1001", "Cash", #debit, #asset),
  ("2110", "Customer deposits", #credit, #liability),
  ("2111", "Customer deposits, term", #credit, #liability),
  ("4100", "Interest expense", #debit, #expense),
  ("9100", "Treasury suspense", #debit, #asset),
].vals()) {
  ignore cfg(admin, Core.prepareOpenAccount(s, admin, code, name, side, cat, #none));
};
ignore cfg(admin, Core.prepareOpenPeriod(s, admin, "2026-09", SEP1, SEP30));
ignore cfg(admin, Core.prepareAddPoster(s, admin, bank));
ignore cfg(admin, Core.prepareAddPoster(s, admin, other));
ignore cfg(admin, Core.prepareSetActivationHeight(s, admin, 0));
assert (Core.isActive(s));

// ─── 1. before any scope is set, both posters reach every account ────────────
var unrestrictedAdmitted = 0;
for (p in [bank, other].vals()) {
  for ((dr, cr) in [("1001", "2110"), ("1001", "2111"), ("9100", "2110"), ("4100", "2110")].vals()) {
    switch (Core.preparePost(s, p, clock, input([leg(dr, #debit, 1_00), leg(cr, #credit, 1_00)]))) {
      case (#ok(#event(e))) { ignore MemLog.commit(chain, s, clock, p, e); unrestrictedAdmitted += 1 };
      case (x) { Debug.print("unrestricted poster refused: " # debug_show(x)); assert false };
    };
  };
};
Debug.print("count: postings admitted with no scope recorded = " # Nat.toText(unrestrictedAdmitted));
assert (unrestrictedAdmitted == 8);
assert (Core.posterScope(s, bank) == null and Core.posterScope(s, other) == null);

// ─── 2. configuration errors are typed ──────────────────────────────────────
var configRefusals = 0;
func expectCfg(r : { #ok : T.Event; #err : T.ConfigError }, want : T.ConfigError) {
  let got = cfgErr(r);
  if (got != want) { Debug.print("wanted " # debug_show(want) # " got " # debug_show(got)); assert false };
  configRefusals += 1;
};
expectCfg(Core.prepareSetPosterScope(s, outsider, bank, ?["2110"]), #Unauthorized);
expectCfg(Core.prepareSetPosterScope(s, admin, outsider, ?["2110"]), #UnknownPoster({ poster = outsider }));
expectCfg(Core.prepareSetPosterScope(s, admin, bank, ?[]), #InvalidPosterScope({ reason = "an empty scope would refuse every posting; pass null to unrestrict" }));
expectCfg(Core.prepareSetPosterScope(s, admin, bank, ?["2110", "2110"]), #InvalidPosterScope({ reason = "duplicate account 2110" }));
expectCfg(Core.prepareSetPosterScope(s, admin, bank, ?["2110", "7777"]), #InvalidPosterScope({ reason = "unknown account 7777" }));
expectCfg(Core.prepareSetPosterScope(s, admin, bank, null), #InvalidPosterScope({ reason = "poster is already unrestricted" }));
// over the bound
let tooMany = Array.tabulate<Text>(T.MAX_POSTER_SCOPE_ACCOUNTS + 1, func(i) { Nat.toText(1000 + i) });
expectCfg(Core.prepareSetPosterScope(s, admin, bank, ?tooMany), #InvalidPosterScope({ reason = "scope exceeds 256 accounts" }));
Debug.print("count: scope configuration refusals typed = " # Nat.toText(configRefusals));
assert (configRefusals == 7);

// ─── 3. set the scope; it is recorded as a block ────────────────────────────
let heightBefore = Core.height(s);
let scopeBlock = cfg(admin, Core.prepareSetPosterScope(s, admin, bank, ?["1001", "2110", "2111", "4100"]));
assert (Core.height(s) == heightBefore + 1);
switch (Core.posterScope(s, bank)) {
  case (?sc) { assert (sc.size() == 4) };
  case null { Debug.print("scope not recorded"); assert false };
};
assert (Core.posterScope(s, other) == null);
Debug.print("scope recorded at block " # Nat.toText(scopeBlock));

// ─── 4. every admission path is refused outside the scope ───────────────────
func refusedOutside(f : () -> { #ok : Core.Prepared; #err : T.PostError }, account : Text) {
  let fp = Core.fingerprint(s);
  let h = Core.height(s);
  switch (f()) {
    case (#err(#PosterNotScopedForAccount(d))) {
      assert (Principal.equal(d.poster, bank) and d.account == account);
    };
    case (x) { Debug.print("expected PosterNotScopedForAccount, got " # debug_show(x)); assert false };
  };
  // a refusal touches nothing
  assert (Core.fingerprint(s) == fp and Core.height(s) == h);
};

var pathRefusals = 0;
// post: the out-of-scope account on either side, in either leg position
refusedOutside(func() = Core.preparePost(s, bank, clock, input([leg("9100", #debit, 5_00), leg("2110", #credit, 5_00)])), "9100");
pathRefusals += 1;
refusedOutside(func() = Core.preparePost(s, bank, clock, input([leg("1001", #debit, 5_00), leg("9100", #credit, 5_00)])), "9100");
pathRefusals += 1;
// reserve
refusedOutside(func() = Core.prepareReserve(s, bank, clock, input([leg("9100", #debit, 5_00), leg("2110", #credit, 5_00)]), null), "9100");
pathRefusals += 1;
// batch: the offending position is named
let fpB = Core.fingerprint(s);
switch (Core.prepareBatch(s, bank, clock, [
  input([leg("1001", #debit, 1_00), leg("2110", #credit, 1_00)]),
  input([leg("9100", #debit, 1_00), leg("2110", #credit, 1_00)]),
])) {
  case (#err({ index; error = #PosterNotScopedForAccount(d) })) { assert (index == 1 and d.account == "9100") };
  case (x) { Debug.print("expected batch refusal, got " # debug_show(x)); assert false };
};
assert (Core.fingerprint(s) == fpB);
pathRefusals += 1;
Debug.print("count: admission paths refused outside scope = " # Nat.toText(pathRefusals));
assert (pathRefusals == 4);

// ─── 5. inside the scope, the scoped poster works normally ──────────────────
var insideAdmitted = 0;
func postAs(p : Principal, i : T.PostingInput) : Nat {
  switch (Core.preparePost(s, p, clock, i)) {
    case (#ok(#event(e))) { insideAdmitted += 1; MemLog.commit(chain, s, clock, p, e).index };
    case (x) { Debug.print("unexpected: " # debug_show(x)); assert false; 0 };
  }
};
ignore postAs(bank, input([leg("1001", #debit, 7_00), leg("2110", #credit, 7_00)]));
ignore postAs(bank, input([leg("4100", #debit, 3_00), leg("2111", #credit, 3_00)]));
Debug.print("count: postings admitted inside scope = " # Nat.toText(insideAdmitted));
assert (insideAdmitted == 2);

// the unrestricted poster still reaches the account the bank may not
ignore postAs(other, input([leg("9100", #debit, 2_00), leg("2110", #credit, 2_00)]));
assert (insideAdmitted == 3);

// ─── 6. the pending paths check the pending's own legs, not the caller's ────
// `other` reserves a posting that touches 9100; the scoped bank may not resolve it.
let pendingIdx = switch (Core.prepareReserve(s, other, clock, input([leg("9100", #debit, 4_00), leg("2110", #credit, 4_00)]), ?(clock + DAY))) {
  case (#ok(#event(e))) MemLog.commit(chain, s, clock, other, e).index;
  case (x) { Debug.print("reserve failed: " # debug_show(x)); assert false; 0 };
};
var pendingRefusals = 0;
let fpP = Core.fingerprint(s);
switch (Core.preparePostPending(s, MemLog.reader(chain), bank, clock, pendingIdx, null)) {
  case (#err(#PosterNotScopedForAccount(d))) { assert (d.account == "9100"); pendingRefusals += 1 };
  case (x) { Debug.print("expected post-pending refusal, got " # debug_show(x)); assert false };
};
switch (Core.prepareVoidPending(s, MemLog.reader(chain), bank, pendingIdx)) {
  case (#err(#PosterNotScopedForAccount(d))) { assert (d.account == "9100"); pendingRefusals += 1 };
  case (x) { Debug.print("expected void-pending refusal, got " # debug_show(x)); assert false };
};
assert (Core.fingerprint(s) == fpP);
// the reserver resolves it itself
switch (Core.preparePostPending(s, MemLog.reader(chain), other, clock, pendingIdx, null)) {
  case (#ok(#event(e))) { ignore MemLog.commit(chain, s, clock, other, e) };
  case (x) { Debug.print("reserver could not post its own pending: " # debug_show(x)); assert false };
};
Debug.print("count: pending paths refused outside scope = " # Nat.toText(pendingRefusals));
assert (pendingRefusals == 2);

// ─── 7. reverse goes through the same check ─────────────────────────────────
// `other` posted a 9100 posting above; the bank cannot reverse it.
let otherPosting = switch (Core.preparePost(s, other, clock, input([leg("9100", #debit, 6_00), leg("2110", #credit, 6_00)]))) {
  case (#ok(#event(e))) MemLog.commit(chain, s, clock, other, e).index;
  case (x) { Debug.print("post failed: " # debug_show(x)); assert false; 0 };
};
let fpR = Core.fingerprint(s);
switch (Core.prepareReverse(s, MemLog.reader(chain), bank, clock, otherPosting, { idempotencyKey = key(); postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "reversal"; sourceRef = { kind = "scope"; id = "rev" } })) {
  case (#err(#PosterNotScopedForAccount(d))) { assert (d.account == "9100") };
  case (x) { Debug.print("expected reverse refusal, got " # debug_show(x)); assert false };
};
assert (Core.fingerprint(s) == fpR);
Debug.print("count: reverse refused outside scope = 1");

// ─── 8. clearing the scope restores the unrestricted behaviour ──────────────
ignore cfg(admin, Core.prepareSetPosterScope(s, admin, bank, null));
assert (Core.posterScope(s, bank) == null);
ignore postAs(bank, input([leg("9100", #debit, 8_00), leg("2110", #credit, 8_00)]));
Debug.print("count: postings admitted after clearing the scope = 1");

// ─── 9. the scope is in the fingerprint, and replay reproduces it ───────────
let fpWithout = Core.fingerprint(s);
ignore cfg(admin, Core.prepareSetPosterScope(s, admin, bank, ?["2110"]));
let fpWith = Core.fingerprint(s);
assert (fpWith != fpWithout);
let replayed = Core.replay(admin, MemLog.blocks(chain));
assert (Core.fingerprint(replayed) == fpWith);
assert (Core.posterScope(replayed, bank) == ?["2110"]);
assert (Core.listPosterScopes(replayed).size() == 1);
Debug.print("count: replayed blocks = " # Nat.toText(MemLog.blocks(chain).size()));
assert (MemLog.blocks(chain).size() == Core.height(s));

// a different scope fingerprints differently
let alt = Core.replay(admin, MemLog.blocks(chain));
assert (Core.fingerprint(alt) == fpWith);

Debug.print("POSTER SCOPE TEST GREEN");
