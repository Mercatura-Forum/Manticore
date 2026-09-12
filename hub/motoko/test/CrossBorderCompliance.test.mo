import ISO "../ISO20022";
import Xml "../ISO20022Xml";
import Text "mo:core/Text";

let g = ISO.crossBorderEducationGuideline();
let pacs009 = ISO.demoPacs009Core();
let pacs009Report = ISO.validatePacs009(g, pacs009, null);
assert (pacs009Report.ok);

let cover = ISO.demoCoverPayment();
let coverReport = ISO.validateCoverPayment(g, cover, null);
assert (coverReport.ok);

assert (ISO.validateInvestigation(g, ISO.demoCamt056()).ok);
assert (ISO.validateInvestigation(g, ISO.demoCamt029()).ok);
assert (ISO.validateInvestigation(g, ISO.demoPacs028()).ok);

let defaultScreen = ISO.screenCoverPayment(ISO.defaultComplianceProfile(), cover);
assert (defaultScreen.decision == "review");
assert (defaultScreen.findingCount > 0);

let blockedProfile = {
  ISO.defaultComplianceProfile() with
  blockedBics = ["CHASUS33"];
};
let blocked = ISO.screenPacs009(blockedProfile, pacs009);
assert (blocked.decision == "block");
assert (blocked.riskScore >= 100);

let pacs009Xml = Xml.pacs009ToXml(pacs009);
assert (Text.contains(pacs009Xml, #text "<FICdtTrf>"));
assert (Text.contains(pacs009Xml, #text "<CrossBorderRouting>"));

let coverXml = Xml.coverPaymentToXml(cover);
assert (Text.contains(coverXml, #text "<CoverPaymentBundle"));
assert (Text.contains(coverXml, #text "<CoverPacs009>"));

let camt056Xml = Xml.investigationToXml(ISO.demoCamt056());
assert (Text.contains(camt056Xml, #text "<FIToFIPmtCxlReq>"));

let complianceXml = Xml.complianceReportToXml(blocked);
assert (Text.contains(complianceXml, #text "<ComplianceReport"));
assert (Text.contains(complianceXml, #text "<Decision>block</Decision>"));
