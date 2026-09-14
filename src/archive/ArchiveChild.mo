/// ArchiveChild.mo; the archive contract a bank rolls its packed months to.
///
/// What it holds is what `Packing.mo` produced: segments of packed journal blocks, each a
/// self-contained `Pack` that unpacks byte for byte to the blocks it was made from, registered by
/// its SHA-256. The **parent** is the only writer; anyone can read. A segment is acknowledged by
/// calling the parent back (`acknowledgeArchivedSegment`) from the message that stored it; the
/// parent records only what this contract itself said it holds, never what a driver claims; and
/// the store happens **before** the call, so on an engine that drops writes made after an awaited
/// reply nothing is lost.
///
/// Who the parent is: on a parent-spawned child the installer is the parent, and that is the
/// default; a child the operator deployed and the bank adopted is bound to its parent once by the
/// installer (`bind`). Either way the parent is one principal, fixed after the first segment.
///
/// Reads: a segment's bytes and its row; the round trip checked here (`verifySegment`); a raw
/// journal block by absolute index, found by the segment that covers it and unpacked; an archive
/// read is a page read of two thousand blocks, which is the price of holding a third of the bytes.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Sha256 "mo:sha2/Sha256";

import JT "mo:journal/JournalTypes";
import RI "mo:ledger/RegionIndex";
import MMR "mo:ledger/MerkleMMR";
import Map "mo:core/Map";

import Pack "../bank/Pack";
import Store "../bank/RegionStore";
import R "../bank/StableRows";

shared (initMsg) persistent actor class ArchiveChild() = self {

  let installer : Principal = initMsg.caller;
  var parent : ?Principal = null;
  var bound : Bool = false;

  let arena : RI.Arena = RI.newArena();
  let store : Store.State = Store.newState();
  /// pack(8) ‖ seq(4) → lo(8) hi(8) offset(8) bytes(4) rawBytes(8) postings(8) sha256(32)
  let segments : RI.State = RI.newStateIn(arena, { keyBytes = 12; valBytes = 76 });
  /// hi(8) → pack(8) ‖ seq(4): which segment covers a block index; the first whose last block
  /// is at or past it
  let byBlock : RI.State = RI.newStateIn(arena, { keyBytes = 8; valBytes = 12 });
  /// leafStart(8) ‖ height(1) → hash(32): the roots of the aligned MMR subtrees of
  /// `STORED_FROM_HEIGHT` or more that lie inside one segment, computed when the segment lands, so
  /// a proof's siblings are read rather than recomputed over thousands of blocks.
  let roots : RI.State = RI.newStateIn(arena, { keyBytes = 9; valBytes = 32 });
  transient let STORED_FROM_HEIGHT : Nat = 6;
  var segmentCount : Nat = 0;
  var blockCount : Nat = 0;
  var acked : Nat = 0;

  public type Segment = { pack : Nat; seq : Nat; lo : Nat; hi : Nat; bytes : Nat; rawBytes : Nat; postings : Nat; sha256 : Blob };
  public type PutError = { #NotParent; #HashMismatch : { computed : Blob; offered : Blob }; #DoesNotUnpack : { reason : Text }; #RangeMismatch : { lo : Nat; hi : Nat; blocks : Nat }; #Conflict : { held : Blob } };

  func parentPrincipal() : Principal { switch (parent) { case (?p) p; case null installer } };

  /// Bind the parent once; for a child the operator deployed and the bank adopted. Installer only.
  public shared ({ caller }) func bind(p : Principal) : async Result.Result<(), { #NotInstaller; #AlreadyBound }> {
    if (caller != installer) return #err(#NotInstaller);
    if (bound) return #err(#AlreadyBound);
    parent := ?p;
    bound := true;
    #ok(())
  };

  func encodeRow(sg : Segment, offset : Nat) : Blob {
    let b = R.buf();
    R.putNat(b, sg.lo, 8); R.putNat(b, sg.hi, 8); R.putNat(b, offset, 8); R.putNat(b, sg.bytes, 4); R.putNat(b, sg.rawBytes, 8); R.putNat(b, sg.postings, 8); R.putBlob(b, sg.sha256, 32);
    R.done(b, 76)
  };
  func decodeRow(pack : Nat, seq : Nat, v : Blob) : (Segment, Nat) {
    let a = Blob.toArray(v);
    ({ pack; seq; lo = R.getNat(a, 0, 8); hi = R.getNat(a, 8, 8); bytes = R.getNat(a, 24, 4); rawBytes = R.getNat(a, 28, 8); postings = R.getNat(a, 36, 8); sha256 = R.getBlob(a, 44, 32) }, R.getNat(a, 16, 8))
  };

  /// Store one segment and acknowledge it to the parent. Parent only. The bytes must hash to the
  /// offered hash and unpack to exactly `hi − lo + 1` blocks whose first index is `lo`; a segment
  /// already held under the same hash is acknowledged again and stored once.
  public shared ({ caller }) func putSegment(pack : Nat, seq : Nat, lo : Nat, hi : Nat, bytes : Blob, sha256 : Blob, postings : Nat) : async Result.Result<{ acknowledged : Bool }, PutError> {
    if (caller != parentPrincipal()) return #err(#NotParent);
    let computed = Sha256.fromBlob(#sha256, bytes);
    if (computed != sha256) return #err(#HashMismatch({ computed; offered = sha256 }));
    let key = R.key2(pack, 8, seq, 4);
    switch (RI.get(segments, key)) {
      case (?v) { let (held, _) = decodeRow(pack, seq, v); if (held.sha256 != sha256) return #err(#Conflict({ held = held.sha256 })) };
      case null {
        let (rawBytes, leafHashes) = switch (Pack.unpack(bytes)) {
          case (#err(reason)) return #err(#DoesNotUnpack({ reason }));
          case (#ok(back)) {
            if (back.size() != hi + 1 - lo or (back.size() > 0 and back[0].block.index != lo)) return #err(#RangeMismatch({ lo; hi; blocks = back.size() }));
            var n = 0; for (b in back.vals()) n += b.raw.size();
            (n, Array.tabulate<Blob>(back.size(), func(i) { MMR.hashLeaf(back[i].block.hash) }))
          };
        };
        let offset = Store.append(store, bytes);
        storeRoots(lo, hi, leafHashes);
        ignore RI.put(segments, key, encodeRow({ pack; seq; lo; hi; bytes = bytes.size(); rawBytes; postings; sha256 }, offset));
        ignore RI.put(byBlock, R.key(hi, 8), key);
        segmentCount += 1;
        blockCount += hi + 1 - lo;
      };
    };
    // the store is committed above; the acknowledgement is the parent's to record
    let p = actor (Principal.toText(parentPrincipal())) : actor { acknowledgeArchivedSegment : shared (Nat, Nat, Blob) -> async Bool };
    let ok = await p.acknowledgeArchivedSegment(pack, seq, sha256);
    if (ok) acked += 1;
    #ok({ acknowledged = ok })
  };

  // ─── the MMR's view of the blocks held: what an archived block's proof needs from here ───

  func rootKey(leafStart : Nat, height : Nat) : Blob { let b = R.buf(); R.putNat(b, leafStart, 8); R.putNat(b, height, 1); R.done(b, 9) };

  /// The aligned subtrees of `STORED_FROM_HEIGHT` or more inside `[lo, hi]`, from the leaf hashes.
  func storeRoots(lo : Nat, hi : Nat, leafHashes : [Blob]) {
    var h = STORED_FROM_HEIGHT;
    label heights while (h < 64) {
      let size = 2 ** h;
      var start = ((lo + size - 1) / size) * size;
      var any = false;
      while (start + size - 1 <= hi) {
        any := true;
        ignore RI.put(roots, rootKey(start, h), foldLeaves(leafHashes, start - lo, size));
        start += size;
      };
      if (not any) break heights;
      h += 1;
    };
  };

  func foldLeaves(leafHashes : [Blob], from : Nat, count : Nat) : Blob {
    if (count == 1) return leafHashes[from];
    MMR.hashInternal(foldLeaves(leafHashes, from, count / 2), foldLeaves(leafHashes, from + count / 2, count / 2))
  };

  /// The leaf hashes of a block range, from the covering segments, each unpacked once per query.
  func leafHashesOf(cache : Map.Map<Nat, (Segment, [Blob])>, from : Nat, count : Nat) : ?[Blob] {
    let out = List.empty<Blob>();
    var i = from;
    while (i < from + count) {
      let ?(sg, hashes) = coveringHashes(cache, i) else return null;
      List.add(out, hashes[i - sg.lo]);
      i += 1;
    };
    ?List.toArray(out)
  };

  func coveringHashes(cache : Map.Map<Nat, (Segment, [Blob])>, index : Nat) : ?(Segment, [Blob]) {
    for ((_, (sg, hashes)) in Map.entries(cache)) { if (sg.lo <= index and index <= sg.hi) return ?(sg, hashes) };
    let ?(sg, offset) = covering(index) else return null;
    switch (Pack.unpack(Store.read(store, offset, sg.bytes))) {
      case (#ok(back)) { let hashes = Array.tabulate<Blob>(back.size(), func(i) { MMR.hashLeaf(back[i].block.hash) }); Map.add(cache, Nat.compare, sg.lo, (sg, hashes)); ?(sg, hashes) };
      case (#err(_)) null;
    }
  };

  func subtreeRootIn(cache : Map.Map<Nat, (Segment, [Blob])>, leafStart : Nat, height : Nat) : ?Blob {
    if (leafStart % (2 ** height) != 0) return null;
    if (height == 0) { let ?(sg, hashes) = coveringHashes(cache, leafStart) else return null; return ?hashes[leafStart - sg.lo] };
    switch (RI.get(roots, rootKey(leafStart, height))) { case (?h) return ?h; case null {} };
    if (height < STORED_FROM_HEIGHT) {
      // small: from the leaves, which lie in at most two segments
      let ?hashes = leafHashesOf(cache, leafStart, 2 ** height) else return null;
      return ?foldLeaves(hashes, 0, 2 ** height);
    };
    let half = 2 ** (height - 1);
    let ?l = subtreeRootIn(cache, leafStart, height - 1) else return null;
    let ?r = subtreeRootIn(cache, leafStart + half, height - 1) else return null;
    ?MMR.hashInternal(l, r)
  };

  /// The root of the aligned MMR subtree of `height` starting at `leafStart` (a block index), when
  /// every block of it is held here; null otherwise; the caller then asks the archive that holds
  /// the rest, or splits the subtree in two.
  public query func subtreeRoot(leafStart : Nat, height : Nat) : async ?Blob {
    subtreeRootIn(Map.empty<Nat, (Segment, [Blob])>(), leafStart, height)
  };

  /// The MMR leaf hash of a block held here.
  public query func leafHash(index : Nat) : async ?Blob {
    subtreeRootIn(Map.empty<Nat, (Segment, [Blob])>(), index, 0)
  };

  /// The lower siblings of an archived block's proof, up to `toHeight`, when every block they
  /// need is held here: what joins the parent's `journalProofAbove` into a whole proof.
  public query func proofBelow(index : Nat, toHeight : Nat) : async ?[Blob] {
    let cache = Map.empty<Nat, (Segment, [Blob])>();
    let out = List.empty<Blob>();
    var idx = index; var h = 0;
    while (h < toHeight) {
      let sib = if (idx % 2 == 0) idx + 1 else idx - 1;
      let ?s = subtreeRootIn(cache, sib * (2 ** h), h) else return null;
      List.add(out, s);
      idx /= 2; h += 1;
    };
    ?List.toArray(out)
  };

  public query func segment(pack : Nat, seq : Nat) : async ?Segment {
    switch (RI.get(segments, R.key2(pack, 8, seq, 4))) { case (?v) ?decodeRow(pack, seq, v).0; case null null }
  };

  public query func segmentBytes(pack : Nat, seq : Nat) : async ?Blob {
    switch (RI.get(segments, R.key2(pack, 8, seq, 4))) { case (?v) { let (sg, offset) = decodeRow(pack, seq, v); ?Store.read(store, offset, sg.bytes) }; case null null }
  };

  public query func listSegments(pack : Nat) : async [Segment] {
    let (lo, hi) = R.prefixRange(pack, 8, 4);
    let out = List.empty<Segment>();
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(segments, lo, hi, cursor, 500);
      for ((k, v) in page.entries.vals()) List.add(out, decodeRow(pack, R.getNat(Blob.toArray(k), 8, 4), v).0);
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };

  /// The round trip, here: the bytes hash to the registered hash and unpack to the registered range.
  public query func verifySegment(pack : Nat, seq : Nat) : async ?{ blocks : Nat; hashOk : Bool; unpacks : Bool; firstIndex : ?Nat; reason : ?Text } {
    let ?v = RI.get(segments, R.key2(pack, 8, seq, 4)) else return null;
    let (sg, offset) = decodeRow(pack, seq, v);
    let bytes = Store.read(store, offset, sg.bytes);
    let hashOk = Sha256.fromBlob(#sha256, bytes) == sg.sha256;
    switch (Pack.unpack(bytes)) {
      case (#err(reason)) ?{ blocks = 0; hashOk; unpacks = false; firstIndex = null; reason = ?reason };
      case (#ok(back)) ?{ blocks = back.size(); hashOk; unpacks = back.size() == sg.hi + 1 - sg.lo; firstIndex = if (back.size() > 0) ?back[0].block.index else null; reason = null };
    }
  };

  /// The segment covering a block index: the first segment whose `hi` is at or past it, if its
  /// `lo` is at or below it.
  func covering(index : Nat) : ?(Segment, Nat) {
    let page = RI.range(byBlock, R.key(index, 8), R.key(0xFFFF_FFFF_FFFF_FFFF, 8), null, 1);
    if (page.entries.size() == 0) return null;
    let key = page.entries[0].1;
    let ka = Blob.toArray(key);
    let ?v = RI.get(segments, key) else return null;
    let (sg, offset) = decodeRow(R.getNat(ka, 0, 8), R.getNat(ka, 8, 4), v);
    if (sg.lo > index) null else ?(sg, offset)
  };

  /// A journal block's raw bytes by absolute index; the block an external verifier hashes.
  public query func rawBlock(index : Nat) : async ?Blob {
    let ?(sg, offset) = covering(index) else return null;
    switch (Pack.unpack(Store.read(store, offset, sg.bytes))) { case (#ok(back)) ?back[index - sg.lo].raw; case (#err(_)) null }
  };

  public query func block(index : Nat) : async ?JT.Block {
    let ?(sg, offset) = covering(index) else return null;
    switch (Pack.unpack(Store.read(store, offset, sg.bytes))) { case (#ok(back)) ?back[index - sg.lo].block; case (#err(_)) null }
  };

  public query func info() : async { parent : Principal; installer : Principal; bound : Bool; segments : Nat; blocks : Nat; acknowledged : Nat; storeBytes : Nat; storePages : Nat; self : Principal } {
    { parent = parentPrincipal(); installer; bound; segments = segmentCount; blocks = blockCount; acknowledged = acked; storeBytes = Store.size(store); storePages = Store.pages(store); self = Principal.fromActor(self) }
  };
}
