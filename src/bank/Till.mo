/// Till.mo — cashier drawers, and why a difference can never be absorbed.
///
/// A till is a cash account with a constraint: it is an asset sub-ledger under the
/// vault's control account, held by one named cashier, and it may not go credit —
/// a drawer cannot hold negative cash. That constraint is the journal's own numeric
/// balance limit on the till's triple, so it is enforced at admission and not by
/// this module.
///
/// The operation that matters is settlement. At the end of a shift the cashier
/// declares what is physically in the drawer. If the declaration does not equal the
/// drawer's book balance, the difference is posted to **suspense** with the cashier
/// named, and the drawer is returned to its book position. There is no code path
/// that adjusts the till's balance to match the count, which is the only way to
/// make a silent absorption impossible: the suspense leg is what makes the posting
/// balance, so a difference that is not posted is a posting that does not admit.
///
/// This is the shape every teller system ends up with (Fineract's teller/cashier
/// module allocates cash to a cashier and settles it back the same way), and the
/// reason to state it here is that the over/short figure is the single most
/// frequently suppressed number in retail branch accounting.

import Nat "mo:core/Nat";
import Text "mo:core/Text";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";

import Posting "Posting";

module {

  public type TillFault = {
    #notAllocated : { till : Text };
    #insufficientCash : { held : Nat; requested : Nat };
    #declarationImplausible : { declared : Nat; book : Nat; tolerance : Nat };
    #notTheHolder;
  };

  /// The difference between what a cashier counted and what the books say, as a
  /// signed figure with the direction named rather than inferred from a sign.
  public type Difference = { #balanced; #over : Nat; #short : Nat };

  public func difference(declared : Nat, book : Nat) : Difference {
    if (declared == book) #balanced
    else if (declared > book) #over(declared - book)
    else #short(book - declared)
  };

  public func differenceText(d : Difference) : Text {
    switch (d) {
      case (#balanced) "balanced";
      case (#over(n)) "over by " # Nat.toText(n);
      case (#short(n)) "short by " # Nat.toText(n);
    }
  };

  public func differenceAmount(d : Difference) : Nat {
    switch (d) { case (#balanced) 0; case (#over(n)) n; case (#short(n)) n }
  };

  /// The book balance of a till: an asset sub-ledger, so its balance is debits less
  /// credits, and it can never be credit by the journal limit the till is opened
  /// with.
  public func bookBalance(js : JCore.State, control : JT.AccountCode, sub : JT.SubledgerKey, ccy : JT.Currency, asOf : JT.Day) : Nat {
    let b = Posting.accountBalanceOn(js, control, sub, ccy, #debit, asOf);
    if (b.overdrawn) 0 else b.net
  };

  /// The legs of a settlement. The till is brought to the declared figure and the
  /// difference goes to suspense; when the count agrees there is no posting at all,
  /// which is reported as `null` rather than as an empty posting.
  ///
  /// A till settled **short** means the drawer holds less than the books say: the
  /// till is credited the shortfall and suspense is debited, so the loss sits in
  /// suspense under the cashier's name until it is investigated. A till **over** is
  /// the mirror.
  public func settlementLegs(
    tillControl : JT.AccountCode,
    tillSub : JT.SubledgerKey,
    suspense : JT.AccountCode,
    ccy : JT.Currency,
    d : Difference,
  ) : ?[JT.Leg] {
    switch (d) {
      case (#balanced) null;
      case (#short(n)) ?[
        Posting.leg(tillControl, ?tillSub, #credit, ccy, n),
        Posting.leg(suspense, null, #debit, ccy, n),
      ];
      case (#over(n)) ?[
        Posting.leg(tillControl, ?tillSub, #debit, ccy, n),
        Posting.leg(suspense, null, #credit, ccy, n),
      ];
    }
  };

  /// Cash moving from the vault to a cashier's drawer, and back. Both directions
  /// are postings between two sub-ledgers of the same control account, so the
  /// bank's total cash does not change when a drawer is loaded — which is the
  /// check a branch reconciliation actually runs.
  public func allocationLegs(
    control : JT.AccountCode,
    vaultSub : JT.SubledgerKey,
    tillSub : JT.SubledgerKey,
    ccy : JT.Currency,
    amount : Nat,
  ) : [JT.Leg] {
    [
      Posting.leg(control, ?tillSub, #debit, ccy, amount),
      Posting.leg(control, ?vaultSub, #credit, ccy, amount),
    ]
  };

  public func returnLegs(
    control : JT.AccountCode,
    vaultSub : JT.SubledgerKey,
    tillSub : JT.SubledgerKey,
    ccy : JT.Currency,
    amount : Nat,
  ) : [JT.Leg] {
    [
      Posting.leg(control, ?vaultSub, #debit, ccy, amount),
      Posting.leg(control, ?tillSub, #credit, ccy, amount),
    ]
  };

  /// The sub-ledger key of the vault, which is a till with no holder. Derived the
  /// same way as every other account key so there is nothing special about it but
  /// its name.
  public func vaultSubledger(book : Text, ccy : JT.Currency) : JT.SubledgerKey {
    Posting.subledgerOf("vault/" # book # "/" # ccy)
  };

  public func tillSubledger(till : Text) : JT.SubledgerKey { Posting.subledgerOf("till/" # till) };
};
