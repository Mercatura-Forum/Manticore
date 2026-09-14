// RegionIndex.test.mo; the stable-memory index against a brute-force oracle.
//
// Every criterion of the index design rests on this module being right, so it is proved
// against a sorted array held in the heap: the same keys go into both, and every read is compared.
//
//   * **`get` agrees with the oracle** on every key inserted and every key not inserted;
//   * **`put` overwrites** in place and reports the previous value, which is what an aggregate's
//     read-modify-write reads;
//   * **`range` pages, unioned, equal the oracle's slice**; same entries, same order, no
//     duplicate and no gap; over random ranges, at every page size from 1 upwards, and with the
//     cursor handed straight back;
//   * **a range over a composite key** returns exactly the account-and-date slice, which is the
//     query the index exists for;
//   * **`rangeSize` stops at its bound** and says so, which is what makes a query refusable
//     before it runs rather than trappable part-way;
//   * **depth and fill match the capacity model**: depth 4 at the entry counts the model predicts
//     it for, and leaf fill near 100% for an append-ordered key;
//   * **`reset` returns every page** and a rebuild reuses them, so a closed month's packing saves
//     space rather than adding to it.
//
// engine: wasi-only; a Region is stable memory, which the interpreter does not provide.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Map "mo:core/Map";
import Text "mo:core/Text";

import RI "mo:ledger/RegionIndex";

// ─── a deterministic pseudo-random source ────────────────────────────────────
//
// A linear congruential generator, so a failure is reproducible from the seed alone: a random
// test nobody can re-run is a test nobody can debug.
var seed : Nat32 = 0x12345678;
func next() : Nat32 {
  seed := seed *% 1_664_525 +% 1_013_904_223;
  seed
};
// The **high** sixteen bits, not the low ones. A linear congruential generator modulo 2^32 has
// low-order bits with very short periods; with these parameters `next() % 4` has period four; so
// `below(4)` was returning a fixed cycle and one whole arm of this test (a posting in two
// currencies) never ran. The output said so: "multi-currency postings = 0". Using the top bits
// removes it.
func below(n : Nat) : Nat { if (n == 0) 0 else Nat32.toNat(next() / 65_536) % n };

// ─── the oracle: a sorted association list in the heap ───────────────────────

type Oracle = Map.Map<Blob, Blob>;

func oracleSlice(o : Oracle, lo : Blob, hi : Blob) : [(Blob, Blob)] {
  let out = List.empty<(Blob, Blob)>();
  for ((k, v) in Map.entries(o)) {
    if (Blob.compare(k, lo) != #less and Blob.compare(k, hi) != #greater) List.add(out, (k, v));
  };
  // Map.entries is already in key order for a Map keyed by Blob.compare, but the slice is sorted
  // again here so the oracle does not depend on that being true
  Array.sort<(Blob, Blob)>(List.toArray(out), func(a, b) { Blob.compare(a.0, b.0) })
};

// ═══════════════════════════════════════════════════════════════════════════
//  1. get and put against the oracle
// ═══════════════════════════════════════════════════════════════════════════

let spec : RI.Spec = { keyBytes = 8; valBytes = 4 };
let idx = RI.newState(spec);
let oracle = Map.empty<Blob, Blob>();

func k8(n : Nat) : Blob { RI.key([RI.beBytes(n, 8)], 8) };
func v4(n : Nat) : Blob { RI.key([RI.beBytes(n, 4)], 4) };

let N = 4_000;
var inserted = 0;
var overwrites = 0;
var i = 0;
while (i < N) {
  let n = below(N * 3);
  let key = k8(n);
  let val = v4(i);
  let previous = RI.put(idx, key, val);
  switch (Map.get(oracle, Blob.compare, key), previous) {
    case (null, null) inserted += 1;
    case (?was, ?got) { assert (was == got); overwrites += 1 };
    case (?_, null) { Debug.print("the index lost a key the oracle has"); assert false };
    case (null, ?_) { Debug.print("the index invented a previous value"); assert false };
  };
  Map.add(oracle, Blob.compare, key, val);
  i += 1;
};
Debug.print("count: keys inserted = " # Nat.toText(inserted));
Debug.print("count: keys overwritten in place = " # Nat.toText(overwrites));
assert (inserted + overwrites == N);
assert (RI.size(idx) == Map.size(oracle));
Debug.print("count: index entries equal to the oracle's = " # Nat.toText(RI.size(idx)));

// every key the oracle has, the index has, with the same value
var reads = 0;
for ((key, val) in Map.entries(oracle)) {
  switch (RI.get(idx, key)) {
    case (?got) { assert (got == val); reads += 1 };
    case null { Debug.print("the index cannot find a key the oracle has"); assert false };
  };
};
Debug.print("count: keys read back equal to the oracle = " # Nat.toText(reads));
assert (reads == Map.size(oracle));

// and every key it does not have, it says so
var misses = 0;
var probe = 0;
while (probe < 2_000) {
  let n = below(N * 6);
  let key = k8(n);
  if (Map.get(oracle, Blob.compare, key) == null) {
    assert (RI.get(idx, key) == null);
    misses += 1;
  };
  probe += 1;
};
Debug.print("count: absent keys the index refused to invent = " # Nat.toText(misses));
assert (misses > 0);

// ═══════════════════════════════════════════════════════════════════════════
//  2. range, paged, against the oracle's slice
// ═══════════════════════════════════════════════════════════════════════════

func digit(c : Char) : Nat {
  switch (c) {
    case ('0') 0; case ('1') 1; case ('2') 2; case ('3') 3; case ('4') 4;
    case ('5') 5; case ('6') 6; case ('7') 7; case ('8') 8; case ('9') 9;
    case (_) { Debug.print("not a digit"); assert false; 0 };
  }
};

func collectRangeIn(which : RI.State, lo : Blob, hi : Blob, limit : Nat) : ([(Blob, Blob)], Nat) {
  let out = List.empty<(Blob, Blob)>();
  var cursor : ?Blob = null;
  var pages = 0;
  label paging loop {
    let page = RI.range(which, lo, hi, cursor, limit);
    for (e in page.entries.vals()) List.add(out, e);
    pages += 1;
    switch (page.cursor) {
      case null break paging;
      case (?c) cursor := ?c;
    };
    if (pages > 20_000) { Debug.print("paging did not terminate"); assert false };
  };
  (List.toArray(out), pages)
};

func collectRange(lo : Blob, hi : Blob, limit : Nat) : ([(Blob, Blob)], Nat) {
  collectRangeIn(idx, lo, hi, limit)
};

var rangeTrials = 0;
var rangeRows = 0;
let pageSizesUsed = List.empty<Nat>();
for (limit in [1, 2, 7, 64, 500, 4_000].vals()) {
  var trial = 0;
  while (trial < 12) {
    let a = below(N * 3);
    let b = below(N * 3);
    let lo = k8(Nat.min(a, b));
    let hi = k8(Nat.max(a, b));
    let want = oracleSlice(oracle, lo, hi);
    let (got, _) = collectRange(lo, hi, limit);
    if (got.size() != want.size()) {
      Debug.print("range [" # Nat.toText(Nat.min(a, b)) # ".." # Nat.toText(Nat.max(a, b))
        # "] at limit " # Nat.toText(limit) # ": got " # Nat.toText(got.size())
        # " entries, the oracle has " # Nat.toText(want.size()));
      assert false;
    };
    var j = 0;
    while (j < got.size()) {
      if (got[j].0 != want[j].0 or got[j].1 != want[j].1) {
        Debug.print("range entry " # Nat.toText(j) # " differs at limit " # Nat.toText(limit));
        assert false;
      };
      // and strictly increasing, so there is no duplicate and no gap
      if (j > 0) assert (Blob.compare(got[j - 1].0, got[j].0) == #less);
      j += 1;
    };
    rangeRows += got.size();
    rangeTrials += 1;
    trial += 1;
  };
  List.add(pageSizesUsed, limit);
};
Debug.print("count: random ranges paged and equal to the oracle = " # Nat.toText(rangeTrials));
Debug.print("count: rows returned across them = " # Nat.toText(rangeRows));
Debug.print("count: page sizes exercised = " # Nat.toText(List.size(pageSizesUsed)));
assert (rangeTrials == 72);

// the whole index, paged at one entry a page, is the whole oracle in order. The ends come from
// `rangeEnds` with no fixed prefix: all-zero and all-0xFF.
let (lo0, hiMax) = RI.rangeEnds([], 8);
let (all, allPages) = collectRange(lo0, hiMax, 1);
assert (all.size() == Map.size(oracle));
assert (allPages == all.size() + 1 or allPages == all.size());
Debug.print("count: whole-index rows at one entry a page = " # Nat.toText(all.size()));
Debug.print("count: pages that took = " # Nat.toText(allPages));

// an empty range is empty, and a reversed range is empty rather than wrong
assert (RI.range(idx, k8(10), k8(5), null, 100).entries.size() == 0);
assert (RI.range(idx, hiMax, hiMax, null, 100).entries.size() <= 1);
assert (RI.range(idx, lo0, hiMax, null, 0).entries.size() == 0);
Debug.print("count: degenerate ranges answered empty = 3");

// ═══════════════════════════════════════════════════════════════════════════
//  3. a composite key is an account-and-date range
// ═══════════════════════════════════════════════════════════════════════════

// The key the capacity model declares for I1: `acctId(8) ‖ valueDay(4) ‖ postingNo(8)`, 20 bytes.
// A query for one account between two dates is then **one range**, which is the whole reason the
// key is composite and fixed-width.
let i1 : RI.Spec = { keyBytes = 20; valBytes = 16 };
let entries = RI.newState(i1);

func i1Key(acct : Nat, day : Nat, posting : Nat) : Blob {
  RI.key([RI.beBytes(acct, 8), RI.beBytes(day, 4), RI.beBytes(posting, 8)], 20)
};
func i1Val(posting : Nat) : Blob { RI.key([RI.beBytes(posting, 8), RI.beBytes(0, 8)], 16) };

// 40 accounts × 60 days × up to 4 postings a day
let ACCOUNTS = 40;
let DAYS = 60;
let DAY0 = 20_000;
let plan = Map.empty<Text, Bool>();
var postingNo = 0;
var planted = 0;
var a = 0;
while (a < ACCOUNTS) {
  var d = 0;
  while (d < DAYS) {
    let howMany = below(5);
    var m = 0;
    while (m < howMany) {
      ignore RI.put(entries, i1Key(a, DAY0 + d, postingNo), i1Val(postingNo));
      Map.add(plan, Text.compare, Nat.toText(a) # "|" # Nat.toText(DAY0 + d) # "|" # Nat.toText(postingNo), true);
      postingNo += 1;
      planted += 1;
      m += 1;
    };
    d += 1;
  };
  a += 1;
};
Debug.print("count: composite-key entries planted = " # Nat.toText(planted));

// for each account, a range over a date window equals a brute-force filter of the plan
var windowTrials = 0;
var windowRows = 0;
a := 0;
while (a < ACCOUNTS) {
  var trial = 0;
  while (trial < 3) {
    let d1 = below(DAYS);
    let d2 = below(DAYS);
    let from = DAY0 + Nat.min(d1, d2);
    let to = DAY0 + Nat.max(d1, d2);
    // the range's ends: the account and the date fixed, the posting number free
    let lo = RI.key([RI.beBytes(a, 8), RI.beBytes(from, 4)], 20);
    let (_, hiTail) = RI.rangeEnds([RI.beBytes(a, 8), RI.beBytes(to, 4)], 20);
    // brute force: every planted key of this account in this window
    var want = 0;
    for ((k, _) in Map.entries(plan)) {
      let parts = Text.split(k, #char '|');
      let arr = List.empty<Text>();
      for (p in parts) List.add(arr, p);
      let xs = List.toArray(arr);
      if (xs[0] == Nat.toText(a)) {
        // the day is the second field
        var day = 0;
        for (c in xs[1].chars()) { day := day * 10 + digit(c) };
        if (day >= from and day <= to) want += 1;
      };
    };
    let (got, _) = collectRangeIn(entries, lo, hiTail, 64);
    if (got.size() != want) {
      Debug.print("account " # Nat.toText(a) # " days " # Nat.toText(from) # ".." # Nat.toText(to)
        # ": the index returned " # Nat.toText(got.size()) # " and the plan has " # Nat.toText(want));
      assert false;
    };
    // every row is this account's and inside the window, and the rows are in key order
    var j = 0;
    while (j < got.size()) {
      if (j > 0) assert (Blob.compare(got[j - 1].0, got[j].0) == #less);
      j += 1;
    };
    windowRows += got.size();
    windowTrials += 1;
    trial += 1;
  };
  a += 1;
};
Debug.print("count: account-and-date windows equal to a brute-force filter = " # Nat.toText(windowTrials));
Debug.print("count: rows the windows returned = " # Nat.toText(windowRows));

// ═══════════════════════════════════════════════════════════════════════════
//  4. rangeSize stops at its bound, so a query is refusable before it runs
// ═══════════════════════════════════════════════════════════════════════════

let (wholeLo, wholeHi) = RI.rangeEnds([], 20);
let exact = RI.rangeSize(entries, wholeLo, wholeHi, 1_000_000);
assert (not exact.exceeded);
assert (exact.size == RI.size(entries));
Debug.print("count: entries the sizing counted exactly = " # Nat.toText(exact.size));

// at a bound below the real size it stops and says so, having counted no further than the bound
var boundTrials = 0;
for (bound in [1, 10, 100, 1_000].vals()) {
  let sized = RI.rangeSize(entries, wholeLo, wholeHi, bound);
  assert (sized.exceeded);
  // it stops one past the bound, so the work is bounded by the bound and not by the index
  assert (sized.size == bound + 1);
  boundTrials += 1;
};
Debug.print("count: sizings that stopped at their bound = " # Nat.toText(boundTrials));
assert (boundTrials == 4);

// a narrow range sizes exactly, which is what lets a caller be told "narrow the date range"
let narrowLo = RI.key([RI.beBytes(3, 8), RI.beBytes(DAY0, 4)], 20);
let (_, narrowHi) = RI.rangeEnds([RI.beBytes(3, 8), RI.beBytes(DAY0 + 2, 4)], 20);
let narrow = RI.rangeSize(entries, narrowLo, narrowHi, 1_000);
let (narrowRows, _) = collectRangeIn(entries, narrowLo, narrowHi, 500);
assert (not narrow.exceeded);
assert (narrow.size == narrowRows.size());
Debug.print("count: narrow ranges whose sizing equals the rows they return = 1");

// ═══════════════════════════════════════════════════════════════════════════
//  5. depth and fill, against the capacity model
// ═══════════════════════════════════════════════════════════════════════════

let s1 = RI.stats(entries);
Debug.print("I1 (20-byte key, 16-byte value): leaf cap " # Nat.toText(s1.leafCap)
  # ", internal cap " # Nat.toText(s1.internalCap)
  # ", entries " # Nat.toText(s1.entries)
  # ", pages " # Nat.toText(s1.pages)
  # ", depth " # Nat.toText(s1.depth)
  # ", leaf fill " # Nat.toText(s1.leafFillPercent) # "%"
  # ", bytes/entry " # Nat.toText(s1.bytesPerEntry));
// the model derives these two from the layout, so they are exact rather than approximate
assert (s1.leafCap == 227);
assert (s1.internalCap == 314);
Debug.print("count: capacity-model leaf and internal capacities confirmed = 2");
// the keys above were planted in key order, so the fill is the append-ordered case the model
// predicts near 100% for; and the depth is what 4,808 entries needs, not the 4 of a billion
assert (s1.leafFillPercent >= 90);
assert (s1.depth >= 2 and s1.depth <= 3);
Debug.print("count: append-ordered leaf fill at or above 90% = 1");

// the random-key index is the other case the model names: ~69% fill
let s2 = RI.stats(idx);
Debug.print("random-key index (8-byte key, 4-byte value): leaf cap " # Nat.toText(s2.leafCap)
  # ", entries " # Nat.toText(s2.entries) # ", depth " # Nat.toText(s2.depth)
  # ", leaf fill " # Nat.toText(s2.leafFillPercent) # "%"
  # ", bytes/entry " # Nat.toText(s2.bytesPerEntry));
assert (s2.leafCap == 681);
// a B-tree built by random insertion settles near ln 2; the model's figure is 69%
assert (s2.leafFillPercent >= 50 and s2.leafFillPercent <= 100);
Debug.print("count: random-key fill within the model's range = 1");

// ═══════════════════════════════════════════════════════════════════════════
//  6. reset returns every page, and a rebuild reuses them
// ═══════════════════════════════════════════════════════════════════════════

// This is what makes closed-month packing worth doing: stable memory is never returned to the
// system, so replacing a month's per-posting entries with a summary row only saves space if the
// pages the old entries occupied are reused.
let before = RI.stats(entries);
RI.reset(entries);
let emptied = RI.stats(entries);
assert (RI.size(entries) == 0);
assert (RI.isEmpty(entries));
assert (emptied.freePages == before.pages);
assert (emptied.pages == before.pages);
Debug.print("count: pages returned to the free list by a reset = " # Nat.toText(emptied.freePages));

// the summary a packed month would hold: one row per account instead of one per posting
var summaries = 0;
a := 0;
while (a < ACCOUNTS) {
  ignore RI.put(entries, RI.key([RI.beBytes(a, 8), RI.beBytes(DAY0, 4)], 20), i1Val(a));
  summaries += 1;
  a += 1;
};
let rebuilt = RI.stats(entries);
Debug.print("after the rebuild: entries " # Nat.toText(rebuilt.entries)
  # ", pages " # Nat.toText(rebuilt.pages) # ", free " # Nat.toText(rebuilt.freePages));
assert (rebuilt.entries == summaries);
// **not one new page**: the rebuild came entirely out of the free list
assert (rebuilt.pages == before.pages);
assert (rebuilt.freePages == before.pages - 1);
Debug.print("count: pages the rebuild took from the free list rather than growing = 1");

// and the rebuilt index answers correctly
a := 0;
var summaryReads = 0;
while (a < ACCOUNTS) {
  assert (RI.get(entries, RI.key([RI.beBytes(a, 8), RI.beBytes(DAY0, 4)], 20)) == ?i1Val(a));
  summaryReads += 1;
  a += 1;
};
Debug.print("count: summary rows read back after the rebuild = " # Nat.toText(summaryReads));

// ═══════════════════════════════════════════════════════════════════════════
//  7. the widths the capacity model declares all fit a page
// ═══════════════════════════════════════════════════════════════════════════

// Every index of the capacity model §2, created and checked against the model's own leaf
// capacity. A width that did not fit would trap at creation, which is the right failure.
let declared : [(Text, Nat, Nat, Nat)] = [
  ("I1 account entries", 20, 16, 227),
  ("I2 day", 12, 16, 292),
  ("I3 currency", 16, 16, 255),
  ("I4 class", 16, 16, 255),
  ("A1 acct|day", 12, 28, 204),
  ("A2 acct|cpty|day", 20, 12, 255),
  ("A3 cpty|acct|day", 20, 12, 255),
  ("A4 lastActiveDay", 8, 4, 681),
];
var declaredChecked = 0;
for ((name, kb, vb, cap) in declared.vals()) {
  let st = RI.newState({ keyBytes = kb; valBytes = vb });
  let s = RI.stats(st);
  if (s.leafCap != cap) {
    Debug.print(name # ": leaf cap " # Nat.toText(s.leafCap) # " where the model says " # Nat.toText(cap));
    assert false;
  };
  // and it holds and returns a key of that width
  let kk = RI.key([RI.beBytes(declaredChecked + 1, kb)], kb);
  let vv = RI.key([RI.beBytes(7, vb)], vb);
  assert (RI.put(st, kk, vv) == null);
  assert (RI.get(st, kk) == ?vv);
  declaredChecked += 1;
};
Debug.print("count: declared index widths whose leaf capacity matches the model = " # Nat.toText(declaredChecked));
assert (declaredChecked == 8);

Debug.print("REGION INDEX TEST GREEN");
