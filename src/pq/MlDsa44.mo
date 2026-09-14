/// MlDsa44.mo: ML-DSA-44 signature verification per FIPS 204 (August 2024), over the byte encodings
/// of the standard: a 1,312-byte public key, a 2,420-byte signature, the context string, and the
/// message.
///
/// The arithmetic (number-theoretic transform, Montgomery reduction, rejection sampling of the
/// matrix, decomposition and hints) is the Thebes Core Team's pure-Motoko ML-DSA implementation
/// (`MlDsaRef.mo`, `MlDsaNtt.mo`, `MlDsaKeccak.mo`, whose key generation matches pq-crystals
/// byte for byte); what this module adds is the standard's outer layer that implementation lacks;
/// pkDecode / sigDecode (Algorithms 23, 27; 10-bit, 18-bit and hint packings), tr = H(pk),
/// μ = H(tr ‖ 0x00 ‖ |ctx| ‖ ctx ‖ M) with the domain separation of ML-DSA.Verify (Algorithm 3),
/// the spec's SampleInBall with rejection (Algorithm 29) and w1Encode (Algorithm 28); so that a
/// signature produced by any conforming implementation verifies here. The proof is the NIST
/// known-answer file: `test/MlDsa44.test.mo` verifies the reference KAT vectors and refuses each
/// one mutated.
///
/// Verify only: this bank never holds a signing key; connectors sign, the bank checks.

import Array "mo:core/Array";
import Int "mo:core/Int";
import Int32 "mo:core/Int32";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import VarArray "mo:core/VarArray";

import Keccak "MlDsaKeccak";
import NTT "MlDsaNtt";

module {

  public let PK_BYTES : Nat = 1_312;
  public let SIG_BYTES : Nat = 2_420;

  let K : Nat = 4;
  let L : Nat = 4;
  let N : Nat = 256;
  let Q : Int = 8_380_417;
  let GAMMA1 : Int = 131_072;        // 2^17
  let GAMMA2 : Int = 95_232;         // (q − 1) / 88
  let BETA : Int = 78;               // τ · η
  let TAU : Nat = 39;
  let OMEGA : Nat = 80;
  let D_SHIFT : Int = 8_192;         // 2^d, d = 13

  public type PublicKey = { rho : [Nat8]; t1 : [[Int32]] };
  public type Signature = { cTilde : [Nat8]; z : [[Int32]]; hint : [[Int32]] };

  // ─── codecs (FIPS 204 §7) ───

  /// Algorithm 23 pkDecode: ρ ‖ SimpleBitPack(t1, 10 bits)[k].
  public func pkDecode(pk : [Nat8]) : ?PublicKey {
    if (pk.size() != PK_BYTES) return null;
    let rho = Array.tabulate<Nat8>(32, func(i) { pk[i] });
    let t1 = Array.tabulate<[Int32]>(K, func(i) {
      let base = 32 + 320 * i;
      Array.tabulate<Int32>(N, func(j) {
        // coefficient j occupies bits [10j, 10j+10), little-endian within bytes
        let bit = 10 * j;
        let byte = bit / 8;
        let off = bit % 8;
        let v = (Nat8.toNat(pk[base + byte]) + Nat8.toNat(pk[base + byte + 1]) * 256) / (2 ** off) % 1024;
        Int32.fromInt(v)
      })
    });
    ?{ rho; t1 }
  };

  /// Algorithm 27 sigDecode: c̃(32) ‖ BitPack(z, γ1−1, γ1)[l] (18 bits) ‖ HintBitPack(h) (ω + k bytes).
  public func sigDecode(sig : [Nat8]) : ?Signature {
    if (sig.size() != SIG_BYTES) return null;
    let cTilde = Array.tabulate<Nat8>(32, func(i) { sig[i] });
    let z = Array.tabulate<[Int32]>(L, func(i) {
      let base = 32 + 576 * i;
      Array.tabulate<Int32>(N, func(j) {
        let bit = 18 * j;
        let byte = bit / 8;
        let off = bit % 8;
        let raw = Nat8.toNat(sig[base + byte]) + Nat8.toNat(sig[base + byte + 1]) * 256 + Nat8.toNat(sig[base + byte + 2]) * 65_536;
        let u = raw / (2 ** off) % 262_144;
        Int32.fromInt(GAMMA1 - u)
      })
    });
    // Algorithm 21 HintBitUnpack: the ω positions, then k running counts; strictly increasing per row
    let hbase = 32 + 576 * L;
    let hint = VarArray.repeat<[Int32]>([], K);
    var index = 0;
    var i = 0;
    while (i < K) {
      let count = Nat8.toNat(sig[hbase + OMEGA + i]);
      if (count < index or count > OMEGA) return null;
      let row = VarArray.repeat<Int32>(0, N);
      let first = index;
      while (index < count) {
        if (index > first and sig[hbase + index - 1] >= sig[hbase + index]) return null;
        row[Nat8.toNat(sig[hbase + index])] := 1;
        index += 1;
      };
      hint[i] := Array.fromVarArray(row);
      i += 1;
    };
    while (index < OMEGA) { if (sig[hbase + index] != 0) return null; index += 1 };
    ?{ cTilde; z = z; hint = Array.fromVarArray(hint) }
  };

  // ─── sampling (FIPS 204 §7.3) ───

  /// Algorithm 30 RejNTTPoly on the SHAKE-128 stream of ρ ‖ s ‖ r.
  func rejNttPoly(rho : [Nat8], s : Nat8, r : Nat8) : [Int32] {
    // 23-bit candidates with a rejection rate below 0.1%: 6N bytes give 2N candidates
    let stream = Keccak.shake128(Array.concat<Nat8>(rho, [s, r]), N * 6);
    let poly = VarArray.repeat<Int32>(0, N);
    var ctr = 0;
    var pos = 0;
    while (ctr < N and pos + 2 < stream.size()) {
      let t = (Nat8.toNat(stream[pos]) + Nat8.toNat(stream[pos + 1]) * 256 + Nat8.toNat(stream[pos + 2]) * 65_536) % 0x800000;
      pos += 3;
      if (t < Int.abs(Q)) { poly[ctr] := Int32.fromInt(t); ctr += 1 };
    };
    Array.fromVarArray(poly)
  };

  /// Algorithm 32 ExpandA: Â[r][s] = RejNTTPoly(ρ ‖ IntegerToBytes(s, 1) ‖ IntegerToBytes(r, 1)).
  func expandA(rho : [Nat8]) : [[Int32]] {
    Array.tabulate<[Int32]>(K * L, func(idx) { rejNttPoly(rho, Nat8.fromNat(idx % L), Nat8.fromNat(idx / L)) })
  };

  /// Algorithm 29 SampleInBall(ρ): eight sign bytes, then τ positions drawn with rejection (a byte
  /// is used only when ≤ i). The stream is squeezed in one block large enough that exhausting it has
  /// probability below 2^-1000; an exhausted stream fails the verification rather than wrapping.
  func sampleInBall(rho : [Nat8]) : ?[var Int32] {
    let buf = Keccak.shake256(rho, 8 + 1_024);
    let c = VarArray.repeat<Int32>(0, N);
    var pos = 8;
    var i = N - TAU;
    while (i < N) {
      var j = 0;
      label draw loop {
        if (pos >= buf.size()) return null;
        j := Nat8.toNat(buf[pos]);
        pos += 1;
        if (j <= i) break draw;
      };
      c[i] := c[j];
      let signByte = Nat8.toNat(buf[(i - (N - TAU)) / 8]);
      let sign = (signByte / (2 ** ((i - (N - TAU)) % 8))) % 2;
      c[j] := if (sign == 0) 1 else -1;
      i += 1;
    };
    ?c
  };

  // ─── decomposition and hints (FIPS 204 §7.4), γ2 = (q − 1) / 88 ───

  func decompose(a : Int32) : (Int, Int) {
    let av = Int32.toInt(NTT.freeze(a));
    var a1 = (av + 127) / 128;
    a1 := (a1 * 11_275 + 8_388_608) / 16_777_216;
    if (a1 >= 44) a1 := 0;
    var a0 = av - a1 * (2 * GAMMA2);
    if (a0 > (Q - 1) / 2) a0 -= Q;
    (a1, a0)
  };

  /// Algorithm 40 UseHint, for m = (q − 1) / (2γ2) = 44.
  func useHint(h : Int32, r : Int32) : Int {
    let (r1, r0) = decompose(r);
    if (h == 0) return r1;
    if (r0 > 0) { if (r1 == 43) 0 else r1 + 1 } else { if (r1 == 0) 43 else r1 - 1 }
  };

  /// Algorithm 28 w1Encode: six bits a coefficient (values 0..43), little-endian bit packing.
  func w1Encode(w1 : [[Int]]) : [Nat8] {
    let out = VarArray.repeat<Nat8>(0, K * 192);
    var idx = 0;
    var ki = 0;
    while (ki < K) {
      var ni = 0;
      while (ni < N) {
        let a = Int.abs(w1[ki][ni]) % 64; let b = Int.abs(w1[ki][ni + 1]) % 64; let c = Int.abs(w1[ki][ni + 2]) % 64; let d = Int.abs(w1[ki][ni + 3]) % 64;
        out[idx] := Nat8.fromNat((a + b * 64) % 256);
        out[idx + 1] := Nat8.fromNat((b / 4 + c * 16) % 256);
        out[idx + 2] := Nat8.fromNat((c / 16 + d * 4) % 256);
        idx += 3;
        ni += 4;
      };
      ki += 1;
    };
    Array.fromVarArray(out)
  };

  func infinityNormBelow(poly : [Int32], bound : Int) : Bool {
    for (c in poly.vals()) {
      // coefficients of z are already centred in (−γ1, γ1)
      let v = Int32.toInt(c);
      if (v >= bound or v <= -bound) return false;
    };
    true
  };

  // ─── verification ───

  /// Algorithm 3 ML-DSA.Verify(pk, M, σ, ctx): |ctx| ≤ 255; M' = 0x00 ‖ IntegerToBytes(|ctx|, 1) ‖ ctx ‖ M.
  public func verify(pkBytes : [Nat8], message : [Nat8], ctx : [Nat8], sigBytes : [Nat8]) : Bool {
    if (ctx.size() > 255) return false;
    let ?pk = pkDecode(pkBytes) else return false;
    let ?sig = sigDecode(sigBytes) else return false;
    let mPrime = Array.concat<Nat8>([0 : Nat8, Nat8.fromNat(ctx.size())], Array.concat<Nat8>(ctx, message));
    verifyInternal(pk, pkBytes, mPrime, sig)
  };

  /// Algorithm 8 ML-DSA.Verify_internal.
  func verifyInternal(pk : PublicKey, pkBytes : [Nat8], mPrime : [Nat8], sig : Signature) : Bool {
    // ‖z‖∞ < γ1 − β
    for (poly in sig.z.vals()) { if (not infinityNormBelow(poly, GAMMA1 - BETA)) return false };
    let tr = Keccak.shake256(pkBytes, 64);
    let mu = Keccak.shake256(Array.concat<Nat8>(tr, mPrime), 64);
    let ?c = sampleInBall(sig.cTilde) else return false;
    let a = expandA(pk.rho);
    // ĉ
    NTT.ntt(c);
    let chat = Array.fromVarArray(c);
    // ẑ
    let zhat = Array.tabulate<[Int32]>(L, func(li) { let tmp = Array.toVarArray<Int32>(sig.z[li]); NTT.ntt(tmp); Array.fromVarArray(tmp) });
    // w' = NTT⁻¹(Â ∘ ẑ − ĉ ∘ NTT(t1 · 2^d))
    let w1 = Array.tabulate<[Int]>(K, func(ki) {
      var acc = NTT.zeroPoly();
      var li = 0;
      while (li < L) {
        let prod = NTT.pointwiseMul(a[ki * L + li], zhat[li]);
        acc := NTT.polyAdd(Array.fromVarArray(acc), Array.fromVarArray(prod));
        li += 1;
      };
      let t1d = Array.toVarArray<Int32>(Array.map<Int32, Int32>(pk.t1[ki], func(v) { Int32.fromInt(Int32.toInt(v) * D_SHIFT) }));
      NTT.ntt(t1d);
      let ct1d = NTT.pointwiseMul(chat, Array.fromVarArray(t1d));
      var ni = 0;
      while (ni < N) { acc[ni] := acc[ni] -% ct1d[ni]; ni += 1 };
      NTT.invNtt(acc);
      Array.tabulate<Int>(N, func(ni2) { useHint(sig.hint[ki][ni2], acc[ni2]) })
    });
    let cCheck = Keccak.shake256(Array.concat<Nat8>(mu, w1Encode(w1)), 32);
    var same = true;
    var i = 0;
    while (i < 32) { if (cCheck[i] != sig.cTilde[i]) same := false; i += 1 };
    same
  };

}
