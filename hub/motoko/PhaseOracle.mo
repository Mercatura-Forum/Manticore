/// PhaseOracle.mo -- static oracle registry for the ISO 20022 hub.
///
/// The actor owns live state checks. This module owns the stable phase names,
/// oracle references, and allowed status/policy vocabularies so tests can pin
/// the review surface without instantiating the actor.

import Array "mo:core/Array";
import Text "mo:core/Text";

module {

  public let registryVersion : Text = "phase-oracle-v1-2026-06-24-c8";

  public type OracleSource = {
    id : Text;
    name : Text;
    kind : Text;
    reference : Text;
    use : Text;
  };

  public type PhaseOracle = {
    phase : Text;
    status : Text;
    verifier : Text;
    oracleSources : [OracleSource];
    implementedChecks : [Text];
    evidenceMethods : [Text];
    limitations : [Text];
    nextHardening : [Text];
  };

  public func registry() : [PhaseOracle] {
    [
      {
        phase = "guideline.configuration";
        status = "implemented";
        verifier = "verifyGuidelineOracleReport";
        oracleSources = [
          iso("iso20022", "ISO 20022 message repository", "https://www.iso20022.org/iso-20022-message-definitions"),
          iso("iso4217", "ISO 4217 currency code list", "https://www.iso.org/iso-4217-currency-codes.html"),
          iso("iso9362", "ISO 9362 BIC", "https://www.iso.org/standard/60390.html"),
          iso("iso13616", "ISO 13616 IBAN", "https://www.iso.org/standard/81090.html"),
        ];
        implementedChecks = ["message-version presence", "active currency shapes", "active country shapes", "byte caps", "settlement method"];
        evidenceMethods = ["getGuideline", "integrationProfilePacks", "verifyOraclePhases"];
        limitations = ["market-specific rulebooks must be loaded as UsageGuideline overlays"];
        nextHardening = ["signed guideline bundles", "profile diff reports", "bank-specific overlays"];
      },
      {
        phase = "xml.codec";
        status = "implemented-partial";
        verifier = "verifyXmlCodecOracleReport";
        oracleSources = [
          iso("iso20022-xml", "ISO 20022 XML schemas", "https://www.iso20022.org/iso-20022-message-definitions"),
          openSource("prowide", "Prowide ISO 20022", "https://github.com/prowide/prowide-iso20022"),
        ];
        implementedChecks = ["safe pain.001 XML import", "safe pain.008/pacs.003 XML import", "safe pacs.008 XML import", "safe pacs.009/cover XML import", "safe pain.002/pacs.002/pacs.004 XML import", "safe investigation XML import", "safe request-to-pay XML import", "safe administrative XML import", "safe camt.053/camt.054 XML import", "deterministic XML export", "DTD/entity rejection"];
        evidenceMethods = ["decodePain001Xml", "validatePain001Xml", "decodeDirectDebitXml", "validateDirectDebitXml", "decodePacs008Xml", "validatePacs008Xml", "decodePacs009Xml", "validatePacs009Xml", "decodeCoverPaymentXml", "validateCoverPaymentXml", "decodeStatusReportXml", "validateStatusReportXml", "decodeInvestigationXml", "validateInvestigationXml", "decodeRequestToPayXml", "validateRequestToPayXml", "decodeAdministrativeXml", "validateAdministrativeXml", "decodeCamt053Xml", "decodeCamt054Xml", "xmlProfileFixtureRegistry", "auditPacs008Xml", "paymentXmlBundle"];
        limitations = ["not full XSD coverage", "not all ISO branches imported"];
        nextHardening = ["full XSD/profile conformance oracle", "canonical XML semantic hash", "fixture corpus expansion"];
      },
      {
        phase = "payment.lifecycle";
        status = "implemented";
        verifier = "verifyLifecycleOracleReport";
        oracleSources = [
          iso("pain001", "pain.001 customer credit transfer", "https://www.iso20022.org/iso-20022-message-definitions"),
          iso("pacs008", "pacs.008 FI-to-FI credit transfer", "https://www.iso20022.org/iso-20022-message-definitions"),
          iso("status", "pain.002/pacs.002/pacs.004 status messages", "https://www.iso20022.org/iso-20022-message-definitions"),
        ];
        implementedChecks = ["pain.001 validation", "pacs.008 transform", "pain.002 status", "pacs.002/pacs.004 status validators"];
        evidenceMethods = ["verifyPaymentPhases", "submitPain001", "dispatchPacs008", "acknowledgePacs002", "returnPayment"];
        limitations = ["compact status model, not every ISO status branch"];
        nextHardening = ["actor-level lifecycle integration tests", "deployed pacs.002/pacs.004 replay files"];
      },
      {
        phase = "direct.debit";
        status = "implemented-compact";
        verifier = "verifyXmlCodecOracleReport";
        oracleSources = [
          iso("pain008", "pain.008 customer direct debit initiation", "https://www.iso20022.org/iso-20022-message-definitions"),
          iso("pacs003", "pacs.003 FI-to-FI direct debit", "https://www.iso20022.org/iso-20022-message-definitions"),
          standard("epc-sdd", "EPC SEPA Direct Debit public guidelines", "https://www.europeanpaymentscouncil.eu/what-we-do/epc-payment-schemes/sepa-direct-debit/sepa-direct-debit-core-rulebook-and-implementation"),
        ];
        implementedChecks = ["pain.008 compact collection form", "pacs.003 compact interbank direct-debit form", "mandate id and signature date", "sequence type FRST/RCUR/FNAL/OOFF", "deterministic XML export"];
        evidenceMethods = ["demoPain008", "demoPacs003", "decodeDirectDebitXml", "validateDirectDebitXml", "directDebitToXml"];
        limitations = ["compact direct-debit record, not full EPC mandate/profile coverage"];
        nextHardening = ["mandate lifecycle state", "SDD Core/B2B profile overlays", "return/reversal lifecycle replay"];
      },
      {
        phase = "crossborder.cover";
        status = "implemented";
        verifier = "verifyCrossBorderOracleReport";
        oracleSources = [
          iso("cbprplus", "CBPR+ usage-guideline source", "https://www.swift.com/standards/iso-20022"),
          iso("pacs009", "pacs.009 FI credit transfer", "https://www.iso20022.org/iso-20022-message-definitions"),
        ];
        implementedChecks = ["pacs.009 core", "pacs.009 COV linkage", "intermediary agents", "FX and regulatory reporting fields"];
        evidenceMethods = ["validatePacs009", "validateCoverPayment", "coverPaymentToXml"];
        limitations = ["education profile, not official CBPR+ conformance"];
        nextHardening = ["corridor-specific overlays", "full CBPR+ fixture packs"];
      },
      {
        phase = "exceptions.investigations";
        status = "implemented";
        verifier = "verifyCrossBorderOracleReport";
        oracleSources = [
          iso("camt056", "camt.056 cancellation", "https://www.iso20022.org/iso-20022-message-definitions"),
          iso("camt029", "camt.029 resolution", "https://www.iso20022.org/iso-20022-message-definitions"),
          iso("pacs028", "pacs.028 status request", "https://www.iso20022.org/iso-20022-message-definitions"),
        ];
        implementedChecks = ["message kind/version", "assignment ids", "original message id", "UETR shape", "reason/action fields", "compact camt.110/camt.111 case-management records"];
        evidenceMethods = ["validateInvestigation", "investigationToXml", "demoCamt110", "demoCamt111"];
        limitations = ["compact investigation records"];
        nextHardening = ["case linkage to payment state", "case-management workflow state"];
      },
      {
        phase = "request.to.pay";
        status = "implemented-compact";
        verifier = "verifyXmlCodecOracleReport";
        oracleSources = [
          iso("pain013", "pain.013 creditor payment activation request", "https://www.iso20022.org/iso-20022-message-definitions"),
          iso("pain014", "pain.014 creditor payment activation request status report", "https://www.iso20022.org/iso-20022-message-definitions"),
          iso("camt055", "camt.055 request cancellation", "https://www.iso20022.org/iso-20022-message-definitions"),
          standard("fedwire-rfp", "Fedwire drawdown/RFP public references", "https://www.frbservices.org/resources/financial-services/wires/iso-20022-post-implementation-faq"),
          standard("fednow-rfp", "FedNow RFP public references", "https://explore.fednow.org/resources/readiness-guide-iso-20022.pdf"),
          standard("cpmi-rfp", "CPMI RFP harmonisation references", "https://www.bis.org/cpmi/publ/d215.pdf"),
        ];
        implementedChecks = ["pain.013 request id and amount", "pain.014 original request id and ACTC/RJCT/PDNG status", "camt.055 cancellation status", "charge bearer code set", "deterministic XML export"];
        evidenceMethods = ["demoPain013", "demoPain014Accepted", "demoCamt055", "decodeRequestToPayXml", "validateRequestToPayXml", "requestToPayToXml"];
        limitations = ["compact RFP record, not full rail-specific profile coverage"];
        nextHardening = ["profile-specific RFP expiry and directory rules", "ACK/NACK correlation to RFP state", "deployed connector replay"];
      },
      {
        phase = "administrative.messages";
        status = "implemented-compact";
        verifier = "verifyXmlCodecOracleReport";
        oracleSources = [
          iso("admi002", "admi.002 message reject", "https://www.iso20022.org/iso-20022-message-definitions"),
          iso("admi004", "admi.004 connection/system event notification", "https://www.iso20022.org/iso-20022-message-definitions"),
          iso("admi007", "admi.007 receipt acknowledgement", "https://www.iso20022.org/iso-20022-message-definitions"),
          iso("admi011", "admi.011 connection/system event acknowledgement", "https://www.iso20022.org/iso-20022-message-definitions"),
        ];
        implementedChecks = ["admi.002 compact reject", "admi.004 compact connection check", "admi.007 compact receipt acknowledgement", "admi.011 compact acknowledgement", "stable status constraints"];
        evidenceMethods = ["demoAdmi002Reject", "demoAdmi004ConnectionCheck", "demoAdmi007Ack", "demoAdmi011ConnectionAck", "decodeAdministrativeXml", "validateAdministrativeXml", "administrativeToXml"];
        limitations = ["compact administrative records, not rail-specific acknowledgement workflow state"];
        nextHardening = ["rail-specific ACK/NACK correlation", "connection heartbeat state", "deployed connector replay"];
      },
      {
        phase = "compliance.screening";
        status = "implemented-partial";
        verifier = "verifyComplianceOracleReport";
        oracleSources = [
          standard("fatf-r16", "FATF Recommendation 16 payment transparency", "https://www.fatf-gafi.org/en/publications/Fatfrecommendations/update-Recommendation-16-payment-transparency-june-2025.html"),
          standard("fatf-recs", "FATF Recommendations", "https://www.fatf-gafi.org/en/publications/Fatfrecommendations/Fatf-recommendations.html"),
        ];
        implementedChecks = ["blocked country/BIC/name hooks", "high-value review", "address transparency", "FX/regulatory-reporting hooks"];
        evidenceMethods = ["screenPacs008", "screenPacs009", "screenCoverPayment", "complianceReportToXml"];
        limitations = ["no licensed sanctions/PEP data bundled"];
        nextHardening = ["case management", "signed sanctions-list snapshots", "four-eyes approval"];
      },
      {
        phase = "connector.envelope";
        status = "implemented";
        verifier = "verifyConnectorOracleReport";
        oracleSources = [
          openSource("apache-camel", "Apache Camel integration patterns", "https://camel.apache.org/"),
          openSource("opentelemetry", "OpenTelemetry semantic conventions", "https://opentelemetry.io/docs/concepts/semantic-conventions/"),
        ];
        implementedChecks = ["sequence", "checksum", "idempotency", "allowed format", "allowed endpoint", "trace id", "signature policy"];
        evidenceMethods = ["submitTransportEnvelope", "listDeadLetters", "connectorEnvelopeSigningHash"];
        limitations = ["external-attestation delegates curve verification to verifier canister"];
        nextHardening = ["native host signature verification", "HTTP putcall mailbox"];
      },
      {
        phase = "connector.outbound";
        status = "implemented";
        verifier = "verifyOutboundOracleReport";
        oracleSources = [
          openSource("apache-camel-outbox", "Enterprise outbox/retry pattern", "https://camel.apache.org/"),
          openSource("slsa-intoto", "SLSA and in-toto provenance", "https://slsa.dev/"),
        ];
        implementedChecks = ["payload hash", "lease state", "attempt count", "ACK/NACK hash", "dead-letter issues"];
        evidenceMethods = ["queuePaymentOutbound", "leaseOutboundBatches", "ackOutboundDelivery", "failOutboundDelivery"];
        limitations = ["heap map storage", "manual connector polling"];
        nextHardening = ["stable BTree outbox", "automated putcall transport"];
      },
      {
        phase = "legacy.mt103";
        status = "implemented-partial";
        verifier = "verifyLegacyMtOracleReport";
        oracleSources = [
          standard("swift-mt", "SWIFT MT standards family", "https://www.swift.com/standards"),
        ];
        implementedChecks = ["MT103 field 20", "32A", "50A/F/K", "52A", "53/54/56 evidence", "57A", "59/F", "70", "71A", "72", "MT940/MT942 61/86 statement lines", "CSV payment rows", "fixed-width payment rows"];
        evidenceMethods = ["parseMt103Fields", "decodeMt103", "decodeMt940", "decodeMt942", "decodeCsvPayments", "decodeFixedWidthPayments", "submitTransportEnvelope"];
        limitations = ["supported subset only", "not full MT option coverage", "CSV/fixed-width layouts are education profiles"];
        nextHardening = ["MT202", "bank-specific CSV/fixed layouts", "wider SWIFT option parser"];
      },
      {
        phase = "audit.evidence";
        status = "implemented";
        verifier = "verifyAuditOracleReport";
        oracleSources = [
          openSource("rekor", "Sigstore Rekor transparency log", "https://docs.sigstore.dev/logging/overview/"),
          openSource("icrc-me", "ICRC-ME audit posture", "https://github.com/Mercatura-Forum/Thebes-Protocol-/tree/main/examples/icrc-me"),
        ];
        implementedChecks = ["hash chain", "Merkle root/proof", "MMR checkpoint", "raw payload hash"];
        evidenceMethods = ["auditTip", "auditProof", "verifyAuditChain"];
        limitations = ["MMR historical node proofs need retained node history"];
        nextHardening = ["stable audit log", "exportable audit bundles"];
      },
      {
        phase = "certified.disclosure";
        status = "implemented-playground";
        verifier = "verifyCertifiedDisclosure";
        oracleSources = [
          standard("ic-certified-data", "Internet Computer certified data", "https://internetcomputer.org/docs/building-apps/network-features/data-certification/certified-data"),
          openSource("icrc3", "ICRC-3 certified transaction log pattern", "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3"),
        ];
        implementedChecks = ["certified_data 32-byte root", "audit/MMR snapshot hash", "participant balance snapshot Merkle root", "certificate-bearing query envelope"];
        evidenceMethods = ["refreshCertifiedDisclosure", "refreshCertifiedSettlementBalances", "certifiedDisclosureCertificate", "certifiedAuditDisclosure", "certifiedParticipantBalance", "verifyCertifiedDisclosure"];
        limitations = ["balance values are refreshed snapshots, not live ledger query certification", "root recomputation and certificate-tree checks are external to the canister", "deployment-network signature validation remains external hardening"];
        nextHardening = ["deployment-network signature validation in the external C6 helper", "Thebes production proof adapter", "certified witness tree for single-field proofs", "ledger-side certified balance witness integration"];
      },
      {
        phase = "participant.workflow";
        status = "implemented";
        verifier = "verifyParticipantWorkflowCorrelation";
        oracleSources = [
          iso("iso9362-directory", "ISO 9362 BIC directory identifier pattern", "https://www.iso.org/standard/60390.html"),
          iso("iso17442-lei", "ISO 17442 LEI", "https://www.iso.org/standard/78829.html"),
          standard("pfmi-access", "PFMI Principles 18 and 19", "https://www.bis.org/cpmi/publ/d101a.pdf"),
          iso("pain008-pacs003", "ISO 20022 direct-debit message family", "https://www.iso20022.org/iso-20022-message-definitions"),
          iso("pain013-pain014", "ISO 20022 request-to-pay message family", "https://www.iso20022.org/iso-20022-message-definitions"),
        ];
        implementedChecks = ["BIC/LEI participant directory records", "direct/indirect/addressable access tiers", "mandate to collection to administrative return/reject correlation", "request-to-pay presentment to response correlation", "case-management request/response correlation", "workflow message/UETR indexes"];
        evidenceMethods = ["upsertParticipantDirectoryEntry", "seedDemoParticipantDirectory", "correlateDirectDebitWorkflow", "correlateRequestToPayWorkflow", "correlateInvestigationWorkflow", "correlateAdministrativeWorkflow", "getWorkflowByMessageId", "getWorkflowByUetr", "verifyParticipantWorkflowCorrelation"];
        limitations = ["directory data is operator-supplied", "no official CBE/EBC participant directory import is bundled", "rail-specific mandate expiry and ACK/NACK SLA timers remain hardening work"];
        nextHardening = ["signed participant directory import", "scheme-specific mandate revocation/expiry rules", "deployed connector replay for workflow messages"];
      },
      {
        phase = "pfmi.self.assessment";
        status = "implemented";
        verifier = "verifyPfmiSelfAssessment";
        oracleSources = [
          standard("pfmi", "CPMI-IOSCO Principles for Financial Market Infrastructures", "https://www.bis.org/cpmi/publ/d101a.pdf"),
          standard("pfmi-disclosure", "CPMI-IOSCO Disclosure framework", "https://www.bis.org/cpmi/publ/d106.pdf"),
        ];
        implementedChecks = ["all 24 PFMI principles enumerated", "applicability/status/locus per principle", "verifier surface for code-enforceable principles", "explicit residual gaps for institutional and external gates"];
        evidenceMethods = ["pfmiSelfAssessment", "verifyPfmiSelfAssessment", "verifyOracleReadiness", "docs/PFMI_SELF_ASSESSMENT.md"];
        limitations = ["legal, governance, collateral, business-risk, custody, and FMI-link evidence are institutional/operator documents, not canister facts"];
        nextHardening = ["operator-signed PFMI disclosure pack", "published legal finality memorandum", "external assurance review"];
      },
      {
        phase = "stable.indexes";
        status = "implemented-partial";
        verifier = "verifyDuplicateOracleReport";
        oracleSources = [
          openSource("btree", "BTree ordered index pattern", "https://en.wikipedia.org/wiki/B-tree"),
        ];
        implementedChecks = ["Bloom duplicate telemetry", "exact UETR/messageId authority", "ordered payment status/account/agent indexes", "ordered outbound connector/status index", "Region checkpoint hash/invariant checks"];
        evidenceMethods = ["duplicateSignalFor", "secondaryIndexHealth", "checkpointSecondaryIndexes", "rebuildSecondaryIndexes", "listPaymentViewsByStatus", "listPaymentViewsByStatusStable", "listPaymentViewsByCreditorAgent", "listPaymentViewsByCreditorAgentStable", "camt053StatementByAccount", "camt053StatementByAccountStable", "listOutboundBatchesByConnectorStatus", "listOutboundBatchesByConnectorStatusStable"];
        limitations = ["range query engine is still heap-first; Region checkpoints are full-index snapshots, not mutable BTree nodes"];
        nextHardening = ["mutable Region-backed BTree", "incremental stable node updates", "stable exact UETR/messageId maps"];
      },
    ];
  };

  public func validPolicyMode(mode : Text) : Bool {
    mode == "none"
      or mode == "signature-presence"
      or mode == "thebes-caller"
      or mode == "memphis-session"
      or mode == "external-attestation";
  };

  public func validSignatureScheme(scheme : Text) : Bool {
    scheme == "none"
      or scheme == "detached-opaque"
      or scheme == "thebes-ingress"
      or scheme == "memphis-derived-principal"
      or scheme == "ed25519"
      or scheme == "frost-ed25519"
      or scheme == "mayo2"
      or scheme == "reference-sha256"
      or scheme == "threshold-schnorr-ed25519"
      or scheme == "bank-hsm"
      or scheme == "institution-attestation";
  };

  public func validOutboundStatus(status : Text) : Bool {
    status == "queued"
      or status == "leased"
      or status == "acked"
      or status == "nacked"
      or status == "dead-letter";
  };

  public func validAckStatus(status : Text) : Bool {
    status == "ACK" or status == "NACK";
  };

  public func implementedPhases() : [PhaseOracle] {
    Array.filter<PhaseOracle>(registry(), func(p) { p.status != "planned" });
  };

  func iso(id : Text, name : Text, reference : Text) : OracleSource {
    { id; name; kind = "standard"; reference; use = "source-of-truth model and field semantics" };
  };

  func standard(id : Text, name : Text, reference : Text) : OracleSource {
    { id; name; kind = "standard"; reference; use = "control objective and policy oracle" };
  };

  func openSource(id : Text, name : Text, reference : Text) : OracleSource {
    { id; name; kind = "open-source"; reference; use = "implementation pattern and differential-oracle inspiration" };
  };
};
