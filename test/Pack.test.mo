// Pack.test.mo; the closed-range codec round-trips every block byte for byte.
//
// The codec is checked at pack time by the code itself (`Pack.pack` unpacks its own output and
// compares); this battery is the second, independent check: a random journal through the real
// log; so the raw bytes are the journal's own encoding, not the test's; packed in ranges,
// unpacked, and compared with the stored bytes and the stored hashes; every event kind the journal
// can write; a pack that is tampered with anywhere is refused or unpacks to different bytes; the
// delta-coded posting list round-trips; and the measured size ratio is printed for the capacity
// model.
//
// engine: wasi-only; the journal's log is a Region.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Text "mo:core/Text";
import Principal "mo:core/Principal";

import JT "mo:journal/JournalTypes";
import JLog "mo:journal/JournalLog";
import Pack "../src/bank/Pack";

var seed : Nat32 = 0x1234_5678;
func next() : Nat32 { seed := seed *% 1_664_525 +% 1_013_904_223; seed };
func below(n : Nat) : Nat { if (n == 0) 0 else (Nat32.toNat(next() / 65_536) * 65_536 + Nat32.toNat(next() / 65_536)) % n };
func fail(what : Text) { Debug.print("FAIL: " # what); assert false };

let log = JLog.newState();
let ME = Principal.fromText("aaaaa-aa");
let OTHER = Principal.fromBlob("\6E\3E\78\13");
func sub(i : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { if (j < 4) Nat8.fromNat((i / (256 ** (3 - j))) % 256) else Nat8.fromNat(j) })) };
let ACCOUNTS = ["1001", "2100", "2110", "4100", "1210"];
let CCY = ["EGP", "USD"];
let NARR = ["salary", "transfer", "fee", "interest capitalisation", "planted"];

func record(n : Nat, day : Nat) : JT.PostingRecord {
  let amount = 100 + below(2_000_000);
  let legs = List.empty<JT.Leg>();
  let ccy = CCY[below(2)];
  List.add(legs, { account = ACCOUNTS[below(5)]; subledger = if (n % 3 == 0) null else ?sub(below(50)); side = #debit; currency = ccy; amount });
  List.add(legs, { account = ACCOUNTS[below(5)]; subledger = ?sub(below(50)); side = #credit; currency = ccy; amount });
  if (n % 7 == 0) {
    List.add(legs, { account = "4100"; subledger = null; side = #debit; currency = ccy; amount = 500 });
    List.add(legs, { account = "2110"; subledger = null; side = #credit; currency = ccy; amount = 500 });
  };
  {
    idempotencyKey = Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { Nat8.fromNat((n * 13 + j * 7) % 256) }));
    postingDate = day; valueDate = if (n % 5 == 0) day + 1 else day;
    valueDateRequested = if (n % 11 == 0) ?(day + 2) else null;
    period = if (day < 20_330) "2026-09" else "2026-10";
    legs = List.toArray(legs);
    sourceRef = { kind = if (n % 4 == 0) "deposit" else "transfer"; id = Nat.toText(n) };
    narration = NARR[below(5)];
    relation = if (n > 10 and n % 17 == 0) ?{ original = n - 5; kind = if (n % 2 == 0) #reversal else #correction } else null;
  }
};

// every event kind, then a stream of postings with pendings, resolutions and voids
var ts : Nat64 = 1_700_000_000_000_000_000;
func emit(caller : Principal, e : JT.Event) : JT.Block { ts += 1_000_000_000 + Nat32.toNat64(next() % 1000); JLog.append(log, ts, caller, e) };
ignore emit(ME, #currencyRegistered({ code = "EGP"; minorUnits = 2 }));
ignore emit(ME, #currencyRegistered({ code = "USD"; minorUnits = 2 }));
ignore emit(ME, #accountOpened({ code = "1001"; name = "Cash"; normalSide = #debit; category = #asset; constraint = #none }));
ignore emit(ME, #accountOpened({ code = "2100"; name = "Deposits"; normalSide = #credit; category = #liability; constraint = #creditsNotExceedDebits }));
ignore emit(ME, #accountClosed({ code = "1210" }));
ignore emit(ME, #periodOpened({ id = "2026-09"; start = 20_300; end = 20_329 }));
ignore emit(ME, #periodOpened({ id = "2026-10"; start = 20_330; end = 20_360 }));
ignore emit(ME, #activationHeight({ height = 7 }));
ignore emit(ME, #leadsheetSchema({ ranges = [{ lo = 1000; hi = 1999; leadsheet = "A"; name = "Assets"; category = "asset"; cycle = "treasury" }] }));
ignore emit(ME, #posterAdded({ poster = OTHER }));
ignore emit(ME, #posterScopeSet({ poster = OTHER; accounts = ?["1001", "2100"] }));
ignore emit(ME, #posterScopeSet({ poster = OTHER; accounts = null }));
ignore emit(ME, #balanceLimitSet({ account = "2100"; subledger = ?sub(3); currency = "EGP"; limit = #debitsNotExceedCreditsPlus(500_00) }));
ignore emit(ME, #balanceLimitSet({ account = "2100"; subledger = null; currency = "EGP"; limit = #none }));
ignore emit(ME, #accountAttributesSet({ code = "2100"; attributes = { usage = #detail; manualEntriesAllowed = false; parent = ?"2000" } }));
ignore emit(ME, #adminTransferred({ admin = OTHER }));
ignore emit(ME, #businessDateRolled({ day = 20_301 }));
ignore emit(ME, #calendarSet({ calendar = null }));
ignore emit(ME, #posterRemoved({ poster = OTHER }));
let configBlocks = JLog.length(log);
let pendings = List.empty<Nat>();
var n = 0;
while (n < 600) {
  let day = 20_300 + below(60);
  let r = record(n, day);
  if (n % 6 == 0) {
    let b = emit(if (n % 2 == 0) ME else OTHER, #pending({ record = r; expiresAt = if (n % 12 == 0) ?(ts + 5_000_000_000) else null }));
    List.add(pendings, b.index);
  } else {
    ignore emit(if (n % 2 == 0) ME else OTHER, #posted(r));
  };
  if (n % 30 == 29) ignore emit(ME, #businessDateRolled({ day }));
  n += 1;
};
var k = 0;
for (p in List.values(pendings)) {
  if (k % 4 == 3) { ignore emit(ME, #void({ pendingIndex = p; reason = if (k % 8 == 3) #requested else #expired })) }
  else { ignore emit(ME, #post({ pendingIndex = p; resolution = { postingDate = 20_320; valueDate = 20_321 + (k % 3); valueDateRequested = if (k % 2 == 0) ?20_325 else null; period = "2026-09" } })) };
  k += 1;
};
ignore emit(ME, #periodClosed({ id = "2026-09" }));
let total = JLog.length(log);
Debug.print("count: journal blocks written = " # Nat.toText(total));
Debug.print("count: configuration event kinds among them = " # Nat.toText(configBlocks));

// ─── the round trip, over every block, in ranges of uneven sizes ─────────────
func stored(lo : Nat, hi : Nat) : [Pack.Stored] {
  Array.tabulate<Pack.Stored>(hi + 1 - lo, func(i) {
    let ?raw = JLog.rawBlock(log, lo + i) else { fail("no raw block"); loop {} };
    let ?block = JLog.get(log, lo + i) else { fail("no block"); loop {} };
    { raw; block }
  })
};
var blocksRoundTripped = 0;
var packedBytes = 0;
var rawBytes = 0;
var lo = 0;
var ranges = 0;
while (lo < total) {
  let hi = Nat.min(total - 1, lo + 40 + below(120));
  let st = stored(lo, hi);
  switch (Pack.pack(st)) {
    case (#err(why)) fail("pack refused [" # Nat.toText(lo) # ", " # Nat.toText(hi) # "]: " # why);
    case (#ok(p)) {
      packedBytes += p.bytes.size();
      rawBytes += p.rawBytes;
      switch (Pack.unpack(p.bytes)) {
        case (#err(why)) fail("unpack failed: " # why);
        case (#ok(back)) {
          assert (back.size() == st.size());
          var i = 0;
          while (i < back.size()) {
            if (back[i].raw != st[i].raw) fail("bytes differ at block " # Nat.toText(lo + i));
            if (back[i].block.hash != st[i].block.hash) fail("hash differs at block " # Nat.toText(lo + i));
            if (back[i].block.parentHash != st[i].block.parentHash) fail("parent hash differs at block " # Nat.toText(lo + i));
            if (back[i].block.event != st[i].block.event) fail("event differs at block " # Nat.toText(lo + i));
            blocksRoundTripped += 1;
            i += 1;
          };
        };
      };
    };
  };
  ranges += 1;
  lo := hi + 1;
};
assert (blocksRoundTripped == total);
Debug.print("count: blocks round-tripped byte for byte through the log's own bytes = " # Nat.toText(blocksRoundTripped));
Debug.print("count: ranges packed = " # Nat.toText(ranges));
Debug.print("count: raw bytes of the blocks = " # Nat.toText(rawBytes));
Debug.print("count: packed bytes = " # Nat.toText(packedBytes));
Debug.print("packed bytes per raw byte, in hundredths: " # Nat.toText(packedBytes * 100 / rawBytes));

// the whole log as one pack, and its size per posting
switch (Pack.pack(stored(0, total - 1))) {
  case (#err(why)) fail("whole-log pack refused: " # why);
  case (#ok(p)) {
    Debug.print("count: bytes per block in one whole-log pack = " # Nat.toText(p.bytes.size() / total));
    Debug.print("count: raw bytes per block = " # Nat.toText(p.rawBytes / total));
    // tampering: every 97th byte flipped in turn; each is refused, or unpacks to something else
    let bytes = Blob.toArray(p.bytes);
    var tampers = 0;
    var caught = 0;
    var x = 5;
    while (x < bytes.size()) {
      let t = Blob.fromArray(Array.tabulate<Nat8>(bytes.size(), func(y) { if (y == x) bytes[y] ^ 0x01 else bytes[y] }));
      tampers += 1;
      switch (Pack.unpack(t)) {
        case (#err(_)) caught += 1;
        case (#ok(back)) {
          var same = back.size() == total;
          var i = 0;
          while (same and i < back.size()) { let ?raw = JLog.rawBlock(log, i) else { fail("raw"); loop {} }; if (back[i].raw != raw) same := false; i += 1 };
          if (not same) caught += 1;
        };
      };
      x += 97;
    };
    assert (caught == tampers);
    Debug.print("count: tampered packs that were refused or unpacked to different bytes = " # Nat.toText(caught));
  };
};

// a range that is not contiguous, and an empty one, are refused
let st2 = stored(3, 6);
let broken = [st2[0], st2[1], st2[3]];
switch (Pack.pack(broken)) { case (#err(_)) {}; case (#ok(_)) fail("a gap was packed") };
switch (Pack.pack([])) { case (#err(_)) {}; case (#ok(_)) fail("nothing was packed") };
Debug.print("count: malformed ranges refused = 2");

// the delta-coded posting list
let lists = [[7, 8, 9], [100], [1, 1_000, 1_000_000, 5_000_000_000], []];
var listChecks = 0;
for (l in lists.vals()) {
  switch (Pack.decodeList(Pack.encodeList(l))) { case (?back) assert (back == l); case null fail("list did not round-trip") };
  listChecks += 1;
};
assert (Pack.decodeList(Blob.fromArray([3, 1, 1])) == null);   // truncated
Debug.print("count: delta-coded posting lists round-tripped = " # Nat.toText(listChecks));
