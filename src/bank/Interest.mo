/// Interest.mo — accrual as a fold, and rounding that conserves.
///
/// Two decisions shape this module, and both are consequences of where the journal
/// already keeps its state.
///
/// **Accrual is computed, not stored.** Apache Fineract accrues per account per day
/// into rows and then runs jobs over them. A canister cannot hold one posting per
/// account per day: a bank with a million accounts would write hundreds of millions
/// of blocks a year to say nothing happened. But the journal keeps **exact
/// value-dated balances**, so accrued interest over any window is a pure function
/// of the journal and the product's terms — which means it is also *correct after a
/// back-dated posting*, with no stored figure to go stale. That is the whole reason
/// the product engine sits on this journal rather than beside a conventional one.
///
/// **Nothing is a floating-point number.** An accrual is an exact rational all the
/// way to the point where it becomes minor units, and the rounding step reports the
/// residue it dropped. Per-account amounts are rounded and the contra leg is set to
/// **their sum**, so the posting balances by construction and no rounding-difference
/// account is ever credited to make the books close. A plug account is how a
/// rounding bug survives a year.
///
/// A negative rate does not produce a negative amount: amounts are `Nat` and the
/// journal refuses zero and has no sign. `Signed.negative` tells the caller to swap
/// the sides of both legs, which is a distinct path with its own tests.

import Nat "mo:core/Nat";
import List "mo:core/List";

import CivilDate "mo:journal/CivilDate";

import DC "DayCount";

module {

  /// An interest rate as an exact rational: 5 % is 5/100, 5.375 % is 5375/100000.
  /// `negative` carries the sign, because the magnitude is a natural.
  public type Rate = { numerator : Nat; denominator : Nat; negative : Bool };

  /// An exact signed rational, the form every intermediate figure takes.
  public type Signed = { numerator : Nat; denominator : Nat; negative : Bool };

  public type Rounding = { #halfEven; #halfUp; #down };

  public type Rounded = {
    amount : Nat;          // minor units
    negative : Bool;
    /// What rounding dropped, as an exact rational: |exact| − amount.
    residueNumerator : Nat;
    residueDenominator : Nat;
  };

  public func zero() : Signed { { numerator = 0; denominator = 1; negative = false } };

  public func isZero(x : Signed) : Bool { x.numerator == 0 };

  public func validRate(r : Rate) : ?Text {
    if (r.denominator == 0) return ?"a rate needs a non-zero denominator";
    if (r.numerator == 0 and r.negative) return ?"negative zero is not a rate";
    null
  };

  /// `principal × rate × dayCountFraction(from, to)`, exact.
  public func periodAccrual(principal : Nat, rate : Rate, conv : DC.Convention, from : CivilDate.Day, to : CivilDate.Day) : Signed {
    let f = DC.fraction(conv, from, to);
    {
      numerator = principal * rate.numerator * f.numerator;
      denominator = rate.denominator * f.denominator;
      negative = rate.negative and principal != 0 and f.numerator != 0;
    }
  };

  /// Daily-balance accrual over `[from, to)`: the sum of each day's balance, each
  /// weighted by that day's denominator, times the rate. `balanceOn` is the
  /// journal's value-dated balance, so the result is exact and survives a
  /// back-dated posting by being recomputed rather than remembered.
  ///
  /// Null when the convention has no well-defined single day (the 30/360 family),
  /// which a product registration refuses rather than substituting ACT/365.
  public func dailyBalanceAccrual(
    balanceOn : (CivilDate.Day) -> Nat,
    rate : Rate,
    conv : DC.Convention,
    from : CivilDate.Day,
    to : CivilDate.Day,
  ) : ?{ accrued : Signed; daysExamined : Nat; balanceDaySum : Nat } {
    if (not DC.supportsDailyBalance(conv)) return null;
    if (to <= from) return ?{ accrued = zero(); daysExamined = 0; balanceDaySum = 0 };
    // A common denominator for every day in the window. For ACT/ACT the daily
    // denominator changes at a year boundary, so 365 × 366 covers both; for the
    // fixed bases it is the basis itself.
    let common : Nat = switch (DC.uniformDailyDenominator(conv, from, to)) {
      case (?d) d;
      case null 365 * 366;
    };
    var weighted : Nat = 0;
    var daySum : Nat = 0;
    var days : Nat = 0;
    var cursor = from;
    while (cursor < to) {
      // The day's own fraction, which is the convention's: one over the basis for
      // the ACT family, and the 30/360 numerator for that family — so a 31st
      // contributes nothing under the bond basis rather than a day the convention
      // does not recognise.
      let ?f = DC.dailyFraction(conv, cursor) else return null;
      let b = balanceOn(cursor);
      daySum += b;
      weighted += b * f.numerator * (common / f.denominator);
      days += 1;
      cursor += 1;
    };
    ?{
      accrued = {
        numerator = weighted * rate.numerator;
        denominator = common * rate.denominator;
        negative = rate.negative and weighted != 0;
      };
      daysExamined = days;
      balanceDaySum = daySum;
    }
  };

  /// Average-daily-balance accrual: the same sum divided by the number of days,
  /// then accrued over the window as a period. Offered because Fineract does, and
  /// because a bank that declares it expects it; the engine computes both from the
  /// same fold so they cannot disagree about the underlying balances.
  public func averageBalanceAccrual(
    balanceOn : (CivilDate.Day) -> Nat,
    rate : Rate,
    conv : DC.Convention,
    from : CivilDate.Day,
    to : CivilDate.Day,
  ) : ?{ accrued : Signed; daysExamined : Nat; balanceDaySum : Nat } {
    if (to <= from) return ?{ accrued = zero(); daysExamined = 0; balanceDaySum = 0 };
    var daySum : Nat = 0;
    var days : Nat = 0;
    var cursor = from;
    while (cursor < to) { daySum += balanceOn(cursor); days += 1; cursor += 1 };
    let f = DC.fraction(conv, from, to);
    ?{
      // (daySum / days) × rate × fraction, kept exact by not dividing early
      accrued = {
        numerator = daySum * rate.numerator * f.numerator;
        denominator = days * rate.denominator * f.denominator;
        negative = rate.negative and daySum != 0 and f.numerator != 0;
      };
      daysExamined = days;
      balanceDaySum = daySum;
    }
  };

  /// Round an exact rational to whole minor units, reporting what was dropped.
  public func round(x : Signed, mode : Rounding) : Rounded {
    if (x.numerator == 0 or x.denominator == 0) {
      return { amount = 0; negative = false; residueNumerator = 0; residueDenominator = 1 };
    };
    let q = x.numerator / x.denominator;
    let r = x.numerator % x.denominator;
    let amount = switch (mode) {
      case (#down) q;
      case (#halfUp) { if (2 * r >= x.denominator) q + 1 else q };
      case (#halfEven) {
        if (2 * r > x.denominator) q + 1
        else if (2 * r < x.denominator) q
        else if (q % 2 == 0) q else q + 1
      };
    };
    // The residue is |exact| − amount, which can be negative when rounding up; it
    // is reported as a magnitude with the denominator so the caller can bound it.
    let exactNum = x.numerator;
    let roundedNum = amount * x.denominator;
    let residue = if (exactNum >= roundedNum) exactNum - roundedNum else roundedNum - exactNum;
    {
      amount;
      negative = x.negative and amount != 0;
      residueNumerator = residue;
      residueDenominator = x.denominator;
    }
  };

  /// Round a set of per-entity accruals and report their total.
  ///
  /// The contra leg of the posting is `total` — the **sum of the rounded
  /// amounts** — so the posting balances by construction. `residueNumerator over
  /// residueDenominator` is the difference between the exact sum and that total,
  /// which the caller reports per run and an acceptance criterion bounds. There is
  /// no rounding-difference account anywhere in this engine.
  public func allocate(amounts : [Signed], mode : Rounding) : {
    rounded : [Rounded];
    total : Nat;
    negativeTotal : Nat;
    residueNumerator : Nat;
    residueDenominator : Nat;
    zeroCount : Nat;
  } {
    var total : Nat = 0;
    var negativeTotal : Nat = 0;
    var zeroCount : Nat = 0;
    // exact sum, over a common denominator
    var commonDen : Nat = 1;
    for (a in amounts.vals()) { if (a.denominator != 0 and a.denominator != commonDen) commonDen := lcm(commonDen, a.denominator) };
    var exactPos : Nat = 0;
    var exactNeg : Nat = 0;
    let out = List.empty<Rounded>();
    var i = 0;
    while (i < amounts.size()) {
      let r = round(amounts[i], mode);
      List.add(out, r);
      if (r.amount == 0) zeroCount += 1;
      if (r.negative) negativeTotal += r.amount else total += r.amount;
      if (amounts[i].denominator != 0) {
        let scaled = amounts[i].numerator * (commonDen / amounts[i].denominator);
        if (amounts[i].negative) exactNeg += scaled else exactPos += scaled;
      };
      i += 1;
    };
    let roundedScaled = total * commonDen;
    let negScaled = negativeTotal * commonDen;
    let exactNet = if (exactPos >= exactNeg) exactPos - exactNeg else exactNeg - exactPos;
    let roundedNet = if (roundedScaled >= negScaled) roundedScaled - negScaled else negScaled - roundedScaled;
    {
      rounded = List.toArray(out);
      total;
      negativeTotal;
      residueNumerator = if (exactNet >= roundedNet) exactNet - roundedNet else roundedNet - exactNet;
      residueDenominator = commonDen;
      zeroCount;
    }
  };

  func gcd(a : Nat, b : Nat) : Nat {
    var x = a;
    var y = b;
    while (y != 0) { let t = x % y; x := y; y := t };
    if (x == 0) 1 else x
  };

  func lcm(a : Nat, b : Nat) : Nat {
    if (a == 0 or b == 0) return 1;
    a / gcd(a, b) * b
  };
};
