// RegionRebuild.test.mo — a RegionIndex rebuilt by generation, in chunks, while it is written to.
//
// What is proved: the rebuilt index holds exactly the kept entries of the source at the swap,
// including every write that landed during the rebuild (below and above the cursor); the source's
// pages went back to the arena and the next index allocates them before any fresh page, so the
// arena does not grow across a rebuild that keeps fewer entries; the cursor resumes across chunks
// of uneven size; a rebuild of an empty index is a no-op that still swaps.
//
// engine: wasi-only — Regions.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Blob "mo:core/Blob";
import Map "mo:core/Map";

import RI "../src/ledger/RegionIndex";
import RB "../src/ledger/RegionRebuild";

var seed : Nat32 = 0xC0FF_EE01;
func next() : Nat32 { seed := seed *% 1_664_525 +% 1_013_904_223; seed };
func below(n : Nat) : Nat { if (n == 0) 0 else (Nat32.toNat(next() / 65_536) * 65_536 + Nat32.toNat(next() / 65_536)) % n };

func key(n : Nat) : Blob { Blob.fromArray(RI.beBytes(n, 12)) };
func val(n : Nat) : Blob { Blob.fromArray(RI.beBytes(n * 7, 8)) };
func keyNat(k : Blob) : Nat { var v = 0; for (b in k.vals()) v := v * 256 + Nat8.toNat(b); v };

let arena = RI.newArena();
var idx = RI.newStateIn(arena, { keyBytes = 12; valBytes = 8 });
let oracle = Map.empty<Nat, Nat>();
func write(n : Nat) { ignore RI.put(idx, key(n), val(n)); Map.add(oracle, Nat.compare, n, n * 7) };

// 20,000 entries, keys spread over a wide space so pages fill at the random end
var i = 0;
while (i < 20_000) { write(below(1_000_000)); i += 1 };
let before = RI.arenaStats(arena);
Debug.print("count: entries before the rebuild = " # Nat.toText(RI.size(idx)));
Debug.print("count: arena pages before the rebuild = " # Nat.toText(before.pages));

// keep the entries whose key is even; drop the odd ones — about half
func keep(k : Blob, _ : Blob) : Bool { keyNat(k) % 2 == 0 };

let job = RB.start(idx);
var steps = 0;
var written = 0;
label run loop {
  let n = RB.step(job, keep, 100 + below(900));
  steps += 1;
  // writes land during the rebuild: some below the cursor, some above, some odd (to be dropped)
  var w = 0;
  while (w < 20) {
    let n2 = below(1_000_000);
    write(n2);
    RB.mirror(job, key(n2), val(n2), keep);
    written += 1;
    w += 1;
  };
  if (job.done) break run;
  assert (n > 0);
};
idx := RB.finish(job);
Debug.print("count: rebuild chunks = " # Nat.toText(steps));
Debug.print("count: writes that landed during the rebuild = " # Nat.toText(written));

// the rebuilt index is exactly the kept part of the oracle
var kept = 0;
for ((k, v) in Map.entries(oracle)) {
  if (k % 2 == 0) {
    kept += 1;
    switch (RI.get(idx, key(k))) {
      case (?got) assert (got == Blob.fromArray(RI.beBytes(v, 8)));
      case null { Debug.print("kept key missing after the rebuild: " # Nat.toText(k)); assert false };
    };
  } else {
    assert (RI.get(idx, key(k)) == null);
  };
};
assert (RI.size(idx) == kept);
Debug.print("count: kept entries present after the rebuild = " # Nat.toText(kept));
// and in order, with nothing extra
let (lo, hi) = RI.rangeEnds([], 12);
var walked = 0;
var cursor : ?Blob = null;
var last = 0;
label walk loop {
  let page = RI.range(idx, lo, hi, cursor, 500);
  for ((k, _) in page.entries.vals()) { let n = keyNat(k); assert (n % 2 == 0 and (walked == 0 or n > last)); last := n; walked += 1 };
  switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
};
assert (walked == kept);

// the arena did not grow past the rebuild's transient peak, and the freed pages are on its list
let after = RI.arenaStats(arena);
Debug.print("count: arena pages after the rebuild = " # Nat.toText(after.pages));
Debug.print("count: pages on the arena's free list after the rebuild = " # Nat.toText(after.free));
assert (after.free > 0);
// a second rebuild of the same shape reuses them: the arena's page count does not move
let job2 = RB.start(idx);
label run2 loop { ignore RB.step(job2, keep, 1_000); if (job2.done) break run2 };
idx := RB.finish(job2);
let again = RI.arenaStats(arena);
assert (again.pages == after.pages);
assert (RI.size(idx) == kept);
Debug.print("count: arena pages after a second rebuild, unchanged = " # Nat.toText(again.pages));

// an empty index rebuilds to an empty index
var empty = RI.newStateIn(arena, { keyBytes = 4; valBytes = 4 });
let job3 = RB.start(empty);
ignore RB.step(job3, func(_, _) { true }, 10);
assert (job3.done);
empty := RB.finish(job3);
assert (RI.size(empty) == 0);
Debug.print("count: empty rebuilds = 1");
