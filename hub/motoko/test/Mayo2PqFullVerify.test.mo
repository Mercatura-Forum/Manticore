import Pq "../Mayo2PqVerifier";
import Vectors "../Mayo2PqRealVectors";

var idx : Nat = 0;
while (idx < Vectors.vectorCount) {
  let vector = Vectors.vector(idx);
  assert (Pq.verifyCompactBytes(vector.publicKey, vector.signedMessage, vector.signature));
  idx += 1;
};
