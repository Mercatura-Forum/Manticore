/// PostingIndex.mo — the four posting indexes of `the capacity model`, in stable memory,
/// maintained in the posting's own message.
///
/// The proposal (the index design) asks for four access paths
/// over the postings, and the design asks for them to be written "in the posting's
/// own message (no background indexer, so an index can never lag the journal)". This module is
/// the write side of that; `queryEntries` is the read side built on it.
///
/// ## What is here, and why each structure exists
///
/// The posting **records** are already in stable memory: `JournalLog` appends every block to a
/// Region-backed `StableLog` and `Canonical.decodeBlock` reads it back, so there is no second copy
/// of a posting anywhere in this module. What is missing is a way to *find* a posting without
/// walking the log, and a place to keep the small mutable facts about it that a query must filter
/// on. So:
///
///   * **`headers`** — one fixed-width row per posting, keyed by its posting number (which is its
///     journal block index). It holds the effective dates, the primary currency, the leg count,
///     the status and the period: exactly the fields a query filters on, so a page of results
///     costs one header read a row and never a block decode. The mutable fields are overwritten in
///     place by `put`, which is why the status of a pending that later posts or voids needs no
///     second row.
///   * **`byLedger` (I0)** — sub-ledger key → account id. A journal leg names a chart code and a
///     32-byte sub-ledger key; every per-account key in this component is the **product account
///     id**, because that is what `the capacity model` §2 sized. This is the one lookup that
///     turns the first into the second, and it is registered when the account is opened, so it can
///     never lag either.
///   * **`byAccount` (I1)** — `acctId ‖ valueDay ‖ postingNo`. One account's entries in any date
///     range, as a single range scan. One row per (posting, account): a posting with two legs on
///     the same account is one statement line, which is also what keeps the key at the sized 20
///     bytes rather than needing a leg ordinal.
///   * **`byDay` (I2)** — `valueDay ‖ postingNo`. The day's movements, for the end-of-day batch and
///     the CBE daily returns.
///   * **`byCurrency` (I3)** — `currencyOrdinal ‖ valueDay ‖ postingNo`, one row per (posting,
///     currency), so a four-leg FX deal appears under both of its currencies.
///   * **`byClass` (I4)** — `classOrdinal ‖ valueDay ‖ postingNo`, one row per (posting, declared
///     class). A class is a **declared** extension label; no personal data enters a key.
///
/// ## Three decisions that are easy to get wrong, so they are stated
///
/// **1. A pending that resolves to a different value date.** `#pending` indexes the posting under
/// the date the record asked for. `#post` may resolve it to another date (a calendar shift, or a
/// later business date). Rather than delete the first rows — `RegionIndex` has no single-key
/// delete, by design — the resolution writes rows at the new value day and the header's `valueDay`
/// becomes the effective one. A row whose key's value day does not equal its header's value day is
/// **stale** and every reader drops it. That is exact, append-only, and needs no extra bit.
///
/// **2. Amounts are `Nat` and the value field is eight bytes.** A leg amount at or above 2^64
/// minor units cannot be wrong in an index the way it can be wrong in a balance, but it must not be
/// silently truncated either. Such a row is written with the field saturated to 2^64 − 1 and the
/// header's `saturated` flag set; a reader applying an amount filter reads the block for a
/// saturated row, so the answer stays exact at the cost of one decode for an amount no bank will
/// ever post. Refusing the posting is not an option: the journal has already accepted it.
///
/// **3. Ordinals.** Currencies, declared classes and periods are named by `Text` and indexed by a
/// four-byte registration ordinal. All three sets are bounded — a few dozen currencies, a few dozen
/// classes, a few hundred periods over a bank's life — so the ordinal tables stay on the heap
/// without touching criterion 3 ("heap flat"), which is about the number of postings and accounts.
/// An ordinal is assigned on first sight and never reused, so a key's meaning is fixed for ever.

import Blob "mo:core/Blob";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

import JT "mo:journal/JournalTypes";

import RI "mo:ledger/RegionIndex";
import RB "mo:ledger/RegionRebuild";

module {

  // ═══════════════════════════════════════════════════════
  //  WIDTHS — every one of these is a row in the capacity model §2
  // ═══════════════════════════════════════════════════════

  /// `postingNo(8)` → a 24-byte header. Entry 32 bytes, 255 to a leaf.
  public let HEADER_KEY : Nat = 8;
  public let HEADER_VAL : Nat = 24;

  /// `subledger(32)` → `acctId(8)`. Entry 40 bytes, 204 to a leaf.
  public let LEDGER_KEY : Nat = 32;
  public let LEDGER_VAL : Nat = 8;

  /// `acctId(8) ‖ valueDay(4) ‖ postingNo(8)`, value `[debits:8][credits:8]`.
  public let I1_KEY : Nat = 20;
  /// `valueDay(4) ‖ postingNo(8)`.
  public let I2_KEY : Nat = 12;
  /// `currencyOrdinal(4) ‖ valueDay(4) ‖ postingNo(8)`.
  public let I3_KEY : Nat = 16;
  /// `classOrdinal(4) ‖ valueDay(4) ‖ postingNo(8)`.
  public let I4_KEY : Nat = 16;
  /// Every posting index carries the same movement pair.
  public let MOVEMENT_VAL : Nat = 16;

  /// The widest value an eight-byte movement field can hold. A leg at or above this is indexed
  /// saturated and flagged; see decision 2 in the header.
  public let MOVEMENT_CEILING : Nat = 18_446_744_073_709_551_615;

  /// Four bytes of day, so every date in a key is the same width.
  let DAY_BYTES : Nat = 4;
  let MAX_DAY : Nat = 4_294_967_295;
  let POSTING_BYTES : Nat = 8;
  let ORD_BYTES : Nat = 4;

  // ═══════════════════════════════════════════════════════
  //  STATUS AND FLAGS
  // ═══════════════════════════════════════════════════════

  public let STATUS_POSTED : Nat8 = 0;
  public let STATUS_PENDING : Nat8 = 1;
  public let STATUS_POSTED_FROM_PENDING : Nat8 = 2;
  public let STATUS_VOIDED : Nat8 = 3;

  public let FLAG_MULTI_CURRENCY : Nat8 = 1;
  public let FLAG_SATURATED : Nat8 = 2;
  public let FLAG_VALUE_DATE_SHIFTED : Nat8 = 4;
  public let FLAG_HAS_RELATION : Nat8 = 8;

  public func hasFlag(flags : Nat8, flag : Nat8) : Bool {
    Nat8.toNat(flags) / Nat8.toNat(flag) % 2 == 1
  };

  // ═══════════════════════════════════════════════════════
  //  STATE
  // ═══════════════════════════════════════════════════════

  public type State = {
    /// The one region every index here allocates from.
    arena : RI.Arena;
    /// The five per-posting indexes are `var` because closed-month packing replaces each by a
    /// generation that leaves the packed month out (`beginRebuild` … `finishRebuild`). I0 is per
    /// account and never rebuilt.
    var headers : RI.State;
    byLedger : RI.State;
    var byAccount : RI.State;
    var byDay : RI.State;
    var byCurrency : RI.State;
    var byClass : RI.State;
    /// The rebuild in progress, if any: which index, its job, the highest packed posting and the
    /// packed period's last day — see `keepLive` for which rows leave.
    var rebuild : ?{ which : Rebuildable; job : RB.Job; hiPacked : Nat; periodEnd : Nat };
    /// Bounded name→ordinal tables. See decision 3 in the header.
    currencyOrd : Map.Map<Text, Nat>;
    currencyName : Map.Map<Nat, Text>;
    classOrd : Map.Map<Text, Nat>;
    className : Map.Map<Nat, Text>;
    periodOrd : Map.Map<Text, Nat>;
    periodName : Map.Map<Nat, Text>;
    var nextCurrency : Nat;
    var nextClass : Nat;
    var nextPeriod : Nat;
    /// Postings with a header row. Not the same as the journal's height: configuration blocks have
    /// no header.
    var postings : Nat;
    /// Rows written across I1..I4, which is the figure the capacity model predicts.
    var rows : Nat;
    /// Rows that were superseded by a resolution to a different value date, so the staleness
    /// decision above can be reported rather than assumed.
    var superseded : Nat;
  };

  public func newState() : State {
    // one region for the six indexes: a Region reserves 8 MiB, an arena shares it
    let arena = RI.newArena();
    {
      arena;
      var headers = RI.newStateIn(arena, { keyBytes = HEADER_KEY; valBytes = HEADER_VAL });
      byLedger = RI.newStateIn(arena, { keyBytes = LEDGER_KEY; valBytes = LEDGER_VAL });
      var byAccount = RI.newStateIn(arena, { keyBytes = I1_KEY; valBytes = MOVEMENT_VAL });
      var byDay = RI.newStateIn(arena, { keyBytes = I2_KEY; valBytes = MOVEMENT_VAL });
      var byCurrency = RI.newStateIn(arena, { keyBytes = I3_KEY; valBytes = MOVEMENT_VAL });
      var byClass = RI.newStateIn(arena, { keyBytes = I4_KEY; valBytes = MOVEMENT_VAL });
      var rebuild = null;
      currencyOrd = Map.empty<Text, Nat>();
      currencyName = Map.empty<Nat, Text>();
      classOrd = Map.empty<Text, Nat>();
      className = Map.empty<Nat, Text>();
      periodOrd = Map.empty<Text, Nat>();
      periodName = Map.empty<Nat, Text>();
      var nextCurrency = 0;
      var nextClass = 0;
      var nextPeriod = 0;
      var postings = 0;
      var rows = 0;
      var superseded = 0;
    }
  };

  // ═══════════════════════════════════════════════════════
  //  ORDINALS
  // ═══════════════════════════════════════════════════════

  /// The registration ordinal of a currency, assigned on first sight. Public because a query that
  /// filters on a currency needs the same ordinal the writer used.
  public func currencyOrdinal(s : State, code : JT.Currency) : Nat {
    switch (Map.get(s.currencyOrd, Text.compare, code)) {
      case (?o) o;
      case null {
        let o = s.nextCurrency;
        s.nextCurrency += 1;
        Map.add(s.currencyOrd, Text.compare, code, o);
        Map.add(s.currencyName, Nat.compare, o, code);
        o
      };
    }
  };

  /// The ordinal of a currency already registered, without registering it. A query for a currency
  /// the journal has never seen must answer "no rows", not create an ordinal.
  public func knownCurrency(s : State, code : JT.Currency) : ?Nat {
    Map.get(s.currencyOrd, Text.compare, code)
  };

  public func currencyOf(s : State, ord : Nat) : ?JT.Currency { Map.get(s.currencyName, Nat.compare, ord) };

  public func classOrdinal(s : State, label_ : Text) : Nat {
    switch (Map.get(s.classOrd, Text.compare, label_)) {
      case (?o) o;
      case null {
        let o = s.nextClass;
        s.nextClass += 1;
        Map.add(s.classOrd, Text.compare, label_, o);
        Map.add(s.className, Nat.compare, o, label_);
        o
      };
    }
  };

  public func knownClass(s : State, label_ : Text) : ?Nat { Map.get(s.classOrd, Text.compare, label_) };
  public func classOf(s : State, ord : Nat) : ?Text { Map.get(s.className, Nat.compare, ord) };

  public func periodOrdinal(s : State, id : JT.PeriodId) : Nat {
    switch (Map.get(s.periodOrd, Text.compare, id)) {
      case (?o) o;
      case null {
        let o = s.nextPeriod;
        s.nextPeriod += 1;
        Map.add(s.periodOrd, Text.compare, id, o);
        Map.add(s.periodName, Nat.compare, o, id);
        o
      };
    }
  };

  public func knownPeriod(s : State, id : JT.PeriodId) : ?Nat { Map.get(s.periodOrd, Text.compare, id) };
  public func periodOf(s : State, ord : Nat) : ?JT.PeriodId { Map.get(s.periodName, Nat.compare, ord) };

  // ═══════════════════════════════════════════════════════
  //  ENCODING
  // ═══════════════════════════════════════════════════════

  /// A day, clamped to the four bytes a key gives it. Day 4,294,967,295 is the year 11,761,191, so
  /// the clamp is unreachable from any real date; it is here so a corrupt date cannot trap a
  /// posting that the journal has already accepted.
  func dayBytes(day : JT.Day) : [Nat8] {
    RI.beBytes(if (day > MAX_DAY) MAX_DAY else day, DAY_BYTES)
  };

  /// Eight big-endian bytes, saturating rather than trapping. Decision 2 in the header.
  func satBytes(value : Nat) : [Nat8] {
    RI.beBytes(if (value > MOVEMENT_CEILING) MOVEMENT_CEILING else value, 8)
  };

  public type Header = {
    valueDay : JT.Day;
    postingDay : JT.Day;
    currencyOrd : Nat;
    legs : Nat;
    accountRows : Nat;
    status : Nat8;
    flags : Nat8;
    periodOrd : Nat;
  };

  public type Movement = { debits : Nat; credits : Nat };

  func encodeHeader(h : Header) : Blob {
    RI.key(
      [
        dayBytes(h.valueDay),
        dayBytes(h.postingDay),
        RI.beBytes(h.currencyOrd, ORD_BYTES),
        RI.beBytes(if (h.legs > 65535) 65535 else h.legs, 2),
        RI.beBytes(if (h.accountRows > 65535) 65535 else h.accountRows, 2),
        [h.status],
        [h.flags],
        RI.beBytes(h.periodOrd, ORD_BYTES),
        [0 : Nat8, 0 : Nat8],
      ],
      HEADER_VAL,
    )
  };

  func beNat(bytes : [Nat8], from : Nat, width : Nat) : Nat {
    var v = 0;
    var i = 0;
    while (i < width) { v := v * 256 + Nat8.toNat(bytes[from + i]); i += 1 };
    v
  };

  func decodeHeader(b : Blob) : Header {
    let a = Blob.toArray(b);
    {
      valueDay = beNat(a, 0, 4);
      postingDay = beNat(a, 4, 4);
      currencyOrd = beNat(a, 8, 4);
      legs = beNat(a, 12, 2);
      accountRows = beNat(a, 14, 2);
      status = a[16];
      flags = a[17];
      periodOrd = beNat(a, 18, 4);
    }
  };

  func encodeMovement(m : Movement) : Blob {
    RI.key([satBytes(m.debits), satBytes(m.credits)], MOVEMENT_VAL)
  };

  func decodeMovement(b : Blob) : Movement {
    let a = Blob.toArray(b);
    { debits = beNat(a, 0, 8); credits = beNat(a, 8, 8) }
  };

  // ═══════════════════════════════════════════════════════
  //  KEYS
  // ═══════════════════════════════════════════════════════

  public func headerKey(postingNo : Nat) : Blob {
    RI.key([RI.beBytes(postingNo, POSTING_BYTES)], HEADER_KEY)
  };

  public func accountKey(acctId : Nat, valueDay : JT.Day, postingNo : Nat) : Blob {
    RI.key([RI.beBytes(acctId, 8), dayBytes(valueDay), RI.beBytes(postingNo, POSTING_BYTES)], I1_KEY)
  };

  public func dayKey(valueDay : JT.Day, postingNo : Nat) : Blob {
    RI.key([dayBytes(valueDay), RI.beBytes(postingNo, POSTING_BYTES)], I2_KEY)
  };

  public func currencyKey(ord : Nat, valueDay : JT.Day, postingNo : Nat) : Blob {
    RI.key([RI.beBytes(ord, ORD_BYTES), dayBytes(valueDay), RI.beBytes(postingNo, POSTING_BYTES)], I3_KEY)
  };

  public func classKey(ord : Nat, valueDay : JT.Day, postingNo : Nat) : Blob {
    RI.key([RI.beBytes(ord, ORD_BYTES), dayBytes(valueDay), RI.beBytes(postingNo, POSTING_BYTES)], I4_KEY)
  };

  /// The ends of an account's range over a closed day interval. `to` is inclusive, and the posting
  /// part runs to 0xFF so every posting of the last day is in the range.
  public func accountRangeEnds(acctId : Nat, from : JT.Day, to : JT.Day) : (Blob, Blob) {
    (
      RI.key([RI.beBytes(acctId, 8), dayBytes(from)], I1_KEY),
      RI.key([RI.beBytes(acctId, 8), dayBytes(to), [255, 255, 255, 255, 255, 255, 255, 255] : [Nat8]], I1_KEY),
    )
  };

  public func dayRangeEnds(from : JT.Day, to : JT.Day) : (Blob, Blob) {
    (
      RI.key([dayBytes(from)], I2_KEY),
      RI.key([dayBytes(to), [255, 255, 255, 255, 255, 255, 255, 255] : [Nat8]], I2_KEY),
    )
  };

  public func currencyRangeEnds(ord : Nat, from : JT.Day, to : JT.Day) : (Blob, Blob) {
    (
      RI.key([RI.beBytes(ord, ORD_BYTES), dayBytes(from)], I3_KEY),
      RI.key([RI.beBytes(ord, ORD_BYTES), dayBytes(to), [255, 255, 255, 255, 255, 255, 255, 255] : [Nat8]], I3_KEY),
    )
  };

  public func classRangeEnds(ord : Nat, from : JT.Day, to : JT.Day) : (Blob, Blob) {
    (
      RI.key([RI.beBytes(ord, ORD_BYTES), dayBytes(from)], I4_KEY),
      RI.key([RI.beBytes(ord, ORD_BYTES), dayBytes(to), [255, 255, 255, 255, 255, 255, 255, 255] : [Nat8]], I4_KEY),
    )
  };

  /// The three parts of an I1 key, for a reader walking a page.
  public func splitAccountKey(k : Blob) : { acctId : Nat; valueDay : JT.Day; postingNo : Nat } {
    let a = Blob.toArray(k);
    { acctId = beNat(a, 0, 8); valueDay = beNat(a, 8, 4); postingNo = beNat(a, 12, 8) }
  };

  public func splitDayKey(k : Blob) : { valueDay : JT.Day; postingNo : Nat } {
    let a = Blob.toArray(k);
    { valueDay = beNat(a, 0, 4); postingNo = beNat(a, 4, 8) }
  };

  /// I3 and I4 share a layout.
  public func splitOrdinalKey(k : Blob) : { ord : Nat; valueDay : JT.Day; postingNo : Nat } {
    let a = Blob.toArray(k);
    { ord = beNat(a, 0, 4); valueDay = beNat(a, 4, 4); postingNo = beNat(a, 8, 8) }
  };

  // ═══════════════════════════════════════════════════════
  //  I0 — SUB-LEDGER KEY TO ACCOUNT ID
  // ═══════════════════════════════════════════════════════

  /// Register an account's sub-ledger key. Called when the account is opened, in the same message,
  /// so the reverse lookup can never lag the account. Idempotent: re-registering the same pair is a
  /// no-op, and re-registering a different id for the same key is refused by returning `false`,
  /// because a sub-ledger key is a digest of the issued identifier and two accounts sharing one
  /// would be a defect upstream, not something to silently overwrite.
  public func registerAccount(s : State, subledger : JT.SubledgerKey, acctId : Nat) : Bool {
    if (subledger.size() != LEDGER_KEY) return false;
    let v = RI.key([RI.beBytes(acctId, 8)], LEDGER_VAL);
    switch (RI.get(s.byLedger, subledger)) {
      case (?existing) Blob.equal(existing, v);
      case null { ignore RI.put(s.byLedger, subledger, v); true };
    }
  };

  public func accountOf(s : State, subledger : JT.SubledgerKey) : ?Nat {
    if (subledger.size() != LEDGER_KEY) return null;
    switch (RI.get(s.byLedger, subledger)) {
      case (?v) ?beNat(Blob.toArray(v), 0, 8);
      case null null;
    }
  };

  public func registeredAccounts(s : State) : Nat { RI.size(s.byLedger) };

  // ═══════════════════════════════════════════════════════
  //  READS
  // ═══════════════════════════════════════════════════════

  public func header(s : State, postingNo : Nat) : ?Header {
    switch (RI.get(s.headers, headerKey(postingNo))) {
      case (?v) ?decodeHeader(v);
      case null null;
    }
  };

  public func movementOf(index : RI.State, k : Blob) : ?Movement {
    switch (RI.get(index, k)) { case (?v) ?decodeMovement(v); case null null }
  };

  public func readMovement(v : Blob) : Movement { decodeMovement(v) };

  /// Is this row the live one for its posting? A row whose key's value day differs from its
  /// header's effective value day was superseded by a resolution; decision 1 in the header.
  public func isLive(s : State, postingNo : Nat, keyValueDay : JT.Day) : Bool {
    switch (header(s, postingNo)) {
      case (?h) h.valueDay == keyValueDay;
      case null false;
    }
  };

  /// Live **and posted**: the row is at the posting's final value day and the posting is not a
  /// pending awaiting resolution nor a void. What the monitoring aggregates count, so a rule that
  /// reads I1 sees the same postings the aggregates saw.
  public func isPosted(s : State, postingNo : Nat, keyValueDay : JT.Day) : Bool {
    switch (header(s, postingNo)) {
      case (?h) h.valueDay == keyValueDay and (h.status == STATUS_POSTED or h.status == STATUS_POSTED_FROM_PENDING);
      case null false;
    }
  };

  // ═══════════════════════════════════════════════════════
  //  WRITES
  // ═══════════════════════════════════════════════════════

  /// What the bank must tell the index about a posting that the index cannot work out for itself.
  ///
  /// `classOf` is the declared counterparty class of a product account — party data the index
  /// deliberately does not hold, so it is asked for rather than stored twice.
  ///
  /// `blockOf` reads a block back from the journal's log. It is needed for exactly one case: a
  /// pending that resolves to a different value date has to write its account rows at the new day,
  /// and which accounts those are is a fact about the **record**, not about the header. Reading the
  /// record back and recomputing is how the resolution is guaranteed to agree with the original
  /// indexing, because both run the same pure `sumsOf` over the same bytes. The alternative — a
  /// fifth index from posting to account — would cost seventeen bytes for every (posting, account)
  /// pair to avoid one log read on a path that only a calendar shift reaches.
  public type Context = {
    classOf : Nat -> ?Text;
    blockOf : Nat -> ?JT.Block;
  };

  /// Per-account and per-currency movement sums for one posting, built before anything is written
  /// so a write never half-lands.
  type Sums = {
    accounts : [(Nat, Movement)];
    currencies : [(Nat, Movement)];
    classes : [(Nat, Movement)];
    total : Movement;
    primaryCurrency : Nat;
    multiCurrency : Bool;
    saturated : Bool;
  };

  func addTo(acc : Map.Map<Nat, { var dr : Nat; var cr : Nat }>, k : Nat, side : JT.Side, amount : Nat) {
    let cell = switch (Map.get(acc, Nat.compare, k)) {
      case (?c) c;
      case null { let c = { var dr = 0; var cr = 0 }; Map.add(acc, Nat.compare, k, c); c };
    };
    switch (side) { case (#debit) cell.dr += amount; case (#credit) cell.cr += amount };
  };

  func drain(acc : Map.Map<Nat, { var dr : Nat; var cr : Nat }>) : [(Nat, Movement)] {
    let out = List.empty<(Nat, Movement)>();
    for ((k, c) in Map.entries(acc)) { List.add(out, (k, { debits = c.dr; credits = c.cr })) };
    List.toArray(out)
  };

  func sumsOf(s : State, record : JT.PostingRecord, ctx : Context) : Sums {
    let byAcct = Map.empty<Nat, { var dr : Nat; var cr : Nat }>();
    let byCcy = Map.empty<Nat, { var dr : Nat; var cr : Nat }>();
    let byCls = Map.empty<Nat, { var dr : Nat; var cr : Nat }>();
    var totalDr = 0;
    var totalCr = 0;
    var primary = 0;
    var seenPrimary = false;
    var multi = false;
    var saturated = false;
    for (leg in record.legs.vals()) {
      if (leg.amount > MOVEMENT_CEILING) saturated := true;
      let ord = currencyOrdinal(s, leg.currency);
      if (not seenPrimary) { primary := ord; seenPrimary := true } else if (ord != primary) { multi := true };
      addTo(byCcy, ord, leg.side, leg.amount);
      // The total is the primary currency's movement only: summing minor units across currencies
      // would be a number with no meaning. `multiCurrency` tells a reader when that matters.
      if (ord == primary) {
        switch (leg.side) { case (#debit) totalDr += leg.amount; case (#credit) totalCr += leg.amount };
      };
      switch (leg.subledger) {
        case (?sub) {
          switch (accountOf(s, sub)) {
            case (?acctId) {
              addTo(byAcct, acctId, leg.side, leg.amount);
              switch (ctx.classOf(acctId)) {
                case (?label_) addTo(byCls, classOrdinal(s, label_), leg.side, leg.amount);
                case null {};
              };
            };
            // A leg with a sub-ledger key this bank has not registered is a general-ledger leg of
            // another estate's making; it is reachable through I2 and I3 and the report engine, and
            // inventing an account id for it would put a meaning in a key that nothing can read
            // back.
            case null {};
          };
        };
        case null {};
      };
    };
    {
      accounts = drain(byAcct);
      currencies = drain(byCcy);
      classes = drain(byCls);
      total = { debits = totalDr; credits = totalCr };
      primaryCurrency = primary;
      multiCurrency = multi;
      saturated;
    }
  };

  func flagsOf(record : JT.PostingRecord, sums : Sums) : Nat8 {
    var f : Nat8 = 0;
    if (sums.multiCurrency) f += FLAG_MULTI_CURRENCY;
    if (sums.saturated) f += FLAG_SATURATED;
    switch (record.valueDateRequested) { case (?_) { f += FLAG_VALUE_DATE_SHIFTED }; case null {} };
    switch (record.relation) { case (?_) { f += FLAG_HAS_RELATION }; case null {} };
    f
  };

  /// Write the index rows for one posting at `valueDay`. Used both for the first indexing of a
  /// posting and for a resolution that moved its value date.
  func writeRows(s : State, postingNo : Nat, valueDay : JT.Day, sums : Sums) : Nat {
    var written = 0;
    for ((acctId, m) in sums.accounts.vals()) {
      if (putIdx(s, #byAccount, accountKey(acctId, valueDay, postingNo), encodeMovement(m)) == null) written += 1;
    };
    if (putIdx(s, #byDay, dayKey(valueDay, postingNo), encodeMovement(sums.total)) == null) written += 1;
    for ((ord, m) in sums.currencies.vals()) {
      if (putIdx(s, #byCurrency, currencyKey(ord, valueDay, postingNo), encodeMovement(m)) == null) written += 1;
    };
    for ((ord, m) in sums.classes.vals()) {
      if (putIdx(s, #byClass, classKey(ord, valueDay, postingNo), encodeMovement(m)) == null) written += 1;
    };
    s.rows += written;
    written
  };

  public type Written = {
    postingNo : Nat;
    /// Rows added across I1..I4. Zero when the block was not a posting.
    rows : Nat;
    /// True when the block carried a posting this index took an interest in.
    indexed : Bool;
  };

  let NOTHING : Written = { postingNo = 0; rows = 0; indexed = false };

  /// Index one journal block. Called from the bank's single `commitJournal` funnel, in the posting's
  /// own message, immediately after `JCore.apply`. Every block shape the journal can produce is
  /// named here: the configuration shapes write nothing and say so, so a new event variant in the
  /// journal becomes a compile error here rather than a silently unindexed posting.
  public func indexBlock(s : State, block : JT.Block, ctx : Context) : Written {
    switch (block.event) {

      case (#posted(record)) {
        let sums = sumsOf(s, record, ctx);
        let rows = writeRows(s, block.index, record.valueDate, sums);
        ignore putIdx(
          s, #headers,
          headerKey(block.index),
          encodeHeader({
            valueDay = record.valueDate;
            postingDay = record.postingDate;
            currencyOrd = sums.primaryCurrency;
            legs = record.legs.size();
            accountRows = sums.accounts.size();
            status = STATUS_POSTED;
            flags = flagsOf(record, sums);
            periodOrd = periodOrdinal(s, record.period);
          }),
        );
        s.postings += 1;
        { postingNo = block.index; rows; indexed = true }
      };

      case (#pending(x)) {
        let sums = sumsOf(s, x.record, ctx);
        let rows = writeRows(s, block.index, x.record.valueDate, sums);
        ignore putIdx(
          s, #headers,
          headerKey(block.index),
          encodeHeader({
            valueDay = x.record.valueDate;
            postingDay = x.record.postingDate;
            currencyOrd = sums.primaryCurrency;
            legs = x.record.legs.size();
            accountRows = sums.accounts.size();
            status = STATUS_PENDING;
            flags = flagsOf(x.record, sums);
            periodOrd = periodOrdinal(s, x.record.period);
          }),
        );
        s.postings += 1;
        { postingNo = block.index; rows; indexed = true }
      };

      // A pending becomes a posting. The dates and the period are the resolution's, not the
      // record's. Rows at the resolved value day are written when it differs; the rows at the
      // original day become stale and every reader drops them.
      case (#post(x)) {
        switch (header(s, x.pendingIndex)) {
          case null NOTHING;
          case (?h) {
            var rows = 0;
            if (h.valueDay != x.resolution.valueDate) {
              rows := rewriteAt(s, x.pendingIndex, x.resolution.valueDate, ctx);
            };
            ignore putIdx(
              s, #headers,
              headerKey(x.pendingIndex),
              encodeHeader({
                valueDay = x.resolution.valueDate;
                postingDay = x.resolution.postingDate;
                currencyOrd = h.currencyOrd;
                legs = h.legs;
                accountRows = h.accountRows;
                status = STATUS_POSTED_FROM_PENDING;
                flags = h.flags;
                periodOrd = periodOrdinal(s, x.resolution.period);
              }),
            );
            { postingNo = x.pendingIndex; rows; indexed = true }
          };
        }
      };

      case (#void(x)) {
        switch (header(s, x.pendingIndex)) {
          case null NOTHING;
          case (?h) {
            ignore putIdx(
              s, #headers,
              headerKey(x.pendingIndex),
              encodeHeader({
                valueDay = h.valueDay;
                postingDay = h.postingDay;
                currencyOrd = h.currencyOrd;
                legs = h.legs;
                accountRows = h.accountRows;
                status = STATUS_VOIDED;
                flags = h.flags;
                periodOrd = h.periodOrd;
              }),
            );
            { postingNo = x.pendingIndex; rows = 0; indexed = true }
          };
        }
      };

      case (#currencyRegistered(info)) { ignore currencyOrdinal(s, info.code); NOTHING };
      case (#periodOpened(x)) { ignore periodOrdinal(s, x.id); NOTHING };

      case (#accountOpened(_)) NOTHING;
      case (#accountClosed(_)) NOTHING;
      case (#periodClosed(_)) NOTHING;
      case (#activationHeight(_)) NOTHING;
      case (#leadsheetSchema(_)) NOTHING;
      case (#posterAdded(_)) NOTHING;
      case (#posterRemoved(_)) NOTHING;
      case (#posterScopeSet(_)) NOTHING;
      case (#balanceLimitSet(_)) NOTHING;
      case (#accountAttributesSet(_)) NOTHING;
      case (#adminTransferred(_)) NOTHING;
      case (#businessDateRolled(_)) NOTHING;
      case (#calendarSet(_)) NOTHING;
      case (#checkpoint(_)) NOTHING;
    }
  };

  /// Write a resolved pending's rows at the day it resolved to.
  ///
  /// The movements are recomputed from the pending's own record, read back out of the journal's log,
  /// by the same `sumsOf` that indexed it in the first place. Two consequences, and both are the
  /// reason it is done this way rather than by copying rows: the resolution cannot disagree with the
  /// original indexing about what the posting moved, and the account rows — whose account ids are
  /// nowhere in the fixed-width header — are recovered exactly.
  ///
  /// The rows at the old day are left in place and become stale; `isLive` is what every reader uses
  /// to drop them, and `superseded` counts them so the effect is reportable rather than assumed.
  func rewriteAt(s : State, postingNo : Nat, toDay : JT.Day, ctx : Context) : Nat {
    let ?block = ctx.blockOf(postingNo) else Runtime.trap(
      "PostingIndex: the pending at " # Nat.toText(postingNo) # " resolved to a different value day, but its block is not readable from the log. A pending is by definition unresolved, so it can never be in an archived period; this is a defect, and trapping rolls the resolution back rather than indexing it wrongly."
    );
    let record = switch (block.event) {
      case (#pending(x)) x.record;
      // A resolution can only name a block the journal recorded as a pending. Anything else means
      // the header and the log disagree about what the posting is.
      case (_) Runtime.trap("PostingIndex: block " # Nat.toText(postingNo) # " has a posting header but is not a pending");
    };
    let sums = sumsOf(s, record, ctx);
    s.superseded += sums.accounts.size() + 1 + sums.currencies.size() + sums.classes.size();
    writeRows(s, postingNo, toDay, sums)
  };

  // ═══════════════════════════════════════════════════════
  //  REBUILD — closed-month packing leaves a month's rows out
  // ═══════════════════════════════════════════════════════

  public type Rebuildable = { #headers; #byAccount; #byDay; #byCurrency; #byClass };

  func current(s : State, which : Rebuildable) : RI.State {
    switch (which) { case (#headers) s.headers; case (#byAccount) s.byAccount; case (#byDay) s.byDay; case (#byCurrency) s.byCurrency; case (#byClass) s.byClass }
  };

  func setCurrent(s : State, which : Rebuildable, idx : RI.State) {
    switch (which) { case (#headers) s.headers := idx; case (#byAccount) s.byAccount := idx; case (#byDay) s.byDay := idx; case (#byCurrency) s.byCurrency := idx; case (#byClass) s.byClass := idx }
  };

  /// The posting number in a key of each layout: `postingNo(8)` for a header; the last eight bytes
  /// of every movement key.
  func postingOfKey(which : Rebuildable, k : Blob) : Nat {
    let a = Blob.toArray(k);
    let off = switch (which) { case (#headers) 0; case (#byAccount) 12; case (#byDay) 4; case (#byCurrency) 8; case (#byClass) 8 };
    var v = 0;
    var i = 0;
    while (i < 8) { v := v * 256 + Nat8.toNat(a[off + i]); i += 1 };
    v
  };

  /// Which rows stay live across a pack. The reads honour a **day** boundary — every value day at
  /// or before the packed period's end is answered from the packs, every later day from here — so
  /// a row leaves exactly when its posting is in the packed block range **and** its value day is
  /// at or before the period's end. A posting in the range whose value day is later (an early
  /// posting of the next period, made before the close) keeps its rows; so does a pending still
  /// unresolved at the pack, whose resolution has not happened yet and will land here.
  ///
  /// The headers are rebuilt first and decide; the four movement indexes keep a row exactly when
  /// its posting still has a header — one lookup per examined row of a packed posting, none for a
  /// live one.
  func keepLive(s : State, which : Rebuildable, hiPacked : Nat, periodEnd : Nat) : (Blob, Blob) -> Bool {
    func(k : Blob, v : Blob) : Bool {
      let p = postingOfKey(which, k);
      if (p > hiPacked) return true;
      switch (which) {
        case (#headers) { let h = decodeHeader(v); h.valueDay > periodEnd or h.status == STATUS_PENDING };
        case (_) { switch (RI.get(s.headers, headerKey(p))) { case (?_) true; case null false } };
      }
    }
  };

  /// Every write goes through here: the current index always, and the rebuild's target when the
  /// index is the one being rebuilt and the copy has passed the key.
  func putIdx(s : State, which : Rebuildable, key : Blob, val : Blob) : ?Blob {
    let previous = RI.put(current(s, which), key, val);
    switch (s.rebuild) {
      case (?r) { if (r.which == which) RB.mirror(r.job, key, val, keepLive(s, which, r.hiPacked, r.periodEnd)) };
      case null {};
    };
    previous
  };

  /// Start rebuilding one index without the rows `keepLive` leaves out. Refused while another
  /// rebuild is in progress. The headers must be rebuilt before the movement indexes.
  public func beginRebuild(s : State, which : Rebuildable, hiPacked : Nat, periodEnd : Nat) : Bool {
    switch (s.rebuild) { case (?_) return false; case null {} };
    s.rebuild := ?{ which; job = RB.start(current(s, which)); hiPacked; periodEnd };
    true
  };

  public func stepRebuild(s : State, limit : Nat) : { examined : Nat; done : Bool } {
    let ?r = s.rebuild else return { examined = 0; done = true };
    let n = RB.step(r.job, keepLive(s, r.which, r.hiPacked, r.periodEnd), limit);
    { examined = n; done = r.job.done }
  };

  /// Swap the rebuilt index in and release the old one's pages. Only when the copy is done.
  public func finishRebuild(s : State) : ?{ which : Rebuildable; copied : Nat; dropped : Nat } {
    let ?r = s.rebuild else return null;
    if (not r.job.done) return null;
    setCurrent(s, r.which, RB.finish(r.job));
    s.rebuild := null;
    ?{ which = r.which; copied = r.job.copied; dropped = r.job.dropped }
  };

  public func rebuildInProgress(s : State) : ?{ which : Rebuildable; copied : Nat; dropped : Nat; done : Bool } {
    switch (s.rebuild) { case (?r) ?{ which = r.which; copied = r.job.copied; dropped = r.job.dropped; done = r.job.done }; case null null }
  };

  public func rebuildableText(w : Rebuildable) : Text {
    switch (w) { case (#headers) "headers"; case (#byAccount) "byAccount"; case (#byDay) "byDay"; case (#byCurrency) "byCurrency"; case (#byClass) "byClass" }
  };

  // ═══════════════════════════════════════════════════════
  //  STATS
  // ═══════════════════════════════════════════════════════

  public type Stats = {
    postings : Nat;
    rows : Nat;
    superseded : Nat;
    accounts : Nat;
    currencies : Nat;
    classes : Nat;
    periods : Nat;
    headers : RI.Stats;
    ledger : RI.Stats;
    i1 : RI.Stats;
    i2 : RI.Stats;
    i3 : RI.Stats;
    i4 : RI.Stats;
    /// Stable-memory bytes across every structure here, which is the figure the capacity
    /// model predicts.
    bytes : Nat;
  };

  public func stats(s : State) : Stats {
    let h = RI.stats(s.headers);
    let l = RI.stats(s.byLedger);
    let a = RI.stats(s.byAccount);
    let d = RI.stats(s.byDay);
    let c = RI.stats(s.byCurrency);
    let k = RI.stats(s.byClass);
    {
      postings = s.postings;
      rows = s.rows;
      superseded = s.superseded;
      accounts = RI.size(s.byLedger);
      currencies = s.nextCurrency;
      classes = s.nextClass;
      periods = s.nextPeriod;
      headers = h;
      ledger = l;
      i1 = a;
      i2 = d;
      i3 = c;
      i4 = k;
      bytes = h.bytes + l.bytes + a.bytes + d.bytes + c.bytes + k.bytes;
    }
  };
}
