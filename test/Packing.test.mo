// Packing.test.mo — closed-month packing against a brute-force oracle, interrupted at every step.
//
// What is proved, on a random journal through the real log with two periods and a close between:
//
//   * every segment of the pack unpacks to the exact bytes the log holds (the codec's own round trip
//     is repeated here, independently);
//   * after the pack, every live posting index holds exactly the rows the day rule keeps — a row
//     leaves when its posting is in the packed block range and its value day is at or before the
//     period's end; a posting of the next period made before the close keeps its rows, and so does
//     a pending still open at the pack — and every live activity index exactly the rows of days
//     after the period's end; compared row for row, both directions, with dumps taken before the
//     pack and filtered by the oracle;
//   * the monthly roll-ups equal the sums of the rows that left;
//   * every account's packed summary and delta-coded list equal the brute-force list of its posted
//     postings in the range, and a packed statement read equals the live read taken before;
//   * postings that land **during** the rebuilds are in the live indexes afterwards;
//   * the dormancy reading after the roll-up equals the one before, for every account;
//   * a second pack reuses the first's pages: the arena does not grow past what the first needed;
//   * the bank's own log packs with the month (§18.3): every bank block of the range reads back through
//     the packs as the bytes the log stored — head and empty trailer for the settled proposals whose
//     bodies the rule lets go, the whole block for everything else — and decodes to the block it was,
//     hash for hash; a body leaves only where the rule says; the chain walks from genesis across the
//     packed prefix and the live tail; every packed block still proves against the bank's MMR root;
//     the `StableLog` holds nothing below the packed range; bank blocks appended during the pack are
//     above the range and stay live; the second month packs the next bank range and reads span both.
//
// engine: wasi-only — Regions.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Principal "mo:core/Principal";

import JT "mo:journal/JournalTypes";
import JLog "mo:journal/JournalLog";
import RI "mo:ledger/RegionIndex";
import PIdx "../src/bank/PostingIndex";
import A "../src/bank/Activity";
import Pack "../src/bank/Pack";
import Packing "../src/bank/Packing";
import R "../src/bank/StableRows";
import Nat64 "mo:core/Nat64";
import Sha256 "mo:sha2/Sha256";
import BT "../src/bank/BankTypes";
import BC "../src/bank/BankCanonical";
import BLog "../src/bank/BankLog";
import BankPack "../src/bank/BankPack";

var seed : Nat32 = 0x0BAD_F00D;
func next() : Nat32 { seed := seed *% 1_664_525 +% 1_013_904_223; seed };
func below(n : Nat) : Nat { if (n == 0) 0 else (Nat32.toNat(next() / 65_536) * 65_536 + Nat32.toNat(next() / 65_536)) % n };
func fail(what : Text) { Debug.print("FAIL: " # what); assert false };

let ACCOUNTS = 30;
let P1_START = 20_300; let P1_END = 20_329;
let P2_START = 20_330; let P2_END = 20_360;

let log = JLog.newState();
let idx = PIdx.newState();
let act = A.newState(idx.arena);
let packing = Packing.newState(idx.arena);
let ME = Principal.fromText("aaaaa-aa");
func subledgerFor(i : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { if (j < 8) Nat8.fromNat((i / (256 ** (7 - j))) % 256) else 0 })) };
func acctIdFor(i : Nat) : Nat { 200 + i };
var i = 0;
while (i < ACCOUNTS) { assert (PIdx.registerAccount(idx, subledgerFor(i), acctIdFor(i))); i += 1 };

let pctx : PIdx.Context = { classOf = func(a : Nat) : ?Text { if (a % 3 == 0) ?"c.f=x" else null }; blockOf = func(n : Nat) : ?JT.Block { JLog.get(log, n) } };
let actx : A.Context = { accountOf = func(sub : JT.SubledgerKey) : ?Nat { PIdx.accountOf(idx, sub) }; blockOf = func(n : Nat) : ?JT.Block { JLog.get(log, n) } };
var ts : Nat64 = 1_700_000_000_000_000_000;
func emit(e : JT.Event) : JT.Block {
  ts += 1_000_000_000;
  let b = JLog.append(log, ts, ME, e);
  ignore PIdx.indexBlock(idx, b, pctx);
  ignore A.record(act, b, actx);
  b
};
var counter = 0;
func record(day : Nat, period : Text) : JT.PostingRecord {
  counter += 1;
  let a = below(ACCOUNTS);
  var b = below(ACCOUNTS); if (b == a) b := (a + 1) % ACCOUNTS;
  let amount = 1_000 + below(900_000);
  let shape = below(3);
  let legs : [JT.Leg] = if (shape == 0) [
      { account = "2100"; subledger = ?subledgerFor(a); side = #debit; currency = "EGP"; amount },
      { account = "2100"; subledger = ?subledgerFor(b); side = #credit; currency = "EGP"; amount } ]
    else if (shape == 1) [
      { account = "1001"; subledger = null; side = #debit; currency = "EGP"; amount },
      { account = "2100"; subledger = ?subledgerFor(a); side = #credit; currency = "EGP"; amount } ]
    else [
      { account = "2100"; subledger = ?subledgerFor(a); side = #debit; currency = "EGP"; amount },
      { account = "1001"; subledger = null; side = #credit; currency = "EGP"; amount } ];
  {
    idempotencyKey = Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { Nat8.fromNat((counter * 11 + j) % 256) }));
    postingDate = day; valueDate = day; valueDateRequested = null; period; legs;
    sourceRef = { kind = if (shape == 1) "deposit" else "transfer"; id = Nat.toText(counter) }; narration = "n" # Nat.toText(counter % 7); relation = null;
  }
};

ignore emit(#currencyRegistered({ code = "EGP"; minorUnits = 2 }));
ignore emit(#periodOpened({ id = "2026-09"; start = P1_START; end = P1_END }));
ignore emit(#periodOpened({ id = "2026-10"; start = P2_START; end = P2_END }));
// month one: 700 postings, some pending resolved and voided, a few early October postings before the
// September close, then the close
let pendings = List.empty<Nat>();
var n = 0;
while (n < 700) {
  let day = P1_START + below(30);
  let r = record(day, "2026-09");
  if (n % 9 == 0) { List.add(pendings, emit(#pending({ record = r; expiresAt = null })).index) } else ignore emit(#posted(r));
  n += 1;
};
var k = 0;
for (p in List.values(pendings)) {
  if (k % 3 == 2) ignore emit(#void({ pendingIndex = p; reason = #requested }))
  else ignore emit(#post({ pendingIndex = p; resolution = { postingDate = P1_START + 10; valueDate = P1_START + 10 + (k % 5); valueDateRequested = null; period = "2026-09" } }));
  k += 1;
};
n := 0;
while (n < 60) { ignore emit(#posted(record(P2_START + below(5), "2026-10"))); n += 1 };
// a pending reserved in September and still open at the pack: resolved into October after it
let openPending = emit(#pending({ record = record(P1_START + 25, "2026-09"); expiresAt = null })).index;
let closeBlock = emit(#periodClosed({ id = "2026-09" })).index;
Debug.print("count: journal blocks before the pack = " # Nat.toText(JLog.length(log)));

// ─── the oracle's view, taken before the pack ────────────────────────────────
func dumpAll(r : RI.State, width : Nat) : [(Blob, Blob)] { A.dump(r, width) };
let beforeHeaders = dumpAll(idx.headers, PIdx.HEADER_KEY);
let beforeI1 = dumpAll(idx.byAccount, PIdx.I1_KEY);
let beforeI2 = dumpAll(idx.byDay, PIdx.I2_KEY);
let beforeI3 = dumpAll(idx.byCurrency, PIdx.I3_KEY);
let beforeI4 = dumpAll(idx.byClass, PIdx.I4_KEY);
let beforeA1 = dumpAll(act.activity, A.A1_KEY);
let beforeE1 = dumpAll(act.edges, A.E1_KEY);
let beforeE2 = dumpAll(act.edgesOut, A.E2_KEY);
let beforeE3 = dumpAll(act.edgesIn, A.E2_KEY);
// the dormancy reading of every account for a day past the month, before the roll-up
let probeDay = P2_END + 40;
let dormancyBefore = Array.tabulate<?Nat>(ACCOUNTS, func(j) { A.latestBefore(act, acctIdFor(j), probeDay) });
// the live statement of every account over September, before the pack
func liveStatement(acct : Nat, from : Nat, to : Nat) : [(Nat, Nat, Nat, Nat)] {
  let (lo, hi) = PIdx.accountRangeEnds(acct, from, to);
  let page = RI.range(idx.byAccount, lo, hi, null, 10_000);
  let out = List.empty<(Nat, Nat, Nat, Nat)>();
  for ((kk, v) in page.entries.vals()) {
    let parts = PIdx.splitAccountKey(kk);
    if (PIdx.isPosted(idx, parts.postingNo, parts.valueDay)) { let m = PIdx.readMovement(v); List.add(out, (parts.postingNo, parts.valueDay, m.debits, m.credits)) };
  };
  Array.sort<(Nat, Nat, Nat, Nat)>(List.toArray(out), func(x, y) { switch (Nat.compare(x.1, y.1)) { case (#equal) Nat.compare(x.0, y.0); case (o) o } })
};
let statementsBefore = Array.tabulate<[(Nat, Nat, Nat, Nat)]>(ACCOUNTS, func(j) { liveStatement(acctIdFor(j), 0, P1_END) });
let arenaBefore = RI.arenaStats(idx.arena);
Debug.print("count: arena pages before the pack = " # Nat.toText(arenaBefore.pages));

// ─── the bank's own log: decisions of the month, some proposals carrying bodies ───────────────
// Every fourth block is a proposal with its body; every other proposal is "settled" — executed, its
// command reconstructed — and the rule drops its body at the pack; the others keep theirs. The rule is
// the bank's (`BankCore.keptBytes`, proved in BankCore.test); here its decision is the oracle's.
let bankLog = BLog.newState();
let maker = Principal.fromText("2vxsx-fae");
let bankCommands : [BT.Command] = [
  #openBook({ id = "BR01"; name = "Branch 1"; parent = ?"HQ" }),
  #setDualPolicy({ permission = "journal.entry.create"; required = 2; eligibleRole = "checker"; ttlSeconds = 86_400 }),
  #setFeatureActivation({ feature = "manual-entry"; height = 17 : Nat64 }),
  #defineRole({ id = "checker"; name = "Checker"; permissions = ["command.approve", "role.grant"] }),
];
func isProposal(i : Nat) : Bool { i % 4 == 0 };
func isSettled(i : Nat) : Bool { i % 8 == 0 };
func bankEventFor(i : Nat) : BT.Event {
  if (isProposal(i)) {
    let c = bankCommands[(i / 4) % bankCommands.size()];
    #commandProposed({ command = ?c; commandHash = BC.commandHash(c); commandEncoding = 2 : Nat8; permission = "x"; book = ?"BR01"; maker; required = 1; eligibleRole = "checker"; expiresAt = Nat64.fromNat(i) * 1_000_000_000 + 86_400_000_000_000; justification = "month " # Nat.toText(i) })
  } else if (i % 4 == 1) {
    #commandApproved({ proposal = i - 1; commandHash = BC.commandHash(bankCommands[((i - 1) / 4) % bankCommands.size()]); checker = ME })
  } else if (i % 4 == 2) {
    #commandExecuted({ proposal = i - 2; commandHash = BC.commandHash(bankCommands[((i - 2) / 4) % bankCommands.size()]); postings = [i, i + 1]; charge = ?{ day = P1_START + (i % 30); totals = [("EGP", i * 100)] } })
  } else {
    #commandRejected({ proposal = i - 3; checker = ME; reason = "no" })
  }
};
func appendBank(i : Nat) : BT.Block { BLog.append(bankLog, Nat64.fromNat(i) * 1_000_000_000, maker, bankEventFor(i)) };
let BANK_N = 241;
let BANK_HI1 = 183;   // the first pack's bank range is 0 … 183; 184 … 240 stay live as the month's tail
i := 0;
while (i < BANK_N) { ignore appendBank(i); i += 1 };
// the bank's view before the pack: every block's stored bytes and decoded block
let bankRawBefore = Array.tabulate<Blob>(BANK_N, func(k) { switch (BLog.rawBlock(bankLog, k)) { case (?b) b; case null { fail("bank raw"); loop {} } } });
let bankBlocksBefore = Array.tabulate<BT.Block>(BANK_N, func(k) { switch (BLog.get(bankLog, k)) { case (?b) b; case null { fail("bank block"); loop {} } } });
func rootOf(l : BLog.State) : Blob { switch (BLog.mmrRoot(l)) { case (?r) r; case null { fail("bank root"); loop {} } } };
let bankRootBefore = rootOf(bankLog);
func headWithEmptyTrailer(raw : Blob) : Blob {
  let ?parts = BC.splitTrailer(raw) else { fail("a bank block does not split"); loop {} };
  Blob.fromArray(Array.concat<Nat8>(Blob.toArray(parts.head), [0]))
};
func keepRule(k : Nat, raw : Blob) : Blob { if (isSettled(k)) headWithEmptyTrailer(raw) else raw };
func packedBankBlock(k : Nat) : ?Blob { Packing.bankBlock(packing, k) };

// ─── the pack, one bounded step at a time, with postings landing between steps ───────────────
func idemBegin(_ : Nat) : Bool { true };
func idemStep(_ : Nat) : { examined : Nat; done : Bool } { { examined = 0; done = true } };
func idemFinish() : Bool { true };
let ctx : Packing.Context = { pidx = idx; activity = act; rawBlock = func(i : Nat) : ?Blob { JLog.rawBlock(log, i) }; blockOf = func(i : Nat) : ?JT.Block { JLog.get(log, i) }; rawBankBlock = func(i : Nat) : ?Blob { BLog.rawBlock(bankLog, i) }; bankKeep = keepRule; idemBegin; idemStep; idemFinish };
let job = switch (Packing.open(packing, "2026-09", PIdx.periodOrdinal(idx, "2026-09"), P1_END, closeBlock, 0, BANK_HI1)) { case (#ok(j)) j; case (#err(e)) { fail(debug_show (e)); loop {} } };
assert (job.lo == 0 and job.hi == closeBlock and job.bankLo == 0 and job.bankHi == BANK_HI1);
switch (Packing.open(packing, "2026-10", 2, P2_END, closeBlock + 1, BANK_HI1 + 1, BANK_N - 1)) { case (#err(#PackingInProgress(_))) {}; case (_) fail("a second pack opened during the first") };
var steps = 0;
var landedDuring = 0;
let landed = List.empty<Nat>();
var lastPhase = "";
let phases = List.empty<Text>();
var bankLandedDuring = 0;
label run loop {
  let adv = switch (Packing.advance(packing, ctx, 50 + below(300))) { case (#ok(a)) a; case (#err(e)) { fail("advance: " # debug_show (e)); loop {} } };
  steps += 1;
  if (not Text.equal(adv.phase, lastPhase)) { Debug.print("  phase " # adv.phase); lastPhase := adv.phase; List.add(phases, adv.phase) };
  // an October posting lands between steps, whatever the phase
  if (steps % 3 == 0) { List.add(landed, emit(#posted(record(P2_START + 6 + below(10), "2026-10"))).index); landedDuring += 1 };
  // and a bank decision lands too: above the pack's bank range, it stays in the live log
  if (steps % 5 == 0) { ignore appendBank(BLog.length(bankLog)); bankLandedDuring += 1 };
  // at the seal the bank does what Bank.mo does: the packed bank prefix leaves the StableLog
  if (adv.sealed) { BLog.truncateThrough(bankLog, job.bankHi); break run };
};
Debug.print("count: packing steps = " # Nat.toText(steps));
Debug.print("count: postings that landed during the pack = " # Nat.toText(landedDuring));
Debug.print("count: bank blocks that landed during the pack = " # Nat.toText(bankLandedDuring));
// the phases run in order: the journal's blocks, then the bank's, then the rows
let phaseOrder = List.toArray(phases);
assert (phaseOrder.size() >= 3 and Text.equal(phaseOrder[0], "encoding") and Text.equal(phaseOrder[1], "bankEncoding") and Text.equal(phaseOrder[2], "consolidating"));
let ?pack = Packing.getPack(packing, 1) else { fail("no pack"); loop {} };
assert (pack.lo == 0 and pack.hi == closeBlock and pack.segments > 1);
Debug.print("count: segments in the pack = " # Nat.toText(pack.segments));
Debug.print("count: postings in the pack = " # Nat.toText(pack.postings));
Debug.print("count: accounts with a summary row = " # Nat.toText(pack.accounts));
Debug.print("count: packed bytes = " # Nat.toText(pack.packedBytes));
Debug.print("count: raw bytes replaced = " # Nat.toText(pack.rawBytes));

// ─── the segments unpack to the log's bytes ──────────────────────────────────
var segBlocks = 0;
for (sg in Packing.segmentsOf(packing, 1).vals()) {
  let ?bytes = Packing.segmentBytes(packing, 1, sg.seq) else { fail("segment bytes"); loop {} };
  switch (Pack.unpack(bytes)) {
    case (#err(why)) fail("segment " # Nat.toText(sg.seq) # " does not unpack: " # why);
    case (#ok(back)) {
      var b = 0;
      while (b < back.size()) {
        let ?raw = JLog.rawBlock(log, sg.lo + b) else { fail("raw"); loop {} };
        if (back[b].raw != raw) fail("segment " # Nat.toText(sg.seq) # " block " # Nat.toText(sg.lo + b) # " differs");
        segBlocks += 1;
        b += 1;
      };
    };
  };
};
assert (segBlocks == closeBlock + 1);
Debug.print("count: packed blocks that unpack to the log's bytes = " # Nat.toText(segBlocks));

// ─── the bank's blocks: packed, truncated, read back through the packs (§18.3) ───────────────
func checkBankRange(packNo : Nat, lo : Nat, hi : Nat) {
  let ?pv = Packing.getPack(packing, packNo) else { fail("no pack " # Nat.toText(packNo)); loop {} };
  assert (pv.bankLo == lo and pv.bankHi == hi);
  // the segments: contiguous over the range, each hashing to its row's sha256, each a TBBP segment
  var expectAt = lo;
  var dropped = 0; var kept = 0; var segBytes = 0; var segRaw = 0;
  let segs = Packing.bankSegmentsOf(packing, packNo);
  assert (segs.size() == pv.bankSegments and segs.size() >= 1);
  for (g in segs.vals()) {
    assert (g.lo == expectAt and g.hi >= g.lo and g.hi <= hi);
    let ?bytes = Packing.bankSegmentBytes(packing, packNo, g.seq) else { fail("bank segment bytes"); loop {} };
    assert (bytes.size() == g.bytes and Sha256.fromBlob(#sha256, bytes) == g.sha256);
    let ?h = BankPack.header(bytes) else { fail("bank segment header"); loop {} };
    assert (h.lo == g.lo and h.count == g.hi + 1 - g.lo);
    // the whole-segment reader and the store's one-block reader agree
    var k = g.lo;
    while (k <= g.hi) { assert (BankPack.block(bytes, k) == packedBankBlock(k)); k += 1 };
    expectAt := g.hi + 1; dropped += g.dropped; kept += g.kept; segBytes += g.bytes; segRaw += g.rawBytes;
  };
  assert (expectAt == hi + 1);
  assert (dropped == pv.bankDropped and kept == pv.bankKept and segBytes == pv.bankPackedBytes and segRaw == pv.bankRawBytes);
  // every block of the range: the StableLog no longer holds it; the pack answers the bytes the rule
  // keeps; it decodes to the block it was, hash for hash, its body gone only where the rule said
  var expectDropped = 0;
  var k = lo;
  while (k <= hi) {
    assert (BLog.rawBlock(bankLog, k) == null);
    let want = keepRule(k, bankRawBefore[k]);
    if (want.size() != bankRawBefore[k].size()) expectDropped += 1;
    switch (packedBankBlock(k)) { case (?got) { if (got != want) fail("bank block " # Nat.toText(k) # " reads back differently through the pack") }; case null fail("bank block " # Nat.toText(k) # " is not in a pack") };
    assert (BLog.rawBlockWith(bankLog, packedBankBlock, k) == ?want);
    let ?b = BLog.getWith(bankLog, packedBankBlock, k) else { fail("bank block " # Nat.toText(k) # " does not decode from the pack"); loop {} };
    let was = bankBlocksBefore[k];
    assert (b.index == was.index and b.hash == was.hash and b.parentHash == was.parentHash and b.timestamp == was.timestamp and b.caller == was.caller);
    switch (b.event, was.event) {
      case (#commandProposed(x), #commandProposed(y)) {
        assert (x.commandHash == y.commandHash and x.maker == y.maker and x.justification == y.justification);
        if (isSettled(k)) assert (x.command == null and y.command != null) else assert (x.command == y.command and x.command != null);
      };
      case (e, f) assert (e == f);
    };
    // the packed block proves against the root the bank certifies now: packing moved its bytes, not its leaf
    let ?pf = BLog.proof(bankLog, k) else { fail("bank proof"); loop {} };
    assert (BLog.verify(b.hash, k, pf, rootOf(bankLog)));
    k += 1;
  };
  assert (expectDropped == dropped and expectDropped > 0 and kept > 0);
  Debug.print("count: pack " # Nat.toText(packNo) # " bank blocks packed = " # Nat.toText(hi + 1 - lo) # " in " # Nat.toText(segs.size()) # " segments; bodies dropped = " # Nat.toText(dropped) # "; blocks kept whole = " # Nat.toText(kept));
  Debug.print("count: pack " # Nat.toText(packNo) # " bank bytes packed = " # Nat.toText(segBytes) # " of " # Nat.toText(segRaw) # " raw");
};
checkBankRange(1, 0, BANK_HI1);
assert (BLog.base(bankLog) == BANK_HI1 + 1);
assert (Packing.bankPackedThrough(packing) == BANK_HI1);
// the live tail is untouched, including what landed during the pack
var t = BANK_HI1 + 1;
while (t < BLog.length(bankLog)) { assert (BLog.rawBlock(bankLog, t) != null and packedBankBlock(t) == null); t += 1 };
assert (BLog.length(bankLog) == BANK_N + bankLandedDuring);
// the chain walks from genesis over the packed prefix and the live tail
let walk = BLog.verifyChainWith(bankLog, packedBankBlock);
assert (walk.fault == null and walk.checked == BLog.length(bankLog));
Debug.print("count: bank chain walked across the pack = " # Nat.toText(walk.checked));
// a walk that cannot see the packs stops at the base — the truncation is real
assert (BLog.verifyChain(bankLog).checked == 0);
// the root moved only because the tail grew during the pack; packing moves bytes, not commitments …
assert (BLog.mmrRoot(bankLog) != ?bankRootBefore and bankLandedDuring > 0);
let rootNow = rootOf(bankLog);
t := 0;
while (t < BLog.length(bankLog)) {
  let ?b = BLog.getWith(bankLog, packedBankBlock, t) else { fail("walk"); loop {} };
  let ?pf = BLog.proof(bankLog, t) else { fail("proof"); loop {} };
  assert (BLog.verify(b.hash, t, pf, rootNow));   // … and every block, packed or live, proves against today's root
  t += 1;
};
Debug.print("count: bank blocks proving against the current root = " # Nat.toText(t));
// a range read spans the packs and the live log
let spanned = BLog.getRangeWith(bankLog, packedBankBlock, BANK_HI1 - 3, 8);
assert (spanned.size() == 8 and spanned[0].index == BANK_HI1 - 3 and spanned[7].index == BANK_HI1 + 4);

// ─── the live indexes: exactly the rows above the boundary, plus what landed ────────────────
func postingOfHeaderKey(kk : Blob) : Nat { R.getNat(Blob.toArray(kk), 0, 8) };
func compareRows(name : Text, now : [(Blob, Blob)], expected : [(Blob, Blob)]) {
  let want = Map.empty<Blob, Blob>();
  for ((kk, v) in expected.vals()) Map.add(want, Blob.compare, kk, v);
  if (now.size() != Map.size(want)) fail(name # ": " # Nat.toText(now.size()) # " live rows, " # Nat.toText(Map.size(want)) # " expected");
  for ((kk, v) in now.vals()) {
    switch (Map.get(want, Blob.compare, kk)) { case (?w) { if (w != v) fail(name # ": a row differs") }; case null fail(name # ": an unexpected live row") };
  };
  Debug.print("count: " # name # " rows equal to the oracle after the pack = " # Nat.toText(now.size()));
};
// what landed during the pack is in the live indexes now: take fresh dumps of the rows for those
// postings from the live index itself, and the oracle is "before, filtered, plus those"
// the day rule, written independently of the index: a posting of the packed range stays when its
// header's value day is after the period's end or it is a pending still open; the movement rows
// follow their header
let headerStays = Map.empty<Nat, Bool>();
for ((kk, v) in beforeHeaders.vals()) {
  let p = postingOfHeaderKey(kk);
  let hv = Blob.toArray(v);
  let valueDay = R.getNat(hv, 0, 4);
  let status = hv[16];
  Map.add(headerStays, Nat.compare, p, p > closeBlock or valueDay > P1_END or status == PIdx.STATUS_PENDING);
};
func stays(p : Nat) : Bool { switch (Map.get(headerStays, Nat.compare, p)) { case (?b) b; case null false } };
func withLanded(before : [(Blob, Blob)], now : [(Blob, Blob)], postingOf : Blob -> Nat) : [(Blob, Blob)] {
  let out = List.empty<(Blob, Blob)>();
  for ((kk, v) in before.vals()) { if (stays(postingOf(kk))) List.add(out, (kk, v)) };
  for ((kk, v) in now.vals()) { let p = postingOf(kk); for (l in List.values(landed)) { if (l == p) List.add(out, (kk, v)) } };
  List.toArray(out)
};
var kept = 0; var left = 0;
for ((_, b) in Map.entries(headerStays)) { if (b) kept += 1 else left += 1 };
Debug.print("count: headers of the packed range the day rule keeps = " # Nat.toText(kept));
Debug.print("count: headers the day rule drops = " # Nat.toText(left));
assert (stays(openPending));
compareRows("headers", dumpAll(idx.headers, PIdx.HEADER_KEY), withLanded(beforeHeaders, dumpAll(idx.headers, PIdx.HEADER_KEY), postingOfHeaderKey));
compareRows("I1", dumpAll(idx.byAccount, PIdx.I1_KEY), withLanded(beforeI1, dumpAll(idx.byAccount, PIdx.I1_KEY), func(kk) { PIdx.splitAccountKey(kk).postingNo }));
compareRows("I2", dumpAll(idx.byDay, PIdx.I2_KEY), withLanded(beforeI2, dumpAll(idx.byDay, PIdx.I2_KEY), func(kk) { PIdx.splitDayKey(kk).postingNo }));
compareRows("I3", dumpAll(idx.byCurrency, PIdx.I3_KEY), withLanded(beforeI3, dumpAll(idx.byCurrency, PIdx.I3_KEY), func(kk) { PIdx.splitOrdinalKey(kk).postingNo }));
compareRows("I4", dumpAll(idx.byClass, PIdx.I4_KEY), withLanded(beforeI4, dumpAll(idx.byClass, PIdx.I4_KEY), func(kk) { PIdx.splitOrdinalKey(kk).postingNo }));
// the open pending resolves after the pack, into October: its rows move to the resolved day and
// the resolution is readable by the account index
let resolvedDay = P2_START + 3;
ignore emit(#post({ pendingIndex = openPending; resolution = { postingDate = resolvedDay; valueDate = resolvedDay; valueDateRequested = null; period = "2026-10" } }));
switch (PIdx.header(idx, openPending)) { case (?h) assert (h.valueDay == resolvedDay and h.status == PIdx.STATUS_POSTED_FROM_PENDING); case null fail("the open pending lost its header") };
var resolvedRows = 0;
for ((kk, _) in dumpAll(idx.byAccount, PIdx.I1_KEY).vals()) { let parts = PIdx.splitAccountKey(kk); if (parts.postingNo == openPending and PIdx.isPosted(idx, parts.postingNo, parts.valueDay)) resolvedRows += 1 };
Debug.print("count: live rows of the pending resolved after the pack = " # Nat.toText(resolvedRows));
// the activity rows: days after the period's end; a landed posting's day is always after it
func dayOfA1(kk : Blob) : Nat { R.getNat(Blob.toArray(kk), 8, 4) };
func dayOfE1(kk : Blob) : Nat { R.getNat(Blob.toArray(kk), 66, 4) };
func dayOfE2(kk : Blob) : Nat { R.getNat(Blob.toArray(kk), 33, 4) };
func afterEnd(before : [(Blob, Blob)], now : [(Blob, Blob)], dayOf : Blob -> Nat) : [(Blob, Blob)] {
  // every live row must have a day after the period end; and every before-row with such a day must
  // be present with a value the live index now holds (the landed postings added to it)
  for ((kk, _) in now.vals()) { if (dayOf(kk) <= P1_END) fail("a row of a rolled-up day is still live") };
  let out = List.empty<(Blob, Blob)>();
  let nowMap = Map.empty<Blob, Blob>();
  for ((kk, v) in now.vals()) Map.add(nowMap, Blob.compare, kk, v);
  for ((kk, v) in before.vals()) {
    if (dayOf(kk) > P1_END) {
      switch (Map.get(nowMap, Blob.compare, kk)) { case (?nv) List.add(out, (kk, nv)); case null List.add(out, (kk, v)) };
    };
  };
  // rows that exist only because of the landed postings
  let beforeMap = Map.empty<Blob, Blob>();
  for ((kk, v) in before.vals()) Map.add(beforeMap, Blob.compare, kk, v);
  for ((kk, v) in now.vals()) { if (Map.get(beforeMap, Blob.compare, kk) == null) List.add(out, (kk, v)) };
  List.toArray(out)
};
compareRows("A1", dumpAll(act.activity, A.A1_KEY), afterEnd(beforeA1, dumpAll(act.activity, A.A1_KEY), dayOfA1));
compareRows("E1", dumpAll(act.edges, A.E1_KEY), afterEnd(beforeE1, dumpAll(act.edges, A.E1_KEY), dayOfE1));
compareRows("E2", dumpAll(act.edgesOut, A.E2_KEY), afterEnd(beforeE2, dumpAll(act.edgesOut, A.E2_KEY), dayOfE2));
compareRows("E3", dumpAll(act.edgesIn, A.E2_KEY), afterEnd(beforeE3, dumpAll(act.edgesIn, A.E2_KEY), dayOfE2));
assert (landedDuring > 0);
// and every landed posting is readable by the account index now
for (l in List.values(landed)) { switch (PIdx.header(idx, l)) { case (?h) assert (h.valueDay > P1_END); case null fail("a posting that landed during the pack has no header") } };
Debug.print("count: postings landed during the pack and present in the live indexes = " # Nat.toText(landedDuring));

// ─── the monthly roll-ups equal the sums of what left ──────────────────────
let sepOrd = PIdx.periodOrdinal(idx, "2026-09");
var rolled = 0;
var j = 0;
while (j < ACCOUNTS) {
  let acct = acctIdFor(j);
  var count = 0; var dr = 0; var cr = 0; var largest = 0; var first = 0xFFFF_FFFF; var last = 0;
  for ((kk, v) in beforeA1.vals()) {
    let a = Blob.toArray(kk);
    if (R.getNat(a, 0, 8) == acct and dayOfA1(kk) <= P1_END) {
      let d = Blob.toArray(v);
      count += R.getNat(d, 0, 4); dr += R.getNat(d, 4, 16); cr += R.getNat(d, 20, 16); largest := Nat.max(largest, R.getNat(d, 36, 16));
      first := Nat.min(first, dayOfA1(kk)); last := Nat.max(last, dayOfA1(kk));
    };
  };
  switch (A.monthOf(act, acct, sepOrd)) {
    case (?m) { assert (count > 0); assert (m.count == count and m.debits == dr and m.credits == cr and m.largest == largest and m.firstDay == first and m.lastDay == last); rolled += 1 };
    case null assert (count == 0);
  };
  j += 1;
};
Debug.print("count: accounts whose monthly roll-up equals the rows that left = " # Nat.toText(rolled));
// the edges: the monthly total of an (from, to) pair equals the sum of its E1 rows of the month
var edgeMonths = 0;
let pairSums = Map.empty<Blob, (Nat, Nat)>();
for ((kk, v) in beforeE1.vals()) {
  if (dayOfE1(kk) <= P1_END) {
    let a = Blob.toArray(kk);
    let pk = R.getBlob(a, 0, 66);
    let amount = R.getNat(Blob.toArray(v), 0, 16);
    let (c, s) = switch (Map.get(pairSums, Blob.compare, pk)) { case (?x) x; case null (0, 0) };
    Map.add(pairSums, Blob.compare, pk, (c + 1, s + amount));
  };
};
for ((pk, (c, s)) in Map.entries(pairSums)) {
  let from : A.Counterparty = #key(R.getBlob(Blob.toArray(pk), 0, 33));
  let rows = A.monthlyNeighbours(act, from, true, 10_000);
  var found = false;
  for (r in rows.vals()) { if (r.key == R.getBlob(Blob.toArray(pk), 33, 33) and r.periodOrd == sepOrd) { found := true; assert (r.count == c and r.amount == s) } };
  if (not found) fail("a monthly edge total is missing");
  edgeMonths += 1;
};
Debug.print("count: monthly edge totals equal to the rows that left = " # Nat.toText(edgeMonths));

// ─── the packed statements equal the live ones taken before ──────────────
var statements = 0;
j := 0;
while (j < ACCOUNTS) {
  let acct = acctIdFor(j);
  let packed = Packing.packedEntries(packing, acct, 0, P1_END, 10_000);
  assert (not packed.exceeded);
  let want = statementsBefore[j];
  if (packed.entries.size() != want.size()) fail("account " # Nat.toText(acct) # ": " # Nat.toText(packed.entries.size()) # " packed rows, " # Nat.toText(want.size()) # " live before");
  var q = 0;
  while (q < want.size()) {
    let e = packed.entries[q];
    let (p, d, dr, cr) = want[q];
    if (e.posting != p or e.valueDay != d or e.debits != dr or e.credits != cr) fail("account " # Nat.toText(acct) # " row " # Nat.toText(q) # " differs");
    q += 1;
  };
  switch (Packing.packedAccount(packing, acct, 1)) {
    case (?pa) { var dr = 0; var cr = 0; for (e in pa.entries.vals()) { dr += e.debits; cr += e.credits }; assert (pa.debits == dr and pa.credits == cr and pa.count == pa.entries.size()) };
    case null assert (want.size() == 0 or statementsBefore[j].size() == 0);
  };
  statements += 1;
  j += 1;
};
Debug.print("count: packed statements equal to the live statements before the pack = " # Nat.toText(statements));
// the packed lists hold every posting of the range, October's early ones included, and a read
// over October days finds exactly those — the rows the live index also still holds
var octoberPacked = 0;
j := 0;
while (j < ACCOUNTS) {
  let acct = acctIdFor(j);
  let packed = Packing.packedEntries(packing, acct, P2_START, P2_END, 10_000);
  let live = liveStatement(acct, P2_START, P2_END);
  // the live statement also holds what landed during the pack and the pending resolved after it
  // (its entry belongs to the pack of its resolution); the packed one cannot
  var liveInRange = 0;
  for ((p, _, _, _) in live.vals()) { if (p <= closeBlock and p != openPending) liveInRange += 1 };
  if (packed.entries.size() != liveInRange) fail("account " # Nat.toText(acct) # ": October packed rows differ from the live ones");
  octoberPacked += packed.entries.size();
  j += 1;
};
Debug.print("count: next-period postings in the pack that the live index still holds = " # Nat.toText(octoberPacked));
// a read wider than its bound is refused with the size
let wide = Packing.packedEntries(packing, acctIdFor(0), 0, P1_END, 1);
assert (wide.exceeded and wide.size > 1);
Debug.print("count: packed reads refused past their bound = 1");

// ─── dormancy reads unchanged by the roll-up ────────────────────────────────
var dormancyChecks = 0;
j := 0;
while (j < ACCOUNTS) {
  let acct = acctIdFor(j);
  // a landed October posting may have moved the reading forward; compare against a day before them
  let nowReading = A.latestBefore(act, acct, probeDay);
  switch (dormancyBefore[j], nowReading) {
    case (?b, ?nw) { assert (nw >= b) };
    case (null, null) {};
    case (null, ?_) {};   // activity landed during the pack
    case (?_, null) fail("a dormancy reading vanished with the roll-up");
  };
  // and for a day inside October, before any landed posting, the reading is exactly the same
  let d0 = P2_START;
  assert (A.latestBefore(act, acct, d0) == (
    do {
      var best : ?Nat = null;
      for ((kk, _) in beforeA1.vals()) { let a = Blob.toArray(kk); if (R.getNat(a, 0, 8) == acct and dayOfA1(kk) < d0) { switch (best) { case (?x) { if (dayOfA1(kk) > x) best := ?dayOfA1(kk) }; case null best := ?dayOfA1(kk) } } };
      best
    }));
  dormancyChecks += 1;
  j += 1;
};
Debug.print("count: dormancy readings exact after the roll-up = " # Nat.toText(dormancyChecks));
assert (A.rolledUpThrough(act) == P1_END);

// ─── the second month reuses the first's pages ───────────────────────────────
let arenaAfterFirst = RI.arenaStats(idx.arena);
n := 0;
while (n < 700) { ignore emit(#posted(record(P2_START + below(31), "2026-10"))); n += 1 };
let closeBlock2 = emit(#periodClosed({ id = "2026-10" })).index;
let arenaBeforeSecond = RI.arenaStats(idx.arena);
// October's bank decisions: more blocks, the second range is the first's end to the tail the bank leaves
i := BLog.length(bankLog);
while (i < BANK_N + bankLandedDuring + 60) { ignore appendBank(i); i += 1 };
let BANK_HI2 = BLog.length(bankLog) - 9;
let bankRawBefore2 = Array.tabulate<Blob>(BLog.length(bankLog), func(k) { if (k <= BANK_HI1) bankRawBefore[k] else switch (BLog.rawBlock(bankLog, k)) { case (?b) b; case null { fail("bank raw 2"); loop {} } } });
switch (Packing.open(packing, "2026-10", PIdx.periodOrdinal(idx, "2026-10"), P2_END, closeBlock2, BANK_HI1 + 1, BANK_HI2)) { case (#ok(j2)) assert (j2.lo == closeBlock + 1 and j2.bankLo == BANK_HI1 + 1 and j2.bankHi == BANK_HI2); case (#err(e)) fail(debug_show (e)) };
label run2 loop { switch (Packing.advance(packing, ctx, 5_000)) { case (#ok(a)) { if (a.sealed) { BLog.truncateThrough(bankLog, BANK_HI2); break run2 } }; case (#err(e)) { fail(debug_show (e)); loop {} } } };
let arenaAfterSecond = RI.arenaStats(idx.arena);
Debug.print("count: arena pages after the first pack = " # Nat.toText(arenaAfterFirst.pages));
Debug.print("count: arena pages before the second pack = " # Nat.toText(arenaBeforeSecond.pages));
Debug.print("count: arena pages after the second pack = " # Nat.toText(arenaAfterSecond.pages));
Debug.print("count: free pages after the second pack = " # Nat.toText(arenaAfterSecond.free));
// the second pack's rebuilds ran in the pages the first released: growth across the second pack is
// at most what the second month's own rows added before it
assert (arenaAfterSecond.pages <= arenaBeforeSecond.pages + 8);
let ?pack2 = Packing.getPack(packing, 2) else { fail("no second pack"); loop {} };
// the second bank range reads through pack 2; the first still through pack 1; the tail is live
assert (BLog.base(bankLog) == BANK_HI2 + 1 and Packing.bankPackedThrough(packing) == BANK_HI2);
t := 0;
while (t < BLog.length(bankLog)) {
  let want = if (t <= BANK_HI2) keepRule(t, bankRawBefore2[t]) else bankRawBefore2[t];
  assert (BLog.rawBlockWith(bankLog, packedBankBlock, t) == ?want);
  if (t <= BANK_HI2) assert (BLog.rawBlock(bankLog, t) == null) else assert (packedBankBlock(t) == null);
  t += 1;
};
let walk2 = BLog.verifyChainWith(bankLog, packedBankBlock);
assert (walk2.fault == null and walk2.checked == BLog.length(bankLog));
assert (pack2.bankLo == BANK_HI1 + 1 and pack2.bankHi == BANK_HI2 and pack2.bankSegments >= 1 and pack2.bankDropped > 0);
Debug.print("count: bank blocks in pack 2 = " # Nat.toText(pack2.bankHi + 1 - pack2.bankLo) # "; bodies dropped = " # Nat.toText(pack2.bankDropped));
Debug.print("count: bank chain walked across two packs = " # Nat.toText(walk2.checked));
let bst = Packing.stats(packing);
assert (bst.bankBlocksPacked == BANK_HI2 + 1 and bst.bankBodiesDropped == pack.bankDropped + pack2.bankDropped and bst.bankPackedThroughBlock == BANK_HI2);
Debug.print("count: bank pack store bytes = " # Nat.toText(bst.bankStoreBytes));
Debug.print("count: bank packed bytes / raw = " # Nat.toText(bst.bankPackedBytes) # " / " # Nat.toText(bst.bankRawBytes));
// the pending resolved after the first pack is listed by the second, at its resolved day
var resolvedListed = 0;
for (e in Packing.packedEntries(packing, acctIdFor(0), P2_START, P2_END, 100_000).entries.vals()) { if (e.posting == openPending) resolvedListed += 1 };
j := 0;
while (j < ACCOUNTS) { for (e in Packing.packedEntries(packing, acctIdFor(j), P2_START, P2_END, 100_000).entries.vals()) { if (e.posting == openPending) { assert (e.valueDay == resolvedDay); resolvedListed += 1 } }; j += 1 };
assert (resolvedListed >= 1);
Debug.print("count: packed rows of the pending resolved between the packs = " # Nat.toText(resolvedListed));
assert (pack2.lo == closeBlock + 1 and pack2.hi == closeBlock2);
assert (Packing.packedThrough(packing).block == closeBlock2 and Packing.packedThrough(packing).day == P2_END);
Debug.print("count: packs sealed = 2");
let st = Packing.stats(packing);
Debug.print("count: pack store bytes = " # Nat.toText(st.storeBytes));
Debug.print("count: pack stores = " # Nat.toText(st.stores));
Debug.print("packed bytes per posting in pack 1: " # Nat.toText(pack.packedBytes / pack.postings) # "; raw: " # Nat.toText(pack.rawBytes / pack.postings));
