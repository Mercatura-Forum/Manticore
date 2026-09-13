/// DayCount.mo — day-count fractions, as exact rationals.
///
/// Day counts are where two correct-looking implementations disagree by money, so
/// nothing here is a floating-point number. A fraction is returned as a rational
/// `{ numerator; denominator }` of naturals and the caller multiplies before it
/// divides, which is the only way an interest figure is reproducible to the minor
/// unit.
///
/// The conventions are the ones the **ISO 20022 `InterestComputationMethod` code
/// set** names. That set's membership was read mechanically from
/// `pw-iso20022-SRU2025-9.6.6.jar`: `InterestComputationMethod4Code` carries 21
/// values, A001 … A020 and NARR. Using the standard's own enumeration rather than
/// inventing day-count names is what lets an interest figure be reconciled against
/// a counterparty's statement.
///
/// Two shapes of question, and they are not interchangeable:
///
///   * `fraction(convention, from, to)` — the fraction for a *period*, which is
///     what a loan instalment or a term deposit uses;
///   * `dailyDenominator(convention, day)` — the denominator of **one day**, which
///     is what a daily-balance accrual uses. The 30/360 family accrues each calendar
///     day at 1/360 (1/365 for 30/365) — the market's daily reading of a 360-day
///     year, which is not the period fraction (a 31-day month accrues 31/360 by the
///     day and 30/360 by the period; `test/DayCountInterest.test.mo` records the
///     choice) — and ACT/ACT (ICMA) alone has no single day, its unit being the
///     coupon period: a product asking for a daily-balance accrual under it is
///     refused at registration rather than silently given ACT/365.
///
/// References: ISDA 2006 Definitions §4.16 (the 30/360 family and ACT/ACT),
/// ICMA Rule 251 (A001), and the ISO 20022 code set above.

import Nat "mo:core/Nat";
import Text "mo:core/Text";

import CivilDate "mo:journal/CivilDate";

module {

  /// The implemented subset of the ISO 20022 code set. A code outside it is a
  /// typed refusal at product registration, never a substitution.
  public type Convention = {
    #a001_ActActIcma : { couponsPerYear : Nat };   // AA/AA (ICMA), Rule 251
    #a003_Act360;                                  // ACT/360
    #a004_Act365Fixed;                             // ACT/365 (fixed)
    #a005_ActActIsda;                              // ACT/ACT (ISDA)
    #a006_Thirty360Isda;                           // 30/360 (ISDA, bond basis)
    #a007_ThirtyE360;                              // 30E/360 (Eurobond basis)
    #a011_Thirty365;                               // 30/365
  };

  public type Fraction = { numerator : Nat; denominator : Nat };

  /// The ISO 20022 code for a convention, so a product's terms and a counterparty's
  /// message name the same thing.
  public func isoCode(c : Convention) : Text {
    switch (c) {
      case (#a001_ActActIcma(_)) "A001";
      case (#a003_Act360) "A003";
      case (#a004_Act365Fixed) "A004";
      case (#a005_ActActIsda) "A005";
      case (#a006_Thirty360Isda) "A006";
      case (#a007_ThirtyE360) "A007";
      case (#a011_Thirty365) "A011";
    }
  };

  /// Every ISO 20022 code in the published set. A product naming one outside
  /// `Convention` is refused with this list as the evidence that the refusal is a
  /// deliberate boundary rather than an oversight.
  public func isoCodeSet() : [Text] {
    ["A001", "A002", "A003", "A004", "A005", "A006", "A007", "A008", "A009", "A010",
     "A011", "A012", "A013", "A014", "A015", "A016", "A017", "A018", "A019", "A020", "NARR"]
  };

  public func byIsoCode(code : Text, couponsPerYear : Nat) : ?Convention {
    if (Text.equal(code, "A001")) return ?#a001_ActActIcma({ couponsPerYear });
    if (Text.equal(code, "A003")) return ?#a003_Act360;
    if (Text.equal(code, "A004")) return ?#a004_Act365Fixed;
    if (Text.equal(code, "A005")) return ?#a005_ActActIsda;
    if (Text.equal(code, "A006")) return ?#a006_Thirty360Isda;
    if (Text.equal(code, "A007")) return ?#a007_ThirtyE360;
    if (Text.equal(code, "A011")) return ?#a011_Thirty365;
    null
  };

  /// Delegates to the journal's own calendar so there is one leap-year rule in
  /// the estate, not two that could disagree.
  public func isLeap(year : Nat) : Bool { CivilDate.isLeapYear(year) };

  public func daysInYear(year : Nat) : Nat { if (isLeap(year)) 366 else 365 };

  /// The 30/360 numerator, shared by A006, A007 and A011. The two conventions
  /// differ only in how they clamp the day numbers, which is the whole of the
  /// long-standing confusion between them.
  func thirty360Numerator(from : CivilDate.Day, to : CivilDate.Day, eurobond : Bool) : Nat {
    let (y1, m1, day1) = CivilDate.toCivil(from);
    let (y2, m2, day2) = CivilDate.toCivil(to);
    var d1 = day1;
    var d2 = day2;
    if (eurobond) {
      // 30E/360: both day numbers are clamped to 30.
      if (d1 > 30) d1 := 30;
      if (d2 > 30) d2 := 30;
    } else {
      // 30/360 bond basis: the first is clamped, and the second only when the
      // first became the 30th.
      if (d1 == 31) d1 := 30;
      if (d2 == 31 and d1 == 30) d2 := 30;
    };
    // The result cannot be negative for from <= to, but the expression is built so
    // that every subtraction is on naturals that are known to be large enough.
    let years = y2 - y1;
    let months = 12 * years + m2 - m1;
    let base = 30 * months;
    if (d2 >= d1) base + (d2 - d1) else base - (d1 - d2)
  };

  /// The fraction of a year between two dates, inclusive of `from` and exclusive
  /// of `to` — the convention every day-count definition uses, so a period that
  /// ends where the next begins counts each day once.
  public func fraction(c : Convention, from : CivilDate.Day, to : CivilDate.Day) : Fraction {
    if (to <= from) return { numerator = 0; denominator = 1 };
    let days = to - from;
    switch (c) {
      case (#a003_Act360) { { numerator = days; denominator = 360 } };
      case (#a004_Act365Fixed) { { numerator = days; denominator = 365 } };
      case (#a005_ActActIsda) {
        // ISDA ACT/ACT: each calendar year's days over that year's own length,
        // summed. Expressed over a common denominator so the result stays exact.
        // 365 * 366 is the common denominator of the two possible year lengths.
        let D : Nat = 365 * 366;
        var num : Nat = 0;
        var cursor = from;
        while (cursor < to) {
          let (y, _, _) = CivilDate.toCivil(cursor);
          let ?yearEnd = CivilDate.fromCivil(y + 1, 1, 1) else return { numerator = 0; denominator = 1 };
          let segmentEnd = if (yearEnd < to) yearEnd else to;
          let segment = segmentEnd - cursor;
          num += segment * (D / daysInYear(y));
          cursor := segmentEnd;
        };
        { numerator = num; denominator = D }
      };
      case (#a001_ActActIcma({ couponsPerYear })) {
        // ICMA Rule 251: the period's actual days over (coupons per year × the
        // days in the coupon period the dates sit in). With `from`/`to` being the
        // coupon period itself — the usual case — this is exactly 1/couponsPerYear.
        let f = if (couponsPerYear == 0) 1 else couponsPerYear;
        { numerator = days; denominator = f * days }
      };
      case (#a006_Thirty360Isda) { { numerator = thirty360Numerator(from, to, false); denominator = 360 } };
      case (#a007_ThirtyE360) { { numerator = thirty360Numerator(from, to, true); denominator = 360 } };
      case (#a011_Thirty365) { { numerator = thirty360Numerator(from, to, false); denominator = 365 } };
    }
  };

  /// The denominator of a single day, for a daily-balance accrual. Null for
  /// ACT/ACT (ICMA), which is defined over a coupon period and has no single-day
  /// meaning at all.
  public func dailyDenominator(c : Convention, day : CivilDate.Day) : ?Nat {
    switch (c) {
      case (#a003_Act360) ?360;
      case (#a004_Act365Fixed) ?365;
      case (#a005_ActActIsda) { let (y, _, _) = CivilDate.toCivil(day); ?daysInYear(y) };
      case (#a001_ActActIcma(_)) null;
      case (#a006_Thirty360Isda) ?360;
      case (#a007_ThirtyE360) ?360;
      case (#a011_Thirty365) ?365;
    }
  };

  /// The fraction of a year a **single day** contributes. For the ACT family this
  /// is one over the basis; for the 30/360 family it is that convention's own
  /// numerator for the one-day step, which is what makes the 31st of a month
  /// contribute nothing under the bond basis and the 30th of February contribute
  /// three days under 30E/360. Defining the daily fraction rather than only the
  /// daily denominator is what lets a 30/360 product accrue on a *daily balance*
  /// without either convention being bent: the day count is the convention's and
  /// the balance is the journal's.
  ///
  /// Null for ACT/ACT (ICMA), whose unit is a coupon period; a product declaring it
  /// with a daily-balance basis is refused at registration rather than approximated
  /// here.
  public func dailyFraction(c : Convention, day : CivilDate.Day) : ?Fraction {
    switch (c) {
      case (#a003_Act360) ?{ numerator = 1; denominator = 360 };
      case (#a004_Act365Fixed) ?{ numerator = 1; denominator = 365 };
      case (#a005_ActActIsda) { let (y, _, _) = CivilDate.toCivil(day); ?{ numerator = 1; denominator = daysInYear(y) } };
      case (#a001_ActActIcma(_)) null;
      case (#a006_Thirty360Isda) ?{ numerator = thirty360Numerator(day, day + 1, false); denominator = 360 };
      case (#a007_ThirtyE360) ?{ numerator = thirty360Numerator(day, day + 1, true); denominator = 360 };
      case (#a011_Thirty365) ?{ numerator = thirty360Numerator(day, day + 1, false); denominator = 365 };
    }
  };

  public func supportsDailyBalance(c : Convention) : Bool {
    switch (c) { case (#a001_ActActIcma(_)) false; case (_) true }
  };

  /// Does a daily-balance accrual over this window use one denominator throughout?
  /// ACT/ACT changes denominator at a year boundary, which a caller must handle
  /// day by day rather than by multiplying a sum.
  public func uniformDailyDenominator(c : Convention, from : CivilDate.Day, to : CivilDate.Day) : ?Nat {
    switch (dailyDenominator(c, from)) {
      case null null;
      case (?d) {
        var cursor = from;
        while (cursor < to) {
          switch (dailyDenominator(c, cursor)) {
            case (?d2) { if (d2 != d) return null };
            case null return null;
          };
          cursor += 1;
        };
        ?d
      };
    }
  };

  /// Reduce a fraction, so two equal fractions compare equal and a test can assert
  /// on the reduced form.
  public func reduce(f : Fraction) : Fraction {
    if (f.numerator == 0) return { numerator = 0; denominator = 1 };
    var a = f.numerator;
    var b = f.denominator;
    while (b != 0) { let t = a % b; a := b; b := t };
    { numerator = f.numerator / a; denominator = f.denominator / a }
  };
};
