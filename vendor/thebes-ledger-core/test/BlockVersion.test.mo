// BlockVersion.test.mo — a version-3 block stream stays readable and replays to
// the same state under the version-4 decoder (operator decision D-2).
//
// Adding the banking event tags made the written version 4. The decoder previously
// refused anything but the single current version, which would have made every
// block written by an earlier build unreadable. This test proves three things:
//   1. a version-3 encoding of a version-3 event differs from its version-4
//      encoding in exactly one byte (the version byte) and nowhere else, so no
//      existing variant's encoding changed;
//   2. both encodings decode, and the decoded block carries its own stored hash
//      (which differs between versions because the version byte is hashed);
//   3. replaying a version-3 stream and the matching version-4 stream into fresh
//      journal states yields the same state fingerprint, so an existing log
//      means exactly what it meant.
// Every unsupported version is refused.
//
// engine: wasi-only — the journal core now keeps its per-posting state in a stable-memory Region
// (`JournalCore.postingRows`), and the moc interpreter provides no Region. The dual-engine check this
// loses was worth having, and the loss is stated here rather than hidden: the reason the state moved
// is that a heap map per posting makes the heap grow with the journal, which is the one thing a
// contract's heap must not do. Every test below still runs under wasmtime, which is the engine the
// chain runs.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Principal "mo:core/Principal";
import Nat64 "mo:core/Nat64";
import T "../src/journal/JournalTypes";
import C "../src/journal/Canonical";
import Core "../src/journal/JournalCore";

let admin = Principal.fromText("aaaaa-aa");
let poster = Principal.fromBlob(Blob.fromArray([7, 7, 7, 7, 7]));

func key(n : Nat) : Blob { Blob.fromArray([Nat8.fromNat(n % 256), 0xAB]) };

func record(n : Nat, account : Text, amount : Nat) : T.PostingRecord {
  {
    idempotencyKey = key(n);
    postingDate = 20705; valueDate = 20705; valueDateRequested = null;
    period = "2026-09";
    legs = [
      { account = account; subledger = null; side = #debit; currency = "EGP"; amount },
      { account = "2001"; subledger = ?Blob.fromArray([1, 2, 3]); side = #credit; currency = "EGP"; amount },
    ];
    sourceRef = { kind = "test"; id = "v3" };
    narration = "version stream";
    relation = null;
  }
};

// A stream using only the version-3 vocabulary (tags 0x10..0x2B).
let v3Events : [T.Event] = [
  #currencyRegistered({ code = "EGP"; minorUnits = 2 }),
  #accountOpened({ code = "1500"; name = "Cash"; normalSide = #debit; category = #asset; constraint = #none }),
  #accountOpened({ code = "2001"; name = "Customer deposits"; normalSide = #credit; category = #liability; constraint = #debitsNotExceedCredits }),
  #periodOpened({ id = "2026-09"; start = 20697; end = 20726 }),
  #posterAdded({ poster }),
  #activationHeight({ height = 0 }),
  #businessDateRolled({ day = 20705 }),
  #calendarSet({ calendar = ?{ restDays = [4, 5]; holidays = [20710]; policy = #reject } }),
  #posted(record(1, "1500", 500_00)),
  #posted(record(2, "1500", 250_00)),
  #pending({ record = record(3, "1500", 100_00); expiresAt = ?1_900_000_000_000_000_000 }),
  #post({ pendingIndex = 10; resolution = { postingDate = 20705; valueDate = 20705; valueDateRequested = null; period = "2026-09" } }),
  #periodClosed({ id = "2026-09" }),
];

// Encode the same events at both versions, checking the one-byte difference.
let v3 = List.empty<T.Block>();
let v4 = List.empty<T.Block>();
var byteDiffs = 0;
var decoded = 0;
var prev3 : ?Blob = null;
var prev4 : ?Blob = null;
var i = 0;
for (e in v3Events.vals()) {
  let ts = 1_700_000_000_000_000_000 + Nat64.fromNat(i);
  let caller = if (i % 2 == 0) admin else poster;
  let a = C.encodeBlockAtVersion(0x03, i, ts, caller, prev3, e);
  // For the byte-level comparison the two encodings must differ in nothing but
  // the version byte, so they are given the same parent hash. The two chains
  // themselves diverge (the version byte is hashed), so the version-4 chain is
  // built separately below.
  let b = C.encodeBlockAtVersion(0x04, i, ts, caller, prev3, e);
  let bChain = C.encodeBlockAtVersion(0x04, i, ts, caller, prev4, e);
  let ab = Blob.toArray(a.bytes);
  let bb = Blob.toArray(b.bytes);
  assert (ab.size() == bb.size());
  assert (ab[0] == 0x03 and bb[0] == 0x04);
  // the preimage differs only in byte 0; the trailing 32-byte hash differs
  // because it covers that byte, which is the point of hashing it.
  var k = 1;
  var diffsInPreimage = 0;
  while (k < ab.size() - 32) {
    if (ab[k] != bb[k]) diffsInPreimage += 1;
    k += 1;
  };
  assert (diffsInPreimage == 0);
  assert (a.hash != b.hash);
  byteDiffs += 1;

  let ?d3 = C.decodeBlock(a.bytes) else { Debug.print("v3 decode failed at " # Nat.toText(i)); assert false; loop {} };
  let ?d4 = C.decodeBlock(bChain.bytes) else { Debug.print("v4 decode failed at " # Nat.toText(i)); assert false; loop {} };
  assert (d3.index == i and d4.index == i);
  assert (d3.event == e and d4.event == e);
  assert (d3.hash == a.hash and d4.hash == bChain.hash);
  assert (d3.timestamp == d4.timestamp and d3.caller == d4.caller);
  decoded += 2;
  List.add(v3, d3);
  List.add(v4, d4);
  prev3 := ?a.hash;
  prev4 := ?bChain.hash;
  i += 1;
};
Debug.print("count: version pairs encoded and compared = " # Nat.toText(byteDiffs));
Debug.print("count: blocks decoded across both versions = " # Nat.toText(decoded));
assert (byteDiffs == v3Events.size());

// Replay both streams; the derived state must be identical. The hash chain
// differs by construction, so the fingerprint covers the accounting state.
let s3 = Core.replay(admin, List.toArray(v3));
let s4 = Core.replay(admin, List.toArray(v4));
let f3 = Core.fingerprint(s3);
let f4 = Core.fingerprint(s4);
Debug.print("v3 fingerprint == v4 fingerprint: " # (if (f3 == f4) "yes" else "no"));
assert (f3 == f4);
assert (Core.height(s3) == v3Events.size() and Core.height(s4) == v3Events.size());
assert (Core.postedCount(s3) == 3);
Debug.print("count: replayed blocks per stream = " # Nat.toText(Core.height(s3)));

// Supported versions, and nothing else.
assert (C.supportsVersion(0x03) and C.supportsVersion(0x04));
var refusedVersions = 0;
var v : Nat = 0;
while (v < 256) {
  if (v != 3 and v != 4) {
    assert (not C.supportsVersion(Nat8.fromNat(v)));
    // a block whose version byte is unsupported does not decode, even with a
    // correctly recomputed hash for that byte string
    let enc = C.encodeBlockAtVersion(Nat8.fromNat(v), 0, 1, admin, null, v3Events[0]);
    switch (C.decodeBlock(enc.bytes)) {
      case null refusedVersions += 1;
      case (?_) { Debug.print("unsupported version accepted: " # Nat.toText(v)); assert false };
    };
  };
  v += 1;
};
Debug.print("count: unsupported versions refused = " # Nat.toText(refusedVersions));
assert (refusedVersions == 254);

// A version-4 event (tag 0x2C) is not decodable as version 3 content by an
// earlier build, but is by this one; the round trip is exact.
let scopeEvent : T.Event = #posterScopeSet({ poster; accounts = ?["1500", "2001"] });
let se = C.encodeBlock(0, 1, admin, null, scopeEvent);
assert (Blob.toArray(se.bytes)[0] == 0x04);
let ?sd = C.decodeBlock(se.bytes) else { assert false; loop {} };
assert (sd.event == scopeEvent);
// the calendar authority (tag 0x2F), the same way
let authorityEvent : T.Event = #calendarAuthoritySet({ authority = #businessDate; maxRollDays = 31; businessDate = ?20705 });
let ae = C.encodeBlock(1, 2, admin, ?se.hash, authorityEvent);
assert (Blob.toArray(ae.bytes)[0] == 0x04);
let ?ad = C.decodeBlock(ae.bytes) else { assert false; loop {} };
assert (ad.event == authorityEvent);
Debug.print("count: version-4 only events round tripped = 2");

Debug.print("BLOCK VERSION TEST GREEN");
