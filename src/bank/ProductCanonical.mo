/// ProductCanonical.mo; the canonical bytes of the product engine's vocabulary.
///
/// Tag per variant, additive, never renumbered: the same rule the journal's own
/// encoder follows, for the same reason. A product's terms are the single most
/// disputable object in a bank, so the bytes that go in the block are a total
/// function of the terms and nothing else; there is no map iteration, no optional
/// field that can be absent in one encoding and present in another, and every
/// variable-length part carries its own length.
///
/// The writers and readers here are mirror images and the battery proves it by
/// round-tripping one value of every variant and then flipping every byte of every
/// block, which is also how a new variant missing from the codec is caught.

import List "mo:core/List";

import C "mo:journal/Canonical";

import T "ProductTypes";
import I "Interest";
import DC "DayCount";

module {

  // ═══════════════════════════════════════════════════════
  //  WRITERS
  // ═══════════════════════════════════════════════════════

  public func wRate(w : C.Writer, r : I.Rate) { w.nat(r.numerator); w.nat(r.denominator); w.bool(r.negative) };

  public func wRounding(w : C.Writer, m : I.Rounding) {
    w.byte(switch (m) { case (#halfEven) 0; case (#halfUp) 1; case (#down) 2 });
  };

  public func wConvention(w : C.Writer, c : DC.Convention) {
    switch (c) {
      case (#a001_ActActIcma(x)) { w.byte(0x01); w.nat(x.couponsPerYear) };
      case (#a003_Act360) w.byte(0x03);
      case (#a004_Act365Fixed) w.byte(0x04);
      case (#a005_ActActIsda) w.byte(0x05);
      case (#a006_Thirty360Isda) w.byte(0x06);
      case (#a007_ThirtyE360) w.byte(0x07);
      case (#a011_Thirty365) w.byte(0x0B);
    };
  };

  public func wPeriod(w : C.Writer, p : T.Period) {
    w.byte(switch (p) {
      case (#daily) 0; case (#monthly) 1; case (#quarterly) 2;
      case (#semiAnnual) 3; case (#annual) 4; case (#atMaturity) 5;
    });
  };

  public func wRole(w : C.Writer, r : T.Role) {
    w.byte(switch (r) {
      case (#principal) 0x01; case (#interestPayable) 0x02; case (#interestExpense) 0x03;
      case (#interestReceivable) 0x04; case (#interestIncome) 0x05; case (#feeIncome) 0x06;
      case (#penaltyIncome) 0x07; case (#feeReceivable) 0x08; case (#penaltyReceivable) 0x09;
      case (#taxPayable) 0x0A; case (#overdraftPortfolio) 0x0B; case (#writeOff) 0x0C;
      case (#recovery) 0x0D; case (#allowance) 0x0E; case (#impairmentExpense) 0x0F;
      case (#suspense) 0x10; case (#cash) 0x11; case (#modificationAdjustment) 0x12;
      case (#dueToParticipants) 0x13; case (#participantPayable) 0x14; case (#rentReceivable) 0x15; case (#rentalIncome) 0x16;
      case (#purchasedReceivables) 0x17; case (#retentionPayable) 0x18; case (#unearnedDiscount) 0x19; case (#discountIncome) 0x1A;
    });
  };

  public func wKind(w : C.Writer, k : T.ProductKind) {
    w.byte(switch (k) {
      case (#currentAccount) 0x01; case (#savings) 0x02; case (#termDeposit) 0x03;
      case (#recurringDeposit) 0x04; case (#loan) 0x05; case (#shareAccount) 0x06; case (#till) 0x07;
    });
  };

  public func wComponent(w : C.Writer, c : T.Component) {
    w.byte(switch (c) { case (#penalty) 0; case (#fee) 1; case (#interest) 2; case (#principal) 3 });
  };

  public func wComponents(w : C.Writer, cs : [T.Component]) {
    w.len16(cs.size()); for (c in cs.vals()) { wComponent(w, c) };
  };

  public func wAllocation(w : C.Writer, a : T.Allocation) {
    w.nat(a.penalty); w.nat(a.fee); w.nat(a.interest); w.nat(a.principal);
  };

  public func wStatus(w : C.Writer, st : T.AccountStatus) {
    w.byte(switch (st) { case (#pending) 0; case (#active) 1; case (#dormant) 2; case (#closed) 3 });
  };

  public func wDifference(w : C.Writer, d : T.Difference) {
    switch (d) {
      case (#balanced) w.byte(0);
      case (#over(n)) { w.byte(1); w.nat(n) };
      case (#short(n)) { w.byte(2); w.nat(n) };
    };
  };

  public func wFunding(w : C.Writer, f : T.Funding) {
    switch (f) {
      case (#till(t)) { w.byte(0); w.text(t) };
      case (#glAccount(a)) { w.byte(1); w.text(a) };
    };
  };

  public func wChargeBase(w : C.Writer, b : T.ChargeBase) {
    w.optNat(b.amount); w.optNat(b.interest); w.optNat(b.outstanding);
  };

  func wBands(w : C.Writer, bs : [T.RateBand]) {
    w.len16(bs.size());
    for (b in bs.vals()) { w.nat(b.from); w.optNat(b.to); wRate(w, b.rate) };
  };

  public func wChart(w : C.Writer, c : T.RateChart) {
    wBands(w, c.bands);
    w.byte(switch (c.by) { case (#balance) 0; case (#termDays) 1 });
  };

  public func wInterest(w : C.Writer, it : T.InterestTerms) {
    wChart(w, it.chart); wConvention(w, it.convention);
    w.byte(switch (it.basis) { case (#dailyBalance) 0; case (#averageDailyBalance) 1 });
    wPeriod(w, it.compounding);
    w.byte(switch (it.compoundingAlignment) { case (#anniversary) 0; case (#calendar) 1 });
    wPeriod(w, it.posting);
    w.nat(it.minimumBalance); w.bool(it.allowNegative);
  };

  public func wCalculation(w : C.Writer, c : T.ChargeCalculation) {
    switch (c) {
      case (#flat(x)) { w.byte(0); w.nat(x.amount) };
      case (#percentOfAmount(x)) { w.byte(1); wRate(w, x.rate) };
      case (#percentOfInterest(x)) { w.byte(2); wRate(w, x.rate) };
      case (#percentOfPrincipalOutstanding(x)) { w.byte(3); wRate(w, x.rate) };
    };
  };

  public func wTiming(w : C.Writer, t : T.ChargeTiming) {
    switch (t) {
      case (#onActivation) w.byte(0);
      case (#onTransaction) w.byte(1);
      case (#onDate(x)) { w.byte(2); w.nat(x.day) };
      case (#recurring(x)) { w.byte(3); wPeriod(w, x.every) };
      case (#overdue(x)) { w.byte(4); w.nat(x.afterDays) };
      case (#onClosure) w.byte(5);
    };
  };

  public func wCharges(w : C.Writer, cs : [T.Charge]) {
    w.len16(cs.size());
    for (c in cs.vals()) {
      w.text(c.id); wCalculation(w, c.calculation); wTiming(w, c.timing);
      w.text(c.currency); wRole(w, c.role); w.bool(c.waivable);
    };
  };

  public func wAmortisation(w : C.Writer, a : T.Amortisation) {
    switch (a) {
      case (#equalInstalments) w.byte(0);
      case (#equalPrincipal) w.byte(1);
      case (#flat) w.byte(2);
      case (#balloon(x)) { w.byte(3); w.nat(x.finalPrincipal) };
    };
  };

  public func wSchedule(w : C.Writer, s : T.ScheduleTerms) {
    wAmortisation(w, s.amortisation); w.nat(s.instalments); wPeriod(w, s.every);
    w.nat(s.principalGrace); w.nat(s.interestGrace); w.nat(s.moratoriumDays);
  };

  public func wInstalments(w : C.Writer, rows : [T.Instalment]) {
    w.len16(rows.size());
    for (r in rows.vals()) {
      w.nat(r.number); w.nat(r.dueDate); w.nat(r.openingPrincipal);
      w.nat(r.principal); w.nat(r.interest); w.nat(r.fees); w.nat(r.closingPrincipal);
    };
  };

  public func wTerms(w : C.Writer, t : T.ProductTerms) {
    wKind(w, t.kind); w.text(t.currency); w.text(t.control);
    w.len16(t.roles.size());
    for (m in t.roles.vals()) { wRole(w, m.role); w.text(m.account) };
    switch (t.interest) { case null w.byte(0); case (?it) { w.byte(1); wInterest(w, it) } };
    wCharges(w, t.charges);
    w.optNat(t.limits.overdraft); w.nat(t.limits.minimumOperating); w.optNat(t.limits.perOperation);
    switch (t.schedule) { case null w.byte(0); case (?s) { w.byte(1); wSchedule(w, s) } };
    w.len16(t.delinquency.size());
    for (b in t.delinquency.vals()) { w.text(b.name); w.nat(b.fromDays); w.optNat(b.toDays) };
    w.len16(t.provisioning.size());
    for (r in t.provisioning.vals()) { w.text(r.band); w.nat(r.stage); wRate(w, r.percentOfOutstanding) };
    w.byte(switch (t.accounting) { case (#cash) 0; case (#accrualPeriodic) 1 });
    switch (t.withholdingTax) { case null w.byte(0); case (?r) { w.byte(1); wRate(w, r) } };
    wRounding(w, t.rounding);
    switch (t.earlyRedemptionPenalty) { case null w.byte(0); case (?r) { w.byte(1); wRate(w, r) } };
    w.byte(switch (t.valueDateConvention) {
      case (#sameDay) 0; case (#following) 1; case (#modifiedFollowing) 2;
      case (#preceding) 3; case (#modifiedPreceding) 4; case (#endOfMonth) 5;
    });
  };

  public func writeEvent(w : C.Writer, e : T.ProductEvent) {
    switch (e) {
      case (#productRegistered(x)) { w.byte(0x01); w.text(x.id); w.nat(x.version); w.text(x.name); wTerms(w, x.terms) };
      case (#productAmended(x)) { w.byte(0x02); w.text(x.id); w.nat(x.version); w.nat(x.supersedes); w.text(x.name); wTerms(w, x.terms) };
      case (#productClosedToNewAccounts(x)) { w.byte(0x03); w.text(x.id); w.nat(x.version) };
      case (#accountOpened(x)) {
        w.byte(0x04); w.text(x.product); w.nat(x.version); w.nat(x.party); w.text(x.book);
        w.text(x.identifier); w.text(x.currency); w.nat(x.opened); w.optNat(x.maturity);
        switch (x.openingRate) { case null w.byte(0); case (?r) { w.byte(1); wRate(w, r) } };
        wComponents(w, x.allocationOrder);
      };
      case (#accountStatusSet(x)) { w.byte(0x05); w.nat(x.account); wStatus(w, x.to) };
      case (#accountMigrated(x)) { w.byte(0x06); w.nat(x.account); w.nat(x.from); w.nat(x.to) };
      case (#facilityGranted(x)) { w.byte(0x07); w.nat(x.account); w.nat(x.limit) };
      case (#chargeApplied(x)) { w.byte(0x08); w.nat(x.account); w.text(x.charge); w.nat(x.amount); w.nat(x.day) };
      case (#chargeWaived(x)) { w.byte(0x09); w.nat(x.account); w.text(x.charge); w.nat(x.occurrence); w.optNat(x.reversalOf); w.text(x.reason) };
      case (#accrualPosted(x)) { w.byte(0x0A); w.text(x.product); w.text(x.currency); w.nat(x.day); w.nat(x.amount); w.nat(x.accounts) };
      case (#interestCapitalised(x)) {
        w.byte(0x0B); w.text(x.product); w.text(x.currency); w.nat(x.from); w.nat(x.to);
        w.nat(x.examined); w.nat(x.posted); w.nat(x.zero); w.nat(x.total);
        w.nat(x.residueNumerator); w.nat(x.residueDenominator); w.bool(x.residueNegative);
      };
      case (#loanDisbursed(x)) { w.byte(0x0C); w.nat(x.account); w.nat(x.amount); w.nat(x.day); wInstalments(w, x.schedule) };
      case (#loanRescheduled(x)) { w.byte(0x0D); w.nat(x.account); w.nat(x.version); w.nat(x.effective); wInstalments(w, x.schedule) };
      case (#repaymentReceived(x)) { w.byte(0x0E); w.nat(x.account); w.nat(x.day); w.nat(x.amount); wAllocation(w, x.applied); w.nat(x.overpayment) };
      case (#provisionSet(x)) {
        w.byte(0x0F); w.nat(x.account);
        switch (x.band) { case null w.byte(0); case (?b) { w.byte(1); w.text(b) } };
        w.optNat(x.stage); w.nat(x.required); w.nat(x.previous);
      };
      case (#loanWrittenOff(x)) { w.byte(0x10); w.nat(x.account); wAllocation(w, x.components); w.nat(x.fromAllowance); w.nat(x.toExpense); w.nat(x.day) };
      case (#recoveryReceived(x)) { w.byte(0x11); w.nat(x.account); w.nat(x.amount); w.nat(x.day) };
      case (#termDepositRedeemed(x)) { w.byte(0x12); w.nat(x.account); w.nat(x.day); w.nat(x.entitled); w.nat(x.recoverable); w.nat(x.payable); w.bool(x.early) };
      case (#tillOpened(x)) { w.byte(0x13); w.text(x.till); w.text(x.book); w.text(x.currency); w.principal(x.holder); w.text(x.product) };
      case (#tillAllocated(x)) { w.byte(0x14); w.text(x.till); w.nat(x.amount); w.nat(x.day) };
      case (#tillReturned(x)) { w.byte(0x15); w.text(x.till); w.nat(x.amount); w.nat(x.day) };
      case (#tillSettled(x)) { w.byte(0x16); w.text(x.till); w.nat(x.declared); w.nat(x.book); wDifference(w, x.difference); w.nat(x.day) };
      case (#tillClosed(x)) { w.byte(0x17); w.text(x.till) };
      case (#accountRateSet(x)) { w.byte(0x18); w.nat(x.account); wRate(w, x.rate); w.nat(x.effective) };
      case (#productRedenominated(x)) { w.byte(0x19); w.text(x.id); w.nat(x.version); w.nat(x.supersedes); w.text(x.from); w.text(x.to); wTerms(w, x.terms) };
      case (#accountRedenominated(x)) { w.byte(0x1A); w.nat(x.account); w.nat(x.version); w.text(x.from); w.text(x.to) };
      case (#scheduleTermsSet(x)) { w.byte(0x1B); w.nat(x.account); wSchedule(w, x.terms); w.nat(x.effective) };
    };
  };

  // ═══════════════════════════════════════════════════════
  //  READERS
  // ═══════════════════════════════════════════════════════

  public func rRate(r : C.Reader) : ?I.Rate {
    let ?numerator = r.nat() else return null;
    let ?denominator = r.nat() else return null;
    let ?negative = r.bool() else return null;
    ?{ numerator; denominator; negative }
  };

  public func rRounding(r : C.Reader) : ?I.Rounding {
    switch (r.byte()) { case (?0) ?#halfEven; case (?1) ?#halfUp; case (?2) ?#down; case (_) null }
  };

  public func rConvention(r : C.Reader) : ?DC.Convention {
    switch (r.byte()) {
      case (?0x01) { let ?n = r.nat() else return null; ?#a001_ActActIcma({ couponsPerYear = n }) };
      case (?0x03) ?#a003_Act360;
      case (?0x04) ?#a004_Act365Fixed;
      case (?0x05) ?#a005_ActActIsda;
      case (?0x06) ?#a006_Thirty360Isda;
      case (?0x07) ?#a007_ThirtyE360;
      case (?0x0B) ?#a011_Thirty365;
      case (_) null;
    }
  };

  public func rPeriod(r : C.Reader) : ?T.Period {
    switch (r.byte()) {
      case (?0) ?#daily; case (?1) ?#monthly; case (?2) ?#quarterly;
      case (?3) ?#semiAnnual; case (?4) ?#annual; case (?5) ?#atMaturity; case (_) null;
    }
  };

  public func rRole(r : C.Reader) : ?T.Role {
    switch (r.byte()) {
      case (?0x01) ?#principal; case (?0x02) ?#interestPayable; case (?0x03) ?#interestExpense;
      case (?0x04) ?#interestReceivable; case (?0x05) ?#interestIncome; case (?0x06) ?#feeIncome;
      case (?0x07) ?#penaltyIncome; case (?0x08) ?#feeReceivable; case (?0x09) ?#penaltyReceivable;
      case (?0x0A) ?#taxPayable; case (?0x0B) ?#overdraftPortfolio; case (?0x0C) ?#writeOff;
      case (?0x0D) ?#recovery; case (?0x0E) ?#allowance; case (?0x0F) ?#impairmentExpense;
      case (?0x10) ?#suspense; case (?0x11) ?#cash; case (?0x12) ?#modificationAdjustment;
      case (?0x13) ?#dueToParticipants; case (?0x14) ?#participantPayable; case (?0x15) ?#rentReceivable; case (?0x16) ?#rentalIncome;
      case (?0x17) ?#purchasedReceivables; case (?0x18) ?#retentionPayable; case (?0x19) ?#unearnedDiscount; case (?0x1A) ?#discountIncome; case (_) null;
    }
  };

  public func rKind(r : C.Reader) : ?T.ProductKind {
    switch (r.byte()) {
      case (?0x01) ?#currentAccount; case (?0x02) ?#savings; case (?0x03) ?#termDeposit;
      case (?0x04) ?#recurringDeposit; case (?0x05) ?#loan; case (?0x06) ?#shareAccount;
      case (?0x07) ?#till; case (_) null;
    }
  };

  public func rComponent(r : C.Reader) : ?T.Component {
    switch (r.byte()) { case (?0) ?#penalty; case (?1) ?#fee; case (?2) ?#interest; case (?3) ?#principal; case (_) null }
  };

  public func rComponents(r : C.Reader) : ?[T.Component] {
    let ?n = r.len16() else return null;
    let out = List.empty<T.Component>();
    var i = 0;
    while (i < n) { let ?c = rComponent(r) else return null; List.add(out, c); i += 1 };
    ?List.toArray(out)
  };

  public func rAllocation(r : C.Reader) : ?T.Allocation {
    let ?penalty = r.nat() else return null;
    let ?fee = r.nat() else return null;
    let ?interest = r.nat() else return null;
    let ?principal = r.nat() else return null;
    ?{ penalty; fee; interest; principal }
  };

  public func rStatus(r : C.Reader) : ?T.AccountStatus {
    switch (r.byte()) { case (?0) ?#pending; case (?1) ?#active; case (?2) ?#dormant; case (?3) ?#closed; case (_) null }
  };

  public func rDifference(r : C.Reader) : ?T.Difference {
    switch (r.byte()) {
      case (?0) ?#balanced;
      case (?1) { let ?n = r.nat() else return null; ?#over(n) };
      case (?2) { let ?n = r.nat() else return null; ?#short(n) };
      case (_) null;
    }
  };

  public func rFunding(r : C.Reader) : ?T.Funding {
    switch (r.byte()) {
      case (?0) { let ?t = r.text() else return null; ?#till(t) };
      case (?1) { let ?a = r.text() else return null; ?#glAccount(a) };
      case (_) null;
    }
  };

  public func rChargeBase(r : C.Reader) : ?T.ChargeBase {
    let ?amount = r.optNat() else return null;
    let ?interest = r.optNat() else return null;
    let ?outstanding = r.optNat() else return null;
    ?{ amount; interest; outstanding }
  };

  func rBands(r : C.Reader) : ?[T.RateBand] {
    let ?n = r.len16() else return null;
    let out = List.empty<T.RateBand>();
    var i = 0;
    while (i < n) {
      let ?from = r.nat() else return null;
      let ?to = r.optNat() else return null;
      let ?rate = rRate(r) else return null;
      List.add(out, { from; to; rate });
      i += 1;
    };
    ?List.toArray(out)
  };

  public func rChart(r : C.Reader) : ?T.RateChart {
    let ?bands = rBands(r) else return null;
    let by = switch (r.byte()) { case (?0) #balance; case (?1) #termDays; case (_) return null };
    ?{ bands; by }
  };

  public func rInterest(r : C.Reader) : ?T.InterestTerms {
    let ?chart = rChart(r) else return null;
    let ?convention = rConvention(r) else return null;
    let basis = switch (r.byte()) { case (?0) #dailyBalance; case (?1) #averageDailyBalance; case (_) return null };
    let ?compounding = rPeriod(r) else return null;
    let alignment = switch (r.byte()) { case (?0) #anniversary; case (?1) #calendar; case (_) return null };
    let ?posting = rPeriod(r) else return null;
    let ?minimumBalance = r.nat() else return null;
    let ?allowNegative = r.bool() else return null;
    ?{ chart; convention; basis; compounding; compoundingAlignment = alignment; posting; minimumBalance; allowNegative }
  };

  public func rCalculation(r : C.Reader) : ?T.ChargeCalculation {
    switch (r.byte()) {
      case (?0) { let ?a = r.nat() else return null; ?#flat({ amount = a }) };
      case (?1) { let ?x = rRate(r) else return null; ?#percentOfAmount({ rate = x }) };
      case (?2) { let ?x = rRate(r) else return null; ?#percentOfInterest({ rate = x }) };
      case (?3) { let ?x = rRate(r) else return null; ?#percentOfPrincipalOutstanding({ rate = x }) };
      case (_) null;
    }
  };

  public func rTiming(r : C.Reader) : ?T.ChargeTiming {
    switch (r.byte()) {
      case (?0) ?#onActivation;
      case (?1) ?#onTransaction;
      case (?2) { let ?d = r.nat() else return null; ?#onDate({ day = d }) };
      case (?3) { let ?p = rPeriod(r) else return null; ?#recurring({ every = p }) };
      case (?4) { let ?d = r.nat() else return null; ?#overdue({ afterDays = d }) };
      case (?5) ?#onClosure;
      case (_) null;
    }
  };

  public func rCharges(r : C.Reader) : ?[T.Charge] {
    let ?n = r.len16() else return null;
    let out = List.empty<T.Charge>();
    var i = 0;
    while (i < n) {
      let ?id = r.text() else return null;
      let ?calculation = rCalculation(r) else return null;
      let ?timing = rTiming(r) else return null;
      let ?currency = r.text() else return null;
      let ?role = rRole(r) else return null;
      let ?waivable = r.bool() else return null;
      List.add(out, { id; calculation; timing; currency; role; waivable });
      i += 1;
    };
    ?List.toArray(out)
  };

  public func rAmortisation(r : C.Reader) : ?T.Amortisation {
    switch (r.byte()) {
      case (?0) ?#equalInstalments;
      case (?1) ?#equalPrincipal;
      case (?2) ?#flat;
      case (?3) { let ?n = r.nat() else return null; ?#balloon({ finalPrincipal = n }) };
      case (_) null;
    }
  };

  public func rSchedule(r : C.Reader) : ?T.ScheduleTerms {
    let ?amortisation = rAmortisation(r) else return null;
    let ?instalments = r.nat() else return null;
    let ?every = rPeriod(r) else return null;
    let ?principalGrace = r.nat() else return null;
    let ?interestGrace = r.nat() else return null;
    let ?moratoriumDays = r.nat() else return null;
    ?{ amortisation; instalments; every; principalGrace; interestGrace; moratoriumDays }
  };

  public func rInstalments(r : C.Reader) : ?[T.Instalment] {
    let ?n = r.len16() else return null;
    let out = List.empty<T.Instalment>();
    var i = 0;
    while (i < n) {
      let ?number = r.nat() else return null;
      let ?dueDate = r.nat() else return null;
      let ?openingPrincipal = r.nat() else return null;
      let ?principal = r.nat() else return null;
      let ?interest = r.nat() else return null;
      let ?fees = r.nat() else return null;
      let ?closingPrincipal = r.nat() else return null;
      List.add(out, { number; dueDate; openingPrincipal; principal; interest; fees; closingPrincipal });
      i += 1;
    };
    ?List.toArray(out)
  };

  public func rTerms(r : C.Reader) : ?T.ProductTerms {
    let ?kind = rKind(r) else return null;
    let ?currency = r.text() else return null;
    let ?control = r.text() else return null;
    let ?roleCount = r.len16() else return null;
    let roles = List.empty<T.RoleMapping>();
    var i = 0;
    while (i < roleCount) {
      let ?role = rRole(r) else return null;
      let ?account = r.text() else return null;
      List.add(roles, { role; account });
      i += 1;
    };
    let interest = switch (r.byte()) {
      case (?0) null;
      case (?1) { let ?it = rInterest(r) else return null; ?it };
      case (_) return null;
    };
    let ?charges = rCharges(r) else return null;
    let ?overdraft = r.optNat() else return null;
    let ?minimumOperating = r.nat() else return null;
    let ?perOperation = r.optNat() else return null;
    let schedule = switch (r.byte()) {
      case (?0) null;
      case (?1) { let ?s = rSchedule(r) else return null; ?s };
      case (_) return null;
    };
    let ?bandCount = r.len16() else return null;
    let delinquency = List.empty<T.DelinquencyBand>();
    var b = 0;
    while (b < bandCount) {
      let ?name = r.text() else return null;
      let ?fromDays = r.nat() else return null;
      let ?toDays = r.optNat() else return null;
      List.add(delinquency, { name; fromDays; toDays });
      b += 1;
    };
    let ?ruleCount = r.len16() else return null;
    let provisioning = List.empty<T.ProvisionRule>();
    var k = 0;
    while (k < ruleCount) {
      let ?band = r.text() else return null;
      let ?stage = r.nat() else return null;
      let ?pct = rRate(r) else return null;
      List.add(provisioning, { band; stage; percentOfOutstanding = pct });
      k += 1;
    };
    let accounting = switch (r.byte()) { case (?0) #cash; case (?1) #accrualPeriodic; case (_) return null };
    let withholdingTax = switch (r.byte()) {
      case (?0) null;
      case (?1) { let ?x = rRate(r) else return null; ?x };
      case (_) return null;
    };
    let ?rounding = rRounding(r) else return null;
    let earlyRedemptionPenalty = switch (r.byte()) {
      case (?0) null;
      case (?1) { let ?x = rRate(r) else return null; ?x };
      case (_) return null;
    };
    let valueDateConvention : T.ValueDateConvention = switch (r.byte()) {
      case (?0) #sameDay; case (?1) #following; case (?2) #modifiedFollowing;
      case (?3) #preceding; case (?4) #modifiedPreceding; case (?5) #endOfMonth;
      case (_) return null;
    };
    ?{
      kind; currency; control;
      roles = List.toArray(roles);
      interest; charges;
      limits = { overdraft; minimumOperating; perOperation };
      schedule;
      delinquency = List.toArray(delinquency);
      provisioning = List.toArray(provisioning);
      accounting; withholdingTax; rounding; earlyRedemptionPenalty; valueDateConvention;
    }
  };

  public func readEvent(r : C.Reader) : ?T.ProductEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 {
        let ?id = r.text() else return null;
        let ?version = r.nat() else return null;
        let ?name = r.text() else return null;
        let ?terms = rTerms(r) else return null;
        ?#productRegistered({ id; version; name; terms })
      };
      case 0x02 {
        let ?id = r.text() else return null;
        let ?version = r.nat() else return null;
        let ?supersedes = r.nat() else return null;
        let ?name = r.text() else return null;
        let ?terms = rTerms(r) else return null;
        ?#productAmended({ id; version; supersedes; name; terms })
      };
      case 0x03 {
        let ?id = r.text() else return null;
        let ?version = r.nat() else return null;
        ?#productClosedToNewAccounts({ id; version })
      };
      case 0x04 {
        let ?product = r.text() else return null;
        let ?version = r.nat() else return null;
        let ?party = r.nat() else return null;
        let ?book = r.text() else return null;
        let ?identifier = r.text() else return null;
        let ?currency = r.text() else return null;
        let ?opened = r.nat() else return null;
        let ?maturity = r.optNat() else return null;
        let openingRate = switch (r.byte()) {
          case (?0) null;
          case (?1) { let ?x = rRate(r) else return null; ?x };
          case (_) return null;
        };
        let ?allocationOrder = rComponents(r) else return null;
        ?#accountOpened({ product; version; party; book; identifier; currency; opened; maturity; openingRate; allocationOrder })
      };
      case 0x05 {
        let ?account = r.nat() else return null;
        let ?to = rStatus(r) else return null;
        ?#accountStatusSet({ account; to })
      };
      case 0x06 {
        let ?account = r.nat() else return null;
        let ?from = r.nat() else return null;
        let ?to = r.nat() else return null;
        ?#accountMigrated({ account; from; to })
      };
      case 0x07 {
        let ?account = r.nat() else return null;
        let ?limit = r.nat() else return null;
        ?#facilityGranted({ account; limit })
      };
      case 0x08 {
        let ?account = r.nat() else return null;
        let ?charge = r.text() else return null;
        let ?amount = r.nat() else return null;
        let ?day = r.nat() else return null;
        ?#chargeApplied({ account; charge; amount; day })
      };
      case 0x09 {
        let ?account = r.nat() else return null;
        let ?charge = r.text() else return null;
        let ?occurrence = r.nat() else return null;
        let ?reversalOf = r.optNat() else return null;
        let ?reason = r.text() else return null;
        ?#chargeWaived({ account; charge; occurrence; reversalOf; reason })
      };
      case 0x0A {
        let ?product = r.text() else return null;
        let ?currency = r.text() else return null;
        let ?day = r.nat() else return null;
        let ?amount = r.nat() else return null;
        let ?accounts = r.nat() else return null;
        ?#accrualPosted({ product; currency; day; amount; accounts })
      };
      case 0x0B {
        let ?product = r.text() else return null;
        let ?currency = r.text() else return null;
        let ?from = r.nat() else return null;
        let ?to = r.nat() else return null;
        let ?examined = r.nat() else return null;
        let ?posted = r.nat() else return null;
        let ?zero = r.nat() else return null;
        let ?total = r.nat() else return null;
        let ?residueNumerator = r.nat() else return null;
        let ?residueDenominator = r.nat() else return null;
        let ?residueNegative = r.bool() else return null;
        ?#interestCapitalised({ product; currency; from; to; examined; posted; zero; total; residueNumerator; residueDenominator; residueNegative })
      };
      case 0x0C {
        let ?account = r.nat() else return null;
        let ?amount = r.nat() else return null;
        let ?day = r.nat() else return null;
        let ?schedule = rInstalments(r) else return null;
        ?#loanDisbursed({ account; amount; day; schedule })
      };
      case 0x0D {
        let ?account = r.nat() else return null;
        let ?version = r.nat() else return null;
        let ?effective = r.nat() else return null;
        let ?schedule = rInstalments(r) else return null;
        ?#loanRescheduled({ account; version; effective; schedule })
      };
      case 0x0E {
        let ?account = r.nat() else return null;
        let ?day = r.nat() else return null;
        let ?amount = r.nat() else return null;
        let ?applied = rAllocation(r) else return null;
        let ?overpayment = r.nat() else return null;
        ?#repaymentReceived({ account; day; amount; applied; overpayment })
      };
      case 0x0F {
        let ?account = r.nat() else return null;
        let band = switch (r.byte()) {
          case (?0) null;
          case (?1) { let ?b = r.text() else return null; ?b };
          case (_) return null;
        };
        let ?stage = r.optNat() else return null;
        let ?required = r.nat() else return null;
        let ?previous = r.nat() else return null;
        ?#provisionSet({ account; band; stage; required; previous })
      };
      case 0x10 {
        let ?account = r.nat() else return null;
        let ?components = rAllocation(r) else return null;
        let ?fromAllowance = r.nat() else return null;
        let ?toExpense = r.nat() else return null;
        let ?day = r.nat() else return null;
        ?#loanWrittenOff({ account; components; fromAllowance; toExpense; day })
      };
      case 0x11 {
        let ?account = r.nat() else return null;
        let ?amount = r.nat() else return null;
        let ?day = r.nat() else return null;
        ?#recoveryReceived({ account; amount; day })
      };
      case 0x12 {
        let ?account = r.nat() else return null;
        let ?day = r.nat() else return null;
        let ?entitled = r.nat() else return null;
        let ?recoverable = r.nat() else return null;
        let ?payable = r.nat() else return null;
        let ?early = r.bool() else return null;
        ?#termDepositRedeemed({ account; day; entitled; recoverable; payable; early })
      };
      case 0x13 {
        let ?till = r.text() else return null;
        let ?book = r.text() else return null;
        let ?currency = r.text() else return null;
        let ?holder = r.principal() else return null;
        let ?product = r.text() else return null;
        ?#tillOpened({ till; book; currency; holder; product })
      };
      case 0x14 {
        let ?till = r.text() else return null;
        let ?amount = r.nat() else return null;
        let ?day = r.nat() else return null;
        ?#tillAllocated({ till; amount; day })
      };
      case 0x15 {
        let ?till = r.text() else return null;
        let ?amount = r.nat() else return null;
        let ?day = r.nat() else return null;
        ?#tillReturned({ till; amount; day })
      };
      case 0x16 {
        let ?till = r.text() else return null;
        let ?declared = r.nat() else return null;
        let ?book = r.nat() else return null;
        let ?difference = rDifference(r) else return null;
        let ?day = r.nat() else return null;
        ?#tillSettled({ till; declared; book; difference; day })
      };
      case 0x17 { let ?till = r.text() else return null; ?#tillClosed({ till }) };
      case 0x18 { let ?account = r.nat() else return null; let ?rate = rRate(r) else return null; let ?effective = r.nat() else return null; ?#accountRateSet({ account; rate; effective }) };
      case 0x19 { let ?id = r.text() else return null; let ?version = r.nat() else return null; let ?supersedes = r.nat() else return null; let ?from = r.text() else return null; let ?to = r.text() else return null; let ?terms = rTerms(r) else return null; ?#productRedenominated({ id; version; supersedes; from; to; terms }) };
      case 0x1A { let ?account = r.nat() else return null; let ?version = r.nat() else return null; let ?from = r.text() else return null; let ?to = r.text() else return null; ?#accountRedenominated({ account; version; from; to }) };
      case 0x1B { let ?account = r.nat() else return null; let ?terms = rSchedule(r) else return null; let ?effective = r.nat() else return null; ?#scheduleTermsSet({ account; terms; effective }) };
      case _ null;
    }
  };
};
