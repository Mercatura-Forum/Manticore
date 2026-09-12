import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import VarArray "mo:core/VarArray";
import Gf16 "PqGf16";
import Keccak "PqKeccak";

module {
  public let m : Nat = 64;
  public let n : Nat = 81;
  public let o : Nat = 17;
  public let v : Nat = 64;
  public let k : Nat = 4;
  public let pairCount : Nat = 10;
  public let extRows : Nat = 73;

  public let triV : Nat = 2080;
  public let triO : Nat = 153;
  public let p1Bytes : Nat = 66560;
  public let p2Bytes : Nat = 34816;
  public let p3Bytes : Nat = 4896;

  public let shakePkSeedBytes : Nat = 32;
  public let pqMayoPkSeedBytes : Nat = 16;
  public let shakePublicKeyBytes : Nat = 4928;
  public let pqMayoPublicKeyBytes : Nat = 4912;

  public let signatureVectorBytes : Nat = 162;
  public let saltBytes : Nat = 24;
  public let signatureBytes : Nat = 186;

  public type PublicKey = {
    seed : [Nat8];
    p3 : [Nat8];
  };

  public type ExpandedPublicKey = {
    p1 : [Nat8];
    p2 : [Nat8];
    p3 : [Nat8];
  };

  public type Signature = {
    s : [Nat8];
    salt : [Nat8];
  };

  public func parseSignature(bytes : [Nat8]) : ?Signature {
    if (bytes.size() != signatureBytes) {
      return null;
    };
    let s = Array.tabulate<Nat8>(signatureVectorBytes, func(i : Nat) : Nat8 { bytes[i] });
    let salt = Array.tabulate<Nat8>(saltBytes, func(i : Nat) : Nat8 { bytes[signatureVectorBytes + i] });
    ?{ s; salt };
  };

  public func parseShakePublicKey(bytes : [Nat8]) : ?PublicKey {
    if (bytes.size() != shakePublicKeyBytes) {
      return null;
    };
    let seed = Array.tabulate<Nat8>(shakePkSeedBytes, func(i : Nat) : Nat8 { bytes[i] });
    let p3 = Array.tabulate<Nat8>(p3Bytes, func(i : Nat) : Nat8 { bytes[shakePkSeedBytes + i] });
    ?{ seed; p3 };
  };

  public func expandShakePublicKey(pk : PublicKey) : ?ExpandedPublicKey {
    if (pk.seed.size() != shakePkSeedBytes or pk.p3.size() != p3Bytes) {
      return null;
    };
    let p1 = expandSHAKE(pk.seed, 0x02, p1Bytes);
    let p2 = expandSHAKE(pk.seed, 0x03, p2Bytes);
    ?{ p1; p2; p3 = pk.p3 };
  };

  public func verifyCompactShake(pk : PublicKey, msg : [Nat8], sig : Signature) : Bool {
    switch (expandShakePublicKey(pk)) {
      case (?epk) verifyExpanded(epk, msg, sig);
      case null false;
    };
  };

  public func verifyCompactShakeBytes(pkBytes : [Nat8], msg : [Nat8], sigBytes : [Nat8]) : Bool {
    switch (parseShakePublicKey(pkBytes), parseSignature(sigBytes)) {
      case (?pk, ?sig) verifyCompactShake(pk, msg, sig);
      case _ false;
    };
  };

  public func targetNibbles(msg : [Nat8], salt : [Nat8]) : [Nat8] {
    if (salt.size() != saltBytes) {
      return [];
    };
    let digestLen = 32 + m / 2;
    let msgHash = Keccak.shake256(msg, digestLen);
    let tHash = Keccak.shake256(Array.concat<Nat8>(msgHash, salt), m / 2);
    Array.tabulate<Nat8>(m, func(i : Nat) : Nat8 { Gf16.getPacked(tHash, i) });
  };

  public func verifyExpanded(epk : ExpandedPublicKey, msg : [Nat8], sig : Signature) : Bool {
    if (not validExpandedPublicKey(epk) or sig.s.size() != signatureVectorBytes or sig.salt.size() != saltBytes) {
      return false;
    };

    let target = targetNibbles(msg, sig.salt);
    if (target.size() != m) {
      return false;
    };

    let sigs = Array.tabulate<[Nat8]>(k, func(ki : Nat) : [Nat8] {
      Array.tabulate<Nat8>(n, func(ni : Nat) : Nat8 {
        Gf16.getPacked(sig.s, ki * n + ni);
      });
    });

    let extY = VarArray.repeat<Nat8>(0, extRows);

    var ell : Nat = 0;
    var ii : Nat = 0;
    while (ii < k) {
      var jjRev : Nat = 0;
      while (jjRev < k - ii) {
        let jj = k - 1 - jjRev;
        if (jj >= ii) {
          var eq : Nat = 0;
          while (eq < m) {
            let u = evalPair(epk, eq, sigs[ii], sigs[jj], ii == jj);
            let row = eq + ell;
            if (row < extRows) {
              extY[row] ^= u;
            };
            eq += 1;
          };
          ell += 1;
        };
        jjRev += 1;
      };
      ii += 1;
    };

    var extRow : Nat = m;
    while (extRow < extRows) {
      let offset = extRow - m;
      if (extY[extRow] != 0) {
        if (offset < m) {
          extY[offset] ^= Gf16.mul(8, extY[extRow]);
        };
        if (offset + 2 < m) {
          extY[offset + 2] ^= Gf16.mul(2, extY[extRow]);
        };
        if (offset + 3 < m) {
          extY[offset + 3] ^= Gf16.mul(8, extY[extRow]);
        };
      };
      extRow += 1;
    };

    var ci : Nat = 0;
    while (ci < m) {
      if ((extY[ci] & 0x0F) != (target[ci] & 0x0F)) {
        return false;
      };
      ci += 1;
    };
    true;
  };

  public func validExpandedPublicKey(epk : ExpandedPublicKey) : Bool {
    epk.p1.size() == p1Bytes and epk.p2.size() == p2Bytes and epk.p3.size() == p3Bytes;
  };

  public func compatibilityNote() : Text {
    "MAYO-2 SHAKE verifier: 186-byte signatures and 4928-byte SHAKE compact public keys. Thebes pq-mayo consensus uses 4912-byte AES-CTR compact keys; that layout still requires the Rust oracle gate before live-QC use.";
  };

  func expandSHAKE(seed : [Nat8], tag : Nat8, numBytes : Nat) : [Nat8] {
    Keccak.shake256(Array.concat<Nat8>(seed, [tag]), numBytes);
  };

  func evalPair(epk : ExpandedPublicKey, eq : Nat, si : [Nat8], sj : [Nat8], same : Bool) : Nat8 {
    var acc : Nat8 = 0;

    let p1Base = eq * triV;
    var a : Nat = 0;
    while (a < v) {
      var b : Nat = a;
      while (b < v) {
        let coef = Gf16.getPacked(epk.p1, p1Base + a * v - (a * (a + 1)) / 2 + b);
        if (coef != 0) {
          let prod1 = Gf16.mul(si[a], sj[b]);
          if (prod1 != 0) {
            acc ^= Gf16.mul(coef, prod1);
          };
          if (not same) {
            let prod2 = Gf16.mul(sj[a], si[b]);
            if (prod2 != 0) {
              acc ^= Gf16.mul(coef, prod2);
            };
          };
        };
        b += 1;
      };
      a += 1;
    };

    let p2Base = eq * v * o;
    a := 0;
    while (a < v) {
      var b : Nat = 0;
      while (b < o) {
        let coef = Gf16.getPacked(epk.p2, p2Base + a * o + b);
        if (coef != 0) {
          let prod1 = Gf16.mul(si[a], sj[v + b]);
          if (prod1 != 0) {
            acc ^= Gf16.mul(coef, prod1);
          };
          if (not same) {
            let prod2 = Gf16.mul(sj[a], si[v + b]);
            if (prod2 != 0) {
              acc ^= Gf16.mul(coef, prod2);
            };
          };
        };
        b += 1;
      };
      a += 1;
    };

    let p3Base = eq * triO;
    a := 0;
    while (a < o) {
      var b : Nat = a;
      while (b < o) {
        let triIdx = a * o - (a * (a + 1)) / 2 + b;
        let coef = Gf16.getPacked(epk.p3, p3Base + triIdx);
        if (coef != 0) {
          let prod1 = Gf16.mul(si[v + a], sj[v + b]);
          if (prod1 != 0) {
            acc ^= Gf16.mul(coef, prod1);
          };
          if (not same) {
            let prod2 = Gf16.mul(sj[v + a], si[v + b]);
            if (prod2 != 0) {
              acc ^= Gf16.mul(coef, prod2);
            };
          };
        };
        b += 1;
      };
      a += 1;
    };

    acc & 0x0F;
  };
};
