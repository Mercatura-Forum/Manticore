/// Limits.mo — facilities, overdrafts and per-operation ceilings.
///
/// The important decision here is what this module does **not** do. An overdraft
/// facility is not checked by this layer before a posting is submitted. It is
/// expressed as the journal's own numeric balance limit on the customer's
/// (control account, sub-ledger, currency) triple — `#debitsNotExceedCreditsPlus`
/// for a deposit-side account — so the limit is enforced at admission by the same
/// engine that enforces per-currency balance, over posted **and** pending amounts,
/// and a direct poster cannot bypass it: the limit is engine-enforced rather than
/// checked by the application.
///
/// Modelling the facility as a credit to the customer's sub-ledger instead was
/// considered and rejected: it would inflate the customer's reported balance by
/// the undrawn facility, which is a misstatement whatever the internal bookkeeping.
///
/// What remains for this module is the arithmetic around the limit: translating a
/// product's declared limits into the journal event, reading back what headroom an
/// account has, and the two checks that are genuinely product-level rather than
/// ledger-level — the minimum operating balance a withdrawal must leave behind,
/// and the largest single movement a product permits.

import Nat "mo:core/Nat";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";

import T "ProductTypes";
import Posting "Posting";

module {

  public type LimitFault = {
    #overPerOperation : { limit : Nat; amount : Nat };
    #belowMinimumOperating : { minimum : Nat; wouldLeave : Nat };
    #wouldExceedFacility : { facility : Nat; headroom : Nat; amount : Nat };
    #noFacility : { amount : Nat; available : Nat };
  };

  /// The journal balance limit a product's declared limits imply for one customer
  /// sub-ledger. A deposit-side account (normal side credit) may go debit by at
  /// most the facility; an asset-side account (a loan) may go credit by at most
  /// zero, because an over-repayment is a refund and not a credit balance.
  public func journalLimit(normalSide : JT.Side, overdraft : ?Nat) : JT.BalanceLimit {
    switch (normalSide, overdraft) {
      case (#credit, ?n) #debitsNotExceedCreditsPlus(n);
      case (#credit, null) #debitsNotExceedCreditsPlus(0);
      case (#debit, ?n) #creditsNotExceedDebitsPlus(n);
      case (#debit, null) #creditsNotExceedDebitsPlus(0);
    }
  };

  /// The facility recorded for an account, read back from the journal rather than
  /// from product state, so what this function reports is what the engine will
  /// enforce.
  public func facilityOf(js : JCore.State, control : JT.AccountCode, sub : JT.SubledgerKey, ccy : JT.Currency) : Nat {
    switch (JCore.balanceLimit(js, control, ?sub, ccy)) {
      case (?#debitsNotExceedCreditsPlus(n)) n;
      case (?#creditsNotExceedDebitsPlus(n)) n;
      case (?#none) 0;
      case null 0;
    }
  };

  /// How much more an account can be drawn down before the engine refuses: the
  /// balance on its own side plus the facility, measured **including pending**
  /// amounts so a reservation already taken is not available twice.
  public func headroom(
    js : JCore.State,
    control : JT.AccountCode,
    sub : JT.SubledgerKey,
    ccy : JT.Currency,
    normalSide : JT.Side,
  ) : { available : Nat; facility : Nat; net : Nat; overdrawn : Bool } {
    let b = JCore.balance(js, control, ?sub, ccy);
    let facility = facilityOf(js, control, sub, ccy);
    switch (normalSide) {
      case (#credit) {
        // headroom = credits − (debits + pending debits) + facility
        let used = b.debitsPosted + b.debitsPending;
        let available = if (b.creditsPosted + facility >= used) b.creditsPosted + facility - used else 0;
        let net = if (b.creditsPosted >= b.debitsPosted) b.creditsPosted - b.debitsPosted else b.debitsPosted - b.creditsPosted;
        { available; facility; net; overdrawn = b.debitsPosted > b.creditsPosted }
      };
      case (#debit) {
        let used = b.creditsPosted + b.creditsPending;
        let available = if (b.debitsPosted + facility >= used) b.debitsPosted + facility - used else 0;
        let net = if (b.debitsPosted >= b.creditsPosted) b.debitsPosted - b.creditsPosted else b.creditsPosted - b.debitsPosted;
        { available; facility; net; overdrawn = b.creditsPosted > b.debitsPosted }
      };
    }
  };

  /// The product-level checks on a withdrawal, which the engine cannot make
  /// because they are terms and not invariants: the largest single movement, and
  /// the balance that must remain behind. Returns the first failure.
  ///
  /// The facility itself is deliberately *not* pre-checked here — `wouldExceed`
  /// below exists for a caller that wants to report the headroom in its own error
  /// rather than let admission do it, and the engine check happens regardless.
  public func checkWithdrawal(limits : T.Limits, amount : Nat, balanceAfter : Nat, overdrawnAfter : Bool) : ?LimitFault {
    switch (limits.perOperation) {
      case (?cap) { if (amount > cap) return ?#overPerOperation({ limit = cap; amount }) };
      case null {};
    };
    if (limits.minimumOperating > 0) {
      if (overdrawnAfter) return ?#belowMinimumOperating({ minimum = limits.minimumOperating; wouldLeave = 0 });
      if (balanceAfter < limits.minimumOperating) {
        return ?#belowMinimumOperating({ minimum = limits.minimumOperating; wouldLeave = balanceAfter });
      };
    };
    null
  };

  /// Would this drawing exceed the recorded facility? Reported so a caller can
  /// name the headroom; the engine refuses it in any case.
  public func wouldExceed(
    js : JCore.State,
    control : JT.AccountCode,
    sub : JT.SubledgerKey,
    ccy : JT.Currency,
    normalSide : JT.Side,
    amount : Nat,
  ) : ?LimitFault {
    let h = headroom(js, control, sub, ccy, normalSide);
    if (amount <= h.available) return null;
    if (h.facility == 0) ?#noFacility({ amount; available = h.available })
    else ?#wouldExceedFacility({ facility = h.facility; headroom = h.available; amount })
  };

  /// The balance an account would be left with after a movement of `amount` out of
  /// it, on its own side, and whether that leaves it overdrawn. Value-dated on the
  /// day asked about, because that is the balance the terms speak of.
  public func after(
    js : JCore.State,
    control : JT.AccountCode,
    sub : JT.SubledgerKey,
    ccy : JT.Currency,
    normalSide : JT.Side,
    asOf : JT.Day,
    amount : Nat,
  ) : { balance : Nat; overdrawn : Bool } {
    let b = Posting.accountBalanceOn(js, control, sub, ccy, normalSide, asOf);
    if (b.overdrawn) { { balance = b.net + amount; overdrawn = true } }
    else if (b.net >= amount) { { balance = b.net - amount; overdrawn = false } }
    else { { balance = amount - b.net; overdrawn = true } }
  };

  public func faultText(f : LimitFault) : Text {
    switch (f) {
      case (#overPerOperation(x)) "over the per-operation limit of " # Nat.toText(x.limit);
      case (#belowMinimumOperating(x)) "would leave " # Nat.toText(x.wouldLeave) # " against a minimum of " # Nat.toText(x.minimum);
      case (#wouldExceedFacility(x)) "would exceed the facility of " # Nat.toText(x.facility) # " (headroom " # Nat.toText(x.headroom) # ")";
      case (#noFacility(x)) "no facility: " # Nat.toText(x.amount) # " against " # Nat.toText(x.available) # " available";
    }
  };
};
