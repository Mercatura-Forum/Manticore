/// Charges.mo; the fee and charge engine, as pure functions.
///
/// A charge definition is (calculation, timing, amount or rate, currency, income
/// role, waivable). Fineract's `m_charge` is the reference shape, and the
/// calculation and time types here are its type set: flat, percent of amount,
/// percent of interest, percent of outstanding principal; on activation, on
/// transaction, on a specified date, recurring on a period, overdue after a number
/// of days, on closure.
///
/// Two rules that matter more than the arithmetic:
///
///   * **A charge is applied by a posting, and only once per due occurrence.** The
///     occurrence is part of the derived idempotency key, so re-running a charge
///     run cannot charge twice.
///   * **A waiver is a decision, not a deletion.** Waiving a charge that has not
///     been applied produces no posting; waiving one that has produces a reversal
///     that names the original. There is no path that removes a posting.

import Nat "mo:core/Nat";
import Text "mo:core/Text";
import List "mo:core/List";

import JT "mo:journal/JournalTypes";
import CivilDate "mo:journal/CivilDate";

import T "ProductTypes";
import I "Interest";

module {

  /// What a charge is computed against. A charge whose calculation needs a figure
  /// the caller has not supplied is refused rather than computed from zero, so a
  /// misconfigured charge cannot silently become free.
  public type Base = {
    /// The transaction amount, for a charge on a transaction.
    amount : ?Nat;
    /// Interest credited or debited, for a percentage-of-interest charge.
    interest : ?Nat;
    /// Outstanding principal, for a percentage-of-outstanding charge.
    outstanding : ?Nat;
  };

  public func emptyBase() : Base { { amount = null; interest = null; outstanding = null } };

  public type ChargeFault = {
    #baseMissing : { charge : Text; needs : Text };
    #roundsToZero : { charge : Text };
  };

  /// The exact amount of a charge, before rounding.
  public func exact(c : T.Charge, base : Base) : { #ok : I.Signed; #err : ChargeFault } {
    switch (c.calculation) {
      case (#flat({ amount })) #ok({ numerator = amount; denominator = 1; negative = false });
      case (#percentOfAmount({ rate })) {
        switch (base.amount) {
          case (?a) #ok({ numerator = a * rate.numerator; denominator = rate.denominator; negative = rate.negative });
          case null #err(#baseMissing({ charge = c.id; needs = "transaction amount" }));
        }
      };
      case (#percentOfInterest({ rate })) {
        switch (base.interest) {
          case (?x) #ok({ numerator = x * rate.numerator; denominator = rate.denominator; negative = rate.negative });
          case null #err(#baseMissing({ charge = c.id; needs = "interest" }));
        }
      };
      case (#percentOfPrincipalOutstanding({ rate })) {
        switch (base.outstanding) {
          case (?x) #ok({ numerator = x * rate.numerator; denominator = rate.denominator; negative = rate.negative });
          case null #err(#baseMissing({ charge = c.id; needs = "outstanding principal" }));
        }
      };
    }
  };

  /// The amount actually charged: exact, then rounded by the product's declared
  /// mode. A charge that rounds to zero is **not** posted; the journal refuses a
  /// zero leg, and a posting that moves nothing is the fake-green pattern.
  public func amountOf(c : T.Charge, base : Base, mode : I.Rounding) : { #ok : { amount : Nat; exact_ : I.Signed }; #err : ChargeFault } {
    switch (exact(c, base)) {
      case (#err(e)) #err(e);
      case (#ok(x)) {
        let r = I.round(x, mode);
        if (r.amount == 0) #err(#roundsToZero({ charge = c.id })) else #ok({ amount = r.amount; exact_ = x })
      };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  WHEN A CHARGE FALLS DUE
  // ═══════════════════════════════════════════════════════

  /// Whether a charge of this timing is due on `day`, given the account's opening
  /// day, closing day and the age of its oldest overdue instalment. Pure, so the
  /// due dates of a charge over a window can be enumerated and compared against a
  /// reference system's own schedule rather than inspected by hand.
  public func dueOn(
    timing : T.ChargeTiming,
    day : T.Day,
    opened : T.Day,
    closed : ?T.Day,
    overdueDays : Nat,
  ) : Bool {
    switch (timing) {
      case (#onActivation) day == opened;
      case (#onTransaction) false;          // driven by the transaction, not the calendar
      case (#onDate({ day = d })) day == d;
      case (#recurring({ every })) {
        if (day < opened) false
        else switch (every) {
          case (#daily) true;
          case (#atMaturity) (switch (closed) { case (?c) day == c; case null false });
          case (_) onAnniversary(opened, day, T.periodMonths(every));
        }
      };
      case (#overdue({ afterDays })) overdueDays > 0 and overdueDays == afterDays;
      case (#onClosure) (switch (closed) { case (?c) day == c; case null false });
    }
  };

  /// Is `day` a whole number of `months`-month steps after `from`, on the same day
  /// of month (clamped at a short month end, which is the convention every fee
  /// calendar uses)?
  public func onAnniversary(from : T.Day, day : T.Day, months : Nat) : Bool {
    if (months == 0 or day <= from) return false;
    let (fy, fm, fd) = CivilDate.toCivil(from);
    let (dy, dm, dd) = CivilDate.toCivil(day);
    let elapsed = (dy * 12 + (dm - 1)) - (fy * 12 + (fm - 1));
    if (elapsed == 0 or elapsed % months != 0) return false;
    let maxDay = CivilDate.daysInMonth(dy, dm);
    let want = if (fd > maxDay) maxDay else fd;
    dd == want
  };

  /// Every day in `[from, to)` on which this charge falls due. Bounded by the
  /// window, so a caller cannot accidentally enumerate a century.
  public func dueDays(
    timing : T.ChargeTiming,
    from : T.Day,
    to : T.Day,
    opened : T.Day,
    closed : ?T.Day,
    overdueDaysOn : (T.Day) -> Nat,
  ) : [T.Day] {
    let out = List.empty<T.Day>();
    if (to <= from) return [];
    var cursor = from;
    while (cursor < to) {
      if (dueOn(timing, cursor, opened, closed, overdueDaysOn(cursor))) List.add(out, cursor);
      cursor += 1;
    };
    List.toArray(out)
  };

  // ═══════════════════════════════════════════════════════
  //  THE CHARGE SET OF A PRODUCT
  // ═══════════════════════════════════════════════════════

  public func find(terms : T.ProductTerms, id : Text) : ?T.Charge {
    for (c in terms.charges.vals()) { if (Text.equal(c.id, id)) return ?c };
    null
  };

  /// The charges of a product that apply to a transaction, in declaration order so
  /// the sequence of postings is a function of the product and not of a map's
  /// iteration order.
  public func onTransaction(terms : T.ProductTerms) : [T.Charge] {
    let out = List.empty<T.Charge>();
    for (c in terms.charges.vals()) { if (c.timing == #onTransaction) List.add(out, c) };
    List.toArray(out)
  };

  public func onActivation(terms : T.ProductTerms) : [T.Charge] {
    let out = List.empty<T.Charge>();
    for (c in terms.charges.vals()) { if (c.timing == #onActivation) List.add(out, c) };
    List.toArray(out)
  };

  public func onClosure(terms : T.ProductTerms) : [T.Charge] {
    let out = List.empty<T.Charge>();
    for (c in terms.charges.vals()) { if (c.timing == #onClosure) List.add(out, c) };
    List.toArray(out)
  };

  /// A charge's income role resolved to its account, which registration has
  /// already proved exists with the right category.
  public func incomeAccount(terms : T.ProductTerms, c : T.Charge) : ?JT.AccountCode {
    for (m in terms.roles.vals()) { if (m.role == c.role) return ?m.account };
    null
  };
};
