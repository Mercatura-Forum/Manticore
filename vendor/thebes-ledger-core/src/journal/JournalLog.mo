/// JournalLog.mo — the Merkle-committed journal log.
///
/// Every journal event becomes one block: canonical bytes (Canonical.mo)
/// appended to a Region-backed StableLog, SHA-256 chained to its parent, and
/// committed as a leaf of a Merkle Mountain Range. The three primitives —
/// StableLog, MerkleMMR and the leaf/node domain separation — are the ones the
/// canonical ICRC-ME ledger already uses for its token block log (`src/ledger/`),
/// so a journal entry carries the same kind of O(log n) inclusion proof as a
/// token transfer. Nothing here is ever rewritten: the log has append and read,
/// no update and no delete.

import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Blob "mo:core/Blob";
import Principal "mo:core/Principal";
import List "mo:core/List";

import SLog "../ledger/StableLog";
import MMR "../ledger/MerkleMMR";

import T "JournalTypes";
import C "Canonical";
import Proof "JournalProof";

module {

  public type State = {
    var count : Nat;
    var lastHash : ?Blob;
    stableLog : SLog.State;
    mmr : MMR.State;
  };

  public func newState() : State {
    { var count = 0; var lastHash = null; stableLog = SLog.newState(); mmr = MMR.newState() }
  };

  public type Proof = { siblings : [Blob]; peakIndex : Nat; peaks : [Blob] };

  /// Append one event. Returns the committed block.
  public func append(state : State, timestamp : Nat64, caller : Principal, event : T.Event) : T.Block {
    let index = state.count;
    let parentHash = state.lastHash;
    let enc = C.encodeBlock(index, timestamp, caller, parentHash, event);
    let stored = SLog.append(state.stableLog, enc.bytes);
    if (stored != index) {
      // The StableLog and the block counter must never diverge; if they did,
      // indices would no longer address the bytes they were issued for.
      assert false;
    };
    ignore MMR.append(state.mmr, MMR.hashLeaf(enc.hash));
    state.count += 1;
    state.lastHash := ?enc.hash;
    { index; timestamp; caller; parentHash; hash = enc.hash; event }
  };

  public func length(state : State) : Nat { state.count };
  /// The first block still held: blocks below it left with an archive roll (`truncateThrough`).
  public func base(state : State) : Nat { SLog.base(state.stableLog) };

  /// Let every block at or below `hi` go: the bytes leave and their regions return to the log's
  /// pool; the hash chain, the MMR (every leaf and node kept, so proofs for archived blocks are
  /// still generated here) and the count are untouched. `get` and `rawBlock` answer null below the
  /// base from then on.
  public func truncateThrough(state : State, hi : Nat) { SLog.truncateThrough(state.stableLog, hi) };

  public func regionStats(state : State) : { regions : Nat; free : Nat; pages : Nat } { SLog.regionStats(state.stableLog) };

  /// Prune the MMR below the archived boundary: every node whose leaves are all at or below `hi`
  /// leaves, but for the frontier's roots and the subtrees of `MMR.KEPT_HEIGHT` or more, so a
  /// live block's proof is still whole here and an archived block's needs from the archive only
  /// the siblings inside its aligned block (`proofAbove`).
  public func pruneMmrThroughBlock(state : State, hi : Nat) { MMR.pruneThroughLeaf(state.mmr, hi + 1) };
  public func proofAbove(state : State, index : Nat) : ?{ lower : [?Blob]; siblings : [Blob]; fromHeight : Nat; peakIndex : Nat; peaks : [Blob]; treeHeight : Nat } { MMR.proofAbove(state.mmr, index, MMR.KEPT_HEIGHT) };
  public func mmrStats(state : State) : { leaves : Nat; nodes : Nat; prunedThroughLeaf : Nat; prunedThroughPos : Nat; chunks : Nat; freeChunks : Nat; kept : Nat; pages : Nat } { MMR.stats(state.mmr) };
  public func mmrKeptHeight() : Nat { MMR.KEPT_HEIGHT };
  public func tipHash(state : State) : ?Blob { state.lastHash };

  /// Raw stored bytes of a block (what an external verifier hashes).
  public func rawBlock(state : State, index : Nat) : ?Blob { SLog.get(state.stableLog, index) };

  /// Decoded block; null if absent or if the stored bytes fail their own hash check.
  public func get(state : State, index : Nat) : ?T.Block {
    switch (SLog.get(state.stableLog, index)) {
      case (?bytes) C.decodeBlock(bytes);
      case null null;
    }
  };

  /// Raw stored bytes of a contiguous range (for archival).
  public func rawRange(state : State, start : Nat, length : Nat) : [Blob] {
    let end = Nat.min(start + length, state.count);
    if (start >= end) return [];
    let out = List.empty<Blob>();
    var i = start;
    while (i < end) { switch (SLog.get(state.stableLog, i)) { case (?b) List.add(out, b); case null {} }; i += 1 };
    List.toArray(out)
  };

  public func getRange(state : State, start : Nat, length : Nat) : [T.Block] {
    let end = Nat.min(start + length, state.count);
    let out = List.empty<T.Block>();
    var i = start;
    while (i < end) {
      switch (get(state, i)) { case (?b) List.add(out, b); case null {} };
      i += 1;
    };
    List.toArray(out)
  };

  public func mmrRoot(state : State) : ?Blob { MMR.rootHash(state.mmr) };
  public func mmrPeakCount(state : State) : Nat { MMR.peakCount(state.mmr) };

  public func proof(state : State, index : Nat) : ?Proof { MMR.generateProof(state.mmr, index) };

  /// Local verification (the same arithmetic an external verifier performs),
  /// through JournalProof so the proof rules are stated in one place.
  public func verify(blockHash : Blob, index : Nat, p : Proof, root : Blob) : Bool {
    Proof.verify(blockHash, index, p, root)
  };

  /// Walk the hash chain from genesis and confirm every stored block decodes,
  /// carries the right index, and links to its predecessor. Returns the number
  /// of blocks checked and the first fault, if any.
  public func verifyChain(state : State) : { checked : Nat; fault : ?Text } {
    // from the base: the first retained block's parent hash is the last archived block's, which
    // the archive holds and the MMR commits; the walk here checks what is here
    var prev : ?Blob = null;
    var i = base(state);
    while (i < state.count) {
      switch (get(state, i)) {
        case null return { checked = i; fault = ?("block " # Nat.toText(i) # " does not decode or fails its hash check") };
        case (?b) {
          if (b.index != i) return { checked = i; fault = ?("block " # Nat.toText(i) # " carries index " # Nat.toText(b.index)) };
          if (i > base(state) and b.parentHash != prev) return { checked = i; fault = ?("block " # Nat.toText(i) # " parent hash mismatch") };
          prev := ?b.hash;
        };
      };
      i += 1;
    };
    if (prev != state.lastHash) return { checked = i; fault = ?"tip hash does not match last block" };
    { checked = i; fault = null }
  };
};
