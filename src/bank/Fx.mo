/// Fx.mo: foreign currency, inside the journal's per-currency invariant.
///
/// The journal balances **per currency** and never converts: a two-leg USD/EGP
/// posting is `#Unbalanced`, and the correct form is four legs through a position
/// account. That is already the right structure for bank FX accounting, and
/// revaluation falls out of it without touching the invariant.
///
/// For each foreign currency C the books carry a pair:
///
///   * the **position** in C; how much of C the bank is long or short;
///   * the **position equivalent** in the functional currency; what that position
///     was booked at.
///
/// Every cross-currency movement posts four legs: the two business legs plus the
/// two position legs, so both halves move at the deal rate. At period end
///
///     unrealised(C) = position(C) × rate(C, closing date) − positionEquivalent(C)
///
/// and the difference is posted **entirely in the functional currency**: the
/// unrealised gain or loss against the position-equivalent account. No leg in
/// currency C is written, so the per-currency invariant is untouched and the
/// foreign-currency position is not disturbed by a revaluation; which is the
/// property that keeps the next deal's arithmetic correct.
///
/// A rate is declared data, recorded as a bank event. The engine never fetches a
/// rate, never interpolates one, and never reuses an earlier day's silently: a
/// revaluation for a currency with no rate recorded for the closing date is a typed
/// refusal. IAS 21 is the authority for what is revalued; monetary items at the
/// closing rate; and whether an account is monetary is declared, not guessed.

import Nat "mo:core/Nat";
import Text "mo:core/Text";
import List "mo:core/List";

import JT "mo:journal/JournalTypes";

import Posting "Posting";
import I "Interest";

module {

  public type Day = JT.Day;

  /// A rate as an exact ratio of minor units: `numerator` minor units of the
  /// functional currency per `denominator` minor units of the foreign currency.
  /// Expressed as a ratio rather than a decimal because every figure downstream is
  /// exact, and because a rate with a scale is a rate with a rounding question
  /// nobody answered.
  public type Rate = {
    currency : JT.Currency;          // the foreign currency
    functional : JT.Currency;        // the functional currency the rate is quoted into
    numerator : Nat;                 // minor units of `functional`
    denominator : Nat;               // minor units of `currency`
    asOf : Day;
    source : Text;
  };

  public func validateRate(r : Rate) : ?Text {
    if (r.denominator == 0) return ?"a rate needs a non-zero denominator";
    if (r.numerator == 0) return ?"a rate of zero is not a rate";
    if (Text.encodeUtf8(r.currency).size() != 3) return ?"the foreign currency must be a three-letter code";
    if (Text.encodeUtf8(r.functional).size() != 3) return ?"the functional currency must be a three-letter code";
    if (Text.equal(r.currency, r.functional)) return ?"a currency has no rate against itself";
    if (Text.encodeUtf8(r.source).size() == 0) return ?"a rate records where it came from";
    if (Text.encodeUtf8(r.source).size() > MAX_SOURCE_BYTES) return ?"the source exceeds the bound";
    null
  };

  public let MAX_SOURCE_BYTES : Nat = 128;

  /// The functional-currency equivalent of a foreign position at a rate, exact.
  public func equivalentOf(position : Nat, r : Rate) : I.Signed {
    { numerator = position * r.numerator; denominator = r.denominator; negative = false }
  };

  /// The accounts a currency's pair lives in. Declared per currency as a recorded
  /// event, so which account carries which half is answerable by replay rather than
  /// by convention.
  public type PositionPair = {
    currency : JT.Currency;
    /// Holds the balance **in the foreign currency**: how much of C the bank holds.
    position : JT.AccountCode;
    /// Holds the **functional-currency** amount that position was booked at.
    equivalent : JT.AccountCode;
    /// Where an unrealised revaluation difference goes, in the functional currency.
    unrealised : JT.AccountCode;
    /// Where a realised difference goes when a position is closed.
    realised : JT.AccountCode;
    /// IAS 21: a monetary item is revalued at the closing rate; a non-monetary one
    /// is carried at its historic rate and is not revalued at all.
    monetary : Bool;
  };

  public type Fault = {
    #noRate : { currency : JT.Currency; asOf : Day };
    #staleRate : { currency : JT.Currency; asOf : Day; recorded : Day };
    #notMonetary : { currency : JT.Currency };
    #sameCurrency : { currency : JT.Currency };
    #functionalMismatch : { expected : JT.Currency; actual : JT.Currency };
    #nothingToRevalue : { currency : JT.Currency };
  };

  /// The revaluation of one currency's position, as figures. `movement` is what must
  /// be posted and `direction` says which way; a movement of zero is reported as
  /// `#unchanged` and produces no posting, because the journal refuses a zero leg.
  public type Revaluation = {
    currency : JT.Currency;
    position : Nat;
    positionSide : JT.Side;
    equivalent : Nat;
    rate : Rate;
    /// `position × rate`, exact, before rounding.
    revaluedExact : I.Signed;
    revalued : Nat;
    movement : Nat;
    direction : { #gain; #loss; #unchanged };
  };

  /// Compute a revaluation. `position` is the foreign-currency balance on the side
  /// the position account's own normal side, and `equivalent` the functional-currency
  /// balance of its pair. Both are read from the journal; nothing here is stored.
  public func revalue(
    pair : PositionPair,
    position : Nat,
    positionSide : JT.Side,
    equivalent : Nat,
    rate : Rate,
    rounding : I.Rounding,
  ) : { #ok : Revaluation; #err : Fault } {
    if (not pair.monetary) return #err(#notMonetary({ currency = pair.currency }));
    if (not Text.equal(pair.currency, rate.currency)) {
      return #err(#functionalMismatch({ expected = pair.currency; actual = rate.currency }));
    };
    let exact = equivalentOf(position, rate);
    let revalued = (I.round(exact, rounding)).amount;
    let (movement, direction) =
      if (revalued > equivalent) (revalued - equivalent, #gain)
      else if (equivalent > revalued) (equivalent - revalued, #loss)
      else (0, #unchanged);
    #ok({
      currency = pair.currency; position; positionSide; equivalent; rate;
      revaluedExact = exact; revalued; movement; direction;
    })
  };

  /// The legs of a revaluation: entirely in the functional currency, and exactly two
  /// of them. A gain raises the position equivalent and credits unrealised gain; a
  /// loss is the mirror. There is deliberately no leg in the foreign currency, which
  /// is what leaves the position itself untouched.
  public func revaluationLegs(pair : PositionPair, functional : JT.Currency, r : Revaluation) : ?[JT.Leg] {
    switch (r.direction) {
      case (#unchanged) null;
      case (#gain) ?[
        Posting.leg(pair.equivalent, null, #debit, functional, r.movement),
        Posting.leg(pair.unrealised, null, #credit, functional, r.movement),
      ];
      case (#loss) ?[
        Posting.leg(pair.unrealised, null, #debit, functional, r.movement),
        Posting.leg(pair.equivalent, null, #credit, functional, r.movement),
      ];
    }
  };

  // ═══════════════════════════════════════════════════════
  //  A CROSS-CURRENCY MOVEMENT: FOUR LEGS, ONE DEAL RATE
  // ═══════════════════════════════════════════════════════

  /// A cross-currency deal: `sellAmount` of `sell` leaves, `buyAmount` of `buy`
  /// arrives, at the recorded rate. Both currencies balance on their own, because
  /// each is closed through its position pair; which is the journal's invariant and
  /// also the reason a deal and a revaluation can never disagree about what a
  /// position is worth.
  public type Deal = {
    sell : JT.Currency;
    sellAmount : Nat;
    sellAccount : JT.AccountCode;          // where the sold currency leaves from
    sellSubledger : ?JT.SubledgerKey;
    buy : JT.Currency;
    buyAmount : Nat;
    buyAccount : JT.AccountCode;           // where the bought currency arrives
    buySubledger : ?JT.SubledgerKey;
  };

  /// The four legs of a cross-currency movement where one side is the functional
  /// currency, with the **directions** that make the pair mean what it says.
  ///
  /// The two pair accounts are contra accounts that together carry the open position:
  /// the position holds the net amount of C and the equivalent holds what that net
  /// cost in the functional currency. Buying 1,000 USD for 48,000 EGP is
  ///
  ///     debit  the receiving account     1,000 USD    (the currency arrives)
  ///     credit the position             1,000 USD    (the position is now long USD)
  ///     debit  the position equivalent 48,000 EGP    (what it cost)
  ///     credit the funding account     48,000 EGP    (the currency leaves)
  ///
  /// so USD balances within itself, EGP balances within itself, and the pair's two
  /// balances offset exactly at the deal rate. At a new rate their imbalance is the
  /// unrealised result, which is what `revalue` computes and posts; in the
  /// functional currency only, leaving the position untouched.
  ///
  /// Getting these four directions wrong still balances per currency, which is why
  /// the battery asserts the direction of each leg and not only that the posting
  /// balances.
  public func dealLegs(pair : PositionPair, functional : JT.Currency, deal : Deal) : { #ok : [JT.Leg]; #err : Fault } {
    if (Text.equal(deal.sell, deal.buy)) return #err(#sameCurrency({ currency = deal.sell }));
    let buyingForeign = Text.equal(deal.sell, functional) and Text.equal(deal.buy, pair.currency);
    let sellingForeign = Text.equal(deal.buy, functional) and Text.equal(deal.sell, pair.currency);
    if (not buyingForeign and not sellingForeign) {
      return #err(#functionalMismatch({ expected = functional; actual = deal.sell # "/" # deal.buy }));
    };
    if (buyingForeign) {
      #ok([
        // the foreign currency arrives, and the position becomes long it
        Posting.leg(deal.buyAccount, deal.buySubledger, #debit, pair.currency, deal.buyAmount),
        Posting.leg(pair.position, null, #credit, pair.currency, deal.buyAmount),
        // the functional currency leaves, and the equivalent records what it cost
        Posting.leg(pair.equivalent, null, #debit, functional, deal.sellAmount),
        Posting.leg(deal.sellAccount, deal.sellSubledger, #credit, functional, deal.sellAmount),
      ])
    } else {
      #ok([
        // the foreign currency leaves, closing the position by that much
        Posting.leg(pair.position, null, #debit, pair.currency, deal.sellAmount),
        Posting.leg(deal.sellAccount, deal.sellSubledger, #credit, pair.currency, deal.sellAmount),
        // the functional currency arrives, and the equivalent is relieved of its cost
        Posting.leg(deal.buyAccount, deal.buySubledger, #debit, functional, deal.buyAmount),
        Posting.leg(pair.equivalent, null, #credit, functional, deal.buyAmount),
      ])
    }
  };

  /// Each currency's legs must sum to zero on their own; that is the journal's
  /// invariant, and a four-leg deal satisfies it only if the pair is used correctly.
  /// This proves it per currency rather than leaving it to a careful reading, and the
  /// battery calls it on every generated deal.
  public func balancesPerCurrency(legs : [JT.Leg]) : Bool {
    let seen = List.empty<JT.Currency>();
    for (l in legs.vals()) {
      var known = false;
      for (c in List.values(seen)) { if (Text.equal(c, l.currency)) known := true };
      if (not known) List.add(seen, l.currency);
    };
    for (c in List.values(seen)) {
      var d = 0;
      var cr = 0;
      for (l in legs.vals()) {
        if (Text.equal(l.currency, c)) {
          switch (l.side) { case (#debit) d += l.amount; case (#credit) cr += l.amount };
        };
      };
      if (d != cr or d == 0) return false;
    };
    List.size(seen) > 0
  };

  /// The functional-currency amount a deal's foreign leg is worth at a rate, exact
  /// and then rounded; the figure a quote states and the posting uses.
  public func convert(amount : Nat, r : Rate, rounding : I.Rounding) : { amount : Nat; exact_ : I.Signed } {
    let exact = equivalentOf(amount, r);
    { amount = (I.round(exact, rounding)).amount; exact_ = exact }
  };

  /// Closing a position realises the difference between what it was booked at and
  /// what it is sold for. The arithmetic is the revaluation's, at the deal rate
  /// rather than the closing rate, and it posts through the same pair; which is why
  /// realised and unrealised cannot double-count: the unrealised balance is relieved
  /// by the same movement that recognises the realised one.
  public type Realisation = {
    currency : JT.Currency;
    closedPosition : Nat;
    bookedEquivalent : Nat;
    proceeds : Nat;
    movement : Nat;
    direction : { #gain; #loss; #unchanged };
  };

  public func realise(currency : JT.Currency, closedPosition : Nat, bookedEquivalent : Nat, proceeds : Nat) : Realisation {
    let (movement, direction) =
      if (proceeds > bookedEquivalent) (proceeds - bookedEquivalent, #gain)
      else if (bookedEquivalent > proceeds) (bookedEquivalent - proceeds, #loss)
      else (0, #unchanged);
    { currency; closedPosition; bookedEquivalent; proceeds; movement; direction }
  };

  public func realisationLegs(pair : PositionPair, functional : JT.Currency, r : Realisation) : ?[JT.Leg] {
    switch (r.direction) {
      case (#unchanged) null;
      case (#gain) ?[
        Posting.leg(pair.equivalent, null, #debit, functional, r.movement),
        Posting.leg(pair.realised, null, #credit, functional, r.movement),
      ];
      case (#loss) ?[
        Posting.leg(pair.realised, null, #debit, functional, r.movement),
        Posting.leg(pair.equivalent, null, #credit, functional, r.movement),
      ];
    }
  };

  public func directionText(d : { #gain; #loss; #unchanged }) : Text {
    switch (d) { case (#gain) "gain"; case (#loss) "loss"; case (#unchanged) "unchanged" }
  };
};
