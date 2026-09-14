// PostingIndex.test.mo; the four posting indexes against a brute-force oracle.
//
// `RegionIndex.test.mo` proves the B-tree. This proves the **meaning** put into it: that the rows
// `indexBlock` writes for a stream of journal blocks are exactly the rows a straightforward fold
// over the same blocks says they should be.
//
// The oracle is that fold, written independently in the heap; a sorted association list per index,
// built by walking the blocks and summing legs. It shares no code with `PostingIndex` beyond the
// journal's own types, which is the point: two implementations of the same statement, compared.
//
// What is proved:
//
//   * **I0** registers a sub-ledger key once, answers `accountOf` for every registered key, refuses
//     a second registration with a different id, and accepts an identical re-registration;
//   * **the headers** match the oracle field by field; dates, primary currency, leg count, account
//     rows, status, flags, period; for postings, pendings, resolutions and voids;
//   * **I1, I2, I3 and I4** hold exactly the oracle's rows, in key order, with the oracle's
//     movements: full-range scans are compared entry by entry, so a missing row, an extra row and a
//     wrong movement are all caught;
//   * **a per-account date range** returns exactly the account's slice, which is the query the index
//     exists for, over many random windows;
//   * **a pending that resolves to another value day** leaves its old rows stale and its new rows
//     live, and `isLive` separates them exactly;
//   * **a leg at or above 2^64 minor units** is indexed saturated and flagged, not truncated
//     silently and not trapped;
//   * **legs on unregistered sub-ledgers and legs with no sub-ledger** produce no I1 row, and the
//     day and currency indexes still carry the posting;
//   * **the multi-currency, shifted-value-date and relation flags** are set exactly when they apply;
//   * **the capacity model's leaf capacities** for the header store, I0 and I1..I4 are what this
//     module's widths produce.
//
// engine: wasi-only; a Region is stable memory, which the interpreter does not provide.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";

import JT "mo:journal/JournalTypes";

import RI "mo:ledger/RegionIndex";
import PIdx "../src/bank/PostingIndex";

// ─── a deterministic pseudo-random source ────────────────────────────────────

var seed : Nat32 = 0x5EED_1D01;
func next() : Nat32 {
  seed := seed *% 1_664_525 +% 1_013_904_223;
  seed
};
// The **high** sixteen bits, not the low ones. A linear congruential generator modulo 2^32 has
// low-order bits with very short periods; with these parameters `next() % 4` has period four; so
// `below(4)` was returning a fixed cycle and one whole arm of this test (a posting in two
// currencies) never ran. The output said so: "multi-currency postings = 0". Using the top bits
// removes it.
func below(n : Nat) : Nat { if (n == 0) 0 else Nat32.toNat(next() / 65_536) % n };

func fail(what : Text) {
  Debug.print("FAIL: " # what);
  assert false;
};

// ═══════════════════════════════════════════════════════════════════
//  THE WORLD THE ORACLE AND THE INDEX BOTH SEE
// ═══════════════════════════════════════════════════════════════════

let CURRENCIES = ["EGP", "USD", "EUR", "GBP"];
let CLASSES = ["retail", "corporate", "sme"];

let ACCOUNTS = 240;
let POSTINGS = 900;
let DAY_BASE = 20_300;
let DAY_SPAN = 60;

// A 32-byte sub-ledger key per account. The index is in the first two bytes, so two accounts can
// never share a key however many there are; a wrap-around collision in a test fixture would make
// the test prove the wrong thing.
func subledgerFor(i : Nat) : Blob {
  Blob.fromArray(Array.tabulate<Nat8>(32, func(j) {
    if (j == 0) Nat8.fromNat(i / 256) else if (j == 1) Nat8.fromNat(i % 256) else Nat8.fromNat((i * 7 + j * 31 + 1) % 256)
  }))
};

// A key in a space no account uses, for the absent-lookup arm.
func unregisteredSubledger(i : Nat) : Blob {
  Blob.fromArray(Array.tabulate<Nat8>(32, func(j) {
    if (j == 0) 0xFF else if (j == 1) Nat8.fromNat(i % 256) else Nat8.fromNat((i * 11 + j) % 256)
  }))
};

// The account id of account `i`: spread out, so ids are not 0..n and a key that truncated one would
// be caught.
func acctIdFor(i : Nat) : Nat { 1_000 + i * 13 };

// The declared class of an account, or null. Two thirds carry one, so the unclassified path is
// exercised as well as the classified one.
// Fully qualified exactly as `IndexTypes.labelOf` builds it in the bank, so the ordinals this test
// exercises are the ordinals production assigns.
func classFor(acctId : Nat) : ?Text {
  // The unclassified share and the class choice are taken from different digits, so every declared
  // class is reachable. Taking both from the same digit left one class unreachable and the test
  // counted two where three were declared.
  if (acctId % 7 == 0) null else ?("thebes.party.sector=" # CLASSES[(acctId / 13) % CLASSES.size()])
};

let idx = PIdx.newState();

// ─── I0 ──────────────────────────────────────────────────────────────────────

var registered = 0;
var i = 0;
while (i < ACCOUNTS) {
  if (not PIdx.registerAccount(idx, subledgerFor(i), acctIdFor(i))) fail("account " # Nat.toText(i) # " would not register");
  registered += 1;
  i += 1;
};
Debug.print("count: accounts registered in I0 = " # Nat.toText(registered));

// An identical re-registration is accepted; a different id for the same key is refused.
if (not PIdx.registerAccount(idx, subledgerFor(7), acctIdFor(7))) fail("an identical re-registration was refused");
if (PIdx.registerAccount(idx, subledgerFor(7), acctIdFor(8))) fail("a second account claimed a registered sub-ledger key");

var looked = 0;
i := 0;
while (i < ACCOUNTS) {
  switch (PIdx.accountOf(idx, subledgerFor(i))) {
    case (?id) { if (id != acctIdFor(i)) fail("I0 gave " # Nat.toText(id) # " for account " # Nat.toText(i)) };
    case null fail("I0 lost account " # Nat.toText(i));
  };
  looked += 1;
  i += 1;
};
Debug.print("count: I0 lookups verified = " # Nat.toText(looked));

// A key that was never registered, and a key of the wrong width.
var absent = 0;
i := 0;
while (i < 50) {
  switch (PIdx.accountOf(idx, unregisteredSubledger(i))) {
    case (?_) fail("I0 answered for an unregistered sub-ledger key");
    case null absent += 1;
  };
  i += 1;
};
switch (PIdx.accountOf(idx, Blob.fromArray([1, 2, 3]))) {
  case (?_) fail("I0 answered for a key of the wrong width");
  case null absent += 1;
};
if (PIdx.registerAccount(idx, Blob.fromArray([1, 2, 3]), 9)) fail("I0 registered a key of the wrong width");
Debug.print("count: I0 absent keys refused = " # Nat.toText(absent));

// ═══════════════════════════════════════════════════════════════════
//  THE BLOCK STREAM
// ═══════════════════════════════════════════════════════════════════

let ME = Principal.fromText("aaaaa-aa");

type Built = { block : JT.Block; record : ?JT.PostingRecord };

// Legs: one to four, each on a random account (sometimes an unregistered one, sometimes with no
// sub-ledger at all), balanced per currency so the posting is a posting and not a fragment.
func buildLegs(ccy : JT.Currency, extraCcy : ?JT.Currency) : [JT.Leg] {
  let legs = List.empty<JT.Leg>();
  let amount = 100 + below(1_000_000);
  let a = below(ACCOUNTS + 12);           // the last 12 are unregistered
  var b = below(ACCOUNTS + 12);
  if (b == a) b := (a + 1) % (ACCOUNTS + 12);
  let subA : ?JT.SubledgerKey = if (a % 17 == 0) null else ?subledgerFor(a);
  let subB : ?JT.SubledgerKey = if (b % 19 == 0) null else ?subledgerFor(b);
  List.add(legs, { account = "1100"; subledger = subA; side = #debit; currency = ccy; amount });
  List.add(legs, { account = "2100"; subledger = subB; side = #credit; currency = ccy; amount });
  switch (extraCcy) {
    case (?c2) {
      let amount2 = 50 + below(500_000);
      let c = below(ACCOUNTS);
      List.add(legs, { account = "1200"; subledger = ?subledgerFor(c); side = #debit; currency = c2; amount = amount2 });
      List.add(legs, { account = "2200"; subledger = null; side = #credit; currency = c2; amount = amount2 });
    };
    case null {};
  };
  List.toArray(legs)
};

func buildRecord(n : Nat) : JT.PostingRecord {
  let ccy = CURRENCIES[below(CURRENCIES.size())];
  let extra : ?JT.Currency = if (n % 11 == 0) ?CURRENCIES[(below(CURRENCIES.size()) + 1) % CURRENCIES.size()] else null;
  let day = DAY_BASE + below(DAY_SPAN);
  {
    idempotencyKey = Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { Nat8.fromNat((n * 5 + j) % 256) }));
    postingDate = day;
    valueDate = day;
    valueDateRequested = if (n % 13 == 0) ?(day + 1) else null;
    period = "2026-" # (if (day % 2 == 0) "09" else "10");
    legs = buildLegs(ccy, extra);
    sourceRef = { kind = "test"; id = Nat.toText(n) };
    narration = "posting " # Nat.toText(n);
    relation = if (n % 23 == 0 and n > 0) ?{ original = n - 1; kind = #correction } else null;
  }
};

// The stream, kept so `blockOf` can serve it and the oracle can fold it.
let blocks = List.empty<JT.Block>();

func emit(event : JT.Event) : JT.Block {
  let b : JT.Block = {
    index = List.size(blocks);
    timestamp = Nat32.toNat64(next());
    caller = ME;
    parentHash = null;
    hash = Blob.fromArray([0]);
    event;
  };
  List.add(blocks, b);
  b
};

let ctx : PIdx.Context = {
  classOf = func(acctId : Nat) : ?Text { classFor(acctId) };
  blockOf = func(n : Nat) : ?JT.Block { List.get(blocks, n) };
};

// Declare the currencies first, so their ordinals are registration order and not first-posting
// order; the same thing the bank does with `#currencyRegistered`.
for (c in CURRENCIES.vals()) {
  ignore PIdx.indexBlock(idx, emit(#currencyRegistered({ code = c; minorUnits = 2 })), ctx);
};
ignore PIdx.indexBlock(idx, emit(#periodOpened({ id = "2026-09"; start = DAY_BASE; end = DAY_BASE + 30 })), ctx);
ignore PIdx.indexBlock(idx, emit(#periodOpened({ id = "2026-10"; start = DAY_BASE + 31; end = DAY_BASE + 60 })), ctx);

// The postings. Four shapes, so every arm of `indexBlock` runs:
//   n % 7 == 0 → a pending, resolved later to a DIFFERENT value day;
//   n % 7 == 1 → a pending, resolved later to the SAME value day;
//   n % 7 == 2 → a pending, voided;
//   otherwise  → posted outright.
type Outstanding = { postingNo : Nat; record : JT.PostingRecord; shape : Nat };
let outstanding = List.empty<Outstanding>();

var posted = 0;
var pended = 0;
var n = 0;
while (n < POSTINGS) {
  let record = buildRecord(n);
  let shape = n % 7;
  if (shape <= 2) {
    let b = emit(#pending({ record; expiresAt = null }));
    ignore PIdx.indexBlock(idx, b, ctx);
    List.add(outstanding, { postingNo = b.index; record; shape });
    pended += 1;
  } else {
    let b = emit(#posted(record));
    ignore PIdx.indexBlock(idx, b, ctx);
    posted += 1;
  };
  n += 1;
};
Debug.print("count: postings indexed outright = " # Nat.toText(posted));
Debug.print("count: pendings indexed = " # Nat.toText(pended));

// Resolve and void them.
type Resolved = { postingNo : Nat; record : JT.PostingRecord; resolution : JT.Resolution };
let resolutions = List.empty<Resolved>();
let voided = List.empty<Nat>();
var movedDay = 0;
for (o in List.values(outstanding)) {
  if (o.shape == 2) {
    ignore PIdx.indexBlock(idx, emit(#void({ pendingIndex = o.postingNo; reason = #requested })), ctx);
    List.add(voided, o.postingNo);
  } else {
    let shifted = o.shape == 0;
    let newDay = if (shifted) (o.record.valueDate + 3) else o.record.valueDate;
    if (shifted) movedDay += 1;
    let resolution : JT.Resolution = {
      postingDate = o.record.postingDate;
      valueDate = newDay;
      valueDateRequested = if (shifted) ?o.record.valueDate else null;
      period = o.record.period;
    };
    ignore PIdx.indexBlock(idx, emit(#post({ pendingIndex = o.postingNo; resolution })), ctx);
    List.add(resolutions, { postingNo = o.postingNo; record = o.record; resolution });
  };
};
Debug.print("count: pendings resolved = " # Nat.toText(List.size(resolutions)));
Debug.print("count: resolutions that moved the value day = " # Nat.toText(movedDay));
Debug.print("count: pendings voided = " # Nat.toText(List.size(voided)));

// ═══════════════════════════════════════════════════════════════════
//  THE ORACLE; the same fold, written separately
// ═══════════════════════════════════════════════════════════════════

type Mv = { var dr : Nat; var cr : Nat };
type Row = { key : Blob; dr : Nat; cr : Nat };

// What the oracle believes about one posting.
type OHeader = {
  var valueDay : Nat;
  var postingDay : Nat;
  var ccyOrd : Nat;
  var legs : Nat;
  var accountRows : Nat;
  var status : Nat8;
  var flags : Nat8;
  var periodOrd : Nat;
};

let oHeaders = Map.empty<Nat, OHeader>();
let oI1 = Map.empty<Blob, Mv>();
let oI2 = Map.empty<Blob, Mv>();
let oI3 = Map.empty<Blob, Mv>();
let oI4 = Map.empty<Blob, Mv>();

// The oracle's own ordinal tables, assigned in first-sight order exactly as the index does.
let oCcy = Map.empty<Text, Nat>();
let oCls = Map.empty<Text, Nat>();
let oPer = Map.empty<Text, Nat>();
var oNextCcy = 0;
var oNextCls = 0;
var oNextPer = 0;
func oCcyOrd(c : Text) : Nat {
  switch (Map.get(oCcy, Text.compare, c)) {
    case (?o) o;
    case null { let o = oNextCcy; oNextCcy += 1; Map.add(oCcy, Text.compare, c, o); o };
  }
};
func oClsOrd(c : Text) : Nat {
  switch (Map.get(oCls, Text.compare, c)) {
    case (?o) o;
    case null { let o = oNextCls; oNextCls += 1; Map.add(oCls, Text.compare, c, o); o };
  }
};
func oPerOrd(c : Text) : Nat {
  switch (Map.get(oPer, Text.compare, c)) {
    case (?o) o;
    case null { let o = oNextPer; oNextPer += 1; Map.add(oPer, Text.compare, c, o); o };
  }
};

// Set, not add: `writeRows` uses `put`, which overwrites. A resolution re-indexes the same posting,
// so an oracle that accumulated would disagree with the index by exactly a factor of two; which is
// the bug this comment exists to stop coming back.
func setRow(m : Map.Map<Blob, Mv>, k : Blob, dr : Nat, cr : Nat) {
  switch (Map.get(m, Blob.compare, k)) {
    case (?c) { c.dr := dr; c.cr := cr };
    case null Map.add(m, Blob.compare, k, { var dr; var cr });
  };
};

// The oracle's account resolution: the registered map, kept in the heap.
let oLedger = Map.empty<Blob, Nat>();
i := 0;
while (i < ACCOUNTS) { Map.add(oLedger, Blob.compare, subledgerFor(i), acctIdFor(i)); i += 1 };

func oracleIndex(postingNo : Nat, record : JT.PostingRecord, valueDay : Nat, postingDay : Nat, period : Text, status : Nat8) {
  // per-key sums for this posting, so one posting contributes one row per key
  let perAcct = Map.empty<Nat, Mv>();
  let perCcy = Map.empty<Nat, Mv>();
  let perCls = Map.empty<Nat, Mv>();
  var totalDr = 0;
  var totalCr = 0;
  var primary = 0;
  var seen = false;
  var multi = false;
  var saturated = false;
  func cell(m : Map.Map<Nat, Mv>, k : Nat) : Mv {
    switch (Map.get(m, Nat.compare, k)) {
      case (?c) c;
      case null { let c : Mv = { var dr = 0; var cr = 0 }; Map.add(m, Nat.compare, k, c); c };
    }
  };
  for (leg in record.legs.vals()) {
    if (leg.amount > PIdx.MOVEMENT_CEILING) saturated := true;
    let ord = oCcyOrd(leg.currency);
    if (not seen) { primary := ord; seen := true } else if (ord != primary) { multi := true };
    let cc = cell(perCcy, ord);
    switch (leg.side) { case (#debit) cc.dr += leg.amount; case (#credit) cc.cr += leg.amount };
    if (ord == primary) {
      switch (leg.side) { case (#debit) totalDr += leg.amount; case (#credit) totalCr += leg.amount };
    };
    switch (leg.subledger) {
      case (?sub) {
        switch (Map.get(oLedger, Blob.compare, sub)) {
          case (?acctId) {
            let ca = cell(perAcct, acctId);
            switch (leg.side) { case (#debit) ca.dr += leg.amount; case (#credit) ca.cr += leg.amount };
            switch (classFor(acctId)) {
              case (?lbl) {
                let cl = cell(perCls, oClsOrd(lbl));
                switch (leg.side) { case (#debit) cl.dr += leg.amount; case (#credit) cl.cr += leg.amount };
              };
              case null {};
            };
          };
          case null {};
        };
      };
      case null {};
    };
  };
  var accountRows = 0;
  for ((acctId, m) in Map.entries(perAcct)) {
    setRow(oI1, PIdx.accountKey(acctId, valueDay, postingNo), m.dr, m.cr);
    accountRows += 1;
  };
  setRow(oI2, PIdx.dayKey(valueDay, postingNo), totalDr, totalCr);
  for ((ord, m) in Map.entries(perCcy)) {
    setRow(oI3, PIdx.currencyKey(ord, valueDay, postingNo), m.dr, m.cr);
  };
  for ((ord, m) in Map.entries(perCls)) {
    setRow(oI4, PIdx.classKey(ord, valueDay, postingNo), m.dr, m.cr);
  };
  var flags : Nat8 = 0;
  if (multi) flags += PIdx.FLAG_MULTI_CURRENCY;
  if (saturated) flags += PIdx.FLAG_SATURATED;
  switch (record.valueDateRequested) { case (?_) { flags += PIdx.FLAG_VALUE_DATE_SHIFTED }; case null {} };
  switch (record.relation) { case (?_) { flags += PIdx.FLAG_HAS_RELATION }; case null {} };
  switch (Map.get(oHeaders, Nat.compare, postingNo)) {
    case (?h) {
      h.valueDay := valueDay;
      h.postingDay := postingDay;
      h.status := status;
      h.periodOrd := oPerOrd(period);
    };
    case null {
      Map.add(oHeaders, Nat.compare, postingNo, {
        var valueDay;
        var postingDay;
        var ccyOrd = primary;
        var legs = record.legs.size();
        var accountRows;
        var status;
        var flags;
        var periodOrd = oPerOrd(period);
      });
    };
  };
};

// The oracle's fold: the same block stream, in the same order.
for (b in List.values(blocks)) {
  switch (b.event) {
    case (#currencyRegistered(info)) { ignore oCcyOrd(info.code) };
    case (#periodOpened(x)) { ignore oPerOrd(x.id) };
    case (#posted(r)) { oracleIndex(b.index, r, r.valueDate, r.postingDate, r.period, PIdx.STATUS_POSTED) };
    case (#pending(x)) { oracleIndex(b.index, x.record, x.record.valueDate, x.record.postingDate, x.record.period, PIdx.STATUS_PENDING) };
    case (#post(x)) {
      // the pending's own record, found the same way the index finds it
      let ?pb = List.get(blocks, x.pendingIndex) else Runtime.trap("the oracle cannot read the pending block");
      switch (pb.event) {
        case (#pending(p)) {
          oracleIndex(x.pendingIndex, p.record, x.resolution.valueDate, x.resolution.postingDate, x.resolution.period, PIdx.STATUS_POSTED_FROM_PENDING);
        };
        case (_) fail("the oracle found a resolution of a block that is not a pending");
      };
    };
    case (#void(x)) {
      switch (Map.get(oHeaders, Nat.compare, x.pendingIndex)) {
        case (?h) { h.status := PIdx.STATUS_VOIDED };
        case null fail("the oracle found a void of an unindexed pending");
      };
    };
    case (_) {};
  };
};

// ═══════════════════════════════════════════════════════════════════
//  COMPARISON
// ═══════════════════════════════════════════════════════════════════

// ─── headers ───
var headersChecked = 0;
for ((postingNo, o) in Map.entries(oHeaders)) {
  let ?h = PIdx.header(idx, postingNo) else Runtime.trap("no header for posting " # Nat.toText(postingNo));
  if (h.valueDay != o.valueDay) fail("header " # Nat.toText(postingNo) # " value day " # Nat.toText(h.valueDay) # " vs " # Nat.toText(o.valueDay));
  if (h.postingDay != o.postingDay) fail("header " # Nat.toText(postingNo) # " posting day");
  if (h.currencyOrd != o.ccyOrd) fail("header " # Nat.toText(postingNo) # " currency ordinal " # Nat.toText(h.currencyOrd) # " vs " # Nat.toText(o.ccyOrd));
  if (h.legs != o.legs) fail("header " # Nat.toText(postingNo) # " leg count");
  if (h.accountRows != o.accountRows) fail("header " # Nat.toText(postingNo) # " account rows " # Nat.toText(h.accountRows) # " vs " # Nat.toText(o.accountRows));
  if (h.status != o.status) fail("header " # Nat.toText(postingNo) # " status " # Nat.toText(Nat8.toNat(h.status)) # " vs " # Nat.toText(Nat8.toNat(o.status)));
  if (h.flags != o.flags) fail("header " # Nat.toText(postingNo) # " flags " # Nat.toText(Nat8.toNat(h.flags)) # " vs " # Nat.toText(Nat8.toNat(o.flags)));
  if (h.periodOrd != o.periodOrd) fail("header " # Nat.toText(postingNo) # " period ordinal");
  headersChecked += 1;
};
Debug.print("count: headers equal to the oracle = " # Nat.toText(headersChecked));

// A posting number nothing indexed has no header.
switch (PIdx.header(idx, 9_999_999)) { case (?_) fail("a header for a posting that does not exist"); case null {} };

// ─── the four indexes, row by row ───
func sortedOracle(m : Map.Map<Blob, Mv>) : [Row] {
  let out = List.empty<Row>();
  for ((k, v) in Map.entries(m)) { List.add(out, { key = k; dr = v.dr; cr = v.cr }) };
  Array.sort<Row>(List.toArray(out), func(a, b) { Blob.compare(a.key, b.key) })
};

func allRows(index : RI.State, width : Nat) : [Row] {
  let (lo, hi) = RI.rangeEnds([], width);
  let out = List.empty<Row>();
  var cursor : ?Blob = null;
  label walk loop {
    let page = RI.range(index, lo, hi, cursor, 100);
    for ((k, v) in page.entries.vals()) {
      let m = PIdx.readMovement(v);
      List.add(out, { key = k; dr = m.debits; cr = m.credits });
    };
    switch (page.cursor) { case (?c) { cursor := ?c }; case null break walk };
  };
  List.toArray(out)
};

func compare(name : Text, got : [Row], want : [Row]) {
  if (got.size() != want.size()) {
    fail(name # " holds " # Nat.toText(got.size()) # " rows, the oracle says " # Nat.toText(want.size()));
    return;
  };
  var j = 0;
  while (j < got.size()) {
    if (not Blob.equal(got[j].key, want[j].key)) fail(name # " row " # Nat.toText(j) # " has the wrong key");
    if (got[j].dr != want[j].dr) fail(name # " row " # Nat.toText(j) # " debits " # Nat.toText(got[j].dr) # " vs " # Nat.toText(want[j].dr));
    if (got[j].cr != want[j].cr) fail(name # " row " # Nat.toText(j) # " credits " # Nat.toText(got[j].cr) # " vs " # Nat.toText(want[j].cr));
    j += 1;
  };
  Debug.print("count: " # name # " rows equal to the oracle = " # Nat.toText(got.size()));
};

compare("I1", allRows(idx.byAccount, PIdx.I1_KEY), sortedOracle(oI1));
compare("I2", allRows(idx.byDay, PIdx.I2_KEY), sortedOracle(oI2));
compare("I3", allRows(idx.byCurrency, PIdx.I3_KEY), sortedOracle(oI3));
compare("I4", allRows(idx.byClass, PIdx.I4_KEY), sortedOracle(oI4));

// ─── the query the index exists for: an account over a date window ───
var windows = 0;
var windowRows = 0;
var j = 0;
while (j < 120) {
  let a = acctIdFor(below(ACCOUNTS));
  let from = DAY_BASE + below(DAY_SPAN);
  let to = from + below(12);
  let (lo, hi) = PIdx.accountRangeEnds(a, from, to);
  // the index's answer, paged at a size that forces several pages
  let got = List.empty<Row>();
  var cursor : ?Blob = null;
  label walk loop {
    let page = RI.range(idx.byAccount, lo, hi, cursor, 7);
    for ((k, v) in page.entries.vals()) {
      let m = PIdx.readMovement(v);
      List.add(got, { key = k; dr = m.debits; cr = m.credits });
    };
    switch (page.cursor) { case (?c) { cursor := ?c }; case null break walk };
  };
  // the oracle's answer
  let want = List.empty<Row>();
  for (r in sortedOracle(oI1).vals()) {
    let parts = PIdx.splitAccountKey(r.key);
    if (parts.acctId == a and parts.valueDay >= from and parts.valueDay <= to) List.add(want, r);
  };
  let g = List.toArray(got);
  let w = List.toArray(want);
  if (g.size() != w.size()) fail("account window " # Nat.toText(a) # " [" # Nat.toText(from) # "," # Nat.toText(to) # "] gave " # Nat.toText(g.size()) # " rows, the oracle " # Nat.toText(w.size()));
  var q = 0;
  while (q < g.size()) {
    if (not Blob.equal(g[q].key, w[q].key)) fail("account window row " # Nat.toText(q) # " key");
    if (g[q].dr != w[q].dr or g[q].cr != w[q].cr) fail("account window row " # Nat.toText(q) # " movement");
    q += 1;
  };
  windowRows += g.size();
  windows += 1;
  j += 1;
};
Debug.print("count: account-and-date windows verified = " # Nat.toText(windows));
Debug.print("count: rows returned across those windows = " # Nat.toText(windowRows));

// ─── staleness: a resolution that moved the day leaves the old rows, and isLive drops them ───
var staleFound = 0;
var liveFound = 0;
for (r in List.values(resolutions)) {
  if (r.resolution.valueDate != r.record.valueDate) {
    // the old day's day-index row still exists, and is not live
    switch (PIdx.movementOf(idx.byDay, PIdx.dayKey(r.record.valueDate, r.postingNo))) {
      case (?_) {
        if (PIdx.isLive(idx, r.postingNo, r.record.valueDate)) fail("a superseded row reports itself live");
        staleFound += 1;
      };
      case null fail("the superseded row at the original day is gone");
    };
    switch (PIdx.movementOf(idx.byDay, PIdx.dayKey(r.resolution.valueDate, r.postingNo))) {
      case (?_) {
        if (not PIdx.isLive(idx, r.postingNo, r.resolution.valueDate)) fail("the resolved row does not report itself live");
        liveFound += 1;
      };
      case null fail("no row at the resolved value day");
    };
  };
};
Debug.print("count: superseded rows identified as stale = " # Nat.toText(staleFound));
Debug.print("count: resolved rows identified as live = " # Nat.toText(liveFound));

// The account rows moved too, which is what needed the record read back.
var movedAccountRows = 0;
for (r in List.values(resolutions)) {
  if (r.resolution.valueDate != r.record.valueDate) {
    for (leg in r.record.legs.vals()) {
      switch (leg.subledger) {
        case (?sub) {
          switch (PIdx.accountOf(idx, sub)) {
            case (?acctId) {
              switch (PIdx.movementOf(idx.byAccount, PIdx.accountKey(acctId, r.resolution.valueDate, r.postingNo))) {
                case (?_) movedAccountRows += 1;
                case null fail("account " # Nat.toText(acctId) # " has no row at the resolved value day of posting " # Nat.toText(r.postingNo));
              };
            };
            case null {};
          };
        };
        case null {};
      };
    };
  };
};
Debug.print("count: account rows present at the resolved value day = " # Nat.toText(movedAccountRows));

// ─── a leg at the ceiling: saturated and flagged, not truncated silently ───
let huge = PIdx.MOVEMENT_CEILING + 1_000;
let bigRecord : JT.PostingRecord = {
  idempotencyKey = Blob.fromArray(Array.tabulate<Nat8>(32, func(k) { Nat8.fromNat((k * 3 + 11) % 256) }));
  postingDate = DAY_BASE + 1;
  valueDate = DAY_BASE + 1;
  valueDateRequested = null;
  period = "2026-09";
  legs = [
    { account = "1100"; subledger = ?subledgerFor(3); side = #debit; currency = "EGP"; amount = huge },
    { account = "2100"; subledger = ?subledgerFor(4); side = #credit; currency = "EGP"; amount = huge },
  ];
  sourceRef = { kind = "test"; id = "huge" };
  narration = "a leg past the eight-byte field";
  relation = null;
};
let bigBlock = emit(#posted(bigRecord));
ignore PIdx.indexBlock(idx, bigBlock, ctx);
let ?bigHeader = PIdx.header(idx, bigBlock.index) else Runtime.trap("no header for the saturated posting");
if (not PIdx.hasFlag(bigHeader.flags, PIdx.FLAG_SATURATED)) fail("the saturated posting is not flagged");
switch (PIdx.movementOf(idx.byAccount, PIdx.accountKey(acctIdFor(3), DAY_BASE + 1, bigBlock.index))) {
  case (?m) {
    if (m.debits != PIdx.MOVEMENT_CEILING) fail("a saturated field holds " # Nat.toText(m.debits) # " rather than the ceiling");
  };
  case null fail("no row for the saturated posting");
};
Debug.print("count: saturated legs indexed at the ceiling and flagged = 1");

// ─── the flags, counted against the oracle ───
var multiCount = 0;
var shiftedCount = 0;
var relationCount = 0;
for ((postingNo, o) in Map.entries(oHeaders)) {
  if (PIdx.hasFlag(o.flags, PIdx.FLAG_MULTI_CURRENCY)) multiCount += 1;
  if (PIdx.hasFlag(o.flags, PIdx.FLAG_VALUE_DATE_SHIFTED)) shiftedCount += 1;
  if (PIdx.hasFlag(o.flags, PIdx.FLAG_HAS_RELATION)) relationCount += 1;
  ignore postingNo;
};
Debug.print("count: multi-currency postings = " # Nat.toText(multiCount));
Debug.print("count: postings with a shifted value date = " # Nat.toText(shiftedCount));
Debug.print("count: postings carrying a relation = " # Nat.toText(relationCount));

// ─── the capacity model's leaf capacities ───
let st = PIdx.stats(idx);
func expectCap(name : Text, got : Nat, want : Nat) {
  if (got != want) fail(name # " holds " # Nat.toText(got) # " entries a leaf, the capacity model says " # Nat.toText(want));
};
expectCap("the header store", st.headers.leafCap, (8192 - 9) / (PIdx.HEADER_KEY + PIdx.HEADER_VAL));
expectCap("I0", st.ledger.leafCap, (8192 - 9) / (PIdx.LEDGER_KEY + PIdx.LEDGER_VAL));
expectCap("I1", st.i1.leafCap, 227);
expectCap("I2", st.i2.leafCap, 292);
expectCap("I3", st.i3.leafCap, 255);
expectCap("I4", st.i4.leafCap, 255);
Debug.print("count: leaf capacities asserted against the capacity model = 6");

Debug.print("stable-memory bytes across every index = " # Nat.toText(st.bytes));
Debug.print("rows written across I1..I4 = " # Nat.toText(st.rows));
Debug.print("postings with a header = " # Nat.toText(st.postings));
Debug.print("currencies / classes / periods = " # Nat.toText(st.currencies) # " / " # Nat.toText(st.classes) # " / " # Nat.toText(st.periods));
Debug.print("I1 depth / leaf fill % = " # Nat.toText(st.i1.depth) # " / " # Nat.toText(st.i1.leafFillPercent));
Debug.print("I2 depth / leaf fill % = " # Nat.toText(st.i2.depth) # " / " # Nat.toText(st.i2.leafFillPercent));

if (st.postings != headersChecked + 1) fail("the index counts " # Nat.toText(st.postings) # " postings, the oracle " # Nat.toText(headersChecked + 1));
if (st.currencies != oNextCcy) fail("currency ordinals disagree");
if (st.classes != oNextCls) fail("class ordinals disagree: " # Nat.toText(st.classes) # " vs " # Nat.toText(oNextCls));
if (st.periods != oNextPer) fail("period ordinals disagree");

Debug.print("PostingIndex: every row, header, window and flag equals the oracle");
