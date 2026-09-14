/// CivilDate.mo: proleptic Gregorian calendar arithmetic on day numbers.
///
/// A `Day` is the number of whole days since 1970-01-01 (UTC). The journal
/// stores posting dates and value dates as `Day` so that period membership,
/// back-dating and value-dated balances are integer comparisons. Conversion to
/// and from year/month/day uses the era-based algorithms published by
/// Howard Hinnant ("chrono-Compatible Low-Level Date Algorithms"), which are
/// exact for every date in the range supported here (years 1970..9999).
///
/// Every function is total and pure; invalid input yields `null`, never a trap.

import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Char "mo:core/Char";
import Nat32 "mo:core/Nat32";

module {

  public type Day = Nat;

  public let NANOS_PER_DAY : Nat = 86_400_000_000_000;
  public let MIN_YEAR : Nat = 1970;
  public let MAX_YEAR : Nat = 9999;

  public func isLeapYear(y : Nat) : Bool {
    (y % 4 == 0 and y % 100 != 0) or y % 400 == 0
  };

  public func daysInMonth(y : Nat, m : Nat) : Nat {
    switch (m) {
      case 1 31; case 3 31; case 5 31; case 7 31; case 8 31; case 10 31; case 12 31;
      case 4 30; case 6 30; case 9 30; case 11 30;
      case 2 { if (isLeapYear(y)) 29 else 28 };
      case _ 0;
    }
  };

  /// Day number of a civil date, or null if the date is not a valid calendar
  /// date within [MIN_YEAR, MAX_YEAR].
  public func fromCivil(y : Nat, m : Nat, d : Nat) : ?Day {
    if (y < MIN_YEAR or y > MAX_YEAR or m < 1 or m > 12 or d < 1 or d > daysInMonth(y, m)) return null;
    let yy : Int = if (m <= 2) (y : Int) - 1 else y;
    let era : Int = yy / 400;
    let yoe : Int = yy - era * 400;
    let mp : Int = if (m > 2) (m : Int) - 3 else (m : Int) + 9;
    let doy : Int = (153 * mp + 2) / 5 + (d : Int) - 1;
    let doe : Int = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days : Int = era * 146097 + doe - 719468;
    if (days < 0) null else ?Int.abs(days)
  };

  /// Civil date (year, month, day) of a day number.
  public func toCivil(day : Day) : (Nat, Nat, Nat) {
    let z : Int = (day : Int) + 719468;
    let era : Int = z / 146097;
    let doe : Int = z - era * 146097;
    let yoe : Int = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y : Int = yoe + era * 400;
    let doy : Int = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp : Int = (5 * doy + 2) / 153;
    let d : Int = doy - (153 * mp + 2) / 5 + 1;
    let m : Int = if (mp < 10) mp + 3 else mp - 9;
    let yy : Int = if (m <= 2) y + 1 else y;
    (Int.abs(yy), Int.abs(m), Int.abs(d))
  };

  func pad2(n : Nat) : Text { (if (n < 10) "0" else "") # Nat.toText(n) };
  func pad4(n : Nat) : Text {
    (if (n < 10) "000" else if (n < 100) "00" else if (n < 1000) "0" else "") # Nat.toText(n)
  };

  /// ISO 8601 calendar date, "YYYY-MM-DD".
  public func toText(day : Day) : Text {
    let (y, m, d) = toCivil(day);
    pad4(y) # "-" # pad2(m) # "-" # pad2(d)
  };

  /// Parse "YYYY-MM-DD" strictly (exactly ten characters, ASCII digits and two
  /// hyphens). Returns null on any deviation.
  public func fromText(t : Text) : ?Day {
    let cs = Text.toArray(t);
    if (cs.size() != 10) return null;
    if (cs[4] != '-' or cs[7] != '-') return null;
    func digit(c : Char) : ?Nat {
      if (c >= '0' and c <= '9') ?(Nat32.toNat(Char.toNat32(c)) - 48) else null
    };
    func num(from : Nat, to : Nat) : ?Nat {
      var acc : Nat = 0;
      var i = from;
      while (i < to) {
        switch (digit(cs[i])) { case (?v) { acc := acc * 10 + v }; case null return null };
        i += 1;
      };
      ?acc
    };
    switch (num(0, 4), num(5, 7), num(8, 10)) {
      case (?y, ?m, ?d) fromCivil(y, m, d);
      case _ null;
    }
  };

  /// Day number of a nanosecond timestamp (IC `Time.now()` units).
  public func fromNanos(ns : Nat) : Day { ns / NANOS_PER_DAY };

  /// Nanosecond timestamp of midnight UTC at the start of `day`.
  public func toNanos(day : Day) : Nat { day * NANOS_PER_DAY };

  /// Absolute difference in days.
  public func distance(a : Day, b : Day) : Nat { if (a >= b) a - b else b - a };
};
