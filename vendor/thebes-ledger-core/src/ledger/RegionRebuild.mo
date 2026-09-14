/// RegionRebuild.mo; replacing a `RegionIndex` by a copy that leaves some entries out, in chunks,
/// while the index stays in use.
///
/// A `RegionIndex` cannot delete an entry, by design: a page belongs to an index for ever and the
/// tree never rebalances. What closed-month packing needs is the other thing; an index with a
/// whole month's rows gone and their pages reusable; and that is a **rebuild by generation**: a
/// new index in the same arena, every kept entry copied into it in key order, then the old index
/// released so its pages feed the arena's free list, which the new index and every later one
/// allocate from before any fresh page. The copy is chunked, resumable from its cursor, and the
/// old index keeps serving reads until the swap.
///
/// Writes that land while a rebuild is in progress go to the old index, and; when their key is at
/// or below the cursor, so the copy has already passed them; to the new one as well
/// (`mirror`). A key above the cursor is copied when the cursor reaches it. So the new index holds
/// exactly the kept entries the old one holds at the moment of the swap, whatever arrived in
/// between; `test/RegionRebuild.test.mo` writes during the rebuild and checks that.

import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Order "mo:core/Order";

import RI "RegionIndex";

module {

  public type Job = {
    source : RI.State;
    target : RI.State;
    /// The last key copied or dropped; entries at or below it are the new index's business.
    var cursor : ?Blob;
    var copied : Nat;
    var dropped : Nat;
    var done : Bool;
  };

  /// Start a rebuild: the target is a fresh index of the same spec in the same arena.
  public func start(source : RI.State) : Job {
    { source; target = RI.newStateIn(source.arena, source.spec); var cursor = null; var copied = 0; var dropped = 0; var done = false }
  };

  func lo(width : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(width, func(_) { 0 })) };
  func hi(width : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(width, func(_) { 255 })) };

  func cmp(a : Blob, b : Blob) : Order.Order { Blob.compare(a, b) };

  /// The successor key of the last examined one, as a range cursor: the first key strictly above
  /// it. Computed by incrementing the big-endian key; an all-0xFF key has no successor, which ends
  /// the walk.
  func successor(k : Blob) : ?Blob {
    let a = Blob.toArray(k);
    var i = a.size();
    let out = Array.toVarArray<Nat8>(a);
    while (i > 0) {
      i -= 1;
      if (out[i] < 255) { out[i] += 1; return ?Blob.fromArray(Array.fromVarArray(out)) };
      out[i] := 0;
    };
    null
  };

  /// Copy up to `limit` entries that `keep` accepts, in key order, from the cursor on. Returns the
  /// number examined. The job is `done` when the source is exhausted.
  public func step(job : Job, keep : (Blob, Blob) -> Bool, limit : Nat) : Nat {
    if (job.done or limit == 0) return 0;
    let width = job.source.spec.keyBytes;
    let start = switch (job.cursor) {
      case null lo(width);
      case (?c) { switch (successor(c)) { case (?s) s; case null { job.done := true; return 0 } } };
    };
    let page = RI.range(job.source, start, hi(width), null, limit);
    var examined = 0;
    for ((k, v) in page.entries.vals()) {
      if (keep(k, v)) { ignore RI.put(job.target, k, v); job.copied += 1 } else { job.dropped += 1 };
      job.cursor := ?k;
      examined += 1;
    };
    if (page.cursor == null) job.done := true;
    examined
  };

  /// A write that lands during the rebuild: the source always, the target when the copy has
  /// passed the key. The caller has written the source already; this adds the target's share.
  public func mirror(job : Job, key : Blob, val : Blob, keep : (Blob, Blob) -> Bool) {
    if (job.done) { if (keep(key, val)) ignore RI.put(job.target, key, val); return };
    switch (job.cursor) {
      case (?c) { if (cmp(key, c) != #greater and keep(key, val)) ignore RI.put(job.target, key, val) };
      case null {};
    };
  };

  /// Release the source's pages to the arena and hand back the target. Only when done.
  public func finish(job : Job) : RI.State {
    assert (job.done);
    RI.release(job.source);
    job.target
  };
}
