/// JournalCore.mo: the pure double-entry state machine.
///
/// This module holds no Region memory, performs no I/O and reads no clock:
/// every function takes the current time as an argument and returns either an
/// `Event` to be committed or a typed error. State changes happen only in
/// `apply`, which consumes committed blocks. That split gives three
/// properties the journal depends on:
///
///   1. Admission is exhaustive and atomic. `prepare*` validates everything;
///      the balance invariant, period status, account status, dates, limits,
///      authorization, idempotency; before an event exists, so a rejected
///      posting has touched nothing.
///   2. The state is a fold over the log. `replay` rebuilds an identical state
///      from the committed blocks alone, which is how the "independent
///      recomputation" and "restart" criteria are proven.
///   3. The module runs in the Motoko interpreter, so the accounting rules are
///      unit-tested without a replica.
///
/// Invariants maintained by `apply` (checked by tests, never relaxed):
///   INV-J1  For every posted posting and every currency, Σdebits = Σcredits.
///   INV-J2  For every (account, currency): debitsPosted and creditsPosted are the
///           sums over posted legs; debitsPending/creditsPending over unresolved pendings.
///   INV-J3  A period's trial balance is the sum of its postings' legs; a closed
///           period's figures never change.
///   INV-J4  A pending posting is in exactly one of {unresolved, posted, voided}.
///   INV-J5  A posting is reversed at most once.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import Int "mo:core/Int";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Order "mo:core/Order";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

import T "JournalTypes";
import C "Canonical";
import CivilDate "CivilDate";
import Leadsheet "Leadsheet";
import Calendar "Calendar";
import RI "../ledger/RegionIndex";
import RB "../ledger/RegionRebuild";

module {

  // ═══════════════════════════════════════════════════════
  //  STATE
  // ═══════════════════════════════════════════════════════

  type Acc = { var dr : Nat; var cr : Nat };

  type Bal = { var drPosted : Nat; var crPosted : Nat; var drPending : Nat; var crPending : Nat };

  public type AccountEntry = {
    code : T.AccountCode;
    name : Text;
    normalSide : T.Side;
    category : T.Category;
    constraint : T.BalanceConstraint;
    var status : T.AccountStatus;
    openedAtBlock : Nat;
    var closedAtBlock : ?Nat;
  };

  public type PeriodEntry = {
    id : T.PeriodId;
    start : T.Day;
    end : T.Day;
    var status : T.PeriodStatus;
    openedAtBlock : Nat;
    var closedAtBlock : ?Nat;
  };

  public type SubmissionKind = { #immediate; #pending };

  type IdemEntry = { index : Nat; contentHash : Blob; kind : SubmissionKind };

  /// How the journal reads a posting's record back.
  ///
  /// A posting's record lives in the **block log**; a Region-backed `StableLog` whose bytes
  /// `Canonical.decodeBlock` reads back; so the journal's own state keeps only the mutable facts about
  /// a posting and reads the record through this when it needs it.
  ///
  /// Before this, `postings : Map<Nat, PostingMeta>` held the whole record a second time, on the heap.
  /// Measured: **542 heap bytes a posting**, which is the heap growing with the journal; the one thing
  /// a contract's heap must not do, because the heap is resident in a validator's memory while stable
  /// memory is not. The banking layer's approved indexing proposal makes it a criterion ("the heap
  /// keeps only bounded aggregates").
  ///
  /// It is a record of one function rather than a bare function so that a caller reading a signature
  /// sees what is being asked for.
  public type Blocks = { get : Nat -> ?T.Block };

  /// The posting facts that are **not** in the block log, in one fixed-width stable-memory row.
  ///
  /// Keyed by the posting number, which is its block index. 84 bytes:
  ///
  ///     [0]       status            0 posted, 1 pending, 2 postedFromPending, 3 voided
  ///     [1]       flags             bit0 reversedBy present, bit1 expiresAt present,
  ///                                 bit2 the resolution's valueDateRequested present,
  ///                                 bit3 the void reason is #expired rather than #requested
  ///     [2..10)   reversedBy
  ///     [10..18)  expiresAt         a pending's expiry
  ///     [18..26)  resolvedBy        the #post or #void block that resolved a pending
  ///     [26..30)  resolution postingDate
  ///     [30..34)  resolution valueDate
  ///     [34..38)  resolution valueDateRequested
  ///     [38..42)  resolution period, as a registration ordinal
  ///     [42..46)  corrector count
  ///     [46..54)  timestamp
  ///     [54]      caller length
  ///     [55..84)  caller bytes
  ///
  /// One resolution slot serves both `#postedFromPending`'s payload and `effective`, because `apply`
  /// sets them to the same value; and for an immediate posting `effective` **is** the record's own
  /// dates, so it is derived from the record rather than stored. Storing a second copy of a value that
  /// is always equal to the first is how the two come to disagree.
  let POSTING_KEY_BYTES : Nat = 8;
  let POSTING_ROW_BYTES : Nat = 84;
  /// `postingNo(8) | sequence(4)` -> `corrector(8)`. A posting's corrections are a list of unknown
  /// length, so they are a range scan of their own rather than a wider fixed row.
  let CORRECTOR_KEY_BYTES : Nat = 12;
  let CORRECTOR_VAL_BYTES : Nat = 8;
  /// The duplicate-rejection index: `scopeKey(32)` -> `[index(8)][kind(1)][contentHash(32)]`.
  /// One entry a posting, so it grew the heap with the journal exactly as the posting map did.
  let IDEM_KEY_BYTES : Nat = 32;
  let IDEM_VAL_BYTES : Nat = 41;
  /// A period's posted postings: `periodOrdinal(4) | postingNo(8)` with no value. One entry a posting,
  /// and a period's run is contiguous because the key puts the period first; so a page is a seek plus
  /// the page, where the heap list it replaces was a slice of an ever-growing `List`.
  let PERIOD_POSTING_KEY_BYTES : Nat = 12;
  /// Value-dated and posting-dated accumulators:
  /// `accountOrdinal(4) | currencyOrdinal(4) | subledger(64) | day(4)` -> `[debits(8)][credits(8)]`.
  ///
  /// The order of the key parts is the whole design. Putting the currency before the sub-ledger makes
  /// both questions a contiguous run: one sub-ledger's days, and; for `subledger = null`, which asks
  /// for an account summed across its sub-ledgers; that account and currency's whole run. Before this
  /// both reads **scanned every account-day in the book** on every call, so this is a bound on cost as
  /// much as on the heap.
  /// The sub-ledger field is the **full** `T.MAX_SUBLEDGER_BYTES`, not a digest of the key. A digest
  /// would be narrower and would let two sub-ledgers collide, and a collision here is a wrong balance;
  /// the one kind of wrongness this estate may not trade width for. The first run of the journal's own
  /// suite found this: a 62-byte sub-ledger key trapped against a 32-byte field.
  let DATED_KEY_BYTES : Nat = 76;
  let DATED_VAL_BYTES : Nat = 16;
  let DATED_SUB_OFFSET : Nat = 8;
  let DATED_DAY_OFFSET : Nat = 72;

  let STATUS_POSTED : Nat8 = 0;
  let STATUS_PENDING : Nat8 = 1;
  let STATUS_FROM_PENDING : Nat8 = 2;
  let STATUS_VOIDED : Nat8 = 3;

  let FLAG_REVERSED : Nat8 = 1;
  let FLAG_EXPIRES : Nat8 = 2;
  let FLAG_VDR : Nat8 = 4;
  let FLAG_EXPIRED_REASON : Nat8 = 8;

  /// Everything the journal knows about one posting, assembled from its row and its record. Immutable:
  /// the mutable fields live in stable memory now and are changed through the setters below, not by
  /// mutating a shared heap object; which also makes every change to a posting's state a line you can
  /// find by searching for the setter.
  public type PostingMeta = {
    index : Nat;
    timestamp : Nat64;
    caller : Principal;
    record : T.PostingRecord;
    status : T.PostingStatus;
    reversedBy : ?Nat;
    correctedBy : [Nat];
    /// dates and period the posting is booked under (== record's for immediate
    /// postings; the resolution for postings that came out of a pending)
    effective : ?T.Resolution;
  };

  /// The row alone, for the many reads that do not need the record: a status check, a reversal check,
  /// an expiry sweep. Each of those was a heap-map read and is now one B-tree descent.
  public type PostingRow = {
    status : Nat8;
    flags : Nat8;
    reversedBy : ?Nat;
    expiresAt : ?Nat64;
    resolvedBy : Nat;
    resolution : ?T.Resolution;
    correctors : Nat;
    timestamp : Nat64;
    caller : Principal;
  };

  public type State = {
    /// The one region every index below allocates from.
    arena : RI.Arena;
    var admin : Principal;
    posters : Map.Map<Principal, ()>;
    posterScopes : Map.Map<Principal, T.PosterScope>;          // present only when that poster is restricted
    /// Numeric balance limits per (account, sub-ledger, currency). Absent means
    /// the account's own `constraint` governs, which is every account until a
    /// limit is recorded.
    balanceLimits : Map.Map<(Text, Blob, Text), T.BalanceLimit>;
    /// Chart-of-accounts attributes per account; absent reads as the default.
    accountAttributes : Map.Map<T.AccountCode, T.AccountAttributes>;
    var activationHeight : Nat64;
    var height : Nat;                                   // blocks applied
    currencies : Map.Map<T.Currency, Nat8>;
    accounts : Map.Map<T.AccountCode, AccountEntry>;
    periods : Map.Map<T.PeriodId, PeriodEntry>;
    balances : Map.Map<(Text, Blob, Text), Bal>;                 // (account, sub-ledger key or "", currency)
    periodBalances : Map.Map<(Text, Text, Text), Acc>;           // (period, account, currency)
    /// In stable memory: one entry per (account, sub-ledger, currency, day) that was posted to, which
    /// grows with the journal.
    var valueDatedIndex : RI.State;
    var postingDatedIndex : RI.State;
    /// Chart-of-accounts codes are `Text`; the fixed-width keys above use a registration ordinal.
    /// Bounded by the chart, which is bounded by recorded acts.
    accountOrdinals : Map.Map<T.AccountCode, Nat>;
    accountNames : Map.Map<Nat, T.AccountCode>;
    var nextAccountOrdinal : Nat;
    currencyOrdinals : Map.Map<T.Currency, Nat>;
    var nextCurrencyOrdinal : Nat;
    /// In stable memory: one entry a posting. `periodPostingCounts` keeps the per-period total on the
    /// heap, which is bounded by the number of periods rather than by the number of postings.
    var periodPostingIndex : RI.State;
    periodPostingCounts : Map.Map<T.PeriodId, Nat>;
    /// The posting rows above, in stable memory. Not a heap map: see `Blocks`.
    var postingRows : RI.State;
    /// `postingNo | sequence` -> the posting that corrected it.
    var correctors : RI.State;
    /// The archive roll's drop in progress: which of the five per-posting indexes is being rebuilt
    /// without the archived range (`beginArchiveDrop`), the boundary block and the packed period's
    /// last day. Rows of postings at or below `hi` leave; dated rows at or before `periodEnd` roll
    /// up into one row at `periodEnd`.
    var archiveDrop : ?{ which : Droppable; job : RB.Job; hi : Nat; periodEnd : Nat };
    /// Every dated row at or before this day has been rolled up: a balance as of an earlier day is
    /// not answerable from the live indexes.
    var datedRolledUpThrough : Nat;
    /// The latest checkpoint series the log carries: what a fold of the retained log starts from.
    var checkpoint : ?{ through : Nat; first : Nat; var last : ?Nat };
    /// Period identifiers are `Text`; a fixed-width row keys them by registration ordinal. Both tables
    /// are bounded by the number of accounting periods a bank ever opens, so they stay on the heap
    /// without touching the criterion that the heap does not grow with the journal.
    periodOrdinals : Map.Map<T.PeriodId, Nat>;
    periodNames : Map.Map<Nat, T.PeriodId>;
    var nextPeriodOrdinal : Nat;
    var postingRowCount : Nat;
    openPendings : Map.Map<Nat, ()>;
    pendingByPeriod : Map.Map<T.PeriodId, Nat>;
    pendingByAccount : Map.Map<T.AccountCode, Nat>;
    /// Open pending legs per currency: what a currency's retirement asks before it closes the currency, in constant time.
    pendingByCurrency : Map.Map<T.Currency, Nat>;
    /// In stable memory: one entry a posting, so on the heap it grew with the journal. `var`
    /// because a closed month's keys are dropped after the dedup window by rebuilding the index
    /// without them (`beginIdempotencyRebuild` … `finishIdempotencyRebuild`).
    var idempotencyIndex : RI.State;
    var idempotencyCount : Nat;
    var idempotencyRebuild : ?{ job : RB.Job; hiPacked : Nat };
    /// Keys of postings at or below this index have been dropped: a duplicate of one is no longer
    /// refused as a duplicate. The bank sets the dedup window that makes that acceptable.
    var idempotencyDroppedThrough : Nat;
    var leadsheet : [T.LeadsheetRange];                          // sorted by lo
    var postedCount : Nat;
    var voidedCount : Nat;
    // the journal calendar period-end processes
    var businessDate : ?T.Day;                                   // the accounting "today" once set
    var calendar : ?T.CalendarConfig;                            // working-day calendar and shift policy
    // where "today" comes from (see JournalTypes) and, under #businessDate, the most a roll may advance; both
    // optional so a journal persisted before the authority existed upgrades in place: null is the substrate clock
    var calendarAuthority : ?T.CalendarAuthority;
    var maxRollDays : ?Nat;
  };

  public func newState(admin : Principal) : State {
    // one region for every index of the journal: a Region reserves 8 MiB, an arena shares it
    newStateIn(admin, RI.newArena())
  };

  /// A state whose indexes live in a given arena; the archive roll's shadow fold uses one arena
  /// across rolls, releasing the indexes back to it when the fold is done (`releaseIndexes`).
  public func newStateIn(admin : Principal, arena : RI.Arena) : State {
    {
      arena;
      var admin;
      posters = Map.empty<Principal, ()>();
      posterScopes = Map.empty<Principal, T.PosterScope>();
      balanceLimits = Map.empty<(Text, Blob, Text), T.BalanceLimit>();
      accountAttributes = Map.empty<T.AccountCode, T.AccountAttributes>();
      var activationHeight = T.ACTIVATION_OFF;
      var height = 0;
      currencies = Map.empty<T.Currency, Nat8>();
      accounts = Map.empty<T.AccountCode, AccountEntry>();
      periods = Map.empty<T.PeriodId, PeriodEntry>();
      balances = Map.empty<(Text, Blob, Text), Bal>();
      periodBalances = Map.empty<(Text, Text, Text), Acc>();
      var valueDatedIndex = RI.newStateIn(arena, { keyBytes = DATED_KEY_BYTES; valBytes = DATED_VAL_BYTES });
      var postingDatedIndex = RI.newStateIn(arena, { keyBytes = DATED_KEY_BYTES; valBytes = DATED_VAL_BYTES });
      accountOrdinals = Map.empty<T.AccountCode, Nat>();
      accountNames = Map.empty<Nat, T.AccountCode>();
      var nextAccountOrdinal = 0;
      currencyOrdinals = Map.empty<T.Currency, Nat>();
      var nextCurrencyOrdinal = 0;
      var periodPostingIndex = RI.newStateIn(arena, { keyBytes = PERIOD_POSTING_KEY_BYTES; valBytes = 0 });
      periodPostingCounts = Map.empty<T.PeriodId, Nat>();
      var postingRows = RI.newStateIn(arena, { keyBytes = POSTING_KEY_BYTES; valBytes = POSTING_ROW_BYTES });
      var correctors = RI.newStateIn(arena, { keyBytes = CORRECTOR_KEY_BYTES; valBytes = CORRECTOR_VAL_BYTES });
      var archiveDrop = null;
      var datedRolledUpThrough = 0;
      var checkpoint = null;
      periodOrdinals = Map.empty<T.PeriodId, Nat>();
      periodNames = Map.empty<Nat, T.PeriodId>();
      var nextPeriodOrdinal = 0;
      var postingRowCount = 0;
      openPendings = Map.empty<Nat, ()>();
      pendingByPeriod = Map.empty<T.PeriodId, Nat>();
      pendingByAccount = Map.empty<T.AccountCode, Nat>();
      pendingByCurrency = Map.empty<T.Currency, Nat>();
      var idempotencyIndex = RI.newStateIn(arena, { keyBytes = IDEM_KEY_BYTES; valBytes = IDEM_VAL_BYTES });
      var idempotencyCount = 0;
      var idempotencyRebuild = null;
      var idempotencyDroppedThrough = 0;
      var leadsheet = [];
      var postedCount = 0;
      var voidedCount = 0;
      var businessDate = null;
      var calendar = null;
      var calendarAuthority = null;
      var maxRollDays = null;
    }
  };

  // ═══════════════════════════════════════════════════════
  //  POSTING ROWS; the stable-memory replacement for the heap posting map
  // ═══════════════════════════════════════════════════════

  /// The registration ordinal of a period, assigned on first sight and never reused, so a row written
  /// under one ordinal means the same period for ever.
  func periodOrdinal(state : State, id : T.PeriodId) : Nat {
    switch (Map.get(state.periodOrdinals, Text.compare, id)) {
      case (?o) o;
      case null {
        let o = state.nextPeriodOrdinal;
        state.nextPeriodOrdinal += 1;
        Map.add(state.periodOrdinals, Text.compare, id, o);
        Map.add(state.periodNames, Nat.compare, o, id);
        o
      };
    }
  };

  func periodOfOrdinal(state : State, o : Nat) : T.PeriodId {
    switch (Map.get(state.periodNames, Nat.compare, o)) {
      case (?id) id;
      // Unreachable: an ordinal only exists because a period was named, and nothing removes either
      // table's entry. Trapping rather than returning "" keeps a corrupt row from becoming a posting
      // booked to a period nobody opened.
      case null Runtime.trap("JournalCore: period ordinal " # Nat.toText(o) # " has no name");
    }
  };

  func be(value : Nat, width : Nat) : [Nat8] { RI.beBytes(value, width) };

  func beNat(a : [Nat8], from : Nat, width : Nat) : Nat {
    var v = 0;
    var i = 0;
    while (i < width) { v := v * 256 + Nat8.toNat(a[from + i]); i += 1 };
    v
  };

  func hasFlag(flags : Nat8, flag : Nat8) : Bool { Nat8.toNat(flags) / Nat8.toNat(flag) % 2 == 1 };

  func postingKey(index : Nat) : Blob { RI.key([be(index, POSTING_KEY_BYTES)], POSTING_KEY_BYTES) };

  func correctorKey(index : Nat, seq : Nat) : Blob {
    RI.key([be(index, 8), be(seq, 4)], CORRECTOR_KEY_BYTES)
  };

  /// A principal is at most 29 bytes, so it fits a length byte and a fixed field.
  func callerBytes(p : Principal) : [Nat8] {
    let b = Blob.toArray(Principal.toBlob(p));
    if (b.size() > 29) Runtime.trap("JournalCore: a principal of " # Nat.toText(b.size()) # " bytes");
    Array.tabulate<Nat8>(30, func(i) { if (i == 0) Nat8.fromNat(b.size()) else if (i <= b.size()) b[i - 1] else 0 })
  };

  func callerOf(a : [Nat8], from : Nat) : Principal {
    let n = Nat8.toNat(a[from]);
    Principal.fromBlob(Blob.fromArray(Array.tabulate<Nat8>(n, func(i) { a[from + 1 + i] })))
  };

  /// The row's bytes, with the resolution's period left at ordinal zero: assigning an ordinal needs the
  /// state's table, so `putRow` patches those four bytes in. Splitting it this way keeps the layout in
  /// one function rather than two that have to agree.
  func encodeRow(r : PostingRow) : Blob {
    let res = switch (r.resolution) {
      case (?x) x;
      case null { { postingDate = 0; valueDate = 0; valueDateRequested = null; period = "" } };
    };
    RI.key(
      [
        [r.status],
        [r.flags],
        be(switch (r.reversedBy) { case (?x) x; case null 0 }, 8),
        be(Nat64.toNat(switch (r.expiresAt) { case (?x) x; case null 0 }), 8),
        be(r.resolvedBy, 8),
        be(res.postingDate, 4),
        be(res.valueDate, 4),
        be(switch (res.valueDateRequested) { case (?x) x; case null 0 }, 4),
        be(0, 4),
        be(r.correctors, 4),
        be(Nat64.toNat(r.timestamp), 8),
        callerBytes(r.caller),
      ],
      POSTING_ROW_BYTES,
    )
  };

  /// The row, with the period resolved from its ordinal. `state` is needed only for that table.
  func decodeRow(state : State, b : Blob) : PostingRow {
    let a = Blob.toArray(b);
    let status = a[0];
    let flags = a[1];
    let resolution : ?T.Resolution =
      if (status == STATUS_FROM_PENDING) {
        ?{
          postingDate = beNat(a, 26, 4);
          valueDate = beNat(a, 30, 4);
          valueDateRequested = if (hasFlag(flags, FLAG_VDR)) ?beNat(a, 34, 4) else null;
          period = periodOfOrdinal(state, beNat(a, 38, 4));
        }
      } else null;
    {
      status;
      flags;
      reversedBy = if (hasFlag(flags, FLAG_REVERSED)) ?beNat(a, 2, 8) else null;
      expiresAt = if (hasFlag(flags, FLAG_EXPIRES)) ?Nat64.fromNat(beNat(a, 10, 8)) else null;
      resolvedBy = beNat(a, 18, 8);
      resolution;
      correctors = beNat(a, 42, 4);
      timestamp = Nat64.fromNat(beNat(a, 46, 8));
      caller = callerOf(a, 54);
    }
  };

  /// The row of one posting, or null when there is no such posting. One B-tree descent.
  public func postingRow(state : State, index : Nat) : ?PostingRow {
    switch (RI.get(state.postingRows, postingKey(index))) {
      case (?v) ?decodeRow(state, v);
      case null null;
    }
  };

  func putRow(state : State, index : Nat, r : PostingRow, resolutionPeriod : ?T.PeriodId) {
    // The resolution's period is written as an ordinal, which `encodeRow` cannot assign because it has
    // no state; so it is patched in here, where the table is reachable.
    let base = Blob.toArray(encodeRow(r));
    let ord = switch (resolutionPeriod) { case (?id) periodOrdinal(state, id); case null 0 };
    let ordBytes = be(ord, 4);
    let patched = Array.tabulate<Nat8>(base.size(), func(i) {
      if (i >= 38 and i < 42) ordBytes[i - 38] else base[i]
    });
    if (putDroppable(state, #rows, postingKey(index), Blob.fromArray(patched)) == null) {
      state.postingRowCount += 1;
    };
  };

  // ─── the five per-posting indexes an archive roll drops from ────────────────

  public type Droppable = { #rows; #correctors; #periodPostings; #valueDated; #postingDated };
  public let DROPPABLES : [Droppable] = [#rows, #correctors, #periodPostings, #valueDated, #postingDated];

  func droppable(state : State, which : Droppable) : RI.State {
    switch (which) { case (#rows) state.postingRows; case (#correctors) state.correctors; case (#periodPostings) state.periodPostingIndex; case (#valueDated) state.valueDatedIndex; case (#postingDated) state.postingDatedIndex }
  };
  func setDroppable(state : State, which : Droppable, idx : RI.State) {
    switch (which) { case (#rows) state.postingRows := idx; case (#correctors) state.correctors := idx; case (#periodPostings) state.periodPostingIndex := idx; case (#valueDated) state.valueDatedIndex := idx; case (#postingDated) state.postingDatedIndex := idx }
  };

  /// Which rows stay across an archive roll. A posting row leaves when its posting is at or below
  /// the boundary unless it is still a pending (the roll is refused while one is, so this is the
  /// invariant's own guard); a corrector or period entry follows its posting; a dated row at or
  /// before the period's end is added into the one row at the period's end for its (account,
  /// currency, sub-ledger); so a balance as of any later day still sums to the same figure.
  func keepAcrossRoll(state : State, which : Droppable, hi : Nat, periodEnd : Nat, target : RI.State) : (Blob, Blob) -> Bool {
    func(k : Blob, v : Blob) : Bool {
      let a = Blob.toArray(k);
      switch (which) {
        case (#rows) { beNat(a, 0, POSTING_KEY_BYTES) > hi or decodeRowStatus(v) == STATUS_PENDING };
        case (#correctors) beNat(a, 0, 8) > hi;
        case (#periodPostings) beNat(a, 4, 8) > hi;
        case (_) {
          let day = beNat(a, DATED_DAY_OFFSET, 4);
          if (day > periodEnd) return true;
          let b = Blob.toArray(v);
          let k2 = RI.key([Array.tabulate<Nat8>(DATED_DAY_OFFSET, func(i) { a[i] }), be(periodEnd, 4)], DATED_KEY_BYTES);
          let (d0, c0) = switch (RI.get(target, k2)) { case (?x) { let xa = Blob.toArray(x); (beNat(xa, 0, 8), beNat(xa, 8, 8)) }; case null (0, 0) };
          ignore RI.put(target, k2, RI.key([be(d0 + beNat(b, 0, 8), 8), be(c0 + beNat(b, 8, 8), 8)], DATED_VAL_BYTES));
          ignore state;
          false
        };
      }
    }
  };

  func decodeRowStatus(v : Blob) : Nat8 { Blob.toArray(v)[0] };

  /// Every write to one of the five goes through here: the current index always, the rebuild's
  /// target when that index is the one being rebuilt and the copy has passed the key.
  func putDroppable(state : State, which : Droppable, k : Blob, v : Blob) : ?Blob {
    let previous = RI.put(droppable(state, which), k, v);
    switch (state.archiveDrop) {
      case (?d) { if (d.which == which) RB.mirror(d.job, k, v, keepAcrossRoll(state, which, d.hi, d.periodEnd, d.job.target)) };
      case null {};
    };
    previous
  };

  /// Start dropping the archived range from one index. Refused while another drop is in progress.
  public func beginArchiveDrop(state : State, which : Droppable, hi : Nat, periodEnd : Nat) : Bool {
    switch (state.archiveDrop) { case (?_) return false; case null {} };
    state.archiveDrop := ?{ which; job = RB.start(droppable(state, which)); hi; periodEnd };
    true
  };

  public func stepArchiveDrop(state : State, limit : Nat) : { examined : Nat; done : Bool } {
    let ?d = state.archiveDrop else return { examined = 0; done = true };
    let n = RB.step(d.job, keepAcrossRoll(state, d.which, d.hi, d.periodEnd, d.job.target), limit);
    { examined = n; done = d.job.done }
  };

  public func finishArchiveDrop(state : State) : ?{ which : Droppable; copied : Nat; dropped : Nat } {
    let ?d = state.archiveDrop else return null;
    if (not d.job.done) return null;
    setDroppable(state, d.which, RB.finish(d.job));
    switch (d.which) {
      case (#rows) state.postingRowCount := RI.size(state.postingRows);
      case (#valueDated) { if (d.periodEnd > state.datedRolledUpThrough) state.datedRolledUpThrough := d.periodEnd };
      case (_) {};
    };
    state.archiveDrop := null;
    ?{ which = d.which; copied = d.job.copied; dropped = d.job.dropped }
  };

  public func archiveDropInProgress(state : State) : ?{ which : Droppable; done : Bool } {
    switch (state.archiveDrop) { case (?d) ?{ which = d.which; done = d.job.done }; case null null }
  };

  public func droppableText(w : Droppable) : Text {
    switch (w) { case (#rows) "rows"; case (#correctors) "correctors"; case (#periodPostings) "periodPostings"; case (#valueDated) "valueDated"; case (#postingDated) "postingDated" }
  };

  public func datedRolledUpThrough(state : State) : Nat { state.datedRolledUpThrough };

  /// The oldest open pending, if any: an archive roll may not take a range that still holds one,
  /// because its record would leave with the block while its resolution is still to come.
  public func oldestOpenPending(state : State) : ?Nat {
    var best : ?Nat = null;
    for ((i, _) in Map.entries(state.openPendings)) { switch (best) { case (?b) { if (i < b) best := ?i }; case null best := ?i } };
    best
  };

  /// Give every index's pages back to the arena: what a shadow fold does when it is finished with.
  public func releaseIndexes(state : State) {
    RI.release(state.valueDatedIndex); RI.release(state.postingDatedIndex); RI.release(state.periodPostingIndex);
    RI.release(state.postingRows); RI.release(state.correctors); RI.release(state.idempotencyIndex);
  };

  func statusOfRow(state : State, r : PostingRow) : T.PostingStatus {
    // `state` is unused today and is taken anyway: every other row reader needs it for the period
    // table, and a signature that differs only here is the kind of asymmetry that later grows a bug.
    ignore state;
    if (r.status == STATUS_POSTED) #posted
    else if (r.status == STATUS_PENDING) #pending({ expiresAt = r.expiresAt })
    else if (r.status == STATUS_FROM_PENDING) {
      switch (r.resolution) {
        case (?res) #postedFromPending({ by = r.resolvedBy; resolution = res });
        case null Runtime.trap("JournalCore: a postedFromPending row with no resolution");
      }
    } else #voided({
      by = r.resolvedBy;
      reason = if (hasFlag(r.flags, FLAG_EXPIRED_REASON)) #expired else #requested;
    })
  };

  /// A posting's status, without reading its record.
  public func postingStatus(state : State, index : Nat) : ?T.PostingStatus {
    switch (postingRow(state, index)) { case (?r) ?statusOfRow(state, r); case null null }
  };

  func correctorsOf(state : State, index : Nat, count : Nat) : [Nat] {
    if (count == 0) return [];
    let out = List.empty<Nat>();
    var seq = 0;
    while (seq < count) {
      switch (RI.get(state.correctors, correctorKey(index, seq))) {
        case (?v) List.add(out, beNat(Blob.toArray(v), 0, 8));
        case null {};
      };
      seq += 1;
    };
    List.toArray(out)
  };

  /// Everything about one posting: the row, and the record read back from the block log.
  ///
  /// Returns null when there is no such posting; **traps** when the row exists but the block does not,
  /// because that means the journal's own state and its log disagree, and answering with a partial
  /// posting would hide it.
  public func postingMeta(state : State, blocks : Blocks, index : Nat) : ?PostingMeta {
    let ?r = postingRow(state, index) else return null;
    let ?block = blocks.get(index) else Runtime.trap(
      "JournalCore: posting " # Nat.toText(index) # " has a row but no block in the log"
    );
    let record = switch (block.event) {
      case (#posted(rec)) rec;
      case (#pending(x)) x.record;
      case (_) Runtime.trap("JournalCore: block " # Nat.toText(index) # " has a posting row but is not a posting");
    };
    let effective : ?T.Resolution =
      if (r.status == STATUS_POSTED) {
        ?{ postingDate = record.postingDate; valueDate = record.valueDate; valueDateRequested = record.valueDateRequested; period = record.period }
      } else r.resolution;
    ?{
      index;
      timestamp = r.timestamp;
      caller = r.caller;
      record;
      status = statusOfRow(state, r);
      reversedBy = r.reversedBy;
      correctedBy = correctorsOf(state, index, r.correctors);
      effective;
    }
  };

  /// The record alone. The commonest need, and the one that says plainly where a record comes from.
  func loggedRecord(blocks : Blocks, index : Nat) : T.PostingRecord {
    let ?block = blocks.get(index) else Runtime.trap(
      "JournalCore: posting " # Nat.toText(index) # " is not in the log"
    );
    switch (block.event) {
      case (#posted(rec)) rec;
      case (#pending(x)) x.record;
      case (_) Runtime.trap("JournalCore: block " # Nat.toText(index) # " is not a posting");
    }
  };

  public func postingCount(state : State) : Nat { state.postingRowCount };

  // ─── the duplicate-rejection index ────────────────────────────────────────

  func encodeIdem(e : IdemEntry) : Blob {
    let h = Blob.toArray(e.contentHash);
    if (h.size() != 32) Runtime.trap("JournalCore: a content hash of " # Nat.toText(h.size()) # " bytes");
    RI.key([be(e.index, 8), [switch (e.kind) { case (#immediate) 0 : Nat8; case (#pending) 1 : Nat8 }], h], IDEM_VAL_BYTES)
  };

  func decodeIdem(b : Blob) : IdemEntry {
    let a = Blob.toArray(b);
    {
      index = beNat(a, 0, 8);
      kind = if (a[8] == 0) #immediate else #pending;
      contentHash = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { a[9 + i] }));
    }
  };

  func idemOf(state : State, scope : Blob) : ?IdemEntry {
    switch (RI.get(state.idempotencyIndex, scope)) { case (?v) ?decodeIdem(v); case null null }
  };

  public func idempotencyCount(state : State) : Nat { state.idempotencyCount };

  // ─── a period's posted postings ───────────────────────────────────────────

  func periodPostingKey(state : State, period : T.PeriodId, index : Nat) : Blob {
    RI.key([be(periodOrdinal(state, period), 4), be(index, 8)], PERIOD_POSTING_KEY_BYTES)
  };

  func periodPostingEnds(state : State, period : T.PeriodId) : (Blob, Blob) {
    let ord = be(periodOrdinal(state, period), 4);
    (
      RI.key([ord], PERIOD_POSTING_KEY_BYTES),
      RI.key([ord, [255, 255, 255, 255, 255, 255, 255, 255] : [Nat8]], PERIOD_POSTING_KEY_BYTES),
    )
  };

  public func periodPostingCount(state : State, period : T.PeriodId) : Nat {
    switch (Map.get(state.periodPostingCounts, Text.compare, period)) { case (?n) n; case null 0 }
  };

  // ─── value-dated and posting-dated accumulators ───────────────────────────

  func accountOrdinal(state : State, code : T.AccountCode) : Nat {
    switch (Map.get(state.accountOrdinals, Text.compare, code)) {
      case (?o) o;
      case null {
        let o = state.nextAccountOrdinal;
        state.nextAccountOrdinal += 1;
        Map.add(state.accountOrdinals, Text.compare, code, o);
        Map.add(state.accountNames, Nat.compare, o, code);
        o
      };
    }
  };

  func knownAccountOrdinal(state : State, code : T.AccountCode) : ?Nat {
    Map.get(state.accountOrdinals, Text.compare, code)
  };

  func accountOfOrdinal(state : State, o : Nat) : T.AccountCode {
    switch (Map.get(state.accountNames, Nat.compare, o)) {
      case (?c) c;
      case null Runtime.trap("JournalCore: account ordinal " # Nat.toText(o) # " has no code");
    }
  };

  func currencyOrdinal(state : State, code : T.Currency) : Nat {
    switch (Map.get(state.currencyOrdinals, Text.compare, code)) {
      case (?o) o;
      case null {
        let o = state.nextCurrencyOrdinal;
        state.nextCurrencyOrdinal += 1;
        Map.add(state.currencyOrdinals, Text.compare, code, o);
        o
      };
    }
  };

  func knownCurrencyOrdinal(state : State, code : T.Currency) : ?Nat {
    Map.get(state.currencyOrdinals, Text.compare, code)
  };

  func subBytes(sub : Blob) : [Nat8] {
    let a = Blob.toArray(sub);
    // The general-ledger-only case is the empty sub-ledger key, which pads to zeros and so sorts first
    // within its account and currency; where a reader looking for "the account itself" expects it.
    //
    // A key wider than the journal's own bound cannot be stored, and trapping is right: admission has
    // already refused anything wider (`#SubledgerKeyInvalid`), so reaching here means state and
    // validation disagree.
    if (a.size() > T.MAX_SUBLEDGER_BYTES) Runtime.trap("JournalCore: a sub-ledger key of " # Nat.toText(a.size()) # " bytes");
    Array.tabulate<Nat8>(T.MAX_SUBLEDGER_BYTES, func(i) { if (i < a.size()) a[i] else 0 })
  };

  /// The same key from parts already computed. The two dated indexes are written for every leg, and
  /// padding the sub-ledger key to its 64 bytes twice a leg is allocation for nothing: the padded bytes
  /// and the two ordinals are the same for both. This is not micro-optimisation of a hot loop nobody
  /// measured; it was measured, and it is per posting, for ever.
  func datedKeyFrom(acctOrd : Nat, ccyOrd : Nat, subPadded : [Nat8], day : T.Day) : Blob {
    RI.key([be(acctOrd, 4), be(ccyOrd, 4), subPadded, be(day, 4)], DATED_KEY_BYTES)
  };

  /// The ends of the run a balance question covers. `subledger = null` asks for the account summed
  /// across its sub-ledgers, which is this account and currency's whole run; a named sub-ledger is the
  /// narrower run inside it. Either way the days run to `asOf`, which is the last key part.
  func datedEnds(state : State, account : T.AccountCode, sub : ?Blob, ccy : T.Currency, asOf : T.Day) : ?(Blob, Blob) {
    let ?aOrd = knownAccountOrdinal(state, account) else return null;
    let ?cOrd = knownCurrencyOrdinal(state, ccy) else return null;
    let prefix = [be(aOrd, 4), be(cOrd, 4)];
    switch (sub) {
      case (?k) {
        ?(
          RI.key([be(aOrd, 4), be(cOrd, 4), subBytes(k)], DATED_KEY_BYTES),
          RI.key([be(aOrd, 4), be(cOrd, 4), subBytes(k), be(asOf, 4)], DATED_KEY_BYTES),
        )
      };
      case null {
        // Every sub-ledger, so the run is the whole (account, currency) range and the day bound is
        // applied while walking; the day is after the sub-ledger in the key, so it cannot bound the
        // range itself.
        let (lo, hi) = RI.rangeEnds(prefix, DATED_KEY_BYTES);
        ?(lo, hi)
      };
    }
  };

  func datedAdd(state : State, which : Droppable, k : Blob, dr : Nat, cr : Nat) {
    let index = droppable(state, which);
    let (d0, c0) = switch (RI.get(index, k)) {
      case (?v) { let a = Blob.toArray(v); (beNat(a, 0, 8), beNat(a, 8, 8)) };
      case null (0, 0);
    };
    ignore putDroppable(state, which, k, RI.key([be(d0 + dr, 8), be(c0 + cr, 8)], DATED_VAL_BYTES));
  };

  /// Sum one of the dated indexes over a balance question. `subledger = null` walks the account's whole
  /// run and filters the day while walking; a named sub-ledger's run is bounded by the key itself.
  func datedSum(state : State, index : RI.State, account : T.AccountCode, subledger : ?T.SubledgerKey, ccy : T.Currency, asOf : T.Day) : { debits : Nat; credits : Nat } {
    let ?(lo, hi) = datedEnds(state, account, subledger, ccy, asOf) else return { debits = 0; credits = 0 };
    var dr = 0;
    var cr = 0;
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(index, lo, hi, cursor, 500);
      for ((k, v) in page.entries.vals()) {
        let a = Blob.toArray(k);
        let day = beNat(a, DATED_DAY_OFFSET, 4);
        if (day <= asOf) {
          let b = Blob.toArray(v);
          dr += beNat(b, 0, 8);
          cr += beNat(b, 8, 8);
        };
      };
      switch (page.cursor) { case (?c) { cursor := ?c }; case null break walk };
    };
    { debits = dr; credits = cr }
  };

  // ─── key comparators ──────────────────────────────────────────────────────

  func cmp2(a : (Text, Text), b : (Text, Text)) : Order.Order {
    switch (Text.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o }
  };
  func cmp3(a : (Text, Text, Text), b : (Text, Text, Text)) : Order.Order {
    switch (Text.compare(a.0, b.0)) {
      case (#equal) { switch (Text.compare(a.1, b.1)) { case (#equal) Text.compare(a.2, b.2); case (o) o } };
      case (o) o;
    }
  };
  /// Balance key: (account, sub-ledger key or the empty blob, currency).
  func cmpBal(a : (Text, Blob, Text), b : (Text, Blob, Text)) : Order.Order {
    switch (Text.compare(a.0, b.0)) {
      case (#equal) { switch (Blob.compare(a.1, b.1)) { case (#equal) Text.compare(a.2, b.2); case (o) o } };
      case (o) o;
    }
  };
  public func accountAttributes(state : State, code : T.AccountCode) : T.AccountAttributes {
    switch (Map.get(state.accountAttributes, Text.compare, code)) { case (?a) a; case null T.DEFAULT_ACCOUNT_ATTRIBUTES }
  };

  public func listBalanceLimits(state : State) : [((Text, Blob, Text), T.BalanceLimit)] { Map.toArray(state.balanceLimits) };

  /// Refuse a posting whose legs name an account outside the caller's recorded
  /// scope. An unrestricted poster (no recorded scope) is unaffected, which is
  /// why every journal written before scopes existed behaves identically.
  public func checkPosterScope(state : State, caller : Principal, legs : [T.Leg]) : ?T.PostError {
    let ?allowed = Map.get(state.posterScopes, Principal.compare, caller) else return null;
    for (l in legs.vals()) {
      var ok = false;
      for (a in allowed.vals()) { if (Text.equal(a, l.account)) ok := true };
      if (not ok) return ?#PosterNotScopedForAccount({ poster = caller; account = l.account });
    };
    null
  };
  public func isActive(state : State) : Bool { state.activationHeight <= Nat64.fromNat(state.height) };
  public func height(state : State) : Nat { state.height };

  /// The accounting "today": the business date once one has been rolled,
  /// otherwise the day of the canister clock.
  func today(state : State, now : Nat64) : T.Day {
    switch (state.businessDate) { case (?d) d; case null CivilDate.fromNanos(Nat64.toNat(now)) }
  };
  public func effectiveToday(state : State, now : Nat64) : T.Day { today(state, now) };

  func calendarOf(c : T.CalendarConfig) : Calendar.Calendar { { restDays = c.restDays; holidays = c.holidays } };

  /// Apply the working-day calendar to a value date: the effective date and
  /// the requested one when it moved; a typed error under the reject policy.
  public func shiftValueDate(state : State, valueDate : T.Day) : Result.Result<(T.Day, ?T.Day), T.PostError> {
    switch (state.calendar) {
      case null #ok((valueDate, null));
      case (?c) {
        switch (Calendar.apply(calendarOf(c), c.policy, valueDate)) {
          case (#ok(null)) #ok((valueDate, null));
          case (#ok(?s)) #ok((s.effective, ?s.requested));
          case (#err(_)) #err(#ValueDateNotBusinessDay({ valueDate }));
        }
      };
    }
  };

  func isUpperAlnum(c : Char) : Bool { (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') };
  func isPeriodChar(c : Char) : Bool {
    (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_'
  };

  public func validateCurrencyCode(code : Text) : ?Text {
    let cs = Text.toArray(code);
    if (cs.size() < 2 or cs.size() > 8) return ?"currency code must be 2 to 8 characters";
    for (c in cs.vals()) { if (not isUpperAlnum(c)) return ?"currency code must be upper-case ASCII letters or digits" };
    null
  };

  public func validatePeriodId(id : Text) : ?Text {
    let cs = Text.toArray(id);
    if (cs.size() < 1 or cs.size() > T.MAX_PERIOD_ID_BYTES) return ?"period id must be 1 to 16 characters";
    for (c in cs.vals()) { if (not isPeriodChar(c)) return ?"period id may contain only ASCII letters, digits, '-' and '_'" };
    null
  };

  // ═══════════════════════════════════════════════════════
  //  ADMISSION; financial events
  // ═══════════════════════════════════════════════════════

  public type Prepared = { #event : T.Event; #duplicate : Nat };

  type PostArgs = {
    caller : Principal;
    now : Nat64;
    record : T.PostingRecord;
    kind : SubmissionKind;
    expiresAt : ?Nat64;
  };

  func gate(state : State, caller : Principal) : ?T.PostError {
    if (Principal.isAnonymous(caller)) return ?#AnonymousCaller;
    if (not isPoster(state, caller)) return ?#Unauthorized;
    if (not isActive(state)) return ?#NotActivated({ activationHeight = state.activationHeight; height = Nat64.fromNat(state.height) });
    null
  };

  /// Batch-local accumulator of (debits, credits) already admitted for an
  /// (account, currency) earlier in the same batch, so that limits are
  /// checked against the state the batch will produce.
  public type Deltas = Map.Map<(Text, Blob, Text), Acc>;
  public func newDeltas() : Deltas { Map.empty<(Text, Blob, Text), Acc>() };

  func deltaOf(d : Deltas, account : Text, sub : Blob, ccy : Text) : Acc {
    switch (Map.get(d, cmpBal, (account, sub, ccy))) {
      case (?a) a;
      case null { let a : Acc = { var dr = 0; var cr = 0 }; Map.add(d, cmpBal, (account, sub, ccy), a); a };
    }
  };

  /// Record the legs of an admitted posting in the accumulator.
  public func accumulate(d : Deltas, legs : [T.Leg]) {
    for (l in legs.vals()) {
      let a = deltaOf(d, l.account, subKey(l.subledger), l.currency);
      switch (l.side) { case (#debit) a.dr += l.amount; case (#credit) a.cr += l.amount };
    };
  };

  /// L4: engine-enforced limits, over posted + pending + amounts admitted
  /// earlier in this batch + earlier legs of this posting.
  func checkConstraints(state : State, legs : [T.Leg], d : Deltas) : ?T.PostError {
    let local = newDeltas();
    for (l in legs.vals()) {
      let ?a = Map.get(state.accounts, Text.compare, l.account) else return ?#UnknownAccount({ account = l.account });
      let sub = subKey(l.subledger);
      let b = switch (Map.get(state.balances, cmpBal, (l.account, sub, l.currency))) {
        case (?b) b;
        case null { { var drPosted = 0; var crPosted = 0; var drPending = 0; var crPending = 0 } : Bal };
      };
      let batch = deltaOf(d, l.account, sub, l.currency);
      let here = deltaOf(local, l.account, sub, l.currency);
      // A recorded numeric limit for this (account, sub-ledger, currency)
      // overrides the account's own constraint: `#debitsNotExceedCreditsPlus n`
      // is the same rule with an allowance of n, which is what an overdraft
      // facility and a net debit cap are. `#none` recorded explicitly lifts the
      // account's constraint for this sub-ledger.
      let (rule, allowance) = switch (Map.get(state.balanceLimits, cmpBal, (l.account, sub, l.currency))) {
        case (?#debitsNotExceedCreditsPlus(n)) (#debitsNotExceedCredits, n);
        case (?#creditsNotExceedDebitsPlus(n)) (#creditsNotExceedDebits, n);
        case (?#none) (#none, 0);
        case null (a.constraint, 0);
      };
      switch (rule, l.side) {
        case (#debitsNotExceedCredits, #debit) {
          let debits = b.drPosted + b.drPending + batch.dr + here.dr;
          let credits = b.crPosted + batch.cr + here.cr;
          if (debits + l.amount > credits + allowance) {
            return ?#ExceedsCredits({ account = l.account; subledger = l.subledger; currency = l.currency; debitsPosted = b.drPosted; debitsPending = b.drPending + batch.dr + here.dr; creditsPosted = credits; amount = l.amount; allowance });
          };
        };
        case (#creditsNotExceedDebits, #credit) {
          let credits = b.crPosted + b.crPending + batch.cr + here.cr;
          let debits = b.drPosted + batch.dr + here.dr;
          if (credits + l.amount > debits + allowance) {
            return ?#ExceedsDebits({ account = l.account; subledger = l.subledger; currency = l.currency; creditsPosted = b.crPosted; creditsPending = b.crPending + batch.cr + here.cr; debitsPosted = debits; amount = l.amount; allowance });
          };
        };
        case _ {};
      };
      switch (l.side) { case (#debit) here.dr += l.amount; case (#credit) here.cr += l.amount };
    };
    null
  };

  func isManualSource(kind : Text) : Bool {
    for (k in T.MANUAL_SOURCE_KINDS.vals()) { if (Text.equal(k, kind)) return true };
    false
  };

  /// Validate a posting record against the current state. Pure.
  public func subKey(sub : ?Blob) : Blob { switch (sub) { case (?b) b; case null ("" : Blob) } };

  // ═══════════════════════════════════════════════════════
  //  PREDICATES
  // ═══════════════════════════════════════════════════════

  public func isAdmin(state : State, p : Principal) : Bool { Principal.equal(state.admin, p) };
  public func isPoster(state : State, p : Principal) : Bool { Map.containsKey(state.posters, Principal.compare, p) };
  /// The accounts this poster is restricted to, or null when unrestricted.
  public func posterScope(state : State, p : Principal) : ?T.PosterScope { Map.get(state.posterScopes, Principal.compare, p) };

  /// The recorded numeric limit for one (account, sub-ledger, currency), if any.
  public func balanceLimit(state : State, account : T.AccountCode, sub : ?T.SubledgerKey, ccy : T.Currency) : ?T.BalanceLimit {
    Map.get(state.balanceLimits, cmpBal, (account, subKey(sub), ccy))
  };

  func validateRecord(state : State, now : Nat64, r : T.PostingRecord, d : Deltas) : ?T.PostError {
    // key and text limits
    let ks = r.idempotencyKey.size();
    if (ks == 0 or ks > T.MAX_IDEMPOTENCY_KEY_BYTES) return ?#IdempotencyKeyInvalid({ size = ks });
    let ns = Text.encodeUtf8(r.narration).size();
    if (ns > T.MAX_NARRATION_BYTES) return ?#NarrationTooLong({ size = ns; max = T.MAX_NARRATION_BYTES });
    let kindSize = Text.encodeUtf8(r.sourceRef.kind).size();
    if (kindSize == 0) return ?#SourceRefInvalid({ reason = "source kind is empty" });
    if (kindSize > T.MAX_SOURCE_KIND_BYTES) return ?#SourceRefInvalid({ reason = "source kind exceeds 32 bytes" });
    if (Text.encodeUtf8(r.sourceRef.id).size() > T.MAX_SOURCE_ID_BYTES) return ?#SourceRefInvalid({ reason = "source id exceeds 128 bytes" });
    // legs
    let n = r.legs.size();
    if (n < 2) return ?#TooFewLegs({ count = n });
    if (n > T.MAX_LEGS) return ?#TooManyLegs({ count = n; max = T.MAX_LEGS });
    var i = 0;
    while (i < n) {
      let leg = r.legs[i];
      if (leg.amount == 0) return ?#ZeroAmountLeg({ index = i });
      switch (leg.subledger) {
        case (?k) { if (k.size() == 0 or k.size() > T.MAX_SUBLEDGER_BYTES) return ?#SubledgerKeyInvalid({ index = i; size = k.size() }) };
        case null {};
      };
      switch (Map.get(state.accounts, Text.compare, leg.account)) {
        case null return ?#UnknownAccount({ account = leg.account });
        case (?a) { if (a.status == #closed) return ?#AccountClosed({ account = leg.account }) };
      };
      // Chart-of-accounts attributes: a header account is a
      // rollup and is never posted to, and an account that does not allow manual
      // entries refuses a posting whose source kind is a manual correction.
      let attrs = accountAttributes(state, leg.account);
      if (attrs.usage == #header) return ?#AccountIsHeader({ account = leg.account });
      if (not attrs.manualEntriesAllowed and isManualSource(r.sourceRef.kind)) {
        return ?#ManualEntriesNotAllowed({ account = leg.account });
      };
      if (not Map.containsKey(state.currencies, Text.compare, leg.currency)) return ?#UnknownCurrency({ currency = leg.currency });
      i += 1;
    };
    // INV-J1: per currency, debits == credits
    switch (unbalancedCurrency(r.legs)) {
      case (?u) return ?#Unbalanced(u);
      case null {};
    };
    // L4: per-account limits
    switch (checkConstraints(state, r.legs, d)) {
      case (?e) return ?e;
      case null {};
    };
    // period and dates
    switch (validateBooking(state, now, r.postingDate, r.valueDate, r.period)) {
      case (?e) return ?e;
      case null {};
    };
    // relation target
    switch (r.relation) {
      case null {};
      case (?rel) {
        switch (postingRow(state, rel.original)) {
          case null return ?#UnknownPosting({ index = rel.original });
          case (?row) {
            // The row alone answers this: no record is read, so validating a relation costs one B-tree
            // descent rather than a heap map holding every posting.
            switch (statusOfRow(state, row)) {
              case (#posted) {};
              case (#postedFromPending(_)) {};
              case (_) return ?#NotAPosting({ index = rel.original });
            };
            if (rel.kind == #reversal) {
              switch (row.reversedBy) {
                case (?by) return ?#AlreadyReversed({ original = rel.original; reversedBy = by });
                case null {};
              };
            };
          };
        };
      };
    };
    null
  };

  /// The first currency whose debits differ from its credits, with both sums.
  public func unbalancedCurrency(legs : [T.Leg]) : ?{ currency : T.Currency; debits : Nat; credits : Nat } {
    let sums = Map.empty<Text, Acc>();
    for (l in legs.vals()) {
      let acc = switch (Map.get(sums, Text.compare, l.currency)) {
        case (?a) a;
        case null { let a : Acc = { var dr = 0; var cr = 0 }; Map.add(sums, Text.compare, l.currency, a); a };
      };
      switch (l.side) { case (#debit) acc.dr += l.amount; case (#credit) acc.cr += l.amount };
    };
    for ((ccy, acc) in Map.entries(sums)) {
      if (acc.dr != acc.cr) return ?{ currency = ccy; debits = acc.dr; credits = acc.cr };
    };
    null
  };

  func validateBooking(state : State, now : Nat64, postingDate : T.Day, valueDate : T.Day, period : T.PeriodId) : ?T.PostError {
    let ?p = Map.get(state.periods, Text.compare, period) else return ?#UnknownPeriod({ period });
    if (p.status == #closed) return ?#PeriodClosed({ period });
    if (postingDate < p.start or postingDate > p.end) {
      return ?#PostingDateOutsidePeriod({ period; postingDate; start = p.start; end = p.end });
    };
    let t = today(state, now);
    if (postingDate > t) return ?#PostingDateInFuture({ postingDate; today = t });
    if (CivilDate.distance(valueDate, postingDate) > T.MAX_VALUE_DATE_DRIFT_DAYS) {
      return ?#ValueDateTooFar({ valueDate; postingDate; maxDriftDays = T.MAX_VALUE_DATE_DRIFT_DAYS });
    };
    null
  };

  func checkIdempotency(state : State, caller : Principal, r : T.PostingRecord, kind : SubmissionKind) : Result.Result<?Nat, T.PostError> {
    let scope = C.idempotencyScopeKey(caller, r.idempotencyKey);
    switch (idemOf(state, scope)) {
      case null #ok(null);
      case (?e) {
        if (e.kind == kind and e.contentHash == C.postingContentHash(r)) #ok(?e.index)
        else #err(#IdempotencyKeyReused({ existing = e.index }))
      };
    }
  };

  func prepare(state : State, a : PostArgs) : Result.Result<Prepared, T.PostError> {
    prepareWith(state, a, newDeltas())
  };

  func prepareWith(state : State, a0 : PostArgs, d : Deltas) : Result.Result<Prepared, T.PostError> {
    switch (gate(state, a0.caller)) { case (?e) return #err(e); case null {} };
    switch (checkPosterScope(state, a0.caller, a0.record.legs)) { case (?e) return #err(e); case null {} };
    // working-day calendar: the value date may move; the requested date is recorded
    let a : PostArgs = switch (shiftValueDate(state, a0.record.valueDate)) {
      case (#err(e)) return #err(e);
      case (#ok((eff, req))) { { a0 with record = { a0.record with valueDate = eff; valueDateRequested = req } } };
    };
    switch (validateRecord(state, a.now, a.record, d)) { case (?e) return #err(e); case null {} };
    switch (a.expiresAt) {
      case (?x) { if (x <= a.now) return #err(#ExpiryInPast({ expiresAt = x; now = a.now })) };
      case null {};
    };
    switch (checkIdempotency(state, a.caller, a.record, a.kind)) {
      case (#err(e)) #err(e);
      case (#ok(?existing)) #ok(#duplicate(existing));
      case (#ok(null)) {
        switch (a.kind) {
          case (#immediate) #ok(#event(#posted(a.record)));
          case (#pending) #ok(#event(#pending({ record = a.record; expiresAt = a.expiresAt })));
        }
      };
    }
  };

  func recordOf(input : T.PostingInput) : T.PostingRecord {
    {
      idempotencyKey = input.idempotencyKey;
      postingDate = input.postingDate;
      valueDate = input.valueDate;
      period = input.period;
      legs = input.legs;
      sourceRef = input.sourceRef;
      narration = input.narration;
      relation = switch (input.correctionOf) { case (?o) ?{ original = o; kind = #correction }; case null null };
      valueDateRequested = null;
    }
  };

  /// A posting against the business date: posting and value date are
  /// the business date, the period is the open period containing it.
  public func businessInputOf(state : State, input : T.BusinessPostingInput) : Result.Result<T.PostingInput, T.PostError> {
    let ?bd = state.businessDate else return #err(#NoBusinessDate);
    var period : ?T.PeriodId = null;
    for ((id, p) in Map.entries(state.periods)) {
      if (p.status == #open and p.start <= bd and bd <= p.end) period := ?id;
    };
    let ?pid = period else return #err(#NoOpenPeriodForBusinessDate({ businessDate = bd }));
    #ok({ idempotencyKey = input.idempotencyKey; postingDate = bd; valueDate = bd; period = pid; legs = input.legs; sourceRef = input.sourceRef; narration = input.narration; correctionOf = input.correctionOf })
  };

  public func preparePostAtBusinessDate(state : State, caller : Principal, now : Nat64, input : T.BusinessPostingInput) : Result.Result<Prepared, T.PostError> {
    switch (businessInputOf(state, input)) { case (#err(e)) #err(e); case (#ok(i)) preparePost(state, caller, now, i) }
  };

  /// Admit an immediate posting.
  public func preparePost(state : State, caller : Principal, now : Nat64, input : T.PostingInput) : Result.Result<Prepared, T.PostError> {
    prepare(state, { caller; now; record = recordOf(input); kind = #immediate; expiresAt = null })
  };

  /// Admit a pending (phase-one) posting.
  public func prepareReserve(state : State, caller : Principal, now : Nat64, input : T.PostingInput, expiresAt : ?Nat64) : Result.Result<Prepared, T.PostError> {
    prepare(state, { caller; now; record = recordOf(input); kind = #pending; expiresAt })
  };

  /// L10: admit several postings as one atomic unit. Every posting is validated
  /// against the state the earlier ones will produce (limits accumulate; a key
  /// repeated inside the batch is refused). The first failure names the
  /// offending position and nothing is admitted. Exact duplicates of already
  /// committed postings are returned as `#duplicate`, so a retried batch is
  /// idempotent.
  public func prepareBatch(state : State, caller : Principal, now : Nat64, inputs : [T.PostingInput]) : Result.Result<[Prepared], T.BatchError> {
    if (inputs.size() == 0) return #err({ index = 0; error = #EmptyBatch });
    if (inputs.size() > T.MAX_BATCH) return #err({ index = 0; error = #BatchTooLarge({ count = inputs.size(); max = T.MAX_BATCH }) });
    let d = newDeltas();
    let seen = Map.empty<Blob, Nat>();
    let out = List.empty<Prepared>();
    var i = 0;
    while (i < inputs.size()) {
      let record = recordOf(inputs[i]);
      let scope = C.idempotencyScopeKey(caller, record.idempotencyKey);
      switch (Map.get(seen, Blob.compare, scope)) {
        case (?first) return #err({ index = i; error = #DuplicateKeyInBatch({ first; index = i }) });
        case null Map.add(seen, Blob.compare, scope, i);
      };
      switch (prepareWith(state, { caller; now; record; kind = #immediate; expiresAt = null }, d)) {
        case (#err(e)) return #err({ index = i; error = e });
        case (#ok(p)) {
          switch (p) { case (#event(_)) accumulate(d, record.legs); case (#duplicate(_)) {} };
          List.add(out, p);
        };
      };
      i += 1;
    };
    #ok(List.toArray(out))
  };

  public type ReverseArgs = {
    idempotencyKey : Blob;
    postingDate : T.Day;
    valueDate : T.Day;
    period : T.PeriodId;
    sourceRef : T.SourceRef;
    narration : Text;
  };

  /// Build the exact mirror of a posted posting and admit it as a reversal.
  public func prepareReverse(state : State, blocks : Blocks, caller : Principal, now : Nat64, original : Nat, args : ReverseArgs) : Result.Result<Prepared, T.PostError> {
    switch (gate(state, caller)) { case (?e) return #err(e); case null {} };
    let ?_ = postingRow(state, original) else return #err(#UnknownPosting({ index = original }));
    let original_ = loggedRecord(blocks, original);
    let mirrored = Array.map<T.Leg, T.Leg>(original_.legs, func(l) {
      { l with side = switch (l.side) { case (#debit) #credit; case (#credit) #debit } }
    });
    let record : T.PostingRecord = {
      idempotencyKey = args.idempotencyKey;
      postingDate = args.postingDate;
      valueDate = args.valueDate;
      period = args.period;
      legs = mirrored;
      sourceRef = args.sourceRef;
      narration = args.narration;
      relation = ?{ original; kind = #reversal };
      valueDateRequested = null;
    };
    prepare(state, { caller; now; record; kind = #immediate; expiresAt = null })
  };

  public type PendingOutcome = { #event : T.Event; #expired : { expiresAt : Nat64 } };

  /// The row of a posting that must still be an open pending. No record is read, because every caller
  /// that needs the record fetches it from the log itself and says so.
  func pendingRow(state : State, index : Nat) : Result.Result<PostingRow, T.PostError> {
    let ?row = postingRow(state, index) else return #err(#NotPending({ index }));
    switch (statusOfRow(state, row)) {
      case (#pending(_)) #ok(row);
      case (#postedFromPending(x)) #err(#PendingAlreadyResolved({ index; resolvedBy = x.by }));
      case (#voided(x)) #err(#PendingAlreadyResolved({ index; resolvedBy = x.by }));
      case (#posted) #err(#NotPending({ index }));
    }
  };

  /// Phase two, posted. The event carries the resolution (dates and period) the
  /// posting is booked under. An expired pending is reported as `#expired`; the
  /// caller must commit the corresponding void event.
  public func preparePostPending(state : State, blocks : Blocks, caller : Principal, now : Nat64, index : Nat, override : ?T.Resolution) : Result.Result<PendingOutcome, T.PostError> {
    switch (gate(state, caller)) { case (?e) return #err(e); case null {} };
    let row = switch (pendingRow(state, index)) { case (#ok(r)) r; case (#err(e)) return #err(e) };
    let pendingRecord = loggedRecord(blocks, index);
    switch (checkPosterScope(state, caller, pendingRecord.legs)) { case (?e) return #err(e); case null {} };
    switch (row.expiresAt) {
      case (?x) { if (x <= now) return #ok(#expired({ expiresAt = x })) };
      case null {};
    };
    let resolution : T.Resolution = switch (override) {
      case (?r) {
        switch (shiftValueDate(state, r.valueDate)) {
          case (#err(e)) return #err(e);
          case (#ok((eff, req))) { { r with valueDate = eff; valueDateRequested = req } };
        }
      };
      case null { { postingDate = pendingRecord.postingDate; valueDate = pendingRecord.valueDate; valueDateRequested = pendingRecord.valueDateRequested; period = pendingRecord.period } };
    };
    switch (validateBooking(state, now, resolution.postingDate, resolution.valueDate, resolution.period)) {
      case (?e) return #err(e);
      case null {};
    };
    #ok(#event(#post({ pendingIndex = index; resolution })))
  };

  /// Phase two, voided by request.
  public func prepareVoidPending(state : State, blocks : Blocks, caller : Principal, index : Nat) : Result.Result<T.Event, T.PostError> {
    switch (gate(state, caller)) { case (?e) return #err(e); case null {} };
    switch (pendingRow(state, index)) {
      case (#ok(_)) {
        switch (checkPosterScope(state, caller, loggedRecord(blocks, index).legs)) { case (?e) return #err(e); case null {} };
        #ok(#void({ pendingIndex = index; reason = #requested }))
      };
      case (#err(e)) #err(e);
    }
  };

  /// Void event for an expired pending (used by the expiry sweep and by
  /// preparePostPending's `#expired` path). No authorization: expiry is a fact.
  public func expiryVoidEvent(index : Nat) : T.Event { #void({ pendingIndex = index; reason = #expired }) };

  /// Unresolved pendings whose expiry has passed, oldest first, at most `limit`.
  public func expiredPendings(state : State, now : Nat64, limit : Nat) : [Nat] {
    let out = List.empty<Nat>();
    label scan for ((idx, _) in Map.entries(state.openPendings)) {
      if (List.size(out) >= limit) break scan;
      // The row alone: an expiry sweep never needs a record, and at a million open pendings that is
      // the difference between a bounded sweep and a heap walk.
      switch (postingRow(state, idx)) {
        case (?row) {
          if (row.status == STATUS_PENDING) {
            switch (row.expiresAt) { case (?x) { if (x <= now) List.add(out, idx) }; case null {} };
          };
        };
        case null {};
      };
    };
    List.toArray(out)
  };

  // ═══════════════════════════════════════════════════════
  //  ADMISSION; configuration events (administrator)
  // ═══════════════════════════════════════════════════════

  func adminGate(state : State, caller : Principal) : ?T.ConfigError {
    if (Principal.isAnonymous(caller)) return ?#AnonymousCaller;
    if (not isAdmin(state, caller)) return ?#Unauthorized;
    null
  };

  public func prepareRegisterCurrency(state : State, caller : Principal, code : T.Currency, minorUnits : Nat8) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    switch (validateCurrencyCode(code)) { case (?r) return #err(#InvalidCurrency({ code; reason = r })); case null {} };
    if (minorUnits > 18) return #err(#InvalidCurrency({ code; reason = "minor units exceed 18" }));
    if (Map.containsKey(state.currencies, Text.compare, code)) return #err(#CurrencyExists({ code }));
    #ok(#currencyRegistered({ code; minorUnits }))
  };

  public func prepareOpenAccount(state : State, caller : Principal, code : T.AccountCode, name : Text, normalSide : T.Side, category : T.Category, constraint : T.BalanceConstraint) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    switch (Leadsheet.validateAccountCode(code)) { case (?r) return #err(#InvalidAccountCode({ code; reason = r })); case null {} };
    let nameSize = Text.encodeUtf8(name).size();
    if (nameSize == 0 or nameSize > T.MAX_ACCOUNT_NAME_BYTES) return #err(#InvalidAccountCode({ code; reason = "account name must be 1 to 128 bytes" }));
    if (Map.containsKey(state.accounts, Text.compare, code)) return #err(#AccountExists({ code }));
    #ok(#accountOpened({ code; name; normalSide; category; constraint }))
  };

  public func prepareCloseAccount(state : State, caller : Principal, code : T.AccountCode) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    let ?a = Map.get(state.accounts, Text.compare, code) else return #err(#UnknownAccount({ code }));
    if (a.status == #closed) return #err(#AccountAlreadyClosed({ code }));
    switch (Map.get(state.pendingByAccount, Text.compare, code)) {
      case (?n) { if (n > 0) return #err(#AccountHasPending({ code; count = n })) };
      case null {};
    };
    for (((acct, sub, ccy), b) in Map.entries(state.balances)) {
      if (acct == code and b.drPosted != b.crPosted) {
        return #err(#AccountHasBalance({ code; subledger = if (sub.size() == 0) null else ?sub; currency = ccy; debits = b.drPosted; credits = b.crPosted }));
      };
    };
    #ok(#accountClosed({ code }))
  };

  public func prepareOpenPeriod(state : State, caller : Principal, id : T.PeriodId, start : T.Day, end : T.Day) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    switch (validatePeriodId(id)) { case (?r) return #err(#InvalidPeriod({ id; reason = r })); case null {} };
    if (start > end) return #err(#InvalidPeriod({ id; reason = "start is after end" }));
    if (Map.containsKey(state.periods, Text.compare, id)) return #err(#PeriodExists({ id }));
    for ((pid, p) in Map.entries(state.periods)) {
      if (start <= p.end and end >= p.start) return #err(#PeriodOverlaps({ id; overlapping = pid }));
    };
    #ok(#periodOpened({ id; start; end }))
  };

  public func prepareClosePeriod(state : State, caller : Principal, id : T.PeriodId) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    let ?p = Map.get(state.periods, Text.compare, id) else return #err(#UnknownPeriod({ id }));
    if (p.status == #closed) return #err(#PeriodAlreadyClosed({ id }));
    for ((qid, q) in Map.entries(state.periods)) {
      if (q.start < p.start and q.status == #open) return #err(#EarlierPeriodOpen({ id; earlier = qid }));
    };
    switch (Map.get(state.pendingByPeriod, Text.compare, id)) {
      case (?n) { if (n > 0) return #err(#PendingPostingsOutstanding({ id; count = n })) };
      case null {};
    };
    #ok(#periodClosed({ id }))
  };

  /// Roll the business date forward (never backwards, never past the clock day).
  public func prepareRollBusinessDate(state : State, caller : Principal, now : Nat64, day : T.Day) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    switch (authorityOf(state)) {
      case (#substrateClock) {
        let clockDay = CivilDate.fromNanos(Nat64.toNat(now));
        if (day > clockDay) return #err(#BusinessDateInFuture({ requested = day; today = clockDay }));
      };
      case (#businessDate) {
        // the clock is not a clock here; the roll's protections are its authorisation, its monotonicity and the bound
        let bound = rollBoundOf(state);
        switch (state.businessDate) {
          case (?cur) { if (bound > 0 and day > cur + bound) return #err(#BusinessDateRollTooFar({ current = cur; requested = day; maxRollDays = bound })) };
          case null {};
        };
      };
    };
    switch (state.businessDate) {
      case (?cur) { if (day <= cur) return #err(#BusinessDateBackwards({ current = cur; requested = day })) };
      case null {};
    };
    #ok(#businessDateRolled({ day }))
  };

  /// The calendar's authority, recorded. `#businessDate` needs a business date to exist once it is in force:
  /// the act carries the first one when none is set (and may advance an existing one, monotone); under
  /// `#substrateClock` a date travels only by the roll command, and the bound has no meaning.
  public func prepareSetCalendarAuthority(state : State, caller : Principal, authority : T.CalendarAuthority, maxRollDays : Nat, businessDate : ?T.Day) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    switch (authority) {
      case (#substrateClock) {
        if (businessDate != null) return #err(#InvalidCalendarAuthority({ reason = "a business date travels by the roll command under the substrate clock" }));
        if (maxRollDays != 0) return #err(#InvalidCalendarAuthority({ reason = "the roll bound applies under the business-date authority only" }));
      };
      case (#businessDate) {
        if (maxRollDays == 0) return #err(#InvalidCalendarAuthority({ reason = "the business-date authority needs a roll bound of at least one day" }));
        switch (businessDate, state.businessDate) {
          case (null, null) return #err(#InvalidCalendarAuthority({ reason = "the business-date authority needs a business date: none is set and the act carries none" }));
          case (?d, ?cur) { if (d <= cur) return #err(#BusinessDateBackwards({ current = cur; requested = d })) };
          case (_, _) {};
        };
      };
    };
    #ok(#calendarAuthoritySet({ authority; maxRollDays; businessDate }))
  };

  func authorityOf(state : State) : T.CalendarAuthority { switch (state.calendarAuthority) { case (?a) a; case null #substrateClock } };
  func rollBoundOf(state : State) : Nat { switch (state.maxRollDays) { case (?n) n; case null 0 } };
  public func calendarAuthority(state : State) : { authority : T.CalendarAuthority; maxRollDays : Nat } { { authority = authorityOf(state); maxRollDays = rollBoundOf(state) } };

  public func prepareSetCalendar(state : State, caller : Principal, calendar : ?T.CalendarConfig) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    switch (calendar) {
      case (?c) {
        let sorted = Calendar.sortedHolidays(c.holidays);
        switch (Calendar.validate({ restDays = c.restDays; holidays = sorted })) {
          case (?r) #err(#InvalidCalendar({ reason = r }));
          case null #ok(#calendarSet({ calendar = ?{ restDays = c.restDays; holidays = sorted; policy = c.policy } }));
        }
      };
      case null #ok(#calendarSet({ calendar = null }));
    }
  };

  public func prepareSetActivationHeight(state : State, caller : Principal, h : Nat64) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    #ok(#activationHeight({ height = h }))
  };

  public func prepareSetLeadsheetSchema(state : State, caller : Principal, ranges : [T.LeadsheetRange]) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    switch (Leadsheet.validate(ranges)) { case (?r) return #err(#InvalidLeadsheetSchema({ reason = r })); case null {} };
    #ok(#leadsheetSchema({ ranges = Leadsheet.sortByLo(ranges) }))
  };

  public func prepareAddPoster(state : State, caller : Principal, poster : Principal) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    if (Principal.isAnonymous(poster)) return #err(#InvalidPrincipal);
    if (isPoster(state, poster)) return #err(#PosterExists({ poster }));
    #ok(#posterAdded({ poster }))
  };

  public func prepareRemovePoster(state : State, caller : Principal, poster : Principal) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    if (not isPoster(state, poster)) return #err(#UnknownPoster({ poster }));
    #ok(#posterRemoved({ poster }))
  };

  /// Restrict (or, with null, unrestrict) the accounts a poster may name in a
  /// leg. Admin only, recorded as a block. The account list must be non-empty,
  /// free of duplicates, within the bound, and name only accounts that exist;
  /// a scope naming an account that does not exist would silently refuse every
  /// posting to it.
  public func prepareSetPosterScope(state : State, caller : Principal, poster : Principal, accounts : ?T.PosterScope) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    if (not isPoster(state, poster)) return #err(#UnknownPoster({ poster }));
    switch (accounts) {
      case null {
        if (Map.get(state.posterScopes, Principal.compare, poster) == null) return #err(#InvalidPosterScope({ reason = "poster is already unrestricted" }));
      };
      case (?list) {
        if (list.size() == 0) return #err(#InvalidPosterScope({ reason = "an empty scope would refuse every posting; pass null to unrestrict" }));
        if (list.size() > T.MAX_POSTER_SCOPE_ACCOUNTS) return #err(#InvalidPosterScope({ reason = "scope exceeds " # Nat.toText(T.MAX_POSTER_SCOPE_ACCOUNTS) # " accounts" }));
        var i = 0;
        while (i < list.size()) {
          if (not Map.containsKey(state.accounts, Text.compare, list[i])) return #err(#InvalidPosterScope({ reason = "unknown account " # list[i] }));
          var j = i + 1;
          while (j < list.size()) {
            if (Text.equal(list[i], list[j])) return #err(#InvalidPosterScope({ reason = "duplicate account " # list[i] }));
            j += 1;
          };
          i += 1;
        };
      };
    };
    #ok(#posterScopeSet({ poster; accounts }))
  };

  /// Record a numeric balance limit for one (account, sub-ledger, currency), or
  /// `#none` to lift the account's constraint for that sub-ledger. Admin only.
  /// This is what makes an overdraft facility and a net debit cap engine-enforced
  /// rather than checked by a layer that a second poster could bypass.
  public func prepareSetBalanceLimit(state : State, caller : Principal, account : T.AccountCode, sub : ?T.SubledgerKey, ccy : T.Currency, limit : T.BalanceLimit) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    switch (Map.get(state.accounts, Text.compare, account)) {
      case null return #err(#UnknownAccount({ code = account }));
      case (?a) { if (a.status == #closed) return #err(#AccountAlreadyClosed({ code = account })) };
    };
    if (not Map.containsKey(state.currencies, Text.compare, ccy)) return #err(#InvalidCurrency({ code = ccy; reason = "currency is not registered" }));
    switch (sub) {
      case (?k) { if (k.size() == 0 or k.size() > T.MAX_SUBLEDGER_BYTES) return #err(#InvalidBalanceLimit({ reason = "sub-ledger key is empty or over the bound" })) };
      case null {};
    };
    // A limit that contradicts the account's normal side is a configuration
    // mistake worth refusing: an allowance on the side the account never takes
    // would silently never bind.
    switch (limit) {
      case (#debitsNotExceedCreditsPlus(_)) {};
      case (#creditsNotExceedDebitsPlus(_)) {};
      case (#none) {};
    };
    #ok(#balanceLimitSet({ account; subledger = sub; currency = ccy; limit }))
  };

  /// Record chart-of-accounts attributes: header or detail, the
  /// manual-entry flag, and the parent for the rollup tree.
  public func prepareSetAccountAttributes(state : State, caller : Principal, code : T.AccountCode, attributes : T.AccountAttributes) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    switch (Map.get(state.accounts, Text.compare, code)) {
      case null return #err(#UnknownAccount({ code }));
      case (?a) { if (a.status == #closed) return #err(#AccountAlreadyClosed({ code })) };
    };
    switch (attributes.parent) {
      case (?p) {
        if (Text.equal(p, code)) return #err(#InvalidAccountAttributes({ reason = "an account cannot be its own parent" }));
        switch (Map.get(state.accounts, Text.compare, p)) {
          case null return #err(#UnknownAccount({ code = p }));
          case (?_) {};
        };
        // the parent must be a header account, and the tree must not cycle
        if (accountAttributes(state, p).usage != #header) {
          return #err(#InvalidAccountAttributes({ reason = "parent " # p # " is not a header account" }));
        };
        var cur : ?T.AccountCode = ?p;
        var depth = 0;
        label walk loop {
          switch (cur) {
            case null break walk;
            case (?c) {
              if (Text.equal(c, code)) return #err(#InvalidAccountAttributes({ reason = "the parent chain would cycle through " # code }));
              depth += 1;
              if (depth > 32) return #err(#InvalidAccountAttributes({ reason = "the parent chain is deeper than 32" }));
              cur := accountAttributes(state, c).parent;
            };
          };
        };
      };
      case null {};
    };
    // An account that already carries postings cannot become a header: the
    // postings it holds would become unreachable by the rule that refuses them.
    if (attributes.usage == #header) {
      for (((acct, _, _), b) in Map.entries(state.balances)) {
        if (Text.equal(acct, code)) {
          if (b.drPosted != 0 or b.crPosted != 0 or b.drPending != 0 or b.crPending != 0) {
            return #err(#InvalidAccountAttributes({ reason = "account " # code # " carries balances and cannot become a header" }));
          };
        };
      };
    };
    #ok(#accountAttributesSet({ code; attributes }))
  };

  public func prepareTransferAdmin(state : State, caller : Principal, admin : Principal) : Result.Result<T.Event, T.ConfigError> {
    switch (adminGate(state, caller)) { case (?e) return #err(e); case null {} };
    if (Principal.isAnonymous(admin)) return #err(#InvalidPrincipal);
    #ok(#adminTransferred({ admin }))
  };

  // ═══════════════════════════════════════════════════════
  //  APPLY; the only place state changes
  // ═══════════════════════════════════════════════════════

  func bal(state : State, account : Text, sub : Blob, ccy : Text) : Bal {
    switch (Map.get(state.balances, cmpBal, (account, sub, ccy))) {
      case (?b) b;
      case null { let b : Bal = { var drPosted = 0; var crPosted = 0; var drPending = 0; var crPending = 0 }; Map.add(state.balances, cmpBal, (account, sub, ccy), b); b };
    }
  };

  func periodAcc(state : State, period : Text, account : Text, ccy : Text) : Acc {
    switch (Map.get(state.periodBalances, cmp3, (period, account, ccy))) {
      case (?a) a;
      case null { let a : Acc = { var dr = 0; var cr = 0 }; Map.add(state.periodBalances, cmp3, (period, account, ccy), a); a };
    }
  };

  func bump(m : Map.Map<Text, Nat>, key : Text, delta : Int) {
    let cur = switch (Map.get(m, Text.compare, key)) { case (?n) n; case null 0 };
    let next : Int = cur + delta;
    if (next < 0) Runtime.trap("JournalCore: pending counter underflow for " # key);
    Map.add(m, Text.compare, key, Int.abs(next));
  };

  func applyPostedLegs(state : State, index : Nat, legs : [T.Leg], res : T.Resolution) {
    for (l in legs.vals()) {
      let sub = subKey(l.subledger);
      let b = bal(state, l.account, sub, l.currency);
      let pa = periodAcc(state, res.period, l.account, l.currency);
      let (dr, cr) = switch (l.side) { case (#debit) (l.amount, 0); case (#credit) (0, l.amount) };
      switch (l.side) {
        case (#debit) { b.drPosted += l.amount; pa.dr += l.amount };
        case (#credit) { b.crPosted += l.amount; pa.cr += l.amount };
      };
      // The ordinals and the padded sub-ledger key are the same for both indexes, so they are computed
      // once a leg rather than once an index.
      let aOrd = accountOrdinal(state, l.account);
      let cOrd = currencyOrdinal(state, l.currency);
      let padded = subBytes(sub);
      datedAdd(state, #valueDated, datedKeyFrom(aOrd, cOrd, padded, res.valueDate), dr, cr);
      datedAdd(state, #postingDated, datedKeyFrom(aOrd, cOrd, padded, res.postingDate), dr, cr);
    };
    if (putDroppable(state, #periodPostings, periodPostingKey(state, res.period, index), "" : Blob) == null) {
      Map.add(state.periodPostingCounts, Text.compare, res.period, periodPostingCount(state, res.period) + 1);
    };
    state.postedCount += 1;
  };

  func applyPendingLegs(state : State, legs : [T.Leg], sign : Int) {
    for (l in legs.vals()) {
      let b = bal(state, l.account, subKey(l.subledger), l.currency);
      if (sign > 0) {
        switch (l.side) { case (#debit) b.drPending += l.amount; case (#credit) b.crPending += l.amount };
      } else {
        switch (l.side) {
          case (#debit) { if (b.drPending < l.amount) Runtime.trap("JournalCore: pending debit underflow"); b.drPending -= l.amount };
          case (#credit) { if (b.crPending < l.amount) Runtime.trap("JournalCore: pending credit underflow"); b.crPending -= l.amount };
        };
      };
    };
  };

  /// Record, on the posting a new posting reverses or corrects, that it was reversed or corrected.
  ///
  /// A row update rather than a mutation of a shared heap object: the row is read, changed and written
  /// back under the same key, which is what `put` does in place. A correction also appends one entry to
  /// the corrector index, whose key carries the sequence so the list keeps its order.
  func linkRelation(state : State, index : Nat, relation : ?T.Relation) {
    switch (relation) {
      case null {};
      case (?rel) {
        switch (postingRow(state, rel.original)) {
          case null Runtime.trap("JournalCore: relation target missing at apply");
          case (?orig) {
            switch (rel.kind) {
              case (#reversal) {
                if (orig.reversedBy != null) Runtime.trap("JournalCore: INV-J5 double reversal at apply");
                putRow(
                  state,
                  rel.original,
                  { orig with reversedBy = ?index; flags = orig.flags | FLAG_REVERSED },
                  switch (orig.resolution) { case (?r) ?r.period; case null null },
                );
              };
              case (#correction) {
                ignore putDroppable(state, #correctors, correctorKey(rel.original, orig.correctors), RI.key([be(index, 8)], CORRECTOR_VAL_BYTES));
                putRow(
                  state,
                  rel.original,
                  { orig with correctors = orig.correctors + 1 },
                  switch (orig.resolution) { case (?r) ?r.period; case null null },
                );
              };
            };
          };
        };
      };
    };
  };

  func registerIdempotency(state : State, caller : Principal, record : T.PostingRecord, index : Nat, kind : SubmissionKind) {
    let scope = C.idempotencyScopeKey(caller, record.idempotencyKey);
    let val = encodeIdem({ index; contentHash = C.postingContentHash(record); kind });
    if (RI.put(state.idempotencyIndex, scope, val) == null) {
      state.idempotencyCount += 1;
    };
    switch (state.idempotencyRebuild) { case (?r) RB.mirror(r.job, scope, val, keepIdemAbove(state, r.hiPacked)); case null {} };
  };

  // ─── dropping a closed month's keys ───────────────────────────────────────

  /// A key leaves when its posting is at or below the packed boundary; unless it is a pending
  /// still open, whose resolution or void has not happened yet and whose duplicate must still be
  /// refused.
  func keepIdemAbove(state : State, hiPacked : Nat) : (Blob, Blob) -> Bool {
    func(_ : Blob, v : Blob) : Bool {
      let e = decodeIdem(v);
      e.index > hiPacked or (e.kind == #pending and Map.containsKey(state.openPendings, Nat.compare, e.index))
    }
  };

  /// Start dropping the keys of postings at or below `hiPacked`: the index is rebuilt without them,
  /// in chunks, while it keeps refusing duplicates. Refused while a rebuild is in progress.
  public func beginIdempotencyRebuild(state : State, hiPacked : Nat) : Bool {
    switch (state.idempotencyRebuild) { case (?_) return false; case null {} };
    state.idempotencyRebuild := ?{ job = RB.start(state.idempotencyIndex); hiPacked };
    true
  };

  public func stepIdempotencyRebuild(state : State, limit : Nat) : { examined : Nat; done : Bool } {
    let ?r = state.idempotencyRebuild else return { examined = 0; done = true };
    let n = RB.step(r.job, keepIdemAbove(state, r.hiPacked), limit);
    { examined = n; done = r.job.done }
  };

  public func finishIdempotencyRebuild(state : State) : ?{ copied : Nat; dropped : Nat } {
    let ?r = state.idempotencyRebuild else return null;
    if (not r.job.done) return null;
    state.idempotencyIndex := RB.finish(r.job);
    // the new index's size, not the copy's count: a key registered during the rebuild below the
    // cursor went in by the mirror, not the copy
    state.idempotencyCount := RI.size(state.idempotencyIndex);
    if (r.hiPacked > state.idempotencyDroppedThrough) state.idempotencyDroppedThrough := r.hiPacked;
    state.idempotencyRebuild := null;
    ?{ copied = r.job.copied; dropped = r.job.dropped }
  };

  /// The whole drop in one go, for a replayed state that must match a live one whose keys were
  /// dropped: the bank replays the journal, then drops what its own log says was packed.
  public func dropIdempotencyThrough(state : State, hiPacked : Nat) {
    if (hiPacked <= state.idempotencyDroppedThrough) return;
    assert (beginIdempotencyRebuild(state, hiPacked));
    label all loop { if (stepIdempotencyRebuild(state, 10_000).done) break all };
    ignore finishIdempotencyRebuild(state);
  };

  public func idempotencyDroppedThrough(state : State) : Nat { state.idempotencyDroppedThrough };

  public func idempotencyRebuildInProgress(state : State) : ?{ hiPacked : Nat; copied : Nat; dropped : Nat; done : Bool } {
    switch (state.idempotencyRebuild) { case (?r) ?{ hiPacked = r.hiPacked; copied = r.job.copied; dropped = r.job.dropped; done = r.job.done }; case null null }
  };

  /// Apply a committed block. Blocks must be applied in order; the block's
  /// index must equal the current height. Any inconsistency traps, which on
  /// the IC rolls back the whole message; a corrupt apply never half-lands.
  public func apply(state : State, blocks : Blocks, block : T.Block) {
    if (block.index != state.height) Runtime.trap("JournalCore: block index " # Nat.toText(block.index) # " != height " # Nat.toText(state.height));
    switch (block.event) {
      case (#posted(record)) {
        let res : T.Resolution = { postingDate = record.postingDate; valueDate = record.valueDate; valueDateRequested = record.valueDateRequested; period = record.period };
        // The record is not stored: it is in this very block, which the log has. The row holds the
        // facts that will change; none of them yet, for an immediate posting.
        putRow(state, block.index, {
          status = STATUS_POSTED; flags = 0; reversedBy = null; expiresAt = null;
          resolvedBy = 0; resolution = null; correctors = 0;
          timestamp = block.timestamp; caller = block.caller;
        }, null);
        applyPostedLegs(state, block.index, record.legs, res);
        linkRelation(state, block.index, record.relation);
        registerIdempotency(state, block.caller, record, block.index, #immediate);
      };
      case (#pending({ record; expiresAt })) {
        putRow(state, block.index, {
          status = STATUS_PENDING;
          flags = switch (expiresAt) { case (?_) FLAG_EXPIRES; case null 0 };
          reversedBy = null; expiresAt;
          resolvedBy = 0; resolution = null; correctors = 0;
          timestamp = block.timestamp; caller = block.caller;
        }, null);
        applyPendingLegs(state, record.legs, 1);
        Map.add(state.openPendings, Nat.compare, block.index, ());
        bump(state.pendingByPeriod, record.period, 1);
        for (l in record.legs.vals()) { bump(state.pendingByAccount, l.account, 1); bump(state.pendingByCurrency, l.currency, 1) };
        registerIdempotency(state, block.caller, record, block.index, #pending);
      };
      case (#post({ pendingIndex; resolution })) {
        let ?row = postingRow(state, pendingIndex) else Runtime.trap("JournalCore: post of unknown pending");
        if (row.status != STATUS_PENDING) Runtime.trap("JournalCore: INV-J4 post of resolved pending");
        // The pending's record comes from the log, where it was written when the pending was admitted.
        let record = loggedRecord(blocks, pendingIndex);
        applyPendingLegs(state, record.legs, -1);
        applyPostedLegs(state, pendingIndex, record.legs, resolution);
        putRow(state, pendingIndex, {
          row with
          status = STATUS_FROM_PENDING;
          flags = (row.flags - (row.flags & FLAG_VDR)) | (switch (resolution.valueDateRequested) { case (?_) FLAG_VDR; case null 0 });
          resolvedBy = block.index;
          resolution = ?resolution;
        }, ?resolution.period);
        ignore Map.delete(state.openPendings, Nat.compare, pendingIndex);
        bump(state.pendingByPeriod, record.period, -1);
        for (l in record.legs.vals()) { bump(state.pendingByAccount, l.account, -1); bump(state.pendingByCurrency, l.currency, -1) };
        linkRelation(state, pendingIndex, record.relation);
      };
      case (#void({ pendingIndex; reason })) {
        let ?row = postingRow(state, pendingIndex) else Runtime.trap("JournalCore: void of unknown pending");
        if (row.status != STATUS_PENDING) Runtime.trap("JournalCore: INV-J4 void of resolved pending");
        let record = loggedRecord(blocks, pendingIndex);
        applyPendingLegs(state, record.legs, -1);
        putRow(state, pendingIndex, {
          row with
          status = STATUS_VOIDED;
          resolvedBy = block.index;
          flags = row.flags | (switch (reason) { case (#expired) FLAG_EXPIRED_REASON; case (#requested) 0 });
        }, null);
        ignore Map.delete(state.openPendings, Nat.compare, pendingIndex);
        bump(state.pendingByPeriod, record.period, -1);
        for (l in record.legs.vals()) { bump(state.pendingByAccount, l.account, -1); bump(state.pendingByCurrency, l.currency, -1) };
        state.voidedCount += 1;
      };
      case (#currencyRegistered(c)) { Map.add(state.currencies, Text.compare, c.code, c.minorUnits) };
      case (#accountOpened(a)) {
        let entry : AccountEntry = {
          code = a.code; name = a.name; normalSide = a.normalSide; category = a.category; constraint = a.constraint;
          var status = #active; openedAtBlock = block.index; var closedAtBlock = null;
        };
        Map.add(state.accounts, Text.compare, a.code, entry);
      };
      case (#accountClosed(a)) {
        let ?acct = Map.get(state.accounts, Text.compare, a.code) else Runtime.trap("JournalCore: close of unknown account");
        acct.status := #closed;
        acct.closedAtBlock := ?block.index;
      };
      case (#periodOpened(p)) {
        let entry : PeriodEntry = { id = p.id; start = p.start; end = p.end; var status = #open; openedAtBlock = block.index; var closedAtBlock = null };
        Map.add(state.periods, Text.compare, p.id, entry);
      };
      case (#periodClosed(p)) {
        let ?per = Map.get(state.periods, Text.compare, p.id) else Runtime.trap("JournalCore: close of unknown period");
        per.status := #closed;
        per.closedAtBlock := ?block.index;
      };
      case (#activationHeight(a)) { state.activationHeight := a.height };
      case (#leadsheetSchema(s)) { state.leadsheet := s.ranges };
      case (#posterAdded(p)) { Map.add(state.posters, Principal.compare, p.poster, ()) };
      case (#posterRemoved(p)) { ignore Map.delete(state.posters, Principal.compare, p.poster) };
      case (#balanceLimitSet(x)) {
        switch (x.limit) {
          case (#none) {
            // `#none` recorded explicitly is a stored limit that lifts the
            // account's constraint for this sub-ledger; clearing the entry
            // entirely would restore the constraint instead.
            Map.add(state.balanceLimits, cmpBal, (x.account, subKey(x.subledger), x.currency), #none);
          };
          case (l) Map.add(state.balanceLimits, cmpBal, (x.account, subKey(x.subledger), x.currency), l);
        };
      };
      case (#accountAttributesSet(x)) { Map.add(state.accountAttributes, Text.compare, x.code, x.attributes) };
      case (#posterScopeSet(p)) {
        switch (p.accounts) {
          case (?accounts) Map.add(state.posterScopes, Principal.compare, p.poster, accounts);
          case null ignore Map.delete(state.posterScopes, Principal.compare, p.poster);
        };
      };
      case (#adminTransferred(a)) { state.admin := a.admin };
      case (#businessDateRolled(b)) { state.businessDate := ?b.day };
      case (#calendarSet(c)) { state.calendar := c.calendar };
      case (#calendarAuthoritySet(x)) {
        state.calendarAuthority := ?x.authority; state.maxRollDays := ?x.maxRollDays;
        switch (x.businessDate) { case (?d) state.businessDate := ?d; case null {} };
      };
      case (#checkpoint(c)) {
        // the live state already is what the checkpoint says; only the series' position is kept
        if (c.seq == 0) state.checkpoint := ?{ through = c.through; first = block.index; var last = null };
        switch (state.checkpoint) { case (?cp) { if (cp.through == c.through and c.last) cp.last := ?block.index }; case null {} };
      };
    };
    state.height += 1;
  };

  /// Rebuild a state from scratch by applying every block in order.
  ///
  /// The blocks it is given are also the log it reads records back from, so a replay needs no second
  /// source: a pending resolved at block 40 finds its record at block 12 in the same array.
  public func replay(admin : Principal, blocks : [T.Block]) : State {
    let s = newState(admin);
    let reader : Blocks = { get = func(i : Nat) : ?T.Block { if (i < blocks.size()) ?blocks[i] else null } };
    for (b in blocks.vals()) { apply(s, reader, b) };
    s
  };

  // ═══════════════════════════════════════════════════════
  //  CHECKPOINTS; the derived state written into its own log
  // ═══════════════════════════════════════════════════════

  /// Where a chunked serialisation is: which part comes next, and the key it resumes from.
  public type CheckpointCursor = {
    #config; #accounts; #periods;
    #balances : ?(Text, Blob, Text);
    #periodBalances : ?(Text, Text, Text);
    #valueDated : ?Blob; #postingDated : ?Blob;
    #pendings;
    #done;
  };

  public let CHECKPOINT_CHUNK : Nat = 4_000;

  public func checkpointPosition(state : State) : ?{ through : Nat; first : Nat; last : ?Nat } {
    switch (state.checkpoint) { case (?c) ?{ through = c.through; first = c.first; last = c.last }; case null null }
  };

  /// One part of the state, at most `CHECKPOINT_CHUNK` entries, and where the next call resumes.
  /// The dated rows are carried rolled up through `periodEnd`. Pure over the state.
  public func checkpointPart(state : State, cursor : CheckpointCursor, periodEnd : Nat) : { part : T.CheckpointPart; next : CheckpointCursor } {
    switch (cursor) {
      case (#config) {
        let limits = List.empty<{ account : T.AccountCode; subledger : Blob; currency : T.Currency; limit : T.BalanceLimit }>();
        for (((account, subledger, currency), limit) in Map.entries(state.balanceLimits)) List.add(limits, { account; subledger; currency; limit });
        ({
          part = #config({
            admin = state.admin; activationHeight = state.activationHeight; businessDate = state.businessDate; calendar = state.calendar; leadsheet = state.leadsheet;
            calendarAuthority = authorityOf(state); maxRollDays = rollBoundOf(state);
            currencies = Map.toArray(state.currencies); posters = Array.map<(Principal, ()), Principal>(Map.toArray(state.posters), func((p, _)) { p });
            posterScopes = Map.toArray(state.posterScopes); balanceLimits = List.toArray(limits); accountAttributes = Map.toArray(state.accountAttributes);
            accountOrdinals = Map.toArray(state.accountOrdinals); currencyOrdinals = Map.toArray(state.currencyOrdinals); periodOrdinals = Map.toArray(state.periodOrdinals);
            postedCount = state.postedCount; voidedCount = state.voidedCount; datedRolledUpThrough = Nat.max(state.datedRolledUpThrough, periodEnd);
          });
          next = #accounts;
        })
      };
      case (#accounts) {
        let out = List.empty<{ code : T.AccountCode; name : Text; normalSide : T.Side; category : T.Category; constraint : T.BalanceConstraint; active : Bool; openedAtBlock : Nat; closedAtBlock : ?Nat }>();
        for ((_, a) in Map.entries(state.accounts)) List.add(out, { code = a.code; name = a.name; normalSide = a.normalSide; category = a.category; constraint = a.constraint; active = a.status == #active; openedAtBlock = a.openedAtBlock; closedAtBlock = a.closedAtBlock });
        { part = #accounts(List.toArray(out)); next = #periods }
      };
      case (#periods) {
        let out = List.empty<{ id : T.PeriodId; start : T.Day; end : T.Day; open : Bool; openedAtBlock : Nat; closedAtBlock : ?Nat; postings : Nat; pendings : Nat }>();
        for ((_, p) in Map.entries(state.periods)) List.add(out, { id = p.id; start = p.start; end = p.end; open = p.status == #open; openedAtBlock = p.openedAtBlock; closedAtBlock = p.closedAtBlock; postings = periodPostingCount(state, p.id); pendings = switch (Map.get(state.pendingByPeriod, Text.compare, p.id)) { case (?n) n; case null 0 } });
        { part = #periods(List.toArray(out)); next = #balances(null) }
      };
      case (#balances(from)) {
        let out = List.empty<{ account : T.AccountCode; subledger : Blob; currency : T.Currency; drPosted : Nat; crPosted : Nat; drPending : Nat; crPending : Nat }>();
        var next : CheckpointCursor = #periodBalances(null);
        let it = switch (from) { case (?k) Map.entriesFrom(state.balances, cmpBal, k); case null Map.entries(state.balances) };
        label walk for (((account, subledger, currency), b) in it) {
          if (List.size(out) == CHECKPOINT_CHUNK) { next := #balances(?(account, subledger, currency)); break walk };
          List.add(out, { account; subledger; currency; drPosted = b.drPosted; crPosted = b.crPosted; drPending = b.drPending; crPending = b.crPending });
        };
        { part = #balances(List.toArray(out)); next }
      };
      case (#periodBalances(from)) {
        let out = List.empty<{ period : T.PeriodId; account : T.AccountCode; currency : T.Currency; debits : Nat; credits : Nat }>();
        var next : CheckpointCursor = #valueDated(null);
        let it = switch (from) { case (?k) Map.entriesFrom(state.periodBalances, cmp3, k); case null Map.entries(state.periodBalances) };
        label walk for (((period, account, currency), acc) in it) {
          if (List.size(out) == CHECKPOINT_CHUNK) { next := #periodBalances(?(period, account, currency)); break walk };
          List.add(out, { period; account; currency; debits = acc.dr; credits = acc.cr });
        };
        { part = #periodBalances(List.toArray(out)); next }
      };
      case (#valueDated(from)) { let r = datedPart(state, state.valueDatedIndex, from, periodEnd); { part = #dated({ valueDated = true; rows = r.rows }); next = switch (r.next) { case (?c) #valueDated(?c); case null #postingDated(null) } } };
      case (#postingDated(from)) { let r = datedPart(state, state.postingDatedIndex, from, periodEnd); { part = #dated({ valueDated = false; rows = r.rows }); next = switch (r.next) { case (?c) #postingDated(?c); case null #pendings } } };
      case (#pendings) {
        { part = #pendings({ open = Array.map<(Nat, ()), Nat>(Map.toArray(state.openPendings), func((i, _)) { i }); byAccount = Map.toArray(state.pendingByAccount); byCurrency = Map.toArray(state.pendingByCurrency) }); next = #done }
      };
      case (#done) Runtime.trap("JournalCore: a checkpoint part past the end");
    }
  };

  /// A chunk of one dated index in key order, the days at or before `periodEnd` folded into one row
  /// at `periodEnd` per prefix. A chunk ends only at a prefix boundary, so a rolled-up row is never
  /// split across parts.
  func datedPart(state : State, index : RI.State, from : ?Blob, periodEnd : Nat) : { rows : [{ account : T.AccountCode; currency : T.Currency; subledger : Blob; day : T.Day; debits : Nat; credits : Nat }]; next : ?Blob } {
    let out = List.empty<{ account : T.AccountCode; currency : T.Currency; subledger : Blob; day : T.Day; debits : Nat; credits : Nat }>();
    let (lo, hi) = RI.rangeEnds([], DATED_KEY_BYTES);
    var cursor : ?Blob = from;
    var acc : ?{ prefix : [Nat8]; var dr : Nat; var cr : Nat } = null;
    func flush() {
      switch (acc) {
        case (?x) {
          List.add(out, { account = accountOfOrdinal(state, beNat(x.prefix, 0, 4)); currency = currencyOfOrdinal(state, beNat(x.prefix, 4, 4)); subledger = Blob.fromArray(Array.tabulate<Nat8>(T.MAX_SUBLEDGER_BYTES, func(i) { x.prefix[DATED_SUB_OFFSET + i] })); day = periodEnd; debits = x.dr; credits = x.cr });
          acc := null;
        };
        case null {};
      };
    };
    label walk loop {
      let page = RI.range(index, lo, hi, cursor, 500);
      for ((k, v) in page.entries.vals()) {
        let a = Blob.toArray(k);
        let b = Blob.toArray(v);
        let day = beNat(a, DATED_DAY_OFFSET, 4);
        let prefix = Array.tabulate<Nat8>(DATED_DAY_OFFSET, func(i) { a[i] });
        switch (acc) { case (?x) { if (x.prefix != prefix) flush() }; case null {} };
        if (day <= periodEnd) {
          switch (acc) {
            case (?x) { x.dr += beNat(b, 0, 8); x.cr += beNat(b, 8, 8) };
            case null acc := ?{ prefix; var dr = beNat(b, 0, 8); var cr = beNat(b, 8, 8) };
          };
        } else {
          flush();
          List.add(out, { account = accountOfOrdinal(state, beNat(a, 0, 4)); currency = currencyOfOrdinal(state, beNat(a, 4, 4)); subledger = Blob.fromArray(Array.tabulate<Nat8>(T.MAX_SUBLEDGER_BYTES, func(i) { a[DATED_SUB_OFFSET + i] })); day; debits = beNat(b, 0, 8); credits = beNat(b, 8, 8) });
        };
      };
      switch (page.cursor) {
        case (?c) {
          cursor := ?c;
          // stop at a prefix boundary once the chunk is full: the next key's prefix differs from the
          // accumulator's, or nothing is accumulating
          if (List.size(out) >= CHECKPOINT_CHUNK) {
            let nextPrefix = Array.tabulate<Nat8>(DATED_DAY_OFFSET, func(i) { Blob.toArray(c)[i] });
            switch (acc) { case (?x) { if (x.prefix != nextPrefix) { flush(); return { rows = List.toArray(out); next = ?c } } }; case null return { rows = List.toArray(out); next = ?c } };
          };
        };
        case null { flush(); break walk };
      };
    };
    { rows = List.toArray(out); next = null }
  };

  func currencyOfOrdinal(state : State, o : Nat) : T.Currency {
    for ((code, ord) in Map.entries(state.currencyOrdinals)) { if (ord == o) return code };
    Runtime.trap("JournalCore: currency ordinal " # Nat.toText(o) # " has no code")
  };

  /// A state from a checkpoint series: `through` is the block the state stood after; the parts in
  /// order. The per-posting indexes start empty, as the roll leaves them.
  public func restore(admin : Principal, through : Nat, parts : [T.CheckpointPart]) : State { restoreIn(admin, RI.newArena(), through, parts) };

  public func restoreIn(admin : Principal, arena : RI.Arena, through : Nat, parts : [T.CheckpointPart]) : State {
    let s = newStateIn(admin, arena);
    for (part in parts.vals()) {
      switch (part) {
        case (#config(c)) {
          s.admin := c.admin; s.activationHeight := c.activationHeight; s.businessDate := c.businessDate; s.calendar := c.calendar; s.leadsheet := c.leadsheet;
          s.calendarAuthority := ?c.calendarAuthority; s.maxRollDays := ?c.maxRollDays;
          for ((code, mu) in c.currencies.vals()) Map.add(s.currencies, Text.compare, code, mu);
          for (p in c.posters.vals()) Map.add(s.posters, Principal.compare, p, ());
          for ((p, scope) in c.posterScopes.vals()) Map.add(s.posterScopes, Principal.compare, p, scope);
          for (l in c.balanceLimits.vals()) Map.add(s.balanceLimits, cmpBal, (l.account, l.subledger, l.currency), l.limit);
          for ((code, a) in c.accountAttributes.vals()) Map.add(s.accountAttributes, Text.compare, code, a);
          for ((code, o) in c.accountOrdinals.vals()) { Map.add(s.accountOrdinals, Text.compare, code, o); Map.add(s.accountNames, Nat.compare, o, code); if (o + 1 > s.nextAccountOrdinal) s.nextAccountOrdinal := o + 1 };
          for ((code, o) in c.currencyOrdinals.vals()) { Map.add(s.currencyOrdinals, Text.compare, code, o); if (o + 1 > s.nextCurrencyOrdinal) s.nextCurrencyOrdinal := o + 1 };
          for ((id, o) in c.periodOrdinals.vals()) { Map.add(s.periodOrdinals, Text.compare, id, o); Map.add(s.periodNames, Nat.compare, o, id); if (o + 1 > s.nextPeriodOrdinal) s.nextPeriodOrdinal := o + 1 };
          s.postedCount := c.postedCount; s.voidedCount := c.voidedCount; s.datedRolledUpThrough := c.datedRolledUpThrough;
        };
        case (#accounts(xs)) {
          for (a in xs.vals()) Map.add(s.accounts, Text.compare, a.code, { code = a.code; name = a.name; normalSide = a.normalSide; category = a.category; constraint = a.constraint; var status = if (a.active) #active else #closed; openedAtBlock = a.openedAtBlock; var closedAtBlock = a.closedAtBlock });
        };
        case (#periods(xs)) {
          for (p in xs.vals()) {
            Map.add(s.periods, Text.compare, p.id, { id = p.id; start = p.start; end = p.end; var status = if (p.open) #open else #closed; openedAtBlock = p.openedAtBlock; var closedAtBlock = p.closedAtBlock });
            if (p.postings > 0) Map.add(s.periodPostingCounts, Text.compare, p.id, p.postings);
            if (p.pendings > 0) Map.add(s.pendingByPeriod, Text.compare, p.id, p.pendings);
          };
        };
        case (#balances(xs)) {
          for (b in xs.vals()) Map.add(s.balances, cmpBal, (b.account, b.subledger, b.currency), { var drPosted = b.drPosted; var crPosted = b.crPosted; var drPending = b.drPending; var crPending = b.crPending });
        };
        case (#periodBalances(xs)) {
          for (b in xs.vals()) Map.add(s.periodBalances, cmp3, (b.period, b.account, b.currency), { var dr = b.debits; var cr = b.credits });
        };
        case (#dated(d)) {
          for (r in d.rows.vals()) {
            let k = datedKeyFrom(accountOrdinal(s, r.account), currencyOrdinal(s, r.currency), subBytes(r.subledger), r.day);
            ignore RI.put(if (d.valueDated) s.valueDatedIndex else s.postingDatedIndex, k, RI.key([be(r.debits, 8), be(r.credits, 8)], DATED_VAL_BYTES));
          };
        };
        case (#pendings(x)) {
          for (i in x.open.vals()) Map.add(s.openPendings, Nat.compare, i, ());
          for ((a, n) in x.byAccount.vals()) Map.add(s.pendingByAccount, Text.compare, a, n);
          for ((c, n) in x.byCurrency.vals()) Map.add(s.pendingByCurrency, Text.compare, c, n);
        };
      };
    };
    s.height := through + 1;
    s.idempotencyDroppedThrough := through;
    s
  };

  /// A fold of a log whose prefix has left: the checkpoint series at blocks `first … last` restored,
  /// then every block after `last` applied; and every block between `through` and `first` as well,
  /// which were applied to the live state after the checkpoint's boundary. The blocks are read from
  /// `blocks`, which is also what the fold reads records back from.
  public func replayFrom(admin : Principal, blocks : Blocks, first : Nat, last : Nat, end : Nat) : State { replayFromIn(admin, RI.newArena(), blocks, first, last, end) };

  /// The layout of the derived state: every fixed-width row, key width and index this module keeps in Regions. A
  /// contract records the layout its state was written with and, on an upgrade to code with another, rebuilds the state
  /// from the log rather than reading old bytes as new rows (the bank's S4.10). Raised on any such change.
  public let LAYOUT_VERSION : Nat = 1;

  /// The first step of a rebuild that can be resumed: the state restored from the checkpoint series (the log's packed
  /// prefix) and the index of the first block to fold after it. The caller folds from there with `apply`, a chunk at a
  /// time, to the log's end. Without a series the state is fresh and the fold starts at block 0.
  public func rebuildStart(admin : Principal, arena : RI.Arena, blocks : Blocks, series : ?{ first : Nat; last : Nat }) : { state : State; next : Nat } {
    switch (series) {
      case (?cp) {
        let parts = List.empty<T.CheckpointPart>();
        var through = 0;
        var seq = 0;
        var i = cp.first;
        while (i <= cp.last) {
          let ?b = blocks.get(i) else Runtime.trap("JournalCore: checkpoint block " # Nat.toText(i) # " is not in the log");
          switch (b.event) {
            case (#checkpoint(c)) {
              if (i == cp.first) through := c.through;
              if (c.through != through or c.seq != seq) Runtime.trap("JournalCore: a checkpoint series out of order at block " # Nat.toText(i));
              List.add(parts, c.part);
              seq += 1;
            };
            case (_) {};
          };
          i += 1;
        };
        if (List.size(parts) == 0) Runtime.trap("JournalCore: no checkpoint parts between " # Nat.toText(cp.first) # " and " # Nat.toText(cp.last));
        { state = restoreIn(admin, arena, through, List.toArray(parts)); next = through + 1 }
      };
      case null ({ state = newStateIn(admin, arena); next = 0 });
    }
  };

  public func replayFromIn(admin : Principal, arena : RI.Arena, blocks : Blocks, first : Nat, last : Nat, end : Nat) : State {
    // the series' parts, in order; other blocks between them (postings that landed while the
    // series was being written) are applied below like every block after the boundary
    let parts = List.empty<T.CheckpointPart>();
    var through = 0;
    var seq = 0;
    var i = first;
    while (i <= last) {
      let ?b = blocks.get(i) else Runtime.trap("JournalCore: checkpoint block " # Nat.toText(i) # " is not in the log");
      switch (b.event) {
        case (#checkpoint(c)) {
          if (i == first) through := c.through;
          if (c.through != through or c.seq != seq) Runtime.trap("JournalCore: a checkpoint series out of order at block " # Nat.toText(i));
          List.add(parts, c.part);
          seq += 1;
        };
        case (_) {};
      };
      i += 1;
    };
    if (List.size(parts) == 0) Runtime.trap("JournalCore: no checkpoint parts between " # Nat.toText(first) # " and " # Nat.toText(last));
    let s = restoreIn(admin, arena, through, List.toArray(parts));
    var j = through + 1;
    while (j < end) {
      let ?b = blocks.get(j) else Runtime.trap("JournalCore: block " # Nat.toText(j) # " is not in the log");
      apply(s, blocks, b);
      j += 1;
    };
    s
  };

  // ═══════════════════════════════════════════════════════
  //  VIEWS
  // ═══════════════════════════════════════════════════════

  public func accountViewIn(state : State, a : AccountEntry) : T.Account {
    { code = a.code; name = a.name; normalSide = a.normalSide; category = a.category; constraint = a.constraint; status = a.status; openedAtBlock = a.openedAtBlock; closedAtBlock = a.closedAtBlock; attributes = accountAttributes(state, a.code) }
  };

  /// The view without state, for a caller that has only the entry; attributes
  /// read as the default, which is what an account with none recorded has.
  public func accountView(a : AccountEntry) : T.Account {
    { code = a.code; name = a.name; normalSide = a.normalSide; category = a.category; constraint = a.constraint; status = a.status; openedAtBlock = a.openedAtBlock; closedAtBlock = a.closedAtBlock; attributes = T.DEFAULT_ACCOUNT_ATTRIBUTES }
  };

  public func periodView(p : PeriodEntry) : T.Period {
    { id = p.id; start = p.start; end = p.end; status = p.status; openedAtBlock = p.openedAtBlock; closedAtBlock = p.closedAtBlock }
  };

  public func listAccounts(state : State) : [T.Account] {
    Array.map<(Text, AccountEntry), T.Account>(Map.toArray(state.accounts), func((_, a)) { accountViewIn(state, a) })
  };

  /// ─── paged reads ─────────────────────────────────────────────────────────
  ///
  /// Every read above that returns "all of them" is unbounded in the size of the chart or of the
  /// book, and an unbounded read in a contract is not a slow read: it is a read that one day does
  /// not return. Each has a paged form below, taking a cursor and a limit and returning the cursor
  /// to resume at.
  ///
  /// The walk is a **seek**, not a scan: `Map.entriesFrom` descends to the cursor's position, so a
  /// page costs the page and not the position. The unpaged forms are kept, because several internal
  /// callers are already bounded by something else; a report's declared `maxSlice`, a period's own
  /// posting count; and paging those would only move the bound somewhere harder to see.

  /// The page bound these reads share. A caller may ask for less; nothing gets more.
  public let MAX_PAGE : Nat = 500;

  func pageLimit(limit : Nat) : Nat { if (limit == 0 or limit > MAX_PAGE) MAX_PAGE else limit };

  public type AccountPage = { rows : [T.Account]; cursor : ?T.AccountCode; total : Nat };

  public func listAccountsPaged(state : State, cursor : ?T.AccountCode, limit : Nat) : AccountPage {
    let n = pageLimit(limit);
    let rows = List.empty<T.Account>();
    var next : ?T.AccountCode = null;
    let it = switch (cursor) {
      case (?c) Map.entriesFrom(state.accounts, Text.compare, c);
      case null Map.entries(state.accounts);
    };
    label walk for ((code, a) in it) {
      if (List.size(rows) == n) { next := ?code; break walk };
      List.add(rows, accountViewIn(state, a));
    };
    { rows = List.toArray(rows); cursor = next; total = Map.size(state.accounts) }
  };

  public func listPeriods(state : State) : [T.Period] {
    Array.sort<T.Period>(
      Array.map<(Text, PeriodEntry), T.Period>(Map.toArray(state.periods), func((_, p)) { periodView(p) }),
      func(a, b) { Nat.compare(a.start, b.start) }
    )
  };

  public func listCurrencies(state : State) : [T.CurrencyInfo] {
    Array.map<(Text, Nat8), T.CurrencyInfo>(Map.toArray(state.currencies), func((code, minorUnits)) { { code; minorUnits } })
  };

  public func listPosterScopes(state : State) : [(Principal, T.PosterScope)] {
    Map.toArray(state.posterScopes)
  };

  public func listPosters(state : State) : [Principal] {
    Array.map<(Principal, ()), Principal>(Map.toArray(state.posters), func((p, _)) { p })
  };

  public func getPeriod(state : State, id : T.PeriodId) : ?T.Period {
    switch (Map.get(state.periods, Text.compare, id)) { case (?p) ?periodView(p); case null null }
  };

  /// An account as a reader sees it, **including its recorded attributes**. It uses
  /// `accountViewIn` rather than `accountView` because the latter has no state and
  /// therefore reports the default attributes: a caller reading
  /// `getAccount(...).attributes.usage` to decide whether an account may carry a
  /// posting would have been told `#detail` for every header account in the chart.
  public func getAccount(state : State, code : T.AccountCode) : ?T.Account {
    switch (Map.get(state.accounts, Text.compare, code)) { case (?a) ?accountViewIn(state, a); case null null }
  };

  public func currencyMinorUnits(state : State, code : T.Currency) : ?Nat8 { Map.get(state.currencies, Text.compare, code) };

  /// The posting a (caller, idempotency key) pair already committed, if any. The
  /// idempotency table is the journal's own duplicate-rejection index, so this is
  /// a read of something already there rather than a new structure; it exists so a
  /// caller whose keys are **derived** from the facts of an act can find the
  /// posting that act produced; which is what makes a reversal possible without
  /// anyone storing a posting index alongside the decision that caused it.
  public func postingIndexByKey(state : State, caller : Principal, key : Blob) : ?Nat {
    switch (idemOf(state, C.idempotencyScopeKey(caller, key))) {
      case (?e) ?e.index;
      case null null;
    }
  };
  public func businessDate(state : State) : ?T.Day { state.businessDate };
  public func calendar(state : State) : ?T.CalendarConfig { state.calendar };

  public func postingView(state : State, blocks : Blocks, index : Nat) : ?T.PostingView {
    switch (postingMeta(state, blocks, index)) {
      case null null;
      case (?m) ?{
        index = m.index; timestamp = m.timestamp; caller = m.caller; record = m.record;
        status = m.status; reversedBy = m.reversedBy; correctedBy = m.correctedBy;
      };
    }
  };

  public func listPending(state : State, blocks : Blocks) : [T.PendingView] {
    let out = List.empty<T.PendingView>();
    for ((idx, _) in Map.entries(state.openPendings)) {
      switch (postingRow(state, idx)) {
        case (?row) List.add(out, { index = idx; record = loggedRecord(blocks, idx); expiresAt = row.expiresAt; caller = row.caller });
        case null {};
      };
    };
    List.toArray(out)
  };

  /// The open pendings, paged. Open pendings are bounded by how many a bank leaves unresolved, which
  /// is a number nobody controls, so this read is paged like the rest. The cursor is the posting index
  /// it stopped at, and `openPendings` is keyed by it, so resuming is a seek.
  public type PendingPage = { rows : [T.PendingView]; cursor : ?Nat; total : Nat };

  public func listPendingPaged(state : State, blocks : Blocks, cursor : ?Nat, limit : Nat) : PendingPage {
    let n = pageLimit(limit);
    let out = List.empty<T.PendingView>();
    var next : ?Nat = null;
    let it = switch (cursor) {
      case (?c) Map.entriesFrom(state.openPendings, Nat.compare, c);
      case null Map.entries(state.openPendings);
    };
    label walk for ((idx, _) in it) {
      if (List.size(out) == n) { next := ?idx; break walk };
      switch (postingRow(state, idx)) {
        case (?row) List.add(out, { index = idx; record = loggedRecord(blocks, idx); expiresAt = row.expiresAt; caller = row.caller });
        case null {};
      };
    };
    { rows = List.toArray(out); cursor = next; total = Map.size(state.openPendings) }
  };

  public func pendingCount(state : State) : Nat { Map.size(state.openPendings) };
  /// The open pending legs in a currency, from the fold's counter.
  public func pendingLegsInCurrency(state : State, currency : T.Currency) : Nat { switch (Map.get(state.pendingByCurrency, Text.compare, currency)) { case (?n) n; case null 0 } };
  public func postedCount(state : State) : Nat { state.postedCount };
  public func voidedCount(state : State) : Nat { state.voidedCount };
  public func leadsheetSchema(state : State) : [T.LeadsheetRange] { state.leadsheet };

  func subView(sub : Blob) : ?Blob { if (sub.size() == 0) null else ?sub };

  /// Balance of one sub-ledger (or of the account itself when `subledger` is
  /// null and the account is used without sub-ledgers). For a control
  /// account's total across its sub-ledgers use `accountTotal`.
  public func balance(state : State, account : T.AccountCode, subledger : ?T.SubledgerKey, ccy : T.Currency) : T.Balance {
    switch (Map.get(state.balances, cmpBal, (account, subKey(subledger), ccy))) {
      case (?b) { { account; subledger; currency = ccy; debitsPosted = b.drPosted; creditsPosted = b.crPosted; debitsPending = b.drPending; creditsPending = b.crPending } };
      case null { { account; subledger; currency = ccy; debitsPosted = 0; creditsPosted = 0; debitsPending = 0; creditsPending = 0 } };
    }
  };

  /// Sum over every sub-ledger of an account (and the account itself).
  public func accountTotal(state : State, account : T.AccountCode, ccy : T.Currency) : T.Balance {
    var dp = 0; var cp = 0; var dn = 0; var cn = 0;
    for (((a, _, c), b) in Map.entries(state.balances)) {
      if (a == account and c == ccy) { dp += b.drPosted; cp += b.crPosted; dn += b.drPending; cn += b.crPending };
    };
    { account; subledger = null; currency = ccy; debitsPosted = dp; creditsPosted = cp; debitsPending = dn; creditsPending = cn }
  };

  public func allBalances(state : State) : [T.Balance] {
    Array.map<((Text, Blob, Text), Bal), T.Balance>(Map.toArray(state.balances), func(((account, sub, currency), b)) {
      { account; subledger = subView(sub); currency; debitsPosted = b.drPosted; creditsPosted = b.crPosted; debitsPending = b.drPending; creditsPending = b.crPending }
    })
  };

  /// The cursor of a balance page is the composite key it stopped at, so resuming is a seek into the
  /// same ordering rather than a count into a list that may have grown.
  public type BalanceCursor = { account : T.AccountCode; subledger : Blob; currency : T.Currency };
  public type BalancePage = { rows : [T.Balance]; cursor : ?BalanceCursor; total : Nat };

  public func allBalancesPaged(state : State, cursor : ?BalanceCursor, limit : Nat) : BalancePage {
    let n = pageLimit(limit);
    let rows = List.empty<T.Balance>();
    var next : ?BalanceCursor = null;
    let it = switch (cursor) {
      case (?c) Map.entriesFrom(state.balances, cmpBal, (c.account, c.subledger, c.currency));
      case null Map.entries(state.balances);
    };
    label walk for (((account, sub, currency), b) in it) {
      if (List.size(rows) == n) { next := ?{ account; subledger = sub; currency }; break walk };
      List.add(rows, {
        account; subledger = subView(sub); currency;
        debitsPosted = b.drPosted; creditsPosted = b.crPosted;
        debitsPending = b.drPending; creditsPending = b.crPending;
      });
    };
    { rows = List.toArray(rows); cursor = next; total = Map.size(state.balances) }
  };

  /// Balances of every sub-ledger under an account.
  public func subledgerBalances(state : State, account : T.AccountCode) : [T.Balance] {
    Array.map<T.Balance, T.Balance>(Array.filter<T.Balance>(allBalances(state), func(b) { b.account == account }), func(b) { b })
  };

  /// Balances of the sub-ledgers under one account, paged.
  ///
  /// This is the read that most needed it: the chart has a few thousand accounts, but a single
  /// customer-accounts control may carry a sub-ledger for every account the bank holds. The composite
  /// key is `(account, subledger, currency)` and it sorts account-first, so one account's sub-ledgers
  /// are a contiguous run and a page is a seek plus the page.
  public func subledgerBalancesPaged(state : State, account : T.AccountCode, cursor : ?BalanceCursor, limit : Nat) : BalancePage {
    let n = pageLimit(limit);
    let rows = List.empty<T.Balance>();
    var next : ?BalanceCursor = null;
    let start : (Text, Blob, Text) = switch (cursor) {
      case (?c) (c.account, c.subledger, c.currency);
      // the low end of this account's run: the empty sub-ledger key and the empty currency sort first
      case null (account, "" : Blob, "");
    };
    label walk for (((a, sub, currency), b) in Map.entriesFrom(state.balances, cmpBal, start)) {
      if (a != account) break walk;
      if (List.size(rows) == n) { next := ?{ account = a; subledger = sub; currency }; break walk };
      List.add(rows, {
        account = a; subledger = subView(sub); currency;
        debitsPosted = b.drPosted; creditsPosted = b.crPosted;
        debitsPending = b.drPending; creditsPending = b.crPending;
      });
    };
    { rows = List.toArray(rows); cursor = next; total = List.size(rows) }
  };

  /// L9: posted debits and credits with posting date on or before `asOf`;
  /// the balance as the books stood at the end of that day.
  /// `subledger = null` sums the account across all of its sub-ledgers.
  public func balanceAsOf(state : State, account : T.AccountCode, subledger : ?T.SubledgerKey, ccy : T.Currency, asOf : T.Day) : { debits : Nat; credits : Nat } {
    datedSum(state, state.postingDatedIndex, account, subledger, ccy, asOf)
  };

  /// Posted debits and credits with value date on or before `asOf`;
  /// `subledger = null` sums the account across all of its sub-ledgers.
  public func valueDatedBalance(state : State, account : T.AccountCode, subledger : ?T.SubledgerKey, ccy : T.Currency, asOf : T.Day) : { debits : Nat; credits : Nat } {
    datedSum(state, state.valueDatedIndex, account, subledger, ccy, asOf)
  };

  /// Trial balance: period columns from the period's own postings, closing
  /// columns cumulative over every period whose start is not after this one's.
  public func trialBalance(state : State, periodId : T.PeriodId) : ?T.TrialBalance {
    let ?p = Map.get(state.periods, Text.compare, periodId) else return null;
    // (account, currency) -> row accumulators
    type RowAcc = { var pdr : Nat; var pcr : Nat; var cdr : Nat; var ccr : Nat };
    let rows = Map.empty<(Text, Text), RowAcc>();
    for (((per, account, ccy), acc) in Map.entries(state.periodBalances)) {
      let ?q = Map.get(state.periods, Text.compare, per) else Runtime.trap("JournalCore: balance for unknown period");
      if (q.start <= p.start) {
        let r = switch (Map.get(rows, cmp2, (account, ccy))) {
          case (?r) r;
          case null { let r : RowAcc = { var pdr = 0; var pcr = 0; var cdr = 0; var ccr = 0 }; Map.add(rows, cmp2, (account, ccy), r); r };
        };
        r.cdr += acc.dr; r.ccr += acc.cr;
        if (per == periodId) { r.pdr += acc.dr; r.pcr += acc.cr };
      };
    };
    let totals = Map.empty<Text, RowAcc>();
    let outRows = List.empty<T.TrialBalanceRow>();
    var balanced = true;
    for (((account, ccy), r) in Map.entries(rows)) {
      List.add(outRows, { account; currency = ccy; periodDebits = r.pdr; periodCredits = r.pcr; closingDebits = r.cdr; closingCredits = r.ccr });
      let t = switch (Map.get(totals, Text.compare, ccy)) {
        case (?t) t;
        case null { let t : RowAcc = { var pdr = 0; var pcr = 0; var cdr = 0; var ccr = 0 }; Map.add(totals, Text.compare, ccy, t); t };
      };
      t.pdr += r.pdr; t.pcr += r.pcr; t.cdr += r.cdr; t.ccr += r.ccr;
    };
    let outTotals = List.empty<T.CurrencyTotals>();
    for ((ccy, t) in Map.entries(totals)) {
      if (t.pdr != t.pcr or t.cdr != t.ccr) balanced := false;
      List.add(outTotals, { currency = ccy; periodDebits = t.pdr; periodCredits = t.pcr; closingDebits = t.cdr; closingCredits = t.ccr });
    };
    let postingCount = periodPostingCount(state, periodId);
    ?{ period = periodId; rows = List.toArray(outRows); totals = List.toArray(outTotals); balanced; postingCount }
  };

  public func mappedTrialBalance(state : State, periodId : T.PeriodId) : ?T.MappedTrialBalance {
    switch (trialBalance(state, periodId)) {
      case (?tb) ?Leadsheet.mapTrialBalance(state.leadsheet, tb);
      case null null;
    }
  };

  /// General ledger for a period: the trial balance grouped by account with
  /// every posted leg listed. `account = null` returns all accounts.
  public func generalLedger(state : State, blocks : Blocks, periodId : T.PeriodId, account : ?T.AccountCode) : ?T.GeneralLedger {
    let ?tb = trialBalance(state, periodId) else return null;
    let entries = Map.empty<(Text, Text), List.List<T.GlEntry>>();
    var entryCount = 0;
    // A period's postings, from the stable index rather than from a heap list that grew with every
    // posting. The fold itself is bounded by the caller: `Bank.generalLedger` refuses a period holding
    // more postings than one fold is allowed.
    let periodIndices = periodPostingIndices(state, periodId);
    label fold {
      for (idx in periodIndices.vals()) {
          let ?m = postingMeta(state, blocks, idx) else Runtime.trap("JournalCore: period posting missing");
          let ?eff = m.effective else Runtime.trap("JournalCore: posted posting without effective dates");
          for (l in m.record.legs.vals()) {
            let wanted = switch (account) { case null true; case (?a) a == l.account };
            if (wanted) {
              let counterparts = List.empty<Text>();
              for (o in m.record.legs.vals()) {
                if (o.currency == l.currency and o.side != l.side) List.add(counterparts, o.account);
              };
              let lst2 = switch (Map.get(entries, cmp2, (l.account, l.currency))) {
                case (?e) e;
                case null { let e = List.empty<T.GlEntry>(); Map.add(entries, cmp2, (l.account, l.currency), e); e };
              };
              List.add(lst2, {
                index = idx; postingDate = eff.postingDate; valueDate = eff.valueDate; subledger = l.subledger; side = l.side; amount = l.amount;
                narration = m.record.narration; sourceRef = m.record.sourceRef; counterparts = List.toArray(counterparts);
              });
            entryCount += 1;
          };
        };
      };
    };
    let accounts = List.empty<T.GlAccount>();
    for (row in tb.rows.vals()) {
      let wanted = switch (account) { case null true; case (?a) a == row.account };
      if (wanted) {
        let es = switch (Map.get(entries, cmp2, (row.account, row.currency))) { case (?e) List.toArray(e); case null [] };
        // closing figures include the period's own figures by construction (INV-J3)
        if (row.closingDebits < row.periodDebits or row.closingCredits < row.periodCredits) Runtime.trap("JournalCore: INV-J3 closing below period figures");
        List.add(accounts, {
          account = row.account; currency = row.currency;
          openingDebits = row.closingDebits - row.periodDebits : Nat; openingCredits = row.closingCredits - row.periodCredits : Nat;
          entries = es;
          periodDebits = row.periodDebits; periodCredits = row.periodCredits;
          closingDebits = row.closingDebits; closingCredits = row.closingCredits;
        });
      };
    };
    ?{ period = periodId; accounts = List.toArray(accounts); entryCount }
  };

  /// Posted posting indices booked in a period, in booking order.
  public func periodPostingIndices(state : State, periodId : T.PeriodId) : [Nat] {
    let (lo, hi) = periodPostingEnds(state, periodId);
    let out = List.empty<Nat>();
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(state.periodPostingIndex, lo, hi, cursor, 1_000);
      for ((k, _) in page.entries.vals()) { List.add(out, beNat(Blob.toArray(k), 4, 8)) };
      switch (page.cursor) { case (?c) { cursor := ?c }; case null break walk };
    };
    List.toArray(out)
  };

  /// A period's posting indices, paged. The cursor is the **posting number** to resume at, not a
  /// position: the index is sorted by it, so resuming is a seek. A posting number is also stable where
  /// a position is not, which is what a caller wants across a period that is still being posted to.
  public type PostingIndexPage = { indices : [Nat]; cursor : ?Nat; total : Nat };

  public func periodPostingIndicesPaged(state : State, periodId : T.PeriodId, cursor : Nat, limit : Nat) : PostingIndexPage {
    let n = pageLimit(limit);
    let total = periodPostingCount(state, periodId);
    let (lo, hi) = periodPostingEnds(state, periodId);
    let from = if (cursor == 0) lo else periodPostingKey(state, periodId, cursor);
    let page = RI.range(state.periodPostingIndex, from, hi, null, n);
    let out = List.empty<Nat>();
    for ((k, _) in page.entries.vals()) { List.add(out, beNat(Blob.toArray(k), 4, 8)) };
    let next = switch (page.cursor) { case (?c) ?beNat(Blob.toArray(c), 4, 8); case null null };
    { indices = List.toArray(out); cursor = next; total }
  };

  public func effectiveResolution(state : State, blocks : Blocks, index : Nat) : ?T.Resolution {
    // For an immediate posting `effective` is the record's own dates, so this needs the log; for a
    // resolved pending the row carries them. The caller supplies the log either way.
    switch (postingRow(state, index)) {
      case null null;
      case (?row) {
        if (row.status == STATUS_FROM_PENDING) row.resolution
        else if (row.status == STATUS_POSTED) {
          let rec = loggedRecord(blocks, index);
          ?{ postingDate = rec.postingDate; valueDate = rec.valueDate; valueDateRequested = rec.valueDateRequested; period = rec.period }
        } else null
      };
    }
  };

  /// SHA-256 over a canonical serialisation of the derived state. Two states
  /// with the same fingerprint have the same accounts, currencies, periods,
  /// balances, posting statuses, pendings, idempotency table and gate.
  public func fingerprint(state : State) : Blob {
    let w = C.Writer();
    w.principal(state.admin);
    w.nat64(state.activationHeight);
    w.nat(state.height);
    w.nat(state.postedCount);
    w.nat(state.voidedCount);
    for ((p, _) in Map.entries(state.posters)) { w.principal(p) };
    for ((p, scope) in Map.entries(state.posterScopes)) { w.principal(p); w.len16(scope.size()); for (a in scope.vals()) { w.text(a) } };
    for (((acct, sub, ccy), l) in Map.entries(state.balanceLimits)) {
      w.text(acct); w.blob(sub); w.text(ccy);
      switch (l) {
        case (#none) w.byte(0);
        case (#debitsNotExceedCreditsPlus(n)) { w.byte(1); w.nat(n) };
        case (#creditsNotExceedDebitsPlus(n)) { w.byte(2); w.nat(n) };
      };
    };
    for ((code, a) in Map.entries(state.accountAttributes)) {
      w.text(code); w.byte(switch (a.usage) { case (#header) 0; case (#detail) 1 }); w.bool(a.manualEntriesAllowed);
      switch (a.parent) { case null w.byte(0); case (?p2) { w.byte(1); w.text(p2) } };
    };
    for ((code, mu) in Map.entries(state.currencies)) { w.text(code); w.nat8(mu) };
    for ((_, a) in Map.entries(state.accounts)) {
      w.text(a.code); w.text(a.name); w.side(a.normalSide); w.category(a.category); w.constraint(a.constraint);
      w.bool(a.status == #active); w.nat(a.openedAtBlock); w.optNat(a.closedAtBlock);
    };
    for ((_, p) in Map.entries(state.periods)) {
      w.text(p.id); w.nat(p.start); w.nat(p.end); w.bool(p.status == #open); w.nat(p.openedAtBlock); w.optNat(p.closedAtBlock);
    };
    for (((a, sub, c), b) in Map.entries(state.balances)) { w.text(a); w.blob(sub); w.text(c); w.nat(b.drPosted); w.nat(b.crPosted); w.nat(b.drPending); w.nat(b.crPending) };
    for (((p, a, c), acc) in Map.entries(state.periodBalances)) { w.text(p); w.text(a); w.text(c); w.nat(acc.dr); w.nat(acc.cr) };
    // The indexes in stable memory; the two dated indexes, the period index, the posting rows, the
    // correctors, the duplicate-rejection index; each enter as its row digest (`RegionIndex`
    // improvement 5: the sum of the rows' hashes, maintained at every `put`) with its size, not as a
    // walk of its rows: the walk was O(postings), and exceeded one message at a fifty-thousand-deal
    // book. Two states holding the same rows write the same words; a row that differs in one byte
    // moves its index's word.
    //
    // The **records** are no longer part of this fingerprint, and deliberately so. A fingerprint
    // answers "did a replay produce the same derived state"; a record is not derived state, it is the
    // log, and the log is already covered twice over by the block hash chain and by the MMR root the
    // contract certifies. Writing it here was a second copy of a thing already proven, and an O(n)
    // read of every record to prove it.
    for (idx in [state.valueDatedIndex, state.postingDatedIndex, state.periodPostingIndex, state.postingRows, state.correctors, state.idempotencyIndex].vals()) {
      w.nat(RI.size(idx)); w.blobRaw(RI.digest(idx));
    };
    w.nat(state.postingRowCount);
    w.nat(state.idempotencyCount);
    w.len16(state.leadsheet.size());
    for (r in state.leadsheet.vals()) { w.range(r) };
    w.optNat(state.businessDate);
    w.calendar(state.calendar);
    w.byte(switch (authorityOf(state)) { case (#substrateClock) 0; case (#businessDate) 1 });
    w.nat(rollBoundOf(state));
    let d = Sha256.Digest(#sha256);
    d.writeArray(w.toArray());
    d.sum()
  };
};
