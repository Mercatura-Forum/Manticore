/// TreasuryCore.mo — the treasury book folded from the bank's log in stable memory (treasury): deals, securities,
/// curves, limits, nostros, the nostro's own postings as an index over the journal, statements and breaks.
///
/// Rows: one per deal (keyed by the block that captured it) with the fixed facts and the running figures the
/// postings have made — accrued, amortised, fair-value adjustment, mark, realised, the nominal and cost left of a
/// security lot, the settled legs; one per registered security; one per curve per day; one per limit; one per
/// nostro; one per posting leg on a nostro account (the bank's side of the reconciliation, written as the journal
/// commits); one per statement (its hash, so a statement is recorded once); one per break. The valuation arithmetic
/// lives in `TreasuryMath.mo`; here it is applied to rows, and the postings each act needs are built as legs the
/// bank posts — the same shape as every domain since S2.
///
/// Decisions this file makes (DESIGN §25): a deal's terms live in the block that captured (or last amended) it,
/// and the row points at that block; positions are folds over the open rows, not stored; a security lot is its
/// purchase deal, sales consume lots first-in-first-out or pro rata by the book's recorded method, pro rata to what
/// is actually booked so the securities account reaches zero when the last unit leaves; a mark is one debit-normal
/// account per instrument class carrying the signed figure per deal sub-ledger; a statement's entries are matched
/// by reference first, then by amount and value date within the nostro's tolerance, deterministically in the
/// order recorded; a break is a block, and its id that block's index.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Result "mo:core/Result";
import Text "mo:core/Text";
import VarArray "mo:core/VarArray";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";
import JT "mo:journal/JournalTypes";

import TT "TreasuryTypes";
import M "TreasuryMath";
import DC "DayCount";
import Fx "Fx";
import Posting "Posting";
import R "StableRows";

module {

  public let DEAL_ROW_BYTES : Nat = 205;
  public let SECURITY_ROW_BYTES : Nat = 70;
  public let CURVE_ROW_BYTES : Nat = 258;
  public let NOSTRO_ROW_BYTES : Nat = 98;
  public let NOSTRO_LEG_ROW_BYTES : Nat = 26;
  public let BREAK_ROW_BYTES : Nat = 80;
  public let STATEMENT_ROW_BYTES : Nat = 44;
  public let MAX_CURVE_POINTS : Nat = 16;
  public let MAX_STATEMENT_ENTRIES : Nat = 500;
  public let MAX_SWAP_PERIODS : Nat = 64;
  let MAX_PAGE = 512;

  // ─── keys, codes, sub-ledgers ─────────────────────────────────────────────

  /// The sub-ledger of a deal on every account it posts to.
  public func dealSub(id : TT.DealId) : JT.SubledgerKey { Posting.subledgerOf("treasury/" # Nat.toText(id)) };
  public func holdsSubledger(s : State, sub : JT.SubledgerKey) : Bool { sub.size() == 32 and RI.get(s.subledgers, sub) != null };
  func holdSub(s : State, sub : JT.SubledgerKey) { ignore RI.put(s.subledgers, sub, Blob.fromArray([1])) };
  func hashText(t : Text) : Blob { Sha256.fromBlob(#sha256, Text.encodeUtf8(t)) };
  public func hash8(t : Text) : Nat { R.getNat(Blob.toArray(hashText(t)), 0, 8) };
  /// The identity of a nostro's journal account: account ‖ sub-ledger key ‖ currency, hashed to eight bytes.
  public func nostroAccountHash(account : Text, sub : ?JT.SubledgerKey, currency : Text) : Nat {
    let w = C.Writer(); w.text(account); w.blob(switch (sub) { case (?b) b; case null ("" : Blob) }); w.text(currency);
    R.getNat(Blob.toArray(Sha256.fromBlob(#sha256, w.toBlob())), 0, 8)
  };
  public func cashSub(c : TT.CashAccount) : ?JT.SubledgerKey { switch (c.sub) { case (?t) ?Posting.subledgerOf(t); case null null } };

  func kindCode(k : TT.DealKind) : Nat8 { switch (k) { case (#moneyMarket(_)) 1; case (#fxForward(_)) 2; case (#fxSwap(_)) 3; case (#security(_)) 4; case (#irs(_)) 5; case (#fxOption(_)) 6 } };
  public func kindTextOf(c : Nat8) : Text { switch (c) { case 1 "moneyMarket"; case 2 "fxForward"; case 3 "fxSwap"; case 4 "security"; case 5 "irs"; case 6 "fxOption"; case _ "?" } };
  public func stateCode(s : TT.DealState) : Nat8 { switch (s) { case (#captured) 1; case (#confirmed) 2; case (#settled) 3; case (#cancelled) 4 } };
  func stateOf(c : Nat8) : TT.DealState { switch (c) { case 1 #captured; case 2 #confirmed; case 3 #settled; case _ #cancelled } };
  func curveKindCode(k : TT.CurveKind) : Nat8 { switch (k) { case (#zeroRates) 1; case (#forwardPoints) 2; case (#volatility) 3; case (#securityPrice) 4 } };
  func curveKindOf(c : Nat8) : TT.CurveKind { switch (c) { case 1 #zeroRates; case 2 #forwardPoints; case 3 #volatility; case _ #securityPrice } };
  public func limitCode(k : TT.LimitKind) : Nat8 { switch (k) { case (#counterpartyExposure) 1; case (#openFxPosition) 2; case (#tenorBucket) 3; case (#dv01) 4; case (#stopLoss) 5; case (#issuerConcentration) 6 } };
  func limitKindOf(c : Nat8) : TT.LimitKind { switch (c) { case 1 #counterpartyExposure; case 2 #openFxPosition; case 3 #tenorBucket; case 4 #dv01; case 5 #stopLoss; case _ #issuerConcentration } };
  func convCode(c : DC.Convention) : Nat8 { switch (c) { case (#a001_ActActIcma(_)) 1; case (#a003_Act360) 3; case (#a004_Act365Fixed) 4; case (#a005_ActActIsda) 5; case (#a006_Thirty360Isda) 6; case (#a007_ThirtyE360) 7; case (#a011_Thirty365) 11 } };
  func convOf(c : Nat8, cpy : Nat) : DC.Convention { switch (c) { case 1 #a001_ActActIcma({ couponsPerYear = cpy }); case 3 #a003_Act360; case 4 #a004_Act365Fixed; case 5 #a005_ActActIsda; case 6 #a006_Thirty360Isda; case 7 #a007_ThirtyE360; case _ #a011_Thirty365 } };
  public let F_CONFIRMED : Nat8 = 1;
  public let F_WITHIN : Nat8 = 2;
  public let F_BUY : Nat8 = 4;        // buy / placement / pay fixed / bought
  public let F_CALL : Nat8 = 8;
  public let F_FVOCI : Nat8 = 16;
  public let F_FVTPL : Nat8 = 32;
  public let F_ALERTED : Nat8 = 64;   // the overdue-confirmation alert was raised once
  func has(flags : Nat8, f : Nat8) : Bool { (flags & f) != 0 };

  func putInt(b : R.Buf, v : Int) { R.putByte(b, if (v < 0) 1 else 0); R.putNat(b, Int.abs(v), 8) };
  func getInt(a : [Nat8], off : Nat) : Int { let m = R.getNat(a, off + 1, 8); if (a[off] == 1) -m else m };

  // ─── rows ─────────────────────────────────────────────────────────────────

  public type DealRow = {
    id : TT.DealId; kind : Nat8; state : TT.DealState; flags : Nat8; book : Text; cpHash : Nat; currency : Text; notional : Nat;
    secondCurrency : Text; secondAmount : Nat; day : Nat; start : Nat; maturity : Nat; rate : Nat;
    accruedPosted : Int; amortisedPosted : Int; fvPosted : Int; markPosted : Int; realised : Int;
    nominalLeft : Nat; costLeft : Nat; yieldMillionths : Nat; settledMask : Nat; legs : Nat; lastBlock : Nat; termsBlock : Nat; isin : Text; refHash : Nat;
  };
  public type SecurityRow = { isin : Text; issuerHash : Nat; issuer : Text; currency : Text; couponBps : Nat; couponsPerYear : Nat; dayCount : Nat8; issue : Nat; maturity : Nat; block : Nat };
  public type CurveRow = { id : Text; day : Nat; kind : TT.CurveKind; currency : Text; points : [(Nat, Int)]; source : Blob; block : Nat };
  public type NostroRow = { id : Text; account : Text; subText : Text; hasSub : Bool; currency : Text; accountHash : Nat; tolerance : Nat; correspondentHash : Nat; block : Nat };
  public type NostroLegRow = { nostroHash : Nat; valueDay : Nat; posting : Nat; amount : Nat; debit : Bool; status : Nat8; refHash : Nat; statement8 : Nat };
  public type BreakRow = { id : TT.BreakId; nostroHash : Nat; side : TT.BreakSide; amount : Nat; credit : Bool; valueDay : Nat; refHash : Nat; posting : Nat; openedDay : Nat; resolved : Bool; resolvedDay : Nat; statement : Blob; alerted : Bool };
  public let LEG_OPEN : Nat8 = 0;
  public let LEG_MATCHED : Nat8 = 1;
  public let LEG_BROKEN : Nat8 = 2;

  func encodeDeal(r : DealRow) : Blob {
    let b = R.buf();
    R.putByte(b, r.kind); R.putByte(b, stateCode(r.state)); R.putByte(b, r.flags); R.putText(b, r.book, 32); R.putNat(b, r.cpHash, 8);
    R.putText(b, r.currency, 8); R.putNat(b, r.notional, 8); R.putText(b, r.secondCurrency, 8); R.putNat(b, r.secondAmount, 8);
    R.putNat(b, r.day, 4); R.putNat(b, r.start, 4); R.putNat(b, r.maturity, 4); R.putNat(b, r.rate, 8);
    putInt(b, r.accruedPosted); putInt(b, r.amortisedPosted); putInt(b, r.fvPosted); putInt(b, r.markPosted); putInt(b, r.realised);
    R.putNat(b, r.nominalLeft, 8); R.putNat(b, r.costLeft, 8); R.putNat(b, r.yieldMillionths, 4); R.putNat(b, r.settledMask, 8); R.putNat(b, r.legs, 1);
    R.putNat(b, r.lastBlock, 8); R.putNat(b, r.termsBlock, 8); R.putText(b, r.isin, 12); R.putNat(b, r.refHash, 8);
    R.done(b, DEAL_ROW_BYTES)
  };
  func decodeDeal(id : Nat, v : Blob) : DealRow {
    let a = Blob.toArray(v);
    {
      id; kind = a[0]; state = stateOf(a[1]); flags = a[2]; book = R.getText(a, 3, 32); cpHash = R.getNat(a, 35, 8);
      currency = R.getText(a, 43, 8); notional = R.getNat(a, 51, 8); secondCurrency = R.getText(a, 59, 8); secondAmount = R.getNat(a, 67, 8);
      day = R.getNat(a, 75, 4); start = R.getNat(a, 79, 4); maturity = R.getNat(a, 83, 4); rate = R.getNat(a, 87, 8);
      accruedPosted = getInt(a, 95); amortisedPosted = getInt(a, 104); fvPosted = getInt(a, 113); markPosted = getInt(a, 122); realised = getInt(a, 131);
      nominalLeft = R.getNat(a, 140, 8); costLeft = R.getNat(a, 148, 8); yieldMillionths = R.getNat(a, 156, 4); settledMask = R.getNat(a, 160, 8); legs = R.getNat(a, 168, 1);
      lastBlock = R.getNat(a, 169, 8); termsBlock = R.getNat(a, 177, 8); isin = R.getText(a, 185, 12); refHash = R.getNat(a, 197, 8);
    }
  };
  func encodeSecurity(r : SecurityRow) : Blob {
    let b = R.buf();
    R.putNat(b, r.issuerHash, 8); R.putText(b, r.issuer, 32); R.putText(b, r.currency, 8); R.putNat(b, r.couponBps, 4); R.putNat(b, r.couponsPerYear, 1); R.putByte(b, r.dayCount);
    R.putNat(b, r.issue, 4); R.putNat(b, r.maturity, 4); R.putNat(b, r.block, 8);
    R.done(b, SECURITY_ROW_BYTES)
  };
  func decodeSecurity(isin : Text, v : Blob) : SecurityRow {
    let a = Blob.toArray(v);
    { isin; issuerHash = R.getNat(a, 0, 8); issuer = R.getText(a, 8, 32); currency = R.getText(a, 40, 8); couponBps = R.getNat(a, 48, 4); couponsPerYear = R.getNat(a, 52, 1); dayCount = a[53];
      issue = R.getNat(a, 54, 4); maturity = R.getNat(a, 58, 4); block = R.getNat(a, 62, 8) }
  };
  func encodeCurve(r : CurveRow) : Blob {
    let b = R.buf();
    R.putByte(b, curveKindCode(r.kind)); R.putText(b, r.currency, 8); R.putNat(b, r.points.size(), 1);
    var i = 0;
    while (i < MAX_CURVE_POINTS) {
      if (i < r.points.size()) { R.putNat(b, r.points[i].0, 4); putInt(b, r.points[i].1) } else { R.putNat(b, 0, 4); putInt(b, 0) };
      i += 1;
    };
    R.putBlob(b, r.source, 32); R.putNat(b, r.block, 8);
    R.done(b, CURVE_ROW_BYTES)
  };
  func decodeCurve(id : Text, day : Nat, v : Blob) : CurveRow {
    let a = Blob.toArray(v);
    let n = R.getNat(a, 9, 1);
    let points = Array.tabulate<(Nat, Int)>(n, func(i) { (R.getNat(a, 10 + i * 13, 4), getInt(a, 14 + i * 13)) });
    { id; day; kind = curveKindOf(a[0]); currency = R.getText(a, 1, 8); points; source = R.getBlob(a, 218, 32); block = R.getNat(a, 250, 8) }
  };
  func encodeNostro(r : NostroRow) : Blob {
    let b = R.buf();
    R.putText(b, r.account, 32); R.putText(b, r.subText, 32); R.putBool(b, r.hasSub); R.putText(b, r.currency, 8); R.putNat(b, r.accountHash, 8); R.putNat(b, r.tolerance, 1); R.putNat(b, r.correspondentHash, 8); R.putNat(b, r.block, 8);
    R.done(b, NOSTRO_ROW_BYTES)
  };
  func decodeNostro(id : Text, v : Blob) : NostroRow {
    let a = Blob.toArray(v);
    { id; account = R.getText(a, 0, 32); subText = R.getText(a, 32, 32); hasSub = R.getBool(a, 64); currency = R.getText(a, 65, 8); accountHash = R.getNat(a, 73, 8); tolerance = R.getNat(a, 81, 1); correspondentHash = R.getNat(a, 82, 8); block = R.getNat(a, 90, 8) }
  };
  func legKey(nostroHash : Nat, valueDay : Nat, posting : Nat) : Blob { let b = R.buf(); R.putNat(b, nostroHash, 8); R.putNat(b, valueDay, 4); R.putNat(b, posting, 8); R.done(b, 20) };
  func encodeLeg(r : NostroLegRow) : Blob { let b = R.buf(); R.putNat(b, r.amount, 8); R.putBool(b, r.debit); R.putByte(b, r.status); R.putNat(b, r.refHash, 8); R.putNat(b, r.statement8, 8); R.done(b, NOSTRO_LEG_ROW_BYTES) };
  func decodeLeg(k : Blob, v : Blob) : NostroLegRow {
    let ka = Blob.toArray(k); let a = Blob.toArray(v);
    { nostroHash = R.getNat(ka, 0, 8); valueDay = R.getNat(ka, 8, 4); posting = R.getNat(ka, 12, 8); amount = R.getNat(a, 0, 8); debit = R.getBool(a, 8); status = a[9]; refHash = R.getNat(a, 10, 8); statement8 = R.getNat(a, 18, 8) }
  };
  func encodeBreak(r : BreakRow) : Blob {
    let b = R.buf();
    R.putNat(b, r.nostroHash, 8); R.putByte(b, switch (r.side) { case (#onStatementOnly) 1; case (#inOurBooksOnly) 2 }); R.putNat(b, r.amount, 8); R.putBool(b, r.credit); R.putNat(b, r.valueDay, 4);
    R.putNat(b, r.refHash, 8); R.putNat(b, r.posting, 8); R.putNat(b, r.openedDay, 4); R.putBool(b, r.resolved); R.putNat(b, r.resolvedDay, 4); R.putBlob(b, r.statement, 32); R.putBool(b, r.alerted);
    R.done(b, BREAK_ROW_BYTES)
  };
  func decodeBreak(id : Nat, v : Blob) : BreakRow {
    let a = Blob.toArray(v);
    { id; nostroHash = R.getNat(a, 0, 8); side = if (a[8] == 1) #onStatementOnly else #inOurBooksOnly; amount = R.getNat(a, 9, 8); credit = R.getBool(a, 17); valueDay = R.getNat(a, 18, 4);
      refHash = R.getNat(a, 22, 8); posting = R.getNat(a, 30, 8); openedDay = R.getNat(a, 38, 4); resolved = R.getBool(a, 42); resolvedDay = R.getNat(a, 43, 4); statement = R.getBlob(a, 47, 32); alerted = R.getBool(a, 79) }
  };

  // ─── state ────────────────────────────────────────────────────────────────

  public type State = {
    deals : RI.State;          // id(8) -> row
    securities : RI.State;     // isin(12) -> row
    curves : RI.State;         // id(32) ‖ day(4) -> row
    limits : RI.State;         // book(32) ‖ kind(1) ‖ currency(8) ‖ subjectHash(8) -> value(8)
    buckets : RI.State;        // book(32) ‖ subjectHash(8) -> fromDays(4) ‖ toDays(4), the bounds of a tenor-bucket limit
    nostros : RI.State;        // id(32) -> row
    nostroByAccount : RI.State;// accountHash(8) -> id(32)
    nostroLegs : RI.State;     // nostroHash(8) ‖ valueDay(4) ‖ posting(8) -> leg
    statements : RI.State;     // sha256(32) -> nostro(32) ‖ day(4) ‖ matched(4) ‖ breaks(4)
    legByPosting : RI.State;   // posting(8) ‖ nostroHash(8) -> valueDay(4)
    breaks : RI.State;         // id(8) -> row
    byBook : RI.State;         // book(32) ‖ id(8)
    byState : RI.State;        // state(1) ‖ id(8)
    byCounterparty : RI.State; // cpHash(8) ‖ id(8)
    byIsin : RI.State;         // isin(12) ‖ id(8)
    breaksByStatus : RI.State; // status(1) ‖ id(8)
    subledgers : RI.State;
    var policy : ?TT.Policy;
    var captured : Nat;
    var open : Nat;
    var curveCount : Nat;
    var securityCount : Nat;
    var limitCount : Nat;
    var nostroCount : Nat;
    var breaksTotal : Nat;
    var breaksOpen : Nat;
    var statementCount : Nat;
    var realisedTotal : Int;
    var markTotal : Int;
  };

  public func newState(arena : RI.Arena) : State {
    {
      deals = RI.newStateIn(arena, { keyBytes = 8; valBytes = DEAL_ROW_BYTES });
      securities = RI.newStateIn(arena, { keyBytes = 12; valBytes = SECURITY_ROW_BYTES });
      curves = RI.newStateIn(arena, { keyBytes = 36; valBytes = CURVE_ROW_BYTES });
      limits = RI.newStateIn(arena, { keyBytes = 49; valBytes = 8 });
      buckets = RI.newStateIn(arena, { keyBytes = 40; valBytes = 8 });
      nostros = RI.newStateIn(arena, { keyBytes = 32; valBytes = NOSTRO_ROW_BYTES });
      nostroByAccount = RI.newStateIn(arena, { keyBytes = 8; valBytes = 32 });
      nostroLegs = RI.newStateIn(arena, { keyBytes = 20; valBytes = NOSTRO_LEG_ROW_BYTES });
      statements = RI.newStateIn(arena, { keyBytes = 32; valBytes = STATEMENT_ROW_BYTES });
      legByPosting = RI.newStateIn(arena, { keyBytes = 16; valBytes = 4 });
      breaks = RI.newStateIn(arena, { keyBytes = 8; valBytes = BREAK_ROW_BYTES });
      byBook = RI.newStateIn(arena, { keyBytes = 40; valBytes = 1 });
      byState = RI.newStateIn(arena, { keyBytes = 9; valBytes = 1 });
      byCounterparty = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      byIsin = RI.newStateIn(arena, { keyBytes = 20; valBytes = 1 });
      breaksByStatus = RI.newStateIn(arena, { keyBytes = 9; valBytes = 1 });
      subledgers = RI.newStateIn(arena, { keyBytes = 32; valBytes = 1 });
      var policy = null; var captured = 0; var open = 0; var curveCount = 0; var securityCount = 0; var limitCount = 0; var nostroCount = 0;
      var breaksTotal = 0; var breaksOpen = 0; var statementCount = 0; var realisedTotal = 0; var markTotal = 0;
    }
  };

  public func policy(s : State) : ?TT.Policy { s.policy };
  public func row(s : State, id : TT.DealId) : ?DealRow { switch (RI.get(s.deals, R.key(id, 8))) { case (?v) ?decodeDeal(id, v); case null null } };
  public func security(s : State, isin : Text) : ?SecurityRow { switch (RI.get(s.securities, R.textKey(isin, 12))) { case (?v) ?decodeSecurity(isin, v); case null null } };
  public func nostro(s : State, id : Text) : ?NostroRow { switch (RI.get(s.nostros, R.textKey(id, 32))) { case (?v) ?decodeNostro(id, v); case null null } };
  public func nostroOfAccount(s : State, accountHash : Nat) : ?NostroRow {
    switch (RI.get(s.nostroByAccount, R.key(accountHash, 8))) { case (?v) nostro(s, R.getText(Blob.toArray(v), 0, 32)); case null null }
  };
  public func breakRow(s : State, id : TT.BreakId) : ?BreakRow { switch (RI.get(s.breaks, R.key(id, 8))) { case (?v) ?decodeBreak(id, v); case null null } };
  public func statementKnown(s : State, hash : Blob) : Bool { hash.size() == 32 and RI.get(s.statements, hash) != null };
  func putRow(s : State, r : DealRow) { ignore RI.put(s.deals, R.key(r.id, 8), encodeDeal(r)) };
  func putBreak(s : State, r : BreakRow) { ignore RI.put(s.breaks, R.key(r.id, 8), encodeBreak(r)) };
  func curveKey(id : Text, day : Nat) : Blob { Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.textKey(id, 32)), Blob.toArray(R.key(day, 4)))) };
  func limitKey(book : Text, kind : TT.LimitKind, currency : Text, subject : Text) : Blob {
    let b = R.buf(); R.putText(b, book, 32); R.putByte(b, limitCode(kind)); R.putText(b, currency, 8); R.putNat(b, hash8(subject), 8); R.done(b, 49)
  };
  public func limitOf(s : State, book : Text, kind : TT.LimitKind, currency : Text, subject : Text) : ?Nat {
    switch (RI.get(s.limits, limitKey(book, kind, currency, subject))) { case (?v) ?R.getNat(Blob.toArray(v), 0, 8); case null null }
  };

  /// The latest curve with this id published on or before `day`.
  public func curveOn(s : State, id : Text, day : Nat) : ?CurveRow {
    let lo = curveKey(id, 0); let hi = curveKey(id, day);
    var cursor : ?Blob = null;
    var last : ?(Blob, Blob) = null;
    label walk loop {
      let page = RI.range(s.curves, lo, hi, cursor, MAX_PAGE);
      if (page.entries.size() > 0) last := ?page.entries[page.entries.size() - 1];
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    switch (last) { case (?(k, v)) ?decodeCurve(id, R.getNat(Blob.toArray(k), 32, 4), v); case null null }
  };
  public func curveExactly(s : State, id : Text, day : Nat) : ?CurveRow { switch (RI.get(s.curves, curveKey(id, day))) { case (?v) ?decodeCurve(id, day, v); case null null } };

  public func isOpen(r : DealRow) : Bool { switch (r.state) { case (#captured or #confirmed) true; case (_) false } };
  public func legSettled(r : DealRow, leg : Nat) : Bool { (r.settledMask / (2 ** leg)) % 2 == 1 };
  public func settledCount(r : DealRow) : Nat { var n = 0; var i = 0; while (i < r.legs) { if (legSettled(r, i)) n += 1; i += 1 }; n };
  func classOf(flags : Nat8) : TT.Classification { if (has(flags, F_FVOCI)) #fvoci else if (has(flags, F_FVTPL)) #fvtpl else #amortisedCost };
  public func conventionOf(sec : SecurityRow) : DC.Convention { convOf(sec.dayCount, sec.couponsPerYear) };

  // ─── walking the indexes ───────────────────────────────────────────────────

  func idsUnder(idx : RI.State, lo : Blob, hi : Blob, offset : Nat) : [Nat] {
    let out = List.empty<Nat>();
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(idx, lo, hi, cursor, MAX_PAGE);
      for ((k, _) in page.entries.vals()) List.add(out, R.getNat(Blob.toArray(k), offset, 8));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  func textPrefixRange(t : Text, width : Nat, rest : Nat) : (Blob, Blob) {
    let p = Blob.toArray(R.textKey(t, width));
    (Blob.fromArray(Array.concat<Nat8>(p, Array.repeat<Nat8>(0, rest))), Blob.fromArray(Array.concat<Nat8>(p, Array.repeat<Nat8>(255, rest))))
  };
  /// Deals of a book, all states, ascending by id.
  public func dealsOfBook(s : State, book : Text) : [DealRow] {
    let (lo, hi) = textPrefixRange(book, 32, 8);
    Array.filterMap<Nat, DealRow>(idsUnder(s.byBook, lo, hi, 32), func(id) { row(s, id) })
  };
  public func openInBook(s : State, book : Text) : [DealRow] { Array.filter<DealRow>(dealsOfBook(s, book), isOpen) };
  /// Every open deal — what the batch walks.
  public func openAll(s : State) : [DealRow] {
    let out = List.empty<DealRow>();
    for (st in [#captured, #confirmed].vals()) {
      let (lo, hi) = R.prefixRange(Nat8.toNat(stateCode(st)), 1, 8);
      for (id in idsUnder(s.byState, lo, hi, 1).vals()) { switch (row(s, id)) { case (?r) { if (r.state == st) List.add(out, r) }; case null {} } };
    };
    List.toArray(out)
  };
  public func listByState(s : State, st : TT.DealState, cursor : ?Blob, limit : Nat) : { ids : [TT.DealId]; cursor : ?Blob } {
    let (lo, hi) = R.prefixRange(Nat8.toNat(stateCode(st)), 1, 8);
    let page = RI.range(s.byState, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    let out = List.empty<Nat>();
    for ((k, _) in page.entries.vals()) { let id = R.getNat(Blob.toArray(k), 1, 8); switch (row(s, id)) { case (?r) { if (r.state == st) List.add(out, id) }; case null {} } };
    { ids = List.toArray(out); cursor = page.cursor }
  };
  public func listByCounterparty(s : State, name : Text, cursor : ?Blob, limit : Nat) : { ids : [TT.DealId]; cursor : ?Blob } {
    let (lo, hi) = R.prefixRange(hash8(name), 8, 8);
    let page = RI.range(s.byCounterparty, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    { ids = Array.map<(Blob, Blob), Nat>(page.entries, func((k, _)) { R.getNat(Blob.toArray(k), 8, 8) }); cursor = page.cursor }
  };
  /// The settled purchase lots of a security in a book with nominal left, oldest first: what a sale can take from.
  public func lotsOf(s : State, book : Text, isin : Text) : [DealRow] {
    let (lo, hi) = textPrefixRange(isin, 12, 8);
    Array.filter<DealRow>(Array.filterMap<Nat, DealRow>(idsUnder(s.byIsin, lo, hi, 12), func(id) { row(s, id) }), func(r) { Text.equal(r.book, book) and has(r.flags, F_BUY) and r.nominalLeft > 0 and r.state != #cancelled and legSettled(r, 0) })
  };
  public func limitsOf(s : State, book : Text) : [TT.Limit] {
    let (lo, hi) = textPrefixRange(book, 32, 17);
    let out = List.empty<TT.Limit>();
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.limits, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) {
        let a = Blob.toArray(k);
        // the subject is a hash in the key; the limit's text lives in its block, so the view carries the hash as text
        List.add(out, { book; kind = limitKindOf(a[32]); currency = R.getText(a, 33, 8); subject = Nat.toText(R.getNat(a, 41, 8)); value = R.getNat(Blob.toArray(v), 0, 8) });
      };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  public func openBreaks(s : State) : [BreakRow] {
    let (lo, hi) = R.prefixRange(0, 1, 8);
    Array.filter<BreakRow>(Array.filterMap<Nat, BreakRow>(idsUnder(s.breaksByStatus, lo, hi, 1), func(id) { breakRow(s, id) }), func(b) { not b.resolved })
  };
  public func breaksOfNostro(s : State, nostroId : Text, includeResolved : Bool) : [BreakRow] {
    let ?nr = nostro(s, nostroId) else return [];
    let h = nr.accountHash;
    let (lo, hi) = if (includeResolved) R.fullRange(9) else R.prefixRange(0, 1, 8);
    Array.filter<BreakRow>(Array.filterMap<Nat, BreakRow>(idsUnder(s.breaksByStatus, lo, hi, 1), func(id) { breakRow(s, id) }), func(b) { b.nostroHash == h and (includeResolved or not b.resolved) })
  };
  /// Our postings on a nostro with value day in a window, ascending by (value day, posting).
  public func nostroLegsIn(s : State, nostroHash : Nat, from : Nat, to : Nat) : [NostroLegRow] {
    let lo = legKey(nostroHash, from, 0); let hi = legKey(nostroHash, to, 0xFFFF_FFFF_FFFF_FFFF);
    let out = List.empty<NostroLegRow>();
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.nostroLegs, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) List.add(out, decodeLeg(k, v));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };

  // ─── the terms, as schedules ───────────────────────────────────────────────

  public type Ctx = {
    functional : Text;
    spot : (Text, Nat) -> ?Fx.Rate;          // the recorded rate of a foreign currency on a day
    pair : Text -> ?Fx.PositionPair;
    fixing : (Text, Nat) -> ?Nat;            // the recorded fixing of an index on a day, in bps
    isShariaBook : Text -> Bool;
  };
  public type Act = { ev : TT.TreasuryEvent; legs : [JT.Leg]; extras : [TT.TreasuryEvent] };
  type Res<X> = Result.Result<X, TT.TreasuryError>;
  func bad<X>(reason : Text) : Res<X> { #err(#InvalidTerms({ reason })) };
  func bytesOf(t : Text) : Nat { Text.encodeUtf8(t).size() };
  func ccyOk(c : Text) : Bool { bytesOf(c) == 3 };

  public func couponPeriodsOf(sec : SecurityRow, nominal : Nat) : [M.Coupon] {
    M.couponPeriods(nominal, sec.couponBps, sec.couponsPerYear, conventionOf(sec), sec.issue, sec.maturity)
  };
  public func swapPeriodsOf(i : TT.Irs) : [M.SwapPeriod] { M.swapPeriods(i.start, i.maturity, i.paymentMonths) };
  /// A purchase lot's constant-yield schedule, recomputed from the row and the security's terms.
  public func lotSchedule(r : DealRow, sec : SecurityRow) : [M.AmortisationStep] {
    if (r.yieldMillionths == 0 and r.costLeft == r.notional) return [];
    M.amortisationSchedule(r.notional, couponPeriodsOf(sec, r.notional), conventionOf(sec), sec.couponsPerYear, r.start, r.secondAmount, r.yieldMillionths)
  };
  /// The cumulative amortisation of a lot at `day`, on its original nominal.
  public func lotAmortisationTo(r : DealRow, sec : SecurityRow, day : Nat) : Int {
    var total : Int = 0;
    for (st in lotSchedule(r, sec).vals()) total += M.amortisationTo(st, day);
    total
  };
  public func yieldFor(sec : SecurityRow, t : TT.SecurityTrade) : Nat {
    let periods = couponPeriodsOf(sec, t.nominal);
    let clean = M.cleanCost(t.nominal, t.priceMicro);
    let accrued = M.accruedCoupon(t.nominal, sec.couponBps, conventionOf(sec), periods, t.settlement);
    M.effectiveYieldMillionths(t.nominal, periods, conventionOf(sec), sec.couponsPerYear, t.settlement, clean + accrued)
  };

  // ─── configuration planners ────────────────────────────────────────────────

  public func accountsOf(p : TT.Policy) : [Text] {
    [p.mmPlacements, p.mmTakings, p.mmInterestReceivable, p.mmInterestPayable, p.mmInterestIncome, p.mmInterestExpense, p.fxForwardMark, p.irsMark, p.fxOptionValue,
     p.unrealisedTradingGain, p.unrealisedTradingLoss, p.realisedTradingGain, p.realisedTradingLoss, p.securitiesAmortisedCost, p.securitiesFvoci, p.securitiesFvtpl, p.fvociReserve,
     p.couponReceivable, p.couponIncome, p.amortisationIncome, p.amortisationExpense, p.nostroSuspense]
  };
  public func planPolicy(p : TT.Policy) : Res<TT.TreasuryEvent> {
    for (a in accountsOf(p).vals()) { if (bytesOf(a) == 0) return #err(#InvalidPolicy({ reason = "every role account is named" })) };
    if (p.maxCurvePoints == 0 or p.maxCurvePoints > MAX_CURVE_POINTS) return #err(#InvalidPolicy({ reason = "maxCurvePoints in 1.." # Nat.toText(MAX_CURVE_POINTS) }));
    if (p.confirmationDueDays == 0 or p.confirmationDueDays > 30) return #err(#InvalidPolicy({ reason = "confirmationDueDays in 1..30" }));
    if (p.breakAgeAlertDays == 0 or p.breakAgeAlertDays > 180) return #err(#InvalidPolicy({ reason = "breakAgeAlertDays in 1..180" }));
    #ok(#policySet(p))
  };
  public func planRegisterSecurity(s : State, t : TT.SecurityTerms, day : Nat) : Res<TT.TreasuryEvent> {
    if (bytesOf(t.isin) != 12) return bad("an ISIN has twelve characters");
    if (security(s, t.isin) != null) return bad("security " # t.isin # " is already registered");
    if (bytesOf(t.issuer) == 0 or bytesOf(t.issuer) > 32) return bad("the issuer is named in at most 32 bytes");
    if (not ccyOk(t.currency)) return bad("the currency is a three-letter code");
    if (t.couponsPerYear != 1 and t.couponsPerYear != 2 and t.couponsPerYear != 4 and t.couponsPerYear != 12) return bad("coupons per year is 1, 2, 4 or 12");
    if (t.couponBps > 100_000) return bad("the coupon exceeds 1000 %");
    if (t.issue >= t.maturity) return bad("the issue precedes the maturity");
    switch (t.dayCount) { case (#a001_ActActIcma(x)) { if (x.couponsPerYear != t.couponsPerYear) return bad("ACT/ACT (ICMA) names the coupon frequency") }; case (_) {} };
    if (M.couponPeriods(100, t.couponBps, t.couponsPerYear, t.dayCount, t.issue, t.maturity).size() == 0) return bad("the maturity is not on the coupon grid from the issue");
    #ok(#securityRegistered({ terms = t; day }))
  };
  /// Null when an identical curve is already recorded for the day (nothing to record).
  public func planPublishCurve(s : State, c : TT.Curve) : Res<?TT.TreasuryEvent> {
    let ?p = s.policy else return #err(#NoPolicy);
    if (bytesOf(c.id) == 0 or bytesOf(c.id) > 32) return bad("a curve id is 1..32 bytes");
    if (not ccyOk(c.currency)) return bad("the currency is a three-letter code");
    if (c.source.size() != 32) return bad("the source is a sha256");
    if (not M.validPoints(c.points, p.maxCurvePoints)) return bad("points are sorted strictly by tenor, 1.." # Nat.toText(p.maxCurvePoints));
    switch (c.kind) {
      case (#securityPrice) { if (c.points.size() != 1 or c.points[0].0 != 0 or c.points[0].1 <= 0) return bad("a price curve is one positive point at tenor 0") };
      case (#zeroRates or #volatility) { for ((_, v) in c.points.vals()) { if (v < 0) return bad("rates and volatilities are not negative") } };
      case (#forwardPoints) {};
    };
    switch (curveExactly(s, c.id, c.day)) {
      case (?existing) {
        if (existing.kind == c.kind and Text.equal(existing.currency, c.currency) and Blob.equal(existing.source, c.source) and Array.equal<(Nat, Int)>(existing.points, c.points, func(a, b) { a.0 == b.0 and a.1 == b.1 })) return #ok(null);
        return bad("a different curve " # c.id # " is already recorded for day " # Nat.toText(c.day));
      };
      case null {};
    };
    #ok(?#curvePublished({ curve = c }))
  };
  /// The tenor bucket of a limit's subject, "fromDays-toDays".
  public func parseBucket(subject : Text) : ?(Nat, Nat) {
    let parts = Text.split(subject, #char '-');
    let ?a = parts.next() else return null; let ?b = parts.next() else return null;
    if (parts.next() != null) return null;
    let ?lo = Nat.fromText(a) else return null; let ?hi = Nat.fromText(b) else return null;
    if (lo > hi) return null;
    ?(lo, hi)
  };
  public func planSetLimit(l : TT.Limit, day : Nat) : Res<TT.TreasuryEvent> {
    if (bytesOf(l.book) == 0 or bytesOf(l.book) > 32) return bad("a book is named in 1..32 bytes");
    if (not ccyOk(l.currency)) return bad("the currency is a three-letter code");
    if (l.value == 0) return bad("a limit is positive");
    switch (l.kind) {
      case (#counterpartyExposure or #issuerConcentration) { if (bytesOf(l.subject) == 0 or bytesOf(l.subject) > 64) return bad("the subject names the counterparty or issuer") };
      case (#tenorBucket) { if (parseBucket(l.subject) == null) return bad("a tenor bucket is \"fromDays-toDays\"") };
      case (#openFxPosition or #dv01 or #stopLoss) { if (bytesOf(l.subject) != 0) return bad("this limit kind has no subject") };
    };
    #ok(#limitSet({ limit = l; day }))
  };
  public func planRegisterNostro(s : State, n : TT.Nostro, day : Nat) : Res<TT.TreasuryEvent> {
    if (bytesOf(n.id) == 0 or bytesOf(n.id) > 32) return bad("a nostro id is 1..32 bytes");
    if (nostro(s, n.id) != null) return bad("nostro " # n.id # " is already registered");
    if (bytesOf(n.account) == 0 or bytesOf(n.account) > 32) return bad("the account code is 1..32 bytes");
    switch (n.sub) { case (?t) { if (bytesOf(t) == 0 or bytesOf(t) > 32) return bad("the sub-ledger name is 1..32 bytes") }; case null {} };
    if (not ccyOk(n.currency)) return bad("the currency is a three-letter code");
    if (n.valueDateToleranceDays > 30) return bad("the value-date tolerance is at most 30 days");
    if (bytesOf(n.correspondent.bic) != 8 and bytesOf(n.correspondent.bic) != 11) return bad("the correspondent's BIC has 8 or 11 characters");
    let h = nostroAccountHash(n.account, switch (n.sub) { case (?t) ?Posting.subledgerOf(t); case null null }, n.currency);
    if (nostroOfAccount(s, h) != null) return bad("that account is already a nostro");
    #ok(#nostroRegistered({ nostro = n; day }))
  };

  // ─── deals: validation, the second amount, the legs of a kind ──────────────

  func validForward(f : TT.FxForward, functional : Text, day : Nat) : ?Text {
    if (not Text.equal(f.quote, functional)) return ?"the quote currency of a forward is the functional currency";
    if (Text.equal(f.base, f.quote) or not ccyOk(f.base)) return ?"the base is a foreign currency";
    if (f.baseAmount == 0) return ?"the base amount is positive";
    if (f.rateMicro == 0) return ?"the rate is positive";
    if (f.spotMicro + f.forwardPointsMicro != f.rateMicro) return ?"rate = spot + forward points";
    if (f.valueDate < day) return ?"the value date is not in the past";
    if (bytesOf(f.baseAccount.account) == 0 or bytesOf(f.quoteAccount.account) == 0) return ?"both settlement accounts are named";
    if (bytesOf(f.pointsCurve) == 0 or bytesOf(f.discountCurve) == 0) return ?"the points and discount curves are named";
    null
  };
  /// A settlement account: a journal account, or a registered nostro when it names a sub-ledger — the only sub-ledgers
  /// a treasury leg may name besides the deal's own.
  func cashOk(s : State, c : TT.CashAccount, ccy : Text) : ?Text {
    if (bytesOf(c.account) == 0) return ?"the settlement account is named";
    switch (c.sub) {
      case null null;
      case (?t) { if (nostroOfAccount(s, nostroAccountHash(c.account, ?Posting.subledgerOf(t), ccy)) == null) ?("the settlement account " # c.account # "/" # t # " in " # ccy # " is not a registered nostro") else null };
    }
  };
  /// Validate a kind's terms against the day, the functional currency and the book; the second amount of the deal.
  public func validateKind(s : State, kind : TT.DealKind, book : Text, day : Nat, ctx : Ctx) : Res<Nat> {
    let sharia = ctx.isShariaBook(book);
    switch (kind) {
      case (#moneyMarket(m)) {
        if (sharia) return #err(#ShariaBook({ book; kind = "moneyMarket" }));
        if (not ccyOk(m.currency)) return bad("the currency is a three-letter code");
        if (m.principal == 0) return bad("the principal is positive");
        if (m.rateBps > 1_000_000) return bad("the rate exceeds 10000 %");
        if (m.start >= m.maturity) return bad("the start precedes the maturity");
        if (m.start < day) return bad("the start is not in the past");
        switch (cashOk(s, m.cash, m.currency)) { case (?r) return bad(r); case null {} };
        #ok(0)
      };
      case (#fxForward(f)) {
        switch (validForward(f, ctx.functional, day)) { case (?r) return bad(r); case null {} };
        switch (cashOk(s, f.baseAccount, f.base)) { case (?r) return bad(r); case null {} };
        switch (cashOk(s, f.quoteAccount, f.quote)) { case (?r) return bad(r); case null {} };
        #ok(M.quoteAmount(f.baseAmount, f.rateMicro))
      };
      case (#fxSwap(x)) {
        switch (validForward(x.near, ctx.functional, day)) { case (?r) return bad("near leg: " # r); case null {} };
        switch (validForward(x.far, ctx.functional, day)) { case (?r) return bad("far leg: " # r); case null {} };
        if (not Text.equal(x.near.base, x.far.base)) return bad("both legs of a swap are on one pair");
        if (x.near.direction == x.far.direction) return bad("the legs of a swap run opposite ways");
        if (x.far.valueDate <= x.near.valueDate) return bad("the far leg settles after the near");
        for (f in [x.near, x.far].vals()) {
          switch (cashOk(s, f.baseAccount, f.base)) { case (?r) return bad(r); case null {} };
          switch (cashOk(s, f.quoteAccount, f.quote)) { case (?r) return bad(r); case null {} };
        };
        #ok(M.quoteAmount(x.near.baseAmount, x.near.rateMicro))
      };
      case (#security(t)) {
        let ?sec = security(s, t.isin) else return #err(#UnknownSecurity({ isin = t.isin }));
        if (sharia and sec.couponBps > 0) return #err(#ShariaBook({ book; kind = "security" }));
        if (t.nominal == 0) return bad("the nominal is positive");
        if (t.priceMicro == 0) return bad("the price is positive");
        if (t.settlement < day) return bad("the settlement is not in the past");
        if (t.settlement >= sec.maturity) return bad("the settlement precedes the maturity");
        if (t.settlement < sec.issue) return bad("the settlement is not before the issue");
        switch (cashOk(s, t.cash, sec.currency)) { case (?r) return bad(r); case null {} };
        if (bytesOf(t.priceCurve) == 0) return bad("the price curve is named");
        if (t.direction == #sell) {
          var held = 0;
          for (l in lotsOf(s, book, t.isin).vals()) held += l.nominalLeft;
          if (held < t.nominal) return #err(#InsufficientPosition({ isin = t.isin; book; held; wanted = t.nominal }));
        };
        #ok(M.cleanCost(t.nominal, t.priceMicro))
      };
      case (#irs(i)) {
        if (sharia) return #err(#ShariaBook({ book; kind = "irs" }));
        if (not ccyOk(i.currency)) return bad("the currency is a three-letter code");
        if (i.notional == 0) return bad("the notional is positive");
        if (i.fixedBps > 1_000_000) return bad("the fixed rate exceeds 10000 %");
        if (i.start < day) return bad("the start is not in the past");
        if (bytesOf(i.floatingIndex) == 0 or bytesOf(i.floatingIndex) > 32) return bad("the floating index is named in 1..32 bytes");
        let ps = swapPeriodsOf(i);
        if (ps.size() == 0) return bad("the maturity is on the payment grid from the start");
        if (ps.size() > MAX_SWAP_PERIODS) return bad("at most " # Nat.toText(MAX_SWAP_PERIODS) # " payment periods");
        switch (cashOk(s, i.cash, i.currency)) { case (?r) return bad(r); case null {} };
        if (bytesOf(i.discountCurve) == 0) return bad("the discount curve is named");
        #ok(0)
      };
      case (#fxOption(o)) {
        if (not Text.equal(o.quote, ctx.functional)) return bad("the quote currency of an option is the functional currency");
        if (Text.equal(o.base, o.quote) or not ccyOk(o.base)) return bad("the base is a foreign currency");
        if (o.baseAmount == 0 or o.strikeMicro == 0 or o.premium == 0) return bad("amount, strike and premium are positive");
        if (o.start < day) return bad("the premium date is not in the past");
        if (o.expiry <= o.start) return bad("the expiry follows the premium date");
        switch (cashOk(s, o.cash, o.quote)) { case (?r) return bad(r); case null {} };
        if (bytesOf(o.domesticCurve) == 0 or bytesOf(o.foreignCurve) == 0 or bytesOf(o.volCurve) == 0) return bad("the three curves are named");
        #ok(o.premium)
      };
    }
  };

  /// How many legs a kind settles, and the day each falls due.
  public func legCount(kind : TT.DealKind) : Nat {
    switch (kind) { case (#moneyMarket(_)) 2; case (#fxForward(_)) 1; case (#fxSwap(_)) 2; case (#security(t)) (if (t.direction == #buy) 2 else 1); case (#irs(i)) swapPeriodsOf(i).size(); case (#fxOption(_)) 2 }
  };
  public func legDue(kind : TT.DealKind, leg : Nat, securityMaturity : Nat) : ?Nat {
    switch (kind) {
      case (#moneyMarket(m)) { if (leg == 0) ?m.start else if (leg == 1) ?m.maturity else null };
      case (#fxForward(f)) { if (leg == 0) ?f.valueDate else null };
      case (#fxSwap(x)) { if (leg == 0) ?x.near.valueDate else if (leg == 1) ?x.far.valueDate else null };
      case (#security(t)) { if (leg == 0) ?t.settlement else if (leg == 1 and t.direction == #buy) ?securityMaturity else null };
      case (#irs(i)) { let ps = swapPeriodsOf(i); if (leg < ps.size()) ?ps[leg].end else null };
      case (#fxOption(o)) { if (leg == 0) ?o.start else if (leg == 1) ?o.expiry else null };
    }
  };
  /// The figures a row keeps for a kind: currency, notional, second currency, start, maturity, rate, flags, isin.
  func rowFacts(kind : TT.DealKind, secMaturity : Nat) : { currency : Text; notional : Nat; second : Text; start : Nat; maturity : Nat; rate : Nat; flags : Nat8; isin : Text } {
    switch (kind) {
      case (#moneyMarket(m)) { { currency = m.currency; notional = m.principal; second = ""; start = m.start; maturity = m.maturity; rate = m.rateBps; flags = if (m.placement) F_BUY else 0; isin = "" } };
      case (#fxForward(f)) { { currency = f.base; notional = f.baseAmount; second = f.quote; start = f.valueDate; maturity = f.valueDate; rate = f.rateMicro; flags = if (f.direction == #buy) F_BUY else 0; isin = "" } };
      case (#fxSwap(x)) { { currency = x.near.base; notional = x.near.baseAmount; second = x.near.quote; start = x.near.valueDate; maturity = x.far.valueDate; rate = x.near.rateMicro; flags = if (x.near.direction == #buy) F_BUY else 0; isin = "" } };
      case (#security(t)) {
        let cls : Nat8 = switch (t.classification) { case (#fvoci) F_FVOCI; case (#fvtpl) F_FVTPL; case (#amortisedCost) 0 };
        { currency = ""; notional = t.nominal; second = ""; start = t.settlement; maturity = secMaturity; rate = t.priceMicro; flags = cls | (if (t.direction == #buy) F_BUY else 0); isin = t.isin }
      };
      case (#irs(i)) { { currency = i.currency; notional = i.notional; second = ""; start = i.start; maturity = i.maturity; rate = i.fixedBps; flags = if (i.payFixed) F_BUY else 0; isin = "" } };
      case (#fxOption(o)) { { currency = o.base; notional = o.baseAmount; second = o.quote; start = o.start; maturity = o.expiry; rate = o.strikeMicro; flags = (if (o.bought) F_BUY else 0) | (if (o.call) F_CALL else 0); isin = "" } };
    }
  };

  // ─── limits over the fold ──────────────────────────────────────────────────

  func signedBase(r : DealRow, kind : ?TT.DealKind) : Int {
    // the open FX exposure of a deal in its base currency: forwards and the unsettled legs of a swap, options by their amount
    switch (r.kind) {
      case 2 { if (has(r.flags, F_BUY)) r.notional else -r.notional };
      case 3 {
        switch (kind) {
          case (?#fxSwap(x)) {
            var v : Int = 0;
            if (not legSettled(r, 0)) v += (if (x.near.direction == #buy) x.near.baseAmount else -x.near.baseAmount);
            if (not legSettled(r, 1)) v += (if (x.far.direction == #buy) x.far.baseAmount else -x.far.baseAmount);
            v
          };
          case (_) 0;
        }
      };
      case 6 { if (has(r.flags, F_BUY) == has(r.flags, F_CALL)) r.notional else -r.notional };
      case _ 0;
    }
  };
  func dv01Of(r : DealRow, day : Nat) : Nat {
    if (r.kind != 1 and r.kind != 4 and r.kind != 5) return 0;
    let remaining = if (r.maturity > day) r.maturity - day else 0;
    let n = if (r.kind == 4) r.nominalLeft else r.notional;
    M.roundNat(M.q(n * remaining, 365 * M.BPS))
  };
  /// Measure every limit of the book that the new deal touches, with the new deal counted; the breaches.
  public func measureLimits(s : State, book : Text, cp : TT.Counterparty, kind : TT.DealKind, day : Nat, terms : Nat -> ?TT.DealKind) : [(TT.Limit, Nat)] {
    let open = openInBook(s, book);
    let limits = limitsOf(s, book);
    if (limits.size() == 0) return [];
    let secRow = switch (kind) { case (#security(t)) security(s, t.isin); case (_) null };
    let facts = rowFacts(kind, switch (secRow) { case (?x) x.maturity; case null 0 });
    let dealCcy = switch (kind) { case (#security(_)) { switch (secRow) { case (?x) x.currency; case null "" } }; case (_) facts.currency };
    let issuer = switch (secRow) { case (?x) x.issuer; case null "" };
    let cpHash = hash8(cp.name);
    let out = List.empty<(TT.Limit, Nat)>();
    let (lo, hi) = textPrefixRange(book, 32, 17);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.limits, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) {
        let a = Blob.toArray(k);
        let lk = limitKindOf(a[32]); let lccy = R.getText(a, 33, 8); let subjectHash = R.getNat(a, 41, 8); let value = R.getNat(Blob.toArray(v), 0, 8);
        if (Text.equal(lccy, dealCcy)) {
          var measured : Nat = 0; var applies = false; var subjectText = "";
          switch (lk) {
            case (#counterpartyExposure) {
              if (subjectHash == cpHash) {
                applies := true; subjectText := cp.name;
                measured := facts.notional;
                for (r in open.vals()) { if (r.cpHash == cpHash and rowCurrency(s, r) == dealCcy) measured += (if (r.kind == 4) r.nominalLeft else r.notional) };
              };
            };
            case (#openFxPosition) {
              switch (kind) {
                case (#fxForward(_) or #fxSwap(_) or #fxOption(_)) {
                  applies := true;
                  var pos : Int = signedBase(newRowFor(kind, facts), ?kind);
                  for (r in open.vals()) { if (Text.equal(r.currency, dealCcy)) pos += signedBase(r, terms(r.termsBlock)) };
                  measured := Int.abs(pos);
                };
                case (_) {};
              };
            };
            case (#tenorBucket) {
              switch (kind) {
                case (#moneyMarket(_) or #security(_) or #irs(_)) {
                  // the bucket's bounds are in the limit's block; the key holds their hash, so the bounds are read from the subject
                  // recorded at `limitSet` time through `bucketOf`
                  switch (bucketOf(s, book, subjectHash)) {
                    case (?(lo_, hi_)) {
                      let rem = if (facts.maturity > day) facts.maturity - day else 0;
                      if (rem >= lo_ and rem <= hi_) {
                        applies := true; subjectText := Nat.toText(lo_) # "-" # Nat.toText(hi_);
                        measured := facts.notional;
                        for (r in open.vals()) {
                          if ((r.kind == 1 or r.kind == 4 or r.kind == 5) and rowCurrency(s, r) == dealCcy) {
                            let rr = if (r.maturity > day) r.maturity - day else 0;
                            if (rr >= lo_ and rr <= hi_) measured += (if (r.kind == 4) r.nominalLeft else r.notional);
                          };
                        };
                      };
                    };
                    case null {};
                  };
                };
                case (_) {};
              };
            };
            case (#dv01) {
              switch (kind) {
                case (#moneyMarket(_) or #security(_) or #irs(_)) {
                  applies := true;
                  measured := dv01Of(newRowFor(kind, facts), day);
                  for (r in open.vals()) { if (rowCurrency(s, r) == dealCcy) measured += dv01Of(r, day) };
                };
                case (_) {};
              };
            };
            case (#stopLoss) {
              applies := true;
              var pnl : Int = 0;
              for (r in open.vals()) { if (rowCurrency(s, r) == dealCcy) pnl += r.realised + r.markPosted + r.fvPosted };
              for (r in dealsOfBook(s, book).vals()) { if (not isOpen(r) and rowCurrency(s, r) == dealCcy) pnl += r.realised };
              measured := if (pnl < 0) Int.abs(pnl) else 0;
            };
            case (#issuerConcentration) {
              if (secRow != null and subjectHash == hash8(issuer)) {
                applies := true; subjectText := issuer;
                measured := facts.notional;
                for (r in open.vals()) { if (r.kind == 4 and has(r.flags, F_BUY)) { switch (security(s, r.isin)) { case (?x) { if (x.issuerHash == subjectHash) measured += r.nominalLeft }; case null {} } } };
              };
            };
          };
          if (applies and measured > value) List.add(out, ({ book; kind = lk; currency = lccy; subject = subjectText; value }, measured));
        };
      };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  func rowCurrency(s : State, r : DealRow) : Text { if (r.kind == 4) { switch (security(s, r.isin)) { case (?x) x.currency; case null "" } } else r.currency };
  func newRowFor(kind : TT.DealKind, f : { currency : Text; notional : Nat; second : Text; start : Nat; maturity : Nat; rate : Nat; flags : Nat8; isin : Text }) : DealRow {
    { id = 0; kind = switch (kind) { case (#moneyMarket(_)) 1; case (#fxForward(_)) 2; case (#fxSwap(_)) 3; case (#security(_)) 4; case (#irs(_)) 5; case (#fxOption(_)) 6 }; state = #captured; flags = f.flags; book = ""; cpHash = 0;
      currency = f.currency; notional = f.notional; secondCurrency = f.second; secondAmount = 0; day = 0; start = f.start; maturity = f.maturity; rate = f.rate;
      accruedPosted = 0; amortisedPosted = 0; fvPosted = 0; markPosted = 0; realised = 0; nominalLeft = f.notional; costLeft = 0; yieldMillionths = 0; settledMask = 0; legs = 0; lastBlock = 0; termsBlock = 0; isin = f.isin; refHash = 0 }
  };
  /// The bounds of a tenor-bucket limit, kept beside the limit so the key's hash can be read back.
  public func bucketOf(s : State, book : Text, subjectHash : Nat) : ?(Nat, Nat) {
    switch (RI.get(s.buckets, bucketKey(book, subjectHash))) { case (?v) { let a = Blob.toArray(v); ?(R.getNat(a, 0, 4), R.getNat(a, 4, 4)) }; case null null }
  };
  func bucketKey(book : Text, subjectHash : Nat) : Blob { let b = R.buf(); R.putText(b, book, 32); R.putNat(b, subjectHash, 8); R.done(b, 40) };

  // ─── deal planners ─────────────────────────────────────────────────────────

  /// Capture: the terms validated, the second amount computed, the limits measured over the fold. A breach with no
  /// approver is a refusal; with one, the deal is recorded outside its limits and each breach is recorded after it.
  public func planCapture(s : State, dealId : Nat, book : Text, cp : TT.Counterparty, kind : TT.DealKind, reference : Text, trader : Principal, day : Nat, approver : ?Principal, ctx : Ctx, terms : Nat -> ?TT.DealKind) : Res<{ ev : TT.TreasuryEvent; extras : [TT.TreasuryEvent] }> {
    if (s.policy == null) return #err(#NoPolicy);
    if (bytesOf(book) == 0 or bytesOf(book) > 32) return bad("a book is named in 1..32 bytes");
    if (bytesOf(cp.name) == 0 or bytesOf(cp.name) > 64) return bad("the counterparty is named in 1..64 bytes");
    if (bytesOf(reference) > 64) return bad("the reference is at most 64 bytes");
    let second = switch (validateKind(s, kind, book, day, ctx)) { case (#err(e)) return #err(e); case (#ok(x)) x };
    let breaches = measureLimits(s, book, cp, kind, day, terms);
    let within = breaches.size() == 0;
    let extras = switch (approver) {
      case null { if (not within) { let (l, m) = breaches[0]; return #err(#LimitBreached({ kind = TT.limitKindText(l.kind); subject = l.subject; limit = l.value; measured = m })) }; [] };
      case (?a) Array.map<(TT.Limit, Nat), TT.TreasuryEvent>(breaches, func((l, m)) { #limitBreached({ limit = l; measured = m; deal = dealId; approver = a; day }) });
    };
    #ok({ ev = #dealCaptured({ book; counterparty = cp; kind; reference; trader; day; withinLimits = within; approver; secondAmount = second }); extras })
  };
  public func rowOpen(s : State, id : TT.DealId) : Res<DealRow> {
    switch (row(s, id)) { case null #err(#UnknownDeal({ deal = id })); case (?r) { if (isOpen(r)) #ok(r) else #err(#DealNotIn({ deal = id; state = TT.dealStateText(r.state); wanted = "captured|confirmed" })) } }
  };
  /// The counterparty's confirmation against the deal: a match confirms, a difference is recorded as such and the
  /// deal stays unconfirmed — never a match with a caveat.
  public func planConfirm(s : State, id : TT.DealId, confirmation : Blob, f : TT.ConfirmationFields, cp : TT.Counterparty, kind : TT.DealKind, day : Nat) : Res<TT.TreasuryEvent> {
    let r = switch (rowOpen(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    if (has(r.flags, F_CONFIRMED)) return #err(#DealNotIn({ deal = id; state = "confirmed"; wanted = "captured" }));
    if (confirmation.size() != 32) return bad("the confirmation is recorded by its sha256");
    func mismatch(field : Text, ours : Text, theirs : Text) : TT.TreasuryEvent { #confirmationMismatch({ deal = id; confirmation; field; ours; theirs; day }) };
    let ccy = rowCurrency(s, r);
    if (not Text.equal(f.kind, kindTextOf(r.kind))) return #ok(mismatch("kind", kindTextOf(r.kind), f.kind));
    // the counterparty identifies itself by name or by BIC
    if (not Text.equal(f.counterparty, cp.name) and not Text.equal(f.counterparty, cp.bic)) return #ok(mismatch("counterparty", cp.name, f.counterparty));
    if (not Text.equal(f.currency1, ccy)) return #ok(mismatch("currency1", ccy, f.currency1));
    if (not Text.equal(f.currency2, r.secondCurrency)) return #ok(mismatch("currency2", r.secondCurrency, f.currency2));
    // a swap's confirmation names one of its legs; every other kind has one set of figures
    let legs : [(Nat, Nat, Nat, Nat)] = switch (kind) {
      case (#fxSwap(x)) [(x.near.baseAmount, M.quoteAmount(x.near.baseAmount, x.near.rateMicro), x.near.valueDate, x.near.rateMicro), (x.far.baseAmount, M.quoteAmount(x.far.baseAmount, x.far.rateMicro), x.far.valueDate, x.far.rateMicro)];
      case (_) [(r.notional, r.secondAmount, r.maturity, r.rate)];
    };
    for ((a1, a2, vd, rate) in legs.vals()) { if (f.amount1 == a1 and f.amount2 == a2 and f.valueDate == vd and f.rateMicro == rate) return #ok(#dealConfirmed({ deal = id; confirmation; day })) };
    // the first difference against the leg whose value date the confirmation names, else the first leg
    let (a1, a2, vd, rate) = switch (Array.find<(Nat, Nat, Nat, Nat)>(legs, func((_, _, v, _)) { v == f.valueDate })) { case (?l) l; case null legs[0] };
    if (f.amount1 != a1) return #ok(mismatch("amount1", Nat.toText(a1), Nat.toText(f.amount1)));
    if (f.amount2 != a2) return #ok(mismatch("amount2", Nat.toText(a2), Nat.toText(f.amount2)));
    if (f.valueDate != vd) return #ok(mismatch("valueDate", Nat.toText(vd), Nat.toText(f.valueDate)));
    #ok(mismatch("rate", Nat.toText(rate), Nat.toText(f.rateMicro)))
  };
  public func planAmend(s : State, id : TT.DealId, kind : TT.DealKind, reason : Text, day : Nat, ctx : Ctx) : Res<TT.TreasuryEvent> {
    let r = switch (rowOpen(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    if (r.settledMask != 0) return #err(#DealNotIn({ deal = id; state = "settling"; wanted = "unsettled" }));
    if (kindCode(kind) != r.kind) return bad("an amendment keeps the deal's kind");
    if (bytesOf(reason) == 0 or bytesOf(reason) > 128) return bad("an amendment states its reason in 1..128 bytes");
    let second = switch (validateKind(s, kind, r.book, day, ctx)) { case (#err(e)) return #err(e); case (#ok(x)) x };
    #ok(#dealAmended({ deal = id; kind; reason; day; secondAmount = second }))
  };
  public func planCancel(s : State, id : TT.DealId, reason : Text, day : Nat) : Res<TT.TreasuryEvent> {
    let r = switch (rowOpen(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    if (r.settledMask != 0) return #err(#DealNotIn({ deal = id; state = "settling"; wanted = "unsettled" }));
    if (bytesOf(reason) == 0 or bytesOf(reason) > 128) return bad("a cancellation states its reason in 1..128 bytes");
    #ok(#dealCancelled({ deal = id; reason; day }))
  };

  // ─── legs ─────────────────────────────────────────────────────────────────

  type Legs = List.List<JT.Leg>;
  func addLeg(ls : Legs, account : Text, sub : ?JT.SubledgerKey, side : JT.Side, ccy : Text, amount : Nat) { if (amount > 0) List.add(ls, Posting.leg(account, sub, side, ccy, amount)) };
  /// A signed movement on a debit-normal carrying account against a gain and a loss account: up is a debit to the
  /// account and a credit to the gain; down is a debit to the loss and a credit to the account.
  func moveSigned(ls : Legs, account : Text, sub : ?JT.SubledgerKey, ccy : Text, delta : Int, gain : Text, loss : Text) {
    if (delta > 0) { addLeg(ls, account, sub, #debit, ccy, Int.abs(delta)); addLeg(ls, gain, null, #credit, ccy, Int.abs(delta)) }
    else if (delta < 0) { addLeg(ls, loss, null, #debit, ccy, Int.abs(delta)); addLeg(ls, account, sub, #credit, ccy, Int.abs(delta)) };
  };
  /// A realised result in a currency: positive to the gain account, negative to the loss account, against `against`.
  func realisedLegs(ls : Legs, p : TT.Policy, against : Text, againstSub : ?JT.SubledgerKey, ccy : Text, result : Int) {
    if (result > 0) { addLeg(ls, against, againstSub, #debit, ccy, Int.abs(result)); addLeg(ls, p.realisedTradingGain, null, #credit, ccy, Int.abs(result)) }
    else if (result < 0) { addLeg(ls, p.realisedTradingLoss, null, #debit, ccy, Int.abs(result)); addLeg(ls, against, againstSub, #credit, ccy, Int.abs(result)) };
  };
  func securitiesAccount(p : TT.Policy, flags : Nat8) : Text { switch (classOf(flags)) { case (#amortisedCost) p.securitiesAmortisedCost; case (#fvoci) p.securitiesFvoci; case (#fvtpl) p.securitiesFvtpl } };
  /// A fair-value adjustment's contra: the OCI reserve for FVOCI, the unrealised result for FVTPL.
  func fvLegs(ls : Legs, p : TT.Policy, flags : Nat8, sub : ?JT.SubledgerKey, ccy : Text, delta : Int) {
    let acc = securitiesAccount(p, flags);
    switch (classOf(flags)) {
      case (#fvoci) moveSigned(ls, acc, sub, ccy, delta, p.fvociReserve, p.fvociReserve);
      case (_) moveSigned(ls, acc, sub, ccy, delta, p.unrealisedTradingGain, p.unrealisedTradingLoss);
    }
  };
  func mmAccrualLegs(ls : Legs, p : TT.Policy, placement : Bool, sub : ?JT.SubledgerKey, ccy : Text, delta : Int) {
    if (placement) moveSigned(ls, p.mmInterestReceivable, sub, ccy, delta, p.mmInterestIncome, p.mmInterestIncome)
    else {
      // a liability's accrual: up is a debit to expense and a credit to the payable
      if (delta > 0) { addLeg(ls, p.mmInterestExpense, null, #debit, ccy, Int.abs(delta)); addLeg(ls, p.mmInterestPayable, sub, #credit, ccy, Int.abs(delta)) }
      else if (delta < 0) { addLeg(ls, p.mmInterestPayable, sub, #debit, ccy, Int.abs(delta)); addLeg(ls, p.mmInterestExpense, null, #credit, ccy, Int.abs(delta)) };
    }
  };
  func amortisationLegs(ls : Legs, p : TT.Policy, flags : Nat8, sub : ?JT.SubledgerKey, ccy : Text, delta : Int) {
    let acc = securitiesAccount(p, flags);
    if (delta > 0) { addLeg(ls, acc, sub, #debit, ccy, Int.abs(delta)); addLeg(ls, p.amortisationIncome, null, #credit, ccy, Int.abs(delta)) }
    else if (delta < 0) { addLeg(ls, p.amortisationExpense, null, #debit, ccy, Int.abs(delta)); addLeg(ls, acc, sub, #credit, ccy, Int.abs(delta)) };
  };
  func policyOf(s : State) : Res<TT.Policy> { switch (s.policy) { case (?p) #ok(p); case null #err(#NoPolicy) } };
  func spotOf(ctx : Ctx, ccy : Text, day : Nat) : Res<Fx.Rate> { switch (ctx.spot(ccy, day)) { case (?r) #ok(r); case null #err(#NoRate({ currency = ccy; day })) } };
  func curveOf(s : State, id : Text, day : Nat, kind : TT.CurveKind) : Res<[(Nat, Int)]> {
    switch (curveOn(s, id, day)) { case (?c) { if (c.kind != kind) return #err(#UnknownCurve({ curve = id; day })); #ok(c.points) }; case null #err(#UnknownCurve({ curve = id; day })) }
  };
  func spotQ(r : Fx.Rate) : M.Q { M.rateMicro(r.numerator, r.denominator) };

  /// The spot exchange of a forward at the day's rate through the currency's position pair, the contractual quote
  /// amount leaving or arriving, the difference realised, and the deal's mark reversed.
  func forwardSettleLegs(ls : Legs, p : TT.Policy, ctx : Ctx, f : TT.FxForward, quoteAmount : Nat, sub : ?JT.SubledgerKey, mark : Int, day : Nat) : Res<Int> {
    let rate = switch (spotOf(ctx, f.base, day)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    let ?pair = ctx.pair(f.base) else return #err(#UnsupportedKind({ kind = "fxForward"; reason = "no position pair is declared for " # f.base }));
    let e = M.roundNat(M.ofSigned(Fx.equivalentOf(f.baseAmount, rate)));
    let buy = f.direction == #buy;
    let deal : Fx.Deal = if (buy) {
      { sell = f.quote; sellAmount = e; sellAccount = f.quoteAccount.account; sellSubledger = cashSub(f.quoteAccount); buy = f.base; buyAmount = f.baseAmount; buyAccount = f.baseAccount.account; buySubledger = cashSub(f.baseAccount) }
    } else {
      { sell = f.base; sellAmount = f.baseAmount; sellAccount = f.baseAccount.account; sellSubledger = cashSub(f.baseAccount); buy = f.quote; buyAmount = e; buyAccount = f.quoteAccount.account; buySubledger = cashSub(f.quoteAccount) }
    };
    switch (Fx.dealLegs(pair, ctx.functional, deal)) {
      case (#err(_)) return #err(#UnsupportedKind({ kind = "fxForward"; reason = "the pair does not carry " # f.base # " against " # ctx.functional }));
      case (#ok(legs)) { for (l in legs.vals()) List.add(ls, l) };
    };
    // the equivalent at spot less the contractual amount: what the forward was worth when it settled
    let result : Int = if (buy) (e : Int) - quoteAmount else (quoteAmount : Int) - e;
    realisedLegs(ls, p, f.quoteAccount.account, cashSub(f.quoteAccount), f.quote, result);
    moveSigned(ls, p.fxForwardMark, sub, f.quote, -mark, p.unrealisedTradingGain, p.unrealisedTradingLoss);
    #ok(result)
  };

  /// One lot's share of a sale: pro rata to what is booked, the whole when the lot is exhausted.
  type Consumed = { lot : DealRow; nominal : Nat; cost : Nat; amortisation : Int; fv : Int; accrual : Int };
  func consumeLot(l : DealRow, q : Nat) : Consumed {
    if (q >= l.nominalLeft) return { lot = l; nominal = l.nominalLeft; cost = l.costLeft; amortisation = l.amortisedPosted; fv = l.fvPosted; accrual = l.accruedPosted };
    func part(x : Int) : Int { M.roundHalfEven(M.q(x * q, l.nominalLeft)) };
    { lot = l; nominal = q; cost = Int.abs(part(l.costLeft)); amortisation = part(l.amortisedPosted); fv = part(l.fvPosted); accrual = part(l.accruedPosted) }
  };
  /// Which lots a sale takes from, and how much of each: first-in-first-out, or pro rata by nominal left with the
  /// rounding remainder placed one unit at a time on the earliest lots.
  public func allocateSale(lots : [DealRow], nominal : Nat, method : TT.LotMethod) : [(DealRow, Nat)] {
    switch (method) {
      case (#fifo) {
        var left = nominal;
        let out = List.empty<(DealRow, Nat)>();
        for (l in lots.vals()) { if (left > 0) { let q = Nat.min(left, l.nominalLeft); List.add(out, (l, q)); left -= q } };
        List.toArray(out)
      };
      case (#averageCost) {
        var total = 0;
        for (l in lots.vals()) total += l.nominalLeft;
        if (total == 0) return [];
        let qs = Array.tabulate<Nat>(lots.size(), func(i) { nominal * lots[i].nominalLeft / total });
        var given = 0;
        for (q in qs.vals()) given += q;
        var rem = nominal - given;
        let out = List.empty<(DealRow, Nat)>();
        var i = 0;
        while (i < lots.size()) {
          var q = qs[i];
          if (rem > 0 and q < lots[i].nominalLeft) { q += 1; rem -= 1 };
          if (q > 0) List.add(out, (lots[i], q));
          i += 1;
        };
        List.toArray(out)
      };
    }
  };

  /// Settle one leg of a deal on `day`: the legs to post, the event and the lot events. Legs settle in order, each
  /// on or after its due day.
  public func planSettleLeg(s : State, r : DealRow, kind : TT.DealKind, leg : Nat, day : Nat, ctx : Ctx) : Res<Act> {
    let p = switch (policyOf(s)) { case (#err(e)) return #err(e); case (#ok(p)) p };
    if (not isOpen(r)) return #err(#DealNotIn({ deal = r.id; state = TT.dealStateText(r.state); wanted = "captured|confirmed" }));
    if (leg >= r.legs) return #err(#NoSuchLeg({ deal = r.id; leg }));
    if (legSettled(r, leg)) return #err(#LegSettled({ deal = r.id; leg }));
    if (leg > 0 and not legSettled(r, leg - 1)) return #err(#DealNotIn({ deal = r.id; state = "leg " # Nat.toText(leg - 1) # " unsettled"; wanted = "legs in order" }));
    let secRow = if (r.kind == 4) security(s, r.isin) else null;
    let ?due = legDue(kind, leg, switch (secRow) { case (?x) x.maturity; case null 0 }) else return #err(#NoSuchLeg({ deal = r.id; leg }));
    if (day < due) return #err(#LegNotDue({ deal = r.id; leg; due; day }));
    let sub = ?dealSub(r.id);
    let ls = List.empty<JT.Leg>();
    func settled(amount : Nat, currency : Text, realised : Int, accrual : Int, amortisation : Int, fv : Int, nominal : Nat, cost : Nat) : TT.TreasuryEvent {
      #legSettled({ deal = r.id; leg; amount; currency; realised; day; accrual; amortisation; fv; nominal; cost })
    };
    switch (kind) {
      case (#moneyMarket(m)) {
        let cs = cashSub(m.cash);
        if (leg == 0) {
          if (m.placement) { addLeg(ls, p.mmPlacements, sub, #debit, m.currency, m.principal); addLeg(ls, m.cash.account, cs, #credit, m.currency, m.principal) }
          else { addLeg(ls, m.cash.account, cs, #debit, m.currency, m.principal); addLeg(ls, p.mmTakings, sub, #credit, m.currency, m.principal) };
          #ok({ ev = settled(m.principal, m.currency, 0, 0, 0, 0, 0, 0); legs = List.toArray(ls); extras = [] })
        } else {
          let interest = M.simpleInterestTo(m.principal, m.rateBps, m.dayCount, m.start, m.maturity);
          let catchUp : Int = (interest : Int) - r.accruedPosted;
          mmAccrualLegs(ls, p, m.placement, sub, m.currency, catchUp);
          if (m.placement) {
            addLeg(ls, m.cash.account, cs, #debit, m.currency, m.principal + interest);
            addLeg(ls, p.mmPlacements, sub, #credit, m.currency, m.principal); addLeg(ls, p.mmInterestReceivable, sub, #credit, m.currency, interest);
          } else {
            addLeg(ls, p.mmTakings, sub, #debit, m.currency, m.principal); addLeg(ls, p.mmInterestPayable, sub, #debit, m.currency, interest);
            addLeg(ls, m.cash.account, cs, #credit, m.currency, m.principal + interest);
          };
          #ok({ ev = settled(m.principal + interest, m.currency, 0, catchUp, 0, 0, 0, 0); legs = List.toArray(ls); extras = [] })
        }
      };
      case (#fxForward(f)) {
        let result = switch (forwardSettleLegs(ls, p, ctx, f, r.secondAmount, sub, r.markPosted, day)) { case (#err(e)) return #err(e); case (#ok(x)) x };
        #ok({ ev = settled(f.baseAmount, f.base, result, 0, 0, -r.markPosted, 0, 0); legs = List.toArray(ls); extras = [] })
      };
      case (#fxSwap(x)) {
        let f = if (leg == 0) x.near else x.far;
        let q = if (leg == 0) r.secondAmount else M.quoteAmount(x.far.baseAmount, x.far.rateMicro);
        let result = switch (forwardSettleLegs(ls, p, ctx, f, q, sub, r.markPosted, day)) { case (#err(e)) return #err(e); case (#ok(x_)) x_ };
        #ok({ ev = settled(f.baseAmount, f.base, result, 0, 0, -r.markPosted, 0, 0); legs = List.toArray(ls); extras = [] })
      };
      case (#security(t)) {
        let ?sec = secRow else return #err(#UnknownSecurity({ isin = t.isin }));
        let conv = conventionOf(sec);
        let cs = cashSub(t.cash);
        if (t.direction == #buy) {
          if (leg == 0) {
            let periods = couponPeriodsOf(sec, t.nominal);
            let accrued = M.accruedCoupon(t.nominal, sec.couponBps, conv, periods, t.settlement);
            addLeg(ls, securitiesAccount(p, r.flags), sub, #debit, sec.currency, r.secondAmount);
            addLeg(ls, p.couponReceivable, sub, #debit, sec.currency, accrued);
            addLeg(ls, t.cash.account, cs, #credit, sec.currency, r.secondAmount + accrued);
            #ok({ ev = settled(r.secondAmount + accrued, sec.currency, 0, accrued, 0, 0, 0, 0); legs = List.toArray(ls); extras = [] })
          } else {
            // redemption at face; the last coupon was paid first (the end of day pays it before it redeems)
            if (r.accruedPosted != 0) return #err(#Busy({ reason = "the final coupon is paid before the redemption" }));
            let face = r.nominalLeft;
            let book : Int = (r.costLeft : Int) + r.amortisedPosted;
            let result : Int = (face : Int) - book;
            #ok({ ev = settled(face, sec.currency, result, 0, -r.amortisedPosted, -r.fvPosted, face, r.costLeft); legs = redemptionLegs(p, r, t, sec, face, book); extras = [] })
          }
        } else {
          // a sale: the lots consumed, the clean proceeds against their booked cost, the accrued coupon the buyer pays
          let lots = lotsOf(s, r.book, t.isin);
          let parts = allocateSale(lots, t.nominal, p.lotMethod);
          var taken = 0;
          for ((_, q) in parts.vals()) taken += q;
          if (taken < t.nominal) return #err(#InsufficientPosition({ isin = t.isin; book = r.book; held = taken; wanted = t.nominal }));
          let periods = couponPeriodsOf(sec, t.nominal);
          let accruedBuyer = M.accruedCoupon(t.nominal, sec.couponBps, conv, periods, day);
          var consumedBook : Int = 0; var accrualOut : Int = 0;
          let extras = List.empty<TT.TreasuryEvent>();
          for ((l, q) in parts.vals()) {
            let c = consumeLot(l, q);
            let lsub = ?dealSub(l.id);
            let bookPart : Int = (c.cost : Int) + c.amortisation;
            if (bookPart > 0) addLeg(ls, securitiesAccount(p, l.flags), lsub, #credit, sec.currency, Int.abs(bookPart))
            else if (bookPart < 0) addLeg(ls, securitiesAccount(p, l.flags), lsub, #debit, sec.currency, Int.abs(bookPart));
            fvLegs(ls, p, l.flags, lsub, sec.currency, -c.fv);
            if (c.accrual > 0) addLeg(ls, p.couponReceivable, lsub, #credit, sec.currency, Int.abs(c.accrual))
            else if (c.accrual < 0) addLeg(ls, p.couponReceivable, lsub, #debit, sec.currency, Int.abs(c.accrual));
            consumedBook += bookPart; accrualOut += c.accrual;
            List.add(extras, #lotConsumed({ lot = l.id; by = r.id; nominal = c.nominal; cost = c.cost; amortisation = -c.amortisation; fv = -c.fv; accrual = -c.accrual; day }));
          };
          addLeg(ls, t.cash.account, cs, #debit, sec.currency, r.secondAmount + accruedBuyer);
          let incomeDiff : Int = (accruedBuyer : Int) - accrualOut;
          if (incomeDiff > 0) addLeg(ls, p.couponIncome, null, #credit, sec.currency, Int.abs(incomeDiff))
          else if (incomeDiff < 0) addLeg(ls, p.couponIncome, null, #debit, sec.currency, Int.abs(incomeDiff));
          let result : Int = (r.secondAmount : Int) - consumedBook;
          if (result > 0) addLeg(ls, p.realisedTradingGain, null, #credit, sec.currency, Int.abs(result))
          else if (result < 0) addLeg(ls, p.realisedTradingLoss, null, #debit, sec.currency, Int.abs(result));
          #ok({ ev = settled(r.secondAmount + accruedBuyer, sec.currency, result, 0, 0, 0, 0, 0); legs = List.toArray(ls); extras = List.toArray(extras) })
        }
      };
      case (#irs(i)) {
        let ps = swapPeriodsOf(i);
        let period = ps[leg];
        let ?fixing = ctx.fixing(i.floatingIndex, period.start) else return #err(#NoFixing({ index = i.floatingIndex; day = period.start }));
        let fixed = M.legAmount(i.notional, M.ofNat(i.fixedBps), i.dayCount, period);
        let floating = M.legAmount(i.notional, M.ofInt((fixing : Int) + i.spreadBps), i.dayCount, period);
        let net : Int = if (i.payFixed) floating - fixed else fixed - floating;
        let cs = cashSub(i.cash);
        if (net > 0) { addLeg(ls, i.cash.account, cs, #debit, i.currency, Int.abs(net)); addLeg(ls, p.realisedTradingGain, null, #credit, i.currency, Int.abs(net)) }
        else if (net < 0) { addLeg(ls, p.realisedTradingLoss, null, #debit, i.currency, Int.abs(net)); addLeg(ls, i.cash.account, cs, #credit, i.currency, Int.abs(net)) };
        moveSigned(ls, p.irsMark, sub, i.currency, -r.markPosted, p.unrealisedTradingGain, p.unrealisedTradingLoss);
        #ok({ ev = settled(Int.abs(net), i.currency, net, 0, 0, -r.markPosted, 0, 0); legs = List.toArray(ls); extras = [] })
      };
      case (#fxOption(o)) {
        let cs = cashSub(o.cash);
        if (leg == 0) {
          if (o.bought) { addLeg(ls, p.fxOptionValue, sub, #debit, o.quote, o.premium); addLeg(ls, o.cash.account, cs, #credit, o.quote, o.premium) }
          else { addLeg(ls, o.cash.account, cs, #debit, o.quote, o.premium); addLeg(ls, p.fxOptionValue, sub, #credit, o.quote, o.premium) };
          #ok({ ev = settled(o.premium, o.quote, 0, 0, 0, if (o.bought) o.premium else -(o.premium : Int), 0, 0); legs = List.toArray(ls); extras = [] })
        } else {
          let rate = switch (spotOf(ctx, o.base, o.expiry)) { case (#err(e)) return #err(e); case (#ok(x)) x };
          let spot = M.roundHalfEven(spotQ(rate));
          let payoff = M.garmanKohlhagen(o.call, o.baseAmount, spot, o.strikeMicro, 0, 0, 0, 0);
          let carrying = r.markPosted;   // signed: positive when bought
          let result : Int = if (o.bought) (payoff : Int) - carrying else -(payoff : Int) - carrying;
          if (o.bought) {
            addLeg(ls, o.cash.account, cs, #debit, o.quote, payoff);
            if (carrying > 0) addLeg(ls, p.fxOptionValue, sub, #credit, o.quote, Int.abs(carrying));
            if (result > 0) addLeg(ls, p.realisedTradingGain, null, #credit, o.quote, Int.abs(result)) else if (result < 0) addLeg(ls, p.realisedTradingLoss, null, #debit, o.quote, Int.abs(result));
          } else {
            if (carrying < 0) addLeg(ls, p.fxOptionValue, sub, #debit, o.quote, Int.abs(carrying));
            addLeg(ls, o.cash.account, cs, #credit, o.quote, payoff);
            if (result > 0) addLeg(ls, p.realisedTradingGain, null, #credit, o.quote, Int.abs(result)) else if (result < 0) addLeg(ls, p.realisedTradingLoss, null, #debit, o.quote, Int.abs(result));
          };
          #ok({ ev = settled(payoff, o.quote, result, 0, 0, -carrying, 0, 0); legs = List.toArray(ls); extras = [] })
        }
      };
    }
  };
  /// The redemption's legs: cash at face, the securities account relieved of its book value, the fair-value
  /// adjustment reversed to its contra, the difference realised.
  func redemptionLegs(p : TT.Policy, r : DealRow, t : TT.SecurityTrade, sec : SecurityRow, face : Nat, book : Int) : [JT.Leg] {
    let ls = List.empty<JT.Leg>();
    let sub = ?dealSub(r.id);
    addLeg(ls, t.cash.account, cashSub(t.cash), #debit, sec.currency, face);
    if (book > 0) addLeg(ls, securitiesAccount(p, r.flags), sub, #credit, sec.currency, Int.abs(book)) else if (book < 0) addLeg(ls, securitiesAccount(p, r.flags), sub, #debit, sec.currency, Int.abs(book));
    fvLegs(ls, p, r.flags, sub, sec.currency, -r.fvPosted);
    let result : Int = (face : Int) - book;
    if (result > 0) addLeg(ls, p.realisedTradingGain, null, #credit, sec.currency, Int.abs(result)) else if (result < 0) addLeg(ls, p.realisedTradingLoss, null, #debit, sec.currency, Int.abs(result));
    List.toArray(ls)
  };

  /// The day's accrual of a deal: money-market interest to the day; a lot's coupon and its amortisation. Null when
  /// nothing moves.
  public func planAccrue(s : State, r : DealRow, kind : TT.DealKind, day : Nat) : Res<?Act> {
    let p = switch (policyOf(s)) { case (#err(e)) return #err(e); case (#ok(p)) p };
    if (not isOpen(r)) return #ok(null);
    let sub = ?dealSub(r.id);
    let ls = List.empty<JT.Leg>();
    switch (kind) {
      case (#moneyMarket(m)) {
        if (not legSettled(r, 0) or legSettled(r, 1)) return #ok(null);
        let to = Nat.min(day, m.maturity);
        let target : Int = M.simpleInterestTo(m.principal, m.rateBps, m.dayCount, m.start, to);
        let delta = target - r.accruedPosted;
        if (delta == 0) return #ok(null);
        mmAccrualLegs(ls, p, m.placement, sub, m.currency, delta);
        #ok(?{ ev = #accrued({ deal = r.id; interest = delta; amortisation = 0; day }); legs = List.toArray(ls); extras = [] })
      };
      case (#security(t)) {
        if (t.direction != #buy or not legSettled(r, 0) or r.nominalLeft == 0) return #ok(null);
        let ?sec = security(s, t.isin) else return #err(#UnknownSecurity({ isin = t.isin }));
        if (day >= sec.maturity) return #ok(null);
        let conv = conventionOf(sec);
        let periods = couponPeriodsOf(sec, r.nominalLeft);
        let couponTarget : Int = M.accruedCoupon(r.nominalLeft, sec.couponBps, conv, periods, day);
        let dc = couponTarget - r.accruedPosted;
        let amortTarget : Int = M.roundHalfEven(M.q(lotAmortisationTo(r, sec, day) * r.nominalLeft, r.notional));
        let da = amortTarget - r.amortisedPosted;
        if (dc == 0 and da == 0) return #ok(null);
        moveSigned(ls, p.couponReceivable, sub, sec.currency, dc, p.couponIncome, p.couponIncome);
        amortisationLegs(ls, p, r.flags, sub, sec.currency, da);
        #ok(?{ ev = #accrued({ deal = r.id; interest = dc; amortisation = da; day }); legs = List.toArray(ls); extras = [] })
      };
      case (_) #ok(null);
    }
  };

  /// A coupon falling due on `day` for a lot: cash in, the receivable cleared, the rounding to income.
  public func planCoupon(s : State, r : DealRow, kind : TT.DealKind, day : Nat) : Res<?Act> {
    let p = switch (policyOf(s)) { case (#err(e)) return #err(e); case (#ok(p)) p };
    let #security(t) = kind else return #ok(null);
    if (not isOpen(r) or t.direction != #buy or not legSettled(r, 0) or r.nominalLeft == 0) return #ok(null);
    let ?sec = security(s, t.isin) else return #err(#UnknownSecurity({ isin = t.isin }));
    var coupon : ?Nat = null;
    for (pd in couponPeriodsOf(sec, r.nominalLeft).vals()) { if (pd.end == day and pd.start < day) coupon := ?pd.amount };
    let ?c = coupon else return #ok(null);
    if (r.day > day) return #ok(null);
    let sub = ?dealSub(r.id);
    let ls = List.empty<JT.Leg>();
    addLeg(ls, t.cash.account, cashSub(t.cash), #debit, sec.currency, c);
    if (r.accruedPosted > 0) addLeg(ls, p.couponReceivable, sub, #credit, sec.currency, Int.abs(r.accruedPosted)) else if (r.accruedPosted < 0) addLeg(ls, p.couponReceivable, sub, #debit, sec.currency, Int.abs(r.accruedPosted));
    let diff : Int = (c : Int) - r.accruedPosted;
    if (diff > 0) addLeg(ls, p.couponIncome, null, #credit, sec.currency, Int.abs(diff)) else if (diff < 0) addLeg(ls, p.couponIncome, null, #debit, sec.currency, Int.abs(diff));
    #ok(?{ ev = #couponPaid({ deal = r.id; amount = c; day }); legs = List.toArray(ls); extras = [] })
  };

  /// The day's valuation of a deal against the recorded curves and the day's spot: the movement of its mark (or a
  /// lot's fair-value adjustment). Null when the kind carries no mark or nothing moves.
  public func planMark(s : State, r : DealRow, kind : TT.DealKind, day : Nat, ctx : Ctx) : Res<?Act> {
    let p = switch (policyOf(s)) { case (#err(e)) return #err(e); case (#ok(p)) p };
    if (not isOpen(r)) return #ok(null);
    let sub = ?dealSub(r.id);
    let ls = List.empty<JT.Leg>();
    func forwardValue(f : TT.FxForward) : Res<Int> {
      if (day >= f.valueDate) return #ok(0);
      let rate = switch (spotOf(ctx, f.base, day)) { case (#err(e)) return #err(e); case (#ok(x)) x };
      let pts = switch (curveOf(s, f.pointsCurve, day, #forwardPoints)) { case (#err(e)) return #err(e); case (#ok(x)) x };
      let zero = switch (curveOf(s, f.discountCurve, day, #zeroRates)) { case (#err(e)) return #err(e); case (#ok(x)) x };
      #ok(M.forwardMark(f.direction == #buy, f.baseAmount, f.rateMicro, spotQ(rate), pts, zero, f.valueDate - day))
    };
    let (target, account, ccy) : (Int, Text, Text) = switch (kind) {
      case (#fxForward(f)) {
        if (legSettled(r, 0)) return #ok(null);
        (switch (forwardValue(f)) { case (#err(e)) return #err(e); case (#ok(v)) v }, p.fxForwardMark, f.quote)
      };
      case (#fxSwap(x)) {
        var v : Int = 0;
        if (not legSettled(r, 0)) v += (switch (forwardValue(x.near)) { case (#err(e)) return #err(e); case (#ok(m)) m });
        if (not legSettled(r, 1)) v += (switch (forwardValue(x.far)) { case (#err(e)) return #err(e); case (#ok(m)) m });
        (v, p.fxForwardMark, x.near.quote)
      };
      case (#irs(i)) {
        if (day >= i.maturity) return #ok(null);
        let zero = switch (curveOf(s, i.discountCurve, day, #zeroRates)) { case (#err(e)) return #err(e); case (#ok(x)) x };
        let ps = swapPeriodsOf(i);
        func fixingFor(start : Nat) : ?Nat { ctx.fixing(i.floatingIndex, start) };
        (M.swapMark(i.notional, i.payFixed, i.fixedBps, i.spreadBps, i.dayCount, ps, zero, day, fixingFor), p.irsMark, i.currency)
      };
      case (#fxOption(o)) {
        if (not legSettled(r, 0) or day >= o.expiry) return #ok(null);
        let rate = switch (spotOf(ctx, o.base, day)) { case (#err(e)) return #err(e); case (#ok(x)) x };
        let tenor = o.expiry - day;
        let dom = switch (curveOf(s, o.domesticCurve, day, #zeroRates)) { case (#err(e)) return #err(e); case (#ok(x)) x };
        let fgn = switch (curveOf(s, o.foreignCurve, day, #zeroRates)) { case (#err(e)) return #err(e); case (#ok(x)) x };
        let vol = switch (curveOf(s, o.volCurve, day, #volatility)) { case (#err(e)) return #err(e); case (#ok(x)) x };
        let v = M.garmanKohlhagen(o.call, o.baseAmount, M.roundHalfEven(spotQ(rate)), o.strikeMicro, M.roundHalfEven(M.interpolate(dom, tenor)), M.roundHalfEven(M.interpolate(fgn, tenor)), M.roundNat(M.interpolate(vol, tenor)), tenor);
        (if (o.bought) v else -(v : Int), p.fxOptionValue, o.quote)
      };
      case (#security(t)) {
        if (t.direction != #buy or not legSettled(r, 0) or r.nominalLeft == 0 or classOf(r.flags) == #amortisedCost) return #ok(null);
        let ?sec = security(s, t.isin) else return #err(#UnknownSecurity({ isin = t.isin }));
        if (day >= sec.maturity) return #ok(null);
        let px = switch (curveOf(s, t.priceCurve, day, #securityPrice)) { case (#err(e)) return #err(e); case (#ok(x)) x };
        let price = M.roundNat(M.interpolate(px, 0));
        let fv : Int = M.cleanCost(r.nominalLeft, price);
        let fvTarget = fv - ((r.costLeft : Int) + r.amortisedPosted);
        let delta = fvTarget - r.fvPosted;
        if (delta == 0) return #ok(null);
        fvLegs(ls, p, r.flags, sub, sec.currency, delta);
        return #ok(?{ ev = #marked({ deal = r.id; value = fvTarget; previous = r.fvPosted; day }); legs = List.toArray(ls); extras = [] });
      };
      case (#moneyMarket(_)) return #ok(null);
    };
    let delta = target - r.markPosted;
    if (delta == 0) return #ok(null);
    moveSigned(ls, account, sub, ccy, delta, p.unrealisedTradingGain, p.unrealisedTradingLoss);
    #ok(?{ ev = #marked({ deal = r.id; value = target; previous = r.markPosted; day }); legs = List.toArray(ls); extras = [] })
  };

  // ─── nostro reconciliation ─────────────────────────────────────────────────

  /// Index a committed posting's legs on registered nostro accounts: the bank's side of the reconciliation, written
  /// as the journal commits so a statement can be matched against it by a fold and never by a query.
  public func indexJournalLegs(s : State, posting : Nat, valueDay : Nat, legs : [JT.Leg], reference : Text) : Nat {
    if (s.nostroCount == 0) return 0;
    var n = 0;
    for (l in legs.vals()) {
      let h = nostroAccountHash(l.account, l.subledger, l.currency);
      switch (nostroOfAccount(s, h)) {
        case (?nr) {
          ignore RI.put(s.nostroLegs, legKey(nr.accountHash, valueDay, posting), encodeLeg({ nostroHash = nr.accountHash; valueDay; posting; amount = l.amount; debit = l.side == #debit; status = LEG_OPEN; refHash = hash8(reference); statement8 = 0 }));
          ignore RI.put(s.legByPosting, R.key2(posting, 8, nr.accountHash, 8), R.key(valueDay, 4));
          n += 1;
        };
        case null {};
      };
    };
    n
  };
  func legOf(s : State, nostroHash : Nat, posting : Nat) : ?NostroLegRow {
    switch (RI.get(s.legByPosting, R.key2(posting, 8, nostroHash, 8))) {
      case (?v) { let day = R.getNat(Blob.toArray(v), 0, 4); let k = legKey(nostroHash, day, posting); switch (RI.get(s.nostroLegs, k)) { case (?lv) ?decodeLeg(k, lv); case null null } };
      case null null;
    }
  };
  func putLeg(s : State, l : NostroLegRow) { ignore RI.put(s.nostroLegs, legKey(l.nostroHash, l.valueDay, l.posting), encodeLeg(l)) };

  /// Match a statement's entries against our unmatched postings on the nostro: by reference first, then by amount,
  /// direction and value date within the tolerance, deterministically in the order recorded; an entry with no
  /// posting is a break on the statement's side, an unmatched posting of ours inside the statement's window a break
  /// on ours. The event carries the matched postings; each break is its own event after it.
  public func planRecordStatement(s : State, nostroId : Text, statement : Blob, from : Nat, to : Nat, entries : [TT.StatementEntry], day : Nat) : Res<{ ev : TT.TreasuryEvent; breaks : [TT.TreasuryEvent] }> {
    let ?nr = nostro(s, nostroId) else return #err(#UnknownNostro({ nostro = nostroId }));
    if (statement.size() != 32) return #err(#BadDocument({ reason = "a statement is recorded by its sha256" }));
    if (statementKnown(s, statement)) return #err(#BadDocument({ reason = "this statement is already recorded" }));
    if (from > to or to > day) return #err(#BadDocument({ reason = "the statement's window ends on or before today" }));
    if (entries.size() > MAX_STATEMENT_ENTRIES) return #err(#BadDocument({ reason = "at most " # Nat.toText(MAX_STATEMENT_ENTRIES) # " entries" }));
    for (e in entries.vals()) {
      if (e.amount == 0) return #err(#BadDocument({ reason = "an entry's amount is positive" }));
      if (e.valueDay < from or e.valueDay > to) return #err(#BadDocument({ reason = "an entry's value day lies in the statement's window" }));
      if (bytesOf(e.reference) > 64) return #err(#BadDocument({ reason = "an entry's reference is at most 64 bytes" }));
    };
    let lo = if (from > nr.tolerance) from - nr.tolerance else 0;
    let ours = Array.filter<NostroLegRow>(nostroLegsIn(s, nr.accountHash, lo, to + nr.tolerance), func(l) { l.status == LEG_OPEN });
    let taken = VarArray.repeat<Bool>(false, ours.size());
    let matches = List.empty<Nat>();
    let breaks = List.empty<TT.TreasuryEvent>();
    func within(a : Nat, b : Nat) : Bool { (if (a > b) a - b else b - a) <= nr.tolerance };
    for (e in entries.vals()) {
      let rh = hash8(e.reference);
      var found : ?Nat = null;
      // a statement credit is our debit: the correspondent credits our account when our asset grows
      var i = 0;
      while (i < ours.size() and found == null) {
        let l = ours[i];
        if (not taken[i] and l.debit == e.credit and l.amount == e.amount and within(l.valueDay, e.valueDay) and l.refHash == rh and bytesOf(e.reference) > 0) found := ?i;
        i += 1;
      };
      i := 0;
      while (i < ours.size() and found == null) {
        let l = ours[i];
        if (not taken[i] and l.debit == e.credit and l.amount == e.amount and within(l.valueDay, e.valueDay)) found := ?i;
        i += 1;
      };
      switch (found) {
        case (?j) { taken[j] := true; List.add(matches, ours[j].posting) };
        case null List.add(breaks, #nostroBreak({ nostro = nostroId; statement; side = #onStatementOnly; amount = e.amount; credit = e.credit; valueDay = e.valueDay; reference = e.reference; posting = null; day }));
      };
    };
    var i = 0;
    while (i < ours.size()) {
      let l = ours[i];
      if (not taken[i] and l.valueDay >= from and l.valueDay <= to) {
        List.add(breaks, #nostroBreak({ nostro = nostroId; statement; side = #inOurBooksOnly; amount = l.amount; credit = not l.debit; valueDay = l.valueDay; reference = ""; posting = ?l.posting; day }));
      };
      i += 1;
    };
    #ok({ ev = #statementRecorded({ nostro = nostroId; statement; from; to; entries = entries.size(); matches = List.toArray(matches); breaks = List.size(breaks); day }); breaks = List.toArray(breaks) })
  };

  public type Correction = { account : Text; sub : ?Text; debit : Bool; amount : Nat; currency : Text };
  /// Resolve a break: the reason recorded, and a correcting posting through the suspense account when the resolution
  /// moves money (the counter-account is named; the suspense is its other side until the item is cleared).
  public func planResolveBreak(s : State, id : TT.BreakId, resolution : Text, correction : ?Correction, day : Nat) : Res<Act> {
    let p = switch (policyOf(s)) { case (#err(e)) return #err(e); case (#ok(p)) p };
    let ?b = breakRow(s, id) else return #err(#UnknownBreak({ breakId = id }));
    if (b.resolved) return #err(#BreakNotOpen({ breakId = id }));
    if (bytesOf(resolution) == 0 or bytesOf(resolution) > 128) return bad("a resolution states its reason in 1..128 bytes");
    let ls = List.empty<JT.Leg>();
    switch (correction) {
      case (?c) {
        if (c.amount == 0 or not ccyOk(c.currency) or bytesOf(c.account) == 0) return bad("a correction names an account, a positive amount and a currency");
        let sub = switch (c.sub) { case (?t) ?Posting.subledgerOf(t); case null null };
        if (c.debit) { addLeg(ls, c.account, sub, #debit, c.currency, c.amount); addLeg(ls, p.nostroSuspense, null, #credit, c.currency, c.amount) }
        else { addLeg(ls, p.nostroSuspense, null, #debit, c.currency, c.amount); addLeg(ls, c.account, sub, #credit, c.currency, c.amount) };
      };
      case null {};
    };
    #ok({ ev = #breakResolved({ breakId = id; resolution; corrected = correction != null; day }); legs = List.toArray(ls); extras = [] })
  };
  /// Open breaks older than the policy's threshold that were not yet reported: the aging events.
  public func agedBreaks(s : State, day : Nat) : [TT.TreasuryEvent] {
    let ?p = s.policy else return [];
    let out = List.empty<TT.TreasuryEvent>();
    for (b in openBreaks(s).vals()) {
      let age = if (day > b.valueDay) day - b.valueDay else 0;
      if (age >= p.breakAgeAlertDays and not b.alerted) List.add(out, #breakAged({ breakId = b.id; ageDays = age; day }));
    };
    List.toArray(out)
  };
  /// Unconfirmed deals older than the policy's confirmation window, not yet reported.
  public func overdueConfirmations(s : State, day : Nat) : [TT.TreasuryEvent] {
    let ?p = s.policy else return [];
    let out = List.empty<TT.TreasuryEvent>();
    for (r in openAll(s).vals()) {
      if (not has(r.flags, F_CONFIRMED) and not has(r.flags, F_ALERTED) and day > r.day and day - r.day >= p.confirmationDueDays) {
        List.add(out, #confirmationOverdue({ deal = r.id; ageDays = day - r.day; day }));
      };
    };
    List.toArray(out)
  };

  // ─── the fold ──────────────────────────────────────────────────────────────

  func index(s : State, r : DealRow) {
    ignore RI.put(s.byBook, Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.textKey(r.book, 32)), Blob.toArray(R.key(r.id, 8)))), Blob.fromArray([1]));
    ignore RI.put(s.byState, R.key2(Nat8.toNat(stateCode(r.state)), 1, r.id, 8), Blob.fromArray([1]));
    ignore RI.put(s.byCounterparty, R.key2(r.cpHash, 8, r.id, 8), Blob.fromArray([1]));
    if (r.kind == 4) ignore RI.put(s.byIsin, Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.textKey(r.isin, 12)), Blob.toArray(R.key(r.id, 8)))), Blob.fromArray([1]));
  };
  func withState(s : State, r : DealRow, st : TT.DealState, block : Nat) : DealRow {
    let n = { r with state = st; lastBlock = block };
    ignore RI.put(s.byState, R.key2(Nat8.toNat(stateCode(st)), 1, r.id, 8), Blob.fromArray([1]));
    if (isOpen(r) and not isOpen(n)) s.open -= 1;
    n
  };
  func rowFromKind(s : State, id : Nat, book : Text, cpHash : Nat, kind : TT.DealKind, day : Nat, within : Bool, second : Nat, block : Nat, refHash : Nat) : DealRow {
    let secRow = switch (kind) { case (#security(t)) security(s, t.isin); case (_) null };
    let f = rowFacts(kind, switch (secRow) { case (?x) x.maturity; case null 0 });
    let (isBuySec, yieldM) = switch (kind, secRow) {
      case (#security(t), ?sec) { (t.direction == #buy, if (t.direction == #buy and t.classification != #fvtpl) yieldFor(sec, t) else 0) };
      case (_) (false, 0);
    };
    {
      id; kind = kindCode(kind); state = #captured; flags = f.flags | (if (within) F_WITHIN else 0); book; cpHash;
      currency = f.currency; notional = f.notional; secondCurrency = f.second; secondAmount = second; day; start = f.start; maturity = f.maturity; rate = f.rate;
      accruedPosted = 0; amortisedPosted = 0; fvPosted = 0; markPosted = 0; realised = 0;
      nominalLeft = if (isBuySec) f.notional else 0; costLeft = if (isBuySec) second else 0; yieldMillionths = yieldM; settledMask = 0; legs = legCount(kind); lastBlock = block; termsBlock = block; isin = f.isin; refHash;
    }
  };

  public func fold(s : State, block : Nat, ev : TT.TreasuryEvent) {
    switch (ev) {
      case (#policySet(p)) s.policy := ?p;
      case (#securityRegistered(x)) {
        let t = x.terms;
        ignore RI.put(s.securities, R.textKey(t.isin, 12), encodeSecurity({ isin = t.isin; issuerHash = hash8(t.issuer); issuer = t.issuer; currency = t.currency; couponBps = t.couponBps; couponsPerYear = t.couponsPerYear; dayCount = convCode(t.dayCount); issue = t.issue; maturity = t.maturity; block }));
        s.securityCount += 1;
      };
      case (#curvePublished(x)) {
        let c = x.curve;
        if (RI.put(s.curves, curveKey(c.id, c.day), encodeCurve({ id = c.id; day = c.day; kind = c.kind; currency = c.currency; points = c.points; source = c.source; block })) == null) s.curveCount += 1;
      };
      case (#limitSet(x)) {
        let l = x.limit;
        if (RI.put(s.limits, limitKey(l.book, l.kind, l.currency, l.subject), R.key(l.value, 8)) == null) s.limitCount += 1;
        switch (l.kind, parseBucket(l.subject)) {
          case (#tenorBucket, ?(lo, hi)) { let b = R.buf(); R.putNat(b, lo, 4); R.putNat(b, hi, 4); ignore RI.put(s.buckets, bucketKey(l.book, hash8(l.subject)), R.done(b, 8)) };
          case (_) {};
        };
      };
      case (#nostroRegistered(x)) {
        let n = x.nostro;
        let h = nostroAccountHash(n.account, switch (n.sub) { case (?t) ?Posting.subledgerOf(t); case null null }, n.currency);
        ignore RI.put(s.nostros, R.textKey(n.id, 32), encodeNostro({ id = n.id; account = n.account; subText = switch (n.sub) { case (?t) t; case null "" }; hasSub = n.sub != null; currency = n.currency; accountHash = h; tolerance = n.valueDateToleranceDays; correspondentHash = hash8(n.correspondent.name); block }));
        ignore RI.put(s.nostroByAccount, R.key(h, 8), R.textKey(n.id, 32));
        switch (n.sub) { case (?t) holdSub(s, Posting.subledgerOf(t)); case null {} };
        s.nostroCount += 1;
      };
      case (#dealCaptured(x)) {
        let r = rowFromKind(s, block, x.book, hash8(x.counterparty.name), x.kind, x.day, x.withinLimits, x.secondAmount, block, hash8(x.reference));
        putRow(s, r); index(s, r); holdSub(s, dealSub(block));
        s.captured += 1; s.open += 1;
      };
      case (#limitBreached(_)) {};
      case (#dealConfirmed(x)) { switch (row(s, x.deal)) { case (?r) putRow(s, withState(s, { r with flags = r.flags | F_CONFIRMED }, #confirmed, block)); case null {} } };
      case (#confirmationMismatch(x)) { switch (row(s, x.deal)) { case (?r) putRow(s, { r with lastBlock = block }); case null {} } };
      case (#dealAmended(x)) {
        switch (row(s, x.deal)) {
          case (?r) {
            let n = rowFromKind(s, r.id, r.book, r.cpHash, x.kind, r.day, has(r.flags, F_WITHIN), x.secondAmount, block, r.refHash);
            putRow(s, { n with state = r.state; flags = n.flags | (r.flags & (F_CONFIRMED | F_ALERTED)) });
          };
          case null {};
        };
      };
      case (#dealCancelled(x)) { switch (row(s, x.deal)) { case (?r) putRow(s, withState(s, r, #cancelled, block)); case null {} } };
      case (#legSettled(x)) {
        switch (row(s, x.deal)) {
          case (?r) {
            let mask = r.settledMask + (if (legSettled(r, x.leg)) 0 else 2 ** x.leg);
            var n = { r with settledMask = mask; realised = r.realised + x.realised; accruedPosted = r.accruedPosted + x.accrual; amortisedPosted = r.amortisedPosted + x.amortisation;
                      nominalLeft = if (x.nominal > r.nominalLeft) 0 else r.nominalLeft - x.nominal; costLeft = if (x.cost > r.costLeft) 0 else r.costLeft - x.cost; lastBlock = block };
            n := if (r.kind == 4) ({ n with fvPosted = r.fvPosted + x.fv }) else ({ n with markPosted = r.markPosted + x.fv });
            s.realisedTotal += x.realised; s.markTotal += x.fv;
            var all = true; var i = 0;
            while (i < n.legs) { if (not legSettled(n, i)) all := false; i += 1 };
            putRow(s, if (all) withState(s, n, #settled, block) else n);
          };
          case null {};
        };
      };
      case (#lotConsumed(x)) {
        switch (row(s, x.lot)) {
          case (?l) {
            putRow(s, { l with nominalLeft = if (x.nominal > l.nominalLeft) 0 else l.nominalLeft - x.nominal; costLeft = if (x.cost > l.costLeft) 0 else l.costLeft - x.cost;
                        amortisedPosted = l.amortisedPosted + x.amortisation; fvPosted = l.fvPosted + x.fv; accruedPosted = l.accruedPosted + x.accrual; lastBlock = block });
            s.markTotal += x.fv;
          };
          case null {};
        };
      };
      case (#accrued(x)) { switch (row(s, x.deal)) { case (?r) putRow(s, { r with accruedPosted = r.accruedPosted + x.interest; amortisedPosted = r.amortisedPosted + x.amortisation; lastBlock = block }); case null {} } };
      case (#marked(x)) {
        switch (row(s, x.deal)) {
          case (?r) { putRow(s, if (r.kind == 4) ({ r with fvPosted = x.value; lastBlock = block }) else ({ r with markPosted = x.value; lastBlock = block })); s.markTotal += x.value - x.previous };
          case null {};
        };
      };
      case (#couponPaid(x)) { switch (row(s, x.deal)) { case (?r) putRow(s, { r with accruedPosted = 0; lastBlock = block }); case null {} } };
      case (#statementRecorded(x)) {
        switch (nostro(s, x.nostro)) {
          case (?nr) {
            let b = R.buf(); R.putText(b, x.nostro, 32); R.putNat(b, x.day, 4); R.putNat(b, x.matches.size(), 4); R.putNat(b, x.breaks, 4);
            ignore RI.put(s.statements, x.statement, R.done(b, STATEMENT_ROW_BYTES));
            let st8 = R.getNat(Blob.toArray(x.statement), 0, 8);
            for (pid in x.matches.vals()) { switch (legOf(s, nr.accountHash, pid)) { case (?l) putLeg(s, { l with status = LEG_MATCHED; statement8 = st8 }); case null {} } };
            s.statementCount += 1;
          };
          case null {};
        };
      };
      case (#nostroBreak(x)) {
        switch (nostro(s, x.nostro)) {
          case (?nr) {
            putBreak(s, { id = block; nostroHash = nr.accountHash; side = x.side; amount = x.amount; credit = x.credit; valueDay = x.valueDay; refHash = hash8(x.reference); posting = switch (x.posting) { case (?p) p; case null 0 }; openedDay = x.day; resolved = false; resolvedDay = 0; statement = x.statement; alerted = false });
            ignore RI.put(s.breaksByStatus, R.key2(0, 1, block, 8), Blob.fromArray([1]));
            switch (x.posting) { case (?pid) { switch (legOf(s, nr.accountHash, pid)) { case (?l) putLeg(s, { l with status = LEG_BROKEN; statement8 = R.getNat(Blob.toArray(x.statement), 0, 8) }); case null {} } }; case null {} };
            s.breaksTotal += 1; s.breaksOpen += 1;
          };
          case null {};
        };
      };
      case (#breakResolved(x)) {
        switch (breakRow(s, x.breakId)) {
          case (?b) { if (not b.resolved) { putBreak(s, { b with resolved = true; resolvedDay = x.day }); ignore RI.put(s.breaksByStatus, R.key2(1, 1, b.id, 8), Blob.fromArray([1])); s.breaksOpen -= 1 } };
          case null {};
        };
      };
      case (#breakAged(x)) { switch (breakRow(s, x.breakId)) { case (?b) putBreak(s, { b with alerted = true }); case null {} } };
      case (#confirmationOverdue(x)) { switch (row(s, x.deal)) { case (?r) putRow(s, { r with flags = r.flags | F_ALERTED; lastBlock = block }); case null {} } };
    }
  };

  // ─── reads ────────────────────────────────────────────────────────────────

  public func view(s : State, r : DealRow, cpName : Text, reference : Text) : TT.DealView {
    {
      id = r.id; book = r.book; kind = kindTextOf(r.kind); state = TT.dealStateText(r.state); counterparty = cpName; reference; currency = rowCurrency(s, r); notional = r.notional;
      secondCurrency = r.secondCurrency; secondAmount = r.secondAmount; day = r.day; start = r.start; maturity = r.maturity; rate = r.rate; accruedPosted = r.accruedPosted; amortisedPosted = r.amortisedPosted;
      fvPosted = r.fvPosted; markPosted = r.markPosted; realised = r.realised; nominalLeft = r.nominalLeft; costLeft = r.costLeft; yieldMillionths = r.yieldMillionths; settledLegs = settledCount(r); legs = r.legs;
      confirmed = has(r.flags, F_CONFIRMED); withinLimits = has(r.flags, F_WITHIN); lastBlock = r.lastBlock;
    }
  };
  public func breakView(b : BreakRow, nostroId : Text, reference : Text, day : Nat) : TT.BreakView {
    { id = b.id; nostro = nostroId; side = TT.breakSideText(b.side); amount = b.amount; credit = b.credit; valueDay = b.valueDay; reference; posting = if (b.posting == 0) null else ?b.posting; openedDay = b.openedDay;
      ageDays = if (day > b.valueDay) day - b.valueDay else 0; resolved = b.resolved; block = b.id }
  };
  public func nostroIdOfHash(s : State, h : Nat) : Text { switch (nostroOfAccount(s, h)) { case (?n) n.id; case null "" } };
  /// Positions of a book: open deals aggregated by kind × instrument × currency — the nominal signed from the bank's
  /// side, the carrying amount booked, the mark.
  public func positions(s : State, book : Text, terms : Nat -> ?TT.DealKind) : [TT.PositionView] {
    let acc = List.empty<TT.PositionView>();
    for (r in openInBook(s, book).vals()) {
      let (instrument, ccy, nominal, carrying) : (Text, Text, Int, Int) = switch (r.kind) {
        case 4 { (r.isin, rowCurrency(s, r), if (has(r.flags, F_BUY)) r.nominalLeft else 0, (r.costLeft : Int) + r.amortisedPosted + r.fvPosted) };
        case 1 { (if (has(r.flags, F_BUY)) "placement" else "taking", r.currency, if (has(r.flags, F_BUY)) r.notional else -(r.notional : Int), (r.notional : Int) + r.accruedPosted) };
        case 5 { ("irs", r.currency, if (has(r.flags, F_BUY)) r.notional else -(r.notional : Int), r.markPosted) };
        case _ { (r.currency # "/" # r.secondCurrency, r.currency, signedBase(r, terms(r.termsBlock)), r.markPosted) };
      };
      let kindText = kindTextOf(r.kind);
      var merged = false;
      let arr = List.toArray(acc);
      List.clear(acc);
      for (p in arr.vals()) {
        if (not merged and Text.equal(p.instrument, instrument) and Text.equal(p.currency, ccy) and Text.equal(p.kind, kindText)) {
          List.add(acc, { p with nominal = p.nominal + nominal; carrying = p.carrying + carrying; mark = p.mark + r.markPosted + r.fvPosted; deals = p.deals + 1 }); merged := true;
        } else List.add(acc, p);
      };
      if (not merged) List.add(acc, { book; instrument; currency = ccy; kind = kindText; nominal; carrying; mark = r.markPosted + r.fvPosted; deals = 1 });
    };
    List.toArray(acc)
  };
  public func status(s : State) : TT.Status {
    { deals = s.captured; open = s.open; curves = s.curveCount; securities = s.securityCount; limits = s.limitCount; nostros = s.nostroCount; breaksOpen = s.breaksOpen; breaksTotal = s.breaksTotal; statements = s.statementCount; realisedTotal = s.realisedTotal; markTotal = s.markTotal }
  };

  // ─── fingerprint ──────────────────────────────────────────────────────────

  func fingerprintRows(w : C.Writer, idx : RI.State, keyWidth : Nat) {
    let (lo, hi) = R.fullRange(keyWidth);
    var cursor : ?Blob = null;
    var n = 0;
    label walk loop {
      let page = RI.range(idx, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) { w.blob(k); w.blob(v); n += 1 };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    w.nat(n);
  };
  public func fingerprintInto(w : C.Writer, s : State) {
    switch (s.policy) {
      case null w.byte(0);
      case (?p) { w.byte(1); for (t in accountsOf(p).vals()) w.text(t); w.text(TT.lotMethodText(p.lotMethod)); w.nat(p.confirmationDueDays); w.nat(p.breakAgeAlertDays); w.nat(p.maxCurvePoints) };
    };
    w.nat(s.captured); w.nat(s.open); w.nat(s.curveCount); w.nat(s.securityCount); w.nat(s.limitCount); w.nat(s.nostroCount); w.nat(s.breaksTotal); w.nat(s.breaksOpen); w.nat(s.statementCount);
    w.bool(s.realisedTotal < 0); w.nat(Int.abs(s.realisedTotal)); w.bool(s.markTotal < 0); w.nat(Int.abs(s.markTotal));
    fingerprintRows(w, s.deals, 8); fingerprintRows(w, s.securities, 12); fingerprintRows(w, s.curves, 36); fingerprintRows(w, s.limits, 49); fingerprintRows(w, s.buckets, 40);
    fingerprintRows(w, s.nostros, 32); fingerprintRows(w, s.nostroByAccount, 8); fingerprintRows(w, s.nostroLegs, 20); fingerprintRows(w, s.legByPosting, 16); fingerprintRows(w, s.statements, 32); fingerprintRows(w, s.breaks, 8);
    fingerprintRows(w, s.byBook, 40); fingerprintRows(w, s.byState, 9); fingerprintRows(w, s.byCounterparty, 16); fingerprintRows(w, s.byIsin, 20); fingerprintRows(w, s.breaksByStatus, 9); fingerprintRows(w, s.subledgers, 32);
  };
}
