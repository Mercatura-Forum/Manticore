/// StableLog.mo: Append-only log backed by Region stable memory, with a prefix that can leave.
///
/// A Motoko equivalent of Rust's ic-stable-structures StableLog: survives upgrades, scales to
/// gigabytes, O(1) append and O(1) random access. This version also lets a **prefix be truncated**
/// and its memory reused; which a Region cannot do on its own, because a Region is never returned
/// to the system. So the log keeps its bytes in a **pool of regions**: entries are appended into
/// the current data region until it is full, then the next region is taken from the pool (a region
/// whose entries have all been truncated) or allocated; the index that addresses entries is kept in
/// chunks of `INDEX_CHUNK` entries, each chunk a region of the same pool. Truncating through entry
/// `hi` moves the base to `hi + 1` and puts every region that held only truncated entries back on
/// the pool, so the next month's entries land in the pages last month's left.
///
/// Layout:
///   region 0; the header: base(8) ‖ count(8) ‖ dataRegion(8) ‖ dataOffset(8), rewritten on every
///              append and truncation, so the state is recoverable from stable memory alone;
///   index chunk c; slots for entries [c·INDEX_CHUNK, (c+1)·INDEX_CHUNK): offset(8) ‖ len(4) ‖ region(4);
///   data regions; the entries' bytes, contiguous within a region; an entry never straddles two.
///
/// The public surface the readers already use, `append`, `get`, `size`, `getRange`, `dataSize`, is
/// unchanged; `get` answers null below the base as it does past the end.

import Region "mo:core/Region";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Map "mo:core/Map";
import Runtime "mo:core/Runtime";

module {

  let PAGE_SIZE : Nat64 = 65536; // 64KB per page
  /// Entries per index chunk: 16 bytes a slot, so a chunk is at most 16 MiB.
  public let INDEX_CHUNK : Nat64 = 1_048_576;
  let SLOT : Nat64 = 16;
  /// A data region is closed once it holds this many bytes; the next entry opens the next region.
  public let DATA_REGION_BYTES : Nat64 = 268_435_456;   // 256 MiB

  // ═══════════════════════════════════════════════════════
  //  STATE (Region handles are stable)
  // ═══════════════════════════════════════════════════════

  public type State = {
    /// Every region this log ever allocated, by ordinal; ordinal 0 is the header.
    regions : List.List<Region.Region>;
    /// Ordinals whose entries have all been truncated: reused before any new region.
    free : List.List<Nat>;
    /// Index chunk number → region ordinal.
    indexChunks : Map.Map<Nat, Nat>;
    /// Data region ordinal → the last entry it holds, so truncation knows when it is empty.
    dataLast : Map.Map<Nat, Nat64>;
    var base : Nat64;
    var entryCount : Nat64;
    var dataRegion : Nat;
    var dataOffset : Nat64;
    var initialized : Bool;
  };

  public func newState() : State {
    {
      regions = List.empty<Region.Region>();
      free = List.empty<Nat>();
      indexChunks = Map.empty<Nat, Nat>();
      dataLast = Map.empty<Nat, Nat64>();
      var base : Nat64 = 0;
      var entryCount : Nat64 = 0;
      var dataRegion = 0;
      var dataOffset : Nat64 = 0;
      var initialized = false;
    };
  };

  func regionOf(state : State, ordinal : Nat) : Region.Region {
    switch (List.get(state.regions, ordinal)) { case (?r) r; case null Runtime.trap("StableLog: no region " # Nat.toText(ordinal)) }
  };

  /// A region from the pool, else a new one.
  func takeRegion(state : State) : Nat {
    switch (List.removeLast(state.free)) {
      case (?ordinal) ordinal;
      case null { List.add(state.regions, Region.new()); List.size(state.regions) - 1 };
    }
  };

  func ensureCapacity(region : Region.Region, needed : Nat64) {
    let currentBytes = Region.size(region) * PAGE_SIZE;
    if (needed > currentBytes) {
      let pagesNeeded = (needed - currentBytes + PAGE_SIZE - 1) / PAGE_SIZE;
      let result = Region.grow(region, pagesNeeded);
      if (result == 0xFFFF_FFFF_FFFF_FFFF) {
        Runtime.trap("StableLog: out of stable memory");
      };
    };
  };

  /// Initialize (idempotent via initialized flag): the header region, and the first data region.
  public func ensureInit(state : State) {
    if (state.initialized) return;
    let header = takeRegion(state);
    assert (header == 0);
    ensureCapacity(regionOf(state, 0), 32);
    state.dataRegion := takeRegion(state);
    state.initialized := true;
    writeHeader(state);
  };

  func writeHeader(state : State) {
    let h = regionOf(state, 0);
    Region.storeNat64(h, 0, state.base);
    Region.storeNat64(h, 8, state.entryCount);
    Region.storeNat64(h, 16, Nat64.fromNat(state.dataRegion));
    Region.storeNat64(h, 24, state.dataOffset);
  };

  func chunkOf(idx : Nat64) : Nat { Nat64.toNat(idx / INDEX_CHUNK) };
  func slotOffset(idx : Nat64) : Nat64 { (idx % INDEX_CHUNK) * SLOT };

  func indexRegionFor(state : State, idx : Nat64) : Region.Region {
    let c = chunkOf(idx);
    switch (Map.get(state.indexChunks, Nat.compare, c)) {
      case (?ordinal) regionOf(state, ordinal);
      case null {
        let ordinal = takeRegion(state);
        Map.add(state.indexChunks, Nat.compare, c, ordinal);
        regionOf(state, ordinal)
      };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  OPERATIONS
  // ═══════════════════════════════════════════════════════

  /// Append a blob entry. Returns the entry index.
  public func append(state : State, data : Blob) : Nat {
    ensureInit(state);
    let idx = state.entryCount;
    let dataLen64 = Nat64.fromNat(data.size());
    // the entry goes into the current data region unless that would take it past the cap; an entry
    // larger than the cap gets a region of its own, since a region grows to what is asked of it
    if (state.dataOffset > 0 and state.dataOffset + dataLen64 > DATA_REGION_BYTES) {
      state.dataRegion := takeRegion(state);
      state.dataOffset := 0;
    };
    let dr = regionOf(state, state.dataRegion);
    ensureCapacity(dr, state.dataOffset + dataLen64);
    Region.storeBlob(dr, state.dataOffset, data);

    let ir = indexRegionFor(state, idx);
    let slot = slotOffset(idx);
    ensureCapacity(ir, slot + SLOT);
    Region.storeNat64(ir, slot, state.dataOffset);
    Region.storeNat32(ir, slot + 8, Nat32.fromNat(data.size()));
    Region.storeNat32(ir, slot + 12, Nat32.fromNat(state.dataRegion));

    Map.add(state.dataLast, Nat.compare, state.dataRegion, idx);
    state.dataOffset += dataLen64;
    state.entryCount += 1;
    writeHeader(state);
    Nat64.toNat(idx)
  };

  /// Get entry by index. Null past the end; and below the base, where the prefix has left.
  public func get(state : State, idx : Nat) : ?Blob {
    let idx64 = Nat64.fromNat(idx);
    if (idx64 >= state.entryCount or idx64 < state.base) return null;
    let ir = indexRegionFor(state, idx64);
    let slot = slotOffset(idx64);
    let offset = Region.loadNat64(ir, slot);
    let length = Region.loadNat32(ir, slot + 8);
    let ordinal = Nat32.toNat(Region.loadNat32(ir, slot + 12));
    ?Region.loadBlob(regionOf(state, ordinal), offset, Nat32.toNat(length))
  };

  /// Number of entries ever appended: the next index. Entries below `base` are gone.
  public func size(state : State) : Nat {
    Nat64.toNat(state.entryCount)
  };

  /// The first entry still held.
  public func base(state : State) : Nat { Nat64.toNat(state.base) };

  /// Get a range of entries [start, start+length), the truncated ones as empty blobs.
  public func getRange(state : State, start : Nat, length : Nat) : [Blob] {
    let end = Nat.min(start + length, size(state));
    if (start >= end) return [];
    Array.tabulate<Blob>(end - start, func(i) {
      switch (get(state, start + i)) {
        case (?b) b;
        case null Blob.fromArray([]);
      };
    });
  };

  /// Bytes held in data regions still in use: what the live entries cost, plus whatever a partly
  /// truncated region still holds.
  public func dataSize(state : State) : Nat {
    var bytes : Nat64 = 0;
    for ((ordinal, _) in Map.entries(state.dataLast)) {
      bytes += Region.size(regionOf(state, ordinal)) * PAGE_SIZE;
    };
    Nat64.toNat(bytes)
  };

  /// Regions allocated, and how many of them wait on the pool.
  public func regionStats(state : State) : { regions : Nat; free : Nat; pages : Nat } {
    var pages : Nat64 = 0;
    for (r in List.values(state.regions)) pages += Region.size(r);
    { regions = List.size(state.regions); free = List.size(state.free); pages = Nat64.toNat(pages) }
  };

  /// Let every entry at or below `hi` go. Regions that held only such entries; whole index chunks,
  /// data regions whose last entry is at or below `hi` and are not the current one; return to the
  /// pool. A base already past `hi` is left where it is.
  public func truncateThrough(state : State, hi : Nat) {
    ensureInit(state);
    let hi64 = Nat64.fromNat(hi);
    if (hi64 >= state.entryCount) Runtime.trap("StableLog: truncation past the end");
    if (hi64 + 1 <= state.base) return;
    state.base := hi64 + 1;
    // index chunks entirely below the base
    let doneChunks = List.empty<Nat>();
    for ((c, ordinal) in Map.entries(state.indexChunks)) {
      let chunkEnd = Nat64.fromNat(c + 1) * INDEX_CHUNK;   // exclusive
      if (chunkEnd <= state.base) { List.add(doneChunks, c); List.add(state.free, ordinal) };
    };
    for (c in List.values(doneChunks)) ignore Map.delete(state.indexChunks, Nat.compare, c);
    // data regions whose every entry is below the base
    let doneData = List.empty<Nat>();
    for ((ordinal, last) in Map.entries(state.dataLast)) {
      if (last < state.base and ordinal != state.dataRegion) { List.add(doneData, ordinal); List.add(state.free, ordinal) };
    };
    for (o in List.values(doneData)) ignore Map.delete(state.dataLast, Nat.compare, o);
    writeHeader(state);
  };

  /// Recover the counters from the header region after an upgrade that lost them (a persistent
  /// actor keeps them; this is for disaster recovery).
  public func recover(state : State) {
    if (List.size(state.regions) == 0) return;
    let h = regionOf(state, 0);
    state.base := Region.loadNat64(h, 0);
    state.entryCount := Region.loadNat64(h, 8);
    state.dataRegion := Nat64.toNat(Region.loadNat64(h, 16));
    state.dataOffset := Region.loadNat64(h, 24);
    state.initialized := true;
  };
};
