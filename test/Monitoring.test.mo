// Monitoring.test.mo — the aggregates and the closed rule set against a brute-force oracle.
//
// The addendum's acceptance: "for random journals and every rule type, the incremental alerts equal
// a brute-force recomputation over the whole journal: same alerts, same cited postings." Here the
// findings are the alerts' content (the alert component records them), and the oracle is the whole
// of it, written separately from the code it checks:
//
//   * every A1, E1, E2, E3 and A4 row maintained posting by posting equals the row recomputed from
//     the final journal, byte for byte, in both directions — no extra row, no missing row;
//   * the cheap rules evaluated in each posting's own message (large cash, dormant then active,
//     round trip) produce the same findings, with the same cited postings, as a brute-force replay
//     that keeps its own history;
//   * the window rules evaluated per (account, day) (velocity, structuring, fan-out, fan-in,
//     pass-through) produce the same findings and citations as a brute-force count over the window;
//   * a structuring rule that would read past its declared bound is refused with the size, not run;
//   * the rule registry folds versions and retirements, and refuses a rule that could never fire or
//     never stop.
//
// Pendings are part of the stream: a pending counts nothing until it resolves, counts at the
// resolved day when it does, and never counts when voided.
//
// engine: wasi-only — Regions.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Order "mo:core/Order";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";

import JT "mo:journal/JournalTypes";
import RI "mo:ledger/RegionIndex";
import PIdx "../src/bank/PostingIndex";
import A "../src/bank/Activity";
import MT "../src/bank/MonitoringTypes";
import M "../src/bank/Monitoring";
import MC "../src/bank/MonitoringCore";

// ─── a deterministic generator ───────────────────────────────────────────────
var seed : Nat32 = 0x9E37_79B9;
func next() : Nat32 { seed := seed *% 1_664_525 +% 1_013_904_223; seed };
// two high halves make 32 random bits: the generator's low bits have a short period
func below(n : Nat) : Nat { if (n == 0) 0 else (Nat32.toNat(next() / 65_536) * 65_536 + Nat32.toNat(next() / 65_536)) % n };

func fail(what : Text) { Debug.print("FAIL: " # what); assert false };

let ACCOUNTS = 40;
let POSTINGS = 1_400;
let DAY_BASE = 20_300;
let DAY_SPAN = 40;
let CURRENCIES = ["EGP", "USD"];
let CHANNELS = ["deposit", "withdrawal", "transfer", "test"];

func subledgerFor(i : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { if (j < 8) Nat8.fromNat((i / (256 ** (7 - j))) % 256) else 0 })) };
func acctIdFor(i : Nat) : Nat { 100 + i * 3 };
func ccyFor(i : Nat) : Text { CURRENCIES[i % 2] };

let idx = PIdx.newState();
let act = A.newState(idx.arena);
var i = 0;
while (i < ACCOUNTS) { assert (PIdx.registerAccount(idx, subledgerFor(i), acctIdFor(i))); i += 1 };
let ME = Principal.fromText("aaaaa-aa");
let blocks = List.empty<JT.Block>();

func emit(event : JT.Event) : JT.Block {
  let b : JT.Block = { index = List.size(blocks); timestamp = Nat32.toNat64(next()); caller = ME; parentHash = null; hash = Blob.fromArray([0]); event };
  List.add(blocks, b);
  b
};

let pctx : PIdx.Context = { classOf = func(_ : Nat) : ?Text { null }; blockOf = func(n : Nat) : ?JT.Block { List.get(blocks, n) } };
let actx : A.Context = { accountOf = func(sub : JT.SubledgerKey) : ?Nat { PIdx.accountOf(idx, sub) }; blockOf = func(n : Nat) : ?JT.Block { List.get(blocks, n) } };
let currencyOfAcct = Map.empty<Nat, Text>();
i := 0;
while (i < ACCOUNTS) { Map.add(currencyOfAcct, Nat.compare, acctIdFor(i), ccyFor(i)); i += 1 };

let mctx : M.Context = {
  activity = act;
  postingsOf = func(acct : Nat, from : Nat, to : Nat, bound : Nat) : { rows : [M.PostingRow]; exceeded : Bool } {
    let (lo, hi) = PIdx.accountRangeEnds(acct, from, to);
    let page = RI.range(idx.byAccount, lo, hi, null, bound + 1);
    let rows = List.empty<M.PostingRow>();
    for ((k, v) in page.entries.vals()) {
      let parts = PIdx.splitAccountKey(k);
      if (PIdx.isPosted(idx, parts.postingNo, parts.valueDay)) {
        let m = PIdx.readMovement(v);
        List.add(rows, { posting = parts.postingNo; day = parts.valueDay; debits = m.debits; credits = m.credits });
      };
    };
    if (List.size(rows) > bound) { { rows = Array.tabulate<M.PostingRow>(bound, func(j) { switch (List.get(rows, j)) { case (?r) r; case null Runtime.trap("row") } }); exceeded = true } }
    else { { rows = List.toArray(rows); exceeded = page.cursor != null } }
  };
  currencyOf = func(acct : Nat) : ?Text { Map.get(currencyOfAcct, Nat.compare, acct) };
};

for (c in CURRENCIES.vals()) { ignore PIdx.indexBlock(idx, emit(#currencyRegistered({ code = c; minorUnits = 2 })), pctx) };
ignore PIdx.indexBlock(idx, emit(#periodOpened({ id = "2026-09"; start = DAY_BASE; end = DAY_BASE + 60 })), pctx);

// ─── the rules ───────────────────────────────────────────────────────────────
// Thresholds chosen against the generator so every type fires somewhere and nowhere always.
let reg = MC.newState();
var block = 10;
func define(id : Text, ccy : ?Text, spec : MT.RuleSpec) {
  switch (MC.planDefine(reg, id, ccy, spec)) { case (#ok(ev)) { MC.apply(reg, block, ev); block += 1 }; case (#err(e)) fail("define " # id # ": " # debug_show (e)) };
};
define("cash", null, #largeCash({ threshold = 800_000; channels = ["deposit", "withdrawal"] }));
define("dormant", null, #dormantThenActive({ dormantDays = 12; amount = 300_000 }));
define("trip", ?"EGP", #roundTrip({ windowDays = 6; minAmount = 200_000 }));
define("velocity", null, #velocity({ count = 5; windowDays = 5 }));
define("bands", null, #structuring({ threshold = 500_000; bandPercent = 20; count = 3; windowDays = 10; maxScan = 200 }));
define("fanout", null, #fanOut({ distinct = 4; windowDays = 8 }));
define("fanin", null, #fanIn({ distinct = 4; windowDays = 8 }));
define("pass", null, #passThrough({ inOutPercent = 60; windowDays = 7; minAmount = 900_000 }));
define("narrow", null, #structuring({ threshold = 500_000; bandPercent = 20; count = 1; windowDays = 10; maxScan = 2 }));
// versions and retirement
define("cash", null, #largeCash({ threshold = 800_000; channels = ["deposit", "withdrawal", "transfer"] }));
switch (MC.get(reg, "cash")) { case (?r) assert (r.version == 2 and r.active); case null fail("cash rule missing") };
assert (MC.version(reg, "cash", 1) != null);
switch (MC.planRetire(reg, "narrow")) { case (#ok(ev)) MC.apply(reg, block, ev); case (#err(_)) fail("retire") };
switch (MC.planRetire(reg, "narrow")) { case (#err(#RuleRetired(_))) {}; case (_) fail("a retired rule was retired again") };
switch (MC.planRetire(reg, "nope")) { case (#err(#UnknownRule(_))) {}; case (_) fail("an unknown rule was retired") };
var refused = 0;
for (bad in [
  ("v0", #velocity({ count = 0; windowDays = 5 }) : MT.RuleSpec),
  ("v400", #velocity({ count = 1; windowDays = 400 })),
  ("s0", #structuring({ threshold = 0; bandPercent = 20; count = 3; windowDays = 10; maxScan = 200 })),
  ("s100", #structuring({ threshold = 10; bandPercent = 100; count = 3; windowDays = 10; maxScan = 200 })),
  ("sscan", #structuring({ threshold = 10; bandPercent = 20; count = 3; windowDays = 10; maxScan = 100_000 })),
  ("r0", #roundTrip({ windowDays = 6; minAmount = 0 })),
  ("f0", #fanOut({ distinct = 0; windowDays = 8 })),
  ("d0", #dormantThenActive({ dormantDays = 0; amount = 1 })),
  ("p0", #passThrough({ inOutPercent = 101; windowDays = 7; minAmount = 1 })),
  ("c0", #largeCash({ threshold = 1; channels = [] })),
  ("bad id!", #velocity({ count = 1; windowDays = 1 })),
].vals()) {
  switch (MC.planDefine(reg, bad.0, null, bad.1)) { case (#err(#InvalidRule(_))) refused += 1; case (_) fail("accepted an impossible rule " # bad.0) };
};
Debug.print("count: impossible rules refused at declaration = " # Nat.toText(refused));
let cheapRules = MC.active(reg, #atPosting);
let windowRules = MC.active(reg, #endOfDay);
Debug.print("count: active rules at posting = " # Nat.toText(cheapRules.size()));
Debug.print("count: active rules at end of day = " # Nat.toText(windowRules.size()));
assert (cheapRules.size() == 3 and windowRules.size() == 5);

// ─── the journal ─────────────────────────────────────────────────────────────

func record(n : Nat) : JT.PostingRecord {
  let a = below(ACCOUNTS);
  // a strong pair structure so round trips and fans happen: accounts cluster in groups of five
  var b = (a / 5) * 5 + below(5);
  if (b == a) b := (a + 1) % ACCOUNTS;
  let ccy = ccyFor(a);
  let shape = below(10);
  let amount = 50_000 + below(1_000_000);
  let day = DAY_BASE + below(DAY_SPAN);
  let channel = CHANNELS[below(CHANNELS.size())];
  let legs : [JT.Leg] = if (shape < 5) {
    // transfer a -> b (a debited, b credited); both must share a currency to be a valid posting
    let bb = if (Text.equal(ccyFor(b), ccy)) b else (b + 1) % ACCOUNTS;
    [
      { account = "2100"; subledger = ?subledgerFor(a); side = #debit; currency = ccy; amount },
      { account = "2100"; subledger = ?subledgerFor(bb); side = #credit; currency = ccy; amount },
    ]
  } else if (shape < 8) {
    // deposit from cash: GL debited, a credited
    [
      { account = "1001"; subledger = null; side = #debit; currency = ccy; amount },
      { account = "2100"; subledger = ?subledgerFor(a); side = #credit; currency = ccy; amount },
    ]
  } else {
    // withdrawal with a fee: a debited, cash and fee income credited
    [
      { account = "2100"; subledger = ?subledgerFor(a); side = #debit; currency = ccy; amount = amount + 500 },
      { account = "1001"; subledger = null; side = #credit; currency = ccy; amount },
      { account = "4100"; subledger = null; side = #credit; currency = ccy; amount = 500 },
    ]
  };
  {
    idempotencyKey = Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { Nat8.fromNat((n * 7 + j) % 256) }));
    postingDate = day; valueDate = day; valueDateRequested = null; period = "2026-09";
    legs; sourceRef = { kind = channel; id = Nat.toText(n) }; narration = "p" # Nat.toText(n); relation = null;
  }
};

// The incremental run: index, aggregate, evaluate the cheap rules in the posting's own step.
type Key = Text;   // rule ‖ version ‖ account ‖ day ‖ postings
func keyOf(f : MT.Finding) : Key {
  let ps = Array.sort<Nat>(f.postings, Nat.compare);
  f.rule # "/" # Nat.toText(f.version) # "/" # Nat.toText(f.account) # "/" # Nat.toText(f.day) # "/" # Text.join(Array.map<Nat, Text>(ps, Nat.toText).vals(), ",")
};
let incrementalCheap = List.empty<Key>();
type Outstanding = { postingNo : Nat; record : JT.PostingRecord; shape : Nat };
let outstanding = List.empty<Outstanding>();
var n = 0;
var postedOutright = 0;
while (n < POSTINGS) {
  let rec = record(n);
  let shape = n % 9;
  if (shape <= 2) {
    let b = emit(#pending({ record = rec; expiresAt = null }));
    ignore PIdx.indexBlock(idx, b, pctx);
    let r = A.record(act, b, actx);
    assert (r.posted == null);
    List.add(outstanding, { postingNo = b.index; record = rec; shape });
  } else {
    let b = emit(#posted(rec));
    ignore PIdx.indexBlock(idx, b, pctx);
    let r = A.record(act, b, actx);
    for (f in M.atPosting(mctx, cheapRules, r).vals()) List.add(incrementalCheap, keyOf(f));
    postedOutright += 1;
  };
  n += 1;
};
// resolve and void, interleaved after the stream so a resolution can complete a round trip
var resolved = 0;
var voided = 0;
for (o in List.values(outstanding)) {
  if (o.shape == 2) {
    let b = emit(#void({ pendingIndex = o.postingNo; reason = #requested }));
    ignore PIdx.indexBlock(idx, b, pctx);
    assert (A.record(act, b, actx).posted == null);
    voided += 1;
  } else {
    let newDay = if (o.shape == 0) o.record.valueDate + 2 else o.record.valueDate;
    let resolution : JT.Resolution = { postingDate = o.record.postingDate; valueDate = newDay; valueDateRequested = if (o.shape == 0) ?o.record.valueDate else null; period = o.record.period };
    let b = emit(#post({ pendingIndex = o.postingNo; resolution }));
    ignore PIdx.indexBlock(idx, b, pctx);
    let r = A.record(act, b, actx);
    switch (r.posted) { case (?p) assert (p.day == newDay and p.postingNo == o.postingNo); case null fail("a resolution aggregated nothing") };
    for (f in M.atPosting(mctx, cheapRules, r).vals()) List.add(incrementalCheap, keyOf(f));
    resolved += 1;
  };
};
Debug.print("count: postings aggregated outright = " # Nat.toText(postedOutright));
Debug.print("count: pendings resolved and aggregated = " # Nat.toText(resolved));
Debug.print("count: pendings voided and never aggregated = " # Nat.toText(voided));
assert (A.stats(act).postings == postedOutright + resolved);

// ═══════════════════════════════════════════════════════════════════
//  THE ORACLE — the aggregates, recomputed from the final journal
// ═══════════════════════════════════════════════════════════════════

// Every posted reading, in block order (a resolution counts at its resolving block's position).
type P = A.Posted;
let postedAll = List.empty<P>();
for (b in List.values(blocks)) {
  switch (b.event) {
    case (#posted(r)) List.add(postedAll, A.derive(r, b.index, r.valueDate, actx.accountOf));
    case (#post(x)) {
      switch (List.get(blocks, x.pendingIndex)) {
        case (?pb) { switch (pb.event) { case (#pending(p)) List.add(postedAll, A.derive(p.record, x.pendingIndex, x.resolution.valueDate, actx.accountOf)); case (_) fail("resolution of a non-pending") } };
        case null fail("resolution of a missing block");
      };
    };
    case (_) {};
  };
};
Debug.print("count: posted readings in the oracle = " # Nat.toText(List.size(postedAll)));

func be(v : Nat, w : Nat) : [Nat8] { var x = v; let le = Array.tabulate<Nat8>(w, func(_) { let b = Nat8.fromNat(x % 256); x /= 256; b }); Array.tabulate<Nat8>(w, func(j) { le[w - 1 - j] }) };
func cat(parts : [[Nat8]]) : Blob { let out = List.empty<Nat8>(); for (p in parts.vals()) { for (x in p.vals()) List.add(out, x) }; Blob.fromArray(List.toArray(out)) };
func ck(c : A.Counterparty) : [Nat8] { Blob.toArray(A.cptyKey(c)) };

// A1
let a1 = Map.empty<Blob, { var count : Nat; var dr : Nat; var cr : Nat; var largest : Nat }>();
// A4 — folded in block order, with the same previous-day rule
let a4 = Map.empty<Nat, { var first : Nat; var last : Nat; var postings : Nat }>();
// E1 / E2 / E3
let e1 = Map.empty<Blob, Nat>();
let e2 = Map.empty<Blob, { var count : Nat; var amount : Nat }>();
let e3 = Map.empty<Blob, { var count : Nat; var amount : Nat }>();
func bump(m : Map.Map<Blob, { var count : Nat; var amount : Nat }>, k : Blob, amount : Nat) {
  switch (Map.get(m, Blob.compare, k)) { case (?e) { e.count += 1; e.amount += amount }; case null Map.add(m, Blob.compare, k, { var count = 1; var amount }) };
};
for (p in List.values(postedAll)) {
  for (a in p.accounts.vals()) {
    let k = cat([be(a.account, 8), be(p.day, 4)]);
    switch (Map.get(a1, Blob.compare, k)) {
      case (?e) { e.count += 1; e.dr += a.debits; e.cr += a.credits; if (a.largest > e.largest) e.largest := a.largest };
      case null Map.add(a1, Blob.compare, k, { var count = 1; var dr = a.debits; var cr = a.credits; var largest = a.largest });
    };
    switch (Map.get(a4, Nat.compare, a.account)) {
      case (?d) { d.first := Nat.min(d.first, p.day); d.last := Nat.max(d.last, p.day); d.postings += 1 };
      case null Map.add(a4, Nat.compare, a.account, { var first = p.day; var last = p.day; var postings = 1 });
    };
  };
  for (e in p.edges.vals()) {
    Map.add(e1, Blob.compare, cat([ck(e.from), ck(e.to), be(p.day, 4), be(p.postingNo, 8)]), e.amount);
    bump(e2, cat([ck(e.from), be(p.day, 4), ck(e.to)]), e.amount);
    bump(e3, cat([ck(e.to), be(p.day, 4), ck(e.from)]), e.amount);
  };
};

// compare, both directions, byte for byte
func compare(name : Text, dumped : [(Blob, Blob)], expect : Blob -> ?Blob, expectedCount : Nat) {
  if (dumped.size() != expectedCount) fail(name # ": " # Nat.toText(dumped.size()) # " rows maintained, " # Nat.toText(expectedCount) # " recomputed");
  for ((k, v) in dumped.vals()) {
    switch (expect(k)) {
      case (?want) { if (want != v) fail(name # ": a row differs at " # debug_show (k)) };
      case null fail(name # ": a maintained row the oracle does not have");
    };
  };
  Debug.print("count: " # name # " rows equal to the recomputation = " # Nat.toText(dumped.size()));
};
compare("A1", A.dump(act.activity, A.A1_KEY), func(k) {
  switch (Map.get(a1, Blob.compare, k)) { case (?e) ?cat([be(e.count, 4), be(e.dr, 16), be(e.cr, 16), be(e.largest, 16)]); case null null }
}, Map.size(a1));
compare("E1", A.dump(act.edges, A.E1_KEY), func(k) { switch (Map.get(e1, Blob.compare, k)) { case (?amt) ?cat([be(amt, 16)]); case null null } }, Map.size(e1));
compare("E2", A.dump(act.edgesOut, A.E2_KEY), func(k) { switch (Map.get(e2, Blob.compare, k)) { case (?e) ?cat([be(e.count, 4), be(e.amount, 16)]); case null null } }, Map.size(e2));
compare("E3", A.dump(act.edgesIn, A.E2_KEY), func(k) { switch (Map.get(e3, Blob.compare, k)) { case (?e) ?cat([be(e.count, 4), be(e.amount, 16)]); case null null } }, Map.size(e3));
compare("A4", A.dump(act.lastActive, 8), func(k) {
  let id = Blob.toArray(k);
  var v = 0; for (x in id.vals()) v := v * 256 + Nat8.toNat(x);
  switch (Map.get(a4, Nat.compare, v)) { case (?d) ?cat([be(d.first, 4), be(d.last, 4), be(d.postings, 8)]); case null null }
}, Map.size(a4));
assert (Map.size(e1) > 100 and Map.size(a1) > 100);

// ═══════════════════════════════════════════════════════════════════
//  THE ORACLE — the cheap rules, by definition, with their own history
// ═══════════════════════════════════════════════════════════════════

let bruteCheap = List.empty<Key>();
func ruleOf(id : Text) : MT.Rule { switch (MC.get(reg, id)) { case (?r) r; case null Runtime.trap("rule " # id) } };
func appliesTo(r : MT.Rule, acct : Nat) : Bool {
  switch (r.currency) { case null true; case (?c) { switch (Map.get(currencyOfAcct, Nat.compare, acct)) { case (?ac) Text.equal(ac, c); case null false } } }
};
func add(rule : MT.Rule, acct : Nat, day : Nat, postings : [Nat]) { List.add(bruteCheap, keyOf({ rule = rule.id; version = rule.version; account = acct; day; postings; detail = "" })) };
// history as the replay sees it: activity days per account so far, and edges so far
let daysSeen = Map.empty<Nat, List.List<Nat>>();
let edgesSeen = List.empty<(Blob, Blob, Nat, Nat, Nat)>();   // from, to, day, posting, amount
let cash = ruleOf("cash");
let dormant = ruleOf("dormant");
let trip = ruleOf("trip");
for (p in List.values(postedAll)) {
  // large cash, version 2: three channels
  let onChannel = Text.equal(p.channel, "deposit") or Text.equal(p.channel, "withdrawal") or Text.equal(p.channel, "transfer");
  for (a in p.accounts.vals()) {
    if (onChannel and a.largest >= 800_000) add(cash, a.account, p.day, [p.postingNo]);
    // dormant then active: the latest activity day strictly before this day, from the days seen
    if (Nat.max(a.debits, a.credits) >= 300_000) {
      switch (Map.get(daysSeen, Nat.compare, a.account)) {
        case (?ds) {
          var lb : ?Nat = null;
          for (d in List.values(ds)) { if (d < p.day) { switch (lb) { case (?x) { if (d > x) lb := ?d }; case null lb := ?d } } };
          switch (lb) { case (?x) { if (p.day >= x + 12) add(dormant, a.account, p.day, [p.postingNo]) }; case null {} };
        };
        case null {};
      };
    };
  };
  // round trip: an earlier reverse edge within 6 days before (inclusive of the same day)
  for (e in p.edges.vals()) {
    if (e.amount >= 200_000) {
      let on : ?Nat = switch (e.from) { case (#account(id)) ?id; case (_) { switch (e.to) { case (#account(id)) ?id; case (_) null } } };
      switch (on) {
        case (?acct) {
          if (appliesTo(trip, acct)) {
            let fromK = A.cptyKey(e.to); let toK = A.cptyKey(e.from);
            let earlier = List.empty<Nat>();
            for ((f, t, d, pn, _) in List.values(edgesSeen)) {
              if (f == fromK and t == toK and d + 6 >= p.day and d <= p.day and pn != p.postingNo) List.add(earlier, pn);
            };
            if (List.size(earlier) > 0) add(trip, acct, p.day, Array.concat<Nat>([p.postingNo], List.toArray(earlier)));
          };
        };
        case null {};
      };
    };
  };
  // then this posting joins the history
  for (a in p.accounts.vals()) {
    switch (Map.get(daysSeen, Nat.compare, a.account)) { case (?ds) List.add(ds, p.day); case null { let l = List.empty<Nat>(); List.add(l, p.day); Map.add(daysSeen, Nat.compare, a.account, l) } };
  };
  for (e in p.edges.vals()) List.add(edgesSeen, (A.cptyKey(e.from), A.cptyKey(e.to), p.day, p.postingNo, e.amount));
};

func sameSet(name : Text, got : List.List<Key>, want : List.List<Key>) {
  let g = Array.sort<Text>(List.toArray(got), Text.compare);
  let w = Array.sort<Text>(List.toArray(want), Text.compare);
  if (g.size() != w.size()) {
    // say which, before failing: the first of each side the other lacks
    var shown = 0;
    for (x in g.vals()) { if (shown < 3 and Array.find<Text>(w, func(y) { Text.equal(x, y) }) == null) { Debug.print("  only incremental: " # x); shown += 1 } };
    shown := 0;
    for (x in w.vals()) { if (shown < 3 and Array.find<Text>(g, func(y) { Text.equal(x, y) }) == null) { Debug.print("  only brute force: " # x); shown += 1 } };
    fail(name # ": " # Nat.toText(g.size()) # " incremental findings, " # Nat.toText(w.size()) # " by brute force");
  };
  var j = 0;
  while (j < g.size()) { if (not Text.equal(g[j], w[j])) fail(name # ": findings differ: " # g[j] # " vs " # w[j]); j += 1 };
  Debug.print("count: " # name # " findings equal to the brute force = " # Nat.toText(g.size()));
};
sameSet("cheap-rule", incrementalCheap, bruteCheap);
var cashN = 0; var dormantN = 0; var tripN = 0;
for (k in List.values(bruteCheap)) { if (Text.startsWith(k, #text "cash/")) cashN += 1 else if (Text.startsWith(k, #text "dormant/")) dormantN += 1 else tripN += 1 };
Debug.print("count: large-cash findings = " # Nat.toText(cashN));
Debug.print("count: dormant-then-active findings = " # Nat.toText(dormantN));
Debug.print("count: round-trip findings = " # Nat.toText(tripN));
assert (cashN > 0 and dormantN > 0 and tripN > 0);

// ═══════════════════════════════════════════════════════════════════
//  THE ORACLE — the window rules, per (account, day)
// ═══════════════════════════════════════════════════════════════════

// the account's postings by (day, posting), live ones — the I1 order
type PR = { posting : Nat; day : Nat; dr : Nat; cr : Nat };
let byAccount = Map.empty<Nat, List.List<PR>>();
for (p in List.values(postedAll)) {
  for (a in p.accounts.vals()) {
    let l = switch (Map.get(byAccount, Nat.compare, a.account)) { case (?l) l; case null { let l = List.empty<PR>(); Map.add(byAccount, Nat.compare, a.account, l); l } };
    List.add(l, { posting = p.postingNo; day = p.day; dr = a.debits; cr = a.credits });
  };
};
func cmpPR(x : PR, y : PR) : Order.Order { switch (Nat.compare(x.day, y.day)) { case (#equal) Nat.compare(x.posting, y.posting); case (o) o } };
func inWindow(acct : Nat, from : Nat, to : Nat) : [PR] {
  switch (Map.get(byAccount, Nat.compare, acct)) {
    case (?l) Array.sort<PR>(Array.filter<PR>(List.toArray(l), func(r) { r.day >= from and r.day <= to }), cmpPR);
    case null [];
  }
};
func capN(ps : [Nat]) : [Nat] { if (ps.size() <= MT.MAX_CITATIONS) ps else Array.tabulate<Nat>(MT.MAX_CITATIONS, func(j) { ps[j] }) };
func firstPostings(rows : [PR]) : [Nat] { capN(Array.map<PR, Nat>(rows, func(r) { r.posting })) };
let incrementalWindow = List.empty<Key>();
let bruteWindow = List.empty<Key>();
var pairs = 0;
var tooWide = 0;
let velocity = ruleOf("velocity"); let bands = ruleOf("bands"); let fanout = ruleOf("fanout"); let fanin = ruleOf("fanin"); let pass = ruleOf("pass");
func addW(rule : MT.Rule, acct : Nat, day : Nat, postings : [Nat]) { List.add(bruteWindow, keyOf({ rule = rule.id; version = rule.version; account = acct; day; postings; detail = "" })) };
func cmpBlob(x : Blob, y : Blob) : Order.Order { Blob.compare(x, y) };
for ((acct, l) in Map.entries(byAccount)) {
  let days = List.empty<Nat>();
  for (r in List.values(l)) { var seen = false; for (d in List.values(days)) { if (d == r.day) seen := true }; if (not seen) List.add(days, r.day) };
  for (day in List.values(days)) {
    pairs += 1;
    switch (M.atDay(mctx, windowRules, acct, day)) {
      case (#ok(fs)) { for (f in fs.vals()) List.add(incrementalWindow, keyOf(f)) };
      case (#err(e)) fail("window evaluation refused: " # debug_show (e));
    };
    // velocity: 5 in 5 days
    let w5 = inWindow(acct, if (day < 4) 0 else day - 4, day);
    if (w5.size() >= 5) addW(velocity, acct, day, firstPostings(w5));
    // structuring: band [400_000, 500_000), 3 in 10 days
    let w10 = inWindow(acct, if (day < 9) 0 else day - 9, day);
    let hit = Array.map<PR, Nat>(Array.filter<PR>(w10, func(r) { let m = Nat.max(r.dr, r.cr); m >= 400_000 and m < 500_000 }), func(r) { r.posting });
    if (hit.size() >= 3) addW(bands, acct, day, capN(hit));
    // pass-through: 7 days, both sides ≥ 900_000, min ≥ 60% of max
    let w7 = inWindow(acct, if (day < 6) 0 else day - 6, day);
    var dr = 0; var cr = 0;
    for (r in w7.vals()) { dr += r.dr; cr += r.cr };
    if (dr >= 900_000 and cr >= 900_000 and Nat.min(dr, cr) * 100 >= Nat.max(dr, cr) * 60) addW(pass, acct, day, firstPostings(w7));
    // fans: distinct counterparties over 8 days, in (day, key) order, stopping past 4; cite the
    // first posting of each distinct edge
    let from = if (day < 7) 0 else day - 7;
    let meK = A.cptyKey(#account(acct));
    for (outward in [true, false].vals()) {
      let rows = List.empty<(Nat, Blob, Nat)>();   // day, other key, posting
      for ((f, t, d, pn, _) in List.values(edgesSeen)) {
        if (d >= from and d <= day) {
          if (outward and f == meK) List.add(rows, (d, t, pn));
          if (not outward and t == meK) List.add(rows, (d, f, pn));
        };
      };
      // E2/E3 order: day, then key; within one (day, key) the E1 order is by day then posting
      let sorted = Array.sort<(Nat, Blob, Nat)>(List.toArray(rows), func(x, y) { switch (Nat.compare(x.0, y.0)) { case (#equal) { switch (cmpBlob(x.1, y.1)) { case (#equal) Nat.compare(x.2, y.2); case (o) o } }; case (o) o } });
      let distinctKeys = List.empty<Blob>();
      var over = false;
      label scan for ((_, k, _) in sorted.vals()) {
        var seen = false;
        for (x in List.values(distinctKeys)) { if (x == k) seen := true };
        if (not seen) { List.add(distinctKeys, k); if (List.size(distinctKeys) > 4) { over := true; break scan } };
      };
      if (over) {
        let cited = List.empty<Nat>();
        for (k in List.values(distinctKeys)) {
          // the first E1 row for (me, k) or (k, me) over the window: smallest (day, posting)
          var best : ?(Nat, Nat) = null;
          for ((f, t, d, pn, _) in List.values(edgesSeen)) {
            let match = if (outward) (f == meK and t == k) else (f == k and t == meK);
            if (match and d >= from and d <= day) {
              switch (best) { case (?(bd, bp)) { if (d < bd or (d == bd and pn < bp)) best := ?(d, pn) }; case null best := ?(d, pn) };
            };
          };
          switch (best) { case (?(_, pn)) List.add(cited, pn); case null fail("a distinct edge with no posting") };
        };
        addW(if (outward) fanout else fanin, acct, day, List.toArray(cited));
      };
    };
    // the narrow structuring rule (maxScan 2) is retired, so it never runs; run it directly to
    // see the refusal
    switch (M.evaluateWindow(mctx, ruleOf("narrow"), acct, day)) {
      case (#err(#TooWide(x))) { tooWide += 1; assert (x.bound == 2) };
      case (#ok(_)) {};
      case (#err(e)) fail("unexpected refusal " # debug_show (e));
    };
  };
};
Debug.print("count: (account, day) pairs evaluated = " # Nat.toText(pairs));
sameSet("window-rule", incrementalWindow, bruteWindow);
var vN = 0; var sN = 0; var foN = 0; var fiN = 0; var pN = 0;
for (k in List.values(bruteWindow)) {
  if (Text.startsWith(k, #text "velocity/")) vN += 1 else if (Text.startsWith(k, #text "bands/")) sN += 1
  else if (Text.startsWith(k, #text "fanout/")) foN += 1 else if (Text.startsWith(k, #text "fanin/")) fiN += 1 else pN += 1;
};
Debug.print("count: velocity findings = " # Nat.toText(vN));
Debug.print("count: structuring findings = " # Nat.toText(sN));
Debug.print("count: fan-out findings = " # Nat.toText(foN));
Debug.print("count: fan-in findings = " # Nat.toText(fiN));
Debug.print("count: pass-through findings = " # Nat.toText(pN));
assert (vN > 0 and sN > 0 and foN > 0 and fiN > 0 and pN > 0);
Debug.print("count: structuring evaluations refused as too wide for their declared bound = " # Nat.toText(tooWide));
assert (tooWide > 0);

// every read the rules make is bounded by construction, and the widths are what the rows declare
assert (A.A1_KEY == 12 and A.A1_VAL == 52 and A.E1_KEY == 78 and A.E2_KEY == 70);
let st = A.stats(act);
Debug.print("count: aggregate stable-memory bytes = " # Nat.toText(st.bytes));
Debug.print("count: edges aggregated = " # Nat.toText(st.edges));

// ═══════════════════════════════════════════════════════════════════
//  NEGATIVE CONTROLS — planted series, caught inside the window and not outside it
// ═══════════════════════════════════════════════════════════════════
//
// The addendum's acceptance: "a planted structuring series, a round trip and a pass-through are
// each caught. The same series spread just outside the window is not." A fresh index and fresh
// aggregates, two accounts, and each series planted twice: once inside its rule's window, once
// with the same postings one day too far apart.

let idx2 = PIdx.newState();
let act2 = A.newState(idx2.arena);
let blocks2 = List.empty<JT.Block>();
let P1 = 5_000; let P2 = 5_001;
assert (PIdx.registerAccount(idx2, subledgerFor(900), P1));
assert (PIdx.registerAccount(idx2, subledgerFor(901), P2));
func emit2(event : JT.Event) : JT.Block {
  let b : JT.Block = { index = List.size(blocks2); timestamp = 0; caller = ME; parentHash = null; hash = Blob.fromArray([0]); event };
  List.add(blocks2, b);
  b
};
let pctx2 : PIdx.Context = { classOf = func(_ : Nat) : ?Text { null }; blockOf = func(n : Nat) : ?JT.Block { List.get(blocks2, n) } };
let actx2 : A.Context = { accountOf = func(sub : JT.SubledgerKey) : ?Nat { PIdx.accountOf(idx2, sub) }; blockOf = func(n : Nat) : ?JT.Block { List.get(blocks2, n) } };
let currencies2 = Map.empty<Nat, Text>();
Map.add(currencies2, Nat.compare, P1, "EGP"); Map.add(currencies2, Nat.compare, P2, "EGP");
let mctx2 : M.Context = {
  activity = act2;
  postingsOf = func(acct : Nat, from : Nat, to : Nat, bound : Nat) : { rows : [M.PostingRow]; exceeded : Bool } {
    let (lo, hi) = PIdx.accountRangeEnds(acct, from, to);
    let page = RI.range(idx2.byAccount, lo, hi, null, bound + 1);
    let rows = List.empty<M.PostingRow>();
    for ((k, v) in page.entries.vals()) {
      let parts = PIdx.splitAccountKey(k);
      if (PIdx.isPosted(idx2, parts.postingNo, parts.valueDay)) { let m = PIdx.readMovement(v); List.add(rows, { posting = parts.postingNo; day = parts.valueDay; debits = m.debits; credits = m.credits }) };
    };
    { rows = List.toArray(rows); exceeded = page.cursor != null }
  };
  currencyOf = func(acct : Nat) : ?Text { Map.get(currencies2, Nat.compare, acct) };
};
ignore PIdx.indexBlock(idx2, emit2(#currencyRegistered({ code = "EGP"; minorUnits = 2 })), pctx2);
var plantedNo = 0;
func plant(day : Nat, from : Nat, to : Nat, amount : Nat, kind : Text) : Nat {
  plantedNo += 1;
  let rec : JT.PostingRecord = {
    idempotencyKey = Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { Nat8.fromNat((plantedNo * 3 + j) % 256) }));
    postingDate = day; valueDate = day; valueDateRequested = null; period = "2026-09";
    legs = [
      { account = "2100"; subledger = if (from == 0) null else ?subledgerFor(from); side = #debit; currency = "EGP"; amount },
      { account = "2100"; subledger = if (to == 0) null else ?subledgerFor(to); side = #credit; currency = "EGP"; amount },
    ];
    sourceRef = { kind; id = Nat.toText(plantedNo) }; narration = "planted"; relation = null;
  };
  let b = emit2(#posted(rec));
  ignore PIdx.indexBlock(idx2, b, pctx2);
  lastRecorded := A.record(act2, b, actx2);
  b.index
};
var lastRecorded : A.Recorded = { posted = null; before = [] };
let ruleBands = ruleOf("bands");          // 3 in [400_000, 500_000) within 10 days
let ruleTrip = ruleOf("trip");            // returned within 6 days, ≥ 200_000
let rulePass = ruleOf("pass");            // 7 days, both sides ≥ 900_000, min ≥ 60% of max
let D = 21_000;
// structuring: three band postings on days D, D+4, D+9 (inside 10) — caught on D+9
ignore plant(D, 0, 900, 450_000, "deposit"); ignore plant(D + 4, 0, 900, 450_000, "deposit"); ignore plant(D + 9, 0, 900, 450_000, "deposit");
switch (M.evaluateWindow(mctx2, ruleBands, P1, D + 9)) { case (#ok(?f)) assert (f.postings.size() == 3); case (_) fail("the planted structuring series was not caught") };
// the same three spread over eleven days: D+10 .. D+20 sees only two of them
ignore plant(D + 10, 0, 900, 450_000, "deposit"); ignore plant(D + 15, 0, 900, 450_000, "deposit"); ignore plant(D + 20, 0, 900, 450_000, "deposit");
// at D+20 the window [D+11, D+20] holds D+15 and D+20 only
switch (M.evaluateWindow(mctx2, ruleBands, P1, D + 20)) { case (#ok(null)) {}; case (_) fail("a series spread outside the window was caught") };
// round trip: P1 -> P2 on day E, P2 -> P1 on day E+6 — caught at the return
let E = 21_100;
ignore plant(E, 900, 901, 300_000, "transfer");
ignore plant(E + 6, 901, 900, 300_000, "transfer");
let tripHit = M.atPosting(mctx2, [ruleTrip], lastRecorded);
assert (tripHit.size() == 1 and tripHit[0].postings.size() == 2);
// the same, seven days apart: not a round trip
let F = 21_200;
ignore plant(F, 900, 901, 300_000, "transfer");
ignore plant(F + 7, 901, 900, 300_000, "transfer");
assert (M.atPosting(mctx2, [ruleTrip], lastRecorded).size() == 0);
// pass-through: 1,000,000 in on day G, 900,000 out on G+6 — caught at G+6
let G = 21_300;
ignore plant(G, 0, 900, 1_000_000, "deposit");
ignore plant(G + 6, 900, 0, 900_000, "withdrawal");
switch (M.evaluateWindow(mctx2, rulePass, P1, G + 6)) { case (#ok(?_)) {}; case (_) fail("the planted pass-through was not caught") };
// the same, seven days apart: the inflow has left the window
let H = 21_400;
ignore plant(H, 0, 900, 1_000_000, "deposit");
ignore plant(H + 7, 900, 0, 900_000, "withdrawal");
switch (M.evaluateWindow(mctx2, rulePass, P1, H + 7)) { case (#ok(null)) {}; case (_) fail("a pass-through spread outside the window was caught") };
Debug.print("count: planted series caught inside their window = 3");
Debug.print("count: planted series not caught just outside their window = 3");
