// DayCountInterest.test.mo; the arithmetic that is money.
//
// Day-count fractions and interest accrual, as exact rationals, against published
// vectors. The one that matters most is the last: the figure Apache Fineract 1.15.0
// reported on a live instance is reproduced here from its own deposit and withdrawal
// history.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Array "mo:core/Array";

import CivilDate "mo:journal/CivilDate";

import DC "../src/bank/DayCount";
import I "../src/bank/Interest";

func day(y : Nat, m : Nat, d : Nat) : CivilDate.Day {
  switch (CivilDate.fromCivil(y, m, d)) { case (?x) x; case null { Debug.print("bad date"); assert false; 0 } }
};

func frac(c : DC.Convention, a : CivilDate.Day, b : CivilDate.Day) : DC.Fraction { DC.reduce(DC.fraction(c, a, b)) };

var vectors = 0;
func vector(name : Text, c : DC.Convention, from : CivilDate.Day, to : CivilDate.Day, num : Nat, den : Nat) {
  let f = frac(c, from, to);
  let want = DC.reduce({ numerator = num; denominator = den });
  if (f.numerator != want.numerator or f.denominator != want.denominator) {
    Debug.print(name # ": got " # Nat.toText(f.numerator) # "/" # Nat.toText(f.denominator)
      # ", wanted " # Nat.toText(want.numerator) # "/" # Nat.toText(want.denominator));
    assert false;
  };
  vectors += 1;
};

// ─── ACT/360 and ACT/365 fixed ───────────────────────────────────────────────
vector("A003 one month", #a003_Act360, day(2007, 1, 15), day(2007, 2, 15), 31, 360);
vector("A004 one month", #a004_Act365Fixed, day(2007, 1, 15), day(2007, 2, 15), 31, 365);
vector("A004 a full year", #a004_Act365Fixed, day(2007, 1, 1), day(2008, 1, 1), 365, 365);
vector("A004 a leap year", #a004_Act365Fixed, day(2008, 1, 1), day(2009, 1, 1), 366, 365);
vector("A003 a leap year", #a003_Act360, day(2008, 1, 1), day(2009, 1, 1), 366, 360);
vector("A004 a single day", #a004_Act365Fixed, day(2026, 9, 9), day(2026, 9, 10), 1, 365);
vector("A004 an empty window", #a004_Act365Fixed, day(2026, 9, 9), day(2026, 9, 9), 0, 1);

// ─── 30/360 bond basis (A006) and 30E/360 Eurobond (A007) ───────────────────
// The classic ISDA cases. Most agree; the discriminating one is the last pair.
vector("A006 mid-month to mid-month", #a006_Thirty360Isda, day(2007, 1, 15), day(2007, 1, 30), 15, 360);
vector("A006 one month", #a006_Thirty360Isda, day(2007, 1, 15), day(2007, 2, 15), 30, 360);
vector("A006 31 Jan to 28 Feb", #a006_Thirty360Isda, day(2007, 1, 31), day(2007, 2, 28), 28, 360);
vector("A006 31 Aug to 29 Feb", #a006_Thirty360Isda, day(2007, 8, 31), day(2008, 2, 29), 179, 360);
vector("A006 31 Jan to 31 Mar", #a006_Thirty360Isda, day(2007, 1, 31), day(2007, 3, 31), 60, 360);
vector("A006 31 Aug to 30 Sep", #a006_Thirty360Isda, day(2007, 8, 31), day(2007, 9, 30), 30, 360);
// 28 Feb to 31 Mar: bond basis keeps the 31st because the first day was not the
// 30th (33 days); the Eurobond basis clamps both (32 days). This is the pair that
// tells the two conventions apart, and getting it wrong is a real money difference.
vector("A006 28 Feb to 31 Mar", #a006_Thirty360Isda, day(2007, 2, 28), day(2007, 3, 31), 33, 360);
vector("A007 28 Feb to 31 Mar", #a007_ThirtyE360, day(2007, 2, 28), day(2007, 3, 31), 32, 360);
assert (frac(#a006_Thirty360Isda, day(2007, 2, 28), day(2007, 3, 31)) != frac(#a007_ThirtyE360, day(2007, 2, 28), day(2007, 3, 31)));
vector("A007 31 Jan to 31 Mar", #a007_ThirtyE360, day(2007, 1, 31), day(2007, 3, 31), 60, 360);
vector("A011 one month over 365", #a011_Thirty365, day(2007, 1, 15), day(2007, 2, 15), 30, 365);
vector("A006 a full year", #a006_Thirty360Isda, day(2007, 1, 1), day(2008, 1, 1), 360, 360);

// ─── ACT/ACT ISDA (A005) across a year boundary ─────────────────────────────
// 17 days in 2007 (365-day year) plus 14 in 2008 (366), over the common
// denominator 365 × 366: 17×366 + 14×365 = 11,332.
vector("A005 across a year boundary", #a005_ActActIsda, day(2007, 12, 15), day(2008, 1, 15), 11_332, 133_590);
vector("A005 inside one common year", #a005_ActActIsda, day(2007, 1, 1), day(2007, 2, 1), 31, 365);
vector("A005 a whole leap year", #a005_ActActIsda, day(2008, 1, 1), day(2009, 1, 1), 1, 1);
vector("A005 a whole common year", #a005_ActActIsda, day(2007, 1, 1), day(2008, 1, 1), 1, 1);

// ─── ICMA (A001) ────────────────────────────────────────────────────────────
// Rule 251 over a regular coupon period is exactly one over the coupon frequency.
vector("A001 a semi-annual coupon period", #a001_ActActIcma({ couponsPerYear = 2 }), day(2007, 1, 15), day(2007, 7, 15), 1, 2);
vector("A001 a quarterly coupon period", #a001_ActActIcma({ couponsPerYear = 4 }), day(2007, 1, 15), day(2007, 4, 15), 1, 4);

Debug.print("count: day-count vectors verified = " # Nat.toText(vectors));
assert (vectors == 24);

// ─── the ISO 20022 code set, and the boundary of the implemented subset ─────
var implemented = 0;
var refused = 0;
for (code in DC.isoCodeSet().vals()) {
  switch (DC.byIsoCode(code, 2)) {
    case (?c) { assert (Text.equal(DC.isoCode(c), code)); implemented += 1 };
    case null refused += 1;
  };
};
Debug.print("count: ISO 20022 interest-computation codes in the published set = " # Nat.toText(DC.isoCodeSet().size()));
Debug.print("count: codes implemented = " # Nat.toText(implemented));
Debug.print("count: codes outside the implemented subset, refused by name = " # Nat.toText(refused));
assert (DC.isoCodeSet().size() == 21);
assert (implemented == 7);
assert (refused == 14);

// Daily-balance support is a property of the convention, not a hope. Every
// convention whose unit is a *day* supports it, and that includes the 30/360
// family: its daily fraction is its own numerator for the one-day step, so a 31st
// contributes nothing under the bond basis rather than a day the convention does
// not recognise. ACT/ACT (ICMA) is the exception, and the only one: its unit is a
// coupon period, so a single day has no fraction at all and a product declaring it
// with a daily-balance basis is refused at registration.
var dailyOk = 0;
var dailyNo = 0;
for (c in [#a003_Act360, #a004_Act365Fixed, #a005_ActActIsda, #a006_Thirty360Isda, #a007_ThirtyE360, #a011_Thirty365].vals()) {
  assert (DC.supportsDailyBalance(c));
  assert (DC.dailyFraction(c, day(2026, 9, 9)) != null);
  dailyOk += 1;
};
for (c in [#a001_ActActIcma({ couponsPerYear = 2 })].vals()) {
  assert (not DC.supportsDailyBalance(c));
  assert (DC.dailyDenominator(c, day(2026, 9, 9)) == null);
  assert (DC.dailyFraction(c, day(2026, 9, 9)) == null);
  dailyNo += 1;
};
Debug.print("count: conventions classified for daily-balance use = " # Nat.toText(dailyOk + dailyNo));
assert (dailyOk == 6 and dailyNo == 1);

// The daily fractions themselves, against the conventions' own definitions. These
// are the vectors that make "a 30/360 product may accrue daily" a statement about
// arithmetic rather than about convenience.
var dailyVectors = 0;
func df(c : DC.Convention, y : Nat, m : Nat, d : Nat) : (Nat, Nat) {
  switch (DC.dailyFraction(c, day(y, m, d))) { case (?f) (f.numerator, f.denominator); case null (999, 999) }
};
// ACT family: one day over the basis, every day
assert (df(#a003_Act360, 2026, 1, 31) == (1, 360));
assert (df(#a004_Act365Fixed, 2026, 1, 31) == (1, 365));
assert (df(#a005_ActActIsda, 2024, 3, 1) == (1, 366));   // a leap year
assert (df(#a005_ActActIsda, 2026, 3, 1) == (1, 365));
dailyVectors += 4;
// 30/360 bond basis: the 30th to the 31st is zero days, the 31st to the 1st is one
assert (df(#a006_Thirty360Isda, 2026, 1, 30) == (0, 360));
assert (df(#a006_Thirty360Isda, 2026, 1, 31) == (1, 360));
assert (df(#a006_Thirty360Isda, 2026, 1, 15) == (1, 360));
dailyVectors += 3;
// 30E/360: both ends clamp to 30, so the 30th to the 31st is zero days, while the
// 31st to the 1st of the next month is one (the 31st is read as the 30th). The last
// day of a short February carries the rest of the notional month: 28 Feb to 1 Mar
// is 30 - 28 + 1 = 3 days.
assert (df(#a007_ThirtyE360, 2026, 1, 30) == (0, 360));
assert (df(#a007_ThirtyE360, 2026, 1, 31) == (1, 360));
assert (df(#a007_ThirtyE360, 2026, 2, 28) == (3, 360));
dailyVectors += 3;
// 30/365 shares the numerator and changes only the basis
assert (df(#a011_Thirty365, 2026, 1, 30) == (0, 365));
assert (df(#a011_Thirty365, 2026, 1, 15) == (1, 365));
dailyVectors += 2;
// and a whole notional month of daily fractions sums to the convention's own
// fraction for that month, which is the property that makes the two agree
var sumNum = 0;
var cursor = day(2026, 1, 1);
let monthEnd = day(2026, 2, 1);
while (cursor < monthEnd) {
  switch (DC.dailyFraction(#a006_Thirty360Isda, cursor)) { case (?f) sumNum += f.numerator; case null assert false };
  cursor += 1;
};
let monthFraction = DC.fraction(#a006_Thirty360Isda, day(2026, 1, 1), day(2026, 2, 1));
assert (sumNum == monthFraction.numerator);
dailyVectors += 1;
Debug.print("count: daily-fraction vectors verified = " # Nat.toText(dailyVectors));
assert (dailyVectors == 13);

// ─── rounding ───────────────────────────────────────────────────────────────
func r(num : Nat, den : Nat, mode : I.Rounding) : Nat {
  (I.round({ numerator = num; denominator = den; negative = false }, mode)).amount
};
// exactly a half: half-even goes to the even neighbour, half-up always up
assert (r(1, 2, #halfEven) == 0 and r(1, 2, #halfUp) == 1 and r(1, 2, #down) == 0);
assert (r(3, 2, #halfEven) == 2 and r(3, 2, #halfUp) == 2 and r(3, 2, #down) == 1);
assert (r(5, 2, #halfEven) == 2 and r(5, 2, #halfUp) == 3 and r(5, 2, #down) == 2);
assert (r(7, 2, #halfEven) == 4 and r(7, 2, #halfUp) == 4);
// above and below a half
assert (r(51, 100, #halfEven) == 1 and r(49, 100, #halfEven) == 0);
assert (r(0, 1, #halfEven) == 0);
Debug.print("count: rounding-mode checks = 14");

// the residue is what rounding dropped, exactly
let rr = I.round({ numerator = 3_125_000; denominator = 36_500; negative = false }, #halfEven);
// 3125000/36500 = 85.6164...; half-even gives 86, so the residue is 86×36500 − 3125000
assert (rr.amount == 86);
assert (rr.residueDenominator == 36_500);
assert (rr.residueNumerator == 86 * 36_500 - 3_125_000);
Debug.print("count: residue checks = 3");

// ─── allocation conserves: the contra leg is the sum of the rounded legs ────
// 100 accruals that each round to a half, so the rounding is maximally awkward
let awkward = Array.tabulate<I.Signed>(100, func(i) { { numerator = 2 * i + 1; denominator = 2; negative = false } });
let alloc = I.allocate(awkward, #halfEven);
var sum : Nat = 0;
for (x in alloc.rounded.vals()) { sum += x.amount };
assert (sum == alloc.total);
Debug.print("count: allocated accruals = " # Nat.toText(alloc.rounded.size()));
Debug.print("count: allocation total equals the sum of its parts = 1");
// the residue is bounded by half a minor unit per leg
assert (alloc.residueNumerator * 2 <= alloc.residueDenominator * awkward.size());
Debug.print("count: residue bound checks = 1");
// and the zero count is reported, because a zero accrual must not be posted
let withZeros = Array.tabulate<I.Signed>(10, func(i) { { numerator = if (i % 2 == 0) 0 else 300; denominator = 100; negative = false } });
let az = I.allocate(withZeros, #halfEven);
assert (az.zeroCount == 5 and az.total == 5 * 3);
Debug.print("count: zero accruals reported and not totalled = " # Nat.toText(az.zeroCount));

// ─── negative rates flip the side; the amount stays a natural ──────────────
let negRate : I.Rate = { numerator = 50; denominator = 10_000; negative = true };   // −0.50 %
assert (I.validRate(negRate) == null);
let negAccrual = I.periodAccrual(1_000_000, negRate, #a004_Act365Fixed, day(2026, 1, 1), day(2027, 1, 1));
assert negAccrual.negative;
let negRounded = I.round(negAccrual, #halfEven);
assert (negRounded.negative and negRounded.amount == 5_000);
// the same magnitude as the positive rate
let posAccrual = I.periodAccrual(1_000_000, { negRate with negative = false }, #a004_Act365Fixed, day(2026, 1, 1), day(2027, 1, 1));
assert (not posAccrual.negative);
assert ((I.round(posAccrual, #halfEven)).amount == negRounded.amount);
Debug.print("count: negative-rate checks = 5");
// an invalid rate is refused
assert (I.validRate({ numerator = 1; denominator = 0; negative = false }) != null);
assert (I.validRate({ numerator = 0; denominator = 100; negative = true }) != null);
Debug.print("count: invalid rates refused = 2");

// ─── the Fineract vector, reproduced from its own history ───────────────────
// Observed on the live instance: a savings account at 5 % nominal, daily balance,
// 365-day basis; deposit 1,000 on 2 September and withdraw 250 on 3 September;
// `totalInterestEarned` read 0.86 seven days later. The balance history is
// 1,000.00 for one day and 750.00 for seven, so the sum of daily balances is
// 62,500.00 and the interest is 62,500.00 × 5 % / 365 = 0.8562, which is 0.86.
let SEP2 = day(2026, 9, 2);
let SEP10 = day(2026, 9, 10);
func fineractBalance(d : CivilDate.Day) : Nat {
  if (d < SEP2) 0
  else if (d == SEP2) 100_000        // 1,000.00 in minor units
  else 75_000                         // 750.00 after the withdrawal on 3 September
};
let fiveper : I.Rate = { numerator = 5; denominator = 100; negative = false };
switch (I.dailyBalanceAccrual(fineractBalance, fiveper, #a004_Act365Fixed, SEP2, SEP10)) {
  case null { Debug.print("ACT/365 should support a daily balance"); assert false };
  case (?res) {
    Debug.print("count: days examined in the Fineract window = " # Nat.toText(res.daysExamined));
    assert (res.daysExamined == 8);
    assert (res.balanceDaySum == 100_000 + 7 * 75_000);
    // the exact figure before rounding
    assert (res.accrued.numerator == (100_000 + 7 * 75_000) * 5);
    assert (res.accrued.denominator == 365 * 100);
    let rounded = I.round(res.accrued, #halfEven);
    Debug.print("Fineract reported 0.86; the fold gives " # Nat.toText(rounded.amount) # " minor units");
    assert (rounded.amount == 86);
    // and half-up agrees, so the figure does not depend on the tie rule
    assert ((I.round(res.accrued, #halfUp)).amount == 86);
    Debug.print("count: Fineract interest vectors reproduced = 1");
  };
};

// ACT/ACT (ICMA) has no single-day fraction, so a daily-balance accrual under it is
// refused rather than approximated; the one convention of the seven that cannot
// serve this basis.
assert (I.dailyBalanceAccrual(fineractBalance, fiveper, #a001_ActActIcma({ couponsPerYear = 2 }), SEP2, SEP10) == null);
Debug.print("count: daily-balance accruals refused for a coupon-period convention = 1");

// A 30/360 daily-balance accrual is a real figure and it is *not* the ACT/365 one:
// the same window over the same balances gives a different day count, which is the
// whole reason a product declares its convention.
switch (I.dailyBalanceAccrual(fineractBalance, fiveper, #a006_Thirty360Isda, SEP2, SEP10)) {
  case (?res) {
    assert (res.daysExamined == 8);
    let thirty = (I.round(res.accrued, #halfEven)).amount;
    Debug.print("the same window on a 30/360 basis gives " # Nat.toText(thirty) # " minor units");
    assert (thirty > 0);
    assert (thirty != 86);
    Debug.print("count: 30/360 daily-balance accruals verified = 1");
  };
  case null { Debug.print("a 30/360 daily-balance accrual was refused"); assert false };
};

// an empty window accrues nothing, and a zero balance accrues nothing
switch (I.dailyBalanceAccrual(fineractBalance, fiveper, #a004_Act365Fixed, SEP2, SEP2)) {
  case (?res) { assert (I.isZero(res.accrued) and res.daysExamined == 0) };
  case null { assert false };
};
switch (I.dailyBalanceAccrual(func(_) { 0 }, fiveper, #a004_Act365Fixed, SEP2, SEP10)) {
  case (?res) { assert (I.isZero(res.accrued) and res.daysExamined == 8) };
  case null { assert false };
};
Debug.print("count: empty and zero-balance accruals = 2");

// ─── the average-daily-balance basis agrees on the same history ────────────
switch (I.averageBalanceAccrual(fineractBalance, fiveper, #a004_Act365Fixed, SEP2, SEP10)) {
  case (?res) {
    // (625000/8) × 5% × 8/365 = 625000 × 5 / (100 × 365): the same figure, because
    // the window is one uniform stretch; which is the point of computing both from
    // one fold.
    let a = I.round(res.accrued, #halfEven);
    assert (a.amount == 86);
    Debug.print("count: average-balance accruals agreeing with the daily basis = 1");
  };
  case null { assert false };
};

// ─── ACT/ACT across a year boundary uses both denominators ─────────────────
let DEC15 = day(2026, 12, 15);
let JAN15 = day(2027, 1, 15);
switch (I.dailyBalanceAccrual(func(_) { 1_000_000 }, fiveper, #a005_ActActIsda, DEC15, JAN15)) {
  case (?res) {
    assert (res.daysExamined == 31);
    // 2026 and 2027 are both common years, so the denominator is uniform here;
    // the crossing that matters is into a leap year, checked next.
    Debug.print("count: ACT/ACT windows accrued = 1");
  };
  case null { assert false };
};
let DEC2027 = day(2027, 12, 15);
let JAN2028 = day(2028, 1, 15);
switch (DC.uniformDailyDenominator(#a005_ActActIsda, DEC2027, JAN2028)) {
  case null {};   // 2027 is 365 days and 2028 is 366: not uniform, as expected
  case (?d) { Debug.print("expected a non-uniform denominator across a leap boundary, got " # Nat.toText(d)); assert false };
};
switch (I.dailyBalanceAccrual(func(_) { 36_600_000 }, { numerator = 1; denominator = 1; negative = false }, #a005_ActActIsda, DEC2027, JAN2028)) {
  case (?res) {
    assert (res.daysExamined == 31);
    // 17 days at 1/365 and 14 at 1/366, times 36,600,000: exactly
    //   36,600,000 × (17×366 + 14×365) / (365×366)
    let expectedNum = 36_600_000 * (17 * 366 + 14 * 365);
    assert (res.accrued.numerator == expectedNum);
    assert (res.accrued.denominator == 365 * 366);
    Debug.print("count: leap-boundary ACT/ACT accruals verified = 1");
  };
  case null { assert false };
};

Debug.print("DAY COUNT AND INTEREST TEST GREEN");
