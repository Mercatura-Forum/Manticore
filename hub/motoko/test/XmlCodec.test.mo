import ISO "../ISO20022";
import Xml "../ISO20022Xml";
import Blob "mo:core/Blob";
import Text "mo:core/Text";

let g = ISO.defaultGuideline();
let crossBorder = ISO.crossBorderEducationGuideline();
let pain = ISO.demoPain001();

let xml = Xml.pain001ToXml(pain);
assert (Text.contains(xml, #text "<CstmrCdtTrfInitn>"));
assert (Text.contains(xml, #text "<InstdAmt Ccy=\"EGP\">12500.00</InstdAmt>"));

switch (Xml.decodePain001(Text.encodeUtf8(xml))) {
  case (#ok(decoded)) {
    assert (decoded.messageId == pain.messageId);
    assert (decoded.creationDateTime == pain.creationDateTime);
    assert (decoded.instructedAmount.currency == pain.instructedAmount.currency);
    assert (decoded.instructedAmount.minorUnits == pain.instructedAmount.minorUnits);
    assert (decoded.debtorAgent.bicfi == pain.debtorAgent.bicfi);
    assert (decoded.creditorAgent.bicfi == pain.creditorAgent.bicfi);
    assert (ISO.validatePain001(g, decoded, ?Text.encodeUtf8(xml)).ok);
  };
  case (#err(_)) { assert false };
};

let unsafe = Text.encodeUtf8("<!DOCTYPE foo [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]><Document/>");
switch (Xml.decodePain001(unsafe)) {
  case (#ok(_)) { assert false };
  case (#err(issues)) {
    assert (issues.size() > 0);
    assert (issues[0].ruleId == "XML-UNSAFE-DECL");
  };
};

let escapedPain = {
  pain with
  initiatingParty = { pain.initiatingParty with name = "A&B <Treasury>" };
};
let escapedXml = Xml.pain001ToXml(escapedPain);
assert (Text.contains(escapedXml, #text "A&amp;B &lt;Treasury&gt;"));
switch (Xml.decodePain001(Text.encodeUtf8(escapedXml))) {
  case (#ok(decoded)) { assert (decoded.initiatingParty.name == "A&B <Treasury>") };
  case (#err(_)) { assert false };
};

let pacsXml = Xml.pacs008ToXml(ISO.demoPacs008());
assert (Text.contains(pacsXml, #text "<FIToFICstmrCdtTrf>"));
assert (Text.contains(pacsXml, #text "<UETR>8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011</UETR>"));
switch (Xml.decodePacs008(Text.encodeUtf8(pacsXml))) {
  case (#ok(decoded)) {
    assert (decoded.messageId == ISO.demoPacs008().messageId);
    assert (decoded.transactionCount == 1);
    assert (decoded.instructedAmount.currency == "EGP");
    assert (decoded.instructedAmount.minorUnits == 1_250_000);
    assert (decoded.debtorAgent.bicfi == "EGBKEGCX");
    assert (decoded.creditorAgent.bicfi == "EXBKEGCX");
    assert (ISO.validatePacs008(g, decoded, ?Text.encodeUtf8(pacsXml)).ok);
  };
  case (#err(_)) { assert false };
};

let status = ISO.pain002FromValidation(g, "PAIN002-TEST", pain.messageId, "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011", pain.creationDateTime, ISO.validatePain001(g, pain, null));
let statusXml = Xml.statusReportToXml(status);
assert (Text.contains(statusXml, #text "<CstmrPmtStsRpt>"));
switch (Xml.decodeStatusReport(Text.encodeUtf8(statusXml))) {
  case (#ok(decoded)) {
    assert (decoded.messageKind == "pain.002");
    assert (decoded.messageId == status.messageId);
    assert (decoded.originalMessageId == status.originalMessageId);
    assert (decoded.transactionStatus == status.transactionStatus);
    assert (ISO.validateStatusReport(g, decoded, "pain.002").ok);
  };
  case (#err(_)) { assert false };
};

let pacs002Xml = Xml.statusReportToXml(ISO.pacs002(g, "PACS002-TEST", pain.messageId, "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011", "ACSC", null, pain.creationDateTime));
switch (Xml.decodeStatusReport(Text.encodeUtf8(pacs002Xml))) {
  case (#ok(decoded)) {
    assert (decoded.messageKind == "pacs.002");
    assert (decoded.transactionStatus == "ACSC");
    assert (ISO.validateStatusReport(g, decoded, "pacs.002").ok);
  };
  case (#err(_)) { assert false };
};

let pacs004Xml = Xml.statusReportToXml(ISO.pacs004(g, "PACS004-TEST", pain.messageId, "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011", "returned by fixture", pain.creationDateTime));
switch (Xml.decodeStatusReport(Text.encodeUtf8(pacs004Xml))) {
  case (#ok(decoded)) {
    assert (decoded.messageKind == "pacs.004");
    assert (decoded.reason == ?"returned by fixture");
    assert (ISO.validateStatusReport(g, decoded, "pacs.004").ok);
  };
  case (#err(_)) { assert false };
};

let pacs009 = ISO.demoPacs009Core();
let pacs009Xml = Xml.pacs009ToXml(pacs009);
switch (Xml.decodePacs009(Text.encodeUtf8(pacs009Xml))) {
  case (#ok(decoded)) {
    assert (decoded.messageId == pacs009.messageId);
    assert (decoded.routing.chargeBearer == "SHAR");
    assert (decoded.routing.intermediaryAgents.size() == 1);
    assert (decoded.routing.charges.size() == 1);
    assert (decoded.routing.regulatoryReporting.size() == 1);
    assert (ISO.validatePacs009(crossBorder, decoded, ?Text.encodeUtf8(pacs009Xml)).ok);
  };
  case (#err(_)) { assert false };
};

let cover = ISO.demoCoverPayment();
let coverXml = Xml.coverPaymentToXml(cover);
switch (Xml.decodeCoverPayment(Text.encodeUtf8(coverXml))) {
  case (#ok(decoded)) {
    assert (decoded.method == "COVER");
    assert (decoded.coverMessage.isCover);
    assert (decoded.coverMessage.underlyingPacs008MessageId == ?decoded.directMessage.messageId);
    assert (ISO.validateCoverPayment(crossBorder, decoded, ?Text.encodeUtf8(coverXml)).ok);
  };
  case (#err(_)) { assert false };
};

for (inv in [ISO.demoCamt056(), ISO.demoCamt029(), ISO.demoPacs028(), ISO.demoCamt110(), ISO.demoCamt111()].vals()) {
  let invXml = Xml.investigationToXml(inv);
  switch (Xml.decodeInvestigation(Text.encodeUtf8(invXml))) {
    case (#ok(decoded)) {
      assert (decoded.messageKind == inv.messageKind);
      assert (decoded.assignmentId == inv.assignmentId);
      assert (decoded.originalMessageId == inv.originalMessageId);
      assert (ISO.validateInvestigation(crossBorder, decoded).ok);
    };
    case (#err(_)) { assert false };
  };
};

for (rtp in [ISO.demoPain013(), ISO.demoPain014Accepted(), ISO.demoCamt055()].vals()) {
  let rtpXml = Xml.requestToPayToXml(rtp);
  switch (Xml.decodeRequestToPay(Text.encodeUtf8(rtpXml))) {
    case (#ok(decoded)) {
      assert (decoded.messageKind == rtp.messageKind);
      assert (decoded.messageId == rtp.messageId);
      assert (decoded.requestId == rtp.requestId);
      assert (decoded.originalRequestId == rtp.originalRequestId);
      assert (decoded.status == rtp.status);
      assert (ISO.validateRequestToPay(crossBorder, decoded).ok);
    };
    case (#err(_)) { assert false };
  };
};

for (dd in [ISO.demoPain008(), ISO.demoPacs003()].vals()) {
  let ddXml = Xml.directDebitToXml(dd);
  switch (Xml.decodeDirectDebit(Text.encodeUtf8(ddXml))) {
    case (#ok(decoded)) {
      assert (decoded.messageKind == dd.messageKind);
      assert (decoded.messageId == dd.messageId);
      assert (decoded.endToEndId == dd.endToEndId);
      assert (decoded.mandateId == dd.mandateId);
      assert (decoded.sequenceType == dd.sequenceType);
      assert (ISO.validateDirectDebit(crossBorder, decoded, ?Text.encodeUtf8(ddXml)).ok);
    };
    case (#err(_)) { assert false };
  };
};

for (admi in [ISO.demoAdmi002Reject(), ISO.demoAdmi004ConnectionCheck(), ISO.demoAdmi007Ack(), ISO.demoAdmi011ConnectionAck()].vals()) {
  let admiXml = Xml.administrativeToXml(admi);
  switch (Xml.decodeAdministrative(Text.encodeUtf8(admiXml))) {
    case (#ok(decoded)) {
      assert (decoded.messageKind == admi.messageKind);
      assert (decoded.messageId == admi.messageId);
      assert (decoded.eventCode == admi.eventCode);
      assert (decoded.status == admi.status);
      assert (ISO.validateAdministrativeMessage(crossBorder, decoded).ok);
    };
    case (#err(_)) { assert false };
  };
};

let statementEntry : ISO.StatementEntry = {
  entryId = "CAMT-42";
  paymentId = 42;
  uetr = "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011";
  accountIban = ?"EG380019000500000000263180002";
  accountOtherId = null;
  amount = { currency = "EGP"; minorUnits = 1_250_000 };
  creditDebit = "CRDT";
  status = "settled";
  bookedAt = 1_772_000_000_000_000_000;
  counterpartyName = "Debtor Fixture";
  remittance = ["Invoice 42"];
};

let camt054Xml = Xml.camt054ToXml(statementEntry);
switch (Xml.decodeCamt054(Text.encodeUtf8(camt054Xml))) {
  case (#ok(entries)) {
    assert (entries.size() == 1);
    assert (entries[0].paymentId == 42);
    assert (entries[0].bookedAt == statementEntry.bookedAt);
    assert (entries[0].remittance.size() == 1);
  };
  case (#err(_)) { assert false };
};

let camt053Xml = Xml.camt053ToXml([statementEntry, { statementEntry with entryId = "CAMT-43"; paymentId = 43 }]);
switch (Xml.decodeCamt053(Text.encodeUtf8(camt053Xml))) {
  case (#ok(entries)) {
    assert (entries.size() == 2);
    assert (entries[1].paymentId == 43);
  };
  case (#err(_)) { assert false };
};

// An XML declaration anywhere but the very start is refused, as a conforming parser refuses it; the
// defect the pacs.003 fixture carried (a declaration after the AppHdr) and its relatives.
let declAfterHeader = Text.encodeUtf8("<AppHdr xmlns=\"urn:iso:std:iso:20022:tech:xsd:head.001.001.02\"><Fr><FIId><FinInstnId><BICFI>DEUTDEFF</BICFI></FinInstnId></FIId></Fr></AppHdr>\n<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" # xml);
switch (Xml.decodePain001(declAfterHeader)) {
  case (#ok(_)) { assert false };
  case (#err(issues)) { assert (issues.size() > 0); assert (issues[0].ruleId == "XML-DECL-POSITION") };
};
switch (Xml.decodePain001(Text.encodeUtf8(" " # xml))) {
  case (#ok(_)) { assert false };
  case (#err(issues)) { assert (issues[0].ruleId == "XML-DECL-POSITION") };
};
switch (Xml.decodePain001(Text.encodeUtf8("<?xml version=\"1.0\"?>" # xml))) {
  case (#ok(_)) { assert false };
  case (#err(issues)) { assert (issues[0].ruleId == "XML-DECL-DUPLICATE") };
};
switch (Xml.decodePain001(Text.encodeUtf8(Text.replace(xml, #text "<Document", "\u{FEFF}<Document")))) {
  case (#ok(_)) { assert false };
  case (#err(issues)) { assert (issues[0].ruleId == "XML-BOM-POSITION") };
};
