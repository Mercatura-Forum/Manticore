// JournalLog.test.mo; criterion 7 on the Region-backed log: every block gets an
// inclusion proof that verifies against the MMR root, a tampered hash fails,
// the hash chain walks clean, and the certified tip tree is deterministic.
// Needs Region memory: runs under WASI only.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Principal "mo:core/Principal";

import T "../src/journal/JournalTypes";
import JLog "../src/journal/JournalLog";
import JCert "../src/journal/JournalCert";
import Proof "../src/journal/JournalProof";
import C "../src/journal/Canonical";

let admin = Principal.fromBlob("\AD\01");
let poster = Principal.fromBlob("\B0\01");

func record(i : Nat) : T.PostingRecord {
  {
    idempotencyKey = Blob.fromArray([Nat8.fromNat(i % 256), Nat8.fromNat(i / 256)]);
    postingDate = 20697 + (i % 9); valueDate = 20697; period = "2026-09";
    legs = [{ account = "1500"; subledger = null; side = #debit; currency = "EGP"; amount = 1 + i }, { account = "2000"; subledger = ?Blob.fromArray([Nat8.fromNat(i % 256)]); side = #credit; currency = "EGP"; amount = 1 + i }];
    sourceRef = { kind = "test"; id = Nat.toText(i) }; narration = "block " # Nat.toText(i); relation = null; valueDateRequested = null;
  }
};

func event(i : Nat) : T.Event {
  switch (i % 5) {
    case 0 #posted(record(i));
    case 1 #pending({ record = record(i); expiresAt = ?Nat64.fromNat(i) });
    case 2 #periodOpened({ id = "p" # Nat.toText(i); start = i; end = i + 1 });
    case 3 #post({ pendingIndex = i - 2; resolution = { postingDate = 20697; valueDate = 20697; valueDateRequested = null; period = "2026-09" } });
    case _ #void({ pendingIndex = i - 3; reason = #expired });
  }
};

let N = 300;
let log = JLog.newState();
assert (JLog.length(log) == 0 and JLog.mmrRoot(log) == null and JLog.tipHash(log) == null);

var appended = 0;
var proofsVerifiedAtEveryTip = 0;
var i = 0;
while (i < N) {
  let ts = 1_700_000_000_000_000_000 + Nat64.fromNat(i);
  let b = JLog.append(log, ts, if (i % 2 == 0) admin else poster, event(i));
  assert (b.index == i);
  appended += 1;
  // after each append, every earlier block's proof must verify against the new root
  let root = switch (JLog.mmrRoot(log)) { case (?r) r; case null { assert false; loop {} } };
  var j = 0;
  while (j <= i) {
    let bj = switch (JLog.get(log, j)) { case (?x) x; case null { assert false; loop {} } };
    let p = switch (JLog.proof(log, j)) { case (?x) x; case null { assert false; loop {} } };
    assert (JLog.verify(bj.hash, j, p, root));
    proofsVerifiedAtEveryTip += 1;
    j += 1;
  };
  i += 1;
};
Debug.print("count: journal log blocks appended = " # Nat.toText(appended));
Debug.print("count: inclusion proofs verified against every intermediate root = " # Nat.toText(proofsVerifiedAtEveryTip));
assert (proofsVerifiedAtEveryTip == N * (N + 1) / 2);

// decode round trip and chain walk
var decoded = 0;
var prev : ?Blob = null;
i := 0;
while (i < N) {
  let b = switch (JLog.get(log, i)) { case (?x) x; case null { assert false; loop {} } };
  assert (b.event == event(i));
  assert (b.parentHash == prev);
  let raw = switch (JLog.rawBlock(log, i)) { case (?x) x; case null { assert false; loop {} } };
  assert (C.decodeBlock(raw) == ?b);
  prev := ?b.hash;
  decoded += 1;
  i += 1;
};
let walk = JLog.verifyChain(log);
assert (walk.checked == N and walk.fault == null);
Debug.print("count: blocks decoded and chain-linked = " # Nat.toText(decoded));
Debug.print("count: chain walk blocks checked = " # Nat.toText(walk.checked));

// tampering: a flipped bit in the block hash, a wrong index, a wrong root, or a
// sibling from another proof must all fail.
let root = switch (JLog.mmrRoot(log)) { case (?r) r; case null { assert false; loop {} } };
var tamperFails = 0;
var tamperTrials = 0;
i := 0;
while (i < N) {
  let b = switch (JLog.get(log, i)) { case (?x) x; case null { assert false; loop {} } };
  let p = switch (JLog.proof(log, i)) { case (?x) x; case null { assert false; loop {} } };
  let hb = Blob.toArray(b.hash);
  let flipped = Blob.fromArray(Array.tabulate<Nat8>(32, func(k) { if (k == i % 32) hb[k] ^ 0x80 else hb[k] }));
  tamperTrials += 4;
  if (not JLog.verify(flipped, i, p, root)) tamperFails += 1;
  if (not JLog.verify(b.hash, (i + 1) % N, p, root)) tamperFails += 1;
  let rb = Blob.toArray(root);
  let wrongRoot = Blob.fromArray(Array.tabulate<Nat8>(32, func(k) { if (k == 0) rb[k] ^ 0x01 else rb[k] }));
  if (not JLog.verify(b.hash, i, p, wrongRoot)) tamperFails += 1;
  let other = switch (JLog.proof(log, (i + 7) % N)) { case (?x) x; case null { assert false; loop {} } };
  if (not JLog.verify(b.hash, i, other, root)) tamperFails += 1;
  i += 1;
};
Debug.print("count: proof tamper trials = " # Nat.toText(tamperTrials));
Debug.print("count: proof tampers rejected = " # Nat.toText(tamperFails));
assert (tamperTrials == tamperFails);

// out-of-range access is null, never a trap
assert (JLog.get(log, N) == null and JLog.proof(log, N) == null and JLog.rawBlock(log, N) == null);
assert (JLog.getRange(log, N - 2, 10).size() == 2);

// certified tip tree: deterministic, sensitive to every field, labels present
let h = switch (JLog.tipHash(log)) { case (?x) x; case null { assert false; loop {} } };
let r1 = JCert.rootHash(N - 1, h, root);
assert (r1 == JCert.rootHash(N - 1, h, root));
assert (r1 != JCert.rootHash(N - 2, h, root));
assert (r1 != JCert.rootHash(N - 1, root, root));
assert (r1 != JCert.rootHash(N - 1, h, h));
assert (JCert.natToBeBytes(0) == Blob.fromArray([0]));
assert (JCert.natToBeBytes(256) == Blob.fromArray([1, 0]));
assert (JCert.natToBeBytes(65535) == Blob.fromArray([255, 255]));
Debug.print("count: certified tip tree checks = 7");

// the standalone verifier agrees with the log's verify on every block
var agreed = 0;
i := 0;
while (i < N) {
  let b = switch (JLog.get(log, i)) { case (?x) x; case null { assert false; loop {} } };
  let p = switch (JLog.proof(log, i)) { case (?x) x; case null { assert false; loop {} } };
  assert (Proof.verify(b.hash, i, p, root) and JLog.verify(b.hash, i, p, root));
  agreed += 1;
  i += 1;
};
Debug.print("count: JournalProof and JournalLog verifiers agree on blocks = " # Nat.toText(agreed));
