/// Packing.mo; closed-month packing: a closed range of the journal packed, its index rows replaced
/// by one summary row per account and a delta-coded list, its aggregates rolled up, in chunks.
///
/// The unit is a **pack**: the journal blocks from the block after the last pack's end up to the
/// block that closed a period. Opening one is a dual-authorised command whose gate is the bank's:
/// the period is closed, and its last day is older than every window a rule could read and than
/// the dedup window that keeps a duplicate submission refused (`OpenGate`). Advancing one is an
/// open method, like the end-of-day batch's: the plan is fixed when the pack opens, every advance
/// does a bounded amount of it, and the state after a crash is the state to resume from.
///
/// The phases, in order:
///
///   1. **encoding**; the range in segments of at most `SEGMENT_BLOCKS` blocks, each a
///      self-contained `Pack` (its own dictionaries) that has already round-tripped byte for byte
///      before it is stored; per segment, each account's postings as a delta-coded list
///      (`Pack.AccountEntry`), written to the pack's store beside the segment;
///   2. **consolidating**; an account's per-segment lists merged into one list and one summary
///      row per (account, pack): count, debits, credits, and where the list is;
///   3. **rebuilding**; the ten per-posting indexes replaced by generations without the packed
///      rows (`RegionRebuild`): the five posting indexes and the journal's idempotency keys by
///      posting number, the four activity indexes by day, the latter rolled up into monthly rows as
///      they go;
///   4. **sealed**; the pack's row written, the boundary moved, the next pack allowed.
///
/// A pack's bytes live in a store of their own (`RegionStore`), one region a pack, taken from a
/// pool: when a pack has rolled to an archive its store is reset and the next pack fills it, so
/// the live contract's regions are bounded by the packs it has not yet rolled.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Sha256 "mo:sha2/Sha256";

import JT "mo:journal/JournalTypes";
import RI "mo:ledger/RegionIndex";

import PIdx "PostingIndex";
import PT "PackingTypes";
import Activity "Activity";
import Pack "Pack";
import BankPack "BankPack";
import Store "RegionStore";
import R "StableRows";

module {

  public let SEGMENT_BLOCKS : Nat = 2_000;
  public let MAX_ADVANCE : Nat = 20_000;
  /// A duplicate submission is refused for at least this long after the posting it duplicates: the
  /// idempotency keys of a packed range are dropped, so a range is packed only once its last day is
  /// this far behind the business date.
  public let DEDUP_WINDOW_DAYS : Nat = 92;

  public type Phase = { #encoding; #bankEncoding; #consolidating; #rebuilding : Nat; #sealed };

  /// The ten indexes a pack rebuilds, in order.
  public let REBUILDS : [Text] = ["headers", "byAccount", "byDay", "byCurrency", "byClass", "activity", "edges", "edgesOut", "edgesIn", "idempotency"];

  public type Job = {
    pack : Nat;
    period : JT.PeriodId;
    periodOrd : Nat;
    periodEnd : Nat;
    lo : Nat;
    hi : Nat;
    /// the bank's own range (§18.3): blocks `bankLo … bankHi`, encoded after the journal's
    bankLo : Nat;
    bankHi : Nat;
    var bankNext : Nat;
    var bankSegments : Nat;
    var bankPackedBytes : Nat;
    var bankRawBytes : Nat;
    var bankDropped : Nat;
    var bankKept : Nat;
    /// the bank segments' store: taken from the same pool, but not released by the journal's roll; the
    /// bank's blocks stay readable here until a roll of their own carries them
    bankStoreIx : Nat;
    storeIx : Nat;
    var next : Nat;
    var segments : Nat;
    var postings : Nat;
    var packedBytes : Nat;
    var rawBytes : Nat;
    var minDay : Nat;
    var maxDay : Nat;
    var phase : Phase;
    var consolidateCursor : ?Blob;
    var accountsPacked : Nat;
    segmentHashes : List.List<Blob>;
  };

  /// A sealed pack, as the reads see it.
  public type PackRow = {
    pack : Nat;
    period : JT.PeriodId;
    periodOrd : Nat;
    periodEnd : Nat;
    lo : Nat;
    hi : Nat;
    segments : Nat;
    postings : Nat;
    accounts : Nat;
    packedBytes : Nat;
    rawBytes : Nat;
    minDay : Nat;
    maxDay : Nat;
    bankLo : Nat;
    bankHi : Nat;
    bankSegments : Nat;
    bankPackedBytes : Nat;
    bankRawBytes : Nat;
    bankDropped : Nat;
    bankKept : Nat;
    bankStoreIx : Nat;
    var bankArchived : Bool;
    /// SHA-256 over the segment hashes in order (the journal's, then the bank's): what the archive is registered against.
    sha256 : Blob;
    storeIx : Nat;
    var archived : Bool;
  };

  public type Segment = { pack : Nat; seq : Nat; lo : Nat; hi : Nat; offset : Nat; bytes : Nat; rawBytes : Nat; postings : Nat; sha256 : Blob };
  /// A segment of bank blocks: `dropped` is the count of proposal bodies the rule let go, `kept` the rest.
  public type BankSegment = { pack : Nat; seq : Nat; lo : Nat; hi : Nat; offset : Nat; bytes : Nat; rawBytes : Nat; dropped : Nat; kept : Nat; sha256 : Blob };

  /// `count(4) ‖ debits(16) ‖ credits(16) ‖ offset(8) ‖ len(4)`; 48 bytes.
  public let ACCOUNT_ROW : Nat = 48;
  public let SEGMENT_ROW : Nat = 76;   // lo(8) hi(8) offset(8) bytes(4) rawBytes(8) postings(8) sha256(32)
  public let BANK_SEGMENT_ROW : Nat = 84;   // lo(8) hi(8) offset(8) bytes(4) rawBytes(8) dropped(8) kept(8) sha256(32)

  public type State = {
    /// The pack stores: one region a pack, pooled; reset for the next pack once its pack has
    /// rolled to an archive.
    stores : List.List<Store.State>;
    /// The consolidated account lists, never reset: what the live contract keeps of a packed
    /// month after its segments have left.
    lists : Store.State;
    packs : Map.Map<Nat, PackRow>;
    segments : RI.State;            // pack(8) ‖ seq(4) -> SEGMENT_ROW
    bankSegments : RI.State;        // pack(8) ‖ seq(4) -> BANK_SEGMENT_ROW, the bank's segments of the pack
    /// pack(8) ‖ acct(8) ‖ seq(4) -> ACCOUNT_ROW, the per-segment rows, reset after consolidation
    segmentAccounts : RI.State;
    /// acct(8) ‖ pack(8) -> ACCOUNT_ROW, the summary row per account and pack
    packedAccounts : RI.State;
    var current : ?Job;
    var nextPack : Nat;
    var packedThroughBlock : Nat;
    var packedThroughDay : Nat;
    /// the bank log is packed through this block (§18.3); reads below the log's base come from the packs
    var bankPackedThroughBlock : Nat;
    /// stores taken by an opening in progress, so two takes in one opening never coincide
    reservedStores : List.List<Nat>;
  };

  public func newState(arena : RI.Arena) : State {
    {
      stores = List.empty<Store.State>();
      lists = Store.newState();
      packs = Map.empty<Nat, PackRow>();
      segments = RI.newStateIn(arena, { keyBytes = 12; valBytes = SEGMENT_ROW });
      bankSegments = RI.newStateIn(arena, { keyBytes = 12; valBytes = BANK_SEGMENT_ROW });
      segmentAccounts = RI.newStateIn(arena, { keyBytes = 20; valBytes = ACCOUNT_ROW });
      packedAccounts = RI.newStateIn(arena, { keyBytes = 16; valBytes = ACCOUNT_ROW });
      var current = null;
      var nextPack = 1;
      var packedThroughBlock = 0;
      var bankPackedThroughBlock = 0;
      reservedStores = List.empty<Nat>();
      var packedThroughDay = 0;
    }
  };

  public type Error = PT.Error;

  // ─── rows ─────────────────────────────────────────────────────────────────

  type AccountRow = { count : Nat; debits : Nat; credits : Nat; offset : Nat; len : Nat };

  func encodeAccountRow(r : AccountRow) : Blob {
    let b = R.buf();
    R.putNat(b, r.count, 4); R.putNat(b, r.debits, 16); R.putNat(b, r.credits, 16); R.putNat(b, r.offset, 8); R.putNat(b, r.len, 4);
    R.done(b, ACCOUNT_ROW)
  };
  func decodeAccountRow(v : Blob) : AccountRow {
    let a = Blob.toArray(v);
    { count = R.getNat(a, 0, 4); debits = R.getNat(a, 4, 16); credits = R.getNat(a, 20, 16); offset = R.getNat(a, 36, 8); len = R.getNat(a, 44, 4) }
  };
  func encodeSegmentRow(sg : Segment) : Blob {
    let b = R.buf();
    R.putNat(b, sg.lo, 8); R.putNat(b, sg.hi, 8); R.putNat(b, sg.offset, 8); R.putNat(b, sg.bytes, 4); R.putNat(b, sg.rawBytes, 8); R.putNat(b, sg.postings, 8); R.putBlob(b, sg.sha256, 32);
    R.done(b, SEGMENT_ROW)
  };
  func decodeSegment(pack : Nat, seq : Nat, v : Blob) : Segment {
    let a = Blob.toArray(v);
    { pack; seq; lo = R.getNat(a, 0, 8); hi = R.getNat(a, 8, 8); offset = R.getNat(a, 16, 8); bytes = R.getNat(a, 24, 4); rawBytes = R.getNat(a, 28, 8); postings = R.getNat(a, 36, 8); sha256 = R.getBlob(a, 44, 32) }
  };

  func storeOf(s : State, ix : Nat) : Store.State {
    switch (List.get(s.stores, ix)) { case (?st) st; case null Runtime.trap("Packing: no store " # Nat.toText(ix)) }
  };

  /// A store for a new pack: one whose pack has been archived, else a new region. A pack's journal store is
  /// free once its pack rolled; its bank store once the bank segments rolled (never, until a roll of their
  /// own exists: §18.3). `reservedStores` are the indices an opening has taken before it is installed.
  func takeStore(s : State) : Nat {
    var ix = 0;
    let taken = List.empty<Nat>();
    for ((_, p) in Map.entries(s.packs)) { if (not p.archived) List.add(taken, p.storeIx); if (not p.bankArchived) List.add(taken, p.bankStoreIx) };
    switch (s.current) { case (?j) { List.add(taken, j.storeIx); List.add(taken, j.bankStoreIx) }; case null {} };
    for (t in List.values(s.reservedStores)) List.add(taken, t);
    while (ix < List.size(s.stores)) {
      var used = false;
      for (t in List.values(taken)) { if (t == ix) used := true };
      if (not used) { Store.reset(storeOf(s, ix)); List.add(s.reservedStores, ix); return ix };
      ix += 1;
    };
    List.add(s.stores, Store.newState());
    List.add(s.reservedStores, List.size(s.stores) - 1);
    List.size(s.stores) - 1
  };

  // ─── what the engine reads and writes ─────────────────────────────────────

  public type Context = {
    pidx : PIdx.State;
    activity : Activity.State;
    rawBlock : Nat -> ?Blob;
    blockOf : Nat -> ?JT.Block;
    /// The bank log's stored bytes of a block, and the bytes to keep of them (the same, or the preimage
    /// and hash with the empty trailer when §18.2's rule lets a proposal's body go); the bank's rule,
    /// applied by the bank, so this module does not read proposals.
    rawBankBlock : Nat -> ?Blob;
    bankKeep : (Nat, Blob) -> Blob;
    /// The journal's idempotency rebuild, as three closures so this module does not own the journal.
    idemBegin : Nat -> Bool;
    idemStep : Nat -> { examined : Nat; done : Bool };
    idemFinish : () -> Bool;
  };

  /// Open a pack over `[lo, hi]` for a period. The caller has checked the gate (`OpenGate`).
  public func open(s : State, period : JT.PeriodId, periodOrd : Nat, periodEnd : Nat, hi : Nat, bankLo : Nat, bankHi : Nat) : Result.Result<Job, Error> {
    switch (s.current) { case (?j) return #err(#PackingInProgress({ pack = j.pack })); case null {} };
    let lo = s.packedThroughBlock + (if (Map.size(s.packs) == 0 and s.packedThroughBlock == 0) 0 else 1);
    if (hi < lo) return #err(#NothingToPack({ period }));
    if (bankHi < bankLo) return #err(#NothingToPack({ period }));
    let job : Job = {
      pack = s.nextPack; period; periodOrd; periodEnd; lo; hi; bankLo; bankHi; storeIx = takeStore(s); bankStoreIx = takeStore(s);
      var bankNext = bankLo; var bankSegments = 0; var bankPackedBytes = 0; var bankRawBytes = 0; var bankDropped = 0; var bankKept = 0;
      var next = lo; var segments = 0; var postings = 0; var packedBytes = 0; var rawBytes = 0;
      var minDay = 0xFFFF_FFFF; var maxDay = 0; var phase = #encoding; var consolidateCursor = null; var accountsPacked = 0;
      segmentHashes = List.empty<Blob>();
    };
    s.current := ?job;
    List.clear(s.reservedStores);
    s.nextPack += 1;
    #ok(job)
  };

  public type Advance = {
    pack : Nat;
    phase : Text;
    /// Blocks encoded, rows consolidated or entries examined, whichever the phase does.
    work : Nat;
    sealed : Bool;
    segment : ?Segment;
    bankSegment : ?BankSegment;
  };

  public func phaseText(p : Phase) : Text {
    switch (p) { case (#encoding) "encoding"; case (#bankEncoding) "bankEncoding"; case (#consolidating) "consolidating"; case (#rebuilding(k)) "rebuilding:" # (if (k < REBUILDS.size()) REBUILDS[k] else "?"); case (#sealed) "sealed" }
  };

  /// One bounded step of the open pack.
  public func advance(s : State, ctx : Context, limit : Nat) : Result.Result<Advance, Error> {
    let ?job = s.current else return #err(#NotPacking);
    let n = if (limit == 0 or limit > MAX_ADVANCE) MAX_ADVANCE else limit;
    switch (job.phase) {
      case (#encoding) encodeSegment(s, ctx, job, n);
      case (#bankEncoding) encodeBankSegment(s, ctx, job, n);
      case (#consolidating) consolidate(s, job, n);
      case (#rebuilding(k)) rebuild(s, ctx, job, k, n);
      case (#sealed) #err(#NotPacking);
    }
  };

  // ─── phase 1: encoding ────────────────────────────────────────────────────

  func encodeSegment(s : State, ctx : Context, job : Job, limit : Nat) : Result.Result<Advance, Error> {
    let lo = job.next;
    let hi = Nat.min(job.hi, lo + Nat.min(limit, SEGMENT_BLOCKS) - 1);
    let stored = List.empty<Pack.Stored>();
    var i = lo;
    while (i <= hi) {
      let ?raw = ctx.rawBlock(i) else return #err(#Codec({ block = i; reason = "the log has no block" }));
      let ?block = ctx.blockOf(i) else return #err(#Codec({ block = i; reason = "the log's block does not decode" }));
      List.add(stored, { raw; block });
      i += 1;
    };
    let packed = switch (Pack.pack(List.toArray(stored))) { case (#err(why)) return #err(#Codec({ block = lo; reason = why })); case (#ok(p)) p };
    let store = storeOf(s, job.storeIx);
    let offset = Store.append(store, packed.bytes);
    let hash = Sha256.fromBlob(#sha256, packed.bytes);
    // the per-account lists of this segment: posted activity, as the aggregates read it
    let perAccount = Map.empty<Nat, List.List<Pack.AccountEntry>>();
    let order = List.empty<Nat>();
    var postings = 0;
    for (st in List.values(stored)) {
      let (rec, postingNo, day, postingDay) : (?JT.PostingRecord, Nat, Nat, Nat) = switch (st.block.event) {
        case (#posted(r)) (?r, st.block.index, r.valueDate, r.postingDate);
        case (#post(x)) {
          switch (ctx.blockOf(x.pendingIndex)) {
            case (?pb) { switch (pb.event) { case (#pending(p)) (?p.record, x.pendingIndex, x.resolution.valueDate, x.resolution.postingDate); case (_) (null, 0, 0, 0) } };
            case null (null, 0, 0, 0);
          }
        };
        case (_) (null, 0, 0, 0);
      };
      switch (rec) {
        case (?r) {
          postings += 1;
          if (day < job.minDay) job.minDay := day;
          if (day > job.maxDay) job.maxDay := day;
          let posted = Activity.derive(r, postingNo, day, func(sub : JT.SubledgerKey) : ?Nat { PIdx.accountOf(ctx.pidx, sub) });
          for (a in posted.accounts.vals()) {
            let l = switch (Map.get(perAccount, Nat.compare, a.account)) {
              case (?l) l;
              case null { let l = List.empty<Pack.AccountEntry>(); Map.add(perAccount, Nat.compare, a.account, l); List.add(order, a.account); l };
            };
            List.add(l, { posting = postingNo; valueDay = day; postingDay; debits = a.debits; credits = a.credits });
          };
        };
        case null {};
      };
    };
    for (acct in List.values(order)) {
      let ?l = Map.get(perAccount, Nat.compare, acct) else Runtime.trap("Packing: an account that was just listed is missing");
      // a resolved pending's number is below this segment's blocks and may be out of order: sort
      let entries = Array.sort<Pack.AccountEntry>(List.toArray(l), func(x, y) { Nat.compare(x.posting, y.posting) });
      var dr = 0; var cr = 0;
      for (e in entries.vals()) { dr += e.debits; cr += e.credits };
      let bytes = Pack.encodeAccountList(entries);
      let at = Store.append(store, bytes);
      ignore RI.put(s.segmentAccounts, segKey(job.pack, acct, job.segments), encodeAccountRow({ count = entries.size(); debits = dr; credits = cr; offset = at; len = bytes.size() }));
    };
    let segment : Segment = { pack = job.pack; seq = job.segments; lo; hi; offset; bytes = packed.bytes.size(); rawBytes = packed.rawBytes; postings; sha256 = hash };
    ignore RI.put(s.segments, R.key2(job.pack, 8, job.segments, 4), encodeSegmentRow(segment));
    List.add(job.segmentHashes, hash);
    job.segments += 1;
    job.postings += postings;
    job.packedBytes += packed.bytes.size();
    job.rawBytes += packed.rawBytes;
    job.next := hi + 1;
    if (job.next > job.hi) job.phase := #bankEncoding;
    #ok({ pack = job.pack; phase = "encoding"; work = hi + 1 - lo; sealed = false; segment = ?segment; bankSegment = null })
  };

  // ─── phase 1b: the bank's blocks (§18.3) ──────────────────────────────────

  func encodeBankSegment(s : State, ctx : Context, job : Job, limit : Nat) : Result.Result<Advance, Error> {
    let lo = job.bankNext;
    let hi = Nat.min(job.bankHi, lo + Nat.min(limit, SEGMENT_BLOCKS) - 1);
    let entries = List.empty<BankPack.Entry>();
    var dropped = 0;
    var kept = 0;
    var rawBytes = 0;
    var i = lo;
    while (i <= hi) {
      let ?raw = ctx.rawBankBlock(i) else return #err(#Codec({ block = i; reason = "the bank log has no block" }));
      let keep = ctx.bankKeep(i, raw);
      if (keep.size() != raw.size()) dropped += 1 else kept += 1;
      rawBytes += raw.size();
      List.add(entries, { raw; keep });
      i += 1;
    };
    let packed = switch (BankPack.pack(lo, List.toArray(entries))) { case (#err(why)) return #err(#Codec({ block = lo; reason = why })); case (#ok(p)) p };
    let store = storeOf(s, job.bankStoreIx);
    let offset = Store.append(store, packed.bytes);
    let hash = Sha256.fromBlob(#sha256, packed.bytes);
    let segment : BankSegment = { pack = job.pack; seq = job.bankSegments; lo; hi; offset; bytes = packed.bytes.size(); rawBytes; dropped; kept; sha256 = hash };
    ignore RI.put(s.bankSegments, R.key2(job.pack, 8, job.bankSegments, 4), encodeBankSegmentRow(segment));
    List.add(job.segmentHashes, hash);
    job.bankSegments += 1;
    job.bankPackedBytes += packed.bytes.size();
    job.bankRawBytes += rawBytes;
    job.bankDropped += dropped;
    job.bankKept += kept;
    job.bankNext := hi + 1;
    if (job.bankNext > job.bankHi) job.phase := #consolidating;
    #ok({ pack = job.pack; phase = "bankEncoding"; work = hi + 1 - lo; sealed = false; segment = null; bankSegment = ?segment })
  };

  func encodeBankSegmentRow(g : BankSegment) : Blob {
    let b = R.buf();
    R.putNat(b, g.lo, 8); R.putNat(b, g.hi, 8); R.putNat(b, g.offset, 8); R.putNat(b, g.bytes, 4); R.putNat(b, g.rawBytes, 8); R.putNat(b, g.dropped, 8); R.putNat(b, g.kept, 8); R.putBlob(b, g.sha256, 32);
    R.done(b, BANK_SEGMENT_ROW)
  };
  func decodeBankSegmentRow(pack : Nat, seq : Nat, v : Blob) : BankSegment {
    let a = Blob.toArray(v);
    { pack; seq; lo = R.getNat(a, 0, 8); hi = R.getNat(a, 8, 8); offset = R.getNat(a, 16, 8); bytes = R.getNat(a, 24, 4); rawBytes = R.getNat(a, 28, 8); dropped = R.getNat(a, 36, 8); kept = R.getNat(a, 44, 8); sha256 = R.getBlob(a, 52, 32) }
  };

  func segKey(pack : Nat, acct : Nat, seq : Nat) : Blob {
    let b = R.buf();
    R.putNat(b, pack, 8); R.putNat(b, acct, 8); R.putNat(b, seq, 4);
    R.done(b, 20)
  };

  // ─── phase 2: consolidating ───────────────────────────────────────────────

  func consolidate(s : State, job : Job, limit : Nat) : Result.Result<Advance, Error> {
    let (lo, hi) = R.prefixRange(job.pack, 8, 12);
    let page = RI.range(s.segmentAccounts, lo, hi, job.consolidateCursor, limit);
    var rows = 0;
    var i = 0;
    let store = storeOf(s, job.storeIx);
    while (i < page.entries.size()) {
      // gather this account's rows; an account whose rows straddle the page boundary is finished
      // on the next advance; the cursor stops before it
      let acct = R.getNat(Blob.toArray(page.entries[i].0), 8, 8);
      var j = i;
      while (j < page.entries.size() and R.getNat(Blob.toArray(page.entries[j].0), 8, 8) == acct) j += 1;
      if (j == page.entries.size() and page.cursor != null) {
        // the account may continue in the next B-tree page: leave it for the next advance
        job.consolidateCursor := ?page.entries[i].0;
        return #ok({ pack = job.pack; phase = "consolidating"; work = rows; sealed = false; segment = null; bankSegment = null });
      };
      let merged = List.empty<Pack.AccountEntry>();
      var dr = 0; var cr = 0;
      var k = i;
      while (k < j) {
        let row = decodeAccountRow(page.entries[k].1);
        let ?entries = Pack.decodeAccountList(Store.read(store, row.offset, row.len)) else return #err(#Codec({ block = 0; reason = "a segment list of the pack does not decode" }));
        for (e in entries.vals()) List.add(merged, e);
        dr += row.debits; cr += row.credits;
        rows += 1;
        k += 1;
      };
      // a later segment can resolve a pending whose number is below an earlier one's: sort
      let bytes = Pack.encodeAccountList(Array.sort<Pack.AccountEntry>(List.toArray(merged), func(x, y) { Nat.compare(x.posting, y.posting) }));
      let at = Store.append(s.lists, bytes);
      ignore RI.put(s.packedAccounts, R.key2(acct, 8, job.pack, 8), encodeAccountRow({ count = List.size(merged); debits = dr; credits = cr; offset = at; len = bytes.size() }));
      job.accountsPacked += 1;
      i := j;
    };
    switch (page.cursor) {
      case (?c) { job.consolidateCursor := ?c };
      case null {
        // the per-segment rows are dead: the index holds only this pack's, so it is emptied and its
        // pages wait for the next pack
        RI.reset(s.segmentAccounts);
        job.phase := #rebuilding(0);
      };
    };
    #ok({ pack = job.pack; phase = "consolidating"; work = rows; sealed = false; segment = null; bankSegment = null })
  };

  // ─── phase 3: rebuilding ──────────────────────────────────────────────────

  func rebuild(s : State, ctx : Context, job : Job, k : Nat, limit : Nat) : Result.Result<Advance, Error> {
    if (k >= REBUILDS.size()) return seal(s, ctx, job);
    let name = REBUILDS[k];
    // begin if nothing is in progress for this index
    let began = switch (k) {
      case 0 { switch (PIdx.rebuildInProgress(ctx.pidx)) { case (?_) true; case null PIdx.beginRebuild(ctx.pidx, #headers, job.hi, job.periodEnd) } };
      case 1 { switch (PIdx.rebuildInProgress(ctx.pidx)) { case (?_) true; case null PIdx.beginRebuild(ctx.pidx, #byAccount, job.hi, job.periodEnd) } };
      case 2 { switch (PIdx.rebuildInProgress(ctx.pidx)) { case (?_) true; case null PIdx.beginRebuild(ctx.pidx, #byDay, job.hi, job.periodEnd) } };
      case 3 { switch (PIdx.rebuildInProgress(ctx.pidx)) { case (?_) true; case null PIdx.beginRebuild(ctx.pidx, #byCurrency, job.hi, job.periodEnd) } };
      case 4 { switch (PIdx.rebuildInProgress(ctx.pidx)) { case (?_) true; case null PIdx.beginRebuild(ctx.pidx, #byClass, job.hi, job.periodEnd) } };
      case 5 { switch (Activity.rebuildInProgress(ctx.activity)) { case (?_) true; case null Activity.beginRebuild(ctx.activity, #activity, job.periodEnd, job.periodOrd) } };
      case 6 { switch (Activity.rebuildInProgress(ctx.activity)) { case (?_) true; case null Activity.beginRebuild(ctx.activity, #edges, job.periodEnd, job.periodOrd) } };
      case 7 { switch (Activity.rebuildInProgress(ctx.activity)) { case (?_) true; case null Activity.beginRebuild(ctx.activity, #edgesOut, job.periodEnd, job.periodOrd) } };
      case 8 { switch (Activity.rebuildInProgress(ctx.activity)) { case (?_) true; case null Activity.beginRebuild(ctx.activity, #edgesIn, job.periodEnd, job.periodOrd) } };
      case _ ctx.idemBegin(job.hi);
    };
    if (not began) return #err(#RebuildBusy({ index = name }));
    let step = if (k < 5) PIdx.stepRebuild(ctx.pidx, limit) else if (k < 9) Activity.stepRebuild(ctx.activity, limit) else ctx.idemStep(limit);
    if (step.done) {
      let finished = if (k < 5) (PIdx.finishRebuild(ctx.pidx) != null) else if (k < 9) (Activity.finishRebuild(ctx.activity) != null) else ctx.idemFinish();
      if (not finished) return #err(#RebuildBusy({ index = name }));
      job.phase := #rebuilding(k + 1);
      if (k + 1 >= REBUILDS.size()) return seal(s, ctx, job);
    };
    #ok({ pack = job.pack; phase = "rebuilding:" # name; work = step.examined; sealed = false; segment = null; bankSegment = null })
  };

  // ─── phase 4: sealed ──────────────────────────────────────────────────────

  func seal(s : State, ctx : Context, job : Job) : Result.Result<Advance, Error> {
    let d = Sha256.Digest(#sha256);
    for (h in List.values(job.segmentHashes)) d.writeBlob(h);
    let row : PackRow = {
      pack = job.pack; period = job.period; periodOrd = job.periodOrd; periodEnd = job.periodEnd; lo = job.lo; hi = job.hi;
      segments = job.segments; postings = job.postings; accounts = job.accountsPacked; packedBytes = job.packedBytes; rawBytes = job.rawBytes;
      minDay = if (job.minDay == 0xFFFF_FFFF) 0 else job.minDay; maxDay = job.maxDay;
      bankLo = job.bankLo; bankHi = job.bankHi; bankSegments = job.bankSegments; bankPackedBytes = job.bankPackedBytes; bankRawBytes = job.bankRawBytes; bankDropped = job.bankDropped; bankKept = job.bankKept;
      bankStoreIx = job.bankStoreIx; var bankArchived = false;
      sha256 = d.sum(); storeIx = job.storeIx; var archived = false;
    };
    Map.add(s.packs, Nat.compare, job.pack, row);
    s.packedThroughBlock := job.hi;
    s.bankPackedThroughBlock := job.bankHi;
    if (job.periodEnd > s.packedThroughDay) s.packedThroughDay := job.periodEnd;
    Activity.markRolledUp(ctx.activity, job.periodEnd);
    job.phase := #sealed;
    s.current := null;
    #ok({ pack = job.pack; phase = "sealed"; work = 0; sealed = true; segment = null; bankSegment = null })
  };

  // ─── reads ────────────────────────────────────────────────────────────────

  public type Current = { pack : Nat; period : JT.PeriodId; lo : Nat; hi : Nat; next : Nat; segments : Nat; postings : Nat; phase : Text;
                          bankLo : Nat; bankHi : Nat; bankNext : Nat; bankSegments : Nat };
  public func current(s : State) : ?Current {
    switch (s.current) {
      case (?j) ?{ pack = j.pack; period = j.period; lo = j.lo; hi = j.hi; next = j.next; segments = j.segments; postings = j.postings; phase = phaseText(j.phase);
                   bankLo = j.bankLo; bankHi = j.bankHi; bankNext = j.bankNext; bankSegments = j.bankSegments };
      case null null;
    }
  };

  public type PackView = {
    pack : Nat; period : JT.PeriodId; periodEnd : Nat; lo : Nat; hi : Nat; segments : Nat; postings : Nat; accounts : Nat;
    packedBytes : Nat; rawBytes : Nat; minDay : Nat; maxDay : Nat; sha256 : Blob; archived : Bool;
    bankLo : Nat; bankHi : Nat; bankSegments : Nat; bankPackedBytes : Nat; bankRawBytes : Nat; bankDropped : Nat; bankKept : Nat;
  };

  func view(p : PackRow) : PackView {
    { pack = p.pack; period = p.period; periodEnd = p.periodEnd; lo = p.lo; hi = p.hi; segments = p.segments; postings = p.postings; accounts = p.accounts; packedBytes = p.packedBytes; rawBytes = p.rawBytes; minDay = p.minDay; maxDay = p.maxDay; sha256 = p.sha256; archived = p.archived;
      bankLo = p.bankLo; bankHi = p.bankHi; bankSegments = p.bankSegments; bankPackedBytes = p.bankPackedBytes; bankRawBytes = p.bankRawBytes; bankDropped = p.bankDropped; bankKept = p.bankKept }
  };

  // ─── the bank's packed blocks, read back (§18.3) ──────────────────────────

  /// The bank segments of a pack, in order.
  public func bankSegmentsOf(s : State, pack : Nat) : [BankSegment] {
    let (lo, hi) = R.prefixRange(pack, 8, 4);
    let out = List.empty<BankSegment>();
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.bankSegments, lo, hi, cursor, 500);
      for ((k, v) in page.entries.vals()) List.add(out, decodeBankSegmentRow(pack, R.getNat(Blob.toArray(k), 8, 4), v));
      switch (page.cursor) { case (?c) cursor := ?c; case null break walk };
    };
    List.toArray(out)
  };

  /// A bank segment's bytes, for the verifier and for the archive roll of §18.3.
  public func bankSegmentBytes(s : State, pack : Nat, seq : Nat) : ?Blob {
    let ?p = Map.get(s.packs, Nat.compare, pack) else return null;
    for (g in bankSegmentsOf(s, pack).vals()) { if (g.seq == seq) return ?Store.read(storeOf(s, p.bankStoreIx), g.offset, g.bytes) };
    null
  };

  /// The bank's packed range: through which block the packs answer.
  public func bankPackedThrough(s : State) : Nat { s.bankPackedThroughBlock };

  /// A packed bank block's stored bytes; one read of its segment's offsets table and one of the block;
  /// or null when no sealed pack holds the block (a block above the packed range, or one that has rolled).
  public func bankBlock(s : State, index : Nat) : ?Blob {
    if (Map.size(s.packs) == 0 or index > s.bankPackedThroughBlock) return null;
    for ((_, p) in Map.entries(s.packs)) {
      if (index >= p.bankLo and index <= p.bankHi and not p.bankArchived) {
        for (g in bankSegmentsOf(s, p.pack).vals()) {
          if (index >= g.lo and index <= g.hi) {
            let store = storeOf(s, p.bankStoreIx);
            let head = Store.read(store, g.offset, BankPack.tableBytes(g.hi + 1 - g.lo));
            let ?at = BankPack.locate(head, g.bytes, index) else return null;
            return ?Store.read(store, g.offset + at.offset, at.length);
          };
        };
        return null;
      };
    };
    null
  };

  public func getPack(s : State, pack : Nat) : ?PackView { switch (Map.get(s.packs, Nat.compare, pack)) { case (?p) ?view(p); case null null } };

  /// One page of the packs, by number from a cursor (inclusive).
  public func packsFrom(s : State, cursor : ?Nat, limit : Nat) : { rows : [PackView]; next : ?Nat } {
    let rows = List.empty<PackView>();
    let it = switch (cursor) { case (?c) Map.entriesFrom(s.packs, Nat.compare, c); case null Map.entries(s.packs) };
    for ((k, p) in it) { if (List.size(rows) >= limit) return { rows = List.toArray(rows); next = ?k }; List.add(rows, view(p)) };
    { rows = List.toArray(rows); next = null }
  };
  public func packCount(s : State) : Nat { Map.size(s.packs) };
  public func listPacks(s : State) : [PackView] {
    let out = List.empty<PackView>();
    for ((_, p) in Map.entries(s.packs)) List.add(out, view(p));
    List.toArray(out)
  };

  public func packedThrough(s : State) : { block : Nat; day : Nat } { { block = s.packedThroughBlock; day = s.packedThroughDay } };

  public func segmentsOf(s : State, pack : Nat) : [Segment] {
    let (lo, hi) = R.prefixRange(pack, 8, 4);
    let out = List.empty<Segment>();
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.segments, lo, hi, cursor, 500);
      for ((k, v) in page.entries.vals()) List.add(out, decodeSegment(pack, R.getNat(Blob.toArray(k), 8, 4), v));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };

  public func segment(s : State, pack : Nat, seq : Nat) : ?Segment {
    switch (RI.get(s.segments, R.key2(pack, 8, seq, 4))) { case (?v) ?decodeSegment(pack, seq, v); case null null }
  };

  /// A segment's bytes; what an archive is given, and what a reader unpacks.
  public func segmentBytes(s : State, pack : Nat, seq : Nat) : ?Blob {
    let ?p = Map.get(s.packs, Nat.compare, pack) else return null;
    if (p.archived) return null;
    switch (RI.get(s.segments, R.key2(pack, 8, seq, 4))) {
      case (?v) { let sg = decodeSegment(pack, seq, v); ?Store.read(storeOf(s, p.storeIx), sg.offset, sg.bytes) };
      case null null;
    }
  };

  public type PackedAccount = { pack : Nat; count : Nat; debits : Nat; credits : Nat; entries : [Pack.AccountEntry] };

  /// An account's summary row and list for one pack.
  public func packedAccount(s : State, acct : Nat, pack : Nat) : ?PackedAccount {
    if (not Map.containsKey(s.packs, Nat.compare, pack)) return null;
    switch (RI.get(s.packedAccounts, R.key2(acct, 8, pack, 8))) {
      case (?v) {
        let row = decodeAccountRow(v);
        let ?entries = Pack.decodeAccountList(Store.read(s.lists, row.offset, row.len)) else Runtime.trap("Packing: a packed account list that does not decode");
        ?{ pack; count = row.count; debits = row.debits; credits = row.credits; entries }
      };
      case null null;
    }
  };

  /// The packs whose days overlap `[from, to]`, ascending; the ones a packed account read consults.
  public func packsOverlapping(s : State, from : Nat, to : Nat) : [PackView] {
    let out = List.empty<PackView>();
    for ((_, p) in Map.entries(s.packs)) { if (p.maxDay >= from and p.minDay <= to) List.add(out, view(p)) };
    List.toArray(out)
  };

  /// An account's packed postings over `[from, to]`, in statement order; value day, then posting
  /// number, the order the account index pages in; at most `bound` entries: the account's summary
  /// rows say the size before any list is read, so a read past the bound is refused with the size.
  public func packedEntries(s : State, acct : Nat, from : Nat, to : Nat, bound : Nat) : { entries : [Pack.AccountEntry]; size : Nat; exceeded : Bool } {
    let packs = packsOverlapping(s, from, to);
    var size = 0;
    for (p in packs.vals()) {
      switch (RI.get(s.packedAccounts, R.key2(acct, 8, p.pack, 8))) { case (?v) size += decodeAccountRow(v).count; case null {} };
    };
    if (size > bound) return { entries = []; size; exceeded = true };
    let out = List.empty<Pack.AccountEntry>();
    for (p in packs.vals()) {
      switch (packedAccount(s, acct, p.pack)) {
        case (?pa) { for (e in pa.entries.vals()) { if (e.valueDay >= from and e.valueDay <= to) List.add(out, e) } };
        case null {};
      };
    };
    { entries = Array.sort<Pack.AccountEntry>(List.toArray(out), func(x, y) { switch (Nat.compare(x.valueDay, y.valueDay)) { case (#equal) Nat.compare(x.posting, y.posting); case (o) o } }); size; exceeded = false }
  };

  public func markArchived(s : State, pack : Nat) : Bool {
    switch (Map.get(s.packs, Nat.compare, pack)) { case (?p) { p.archived := true; true }; case null false }
  };

  public type Stats = { packs : Nat; archived : Nat; packedThroughBlock : Nat; packedThroughDay : Nat; stores : Nat; storeBytes : Nat; storePages : Nat; listBytes : Nat; listPages : Nat; packedAccounts : RI.Stats; segments : RI.Stats; inProgress : Bool;
                        bankPackedThroughBlock : Nat; bankStoreBytes : Nat; bankStorePages : Nat; bankSegments : RI.Stats; bankBlocksPacked : Nat; bankBodiesDropped : Nat; bankBodiesKept : Nat; bankPackedBytes : Nat; bankRawBytes : Nat };

  public func stats(s : State) : Stats {
    var bytes = 0; var pages = 0; var archived = 0;
    var bankBytes = 0; var bankPages = 0; var bankBlocks = 0; var dropped = 0; var kept = 0; var bankPacked = 0; var bankRaw = 0;
    let bankStores = List.empty<Nat>();
    for ((_, p) in Map.entries(s.packs)) {
      if (p.archived) archived += 1;
      if (not List.contains(bankStores, Nat.equal, p.bankStoreIx)) List.add(bankStores, p.bankStoreIx);
      bankBlocks += p.bankHi + 1 - p.bankLo; dropped += p.bankDropped; kept += p.bankKept; bankPacked += p.bankPackedBytes; bankRaw += p.bankRawBytes;
    };
    switch (s.current) { case (?j) { if (not List.contains(bankStores, Nat.equal, j.bankStoreIx)) List.add(bankStores, j.bankStoreIx) }; case null {} };
    var ix = 0;
    for (st in List.values(s.stores)) {
      if (List.contains(bankStores, Nat.equal, ix)) { bankBytes += Store.size(st); bankPages += Store.pages(st) } else { bytes += Store.size(st); pages += Store.pages(st) };
      ix += 1;
    };
    { packs = Map.size(s.packs); archived; packedThroughBlock = s.packedThroughBlock; packedThroughDay = s.packedThroughDay; stores = List.size(s.stores); storeBytes = bytes; storePages = pages;
      listBytes = Store.size(s.lists); listPages = Store.pages(s.lists);
      packedAccounts = RI.stats(s.packedAccounts); segments = RI.stats(s.segments); inProgress = switch (s.current) { case (?_) true; case null false };
      bankPackedThroughBlock = s.bankPackedThroughBlock; bankStoreBytes = bankBytes; bankStorePages = bankPages; bankSegments = RI.stats(s.bankSegments);
      bankBlocksPacked = bankBlocks; bankBodiesDropped = dropped; bankBodiesKept = kept; bankPackedBytes = bankPacked; bankRawBytes = bankRaw }
  };
}
