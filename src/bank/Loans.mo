/// Loans.mo; repayment allocation, arrears, delinquency and impairment figures.
///
/// Schedule generation lives in `Products.mo` (it is shared with term products);
/// what is here is everything that happens to a loan after it is disbursed, and
/// all of it is a pure function of the schedule plus figures read from the journal.
/// There is no loan balance stored anywhere: principal outstanding is the journal
/// balance of the loan's sub-ledger under the principal control account, interest
/// receivable is the balance under the interest-receivable control, and fees and
/// penalties under theirs. Arrears and delinquency are computed from the schedule
/// and those balances on demand, so a back-dated repayment corrects the arrears
/// position by construction rather than by a recalculation job.
///
/// **Allocation order.** A repayment is applied in a declared order across
/// penalties, fees, interest and principal. Fineract's default is penalties →
/// fees → interest → principal and that is the default here, but the order is
/// product data rather than a constant, because it is a term a bank negotiates and
/// a regulator reads. Whatever the order, the allocation is exact: the components
/// sum to the payment, and an excess over the total outstanding is reported as an
/// overpayment rather than absorbed.
///
/// **Provisioning computes, it does not estimate.** Delinquency bands and the
/// percentage against each are declared parameters supplied by the institution
/// (IFRS 9 staging, the CBE classification bands). This module applies them. No
/// model is fitted, inferred or hidden here; a provision a regulator cannot
/// recompute is a provision that cannot be defended.

import Nat "mo:core/Nat";
import Text "mo:core/Text";
import List "mo:core/List";
import Array "mo:core/Array";

import T "ProductTypes";
import I "Interest";
import DC "DayCount";
import Products "Products";

module {

  /// The four things a repayment can be applied to, and how much of each a
  /// repayment settled. Declared in `ProductTypes` because the log's own event
  /// vocabulary names them.
  public type Component = T.Component;

  public type Allocation = T.Allocation;

  public func zeroAllocation() : Allocation { { penalty = 0; fee = 0; interest = 0; principal = 0 } };

  public func allocationTotal(a : Allocation) : Nat { a.penalty + a.fee + a.interest + a.principal };

  /// Fineract's default order, and the default here. A product may declare another.
  public func defaultOrder() : [Component] { [#penalty, #fee, #interest, #principal] };

  public func componentText(c : Component) : Text { T.componentText(c) };

  /// Is this a permutation of the four components, each exactly once? An order
  /// that drops a component would silently never repay it.
  public func validOrder(order : [Component]) : ?Text {
    if (order.size() != 4) return ?"an allocation order names all four components";
    var p = 0; var f = 0; var i = 0; var pr = 0;
    for (c in order.vals()) {
      switch (c) { case (#penalty) p += 1; case (#fee) f += 1; case (#interest) i += 1; case (#principal) pr += 1 };
    };
    if (p != 1 or f != 1 or i != 1 or pr != 1) return ?"an allocation order names each component exactly once";
    null
  };

  /// Apply `payment` across the outstanding components in `order`. Exact: the
  /// applied components sum to the payment less any overpayment, and the
  /// overpayment is what remains when everything outstanding is settled.
  public func allocate(payment : Nat, outstanding : Allocation, order : [Component]) : { applied : Allocation; overpayment : Nat } {
    var left = payment;
    var penalty = 0; var fee = 0; var interest = 0; var principal = 0;
    for (c in order.vals()) {
      let want = switch (c) {
        case (#penalty) outstanding.penalty;
        case (#fee) outstanding.fee;
        case (#interest) outstanding.interest;
        case (#principal) outstanding.principal;
      };
      let take = if (left >= want) want else left;
      switch (c) {
        case (#penalty) penalty := take; case (#fee) fee := take;
        case (#interest) interest := take; case (#principal) principal := take;
      };
      left -= take;
    };
    { applied = { penalty; fee; interest; principal }; overpayment = left }
  };

  // ═══════════════════════════════════════════════════════
  //  ARREARS
  // ═══════════════════════════════════════════════════════

  public type Arrears = {
    /// Total fallen due and unpaid as at the day asked about.
    overdueTotal : Nat;
    /// The due date of the oldest instalment not fully covered.
    oldestOverdueDue : ?T.Day;
    /// The age of that instalment in days, which is what the bands bucket on.
    overdueDays : Nat;
    /// How many instalments are wholly or partly unpaid.
    instalmentsOverdue : Nat;
    /// Total fallen due by that day, paid or not.
    dueToDate : Nat;
    /// What the borrower has paid in total.
    paid : Nat;
  };

  /// Arrears from the schedule and the total repaid. Cumulative, which is the only
  /// shape that stays correct when a repayment is back-dated: the position is a
  /// function of the two running totals and never of a sequence of adjustments.
  ///
  /// **Due and overdue are not the same day.** An instalment whose due date is `asOf`
  /// has fallen due; it is in `dueToDate`, and the end-of-day batch moves it into the
  /// borrower's receivable; but it is not late: the borrower has that day to pay it.
  /// Only instalments whose due date has passed are overdue, which is what
  /// `overdueTotal`, `instalmentsOverdue` and the delinquency band are computed from.
  ///
  /// Counting today's instalment as overdue would put every performing borrower into
  /// arrears on the morning of each due date and provision them at a worse stage for
  /// that day, which is both wrong and the behaviour Apache Fineract 1.15.0 does not
  /// have: its arrears ageing counts instalments before the business
  /// date, and the two systems agree once this does the same.
  public func arrears(rows : [T.Instalment], paid : Nat, asOf : T.Day) : Arrears {
    var dueToDate : Nat = 0;
    var overdueDue : Nat = 0;
    var cumulative : Nat = 0;
    var oldest : ?T.Day = null;
    var instalmentsOverdue : Nat = 0;
    for (r in rows.vals()) {
      if (r.dueDate <= asOf) {
        let amount = r.principal + r.interest + r.fees;
        dueToDate += amount;
        cumulative += amount;
        if (r.dueDate < asOf) {
          overdueDue += amount;
          // this instalment is unpaid, wholly or in part, when the payments received
          // do not reach its cumulative end
          if (paid < cumulative) {
            instalmentsOverdue += 1;
            // the first instalment the payments do not reach is the oldest overdue one
            if (oldest == null) oldest := ?r.dueDate;
          };
        };
      };
    };
    // payments are applied oldest first, so what is overdue is what has passed its due
    // date less everything paid so far
    let overdueTotal = if (overdueDue > paid) overdueDue - paid else 0;
    let overdueDays = switch (oldest) {
      case (?d) { if (asOf > d) asOf - d else 0 };
      case null 0;
    };
    { overdueTotal; oldestOverdueDue = oldest; overdueDays; instalmentsOverdue; dueToDate; paid }
  };

  /// The delinquency band an arrears position falls in.
  /// The band the arrears age into, which is the band covering the overdue days;
  /// **including zero overdue days**.
  ///
  /// A performing loan is not unclassified: under IFRS 9 it sits in stage 1 and carries a
  /// twelve-month expected-loss allowance, and the CBE's own classification has a
  /// performing grade with a general provision against it. So a product that declares a
  /// band starting at day 0 gets it applied to its performing exposure, and the stage-1
  /// rule it also declared is a rule that fires rather than configuration nobody can
  /// reach. A product that declares no band covering zero days still gets `null`, and
  /// provides nothing, which is the same answer as before for that product.
  public func band(terms : T.ProductTerms, a : Arrears) : ?Text {
    Products.delinquencyBand(terms, a.overdueDays)
  };

  /// The provision required against an outstanding exposure, as an exact rational
  /// and as the rounded figure that would be posted.
  public func requiredProvision(
    terms : T.ProductTerms,
    a : Arrears,
    outstanding : Nat,
    mode : I.Rounding,
  ) : { band : ?Text; stage : ?Nat; exact_ : I.Signed; amount : Nat } {
    switch (band(terms, a)) {
      case null { { band = null; stage = null; exact_ = I.zero(); amount = 0 } };
      case (?name) {
        var stage : ?Nat = null;
        for (r in terms.provisioning.vals()) { if (Text.equal(r.band, name)) stage := ?r.stage };
        switch (Products.provision(terms, name, outstanding)) {
          case null { { band = ?name; stage; exact_ = I.zero(); amount = 0 } };
          case (?x) { { band = ?name; stage; exact_ = x; amount = (I.round(x, mode)).amount } };
        }
      };
    }
  };

  /// The movement needed to bring the allowance to the required figure: a charge to
  /// impairment expense when the provision rises, a release when it falls. Never a
  /// direct restatement of the allowance, because the expense side has to move too.
  public func provisionMovement(current : Nat, required : Nat) : { #increase : Nat; #release : Nat; #unchanged } {
    if (required > current) #increase(required - current)
    else if (current > required) #release(current - required)
    else #unchanged
  };

  // ═══════════════════════════════════════════════════════
  //  WRITE-OFF AND RECOVERY
  // ═══════════════════════════════════════════════════════

  public type WriteOff = {
    /// Principal, interest, fees and penalties written off; the whole exposure,
    /// each from its own control account, so each balance-sheet line is relieved
    /// of its own figure and nothing is netted.
    components : Allocation;
    /// How much of the loss the allowance already carries; the rest is a fresh
    /// charge to impairment expense.
    fromAllowance : Nat;
    toExpense : Nat;
  };

  /// The write-off figures for an exposure, given what the allowance already holds.
  /// The allowance absorbs as much of the loss as it carries and the remainder is a
  /// charge, which is the only treatment that leaves both the allowance and the
  /// expense at a figure an auditor can tie to the movement.
  public func writeOff(exposure : Allocation, allowance : Nat) : WriteOff {
    let total = allocationTotal(exposure);
    let fromAllowance = if (allowance >= total) total else allowance;
    { components = exposure; fromAllowance; toExpense = total - fromAllowance }
  };

  /// A recovery after write-off is income, not a reversal of the write-off: the
  /// exposure is gone from the books, so the cash received credits the recovery
  /// account. Splitting it back across components would re-create balances that
  /// were removed.
  public func recovery(amount : Nat) : { toRecoveryIncome : Nat } { { toRecoveryIncome = amount } };

  // ═══════════════════════════════════════════════════════
  //  RESCHEDULING
  // ═══════════════════════════════════════════════════════

  public type RescheduleRequest = {
    /// The day from which the new schedule runs. Instalments already due keep their
    /// dates; only the remainder is regenerated.
    effective : T.Day;
    terms : T.ScheduleTerms;
    rate : I.Rate;
  };

  /// Reschedule: instalments that already fell due are retained exactly as they
  /// were, and the outstanding principal as at the effective day is re-amortised
  /// over the new terms. The superseded schedule is kept by the caller as a
  /// version, so the change is a recorded decision and not an edit.
  public func reschedule(
    old : [T.Instalment],
    req : RescheduleRequest,
    rounding : I.Rounding,
  ) : { rows : [T.Instalment]; retained : Nat; reamortised : Nat; outstandingAtEffective : Nat } {
    let kept = List.empty<T.Instalment>();
    var outstanding : Nat = 0;
    var found = false;
    for (r in old.vals()) {
      if (r.dueDate < req.effective) {
        List.add(kept, r);
        outstanding := r.closingPrincipal;
        found := true;
      };
    };
    if (not found and old.size() > 0) outstanding := old[0].openingPrincipal;
    let fresh = Products.schedule(outstanding, req.rate, req.terms, rounding, req.effective);
    let renumbered = Array.tabulate<T.Instalment>(fresh.rows.size(), func(i) {
      let r = fresh.rows[i];
      { r with number = List.size(kept) + i + 1 }
    });
    let all = List.empty<T.Instalment>();
    for (r in List.values(kept)) { List.add(all, r) };
    for (r in renumbered.vals()) { List.add(all, r) };
    {
      rows = List.toArray(all);
      retained = List.size(kept);
      reamortised = renumbered.size();
      outstandingAtEffective = outstanding;
    }
  };

  /// The modification gain or loss of a restructuring (IFRS 9 §5.4.3), stated as this bank computes it and as
  /// the Python oracle of `bank_s31.py` reproduces it. The gross carrying amount before the modification
  /// (`carrying`: principal, interest, fees and penalties outstanding at the effective day) is compared with
  /// the present value of the modified contractual cash flows, discounted at the **original** contractual
  /// rate: every instalment of the new schedule due on or after the effective day contributes
  /// `round(cashFlow × 1 / (1 + rate × fraction(effective, dueDate)))`; simple discounting per flow over the
  /// product's day-count convention, each flow rounded on its own under the product's rounding, so the
  /// figure is exact, bounded and identical on both sides. What had fallen due and was unpaid at the
  /// effective day (`pastDueUnpaid`) is present-valued at par; it is due now; and the retained instalments
  /// of the old schedule are not flows of the modification. A positive result is a loss (the modified flows
  /// are worth less than the carrying amount), a negative one a gain.
  public func modificationGainLoss(
    newRows : [T.Instalment], effective : T.Day, originalRate : I.Rate, convention : DC.Convention, carrying : Nat, mode : I.Rounding, pastDueUnpaid : Nat,
  ) : { presentValue : Nat; loss : Nat; gain : Nat } {
    var pv : Nat = pastDueUnpaid;
    for (r in newRows.vals()) {
      let flow = r.principal + r.interest + r.fees;
      if (flow > 0 and r.dueDate > effective) {
        let f = DC.fraction(convention, effective, r.dueDate);
        // discount factor = f.den × rate.den / (f.den × rate.den + rate.num × f.num)
        let dfNum = f.denominator * originalRate.denominator;
        let dfDen = f.denominator * originalRate.denominator + originalRate.numerator * f.numerator;
        let x : I.Signed = { numerator = flow * dfNum; denominator = dfDen; negative = false };
        pv += I.round(x, mode).amount;
      };
    };
    if (carrying > pv) { { presentValue = pv; loss = carrying - pv; gain = 0 } } else { { presentValue = pv; loss = 0; gain = pv - carrying } }
  };
};
