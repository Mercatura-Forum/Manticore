import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import VarArray "mo:core/VarArray";
import Aes "../PqAes128";
import Gf16 "../PqGf16";
import Pq "../Mayo2PqVerifier";

let aesKey : [Nat8] = [
  0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
  0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
];
let aesPlain : [Nat8] = [
  0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
  0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
];
let aesCipher : [Nat8] = [
  0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30,
  0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a,
];
assert (Aes.encryptBlock(aesKey, aesPlain) == aesCipher);

let zeroKey = Array.tabulate<Nat8>(16, func(_ : Nat) : Nat8 { 0 });
let zeroCtr0 : [Nat8] = [
  0x66, 0xe9, 0x4b, 0xd4, 0xef, 0x8a, 0x2c, 0x3b,
  0x88, 0x4c, 0xfa, 0x59, 0xca, 0x34, 0x2b, 0x2e,
];
assert (Aes.ctr32be(zeroKey, 16) == zeroCtr0);

assert (Pq.publicKeyBytes == 4912);
assert (Pq.signatureBytes == 186);

let signedMessage : [Nat8] = [
  0xde, 0xc0, 0xc3, 0xb1, 0x11, 0x6e, 0x05, 0xac,
  0x78, 0xa6, 0x79, 0x43, 0x17, 0x24, 0x8a, 0x97,
  0xb0, 0x8f, 0xc4, 0x5e, 0x78, 0x91, 0x0c, 0xce,
  0x11, 0x6f, 0x5f, 0x17, 0x1a, 0x45, 0x07, 0x9b,
];
let salt = Array.tabulate<Nat8>(Pq.saltBytes, func(i : Nat) : Nat8 { Nat8.fromNat(i) });
let target = Pq.targetNibbles(signedMessage, salt);
let rustOracleTarget : [Nat8] = [
  4, 1, 9, 6, 7, 11, 2, 1, 7, 14, 13, 11, 3, 9, 7, 0,
  2, 1, 5, 2, 1, 5, 3, 2, 4, 11, 1, 12, 13, 0, 14, 13,
  5, 8, 10, 5, 6, 1, 1, 15, 6, 15, 6, 14, 5, 15, 8, 0,
  2, 0, 13, 6, 2, 11, 6, 1, 3, 7, 9, 13, 15, 11, 2, 8,
];
assert (target.size() == Pq.m);
assert (target == rustOracleTarget);

let p1 = VarArray.repeat<Nat8>(0, Pq.p1Bytes);
let p2 = VarArray.repeat<Nat8>(0, Pq.p2Bytes);
let p3 = VarArray.repeat<Nat8>(0, Pq.p3Bytes);
var eq : Nat = 0;
while (eq < Pq.m) {
  Gf16.setPacked(p3, 1 * Pq.m + eq, target[eq]);
  eq += 1;
};

let sigS = VarArray.repeat<Nat8>(0, Pq.signatureVectorBytes);
Gf16.setPacked(sigS, Pq.v, 1);
Gf16.setPacked(sigS, 3 * Pq.n + Pq.v + 1, 1);
let sig : Pq.Signature = { s = Array.fromVarArray<Nat8>(sigS); salt };
let epk : Pq.ExpandedPublicKey = {
  p1 = Array.fromVarArray<Nat8>(p1);
  p2 = Array.fromVarArray<Nat8>(p2);
  p3 = Array.fromVarArray<Nat8>(p3);
};

assert (Pq.verifyExpanded(epk, signedMessage, sig));

let badSigS = VarArray.tabulate<Nat8>(Pq.signatureVectorBytes, func(i : Nat) : Nat8 { sigS[i] });
Gf16.setPacked(badSigS, 3 * Pq.n + Pq.v + 1, 0);
let badSig : Pq.Signature = { s = Array.fromVarArray<Nat8>(badSigS); salt };
assert (not Pq.verifyExpanded(epk, signedMessage, badSig));
