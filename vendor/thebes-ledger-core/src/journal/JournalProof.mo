/// JournalProof.mo; verification of a journal entry's inclusion proof.
///
/// The proof format is the one `src/ledger/MerkleMMR.generateProof` emits:
///   siblings   hashes along the path from the leaf to its peak, bottom-up
///   peaks      every peak of the mountain range, highest (leftmost) first
///   peakIndex  which of those peaks the leaf's path ends at
///
/// Hashing (matching MerkleMMR.mo, the canonical ICRC-ME ledger):
///   leaf  = SHA-256(0x00 || blockHash)
///   node  = SHA-256(0x01 || left || right)
///   root  = fold over peaks from the HIGHEST peak: acc := peak_high;
///           for each lower peak p: acc := node(p, acc)
///
/// That fold is exactly `MerkleMMR.recomputeBaggedRoot`. The ICRC-ME
/// `MerkleMMR.verifyProof` as imported folded the peaks in the opposite order
/// and rejected every valid proof of a range with two or more peaks (every leaf
/// count that is not a power of two); it is fixed in this repository's copy
/// (see test/MmrVerifyProof.test.mo)
/// proves both verifiers agree over leaf counts 1..300. This module stays the
/// journal's verifier so the proof rules are stated in one place.
///
/// An external verifier reimplements these four rules; nothing else is needed.

import Blob "mo:core/Blob";
import Sha256 "mo:sha2/Sha256";

module {

  public type Proof = { siblings : [Blob]; peakIndex : Nat; peaks : [Blob] };

  public func hashLeaf(blockHash : Blob) : Blob {
    let d = Sha256.Digest(#sha256);
    d.writeArray([0x00]);
    d.writeBlob(blockHash);
    d.sum()
  };

  public func hashNode(left : Blob, right : Blob) : Blob {
    let d = Sha256.Digest(#sha256);
    d.writeArray([0x01]);
    d.writeBlob(left);
    d.writeBlob(right);
    d.sum()
  };

  /// Root of a mountain range from its peaks, highest peak first.
  public func bagPeaks(peaks : [Blob]) : ?Blob {
    var acc : ?Blob = null;
    for (p in peaks.vals()) {
      acc := switch (acc) { case null ?p; case (?a) ?hashNode(p, a) };
    };
    acc
  };

  /// Climb from the leaf to its peak using the sibling path.
  public func climb(leafHash : Blob, leafIndex : Nat, siblings : [Blob]) : Blob {
    var current = leafHash;
    var idx = leafIndex;
    for (sib in siblings.vals()) {
      current := if (idx % 2 == 0) hashNode(current, sib) else hashNode(sib, current);
      idx /= 2;
    };
    current
  };

  /// True iff `blockHash` is the leaf at `leafIndex` of a range whose root is `root`.
  public func verify(blockHash : Blob, leafIndex : Nat, proof : Proof, root : Blob) : Bool {
    if (proof.peakIndex >= proof.peaks.size()) return false;
    let peak = climb(hashLeaf(blockHash), leafIndex, proof.siblings);
    if (peak != proof.peaks[proof.peakIndex]) return false;
    switch (bagPeaks(proof.peaks)) {
      case (?r) r == root;
      case null false;
    }
  };
};
