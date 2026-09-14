/// AlertTypes.mo; an alert is a finding with a review.
///
/// A monitoring rule that is met produces a finding (`MonitoringTypes.Finding`); an alert is that
/// finding **recorded**; in a bank block, at posting time for the cheap rules and by the
/// end-of-day batch for the window rules; and then reviewed by compliance under maker-checker:
/// cleared with a reason, or escalated to a suspicious-transaction report. Every step is a block,
/// so the trail is the log. A report to the financial intelligence unit (EMLCU under Egypt's Law
/// 80 of 2002) is produced **from an escalated alert and nothing else**: the same cited postings,
/// the same rule and version, read back from the blocks.
///
/// An alert is opened once. Its key is the finding; rule, version, account, day, cited postings;
/// and a second finding with the same key (a retried end-of-day chunk, a query re-run) opens
/// nothing, which is what lets the batch re-derive a chunk after a crash without a second alert.

import Text "mo:core/Text";

import MT "MonitoringTypes";

module {

  public type AlertId = Nat;   // the bank block index of #alertOpened

  public type Source = { #posting; #endOfDay };

  public type Status = {
    #open;
    #cleared : { reason : Text; at : Nat };
    #escalated : { reportRef : Text; at : Nat };
  };

  public type Alert = {
    id : AlertId;
    finding : MT.Finding;
    source : Source;
    openedAt : Nat;
    status : Status;
  };

  public type AlertEvent = {
    #alertOpened : { finding : MT.Finding; source : Source };
    #alertCleared : { alert : AlertId; reason : Text };
    #alertEscalated : { alert : AlertId; reportRef : Text };
  };

  public type AlertError = {
    #UnknownAlert : { alert : AlertId };
    #AlertNotOpen : { alert : AlertId; status : Text };
    #AlertNotEscalated : { alert : AlertId; status : Text };
    #InvalidReview : { reason : Text };
  };

  /// The suspicious-transaction report, as the escalated alert determines it: nothing in it comes
  /// from anywhere but the alert's blocks and the postings it cites.
  public type CitedPosting = {
    posting : Nat;
    valueDate : Nat;
    postingDate : Nat;
    legs : Nat;
    /// Debits and credits on the reported account in that posting, from the posting record.
    debits : Nat;
    credits : Nat;
    sourceKind : Text;
  };

  public type SuspiciousTransactionReport = {
    alert : AlertId;
    rule : MT.RuleId;
    version : Nat;
    ruleText : Text;
    account : Nat;
    /// The account's identifier as the bank issued it; an account number, never a name.
    identifier : Text;
    currency : Text;
    day : Nat;
    detail : Text;
    postings : [CitedPosting];
    openedAt : Nat;
    escalatedAt : Nat;
    reportRef : Text;
  };

  public let MAX_REASON_BYTES : Nat = 512;
  public let MAX_REPORT_REF_BYTES : Nat = 128;

  public func statusText(s : Status) : Text {
    switch (s) { case (#open) "open"; case (#cleared(_)) "cleared"; case (#escalated(_)) "escalated" }
  };

  public func sourceText(s : Source) : Text { switch (s) { case (#posting) "posting"; case (#endOfDay) "endOfDay" } };

  public func textFits(t : Text, max : Nat) : Bool { let n = Text.encodeUtf8(t).size(); n > 0 and n <= max };
}
