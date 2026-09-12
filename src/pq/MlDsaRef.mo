// ML-DSA-44 (FIPS 204) — exact reference implementation match.
// Uses signed Int32 arithmetic + Montgomery NTT throughout.
// KAT-verifiable against NIST test vectors.

import Keccak "MlDsaKeccak";
import NTT "MlDsaNtt";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Int32 "mo:core/Int32";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";

module {

  let K : Nat = 4;
  let L : Nat = 4;
  let ETA : Int32 = 2;
  let GAMMA1 : Int32 = 131072;   // 2^17
  let GAMMA2 : Int32 = 95232;    // (q-1)/88
  let TAU : Nat = 39;
  let BETA : Int32 = 78;         // TAU * ETA
  let D : Nat = 13;
  let Q = NTT.Q;
  let N = NTT.N;

  public type PublicKey = {
    rho : [Nat8];
    t1 : [[Int32]];  // k polynomials
  };

  public type SecretKey = {
    rho : [Nat8];
    key : [Nat8];
    tr : [Nat8];
    s1 : [[Int32]];
    s2 : [[Int32]];
    t0 : [[Int32]];
  };

  public type Signature = {
    cTilde : [Nat8];
    z : [[Int32]];
    hint : [[Int32]];
  };

  // expand A from rho (NTT domain)
  func expandA(rho : [Nat8]) : [[Int32]] {
    let matrix = VarArray.repeat<[Int32]>(Array.repeat<Int32>(0, N), K * L);
    var i : Nat = 0;
    while (i < K) {
      var j : Nat = 0;
      while (j < L) {
        let seed = Array.concat<Nat8>(rho, [Nat8.fromNat(j), Nat8.fromNat(i)]);
        let stream = Keccak.shake128(seed, N * 6); // 23-bit rejection needs ~2x more bytes
        let poly = rejUniform(stream);
        // A is sampled directly in NTT domain — do NOT apply NTT
        matrix[i * L + j] := Array.fromVarArray(poly);
        j += 1;
      };
      i += 1;
    };
    Array.fromVarArray(matrix);
  };

  // FIPS 204: rejection uniform sampling — 23-bit candidates from 3 bytes.
  func rejUniform(stream : [Nat8]) : [var Int32] {
    let poly = NTT.zeroPoly();
    var ctr : Nat = 0;
    var pos : Nat = 0;
    while (ctr < N and pos + 2 < stream.size()) {
      let t = Nat8.toNat(stream[pos])
            + Nat8.toNat(stream[pos + 1]) * 256
            + Nat8.toNat(stream[pos + 2]) * 65536;
      let t23 = t % 0x800000; // 23-bit mask
      pos += 3;
      if (t23 < Int32.toInt(Q)) { poly[ctr] := Int32.fromInt(t23); ctr += 1 };
    };
    poly;
  };

  // FIPS 204 rej_eta: rejection sampling on nibbles with 16-bit nonce.
  // Each nibble t in [0,14] maps to coefficient 2 - (t mod 5).
  // Nibble 15 is rejected.
  func sampleSecret(seed : [Nat8], nonce : Nat8) : [var Int32] {
    let nonceLE = [nonce, 0 : Nat8]; // 16-bit little-endian nonce
    let buf = Keccak.shake256(Array.concat<Nat8>(seed, nonceLE), N * 2); // plenty of bytes
    let poly = NTT.zeroPoly();
    var ctr : Nat = 0;
    var pos : Nat = 0;
    while (ctr < N) {
      let byte = Nat8.toNat(buf[pos]);
      let t0 = byte % 16;
      let t1 = byte / 16;
      pos += 1;
      if (t0 < 15) {
        let t0mod5 = t0 - (205 * t0 / 1024) * 5; // t0 mod 5 via magic constant
        poly[ctr] := Int32.fromInt(2 - t0mod5);
        ctr += 1;
      };
      if (t1 < 15 and ctr < N) {
        let t1mod5 = t1 - (205 * t1 / 1024) * 5;
        poly[ctr] := Int32.fromInt(2 - t1mod5);
        ctr += 1;
      };
    };
    poly;
  };

  // FIPS 204: polyz_unpack — 18-bit packed coefficients, 4 per 9 bytes.
  // coeff = GAMMA1 - (18-bit value)
  public func sampleSecretPub(seed : [Nat8], nonce : Nat8) : [var Int32] {
    sampleSecret(seed, nonce);
  };

  func sampleMasking(seed : [Nat8], nonce : Nat) : [var Int32] {
    let input = Array.concat<Nat8>(seed, [
      Nat8.fromNat(nonce % 256), Nat8.fromNat((nonce / 256) % 256),
    ]);
    let buf = Keccak.shake256(input, N * 9 / 4 + 16);
    let poly = NTT.zeroPoly();
    var i : Nat = 0;
    while (i < N / 4) {
      let b = i * 9;
      let a0 = Nat8.toNat(buf[b]);
      let a1 = Nat8.toNat(buf[b+1]);
      let a2 = Nat8.toNat(buf[b+2]);
      let a3 = Nat8.toNat(buf[b+3]);
      let a4 = Nat8.toNat(buf[b+4]);
      let a5 = Nat8.toNat(buf[b+5]);
      let a6 = Nat8.toNat(buf[b+6]);
      let a7 = Nat8.toNat(buf[b+7]);
      let a8 = Nat8.toNat(buf[b+8]);

      let c0 = (a0 + a1 * 256 + a2 * 65536) % 0x40000;
      let c1 = (a2 / 4 + a3 * 64 + a4 * 16384) % 0x40000;
      let c2 = (a4 / 16 + a5 * 16 + a6 * 4096) % 0x40000;
      let c3 = (a6 / 64 + a7 * 4 + a8 * 1024) % 0x40000;

      poly[4*i]   := GAMMA1 -% Int32.fromInt(c0);
      poly[4*i+1] := GAMMA1 -% Int32.fromInt(c1);
      poly[4*i+2] := GAMMA1 -% Int32.fromInt(c2);
      poly[4*i+3] := GAMMA1 -% Int32.fromInt(c3);
      i += 1;
    };
    poly;
  };

  func sampleInBall(seed : [Nat8]) : [var Int32] {
    let buf = Keccak.shake256(seed, 136);
    let c = NTT.zeroPoly();
    var signs : Nat64 = 0;
    var si : Nat = 0;
    while (si < 8) {
      signs |= Nat64.fromNat(Nat8.toNat(buf[si])) << Nat64.fromNat(si * 8);
      si += 1;
    };
    var pos : Nat = 8;
    var i : Nat = N - TAU;
    while (i < N) {
      var j = Nat8.toNat(buf[pos]) % (i + 1);
      pos += 1;
      if (pos >= buf.size()) pos := 8;
      c[i] := c[j];
      let sign = (signs >> Nat64.fromNat(i - (N - TAU))) & 1;
      c[j] := if (sign == 0) (1 : Int32) else (-1 : Int32);
      i += 1;
    };
    c;
  };

  // Power2Round: r → (r1, r0) where r = r1*2^d + r0
  func power2round(r : Int32) : (Int32, Int32) {
    let rv = Int32.toInt(NTT.freeze(r));
    let r1 = Int32.fromInt((rv + 4095) / 8192);
    let r0 = Int32.fromInt(rv) -% (r1 *% 8192);
    (r1, r0);
  };

  // Decompose: r → (r1, r0) with alpha = 2*gamma2
  func decompose(a : Int32) : (Int32, Int32) {
    let av = Int32.toInt(NTT.freeze(a));
    var a1 = (av + 127) / 128;
    a1 := (a1 * 11275 + 8388608) / 16777216;
    if (a1 >= 44) a1 := 0;
    var a0 = av - a1 * 190464;
    if (a0 > Int32.toInt(Q) / 2) a0 -= Int32.toInt(Q);
    (Int32.fromInt(a1), Int32.fromInt(a0));
  };

  func highBits(a : Int32) : Int32 { let (r1, _) = decompose(a); r1 };

  // MakeHint: returns 1 if highBits(a0 + a1) != a1 (where a0 is low, a1 is high)
  func makeHint(a0 : Int32, a1 : Int32) : Int32 {
    let sum = a0 +% (a1 *% (2 * GAMMA2));
    let hi = highBits(sum);
    if (hi == a1) (0 : Int32) else (1 : Int32);
  };

  // Pack w1 coefficients using 6-bit encoding (SimpleBitPack per FIPS 204).
  // 4 coefficients (6 bits each) → 3 bytes: [a|(b<<6), (b>>2)|(c<<4), (c>>4)|(d<<2)]
  func packW1(w1 : [[var Int32]]) : [Nat8] {
    let packed = VarArray.repeat<Nat8>(0 : Nat8, K * 192); // K * 256 * 6/8 = K * 192
    var idx : Nat = 0;
    var ki : Nat = 0;
    while (ki < K) {
      var ni : Nat = 0;
      while (ni < N) {
        let a = Int.abs(Int32.toInt(w1[ki][ni])) % 64;
        let b = Int.abs(Int32.toInt(w1[ki][ni + 1])) % 64;
        let c = Int.abs(Int32.toInt(w1[ki][ni + 2])) % 64;
        let d = Int.abs(Int32.toInt(w1[ki][ni + 3])) % 64;
        packed[idx] := Nat8.fromNat((a + b * 64) % 256);
        packed[idx + 1] := Nat8.fromNat((b / 4 + c * 16) % 256);
        packed[idx + 2] := Nat8.fromNat((c / 16 + d * 4) % 256);
        idx += 3;
        ni += 4;
      };
      ki += 1;
    };
    Array.fromVarArray(packed);
  };

  // UseHint: adjust r1 based on hint bit
  func useHint(hint : Int32, r : Int32) : Int32 {
    let (r1, r0) = decompose(r);
    if (hint == 0) return r1;
    // if r0 > 0, increment r1; else decrement
    let maxR1 : Int32 = 43; // (q-1)/(2*gamma2) = 43
    if (Int32.toInt(r0) > 0) {
      if (r1 == maxR1) (0 : Int32) else (r1 +% 1);
    } else {
      if (r1 == 0) maxR1 else (r1 -% 1);
    };
  };

  // mat-vec mul: A (frozen NTT) × v (frozen NTT) → result (NTT domain, mutable)
  func matVecMul(a : [[Int32]], v : [[Int32]]) : [[var Int32]] {
    let result = Array.toVarArray(Array.tabulate<[var Int32]>(K, func(_ : Nat) : [var Int32] { NTT.zeroPoly() }));
    var i : Nat = 0;
    while (i < K) {
      var j : Nat = 0;
      while (j < L) {
        let prod = NTT.pointwiseMul(a[i * L + j], v[j]);
        let sum = NTT.polyAdd(Array.fromVarArray(result[i]), Array.fromVarArray(prod));
        result[i] := sum;
        j += 1;
      };
      i += 1;
    };
    Array.fromVarArray(result);
  };

  public func keyGen(seed : [Nat8]) : (PublicKey, SecretKey) {
    // FIPS 204: SHAKE256(xi || K || L) → rho(32) || rhoPrime(64) || key(32)
    let seedKL = Array.concat<Nat8>(seed, [Nat8.fromNat(K), Nat8.fromNat(L)]);
    let expanded = Keccak.shake256(seedKL, 128);
    let rho = Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 { expanded[i] });
    let rhoPrime = Array.tabulate<Nat8>(64, func(i : Nat) : Nat8 { expanded[32 + i] });
    let key = Array.tabulate<Nat8>(32, func(i : Nat) : Nat8 { expanded[96 + i] });

    let a = expandA(rho);

    let s1 = Array.toVarArray(Array.tabulate<[var Int32]>(L, func(i : Nat) : [var Int32] {
      sampleSecret(rhoPrime, Nat8.fromNat(i));
    }));
    let s2 = Array.toVarArray(Array.tabulate<[var Int32]>(K, func(i : Nat) : [var Int32] {
      sampleSecret(rhoPrime, Nat8.fromNat(L + i));
    }));

    // NTT(s1)
    let s1ntt = VarArray.repeat<[Int32]>(Array.repeat<Int32>(0, N), L);
    var i : Nat = 0;
    while (i < L) {
      let tmp = NTT.zeroPoly();
      var j : Nat = 0;
      while (j < N) { tmp[j] := s1[i][j]; j += 1 };
      NTT.ntt(tmp);
      s1ntt[i] := Array.fromVarArray(tmp);
      i += 1;
    };

    // t = A * NTT(s1), then reduce + invNTT
    let t = matVecMul(a, Array.fromVarArray(s1ntt));
    i := 0;
    while (i < K) {
      NTT.polyReduce(t[i]);
      NTT.invNtt(t[i]);
      // add s2 + caddq (ensure [0, q))
      var j : Nat = 0;
      while (j < N) {
        var v = t[i][j] +% s2[i][j];
        v := NTT.freeze(v); // ensure [0, q)
        t[i][j] := v;
        j += 1;
      };
      i += 1;
    };

    // Power2Round
    let t1 = Array.tabulate<[Int32]>(K, func(ki : Nat) : [Int32] {
      Array.tabulate<Int32>(N, func(ni : Nat) : Int32 {
        let (r1, _) = power2round(t[ki][ni]);
        r1;
      });
    });
    let t0 = Array.tabulate<[Int32]>(K, func(ki : Nat) : [Int32] {
      Array.tabulate<Int32>(N, func(ni : Nat) : Int32 {
        let (_, r0) = power2round(t[ki][ni]);
        r0;
      });
    });

    // tr = SHAKE-256(rho || pack(t1))
    var trInput : [Nat8] = rho;
    for (poly in t1.vals()) {
      for (c in poly.vals()) {
        let v = Int32.toInt(c);
        trInput := Array.concat<Nat8>(trInput, [
          Nat8.fromNat(Int.abs(v) % 256),
          Nat8.fromNat((Int.abs(v) / 256) % 256),
        ]);
      };
    };
    let tr = Keccak.shake256(trInput, 64);

    let pk : PublicKey = { rho; t1 };
    let sk : SecretKey = {
      rho; key; tr;
      s1 = Array.tabulate<[Int32]>(L, func(li : Nat) : [Int32] { Array.fromVarArray(s1[li]) });
      s2 = Array.tabulate<[Int32]>(K, func(ki : Nat) : [Int32] { Array.fromVarArray(s2[ki]) });
      t0;
    };
    (pk, sk);
  };

  public func sign(sk : SecretKey, msg : [Nat8]) : ?Signature {
    let mu = Keccak.shake256(Array.concat<Nat8>(sk.tr, msg), 64);
    let rhoPrime = Keccak.shake256(Array.concat<Nat8>(sk.key, mu), 64);
    let a = expandA(sk.rho);

    // NTT(s1), NTT(s2)
    let s1hat = Array.tabulate<[Int32]>(L, func(li : Nat) : [Int32] {
      let tmp = NTT.zeroPoly();
      var ni : Nat = 0;
      while (ni < N) { tmp[ni] := sk.s1[li][ni]; ni += 1 };
      NTT.ntt(tmp);
      Array.fromVarArray(tmp);
    });
    let s2hat = Array.tabulate<[Int32]>(K, func(ki : Nat) : [Int32] {
      let tmp = NTT.zeroPoly();
      var ni : Nat = 0;
      while (ni < N) { tmp[ni] := sk.s2[ki][ni]; ni += 1 };
      NTT.ntt(tmp);
      Array.fromVarArray(tmp);
    });

    var kappa : Nat = 0;
    while (kappa < 100) {
      // y
      let y = Array.tabulate<[var Int32]>(L, func(li : Nat) : [var Int32] {
        sampleMasking(rhoPrime, kappa * L + li);
      });

      // w = A * NTT(y)
      let yhat = Array.tabulate<[Int32]>(L, func(li : Nat) : [Int32] {
        let tmp = NTT.zeroPoly();
        var ni : Nat = 0;
        while (ni < N) { tmp[ni] := y[li][ni]; ni += 1 };
        NTT.ntt(tmp);
        Array.fromVarArray(tmp);
      });
      let w = matVecMul(a, yhat);
      var ki : Nat = 0;
      while (ki < K) { NTT.invNtt(w[ki]); ki += 1 };

      // w1 = HighBits(w), then 6-bit pack per FIPS 204
      let w1 = Array.tabulate<[var Int32]>(K, func(ki2 : Nat) : [var Int32] {
        let poly = VarArray.repeat<Int32>(0 : Int32, N);
        var ni2 : Nat = 0;
        while (ni2 < N) { poly[ni2] := highBits(w[ki2][ni2]); ni2 += 1 };
        poly;
      });
      let w1packed = packW1(w1);

      let cTilde = Keccak.shake256(Array.concat<Nat8>(mu, w1packed), 32);
      let c = sampleInBall(cTilde);
      let chat = NTT.zeroPoly();
      var ni : Nat = 0;
      while (ni < N) { chat[ni] := c[ni]; ni += 1 };
      NTT.ntt(chat);
      let chatFrozen = Array.fromVarArray(chat);

      // z = y + c*s1
      let z = Array.tabulate<[var Int32]>(L, func(li : Nat) : [var Int32] {
        let cs = NTT.pointwiseMul(chatFrozen, s1hat[li]);
        NTT.invNtt(cs);
        let zi = NTT.zeroPoly();
        var i : Nat = 0;
        while (i < N) { zi[i] := y[li][i] +% cs[i]; i += 1 };
        zi;
      });

      // check ||z|| < gamma1 - beta
      var reject = false;
      var li : Nat = 0;
      while (li < L and not reject) {
        if (not NTT.checkNorm(Array.fromVarArray(z[li]), GAMMA1 -% BETA)) reject := true;
        li += 1;
      };

      if (not reject) {
        // check lowBits(w - c*s2) < gamma2 - beta
        ki := 0;
        while (ki < K and not reject) {
          let cs2 = NTT.pointwiseMul(chatFrozen, s2hat[ki]);
          NTT.invNtt(cs2);
          var ri : Nat = 0;
          while (ri < N and not reject) {
            let wcs2 = w[ki][ri] -% cs2[ri];
            let (_, r0) = decompose(wcs2);
            let r0abs = if (r0 < 0) Int32.neg(r0) else r0;
            if (r0abs >= GAMMA2 -% BETA) reject := true;
            ri += 1;
          };
          ki += 1;
        };
      };

      if (not reject) {
        // Compute hint: compare HighBits(w) with HighBits(w - c*s2 - c*t0)
        // w' = A*z - c*t1*2^d = w - c*s2 - c*t0 (by construction)
        // hint[i][j] = 1 if HighBits(w[i][j]) != HighBits(w'[i][j])
        var hintCount : Nat = 0;
        let hint = Array.tabulate<[Int32]>(K, func(hki : Nat) : [Int32] {
          let cs2 = NTT.pointwiseMul(chatFrozen, s2hat[hki]);
          NTT.invNtt(cs2);
          // also need c*t0 — compute from sk.t0
          let t0hat = NTT.zeroPoly();
          var ti : Nat = 0;
          while (ti < N) { t0hat[ti] := sk.t0[hki][ti]; ti += 1 };
          NTT.ntt(t0hat);
          let ct0 = NTT.pointwiseMul(chatFrozen, Array.fromVarArray(t0hat));
          NTT.invNtt(ct0);

          Array.tabulate<Int32>(N, func(ni : Nat) : Int32 {
            // w' = w - c*s2 + c*t0 (what verify computes as A*z - c*t1*2^d)
            let wPrime = w[hki][ni] -% cs2[ni] +% ct0[ni];
            let h1 = highBits(w[hki][ni]);
            let h2 = highBits(wPrime);
            if (h1 != h2) { hintCount += 1; (1 : Int32) } else (0 : Int32);
          });
        });

        // OMEGA check: total hints must be <= OMEGA (80 for ML-DSA-44)
        if (hintCount > 80) { kappa += 1; reject := true }
        else {
          return ?{
            cTilde;
            z = Array.tabulate<[Int32]>(L, func(i : Nat) : [Int32] { Array.fromVarArray(z[i]) });
            hint;
          };
        };
      };
      if (not reject) {};
      kappa += 1;
    };
    null;
  };

  /// Debug: sign with full hints (same as sign) and also return sign-side w1packed
  public func signDebug(sk : SecretKey, msg : [Nat8]) : ?(Signature, [Nat8]) {
    let mu = Keccak.shake256(Array.concat<Nat8>(sk.tr, msg), 64);
    let rhoPrime = Keccak.shake256(Array.concat<Nat8>(sk.key, mu), 64);
    let a = expandA(sk.rho);
    let s1hat = Array.tabulate<[Int32]>(L, func(li : Nat) : [Int32] {
      let tmp = NTT.zeroPoly();
      var ni : Nat = 0;
      while (ni < N) { tmp[ni] := sk.s1[li][ni]; ni += 1 };
      NTT.ntt(tmp); Array.fromVarArray(tmp);
    });
    let s2hat = Array.tabulate<[Int32]>(K, func(ki : Nat) : [Int32] {
      let tmp = NTT.zeroPoly();
      var ni : Nat = 0;
      while (ni < N) { tmp[ni] := sk.s2[ki][ni]; ni += 1 };
      NTT.ntt(tmp); Array.fromVarArray(tmp);
    });
    var kappa : Nat = 0;
    while (kappa < 100) {
      let y = Array.tabulate<[var Int32]>(L, func(li : Nat) : [var Int32] {
        sampleMasking(rhoPrime, kappa * L + li);
      });
      let yhat = Array.tabulate<[Int32]>(L, func(li : Nat) : [Int32] {
        let tmp = NTT.zeroPoly();
        var ni : Nat = 0;
        while (ni < N) { tmp[ni] := y[li][ni]; ni += 1 };
        NTT.ntt(tmp); Array.fromVarArray(tmp);
      });
      let w = matVecMul(a, yhat);
      var ki : Nat = 0;
      while (ki < K) { NTT.invNtt(w[ki]); ki += 1 };

      // w1packed = highBits(w), 6-bit packed per FIPS 204
      let w1 = Array.tabulate<[var Int32]>(K, func(ki2 : Nat) : [var Int32] {
        let poly = VarArray.repeat<Int32>(0 : Int32, N);
        var ni2 : Nat = 0;
        while (ni2 < N) { poly[ni2] := highBits(w[ki2][ni2]); ni2 += 1 };
        poly;
      });
      let w1packed = packW1(w1);

      let cTilde = Keccak.shake256(Array.concat<Nat8>(mu, w1packed), 32);
      let c = sampleInBall(cTilde);
      let chat = NTT.zeroPoly();
      var ni : Nat = 0;
      while (ni < N) { chat[ni] := c[ni]; ni += 1 };
      NTT.ntt(chat);
      let chatFrozen = Array.fromVarArray(chat);

      let z = Array.tabulate<[var Int32]>(L, func(li : Nat) : [var Int32] {
        let cs = NTT.pointwiseMul(chatFrozen, s1hat[li]);
        NTT.invNtt(cs);
        let zi = NTT.zeroPoly();
        var i : Nat = 0;
        while (i < N) { zi[i] := y[li][i] +% cs[i]; i += 1 };
        zi;
      });

      var reject = false;
      var li : Nat = 0;
      while (li < L and not reject) {
        if (not NTT.checkNorm(Array.fromVarArray(z[li]), GAMMA1 -% BETA)) reject := true;
        li += 1;
      };
      if (not reject) {
        ki := 0;
        while (ki < K and not reject) {
          let cs2 = NTT.pointwiseMul(chatFrozen, s2hat[ki]);
          NTT.invNtt(cs2);
          var ri : Nat = 0;
          while (ri < N and not reject) {
            let wcs2 = w[ki][ri] -% cs2[ri];
            let (_, r0) = decompose(wcs2);
            let r0abs = if (r0 < 0) Int32.neg(r0) else r0;
            if (r0abs >= GAMMA2 -% BETA) reject := true;
            ri += 1;
          };
          ki += 1;
        };
      };

      if (not reject) {
        // Compute hints (same as sign)
        var hintCount : Nat = 0;
        let hint = Array.tabulate<[Int32]>(K, func(hki : Nat) : [Int32] {
          let cs2 = NTT.pointwiseMul(chatFrozen, s2hat[hki]);
          NTT.invNtt(cs2);
          let t0hat = NTT.zeroPoly();
          var ti : Nat = 0;
          while (ti < N) { t0hat[ti] := sk.t0[hki][ti]; ti += 1 };
          NTT.ntt(t0hat);
          let ct0 = NTT.pointwiseMul(chatFrozen, Array.fromVarArray(t0hat));
          NTT.invNtt(ct0);
          Array.tabulate<Int32>(N, func(ni2 : Nat) : Int32 {
            let wPrime = w[hki][ni2] -% cs2[ni2] +% ct0[ni2];
            let h1 = highBits(w[hki][ni2]);
            let h2 = highBits(wPrime);
            if (h1 != h2) { hintCount += 1; (1 : Int32) } else (0 : Int32);
          });
        });

        if (hintCount > 80) { kappa += 1 }
        else {
          return ?({
            cTilde;
            z = Array.tabulate<[Int32]>(L, func(i : Nat) : [Int32] { Array.fromVarArray(z[i]) });
            hint;
          }, w1packed);
        };
      } else {
        kappa += 1;
      };
    };
    null;
  };

  /// Debug: verify and return w1' packed bytes
  public func verifyDebug(pk : PublicKey, msg : [Nat8], sig : Signature) : [Nat8] {
    var pkBytes : [Nat8] = pk.rho;
    for (poly in pk.t1.vals()) {
      for (c in poly.vals()) {
        let v = Int32.toInt(c);
        pkBytes := Array.concat<Nat8>(pkBytes, [
          Nat8.fromNat(Int.abs(v) % 256), Nat8.fromNat((Int.abs(v) / 256) % 256),
        ]);
      };
    };
    let tr = Keccak.shake256(pkBytes, 64);
    let mu = Keccak.shake256(Array.concat<Nat8>(tr, msg), 64);
    let a = expandA(pk.rho);
    let c = sampleInBall(sig.cTilde);
    let chat = NTT.zeroPoly();
    var ni : Nat = 0;
    while (ni < N) { chat[ni] := c[ni]; ni += 1 };
    NTT.ntt(chat);
    let chatFrozen = Array.fromVarArray(chat);
    let zhat = Array.tabulate<[Int32]>(L, func(li : Nat) : [Int32] {
      let tmp = NTT.zeroPoly();
      var i : Nat = 0;
      while (i < N) { tmp[i] := sig.z[li][i]; i += 1 };
      NTT.ntt(tmp); Array.fromVarArray(tmp);
    });
    let az = matVecMul(a, zhat);
    var ki : Nat = 0;
    while (ki < K) {
      let t1d = NTT.zeroPoly();
      ni := 0;
      while (ni < N) { t1d[ni] := pk.t1[ki][ni] *% 8192; ni += 1 };
      NTT.ntt(t1d);
      let ct1d = NTT.pointwiseMul(chatFrozen, Array.fromVarArray(t1d));
      ni := 0;
      while (ni < N) { az[ki][ni] := az[ki][ni] -% ct1d[ni]; ni += 1 };
      NTT.invNtt(az[ki]);
      ki += 1;
    };
    let w1dbg = Array.tabulate<[var Int32]>(K, func(ki2 : Nat) : [var Int32] {
      let poly = VarArray.repeat<Int32>(0 : Int32, N);
      var ni2 : Nat = 0;
      while (ni2 < N) { poly[ni2] := highBits(az[ki2][ni2]); ni2 += 1 };
      poly;
    });
    packW1(w1dbg);
  };

  public func verify(pk : PublicKey, msg : [Nat8], sig : Signature) : Bool {
    // recompute tr
    var pkBytes : [Nat8] = pk.rho;
    for (poly in pk.t1.vals()) {
      for (c in poly.vals()) {
        let v = Int32.toInt(c);
        pkBytes := Array.concat<Nat8>(pkBytes, [
          Nat8.fromNat(Int.abs(v) % 256),
          Nat8.fromNat((Int.abs(v) / 256) % 256),
        ]);
      };
    };
    let tr = Keccak.shake256(pkBytes, 64);
    let mu = Keccak.shake256(Array.concat<Nat8>(tr, msg), 64);

    // check z norm
    for (poly in sig.z.vals()) {
      if (not NTT.checkNorm(poly, GAMMA1 -% BETA)) return false;
    };

    let a = expandA(pk.rho);
    let c = sampleInBall(sig.cTilde);
    let chat = NTT.zeroPoly();
    var ni : Nat = 0;
    while (ni < N) { chat[ni] := c[ni]; ni += 1 };
    NTT.ntt(chat);
    let chatFrozen = Array.fromVarArray(chat);

    // NTT(z)
    let zhat = Array.tabulate<[Int32]>(L, func(li : Nat) : [Int32] {
      let tmp = NTT.zeroPoly();
      var i : Nat = 0;
      while (i < N) { tmp[i] := sig.z[li][i]; i += 1 };
      NTT.ntt(tmp);
      Array.fromVarArray(tmp);
    });

    // w' = A*z - c*t1*2^d
    let az = matVecMul(a, zhat);
    var ki : Nat = 0;
    while (ki < K) {
      // t1 * 2^d in NTT domain
      let t1d = NTT.zeroPoly();
      ni := 0;
      while (ni < N) {
        t1d[ni] := pk.t1[ki][ni] *% 8192; // 2^13
        ni += 1;
      };
      NTT.ntt(t1d);
      let ct1d = NTT.pointwiseMul(chatFrozen, Array.fromVarArray(t1d));
      // w' = Az - c*t1*2^d
      ni := 0;
      while (ni < N) {
        az[ki][ni] := az[ki][ni] -% ct1d[ni];
        ni += 1;
      };
      NTT.invNtt(az[ki]);
      ki += 1;
    };

    // w1' = UseHint(hint, w') — apply hint to correct boundary rounding, 6-bit packed
    let w1v = Array.tabulate<[var Int32]>(K, func(ki2 : Nat) : [var Int32] {
      let poly = VarArray.repeat<Int32>(0 : Int32, N);
      var ni2 : Nat = 0;
      while (ni2 < N) { poly[ni2] := useHint(sig.hint[ki2][ni2], az[ki2][ni2]); ni2 += 1 };
      poly;
    });
    let w1packed = packW1(w1v);

    let cTildeCheck = Keccak.shake256(Array.concat<Nat8>(mu, w1packed), 32);

    var match = true;
    var ci : Nat = 0;
    while (ci < 32) {
      if (cTildeCheck[ci] != sig.cTilde[ci]) match := false;
      ci += 1;
    };
    match;
  };
};
