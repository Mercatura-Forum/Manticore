// Canonical.test.mo — every event variant encodes, decodes byte-for-byte, and a
// single flipped byte anywhere in a block is detected.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Nat64 "mo:core/Nat64";
import T "../src/journal/JournalTypes";
import C "../src/journal/Canonical";

func Nat64FromNat(n : Nat) : Nat64 { Nat64.fromNat(n) };

let admin = Principal.fromText("aaaaa-aa");
let poster = Principal.fromBlob(Blob.fromArray([1, 2, 3, 4, 5]));

let record : T.PostingRecord = {
  idempotencyKey = Blob.fromArray([9, 9, 9]);
  postingDate = 20705; valueDate = 20700; period = "2026-09";
  legs = [
    { account = "1500"; subledger = null; side = #debit; currency = "EGP"; amount = 123_456_789_012_345_678_901_234_567_890 },
    { account = "2000.01"; subledger = ?Blob.fromArray(Array.tabulate<Nat8>(62, func(i) { Nat8.fromNat(i) })); side = #credit; currency = "EGP"; amount = 123_456_789_012_345_678_901_234_567_890 },
  ];
  sourceRef = { kind = "pacs.008"; id = "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011" };
  narration = "Narration with unicode — عربي — and <xml> & 'quotes'";
  relation = ?{ original = 7; kind = #correction };
  valueDateRequested = ?20698;
};

let events : [T.Event] = [
  #posted(record),
  #posted({ record with relation = null; narration = "" }),
  #pending({ record; expiresAt = ?1_800_000_000_000_000_000 }),
  #pending({ record; expiresAt = null }),
  #post({ pendingIndex = 3; resolution = { postingDate = 20706; valueDate = 20706; valueDateRequested = null; period = "2026-09" } }),
  #post({ pendingIndex = 5; resolution = { postingDate = 20706; valueDate = 20708; valueDateRequested = ?20706; period = "2026-09" } }),
  #businessDateRolled({ day = 20705 }),
  #calendarSet({ calendar = ?{ restDays = [4, 5]; holidays = [20460, 20478]; policy = #nearest } }),
  #calendarSet({ calendar = null }),
  #calendarAuthoritySet({ authority = #businessDate; maxRollDays = 31; businessDate = ?20705 }),
  #calendarAuthoritySet({ authority = #substrateClock; maxRollDays = 0; businessDate = null }),
  #void({ pendingIndex = 3; reason = #requested }),
  #void({ pendingIndex = 4; reason = #expired }),
  #currencyRegistered({ code = "EGP"; minorUnits = 2 }),
  #accountOpened({ code = "1500"; name = "Cash"; normalSide = #debit; category = #asset; constraint = #none }),
  #accountOpened({ code = "2001"; name = "Deposit"; normalSide = #credit; category = #liability; constraint = #debitsNotExceedCredits }),
  #accountOpened({ code = "1501"; name = "Till"; normalSide = #debit; category = #asset; constraint = #creditsNotExceedDebits }),
  #accountClosed({ code = "1500" }),
  #periodOpened({ id = "2026-09"; start = 20697; end = 20726 }),
  #periodClosed({ id = "2026-09" }),
  #activationHeight({ height = 0xFFFF_FFFF_FFFF_FFFF }),
  #activationHeight({ height = 0 }),
  #leadsheetSchema({ ranges = [{ lo = 1000; hi = 1099; leadsheet = "1"; name = "PPE"; category = "non_current_assets"; cycle = "ppe" }] }),
  #posterAdded({ poster }),
  #posterRemoved({ poster }),
  #adminTransferred({ admin = poster }),
  #posterScopeSet({ poster; accounts = ?["1500", "2001", "2000.01"] }),
  #posterScopeSet({ poster; accounts = null }),
  #balanceLimitSet({ account = "2001"; subledger = ?Blob.fromArray([1, 2, 3]); currency = "EGP"; limit = #debitsNotExceedCreditsPlus(50_000_00) }),
  #balanceLimitSet({ account = "2001"; subledger = null; currency = "USD"; limit = #creditsNotExceedDebitsPlus(1_000_000_00) }),
  #balanceLimitSet({ account = "1500"; subledger = null; currency = "EGP"; limit = #none }),
  #accountAttributesSet({ code = "1500"; attributes = { usage = #header; manualEntriesAllowed = false; parent = null } }),
  #accountAttributesSet({ code = "2001"; attributes = { usage = #detail; manualEntriesAllowed = true; parent = ?"1500" } }),
];

var prev : ?Blob = null;
var roundTrips = 0;
var tampersDetected = 0;
var tamperTrials = 0;
var i = 0;
for (e in events.vals()) {
  let enc = C.encodeBlock(i, 1_700_000_000_000_000_000 + Nat64FromNat(i), if (i % 2 == 0) admin else poster, prev, e);
  // decode must reproduce every field
  switch (C.decodeBlock(enc.bytes)) {
    case null { assert false };
    case (?b) {
      assert (b.index == i);
      assert (b.parentHash == prev);
      assert (b.hash == enc.hash);
      assert (b.event == e);
      // re-encoding the decoded block gives identical bytes and hash
      let enc2 = C.encodeBlock(b.index, b.timestamp, b.caller, b.parentHash, b.event);
      assert (enc2.bytes == enc.bytes and enc2.hash == enc.hash);
    };
  };
  roundTrips += 1;
  // flip every byte in turn: decode must fail (hash mismatch or malformed), never succeed
  let bytes = Blob.toArray(enc.bytes);
  var k = 0;
  while (k < bytes.size()) {
    let tampered = Array.tabulate<Nat8>(bytes.size(), func(j) { if (j == k) bytes[j] ^ 0x01 else bytes[j] });
    tamperTrials += 1;
    switch (C.decodeBlock(Blob.fromArray(tampered))) {
      case null tampersDetected += 1;
      case (?_) { Debug.print("tamper undetected at byte " # Nat.toText(k) # " of event " # Nat.toText(i)); assert false };
    };
    k += 1;
  };
  prev := ?enc.hash;
  i += 1;
};
// A principal field whose length byte claims more than 29 bytes must be
// rejected, not constructed: Principal.fromBlob traps on a longer blob, and a
// decoder that traps cannot reject. (Found by the bank log's byte-flip test.)
var principalLengthRefusals = 0;
let pblock = C.encodeBlock(0, 1, admin, null, #posterAdded({ poster }));
let pbytes = Blob.toArray(pblock.bytes);
// locate the caller principal's length byte: version(1) + nat(index) + nat64(8)
// then the principal length byte. nat(0) is a single 0x00 byte.
var lenPos = 1 + 1 + 8;
var claim = 30;
while (claim < 256) {
  let tampered = Array.tabulate<Nat8>(pbytes.size(), func(j) { if (j == lenPos) Nat8.fromNat(claim) else pbytes[j] });
  switch (C.decodeBlock(Blob.fromArray(tampered))) {
    case null principalLengthRefusals += 1;
    case (?_) { Debug.print("over-long principal accepted, claim " # Nat.toText(claim)); assert false };
  };
  claim += 1;
};
Debug.print("count: over-long principal length bytes refused = " # Nat.toText(principalLengthRefusals));
assert (principalLengthRefusals == 226);
assert (C.MAX_PRINCIPAL_BYTES == 29);

Debug.print("count: canonical event round trips = " # Nat.toText(roundTrips));
Debug.print("count: canonical tamper trials = " # Nat.toText(tamperTrials));
Debug.print("count: canonical tampers detected = " # Nat.toText(tampersDetected));
assert (tamperTrials == tampersDetected and tamperTrials > 1000);
assert (roundTrips == events.size() and events.size() == 33);

// Hash is a pure function of the fields; different index or parent changes it.
let a = C.encodeBlock(0, 1, admin, null, events[0]);
let b = C.encodeBlock(0, 1, admin, null, events[0]);
assert (a.hash == b.hash and a.bytes == b.bytes);
assert (C.encodeBlock(1, 1, admin, null, events[0]).hash != a.hash);
assert (C.encodeBlock(0, 2, admin, null, events[0]).hash != a.hash);
assert (C.encodeBlock(0, 1, poster, null, events[0]).hash != a.hash);
assert (C.encodeBlock(0, 1, admin, ?a.hash, events[0]).hash != a.hash);

// Content hash and scope key
assert (C.postingContentHash(record) == C.postingContentHash({ record with narration = record.narration }));
assert (C.postingContentHash(record) != C.postingContentHash({ record with narration = "x" }));
assert (C.idempotencyScopeKey(admin, Blob.fromArray([1])) != C.idempotencyScopeKey(poster, Blob.fromArray([1])));
assert (C.idempotencyScopeKey(admin, Blob.fromArray([1])) == C.idempotencyScopeKey(admin, Blob.fromArray([1])));

// Nat encoding: minimal big-endian with a length byte; non-minimal input rejected.
let w = C.Writer();
w.nat(0); w.nat(1); w.nat(255); w.nat(256); w.nat(65536);
assert (w.toArray() == [0, 1, 1, 1, 255, 2, 1, 0, 3, 1, 0, 0]);
let r = C.Reader([2, 0, 5]);
assert (r.nat() == null);
Debug.print("count: canonical determinism checks = 11");
