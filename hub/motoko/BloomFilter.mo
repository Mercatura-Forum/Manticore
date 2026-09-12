/// Small immutable Bloom filter for advisory duplicate detection.
///
/// False positives are possible, so callers must fall back to an exact index
/// before rejecting a payment. False negatives are not expected for values
/// added to the same filter instance.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";

module {

  public type Filter = [Bool];

  public let BITS : Nat = 4096;
  public let HASHES : Nat = 5;

  public func empty() : Filter {
    Array.tabulate<Bool>(BITS, func(_) { false });
  };

  public func add(filter : Filter, key : Text) : Filter {
    var next = filter;
    var i = 0;
    while (i < HASHES) {
      next := set(next, index(key, i));
      i += 1;
    };
    next;
  };

  public func mightContain(filter : Filter, key : Text) : Bool {
    var i = 0;
    while (i < HASHES) {
      if (not filter[index(key, i)]) return false;
      i += 1;
    };
    true;
  };

  public func fillRatioPermille(filter : Filter) : Nat {
    var setBits = 0;
    for (bit in filter.vals()) {
      if (bit) setBits += 1;
    };
    (setBits * 1000) / filter.size();
  };

  func set(filter : Filter, bit : Nat) : Filter {
    Array.tabulate<Bool>(filter.size(), func(i) { if (i == bit) true else filter[i] });
  };

  func index(key : Text, seed : Nat) : Nat {
    var h = 2_166_136_261 + (seed * 16_777_619);
    for (b in Blob.toArray(Text.encodeUtf8(key)).vals()) {
      h := ((h * 16_777_619) + Nat8.toNat(b) + seed + 1) % BITS;
    };
    h;
  };
};
