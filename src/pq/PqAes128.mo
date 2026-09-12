import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import VarArray "mo:core/VarArray";

module {
  let sbox : [Nat8] = [
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
  ];

  let rcon : [Nat8] = [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];

  public type SplitStream = {
    first : [Nat8];
    second : [Nat8];
  };

  public func encryptBlock(key : [Nat8], block : [Nat8]) : [Nat8] {
    if (key.size() != 16 or block.size() != 16) {
      return [];
    };
    let roundKeys = expandKey(key);
    encryptBlockWithRoundKeys(roundKeys, block);
  };

  func encryptBlockWithRoundKeys(roundKeys : [Nat8], block : [Nat8]) : [Nat8] {
    if (roundKeys.size() != 176 or block.size() != 16) {
      return [];
    };
    encrypt16WithRoundKeys(
      roundKeys,
      block[0], block[1], block[2], block[3],
      block[4], block[5], block[6], block[7],
      block[8], block[9], block[10], block[11],
      block[12], block[13], block[14], block[15],
    );
  };

  func encryptCounterWithRoundKeys(roundKeys : [Nat8], counter : [var Nat8]) : [Nat8] {
    if (roundKeys.size() != 176 or counter.size() != 16) {
      return [];
    };
    let out = VarArray.repeat<Nat8>(0, 16);
    encryptCounterInto(roundKeys, counter, out, 0, 0, 16);
    Array.fromVarArray(out);
  };

  func encryptCounterInto(roundKeys : [Nat8], counter : [var Nat8], out : [var Nat8], outOffset : Nat, skip : Nat, take : Nat) {
    encrypt16Into(
      roundKeys,
      counter[0], counter[1], counter[2], counter[3],
      counter[4], counter[5], counter[6], counter[7],
      counter[8], counter[9], counter[10], counter[11],
      counter[12], counter[13], counter[14], counter[15],
      out,
      outOffset,
      skip,
      take,
    );
  };

  func encrypt16WithRoundKeys(
    roundKeys : [Nat8],
    b0 : Nat8, b1 : Nat8, b2 : Nat8, b3 : Nat8,
    b4 : Nat8, b5 : Nat8, b6 : Nat8, b7 : Nat8,
    b8 : Nat8, b9 : Nat8, b10 : Nat8, b11 : Nat8,
    b12 : Nat8, b13 : Nat8, b14 : Nat8, b15 : Nat8,
  ) : [Nat8] {
    let out = VarArray.repeat<Nat8>(0, 16);
    encrypt16Into(
      roundKeys,
      b0, b1, b2, b3,
      b4, b5, b6, b7,
      b8, b9, b10, b11,
      b12, b13, b14, b15,
      out,
      0,
      0,
      16,
    );
    Array.fromVarArray(out);
  };

  func encrypt16Into(
    roundKeys : [Nat8],
    b0 : Nat8, b1 : Nat8, b2 : Nat8, b3 : Nat8,
    b4 : Nat8, b5 : Nat8, b6 : Nat8, b7 : Nat8,
    b8 : Nat8, b9 : Nat8, b10 : Nat8, b11 : Nat8,
    b12 : Nat8, b13 : Nat8, b14 : Nat8, b15 : Nat8,
    out : [var Nat8],
    outOffset : Nat,
    skip : Nat,
    take : Nat,
  ) {
    var s0 = b0 ^ roundKeys[0];
    var s1 = b1 ^ roundKeys[1];
    var s2 = b2 ^ roundKeys[2];
    var s3 = b3 ^ roundKeys[3];
    var s4 = b4 ^ roundKeys[4];
    var s5 = b5 ^ roundKeys[5];
    var s6 = b6 ^ roundKeys[6];
    var s7 = b7 ^ roundKeys[7];
    var s8 = b8 ^ roundKeys[8];
    var s9 = b9 ^ roundKeys[9];
    var s10 = b10 ^ roundKeys[10];
    var s11 = b11 ^ roundKeys[11];
    var s12 = b12 ^ roundKeys[12];
    var s13 = b13 ^ roundKeys[13];
    var s14 = b14 ^ roundKeys[14];
    var s15 = b15 ^ roundKeys[15];

    var round : Nat = 1;
    while (round < 10) {
      let r = round * 16;

      let c0 = sbox[Nat8.toNat(s0)];
      let c1 = sbox[Nat8.toNat(s5)];
      let c2 = sbox[Nat8.toNat(s10)];
      let c3 = sbox[Nat8.toNat(s15)];
      let d0 = xtime(c0);
      let d1 = xtime(c1);
      let d2 = xtime(c2);
      let d3 = xtime(c3);
      let n0 = d0 ^ (d1 ^ c1) ^ c2 ^ c3 ^ roundKeys[r];
      let n1 = c0 ^ d1 ^ (d2 ^ c2) ^ c3 ^ roundKeys[r + 1];
      let n2 = c0 ^ c1 ^ d2 ^ (d3 ^ c3) ^ roundKeys[r + 2];
      let n3 = (d0 ^ c0) ^ c1 ^ c2 ^ d3 ^ roundKeys[r + 3];

      let c4 = sbox[Nat8.toNat(s4)];
      let c5 = sbox[Nat8.toNat(s9)];
      let c6 = sbox[Nat8.toNat(s14)];
      let c7 = sbox[Nat8.toNat(s3)];
      let d4 = xtime(c4);
      let d5 = xtime(c5);
      let d6 = xtime(c6);
      let d7 = xtime(c7);
      let n4 = d4 ^ (d5 ^ c5) ^ c6 ^ c7 ^ roundKeys[r + 4];
      let n5 = c4 ^ d5 ^ (d6 ^ c6) ^ c7 ^ roundKeys[r + 5];
      let n6 = c4 ^ c5 ^ d6 ^ (d7 ^ c7) ^ roundKeys[r + 6];
      let n7 = (d4 ^ c4) ^ c5 ^ c6 ^ d7 ^ roundKeys[r + 7];

      let c8 = sbox[Nat8.toNat(s8)];
      let c9 = sbox[Nat8.toNat(s13)];
      let c10 = sbox[Nat8.toNat(s2)];
      let c11 = sbox[Nat8.toNat(s7)];
      let d8 = xtime(c8);
      let d9 = xtime(c9);
      let d10 = xtime(c10);
      let d11 = xtime(c11);
      let n8 = d8 ^ (d9 ^ c9) ^ c10 ^ c11 ^ roundKeys[r + 8];
      let n9 = c8 ^ d9 ^ (d10 ^ c10) ^ c11 ^ roundKeys[r + 9];
      let n10 = c8 ^ c9 ^ d10 ^ (d11 ^ c11) ^ roundKeys[r + 10];
      let n11 = (d8 ^ c8) ^ c9 ^ c10 ^ d11 ^ roundKeys[r + 11];

      let c12 = sbox[Nat8.toNat(s12)];
      let c13 = sbox[Nat8.toNat(s1)];
      let c14 = sbox[Nat8.toNat(s6)];
      let c15 = sbox[Nat8.toNat(s11)];
      let d12 = xtime(c12);
      let d13 = xtime(c13);
      let d14 = xtime(c14);
      let d15 = xtime(c15);
      let n12 = d12 ^ (d13 ^ c13) ^ c14 ^ c15 ^ roundKeys[r + 12];
      let n13 = c12 ^ d13 ^ (d14 ^ c14) ^ c15 ^ roundKeys[r + 13];
      let n14 = c12 ^ c13 ^ d14 ^ (d15 ^ c15) ^ roundKeys[r + 14];
      let n15 = (d12 ^ c12) ^ c13 ^ c14 ^ d15 ^ roundKeys[r + 15];

      s0 := n0;
      s1 := n1;
      s2 := n2;
      s3 := n3;
      s4 := n4;
      s5 := n5;
      s6 := n6;
      s7 := n7;
      s8 := n8;
      s9 := n9;
      s10 := n10;
      s11 := n11;
      s12 := n12;
      s13 := n13;
      s14 := n14;
      s15 := n15;

      round += 1;
    };

    writeBlock(
      out,
      outOffset,
      skip,
      take,
      sbox[Nat8.toNat(s0)] ^ roundKeys[160],
      sbox[Nat8.toNat(s5)] ^ roundKeys[161],
      sbox[Nat8.toNat(s10)] ^ roundKeys[162],
      sbox[Nat8.toNat(s15)] ^ roundKeys[163],
      sbox[Nat8.toNat(s4)] ^ roundKeys[164],
      sbox[Nat8.toNat(s9)] ^ roundKeys[165],
      sbox[Nat8.toNat(s14)] ^ roundKeys[166],
      sbox[Nat8.toNat(s3)] ^ roundKeys[167],
      sbox[Nat8.toNat(s8)] ^ roundKeys[168],
      sbox[Nat8.toNat(s13)] ^ roundKeys[169],
      sbox[Nat8.toNat(s2)] ^ roundKeys[170],
      sbox[Nat8.toNat(s7)] ^ roundKeys[171],
      sbox[Nat8.toNat(s12)] ^ roundKeys[172],
      sbox[Nat8.toNat(s1)] ^ roundKeys[173],
      sbox[Nat8.toNat(s6)] ^ roundKeys[174],
      sbox[Nat8.toNat(s11)] ^ roundKeys[175],
    );
  };

  func writeBlock(
    out : [var Nat8],
    outOffset : Nat,
    skip : Nat,
    take : Nat,
    o0 : Nat8, o1 : Nat8, o2 : Nat8, o3 : Nat8,
    o4 : Nat8, o5 : Nat8, o6 : Nat8, o7 : Nat8,
    o8 : Nat8, o9 : Nat8, o10 : Nat8, o11 : Nat8,
    o12 : Nat8, o13 : Nat8, o14 : Nat8, o15 : Nat8,
  ) {
    var i = skip;
    var written : Nat = 0;
    while (i < 16 and written < take) {
      let value : Nat8 = switch (i) {
        case (0) o0;
        case (1) o1;
        case (2) o2;
        case (3) o3;
        case (4) o4;
        case (5) o5;
        case (6) o6;
        case (7) o7;
        case (8) o8;
        case (9) o9;
        case (10) o10;
        case (11) o11;
        case (12) o12;
        case (13) o13;
        case (14) o14;
        case (15) o15;
        case (_) 0;
      };
      out[outOffset + written] := value;
      i += 1;
      written += 1;
    };
  };

  public func ctr32be(key : [Nat8], outputLen : Nat) : [Nat8] {
    if (key.size() != 16) {
      return [];
    };
    let roundKeys = expandKey(key);
    let out = VarArray.repeat<Nat8>(0, outputLen);
    let counter = VarArray.repeat<Nat8>(0, 16);
    var produced : Nat = 0;
    while (produced < outputLen) {
      let take = if (outputLen - produced < 16) outputLen - produced else 16;
      encryptCounterInto(roundKeys, counter, out, produced, 0, take);
      produced += take;
      incrementCounter32be(counter);
    };
    Array.fromVarArray(out);
  };

  public func ctr32beSplit(key : [Nat8], firstLen : Nat, secondLen : Nat) : ?SplitStream {
    if (key.size() != 16) {
      return null;
    };
    let roundKeys = expandKey(key);
    let first = VarArray.repeat<Nat8>(0, firstLen);
    let second = VarArray.repeat<Nat8>(0, secondLen);
    let counter = VarArray.repeat<Nat8>(0, 16);
    let totalLen = firstLen + secondLen;

    var produced : Nat = 0;
    while (produced < totalLen) {
      let take = if (totalLen - produced < 16) totalLen - produced else 16;
      if (produced + take <= firstLen) {
        encryptCounterInto(roundKeys, counter, first, produced, 0, take);
      } else if (produced >= firstLen) {
        encryptCounterInto(roundKeys, counter, second, produced - firstLen, 0, take);
      } else {
        let firstTake = firstLen - produced;
        encryptCounterInto(roundKeys, counter, first, produced, 0, firstTake);
        encryptCounterInto(roundKeys, counter, second, 0, firstTake, take - firstTake);
      };
      produced += take;
      incrementCounter32be(counter);
    };

    ?{
      first = Array.fromVarArray(first);
      second = Array.fromVarArray(second);
    };
  };

  public func ctr32beAt(key : [Nat8], byteOffset : Nat, outputLen : Nat) : [Nat8] {
    if (key.size() != 16) {
      return [];
    };
    let roundKeys = expandKey(key);
    let out = VarArray.repeat<Nat8>(0, outputLen);
    let counter = VarArray.repeat<Nat8>(0, 16);
    setCounter32be(counter, byteOffset / 16);

    var produced : Nat = 0;
    var skip : Nat = byteOffset % 16;
    while (produced < outputLen) {
      let available = 16 - skip;
      let take = if (outputLen - produced < available) outputLen - produced else available;
      encryptCounterInto(roundKeys, counter, out, produced, skip, take);
      produced += take;
      skip := 0;
      incrementCounter32be(counter);
    };
    Array.fromVarArray(out);
  };

  func expandKey(key : [Nat8]) : [Nat8] {
    let expanded = VarArray.repeat<Nat8>(0, 176);
    var i : Nat = 0;
    while (i < 16) {
      expanded[i] := key[i];
      i += 1;
    };

    var bytesGenerated : Nat = 16;
    var rconIter : Nat = 1;
    let temp = VarArray.repeat<Nat8>(0, 4);

    while (bytesGenerated < 176) {
      i := 0;
      while (i < 4) {
        temp[i] := expanded[bytesGenerated - 4 + i];
        i += 1;
      };

      if (bytesGenerated % 16 == 0) {
        let t = temp[0];
        temp[0] := temp[1];
        temp[1] := temp[2];
        temp[2] := temp[3];
        temp[3] := t;
        i := 0;
        while (i < 4) {
          temp[i] := sbox[Nat8.toNat(temp[i])];
          i += 1;
        };
        temp[0] ^= rcon[rconIter];
        rconIter += 1;
      };

      i := 0;
      while (i < 4) {
        expanded[bytesGenerated] := expanded[bytesGenerated - 16] ^ temp[i];
        bytesGenerated += 1;
        i += 1;
      };
    };

    Array.fromVarArray(expanded);
  };

  func addRoundKey(state : [var Nat8], roundKeys : [Nat8], round : Nat) {
    let base = round * 16;
    var i : Nat = 0;
    while (i < 16) {
      state[i] ^= roundKeys[base + i];
      i += 1;
    };
  };

  func subBytes(state : [var Nat8]) {
    var i : Nat = 0;
    while (i < 16) {
      state[i] := sbox[Nat8.toNat(state[i])];
      i += 1;
    };
  };

  func shiftRows(state : [var Nat8]) {
    let t1 = state[1];
    state[1] := state[5];
    state[5] := state[9];
    state[9] := state[13];
    state[13] := t1;

    let t2 = state[2];
    let t6 = state[6];
    state[2] := state[10];
    state[6] := state[14];
    state[10] := t2;
    state[14] := t6;

    let t3 = state[3];
    state[3] := state[15];
    state[15] := state[11];
    state[11] := state[7];
    state[7] := t3;
  };

  func mixColumns(state : [var Nat8]) {
    var c : Nat = 0;
    while (c < 4) {
      let i = c * 4;
      let a0 = state[i];
      let a1 = state[i + 1];
      let a2 = state[i + 2];
      let a3 = state[i + 3];
      let t = a0 ^ a1 ^ a2 ^ a3;
      let u = a0;
      state[i] ^= t ^ xtime(a0 ^ a1);
      state[i + 1] ^= t ^ xtime(a1 ^ a2);
      state[i + 2] ^= t ^ xtime(a2 ^ a3);
      state[i + 3] ^= t ^ xtime(a3 ^ u);
      c += 1;
    };
  };

  func xtime(x : Nat8) : Nat8 {
    let shifted = x << 1;
    if ((x & 0x80) != 0) shifted ^ 0x1b else shifted;
  };

  func incrementCounter32be(counter : [var Nat8]) {
    var idx : Nat = 15;
    label L loop {
      counter[idx] +%= 1;
      if (counter[idx] != 0 or idx == 12) {
        break L;
      };
      idx -= 1;
    };
  };

  func setCounter32be(counter : [var Nat8], value : Nat) {
    counter[12] := Nat8.fromNat((value / 16_777_216) % 256);
    counter[13] := Nat8.fromNat((value / 65_536) % 256);
    counter[14] := Nat8.fromNat((value / 256) % 256);
    counter[15] := Nat8.fromNat(value % 256);
  };
};
