/// ISO20022Xml.mo -- profile-scoped XML codec for the Thebes ISO 20022 hub.
///
/// This is not a general-purpose XML library. It is a strict, safe subset
/// codec for the message shapes this canister currently supports. The parser
/// rejects DTD/entity declarations and maps known ISO paths into typed records;
/// the serializer emits deterministic XML for bank-facing fixtures and exports.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import ISO "ISO20022";

module {

  public type Pain001Decode = {
    #ok : ISO.CustomerCreditTransferInitiation;
    #err : [ISO.ValidationIssue];
  };

  public type Pacs008Decode = {
    #ok : ISO.Pacs008CreditTransfer;
    #err : [ISO.ValidationIssue];
  };

  public type Pacs009Decode = {
    #ok : ISO.Pacs009FinancialInstitutionCreditTransfer;
    #err : [ISO.ValidationIssue];
  };

  public type CoverPaymentDecode = {
    #ok : ISO.CoverPayment;
    #err : [ISO.ValidationIssue];
  };

  public type InvestigationDecode = {
    #ok : ISO.InvestigationMessage;
    #err : [ISO.ValidationIssue];
  };

  public type StatusReportDecode = {
    #ok : ISO.StatusReport;
    #err : [ISO.ValidationIssue];
  };

  public type StatementDecode = {
    #ok : [ISO.StatementEntry];
    #err : [ISO.ValidationIssue];
  };

  public type RequestToPayDecode = {
    #ok : ISO.RequestToPayMessage;
    #err : [ISO.ValidationIssue];
  };

  public type DirectDebitDecode = {
    #ok : ISO.DirectDebitMessage;
    #err : [ISO.ValidationIssue];
  };

  public type AdministrativeDecode = {
    #ok : ISO.AdministrativeMessage;
    #err : [ISO.ValidationIssue];
  };

  public let codecVersion : Text = "iso20022-xml-subset-v1";

  let PAIN001_NS = "urn:iso:std:iso:20022:tech:xsd:pain.001.001.09";
  let PAIN008_NS = "urn:iso:std:iso:20022:tech:xsd:pain.008.001.08";
  let PAIN013_NS = "urn:iso:std:iso:20022:tech:xsd:pain.013.001.10";
  let PAIN014_NS = "urn:iso:std:iso:20022:tech:xsd:pain.014.001.10";
  let PACS003_NS = "urn:iso:std:iso:20022:tech:xsd:pacs.003.001.08";
  let PACS008_NS = "urn:iso:std:iso:20022:tech:xsd:pacs.008.001.08";
  let PACS002_NS = "urn:iso:std:iso:20022:tech:xsd:pacs.002.001.10";
  let PACS004_NS = "urn:iso:std:iso:20022:tech:xsd:pacs.004.001.09";
  let PACS009_NS = "urn:iso:std:iso:20022:tech:xsd:pacs.009.001.08";
  let PACS028_NS = "urn:iso:std:iso:20022:tech:xsd:pacs.028.001.03";
  let ADMI002_NS = "urn:iso:std:iso:20022:tech:xsd:admi.002.001.01";
  let ADMI004_NS = "urn:iso:std:iso:20022:tech:xsd:admi.004.001.01";
  let ADMI007_NS = "urn:iso:std:iso:20022:tech:xsd:admi.007.001.01";
  let ADMI011_NS = "urn:iso:std:iso:20022:tech:xsd:admi.011.001.01";
  let CAMT029_NS = "urn:iso:std:iso:20022:tech:xsd:camt.029.001.09";
  let CAMT055_NS = "urn:iso:std:iso:20022:tech:xsd:camt.055.001.09";
  let CAMT056_NS = "urn:iso:std:iso:20022:tech:xsd:camt.056.001.08";
  let CAMT110_NS = "urn:iso:std:iso:20022:tech:xsd:camt.110.001.01";
  let CAMT111_NS = "urn:iso:std:iso:20022:tech:xsd:camt.111.001.01";
  let CAMT053_NS = "urn:iso:std:iso:20022:tech:xsd:camt.053.001.08";
  let CAMT054_NS = "urn:iso:std:iso:20022:tech:xsd:camt.054.001.08";

  public func pain001ToXml(doc : ISO.CustomerCreditTransferInitiation) : Text {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"" # PAIN001_NS # "\">\n"
    # "  <CstmrCdtTrfInitn>\n"
    # "    <GrpHdr>\n"
    # elem(6, "MsgId", doc.messageId)
    # elem(6, "CreDtTm", doc.creationDateTime)
    # "      <NbOfTxs>1</NbOfTxs>\n"
    # partyXml(6, "InitgPty", doc.initiatingParty)
    # "    </GrpHdr>\n"
    # "    <PmtInf>\n"
    # elem(6, "PmtInfId", doc.messageId)
    # "      <PmtMtd>TRF</PmtMtd>\n"
    # optElem(6, "ReqdExctnDt", doc.requestedExecutionDate)
    # paymentTypeXml(6, doc.paymentTypeInformation)
    # partyXml(6, "Dbtr", doc.debtor)
    # accountXml(6, "DbtrAcct", doc.debtorAccount)
    # agentXml(6, "DbtrAgt", doc.debtorAgent)
    # "      <CdtTrfTxInf>\n"
    # "        <PmtId>\n"
    # elem(10, "EndToEndId", doc.endToEndId)
    # optElem(10, "UETR", doc.requestedUetr)
    # "        </PmtId>\n"
    # amountXml(8, "InstdAmt", doc.instructedAmount)
    # agentXml(8, "CdtrAgt", doc.creditorAgent)
    # partyXml(8, "Cdtr", doc.creditor)
    # accountXml(8, "CdtrAcct", doc.creditorAccount)
    # remittanceXml(8, doc.remittanceInformation)
    # "      </CdtTrfTxInf>\n"
    # "    </PmtInf>\n"
    # "  </CstmrCdtTrfInitn>\n"
    # "</Document>\n";
  };

  public func pacs008ToXml(doc : ISO.Pacs008CreditTransfer) : Text {
    let header = switch (doc.businessApplicationHeader) {
      case (?h) {
        "<AppHdr xmlns=\"urn:iso:std:iso:20022:tech:xsd:head.001.001.02\">\n"
        # "  <Fr><FIId><FinInstnId><BICFI>" # escape(h.fromBic) # "</BICFI></FinInstnId></FIId></Fr>\n"
        # "  <To><FIId><FinInstnId><BICFI>" # escape(h.toBic) # "</BICFI></FinInstnId></FIId></To>\n"
        # elem(2, "BizMsgIdr", h.businessMessageId)
        # elem(2, "MsgDefIdr", h.messageDefinitionId)
        # optElem(2, "BizSvc", h.businessService)
        # elem(2, "CreDt", h.creationDateTime)
        # optElem(2, "UETR", h.uetr)
        # "</AppHdr>\n";
      };
      case null "";
    };
    header
    # "<Document xmlns=\"" # PACS008_NS # "\">\n"
    # "  <FIToFICstmrCdtTrf>\n"
    # "    <GrpHdr>\n"
    # elem(6, "MsgId", doc.messageId)
    # elem(6, "CreDtTm", doc.creationDateTime)
    # elem(6, "NbOfTxs", Nat.toText(doc.transactionCount))
    # "      <SttlmInf>\n"
    # elem(8, "SttlmMtd", doc.settlementInstruction.settlementMethod)
    # optElem(8, "ClrSys", doc.settlementInstruction.clearingSystem)
    # "      </SttlmInf>\n"
    # "    </GrpHdr>\n"
    # "    <CdtTrfTxInf>\n"
    # "      <PmtId>\n"
    # elem(8, "EndToEndId", doc.endToEndId)
    # optElem(8, "UETR", doc.uetr)
    # "      </PmtId>\n"
    # paymentTypeXml(6, doc.paymentTypeInformation)
    # amountXml(6, "InstdAmt", doc.instructedAmount)
    # agentXml(6, "DbtrAgt", doc.debtorAgent)
    # partyXml(6, "Dbtr", doc.debtor)
    # accountXml(6, "DbtrAcct", doc.debtorAccount)
    # agentXml(6, "CdtrAgt", doc.creditorAgent)
    # partyXml(6, "Cdtr", doc.creditor)
    # accountXml(6, "CdtrAcct", doc.creditorAccount)
    # remittanceXml(6, doc.remittanceInformation)
    # "    </CdtTrfTxInf>\n"
    # "  </FIToFICstmrCdtTrf>\n"
    # "</Document>\n";
  };

  public func statusReportToXml(doc : ISO.StatusReport) : Text {
    let ns = if (doc.messageKind == "pacs.004") PACS004_NS else if (doc.messageKind == "pacs.002") PACS002_NS else PAIN001_NS;
    let root = if (doc.messageKind == "pacs.004") "PmtRtr" else if (doc.messageKind == "pacs.002") "FIToFIPmtStsRpt" else "CstmrPmtStsRpt";
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"" # ns # "\">\n"
    # "  <" # root # ">\n"
    # "    <GrpHdr>\n"
    # elem(6, "MsgId", doc.messageId)
    # elem(6, "CreDtTm", doc.creationDateTime)
    # "    </GrpHdr>\n"
    # "    <OrgnlGrpInfAndSts>\n"
    # elem(6, "OrgnlMsgId", doc.originalMessageId)
    # elem(6, "OrgnlMsgNmId", doc.messageVersion)
    # "    </OrgnlGrpInfAndSts>\n"
    # "    <TxInfAndSts>\n"
    # elem(6, "OrgnlUETR", doc.originalUetr)
    # elem(6, "TxSts", doc.transactionStatus)
    # optElem(6, "Rsn", doc.reason)
    # "    </TxInfAndSts>\n"
    # "  </" # root # ">\n"
    # "</Document>\n";
  };

  public func pacs009ToXml(doc : ISO.Pacs009FinancialInstitutionCreditTransfer) : Text {
    let header = switch (doc.businessApplicationHeader) {
      case (?h) {
        "<AppHdr xmlns=\"urn:iso:std:iso:20022:tech:xsd:head.001.001.02\">\n"
        # "  <Fr><FIId><FinInstnId><BICFI>" # escape(h.fromBic) # "</BICFI></FinInstnId></FIId></Fr>\n"
        # "  <To><FIId><FinInstnId><BICFI>" # escape(h.toBic) # "</BICFI></FinInstnId></FIId></To>\n"
        # elem(2, "BizMsgIdr", h.businessMessageId)
        # elem(2, "MsgDefIdr", h.messageDefinitionId)
        # optElem(2, "BizSvc", h.businessService)
        # elem(2, "CreDt", h.creationDateTime)
        # optElem(2, "UETR", h.uetr)
        # "</AppHdr>\n";
      };
      case null "";
    };
    header
    # "<Document xmlns=\"" # PACS009_NS # "\">\n"
    # "  <FICdtTrf>\n"
    # "    <GrpHdr>\n"
    # elem(6, "MsgId", doc.messageId)
    # elem(6, "CreDtTm", doc.creationDateTime)
    # elem(6, "NbOfTxs", Nat.toText(doc.transactionCount))
    # "      <SttlmInf>\n"
    # elem(8, "SttlmMtd", doc.settlementInstruction.settlementMethod)
    # optElem(8, "ClrSys", doc.settlementInstruction.clearingSystem)
    # "      </SttlmInf>\n"
    # "    </GrpHdr>\n"
    # "    <CdtTrfTxInf>\n"
    # "      <PmtId>\n"
    # elem(8, "InstrId", doc.instructionId)
    # elem(8, "EndToEndId", doc.endToEndId)
    # optElem(8, "UETR", doc.uetr)
    # "      </PmtId>\n"
    # amountXml(6, "IntrBkSttlmAmt", doc.instructedAmount)
    # agentXml(6, "DbtrAgt", doc.debtorAgent)
    # agentXml(6, "CdtrAgt", doc.creditorAgent)
    # agentXml(6, "Dbtr", doc.debtorInstitution)
    # agentXml(6, "Cdtr", doc.creditorInstitution)
    # routingXml(6, doc.routing)
    # elem(6, "COV", if (doc.isCover) "true" else "false")
    # optElem(6, "UndrlygPacs008MsgId", doc.underlyingPacs008MessageId)
    # "    </CdtTrfTxInf>\n"
    # "  </FICdtTrf>\n"
    # "</Document>\n";
  };

  public func coverPaymentToXml(cover : ISO.CoverPayment) : Text {
    "<CoverPaymentBundle codec=\"" # codecVersion # "\">\n"
    # "  <DirectPacs008>\n"
    # indentBlock(pacs008ToXml(cover.directMessage), 4)
    # "  </DirectPacs008>\n"
    # "  <CoverPacs009>\n"
    # indentBlock(pacs009ToXml(cover.coverMessage), 4)
    # "  </CoverPacs009>\n"
    # elem(2, "Method", cover.method)
    # "</CoverPaymentBundle>\n";
  };

  public func investigationToXml(doc : ISO.InvestigationMessage) : Text {
    let ns =
      if (doc.messageKind == "camt.056") CAMT056_NS
      else if (doc.messageKind == "camt.029") CAMT029_NS
      else if (doc.messageKind == "camt.110") CAMT110_NS
      else if (doc.messageKind == "camt.111") CAMT111_NS
      else PACS028_NS;
    let root =
      if (doc.messageKind == "camt.056") "FIToFIPmtCxlReq"
      else if (doc.messageKind == "camt.029") "RsltnOfInvstgtn"
      else if (doc.messageKind == "camt.110") "InvstgtnReq"
      else if (doc.messageKind == "camt.111") "InvstgtnRspn"
      else "FIToFIPmtStsReq";
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"" # ns # "\">\n"
    # "  <" # root # ">\n"
    # "    <Assgnmt>\n"
    # elem(6, "Id", doc.assignmentId)
    # elem(6, "CreDtTm", doc.creationDateTime)
    # "    </Assgnmt>\n"
    # "    <Undrlyg>\n"
    # elem(6, "MsgId", doc.messageId)
    # elem(6, "OrgnlMsgId", doc.originalMessageId)
    # optElem(6, "OrgnlUETR", doc.originalUetr)
    # elem(6, "RsnCd", doc.reasonCode)
    # optElem(6, "ReqdActn", doc.requestedAction)
    # investigationInfoXml(6, doc.additionalInfo)
    # "    </Undrlyg>\n"
    # "  </" # root # ">\n"
    # "</Document>\n";
  };

  public func requestToPayToXml(doc : ISO.RequestToPayMessage) : Text {
    let ns =
      if (doc.messageKind == "pain.013") PAIN013_NS
      else if (doc.messageKind == "pain.014") PAIN014_NS
      else CAMT055_NS;
    let root =
      if (doc.messageKind == "pain.013") "CdtrPmtActvtnReq"
      else if (doc.messageKind == "pain.014") "CdtrPmtActvtnReqStsRpt"
      else "PmtCxlReq";
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"" # ns # "\">\n"
    # "  <" # root # ">\n"
    # "    <GrpHdr>\n"
    # elem(6, "MsgId", doc.messageId)
    # elem(6, "CreDtTm", doc.creationDateTime)
    # "    </GrpHdr>\n"
    # "    <RTP>\n"
    # elem(6, "ReqId", doc.requestId)
    # optElem(6, "OrgnlReqId", doc.originalRequestId)
    # partyXml(6, "Dbtr", doc.debtor)
    # accountXml(6, "DbtrAcct", doc.debtorAccount)
    # agentXml(6, "DbtrAgt", doc.debtorAgent)
    # partyXml(6, "Cdtr", doc.creditor)
    # accountXml(6, "CdtrAcct", doc.creditorAccount)
    # agentXml(6, "CdtrAgt", doc.creditorAgent)
    # amountXml(6, "ReqdAmt", doc.requestedAmount)
    # optElem(6, "ReqdExctnDt", doc.requestedExecutionDate)
    # optElem(6, "ChrgBr", doc.chargeBearer)
    # optElem(6, "ReqSts", doc.status)
    # optElem(6, "Rsn", doc.reason)
    # remittanceXml(6, doc.remittanceInformation)
    # "    </RTP>\n"
    # "  </" # root # ">\n"
    # "</Document>\n";
  };

  public func directDebitToXml(doc : ISO.DirectDebitMessage) : Text {
    if (doc.messageKind == "pacs.003") {
      let header = switch (doc.businessApplicationHeader) {
        case (?h) {
          "<AppHdr xmlns=\"urn:iso:std:iso:20022:tech:xsd:head.001.001.02\">\n"
          # "  <Fr><FIId><FinInstnId><BICFI>" # escape(h.fromBic) # "</BICFI></FinInstnId></FIId></Fr>\n"
          # "  <To><FIId><FinInstnId><BICFI>" # escape(h.toBic) # "</BICFI></FinInstnId></FIId></To>\n"
          # elem(2, "BizMsgIdr", h.businessMessageId)
          # elem(2, "MsgDefIdr", h.messageDefinitionId)
          # optElem(2, "BizSvc", h.businessService)
          # elem(2, "CreDt", h.creationDateTime)
          # optElem(2, "UETR", h.uetr)
          # "</AppHdr>\n";
        };
        case null "";
      };
      let settlement = switch (doc.settlementInstruction) {
        case (?s) {
          "      <SttlmInf><SttlmMtd>" # escape(s.settlementMethod) # "</SttlmMtd>"
          # optInline("ClrSys", s.clearingSystem)
          # "</SttlmInf>\n";
        };
        case null "";
      };
      header
      # "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      # "<Document xmlns=\"" # PACS003_NS # "\">\n"
      # "  <FIToFICstmrDrctDbt>\n"
      # "    <GrpHdr>\n"
      # elem(6, "MsgId", doc.messageId)
      # elem(6, "CreDtTm", doc.creationDateTime)
      # elem(6, "NbOfTxs", Nat.toText(doc.transactionCount))
      # settlement
      # "    </GrpHdr>\n"
      # directDebitTxXml(4, doc, true, true)
      # "  </FIToFICstmrDrctDbt>\n"
      # "</Document>\n";
    } else {
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      # "<Document xmlns=\"" # PAIN008_NS # "\">\n"
      # "  <CstmrDrctDbtInitn>\n"
      # "    <GrpHdr>\n"
      # elem(6, "MsgId", doc.messageId)
      # elem(6, "CreDtTm", doc.creationDateTime)
      # elem(6, "NbOfTxs", Nat.toText(doc.transactionCount))
      # partyXml(6, "InitgPty", doc.initiatingParty)
      # "    </GrpHdr>\n"
      # "    <PmtInf>\n"
      # elem(6, "PmtInfId", doc.messageId)
      # "      <PmtMtd>DD</PmtMtd>\n"
      # optElem(6, "ReqdColltnDt", doc.requestedCollectionDate)
      # paymentTypeXml(6, doc.paymentTypeInformation)
      # partyXml(6, "Cdtr", doc.creditor)
      # accountXml(6, "CdtrAcct", doc.creditorAccount)
      # agentXml(6, "CdtrAgt", doc.creditorAgent)
      # directDebitTxXml(6, doc, false, false)
      # "    </PmtInf>\n"
      # "  </CstmrDrctDbtInitn>\n"
      # "</Document>\n";
    };
  };

  public func administrativeToXml(doc : ISO.AdministrativeMessage) : Text {
    let ns =
      if (doc.messageKind == "admi.002") ADMI002_NS
      else if (doc.messageKind == "admi.004") ADMI004_NS
      else if (doc.messageKind == "admi.007") ADMI007_NS
      else ADMI011_NS;
    let root =
      if (doc.messageKind == "admi.002") "MessageReject"
      else if (doc.messageKind == "admi.004") "SystemEventNotification"
      else if (doc.messageKind == "admi.007") "ReceiptAcknowledgement"
      else "SystemEventAcknowledgement";
    var info = "";
    for (line in doc.additionalInfo.vals()) {
      info #= elem(6, "AddtlInf", line);
    };
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"" # ns # "\">\n"
    # "  <" # root # ">\n"
    # "    <EvtInf>\n"
    # elem(6, "MsgId", doc.messageId)
    # elem(6, "CreDtTm", doc.creationDateTime)
    # optElem(6, "RltdMsgId", doc.relatedMessageId)
    # optElem(6, "RltdUETR", doc.relatedUetr)
    # elem(6, "EvtCd", doc.eventCode)
    # elem(6, "Sts", doc.status)
    # optElem(6, "Rsn", doc.reason)
    # info
    # "    </EvtInf>\n"
    # "  </" # root # ">\n"
    # "</Document>\n";
  };

  public func complianceReportToXml(report : ISO.ComplianceReport) : Text {
    var findings = "";
    for (f in report.findings.vals()) {
      findings #= "    <Finding>\n"
        # elem(6, "Severity", f.severity)
        # elem(6, "RuleId", f.ruleId)
        # elem(6, "Path", f.path)
        # elem(6, "Message", f.message)
        # elem(6, "Action", f.action)
        # elem(6, "Score", Nat.toText(f.score))
        # "    </Finding>\n";
    };
    "<ComplianceReport codec=\"" # codecVersion # "\">\n"
    # elem(2, "ProfileId", report.profileId)
    # elem(2, "Decision", report.decision)
    # elem(2, "RiskScore", Nat.toText(report.riskScore))
    # elem(2, "FindingCount", Nat.toText(report.findingCount))
    # "  <Findings>\n"
    # findings
    # "  </Findings>\n"
    # "</ComplianceReport>\n";
  };

  public func camt054ToXml(entry : ISO.StatementEntry) : Text {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"" # CAMT054_NS # "\">\n"
    # "  <BkToCstmrDbtCdtNtfctn>\n"
    # "    <Ntfctn>\n"
    # statementEntryXml(6, entry)
    # "    </Ntfctn>\n"
    # "  </BkToCstmrDbtCdtNtfctn>\n"
    # "</Document>\n";
  };

  public func camt053ToXml(entries : [ISO.StatementEntry]) : Text {
    var body = "";
    for (entry in entries.vals()) {
      body #= statementEntryXml(6, entry);
    };
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    # "<Document xmlns=\"" # CAMT053_NS # "\">\n"
    # "  <BkToCstmrStmt>\n"
    # "    <Stmt>\n"
    # body
    # "    </Stmt>\n"
    # "  </BkToCstmrStmt>\n"
    # "</Document>\n";
  };

  public func decodePain001(xml : Blob) : Pain001Decode {
    switch (Text.decodeUtf8(xml)) {
      case null {
        #err([ISO.publicIssue("schema", "XML-UTF8", "$xml", "XML payload must be valid UTF-8")]);
      };
      case (?text) {
        let safety = safetyIssues(text, xml.size());
        if (safety.size() > 0) return #err(safety);
        let bytes = Blob.toArray(xml);
        switch (element(bytes, "CstmrCdtTrfInitn")) {
          case null #err([ISO.publicIssue("schema", "XML-ROOT", "$xml", "pain.001 XML must contain CstmrCdtTrfInitn")]);
          case (?root) {
            let issues0 : [ISO.ValidationIssue] = [];
            let grp = requireElement(root.content, "GrpHdr", "$.Document.CstmrCdtTrfInitn.GrpHdr", issues0);
            let pmtInf = requireElement(root.content, "PmtInf", "$.Document.CstmrCdtTrfInitn.PmtInf", grp.issues);
            let tx = switch (pmtInf.element) {
              case (?p) requireElement(p.content, "CdtTrfTxInf", "$.Document.CstmrCdtTrfInitn.PmtInf.CdtTrfTxInf", pmtInf.issues);
              case null { { element = null; issues = pmtInf.issues } };
            };
            var issues = tx.issues;

            let messageId = requiredTextFromOpt(grp.element, "MsgId", "$.GrpHdr.MsgId", issues);
            issues := messageId.issues;
            let creationDateTime = requiredTextFromOpt(grp.element, "CreDtTm", "$.GrpHdr.CreDtTm", issues);
            issues := creationDateTime.issues;
            let requestedExecutionDate = optionalTextFromOpt(pmtInf.element, "ReqdExctnDt");
            let endToEndId = requiredNestedText(tx.element, ["PmtId", "EndToEndId"], "$.CdtTrfTxInf.PmtId.EndToEndId", issues);
            issues := endToEndId.issues;
            let requestedUetr = optionalNestedText(tx.element, ["PmtId", "UETR"]);

            let amt = requiredAmount(tx.element, "$.CdtTrfTxInf.Amt.InstdAmt", "InstdAmt", issues);
            issues := amt.issues;

            let initiatingParty = partyFromOpt(grp.element, "InitgPty", "initiating party", "$.GrpHdr.InitgPty", issues);
            issues := initiatingParty.issues;
            let debtor = partyFromOpt(pmtInf.element, "Dbtr", "debtor", "$.PmtInf.Dbtr", issues);
            issues := debtor.issues;
            let debtorAccount = accountFromOpt(pmtInf.element, "DbtrAcct", "$.PmtInf.DbtrAcct", issues);
            issues := debtorAccount.issues;
            let debtorAgent = agentFromOpt(pmtInf.element, "DbtrAgt", "$.PmtInf.DbtrAgt", issues);
            issues := debtorAgent.issues;
            let creditor = partyFromOpt(tx.element, "Cdtr", "creditor", "$.CdtTrfTxInf.Cdtr", issues);
            issues := creditor.issues;
            let creditorAccount = accountFromOpt(tx.element, "CdtrAcct", "$.CdtTrfTxInf.CdtrAcct", issues);
            issues := creditorAccount.issues;
            let creditorAgent = agentFromOpt(tx.element, "CdtrAgt", "$.CdtTrfTxInf.CdtrAgt", issues);
            issues := creditorAgent.issues;
            let paymentType = paymentTypeFromOpt(pmtInf.element);
            let remittance = remittanceFromOpt(tx.element);

            if (issues.size() > 0) return #err(issues);
            #ok({
              messageId = messageId.value;
              creationDateTime = creationDateTime.value;
              requestedExecutionDate;
              initiatingParty = initiatingParty.value;
              debtor = debtor.value;
              debtorAccount = debtorAccount.value;
              debtorAgent = debtorAgent.value;
              creditor = creditor.value;
              creditorAccount = creditorAccount.value;
              creditorAgent = creditorAgent.value;
              paymentTypeInformation = paymentType;
              instructedAmount = amt.value;
              endToEndId = endToEndId.value;
              remittanceInformation = remittance;
              requestedUetr;
            });
          };
        };
      };
    };
  };

  public func decodePacs008(xml : Blob) : Pacs008Decode {
    switch (Text.decodeUtf8(xml)) {
      case null {
        #err([ISO.publicIssue("schema", "XML-UTF8", "$xml", "XML payload must be valid UTF-8")]);
      };
      case (?text) {
        let safety = safetyIssues(text, xml.size());
        if (safety.size() > 0) return #err(safety);
        let bytes = Blob.toArray(xml);
        let appHdr = element(bytes, "AppHdr");
        switch (element(bytes, "FIToFICstmrCdtTrf")) {
          case null #err([ISO.publicIssue("schema", "XML-ROOT", "$xml", "pacs.008 XML must contain FIToFICstmrCdtTrf")]);
          case (?root) {
            let issues0 : [ISO.ValidationIssue] = [];
            let grp = requireElement(root.content, "GrpHdr", "$.Document.FIToFICstmrCdtTrf.GrpHdr", issues0);
            let tx = requireElement(root.content, "CdtTrfTxInf", "$.Document.FIToFICstmrCdtTrf.CdtTrfTxInf", grp.issues);
            var issues = tx.issues;

            let messageId = requiredTextFromOpt(grp.element, "MsgId", "$.GrpHdr.MsgId", issues);
            issues := messageId.issues;
            let creationDateTime = requiredTextFromOpt(grp.element, "CreDtTm", "$.GrpHdr.CreDtTm", issues);
            issues := creationDateTime.issues;
            let txCount = requiredNatFromOpt(grp.element, "NbOfTxs", "$.GrpHdr.NbOfTxs", issues);
            issues := txCount.issues;
            let sttlmMethod = requiredNestedText(grp.element, ["SttlmInf", "SttlmMtd"], "$.GrpHdr.SttlmInf.SttlmMtd", issues);
            issues := sttlmMethod.issues;
            let clearingSystem = optionalNestedText(grp.element, ["SttlmInf", "ClrSys"]);

            let endToEndId = requiredNestedText(tx.element, ["PmtId", "EndToEndId"], "$.CdtTrfTxInf.PmtId.EndToEndId", issues);
            issues := endToEndId.issues;
            let uetr = optionalNestedText(tx.element, ["PmtId", "UETR"]);

            let amt = requiredAmount(tx.element, "$.CdtTrfTxInf.Amt.InstdAmt", "InstdAmt", issues);
            issues := amt.issues;

            let debtorAgent = agentFromOpt(tx.element, "DbtrAgt", "$.CdtTrfTxInf.DbtrAgt", issues);
            issues := debtorAgent.issues;
            let debtor = partyFromOpt(tx.element, "Dbtr", "debtor", "$.CdtTrfTxInf.Dbtr", issues);
            issues := debtor.issues;
            let debtorAccount = accountFromOpt(tx.element, "DbtrAcct", "$.CdtTrfTxInf.DbtrAcct", issues);
            issues := debtorAccount.issues;
            let creditorAgent = agentFromOpt(tx.element, "CdtrAgt", "$.CdtTrfTxInf.CdtrAgt", issues);
            issues := creditorAgent.issues;
            let creditor = partyFromOpt(tx.element, "Cdtr", "creditor", "$.CdtTrfTxInf.Cdtr", issues);
            issues := creditor.issues;
            let creditorAccount = accountFromOpt(tx.element, "CdtrAcct", "$.CdtTrfTxInf.CdtrAcct", issues);
            issues := creditorAccount.issues;

            let header = headerFromOpt(appHdr, messageId.value, creationDateTime.value, uetr, "pacs.008.001.08");
            let paymentType = paymentTypeFromOpt(tx.element);
            let remittance = remittanceFromOpt(tx.element);

            if (issues.size() > 0) return #err(issues);
            #ok({
              businessApplicationHeader = header;
              messageId = messageId.value;
              creationDateTime = creationDateTime.value;
              settlementInstruction = { settlementMethod = sttlmMethod.value; clearingSystem };
              paymentTypeInformation = paymentType;
              uetr;
              endToEndId = endToEndId.value;
              instructedAmount = amt.value;
              debtor = debtor.value;
              debtorAccount = debtorAccount.value;
              debtorAgent = debtorAgent.value;
              creditor = creditor.value;
              creditorAccount = creditorAccount.value;
              creditorAgent = creditorAgent.value;
              remittanceInformation = remittance;
              transactionCount = txCount.value;
            });
          };
        };
      };
    };
  };

  public func decodePacs009(xml : Blob) : Pacs009Decode {
    switch (Text.decodeUtf8(xml)) {
      case null {
        #err([ISO.publicIssue("schema", "XML-UTF8", "$xml", "XML payload must be valid UTF-8")]);
      };
      case (?text) {
        let safety = safetyIssues(text, xml.size());
        if (safety.size() > 0) return #err(safety);
        let bytes = Blob.toArray(xml);
        let appHdr = element(bytes, "AppHdr");
        switch (element(bytes, "FICdtTrf")) {
          case null #err([ISO.publicIssue("schema", "XML-ROOT", "$xml", "pacs.009 XML must contain FICdtTrf")]);
          case (?root) {
            let issues0 : [ISO.ValidationIssue] = [];
            let grp = requireElement(root.content, "GrpHdr", "$.Document.FICdtTrf.GrpHdr", issues0);
            let tx = requireElement(root.content, "CdtTrfTxInf", "$.Document.FICdtTrf.CdtTrfTxInf", grp.issues);
            var issues = tx.issues;

            let messageId = requiredTextFromOpt(grp.element, "MsgId", "$.GrpHdr.MsgId", issues);
            issues := messageId.issues;
            let creationDateTime = requiredTextFromOpt(grp.element, "CreDtTm", "$.GrpHdr.CreDtTm", issues);
            issues := creationDateTime.issues;
            let txCount = requiredNatFromOpt(grp.element, "NbOfTxs", "$.GrpHdr.NbOfTxs", issues);
            issues := txCount.issues;
            let sttlmMethod = requiredNestedText(grp.element, ["SttlmInf", "SttlmMtd"], "$.GrpHdr.SttlmInf.SttlmMtd", issues);
            issues := sttlmMethod.issues;
            let clearingSystem = optionalNestedText(grp.element, ["SttlmInf", "ClrSys"]);

            let instructionId = requiredNestedText(tx.element, ["PmtId", "InstrId"], "$.CdtTrfTxInf.PmtId.InstrId", issues);
            issues := instructionId.issues;
            let endToEndId = requiredNestedText(tx.element, ["PmtId", "EndToEndId"], "$.CdtTrfTxInf.PmtId.EndToEndId", issues);
            issues := endToEndId.issues;
            let uetr = optionalNestedText(tx.element, ["PmtId", "UETR"]);
            let amt = requiredAmount(tx.element, "$.CdtTrfTxInf.Amt.IntrBkSttlmAmt", "IntrBkSttlmAmt", issues);
            issues := amt.issues;

            let debtorAgent = agentFromOpt(tx.element, "DbtrAgt", "$.CdtTrfTxInf.DbtrAgt", issues);
            issues := debtorAgent.issues;
            let creditorAgent = agentFromOpt(tx.element, "CdtrAgt", "$.CdtTrfTxInf.CdtrAgt", issues);
            issues := creditorAgent.issues;
            let debtorInstitution = agentFromOpt(tx.element, "Dbtr", "$.CdtTrfTxInf.Dbtr", issues);
            issues := debtorInstitution.issues;
            let creditorInstitution = agentFromOpt(tx.element, "Cdtr", "$.CdtTrfTxInf.Cdtr", issues);
            issues := creditorInstitution.issues;
            let routing = routingFromOpt(tx.element, issues);
            issues := routing.issues;
            let isCover = switch (optionalTextFromOpt(tx.element, "COV")) { case (?"true") true; case _ false };
            let underlyingPacs008MessageId = optionalTextFromOpt(tx.element, "UndrlygPacs008MsgId");
            let header = headerFromOpt(appHdr, messageId.value, creationDateTime.value, uetr, "pacs.009.001.08");

            if (issues.size() > 0) return #err(issues);
            #ok({
              businessApplicationHeader = header;
              messageId = messageId.value;
              creationDateTime = creationDateTime.value;
              settlementInstruction = { settlementMethod = sttlmMethod.value; clearingSystem };
              uetr;
              instructionId = instructionId.value;
              endToEndId = endToEndId.value;
              instructedAmount = amt.value;
              debtorAgent = debtorAgent.value;
              creditorAgent = creditorAgent.value;
              debtorInstitution = debtorInstitution.value;
              creditorInstitution = creditorInstitution.value;
              routing = routing.value;
              isCover;
              underlyingPacs008MessageId;
              transactionCount = txCount.value;
            });
          };
        };
      };
    };
  };

  public func decodeCoverPayment(xml : Blob) : CoverPaymentDecode {
    switch (Text.decodeUtf8(xml)) {
      case null {
        #err([ISO.publicIssue("schema", "XML-UTF8", "$xml", "XML payload must be valid UTF-8")]);
      };
      case (?text) {
        let safety = safetyIssues(text, xml.size());
        if (safety.size() > 0) return #err(safety);
        let bytes = Blob.toArray(xml);
        let direct = requireElement(bytes, "DirectPacs008", "$.CoverPaymentBundle.DirectPacs008", []);
        let cover = requireElement(bytes, "CoverPacs009", "$.CoverPaymentBundle.CoverPacs009", direct.issues);
        var issues = cover.issues;
        let method = switch (textOf(bytes, "Method")) { case (?m) m; case null "COVER" };
        switch (direct.element, cover.element) {
          case (?d, ?c) {
            switch (decodePacs008(Blob.fromArray(d.content)), decodePacs009(Blob.fromArray(c.content))) {
              case (#ok(p008), #ok(p009)) {
                if (issues.size() > 0) return #err(issues);
                #ok({ directMessage = p008; coverMessage = p009; method });
              };
              case (#err(a), #ok(_)) {
                for (i in a.vals()) issues := add(issues, i);
                #err(issues);
              };
              case (#ok(_), #err(b)) {
                for (i in b.vals()) issues := add(issues, i);
                #err(issues);
              };
              case (#err(a), #err(b)) {
                for (i in a.vals()) issues := add(issues, i);
                for (i in b.vals()) issues := add(issues, i);
                #err(issues);
              };
            };
          };
          case _ #err(issues);
        };
      };
    };
  };

  public func decodeInvestigation(xml : Blob) : InvestigationDecode {
    switch (Text.decodeUtf8(xml)) {
      case null {
        #err([ISO.publicIssue("schema", "XML-UTF8", "$xml", "XML payload must be valid UTF-8")]);
      };
      case (?text) {
        let safety = safetyIssues(text, xml.size());
        if (safety.size() > 0) return #err(safety);
        let bytes = Blob.toArray(xml);
        switch (investigationRoot(bytes)) {
          case null #err([ISO.publicIssue("schema", "XML-ROOT", "$xml", "investigation XML must contain FIToFIPmtCxlReq, RsltnOfInvstgtn, or FIToFIPmtStsReq")]);
          case (?(messageKind, version, root)) {
            let assgnmt = requireElement(root.content, "Assgnmt", "$.Document.Investigation.Assgnmt", []);
            let undrlyg = requireElement(root.content, "Undrlyg", "$.Document.Investigation.Undrlyg", assgnmt.issues);
            var issues = undrlyg.issues;
            let assignmentId = requiredTextFromOpt(assgnmt.element, "Id", "$.Assgnmt.Id", issues);
            issues := assignmentId.issues;
            let creationDateTime = requiredTextFromOpt(assgnmt.element, "CreDtTm", "$.Assgnmt.CreDtTm", issues);
            issues := creationDateTime.issues;
            let messageId = requiredTextFromOpt(undrlyg.element, "MsgId", "$.Undrlyg.MsgId", issues);
            issues := messageId.issues;
            let originalMessageId = requiredTextFromOpt(undrlyg.element, "OrgnlMsgId", "$.Undrlyg.OrgnlMsgId", issues);
            issues := originalMessageId.issues;
            let reasonCode = requiredTextFromOpt(undrlyg.element, "RsnCd", "$.Undrlyg.RsnCd", issues);
            issues := reasonCode.issues;
            if (issues.size() > 0) return #err(issues);
            #ok({
              messageKind;
              messageVersion = version;
              messageId = messageId.value;
              creationDateTime = creationDateTime.value;
              assignmentId = assignmentId.value;
              originalMessageId = originalMessageId.value;
              originalUetr = optionalTextFromOpt(undrlyg.element, "OrgnlUETR");
              reasonCode = reasonCode.value;
              requestedAction = optionalTextFromOpt(undrlyg.element, "ReqdActn");
              additionalInfo = switch (undrlyg.element) { case (?u) allTextOf(u.content, "AddtlInf"); case null [] };
            });
          };
        };
      };
    };
  };

  public func decodeRequestToPay(xml : Blob) : RequestToPayDecode {
    switch (Text.decodeUtf8(xml)) {
      case null {
        #err([ISO.publicIssue("schema", "XML-UTF8", "$xml", "XML payload must be valid UTF-8")]);
      };
      case (?text) {
        let safety = safetyIssues(text, xml.size());
        if (safety.size() > 0) return #err(safety);
        let bytes = Blob.toArray(xml);
        switch (requestToPayRoot(bytes)) {
          case null #err([ISO.publicIssue("schema", "XML-ROOT", "$xml", "request-to-pay XML must contain CdtrPmtActvtnReq, CdtrPmtActvtnReqStsRpt, or PmtCxlReq")]);
          case (?(messageKind, version, root)) {
            let grp = requireElement(root.content, "GrpHdr", "$.Document.RTP.GrpHdr", []);
            let rtp = requireElement(root.content, "RTP", "$.Document.RTP", grp.issues);
            var issues = rtp.issues;
            let messageId = requiredTextFromOpt(grp.element, "MsgId", "$.GrpHdr.MsgId", issues);
            issues := messageId.issues;
            let creationDateTime = requiredTextFromOpt(grp.element, "CreDtTm", "$.GrpHdr.CreDtTm", issues);
            issues := creationDateTime.issues;
            let requestId = requiredTextFromOpt(rtp.element, "ReqId", "$.RTP.ReqId", issues);
            issues := requestId.issues;
            let debtor = partyFromOpt(rtp.element, "Dbtr", "request-to-pay debtor", "$.RTP.Dbtr", issues);
            issues := debtor.issues;
            let debtorAccount = accountFromOpt(rtp.element, "DbtrAcct", "$.RTP.DbtrAcct", issues);
            issues := debtorAccount.issues;
            let debtorAgent = agentFromOpt(rtp.element, "DbtrAgt", "$.RTP.DbtrAgt", issues);
            issues := debtorAgent.issues;
            let creditor = partyFromOpt(rtp.element, "Cdtr", "request-to-pay creditor", "$.RTP.Cdtr", issues);
            issues := creditor.issues;
            let creditorAccount = accountFromOpt(rtp.element, "CdtrAcct", "$.RTP.CdtrAcct", issues);
            issues := creditorAccount.issues;
            let creditorAgent = agentFromOpt(rtp.element, "CdtrAgt", "$.RTP.CdtrAgt", issues);
            issues := creditorAgent.issues;
            let amount = requiredAmount(rtp.element, "$.RTP.ReqdAmt", "ReqdAmt", issues);
            issues := amount.issues;
            if (issues.size() > 0) return #err(issues);
            #ok({
              messageKind;
              messageVersion = version;
              messageId = messageId.value;
              creationDateTime = creationDateTime.value;
              requestId = requestId.value;
              originalRequestId = optionalTextFromOpt(rtp.element, "OrgnlReqId");
              debtor = debtor.value;
              debtorAccount = debtorAccount.value;
              debtorAgent = debtorAgent.value;
              creditor = creditor.value;
              creditorAccount = creditorAccount.value;
              creditorAgent = creditorAgent.value;
              requestedAmount = amount.value;
              requestedExecutionDate = optionalTextFromOpt(rtp.element, "ReqdExctnDt");
              chargeBearer = optionalTextFromOpt(rtp.element, "ChrgBr");
              status = optionalTextFromOpt(rtp.element, "ReqSts");
              reason = statusReasonFromOpt(rtp.element);
              remittanceInformation = remittanceFromOpt(rtp.element);
            });
          };
        };
      };
    };
  };

  public func decodeDirectDebit(xml : Blob) : DirectDebitDecode {
    switch (Text.decodeUtf8(xml)) {
      case null {
        #err([ISO.publicIssue("schema", "XML-UTF8", "$xml", "XML payload must be valid UTF-8")]);
      };
      case (?text) {
        let safety = safetyIssues(text, xml.size());
        if (safety.size() > 0) return #err(safety);
        let bytes = Blob.toArray(xml);
        let appHdr = element(bytes, "AppHdr");
        switch (element(bytes, "CstmrDrctDbtInitn")) {
          case (?root) decodePain008Root(root);
          case null {
            switch (element(bytes, "FIToFICstmrDrctDbt")) {
              case (?root) decodePacs003Root(root, appHdr);
              case null #err([ISO.publicIssue("schema", "XML-ROOT", "$xml", "direct-debit XML must contain CstmrDrctDbtInitn or FIToFICstmrDrctDbt")]);
            };
          };
        };
      };
    };
  };

  public func decodeAdministrative(xml : Blob) : AdministrativeDecode {
    switch (Text.decodeUtf8(xml)) {
      case null {
        #err([ISO.publicIssue("schema", "XML-UTF8", "$xml", "XML payload must be valid UTF-8")]);
      };
      case (?text) {
        let safety = safetyIssues(text, xml.size());
        if (safety.size() > 0) return #err(safety);
        let bytes = Blob.toArray(xml);
        switch (administrativeRoot(bytes)) {
          case null #err([ISO.publicIssue("schema", "XML-ROOT", "$xml", "administrative XML must contain MessageReject, SystemEventNotification, ReceiptAcknowledgement, or SystemEventAcknowledgement")]);
          case (?(messageKind, version, root)) {
            let evt = requireElement(root.content, "EvtInf", "$.Document.Administrative.EvtInf", []);
            var issues = evt.issues;
            let messageId = requiredTextFromOpt(evt.element, "MsgId", "$.EvtInf.MsgId", issues);
            issues := messageId.issues;
            let creationDateTime = requiredTextFromOpt(evt.element, "CreDtTm", "$.EvtInf.CreDtTm", issues);
            issues := creationDateTime.issues;
            let eventCode = requiredTextFromOpt(evt.element, "EvtCd", "$.EvtInf.EvtCd", issues);
            issues := eventCode.issues;
            let status = requiredTextFromOpt(evt.element, "Sts", "$.EvtInf.Sts", issues);
            issues := status.issues;
            if (issues.size() > 0) return #err(issues);
            #ok({
              messageKind;
              messageVersion = version;
              messageId = messageId.value;
              creationDateTime = creationDateTime.value;
              relatedMessageId = optionalTextFromOpt(evt.element, "RltdMsgId");
              relatedUetr = optionalTextFromOpt(evt.element, "RltdUETR");
              eventCode = eventCode.value;
              status = status.value;
              reason = optionalTextFromOpt(evt.element, "Rsn");
              additionalInfo = switch (evt.element) { case (?e) allTextOf(e.content, "AddtlInf"); case null [] };
            });
          };
        };
      };
    };
  };

  func decodePain008Root(root : Element) : DirectDebitDecode {
    let issues0 : [ISO.ValidationIssue] = [];
    let grp = requireElement(root.content, "GrpHdr", "$.Document.CstmrDrctDbtInitn.GrpHdr", issues0);
    let pmtInf = requireElement(root.content, "PmtInf", "$.Document.CstmrDrctDbtInitn.PmtInf", grp.issues);
    let tx = switch (pmtInf.element) {
      case (?p) requireElement(p.content, "DrctDbtTxInf", "$.Document.CstmrDrctDbtInitn.PmtInf.DrctDbtTxInf", pmtInf.issues);
      case null { { element = null; issues = pmtInf.issues } };
    };
    var issues = tx.issues;
    let messageId = requiredTextFromOpt(grp.element, "MsgId", "$.GrpHdr.MsgId", issues);
    issues := messageId.issues;
    let creationDateTime = requiredTextFromOpt(grp.element, "CreDtTm", "$.GrpHdr.CreDtTm", issues);
    issues := creationDateTime.issues;
    let txCount = requiredNatFromOpt(grp.element, "NbOfTxs", "$.GrpHdr.NbOfTxs", issues);
    issues := txCount.issues;
    let initiatingParty = partyFromOpt(grp.element, "InitgPty", "initiating party", "$.GrpHdr.InitgPty", issues);
    issues := initiatingParty.issues;
    let creditor = partyFromOpt(pmtInf.element, "Cdtr", "creditor", "$.PmtInf.Cdtr", issues);
    issues := creditor.issues;
    let creditorAccount = accountFromOpt(pmtInf.element, "CdtrAcct", "$.PmtInf.CdtrAcct", issues);
    issues := creditorAccount.issues;
    let creditorAgent = agentFromOpt(pmtInf.element, "CdtrAgt", "$.PmtInf.CdtrAgt", issues);
    issues := creditorAgent.issues;
    let debtor = partyFromOpt(tx.element, "Dbtr", "debtor", "$.DrctDbtTxInf.Dbtr", issues);
    issues := debtor.issues;
    let debtorAccount = accountFromOpt(tx.element, "DbtrAcct", "$.DrctDbtTxInf.DbtrAcct", issues);
    issues := debtorAccount.issues;
    let debtorAgent = agentFromOpt(tx.element, "DbtrAgt", "$.DrctDbtTxInf.DbtrAgt", issues);
    issues := debtorAgent.issues;
    let amount = requiredAmount(tx.element, "$.DrctDbtTxInf.Amt.InstdAmt", "InstdAmt", issues);
    issues := amount.issues;
    let endToEndId = requiredNestedText(tx.element, ["PmtId", "EndToEndId"], "$.DrctDbtTxInf.PmtId.EndToEndId", issues);
    issues := endToEndId.issues;
    let mandateId = requiredNestedText(tx.element, ["DrctDbtTx", "MndtRltdInf", "MndtId"], "$.DrctDbtTxInf.DrctDbtTx.MndtRltdInf.MndtId", issues);
    issues := mandateId.issues;
    let sequenceType = requiredNestedText(tx.element, ["DrctDbtTx", "SeqTp"], "$.DrctDbtTxInf.DrctDbtTx.SeqTp", issues);
    issues := sequenceType.issues;
    if (issues.size() > 0) return #err(issues);
    #ok({
      messageKind = "pain.008";
      messageVersion = "pain.008.001.08";
      businessApplicationHeader = null;
      messageId = messageId.value;
      creationDateTime = creationDateTime.value;
      settlementInstruction = null;
      requestedCollectionDate = optionalTextFromOpt(pmtInf.element, "ReqdColltnDt");
      initiatingParty = initiatingParty.value;
      creditor = creditor.value;
      creditorAccount = creditorAccount.value;
      creditorAgent = creditorAgent.value;
      debtor = debtor.value;
      debtorAccount = debtorAccount.value;
      debtorAgent = debtorAgent.value;
      paymentTypeInformation = paymentTypeFromOpt(pmtInf.element);
      instructedAmount = amount.value;
      endToEndId = endToEndId.value;
      mandateId = mandateId.value;
      mandateSignatureDate = optionalNestedText(tx.element, ["DrctDbtTx", "MndtRltdInf", "DtOfSgntr"]);
      sequenceType = sequenceType.value;
      remittanceInformation = remittanceFromOpt(tx.element);
      uetr = optionalNestedText(tx.element, ["PmtId", "UETR"]);
      transactionCount = txCount.value;
    });
  };

  func decodePacs003Root(root : Element, appHdr : ?Element) : DirectDebitDecode {
    let issues0 : [ISO.ValidationIssue] = [];
    let grp = requireElement(root.content, "GrpHdr", "$.Document.FIToFICstmrDrctDbt.GrpHdr", issues0);
    let tx = requireElement(root.content, "DrctDbtTxInf", "$.Document.FIToFICstmrDrctDbt.DrctDbtTxInf", grp.issues);
    var issues = tx.issues;
    let messageId = requiredTextFromOpt(grp.element, "MsgId", "$.GrpHdr.MsgId", issues);
    issues := messageId.issues;
    let creationDateTime = requiredTextFromOpt(grp.element, "CreDtTm", "$.GrpHdr.CreDtTm", issues);
    issues := creationDateTime.issues;
    let txCount = requiredNatFromOpt(grp.element, "NbOfTxs", "$.GrpHdr.NbOfTxs", issues);
    issues := txCount.issues;
    let sttlmMethod = requiredNestedText(grp.element, ["SttlmInf", "SttlmMtd"], "$.GrpHdr.SttlmInf.SttlmMtd", issues);
    issues := sttlmMethod.issues;
    let clearingSystem = optionalNestedText(grp.element, ["SttlmInf", "ClrSys"]);
    let creditor = partyFromOpt(tx.element, "Cdtr", "creditor", "$.DrctDbtTxInf.Cdtr", issues);
    issues := creditor.issues;
    let creditorAccount = accountFromOpt(tx.element, "CdtrAcct", "$.DrctDbtTxInf.CdtrAcct", issues);
    issues := creditorAccount.issues;
    let creditorAgent = agentFromOpt(tx.element, "CdtrAgt", "$.DrctDbtTxInf.CdtrAgt", issues);
    issues := creditorAgent.issues;
    let debtor = partyFromOpt(tx.element, "Dbtr", "debtor", "$.DrctDbtTxInf.Dbtr", issues);
    issues := debtor.issues;
    let debtorAccount = accountFromOpt(tx.element, "DbtrAcct", "$.DrctDbtTxInf.DbtrAcct", issues);
    issues := debtorAccount.issues;
    let debtorAgent = agentFromOpt(tx.element, "DbtrAgt", "$.DrctDbtTxInf.DbtrAgt", issues);
    issues := debtorAgent.issues;
    let amount = requiredAmount(tx.element, "$.DrctDbtTxInf.Amt.InstdAmt", "InstdAmt", issues);
    issues := amount.issues;
    let endToEndId = requiredNestedText(tx.element, ["PmtId", "EndToEndId"], "$.DrctDbtTxInf.PmtId.EndToEndId", issues);
    issues := endToEndId.issues;
    let mandateId = requiredNestedText(tx.element, ["DrctDbtTx", "MndtRltdInf", "MndtId"], "$.DrctDbtTxInf.DrctDbtTx.MndtRltdInf.MndtId", issues);
    issues := mandateId.issues;
    let sequenceType = requiredNestedText(tx.element, ["DrctDbtTx", "SeqTp"], "$.DrctDbtTxInf.DrctDbtTx.SeqTp", issues);
    issues := sequenceType.issues;
    let uetr = optionalNestedText(tx.element, ["PmtId", "UETR"]);
    let header = headerFromOpt(appHdr, messageId.value, creationDateTime.value, uetr, "pacs.003.001.08");
    if (issues.size() > 0) return #err(issues);
    #ok({
      messageKind = "pacs.003";
      messageVersion = "pacs.003.001.08";
      businessApplicationHeader = header;
      messageId = messageId.value;
      creationDateTime = creationDateTime.value;
      settlementInstruction = ?{ settlementMethod = sttlmMethod.value; clearingSystem };
      requestedCollectionDate = optionalTextFromOpt(tx.element, "ReqdColltnDt");
      initiatingParty = creditor.value;
      creditor = creditor.value;
      creditorAccount = creditorAccount.value;
      creditorAgent = creditorAgent.value;
      debtor = debtor.value;
      debtorAccount = debtorAccount.value;
      debtorAgent = debtorAgent.value;
      paymentTypeInformation = paymentTypeFromOpt(tx.element);
      instructedAmount = amount.value;
      endToEndId = endToEndId.value;
      mandateId = mandateId.value;
      mandateSignatureDate = optionalNestedText(tx.element, ["DrctDbtTx", "MndtRltdInf", "DtOfSgntr"]);
      sequenceType = sequenceType.value;
      remittanceInformation = remittanceFromOpt(tx.element);
      uetr;
      transactionCount = txCount.value;
    });
  };

  public func decodeCamt053(xml : Blob) : StatementDecode {
    decodeStatementEntries(xml, "BkToCstmrStmt", "camt.053");
  };

  public func decodeCamt054(xml : Blob) : StatementDecode {
    decodeStatementEntries(xml, "BkToCstmrDbtCdtNtfctn", "camt.054");
  };

  public func decodeStatusReport(xml : Blob) : StatusReportDecode {
    switch (Text.decodeUtf8(xml)) {
      case null {
        #err([ISO.publicIssue("schema", "XML-UTF8", "$xml", "XML payload must be valid UTF-8")]);
      };
      case (?text) {
        let safety = safetyIssues(text, xml.size());
        if (safety.size() > 0) return #err(safety);
        let bytes = Blob.toArray(xml);
        switch (statusRoot(bytes)) {
          case null #err([ISO.publicIssue("schema", "XML-ROOT", "$xml", "status XML must contain CstmrPmtStsRpt, FIToFIPmtStsRpt, or PmtRtr")]);
          case (?(messageKind, defaultVersion, root)) {
            let issues0 : [ISO.ValidationIssue] = [];
            let grp = requireElement(root.content, "GrpHdr", "$.Document.Status.GrpHdr", issues0);
            let original = requireElement(root.content, "OrgnlGrpInfAndSts", "$.Document.Status.OrgnlGrpInfAndSts", grp.issues);
            let tx = requireElement(root.content, "TxInfAndSts", "$.Document.Status.TxInfAndSts", original.issues);
            var issues = tx.issues;

            let messageId = requiredTextFromOpt(grp.element, "MsgId", "$.GrpHdr.MsgId", issues);
            issues := messageId.issues;
            let creationDateTime = requiredTextFromOpt(grp.element, "CreDtTm", "$.GrpHdr.CreDtTm", issues);
            issues := creationDateTime.issues;
            let originalMessageId = requiredTextFromOpt(original.element, "OrgnlMsgId", "$.OrgnlGrpInfAndSts.OrgnlMsgId", issues);
            issues := originalMessageId.issues;
            let version = switch (optionalTextFromOpt(original.element, "OrgnlMsgNmId")) {
              case (?v) v;
              case null defaultVersion;
            };
            let originalUetr = requiredTextFromOpt(tx.element, "OrgnlUETR", "$.TxInfAndSts.OrgnlUETR", issues);
            issues := originalUetr.issues;
            let transactionStatus = requiredTextFromOpt(tx.element, "TxSts", "$.TxInfAndSts.TxSts", issues);
            issues := transactionStatus.issues;

            if (issues.size() > 0) return #err(issues);
            #ok({
              messageKind;
              messageVersion = version;
              messageId = messageId.value;
              originalMessageId = originalMessageId.value;
              originalUetr = originalUetr.value;
              transactionStatus = transactionStatus.value;
              reason = statusReasonFromOpt(tx.element);
              creationDateTime = creationDateTime.value;
            });
          };
        };
      };
    };
  };

  public func escape(value : Text) : Text {
    var out = Text.replace(value, #text "&", "&amp;");
    out := Text.replace(out, #text "<", "&lt;");
    out := Text.replace(out, #text ">", "&gt;");
    out := Text.replace(out, #text "\"", "&quot;");
    Text.replace(out, #text "'", "&apos;");
  };

  public func unescape(value : Text) : Text {
    var out = Text.replace(value, #text "&lt;", "<");
    out := Text.replace(out, #text "&gt;", ">");
    out := Text.replace(out, #text "&quot;", "\"");
    out := Text.replace(out, #text "&apos;", "'");
    Text.replace(out, #text "&amp;", "&");
  };

  func partyXml(indent : Nat, tag : Text, party : ISO.PartyIdentification) : Text {
    spaces(indent) # "<" # tag # ">\n"
    # elem(indent + 2, "Nm", party.name)
    # addressXml(indent + 2, party.postalAddress)
    # optElem(indent + 2, "LEI", party.lei)
    # spaces(indent) # "</" # tag # ">\n";
  };

  func addressXml(indent : Nat, address : ?ISO.PostalAddress) : Text {
    switch (address) {
      case null "";
      case (?a) {
        var lines = "";
        for (line in a.addressLine.vals()) {
          lines #= elem(indent + 2, "AdrLine", line);
        };
        spaces(indent) # "<PstlAdr>\n"
        # elem(indent + 2, "Ctry", a.country)
        # elem(indent + 2, "TwnNm", a.townName)
        # optElem(indent + 2, "PstCd", a.postalCode)
        # lines
        # spaces(indent) # "</PstlAdr>\n";
      };
    };
  };

  func accountXml(indent : Nat, tag : Text, account : ISO.CashAccount) : Text {
    spaces(indent) # "<" # tag # ">\n"
    # "  " # spaces(indent) # "<Id>\n"
    # optElem(indent + 4, "IBAN", account.iban)
    # optElem(indent + 4, "Othr", account.otherId)
    # "  " # spaces(indent) # "</Id>\n"
    # optElem(indent + 2, "Ccy", account.currency)
    # spaces(indent) # "</" # tag # ">\n";
  };

  func agentXml(indent : Nat, tag : Text, agent : ISO.FinancialInstitutionIdentification) : Text {
    spaces(indent) # "<" # tag # "><FinInstnId>\n"
    # elem(indent + 2, "BICFI", agent.bicfi)
    # optElem(indent + 2, "Nm", agent.name)
    # spaces(indent) # "</FinInstnId></" # tag # ">\n";
  };

  func paymentTypeXml(indent : Nat, pti : ?ISO.PaymentTypeInformation) : Text {
    switch (pti) {
      case null "";
      case (?p) {
        spaces(indent) # "<PmtTpInf>\n"
        # optElem(indent + 2, "SvcLvl", p.serviceLevel)
        # optElem(indent + 2, "LclInstrm", p.localInstrument)
        # optElem(indent + 2, "CtgyPurp", p.categoryPurpose)
        # spaces(indent) # "</PmtTpInf>\n";
      };
    };
  };

  func amountXml(indent : Nat, tag : Text, amount : ISO.ActiveCurrencyAndAmount) : Text {
    spaces(indent) # "<Amt><" # tag # " Ccy=\"" # escape(amount.currency) # "\">"
    # amountToText(amount.minorUnits)
    # "</" # tag # "></Amt>\n";
  };

  func directAmountXml(indent : Nat, tag : Text, amount : ISO.ActiveCurrencyAndAmount) : Text {
    spaces(indent) # "<" # tag # " Ccy=\"" # escape(amount.currency) # "\">"
    # amountToText(amount.minorUnits)
    # "</" # tag # ">\n";
  };

  func remittanceXml(indent : Nat, rem : ISO.RemittanceInformation) : Text {
    var lines = "";
    for (line in rem.unstructured.vals()) {
      lines #= elem(indent + 2, "Ustrd", line);
    };
    let strd = switch (rem.structuredCreditorReference) {
      case null "";
      case (?ref) {
        spaces(indent + 2) # "<Strd><CdtrRefInf>" # elem(0, "Ref", ref) # "</CdtrRefInf></Strd>\n";
      };
    };
    spaces(indent) # "<RmtInf>\n" # lines # strd # spaces(indent) # "</RmtInf>\n";
  };

  func routingXml(indent : Nat, routing : ISO.CrossBorderRouting) : Text {
    var inter = "";
    var charges = "";
    var reg = "";
    for (agent in routing.intermediaryAgents.vals()) {
      inter #= agentXml(indent + 2, "IntrmyAgt", agent);
    };
    for (charge in routing.charges.vals()) {
      charges #= spaces(indent + 2) # "<ChrgsInf>\n"
        # directAmountXml(indent + 4, "Amt", charge.amount)
        # agentXml(indent + 4, "Agt", charge.agent)
        # optElem(indent + 4, "Tp", charge.typeCode)
        # spaces(indent + 2) # "</ChrgsInf>\n";
    };
    for (r in routing.regulatoryReporting.vals()) {
      reg #= spaces(indent + 2) # "<RgltryRptg>\n"
        # optElem(indent + 4, "AuthrtyCtry", r.authorityCountry)
        # optElem(indent + 4, "Cd", r.reportingCode)
        # infoLines(indent + 4, "Inf", r.details)
        # spaces(indent + 2) # "</RgltryRptg>\n";
    };
    spaces(indent) # "<CrossBorderRouting>\n"
    # elem(indent + 2, "ChrgBr", routing.chargeBearer)
    # agentXml(indent + 2, "InstgAgt", routing.instructingAgent)
    # agentXml(indent + 2, "InstdAgt", routing.instructedAgent)
    # inter
    # optElem(indent + 2, "IntrBkSttlmDt", routing.settlementDate)
    # fxXml(indent + 2, routing.fx)
    # charges
    # reg
    # spaces(indent) # "</CrossBorderRouting>\n";
  };

  func fxXml(indent : Nat, fx : ?ISO.FxDetails) : Text {
    switch (fx) {
      case null "";
      case (?f) {
        spaces(indent) # "<FX>\n"
        # elem(indent + 2, "SrcCcy", f.sourceCurrency)
        # elem(indent + 2, "TgtCcy", f.targetCurrency)
        # elem(indent + 2, "XchgRateE8s", Nat.toText(f.exchangeRateE8s))
        # optElem(indent + 2, "QuoteId", f.quoteId)
        # optElem(indent + 2, "QuoteXpry", f.quoteExpiry)
        # amountXml(indent + 2, "SttlmAmt", f.settlementAmount)
        # spaces(indent) # "</FX>\n";
      };
    };
  };

  func investigationInfoXml(indent : Nat, infos : [Text]) : Text {
    infoLines(indent, "AddtlInf", infos);
  };

  func infoLines(indent : Nat, tag : Text, infos : [Text]) : Text {
    var out = "";
    for (info in infos.vals()) {
      out #= elem(indent, tag, info);
    };
    out;
  };

  func indentBlock(value : Text, indent : Nat) : Text {
    let prefix = spaces(indent);
    var out = "";
    for (line in Text.split(value, #char '\n')) {
      if (line != "") out #= prefix # line # "\n";
    };
    out;
  };

  func statementEntryXml(indent : Nat, entry : ISO.StatementEntry) : Text {
    spaces(indent) # "<Ntry>\n"
    # elem(indent + 2, "NtryRef", entry.entryId)
    # elem(indent + 2, "CdtDbtInd", entry.creditDebit)
    # directAmountXml(indent + 2, "Amt", entry.amount)
    # "  " # spaces(indent) # "<NtryDtls><TxDtls>\n"
    # elem(indent + 6, "PaymentId", Nat.toText(entry.paymentId))
    # elem(indent + 6, "UETR", entry.uetr)
    # elem(indent + 6, "TxSts", entry.status)
    # elem(indent + 6, "BookedAt", intToText(entry.bookedAt))
    # optElem(indent + 6, "IBAN", entry.accountIban)
    # optElem(indent + 6, "Othr", entry.accountOtherId)
    # elem(indent + 6, "RltdPties", entry.counterpartyName)
    # remittanceXml(indent + 6, { unstructured = entry.remittance; structuredCreditorReference = null })
    # "  " # spaces(indent) # "</TxDtls></NtryDtls>\n"
    # spaces(indent) # "</Ntry>\n";
  };

  func directDebitTxXml(indent : Nat, doc : ISO.DirectDebitMessage, includeCreditor : Bool, includeCollectionDate : Bool) : Text {
    let creditor =
      if (includeCreditor) {
        agentXml(indent + 2, "CdtrAgt", doc.creditorAgent)
        # partyXml(indent + 2, "Cdtr", doc.creditor)
        # accountXml(indent + 2, "CdtrAcct", doc.creditorAccount)
      } else "";
    let collectionDate = if (includeCollectionDate) optElem(indent + 2, "ReqdColltnDt", doc.requestedCollectionDate) else "";
    spaces(indent) # "<DrctDbtTxInf>\n"
    # "  " # spaces(indent) # "<PmtId>\n"
    # elem(indent + 4, "EndToEndId", doc.endToEndId)
    # optElem(indent + 4, "UETR", doc.uetr)
    # "  " # spaces(indent) # "</PmtId>\n"
    # collectionDate
    # amountXml(indent + 2, "InstdAmt", doc.instructedAmount)
    # "  " # spaces(indent) # "<DrctDbtTx>\n"
    # "    " # spaces(indent) # "<MndtRltdInf>\n"
    # elem(indent + 6, "MndtId", doc.mandateId)
    # optElem(indent + 6, "DtOfSgntr", doc.mandateSignatureDate)
    # "    " # spaces(indent) # "</MndtRltdInf>\n"
    # elem(indent + 4, "SeqTp", doc.sequenceType)
    # "  " # spaces(indent) # "</DrctDbtTx>\n"
    # creditor
    # agentXml(indent + 2, "DbtrAgt", doc.debtorAgent)
    # partyXml(indent + 2, "Dbtr", doc.debtor)
    # accountXml(indent + 2, "DbtrAcct", doc.debtorAccount)
    # remittanceXml(indent + 2, doc.remittanceInformation)
    # spaces(indent) # "</DrctDbtTxInf>\n";
  };

  func elem(indent : Nat, tag : Text, value : Text) : Text {
    spaces(indent) # "<" # tag # ">" # escape(value) # "</" # tag # ">\n";
  };

  func optElem(indent : Nat, tag : Text, value : ?Text) : Text {
    switch (value) {
      case (?v) elem(indent, tag, v);
      case null "";
    };
  };

  func optInline(tag : Text, value : ?Text) : Text {
    switch (value) {
      case (?v) "<" # tag # ">" # escape(v) # "</" # tag # ">";
      case null "";
    };
  };

  func spaces(n : Nat) : Text {
    var out = "";
    var i = 0;
    while (i < n) {
      out #= " ";
      i += 1;
    };
    out;
  };

  func intToText(value : Int) : Text {
    Int.toText(value);
  };

  func amountToText(minor : Nat) : Text {
    let major = minor / 100;
    let cents = minor % 100;
    Nat.toText(major) # "." # (if (cents < 10) "0" else "") # Nat.toText(cents);
  };

  func safetyIssues(text : Text, byteSize : Nat) : [ISO.ValidationIssue] {
    var issues : [ISO.ValidationIssue] = [];
    if (byteSize > 80_000) {
      issues := add(issues, ISO.publicIssue("schema", "XML-SIZE", "$xml", "XML payload exceeds codec byte cap"));
    };
    if (Text.contains(text, #text "<!DOCTYPE") or Text.contains(text, #text "<!ENTITY") or Text.contains(text, #text " SYSTEM ") or Text.contains(text, #text " PUBLIC ")) {
      issues := add(issues, ISO.publicIssue("schema", "XML-UNSAFE-DECL", "$xml", "DTD, entity declarations, and external identifiers are not allowed"));
    };
    if (Text.contains(text, #text "<?xml-stylesheet")) {
      issues := add(issues, ISO.publicIssue("schema", "XML-PI", "$xml", "XML processing instructions other than the XML declaration are not allowed"));
    };
    issues;
  };

  type Element = {
    openStart : Nat;
    openEnd : Nat;
    openTag : [Nat8];
    content : [Nat8];
  };

  type ReqElement = {
    element : ?Element;
    issues : [ISO.ValidationIssue];
  };

  type ReqText = {
    value : Text;
    issues : [ISO.ValidationIssue];
  };

  type ReqParty = {
    value : ISO.PartyIdentification;
    issues : [ISO.ValidationIssue];
  };

  type ReqAccount = {
    value : ISO.CashAccount;
    issues : [ISO.ValidationIssue];
  };

  type ReqAgent = {
    value : ISO.FinancialInstitutionIdentification;
    issues : [ISO.ValidationIssue];
  };

  type ReqAmount = {
    value : ISO.ActiveCurrencyAndAmount;
    issues : [ISO.ValidationIssue];
  };

  type ReqNat = {
    value : Nat;
    issues : [ISO.ValidationIssue];
  };

  type ReqRouting = {
    value : ISO.CrossBorderRouting;
    issues : [ISO.ValidationIssue];
  };

  func requireElement(source : [Nat8], tag : Text, path : Text, issues0 : [ISO.ValidationIssue]) : ReqElement {
    switch (element(source, tag)) {
      case (?e) { { element = ?e; issues = issues0 } };
      case null { { element = null; issues = add(issues0, ISO.publicIssue("schema", "XML-ELEMENT-REQUIRED", path, "required XML element " # tag # " is missing")) } };
    };
  };

  func requiredTextFromOpt(parent : ?Element, tag : Text, path : Text, issues0 : [ISO.ValidationIssue]) : ReqText {
    switch (parent) {
      case null { { value = ""; issues = issues0 } };
      case (?p) {
        switch (textOf(p.content, tag)) {
          case (?value) { { value; issues = issues0 } };
          case null { { value = ""; issues = add(issues0, ISO.publicIssue("schema", "XML-TEXT-REQUIRED", path, "required XML text " # tag # " is missing")) } };
        };
      };
    };
  };

  func requiredNatFromOpt(parent : ?Element, tag : Text, path : Text, issues0 : [ISO.ValidationIssue]) : ReqNat {
    let text = requiredTextFromOpt(parent, tag, path, issues0);
    switch (parseNat(text.value)) {
      case (?n) { { value = n; issues = text.issues } };
      case null { { value = 0; issues = add(text.issues, ISO.publicIssue("schema", "XML-NAT-FORMAT", path, "required XML text must be an unsigned integer")) } };
    };
  };

  func optionalTextFromOpt(parent : ?Element, tag : Text) : ?Text {
    switch (parent) {
      case (?p) textOf(p.content, tag);
      case null null;
    };
  };

  func requiredNestedText(parent : ?Element, tags : [Text], path : Text, issues0 : [ISO.ValidationIssue]) : ReqText {
    switch (nestedElement(parent, tags)) {
      case (?e) {
        switch (decodeText(e.content)) {
          case (?value) { { value = unescape(trim(value)); issues = issues0 } };
          case null { { value = ""; issues = add(issues0, ISO.publicIssue("schema", "XML-UTF8", path, "XML text is not valid UTF-8")) } };
        };
      };
      case null { { value = ""; issues = add(issues0, ISO.publicIssue("schema", "XML-TEXT-REQUIRED", path, "required nested XML text is missing")) } };
    };
  };

  func optionalNestedText(parent : ?Element, tags : [Text]) : ?Text {
    switch (nestedElement(parent, tags)) {
      case (?e) {
        switch (decodeText(e.content)) {
          case (?value) ?unescape(trim(value));
          case null null;
        };
      };
      case null null;
    };
  };

  func nestedElement(parent : ?Element, tags : [Text]) : ?Element {
    switch (parent) {
      case null null;
      case (?p) {
        var current : ?Element = ?p;
        var i = 0;
        while (i < tags.size()) {
          current := switch (current) {
            case (?c) element(c.content, tags[i]);
            case null null;
          };
          i += 1;
        };
        current;
      };
    };
  };

  func partyFromOpt(parent : ?Element, tag : Text, fallbackName : Text, path : Text, issues0 : [ISO.ValidationIssue]) : ReqParty {
    let req = switch (parent) {
      case (?p) requireElement(p.content, tag, path, issues0);
      case null { { element = null; issues = issues0 } };
    };
    var issues = req.issues;
    let name = requiredTextFromOpt(req.element, "Nm", path # ".Nm", issues);
    issues := name.issues;
    let address = switch (req.element) {
      case (?e) addressFrom(element(e.content, "PstlAdr"));
      case null null;
    };
    let lei = optionalTextFromOpt(req.element, "LEI");
    { value = { name = if (name.value == "") fallbackName else name.value; postalAddress = address; lei }; issues };
  };

  func addressFrom(address : ?Element) : ?ISO.PostalAddress {
    switch (address) {
      case null null;
      case (?a) ?{
        country = switch (textOf(a.content, "Ctry")) { case (?v) v; case null "" };
        townName = switch (textOf(a.content, "TwnNm")) { case (?v) v; case null "" };
        addressLine = allTextOf(a.content, "AdrLine");
        postalCode = textOf(a.content, "PstCd");
      };
    };
  };

  func accountFromOpt(parent : ?Element, tag : Text, path : Text, issues0 : [ISO.ValidationIssue]) : ReqAccount {
    let req = switch (parent) {
      case (?p) requireElement(p.content, tag, path, issues0);
      case null { { element = null; issues = issues0 } };
    };
    let iban = optionalNestedText(req.element, ["Id", "IBAN"]);
    let otherId = optionalNestedText(req.element, ["Id", "Othr"]);
    let currency = optionalTextFromOpt(req.element, "Ccy");
    { value = { iban; otherId; currency }; issues = req.issues };
  };

  func agentFromOpt(parent : ?Element, tag : Text, path : Text, issues0 : [ISO.ValidationIssue]) : ReqAgent {
    let req = switch (parent) {
      case (?p) requireElement(p.content, tag, path, issues0);
      case null { { element = null; issues = issues0 } };
    };
    agentFromElement(req.element, path, req.issues);
  };

  func agentFromElement(agent : ?Element, path : Text, issues0 : [ISO.ValidationIssue]) : ReqAgent {
    let bic = requiredNestedText(agent, ["FinInstnId", "BICFI"], path # ".FinInstnId.BICFI", issues0);
    let name = optionalNestedText(agent, ["FinInstnId", "Nm"]);
    { value = { bicfi = bic.value; name }; issues = bic.issues };
  };

  func paymentTypeFromOpt(parent : ?Element) : ?ISO.PaymentTypeInformation {
    switch (nestedElement(parent, ["PmtTpInf"])) {
      case null null;
      case (?p) ?{
        serviceLevel = textOf(p.content, "SvcLvl");
        localInstrument = textOf(p.content, "LclInstrm");
        categoryPurpose = textOf(p.content, "CtgyPurp");
      };
    };
  };

  func remittanceFromOpt(parent : ?Element) : ISO.RemittanceInformation {
    switch (nestedElement(parent, ["RmtInf"])) {
      case null { { unstructured = []; structuredCreditorReference = null } };
      case (?r) {
        {
          unstructured = allTextOf(r.content, "Ustrd");
          structuredCreditorReference = optionalNestedText(?r, ["Strd", "CdtrRefInf", "Ref"]);
        };
      };
    };
  };

  func routingFromOpt(parent : ?Element, issues0 : [ISO.ValidationIssue]) : ReqRouting {
    let req = switch (parent) {
      case (?p) requireElement(p.content, "CrossBorderRouting", "$.CdtTrfTxInf.CrossBorderRouting", issues0);
      case null { { element = null; issues = issues0 } };
    };
    var issues = req.issues;
    let chargeBearer = requiredTextFromOpt(req.element, "ChrgBr", "$.CrossBorderRouting.ChrgBr", issues);
    issues := chargeBearer.issues;
    let instructingAgent = agentFromOpt(req.element, "InstgAgt", "$.CrossBorderRouting.InstgAgt", issues);
    issues := instructingAgent.issues;
    let instructedAgent = agentFromOpt(req.element, "InstdAgt", "$.CrossBorderRouting.InstdAgt", issues);
    issues := instructedAgent.issues;
    var intermediaryAgents : [ISO.FinancialInstitutionIdentification] = [];
    var charges : [ISO.Charge] = [];
    var regulatoryReporting : [ISO.RegulatoryReporting] = [];
    switch (req.element) {
      case (?r) {
        for (agentElement in allElements(r.content, "IntrmyAgt").vals()) {
          let parsed = agentFromElement(?agentElement, "$.CrossBorderRouting.IntrmyAgt", issues);
          issues := parsed.issues;
          intermediaryAgents := Array.concat<ISO.FinancialInstitutionIdentification>(intermediaryAgents, [parsed.value]);
        };
        for (chargeElement in allElements(r.content, "ChrgsInf").vals()) {
          let amt = requiredDirectAmount(?chargeElement, "$.CrossBorderRouting.ChrgsInf.Amt", "Amt", issues);
          issues := amt.issues;
          let agent = agentFromOpt(?chargeElement, "Agt", "$.CrossBorderRouting.ChrgsInf.Agt", issues);
          issues := agent.issues;
          charges := Array.concat<ISO.Charge>(charges, [{
            amount = amt.value;
            agent = agent.value;
            typeCode = optionalTextFromOpt(?chargeElement, "Tp");
          }]);
        };
        for (regElement in allElements(r.content, "RgltryRptg").vals()) {
          regulatoryReporting := Array.concat<ISO.RegulatoryReporting>(regulatoryReporting, [{
            authorityCountry = optionalTextFromOpt(?regElement, "AuthrtyCtry");
            reportingCode = optionalTextFromOpt(?regElement, "Cd");
            details = allTextOf(regElement.content, "Inf");
          }]);
        };
      };
      case null {};
    };
    let fx = switch (nestedElement(req.element, ["FX"])) {
      case null null;
      case (?f) {
        let rate = requiredNatFromOpt(?f, "XchgRateE8s", "$.CrossBorderRouting.FX.XchgRateE8s", issues);
        issues := rate.issues;
        let settlementAmount = requiredAmount(?f, "$.CrossBorderRouting.FX.SttlmAmt", "SttlmAmt", issues);
        issues := settlementAmount.issues;
        ?{
          sourceCurrency = switch (optionalTextFromOpt(?f, "SrcCcy")) { case (?v) v; case null "" };
          targetCurrency = switch (optionalTextFromOpt(?f, "TgtCcy")) { case (?v) v; case null "" };
          exchangeRateE8s = rate.value;
          quoteId = optionalTextFromOpt(?f, "QuoteId");
          quoteExpiry = optionalTextFromOpt(?f, "QuoteXpry");
          settlementAmount = settlementAmount.value;
        };
      };
    };
    {
      value = {
        chargeBearer = chargeBearer.value;
        charges;
        instructingAgent = instructingAgent.value;
        instructedAgent = instructedAgent.value;
        intermediaryAgents;
        settlementDate = optionalTextFromOpt(req.element, "IntrBkSttlmDt");
        fx;
        regulatoryReporting;
      };
      issues;
    };
  };

  func statusRoot(bytes : [Nat8]) : ?(Text, Text, Element) {
    switch (element(bytes, "CstmrPmtStsRpt")) {
      case (?root) return ?("pain.002", "pain.002.001.10", root);
      case null {};
    };
    switch (element(bytes, "FIToFIPmtStsRpt")) {
      case (?root) return ?("pacs.002", "pacs.002.001.10", root);
      case null {};
    };
    switch (element(bytes, "PmtRtr")) {
      case (?root) return ?("pacs.004", "pacs.004.001.09", root);
      case null {};
    };
    null;
  };

  func investigationRoot(bytes : [Nat8]) : ?(Text, Text, Element) {
    switch (element(bytes, "FIToFIPmtCxlReq")) {
      case (?root) return ?("camt.056", "camt.056.001.08", root);
      case null {};
    };
    switch (element(bytes, "RsltnOfInvstgtn")) {
      case (?root) return ?("camt.029", "camt.029.001.09", root);
      case null {};
    };
    switch (element(bytes, "FIToFIPmtStsReq")) {
      case (?root) return ?("pacs.028", "pacs.028.001.03", root);
      case null {};
    };
    switch (element(bytes, "InvstgtnReq")) {
      case (?root) return ?("camt.110", "camt.110.001.01", root);
      case null {};
    };
    switch (element(bytes, "InvstgtnRspn")) {
      case (?root) return ?("camt.111", "camt.111.001.01", root);
      case null {};
    };
    null;
  };

  func requestToPayRoot(bytes : [Nat8]) : ?(Text, Text, Element) {
    switch (element(bytes, "CdtrPmtActvtnReq")) {
      case (?root) return ?("pain.013", "pain.013.001.10", root);
      case null {};
    };
    switch (element(bytes, "CdtrPmtActvtnReqStsRpt")) {
      case (?root) return ?("pain.014", "pain.014.001.10", root);
      case null {};
    };
    switch (element(bytes, "PmtCxlReq")) {
      case (?root) return ?("camt.055", "camt.055.001.09", root);
      case null {};
    };
    null;
  };

  func administrativeRoot(bytes : [Nat8]) : ?(Text, Text, Element) {
    switch (element(bytes, "MessageReject")) {
      case (?root) return ?("admi.002", "admi.002.001.01", root);
      case null {};
    };
    switch (element(bytes, "SystemEventNotification")) {
      case (?root) return ?("admi.004", "admi.004.001.01", root);
      case null {};
    };
    switch (element(bytes, "ReceiptAcknowledgement")) {
      case (?root) return ?("admi.007", "admi.007.001.01", root);
      case null {};
    };
    switch (element(bytes, "SystemEventAcknowledgement")) {
      case (?root) return ?("admi.011", "admi.011.001.01", root);
      case null {};
    };
    null;
  };

  func decodeStatementEntries(xml : Blob, rootTag : Text, kind : Text) : StatementDecode {
    switch (Text.decodeUtf8(xml)) {
      case null {
        #err([ISO.publicIssue("schema", "XML-UTF8", "$xml", "XML payload must be valid UTF-8")]);
      };
      case (?text) {
        let safety = safetyIssues(text, xml.size());
        if (safety.size() > 0) return #err(safety);
        let bytes = Blob.toArray(xml);
        switch (element(bytes, rootTag)) {
          case null #err([ISO.publicIssue("schema", "XML-ROOT", "$xml", kind # " XML must contain " # rootTag)]);
          case (?root) {
            var issues : [ISO.ValidationIssue] = [];
            var entries : [ISO.StatementEntry] = [];
            for (entryElement in allElements(root.content, "Ntry").vals()) {
              let parsed = statementEntryFrom(entryElement, issues);
              issues := parsed.issues;
              entries := Array.concat<ISO.StatementEntry>(entries, [parsed.value]);
            };
            if (entries.size() == 0) {
              issues := add(issues, ISO.publicIssue("schema", "XML-CAMT-NTRY", "$.Ntry", "statement XML must contain at least one Ntry"));
            };
            if (issues.size() > 0) #err(issues) else #ok(entries);
          };
        };
      };
    };
  };

  type ReqStatementEntry = {
    value : ISO.StatementEntry;
    issues : [ISO.ValidationIssue];
  };

  func statementEntryFrom(entry : Element, issues0 : [ISO.ValidationIssue]) : ReqStatementEntry {
    var issues = issues0;
    let entryId = requiredTextFromOpt(?entry, "NtryRef", "$.Ntry.NtryRef", issues);
    issues := entryId.issues;
    let creditDebit = requiredTextFromOpt(?entry, "CdtDbtInd", "$.Ntry.CdtDbtInd", issues);
    issues := creditDebit.issues;
    let amount = requiredDirectAmount(?entry, "$.Ntry.Amt", "Amt", issues);
    issues := amount.issues;
    let tx = nestedElement(?entry, ["NtryDtls", "TxDtls"]);
    let uetr = requiredTextFromOpt(tx, "UETR", "$.Ntry.TxDtls.UETR", issues);
    issues := uetr.issues;
    let status = requiredTextFromOpt(tx, "TxSts", "$.Ntry.TxDtls.TxSts", issues);
    issues := status.issues;
    let paymentId = switch (optionalTextFromOpt(tx, "PaymentId")) {
      case (?raw) {
        switch (parseNat(raw)) {
          case (?n) n;
          case null {
            issues := add(issues, ISO.publicIssue("schema", "XML-PAYMENTID-FORMAT", "$.Ntry.TxDtls.PaymentId", "PaymentId must be an unsigned integer"));
            statementPaymentId(entryId.value);
          };
        };
      };
      case null statementPaymentId(entryId.value);
    };
    let bookedAt = switch (optionalTextFromOpt(tx, "BookedAt")) {
      case (?raw) {
        switch (parseInt(raw)) {
          case (?n) n;
          case null {
            issues := add(issues, ISO.publicIssue("schema", "XML-BOOKEDAT-FORMAT", "$.Ntry.TxDtls.BookedAt", "BookedAt must be a signed integer timestamp"));
            0;
          };
        };
      };
      case null 0;
    };
    {
      value = {
        entryId = entryId.value;
        paymentId;
        uetr = uetr.value;
        accountIban = optionalTextFromOpt(tx, "IBAN");
        accountOtherId = optionalTextFromOpt(tx, "Othr");
        amount = amount.value;
        creditDebit = creditDebit.value;
        status = status.value;
        bookedAt;
        counterpartyName = switch (optionalTextFromOpt(tx, "RltdPties")) { case (?v) v; case null "" };
        remittance = switch (tx) { case (?t) allTextOf(t.content, "Ustrd"); case null [] };
      };
      issues;
    };
  };

  func statementPaymentId(entryId : Text) : Nat {
    let prefix = "CAMT-";
    if (Text.startsWith(entryId, #text prefix)) {
      switch (parseNat(Text.trimStart(entryId, #text prefix))) {
        case (?n) return n;
        case null {};
      };
    };
    0;
  };

  func statusReasonFromOpt(parent : ?Element) : ?Text {
    switch (optionalTextFromOpt(parent, "Rsn")) {
      case (?r) ?r;
      case null {
        switch (optionalNestedText(parent, ["StsRsnInf", "Rsn", "Cd"])) {
          case (?code) ?code;
          case null optionalNestedText(parent, ["StsRsnInf", "AddtlInf"]);
        };
      };
    };
  };

  func headerFromOpt(appHdr : ?Element, fallbackMessageId : Text, fallbackCreationDateTime : Text, fallbackUetr : ?Text, fallbackMessageDefinitionId : Text) : ?ISO.BusinessApplicationHeader {
    switch (appHdr) {
      case null null;
      case (?h) {
        let fromBic = switch (optionalNestedText(?h, ["Fr", "FIId", "FinInstnId", "BICFI"])) { case (?v) v; case null "" };
        let toBic = switch (optionalNestedText(?h, ["To", "FIId", "FinInstnId", "BICFI"])) { case (?v) v; case null "" };
        let businessMessageId = switch (textOf(h.content, "BizMsgIdr")) { case (?v) v; case null fallbackMessageId };
        let messageDefinitionId = switch (textOf(h.content, "MsgDefIdr")) { case (?v) v; case null fallbackMessageDefinitionId };
        let creationDateTime = switch (textOf(h.content, "CreDt")) { case (?v) v; case null fallbackCreationDateTime };
        ?{
          fromBic;
          toBic;
          businessMessageId;
          messageDefinitionId;
          businessService = textOf(h.content, "BizSvc");
          creationDateTime;
          uetr = switch (textOf(h.content, "UETR")) { case (?v) ?v; case null fallbackUetr };
        };
      };
    };
  };

  func requiredAmount(parent : ?Element, path : Text, amountTag : Text, issues0 : [ISO.ValidationIssue]) : ReqAmount {
    switch (nestedElement(parent, ["Amt", amountTag])) {
      case null {
        { value = { currency = ""; minorUnits = 0 }; issues = add(issues0, ISO.publicIssue("schema", "XML-AMT-REQUIRED", path, "amount element is required")) };
      };
      case (?amt) {
        amountFromElement(amt, path, issues0);
      };
    };
  };

  func requiredDirectAmount(parent : ?Element, path : Text, amountTag : Text, issues0 : [ISO.ValidationIssue]) : ReqAmount {
    switch (nestedElement(parent, [amountTag])) {
      case null {
        { value = { currency = ""; minorUnits = 0 }; issues = add(issues0, ISO.publicIssue("schema", "XML-AMT-REQUIRED", path, "amount element is required")) };
      };
      case (?amt) amountFromElement(amt, path, issues0);
    };
  };

  func amountFromElement(amt : Element, path : Text, issues0 : [ISO.ValidationIssue]) : ReqAmount {
    var issues = issues0;
    let currency = switch (attr(amt, "Ccy")) {
      case (?c) c;
      case null {
        issues := add(issues, ISO.publicIssue("schema", "XML-AMT-CCY", path # ".@Ccy", "amount currency attribute is required"));
        "";
      };
    };
    let text = switch (decodeText(amt.content)) {
      case (?v) trim(v);
      case null {
        issues := add(issues, ISO.publicIssue("schema", "XML-UTF8", path, "amount text is not valid UTF-8"));
        "";
      };
    };
    switch (parseMinorUnits(text)) {
      case (?minor) { { value = { currency; minorUnits = minor }; issues } };
      case null {
        { value = { currency; minorUnits = 0 }; issues = add(issues, ISO.publicIssue("schema", "XML-AMT-FORMAT", path, "amount must use decimal format with up to two fraction digits")) };
      };
    };
  };

  func add(xs : [ISO.ValidationIssue], x : ISO.ValidationIssue) : [ISO.ValidationIssue] {
    Array.concat<ISO.ValidationIssue>(xs, [x]);
  };

  func element(source : [Nat8], tag : Text) : ?Element {
    let tagBytes = Blob.toArray(Text.encodeUtf8(tag));
    var i = 0;
    while (i < source.size()) {
      if (source[i] == 60 and i + 1 < source.size() and source[i + 1] != 47 and source[i + 1] != 33 and source[i + 1] != 63) {
        let nameStart = i + 1;
        let nameEnd = scanNameEnd(source, nameStart);
        if (localNameEq(source, nameStart, nameEnd, tagBytes)) {
          switch (scanGt(source, nameEnd)) {
            case null return null;
            case (?openEnd) {
              if (openEnd > 0 and source[openEnd - 1] == 47) {
                return ?{ openStart = i; openEnd; openTag = slice(source, i, openEnd + 1); content = [] };
              };
              switch (findClose(source, openEnd + 1, tagBytes)) {
                case null return null;
                case (?closeStart) {
                  return ?{
                    openStart = i;
                    openEnd;
                    openTag = slice(source, i, openEnd + 1);
                    content = slice(source, openEnd + 1, closeStart);
                  };
                };
              };
            };
          };
        };
      };
      i += 1;
    };
    null;
  };

  func allElements(source : [Nat8], tag : Text) : [Element] {
    let tagBytes = Blob.toArray(Text.encodeUtf8(tag));
    var out : [Element] = [];
    var i = 0;
    while (i < source.size()) {
      if (source[i] == 60 and i + 1 < source.size() and source[i + 1] != 47 and source[i + 1] != 33 and source[i + 1] != 63) {
        let nameStart = i + 1;
        let nameEnd = scanNameEnd(source, nameStart);
        if (localNameEq(source, nameStart, nameEnd, tagBytes)) {
          switch (scanGt(source, nameEnd)) {
            case null { i := source.size() };
            case (?openEnd) {
              if (openEnd > 0 and source[openEnd - 1] == 47) {
                out := Array.concat<Element>(out, [{ openStart = i; openEnd; openTag = slice(source, i, openEnd + 1); content = [] }]);
                i := openEnd + 1;
              } else {
                switch (findClose(source, openEnd + 1, tagBytes)) {
                  case null { i := openEnd + 1 };
                  case (?closeStart) {
                    out := Array.concat<Element>(out, [{
                      openStart = i;
                      openEnd;
                      openTag = slice(source, i, openEnd + 1);
                      content = slice(source, openEnd + 1, closeStart);
                    }]);
                    i := closeStart + 1;
                  };
                };
              };
            };
          };
        } else {
          i += 1;
        };
      } else {
        i += 1;
      };
    };
    out;
  };

  func allTextOf(source : [Nat8], tag : Text) : [Text] {
    let tagBytes = Blob.toArray(Text.encodeUtf8(tag));
    var cursor = 0;
    var out : [Text] = [];
    while (cursor < source.size()) {
      switch (elementFrom(source, tagBytes, cursor)) {
        case null { return out };
        case (?found) {
          switch (decodeText(found.content)) {
            case (?value) { out := Array.concat<Text>(out, [unescape(trim(value))]) };
            case null {};
          };
          cursor := found.openEnd + found.content.size() + 1;
        };
      };
    };
    out;
  };

  func elementFrom(source : [Nat8], tagBytes : [Nat8], start : Nat) : ?Element {
    var i = start;
    while (i < source.size()) {
      if (source[i] == 60 and i + 1 < source.size() and source[i + 1] != 47 and source[i + 1] != 33 and source[i + 1] != 63) {
        let nameStart = i + 1;
        let nameEnd = scanNameEnd(source, nameStart);
        if (localNameEq(source, nameStart, nameEnd, tagBytes)) {
          switch (scanGt(source, nameEnd)) {
            case null return null;
            case (?openEnd) {
              switch (findClose(source, openEnd + 1, tagBytes)) {
                case null return null;
                case (?closeStart) return ?{ openStart = i; openEnd; openTag = slice(source, i, openEnd + 1); content = slice(source, openEnd + 1, closeStart) };
              };
            };
          };
        };
      };
      i += 1;
    };
    null;
  };

  func textOf(source : [Nat8], tag : Text) : ?Text {
    switch (element(source, tag)) {
      case null null;
      case (?e) {
        switch (decodeText(e.content)) {
          case (?value) ?unescape(trim(value));
          case null null;
        };
      };
    };
  };

  func attr(e : Element, name : Text) : ?Text {
    let nameBytes = Blob.toArray(Text.encodeUtf8(name));
    let source = e.openTag;
    var i = 0;
    while (i + nameBytes.size() + 2 < source.size()) {
      if (matchesAt(source, i, nameBytes)) {
        var j = i + nameBytes.size();
        while (j < source.size() and isSpace(source[j])) j += 1;
        if (j < source.size() and source[j] == 61) {
          j += 1;
          while (j < source.size() and isSpace(source[j])) j += 1;
          if (j < source.size() and (source[j] == 34 or source[j] == 39)) {
            let quote = source[j];
            let start = j + 1;
            j := start;
            while (j < source.size() and source[j] != quote) j += 1;
            if (j < source.size()) {
              return decodeText(slice(source, start, j));
            };
          };
        };
      };
      i += 1;
    };
    null;
  };

  func scanNameEnd(source : [Nat8], start : Nat) : Nat {
    var i = start;
    while (i < source.size() and source[i] != 62 and source[i] != 47 and not isSpace(source[i])) {
      i += 1;
    };
    i;
  };

  func scanGt(source : [Nat8], start : Nat) : ?Nat {
    var i = start;
    while (i < source.size()) {
      if (source[i] == 62) return ?i;
      i += 1;
    };
    null;
  };

  func findClose(source : [Nat8], start : Nat, tagBytes : [Nat8]) : ?Nat {
    var i = start;
    while (i + 2 < source.size()) {
      if (source[i] == 60 and source[i + 1] == 47) {
        let nameStart = i + 2;
        let nameEnd = scanNameEnd(source, nameStart);
        if (localNameEq(source, nameStart, nameEnd, tagBytes)) return ?i;
      };
      i += 1;
    };
    null;
  };

  func localNameEq(source : [Nat8], start : Nat, end : Nat, tagBytes : [Nat8]) : Bool {
    var localStart = start;
    var i = start;
    while (i < end) {
      if (source[i] == 58) localStart := i + 1;
      i += 1;
    };
    if (localStart > end) return false;
    var len = 0;
    i := localStart;
    while (i < end) {
      len += 1;
      i += 1;
    };
    if (len != tagBytes.size()) return false;
    i := 0;
    while (i < len) {
      if (source[localStart + i] != tagBytes[i]) return false;
      i += 1;
    };
    true;
  };

  func matchesAt(source : [Nat8], start : Nat, needle : [Nat8]) : Bool {
    if (start + needle.size() > source.size()) return false;
    var i = 0;
    while (i < needle.size()) {
      if (source[start + i] != needle[i]) return false;
      i += 1;
    };
    true;
  };

  func slice(source : [Nat8], start : Nat, end : Nat) : [Nat8] {
    if (end <= start) return [];
    Array.tabulate<Nat8>(end - start, func(i) { source[start + i] });
  };

  func decodeText(bytes : [Nat8]) : ?Text {
    Text.decodeUtf8(Blob.fromArray(bytes));
  };

  func isSpace(b : Nat8) : Bool {
    b == 32 or b == 10 or b == 13 or b == 9;
  };

  func trim(value : Text) : Text {
    Text.trim(value, #predicate(func(c) { c == ' ' or c == '\n' or c == '\r' or c == '\t' }));
  };

  func parseMinorUnits(value : Text) : ?Nat {
    let bs = Blob.toArray(Text.encodeUtf8(value));
    if (bs.size() == 0) return null;
    var whole : Nat = 0;
    var frac : Nat = 0;
    var fracDigits : Nat = 0;
    var seenDot = false;
    var i = 0;
    while (i < bs.size()) {
      let b = bs[i];
      if (b == 46 and not seenDot) {
        seenDot := true;
      } else if (b >= 48 and b <= 57) {
        let d =
          if (b == 48) 0
          else if (b == 49) 1
          else if (b == 50) 2
          else if (b == 51) 3
          else if (b == 52) 4
          else if (b == 53) 5
          else if (b == 54) 6
          else if (b == 55) 7
          else if (b == 56) 8
          else 9;
        if (seenDot) {
          if (fracDigits >= 2) return null;
          frac := (frac * 10) + d;
          fracDigits += 1;
        } else {
          whole := (whole * 10) + d;
        };
      } else {
        return null;
      };
      i += 1;
    };
    if (fracDigits == 1) frac *= 10;
    ?((whole * 100) + frac);
  };

  func parseNat(value : Text) : ?Nat {
    let bs = Blob.toArray(Text.encodeUtf8(value));
    if (bs.size() == 0) return null;
    var out : Nat = 0;
    var i = 0;
    while (i < bs.size()) {
      let b = bs[i];
      if (b < 48 or b > 57) return null;
      out := (out * 10) + digitValue(b);
      i += 1;
    };
    ?out;
  };

  func parseInt(value : Text) : ?Int {
    let bs = Blob.toArray(Text.encodeUtf8(value));
    if (bs.size() == 0) return null;
    var negative = false;
    var start = 0;
    if (bs[0] == 45) {
      negative := true;
      start := 1;
      if (bs.size() == 1) return null;
    };
    var out : Nat = 0;
    var i = start;
    while (i < bs.size()) {
      let b = bs[i];
      if (b < 48 or b > 57) return null;
      out := (out * 10) + digitValue(b);
      i += 1;
    };
    if (negative) ?(-out) else ?out;
  };

  func digitValue(b : Nat8) : Nat {
    if (b == 48) 0
    else if (b == 49) 1
    else if (b == 50) 2
    else if (b == 51) 3
    else if (b == 52) 4
    else if (b == 53) 5
    else if (b == 54) 6
    else if (b == 55) 7
    else if (b == 56) 8
    else 9;
  };
};
