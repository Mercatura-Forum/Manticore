/// RegionStore.mo — an append-only byte store in one Region.
///
/// What a pack's bytes and its per-account posting lists are kept in: appended once, read by
/// offset and length, never rewritten. A store can be **reset** to be filled again — a Region is
/// never given back to the system, so a pack that has rolled to an archive leaves its store to the
/// next pack rather than an empty region behind it.

import Region "mo:core/Region";
import Nat64 "mo:core/Nat64";

module {

  public type State = { region : Region.Region; var bytes : Nat };

  let PAGE : Nat64 = 65_536;

  public func newState() : State { { region = Region.new(); var bytes = 0 } };

  public func size(s : State) : Nat { s.bytes };

  public func reset(s : State) { s.bytes := 0 };

  func ensure(s : State, upTo : Nat) {
    let need = (Nat64.fromNat(upTo) + PAGE - 1) / PAGE;
    let have = Region.size(s.region);
    if (need > have) {
      let got = Region.grow(s.region, need - have);
      assert (got != 0xFFFF_FFFF_FFFF_FFFF);
    };
  };

  /// Append, and say where it landed.
  public func append(s : State, data : Blob) : Nat {
    let at = s.bytes;
    if (data.size() > 0) {
      ensure(s, at + data.size());
      Region.storeBlob(s.region, Nat64.fromNat(at), data);
      s.bytes += data.size();
    };
    at
  };

  public func read(s : State, offset : Nat, len : Nat) : Blob {
    assert (offset + len <= s.bytes);
    if (len == 0) return "" : Blob;
    Region.loadBlob(s.region, Nat64.fromNat(offset), len)
  };

  /// The pages the region holds — what it costs, whatever `bytes` says.
  public func pages(s : State) : Nat { Nat64.toNat(Region.size(s.region)) };
}
