// CivilDate.test.mo; calendar arithmetic against independently computed vectors
// (Python datetime, see the comment on each vector) and exhaustive round-trip.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import D "../src/journal/CivilDate";

// (y, m, d, days since 1970-01-01); values from Python: (date(y,m,d) - date(1970,1,1)).days
let vectors : [(Nat, Nat, Nat, Nat)] = [
  (1970, 1, 1, 0), (1970, 1, 2, 1), (1999, 12, 31, 10956), (2000, 1, 1, 10957),
  (2000, 2, 29, 11016), (2000, 3, 1, 11017), (2024, 2, 29, 19782), (2026, 1, 1, 20454),
  (2026, 1, 31, 20484), (2026, 2, 1, 20485), (2026, 2, 28, 20512), (2026, 9, 9, 20705),
  (2100, 2, 28, 47540), (2100, 3, 1, 47541), (9999, 12, 31, 2932896),
];

var checked = 0;
for ((y, m, d, expected) in vectors.vals()) {
  switch (D.fromCivil(y, m, d)) {
    case (?day) { assert (day == expected); assert (D.toCivil(day) == (y, m, d)) };
    case null { assert false };
  };
  checked += 1;
};
Debug.print("count: civil-date vectors checked = " # Nat.toText(checked));

// Exhaustive round trip over every day from 1970-01-01 to 2200-12-31.
let last = switch (D.fromCivil(2200, 12, 31)) { case (?d) d; case null 0 };
assert (last > 0);
var day = 0;
var roundTrips = 0;
var prevCivil = (0, 0, 0);
while (day <= last) {
  let c = D.toCivil(day);
  switch (D.fromCivil(c.0, c.1, c.2)) {
    case (?back) { assert (back == day) };
    case null { assert false };
  };
  // strictly increasing calendar order
  if (day > 0) { assert (c.0 > prevCivil.0 or (c.0 == prevCivil.0 and (c.1 > prevCivil.1 or (c.1 == prevCivil.1 and c.2 > prevCivil.2)))) };
  prevCivil := c;
  roundTrips += 1;
  day += 1;
};
Debug.print("count: civil-date exhaustive round trips = " # Nat.toText(roundTrips));
assert (roundTrips == last + 1);

// Invalid dates are rejected, never trapped on.
let invalid : [(Nat, Nat, Nat)] = [(1969, 12, 31), (2026, 2, 29), (2100, 2, 29), (2026, 13, 1), (2026, 0, 1), (2026, 4, 31), (2026, 1, 0), (10000, 1, 1)];
var rejected = 0;
for ((y, m, d) in invalid.vals()) { assert (D.fromCivil(y, m, d) == null); rejected += 1 };
Debug.print("count: civil-date invalid dates rejected = " # Nat.toText(rejected));

// Text form.
assert (D.toText(20705) == "2026-09-09");
assert (D.toText(0) == "1970-01-01");
assert (D.fromText("2026-09-09") == ?20705);
assert (D.fromText("2026-9-9") == null);
assert (D.fromText("2026-09-09T") == null);
assert (D.fromText("2026/09/09") == null);
assert (D.fromText("2026-02-30") == null);
assert (D.fromNanos(20705 * 86_400_000_000_000 + 12_345) == 20705);
assert (D.toNanos(20705) == 20705 * 86_400_000_000_000);
assert (D.distance(10, 25) == 15 and D.distance(25, 10) == 15);
Debug.print("count: civil-date text checks = 10");
