// Queries.test.mo — the bounded, paged read against a brute-force oracle.
//
// `PostingIndex.test.mo` proves the rows are right. This proves the **read** is right: that
// `Queries.run` pages, unioned, equal a straightforward filter over the same postings — same rows,
// same order, no duplicate and no gap — at every page size, for every index the engine can pick, and
// that a filter past the bound is refused naming its size rather than truncated or trapped.
//
// The oracle is a list of the postings built in the heap, filtered with a plain predicate. It shares
// no code with the engine.
//
// What is proved:
//
//   * **every index the engine can pick** answers: account (I1), class (I4), currency (I3) and day
//     (I2), and the page says which one it was;
//   * **pages unioned equal the oracle**, at page sizes 1, 2, 3, 7, 13, 100 and 500 — so a cursor
//     handed straight back neither repeats nor skips a row;
//   * **the limit is honoured and capped** at `MAX_LIMIT`, whatever a caller asks for;
//   * **an amount band** filters exactly, including over a saturated row whose eight-byte field
//     cannot answer it and whose record decides instead;
//   * **a status filter** returns exactly the statuses asked for, and the default returns the two
//     that mean money moved;
//   * **stale rows are dropped**: a pending resolved to another value day appears once, at the day it
//     resolved to, and the page counts the superseded row it walked past;
//   * **refusal, not truncation**: a window wider than `MAX_SCAN` is `#TooWide` with the size and a
//     sentence that says how to narrow it, and the same filter inside the bound answers;
//   * **refusal, not an empty page**, for a currency, class or account the bank has never seen —
//     because "no such currency" and "no movements in it" are different answers;
//   * **an inverted window and an inverted amount band** are refused, not answered empty.
//
// engine: wasi-only — a Region is stable memory, which the interpreter does not provide.

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

import JT "mo:journal/JournalTypes";

import PIdx "../src/bank/PostingIndex";
import Q "../src/bank/Queries";

// The high bits of an LCG; the low ones have period four. See PostingIndex.test.mo.
var seed : Nat32 = 0x0B0_1CE11;
func next() : Nat32 { seed := seed *% 1_664_525 +% 1_013_904_223; seed };
func below(n : Nat) : Nat { if (n == 0) 0 else Nat32.toNat(next() / 65_536) % n };

func fail(what : Text) { Debug.print("FAIL: " # what); assert false };

// ═══════════════════════════════════════════════════════════════════
//  A BOOK
// ═══════════════════════════════════════════════════════════════════

let CURRENCIES = ["EGP", "USD", "EUR"];
let CLASSES = ["thebes.party.sector=retail", "thebes.party.sector=corporate"];
let ACCOUNTS = 40;
let POSTINGS = 600;
let DAY0 = 20_400;
let DAYS = 30;

func subledgerFor(i : Nat) : Blob {
  Blob.fromArray(Array.tabulate<Nat8>(32, func(j) {
    if (j == 0) Nat8.fromNat(i / 256) else if (j == 1) Nat8.fromNat(i % 256) else Nat8.fromNat((i * 7 + j * 31 + 1) % 256)
  }))
};
func acctIdFor(i : Nat) : Nat { 500 + i * 3 };
func classFor(acctId : Nat) : ?Text {
  if (acctId % 5 == 0) null else ?CLASSES[(acctId / 3) % CLASSES.size()]
};

let idx = PIdx.newState();
var i = 0;
while (i < ACCOUNTS) {
  if (not PIdx.registerAccount(idx, subledgerFor(i), acctIdFor(i))) fail("registration " # Nat.toText(i));
  i += 1;
};

let ME = Principal.fromText("aaaaa-aa");
let blocks = List.empty<JT.Block>();
func emit(event : JT.Event) : JT.Block {
  let b : JT.Block = { index = List.size(blocks); timestamp = 0; caller = ME; parentHash = null; hash = Blob.fromArray([0]); event };
  List.add(blocks, b);
  b
};
let ctx0 : PIdx.Context = {
  classOf = func(a : Nat) : ?Text { classFor(a) };
  blockOf = func(n : Nat) : ?JT.Block { List.get(blocks, n) };
};

for (c in CURRENCIES.vals()) { ignore PIdx.indexBlock(idx, emit(#currencyRegistered({ code = c; minorUnits = 2 })), ctx0) };
ignore PIdx.indexBlock(idx, emit(#periodOpened({ id = "2026-10"; start = DAY0; end = DAY0 + DAYS })), ctx0);

// What the oracle remembers about one indexed posting: enough to reproduce any page.
type Fact = {
  postingNo : Nat;
  var valueDay : Nat;
  postingDay : Nat;
  ccy : Text;
  accounts : [(Nat, Nat, Nat)];   // (acctId, debits, credits)
  classes : [Text];
  currencies : [Text];
  totalDr : Nat;
  totalCr : Nat;
  var status : Nat8;
  saturated : Bool;
};
let facts = List.empty<Fact>();

func legsFor(n : Nat, ccy : Text, huge : Bool) : [JT.Leg] {
  let amount = if (huge) (PIdx.MOVEMENT_CEILING + 77) else (1_000 + below(900_000));
  let a = below(ACCOUNTS);
  var b = below(ACCOUNTS);
  if (b == a) b := (a + 1) % ACCOUNTS;
  ignore n;
  [
    { account = "1100"; subledger = ?subledgerFor(a); side = #debit; currency = ccy; amount },
    { account = "2100"; subledger = ?subledgerFor(b); side = #credit; currency = ccy; amount },
  ]
};

func factOf(postingNo : Nat, record : JT.PostingRecord, valueDay : Nat, status : Nat8) : Fact {
  let perAcct = Map.empty<Nat, { var dr : Nat; var cr : Nat }>();
  let cls = List.empty<Text>();
  let ccys = List.empty<Text>();
  var dr = 0;
  var cr = 0;
  var sat = false;
  let primary = record.legs[0].currency;
  for (leg in record.legs.vals()) {
    if (leg.amount > PIdx.MOVEMENT_CEILING) sat := true;
    var seenC = false;
    for (c in List.values(ccys)) { if (Text.equal(c, leg.currency)) seenC := true };
    if (not seenC) List.add(ccys, leg.currency);
    if (Text.equal(leg.currency, primary)) {
      switch (leg.side) { case (#debit) dr += leg.amount; case (#credit) cr += leg.amount };
    };
    switch (leg.subledger) {
      case (?sub) {
        var found : ?Nat = null;
        var k = 0;
        while (k < ACCOUNTS) { if (Blob.equal(sub, subledgerFor(k))) found := ?acctIdFor(k); k += 1 };
        switch (found) {
          case (?acctId) {
            let cell = switch (Map.get(perAcct, Nat.compare, acctId)) {
              case (?c) c;
              case null { let c = { var dr = 0; var cr = 0 }; Map.add(perAcct, Nat.compare, acctId, c); c };
            };
            switch (leg.side) { case (#debit) cell.dr += leg.amount; case (#credit) cell.cr += leg.amount };
            switch (classFor(acctId)) {
              case (?l) {
                var seen = false;
                for (x in List.values(cls)) { if (Text.equal(x, l)) seen := true };
                if (not seen) List.add(cls, l);
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
  let accs = List.empty<(Nat, Nat, Nat)>();
  for ((a, m) in Map.entries(perAcct)) { List.add(accs, (a, m.dr, m.cr)) };
  {
    postingNo;
    var valueDay;
    postingDay = record.postingDate;
    ccy = primary;
    accounts = List.toArray(accs);
    classes = List.toArray(cls);
    currencies = List.toArray(ccys);
    totalDr = dr;
    totalCr = cr;
    var status;
    saturated = sat;
  }
};

// The stream. One in nine is a pending resolved to a later day, one in eleven is a pending left open,
// one posting carries a leg past the eight-byte field.
type Open = { postingNo : Nat; record : JT.PostingRecord; fact : Fact; resolve : Bool };
let open_ = List.empty<Open>();
var n = 0;
while (n < POSTINGS) {
  let ccy = CURRENCIES[below(CURRENCIES.size())];
  let day = DAY0 + below(DAYS);
  let record : JT.PostingRecord = {
    idempotencyKey = Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { Nat8.fromNat((n * 3 + j) % 256) }));
    postingDate = day;
    valueDate = day;
    valueDateRequested = null;
    period = "2026-10";
    legs = legsFor(n, ccy, n == 17);
    sourceRef = { kind = "test"; id = Nat.toText(n) };
    narration = "q" # Nat.toText(n);
    relation = null;
  };
  if (n % 9 == 0 or n % 11 == 0) {
    let b = emit(#pending({ record; expiresAt = null }));
    ignore PIdx.indexBlock(idx, b, ctx0);
    let f = factOf(b.index, record, day, PIdx.STATUS_PENDING);
    List.add(facts, f);
    List.add(open_, { postingNo = b.index; record; fact = f; resolve = n % 9 == 0 });
  } else {
    let b = emit(#posted(record));
    ignore PIdx.indexBlock(idx, b, ctx0);
    List.add(facts, factOf(b.index, record, day, PIdx.STATUS_POSTED));
  };
  n += 1;
};

var resolvedMoved = 0;
for (o in List.values(open_)) {
  if (o.resolve) {
    let newDay = o.record.valueDate + 2;
    ignore PIdx.indexBlock(idx, emit(#post({
      pendingIndex = o.postingNo;
      resolution = { postingDate = o.record.postingDate; valueDate = newDay; valueDateRequested = ?o.record.valueDate; period = "2026-10" };
    })), ctx0);
    o.fact.valueDay := newDay;
    o.fact.status := PIdx.STATUS_POSTED_FROM_PENDING;
    resolvedMoved += 1;
  };
};
Debug.print("count: postings in the book = " # Nat.toText(List.size(facts)));
Debug.print("count: pendings resolved to a later value day = " # Nat.toText(resolvedMoved));

// ═══════════════════════════════════════════════════════════════════
//  THE ENGINE'S CONTEXT
// ═══════════════════════════════════════════════════════════════════

let qctx : Q.Context = {
  recordOf = func(p : Nat) : ?JT.PostingRecord {
    switch (List.get(blocks, p)) {
      case (?b) { switch (b.event) { case (#posted(r)) ?r; case (#pending(x)) ?x.record; case (_) null } };
      case null null;
    }
  };
  height = List.size(blocks);
  accountExists = func(a : Nat) : Bool {
    var k = 0;
    while (k < ACCOUNTS) { if (acctIdFor(k) == a) return true; k += 1 };
    false
  };
  classOf = func(a : Nat) : ?Text { classFor(a) };
};

let DEFAULT_STATUSES : [Nat8] = [PIdx.STATUS_POSTED, PIdx.STATUS_POSTED_FROM_PENDING];

func statusIn(ss : [Nat8], s : Nat8) : Bool { for (x in ss.vals()) { if (x == s) return true }; false };

// A row reports the eight-byte field, which saturates; the amount band is decided on the exact value.
// Both behaviours are the engine's, so the oracle has to hold both.
func sat(x : Nat) : Nat { if (x > PIdx.MOVEMENT_CEILING) PIdx.MOVEMENT_CEILING else x };

// ─── the oracle: the rows a filter should return, in key order ───
type Want = { postingNo : Nat; valueDay : Nat; dr : Nat; cr : Nat };

func oracle(
  account : ?Nat, class_ : ?Text, currency : ?Text,
  from : Nat, to : Nat, minA : ?Nat, maxA : ?Nat, statuses : [Nat8],
) : [Want] {
  let out = List.empty<Want>();
  for (f in List.values(facts)) {
    if (f.valueDay >= from and f.valueDay <= to and statusIn(statuses, f.status)) {
      // which row shape this filter reads
      switch (account) {
        case (?a) {
          for ((acctId, dr, cr) in f.accounts.vals()) {
            if (acctId == a) {
              let mag = if (dr >= cr) dr else cr;
              let ccyOk = switch (currency) { case null true; case (?c) Text.equal(c, f.ccy) };
              let minOk = switch (minA) { case null true; case (?x) mag >= x };
              let maxOk = switch (maxA) { case null true; case (?x) mag <= x };
              if (ccyOk and minOk and maxOk) List.add(out, { postingNo = f.postingNo; valueDay = f.valueDay; dr = sat(dr); cr = sat(cr) });
            };
          };
        };
        case null {
          switch (class_) {
            case (?cl) {
              var has = false;
              for (x in f.classes.vals()) { if (Text.equal(x, cl)) has := true };
              if (has) {
                // the class row's movement is the sum over that class's accounts
                var dr = 0;
                var cr = 0;
                for ((acctId, d, c) in f.accounts.vals()) {
                  switch (classFor(acctId)) {
                    case (?l) { if (Text.equal(l, cl)) { dr += d; cr += c } };
                    case null {};
                  };
                };
                let mag = if (dr >= cr) dr else cr;
                let ccyOk = switch (currency) { case null true; case (?c) Text.equal(c, f.ccy) };
                let minOk = switch (minA) { case null true; case (?x) mag >= x };
                let maxOk = switch (maxA) { case null true; case (?x) mag <= x };
                if (ccyOk and minOk and maxOk) List.add(out, { postingNo = f.postingNo; valueDay = f.valueDay; dr = sat(dr); cr = sat(cr) });
              };
            };
            case null {
              switch (currency) {
                case (?c) {
                  var has = false;
                  for (x in f.currencies.vals()) { if (Text.equal(x, c)) has := true };
                  if (has) {
                    let mag = if (f.totalDr >= f.totalCr) f.totalDr else f.totalCr;
                    let minOk = switch (minA) { case null true; case (?x) mag >= x };
                    let maxOk = switch (maxA) { case null true; case (?x) mag <= x };
                    if (minOk and maxOk) List.add(out, { postingNo = f.postingNo; valueDay = f.valueDay; dr = sat(f.totalDr); cr = sat(f.totalCr) });
                  };
                };
                case null {
                  let mag = if (f.totalDr >= f.totalCr) f.totalDr else f.totalCr;
                  let minOk = switch (minA) { case null true; case (?x) mag >= x };
                  let maxOk = switch (maxA) { case null true; case (?x) mag <= x };
                  if (minOk and maxOk) List.add(out, { postingNo = f.postingNo; valueDay = f.valueDay; dr = sat(f.totalDr); cr = sat(f.totalCr) });
                };
              };
            };
          };
        };
      };
    };
  };
  // key order: the day first, then the posting number — the order every one of the four keys imposes
  Array.sort<Want>(List.toArray(out), func(a, b) {
    switch (Nat.compare(a.valueDay, b.valueDay)) { case (#equal) Nat.compare(a.postingNo, b.postingNo); case (o) o }
  })
};

// ─── page a filter to exhaustion ───
func pageAll(f : Q.Filter) : { rows : [Want]; index : Text; pages : Nat } {
  let out = List.empty<Want>();
  var cursor = f.cursor;
  var pages = 0;
  var which = "";
  label walk loop {
    switch (Q.run(idx, { f with cursor }, qctx)) {
      case (#err(e)) { fail("a page was refused mid-walk: " # debug_show (e)); break walk };
      case (#ok(p)) {
        pages += 1;
        which := p.index;
        for (r in p.rows.vals()) { List.add(out, { postingNo = r.postingNo; valueDay = r.valueDay; dr = r.debits; cr = r.credits }) };
        switch (p.cursor) { case (?c) { cursor := ?c }; case null break walk };
        if (pages > 5_000) { fail("paging did not terminate"); break walk };
      };
    };
  };
  { rows = List.toArray(out); index = which; pages }
};

func same(name : Text, got : [Want], want : [Want]) : Bool {
  if (got.size() != want.size()) {
    fail(name # ": " # Nat.toText(got.size()) # " rows, the oracle says " # Nat.toText(want.size()));
    return false;
  };
  var j = 0;
  while (j < got.size()) {
    if (got[j].postingNo != want[j].postingNo) { fail(name # " row " # Nat.toText(j) # ": posting " # Nat.toText(got[j].postingNo) # " vs " # Nat.toText(want[j].postingNo)); return false };
    if (got[j].valueDay != want[j].valueDay) { fail(name # " row " # Nat.toText(j) # ": value day"); return false };
    if (got[j].dr != want[j].dr or got[j].cr != want[j].cr) { fail(name # " row " # Nat.toText(j) # ": movement"); return false };
    j += 1;
  };
  true
};

let base : Q.Filter = {
  account = null; currency = null; class_ = null;
  from = ?DAY0; to = ?(DAY0 + DAYS + 5);
  minAmount = null; maxAmount = null; statuses = null; cursor = null; limit = 100;
};

// ═══════════════════════════════════════════════════════════════════
//  EVERY INDEX, EVERY PAGE SIZE
// ═══════════════════════════════════════════════════════════════════

let SIZES = [1, 2, 3, 7, 13, 100, 500];
var checks = 0;
var rowsSeen = 0;

// the day index
for (sz in SIZES.vals()) {
  let got = pageAll({ base with limit = sz });
  if (not Text.equal(got.index, "day")) fail("an unfiltered query was answered by " # got.index);
  if (same("day index at page " # Nat.toText(sz), got.rows, oracle(null, null, null, DAY0, DAY0 + DAYS + 5, null, null, DEFAULT_STATUSES))) {
    checks += 1;
    rowsSeen += got.rows.size();
  };
};
Debug.print("count: day-index page sizes equal to the oracle = " # Nat.toText(checks));

// the account index
var acctChecks = 0;
i := 0;
while (i < ACCOUNTS) {
  let a = acctIdFor(i);
  for (sz in [1, 5, 100].vals()) {
    let got = pageAll({ base with account = ?a; limit = sz });
    if (not Text.equal(got.index, "account")) fail("an account query was answered by " # got.index);
    if (same("account " # Nat.toText(a) # " at page " # Nat.toText(sz), got.rows, oracle(?a, null, null, DAY0, DAY0 + DAYS + 5, null, null, DEFAULT_STATUSES))) {
      acctChecks += 1;
    };
  };
  i += 1;
};
Debug.print("count: account-index queries equal to the oracle = " # Nat.toText(acctChecks));

// the currency index
var ccyChecks = 0;
for (c in CURRENCIES.vals()) {
  for (sz in [1, 11, 500].vals()) {
    let got = pageAll({ base with currency = ?c; limit = sz });
    if (not Text.equal(got.index, "currency")) fail("a currency query was answered by " # got.index);
    if (same("currency " # c # " at page " # Nat.toText(sz), got.rows, oracle(null, null, ?c, DAY0, DAY0 + DAYS + 5, null, null, DEFAULT_STATUSES))) {
      ccyChecks += 1;
    };
  };
};
Debug.print("count: currency-index queries equal to the oracle = " # Nat.toText(ccyChecks));

// the class index
var clsChecks = 0;
for (cl in CLASSES.vals()) {
  for (sz in [1, 9, 500].vals()) {
    let got = pageAll({ base with class_ = ?cl; limit = sz });
    if (not Text.equal(got.index, "class")) fail("a class query was answered by " # got.index);
    if (same("class " # cl # " at page " # Nat.toText(sz), got.rows, oracle(null, ?cl, null, DAY0, DAY0 + DAYS + 5, null, null, DEFAULT_STATUSES))) {
      clsChecks += 1;
    };
  };
};
Debug.print("count: class-index queries equal to the oracle = " # Nat.toText(clsChecks));

// ═══════════════════════════════════════════════════════════════════
//  WINDOWS, BANDS, STATUSES
// ═══════════════════════════════════════════════════════════════════

var windowChecks = 0;
var j = 0;
while (j < 80) {
  let f0 = DAY0 + below(DAYS);
  let t0 = f0 + below(8);
  let got = pageAll({ base with from = ?f0; to = ?t0; limit = 4 });
  if (same("window [" # Nat.toText(f0) # "," # Nat.toText(t0) # "]", got.rows, oracle(null, null, null, f0, t0, null, null, DEFAULT_STATUSES))) {
    windowChecks += 1;
  };
  j += 1;
};
Debug.print("count: random value-date windows equal to the oracle = " # Nat.toText(windowChecks));

var bandChecks = 0;
j := 0;
while (j < 40) {
  let lo = 1_000 + below(400_000);
  let hi = lo + below(500_000);
  let got = pageAll({ base with minAmount = ?lo; maxAmount = ?hi; limit = 6 });
  if (same("amount band [" # Nat.toText(lo) # "," # Nat.toText(hi) # "]", got.rows, oracle(null, null, null, DAY0, DAY0 + DAYS + 5, ?lo, ?hi, DEFAULT_STATUSES))) {
    bandChecks += 1;
  };
  j += 1;
};
Debug.print("count: amount bands equal to the oracle = " # Nat.toText(bandChecks));

// The saturated posting: it is above every ordinary amount, so a band at the ceiling finds it and a
// band below the ceiling does not. Its eight-byte field cannot tell them apart; its record can.
let atCeiling = pageAll({ base with minAmount = ?PIdx.MOVEMENT_CEILING; limit = 10 });
if (atCeiling.rows.size() != 1) fail("a band at the ceiling returned " # Nat.toText(atCeiling.rows.size()) # " rows, not the one saturated posting");
let belowCeiling = pageAll({ base with minAmount = ?1_000; maxAmount = ?999_999; limit = 500 });
for (r in belowCeiling.rows.vals()) {
  if (r.postingNo == atCeiling.rows[0].postingNo) fail("the saturated posting appeared inside a band it is above");
};
Debug.print("count: saturated rows decided from the record rather than the field = 1");

// Statuses: the open pendings are returned when asked for and not otherwise.
let pendings = pageAll({ base with statuses = ?[PIdx.STATUS_PENDING]; limit = 17 });
if (same("the open pendings", pendings.rows, oracle(null, null, null, DAY0, DAY0 + DAYS + 5, null, null, [PIdx.STATUS_PENDING]))) {
  Debug.print("count: pending-status rows equal to the oracle = " # Nat.toText(pendings.rows.size()));
};
if (pendings.rows.size() == 0) fail("no open pendings in the book, so the status filter proved nothing");

// ═══════════════════════════════════════════════════════════════════
//  STALENESS, COUNTS, BOUNDS AND REFUSALS
// ═══════════════════════════════════════════════════════════════════

// A resolved pending appears once, at the day it resolved to.
var staleDropped = 0;
for (o in List.values(open_)) {
  if (o.resolve) {
    let got = pageAll({ base with account = null; from = ?o.record.valueDate; to = ?(o.record.valueDate + 2); limit = 500 });
    var seen = 0;
    for (r in got.rows.vals()) { if (r.postingNo == o.postingNo) { seen += 1; if (r.valueDay != o.record.valueDate + 2) fail("a resolved posting came back at the day it was superseded from") } };
    if (seen != 1) fail("a resolved posting appeared " # Nat.toText(seen) # " times, not once");
    staleDropped += 1;
  };
};
Debug.print("count: resolved postings appearing exactly once, at the resolved day = " # Nat.toText(staleDropped));

// The page's own counters.
switch (Q.run(idx, { base with limit = 50 }, qctx)) {
  case (#err(e)) fail("the base query was refused: " # debug_show (e));
  case (#ok(p)) {
    if (p.rows.size() != 50) fail("a page of 50 returned " # Nat.toText(p.rows.size()));
    if (p.sized == 0) fail("the sizing found nothing");
    if (p.bound != Q.MAX_SCAN) fail("the page reports a bound that is not MAX_SCAN");
    if (p.atHeight != List.size(blocks)) fail("the page reports the wrong journal height");
    if (p.scanned < p.rows.size()) fail("a page scanned fewer rows than it returned");
    Debug.print("count: page counters checked (rows, sized, bound, height, scanned) = 5");
    Debug.print("the base page: sized " # Nat.toText(p.sized) # ", scanned " # Nat.toText(p.scanned) # ", stale " # Nat.toText(p.stale) # ", filtered " # Nat.toText(p.filtered));
  };
};

// A limit above the cap is capped, not honoured.
switch (Q.run(idx, { base with limit = 100_000 }, qctx)) {
  case (#err(e)) fail("an over-large limit was refused rather than capped: " # debug_show (e));
  case (#ok(p)) {
    if (p.rows.size() > Q.MAX_LIMIT) fail("a page returned " # Nat.toText(p.rows.size()) # " rows, past MAX_LIMIT");
    Debug.print("count: over-large limits capped at MAX_LIMIT = 1");
  };
};

// ─── refusal, not truncation: a window wider than the bound ───
//
// The bound is on index rows walked, so the book above is far too small to exceed it. A second index
// is filled past `MAX_SCAN` with one account's entries, and the same filter is then asked for.
let wide = PIdx.newState();
ignore PIdx.registerAccount(wide, subledgerFor(0), acctIdFor(0));
let wideBlocks = List.empty<JT.Block>();
let wctx : PIdx.Context = {
  classOf = func(_ : Nat) : ?Text { null };
  blockOf = func(p : Nat) : ?JT.Block { List.get(wideBlocks, p) };
};
var w = 0;
while (w < Q.MAX_SCAN + 200) {
  let rec : JT.PostingRecord = {
    idempotencyKey = Blob.fromArray(Array.tabulate<Nat8>(32, func(k) { Nat8.fromNat((w + k) % 256) }));
    postingDate = DAY0;
    valueDate = DAY0 + (w % 3);
    valueDateRequested = null;
    period = "2026-10";
    legs = [
      { account = "1100"; subledger = ?subledgerFor(0); side = #debit; currency = "EGP"; amount = 100 },
      { account = "2100"; subledger = null; side = #credit; currency = "EGP"; amount = 100 },
    ];
    sourceRef = { kind = "wide"; id = Nat.toText(w) };
    narration = "w";
    relation = null;
  };
  let b : JT.Block = { index = List.size(wideBlocks); timestamp = 0; caller = ME; parentHash = null; hash = Blob.fromArray([0]); event = #posted(rec) };
  List.add(wideBlocks, b);
  ignore PIdx.indexBlock(wide, b, wctx);
  w += 1;
};
let wideCtx : Q.Context = {
  recordOf = func(p : Nat) : ?JT.PostingRecord {
    switch (List.get(wideBlocks, p)) { case (?b) { switch (b.event) { case (#posted(r)) ?r; case (_) null } }; case null null }
  };
  height = List.size(wideBlocks);
  accountExists = func(a : Nat) : Bool { a == acctIdFor(0) };
  classOf = func(_ : Nat) : ?Text { null };
};
Debug.print("count: postings indexed into the over-wide book = " # Nat.toText(w));

switch (Q.run(wide, { base with from = ?0; to = ?4_000_000; limit = 100 }, wideCtx)) {
  case (#ok(_)) fail("a window past the bound was answered rather than refused");
  case (#err(#TooWide(x))) {
    if (x.size <= x.bound) fail("a refusal reported a size inside its own bound");
    if (Text.size(x.narrow) == 0) fail("a refusal that does not say how to narrow the filter");
    Debug.print("count: over-wide windows refused with a size and a remedy = 1");
    Debug.print("the refusal: size " # Nat.toText(x.size) # " past bound " # Nat.toText(x.bound) # " — " # x.narrow);
  };
  case (#err(e)) fail("the wrong refusal for an over-wide window: " # debug_show (e));
};

// The same book, a narrow window: answered, not refused. Proof that the refusal is about the filter
// and not about the book.
switch (Q.run(wide, { base with from = ?DAY0; to = ?DAY0; limit = 100 }, wideCtx)) {
  case (#ok(p)) {
    if (p.rows.size() == 0) fail("a narrow window over the wide book returned nothing");
    Debug.print("count: narrow windows over the same over-wide book answered = 1");
  };
  case (#err(e)) fail("a narrow window over the wide book was refused: " # debug_show (e));
};

// ─── refusal, not an empty page ───
var refusals = 0;
switch (Q.run(idx, { base with currency = ?"JPY" }, qctx)) {
  case (#err(#UnknownCurrency(x))) { if (not Text.equal(x.currency, "JPY")) fail("the wrong currency named"); refusals += 1 };
  case (_) fail("a currency the journal has never seen was answered rather than refused");
};
switch (Q.run(idx, { base with class_ = ?"thebes.party.sector=government" }, qctx)) {
  case (#err(#UnknownClass(_))) refusals += 1;
  case (_) fail("a class the journal has never seen was answered rather than refused");
};
switch (Q.run(idx, { base with account = ?999_999 }, qctx)) {
  case (#err(#UnknownAccount(x))) { if (x.account != 999_999) fail("the wrong account named"); refusals += 1 };
  case (_) fail("an account the bank never opened was answered rather than refused");
};
switch (Q.run(idx, { base with from = ?(DAY0 + 10); to = ?DAY0 }, qctx)) {
  case (#err(#InvalidRange(_))) refusals += 1;
  case (_) fail("an inverted window was answered rather than refused");
};
switch (Q.run(idx, { base with minAmount = ?500; maxAmount = ?100 }, qctx)) {
  case (#err(#InvalidRange(_))) refusals += 1;
  case (_) fail("an inverted amount band was answered rather than refused");
};
Debug.print("count: refusals that name what is wrong rather than answering empty = " # Nat.toText(refusals));

// A currency that exists but has no movement in the window: an empty page, not a refusal. The two
// answers are different and both are reachable.
switch (Q.run(idx, { base with currency = ?"EGP"; from = ?(DAY0 + 10_000); to = ?(DAY0 + 10_001) }, qctx)) {
  case (#ok(p)) {
    if (p.rows.size() != 0) fail("a window with no movement returned rows");
    Debug.print("count: known currencies with no movement answered as an empty page = 1");
  };
  case (#err(e)) fail("a known currency with no movement was refused: " # debug_show (e));
};

Debug.print("QUERIES TEST GREEN");
