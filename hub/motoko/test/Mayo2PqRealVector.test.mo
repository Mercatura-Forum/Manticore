import Runtime "mo:core/Runtime";
import Pq "../Mayo2PqVerifier";
import Vectors "../Mayo2PqRealVectors";

assert (Vectors.vectorCount == 3);

func requireSignature(bytes : [Nat8]) : Pq.Signature {
  switch (Pq.parseSignature(bytes)) {
    case (?sig) sig;
    case null Runtime.trap("real vector signature parse failed");
  };
};

func requireExpansionWindow(bytes : [Nat8], offset : Nat, len : Nat) : [Nat8] {
  switch (Pq.expandP1P2Window(bytes, offset, len)) {
    case (?window) window;
    case null Runtime.trap("real vector public-key expansion window failed");
  };
};

var vectorIndex : Nat = 0;
while (vectorIndex < Vectors.vectorCount) {
  let vector = Vectors.vector(vectorIndex);
  assert (vector.publicKey.size() == Pq.publicKeyBytes);
  assert (vector.signature.size() == Pq.signatureBytes);
  assert (vector.signedMessage.size() == 32);
  assert (vector.targetNibbles.size() == Pq.m);

  let sig = requireSignature(vector.signature);
  assert (Pq.targetNibbles(vector.signedMessage, sig.salt) == vector.targetNibbles);

  assert (requireExpansionWindow(vector.publicKey, 0, 32) == vector.expandedP1Head);
  assert (requireExpansionWindow(vector.publicKey, Pq.p1Bytes - 32, 32) == vector.expandedP1Tail);
  assert (requireExpansionWindow(vector.publicKey, Pq.p1Bytes, 32) == vector.expandedP2Head);
  assert (requireExpansionWindow(vector.publicKey, Pq.p1Bytes + Pq.p2Bytes - 32, 32) == vector.expandedP2Tail);

  vectorIndex += 1;
};
