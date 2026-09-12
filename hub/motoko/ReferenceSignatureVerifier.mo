/// Reference connector-signature verifier for integration tests and demos.
///
/// This is not a production PKI implementation. It proves the external
/// verifier seam by checking a deterministic attestation over the hub's
/// canonical connector-envelope hash.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import InPlaceSha256d "InPlaceSha256d";

persistent actor ReferenceSignatureVerifier {

  public type ValidationIssue = {
    severity : Text;
    tier : Text;
    ruleId : Text;
    path : Text;
    message : Text;
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

  transient let hasher = InPlaceSha256d.Hasher();
  let referenceScheme = "reference-sha256";

  public query func reference_connector_signature(envelopeHash : Blob, publicKeyHash : ?Blob) : async Blob {
    expectedSignature(envelopeHash, publicKeyHash);
  };

  public query func verify_connector_signature(request : SignatureVerificationRequest) : async SignatureVerificationReport {
    var issues : [ValidationIssue] = [];
    if (request.scheme != referenceScheme) {
      issues := addIssue(issues, issue("TRANSPORT-REFERENCE-SCHEME", "$.scheme", "reference verifier only accepts scheme " # referenceScheme));
    };
    let expected = expectedSignature(request.envelopeHash, request.publicKeyHash);
    if (request.signature != expected) {
      issues := addIssue(issues, issue("TRANSPORT-REFERENCE-SIGNATURE-MISMATCH", "$.signature", "reference signature does not match the canonical envelope hash"));
    };
    {
      ok = issues.size() == 0;
      scheme = request.scheme;
      verifier = Principal.fromActor(ReferenceSignatureVerifier);
      signerKeyHash = request.publicKeyHash;
      messageHash = request.envelopeHash;
      signatureHash = hashBlob(request.signature);
      issueCount = issues.size();
      issues;
    };
  };

  func expectedSignature(envelopeHash : Blob, publicKeyHash : ?Blob) : Blob {
    var preimage : [Nat8] = textBytes("thebes.reference.connector.signature.v1");
    preimage := appendBlob(preimage, envelopeHash);
    switch (publicKeyHash) {
      case (?hash) {
        preimage := Array.concat<Nat8>(preimage, [1]);
        preimage := appendBlob(preimage, hash);
      };
      case null {
        preimage := Array.concat<Nat8>(preimage, [0]);
      };
    };
    sha256(preimage);
  };

  func issue(ruleId : Text, path : Text, message : Text) : ValidationIssue {
    { severity = "error"; tier = "transport"; ruleId; path; message };
  };

  func addIssue(xs : [ValidationIssue], x : ValidationIssue) : [ValidationIssue] {
    Array.concat<ValidationIssue>(xs, [x]);
  };

  func hashBlob(value : Blob) : Blob {
    sha256(Blob.toArray(value));
  };

  func appendBlob(xs : [Nat8], blob : Blob) : [Nat8] {
    Array.concat<Nat8>(xs, Blob.toArray(blob));
  };

  func textBytes(value : Text) : [Nat8] {
    Blob.toArray(Text.encodeUtf8(value));
  };

  func sha256(value : [Nat8]) : Blob {
    Blob.fromArray(hasher.sha256General(value));
  };
};
