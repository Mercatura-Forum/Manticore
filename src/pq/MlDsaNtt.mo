// NTT; exact match to CRYSTALS-Dilithium reference implementation.
// Uses Montgomery arithmetic with signed 32-bit representation.
// q = 8380417, MONT = 2^32 mod q = 4193792 (reference uses -4186625 = q - 4193792)
//
// A: this has to match the reference byte-for-byte or the KAT vectors won't pass.
//    every single zeta, every reduction, every butterfly; exact match to
//    pq-crystals/dilithium/ref/ntt.c

import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Int "mo:core/Int";
import Int32 "mo:core/Int32";
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";

module {

  public let Q : Int32 = 8380417;
  public let N : Nat = 256;
  let QINV : Int32 = 58728449; // q^-1 mod 2^32

  // zetas from reference (Montgomery domain, signed int32)
  let ZETAS : [Int32] = [
         0,    25847, -2608894,  -518909,   237124,  -777960,  -876248,   466468,
   1826347,  2353451,  -359251, -2091905,  3119733, -2884855,  3111497,  2680103,
   2725464,  1024112, -1079900,  3585928,  -549488, -1119584,  2619752, -2108549,
  -2118186, -3859737, -1399561, -3277672,  1757237,   -19422,  4010497,   280005,
   2706023,    95776,  3077325,  3530437, -1661693, -3592148, -2537516,  3915439,
  -3861115, -3043716,  3574422, -2867647,  3539968,  -300467,  2348700,  -539299,
  -1699267, -1643818,  3505694, -3821735,  3507263, -2140649, -1600420,  3699596,
    811944,   531354,   954230,  3881043,  3900724, -2556880,  2071892, -2797779,
  -3930395, -1528703, -3677745, -3041255, -1452451,  3475950,  2176455, -1585221,
  -1257611,  1939314, -4083598, -1000202, -3190144, -3157330, -3632928,   126922,
   3412210,  -983419,  2147896,  2715295, -2967645, -3693493,  -411027, -2477047,
   -671102, -1228525,   -22981, -1308169,  -381987,  1349076,  1852771, -1430430,
  -3343383,   264944,   508951,  3097992,    44288, -1100098,   904516,  3958618,
  -3724342,    -8578,  1653064, -3249728,  2389356,  -210977,   759969, -1316856,
    189548, -3553272,  3159746, -1851402, -2409325,  -177440,  1315589,  1341330,
   1285669, -1584928,  -812732, -1439742, -3019102, -3881060, -3628969,  3839961,
   2091667,  3407706,  2316500,  3817976, -3342478,  2244091, -2446433, -3562462,
    266997,  2434439, -1235728,  3513181, -3520352, -3759364, -1197226, -3193378,
    900702,  1859098,   909542,   819034,   495491, -1613174,   -43260,  -522500,
   -655327, -3122442,  2031748,  3207046, -3556995,  -525098,  -768622, -3595838,
    342297,   286988, -2437823,  4108315,  3437287, -3342277,  1735879,   203044,
   2842341,  2691481, -2590150,  1265009,  4055324,  1247620,  2486353,  1595974,
  -3767016,  1250494,  2635921, -3548272, -2994039,  1869119,  1903435, -1050970,
  -1333058,  1237275, -3318210, -1430225,  -451100,  1312455,  3306115, -1962642,
  -1279661,  1917081, -2546312, -1374803,  1500165,   777191,  2235880,  3406031,
   -542412, -2831860, -1671176, -1846953, -2584293, -3724270,   594136, -3776993,
  -2013608,  2432395,  2454455,  -164721,  1957272,  3369112,   185531, -1207385,
  -3183426,   162844,  1616392,  3014001,   810149,  1652634, -3694233, -1799107,
  -3038916,  3523897,  3866901,   269760,  2213111,  -975884,  1717735,   472078,
   -426683,  1723600, -1803090,  1910376, -1667432, -1104333,  -260646, -3833893,
  -2939036, -2235985,  -420899, -2286327,   183443,  -976891,  1612842, -3545687,
   -554416,  3919660,   -48306, -1362209,  3937738,  1400424,  -846154,  1976782,
  ];

  // Montgomery reduction using Nat32 wrapping arithmetic (much faster)
  // Input: a is at most ~2^46 (product of two values < q^2)
  func montgomeryReduce(a : Int) : Int32 {
    // t = (int32)(a) * QINV; wrapping multiplication, take low 32 bits
    // Use Nat32 wrapping for the low bits
    let aLow32 = Nat32.fromNat(Int.abs(if (a >= 0) a % 4294967296 else (4294967296 - (Int.abs(a) % 4294967296)) % 4294967296));
    let t32 = aLow32 *% Nat32.fromNat(Int.abs(Int32.toInt(QINV)));
    // sign-extend t32 to Int
    var t : Int = Nat32.toNat(t32);
    if (t >= 2147483648) t -= 4294967296;
    // r = (a - t * Q) / 2^32
    let r = (a - t * Int32.toInt(Q)) / 4294967296;
    Int32.fromInt(r);
  };

  /// Forward NTT (Cooley-Tukey); exact reference match
  public func ntt(a : [var Int32]) {
    var len : Nat = 128;
    var k : Nat = 1;
    while (len >= 1) {
      var start : Nat = 0;
      while (start < N) {
        let zeta = ZETAS[k];
        k += 1;
        var j : Nat = start;
        while (j < start + len) {
          let t = montgomeryReduce(Int32.toInt(zeta) * Int32.toInt(a[j + len]));
          a[j + len] := a[j] -% t;
          a[j] := a[j] +% t;
          j += 1;
        };
        start += 2 * len;
      };
      len /= 2;
    };
  };

  /// Inverse NTT (Gentleman-Sande); exact reference match
  public func invNtt(a : [var Int32]) {
    let f : Int32 = 41978; // mont^2 / 256
    var len : Nat = 1;
    var k : Nat = 255;
    while (len <= 128) {
      var start : Nat = 0;
      while (start < N) {
        let zeta = Int32.neg(ZETAS[k]); // negated
        k -= 1;
        var j : Nat = start;
        while (j < start + len) {
          let t = a[j];
          a[j] := t +% a[j + len];
          a[j + len] := t -% a[j + len];
          a[j + len] := montgomeryReduce(Int32.toInt(zeta) * Int32.toInt(a[j + len]));
          j += 1;
        };
        start += 2 * len;
      };
      len *= 2;
    };
    // multiply by f = mont^2/256
    var i : Nat = 0;
    while (i < N) {
      a[i] := montgomeryReduce(Int32.toInt(f) * Int32.toInt(a[i]));
      i += 1;
    };
  };

  /// Pointwise Montgomery multiplication
  public func pointwiseMul(a : [Int32], b : [Int32]) : [var Int32] {
    let c = VarArray.repeat<Int32>(0, N);
    var i : Nat = 0;
    while (i < N) {
      c[i] := montgomeryReduce(Int32.toInt(a[i]) * Int32.toInt(b[i]));
      i += 1;
    };
    c;
  };

  /// Partial reduce: a → a mod±q (approximately [-q, q])
  public func reduce32(a : Int32) : Int32 {
    let t = (a +% (1 << 22)) >> 23;
    a -% (t *% Q);
  };

  /// Reduce all coefficients of a polynomial
  public func polyReduce(p : [var Int32]) {
    var i : Nat = 0;
    while (i < N) { p[i] := reduce32(p[i]); i += 1 };
  };

  /// Fully reduce to [0, q)
  public func freeze(a : Int32) : Int32 {
    var v = Int32.toInt(a) % Int32.toInt(Q);
    if (v < 0) v += Int32.toInt(Q);
    Int32.fromInt(v);
  };

  /// Remove Montgomery factor: a_mont → a_standard = a_mont * R^-1 mod q
  public func fromMontgomery(a : Int32) : Int32 {
    montgomeryReduce(Int32.toInt(a));
  };

  /// Convert full polynomial from Montgomery to standard domain
  public func polyReduceMont(p : [var Int32]) {
    var i : Nat = 0;
    while (i < N) {
      p[i] := fromMontgomery(p[i]);
      i += 1;
    };
  };

  /// Create zero polynomial (signed)
  public func zeroPoly() : [var Int32] {
    VarArray.repeat<Int32>(0, N);
  };

  /// Add two polynomials
  public func polyAdd(a : [Int32], b : [Int32]) : [var Int32] {
    let c = VarArray.repeat<Int32>(0, N);
    var i : Nat = 0;
    while (i < N) { c[i] := a[i] +% b[i]; i += 1 };
    c;
  };

  /// Subtract
  public func polySub(a : [Int32], b : [Int32]) : [var Int32] {
    let c = VarArray.repeat<Int32>(0, N);
    var i : Nat = 0;
    while (i < N) { c[i] := a[i] -% b[i]; i += 1 };
    c;
  };

  /// Check infinity norm: max |coeff| < bound
  public func checkNorm(poly : [Int32], bound : Int32) : Bool {
    var i : Nat = 0;
    while (i < N) {
      var v = freeze(poly[i]);
      // center: if v > q/2 then v = q - v
      if (v > Q / 2) v := Q -% v;
      if (v >= bound) return false;
      i += 1;
    };
    true;
  };
};
