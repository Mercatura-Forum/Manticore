// IdempotencyDrop.test.mo; the idempotency keys of a packed range dropped, in chunks, while the
// journal keeps refusing duplicates.
//
// What is proved: after the drop, a key of a posting at or below the boundary no longer refuses
// (the bank's dedup window has passed; a resubmission is a new posting), a key of a posting above
// it still refuses with the original index, a key of a pending still **open** at the boundary
// still refuses whatever its index, and keys registered while the rebuild ran are kept; a drop
// through a boundary already dropped is a no-op; the count after the drop is the number of kept
// keys.
//
// engine: wasi-only; Regions.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";
import List "mo:core/List";
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
func cfg(r : { #ok : T.Event; #err : T.ConfigError }) { switch (r) { case (#ok(e)) ignore MemLog.commit(chain, s, clock, admin, e); case (#err(e)) { Debug.print(debug_show (e)); assert false } } };
cfg(Core.prepareRegisterCurrency(s, admin, "EGP", 2));
cfg(Core.prepareOpenAccount(s, admin, "1500", "Cash", #debit, #asset, #none));
cfg(Core.prepareOpenAccount(s, admin, "5000", "Revenue", #credit, #income, #none));
cfg(Core.prepareOpenPeriod(s, admin, "2026-09", SEP1, SEP30));
cfg(Core.prepareAddPoster(s, admin, poster));
cfg(Core.prepareRollBusinessDate(s, admin, clock, TODAY));
cfg(Core.prepareSetActivationHeight(s, admin, 0));

var keyCounter = 0;
func key() : Blob { keyCounter += 1; Blob.fromArray([Nat8.fromNat(keyCounter / 256), Nat8.fromNat(keyCounter % 256)]) };
func input(k : Blob) : T.PostingInput {
  { idempotencyKey = k; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; legs = [{ account = "1500"; subledger = null; side = #debit; currency = "EGP"; amount = 100 }, { account = "5000"; subledger = null; side = #credit; currency = "EGP"; amount = 100 }]; sourceRef = { kind = "test"; id = "t" }; narration = "n"; correctionOf = null }
};
func post(i : T.PostingInput) : Nat {
  switch (Core.preparePost(s, poster, clock, i)) { case (#ok(#event(e))) MemLog.commit(chain, s, clock, poster, e).index; case (other) { Debug.print(debug_show (other)); assert false; 0 } }
};
func reserve(i : T.PostingInput) : Nat {
  switch (Core.prepareReserve(s, poster, clock, i, null)) { case (#ok(#event(e))) MemLog.commit(chain, s, clock, poster, e).index; case (other) { Debug.print(debug_show (other)); assert false; 0 } }
};
/// A resubmission with the same key and a changed narration: refused with the original index, or
/// accepted as a new posting when the key is gone.
func refusedWith(i : T.PostingInput) : ?Nat {
  switch (Core.preparePost(s, poster, clock, { i with narration = "changed" })) { case (#err(#IdempotencyKeyReused(x))) ?x.existing; case (#ok(#event(_))) null; case (other) { Debug.print(debug_show (other)); assert false; null } }
};

// 300 submissions, every tenth a pending; the pendings of the first half resolve, the rest stay
// open across the drop; the boundary falls after the 200th submission
type Sub = { input : T.PostingInput; index : Nat; pending : Bool; resolved : Bool };
let subs = List.empty<Sub>();
var n = 0;
while (n < 300) {
  let i = input(key());
  if (n % 10 == 0) List.add(subs, { input = i; index = reserve(i); pending = true; resolved = false })
  else List.add(subs, { input = i; index = post(i); pending = false; resolved = false });
  n += 1;
};
var resolved = 0;
n := 0;
while (n < 150) {
  switch (List.get(subs, n)) {
    case (?x) { if (x.pending) { switch (Core.preparePostPending(s, MemLog.reader(chain), poster, clock, x.index, null)) { case (#ok(#event(e))) { ignore MemLog.commit(chain, s, clock, poster, e); List.put(subs, n, { x with resolved = true }); resolved += 1 }; case (other) { Debug.print(debug_show (other)); assert false } } } };
    case null {};
  };
  n += 1;
};
let ?boundarySub = List.get(subs, 199) else { assert false; loop {} };
let hi = boundarySub.index;
let before = Core.idempotencyCount(s);
Debug.print("count: keys before the drop = " # Nat.toText(before));
Debug.print("count: pendings resolved before the drop = " # Nat.toText(resolved));
// every key refuses before the drop
var refusing = 0;
for (x in List.values(subs)) { switch (refusedWith(x.input)) { case (?e) { assert (e == x.index); refusing += 1 }; case null { Debug.print("a key did not refuse before the drop"); assert false } } };
Debug.print("count: keys refusing a duplicate before the drop = " # Nat.toText(refusing));

// the drop, in uneven chunks, with new keys registered between chunks
assert (Core.beginIdempotencyRebuild(s, hi));
assert (not Core.beginIdempotencyRebuild(s, hi));
let during = List.empty<Sub>();
var chunks = 0;
label run loop {
  let st = Core.stepIdempotencyRebuild(s, 7 + chunks * 13);
  chunks += 1;
  let i = input(key());
  List.add(during, { input = i; index = post(i); pending = false; resolved = false });
  if (st.done) break run;
};
let ?outcome = Core.finishIdempotencyRebuild(s) else { assert false; loop {} };
Debug.print("count: rebuild chunks = " # Nat.toText(chunks));
Debug.print("count: keys dropped = " # Nat.toText(outcome.dropped));
Debug.print("count: keys kept = " # Nat.toText(outcome.copied));
assert (Core.idempotencyDroppedThrough(s) == hi);
assert (Core.idempotencyCount(s) >= outcome.copied);

// the oracle: a key is kept exactly when its posting is above the boundary or is a pending still open
var expectedKept = 0; var gone = 0; var openKept = 0; var aboveKept = 0;
for (x in List.values(subs)) {
  let keep = x.index > hi or (x.pending and not x.resolved);
  switch (refusedWith(x.input)) {
    case (?e) { assert (keep); assert (e == x.index); if (x.index > hi) aboveKept += 1 else openKept += 1 };
    case null { assert (not keep); gone += 1 };
  };
  if (keep) expectedKept += 1;
};
for (x in List.values(during)) { switch (refusedWith(x.input)) { case (?e) assert (e == x.index); case null { Debug.print("a key registered during the rebuild is gone"); assert false } } };
Debug.print("count: keys at or below the boundary that no longer refuse = " # Nat.toText(gone));
Debug.print("count: keys above the boundary still refusing = " # Nat.toText(aboveKept));
Debug.print("count: keys of open pendings at or below the boundary still refusing = " # Nat.toText(openKept));
Debug.print("count: keys registered during the rebuild still refusing = " # Nat.toText(List.size(during)));
// the count is the kept keys plus those registered during the rebuild; and the `refusedWith`
// calls above that were accepted registered nothing (a prepare writes no state)
assert (Core.idempotencyCount(s) == expectedKept + List.size(during));
Debug.print("count: keys after the drop = " # Nat.toText(Core.idempotencyCount(s)));
// a drop through a boundary already dropped is a no-op
let countNow = Core.idempotencyCount(s);
Core.dropIdempotencyThrough(s, hi - 5);
assert (Core.idempotencyCount(s) == countNow);
Debug.print("count: no-op drops = 1");
