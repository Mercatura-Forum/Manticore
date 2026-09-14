/// RegionIndex.mo; a sorted index in stable memory, with range scans.
///
/// This is a **derivative work** of `RegionBTree.mo`, beside it in this directory (MIT, carried from
/// ICRC-ME). It lives here rather than in the banking layer because the journal and the banking layer
/// both build on it; its oracle is `test/RegionIndex.test.mo` in the banking layer. The node
/// layout, the 8 KiB page, the 48-bit offsets, the binary search, the split and the shift helpers
/// are that file's constructions; the derivation is recorded in `NOTICE` beside
/// `src/facade/TokenLedger.mo`'s derivation from `IndexedLedger.mo`. The rule was
/// to improve that ledger, not rewrite it, and the four improvements are:
///
///   1. **Per-index key and value widths.** The original fixes `KEY_SIZE = 62` and
///      `VAL_SIZE = 16`, so a 12-byte day key still costs 78 bytes an entry. Taking both widths
///      from a `Spec` at creation buys between two and six times on storage and takes every index
///      in `the capacity model` from depth 5 to depth 4 at a billion keys; one fewer page
///      read on every lookup.
///   2. **Sibling-linked leaves.** A six-byte `next` pointer in the node header makes a range page
///      one descent plus sequential leaves, rather than one descent per leaf. That is what the
///      proposal means by "seek to `lo`, walk the sorted leaves".
///   3. **`range(lo, hi, cursor, limit)`** with a resume cursor, which the original's
///      `prefixScan` has no equivalent of: it re-descends from the root on every call and so
///      pages in O(n). A cursor makes paging O(page).
///   4. **A page free list**, so an index can be emptied and rebuilt **in place**. Stable memory
///      is never returned to the system, so a closed month whose per-posting entries are replaced
///      by a summary row must reuse its own pages or the packing saves nothing.
///   5. **A digest of the rows, maintained at `put`.** `digest` is the sum modulo 2^256 of
///      SHA-256(key ‖ value) over the rows the index holds now: `put` adds the new row's hash and,
///      when it overwrote, subtracts the old row's; `reset` and `release` zero it. Two indexes
///      holding the same rows have the same digest whatever order the rows arrived in, so a state
///      fingerprint reads one 32-byte word per index instead of walking every row; the walk that
///      exceeded one message at a fifty-thousand-deal book. The construction is the incremental
///      set hash of Bellare and Micciancio (AdHash, EUROCRYPT 1997; the additive form Facebook's
///      LtHash keeps for its data-set checksums): it is an equality check between two derivations
///      of the same log; a replay, a rebuild, the state across an upgrade; and not a commitment
///      a third party relies on; the commitment is the certified root over the log itself.
///
/// No deletion of single keys is provided, and none is needed: every index in this component is
/// either append-mostly, overwritten in place by `put`, or rebuilt wholesale for a closed month.
/// A B-tree delete with rebalancing would be a large surface maintained for no caller.

import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Order "mo:core/Order";
import Region "mo:core/Region";
import Runtime "mo:core/Runtime";
import VarArray "mo:core/VarArray";

import ByteBuf "ByteBuf";
import Array "mo:core/Array";
import Int "mo:core/Int";
import Sha256 "mo:sha2/Sha256";

module {

  let PAGE_SIZE : Nat64 = 8192;        // one node, one stable-memory page
  let REGION_PAGE : Nat64 = 65536;     // a Region grows in 64 KiB pages
  let HEADER : Nat = 9;                // [type:1][count:2][next:6]
  let CHILD_PTR : Nat = 6;             // a 48-bit node offset
  let NULL_NODE : Nat64 = 0xFFFF_FFFF_FFFF;

  let NODE_LEAF : Nat8 = 0;
  let NODE_INTERNAL : Nat8 = 1;

  /// The widths of one index. Both are fixed for the life of the index, which is what makes the
  /// B-tree's order the query's order: a composite key compares byte by byte, so
  /// `account ‖ day ‖ postingNo` sorts by account, then by day, then by posting; exactly the
  /// order an account-and-date-range query wants to read.
  public type Spec = { keyBytes : Nat; valBytes : Nat };

  /// A page allocator several indexes share. A Motoko `Region` reserves stable memory in 8 MiB
  /// blocks, so one region per index makes every small index cost 8 MiB before its first entry;
  /// an arena is one region whose pages are handed out to every index built in it, and a component
  /// with forty indexes pays the 8 MiB once. Pages are never returned to the arena; an index keeps
  /// the pages it frees on its own free list; so a page belongs to one index for ever.
  public type Arena = {
    region : Region.Region;
    /// Pages handed out so far, which is what the region's size is derived from.
    var pageCount : Nat64;
    /// Pages an index gave back (`release`), chained through their first six bytes like an index's
    /// own free list, and handed out again before any fresh page. This is what a rebuild reuses:
    /// the pages of the index it replaces.
    var freeHead : Nat64;
    var freeCount : Nat64;
  };

  public func newArena() : Arena { { region = Region.new(); var pageCount = 0; var freeHead = NULL_NODE; var freeCount = 0 } };

  /// Pages the arena has handed out, and pages waiting on its free list.
  public func arenaStats(a : Arena) : { pages : Nat; free : Nat; bytes : Nat } {
    { pages = Nat64.toNat(a.pageCount); free = Nat64.toNat(a.freeCount); bytes = Nat64.toNat(a.pageCount * PAGE_SIZE) }
  };

  public type State = {
    arena : Arena;
    spec : Spec;
    /// `(8192 − 9) / (key + val)`
    leafCap : Nat;
    /// `(8192 − 9 − 6) / (key + 6)`
    internalCap : Nat;
    var root : Nat64;
    /// Pages this index has taken from the arena.
    var pageCount : Nat64;
    var entryCount : Nat;
    /// Head of the free-page chain, or `NULL_NODE`. A freed page stores the next free offset in
    /// its first six bytes.
    var freeHead : Nat64;
    var freeCount : Nat64;
    /// The sum modulo 2^256 of SHA-256(key ‖ value) over the rows the index holds (improvement 5).
    var digest : Blob;
  };

  /// Thirty-two zero bytes: the digest of an empty index.
  public let ZERO_DIGEST : Blob = "\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00";

  /// An index in its own arena; its own region.
  public func newState(spec : Spec) : State { newStateIn(newArena(), spec) };

  /// An index in a shared arena.
  public func newStateIn(arena : Arena, spec : Spec) : State {
    if (spec.keyBytes == 0) Runtime.trap("RegionIndex: a key width of zero");
    let entry = spec.keyBytes + spec.valBytes;
    let leafCap = (Nat64.toNat(PAGE_SIZE) - HEADER) / entry;
    let internalCap = (Nat64.toNat(PAGE_SIZE) - HEADER - CHILD_PTR) / (spec.keyBytes + CHILD_PTR);
    if (leafCap < 4 or internalCap < 4) {
      Runtime.trap("RegionIndex: a key and value that wide leave fewer than four entries a page");
    };
    {
      arena;
      spec;
      leafCap;
      internalCap;
      var root : Nat64 = NULL_NODE;
      var pageCount : Nat64 = 0;
      var entryCount : Nat = 0;
      var freeHead : Nat64 = NULL_NODE;
      var freeCount : Nat64 = 0;
      var digest : Blob = ZERO_DIGEST;
    }
  };

  public func size(state : State) : Nat { state.entryCount };
  /// The digest of the rows the index holds now; equal for two indexes holding the same rows.
  public func digest(state : State) : Blob { state.digest };

  // ═══════════════════════════════════════════════════════
  //  ROW DIGEST
  // ═══════════════════════════════════════════════════════

  /// SHA-256 over the row's bytes. Every key of an index has one width and every value another, so
  /// `key ‖ value` names one row without a separator.
  func rowHash(key : Blob, val : Blob) : Blob {
    let d = Sha256.Digest(#sha256);
    d.writeBlob(key);
    d.writeBlob(val);
    d.sum()
  };

  /// `a + b` or `a − b` modulo 2^256 over 32 big-endian bytes.
  func addMod(a : Blob, b : Blob, subtract : Bool) : Blob {
    let x = Blob.toArray(a);
    let y = Blob.toArray(b);
    let out = VarArray.repeat<Nat8>(0, 32);
    var carry : Int = 0;
    var i = 32;
    while (i > 0) {
      i -= 1;
      let yi : Int = Nat8.toNat(y[i]);
      let t : Int = Nat8.toNat(x[i]) + (if (subtract) -yi else yi) + carry;
      if (t < 0) { out[i] := Nat8.fromNat(Int.abs(t + 256)); carry := -1 }
      else if (t >= 256) { out[i] := Nat8.fromNat(Int.abs(t - 256)); carry := 1 }
      else { out[i] := Nat8.fromNat(Int.abs(t)); carry := 0 };
    };
    Blob.fromArray(Array.fromVarArray(out))
  };

  /// The digest after a row was written: the new row added, the row it overwrote (if any) taken out.
  func digestPut(state : State, key : Blob, val : Blob, old : ?Blob) {
    switch (old) {
      case (?o) { if (o != val) { state.digest := addMod(addMod(state.digest, rowHash(key, o), true), rowHash(key, val), false) } };
      case null { state.digest := addMod(state.digest, rowHash(key, val), false) };
    };
  };
  public func isEmpty(state : State) : Bool { state.root == NULL_NODE };

  // ═══════════════════════════════════════════════════════
  //  PAGES
  // ═══════════════════════════════════════════════════════

  func growIfNeeded(arena : Arena, needed : Nat64) {
    let pages = (needed / REGION_PAGE) + 1;
    let have = Region.size(arena.region);
    if (pages > have) {
      let g = Region.grow(arena.region, pages - have);
      if (g == 0xFFFF_FFFF_FFFF_FFFF) Runtime.trap("RegionIndex: memory exhausted");
    };
  };

  func store48(state : State, off : Nat64, val : Nat64) {
    Region.storeNat32(state.arena.region, off, Nat32.fromNat(Nat64.toNat(val) % 4294967296));
    Region.storeNat16(state.arena.region, off + 4, Nat16.fromNat(Nat64.toNat(val) / 4294967296));
  };

  func load48(state : State, off : Nat64) : Nat64 {
    let lo = Nat32.toNat(Region.loadNat32(state.arena.region, off));
    let hi = Nat16.toNat(Region.loadNat16(state.arena.region, off + 4));
    Nat64.fromNat(lo + hi * 4294967296)
  };

  func allocNode(state : State, kind : Nat8) : Nat64 {
    let off = if (state.freeHead != NULL_NODE) {
      // reuse a page this index freed
      let reused = state.freeHead;
      state.freeHead := load48(state, reused);
      state.freeCount -= 1;
      reused
    } else if (state.arena.freeHead != NULL_NODE) {
      // then a page another index of the arena released
      let reused = state.arena.freeHead;
      state.arena.freeHead := load48(state, reused);
      state.arena.freeCount -= 1;
      state.pageCount += 1;
      reused
    } else {
      // a fresh page from the arena: the next one nobody holds
      let fresh = state.arena.pageCount * PAGE_SIZE;
      state.arena.pageCount += 1;
      state.pageCount += 1;
      growIfNeeded(state.arena, state.arena.pageCount * PAGE_SIZE);
      fresh
    };
    Region.storeNat8(state.arena.region, off, kind);
    Region.storeNat16(state.arena.region, off + 1, 0);
    store48(state, off + 3, NULL_NODE);
    off
  };

  func freeNode(state : State, node : Nat64) {
    store48(state, node, state.freeHead);
    state.freeHead := node;
    state.freeCount += 1;
  };

  /// Give every page of the index; the tree's and its own free list's; back to the arena, so an
  /// index built in its place allocates them before any fresh page. The index is empty afterwards
  /// and must not be used again except to be released a second time, which does nothing.
  public func release(state : State) {
    if (state.root != NULL_NODE) {
      let stack = List.empty<Nat64>();
      List.add(stack, state.root);
      label walk loop {
        let ?node = List.removeLast(stack) else break walk;
        if (nodeKind(state, node) == NODE_INTERNAL) {
          let n = count(state, node);
          var i = 0;
          while (i <= n) { List.add(stack, child(state, node, i)); i += 1 };
        };
        store48(state, node, state.arena.freeHead);
        state.arena.freeHead := node;
        state.arena.freeCount += 1;
      };
    };
    // and the pages this index freed for itself
    while (state.freeHead != NULL_NODE) {
      let page = state.freeHead;
      state.freeHead := load48(state, page);
      store48(state, page, state.arena.freeHead);
      state.arena.freeHead := page;
      state.arena.freeCount += 1;
    };
    state.freeCount := 0;
    state.root := NULL_NODE;
    state.entryCount := 0;
    state.pageCount := 0;
    state.digest := ZERO_DIGEST;
  };

  /// Empty the index, returning every page to the free list so a rebuild reuses them.
  ///
  /// This is what makes closed-month packing worth doing: stable memory is never returned to the
  /// system, so replacing a month's per-posting entries with a summary row only saves space if the
  /// pages the old entries occupied are reused.
  public func reset(state : State) {
    if (state.root != NULL_NODE) {
      let stack = List.empty<Nat64>();
      List.add(stack, state.root);
      label walk loop {
        let ?node = List.removeLast(stack) else break walk;
        if (nodeKind(state, node) == NODE_INTERNAL) {
          let n = count(state, node);
          var i = 0;
          while (i <= n) { List.add(stack, child(state, node, i)); i += 1 };
        };
        freeNode(state, node);
      };
    };
    state.root := NULL_NODE;
    state.entryCount := 0;
    state.digest := ZERO_DIGEST;
  };

  // ═══════════════════════════════════════════════════════
  //  NODE ACCESS
  // ═══════════════════════════════════════════════════════

  func nodeKind(state : State, node : Nat64) : Nat8 { Region.loadNat8(state.arena.region, node) };
  func count(state : State, node : Nat64) : Nat { Nat16.toNat(Region.loadNat16(state.arena.region, node + 1)) };
  func setCount(state : State, node : Nat64, n : Nat) { Region.storeNat16(state.arena.region, node + 1, Nat16.fromNat(n)) };
  func nextLeaf(state : State, node : Nat64) : Nat64 { load48(state, node + 3) };
  func setNextLeaf(state : State, node : Nat64, nxt : Nat64) { store48(state, node + 3, nxt) };

  func leafOff(state : State, node : Nat64, idx : Nat) : Nat64 {
    node + Nat64.fromNat(HEADER) + Nat64.fromNat(idx * (state.spec.keyBytes + state.spec.valBytes))
  };
  func leafKey(state : State, node : Nat64, idx : Nat) : Blob {
    Region.loadBlob(state.arena.region, leafOff(state, node, idx), state.spec.keyBytes)
  };
  func leafVal(state : State, node : Nat64, idx : Nat) : Blob {
    Region.loadBlob(state.arena.region, leafOff(state, node, idx) + Nat64.fromNat(state.spec.keyBytes), state.spec.valBytes)
  };
  func setLeaf(state : State, node : Nat64, idx : Nat, key : Blob, val : Blob) {
    Region.storeBlob(state.arena.region, leafOff(state, node, idx), key);
    Region.storeBlob(state.arena.region, leafOff(state, node, idx) + Nat64.fromNat(state.spec.keyBytes), val);
  };

  // Internal layout, following the original: children first, then keys.
  //   [type:1][count:2][next:6][children:6×(internalCap+1)][keys:key×internalCap]
  func childOff(_state : State, node : Nat64, idx : Nat) : Nat64 {
    node + Nat64.fromNat(HEADER) + Nat64.fromNat(idx * CHILD_PTR)
  };
  func internalKeyOff(state : State, node : Nat64, idx : Nat) : Nat64 {
    node + Nat64.fromNat(HEADER) + Nat64.fromNat((state.internalCap + 1) * CHILD_PTR)
      + Nat64.fromNat(idx * state.spec.keyBytes)
  };
  func child(state : State, node : Nat64, idx : Nat) : Nat64 { load48(state, childOff(state, node, idx)) };
  func setChild(state : State, node : Nat64, idx : Nat, c : Nat64) { store48(state, childOff(state, node, idx), c) };
  func internalKey(state : State, node : Nat64, idx : Nat) : Blob {
    Region.loadBlob(state.arena.region, internalKeyOff(state, node, idx), state.spec.keyBytes)
  };
  func setInternalKey(state : State, node : Nat64, idx : Nat, key : Blob) {
    Region.storeBlob(state.arena.region, internalKeyOff(state, node, idx), key);
  };

  // ═══════════════════════════════════════════════════════
  //  SEARCH
  // ═══════════════════════════════════════════════════════

  func cmp(a : Blob, b : Blob) : Order.Order { Blob.compare(a, b) };

  /// The index a key would be inserted at, and whether it is already there.
  func leafSearch(state : State, node : Nat64, key : Blob) : (Nat, Bool) {
    let n = count(state, node);
    if (n == 0) return (0, false);
    var lo = 0;
    var hi = n;
    while (lo < hi) {
      let mid = (lo + hi) / 2;
      switch (cmp(leafKey(state, node, mid), key)) {
        case (#less) lo := mid + 1;
        case (#equal) return (mid, true);
        case (#greater) hi := mid;
      };
    };
    (lo, false)
  };

  func internalSearch(state : State, node : Nat64, key : Blob) : Nat {
    let n = count(state, node);
    var lo = 0;
    var hi = n;
    while (lo < hi) {
      let mid = (lo + hi) / 2;
      switch (cmp(internalKey(state, node, mid), key)) {
        case (#less) lo := mid + 1;
        case (#equal) return mid + 1;        // an exact match goes right
        case (#greater) hi := mid;
      };
    };
    lo
  };

  func requireWidth(state : State, key : Blob, val : ?Blob) {
    if (key.size() != state.spec.keyBytes) {
      Runtime.trap("RegionIndex: a key of " # Nat.toText(key.size()) # " bytes where the index takes "
        # Nat.toText(state.spec.keyBytes));
    };
    switch (val) {
      case (?v) {
        if (v.size() != state.spec.valBytes) {
          Runtime.trap("RegionIndex: a value of " # Nat.toText(v.size()) # " bytes where the index takes "
            # Nat.toText(state.spec.valBytes));
        };
      };
      case null {};
    };
  };

  public func get(state : State, key : Blob) : ?Blob {
    requireWidth(state, key, null);
    var node = state.root;
    while (node != NULL_NODE) {
      if (nodeKind(state, node) == NODE_LEAF) {
        let (idx, found) = leafSearch(state, node, key);
        return if (found) ?leafVal(state, node, idx) else null;
      };
      node := child(state, node, internalSearch(state, node, key));
    };
    null
  };

  // ═══════════════════════════════════════════════════════
  //  SHIFTS AND SPLITS
  // ═══════════════════════════════════════════════════════

  /// Entries `[from, n)` moved one slot right: one load of the run and one store, not one pair per
  /// entry. The store lands after the load has copied the bytes out, so the overlap is safe. The
  /// measured runs found the per-entry loop to be the cost of a posting: a random insert into a
  /// 227-entry leaf moved a hundred entries with a call each.
  func shiftLeafRight(state : State, node : Nat64, from : Nat, n : Nat) {
    if (n <= from) return;
    let width = state.spec.keyBytes + state.spec.valBytes;
    let run = Region.loadBlob(state.arena.region, leafOff(state, node, from), (n - from) * width);
    Region.storeBlob(state.arena.region, leafOff(state, node, from + 1), run);
  };

  func shiftInternalRight(state : State, node : Nat64, from : Nat, n : Nat) {
    if (n <= from) return;
    let keys = Region.loadBlob(state.arena.region, internalKeyOff(state, node, from), (n - from) * state.spec.keyBytes);
    Region.storeBlob(state.arena.region, internalKeyOff(state, node, from + 1), keys);
    let children = Region.loadBlob(state.arena.region, childOff(state, node, from + 1), (n - from) * CHILD_PTR);
    Region.storeBlob(state.arena.region, childOff(state, node, from + 2), children);
  };

  type Split = { medianKey : Blob; rightNode : Nat64 };

  /// Split a leaf, given the key that is about to be inserted.
  ///
  /// A midpoint split is right for random keys and **wrong for append-ordered ones**: every split
  /// leaves the left half empty for ever and every later key goes right, so a purely ascending
  /// index settles at 50% fill, not the near-100% `the capacity model` claims for the day,
  /// currency and class indexes. Three of our four posting indexes are append-ordered, so the
  /// difference is half their storage.
  ///
  /// So a split that is appending at the right edge of the tree; the new key is greater than
  /// every key in the leaf and the leaf has no successor; leaves the left leaf **full** and
  /// starts the right one empty, with the new key as the separator. That is Graefe's right-edge
  /// split (*Modern B-Tree Techniques* §2.2), and it is what makes the model's fill figure true
  /// rather than aspirational.
  func splitLeafFor(state : State, node : Nat64, key : Blob) : Split {
    let n = count(state, node);
    if (n > 0 and nextLeaf(state, node) == NULL_NODE
        and cmp(key, leafKey(state, node, n - 1)) == #greater) {
      let right = allocNode(state, NODE_LEAF);
      setCount(state, right, 0);
      setNextLeaf(state, right, nextLeaf(state, node));
      setNextLeaf(state, node, right);
      return { medianKey = key; rightNode = right };
    };
    splitLeafAt(state, node, n / 2)
  };

  func splitLeafAt(state : State, node : Nat64, mid : Nat) : Split {
    let n = count(state, node);
    let right = allocNode(state, NODE_LEAF);
    let width = state.spec.keyBytes + state.spec.valBytes;
    // the upper half moved as one run
    if (n > mid) {
      let run = Region.loadBlob(state.arena.region, leafOff(state, node, mid), (n - mid) * width);
      Region.storeBlob(state.arena.region, leafOff(state, right, 0), run);
    };
    setCount(state, right, n - mid);
    setCount(state, node, mid);
    // the sibling chain: the new leaf takes the old one's successor
    setNextLeaf(state, right, nextLeaf(state, node));
    setNextLeaf(state, node, right);
    { medianKey = leafKey(state, right, 0); rightNode = right }
  };

  func splitInternal(state : State, node : Nat64) : Split {
    let n = count(state, node);
    let mid = n / 2;
    let right = allocNode(state, NODE_INTERNAL);
    let median = internalKey(state, node, mid);
    // the keys after the median and the children from the median's right, each as one run
    if (n > mid + 1) {
      let keys = Region.loadBlob(state.arena.region, internalKeyOff(state, node, mid + 1), (n - mid - 1) * state.spec.keyBytes);
      Region.storeBlob(state.arena.region, internalKeyOff(state, right, 0), keys);
    };
    let children = Region.loadBlob(state.arena.region, childOff(state, node, mid + 1), (n - mid) * CHILD_PTR);
    Region.storeBlob(state.arena.region, childOff(state, right, 0), children);
    setCount(state, right, n - mid - 1);
    setCount(state, node, mid);
    { medianKey = median; rightNode = right }
  };

  // ═══════════════════════════════════════════════════════
  //  INSERT
  // ═══════════════════════════════════════════════════════

  /// Insert or overwrite. Returns the previous value when the key was already there, which is what
  /// an aggregate's read-modify-write reads.
  public func put(state : State, key : Blob, val : Blob) : ?Blob {
    requireWidth(state, key, ?val);
    if (state.root == NULL_NODE) {
      let root = allocNode(state, NODE_LEAF);
      setLeaf(state, root, 0, key, val);
      setCount(state, root, 1);
      state.root := root;
      state.entryCount += 1;
      digestPut(state, key, val, null);
      return null;
    };
    // split the root first if it is full, so a descent never has to split upwards
    let rootCap = if (nodeKind(state, state.root) == NODE_LEAF) state.leafCap else state.internalCap;
    if (count(state, state.root) >= rootCap) {
      let split = if (nodeKind(state, state.root) == NODE_LEAF) splitLeafFor(state, state.root, key)
                  else splitInternal(state, state.root);
      let newRoot = allocNode(state, NODE_INTERNAL);
      setChild(state, newRoot, 0, state.root);
      setChild(state, newRoot, 1, split.rightNode);
      setInternalKey(state, newRoot, 0, split.medianKey);
      setCount(state, newRoot, 1);
      state.root := newRoot;
    };
    let old = insertNonFull(state, state.root, key, val);
    digestPut(state, key, val, old);
    old
  };

  func insertNonFull(state : State, node : Nat64, key : Blob, val : Blob) : ?Blob {
    if (nodeKind(state, node) == NODE_LEAF) {
      let n = count(state, node);
      let (idx, found) = leafSearch(state, node, key);
      if (found) {
        let previous = leafVal(state, node, idx);
        setLeaf(state, node, idx, key, val);
        return ?previous;
      };
      shiftLeafRight(state, node, idx, n);
      setLeaf(state, node, idx, key, val);
      setCount(state, node, n + 1);
      state.entryCount += 1;
      return null;
    };
    let n = count(state, node);
    var i = internalSearch(state, node, key);
    var c = child(state, node, i);
    let childCap = if (nodeKind(state, c) == NODE_LEAF) state.leafCap else state.internalCap;
    if (count(state, c) >= childCap) {
      let split = if (nodeKind(state, c) == NODE_LEAF) splitLeafFor(state, c, key) else splitInternal(state, c);
      shiftInternalRight(state, node, i, n);
      setInternalKey(state, node, i, split.medianKey);
      setChild(state, node, i + 1, split.rightNode);
      setCount(state, node, n + 1);
      if (cmp(key, split.medianKey) != #less) {
        i += 1;
        c := split.rightNode;
      };
    };
    insertNonFull(state, c, key, val)
  };

  // ═══════════════════════════════════════════════════════
  //  RANGE
  // ═══════════════════════════════════════════════════════

  public type Page = {
    entries : [(Blob, Blob)];
    /// The key to resume at, or null when the range is exhausted. A caller pages by handing this
    /// straight back, so paging costs one descent and then sequential leaves.
    cursor : ?Blob;
  };

  /// The leaf that would hold `key`, and the index within it of the first entry ≥ `key`.
  func seek(state : State, key : Blob) : ?(Nat64, Nat) {
    var node = state.root;
    if (node == NULL_NODE) return null;
    while (nodeKind(state, node) == NODE_INTERNAL) {
      node := child(state, node, internalSearch(state, node, key));
    };
    let (idx, _) = leafSearch(state, node, key);
    ?(node, idx)
  };

  /// Entries with `lo ≤ key ≤ hi`, in key order, at most `limit` of them.
  ///
  /// `cursor` resumes a previous page: pass the `cursor` the last page returned. The walk is one
  /// descent to find the starting leaf and then the sibling chain, so the cost is the page and not
  /// the index; which is the whole reason the index exists.
  public func range(state : State, lo : Blob, hi : Blob, cursor : ?Blob, limit : Nat) : Page {
    requireWidth(state, lo, null);
    requireWidth(state, hi, null);
    let start = switch (cursor) {
      case (?c) { requireWidth(state, c, null); if (cmp(c, lo) == #less) lo else c };
      case null lo;
    };
    let out = List.empty<(Blob, Blob)>();
    if (limit == 0 or cmp(start, hi) == #greater) return { entries = []; cursor = null };
    let ?(firstLeaf, firstIdx) = seek(state, start) else return { entries = []; cursor = null };
    var node = firstLeaf;
    var i = firstIdx;
    label walk loop {
      if (node == NULL_NODE) break walk;
      let n = count(state, node);
      while (i < n) {
        let k = leafKey(state, node, i);
        if (cmp(k, hi) == #greater) return { entries = List.toArray(out); cursor = null };
        List.add(out, (k, leafVal(state, node, i)));
        i += 1;
        if (List.size(out) >= limit) {
          // the next key is where the caller resumes; a successor of the last key returned would
          // need a key increment, and the leaf already knows the answer
          if (i < n) return { entries = List.toArray(out); cursor = ?leafKey(state, node, i) };
          let nxt = nextLeaf(state, node);
          if (nxt == NULL_NODE or count(state, nxt) == 0) {
            return { entries = List.toArray(out); cursor = null };
          };
          let nextKey = leafKey(state, nxt, 0);
          return {
            entries = List.toArray(out);
            cursor = if (cmp(nextKey, hi) == #greater) null else ?nextKey;
          };
        };
      };
      node := nextLeaf(state, node);
      i := 0;
    };
    { entries = List.toArray(out); cursor = null }
  };

  /// How many entries the range holds, up to `bound`. Used to **size a query before running it**,
  /// so a filter wider than its bound is refused naming the size rather than trapping part-way.
  /// Stops counting at `bound`, so the sizing itself is bounded.
  public func rangeSize(state : State, lo : Blob, hi : Blob, bound : Nat) : { size : Nat; exceeded : Bool } {
    requireWidth(state, lo, null);
    requireWidth(state, hi, null);
    var total = 0;
    let ?(firstLeaf, firstIdx) = seek(state, lo) else return { size = 0; exceeded = false };
    var node = firstLeaf;
    var i = firstIdx;
    label walk loop {
      if (node == NULL_NODE) break walk;
      let n = count(state, node);
      while (i < n) {
        if (cmp(leafKey(state, node, i), hi) == #greater) return { size = total; exceeded = false };
        total += 1;
        if (total > bound) return { size = total; exceeded = true };
        i += 1;
      };
      node := nextLeaf(state, node);
      i := 0;
    };
    { size = total; exceeded = false }
  };

  // ═══════════════════════════════════════════════════════
  //  STATS; what the capacity model is measured against
  // ═══════════════════════════════════════════════════════

  public type Stats = {
    entries : Nat;
    pages : Nat;
    freePages : Nat;
    /// `pages × 8192`, which is the index's share of stable memory.
    bytes : Nat;
    bytesPerEntry : Nat;
    depth : Nat;
    leafCap : Nat;
    internalCap : Nat;
    /// Mean leaf occupancy as a percentage, which the model assumes is 69 for random keys and
    /// near 100 for append-ordered ones.
    leafFillPercent : Nat;
  };

  public func stats(state : State) : Stats {
    var depth = 0;
    var node = state.root;
    while (node != NULL_NODE and nodeKind(state, node) == NODE_INTERNAL) {
      depth += 1;
      node := child(state, node, 0);
    };
    if (node != NULL_NODE) depth += 1;
    // walk the sibling chain for the leaf fill, which is one pass over the leaves and is only
    // asked for by the measurement harness
    var leaves = 0;
    var occupied = 0;
    var leaf = node;
    while (leaf != NULL_NODE) {
      leaves += 1;
      occupied += count(state, leaf);
      leaf := nextLeaf(state, leaf);
    };
    let bytes = Nat64.toNat(state.pageCount * PAGE_SIZE);
    {
      entries = state.entryCount;
      pages = Nat64.toNat(state.pageCount);
      freePages = Nat64.toNat(state.freeCount);
      bytes;
      bytesPerEntry = if (state.entryCount == 0) 0 else bytes / state.entryCount;
      depth;
      leafCap = state.leafCap;
      internalCap = state.internalCap;
      leafFillPercent = if (leaves == 0) 0 else (occupied * 100) / (leaves * state.leafCap);
    }
  };

  // ═══════════════════════════════════════════════════════
  //  KEY BUILDING
  // ═══════════════════════════════════════════════════════

  /// Big-endian, fixed width. Every key in this component is built from these, because a key whose
  /// bytes are big-endian sorts the same way as the number it encodes; which is what lets one
  /// composite key serve a range query.
  public func beBytes(value : Nat, width : Nat) : [Nat8] { ByteBuf.be(value, width) };

  /// Concatenate fixed-width parts into a key of exactly `width` bytes, right-padded with zeros.
  /// Padding with zeros keeps the order: a shorter logical key sorts before every key that extends
  /// it, which is what makes a prefix range work.
  public func key(parts : [[Nat8]], width : Nat) : Blob {
    let out = VarArray.repeat<Nat8>(0, width);
    var n = 0;
    for (p in parts.vals()) {
      for (b in p.vals()) {
        if (n >= width) Runtime.trap("RegionIndex: a key longer than the " # Nat.toText(width) # " bytes declared");
        out[n] := b;
        n += 1;
      };
    };
    Blob.fromVarArray(out)
  };

  /// The low and high ends of a range over a key whose leading parts are fixed: the fixed prefix
  /// with the rest at 0x00 and at 0xFF. This is how an account-and-date range is expressed.
  public func rangeEnds(prefix : [[Nat8]], width : Nat) : (Blob, Blob) {
    let lo = VarArray.repeat<Nat8>(0, width);
    let hi = VarArray.repeat<Nat8>(255, width);
    var n = 0;
    for (p in prefix.vals()) {
      for (b in p.vals()) {
        if (n >= width) Runtime.trap("RegionIndex: a prefix longer than the key");
        lo[n] := b; hi[n] := b;
        n += 1;
      };
    };
    (Blob.fromVarArray(lo), Blob.fromVarArray(hi))
  };
};
