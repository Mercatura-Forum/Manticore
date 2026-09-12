/// ISO 20022 Egypt-focused financial hub example for Thebes.
///
/// The canister owns admin state, an active usage-guideline configuration,
/// payment lifecycle state, duplicate indexes, and append-only audit evidence.
/// ISO-specific validation rules live in ISO20022.mo so bank/rail-specific
/// implementation guidelines can be loaded as data.

import Admin "mo:thebes-lib/Admin";
import MemphisAuth "mo:thebes-lib/MemphisAuth";
import Pagination "mo:thebes-lib/Pagination";
import ISO "ISO20022";
import Xml "ISO20022Xml";
import Connector "Connector";
import LegacyMT "LegacyMT";
import Breadth "iso/IsoBreadth";
import MtBridge "iso/MtBridge";
import RuleSets "iso/RuleSets";
import IsoXml "iso/Xml";
import IsoSchema "iso/IsoSchema";
import IsoProfiles "iso/IsoProfiles";
import Oracles "PhaseOracle";
import OrderedIndex "OrderedIndex";
import StableOrderedIndex "StableOrderedIndex";
import Bloom "BloomFilter";
import AuditMMR "AuditMMR";
import InPlaceSha256d "InPlaceSha256d";

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import CertifiedData "mo:core/CertifiedData";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Time "mo:core/Time";

persistent actor ISO20022Hub {

  public type CustomerCreditTransferInitiation = ISO.CustomerCreditTransferInitiation;
  public type Pacs008CreditTransfer = ISO.Pacs008CreditTransfer;
  public type UsageGuideline = ISO.UsageGuideline;
  public type ValidationIssue = ISO.ValidationIssue;
  public type ValidationReport = ISO.ValidationReport;
  public type PhaseVerification = ISO.PhaseVerification;
  public type StatusReport = ISO.StatusReport;
  public type StatementEntry = ISO.StatementEntry;
  public type Pacs009FinancialInstitutionCreditTransfer = ISO.Pacs009FinancialInstitutionCreditTransfer;
  public type CoverPayment = ISO.CoverPayment;
  public type InvestigationMessage = ISO.InvestigationMessage;
  public type RequestToPayMessage = ISO.RequestToPayMessage;
  public type DirectDebitMessage = ISO.DirectDebitMessage;
  public type AdministrativeMessage = ISO.AdministrativeMessage;
  public type ComplianceProfile = ISO.ComplianceProfile;
  public type ComplianceReport = ISO.ComplianceReport;
  public type ConnectorConfig = Connector.Connector;
  public type SignaturePolicy = Connector.SignaturePolicy;
  public type TransportEnvelope = Connector.TransportEnvelope;
  public type TransportRecord = Connector.TransportRecord;
  public type DeliveryAck = Connector.DeliveryAck;
  public type OutboundBatch = Connector.OutboundBatch;
  public type MemphisIdentity = MemphisAuth.Identity;
  public type MemphisAuthError = MemphisAuth.AuthError;
  public type Pain001XmlDecode = Xml.Pain001Decode;
  public type Pacs008XmlDecode = Xml.Pacs008Decode;
  public type Pacs009XmlDecode = Xml.Pacs009Decode;
  public type CoverPaymentXmlDecode = Xml.CoverPaymentDecode;
  public type InvestigationXmlDecode = Xml.InvestigationDecode;
  public type RequestToPayXmlDecode = Xml.RequestToPayDecode;
  public type DirectDebitXmlDecode = Xml.DirectDebitDecode;
  public type AdministrativeXmlDecode = Xml.AdministrativeDecode;
  public type StatusReportXmlDecode = Xml.StatusReportDecode;
  public type StatementXmlDecode = Xml.StatementDecode;
  public type Mt103Field = LegacyMT.Mt103Field;
  public type Mt103Decode = LegacyMT.Mt103Decode;
  public type MtStatementDecode = LegacyMT.StatementDecode;
  public type LegacyPaymentFileDecode = LegacyMT.PaymentFileDecode;
  public type OracleSource = Oracles.OracleSource;
  public type PhaseOracleSpec = Oracles.PhaseOracle;
  public type OrderedIndexInvariantReport = OrderedIndex.InvariantReport;
  public type StableIndexVerifyReport = StableOrderedIndex.VerifyReport;

  public type SubmitXmlResult = {
    #ok : HubPayment;
    #err : ValidationReport;
  };

  public type AuditXmlResult = {
    #ok : AuditRecord;
    #err : ValidationReport;
  };

  public type PaymentXmlBundle = {
    codecVersion : Text;
    pain001Xml : Text;
    pacs008Xml : Text;
    pain002Xml : Text;
    pacs002Xml : ?Text;
    returnXml : ?Text;
    camt054Xml : Text;
  };

  public type TransportSubmitResult = {
    #accepted : TransportRecord;
    #deadLetter : TransportRecord;
  };

  type StatusApplicationResult = {
    paymentId : ?Nat;
    issues : [ValidationIssue];
  };

  public type OracleReadiness = {
    ok : Bool;
    phaseCount : Nat;
    failingCount : Nat;
    generatedAt : Int;
    registryVersion : Text;
    phases : [PhaseVerification];
  };

  public type SecondaryIndexHealth = {
    paymentStatusSize : Nat;
    paymentAccountSize : Nat;
    paymentCreditorAgentSize : Nat;
    outboundQueueSize : Nat;
    settlementQueueSize : Nat;
    paymentStatus : OrderedIndexInvariantReport;
    paymentAccount : OrderedIndexInvariantReport;
    paymentCreditorAgent : OrderedIndexInvariantReport;
    outboundQueue : OrderedIndexInvariantReport;
    settlementQueue : OrderedIndexInvariantReport;
    stablePaymentStatus : StableIndexVerifyReport;
    stablePaymentAccount : StableIndexVerifyReport;
    stablePaymentCreditorAgent : StableIndexVerifyReport;
    stableOutboundQueue : StableIndexVerifyReport;
    stableSettlementQueue : StableIndexVerifyReport;
  };

  public type MemphisTransportSubmitResult = {
    #accepted : TransportRecord;
    #deadLetter : TransportRecord;
    #authErr : MemphisAuthError;
  };

  public type SignatureVerificationRequest = {
    connectorId : Text;
    scheme : Text;
    domain : Text;
    payloadHash : Blob;
    envelopeHash : Blob;
    signature : Blob;
    publicKeyHash : ?Blob;
    traceId : Text;
    remoteId : Text;
  };

  public type SignatureVerificationReport = {
    ok : Bool;
    scheme : Text;
    verifier : Principal;
    signerKeyHash : ?Blob;
    messageHash : Blob;
    signatureHash : Blob;
    issueCount : Nat;
    issues : [ValidationIssue];
  };

  public type IcrcAccount = {
    owner : Principal;
    subaccount : ?Blob;
  };

  public type IcrcTransferFromArgs = {
    spender_subaccount : ?Blob;
    from : IcrcAccount;
    to : IcrcAccount;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type IcrcTransferFromError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type IcrcTransferFromResult = {
    #Ok : Nat;
    #Err : IcrcTransferFromError;
  };

  type IcrcLedger = actor {
    icrc1_balance_of : query (IcrcAccount) -> async Nat;
    icrc2_transfer_from : (IcrcTransferFromArgs) -> async IcrcTransferFromResult;
  };

  public type SettlementLedgerConfig = {
    enabled : Bool;
    ledgerCanister : ?Principal;
    fee : Nat;
    currency : ?Text;
    transferMode : Text;
  };

  public type SettlementParticipantAccount = {
    bicfi : Text;
    account : IcrcAccount;
  };

  public type SettlementRecord = {
    ledgerCanister : Principal;
    ledgerBlockIndex : Nat;
    debtorAgent : Text;
    creditorAgent : Text;
    debtorAccount : IcrcAccount;
    creditorAccount : IcrcAccount;
    amount : ISO.ActiveCurrencyAndAmount;
    fee : Nat;
    transferMode : Text;
    settledAt : Int;
  };

  public type SettlementLiquidityLimit = {
    bicfi : Text;
    maxDebitMinorUnits : Nat;
    reservedDebitMinorUnits : Nat;
    active : Bool;
  };

  public type SettlementLiquidityPosition = {
    bicfi : Text;
    debitLimitMinorUnits : ?Nat;
    reservedDebitMinorUnits : Nat;
    availableDebitMinorUnits : ?Nat;
    queuedPaymentCount : Nat;
  };

  public type SettlementLiquidityCheck = {
    ok : Bool;
    bicfi : Text;
    debitLimitMinorUnits : ?Nat;
    reservedDebitMinorUnits : Nat;
    requestedDebitMinorUnits : Nat;
    reason : ?Text;
  };

  public type SettlementQueueEntry = {
    paymentId : Nat;
    queuedAt : Int;
    updatedAt : Int;
    priority : Nat;
    bypassFifo : Bool;
    debtorAgent : Text;
    creditorAgent : Text;
    amount : ISO.ActiveCurrencyAndAmount;
    reservedDebitMinorUnits : Nat;
    reason : Text;
    status : Text;
  };

  public type SettlementDispatchResult = {
    #dispatched : HubPayment;
    #settled : HubPayment;
    #queued : SettlementQueueEntry;
  };

  public type SettlementOffsetResult = {
    paymentA : HubPayment;
    paymentB : HubPayment;
    netAmountMinorUnits : Nat;
    netDebtorAgent : ?Text;
    netCreditorAgent : ?Text;
    ledgerBlockIndex : ?Nat;
    transferMode : Text;
  };

  public type OperatingDayConfig = {
    currency : Text;
    businessDate : Text;
    phase : Text;
    openedAt : Int;
    cutoffAt : Int;
    closesAt : Int;
    updatedAt : Int;
    active : Bool;
  };

  public type OperatingDayStatus = {
    currency : Text;
    businessDate : ?Text;
    phase : Text;
    now : Int;
    settlementAllowed : Bool;
    reason : ?Text;
    cutoffAt : ?Int;
    closesAt : ?Int;
  };

  public type OperatingDayOpeningBalance = {
    bicfi : Text;
    account : IcrcAccount;
    balance : Nat;
    capturedAt : Int;
  };

  public type EndOfDayParticipantReconciliation = {
    bicfi : Text;
    account : IcrcAccount;
    openingBalance : Nat;
    ledgerBalance : Nat;
    grossCreditMinorUnits : Nat;
    grossDebitMinorUnits : Nat;
    feeDebitMinorUnits : Nat;
    netLedgerDeltaMinorUnits : Int;
    expectedClosingBalance : Int;
    ok : Bool;
    issues : [Text];
  };

  public type EndOfDayStatementRun = {
    id : Nat;
    currency : Text;
    businessDate : Text;
    generatedAt : Int;
    fromTimeInclusive : Int;
    toTimeExclusive : Int;
    paymentCount : Nat;
    entries : [StatementEntry];
    camt053Xml : Text;
    reconciliations : [EndOfDayParticipantReconciliation];
    ok : Bool;
    issueCount : Nat;
    issues : [Text];
  };

  type SignatureVerifier = actor {
    verify_connector_signature : query (SignatureVerificationRequest) -> async SignatureVerificationReport;
  };

  public type DuplicateSignal = {
    uetrBloomMightContain : Bool;
    messageIdBloomMightContain : Bool;
    exactUetrDuplicate : Bool;
    exactMessageIdDuplicate : Bool;
  };

  public type PaymentEvent = {
    at : Int;
    by : Principal;
    event : Text;
    detail : Text;
  };

  public type HubPayment = {
    id : Nat;
    createdAt : Int;
    updatedAt : Int;
    submittedBy : Principal;
    messageId : Text;
    uetr : Text;
    instruction : CustomerCreditTransferInitiation;
    pacs008 : Pacs008CreditTransfer;
    status : Text;
    validationReport : ValidationReport;
    pain002 : StatusReport;
    pacs002 : ?StatusReport;
    returnReport : ?StatusReport;
    auditId : Nat;
    duplicateSignal : DuplicateSignal;
    settlement : ?SettlementRecord;
    history : [PaymentEvent];
  };

  public type ComplianceScreeningRecord = {
    paymentId : Nat;
    screenedAt : Int;
    profileId : Text;
    decision : Text;
    riskScore : Nat;
    findingCount : Nat;
    action : Text;
    report : ComplianceReport;
  };

  public type PaymentView = {
    id : Nat;
    createdAt : Int;
    updatedAt : Int;
    submittedBy : Principal;
    messageId : Text;
    uetr : Text;
    amount : ISO.ActiveCurrencyAndAmount;
    debtorAgent : Text;
    creditorAgent : Text;
    status : Text;
    ok : Bool;
    issueCount : Nat;
    auditId : Nat;
    duplicateSignal : DuplicateSignal;
    settlementLedger : ?Principal;
    settlementBlockIndex : ?Nat;
  };

  public type AuditRecord = {
    id : Nat;
    at : Int;
    caller : Principal;
    parentHash : ?Blob;
    recordHash : Blob;
    rawXmlHash : ?Blob;
    messageKind : Text;
    messageVersion : Text;
    guidelineId : Text;
    businessMessageId : Text;
    uetr : Text;
    ok : Bool;
    issueCount : Nat;
    report : ValidationReport;
  };

  public type AuditView = {
    id : Nat;
    at : Int;
    caller : Principal;
    messageKind : Text;
    messageVersion : Text;
    guidelineId : Text;
    businessMessageId : Text;
    uetr : Text;
    ok : Bool;
    issueCount : Nat;
    rawXmlHash : ?Blob;
  };

  public type AuditTip = {
    count : Nat;
    lastAuditId : ?Nat;
    lastAuditHash : ?Blob;
    merkleRoot : ?Blob;
    mmrRoot : ?Blob;
    mmrLeafCount : Nat;
    mmrPeakCount : Nat;
    guidelineId : Text;
  };

  public type CertifiedAuditSnapshot = {
    capturedAt : Int;
    count : Nat;
    lastAuditId : ?Nat;
    lastAuditHash : ?Blob;
    merkleRoot : ?Blob;
    mmrRoot : ?Blob;
    mmrLeafCount : Nat;
    mmrPeakCount : Nat;
    guidelineId : Text;
    snapshotHash : Blob;
  };

  public type CertifiedParticipantBalance = {
    bicfi : Text;
    account : IcrcAccount;
    ledgerCanister : ?Principal;
    currency : ?Text;
    balance : Nat;
    capturedAt : Int;
    snapshotHash : Blob;
  };

  public type CertifiedDisclosureRoot = {
    version : Text;
    updatedAt : Int;
    auditSnapshotHash : Blob;
    balanceRoot : Blob;
    balanceCount : Nat;
    rootHash : Blob;
  };

  public type CertifiedDisclosureCertificate = {
    certificate : ?Blob;
    root : CertifiedDisclosureRoot;
  };

  public type CertifiedAuditDisclosure = {
    certificate : ?Blob;
    root : CertifiedDisclosureRoot;
    audit : CertifiedAuditSnapshot;
  };

  public type CertifiedBalanceDisclosure = {
    certificate : ?Blob;
    root : CertifiedDisclosureRoot;
    balance : CertifiedParticipantBalance;
  };

  public type ParticipantDirectoryInput = {
    bicfi : Text;
    lei : ?Text;
    displayName : Text;
    country : Text;
    accessTier : Text;
    parentBicfi : ?Text;
    reachable : Bool;
    active : Bool;
    supportedMessageFamilies : [Text];
    notes : Text;
  };

  public type ParticipantDirectoryEntry = {
    bicfi : Text;
    lei : ?Text;
    displayName : Text;
    country : Text;
    accessTier : Text;
    parentBicfi : ?Text;
    reachable : Bool;
    active : Bool;
    settlementAccountConfigured : Bool;
    supportedMessageFamilies : [Text];
    updatedAt : Int;
    notes : Text;
  };

  public type WorkflowEvent = {
    at : Int;
    by : Principal;
    messageKind : Text;
    messageId : Text;
    relatedMessageId : ?Text;
    uetr : ?Text;
    status : Text;
    detail : Text;
    auditId : ?Nat;
  };

  public type WorkflowState = {
    id : Text;
    kind : Text;
    primaryReference : Text;
    status : Text;
    participants : [Text];
    messageIds : [Text];
    uetrs : [Text];
    startedAt : Int;
    updatedAt : Int;
    eventCount : Nat;
    events : [WorkflowEvent];
  };

  public type WorkflowCorrelationResult = {
    ok : Bool;
    workflow : ?WorkflowState;
    audit : AuditRecord;
    report : ValidationReport;
  };

  public type PfmiPrincipleAssessment = {
    principle : Nat;
    title : Text;
    applicability : Text;
    status : Text;
    locus : Text;
    codeEnforceable : Bool;
    oraclePhase : ?Text;
    verifierSurface : [Text];
    evidence : [Text];
    residualGaps : [Text];
  };

  public type AuditProof = {
    auditId : Nat;
    leaf : Blob;
    root : Blob;
    siblings : [Blob];
    leafIndex : Nat;
  };

  public type DuplicateFilterInfo = {
    bits : Nat;
    hashes : Nat;
    uetrFillPermille : Nat;
    messageIdFillPermille : Nat;
    exactUetrIndexSize : Nat;
    exactMessageIdIndexSize : Nat;
    note : Text;
  };

  public type SupportedStandard = {
    name : Text;
    url : Text;
  };

  public type Capability = {
    name : Text;
    status : Text;
    notes : Text;
  };

  public type CheckpointMapEntry = {
    id : Text;
    layer : Text;
    status : Text;
    codeSurface : [Text];
    verifierSurface : [Text];
    currentGate : Text;
    nextGate : Text;
  };

  public type XmlProfileFixture = {
    id : Text;
    profile : Text;
    messageKind : Text;
    direction : Text;
    validity : Text;
    sourceOracle : Text;
    expectedRuleIds : [Text];
    notes : Text;
  };

  public type IntegrationProfilePack = {
    id : Text;
    displayName : Text;
    status : Text;
    guidelineSurface : Text;
    messageFamilies : [Text];
    connectorFormats : [Text];
    legacyInputs : [Text];
    fixturePath : Text;
    notes : Text;
  };

  public type GuidelineProfile = {
    id : Text;
    displayName : Text;
    status : Text;
    guideline : UsageGuideline;
    notes : Text;
    updatedAt : Int;
  };

  public type GuidelineProfileSummary = {
    id : Text;
    displayName : Text;
    status : Text;
    guidelineId : Text;
    notes : Text;
    updatedAt : Int;
    builtin : Bool;
  };

  public type ConnectorGuidelineProfile = {
    connectorId : Text;
    profileId : Text;
    guidelineId : Text;
    updatedAt : Int;
  };

  let egGuidelineProfileId : Text = "EG-DOMESTIC-EDU";
  let cbprGuidelineProfileId : Text = "CBPRPLUS-EDU";
  let sepaSctGuidelineProfileId : Text = "SEPA-SCT-EDU";
  let sepaSctInstGuidelineProfileId : Text = "SEPA-SCT-INST-EDU";
  let sepaSddGuidelineProfileId : Text = "SEPA-SDD-EDU";
  let fedwireGuidelineProfileId : Text = "FEDWIRE-ISO20022-EDU";
  let fednowGuidelineProfileId : Text = "FEDNOW-ISO20022-EDU";
  let bisCrossBorderGuidelineProfileId : Text = "BIS-CPMI-HARMONIZED-CROSSBORDER";
  let customActiveGuidelineProfileId : Text = "CUSTOM-ACTIVE";

  let admin = Admin.init();
  transient let hasher = InPlaceSha256d.Hasher();
  let certifiedDisclosureVersion : Text = "certified-disclosure-v1";
  let zeroCertifiedHash : Blob = Blob.fromArray(Array.tabulate<Nat8>(32, func(_i) { 0 : Nat8 }));

  var defaultGuidelineProfileId : Text = egGuidelineProfileId;
  var guideline : UsageGuideline = ISO.defaultGuideline();
  let customGuidelineProfiles = Map.empty<Text, GuidelineProfile>();
  let connectorGuidelineProfiles = Map.empty<Text, ConnectorGuidelineProfile>();
  var complianceProfile : ComplianceProfile = ISO.defaultComplianceProfile();
  let complianceScreeningRecords = Map.empty<Nat, ComplianceScreeningRecord>();
  // The PSEUDONYM NAMESPACE — a label, frozen for the life of this contract.
  // It decides every institution user's principal; changing it orphans them.
  var memphisGate : MemphisAuth.State = MemphisAuth.initFromCid(921, "thebes-example-iso20022", 1);

  // The WEB ORIGIN of the frontend that submits envelopes here. A DIFFERENT
  // value from the namespace above: Memphis compares this byte-exactly against
  // the origin it minted the token for, and the namespace is not a URL at all.
  // Passing the namespace as the audience makes every verification fail with
  // #Unauthorized, which is what this contract did before it was configurable.
  // Institutions run their own frontend, so it is set with setMemphisAudience.
  var memphisAudience : Text = "https://memphis.mercaturaforum.com";

  var nextPaymentId : Nat = 0;
  let payments = Map.empty<Nat, HubPayment>();
  let paymentByUetr = Map.empty<Text, Nat>();
  let paymentByMessageId = Map.empty<Text, Nat>();
  var uetrBloom : Bloom.Filter = Bloom.empty();
  var messageIdBloom : Bloom.Filter = Bloom.empty();
  var paymentStatusIndex : OrderedIndex.Index = OrderedIndex.empty();
  var paymentAccountIndex : OrderedIndex.Index = OrderedIndex.empty();
  var paymentCreditorAgentIndex : OrderedIndex.Index = OrderedIndex.empty();
  let paymentStatusStableIndex = StableOrderedIndex.empty();
  let paymentAccountStableIndex = StableOrderedIndex.empty();
  let paymentCreditorAgentStableIndex = StableOrderedIndex.empty();

  var settlementEnabled : Bool = false;
  var settlementLedgerCanister : ?Principal = null;
  var settlementFee : Nat = 0;
  var settlementCurrency : ?Text = ?"EGP";
  let settlementParticipantAccounts = Map.empty<Text, IcrcAccount>();
  let settlementDebitLimits = Map.empty<Text, Nat>();
  let settlementQueue = Map.empty<Nat, SettlementQueueEntry>();
  var settlementQueueIndex : OrderedIndex.Index = OrderedIndex.empty();
  let settlementQueueStableIndex = StableOrderedIndex.empty();
  let operatingDayConfigs = Map.empty<Text, OperatingDayConfig>();
  let operatingDayOpeningBalances = Map.empty<Text, [OperatingDayOpeningBalance]>();
  var nextEndOfDayRunId : Nat = 0;
  let endOfDayRuns = Map.empty<Nat, EndOfDayStatementRun>();

  var nextTransportId : Nat = 0;
  let connectors = Map.empty<Text, ConnectorConfig>();
  let transportRecords = Map.empty<Nat, TransportRecord>();
  let remoteIdIndex = Map.empty<Text, Nat>();
  var nextOutboundBatchId : Nat = 0;
  let outboundBatches = Map.empty<Nat, OutboundBatch>();
  var outboundQueueIndex : OrderedIndex.Index = OrderedIndex.empty();
  let outboundQueueStableIndex = StableOrderedIndex.empty();

  var nextAuditId : Nat = 0;
  var lastAuditHash : ?Blob = null;
  var auditMmr : AuditMMR.State = AuditMMR.empty();
  let audits = Map.empty<Nat, AuditRecord>();
  var certifiedAuditSnapshot : CertifiedAuditSnapshot = {
    capturedAt = 0;
    count = 0;
    lastAuditId = null;
    lastAuditHash = null;
    merkleRoot = null;
    mmrRoot = null;
    mmrLeafCount = 0;
    mmrPeakCount = 0;
    guidelineId = guideline.id;
    snapshotHash = zeroCertifiedHash;
  };
  let certifiedParticipantBalances = Map.empty<Text, CertifiedParticipantBalance>();
  var certifiedDisclosureRootState : CertifiedDisclosureRoot = {
    version = certifiedDisclosureVersion;
    updatedAt = 0;
    auditSnapshotHash = zeroCertifiedHash;
    balanceRoot = zeroCertifiedHash;
    balanceCount = 0;
    rootHash = zeroCertifiedHash;
  };
  let participantDirectory = Map.empty<Text, ParticipantDirectoryEntry>();
  let workflowStates = Map.empty<Text, WorkflowState>();
  let workflowByMessageId = Map.empty<Text, Text>();
  let workflowByUetr = Map.empty<Text, Text>();

  // -- Admin ---------------------------------------------------------------
  public shared (msg) func claimOwner() : async Bool {
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    Admin.claimOwner(admin, msg.caller);
  };

  public shared (msg) func transferOwner(newOwner : Principal) : async Bool {
    Admin.transferOwner(admin, msg.caller, newOwner);
  };

  public shared (msg) func addAdmin(who : Principal) : async Bool {
    Admin.addAdmin(admin, msg.caller, who);
  };

  public shared (msg) func removeAdmin(who : Principal) : async Bool {
    Admin.removeAdmin(admin, msg.caller, who);
  };

  public shared (msg) func setPaused(value : Bool) : async Bool {
    Admin.setPaused(admin, msg.caller, value);
  };

  public query func getOwner() : async ?Principal { Admin.getOwner(admin) };
  public query func getAdmins() : async [Principal] { Admin.getAdmins(admin) };
  public query func isPaused() : async Bool { Admin.isPaused(admin) };

  public shared (msg) func setSettlementLedger(config : SettlementLedgerConfig) : async SettlementLedgerConfig {
    Admin.requireAdmin(admin, msg.caller);
    settlementEnabled := config.enabled;
    settlementLedgerCanister := config.ledgerCanister;
    settlementFee := config.fee;
    settlementCurrency := config.currency;
    settlementConfig();
  };

  public query func getSettlementLedger() : async SettlementLedgerConfig {
    settlementConfig();
  };

  public shared (msg) func setSettlementParticipantAccount(bicfi : Text, account : IcrcAccount) : async Bool {
    Admin.requireAdmin(admin, msg.caller);
    if (Text.size(bicfi) == 0) Runtime.trap("bicfi required");
    Map.add(settlementParticipantAccounts, Text.compare, bicfi, account);
    true;
  };

  public query func getSettlementParticipantAccount(bicfi : Text) : async ?IcrcAccount {
    Map.get(settlementParticipantAccounts, Text.compare, bicfi);
  };

  public query func listSettlementParticipantAccounts() : async [SettlementParticipantAccount] {
    Array.map<(Text, IcrcAccount), SettlementParticipantAccount>(
      Iter.toArray(Map.entries(settlementParticipantAccounts)),
      func((bicfi, account)) { { bicfi; account } },
    );
  };

  public query func validateParticipantDirectoryEntry(input : ParticipantDirectoryInput) : async ValidationReport {
    validateParticipantDirectoryInput(input);
  };

  public shared (msg) func upsertParticipantDirectoryEntry(input : ParticipantDirectoryInput) : async ParticipantDirectoryEntry {
    Admin.requireAdmin(admin, msg.caller);
    let report = validateParticipantDirectoryInput(input);
    if (not report.ok) Runtime.trap("invalid participant directory entry");
    let entry = participantDirectoryEntryFromInput(input, Time.now());
    Map.add(participantDirectory, Text.compare, input.bicfi, entry);
    entry;
  };

  public shared (msg) func seedDemoParticipantDirectory() : async [ParticipantDirectoryEntry] {
    Admin.requireAdmin(admin, msg.caller);
    seedDemoParticipantDirectoryCore(Time.now());
    participantDirectoryEntries();
  };

  public query func getParticipantDirectoryEntry(bicfi : Text) : async ?ParticipantDirectoryEntry {
    switch (Map.get(participantDirectory, Text.compare, bicfi)) {
      case (?entry) ?participantDirectoryEntryView(entry);
      case null null;
    };
  };

  public query func listParticipantDirectory(offset : Nat, limit : Nat) : async Pagination.Page<ParticipantDirectoryEntry> {
    Pagination.page<ParticipantDirectoryEntry>(participantDirectoryEntries(), offset, limit);
  };

  public shared (msg) func setSettlementDebitLimit(bicfi : Text, maxDebitMinorUnits : ?Nat) : async SettlementLiquidityLimit {
    Admin.requireAdmin(admin, msg.caller);
    if (Text.size(bicfi) == 0) Runtime.trap("bicfi required");
    switch (maxDebitMinorUnits) {
      case (?limit) Map.add(settlementDebitLimits, Text.compare, bicfi, limit);
      case null ignore Map.delete(settlementDebitLimits, Text.compare, bicfi);
    };
    liquidityLimitView(bicfi);
  };

  public query func getSettlementDebitLimit(bicfi : Text) : async SettlementLiquidityLimit {
    liquidityLimitView(bicfi);
  };

  public query func settlementLiquidityPosition(bicfi : Text) : async SettlementLiquidityPosition {
    liquidityPosition(bicfi);
  };

  public query func listSettlementLiquidityPositions() : async [SettlementLiquidityPosition] {
    let bicfis = Map.empty<Text, Bool>();
    for ((bicfi, _) in Map.entries(settlementDebitLimits)) {
      Map.add(bicfis, Text.compare, bicfi, true);
    };
    for (entry in Map.values(settlementQueue)) {
      if (entry.status == "queued") {
        Map.add(bicfis, Text.compare, entry.debtorAgent, true);
      };
    };
    Array.map<(Text, Bool), SettlementLiquidityPosition>(
      Iter.toArray(Map.entries(bicfis)),
      func((bicfi, _)) { liquidityPosition(bicfi) },
    );
  };

  public query func checkSettlementLiquidity(paymentId : Nat) : async SettlementLiquidityCheck {
    liquidityCheckForPayment(requirePayment(paymentId), null);
  };

  public query func getSettlementQueueEntry(paymentId : Nat) : async ?SettlementQueueEntry {
    Map.get(settlementQueue, Nat.compare, paymentId);
  };

  public query func listSettlementQueue(offset : Nat, limit : Nat) : async Pagination.Page<SettlementQueueEntry> {
    settlementQueuePageFromIds(OrderedIndex.prefix(settlementQueueIndex, "", 0, Map.size(settlementQueue)), offset, limit);
  };

  public query func listSettlementQueueByStatus(status : Text, offset : Nat, limit : Nat) : async Pagination.Page<SettlementQueueEntry> {
    settlementQueuePageFromIds(OrderedIndex.prefix(settlementQueueIndex, OrderedIndex.keyPart(status), 0, Map.size(settlementQueue)), offset, limit);
  };

  public shared (msg) func configureOperatingDay(config : OperatingDayConfig) : async OperatingDayStatus {
    Admin.requireAdmin(admin, msg.caller);
    validateOperatingDayConfig(config);
    let now = Time.now();
    let next = { config with updatedAt = now };
    Map.add(operatingDayConfigs, Text.compare, config.currency, next);
    operatingDayStatusCore(config.currency, now);
  };

  public shared (msg) func openOperatingDay(currency : Text, businessDate : Text, cutoffAt : Int, closesAt : Int) : async OperatingDayStatus {
    Admin.requireAdmin(admin, msg.caller);
    if (Text.size(currency) == 0) Runtime.trap("currency required");
    if (Text.size(businessDate) == 0) Runtime.trap("businessDate required");
    let now = Time.now();
    if (cutoffAt <= now) Runtime.trap("cutoffAt must be in the future");
    if (closesAt <= cutoffAt) Runtime.trap("closesAt must be after cutoffAt");
    let snapshots = await captureOperatingDayOpeningBalances(now);
    Map.add(operatingDayOpeningBalances, Text.compare, currency, snapshots);
    let config = {
      currency;
      businessDate;
      phase = "settlement-window";
      openedAt = now;
      cutoffAt;
      closesAt;
      updatedAt = now;
      active = true;
    };
    Map.add(operatingDayConfigs, Text.compare, currency, config);
    operatingDayStatusCore(currency, now);
  };

  public shared (msg) func setOperatingDayPhase(currency : Text, phase : Text) : async OperatingDayStatus {
    Admin.requireAdmin(admin, msg.caller);
    validateOperatingDayPhase(phase);
    let config = requireOperatingDayConfig(currency);
    let now = Time.now();
    let next = { config with phase; updatedAt = now; active = phase != "closed" };
    Map.add(operatingDayConfigs, Text.compare, currency, next);
    operatingDayStatusCore(currency, now);
  };

  public query func getOperatingDay(currency : Text) : async ?OperatingDayConfig {
    Map.get(operatingDayConfigs, Text.compare, currency);
  };

  public query func operatingDayStatus(currency : Text) : async OperatingDayStatus {
    operatingDayStatusCore(currency, Time.now());
  };

  public query func listOperatingDayOpeningBalances(currency : Text) : async [OperatingDayOpeningBalance] {
    switch (Map.get(operatingDayOpeningBalances, Text.compare, currency)) {
      case (?snapshots) snapshots;
      case null [];
    };
  };

  public shared (msg) func runEndOfDay(currency : Text) : async EndOfDayStatementRun {
    Admin.requireAdmin(admin, msg.caller);
    let config = requireOperatingDayConfig(currency);
    if (not config.active) Runtime.trap("operating day is not active");
    let now = Time.now();
    let eodConfig = { config with phase = "end-of-day"; updatedAt = now };
    Map.add(operatingDayConfigs, Text.compare, currency, eodConfig);
    let run = await runEndOfDayCore(eodConfig, now);
    Map.add(endOfDayRuns, Nat.compare, run.id, run);
    Map.add(operatingDayConfigs, Text.compare, currency, { eodConfig with phase = "reconciled"; active = false; updatedAt = now });
    run;
  };

  public query func getEndOfDayRun(id : Nat) : async ?EndOfDayStatementRun {
    Map.get(endOfDayRuns, Nat.compare, id);
  };

  public query func listEndOfDayRuns(offset : Nat, limit : Nat) : async Pagination.Page<EndOfDayStatementRun> {
    Pagination.page<EndOfDayStatementRun>(Iter.toArray(Map.values(endOfDayRuns)), offset, limit);
  };

  // -- Guideline configuration -------------------------------------------
  public query func getGuideline() : async UsageGuideline { guideline };
  public query func getCrossBorderEducationGuideline() : async UsageGuideline { ISO.crossBorderEducationGuideline() };

  public query func getDefaultGuidelineProfileId() : async Text {
    defaultGuidelineProfileId;
  };

  public query func getDefaultGuidelineProfile() : async GuidelineProfileSummary {
    let profile = requireGuidelineProfile(defaultGuidelineProfileId);
    guidelineProfileSummary(profile, isBuiltinGuidelineProfileId(defaultGuidelineProfileId));
  };

  public query func getGuidelineProfile(profileId : Text) : async ?GuidelineProfile {
    guidelineProfile(profileId);
  };

  public query func listGuidelineProfiles() : async [GuidelineProfileSummary] {
    guidelineProfileSummaries();
  };

  public shared (msg) func setDefaultGuidelineProfile(profileId : Text) : async GuidelineProfileSummary {
    Admin.requireAdmin(admin, msg.caller);
    setDefaultGuidelineProfileCore(profileId);
  };

  public shared (msg) func putGuidelineProfile(profile : GuidelineProfile) : async GuidelineProfileSummary {
    Admin.requireAdmin(admin, msg.caller);
    if (Text.size(profile.id) == 0) Runtime.trap("profile id required");
    if (isBuiltinGuidelineProfileId(canonicalGuidelineProfileId(profile.id))) Runtime.trap("built-in profile id is reserved");
    if (Text.size(profile.guideline.id) == 0) Runtime.trap("guideline id required");
    let stored = { profile with updatedAt = Time.now() };
    Map.add(customGuidelineProfiles, Text.compare, stored.id, stored);
    guidelineProfileSummary(stored, false);
  };

  public shared (msg) func setConnectorGuidelineProfile(connectorId : Text, profileId : Text) : async ConnectorGuidelineProfile {
    Admin.requireAdmin(admin, msg.caller);
    if (Text.size(connectorId) == 0) Runtime.trap("connector id required");
    switch (Map.get(connectors, Text.compare, connectorId)) {
      case null Runtime.trap("connector not found");
      case (?_) {};
    };
    let canonical = canonicalGuidelineProfileId(profileId);
    let profile = requireGuidelineProfile(canonical);
    let selection : ConnectorGuidelineProfile = {
      connectorId;
      profileId = canonical;
      guidelineId = profile.guideline.id;
      updatedAt = Time.now();
    };
    Map.add(connectorGuidelineProfiles, Text.compare, connectorId, selection);
    selection;
  };

  public query func getConnectorGuidelineProfile(connectorId : Text) : async ?ConnectorGuidelineProfile {
    Map.get(connectorGuidelineProfiles, Text.compare, connectorId);
  };

  public query func listConnectorGuidelineProfiles() : async [ConnectorGuidelineProfile] {
    Iter.toArray(Map.values(connectorGuidelineProfiles));
  };

  public shared (msg) func clearConnectorGuidelineProfile(connectorId : Text) : async Bool {
    Admin.requireAdmin(admin, msg.caller);
    ignore Map.delete(connectorGuidelineProfiles, Text.compare, connectorId);
    true;
  };

  public shared (msg) func setGuideline(next : UsageGuideline) : async Bool {
    Admin.requireAdmin(admin, msg.caller);
    let profile : GuidelineProfile = {
      id = customActiveGuidelineProfileId;
      displayName = "Custom active guideline";
      status = "custom";
      guideline = next;
      notes = "Loaded through legacy setGuideline; prefer putGuidelineProfile plus setDefaultGuidelineProfile for named runtime profiles.";
      updatedAt = Time.now();
    };
    Map.add(customGuidelineProfiles, Text.compare, profile.id, profile);
    defaultGuidelineProfileId := profile.id;
    guideline := next;
    true;
  };

  public shared (msg) func resetGuidelineToEgyptEducationBaseline() : async Bool {
    Admin.requireAdmin(admin, msg.caller);
    ignore setDefaultGuidelineProfileCore(egGuidelineProfileId);
    true;
  };

  public shared (msg) func resetGuidelineToCrossBorderEducationBaseline() : async Bool {
    Admin.requireAdmin(admin, msg.caller);
    ignore setDefaultGuidelineProfileCore(cbprGuidelineProfileId);
    true;
  };

  public query func getComplianceProfile() : async ComplianceProfile { complianceProfile };

  public shared (msg) func setComplianceProfile(next : ComplianceProfile) : async Bool {
    Admin.requireAdmin(admin, msg.caller);
    complianceProfile := next;
    true;
  };

  public shared (msg) func resetComplianceProfile() : async Bool {
    Admin.requireAdmin(admin, msg.caller);
    complianceProfile := ISO.defaultComplianceProfile();
    true;
  };

  public query func getMemphisGateConfig() : async { memphis : Principal; origin : Text; version : Nat64 } {
    { memphis = memphisGate.memphis; origin = memphisGate.origin; version = memphisGate.version };
  };

  public shared (msg) func setMemphisGateByCid(cid : Nat64, origin : Text, version : Nat64) : async Bool {
    Admin.requireAdmin(admin, msg.caller);
    memphisGate := MemphisAuth.initFromCid(cid, origin, version);
    true;
  };

  public shared (msg) func setMemphisGate(memphis : Principal, origin : Text, version : Nat64) : async Bool {
    Admin.requireAdmin(admin, msg.caller);
    memphisGate := MemphisAuth.init(memphis, origin, version);
    true;
  };

  public query func getMemphisAudience() : async Text { memphisAudience };

  /// Set the web origin whose sessions this contract accepts.
  ///
  /// Safe to change — unlike the namespace on the gate, it touches no identity:
  /// it only says where a token must have been minted. Change it when the
  /// submitting frontend moves to a new domain. It must be a bare origin
  /// (scheme + host + optional port) because Memphis compares it byte-exactly.
  public shared (msg) func setMemphisAudience(audience : Text) : async Bool {
    Admin.requireAdmin(admin, msg.caller);
    if (Text.size(audience) == 0) return false;
    memphisAudience := audience;
    true;
  };

  // -- On-chain connector framework --------------------------------------
  public shared (msg) func registerConnector(
    id : Text,
    publicKeyHash : ?Blob,
    allowedFormats : [Text],
    allowedEndpoints : [Text],
  ) : async ConnectorConfig {
    Admin.requireAdmin(admin, msg.caller);
    if (id == "") Runtime.trap("connector id required");
    let now = Time.now();
    let existing = Map.get(connectors, Text.compare, id);
    let nextSequence = switch (existing) {
      case (?c) c.nextInboundSequence;
      case null 0;
    };
    let cfg : ConnectorConfig = {
      id;
      owner = msg.caller;
      active = true;
      publicKeyHash;
      signaturePolicy = Connector.defaultSignaturePolicy(publicKeyHash);
      allowedFormats;
      allowedEndpoints;
      nextInboundSequence = nextSequence;
      createdAt = switch (existing) { case (?c) c.createdAt; case null now };
      updatedAt = now;
    };
    Map.add(connectors, Text.compare, id, cfg);
    cfg;
  };

  public shared (msg) func setConnectorSignaturePolicy(id : Text, policy : SignaturePolicy) : async ConnectorConfig {
    Admin.requireAdmin(admin, msg.caller);
    switch (Map.get(connectors, Text.compare, id)) {
      case null Runtime.trap("connector not found");
      case (?c) {
        let next = { c with signaturePolicy = policy; publicKeyHash = policy.publicKeyHash; updatedAt = Time.now() };
        Map.add(connectors, Text.compare, id, next);
        next;
      };
    };
  };

  public shared (msg) func useThebesCallerAuth(id : Text) : async ConnectorConfig {
    Admin.requireAdmin(admin, msg.caller);
    setConnectorPolicyCore(id, Connector.thebesCallerPolicy());
  };

  public shared (msg) func useMemphisSessionAuth(id : Text) : async ConnectorConfig {
    Admin.requireAdmin(admin, msg.caller);
    setConnectorPolicyCore(id, Connector.memphisSessionPolicy());
  };

  public shared (msg) func useExternalSignatureAuth(id : Text, scheme : Text, publicKeyHash : ?Blob, verifier : Principal) : async ConnectorConfig {
    Admin.requireAdmin(admin, msg.caller);
    setConnectorPolicyCore(id, Connector.externalAttestationPolicy(scheme, publicKeyHash, verifier));
  };

  public shared (msg) func setConnectorActive(id : Text, active : Bool) : async Bool {
    Admin.requireAdmin(admin, msg.caller);
    switch (Map.get(connectors, Text.compare, id)) {
      case null Runtime.trap("connector not found");
      case (?c) {
        Map.add(connectors, Text.compare, id, { c with active; updatedAt = Time.now() });
        true;
      };
    };
  };

  public query func getConnector(id : Text) : async ?ConnectorConfig {
    Map.get(connectors, Text.compare, id);
  };

  public query func listConnectors(offset : Nat, limit : Nat) : async Pagination.Page<ConnectorConfig> {
    Pagination.page<ConnectorConfig>(Iter.toArray(Map.values(connectors)), offset, limit);
  };

  public query func connectorEnvelopeSigningHash(env : TransportEnvelope) : async Blob {
    let domain = switch (Map.get(connectors, Text.compare, env.connectorId)) {
      case (?c) c.signaturePolicy.domain;
      case null "thebes.iso20022.connector.v1";
    };
    connectorEnvelopeHash(env, hashBlob(env.payload), domain);
  };

  public shared (msg) func submitTransportEnvelope(env : TransportEnvelope) : async TransportSubmitResult {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    await submitTransportEnvelopeCore(msg.caller, env, null)
  };

  public shared (msg) func submitTransportEnvelopeWithMemphis(env : TransportEnvelope, token : Blob) : async MemphisTransportSubmitResult {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    // await*, not await: verifyWithAudience is async*. A plain await on a
    // module-level async helper that calls another contract replies with the
    // INNER value instead of this method's own return.
    let identity = switch (await* MemphisAuth.verifyWithAudience(memphisGate, token, memphisAudience)) {
      case (#ok(id)) id;
      case (#err(e)) return #authErr(e);
    };
    switch (await submitTransportEnvelopeCore(msg.caller, env, ?identity.principal)) {
      case (#accepted(r)) #accepted(r);
      case (#deadLetter(r)) #deadLetter(r);
    }
  };

  func submitTransportEnvelopeCore(caller : Principal, env : TransportEnvelope, memphisPrincipal : ?Principal) : async TransportSubmitResult {
    let connector = Map.get(connectors, Text.compare, env.connectorId);
    let remoteKey = env.connectorId # ":" # env.remoteId;
    let remoteSeen = switch (Map.get(remoteIdIndex, Text.compare, remoteKey)) { case (?_) true; case null false };
    let expectedHash = hashBlob(env.payload);
    var issues = Connector.verifyEnvelope(
      {
        connector;
        expectedHash;
        remoteAlreadySeen = remoteSeen;
        caller = ?caller;
        memphisPrincipal;
      },
      env,
    );
    var paymentId : ?Nat = null;
    var status = Connector.statusFromIssues(issues);
    let selectedGuideline = guidelineForConnector(env.connectorId);

    if (issues.size() == 0) {
      issues := await verifyExternalSignatureIfNeeded(connector, env, expectedHash, issues);
      status := Connector.statusFromIssues(issues);
    };

    if (issues.size() == 0) {
      if (env.format == "pain.001.xml") {
        switch (Xml.decodePain001(env.payload)) {
          case (#ok(instruction)) {
            let p = submitPain001CoreWithGuideline(caller, instruction, ?env.payload, selectedGuideline);
            paymentId := ?p.id;
            status := "processed";
          };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "pacs.008.xml") {
        switch (Xml.decodePacs008(env.payload)) {
          case (#ok(doc)) {
            let report = ISO.validatePacs008(selectedGuideline, doc, ?env.payload);
            ignore auditPacs008Core(caller, doc, ?env.payload, report);
            status := "processed";
          };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "pain.008.xml" or env.format == "pacs.003.xml") {
        switch (Xml.decodeDirectDebit(env.payload)) {
          case (#ok(doc)) {
            let report = ISO.validateDirectDebit(selectedGuideline, doc, ?env.payload);
            if (report.ok) {
              ignore correlateDirectDebitWorkflowWithGuideline(caller, doc, ?env.payload, selectedGuideline);
              status := "processed";
            } else {
              for (i in report.issues.vals()) issues := Connector.add(issues, i);
              status := "dead-letter";
            };
          };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "pain.002.xml" or env.format == "pacs.002.xml" or env.format == "pacs.004.xml") {
        switch (Xml.decodeStatusReport(env.payload)) {
          case (#ok(doc)) {
            let expectedKind = if (env.format == "pain.002.xml") {
              "pain.002";
            } else if (env.format == "pacs.002.xml") {
              "pacs.002";
            } else {
              "pacs.004";
            };
            let report = ISO.validateStatusReport(selectedGuideline, doc, expectedKind);
            if (report.ok) {
              if (expectedKind == "pacs.002" or expectedKind == "pacs.004") {
                let applied = applyInboundStatusReport(caller, doc, selectedGuideline);
                paymentId := applied.paymentId;
                if (applied.issues.size() == 0) {
                  status := "processed";
                } else {
                  for (i in applied.issues.vals()) issues := Connector.add(issues, i);
                  status := "dead-letter";
                };
              } else {
                status := "processed";
              };
            } else {
              for (i in report.issues.vals()) issues := Connector.add(issues, i);
              status := "dead-letter";
            };
          };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "pacs.009.xml") {
        switch (Xml.decodePacs009(env.payload)) {
          case (#ok(doc)) {
            let report = ISO.validatePacs009(selectedGuideline, doc, ?env.payload);
            if (report.ok) {
              status := "processed";
            } else {
              for (i in report.issues.vals()) issues := Connector.add(issues, i);
              status := "dead-letter";
            };
          };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "cover.payment.xml") {
        switch (Xml.decodeCoverPayment(env.payload)) {
          case (#ok(doc)) {
            let report = ISO.validateCoverPayment(selectedGuideline, doc, ?env.payload);
            if (report.ok) {
              status := "processed";
            } else {
              for (i in report.issues.vals()) issues := Connector.add(issues, i);
              status := "dead-letter";
            };
          };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "camt.056.xml" or env.format == "camt.029.xml" or env.format == "pacs.028.xml" or env.format == "camt.110.xml" or env.format == "camt.111.xml") {
        switch (Xml.decodeInvestigation(env.payload)) {
          case (#ok(doc)) {
            let report = ISO.validateInvestigation(selectedGuideline, doc);
            if (report.ok) {
              ignore correlateInvestigationWorkflowWithGuideline(caller, doc, selectedGuideline);
              status := "processed";
            } else {
              for (i in report.issues.vals()) issues := Connector.add(issues, i);
              status := "dead-letter";
            };
          };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "pain.013.xml" or env.format == "pain.014.xml" or env.format == "camt.055.xml") {
        switch (Xml.decodeRequestToPay(env.payload)) {
          case (#ok(doc)) {
            let report = ISO.validateRequestToPay(selectedGuideline, doc);
            if (report.ok) {
              ignore correlateRequestToPayWorkflowWithGuideline(caller, doc, selectedGuideline);
              status := "processed";
            } else {
              for (i in report.issues.vals()) issues := Connector.add(issues, i);
              status := "dead-letter";
            };
          };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "admi.002.xml" or env.format == "admi.004.xml" or env.format == "admi.007.xml" or env.format == "admi.011.xml") {
        switch (Xml.decodeAdministrative(env.payload)) {
          case (#ok(doc)) {
            let report = ISO.validateAdministrativeMessage(selectedGuideline, doc);
            if (report.ok) {
              ignore correlateAdministrativeWorkflowWithGuideline(caller, doc, selectedGuideline);
              status := "processed";
            } else {
              for (i in report.issues.vals()) issues := Connector.add(issues, i);
              status := "dead-letter";
            };
          };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "camt.053.xml") {
        switch (Xml.decodeCamt053(env.payload)) {
          case (#ok(_)) { status := "processed" };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "camt.054.xml") {
        switch (Xml.decodeCamt054(env.payload)) {
          case (#ok(_)) { status := "processed" };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "mt103") {
        switch (LegacyMT.decodeMt103(env.payload, defaultLegacyCountryForGuideline(selectedGuideline))) {
          case (#ok(instruction)) {
            let p = submitPain001CoreWithGuideline(caller, instruction, ?env.payload, selectedGuideline);
            paymentId := ?p.id;
            status := "processed";
          };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "mt940") {
        switch (LegacyMT.decodeMt940(env.payload, defaultLegacyCurrencyForGuideline(selectedGuideline))) {
          case (#ok(_)) { status := "processed" };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "mt942") {
        switch (LegacyMT.decodeMt942(env.payload, defaultLegacyCurrencyForGuideline(selectedGuideline))) {
          case (#ok(_)) { status := "processed" };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "csv.payments") {
        switch (LegacyMT.decodeCsvPayments(env.payload, defaultLegacyCountryForGuideline(selectedGuideline))) {
          case (#ok(docs)) {
            paymentId := submitLegacyPaymentBatch(caller, docs, env.payload, selectedGuideline);
            status := "processed";
          };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (env.format == "fixed.payments") {
        switch (LegacyMT.decodeFixedWidthPayments(env.payload, defaultLegacyCountryForGuideline(selectedGuideline))) {
          case (#ok(docs)) {
            paymentId := submitLegacyPaymentBatch(caller, docs, env.payload, selectedGuideline);
            status := "processed";
          };
          case (#err(parseIssues)) {
            for (i in parseIssues.vals()) issues := Connector.add(issues, i);
            status := "dead-letter";
          };
        };
      } else if (mtBridgeFormat(env.format)) {
        // the MT bridge: block 2 names the type ("mt" lets the bridge read it; "mt202" and the like assert it)
        let hint = if (env.format == "mt") null else ?Text.toUpper(env.format);
        let d = MtBridge.decode(env.payload, hint, mtOptions(selectedGuideline), breadthMinorUnits(selectedGuideline));
        switch (d.message) {
          case (#ok(m)) {
            switch (hint) { case (?h) { if (h != d.mtType) { issues := Connector.add(issues, ISO.publicIssue("transport", "MT-TYPE-MISMATCH", "$.format", "block 2 says " # d.mtType # ", the format says " # h)) } }; case null {} };
            if (issues.size() == 0) {
              switch (m) {
                case (#pain001(docs)) { paymentId := submitLegacyPaymentBatch(caller, docs, env.payload, selectedGuideline) };
                case (_) {};
              };
              status := "processed";
            } else status := "dead-letter";
          };
          case (#err(e)) { for (i in e.vals()) issues := Connector.add(issues, i); status := "dead-letter" };
        };
      } else if (breadthFormat(env.format)) {
        // the schema-profile codec: the official XSD first, then the business reading
        let d = Breadth.decode(env.payload, breadthMinorUnits(selectedGuideline));
        let bi = breadthIssues(d);
        if (bi.size() == 0) { status := "processed" }
        else { for (i in bi.vals()) issues := Connector.add(issues, i); status := "dead-letter" };
      } else {
        issues := Connector.add(issues, ISO.publicIssue("transport", "TRANSPORT-ROUTE-MISSING", "$.format", "format is allowed but no on-chain route is implemented yet"));
        status := "dead-letter";
      };
    };

    let rec = makeTransportRecord(env, expectedHash, status, paymentId, issues);
    Map.add(transportRecords, Nat.compare, rec.id, rec);
    if (not remoteSeen and issues.size() == 0) {
      Map.add(remoteIdIndex, Text.compare, remoteKey, rec.id);
      switch (connector) {
        case (?c) {
          Map.add(connectors, Text.compare, c.id, { c with nextInboundSequence = env.sequence + 1; updatedAt = Time.now() });
        };
        case null {};
      };
    };
    if (status == "processed") #accepted(rec) else #deadLetter(rec);
  };

  public query func getTransportRecord(id : Nat) : async ?TransportRecord {
    Map.get(transportRecords, Nat.compare, id);
  };

  public query func listTransportRecords(offset : Nat, limit : Nat) : async Pagination.Page<TransportRecord> {
    Pagination.page<TransportRecord>(Iter.toArray(Map.values(transportRecords)), offset, limit);
  };

  public query func listDeadLetters(offset : Nat, limit : Nat) : async Pagination.Page<TransportRecord> {
    var all : [TransportRecord] = [];
    for (r in Map.values(transportRecords)) {
      if (r.status == "dead-letter") {
        all := Array.concat<TransportRecord>(all, [r]);
      };
    };
    Pagination.page<TransportRecord>(all, offset, limit);
  };

  public query func transportCount() : async Nat {
    Map.size(transportRecords);
  };

  public query func decodeMt103(mt : Blob) : async Mt103Decode {
    LegacyMT.decodeMt103(mt, defaultLegacyCountry());
  };

  public query func decodeMt940(mt : Blob) : async MtStatementDecode {
    LegacyMT.decodeMt940(mt, defaultLegacyCurrency());
  };

  public query func decodeMt942(mt : Blob) : async MtStatementDecode {
    LegacyMT.decodeMt942(mt, defaultLegacyCurrency());
  };

  public query func decodeCsvPayments(csv : Blob) : async LegacyPaymentFileDecode {
    LegacyMT.decodeCsvPayments(csv, defaultLegacyCountry());
  };

  public query func decodeFixedWidthPayments(payload : Blob) : async LegacyPaymentFileDecode {
    LegacyMT.decodeFixedWidthPayments(payload, defaultLegacyCountry());
  };

  public query func parseMt103Fields(mt : Text) : async [Mt103Field] {
    LegacyMT.parseMt103Fields(mt);
  };

  public shared (msg) func queuePaymentOutbound(connectorId : Text, paymentId : Nat, format : Text) : async OutboundBatch {
    Admin.requireAdmin(admin, msg.caller);
    queuePaymentOutboundCore(connectorId, ?paymentId, format);
  };

  public shared (msg) func queuePaymentXmlBundle(connectorId : Text, paymentId : Nat) : async OutboundBatch {
    Admin.requireAdmin(admin, msg.caller);
    queuePaymentOutboundCore(connectorId, ?paymentId, "payment.bundle.xml");
  };

  public shared (msg) func leaseOutboundBatches(connectorId : Text, limit : Nat, leaseMillis : Nat) : async [OutboundBatch] {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    requireConnectorCaller(msg.caller, connectorId);
    let now = Time.now();
    let leaseUntil = now + ((leaseMillis : Int) * 1_000_000);
    var leased : [OutboundBatch] = [];
    for (batch in Map.values(outboundBatches)) {
      if (leased.size() < limit and batch.connectorId == connectorId and batch.status == "queued") {
        if (batch.attemptCount >= batch.maxAttempts) {
          let issues = addIssue(batch.issues, ISO.publicIssue("transport", "OUTBOUND-MAX-ATTEMPTS", "$.attemptCount", "outbound batch exceeded max delivery attempts"));
          let dead = { batch with status = "dead-letter"; updatedAt = now; issueCount = issues.size(); issues };
          storeOutboundBatch(dead);
        } else {
          let next = {
            batch with
            status = "leased";
            attemptCount = batch.attemptCount + 1;
            updatedAt = now;
            leasedUntil = ?leaseUntil;
          };
          storeOutboundBatch(next);
          leased := Array.concat<OutboundBatch>(leased, [next]);
        };
      };
    };
    leased;
  };

  public shared (msg) func ackOutboundDelivery(ack : DeliveryAck) : async ?OutboundBatch {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    requireConnectorCaller(msg.caller, ack.connectorId);
    switch (Map.get(outboundBatches, Nat.compare, ack.batchId)) {
      case null null;
      case (?batch) {
        let now = Time.now();
        let issues = Connector.verifyDeliveryAck(?batch, ack);
        let status = if (issues.size() > 0) {
          "dead-letter";
        } else if (ack.status == "ACK") {
          "acked";
        } else {
          "nacked";
        };
        let next = {
          batch with
          status;
          updatedAt = now;
          leasedUntil = null;
          ack = ?ack;
          issueCount = issues.size();
          issues;
        };
        storeOutboundBatch(next);
        ?next;
      };
    };
  };

  public shared (msg) func failOutboundDelivery(batchId : Nat, detail : Text) : async ?OutboundBatch {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    switch (Map.get(outboundBatches, Nat.compare, batchId)) {
      case null null;
      case (?batch) {
        requireConnectorCaller(msg.caller, batch.connectorId);
        let now = Time.now();
        var issues = addIssue(batch.issues, ISO.publicIssue("transport", "OUTBOUND-DELIVERY-FAILED", "$.delivery", detail));
        let status = if (batch.attemptCount >= batch.maxAttempts) {
          issues := addIssue(issues, ISO.publicIssue("transport", "OUTBOUND-MAX-ATTEMPTS", "$.attemptCount", "outbound batch exceeded max delivery attempts"));
          "dead-letter";
        } else {
          "queued";
        };
        let next = {
          batch with
          status;
          updatedAt = now;
          leasedUntil = null;
          issueCount = issues.size();
          issues;
        };
        storeOutboundBatch(next);
        ?next;
      };
    };
  };

  public shared (msg) func retryOutboundBatch(batchId : Nat) : async ?OutboundBatch {
    Admin.requireAdmin(admin, msg.caller);
    switch (Map.get(outboundBatches, Nat.compare, batchId)) {
      case null null;
      case (?batch) {
        if (batch.status == "acked") Runtime.trap("acked batch cannot be retried");
        let next = {
          batch with
          status = "queued";
          updatedAt = Time.now();
          leasedUntil = null;
          ack = null;
          issues = [];
          issueCount = 0;
        };
        storeOutboundBatch(next);
        ?next;
      };
    };
  };

  public query func getOutboundBatch(id : Nat) : async ?OutboundBatch {
    Map.get(outboundBatches, Nat.compare, id);
  };

  public query func listOutboundBatches(offset : Nat, limit : Nat) : async Pagination.Page<OutboundBatch> {
    Pagination.page<OutboundBatch>(Iter.toArray(Map.values(outboundBatches)), offset, limit);
  };

  public query func listOutboundBatchesForConnector(connectorId : Text, offset : Nat, limit : Nat) : async Pagination.Page<OutboundBatch> {
    var all : [OutboundBatch] = [];
    for (batch in Map.values(outboundBatches)) {
      if (batch.connectorId == connectorId) {
        all := Array.concat<OutboundBatch>(all, [batch]);
      };
    };
    Pagination.page<OutboundBatch>(all, offset, limit);
  };

  public query func listOutboundBatchesByConnectorStatus(connectorId : Text, status : Text, offset : Nat, limit : Nat) : async Pagination.Page<OutboundBatch> {
    let prefix = OrderedIndex.join([OrderedIndex.keyPart(connectorId), OrderedIndex.keyPart(status)]);
    outboundPageFromIds(OrderedIndex.prefix(outboundQueueIndex, prefix, 0, Map.size(outboundBatches)), offset, limit);
  };

  public query func listOutboundBatchesByConnectorStatusStable(connectorId : Text, status : Text, offset : Nat, limit : Nat) : async Pagination.Page<OutboundBatch> {
    let prefix = OrderedIndex.join([OrderedIndex.keyPart(connectorId), OrderedIndex.keyPart(status)]);
    outboundPageFromIds(StableOrderedIndex.prefix(outboundQueueStableIndex, prefix, 0, Map.size(outboundBatches)), offset, limit);
  };

  public query func outboundBatchCount() : async Nat {
    Map.size(outboundBatches);
  };

  public query func secondaryIndexHealth() : async SecondaryIndexHealth {
    secondaryIndexHealthCore();
  };

  public shared (msg) func rebuildSecondaryIndexes() : async SecondaryIndexHealth {
    Admin.requireAdmin(admin, msg.caller);
    rebuildSecondaryIndexesCore();
    secondaryIndexHealthCore();
  };

  public shared (msg) func checkpointSecondaryIndexes() : async SecondaryIndexHealth {
    Admin.requireAdmin(admin, msg.caller);
    commitSecondaryIndexCheckpoints();
    secondaryIndexHealthCore();
  };

  // -- Validation ---------------------------------------------------------
  public query func validatePain001(doc : CustomerCreditTransferInitiation, rawXml : ?Blob) : async ValidationReport {
    ISO.validatePain001(guideline, doc, rawXml);
  };

  public query func validatePacs008(doc : Pacs008CreditTransfer, rawXml : ?Blob) : async ValidationReport {
    ISO.validatePacs008(guideline, doc, rawXml);
  };

  public query func validatePacs009(doc : Pacs009FinancialInstitutionCreditTransfer, rawXml : ?Blob) : async ValidationReport {
    ISO.validatePacs009(guideline, doc, rawXml);
  };

  public query func validateCoverPayment(doc : CoverPayment, rawXml : ?Blob) : async ValidationReport {
    ISO.validateCoverPayment(guideline, doc, rawXml);
  };

  public query func validateInvestigation(doc : InvestigationMessage) : async ValidationReport {
    ISO.validateInvestigation(guideline, doc);
  };

  public query func validatePain001WithProfile(profileId : Text, doc : CustomerCreditTransferInitiation, rawXml : ?Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    ISO.validatePain001(g, doc, rawXml);
  };

  public query func validatePacs008WithProfile(profileId : Text, doc : Pacs008CreditTransfer, rawXml : ?Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    ISO.validatePacs008(g, doc, rawXml);
  };

  public query func validatePacs009WithProfile(profileId : Text, doc : Pacs009FinancialInstitutionCreditTransfer, rawXml : ?Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    ISO.validatePacs009(g, doc, rawXml);
  };

  public query func validateCoverPaymentWithProfile(profileId : Text, doc : CoverPayment, rawXml : ?Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    ISO.validateCoverPayment(g, doc, rawXml);
  };

  public query func validateInvestigationWithProfile(profileId : Text, doc : InvestigationMessage) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    ISO.validateInvestigation(g, doc);
  };

  public query func validateRequestToPayWithProfile(profileId : Text, doc : RequestToPayMessage) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    ISO.validateRequestToPay(g, doc);
  };

  public query func validateDirectDebitWithProfile(profileId : Text, doc : DirectDebitMessage, rawXml : ?Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    ISO.validateDirectDebit(g, doc, rawXml);
  };

  public query func validateAdministrativeWithProfile(profileId : Text, doc : AdministrativeMessage) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    ISO.validateAdministrativeMessage(g, doc);
  };

  public query func validateStatusReportWithProfile(profileId : Text, doc : StatusReport, expectedKind : Text) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    ISO.validateStatusReport(g, doc, expectedKind);
  };

  public shared (msg) func correlateDirectDebitWorkflow(doc : DirectDebitMessage, rawXml : ?Blob) : async WorkflowCorrelationResult {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    correlateDirectDebitWorkflowWithGuideline(msg.caller, doc, rawXml, guideline);
  };

  public shared (msg) func correlateRequestToPayWorkflow(doc : RequestToPayMessage) : async WorkflowCorrelationResult {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    correlateRequestToPayWorkflowWithGuideline(msg.caller, doc, guideline);
  };

  public shared (msg) func correlateInvestigationWorkflow(doc : InvestigationMessage) : async WorkflowCorrelationResult {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    correlateInvestigationWorkflowWithGuideline(msg.caller, doc, guideline);
  };

  public shared (msg) func correlateAdministrativeWorkflow(doc : AdministrativeMessage) : async WorkflowCorrelationResult {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    correlateAdministrativeWorkflowWithGuideline(msg.caller, doc, guideline);
  };

  public shared (msg) func correlateDemoDirectDebitReturnWorkflow() : async WorkflowState {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    let g = ISO.crossBorderEducationGuideline();
    let first = correlateDirectDebitWorkflowWithGuideline(msg.caller, ISO.demoPain008(), null, g);
    if (not first.ok) Runtime.trap("demo pain.008 correlation failed validation");
    let collection = correlateDirectDebitWorkflowWithGuideline(msg.caller, ISO.demoPacs003(), null, g);
    if (not collection.ok) Runtime.trap("demo pacs.003 correlation failed validation");
    let rejection = correlateAdministrativeWorkflowWithGuideline(msg.caller, ISO.demoAdmi002Reject(), g);
    if (not rejection.ok) Runtime.trap("demo admi.002 correlation failed validation");
    switch (rejection.workflow) {
      case (?wf) wf;
      case null Runtime.trap("demo direct-debit workflow was not correlated");
    };
  };

  public shared (msg) func correlateDemoRequestToPayWorkflow() : async WorkflowState {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    let g = ISO.crossBorderEducationGuideline();
    let request = correlateRequestToPayWorkflowWithGuideline(msg.caller, ISO.demoPain013(), g);
    if (not request.ok) Runtime.trap("demo pain.013 correlation failed validation");
    let response = correlateRequestToPayWorkflowWithGuideline(msg.caller, ISO.demoPain014Accepted(), g);
    if (not response.ok) Runtime.trap("demo pain.014 correlation failed validation");
    let ack = correlateAdministrativeWorkflowWithGuideline(msg.caller, ISO.demoAdmi007Ack(), g);
    if (not ack.ok) Runtime.trap("demo admi.007 correlation failed validation");
    switch (ack.workflow) {
      case (?wf) wf;
      case null Runtime.trap("demo request-to-pay workflow was not correlated");
    };
  };

  public query func getWorkflowState(id : Text) : async ?WorkflowState {
    Map.get(workflowStates, Text.compare, id);
  };

  public query func getWorkflowByMessageId(messageId : Text) : async ?WorkflowState {
    switch (Map.get(workflowByMessageId, Text.compare, messageId)) {
      case (?id) Map.get(workflowStates, Text.compare, id);
      case null null;
    };
  };

  public query func getWorkflowByUetr(uetr : Text) : async ?WorkflowState {
    switch (Map.get(workflowByUetr, Text.compare, uetr)) {
      case (?id) Map.get(workflowStates, Text.compare, id);
      case null null;
    };
  };

  public query func listWorkflowStates(offset : Nat, limit : Nat) : async Pagination.Page<WorkflowState> {
    Pagination.page<WorkflowState>(workflowStatesOrdered(), offset, limit);
  };

  public query func verifyParticipantWorkflowCorrelation() : async ValidationReport {
    verifyParticipantWorkflowOracleReport();
  };

  public query func pfmiSelfAssessment() : async [PfmiPrincipleAssessment] {
    pfmiAssessments();
  };

  public query func verifyPfmiSelfAssessment() : async ValidationReport {
    verifyPfmiSelfAssessmentReport();
  };

  public query func screenPacs008(doc : Pacs008CreditTransfer) : async ComplianceReport {
    ISO.screenPacs008(complianceProfile, doc);
  };

  public query func screenPacs009(doc : Pacs009FinancialInstitutionCreditTransfer) : async ComplianceReport {
    ISO.screenPacs009(complianceProfile, doc);
  };

  public query func screenCoverPayment(doc : CoverPayment) : async ComplianceReport {
    ISO.screenCoverPayment(complianceProfile, doc);
  };

  public query func getPaymentComplianceReport(paymentId : Nat) : async ?ComplianceScreeningRecord {
    Map.get(complianceScreeningRecords, Nat.compare, paymentId);
  };

  public query func listPaymentComplianceReports(offset : Nat, limit : Nat) : async Pagination.Page<ComplianceScreeningRecord> {
    Pagination.page<ComplianceScreeningRecord>(Iter.toArray(Map.values(complianceScreeningRecords)), offset, limit);
  };

  public query func listHeldPaymentViews(offset : Nat, limit : Nat) : async Pagination.Page<PaymentView> {
    paymentViewPageFromIds(OrderedIndex.prefix(paymentStatusIndex, OrderedIndex.keyPart("held"), 0, Map.size(payments)), offset, limit);
  };

  public shared (msg) func releaseComplianceHold(paymentId : Nat, reason : Text) : async HubPayment {
    Admin.requireAdmin(admin, msg.caller);
    updateComplianceHeldPayment(paymentId, "accepted", "compliance.released", reason, msg.caller);
  };

  public shared (msg) func rejectComplianceHold(paymentId : Nat, reason : Text) : async HubPayment {
    Admin.requireAdmin(admin, msg.caller);
    updateComplianceHeldPayment(paymentId, "rejected", "compliance.rejected", reason, msg.caller);
  };

  public query func validateDemoPain001() : async ValidationReport {
    ISO.validatePain001(guideline, ISO.demoPain001(), null);
  };

  public query func validateDemoPain001WithProfile(profileId : Text) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    ISO.validatePain001(g, ISO.demoPain001(), null);
  };

  public query func validateDemoCrossBorderPain001WithProfile(profileId : Text) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    ISO.validatePain001(g, ISO.demoCrossBorderPain001(), null);
  };

  public query func validateDemoPacs008() : async ValidationReport {
    ISO.validatePacs008(guideline, ISO.demoPacs008(), null);
  };

  public query func validateDemoPacs008WithProfile(profileId : Text) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    ISO.validatePacs008(g, ISO.demoPacs008(), null);
  };

  public query func validateDemoCrossBorderPacs008WithProfile(profileId : Text) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    ISO.validatePacs008(g, ISO.demoCrossBorderPacs008(), null);
  };

  public query func validateDemoPacs009() : async ValidationReport {
    ISO.validatePacs009(ISO.crossBorderEducationGuideline(), ISO.demoPacs009Core(), null);
  };

  public query func validateDemoCoverPayment() : async ValidationReport {
    ISO.validateCoverPayment(ISO.crossBorderEducationGuideline(), ISO.demoCoverPayment(), null);
  };

  public query func screenDemoCoverPayment() : async ComplianceReport {
    ISO.screenCoverPayment(complianceProfile, ISO.demoCoverPayment());
  };

  public query func demoPain001() : async CustomerCreditTransferInitiation {
    ISO.demoPain001();
  };

  public query func demoPacs008() : async Pacs008CreditTransfer {
    ISO.demoPacs008();
  };

  public query func demoCrossBorderPain001() : async CustomerCreditTransferInitiation {
    ISO.demoCrossBorderPain001();
  };

  public query func demoCrossBorderPacs008() : async Pacs008CreditTransfer {
    ISO.demoCrossBorderPacs008();
  };

  public query func demoPacs009Core() : async Pacs009FinancialInstitutionCreditTransfer {
    ISO.demoPacs009Core();
  };

  public query func demoCoverPayment() : async CoverPayment {
    ISO.demoCoverPayment();
  };

  public query func demoCamt056() : async InvestigationMessage {
    ISO.demoCamt056();
  };

  public query func demoCamt029() : async InvestigationMessage {
    ISO.demoCamt029();
  };

  public query func demoPacs028() : async InvestigationMessage {
    ISO.demoPacs028();
  };

  public query func demoCamt110() : async InvestigationMessage {
    ISO.demoCamt110();
  };

  public query func demoCamt111() : async InvestigationMessage {
    ISO.demoCamt111();
  };

  public query func demoPain013() : async RequestToPayMessage {
    ISO.demoPain013();
  };

  public query func demoPain014Accepted() : async RequestToPayMessage {
    ISO.demoPain014Accepted();
  };

  public query func demoCamt055() : async RequestToPayMessage {
    ISO.demoCamt055();
  };

  public query func demoPain008() : async DirectDebitMessage {
    ISO.demoPain008();
  };

  public query func demoPacs003() : async DirectDebitMessage {
    ISO.demoPacs003();
  };

  public query func demoAdmi002Reject() : async AdministrativeMessage {
    ISO.demoAdmi002Reject();
  };

  public query func demoAdmi004ConnectionCheck() : async AdministrativeMessage {
    ISO.demoAdmi004ConnectionCheck();
  };

  public query func demoAdmi007Ack() : async AdministrativeMessage {
    ISO.demoAdmi007Ack();
  };

  public query func demoAdmi011ConnectionAck() : async AdministrativeMessage {
    ISO.demoAdmi011ConnectionAck();
  };

  // -- XML codec ----------------------------------------------------------
  public query func xmlCodecVersion() : async Text {
    Xml.codecVersion;
  };

  public query func decodePain001Xml(xml : Blob) : async Pain001XmlDecode {
    Xml.decodePain001(xml);
  };

  public query func decodePacs008Xml(xml : Blob) : async Pacs008XmlDecode {
    Xml.decodePacs008(xml);
  };

  public query func decodePacs009Xml(xml : Blob) : async Pacs009XmlDecode {
    Xml.decodePacs009(xml);
  };

  public query func decodeCoverPaymentXml(xml : Blob) : async CoverPaymentXmlDecode {
    Xml.decodeCoverPayment(xml);
  };

  public query func decodeInvestigationXml(xml : Blob) : async InvestigationXmlDecode {
    Xml.decodeInvestigation(xml);
  };

  public query func decodeRequestToPayXml(xml : Blob) : async RequestToPayXmlDecode {
    Xml.decodeRequestToPay(xml);
  };

  public query func decodeDirectDebitXml(xml : Blob) : async DirectDebitXmlDecode {
    Xml.decodeDirectDebit(xml);
  };

  public query func decodeAdministrativeXml(xml : Blob) : async AdministrativeXmlDecode {
    Xml.decodeAdministrative(xml);
  };

  public query func decodeStatusReportXml(xml : Blob) : async StatusReportXmlDecode {
    Xml.decodeStatusReport(xml);
  };

  public query func decodeCamt053Xml(xml : Blob) : async StatementXmlDecode {
    Xml.decodeCamt053(xml);
  };

  public query func decodeCamt054Xml(xml : Blob) : async StatementXmlDecode {
    Xml.decodeCamt054(xml);
  };

  // -- schema-profile codec: the twenty families of the declared target list ----------------------
  // (motoko/iso/IsoBreadth.mo). A message is validated
  // against its official XSD (motoko/iso/IsoProfiles.mo, generated from the schemas) before its
  // business content is read; a record is written back schema-valid. The compact codec above is
  // untouched: these families are read and written in the official shape only.

  public type BreadthMessage = Breadth.Message;
  public type BreadthEmitOptions = Breadth.EmitOptions;
  public type BreadthDecode = {
    family : Text;
    /// the official schema's disagreements (tier "schema"); the business reading is attempted only when empty
    schemaIssues : [ValidationIssue];
    /// the typed record, when both tiers passed
    message : ?BreadthMessage;
    /// every issue of both tiers, the shape the transport route records
    issues : [ValidationIssue];
  };
  public type SchemaProfileSummary = { family : Text; namespace : Text; rootName : Text; schemaSha256 : Text; types : Nat };

  // -- market-practice rule sets: CBPR+ and HVPS+ as data --------------------
  // motoko/iso/RuleSets.mo. A rule set evaluates an official-shape message after its schema passed; a
  // guideline profile may be bound to one, and the general validator applies the binding.

  public type RuleSetSummary = { id : Text; name : Text; authority : Text; basis : [Text]; reconciliation : Text; implemented : [(Text, Nat)]; ruleCount : Nat };
  public type RuleView = { id : Text; families : [Text]; check : Text; basis : Text };
  /// The general reading of an official-shape message: the family, the schema tier, the business reading
  /// when the family is one of the schema-profile codec's, and the rule set's disagreements.
  public type IsoDocumentReport = { family : Text; hasHeader : Bool; ruleSet : ?Text; report : ValidationReport };

  let profileRuleSets = Map.empty<Text, Text>();
  func ruleSetIdForProfile(profileId : Text) : ?Text {
    let canonical = canonicalGuidelineProfileId(profileId);
    switch (Map.get(profileRuleSets, Text.compare, canonical)) {
      case (?id) ?id;
      case null { if (canonical == cbprGuidelineProfileId) ?"CBPRPLUS" else null };
    }
  };

  public query func isoRuleSets() : async [RuleSetSummary] {
    Array.map<RuleSets.RuleSet, RuleSetSummary>(RuleSets.all(), func(rs) { { id = rs.id; name = rs.name; authority = rs.authority; basis = rs.basis; reconciliation = rs.reconciliation; implemented = RuleSets.implemented(rs); ruleCount = rs.rules.size() } })
  };
  public query func isoRuleSetRules(ruleSetId : Text) : async [RuleView] {
    switch (RuleSets.byId(ruleSetId)) {
      case (?rs) Array.map<RuleSets.Rule, RuleView>(rs.rules, func(r) { { id = r.id; families = r.families; check = RuleSets.checkText(r.check); basis = r.basis } });
      case null [];
    }
  };
  /// The rule set a guideline profile is bound to (CBPRPLUS-EDU is bound to CBPRPLUS unless rebound).
  public query func guidelineRuleSet(profileId : Text) : async ?Text { ruleSetIdForProfile(profileId) };
  public shared (msg) func bindGuidelineRuleSet(profileId : Text, ruleSetId : Text) : async Bool {
    Admin.requireAdmin(admin, msg.caller);
    ignore requireGuidelineProfile(profileId);
    if (RuleSets.byId(ruleSetId) == null) Runtime.trap("unknown rule set " # ruleSetId);
    Map.add(profileRuleSets, Text.compare, canonicalGuidelineProfileId(profileId), ruleSetId);
    true
  };

  func isoDocument(g : UsageGuideline, ruleSetId : ?Text, xml : Blob) : IsoDocumentReport {
    func fail(family : Text, hasHeader : Bool, issues : [ValidationIssue]) : IsoDocumentReport {
      { family; hasHeader; ruleSet = ruleSetId; report = ISO.reportFromIssues(g, family, Xml.codecVersion, issues) }
    };
    let roots = switch (IsoXml.parseMessage(xml)) {
      case (#err(e)) return fail("unknown", false, [ISO.publicIssue("schema", e.rule, "$xml@" # Nat.toText(e.offset), e.detail)]);
      case (#ok(rs)) rs;
    };
    if (roots.size() == 0 or roots.size() > 2) return fail("unknown", false, [ISO.publicIssue("schema", "XML-ROOT", "/", "a Document, or an AppHdr followed by a Document")]);
    let hasHeader = roots.size() == 2;
    let issues = List.empty<ValidationIssue>();
    if (hasHeader) {
      switch (IsoSchema.schemaFor(roots[0].namespace)) {
        case (?hs) { if (Breadth.shortFamily(hs.family) != "head.001") List.add(issues, ISO.publicIssue("schema", "XML-ROOT", "/" # roots[0].name, "the first element of a two-element message is a head.001 AppHdr")) else { for (i in IsoSchema.validate(hs, roots[0]).vals()) List.add(issues, ISO.publicIssue("schema", i.rule, "/AppHdr" # i.path, i.detail)) } };
        case null List.add(issues, ISO.publicIssue("schema", "ISO-XSD-ROOT", "/" # roots[0].name, "namespace " # roots[0].namespace # " is not a family this component carries"));
      };
    };
    let doc = roots[roots.size() - 1];
    let ?sc = IsoSchema.schemaFor(doc.namespace) else return fail("unknown", hasHeader, Array.concat(List.toArray(issues), [ISO.publicIssue("schema", "ISO-XSD-ROOT", "/" # doc.name, "namespace " # doc.namespace # " is not a family this component carries")]));
    let family = Breadth.shortFamily(sc.family);
    for (i in IsoSchema.validate(sc, doc).vals()) List.add(issues, ISO.publicIssue("schema", i.rule, i.path, i.detail));
    if (List.size(issues) > 0) return fail(sc.family, hasHeader, List.toArray(issues));
    // the business reading, where the schema-profile codec has one
    if (breadthFormat(family # ".xml")) {
      let bytes = Text.encodeUtf8(IsoXml.serialize(doc));
      let d = Breadth.decode(bytes, breadthMinorUnits(g));
      switch (d.message) { case (#err(e)) { for (i in e.vals()) List.add(issues, breadthIssue("business", i)) }; case (#ok(_)) {} };
    };
    // the rule set
    switch (ruleSetId) {
      case (?id) {
        switch (RuleSets.byId(id)) {
          case (?rs) {
            let msgRoot = if (doc.children.size() == 1) doc.children[0] else doc;
            for (i in RuleSets.evaluate(rs, family, msgRoot, hasHeader).vals()) List.add(issues, ISO.publicIssue("usageGuideline", i.rule, i.path, i.detail));
          };
          case null List.add(issues, ISO.publicIssue("usageGuideline", "RULESET-UNKNOWN", "$.ruleSet", "no rule set " # id));
        };
      };
      case null {};
    };
    fail(sc.family, hasHeader, List.toArray(issues))
  };

  /// An official-shape message (any of the 43 schema profiles, with or without its AppHdr) under the active
  /// guideline: the schema, the business reading, and the rule set the default profile is bound to.
  public query func validateIsoDocument(xml : Blob) : async IsoDocumentReport { isoDocument(guideline, ruleSetIdForProfile(defaultGuidelineProfileId), xml) };
  public query func validateIsoDocumentWithProfile(profileId : Text, xml : Blob) : async IsoDocumentReport { isoDocument(requireGuidelineForProfile(profileId), ruleSetIdForProfile(profileId), xml) };
  /// The same reading under a named rule set, whatever the profile binding.
  public query func validateIsoDocumentWithRuleSet(ruleSetId : Text, xml : Blob) : async IsoDocumentReport { isoDocument(guideline, ?ruleSetId, xml) };

  // -- the MT bridge: thirteen FIN message types ↔ the hub's records -------------
  // motoko/iso/MtBridge.mo. The legacy routes above ("mt103", "mt940", "mt942") are unchanged; the
  // bridge's route is "mt" (the type read from block 2) or the type itself ("mt202", "mt202cov", …).

  public type MtMessage = MtBridge.Message;
  public type MtMapping = MtBridge.Mapping;
  public type MtDecode = { mtType : Text; iso : Text; message : ?MtMessage; issues : [ValidationIssue] };
  public type MtParty = MtBridge.Party;

  let MT_BRIDGE_FORMATS : [Text] = ["mt", "mt101", "mt104", "mt202", "mt202cov", "mt900", "mt910", "mt950", "mt192", "mt196", "mt199"];
  func mtBridgeFormat(format : Text) : Bool { for (f in MT_BRIDGE_FORMATS.vals()) { if (f == format) return true }; false };

  /// Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm), for the records' creation date-time.
  func isoDateTimeNow() : Text {
    let ns = Time.now();
    let secs = if (ns < 0) 0 else Int.abs(ns) / 1_000_000_000;
    let days = secs / 86400;
    let rem = secs % 86400;
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if (mp < 10) mp + 3 else mp - 9;
    let year = if (m <= 2) y + 1 else y;
    func two(n : Nat) : Text { if (n < 10) "0" # Nat.toText(n) else Nat.toText(n) };
    Nat.toText(year) # "-" # two(m) # "-" # two(d) # "T" # two(rem / 3600) # ":" # two((rem % 3600) / 60) # ":" # two(rem % 60) # "Z"
  };
  func mtOptions(g : UsageGuideline) : MtBridge.Options {
    { creationDateTime = isoDateTimeNow(); settlementMethod = g.settlementMethod; country = defaultLegacyCountryForGuideline(g); versions = func(kind : Text) : Text { ISO.versionOf(g, kind) } }
  };
  func mtDecode(g : UsageGuideline, payload : Blob, hint : ?Text) : MtDecode {
    let d = MtBridge.decode(payload, hint, mtOptions(g), breadthMinorUnits(g));
    switch (d.message) {
      case (#ok(m)) { { mtType = d.mtType; iso = d.iso; message = ?m; issues = [] } };
      case (#err(e)) { { mtType = d.mtType; iso = d.iso; message = null; issues = e } };
    }
  };

  /// The bridge's message types and the ISO family each reads into.
  public query func mtBridgeTypes() : async [(Text, Text)] { Array.map<MtMapping, (Text, Text)>(MtBridge.mappings(), func(m) { (m.mt, m.iso) }) };
  /// The field-to-element mapping tables the bridge implements — the same data the fixture set carries.
  public query func mtBridgeMappings() : async [MtMapping] { MtBridge.mappings() };
  /// A FIN message read into its record under the active guideline; `hint` names the type when block 2 is absent.
  public query func decodeMt(payload : Blob, hint : ?Text) : async MtDecode { mtDecode(guideline, payload, hint) };
  public query func decodeMtWithProfile(profileId : Text, payload : Blob, hint : ?Text) : async MtDecode { mtDecode(requireGuidelineForProfile(profileId), payload, hint) };
  /// A record written as the named FIN type; `parties` names the envelope's institutions where the record does not.
  public query func encodeMt(message : MtMessage, mtType : Text, parties : MtParty) : async Result.Result<Text, [ValidationIssue]> {
    MtBridge.encode(message, mtType, parties, breadthMinorUnits(guideline))
  };

  /// A transport format the schema-profile codec routes: "<family>.xml" for one of its families.
  func breadthFormat(format : Text) : Bool {
    for (f in Breadth.FAMILIES.vals()) { if (format == Breadth.shortFamily(f) # ".xml") return true };
    false
  };

  /// The minor units of a currency under a guideline — what the codec needs to hold an amount exactly.
  func breadthMinorUnits(g : UsageGuideline) : Text -> ?Nat8 {
    func(code : Text) : ?Nat8 {
      for (c in g.currencies.vals()) { if (c.code == code) return ?Nat8.fromNat(c.fractionDigits) };
      null
    }
  };

  func breadthIssue(tier : Text, i : Breadth.Issue) : ValidationIssue { ISO.publicIssue(tier, i.rule, i.path, i.detail) };
  func breadthIssues(d : Breadth.Decoded) : [ValidationIssue] {
    let schema = Array.map<Breadth.Issue, ValidationIssue>(d.schemaIssues, func(i) { breadthIssue("schema", i) });
    switch (d.message) {
      case (#ok(_)) schema;
      case (#err(e)) Array.concat<ValidationIssue>(schema, Array.map<Breadth.Issue, ValidationIssue>(e, func(i) { breadthIssue("business", i) }));
    }
  };
  func breadthDecode(g : UsageGuideline, xml : Blob) : BreadthDecode {
    let d = Breadth.decode(xml, breadthMinorUnits(g));
    { family = d.family; schemaIssues = Array.map<Breadth.Issue, ValidationIssue>(d.schemaIssues, func(i) { breadthIssue("schema", i) }); message = (switch (d.message) { case (#ok(m)) ?m; case (#err(_)) null }); issues = breadthIssues(d) }
  };

  /// The families the schema-profile codec reads and writes, by message definition identifier.
  public query func isoBreadthFamilies() : async [Text] { Breadth.FAMILIES };

  /// Every official schema the canister carries as a generated profile: the compact codec's families,
  /// the business application header and the schema-profile codec's families (43).
  public query func isoSchemaProfiles() : async [SchemaProfileSummary] {
    Array.map<IsoProfiles.Schema, SchemaProfileSummary>(IsoProfiles.all(), func(s) { { family = s.family; namespace = s.namespace; rootName = s.rootName; schemaSha256 = s.schemaSha256; types = s.types.size() } })
  };

  public query func decodeIsoBreadth(xml : Blob) : async BreadthDecode { breadthDecode(guideline, xml) };
  public query func decodeIsoBreadthWithProfile(profileId : Text, xml : Blob) : async BreadthDecode { breadthDecode(requireGuidelineForProfile(profileId), xml) };

  public query func validateIsoBreadth(xml : Blob) : async ValidationReport {
    let d = breadthDecode(guideline, xml);
    ISO.reportFromIssues(guideline, d.family, Xml.codecVersion, d.issues)
  };
  public query func validateIsoBreadthWithProfile(profileId : Text, xml : Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    let d = breadthDecode(g, xml);
    ISO.reportFromIssues(g, d.family, Xml.codecVersion, d.issues)
  };

  /// A record written in its family's official shape, or the fields the schema needs and the record lacks.
  public query func encodeIsoBreadth(message : BreadthMessage, options : BreadthEmitOptions) : async Result.Result<Text, [ValidationIssue]> {
    switch (Breadth.emit(message, breadthMinorUnits(guideline), options)) {
      case (#ok(x)) #ok(x);
      case (#err(e)) #err(Array.map<Breadth.Issue, ValidationIssue>(e, func(i) { breadthIssue("business", i) }));
    }
  };

  /// The message read, written and read again: `#ok` is the written document when the two readings are
  /// equal — the property the integration kit's breadth runner asserts on every fixture.
  public query func roundTripIsoBreadth(xml : Blob, options : BreadthEmitOptions) : async Result.Result<Text, [ValidationIssue]> {
    switch (Breadth.roundTrip(xml, breadthMinorUnits(guideline), options)) {
      case (#ok(x)) #ok(x);
      case (#err(e)) #err(Array.map<Breadth.Issue, ValidationIssue>(e, func(i) { breadthIssue(if (Text.startsWith(i.rule, #text "ISO-XSD") or Text.startsWith(i.rule, #text "XML-")) "schema" else "business", i) }));
    }
  };

  public query func validatePain001Xml(xml : Blob) : async ValidationReport {
    switch (Xml.decodePain001(xml)) {
      case (#ok(doc)) ISO.validatePain001(guideline, doc, ?xml);
      case (#err(issues)) ISO.reportFromIssues(guideline, "pain.001.xml", Xml.codecVersion, issues);
    };
  };

  public query func validatePacs008Xml(xml : Blob) : async ValidationReport {
    switch (Xml.decodePacs008(xml)) {
      case (#ok(doc)) ISO.validatePacs008(guideline, doc, ?xml);
      case (#err(issues)) ISO.reportFromIssues(guideline, "pacs.008.xml", Xml.codecVersion, issues);
    };
  };

  public query func validatePacs009Xml(xml : Blob) : async ValidationReport {
    switch (Xml.decodePacs009(xml)) {
      case (#ok(doc)) ISO.validatePacs009(guideline, doc, ?xml);
      case (#err(issues)) ISO.reportFromIssues(guideline, "pacs.009.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateCoverPaymentXml(xml : Blob) : async ValidationReport {
    switch (Xml.decodeCoverPayment(xml)) {
      case (#ok(doc)) ISO.validateCoverPayment(guideline, doc, ?xml);
      case (#err(issues)) ISO.reportFromIssues(guideline, "cover.payment.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateInvestigationXml(xml : Blob) : async ValidationReport {
    switch (Xml.decodeInvestigation(xml)) {
      case (#ok(doc)) ISO.validateInvestigation(guideline, doc);
      case (#err(issues)) ISO.reportFromIssues(guideline, "investigation.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateRequestToPayXml(xml : Blob) : async ValidationReport {
    switch (Xml.decodeRequestToPay(xml)) {
      case (#ok(doc)) ISO.validateRequestToPay(guideline, doc);
      case (#err(issues)) ISO.reportFromIssues(guideline, "request-to-pay.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateDirectDebitXml(xml : Blob) : async ValidationReport {
    switch (Xml.decodeDirectDebit(xml)) {
      case (#ok(doc)) ISO.validateDirectDebit(guideline, doc, ?xml);
      case (#err(issues)) ISO.reportFromIssues(guideline, "direct-debit.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateAdministrativeXml(xml : Blob) : async ValidationReport {
    switch (Xml.decodeAdministrative(xml)) {
      case (#ok(doc)) ISO.validateAdministrativeMessage(guideline, doc);
      case (#err(issues)) ISO.reportFromIssues(guideline, "administrative.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateStatusReportXml(xml : Blob, expectedKind : ?Text) : async ValidationReport {
    switch (Xml.decodeStatusReport(xml)) {
      case (#ok(doc)) {
        let kind = switch (expectedKind) {
          case (?k) k;
          case null doc.messageKind;
        };
        ISO.validateStatusReport(guideline, doc, kind);
      };
      case (#err(issues)) ISO.reportFromIssues(guideline, "status-report.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateCamt053Xml(xml : Blob) : async ValidationReport {
    switch (Xml.decodeCamt053(xml)) {
      case (#ok(_)) ISO.reportFromIssues(guideline, "camt.053.xml", Xml.codecVersion, []);
      case (#err(issues)) ISO.reportFromIssues(guideline, "camt.053.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateCamt054Xml(xml : Blob) : async ValidationReport {
    switch (Xml.decodeCamt054(xml)) {
      case (#ok(_)) ISO.reportFromIssues(guideline, "camt.054.xml", Xml.codecVersion, []);
      case (#err(issues)) ISO.reportFromIssues(guideline, "camt.054.xml", Xml.codecVersion, issues);
    };
  };

  public query func validatePain001XmlWithProfile(profileId : Text, xml : Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    switch (Xml.decodePain001(xml)) {
      case (#ok(doc)) ISO.validatePain001(g, doc, ?xml);
      case (#err(issues)) ISO.reportFromIssues(g, "pain.001.xml", Xml.codecVersion, issues);
    };
  };

  public query func validatePacs008XmlWithProfile(profileId : Text, xml : Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    switch (Xml.decodePacs008(xml)) {
      case (#ok(doc)) ISO.validatePacs008(g, doc, ?xml);
      case (#err(issues)) ISO.reportFromIssues(g, "pacs.008.xml", Xml.codecVersion, issues);
    };
  };

  public query func validatePacs009XmlWithProfile(profileId : Text, xml : Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    switch (Xml.decodePacs009(xml)) {
      case (#ok(doc)) ISO.validatePacs009(g, doc, ?xml);
      case (#err(issues)) ISO.reportFromIssues(g, "pacs.009.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateCoverPaymentXmlWithProfile(profileId : Text, xml : Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    switch (Xml.decodeCoverPayment(xml)) {
      case (#ok(doc)) ISO.validateCoverPayment(g, doc, ?xml);
      case (#err(issues)) ISO.reportFromIssues(g, "cover.payment.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateInvestigationXmlWithProfile(profileId : Text, xml : Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    switch (Xml.decodeInvestigation(xml)) {
      case (#ok(doc)) ISO.validateInvestigation(g, doc);
      case (#err(issues)) ISO.reportFromIssues(g, "investigation.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateRequestToPayXmlWithProfile(profileId : Text, xml : Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    switch (Xml.decodeRequestToPay(xml)) {
      case (#ok(doc)) ISO.validateRequestToPay(g, doc);
      case (#err(issues)) ISO.reportFromIssues(g, "request-to-pay.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateDirectDebitXmlWithProfile(profileId : Text, xml : Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    switch (Xml.decodeDirectDebit(xml)) {
      case (#ok(doc)) ISO.validateDirectDebit(g, doc, ?xml);
      case (#err(issues)) ISO.reportFromIssues(g, "direct-debit.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateAdministrativeXmlWithProfile(profileId : Text, xml : Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    switch (Xml.decodeAdministrative(xml)) {
      case (#ok(doc)) ISO.validateAdministrativeMessage(g, doc);
      case (#err(issues)) ISO.reportFromIssues(g, "administrative.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateStatusReportXmlWithProfile(profileId : Text, xml : Blob, expectedKind : ?Text) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    switch (Xml.decodeStatusReport(xml)) {
      case (#ok(doc)) {
        let kind = switch (expectedKind) {
          case (?k) k;
          case null doc.messageKind;
        };
        ISO.validateStatusReport(g, doc, kind);
      };
      case (#err(issues)) ISO.reportFromIssues(g, "status-report.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateCamt053XmlWithProfile(profileId : Text, xml : Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    switch (Xml.decodeCamt053(xml)) {
      case (#ok(_)) ISO.reportFromIssues(g, "camt.053.xml", Xml.codecVersion, []);
      case (#err(issues)) ISO.reportFromIssues(g, "camt.053.xml", Xml.codecVersion, issues);
    };
  };

  public query func validateCamt054XmlWithProfile(profileId : Text, xml : Blob) : async ValidationReport {
    let g = requireGuidelineForProfile(profileId);
    switch (Xml.decodeCamt054(xml)) {
      case (#ok(_)) ISO.reportFromIssues(g, "camt.054.xml", Xml.codecVersion, []);
      case (#err(issues)) ISO.reportFromIssues(g, "camt.054.xml", Xml.codecVersion, issues);
    };
  };

  public query func pain001ToXml(doc : CustomerCreditTransferInitiation) : async Text {
    Xml.pain001ToXml(doc);
  };

  public query func pacs008ToXml(doc : Pacs008CreditTransfer) : async Text {
    Xml.pacs008ToXml(doc);
  };

  public query func pacs009ToXml(doc : Pacs009FinancialInstitutionCreditTransfer) : async Text {
    Xml.pacs009ToXml(doc);
  };

  public query func coverPaymentToXml(doc : CoverPayment) : async Text {
    Xml.coverPaymentToXml(doc);
  };

  public query func investigationToXml(doc : InvestigationMessage) : async Text {
    Xml.investigationToXml(doc);
  };

  public query func requestToPayToXml(doc : RequestToPayMessage) : async Text {
    Xml.requestToPayToXml(doc);
  };

  public query func directDebitToXml(doc : DirectDebitMessage) : async Text {
    Xml.directDebitToXml(doc);
  };

  public query func administrativeToXml(doc : AdministrativeMessage) : async Text {
    Xml.administrativeToXml(doc);
  };

  public query func complianceReportToXml(report : ComplianceReport) : async Text {
    Xml.complianceReportToXml(report);
  };

  public query func statusReportToXml(doc : StatusReport) : async Text {
    Xml.statusReportToXml(doc);
  };

  public query func demoPain001Xml() : async Text {
    Xml.pain001ToXml(ISO.demoPain001());
  };

  public query func demoPacs008Xml() : async Text {
    Xml.pacs008ToXml(ISO.demoPacs008());
  };

  public query func demoPacs009Xml() : async Text {
    Xml.pacs009ToXml(ISO.demoPacs009Core());
  };

  public query func demoCoverPaymentXml() : async Text {
    Xml.coverPaymentToXml(ISO.demoCoverPayment());
  };

  public query func demoCamt056Xml() : async Text {
    Xml.investigationToXml(ISO.demoCamt056());
  };

  public query func demoCamt110Xml() : async Text {
    Xml.investigationToXml(ISO.demoCamt110());
  };

  public query func demoCamt111Xml() : async Text {
    Xml.investigationToXml(ISO.demoCamt111());
  };

  public query func demoPain013Xml() : async Text {
    Xml.requestToPayToXml(ISO.demoPain013());
  };

  public query func demoPain014AcceptedXml() : async Text {
    Xml.requestToPayToXml(ISO.demoPain014Accepted());
  };

  public query func demoCamt055Xml() : async Text {
    Xml.requestToPayToXml(ISO.demoCamt055());
  };

  public query func demoPain008Xml() : async Text {
    Xml.directDebitToXml(ISO.demoPain008());
  };

  public query func demoPacs003Xml() : async Text {
    Xml.directDebitToXml(ISO.demoPacs003());
  };

  public query func demoAdmi002RejectXml() : async Text {
    Xml.administrativeToXml(ISO.demoAdmi002Reject());
  };

  public query func demoAdmi004ConnectionCheckXml() : async Text {
    Xml.administrativeToXml(ISO.demoAdmi004ConnectionCheck());
  };

  public query func demoAdmi007AckXml() : async Text {
    Xml.administrativeToXml(ISO.demoAdmi007Ack());
  };

  public query func demoAdmi011ConnectionAckXml() : async Text {
    Xml.administrativeToXml(ISO.demoAdmi011ConnectionAck());
  };

  public query func demoComplianceReportXml() : async Text {
    Xml.complianceReportToXml(ISO.screenCoverPayment(complianceProfile, ISO.demoCoverPayment()));
  };

  // -- Hub lifecycle ------------------------------------------------------
  public shared (msg) func submitPain001(instruction : CustomerCreditTransferInitiation, rawXml : ?Blob) : async HubPayment {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    submitPain001Core(msg.caller, instruction, rawXml);
  };

  public shared (msg) func submitPain001WithProfile(profileId : Text, instruction : CustomerCreditTransferInitiation, rawXml : ?Blob) : async HubPayment {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    let g = requireGuidelineForProfile(profileId);
    submitPain001CoreWithGuideline(msg.caller, instruction, rawXml, g);
  };

  public shared (msg) func submitDemoPain001() : async HubPayment {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    submitPain001Core(msg.caller, ISO.demoPain001(), null);
  };

  public shared (msg) func submitPain001Xml(xml : Blob) : async SubmitXmlResult {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    switch (Xml.decodePain001(xml)) {
      case (#ok(instruction)) #ok(submitPain001Core(msg.caller, instruction, ?xml));
      case (#err(issues)) #err(ISO.reportFromIssues(guideline, "pain.001.xml", Xml.codecVersion, issues));
    };
  };

  public shared (msg) func submitPain001XmlWithProfile(profileId : Text, xml : Blob) : async SubmitXmlResult {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    let g = requireGuidelineForProfile(profileId);
    switch (Xml.decodePain001(xml)) {
      case (#ok(instruction)) #ok(submitPain001CoreWithGuideline(msg.caller, instruction, ?xml, g));
      case (#err(issues)) #err(ISO.reportFromIssues(g, "pain.001.xml", Xml.codecVersion, issues));
    };
  };

  func submitPain001Core(caller : Principal, instruction : CustomerCreditTransferInitiation, rawXml : ?Blob) : HubPayment {
    submitPain001CoreWithGuideline(caller, instruction, rawXml, guideline);
  };

  func submitPain001CoreWithGuideline(caller : Principal, instruction : CustomerCreditTransferInitiation, rawXml : ?Blob, g : UsageGuideline) : HubPayment {
    let id = nextPaymentId;
    nextPaymentId += 1;

    let now = Time.now();
    let uetr = switch (instruction.requestedUetr) {
      case (?requested) requested;
      case null deriveUetr(caller, instruction, now);
    };
    let pacs = ISO.pacs008FromPain001(g, instruction, uetr, instruction.creationDateTime);

    let uetrBloomHit = Bloom.mightContain(uetrBloom, uetr);
    let msgBloomHit = Bloom.mightContain(messageIdBloom, instruction.messageId);
    let exactUetrHit = hasTextIndex(paymentByUetr, uetr);
    let exactMessageHit = hasTextIndex(paymentByMessageId, instruction.messageId);
    let duplicateSignal : DuplicateSignal = {
      uetrBloomMightContain = uetrBloomHit;
      messageIdBloomMightContain = msgBloomHit;
      exactUetrDuplicate = exactUetrHit;
      exactMessageIdDuplicate = exactMessageHit;
    };

    var extraIssues : [ValidationIssue] = [];
    if (exactUetrHit) {
      extraIssues := addIssue(extraIssues, ISO.publicIssue("business", "DUPLICATE-UETR", "$.requestedUetr", "UETR already exists in the exact payment index"));
    };
    if (exactMessageHit) {
      extraIssues := addIssue(extraIssues, ISO.publicIssue("business", "DUPLICATE-MSGID", "$.messageId", "messageId already exists in the exact payment index"));
    };

    let painReport = ISO.validatePain001(g, instruction, rawXml);
    let pacsReport = ISO.validatePacs008(g, pacs, null);
    let validationReport = combineReportsWithGuideline(g, "hub.submit", "pain.001+pacs.008", [painReport, pacsReport], extraIssues);
    let complianceReport = ISO.screenPacs008(complianceProfile, pacs);
    let complianceAction = complianceActionForReport(validationReport, complianceReport);
    let auditReport = if (validationReport.ok and complianceReport.decision != "pass") {
      reportWithComplianceIssues(g, validationReport, complianceReport);
    } else {
      validationReport;
    };
    let complianceRecord : ComplianceScreeningRecord = {
      paymentId = id;
      screenedAt = now;
      profileId = complianceReport.profileId;
      decision = complianceReport.decision;
      riskScore = complianceReport.riskScore;
      findingCount = complianceReport.findingCount;
      action = complianceAction;
      report = complianceReport;
    };
    let pain002 = ISO.pain002FromValidation(g, "PAIN002-" # Nat.toText(id), instruction.messageId, uetr, instruction.creationDateTime, validationReport);
    let audit = auditPacs008Core(caller, pacs, rawXml, auditReport);
    let status = if (not validationReport.ok) {
      "rejected"
    } else if (complianceReport.decision == "pass") {
      "accepted"
    } else {
      "held"
    };
    var history = [
      event(now, caller, "pain.001.received", "customer credit transfer initiation received"),
      event(now, caller, "pain.002." # pain002.transactionStatus, "customer status report generated"),
    ];
    if (validationReport.ok) {
      history := Array.concat<PaymentEvent>(history, [
        event(now, caller, "compliance." # complianceAction, complianceHistoryDetail(complianceReport)),
      ]);
    };
    let payment : HubPayment = {
      id;
      createdAt = now;
      updatedAt = now;
      submittedBy = caller;
      messageId = instruction.messageId;
      uetr;
      instruction;
      pacs008 = pacs;
      status;
      validationReport = validationReport;
      pain002;
      pacs002 = null;
      returnReport = null;
      auditId = audit.id;
      duplicateSignal;
      settlement = null;
      history;
    };
    Map.add(payments, Nat.compare, id, payment);
    Map.add(complianceScreeningRecords, Nat.compare, id, complianceRecord);
    indexPayment(payment);
    if (not exactUetrHit) Map.add(paymentByUetr, Text.compare, uetr, id);
    if (not exactMessageHit) Map.add(paymentByMessageId, Text.compare, instruction.messageId, id);
    uetrBloom := Bloom.add(uetrBloom, uetr);
    messageIdBloom := Bloom.add(messageIdBloom, instruction.messageId);
    payment;
  };

  public shared (msg) func dispatchPacs008(paymentId : Nat) : async Pacs008CreditTransfer {
    Admin.requireAdmin(admin, msg.caller);
    let p = requirePayment(paymentId);
    if (p.status != "accepted") Runtime.trap("payment must be accepted before dispatch");
    let now = Time.now();
    assertOperatingDayAllowsSettlement(p.pacs008.instructedAmount.currency, now);
    let next = if (settlementEnabled) {
      assertLiquidityAvailableForPayment(p, null);
      await settleGrossPaymentOnIcrcMe(p, msg.caller, now);
    } else {
      markPaymentDispatched(p, msg.caller, now);
    };
    Map.add(payments, Nat.compare, paymentId, next);
    indexPayment(next);
    next.pacs008;
  };

  public shared (msg) func dispatchOrQueuePacs008(paymentId : Nat, priority : Nat, bypassFifo : Bool) : async SettlementDispatchResult {
    Admin.requireAdmin(admin, msg.caller);
    let p = requirePayment(paymentId);
    if (p.status != "accepted") Runtime.trap("payment must be accepted before dispatch");
    let now = Time.now();
    assertOperatingDayAllowsSettlement(p.pacs008.instructedAmount.currency, now);
    if (not settlementEnabled) {
      let next = markPaymentDispatched(p, msg.caller, now);
      Map.add(payments, Nat.compare, paymentId, next);
      indexPayment(next);
      return #dispatched(next);
    };
    let check = liquidityCheckForPayment(p, null);
    if (not check.ok) {
      let reason = switch (check.reason) {
        case (?text) text;
        case null "payment queued by liquidity policy";
      };
      let entry = queueSettlementPaymentCore(p, priority, bypassFifo, reason, now);
      let next = markPaymentQueued(p, msg.caller, now, reason);
      Map.add(payments, Nat.compare, paymentId, next);
      indexPayment(next);
      return #queued(entry);
    };
    let next = await settleGrossPaymentOnIcrcMe(p, msg.caller, now);
    Map.add(payments, Nat.compare, paymentId, next);
    indexPayment(next);
    #settled(next);
  };

  public shared (msg) func queueSettlementPayment(paymentId : Nat, priority : Nat, bypassFifo : Bool, reason : Text) : async SettlementQueueEntry {
    Admin.requireAdmin(admin, msg.caller);
    let p = requirePayment(paymentId);
    if (p.status != "accepted") Runtime.trap("payment must be accepted before queueing");
    let now = Time.now();
    assertOperatingDayAllowsSettlement(p.pacs008.instructedAmount.currency, now);
    let entry = queueSettlementPaymentCore(p, priority, bypassFifo, reason, now);
    let next = markPaymentQueued(p, msg.caller, now, reason);
    Map.add(payments, Nat.compare, paymentId, next);
    indexPayment(next);
    entry;
  };

  public shared (msg) func settleQueuedPacs008(paymentId : Nat) : async HubPayment {
    Admin.requireAdmin(admin, msg.caller);
    let p = requirePayment(paymentId);
    if (p.status != "queued") Runtime.trap("payment must be queued before queued settlement");
    assertQueueEntry(paymentId);
    assertLiquidityAvailableForPayment(p, ?paymentId);
    let now = Time.now();
    assertOperatingDayAllowsSettlement(p.pacs008.instructedAmount.currency, now);
    let next = await settleGrossPaymentOnIcrcMe(p, msg.caller, now);
    removeSettlementQueueEntry(paymentId);
    Map.add(payments, Nat.compare, paymentId, next);
    indexPayment(next);
    next;
  };

  public shared (msg) func resolveQueuedSettlementOffset(paymentIdA : Nat, paymentIdB : Nat) : async SettlementOffsetResult {
    Admin.requireAdmin(admin, msg.caller);
    if (paymentIdA == paymentIdB) Runtime.trap("offset requires two distinct payments");
    if (not settlementEnabled) Runtime.trap("settlement ledger must be enabled before offset settlement");
    assertQueueEntry(paymentIdA);
    assertQueueEntry(paymentIdB);
    let pA = requirePayment(paymentIdA);
    let pB = requirePayment(paymentIdB);
    if (pA.status != "queued" or pB.status != "queued") Runtime.trap("both payments must be queued before offset settlement");
    if (pA.pacs008.debtorAgent.bicfi != pB.pacs008.creditorAgent.bicfi or pA.pacs008.creditorAgent.bicfi != pB.pacs008.debtorAgent.bicfi) {
      Runtime.trap("offset payments must have opposite debtor/creditor agents");
    };
    if (pA.pacs008.instructedAmount.currency != pB.pacs008.instructedAmount.currency) {
      Runtime.trap("offset payments must use the same currency");
    };
    let now = Time.now();
    assertOperatingDayAllowsSettlement(pA.pacs008.instructedAmount.currency, now);
    let amountA = pA.pacs008.instructedAmount.minorUnits;
    let amountB = pB.pacs008.instructedAmount.minorUnits;
    let ledgerPrincipal = requireSettlementLedgerCanister();
    let mode = "icrc2_transfer_from_offset_net";
    let net = Int.abs((amountA : Int) - (amountB : Int));
    if (net > 0) {
      if (amountA > amountB) {
        assertDebitAmountWithinLimit(pA.pacs008.debtorAgent.bicfi, net, ?paymentIdA);
      } else {
        assertDebitAmountWithinLimit(pB.pacs008.debtorAgent.bicfi, net, ?paymentIdB);
      };
    };
    let receipt = if (net == 0) {
      null;
    } else if (amountA > amountB) {
      ?(await settleIcrcMeTransfer(
        pA.pacs008.debtorAgent.bicfi,
        pA.pacs008.creditorAgent.bicfi,
        { currency = pA.pacs008.instructedAmount.currency; minorUnits = net },
        Text.encodeUtf8("iso20022:offset:" # Nat.toText(paymentIdA) # ":" # Nat.toText(paymentIdB)),
        mode,
        now,
      ));
    } else {
      ?(await settleIcrcMeTransfer(
        pB.pacs008.debtorAgent.bicfi,
        pB.pacs008.creditorAgent.bicfi,
        { currency = pB.pacs008.instructedAmount.currency; minorUnits = net },
        Text.encodeUtf8("iso20022:offset:" # Nat.toText(paymentIdB) # ":" # Nat.toText(paymentIdA)),
        mode,
        now,
      ));
    };
    let blockIndex = switch (receipt) {
      case (?r) ?r.ledgerBlockIndex;
      case null null;
    };
    let nextA = markPaymentOffsetSettled(pA, msg.caller, now, ledgerPrincipal, blockIndex, mode);
    let nextB = markPaymentOffsetSettled(pB, msg.caller, now, ledgerPrincipal, blockIndex, mode);
    removeSettlementQueueEntry(paymentIdA);
    removeSettlementQueueEntry(paymentIdB);
    Map.add(payments, Nat.compare, paymentIdA, nextA);
    Map.add(payments, Nat.compare, paymentIdB, nextB);
    indexPayment(nextA);
    indexPayment(nextB);
    {
      paymentA = nextA;
      paymentB = nextB;
      netAmountMinorUnits = net;
      netDebtorAgent = if (net == 0) null else if (amountA > amountB) ?pA.pacs008.debtorAgent.bicfi else ?pB.pacs008.debtorAgent.bicfi;
      netCreditorAgent = if (net == 0) null else if (amountA > amountB) ?pA.pacs008.creditorAgent.bicfi else ?pB.pacs008.creditorAgent.bicfi;
      ledgerBlockIndex = blockIndex;
      transferMode = if (net == 0) "offset.zero_net" else mode;
    };
  };

  public shared (msg) func acknowledgePacs002(paymentId : Nat, transactionStatus : Text, reason : ?Text) : async HubPayment {
    Admin.requireAdmin(admin, msg.caller);
    if (not ISO.validTransactionStatus(transactionStatus)) Runtime.trap("unsupported transaction status");
    let p = requirePayment(paymentId);
    if (p.status != "dispatched" and p.status != "accepted") Runtime.trap("payment must be accepted or dispatched before pacs.002 acknowledgement");
    let now = Time.now();
    let ack = ISO.pacs002(
      guideline,
      "PACS002-" # Nat.toText(paymentId),
      p.messageId,
      p.uetr,
      transactionStatus,
      reason,
      p.pacs008.creationDateTime,
    );
    let ackReport = ISO.validateStatusReport(guideline, ack, "pacs.002");
    if (not ackReport.ok) Runtime.trap("generated pacs.002 failed validation");
    let nextStatus = if (transactionStatus == "ACSC") {
      "settled"
    } else if (transactionStatus == "RJCT") {
      "rejected"
    } else {
      "dispatched"
    };
    let next = {
      p with
      status = nextStatus;
      updatedAt = now;
      pacs002 = ?ack;
      history = appendEvent(p.history, event(now, msg.caller, "pacs.002." # transactionStatus, "FI-to-FI payment status report acknowledged"));
    };
    Map.add(payments, Nat.compare, paymentId, next);
    indexPayment(next);
    next;
  };

  public shared (msg) func returnPayment(paymentId : Nat, reason : Text) : async HubPayment {
    Admin.requireAdmin(admin, msg.caller);
    let p = requirePayment(paymentId);
    if (p.status != "settled" and p.status != "dispatched") Runtime.trap("payment must be settled or dispatched before return");
    let now = Time.now();
    let ret = ISO.pacs004(
      guideline,
      "PACS004-" # Nat.toText(paymentId),
      p.messageId,
      p.uetr,
      "return: " # reason,
      p.pacs008.creationDateTime,
    );
    let next = {
      p with
      status = "returned";
      updatedAt = now;
      returnReport = ?ret;
      history = appendEvent(p.history, event(now, msg.caller, "pacs.004.returned", reason));
    };
    Map.add(payments, Nat.compare, paymentId, next);
    indexPayment(next);
    next;
  };

  func applyInboundStatusReport(caller : Principal, doc : StatusReport, g : UsageGuideline) : StatusApplicationResult {
    let expectedKind = doc.messageKind;
    let report = ISO.validateStatusReport(g, doc, expectedKind);
    var issues = report.issues;
    if (not (expectedKind == "pacs.002" or expectedKind == "pacs.004")) {
      issues := addIssue(issues, ISO.publicIssue("business", "STATUS-APPLY-KIND", "$.messageKind", "only pacs.002 and pacs.004 inbound status reports mutate payment state"));
    };
    let paymentId = Map.get(paymentByMessageId, Text.compare, doc.originalMessageId);
    switch (paymentId) {
      case null {
        issues := addIssue(issues, ISO.publicIssue("business", "STATUS-ORIGINAL-MSG-NOT-FOUND", "$.originalMessageId", "original message id does not match a stored payment"));
        { paymentId = null; issues };
      };
      case (?id) {
        switch (Map.get(payments, Nat.compare, id)) {
          case null {
            issues := addIssue(issues, ISO.publicIssue("business", "STATUS-PAYMENT-MISSING", "$.originalMessageId", "payment index points to a missing payment"));
            { paymentId = ?id; issues };
          };
          case (?p) {
            if (p.uetr != doc.originalUetr) {
              issues := addIssue(issues, ISO.publicIssue("business", "STATUS-UETR-MISMATCH", "$.originalUetr", "status report original UETR does not match the stored payment"));
            };
            if (expectedKind == "pacs.002") {
              switch (p.pacs002) {
                case (?_) issues := addIssue(issues, ISO.publicIssue("business", "STATUS-PACS002-DUPLICATE", "$.pacs002", "payment already has an applied pacs.002 status report"));
                case null {};
              };
              if (p.status != "accepted" and p.status != "dispatched") {
                issues := addIssue(issues, ISO.publicIssue("business", "STATUS-PACS002-LIFECYCLE", "$.status", "pacs.002 can only be applied to accepted or dispatched payments"));
              };
            };
            if (expectedKind == "pacs.004") {
              switch (p.returnReport) {
                case (?_) issues := addIssue(issues, ISO.publicIssue("business", "STATUS-PACS004-DUPLICATE", "$.returnReport", "payment already has an applied pacs.004 return report"));
                case null {};
              };
              if (p.status != "settled" and p.status != "dispatched") {
                issues := addIssue(issues, ISO.publicIssue("business", "STATUS-PACS004-LIFECYCLE", "$.status", "pacs.004 can only be applied to settled or dispatched payments"));
              };
              switch (doc.reason) {
                case (?_) {};
                case null issues := addIssue(issues, ISO.publicIssue("business", "STATUS-PACS004-REASON", "$.reason", "pacs.004 return requires a reason"));
              };
            };
            if (issues.size() > 0) return { paymentId = ?id; issues };
            let now = Time.now();
            let next = if (expectedKind == "pacs.002") {
              let nextStatus = if (doc.transactionStatus == "ACSC") {
                "settled";
              } else if (doc.transactionStatus == "RJCT") {
                "rejected";
              } else {
                "dispatched";
              };
              {
                p with
                status = nextStatus;
                updatedAt = now;
                pacs002 = ?doc;
                history = appendEvent(p.history, event(now, caller, "pacs.002." # doc.transactionStatus, "inbound FI-to-FI status report applied"));
              };
            } else {
              {
                p with
                status = "returned";
                updatedAt = now;
                returnReport = ?doc;
                history = appendEvent(p.history, event(now, caller, "pacs.004.returned", "inbound payment return applied"));
              };
            };
            Map.add(payments, Nat.compare, id, next);
            indexPayment(next);
            { paymentId = ?id; issues = [] };
          };
        };
      };
    };
  };

  public query func getPayment(id : Nat) : async ?HubPayment {
    Map.get(payments, Nat.compare, id);
  };

  public query func getPaymentByUetr(uetr : Text) : async ?HubPayment {
    switch (Map.get(paymentByUetr, Text.compare, uetr)) {
      case (?id) Map.get(payments, Nat.compare, id);
      case null null;
    };
  };

  public query func paymentCount() : async Nat {
    Map.size(payments);
  };

  public query func listPayments(offset : Nat, limit : Nat) : async Pagination.Page<HubPayment> {
    Pagination.page<HubPayment>(Iter.toArray(Map.values(payments)), offset, limit);
  };

  public query func listPaymentViews(offset : Nat, limit : Nat) : async Pagination.Page<PaymentView> {
    let views = Array.map<HubPayment, PaymentView>(Iter.toArray(Map.values(payments)), paymentView);
    Pagination.page<PaymentView>(views, offset, limit);
  };

  public query func listPaymentViewsByStatus(status : Text, offset : Nat, limit : Nat) : async Pagination.Page<PaymentView> {
    paymentViewPageFromIds(OrderedIndex.prefix(paymentStatusIndex, OrderedIndex.keyPart(status), 0, Map.size(payments)), offset, limit);
  };

  public query func listPaymentViewsByStatusStable(status : Text, offset : Nat, limit : Nat) : async Pagination.Page<PaymentView> {
    paymentViewPageFromIds(StableOrderedIndex.prefix(paymentStatusStableIndex, OrderedIndex.keyPart(status), 0, Map.size(payments)), offset, limit);
  };

  public query func listPaymentViewsByCreditorAgent(bicfi : Text, offset : Nat, limit : Nat) : async Pagination.Page<PaymentView> {
    paymentViewPageFromIds(OrderedIndex.prefix(paymentCreditorAgentIndex, OrderedIndex.keyPart(bicfi), 0, Map.size(payments)), offset, limit);
  };

  public query func listPaymentViewsByCreditorAgentStable(bicfi : Text, offset : Nat, limit : Nat) : async Pagination.Page<PaymentView> {
    paymentViewPageFromIds(StableOrderedIndex.prefix(paymentCreditorAgentStableIndex, OrderedIndex.keyPart(bicfi), 0, Map.size(payments)), offset, limit);
  };

  public query func camt053Statement(offset : Nat, limit : Nat) : async Pagination.Page<StatementEntry> {
    let entries = Array.map<HubPayment, StatementEntry>(Iter.toArray(Map.values(payments)), statementEntry);
    Pagination.page<StatementEntry>(entries, offset, limit);
  };

  public query func camt053StatementByAccount(accountId : Text, fromBookedAtInclusive : Int, toBookedAtExclusive : Int, offset : Nat, limit : Nat) : async Pagination.Page<StatementEntry> {
    let from = OrderedIndex.join([OrderedIndex.keyPart(accountId), OrderedIndex.intPart(fromBookedAtInclusive)]);
    let to = OrderedIndex.join([OrderedIndex.keyPart(accountId), OrderedIndex.intPart(toBookedAtExclusive)]);
    statementPageFromIds(OrderedIndex.range(paymentAccountIndex, from, to, 0, Map.size(payments)), offset, limit);
  };

  public query func camt053StatementByAccountStable(accountId : Text, fromBookedAtInclusive : Int, toBookedAtExclusive : Int, offset : Nat, limit : Nat) : async Pagination.Page<StatementEntry> {
    let from = OrderedIndex.join([OrderedIndex.keyPart(accountId), OrderedIndex.intPart(fromBookedAtInclusive)]);
    let to = OrderedIndex.join([OrderedIndex.keyPart(accountId), OrderedIndex.intPart(toBookedAtExclusive)]);
    statementPageFromIds(StableOrderedIndex.range(paymentAccountStableIndex, from, to, 0, Map.size(payments)), offset, limit);
  };

  public query func camt054Notification(paymentId : Nat) : async ?StatementEntry {
    switch (Map.get(payments, Nat.compare, paymentId)) {
      case (?p) ?statementEntry(p);
      case null null;
    };
  };

  public query func camt053Xml(offset : Nat, limit : Nat) : async Text {
    let all = Array.map<HubPayment, StatementEntry>(Iter.toArray(Map.values(payments)), statementEntry);
    let page = Pagination.page<StatementEntry>(all, offset, limit);
    Xml.camt053ToXml(page.items);
  };

  public query func camt053XmlByAccount(accountId : Text, fromBookedAtInclusive : Int, toBookedAtExclusive : Int, offset : Nat, limit : Nat) : async Text {
    let from = OrderedIndex.join([OrderedIndex.keyPart(accountId), OrderedIndex.intPart(fromBookedAtInclusive)]);
    let to = OrderedIndex.join([OrderedIndex.keyPart(accountId), OrderedIndex.intPart(toBookedAtExclusive)]);
    let page = statementPageFromIds(OrderedIndex.range(paymentAccountIndex, from, to, 0, Map.size(payments)), offset, limit);
    Xml.camt053ToXml(page.items);
  };

  public query func camt054Xml(paymentId : Nat) : async ?Text {
    switch (Map.get(payments, Nat.compare, paymentId)) {
      case (?p) ?Xml.camt054ToXml(statementEntry(p));
      case null null;
    };
  };

  public query func paymentXmlBundle(paymentId : Nat) : async ?PaymentXmlBundle {
    switch (Map.get(payments, Nat.compare, paymentId)) {
      case null null;
      case (?p) ?{
        codecVersion = Xml.codecVersion;
        pain001Xml = Xml.pain001ToXml(p.instruction);
        pacs008Xml = Xml.pacs008ToXml(p.pacs008);
        pain002Xml = Xml.statusReportToXml(p.pain002);
        pacs002Xml = switch (p.pacs002) { case (?ack) ?Xml.statusReportToXml(ack); case null null };
        returnXml = switch (p.returnReport) { case (?ret) ?Xml.statusReportToXml(ret); case null null };
        camt054Xml = Xml.camt054ToXml(statementEntry(p));
      };
    };
  };

  public query func duplicateSignalFor(messageId : Text, uetr : Text) : async DuplicateSignal {
    {
      uetrBloomMightContain = Bloom.mightContain(uetrBloom, uetr);
      messageIdBloomMightContain = Bloom.mightContain(messageIdBloom, messageId);
      exactUetrDuplicate = hasTextIndex(paymentByUetr, uetr);
      exactMessageIdDuplicate = hasTextIndex(paymentByMessageId, messageId);
    };
  };

  public query func duplicateFilterInfo() : async DuplicateFilterInfo {
    {
      bits = Bloom.BITS;
      hashes = Bloom.HASHES;
      uetrFillPermille = Bloom.fillRatioPermille(uetrBloom);
      messageIdFillPermille = Bloom.fillRatioPermille(messageIdBloom);
      exactUetrIndexSize = Map.size(paymentByUetr);
      exactMessageIdIndexSize = Map.size(paymentByMessageId);
      note = "Bloom filters are advisory; exact maps are the source of truth for duplicate rejection.";
    };
  };

  public query func verifyPaymentPhases(paymentId : Nat) : async [PhaseVerification] {
    switch (Map.get(payments, Nat.compare, paymentId)) {
      case null [
        ISO.phaseVerification(
          "lookup",
          ISO.reportFromIssues(guideline, "hub.payment", "internal", [ISO.publicIssue("business", "PAYMENT-NOT-FOUND", "$.paymentId", "payment does not exist")]),
        )
      ];
      case (?p) {
        var phases : [PhaseVerification] = [
          ISO.phaseVerification("pain.001.intake", ISO.validatePain001(guideline, p.instruction, null)),
          ISO.phaseVerification("pacs.008.transform", ISO.validatePacs008(guideline, p.pacs008, null)),
          ISO.phaseVerification("pain.002.customer-status", ISO.validateStatusReport(guideline, p.pain002, "pain.002")),
          ISO.phaseVerification("audit.evidence", verifyPaymentAuditReport(p)),
          ISO.phaseVerification("duplicate.indexes", verifyPaymentIndexReport(p)),
        ];
        switch (p.pacs002) {
          case (?ack) {
            phases := Array.concat<PhaseVerification>(phases, [ISO.phaseVerification("pacs.002.bank-status", ISO.validateStatusReport(guideline, ack, "pacs.002"))]);
          };
          case null {};
        };
        switch (p.settlement) {
          case (?_) {
            phases := Array.concat<PhaseVerification>(phases, [ISO.phaseVerification("settlement.icrc-me", verifySettlementReport(p))]);
          };
          case null {};
        };
        switch (p.returnReport) {
          case (?ret) {
            phases := Array.concat<PhaseVerification>(phases, [ISO.phaseVerification("pacs.004.return", ISO.validateStatusReport(guideline, ret, "pacs.004"))]);
          };
          case null {};
        };
        phases;
      };
    };
  };

  public query func oraclePhaseRegistry() : async [PhaseOracleSpec] {
    Oracles.registry();
  };

  public query func verifyOraclePhases() : async [PhaseVerification] {
    oraclePhaseVerifications();
  };

  public query func verifyOracleReadiness() : async OracleReadiness {
    let phases = oraclePhaseVerifications();
    var failing = 0;
    for (p in phases.vals()) {
      if (not p.ok) failing += 1;
    };
    {
      ok = failing == 0;
      phaseCount = phases.size();
      failingCount = failing;
      generatedAt = Time.now();
      registryVersion = Oracles.registryVersion;
      phases;
    };
  };

  // -- Discovery ----------------------------------------------------------
  public query func supportedStandards() : async [SupportedStandard] {
    [
      { name = "ISO 20022"; url = "https://www.iso20022.org/" },
      { name = "head.001"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "pain.001"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "pain.002"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "pain.008"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "pain.013"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "pain.014"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "pacs.003"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "pacs.008"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "pacs.009"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "pacs.002"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "pacs.004"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "pacs.028"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "camt.029"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "camt.055"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "camt.056"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "camt.110"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "camt.111"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "admi.002"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "admi.004"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "admi.007"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "admi.011"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "camt.053"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "camt.054"; url = "https://www.iso20022.org/iso-20022-message-definitions" },
      { name = "EPC SEPA Credit Transfer public guidelines"; url = "https://www.europeanpaymentscouncil.eu/what-we-do/epc-payment-schemes/sepa-credit-transfer/sepa-credit-transfer-rulebook-and" },
      { name = "EPC SEPA Instant Credit Transfer public guidelines"; url = "https://www.europeanpaymentscouncil.eu/what-we-do/epc-payment-schemes/sepa-instant-credit-transfer/sepa-instant-credit-transfer-rulebook" },
      { name = "EPC SEPA Direct Debit public guidelines"; url = "https://www.europeanpaymentscouncil.eu/what-we-do/epc-payment-schemes/sepa-direct-debit/sepa-direct-debit-core-rulebook-and-implementation" },
      { name = "Fedwire ISO 20022 public implementation center"; url = "https://www.frbservices.org/resources/financial-services/wires/iso-20022-implementation-center" },
      { name = "FedNow ISO 20022 public readiness guide"; url = "https://explore.fednow.org/resources/readiness-guide-iso-20022.pdf" },
      { name = "BIS CPMI ISO 20022 harmonisation requirements"; url = "https://www.bis.org/cpmi/publ/d215.pdf" },
      { name = "ISO 9362 BIC"; url = "https://www.iso.org/standard/60390.html" },
      { name = "ISO 13616 IBAN"; url = "https://www.iso.org/standard/81090.html" },
      { name = "ISO 17442 LEI"; url = "https://www.iso.org/standard/78829.html" },
      { name = "ISO 4217 Currency"; url = "https://www.iso.org/iso-4217-currency-codes.html" },
      { name = "SWIFT MT103 legacy compatibility subset"; url = "https://www.swift.com/standards" },
      { name = "SWIFT MT940/MT942 legacy statement compatibility subset"; url = "https://www.swift.com/standards" },
      { name = "CSV/fixed-width legacy file compatibility profiles"; url = "integration-kit/legacy/README.md" },
      { name = "ICRC-ME audit posture"; url = "https://github.com/Mercatura-Forum/Thebes-Protocol-/tree/main/examples/icrc-me" },
    ];
  };

  public query func capabilities() : async [Capability] {
    [
      { name = "egypt-bank-integration-baseline"; status = "implemented"; notes = "Egyptian IBAN shape, EG BIC country rules, EGP activation, and configurable country/currency/code sets" },
      { name = "pain001-customer-intake"; status = "implemented"; notes = "typed customer credit-transfer initiation validation" },
      { name = "pain001-to-pacs008-transform"; status = "implemented"; notes = "deterministic mapping into FI-to-FI credit transfer with BAH and UETR" },
      { name = "cross-border-pacs009-cover"; status = "implemented"; notes = "pacs.009 core/COV model, validators, XML export, and cover linkage checks" },
      { name = "exceptions-investigations"; status = "implemented"; notes = "camt.056 cancellation, camt.029 resolution, pacs.028 status-request, and camt.110/camt.111 case-management model and XML export" },
      { name = "compliance-screening-hooks"; status = "implemented-playground"; notes = "deterministic AML/CFT/payment-transparency screening profile with blocked/high-risk country, BIC, name fragment, value, route, FX, and regulatory-reporting findings; C5 replay held a configured sanctioned payee on ICP Playground" },
      { name = "pain002-pacs002-status-reports"; status = "implemented"; notes = "customer and bank status reports with phase validation" },
      { name = "direct-debit-forms"; status = "implemented-compact"; notes = "compact pain.008 and pacs.003 XML decode/validate/export with mandate id, sequence type, connector routing, and SEPA SDD education fixtures" },
      { name = "camt-style-reporting"; status = "implemented"; notes = "statement and notification views over hub payments" },
      { name = "request-to-pay-forms"; status = "implemented-compact"; notes = "compact pain.013, pain.014, and camt.055 XML decode/validate/export with connector routing and public-source fixtures" },
      { name = "administrative-admi-forms"; status = "implemented-compact"; notes = "compact admi.002, admi.004, admi.007, and admi.011 XML decode/validate/export with connector routing and fixtures" },
      { name = "duplicate-bloom-filter"; status = "implemented"; notes = "advisory UETR/messageId Bloom filter with exact Map fallback" },
      { name = "hash-chained-audit"; status = "implemented"; notes = "every audit record commits to the previous audit hash" },
      { name = "audit-merkle-root-and-proof"; status = "implemented"; notes = "queryable inclusion proof over audit record hashes" },
      { name = "audit-mmr-root"; status = "implemented"; notes = "compact Merkle Mountain Range checkpoint root over append-only audit hashes" },
      { name = "certified-disclosure-root"; status = "implemented-playground"; notes = "IC certified_data commits to the current audit/MMR snapshot and refreshed ICRC-ME participant balance snapshots, with certificate-bearing query envelopes; C6 replay passed on ICP Playground" },
      { name = "participant-directory-workflows"; status = "implemented"; notes = "BIC/LEI participant directory plus auditable correlation state for direct-debit mandate/collection/reject threads, request-to-pay request/response threads, administrative ACK/NACKs, and case-management messages" },
      { name = "pfmi-self-assessment"; status = "implemented"; notes = "PFMI principle matrix is exposed on-chain with code-enforceable verifier coverage where the hub can check the invariant and explicit institutional/external residual gates where it cannot" },
      { name = "schema-aware-xml-codec"; status = "implemented-partial"; notes = "strict compact XML subset codec: inbound/outbound pain.001, pain.008, pacs.003, pacs.008, pacs.009, cover, status, investigation/case-management, request-to-pay, administrative, and camt reporting; full ISO XSD/profile conformance remains an external oracle gate" },
      { name = "connector-outbound-delivery"; status = "implemented"; notes = "on-chain outbound XML batch queue with connector leasing, delivery ACK/NACK receipts, payload-hash verification, retry state, and dead-letter issues" },
      { name = "legacy-file-parsers"; status = "implemented-partial"; notes = "native MT103 payment, MT940/MT942 statement, CSV payment, and fixed-width payment parsers for integration fixtures; full SWIFT option coverage and bank-specific CSV/fixed layouts remain profile gates" },
      { name = "connector-thebes-caller-auth"; status = "implemented"; notes = "connector policy can require the Thebes-authenticated ingress caller to equal the registered connector owner" },
      { name = "connector-memphis-session-auth"; status = "implemented"; notes = "connector policy can require a live Memphis session token and compare the derived app principal with the registered connector owner" },
      { name = "connector-external-signature-attestation"; status = "implemented-playground"; notes = "connector policy can require a detached signature and call a verifier canister for Ed25519, MAYO-2, threshold-Schnorr, or institution-specific schemes against the canister canonical envelope hash; C5 replay verified the reference verifier and rejected a tampered envelope on ICP Playground" },
      { name = "integration-profile-packs"; status = "implemented"; notes = "discoverable local, CBPR-shaped, legacy, SEPA, Fedwire, FedNow, and BIS CPMI public-source profile metadata with matching integration-kit fixtures where implemented" },
      { name = "runtime-guideline-profiles"; status = "implemented-playground"; notes = "built-in and custom UsageGuideline profiles can be selected as the default, per connector, or per validation/submission call without redeploying the canister; C3 replay passed on ICP Playground" },
      { name = "settlement-liquidity-queue"; status = "implemented-local"; notes = "participant debit caps, reserved queued liquidity, FIFO/bypass queue ordering, gross dispatch rejection, and two-payment offset settlement path over ICRC-ME net transfer" },
      { name = "operating-day-state-machine"; status = "implemented-playground"; notes = "per-currency operating-day config, settlement-window cutoff enforcement, opening balance snapshots, end-of-day camt.053 generation, and ICRC-ME balance reconciliation; C4 replay passed on ICP Playground" },
      { name = "public-scheme-research"; status = "implemented"; notes = "docs/PUBLIC_SCHEME_RESEARCH.md records public scheme/form gaps and distinguishes implemented compact forms from official conformance gates" },
      { name = "phase-oracle-readiness"; status = "implemented"; notes = "machine-readable oracle phase registry plus live readiness verifiers for guideline, XML, lifecycle, cross-border, compliance, connectors, outbound, MT103, audit, and duplicate indexes" },
      { name = "checkpoint-map"; status = "implemented"; notes = "machine-readable architecture checkpoint map plus XML profile fixture registry for audit/review discipline" },
      { name = "ordered-secondary-indexes"; status = "implemented-partial"; notes = "deterministic range/prefix indexes for payment status, creditor-agent, account statement, and outbound connector/status queries" },
      { name = "stable-index-checkpoints"; status = "implemented-partial"; notes = "Region-backed stable-memory checkpoints with SHA-256 commit hashes and live verifier checks for the ordered secondary indexes, including the settlement queue; mutable Region BTree storage remains the next scale gate" },
    ];
  };

  public query func checkpointMap() : async [CheckpointMapEntry] {
    [
      {
        id = "xml.inbound.full-compact";
        layer = "codec";
        status = "implemented-partial";
        codeSurface = ["ISO20022Xml.decodePain001", "decodeDirectDebit", "decodePacs008", "decodePacs009", "decodeCoverPayment", "decodeStatusReport", "decodeInvestigation", "decodeRequestToPay", "decodeAdministrative", "decodeCamt053", "decodeCamt054"];
        verifierSurface = ["verifyXmlCodecOracleReport", "XmlCodec.test.mo", "xmlProfileFixtureRegistry"];
        currentGate = "strict compact XML subset roundtrips and safe-parser rejection checks";
        nextGate = "external XSD/profile differential fixture runner";
      },
      {
        id = "connector.status-application";
        layer = "connector";
        status = "implemented";
        codeSurface = ["submitTransportEnvelope", "applyInboundStatusReport", "paymentByMessageId", "paymentByUetr"];
        verifierSurface = ["verifyConnectorOracleReport", "verifyPaymentPhases", "listDeadLetters"];
        currentGate = "pacs.002/pacs.004 match by originalMessageId and UETR, reject duplicates, enforce lifecycle";
        nextGate = "actor integration test against deployed canister and replayed bank status files";
      },
      {
        id = "stable.index.checkpoints";
        layer = "storage";
        status = "implemented-partial";
        codeSurface = ["OrderedIndex", "StableOrderedIndex", "secondaryIndexHealth", "checkpointSecondaryIndexes"];
        verifierSurface = ["verifyDuplicateOracleReport", "secondaryIndexHealth", "OrderedIndex.test.mo"];
        currentGate = "Region checkpoint hash/invariant verifier over ordered secondary indexes";
        nextGate = "mutable Region BTree node store with deployed canister smoke tests";
      },
      {
        id = "settlement.liquidity.queue";
        layer = "settlement";
        status = "implemented-local";
        codeSurface = ["setSettlementDebitLimit", "dispatchOrQueuePacs008", "queueSettlementPayment", "settleQueuedPacs008", "resolveQueuedSettlementOffset", "settlementLiquidityPosition", "listSettlementQueue"];
        verifierSurface = ["secondaryIndexHealth", "checkSettlementLiquidity", "listSettlementQueue", "verifyPaymentPhases"];
        currentGate = "local DFX queue smoke: over-limit gross dispatch queues, reserves debit liquidity, and checkpoint-verifies the settlement queue index";
        nextGate = "deployed C2 replay with two opposite queued payments resolved through ICRC-ME net settlement";
      },
      {
        id = "settlement.operating-day";
        layer = "settlement";
        status = "implemented-playground";
        codeSurface = ["configureOperatingDay", "openOperatingDay", "setOperatingDayPhase", "operatingDayStatus", "runEndOfDay", "listEndOfDayRuns"];
        verifierSurface = ["operatingDayStatus", "getEndOfDayRun", "camt053Xml", "secondaryIndexHealth"];
        currentGate = "ICP Playground C4 replay on hub xpjyl-daaaa-aaaab-qadcq-cai and ledger 2uurk-ziaaa-aaaab-qacla-cai: cutoff blocked dispatch, settlement finalized at ICRC-ME block 3, and end-of-day reconciliation matched ledger balances";
        nextGate = "long-lived canonical replay if short-lived Playground evidence is not accepted";
      },
      {
        id = "profile.runtime-selection";
        layer = "profile";
        status = "implemented-playground";
        codeSurface = ["listGuidelineProfiles", "setDefaultGuidelineProfile", "putGuidelineProfile", "setConnectorGuidelineProfile", "validatePain001WithProfile", "validatePain001XmlWithProfile", "submitPain001WithProfile", "submitTransportEnvelope"];
        verifierSurface = ["validateDemoPain001WithProfile", "validateDemoCrossBorderPain001WithProfile", "verifyOracleReadiness", "listConnectorGuidelineProfiles"];
        currentGate = "ICP Playground C3 replay on xpjyl-daaaa-aaaab-qadcq-cai: EG domestic accepts domestic pain.001, EG rejects cross-market pain.001, CBPR+/SEPA/Fedwire profiles accept it, and a connector binds to SEPA without changing the default";
        nextGate = "long-lived canonical replay with connector-bound SEPA/CBPR+/Fedwire fixtures if short-lived Playground evidence is not accepted";
      },
      {
        id = "compliance.signing-gate";
        layer = "compliance";
        status = "implemented-playground";
        codeSurface = ["setComplianceProfile", "submitPain001Xml", "getPaymentComplianceReport", "listHeldPaymentViews", "releaseComplianceHold", "rejectComplianceHold", "useExternalSignatureAuth", "connectorEnvelopeSigningHash", "submitTransportEnvelope", "ReferenceSignatureVerifier.verify_connector_signature"];
        verifierSurface = ["getPaymentComplianceReport", "listHeldPaymentViews", "listTransportRecords", "verifyOracleReadiness"];
        currentGate = "ICP Playground C5 replay on hub xpjyl-daaaa-aaaab-qadcq-cai and verifier 4ey3y-zaaaa-aaaab-qac6q-cai: payment 1 held with SANCTIONS-NAME-FRAGMENT, transport 0 accepted with a reference-sha256 detached signature, and transport 1 dead-lettered with TRANSPORT-REFERENCE-SIGNATURE-MISMATCH";
        nextGate = "licensed sanctions/PEP feed, scheme/bank PKI or HSM verifier, and long-lived canonical replay if short-lived Playground evidence is not accepted";
      },
      {
        id = "audit.evidence";
        layer = "evidence";
        status = "implemented";
        codeSurface = ["auditTip", "auditProof", "verifyAuditChain", "AuditMMR"];
        verifierSurface = ["verifyAuditOracleReport", "BloomMmr.test.mo"];
        currentGate = "hash chain, Merkle inclusion proof, MMR checkpoint root";
        nextGate = "stable audit leaves and exportable audit bundles";
      },
      {
        id = "certified.disclosure";
        layer = "evidence";
        status = "implemented-playground";
        codeSurface = ["refreshCertifiedDisclosure", "refreshCertifiedSettlementBalances", "refreshCertifiedParticipantBalance", "certifiedDisclosureCertificate", "certifiedAuditDisclosure", "certifiedParticipantBalance", "listCertifiedParticipantBalances"];
        verifierSurface = ["verifyCertifiedDisclosure", "verifyOracleReadiness"];
        currentGate = "ICP Playground C6 replay on hub xpjyl-daaaa-aaaab-qadcq-cai and ledger mytki-xqaaa-aaaab-qabrq-cai: certified root commits to audit/MMR snapshot and two refreshed EGP balance snapshots, certificate-bearing query returned non-null certificate, verifyCertifiedDisclosure ok=true";
        nextGate = "external certificate verification client against the IC root key and ledger-native certified balance witnesses";
      },
      {
        id = "participant.workflow";
        layer = "workflow";
        status = "implemented";
        codeSurface = ["upsertParticipantDirectoryEntry", "seedDemoParticipantDirectory", "correlateDirectDebitWorkflow", "correlateRequestToPayWorkflow", "correlateInvestigationWorkflow", "correlateAdministrativeWorkflow", "getWorkflowByMessageId", "getWorkflowByUetr", "listWorkflowStates"];
        verifierSurface = ["verifyParticipantWorkflowCorrelation", "verifyOracleReadiness"];
        currentGate = "BIC/LEI directory validation plus workflow states that correlate the demo mandate -> pacs.003 collection -> admi.002 reject and pain.013 request -> pain.014 response threads into single auditable states";
        nextGate = "scheme-specific directory import, mandate expiry/revocation rules, rail ACK/NACK SLA timers, and deployed connector replay";
      },
      {
        id = "pfmi.self.assessment";
        layer = "governance";
        status = "implemented";
        codeSurface = ["pfmiSelfAssessment", "verifyPfmiSelfAssessment"];
        verifierSurface = ["verifyPfmiSelfAssessment", "verifyOracleReadiness"];
        currentGate = "All 24 PFMI principles are classified as native, built, hybrid, institutional, external, or not-applicable; code-enforceable rows name a live verifier";
        nextGate = "operator-signed rulebook, governance evidence pack, legal finality memorandum, and external disclosure framework publication";
      },
      {
        id = "profile.oracle";
        layer = "oracle";
        status = "implemented-partial";
        codeSurface = ["oraclePhaseRegistry", "verifyOraclePhases", "verifyOracleReadiness"];
        verifierSurface = ["PhaseOracle.test.mo", "docs/XML_CODEC_ORACLE.md", "docs/CHECKPOINT_MAP.md"];
        currentGate = "static profile/fixture manifest plus live in-canister verifier rules";
        nextGate = "Prowide/ISO XSD differential runner outside canister with signed fixture bundle hashes";
      },
    ];
  };

  public query func integrationProfilePacks() : async [IntegrationProfilePack] {
    [
      {
        id = "EG-DOMESTIC-EDU";
        displayName = "Egypt domestic credit transfer education profile";
        status = "implemented-compact";
        guidelineSurface = "listGuidelineProfiles / setDefaultGuidelineProfile / resetGuidelineToEgyptEducationBaseline";
        messageFamilies = ["pain.001", "pain.002", "pacs.008", "pacs.002", "pacs.004", "camt.053", "camt.054"];
        connectorFormats = ["pain.001.xml", "pacs.008.xml", "pain.002.xml", "pacs.002.xml", "pacs.004.xml", "camt.053.xml", "camt.054.xml", "payment.bundle.xml"];
        legacyInputs = [];
        fixturePath = "integration-kit/profiles/EG-DOMESTIC-EDU.json";
        notes = "Education profile for Egyptian IBAN/BIC/currency rules; not an official bank or scheme rulebook.";
      },
      {
        id = "CBPRPLUS-EDU";
        displayName = "Cross-border and cover-payment education profile";
        status = "implemented-compact";
        guidelineSurface = "listGuidelineProfiles / setDefaultGuidelineProfile / setConnectorGuidelineProfile / resetGuidelineToCrossBorderEducationBaseline";
        messageFamilies = ["head.001", "pacs.008", "pacs.009", "pacs.002", "pacs.004", "camt.056", "camt.029", "pacs.028", "camt.110", "camt.111"];
        connectorFormats = ["pacs.008.xml", "pacs.009.xml", "cover.payment.xml", "pacs.002.xml", "pacs.004.xml", "camt.056.xml", "camt.029.xml", "pacs.028.xml", "camt.110.xml", "camt.111.xml"];
        legacyInputs = [];
        fixturePath = "integration-kit/profiles/CBPRPLUS-EDU.json";
        notes = "CBPR+-shaped education fixtures and validators; official CBPR+ conformance remains an external oracle gate.";
      },
      {
        id = "LEGACY-MT103-BRIDGE";
        displayName = "Legacy MT103 file bridge profile";
        status = "implemented-partial";
        guidelineSurface = "decodeMt103 / submitTransportEnvelope(format = \"mt103\")";
        messageFamilies = ["MT103", "pain.001", "pain.002", "pacs.008", "camt.054"];
        connectorFormats = ["mt103", "mt940", "mt942", "csv.payments", "fixed.payments", "pain.002.xml", "pacs.002.xml", "payment.bundle.xml"];
        legacyInputs = ["MT103 block 4", "MT940 statement file", "MT942 intraday file", "CSV payment file", "fixed-width payment file", "bank file manifest", "SFTP/file-drop adapter pattern"];
        fixturePath = "integration-kit/profiles/LEGACY-MT103-BRIDGE.json";
        notes = "Maps supported MT103, CSV, and fixed-width payment files into pain.001 intake and decodes MT940/MT942 statement feeds into statement entries.";
      },
      {
        id = "SEPA-SCT-EDU";
        displayName = "SEPA Credit Transfer public-source education overlay";
        status = "implemented-runtime-overlay";
        guidelineSurface = "listGuidelineProfiles / setDefaultGuidelineProfile / setConnectorGuidelineProfile / validatePain001WithProfile";
        messageFamilies = ["pain.001", "pain.002", "pacs.008", "pacs.002", "pacs.004", "camt.056", "camt.029", "pacs.028", "camt.053", "camt.054"];
        connectorFormats = ["pain.001.xml", "pain.002.xml", "pacs.008.xml", "pacs.002.xml", "pacs.004.xml", "camt.056.xml", "camt.029.xml", "pacs.028.xml", "camt.053.xml", "camt.054.xml"];
        legacyInputs = [];
        fixturePath = "integration-kit/profiles/SEPA-SCT-EDU.json";
        notes = "Tracks public EPC SCT guidelines as a named overlay; official EPC conformance remains an external oracle gate.";
      },
      {
        id = "SEPA-SCT-INST-EDU";
        displayName = "SEPA Instant Credit Transfer public-source education overlay";
        status = "implemented-runtime-overlay";
        guidelineSurface = "listGuidelineProfiles / setDefaultGuidelineProfile / setConnectorGuidelineProfile / validatePacs008WithProfile";
        messageFamilies = ["pacs.008", "pacs.002", "pacs.004", "camt.056", "camt.029", "pacs.028", "camt.053", "camt.054"];
        connectorFormats = ["pacs.008.xml", "pacs.002.xml", "pacs.004.xml", "camt.056.xml", "camt.029.xml", "pacs.028.xml", "camt.053.xml", "camt.054.xml"];
        legacyInputs = [];
        fixturePath = "integration-kit/profiles/SEPA-SCT-INST-EDU.json";
        notes = "Tracks public EPC SCT Inst guidelines as a named overlay; instant SLA and scheme profile rules stay in the external runner.";
      },
      {
        id = "SEPA-SDD-EDU";
        displayName = "SEPA Direct Debit public-source education overlay";
        status = "implemented-runtime-overlay";
        guidelineSurface = "listGuidelineProfiles / setDefaultGuidelineProfile / setConnectorGuidelineProfile / validateDirectDebitWithProfile";
        messageFamilies = ["pain.008", "pacs.003", "pain.002", "pacs.002", "pacs.004", "camt.056", "camt.029", "camt.053", "camt.054"];
        connectorFormats = ["pain.008.xml", "pacs.003.xml", "pain.002.xml", "pacs.002.xml", "pacs.004.xml", "camt.053.xml", "camt.054.xml"];
        legacyInputs = [];
        fixturePath = "integration-kit/profiles/SEPA-SDD-EDU.json";
        notes = "Public EPC SDD profile tracked; compact pain.008 and pacs.003 mandate/collection forms are implemented, while official scheme and mandate lifecycle rules remain external.";
      },
      {
        id = "FEDWIRE-ISO20022-EDU";
        displayName = "Fedwire ISO 20022 public-source education overlay";
        status = "implemented-runtime-overlay";
        guidelineSurface = "listGuidelineProfiles / setDefaultGuidelineProfile / setConnectorGuidelineProfile / validateRequestToPayWithProfile";
        messageFamilies = ["pacs.008", "pacs.009", "pacs.002", "pacs.004", "pacs.028", "pain.013", "pain.014", "camt.056", "camt.029", "camt.055", "camt.110", "camt.111", "admi.002", "admi.004", "admi.007", "admi.011"];
        connectorFormats = ["pacs.008.xml", "pacs.009.xml", "pacs.002.xml", "pacs.004.xml", "pacs.028.xml", "pain.013.xml", "pain.014.xml", "camt.056.xml", "camt.029.xml", "camt.055.xml", "camt.110.xml", "camt.111.xml", "admi.002.xml", "admi.004.xml", "admi.007.xml", "admi.011.xml"];
        legacyInputs = [];
        fixturePath = "integration-kit/profiles/FEDWIRE-ISO20022-EDU.json";
        notes = "Public Fedwire drawdown/RFP, case-management, and administrative references tracked; pain.013, pain.014, camt.055, camt.110, camt.111, and compact admi forms are implemented.";
      },
      {
        id = "FEDNOW-ISO20022-EDU";
        displayName = "FedNow ISO 20022 public-source education overlay";
        status = "implemented-runtime-overlay";
        guidelineSurface = "listGuidelineProfiles / setDefaultGuidelineProfile / setConnectorGuidelineProfile / validateRequestToPayWithProfile";
        messageFamilies = ["pacs.008", "pacs.009", "pacs.002", "pacs.004", "pacs.028", "pain.013", "pain.014", "camt.056", "camt.029", "camt.055", "camt.054"];
        connectorFormats = ["pacs.008.xml", "pacs.009.xml", "pacs.002.xml", "pacs.004.xml", "pacs.028.xml", "pain.013.xml", "pain.014.xml", "camt.056.xml", "camt.029.xml", "camt.055.xml", "camt.054.xml"];
        legacyInputs = [];
        fixturePath = "integration-kit/profiles/FEDNOW-ISO20022-EDU.json";
        notes = "Public FedNow RFP references tracked; compact RFP, payment, return, status, and reporting examples are available, but FedNow service rules remain external.";
      },
      {
        id = "BIS-CPMI-HARMONIZED-CROSSBORDER";
        displayName = "BIS CPMI cross-border harmonisation research overlay";
        status = "research-runtime-overlay";
        guidelineSurface = "listGuidelineProfiles / setConnectorGuidelineProfile / docs/PUBLIC_SCHEME_RESEARCH.md";
        messageFamilies = ["pain.001", "pacs.008", "pacs.009", "pain.013", "pain.014", "camt.055", "camt.029", "camt.056", "pacs.028", "camt.054", "camt.110", "camt.111"];
        connectorFormats = ["pain.001.xml", "pacs.008.xml", "pacs.009.xml", "pain.013.xml", "pain.014.xml", "camt.055.xml", "camt.029.xml", "camt.056.xml", "pacs.028.xml", "camt.054.xml", "camt.110.xml", "camt.111.xml"];
        legacyInputs = [];
        fixturePath = "integration-kit/profiles/BIS-CPMI-HARMONIZED-CROSSBORDER.json";
        notes = "Records public CPMI harmonisation targets; compact camt.110 and camt.111 case-management forms are implemented.";
      },
    ];
  };

  public query func xmlProfileFixtureRegistry() : async [XmlProfileFixture] {
    [
      {
        id = "valid/pain001-eg-domestic.xml";
        profile = "EGYPT-ISO20022-HUB-EDU";
        messageKind = "pain.001";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "ISO 20022 pain.001.001.09 plus local usage guideline";
        expectedRuleIds = [];
        notes = "customer credit transfer initiation accepted by compact hub subset";
      },
      {
        id = "valid/pacs008-eg-domestic.xml";
        profile = "EGYPT-ISO20022-HUB-EDU";
        messageKind = "pacs.008";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "ISO 20022 pacs.008.001.08 plus BAH/UETR guideline";
        expectedRuleIds = [];
        notes = "FI-to-FI audit intake with BAH and one transaction";
      },
      {
        id = "valid/direct-debit-pain008-sdd.xml";
        profile = "SEPA-SDD-EDU";
        messageKind = "pain.008";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "public EPC SDD profile plus compact hub subset";
        expectedRuleIds = [];
        notes = "customer direct debit initiation with mandate id, signature date, and RCUR sequence type";
      },
      {
        id = "valid/direct-debit-pacs003-sdd.xml";
        profile = "SEPA-SDD-EDU";
        messageKind = "pacs.003";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "public EPC SDD profile plus compact hub subset";
        expectedRuleIds = [];
        notes = "FI-to-FI direct debit with BAH, UETR, settlement instruction, and mandate reference";
      },
      {
        id = "valid/pacs009-cbprplus-core.xml";
        profile = "CBPRPLUS-EDU";
        messageKind = "pacs.009";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "CBPR+ pattern and ISO pacs.009.001.08";
        expectedRuleIds = [];
        notes = "cross-border FI transfer with routing, charges, FX, and regulatory reporting";
      },
      {
        id = "valid/cover-payment.xml";
        profile = "CBPRPLUS-EDU";
        messageKind = "pacs.008+pacs.009.COV";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "cover payment direct/cover linkage rule";
        expectedRuleIds = [];
        notes = "cover bundle links direct pacs.008 to pacs.009 COV by original message id and UETR";
      },
      {
        id = "valid/investigation-camt110-request.xml";
        profile = "BIS-CPMI-HARMONIZED-CROSSBORDER";
        messageKind = "camt.110";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "public CPMI/Fedwire case-management references plus compact hub subset";
        expectedRuleIds = [];
        notes = "compact case-management investigation request linked to original payment id and UETR";
      },
      {
        id = "valid/investigation-camt111-response.xml";
        profile = "BIS-CPMI-HARMONIZED-CROSSBORDER";
        messageKind = "camt.111";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "public CPMI/Fedwire case-management references plus compact hub subset";
        expectedRuleIds = [];
        notes = "compact case-management investigation response linked to camt.110 assignment";
      },
      {
        id = "valid/request-pain013-rfp.xml";
        profile = "FEDWIRE-ISO20022-EDU";
        messageKind = "pain.013";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "public Fedwire/FedNow/BIS request-to-pay references plus compact hub subset";
        expectedRuleIds = [];
        notes = "request-for-payment/drawdown request fixture accepted by compact hub subset";
      },
      {
        id = "valid/request-pain014-accepted.xml";
        profile = "FEDWIRE-ISO20022-EDU";
        messageKind = "pain.014";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "public Fedwire/FedNow/BIS request-to-pay references plus compact hub subset";
        expectedRuleIds = [];
        notes = "request-for-payment response fixture with ACTC status";
      },
      {
        id = "valid/request-camt055-cancel.xml";
        profile = "FEDWIRE-ISO20022-EDU";
        messageKind = "camt.055";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "public Fedwire/FedNow/BIS request-to-pay cancellation references plus compact hub subset";
        expectedRuleIds = [];
        notes = "request-for-payment cancellation fixture with CANC status and original request id";
      },
      {
        id = "valid/admin-admi002-reject.xml";
        profile = "FEDWIRE-ISO20022-EDU";
        messageKind = "admi.002";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "public administrative reject pattern plus compact hub subset";
        expectedRuleIds = [];
        notes = "compact administrative reject with related message id and UETR";
      },
      {
        id = "valid/admin-admi004-connection-check.xml";
        profile = "FEDWIRE-ISO20022-EDU";
        messageKind = "admi.004";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "public administrative connection-check pattern plus compact hub subset";
        expectedRuleIds = [];
        notes = "compact connection-check event notification";
      },
      {
        id = "valid/admin-admi007-ack.xml";
        profile = "FEDWIRE-ISO20022-EDU";
        messageKind = "admi.007";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "public administrative acknowledgement pattern plus compact hub subset";
        expectedRuleIds = [];
        notes = "compact receipt acknowledgement with related message id";
      },
      {
        id = "valid/admin-admi011-connection-ack.xml";
        profile = "FEDWIRE-ISO20022-EDU";
        messageKind = "admi.011";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "public administrative connection-check acknowledgement pattern plus compact hub subset";
        expectedRuleIds = [];
        notes = "compact connection-check acknowledgement with related message id";
      },
      {
        id = "valid/status-pacs002-settled.xml";
        profile = "EGYPT-ISO20022-HUB-EDU";
        messageKind = "pacs.002";
        direction = "inbound";
        validity = "valid";
        sourceOracle = "ISO status report plus hub lifecycle rule";
        expectedRuleIds = [];
        notes = "applies settlement state after originalMessageId and UETR correlation";
      },
      {
        id = "invalid/xml-doctype-entity.xml";
        profile = "SECURITY";
        messageKind = "any";
        direction = "inbound";
        validity = "invalid";
        sourceOracle = "safe XML parser control";
        expectedRuleIds = ["XML-UNSAFE-DECL"];
        notes = "DTD/entity/external identifier payload must be rejected before mapping";
      },
      {
        id = "invalid/status-uetr-mismatch.xml";
        profile = "EGYPT-ISO20022-HUB-EDU";
        messageKind = "pacs.002";
        direction = "inbound";
        validity = "invalid";
        sourceOracle = "hub lifecycle correlation rule";
        expectedRuleIds = ["STATUS-UETR-MISMATCH"];
        notes = "status report cannot mutate a payment when original UETR does not match stored state";
      },
      {
        id = "invalid/cover-underlying-mismatch.xml";
        profile = "CBPRPLUS-EDU";
        messageKind = "pacs.008+pacs.009.COV";
        direction = "inbound";
        validity = "invalid";
        sourceOracle = "cover payment linkage rule";
        expectedRuleIds = ["COVER-UNDERLYING-MATCH"];
        notes = "cover pacs.009 must reference the direct pacs.008 message id";
      },
    ];
  };

  // -- Audit --------------------------------------------------------------
  public shared (msg) func auditPacs008(doc : Pacs008CreditTransfer, rawXml : ?Blob) : async AuditRecord {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    let report = ISO.validatePacs008(guideline, doc, rawXml);
    auditPacs008Core(msg.caller, doc, rawXml, report);
  };

  public shared (msg) func auditPacs008Xml(xml : Blob) : async AuditXmlResult {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    switch (Xml.decodePacs008(xml)) {
      case (#ok(doc)) {
        let report = ISO.validatePacs008(guideline, doc, ?xml);
        #ok(auditPacs008Core(msg.caller, doc, ?xml, report));
      };
      case (#err(issues)) #err(ISO.reportFromIssues(guideline, "pacs.008.xml", Xml.codecVersion, issues));
    };
  };

  public shared (msg) func auditDemoPacs008() : async AuditRecord {
    Admin.requireNotPaused(admin);
    if (Principal.isAnonymous(msg.caller)) Runtime.trap("anonymous caller");
    let doc = ISO.demoPacs008();
    let report = ISO.validatePacs008(guideline, doc, null);
    auditPacs008Core(msg.caller, doc, null, report);
  };

  public query func getAudit(id : Nat) : async ?AuditRecord {
    Map.get(audits, Nat.compare, id);
  };

  public query func auditCount() : async Nat {
    Map.size(audits);
  };

  public query func auditTip() : async AuditTip {
    auditTipCore();
  };

  public shared (msg) func refreshCertifiedDisclosure() : async CertifiedDisclosureRoot {
    Admin.requireAdmin(admin, msg.caller);
    commitCertifiedDisclosure(Time.now());
  };

  public shared (msg) func refreshCertifiedParticipantBalance(bicfi : Text) : async CertifiedParticipantBalance {
    Admin.requireAdmin(admin, msg.caller);
    let account = switch (Map.get(settlementParticipantAccounts, Text.compare, bicfi)) {
      case (?a) a;
      case null Runtime.trap("settlement participant account not configured for " # bicfi);
    };
    let ledgerPrincipal = requireSettlementLedgerCanister();
    let ledger : IcrcLedger = actor (Principal.toText(ledgerPrincipal));
    let balance = await ledger.icrc1_balance_of(account);
    let snapshot = makeCertifiedParticipantBalance(
      bicfi,
      account,
      ?ledgerPrincipal,
      settlementCurrency,
      balance,
      Time.now(),
    );
    Map.add(certifiedParticipantBalances, Text.compare, bicfi, snapshot);
    ignore commitCertifiedDisclosure(snapshot.capturedAt);
    snapshot;
  };

  public shared (msg) func refreshCertifiedSettlementBalances() : async [CertifiedParticipantBalance] {
    Admin.requireAdmin(admin, msg.caller);
    let ledgerPrincipal = requireSettlementLedgerCanister();
    let ledger : IcrcLedger = actor (Principal.toText(ledgerPrincipal));
    let capturedAt = Time.now();
    for ((bicfi, account) in Map.entries(settlementParticipantAccounts)) {
      let balance = await ledger.icrc1_balance_of(account);
      let snapshot = makeCertifiedParticipantBalance(
        bicfi,
        account,
        ?ledgerPrincipal,
        settlementCurrency,
        balance,
        capturedAt,
      );
      Map.add(certifiedParticipantBalances, Text.compare, bicfi, snapshot);
    };
    ignore commitCertifiedDisclosure(capturedAt);
    certifiedBalancesOrdered();
  };

  public query func certifiedDisclosureCertificate() : async CertifiedDisclosureCertificate {
    {
      certificate = CertifiedData.getCertificate();
      root = certifiedDisclosureRootState;
    };
  };

  public query func certifiedAuditDisclosure() : async CertifiedAuditDisclosure {
    {
      certificate = CertifiedData.getCertificate();
      root = certifiedDisclosureRootState;
      audit = certifiedAuditSnapshot;
    };
  };

  public query func certifiedParticipantBalance(bicfi : Text) : async ?CertifiedBalanceDisclosure {
    switch (Map.get(certifiedParticipantBalances, Text.compare, bicfi)) {
      case (?balance) ?{
        certificate = CertifiedData.getCertificate();
        root = certifiedDisclosureRootState;
        balance;
      };
      case null null;
    };
  };

  public query func listCertifiedParticipantBalances(offset : Nat, limit : Nat) : async Pagination.Page<CertifiedParticipantBalance> {
    Pagination.page<CertifiedParticipantBalance>(certifiedBalancesOrdered(), offset, limit);
  };

  public query func verifyCertifiedDisclosure() : async ValidationReport {
    verifyCertifiedDisclosureReport();
  };

  // ── Certified-disclosure JSON projections ────────────────────────────────
  // These query methods mirror the typed certified-disclosure methods above but
  // return a JSON *string* in the exact shape the external verifier consumes:
  //   * Blob              -> array of byte values, e.g. [1, 255, 0]
  //   * ?Blob             -> [] | [[b0, b1, ...]]
  //   * Nat / Int         -> decimal string (survives values beyond 2^53 that a
  //                          JSON number would silently round)
  //   * ?Nat              -> [] | ["123"]
  //   * Text / Principal  -> escaped JSON string
  //   * ?Text / ?Principal-> [] | ["..."]
  // The dependency-free certified-disclosure-verify.py reads these over
  // `thebes-deploy query` and recomputes the commitment with no Candid decoder
  // and no external client library.

  func jHexDigit(n : Nat32) : Char {
    let d = n % 16;
    if (d < 10) Char.fromNat32(48 + d) else Char.fromNat32(87 + d); // '0'..'9' | 'a'..'f'
  };

  func jHex4(code : Nat32) : Text {
    Char.toText(jHexDigit(code / 4096)) # Char.toText(jHexDigit(code / 256)) # Char.toText(jHexDigit(code / 16)) # Char.toText(jHexDigit(code));
  };

  func jText(t : Text) : Text {
    var out = "\"";
    for (c in t.chars()) {
      let code = Char.toNat32(c);
      if (c == '\"') { out #= "\\\"" } else if (c == '\\') { out #= "\\\\" } else if (c == '\n') {
        out #= "\\n";
      } else if (c == '\r') { out #= "\\r" } else if (c == '\t') { out #= "\\t" } else if (code < 0x20) {
        out #= "\\u" # jHex4(code);
      } else { out #= Char.toText(c) };
    };
    out # "\"";
  };

  func jNat(n : Nat) : Text { "\"" # Nat.toText(n) # "\"" };
  func jInt(i : Int) : Text { "\"" # Int.toText(i) # "\"" };
  func jBool(b : Bool) : Text { if (b) "true" else "false" };

  func jBlob(b : Blob) : Text {
    var out = "[";
    var first = true;
    for (byte in Blob.toArray(b).vals()) {
      if (first) { first := false } else { out #= "," };
      out #= Nat.toText(Nat8.toNat(byte));
    };
    out # "]";
  };

  func jOptBlob(o : ?Blob) : Text {
    switch (o) { case null "[]"; case (?b) "[" # jBlob(b) # "]" };
  };

  func jOptNat(o : ?Nat) : Text {
    switch (o) { case null "[]"; case (?n) "[" # jNat(n) # "]" };
  };

  func jOptText(o : ?Text) : Text {
    switch (o) { case null "[]"; case (?t) "[" # jText(t) # "]" };
  };

  func jOptPrincipal(o : ?Principal) : Text {
    switch (o) { case null "[]"; case (?p) "[" # jText(Principal.toText(p)) # "]" };
  };

  func jAccount(a : IcrcAccount) : Text {
    "{\"owner\":" # jText(Principal.toText(a.owner)) # ",\"subaccount\":" # jOptBlob(a.subaccount) # "}";
  };

  func jRoot(r : CertifiedDisclosureRoot) : Text {
    "{\"version\":" # jText(r.version) # ",\"updatedAt\":" # jInt(r.updatedAt) # ",\"auditSnapshotHash\":" # jBlob(r.auditSnapshotHash) # ",\"balanceRoot\":" # jBlob(r.balanceRoot) # ",\"balanceCount\":" # jNat(r.balanceCount) # ",\"rootHash\":" # jBlob(r.rootHash) # "}";
  };

  func jAudit(s : CertifiedAuditSnapshot) : Text {
    "{\"capturedAt\":" # jInt(s.capturedAt) # ",\"count\":" # jNat(s.count) # ",\"lastAuditId\":" # jOptNat(s.lastAuditId) # ",\"lastAuditHash\":" # jOptBlob(s.lastAuditHash) # ",\"merkleRoot\":" # jOptBlob(s.merkleRoot) # ",\"mmrRoot\":" # jOptBlob(s.mmrRoot) # ",\"mmrLeafCount\":" # jNat(s.mmrLeafCount) # ",\"mmrPeakCount\":" # jNat(s.mmrPeakCount) # ",\"guidelineId\":" # jText(s.guidelineId) # ",\"snapshotHash\":" # jBlob(s.snapshotHash) # "}";
  };

  func jBalance(b : CertifiedParticipantBalance) : Text {
    "{\"bicfi\":" # jText(b.bicfi) # ",\"account\":" # jAccount(b.account) # ",\"ledgerCanister\":" # jOptPrincipal(b.ledgerCanister) # ",\"currency\":" # jOptText(b.currency) # ",\"balance\":" # jNat(b.balance) # ",\"capturedAt\":" # jInt(b.capturedAt) # ",\"snapshotHash\":" # jBlob(b.snapshotHash) # "}";
  };

  func jIssue(i : ValidationIssue) : Text {
    "{\"severity\":" # jText(i.severity) # ",\"tier\":" # jText(i.tier) # ",\"ruleId\":" # jText(i.ruleId) # ",\"path\":" # jText(i.path) # ",\"message\":" # jText(i.message) # "}";
  };

  public query func certifiedAuditDisclosureJson() : async Text {
    "{\"certificate\":" # jOptBlob(CertifiedData.getCertificate()) # ",\"root\":" # jRoot(certifiedDisclosureRootState) # ",\"audit\":" # jAudit(certifiedAuditSnapshot) # "}";
  };

  public query func certifiedDisclosureCertificateJson() : async Text {
    "{\"certificate\":" # jOptBlob(CertifiedData.getCertificate()) # ",\"root\":" # jRoot(certifiedDisclosureRootState) # "}";
  };

  public query func listCertifiedParticipantBalancesJson(offset : Nat, limit : Nat) : async Text {
    let page = Pagination.page<CertifiedParticipantBalance>(certifiedBalancesOrdered(), offset, limit);
    var items = "[";
    var first = true;
    for (b in page.items.vals()) {
      if (first) { first := false } else { items #= "," };
      items #= jBalance(b);
    };
    items #= "]";
    "{\"items\":" # items # ",\"nextOffset\":" # jOptNat(page.nextOffset) # ",\"total\":" # jNat(page.total) # "}";
  };

  public query func verifyCertifiedDisclosureJson() : async Text {
    let r = verifyCertifiedDisclosureReport();
    var issues = "[";
    var first = true;
    for (i in r.issues.vals()) {
      if (first) { first := false } else { issues #= "," };
      issues #= jIssue(i);
    };
    issues #= "]";
    "{\"ok\":" # jBool(r.ok) # ",\"guidelineId\":" # jText(r.guidelineId) # ",\"messageKind\":" # jText(r.messageKind) # ",\"messageVersion\":" # jText(r.messageVersion) # ",\"issueCount\":" # jNat(r.issueCount) # ",\"issues\":" # issues # "}";
  };

  public query func verifyAuditChain() : async Bool {
    auditChainOk()
  };

  func auditTipCore() : AuditTip {
    {
      count = nextAuditId;
      lastAuditId = if (nextAuditId == 0) null else ?(nextAuditId - 1);
      lastAuditHash;
      merkleRoot = auditMerkleRoot();
      mmrRoot = AuditMMR.root(auditMmr);
      mmrLeafCount = auditMmr.leafCount;
      mmrPeakCount = AuditMMR.peakCount(auditMmr);
      guidelineId = guideline.id;
    };
  };

  func makeCertifiedAuditSnapshot(capturedAt : Int) : CertifiedAuditSnapshot {
    let tip = auditTipCore();
    let draft : CertifiedAuditSnapshot = {
      capturedAt;
      count = tip.count;
      lastAuditId = tip.lastAuditId;
      lastAuditHash = tip.lastAuditHash;
      merkleRoot = tip.merkleRoot;
      mmrRoot = tip.mmrRoot;
      mmrLeafCount = tip.mmrLeafCount;
      mmrPeakCount = tip.mmrPeakCount;
      guidelineId = tip.guidelineId;
      snapshotHash = zeroCertifiedHash;
    };
    { draft with snapshotHash = certifiedAuditSnapshotHash(draft) };
  };

  func makeCertifiedParticipantBalance(
    bicfi : Text,
    account : IcrcAccount,
    ledgerCanister : ?Principal,
    currency : ?Text,
    balance : Nat,
    capturedAt : Int,
  ) : CertifiedParticipantBalance {
    let draft : CertifiedParticipantBalance = {
      bicfi;
      account;
      ledgerCanister;
      currency;
      balance;
      capturedAt;
      snapshotHash = zeroCertifiedHash;
    };
    { draft with snapshotHash = certifiedParticipantBalanceHash(draft) };
  };

  func certifiedBalancesOrdered() : [CertifiedParticipantBalance] {
    Array.sort<CertifiedParticipantBalance>(
      Iter.toArray(Map.values(certifiedParticipantBalances)),
      func(a, b) { Text.compare(a.bicfi, b.bicfi) },
    );
  };

  func commitCertifiedDisclosure(capturedAt : Int) : CertifiedDisclosureRoot {
    let audit = makeCertifiedAuditSnapshot(capturedAt);
    certifiedAuditSnapshot := audit;
    let balances = certifiedBalancesOrdered();
    let balanceRoot = certifiedBalanceRoot(balances);
    let draft : CertifiedDisclosureRoot = {
      version = certifiedDisclosureVersion;
      updatedAt = capturedAt;
      auditSnapshotHash = audit.snapshotHash;
      balanceRoot;
      balanceCount = balances.size();
      rootHash = zeroCertifiedHash;
    };
    let root = { draft with rootHash = certifiedDisclosureRootHash(draft) };
    certifiedDisclosureRootState := root;
    CertifiedData.set(root.rootHash);
    root;
  };

  func verifyCertifiedDisclosureReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    let expectedAudit = makeCertifiedAuditSnapshot(certifiedAuditSnapshot.capturedAt);
    if (certifiedAuditSnapshot.snapshotHash != certifiedAuditSnapshotHash(certifiedAuditSnapshot)) {
      issues := addIssue(issues, oracleIssue("CERT-AUDIT-SNAPSHOT-HASH", "$.certified.audit.snapshotHash", "certified audit snapshot hash must match its fields"));
    };
    if (certifiedAuditSnapshot.snapshotHash != expectedAudit.snapshotHash) {
      issues := addIssue(issues, oracleIssue("CERT-AUDIT-SNAPSHOT-CURRENT", "$.certified.audit", "certified audit snapshot must match the current audit tip"));
    };
    for (balance in Map.values(certifiedParticipantBalances)) {
      if (balance.snapshotHash != certifiedParticipantBalanceHash(balance)) {
        issues := addIssue(issues, oracleIssue("CERT-BALANCE-SNAPSHOT-HASH", "$.certified.balances", "certified participant balance hash must match its fields"));
      };
    };
    let balances = certifiedBalancesOrdered();
    let balanceRoot = certifiedBalanceRoot(balances);
    if (certifiedDisclosureRootState.auditSnapshotHash != certifiedAuditSnapshot.snapshotHash) {
      issues := addIssue(issues, oracleIssue("CERT-ROOT-AUDIT-HASH", "$.certified.root.auditSnapshotHash", "certified root must commit to the audit snapshot hash"));
    };
    if (certifiedDisclosureRootState.balanceRoot != balanceRoot) {
      issues := addIssue(issues, oracleIssue("CERT-ROOT-BALANCE-HASH", "$.certified.root.balanceRoot", "certified root must commit to the balance snapshot root"));
    };
    if (certifiedDisclosureRootState.balanceCount != balances.size()) {
      issues := addIssue(issues, oracleIssue("CERT-ROOT-BALANCE-COUNT", "$.certified.root.balanceCount", "certified balance count must equal stored balance snapshots"));
    };
    if (certifiedDisclosureRootState.rootHash != certifiedDisclosureRootHash({ certifiedDisclosureRootState with rootHash = zeroCertifiedHash })) {
      issues := addIssue(issues, oracleIssue("CERT-ROOT-HASH", "$.certified.root.rootHash", "certified disclosure root hash must match its fields"));
    };
    if (certifiedDisclosureRootState.rootHash.size() > 32) {
      issues := addIssue(issues, oracleIssue("CERT-ROOT-SIZE", "$.certified.root.rootHash", "IC certified_data root must be at most 32 bytes"));
    };
    oracleReport("certified.disclosure", issues);
  };

  func auditChainOk() : Bool {
    var expectedParent : ?Blob = null;
    var rebuiltMmr = AuditMMR.empty();
    var i = 0;
    while (i < nextAuditId) {
      switch (Map.get(audits, Nat.compare, i)) {
        case null { return false };
        case (?rec) {
          if (not optBlobEq(rec.parentHash, expectedParent)) return false;
          if (rec.recordHash != computeAuditHash(rec)) return false;
          expectedParent := ?rec.recordHash;
          rebuiltMmr := AuditMMR.append(rebuiltMmr, rec.recordHash);
        };
      };
      i += 1;
    };
    optBlobEq(expectedParent, lastAuditHash)
      and rebuiltMmr.leafCount == auditMmr.leafCount
      and optBlobEq(AuditMMR.root(rebuiltMmr), AuditMMR.root(auditMmr));
  };

  public query func auditProof(id : Nat) : async ?AuditProof {
    if (id >= nextAuditId) return null;
    let leaves = auditHashesInOrder();
    if (leaves.size() == 0) return null;
    var idx = id;
    var level = leaves;
    var siblings : [Blob] = [];
    while (level.size() > 1) {
      let siblingIndex = if (idx % 2 == 0) {
        if (idx + 1 < level.size()) idx + 1 else idx
      } else {
        Int.abs((idx : Int) - 1)
      };
      siblings := Array.concat<Blob>(siblings, [level[siblingIndex]]);
      level := nextMerkleLevel(level);
      idx /= 2;
    };
    ?{
      auditId = id;
      leaf = leaves[id];
      root = level[0];
      siblings;
      leafIndex = id;
    };
  };

  public query func listAudits(offset : Nat, limit : Nat) : async Pagination.Page<AuditRecord> {
    Pagination.page<AuditRecord>(Iter.toArray(Map.values(audits)), offset, limit);
  };

  public query func listAuditViews(offset : Nat, limit : Nat) : async Pagination.Page<AuditView> {
    let views = Array.map<AuditRecord, AuditView>(Iter.toArray(Map.values(audits)), auditView);
    Pagination.page<AuditView>(views, offset, limit);
  };

  func oraclePhaseVerifications() : [PhaseVerification] {
    [
      ISO.phaseVerification("guideline.configuration", verifyGuidelineOracleReport()),
      ISO.phaseVerification("xml.codec", verifyXmlCodecOracleReport()),
      ISO.phaseVerification("payment.lifecycle", verifyLifecycleOracleReport()),
      ISO.phaseVerification("crossborder.cover", verifyCrossBorderOracleReport()),
      ISO.phaseVerification("exceptions.investigations", verifyInvestigationOracleReport()),
      ISO.phaseVerification("compliance.screening", verifyComplianceOracleReport()),
      ISO.phaseVerification("connector.envelope", verifyConnectorOracleReport()),
      ISO.phaseVerification("connector.outbound", verifyOutboundOracleReport()),
      ISO.phaseVerification("legacy.mt103", verifyLegacyMtOracleReport()),
      ISO.phaseVerification("audit.evidence", verifyAuditOracleReport()),
      ISO.phaseVerification("certified.disclosure", verifyCertifiedDisclosureReport()),
      ISO.phaseVerification("participant.workflow", verifyParticipantWorkflowOracleReport()),
      ISO.phaseVerification("pfmi.self.assessment", verifyPfmiSelfAssessmentReport()),
      ISO.phaseVerification("duplicate.indexes", verifyDuplicateOracleReport()),
      ISO.phaseVerification("stable.indexes", verifyDuplicateOracleReport()),
    ];
  };

  func verifyGuidelineOracleReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    if (guideline.id == "") {
      issues := addIssue(issues, oracleIssue("GUIDELINE-ID-REQUIRED", "$.guideline.id", "active guideline id is required"));
    };
    if (guideline.maxMessageBytes == 0) {
      issues := addIssue(issues, oracleIssue("GUIDELINE-MAX-BYTES", "$.guideline.maxMessageBytes", "maxMessageBytes must be positive"));
    };
    for (kind in ["head.001", "pain.001", "pain.002", "pacs.008", "pacs.009", "pacs.002", "pacs.004", "camt.053", "camt.054"].vals()) {
      if (not guidelineHasMessageKind(kind)) {
        issues := addIssue(issues, oracleIssue("GUIDELINE-MSG-VERSION", "$.guideline.messageVersions", "missing message version for " # kind));
      };
    };
    if (guideline.currencies.size() == 0) {
      issues := addIssue(issues, oracleIssue("GUIDELINE-CURRENCY-SET", "$.guideline.currencies", "at least one active currency is required"));
    };
    for (c in guideline.currencies.vals()) {
      if (not ISO.validCurrencyCode(c.code)) {
        issues := addIssue(issues, oracleIssue("GUIDELINE-CURRENCY-CODE", "$.guideline.currencies", "currency code must be ISO 4217 uppercase alpha-3"));
      };
      if (c.fractionDigits > 3) {
        issues := addIssue(issues, oracleIssue("GUIDELINE-CURRENCY-FRACTION", "$.guideline.currencies", "currency fraction digits should be bounded for fixed minor-unit accounting"));
      };
    };
    for (country in guideline.countryCodes.vals()) {
      if (not ISO.validCountryCode(country)) {
        issues := addIssue(issues, oracleIssue("GUIDELINE-COUNTRY-CODE", "$.guideline.countryCodes", "country code must be ISO 3166-1 alpha-2"));
      };
    };
    switch (guideline.requiredAgentCountry) {
      case (?country) {
        if (not ISO.validCountryCode(country)) issues := addIssue(issues, oracleIssue("GUIDELINE-AGENT-COUNTRY", "$.guideline.requiredAgentCountry", "required agent country must be ISO 3166-1 alpha-2"));
      };
      case null {};
    };
    switch (guideline.requiredIbanCountry) {
      case (?country) {
        if (not ISO.validCountryCode(country)) issues := addIssue(issues, oracleIssue("GUIDELINE-IBAN-COUNTRY", "$.guideline.requiredIbanCountry", "required IBAN country must be ISO 3166-1 alpha-2"));
      };
      case null {};
    };
    if (guideline.settlementMethod == "") {
      issues := addIssue(issues, oracleIssue("GUIDELINE-SETTLEMENT-METHOD", "$.guideline.settlementMethod", "settlement method is required"));
    };
    for (profileId in [egGuidelineProfileId, cbprGuidelineProfileId, sepaSctGuidelineProfileId, fedwireGuidelineProfileId].vals()) {
      let profile = requireGuidelineProfile(profileId);
      if (profile.guideline.id == "") {
        issues := addIssue(issues, oracleIssue("GUIDELINE-PROFILE-ID", "$.guidelineProfiles." # profileId, "runtime guideline profile must expose a concrete guideline id"));
      };
    };
    if (not ISO.validatePain001(requireGuidelineForProfile(egGuidelineProfileId), ISO.demoPain001(), null).ok) {
      issues := addIssue(issues, oracleIssue("GUIDELINE-PROFILE-EG-DOMESTIC", "$.guidelineProfiles.EG-DOMESTIC-EDU", "EG profile must validate the domestic demo pain.001"));
    };
    if (ISO.validatePain001(requireGuidelineForProfile(egGuidelineProfileId), ISO.demoCrossBorderPain001(), null).ok) {
      issues := addIssue(issues, oracleIssue("GUIDELINE-PROFILE-EG-BOUNDARY", "$.guidelineProfiles.EG-DOMESTIC-EDU", "EG profile must keep rejecting the cross-border demo that violates EG BIC/IBAN rules"));
    };
    for (profileId in [cbprGuidelineProfileId, sepaSctGuidelineProfileId, fedwireGuidelineProfileId].vals()) {
      if (not ISO.validatePain001(requireGuidelineForProfile(profileId), ISO.demoCrossBorderPain001(), null).ok) {
        issues := addIssue(issues, oracleIssue("GUIDELINE-PROFILE-RUNTIME-SELECTION", "$.guidelineProfiles." # profileId, "runtime profile must validate the cross-market demo pain.001 under its selected guideline"));
      };
    };
    oracleReport("guideline.configuration", issues);
  };

  func verifyXmlCodecOracleReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    let demo = ISO.demoPain001();
    let xml = Xml.pain001ToXml(demo);
    if (not Text.contains(xml, #text "<CstmrCdtTrfInitn>")) {
      issues := addIssue(issues, oracleIssue("XML-PAIN001-ROOT", "$xml", "pain.001 serializer must emit CstmrCdtTrfInitn"));
    };
    switch (Xml.decodePain001(Text.encodeUtf8(xml))) {
      case (#ok(decoded)) {
        if (decoded.messageId != demo.messageId) {
          issues := addIssue(issues, oracleIssue("XML-ROUNDTRIP-MSGID", "$xml.MsgId", "pain.001 XML roundtrip must preserve message id"));
        };
        if (decoded.instructedAmount != demo.instructedAmount) {
          issues := addIssue(issues, oracleIssue("XML-ROUNDTRIP-AMOUNT", "$xml.InstdAmt", "pain.001 XML roundtrip must preserve amount"));
        };
        let report = ISO.validatePain001(ISO.defaultGuideline(), decoded, ?Text.encodeUtf8(xml));
        for (i in report.issues.vals()) issues := addIssue(issues, i);
      };
      case (#err(parseIssues)) {
        for (i in parseIssues.vals()) issues := addIssue(issues, i);
      };
    };
    switch (Xml.decodePain001(Text.encodeUtf8("<!DOCTYPE foo [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]><Document/>"))) {
      case (#ok(_)) {
        issues := addIssue(issues, oracleIssue("XML-UNSAFE-DECL-ORACLE", "$xml", "XML codec must reject DTD/entity payloads"));
      };
      case (#err(_)) {};
    };
    let pacs = ISO.demoPacs008();
    let pacsXml = Xml.pacs008ToXml(pacs);
    if (not Text.contains(pacsXml, #text "<FIToFICstmrCdtTrf>")) {
      issues := addIssue(issues, oracleIssue("XML-PACS008-ROOT", "$xml", "pacs.008 serializer must emit FIToFICstmrCdtTrf"));
    };
    switch (Xml.decodePacs008(Text.encodeUtf8(pacsXml))) {
      case (#ok(decoded)) {
        if (decoded.messageId != pacs.messageId) {
          issues := addIssue(issues, oracleIssue("XML-PACS008-ROUNDTRIP-MSGID", "$xml.MsgId", "pacs.008 XML roundtrip must preserve message id"));
        };
        if (decoded.instructedAmount != pacs.instructedAmount) {
          issues := addIssue(issues, oracleIssue("XML-PACS008-ROUNDTRIP-AMOUNT", "$xml.InstdAmt", "pacs.008 XML roundtrip must preserve amount"));
        };
        let report = ISO.validatePacs008(ISO.defaultGuideline(), decoded, ?Text.encodeUtf8(pacsXml));
        for (i in report.issues.vals()) issues := addIssue(issues, i);
      };
      case (#err(parseIssues)) {
        for (i in parseIssues.vals()) issues := addIssue(issues, i);
      };
    };
    let status = ISO.pacs002(ISO.defaultGuideline(), "PACS002-XML-ORACLE", pacs.messageId, "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011", "ACSC", null, pacs.creationDateTime);
    let statusXml = Xml.statusReportToXml(status);
    switch (Xml.decodeStatusReport(Text.encodeUtf8(statusXml))) {
      case (#ok(decoded)) {
        if (decoded.messageKind != "pacs.002") {
          issues := addIssue(issues, oracleIssue("XML-STATUS-KIND", "$xml.status.messageKind", "status XML decoder must preserve status message kind"));
        };
        if (decoded.messageId != status.messageId or decoded.originalMessageId != status.originalMessageId) {
          issues := addIssue(issues, oracleIssue("XML-STATUS-ROUNDTRIP-ID", "$xml.status.MsgId", "status XML roundtrip must preserve message ids"));
        };
        let report = ISO.validateStatusReport(ISO.defaultGuideline(), decoded, "pacs.002");
        for (i in report.issues.vals()) issues := addIssue(issues, i);
      };
      case (#err(parseIssues)) {
        for (i in parseIssues.vals()) issues := addIssue(issues, i);
      };
    };
    let crossBorder = ISO.crossBorderEducationGuideline();
    let pacs009 = ISO.demoPacs009Core();
    let pacs009Xml = Xml.pacs009ToXml(pacs009);
    switch (Xml.decodePacs009(Text.encodeUtf8(pacs009Xml))) {
      case (#ok(decoded)) {
        if (decoded.messageId != pacs009.messageId) {
          issues := addIssue(issues, oracleIssue("XML-PACS009-ROUNDTRIP-MSGID", "$xml.pacs009.MsgId", "pacs.009 XML roundtrip must preserve message id"));
        };
        let report = ISO.validatePacs009(crossBorder, decoded, ?Text.encodeUtf8(pacs009Xml));
        for (i in report.issues.vals()) issues := addIssue(issues, i);
      };
      case (#err(parseIssues)) {
        for (i in parseIssues.vals()) issues := addIssue(issues, i);
      };
    };
    let cover = ISO.demoCoverPayment();
    let coverXml = Xml.coverPaymentToXml(cover);
    switch (Xml.decodeCoverPayment(Text.encodeUtf8(coverXml))) {
      case (#ok(decoded)) {
        let report = ISO.validateCoverPayment(crossBorder, decoded, ?Text.encodeUtf8(coverXml));
        for (i in report.issues.vals()) issues := addIssue(issues, i);
      };
      case (#err(parseIssues)) {
        for (i in parseIssues.vals()) issues := addIssue(issues, i);
      };
    };
    for (inv in [ISO.demoCamt056(), ISO.demoCamt029(), ISO.demoPacs028(), ISO.demoCamt110(), ISO.demoCamt111()].vals()) {
      let invXml = Xml.investigationToXml(inv);
      switch (Xml.decodeInvestigation(Text.encodeUtf8(invXml))) {
        case (#ok(decoded)) {
          let report = ISO.validateInvestigation(crossBorder, decoded);
          for (i in report.issues.vals()) issues := addIssue(issues, i);
        };
        case (#err(parseIssues)) {
          for (i in parseIssues.vals()) issues := addIssue(issues, i);
        };
      };
    };
    for (rtp in [ISO.demoPain013(), ISO.demoPain014Accepted(), ISO.demoCamt055()].vals()) {
      let rtpXml = Xml.requestToPayToXml(rtp);
      switch (Xml.decodeRequestToPay(Text.encodeUtf8(rtpXml))) {
        case (#ok(decoded)) {
          let report = ISO.validateRequestToPay(crossBorder, decoded);
          for (i in report.issues.vals()) issues := addIssue(issues, i);
        };
        case (#err(parseIssues)) {
          for (i in parseIssues.vals()) issues := addIssue(issues, i);
        };
      };
    };
    for (dd in [ISO.demoPain008(), ISO.demoPacs003()].vals()) {
      let ddXml = Xml.directDebitToXml(dd);
      switch (Xml.decodeDirectDebit(Text.encodeUtf8(ddXml))) {
        case (#ok(decoded)) {
          let report = ISO.validateDirectDebit(crossBorder, decoded, ?Text.encodeUtf8(ddXml));
          for (i in report.issues.vals()) issues := addIssue(issues, i);
        };
        case (#err(parseIssues)) {
          for (i in parseIssues.vals()) issues := addIssue(issues, i);
        };
      };
    };
    for (admi in [ISO.demoAdmi002Reject(), ISO.demoAdmi004ConnectionCheck(), ISO.demoAdmi007Ack(), ISO.demoAdmi011ConnectionAck()].vals()) {
      let admiXml = Xml.administrativeToXml(admi);
      switch (Xml.decodeAdministrative(Text.encodeUtf8(admiXml))) {
        case (#ok(decoded)) {
          let report = ISO.validateAdministrativeMessage(crossBorder, decoded);
          for (i in report.issues.vals()) issues := addIssue(issues, i);
        };
        case (#err(parseIssues)) {
          for (i in parseIssues.vals()) issues := addIssue(issues, i);
        };
      };
    };
    let statement : StatementEntry = {
      entryId = "CAMT-XML-ORACLE";
      paymentId = 0;
      uetr = "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
      accountIban = ?"EG380019000500000000263180002";
      accountOtherId = null;
      amount = { currency = "EGP"; minorUnits = 1_250_000 };
      creditDebit = "CRDT";
      status = "settled";
      bookedAt = 0;
      counterpartyName = "Oracle Debtor";
      remittance = ["oracle statement entry"];
    };
    switch (Xml.decodeCamt054(Text.encodeUtf8(Xml.camt054ToXml(statement)))) {
      case (#ok(entries)) {
        if (entries.size() != 1 or entries[0].uetr != statement.uetr) {
          issues := addIssue(issues, oracleIssue("XML-CAMT054-ROUNDTRIP", "$xml.camt054", "camt.054 XML roundtrip must preserve statement entry"));
        };
      };
      case (#err(parseIssues)) {
        for (i in parseIssues.vals()) issues := addIssue(issues, i);
      };
    };
    switch (Xml.decodeCamt053(Text.encodeUtf8(Xml.camt053ToXml([statement])))) {
      case (#ok(entries)) {
        if (entries.size() != 1 or entries[0].entryId != statement.entryId) {
          issues := addIssue(issues, oracleIssue("XML-CAMT053-ROUNDTRIP", "$xml.camt053", "camt.053 XML roundtrip must preserve statement entries"));
        };
      };
      case (#err(parseIssues)) {
        for (i in parseIssues.vals()) issues := addIssue(issues, i);
      };
    };
    oracleReport("xml.codec", issues);
  };

  func verifyLifecycleOracleReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    let pain = ISO.demoPain001();
    let painReport = ISO.validatePain001(guideline, pain, null);
    for (i in painReport.issues.vals()) issues := addIssue(issues, i);
    let uetr = switch (pain.requestedUetr) { case (?u) u; case null "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011" };
    let pacs = ISO.pacs008FromPain001(guideline, pain, uetr, pain.creationDateTime);
    let pacsReport = ISO.validatePacs008(guideline, pacs, null);
    for (i in pacsReport.issues.vals()) issues := addIssue(issues, i);
    let pain002 = ISO.pain002FromValidation(guideline, "PAIN002-ORACLE", pain.messageId, uetr, pain.creationDateTime, pacsReport);
    for (i in ISO.validateStatusReport(guideline, pain002, "pain.002").issues.vals()) issues := addIssue(issues, i);
    let pacs002 = ISO.pacs002(guideline, "PACS002-ORACLE", pain.messageId, uetr, "ACSC", null, pain.creationDateTime);
    for (i in ISO.validateStatusReport(guideline, pacs002, "pacs.002").issues.vals()) issues := addIssue(issues, i);
    let pacs004 = ISO.pacs004(guideline, "PACS004-ORACLE", pain.messageId, uetr, "return: oracle", pain.creationDateTime);
    for (i in ISO.validateStatusReport(guideline, pacs004, "pacs.004").issues.vals()) issues := addIssue(issues, i);
    oracleReport("payment.lifecycle", issues);
  };

  func verifyCrossBorderOracleReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    let g = ISO.crossBorderEducationGuideline();
    for (i in ISO.validatePacs009(g, ISO.demoPacs009Core(), null).issues.vals()) issues := addIssue(issues, i);
    for (i in ISO.validateCoverPayment(g, ISO.demoCoverPayment(), null).issues.vals()) issues := addIssue(issues, i);
    let report = ISO.screenCoverPayment(complianceProfile, ISO.demoCoverPayment());
    if (report.findingCount != report.findings.size()) {
      issues := addIssue(issues, oracleIssue("COMPLIANCE-FINDING-COUNT", "$.compliance.findingCount", "compliance report finding count must equal findings length"));
    };
    oracleReport("crossborder.cover", issues);
  };

  func verifyInvestigationOracleReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    let g = ISO.crossBorderEducationGuideline();
    for (i in ISO.validateInvestigation(g, ISO.demoCamt056()).issues.vals()) issues := addIssue(issues, i);
    for (i in ISO.validateInvestigation(g, ISO.demoCamt029()).issues.vals()) issues := addIssue(issues, i);
    for (i in ISO.validateInvestigation(g, ISO.demoPacs028()).issues.vals()) issues := addIssue(issues, i);
    for (i in ISO.validateInvestigation(g, ISO.demoCamt110()).issues.vals()) issues := addIssue(issues, i);
    for (i in ISO.validateInvestigation(g, ISO.demoCamt111()).issues.vals()) issues := addIssue(issues, i);
    oracleReport("exceptions.investigations", issues);
  };

  func verifyComplianceOracleReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    if (complianceProfile.id == "") {
      issues := addIssue(issues, oracleIssue("COMPLIANCE-PROFILE-ID", "$.complianceProfile.id", "compliance profile id is required"));
    };
    if (complianceProfile.highValueThresholdMinorUnits == 0) {
      issues := addIssue(issues, oracleIssue("COMPLIANCE-HIGH-VALUE-THRESHOLD", "$.complianceProfile.highValueThresholdMinorUnits", "high-value threshold must be positive"));
    };
    for (cb in complianceProfile.allowedChargeBearers.vals()) {
      if (not (cb == "DEBT" or cb == "CRED" or cb == "SHAR" or cb == "SLEV")) {
        issues := addIssue(issues, oracleIssue("COMPLIANCE-CHRGBR", "$.complianceProfile.allowedChargeBearers", "allowed charge bearer must be DEBT, CRED, SHAR, or SLEV"));
      };
    };
    let report = ISO.screenCoverPayment(complianceProfile, ISO.demoCoverPayment());
    if (not validComplianceDecision(report.decision)) {
      issues := addIssue(issues, oracleIssue("COMPLIANCE-DECISION", "$.decision", "compliance decision must be pass, review, or block"));
    };
    if (report.findingCount != report.findings.size()) {
      issues := addIssue(issues, oracleIssue("COMPLIANCE-FINDING-COUNT", "$.findingCount", "finding count must equal findings length"));
    };
    oracleReport("compliance.screening", issues);
  };

  func verifyConnectorOracleReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    for (c in Map.values(connectors)) {
      if (c.id == "") {
        issues := addIssue(issues, oracleIssue("CONNECTOR-ID-REQUIRED", "$.connector.id", "connector id is required"));
      };
      if (c.allowedFormats.size() == 0) {
        issues := addIssue(issues, oracleIssue("CONNECTOR-FORMATS-REQUIRED", "$.connector.allowedFormats", "connector should declare at least one allowed format"));
      };
      let policy = c.signaturePolicy;
      if (not Oracles.validPolicyMode(policy.mode)) {
        issues := addIssue(issues, oracleIssue("CONNECTOR-POLICY-MODE", "$.connector.signaturePolicy.mode", "connector signature policy mode is not in the phase oracle vocabulary"));
      };
      if (not Oracles.validSignatureScheme(policy.scheme)) {
        issues := addIssue(issues, oracleIssue("CONNECTOR-POLICY-SCHEME", "$.connector.signaturePolicy.scheme", "connector signature scheme is not in the phase oracle vocabulary"));
      };
      if (policy.mode == "none" and policy.requireSignature) {
        issues := addIssue(issues, oracleIssue("CONNECTOR-POLICY-NONE-SIGNATURE", "$.connector.signaturePolicy.requireSignature", "none policy cannot require a detached signature"));
      };
      if (policy.mode == "external-attestation") {
        if (not policy.requireSignature) {
          issues := addIssue(issues, oracleIssue("CONNECTOR-POLICY-EXT-SIGNATURE", "$.connector.signaturePolicy.requireSignature", "external attestation must require a signature"));
        };
        switch (policy.verifier) {
          case null issues := addIssue(issues, oracleIssue("CONNECTOR-POLICY-EXT-VERIFIER", "$.connector.signaturePolicy.verifier", "external attestation requires a verifier canister"));
          case (?_) {};
        };
      };
    };
    let payload = Text.encodeUtf8("<Document/>");
    let env : TransportEnvelope = {
      connectorId = "oracle-connector";
      remoteId = "oracle-remote";
      sequence = 0;
      format = "pain.001.xml";
      payload;
      payloadHash = hashBlob(payload);
      signature = ?Text.encodeUtf8("oracle-signature");
      sentAt = 0;
      traceId = "oracle-trace";
      endpoint = null;
    };
    let h1 = connectorEnvelopeHash(env, env.payloadHash, "thebes.iso20022.connector.v1");
    let h2 = connectorEnvelopeHash(env, env.payloadHash, "thebes.iso20022.connector.v1");
    if (h1 != h2 or h1.size() != 32) {
      issues := addIssue(issues, oracleIssue("CONNECTOR-SIGNING-HASH", "$.connectorEnvelopeSigningHash", "connector signing hash must be deterministic SHA-256"));
    };
    oracleReport("connector.envelope", issues);
  };

  func verifyOutboundOracleReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    for (batch in Map.values(outboundBatches)) {
      if (not Oracles.validOutboundStatus(batch.status)) {
        issues := addIssue(issues, oracleIssue("OUTBOUND-STATUS", "$.outbound.status", "outbound batch status is not in the phase oracle vocabulary"));
      };
      if (batch.payloadHash != hashBlob(batch.payload)) {
        issues := addIssue(issues, oracleIssue("OUTBOUND-PAYLOAD-HASH", "$.outbound.payloadHash", "outbound batch payload hash must match payload"));
      };
      if (batch.issueCount != batch.issues.size()) {
        issues := addIssue(issues, oracleIssue("OUTBOUND-ISSUE-COUNT", "$.outbound.issueCount", "outbound issue count must equal issues length"));
      };
      if (batch.status == "leased") {
        switch (batch.leasedUntil) {
          case null issues := addIssue(issues, oracleIssue("OUTBOUND-LEASE-UNTIL", "$.outbound.leasedUntil", "leased outbound batch requires leasedUntil"));
          case (?_) {};
        };
      };
      switch (batch.ack) {
        case (?ack) {
          if (ack.connectorId != batch.connectorId) {
            issues := addIssue(issues, oracleIssue("OUTBOUND-ACK-CONNECTOR", "$.outbound.ack.connectorId", "outbound ACK connector must match batch"));
          };
          if (ack.payloadHash != batch.payloadHash) {
            issues := addIssue(issues, oracleIssue("OUTBOUND-ACK-HASH", "$.outbound.ack.payloadHash", "outbound ACK payload hash must match batch"));
          };
          if (not Oracles.validAckStatus(ack.status)) {
            issues := addIssue(issues, oracleIssue("OUTBOUND-ACK-STATUS", "$.outbound.ack.status", "outbound ACK status must be ACK or NACK"));
          };
        };
        case null {
          if (batch.status == "acked" or batch.status == "nacked") {
            issues := addIssue(issues, oracleIssue("OUTBOUND-ACK-REQUIRED", "$.outbound.ack", "acked/nacked outbound batch requires ACK record"));
          };
        };
      };
    };
    oracleReport("connector.outbound", issues);
  };

  func verifyLegacyMtOracleReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    switch (LegacyMT.decodeMt103(Text.encodeUtf8(sampleMt103()), "EG")) {
      case (#ok(doc)) {
        if (doc.messageId != "MT103-20260622-0001") {
          issues := addIssue(issues, oracleIssue("MT103-MSGID", "$.20", "MT103 field 20 must map to messageId"));
        };
        if (doc.instructedAmount.currency != "EGP" or doc.instructedAmount.minorUnits != 1_250_000) {
          issues := addIssue(issues, oracleIssue("MT103-AMOUNT", "$.32A", "MT103 field 32A must map date/currency/amount"));
        };
        for (i in ISO.validatePain001(ISO.defaultGuideline(), doc, ?Text.encodeUtf8(sampleMt103())).issues.vals()) {
          issues := addIssue(issues, i);
        };
      };
      case (#err(parseIssues)) {
        for (i in parseIssues.vals()) issues := addIssue(issues, i);
      };
    };
    oracleReport("legacy.mt103", issues);
  };

  func verifyAuditOracleReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    if (not auditChainOk()) {
      issues := addIssue(issues, oracleIssue("AUDIT-CHAIN", "$.audit", "audit hash chain/MMR state verification failed"));
    };
    if (auditMmr.leafCount != nextAuditId) {
      issues := addIssue(issues, oracleIssue("AUDIT-MMR-LEAF-COUNT", "$.auditMmr.leafCount", "MMR leaf count must equal audit count"));
    };
    if (nextAuditId > 0) {
      switch (lastAuditHash) {
        case null issues := addIssue(issues, oracleIssue("AUDIT-LAST-HASH", "$.lastAuditHash", "non-empty audit log requires last audit hash"));
        case (?_) {};
      };
      switch (auditMerkleRoot()) {
        case null issues := addIssue(issues, oracleIssue("AUDIT-MERKLE-ROOT", "$.merkleRoot", "non-empty audit log requires Merkle root"));
        case (?_) {};
      };
    };
    oracleReport("audit.evidence", issues);
  };

  func verifyDuplicateOracleReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    if (Map.size(paymentByUetr) > Map.size(payments)) {
      issues := addIssue(issues, oracleIssue("DUPLICATE-UETR-INDEX-SIZE", "$.paymentByUetr", "UETR exact index cannot exceed payment count"));
    };
    if (Map.size(paymentByMessageId) > Map.size(payments)) {
      issues := addIssue(issues, oracleIssue("DUPLICATE-MSGID-INDEX-SIZE", "$.paymentByMessageId", "messageId exact index cannot exceed payment count"));
    };
    let health = secondaryIndexHealthCore();
    if (not health.paymentStatus.ok) {
      issues := addIssue(issues, oracleIssue("ORDERED-PAYMENT-STATUS-INDEX", "$.paymentStatusIndex", "payment status ordered index invariant failed"));
    };
    if (not health.paymentAccount.ok) {
      issues := addIssue(issues, oracleIssue("ORDERED-PAYMENT-ACCOUNT-INDEX", "$.paymentAccountIndex", "payment account ordered index invariant failed"));
    };
    if (not health.paymentCreditorAgent.ok) {
      issues := addIssue(issues, oracleIssue("ORDERED-PAYMENT-AGENT-INDEX", "$.paymentCreditorAgentIndex", "payment creditor-agent ordered index invariant failed"));
    };
    if (health.paymentStatusSize != Map.size(payments) or health.paymentAccountSize != Map.size(payments) or health.paymentCreditorAgentSize != Map.size(payments)) {
      issues := addIssue(issues, oracleIssue("ORDERED-PAYMENT-INDEX-SIZE", "$.secondaryIndexes", "payment ordered indexes must contain one entry per payment"));
    };
    if (not health.outboundQueue.ok) {
      issues := addIssue(issues, oracleIssue("ORDERED-OUTBOUND-QUEUE-INDEX", "$.outboundQueueIndex", "outbound queue ordered index invariant failed"));
    };
    if (health.outboundQueueSize != Map.size(outboundBatches)) {
      issues := addIssue(issues, oracleIssue("ORDERED-OUTBOUND-INDEX-SIZE", "$.outboundQueueIndex", "outbound ordered index must contain one entry per outbound batch"));
    };
    if (not health.stablePaymentStatus.ok) {
      issues := addIssue(issues, oracleIssue("STABLE-PAYMENT-STATUS-INDEX", "$.paymentStatusStableIndex", "stable payment status checkpoint invariant failed"));
    };
    if (not health.stablePaymentAccount.ok) {
      issues := addIssue(issues, oracleIssue("STABLE-PAYMENT-ACCOUNT-INDEX", "$.paymentAccountStableIndex", "stable payment account checkpoint invariant failed"));
    };
    if (not health.stablePaymentCreditorAgent.ok) {
      issues := addIssue(issues, oracleIssue("STABLE-PAYMENT-AGENT-INDEX", "$.paymentCreditorAgentStableIndex", "stable payment creditor-agent checkpoint invariant failed"));
    };
    if (health.stablePaymentStatus.metadata.entryCount != Map.size(payments) or health.stablePaymentAccount.metadata.entryCount != Map.size(payments) or health.stablePaymentCreditorAgent.metadata.entryCount != Map.size(payments)) {
      issues := addIssue(issues, oracleIssue("STABLE-PAYMENT-INDEX-SIZE", "$.stableSecondaryIndexes", "stable payment checkpoints must contain one entry per payment"));
    };
    if (not health.stableOutboundQueue.ok) {
      issues := addIssue(issues, oracleIssue("STABLE-OUTBOUND-QUEUE-INDEX", "$.outboundQueueStableIndex", "stable outbound queue checkpoint invariant failed"));
    };
    if (health.stableOutboundQueue.metadata.entryCount != Map.size(outboundBatches)) {
      issues := addIssue(issues, oracleIssue("STABLE-OUTBOUND-INDEX-SIZE", "$.outboundQueueStableIndex", "stable outbound checkpoint must contain one entry per outbound batch"));
    };
    for (p in Map.values(payments)) {
      let report = verifyPaymentIndexReport(p);
      for (i in report.issues.vals()) issues := addIssue(issues, i);
    };
    oracleReport("duplicate.indexes", issues);
  };

  func validateParticipantDirectoryInput(input : ParticipantDirectoryInput) : ValidationReport {
    var issues : [ValidationIssue] = [];
    if (not ISO.validBicFi(input.bicfi)) {
      issues := addIssue(issues, ISO.publicIssue("schema", "PARTICIPANT-BIC", "$.bicfi", "participant BICFI must be a valid ISO 9362 BIC"));
    };
    switch (input.lei) {
      case (?lei) {
        if (not ISO.validLei(lei)) {
          issues := addIssue(issues, ISO.publicIssue("schema", "PARTICIPANT-LEI", "$.lei", "participant LEI must be a valid ISO 17442 LEI"));
        };
      };
      case null {};
    };
    if (input.displayName == "") {
      issues := addIssue(issues, ISO.publicIssue("business", "PARTICIPANT-NAME", "$.displayName", "participant display name is required"));
    };
    if (not ISO.validCountryCode(input.country)) {
      issues := addIssue(issues, ISO.publicIssue("schema", "PARTICIPANT-COUNTRY", "$.country", "participant country must be ISO 3166-1 alpha-2"));
    };
    if (not validParticipantAccessTier(input.accessTier)) {
      issues := addIssue(issues, ISO.publicIssue("business", "PARTICIPANT-ACCESS-TIER", "$.accessTier", "participant access tier must be direct, indirect, or addressable"));
    };
    switch (input.parentBicfi) {
      case (?parent) {
        if (not ISO.validBicFi(parent)) {
          issues := addIssue(issues, ISO.publicIssue("schema", "PARTICIPANT-PARENT-BIC", "$.parentBicfi", "parent participant BICFI must be a valid ISO 9362 BIC"));
        };
      };
      case null {
        if (input.accessTier == "indirect" or input.accessTier == "addressable") {
          issues := addIssue(issues, ISO.publicIssue("business", "PARTICIPANT-PARENT-REQUIRED", "$.parentBicfi", "indirect and addressable participants must name a direct parent participant"));
        };
      };
    };
    if (input.supportedMessageFamilies.size() == 0) {
      issues := addIssue(issues, ISO.publicIssue("business", "PARTICIPANT-MESSAGE-FAMILIES", "$.supportedMessageFamilies", "participant reachability must name at least one supported message family"));
    };
    for (family in input.supportedMessageFamilies.vals()) {
      if (family == "") {
        issues := addIssue(issues, ISO.publicIssue("business", "PARTICIPANT-MESSAGE-FAMILY", "$.supportedMessageFamilies", "participant message families must not be empty"));
      };
    };
    ISO.reportFromIssues(guideline, "participant.directory", "participant-directory-v1", issues);
  };

  func validParticipantAccessTier(accessTier : Text) : Bool {
    accessTier == "direct" or accessTier == "indirect" or accessTier == "addressable";
  };

  func participantDirectoryEntryFromInput(input : ParticipantDirectoryInput, updatedAt : Int) : ParticipantDirectoryEntry {
    {
      bicfi = input.bicfi;
      lei = input.lei;
      displayName = input.displayName;
      country = input.country;
      accessTier = input.accessTier;
      parentBicfi = input.parentBicfi;
      reachable = input.reachable;
      active = input.active;
      settlementAccountConfigured = participantHasSettlementAccount(input.bicfi);
      supportedMessageFamilies = input.supportedMessageFamilies;
      updatedAt;
      notes = input.notes;
    };
  };

  func participantDirectoryEntryView(entry : ParticipantDirectoryEntry) : ParticipantDirectoryEntry {
    { entry with settlementAccountConfigured = participantHasSettlementAccount(entry.bicfi) };
  };

  func participantHasSettlementAccount(bicfi : Text) : Bool {
    switch (Map.get(settlementParticipantAccounts, Text.compare, bicfi)) {
      case (?_) true;
      case null false;
    };
  };

  func participantDirectoryEntries() : [ParticipantDirectoryEntry] {
    Array.sort<ParticipantDirectoryEntry>(
      Array.map<ParticipantDirectoryEntry, ParticipantDirectoryEntry>(
        Iter.toArray(Map.values(participantDirectory)),
        participantDirectoryEntryView,
      ),
      func(a, b) { Text.compare(a.bicfi, b.bicfi) },
    );
  };

  func demoParticipantDirectoryInputs() : [ParticipantDirectoryInput] {
    [
      {
        bicfi = "EGBKEGCX";
        lei = ?"5493001KJTIIGC8Y1R12";
        displayName = "Example Egypt Direct Bank";
        country = "EG";
        accessTier = "direct";
        parentBicfi = null;
        reachable = true;
        active = true;
        supportedMessageFamilies = ["pain.001", "pacs.008", "pacs.002", "camt.053"];
        notes = "C7 direct participant fixture";
      },
      {
        bicfi = "EXBKEGCX";
        lei = ?"213800D1EI4B9WTWWD28";
        displayName = "Example Egypt Addressable Bank";
        country = "EG";
        accessTier = "addressable";
        parentBicfi = ?"EGBKEGCX";
        reachable = true;
        active = true;
        supportedMessageFamilies = ["pain.001", "pacs.008", "pacs.002", "camt.053"];
        notes = "C7 addressable participant fixture";
      },
      {
        bicfi = "DEUTDEFF";
        lei = ?"529900T8BM49AURSDO55";
        displayName = "Deutsche Example Bank";
        country = "DE";
        accessTier = "direct";
        parentBicfi = null;
        reachable = true;
        active = true;
        supportedMessageFamilies = ["pain.008", "pacs.003", "admi.002"];
        notes = "Direct-debit creditor bank fixture";
      },
      {
        bicfi = "BNPAFRPP";
        lei = null;
        displayName = "BNP Example Bank";
        country = "FR";
        accessTier = "indirect";
        parentBicfi = ?"DEUTDEFF";
        reachable = true;
        active = true;
        supportedMessageFamilies = ["pain.008", "pacs.003", "admi.002"];
        notes = "Direct-debit debtor bank fixture";
      },
    ];
  };

  func seedDemoParticipantDirectoryCore(updatedAt : Int) {
    for (input in demoParticipantDirectoryInputs().vals()) {
      Map.add(participantDirectory, Text.compare, input.bicfi, participantDirectoryEntryFromInput(input, updatedAt));
    };
  };

  func correlateDirectDebitWorkflowWithGuideline(caller : Principal, doc : DirectDebitMessage, rawXml : ?Blob, g : UsageGuideline) : WorkflowCorrelationResult {
    let report = ISO.validateDirectDebit(g, doc, rawXml);
    let audit = auditGenericMessage(caller, doc.messageKind, doc.messageVersion, doc.messageId, optText(doc.uetr), rawXml, report);
    if (not report.ok) return { ok = false; workflow = null; audit; report };
    let workflow = storeWorkflowEvent(
      directDebitWorkflowId(doc),
      "direct-debit",
      doc.mandateId,
      [doc.creditorAgent.bicfi, doc.debtorAgent.bicfi],
      doc.messageKind,
      doc.messageId,
      null,
      doc.uetr,
      directDebitWorkflowStatus(doc),
      directDebitWorkflowDetail(doc),
      caller,
      ?audit.id,
      audit.at,
    );
    { ok = true; workflow = ?workflow; audit; report };
  };

  func correlateRequestToPayWorkflowWithGuideline(caller : Principal, doc : RequestToPayMessage, g : UsageGuideline) : WorkflowCorrelationResult {
    let report = ISO.validateRequestToPay(g, doc);
    let audit = auditGenericMessage(caller, doc.messageKind, doc.messageVersion, doc.messageId, "", null, report);
    if (not report.ok) return { ok = false; workflow = null; audit; report };
    let workflow = storeWorkflowEvent(
      requestToPayWorkflowId(doc),
      "request-to-pay",
      requestToPayPrimaryReference(doc),
      [doc.creditorAgent.bicfi, doc.debtorAgent.bicfi],
      doc.messageKind,
      doc.messageId,
      doc.originalRequestId,
      null,
      requestToPayWorkflowStatus(doc),
      requestToPayWorkflowDetail(doc),
      caller,
      ?audit.id,
      audit.at,
    );
    { ok = true; workflow = ?workflow; audit; report };
  };

  func correlateInvestigationWorkflowWithGuideline(caller : Principal, doc : InvestigationMessage, g : UsageGuideline) : WorkflowCorrelationResult {
    let report = ISO.validateInvestigation(g, doc);
    let audit = auditGenericMessage(caller, doc.messageKind, doc.messageVersion, doc.messageId, optText(doc.originalUetr), null, report);
    if (not report.ok) return { ok = false; workflow = null; audit; report };
    let workflow = storeWorkflowEvent(
      investigationWorkflowId(doc),
      if (doc.messageKind == "camt.110" or doc.messageKind == "camt.111") "case-management" else "investigation",
      investigationPrimaryReference(doc),
      [],
      doc.messageKind,
      doc.messageId,
      ?doc.originalMessageId,
      doc.originalUetr,
      investigationWorkflowStatus(doc),
      investigationWorkflowDetail(doc),
      caller,
      ?audit.id,
      audit.at,
    );
    { ok = true; workflow = ?workflow; audit; report };
  };

  func correlateAdministrativeWorkflowWithGuideline(caller : Principal, doc : AdministrativeMessage, g : UsageGuideline) : WorkflowCorrelationResult {
    let report = ISO.validateAdministrativeMessage(g, doc);
    let audit = auditGenericMessage(caller, doc.messageKind, doc.messageVersion, doc.messageId, optText(doc.relatedUetr), null, report);
    if (not report.ok) return { ok = false; workflow = null; audit; report };
    let workflow = storeWorkflowEvent(
      administrativeWorkflowId(doc),
      "administrative",
      administrativePrimaryReference(doc),
      [],
      doc.messageKind,
      doc.messageId,
      doc.relatedMessageId,
      doc.relatedUetr,
      administrativeWorkflowStatus(doc),
      administrativeWorkflowDetail(doc),
      caller,
      ?audit.id,
      audit.at,
    );
    { ok = true; workflow = ?workflow; audit; report };
  };

  func storeWorkflowEvent(
    id : Text,
    kind : Text,
    primaryReference : Text,
    participants : [Text],
    messageKind : Text,
    messageId : Text,
    relatedMessageId : ?Text,
    uetr : ?Text,
    status : Text,
    detail : Text,
    caller : Principal,
    auditId : ?Nat,
    at : Int,
  ) : WorkflowState {
    let current = Map.get(workflowStates, Text.compare, id);
    let next = workflowStateAfterEvent(current, id, kind, primaryReference, participants, messageKind, messageId, relatedMessageId, uetr, status, detail, caller, auditId, at);
    Map.add(workflowStates, Text.compare, id, next);
    Map.add(workflowByMessageId, Text.compare, messageId, id);
    switch (uetr) {
      case (?value) if (value != "") Map.add(workflowByUetr, Text.compare, value, id);
      case _ {};
    };
    next;
  };

  func workflowStateAfterEvent(
    current : ?WorkflowState,
    id : Text,
    kind : Text,
    primaryReference : Text,
    participants : [Text],
    messageKind : Text,
    messageId : Text,
    relatedMessageId : ?Text,
    uetr : ?Text,
    status : Text,
    detail : Text,
    caller : Principal,
    auditId : ?Nat,
    at : Int,
  ) : WorkflowState {
    let base = switch (current) {
      case (?wf) wf;
      case null {
        {
          id;
          kind;
          primaryReference;
          status;
          participants = [];
          messageIds = [];
          uetrs = [];
          startedAt = at;
          updatedAt = at;
          eventCount = 0;
          events = [];
        };
      };
    };
    let nextUetrs = switch (uetr) {
      case (?value) {
        if (value == "") base.uetrs else addUniqueText(base.uetrs, value);
      };
      case _ base.uetrs;
    };
    let event : WorkflowEvent = {
      at;
      by = caller;
      messageKind;
      messageId;
      relatedMessageId;
      uetr;
      status;
      detail;
      auditId;
    };
    {
      base with
      status;
      participants = addUniqueTexts(base.participants, participants);
      messageIds = addUniqueText(base.messageIds, messageId);
      uetrs = nextUetrs;
      updatedAt = at;
      eventCount = base.eventCount + 1;
      events = Array.concat<WorkflowEvent>(base.events, [event]);
    };
  };

  func directDebitWorkflowId(doc : DirectDebitMessage) : Text {
    "dd:" # doc.mandateId;
  };

  func requestToPayWorkflowId(doc : RequestToPayMessage) : Text {
    "rtp:" # requestToPayPrimaryReference(doc);
  };

  func requestToPayPrimaryReference(doc : RequestToPayMessage) : Text {
    switch (doc.originalRequestId) {
      case (?id) id;
      case null doc.requestId;
    };
  };

  func investigationWorkflowId(doc : InvestigationMessage) : Text {
    switch (Map.get(workflowByMessageId, Text.compare, doc.originalMessageId)) {
      case (?id) return id;
      case null {};
    };
    switch (doc.originalUetr) {
      case (?uetr) {
        switch (Map.get(workflowByUetr, Text.compare, uetr)) {
          case (?id) return id;
          case null {};
        };
      };
      case null {};
    };
    if (doc.messageKind == "camt.110") {
      "case:" # doc.assignmentId;
    } else if (doc.messageKind == "camt.111") {
      "case:" # doc.originalMessageId;
    } else {
      "investigation:" # doc.originalMessageId;
    };
  };

  func investigationPrimaryReference(doc : InvestigationMessage) : Text {
    if (doc.messageKind == "camt.110") doc.assignmentId else doc.originalMessageId;
  };

  func administrativeWorkflowId(doc : AdministrativeMessage) : Text {
    switch (doc.relatedMessageId) {
      case (?messageId) {
        switch (Map.get(workflowByMessageId, Text.compare, messageId)) {
          case (?id) return id;
          case null {};
        };
      };
      case null {};
    };
    switch (doc.relatedUetr) {
      case (?uetr) {
        switch (Map.get(workflowByUetr, Text.compare, uetr)) {
          case (?id) return id;
          case null {};
        };
      };
      case null {};
    };
    "admi:" # administrativePrimaryReference(doc);
  };

  func administrativePrimaryReference(doc : AdministrativeMessage) : Text {
    switch (doc.relatedMessageId) {
      case (?messageId) messageId;
      case null doc.messageId;
    };
  };

  func directDebitWorkflowStatus(doc : DirectDebitMessage) : Text {
    if (doc.messageKind == "pain.008") "mandate-presented" else "collection-presented";
  };

  func directDebitWorkflowDetail(doc : DirectDebitMessage) : Text {
    if (doc.messageKind == "pain.008") {
      "direct-debit mandate and customer collection instruction received";
    } else {
      "interbank direct-debit collection correlated to mandate " # doc.mandateId;
    };
  };

  func requestToPayWorkflowStatus(doc : RequestToPayMessage) : Text {
    if (doc.messageKind == "pain.013") {
      "requested";
    } else if (doc.messageKind == "camt.055") {
      "cancelled";
    } else {
      switch (doc.status) {
        case (?"ACTC") "accepted";
        case (?"RJCT") "rejected";
        case (?"PDNG") "pending";
        case (?s) s;
        case null "responded";
      };
    };
  };

  func requestToPayWorkflowDetail(doc : RequestToPayMessage) : Text {
    if (doc.messageKind == "pain.013") {
      "request-to-pay presentment received";
    } else if (doc.messageKind == "camt.055") {
      "request-to-pay cancellation correlated";
    } else {
      "request-to-pay response correlated to " # requestToPayPrimaryReference(doc);
    };
  };

  func investigationWorkflowStatus(doc : InvestigationMessage) : Text {
    if (doc.messageKind == "camt.110") {
      "case-open";
    } else if (doc.messageKind == "camt.111") {
      "case-responded";
    } else {
      doc.reasonCode;
    };
  };

  func investigationWorkflowDetail(doc : InvestigationMessage) : Text {
    if (doc.messageKind == "camt.110" or doc.messageKind == "camt.111") {
      "case-management message correlated to " # doc.originalMessageId;
    } else {
      "investigation message correlated to " # doc.originalMessageId;
    };
  };

  func administrativeWorkflowStatus(doc : AdministrativeMessage) : Text {
    if (doc.status == "ACK") {
      "acknowledged";
    } else if (doc.status == "RJCT") {
      "rejected";
    } else {
      doc.status;
    };
  };

  func administrativeWorkflowDetail(doc : AdministrativeMessage) : Text {
    "administrative " # doc.messageKind # " " # doc.status # " correlated";
  };

  func workflowStatesOrdered() : [WorkflowState] {
    Array.sort<WorkflowState>(
      Iter.toArray(Map.values(workflowStates)),
      func(a, b) { Text.compare(a.id, b.id) },
    );
  };

  func verifyParticipantWorkflowOracleReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    for (input in demoParticipantDirectoryInputs().vals()) {
      let report = validateParticipantDirectoryInput(input);
      for (issue in report.issues.vals()) issues := addIssue(issues, issue);
    };
    if (validParticipantAccessTier("sponsored")) {
      issues := addIssue(issues, oracleIssue("PARTICIPANT-TIER-CLOSED", "$.participantDirectory.accessTier", "participant access tier vocabulary must reject unsupported values"));
    };

    let caller = Principal.fromText("aaaaa-aa");
    let ddPain = ISO.demoPain008();
    let ddPacs = ISO.demoPacs003();
    let ddAdmin = ISO.demoAdmi002Reject();
    let ddId = directDebitWorkflowId(ddPain);
    var ddWorkflow = workflowStateAfterEvent(null, ddId, "direct-debit", ddPain.mandateId, [ddPain.creditorAgent.bicfi, ddPain.debtorAgent.bicfi], ddPain.messageKind, ddPain.messageId, null, ddPain.uetr, directDebitWorkflowStatus(ddPain), directDebitWorkflowDetail(ddPain), caller, null, 0);
    ddWorkflow := workflowStateAfterEvent(?ddWorkflow, ddId, "direct-debit", ddPacs.mandateId, [ddPacs.creditorAgent.bicfi, ddPacs.debtorAgent.bicfi], ddPacs.messageKind, ddPacs.messageId, null, ddPacs.uetr, directDebitWorkflowStatus(ddPacs), directDebitWorkflowDetail(ddPacs), caller, null, 1);
    ddWorkflow := workflowStateAfterEvent(?ddWorkflow, ddId, "direct-debit", ddPacs.mandateId, [], ddAdmin.messageKind, ddAdmin.messageId, ddAdmin.relatedMessageId, ddAdmin.relatedUetr, administrativeWorkflowStatus(ddAdmin), administrativeWorkflowDetail(ddAdmin), caller, null, 2);
    if (ddWorkflow.eventCount != 3 or ddWorkflow.id != ddId) {
      issues := addIssue(issues, oracleIssue("WORKFLOW-DD-EVENT-COUNT", "$.workflow.directDebit", "direct-debit demo must correlate mandate, collection, and administrative return/reject into one workflow"));
    };
    if (not textArrayContains(ddWorkflow.messageIds, ddPain.messageId) or not textArrayContains(ddWorkflow.messageIds, ddPacs.messageId) or not textArrayContains(ddWorkflow.messageIds, ddAdmin.messageId)) {
      issues := addIssue(issues, oracleIssue("WORKFLOW-DD-MESSAGE-INDEX", "$.workflow.directDebit.messageIds", "direct-debit workflow must retain all correlated message ids"));
    };

    let rfp = ISO.demoPain013();
    let rfpResponse = ISO.demoPain014Accepted();
    let rfpId = requestToPayWorkflowId(rfp);
    var rfpWorkflow = workflowStateAfterEvent(null, rfpId, "request-to-pay", rfp.requestId, [rfp.creditorAgent.bicfi, rfp.debtorAgent.bicfi], rfp.messageKind, rfp.messageId, rfp.originalRequestId, null, requestToPayWorkflowStatus(rfp), requestToPayWorkflowDetail(rfp), caller, null, 0);
    rfpWorkflow := workflowStateAfterEvent(?rfpWorkflow, rfpId, "request-to-pay", rfp.requestId, [rfpResponse.creditorAgent.bicfi, rfpResponse.debtorAgent.bicfi], rfpResponse.messageKind, rfpResponse.messageId, rfpResponse.originalRequestId, null, requestToPayWorkflowStatus(rfpResponse), requestToPayWorkflowDetail(rfpResponse), caller, null, 1);
    if (rfpWorkflow.eventCount != 2 or rfpWorkflow.id != rfpId or rfpWorkflow.status != "accepted") {
      issues := addIssue(issues, oracleIssue("WORKFLOW-RFP-RESPONSE", "$.workflow.requestToPay", "RFP demo must correlate pain.013 and pain.014 into one accepted workflow state"));
    };

    let caseRequest = ISO.demoCamt110();
    let caseResponse = ISO.demoCamt111();
    let caseId = "case:" # caseRequest.assignmentId;
    var caseWorkflow = workflowStateAfterEvent(null, caseId, "case-management", caseRequest.assignmentId, [], caseRequest.messageKind, caseRequest.messageId, ?caseRequest.originalMessageId, caseRequest.originalUetr, investigationWorkflowStatus(caseRequest), investigationWorkflowDetail(caseRequest), caller, null, 0);
    caseWorkflow := workflowStateAfterEvent(?caseWorkflow, caseId, "case-management", caseRequest.assignmentId, [], caseResponse.messageKind, caseResponse.messageId, ?caseResponse.originalMessageId, caseResponse.originalUetr, investigationWorkflowStatus(caseResponse), investigationWorkflowDetail(caseResponse), caller, null, 1);
    if (caseWorkflow.eventCount != 2 or caseWorkflow.status != "case-responded") {
      issues := addIssue(issues, oracleIssue("WORKFLOW-CASE-RESPONSE", "$.workflow.caseManagement", "case-management demo must correlate camt.110 and camt.111 into one workflow state"));
    };

    for (entry in Map.values(participantDirectory)) {
      let input : ParticipantDirectoryInput = {
        bicfi = entry.bicfi;
        lei = entry.lei;
        displayName = entry.displayName;
        country = entry.country;
        accessTier = entry.accessTier;
        parentBicfi = entry.parentBicfi;
        reachable = entry.reachable;
        active = entry.active;
        supportedMessageFamilies = entry.supportedMessageFamilies;
        notes = entry.notes;
      };
      let report = validateParticipantDirectoryInput(input);
      for (issue in report.issues.vals()) issues := addIssue(issues, issue);
    };
    for (workflow in Map.values(workflowStates)) {
      if (workflow.eventCount != workflow.events.size()) {
        issues := addIssue(issues, oracleIssue("WORKFLOW-EVENT-COUNT", "$.workflowStates." # workflow.id # ".eventCount", "workflow eventCount must equal retained events"));
      };
      if (workflow.messageIds.size() == 0) {
        issues := addIssue(issues, oracleIssue("WORKFLOW-MESSAGE-ID", "$.workflowStates." # workflow.id # ".messageIds", "workflow must retain at least one message id"));
      };
      for (messageId in workflow.messageIds.vals()) {
        switch (Map.get(workflowByMessageId, Text.compare, messageId)) {
          case (?id) {
            if (id != workflow.id) {
              issues := addIssue(issues, oracleIssue("WORKFLOW-MESSAGE-INDEX", "$.workflowByMessageId." # messageId, "message id index must point back to the owning workflow"));
            };
          };
          case null {
            issues := addIssue(issues, oracleIssue("WORKFLOW-MESSAGE-INDEX-MISSING", "$.workflowByMessageId." # messageId, "message id index must contain each workflow message id"));
          };
        };
      };
      for (uetr in workflow.uetrs.vals()) {
        switch (Map.get(workflowByUetr, Text.compare, uetr)) {
          case (?id) {
            if (id != workflow.id) {
              issues := addIssue(issues, oracleIssue("WORKFLOW-UETR-INDEX", "$.workflowByUetr." # uetr, "UETR index must point back to the owning workflow"));
            };
          };
          case null {
            issues := addIssue(issues, oracleIssue("WORKFLOW-UETR-INDEX-MISSING", "$.workflowByUetr." # uetr, "UETR index must contain each workflow UETR"));
          };
        };
      };
    };
    oracleReport("participant.workflow", issues);
  };

  func pfmiAssessments() : [PfmiPrincipleAssessment] {
    [
      pfmi(1, "Legal basis", "applicable", "institutional", "operator rulebook and legal designation", false, null, [], ["docs/PFMI_SELF_ASSESSMENT.md"], ["legal finality opinion and rulebook are external"]),
      pfmi(2, "Governance", "applicable", "institutional", "operator governance", false, null, [], ["docs/PFMI_SELF_ASSESSMENT.md"], ["board, risk, and accountability evidence is external"]),
      pfmi(3, "Framework for comprehensive risk management", "applicable", "hybrid", "hub oracle plus operator risk framework", true, ?"pfmi.self.assessment", ["verifyOracleReadiness", "verifyPfmiSelfAssessment"], ["oraclePhaseRegistry", "checkpointMap"], ["enterprise risk framework and model-risk signoff remain institutional"]),
      pfmi(4, "Credit risk", "applicable", "hybrid", "settlement limits plus operator credit policy", true, ?"settlement.liquidity.queue", ["checkSettlementLiquidity", "settlementLiquidityPosition"], ["setSettlementDebitLimit", "dispatchOrQueuePacs008"], ["collateralized credit exposure policy is external"]),
      pfmi(5, "Collateral", "applicable", "institutional", "operator collateral policy", false, null, [], ["docs/PFMI_SELF_ASSESSMENT.md"], ["no native collateral eligibility/haircut engine is bundled"]),
      pfmi(6, "Margin", "not-applicable", "not-applicable", "not a CCP margining system", false, null, [], ["docs/PFMI_SELF_ASSESSMENT.md"], []),
      pfmi(7, "Liquidity risk", "applicable", "built", "settlement liquidity queue", true, ?"settlement.liquidity.queue", ["checkSettlementLiquidity", "listSettlementQueue", "secondaryIndexHealth"], ["setSettlementDebitLimit", "resolveQueuedSettlementOffset"], ["real RTGS intraday liquidity facilities are external"]),
      pfmi(8, "Settlement finality", "applicable", "native-plus-built", "IC finalization plus hub lifecycle", true, ?"payment.lifecycle", ["verifyPaymentPhases", "verifyOracleReadiness"], ["acknowledgePacs002", "auditTip"], ["legal finality memorandum remains institutional"]),
      pfmi(9, "Money settlements", "applicable", "built", "ICRC-ME settlement asset", true, ?"certified.disclosure", ["verifyCertifiedDisclosure", "runEndOfDay"], ["setSettlementLedger", "refreshCertifiedSettlementBalances"], ["production central-bank money or commercial-bank money policy is external"]),
      pfmi(10, "Physical deliveries", "not-applicable", "not-applicable", "payment-message hub has no physical delivery leg", false, null, [], ["docs/PFMI_SELF_ASSESSMENT.md"], []),
      pfmi(11, "Central securities depositories", "not-applicable", "not-applicable", "not a CSD", false, null, [], ["docs/PFMI_SELF_ASSESSMENT.md"], []),
      pfmi(12, "Exchange-of-value settlement systems", "not-applicable", "not-applicable", "no DvP/PvP exchange-of-value engine", false, null, [], ["docs/PFMI_SELF_ASSESSMENT.md"], []),
      pfmi(13, "Participant-default rules and procedures", "applicable", "hybrid", "liquidity controls plus workflow directory", true, ?"participant.workflow", ["verifyParticipantWorkflowCorrelation", "checkSettlementLiquidity"], ["upsertParticipantDirectoryEntry", "correlateAdministrativeWorkflow"], ["default waterfall, loss allocation, and legal notices remain rulebook items"]),
      pfmi(14, "Segregation and portability", "not-applicable", "not-applicable", "not a CCP with client margin portability", false, null, [], ["docs/PFMI_SELF_ASSESSMENT.md"], []),
      pfmi(15, "General business risk", "applicable", "institutional", "operator finance and continuity plan", false, null, [], ["docs/PFMI_SELF_ASSESSMENT.md"], ["capital planning and wind-down evidence are external"]),
      pfmi(16, "Custody and investment risks", "applicable", "external", "settlement-asset custody and treasury policy", false, null, [], ["docs/PFMI_SELF_ASSESSMENT.md"], ["custody/investment controls depend on the deployed settlement asset and operator treasury"]),
      pfmi(17, "Operational risk", "applicable", "native-plus-built", "IC replicated execution plus connector controls", true, ?"connector.envelope", ["verifyOracleReadiness", "secondaryIndexHealth"], ["submitTransportEnvelope", "useExternalSignatureAuth"], ["disaster recovery runbooks and incident response exercises remain operator evidence"]),
      pfmi(18, "Access and participation requirements", "applicable", "built", "participant directory", true, ?"participant.workflow", ["verifyParticipantWorkflowCorrelation"], ["upsertParticipantDirectoryEntry", "listParticipantDirectory"], ["official CBE/EBC participant directory imports remain external"]),
      pfmi(19, "Tiered participation arrangements", "applicable", "built", "access tier and parent BIC model", true, ?"participant.workflow", ["verifyParticipantWorkflowCorrelation"], ["upsertParticipantDirectoryEntry", "seedDemoParticipantDirectory"], ["monitoring thresholds for indirect participants remain operator policy"]),
      pfmi(20, "FMI links", "applicable", "external", "connector and settlement-asset links", false, null, [], ["integrationProfilePacks", "setSettlementLedger"], ["bilateral/link agreements and link-risk assessments are external"]),
      pfmi(21, "Efficiency and effectiveness", "applicable", "built", "operating-day and profile controls", true, ?"settlement.operating-day", ["operatingDayStatus", "runEndOfDay", "verifyOracleReadiness"], ["configureOperatingDay", "listGuidelineProfiles"], ["service-level targets and participant feedback loop are external"]),
      pfmi(22, "Communication procedures and standards", "applicable", "built", "ISO 20022 compact XML and profile packs", true, ?"xml.codec", ["verifyXmlCodecOracleReport", "xmlProfileFixtureRegistry"], ["decodePain001Xml", "integrationProfilePacks"], ["full XSD/profile conformance runner remains external"]),
      pfmi(23, "Disclosure of rules and key procedures", "applicable", "built", "certified disclosure plus self-assessment", true, ?"pfmi.self.assessment", ["verifyCertifiedDisclosure", "verifyPfmiSelfAssessment"], ["certifiedAuditDisclosure", "pfmiSelfAssessment"], ["external publication and disclosure framework signoff remain operator tasks"]),
      pfmi(24, "Disclosure of market data by trade repositories", "not-applicable", "not-applicable", "not a trade repository", false, null, [], ["docs/PFMI_SELF_ASSESSMENT.md"], []),
    ];
  };

  func pfmi(
    principle : Nat,
    title : Text,
    applicability : Text,
    status : Text,
    locus : Text,
    codeEnforceable : Bool,
    oraclePhase : ?Text,
    verifierSurface : [Text],
    evidence : [Text],
    residualGaps : [Text],
  ) : PfmiPrincipleAssessment {
    {
      principle;
      title;
      applicability;
      status;
      locus;
      codeEnforceable;
      oraclePhase;
      verifierSurface;
      evidence;
      residualGaps;
    };
  };

  func verifyPfmiSelfAssessmentReport() : ValidationReport {
    var issues : [ValidationIssue] = [];
    let assessments = pfmiAssessments();
    if (assessments.size() != 24) {
      issues := addIssue(issues, oracleIssue("PFMI-PRINCIPLE-COUNT", "$.pfmiSelfAssessment", "PFMI self-assessment must enumerate all 24 principles"));
    };
    var p = 1;
    while (p <= 24) {
      if (not hasPfmiPrinciple(assessments, p)) {
        issues := addIssue(issues, oracleIssue("PFMI-PRINCIPLE-MISSING", "$.pfmiSelfAssessment[" # Nat.toText(p) # "]", "PFMI principle row is missing"));
      };
      p += 1;
    };
    var codeRows = 0;
    for (row in assessments.vals()) {
      if (row.title == "" or row.status == "" or row.locus == "" or row.applicability == "") {
        issues := addIssue(issues, oracleIssue("PFMI-ROW-FIELDS", "$.pfmiSelfAssessment[" # Nat.toText(row.principle) # "]", "PFMI row must have title, status, applicability, and locus"));
      };
      if (row.codeEnforceable) {
        codeRows += 1;
        if (row.verifierSurface.size() == 0) {
          issues := addIssue(issues, oracleIssue("PFMI-VERIFIER-SURFACE", "$.pfmiSelfAssessment[" # Nat.toText(row.principle) # "].verifierSurface", "code-enforceable PFMI row must name at least one verifier"));
        };
        switch (row.oraclePhase) {
          case (?phase) {
            if (phase == "") {
              issues := addIssue(issues, oracleIssue("PFMI-ORACLE-PHASE", "$.pfmiSelfAssessment[" # Nat.toText(row.principle) # "].oraclePhase", "code-enforceable PFMI row must name an oracle phase"));
            };
          };
          case null {
            issues := addIssue(issues, oracleIssue("PFMI-ORACLE-PHASE-MISSING", "$.pfmiSelfAssessment[" # Nat.toText(row.principle) # "].oraclePhase", "code-enforceable PFMI row must name an oracle phase"));
          };
        };
      } else if (row.applicability == "applicable" and row.residualGaps.size() == 0) {
        issues := addIssue(issues, oracleIssue("PFMI-RESIDUAL-GAP", "$.pfmiSelfAssessment[" # Nat.toText(row.principle) # "].residualGaps", "non-code applicable PFMI row must name residual institutional or external evidence"));
      };
    };
    if (codeRows < 10) {
      issues := addIssue(issues, oracleIssue("PFMI-CODE-COVERAGE", "$.pfmiSelfAssessment", "PFMI self-assessment should identify code-enforceable coverage for the built hub controls"));
    };
    let workflowReport = verifyParticipantWorkflowOracleReport();
    if (not workflowReport.ok) {
      issues := addIssue(issues, oracleIssue("PFMI-C7-WORKFLOW", "$.participant.workflow", "PFMI access/tiered-participation rows require the participant workflow oracle to pass"));
    };
    oracleReport("pfmi.self.assessment", issues);
  };

  func hasPfmiPrinciple(rows : [PfmiPrincipleAssessment], principle : Nat) : Bool {
    for (row in rows.vals()) {
      if (row.principle == principle) return true;
    };
    false;
  };

  func auditPacs008Core(caller : Principal, doc : Pacs008CreditTransfer, rawXml : ?Blob, report : ValidationReport) : AuditRecord {
    let rec = makeAuditRecord(caller, doc, rawXml, report);
    Map.add(audits, Nat.compare, rec.id, rec);
    auditMmr := AuditMMR.append(auditMmr, rec.recordHash);
    ignore commitCertifiedDisclosure(rec.at);
    rec;
  };

  func auditGenericMessage(
    caller : Principal,
    messageKind : Text,
    messageVersion : Text,
    businessMessageId : Text,
    uetr : Text,
    rawXml : ?Blob,
    report : ValidationReport,
  ) : AuditRecord {
    let rec = makeGenericAuditRecord(caller, messageKind, messageVersion, businessMessageId, uetr, rawXml, report);
    Map.add(audits, Nat.compare, rec.id, rec);
    auditMmr := AuditMMR.append(auditMmr, rec.recordHash);
    ignore commitCertifiedDisclosure(rec.at);
    rec;
  };

  func makeAuditRecord(caller : Principal, doc : Pacs008CreditTransfer, rawXml : ?Blob, report : ValidationReport) : AuditRecord {
    let id = nextAuditId;
    nextAuditId += 1;
    let parentHash = lastAuditHash;
    let draft : AuditRecord = {
      id;
      at = Time.now();
      caller;
      parentHash;
      recordHash = "" : Blob;
      rawXmlHash = switch (rawXml) { case (?xml) ?hashBlob(xml); case null null };
      messageKind = report.messageKind;
      messageVersion = report.messageVersion;
      guidelineId = report.guidelineId;
      businessMessageId = doc.messageId;
      uetr = switch (doc.uetr) { case (?u) u; case null "" };
      ok = report.ok;
      issueCount = report.issueCount;
      report;
    };
    let hash = computeAuditHash(draft);
    let rec = { draft with recordHash = hash };
    lastAuditHash := ?hash;
    rec;
  };

  func makeGenericAuditRecord(
    caller : Principal,
    messageKind : Text,
    messageVersion : Text,
    businessMessageId : Text,
    uetr : Text,
    rawXml : ?Blob,
    report : ValidationReport,
  ) : AuditRecord {
    let id = nextAuditId;
    nextAuditId += 1;
    let parentHash = lastAuditHash;
    let draft : AuditRecord = {
      id;
      at = Time.now();
      caller;
      parentHash;
      recordHash = "" : Blob;
      rawXmlHash = switch (rawXml) { case (?xml) ?hashBlob(xml); case null null };
      messageKind;
      messageVersion;
      guidelineId = report.guidelineId;
      businessMessageId;
      uetr;
      ok = report.ok;
      issueCount = report.issueCount;
      report;
    };
    let hash = computeAuditHash(draft);
    let rec = { draft with recordHash = hash };
    lastAuditHash := ?hash;
    rec;
  };

  func auditView(r : AuditRecord) : AuditView {
    {
      id = r.id;
      at = r.at;
      caller = r.caller;
      messageKind = r.messageKind;
      messageVersion = r.messageVersion;
      guidelineId = r.guidelineId;
      businessMessageId = r.businessMessageId;
      uetr = r.uetr;
      ok = r.ok;
      issueCount = r.issueCount;
      rawXmlHash = r.rawXmlHash;
    };
  };

  func paymentView(p : HubPayment) : PaymentView {
    let settlementLedger = switch (p.settlement) {
      case (?s) ?s.ledgerCanister;
      case null null;
    };
    let settlementBlockIndex = switch (p.settlement) {
      case (?s) ?s.ledgerBlockIndex;
      case null null;
    };
    {
      id = p.id;
      createdAt = p.createdAt;
      updatedAt = p.updatedAt;
      submittedBy = p.submittedBy;
      messageId = p.messageId;
      uetr = p.uetr;
      amount = p.pacs008.instructedAmount;
      debtorAgent = p.pacs008.debtorAgent.bicfi;
      creditorAgent = p.pacs008.creditorAgent.bicfi;
      status = p.status;
      ok = p.validationReport.ok;
      issueCount = p.validationReport.issueCount;
      auditId = p.auditId;
      duplicateSignal = p.duplicateSignal;
      settlementLedger;
      settlementBlockIndex;
    };
  };

  func statementEntry(p : HubPayment) : StatementEntry {
    let entryId = switch (p.settlement) {
      case (?s) "ICRC-ME-BLOCK-" # Nat.toText(s.ledgerBlockIndex);
      case null "CAMT-" # Nat.toText(p.id);
    };
    let remittance = switch (p.settlement) {
      case (?s) Array.concat<Text>(
        p.pacs008.remittanceInformation.unstructured,
        ["settlement-ledger=" # Principal.toText(s.ledgerCanister), "settlement-block=" # Nat.toText(s.ledgerBlockIndex)],
      );
      case null p.pacs008.remittanceInformation.unstructured;
    };
    {
      entryId;
      paymentId = p.id;
      uetr = p.uetr;
      accountIban = p.pacs008.creditorAccount.iban;
      accountOtherId = p.pacs008.creditorAccount.otherId;
      amount = p.pacs008.instructedAmount;
      creditDebit = "CRDT";
      status = p.status;
      bookedAt = p.updatedAt;
      counterpartyName = p.pacs008.debtor.name;
      remittance;
    };
  };

  func validateOperatingDayPhase(phase : Text) {
    if (
      phase != "closed" and
      phase != "start-of-day" and
      phase != "settlement-window" and
      phase != "cutoff" and
      phase != "end-of-day" and
      phase != "reconciled"
    ) {
      Runtime.trap("unsupported operating-day phase");
    };
  };

  func validateOperatingDayConfig(config : OperatingDayConfig) {
    if (Text.size(config.currency) == 0) Runtime.trap("currency required");
    if (Text.size(config.businessDate) == 0) Runtime.trap("businessDate required");
    validateOperatingDayPhase(config.phase);
    if (config.cutoffAt > 0 and config.closesAt > 0 and config.closesAt <= config.cutoffAt) {
      Runtime.trap("closesAt must be after cutoffAt");
    };
  };

  func operatingDayStatusCore(currency : Text, now : Int) : OperatingDayStatus {
    switch (Map.get(operatingDayConfigs, Text.compare, currency)) {
      case null {
        {
          currency;
          businessDate = null;
          phase = "unconfigured";
          now;
          settlementAllowed = true;
          reason = null;
          cutoffAt = null;
          closesAt = null;
        };
      };
      case (?config) {
        let phaseAllowed = config.active and config.phase == "settlement-window";
        let cutoffPassed = config.cutoffAt > 0 and now >= config.cutoffAt;
        let closePassed = config.closesAt > 0 and now >= config.closesAt;
        let allowed = phaseAllowed and not cutoffPassed and not closePassed;
        let reason = if (allowed) {
          null;
        } else if (not config.active) {
          ?("operating day " # config.businessDate # " is not active");
        } else if (config.phase != "settlement-window") {
          ?("operating day phase " # config.phase # " does not allow settlement");
        } else if (cutoffPassed) {
          ?("settlement cutoff passed for " # config.currency # " business date " # config.businessDate);
        } else {
          ?("settlement close passed for " # config.currency # " business date " # config.businessDate);
        };
        {
          currency;
          businessDate = ?config.businessDate;
          phase = config.phase;
          now;
          settlementAllowed = allowed;
          reason;
          cutoffAt = ?config.cutoffAt;
          closesAt = ?config.closesAt;
        };
      };
    };
  };

  func assertOperatingDayAllowsSettlement(currency : Text, now : Int) {
    let status = operatingDayStatusCore(currency, now);
    if (not status.settlementAllowed) {
      switch (status.reason) {
        case (?reason) Runtime.trap(reason);
        case null Runtime.trap("operating day does not allow settlement");
      };
    };
  };

  func requireOperatingDayConfig(currency : Text) : OperatingDayConfig {
    switch (Map.get(operatingDayConfigs, Text.compare, currency)) {
      case (?config) config;
      case null Runtime.trap("operating day not configured for currency " # currency);
    };
  };

  func captureOperatingDayOpeningBalances(capturedAt : Int) : async [OperatingDayOpeningBalance] {
    let ledgerPrincipal = requireSettlementLedgerCanister();
    let ledger : IcrcLedger = actor (Principal.toText(ledgerPrincipal));
    var snapshots : [OperatingDayOpeningBalance] = [];
    for ((bicfi, account) in Map.entries(settlementParticipantAccounts)) {
      let balance = await ledger.icrc1_balance_of(account);
      snapshots := Array.concat<OperatingDayOpeningBalance>(snapshots, [{
        bicfi;
        account;
        balance;
        capturedAt;
      }]);
    };
    snapshots;
  };

  func endOfDayPayments(config : OperatingDayConfig, toTimeExclusive : Int) : [HubPayment] {
    var out : [HubPayment] = [];
    for (p in Map.values(payments)) {
      switch (p.settlement) {
        case (?s) {
          if (
            p.status == "settled" and
            s.amount.currency == config.currency and
            s.settledAt >= config.openedAt and
            s.settledAt < toTimeExclusive
          ) {
            out := Array.concat<HubPayment>(out, [p]);
          };
        };
        case null {};
      };
    };
    out;
  };

  func settlementGroupKey(s : SettlementRecord) : Text {
    Principal.toText(s.ledgerCanister) # ":" # Nat.toText(s.ledgerBlockIndex) # ":" # s.transferMode;
  };

  func isFirstPaymentInSettlementGroup(p : HubPayment, groupKey : Text) : Bool {
    for (candidate in Map.values(payments)) {
      if (candidate.id < p.id) {
        switch (candidate.settlement) {
          case (?s) {
            if (settlementGroupKey(s) == groupKey) return false;
          };
          case null {};
        };
      };
    };
    true;
  };

  func settlementGroupPayments(config : OperatingDayConfig, toTimeExclusive : Int, groupKey : Text) : [HubPayment] {
    var out : [HubPayment] = [];
    for (p in endOfDayPayments(config, toTimeExclusive).vals()) {
      switch (p.settlement) {
        case (?s) {
          if (settlementGroupKey(s) == groupKey) {
            out := Array.concat<HubPayment>(out, [p]);
          };
        };
        case null {};
      };
    };
    out;
  };

  func operatingDayMovementForBicfi(config : OperatingDayConfig, bicfi : Text, toTimeExclusive : Int) : {
    grossCredit : Nat;
    grossDebit : Nat;
    feeDebit : Nat;
    netDelta : Int;
  } {
    var grossCredit : Nat = 0;
    var grossDebit : Nat = 0;
    var feeDebit : Nat = 0;
    var netDelta : Int = 0;
    let eodPayments = endOfDayPayments(config, toTimeExclusive);
    for (p in eodPayments.vals()) {
      let amount = p.pacs008.instructedAmount.minorUnits;
      if (p.pacs008.creditorAgent.bicfi == bicfi) grossCredit += amount;
      if (p.pacs008.debtorAgent.bicfi == bicfi) grossDebit += amount;
      switch (p.settlement) {
        case (?s) {
          if (s.transferMode == "icrc2_transfer_from_offset_net" or s.transferMode == "offset.zero_net") {
            let groupKey = settlementGroupKey(s);
            if (isFirstPaymentInSettlementGroup(p, groupKey)) {
              var position : Int = 0;
              var groupFee : Nat = 0;
              for (groupPayment in settlementGroupPayments(config, toTimeExclusive, groupKey).vals()) {
                switch (groupPayment.settlement) {
                  case (?groupSettlement) groupFee := groupSettlement.fee;
                  case null {};
                };
                let groupAmount = groupPayment.pacs008.instructedAmount.minorUnits;
                if (groupPayment.pacs008.creditorAgent.bicfi == bicfi) {
                  position += (groupAmount : Int);
                };
                if (groupPayment.pacs008.debtorAgent.bicfi == bicfi) {
                  position -= (groupAmount : Int);
                };
              };
              if (position < 0) {
                netDelta += position - (groupFee : Int);
                feeDebit += groupFee;
              } else {
                netDelta += position;
              };
            };
          } else {
            if (s.debtorAgent == bicfi) {
              netDelta -= (amount + s.fee : Int);
              feeDebit += s.fee;
            };
            if (s.creditorAgent == bicfi) {
              netDelta += (amount : Int);
            };
          };
        };
        case null {};
      };
    };
    { grossCredit; grossDebit; feeDebit; netDelta };
  };

  func runEndOfDayCore(config : OperatingDayConfig, generatedAt : Int) : async EndOfDayStatementRun {
    let snapshots = switch (Map.get(operatingDayOpeningBalances, Text.compare, config.currency)) {
      case (?records) records;
      case null Runtime.trap("opening balances not captured for currency " # config.currency);
    };
    let entries = Array.map<HubPayment, StatementEntry>(endOfDayPayments(config, generatedAt), statementEntry);
    let ledgerPrincipal = requireSettlementLedgerCanister();
    let ledger : IcrcLedger = actor (Principal.toText(ledgerPrincipal));
    var reconciliations : [EndOfDayParticipantReconciliation] = [];
    var issues : [Text] = [];
    for (snapshot in snapshots.vals()) {
      let movement = operatingDayMovementForBicfi(config, snapshot.bicfi, generatedAt);
      let ledgerBalance = await ledger.icrc1_balance_of(snapshot.account);
      let expected = (snapshot.balance : Int) + movement.netDelta;
      var participantIssues : [Text] = [];
      if (expected < 0) {
        participantIssues := Array.concat<Text>(participantIssues, ["expected closing balance is negative"]);
      } else if ((ledgerBalance : Int) != expected) {
        participantIssues := Array.concat<Text>(
          participantIssues,
          [
            "ledger balance " # Nat.toText(ledgerBalance) #
            " does not match expected closing balance " # Int.toText(expected)
          ],
        );
      };
      if (participantIssues.size() > 0) {
        for (issue in participantIssues.vals()) {
          issues := Array.concat<Text>(issues, [snapshot.bicfi # ": " # issue]);
        };
      };
      reconciliations := Array.concat<EndOfDayParticipantReconciliation>(reconciliations, [{
        bicfi = snapshot.bicfi;
        account = snapshot.account;
        openingBalance = snapshot.balance;
        ledgerBalance;
        grossCreditMinorUnits = movement.grossCredit;
        grossDebitMinorUnits = movement.grossDebit;
        feeDebitMinorUnits = movement.feeDebit;
        netLedgerDeltaMinorUnits = movement.netDelta;
        expectedClosingBalance = expected;
        ok = participantIssues.size() == 0;
        issues = participantIssues;
      }]);
    };
    let id = nextEndOfDayRunId;
    nextEndOfDayRunId += 1;
    {
      id;
      currency = config.currency;
      businessDate = config.businessDate;
      generatedAt;
      fromTimeInclusive = config.openedAt;
      toTimeExclusive = generatedAt;
      paymentCount = entries.size();
      entries;
      camt053Xml = Xml.camt053ToXml(entries);
      reconciliations;
      ok = issues.size() == 0;
      issueCount = issues.size();
      issues;
    };
  };

  func settlementConfig() : SettlementLedgerConfig {
    {
      enabled = settlementEnabled;
      ledgerCanister = settlementLedgerCanister;
      fee = settlementFee;
      currency = settlementCurrency;
      transferMode = "icrc2_transfer_from";
    };
  };

  func requireSettlementLedgerCanister() : Principal {
    switch (settlementLedgerCanister) {
      case (?principal) principal;
      case null Runtime.trap("settlement ledger is enabled but no ledger canister is configured");
    }
  };

  func requireSettlementAccount(bicfi : Text) : IcrcAccount {
    switch (Map.get(settlementParticipantAccounts, Text.compare, bicfi)) {
      case (?account) account;
      case null Runtime.trap("missing ICRC-ME settlement account for BIC " # bicfi);
    }
  };

  func liquidityLimitView(bicfi : Text) : SettlementLiquidityLimit {
    let reserved = reservedDebitMinorUnits(bicfi, null);
    switch (Map.get(settlementDebitLimits, Text.compare, bicfi)) {
      case (?limit) {
        {
          bicfi;
          maxDebitMinorUnits = limit;
          reservedDebitMinorUnits = reserved;
          active = true;
        };
      };
      case null {
        {
          bicfi;
          maxDebitMinorUnits = 0;
          reservedDebitMinorUnits = reserved;
          active = false;
        };
      };
    };
  };

  func liquidityPosition(bicfi : Text) : SettlementLiquidityPosition {
    let reserved = reservedDebitMinorUnits(bicfi, null);
    let limit = Map.get(settlementDebitLimits, Text.compare, bicfi);
    {
      bicfi;
      debitLimitMinorUnits = limit;
      reservedDebitMinorUnits = reserved;
      availableDebitMinorUnits = switch (limit) {
        case (?maxDebit) {
          if (maxDebit > reserved) ?(maxDebit - reserved) else ?0;
        };
        case null null;
      };
      queuedPaymentCount = queuedDebitPaymentCount(bicfi, null);
    };
  };

  func liquidityCheckForPayment(p : HubPayment, excludePaymentId : ?Nat) : SettlementLiquidityCheck {
    let bicfi = p.pacs008.debtorAgent.bicfi;
    let requested = p.pacs008.instructedAmount.minorUnits;
    let reserved = reservedDebitMinorUnits(bicfi, excludePaymentId);
    switch (Map.get(settlementDebitLimits, Text.compare, bicfi)) {
      case null {
        {
          ok = true;
          bicfi;
          debitLimitMinorUnits = null;
          reservedDebitMinorUnits = reserved;
          requestedDebitMinorUnits = requested;
          reason = null;
        };
      };
      case (?limit) {
        let required = reserved + requested;
        let ok = required <= limit;
        {
          ok;
          bicfi;
          debitLimitMinorUnits = ?limit;
          reservedDebitMinorUnits = reserved;
          requestedDebitMinorUnits = requested;
          reason = if (ok) null else ?(
            "participant " # bicfi # " debit limit exceeded: requested " #
            Nat.toText(requested) # ", reserved " # Nat.toText(reserved) #
            ", limit " # Nat.toText(limit)
          );
        };
      };
    };
  };

  func assertLiquidityAvailableForPayment(p : HubPayment, excludePaymentId : ?Nat) {
    let check = liquidityCheckForPayment(p, excludePaymentId);
    if (not check.ok) {
      switch (check.reason) {
        case (?reason) Runtime.trap(reason);
        case null Runtime.trap("payment is not within configured settlement liquidity limits");
      };
    };
  };

  func assertDebitAmountWithinLimit(bicfi : Text, amountMinorUnits : Nat, excludePaymentId : ?Nat) {
    let reserved = reservedDebitMinorUnits(bicfi, excludePaymentId);
    switch (Map.get(settlementDebitLimits, Text.compare, bicfi)) {
      case null {};
      case (?limit) {
        if (reserved + amountMinorUnits > limit) {
          Runtime.trap(
            "participant " # bicfi # " debit limit exceeded: requested " #
            Nat.toText(amountMinorUnits) # ", reserved " # Nat.toText(reserved) #
            ", limit " # Nat.toText(limit)
          );
        };
      };
    };
  };

  func reservedDebitMinorUnits(bicfi : Text, excludePaymentId : ?Nat) : Nat {
    var total : Nat = 0;
    for (entry in Map.values(settlementQueue)) {
      let excluded = switch (excludePaymentId) {
        case (?id) id == entry.paymentId;
        case null false;
      };
      if (not excluded and entry.status == "queued" and entry.debtorAgent == bicfi) {
        total += entry.reservedDebitMinorUnits;
      };
    };
    total;
  };

  func queuedDebitPaymentCount(bicfi : Text, excludePaymentId : ?Nat) : Nat {
    var count : Nat = 0;
    for (entry in Map.values(settlementQueue)) {
      let excluded = switch (excludePaymentId) {
        case (?id) id == entry.paymentId;
        case null false;
      };
      if (not excluded and entry.status == "queued" and entry.debtorAgent == bicfi) {
        count += 1;
      };
    };
    count;
  };

  func transferFromErrorText(err : IcrcTransferFromError) : Text {
    switch (err) {
      case (#BadFee({ expected_fee })) "BadFee expected_fee=" # Nat.toText(expected_fee);
      case (#BadBurn({ min_burn_amount })) "BadBurn min_burn_amount=" # Nat.toText(min_burn_amount);
      case (#InsufficientFunds({ balance })) "InsufficientFunds balance=" # Nat.toText(balance);
      case (#InsufficientAllowance({ allowance })) "InsufficientAllowance allowance=" # Nat.toText(allowance);
      case (#TooOld) "TooOld";
      case (#CreatedInFuture({ ledger_time })) "CreatedInFuture ledger_time=" # Nat64.toText(ledger_time);
      case (#Duplicate({ duplicate_of })) "Duplicate duplicate_of=" # Nat.toText(duplicate_of);
      case (#TemporarilyUnavailable) "TemporarilyUnavailable";
      case (#GenericError({ error_code; message })) "GenericError " # Nat.toText(error_code) # ": " # message;
    }
  };

  func settlementMemo(p : HubPayment) : Blob {
    Text.encodeUtf8("iso20022:" # p.messageId # ":uetr:" # p.uetr);
  };

  func settlePaymentOnIcrcMe(p : HubPayment, settledAt : Int) : async SettlementRecord {
    await settleIcrcMeTransfer(
      p.pacs008.debtorAgent.bicfi,
      p.pacs008.creditorAgent.bicfi,
      p.pacs008.instructedAmount,
      settlementMemo(p),
      "icrc2_transfer_from",
      settledAt,
    );
  };

  func settleIcrcMeTransfer(
    debtorBicfi : Text,
    creditorBicfi : Text,
    amount : ISO.ActiveCurrencyAndAmount,
    memo : Blob,
    transferMode : Text,
    settledAt : Int,
  ) : async SettlementRecord {
    if (amount.minorUnits == 0) Runtime.trap("ICRC-ME transfer amount must be greater than zero");
    let ledgerPrincipal = requireSettlementLedgerCanister();
    switch (settlementCurrency) {
      case (?currency) {
        if (amount.currency != currency) {
          Runtime.trap("payment currency " # amount.currency # " does not match settlement currency " # currency);
        };
      };
      case null {};
    };
    let debtorAccount = requireSettlementAccount(debtorBicfi);
    let creditorAccount = requireSettlementAccount(creditorBicfi);
    let ledger : IcrcLedger = actor (Principal.toText(ledgerPrincipal));
    let result = await ledger.icrc2_transfer_from({
      spender_subaccount = null;
      from = debtorAccount;
      to = creditorAccount;
      amount = amount.minorUnits;
      fee = if (settlementFee == 0) null else ?settlementFee;
      memo = ?memo;
      created_at_time = null;
    });
    switch (result) {
      case (#Ok(blockIndex)) {
        {
          ledgerCanister = ledgerPrincipal;
          ledgerBlockIndex = blockIndex;
          debtorAgent = debtorBicfi;
          creditorAgent = creditorBicfi;
          debtorAccount;
          creditorAccount;
          amount;
          fee = settlementFee;
          transferMode;
          settledAt;
        }
      };
      case (#Err(err)) Runtime.trap("ICRC-ME settlement failed: " # transferFromErrorText(err));
    }
  };

  func markPaymentDispatched(p : HubPayment, caller : Principal, now : Int) : HubPayment {
    {
      p with
      status = "dispatched";
      updatedAt = now;
      history = appendEvent(p.history, event(now, caller, "pacs.008.dispatched", "bank-to-bank FI credit transfer dispatched"));
    };
  };

  func markPaymentQueued(p : HubPayment, caller : Principal, now : Int, reason : Text) : HubPayment {
    {
      p with
      status = "queued";
      updatedAt = now;
      history = appendEvent(p.history, event(now, caller, "settlement.queue.queued", reason));
    };
  };

  func settleGrossPaymentOnIcrcMe(p : HubPayment, caller : Principal, now : Int) : async HubPayment {
    let settlement = await settlePaymentOnIcrcMe(p, now);
    let ack = ISO.pacs002(
      guideline,
      "PACS002-" # Nat.toText(p.id) # "-ICRC-" # Nat.toText(settlement.ledgerBlockIndex),
      p.messageId,
      p.uetr,
      "ACSC",
      ?("ICRC-ME ledger block " # Nat.toText(settlement.ledgerBlockIndex)),
      p.pacs008.creationDateTime,
    );
    let ackReport = ISO.validateStatusReport(guideline, ack, "pacs.002");
    if (not ackReport.ok) Runtime.trap("generated settlement pacs.002 failed validation");
    {
      p with
      status = "settled";
      updatedAt = now;
      pacs002 = ?ack;
      settlement = ?settlement;
      history = appendEvent(
        appendEvent(p.history, event(now, caller, "pacs.008.dispatched", "bank-to-bank FI credit transfer dispatched to settlement ledger")),
        event(now, caller, "settlement.icrc-me.block", "ICRC-ME transfer_from finalized at ledger block " # Nat.toText(settlement.ledgerBlockIndex)),
      );
    };
  };

  func markPaymentOffsetSettled(
    p : HubPayment,
    caller : Principal,
    now : Int,
    ledgerPrincipal : Principal,
    ledgerBlockIndex : ?Nat,
    netTransferMode : Text,
  ) : HubPayment {
    let blockIndex = switch (ledgerBlockIndex) {
      case (?block) block;
      case null 0;
    };
    let transferMode = switch (ledgerBlockIndex) {
      case (?_) netTransferMode;
      case null "offset.zero_net";
    };
    let reason = switch (ledgerBlockIndex) {
      case (?block) "ICRC-ME offset net block " # Nat.toText(block);
      case null "ICRC-ME zero-net offset";
    };
    let ack = ISO.pacs002(
      guideline,
      "PACS002-" # Nat.toText(p.id) # "-ICRC-OFFSET-" # Nat.toText(blockIndex),
      p.messageId,
      p.uetr,
      "ACSC",
      ?reason,
      p.pacs008.creationDateTime,
    );
    let ackReport = ISO.validateStatusReport(guideline, ack, "pacs.002");
    if (not ackReport.ok) Runtime.trap("generated offset pacs.002 failed validation");
    let settlement = {
      ledgerCanister = ledgerPrincipal;
      ledgerBlockIndex = blockIndex;
      debtorAgent = p.pacs008.debtorAgent.bicfi;
      creditorAgent = p.pacs008.creditorAgent.bicfi;
      debtorAccount = requireSettlementAccount(p.pacs008.debtorAgent.bicfi);
      creditorAccount = requireSettlementAccount(p.pacs008.creditorAgent.bicfi);
      amount = p.pacs008.instructedAmount;
      fee = switch (ledgerBlockIndex) { case (?_) settlementFee; case null 0 };
      transferMode;
      settledAt = now;
    };
    {
      p with
      status = "settled";
      updatedAt = now;
      pacs002 = ?ack;
      settlement = ?settlement;
      history = appendEvent(
        p.history,
        event(now, caller, "settlement.icrc-me.offset", reason),
      );
    };
  };

  func queueSettlementPaymentCore(p : HubPayment, priority : Nat, bypassFifo : Bool, reason : Text, now : Int) : SettlementQueueEntry {
    if (not settlementEnabled) Runtime.trap("settlement ledger must be enabled before queueing");
    let queueReason = if (Text.size(reason) == 0) "payment queued by settlement liquidity policy" else reason;
    let entry = {
      paymentId = p.id;
      queuedAt = now;
      updatedAt = now;
      priority;
      bypassFifo;
      debtorAgent = p.pacs008.debtorAgent.bicfi;
      creditorAgent = p.pacs008.creditorAgent.bicfi;
      amount = p.pacs008.instructedAmount;
      reservedDebitMinorUnits = p.pacs008.instructedAmount.minorUnits;
      reason = queueReason;
      status = "queued";
    };
    Map.add(settlementQueue, Nat.compare, p.id, entry);
    settlementQueueIndex := OrderedIndex.replace(settlementQueueIndex, settlementQueueKey(entry), p.id);
    commitSettlementQueueIndexCheckpoint();
    entry;
  };

  func assertQueueEntry(paymentId : Nat) {
    switch (Map.get(settlementQueue, Nat.compare, paymentId)) {
      case (?_) {};
      case null Runtime.trap("payment is not in the settlement queue");
    };
  };

  func removeSettlementQueueEntry(paymentId : Nat) {
    ignore Map.delete(settlementQueue, Nat.compare, paymentId);
    settlementQueueIndex := OrderedIndex.removeId(settlementQueueIndex, paymentId);
    commitSettlementQueueIndexCheckpoint();
  };

  func requirePayment(id : Nat) : HubPayment {
    switch (Map.get(payments, Nat.compare, id)) {
      case (?p) p;
      case null Runtime.trap("payment not found");
    };
  };

  func indexPayment(p : HubPayment) {
    indexPaymentHeap(p);
    commitPaymentIndexCheckpoints();
  };

  func indexPaymentHeap(p : HubPayment) {
    paymentStatusIndex := OrderedIndex.replace(paymentStatusIndex, paymentStatusKey(p), p.id);
    paymentAccountIndex := OrderedIndex.replace(paymentAccountIndex, paymentAccountKey(p), p.id);
    paymentCreditorAgentIndex := OrderedIndex.replace(paymentCreditorAgentIndex, paymentCreditorAgentKey(p), p.id);
  };

  func storeOutboundBatch(batch : OutboundBatch) {
    Map.add(outboundBatches, Nat.compare, batch.id, batch);
    outboundQueueIndex := OrderedIndex.replace(outboundQueueIndex, outboundQueueKey(batch), batch.id);
    commitOutboundIndexCheckpoint();
  };

  func rebuildSecondaryIndexesCore() {
    paymentStatusIndex := OrderedIndex.empty();
    paymentAccountIndex := OrderedIndex.empty();
    paymentCreditorAgentIndex := OrderedIndex.empty();
    outboundQueueIndex := OrderedIndex.empty();
    settlementQueueIndex := OrderedIndex.empty();
    for (p in Map.values(payments)) {
      indexPaymentHeap(p);
    };
    for (batch in Map.values(outboundBatches)) {
      outboundQueueIndex := OrderedIndex.replace(outboundQueueIndex, outboundQueueKey(batch), batch.id);
    };
    for (entry in Map.values(settlementQueue)) {
      settlementQueueIndex := OrderedIndex.replace(settlementQueueIndex, settlementQueueKey(entry), entry.paymentId);
    };
    commitSecondaryIndexCheckpoints();
  };

  func commitPaymentIndexCheckpoints() {
    StableOrderedIndex.commit(paymentStatusStableIndex, paymentStatusIndex);
    StableOrderedIndex.commit(paymentAccountStableIndex, paymentAccountIndex);
    StableOrderedIndex.commit(paymentCreditorAgentStableIndex, paymentCreditorAgentIndex);
  };

  func commitOutboundIndexCheckpoint() {
    StableOrderedIndex.commit(outboundQueueStableIndex, outboundQueueIndex);
  };

  func commitSettlementQueueIndexCheckpoint() {
    StableOrderedIndex.commit(settlementQueueStableIndex, settlementQueueIndex);
  };

  func commitSecondaryIndexCheckpoints() {
    commitPaymentIndexCheckpoints();
    commitOutboundIndexCheckpoint();
    commitSettlementQueueIndexCheckpoint();
  };

  func secondaryIndexHealthCore() : SecondaryIndexHealth {
    {
      paymentStatusSize = OrderedIndex.size(paymentStatusIndex);
      paymentAccountSize = OrderedIndex.size(paymentAccountIndex);
      paymentCreditorAgentSize = OrderedIndex.size(paymentCreditorAgentIndex);
      outboundQueueSize = OrderedIndex.size(outboundQueueIndex);
      settlementQueueSize = OrderedIndex.size(settlementQueueIndex);
      paymentStatus = OrderedIndex.verify(paymentStatusIndex);
      paymentAccount = OrderedIndex.verify(paymentAccountIndex);
      paymentCreditorAgent = OrderedIndex.verify(paymentCreditorAgentIndex);
      outboundQueue = OrderedIndex.verify(outboundQueueIndex);
      settlementQueue = OrderedIndex.verify(settlementQueueIndex);
      stablePaymentStatus = StableOrderedIndex.verify(paymentStatusStableIndex);
      stablePaymentAccount = StableOrderedIndex.verify(paymentAccountStableIndex);
      stablePaymentCreditorAgent = StableOrderedIndex.verify(paymentCreditorAgentStableIndex);
      stableOutboundQueue = StableOrderedIndex.verify(outboundQueueStableIndex);
      stableSettlementQueue = StableOrderedIndex.verify(settlementQueueStableIndex);
    };
  };

  func paymentStatusKey(p : HubPayment) : Text {
    OrderedIndex.join([OrderedIndex.keyPart(p.status), OrderedIndex.intPart(p.updatedAt), OrderedIndex.natPart(p.id)]);
  };

  func paymentAccountKey(p : HubPayment) : Text {
    OrderedIndex.join([OrderedIndex.keyPart(paymentAccountId(p)), OrderedIndex.intPart(p.updatedAt), OrderedIndex.natPart(p.id)]);
  };

  func paymentCreditorAgentKey(p : HubPayment) : Text {
    OrderedIndex.join([OrderedIndex.keyPart(p.pacs008.creditorAgent.bicfi), OrderedIndex.intPart(p.updatedAt), OrderedIndex.natPart(p.id)]);
  };

  func outboundQueueKey(batch : OutboundBatch) : Text {
    OrderedIndex.join([OrderedIndex.keyPart(batch.connectorId), OrderedIndex.keyPart(batch.status), OrderedIndex.intPart(batch.updatedAt), OrderedIndex.natPart(batch.id)]);
  };

  func settlementQueueKey(entry : SettlementQueueEntry) : Text {
    OrderedIndex.join([
      OrderedIndex.keyPart(entry.status),
      OrderedIndex.keyPart(if (entry.bypassFifo) "0-bypass" else "1-fifo"),
      OrderedIndex.natPart(entry.priority),
      OrderedIndex.intPart(entry.queuedAt),
      OrderedIndex.natPart(entry.paymentId),
    ]);
  };

  func paymentAccountId(p : HubPayment) : Text {
    switch (p.pacs008.creditorAccount.iban) {
      case (?iban) iban;
      case null {
        switch (p.pacs008.creditorAccount.otherId) {
          case (?other) other;
          case null "unidentified-creditor-account";
        };
      };
    };
  };

  func paymentViewPageFromIds(ids : [Nat], offset : Nat, limit : Nat) : Pagination.Page<PaymentView> {
    var all : [PaymentView] = [];
    for (id in ids.vals()) {
      switch (Map.get(payments, Nat.compare, id)) {
        case (?p) all := Array.concat<PaymentView>(all, [paymentView(p)]);
        case null {};
      };
    };
    Pagination.page<PaymentView>(all, offset, limit);
  };

  func statementPageFromIds(ids : [Nat], offset : Nat, limit : Nat) : Pagination.Page<StatementEntry> {
    var all : [StatementEntry] = [];
    for (id in ids.vals()) {
      switch (Map.get(payments, Nat.compare, id)) {
        case (?p) all := Array.concat<StatementEntry>(all, [statementEntry(p)]);
        case null {};
      };
    };
    Pagination.page<StatementEntry>(all, offset, limit);
  };

  func outboundPageFromIds(ids : [Nat], offset : Nat, limit : Nat) : Pagination.Page<OutboundBatch> {
    var all : [OutboundBatch] = [];
    for (id in ids.vals()) {
      switch (Map.get(outboundBatches, Nat.compare, id)) {
        case (?batch) all := Array.concat<OutboundBatch>(all, [batch]);
        case null {};
      };
    };
    Pagination.page<OutboundBatch>(all, offset, limit);
  };

  func settlementQueuePageFromIds(ids : [Nat], offset : Nat, limit : Nat) : Pagination.Page<SettlementQueueEntry> {
    var all : [SettlementQueueEntry] = [];
    for (id in ids.vals()) {
      switch (Map.get(settlementQueue, Nat.compare, id)) {
        case (?entry) all := Array.concat<SettlementQueueEntry>(all, [entry]);
        case null {};
      };
    };
    Pagination.page<SettlementQueueEntry>(all, offset, limit);
  };

  func setConnectorPolicyCore(id : Text, policy : SignaturePolicy) : ConnectorConfig {
    switch (Map.get(connectors, Text.compare, id)) {
      case null Runtime.trap("connector not found");
      case (?c) {
        let next = { c with signaturePolicy = policy; publicKeyHash = policy.publicKeyHash; updatedAt = Time.now() };
        Map.add(connectors, Text.compare, id, next);
        next;
      };
    };
  };

  func verifyExternalSignatureIfNeeded(
    connector : ?ConnectorConfig,
    env : TransportEnvelope,
    payloadHash : Blob,
    issues0 : [ValidationIssue],
  ) : async [ValidationIssue] {
    var issues = issues0;
    switch (connector) {
      case null issues;
      case (?c) {
        let policy = c.signaturePolicy;
        if (policy.mode != "external-attestation") return issues;
        switch (policy.verifier, env.signature) {
          case (?verifierPrincipal, ?signature) {
            let messageHash = connectorEnvelopeHash(env, payloadHash, policy.domain);
            let request : SignatureVerificationRequest = {
              connectorId = env.connectorId;
              scheme = policy.scheme;
              domain = policy.domain;
              payloadHash;
              envelopeHash = messageHash;
              signature;
              publicKeyHash = policy.publicKeyHash;
              traceId = env.traceId;
              remoteId = env.remoteId;
            };
            let verifier : SignatureVerifier = actor (Principal.toText(verifierPrincipal));
            let report = await verifier.verify_connector_signature(request);
            if (not report.ok) {
              if (report.issues.size() == 0) {
                issues := addIssue(issues, ISO.publicIssue("transport", "TRANSPORT-SIGNATURE-VERIFY-FAILED", "$.signature", "external signature verifier rejected the envelope"));
              } else {
                for (issue in report.issues.vals()) {
                  issues := addIssue(issues, issue);
                };
              };
            };
            if (report.scheme != policy.scheme) {
              issues := addIssue(issues, ISO.publicIssue("transport", "TRANSPORT-SIGNATURE-SCHEME-MISMATCH", "$.signature.scheme", "external verifier returned a different signature scheme"));
            };
            if (report.messageHash != messageHash) {
              issues := addIssue(issues, ISO.publicIssue("transport", "TRANSPORT-SIGNATURE-MESSAGE-HASH-MISMATCH", "$.signature.messageHash", "external verifier did not verify the canister's canonical connector-envelope hash"));
            };
            switch (policy.publicKeyHash, report.signerKeyHash) {
              case (?expected, ?actual) {
                if (expected != actual) {
                  issues := addIssue(issues, ISO.publicIssue("transport", "TRANSPORT-SIGNATURE-KEY-HASH-MISMATCH", "$.signature.signerKeyHash", "external verifier signer key hash does not match connector policy"));
                };
              };
              case (?_, null) {
                issues := addIssue(issues, ISO.publicIssue("transport", "TRANSPORT-SIGNATURE-KEY-HASH-REQUIRED", "$.signature.signerKeyHash", "external verifier must return a signer key hash for this connector policy"));
              };
              case _ {};
            };
            issues;
          };
          case (_, null) addIssue(issues, ISO.publicIssue("transport", "TRANSPORT-SIGNATURE-REQUIRED", "$.signature", "external signature policy requires detached signature bytes"));
          case (null, _) addIssue(issues, ISO.publicIssue("transport", "TRANSPORT-SIGNATURE-VERIFIER-REQUIRED", "$.signaturePolicy.verifier", "external signature policy requires verifier canister principal"));
        };
      };
    };
  };

  func queuePaymentOutboundCore(connectorId : Text, paymentId : ?Nat, format : Text) : OutboundBatch {
    let now = Time.now();
    let connector = Map.get(connectors, Text.compare, connectorId);
    var issues : [ValidationIssue] = [];
    let payload = switch (paymentId) {
      case (?id) {
        switch (Map.get(payments, Nat.compare, id)) {
          case null {
            issues := addIssue(issues, ISO.publicIssue("business", "OUTBOUND-PAYMENT-NOT-FOUND", "$.paymentId", "payment does not exist"));
            "" : Blob;
          };
          case (?payment) {
            switch (outboundPayload(payment, format)) {
              case (?body) body;
              case null {
                issues := addIssue(issues, ISO.publicIssue("transport", "OUTBOUND-FORMAT-ROUTE-MISSING", "$.format", "outbound format is not implemented by the canister serializer"));
                "" : Blob;
              };
            };
          };
        };
      };
      case null {
        issues := addIssue(issues, ISO.publicIssue("business", "OUTBOUND-PAYMENT-REQUIRED", "$.paymentId", "payment id is required for payment outbound formats"));
        "" : Blob;
      };
    };
    for (i in Connector.verifyOutboundQueue(connector, connectorId, format, payload).vals()) {
      issues := addIssue(issues, i);
    };
    let hash = hashBlob(payload);
    let batch = makeOutboundBatch(connectorId, paymentId, format, payload, hash, if (issues.size() == 0) "queued" else "dead-letter", 0, 3, now, null, null, issues);
    storeOutboundBatch(batch);
    batch;
  };

  func outboundPayload(payment : HubPayment, format : Text) : ?Blob {
    if (format == "payment.bundle.xml") {
      ?Text.encodeUtf8(paymentBundleXml(payment));
    } else if (format == "pacs.008.xml") {
      ?Text.encodeUtf8(Xml.pacs008ToXml(payment.pacs008));
    } else if (format == "pain.002.xml") {
      ?Text.encodeUtf8(Xml.statusReportToXml(payment.pain002));
    } else if (format == "pacs.002.xml") {
      switch (payment.pacs002) {
        case (?ack) ?Text.encodeUtf8(Xml.statusReportToXml(ack));
        case null null;
      };
    } else if (format == "pacs.004.xml") {
      switch (payment.returnReport) {
        case (?ret) ?Text.encodeUtf8(Xml.statusReportToXml(ret));
        case null null;
      };
    } else if (format == "camt.054.xml") {
      ?Text.encodeUtf8(Xml.camt054ToXml(statementEntry(payment)));
    } else {
      null;
    };
  };

  func paymentBundleXml(payment : HubPayment) : Text {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<PaymentXmlBundle codec=\"" # Xml.codecVersion # "\" paymentId=\"" # Nat.toText(payment.id) # "\">\n"
    # xmlBlock("Pain001", Xml.pain001ToXml(payment.instruction))
    # xmlBlock("Pacs008", Xml.pacs008ToXml(payment.pacs008))
    # xmlBlock("Pain002", Xml.statusReportToXml(payment.pain002))
    # (switch (payment.pacs002) {
      case (?ack) xmlBlock("Pacs002", Xml.statusReportToXml(ack));
      case null "";
    })
    # (switch (payment.returnReport) {
      case (?ret) xmlBlock("Pacs004", Xml.statusReportToXml(ret));
      case null "";
    })
    # xmlBlock("Camt054", Xml.camt054ToXml(statementEntry(payment)))
    # "</PaymentXmlBundle>\n";
  };

  func xmlBlock(tag : Text, body : Text) : Text {
    "  <" # tag # ">\n" # indentXml(body, 4) # "  </" # tag # ">\n";
  };

  func indentXml(value : Text, indent : Nat) : Text {
    var prefix = "";
    var i = 0;
    while (i < indent) {
      prefix #= " ";
      i += 1;
    };
    var out = "";
    for (line in Text.split(value, #char '\n')) {
      if (line != "") out #= prefix # line # "\n";
    };
    out;
  };

  func requireConnectorCaller(caller : Principal, connectorId : Text) {
    if (Admin.isAdmin(admin, caller)) return;
    switch (Map.get(connectors, Text.compare, connectorId)) {
      case (?connector) {
        if (Principal.equal(connector.owner, caller)) return;
        Runtime.trap("connector owner or admin required");
      };
      case null Runtime.trap("connector not found");
    };
  };

  func canonicalGuidelineProfileId(profileId : Text) : Text {
    if (profileId == "EGYPT-ISO20022-HUB-EDU" or profileId == "EGYPT-ISO20022-HUB-EDU-BASELINE-2026-06-22") {
      egGuidelineProfileId
    } else if (profileId == "CBPRPLUS-EDU-CROSSBORDER-BASELINE-2026-06-22") {
      cbprGuidelineProfileId
    } else {
      profileId
    };
  };

  func builtinGuidelineProfileIds() : [Text] {
    [
      egGuidelineProfileId,
      cbprGuidelineProfileId,
      sepaSctGuidelineProfileId,
      sepaSctInstGuidelineProfileId,
      sepaSddGuidelineProfileId,
      fedwireGuidelineProfileId,
      fednowGuidelineProfileId,
      bisCrossBorderGuidelineProfileId,
    ];
  };

  func isBuiltinGuidelineProfileId(profileId : Text) : Bool {
    let canonical = canonicalGuidelineProfileId(profileId);
    for (id in builtinGuidelineProfileIds().vals()) {
      if (id == canonical) return true;
    };
    false;
  };

  func guidelineProfile(profileId : Text) : ?GuidelineProfile {
    let canonical = canonicalGuidelineProfileId(profileId);
    switch (Map.get(customGuidelineProfiles, Text.compare, canonical)) {
      case (?profile) ?profile;
      case null builtinGuidelineProfile(canonical);
    };
  };

  func requireGuidelineProfile(profileId : Text) : GuidelineProfile {
    switch (guidelineProfile(profileId)) {
      case (?profile) profile;
      case null Runtime.trap("guideline profile not found");
    };
  };

  func requireGuidelineForProfile(profileId : Text) : UsageGuideline {
    requireGuidelineProfile(profileId).guideline;
  };

  func setDefaultGuidelineProfileCore(profileId : Text) : GuidelineProfileSummary {
    let canonical = canonicalGuidelineProfileId(profileId);
    let profile = requireGuidelineProfile(canonical);
    defaultGuidelineProfileId := canonical;
    guideline := profile.guideline;
    guidelineProfileSummary(profile, isBuiltinGuidelineProfileId(canonical));
  };

  func guidelineForConnector(connectorId : Text) : UsageGuideline {
    switch (Map.get(connectorGuidelineProfiles, Text.compare, connectorId)) {
      case (?selection) requireGuidelineForProfile(selection.profileId);
      case null guideline;
    };
  };

  func guidelineProfileSummaries() : [GuidelineProfileSummary] {
    var out : [GuidelineProfileSummary] = [];
    for (id in builtinGuidelineProfileIds().vals()) {
      switch (builtinGuidelineProfile(id)) {
        case (?profile) out := Array.concat<GuidelineProfileSummary>(out, [guidelineProfileSummary(profile, true)]);
        case null {};
      };
    };
    for (profile in Map.values(customGuidelineProfiles)) {
      out := Array.concat<GuidelineProfileSummary>(out, [guidelineProfileSummary(profile, false)]);
    };
    out;
  };

  func guidelineProfileSummary(profile : GuidelineProfile, builtin : Bool) : GuidelineProfileSummary {
    {
      id = profile.id;
      displayName = profile.displayName;
      status = profile.status;
      guidelineId = profile.guideline.id;
      notes = profile.notes;
      updatedAt = profile.updatedAt;
      builtin = builtin;
    };
  };

  func builtinGuidelineProfile(profileId : Text) : ?GuidelineProfile {
    let id = canonicalGuidelineProfileId(profileId);
    if (id == egGuidelineProfileId) {
      ?guidelineProfileFromGuideline(
        egGuidelineProfileId,
        "Egypt domestic credit transfer education profile",
        "implemented-compact",
        ISO.defaultGuideline(),
        "Default Egypt domestic profile with EG BIC/IBAN and EGP-focused validation rules.",
      )
    } else if (id == cbprGuidelineProfileId) {
      ?guidelineProfileFromGuideline(
        cbprGuidelineProfileId,
        "Cross-border and cover-payment education profile",
        "implemented-compact",
        crossMarketGuideline(
          cbprGuidelineProfileId,
          "Open CBPR+ education overlay",
          "Public education profile for CBPR+-shaped cross-border, cover, status, and investigation messages.",
        ),
        "Removes Egypt-only agent/IBAN requirements and uses the cross-border education settlement method.",
      )
    } else if (id == sepaSctGuidelineProfileId) {
      ?guidelineProfileFromGuideline(
        sepaSctGuidelineProfileId,
        "SEPA Credit Transfer public-source education overlay",
        "implemented-runtime-overlay",
        crossMarketGuideline(
          sepaSctGuidelineProfileId,
          "Public EPC SCT education overlay",
          "Public education profile for SEPA SCT-shaped credit-transfer validation. Official EPC conformance remains external.",
        ),
        "Runtime-selectable SEPA SCT overlay; external XSD/MUG profile runner remains the official scheme gate.",
      )
    } else if (id == sepaSctInstGuidelineProfileId) {
      ?guidelineProfileFromGuideline(
        sepaSctInstGuidelineProfileId,
        "SEPA Instant Credit Transfer public-source education overlay",
        "implemented-runtime-overlay",
        crossMarketGuideline(
          sepaSctInstGuidelineProfileId,
          "Public EPC SCT Inst education overlay",
          "Public education profile for SEPA Instant-shaped credit-transfer validation. Instant SLA and scheme rules remain external.",
        ),
        "Runtime-selectable SEPA instant overlay; timing and official scheme checks remain external.",
      )
    } else if (id == sepaSddGuidelineProfileId) {
      ?guidelineProfileFromGuideline(
        sepaSddGuidelineProfileId,
        "SEPA Direct Debit public-source education overlay",
        "implemented-runtime-overlay",
        crossMarketGuideline(
          sepaSddGuidelineProfileId,
          "Public EPC SDD education overlay",
          "Public education profile for compact SEPA SDD pain.008 and pacs.003 validation.",
        ),
        "Runtime-selectable SEPA SDD overlay; mandate lifecycle and official scheme checks remain external.",
      )
    } else if (id == fedwireGuidelineProfileId) {
      ?guidelineProfileFromGuideline(
        fedwireGuidelineProfileId,
        "Fedwire ISO 20022 public-source education overlay",
        "implemented-runtime-overlay",
        crossMarketGuideline(
          fedwireGuidelineProfileId,
          "Public Fedwire ISO 20022 education overlay",
          "Public education profile for Fedwire-shaped payment, RFP, case-management, and administrative messages.",
        ),
        "Runtime-selectable Fedwire overlay; MyStandards and Federal Reserve production readiness checks remain external.",
      )
    } else if (id == fednowGuidelineProfileId) {
      ?guidelineProfileFromGuideline(
        fednowGuidelineProfileId,
        "FedNow ISO 20022 public-source education overlay",
        "implemented-runtime-overlay",
        crossMarketGuideline(
          fednowGuidelineProfileId,
          "Public FedNow ISO 20022 education overlay",
          "Public education profile for FedNow-shaped payment, RFP, status, and reporting messages.",
        ),
        "Runtime-selectable FedNow overlay; service rules and production readiness checks remain external.",
      )
    } else if (id == bisCrossBorderGuidelineProfileId) {
      ?guidelineProfileFromGuideline(
        bisCrossBorderGuidelineProfileId,
        "BIS CPMI cross-border harmonisation research overlay",
        "research-runtime-overlay",
        crossMarketGuideline(
          bisCrossBorderGuidelineProfileId,
          "BIS CPMI harmonisation education overlay",
          "Research overlay for CPMI harmonised cross-border ISO 20022 message coverage.",
        ),
        "Runtime-selectable research overlay; not a certification or institutional rulebook.",
      )
    } else {
      null
    };
  };

  func guidelineProfileFromGuideline(id : Text, displayName : Text, status : Text, g : UsageGuideline, notes : Text) : GuidelineProfile {
    {
      id;
      displayName;
      status;
      guideline = g;
      notes;
      updatedAt = 0;
    };
  };

  func crossMarketGuideline(profileId : Text, authority : Text, description : Text) : UsageGuideline {
    let base = ISO.crossBorderEducationGuideline();
    {
      base with
      id = profileId # "-GUIDELINE-2026-06-24";
      authority;
      description;
      countryCodes = crossMarketCountryCodes();
    };
  };

  func crossMarketCountryCodes() : [Text] {
    [
      "EG", "AE", "SA", "GB", "US", "DE", "FR", "CH", "JP", "CN", "SG", "ZA",
      "AT", "BE", "CY", "EE", "ES", "FI", "GR", "IE", "IT", "LU", "LV", "MT",
      "NL", "PT", "SI", "SK",
    ];
  };

  func defaultLegacyCountry() : Text {
    defaultLegacyCountryForGuideline(guideline);
  };

  func defaultLegacyCountryForGuideline(g : UsageGuideline) : Text {
    switch (g.requiredAgentCountry) {
      case (?country) country;
      case null "EG";
    };
  };

  func defaultLegacyCurrency() : Text {
    defaultLegacyCurrencyForGuideline(guideline);
  };

  func defaultLegacyCurrencyForGuideline(g : UsageGuideline) : Text {
    if (g.currencies.size() > 0) {
      g.currencies[0].code
    } else {
      "EGP"
    };
  };

  func submitLegacyPaymentBatch(caller : Principal, docs : [CustomerCreditTransferInitiation], raw : Blob, g : UsageGuideline) : ?Nat {
    var first : ?Nat = null;
    for (doc in docs.vals()) {
      let p = submitPain001CoreWithGuideline(caller, doc, ?raw, g);
      switch (first) {
        case null { first := ?p.id };
        case (?_) {};
      };
    };
    first;
  };

  func makeTransportRecord(
    env : TransportEnvelope,
    expectedHash : Blob,
    status : Text,
    paymentId : ?Nat,
    issues : [ValidationIssue],
  ) : TransportRecord {
    let id = nextTransportId;
    nextTransportId += 1;
    {
      id;
      connectorId = env.connectorId;
      remoteId = env.remoteId;
      sequence = env.sequence;
      format = env.format;
      traceId = env.traceId;
      receivedAt = Time.now();
      payloadHash = expectedHash;
      status;
      paymentId;
      issueCount = issues.size();
      issues;
    };
  };

  func makeOutboundBatch(
    connectorId : Text,
    paymentId : ?Nat,
    format : Text,
    payload : Blob,
    payloadHash : Blob,
    status : Text,
    attemptCount : Nat,
    maxAttempts : Nat,
    now : Int,
    leasedUntil : ?Int,
    ack : ?DeliveryAck,
    issues : [ValidationIssue],
  ) : OutboundBatch {
    let id = nextOutboundBatchId;
    nextOutboundBatchId += 1;
    {
      id;
      connectorId;
      paymentId;
      format;
      payload;
      payloadHash;
      status;
      attemptCount;
      maxAttempts;
      createdAt = now;
      updatedAt = now;
      leasedUntil;
      ack;
      issueCount = issues.size();
      issues;
    };
  };

  func event(at : Int, by : Principal, name : Text, detail : Text) : PaymentEvent {
    { at; by; event = name; detail };
  };

  func appendEvent(history : [PaymentEvent], next : PaymentEvent) : [PaymentEvent] {
    Array.concat<PaymentEvent>(history, [next]);
  };

  func hasTextIndex(index : Map.Map<Text, Nat>, key : Text) : Bool {
    switch (Map.get(index, Text.compare, key)) {
      case (?_) true;
      case null false;
    };
  };

  func combineReportsWithGuideline(g : UsageGuideline, kind : Text, version : Text, reports : [ValidationReport], extraIssues : [ValidationIssue]) : ValidationReport {
    var issues = extraIssues;
    for (report in reports.vals()) {
      for (iss in report.issues.vals()) {
        issues := addIssue(issues, iss);
      };
    };
    ISO.reportFromIssues(g, kind, version, issues);
  };

  func reportWithComplianceIssues(g : UsageGuideline, validationReport : ValidationReport, complianceReport : ComplianceReport) : ValidationReport {
    var issues = validationReport.issues;
    for (finding in complianceReport.findings.vals()) {
      issues := addIssue(
        issues,
        ISO.publicIssue(
          "compliance",
          finding.ruleId,
          finding.path,
          finding.message # " decision=" # complianceReport.decision # " action=" # finding.action,
        ),
      );
    };
    ISO.reportFromIssues(g, validationReport.messageKind, validationReport.messageVersion, issues);
  };

  func complianceActionForReport(validationReport : ValidationReport, complianceReport : ComplianceReport) : Text {
    if (not validationReport.ok) {
      "validation-rejected"
    } else if (complianceReport.decision == "pass") {
      "pass"
    } else {
      "hold"
    };
  };

  func complianceHistoryDetail(report : ComplianceReport) : Text {
    "decision=" # report.decision
    # " profile=" # report.profileId
    # " findings=" # Nat.toText(report.findingCount)
    # " riskScore=" # Nat.toText(report.riskScore);
  };

  func updateComplianceHeldPayment(paymentId : Nat, nextStatus : Text, eventName : Text, reason : Text, caller : Principal) : HubPayment {
    let p = requirePayment(paymentId);
    if (p.status != "held") Runtime.trap("payment is not held by compliance");
    let now = Time.now();
    let next = {
      p with
      status = nextStatus;
      updatedAt = now;
      history = appendEvent(p.history, event(now, caller, eventName, reason));
    };
    switch (Map.get(complianceScreeningRecords, Nat.compare, paymentId)) {
      case (?record) {
        let action = if (nextStatus == "accepted") "released" else "rejected";
        Map.add(complianceScreeningRecords, Nat.compare, paymentId, { record with action });
      };
      case null {};
    };
    Map.add(payments, Nat.compare, paymentId, next);
    indexPayment(next);
    next;
  };

  func oracleReport(phase : Text, issues : [ValidationIssue]) : ValidationReport {
    ISO.reportFromIssues(guideline, "oracle." # phase, Oracles.registryVersion, issues);
  };

  func oracleIssue(ruleId : Text, path : Text, message : Text) : ValidationIssue {
    ISO.publicIssue("oracle", ruleId, path, message);
  };

  func guidelineHasMessageKind(kind : Text) : Bool {
    for (mv in guideline.messageVersions.vals()) {
      if (mv.kind == kind) return true;
    };
    false;
  };

  func validComplianceDecision(decision : Text) : Bool {
    decision == "pass" or decision == "review" or decision == "block";
  };

  func sampleMt103() : Text {
    "{4:\n"
      # ":20:MT103-20260622-0001\n"
      # ":32A:260622EGP12500,00\n"
      # ":50K:/EG380019000500000000263180002\n"
      # "Example Debtor SAE\n"
      # "1 Nile Corniche\n"
      # ":52A:EGBKEGCX\n"
      # ":57A:EXBKEGCX\n"
      # ":59:/EG800002000156789012345180002\n"
      # "Example Creditor LLC\n"
      # "10 Port Road\n"
      # ":70:Invoice INV-2026-001\n"
      # ":71A:SHA\n"
      # "-}";
  };

  func addIssue(xs : [ValidationIssue], x : ValidationIssue) : [ValidationIssue] {
    Array.concat<ValidationIssue>(xs, [x]);
  };

  func optText(value : ?Text) : Text {
    switch (value) {
      case (?text) text;
      case null "";
    };
  };

  func textArrayContains(xs : [Text], x : Text) : Bool {
    for (value in xs.vals()) {
      if (value == x) return true;
    };
    false;
  };

  func addUniqueText(xs : [Text], x : Text) : [Text] {
    if (textArrayContains(xs, x)) xs else Array.concat<Text>(xs, [x]);
  };

  func addUniqueTexts(xs : [Text], values : [Text]) : [Text] {
    var out = xs;
    for (value in values.vals()) {
      if (value != "") out := addUniqueText(out, value);
    };
    out;
  };

  func verifyPaymentAuditReport(p : HubPayment) : ValidationReport {
    var issues : [ValidationIssue] = [];
    switch (Map.get(audits, Nat.compare, p.auditId)) {
      case null {
        issues := addIssue(issues, ISO.publicIssue("business", "AUDIT-MISSING", "$.auditId", "payment audit record is missing"));
      };
      case (?audit) {
        if (audit.businessMessageId != p.messageId) {
          issues := addIssue(issues, ISO.publicIssue("business", "AUDIT-MSGID-MISMATCH", "$.audit.businessMessageId", "audit message id does not match payment"));
        };
        if (audit.uetr != p.uetr) {
          issues := addIssue(issues, ISO.publicIssue("business", "AUDIT-UETR-MISMATCH", "$.audit.uetr", "audit UETR does not match payment"));
        };
        if (audit.recordHash != computeAuditHash(audit)) {
          issues := addIssue(issues, ISO.publicIssue("business", "AUDIT-HASH-MISMATCH", "$.audit.recordHash", "audit hash no longer matches audit content"));
        };
      };
    };
    ISO.reportFromIssues(guideline, "hub.audit", "internal", issues);
  };

  func verifyPaymentIndexReport(p : HubPayment) : ValidationReport {
    var issues : [ValidationIssue] = [];
    switch (Map.get(paymentByUetr, Text.compare, p.uetr)) {
      case (?id) {
        if (id != p.id and not p.duplicateSignal.exactUetrDuplicate) {
          issues := addIssue(issues, ISO.publicIssue("business", "UETR-INDEX-MISMATCH", "$.uetr", "UETR index points to another payment"));
        };
      };
      case null {
        if (not p.duplicateSignal.exactUetrDuplicate) {
          issues := addIssue(issues, ISO.publicIssue("business", "UETR-INDEX-MISSING", "$.uetr", "UETR index is missing"));
        };
      };
    };
    switch (Map.get(paymentByMessageId, Text.compare, p.messageId)) {
      case (?id) {
        if (id != p.id and not p.duplicateSignal.exactMessageIdDuplicate) {
          issues := addIssue(issues, ISO.publicIssue("business", "MSGID-INDEX-MISMATCH", "$.messageId", "messageId index points to another payment"));
        };
      };
      case null {
        if (not p.duplicateSignal.exactMessageIdDuplicate) {
          issues := addIssue(issues, ISO.publicIssue("business", "MSGID-INDEX-MISSING", "$.messageId", "messageId index is missing"));
        };
      };
    };
    if (not Bloom.mightContain(uetrBloom, p.uetr)) {
      issues := addIssue(issues, ISO.publicIssue("business", "UETR-BLOOM-MISSING", "$.uetr", "UETR Bloom filter has an unexpected false negative"));
    };
    if (not Bloom.mightContain(messageIdBloom, p.messageId)) {
      issues := addIssue(issues, ISO.publicIssue("business", "MSGID-BLOOM-MISSING", "$.messageId", "messageId Bloom filter has an unexpected false negative"));
    };
    ISO.reportFromIssues(guideline, "hub.index", "internal", issues);
  };

  func verifySettlementReport(p : HubPayment) : ValidationReport {
    var issues : [ValidationIssue] = [];
    switch (p.settlement) {
      case null {
        issues := addIssue(issues, ISO.publicIssue("business", "SETTLEMENT-RECORD-MISSING", "$.settlement", "settled ICRC-ME payment must carry a settlement record"));
      };
      case (?s) {
        if (p.status != "settled") {
          issues := addIssue(issues, ISO.publicIssue("business", "SETTLEMENT-STATUS", "$.status", "payment with ICRC-ME settlement record must have settled status"));
        };
        if (s.ledgerBlockIndex == 0 and s.settledAt == 0) {
          issues := addIssue(issues, ISO.publicIssue("business", "SETTLEMENT-BLOCK", "$.settlement.ledgerBlockIndex", "settlement record must carry the finalized ledger block index"));
        };
        if (s.amount.currency != p.pacs008.instructedAmount.currency or s.amount.minorUnits != p.pacs008.instructedAmount.minorUnits) {
          issues := addIssue(issues, ISO.publicIssue("business", "SETTLEMENT-AMOUNT", "$.settlement.amount", "settlement amount must match pacs.008 instructed amount"));
        };
        if (s.debtorAgent != p.pacs008.debtorAgent.bicfi or s.creditorAgent != p.pacs008.creditorAgent.bicfi) {
          issues := addIssue(issues, ISO.publicIssue("business", "SETTLEMENT-PARTICIPANTS", "$.settlement", "settlement participants must match pacs.008 debtor/creditor agents"));
        };
      };
    };
    switch (p.pacs002) {
      case (?ack) {
        if (ack.transactionStatus != "ACSC") {
          issues := addIssue(issues, ISO.publicIssue("business", "SETTLEMENT-PACS002", "$.pacs002.transactionStatus", "ledger-settled payment must attach an ACSC pacs.002"));
        };
      };
      case null {
        issues := addIssue(issues, ISO.publicIssue("business", "SETTLEMENT-PACS002-MISSING", "$.pacs002", "ledger-settled payment must attach a pacs.002 status report"));
      };
    };
    ISO.reportFromIssues(guideline, "settlement.icrc-me", "icrc2.transfer_from", issues);
  };

  func optBlobEq(a : ?Blob, b : ?Blob) : Bool {
    switch (a, b) {
      case (null, null) true;
      case (?x, ?y) x == y;
      case _ false;
    };
  };

  func auditHashesInOrder() : [Blob] {
    Array.tabulate<Blob>(nextAuditId, func(i) {
      switch (Map.get(audits, Nat.compare, i)) {
        case (?rec) rec.recordHash;
        case null "" : Blob;
      };
    });
  };

  func auditMerkleRoot() : ?Blob {
    var level = auditHashesInOrder();
    if (level.size() == 0) return null;
    while (level.size() > 1) {
      level := nextMerkleLevel(level);
    };
    ?level[0];
  };

  func nextMerkleLevel(level : [Blob]) : [Blob] {
    let nextSize = (level.size() + 1) / 2;
    Array.tabulate<Blob>(nextSize, func(i) {
      let left = level[i * 2];
      let right = if (i * 2 + 1 < level.size()) level[i * 2 + 1] else left;
      hashNode(left, right);
    });
  };

  func computeAuditHash(r : AuditRecord) : Blob {
    var preimage : [Nat8] = [0x49, 0x53, 0x4F, 0x32, 0x30, 0x30, 0x32, 0x32]; // ISO20022
    preimage := appendNat(preimage, r.id);
    preimage := appendText(preimage, Int.toText(r.at));
    preimage := appendBlob(preimage, Principal.toBlob(r.caller));
    switch (r.parentHash) {
      case (?p) {
        preimage := Array.concat<Nat8>(preimage, [0x01]);
        preimage := appendBlob(preimage, p);
      };
      case null { preimage := Array.concat<Nat8>(preimage, [0x00]) };
    };
    switch (r.rawXmlHash) {
      case (?h) {
        preimage := Array.concat<Nat8>(preimage, [0x01]);
        preimage := appendBlob(preimage, h);
      };
      case null { preimage := Array.concat<Nat8>(preimage, [0x00]) };
    };
    preimage := appendText(preimage, r.messageKind);
    preimage := appendText(preimage, r.messageVersion);
    preimage := appendText(preimage, r.guidelineId);
    preimage := appendText(preimage, r.businessMessageId);
    preimage := appendText(preimage, r.uetr);
    preimage := Array.concat<Nat8>(preimage, [if (r.ok) 0x01 else 0x00]);
    preimage := appendNat(preimage, r.issueCount);
    for (iss in r.report.issues.vals()) {
      preimage := appendText(preimage, iss.severity);
      preimage := appendText(preimage, iss.tier);
      preimage := appendText(preimage, iss.ruleId);
      preimage := appendText(preimage, iss.path);
      preimage := appendText(preimage, iss.message);
    };
    sha256(preimage);
  };

  func hashNode(left : Blob, right : Blob) : Blob {
    var preimage : [Nat8] = [0x01];
    preimage := appendBlob(preimage, left);
    preimage := appendBlob(preimage, right);
    sha256(preimage);
  };

  func certifiedAuditSnapshotHash(snapshot : CertifiedAuditSnapshot) : Blob {
    var preimage : [Nat8] = [0x43, 0x45, 0x52, 0x54, 0x2D, 0x41, 0x55, 0x44, 0x49, 0x54]; // CERT-AUDIT
    preimage := appendText(preimage, Int.toText(snapshot.capturedAt));
    preimage := appendNat(preimage, snapshot.count);
    preimage := appendOptNat(preimage, snapshot.lastAuditId);
    preimage := appendOptBlob(preimage, snapshot.lastAuditHash);
    preimage := appendOptBlob(preimage, snapshot.merkleRoot);
    preimage := appendOptBlob(preimage, snapshot.mmrRoot);
    preimage := appendNat(preimage, snapshot.mmrLeafCount);
    preimage := appendNat(preimage, snapshot.mmrPeakCount);
    preimage := appendText(preimage, snapshot.guidelineId);
    sha256(preimage);
  };

  func certifiedParticipantBalanceHash(snapshot : CertifiedParticipantBalance) : Blob {
    var preimage : [Nat8] = [0x43, 0x45, 0x52, 0x54, 0x2D, 0x42, 0x41, 0x4C]; // CERT-BAL
    preimage := appendText(preimage, snapshot.bicfi);
    preimage := appendIcrcAccount(preimage, snapshot.account);
    switch (snapshot.ledgerCanister) {
      case (?ledger) {
        preimage := Array.concat<Nat8>(preimage, [0x01]);
        preimage := appendBlob(preimage, Principal.toBlob(ledger));
      };
      case null preimage := Array.concat<Nat8>(preimage, [0x00]);
    };
    preimage := appendOptText(preimage, snapshot.currency);
    preimage := appendNat(preimage, snapshot.balance);
    preimage := appendText(preimage, Int.toText(snapshot.capturedAt));
    sha256(preimage);
  };

  func certifiedBalanceRoot(balances : [CertifiedParticipantBalance]) : Blob {
    if (balances.size() == 0) return zeroCertifiedHash;
    var level = Array.tabulate<Blob>(balances.size(), func(i) { balances[i].snapshotHash });
    while (level.size() > 1) {
      level := nextMerkleLevel(level);
    };
    level[0];
  };

  func certifiedDisclosureRootHash(root : CertifiedDisclosureRoot) : Blob {
    var preimage : [Nat8] = [0x43, 0x45, 0x52, 0x54, 0x2D, 0x44, 0x49, 0x53, 0x43]; // CERT-DISC
    preimage := appendText(preimage, root.version);
    preimage := appendText(preimage, Int.toText(root.updatedAt));
    preimage := appendBlob(preimage, root.auditSnapshotHash);
    preimage := appendBlob(preimage, root.balanceRoot);
    preimage := appendNat(preimage, root.balanceCount);
    sha256(preimage);
  };

  func connectorEnvelopeHash(env : TransportEnvelope, payloadHash : Blob, domain : Text) : Blob {
    var preimage : [Nat8] = [0x49, 0x53, 0x4F, 0x32, 0x32, 0x2D, 0x43, 0x4F, 0x4E, 0x4E]; // ISO22-CONN
    preimage := appendText(preimage, domain);
    preimage := appendText(preimage, env.connectorId);
    preimage := appendText(preimage, env.remoteId);
    preimage := appendNat(preimage, env.sequence);
    preimage := appendText(preimage, env.format);
    preimage := appendBlob(preimage, payloadHash);
    preimage := appendText(preimage, Int.toText(env.sentAt));
    preimage := appendText(preimage, env.traceId);
    switch (env.endpoint) {
      case (?endpoint) {
        preimage := Array.concat<Nat8>(preimage, [0x01]);
        preimage := appendText(preimage, endpoint);
      };
      case null {
        preimage := Array.concat<Nat8>(preimage, [0x00]);
      };
    };
    sha256(preimage);
  };

  func hashBlob(value : Blob) : Blob {
    sha256(Blob.toArray(value));
  };

  func sha256(value : [Nat8]) : Blob {
    Blob.fromArray(hasher.sha256General(value));
  };

  func deriveUetr(caller : Principal, instruction : CustomerCreditTransferInitiation, at : Int) : Text {
    var preimage : [Nat8] = [0x55, 0x45, 0x54, 0x52]; // UETR
    preimage := appendBlob(preimage, Principal.toBlob(caller));
    preimage := appendText(preimage, instruction.messageId);
    preimage := appendText(preimage, instruction.endToEndId);
    preimage := appendText(preimage, Int.toText(at));
    uetrFromHash(sha256(preimage));
  };

  func uetrFromHash(hash : Blob) : Text {
    let src = Blob.toArray(hash);
    let b6 = Nat8.fromNat(64 + (Nat8.toNat(src[6]) % 16));
    let b8 = Nat8.fromNat(128 + (Nat8.toNat(src[8]) % 64));
    let bs = [
      src[0], src[1], src[2], src[3], src[4], src[5], b6, src[7],
      b8, src[9], src[10], src[11], src[12], src[13], src[14], src[15],
    ];
    hexByte(bs[0]) # hexByte(bs[1]) # hexByte(bs[2]) # hexByte(bs[3]) # "-"
      # hexByte(bs[4]) # hexByte(bs[5]) # "-"
      # hexByte(bs[6]) # hexByte(bs[7]) # "-"
      # hexByte(bs[8]) # hexByte(bs[9]) # "-"
      # hexByte(bs[10]) # hexByte(bs[11]) # hexByte(bs[12]) # hexByte(bs[13]) # hexByte(bs[14]) # hexByte(bs[15]);
  };

  func hexByte(b : Nat8) : Text {
    let n = Nat8.toNat(b);
    hexNibble(n / 16) # hexNibble(n % 16);
  };

  func hexNibble(n : Nat) : Text {
    if (n < 10) Nat.toText(n)
    else if (n == 10) "a"
    else if (n == 11) "b"
    else if (n == 12) "c"
    else if (n == 13) "d"
    else if (n == 14) "e"
    else "f";
  };

  func appendText(base : [Nat8], value : Text) : [Nat8] {
    let b = Text.encodeUtf8(value);
    appendBlob(appendNat(base, b.size()), b);
  };

  func appendBlob(base : [Nat8], value : Blob) : [Nat8] {
    Array.concat<Nat8>(appendNat(base, value.size()), Blob.toArray(value));
  };

  func appendOptText(base : [Nat8], value : ?Text) : [Nat8] {
    switch (value) {
      case (?text) appendText(Array.concat<Nat8>(base, [0x01]), text);
      case null Array.concat<Nat8>(base, [0x00]);
    };
  };

  func appendOptBlob(base : [Nat8], value : ?Blob) : [Nat8] {
    switch (value) {
      case (?blob) appendBlob(Array.concat<Nat8>(base, [0x01]), blob);
      case null Array.concat<Nat8>(base, [0x00]);
    };
  };

  func appendOptNat(base : [Nat8], value : ?Nat) : [Nat8] {
    switch (value) {
      case (?n) appendNat(Array.concat<Nat8>(base, [0x01]), n);
      case null Array.concat<Nat8>(base, [0x00]);
    };
  };

  func appendIcrcAccount(base : [Nat8], account : IcrcAccount) : [Nat8] {
    let preimage = appendBlob(base, Principal.toBlob(account.owner));
    appendOptBlob(preimage, account.subaccount);
  };

  func appendNat(base : [Nat8], n : Nat) : [Nat8] {
    if (n == 0) {
      return Array.concat<Nat8>(base, [1 : Nat8, 0 : Nat8]);
    };
    var tmp = n;
    var byteCount : Nat = 0;
    while (tmp > 0) {
      tmp /= 256;
      byteCount += 1;
    };
    let bytes = Array.tabulate<Nat8>(byteCount, func(i) {
      Nat8.fromNat((n / (256 ** (byteCount - 1 - i))) % 256);
    });
    Array.concat<Nat8>(Array.concat<Nat8>(base, [Nat8.fromNat(byteCount)]), bytes);
  };
};
