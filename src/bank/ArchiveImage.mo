/// ArchiveImage.mo: the child image, in stable memory.
///
/// The rule: "The operator uploads the child wasm into the parent's stable memory once, in chunks,
/// pinned by SHA-256, and the parent installs from there; do not embed it in the parent's own wasm."
/// This is that store. It lives beside the bank's folded state rather than in it, like the posting
/// indexes, because it is bytes rather than a decision: the decision; which hash an archive child
/// runs; is the pin in `ArchiveCore`, recorded in a block, and this region is only where the bytes
/// that must hash to it are kept.
///
/// Nothing here is trusted on the uploader's word. `hash` is computed over what was actually stored,
/// and `Bank.mo` seals only when that equals the pin. An upload is refused past the wire cap rather
/// than attempted: finding out after `create_canister` that the frame does not fit is how a
/// code-less child happens.

import Region "mo:core/Region";
import Blob "mo:core/Blob";
import Nat64 "mo:core/Nat64";
import Result "mo:core/Result";
import Sha256 "mo:sha2/Sha256";

import AT "ArchiveTypes";

module {

  public type State = {
    region : Region.Region;
    var bytes : Nat;
  };

  let PAGE : Nat64 = 65_536;

  public func newState() : State { { region = Region.new(); var bytes = 0 } };

  public func size(s : State) : Nat { s.bytes };

  /// Forget the stored bytes. The region's pages stay allocated and are overwritten by the next
  /// upload; `bytes` is the only authority on what is image and what is stale.
  public func reset(s : State) { s.bytes := 0 };

  func ensure(s : State, upTo : Nat) {
    let need = (Nat64.fromNat(upTo) + PAGE - 1) / PAGE;
    let have = Region.size(s.region);
    if (need > have) {
      let got = Region.grow(s.region, need - have);
      assert (got != 0xFFFF_FFFF_FFFF_FFFF);
    };
  };

  /// Append a chunk. Refused when the result would not fit one install message.
  public func append(s : State, chunk : Blob) : Result.Result<Nat, AT.ArchiveError> {
    if (chunk.size() == 0) return #err(#ImageInvalid({ reason = "an empty chunk" }));
    let after = s.bytes + chunk.size();
    if (after > AT.MAX_IMAGE_BYTES) return #err(#ImageTooLarge({ bytes = after; cap = AT.MAX_IMAGE_BYTES }));
    ensure(s, after);
    Region.storeBlob(s.region, Nat64.fromNat(s.bytes), chunk);
    s.bytes := after;
    #ok(after)
  };

  /// The SHA-256 of the stored bytes, computed in 64 KiB windows so a 1.8 MB image never needs to
  /// be on the heap whole.
  public func hash(s : State) : Blob {
    let d = Sha256.Digest(#sha256);
    var off = 0;
    while (off < s.bytes) {
      let n = if (s.bytes - off > 65_536) 65_536 else s.bytes - off;
      d.writeBlob(Region.loadBlob(s.region, Nat64.fromNat(off), n));
      off += n;
    };
    d.sum()
  };

  /// The stored bytes, whole, for the install frame. Only the install path reads this, once per
  /// install; it is the one place the image has to be in main memory, and it goes out of scope
  /// with the message.
  public func bytes(s : State) : Blob {
    if (s.bytes == 0) return "" : Blob;
    Region.loadBlob(s.region, 0, s.bytes)
  };
}
