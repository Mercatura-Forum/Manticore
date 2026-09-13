/// ECDSA signature verification over NIST P-256 (secp256r1) with SHA-256, the algorithm
/// of a WebAuthn ES256 passkey (FIPS 186-5 §6.4.2; SEC 1 v2 §4.1.4). Verification only:
/// this contract never holds a private key.
///
/// Arithmetic is generic modular arithmetic on Nat. Points are in Jacobian coordinates
/// with the a = −3 doubling formula (Bernstein–Lange, dbl-2001-b) and the general
/// addition add-2007-bl; u1·G + u2·Q is computed in one pass by Shamir's trick. Every
/// input is validated before use: r and s in [1, n−1], the public key on the curve and
/// not the point at infinity.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0. Vendored unchanged from thebes-kernel `src/sig/P256.mo`
/// (itself moved there from thebes-audit-engine); see NOTICE.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";

module {
  public let p : Nat = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff;
  public let n : Nat = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
  public let b : Nat = 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b;
  let gx : Nat = 0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296;
  let gy : Nat = 0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5;

  // ── field arithmetic mod p (inputs already reduced) ──
  func fadd(x : Nat, y : Nat) : Nat { let s = x + y; if (s >= p) s - p else s };
  func fsub(x : Nat, y : Nat) : Nat { if (x >= y) x - y else x + p - y };
  func fmul(x : Nat, y : Nat) : Nat { (x * y) % p };

  /// The inverse of x modulo m (m prime, 0 < x < m), by the extended Euclidean algorithm.
  func inv(x : Nat, m : Nat) : Nat {
    var r0 : Int = m;
    var r1 : Int = x;
    var t0 : Int = 0;
    var t1 : Int = 1;
    while (r1 != 0) {
      let q = r0 / r1;
      let r2 = r0 - q * r1;
      r0 := r1;
      r1 := r2;
      let t2 = t0 - q * t1;
      t0 := t1;
      t1 := t2;
    };
    let t = t0 % m;
    Int.abs(if (t < 0) t + m else t)
  };

  /// A point in Jacobian coordinates; z = 0 is the point at infinity.
  type Pt = (Nat, Nat, Nat);
  let INF : Pt = (1, 1, 0);

  func dbl(pt : Pt) : Pt {
    let (x1, y1, z1) = pt;
    if (z1 == 0 or y1 == 0) return INF;
    let delta = fmul(z1, z1);
    let gamma = fmul(y1, y1);
    let beta = fmul(x1, gamma);
    let alpha = fmul(3, fmul(fsub(x1, delta), fadd(x1, delta)));
    let x3 = fsub(fmul(alpha, alpha), fmul(8, beta));
    let z3 = fsub(fsub(fmul(fadd(y1, z1), fadd(y1, z1)), gamma), delta);
    let y3 = fsub(fmul(alpha, fsub(fmul(4, beta), x3)), fmul(8, fmul(gamma, gamma)));
    (x3, y3, z3)
  };

  func add(pa : Pt, pb : Pt) : Pt {
    let (x1, y1, z1) = pa;
    let (x2, y2, z2) = pb;
    if (z1 == 0) return pb;
    if (z2 == 0) return pa;
    let z1z1 = fmul(z1, z1);
    let z2z2 = fmul(z2, z2);
    let u1 = fmul(x1, z2z2);
    let u2 = fmul(x2, z1z1);
    let s1 = fmul(y1, fmul(z2, z2z2));
    let s2 = fmul(y2, fmul(z1, z1z1));
    let h = fsub(u2, u1);
    let rr = fmul(2, fsub(s2, s1));
    if (h == 0) return if (rr == 0) dbl(pa) else INF;
    let i = fmul(fmul(2, h), fmul(2, h));
    let j = fmul(h, i);
    let v = fmul(u1, i);
    let x3 = fsub(fsub(fmul(rr, rr), j), fmul(2, v));
    let y3 = fsub(fmul(rr, fsub(v, x3)), fmul(2, fmul(s1, j)));
    let z3 = fmul(fsub(fsub(fmul(fadd(z1, z2), fadd(z1, z2)), z1z1), z2z2), h);
    (x3, y3, z3)
  };

  /// The affine x coordinate, or null for the point at infinity.
  func affineX(pt : Pt) : ?Nat {
    let (x, _, z) = pt;
    if (z == 0) return null;
    let zi = inv(z, p);
    ?fmul(x, fmul(zi, zi))
  };

  /// Is (x, y) a point of the curve: y² = x³ − 3x + b (mod p)?
  public func onCurve(x : Nat, y : Nat) : Bool {
    if (x >= p or y >= p) return false;
    fmul(y, y) == fadd(fsub(fmul(x, fmul(x, x)), fmul(3, x)), b)
  };

  func bits(k : Nat) : [Bool] {
    // most significant first, 256 of them
    var v = k;
    let lsb = Array.tabulate<Bool>(256, func(_) { let bit = v % 2 == 1; v /= 2; bit });
    Array.tabulate<Bool>(256, func(i) { lsb[255 - i] })
  };

  /// Verify an ECDSA P-256 signature (r, s) on the 32-byte SHA-256 digest `e` under the
  /// public key (qx, qy).
  public func verify(qx : Nat, qy : Nat, e : Nat, r : Nat, s : Nat) : Bool {
    if (r == 0 or r >= n or s == 0 or s >= n) return false;
    if (not onCurve(qx, qy)) return false;
    let w = inv(s, n);
    let u1 = (e % n) * w % n;
    let u2 = r * w % n;
    let g : Pt = (gx, gy, 1);
    let q : Pt = (qx, qy, 1);
    let gq = add(g, q);
    let b1 = bits(u1);
    let b2 = bits(u2);
    var acc = INF;
    for (i in Nat.range(0, 256)) {
      acc := dbl(acc);
      if (b1[i] and b2[i]) acc := add(acc, gq)
      else if (b1[i]) acc := add(acc, g)
      else if (b2[i]) acc := add(acc, q);
    };
    switch (affineX(acc)) { case (?x) x % n == r; case null false }
  };

  // ── encodings ──

  public func natOf(bytes : [Nat8]) : Nat {
    var v = 0;
    for (x in bytes.vals()) v := v * 256 + Nat8.toNat(x);
    v
  };

  /// The fixed SubjectPublicKeyInfo prefix of an uncompressed P-256 key: id-ecPublicKey,
  /// prime256v1, a 66-byte BIT STRING holding 0x04 ‖ X ‖ Y.
  let SPKI_PREFIX : [Nat8] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04];

  /// The public point of a DER SubjectPublicKeyInfo for an uncompressed P-256 key.
  public func parseSpki(spki : Blob) : ?(Nat, Nat) {
    let a = Blob.toArray(spki);
    if (a.size() != 91) return null;
    for (i in SPKI_PREFIX.keys()) { if (a[i] != SPKI_PREFIX[i]) return null };
    let x = natOf(Array.sliceToArray(a, 27, 59));
    let y = natOf(Array.sliceToArray(a, 59, 91));
    if (not onCurve(x, y)) null else ?(x, y)
  };

  /// (r, s) of a DER ECDSA-Sig-Value: SEQUENCE { INTEGER r, INTEGER s }, short-form
  /// lengths only (a P-256 signature is at most 72 bytes).
  public func parseDerSignature(sig : Blob) : ?(Nat, Nat) {
    let a = Blob.toArray(sig);
    if (a.size() < 8 or a[0] != 0x30 or Nat8.toNat(a[1]) != a.size() - 2) return null;
    func int(at : Nat) : ?(Nat, Nat) {
      if (at + 2 > a.size() or a[at] != 0x02) return null;
      let len = Nat8.toNat(a[at + 1]);
      if (len == 0 or len > 33 or at + 2 + len > a.size()) return null;
      // DER: no negative numbers, no unnecessary leading zero
      if (a[at + 2] >= 0x80) return null;
      if (len > 1 and a[at + 2] == 0 and a[at + 3] < 0x80) return null;
      ?(natOf(Array.sliceToArray(a, at + 2, at + 2 + len)), at + 2 + len)
    };
    switch (int(2)) {
      case (?(r, next)) switch (int(next)) { case (?(s, end)) if (end == a.size()) ?(r, s) else null; case null null };
      case null null;
    }
  };
};
