/// PqSchemes.mo — the post-quantum connector signature schemes of the payments rails.
///
/// A rail declares the scheme its connectors sign with; a connector registers its public key per
/// BIC (dual); a received message on such a rail carries a signature over its exact bytes, checked
/// here before the message is read. Two schemes, both verified in pure Motoko against their
/// reference vectors:
///
///   MAYO-2     NIST PQC additional-signatures round 2, the AES-128-CTR key expansion of the
///              specification; compact public key 4,912 bytes, signature 186 bytes
///              (`Mayo2PqVerifier.mo`, proved on the pq-mayo consensus vectors)
///   ML-DSA-44  FIPS 204; public key 1,312 bytes, signature 2,420 bytes (`MlDsa44.mo`, proved on the
///              NIST known-answer vectors)
///
/// ML-DSA signs with a context string: every connector on a Thebes rail signs with `CONTEXT` below,
/// so a signature made for another protocol or another Thebes surface does not verify here.

import Blob "mo:core/Blob";
import Text "mo:core/Text";

import Mayo "Mayo2PqVerifier";
import MlDsa "MlDsa44";

module {

  public let MAYO2_PK_BYTES : Nat = 4_912;
  public let MAYO2_SIG_BYTES : Nat = 186;
  public let MLDSA44_PK_BYTES : Nat = MlDsa.PK_BYTES;
  public let MLDSA44_SIG_BYTES : Nat = MlDsa.SIG_BYTES;

  /// The FIPS 204 context string of every connector signature on a Thebes payments rail.
  public let CONTEXT : Text = "thebes.bank.iso20022.connector.v1";

  public func verifyMayo2(publicKey : Blob, message : Blob, signature : Blob) : Bool {
    if (publicKey.size() != MAYO2_PK_BYTES or signature.size() != MAYO2_SIG_BYTES) return false;
    Mayo.verifyCompactBytes(Blob.toArray(publicKey), Blob.toArray(message), Blob.toArray(signature))
  };

  public func verifyMlDsa44(publicKey : Blob, message : Blob, signature : Blob) : Bool {
    MlDsa.verify(Blob.toArray(publicKey), Blob.toArray(message), Blob.toArray(Text.encodeUtf8(CONTEXT)), Blob.toArray(signature))
  };
}
