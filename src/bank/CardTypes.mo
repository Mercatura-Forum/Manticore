/// CardTypes.mo: cards (cards): issuance, authorization as a hold on the journal, clearing and settlement as postings,
/// disputes as lifecycles, the PAN never in the contract.
///
/// The boundary, stated first (PCI DSS scope): no PAN, no track data, no CVV, no PIN and no key of the card ever
/// enters the contract, a block, a row or a log. The contract knows a card by a **token**; an identifier the bank's
/// token vault minted, whose mapping to the PAN lives in that PCI-scoped system; and it keeps only the token's
/// digest as a key. What arrives from the scheme is the authorization request with the token and the *results* of
/// the HSM's checks (`cryptogramValid`, `pinVerified`), signed by the connector whose key the scheme record carries;
/// what the contract answers is a decision, and every decision is a block. Scheme rules; interchange, floor limits,
/// dispute time limits by reason code; are recorded data with their source named, never constants in code.

import PT "PartyTypes";
import ProdT "ProductTypes";
import PayT "PaymentsTypes";

module {

  public type Day = Nat;
  public type Token = Blob;             // the vault's token, 8..32 bytes; never a PAN
  public type CardId = Nat;             // the bank block index of #cardIssued
  public type AuthId = Nat;             // the bank block index of #authorised
  public type ClearedId = Nat;          // the bank block index of #cleared
  public type DisputeId = Nat;          // the bank block index of #disputeOpened
  public type SchemeId = Text;          // ≤ 16 bytes
  public type ProductId = Text;         // ≤ 32 bytes
  public type Mcc = Nat;                // ISO 18245 merchant category code, 0..9999

  /// The role accounts the cards domain posts through and the rules that are the bank's to set.
  public type Policy = {
    disputeSuspense : Text;            // provisional credits until the case resolves
    interchangeIncome : Text;
    schemeFees : Text;                 // scheme and network fees (expense)
    fraudLosses : Text;                // the bank's loss when a cardholder wins and the scheme does not pay
    cardFeeIncome : Text;              // issuance and replacement fees
    provisionalCreditCeiling : Nat;    // above it the credit is a dual act
    clearingTolerance : Nat;           // a clearing may differ from its authorization by this much and still post against the hold
    stanReplayDays : Nat;              // a (acquirer, STAN, RRN) seen within this many days is a duplicate
  };

  /// Interchange by merchant-category range, the floor limit, and the dispute clock per reason code; the scheme's
  /// public rule summary is the source, named.
  public type InterchangeBand = { mccFrom : Mcc; mccTo : Mcc; bps : Nat; fixed : Nat };
  public type ReasonRule = { code : Text; description : Text; chargebackDays : Nat; representmentDays : Nat; preArbitrationDays : Nat };
  public type SchemeRules = {
    source : Text;                     // the document the figures were read from (title, edition, URL)
    interchange : [InterchangeBand];
    floorLimit : Nat;                  // a clearing without an authorization posts when at or below it
    holdDays : Nat;                    // an authorization's hold expires after this many days
    reasons : [ReasonRule];
    feeBps : Nat;                      // the scheme's fee on cleared volume
  };
  public type Scheme = {
    id : SchemeId; name : Text; settlementAccount : Text; settlementCurrency : Text; rules : SchemeRules;
    connectorScheme : PayT.SignatureScheme; connectorKey : Blob;   // who may sign authorizations and clearing batches
  };

  public type Channels = { pos : Bool; atm : Bool; ecom : Bool; contactless : Bool; international : Bool };
  public type Controls = { dailyLimit : Nat; perTransactionLimit : Nat; mccAllow : [Mcc]; mccDeny : [Mcc]; channels : Channels; velocityCount : Nat; velocityWindowMinutes : Nat };
  public type CardKind = { #debit; #credit : { statementDay : Nat; minimumDueBps : Nat; minimumDueFloor : Nat; graceDays : Nat } };
  public type CardProduct = { id : ProductId; name : Text; kind : CardKind; scheme : SchemeId; bounds : Controls; issueFee : Nat; replacementFee : Nat; expiryMonths : Nat };
  public type Form = { #physical; #virtual };
  public type CardState = { #issued; #active; #blocked; #closed };
  public func stateText(s : CardState) : Text { switch (s) { case (#issued) "issued"; case (#active) "active"; case (#blocked) "blocked"; case (#closed) "closed" } };
  public type BlockReason = { #customer; #lost; #stolen; #fraud; #bank : Text };
  public type ReplaceReason = { #lost; #stolen; #damaged; #expired };

  public type Channel = { #pos; #atm; #ecom; #contactless };
  public func channelText(c : Channel) : Text { switch (c) { case (#pos) "pos"; case (#atm) "atm"; case (#ecom) "ecom"; case (#contactless) "contactless" } };
  public type AuthKind = { #purchase; #preAuthorization; #incremental : { of : AuthId }; #completion : { of : AuthId }; #refund; #reversal : { of : AuthId } };
  /// What the acquirer sent, as the connector translated it (ISO 8583 or cain.001), with the HSM's verdicts. The
  /// merchant is a digest; the country a code; the STAN and RRN the scheme's own references.
  public type AuthRequest = {
    token : Token; kind : AuthKind; amount : Nat; currency : Text; mcc : Mcc; merchantHash : Blob; merchantCountry : Text; acquirer : Text;
    channel : Channel; cryptogramValid : Bool; pinVerified : ?Bool; stan : Text; rrn : Text; localTime : Nat64;
  };
  public type DeclineReason = {
    #unknownCard; #cardNotActive; #cardBlocked; #cardExpired; #mccDenied; #channelDenied; #internationalDenied; #overPerTransaction; #overDailyLimit; #velocity;
    #insufficientFunds; #cryptogramInvalid; #pinFailed; #duplicate; #unknownOriginal; #originalNotOpen; #amountExceedsOriginal; #currencyMismatch; #schemeMismatch;
  };
  public func declineText(r : DeclineReason) : Text {
    switch (r) {
      case (#unknownCard) "unknownCard"; case (#cardNotActive) "cardNotActive"; case (#cardBlocked) "cardBlocked"; case (#cardExpired) "cardExpired"; case (#mccDenied) "mccDenied";
      case (#channelDenied) "channelDenied"; case (#internationalDenied) "internationalDenied"; case (#overPerTransaction) "overPerTransaction"; case (#overDailyLimit) "overDailyLimit"; case (#velocity) "velocity";
      case (#insufficientFunds) "insufficientFunds"; case (#cryptogramInvalid) "cryptogramInvalid"; case (#pinFailed) "pinFailed"; case (#duplicate) "duplicate"; case (#unknownOriginal) "unknownOriginal";
      case (#originalNotOpen) "originalNotOpen"; case (#amountExceedsOriginal) "amountExceedsOriginal"; case (#currencyMismatch) "currencyMismatch"; case (#schemeMismatch) "schemeMismatch";
    }
  };
  /// ISO 8583 DE 39 response codes for the decisions, so the connector answers the acquirer in the scheme's words.
  public func responseCode(d : Decision) : Text {
    switch (d) {
      case (#approved(_)) "00";
      case (#declined(r)) {
        switch (r) {
          case (#unknownCard) "14"; case (#cardNotActive) "62"; case (#cardBlocked) "62"; case (#cardExpired) "54"; case (#mccDenied) "57"; case (#channelDenied) "57"; case (#internationalDenied) "57";
          case (#overPerTransaction) "61"; case (#overDailyLimit) "61"; case (#velocity) "65"; case (#insufficientFunds) "51"; case (#cryptogramInvalid) "05"; case (#pinFailed) "55"; case (#duplicate) "94";
          case (#unknownOriginal) "12"; case (#originalNotOpen) "12"; case (#amountExceedsOriginal) "13"; case (#currencyMismatch) "12"; case (#schemeMismatch) "12";
        }
      };
    }
  };
  public type Decision = { #approved : { authCode : Text; hold : ?Nat; amount : Nat }; #declined : DeclineReason };

  public type ClearingItem = { authCode : ?Text; token : Token; amount : Nat; currency : Text; mcc : Mcc; merchantHash : Blob; acquirer : Text; stan : Text; rrn : Text; day : Day; refund : Bool };
  public type ClearingOutcome = { #postedAgainstHold : { auth : AuthId; hold : Nat; difference : Int }; #postedDirect : { belowFloor : Bool }; #exception : { reason : Text } };
  public type DisputeStage = { #opened; #provisionalCredit; #chargeback; #representment; #preArbitration; #resolved };
  public func stageText(s : DisputeStage) : Text { switch (s) { case (#opened) "opened"; case (#provisionalCredit) "provisionalCredit"; case (#chargeback) "chargeback"; case (#representment) "representment"; case (#preArbitration) "preArbitration"; case (#resolved) "resolved" } };
  public type Outcome = { #cardholder; #merchant };

  public type CardEvent = {
    #policySet : Policy;
    #schemeDeclared : { scheme : Scheme; day : Day };
    #productDefined : { product : CardProduct; day : Day };
    #cardIssued : { tokenHash : Blob; account : ProdT.AccountId; party : PT.PartyId; product : ProductId; form : Form; expiryMonth : Nat; controls : Controls; day : Day; replaces : ?CardId };
    #cardActivated : { card : CardId; day : Day };
    #cardBlocked : { card : CardId; reason : BlockReason; day : Day };
    #cardUnblocked : { card : CardId; day : Day };
    #cardClosed : { card : CardId; reason : Text; day : Day };
    #controlsSet : { card : CardId; controls : Controls; byCustomer : Bool; day : Day };
    /// Every decision is a block: the request's facts (never the PAN), the decision, the hold placed.
    #authorised : { card : ?CardId; request : AuthRequest; decision : Decision; day : Day };
    #holdAdjusted : { auth : AuthId; from : Nat; to : Nat; hold : ?Nat; kind : Text; day : Day };
    #holdExpired : { auth : AuthId; hold : Nat; day : Day };
    #clearingRecorded : { scheme : SchemeId; batch : Blob; items : Nat; posted : Nat; exceptions : Nat; interchange : Nat; fees : Nat; day : Day };
    #cleared : { scheme : SchemeId; batch : Blob; card : ?CardId; item : ClearingItem; outcome : ClearingOutcome; interchange : Nat; fee : Nat; posting : ?Nat; day : Day };
    #disputeOpened : { transaction : ClearedId; card : CardId; reason : Text; amount : Nat; dueDay : Day; day : Day };
    #provisionalCredited : { dispute : DisputeId; amount : Nat; day : Day };
    #chargebackRaised : { dispute : DisputeId; schemeRef : Text; dueDay : Day; day : Day };
    #representmentRecorded : { dispute : DisputeId; dueDay : Day; day : Day };
    #preArbitrationRecorded : { dispute : DisputeId; dueDay : Day; day : Day };
    #disputeResolved : { dispute : DisputeId; outcome : Outcome; finalAmount : Nat; day : Day };
    #disputeStepDue : { dispute : DisputeId; stage : DisputeStage; dueDay : Day; day : Day };
    #fraudMarked : { transaction : ClearedId; card : CardId; blocked : Bool; day : Day };
    #statementCut : { card : CardId; cycleEnd : Day; balance : Int; minimumDue : Nat; dueDay : Day; purchases : Nat; payments : Nat; interest : Nat; day : Day };
  };

  public type CardError = {
    #NoPolicy;
    #InvalidPolicy : { reason : Text };
    #InvalidTerms : { reason : Text };
    #UnknownScheme : { scheme : SchemeId };
    #UnknownProduct : { product : ProductId };
    #UnknownCard : { card : CardId };
    #CardNotIn : { card : CardId; state : Text; wanted : Text };
    #ControlsOutsideBounds : { field : Text };
    #BadSignature;
    #UnknownAuthorization : { auth : AuthId };
    #UnknownTransaction : { transaction : ClearedId };
    #UnknownDispute : { dispute : DisputeId };
    #DisputeNotIn : { dispute : DisputeId; stage : Text; wanted : Text };
    #UnknownReason : { code : Text };
    #BatchKnown : { batch : Blob };
    #BadDocument : { reason : Text };
    #Busy : { reason : Text };
  };

  public type CardView = {
    id : CardId; account : ProdT.AccountId; party : PT.PartyId; product : ProductId; scheme : SchemeId; form : Text; state : Text; expiryMonth : Nat; controls : Controls;
    issuedDay : Day; replaces : ?CardId; replacedBy : ?CardId; authorizations : Nat; declines : Nat; openHolds : Nat; heldAmount : Nat; clearedCount : Nat; clearedAmount : Nat; lastBlock : Nat;
  };
  public type AuthView = { id : AuthId; card : ?CardId; kind : Text; amount : Nat; currency : Text; mcc : Mcc; channel : Text; approved : Bool; responseCode : Text; authCode : Text; hold : ?Nat; holdAmount : Nat; holdOpen : Bool; day : Day; stan : Text; rrn : Text };
  public type DisputeView = { id : DisputeId; transaction : ClearedId; card : CardId; reason : Text; amount : Nat; stage : Text; dueDay : Day; outcome : ?Text; finalAmount : Nat; provisional : Nat; block : Nat };
  public type Status = { schemes : Nat; products : Nat; cards : Nat; active : Nat; authorizations : Nat; approved : Nat; declined : Nat; openHolds : Nat; cleared : Nat; exceptions : Nat; disputes : Nat; openDisputes : Nat; statements : Nat };
}
