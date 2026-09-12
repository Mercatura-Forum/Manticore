import Connector "../Connector";
import Blob "mo:core/Blob";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

let owner = Principal.fromText("aaaaa-aa");

let connector : Connector.Connector = {
  id = "bank-eg-001";
  owner;
  active = true;
  publicKeyHash = ?Text.encodeUtf8("pkh");
  signaturePolicy = Connector.defaultSignaturePolicy(?Text.encodeUtf8("pkh"));
  allowedFormats = ["pain.001.xml", "payment.bundle.xml"];
  allowedEndpoints = ["https://bank.example/inbox"];
  nextInboundSequence = 7;
  createdAt = 0;
  updatedAt = 0;
};

let payload = Text.encodeUtf8("<Document/>");
let env : Connector.TransportEnvelope = {
  connectorId = "bank-eg-001";
  remoteId = "FILE-000007";
  sequence = 7;
  format = "pain.001.xml";
  payload;
  payloadHash = payload;
  signature = ?Text.encodeUtf8("sig");
  sentAt = 1;
  traceId = "trace-000007";
  endpoint = ?"https://bank.example/inbox";
};

func ctx(c : ?Connector.Connector, expectedHash : Blob, remoteSeen : Bool) : Connector.VerificationContext {
  { connector = c; expectedHash; remoteAlreadySeen = remoteSeen; caller = ?owner; memphisPrincipal = null };
};

let ok = Connector.verifyEnvelope(ctx(?connector, payload, false), env);
assert (ok.size() == 0);
assert (Connector.statusFromIssues(ok) == "verified");

let gap = Connector.verifyEnvelope(
  ctx(?connector, payload, false),
  { env with sequence = 9 },
);
assert (gap.size() == 1);
assert (gap[0].ruleId == "TRANSPORT-SEQUENCE-GAP");

let checksum = Connector.verifyEnvelope(
  ctx(?connector, Text.encodeUtf8("other"), false),
  env,
);
assert (checksum.size() == 1);
assert (checksum[0].ruleId == "TRANSPORT-CHECKSUM-MISMATCH");

let unsupported = Connector.verifyEnvelope(
  ctx(?connector, payload, false),
  { env with format = "mt940" },
);
assert (unsupported.size() == 1);
assert (unsupported[0].ruleId == "TRANSPORT-UNSUPPORTED-FORMAT");

let duplicate = Connector.verifyEnvelope(
  ctx(?connector, payload, true),
  env,
);
assert (duplicate.size() == 1);
assert (duplicate[0].ruleId == "TRANSPORT-DUPLICATE-REMOTE-ID");

let unsigned = Connector.verifyEnvelope(
  ctx(?connector, payload, false),
  { env with signature = null },
);
assert (unsigned.size() == 1);
assert (unsigned[0].ruleId == "TRANSPORT-SIGNATURE-REQUIRED");

let thebesConnector = { connector with publicKeyHash = null; signaturePolicy = Connector.thebesCallerPolicy() };
let wrongCaller = Connector.verifyEnvelope(
  { connector = ?thebesConnector; expectedHash = payload; remoteAlreadySeen = false; caller = ?Principal.fromText("2vxsx-fae"); memphisPrincipal = null },
  { env with signature = null },
);
assert (wrongCaller.size() == 1);
assert (wrongCaller[0].ruleId == "TRANSPORT-CALLER-NOT-CONNECTOR-OWNER");

let memphisConnector = { connector with publicKeyHash = null; signaturePolicy = Connector.memphisSessionPolicy() };
let missingMemphis = Connector.verifyEnvelope(ctx(?memphisConnector, payload, false), { env with signature = null });
assert (missingMemphis.size() == 1);
assert (missingMemphis[0].ruleId == "TRANSPORT-MEMPHIS-SESSION-REQUIRED");

let memphisOk = Connector.verifyEnvelope(
  { connector = ?memphisConnector; expectedHash = payload; remoteAlreadySeen = false; caller = ?Principal.fromText("2vxsx-fae"); memphisPrincipal = ?owner },
  { env with signature = null },
);
assert (memphisOk.size() == 0);

let externalConnector = {
  connector with
  signaturePolicy = Connector.externalAttestationPolicy("mayo2", ?Text.encodeUtf8("pkh"), Principal.fromText("aaaaa-aa"));
};
let missingExternalSig = Connector.verifyEnvelope(ctx(?externalConnector, payload, false), { env with signature = null });
assert (missingExternalSig.size() == 1);
assert (missingExternalSig[0].ruleId == "TRANSPORT-SIGNATURE-REQUIRED");

let outboundOk = Connector.verifyOutboundQueue(?connector, "bank-eg-001", "payment.bundle.xml", payload);
assert (outboundOk.size() == 0);

let outboundUnsupported = Connector.verifyOutboundQueue(?connector, "bank-eg-001", "pacs.009.xml", payload);
assert (outboundUnsupported.size() == 1);
assert (outboundUnsupported[0].ruleId == "OUTBOUND-FORMAT-UNSUPPORTED");

let batch : Connector.OutboundBatch = {
  id = 3;
  connectorId = "bank-eg-001";
  paymentId = ?9;
  format = "payment.bundle.xml";
  payload;
  payloadHash = payload;
  status = "leased";
  attemptCount = 1;
  maxAttempts = 3;
  createdAt = 0;
  updatedAt = 0;
  leasedUntil = ?1000;
  ack = null;
  issueCount = 0;
  issues = [];
};

let ack : Connector.DeliveryAck = {
  batchId = 3;
  connectorId = "bank-eg-001";
  remoteReceiptId = "BANK-RCPT-000003";
  deliveredAt = 10;
  status = "ACK";
  detail = "accepted by downstream gateway";
  payloadHash = payload;
};

let ackOk = Connector.verifyDeliveryAck(?batch, ack);
assert (ackOk.size() == 0);

let ackHashMismatch = Connector.verifyDeliveryAck(?batch, { ack with payloadHash = Text.encodeUtf8("wrong") });
assert (ackHashMismatch.size() == 1);
assert (ackHashMismatch[0].ruleId == "OUTBOUND-ACK-HASH-MISMATCH");
