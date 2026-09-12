// MmrVerifyProof.test.mo — acceptance test for the verifyProof fix
// Over leaf counts 1..300 every
// proof must verify with the fixed src/ledger/MerkleMMR.verifyProof and with
// JournalProof.verify; the historical fold (reproduced here verbatim) must
// accept exactly the single-peak counts, which documents the defect it replaced;
// and four tamper classes must be rejected for every leaf.
// Needs Region memory (MerkleMMR): WASI only.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import MMR "../src/ledger/MerkleMMR";
import Proof "../src/journal/JournalProof";

func blockHash(n : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((n * 7 + i) % 256) })) };
func isPowerOfTwo(n : Nat) : Bool { n > 0 and (Nat64.fromNat(n) & Nat64.fromNat(n - 1)) == 0 };

/// The fold verifyProof used before the fix (ICRC-ME 0ed4b63c):
/// from the last peak upwards. Kept only to measure what the fix corrected.
func historicalVerify(leafHash : Blob, siblings : [Blob], leafIndex : Nat, expectedRoot : Blob, peaks : [Blob], peakIndex : Nat) : Bool {
  var current = Proof.climb(leafHash, leafIndex, siblings);
  if (peakIndex >= peaks.size()) return false;
  if (current != peaks[peakIndex]) return false;
  var root : ?Blob = null;
  var i = peaks.size();
  while (i > 0) {
    i -= 1;
    root := switch (root) { case null ?peaks[i]; case (?acc) ?Proof.hashNode(peaks[i], acc) };
  };
  switch (root) { case (?r) r == expectedRoot; case null false }
};

let N = 300;
let st = MMR.newState();
var trials = 0;
var fixedOk = 0; var journalOk = 0;
var histOk = 0; var histRejected = 0; var histMatchesPowerOfTwo = true;
var multiPeakCounts = 0;
var n = 0;
while (n < N) {
  ignore MMR.append(st, MMR.hashLeaf(blockHash(n)));
  let count = n + 1;
  if (not isPowerOfTwo(count)) multiPeakCounts += 1;
  let root = switch (MMR.rootHash(st)) { case (?r) r; case null { assert false; loop {} } };
  assert (MMR.peakCount(st) == (if (isPowerOfTwo(count)) 1 else MMR.peakCount(st)) and (MMR.peakCount(st) > 1 or isPowerOfTwo(count)));
  var j = 0;
  while (j <= n) {
    let p = switch (MMR.generateProof(st, j)) { case (?x) x; case null { assert false; loop {} } };
    trials += 1;
    if (MMR.verifyProof(MMR.hashLeaf(blockHash(j)), p.siblings, j, root, p.peaks, p.peakIndex)) fixedOk += 1;
    if (Proof.verify(blockHash(j), j, p, root)) journalOk += 1;
    let h = historicalVerify(MMR.hashLeaf(blockHash(j)), p.siblings, j, root, p.peaks, p.peakIndex);
    if (h) histOk += 1 else histRejected += 1;
    if (h != isPowerOfTwo(count)) histMatchesPowerOfTwo := false;
    j += 1;
  };
  n += 1;
};
Debug.print("count: proofs generated over leaf counts 1..300 = " # Nat.toText(trials));
Debug.print("count: leaf counts with more than one peak = " # Nat.toText(multiPeakCounts));
Debug.print("count: fixed MerkleMMR.verifyProof accepted = " # Nat.toText(fixedOk));
Debug.print("count: JournalProof.verify accepted = " # Nat.toText(journalOk));
Debug.print("count: historical fold accepted (single-peak counts only) = " # Nat.toText(histOk));
Debug.print("count: historical fold rejected = " # Nat.toText(histRejected));
Debug.print("historical fold accepts exactly the power-of-two counts: " # (if (histMatchesPowerOfTwo) "yes" else "no"));
assert (fixedOk == trials and journalOk == trials);
assert (trials == N * (N + 1) / 2);
assert (histMatchesPowerOfTwo);
// 1+2+4+8+16+32+64+128+256 = 511 single-peak proofs among counts 1..300
assert (histOk == 511 and histRejected == trials - 511);
assert (multiPeakCounts == N - 9);

// tamper classes at the final root, for every leaf
let root = switch (MMR.rootHash(st)) { case (?r) r; case null { assert false; loop {} } };
var tamperTrials = 0; var tamperRejected = 0;
var i = 0;
while (i < N) {
  let p = switch (MMR.generateProof(st, i)) { case (?x) x; case null { assert false; loop {} } };
  let leaf = MMR.hashLeaf(blockHash(i));
  let lb = Blob.toArray(leaf);
  let flipped = Blob.fromArray(Array.tabulate<Nat8>(32, func(k) { if (k == i % 32) lb[k] ^ 0x80 else lb[k] }));
  let rb = Blob.toArray(root);
  let wrongRoot = Blob.fromArray(Array.tabulate<Nat8>(32, func(k) { if (k == 0) rb[k] ^ 0x01 else rb[k] }));
  let other = switch (MMR.generateProof(st, (i + 11) % N)) { case (?x) x; case null { assert false; loop {} } };
  tamperTrials += 4;
  if (not MMR.verifyProof(flipped, p.siblings, i, root, p.peaks, p.peakIndex)) tamperRejected += 1;
  if (not MMR.verifyProof(leaf, p.siblings, (i + 1) % N, root, p.peaks, p.peakIndex)) tamperRejected += 1;
  if (not MMR.verifyProof(leaf, p.siblings, i, wrongRoot, p.peaks, p.peakIndex)) tamperRejected += 1;
  if (not MMR.verifyProof(leaf, other.siblings, i, root, other.peaks, other.peakIndex)) tamperRejected += 1;
  i += 1;
};
Debug.print("count: tamper trials = " # Nat.toText(tamperTrials));
Debug.print("count: tampers rejected = " # Nat.toText(tamperRejected));
assert (tamperTrials == tamperRejected);
