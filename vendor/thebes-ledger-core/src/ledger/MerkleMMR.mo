/// MerkleMMR.mo — Merkle Mountain Range for O(log n) inclusion proofs
///
/// Leaf hashes and internal node hashes are stored in Region stable memory.
/// Proof generation reads O(log n) hashes from Region — no recomputation.
///
/// Storage layout in Region:
///   Positions 0..N-1 map to MMR node positions (not leaf indices).
///   MMR position numbering follows the standard post-order scheme:
///     Leaf 0 → pos 0, Leaf 1 → pos 1, Internal → pos 2,
///     Leaf 2 → pos 3, etc.
///   Each position stores a 32-byte SHA-256 hash.
///
/// This gives O(1) append, O(log n) proof, O(log n) root computation.
///
/// **Pruning below an archived boundary.** The nodes live in a pool of region chunks, and every
/// node whose leaves are all below `prunedThroughLeaf` may leave: in post-order those are exactly
/// the positions before the boundary leaf's own, so pruning is a prefix and whole chunks return
/// to the pool. What is kept of the prefix, in a side index by position: the roots of the aligned
/// subtrees that decompose the archived range (the siblings a live leaf's proof needs), and every
/// node whose subtree holds at least `KEPT_SUBTREE_LEAVES` leaves — so a proof for an archived
/// leaf needs from an archive only the siblings below that height, inside the leaf's own aligned
/// block, which the archive regenerates from the blocks it holds (`proofAbove`).

import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Blob "mo:core/Blob";
import VarArray "mo:core/VarArray";
import List "mo:core/List";
import Region "mo:core/Region";
import Runtime "mo:core/Runtime";
import Map "mo:core/Map";

import RI "RegionIndex";

import Sha256 "mo:sha2/Sha256";

module {

  let HASH_SIZE : Nat64 = 32;
  let MAX_HEIGHT : Nat = 64;

  /// Nodes a chunk holds: 32 MiB of hashes.
  public let CHUNK_NODES : Nat = 1_048_576;
  /// A node whose subtree holds at least this many leaves stays after pruning: 2^16.
  public let KEPT_SUBTREE_LEAVES : Nat = 65_536;
  public let KEPT_HEIGHT : Nat = 16;

  public type State = {
    var peaks : [var ?Blob];
    var leafCount : Nat;
    var nodeCount : Nat;       // total MMR nodes (leaves + internals)
    var baggedRoot : ?Blob;    // pre-computed root hash — O(1) access
    /// `bagAbove[h]` is the fold of the peaks above height h, highest first — what the root's fold
    /// has reached before it takes peak h. An append changes peaks only at and below its merge
    /// height, so the root is one hash from the fold above that height, not one per peak.
    var bagAbove : [var ?Blob];
    /// The node chunks: chunk c holds positions [c·chunkNodes, (c+1)·chunkNodes).
    chunks : Map.Map<Nat, Region.Region>;
    free : List.List<Region.Region>;
    chunkNodes : Nat;
    /// Positions below this have been pruned: their hashes are in `kept` or gone.
    var prunedThroughPos : Nat;
    var prunedThroughLeaf : Nat;
    keptArena : RI.Arena;
    /// pos(8) -> hash(32): what stays of the pruned prefix.
    kept : RI.State;
  };

  public func newState() : State { newStateWith(CHUNK_NODES) };

  /// A state whose chunks hold `chunkNodes` nodes — the tests use small chunks to see them cycle.
  public func newStateWith(chunkNodes : Nat) : State {
    let keptArena = RI.newArena();
    {
      var peaks = VarArray.repeat<?Blob>(null, MAX_HEIGHT);
      var leafCount = 0;
      var nodeCount = 0;
      var baggedRoot : ?Blob = null;
      var bagAbove = VarArray.repeat<?Blob>(null, MAX_HEIGHT + 1);
      chunks = Map.empty<Nat, Region.Region>();
      free = List.empty<Region.Region>();
      chunkNodes;
      var prunedThroughPos = 0;
      var prunedThroughLeaf = 0;
      keptArena;
      kept = RI.newStateIn(keptArena, { keyBytes = 8; valBytes = 32 });
    };
  };

  func growIfNeeded(region : Region.Region, needed : Nat64) {
    let pages = (needed / 65536) + 1;
    if (pages > Region.size(region)) {
      let g = Region.grow(region, pages - Region.size(region));
      if (g == 0xFFFF_FFFF_FFFF_FFFF) Runtime.trap("MerkleMMR: memory exhausted");
    };
  };

  func chunkFor(state : State, pos : Nat) : Region.Region {
    let c = pos / state.chunkNodes;
    switch (Map.get(state.chunks, Nat.compare, c)) {
      case (?r) r;
      case null {
        let r = switch (List.removeLast(state.free)) { case (?r) r; case null Region.new() };
        Map.add(state.chunks, Nat.compare, c, r);
        r
      };
    }
  };

  func storeHash(state : State, pos : Nat, hash : Blob) {
    let region = chunkFor(state, pos);
    let off = Nat64.fromNat(pos % state.chunkNodes) * HASH_SIZE;
    growIfNeeded(region, off + HASH_SIZE);
    Region.storeBlob(region, off, hash);
  };

  func posKey(pos : Nat) : Blob { Blob.fromArray(RI.beBytes(pos, 8)) };

  /// A node's hash: from its chunk when it is live, from the kept index when it was pruned and
  /// kept, and null when it is gone.
  public func nodeHash(state : State, pos : Nat) : ?Blob {
    if (pos >= state.nodeCount) return null;
    if (pos < state.prunedThroughPos) return RI.get(state.kept, posKey(pos));
    switch (Map.get(state.chunks, Nat.compare, pos / state.chunkNodes)) {
      case (?r) ?Region.loadBlob(r, Nat64.fromNat(pos % state.chunkNodes) * HASH_SIZE, 32);
      case null null;
    }
  };

  func loadHash(state : State, pos : Nat) : Blob {
    switch (nodeHash(state, pos)) { case (?h) h; case null Runtime.trap("MerkleMMR: node " # Nat.toText(pos) # " was pruned") }
  };

  // ═══════════════════════════════════════════════════════
  //  HASH PRIMITIVES
  // ═══════════════════════════════════════════════════════

  /// The internal-node hash, public so an archive regenerating a subtree hashes the same way.
  public func hashInternal(left : Blob, right : Blob) : Blob { hashNode(left, right) };

  func hashNode(left : Blob, right : Blob) : Blob {
    let digest = Sha256.Digest(#sha256);
    digest.writeArray([0x01]);
    digest.writeBlob(left);
    digest.writeBlob(right);
    digest.sum()
  };

  public func hashLeaf(data : Blob) : Blob {
    let digest = Sha256.Digest(#sha256);
    digest.writeArray([0x00]);
    digest.writeBlob(data);
    digest.sum()
  };

  // ═══════════════════════════════════════════════════════
  //  MMR POSITION ARITHMETIC
  //
  //  Standard MMR uses post-order positions:
  //    Height 0 (leaves): positions where all bits below height are 0
  //    The position of leaf i: i * 2 + popcount of merged trees
  //
  //  Simpler approach: store nodes sequentially as they're created.
  //  Leaf positions and internal positions interleave naturally.
  //  Track with a running counter (nodeCount).
  // ═══════════════════════════════════════════════════════

  /// Append a leaf hash. Stores leaf + all internal nodes created by merging.
  /// O(log n) amortized. Returns the leaf index (0-based).
  public func append(state : State, leafHash : Blob) : Nat {
    let leafIdx = state.leafCount;
    // Store leaf node
    let leafPos = state.nodeCount;
    storeHash(state, leafPos, leafHash);
    state.nodeCount += 1;

    var current = leafHash;
    var height : Nat = 0;
    while (height < MAX_HEIGHT) {
      switch (state.peaks[height]) {
        case (?existing) {
          // Merge: create internal node
          current := hashNode(existing, current);
          let internalPos = state.nodeCount;
          storeHash(state, internalPos, current);
          state.nodeCount += 1;
          state.peaks[height] := null;
          height += 1;
        };
        case null {
          state.peaks[height] := ?current;
          state.leafCount += 1;
          rebagFrom(state, height);
          return leafIdx;
        };
      };
    };
    state.leafCount += 1;
    rebagFrom(state, MAX_HEIGHT - 1);
    leafIdx
  };

  /// The root after an append that set the peak at `height` and cleared every peak below it: the
  /// fold above `height` is what it was; one hash takes the new peak; the heights below, now
  /// empty, see the same fold. One SHA-256 per append instead of one per peak (the measured runs
  /// found the per-peak fold to be a fifth of a posting's cost).
  func rebagFrom(state : State, height : Nat) {
    let ?peak = state.peaks[height] else Runtime.trap("MerkleMMR: rebag at a height with no peak");
    let acc = switch (state.bagAbove[height]) { case null peak; case (?above) hashNode(peak, above) };
    var h = height;
    while (h > 0) { h -= 1; state.bagAbove[h] := ?acc };
    state.baggedRoot := ?acc;
  };

  /// The fold of every peak, highest first — what `rebagFrom` maintains incrementally; the tests
  /// compare the two.
  public func foldPeaks(state : State) : ?Blob {
    var result : ?Blob = null;
    var h : Nat = MAX_HEIGHT;
    while (h > 0) {
      h -= 1;
      switch (state.peaks[h]) {
        case (?peak) { result := switch (result) { case null ?peak; case (?acc) ?hashNode(peak, acc) } };
        case null {};
      };
    };
    result
  };

  /// Root hash — O(1) via pre-computed bagged root.
  public func rootHash(state : State) : ?Blob { state.baggedRoot };

  public func peakCount(state : State) : Nat {
    var count : Nat = 0;
    for (p in state.peaks.vals()) {
      switch (p) { case (?_) count += 1; case null {} };
    };
    count
  };

  /// Generate inclusion proof for a leaf. O(log n) Region reads.
  ///
  /// Strategy: Given leafIndex, we know the leaf's position in the MMR.
  /// The MMR node positions follow a predictable pattern based on the
  /// binary representation of the leaf count at insertion time.
  /// For each level of the proof, we compute the sibling's position
  /// and read its stored hash directly. No subtree recomputation needed.
  public func generateProof(
    state : State,
    leafIndex : Nat,
  ) : ?{ siblings : [Blob]; peakIndex : Nat; peaks : [Blob] } {
    if (leafIndex >= state.leafCount) return null;

    // Find which peak-tree contains this leaf
    var treeStart : Nat = 0;
    var treeHeight : Nat = 0;
    var found = false;
    var peakHeightIdx : Nat = 0;
    // Also track the MMR node position where this tree starts
    var treeNodeStart : Nat = 0;

    var h : Nat = MAX_HEIGHT;
    while (h > 0 and not found) {
      h -= 1;
      switch (state.peaks[h]) {
        case (?_) {
          let treeSize = 2 ** h; // number of leaves in this tree
          if (leafIndex < treeStart + treeSize) {
            treeHeight := h;
            peakHeightIdx := h;
            found := true;
          } else {
            treeStart += treeSize;
            // A perfect binary tree with 2^h leaves has 2^(h+1)-1 nodes
            treeNodeStart += 2 ** (h + 1) - 1;
          };
        };
        case null {};
      };
    };

    if (not found) return null;

    // Compute proof path using MMR node positions.
    // In a perfect binary tree stored in level-order within our sequential layout:
    //   - Leaves are at positions treeNodeStart + 0, +2, +4, ... (stride 2)
    //   - But we stored in creation order (post-order), not level-order.
    //
    // Simpler approach: rebuild the sibling path using the stored hashes.
    // At each level, compute the sibling subtree hash from stored nodes.
    // For a perfect binary tree, the sibling at level k needs 2^k leaf hashes
    // and we can read the stored internal node hash directly if we track positions.
    //
    // Most efficient: compute positions of all siblings using the binary structure.
    // The MMR node for a subtree root at height h containing 2^h leaves
    // is at a position we can calculate from (treeNodeStart, localIndex, height).
    let siblings = List.empty<Blob>();
    let localIndex = leafIndex - treeStart;

    // Walk the tree bottom-up. At each level, find sibling hash.
    // Use recursive subtree hash computation — but only read the ROOT of the sibling,
    // which is already stored in Region (stored during append).
    // The root of a subtree = the last node stored in that subtree's range.
    var idx = localIndex;
    var currentHeight : Nat = 0;
    while (currentHeight < treeHeight) {
      let subtreeLeaves = 2 ** currentHeight;
      let sibIdx = if (idx % 2 == 0) idx + 1 else idx - 1;
      // Compute the node position of the sibling subtree's root.
      // In our sequential storage, a subtree of height h starting at leaf offset L
      // within the tree has its root at:
      //   treeNodeStart + subtreeRootPos(L, h, treeHeight)
      let sibLeafStart = sibIdx * subtreeLeaves;
      let sibRootPos = subtreeRootPosition(treeNodeStart, sibLeafStart, currentHeight, treeHeight);
      // a sibling that was pruned and not kept: no proof from here (see `proofAbove`)
      let ?sib = nodeHash(state, sibRootPos) else return null;
      List.add(siblings, sib);
      idx /= 2;
      currentHeight += 1;
    };

    // Collect peaks
    let peakList = List.empty<Blob>();
    var peakIdx : Nat = 0;
    var targetPeakIdx : Nat = 0;
    var pi : Nat = MAX_HEIGHT;
    while (pi > 0) {
      pi -= 1;
      switch (state.peaks[pi]) {
        case (?peak) {
          List.add(peakList, peak);
          if (pi == peakHeightIdx) { targetPeakIdx := peakIdx };
          peakIdx += 1;
        };
        case null {};
      };
    };

    ?{
      siblings = List.toArray(siblings);
      peakIndex = targetPeakIdx;
      peaks = List.toArray(peakList);
    }
  };

  // ═══════════════════════════════════════════════════════
  //  PRUNING
  // ═══════════════════════════════════════════════════════

  /// The peak tree a leaf lies in: its first leaf, its height, and the position its nodes start at.
  func treeOf(state : State, leafIndex : Nat) : ?{ treeStart : Nat; treeHeight : Nat; treeNodeStart : Nat } {
    var treeStart : Nat = 0;
    var treeNodeStart : Nat = 0;
    var h : Nat = MAX_HEIGHT;
    while (h > 0) {
      h -= 1;
      switch (state.peaks[h]) {
        case (?_) {
          let treeSize = 2 ** h;
          if (leafIndex < treeStart + treeSize) return ?{ treeStart; treeHeight = h; treeNodeStart };
          treeStart += treeSize;
          treeNodeStart += 2 ** (h + 1) - 1;
        };
        case null {};
      };
    };
    null
  };

  /// The position of the root of the aligned subtree of `height` starting at `leafStart`.
  public func subtreePosition(state : State, leafStart : Nat, height : Nat) : ?Nat {
    let ?t = treeOf(state, leafStart) else return null;
    if (height > t.treeHeight or (leafStart - t.treeStart) % (2 ** height) != 0) return null;
    ?subtreeRootPosition(t.treeNodeStart, leafStart - t.treeStart, height, t.treeHeight)
  };

  public func leafPosition(state : State, leafIndex : Nat) : ?Nat { subtreePosition(state, leafIndex, 0) };

  /// The roots of the aligned subtrees that decompose `[0, upTo)`, highest first: what a live
  /// leaf's proof needs of the archived range.
  public func frontier(upTo : Nat) : [(Nat, Nat)] {
    let out = List.empty<(Nat, Nat)>();   // (leafStart, height)
    var at = 0;
    var h = MAX_HEIGHT;
    while (at < upTo and h > 0) {
      h -= 1;
      let size = 2 ** h;
      if (at % size == 0 and at + size <= upTo) { List.add(out, (at, h)); at += size; h := MAX_HEIGHT };
    };
    List.toArray(out)
  };

  /// Let every node whose leaves are all below `upToLeaf` go, keeping the frontier's roots and
  /// every archived node whose subtree holds at least `KEPT_SUBTREE_LEAVES` leaves. Chunks that
  /// held only pruned positions return to the pool. A boundary at or below the last one is a no-op.
  public func pruneThroughLeaf(state : State, upToLeaf : Nat) {
    if (upToLeaf > state.leafCount) Runtime.trap("MerkleMMR: pruning past the leaves");
    if (upToLeaf <= state.prunedThroughLeaf or upToLeaf == 0) return;
    let ?boundary = (if (upToLeaf == state.leafCount) ?state.nodeCount else leafPosition(state, upToLeaf)) else Runtime.trap("MerkleMMR: no position for the boundary leaf");
    // what stays: the frontier roots (any height), and every aligned subtree of KEPT_HEIGHT or more
    // whose leaves are all archived and whose root is not yet kept
    func keep(leafStart : Nat, height : Nat) {
      let ?pos = subtreePosition(state, leafStart, height) else Runtime.trap("MerkleMMR: a kept subtree with no position");
      if (pos < state.prunedThroughPos) return;   // already kept, or gone by an earlier prune
      ignore RI.put(state.kept, posKey(pos), loadHash(state, pos));
    };
    for ((leafStart, height) in frontier(upToLeaf).vals()) keep(leafStart, height);
    var h = KEPT_HEIGHT;
    while (h < MAX_HEIGHT) {
      let size = 2 ** h;
      // aligned subtrees of this height fully inside [0, upToLeaf) whose root lies at or past the
      // last boundary: those ending after the previous boundary leaf
      var start = (state.prunedThroughLeaf / size) * size;
      while (start + size <= upToLeaf) {
        if (start + size > state.prunedThroughLeaf) {
          switch (subtreePosition(state, start, h)) { case (?_) keep(start, h); case null {} };
        };
        start += size;
      };
      h += 1;
    };
    // the frontier roots of the previous boundary that are no longer frontier roots stay kept:
    // they are either below KEPT_HEIGHT (a handful) or kept by height anyway
    state.prunedThroughPos := boundary;
    state.prunedThroughLeaf := upToLeaf;
    // chunks entirely below the boundary go back to the pool
    let done = List.empty<Nat>();
    for ((c, r) in Map.entries(state.chunks)) { if ((c + 1) * state.chunkNodes <= boundary) { List.add(done, c); List.add(state.free, r) } };
    for (c in List.values(done)) ignore Map.delete(state.chunks, Nat.compare, c);
  };

  public func prunedThroughLeaf(state : State) : Nat { state.prunedThroughLeaf };

  /// The upper part of an archived leaf's proof: the siblings from `fromHeight` up (which the kept
  /// nodes and the live chunks answer for every archived leaf when `fromHeight` is `KEPT_HEIGHT`),
  /// the peaks and the peak index. The siblings below come from the archive holding the leaf's
  /// aligned block of `2^fromHeight` leaves, and the two halves make a proof `verifyProof` accepts.
  public func proofAbove(state : State, leafIndex : Nat, fromHeight : Nat) : ?{ lower : [?Blob]; siblings : [Blob]; fromHeight : Nat; peakIndex : Nat; peaks : [Blob]; treeHeight : Nat } {
    if (leafIndex >= state.leafCount) return null;
    let ?t = treeOf(state, leafIndex) else return null;
    let localIndex = leafIndex - t.treeStart;
    // below `fromHeight`: what is still here — a sibling whose subtree holds a live leaf always is
    let lower = List.empty<?Blob>();
    var li = localIndex;
    var lh = 0;
    while (lh < fromHeight and lh < t.treeHeight) {
      let sibIdx = if (li % 2 == 0) li + 1 else li - 1;
      List.add(lower, nodeHash(state, subtreeRootPosition(t.treeNodeStart, sibIdx * (2 ** lh), lh, t.treeHeight)));
      li /= 2;
      lh += 1;
    };
    let siblings = List.empty<Blob>();
    var idx = localIndex / (2 ** fromHeight);
    var currentHeight = fromHeight;
    while (currentHeight < t.treeHeight) {
      let subtreeLeaves = 2 ** currentHeight;
      let sibIdx = if (idx % 2 == 0) idx + 1 else idx - 1;
      let ?sib = nodeHash(state, subtreeRootPosition(t.treeNodeStart, sibIdx * subtreeLeaves, currentHeight, t.treeHeight)) else return null;
      List.add(siblings, sib);
      idx /= 2;
      currentHeight += 1;
    };
    let peakList = List.empty<Blob>();
    var peakIdx : Nat = 0;
    var targetPeakIdx : Nat = 0;
    var pi : Nat = MAX_HEIGHT;
    while (pi > 0) {
      pi -= 1;
      switch (state.peaks[pi]) {
        case (?peak) { List.add(peakList, peak); if (pi == t.treeHeight) targetPeakIdx := peakIdx; peakIdx += 1 };
        case null {};
      };
    };
    ?{ lower = List.toArray(lower); siblings = List.toArray(siblings); fromHeight; peakIndex = targetPeakIdx; peaks = List.toArray(peakList); treeHeight = t.treeHeight }
  };

  public func stats(state : State) : { leaves : Nat; nodes : Nat; prunedThroughLeaf : Nat; prunedThroughPos : Nat; chunks : Nat; freeChunks : Nat; kept : Nat; pages : Nat } {
    var pages : Nat64 = 0;
    for ((_, r) in Map.entries(state.chunks)) pages += Region.size(r);
    for (r in List.values(state.free)) pages += Region.size(r);
    { leaves = state.leafCount; nodes = state.nodeCount; prunedThroughLeaf = state.prunedThroughLeaf; prunedThroughPos = state.prunedThroughPos; chunks = Map.size(state.chunks); freeChunks = List.size(state.free); kept = RI.size(state.kept); pages = Nat64.toNat(pages) + RI.arenaStats(state.keptArena).pages }
  };

  /// Compute the node position of a subtree root within the sequential MMR layout.
  /// A perfect binary tree of height H stored in post-order has 2^(H+1)-1 nodes.
  /// The root is the LAST node. For a subtree at height h starting at leaf offset
  /// leafStart within a tree of height treeHeight:
  ///   - The subtree spans nodes [start..start + 2^(h+1) - 2]
  ///   - The root is at start + 2^(h+1) - 2
  func subtreeRootPosition(treeNodeStart : Nat, leafStart : Nat, subtreeHeight : Nat, treeHeight : Nat) : Nat {
    // In our post-order layout, leaf i of the tree is at position:
    //   treeNodeStart + nodePositionInTree(i, treeHeight)
    // A subtree rooted at height h covering leaves [L..L+2^h-1] has its root
    // at the position of the last node in that subtree.
    //
    // For a post-order traversal of a perfect binary tree:
    //   nodePosition(leafStart, height) gives us the start of the subtree
    //   The root of height-h subtree starting at leaf L is at:
    //   sum of nodes in all complete subtrees before L, plus 2^(h+1)-2
    var pos = treeNodeStart;
    // Walk the path from root to the subtree, accumulating node offsets
    var currentLeafStart : Nat = 0;
    var currentHeight = treeHeight;
    let targetLeafStart = leafStart;

    while (currentHeight > subtreeHeight) {
      let halfLeaves = 2 ** (currentHeight - 1);
      let leftSubtreeNodes = 2 ** currentHeight - 1; // nodes in left child
      if (targetLeafStart < currentLeafStart + halfLeaves) {
        // Go left — skip nothing, left subtree starts at pos
        currentHeight -= 1;
      } else {
        // Go right — skip left subtree + left subtree's nodes
        pos += leftSubtreeNodes;
        currentLeafStart += halfLeaves;
        currentHeight -= 1;
      };
    };
    // Now at the subtree root level. The root of a post-order subtree
    // of height h is the LAST node: pos + 2^(h+1) - 2
    pos + 2 ** (subtreeHeight + 1) - 2
  };

  /// Verify an inclusion proof.
  public func verifyProof(
    leafHash : Blob,
    siblings : [Blob],
    leafIndex : Nat,
    expectedRoot : Blob,
    peaks : [Blob],
    peakIndex : Nat,
  ) : Bool {
    var current = leafHash;
    var idx = leafIndex;
    for (sib in siblings.vals()) {
      if (idx % 2 == 0) {
        current := hashNode(current, sib);
      } else {
        current := hashNode(sib, current);
      };
      idx /= 2;
    };

    if (peakIndex >= peaks.size()) return false;
    if (current != peaks[peakIndex]) return false;

    // Bag the peaks in the order generateProof returns them (highest first),
    // exactly as recomputeBaggedRoot does: acc := H(peak, acc) for each lower
    // peak. (Thebes Core Team, 2026-09-09: the previous fold ran from the last
    // peak upwards and rejected every proof of a range with more than one peak.)
    var root : ?Blob = null;
    for (p in peaks.vals()) {
      root := switch (root) {
        case null ?p;
        case (?acc) ?hashNode(p, acc);
      };
    };

    switch (root) {
      case (?r) r == expectedRoot;
      case null false;
    };
  };
};
