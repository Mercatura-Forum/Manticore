/// ISO20022.mo -- typed payment-message primitives plus configurable
/// usage-guideline validation for the Thebes ISO 20022 financial hub example.
///
/// This module is deliberately a validator/toolkit layer. Rail-specific market
/// implementation guidelines, code sets, byte caps, and local account rules
/// live in UsageGuideline configuration instead of being baked into code.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";

module {

  public type MessageVersion = {
    kind : Text;
    version : Text;
  };

  public type CurrencyRule = {
    code : Text;
    numeric : Nat;
    fractionDigits : Nat;
  };

  public type UsageGuideline = {
    id : Text;
    authority : Text;
    description : Text;
    messageVersions : [MessageVersion];
    currencies : [CurrencyRule];
    countryCodes : [Text];
    purposeCodes : [Text];
    categoryPurposeCodes : [Text];
    maxMessageBytes : Nat;
    requireBusinessApplicationHeader : Bool;
    requireUetr : Bool;
    settlementMethod : Text;
    oneTransactionPerPacs008 : Bool;
    characterSet : Text;
    requiredAgentCountry : ?Text;
    requiredIbanCountry : ?Text;
    requireAccountCurrencyMatchesInstructed : Bool;
    requireBahBusinessMessageIdMatchesMessageId : Bool;
    allowedClearingSystems : [Text];
  };

  public type ActiveCurrencyAndAmount = {
    currency : Text;
    minorUnits : Nat;
  };

  public type PostalAddress = {
    country : Text;
    townName : Text;
    addressLine : [Text];
    postalCode : ?Text;
  };

  public type PartyIdentification = {
    name : Text;
    postalAddress : ?PostalAddress;
    lei : ?Text;
  };

  public type CashAccount = {
    iban : ?Text;
    otherId : ?Text;
    currency : ?Text;
  };

  public type FinancialInstitutionIdentification = {
    bicfi : Text;
    name : ?Text;
  };

  public type SettlementInstruction = {
    settlementMethod : Text;
    clearingSystem : ?Text;
  };

  public type PaymentTypeInformation = {
    serviceLevel : ?Text;
    localInstrument : ?Text;
    categoryPurpose : ?Text;
  };

  public type RemittanceInformation = {
    unstructured : [Text];
    structuredCreditorReference : ?Text;
  };

  public type BusinessApplicationHeader = {
    fromBic : Text;
    toBic : Text;
    businessMessageId : Text;
    messageDefinitionId : Text;
    businessService : ?Text;
    creationDateTime : Text;
    uetr : ?Text;
  };

  public type CustomerCreditTransferInitiation = {
    messageId : Text;
    creationDateTime : Text;
    requestedExecutionDate : ?Text;
    initiatingParty : PartyIdentification;
    debtor : PartyIdentification;
    debtorAccount : CashAccount;
    debtorAgent : FinancialInstitutionIdentification;
    creditor : PartyIdentification;
    creditorAccount : CashAccount;
    creditorAgent : FinancialInstitutionIdentification;
    paymentTypeInformation : ?PaymentTypeInformation;
    instructedAmount : ActiveCurrencyAndAmount;
    endToEndId : Text;
    remittanceInformation : RemittanceInformation;
    requestedUetr : ?Text;
  };

  public type Pacs008CreditTransfer = {
    businessApplicationHeader : ?BusinessApplicationHeader;
    messageId : Text;
    creationDateTime : Text;
    settlementInstruction : SettlementInstruction;
    paymentTypeInformation : ?PaymentTypeInformation;
    uetr : ?Text;
    endToEndId : Text;
    instructedAmount : ActiveCurrencyAndAmount;
    debtor : PartyIdentification;
    debtorAccount : CashAccount;
    debtorAgent : FinancialInstitutionIdentification;
    creditor : PartyIdentification;
    creditorAccount : CashAccount;
    creditorAgent : FinancialInstitutionIdentification;
    remittanceInformation : RemittanceInformation;
    transactionCount : Nat;
  };

  public type Charge = {
    amount : ActiveCurrencyAndAmount;
    agent : FinancialInstitutionIdentification;
    typeCode : ?Text;
  };

  public type FxDetails = {
    sourceCurrency : Text;
    targetCurrency : Text;
    exchangeRateE8s : Nat;
    quoteId : ?Text;
    quoteExpiry : ?Text;
    settlementAmount : ActiveCurrencyAndAmount;
  };

  public type RegulatoryReporting = {
    authorityCountry : ?Text;
    reportingCode : ?Text;
    details : [Text];
  };

  public type CrossBorderRouting = {
    chargeBearer : Text;
    charges : [Charge];
    instructingAgent : FinancialInstitutionIdentification;
    instructedAgent : FinancialInstitutionIdentification;
    intermediaryAgents : [FinancialInstitutionIdentification];
    settlementDate : ?Text;
    fx : ?FxDetails;
    regulatoryReporting : [RegulatoryReporting];
  };

  public type Pacs009FinancialInstitutionCreditTransfer = {
    businessApplicationHeader : ?BusinessApplicationHeader;
    messageId : Text;
    creationDateTime : Text;
    settlementInstruction : SettlementInstruction;
    uetr : ?Text;
    instructionId : Text;
    endToEndId : Text;
    instructedAmount : ActiveCurrencyAndAmount;
    debtorAgent : FinancialInstitutionIdentification;
    creditorAgent : FinancialInstitutionIdentification;
    debtorInstitution : FinancialInstitutionIdentification;
    creditorInstitution : FinancialInstitutionIdentification;
    routing : CrossBorderRouting;
    isCover : Bool;
    underlyingPacs008MessageId : ?Text;
    transactionCount : Nat;
  };

  public type CoverPayment = {
    directMessage : Pacs008CreditTransfer;
    coverMessage : Pacs009FinancialInstitutionCreditTransfer;
    method : Text;
  };

  public type InvestigationMessage = {
    messageKind : Text;
    messageVersion : Text;
    messageId : Text;
    creationDateTime : Text;
    assignmentId : Text;
    originalMessageId : Text;
    originalUetr : ?Text;
    reasonCode : Text;
    requestedAction : ?Text;
    additionalInfo : [Text];
  };

  public type ComplianceProfile = {
    id : Text;
    description : Text;
    blockedCountries : [Text];
    highRiskCountries : [Text];
    blockedBics : [Text];
    blockedNameFragments : [Text];
    highValueThresholdMinorUnits : Nat;
    requireOriginatorAndBeneficiaryAddress : Bool;
    requireRegulatoryReportingForCrossBorder : Bool;
    requirePurposeForCrossBorder : Bool;
    requireFxForCurrencyConversion : Bool;
    maxIntermediaryAgents : Nat;
    allowedChargeBearers : [Text];
  };

  public type ComplianceFinding = {
    severity : Text;
    ruleId : Text;
    path : Text;
    message : Text;
    action : Text;
    score : Nat;
  };

  public type ComplianceReport = {
    ok : Bool;
    decision : Text;
    profileId : Text;
    riskScore : Nat;
    findingCount : Nat;
    findings : [ComplianceFinding];
  };

  public type StatusReport = {
    messageKind : Text;
    messageVersion : Text;
    messageId : Text;
    originalMessageId : Text;
    originalUetr : Text;
    transactionStatus : Text;
    reason : ?Text;
    creationDateTime : Text;
  };

  public type RequestToPayMessage = {
    messageKind : Text;
    messageVersion : Text;
    messageId : Text;
    creationDateTime : Text;
    requestId : Text;
    originalRequestId : ?Text;
    debtor : PartyIdentification;
    debtorAccount : CashAccount;
    debtorAgent : FinancialInstitutionIdentification;
    creditor : PartyIdentification;
    creditorAccount : CashAccount;
    creditorAgent : FinancialInstitutionIdentification;
    requestedAmount : ActiveCurrencyAndAmount;
    requestedExecutionDate : ?Text;
    chargeBearer : ?Text;
    status : ?Text;
    reason : ?Text;
    remittanceInformation : RemittanceInformation;
  };

  public type DirectDebitMessage = {
    messageKind : Text;
    messageVersion : Text;
    businessApplicationHeader : ?BusinessApplicationHeader;
    messageId : Text;
    creationDateTime : Text;
    settlementInstruction : ?SettlementInstruction;
    requestedCollectionDate : ?Text;
    initiatingParty : PartyIdentification;
    creditor : PartyIdentification;
    creditorAccount : CashAccount;
    creditorAgent : FinancialInstitutionIdentification;
    debtor : PartyIdentification;
    debtorAccount : CashAccount;
    debtorAgent : FinancialInstitutionIdentification;
    paymentTypeInformation : ?PaymentTypeInformation;
    instructedAmount : ActiveCurrencyAndAmount;
    endToEndId : Text;
    mandateId : Text;
    mandateSignatureDate : ?Text;
    sequenceType : Text;
    remittanceInformation : RemittanceInformation;
    uetr : ?Text;
    transactionCount : Nat;
  };

  public type AdministrativeMessage = {
    messageKind : Text;
    messageVersion : Text;
    messageId : Text;
    creationDateTime : Text;
    relatedMessageId : ?Text;
    relatedUetr : ?Text;
    eventCode : Text;
    status : Text;
    reason : ?Text;
    additionalInfo : [Text];
  };

  public type StatementEntry = {
    entryId : Text;
    paymentId : Nat;
    uetr : Text;
    accountIban : ?Text;
    accountOtherId : ?Text;
    amount : ActiveCurrencyAndAmount;
    creditDebit : Text;
    status : Text;
    bookedAt : Int;
    counterpartyName : Text;
    remittance : [Text];
  };

  public type ValidationIssue = {
    severity : Text;
    tier : Text;
    ruleId : Text;
    path : Text;
    message : Text;
  };

  public type ValidationReport = {
    ok : Bool;
    guidelineId : Text;
    messageKind : Text;
    messageVersion : Text;
    issueCount : Nat;
    issues : [ValidationIssue];
  };

  public type PhaseVerification = {
    phase : Text;
    ok : Bool;
    issueCount : Nat;
    issues : [ValidationIssue];
  };

  public func defaultGuideline() : UsageGuideline {
    {
      id = "EGYPT-ISO20022-HUB-EDU-BASELINE-2026-06-22";
      authority = "Open Egyptian banking integration template";
      description = "Public educational baseline for ISO 20022 credit-transfer hub validation for Egyptian bank integrations. Replace with a bank, rail, or scheme-specific usage guideline in production.";
      messageVersions = [
        { kind = "head.001"; version = "head.001.001.02" },
        { kind = "pain.001"; version = "pain.001.001.09" },
        { kind = "pain.002"; version = "pain.002.001.10" },
        { kind = "pain.008"; version = "pain.008.001.08" },
        { kind = "pain.013"; version = "pain.013.001.10" },
        { kind = "pain.014"; version = "pain.014.001.10" },
        { kind = "pacs.008"; version = "pacs.008.001.08" },
        { kind = "pacs.003"; version = "pacs.003.001.08" },
        { kind = "pacs.009"; version = "pacs.009.001.08" },
        { kind = "pacs.002"; version = "pacs.002.001.10" },
        { kind = "pacs.004"; version = "pacs.004.001.09" },
        { kind = "pacs.028"; version = "pacs.028.001.03" },
        { kind = "camt.029"; version = "camt.029.001.09" },
        { kind = "camt.055"; version = "camt.055.001.09" },
        { kind = "camt.056"; version = "camt.056.001.08" },
        { kind = "camt.110"; version = "camt.110.001.01" },
        { kind = "camt.111"; version = "camt.111.001.01" },
        { kind = "admi.002"; version = "admi.002.001.01" },
        { kind = "admi.004"; version = "admi.004.001.01" },
        { kind = "admi.007"; version = "admi.007.001.01" },
        { kind = "admi.011"; version = "admi.011.001.01" },
        { kind = "camt.053"; version = "camt.053.001.08" },
        { kind = "camt.054"; version = "camt.054.001.08" },
      ];
      currencies = [
        { code = "EGP"; numeric = 818; fractionDigits = 2 },
        { code = "USD"; numeric = 840; fractionDigits = 2 },
        { code = "EUR"; numeric = 978; fractionDigits = 2 },
        { code = "GBP"; numeric = 826; fractionDigits = 2 },
      ];
      countryCodes = ["EG", "AE", "SA", "GB", "US", "DE", "FR"];
      purposeCodes = [];
      categoryPurposeCodes = ["CASH", "CORT", "SALA", "TREA", "SUPP", "TAXS"];
      maxMessageBytes = 80_000;
      requireBusinessApplicationHeader = true;
      requireUetr = true;
      settlementMethod = "CLRG";
      oneTransactionPerPacs008 = true;
      characterSet = "SWIFT-X";
      requiredAgentCountry = ?"EG";
      requiredIbanCountry = ?"EG";
      requireAccountCurrencyMatchesInstructed = true;
      requireBahBusinessMessageIdMatchesMessageId = true;
      allowedClearingSystems = [];
    };
  };

  public func crossBorderEducationGuideline() : UsageGuideline {
    let base = defaultGuideline();
    {
      base with
      id = "CBPRPLUS-EDU-CROSSBORDER-BASELINE-2026-06-22";
      authority = "Open cross-border payments education template";
      description = "Public educational baseline for cross-border ISO 20022 payment validation. Use official CBPR+, HVPS+, bank, or rail usage guidelines as production overlays.";
      requiredAgentCountry = null;
      requiredIbanCountry = null;
      settlementMethod = "INDA";
      allowedClearingSystems = [];
      countryCodes = ["EG", "AE", "SA", "GB", "US", "DE", "FR", "CH", "JP", "CN", "SG", "ZA"];
    };
  };

  public func defaultComplianceProfile() : ComplianceProfile {
    {
      id = "AML-CFT-EDU-RISK-BASELINE-2026-06-22";
      description = "Deterministic education profile for payment transparency, sanctions-list hooks, high-risk corridor flags, and audit evidence. Not a substitute for licensed sanctions/AML data.";
      blockedCountries = [];
      highRiskCountries = [];
      blockedBics = [];
      blockedNameFragments = [];
      highValueThresholdMinorUnits = 100_000_000_00;
      requireOriginatorAndBeneficiaryAddress = true;
      requireRegulatoryReportingForCrossBorder = true;
      requirePurposeForCrossBorder = true;
      requireFxForCurrencyConversion = true;
      maxIntermediaryAgents = 3;
      allowedChargeBearers = ["DEBT", "CRED", "SHAR", "SLEV"];
    };
  };

  public func demoPain001() : CustomerCreditTransferInitiation {
    {
      messageId = "ISO-HUB-20260622-000001";
      creationDateTime = "2026-06-22T10:00:00Z";
      requestedExecutionDate = ?"2026-06-22";
      initiatingParty = {
        name = "Example Egypt Treasury Desk";
        postalAddress = ?{
          country = "EG";
          townName = "Cairo";
          addressLine = ["1 Nile Corniche"];
          postalCode = ?"11511";
        };
        lei = null;
      };
      debtor = {
        name = "Example Debtor SAE";
        postalAddress = ?{
          country = "EG";
          townName = "Cairo";
          addressLine = ["1 Nile Corniche"];
          postalCode = ?"11511";
        };
        lei = null;
      };
      debtorAccount = { iban = ?"EG380019000500000000263180002"; otherId = null; currency = ?"EGP" };
      debtorAgent = { bicfi = "EGBKEGCX"; name = ?"Egypt Example Bank" };
      creditor = {
        name = "Example Creditor LLC";
        postalAddress = ?{
          country = "EG";
          townName = "Alexandria";
          addressLine = ["10 Port Road"];
          postalCode = ?"21519";
        };
        lei = null;
      };
      creditorAccount = { iban = ?"EG800002000156789012345180002"; otherId = null; currency = ?"EGP" };
      creditorAgent = { bicfi = "EXBKEGCX"; name = ?"Example Bank Egypt" };
      paymentTypeInformation = ?{
        serviceLevel = ?"URGP";
        localInstrument = ?"RTGS";
        categoryPurpose = ?"CORT";
      };
      instructedAmount = { currency = "EGP"; minorUnits = 1_250_000 };
      endToEndId = "E2E-20260622-000001";
      remittanceInformation = {
        unstructured = ["Invoice INV-2026-001"];
        structuredCreditorReference = null;
      };
      requestedUetr = ?"8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
    };
  };

  public func demoCrossBorderPain001() : CustomerCreditTransferInitiation {
    let base = demoPain001();
    {
      base with
      messageId = "CBPR-EDU-20260622-000001";
      debtorAccount = { iban = ?"EG380019000500000000263180002"; otherId = null; currency = ?"USD" };
      creditor = {
        name = "Example Creditor GmbH";
        postalAddress = ?{
          country = "DE";
          townName = "Berlin";
          addressLine = ["10 Market Platz"];
          postalCode = ?"10115";
        };
        lei = null;
      };
      creditorAccount = { iban = ?"DE89370400440532013000"; otherId = null; currency = ?"USD" };
      creditorAgent = { bicfi = "DEUTDEFF"; name = ?"Deutsche Example Bank" };
      instructedAmount = { currency = "USD"; minorUnits = 250_000 };
      endToEndId = "E2E-CBPR-20260622-000001";
      requestedUetr = ?"a12b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
    };
  };

  public func demoPacs008() : Pacs008CreditTransfer {
    pacs008FromPain001(defaultGuideline(), demoPain001(), "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011", "2026-06-22T10:00:00Z");
  };

  public func demoCrossBorderPacs008() : Pacs008CreditTransfer {
    pacs008FromPain001(crossBorderEducationGuideline(), demoCrossBorderPain001(), "a12b5e70-1d44-4e6a-9c4a-2d9c87fd0011", "2026-06-22T10:05:00Z");
  };

  public func demoPacs009Core() : Pacs009FinancialInstitutionCreditTransfer {
    let g = crossBorderEducationGuideline();
    let uetr = "b22b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
    let header : BusinessApplicationHeader = {
      fromBic = "EGBKEGCX";
      toBic = "DEUTDEFF";
      businessMessageId = "PACS009-CORE-20260622-000001";
      messageDefinitionId = versionOf(g, "pacs.009");
      businessService = ?"CBPRPLUS.EDU";
      creationDateTime = "2026-06-22T10:10:00Z";
      uetr = ?uetr;
    };
    {
      businessApplicationHeader = ?header;
      messageId = "PACS009-CORE-20260622-000001";
      creationDateTime = "2026-06-22T10:10:00Z";
      settlementInstruction = { settlementMethod = "INDA"; clearingSystem = null };
      uetr = ?uetr;
      instructionId = "INST-CBPR-20260622-000001";
      endToEndId = "E2E-CBPR-20260622-000001";
      instructedAmount = { currency = "USD"; minorUnits = 250_000 };
      debtorAgent = { bicfi = "EGBKEGCX"; name = ?"Egypt Example Bank" };
      creditorAgent = { bicfi = "DEUTDEFF"; name = ?"Deutsche Example Bank" };
      debtorInstitution = { bicfi = "EGBKEGCX"; name = ?"Egypt Example Bank Treasury" };
      creditorInstitution = { bicfi = "DEUTDEFF"; name = ?"Deutsche Example Bank Treasury" };
      routing = {
        chargeBearer = "SHAR";
        charges = [
          { amount = { currency = "USD"; minorUnits = 1_500 }; agent = { bicfi = "CHASUS33"; name = ?"US Correspondent Example" }; typeCode = ?"COMM" }
        ];
        instructingAgent = { bicfi = "EGBKEGCX"; name = ?"Egypt Example Bank" };
        instructedAgent = { bicfi = "DEUTDEFF"; name = ?"Deutsche Example Bank" };
        intermediaryAgents = [{ bicfi = "CHASUS33"; name = ?"US Correspondent Example" }];
        settlementDate = ?"2026-06-22";
        fx = ?{
          sourceCurrency = "EGP";
          targetCurrency = "USD";
          exchangeRateE8s = 2_050_000;
          quoteId = ?"FXQ-20260622-000001";
          quoteExpiry = ?"2026-06-22T12:00:00Z";
          settlementAmount = { currency = "USD"; minorUnits = 250_000 };
        };
        regulatoryReporting = [
          { authorityCountry = ?"EG"; reportingCode = ?"CORT"; details = ["Commercial invoice settlement"] }
        ];
      };
      isCover = false;
      underlyingPacs008MessageId = null;
      transactionCount = 1;
    };
  };

  public func demoCoverPayment() : CoverPayment {
    let direct = demoCrossBorderPacs008();
    let core = demoPacs009Core();
    let linkedHeader = switch (core.businessApplicationHeader, direct.uetr) {
      case (?h, ?u) ?{ h with businessMessageId = "PACS009-COV-20260622-000001"; uetr = ?u };
      case (?h, null) ?{ h with businessMessageId = "PACS009-COV-20260622-000001" };
      case (null, _) null;
    };
    let cover = {
      core with
      businessApplicationHeader = linkedHeader;
      isCover = true;
      messageId = "PACS009-COV-20260622-000001";
      uetr = direct.uetr;
      underlyingPacs008MessageId = ?direct.messageId;
    };
    { directMessage = direct; coverMessage = cover; method = "COVER" };
  };

  public func demoCamt056() : InvestigationMessage {
    {
      messageKind = "camt.056";
      messageVersion = versionOf(crossBorderEducationGuideline(), "camt.056");
      messageId = "CAMT056-20260622-000001";
      creationDateTime = "2026-06-22T10:30:00Z";
      assignmentId = "ASSIGN-CANCEL-000001";
      originalMessageId = "CBPR-EDU-20260622-000001";
      originalUetr = ?"a12b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
      reasonCode = "CUST";
      requestedAction = ?"CANCEL";
      additionalInfo = ["Customer requested cancellation before settlement"];
    };
  };

  public func demoCamt029() : InvestigationMessage {
    {
      messageKind = "camt.029";
      messageVersion = versionOf(crossBorderEducationGuideline(), "camt.029");
      messageId = "CAMT029-20260622-000001";
      creationDateTime = "2026-06-22T10:35:00Z";
      assignmentId = "ASSIGN-RESOLVE-000001";
      originalMessageId = "CAMT056-20260622-000001";
      originalUetr = ?"a12b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
      reasonCode = "ACCP";
      requestedAction = ?"CANCELLATION ACCEPTED";
      additionalInfo = ["Cancellation accepted by instructed agent"];
    };
  };

  public func demoPacs028() : InvestigationMessage {
    {
      messageKind = "pacs.028";
      messageVersion = versionOf(crossBorderEducationGuideline(), "pacs.028");
      messageId = "PACS028-20260622-000001";
      creationDateTime = "2026-06-22T10:40:00Z";
      assignmentId = "ASSIGN-STATUS-000001";
      originalMessageId = "CBPR-EDU-20260622-000001";
      originalUetr = ?"a12b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
      reasonCode = "STAT";
      requestedAction = ?"REQUEST STATUS";
      additionalInfo = ["Request latest payment status"];
    };
  };

  public func demoCamt110() : InvestigationMessage {
    {
      messageKind = "camt.110";
      messageVersion = versionOf(crossBorderEducationGuideline(), "camt.110");
      messageId = "CAMT110-20260622-000001";
      creationDateTime = "2026-06-22T10:50:00Z";
      assignmentId = "CASE-INVESTIGATE-000001";
      originalMessageId = "CBPR-EDU-20260622-000001";
      originalUetr = ?"a12b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
      reasonCode = "INFO";
      requestedAction = ?"INVESTIGATE";
      additionalInfo = ["Structured case-management investigation request"];
    };
  };

  public func demoCamt111() : InvestigationMessage {
    {
      messageKind = "camt.111";
      messageVersion = versionOf(crossBorderEducationGuideline(), "camt.111");
      messageId = "CAMT111-20260622-000001";
      creationDateTime = "2026-06-22T10:55:00Z";
      assignmentId = "CASE-RESPONSE-000001";
      originalMessageId = "CAMT110-20260622-000001";
      originalUetr = ?"a12b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
      reasonCode = "INFO";
      requestedAction = ?"RESPOND";
      additionalInfo = ["Structured case-management investigation response"];
    };
  };

  public func demoPain013() : RequestToPayMessage {
    let base = demoCrossBorderPain001();
    {
      messageKind = "pain.013";
      messageVersion = versionOf(crossBorderEducationGuideline(), "pain.013");
      messageId = "PAIN013-20260622-000001";
      creationDateTime = "2026-06-22T10:45:00Z";
      requestId = "RFP-20260622-000001";
      originalRequestId = null;
      debtor = base.debtor;
      debtorAccount = base.debtorAccount;
      debtorAgent = base.debtorAgent;
      creditor = base.creditor;
      creditorAccount = base.creditorAccount;
      creditorAgent = base.creditorAgent;
      requestedAmount = base.instructedAmount;
      requestedExecutionDate = base.requestedExecutionDate;
      chargeBearer = ?"SHAR";
      status = null;
      reason = null;
      remittanceInformation = base.remittanceInformation;
    };
  };

  public func demoPain014Accepted() : RequestToPayMessage {
    let req = demoPain013();
    {
      req with
      messageKind = "pain.014";
      messageVersion = versionOf(crossBorderEducationGuideline(), "pain.014");
      messageId = "PAIN014-20260622-000001";
      creationDateTime = "2026-06-22T10:46:00Z";
      originalRequestId = ?req.requestId;
      status = ?"ACTC";
      reason = null;
    };
  };

  public func demoCamt055() : RequestToPayMessage {
    let req = demoPain013();
    {
      req with
      messageKind = "camt.055";
      messageVersion = versionOf(crossBorderEducationGuideline(), "camt.055");
      messageId = "CAMT055-20260622-000001";
      creationDateTime = "2026-06-22T10:47:00Z";
      originalRequestId = ?req.requestId;
      status = ?"CANC";
      reason = ?"payer requested cancellation";
    };
  };

  public func demoPain008() : DirectDebitMessage {
    let g = crossBorderEducationGuideline();
    {
      messageKind = "pain.008";
      messageVersion = versionOf(g, "pain.008");
      businessApplicationHeader = null;
      messageId = "PAIN008-20260622-000001";
      creationDateTime = "2026-06-22T11:00:00Z";
      settlementInstruction = null;
      requestedCollectionDate = ?"2026-06-25";
      initiatingParty = {
        name = "Example Creditor GmbH";
        postalAddress = ?{ country = "DE"; townName = "Berlin"; addressLine = ["10 Market Platz"]; postalCode = ?"10115" };
        lei = ?"529900T8BM49AURSDO55";
      };
      creditor = {
        name = "Example Creditor GmbH";
        postalAddress = ?{ country = "DE"; townName = "Berlin"; addressLine = ["10 Market Platz"]; postalCode = ?"10115" };
        lei = ?"529900T8BM49AURSDO55";
      };
      creditorAccount = { iban = ?"DE89370400440532013000"; otherId = null; currency = ?"EUR" };
      creditorAgent = { bicfi = "DEUTDEFF"; name = ?"Deutsche Example Bank" };
      debtor = {
        name = "Example Debtor SAS";
        postalAddress = ?{ country = "FR"; townName = "Paris"; addressLine = ["5 Rue Example"]; postalCode = ?"75001" };
        lei = null;
      };
      debtorAccount = { iban = ?"FR1420041010050500013M02606"; otherId = null; currency = ?"EUR" };
      debtorAgent = { bicfi = "BNPAFRPP"; name = ?"BNP Example Bank" };
      paymentTypeInformation = ?{ serviceLevel = ?"SEPA"; localInstrument = ?"CORE"; categoryPurpose = ?"SUPP" };
      instructedAmount = { currency = "EUR"; minorUnits = 12_500 };
      endToEndId = "E2E-SDD-20260622-000001";
      mandateId = "MANDATE-20260622-000001";
      mandateSignatureDate = ?"2026-01-15";
      sequenceType = "RCUR";
      remittanceInformation = { unstructured = ["SEPA direct debit education fixture"]; structuredCreditorReference = null };
      uetr = null;
      transactionCount = 1;
    };
  };

  public func demoPacs003() : DirectDebitMessage {
    let pain = demoPain008();
    let header : BusinessApplicationHeader = {
      fromBic = pain.creditorAgent.bicfi;
      toBic = pain.debtorAgent.bicfi;
      businessMessageId = "PACS003-20260622-000001";
      messageDefinitionId = versionOf(crossBorderEducationGuideline(), "pacs.003");
      businessService = ?"SEPA-SDD-EDU";
      creationDateTime = "2026-06-22T11:05:00Z";
      uetr = ?"b62b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
    };
    {
      pain with
      messageKind = "pacs.003";
      messageVersion = versionOf(crossBorderEducationGuideline(), "pacs.003");
      businessApplicationHeader = ?header;
      messageId = "PACS003-20260622-000001";
      creationDateTime = "2026-06-22T11:05:00Z";
      settlementInstruction = ?{ settlementMethod = "INDA"; clearingSystem = null };
      uetr = ?"b62b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
    };
  };

  public func demoAdmi002Reject() : AdministrativeMessage {
    {
      messageKind = "admi.002";
      messageVersion = versionOf(crossBorderEducationGuideline(), "admi.002");
      messageId = "ADMI002-20260622-000001";
      creationDateTime = "2026-06-22T11:10:00Z";
      relatedMessageId = ?"PACS003-20260622-000001";
      relatedUetr = ?"b62b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
      eventCode = "RJCT";
      status = "RJCT";
      reason = ?"schema or profile validation failed";
      additionalInfo = ["Administrative reject fixture"];
    };
  };

  public func demoAdmi004ConnectionCheck() : AdministrativeMessage {
    {
      messageKind = "admi.004";
      messageVersion = versionOf(crossBorderEducationGuideline(), "admi.004");
      messageId = "ADMI004-20260622-000001";
      creationDateTime = "2026-06-22T11:11:00Z";
      relatedMessageId = null;
      relatedUetr = null;
      eventCode = "CONN";
      status = "INFO";
      reason = null;
      additionalInfo = ["Connection check fixture"];
    };
  };

  public func demoAdmi007Ack() : AdministrativeMessage {
    {
      messageKind = "admi.007";
      messageVersion = versionOf(crossBorderEducationGuideline(), "admi.007");
      messageId = "ADMI007-20260622-000001";
      creationDateTime = "2026-06-22T11:12:00Z";
      relatedMessageId = ?"PAIN013-20260622-000001";
      relatedUetr = null;
      eventCode = "RCVD";
      status = "ACK";
      reason = null;
      additionalInfo = ["Administrative receipt acknowledgement fixture"];
    };
  };

  public func demoAdmi011ConnectionAck() : AdministrativeMessage {
    {
      messageKind = "admi.011";
      messageVersion = versionOf(crossBorderEducationGuideline(), "admi.011");
      messageId = "ADMI011-20260622-000001";
      creationDateTime = "2026-06-22T11:13:00Z";
      relatedMessageId = ?"ADMI004-20260622-000001";
      relatedUetr = null;
      eventCode = "CONN";
      status = "ACK";
      reason = null;
      additionalInfo = ["Connection check acknowledged fixture"];
    };
  };

  public func pacs008FromPain001(
    g : UsageGuideline,
    pain : CustomerCreditTransferInitiation,
    uetr : Text,
    creationDateTime : Text,
  ) : Pacs008CreditTransfer {
    let version = switch (messageVersion(g, "pacs.008")) { case (?v) v; case null "pacs.008" };
    let header : BusinessApplicationHeader = {
      fromBic = pain.debtorAgent.bicfi;
      toBic = pain.creditorAgent.bicfi;
      businessMessageId = pain.messageId;
      messageDefinitionId = version;
      businessService = ?"OPEN.ISO20022.HUB";
      creationDateTime;
      uetr = ?uetr;
    };
    {
      businessApplicationHeader = ?header;
      messageId = pain.messageId;
      creationDateTime;
      settlementInstruction = { settlementMethod = g.settlementMethod; clearingSystem = null };
      paymentTypeInformation = pain.paymentTypeInformation;
      uetr = ?uetr;
      endToEndId = pain.endToEndId;
      instructedAmount = pain.instructedAmount;
      debtor = pain.debtor;
      debtorAccount = pain.debtorAccount;
      debtorAgent = pain.debtorAgent;
      creditor = pain.creditor;
      creditorAccount = pain.creditorAccount;
      creditorAgent = pain.creditorAgent;
      remittanceInformation = pain.remittanceInformation;
      transactionCount = 1;
    };
  };

  public func pain002FromValidation(
    g : UsageGuideline,
    messageId : Text,
    originalMessageId : Text,
    originalUetr : Text,
    creationDateTime : Text,
    report : ValidationReport,
  ) : StatusReport {
    {
      messageKind = "pain.002";
      messageVersion = versionOf(g, "pain.002");
      messageId;
      originalMessageId;
      originalUetr;
      transactionStatus = if (report.ok) "ACTC" else "RJCT";
      reason = if (report.ok) null else ?"validation failed";
      creationDateTime;
    };
  };

  public func pacs002(
    g : UsageGuideline,
    messageId : Text,
    originalMessageId : Text,
    originalUetr : Text,
    transactionStatus : Text,
    reason : ?Text,
    creationDateTime : Text,
  ) : StatusReport {
    {
      messageKind = "pacs.002";
      messageVersion = versionOf(g, "pacs.002");
      messageId;
      originalMessageId;
      originalUetr;
      transactionStatus;
      reason;
      creationDateTime;
    };
  };

  public func pacs004(
    g : UsageGuideline,
    messageId : Text,
    originalMessageId : Text,
    originalUetr : Text,
    reason : Text,
    creationDateTime : Text,
  ) : StatusReport {
    {
      messageKind = "pacs.004";
      messageVersion = versionOf(g, "pacs.004");
      messageId;
      originalMessageId;
      originalUetr;
      transactionStatus = "RJCT";
      reason = ?reason;
      creationDateTime;
    };
  };

  public func validatePain001(g : UsageGuideline, doc : CustomerCreditTransferInitiation, rawXml : ?Blob) : ValidationReport {
    let version = versionOf(g, "pain.001");
    var issues : [ValidationIssue] = [];

    issues := validateRawXml(g, rawXml, issues);
    issues := validateMax35Ret(doc.messageId, "$.messageId", "GrpHdr-MsgId", issues);
    issues := validateIsoDateTime(doc.creationDateTime, "$.creationDateTime", "GrpHdr-CreDtTm", issues);
    switch (doc.requestedExecutionDate) {
      case (?d) { issues := validateIsoDate(d, "$.requestedExecutionDate", "ReqdExctnDt", issues) };
      case null {};
    };
    issues := validateParty(g, doc.initiatingParty, "$.initiatingParty", issues);
    issues := validateParty(g, doc.debtor, "$.debtor", issues);
    issues := validateAccount(g, doc.debtorAccount, doc.instructedAmount.currency, "$.debtorAccount", issues);
    issues := validateAgent(g, doc.debtorAgent, "$.debtorAgent", issues);
    issues := validateParty(g, doc.creditor, "$.creditor", issues);
    issues := validateAccount(g, doc.creditorAccount, doc.instructedAmount.currency, "$.creditorAccount", issues);
    issues := validateAgent(g, doc.creditorAgent, "$.creditorAgent", issues);
    issues := validatePaymentType(g, doc.paymentTypeInformation, issues);
    issues := validateAmount(g, doc.instructedAmount, "$.instructedAmount", issues);
    issues := validateMax35Ret(doc.endToEndId, "$.endToEndId", "PmtId-EndToEndId", issues);
    issues := validateRemittance(doc.remittanceInformation, issues);
    switch (doc.requestedUetr) {
      case (?u) {
        if (not validUetr(u)) {
          issues := add(issues, publicIssue("schema", "UETR-FORMAT", "$.requestedUetr", "requested UETR must be an RFC 4122 UUID version 4 value"));
        };
      };
      case null {};
    };

    reportFromIssues(g, "pain.001", version, issues);
  };

  public func validatePacs008(g : UsageGuideline, doc : Pacs008CreditTransfer, rawXml : ?Blob) : ValidationReport {
    let version = versionOf(g, "pacs.008");
    var issues : [ValidationIssue] = [];

    issues := validateRawXml(g, rawXml, issues);

    if (g.requireBusinessApplicationHeader) {
      switch (doc.businessApplicationHeader) {
        case null {
          issues := add(issues, publicIssue("schema", "HEAD001-REQUIRED", "$.businessApplicationHeader", "Business Application Header is required by this guideline"));
        };
        case (?h) {
          issues := validateHeader(g, h, doc.messageId, version, issues);
          switch (h.uetr, doc.uetr) {
            case (?a, ?b) {
              if (a != b) {
                issues := add(issues, publicIssue("business", "UETR-CONSISTENCY", "$.businessApplicationHeader.uetr", "BAH UETR must match the pacs.008 transaction UETR"));
              };
            };
            case _ {};
          };
        };
      };
    };

    issues := validateMax35Ret(doc.messageId, "$.messageId", "GrpHdr-MsgId", issues);
    issues := validateIsoDateTime(doc.creationDateTime, "$.creationDateTime", "GrpHdr-CreDtTm", issues);

    if (g.oneTransactionPerPacs008 and doc.transactionCount != 1) {
      issues := add(issues, publicIssue("usageGuideline", "PACS008-ONE-TX", "$.transactionCount", "pacs.008 must contain exactly one credit transfer transaction for this guideline"));
    };
    if (doc.settlementInstruction.settlementMethod != g.settlementMethod) {
      issues := add(issues, publicIssue("usageGuideline", "STTLM-MTD", "$.settlementInstruction.settlementMethod", "settlement method must be " # g.settlementMethod));
    };
    switch (doc.settlementInstruction.clearingSystem) {
      case (?cs) {
        if (g.allowedClearingSystems.size() > 0 and not containsText(g.allowedClearingSystems, cs)) {
          issues := add(issues, publicIssue("usageGuideline", "CLRSYS-ACTIVE", "$.settlementInstruction.clearingSystem", "clearing system is not enabled in the active guideline"));
        };
      };
      case null {
        if (g.allowedClearingSystems.size() > 0) {
          issues := add(issues, publicIssue("usageGuideline", "CLRSYS-REQUIRED", "$.settlementInstruction.clearingSystem", "clearing system is required by this guideline"));
        };
      };
    };

    if (g.requireUetr) {
      switch (doc.uetr) {
        case null {
          issues := add(issues, publicIssue("business", "UETR-REQUIRED", "$.uetr", "UETR is mandatory for this guideline"));
        };
        case (?u) {
          if (not validUetr(u)) {
            issues := add(issues, publicIssue("schema", "UETR-FORMAT", "$.uetr", "UETR must be an RFC 4122 UUID version 4 value"));
          };
        };
      };
    };

    issues := validateMax35Ret(doc.endToEndId, "$.endToEndId", "PmtId-EndToEndId", issues);
    issues := validateAmount(g, doc.instructedAmount, "$.instructedAmount", issues);
    issues := validateParty(g, doc.debtor, "$.debtor", issues);
    issues := validateAccount(g, doc.debtorAccount, doc.instructedAmount.currency, "$.debtorAccount", issues);
    issues := validateAgent(g, doc.debtorAgent, "$.debtorAgent", issues);
    issues := validateParty(g, doc.creditor, "$.creditor", issues);
    issues := validateAccount(g, doc.creditorAccount, doc.instructedAmount.currency, "$.creditorAccount", issues);
    issues := validateAgent(g, doc.creditorAgent, "$.creditorAgent", issues);
    issues := validatePaymentType(g, doc.paymentTypeInformation, issues);
    issues := validateRemittance(doc.remittanceInformation, issues);

    reportFromIssues(g, "pacs.008", version, issues);
  };

  public func validatePacs009(g : UsageGuideline, doc : Pacs009FinancialInstitutionCreditTransfer, rawXml : ?Blob) : ValidationReport {
    let version = versionOf(g, "pacs.009");
    var issues : [ValidationIssue] = [];

    issues := validateRawXml(g, rawXml, issues);
    switch (doc.businessApplicationHeader) {
      case (?h) {
        issues := validateHeader(g, h, doc.messageId, version, issues);
        switch (h.uetr, doc.uetr) {
          case (?a, ?b) {
            if (a != b) issues := add(issues, publicIssue("business", "UETR-CONSISTENCY", "$.businessApplicationHeader.uetr", "BAH UETR must match pacs.009 UETR"));
          };
          case _ {};
        };
      };
      case null {
        if (g.requireBusinessApplicationHeader) {
          issues := add(issues, publicIssue("schema", "HEAD001-REQUIRED", "$.businessApplicationHeader", "Business Application Header is required by this guideline"));
        };
      };
    };

    issues := validateMax35Ret(doc.messageId, "$.messageId", "GrpHdr-MsgId", issues);
    issues := validateIsoDateTime(doc.creationDateTime, "$.creationDateTime", "GrpHdr-CreDtTm", issues);
    if (doc.transactionCount != 1) {
      issues := add(issues, publicIssue("usageGuideline", "PACS009-ONE-TX", "$.transactionCount", "pacs.009 must contain exactly one FI credit transfer for this hub profile"));
    };
    if (doc.settlementInstruction.settlementMethod != g.settlementMethod) {
      issues := add(issues, publicIssue("usageGuideline", "STTLM-MTD", "$.settlementInstruction.settlementMethod", "settlement method must be " # g.settlementMethod));
    };
    switch (doc.uetr) {
      case (?u) {
        if (not validUetr(u)) issues := add(issues, publicIssue("schema", "UETR-FORMAT", "$.uetr", "UETR must be an RFC 4122 UUID version 4 value"));
      };
      case null {
        if (g.requireUetr) issues := add(issues, publicIssue("business", "UETR-REQUIRED", "$.uetr", "UETR is mandatory for this guideline"));
      };
    };
    issues := validateMax35Ret(doc.instructionId, "$.instructionId", "PmtId-InstrId", issues);
    issues := validateMax35Ret(doc.endToEndId, "$.endToEndId", "PmtId-EndToEndId", issues);
    issues := validateAmount(g, doc.instructedAmount, "$.instructedAmount", issues);
    issues := validateAgent(g, doc.debtorAgent, "$.debtorAgent", issues);
    issues := validateAgent(g, doc.creditorAgent, "$.creditorAgent", issues);
    issues := validateAgent(g, doc.debtorInstitution, "$.debtorInstitution", issues);
    issues := validateAgent(g, doc.creditorInstitution, "$.creditorInstitution", issues);
    issues := validateRouting(g, doc.routing, doc.instructedAmount.currency, "$.routing", issues);
    switch (doc.underlyingPacs008MessageId) {
      case (?id) { issues := validateMax35Ret(id, "$.underlyingPacs008MessageId", "Undrlyg-MsgId", issues) };
      case null {
        if (doc.isCover) {
          issues := add(issues, publicIssue("business", "COVER-UNDERLYING-REQUIRED", "$.underlyingPacs008MessageId", "pacs.009 COV requires an underlying pacs.008 message id"));
        };
      };
    };

    reportFromIssues(g, "pacs.009", version, issues);
  };

  public func validateCoverPayment(g : UsageGuideline, cover : CoverPayment, rawXml : ?Blob) : ValidationReport {
    let direct = validatePacs008(g, cover.directMessage, rawXml);
    let cov = validatePacs009(g, cover.coverMessage, null);
    var issues : [ValidationIssue] = [];
    for (i in direct.issues.vals()) issues := add(issues, i);
    for (i in cov.issues.vals()) issues := add(issues, i);
    if (cover.method != "COVER") {
      issues := add(issues, publicIssue("business", "COVER-METHOD", "$.method", "cover payment method must be COVER"));
    };
    if (not cover.coverMessage.isCover) {
      issues := add(issues, publicIssue("business", "PACS009-COV-FLAG", "$.coverMessage.isCover", "cover message must be flagged as a pacs.009 cover transfer"));
    };
    switch (cover.coverMessage.underlyingPacs008MessageId) {
      case (?id) {
        if (id != cover.directMessage.messageId) {
          issues := add(issues, publicIssue("business", "COVER-UNDERLYING-MATCH", "$.coverMessage.underlyingPacs008MessageId", "cover message must reference the direct pacs.008 message id"));
        };
      };
      case null {};
    };
    switch (cover.directMessage.uetr, cover.coverMessage.uetr) {
      case (?a, ?b) {
        if (a != b) {
          issues := add(issues, publicIssue("business", "COVER-UETR-MATCH", "$.coverMessage.uetr", "cover UETR should match the direct payment UETR for end-to-end traceability"));
        };
      };
      case _ {};
    };
    reportFromIssues(g, "cover.payment", "pacs.008+pacs.009.COV", issues);
  };

  public func validateInvestigation(g : UsageGuideline, doc : InvestigationMessage) : ValidationReport {
    let version = versionOf(g, doc.messageKind);
    var issues : [ValidationIssue] = [];
    if (doc.messageKind != "camt.056" and doc.messageKind != "camt.029" and doc.messageKind != "pacs.028" and doc.messageKind != "camt.110" and doc.messageKind != "camt.111") {
      issues := add(issues, publicIssue("schema", "INVESTIGATION-KIND", "$.messageKind", "message kind must be camt.056, camt.029, pacs.028, camt.110, or camt.111"));
    };
    if (doc.messageVersion != version) {
      issues := add(issues, publicIssue("usageGuideline", "INVESTIGATION-VERSION", "$.messageVersion", "investigation message version must match active guideline"));
    };
    issues := validateMax35Ret(doc.messageId, "$.messageId", "Invstgtn-MsgId", issues);
    issues := validateIsoDateTime(doc.creationDateTime, "$.creationDateTime", "Invstgtn-CreDtTm", issues);
    issues := validateMax35Ret(doc.assignmentId, "$.assignmentId", "Assgnmt-Id", issues);
    issues := validateMax35Ret(doc.originalMessageId, "$.originalMessageId", "OrgnlMsgId", issues);
    switch (doc.originalUetr) {
      case (?u) {
        if (not validUetr(u)) issues := add(issues, publicIssue("schema", "UETR-FORMAT", "$.originalUetr", "original UETR must be an RFC 4122 UUID version 4 value"));
      };
      case null {};
    };
    issues := validateTextMax(doc.reasonCode, 35, "$.reasonCode", "Invstgtn-Rsn", issues);
    switch (doc.requestedAction) {
      case (?a) { issues := validateTextMax(a, 35, "$.requestedAction", "Invstgtn-Actn", issues) };
      case null {};
    };
    var i = 0;
    while (i < doc.additionalInfo.size()) {
      issues := validateTextMax(doc.additionalInfo[i], 140, "$.additionalInfo[" # Nat.toText(i) # "]", "Invstgtn-AddtlInf", issues);
      i += 1;
    };
    reportFromIssues(g, doc.messageKind, version, issues);
  };

  public func screenPacs008(profile : ComplianceProfile, doc : Pacs008CreditTransfer) : ComplianceReport {
    var findings : [ComplianceFinding] = [];
    findings := screenParty(profile, doc.debtor, "$.debtor", findings);
    findings := screenParty(profile, doc.creditor, "$.creditor", findings);
    findings := screenAgent(profile, doc.debtorAgent, "$.debtorAgent", findings);
    findings := screenAgent(profile, doc.creditorAgent, "$.creditorAgent", findings);
    if (profile.requireOriginatorAndBeneficiaryAddress) {
      if (missingAddress(doc.debtor)) findings := addFinding(findings, finding("review", "R16-DEBTOR-ADDRESS", "$.debtor.postalAddress", "originator address is required for payment transparency screening", "repair", 20));
      if (missingAddress(doc.creditor)) findings := addFinding(findings, finding("review", "R16-CREDITOR-ADDRESS", "$.creditor.postalAddress", "beneficiary address is required for payment transparency screening", "repair", 20));
    };
    if (doc.instructedAmount.minorUnits >= profile.highValueThresholdMinorUnits) {
      findings := addFinding(findings, finding("review", "AML-HIGH-VALUE", "$.instructedAmount", "payment exceeds configured high-value review threshold", "manual_review", 20));
    };
    if (profile.requirePurposeForCrossBorder and isCrossBorderPacs008(doc)) {
      switch (doc.paymentTypeInformation) {
        case (?p) {
          switch (p.categoryPurpose) {
            case null { findings := addFinding(findings, finding("review", "PURPOSE-REQUIRED", "$.paymentTypeInformation.categoryPurpose", "cross-border transfer should include category purpose", "repair", 15)) };
            case (?_) {};
          };
        };
        case null { findings := addFinding(findings, finding("review", "PURPOSE-REQUIRED", "$.paymentTypeInformation", "cross-border transfer should include payment purpose information", "repair", 15)) };
      };
    };
    complianceReport(profile, findings);
  };

  public func screenPacs009(profile : ComplianceProfile, doc : Pacs009FinancialInstitutionCreditTransfer) : ComplianceReport {
    var findings : [ComplianceFinding] = [];
    findings := screenAgent(profile, doc.debtorAgent, "$.debtorAgent", findings);
    findings := screenAgent(profile, doc.creditorAgent, "$.creditorAgent", findings);
    findings := screenAgent(profile, doc.debtorInstitution, "$.debtorInstitution", findings);
    findings := screenAgent(profile, doc.creditorInstitution, "$.creditorInstitution", findings);
    findings := screenAgent(profile, doc.routing.instructingAgent, "$.routing.instructingAgent", findings);
    findings := screenAgent(profile, doc.routing.instructedAgent, "$.routing.instructedAgent", findings);
    var i = 0;
    while (i < doc.routing.intermediaryAgents.size()) {
      findings := screenAgent(profile, doc.routing.intermediaryAgents[i], "$.routing.intermediaryAgents[" # Nat.toText(i) # "]", findings);
      i += 1;
    };
    if (doc.routing.intermediaryAgents.size() > profile.maxIntermediaryAgents) {
      findings := addFinding(findings, finding("review", "ROUTE-TOO-MANY-INTERMEDIARIES", "$.routing.intermediaryAgents", "intermediary chain exceeds configured review limit", "manual_review", 20));
    };
    if (not containsText(profile.allowedChargeBearers, doc.routing.chargeBearer)) {
      findings := addFinding(findings, finding("review", "CHRGBR-ACTIVE", "$.routing.chargeBearer", "charge bearer is not allowed by compliance profile", "repair", 15));
    };
    if (profile.requireRegulatoryReportingForCrossBorder and doc.routing.regulatoryReporting.size() == 0) {
      findings := addFinding(findings, finding("review", "REGREP-REQUIRED", "$.routing.regulatoryReporting", "cross-border transfer requires regulatory reporting details for this profile", "repair", 25));
    };
    if (profile.requireFxForCurrencyConversion) {
      switch (doc.routing.fx) {
        case (?fx) {
          if (fx.exchangeRateE8s == 0) findings := addFinding(findings, finding("review", "FX-RATE-REQUIRED", "$.routing.fx.exchangeRateE8s", "FX exchange rate must be positive", "repair", 20));
        };
        case null {
          findings := addFinding(findings, finding("review", "FX-REVIEW", "$.routing.fx", "FX details should be present when settlement and source currencies differ", "manual_review", 15));
        };
      };
    };
    if (doc.instructedAmount.minorUnits >= profile.highValueThresholdMinorUnits) {
      findings := addFinding(findings, finding("review", "AML-HIGH-VALUE", "$.instructedAmount", "FI transfer exceeds configured high-value review threshold", "manual_review", 20));
    };
    complianceReport(profile, findings);
  };

  public func screenCoverPayment(profile : ComplianceProfile, cover : CoverPayment) : ComplianceReport {
    let a = screenPacs008(profile, cover.directMessage);
    let b = screenPacs009(profile, cover.coverMessage);
    var findings : [ComplianceFinding] = [];
    for (f in a.findings.vals()) findings := addFinding(findings, f);
    for (f in b.findings.vals()) findings := addFinding(findings, f);
    if (cover.coverMessage.isCover and cover.coverMessage.routing.intermediaryAgents.size() > 0) {
      findings := addFinding(findings, finding("review", "COVER-CHAIN-RISK", "$.coverMessage.routing.intermediaryAgents", "cover payment uses correspondent chain; verify cover receipt and beneficiary-credit policy", "manual_review", 15));
    };
    complianceReport(profile, findings);
  };

  public func validateStatusReport(g : UsageGuideline, doc : StatusReport, expectedKind : Text) : ValidationReport {
    let version = versionOf(g, expectedKind);
    var issues : [ValidationIssue] = [];
    if (doc.messageKind != expectedKind) {
      issues := add(issues, publicIssue("schema", "STATUS-KIND", "$.messageKind", "status report kind must be " # expectedKind));
    };
    if (doc.messageVersion != version) {
      issues := add(issues, publicIssue("usageGuideline", "STATUS-VERSION", "$.messageVersion", "status report version must match active guideline"));
    };
    issues := validateMax35Ret(doc.messageId, "$.messageId", "Status-MsgId", issues);
    issues := validateMax35Ret(doc.originalMessageId, "$.originalMessageId", "OrgnlMsgId", issues);
    if (not validUetr(doc.originalUetr)) {
      issues := add(issues, publicIssue("schema", "UETR-FORMAT", "$.originalUetr", "original UETR must be an RFC 4122 UUID version 4 value"));
    };
    if (not validTransactionStatus(doc.transactionStatus)) {
      issues := add(issues, publicIssue("usageGuideline", "TXSTS-ACTIVE", "$.transactionStatus", "transaction status is not enabled in this educational hub baseline"));
    };
    switch (doc.reason) {
      case (?r) { issues := validateTextMax(r, 140, "$.reason", "Status-Rsn", issues) };
      case null {};
    };
    issues := validateIsoDateTime(doc.creationDateTime, "$.creationDateTime", "Status-CreDtTm", issues);
    reportFromIssues(g, expectedKind, version, issues);
  };

  public func validateRequestToPay(g : UsageGuideline, doc : RequestToPayMessage) : ValidationReport {
    let version = versionOf(g, doc.messageKind);
    var issues : [ValidationIssue] = [];
    if (doc.messageKind != "pain.013" and doc.messageKind != "pain.014" and doc.messageKind != "camt.055") {
      issues := add(issues, publicIssue("schema", "RTP-KIND", "$.messageKind", "request-to-pay message kind must be pain.013, pain.014, or camt.055"));
    };
    if (doc.messageVersion != version) {
      issues := add(issues, publicIssue("usageGuideline", "RTP-VERSION", "$.messageVersion", "request-to-pay version must match active guideline"));
    };
    issues := validateMax35Ret(doc.messageId, "$.messageId", "RTP-MSGID", issues);
    issues := validateMax35Ret(doc.requestId, "$.requestId", "RTP-REQID", issues);
    issues := validateIsoDateTime(doc.creationDateTime, "$.creationDateTime", "RTP-CreDtTm", issues);
    switch (doc.requestedExecutionDate) {
      case (?d) { issues := validateIsoDate(d, "$.requestedExecutionDate", "RTP-ReqdExctnDt", issues) };
      case null {};
    };
    issues := validateParty(g, doc.debtor, "$.debtor", issues);
    issues := validateAccount(g, doc.debtorAccount, doc.requestedAmount.currency, "$.debtorAccount", issues);
    issues := validateAgent(g, doc.debtorAgent, "$.debtorAgent", issues);
    issues := validateParty(g, doc.creditor, "$.creditor", issues);
    issues := validateAccount(g, doc.creditorAccount, doc.requestedAmount.currency, "$.creditorAccount", issues);
    issues := validateAgent(g, doc.creditorAgent, "$.creditorAgent", issues);
    issues := validateAmount(g, doc.requestedAmount, "$.requestedAmount", issues);
    issues := validateRemittance(doc.remittanceInformation, issues);
    switch (doc.chargeBearer) {
      case (?c) {
        if (c != "DEBT" and c != "CRED" and c != "SHAR" and c != "SLEV") {
          issues := add(issues, publicIssue("usageGuideline", "RTP-CHRGBR", "$.chargeBearer", "request-to-pay charge bearer must be DEBT, CRED, SHAR, or SLEV"));
        };
      };
      case null {};
    };
    if (doc.messageKind == "pain.013") {
      switch (doc.originalRequestId) {
        case (?_) issues := add(issues, publicIssue("business", "RTP-ORIGINAL-UNEXPECTED", "$.originalRequestId", "pain.013 presentment must not carry an original request id"));
        case null {};
      };
      switch (doc.status) {
        case (?_) issues := add(issues, publicIssue("business", "RTP-STATUS-UNEXPECTED", "$.status", "pain.013 presentment must not carry a response status"));
        case null {};
      };
    } else {
      switch (doc.originalRequestId) {
        case (?_) {};
        case null issues := add(issues, publicIssue("business", "RTP-ORIGINAL-REQUIRED", "$.originalRequestId", "pain.014 and camt.055 require the original request id"));
      };
      switch (doc.status) {
        case (?s) {
          if (doc.messageKind == "pain.014" and not (s == "ACTC" or s == "RJCT" or s == "PDNG")) {
            issues := add(issues, publicIssue("usageGuideline", "RTP-STATUS", "$.status", "pain.014 status must be ACTC, RJCT, or PDNG"));
          };
          if (doc.messageKind == "camt.055" and s != "CANC") {
            issues := add(issues, publicIssue("usageGuideline", "RTP-CANCEL-STATUS", "$.status", "camt.055 cancellation status must be CANC"));
          };
        };
        case null issues := add(issues, publicIssue("business", "RTP-STATUS-REQUIRED", "$.status", "pain.014 and camt.055 require a status"));
      };
    };

    reportFromIssues(g, doc.messageKind, version, issues);
  };

  public func validateDirectDebit(g : UsageGuideline, doc : DirectDebitMessage, rawXml : ?Blob) : ValidationReport {
    let version = versionOf(g, doc.messageKind);
    var issues : [ValidationIssue] = [];

    issues := validateRawXml(g, rawXml, issues);
    if (doc.messageKind != "pain.008" and doc.messageKind != "pacs.003") {
      issues := add(issues, publicIssue("schema", "DD-KIND", "$.messageKind", "direct-debit message kind must be pain.008 or pacs.003"));
    };
    if (doc.messageVersion != version) {
      issues := add(issues, publicIssue("usageGuideline", "DD-VERSION", "$.messageVersion", "direct-debit version must match active guideline"));
    };
    issues := validateMax35Ret(doc.messageId, "$.messageId", "DD-MSGID", issues);
    issues := validateIsoDateTime(doc.creationDateTime, "$.creationDateTime", "DD-CreDtTm", issues);
    switch (doc.requestedCollectionDate) {
      case (?d) { issues := validateIsoDate(d, "$.requestedCollectionDate", "DD-ReqdColltnDt", issues) };
      case null {
        issues := add(issues, publicIssue("business", "DD-COLLECTION-DATE-REQUIRED", "$.requestedCollectionDate", "direct debit requires a requested collection date"));
      };
    };
    if (doc.transactionCount != 1) {
      issues := add(issues, publicIssue("usageGuideline", "DD-ONE-TX", "$.transactionCount", "direct-debit compact profile supports exactly one transaction"));
    };

    issues := validateParty(g, doc.initiatingParty, "$.initiatingParty", issues);
    issues := validateParty(g, doc.creditor, "$.creditor", issues);
    issues := validateAccount(g, doc.creditorAccount, doc.instructedAmount.currency, "$.creditorAccount", issues);
    issues := validateAgent(g, doc.creditorAgent, "$.creditorAgent", issues);
    issues := validateParty(g, doc.debtor, "$.debtor", issues);
    issues := validateAccount(g, doc.debtorAccount, doc.instructedAmount.currency, "$.debtorAccount", issues);
    issues := validateAgent(g, doc.debtorAgent, "$.debtorAgent", issues);
    issues := validatePaymentType(g, doc.paymentTypeInformation, issues);
    issues := validateAmount(g, doc.instructedAmount, "$.instructedAmount", issues);
    issues := validateMax35Ret(doc.endToEndId, "$.endToEndId", "DD-EndToEndId", issues);
    issues := validateMax35Ret(doc.mandateId, "$.mandateId", "DD-MndtId", issues);
    switch (doc.mandateSignatureDate) {
      case (?d) { issues := validateIsoDate(d, "$.mandateSignatureDate", "DD-MndtSgntrDt", issues) };
      case null {};
    };
    if (not validDirectDebitSequence(doc.sequenceType)) {
      issues := add(issues, publicIssue("usageGuideline", "DD-SEQUENCE-TYPE", "$.sequenceType", "direct-debit sequence type must be FRST, RCUR, FNAL, or OOFF"));
    };
    issues := validateRemittance(doc.remittanceInformation, issues);

    if (doc.messageKind == "pain.008") {
      switch (doc.businessApplicationHeader) {
        case (?_) issues := add(issues, publicIssue("schema", "DD-HEAD001-UNEXPECTED", "$.businessApplicationHeader", "pain.008 customer direct debit initiation must not carry a Business Application Header in this compact profile"));
        case null {};
      };
      switch (doc.settlementInstruction) {
        case (?_) issues := add(issues, publicIssue("schema", "DD-STTLM-UNEXPECTED", "$.settlementInstruction", "pain.008 customer direct debit initiation must not carry interbank settlement instruction in this compact profile"));
        case null {};
      };
    };

    if (doc.messageKind == "pacs.003") {
      switch (doc.businessApplicationHeader) {
        case (?h) {
          issues := validateHeader(g, h, doc.messageId, version, issues);
          switch (h.uetr, doc.uetr) {
            case (?a, ?b) {
              if (a != b) issues := add(issues, publicIssue("business", "DD-UETR-CONSISTENCY", "$.businessApplicationHeader.uetr", "BAH UETR must match pacs.003 transaction UETR"));
            };
            case _ {};
          };
        };
        case null {
          if (g.requireBusinessApplicationHeader) {
            issues := add(issues, publicIssue("schema", "DD-HEAD001-REQUIRED", "$.businessApplicationHeader", "Business Application Header is required for pacs.003 by this guideline"));
          };
        };
      };
      switch (doc.settlementInstruction) {
        case (?s) {
          if (s.settlementMethod != g.settlementMethod) {
            issues := add(issues, publicIssue("usageGuideline", "DD-STTLM-MTD", "$.settlementInstruction.settlementMethod", "direct-debit settlement method must be " # g.settlementMethod));
          };
        };
        case null {
          issues := add(issues, publicIssue("business", "DD-STTLM-REQUIRED", "$.settlementInstruction", "pacs.003 requires interbank settlement instruction"));
        };
      };
      if (g.requireUetr) {
        switch (doc.uetr) {
          case (?u) {
            if (not validUetr(u)) issues := add(issues, publicIssue("schema", "DD-UETR-FORMAT", "$.uetr", "pacs.003 UETR must be an RFC 4122 UUID version 4 value"));
          };
          case null {
            issues := add(issues, publicIssue("business", "DD-UETR-REQUIRED", "$.uetr", "UETR is mandatory for pacs.003 by this guideline"));
          };
        };
      };
    };

    reportFromIssues(g, doc.messageKind, version, issues);
  };

  public func validateAdministrativeMessage(g : UsageGuideline, doc : AdministrativeMessage) : ValidationReport {
    let version = versionOf(g, doc.messageKind);
    var issues : [ValidationIssue] = [];
    if (doc.messageKind != "admi.002" and doc.messageKind != "admi.004" and doc.messageKind != "admi.007" and doc.messageKind != "admi.011") {
      issues := add(issues, publicIssue("schema", "ADMI-KIND", "$.messageKind", "administrative message kind must be admi.002, admi.004, admi.007, or admi.011"));
    };
    if (doc.messageVersion != version) {
      issues := add(issues, publicIssue("usageGuideline", "ADMI-VERSION", "$.messageVersion", "administrative message version must match active guideline"));
    };
    issues := validateMax35Ret(doc.messageId, "$.messageId", "ADMI-MsgId", issues);
    issues := validateIsoDateTime(doc.creationDateTime, "$.creationDateTime", "ADMI-CreDtTm", issues);
    switch (doc.relatedMessageId) {
      case (?id) { issues := validateMax35Ret(id, "$.relatedMessageId", "ADMI-RltdMsgId", issues) };
      case null {};
    };
    switch (doc.relatedUetr) {
      case (?u) {
        if (not validUetr(u)) issues := add(issues, publicIssue("schema", "ADMI-UETR-FORMAT", "$.relatedUetr", "related UETR must be an RFC 4122 UUID version 4 value"));
      };
      case null {};
    };
    issues := validateTextMax(doc.eventCode, 35, "$.eventCode", "ADMI-EvtCd", issues);
    issues := validateTextMax(doc.status, 35, "$.status", "ADMI-Sts", issues);
    if (doc.messageKind == "admi.002" and doc.status != "RJCT") {
      issues := add(issues, publicIssue("usageGuideline", "ADMI002-STATUS", "$.status", "admi.002 compact reject status must be RJCT"));
    };
    if ((doc.messageKind == "admi.007" or doc.messageKind == "admi.011") and doc.status != "ACK") {
      issues := add(issues, publicIssue("usageGuideline", "ADMI-ACK-STATUS", "$.status", "admi.007 and admi.011 compact acknowledgement status must be ACK"));
    };
    if (doc.messageKind == "admi.004" and not (doc.status == "INFO" or doc.status == "ACK")) {
      issues := add(issues, publicIssue("usageGuideline", "ADMI004-STATUS", "$.status", "admi.004 compact connection-check status must be INFO or ACK"));
    };
    switch (doc.reason) {
      case (?r) { issues := validateTextMax(r, 140, "$.reason", "ADMI-Rsn", issues) };
      case null {};
    };
    var i = 0;
    while (i < doc.additionalInfo.size()) {
      issues := validateTextMax(doc.additionalInfo[i], 140, "$.additionalInfo[" # Nat.toText(i) # "]", "ADMI-AddtlInf", issues);
      i += 1;
    };
    reportFromIssues(g, doc.messageKind, version, issues);
  };

  public func phaseVerification(phase : Text, report : ValidationReport) : PhaseVerification {
    { phase; ok = report.ok; issueCount = report.issueCount; issues = report.issues };
  };

  public func publicIssue(tier : Text, ruleId : Text, path : Text, message : Text) : ValidationIssue {
    { severity = "error"; tier; ruleId; path; message };
  };

  public func reportFromIssues(g : UsageGuideline, kind : Text, version : Text, issues : [ValidationIssue]) : ValidationReport {
    {
      ok = issues.size() == 0;
      guidelineId = g.id;
      messageKind = kind;
      messageVersion = version;
      issueCount = issues.size();
      issues;
    };
  };

  public func versionOf(g : UsageGuideline, kind : Text) : Text {
    switch (messageVersion(g, kind)) { case (?v) v; case null kind };
  };

  public func validTransactionStatus(status : Text) : Bool {
    status == "ACCP" or status == "ACSC" or status == "ACSP" or status == "ACTC" or status == "ACWC" or status == "PDNG" or status == "RJCT";
  };

  public func validDirectDebitSequence(sequenceType : Text) : Bool {
    sequenceType == "FRST" or sequenceType == "RCUR" or sequenceType == "FNAL" or sequenceType == "OOFF";
  };

  func validateRawXml(g : UsageGuideline, rawXml : ?Blob, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = issues0;
    switch (rawXml) {
      case (?xml) {
        if (xml.size() > g.maxMessageBytes) {
          issues := add(issues, publicIssue("schema", "ISO20022-MSG-SIZE", "$xml", "raw XML exceeds configured message byte cap"));
        };
      };
      case null {};
    };
    issues;
  };

  func validateRouting(g : UsageGuideline, routing : CrossBorderRouting, settlementCurrency : Text, path : Text, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = issues0;
    if (not validChargeBearer(routing.chargeBearer)) {
      issues := add(issues, publicIssue("schema", "CHRGBR-FORMAT", path # ".chargeBearer", "charge bearer must be DEBT, CRED, SHAR, or SLEV"));
    };
    issues := validateAgent(g, routing.instructingAgent, path # ".instructingAgent", issues);
    issues := validateAgent(g, routing.instructedAgent, path # ".instructedAgent", issues);
    var i = 0;
    while (i < routing.intermediaryAgents.size()) {
      issues := validateAgent(g, routing.intermediaryAgents[i], path # ".intermediaryAgents[" # Nat.toText(i) # "]", issues);
      i += 1;
    };
    if (routing.intermediaryAgents.size() > 3) {
      issues := add(issues, publicIssue("usageGuideline", "ROUTE-INTERMEDIARY-LIMIT", path # ".intermediaryAgents", "this education profile supports up to three intermediary agents"));
    };
    i := 0;
    while (i < routing.charges.size()) {
      issues := validateAmount(g, routing.charges[i].amount, path # ".charges[" # Nat.toText(i) # "].amount", issues);
      issues := validateAgent(g, routing.charges[i].agent, path # ".charges[" # Nat.toText(i) # "].agent", issues);
      switch (routing.charges[i].typeCode) {
        case (?c) { issues := validateTextMax(c, 35, path # ".charges[" # Nat.toText(i) # "].typeCode", "ChrgsInf-Tp", issues) };
        case null {};
      };
      i += 1;
    };
    switch (routing.settlementDate) {
      case (?d) { issues := validateIsoDate(d, path # ".settlementDate", "IntrBkSttlmDt", issues) };
      case null {};
    };
    switch (routing.fx) {
      case (?fx) {
        if (not validCurrencyCode(fx.sourceCurrency)) issues := add(issues, publicIssue("schema", "FX-SRC-CUR", path # ".fx.sourceCurrency", "FX source currency must be ISO 4217 uppercase alpha-3"));
        if (not validCurrencyCode(fx.targetCurrency)) issues := add(issues, publicIssue("schema", "FX-TGT-CUR", path # ".fx.targetCurrency", "FX target currency must be ISO 4217 uppercase alpha-3"));
        if (fx.exchangeRateE8s == 0) issues := add(issues, publicIssue("business", "FX-RATE-POSITIVE", path # ".fx.exchangeRateE8s", "FX exchange rate must be positive"));
        issues := validateAmount(g, fx.settlementAmount, path # ".fx.settlementAmount", issues);
        if (fx.settlementAmount.currency != settlementCurrency) {
          issues := add(issues, publicIssue("business", "FX-STTLM-CUR-MATCH", path # ".fx.settlementAmount.currency", "FX settlement amount currency must match transfer settlement currency"));
        };
        switch (fx.quoteId) {
          case (?q) { issues := validateTextMax(q, 35, path # ".fx.quoteId", "FX-QuoteId", issues) };
          case null {};
        };
        switch (fx.quoteExpiry) {
          case (?t) { issues := validateIsoDateTime(t, path # ".fx.quoteExpiry", "FX-QuoteExpiry", issues) };
          case null {};
        };
      };
      case null {};
    };
    i := 0;
    while (i < routing.regulatoryReporting.size()) {
      switch (routing.regulatoryReporting[i].authorityCountry) {
        case (?country) {
          if (not validCountryCode(country)) issues := add(issues, publicIssue("schema", "REGREP-COUNTRY", path # ".regulatoryReporting[" # Nat.toText(i) # "].authorityCountry", "regulatory authority country must be ISO 3166-1 alpha-2"));
        };
        case null {};
      };
      switch (routing.regulatoryReporting[i].reportingCode) {
        case (?code) { issues := validateTextMax(code, 35, path # ".regulatoryReporting[" # Nat.toText(i) # "].reportingCode", "RegRptg-Cd", issues) };
        case null {};
      };
      var j = 0;
      while (j < routing.regulatoryReporting[i].details.size()) {
        issues := validateTextMax(routing.regulatoryReporting[i].details[j], 140, path # ".regulatoryReporting[" # Nat.toText(i) # "].details[" # Nat.toText(j) # "]", "RegRptg-Dtl", issues);
        j += 1;
      };
      i += 1;
    };
    issues;
  };

  func validChargeBearer(value : Text) : Bool {
    value == "DEBT" or value == "CRED" or value == "SHAR" or value == "SLEV";
  };

  func screenParty(profile : ComplianceProfile, party : PartyIdentification, path : Text, findings0 : [ComplianceFinding]) : [ComplianceFinding] {
    var findings = screenName(profile, party.name, path # ".name", findings0);
    switch (party.postalAddress) {
      case (?a) {
        findings := screenCountry(profile, a.country, path # ".postalAddress.country", findings);
      };
      case null {};
    };
    findings;
  };

  func screenAgent(profile : ComplianceProfile, agent : FinancialInstitutionIdentification, path : Text, findings0 : [ComplianceFinding]) : [ComplianceFinding] {
    var findings = findings0;
    if (containsText(profile.blockedBics, agent.bicfi)) {
      findings := addFinding(findings, finding("block", "SANCTIONS-BIC", path # ".bicfi", "BIC is present in configured blocked BIC list", "block", 100));
    };
    switch (bicCountry(agent.bicfi)) {
      case (?country) { findings := screenCountry(profile, country, path # ".bicfi.country", findings) };
      case null {};
    };
    switch (agent.name) {
      case (?n) { findings := screenName(profile, n, path # ".name", findings) };
      case null {};
    };
    findings;
  };

  func screenCountry(profile : ComplianceProfile, country : Text, path : Text, findings0 : [ComplianceFinding]) : [ComplianceFinding] {
    var findings = findings0;
    if (containsText(profile.blockedCountries, country)) {
      findings := addFinding(findings, finding("block", "SANCTIONS-COUNTRY", path, "country is present in configured blocked country list", "block", 100));
    } else if (containsText(profile.highRiskCountries, country)) {
      findings := addFinding(findings, finding("review", "AML-HIGH-RISK-COUNTRY", path, "country is present in configured high-risk country list", "manual_review", 30));
    };
    findings;
  };

  func screenName(profile : ComplianceProfile, name : Text, path : Text, findings0 : [ComplianceFinding]) : [ComplianceFinding] {
    var findings = findings0;
    for (fragment in profile.blockedNameFragments.vals()) {
      if (fragment != "" and Text.contains(name, #text fragment)) {
        findings := addFinding(findings, finding("block", "SANCTIONS-NAME-FRAGMENT", path, "party name matched configured blocked name fragment", "block", 100));
      };
    };
    findings;
  };

  func missingAddress(party : PartyIdentification) : Bool {
    switch (party.postalAddress) {
      case null true;
      case (?a) a.country == "" or a.townName == "" or a.addressLine.size() == 0;
    };
  };

  func isCrossBorderPacs008(doc : Pacs008CreditTransfer) : Bool {
    switch (doc.debtor.postalAddress, doc.creditor.postalAddress) {
      case (?d, ?c) {
        if (d.country != c.country) return true;
      };
      case _ {};
    };
    switch (bicCountry(doc.debtorAgent.bicfi), bicCountry(doc.creditorAgent.bicfi)) {
      case (?d, ?c) d != c;
      case _ false;
    };
  };

  func finding(severity : Text, ruleId : Text, path : Text, message : Text, action : Text, score : Nat) : ComplianceFinding {
    { severity; ruleId; path; message; action; score };
  };

  func addFinding(xs : [ComplianceFinding], x : ComplianceFinding) : [ComplianceFinding] {
    Array.concat<ComplianceFinding>(xs, [x]);
  };

  func complianceReport(profile : ComplianceProfile, findings : [ComplianceFinding]) : ComplianceReport {
    var score = 0;
    var blocked = false;
    for (f in findings.vals()) {
      score += f.score;
      if (f.severity == "block" or f.action == "block") blocked := true;
    };
    let decision = if (blocked or score >= 100) {
      "block"
    } else if (score >= 50 or findings.size() > 0) {
      "review"
    } else {
      "pass"
    };
    {
      ok = decision == "pass";
      decision;
      profileId = profile.id;
      riskScore = score;
      findingCount = findings.size();
      findings;
    };
  };

  func validateHeader(g : UsageGuideline, h : BusinessApplicationHeader, messageId : Text, pacsVersion : Text, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = issues0;
    issues := validateBic(h.fromBic, "$.businessApplicationHeader.fromBic", issues);
    issues := validateBic(h.toBic, "$.businessApplicationHeader.toBic", issues);
    issues := validateMax35Ret(h.businessMessageId, "$.businessApplicationHeader.businessMessageId", "BAH-BizMsgIdr", issues);
    if (g.requireBahBusinessMessageIdMatchesMessageId and h.businessMessageId != messageId) {
      issues := add(issues, publicIssue("usageGuideline", "BAH-BIZMSGID-MSGID", "$.businessApplicationHeader.businessMessageId", "BAH businessMessageId must match group header messageId for this guideline"));
    };
    if (h.messageDefinitionId != pacsVersion) {
      issues := add(issues, publicIssue("usageGuideline", "BAH-MSGDEF", "$.businessApplicationHeader.messageDefinitionId", "BAH messageDefinitionId must match configured pacs.008 version"));
    };
    switch (h.businessService) {
      case (?s) { issues := validateTextMax(s, 35, "$.businessApplicationHeader.businessService", "BAH-BizSvc", issues) };
      case null {};
    };
    issues := validateIsoDateTime(h.creationDateTime, "$.businessApplicationHeader.creationDateTime", "BAH-CreDt", issues);
    switch (h.uetr) {
      case (?u) {
        if (not validUetr(u)) {
          issues := add(issues, publicIssue("schema", "UETR-FORMAT", "$.businessApplicationHeader.uetr", "BAH UETR must be an RFC 4122 UUID version 4 value"));
        };
      };
      case null {};
    };
    issues;
  };

  func validateAmount(g : UsageGuideline, amount : ActiveCurrencyAndAmount, path : Text, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = issues0;
    if (not validCurrencyCode(amount.currency)) {
      issues := add(issues, publicIssue("schema", "CUR-FORMAT", path # ".currency", "currency must be a 3-letter uppercase ISO 4217 code"));
    };
    if (amount.minorUnits == 0) {
      issues := add(issues, publicIssue("business", "AMT-POSITIVE", path # ".minorUnits", "amount must be greater than zero"));
    };
    switch (currencyRule(g, amount.currency)) {
      case null {
        issues := add(issues, publicIssue("usageGuideline", "CUR-ACTIVE", path # ".currency", "currency is not enabled in the active guideline code set"));
      };
      case (?_) {};
    };
    issues;
  };

  func validateParty(g : UsageGuideline, party : PartyIdentification, path : Text, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = validateTextMax(party.name, 140, path # ".name", "Party-Nm", issues0);
    switch (party.lei) {
      case (?lei) {
        if (not validLei(lei)) {
          issues := add(issues, publicIssue("schema", "LEI-FORMAT", path # ".lei", "LEI must pass ISO 17442 format and MOD 97-10 checksum"));
        };
      };
      case null {};
    };
    switch (party.postalAddress) {
      case (?a) { issues := validatePostalAddress(g, a, path # ".postalAddress", issues) };
      case null {};
    };
    issues;
  };

  func validatePostalAddress(g : UsageGuideline, a : PostalAddress, path : Text, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = issues0;
    if (not validCountryCode(a.country)) {
      issues := add(issues, publicIssue("schema", "COUNTRY-FORMAT", path # ".country", "country must be an ISO 3166-1 alpha-2 code"));
    } else if (g.countryCodes.size() > 0 and not containsText(g.countryCodes, a.country)) {
      issues := add(issues, publicIssue("usageGuideline", "COUNTRY-ACTIVE", path # ".country", "country is not enabled in the active guideline code set"));
    };
    issues := validateTextMax(a.townName, 35, path # ".townName", "PstlAdr-TwnNm", issues);
    switch (a.postalCode) {
      case (?pc) { issues := validateTextMax(pc, 16, path # ".postalCode", "PstCd", issues) };
      case null {};
    };
    var i = 0;
    while (i < a.addressLine.size()) {
      issues := validateTextMax(a.addressLine[i], 70, path # ".addressLine[" # Nat.toText(i) # "]", "AdrLine", issues);
      i += 1;
    };
    issues;
  };

  func validateAccount(g : UsageGuideline, account : CashAccount, instructedCurrency : Text, path : Text, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = issues0;
    switch (account.iban, account.otherId) {
      case (null, null) {
        issues := add(issues, publicIssue("schema", "ACCT-ID-REQUIRED", path, "cash account requires IBAN or another account identifier"));
      };
      case _ {};
    };
    switch (account.iban) {
      case (?iban) {
        if (not validIban(iban)) {
          issues := add(issues, publicIssue("schema", "IBAN-MOD97", path # ".iban", "IBAN must pass ISO 13616 MOD 97-10 validation"));
        };
        if (startsWith(iban, "EG") and not validEgyptianIbanShape(iban)) {
          issues := add(issues, publicIssue("usageGuideline", "EG-IBAN-SHAPE", path # ".iban", "Egyptian IBAN must be 29 characters: EG + 2 check digits + 25 digits"));
        };
        switch (g.requiredIbanCountry) {
          case (?country) {
            if (not validCountryCode(country)) {
              issues := add(issues, publicIssue("usageGuideline", "IBAN-COUNTRY-CONFIG", "$.guideline.requiredIbanCountry", "required IBAN country must be ISO 3166-1 alpha-2"));
            } else if (not startsWith(iban, country)) {
              issues := add(issues, publicIssue("usageGuideline", "IBAN-COUNTRY-REQUIRED", path # ".iban", "IBAN country must be " # country # " for this guideline"));
            };
          };
          case null {};
        };
      };
      case null {
        switch (g.requiredIbanCountry) {
          case (?country) {
            issues := add(issues, publicIssue("usageGuideline", "IBAN-REQUIRED", path # ".iban", "IBAN is required when requiredIbanCountry is " # country));
          };
          case null {};
        };
      };
    };
    switch (account.currency) {
      case (?c) {
        if (not validCurrencyCode(c)) {
          issues := add(issues, publicIssue("schema", "ACCT-CUR-FORMAT", path # ".currency", "account currency must be a 3-letter uppercase ISO 4217 code"));
        };
        if (g.requireAccountCurrencyMatchesInstructed and c != instructedCurrency) {
          issues := add(issues, publicIssue("business", "ACCT-CUR-MATCH", path # ".currency", "account currency must match instructed amount currency"));
        };
        switch (currencyRule(g, c)) {
          case null { issues := add(issues, publicIssue("usageGuideline", "ACCT-CUR-ACTIVE", path # ".currency", "account currency is not enabled in the active guideline")) };
          case (?_) {};
        };
      };
      case null {};
    };
    issues;
  };

  func validateAgent(g : UsageGuideline, agent : FinancialInstitutionIdentification, path : Text, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = validateBic(agent.bicfi, path # ".bicfi", issues0);
    switch (g.requiredAgentCountry) {
      case (?country) {
        if (not validCountryCode(country)) {
          issues := add(issues, publicIssue("usageGuideline", "AGENT-COUNTRY-CONFIG", "$.guideline.requiredAgentCountry", "required agent country must be ISO 3166-1 alpha-2"));
        } else {
          switch (bicCountry(agent.bicfi)) {
            case (?bicCtry) {
              if (bicCtry != country) {
                issues := add(issues, publicIssue("usageGuideline", "AGENT-COUNTRY-REQUIRED", path # ".bicfi", "BIC country must be " # country # " for this guideline"));
              };
            };
            case null {};
          };
        };
      };
      case null {};
    };
    switch (agent.name) {
      case (?n) { issues := validateTextMax(n, 140, path # ".name", "FinInstnId-Nm", issues) };
      case null {};
    };
    issues;
  };

  func validatePaymentType(g : UsageGuideline, pti : ?PaymentTypeInformation, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = issues0;
    switch (pti) {
      case null {};
      case (?p) {
        switch (p.categoryPurpose) {
          case (?c) {
            if (g.categoryPurposeCodes.size() > 0 and not containsText(g.categoryPurposeCodes, c)) {
              issues := add(issues, publicIssue("usageGuideline", "CATPURP-ACTIVE", "$.paymentTypeInformation.categoryPurpose", "category purpose is not enabled in the active guideline code set"));
            };
          };
          case null {};
        };
        switch (p.serviceLevel) {
          case (?s) { issues := validateTextMax(s, 4, "$.paymentTypeInformation.serviceLevel", "SvcLvl-Cd", issues) };
          case null {};
        };
        switch (p.localInstrument) {
          case (?s) { issues := validateTextMax(s, 35, "$.paymentTypeInformation.localInstrument", "LclInstrm", issues) };
          case null {};
        };
      };
    };
    issues;
  };

  func validateRemittance(r : RemittanceInformation, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = issues0;
    var i = 0;
    while (i < r.unstructured.size()) {
      issues := validateTextMax(r.unstructured[i], 140, "$.remittanceInformation.unstructured[" # Nat.toText(i) # "]", "RmtInf-Ustrd", issues);
      i += 1;
    };
    switch (r.structuredCreditorReference) {
      case (?s) { issues := validateTextMax(s, 35, "$.remittanceInformation.structuredCreditorReference", "CdtrRefInf-Ref", issues) };
      case null {};
    };
    issues;
  };

  func validateBic(bic : Text, path : Text, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = issues0;
    if (not validBicFi(bic)) {
      issues := add(issues, publicIssue("schema", "BICFI-FORMAT", path, "BICFI must be 8 or 11 uppercase ISO 9362 characters"));
    };
    issues;
  };

  func validateMax35Ret(value : Text, path : Text, ruleId : Text, issues0 : [ValidationIssue]) : [ValidationIssue] {
    validateTextMax(value, 35, path, ruleId, issues0);
  };

  func validateTextMax(value : Text, max : Nat, path : Text, ruleId : Text, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = issues0;
    let size = Text.size(value);
    if (size == 0) {
      issues := add(issues, publicIssue("structural", ruleId # "-REQUIRED", path, "field is required"));
    };
    if (size > max) {
      issues := add(issues, publicIssue("schema", ruleId # "-MAXLEN", path, "field exceeds max length " # Nat.toText(max)));
    };
    if (not swiftX(value)) {
      issues := add(issues, publicIssue("schema", "CHARSET-SWIFT-X", path, "field contains characters outside SWIFT Character Set X"));
    };
    issues;
  };

  func validateIsoDateTime(value : Text, path : Text, ruleId : Text, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = validateTextMax(value, 30, path, ruleId, issues0);
    let bs = Blob.toArray(Text.encodeUtf8(value));
    if (bs.size() < 20 or bs.size() > 30 or bs[4] != 45 or bs[7] != 45 or bs[10] != 84 or bs[13] != 58 or bs[16] != 58) {
      issues := add(issues, publicIssue("schema", ruleId # "-ISO8601", path, "datetime must use an ISO-8601 shape like 2026-06-22T10:00:00Z"));
    };
    issues;
  };

  func validateIsoDate(value : Text, path : Text, ruleId : Text, issues0 : [ValidationIssue]) : [ValidationIssue] {
    var issues = validateTextMax(value, 10, path, ruleId, issues0);
    let bs = Blob.toArray(Text.encodeUtf8(value));
    if (bs.size() != 10 or bs[4] != 45 or bs[7] != 45) {
      issues := add(issues, publicIssue("schema", ruleId # "-ISO8601-DATE", path, "date must use an ISO-8601 shape like 2026-06-22"));
    };
    issues;
  };

  func add(xs : [ValidationIssue], x : ValidationIssue) : [ValidationIssue] {
    Array.concat<ValidationIssue>(xs, [x]);
  };

  func messageVersion(g : UsageGuideline, kind : Text) : ?Text {
    for (mv in g.messageVersions.vals()) {
      if (mv.kind == kind) return ?mv.version;
    };
    null;
  };

  func currencyRule(g : UsageGuideline, code : Text) : ?CurrencyRule {
    for (c in g.currencies.vals()) {
      if (c.code == code) return ?c;
    };
    null;
  };

  func containsText(xs : [Text], value : Text) : Bool {
    for (x in xs.vals()) {
      if (x == value) return true;
    };
    false;
  };

  func bytes(t : Text) : [Nat8] {
    Blob.toArray(Text.encodeUtf8(t));
  };

  func byteNat(b : Nat8) : Nat {
    Nat8.toNat(b);
  };

  func isDigit(b : Nat8) : Bool {
    let n = byteNat(b);
    n >= 48 and n <= 57;
  };

  func isUpper(b : Nat8) : Bool {
    let n = byteNat(b);
    n >= 65 and n <= 90;
  };

  func isLower(b : Nat8) : Bool {
    let n = byteNat(b);
    n >= 97 and n <= 122;
  };

  func isAlphaNumUpper(b : Nat8) : Bool {
    isUpper(b) or isDigit(b);
  };

  func isHex(b : Nat8) : Bool {
    isDigit(b) or (byteNat(b) >= 65 and byteNat(b) <= 70) or (byteNat(b) >= 97 and byteNat(b) <= 102);
  };

  func swiftX(t : Text) : Bool {
    for (b in Text.encodeUtf8(t).vals()) {
      let n = byteNat(b);
      let ok = isUpper(b) or isLower(b) or isDigit(b)
        or n == 10 or n == 13 or n == 32
        or n == 39 or n == 40 or n == 41 or n == 43 or n == 44 or n == 45
        or n == 46 or n == 47 or n == 58 or n == 63;
      if (not ok) return false;
    };
    true;
  };

  func startsWith(t : Text, prefix : Text) : Bool {
    let tb = bytes(t);
    let pb = bytes(prefix);
    if (tb.size() < pb.size()) return false;
    var i = 0;
    while (i < pb.size()) {
      if (tb[i] != pb[i]) return false;
      i += 1;
    };
    true;
  };

  public func validCountryCode(code : Text) : Bool {
    let bs = bytes(code);
    bs.size() == 2 and isUpper(bs[0]) and isUpper(bs[1]);
  };

  public func validCurrencyCode(code : Text) : Bool {
    let bs = bytes(code);
    bs.size() == 3 and isUpper(bs[0]) and isUpper(bs[1]) and isUpper(bs[2]);
  };

  public func validBicFi(bic : Text) : Bool {
    let bs = bytes(bic);
    if (bs.size() != 8 and bs.size() != 11) return false;
    var i = 0;
    while (i < 4) { if (not isUpper(bs[i])) return false; i += 1 };
    if (not isUpper(bs[4]) or not isUpper(bs[5])) return false;
    if (not isAlphaNumUpper(bs[6]) or not isAlphaNumUpper(bs[7])) return false;
    i := 8;
    while (i < bs.size()) {
      if (not isAlphaNumUpper(bs[i])) return false;
      i += 1;
    };
    true;
  };

  public func bicCountry(bic : Text) : ?Text {
    let bs = bytes(bic);
    if (bs.size() != 8 and bs.size() != 11) return null;
    if (not validBicFi(bic)) return null;
    Text.decodeUtf8(Blob.fromArray([bs[4], bs[5]]));
  };

  public func validUetr(uetr : Text) : Bool {
    let bs = bytes(uetr);
    if (bs.size() != 36) return false;
    var i = 0;
    while (i < bs.size()) {
      let hyphen = i == 8 or i == 13 or i == 18 or i == 23;
      if (hyphen) {
        if (bs[i] != 45) return false;
      } else if (not isHex(bs[i])) return false;
      i += 1;
    };
    if (bs[14] != 52) return false;
    let v = byteNat(bs[19]);
    v == 56 or v == 57 or v == 65 or v == 66 or v == 97 or v == 98;
  };

  public func validIban(iban : Text) : Bool {
    let bs = bytes(iban);
    if (bs.size() < 15 or bs.size() > 34) return false;
    if (not isUpper(bs[0]) or not isUpper(bs[1]) or not isDigit(bs[2]) or not isDigit(bs[3])) return false;
    var rem : Nat = 0;
    var ok = true;
    var i = 4;
    while (i < bs.size() and ok) {
      switch (mod97Step(rem, bs[i])) {
        case (?r) { rem := r };
        case null { ok := false };
      };
      i += 1;
    };
    i := 0;
    while (i < 4 and ok) {
      switch (mod97Step(rem, bs[i])) {
        case (?r) { rem := r };
        case null { ok := false };
      };
      i += 1;
    };
    ok and rem == 1;
  };

  public func validEgyptianIbanShape(iban : Text) : Bool {
    let bs = bytes(iban);
    if (bs.size() != 29) return false;
    if (bs[0] != 69 or bs[1] != 71) return false;
    var i = 2;
    while (i < bs.size()) {
      if (not isDigit(bs[i])) return false;
      i += 1;
    };
    true;
  };

  public func validLei(lei : Text) : Bool {
    let bs = bytes(lei);
    if (bs.size() != 20) return false;
    if (not isDigit(bs[18]) or not isDigit(bs[19])) return false;
    var rem : Nat = 0;
    var ok = true;
    var i = 0;
    while (i < bs.size() and ok) {
      switch (mod97Step(rem, bs[i])) {
        case (?r) { rem := r };
        case null { ok := false };
      };
      i += 1;
    };
    ok and rem == 1;
  };

  func mod97Step(rem : Nat, b : Nat8) : ?Nat {
    if (isDigit(b)) {
      ?((rem * 10 + (byteNat(b) - 48)) % 97);
    } else if (isUpper(b)) {
      ?((rem * 100 + (byteNat(b) - 55)) % 97);
    } else {
      null;
    };
  };

};
