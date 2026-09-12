import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import VarArray "mo:core/VarArray";
import Gf16 "../PqGf16";
import Keccak "../PqKeccak";
import Mayo "../Mayo2ShakeVerifier";

assert (Mayo.signatureBytes == 186);
assert (Mayo.shakePublicKeyBytes == 4928);
assert (Mayo.pqMayoPublicKeyBytes == 4912);
assert (Mayo.p3Bytes == 4896);

let shakeEmpty32 = Keccak.shake256([], 32);
let shakeExpected : [Nat8] = [
  0x46, 0xb9, 0xdd, 0x2b, 0x0b, 0xa8, 0x8d, 0x13,
  0x23, 0x3b, 0x3f, 0xeb, 0x74, 0x3e, 0xeb, 0x24,
  0x3f, 0xcd, 0x52, 0xea, 0x62, 0xb8, 0x1b, 0x82,
  0xb5, 0x0c, 0x27, 0x64, 0x6e, 0xd5, 0x76, 0x2f,
];
assert (shakeEmpty32 == shakeExpected);

var a : Nat8 = 0;
while (a < 16) {
  assert (Gf16.mul(a, 0) == 0);
  assert (Gf16.mul(a, 1) == a);
  if (a != 0) {
    assert (Gf16.mul(a, Gf16.inv(a)) == 1);
  };
  var b : Nat8 = 0;
  while (b < 16) {
    assert (Gf16.add(a, b) == (a ^ b));
    assert (Gf16.mul(a, b) == Gf16.mul(b, a));
    b += 1;
  };
  a += 1;
};

let msg : [Nat8] = [0x4d, 0x65, 0x6e, 0x65, 0x73, 0x65];
let salt = Array.tabulate<Nat8>(Mayo.saltBytes, func(i : Nat) : Nat8 { Nat8.fromNat(i) });
let target = Mayo.targetNibbles(msg, salt);
let rustOracleTarget : [Nat8] = [
  2, 1, 5, 9, 11, 1, 15, 5, 10, 5, 8, 3, 9, 2, 4, 3,
  9, 7, 12, 15, 4, 14, 2, 13, 1, 13, 9, 10, 14, 7, 7, 12,
  8, 1, 8, 7, 11, 14, 10, 13, 9, 7, 15, 5, 4, 6, 1, 3,
  8, 3, 11, 9, 13, 10, 6, 10, 10, 15, 2, 7, 13, 6, 3, 11,
];
assert (target.size() == Mayo.m);
assert (target == rustOracleTarget);

let p1 = VarArray.repeat<Nat8>(0, Mayo.p1Bytes);
let p2 = VarArray.repeat<Nat8>(0, Mayo.p2Bytes);
let p3 = VarArray.repeat<Nat8>(0, Mayo.p3Bytes);

var eq : Nat = 0;
while (eq < Mayo.m) {
  Gf16.setPacked(p3, eq * Mayo.triO + 1, target[eq]);
  eq += 1;
};

let sigS = VarArray.repeat<Nat8>(0, Mayo.signatureVectorBytes);
Gf16.setPacked(sigS, Mayo.v, 1);
Gf16.setPacked(sigS, 3 * Mayo.n + Mayo.v + 1, 1);

let epk : Mayo.ExpandedPublicKey = {
  p1 = Array.fromVarArray<Nat8>(p1);
  p2 = Array.fromVarArray<Nat8>(p2);
  p3 = Array.fromVarArray<Nat8>(p3);
};
let sig : Mayo.Signature = {
  s = Array.fromVarArray<Nat8>(sigS);
  salt;
};

assert (Mayo.verifyExpanded(epk, msg, sig));
assert (not Mayo.verifyExpanded(epk, [0xff], sig));

let badSigS = VarArray.tabulate<Nat8>(sig.s.size(), func(i : Nat) : Nat8 { sig.s[i] });
Gf16.setPacked(badSigS, 3 * Mayo.n + Mayo.v + 1, 0);
let badSig : Mayo.Signature = {
  s = Array.fromVarArray<Nat8>(badSigS);
  salt;
};
assert (not Mayo.verifyExpanded(epk, msg, badSig));

assert (Mayo.parseSignature(Array.concat<Nat8>(sig.s, sig.salt)) != null);
assert (Mayo.parseSignature(sig.s) == null);
