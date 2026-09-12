// Mayo2.test.mo — MAYO-2 verification against the pq-mayo consensus vectors, through the scheme adapter.
//
// What is proved: each real vector (compact public key, message, signature from the pq-mayo
// reference) verifies under `PqSchemes.verifyMayo2`; a bit flipped in the message, in the signature
// vector, in the salt or in the public key is refused; a wrong-length key or signature is refused.
//
// engine: wasi-only — one verification expands a 4,912-byte compact key into 101 KB.

import Debug "mo:core/Debug";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";

import Pq "../src/pq/PqSchemes";
import Vectors "support/Mayo2PqRealVectors";

func flip(a : [Nat8], i : Nat) : [Nat8] { Array.tabulate<Nat8>(a.size(), func(j) { if (j == i) a[j] ^ 0x01 else a[j] }) };
func b(a : [Nat8]) : Blob { Blob.fromArray(a) };
var verified = 0; var refused = 0;
var i = 0;
while (i < Vectors.vectorCount) {
  let v = Vectors.vector(i);
  assert (Pq.verifyMayo2(b(v.publicKey), b(v.signedMessage), b(v.signature)));
  verified += 1;
  assert (not Pq.verifyMayo2(b(v.publicKey), b(flip(v.signedMessage, 0)), b(v.signature))); refused += 1;
  assert (not Pq.verifyMayo2(b(v.publicKey), b(v.signedMessage), b(flip(v.signature, 0)))); refused += 1;          // the signature vector
  assert (not Pq.verifyMayo2(b(v.publicKey), b(v.signedMessage), b(flip(v.signature, 170)))); refused += 1;        // the salt
  assert (not Pq.verifyMayo2(b(flip(v.publicKey, 100)), b(v.signedMessage), b(v.signature))); refused += 1;
  assert (not Pq.verifyMayo2(b(Array.tabulate<Nat8>(v.publicKey.size() - 1, func(k) { v.publicKey[k] })), b(v.signedMessage), b(v.signature))); refused += 1;
  assert (not Pq.verifyMayo2(b(v.publicKey), b(v.signedMessage), b(Array.concat<Nat8>(v.signature, [0])))); refused += 1;
  i += 1;
};
Debug.print("count: MAYO-2 consensus vectors verified = " # Nat.toText(verified));
Debug.print("count: mutated or malformed MAYO-2 signatures refused = " # Nat.toText(refused));
Debug.print("MAYO-2 TEST GREEN");
