/// ByteBuf.mo — a growable byte buffer on a mutable array.
///
/// Every row, key and block in this family is built byte by byte, and the measured runs found the
/// building to be the cost of a posting: a `List<Nat8>` boxes and chunks, and `List.toArray` then
/// `Blob.fromArray` copy twice — 53,000 instructions for a 250-byte block, 13,000 for an 8-byte
/// big-endian number. This buffer is a `[var Nat8]` that doubles, and `toBlob` is one copy.

import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Runtime "mo:core/Runtime";
import VarArray "mo:core/VarArray";

module {

  public class ByteBuf(initial : Nat) {
    var bytes : [var Nat8] = VarArray.repeat<Nat8>(0, if (initial == 0) 32 else initial);
    var len : Nat = 0;

    func grow(need : Nat) {
      if (need <= bytes.size()) return;
      var cap = bytes.size() * 2;
      while (cap < need) cap *= 2;
      let bigger = VarArray.repeat<Nat8>(0, cap);
      var i = 0;
      while (i < len) { bigger[i] := bytes[i]; i += 1 };
      bytes := bigger;
    };

    public func size() : Nat { len };

    public func add(b : Nat8) {
      if (len == bytes.size()) grow(len + 1);
      bytes[len] := b;
      len += 1;
    };

    public func addArray(a : [Nat8]) {
      grow(len + a.size());
      for (b in a.vals()) { bytes[len] := b; len += 1 };
    };

    public func addBlob(b : Blob) {
      grow(len + b.size());
      for (x in b.vals()) { bytes[len] := x; len += 1 };
    };

    /// A big-endian number of `width` bytes; refused when it does not fit.
    public func addBE(value : Nat, width : Nat) {
      grow(len + width);
      if (value < 18_446_744_073_709_551_616) {
        var v = Nat64.fromNat(value);
        var i = width;
        while (i > 0) { i -= 1; bytes[len + i] := Nat8.fromNat(Nat64.toNat(v % 256)); v /= 256 };
        if (v > 0) Runtime.trap("ByteBuf: " # debug_show (value) # " does not fit in " # debug_show (width) # " bytes");
      } else {
        var v = value;
        var i = width;
        while (i > 0) { i -= 1; bytes[len + i] := Nat8.fromNat(v % 256); v /= 256 };
        if (v > 0) Runtime.trap("ByteBuf: a number does not fit in " # debug_show (width) # " bytes");
      };
      len += width;
    };

    public func get(i : Nat) : Nat8 { bytes[i] };
    public func set(i : Nat, b : Nat8) { bytes[i] := b };

    /// The bytes so far, as a blob: one copy.
    public func toBlob() : Blob {
      if (len == bytes.size()) return Blob.fromVarArray(bytes);
      let out = VarArray.repeat<Nat8>(0, len);
      var i = 0;
      while (i < len) { out[i] := bytes[i]; i += 1 };
      Blob.fromVarArray(out)
    };

    public func toArray() : [Nat8] { Blob.toArray(toBlob()) };
  };

  /// Big-endian, fixed width, as an immutable array — the key parts every index is built from.
  public func be(value : Nat, width : Nat) : [Nat8] {
    let b = ByteBuf(width);
    b.addBE(value, width);
    b.toArray()
  };
}
