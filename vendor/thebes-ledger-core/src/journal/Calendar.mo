/// Calendar.mo: working-day calendar and value-date shift policy.
///
/// A calendar is data: the weekly rest days (0 = Monday … 6 = Sunday, ISO
/// 8601 weekday numbering) and a sorted list of holiday day numbers. A value
/// date that is not a business day is handled by the declared policy:
///   #reject    refuse the posting with a typed error
///   #previous  move back to the last business day
///   #next      move forward to the next business day
///   #nearest   the closer of the two (ties go forward, TARGET2 "modified
///              following" style tie-break is not assumed; equal distance → #next)
/// The journal's own rule (posting date inside the period, value date within
/// drift) is applied after the shift, unchanged. Every function is pure.

import Array "mo:core/Array";
import Nat "mo:core/Nat";

import CivilDate "CivilDate";

module {

  public type Weekday = Nat;   // 0 = Monday … 6 = Sunday

  public type Calendar = {
    restDays : [Weekday];       // e.g. [4, 5] for Friday and Saturday
    holidays : [CivilDate.Day]; // sorted ascending, no duplicates
  };

  public type ShiftPolicy = { #reject; #previous; #next; #nearest };

  public type Shift = { requested : CivilDate.Day; effective : CivilDate.Day };

  /// 1970-01-01 was a Thursday (weekday 3).
  public func weekday(day : CivilDate.Day) : Weekday { (day + 3) % 7 };

  public func validate(c : Calendar) : ?Text {
    if (c.restDays.size() > 6) return ?"a week needs at least one working day";
    for (d in c.restDays.vals()) { if (d > 6) return ?"rest day must be 0..6" };
    var i = 0;
    while (i < c.restDays.size()) {
      var j = i + 1;
      while (j < c.restDays.size()) { if (c.restDays[i] == c.restDays[j]) return ?"duplicate rest day"; j += 1 };
      i += 1;
    };
    i := 1;
    while (i < c.holidays.size()) {
      if (c.holidays[i] <= c.holidays[i - 1]) return ?"holidays must be sorted ascending without duplicates";
      i += 1;
    };
    null
  };

  func isHoliday(c : Calendar, day : CivilDate.Day) : Bool {
    var lo = 0; var hi = c.holidays.size();
    while (lo < hi) {
      let mid = (lo + hi) / 2;
      if (c.holidays[mid] == day) return true;
      if (c.holidays[mid] < day) lo := mid + 1 else hi := mid;
    };
    false
  };

  public func isBusinessDay(c : Calendar, day : CivilDate.Day) : Bool {
    let wd = weekday(day);
    for (r in c.restDays.vals()) { if (r == wd) return false };
    not isHoliday(c, day)
  };

  /// Nearest business day on or after `day` (bounded search: a valid calendar
  /// has at least one working weekday, so at most 7 + holiday-run steps).
  public func nextBusinessDay(c : Calendar, day : CivilDate.Day) : CivilDate.Day {
    var d = day;
    while (not isBusinessDay(c, d)) { d += 1 };
    d
  };

  /// Nearest business day on or before `day`; null if none exists at or after day 0.
  public func previousBusinessDay(c : Calendar, day : CivilDate.Day) : ?CivilDate.Day {
    var d = day;
    while (not isBusinessDay(c, d)) { if (d == 0) return null; d -= 1 };
    ?d
  };

  /// Apply the policy. `#ok(null)` means the date is a business day and stands;
  /// `#ok(?shift)` records where it moved; `#err` is the reject policy or an
  /// impossible backward shift.
  public func apply(c : Calendar, policy : ShiftPolicy, requested : CivilDate.Day) : { #ok : ?Shift; #err : Text } {
    if (isBusinessDay(c, requested)) return #ok(null);
    switch (policy) {
      case (#reject) #err("value date is not a business day");
      case (#next) #ok(?{ requested; effective = nextBusinessDay(c, requested) });
      case (#previous) {
        switch (previousBusinessDay(c, requested)) { case (?p) #ok(?{ requested; effective = p }); case null #err("no earlier business day exists") }
      };
      case (#nearest) {
        let n = nextBusinessDay(c, requested);
        switch (previousBusinessDay(c, requested)) {
          case (?p) {
            let back : Nat = requested - p;      // p <= requested by construction
            let fwd : Nat = n - requested;       // n >= requested by construction
            if (back < fwd) #ok(?{ requested; effective = p }) else #ok(?{ requested; effective = n })
          };
          case null #ok(?{ requested; effective = n });
        }
      };
    }
  };

  public func sortedHolidays(days : [CivilDate.Day]) : [CivilDate.Day] {
    let s = Array.sort<CivilDate.Day>(days, Nat.compare);
    // drop duplicates
    var out : [CivilDate.Day] = [];
    for (d in s.vals()) { if (out.size() == 0 or out[out.size() - 1] != d) out := Array.concat(out, [d]) };
    out
  };
};
