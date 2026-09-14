/// Base64.mo; RFC 4648 base64 and base64url, with and without padding, strict on decode.

import Blob "mo:core/Blob";
import Char "mo:core/Char";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";

module {

  let STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

  func encodeWith(alphabet : Text, bytes : Blob, pad : Bool) : Text {
    let a = Text.toArray(alphabet);
    let b = Blob.toArray(bytes);
    var out = "";
    var i = 0;
    while (i < b.size()) {
      let b0 = Nat8.toNat(b[i]);
      let b1 = if (i + 1 < b.size()) Nat8.toNat(b[i + 1]) else 0;
      let b2 = if (i + 2 < b.size()) Nat8.toNat(b[i + 2]) else 0;
      out #= Char.toText(a[b0 / 4]);
      out #= Char.toText(a[(b0 % 4) * 16 + b1 / 16]);
      if (i + 1 < b.size()) out #= Char.toText(a[(b1 % 16) * 4 + b2 / 64]) else if (pad) out #= "=";
      if (i + 2 < b.size()) out #= Char.toText(a[b2 % 64]) else if (pad) out #= "=";
      i += 3;
    };
    out
  };

  func decodeWith(alphabet : Text, text : Text) : ?Blob {
    let a = Text.toArray(alphabet);
    func val(c : Char) : ?Nat { var i = 0; while (i < 64) { if (a[i] == c) return ?i; i += 1 }; null };
    let cs = Iter.toArray(Text.trimEnd(text, #char '=').chars());
    if (cs.size() % 4 == 1) return null;
    let out = List.empty<Nat8>();
    var i = 0;
    while (i < cs.size()) {
      let ?v0 = val(cs[i]) else return null;
      let ?v1 = (if (i + 1 < cs.size()) val(cs[i + 1]) else ?0) else return null;
      let ?v2 = (if (i + 2 < cs.size()) val(cs[i + 2]) else ?0) else return null;
      let ?v3 = (if (i + 3 < cs.size()) val(cs[i + 3]) else ?0) else return null;
      List.add(out, Nat8.fromNat(v0 * 4 + v1 / 16));
      if (i + 2 < cs.size()) List.add(out, Nat8.fromNat((v1 % 16) * 16 + v2 / 4)) else if (v1 % 16 != 0) return null;   // trailing bits must be zero
      if (i + 3 < cs.size()) List.add(out, Nat8.fromNat((v2 % 4) * 64 + v3)) else if (i + 2 < cs.size() and v2 % 4 != 0) return null;
      i += 4;
    };
    ?Blob.fromArray(List.toArray(out))
  };

  public func encode(b : Blob) : Text { encodeWith(STD, b, true) };
  public func decode(t : Text) : ?Blob { decodeWith(STD, t) };
  /// base64url without padding; FSPIOP's IlpCondition and IlpFulfilment (43 characters for 32 bytes).
  public func encodeUrl(b : Blob) : Text { encodeWith(URL, b, false) };
  public func decodeUrl(t : Text) : ?Blob { decodeWith(URL, t) };

}
