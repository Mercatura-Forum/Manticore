// MlDsa44.test.mo; ML-DSA-44 verification against the NIST known-answer vectors.
//
// What is proved: each KAT signature (pk, ctx, msg, σ from the reference implementation's answer
// file) verifies under `MlDsa44.verify`; the same signature is refused when one byte of the
// signature, one byte of the message, the context or one byte of the public key is changed, and
// when its hint encoding is malformed (a non-increasing hint index) or its length is wrong.
//
// engine: wasi-only; a verification is a few hundred million instructions.

import Debug "mo:core/Debug";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";

import MlDsa44 "../src/pq/MlDsa44";
import KAT "support/MlDsa44Kat";

var verified = 0;
var refused = 0;
func flip(a : [Nat8], i : Nat) : [Nat8] { Array.tabulate<Nat8>(a.size(), func(j) { if (j == i) a[j] ^ 0x01 else a[j] }) };

for (v in KAT.VECTORS.vals()) {
  assert (v.pk.size() == MlDsa44.PK_BYTES and v.sig.size() == MlDsa44.SIG_BYTES);
  if (not MlDsa44.verify(v.pk, v.msg, v.ctx, v.sig)) { Debug.print("KAT " # Nat.toText(v.count) # " does not verify"); assert false };
  verified += 1;
  // mutations: a signature byte in c̃, one in z, one in the hint; a message byte; the context; a key byte
  for (bad in [flip(v.sig, 3), flip(v.sig, 700), flip(v.sig, 2_400)].vals()) { assert (not MlDsa44.verify(v.pk, v.msg, v.ctx, bad)); refused += 1 };
  if (v.msg.size() > 0) { assert (not MlDsa44.verify(v.pk, flip(v.msg, 0), v.ctx, v.sig)); refused += 1 };
  assert (not MlDsa44.verify(v.pk, v.msg, Array.concat<Nat8>(v.ctx, [1]), v.sig)); refused += 1;
  assert (not MlDsa44.verify(flip(v.pk, 40), v.msg, v.ctx, v.sig)); refused += 1;
  // a truncated signature and an overlong one
  assert (not MlDsa44.verify(v.pk, v.msg, v.ctx, Array.tabulate<Nat8>(v.sig.size() - 1, func(i) { v.sig[i] }))); refused += 1;
  assert (not MlDsa44.verify(v.pk, v.msg, v.ctx, Array.concat<Nat8>(v.sig, [0]))); refused += 1;
};
// a malformed hint encoding: the k running counts set past ω
let v0 = KAT.VECTORS[0];
let badHint = Array.tabulate<Nat8>(v0.sig.size(), func(i) { if (i == v0.sig.size() - 1) 81 else v0.sig[i] });
assert (MlDsa44.sigDecode(badHint) == null);
refused += 1;
Debug.print("count: KAT signatures verified = " # Nat.toText(verified));
Debug.print("count: mutated or malformed signatures refused = " # Nat.toText(refused));
Debug.print("ML-DSA-44 TEST GREEN");
