import Oracles "../PhaseOracle";

let phases = Oracles.registry();
assert (phases.size() >= 10);
assert (Oracles.registryVersion == "phase-oracle-v1-2026-06-24-c8");

var hasGuideline = false;
var hasXml = false;
var hasConnector = false;
var hasAudit = false;
var hasCertifiedDisclosure = false;
var hasParticipantWorkflow = false;
var hasPfmi = false;
var hasStableIndexes = false;

for (p in phases.vals()) {
  if (p.phase == "guideline.configuration") hasGuideline := true;
  if (p.phase == "xml.codec") hasXml := true;
  if (p.phase == "connector.envelope") hasConnector := true;
  if (p.phase == "audit.evidence") hasAudit := true;
  if (p.phase == "certified.disclosure") hasCertifiedDisclosure := true;
  if (p.phase == "participant.workflow") hasParticipantWorkflow := true;
  if (p.phase == "pfmi.self.assessment") hasPfmi := true;
  if (p.phase == "stable.indexes" and p.status == "implemented-partial") hasStableIndexes := true;
  assert (p.phase != "");
  assert (p.verifier != "");
};

assert (hasGuideline);
assert (hasXml);
assert (hasConnector);
assert (hasAudit);
assert (hasCertifiedDisclosure);
assert (hasParticipantWorkflow);
assert (hasPfmi);
assert (hasStableIndexes);

assert (Oracles.validPolicyMode("thebes-caller"));
assert (Oracles.validPolicyMode("memphis-session"));
assert (Oracles.validPolicyMode("external-attestation"));
assert (not Oracles.validPolicyMode("pretend-auth"));

assert (Oracles.validSignatureScheme("mayo2"));
assert (Oracles.validSignatureScheme("frost-ed25519"));
assert (not Oracles.validSignatureScheme("unknown-curve"));

assert (Oracles.validOutboundStatus("queued"));
assert (Oracles.validOutboundStatus("dead-letter"));
assert (not Oracles.validOutboundStatus("lost"));

assert (Oracles.validAckStatus("ACK"));
assert (Oracles.validAckStatus("NACK"));
assert (not Oracles.validAckStatus("MAYBE"));
