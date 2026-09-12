import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import VarArray "mo:core/VarArray";
import Aes "PqAes128";
import Gf16 "PqGf16";
import Keccak "PqKeccak";

module {
  public let m : Nat = 64;
  public let n : Nat = 81;
  public let o : Nat = 17;
  public let v : Nat = 64;
  public let k : Nat = 4;
  public let triV : Nat = 2080;
  public let triO : Nat = 153;
  public let mBytes : Nat = 32;
  public let p1Bytes : Nat = 66560;
  public let p2Bytes : Nat = 34816;
  public let p3Bytes : Nat = 4896;
  public let publicKeyBytes : Nat = 4912;
  public let pkSeedBytes : Nat = 16;
  public let signatureVectorBytes : Nat = 162;
  public let saltBytes : Nat = 24;
  public let signatureBytes : Nat = 186;

  public type ExpandedPublicKey = {
    p1 : [Nat8];
    p2 : [Nat8];
    p3 : [Nat8];
  };

  public type Signature = {
    s : [Nat8];
    salt : [Nat8];
  };

  public type MutationCoverage = {
    signedMessageBitFlips : Nat;
    signatureVectorBitFlips : Nat;
    signatureSaltBitFlips : Nat;
  };

  public func parseSignature(bytes : [Nat8]) : ?Signature {
    if (bytes.size() != signatureBytes) {
      return null;
    };
    ?{
      s = Array.tabulate<Nat8>(signatureVectorBytes, func(i : Nat) : Nat8 { bytes[i] });
      salt = Array.tabulate<Nat8>(saltBytes, func(i : Nat) : Nat8 { bytes[signatureVectorBytes + i] });
    };
  };

  public func expandPublicKey(pkBytes : [Nat8]) : ?ExpandedPublicKey {
    if (pkBytes.size() != publicKeyBytes) {
      return null;
    };
    let seed = Array.tabulate<Nat8>(pkSeedBytes, func(i : Nat) : Nat8 { pkBytes[i] });
    switch (Aes.ctr32beSplit(seed, p1Bytes, p2Bytes)) {
      case (?expanded) {
        ?{
          p1 = expanded.first;
          p2 = expanded.second;
          p3 = Array.tabulate<Nat8>(p3Bytes, func(i : Nat) : Nat8 { pkBytes[pkSeedBytes + i] });
        };
      };
      case null null;
    };
  };

  public func expandP1P2Window(pkBytes : [Nat8], offset : Nat, len : Nat) : ?[Nat8] {
    if (pkBytes.size() != publicKeyBytes or offset + len > p1Bytes + p2Bytes) {
      return null;
    };
    let seed = Array.tabulate<Nat8>(pkSeedBytes, func(i : Nat) : Nat8 { pkBytes[i] });
    ?Aes.ctr32beAt(seed, offset, len);
  };

  public func verifyCompactBytes(pkBytes : [Nat8], signedMessage : [Nat8], sigBytes : [Nat8]) : Bool {
    switch (expandPublicKey(pkBytes), parseSignature(sigBytes)) {
      case (?epk, ?sig) verifyExpanded(epk, signedMessage, sig);
      case _ false;
    };
  };

  public func targetNibbles(signedMessage : [Nat8], salt : [Nat8]) : [Nat8] {
    let tHash = targetPackedBytes(signedMessage, salt);
    if (tHash.size() != mBytes) {
      return [];
    };
    Array.tabulate<Nat8>(m, func(i : Nat) : Nat8 { Gf16.getPacked(tHash, i) });
  };

  func targetPackedBytes(signedMessage : [Nat8], salt : [Nat8]) : [Nat8] {
    if (salt.size() != saltBytes) {
      return [];
    };
    let digest = Keccak.shake256(signedMessage, 32);
    Keccak.shake256(Array.concat<Nat8>(digest, salt), mBytes);
  };

  public func verifyExpanded(epk : ExpandedPublicKey, signedMessage : [Nat8], sig : Signature) : Bool {
    if (epk.p1.size() != p1Bytes or epk.p2.size() != p2Bytes or epk.p3.size() != p3Bytes) {
      return false;
    };
    if (sig.s.size() != signatureVectorBytes or sig.salt.size() != saltBytes) {
      return false;
    };

    let target = targetPackedBytes(signedMessage, sig.salt);
    if (target.size() != mBytes) {
      return false;
    };

    let temp = evaluateMapPacked(epk, unpackSignatureRows(sig.s));

    var idx : Nat = 0;
    while (idx < mBytes) {
      if (temp[idx] != target[idx]) {
        return false;
      };
      idx += 1;
    };
    true;
  };

  public func singleBitMutationCoverage(epk : ExpandedPublicKey, signedMessage : [Nat8], sig : Signature) : ?MutationCoverage {
    if (epk.p1.size() != p1Bytes or epk.p2.size() != p2Bytes or epk.p3.size() != p3Bytes) {
      return null;
    };
    if (sig.s.size() != signatureVectorBytes or sig.salt.size() != saltBytes) {
      return null;
    };

    let target = targetPackedBytes(signedMessage, sig.salt);
    if (target.size() != mBytes) {
      return null;
    };

    let sigs = unpackSignatureRows(sig.s);
    let originalMap = evaluateMapPacked(epk, sigs);
    if (not equalBytes(originalMap, target)) {
      return null;
    };

    var signedMessageBitFlips : Nat = 0;
    var byteIdx : Nat = 0;
    while (byteIdx < signedMessage.size()) {
      var bitIdx : Nat = 0;
      while (bitIdx < 8) {
        let mutatedTarget = targetPackedBytes(flipBit(signedMessage, byteIdx, bitIdx), sig.salt);
        if (equalBytes(mutatedTarget, originalMap)) {
          return null;
        };
        signedMessageBitFlips += 1;
        bitIdx += 1;
      };
      byteIdx += 1;
    };

    var signatureSaltBitFlips : Nat = 0;
    byteIdx := 0;
    while (byteIdx < sig.salt.size()) {
      var bitIdx : Nat = 0;
      while (bitIdx < 8) {
        let mutatedTarget = targetPackedBytes(signedMessage, flipBit(sig.salt, byteIdx, bitIdx));
        if (equalBytes(mutatedTarget, originalMap)) {
          return null;
        };
        signatureSaltBitFlips += 1;
        bitIdx += 1;
      };
      byteIdx += 1;
    };

    var signatureVectorBitFlips : Nat = 0;
    let nibbleMasks : [Nat8] = [1, 2, 4, 8];
    var packedNibble : Nat = 0;
    while (packedNibble < k * n) {
      let row = packedNibble / n;
      let coord = packedNibble % n;
      let oldValue = sigs[row][coord];
      var maskIdx : Nat = 0;
      while (maskIdx < nibbleMasks.size()) {
        let newValue = oldValue ^ nibbleMasks[maskIdx];
        let delta = signatureCoordinateDelta(epk, sigs, row, coord, newValue);
        if (isZeroBytes(delta)) {
          return null;
        };
        signatureVectorBitFlips += 1;
        maskIdx += 1;
      };
      packedNibble += 1;
    };

    ?{
      signedMessageBitFlips;
      signatureVectorBitFlips;
      signatureSaltBitFlips;
    };
  };

  func unpackSignatureRows(s : [Nat8]) : [[Nat8]] {
    Array.tabulate<[Nat8]>(k, func(ki : Nat) : [Nat8] {
      Array.tabulate<Nat8>(n, func(ni : Nat) : Nat8 {
        Gf16.getPacked(s, ki * n + ni);
      });
    });
  };

  func evaluateMapPacked(epk : ExpandedPublicKey, sigs : [[Nat8]]) : [Nat8] {
    let temp = VarArray.repeat<Nat8>(0, mBytes);
    var iRev : Nat = 0;
    while (iRev < k) {
      let i = k - 1 - iRev;
      var j : Nat = i;
      while (j < k) {
        shiftXModF(temp);
        addPairContribution(temp, epk, sigs[i], sigs[j], i == j);
        j += 1;
      };
      iRev += 1;
    };
    Array.fromVarArray<Nat8>(temp);
  };

  func equalBytes(a : [Nat8], b : [Nat8]) : Bool {
    if (a.size() != b.size()) {
      return false;
    };
    var idx : Nat = 0;
    while (idx < a.size()) {
      if (a[idx] != b[idx]) {
        return false;
      };
      idx += 1;
    };
    true;
  };

  func isZeroBytes(bytes : [Nat8]) : Bool {
    var idx : Nat = 0;
    while (idx < bytes.size()) {
      if (bytes[idx] != 0) {
        return false;
      };
      idx += 1;
    };
    true;
  };

  func flipBit(bytes : [Nat8], byteIdx : Nat, bitIdx : Nat) : [Nat8] {
    let mask = bitMask(bitIdx);
    Array.tabulate<Nat8>(bytes.size(), func(i : Nat) : Nat8 {
      if (i == byteIdx) bytes[i] ^ mask else bytes[i];
    });
  };

  func bitMask(bitIdx : Nat) : Nat8 {
    switch (bitIdx) {
      case (0) 1;
      case (1) 2;
      case (2) 4;
      case (3) 8;
      case (4) 16;
      case (5) 32;
      case (6) 64;
      case (_) 128;
    };
  };

  func signatureCoordinateDelta(epk : ExpandedPublicKey, sigs : [[Nat8]], changedRow : Nat, changedCoord : Nat, newValue : Nat8) : [Nat8] {
    let delta = VarArray.repeat<Nat8>(0, mBytes);
    var step : Nat = 0;
    var iRev : Nat = 0;
    while (iRev < k) {
      let i = k - 1 - iRev;
      var j : Nat = i;
      while (j < k) {
        if (i == changedRow or j == changedRow) {
          let pairDelta = VarArray.repeat<Nat8>(0, mBytes);
          addCoordinatePairDelta(pairDelta, epk, sigs, i, j, changedRow, changedCoord, newValue, i == j);
          var shifts : Nat = 0;
          while (shifts < ((k * (k + 1)) / 2 - 1 - step)) {
            shiftXModF(pairDelta);
            shifts += 1;
          };
          xorBytes(delta, pairDelta);
        };
        step += 1;
        j += 1;
      };
      iRev += 1;
    };
    Array.fromVarArray<Nat8>(delta);
  };

  func addCoordinatePairDelta(
    acc : [var Nat8],
    epk : ExpandedPublicKey,
    sigs : [[Nat8]],
    i : Nat,
    j : Nat,
    changedRow : Nat,
    changedCoord : Nat,
    newValue : Nat8,
    same : Bool,
  ) {
    if (changedCoord < v) {
      var a : Nat = 0;
      while (a <= changedCoord) {
        addEntryFactorDelta(acc, epk.p1, a * v - (a * (a + 1)) / 2 + changedCoord, sigs, i, j, a, changedCoord, changedRow, changedCoord, newValue, same);
        a += 1;
      };

      var b : Nat = changedCoord + 1;
      while (b < v) {
        addEntryFactorDelta(acc, epk.p1, changedCoord * v - (changedCoord * (changedCoord + 1)) / 2 + b, sigs, i, j, changedCoord, b, changedRow, changedCoord, newValue, same);
        b += 1;
      };

      b := 0;
      while (b < o) {
        addEntryFactorDelta(acc, epk.p2, changedCoord * o + b, sigs, i, j, changedCoord, v + b, changedRow, changedCoord, newValue, same);
        b += 1;
      };
    } else {
      let oilCoord = changedCoord - v;
      var a : Nat = 0;
      while (a < v) {
        addEntryFactorDelta(acc, epk.p2, a * o + oilCoord, sigs, i, j, a, changedCoord, changedRow, changedCoord, newValue, same);
        a += 1;
      };

      a := 0;
      while (a <= oilCoord) {
        addEntryFactorDelta(acc, epk.p3, a * o - (a * (a + 1)) / 2 + oilCoord, sigs, i, j, v + a, changedCoord, changedRow, changedCoord, newValue, same);
        a += 1;
      };

      var b : Nat = oilCoord + 1;
      while (b < o) {
        addEntryFactorDelta(acc, epk.p3, oilCoord * o - (oilCoord * (oilCoord + 1)) / 2 + b, sigs, i, j, changedCoord, v + b, changedRow, changedCoord, newValue, same);
        b += 1;
      };
    };
  };

  func addEntryFactorDelta(
    acc : [var Nat8],
    bytes : [Nat8],
    entry : Nat,
    sigs : [[Nat8]],
    i : Nat,
    j : Nat,
    leftCoord : Nat,
    rightCoord : Nat,
    changedRow : Nat,
    changedCoord : Nat,
    newValue : Nat8,
    same : Bool,
  ) {
    let oldFactor = pairFactor(sigs[i][leftCoord], sigs[j][rightCoord], sigs[j][leftCoord], sigs[i][rightCoord], same);
    let updatedFactor = pairFactor(
      signatureValue(sigs, i, leftCoord, changedRow, changedCoord, newValue),
      signatureValue(sigs, j, rightCoord, changedRow, changedCoord, newValue),
      signatureValue(sigs, j, leftCoord, changedRow, changedCoord, newValue),
      signatureValue(sigs, i, rightCoord, changedRow, changedCoord, newValue),
      same,
    );
    addPackedMVectorContribution(acc, bytes, entry, oldFactor ^ updatedFactor);
  };

  func signatureValue(sigs : [[Nat8]], row : Nat, coord : Nat, changedRow : Nat, changedCoord : Nat, newValue : Nat8) : Nat8 {
    if (row == changedRow and coord == changedCoord) {
      newValue;
    } else {
      sigs[row][coord];
    };
  };

  func xorBytes(acc : [var Nat8], bytes : [var Nat8]) {
    var idx : Nat = 0;
    while (idx < acc.size()) {
      acc[idx] ^= bytes[idx];
      idx += 1;
    };
  };

  func shiftXModF(poly : [var Nat8]) {
    let top = (poly[mBytes - 1] >> 4) & 0x0F;
    var idx : Nat = mBytes - 1;
    label L loop {
      if (idx == 0) {
        poly[0] := (poly[0] & 0x0F) << 4;
        break L;
      };
      poly[idx] := ((poly[idx] & 0x0F) << 4) | ((poly[idx - 1] >> 4) & 0x0F);
      idx -= 1;
    };
    if (top != 0) {
      xorPackedNibble(poly, 0, Gf16.mul(top, 8));
      xorPackedNibble(poly, 2, Gf16.mul(top, 2));
      xorPackedNibble(poly, 3, Gf16.mul(top, 8));
    };
  };

  func xorPackedNibble(poly : [var Nat8], idx : Nat, value : Nat8) {
    let byteIdx = idx / 2;
    if (idx % 2 == 0) {
      poly[byteIdx] ^= value & 0x0F;
    } else {
      poly[byteIdx] ^= (value & 0x0F) << 4;
    };
  };

  func addPairContribution(acc : [var Nat8], epk : ExpandedPublicKey, si : [Nat8], sj : [Nat8], same : Bool) {
    var a : Nat = 0;
    while (a < v) {
      var b : Nat = a;
      while (b < v) {
        let entry = a * v - (a * (a + 1)) / 2 + b;
        addPackedMVectorContribution(acc, epk.p1, entry, pairFactor(si[a], sj[b], sj[a], si[b], same));
        b += 1;
      };
      a += 1;
    };

    a := 0;
    while (a < v) {
      var b : Nat = 0;
      while (b < o) {
        addPackedMVectorContribution(acc, epk.p2, a * o + b, pairFactor(si[a], sj[v + b], sj[a], si[v + b], same));
        b += 1;
      };
      a += 1;
    };

    a := 0;
    while (a < o) {
      var b : Nat = a;
      while (b < o) {
        let entry = a * o - (a * (a + 1)) / 2 + b;
        addPackedMVectorContribution(acc, epk.p3, entry, pairFactor(si[v + a], sj[v + b], sj[v + a], si[v + b], same));
        b += 1;
      };
      a += 1;
    };
  };

  func pairFactor(a : Nat8, b : Nat8, crossA : Nat8, crossB : Nat8, same : Bool) : Nat8 {
    var factor : Nat8 = product(a, b);
    if (not same) {
      factor ^= product(crossA, crossB);
    };
    factor & 0x0F;
  };

  func product(a : Nat8, b : Nat8) : Nat8 {
    if (a == 0 or b == 0) {
      return 0;
    };
    Gf16.mul(a, b);
  };

  func addPackedMVectorContribution(acc : [var Nat8], bytes : [Nat8], entry : Nat, factor : Nat8) {
    let f = factor & 0x0F;
    if (f == 0) {
      return;
    };

    let base = entry * mBytes;
    var byteIdx : Nat = 0;
    while (byteIdx < mBytes) {
      acc[byteIdx] ^= Gf16.mulPackedByte(bytes[base + byteIdx], f);
      byteIdx += 1;
    };
  };
};
