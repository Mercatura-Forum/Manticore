/// StableRows.mo — the byte helpers every fixed-width row in this component is built from.
///
/// A row in a `RegionIndex` is a fixed number of bytes, and the shape used throughout the bank is
/// the same: the record is its block in the log, and the row carries the mutable facts and pointers
/// (block indices) to the blocks that changed them. Every number is big-endian so a key made of them
/// sorts as the numbers do, which is what lets one composite key serve a range.
///
/// Widths are declared where the row is declared; these helpers only refuse a value that does not
/// fit, because a silently truncated pointer is a wrong block, not a smaller one.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Runtime "mo:core/Runtime";

import ByteBuf "mo:ledger/ByteBuf";

module {

  public type Buf = ByteBuf.ByteBuf;

  public func buf() : Buf { ByteBuf.ByteBuf(96) };

  public func putNat(b : Buf, value : Nat, width : Nat) { b.addBE(value, width) };

  public func putByte(b : Buf, v : Nat8) { b.add(v) };

  public func putBool(b : Buf, v : Bool) { b.add(if (v) (1 : Nat8) else (0 : Nat8)) };

  /// Text as a fixed-width field: the bytes, right-padded with zeros. Refused past the width.
  public func putText(b : Buf, t : Text, width : Nat) {
    let bytes = Text.encodeUtf8(t);
    if (bytes.size() > width) Runtime.trap("StableRows: text of " # Nat.toText(bytes.size()) # " bytes in a " # Nat.toText(width) # "-byte field");
    b.addBlob(bytes);
    var i = bytes.size();
    while (i < width) { b.add(0 : Nat8); i += 1 };
  };

  public func putBlob(b : Buf, x : Blob, width : Nat) {
    if (x.size() != width) Runtime.trap("StableRows: a blob of " # Nat.toText(x.size()) # " bytes in a " # Nat.toText(width) # "-byte field");
    b.addBlob(x);
  };

  public func done(b : Buf, width : Nat) : Blob {
    if (b.size() != width) Runtime.trap("StableRows: a row of " # Nat.toText(b.size()) # " bytes where " # Nat.toText(width) # " was declared");
    b.toBlob()
  };

  public func getNat(a : [Nat8], off : Nat, width : Nat) : Nat {
    var v = 0;
    var i = 0;
    while (i < width) { v := v * 256 + Nat8.toNat(a[off + i]); i += 1 };
    v
  };

  public func getBool(a : [Nat8], off : Nat) : Bool { a[off] != 0 };

  /// A padded text field back to text: up to the first zero byte.
  public func getText(a : [Nat8], off : Nat, width : Nat) : Text {
    var n = 0;
    while (n < width and a[off + n] != 0) n += 1;
    switch (Text.decodeUtf8(Blob.fromArray(Array.tabulate<Nat8>(n, func(i) { a[off + i] })))) {
      case (?t) t;
      case null Runtime.trap("StableRows: a text field that is not UTF-8");
    }
  };

  public func getBlob(a : [Nat8], off : Nat, width : Nat) : Blob {
    Blob.fromArray(Array.tabulate<Nat8>(width, func(i) { a[off + i] }))
  };

  /// A key of one big-endian number.
  public func key(value : Nat, width : Nat) : Blob {
    let b = buf();
    putNat(b, value, width);
    done(b, width)
  };

  /// A key of two big-endian numbers.
  public func key2(a : Nat, wa : Nat, b : Nat, wb : Nat) : Blob {
    let buf_ = buf();
    putNat(buf_, a, wa);
    putNat(buf_, b, wb);
    done(buf_, wa + wb)
  };

  /// A text key, padded to the width. Two texts that agree on the first `width` bytes would be one
  /// key, so a caller declares a width its texts are bounded by.
  public func textKey(t : Text, width : Nat) : Blob {
    let b = buf();
    putText(b, t, width);
    done(b, width)
  };

  /// The ends of a prefix range over a two-part key: the prefix, then all zeros and all 0xFF.
  public func prefixRange(prefix : Nat, wp : Nat, rest : Nat) : (Blob, Blob) {
    let lo = buf();
    let hi = buf();
    putNat(lo, prefix, wp);
    putNat(hi, prefix, wp);
    var i = 0;
    while (i < rest) { lo.add(0 : Nat8); hi.add(255 : Nat8); i += 1 };
    (done(lo, wp + rest), done(hi, wp + rest))
  };

  /// The whole key space of a width.
  public func fullRange(width : Nat) : (Blob, Blob) {
    (Blob.fromArray(Array.tabulate<Nat8>(width, func(_) { 0 })), Blob.fromArray(Array.tabulate<Nat8>(width, func(_) { 255 })))
  };
}
