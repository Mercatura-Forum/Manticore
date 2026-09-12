import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import VarArray "mo:core/VarArray";

module {
  let RC : [Nat64] = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
  ];

  let ROT : [Nat64] = [
     0,  1, 62, 28, 27,
    36, 44,  6, 55, 20,
     3, 10, 43, 25, 39,
    41, 45, 15, 21,  8,
    18,  2, 61, 56, 14,
  ];

  let PI : [Nat] = [
     0, 10, 20,  5, 15,
    16,  1, 11, 21,  6,
     7, 17,  2, 12, 22,
    23,  8, 18,  3, 13,
    14, 24,  9, 19,  4,
  ];

  func rotl64(x : Nat64, n : Nat64) : Nat64 {
    if (n == 0) x else (x << n) | (x >> (64 - n));
  };

  public func keccakF(state : [var Nat64]) {
    let c = VarArray.repeat<Nat64>(0, 5);
    let d = VarArray.repeat<Nat64>(0, 5);
    let b = VarArray.repeat<Nat64>(0, 25);

    var round : Nat = 0;
    while (round < 24) {
      var x : Nat = 0;
      while (x < 5) {
        c[x] := state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20];
        x += 1;
      };

      x := 0;
      while (x < 5) {
        d[x] := c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1);
        x += 1;
      };

      x := 0;
      while (x < 25) {
        state[x] ^= d[x % 5];
        x += 1;
      };

      x := 0;
      while (x < 25) {
        b[PI[x]] := rotl64(state[x], ROT[x]);
        x += 1;
      };

      x := 0;
      while (x < 25) {
        state[x] := b[x] ^ ((^b[(x / 5) * 5 + (x + 1) % 5]) & b[(x / 5) * 5 + (x + 2) % 5]);
        x += 1;
      };

      state[0] ^= RC[round];
      round += 1;
    };
  };

  public func shake256(input : [Nat8], outputLen : Nat) : [Nat8] {
    shake(input, outputLen, 136);
  };

  public func shake128(input : [Nat8], outputLen : Nat) : [Nat8] {
    shake(input, outputLen, 168);
  };

  func shake(input : [Nat8], outputLen : Nat, rate : Nat) : [Nat8] {
    let state = VarArray.repeat<Nat64>(0, 25);

    var absorbed : Nat = 0;
    while (absorbed + rate <= input.size()) {
      xorBlock(state, input, absorbed, rate);
      keccakF(state);
      absorbed += rate;
    };

    let remaining = input.size() - absorbed;
    let padBlock = VarArray.repeat<Nat8>(0, rate);
    var i : Nat = 0;
    while (i < remaining) {
      padBlock[i] := input[absorbed + i];
      i += 1;
    };
    padBlock[remaining] := 0x1F;
    padBlock[rate - 1] := padBlock[rate - 1] | 0x80;
    xorBlock(state, Array.fromVarArray(padBlock), 0, rate);
    keccakF(state);

    let output = VarArray.repeat<Nat8>(0, outputLen);
    var produced : Nat = 0;
    while (produced < outputLen) {
      let toExtract = Nat.min(rate, outputLen - produced);
      extractBytes(state, output, produced, toExtract);
      produced += toExtract;
      if (produced < outputLen) {
        keccakF(state);
      };
    };

    Array.fromVarArray(output);
  };

  func xorBlock(state : [var Nat64], data : [Nat8], offset : Nat, len : Nat) {
    var i : Nat = 0;
    while (i * 8 < len) {
      var lane : Nat64 = 0;
      var j : Nat = 0;
      while (j < 8 and i * 8 + j < len) {
        lane |= Nat64.fromNat(Nat8.toNat(data[offset + i * 8 + j])) << Nat64.fromNat(j * 8);
        j += 1;
      };
      state[i] ^= lane;
      i += 1;
    };
  };

  func extractBytes(state : [var Nat64], output : [var Nat8], offset : Nat, len : Nat) {
    var i : Nat = 0;
    while (i * 8 < len) {
      let lane = state[i];
      var j : Nat = 0;
      while (j < 8 and i * 8 + j < len) {
        output[offset + i * 8 + j] := Nat8.fromNat(Nat64.toNat((lane >> Nat64.fromNat(j * 8)) & 0xFF));
        j += 1;
      };
      i += 1;
    };
  };
};
