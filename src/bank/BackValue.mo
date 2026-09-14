/// BackValue.mo: the correction for a back-dated posting, computed and never estimated.
///
/// A posting whose value date precedes the last accrual is the hard case in retail
/// banking, and it is the case an engine that *stores* accrued interest gets wrong:
/// the stored figure is now stale and there is no way to know by how much without
/// recomputing what it should have been.
///
/// Because accrual here is a fold over the journal's value-dated balances and no
/// per-account figure is stored, the *correct* accrued amount after a back-dated
/// posting is simply the fold re-evaluated. The only thing that is stale is what was
/// already **posted** as the daily aggregate accrual. So the correction is the
/// difference of two knowable quantities:
///
///     adjustment(product, ccy, from, to)
///       =  Σ over accounts of accrued(account, ccy, from, to)     -- recomputed now
///        −  Σ of the accrual postings already booked for that range -- read back
///
/// The second term is **read, not remembered**: each daily aggregate accrual is a
/// recorded `#accrualPosted` block carrying the product, the currency, the business
/// date and the amount, so the booked total for a range is a fold of the log rather
/// than a counter that could drift.
///
/// Sign is handled by side and never by a negative amount: an adjustment that reduces
/// accrued interest debits accrued-interest-payable and credits interest expense,
/// which is exactly the reversal of the accrual's own legs. An adjustment that
/// computes to zero produces no posting and is counted as examined.

import Nat "mo:core/Nat";
import Text "mo:core/Text";

import JT "mo:journal/JournalTypes";

import Posting "Posting";

module {

  public type Day = JT.Day;

  public type Direction = { #increase; #decrease; #unchanged };

  public func directionText(d : Direction) : Text {
    switch (d) { case (#increase) "increase"; case (#decrease) "decrease"; case (#unchanged) "unchanged" }
  };

  /// The figures of one correction. Both sides are reported, not just the difference,
  /// because "what it should be" and "what was booked" are each checkable and their
  /// difference is not.
  public type Adjustment = {
    product : Text;
    currency : JT.Currency;
    from : Day;
    to : Day;
    /// The fold re-evaluated now, over every account of the product.
    recomputed : Nat;
    /// The sum of the accrual postings already booked for the range, read from the log.
    booked : Nat;
    movement : Nat;
    direction : Direction;
    /// Accounts the fold examined, so a correction of zero is still evidence that
    /// something was looked at.
    examined : Nat;
  };

  public func compute(product : Text, currency : JT.Currency, from : Day, to : Day, recomputed : Nat, booked : Nat, examined : Nat) : Adjustment {
    let (movement, direction) =
      if (recomputed > booked) (recomputed - booked, #increase)
      else if (booked > recomputed) (booked - recomputed, #decrease)
      else (0, #unchanged);
    { product; currency; from; to; recomputed; booked; movement; direction; examined }
  };

  /// The legs of a correction. An increase posts what the accrual would have posted;
  /// a decrease posts the reverse of it. For a deposit product the accrual is
  /// expense against payable; for a credit product it is receivable against income;
  /// so the caller passes the same two accounts the accrual itself uses and the
  /// direction decides the sides.
  public func legs(
    accrualDebit : JT.AccountCode,
    accrualCredit : JT.AccountCode,
    currency : JT.Currency,
    a : Adjustment,
  ) : ?[JT.Leg] {
    switch (a.direction) {
      case (#unchanged) null;
      case (#increase) ?[
        Posting.leg(accrualDebit, null, #debit, currency, a.movement),
        Posting.leg(accrualCredit, null, #credit, currency, a.movement),
      ];
      case (#decrease) ?[
        Posting.leg(accrualCredit, null, #debit, currency, a.movement),
        Posting.leg(accrualDebit, null, #credit, currency, a.movement),
      ];
    }
  };

  /// The derived idempotency key of a correction: the product, the currency, the range
  /// and the block index of the back-dated posting that caused it. Re-running the
  /// correction is therefore a duplicate the journal rejects, not a second adjustment.
  public func key(product : Text, currency : JT.Currency, from : Day, to : Day, causedBy : Nat) : Blob {
    Posting.key("accrual-adjustment", [product, currency, Nat.toText(from), Nat.toText(to), Nat.toText(causedBy)])
  };
};
