/// PaymentsTypes.mo; ISO 20022 messaging on the journal: the types.
///
/// A **rail** is where messages arrive from: it names the settlement scheme the messages settle
/// in (settlement), the life of a reservation a credit transfer opens, the compliance rules that
/// hold a payment, and the signature scheme its connectors sign with. A **message** is one
/// received business message: parsed (Xml.mo), validated against the schema-derived profile of
/// its family (IsoSchema.mo), read into the one shape the bank acts on (IsoMessages.mo), and
/// recorded; accepted, refused or held; as one block with the hash of its bytes, whatever the
/// verdict (P-4: no posting without a validated message, no message without its audit record).
///
/// The money moves through the settlement layer and nowhere else: a pacs.008 / pacs.009 credit
/// transfer is a settlement transfer keyed on its UETR (prepared, then reserved in the same
/// message); a pacs.002 accepted status fulfils it, a rejected one voids it; a pacs.004 return is a
/// transfer of its own, payee to payer, whose reservation carries the journal's correction link to
/// the original posting, which stays untouched. A compliance hold holds the reservation: the
/// available balance reflects it, the booked balance does not; release posts, rejection voids.

import Text "mo:core/Text";

import ST "SettlementTypes";

module {

  public type RailId = Text;
  public type MessageId = Nat;            // the bank block of #messageReceived

  /// What holds a payment for review: an amount at or above a threshold per currency (minor
  /// units), an agent on a blocked list, a party name carrying a blocked fragment.
  public type HoldRules = { holdAbove : [(Text, Nat)]; blockedBics : [Text]; blockedNameFragments : [Text] };

  /// The connector signature scheme a rail requires: none (the transport authenticates the
  /// caller), or a post-quantum scheme over the message bytes (M-6).
  public type SignatureScheme = { #none; #mayo2; #mldsa44 };

  public type Rail = {
    id : RailId;
    scheme : ST.SchemeId;
    ttlSeconds : Nat;
    hold : HoldRules;
    signatures : SignatureScheme;
    declaredAt : Nat;
  };

  public type ConnectorKey = { rail : RailId; bic : Text; scheme : SignatureScheme; publicKey : Blob; registeredAt : Nat };

  /// The message families the bank reads or emits: the seven of the core set and the twenty-two of the
  /// extended target list, every one with its official schema in
  /// IsoProfiles.mo. `FAMILIES` is the one table their names, namespaces and canonical ordinals
  /// come from.
  public type Family = {
    #pacs008; #pacs009; #pacs002; #pacs004; #camt053; #camt054; #head001;
    #pacs003; #pacs007; #pacs010; #pacs029;
    #pain007; #pain009; #pain010; #pain011; #pain012;
    #camt052; #camt057; #camt060; #camt050; #camt025; #camt026; #camt027; #camt028; #camt087;
    #admi006; #admi007; #admi017; #head002;
    #unknown;
  };

  /// (family, message identifier with version, canonical ordinal). Ordinals are the encoding of the
  /// family in every block: never renumbered, new ones appended.
  public let FAMILIES : [(Family, Text, Nat8)] = [
    (#pacs008, "pacs.008.001.08", 1), (#pacs009, "pacs.009.001.08", 2), (#pacs002, "pacs.002.001.10", 3), (#pacs004, "pacs.004.001.09", 4),
    (#camt053, "camt.053.001.08", 5), (#camt054, "camt.054.001.08", 6), (#head001, "head.001.001.02", 7),
    (#pacs003, "pacs.003.001.08", 8), (#pacs007, "pacs.007.001.10", 9), (#pacs010, "pacs.010.001.04", 10), (#pacs029, "pacs.029.001.02", 11),
    (#pain007, "pain.007.001.10", 12), (#pain009, "pain.009.001.07", 13), (#pain010, "pain.010.001.07", 14), (#pain011, "pain.011.001.07", 15), (#pain012, "pain.012.001.07", 16),
    (#camt052, "camt.052.001.08", 17), (#camt057, "camt.057.001.06", 18), (#camt060, "camt.060.001.05", 19), (#camt050, "camt.050.001.05", 20), (#camt025, "camt.025.001.05", 21),
    (#camt026, "camt.026.001.07", 22), (#camt027, "camt.027.001.07", 23), (#camt028, "camt.028.001.09", 24), (#camt087, "camt.087.001.06", 25),
    (#admi006, "admi.006.001.01", 26), (#admi007, "admi.007.001.01", 27), (#admi017, "admi.017.001.01", 28), (#head002, "head.002.001.01", 29),
  ];

  public type Verdict = { #accepted; #refused; #held };

  public type Issue = { rule : Text; path : Text; detail : Text };

  /// What one message did, transaction by transaction.
  public type Outcome = {
    /// A credit transfer prepared and reserved (`reserved = true`), or prepared and FAILED by the journal (`false`).
    #prepared : { uetr : Text; transfer : Nat; reserved : Bool };
    /// A reserved transfer held for compliance review, with the rule that held it.
    #held : { uetr : Text; transfer : Nat; rule : Text };
    /// A status report fulfilled (posted) the transfer.
    #fulfilled : { uetr : Text; transfer : Nat };
    /// A status report rejected (voided) the transfer, with the reason it carried.
    #rejected : { uetr : Text; transfer : Nat; reason : Text };
    /// A status that moves no money (ACTC, PDNG, ACSP …), recorded against the transfer.
    #acknowledged : { uetr : Text; transfer : Nat; status : Text };
    /// A return: the new transfer, payee to payer, linked to the original's posting; reserved and,
    /// a return being an instruction and not a proposal, posted in the same message (`committed`).
    #returned : { uetr : Text; original : Nat; transfer : Nat; reserved : Bool; committed : Bool };
    /// A transaction refused, with the rule and the reason.
    #refused : { uetr : ?Text; rule : Text; detail : Text };
    // ── the extended target list ──
    /// A reversal (pacs.007, pain.007): a transfer of its own, payee to payer, linked to the original's
    /// posting and posted in the same message, like a return; the reason the reversal carried.
    #reversed : { uetr : Text; original : Nat; transfer : Nat; reserved : Bool; committed : Bool; reason : Text };
    /// A direct-debit mandate's life (pain.009 / 010 / 011 / 012): the mandate is its first block.
    #mandateInitiated : { mandate : Nat; mandateId : Text; creditorAgent : Text; debtorAgent : Text; debtorAccount : Text; sequence : Text; maxAmount : ?Nat; currency : ?Text };
    #mandateAmended : { mandate : Nat; mandateId : Text; maxAmount : ?Nat; currency : ?Text; debtorAccount : Text; reason : Text };
    #mandateCancelled : { mandate : Nat; mandateId : Text; reason : Text };
    #mandateAccepted : { mandate : Nat; mandateId : Text; accepted : Bool; reason : ?Text };
    /// A collection (pacs.003) or an FI direct debit (pacs.010) prepared under its authority: the
    /// mandate or the debit authority that allowed it.
    #collected : { uetr : Text; transfer : Nat; reserved : Bool; authority : Nat; final : Bool };
    /// A multilateral settlement request (pacs.029) opened the window's settlement; the request's
    /// movements are held against the computed nets when netting completes.
    #settlementRequested : { window : Nat; settlement : Nat; cycle : Text; movements : [Movement] };
    /// A reporting request (camt.060): what was asked for and the report the bank answers with.
    #reportRequested : { requestId : Text; kind : Text; account : ?Nat; fromDay : ?Nat; toDay : ?Nat };
    /// A notification to receive (camt.057): an expected incoming payment, matched when it arrives.
    #receiptExpected : { notificationId : Text; itemId : Text; reference : Text; amount : Nat; currency : Text; account : ?Nat };
    #receiptMatched : { notification : Nat; itemId : Text; transfer : Nat };
    /// A liquidity credit transfer (camt.050) between a participant's settlement account and its position.
    #liquidityTransferred : { endToEndId : Text; participant : Nat; currency : Text; amount : Nat; toPosition : Bool; posting : Nat };
    /// An exceptions-and-investigations message (camt.026 / 027 / 028 / 087) recorded against its payment.
    #caseRecorded : { caseId : Text; assignmentId : Text; kind : Text; uetr : ?Text; transfer : ?Nat };
    /// System administration: a resend request (admi.006) and a processing request (admi.017).
    #resendRequested : { reference : Text; messageName : ?Text; message : ?Nat };
    #processingRequested : { requestType : Text; session : ?Text };
    /// A business file header (head.002): the payloads it carried, each ingested as its own message.
    #fileReceived : { payloadId : Text; declared : Nat; messages : [Nat] };
  };

  /// A direct-debit mandate as the register holds it (pain.009 → 012), keyed by (rail, mandate id).
  public type MandateState = { #pending; #active; #cancelled; #rejected; #completed };
  public type Mandate = {
    rail : RailId;
    mandateId : Text;
    mandate : Nat;              // the block of its initiation
    state : MandateState;
    creditorAgent : Text;
    debtorAgent : Text;
    debtorAccount : Text;
    sequence : Text;            // FRST | RCUR | OOFF | FNAL (SequenceType2Code / 3Code)
    maxAmount : ?Nat;
    currency : ?Text;
    collections : Nat;
    lastBlock : Nat;
  };

  /// A participant's standing authority for another institution to debit it by FI direct debit
  /// (pacs.010), granted dual by the debtor participant; without one a pull is refused.
  public type DebitAuthority = { rail : RailId; debtor : ST.ParticipantId; creditorBic : Text; currency : Text; maxAmount : Nat; active : Bool; grantedAt : Nat };

  /// One movement of a multilateral settlement request: the participant, the currency, the amount
  /// and whether the participant is debited or credited.
  public type Movement = { participantBic : Text; currency : Text; amount : Nat; debit : Bool };

  public type Message = {
    id : MessageId;
    rail : RailId;
    family : Family;
    messageId : Text;
    hash : Blob;
    bytes : Nat;
    signer : ?Text;
    verdict : Verdict;
    issues : [Issue];
    outcomes : [Outcome];
    receivedAt : Nat64;
  };

  public type PaymentsEvent = {
    #railDeclared : { id : RailId; scheme : ST.SchemeId; ttlSeconds : Nat; hold : HoldRules; signatures : SignatureScheme };
    #connectorKeyRegistered : { rail : RailId; bic : Text; scheme : SignatureScheme; publicKey : Blob };
    #messageReceived : { rail : RailId; family : Family; messageId : Text; hash : Blob; bytes : Nat; signer : ?Text; verdict : Verdict; issues : [Issue]; outcomes : [Outcome] };
    #holdReleased : { transfer : Nat; reason : Text };
    #holdRejected : { transfer : Nat; reason : Text };
    // ── the extended target list ──
    /// The debtor participant's dual grant (or revocation) of an FI direct-debit authority.
    #debitAuthorityGranted : { rail : RailId; debtor : ST.ParticipantId; creditorBic : Text; currency : Text; maxAmount : Nat };
    #debitAuthorityRevoked : { rail : RailId; debtor : ST.ParticipantId; creditorBic : Text; currency : Text };
    /// The bank's own decision on a pending mandate (dual): the pain.012 is derived from this block.
    #mandateDecided : { rail : RailId; mandateId : Text; accepted : Bool; reason : ?Text };
    /// The verdict on a settlement request's movements once the nets are computed: matched, or not
    /// (the settlement is then aborted with this block's detail).
    #settlementRequestJudged : { settlement : Nat; matched : Bool; detail : Text };
  };

  public type PaymentsError = {
    #UnknownRail : { rail : RailId };
    #RailExists : { rail : RailId };
    #InvalidRail : { reason : Text };
    #UnknownMessage : { message : MessageId };
    #NotHeld : { transfer : Nat };
    #Held : { transfer : Nat; rule : Text };
    #UnknownConnector : { rail : RailId; bic : Text };
    #SignatureRequired : { rail : RailId; scheme : SignatureScheme };
    #BadSignature : { rail : RailId; bic : Text; scheme : SignatureScheme };
    #InvalidKey : { scheme : SignatureScheme; reason : Text };
    #UnknownMandate : { rail : RailId; mandateId : Text };
    #MandateState : { rail : RailId; mandateId : Text; state : Text };
    #InvalidAuthority : { reason : Text };
    #UnknownAuthority : { rail : RailId; debtor : ST.ParticipantId; creditorBic : Text; currency : Text };
  };

  public func familyName(f : Family) : Text { for ((g, n, _) in FAMILIES.vals()) { if (g == f) return n }; "unknown" };

  public func familyOf(namespace : Text) : Family {
    let prefix = "urn:iso:std:iso:20022:tech:xsd:";
    if (not Text.startsWith(namespace, #text prefix)) return #unknown;
    let name = Text.trimStart(namespace, #text prefix);
    for ((g, n, _) in FAMILIES.vals()) { if (n == name) return g };
    #unknown
  };

  public func familyOrd(f : Family) : Nat8 { for ((g, _, o) in FAMILIES.vals()) { if (g == f) return o }; 0 };
  public func familyFromOrd(n : Nat8) : Family { for ((g, _, o) in FAMILIES.vals()) { if (o == n) return g }; #unknown };

  public func mandateStateName(m : MandateState) : Text { switch (m) { case (#pending) "PENDING"; case (#active) "ACTIVE"; case (#cancelled) "CANCELLED"; case (#rejected) "REJECTED"; case (#completed) "COMPLETED" } };
  public func mandateStateOrd(m : MandateState) : Nat8 { switch (m) { case (#pending) 1; case (#active) 2; case (#cancelled) 3; case (#rejected) 4; case (#completed) 5 } };
  public func mandateStateFromOrd(n : Nat8) : MandateState { switch (n) { case 2 #active; case 3 #cancelled; case 4 #rejected; case 5 #completed; case _ #pending } };

  public func verdictName(v : Verdict) : Text { switch (v) { case (#accepted) "ACCEPTED"; case (#refused) "REFUSED"; case (#held) "HELD" } };

  public func schemeName(s : SignatureScheme) : Text { switch (s) { case (#none) "none"; case (#mayo2) "MAYO-2"; case (#mldsa44) "ML-DSA-44" } };

  /// The payment transaction statuses of ISO 20022's ExternalPaymentTransactionStatus1Code this
  /// component acts on, and what each does to the transfer.
  public let STATUS_ACTIONS : [(Text, Text)] = [
    ("ACSC", "fulfil — accepted, settlement completed"),
    ("ACCC", "fulfil — accepted, settlement completed, creditor account credited"),
    ("ACSP", "acknowledge — accepted, settlement in process"),
    ("ACTC", "acknowledge — accepted technical validation"),
    ("ACWC", "acknowledge — accepted with change"),
    ("ACWP", "acknowledge — accepted without posting"),
    ("PDNG", "acknowledge — pending"),
    ("RCVD", "acknowledge — received"),
    ("RJCT", "reject — voids the reservation"),
    ("CANC", "reject — cancelled, voids the reservation"),
  ];

  public let MAX_MESSAGE_ID_BYTES : Nat = 35;
}
