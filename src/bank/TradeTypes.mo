/// TradeTypes.mo; trade finance (trade finance): documentary credits, standbys and demand guarantees, documentary
/// collections and bills as recorded lifecycles under the ICC rules.
///
/// An instrument is an object on the bank log: the block that issued it is its identity, its terms live in that
/// block, and every later act (an amendment, a presentation, an examination, a demand, a payment, a reduction, a
/// release, an expiry) is a block that names it. The fold keeps a fixed row per instrument and per claim under it
/// (a presentation of documents under a credit, a demand under a guarantee, the presentation of a collection),
/// the memoranda that make the contingent book readable, and the messages exchanged with the counterparty bank
/// as hashes on the block; the message is never the truth, the block is. The rules are the ICC's: UCP 600 for
/// documentary credits (examination within five banking days, art. 14(b); a refusal notice stating every
/// discrepancy once, art. 16(c); an amendment needing the beneficiary's consent, art. 10), ISP98 and URDG 758 for
/// undertakings (the supporting statement of art. 15, examination within five business days of art. 20), URC 522
/// for collections (D/P and D/A), the discounting of an accepted bill the corporate lending receivable machinery with an
/// unearned discount unwound straight-line.

import ProdT "ProductTypes";
import PT "PartyTypes";

module {

  public type Day = Nat;
  public type Bps = Nat;
  public type InstrumentId = Nat;   // the bank block index of the issuing / registering / discounting event
  public type ClaimSeq = Nat;       // a claim's ordinal under its instrument, 1-based

  /// The accounts and the rules the trade book posts under. The contingent book is a memorandum pair: every
  /// undertaking outstanding is a debit on its memorandum account against `contingentContra`, so the pair sums to
  /// zero on the balance sheet and the certified report reads the contingent lines from the pair.
  public type Policy = {
    bic : Text;                           // the bank's own BIC, the sender of every outgoing message
    contingentLcs : Text;                 // documentary credits issued or confirmed, outstanding
    contingentGuarantees : Text;          // standbys and demand guarantees outstanding
    contingentCollections : Text;         // items held for collection (no undertaking; memorandum only)
    contingentContra : Text;              // the other side of the memoranda
    marginDeposits : Text;                // the cash margin an applicant or principal lodges, a sub-ledger per instrument (a liability)
    unearnedCommission : Text;            // commission taken at issue and not yet earned
    commissionIncome : Text;              // earned straight-line over the tenor by the batch
    acceptancesPayable : Text;            // a deferred or acceptance undertaking, due at its date
    customersLiabilityAcceptances : Text; // the applicant's matching obligation to the bank
    billsNegotiated : Text;               // documents bought as nominated bank, reimbursed by the issuing bank
    billsDiscounted : Text;               // accepted bills the bank bought
    unearnedDiscount : Text;              // the discount taken and not yet earned
    discountIncome : Text;
    billsRediscounted : Text;             // bills sold on to the central bank or a discount house, a liability while they run
    billLosses : Text;                    // a dishonoured bill bought without recourse
    nostro : Text;                        // the correspondent account a settlement with another bank moves through
    claimProduct : ProdT.ProductId;       // the loan product a paid demand's reimbursement claim is opened under (collections and recovery ages it)
    examinationDays : Nat;                // five banking days (UCP 600 art. 14(b); URDG 758 art. 20)
  };

  public type Rules = { #UCP600; #ISP98; #URDG758; #URC522 };
  public func rulesText(r : Rules) : Text { switch (r) { case (#UCP600) "UCP600"; case (#ISP98) "ISP98"; case (#URDG758) "URDG758"; case (#URC522) "URC522" } };

  /// A document the credit calls for and the checks the examiner performs on it; the ISBP 821 practice as data:
  /// each check is an identifier from the bank's checklist (`INV-AMOUNT`, `TRANS-ONBOARD-DATE`, `INS-COVER-110`…);
  /// the examiner records every check's result and the decision must follow from them.
  public type DocumentKind = { #invoice; #transport; #insurance; #origin; #packing; #inspection; #draft; #other : Text };
  public func documentKindText(k : DocumentKind) : Text {
    switch (k) { case (#invoice) "invoice"; case (#transport) "transport"; case (#insurance) "insurance"; case (#origin) "origin"; case (#packing) "packing"; case (#inspection) "inspection"; case (#draft) "draft"; case (#other(t)) "other:" # t }
  };
  public type RequiredDocument = { kind : DocumentKind; copies : Nat; checks : [Text] };

  /// How the credit is available (UCP 600 art. 6(b)).
  public type Availability = { #sight; #deferred : { days : Nat }; #acceptance : { days : Nat }; #negotiation };
  public func availabilityText(a : Availability) : Text {
    switch (a) { case (#sight) "sight"; case (#deferred(d)) "deferred:" # debug_show d.days; case (#acceptance(d)) "acceptance:" # debug_show d.days; case (#negotiation) "negotiation" }
  };

  public type DocumentaryTerms = {
    documents : [RequiredDocument];
    latestShipment : ?Day;
    presentationDays : Nat;      // after shipment, at most 21 (art. 14(c)) and never after expiry
    partialShipments : Bool;
    transhipment : Bool;
    incoterm : ?Text;            // three letters from the Incoterms 2020 list
    availableBy : Availability;
    portOfLoading : Text;
    portOfDischarge : Text;
    goods : Text;
  };

  /// The bank's role under a documentary credit.
  public type LcRole = { #issuing; #advising; #confirming };
  public func lcRoleText(r : LcRole) : Text { switch (r) { case (#issuing) "issuing"; case (#advising) "advising"; case (#confirming) "confirming" } };

  public type GuaranteeKind = { #standby; #demandGuarantee; #counterGuarantee };
  public func guaranteeKindText(k : GuaranteeKind) : Text { switch (k) { case (#standby) "standby"; case (#demandGuarantee) "demandGuarantee"; case (#counterGuarantee) "counterGuarantee" } };

  public type CollectionRole = { #remitting; #collecting };
  public type CollectionTerms = { #DP; #DA : { tenorDays : Nat } };

  /// A reference to a document: its kind and the SHA-256 of its image.
  public type DocumentRef = { kind : DocumentKind; hash : Blob };

  /// The party on the other side: one of the bank's own customers, or a name and a BIC at another bank.
  public type Counterparty = { #party : { party : PT.PartyId; account : ProdT.AccountId }; #external : { name : Text; bic : Text; account : Text } };

  /// The kinds of instrument, with the terms fixed at issue.
  public type LetterOfCredit = {
    role : LcRole;
    applicant : Counterparty;             // our customer when we issue (the margin is lodged from its account and a payment beyond the margin drawn from it)
    beneficiary : Counterparty;           // our customer when we advise or confirm
    counterpartyBank : Text;              // the advising bank (we issue) or the issuing bank (we advise / confirm); a BIC
    terms : DocumentaryTerms;
    tolerance : ?Bps;                     // art. 30(a): about / approximately, ten per cent unless the credit says otherwise
    marginBps : Bps;                      // the cash margin lodged from the applicant's account at issue
    facility : ?Nat;                      // the facility the undertaking counts against
    commissionBps : Bps;                  // issuance commission on the face, per annum, taken at issue and earned over the tenor
    reference : Text;                     // the credit number (field 20)
  };
  public type Guarantee = {
    kind : GuaranteeKind;
    rules : Rules;                        // #ISP98 or #URDG758
    principal : PT.PartyId;
    principalAccount : ProdT.AccountId;
    beneficiary : Counterparty;
    counterpartyBank : Text;              // the advising or counter-guaranteeing bank, or empty
    wording : Blob;                       // SHA-256 of the guarantee text
    statementRequired : Bool;             // URDG 758 art. 15(a): a supporting statement unless the guarantee excludes it
    reductions : [(Day, Nat)];            // recorded reduction clauses: on the day the amount falls to the figure
    marginBps : Bps;
    facility : ?Nat;
    commissionBps : Bps;
    reference : Text;
  };
  public type Collection = {
    role : CollectionRole;
    terms : CollectionTerms;
    drawer : Counterparty;                // the seller (our customer when remitting)
    drawee : Counterparty;                // the buyer (our customer when collecting)
    counterpartyBank : Text;
    documents : [DocumentRef];
    instructions : Text;
    commissionBps : Bps;                  // flat, taken at settlement
    reference : Text;
  };
  public type Bill = {
    customer : PT.PartyId;
    customerAccount : ProdT.AccountId;    // the proceeds go here, a dishonour under recourse charges back here
    acceptor : Counterparty;
    source : ?{ instrument : InstrumentId; claim : ClaimSeq };  // the accepted claim the bill arises from, when it does
    discountBps : Bps;                    // per annum on the face to maturity
    recourse : Bool;
    reference : Text;
  };

  public type Kind = {
    #letterOfCredit : LetterOfCredit;
    #guarantee : Guarantee;
    #collection : Collection;
    #bill : Bill;
  };
  public func kindText(k : Kind) : Text { switch (k) { case (#letterOfCredit(_)) "letterOfCredit"; case (#guarantee(_)) "guarantee"; case (#collection(_)) "collection"; case (#bill(_)) "bill" } };

  /// Where an instrument is in its life.
  public type InstrumentState = { #issued; #advised; #confirmed; #accepted; #paid; #expired; #released; #closed; #protested; #returned; #rediscounted; #matured; #dishonoured };
  public func stateText(s : InstrumentState) : Text {
    switch (s) {
      case (#issued) "issued"; case (#advised) "advised"; case (#confirmed) "confirmed"; case (#accepted) "accepted"; case (#paid) "paid";
      case (#expired) "expired"; case (#released) "released"; case (#closed) "closed"; case (#protested) "protested"; case (#returned) "returned";
      case (#rediscounted) "rediscounted"; case (#matured) "matured"; case (#dishonoured) "dishonoured";
    }
  };
  /// A claim under an instrument: a presentation of documents, a demand, a collection presented for acceptance or payment.
  public type ClaimState = { #presented; #complying; #discrepant; #waived; #refused; #honoured; #rejected; #paid; #accepted; #withdrawn };
  public func claimStateText(s : ClaimState) : Text {
    switch (s) {
      case (#presented) "presented"; case (#complying) "complying"; case (#discrepant) "discrepant"; case (#waived) "waived"; case (#refused) "refused";
      case (#honoured) "honoured"; case (#rejected) "rejected"; case (#paid) "paid"; case (#accepted) "accepted"; case (#withdrawn) "withdrawn";
    }
  };

  /// One check of the ISBP checklist recorded by the examiner: the document, the check, whether it passed, the finding.
  public type CheckResult = { document : DocumentKind; check : Text; passed : Bool; finding : Text };
  /// The examiner's decision on a presentation or a demand. A refusal names every discrepancy (UCP 600 art.
  /// 16(c)(ii)) and what is being done with the documents (art. 16(c)(iii)).
  public type Disposal = { #held; #returned; #heldPendingWaiver; #actingOnInstructions };
  public type Decision = { #complying; #refuse : { discrepancies : [Text]; disposal : Disposal } };

  /// How a complying presentation is honoured (art. 7(a), 8(a)).
  public type Honour = { #sight; #deferred : { due : Day }; #acceptance : { due : Day }; #negotiation : { due : Day } };
  public func honourText(h : Honour) : Text {
    switch (h) { case (#sight) "sight"; case (#deferred(d)) "deferred:" # debug_show d.due; case (#acceptance(d)) "acceptance:" # debug_show d.due; case (#negotiation(d)) "negotiation:" # debug_show d.due }
  };

  /// An amendment to a credit or a guarantee: what changes, and who consented (art. 10(a): issuing bank,
  /// confirming bank if any, and the beneficiary).
  public type Amendment = {
    amount : ?Nat;              // the new face
    expiry : ?Day;
    latestShipment : ?Day;
    other : Text;               // free text carried to field 79 / the tsrv narrative
    consents : [Consent];
  };
  public type Consent = { #beneficiary; #confirmingBank; #applicant; #issuingBank };

  /// The messages an instrument exchanges: SWIFT FIN MT of the 7-series and the ISO 20022 trade-services
  /// undertakings family. `kind` is the MT number or the tsrv identifier; `direction` who sent it.
  public type MessageKind = { #mt : Nat; #tsrv : Nat };
  public type Direction = { #outgoing; #incoming };
  public func messageKindText(k : MessageKind) : Text { switch (k) { case (#mt(n)) "MT" # debug_show n; case (#tsrv(n)) "tsrv." # debug_show n } };

  public type TradeEvent = {
    #policySet : Policy;
    // documentary credits
    #lcIssued : { lc : LetterOfCredit; amount : Nat; currency : Text; expiry : Day; placeOfExpiry : Text; margin : Nat; commission : Nat; book : Text; day : Day };
    #lcAdvised : { lc : LetterOfCredit; amount : Nat; currency : Text; expiry : Day; placeOfExpiry : Text; messageHash : Blob; confirmed : Bool; commission : Nat; book : Text; day : Day };
    #lcAmended : { instrument : InstrumentId; amendment : Amendment; number : Nat; amount : Nat; expiry : Day; day : Day };
    #documentsPresented : { instrument : InstrumentId; claim : ClaimSeq; documents : [DocumentRef]; amount : Nat; shipmentDate : ?Day; presentedOn : Day; deadline : Day; day : Day };
    #presentationExamined : { instrument : InstrumentId; claim : ClaimSeq; checks : [CheckResult]; decision : Decision; day : Day };
    #discrepanciesWaived : { instrument : InstrumentId; claim : ClaimSeq; applicantConsentHash : Blob; day : Day };
    #presentationHonoured : { instrument : InstrumentId; claim : ClaimSeq; amount : Nat; honour : Honour; fromMargin : Nat; day : Day };
    #acceptanceMatured : { instrument : InstrumentId; claim : ClaimSeq; amount : Nat; fromMargin : Nat; day : Day };
    #lcClosed : { instrument : InstrumentId; reason : Text; marginReleased : Nat; day : Day };
    #lcExpired : { instrument : InstrumentId; expiry : Day; marginReleased : Nat; day : Day };
    // undertakings
    #guaranteeIssued : { guarantee : Guarantee; wordingText : Text; amount : Nat; currency : Text; expiry : Day; margin : Nat; commission : Nat; book : Text; day : Day };
    #guaranteeAmended : { instrument : InstrumentId; amendment : Amendment; number : Nat; amount : Nat; expiry : Day; day : Day };
    #demandRecorded : { instrument : InstrumentId; claim : ClaimSeq; demand : DocumentRef; amount : Nat; supportingStatement : Bool; presentedOn : Day; deadline : Day; day : Day };
    #demandExamined : { instrument : InstrumentId; claim : ClaimSeq; checks : [CheckResult]; decision : Decision; day : Day };
    #demandPaid : { instrument : InstrumentId; claim : ClaimSeq; amount : Nat; fromMargin : Nat; fromAccount : Nat; claimAccount : ?ProdT.AccountId; day : Day };
    #guaranteeReduced : { instrument : InstrumentId; from : Nat; to : Nat; day : Day };
    #guaranteeReleased : { instrument : InstrumentId; reason : Text; marginReleased : Nat; day : Day };
    #guaranteeExpired : { instrument : InstrumentId; expiry : Day; marginReleased : Nat; day : Day };
    // collections
    #collectionRegistered : { collection : Collection; amount : Nat; currency : Text; book : Text; day : Day };
    #collectionPresented : { instrument : InstrumentId; claim : ClaimSeq; presentedOn : Day; day : Day };
    #collectionAccepted : { instrument : InstrumentId; claim : ClaimSeq; maturity : Day; day : Day };
    #collectionPaid : { instrument : InstrumentId; claim : ClaimSeq; amount : Nat; commission : Nat; day : Day };
    #collectionProtested : { instrument : InstrumentId; claim : ClaimSeq; reason : Text; day : Day };
    #collectionReturned : { instrument : InstrumentId; reason : Text; day : Day };
    // bills
    #billDiscounted : { bill : Bill; face : Nat; currency : Text; maturity : Day; discount : Nat; proceeds : Nat; book : Text; day : Day };
    #billRediscounted : { instrument : InstrumentId; to : Text; amount : Nat; day : Day };
    #billMatured : { instrument : InstrumentId; face : Nat; day : Day };
    #billDishonoured : { instrument : InstrumentId; face : Nat; chargedBack : Nat; day : Day };
    // messages and the batch
    #tradeMessageRecorded : { instrument : InstrumentId; seq : Nat; kind : MessageKind; direction : Direction; hash : Blob; day : Day };
    #commissionEarned : { instrument : InstrumentId; amount : Nat; cumulative : Nat; day : Day };
    #discountEarned : { instrument : InstrumentId; amount : Nat; cumulative : Nat; day : Day };
  };

  public type TradeError = {
    #NoPolicy;
    #InvalidPolicy : { reason : Text };
    #InvalidTerms : { reason : Text; article : Text };
    #UnknownInstrument : { instrument : InstrumentId };
    #InstrumentNotIn : { instrument : InstrumentId; state : Text; wanted : Text };
    #WrongKind : { instrument : InstrumentId; kind : Text; wanted : Text };
    #Expired : { instrument : InstrumentId; expiry : Day; day : Day; article : Text };
    #LatePresentation : { instrument : InstrumentId; shipped : Day; presented : Day; allowed : Nat; article : Text };
    #ConsentMissing : { instrument : InstrumentId; needed : Text; article : Text };
    #UnknownClaim : { instrument : InstrumentId; claim : ClaimSeq };
    #ClaimNotIn : { instrument : InstrumentId; claim : ClaimSeq; state : Text; wanted : Text };
    #ExaminationLate : { instrument : InstrumentId; claim : ClaimSeq; presented : Day; deadline : Day; day : Day; article : Text };
    #DecisionContradictsChecks : { instrument : InstrumentId; claim : ClaimSeq; failed : [Text]; article : Text };
    #NoticeIncomplete : { instrument : InstrumentId; claim : ClaimSeq; missing : [Text]; article : Text };
    #StatementMissing : { instrument : InstrumentId; article : Text };
    #OverUtilised : { instrument : InstrumentId; available : Nat; asked : Nat; article : Text };
    #MessageMismatch : { reason : Text };
    #BadMessage : { reason : Text };
  };

  // ─── views ──────────────────────────────────────────────────────────────────

  public type InstrumentView = {
    id : InstrumentId; kind : Text; state : Text; rules : Text; role : Text;
    party : PT.PartyId; account : ProdT.AccountId; counterpartyHash : Blob; counterpartyBank : Text;
    amount : Nat; currency : Text; utilised : Nat; outstanding : Nat;
    issuedDay : Day; expiry : Day; facility : ?Nat;
    marginBps : Bps; margin : Nat;
    commissionBps : Bps; commissionTotal : Nat; commissionEarned : Nat;
    tolerance : Bps; claims : Nat; amendments : Nat; messages : Nat;
    termsHash : Blob; lastBlock : Nat; confirmed : Bool; book : Text;
  };
  public type ClaimView = {
    instrument : InstrumentId; seq : ClaimSeq; state : Text; amount : Nat;
    presentedOn : Day; deadline : Day; documentsHash : Blob; checksTotal : Nat; checksFailed : Nat;
    examinedBlock : ?Nat; honour : Text; due : ?Day; settledBlock : ?Nat; claimAccount : ?ProdT.AccountId; supportingStatement : Bool;
  };
  public type MessageView = { instrument : InstrumentId; seq : Nat; kind : Text; direction : Text; hash : Blob; block : Nat; day : Day };
  public type TradeStatus = {
    instruments : Nat; open : Nat; claims : Nat; amendments : Nat; messages : Nat; paid : Nat; expired : Nat;
    contingentLcs : Nat; contingentGuarantees : Nat; contingentCollections : Nat;
  };
}
