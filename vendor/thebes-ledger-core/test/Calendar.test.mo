// Calendar.test.mo — the journal calendar: weekday arithmetic against known dates,
// business-day classification with an Egyptian-style Friday/Saturday weekend and
// holidays, and the four shift policies over every day of a year.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import D "../src/journal/CivilDate";
import Cal "../src/journal/Calendar";

func day(y : Nat, m : Nat, d : Nat) : Nat { switch (D.fromCivil(y, m, d)) { case (?x) x; case null { assert false; 0 } } };

// weekday vectors: 1970-01-01 Thursday (3); 2026-09-09 Wednesday (2); 2000-01-01 Saturday (5); 2024-02-29 Thursday (3)
assert (Cal.weekday(day(1970, 1, 1)) == 3);
assert (Cal.weekday(day(2026, 9, 9)) == 2);
assert (Cal.weekday(day(2000, 1, 1)) == 5);
assert (Cal.weekday(day(2024, 2, 29)) == 3);
Debug.print("count: weekday vectors = 4");

let egypt : Cal.Calendar = {
  restDays = [4, 5];   // Friday, Saturday
  holidays = Cal.sortedHolidays([day(2026, 1, 7), day(2026, 1, 25), day(2026, 4, 25), day(2026, 7, 23), day(2026, 10, 6), day(2026, 7, 23)]);
};
assert (Cal.validate(egypt) == null);
assert (egypt.holidays.size() == 5);        // duplicate dropped
assert (Cal.validate({ restDays = [0, 1, 2, 3, 4, 5, 6]; holidays = [] }) != null);
assert (Cal.validate({ restDays = [7]; holidays = [] }) != null);
assert (Cal.validate({ restDays = [4, 4]; holidays = [] }) != null);
assert (Cal.validate({ restDays = []; holidays = [10, 5] }) != null);
Debug.print("count: calendar validation checks = 5");

// classification over 2026
var business = 0; var rest = 0; var hol = 0;
var d = day(2026, 1, 1);
let last = day(2026, 12, 31);
while (d <= last) {
  let wd = Cal.weekday(d);
  let isRest = wd == 4 or wd == 5;
  let isHol = d == day(2026, 1, 7) or d == day(2026, 1, 25) or d == day(2026, 4, 25) or d == day(2026, 7, 23) or d == day(2026, 10, 6);
  assert (Cal.isBusinessDay(egypt, d) == (not isRest and not isHol));
  if (Cal.isBusinessDay(egypt, d)) business += 1 else if (isRest) rest += 1 else hol += 1;
  d += 1;
};
Debug.print("count: days classified in 2026 = " # Nat.toText(business + rest + hol));
Debug.print("count: business days in 2026 = " # Nat.toText(business));
assert (business + rest + hol == 365);
// 2026 has 52 Fridays and 52 Saturdays; 2026-01-25 falls on a Sunday and 2026-04-25 on a Saturday (rest day, not counted as holiday)
assert (rest == 104 and hol == 4 and business == 257);

// shift policies over every non-business day of 2026
var shifted = 0; var rejected = 0; var unchanged = 0;
d := day(2026, 1, 1);
while (d <= last) {
  switch (Cal.apply(egypt, #reject, d)) { case (#ok(null)) unchanged += 1; case (#err(_)) rejected += 1; case (#ok(?_)) assert false };
  switch (Cal.apply(egypt, #next, d)) {
    case (#ok(null)) {};
    case (#ok(?s)) { assert (s.effective > d and Cal.isBusinessDay(egypt, s.effective)); var k = d; while (k < s.effective) { assert (not Cal.isBusinessDay(egypt, k)); k += 1 }; shifted += 1 };
    case (#err(_)) assert false;
  };
  switch (Cal.apply(egypt, #previous, d)) {
    case (#ok(null)) {};
    case (#ok(?s)) { assert (s.effective < d and Cal.isBusinessDay(egypt, s.effective)); var k = s.effective + 1; while (k <= d) { assert (not Cal.isBusinessDay(egypt, k)); k += 1 }; shifted += 1 };
    case (#err(_)) assert false;
  };
  switch (Cal.apply(egypt, #nearest, d)) {
    case (#ok(null)) {};
    case (#ok(?s)) {
      let n = Cal.nextBusinessDay(egypt, d);
      let p = switch (Cal.previousBusinessDay(egypt, d)) { case (?x) x; case null 0 };
      assert (s.effective == (if (d - p < n - d) p else n));
      shifted += 1;
    };
    case (#err(_)) assert false;
  };
  d += 1;
};
assert (unchanged == 257 and rejected == 108);
Debug.print("count: value dates shifted by next/previous/nearest = " # Nat.toText(shifted));
Debug.print("count: value dates rejected under the reject policy = " # Nat.toText(rejected));
assert (shifted == 3 * 108);
// a Friday in a Thursday-holiday week: next -> Sunday, previous -> Wednesday, nearest -> Wednesday (2 days) vs Sunday (2 days): tie goes forward
let thuHol = day(2026, 7, 23);                       // Thursday holiday
let fri = thuHol + 1;
assert (Cal.apply(egypt, #next, fri) == #ok(?{ requested = fri; effective = fri + 2 }));
assert (Cal.apply(egypt, #previous, fri) == #ok(?{ requested = fri; effective = fri - 2 }));
assert (Cal.apply(egypt, #nearest, fri) == #ok(?{ requested = fri; effective = fri + 2 }));
Debug.print("count: tie-break and holiday-run checks = 3");
