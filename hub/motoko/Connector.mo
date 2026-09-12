/// Connector.mo -- canister-native bank connector envelope verifier.
///
/// Inspired by enterprise integration patterns, but represented as deterministic
/// on-chain state: connector registry, signed/hash-bound envelopes, sequence
/// checks, idempotency, content routing, and dead-letter reasons.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import ISO "ISO20022";

module {

  public type Connector = {
    id : Text;
    owner : Principal;
    active : Bool;
    publicKeyHash : ?Blob;
    signaturePolicy : SignaturePolicy;
    allowedFormats : [Text];
    allowedEndpoints : [Text];
    nextInboundSequence : Nat;
    createdAt : Int;
    updatedAt : Int;
  };

  public type SignaturePolicy = {
    mode : Text;
    scheme : Text;
    publicKeyHash : ?Blob;
    verifier : ?Principal;
    requireSignature : Bool;
    domain : Text;
  };

  public type TransportEnvelope = {
    connectorId : Text;
    remoteId : Text;
    sequence : Nat;
    format : Text;
    payload : Blob;
    payloadHash : Blob;
    signature : ?Blob;
    sentAt : Int;
    traceId : Text;
    endpoint : ?Text;
  };

  public type TransportRecord = {
    id : Nat;
    connectorId : Text;
    remoteId : Text;
    sequence : Nat;
    format : Text;
    traceId : Text;
    receivedAt : Int;
    payloadHash : Blob;
    status : Text;
    paymentId : ?Nat;
    issueCount : Nat;
    issues : [ISO.ValidationIssue];
  };

  public type DeliveryAck = {
    batchId : Nat;
    connectorId : Text;
    remoteReceiptId : Text;
    deliveredAt : Int;
    status : Text;
    detail : Text;
    payloadHash : Blob;
  };

  public type OutboundBatch = {
    id : Nat;
    connectorId : Text;
    paymentId : ?Nat;
    format : Text;
    payload : Blob;
    payloadHash : Blob;
    status : Text;
    attemptCount : Nat;
    maxAttempts : Nat;
    createdAt : Int;
    updatedAt : Int;
    leasedUntil : ?Int;
    ack : ?DeliveryAck;
    issueCount : Nat;
    issues : [ISO.ValidationIssue];
  };

  public type VerificationContext = {
    connector : ?Connector;
    expectedHash : Blob;
    remoteAlreadySeen : Bool;
    caller : ?Principal;
    memphisPrincipal : ?Principal;
  };

  public func verifyEnvelope(ctx : VerificationContext, env : TransportEnvelope) : [ISO.ValidationIssue] {
    var issues : [ISO.ValidationIssue] = [];
    switch (ctx.connector) {
      case null {
        issues := add(issues, ISO.publicIssue("transport", "CONNECTOR-NOT-FOUND", "$.connectorId", "connector is not registered"));
      };
      case (?c) {
        if (not c.active) {
          issues := add(issues, ISO.publicIssue("transport", "CONNECTOR-INACTIVE", "$.connectorId", "connector is not active"));
        };
        if (env.connectorId != c.id) {
          issues := add(issues, ISO.publicIssue("transport", "CONNECTOR-ID-MISMATCH", "$.connectorId", "envelope connector id does not match registry record"));
        };
        if (env.sequence < c.nextInboundSequence) {
          issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-DUPLICATE-SEQUENCE", "$.sequence", "sequence is lower than next expected inbound sequence"));
        } else if (env.sequence > c.nextInboundSequence) {
          issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-SEQUENCE-GAP", "$.sequence", "sequence is greater than next expected inbound sequence"));
        };
        if (not containsText(c.allowedFormats, env.format)) {
          issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-UNSUPPORTED-FORMAT", "$.format", "connector is not allowed to submit this format"));
        };
        switch (env.endpoint) {
          case (?ep) {
            if (c.allowedEndpoints.size() > 0 and not containsText(c.allowedEndpoints, ep)) {
              issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-ENDPOINT-NOT-ALLOWED", "$.endpoint", "endpoint is not allowed for this connector"));
            };
          };
          case null {};
        };
        issues := validateSignaturePolicy(c, ctx, env, issues);
      };
    };
    if (env.remoteId == "") {
      issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-REMOTE-ID-REQUIRED", "$.remoteId", "remote file/message id is required"));
    };
    if (env.payload.size() == 0) {
      issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-PAYLOAD-EMPTY", "$.payload", "payload must not be empty"));
    };
    if (env.payloadHash != ctx.expectedHash) {
      issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-CHECKSUM-MISMATCH", "$.payloadHash", "payload hash does not match received payload"));
    };
    if (ctx.remoteAlreadySeen) {
      issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-DUPLICATE-REMOTE-ID", "$.remoteId", "remote id was already processed"));
    };
    if (env.traceId == "") {
      issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-TRACE-ID-REQUIRED", "$.traceId", "trace id is required for cross-system observability"));
    };
    issues;
  };

  public func defaultSignaturePolicy(publicKeyHash : ?Blob) : SignaturePolicy {
    {
      mode = switch (publicKeyHash) {
        case (?_) "signature-presence";
        case null "none";
      };
      scheme = switch (publicKeyHash) {
        case (?_) "detached-opaque";
        case null "none";
      };
      publicKeyHash;
      verifier = null;
      requireSignature = switch (publicKeyHash) { case (?_) true; case null false };
      domain = "thebes.iso20022.connector.v1";
    };
  };

  public func thebesCallerPolicy() : SignaturePolicy {
    {
      mode = "thebes-caller";
      scheme = "thebes-ingress";
      publicKeyHash = null;
      verifier = null;
      requireSignature = false;
      domain = "thebes.iso20022.connector.v1";
    };
  };

  public func memphisSessionPolicy() : SignaturePolicy {
    {
      mode = "memphis-session";
      scheme = "memphis-derived-principal";
      publicKeyHash = null;
      verifier = null;
      requireSignature = false;
      domain = "thebes.iso20022.connector.v1";
    };
  };

  public func externalAttestationPolicy(scheme : Text, publicKeyHash : ?Blob, verifier : Principal) : SignaturePolicy {
    {
      mode = "external-attestation";
      scheme;
      publicKeyHash;
      verifier = ?verifier;
      requireSignature = true;
      domain = "thebes.iso20022.connector.v1";
    };
  };

  func validateSignaturePolicy(c : Connector, ctx : VerificationContext, env : TransportEnvelope, issues0 : [ISO.ValidationIssue]) : [ISO.ValidationIssue] {
    var issues = issues0;
    let policy = c.signaturePolicy;
    if (policy.requireSignature) {
      switch (env.signature) {
        case null {
          issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-SIGNATURE-REQUIRED", "$.signature", "connector signature policy requires a detached signature or attestation input"));
        };
        case (?sig) {
          if (sig.size() == 0) {
            issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-SIGNATURE-EMPTY", "$.signature", "signature bytes must not be empty"));
          };
        };
      };
    };

    if (policy.mode == "none" or policy.mode == "signature-presence") {
      return issues;
    };

    if (policy.mode == "thebes-caller") {
      switch (ctx.caller) {
        case (?caller) {
          if (not Principal.equal(caller, c.owner)) {
            issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-CALLER-NOT-CONNECTOR-OWNER", "$caller", "Thebes-authenticated caller must be the registered connector owner"));
          };
        };
        case null {
          issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-CALLER-REQUIRED", "$caller", "Thebes caller principal is required for this connector policy"));
        };
      };
      return issues;
    };

    if (policy.mode == "memphis-session") {
      switch (ctx.memphisPrincipal) {
        case (?principal) {
          if (not Principal.equal(principal, c.owner)) {
            issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-MEMPHIS-PRINCIPAL-MISMATCH", "$memphis.principal", "Memphis-derived principal must be the registered connector owner"));
          };
        };
        case null {
          issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-MEMPHIS-SESSION-REQUIRED", "$memphis", "verified Memphis session is required for this connector policy"));
        };
      };
      return issues;
    };

    if (policy.mode == "external-attestation") {
      switch (policy.verifier) {
        case null {
          issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-SIGNATURE-VERIFIER-REQUIRED", "$.signaturePolicy.verifier", "external-attestation policy requires a verifier canister principal"));
        };
        case (?_) {};
      };
      if (policy.scheme == "" or policy.scheme == "none") {
        issues := add(issues, ISO.publicIssue("transport", "TRANSPORT-SIGNATURE-SCHEME-REQUIRED", "$.signaturePolicy.scheme", "external-attestation policy requires a concrete signature scheme"));
      };
      return issues;
    };

    add(issues, ISO.publicIssue("transport", "TRANSPORT-SIGNATURE-POLICY-MODE", "$.signaturePolicy.mode", "connector signature policy mode is unsupported"));
  };

  public func verifyOutboundQueue(connector : ?Connector, connectorId : Text, format : Text, payload : Blob) : [ISO.ValidationIssue] {
    var issues : [ISO.ValidationIssue] = [];
    switch (connector) {
      case null {
        issues := add(issues, ISO.publicIssue("transport", "OUTBOUND-CONNECTOR-NOT-FOUND", "$.connectorId", "connector is not registered"));
      };
      case (?c) {
        if (c.id != connectorId) {
          issues := add(issues, ISO.publicIssue("transport", "OUTBOUND-CONNECTOR-MISMATCH", "$.connectorId", "connector id does not match registry record"));
        };
        if (not c.active) {
          issues := add(issues, ISO.publicIssue("transport", "OUTBOUND-CONNECTOR-INACTIVE", "$.connectorId", "connector is not active"));
        };
        if (not containsText(c.allowedFormats, format)) {
          issues := add(issues, ISO.publicIssue("transport", "OUTBOUND-FORMAT-UNSUPPORTED", "$.format", "connector is not allowed to receive this outbound format"));
        };
      };
    };
    if (payload.size() == 0) {
      issues := add(issues, ISO.publicIssue("transport", "OUTBOUND-PAYLOAD-EMPTY", "$.payload", "outbound payload must not be empty"));
    };
    issues;
  };

  public func verifyDeliveryAck(batch : ?OutboundBatch, ack : DeliveryAck) : [ISO.ValidationIssue] {
    var issues : [ISO.ValidationIssue] = [];
    switch (batch) {
      case null {
        issues := add(issues, ISO.publicIssue("transport", "OUTBOUND-BATCH-NOT-FOUND", "$.batchId", "outbound batch does not exist"));
      };
      case (?b) {
        if (ack.connectorId != b.connectorId) {
          issues := add(issues, ISO.publicIssue("transport", "OUTBOUND-ACK-CONNECTOR-MISMATCH", "$.connectorId", "delivery ACK connector does not match outbound batch"));
        };
        if (ack.payloadHash != b.payloadHash) {
          issues := add(issues, ISO.publicIssue("transport", "OUTBOUND-ACK-HASH-MISMATCH", "$.payloadHash", "delivery ACK payload hash does not match outbound batch"));
        };
        if (b.status == "acked") {
          issues := add(issues, ISO.publicIssue("transport", "OUTBOUND-ACK-DUPLICATE", "$.status", "outbound batch is already acknowledged"));
        };
      };
    };
    if (ack.remoteReceiptId == "") {
      issues := add(issues, ISO.publicIssue("transport", "OUTBOUND-ACK-RECEIPT-REQUIRED", "$.remoteReceiptId", "delivery ACK requires a remote receipt id"));
    };
    if (ack.status != "ACK" and ack.status != "NACK") {
      issues := add(issues, ISO.publicIssue("transport", "OUTBOUND-ACK-STATUS", "$.status", "delivery ACK status must be ACK or NACK"));
    };
    issues;
  };

  public func statusFromIssues(issues : [ISO.ValidationIssue]) : Text {
    if (issues.size() == 0) "verified" else "dead-letter";
  };

  public func add(xs : [ISO.ValidationIssue], x : ISO.ValidationIssue) : [ISO.ValidationIssue] {
    Array.concat<ISO.ValidationIssue>(xs, [x]);
  };

  public func containsText(xs : [Text], value : Text) : Bool {
    for (x in xs.vals()) {
      if (x == value) return true;
    };
    false;
  };
};
