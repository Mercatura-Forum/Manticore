// Leadsheet.test.mo — acceptance criterion 8 on the pure mapper: every account
// falls in exactly one range of the 28-range schema; unmapped accounts are
// reported; overlapping schemas are rejected.
//
// engine: wasi-only — the journal core now keeps its per-posting state in a stable-memory Region
// (`JournalCore.postingRows`), and the moc interpreter provides no Region. The dual-engine check this
// loses was worth having, and the loss is stated here rather than hidden: the reason the state moved
// is that a heap map per posting makes the heap grow with the journal, which is the one thing a
// contract's heap must not do. Every test below still runs under wasmtime, which is the engine the
// chain runs.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Array "mo:core/Array";
import L "../src/journal/Leadsheet";
import T "../src/journal/JournalTypes";
import F "support/TbSchemaFixture";

assert (F.ranges.size() == F.RANGE_COUNT and F.RANGE_COUNT == 28);
assert (L.validate(F.ranges) == null);
let sorted = L.sortByLo(F.ranges);
Debug.print("count: leadsheet schema ranges validated = " # Nat.toText(sorted.size()));
Debug.print("leadsheet schema source md5 " # F.SOURCE_MD5);

// distinct leadsheet ids == total_leadsheets_mapped in the JSON
var distinct : [Text] = [];
for (r in sorted.vals()) {
  if (Array.find<Text>(distinct, func(x) { x == r.leadsheet }) == null) { distinct := Array.concat(distinct, [r.leadsheet]) };
};
assert (distinct.size() == F.LEADSHEETS_MAPPED);
Debug.print("count: leadsheet distinct ids = " # Nat.toText(distinct.size()));

// every prefix 0000..9999: contained in at most one range (non-overlap), and
// lookup agrees with the brute-force count.
var mappedPrefixes = 0;
var unmappedPrefixes = 0;
var p = 0;
while (p < 10000) {
  let code = (if (p < 10) "000" else if (p < 100) "00" else if (p < 1000) "0" else "") # Nat.toText(p);
  let n = L.countContaining(sorted, code);
  assert (n <= 1);
  switch (L.lookup(sorted, code)) {
    case (?r) { assert (n == 1); assert (p >= r.lo and p <= r.hi); mappedPrefixes += 1 };
    case null { assert (n == 0); unmappedPrefixes += 1 };
  };
  p += 1;
};
Debug.print("count: leadsheet prefixes examined = " # Nat.toText(mappedPrefixes + unmappedPrefixes));
Debug.print("count: leadsheet prefixes mapped = " # Nat.toText(mappedPrefixes));
Debug.print("count: leadsheet prefixes unmapped = " # Nat.toText(unmappedPrefixes));
assert (mappedPrefixes + unmappedPrefixes == 10000);
// the schema covers exactly the sum of its range widths
var width = 0;
for (r in sorted.vals()) { width += r.hi - r.lo + 1 };
assert (width == mappedPrefixes);

// sub-accounts map by prefix
assert ((switch (L.lookup(sorted, "1400.01")) { case (?r) r.leadsheet; case null "" }) == "130");
assert ((switch (L.lookup(sorted, "1000")) { case (?r) r.name; case null "" }) == "Property, Plant & Equipment");
assert (L.lookup(sorted, "9999") == null);
assert (L.lookup(sorted, "1600") == null);   // gap between 1599 and 2000 is unmapped, reported not bucketed

// account code grammar
assert (L.validateAccountCode("1500") == null);
assert (L.validateAccountCode("1400.01") == null);
assert (L.validateAccountCode("1400.ABC123") == null);
assert (L.validateAccountCode("150") != null);
assert (L.validateAccountCode("15000") != null);
assert (L.validateAccountCode("1400.") != null);
assert (L.validateAccountCode("1400.1234567") != null);
assert (L.validateAccountCode("1400-01") != null);
assert (L.validateAccountCode("abcd") != null);
Debug.print("count: account code grammar checks = 9");

// overlapping and malformed schemas are rejected
let overlap : [T.LeadsheetRange] = [
  { lo = 1000; hi = 1099; leadsheet = "1"; name = "a"; category = "c"; cycle = "x" },
  { lo = 1099; hi = 1200; leadsheet = "2"; name = "b"; category = "c"; cycle = "x" },
];
assert (L.validate(overlap) != null);
assert (L.validate([]) != null);
assert (L.validate([{ lo = 20; hi = 10; leadsheet = "1"; name = "a"; category = "c"; cycle = "x" }]) != null);
assert (L.validate([{ lo = 0; hi = 10000; leadsheet = "1"; name = "a"; category = "c"; cycle = "x" }]) != null);
assert (L.validate([{ lo = 0; hi = 10; leadsheet = ""; name = "a"; category = "c"; cycle = "x" }]) != null);
Debug.print("count: leadsheet schema rejections = 5");

// mapping a trial balance partitions rows exhaustively
let tb : T.TrialBalance = {
  period = "2026-09";
  rows = [
    { account = "1500"; currency = "EGP"; periodDebits = 10; periodCredits = 0; closingDebits = 10; closingCredits = 0 },
    { account = "2000"; currency = "EGP"; periodDebits = 0; periodCredits = 10; closingDebits = 0; closingCredits = 10 },
    { account = "9999"; currency = "EGP"; periodDebits = 5; periodCredits = 5; closingDebits = 5; closingCredits = 5 },
    { account = "1500"; currency = "USD"; periodDebits = 7; periodCredits = 0; closingDebits = 7; closingCredits = 0 },
    { account = "2100"; currency = "USD"; periodDebits = 0; periodCredits = 7; closingDebits = 0; closingCredits = 7 },
  ];
  totals = []; balanced = true; postingCount = 3;
};
let m = L.mapTrialBalance(sorted, tb);
assert (m.mapped.size() == 4 and m.unmapped.size() == 1);
assert (m.unmapped[0].account == "9999");
assert (m.mapped.size() + m.unmapped.size() == tb.rows.size());
// leadsheet "140" (cash) EGP closing debits 10
var found = false;
for (t in m.leadsheets.vals()) { if (t.leadsheet == "140" and t.currency == "EGP") { assert (t.closingDebits == 10); found := true } };
assert found;
Debug.print("count: leadsheet trial-balance rows examined = " # Nat.toText(tb.rows.size()));
Debug.print("count: leadsheet trial-balance rows mapped = " # Nat.toText(m.mapped.size()));
Debug.print("count: leadsheet trial-balance rows unmapped = " # Nat.toText(m.unmapped.size()));
