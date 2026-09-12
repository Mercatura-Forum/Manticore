/// Compact Merkle Mountain Range accumulator for append-only audit evidence.
///
/// This stores only peaks. It gives a rolling append-only root suitable for
/// checkpointing. Full historical proof generation still requires leaf or node
/// history; the canister keeps the existing audit Merkle proof API for that.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import InPlaceSha256d "InPlaceSha256d";

module {

  public type State = {
    leafCount : Nat;
    peaks : [?Blob];
  };

  public let MAX_HEIGHT : Nat = 64;

  public func empty() : State {
    { leafCount = 0; peaks = Array.tabulate<?Blob>(MAX_HEIGHT, func(_) { null }) };
  };

  public func append(state : State, leaf : Blob) : State {
    var peaks = state.peaks;
    var current = hashLeaf(leaf);
    var height = 0;
    while (height < MAX_HEIGHT) {
      switch (peaks[height]) {
        case (?existing) {
          current := hashNode(existing, current);
          peaks := replace(peaks, height, null);
          height += 1;
        };
        case null {
          peaks := replace(peaks, height, ?current);
          return { leafCount = state.leafCount + 1; peaks };
        };
      };
    };
    { leafCount = state.leafCount + 1; peaks };
  };

  public func root(state : State) : ?Blob {
    var result : ?Blob = null;
    var h = MAX_HEIGHT;
    while (h > 0) {
      h -= 1;
      switch (state.peaks[h]) {
        case (?peak) {
          result := switch (result) {
            case null ?peak;
            case (?acc) ?hashNode(peak, acc);
          };
        };
        case null {};
      };
    };
    result;
  };

  public func peakCount(state : State) : Nat {
    var count = 0;
    for (peak in state.peaks.vals()) {
      switch (peak) { case (?_) count += 1; case null {} };
    };
    count;
  };

  func replace(xs : [?Blob], idx : Nat, value : ?Blob) : [?Blob] {
    Array.tabulate<?Blob>(xs.size(), func(i) { if (i == idx) value else xs[i] });
  };

  func hashLeaf(leaf : Blob) : Blob {
    hashBytes(Array.concat<Nat8>([0x00], Blob.toArray(leaf)));
  };

  func hashNode(left : Blob, right : Blob) : Blob {
    var bytes : [Nat8] = [0x01];
    bytes := appendBlob(bytes, left);
    bytes := appendBlob(bytes, right);
    hashBytes(bytes);
  };

  func hashBytes(bytes : [Nat8]) : Blob {
    let hasher = InPlaceSha256d.Hasher();
    Blob.fromArray(hasher.sha256General(bytes));
  };

  func appendBlob(base : [Nat8], value : Blob) : [Nat8] {
    Array.concat<Nat8>(appendNat(base, value.size()), Blob.toArray(value));
  };

  func appendNat(base : [Nat8], n : Nat) : [Nat8] {
    if (n == 0) {
      return Array.concat<Nat8>(base, [1 : Nat8, 0 : Nat8]);
    };
    var tmp = n;
    var byteCount : Nat = 0;
    while (tmp > 0) {
      tmp /= 256;
      byteCount += 1;
    };
    let bytes = Array.tabulate<Nat8>(byteCount, func(i) {
      Nat8.fromNat((n / (256 ** (byteCount - 1 - i))) % 256);
    });
    Array.concat<Nat8>(Array.concat<Nat8>(base, [Nat8.fromNat(byteCount)]), bytes);
  };
};
