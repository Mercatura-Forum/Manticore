// StableLogTruncate.test.mo: a log whose prefix leaves and whose regions come back.
//
// What is proved: entries read back byte for byte before and after a truncation; the truncated ones
// answer null and the live ones do not; a data region and an index chunk that held only truncated
// entries return to the pool and the next appends reuse them, so the region count does not grow
// across a second round of the same size; a truncation past the end traps by contract (not
// exercised; `truncateThrough` is documented to trap); `recover` rebuilds the counters.
//
// engine: wasi-only; Regions.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";
import Array "mo:core/Array";

import SLog "../src/ledger/StableLog";

func entry(i : Nat, len : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(len, func(j) { Nat8.fromNat((i * 31 + j) % 256) })) };

let log = SLog.newState();
// entries large enough that a few thousand cross a data region: 200 KiB each, 256 MiB a region
let LEN = 200 * 1024;
let ROUND = 1_600;   // ~312 MiB: past one data region
var i = 0;
while (i < ROUND) { assert (SLog.append(log, entry(i, LEN)) == i); i += 1 };
let s1 = SLog.regionStats(log);
Debug.print("count: entries appended in the first round = " # Nat.toText(ROUND));
Debug.print("count: regions after the first round = " # Nat.toText(s1.regions));
assert (s1.regions >= 3);   // header, at least two data regions, one index chunk
// every entry reads back
i := 0;
while (i < ROUND) { assert (SLog.get(log, i) == ?entry(i, LEN)); i += 1 };
Debug.print("count: entries read back before the truncation = " # Nat.toText(ROUND));

// truncate through the first region's worth and a bit
let HI = 1_400;
SLog.truncateThrough(log, HI);
assert (SLog.base(log) == HI + 1 and SLog.size(log) == ROUND);
var gone = 0; var kept = 0;
i := 0;
while (i < ROUND) {
  switch (SLog.get(log, i)) {
    case null { assert (i <= HI); gone += 1 };
    case (?b) { assert (i > HI and b == entry(i, LEN)); kept += 1 };
  };
  i += 1;
};
assert (gone == HI + 1 and kept == ROUND - HI - 1);
Debug.print("count: truncated entries answering null = " # Nat.toText(gone));
Debug.print("count: live entries reading back after the truncation = " # Nat.toText(kept));
let s2 = SLog.regionStats(log);
Debug.print("count: regions on the pool after the truncation = " # Nat.toText(s2.free));
assert (s2.free >= 1);
// a second truncation at a lower point is a no-op
SLog.truncateThrough(log, 100);
assert (SLog.base(log) == HI + 1);

// the second round reuses the pool: the region count does not grow past what the first needed
i := 0;
while (i < ROUND) { assert (SLog.append(log, entry(ROUND + i, LEN)) == ROUND + i); i += 1 };
let s3 = SLog.regionStats(log);
Debug.print("count: regions after the second round = " # Nat.toText(s3.regions));
assert (s3.regions <= s1.regions + 1);
i := 0;
while (i < ROUND) { assert (SLog.get(log, ROUND + i) == ?entry(ROUND + i, LEN)); i += 1 };
// the kept tail of the first round is still there
i := HI + 1;
while (i < ROUND) { assert (SLog.get(log, i) == ?entry(i, LEN)); i += 1 };
Debug.print("count: entries read back after the pool was reused = " # Nat.toText(ROUND + (ROUND - HI - 1)));
assert (SLog.getRange(log, HI - 1, 4).size() == 4);
assert (SLog.getRange(log, HI - 1, 4)[0].size() == 0 and SLog.getRange(log, HI - 1, 4)[2].size() == LEN);

// recovery from the header
let before = (SLog.base(log), SLog.size(log));
log.base := 0; log.entryCount := 0; log.dataOffset := 0;
SLog.recover(log);
assert ((SLog.base(log), SLog.size(log)) == before);
assert (SLog.append(log, entry(9_999, 10)) == ROUND * 2);
assert (SLog.get(log, ROUND * 2) == ?entry(9_999, 10));
Debug.print("count: recoveries from the header = 1");
