/// SettlementTypes.mo; settlement: settlement on the journal.
///
/// A scheme's participants, their positions and the movement of money between them are postings
/// in the bank's own book; the same Merkle-committed journal as every deposit; so a position
/// cannot breach its net debit cap even if the code above it is wrong: the cap is the journal's
/// numeric limit on the participant's position sub-ledger, and admission refuses the posting.
/// A payment is the journal's two-phase posting (reserve on prepare, post on fulfil, void on
/// reject, error or expiry); a settlement window accumulates committed payments and settles as
/// **one journal batch** (INV-P2) whose net positions sum to zero per currency (INV-P1).
///
/// The reference vocabulary is Mojaloop central-ledger v20's: its 16 transfer states, 7 window
/// states, 7 settlement states, 12 bulk-transfer and 11 bulk-processing states, and its 10 ledger
/// entry types, which here are the `sourceRef.kind` of the postings. The mapping table is
/// `TRANSFER_STATE_MAP` below; every state is reached in `test/Settlement.test.mo` or named there
/// as unreachable with the reason.

import Text "mo:core/Text";

module {

  public type SchemeId = Text;
  public type ParticipantId = Nat;      // the bank block of #participantRegistered
  public type TransferId = Nat;         // the bank block of #transferPrepared
  public type WindowId = Nat;           // the bank block of #windowOpened
  public type SettlementId = Nat;       // the bank block of #settlementOpened
  public type BulkId = Nat;             // the bank block of #bulkReceived

  /// What the scheme settles by: Mojaloop's settlement-model dimensions.
  public type Granularity = { #gross; #net };
  public type Interchange = { #bilateral; #multilateral };
  public type Delay = { #immediate; #deferred };

  public type Scheme = {
    id : SchemeId;
    granularity : Granularity;
    interchange : Interchange;
    delay : Delay;
    /// The hub's reconciliation account: what prefunding moves against.
    reconciliation : Text;
    /// The hub's fee income account and the interchange fee in basis points of a payment.
    feeIncome : Text;
    interchangeBps : Nat;
    hubFeeBps : Nat;
    /// The alarm at this percentage of a position's cap raises a recorded event; the cap itself is
    /// the engine's.
    alarmPercent : Nat;
    declaredAt : Nat;
  };

  /// A participant's accounts in one currency: every one a product account, every one a
  /// sub-ledger under a control account of the journal.
  public type ParticipantAccounts = {
    currency : Text;
    /// The intraday exposure; its net debit cap is the numeric limit on this account.
    position : Nat;
    /// Prefunded; `#debitsNotExceedCredits` by its product.
    settlement : Nat;
    /// Where the interchange fees this participant earns are credited.
    feeReceivable : Nat;
  };

  public type Participant = {
    id : ParticipantId;
    party : Nat;
    bic : Text;
    scheme : SchemeId;
    accounts : [ParticipantAccounts];
    active : Bool;
  };

  /// Mojaloop's sixteen transfer states. `TRANSFER_STATE_MAP` says what each is here.
  public type TransferState = {
    #receivedPrepare; #reserved; #receivedFulfil; #committed; #failed; #reservedTimeout;
    #receivedReject; #abortedRejected; #receivedError; #abortedError; #expiredPrepared;
    #expiredReserved; #invalid; #reservedForwarded; #receivedFulfilDependent; #settled;
  };

  /// Each reference state as (what the journal holds, what the payment record says), and whether
  /// it is reached here. The unreachable ones are unreachable by construction: a prepare that
  /// validates is reserved in the same message, so nothing is ever "prepared and not reserved".
  public let TRANSFER_STATE_MAP : [(Text, Text, Text, Bool)] = [
    ("RECEIVED_PREPARE", "none yet", "prepare accepted, recorded before the reservation in the same message", true),
    ("RESERVED", "pending", "the payer's position debited pending, the payee's credited pending", true),
    ("RECEIVED_FULFIL", "pending", "fulfil accepted, recorded before the post in the same message", true),
    ("COMMITTED", "posted", "the pending posted; the payment is in its window", true),
    ("FAILED", "none", "the reservation refused by the journal — the cap, a closed account, a currency", true),
    ("RESERVED_TIMEOUT", "pending", "the fulfil deadline passed; the next sweep voids", true),
    ("RECEIVED_REJECT", "pending", "a rejection accepted, recorded before the void", true),
    ("ABORTED_REJECTED", "voided", "the pending voided on rejection", true),
    ("RECEIVED_ERROR", "pending", "an error accepted, recorded before the void", true),
    ("ABORTED_ERROR", "voided", "the pending voided on error", true),
    ("EXPIRED_PREPARED", "—", "unreachable: a prepare that validates is reserved in its own message", false),
    ("EXPIRED_RESERVED", "voided", "the pending expired and voided by the sweep", true),
    ("INVALID", "none", "the prepare refused at validation; recorded as a refused payment", true),
    ("RESERVED_FORWARDED", "pending", "the payee's participant is on another shard: reserved here, forwarded as an inter-shard transfer", true),
    ("RECEIVED_FULFIL_DEPENDENT", "pending", "fulfil received while the forwarded leg is unacknowledged", true),
    ("SETTLED", "posted, in a settled window", "the window the payment is in has settled", true),
  ];

  public type Transfer = {
    id : TransferId;
    scheme : SchemeId;
    payer : ParticipantId;
    payee : ParticipantId;
    currency : Text;
    amount : Nat;
    /// The scheme's reference for the payment: the UETR or the transfer id the message carried.
    reference : Text;
    state : TransferState;
    reservation : ?Nat;       // the journal pending
    posting : ?Nat;           // the journal posting once committed
    window : ?WindowId;
    bulk : ?BulkId;
    /// The original posting this transfer returns, when it is a return.
    correctionOf : ?Nat;
    expiresAt : Nat64;
    lastBlock : Nat;
  };

  public type WindowState = { #open; #closed; #pendingSettlement; #processing; #settled; #aborted; #failed };
  public type SettlementState = { #pendingSettlement; #psTransfersRecorded; #psTransfersReserved; #psTransfersCommitted; #settling; #settled; #aborted };

  public type Window = {
    id : WindowId;
    scheme : SchemeId;
    businessDate : Nat;
    state : WindowState;
    transfers : Nat;
    settlement : ?SettlementId;
    lastBlock : Nat;
  };

  public type NetPosition = { participant : ParticipantId; currency : Text; debits : Nat; credits : Nat };

  public type Settlement = {
    id : SettlementId;
    window : WindowId;
    state : SettlementState;
    /// The net per (participant, currency), once netting is done; INV-P1 holds on this list.
    nets : [NetPosition];
    /// The journal batch's postings once settled.
    postings : [Nat];
    lastBlock : Nat;
  };

  public type BulkState = { #received; #pendingPrepare; #accepted; #processing; #pendingFulfil; #completed; #rejected; #invalid; #expired; #aborting; #expiring; #pendingInvalid };
  public type BulkProcessingState = { #received; #receivedDuplicate; #receivedInvalid; #accepted; #processing; #fulfilDuplicate; #fulfilInvalid; #completed; #rejected; #expired; #aborting };

  public type BulkRequest = { payee : ParticipantId; currency : Text; amount : Nat; reference : Text };

  public type Bulk = {
    id : BulkId;
    scheme : SchemeId;
    payer : ParticipantId;
    reference : Text;
    ttlSeconds : Nat;
    state : BulkState;
    processing : BulkProcessingState;
    requests : [BulkRequest];
    /// How many items have been prepared, and how many have reached a terminal state.
    prepared : Nat;
    done : Nat;
    /// Per item: the typed failure when it failed, by position in `requests`.
    failures : [(Nat, Text)];
    lastBlock : Nat;
  };

  /// The reference's ten ledger entry types, as the `sourceRef.kind` of the postings here.
  public let ENTRY_KINDS : [Text] = [
    "PRINCIPLE_VALUE", "INTERCHANGE_FEE", "HUB_FEE", "POSITION_DEPOSIT", "POSITION_WITHDRAWAL",
    "SETTLEMENT_NET_RECIPIENT", "SETTLEMENT_NET_SENDER", "SETTLEMENT_NET_ZERO", "RECORD_FUNDS_IN", "RECORD_FUNDS_OUT",
  ];

  public type SettlementEvent = {
    #schemeDeclared : { id : SchemeId; granularity : Granularity; interchange : Interchange; delay : Delay; reconciliation : Text; feeIncome : Text; interchangeBps : Nat; hubFeeBps : Nat; alarmPercent : Nat };
    #participantRegistered : { party : Nat; bic : Text; scheme : SchemeId; accounts : [ParticipantAccounts] };
    #participantDeactivated : { participant : ParticipantId };
    #fundsRecorded : { participant : ParticipantId; currency : Text; amount : Nat; direction : { #in_; #out }; posting : Nat };
    #capAlarm : { participant : ParticipantId; currency : Text; exposure : Nat; cap : Nat; alarmPercent : Nat };
    /// The prepare accepted: RECEIVED_PREPARE. Its block is the transfer's id.
    /// `correctionOf` names the journal posting a return reverses (ISO 20022 pacs.004): the return is a
    /// transfer of its own, payee to payer, netted in its window like any other, and its reservation
    /// carries the journal's correction link to the original, which stays untouched.
    #transferPrepared : { scheme : SchemeId; payer : ParticipantId; payee : ParticipantId; currency : Text; amount : Nat; reference : Text; expiresAt : Nat64; bulk : ?BulkId; correctionOf : ?Nat };
    /// The journal reserved it: RESERVED, or RESERVED_FORWARDED when the payee is on another shard.
    #transferReserved : { transfer : TransferId; reservation : Nat; forwarded : Bool };
    /// The journal refused the reservation: FAILED, with the journal's reason.
    #transferFailed : { transfer : TransferId; reason : Text };
    /// A fulfil received while the forwarded leg is unacknowledged: RECEIVED_FULFIL_DEPENDENT.
    #transferFulfilDependent : { transfer : TransferId };
    /// RECEIVED_FULFIL then COMMITTED in one block: the pending posted, the fees posted, the window joined.
    #transferCommitted : { transfer : TransferId; posting : Nat; window : WindowId; interchangeFee : Nat; hubFee : Nat; feePostings : [Nat] };
    /// RECEIVED_REJECT then ABORTED_REJECTED, RECEIVED_ERROR then ABORTED_ERROR, or RESERVED_TIMEOUT
    /// then EXPIRED_RESERVED, in one block: the pending voided.
    #transferAborted : { transfer : TransferId; how : { #rejected; #error; #expired }; reason : Text };
    /// The transfers of a settled window, a chunk at a time: SETTLED.
    #transfersSettled : { settlement : SettlementId; transfers : [TransferId] };
    #windowOpened : { scheme : SchemeId; businessDate : Nat };
    #windowStateChanged : { window : WindowId; to : WindowState; reason : Text };
    #settlementOpened : { window : WindowId };
    #settlementStateChanged : { settlement : SettlementId; to : SettlementState; nets : [NetPosition]; postings : [Nat]; reason : Text };
    #bulkReceived : { scheme : SchemeId; payer : ParticipantId; reference : Text; ttlSeconds : Nat; requests : [BulkRequest] };
    #bulkStateChanged : { bulk : BulkId; to : BulkState; processing : BulkProcessingState; prepared : Nat; done : Nat; failures : [(Nat, Text)] };
  };

  public type SettlementError = {
    #UnknownScheme : { scheme : SchemeId };
    #SchemeExists : { scheme : SchemeId };
    #InvalidScheme : { reason : Text };
    #UnknownParticipant : { participant : ParticipantId };
    #ParticipantInactive : { participant : ParticipantId };
    #ParticipantExists : { party : Nat; scheme : SchemeId };
    #NoAccountsIn : { participant : ParticipantId; currency : Text };
    #InvalidParticipant : { reason : Text };
    #UnknownTransfer : { transfer : TransferId };
    #TransferNotIn : { transfer : TransferId; state : Text; expected : Text };
    #InvalidTransfer : { reason : Text };
    #DuplicateReference : { reference : Text; transfer : TransferId };
    #UnknownWindow : { window : WindowId };
    #WindowNotIn : { window : WindowId; state : Text; expected : Text };
    #NoOpenWindow : { scheme : SchemeId; businessDate : Nat };
    #UnknownSettlement : { settlement : SettlementId };
    #SettlementNotIn : { settlement : SettlementId; state : Text; expected : Text };
    /// INV-P1: a netting whose positions do not sum to zero in a currency.
    #NettingNotConserved : { currency : Text; sum : Int };
    #UnknownBulk : { bulk : BulkId };
    #BulkNotIn : { bulk : BulkId; state : Text; expected : Text };
    #InvalidBulk : { reason : Text };
  };

  public func transferStateName(s : TransferState) : Text {
    switch (s) {
      case (#receivedPrepare) "RECEIVED_PREPARE"; case (#reserved) "RESERVED"; case (#receivedFulfil) "RECEIVED_FULFIL"; case (#committed) "COMMITTED";
      case (#failed) "FAILED"; case (#reservedTimeout) "RESERVED_TIMEOUT"; case (#receivedReject) "RECEIVED_REJECT"; case (#abortedRejected) "ABORTED_REJECTED";
      case (#receivedError) "RECEIVED_ERROR"; case (#abortedError) "ABORTED_ERROR"; case (#expiredPrepared) "EXPIRED_PREPARED"; case (#expiredReserved) "EXPIRED_RESERVED";
      case (#invalid) "INVALID"; case (#reservedForwarded) "RESERVED_FORWARDED"; case (#receivedFulfilDependent) "RECEIVED_FULFIL_DEPENDENT"; case (#settled) "SETTLED";
    }
  };
  public func windowStateName(s : WindowState) : Text {
    switch (s) { case (#open) "OPEN"; case (#closed) "CLOSED"; case (#pendingSettlement) "PENDING_SETTLEMENT"; case (#processing) "PROCESSING"; case (#settled) "SETTLED"; case (#aborted) "ABORTED"; case (#failed) "FAILED" }
  };
  public func settlementStateName(s : SettlementState) : Text {
    switch (s) { case (#pendingSettlement) "PENDING_SETTLEMENT"; case (#psTransfersRecorded) "PS_TRANSFERS_RECORDED"; case (#psTransfersReserved) "PS_TRANSFERS_RESERVED"; case (#psTransfersCommitted) "PS_TRANSFERS_COMMITTED"; case (#settling) "SETTLING"; case (#settled) "SETTLED"; case (#aborted) "ABORTED" }
  };
  public func bulkStateName(s : BulkState) : Text {
    switch (s) { case (#received) "RECEIVED"; case (#pendingPrepare) "PENDING_PREPARE"; case (#accepted) "ACCEPTED"; case (#processing) "PROCESSING"; case (#pendingFulfil) "PENDING_FULFIL"; case (#completed) "COMPLETED"; case (#rejected) "REJECTED"; case (#invalid) "INVALID"; case (#expired) "EXPIRED"; case (#aborting) "ABORTING"; case (#expiring) "EXPIRING"; case (#pendingInvalid) "PENDING_INVALID" }
  };
  public func bulkProcessingName(s : BulkProcessingState) : Text {
    switch (s) { case (#received) "RECEIVED"; case (#receivedDuplicate) "RECEIVED_DUPLICATE"; case (#receivedInvalid) "RECEIVED_INVALID"; case (#accepted) "ACCEPTED"; case (#processing) "PROCESSING"; case (#fulfilDuplicate) "FULFIL_DUPLICATE"; case (#fulfilInvalid) "FULFIL_INVALID"; case (#completed) "COMPLETED"; case (#rejected) "REJECTED"; case (#expired) "EXPIRED"; case (#aborting) "ABORTING" }
  };

  public let MAX_BIC_BYTES : Nat = 11;
  public let MAX_REFERENCE_BYTES : Nat = 64;
  public let MAX_BULK_ITEMS : Nat = 1_000;
  /// The longest a reservation lives before the sweep voids it, in seconds.
  public let MAX_TRANSFER_TTL_SECONDS : Nat = 86_400;

  /// ISO 9362: four institution characters, two country letters, two location characters, an
  /// optional three-character branch; the BICFI pattern of the ISO 20022 schemas.
  public func validBic(b : Text) : Bool {
    let cs = Text.toArray(b);
    let n = cs.size();
    if (n != 8 and n != 11) return false;
    func alnum(c : Char) : Bool { (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') };
    func alpha(c : Char) : Bool { c >= 'A' and c <= 'Z' };
    var i = 0;
    while (i < n) {
      let ok = if (i == 4 or i == 5) alpha(cs[i]) else alnum(cs[i]);
      if (not ok) return false;
      i += 1;
    };
    true
  };
}
