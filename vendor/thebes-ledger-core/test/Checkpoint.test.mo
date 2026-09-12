// Checkpoint.test.mo — the derived state written into its own log, and the fold that starts from it.
//
// What is proved, on a journal with pendings, resolutions, voids, a reversal, limits, scopes and
// two periods: the checkpoint parts round-trip through the canonical codec; a state restored from
// them, after the same blocks are applied to both, fingerprints equal to the live state whose
// archived rows were dropped (rows and correctors of the range gone, dated rows rolled up through
// the period's end, the pendings' keys kept); a fold of a log that carries the checkpoint series
// (`replayFrom`) equals the live state; the roll-up leaves every balance as of a later day exact;
// and the drops are chunked and resumable while postings land.
//
// engine: wasi-only — Regions.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Principal "mo:core/Principal";

import T "../src/journal/JournalTypes";
import Core "../src/journal/JournalCore";
import C "../src/journal/Canonical";
import MemLog "support/MemLog";

let admin = Principal.fromBlob("\AD\01");
let poster = Principal.fromBlob("\B0\01");
let DAY : Nat64 = 86_400_000_000_000;
let SEP1 = 20697; let SEP30 = 20726; let OCT1 = 20727; let OCT31 = 20757;
var today = SEP30;
func clock() : Nat64 { Nat64.fromNat(today) * DAY + 43_200_000_000_000 };

let chain = MemLog.new();
let s = Core.newState(admin);
func cfg(r : { #ok : T.Event; #err : T.ConfigError }) { switch (r) { case (#ok(e)) ignore MemLog.commit(chain, s, clock(), admin, e); case (#err(e)) { Debug.print(debug_show (e)); assert false } } };
cfg(Core.prepareRegisterCurrency(s, admin, "EGP", 2));
cfg(Core.prepareRegisterCurrency(s, admin, "USD", 2));
for ((code, name, side, cat) in [("1500", "Cash", #debit, #asset), ("1400", "Receivables", #debit, #asset), ("2100", "Deposits", #credit, #liability), ("5000", "Revenue", #credit, #income), ("6000", "Costs", #debit, #expense)].vals()) {
  cfg(Core.prepareOpenAccount(s, admin, code, name, side, cat, #none));
};
cfg(Core.prepareOpenPeriod(s, admin, "2026-09", SEP1, SEP30));
cfg(Core.prepareOpenPeriod(s, admin, "2026-10", OCT1, OCT31));
cfg(Core.prepareAddPoster(s, admin, poster));
cfg(Core.prepareSetActivationHeight(s, admin, 0));
cfg(Core.prepareRollBusinessDate(s, admin, clock(), today));
cfg(Core.prepareSetBalanceLimit(s, admin, "2100", ?("\01\02" : Blob), "EGP", #creditsNotExceedDebitsPlus(1_000_000_000)));
cfg(Core.prepareSetAccountAttributes(s, admin, "1400", { usage = #detail; manualEntriesAllowed = false; parent = null }));

var keyCounter = 0;
func key() : Blob { keyCounter += 1; Blob.fromArray([Nat8.fromNat(keyCounter / 256), Nat8.fromNat(keyCounter % 256)]) };
func sub(i : Nat) : Blob { Blob.fromArray([Nat8.fromNat(i / 256), Nat8.fromNat(i % 256)]) };
func input(day : Nat, period : Text, dr : Text, cr : Text, drSub : ?Blob, crSub : ?Blob, amount : Nat) : T.PostingInput {
  { idempotencyKey = key(); postingDate = day; valueDate = day; period; legs = [{ account = dr; subledger = drSub; side = #debit; currency = "EGP"; amount }, { account = cr; subledger = crSub; side = #credit; currency = "EGP"; amount }]; sourceRef = { kind = "test"; id = "t" }; narration = "n"; correctionOf = null }
};
func post(i : T.PostingInput) : Nat {
  switch (Core.preparePost(s, poster, clock(), i)) { case (#ok(#event(e))) MemLog.commit(chain, s, clock(), poster, e).index; case (other) { Debug.print(debug_show (other)); assert false; 0 } }
};
func reserve(i : T.PostingInput) : Nat {
  switch (Core.prepareReserve(s, poster, clock(), i, null)) { case (#ok(#event(e))) MemLog.commit(chain, s, clock(), poster, e).index; case (other) { Debug.print(debug_show (other)); assert false; 0 } }
};
func resolve(idx : Nat) { switch (Core.preparePostPending(s, MemLog.reader(chain), poster, clock(), idx, null)) { case (#ok(#event(e))) ignore MemLog.commit(chain, s, clock(), poster, e); case (other) { Debug.print(debug_show (other)); assert false } } };
func void(idx : Nat) { switch (Core.prepareVoidPending(s, MemLog.reader(chain), poster, idx)) { case (#ok(e)) ignore MemLog.commit(chain, s, clock(), poster, e); case (#err(e)) { Debug.print(debug_show (e)); assert false } } };

// September: 400 postings across 30 sub-ledgers, pendings resolved and voided, one reversal
var n = 0;
let pend = List.empty<Nat>();
var firstPosting = 0;
var secondPosting = 0;
while (n < 400) {
  let a = n % 30; let b = (n * 7 + 3) % 30;
  let i = input(SEP1 + n % 30, "2026-09", if (n % 4 == 0) "1500" else "2100", "2100", if (n % 4 == 0) null else ?sub(a), ?sub(b), 1_000 + n * 13);
  if (n % 11 == 0) List.add(pend, reserve(i)) else { let ix = post(i); if (n == 1) firstPosting := ix; if (n == 2) secondPosting := ix };
  n += 1;
};
var k = 0;
for (p in List.values(pend)) { if (k % 3 == 0) void(p) else resolve(p); k += 1 };
// a correction of an early posting, so the corrector index has rows to drop
ignore post({ input(SEP30, "2026-09", "2100", "2100", ?sub(2), ?sub(3), 77) with correctionOf = ?secondPosting });
// a reversal of an early posting
switch (Core.prepareReverse(s, MemLog.reader(chain), poster, clock(), firstPosting, { idempotencyKey = key(); postingDate = today; valueDate = today; period = "2026-09"; narration = "rev"; sourceRef = { kind = "test"; id = "r" } })) {
  case (#ok(#event(e))) ignore MemLog.commit(chain, s, clock(), poster, e);
  case (other) { Debug.print(debug_show (other)); assert false };
};
// October's first days, then the close of September; the boundary is the closing block
today := OCT1 + 2;
cfg(Core.prepareRollBusinessDate(s, admin, clock(), today));
n := 0;
while (n < 40) { ignore post(input(OCT1 + n % 3, "2026-10", "2100", "2100", ?sub(n % 30), ?sub((n + 5) % 30), 500 + n)); n += 1 };
cfg(Core.prepareClosePeriod(s, admin, "2026-09"));
let hi = Core.height(s) - 1;
let PERIOD_END = SEP30;
Debug.print("count: blocks through the boundary = " # Nat.toText(hi + 1));
assert (Core.oldestOpenPending(s) == null);

// ─── the checkpoint of the state at the boundary, round-tripped through the codec ───
let parts = List.empty<T.CheckpointPart>();
var cursor : Core.CheckpointCursor = #config;
var partCount = 0;
label ser loop {
  let r = Core.checkpointPart(s, cursor, PERIOD_END);
  // through the canonical block codec: a checkpoint block encodes and decodes to the same part
  let ev : T.Event = #checkpoint({ through = hi; seq = partCount; last = r.next == #done; part = r.part });
  let enc = C.encodeBlock(0, 0, admin, null, ev);
  switch (C.decodeBlock(enc.bytes)) {
    case (?blk) { switch (blk.event) { case (#checkpoint(c)) { assert (c.part == r.part and c.seq == partCount); List.add(parts, c.part) }; case (_) assert false } };
    case null { Debug.print("a checkpoint block does not decode"); assert false };
  };
  partCount += 1;
  cursor := r.next;
  if (cursor == #done) break ser;
};
Debug.print("count: checkpoint parts round-tripped through the codec = " # Nat.toText(partCount));
let restored = Core.restore(admin, hi, List.toArray(parts));
assert (Core.height(restored) == hi + 1);

// ─── the live state after the archive drop equals the restored one ───
// the drops, in chunks, with October postings landing between chunks
let fpBefore = Core.fingerprint(s);
var landed = 0;
var dropChunks = 0;
for (which in Core.DROPPABLES.vals()) {
  assert (Core.beginArchiveDrop(s, which, hi, PERIOD_END));
  assert (not Core.beginArchiveDrop(s, which, hi, PERIOD_END));
  label run loop {
    let st = Core.stepArchiveDrop(s, 37 + dropChunks * 5);
    dropChunks += 1;
    if (dropChunks % 3 == 0) { ignore post(input(OCT1 + 2, "2026-10", "2100", "2100", ?sub(landed % 30), ?sub((landed + 9) % 30), 700 + landed)); landed += 1 };
    if (st.done) break run;
  };
  let ?out = Core.finishArchiveDrop(s) else { assert false; loop {} };
  Debug.print("count: " # Core.droppableText(which) # " rows dropped = " # Nat.toText(out.dropped));
  assert (out.dropped > 0);
};
Core.dropIdempotencyThrough(s, hi);
assert (Core.datedRolledUpThrough(s) == PERIOD_END);
Debug.print("count: drop chunks = " # Nat.toText(dropChunks));
Debug.print("count: postings landed during the drops = " # Nat.toText(landed));
assert (Core.fingerprint(s) != fpBefore);
// the same blocks after the boundary applied to the restored state
var j = hi + 1;
let reader = MemLog.reader(chain);
while (j < Core.height(s)) { let ?b = reader.get(j) else { assert false; loop {} }; Core.apply(restored, reader, b); j += 1 };
Debug.print("count: blocks applied after the boundary = " # Nat.toText(Core.height(s) - hi - 1));
if (Core.fingerprint(s) != Core.fingerprint(restored)) { Debug.print("FAIL: the live state after the drop differs from the checkpoint fold"); assert false };
Debug.print("count: live and checkpoint-folded fingerprints equal = 1");

// ─── balances as of days after the roll-up are exact: compare against a fresh full fold ───
let full = Core.replay(admin, MemLog.blocks(chain));
var asOfChecks = 0;
for (day in [OCT1, OCT1 + 1, OCT1 + 2, OCT31].vals()) {
  var a = 0;
  while (a < 30) {
    for (acct in ["2100", "1500"].vals()) {
      assert (Core.balanceAsOf(s, acct, ?sub(a), "EGP", day) == Core.balanceAsOf(full, acct, ?sub(a), "EGP", day));
      assert (Core.valueDatedBalance(s, acct, null, "EGP", day) == Core.valueDatedBalance(full, acct, null, "EGP", day));
      asOfChecks += 1;
    };
    a += 1;
  };
};
Debug.print("count: balances as of days after the roll-up equal to a full fold = " # Nat.toText(asOfChecks));
assert (Core.postingCount(s) < Core.postingCount(full));

// ─── the fold from a log that carries the checkpoint series ───
// the series is appended now, at the tip; then more postings; the fold from the series equals live
let first = Core.height(s);
var seq = 0;
for (part in List.values(parts)) {
  ignore MemLog.commit(chain, s, clock(), admin, #checkpoint({ through = hi; seq; last = seq + 1 == List.size(parts); part }));
  seq += 1;
};
let last = Core.height(s) - 1;
switch (Core.checkpointPosition(s)) { case (?c) assert (c.through == hi and c.first == first and c.last == ?last); case null assert false };
n := 0;
while (n < 25) { ignore post(input(OCT1 + 2, "2026-10", "2100", "1500", ?sub(n), null, 300 + n)); n += 1 };
// a log whose prefix is gone: the reader answers nothing below the boundary
let truncated : Core.Blocks = { get = func(i : Nat) : ?T.Block { if (i <= hi) null else reader.get(i) } };
let folded = Core.replayFrom(admin, truncated, first, last, Core.height(s));
if (Core.fingerprint(folded) != Core.fingerprint(s)) { Debug.print("FAIL: the fold from the checkpoint series differs from the live state"); assert false };
Debug.print("count: retained blocks folded from the checkpoint series = " # Nat.toText(Core.height(s) - hi - 1));
Debug.print("count: folds from a truncated log equal to the live state = 1");
// negative control: a part tampered with folds to a different state
let tampered : Core.Blocks = {
  get = func(i : Nat) : ?T.Block {
    if (i == first + 3) {
      switch (reader.get(i)) {
        case (?b) { switch (b.event) { case (#checkpoint(c)) { switch (c.part) { case (#balances(xs)) ?{ b with event = #checkpoint({ c with part = #balances([{ xs[0] with drPosted = xs[0].drPosted + 1 }]) }) }; case (_) ?b } }; case (_) ?b } };
        case null null;
      }
    } else truncated.get(i)
  };
};
assert (Core.fingerprint(Core.replayFrom(admin, tampered, first, last, Core.height(s))) != Core.fingerprint(s));
Debug.print("count: tampered checkpoint parts caught by the fold = 1");
