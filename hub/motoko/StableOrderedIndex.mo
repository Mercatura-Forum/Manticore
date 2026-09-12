/// StableOrderedIndex.mo -- Region-backed checkpoint for ordered index entries.
///
/// This is not yet a mutable BTree. It persists the deterministic ordered-index
/// keyspace into stable memory with enough metadata for live verifier checks and
/// stable-memory range/prefix reads.

import OrderedIndex "OrderedIndex";
import InPlaceSha256d "InPlaceSha256d";

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Region "mo:core/Region";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import VarArray "mo:core/VarArray";

module {

  let PAGE_SIZE : Nat64 = 65_536;
  let HEADER_BYTES : Nat64 = 32;
  let VERSION : Nat64 = 1;

  public type Store = {
    region : Region.Region;
    var byteLength : Nat64;
    var entryCount : Nat;
    var generation : Nat;
    var commitHash : Blob;
  };

  public type Metadata = {
    regionId : Nat;
    pages : Nat64;
    byteLength : Nat64;
    entryCount : Nat;
    generation : Nat;
    commitHash : Blob;
  };

  public type VerifyReport = {
    ok : Bool;
    issueCount : Nat;
    issues : [Text];
    metadata : Metadata;
  };

  public func empty() : Store {
    {
      region = Region.new();
      var byteLength = 0;
      var entryCount = 0;
      var generation = 0;
      var commitHash = Blob.empty();
    };
  };

  public func metadata(store : Store) : Metadata {
    {
      regionId = Region.id(store.region);
      pages = Region.size(store.region);
      byteLength = store.byteLength;
      entryCount = store.entryCount;
      generation = store.generation;
      commitHash = store.commitHash;
    };
  };

  public func commit(store : Store, index : OrderedIndex.Index) {
    let bytes = serialize(index, store.generation + 1);
    let needed = pagesFor(bytes.size());
    let current = Region.size(store.region);
    if (current < needed) {
      let old = Region.grow(store.region, needed - current);
      if (old == Nat64.maxValue) Runtime.trap("stable ordered index region grow failed");
    };
    Region.storeBlob(store.region, 0, Blob.fromVarArray(bytes));
    store.byteLength := Nat64.fromNat(bytes.size());
    store.entryCount := index.entries.size();
    store.generation += 1;
    store.commitHash := hashBytes(bytes);
  };

  public func range(store : Store, fromInclusive : Text, toExclusive : Text, offset : Nat, limit : Nat) : [Nat] {
    scan(store, offset, limit, func(key) { textGte(key, fromInclusive) and textLt(key, toExclusive) });
  };

  public func prefix(store : Store, prefixText : Text, offset : Nat, limit : Nat) : [Nat] {
    scan(store, offset, limit, func(key) { Text.startsWith(key, #text prefixText) });
  };

  public func verify(store : Store) : VerifyReport {
    var issues : [Text] = [];
    if (store.byteLength == 0) {
      if (store.entryCount != 0) issues := add(issues, "empty stable index checkpoint cannot have entries");
      return {
        ok = issues.size() == 0;
        issueCount = issues.size();
        issues;
        metadata = metadata(store);
      };
    };
    if (store.byteLength < HEADER_BYTES) {
      issues := add(issues, "stable index checkpoint header is incomplete");
    };
    let capacity = Region.size(store.region) * PAGE_SIZE;
    if (store.byteLength > capacity) {
      issues := add(issues, "stable index checkpoint byteLength exceeds region capacity");
    };
    if (issues.size() == 0) {
      let version = Region.loadNat64(store.region, 0);
      let count = Region.loadNat64(store.region, 8);
      let byteLength = Region.loadNat64(store.region, 16);
      let generation = Region.loadNat64(store.region, 24);
      if (version != VERSION) issues := add(issues, "stable index checkpoint version mismatch");
      if (count != Nat64.fromNat(store.entryCount)) issues := add(issues, "stable index checkpoint count mismatch");
      if (byteLength != store.byteLength) issues := add(issues, "stable index checkpoint byteLength header mismatch");
      if (generation != Nat64.fromNat(store.generation)) issues := add(issues, "stable index checkpoint generation mismatch");
      let scanned = scanInvariant(store);
      if (scanned.issueCount > 0) {
        for (issue in scanned.issues.vals()) issues := add(issues, issue);
      };
      if (scanned.count != store.entryCount) issues := add(issues, "stable index checkpoint scanned count mismatch");
      if (hashSnapshot(store) != store.commitHash) issues := add(issues, "stable index checkpoint hash mismatch");
    };
    {
      ok = issues.size() == 0;
      issueCount = issues.size();
      issues;
      metadata = metadata(store);
    };
  };

  func serialize(index : OrderedIndex.Index, generation : Nat) : [var Nat8] {
    let total = serializedSize(index);
    let bytes = VarArray.repeat<Nat8>(0, total);
    putNat64(bytes, 0, VERSION);
    putNat64(bytes, 8, Nat64.fromNat(index.entries.size()));
    putNat64(bytes, 16, Nat64.fromNat(total));
    putNat64(bytes, 24, Nat64.fromNat(generation));
    var offset = Nat64.toNat(HEADER_BYTES);
    for (entry in index.entries.vals()) {
      let keyBytes = Blob.toArray(Text.encodeUtf8(entry.key));
      putNat64(bytes, offset, Nat64.fromNat(keyBytes.size()));
      putNat64(bytes, offset + 8, Nat64.fromNat(entry.id));
      offset += 16;
      var i = 0;
      while (i < keyBytes.size()) {
        bytes[offset + i] := keyBytes[i];
        i += 1;
      };
      offset += keyBytes.size();
    };
    bytes;
  };

  func serializedSize(index : OrderedIndex.Index) : Nat {
    var total = Nat64.toNat(HEADER_BYTES);
    for (entry in index.entries.vals()) {
      total += 16 + Blob.size(Text.encodeUtf8(entry.key));
    };
    total;
  };

  func scan(store : Store, offset : Nat, limit : Nat, matches : Text -> Bool) : [Nat] {
    if (store.byteLength == 0 or limit == 0) return [];
    var out : [Nat] = [];
    var skipped = 0;
    var pos = HEADER_BYTES;
    var seen = 0;
    label entries while (seen < store.entryCount and pos + 16 <= store.byteLength) {
      let keyLen = Region.loadNat64(store.region, pos);
      let id = Nat64.toNat(Region.loadNat64(store.region, pos + 8));
      let keyStart = pos + 16;
      let keyEnd = keyStart + keyLen;
      if (keyEnd > store.byteLength) break entries;
      switch (Text.decodeUtf8(Region.loadBlob(store.region, keyStart, Nat64.toNat(keyLen)))) {
        case (?key) {
          if (matches(key)) {
            if (skipped < offset) {
              skipped += 1;
            } else if (out.size() < limit) {
              out := Array.concat<Nat>(out, [id]);
            };
          };
        };
        case null {};
      };
      pos := keyEnd;
      seen += 1;
    };
    out;
  };

  type ScanInvariant = {
    count : Nat;
    issueCount : Nat;
    issues : [Text];
  };

  func scanInvariant(store : Store) : ScanInvariant {
    var issues : [Text] = [];
    var pos = HEADER_BYTES;
    var seen = 0;
    var prevKey : ?Text = null;
    var prevId : Nat = 0;
    label entries while (seen < store.entryCount and pos + 16 <= store.byteLength) {
      let keyLen = Region.loadNat64(store.region, pos);
      let id = Nat64.toNat(Region.loadNat64(store.region, pos + 8));
      let keyStart = pos + 16;
      let keyEnd = keyStart + keyLen;
      if (keyEnd > store.byteLength) {
        issues := add(issues, "stable index entry exceeds checkpoint byteLength");
        break entries;
      };
      switch (Text.decodeUtf8(Region.loadBlob(store.region, keyStart, Nat64.toNat(keyLen)))) {
        case (?key) {
          switch (prevKey) {
            case (?p) {
              let ordered = switch (Text.compare(p, key)) {
                case (#less) true;
                case (#equal) prevId < id;
                case (#greater) false;
              };
              if (not ordered) issues := add(issues, "stable index entries must be strictly sorted and unique");
            };
            case null {};
          };
          prevKey := ?key;
          prevId := id;
        };
        case null issues := add(issues, "stable index key is not valid UTF-8");
      };
      pos := keyEnd;
      seen += 1;
    };
    if (pos != store.byteLength) issues := add(issues, "stable index checkpoint has trailing or truncated bytes");
    { count = seen; issueCount = issues.size(); issues };
  };

  func hashSnapshot(store : Store) : Blob {
    if (store.byteLength == 0) return Blob.empty();
    let blob = Region.loadBlob(store.region, 0, Nat64.toNat(store.byteLength));
    Blob.fromArray(InPlaceSha256d.Hasher().sha256General(Blob.toArray(blob)));
  };

  func hashBytes(bytes : [var Nat8]) : Blob {
    Blob.fromArray(InPlaceSha256d.Hasher().sha256General(VarArray.toArray<Nat8>(bytes)));
  };

  func pagesFor(bytes : Nat) : Nat64 {
    if (bytes == 0) return 0;
    let n = Nat64.fromNat(bytes);
    ((n - 1) / PAGE_SIZE) + 1;
  };

  func putNat64(bytes : [var Nat8], offset : Nat, value : Nat64) {
    var v = value;
    var i = 0;
    while (i < 8) {
      bytes[offset + i] := Nat8.fromNat64(v & 255);
      v >>= 8;
      i += 1;
    };
  };

  func add(xs : [Text], x : Text) : [Text] {
    Array.concat<Text>(xs, [x]);
  };

  func textLt(a : Text, b : Text) : Bool {
    switch (Text.compare(a, b)) {
      case (#less) true;
      case _ false;
    };
  };

  func textGte(a : Text, b : Text) : Bool {
    switch (Text.compare(a, b)) {
      case (#less) false;
      case _ true;
    };
  };
};
