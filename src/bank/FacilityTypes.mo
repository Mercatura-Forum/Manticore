/// FacilityTypes.mo; corporate lending (corporate lending): the facility as the contract the bank and the borrower sign, of
/// which a loan account is one drawing. Bilateral and revolving facilities, syndications with the bank as agent
/// or participant, restructuring across every drawing, finance and operating leases, factoring and forfaiting,
/// covenants, pricing as data with recorded rate fixings.
///
/// A facility never holds an amount of its own: drawn is the sum of its drawings' outstanding principal read
/// from the journal, available is limit − drawn while nothing blocks it, a participant's position is the balance
/// of its sub-ledger, the fee, rental and discount accruals are postings the end-of-day batch makes from the
/// recorded terms; every figure a fold, every decision a block.

import PT "PartyTypes";
import ProdT "ProductTypes";
import PayT "PaymentsTypes";

module {

  public type Day = Nat;
  public type FacilityId = Nat;    // the bank block index of #facilityOpened
  public type Bps = Nat;

  /// The price of a drawing: a fixed annual rate in basis points, or a recorded index plus a spread, re-fixed
  /// every `resetDays` from the drawing's value date by the end-of-day batch.
  public type Pricing = {
    #fixed : Bps;
    #floating : { index : Text; spreadBps : Bps; resetDays : Nat };
  };

  /// A participant of a syndicate: a party (the other lenders are parties of the bank's own party layer) with
  /// its share of every drawing in basis points of the whole; the shares of a syndicate sum to 10,000, the bank's
  /// own included.
  public type Share = { participant : PT.PartyId; bps : Bps };

  public type Kind = {
    /// one lender, one drawing schedule
    #bilateralTerm;
    /// availability and re-borrowing under an aggregate limit; a commitment fee on the undrawn amount; an
    /// optional clean-down: within every `everyDays` of availability the facility is fully undrawn for `forDays`
    #revolving : { commitmentFeeBps : Bps; cleanDown : ?{ everyDays : Nat; forDays : Nat } };
    /// the bank is the agent: drawings are funded by the participants' shares (the bank's own included), the
    /// borrower's interest is distributed by share as it is received, the agent's fee is the bank's
    #syndicatedAgent : { shares : [Share]; agentFeeBps : Bps };
    /// the bank is a participant: the agent's signed notices drive the bank's share of every drawing; the
    /// agent's key verifies them and the agent's account at the bank funds and receives the share
    #syndicatedParticipant : { agent : Text; agentScheme : PayT.SignatureScheme; agentKey : Blob; agentAccount : Text; ourBps : Bps };
    /// a finance lease: the lessor's net investment (IFRS 16 §67), rentals split into principal and finance
    /// income by the effective interest method the loan engine already implements
    #financeLease : { assetAccount : Text; residual : Nat };
    /// an operating lease: the asset stays, rental income straight-line over the term (IFRS 16 §81)
    #operatingLease : { rentalPerPeriod : Nat; every : ProdT.Period; periods : Nat };
    /// receivables purchased at a discount, an advance paid and a retention held; with recourse a dishonour
    /// charges back to the client, without it the receivable is the bank's exposure on the debtor
    #factoring : { advanceBps : Bps; discountBps : Bps; recourse : Bool; clientAccount : ProdT.AccountId };
    /// one instrument bought without recourse at a discount to maturity
    #forfaiting : { discountBps : Bps; clientAccount : ProdT.AccountId };
  };

  public func kindCode(k : Kind) : Nat8 {
    switch (k) {
      case (#bilateralTerm) 0; case (#revolving(_)) 1; case (#syndicatedAgent(_)) 2; case (#syndicatedParticipant(_)) 3;
      case (#financeLease(_)) 4; case (#operatingLease(_)) 5; case (#factoring(_)) 6; case (#forfaiting(_)) 7;
    }
  };
  public func kindText(k : Kind) : Text {
    switch (k) {
      case (#bilateralTerm) "bilateralTerm"; case (#revolving(_)) "revolving"; case (#syndicatedAgent(_)) "syndicatedAgent";
      case (#syndicatedParticipant(_)) "syndicatedParticipant"; case (#financeLease(_)) "financeLease"; case (#operatingLease(_)) "operatingLease";
      case (#factoring(_)) "factoring"; case (#forfaiting(_)) "forfaiting";
    }
  };

  public type Covenant = {
    id : Text;
    kind : {
      /// a ratio presented from the borrower's statements: met while `value op threshold`
      #financialRatio : { name : Text; op : { #atMost; #atLeast }; thresholdBps : Nat };
      /// a document due by a day
      #reporting : { due : Day };
      #negativePledge;
    };
  };

  public type Stage = { #open; #blocked; #closed };
  public func stageCode(s : Stage) : Nat8 { switch (s) { case (#open) 0; case (#blocked) 1; case (#closed) 2 } };
  public func stageOfCode(c : Nat8) : ?Stage { switch (c) { case 0 ?#open; case 1 ?#blocked; case 2 ?#closed; case _ null } };
  public func stageText(s : Stage) : Text { switch (s) { case (#open) "open"; case (#blocked) "blocked"; case (#closed) "closed" } };

  public type Terms = {
    party : PT.PartyId;
    book : Text;
    /// the loan product the facility's drawings are accounts of; its role mapping carries what the kind posts to
    product : ProdT.ProductId;
    kind : Kind;
    currency : Text;
    limit : Nat;
    availabilityFrom : Day;
    availabilityTo : Day;
    pricing : Pricing;
    covenants : [Covenant];
    collateral : [Nat];
    reviewEvery : ?Nat;
  };

  /// A receivable bought under a factoring or forfaiting facility: the debtor is a commitment (never a name),
  /// the invoice a hash, the face amount and the day it falls due.
  public type Receivable = { ref : Blob; debtorCommit : PT.Commitment; face : Nat; due : Day };

  /// What the agent's notice says, when the bank is a participant: the drawing's whole and the bank's share.
  public type AgentNotice = {
    #drawdown : { drawing : Text; total : Nat; ourShare : Nat; valueDate : Day };
    #repayment : { drawing : Text; total : Nat; ourShare : Nat; valueDate : Day };
    #interestDistribution : { drawing : Text; total : Nat; ourShare : Nat; valueDate : Day };
  };

  public type RestructureTerms = { schedule : ProdT.ScheduleTerms; rateBps : Bps };

  public type FacilityEvent = {
    #facilityOpened : { terms : Terms; day : Day };
    #drawn : { facility : FacilityId; account : ProdT.AccountId; amount : Nat; rateBps : Bps; day : Day; splits : [(PT.PartyId, Nat)] };
    #drawingRepaid : { facility : FacilityId; account : ProdT.AccountId; amount : Nat; day : Day; interestShared : [(PT.PartyId, Nat)] };
    #commitmentFeeAccrued : { facility : FacilityId; day : Day; undrawn : Nat; amount : Nat };
    #cleanDownJudged : { facility : FacilityId; windowEnd : Day; cleanDays : Nat; required : Nat; met : Bool };
    #participationTransferred : { facility : FacilityId; from : PT.PartyId; to : PT.PartyId; bps : Bps; moved : Nat };
    #distributedToParticipants : { facility : FacilityId; day : Day; amounts : [(PT.PartyId, Nat)] };
    #agentNoticeRecorded : { facility : FacilityId; notice : AgentNotice; noticeHash : Blob; account : ?ProdT.AccountId };
    #facilityRestructured : { facility : FacilityId; terms : RestructureTerms; effective : Day; drawings : [ProdT.AccountId] };
    #drawingRepriced : { facility : FacilityId; account : ProdT.AccountId; day : Day; rateBps : Bps; fixing : Nat };
    #covenantTested : { facility : FacilityId; covenant : Text; value : Nat; met : Bool; statementHash : Blob; day : Day };
    #drawdownsBlocked : { facility : FacilityId; reason : Text; day : Day };
    #drawdownsUnblocked : { facility : FacilityId; reason : Text; day : Day };
    #reviewRecorded : { facility : FacilityId; day : Day; nextDue : ?Day; note : Text };
    #reviewOverdue : { facility : FacilityId; due : Day; day : Day };
    #leaseRentalAccrued : { facility : FacilityId; day : Day; amount : Nat };
    #rentalReceived : { facility : FacilityId; amount : Nat; day : Day };
    #residualRemeasured : { facility : FacilityId; from : Nat; to : Nat; day : Day };
    #receivablesPurchased : { facility : FacilityId; receivables : [Receivable]; face : Nat; advance : Nat; discount : Nat; retention : Nat; day : Day };
    #discountUnwound : { facility : FacilityId; day : Day; amount : Nat; items : [(Blob, Nat)] };
    #receivableCollected : { facility : FacilityId; ref : Blob; amount : Nat; retentionReleased : Nat; day : Day };
    #receivableDishonoured : { facility : FacilityId; ref : Blob; face : Nat; chargedBack : Bool; day : Day };
    #receivableWrittenOff : { facility : FacilityId; ref : Blob; amount : Nat; day : Day };
    #drawingClosed : { facility : FacilityId; account : ProdT.AccountId; day : Day };
    #rateFixingRecorded : { index : Text; day : Day; rateBps : Bps };
    #facilityClosed : { facility : FacilityId; day : Day };
  };

  public type FacilityError = {
    #UnknownFacility : { facility : FacilityId };
    #WrongKind : { facility : FacilityId; kind : Text; wanted : Text };
    #WrongStage : { facility : FacilityId; stage : Text; wanted : Text };
    #InvalidTerms : { reason : Text };
    #OutsideAvailability : { facility : FacilityId; day : Day; from : Day; to : Day };
    #OverLimit : { facility : FacilityId; limit : Nat; drawn : Nat; requested : Nat };
    #Blocked : { facility : FacilityId; reason : Text };
    #NoFixing : { index : Text; day : Day };
    #UnknownParticipant : { facility : FacilityId; participant : PT.PartyId };
    #UnknownCovenant : { facility : FacilityId; covenant : Text };
    #UnknownReceivable : { facility : FacilityId; ref : Blob };
    #ReceivableNotOpen : { facility : FacilityId; ref : Blob };
    #NotADrawing : { facility : FacilityId; account : ProdT.AccountId };
    #SignatureInvalid : { facility : FacilityId };
    #NoticeMismatch : { reason : Text };
    #HasDrawings : { facility : FacilityId; open : Nat };
  };

  public type FacilityView = {
    id : FacilityId;
    party : PT.PartyId;
    book : Text;
    product : ProdT.ProductId;
    kind : Kind;
    currency : Text;
    limit : Nat;
    stage : Stage;
    availabilityFrom : Day;
    availabilityTo : Day;
    pricing : Pricing;
    covenants : [Covenant];
    drawings : Nat;
    openDrawings : Nat;
    receivables : Nat;
    openReceivables : Nat;
    covenantBreaches : Nat;
    nextReview : ?Day;
    openedBlock : Nat;
    lastBlock : Nat;
  };
}
