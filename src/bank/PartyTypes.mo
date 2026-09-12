/// PartyTypes.mo — the party / CIF and KYC vocabulary.
///
/// The design rule this file exists to enforce is stated before the types:
///
///   **No plaintext personal data is ever written to a block.**
///
/// The replicated log holds commitments, states, dates and decisions. Plaintext
/// lives in an institution-held encrypted record, and the canister's job is to
/// *verify* personal data it never holds. Egypt's Personal Data Protection Law
/// 151/2020 and the GDPR both require data minimisation and contemplate erasure;
/// an append-only Merkle-committed log on a replicated subnet is the worst
/// possible place for a national identity number, and a commitment is the only
/// shape of it that can be published to a regulator without a redaction pass and
/// erased by destroying the off-chain record.
///
/// Every field that could identify a person is therefore a `Commitment`. The
/// per-party salt is in the log on purpose: without it, a commitment over an
/// Egyptian national identity number is a dictionary attack, because that space
/// is small and structured. The salt is worthless without the plaintext.

import Principal "mo:core/Principal";

import JT "mo:journal/JournalTypes";
import Iban "Iban";

module {

  public type Day = JT.Day;

  /// A 32-byte domain-separated SHA-256 commitment. See `Commitments.mo`.
  public type Commitment = Blob;

  /// Party identifier: the bank block index of the `#partyCreated` event.
  public type PartyId = Nat;

  public type PartyKind = { #natural; #legal };

  public type Lifecycle = { #prospect; #pendingKyc; #active; #dormant; #blocked; #closed };

  /// Customer due diligence level (FATF Recommendation 10).
  public type CddLevel = { #simplified; #standard; #enhanced };

  public type RiskRating = { #low; #medium; #high };

  /// A named field of the party record, held as a commitment. `name` is a
  /// non-personal label ("nationalId", "passport", "dateOfBirth", "address",
  /// "legalName"); `commit` is the commitment over the value.
  public type FieldCommit = { name : Text; commit : Commitment };

  /// A document in the register: its kind, a commitment to its content, and the
  /// dates that make it expire. No document bytes are stored.
  public type DocumentRef = {
    kind : Text;                 // "nationalId", "passport", "commercialRegister", ...
    commit : Commitment;
    issued : Day;
    expires : ?Day;
  };

  public type RelationKind = {
    #guarantor; #authorisedSignatory; #beneficialOwner; #director;
    #spouse; #parent; #child; #groupMember; #other : Text;
  };

  public type Relationship = { kind : RelationKind; other : PartyId };

  // ─── Screening ─────────────────────────────────────────────────────────────

  /// A committed screening list: a sorted Merkle tree over normalised entries.
  /// `root` commits the whole list, `count` is its size and `normalisation`
  /// names the rule set the entries were normalised by, so a claim about a
  /// version is a claim about exact bytes.
  public type ScreeningList = {
    version : Text;
    root : Commitment;
    count : Nat;
    normalisation : Text;
    committedAtBlock : Nat;
  };

  /// Where a party stands against the lists.
  ///   #unscreened    never screened
  ///   #clear         proven absent from `listVersion` by an adjacency proof,
  ///                  and the attested fuzzy pass found nothing
  ///   #hit           a match is open and money movement is blocked
  ///   #cleared       a hit was examined and dismissed, with a reason
  ///   #confirmed     a hit was confirmed; the party is blocked
  ///   #rescreenDue   a newer list exists and the party's screening is stale
  public type ScreeningState = {
    #unscreened;
    #clear : { listVersion : Text; at : Nat };
    #hit : { listVersion : Text; matches : Nat; at : Nat };
    #cleared : { listVersion : Text; at : Nat; reason : Text };
    #confirmed : { listVersion : Text; at : Nat };
    #rescreenDue : { since : Text };
  };

  /// An adjacency (non-membership) proof: the two neighbouring leaves that
  /// bracket the subject in the sorted list, each with its inclusion path. This
  /// is the mechanism Certificate Transparency uses for a consistency claim and
  /// Revocation Transparency for non-membership.
  public type AdjacencyProof = {
    /// The normalised entry immediately below the subject, or null when the
    /// subject sorts before the first entry.
    lower : ?{ entry : Blob; index : Nat; path : [Blob] };
    /// The entry immediately above, or null when it sorts after the last.
    upper : ?{ entry : Blob; index : Nat; path : [Blob] };
  };

  /// The attested fuzzy pass. The chain guarantees attribution and
  /// tamper-evidence, not that the matching was good — a distinction that
  /// belongs in the record, not only in a design note.
  public type ScreeningDecision = {
    party : PartyId;
    listVersion : Text;
    listRoot : Commitment;
    decision : { #clear; #hit : { matches : Nat }; #cleared : { reason : Text }; #confirmed };
    screener : Principal;
    justificationCommit : Commitment;
  };

  // ─── Organisation ──────────────────────────────────────────────────────────

  public type StaffStatus = { #active; #inactive };

  public type Staff = {
    principal_ : Principal;
    book : Text;                 // the office the staff member belongs to
    title : Text;
    status : StaffStatus;
    addedAtBlock : Nat;
  };

  // ─── Extension schemas ────────────────────────────────────

  /// A typed extension field. `#commitment` is the shape a personal field takes,
  /// so an extension cannot be used to smuggle plaintext into a block.
  public type FieldType = {
    #text : { maxBytes : Nat };
    #integer : { min : Int; max : Int };
    #date;
    #enumerated : [Text];
    #boolean;
    #commitment;
  };

  public type FieldDef = { name : Text; fieldType : FieldType; required : Bool };

  public type EntityKind = { #party; #collateral };

  public type ExtensionSchema = {
    id : Text;
    entity : EntityKind;
    fields : [FieldDef];
    registeredAtBlock : Nat;
  };

  public type FieldValue = {
    #text : Text;
    #integer : Int;
    #date : Day;
    #enumerated : Text;
    #boolean : Bool;
    #commitment : Commitment;
  };

  public type ExtensionValue = { schema : Text; name : Text; value : FieldValue };

  // ─── Collateral and guarantees ────────────────────────────

  public type CollateralKind = {
    #cashDeposit;
    #property;
    #vehicle;
    #securities;
    /// A title held in the estate's own land registry, pledged and enforceable
    /// through the DvP core's two-phase path rather than through a legal process
    /// plus a reconciliation.
    #tokenisedTitle : { registry : Principal; tokenId : Nat };
    #other : Text;
  };

  public type Valuation = {
    amount : Nat;                // minor units of `currency`
    currency : JT.Currency;
    asOf : Day;
    source : Text;
    /// Percentage points withheld from the valuation, 0..100.
    haircut : Nat;
  };

  public type CollateralId = Nat;   // the bank block index of #collateralRegistered

  public type Collateral = {
    id : CollateralId;
    party : PartyId;
    kind : CollateralKind;
    valuation : Valuation;
    descriptionCommit : Commitment;
    registeredAtBlock : Nat;
    released : Bool;
  };

  /// An allocation of collateral value to a facility. The sum of allocations
  /// against one collateral may never exceed its haircut value.
  public type Allocation = { collateral : CollateralId; facility : Text; amount : Nat };

  // ─── Authentication ────────────────────────────────────────

  /// An OIDC key set, pinned in a block. A deployment with HTTPS outcalls may
  /// refresh it through a recorded act; a deployment without them runs
  /// pinned-only, and which mode it is in is recorded rather than guessed.
  public type Jwks = { issuer : Text; keys : [{ kid : Text; n : Blob; e : Blob }]; pinnedAtBlock : Nat };

  /// The authenticator assurance a credential is registered at. NIST SP 800-63B:
  /// a passkey with user verification is an AAL2 multi-factor cryptographic
  /// authenticator, which is the mapping that closes row E4 against a standard
  /// rather than against an assertion.
  public type Assurance = { #aal1; #aal2; #aal3 };

  public type Credential = {
    subject : Principal;
    kind : { #passkey : { aaguid : Blob }; #oidc : { issuer : Text; subjectCommit : Commitment } };
    assurance : Assurance;
    registeredAtBlock : Nat;
    revokedAtBlock : ?Nat;
  };

  // ─── Views ─────────────────────────────────────────────────────────────────

  public type PartyView = {
    id : PartyId;
    kind : PartyKind;
    identityCommit : Commitment;
    salt : Blob;
    /// The institution-wide deduplication commitment, when one was supplied.
    dedupCommit : ?Commitment;
    attributes : [FieldCommit];
    lifecycle : Lifecycle;
    cddLevel : CddLevel;
    riskRating : RiskRating;
    pep : Bool;
    screening : ScreeningState;
    reviewDue : Day;
    documents : [DocumentRef];
    relationships : [Relationship];
    extensions : [ExtensionValue];
    book : Text;
    identifiers : [Text];            // account identifiers issued to this party
    createdAtBlock : Nat;
  };

  /// Everything the party layer records. One variant per decision; the bank's
  /// own `Event` carries these under a single `#party` case, so there is one log.
  public type PartyEvent = {
    #partyCreated : { kind : PartyKind; salt : Blob; identityCommit : Commitment; dedupCommit : ?Commitment; attributes : [FieldCommit]; book : Text; cddLevel : CddLevel; riskRating : RiskRating; pep : Bool; reviewDue : Day };
    #partyAmended : { party : PartyId; attributes : [FieldCommit] };
    #partyLifecycleSet : { party : PartyId; to : Lifecycle };
    #partyCddSet : { party : PartyId; level : CddLevel; riskRating : RiskRating; pep : Bool; reviewDue : Day };
    #partyDocumentAdded : { party : PartyId; document : DocumentRef };
    #partyRelationshipAdded : { party : PartyId; relationship : Relationship };
    #partyExtensionSet : { party : PartyId; values : [ExtensionValue] };
    #partyIdentifierIssued : { party : PartyId; identifier : Text };
    #screeningListCommitted : { version : Text; root : Commitment; count : Nat; normalisation : Text };
    #screeningProven : { party : PartyId; listVersion : Text };
    #screeningDecisionRecorded : ScreeningDecision;
    #schemaRegistered : { id : Text; entity : EntityKind; fields : [FieldDef] };
    #collateralRegistered : { party : PartyId; kind : CollateralKind; valuation : Valuation; descriptionCommit : Commitment };
    #collateralRevalued : { collateral : CollateralId; valuation : Valuation };
    #collateralAllocated : { collateral : CollateralId; facility : Text; amount : Nat };
    #collateralReleased : { collateral : CollateralId };
    #staffAdded : { principal_ : Principal; book : Text; title : Text };
    #staffRemoved : { principal_ : Principal };
    #accountFormatSet : Iban.Format;
    #jwksPinned : Jwks;
    #credentialRegistered : Credential;
    #credentialRevoked : { subject : Principal };
    #reviewGraceSet : { days : Nat };
  };

  // ─── Errors ────────────────────────────────────────────────────────────────

  public type PartyError = {
    #UnknownParty : { party : PartyId };
    #PartyNotActive : { party : PartyId; lifecycle : Lifecycle };
    #IllegalTransition : { from : Lifecycle; to : Lifecycle };
    #CddIncomplete : { party : PartyId; level : CddLevel; missing : [Text] };
    #ScreeningBlocks : { party : PartyId; state : ScreeningState };
    #ReviewOverdue : { party : PartyId; due : Day; today : Day; grace : Nat };
    #PartyHasBalance : { party : PartyId; account : JT.AccountCode; currency : JT.Currency; debits : Nat; credits : Nat };
    #PartyHasCollateral : { party : PartyId; allocated : Nat };
    #CommitmentMismatch : { field : Text; recorded : Commitment; recomputed : Commitment };
    #DuplicateIdentity : { existing : PartyId };
    #InvalidCommitment : { reason : Text };
    #InvalidParty : { reason : Text };
    #UnknownList : { version : Text };
    #ListExists : { version : Text };
    #AdjacencyProofFailed : { reason : Text };
    #SubjectIsOnTheList : { listVersion : Text };
    #UnknownSchema : { schema : Text };
    #SchemaExists : { schema : Text };
    #InvalidSchema : { reason : Text };
    #FieldNotInSchema : { schema : Text; name : Text };
    #FieldTypeMismatch : { schema : Text; name : Text; expected : Text };
    #FieldOutOfRange : { schema : Text; name : Text; detail : Text };
    #MissingRequiredField : { schema : Text; name : Text };
    #UnknownCollateral : { collateral : CollateralId };
    #CollateralReleased : { collateral : CollateralId };
    #AllocationExceedsValue : { collateral : CollateralId; haircutValue : Nat; allocated : Nat; requested : Nat };
    #InvalidValuation : { reason : Text };
    #UnknownStaff : { principal_ : Principal };
    #StaffExists : { principal_ : Principal };
    #InvalidIdentifier : { identifier : Text; reason : Text };
    #IdentifierExists : { identifier : Text };
    #UnknownIssuer : { issuer : Text };
    #CredentialExists : { subject : Principal };
    #UnknownCredential : { subject : Principal };
  };

  // ─── Bounds ────────────────────────────────────────────────────────────────

  public let COMMITMENT_BYTES : Nat = 32;
  public let SALT_BYTES : Nat = 32;
  public let MAX_ATTRIBUTES : Nat = 64;
  public let MAX_DOCUMENTS : Nat = 64;
  public let MAX_RELATIONSHIPS : Nat = 64;
  public let MAX_EXTENSIONS : Nat = 64;
  public let MAX_SCHEMA_FIELDS : Nat = 64;
  public let MAX_FIELD_NAME_BYTES : Nat = 64;
  public let MAX_TEXT_FIELD_BYTES : Nat = 512;
  public let MAX_ENUM_VALUES : Nat = 64;
  public let MAX_IDENTIFIERS_PER_PARTY : Nat = 32;
  public let MAX_ADJACENCY_PATH : Nat = 64;
  public let MAX_LIST_ENTRY_BYTES : Nat = 128;
  public let MAX_JWKS_KEYS : Nat = 16;
  /// Days past `reviewDue` before money movement is blocked.
  public let DEFAULT_REVIEW_GRACE_DAYS : Nat = 30;

  public func lifecycleText(l : Lifecycle) : Text {
    switch (l) {
      case (#prospect) "prospect"; case (#pendingKyc) "pendingKyc"; case (#active) "active";
      case (#dormant) "dormant"; case (#blocked) "blocked"; case (#closed) "closed";
    }
  };
};
