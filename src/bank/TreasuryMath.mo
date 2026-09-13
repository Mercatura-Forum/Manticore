/// TreasuryMath.mo — the valuation arithmetic of the treasury domain (treasury) as pure functions over recorded data,
/// written so that a Python twin reproduces every figure to the minor unit.
///
/// Two number systems, each chosen for what it values:
///
/// * **Exact rationals** (`Q`) for everything linear in the inputs — discount factors by simple compounding,
///   linear interpolation on a curve, the mark of a forward, the fixed and projected legs of a swap, a bond's
///   price, accrued coupon and constant-yield amortisation. Each result is a ratio of integers rounded half-even
///   exactly once, at the end, so the contract and the twin agree because they compute the same rational.
/// * **Deterministic fixed point** (`Fixed`, 18 decimals) for the Garman–Kohlhagen option price, whose exp, ln,
///   square root and normal distribution are irrational. Every operation is integer arithmetic with truncation
///   toward zero, every series has a fixed number of terms, and the normal CDF is Abramowitz–Stegun 26.2.17 —
///   so two implementations that follow the same steps produce the same integer, and the twin's agreement is
///   bit-for-bit rather than "within tolerance". The approximation's error against the true normal CDF is below
///   7.5 × 10⁻⁸, stated in the design; what the battery proves is that the contract computed the stated model.
///
/// Conventions stated once: an FX rate in **micro** is quote minor units per base minor unit × 10⁶ (48.123456
/// EGP per USD with two decimals each is 48_123_456); a zero rate or a volatility in **basis points**; a bond
/// price in micro per 100 of face (101.25 is 101_250_000); a tenor in days; a discount factor by simple
/// compounding ACT/360 — `1 / (1 + r · t / 360)`; the option's time in years ACT/365.

import Array "mo:core/Array";
import Int "mo:core/Int";
import Nat "mo:core/Nat";

import DC "DayCount";
import I "Interest";
import Products "Products";

module {

  public let MICRO : Nat = 1_000_000;
  public let BPS : Nat = 10_000;

  // ═══════════════════════════════════════════════════════
  //  EXACT RATIONALS
  // ═══════════════════════════════════════════════════════

  /// A rational `n / d` with `d > 0`, kept reduced.
  public type Q = { n : Int; d : Nat };

  func gcd(a : Nat, b : Nat) : Nat { var x = a; var y = b; while (y != 0) { let t = x % y; x := y; y := t }; x };

  public func q(n : Int, d : Nat) : Q {
    if (d == 0) return { n = 0; d = 1 };
    let g = gcd(Int.abs(n), d);
    if (g <= 1) { { n; d } } else { { n = n / g; d = d / g } }
  };
  public func ofInt(n : Int) : Q { { n; d = 1 } };
  public func ofNat(n : Nat) : Q { { n; d = 1 } };
  public func zero() : Q { { n = 0; d = 1 } };
  public func add(a : Q, b : Q) : Q { q(a.n * b.d + b.n * a.d, a.d * b.d) };
  public func sub(a : Q, b : Q) : Q { q(a.n * b.d - b.n * a.d, a.d * b.d) };
  public func mul(a : Q, b : Q) : Q { q(a.n * b.n, a.d * b.d) };
  public func neg(a : Q) : Q { { n = -a.n; d = a.d } };
  /// `a / b`; a division by zero is the zero rational, which no caller reaches because every divisor here is
  /// a positive day count, a positive rate denominator or a discount factor.
  public func div(a : Q, b : Q) : Q {
    if (b.n == 0) return zero();
    let num = a.n * b.d;
    let den = b.n * a.d;
    if (den < 0) q(-num, Int.abs(den)) else q(num, Int.abs(den))
  };
  public func cmp(a : Q, b : Q) : Int { let l = a.n * b.d; let r = b.n * a.d; if (l < r) -1 else if (l > r) 1 else 0 };
  public func isNeg(a : Q) : Bool { a.n < 0 };
  public func scale(a : Q, k : Nat) : Q { mul(a, ofNat(k)) };
  public func ofFraction(f : DC.Fraction) : Q { q(f.numerator, f.denominator) };
  public func ofSigned(s : I.Signed) : Q { q(if (s.negative) -s.numerator else s.numerator, s.denominator) };

  /// Round half to even on the signed value — the same rule as `Interest.round(#halfEven)` applied to the
  /// magnitude with the sign restored, which is symmetric and so agrees with Python's `round(Fraction)`.
  public func roundHalfEven(a : Q) : Int {
    let mag : Nat = Int.abs(a.n);
    let r = I.round({ numerator = mag; denominator = a.d; negative = false }, #halfEven);
    if (a.n < 0) -r.amount else r.amount
  };
  /// The rational as a Nat when non-negative, else zero — for figures the model proves are non-negative.
  public func roundNat(a : Q) : Nat { let r = roundHalfEven(a); if (r < 0) 0 else Int.abs(r) };

  // ═══════════════════════════════════════════════════════
  //  CURVES, DISCOUNTING, FORWARDS
  // ═══════════════════════════════════════════════════════

  /// Linear interpolation on `(tenorDays, value)` points sorted by tenor; flat beyond either end. The value is
  /// exact (a rational), so the interpolated rate never carries a rounding of its own.
  public func interpolate(points : [(Nat, Int)], tenor : Nat) : Q {
    let n = points.size();
    if (n == 0) return zero();
    if (tenor <= points[0].0) return ofInt(points[0].1);
    if (tenor >= points[n - 1].0) return ofInt(points[n - 1].1);
    var i = 1;
    while (i < n) {
      let (t1, v1) = points[i];
      if (tenor <= t1) {
        let (t0, v0) = points[i - 1];
        if (t1 == t0) return ofInt(v1);
        // v0 + (v1 - v0) (tenor - t0) / (t1 - t0)
        return add(ofInt(v0), q((v1 - v0) * (tenor - t0 : Nat), t1 - t0));
      };
      i += 1;
    };
    ofInt(points[n - 1].1)
  };

  /// Sorted strictly by tenor, at least one point, at most `maxPoints`.
  public func validPoints(points : [(Nat, Int)], maxPoints : Nat) : Bool {
    if (points.size() == 0 or points.size() > maxPoints) return false;
    var i = 1;
    while (i < points.size()) { if (points[i].0 <= points[i - 1].0) return false; i += 1 };
    true
  };

  /// Simple-compounded discount factor over `days` at `rateBps` (a rational in bps): `1 / (1 + r · t / 360)`,
  /// i.e. `3_600_000 / (3_600_000 + r_bps · t)` when `r` is whole basis points.
  public func discountFactor(rateBps : Q, days : Nat) : Q {
    let one = ofInt(1);
    let rt = div(mul(rateBps, ofNat(days)), ofNat(BPS * 360));
    div(one, add(one, rt))
  };

  /// The discount factor at a tenor read off a zero curve.
  public func discountOn(zeroCurve : [(Nat, Int)], days : Nat) : Q { discountFactor(interpolate(zeroCurve, days), days) };

  /// An FX rate in micro from the journal's ratio of minor units: `numerator / denominator × 10⁶`, exact.
  public func rateMicro(numerator : Nat, denominator : Nat) : Q { q(numerator * MICRO, denominator) };

  /// Quote-currency minor units of a base amount at a rate in micro, rounded half-even.
  public func quoteAmount(baseAmount : Nat, rateMicro_ : Nat) : Nat { roundNat(q(baseAmount * rateMicro_, MICRO)) };

  /// The mark of an outright forward on a day: `sign · B · (F_mkt − F_deal) · DF(τ)`, where the market forward is
  /// the spot plus the interpolated forward points at the remaining tenor, the discount is at the quote
  /// currency's zero rate for that tenor, and `sign` is +1 when the bank buys the base. In quote minor units.
  public func forwardMark(buyBase : Bool, baseAmount : Nat, dealRateMicro : Nat, spot : Q, forwardPoints : [(Nat, Int)], quoteZero : [(Nat, Int)], remainingDays : Nat) : Int {
    let fwd = add(spot, interpolate(forwardPoints, remainingDays));   // micro
    let diff = sub(fwd, ofNat(dealRateMicro));
    let undiscounted = div(mul(diff, ofNat(baseAmount)), ofNat(MICRO));
    let pv = mul(undiscounted, discountOn(quoteZero, remainingDays));
    let m = roundHalfEven(pv);
    if (buyBase) m else -m
  };

  /// The realised result of a forward settled at the day's spot: the quote equivalent at spot less the
  /// contractual quote amount, signed from the bank's side.
  public func forwardRealised(buyBase : Bool, baseAmount : Nat, dealRateMicro : Nat, spot : Q) : Int {
    let atSpot = roundHalfEven(div(mul(spot, ofNat(baseAmount)), ofNat(MICRO)));
    let contractual : Int = quoteAmount(baseAmount, dealRateMicro);
    if (buyBase) atSpot - contractual else contractual - atSpot
  };

  // ═══════════════════════════════════════════════════════
  //  MONEY MARKET
  // ═══════════════════════════════════════════════════════

  /// Interest accrued from `start` to `day` (exclusive of `day`) at a simple rate in bps by the convention,
  /// rounded half-even: the cumulative figure, so a daily posting is the difference of two cumulatives and
  /// never drifts.
  public func simpleInterestTo(principal : Nat, rateBps : Nat, conv : DC.Convention, start : Nat, day : Nat) : Nat {
    if (day <= start) return 0;
    roundNat(ofSigned(I.periodAccrual(principal, { numerator = rateBps; denominator = BPS; negative = false }, conv, start, day)))
  };

  // ═══════════════════════════════════════════════════════
  //  FIXED-INCOME SECURITIES
  // ═══════════════════════════════════════════════════════

  public type Coupon = { start : Nat; end : Nat; amount : Nat };

  /// The coupon periods of a bond from issue to maturity in whole months of `12 / couponsPerYear`; the maturity
  /// must fall on a period end (validated at registration). The coupon of a period is
  /// `nominal × couponBps / 10⁴ × fraction(convention, start, end)` rounded half-even, so ACT/ACT (ICMA) gives
  /// the rate over the frequency exactly and ACT/360 gives what an ACT/360 note actually pays.
  public func couponPeriods(nominal : Nat, couponBps : Nat, couponsPerYear : Nat, conv : DC.Convention, issue : Nat, maturity : Nat) : [Coupon] {
    if (couponsPerYear == 0 or 12 % couponsPerYear != 0) return [];
    let step = 12 / couponsPerYear;
    var out : [Coupon] = [];
    var k = 1;
    var start = issue;
    label walk loop {
      let end = Products.addMonths(issue, k * step);
      if (end > maturity) return [];       // the maturity is off the grid: no schedule
      out := Array.concat(out, [{ start; end; amount = couponAmount(nominal, couponBps, conv, start, end) }]);
      if (end == maturity) break walk;
      start := end;
      k += 1;
      if (k > 1200) return [];
    };
    out
  };

  public func couponAmount(nominal : Nat, couponBps : Nat, conv : DC.Convention, from : Nat, to : Nat) : Nat {
    roundNat(div(mul(ofNat(nominal * couponBps), ofFraction(DC.fraction(conv, from, to))), ofNat(BPS)))
  };

  /// The coupon period a day falls in: `start ≤ day < end`.
  public func periodOf(periods : [Coupon], day : Nat) : ?Coupon {
    for (p in periods.vals()) { if (day >= p.start and day < p.end) return ?p };
    null
  };

  /// Accrued coupon at `day` (from the period's start, exclusive of `day`), rounded half-even; zero at a
  /// period start and the full coupon at its end.
  public func accruedCoupon(nominal : Nat, couponBps : Nat, conv : DC.Convention, periods : [Coupon], day : Nat) : Nat {
    switch (periodOf(periods, day)) { case (?p) couponAmount(nominal, couponBps, conv, p.start, day); case null 0 }
  };

  /// Clean cost of a nominal at a price in micro per 100 of face, rounded half-even.
  public func cleanCost(nominal : Nat, priceMicro : Nat) : Nat { roundNat(q(nominal * priceMicro, 100 * MICRO)) };

  /// Present value of the remaining cash flows at a yield `y` (a rational, per annum) on `settlement`: the stub to
  /// the first coupon end is discounted by simple interest over its fraction under the convention, each later
  /// period by a further `1 / (1 + y / couponsPerYear)`. Cash flows are the coupons after settlement and the face
  /// at maturity. The constant-yield (effective interest) method of IFRS 9 §B5.4.1 with the stub stated.
  public func presentValue(face : Nat, periods : [Coupon], conv : DC.Convention, couponsPerYear : Nat, settlement : Nat, y : Q) : Q {
    var pv = zero();
    var df = ofInt(1);
    var first = true;
    let perPeriod = div(ofInt(1), add(ofInt(1), div(y, ofNat(couponsPerYear))));
    var i = 0;
    while (i < periods.size()) {
      let p = periods[i];
      if (p.end > settlement) {
        if (first) {
          let stubStart = if (settlement > p.start) settlement else p.start;
          let s = ofFraction(DC.fraction(conv, stubStart, p.end));
          df := div(ofInt(1), add(ofInt(1), mul(y, s)));
          first := false;
        } else {
          df := mul(df, perPeriod);
        };
        var cf = p.amount;
        if (i + 1 == periods.size()) cf += face;
        pv := add(pv, mul(ofNat(cf), df));
      };
      i += 1;
    };
    pv
  };

  /// The yield in millionths per annum (10⁻⁶ of 1) that prices the bond at its dirty cost: bisection over
  /// [0, 2_000_000) — up to 200 % — for the smallest `y` whose present value does not exceed the dirty cost;
  /// forty halvings, as the Murabaha's implicit rate. Deterministic: the twin runs the same bisection.
  public func effectiveYieldMillionths(face : Nat, periods : [Coupon], conv : DC.Convention, couponsPerYear : Nat, settlement : Nat, dirtyCost : Nat) : Nat {
    var lo = 0; var hi = 2_000_000; var iter = 0;
    while (iter < 40 and lo < hi) {
      let mid = (lo + hi) / 2;
      let pv = presentValue(face, periods, conv, couponsPerYear, settlement, q(mid, MICRO));
      if (cmp(pv, ofNat(dirtyCost)) > 0) lo := mid + 1 else hi := mid;
      iter += 1;
    };
    lo
  };

  public type AmortisationStep = { start : Nat; end : Nat; interest : Nat; couponPart : Nat; amortisation : Int; carryingEnd : Nat };

  /// The constant-yield amortisation of a premium or discount from the clean cost at settlement to the face at
  /// maturity: per remaining coupon period, interest = carrying × y × fraction (the stub's fraction first, then
  /// `1 / couponsPerYear`), the coupon part is the coupon accruing in the period after settlement, and the
  /// amortisation is their difference; the last period closes the carrying amount to the face exactly, so the
  /// rounding of every earlier period lands there and nowhere else.
  public func amortisationSchedule(face : Nat, periods : [Coupon], conv : DC.Convention, couponsPerYear : Nat, settlement : Nat, cleanCost_ : Nat, yMillionths : Nat) : [AmortisationStep] {
    let y = q(yMillionths, MICRO);
    var carrying : Int = cleanCost_;
    var out : [AmortisationStep] = [];
    var first = true;
    var i = 0;
    let remaining = Array.filter<Coupon>(periods, func(p) { p.end > settlement });
    while (i < remaining.size()) {
      let p = remaining[i];
      let last = i + 1 == remaining.size();
      let stubStart = if (first and settlement > p.start) settlement else p.start;
      let frac = if (first) ofFraction(DC.fraction(conv, stubStart, p.end)) else q(1, couponsPerYear);
      let interest = roundNat(mul(mul(ofInt(carrying), y), frac));
      // the coupon accruing after settlement: the full coupon less what had accrued at settlement
      let couponPart = if (first and settlement > p.start) p.amount - accruedBefore(p, conv, settlement) else p.amount;
      var amort : Int = interest - couponPart;
      if (last) amort := face - carrying;
      carrying += amort;
      out := Array.concat(out, [{ start = stubStart; end = p.end; interest; couponPart; amortisation = amort; carryingEnd = Int.abs(carrying) }]);
      first := false;
      i += 1;
    };
    out
  };
  // The coupon accrued before settlement in the stub period is the period's coupon scaled by the convention's
  // fraction from the period start to settlement over the period's own fraction — the same ratio the accrued
  // coupon uses, so `couponPart + accruedBefore = amount` up to the rounding that closes on the last period.
  func accruedBefore(p : Coupon, conv : DC.Convention, settlement : Nat) : Nat {
    let whole = ofFraction(DC.fraction(conv, p.start, p.end));
    if (whole.n == 0) return 0;
    let part = ofFraction(DC.fraction(conv, p.start, settlement));
    let a = roundNat(div(mul(ofNat(p.amount), part), whole));
    if (a > p.amount) p.amount else a
  };

  /// The amortisation accrued within a step at `day`, straight-line by day within the step, rounded half-even:
  /// cumulative, like every daily figure here.
  public func amortisationTo(step : AmortisationStep, day : Nat) : Int {
    if (day <= step.start) return 0;
    if (day >= step.end) return step.amortisation;
    let span = step.end - step.start;
    roundHalfEven(q(step.amortisation * (day - step.start : Nat), span))
  };

  // ═══════════════════════════════════════════════════════
  //  INTEREST-RATE SWAPS
  // ═══════════════════════════════════════════════════════

  public type SwapPeriod = { start : Nat; end : Nat };

  /// The payment periods of a swap from `start` in whole months; the maturity must be on the grid.
  public func swapPeriods(start : Nat, maturity : Nat, paymentMonths : Nat) : [SwapPeriod] {
    if (paymentMonths == 0) return [];
    var out : [SwapPeriod] = [];
    var k = 1; var s = start;
    label walk loop {
      let e = Products.addMonths(start, k * paymentMonths);
      if (e > maturity) return [];
      out := Array.concat(out, [{ start = s; end = e }]);
      if (e == maturity) break walk;
      s := e; k += 1;
      if (k > 1200) return [];
    };
    out
  };

  /// A leg's payment for a period at a rate in bps (a rational), rounded half-even.
  public func legAmount(notional : Nat, rateBps : Q, conv : DC.Convention, p : SwapPeriod) : Int {
    roundHalfEven(div(mul(mul(ofNat(notional), rateBps), ofFraction(DC.fraction(conv, p.start, p.end))), ofNat(BPS)))
  };

  /// The forward rate in bps implied by the zero curve between two tenors from today, simple compounding over
  /// the period's fraction: `(DF(t₀) / DF(t₁) − 1) / fraction`.
  public func impliedForwardBps(zeroCurve : [(Nat, Int)], days0 : Nat, days1 : Nat, frac : Q) : Q {
    if (frac.n == 0) return zero();
    let ratio = div(discountOn(zeroCurve, days0), discountOn(zeroCurve, days1));
    mul(div(sub(ratio, ofInt(1)), frac), ofNat(BPS))
  };

  /// The mark of a vanilla swap on `day` from the bank's side: Σ over periods ending after `day` of
  /// `DF(end − day) × (floating − fixed)`, with the sign flipped when the bank receives fixed. A period already
  /// fixed (its start on or before `day`, a fixing recorded) uses the contractual amount; a later period uses the
  /// curve's implied forward plus the spread, unrounded. Rounded half-even once. `fixingFor(start)` is the
  /// recorded fixing in bps for a period start, or null.
  public func swapMark(notional : Nat, payFixed : Bool, fixedBps : Nat, spreadBps : Int, conv : DC.Convention, periods : [SwapPeriod], zeroCurve : [(Nat, Int)], day : Nat, fixingFor : Nat -> ?Nat) : Int {
    var pv = zero();
    for (p in periods.vals()) {
      if (p.end > day) {
        let frac = ofFraction(DC.fraction(conv, p.start, p.end));
        let fixed = ofInt(legAmount(notional, ofNat(fixedBps), conv, p));
        let floating = if (p.start <= day) {
          switch (fixingFor(p.start)) {
            case (?f) ofInt(legAmount(notional, ofInt(f + spreadBps), conv, p));
            case null projected(notional, spreadBps, conv, p, zeroCurve, day, frac);
          }
        } else projected(notional, spreadBps, conv, p, zeroCurve, day, frac);
        let net = mul(sub(floating, fixed), discountOn(zeroCurve, p.end - day));
        pv := add(pv, net);
      };
    };
    let m = roundHalfEven(pv);
    if (payFixed) m else -m
  };
  func projected(notional : Nat, spreadBps : Int, conv : DC.Convention, p : SwapPeriod, zeroCurve : [(Nat, Int)], day : Nat, frac : Q) : Q {
    let d0 = if (p.start > day) p.start - day else 0;
    let fwd = add(impliedForwardBps(zeroCurve, d0, p.end - day, frac), ofInt(spreadBps));
    div(mul(mul(ofNat(notional), fwd), ofFraction(DC.fraction(conv, p.start, p.end))), ofNat(BPS))
  };

  // ═══════════════════════════════════════════════════════
  //  DETERMINISTIC FIXED POINT (18 DECIMALS) AND GARMAN–KOHLHAGEN
  // ═══════════════════════════════════════════════════════

  public let ONE : Int = 1_000_000_000_000_000_000;
  let LN2 : Int = 693_147_180_559_945_309;          // ln 2
  let INV_SQRT_2PI : Int = 398_942_280_401_432_678; // 1 / √(2π)

  /// Truncating multiply and divide — Motoko's `Int` division truncates toward zero, and the twin does the same
  /// explicitly, because Python's `//` floors.
  public func fmul(a : Int, b : Int) : Int { (a * b) / ONE };
  public func fdiv(a : Int, b : Int) : Int { if (b == 0) 0 else (a * ONE) / b };
  public func ofQ(a : Q) : Int { (a.n * ONE) / a.d };

  /// Integer square root by Newton's method, exact floor.
  public func isqrt(n : Nat) : Nat {
    if (n < 2) return n;
    var x = n;
    var y = (x + 1) / 2;
    while (y < x) { x := y; y := (x + n / x) / 2 };
    x
  };
  public func fsqrt(a : Int) : Int { if (a <= 0) 0 else isqrt(Int.abs(a) * Int.abs(ONE)) };

  /// e^x: range-reduced by 2⁸ then a Taylor series of 24 terms, squared back eight times. |x| ≤ 64 in practice.
  public func fexp(x : Int) : Int {
    let r = x / 256;
    var term : Int = ONE;
    var sum : Int = ONE;
    var i : Int = 1;
    while (i <= 24) { term := fmul(term, r) / i; sum += term; i += 1 };
    var k = 0;
    while (k < 8) { sum := fmul(sum, sum); k += 1 };
    sum
  };

  /// ln x for x > 0: x = m · 2ᵉ with m in [1, 2), ln m by the atanh series of 40 terms.
  public func fln(x : Int) : Int {
    if (x <= 0) return 0;
    var m = x;
    var e : Int = 0;
    while (m >= 2 * ONE) { m := m / 2; e += 1 };
    while (m < ONE) { m := m * 2; e -= 1 };
    let z = fdiv(m - ONE, m + ONE);
    let z2 = fmul(z, z);
    var term = z;
    var sum : Int = 0;
    var i : Int = 0;
    while (i < 40) { sum += term / (2 * i + 1); term := fmul(term, z2); i += 1 };
    e * LN2 + 2 * sum
  };

  /// The standard normal CDF by Abramowitz–Stegun 26.2.17 (|ε| < 7.5 × 10⁻⁸), evaluated in fixed point.
  public func normCdf(x : Int) : Int {
    let ax = if (x < 0) -x else x;
    let t = fdiv(ONE, ONE + fmul(231_641_900_000_000_000, ax));
    let b1 : Int = 319_381_530_000_000_000;
    let b2 : Int = -356_563_782_000_000_000;
    let b3 : Int = 1_781_477_937_000_000_000;
    let b4 : Int = -1_821_255_978_000_000_000;
    let b5 : Int = 1_330_274_429_000_000_000;
    let poly = fmul(t, b1 + fmul(t, b2 + fmul(t, b3 + fmul(t, b4 + fmul(t, b5)))));
    let pdf = fmul(INV_SQRT_2PI, fexp(-fmul(ax, ax) / 2));
    let upper = ONE - fmul(pdf, poly);
    if (x < 0) ONE - upper else upper
  };

  /// Garman–Kohlhagen: the value in quote minor units of an option on `baseAmount` base minor units — spot and
  /// strike in micro, rates in bps treated as continuously compounded, volatility in bps, time in days ACT/365.
  /// `C = S e^{−r_f T} N(d₁) − K e^{−r_d T} N(d₂)`, `P = K e^{−r_d T} N(−d₂) − S e^{−r_f T} N(−d₁)`. At or past
  /// expiry the intrinsic value. The result is truncated to whole minor units.
  public func garmanKohlhagen(call : Bool, baseAmount : Nat, spotMicro : Int, strikeMicro : Nat, domesticBps : Int, foreignBps : Int, volBps : Nat, days : Nat) : Nat {
    if (spotMicro <= 0) return 0;
    if (days == 0 or volBps == 0) {
      let intrinsic : Int = if (call) spotMicro - strikeMicro else strikeMicro - spotMicro;
      if (intrinsic <= 0) return 0;
      return Int.abs((intrinsic * baseAmount) / MICRO);
    };
    let T = fdiv(days * ONE, 365 * ONE);
    let sigma = fdiv(volBps * ONE, BPS * ONE);
    let rd = fdiv(domesticBps * ONE, BPS * ONE);
    let rf = fdiv(foreignBps * ONE, BPS * ONE);
    let S = spotMicro * ONE / MICRO;
    let K = strikeMicro * ONE / MICRO;
    let sqrtT = fsqrt(T);
    let sigT = fmul(sigma, sqrtT);
    let lnSK = fln(fdiv(S, K));
    let drift = fmul(rd - rf + fmul(sigma, sigma) / 2, T);
    let d1 = fdiv(lnSK + drift, sigT);
    let d2 = d1 - sigT;
    let dfD = fexp(-fmul(rd, T));
    let dfF = fexp(-fmul(rf, T));
    let price = if (call) fmul(fmul(S, dfF), normCdf(d1)) - fmul(fmul(K, dfD), normCdf(d2))
                else fmul(fmul(K, dfD), normCdf(-d2)) - fmul(fmul(S, dfF), normCdf(-d1));
    if (price <= 0) return 0;
    // price is quote minor units per base minor unit (scaled by ONE); times the base amount, truncated
    Int.abs((price * baseAmount) / ONE)
  };
}
