/// BankLog.mo — the Merkle-committed log of banking decisions.
///
/// The same construction as the journal's own log (`mo:journal/JournalLog`):
/// canonical bytes appended to a Region-backed StableLog, SHA-256 chained to the
/// parent, and committed as a leaf of a Merkle Mountain Range. `StableLog` and
/// `MerkleMMR` come from the canonical ICRC-ME family carried by the pinned
/// submodule (MIT; see NOTICE) and are called, not reproduced. Proof
/// verification goes through the journal's `JournalProof`, so the peak-bagging
/// rule that phase the journal fixed is stated in exactly one place for both logs.
///
/// Append and read; no update, no delete of a block's content. A decision, once recorded, is as
/// immutable as a posting. Since the bank-log ruling of 12 September (measure 2) a **prefix can leave**
/// the `StableLog` once a pack holds it (`truncateThrough`): `get` answers null below the base the way it
/// does past the end, and the bank reads those blocks from the pack (`Packing.bankBlock`). The MMR keeps
/// every leaf, so a packed block still proves against the certified root.

import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import List "mo:core/List";

import SLog "mo:ledger/StableLog";
import MMR "mo:ledger/MerkleMMR";
import Proof "mo:journal/JournalProof";

import T "BankTypes";
import C "BankCanonical";

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
  /// Pages the log's regions and its MMR hold.
  public func regionPages(state : State) : Nat { SLog.regionStats(state.stableLog).pages + MMR.stats(state.mmr).pages };
  public func tipHash(state : State) : ?Blob { state.lastHash };

  public func rawBlock(state : State, index : Nat) : ?Blob { SLog.get(state.stableLog, index) };

  /// The first block the `StableLog` still holds; blocks below it are the packs'.
  public func base(state : State) : Nat { SLog.base(state.stableLog) };

  /// The prefix through `hi` leaves the `StableLog` and its regions go back to the pool; the count, the
  /// tip and the MMR are unchanged. The caller has the bytes in a pack before it calls.
  public func truncateThrough(state : State, hi : Nat) { SLog.truncateThrough(state.stableLog, hi) };

  public func get(state : State, index : Nat) : ?T.Block {
    switch (SLog.get(state.stableLog, index)) {
      case (?bytes) C.decodeBlock(bytes);
      case null null;
    }
  };

  /// A block's stored bytes: the log's, or — below the base — what `below` answers (the packs).
  public func rawBlockWith(state : State, below : Nat -> ?Blob, index : Nat) : ?Blob {
    switch (SLog.get(state.stableLog, index)) { case (?b) ?b; case null { if (index < state.count) below(index) else null } }
  };
  public func getWith(state : State, below : Nat -> ?Blob, index : Nat) : ?T.Block {
    switch (rawBlockWith(state, below, index)) { case (?bytes) C.decodeBlock(bytes); case null null }
  };

  public func getRange(state : State, start : Nat, length_ : Nat) : [T.Block] { getRangeWith(state, func(_ : Nat) : ?Blob { null }, start, length_) };
  public func getRangeWith(state : State, below : Nat -> ?Blob, start : Nat, length_ : Nat) : [T.Block] {
    let end = Nat.min(start + length_, state.count);
    let out = List.empty<T.Block>();
    var i = start;
    while (i < end) {
      switch (getWith(state, below, i)) { case (?b) List.add(out, b); case null {} };
      i += 1;
    };
    List.toArray(out)
  };

  public func mmrRoot(state : State) : ?Blob { MMR.rootHash(state.mmr) };
  public func mmrPeakCount(state : State) : Nat { MMR.peakCount(state.mmr) };
  public func proof(state : State, index : Nat) : ?Proof { MMR.generateProof(state.mmr, index) };

  public func verify(blockHash : Blob, index : Nat, p : Proof, root : Blob) : Bool {
    Proof.verify(blockHash, index, p, root)
  };

  /// Walk the chain from genesis: every block decodes, carries its own index and
  /// links to its predecessor. Returns how many were checked and the first fault.
  public func verifyChain(state : State) : { checked : Nat; fault : ?Text } { verifyChainWith(state, func(_ : Nat) : ?Blob { null }) };
  public func verifyChainWith(state : State, below : Nat -> ?Blob) : { checked : Nat; fault : ?Text } {
    var prev : ?Blob = null;
    var i = 0;
    while (i < state.count) {
      switch (getWith(state, below, i)) {
        case null return { checked = i; fault = ?("bank block " # Nat.toText(i) # " does not decode or fails its hash check") };
        case (?b) {
          if (b.index != i) return { checked = i; fault = ?("bank block " # Nat.toText(i) # " carries index " # Nat.toText(b.index)) };
          if (b.parentHash != prev) return { checked = i; fault = ?("bank block " # Nat.toText(i) # " parent hash mismatch") };
          prev := ?b.hash;
        };
      };
      i += 1;
    };
    if (prev != state.lastHash) return { checked = i; fault = ?"bank tip hash does not match last block" };
    { checked = i; fault = null }
  };
};
