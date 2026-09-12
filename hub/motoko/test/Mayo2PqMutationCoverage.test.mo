import Array "mo:core/Array";
import Runtime "mo:core/Runtime";
import Pq "../Mayo2PqVerifier";
import Vectors "../Mayo2PqRealVectors";

func requireExpandedPublicKey(bytes : [Nat8]) : Pq.ExpandedPublicKey {
  switch (Pq.expandPublicKey(bytes)) {
    case (?epk) epk;
    case null Runtime.trap("real vector public-key expansion failed");
  };
};

func requireSignature(bytes : [Nat8]) : Pq.Signature {
  switch (Pq.parseSignature(bytes)) {
    case (?sig) sig;
    case null Runtime.trap("real vector signature parse failed");
  };
};

func flipByte(bytes : [Nat8], byteIdx : Nat, mask : Nat8) : [Nat8] {
  Array.tabulate<Nat8>(bytes.size(), func(i : Nat) : Nat8 {
    if (i == byteIdx) bytes[i] ^ mask else bytes[i];
  });
};

let expectedSignedMessageBitFlips = 32 * 8;
let expectedSignatureVectorBitFlips = Pq.signatureVectorBytes * 8;
let expectedSignatureSaltBitFlips = Pq.saltBytes * 8;
let expectedBitFlipsPerVector =
  expectedSignedMessageBitFlips
  + expectedSignatureVectorBitFlips
  + expectedSignatureSaltBitFlips;

var checkedBitFlips : Nat = 0;
var vectorIndex : Nat = 0;
while (vectorIndex < Vectors.vectorCount) {
  let vector = Vectors.vector(vectorIndex);
  let epk = requireExpandedPublicKey(vector.publicKey);
  let sig = requireSignature(vector.signature);

  assert (Pq.verifyExpanded(epk, vector.signedMessage, sig));

  switch (Pq.singleBitMutationCoverage(epk, vector.signedMessage, sig)) {
    case (?coverage) {
      assert (coverage.signedMessageBitFlips == expectedSignedMessageBitFlips);
      assert (coverage.signatureVectorBitFlips == expectedSignatureVectorBitFlips);
      assert (coverage.signatureSaltBitFlips == expectedSignatureSaltBitFlips);
      checkedBitFlips += coverage.signedMessageBitFlips;
      checkedBitFlips += coverage.signatureVectorBitFlips;
      checkedBitFlips += coverage.signatureSaltBitFlips;
    };
    case null Runtime.trap("real vector single-bit mutation coverage failed");
  };

  if (vectorIndex == 0) {
    assert (not Pq.verifyExpanded(epk, Vectors.flipFirstBit(vector.signedMessage), sig));

    let badVectorSig = requireSignature(Vectors.flipFirstBit(vector.signature));
    assert (not Pq.verifyExpanded(epk, vector.signedMessage, badVectorSig));

    let badSaltSig = requireSignature(flipByte(vector.signature, Pq.signatureVectorBytes, 1));
    assert (not Pq.verifyExpanded(epk, vector.signedMessage, badSaltSig));
  };

  vectorIndex += 1;
};

assert (checkedBitFlips == Vectors.vectorCount * expectedBitFlipsPerVector);
