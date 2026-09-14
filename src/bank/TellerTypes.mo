/// TellerTypes.mo; branch and teller (branch and teller): cash as counted objects, the vault and the cash network, and the paper
/// instruments a branch handles.
///
/// A teller's drawer is already a till (the product engine, `Till.mo`): a journal sub-ledger that never absorbs a difference.
/// What this layer adds is the count; every cash act carries the denominations tendered, paid or moved, and the
/// fold keeps a per-till and per-vault denomination position the vault teller reconciles against; the teller
/// session (opened with a count against the book, closed with a count, the difference a recorded fact a supervisor
/// resolves, never the teller), the cash network (vault to till and back, branch to branch through cash in transit
/// confirmed by the receiving branch, vault to the central bank and back), and cheques and drafts with a
/// lifecycle: a chequebook's serials issued once, a cheque stopped, presented as a hold on the drawer (the
/// journal's own two-phase posting with the clearing window as its expiry), cleared or returned with its reason,
/// stale and post-dated cheques returned at presentation from the recorded dates; a banker's draft issued against
/// drafts payable, paid on presentation, cancelled by a dual act.

import ProdT "ProductTypes";
import PT "PartyTypes";

module {

  public type Day = Nat;
  public type SessionId = Nat;     // the bank block index of #sessionOpened
  public type MovementId = Nat;    // the bank block index of #cashDispatched

  /// Notes and coins as (face value in minor units, count); the value is the sum of the products.
  public type DenominationSet = { notes : [(Nat, Nat)]; coins : [(Nat, Nat)] };

  public func value(d : DenominationSet) : Nat {
    var v = 0;
    for ((face, count) in d.notes.vals()) v += face * count;
    for ((face, count) in d.coins.vals()) v += face * count;
    v
  };
  public func empty() : DenominationSet { { notes = []; coins = [] } };

  /// The accounts the branch's acts post to besides the tills' own, and the cheque rules.
  public type Policy = {
    overShort : Text;          // where a resolved till difference goes
    cashInTransit : Text;      // cash dispatched and not yet received
    centralBank : Text;        // the reserve account cash is lodged to and drawn from
    draftsPayable : Text;      // the bank's own instruments outstanding
    clearing : Text;           // the clearing house's account, the counterpart of a cheque presented through clearing
    staleDays : Nat;           // a cheque older than this at presentation is returned stale
    clearingWindowDays : Nat;  // the hold a presented cheque places expires after this
  };

  public type Difference = { #balanced; #over : Nat; #short : Nat };

  /// Where a cheque was presented.
  public type Payee = { #inBranch : { till : ProdT.TillId }; #clearing : { house : Text; batch : Text } };
  public type ReturnReason = { #insufficientFunds; #stopped; #signature; #stale; #postDated; #other : Text };
  public func reasonText(r : ReturnReason) : Text {
    switch (r) { case (#insufficientFunds) "insufficientFunds"; case (#stopped) "stopped"; case (#signature) "signature"; case (#stale) "stale"; case (#postDated) "postDated"; case (#other(t)) "other:" # t }
  };

  /// The cash side of a draft: a till's drawer or a customer's account.
  public type CashSource = { #till : ProdT.TillId; #account : ProdT.AccountId };

  public type ChequeState = { #unused; #stopped; #held; #cleared; #returned };
  public func chequeStateText(s : ChequeState) : Text { switch (s) { case (#unused) "unused"; case (#stopped) "stopped"; case (#held) "held"; case (#cleared) "cleared"; case (#returned) "returned" } };
  public type DraftState = { #outstanding; #paid; #cancelled };

  public type TellerEvent = {
    #policySet : Policy;
    #sessionOpened : { till : ProdT.TillId; teller : Principal; opening : DenominationSet; counted : Nat; book : Nat; day : Day };
    #sessionClosed : { session : SessionId; till : ProdT.TillId; closing : DenominationSet; counted : Nat; book : Nat; difference : Difference; day : Day };
    #differenceResolved : { session : SessionId; till : ProdT.TillId; difference : Difference; account : Text; note : Text; day : Day };
    #cashTaken : { till : ProdT.TillId; account : ProdT.AccountId; amount : Nat; tendered : DenominationSet; change : DenominationSet; day : Day };
    #cashPaid : { till : ProdT.TillId; account : ProdT.AccountId; amount : Nat; paid : DenominationSet; day : Day };
    #vaultToTill : { till : ProdT.TillId; book : Text; currency : Text; amount : Nat; denominations : DenominationSet; day : Day };
    #tillToVault : { till : ProdT.TillId; book : Text; currency : Text; amount : Nat; denominations : DenominationSet; day : Day };
    #cashDispatched : { product : ProdT.ProductId; fromBook : Text; toBook : Text; currency : Text; amount : Nat; denominations : DenominationSet; carrier : Text; sealBag : Text; day : Day };
    #cashReceived : { movement : MovementId; denominations : DenominationSet; day : Day };
    #vaultToCentralBank : { product : ProdT.ProductId; book : Text; currency : Text; amount : Nat; denominations : DenominationSet; day : Day };
    #centralBankToVault : { product : ProdT.ProductId; book : Text; currency : Text; amount : Nat; denominations : DenominationSet; day : Day };
    #chequebookIssued : { account : ProdT.AccountId; from : Nat; to : Nat; day : Day };
    #chequeStopped : { account : ProdT.AccountId; serial : Nat; reason : Text; day : Day };
    #chequePresented : { account : ProdT.AccountId; serial : Nat; amount : Nat; payee : Payee; chequeDate : Day; imageHash : Blob; hold : Nat; expiresAt : Day; day : Day };
    #chequeCleared : { account : ProdT.AccountId; serial : Nat; amount : Nat; day : Day };
    #chequeReturned : { account : ProdT.AccountId; serial : Nat; amount : Nat; reason : ReturnReason; day : Day };
    #draftIssued : { serial : Text; payeeCommit : PT.Commitment; amount : Nat; currency : Text; source : CashSource; day : Day };
    #draftPaid : { serial : Text; amount : Nat; to : CashSource; day : Day };
    #draftCancelled : { serial : Text; amount : Nat; refundTo : ProdT.AccountId; day : Day };
  };

  public type TellerError = {
    #NoPolicy;
    #InvalidPolicy : { reason : Text };
    #InvalidDenominations : { reason : Text };
    #CountMismatch : { counted : Nat; amount : Nat };
    #SessionOpen : { till : ProdT.TillId; session : SessionId };
    #NoSession : { till : ProdT.TillId };
    #UnknownSession : { session : SessionId };
    #NotTheHolder : { till : ProdT.TillId };
    #DifferenceNotOpen : { session : SessionId };
    #UnknownMovement : { movement : MovementId };
    #MovementNotInTransit : { movement : MovementId };
    #WrongBook : { wanted : Text; actual : Text };
    #SerialRangeInvalid : { reason : Text };
    #SerialNotIssued : { account : ProdT.AccountId; serial : Nat };
    #ChequeNotIn : { account : ProdT.AccountId; serial : Nat; state : Text; wanted : Text };
    #UnknownDraft : { serial : Text };
    #DraftExists : { serial : Text };
    #DraftNotOutstanding : { serial : Text };
    #InvalidRequest : { reason : Text };
  };

  public type SessionView = {
    id : SessionId; till : ProdT.TillId; teller : Principal; openedBlock : Nat; closedBlock : ?Nat;
    openingCounted : Nat; openingBook : Nat; closingCounted : ?Nat; closingBook : ?Nat; difference : ?Difference; resolvedBlock : ?Nat; day : Day;
  };
  public type ChequeView = { account : ProdT.AccountId; serial : Nat; state : ChequeState; amount : Nat; hold : ?Nat; chequeDate : ?Day; lastBlock : Nat; reason : ?ReturnReason };
  public type DraftView = { serial : Text; state : DraftState; amount : Nat; currency : Text; issuedBlock : Nat; lastBlock : Nat };
  public type MovementView = { id : MovementId; product : ProdT.ProductId; fromBook : Text; toBook : Text; currency : Text; amount : Nat; inTransit : Bool; dispatchedBlock : Nat; receivedBlock : ?Nat };
}
