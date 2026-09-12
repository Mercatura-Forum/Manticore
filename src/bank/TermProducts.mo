/// TermProducts.mo — fixed deposits, recurring deposits and share accounts.
///
/// A term product is a deposit with a maturity and a rate chosen from a chart by
/// **term**, not by balance: a 180-day deposit earns the 180-day band's rate for
/// its whole life, which is why the rate is resolved once at opening and recorded
/// on the account rather than looked up each day. A balance-banded chart is the
/// other shape and is resolved per accrual window; both are supported because both
/// are sold, and which one a product uses is declared in the chart itself.
///
/// Early redemption is a penalty, not a loss of principal: the deposit is closed,
/// the interest is recomputed at the penalised rate for the period actually held,
/// and the difference against what had already been credited is recovered. That is
/// the treatment Fineract's fixed-deposit pre-closure implements and the one a
/// depositor can check with a calculator.
///
/// A recurring deposit is the same machinery with a required instalment: each
/// expected deposit has a due date, a shortfall is recorded rather than assumed,
/// and interest is computed on the balance that was actually there — which is the
/// daily-balance fold, unchanged.

import Nat "mo:core/Nat";
import List "mo:core/List";

import CivilDate "mo:journal/CivilDate";

import T "ProductTypes";
import I "Interest";
import DC "DayCount";
import Products "Products";

module {

  public type TermFault = {
    #noBandForTerm : { termDays : Nat };
    #noBandForBalance : { balance : Nat };
    #chartIsByBalance;
    #chartIsByTerm;
    #notMatured : { maturity : T.Day; asOf : T.Day };
    #alreadyMatured : { maturity : T.Day };
    #termTooShort : { minimumDays : Nat; termDays : Nat };
  };

  /// The rate a term deposit is opened at: the band the **term** falls in. A chart
  /// banded by balance cannot answer this question, and saying so is better than
  /// silently reading the first band.
  public func rateForTerm(chart : T.RateChart, termDays : Nat) : { #ok : I.Rate; #err : TermFault } {
    if (chart.by != #termDays) return #err(#chartIsByBalance);
    switch (Products.rateAt(chart, termDays)) {
      case (?r) #ok(r);
      case null #err(#noBandForTerm({ termDays }));
    }
  };

  /// The rate for a balance-banded chart, resolved for an accrual window. A balance
  /// exactly on a band boundary belongs to the **upper** band, because bands are
  /// `[from, to)` — stated here because "which side of the boundary" is the first
  /// thing a depositor disputes.
  public func rateForBalance(chart : T.RateChart, balance : Nat) : { #ok : I.Rate; #err : TermFault } {
    if (chart.by != #balance) return #err(#chartIsByTerm);
    switch (Products.rateAt(chart, balance)) {
      case (?r) #ok(r);
      case null #err(#noBandForBalance({ balance }));
    }
  };

  /// The maturity day of a deposit opened on `opened` for `termDays`.
  public func maturityOf(opened : T.Day, termDays : Nat) : T.Day { opened + termDays };

  /// The maturity value of a fixed deposit: principal plus the interest earned over
  /// the whole term at the opening rate, compounded at the declared period. Exact
  /// until the single rounding at the end, so the figure a depositor is quoted is
  /// the figure the books will show.
  public func maturityValue(
    principal : Nat,
    rate : I.Rate,
    terms : T.InterestTerms,
    rounding : I.Rounding,
    opened : T.Day,
    maturity : T.Day,
  ) : { value : Nat; interest : Nat; exact_ : I.Signed; compoundings : Nat } {
    let months = T.periodMonths(terms.compounding);
    if (months == 0 or terms.compounding == #atMaturity) {
      // simple interest over the whole term
      let x = I.periodAccrual(principal, rate, terms.convention, opened, maturity);
      let r = I.round(x, rounding);
      return { value = principal + r.amount; interest = r.amount; exact_ = x; compoundings = 1 };
    };
    // compound: each period's interest is added to the balance the next period
    // accrues on. The balance carried forward is the exact rational, so the
    // rounding happens once at the end and not once per period.
    var balanceNum : Nat = principal;
    var balanceDen : Nat = 1;
    var cursor = opened;
    var periods : Nat = 0;
    // Each compounding date is measured from the **opening** date, not from the
    // previous one. Measuring from the previous date makes a deposit opened on the
    // 31st drift to the 28th and stay there, which silently changes the number of
    // periods in the term; measuring from the opening date is both the convention
    // and the only version that returns to the 31st after a short month.
    while (cursor < maturity) {
      let next0 = switch (terms.compoundingAlignment) {
        case (#anniversary) Products.addMonths(opened, months * (periods + 1));
        case (#calendar) Products.startOfMonthAfter(opened, months * periods);
      };
      let next = if (next0 > maturity) maturity else next0;
      if (next <= cursor) { cursor := maturity }
      else {
        let f = DC.fraction(terms.convention, cursor, next);
        // balance := balance × (1 + rate × f)
        let addNum = balanceNum * rate.numerator * f.numerator;
        let addDen = balanceDen * rate.denominator * f.denominator;
        if (rate.negative) {
          // balance − add, over a common denominator
          let commonNum = balanceNum * addDen;
          let subNum = addNum * balanceDen;
          balanceNum := if (commonNum >= subNum) commonNum - subNum else 0;
          balanceDen := balanceDen * addDen;
        } else {
          balanceNum := balanceNum * addDen + addNum * balanceDen;
          balanceDen := balanceDen * addDen;
        };
        periods += 1;
        cursor := next;
      };
    };
    // interest = balance − principal, exact
    let pNum = principal * balanceDen;
    let exact_ : I.Signed =
      if (balanceNum >= pNum) { { numerator = balanceNum - pNum; denominator = balanceDen; negative = false } }
      else { { numerator = pNum - balanceNum; denominator = balanceDen; negative = true } };
    let r = I.round(exact_, rounding);
    let value = if (r.negative) { if (principal >= r.amount) principal - r.amount else 0 } else principal + r.amount;
    // The exact figure is reduced before it leaves: compounding multiplies a
    // denominator per period, so an unreduced seven-period rational is hundreds of
    // digits long and says nothing a reader can check.
    { value; interest = r.amount; exact_ = reduce(exact_); compoundings = periods }
  };

  /// Early redemption. The deposit is recomputed at the penalised rate over the
  /// period actually held; `recoverable` is what must be taken back from interest
  /// already credited, and `payable` is what is still owed if the recomputation is
  /// higher than what was credited. Both are reported, because a penalty that
  /// cannot produce a shortfall is a penalty that was never applied.
  public func earlyRedemption(
    principal : Nat,
    openingRate : I.Rate,
    penalty : I.Rate,
    terms : T.InterestTerms,
    rounding : I.Rounding,
    opened : T.Day,
    redeemed : T.Day,
    alreadyCredited : Nat,
  ) : {
    penalisedRate : I.Rate;
    entitled : Nat;
    recoverable : Nat;
    payable : Nat;
    daysHeld : Nat;
    exact_ : I.Signed;
  } {
    // the penalised rate is the opening rate less the penalty, floored at zero
    let common = openingRate.denominator * penalty.denominator;
    let openNum = openingRate.numerator * penalty.denominator;
    let penNum = penalty.numerator * openingRate.denominator;
    let penalisedRate : I.Rate =
      if (openingRate.negative) { { numerator = openNum + penNum; denominator = common; negative = true } }
      else if (openNum >= penNum) { { numerator = openNum - penNum; denominator = common; negative = false } }
      else { { numerator = 0; denominator = common; negative = false } };
    let held = if (redeemed > opened) redeemed - opened else 0;
    let m = maturityValue(principal, penalisedRate, terms, rounding, opened, redeemed);
    let entitled = m.interest;
    let recoverable = if (alreadyCredited > entitled) alreadyCredited - entitled else 0;
    let payable = if (entitled > alreadyCredited) entitled - alreadyCredited else 0;
    { penalisedRate; entitled; recoverable; payable; daysHeld = held; exact_ = m.exact_ }
  };

  // ═══════════════════════════════════════════════════════
  //  RECURRING DEPOSITS
  // ═══════════════════════════════════════════════════════

  public type Expected = { number : Nat; dueDate : T.Day; amount : Nat };

  /// The expected deposits of a recurring plan. Pure, so a shortfall is the
  /// difference between this list and the journal's own credits and never a figure
  /// someone maintained.
  public func expectedDeposits(instalment : Nat, sch : T.ScheduleTerms, opened : T.Day) : [Expected] {
    let out = List.empty<Expected>();
    var n = 0;
    while (n < sch.instalments) {
      List.add(out, { number = n + 1; dueDate = Products.instalmentDate(opened, sch, n + 1); amount = instalment });
      n += 1;
    };
    List.toArray(out)
  };

  /// The shortfall of a recurring plan as at a day: what should have been deposited
  /// against what was, and how many instalments are short.
  public func shortfall(expected : [Expected], deposited : Nat, asOf : T.Day) : { expectedToDate : Nat; shortfall : Nat; instalmentsMissed : Nat } {
    var expectedToDate : Nat = 0;
    var cumulative : Nat = 0;
    var missed : Nat = 0;
    for (e in expected.vals()) {
      if (e.dueDate <= asOf) {
        expectedToDate += e.amount;
        cumulative += e.amount;
        if (deposited < cumulative) missed += 1;
      };
    };
    { expectedToDate; shortfall = if (expectedToDate > deposited) expectedToDate - deposited else 0; instalmentsMissed = missed }
  };

  /// Reduce a signed rational to its lowest terms.
  public func reduce(x : I.Signed) : I.Signed {
    if (x.numerator == 0) return { numerator = 0; denominator = 1; negative = false };
    var a = x.numerator;
    var b = x.denominator;
    while (b != 0) { let t = a % b; a := b; b := t };
    { numerator = x.numerator / a; denominator = x.denominator / a; negative = x.negative }
  };

  /// A term in whole days between two dates, which is what a chart banded by term
  /// is read with.
  public func termDays(from : T.Day, to : T.Day) : Nat { CivilDate.distance(from, to) };
};
