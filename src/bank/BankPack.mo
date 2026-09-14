/// BankPack.mo; a closed range of bank blocks as one segment: every block's stored bytes kept whole
/// except the trailer a settled proposal may lose, with a table of offsets so one block is one read.
///
/// The bank-log ruling of 12 September (measure 2) packs the bank log by closed month in the journal's
/// `packStores` shape: segments in a pooled store, sealed under a hash, rolled to an archive later. The
/// bank's blocks are not postings; there are no columns to dictionary-code, and a party, an account
/// or a settled proposal is read by its block index on every operation that touches it; so a bank
/// segment keeps each block's bytes as the log stored them (the preimage and its hash: the chain and
/// the MMR are over these) and drops only what §18.2 lets it drop: the trailer body of an executed
/// proposal whose reconstruction hashes to the kept hash, replaced by the empty-trailer byte, which is
/// itself a valid format-2 block. Losslessness is checked, not asserted: `pack` unpacks its own output
/// and compares every block with the bytes it was given, the dropped trailers excepted by design.
///
/// ```
/// "TBBP" ‖ version(1) ‖ lo(8) ‖ count(4) ‖ offsets: count × (offset(4) from the segment's start) ‖ blocks: bytes …
/// ```
///
/// A block's length is the distance to the next offset (the segment's end for the last): the table is
/// the only per-block cost, four bytes.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Result "mo:core/Result";

module {

  public let VERSION : Nat8 = 1;
  let MAGIC : [Nat8] = [0x54, 0x42, 0x42, 0x50];   // "TBBP"
  let HEADER : Nat = 17;   // magic(4) version(1) lo(8) count(4)

  /// One block as the packer receives it: its stored bytes, and the bytes to keep (the same, or the
  /// preimage and hash with the empty trailer when the body is dropped).
  public type Entry = { raw : Blob; keep : Blob };

  public type Packed = { bytes : Blob; count : Nat; rawBytes : Nat; dropped : Nat };

  func be32(n : Nat) : [Nat8] { let v = Nat32.fromNat(n); [Nat8.fromNat(Nat32.toNat(v >> 24)), Nat8.fromNat(Nat32.toNat((v >> 16) & 0xFF)), Nat8.fromNat(Nat32.toNat((v >> 8) & 0xFF)), Nat8.fromNat(Nat32.toNat(v & 0xFF))] };
  func be64(n : Nat) : [Nat8] { let v = Nat64.fromNat(n); Array.tabulate<Nat8>(8, func(i) { Nat8.fromNat(Nat64.toNat((v >> Nat64.fromNat(8 * (7 - i))) & 0xFF)) }) };
  func rd32(a : [Nat8], at : Nat) : Nat { Nat8.toNat(a[at]) * 16_777_216 + Nat8.toNat(a[at + 1]) * 65_536 + Nat8.toNat(a[at + 2]) * 256 + Nat8.toNat(a[at + 3]) };
  func rd64(a : [Nat8], at : Nat) : Nat { var n = 0; for (i in Nat.range(0, 8)) { n := n * 256 + Nat8.toNat(a[at + i]) }; n };

  /// The segment for blocks `lo`, `lo + 1`, … in the order given; refused (with the block that broke
  /// it) unless its own unpacking gives back every block's kept bytes.
  public func pack(lo : Nat, entries : [Entry]) : Result.Result<Packed, Text> {
    if (entries.size() == 0) return #err("a segment holds at least one block");
    if (entries.size() > 0xFFFF_FFFF) return #err("too many blocks for one segment");
    let out = List.empty<Nat8>();
    for (b in MAGIC.vals()) List.add(out, b);
    List.add(out, VERSION);
    for (b in be64(lo).vals()) List.add(out, b);
    for (b in be32(entries.size()).vals()) List.add(out, b);
    // the offsets table, then the blocks
    var offset = HEADER + 4 * entries.size();
    for (e in entries.vals()) { for (b in be32(offset).vals()) List.add(out, b); offset += e.keep.size() };
    var rawBytes = 0;
    var dropped = 0;
    for (e in entries.vals()) {
      for (b in e.keep.vals()) List.add(out, b);
      rawBytes += e.raw.size();
      if (e.keep.size() != e.raw.size()) dropped += 1;
    };
    let arr = List.toArray(out);
    let bytes = Blob.fromArray(arr);
    // the check: every block reads back as the bytes it was given to keep; over the one array, so the
    // check of a segment of 2,000 blocks allocates the segment once, not once per block
    var i = 0;
    while (i < entries.size()) {
      switch (blockIn(arr, lo + i)) {
        case (?b) { if (b != entries[i].keep) return #err("block " # Nat.toText(lo + i) # " does not round-trip") };
        case null return #err("block " # Nat.toText(lo + i) # " cannot be read back");
      };
      i += 1;
    };
    #ok({ bytes; count = entries.size(); rawBytes; dropped })
  };

  /// The range a segment covers: (lo, count).
  public func header(bytes : Blob) : ?{ lo : Nat; count : Nat } { headerIn(Blob.toArray(bytes)) };
  func headerIn(a : [Nat8]) : ?{ lo : Nat; count : Nat } {
    if (a.size() < HEADER) return null;
    for (i in Nat.range(0, 4)) { if (a[i] != MAGIC[i]) return null };
    if (a[4] != VERSION) return null;
    ?{ lo = rd64(a, 5); count = rd32(a, 13) }
  };

  /// One block's stored bytes out of a whole segment, by index.
  public func block(bytes : Blob, index : Nat) : ?Blob { blockIn(Blob.toArray(bytes), index) };
  func blockIn(a : [Nat8], index : Nat) : ?Blob {
    let ?at = locateIn(a, a.size(), index) else return null;
    if (at.offset + at.length > a.size()) return null;
    ?Blob.fromArray(Array.tabulate<Nat8>(at.length, func(i) { a[at.offset + i] }))
  };

  /// Where a block's bytes lie inside a segment, so a store can serve one block without reading the
  /// segment: from the segment's first bytes (header and offsets table) and its total size, the
  /// block's offset and length; the distance to the next offset, or to the end for the last block.
  public func locate(headerAndOffsets : Blob, segmentBytes : Nat, index : Nat) : ?{ offset : Nat; length : Nat } { locateIn(Blob.toArray(headerAndOffsets), segmentBytes, index) };
  func locateIn(a : [Nat8], segmentBytes : Nat, index : Nat) : ?{ offset : Nat; length : Nat } {
    let ?h = headerIn(a) else return null;
    if (index < h.lo or index >= h.lo + h.count) return null;
    let k = index - h.lo;
    if (HEADER + 4 * (k + 1) > a.size()) return null;
    let offset = rd32(a, HEADER + 4 * k);
    let end = if (k + 1 < h.count) { if (HEADER + 4 * (k + 2) > a.size()) return null; rd32(a, HEADER + 4 * (k + 1)) } else segmentBytes;
    if (end < offset or offset < HEADER + 4 * h.count) return null;
    ?{ offset; length = end - offset }
  };

  public func tableBytes(count : Nat) : Nat { HEADER + 4 * count };
}
