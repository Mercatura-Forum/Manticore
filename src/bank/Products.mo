/// Products.mo: product validation and schedule generation, as pure functions.
///
/// Two jobs, both deliberately free of state so they can be tested against vectors
/// and against a reference system rather than against themselves:
///
///   * `validateTerms`; everything a product must satisfy before it can be
///     registered, including the role-to-account category check Fineract performs
///     per slot and refuses the product without;
///   * `schedule`; the repayment schedule for a credit product, row by row, as a
///     pure function of the terms, so it can be recomputed and compared against
///     Fineract's own generated schedule instalment by instalment.
///
/// Every figure is minor units and every intermediate is an exact rational
/// (`Interest.Signed`), so a schedule is reproducible to the unit. The amortisation
/// formula for equal instalments is the standard annuity
/// `EMI = P·i / (1 − (1+i)^−n)`, computed here without floating point: the factor
/// `(1+i)^n` is built by repeated exact multiplication of the rational `1+i`, and
/// the instalment is `P · i · (1+i)^n / ((1+i)^n − 1)`.

import Nat "mo:core/Nat";
import Text "mo:core/Text";
import List "mo:core/List";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";
import CivilDate "mo:journal/CivilDate";

import DC "DayCount";
import I "Interest";
import T "ProductTypes";

module {

  // ═══════════════════════════════════════════════════════
  //  VALIDATION
  // ═══════════════════════════════════════════════════════

  public func roleAccount(terms : T.ProductTerms, role : T.Role) : ?JT.AccountCode {
    for (m in terms.roles.vals()) { if (m.role == role) return ?m.account };
    null
  };

  /// Validate a rate chart: bands must start at zero, be contiguous, and the last
  /// must be open. A gap is a balance with no rate, and an overlap is two.
  public func validateChart(chart : T.RateChart, allowNegative : Bool) : ?Text {
    if (chart.bands.size() == 0) return ?"a chart with no bands has no rate";
    if (chart.bands.size() > T.MAX_RATE_BANDS) return ?"too many rate bands";
    if (chart.bands[0].from != 0) return ?"the first band must start at zero";
    var i = 0;
    while (i < chart.bands.size()) {
      let b = chart.bands[i];
      switch (I.validRate(b.rate)) { case (?r) return ?("band " # Nat.toText(i) # ": " # r); case null {} };
      if (b.rate.negative and not allowNegative) return ?("band " # Nat.toText(i) # " is negative and the product does not allow negative rates");
      switch (b.to) {
        case (?upper) {
          if (upper <= b.from) return ?("band " # Nat.toText(i) # " ends at or before it starts");
          if (i + 1 >= chart.bands.size()) return ?"the last band must be open-ended";
          if (chart.bands[i + 1].from != upper) return ?("band " # Nat.toText(i + 1) # " does not continue where band " # Nat.toText(i) # " ends");
        };
        case null { if (i + 1 != chart.bands.size()) return ?("band " # Nat.toText(i) # " is open but not last") };
      };
      i += 1;
    };
    null
  };

  /// The rate that applies at `value` (a balance, or a term in days).
  public func rateAt(chart : T.RateChart, value : Nat) : ?I.Rate {
    for (b in chart.bands.vals()) {
      let inBand = value >= b.from and (switch (b.to) { case (?u) value < u; case null true });
      if (inBand) return ?b.rate;
    };
    null
  };

  /// Everything a product must satisfy before registration. `js` is the journal, so
  /// the role-to-account checks are against the real chart of accounts.
  public func validateTerms(js : JCore.State, id : T.ProductId, terms : T.ProductTerms) : ?T.ProductError {
    let idBytes = Text.encodeUtf8(id).size();
    if (idBytes == 0 or idBytes > T.MAX_PRODUCT_ID_BYTES) return ?#InvalidTerms({ reason = "product id must be 1.." # Nat.toText(T.MAX_PRODUCT_ID_BYTES) # " bytes" });
    if (Text.encodeUtf8(terms.currency).size() != 3) return ?#InvalidTerms({ reason = "the currency must be a three-letter code" });
    if (JCore.currencyMinorUnits(js, terms.currency) == null) return ?#InvalidTerms({ reason = "currency " # terms.currency # " is not registered in the journal" });
    if (terms.roles.size() == 0 or terms.roles.size() > T.MAX_ROLES) return ?#InvalidTerms({ reason = "role map is empty or over the bound" });
    if (terms.charges.size() > T.MAX_CHARGES) return ?#InvalidTerms({ reason = "too many charges" });
    if (terms.delinquency.size() > T.MAX_DELINQUENCY_BANDS) return ?#InvalidTerms({ reason = "too many delinquency bands" });
    if (terms.provisioning.size() > T.MAX_PROVISION_RULES) return ?#InvalidTerms({ reason = "too many provision rules" });

    // no duplicate roles
    var i = 0;
    while (i < terms.roles.size()) {
      var j = i + 1;
      while (j < terms.roles.size()) {
        if (terms.roles[i].role == terms.roles[j].role) return ?#InvalidTerms({ reason = "duplicate role " # T.roleText(terms.roles[i].role) });
        j += 1;
      };
      i += 1;
    };

    // every required role is mapped, and every mapped account exists, is active and
    // carries the category the role requires. This is the check Fineract performs
    // per slot; a product that fails it is refused rather than registered.
    for (role in T.requiredRoles(terms.kind).vals()) {
      let ?acct = roleAccount(terms, role) else return ?#RoleUnmapped({ product = id; role = T.roleText(role) });
      let ?a = JCore.getAccount(js, acct) else return ?#RoleAccountUnknown({ role = T.roleText(role); account = acct });
      if (a.status == #closed) return ?#RoleAccountClosed({ role = T.roleText(role); account = acct });
      let want = T.requiredCategoryFor(terms.kind, role);
      if (a.category != want) {
        return ?#RoleAccountWrongCategory({ role = T.roleText(role); account = acct; expected = T.categoryText(want); actual = T.categoryText(a.category) });
      };
      // a header account is a rollup and cannot carry postings
      if (a.attributes.usage == #header) {
        return ?#InvalidTerms({ reason = "role " # T.roleText(role) # " maps to header account " # acct });
      };
    };

    // the control account is the principal account, so a customer balance and the
    // control total are the same number by construction
    let ?principalAccount = roleAccount(terms, #principal) else return ?#RoleUnmapped({ product = id; role = "principal" });
    if (not Text.equal(terms.control, principalAccount)) {
      return ?#ControlIsNotPrincipal({ control = terms.control; principal_ = principalAccount });
    };

    // interest
    switch (terms.interest) {
      case (?it) {
        switch (validateChart(it.chart, it.allowNegative)) { case (?r) return ?#InvalidRateChart({ reason = r }); case null {} };
        if (it.basis == #dailyBalance and not DC.supportsDailyBalance(it.convention)) {
          return ?#ConventionNotDailyBalance({ code = DC.isoCode(it.convention) });
        };
        if (it.posting == #atMaturity and terms.kind != #termDeposit and terms.kind != #recurringDeposit and terms.kind != #loan) {
          return ?#InvalidTerms({ reason = "only a term product or a loan may post interest at maturity" });
        };
      };
      case null {
        if (terms.kind == #savings or terms.kind == #termDeposit or terms.kind == #loan) {
          return ?#InvalidTerms({ reason = "a " # debug_show (terms.kind) # " product needs interest terms" });
        };
      };
    };

    // charges
    var c = 0;
    while (c < terms.charges.size()) {
      let ch = terms.charges[c];
      if (Text.encodeUtf8(ch.id).size() == 0) return ?#InvalidTerms({ reason = "a charge needs an id" });
      if (Text.encodeUtf8(ch.id).size() > T.MAX_CHARGE_ID_BYTES) return ?#InvalidTerms({ reason = "charge id " # ch.id # " is longer than " # Nat.toText(T.MAX_CHARGE_ID_BYTES) # " bytes" });
      if (not Text.equal(ch.currency, terms.currency)) return ?#CurrencyMismatch({ expected = terms.currency; actual = ch.currency });
      switch (ch.calculation) {
        case (#flat({ amount })) { if (amount == 0) return ?#InvalidTerms({ reason = "charge " # ch.id # " is zero" }) };
        case (#percentOfAmount({ rate })) { switch (I.validRate(rate)) { case (?r) return ?#InvalidTerms({ reason = "charge " # ch.id # ": " # r }); case null {} } };
        case (#percentOfInterest({ rate })) { switch (I.validRate(rate)) { case (?r) return ?#InvalidTerms({ reason = "charge " # ch.id # ": " # r }); case null {} } };
        case (#percentOfPrincipalOutstanding({ rate })) { switch (I.validRate(rate)) { case (?r) return ?#InvalidTerms({ reason = "charge " # ch.id # ": " # r }); case null {} } };
      };
      if (roleAccount(terms, ch.role) == null) return ?#RoleUnmapped({ product = id; role = T.roleText(ch.role) });
      var d = c + 1;
      while (d < terms.charges.size()) {
        if (Text.equal(ch.id, terms.charges[d].id)) return ?#InvalidTerms({ reason = "duplicate charge " # ch.id });
        d += 1;
      };
      c += 1;
    };

    // schedule
    switch (terms.schedule) {
      case (?sch) {
        if (sch.instalments == 0 or sch.instalments > T.MAX_INSTALMENTS) return ?#InvalidSchedule({ reason = "instalments out of range" });
        if (sch.principalGrace >= sch.instalments) return ?#InvalidSchedule({ reason = "the principal grace covers every instalment" });
        if (sch.interestGrace > sch.instalments) return ?#InvalidSchedule({ reason = "the interest grace exceeds the schedule" });
        if (sch.every == #atMaturity and sch.instalments != 1) return ?#InvalidSchedule({ reason = "an at-maturity schedule has one instalment" });
      };
      case null { if (terms.kind == #loan) return ?#ScheduleRequired({ product = id }) };
    };

    // delinquency bands must be contiguous from zero, like rate bands
    if (terms.delinquency.size() > 0) {
      if (terms.delinquency[0].fromDays != 0) return ?#InvalidTerms({ reason = "the first delinquency band must start at zero days" });
      var k = 0;
      while (k < terms.delinquency.size()) {
        switch (terms.delinquency[k].toDays) {
          case (?u) {
            if (u <= terms.delinquency[k].fromDays) return ?#InvalidTerms({ reason = "delinquency band " # terms.delinquency[k].name # " ends at or before it starts" });
            if (k + 1 >= terms.delinquency.size()) return ?#InvalidTerms({ reason = "the last delinquency band must be open-ended" });
            if (terms.delinquency[k + 1].fromDays != u) return ?#InvalidTerms({ reason = "delinquency bands are not contiguous at " # Nat.toText(u) });
          };
          case null { if (k + 1 != terms.delinquency.size()) return ?#InvalidTerms({ reason = "an open delinquency band is not last" }) };
        };
        k += 1;
      };
    };

    // every provision rule names a real band
    for (rule in terms.provisioning.vals()) {
      var found = false;
      for (b in terms.delinquency.vals()) { if (Text.equal(b.name, rule.band)) found := true };
      if (not found) return ?#InvalidTerms({ reason = "provision rule names unknown band " # rule.band });
      switch (I.validRate(rule.percentOfOutstanding)) { case (?r) return ?#InvalidTerms({ reason = "provision rule " # rule.band # ": " # r }); case null {} };
    };

    switch (terms.earlyRedemptionPenalty) {
      case (?rate) {
        switch (I.validRate(rate)) { case (?r) return ?#InvalidTerms({ reason = "early redemption penalty: " # r }); case null {} };
        if (rate.negative) return ?#InvalidTerms({ reason = "an early redemption penalty cannot be negative" });
        if (terms.kind != #termDeposit and terms.kind != #recurringDeposit) {
          return ?#InvalidTerms({ reason = "only a term product has an early redemption penalty" });
        };
        if (roleAccount(terms, #penaltyIncome) == null) return ?#RoleUnmapped({ product = id; role = "penaltyIncome" });
      };
      case null {};
    };

    // withholding tax needs a liability role to credit
    switch (terms.withholdingTax) {
      case (?rate) {
        switch (I.validRate(rate)) { case (?r) return ?#InvalidTerms({ reason = "withholding tax: " # r }); case null {} };
        if (roleAccount(terms, #taxPayable) == null) return ?#RoleUnmapped({ product = id; role = "taxPayable" });
      };
      case null {};
    };

    null
  };

  // ═══════════════════════════════════════════════════════
  //  DELINQUENCY AND PROVISIONING
  // ═══════════════════════════════════════════════════════

  /// The band an overdue age falls in. Bands are contiguous from zero with the last
  /// open, which validation guarantees, so an age always lands in exactly one.
  public func delinquencyBand(terms : T.ProductTerms, overdueDays : Nat) : ?Text {
    for (b in terms.delinquency.vals()) {
      let inBand = overdueDays >= b.fromDays and (switch (b.toDays) { case (?u) overdueDays < u; case null true });
      if (inBand) return ?b.name;
    };
    null
  };

  /// The provision on an outstanding amount for a band, exact. The percentage is a
  /// declared parameter: the engine computes and posts, and estimates nothing.
  public func provision(terms : T.ProductTerms, band : Text, outstanding : Nat) : ?I.Signed {
    for (r in terms.provisioning.vals()) {
      if (Text.equal(r.band, band)) {
        return ?{
          numerator = outstanding * r.percentOfOutstanding.numerator;
          denominator = r.percentOfOutstanding.denominator;
          negative = false;
        };
      };
    };
    null
  };

  // ═══════════════════════════════════════════════════════
  //  SCHEDULE GENERATION
  // ═══════════════════════════════════════════════════════

  /// Add `n` whole months to a day, clamping the day of month; the convention
  /// every instalment calendar uses, so a loan drawn on the 31st pays on the 30th
  /// in a thirty-day month and returns to the 31st afterwards.
  public func addMonths(d : CivilDate.Day, n : Nat) : CivilDate.Day {
    let (y, m, day) = CivilDate.toCivil(d);
    let total = (m - 1) + n;
    let y2 = y + total / 12;
    let m2 = total % 12 + 1;
    let maxDay = CivilDate.daysInMonth(y2, m2);
    let d2 = if (day > maxDay) maxDay else day;
    switch (CivilDate.fromCivil(y2, m2, d2)) { case (?x) x; case null d }
  };

  /// The first day of the calendar month that follows `skip` whole months after the
  /// month `d` falls in. With `skip = 0` this is the first of the next month, which
  /// is where a calendar-aligned compounding period first closes for a deposit
  /// opened mid-month.
  public func startOfMonthAfter(d : CivilDate.Day, skip : Nat) : CivilDate.Day {
    let (y, m, _) = CivilDate.toCivil(d);
    let total = (m - 1) + skip + 1;
    let y2 = y + total / 12;
    let m2 = total % 12 + 1;
    switch (CivilDate.fromCivil(y2, m2, 1)) { case (?x) x; case null d }
  };

  public func instalmentDate(start : CivilDate.Day, sch : T.ScheduleTerms, n : Nat) : CivilDate.Day {
    let base = start + sch.moratoriumDays;
    switch (sch.every) {
      case (#daily) base + n;
      case (#monthly) addMonths(base, n);
      case (#quarterly) addMonths(base, 3 * n);
      case (#semiAnnual) addMonths(base, 6 * n);
      case (#annual) addMonths(base, 12 * n);
      case (#atMaturity) addMonths(base, 12 * n);
    }
  };

  /// `(1 + i)^n` as an exact rational, where `i` is the periodic rate. A negative
  /// periodic rate of 100% or more would make `1 + i` non-positive, at which point
  /// the annuity has no meaning; that is reported as null rather than computed.
  public func onePlusIPow(rate : I.Rate, n : Nat) : ?{ numerator : Nat; denominator : Nat } {
    let baseNum = if (rate.negative) {
      if (rate.numerator >= rate.denominator) return null;
      rate.denominator - rate.numerator
    } else rate.denominator + rate.numerator;
    let baseDen = rate.denominator;
    var num : Nat = 1;
    var den : Nat = 1;
    var k = 0;
    while (k < n) { num *= baseNum; den *= baseDen; k += 1 };
    ?{ numerator = num; denominator = den }
  };

  /// The periodic rate for a schedule: the annual rate scaled to the instalment
  /// frequency, as an exact rational.
  public func periodicRate(annual : I.Rate, every : T.Period) : I.Rate {
    let perYear = switch (every) {
      case (#daily) 365; case (#monthly) 12; case (#quarterly) 4;
      case (#semiAnnual) 2; case (#annual) 1; case (#atMaturity) 1;
    };
    { numerator = annual.numerator; denominator = annual.denominator * perYear; negative = annual.negative }
  };

  /// Generate the repayment schedule. Pure: the same terms always produce the same
  /// rows, which is what makes an instalment-by-instalment check against a
  /// reference system meaningful.
  ///
  /// The last instalment absorbs any rounding residue in principal, so the closing
  /// principal is exactly zero and the sum of the principal column is exactly the
  /// amount advanced. That is the schedule equivalent of "no plug account".
  public func schedule(
    principal : Nat,
    annualRate : I.Rate,
    sch : T.ScheduleTerms,
    rounding : I.Rounding,
    start : CivilDate.Day,
  ) : { rows : [T.Instalment]; totalPrincipal : Nat; totalInterest : Nat } {
    let rows = List.empty<T.Instalment>();
    let i = periodicRate(annualRate, sch.every);
    var outstanding = principal;
    var totalInterest : Nat = 0;
    let payingInstalments = if (sch.instalments > sch.principalGrace) sch.instalments - sch.principalGrace else 1;

    // For equal instalments, the constant payment is
    //   P · i · (1+i)^n / ((1+i)^n − 1)
    // computed over the instalments that actually amortise principal.
    let emi : ?Nat = switch (sch.amortisation) {
      case (#equalInstalments) {
        if (i.numerator == 0) { ?((principal + payingInstalments - 1) / payingInstalments) }
        else switch (onePlusIPow(i, payingInstalments)) {
          case null null;
          case (?pow) {
            // P · |i| · (1+i)^n / |(1+i)^n − 1|, exact until the single rounding at
            // the end. With a negative rate both the rate and the bracket change
            // sign, so the payment stays positive and the magnitudes are enough.
            if (pow.numerator == pow.denominator) null
            else {
              let num = principal * i.numerator * pow.numerator;
              let gap = if (pow.numerator > pow.denominator) pow.numerator - pow.denominator
                        else pow.denominator - pow.numerator;
              let den = i.denominator * gap;
              ?(I.round({ numerator = num; denominator = den; negative = false }, rounding)).amount
            }
          };
        }
      };
      case (_) null;
    };

    var n = 0;
    while (n < sch.instalments) {
      let opening = outstanding;
      let due = instalmentDate(start, sch, n + 1);
      // interest on the outstanding balance for this period
      let interestExact : I.Signed = if (n < sch.interestGrace) I.zero() else {
        { numerator = opening * i.numerator; denominator = i.denominator; negative = i.negative }
      };
      let interest = (I.round(interestExact, rounding)).amount;
      let isLast = n + 1 == sch.instalments;
      let amortising = n >= sch.principalGrace;
      var principalPart : Nat = 0;
      if (amortising) {
        principalPart := switch (sch.amortisation) {
          case (#equalInstalments) {
            switch (emi) {
              case (?payment) { if (payment > interest) { let p = payment - interest; if (p > opening) opening else p } else 0 };
              case null 0;
            }
          };
          case (#equalPrincipal) { let p = principal / payingInstalments; if (p > opening) opening else p };
          case (#flat) { let p = principal / payingInstalments; if (p > opening) opening else p };
          case (#balloon({ finalPrincipal })) {
            if (isLast) opening
            else {
              let amortise = if (principal > finalPrincipal) principal - finalPrincipal else 0;
              let p = amortise / (if (payingInstalments > 1) payingInstalments - 1 else 1);
              if (p > opening) opening else p
            }
          };
        };
      };
      // the last instalment clears the balance exactly, so the principal column
      // sums to the advance and the closing balance is zero
      if (isLast) principalPart := opening;
      let closing = if (opening > principalPart) opening - principalPart else 0;
      List.add(rows, {
        number = n + 1; dueDate = due; openingPrincipal = opening;
        principal = principalPart; interest; fees = 0; closingPrincipal = closing;
      });
      totalInterest += interest;
      outstanding := closing;
      n += 1;
    };
    { rows = List.toArray(rows); totalPrincipal = principal; totalInterest }
  };

  /// Check a generated schedule against the invariants a schedule must satisfy, so
  /// a caller can assert rather than inspect.
  public func scheduleFaults(principal : Nat, rows : [T.Instalment]) : [Text] {
    let faults = List.empty<Text>();
    if (rows.size() == 0) { List.add(faults, "no rows"); return List.toArray(faults) };
    var sumPrincipal : Nat = 0;
    var i = 0;
    while (i < rows.size()) {
      let r = rows[i];
      if (r.number != i + 1) List.add(faults, "row " # Nat.toText(i) # " is numbered " # Nat.toText(r.number));
      if (i > 0 and r.openingPrincipal != rows[i - 1].closingPrincipal) List.add(faults, "row " # Nat.toText(r.number) # " does not open where the previous closed");
      if (i > 0 and r.dueDate <= rows[i - 1].dueDate) List.add(faults, "row " # Nat.toText(r.number) # " is not after the previous due date");
      if (r.openingPrincipal < r.principal) List.add(faults, "row " # Nat.toText(r.number) # " repays more principal than it owes");
      if (r.closingPrincipal != r.openingPrincipal - r.principal) List.add(faults, "row " # Nat.toText(r.number) # " does not close at opening less principal");
      sumPrincipal += r.principal;
      i += 1;
    };
    if (rows[0].openingPrincipal != principal) List.add(faults, "the first row does not open at the amount advanced");
    if (rows[rows.size() - 1].closingPrincipal != 0) List.add(faults, "the schedule does not close at zero");
    if (sumPrincipal != principal) List.add(faults, "the principal column sums to " # Nat.toText(sumPrincipal) # ", not " # Nat.toText(principal));
    List.toArray(faults)
  };
};
