/// FacilityCore.mo — the facilities of corporate lending, folded from the bank's log, in stable memory (corporate lending).
///
/// One 304-byte row per facility keyed by the block that opened it; indexes by party and by stage; the drawings
/// (facility ‖ account → open) and the drawing's facility (account → facility); the syndicate's shares
/// (facility ‖ participant → bps); the receivables of a factoring facility (facility ‖ ref key → row); the
/// covenants' last result (facility ‖ covenant key → status); the recorded rate fixings (index key ‖ day → bps).
/// Rows are written by the fold only. The arithmetic the postings rest on — a syndicate's allocation of an amount
/// by shares with the residue to the bank, the straight line of a rental or a discount over its term, the
/// clean-down judgement, a covenant's test — is pure here, so the Python oracle of `bank_s33.py` is the same
/// function written twice. What is a journal figure (drawn, available, a participant's position) is read from
/// the journal by `BankCore`, never kept here. The agent's key of a participant facility lives in the opening
/// block (it is too long for a row); the planner that needs it reads the block.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import VarArray "mo:core/VarArray";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";

import FT "FacilityTypes";
import PT "PartyTypes";
import ProdT "ProductTypes";
import R "StableRows";
import Posting "Posting";
import JT "mo:journal/JournalTypes";
import Map "mo:core/Map";
import Int "mo:core/Int";

module {

  public type Row = {
    stage : FT.Stage;
    kind : FT.Kind;
    party : PT.PartyId;
    book : Text;
    product : Text;
    currency : Text;
    limit : Nat;
    availabilityFrom : Nat;
    availabilityTo : Nat;
    pricing : FT.Pricing;
    drawings : Nat;
    openDrawings : Nat;
    receivables : Nat;
    openReceivables : Nat;
    breaches : Nat;
    nextReview : ?Nat;
    reviewFlagged : Bool;
    openedBlock : Nat;
    lastBlock : Nat;
    /// the clean-down window in progress: its start and the undrawn days counted in it
    cleanWindowStart : Nat;
    cleanDays : Nat;
    /// the last day the batch accrued a fee, rental or discount for the facility (0: never)
    lastAccrualDay : Nat;
    /// the day the operating lease's income started (its first accrual day); 0 until then
    leaseStart : Nat;
  };
  public let ROW_BYTES : Nat = 304;
  public let RECEIVABLE_ROW_BYTES : Nat = 84;
  let MAX_PAGE : Nat = 500;

  /// `ref(32) ‖ face(8) ‖ due(4) ‖ status(1) ‖ advance(8) ‖ discount(8) ‖ retention(8) ‖ recognised(8) ‖ purchased(4)
  ///  ‖ pad(3)` — 84 bytes; status 0 open, 1 collected, 2 dishonoured, 3 written off.
  public type ReceivableStatus = { #open; #collected; #dishonoured; #writtenOff };
  public type ReceivableRow = {
    ref : Blob; face : Nat; due : Nat; status : ReceivableStatus;
    advance : Nat; discount : Nat; retention : Nat; recognised : Nat; purchased : Nat;
  };

  public type State = {
    rows : RI.State;          // facility(8) -> Row
    byParty : RI.State;       // party(8) ‖ facility(8) -> stage(1)
    byBook : RI.State;        // book(32) ‖ id(8) -> 0
    byStage : RI.State;       // stage(1) ‖ facility(8) -> 0
    drawings : RI.State;      // facility(8) ‖ account(8) -> open(1)
    drawingOf : RI.State;     // account(8) -> facility(8)
    shares : RI.State;        // facility(8) ‖ participant(8) -> bps(4)
    receivables : RI.State;   // facility(8) ‖ ref key(8) -> ReceivableRow
    covenants : RI.State;     // facility(8) ‖ covenant key(8) -> status(1: 0 untested, 1 met, 2 breached)
    fixings : RI.State;       // index key(8) ‖ day(4) -> bps(4)
    subledgers : RI.State;    // the facility and participant sub-ledgers this shard posts to (32) -> 1
    var facilities : Nat;
    var closed : Nat;
    openByCurrency : Map.Map<Text, Nat>;
    openByBook : Map.Map<Text, Nat>;
    var drawn : Nat;
    var accruals : Nat;
    var fixingCount : Nat;
  };

  public func newState(arena : RI.Arena) : State {
    {
      rows = RI.newStateIn(arena, { keyBytes = 8; valBytes = ROW_BYTES });
      byParty = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      byBook = RI.newStateIn(arena, { keyBytes = 40; valBytes = 1 });
      byStage = RI.newStateIn(arena, { keyBytes = 9; valBytes = 1 });
      drawings = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      drawingOf = RI.newStateIn(arena, { keyBytes = 8; valBytes = 8 });
      shares = RI.newStateIn(arena, { keyBytes = 16; valBytes = 4 });
      receivables = RI.newStateIn(arena, { keyBytes = 16; valBytes = RECEIVABLE_ROW_BYTES });
      covenants = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      fixings = RI.newStateIn(arena, { keyBytes = 12; valBytes = 4 });
      subledgers = RI.newStateIn(arena, { keyBytes = 32; valBytes = 1 });
      openByCurrency = Map.empty<Text, Nat>();
      openByBook = Map.empty<Text, Nat>();
      var facilities = 0; var closed = 0; var drawn = 0; var accruals = 0; var fixingCount = 0;
    }
  };

  // ─── codes and keys ───────────────────────────────────────────────────────

  /// The facility's sub-ledger on the accounts its kind posts to, and a participant's on the syndicate's.
  public func facilitySub(id : FT.FacilityId) : JT.SubledgerKey { Posting.subledgerOf("FAC" # Nat.toText(id)) };
  public func participantSub(id : FT.FacilityId, p : PT.PartyId) : JT.SubledgerKey { Posting.subledgerOf("FAC" # Nat.toText(id) # "-P" # Nat.toText(p)) };
  func holdSub(s : State, sub : JT.SubledgerKey) { ignore RI.put(s.subledgers, sub, Blob.fromArray([1])) };
  /// Whether a sub-ledger is one of this shard's facilities' or participants', so a posting naming it is the shard's own.
  public func holdsSubledger(s : State, sub : JT.SubledgerKey) : Bool { sub.size() == 32 and RI.get(s.subledgers, sub) != null };

  public func periodCode(p : ProdT.Period) : Nat8 { switch (p) { case (#daily) 0; case (#monthly) 1; case (#quarterly) 2; case (#semiAnnual) 3; case (#annual) 4; case (#atMaturity) 5 } };
  public func periodOfCode(c : Nat8) : ?ProdT.Period { switch (c) { case 0 ?#daily; case 1 ?#monthly; case 2 ?#quarterly; case 3 ?#semiAnnual; case 4 ?#annual; case 5 ?#atMaturity; case _ null } };
  public func schemeCode(x : { #none; #mayo2; #mldsa44 }) : Nat8 { switch (x) { case (#none) 0; case (#mayo2) 1; case (#mldsa44) 2 } };
  public func schemeOfCode(c : Nat8) : ?{ #none; #mayo2; #mldsa44 } { switch (c) { case 0 ?#none; case 1 ?#mayo2; case 2 ?#mldsa44; case _ null } };
  func hashKey(b : Blob) : Nat { R.getNat(Blob.toArray(Sha256.fromBlob(#sha256, b)), 0, 8) };
  public func textKey(t : Text) : Nat { hashKey(Text.encodeUtf8(t)) };
  func covenantKey(f : FT.FacilityId, c : Text) : Blob { R.key2(f, 8, textKey(c), 8) };
  func receivableKey(f : FT.FacilityId, ref : Blob) : Blob { R.key2(f, 8, hashKey(ref), 8) };

  // ─── the facility row ─────────────────────────────────────────────────────
  //
  // offsets: 0 stage · 1 kind · 2 party(8) · 10 book(32) · 42 product(32) · 74 currency(8) · 82 limit(8) ·
  // 90 from(4) · 94 to(4) · 98 pricingKind · 99 bps(4) · 103 index(16) · 119 resetDays(4) · 123 feeBps(4) ·
  // 127 cleanEvery(4) · 131 cleanFor(4) · 135 agentFeeBps(4) · 139 ourBps(4) · 143 residual(8) · 151 rental(8) ·
  // 159 every · 160 periods(4) · 164 advanceBps(4) · 168 discountBps(4) · 172 recourse · 173 clientAccount(8) ·
  // 181 drawings(4) · 185 open(4) · 189 receivables(4) · 193 openRec(4) · 197 breaches(4) · 201 nextReview(4) ·
  // 205 openedBlock(8) · 213 lastBlock(8) · 221 cleanStart(4) · 225 cleanDays(4) · 229 reviewFlagged ·
  // 230 lastAccrual(4) · 234 asset/agentAccount(32) · 266 agent(32) · 298 leaseStart(4) · 302 agentScheme · 303 pad

  func encodeRow(r : Row) : Blob {
    let b = R.buf();
    R.putByte(b, FT.stageCode(r.stage)); R.putByte(b, FT.kindCode(r.kind));
    R.putNat(b, r.party, 8); R.putText(b, r.book, 32); R.putText(b, r.product, 32); R.putText(b, r.currency, 8);
    R.putNat(b, r.limit, 8); R.putNat(b, r.availabilityFrom, 4); R.putNat(b, r.availabilityTo, 4);
    switch (r.pricing) {
      case (#fixed(bps)) { R.putByte(b, 0); R.putNat(b, bps, 4); R.putText(b, "", 16); R.putNat(b, 0, 4) };
      case (#floating(f)) { R.putByte(b, 1); R.putNat(b, f.spreadBps, 4); R.putText(b, f.index, 16); R.putNat(b, f.resetDays, 4) };
    };
    var feeBps = 0; var cleanEvery = 0; var cleanFor = 0; var agentFeeBps = 0; var ourBps = 0; var residual = 0; var rental = 0;
    var every : Nat8 = 5; var periods = 0; var advanceBps = 0; var discountBps = 0; var recourse = false; var clientAccount = 0;
    var account = ""; var agent = ""; var scheme : Nat8 = 0;
    switch (r.kind) {
      case (#bilateralTerm) {};
      case (#revolving(x)) { feeBps := x.commitmentFeeBps; switch (x.cleanDown) { case (?c) { cleanEvery := c.everyDays; cleanFor := c.forDays }; case null {} } };
      case (#syndicatedAgent(x)) { agentFeeBps := x.agentFeeBps };
      case (#syndicatedParticipant(x)) { ourBps := x.ourBps; agent := x.agent; scheme := schemeCode(x.agentScheme); account := x.agentAccount };
      case (#financeLease(x)) { account := x.assetAccount; residual := x.residual };
      case (#operatingLease(x)) { rental := x.rentalPerPeriod; every := periodCode(x.every); periods := x.periods };
      case (#factoring(x)) { advanceBps := x.advanceBps; discountBps := x.discountBps; recourse := x.recourse; clientAccount := x.clientAccount };
      case (#forfaiting(x)) { discountBps := x.discountBps; clientAccount := x.clientAccount; advanceBps := 10_000 };
    };
    R.putNat(b, feeBps, 4); R.putNat(b, cleanEvery, 4); R.putNat(b, cleanFor, 4); R.putNat(b, agentFeeBps, 4); R.putNat(b, ourBps, 4);
    R.putNat(b, residual, 8); R.putNat(b, rental, 8); R.putByte(b, every); R.putNat(b, periods, 4);
    R.putNat(b, advanceBps, 4); R.putNat(b, discountBps, 4); R.putBool(b, recourse); R.putNat(b, clientAccount, 8);
    R.putNat(b, r.drawings, 4); R.putNat(b, r.openDrawings, 4); R.putNat(b, r.receivables, 4); R.putNat(b, r.openReceivables, 4); R.putNat(b, r.breaches, 4);
    R.putNat(b, switch (r.nextReview) { case (?d) d; case null 0 }, 4);
    R.putNat(b, r.openedBlock, 8); R.putNat(b, r.lastBlock, 8);
    R.putNat(b, r.cleanWindowStart, 4); R.putNat(b, r.cleanDays, 4);
    R.putBool(b, r.reviewFlagged); R.putNat(b, r.lastAccrualDay, 4);
    R.putText(b, account, 32); R.putText(b, agent, 32);
    R.putNat(b, r.leaseStart, 4); R.putByte(b, scheme); R.putByte(b, 0);
    R.done(b, ROW_BYTES)
  };

  func decodeRow(v : Blob) : Row {
    let a = Blob.toArray(v);
    let ?stage = FT.stageOfCode(a[0]) else Runtime.trap("FacilityCore: a row with an unknown stage code");
    let pricing : FT.Pricing = if (a[98] == 0) #fixed(R.getNat(a, 99, 4)) else #floating({ index = R.getText(a, 103, 16); spreadBps = R.getNat(a, 99, 4); resetDays = R.getNat(a, 119, 4) });
    let feeBps = R.getNat(a, 123, 4); let cleanEvery = R.getNat(a, 127, 4); let cleanFor = R.getNat(a, 131, 4); let agentFeeBps = R.getNat(a, 135, 4); let ourBps = R.getNat(a, 139, 4);
    let residual = R.getNat(a, 143, 8); let rental = R.getNat(a, 151, 8); let every = switch (periodOfCode(a[159])) { case (?p) p; case null #atMaturity }; let periods = R.getNat(a, 160, 4);
    let advanceBps = R.getNat(a, 164, 4); let discountBps = R.getNat(a, 168, 4); let recourse = R.getBool(a, 172); let clientAccount = R.getNat(a, 173, 8);
    let account = R.getText(a, 234, 32); let agent = R.getText(a, 266, 32);
    let scheme = switch (schemeOfCode(a[302])) { case (?s) s; case null #none };
    let kind : FT.Kind = switch (a[1]) {
      case 0 #bilateralTerm;
      case 1 #revolving({ commitmentFeeBps = feeBps; cleanDown = if (cleanEvery == 0) null else ?{ everyDays = cleanEvery; forDays = cleanFor } });
      case 2 #syndicatedAgent({ shares = []; agentFeeBps });   // the shares live in their index: `sharesOf`
      case 3 #syndicatedParticipant({ agent; agentScheme = scheme; agentKey = ""; agentAccount = account; ourBps });   // the key is the opening block's
      case 4 #financeLease({ assetAccount = account; residual });
      case 5 #operatingLease({ rentalPerPeriod = rental; every; periods });
      case 6 #factoring({ advanceBps; discountBps; recourse; clientAccount });
      case _ #forfaiting({ discountBps; clientAccount });
    };
    let nextReview = R.getNat(a, 201, 4);
    {
      stage; kind; party = R.getNat(a, 2, 8); book = R.getText(a, 10, 32); product = R.getText(a, 42, 32); currency = R.getText(a, 74, 8);
      limit = R.getNat(a, 82, 8); availabilityFrom = R.getNat(a, 90, 4); availabilityTo = R.getNat(a, 94, 4); pricing;
      drawings = R.getNat(a, 181, 4); openDrawings = R.getNat(a, 185, 4); receivables = R.getNat(a, 189, 4); openReceivables = R.getNat(a, 193, 4); breaches = R.getNat(a, 197, 4);
      nextReview = if (nextReview == 0) null else ?nextReview;
      openedBlock = R.getNat(a, 205, 8); lastBlock = R.getNat(a, 213, 8);
      cleanWindowStart = R.getNat(a, 221, 4); cleanDays = R.getNat(a, 225, 4);
      reviewFlagged = R.getBool(a, 229); lastAccrualDay = R.getNat(a, 230, 4); leaseStart = R.getNat(a, 298, 4);
    }
  };

  public func row(s : State, id : FT.FacilityId) : ?Row {
    switch (RI.get(s.rows, R.key(id, 8))) { case (?v) ?decodeRow(v); case null null }
  };

  /// The open facilities per currency, kept by the fold: what a redenomination asks before it closes a currency (S4.1).
  func bumpCurrency(s : State, ccy : Text, delta : Int) {
    let cur : Int = switch (Map.get(s.openByCurrency, Text.compare, ccy)) { case (?v) v; case null 0 };
    let next = cur + delta;
    if (next <= 0) ignore Map.delete(s.openByCurrency, Text.compare, ccy) else Map.add(s.openByCurrency, Text.compare, ccy, Int.abs(next));
  };
  public func openInCurrency(s : State, ccy : Text) : Nat { switch (Map.get(s.openByCurrency, Text.compare, ccy)) { case (?v) v; case null 0 } };
  func bumpBook(s : State, book : Text, delta : Int) {
    let cur : Int = switch (Map.get(s.openByBook, Text.compare, book)) { case (?v) v; case null 0 };
    let next = cur + delta;
    if (next <= 0) ignore Map.delete(s.openByBook, Text.compare, book) else Map.add(s.openByBook, Text.compare, book, Int.abs(next));
  };
  /// The open facilities of a book, from the fold's counter: what the end-of-day plan asks — no walk (S4.1).
  public func openCountInBook(s : State, book : Text) : Nat { switch (Map.get(s.openByBook, Text.compare, book)) { case (?v) v; case null 0 } };
  func stageOpen(st : FT.Stage) : Bool { st == #open or st == #blocked };
  func putRow(s : State, id : FT.FacilityId, r : Row, block : Nat) {
    let r2 = { r with lastBlock = block };
    // the per-currency open count follows the stage across the write
    let was = switch (row(s, id)) { case (?o) stageOpen(o.stage); case null false };
    let is = stageOpen(r2.stage);
    if (is and not was) { bumpCurrency(s, r2.currency, 1); bumpBook(s, r2.book, 1) } else if (was and not is) { bumpCurrency(s, r2.currency, -1); bumpBook(s, r2.book, -1) };
    ignore RI.put(s.rows, R.key(id, 8), encodeRow(r2));
    ignore RI.put(s.byParty, R.key2(r2.party, 8, id, 8), Blob.fromArray([FT.stageCode(r2.stage)]));
    ignore RI.put(s.byBook, bookKey(r2.book, id), Blob.fromArray([0]));
    ignore RI.put(s.byStage, R.key2(Nat8.toNat(FT.stageCode(r2.stage)), 1, id, 8), Blob.fromArray([0]));
  };

  func existing(s : State, id : FT.FacilityId) : Row {
    let ?r = row(s, id) else Runtime.trap("FacilityCore: an act on a facility the log never opened");
    r
  };

  // ─── receivable rows ──────────────────────────────────────────────────────

  func statusCode(x : ReceivableStatus) : Nat8 { switch (x) { case (#open) 0; case (#collected) 1; case (#dishonoured) 2; case (#writtenOff) 3 } };
  func encodeReceivable(r : ReceivableRow) : Blob {
    let b = R.buf();
    R.putBlob(b, r.ref, 32); R.putNat(b, r.face, 8); R.putNat(b, r.due, 4); R.putByte(b, statusCode(r.status));
    R.putNat(b, r.advance, 8); R.putNat(b, r.discount, 8); R.putNat(b, r.retention, 8); R.putNat(b, r.recognised, 8); R.putNat(b, r.purchased, 4);
    R.putByte(b, 0); R.putByte(b, 0); R.putByte(b, 0);
    R.done(b, RECEIVABLE_ROW_BYTES)
  };
  func decodeReceivable(v : Blob) : ReceivableRow {
    let a = Blob.toArray(v);
    {
      ref = R.getBlob(a, 0, 32); face = R.getNat(a, 32, 8); due = R.getNat(a, 40, 4);
      status = switch (a[44]) { case 1 #collected; case 2 #dishonoured; case 3 #writtenOff; case _ #open };
      advance = R.getNat(a, 45, 8); discount = R.getNat(a, 53, 8); retention = R.getNat(a, 61, 8); recognised = R.getNat(a, 69, 8); purchased = R.getNat(a, 77, 4);
    }
  };
  public func receivable(s : State, f : FT.FacilityId, ref : Blob) : ?ReceivableRow {
    switch (RI.get(s.receivables, receivableKey(f, ref))) { case (?v) ?decodeReceivable(v); case null null }
  };
  public func receivablesOf(s : State, f : FT.FacilityId) : [ReceivableRow] {
    let out = List.empty<ReceivableRow>();
    let (lo, hi) = R.prefixRange(f, 8, 8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.receivables, lo, hi, cursor, MAX_PAGE);
      for ((_, v) in page.entries.vals()) List.add(out, decodeReceivable(v));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };

  // ─── shares, drawings, fixings, covenants ─────────────────────────────────

  public func sharesOf(s : State, f : FT.FacilityId) : [FT.Share] {
    let out = List.empty<FT.Share>();
    let (lo, hi) = R.prefixRange(f, 8, 8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.shares, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) { let bps = R.getNat(Blob.toArray(v), 0, 4); if (bps > 0) List.add(out, { participant = R.getNat(Blob.toArray(k), 8, 8); bps }) };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  public func shareOf(s : State, f : FT.FacilityId, participant : PT.PartyId) : Nat {
    switch (RI.get(s.shares, R.key2(f, 8, participant, 8))) { case (?v) R.getNat(Blob.toArray(v), 0, 4); case null 0 }
  };

  public func drawingsOf(s : State, f : FT.FacilityId) : [(ProdT.AccountId, Bool)] {
    let out = List.empty<(ProdT.AccountId, Bool)>();
    let (lo, hi) = R.prefixRange(f, 8, 8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.drawings, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) List.add(out, (R.getNat(Blob.toArray(k), 8, 8), Blob.toArray(v)[0] == 1));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  public func facilityOfDrawing(s : State, account : ProdT.AccountId) : ?FT.FacilityId {
    switch (RI.get(s.drawingOf, R.key(account, 8))) { case (?v) ?R.getNat(Blob.toArray(v), 0, 8); case null null }
  };

  /// The fixing of an index in force on a day: the latest recorded on or before it.
  public func fixingOn(s : State, index : Text, day : Nat) : ?Nat {
    let (lo, _) = R.prefixRange(textKey(index), 8, 4);
    let hi = R.key2(textKey(index), 8, day, 4);
    var cursor : ?Blob = null;
    var latest : ?Nat = null;
    label walk loop {
      let page = RI.range(s.fixings, lo, hi, cursor, MAX_PAGE);
      for ((_, v) in page.entries.vals()) latest := ?R.getNat(Blob.toArray(v), 0, 4);
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    latest
  };

  public func covenantStatus(s : State, f : FT.FacilityId, id : Text) : { #untested; #met; #breached } {
    switch (RI.get(s.covenants, covenantKey(f, id))) { case (?v) { switch (Blob.toArray(v)[0]) { case 1 #met; case 2 #breached; case _ #untested } }; case null #untested }
  };

  // ─── the arithmetic, pure: the oracle's twins ─────────────────────────────

  /// An amount split by the participants' shares, each participant's part rounded down and the residue the
  /// bank's: the parts and the bank's own sum to the whole.
  public func allocate(shares : [FT.Share], amount : Nat) : { parts : [(PT.PartyId, Nat)]; own : Nat } {
    var given = 0;
    let parts = Array.map<FT.Share, (PT.PartyId, Nat)>(shares, func(sh) { let part = amount * sh.bps / 10_000; given += part; (sh.participant, part) });
    { parts; own = amount - given }
  };
  public func sharesValid(shares : [FT.Share]) : ?Text {
    var total = 0;
    var i = 0;
    for (sh in shares.vals()) {
      if (sh.bps == 0) return ?"a participant with no share";
      var j = 0;
      for (o in shares.vals()) { if (j < i and o.participant == sh.participant) return ?"a participant listed twice"; j += 1 };
      total += sh.bps; i += 1;
    };
    if (total >= 10_000) return ?"the participants' shares leave the bank nothing";
    null
  };

  /// The figure recognised straight-line by `elapsed` days of a `term`: total × min(elapsed, term) / term, so the
  /// cumulative figure reaches the total exactly on the last day and the daily posting is its difference.
  public func straightLine(total : Nat, termDays : Nat, elapsed : Nat) : Nat {
    if (termDays == 0) return total;
    let e = Nat.min(elapsed, termDays);
    total * e / termDays
  };

  /// A covenant's test over the presented value.
  public func covenantMet(c : FT.Covenant, value : Nat, day : Nat) : Bool {
    switch (c.kind) {
      case (#financialRatio(r)) { switch (r.op) { case (#atMost) value <= r.thresholdBps; case (#atLeast) value >= r.thresholdBps } };
      case (#reporting(x)) day <= x.due;
      case (#negativePledge) value == 1;
    }
  };

  /// The clean-down judgement at a window's end: the undrawn days counted in the window against the days required.
  public func cleanDownMet(cleanDays : Nat, required : Nat) : Bool { cleanDays >= required };

  // ─── validation and planning (the journal legs are BankCore's) ───────────

  public func validTerms(t : FT.Terms) : ?Text {
    if (t.limit == 0) return ?"a facility needs a limit";
    if (t.availabilityTo < t.availabilityFrom) return ?"the availability ends before it starts";
    if (Text.size(t.currency) == 0 or Text.encodeUtf8(t.currency).size() > 8) return ?"a currency code is 1..8 bytes";
    if (Text.encodeUtf8(t.book).size() > 32 or Text.encodeUtf8(t.product).size() > 32) return ?"a book or product id is at most 32 bytes";
    switch (t.pricing) {
      case (#fixed(bps)) { if (bps > 100_000) return ?"a rate above 1000% a year" };
      case (#floating(f)) { if (Text.size(f.index) == 0 or Text.encodeUtf8(f.index).size() > 16) return ?"a rate index is 1..16 bytes"; if (f.resetDays == 0) return ?"a reset period of zero days" };
    };
    var i = 0;
    for (c in t.covenants.vals()) {
      if (Text.size(c.id) == 0) return ?"a covenant needs an id";
      var j = 0;
      for (o in t.covenants.vals()) { if (j < i and Text.equal(o.id, c.id)) return ?"a covenant listed twice"; j += 1 };
      i += 1;
    };
    if (t.covenants.size() > 32) return ?"at most 32 covenants";
    switch (t.reviewEvery) { case (?n) { if (n == 0) return ?"a review period of zero days" }; case null {} };
    switch (t.kind) {
      case (#bilateralTerm) {};
      case (#revolving(x)) {
        if (x.commitmentFeeBps > 10_000) return ?"a commitment fee above 100%";
        switch (x.cleanDown) { case (?c) { if (c.everyDays == 0 or c.forDays == 0 or c.forDays > c.everyDays) return ?"a clean-down needs 1..everyDays days in every window" }; case null {} };
      };
      case (#syndicatedAgent(x)) { switch (sharesValid(x.shares)) { case (?r) return ?r; case null {} }; if (x.agentFeeBps > 10_000) return ?"an agent fee above 100%" };
      case (#syndicatedParticipant(x)) {
        if (x.ourBps == 0 or x.ourBps >= 10_000) return ?"the bank's participation is 1..9999 basis points";
        if (Text.size(x.agent) == 0 or Text.encodeUtf8(x.agent).size() > 32) return ?"an agent id is 1..32 bytes";
        if (x.agentScheme != #none and x.agentKey.size() == 0) return ?"a signing agent needs a key";
        if (Text.size(x.agentAccount) == 0 or Text.encodeUtf8(x.agentAccount).size() > 32) return ?"the agent's account is 1..32 bytes";
      };
      case (#financeLease(x)) { if (Text.size(x.assetAccount) == 0 or Text.encodeUtf8(x.assetAccount).size() > 32) return ?"a lease needs the asset's account"; if (x.residual >= t.limit) return ?"the residual exceeds the lease" };
      case (#operatingLease(x)) { if (x.rentalPerPeriod == 0 or x.periods == 0) return ?"an operating lease needs rentals and periods"; if (x.every == #atMaturity) return ?"rentals fall at a period" };
      case (#factoring(x)) { if (x.advanceBps == 0 or x.advanceBps > 10_000) return ?"an advance is 1..10000 basis points"; if (x.advanceBps + x.discountBps > 10_000) return ?"the advance and the discount exceed the face" };
      case (#forfaiting(x)) { if (x.discountBps == 0 or x.discountBps >= 10_000) return ?"a forfaiting discount is 1..9999 basis points" };
    };
    null
  };

  public type Planned = Result.Result<FT.FacilityEvent, FT.FacilityError>;

  func wrongStage(id : FT.FacilityId, r : Row, wanted : Text) : FT.FacilityError { #WrongStage({ facility = id; stage = FT.stageText(r.stage); wanted }) };
  func wrongKind(id : FT.FacilityId, r : Row, wanted : Text) : FT.FacilityError { #WrongKind({ facility = id; kind = FT.kindText(r.kind); wanted }) };

  public func get(s : State, id : FT.FacilityId) : Result.Result<Row, FT.FacilityError> {
    switch (row(s, id)) { case (?r) #ok(r); case null #err(#UnknownFacility({ facility = id })) }
  };

  /// A drawing is admitted on an open facility inside its availability, under the aggregate limit read by the
  /// caller from the journal; a blocked facility refuses.
  /// `byNotice`: the drawing is the agent's notice on a participation, the only way that kind is drawn.
  public func admitDrawdown(s : State, id : FT.FacilityId, amount : Nat, drawn : Nat, day : Nat, byNotice : Bool) : Result.Result<Row, FT.FacilityError> {
    let ?r = row(s, id) else return #err(#UnknownFacility({ facility = id }));
    switch (r.stage) { case (#open) {}; case (#blocked) return #err(#Blocked({ facility = id; reason = "drawdowns are blocked" })); case (#closed) return #err(wrongStage(id, r, "open")) };
    if (day < r.availabilityFrom or day > r.availabilityTo) return #err(#OutsideAvailability({ facility = id; day; from = r.availabilityFrom; to = r.availabilityTo }));
    if (amount == 0) return #err(#InvalidTerms({ reason = "a drawing of nothing" }));
    if (drawn + amount > r.limit) return #err(#OverLimit({ facility = id; limit = r.limit; drawn; requested = amount }));
    switch (r.kind, byNotice) {
      case (#syndicatedParticipant(_), true) {};
      case (#syndicatedParticipant(_), false) return #err(wrongKind(id, r, "a facility drawn by the bank"));
      case (_, true) return #err(wrongKind(id, r, "syndicatedParticipant"));
      case (#bilateralTerm, _) { if (r.drawings > 0) return #err(#InvalidTerms({ reason = "a bilateral term facility is drawn once" })) };
      case (#financeLease(_), _) { if (r.drawings > 0) return #err(#InvalidTerms({ reason = "a lease commences once" })) };
      case (#revolving(_) or #syndicatedAgent(_), _) {};
      case (_, _) return #err(wrongKind(id, r, "a facility drawn by the bank"));
    };
    #ok(r)
  };

  public func planTransferParticipation(s : State, id : FT.FacilityId, from : PT.PartyId, to : PT.PartyId, bps : Nat, moved : Nat) : Planned {
    let ?r = row(s, id) else return #err(#UnknownFacility({ facility = id }));
    switch (r.kind) { case (#syndicatedAgent(_)) {}; case (_) return #err(wrongKind(id, r, "syndicatedAgent")) };
    if (r.stage == #closed) return #err(wrongStage(id, r, "open or blocked"));
    let have = shareOf(s, id, from);
    if (have == 0) return #err(#UnknownParticipant({ facility = id; participant = from }));
    if (bps == 0 or bps > have) return #err(#InvalidTerms({ reason = "the transfer exceeds the transferor's share" }));
    if (from == to) return #err(#InvalidTerms({ reason = "a transfer to oneself" }));
    #ok(#participationTransferred({ facility = id; from; to; bps; moved }))
  };

  public func planCovenantTest(s : State, id : FT.FacilityId, covenants : [FT.Covenant], covenant : Text, value : Nat, statementHash : Blob, day : Nat) : Planned {
    let ?r = row(s, id) else return #err(#UnknownFacility({ facility = id }));
    if (r.stage == #closed) return #err(wrongStage(id, r, "open or blocked"));
    let ?c = Array.find<FT.Covenant>(covenants, func(c) { Text.equal(c.id, covenant) }) else return #err(#UnknownCovenant({ facility = id; covenant }));
    if (statementHash.size() != 32) return #err(#InvalidTerms({ reason = "a statement hash is 32 bytes" }));
    #ok(#covenantTested({ facility = id; covenant; value; met = covenantMet(c, value, day); statementHash; day }))
  };

  public func planBlock(s : State, id : FT.FacilityId, reason : Text, day : Nat) : Planned {
    let ?r = row(s, id) else return #err(#UnknownFacility({ facility = id }));
    if (r.stage != #open) return #err(wrongStage(id, r, "open"));
    if (Text.size(reason) == 0) return #err(#InvalidTerms({ reason = "a block needs a reason" }));
    #ok(#drawdownsBlocked({ facility = id; reason; day }))
  };
  public func planUnblock(s : State, id : FT.FacilityId, reason : Text, day : Nat) : Planned {
    let ?r = row(s, id) else return #err(#UnknownFacility({ facility = id }));
    if (r.stage != #blocked) return #err(wrongStage(id, r, "blocked"));
    if (Text.size(reason) == 0) return #err(#InvalidTerms({ reason = "an unblock needs a reason" }));
    #ok(#drawdownsUnblocked({ facility = id; reason; day }))
  };
  public func planReview(s : State, id : FT.FacilityId, note : Text, day : Nat) : Planned {
    let ?r = row(s, id) else return #err(#UnknownFacility({ facility = id }));
    if (r.stage == #closed) return #err(wrongStage(id, r, "open or blocked"));
    if (Text.encodeUtf8(note).size() > 256) return #err(#InvalidTerms({ reason = "a review note is at most 256 bytes" }));
    #ok(#reviewRecorded({ facility = id; day; nextDue = null; note }))
  };
  public func planRateFixing(index : Text, day : Nat, rateBps : Nat) : Planned {
    if (Text.size(index) == 0 or Text.encodeUtf8(index).size() > 16) return #err(#InvalidTerms({ reason = "a rate index is 1..16 bytes" }));
    if (rateBps > 100_000) return #err(#InvalidTerms({ reason = "a fixing above 1000% a year" }));
    #ok(#rateFixingRecorded({ index; day; rateBps }))
  };
  public func planClose(s : State, id : FT.FacilityId, day : Nat) : Planned {
    let ?r = row(s, id) else return #err(#UnknownFacility({ facility = id }));
    if (r.stage == #closed) return #err(wrongStage(id, r, "open or blocked"));
    if (r.openDrawings > 0) return #err(#HasDrawings({ facility = id; open = r.openDrawings }));
    if (r.openReceivables > 0) return #err(#HasDrawings({ facility = id; open = r.openReceivables }));
    #ok(#facilityClosed({ facility = id; day }))
  };

  /// The rate a drawing is priced at on a day: fixed, or the index's fixing plus the spread.
  public func rateFor(s : State, r : Row, day : Nat) : Result.Result<{ rateBps : Nat; fixing : Nat }, FT.FacilityError> {
    switch (r.pricing) {
      case (#fixed(bps)) #ok({ rateBps = bps; fixing = 0 });
      case (#floating(f)) { switch (fixingOn(s, f.index, day)) { case (?fx) #ok({ rateBps = fx + f.spreadBps; fixing = fx }); case null #err(#NoFixing({ index = f.index; day })) } };
    }
  };

  /// The receivables a purchase adds, validated: fresh references, faces, due days after the purchase.
  public func admitPurchase(s : State, id : FT.FacilityId, items : [FT.Receivable], day : Nat) : Result.Result<Row, FT.FacilityError> {
    let ?r = row(s, id) else return #err(#UnknownFacility({ facility = id }));
    switch (r.stage) { case (#open) {}; case (#blocked) return #err(#Blocked({ facility = id; reason = "purchases are blocked" })); case (#closed) return #err(wrongStage(id, r, "open")) };
    switch (r.kind) {
      case (#factoring(_)) {};
      case (#forfaiting(_)) { if (items.size() != 1 or r.receivables > 0) return #err(#InvalidTerms({ reason = "a forfaiting facility buys one instrument" })) };
      case (_) return #err(wrongKind(id, r, "factoring or forfaiting"));
    };
    if (items.size() == 0 or items.size() > 64) return #err(#InvalidTerms({ reason = "1..64 receivables a purchase" }));
    if (day < r.availabilityFrom or day > r.availabilityTo) return #err(#OutsideAvailability({ facility = id; day; from = r.availabilityFrom; to = r.availabilityTo }));
    var i = 0;
    for (x in items.vals()) {
      if (x.ref.size() != 32 or x.debtorCommit.size() != 32) return #err(#InvalidTerms({ reason = "a receivable's reference and debtor commitment are 32 bytes" }));
      if (x.face == 0) return #err(#InvalidTerms({ reason = "a receivable of nothing" }));
      if (x.due <= day) return #err(#InvalidTerms({ reason = "a receivable already due" }));
      if (receivable(s, id, x.ref) != null) return #err(#InvalidTerms({ reason = "a receivable bought twice" }));
      var j = 0;
      for (o in items.vals()) { if (j < i and o.ref == x.ref) return #err(#InvalidTerms({ reason = "a receivable listed twice" })); j += 1 };
      i += 1;
    };
    #ok(r)
  };

  /// The split of a purchase: per receivable the advance, the discount to maturity and the retention.
  public func purchaseFigures(kind : FT.Kind, x : FT.Receivable) : { advance : Nat; discount : Nat; retention : Nat } {
    switch (kind) {
      case (#factoring(f)) {
        let discount = x.face * f.discountBps / 10_000;
        let advance = x.face * f.advanceBps / 10_000;
        { advance; discount; retention = x.face - advance - discount }
      };
      case (#forfaiting(f)) { let discount = x.face * f.discountBps / 10_000; { advance = x.face - discount; discount; retention = 0 } };
      case (_) ({ advance = 0; discount = 0; retention = 0 });
    }
  };

  // ─── the fold ─────────────────────────────────────────────────────────────

  public func apply(s : State, block : Nat, e : FT.FacilityEvent) {
    switch (e) {
      case (#facilityOpened(x)) {
        let t = x.terms;
        let r : Row = {
          stage = #open; kind = t.kind; party = t.party; book = t.book; product = t.product; currency = t.currency; limit = t.limit;
          availabilityFrom = t.availabilityFrom; availabilityTo = t.availabilityTo; pricing = t.pricing;
          drawings = 0; openDrawings = 0; receivables = 0; openReceivables = 0; breaches = 0;
          nextReview = switch (t.reviewEvery) { case (?n) ?(x.day + n); case null null }; reviewFlagged = false;
          openedBlock = block; lastBlock = block; cleanWindowStart = t.availabilityFrom; cleanDays = 0; lastAccrualDay = 0; leaseStart = 0;
        };
        putRow(s, block, r, block);
        holdSub(s, facilitySub(block));
        switch (t.kind) { case (#syndicatedAgent(sy)) { for (sh in sy.shares.vals()) { ignore RI.put(s.shares, R.key2(block, 8, sh.participant, 8), R.key(sh.bps, 4)); holdSub(s, participantSub(block, sh.participant)) } }; case (_) {} };
        for (c in t.covenants.vals()) ignore RI.put(s.covenants, covenantKey(block, c.id), Blob.fromArray([0]));
        s.facilities += 1;
      };
      case (#drawn(x)) {
        let r = existing(s, x.facility);
        ignore RI.put(s.drawings, R.key2(x.facility, 8, x.account, 8), Blob.fromArray([1]));
        ignore RI.put(s.drawingOf, R.key(x.account, 8), R.key(x.facility, 8));
        putRow(s, x.facility, { r with drawings = r.drawings + 1; openDrawings = r.openDrawings + 1 }, block);
        s.drawn += 1;
      };
      case (#drawingRepaid(x)) { let r = existing(s, x.facility); putRow(s, x.facility, r, block) };
      case (#commitmentFeeAccrued(x)) { let r = existing(s, x.facility); putRow(s, x.facility, { r with lastAccrualDay = x.day }, block); s.accruals += 1 };
      case (#cleanDownJudged(x)) { let r = existing(s, x.facility); putRow(s, x.facility, { r with cleanWindowStart = x.windowEnd; cleanDays = 0 }, block) };
      case (#participationTransferred(x)) {
        let r = existing(s, x.facility);
        let fromNow = shareOf(s, x.facility, x.from);
        ignore RI.put(s.shares, R.key2(x.facility, 8, x.from, 8), R.key(fromNow - x.bps, 4));
        ignore RI.put(s.shares, R.key2(x.facility, 8, x.to, 8), R.key(shareOf(s, x.facility, x.to) + x.bps, 4));
        holdSub(s, participantSub(x.facility, x.to));
        putRow(s, x.facility, r, block);
      };
      case (#distributedToParticipants(x)) { let r = existing(s, x.facility); putRow(s, x.facility, r, block) };
      // the notice's drawing is recorded by the `#drawn` block the same act writes; the notice is the record of why
      case (#agentNoticeRecorded(x)) { let r = existing(s, x.facility); putRow(s, x.facility, r, block) };
      case (#facilityRestructured(x)) { let r = existing(s, x.facility); putRow(s, x.facility, r, block) };
      case (#drawingRepriced(x)) { let r = existing(s, x.facility); putRow(s, x.facility, r, block) };
      case (#covenantTested(x)) {
        let r = existing(s, x.facility);
        let was = covenantStatus(s, x.facility, x.covenant);
        ignore RI.put(s.covenants, covenantKey(x.facility, x.covenant), Blob.fromArray([if (x.met) 1 else 2]));
        putRow(s, x.facility, { r with breaches = if (x.met) r.breaches else r.breaches + 1 }, block);
        ignore was;
      };
      case (#drawdownsBlocked(x)) { let r = existing(s, x.facility); putRow(s, x.facility, { r with stage = #blocked }, block) };
      case (#drawdownsUnblocked(x)) { let r = existing(s, x.facility); putRow(s, x.facility, { r with stage = #open }, block) };
      case (#reviewRecorded(x)) { let r = existing(s, x.facility); putRow(s, x.facility, { r with nextReview = x.nextDue; reviewFlagged = false }, block) };
      case (#reviewOverdue(x)) { let r = existing(s, x.facility); putRow(s, x.facility, { r with reviewFlagged = true }, block) };
      case (#leaseRentalAccrued(x)) { let r = existing(s, x.facility); putRow(s, x.facility, { r with lastAccrualDay = x.day; leaseStart = if (r.leaseStart == 0) x.day else r.leaseStart }, block); s.accruals += 1 };
      case (#rentalReceived(x)) { let r = existing(s, x.facility); putRow(s, x.facility, r, block) };
      case (#residualRemeasured(x)) {
        let r = existing(s, x.facility);
        let kind : FT.Kind = switch (r.kind) { case (#financeLease(l)) #financeLease({ l with residual = x.to }); case (k) k };
        putRow(s, x.facility, { r with kind }, block);
      };
      case (#receivablesPurchased(x)) {
        let r = existing(s, x.facility);
        for (it in x.receivables.vals()) {
          let fig = purchaseFigures(r.kind, it);
          ignore RI.put(s.receivables, receivableKey(x.facility, it.ref), encodeReceivable({ ref = it.ref; face = it.face; due = it.due; status = #open; advance = fig.advance; discount = fig.discount; retention = fig.retention; recognised = 0; purchased = x.day }));
        };
        putRow(s, x.facility, { r with receivables = r.receivables + x.receivables.size(); openReceivables = r.openReceivables + x.receivables.size() }, block);
      };
      case (#discountUnwound(x)) {
        let r = existing(s, x.facility);
        for ((ref, amount) in x.items.vals()) {
          switch (receivable(s, x.facility, ref)) { case (?rr) ignore RI.put(s.receivables, receivableKey(x.facility, ref), encodeReceivable({ rr with recognised = rr.recognised + amount })); case null {} };
        };
        putRow(s, x.facility, { r with lastAccrualDay = x.day }, block);
        s.accruals += 1;
      };
      case (#receivableCollected(x)) {
        let r = existing(s, x.facility);
        switch (receivable(s, x.facility, x.ref)) {
          case (?rr) { ignore RI.put(s.receivables, receivableKey(x.facility, x.ref), encodeReceivable({ rr with status = #collected; recognised = rr.discount })) };
          case null {};
        };
        putRow(s, x.facility, { r with openReceivables = if (r.openReceivables > 0) r.openReceivables - 1 else 0 }, block);
      };
      case (#receivableDishonoured(x)) {
        let r = existing(s, x.facility);
        switch (receivable(s, x.facility, x.ref)) {
          case (?rr) ignore RI.put(s.receivables, receivableKey(x.facility, x.ref), encodeReceivable({ rr with status = if (x.chargedBack) #writtenOff else #dishonoured; recognised = rr.discount }));
          case null {};
        };
        putRow(s, x.facility, { r with openReceivables = if (x.chargedBack and r.openReceivables > 0) r.openReceivables - 1 else r.openReceivables }, block);
      };
      case (#receivableWrittenOff(x)) {
        let r = existing(s, x.facility);
        switch (receivable(s, x.facility, x.ref)) { case (?rr) ignore RI.put(s.receivables, receivableKey(x.facility, x.ref), encodeReceivable({ rr with status = #writtenOff })); case null {} };
        putRow(s, x.facility, { r with openReceivables = if (r.openReceivables > 0) r.openReceivables - 1 else 0 }, block);
      };
      case (#rateFixingRecorded(x)) {
        ignore RI.put(s.fixings, R.key2(textKey(x.index), 8, x.day, 4), R.key(x.rateBps, 4));
        s.fixingCount += 1;
      };
      case (#drawingClosed(x)) {
        let r = existing(s, x.facility);
        ignore RI.put(s.drawings, R.key2(x.facility, 8, x.account, 8), Blob.fromArray([0]));
        putRow(s, x.facility, { r with openDrawings = if (r.openDrawings > 0) r.openDrawings - 1 else 0 }, block);
      };
      case (#facilityClosed(x)) { let r = existing(s, x.facility); putRow(s, x.facility, { r with stage = #closed }, block); s.closed += 1 };
    };
  };

  // ─── reads ────────────────────────────────────────────────────────────────

  public func view(s : State, id : FT.FacilityId, covenants : [FT.Covenant]) : ?FT.FacilityView {
    let ?r = row(s, id) else return null;
    let kind : FT.Kind = switch (r.kind) { case (#syndicatedAgent(x)) #syndicatedAgent({ x with shares = sharesOf(s, id) }); case (k) k };
    ?{
      id; party = r.party; book = r.book; product = r.product; kind; currency = r.currency; limit = r.limit; stage = r.stage;
      availabilityFrom = r.availabilityFrom; availabilityTo = r.availabilityTo; pricing = r.pricing; covenants;
      drawings = r.drawings; openDrawings = r.openDrawings; receivables = r.receivables; openReceivables = r.openReceivables;
      covenantBreaches = r.breaches; nextReview = r.nextReview; openedBlock = r.openedBlock; lastBlock = r.lastBlock;
    }
  };

  public func listByParty(s : State, party : PT.PartyId, cursor : ?Blob, limit : Nat) : { ids : [FT.FacilityId]; cursor : ?Blob } {
    let (lo, hi) = R.prefixRange(party, 8, 8);
    let page = RI.range(s.byParty, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    { ids = Array.map<(Blob, Blob), FT.FacilityId>(page.entries, func((k, _)) { R.getNat(Blob.toArray(k), 8, 8) }); cursor = page.cursor }
  };
  public func listByStage(s : State, stage : FT.Stage, cursor : ?Blob, limit : Nat) : { ids : [FT.FacilityId]; cursor : ?Blob } {
    let (lo, hi) = R.prefixRange(Nat8.toNat(FT.stageCode(stage)), 1, 8);
    let page = RI.range(s.byStage, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    let out = List.empty<FT.FacilityId>();
    for ((k, _) in page.entries.vals()) { let id = R.getNat(Blob.toArray(k), 1, 8); switch (row(s, id)) { case (?r) { if (r.stage == stage) List.add(out, id) }; case null {} } };
    { ids = List.toArray(out); cursor = page.cursor }
  };
  /// Every facility not yet closed whose currency is `ccy` — the guard a redenomination reads.
  /// The open (or blocked) facilities in a currency by a walk of the stage index: the unit tests hold it equal to
  /// the fold's counter above; the bank reads the counter.
  public func openInCurrencyWalked(s : State, ccy : Text) : Nat {
    var n = 0;
    for (st in [#open, #blocked].vals()) {
      let (lo, hi) = R.prefixRange(Nat8.toNat(FT.stageCode(st)), 1, 8);
      var cursor : ?Blob = null;
      label walk loop {
        let page = RI.range(s.byStage, lo, hi, cursor, MAX_PAGE);
        for ((k, _) in page.entries.vals()) { let id = R.getNat(Blob.toArray(k), 1, 8); switch (row(s, id)) { case (?r) { if (r.stage == st and Text.equal(r.currency, ccy)) n += 1 }; case null {} } };
        switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
      };
    };
    n
  };
  /// Every facility of a book not yet closed — what the batch walks; bounded by the rows.
  func bookKey(book : Text, id : Nat) : Blob { Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.textKey(book, 32)), Blob.toArray(R.key(id, 8)))) };
  public func bookCursor(book : Text, id : Nat) : Blob { bookKey(book, id) };
  /// The open facilities of a book, one page off the book index from a cursor (`bookCursor(book, id)` to resume at an id):
  /// what the end-of-day walks a chunk at a time (the adversarial audit of 13 September, finding A2).
  public func openInBookFrom(s : State, book : Text, cursor : ?Blob, limit : Nat) : { ids : [FT.FacilityId]; cursor : ?Blob } {
    let lo = bookKey(book, 0);
    let hi = Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.textKey(book, 32)), Array.repeat<Nat8>(255, 8)));
    let page = RI.range(s.byBook, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    let out = List.empty<Nat>();
    for ((k, _) in page.entries.vals()) { let id = R.getNat(Blob.toArray(k), 32, 8); switch (row(s, id)) { case (?r) { if (stageOpen(r.stage)) List.add(out, id) }; case null {} } };
    { ids = List.toArray(out); cursor = page.cursor }
  };
  public func openInBook(s : State, book : Text) : [FT.FacilityId] {
    let out = List.empty<FT.FacilityId>();
    for (st in [#open, #blocked].vals()) {
      let (lo, hi) = R.prefixRange(Nat8.toNat(FT.stageCode(st)), 1, 8);
      var cursor : ?Blob = null;
      label walk loop {
        let page = RI.range(s.byStage, lo, hi, cursor, MAX_PAGE);
        for ((k, _) in page.entries.vals()) { let id = R.getNat(Blob.toArray(k), 1, 8); switch (row(s, id)) { case (?r) { if (r.stage == st and Text.equal(r.book, book)) List.add(out, id) }; case null {} } };
        switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
      };
    };
    List.toArray(out)
  };
  public func counts(s : State) : { facilities : Nat; closed : Nat; drawn : Nat; accruals : Nat; fixings : Nat } {
    { facilities = s.facilities; closed = s.closed; drawn = s.drawn; accruals = s.accruals; fixings = s.fixingCount }
  };
  public func kindDistribution(s : State) : [(Text, Nat)] {
    let cs = VarArray.repeat<Nat>(0, 8);
    let (lo, hi) = R.fullRange(8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.rows, lo, hi, cursor, MAX_PAGE);
      for ((_, v) in page.entries.vals()) { let r = decodeRow(v); cs[Nat8.toNat(FT.kindCode(r.kind))] += 1 };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    let names = ["bilateralTerm", "revolving", "syndicatedAgent", "syndicatedParticipant", "financeLease", "operatingLease", "factoring", "forfaiting"];
    Array.tabulate<(Text, Nat)>(8, func(i) { (names[i], cs[i]) })
  };

  // ─── fingerprint ──────────────────────────────────────────────────────────

  func fingerprintRows(w : C.Writer, idx : RI.State, width : Nat) {
    let (lo, hi) = R.fullRange(width);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(idx, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) { w.blobRaw(k); w.blobRaw(v) };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
  };
  public func fingerprintInto(w : C.Writer, s : State) {
    w.nat(Map.size(s.openByBook));
    for ((k, v) in Map.entries(s.openByBook)) { w.text(k); w.nat(v) };
    w.nat(Map.size(s.openByCurrency));
    for ((k, v) in Map.entries(s.openByCurrency)) { w.text(k); w.nat(v) };
    w.nat(s.facilities); w.nat(s.closed); w.nat(s.drawn); w.nat(s.accruals); w.nat(s.fixingCount);
    fingerprintRows(w, s.rows, 8); fingerprintRows(w, s.byParty, 16); fingerprintRows(w, s.byBook, 40); fingerprintRows(w, s.byStage, 9);
    fingerprintRows(w, s.drawings, 16); fingerprintRows(w, s.drawingOf, 8); fingerprintRows(w, s.shares, 16);
    fingerprintRows(w, s.receivables, 16); fingerprintRows(w, s.covenants, 16); fingerprintRows(w, s.fixings, 12); fingerprintRows(w, s.subledgers, 32);
  };
}
