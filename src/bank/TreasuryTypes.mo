/// TreasuryTypes.mo; treasury (treasury): deals as commands, positions as folds, valuation by declared curves, P&L on
/// the journal, nostro reconciliation as a fold over the correspondent's statements.
///
/// A deal is a recorded contract on the bank log: a money-market placement or taking, an FX forward or swap
/// (one side of every FX deal is the functional currency, as `Fx.mo` requires of every cross-currency posting),
/// a fixed-income security with its IFRS 9 classification, a vanilla interest-rate swap, an FX option. A curve is
/// declared data with a source hash, and a valuation is a pure function of recorded deals × recorded curves × the
/// recorded spot rate of the day; no price is ever read live into a posting. Limits are measured over the fold
/// before a deal is recorded. The correspondent's statement is recorded by its hash and its entries; the
/// reconciliation matches them against the nostro's own postings and records the breaks, aged by the end of day
/// and cleared by a dual act.
///
/// Every rate here is in the units `TreasuryMath.mo` states once: FX in micro (quote minor per base minor × 10⁶),
/// zero rates and volatilities in basis points, bond prices in micro per 100 of face.

import PT "PartyTypes";
import DC "DayCount";

module {

  public type Day = Nat;
  public type Bps = Nat;
  public type Micro = Nat;
  public type DealId = Nat;         // the bank block index of #dealCaptured
  public type BreakId = Nat;        // the bank block index of #nostroBreak
  public type CurveId = Text;       // ≤ 32 bytes
  public type Isin = Text;          // 12 characters
  public type NostroId = Text;      // ≤ 32 bytes

  /// The role accounts the treasury posts through and the rules that are the bank's to set.
  public type Policy = {
    // money market
    mmPlacements : Text;               // deposits placed with counterparties (asset)
    mmTakings : Text;                  // deposits taken (liability)
    mmInterestReceivable : Text;
    mmInterestPayable : Text;
    mmInterestIncome : Text;
    mmInterestExpense : Text;
    // marks: one account per instrument class, debit-normal, carrying the signed mark per deal sub-ledger; whether a
    // credit balance is shown as a liability is the statement's presentation (as the IAH equity of Islamic banking)
    fxForwardMark : Text;
    irsMark : Text;
    fxOptionValue : Text;              // options bought (asset) or written (liability) at premium, then at value
    unrealisedTradingGain : Text;
    unrealisedTradingLoss : Text;
    realisedTradingGain : Text;
    realisedTradingLoss : Text;
    // securities, one account per IFRS 9 class
    securitiesAmortisedCost : Text;
    securitiesFvoci : Text;
    securitiesFvtpl : Text;
    fvociReserve : Text;               // OCI: the fair-value reserve (equity), recycled to P&L on sale
    couponReceivable : Text;
    couponIncome : Text;
    amortisationIncome : Text;         // discount unwinding by the effective interest rate
    amortisationExpense : Text;        // premium unwinding
    // nostro reconciliation
    nostroSuspense : Text;             // where a resolving correction posts when the counter-account is not yet known
    lotMethod : LotMethod;
    confirmationDueDays : Nat;         // an unconfirmed deal after this many days is an alert (T+1 by default)
    breakAgeAlertDays : Nat;           // an open break this old is an alert
    maxCurvePoints : Nat;              // ≤ 40
  };
  public type LotMethod = { #fifo; #averageCost };
  public func lotMethodText(m : LotMethod) : Text { switch (m) { case (#fifo) "fifo"; case (#averageCost) "averageCost" } };

  public type Counterparty = { party : ?PT.PartyId; name : Text; bic : Text; lei : Text };
  /// A journal account a leg settles through, with an optional sub-ledger name.
  public type CashAccount = { account : Text; sub : ?Text };
  public type Direction = { #buy; #sell };   // from the bank's side: buy = the bank receives the base currency or the security
  public func directionText(d : Direction) : Text { switch (d) { case (#buy) "buy"; case (#sell) "sell" } };

  public type MoneyMarket = {
    placement : Bool;                  // true: the bank places (asset); false: the bank takes (liability)
    currency : Text; principal : Nat; rateBps : Bps; dayCount : DC.Convention; start : Day; maturity : Day;
    cash : CashAccount;                // the nostro or the counterparty's account the principal moves through
  };
  public type FxForward = {
    base : Text; quote : Text;         // quote is the functional currency
    direction : Direction; baseAmount : Nat; rateMicro : Micro; valueDate : Day;
    spotMicro : Micro; forwardPointsMicro : Int;   // rate = spot + points, checked at capture
    baseAccount : CashAccount; quoteAccount : CashAccount;
    pointsCurve : CurveId; discountCurve : CurveId;
  };
  public type FxSwap = { near : FxForward; far : FxForward };
  public type SecurityTerms = {
    isin : Isin; issuer : Text; currency : Text; couponBps : Bps; couponsPerYear : Nat; dayCount : DC.Convention;
    issue : Day; maturity : Day;
  };
  public type Classification = { #amortisedCost; #fvoci; #fvtpl };
  public func classificationText(c : Classification) : Text { switch (c) { case (#amortisedCost) "amortisedCost"; case (#fvoci) "fvoci"; case (#fvtpl) "fvtpl" } };
  public type SecurityTrade = {
    isin : Isin; direction : Direction; nominal : Nat; priceMicro : Micro; settlement : Day; classification : Classification;
    cash : CashAccount; priceCurve : CurveId; venue : ?Text;
  };
  public type Irs = {
    currency : Text; notional : Nat; payFixed : Bool; fixedBps : Bps; floatingIndex : Text; spreadBps : Int;
    start : Day; maturity : Day; paymentMonths : Nat; dayCount : DC.Convention; cash : CashAccount; discountCurve : CurveId;
  };
  public type FxOption = {
    base : Text; quote : Text; call : Bool; bought : Bool; baseAmount : Nat; strikeMicro : Micro; expiry : Day; premium : Nat; start : Day;
    cash : CashAccount; domesticCurve : CurveId; foreignCurve : CurveId; volCurve : CurveId;
  };
  public type DealKind = { #moneyMarket : MoneyMarket; #fxForward : FxForward; #fxSwap : FxSwap; #security : SecurityTrade; #irs : Irs; #fxOption : FxOption };
  public func dealKindText(k : DealKind) : Text {
    switch (k) { case (#moneyMarket(_)) "moneyMarket"; case (#fxForward(_)) "fxForward"; case (#fxSwap(_)) "fxSwap"; case (#security(_)) "security"; case (#irs(_)) "irs"; case (#fxOption(_)) "fxOption" }
  };

  public type DealState = { #captured; #confirmed; #settled; #cancelled };
  public func dealStateText(s : DealState) : Text { switch (s) { case (#captured) "captured"; case (#confirmed) "confirmed"; case (#settled) "settled"; case (#cancelled) "cancelled" } };

  /// A declared curve: zero rates by tenor (bps), forward points by tenor (micro), volatility by tenor (bps), or a
  /// security's price (one point at tenor 0, micro per 100). Flat beyond the ends, linear between.
  public type CurveKind = { #zeroRates; #forwardPoints; #volatility; #securityPrice };
  public func curveKindText(k : CurveKind) : Text { switch (k) { case (#zeroRates) "zeroRates"; case (#forwardPoints) "forwardPoints"; case (#volatility) "volatility"; case (#securityPrice) "securityPrice" } };
  public type Curve = { id : CurveId; kind : CurveKind; currency : Text; day : Day; points : [(Nat, Int)]; source : Blob };

  public type LimitKind = { #counterpartyExposure; #openFxPosition; #tenorBucket; #dv01; #stopLoss; #issuerConcentration };
  public func limitKindText(k : LimitKind) : Text {
    switch (k) { case (#counterpartyExposure) "counterpartyExposure"; case (#openFxPosition) "openFxPosition"; case (#tenorBucket) "tenorBucket"; case (#dv01) "dv01"; case (#stopLoss) "stopLoss"; case (#issuerConcentration) "issuerConcentration" }
  };
  /// A limit on a book in a currency; `subject` names the counterparty (by name), the issuer, or the tenor bucket
  /// as "fromDays-toDays"; empty for the kinds that have none.
  public type Limit = { book : Text; kind : LimitKind; currency : Text; subject : Text; value : Nat };

  public type Nostro = { id : NostroId; account : Text; sub : ?Text; currency : Text; correspondent : Counterparty; iban : Text; valueDateToleranceDays : Nat };
  public type StatementEntry = { reference : Text; amount : Nat; credit : Bool; valueDay : Day; bookingDay : Day; counterparty : Text };
  public type EntryOutcome = { #matched : { posting : Nat }; #break_ };
  public type BreakSide = { #onStatementOnly; #inOurBooksOnly };
  public func breakSideText(s : BreakSide) : Text { switch (s) { case (#onStatementOnly) "onStatementOnly"; case (#inOurBooksOnly) "inOurBooksOnly" } };

  /// What a counterparty's confirmation says, as the connector read it (or as the contract parsed the document).
  public type ConfirmationFields = { kind : Text; amount1 : Nat; currency1 : Text; amount2 : Nat; currency2 : Text; valueDate : Day; rateMicro : Nat; counterparty : Text };

  public type TreasuryEvent = {
    #policySet : Policy;
    #securityRegistered : { terms : SecurityTerms; day : Day };
    #curvePublished : { curve : Curve };
    #limitSet : { limit : Limit; day : Day };
    #nostroRegistered : { nostro : Nostro; day : Day };
    #dealCaptured : { book : Text; counterparty : Counterparty; kind : DealKind; reference : Text; trader : Principal; day : Day; withinLimits : Bool; approver : ?Principal; secondAmount : Nat };
    #limitBreached : { limit : Limit; measured : Nat; deal : DealId; approver : Principal; day : Day };
    #dealConfirmed : { deal : DealId; confirmation : Blob; day : Day };
    #confirmationMismatch : { deal : DealId; confirmation : Blob; field : Text; ours : Text; theirs : Text; day : Day };
    #dealAmended : { deal : DealId; kind : DealKind; reason : Text; day : Day; secondAmount : Nat };
    #dealCancelled : { deal : DealId; reason : Text; day : Day };
    /// A leg settled, with the deltas the fold applies to the row's running figures: accrual catch-up, amortisation,
    /// fair-value reversal, and the nominal and cost that left (a sale or a redemption).
    #legSettled : { deal : DealId; leg : Nat; amount : Nat; currency : Text; realised : Int; day : Day; accrual : Int; amortisation : Int; fv : Int; nominal : Nat; cost : Nat };
    /// A purchase lot consumed by a sale (one per lot, after the sale's `#legSettled`).
    #lotConsumed : { lot : DealId; by : DealId; nominal : Nat; cost : Nat; amortisation : Int; fv : Int; accrual : Int; day : Day };
    #accrued : { deal : DealId; interest : Int; amortisation : Int; day : Day };
    #marked : { deal : DealId; value : Int; previous : Int; day : Day };
    #couponPaid : { deal : DealId; amount : Nat; day : Day };
    #statementRecorded : { nostro : NostroId; statement : Blob; from : Day; to : Day; entries : Nat; matches : [Nat]; breaks : Nat; day : Day };
    #nostroBreak : { nostro : NostroId; statement : Blob; side : BreakSide; amount : Nat; credit : Bool; valueDay : Day; reference : Text; posting : ?Nat; day : Day };
    #breakResolved : { breakId : BreakId; resolution : Text; corrected : Bool; day : Day };
    #breakAged : { breakId : BreakId; ageDays : Nat; day : Day };
    #confirmationOverdue : { deal : DealId; ageDays : Nat; day : Day };
  };

  public type TreasuryError = {
    #NoPolicy;
    #InvalidPolicy : { reason : Text };
    #InvalidTerms : { reason : Text };
    #UnknownDeal : { deal : DealId };
    #DealNotIn : { deal : DealId; state : Text; wanted : Text };
    #LegNotDue : { deal : DealId; leg : Nat; due : Day; day : Day };
    #LegSettled : { deal : DealId; leg : Nat };
    #NoSuchLeg : { deal : DealId; leg : Nat };
    #UnknownSecurity : { isin : Isin };
    #UnknownCurve : { curve : CurveId; day : Day };
    #NoRate : { currency : Text; day : Day };
    #NoFixing : { index : Text; day : Day };
    #LimitBreached : { kind : Text; subject : Text; limit : Nat; measured : Nat };
    #UnsupportedKind : { kind : Text; reason : Text };
    #InsufficientPosition : { isin : Isin; book : Text; held : Nat; wanted : Nat };
    #UnknownNostro : { nostro : NostroId };
    #UnknownBreak : { breakId : BreakId };
    #BreakNotOpen : { breakId : BreakId };
    #BadDocument : { reason : Text };
    #ShariaBook : { book : Text; kind : Text };
    #Busy : { reason : Text };
  };

  public type DealView = {
    id : DealId; book : Text; kind : Text; state : Text; counterparty : Text; reference : Text; currency : Text; notional : Nat;
    secondCurrency : Text; secondAmount : Nat; day : Day; start : Day; maturity : Day; rate : Nat; accruedPosted : Int; amortisedPosted : Int;
    fvPosted : Int; markPosted : Int; realised : Int; nominalLeft : Nat; costLeft : Nat; yieldMillionths : Nat; settledLegs : Nat; legs : Nat;
    confirmed : Bool; withinLimits : Bool; lastBlock : Nat;
  };
  public type BreakView = { id : BreakId; nostro : NostroId; side : Text; amount : Nat; credit : Bool; valueDay : Day; reference : Text; posting : ?Nat; openedDay : Day; ageDays : Nat; resolved : Bool; block : Nat };
  public type PositionView = { book : Text; instrument : Text; currency : Text; kind : Text; nominal : Int; carrying : Int; mark : Int; deals : Nat };
  public type NostroPostingView = { posting : Nat; valueDay : Day; amount : Nat; debit : Bool; matched : Bool; statement : ?Blob };
  public type Status = { deals : Nat; open : Nat; curves : Nat; securities : Nat; limits : Nat; nostros : Nat; breaksOpen : Nat; breaksTotal : Nat; statements : Nat; realisedTotal : Int; markTotal : Int };
}
