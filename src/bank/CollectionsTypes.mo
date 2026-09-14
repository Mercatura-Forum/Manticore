/// CollectionsTypes.mo; the life of a troubled exposure, as the bank records it (collections and recovery).
///
/// A lending exposure is in one stage at a time: current → overdue → delinquent → default → collections →
/// restructuring → write-off → recovery → closed. The *computed* transitions are the end-of-day batch's; days
/// past due read from the schedule and the postings (`Loans.arrears`), never from a stored counter; and the
/// *decided* ones are commands under maker-checker: unlikely to pay (Basel BCBS d403's qualitative default),
/// a collector's actions and the borrower's promises, the assignment, the closing of a recovery. Restructuring,
/// write-off and recovery are the product engine's acts (`rescheduleLoan`, `writeOffLoan`, `recordRecovery`)
/// and move the stage as they are folded. The policy; the day thresholds, the stage from which interest is
/// held in suspense rather than income, whether a modification gain or loss is recognised at restructuring; is
/// recorded data, set by a dual act, and every derivation names the figures it used.

import Text "mo:core/Text";

module {

  public type Day = Nat;
  public type AccountId = Nat;

  public type Stage = {
    #current; #overdue; #delinquent; #default_; #collections; #restructuring; #writeOff; #recovery; #closed;
  };

  public func stageText(s : Stage) : Text {
    switch (s) {
      case (#current) "current"; case (#overdue) "overdue"; case (#delinquent) "delinquent"; case (#default_) "default";
      case (#collections) "collections"; case (#restructuring) "restructuring"; case (#writeOff) "writeOff";
      case (#recovery) "recovery"; case (#closed) "closed";
    }
  };

  public func stageCode(s : Stage) : Nat8 {
    switch (s) {
      case (#current) 0; case (#overdue) 1; case (#delinquent) 2; case (#default_) 3; case (#collections) 4;
      case (#restructuring) 5; case (#writeOff) 6; case (#recovery) 7; case (#closed) 8;
    }
  };

  public func stageOfCode(c : Nat8) : ?Stage {
    switch (c) {
      case 0 ?#current; case 1 ?#overdue; case 2 ?#delinquent; case 3 ?#default_; case 4 ?#collections;
      case 5 ?#restructuring; case 6 ?#writeOff; case 7 ?#recovery; case 8 ?#closed; case _ null;
    }
  };

  /// The policy the derivation reads. `delinquentDpd` and `defaultDpd` are days past due (Basel: 90);
  /// `suspendInterestFrom` is the stage from which accrued interest is credited to the suspense role rather
  /// than income; `recogniseModificationLoss` says whether a restructuring posts the IFRS 9 §5.4.3 modification
  /// gain or loss at once (the recommendation) or leaves the carrying amount (a bank that must defer).
  public type Policy = {
    delinquentDpd : Nat;
    defaultDpd : Nat;
    suspendInterestFrom : Stage;
    recogniseModificationLoss : Bool;
  };

  public type Action = { #call; #letter; #visit; #legalNotice; #fieldAgent; #other : Text };

  /// Why a stage moved.
  public type Reason = { #daysPastDue; #unlikelyToPay; #collectionAction; #restructured; #writtenOff; #recovery; #cured; #closed };

  public type CollectionsEvent = {
    #policySet : Policy;
    /// The stage moved: from what, to what, on which day, at how many days past due, and why.
    #stageDerived : { account : AccountId; from : Stage; to : Stage; dpd : Nat; day : Day; reason : Reason; note : Text };
    #actionRecorded : { account : AccountId; action : Action; outcome : Text; next : ?Day; day : Day };
    /// `baseline` is what the borrower had repaid in total when the promise was made: the batch judges the
    /// promise against the repayments that followed, never against a stored counter.
    #promiseRecorded : { account : AccountId; amount : Nat; by : Day; day : Day; baseline : Nat };
    /// The end-of-day batch judged a promise on the day after it fell due: kept when the postings that followed
    /// reach the amount, broken otherwise.
    #promiseJudged : { account : AccountId; amount : Nat; by : Day; kept : Bool; day : Day };
    #collectorAssigned : { account : AccountId; staff : Principal };
    /// Interest accrued on an exposure in suspense: credited to the suspense role, not income; and its
    /// release to income on cure.
    #interestSuspended : { account : AccountId; amount : Nat; day : Day };
    #suspenseReleased : { account : AccountId; amount : Nat; day : Day };
  };

  public type CollectionsError = {
    #UnknownExposure : { account : AccountId };
    #NotALoan : { account : AccountId };
    #InvalidStageTransition : { account : AccountId; from : Text; to : Text };
    #InvalidPolicy : { reason : Text };
    #PromiseInThePast : { by : Day; today : Day };
    #NoPolicy;
  };

  /// One exposure as a reader sees it.
  public type ExposureView = {
    account : AccountId;
    stage : Stage;
    dpd : Nat;
    sinceDay : Day;
    sinceBlock : Nat;
    unlikelyToPay : Bool;
    restructured : Bool;
    collector : ?Principal;
    promise : ?{ amount : Nat; by : Day };
    suspenseHeld : Nat;
    writtenOff : Nat;
    recovered : Nat;
    actions : Nat;
    lastActionDay : ?Day;
  };
}
