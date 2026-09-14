/// Activity.mo; the aggregates the monitoring rules read: A1..A4 of the approved proposal's
/// cross-account addendum, maintained in the posting's own message, in stable memory.
///
/// Every row here is **derived**: a pure function of the journal's posted blocks, rebuildable by
/// replay, and never the authority for anything. What the rows are for is a bounded read. A
/// monitoring rule of the closed set (`Monitoring.mo`) answers from a range over these rows whose
/// cost is declared before it runs; a window of days, a bar of distinct counterparties, one
/// reverse lookup; where a warehouse would scan the journal. The ICRC-ME indexed ledger is the
/// base; these are the aggregates it did not have.
///
/// ## What is counted
///
/// Posted activity only. A `#posted` block counts at its value day; a `#post` that resolves a
/// pending counts at the **resolved** value day, from the record in the pending's block; a pending
/// counts nothing until it resolves and a void never counts. So a posting is aggregated exactly
/// once, at the day the journal finally gave it.
///
/// Per posting, `derive` produces the **closed** reading every row and every oracle share:
///
///   * for each indexed account (a sub-ledger key the bank registered, `Context.accountOf`): its
///     debit total, its credit total and its largest leg in the posting;
///   * the **edges**: from each debited counterparty to each credited counterparty, with amount
///     the smaller of the two totals. A counterparty is an indexed account, a general-ledger
///     account code (a leg with no registered sub-ledger), or an external beneficiary commitment
///    the third form is what a payment message will carry; nothing produces it yet, and
///     the key space and the rules treat it like the other two. Never personal data.
///
/// ## The rows
///
/// | | key | value |
/// |---|---|---|
/// | A1 `activity` | `acct(8) ‖ day(4)` | `count(4) ‖ debits(16) ‖ credits(16) ‖ largest(16)` |
/// | E1 `edges` | `from(33) ‖ to(33) ‖ day(4) ‖ posting(8)` | `amount(16)`; one row per posting edge, so a citation is exact |
/// | E2 `edgesOut` | `from(33) ‖ day(4) ‖ to(33)` | `count(4) ‖ amount(16)`; distinct receivers in a window |
/// | E3 `edgesIn` | `to(33) ‖ day(4) ‖ from(33)` | the same; distinct senders in a window |
/// | A4 `lastActive` | `acct(8)` | `first(4) ‖ last(4) ‖ postings(8)`; dormancy |
///
/// The proposal's `acct‖cpty‖day` and `cpty‖acct‖day` are E1 and E3: E1 keeps the pair's history
/// per posting, which is what a round trip cites; E2 and E3 put the day before the counterparty so
/// a fan-out or fan-in is a range over the window that stops at the bar. Amounts are 16 bytes and
/// saturate at 2^128 − 1, which no currency reaches.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Runtime "mo:core/Runtime";
import Sha256 "mo:sha2/Sha256";

import JT "mo:journal/JournalTypes";
import RI "mo:ledger/RegionIndex";
import RB "mo:ledger/RegionRebuild";

import R "StableRows";

module {

  // ─── counterparties ───────────────────────────────────────────────────────

  public type Counterparty = {
    #account : Nat;
    #gl : JT.AccountCode;
    #external : Blob;   // a 32-byte commitment
    /// A counterparty as its 33-byte key, for a lookup made from a key another range returned;
    /// a general-ledger code is hashed into its key and cannot be read back.
    #key : Blob;
  };

  public let CPTY_BYTES : Nat = 33;
  public let ACCT_BYTES : Nat = 8;
  public let DAY_BYTES : Nat = 4;
  public let AMOUNT_BYTES : Nat = 16;
  public let AMOUNT_CEILING : Nat = 340_282_366_920_938_463_463_374_607_431_768_211_455;

  public let A1_KEY : Nat = 12;
  public let A1_VAL : Nat = 52;
  public let E1_KEY : Nat = 78;
  public let E1_VAL : Nat = 16;
  public let E2_KEY : Nat = 70;
  public let E2_VAL : Nat = 20;
  public let A4_VAL : Nat = 16;

  func cptyBytes(c : Counterparty) : [Nat8] {
    let b = R.buf();
    switch (c) {
      case (#account(id)) { R.putByte(b, 1); R.putNat(b, 0, 24); R.putNat(b, id, 8) };
      case (#gl(code)) {
        // the code hashed, so a chart of any shape fits a fixed key and no ordinal table is needed
        R.putByte(b, 2);
        for (x in Sha256.fromBlob(#sha256, Text.encodeUtf8(code)).vals()) R.putByte(b, x);
      };
      case (#external(commit)) {
        if (commit.size() != 32) Runtime.trap("Activity: an external counterparty is a 32-byte commitment");
        R.putByte(b, 3);
        for (x in commit.vals()) R.putByte(b, x);
      };
      case (#key(k)) {
        if (k.size() != CPTY_BYTES) Runtime.trap("Activity: a counterparty key of the wrong width");
        for (x in k.vals()) R.putByte(b, x);
      };
    };
    b.toArray()
  };

  public func cptyKey(c : Counterparty) : Blob { Blob.fromArray(cptyBytes(c)) };

  /// The tag of a counterparty key, and the account id when it is an account. A general-ledger
  /// counterparty's code is not recoverable from its key (it is hashed); a reader that needs the
  /// code has the posting.
  public func cptyOfKey(k : [Nat8], off : Nat) : { #account : Nat; #gl : Blob; #external : Blob } {
    switch (k[off]) {
      case 1 #account(R.getNat(k, off + 25, 8));
      case 2 #gl(R.getBlob(k, off + 1, 32));
      case 3 #external(R.getBlob(k, off + 1, 32));
      case _ Runtime.trap("Activity: a counterparty tag that is not one");
    }
  };

  // ─── what one posting contributes ─────────────────────────────────────────

  public type AccountActivity = { account : Nat; debits : Nat; credits : Nat; largest : Nat };
  public type Edge = { from : Counterparty; to : Counterparty; amount : Nat };

  public type Posted = {
    postingNo : Nat;
    day : Nat;
    /// The posting's source kind: the channel a large-cash rule names.
    channel : Text;
    accounts : [AccountActivity];
    edges : [Edge];
  };

  public type Context = {
    accountOf : JT.SubledgerKey -> ?Nat;
    blockOf : Nat -> ?JT.Block;
  };

  /// The closed reading of a posting record. Pure; the oracle calls the same function.
  public func derive(record : JT.PostingRecord, postingNo : Nat, day : Nat, accountOf : JT.SubledgerKey -> ?Nat) : Posted {
    let byAcct = Map.empty<Nat, { var dr : Nat; var cr : Nat; var largest : Nat }>();
    let order = List.empty<Nat>();
    // debited and credited counterparties, in leg order, with their totals
    let debited = List.empty<(Counterparty, Nat)>();
    let credited = List.empty<(Counterparty, Nat)>();
    func addSide(side : List.List<(Counterparty, Nat)>, c : Counterparty, amount : Nat) {
      let k = cptyKey(c);
      var i = 0;
      while (i < List.size(side)) {
        switch (List.get(side, i)) {
          case (?(c2, a)) { if (cptyKey(c2) == k) { List.put(side, i, (c2, a + amount)); return } };
          case null {};
        };
        i += 1;
      };
      List.add(side, (c, amount));
    };
    for (leg in record.legs.vals()) {
      // a general-ledger counterparty is carried as its key from here on: the code is hashed once
      // a leg, not once per index row the posting writes
      let cpty : Counterparty = switch (leg.subledger) {
        case (?sub) { switch (accountOf(sub)) { case (?id) #account(id); case null #key(cptyKey(#gl(leg.account))) } };
        case null #key(cptyKey(#gl(leg.account)));
      };
      switch (cpty) {
        case (#account(id)) {
          let e = switch (Map.get(byAcct, Nat.compare, id)) {
            case (?e) e;
            case null { let e = { var dr = 0; var cr = 0; var largest = 0 }; Map.add(byAcct, Nat.compare, id, e); List.add(order, id); e };
          };
          switch (leg.side) { case (#debit) e.dr += leg.amount; case (#credit) e.cr += leg.amount };
          if (leg.amount > e.largest) e.largest := leg.amount;
        };
        case (_) {};
      };
      switch (leg.side) { case (#debit) addSide(debited, cpty, leg.amount); case (#credit) addSide(credited, cpty, leg.amount) };
    };
    let accounts = Array.map<Nat, AccountActivity>(List.toArray(order), func(id) {
      let ?e = Map.get(byAcct, Nat.compare, id) else Runtime.trap("Activity: an account that was just added is missing");
      { account = id; debits = e.dr; credits = e.cr; largest = e.largest }
    });
    let edges = List.empty<Edge>();
    for ((from, dr) in List.values(debited)) {
      for ((to, cr) in List.values(credited)) {
        // a counterparty on both sides of one posting is a movement within itself, not an edge
        if (cptyKey(from) != cptyKey(to)) List.add(edges, { from; to; amount = Nat.min(dr, cr) });
      };
    };
    { postingNo; day; channel = record.sourceRef.kind; accounts; edges = List.toArray(edges) }
  };

  // ─── state ────────────────────────────────────────────────────────────────

  /// `count(4) ‖ debits(16) ‖ credits(16) ‖ largest(16) ‖ firstDay(4) ‖ lastDay(4)`; a month of an
  /// account's activity once its days have been rolled up, keyed `acct(8) ‖ periodOrd(4)`. The
  /// first and last active days are what keeps a dormancy reading exact after the roll-up.
  public let M1_KEY : Nat = 12;
  public let M1_VAL : Nat = 60;
  /// `count(4) ‖ amount(16)`, keyed `from(33) ‖ to(33) ‖ periodOrd(4)` and, for fan-in,
  /// `to ‖ from ‖ periodOrd`.
  public let ME_KEY : Nat = 70;

  public type State = {
    /// The per-day and per-posting rows are `var`: closed-month packing rolls a month of them up
    /// into the monthly rows and replaces each index by a generation without them.
    var activity : RI.State;
    var edges : RI.State;
    var edgesOut : RI.State;
    var edgesIn : RI.State;
    lastActive : RI.State;
    monthlyActivity : RI.State;
    monthlyEdges : RI.State;
    monthlyEdgesIn : RI.State;
    var rebuild : ?{ which : Rebuildable; job : RB.Job; periodEnd : Nat; periodOrd : Nat };
    /// The last day whose rows have been rolled up. A window rule cannot read at or below it.
    var rolledUpThrough : Nat;
    var postings : Nat;
    var edgeCount : Nat;
  };

  public func newState(arena : RI.Arena) : State {
    {
      var activity = RI.newStateIn(arena, { keyBytes = A1_KEY; valBytes = A1_VAL });
      var edges = RI.newStateIn(arena, { keyBytes = E1_KEY; valBytes = E1_VAL });
      var edgesOut = RI.newStateIn(arena, { keyBytes = E2_KEY; valBytes = E2_VAL });
      var edgesIn = RI.newStateIn(arena, { keyBytes = E2_KEY; valBytes = E2_VAL });
      lastActive = RI.newStateIn(arena, { keyBytes = ACCT_BYTES; valBytes = A4_VAL });
      monthlyActivity = RI.newStateIn(arena, { keyBytes = M1_KEY; valBytes = M1_VAL });
      monthlyEdges = RI.newStateIn(arena, { keyBytes = ME_KEY; valBytes = E2_VAL });
      monthlyEdgesIn = RI.newStateIn(arena, { keyBytes = ME_KEY; valBytes = E2_VAL });
      var rebuild = null;
      var rolledUpThrough = 0;
      var postings = 0;
      var edgeCount = 0;
    }
  };

  func sat(v : Nat) : Nat { if (v > AMOUNT_CEILING) AMOUNT_CEILING else v };

  public type DayActivity = { count : Nat; debits : Nat; credits : Nat; largest : Nat };
  public type EdgeSum = { count : Nat; amount : Nat };
  public type Dormancy = { first : Nat; last : Nat; postings : Nat };

  func encodeA1(d : DayActivity) : Blob {
    let b = R.buf();
    R.putNat(b, d.count, 4); R.putNat(b, sat(d.debits), 16); R.putNat(b, sat(d.credits), 16); R.putNat(b, sat(d.largest), 16);
    R.done(b, A1_VAL)
  };
  func decodeA1(v : Blob) : DayActivity {
    let a = Blob.toArray(v);
    { count = R.getNat(a, 0, 4); debits = R.getNat(a, 4, 16); credits = R.getNat(a, 20, 16); largest = R.getNat(a, 36, 16) }
  };
  func encodeSum(e : EdgeSum) : Blob { let b = R.buf(); R.putNat(b, e.count, 4); R.putNat(b, sat(e.amount), 16); R.done(b, E2_VAL) };
  func decodeSum(v : Blob) : EdgeSum { let a = Blob.toArray(v); { count = R.getNat(a, 0, 4); amount = R.getNat(a, 4, 16) } };
  func encodeA4(d : Dormancy) : Blob { let b = R.buf(); R.putNat(b, d.first, 4); R.putNat(b, d.last, 4); R.putNat(b, d.postings, 8); R.done(b, A4_VAL) };
  func decodeA4(v : Blob) : Dormancy { let a = Blob.toArray(v); { first = R.getNat(a, 0, 4); last = R.getNat(a, 4, 4); postings = R.getNat(a, 8, 8) } };

  func a1Key(acct : Nat, day : Nat) : Blob { R.key2(acct, 8, day, 4) };
  func e1Key(from : Counterparty, to : Counterparty, day : Nat, posting : Nat) : Blob {
    let b = R.buf();
    for (x in cptyBytes(from).vals()) R.putByte(b, x);
    for (x in cptyBytes(to).vals()) R.putByte(b, x);
    R.putNat(b, day, 4); R.putNat(b, posting, 8);
    R.done(b, E1_KEY)
  };
  func e2Key(first : Counterparty, day : Nat, second : Counterparty) : Blob {
    let b = R.buf();
    for (x in cptyBytes(first).vals()) R.putByte(b, x);
    R.putNat(b, day, 4);
    for (x in cptyBytes(second).vals()) R.putByte(b, x);
    R.done(b, E2_KEY)
  };

  /// A1 for an account and day, or the empty reading.
  public func dayActivity(s : State, acct : Nat, day : Nat) : DayActivity {
    switch (RI.get(s.activity, a1Key(acct, day))) { case (?v) decodeA1(v); case null ({ count = 0; debits = 0; credits = 0; largest = 0 }) }
  };

  public func dormancy(s : State, acct : Nat) : ?Dormancy {
    switch (RI.get(s.lastActive, R.key(acct, 8))) { case (?v) ?decodeA4(v); case null null }
  };

  /// The most a dormancy read looks back: an A1 range of this many days before the posting. A rule
  /// cannot ask for more (`MonitoringTypes.MAX_WINDOW_DAYS`), so an account whose last activity is
  /// further back than this is dormant for every rule, and the read stays bounded.
  public let DORMANCY_LOOKBACK : Nat = 366;

  /// The latest activity day strictly before `day`, exactly when it lies within the look-back, and
  /// the account's first activity day when all of its activity is further back than that (which
  /// is enough: the gap is then longer than any rule's). Null when the account had no activity
  /// before `day`. At most `DORMANCY_LOOKBACK` rows.
  public func latestBefore(s : State, acct : Nat, day : Nat) : ?Nat {
    if (day == 0) return null;
    // the common case in one read: the account's last active day is before this one, so it is the
    // answer; A4 holds it exactly, live or rolled up
    switch (dormancy(s, acct)) {
      case (?d) { if (d.last < day) return ?d.last };
      case null return null;   // no activity at all
    };
    let from = if (day > DORMANCY_LOOKBACK) day - DORMANCY_LOOKBACK else 0;
    let rows = activityOver(s, acct, from, day - 1);
    if (rows.size() > 0) return ?rows[rows.size() - 1].0;
    // nothing live before the day: the latest rolled-up month's last active day, exactly
    var best : ?Nat = null;
    for (m in monthsOf(s, acct).vals()) { if (m.lastDay < day) { switch (best) { case (?b) { if (m.lastDay > b) best := ?m.lastDay }; case null best := ?m.lastDay } } };
    switch (best) {
      case (?b) ?b;
      case null { switch (dormancy(s, acct)) { case (?d) { if (d.first < from) ?d.first else null }; case null null } };
    }
  };

  public type MonthActivity = { periodOrd : Nat; count : Nat; debits : Nat; credits : Nat; largest : Nat; firstDay : Nat; lastDay : Nat };

  func encodeM1(m : MonthActivity) : Blob {
    let b = R.buf();
    R.putNat(b, m.count, 4); R.putNat(b, sat(m.debits), 16); R.putNat(b, sat(m.credits), 16); R.putNat(b, sat(m.largest), 16); R.putNat(b, m.firstDay, 4); R.putNat(b, m.lastDay, 4);
    R.done(b, M1_VAL)
  };
  func decodeM1(periodOrd : Nat, v : Blob) : MonthActivity {
    let a = Blob.toArray(v);
    { periodOrd; count = R.getNat(a, 0, 4); debits = R.getNat(a, 4, 16); credits = R.getNat(a, 20, 16); largest = R.getNat(a, 36, 16); firstDay = R.getNat(a, 52, 4); lastDay = R.getNat(a, 56, 4) }
  };

  /// An account's rolled-up months, ascending by period ordinal. Bounded by the months packed.
  public func monthsOf(s : State, acct : Nat) : [MonthActivity] {
    let (lo, hi) = R.prefixRange(acct, 8, 4);
    let out = List.empty<MonthActivity>();
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.monthlyActivity, lo, hi, cursor, 500);
      for ((k, v) in page.entries.vals()) List.add(out, decodeM1(R.getNat(Blob.toArray(k), 8, 4), v));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };

  public func monthOf(s : State, acct : Nat, periodOrd : Nat) : ?MonthActivity {
    switch (RI.get(s.monthlyActivity, R.key2(acct, 8, periodOrd, 4))) { case (?v) ?decodeM1(periodOrd, v); case null null }
  };

  func meKey(first : Counterparty, second : Counterparty, periodOrd : Nat) : Blob {
    let b = R.buf();
    for (x in cptyBytes(first).vals()) R.putByte(b, x);
    for (x in cptyBytes(second).vals()) R.putByte(b, x);
    R.putNat(b, periodOrd, 4);
    R.done(b, ME_KEY)
  };

  public type MonthEdge = { key : Blob; periodOrd : Nat; count : Nat; amount : Nat };

  /// The rolled-up edges out of (or into) a counterparty, every month, at most `limit`.
  public func monthlyNeighbours(s : State, who : Counterparty, outward : Bool, limit : Nat) : [MonthEdge] {
    let idx = if (outward) s.monthlyEdges else s.monthlyEdgesIn;
    let lob = R.buf(); for (x in cptyBytes(who).vals()) R.putByte(lob, x); R.putNat(lob, 0, 37);
    let hib = R.buf(); for (x in cptyBytes(who).vals()) R.putByte(hib, x); var i = 0; while (i < 37) { R.putByte(hib, 255); i += 1 };
    let page = RI.range(idx, R.done(lob, ME_KEY), R.done(hib, ME_KEY), null, limit);
    Array.map<(Blob, Blob), MonthEdge>(page.entries, func((k, v)) {
      let ka = Blob.toArray(k); let sum = decodeSum(v);
      { key = R.getBlob(ka, 33, 33); periodOrd = R.getNat(ka, 66, 4); count = sum.count; amount = sum.amount }
    })
  };

  // ═══════════════════════════════════════════════════════
  //  REBUILD; a closed month's rows roll up and leave the live indexes
  // ═══════════════════════════════════════════════════════

  public type Rebuildable = { #activity; #edges; #edgesOut; #edgesIn };

  func current(s : State, which : Rebuildable) : RI.State {
    switch (which) { case (#activity) s.activity; case (#edges) s.edges; case (#edgesOut) s.edgesOut; case (#edgesIn) s.edgesIn }
  };
  func setCurrent(s : State, which : Rebuildable, idx : RI.State) {
    switch (which) { case (#activity) s.activity := idx; case (#edges) s.edges := idx; case (#edgesOut) s.edgesOut := idx; case (#edgesIn) s.edgesIn := idx }
  };

  /// The day in a key of each layout.
  func dayOfKey(which : Rebuildable, k : Blob) : Nat {
    let a = Blob.toArray(k);
    switch (which) { case (#activity) R.getNat(a, 8, 4); case (#edges) R.getNat(a, 66, 4); case (#edgesOut) R.getNat(a, 33, 4); case (#edgesIn) R.getNat(a, 33, 4) }
  };

  /// The keep-or-roll-up decision. A row at or before the period's end is not kept; before it goes
  /// it is added into the month's row, so nothing the month said is lost; only its resolution.
  func rollUp(s : State, which : Rebuildable, periodEnd : Nat, periodOrd : Nat) : (Blob, Blob) -> Bool {
    func(k : Blob, v : Blob) : Bool {
      let day = dayOfKey(which, k);
      if (day > periodEnd) return true;
      let ka = Blob.toArray(k);
      switch (which) {
        case (#activity) {
          let acct = R.getNat(ka, 0, 8);
          let d = decodeA1(v);
          let m = switch (monthOf(s, acct, periodOrd)) {
            case (?m) ({ m with count = m.count + d.count; debits = m.debits + d.debits; credits = m.credits + d.credits; largest = Nat.max(m.largest, d.largest); firstDay = Nat.min(m.firstDay, day); lastDay = Nat.max(m.lastDay, day) });
            case null ({ periodOrd; count = d.count; debits = d.debits; credits = d.credits; largest = d.largest; firstDay = day; lastDay = day });
          };
          ignore RI.put(s.monthlyActivity, R.key2(acct, 8, periodOrd, 4), encodeM1(m));
        };
        case (#edges) {
          // one row per posting edge: the month's edge total, both ways
          let from : Counterparty = #key(R.getBlob(ka, 0, 33));
          let to : Counterparty = #key(R.getBlob(ka, 33, 33));
          let amount = R.getNat(Blob.toArray(v), 0, 16);
          for ((idx, k2) in [(s.monthlyEdges, meKey(from, to, periodOrd)), (s.monthlyEdgesIn, meKey(to, from, periodOrd))].vals()) {
            let sum = switch (RI.get(idx, k2)) { case (?x) decodeSum(x); case null ({ count = 0; amount = 0 }) };
            ignore RI.put(idx, k2, encodeSum({ count = sum.count + 1; amount = sum.amount + amount }));
          };
        };
        case (_) {};   // E2 and E3 are day-first views of E1; the monthly rows come from E1
      };
      false
    }
  };

  func putIdx(s : State, which : Rebuildable, key : Blob, val : Blob) : ?Blob {
    let previous = RI.put(current(s, which), key, val);
    switch (s.rebuild) {
      case (?r) { if (r.which == which) RB.mirror(r.job, key, val, rollUp(s, which, r.periodEnd, r.periodOrd)) };
      case null {};
    };
    previous
  };

  public func beginRebuild(s : State, which : Rebuildable, periodEnd : Nat, periodOrd : Nat) : Bool {
    switch (s.rebuild) { case (?_) return false; case null {} };
    s.rebuild := ?{ which; job = RB.start(current(s, which)); periodEnd; periodOrd };
    true
  };

  public func stepRebuild(s : State, limit : Nat) : { examined : Nat; done : Bool } {
    let ?r = s.rebuild else return { examined = 0; done = true };
    let n = RB.step(r.job, rollUp(s, r.which, r.periodEnd, r.periodOrd), limit);
    { examined = n; done = r.job.done }
  };

  public func finishRebuild(s : State) : ?{ which : Rebuildable; copied : Nat; dropped : Nat } {
    let ?r = s.rebuild else return null;
    if (not r.job.done) return null;
    setCurrent(s, r.which, RB.finish(r.job));
    s.rebuild := null;
    ?{ which = r.which; copied = r.job.copied; dropped = r.job.dropped }
  };

  public func rebuildInProgress(s : State) : ?{ which : Rebuildable; done : Bool } {
    switch (s.rebuild) { case (?r) ?{ which = r.which; done = r.job.done }; case null null }
  };

  /// Every day at or before `periodEnd` is rolled up now; a window rule cannot read there.
  public func markRolledUp(s : State, periodEnd : Nat) { if (periodEnd > s.rolledUpThrough) s.rolledUpThrough := periodEnd };
  public func rolledUpThrough(s : State) : Nat { s.rolledUpThrough };

  /// What one posting changed. `before` is, per account, the latest activity day strictly before
  /// this posting's day; read before the posting is written, which only this message can do.
  public type Recorded = {
    posted : ?Posted;
    before : [(Nat, ?Nat)];
  };

  /// Record a block. Posted activity only, as the header says.
  public func record(s : State, block : JT.Block, ctx : Context) : Recorded {
    switch (block.event) {
      case (#posted(rec)) recordPosted(s, derive(rec, block.index, rec.valueDate, ctx.accountOf));
      case (#post(x)) {
        let ?b = ctx.blockOf(x.pendingIndex) else Runtime.trap("Activity: a resolution of a pending that is not in the log");
        let rec = switch (b.event) {
          case (#pending(p)) p.record;
          case (_) Runtime.trap("Activity: a resolution naming a block that is not a pending");
        };
        recordPosted(s, derive(rec, x.pendingIndex, x.resolution.valueDate, ctx.accountOf))
      };
      case (_) { { posted = null; before = [] } };
    }
  };

  func recordPosted(s : State, p : Posted) : Recorded {
    let before = List.empty<(Nat, ?Nat)>();
    for (a in p.accounts.vals()) {
      let prior = dormancy(s, a.account);
      List.add(before, (a.account, latestBefore(s, a.account, p.day)));
      let d = dayActivity(s, a.account, p.day);
      ignore putIdx(s, #activity, a1Key(a.account, p.day), encodeA1({
        count = d.count + 1; debits = d.debits + a.debits; credits = d.credits + a.credits;
        largest = Nat.max(d.largest, a.largest);
      }));
      let next : Dormancy = switch (prior) {
        case null ({ first = p.day; last = p.day; postings = 1 });
        case (?x) ({ first = Nat.min(x.first, p.day); last = Nat.max(x.last, p.day); postings = x.postings + 1 });
      };
      ignore RI.put(s.lastActive, R.key(a.account, 8), encodeA4(next));
    };
    for (e in p.edges.vals()) {
      let amountRow = R.buf();
      R.putNat(amountRow, sat(e.amount), 16);
      ignore putIdx(s, #edges, e1Key(e.from, e.to, p.day, p.postingNo), R.done(amountRow, E1_VAL));
      let ko = e2Key(e.from, p.day, e.to);
      let so = switch (RI.get(s.edgesOut, ko)) { case (?v) decodeSum(v); case null ({ count = 0; amount = 0 }) };
      ignore putIdx(s, #edgesOut, ko, encodeSum({ count = so.count + 1; amount = so.amount + e.amount }));
      let ki = e2Key(e.to, p.day, e.from);
      let si = switch (RI.get(s.edgesIn, ki)) { case (?v) decodeSum(v); case null ({ count = 0; amount = 0 }) };
      ignore putIdx(s, #edgesIn, ki, encodeSum({ count = si.count + 1; amount = si.amount + e.amount }));
      s.edgeCount += 1;
    };
    s.postings += 1;
    { posted = ?p; before = List.toArray(before) }
  };

  // ─── the bounded reads the rules make ─────────────────────────────────────

  /// A1 over `[from, to]`, at most `to − from + 1` rows.
  public func activityOver(s : State, acct : Nat, from : Nat, to : Nat) : [(Nat, DayActivity)] {
    if (to < from) return [];
    let page = RI.range(s.activity, a1Key(acct, from), a1Key(acct, to), null, to - from + 1);
    Array.map<(Blob, Blob), (Nat, DayActivity)>(page.entries, func((k, v)) { (R.getNat(Blob.toArray(k), 8, 4), decodeA1(v)) })
  };

  public type EdgeRow = { day : Nat; posting : Nat; amount : Nat };

  /// E1: the postings that made an edge `from → to` on days in `[from, to]`, up to `limit`, and
  /// whether there were more.
  public func edgesBetween(s : State, a : Counterparty, b : Counterparty, fromDay : Nat, toDay : Nat, limit : Nat) : { rows : [EdgeRow]; more : Bool } {
    if (toDay < fromDay or limit == 0) return { rows = []; more = false };
    let page = RI.range(s.edges, e1Key(a, b, fromDay, 0), e1Key(a, b, toDay, 0xFFFF_FFFF_FFFF_FFFF), null, limit);
    let rows = Array.map<(Blob, Blob), EdgeRow>(page.entries, func((k, v)) {
      let ka = Blob.toArray(k);
      { day = R.getNat(ka, 66, 4); posting = R.getNat(ka, 70, 8); amount = R.getNat(Blob.toArray(v), 0, 16) }
    });
    { rows; more = page.cursor != null }
  };

  public type Neighbour = { key : Blob; day : Nat; count : Nat; amount : Nat };

  func neighbours(idx : RI.State, first : Counterparty, fromDay : Nat, toDay : Nat, limit : Nat) : { rows : [Neighbour]; more : Bool } {
    if (toDay < fromDay or limit == 0) return { rows = []; more = false };
    let lob = R.buf();
    for (x in cptyBytes(first).vals()) R.putByte(lob, x);
    R.putNat(lob, fromDay, 4); R.putNat(lob, 0, 33);
    let hib = R.buf();
    for (x in cptyBytes(first).vals()) R.putByte(hib, x);
    R.putNat(hib, toDay, 4);
    var i = 0;
    while (i < 33) { R.putByte(hib, 255); i += 1 };
    let lo = R.done(lob, E2_KEY);
    let hi = R.done(hib, E2_KEY);
    let page = RI.range(idx, lo, hi, null, limit);
    let rows = Array.map<(Blob, Blob), Neighbour>(page.entries, func((k, v)) {
      let ka = Blob.toArray(k);
      let sum = decodeSum(v);
      { key = R.getBlob(ka, 37, 33); day = R.getNat(ka, 33, 4); count = sum.count; amount = sum.amount }
    });
    { rows; more = page.cursor != null }
  };

  /// E2: the (day, receiver) rows out of `from` over the window. A fan-out reads these and stops
  /// at its bar: `limit` rows, then `more`.
  public func edgesOut(s : State, from : Counterparty, fromDay : Nat, toDay : Nat, limit : Nat) : { rows : [Neighbour]; more : Bool } {
    neighbours(s.edgesOut, from, fromDay, toDay, limit)
  };

  /// E3: the (day, sender) rows into `to` over the window.
  public func edgesIn(s : State, to : Counterparty, fromDay : Nat, toDay : Nat, limit : Nat) : { rows : [Neighbour]; more : Bool } {
    neighbours(s.edgesIn, to, fromDay, toDay, limit)
  };

  /// Distinct counterparty keys among neighbour rows, in first-seen order, stopping past `bar`.
  public func distinct(rows : [Neighbour], bar : Nat) : { keys : [Blob]; overBar : Bool } {
    let seen = List.empty<Blob>();
    for (r in rows.vals()) {
      var found = false;
      for (k in List.values(seen)) { if (k == r.key) found := true };
      if (not found) {
        List.add(seen, r.key);
        if (List.size(seen) > bar) return { keys = List.toArray(seen); overBar = true };
      };
    };
    { keys = List.toArray(seen); overBar = false }
  };

  public type Stats = { postings : Nat; edges : Nat; a1 : RI.Stats; e1 : RI.Stats; e2 : RI.Stats; e3 : RI.Stats; a4 : RI.Stats; monthly : RI.Stats; rolledUpThrough : Nat; bytes : Nat };

  public func stats(s : State) : Stats {
    let a1 = RI.stats(s.activity); let e1 = RI.stats(s.edges); let e2 = RI.stats(s.edgesOut); let e3 = RI.stats(s.edgesIn); let a4 = RI.stats(s.lastActive);
    let m1 = RI.stats(s.monthlyActivity); let me = RI.stats(s.monthlyEdges); let mi = RI.stats(s.monthlyEdgesIn);
    { postings = s.postings; edges = s.edgeCount; a1; e1; e2; e3; a4; monthly = m1; rolledUpThrough = s.rolledUpThrough;
      bytes = a1.bytes + e1.bytes + e2.bytes + e3.bytes + a4.bytes + m1.bytes + me.bytes + mi.bytes }
  };

  /// Every row of an index, raw, for the oracle's equality check.
  public func dump(idx : RI.State, keyBytes : Nat) : [(Blob, Blob)] {
    let (lo, hi) = R.fullRange(keyBytes);
    let out = List.empty<(Blob, Blob)>();
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(idx, lo, hi, cursor, 500);
      for (e in page.entries.vals()) List.add(out, e);
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
}
