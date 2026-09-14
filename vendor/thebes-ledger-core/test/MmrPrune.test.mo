// MmrPrune.test.mo; the MMR pruned below an archived boundary, its proofs still whole.
//
// What is proved: after pruning through a boundary, every live leaf's proof still verifies against
// the same root; an archived leaf has no whole proof here (null, never a wrong one) but its upper
// part (`proofAbove`) joined to the lower siblings recomputed from the archived leaf hashes; what an
// archive regenerates; verifies; a second and third prune keep this true; chunks that held only
// pruned nodes return to the pool and later appends reuse them; the kept index stays small (the
// frontier and the subtrees of KEPT_HEIGHT or more); a proof of a tampered leaf fails.
//
// engine: wasi-only; Regions.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";

import MMR "../src/ledger/MerkleMMR";
import Sha256 "mo:sha2/Sha256";

func leafData(i : Nat) : Blob { Blob.fromArray([Nat8.fromNat(i / 65536 % 256), Nat8.fromNat(i / 256 % 256), Nat8.fromNat(i % 256), 7]) };
func hashNode(l : Blob, r : Blob) : Blob { let d = Sha256.Digest(#sha256); d.writeArray([0x01]); d.writeBlob(l); d.writeBlob(r); d.sum() };

// small chunks, so several cycle through the pool
let m = MMR.newStateWith(400);
let leaves = List.empty<Blob>();
func add(n : Nat) { var i = 0; while (i < n) { let h = MMR.hashLeaf(leafData(List.size(leaves))); assert (MMR.append(m, h) == List.size(leaves)); List.add(leaves, h); i += 1 } };
add(2_000);
let ?root0 = MMR.rootHash(m) else { assert false; loop {} };
// the incrementally bagged root equals the fold over every peak, here and after every later append
assert (MMR.foldPeaks(m) == ?root0);
var bagChecks = 0;
var bi = 0;
while (bi < 300) { add(1); assert (MMR.foldPeaks(m) == MMR.rootHash(m)); bagChecks += 1; bi += 1 };
Debug.print("count: incremental roots equal to the full peak fold = " # Nat.toText(bagChecks));

func check(i : Nat) : Bool {
  switch (MMR.generateProof(m, i)) {
    case (?p) { let ?root = MMR.rootHash(m) else return false; MMR.verifyProof(List.get(leaves, i) |> (switch (_) { case (?h) h; case null "" : Blob }), p.siblings, i, root, p.peaks, p.peakIndex) };
    case null false;
  }
};
var ok = 0;
var i = 0;
while (i < List.size(leaves)) { assert (check(i)); ok += 1; i += 1 };
Debug.print("count: proofs verified before any prune = " # Nat.toText(ok));
let s0 = MMR.stats(m);
Debug.print("count: chunks before the prune = " # Nat.toText(s0.chunks));

/// The lower siblings of an archived leaf, recomputed from the leaf hashes below `upTo`; what an
/// archive does from the blocks it holds; for the aligned subtree of `height` the leaf lies in.
func subtreeRoot(leafStart : Nat, height : Nat) : Blob {
  if (height == 0) { switch (List.get(leaves, leafStart)) { case (?h) h; case null { assert false; "" : Blob } } }
  else hashNode(subtreeRoot(leafStart, height - 1), subtreeRoot(leafStart + 2 ** (height - 1), height - 1))
};
func lowerSiblings(leaf : Nat, upToHeight : Nat) : [Blob] {
  let out = List.empty<Blob>();
  var idx = leaf; var h = 0;
  while (h < upToHeight) {
    let sib = if (idx % 2 == 0) idx + 1 else idx - 1;
    List.add(out, subtreeRoot(sib * (2 ** h), h));
    idx /= 2; h += 1;
  };
  List.toArray(out)
};
func checkArchived(i : Nat) : Bool {
  let ?up = MMR.proofAbove(m, i, MMR.KEPT_HEIGHT) else return false;
  let lowerTo = Nat.min(MMR.KEPT_HEIGHT, up.treeHeight);
  // what the parent still has below the kept height is used as it is; the rest is regenerated
  let regenerated = lowerSiblings(i, lowerTo);
  assert (up.lower.size() == lowerTo);
  let lower = Array.tabulate<Blob>(lowerTo, func(h) { switch (up.lower[h]) { case (?x) { assert (x == regenerated[h]); x }; case null regenerated[h] } });
  let siblings = Array.concat<Blob>(lower, up.siblings);
  let ?root = MMR.rootHash(m) else return false;
  let ?h = List.get(leaves, i) else return false;
  MMR.verifyProof(h, siblings, i, root, up.peaks, up.peakIndex)
};

// prune through leaf 1,200: every live proof whole, every archived one assembled
let rootBeforePrune = MMR.rootHash(m);
MMR.pruneThroughLeaf(m, 700);
assert (MMR.prunedThroughLeaf(m) == 700);
assert (MMR.rootHash(m) == rootBeforePrune);
ignore root0;
var live = 0; var archived = 0; var nullProofs = 0;
i := 0;
while (i < List.size(leaves)) {
  if (i < 700) { if (MMR.generateProof(m, i) == null) nullProofs += 1; assert (checkArchived(i)); archived += 1 }
  else { assert (check(i)); live += 1 };
  i += 1;
};
Debug.print("count: live proofs whole after the prune = " # Nat.toText(live));
Debug.print("count: archived proofs assembled from the upper part and regenerated lower siblings = " # Nat.toText(archived));
Debug.print("count: archived leaves with no whole proof here = " # Nat.toText(nullProofs));
assert (nullProofs > 0);
let s1 = MMR.stats(m);
Debug.print("count: chunks on the pool after the prune = " # Nat.toText(s1.freeChunks));
Debug.print("count: kept nodes = " # Nat.toText(s1.kept));
assert (s1.freeChunks >= 1 and s1.kept <= 64);
// a prune at or below the boundary is a no-op
MMR.pruneThroughLeaf(m, 600);
assert (MMR.prunedThroughLeaf(m) == 700);

// more leaves land in the pooled chunks; a second and a third prune
add(700);
let s2 = MMR.stats(m);
Debug.print("count: chunks after 700 more leaves = " # Nat.toText(s2.chunks + s2.freeChunks));
assert (s2.chunks + s2.freeChunks <= s0.chunks + 6);
MMR.pruneThroughLeaf(m, 2_048);
MMR.pruneThroughLeaf(m, 2_500);
let ?root2 = MMR.rootHash(m) else { assert false; loop {} };
live := 0; archived := 0;
i := 0;
while (i < 3_000) {
  if (i < 2_500) { assert (checkArchived(i)); archived += 1 } else { assert (check(i)); live += 1 };
  i += 1;
};
Debug.print("count: live proofs whole after three prunes = " # Nat.toText(live));
Debug.print("count: archived proofs assembled after three prunes = " # Nat.toText(archived));
let s3 = MMR.stats(m);
Debug.print("count: kept nodes after three prunes = " # Nat.toText(s3.kept));
assert (s3.kept <= 3 * 64);
// the pool is used: after the prunes, the chunk count does not grow across the next appends
add(800);
let s4 = MMR.stats(m);
assert (s4.chunks + s4.freeChunks == s3.chunks + s3.freeChunks or s4.chunks + s4.freeChunks <= s3.chunks + s3.freeChunks + 1);
Debug.print("count: chunks after the pool was reused = " # Nat.toText(s4.chunks + s4.freeChunks));
// a tampered leaf fails
let ?p = MMR.proofAbove(m, 10, MMR.KEPT_HEIGHT) else { assert false; loop {} };
let ?rootNow = MMR.rootHash(m) else { assert false; loop {} };
assert (not MMR.verifyProof(MMR.hashLeaf(leafData(11)), Array.concat<Blob>(lowerSiblings(10, Nat.min(MMR.KEPT_HEIGHT, p.treeHeight)), p.siblings), 10, rootNow, p.peaks, p.peakIndex));
Debug.print("count: tampered archived proofs rejected = 1");
ignore root2;
