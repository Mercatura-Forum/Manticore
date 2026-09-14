/// TellerCore.mo; the branch's counted cash, sessions, cash network, cheques and drafts, folded from the bank's log
/// in stable memory (branch and teller).
///
/// Rows: a teller session (keyed by the block that opened it) with the till's open session indexed by till; the
/// denomination position of every till and every vault (till ‖ face → count, book ‖ currency ‖ face → count),
/// written by the fold from the counts every cash act carries; the cash movements in transit; a customer's
/// chequebooks (account ‖ first serial → last) and the cheques that left the unused state (account ‖ serial → state,
/// amount, hold); the bank's drafts. The amounts are the journal's; this layer keeps what the journal does not;
/// the composition of the cash, who was at the drawer, and where each instrument is in its life. The planners
/// refuse an act the count cannot support (a payment in notes the drawer does not hold) and decide a presented
/// cheque's fate from the recorded dates and state; the postings are `BankCore`'s.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";

import TT "TellerTypes";
import ProdT "ProductTypes";
import R "StableRows";
import Posting "Posting";
import JT "mo:journal/JournalTypes";

module {

  public let SESSION_ROW_BYTES : Nat = 132;
  public let MOVEMENT_ROW_BYTES : Nat = 132;
  public let CHEQUE_ROW_BYTES : Nat = 32;
  public let DRAFT_ROW_BYTES : Nat = 72;
  let MAX_PAGE : Nat = 500;
  public let MAX_CHEQUEBOOK : Nat = 1_000;

  public type SessionRow = {
    till : Text; teller : Principal; openedBlock : Nat; closedBlock : Nat; openingCounted : Nat; openingBook : Nat;
    closingCounted : Nat; closingBook : Nat; difference : TT.Difference; resolvedBlock : Nat; day : Nat; closed : Bool; resolved : Bool;
  };
  public type MovementRow = { product : Text; fromBook : Text; toBook : Text; currency : Text; amount : Nat; inTransit : Bool; dispatchedBlock : Nat; receivedBlock : Nat };
  public type ChequeRow = { state : TT.ChequeState; amount : Nat; hold : Nat; chequeDate : Nat; lastBlock : Nat; reason : ?TT.ReturnReason };
  public type DraftRow = { state : TT.DraftState; amount : Nat; currency : Text; issuedBlock : Nat; lastBlock : Nat; serialHash : Blob };

  public type State = {
    sessions : RI.State;       // session(8) -> SessionRow
    openSession : RI.State;    // till(32) -> session(8)
    tillDenoms : RI.State;     // till(32) ‖ face(8) -> count(8)
    vaultDenoms : RI.State;    // book(32) ‖ currency(8) ‖ face(8) -> count(8)
    movements : RI.State;      // movement(8) -> MovementRow
    chequebooks : RI.State;    // account(8) ‖ from(8) -> to(8)
    cheques : RI.State;        // account(8) ‖ serial(8) -> ChequeRow
    drafts : RI.State;         // serial key(8) -> DraftRow
    subledgers : RI.State;     // the transit and draft sub-ledgers this shard posts to (32) -> 1
    var policy : ?TT.Policy;
    var sessionsOpened : Nat;
    var differences : Nat;
    var movementsDispatched : Nat;
    var movementsInTransit : Nat;
    var chequesPresented : Nat;
    var chequesReturned : Nat;
    var draftsIssued : Nat;
  };

  public func newState(arena : RI.Arena) : State {
    {
      sessions = RI.newStateIn(arena, { keyBytes = 8; valBytes = SESSION_ROW_BYTES });
      openSession = RI.newStateIn(arena, { keyBytes = 32; valBytes = 8 });
      tillDenoms = RI.newStateIn(arena, { keyBytes = 40; valBytes = 8 });
      vaultDenoms = RI.newStateIn(arena, { keyBytes = 48; valBytes = 8 });
      movements = RI.newStateIn(arena, { keyBytes = 8; valBytes = MOVEMENT_ROW_BYTES });
      chequebooks = RI.newStateIn(arena, { keyBytes = 16; valBytes = 8 });
      cheques = RI.newStateIn(arena, { keyBytes = 16; valBytes = CHEQUE_ROW_BYTES });
      drafts = RI.newStateIn(arena, { keyBytes = 8; valBytes = DRAFT_ROW_BYTES });
      subledgers = RI.newStateIn(arena, { keyBytes = 32; valBytes = 1 });
      var policy = null; var sessionsOpened = 0; var differences = 0; var movementsDispatched = 0; var movementsInTransit = 0; var chequesPresented = 0; var chequesReturned = 0; var draftsIssued = 0;
    }
  };

  // ─── keys and codes ───────────────────────────────────────────────────────

  /// The sub-ledger of a cash movement on the cash-in-transit account, and of a draft on drafts payable.
  public func transitSub(movement : Nat) : JT.SubledgerKey { Posting.subledgerOf("transit/" # Nat.toText(movement)) };
  public func draftSub(serial : Text) : JT.SubledgerKey { Posting.subledgerOf("draft/" # serial) };
  public func holdsSubledger(s : State, sub : JT.SubledgerKey) : Bool { sub.size() == 32 and RI.get(s.subledgers, sub) != null };
  func holdSub(s : State, sub : JT.SubledgerKey) { ignore RI.put(s.subledgers, sub, Blob.fromArray([1])) };

  func tillKey(till : Text) : Blob { R.textKey(till, 32) };
  func denomKey(till : Text, face : Nat) : Blob { Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.textKey(till, 32)), Blob.toArray(R.key(face, 8)))) };
  func vaultKey(book : Text, ccy : Text, face : Nat) : Blob { Blob.fromArray(Array.concat<Nat8>(Array.concat<Nat8>(Blob.toArray(R.textKey(book, 32)), Blob.toArray(R.textKey(ccy, 8))), Blob.toArray(R.key(face, 8)))) };
  func draftKey(serial : Text) : Blob { R.key(R.getNat(Blob.toArray(Sha256.fromBlob(#sha256, Text.encodeUtf8(serial))), 0, 8), 8) };
  func diffCode(d : TT.Difference) : Nat8 { switch (d) { case (#balanced) 0; case (#over(_)) 1; case (#short(_)) 2 } };
  func diffOf(code : Nat8, amount : Nat) : TT.Difference { switch (code) { case 1 #over(amount); case 2 #short(amount); case _ #balanced } };
  public func diffAmount(d : TT.Difference) : Nat { switch (d) { case (#balanced) 0; case (#over(n)) n; case (#short(n)) n } };
  func chequeStateCode(s : TT.ChequeState) : Nat8 { switch (s) { case (#unused) 0; case (#stopped) 1; case (#held) 2; case (#cleared) 3; case (#returned) 4 } };
  func chequeStateOf(c : Nat8) : TT.ChequeState { switch (c) { case 1 #stopped; case 2 #held; case 3 #cleared; case 4 #returned; case _ #unused } };
  func reasonCode(r : ?TT.ReturnReason) : Nat8 { switch (r) { case null 0; case (?#insufficientFunds) 1; case (?#stopped) 2; case (?#signature) 3; case (?#stale) 4; case (?#postDated) 5; case (?#other(_)) 6 } };
  func reasonOf(c : Nat8) : ?TT.ReturnReason { switch (c) { case 1 ?#insufficientFunds; case 2 ?#stopped; case 3 ?#signature; case 4 ?#stale; case 5 ?#postDated; case 6 ?#other(""); case _ null } };
  func draftStateCode(s : TT.DraftState) : Nat8 { switch (s) { case (#outstanding) 0; case (#paid) 1; case (#cancelled) 2 } };
  func draftStateOf(c : Nat8) : TT.DraftState { switch (c) { case 1 #paid; case 2 #cancelled; case _ #outstanding } };

  // ─── rows ─────────────────────────────────────────────────────────────────

  func encodeSession(r : SessionRow) : Blob {
    let b = R.buf();
    R.putText(b, r.till, 32);
    let pb = Blob.toArray(Principal.toBlob(r.teller));
    if (pb.size() > 29) Runtime.trap("TellerCore: a principal of more than 29 bytes");
    R.putByte(b, Nat8.fromNat(pb.size())); R.putBlob(b, Blob.fromArray(Array.tabulate<Nat8>(29, func(i) { if (i < pb.size()) pb[i] else 0 })), 29);
    R.putNat(b, r.openedBlock, 8); R.putNat(b, r.closedBlock, 8); R.putNat(b, r.openingCounted, 8); R.putNat(b, r.openingBook, 8);
    R.putNat(b, r.closingCounted, 8); R.putNat(b, r.closingBook, 8); R.putByte(b, diffCode(r.difference)); R.putNat(b, diffAmount(r.difference), 8);
    R.putNat(b, r.resolvedBlock, 8); R.putNat(b, r.day, 4);
    var flags : Nat8 = 0; if (r.closed) flags |= 1; if (r.resolved) flags |= 2; R.putByte(b, flags);
    R.done(b, SESSION_ROW_BYTES)
  };
  func decodeSession(v : Blob) : SessionRow {
    let a = Blob.toArray(v);
    let len = Nat8.toNat(a[32]);
    let flags = a[131];
    {
      till = R.getText(a, 0, 32); teller = Principal.fromBlob(Blob.fromArray(Array.tabulate<Nat8>(len, func(i) { a[33 + i] })));
      openedBlock = R.getNat(a, 62, 8); closedBlock = R.getNat(a, 70, 8); openingCounted = R.getNat(a, 78, 8); openingBook = R.getNat(a, 86, 8);
      closingCounted = R.getNat(a, 94, 8); closingBook = R.getNat(a, 102, 8); difference = diffOf(a[110], R.getNat(a, 111, 8));
      resolvedBlock = R.getNat(a, 119, 8); day = R.getNat(a, 127, 4); closed = flags & 1 != 0; resolved = flags & 2 != 0;
    }
  };
  public func session(s : State, id : TT.SessionId) : ?SessionRow { switch (RI.get(s.sessions, R.key(id, 8))) { case (?v) ?decodeSession(v); case null null } };
  /// The till's open session; a closed one leaves a zero behind (no session is block 0, the genesis record).
  public func openSessionOf(s : State, till : Text) : ?TT.SessionId {
    switch (RI.get(s.openSession, tillKey(till))) { case (?v) { let id = R.getNat(Blob.toArray(v), 0, 8); if (id == 0) null else ?id }; case null null }
  };

  func encodeMovement(r : MovementRow) : Blob {
    let b = R.buf();
    R.putText(b, r.product, 32); R.putText(b, r.fromBook, 32); R.putText(b, r.toBook, 32); R.putText(b, r.currency, 8);
    R.putNat(b, r.amount, 8); R.putBool(b, r.inTransit); R.putNat(b, r.dispatchedBlock, 8); R.putNat(b, r.receivedBlock, 8);
    R.putByte(b, 0); R.putByte(b, 0); R.putByte(b, 0);
    R.done(b, MOVEMENT_ROW_BYTES)
  };
  func decodeMovement(v : Blob) : MovementRow {
    let a = Blob.toArray(v);
    { product = R.getText(a, 0, 32); fromBook = R.getText(a, 32, 32); toBook = R.getText(a, 64, 32); currency = R.getText(a, 96, 8);
      amount = R.getNat(a, 104, 8); inTransit = R.getBool(a, 112); dispatchedBlock = R.getNat(a, 113, 8); receivedBlock = R.getNat(a, 121, 8) }
  };
  public func movement(s : State, id : TT.MovementId) : ?MovementRow { switch (RI.get(s.movements, R.key(id, 8))) { case (?v) ?decodeMovement(v); case null null } };

  func encodeCheque(r : ChequeRow) : Blob {
    let b = R.buf();
    R.putByte(b, chequeStateCode(r.state)); R.putNat(b, r.amount, 8); R.putNat(b, r.hold, 8); R.putNat(b, r.chequeDate, 4); R.putNat(b, r.lastBlock, 8); R.putByte(b, reasonCode(r.reason));
    R.putByte(b, 0); R.putByte(b, 0);
    R.done(b, CHEQUE_ROW_BYTES)
  };
  func decodeCheque(v : Blob) : ChequeRow {
    let a = Blob.toArray(v);
    { state = chequeStateOf(a[0]); amount = R.getNat(a, 1, 8); hold = R.getNat(a, 9, 8); chequeDate = R.getNat(a, 17, 4); lastBlock = R.getNat(a, 21, 8); reason = reasonOf(a[29]) }
  };
  public func cheque(s : State, account : Nat, serial : Nat) : ?ChequeRow { switch (RI.get(s.cheques, R.key2(account, 8, serial, 8))) { case (?v) ?decodeCheque(v); case null null } };

  func encodeDraft(r : DraftRow) : Blob {
    let b = R.buf();
    R.putByte(b, draftStateCode(r.state)); R.putNat(b, r.amount, 8); R.putText(b, r.currency, 8); R.putNat(b, r.issuedBlock, 8); R.putNat(b, r.lastBlock, 8); R.putBlob(b, r.serialHash, 32);
    R.putNat(b, 0, 7);
    R.done(b, DRAFT_ROW_BYTES)
  };
  func decodeDraft(v : Blob) : DraftRow {
    let a = Blob.toArray(v);
    { state = draftStateOf(a[0]); amount = R.getNat(a, 1, 8); currency = R.getText(a, 9, 8); issuedBlock = R.getNat(a, 17, 8); lastBlock = R.getNat(a, 25, 8); serialHash = R.getBlob(a, 33, 32) }
  };
  public func draft(s : State, serial : Text) : ?DraftRow {
    switch (RI.get(s.drafts, draftKey(serial))) {
      case (?v) { let r = decodeDraft(v); if (r.serialHash == Sha256.fromBlob(#sha256, Text.encodeUtf8(serial))) ?r else null };
      case null null;
    }
  };

  // ─── denominations ────────────────────────────────────────────────────────

  public func validDenominations(d : TT.DenominationSet) : ?Text {
    if (d.notes.size() + d.coins.size() > 64) return ?"at most 64 denominations";
    var i = 0;
    for ((face, count) in Array.concat<(Nat, Nat)>(d.notes, d.coins).vals()) {
      if (face == 0) return ?"a denomination with no face value";
      var j = 0;
      for ((other, _) in Array.concat<(Nat, Nat)>(d.notes, d.coins).vals()) { if (j < i and other == face) return ?"a denomination listed twice"; j += 1 };
      ignore count; i += 1;
    };
    null
  };
  func faces(d : TT.DenominationSet) : [(Nat, Nat)] { Array.concat<(Nat, Nat)>(d.notes, d.coins) };

  public func tillCount(s : State, till : Text, face : Nat) : Nat { switch (RI.get(s.tillDenoms, denomKey(till, face))) { case (?v) R.getNat(Blob.toArray(v), 0, 8); case null 0 } };
  public func vaultCount(s : State, book : Text, ccy : Text, face : Nat) : Nat { switch (RI.get(s.vaultDenoms, vaultKey(book, ccy, face))) { case (?v) R.getNat(Blob.toArray(v), 0, 8); case null 0 } };

  /// Whether the till holds what `paid` says in every denomination.
  public func tillHolds(s : State, till : Text, paid : TT.DenominationSet) : Bool {
    for ((face, count) in faces(paid).vals()) { if (tillCount(s, till, face) < count) return false };
    true
  };
  public func vaultHolds(s : State, book : Text, ccy : Text, d : TT.DenominationSet) : Bool {
    for ((face, count) in faces(d).vals()) { if (vaultCount(s, book, ccy, face) < count) return false };
    true
  };
  func tillAdjust(s : State, till : Text, d : TT.DenominationSet, add : Bool) {
    for ((face, count) in faces(d).vals()) {
      let have = tillCount(s, till, face);
      let next = if (add) have + count else (if (have >= count) have - count else 0);
      ignore RI.put(s.tillDenoms, denomKey(till, face), R.key(next, 8));
    };
  };
  func tillSet(s : State, till : Text, d : TT.DenominationSet) {
    // the count replaces the position: every denomination held goes to zero, then the count is written
    let (lo, hi) = prefixRangeText(till, 32, 8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.tillDenoms, lo, hi, cursor, MAX_PAGE);
      for ((k, _) in page.entries.vals()) ignore RI.put(s.tillDenoms, k, R.key(0, 8));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    tillAdjust(s, till, d, true);
  };
  func vaultAdjust(s : State, book : Text, ccy : Text, d : TT.DenominationSet, add : Bool) {
    for ((face, count) in faces(d).vals()) {
      let have = vaultCount(s, book, ccy, face);
      let next = if (add) have + count else (if (have >= count) have - count else 0);
      ignore RI.put(s.vaultDenoms, vaultKey(book, ccy, face), R.key(next, 8));
    };
  };
  func prefixRangeText(prefix : Text, wp : Nat, rest : Nat) : (Blob, Blob) {
    let p = Blob.toArray(R.textKey(prefix, wp));
    let lo = Array.concat<Nat8>(p, Array.tabulate<Nat8>(rest, func(_) { 0 }));
    let hi = Array.concat<Nat8>(p, Array.tabulate<Nat8>(rest, func(_) { 255 }));
    (Blob.fromArray(lo), Blob.fromArray(hi))
  };

  /// The denomination position of a till, as (face, count), the non-zero ones.
  public func tillDenominations(s : State, till : Text) : [(Nat, Nat)] {
    let out = List.empty<(Nat, Nat)>();
    let (lo, hi) = prefixRangeText(till, 32, 8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.tillDenoms, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) { let n = R.getNat(Blob.toArray(v), 0, 8); if (n > 0) List.add(out, (R.getNat(Blob.toArray(k), 32, 8), n)) };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  public func vaultDenominations(s : State, book : Text, ccy : Text) : [(Nat, Nat)] {
    let out = List.empty<(Nat, Nat)>();
    let p = Array.concat<Nat8>(Blob.toArray(R.textKey(book, 32)), Blob.toArray(R.textKey(ccy, 8)));
    let lo = Blob.fromArray(Array.concat<Nat8>(p, Array.tabulate<Nat8>(8, func(_) { 0 })));
    let hi = Blob.fromArray(Array.concat<Nat8>(p, Array.tabulate<Nat8>(8, func(_) { 255 })));
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.vaultDenoms, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) { let n = R.getNat(Blob.toArray(v), 0, 8); if (n > 0) List.add(out, (R.getNat(Blob.toArray(k), 40, 8), n)) };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  public func positionValue(xs : [(Nat, Nat)]) : Nat { var v = 0; for ((face, count) in xs.vals()) v += face * count; v };

  // ─── the planners ─────────────────────────────────────────────────────────

  public type Planned = Result.Result<TT.TellerEvent, TT.TellerError>;

  public func validPolicy(p : TT.Policy) : ?Text {
    for (code in [p.overShort, p.cashInTransit, p.centralBank, p.draftsPayable, p.clearing].vals()) { if (Text.size(code) == 0) return ?"every account of the policy is named" };
    if (p.staleDays == 0) return ?"a stale period of zero days";
    if (p.clearingWindowDays == 0) return ?"a clearing window of zero days";
    null
  };
  public func planPolicy(p : TT.Policy) : Planned { switch (validPolicy(p)) { case (?reason) #err(#InvalidPolicy({ reason })); case null #ok(#policySet(p)) } };
  public func policy(s : State) : ?TT.Policy { s.policy };

  public func planOpenSession(s : State, till : Text, teller : Principal, opening : TT.DenominationSet, book : Nat, day : Nat) : Planned {
    switch (validDenominations(opening)) { case (?reason) return #err(#InvalidDenominations({ reason })); case null {} };
    switch (openSessionOf(s, till)) { case (?id) return #err(#SessionOpen({ till; session = id })); case null {} };
    #ok(#sessionOpened({ till; teller; opening; counted = TT.value(opening); book; day }))
  };
  public func planCloseSession(s : State, till : Text, closing : TT.DenominationSet, book : Nat, day : Nat) : Planned {
    switch (validDenominations(closing)) { case (?reason) return #err(#InvalidDenominations({ reason })); case null {} };
    let ?id = openSessionOf(s, till) else return #err(#NoSession({ till }));
    let counted = TT.value(closing);
    let difference : TT.Difference = if (counted == book) #balanced else if (counted > book) #over(counted - book) else #short(book - counted);
    #ok(#sessionClosed({ session = id; till; closing; counted; book; difference; day }))
  };
  public func planResolve(s : State, id : TT.SessionId, account : Text, note : Text, day : Nat) : Planned {
    let ?r = session(s, id) else return #err(#UnknownSession({ session = id }));
    if (not r.closed or r.resolved or r.difference == #balanced) return #err(#DifferenceNotOpen({ session = id }));
    if (Text.encodeUtf8(note).size() > 256) return #err(#InvalidRequest({ reason = "a note is at most 256 bytes" }));
    #ok(#differenceResolved({ session = id; till = r.till; difference = r.difference; account; note; day }))
  };
  /// A session must be open on the till for a counted act at its drawer.
  public func requireSession(s : State, till : Text) : Result.Result<TT.SessionId, TT.TellerError> {
    switch (openSessionOf(s, till)) { case (?id) #ok(id); case null #err(#NoSession({ till })) }
  };
  public func planCashTaken(s : State, till : Text, account : Nat, amount : Nat, tendered : TT.DenominationSet, change : TT.DenominationSet, day : Nat) : Planned {
    switch (validDenominations(tendered)) { case (?reason) return #err(#InvalidDenominations({ reason })); case null {} };
    switch (validDenominations(change)) { case (?reason) return #err(#InvalidDenominations({ reason })); case null {} };
    switch (requireSession(s, till)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    let t = TT.value(tendered); let c = TT.value(change);
    if (t < c or t - c != amount) return #err(#CountMismatch({ counted = if (t >= c) t - c else 0; amount }));
    // the change comes out of the drawer as it stands once the tender is in it
    for ((face, count) in faces(change).vals()) {
      var tenderedOfFace = 0;
      for ((f, c) in faces(tendered).vals()) { if (f == face) tenderedOfFace += c };
      if (tillCount(s, till, face) + tenderedOfFace < count) return #err(#InvalidDenominations({ reason = "the drawer does not hold the change" }));
    };
    #ok(#cashTaken({ till; account; amount; tendered; change; day }))
  };
  public func planCashPaid(s : State, till : Text, account : Nat, amount : Nat, paid : TT.DenominationSet, day : Nat) : Planned {
    switch (validDenominations(paid)) { case (?reason) return #err(#InvalidDenominations({ reason })); case null {} };
    switch (requireSession(s, till)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    if (TT.value(paid) != amount) return #err(#CountMismatch({ counted = TT.value(paid); amount }));
    if (not tillHolds(s, till, paid)) return #err(#InvalidDenominations({ reason = "the drawer does not hold those notes" }));
    #ok(#cashPaid({ till; account; amount; paid; day }))
  };
  public func planVaultToTill(s : State, till : Text, book : Text, ccy : Text, amount : Nat, d : TT.DenominationSet, day : Nat) : Planned {
    switch (validDenominations(d)) { case (?reason) return #err(#InvalidDenominations({ reason })); case null {} };
    if (TT.value(d) != amount) return #err(#CountMismatch({ counted = TT.value(d); amount }));
    if (not vaultHolds(s, book, ccy, d)) return #err(#InvalidDenominations({ reason = "the vault does not hold those notes" }));
    #ok(#vaultToTill({ till; book; currency = ccy; amount; denominations = d; day }))
  };
  public func planTillToVault(s : State, till : Text, book : Text, ccy : Text, amount : Nat, d : TT.DenominationSet, day : Nat) : Planned {
    switch (validDenominations(d)) { case (?reason) return #err(#InvalidDenominations({ reason })); case null {} };
    if (TT.value(d) != amount) return #err(#CountMismatch({ counted = TT.value(d); amount }));
    if (not tillHolds(s, till, d)) return #err(#InvalidDenominations({ reason = "the drawer does not hold those notes" }));
    #ok(#tillToVault({ till; book; currency = ccy; amount; denominations = d; day }))
  };
  public func planDispatch(s : State, product : Text, fromBook : Text, toBook : Text, ccy : Text, amount : Nat, d : TT.DenominationSet, carrier : Text, sealBag : Text, day : Nat) : Planned {
    switch (validDenominations(d)) { case (?reason) return #err(#InvalidDenominations({ reason })); case null {} };
    if (Text.equal(fromBook, toBook)) return #err(#InvalidRequest({ reason = "a movement between a vault and itself" }));
    if (TT.value(d) != amount or amount == 0) return #err(#CountMismatch({ counted = TT.value(d); amount }));
    if (Text.size(carrier) == 0 or Text.encodeUtf8(carrier).size() > 64 or Text.encodeUtf8(sealBag).size() > 64) return #err(#InvalidRequest({ reason = "a carrier is named in at most 64 bytes, a seal bag in at most 64" }));
    if (not vaultHolds(s, fromBook, ccy, d)) return #err(#InvalidDenominations({ reason = "the vault does not hold those notes" }));
    #ok(#cashDispatched({ product; fromBook; toBook; currency = ccy; amount; denominations = d; carrier; sealBag; day }))
  };
  public func planReceive(s : State, id : TT.MovementId, d : TT.DenominationSet, day : Nat) : Result.Result<(TT.TellerEvent, MovementRow), TT.TellerError> {
    let ?m = movement(s, id) else return #err(#UnknownMovement({ movement = id }));
    if (not m.inTransit) return #err(#MovementNotInTransit({ movement = id }));
    switch (validDenominations(d)) { case (?reason) return #err(#InvalidDenominations({ reason })); case null {} };
    if (TT.value(d) != m.amount) return #err(#CountMismatch({ counted = TT.value(d); amount = m.amount }));
    #ok((#cashReceived({ movement = id; denominations = d; day }), m))
  };
  public func planVaultToCentralBank(s : State, product : Text, book : Text, ccy : Text, amount : Nat, d : TT.DenominationSet, day : Nat) : Planned {
    switch (validDenominations(d)) { case (?reason) return #err(#InvalidDenominations({ reason })); case null {} };
    if (TT.value(d) != amount or amount == 0) return #err(#CountMismatch({ counted = TT.value(d); amount }));
    if (not vaultHolds(s, book, ccy, d)) return #err(#InvalidDenominations({ reason = "the vault does not hold those notes" }));
    #ok(#vaultToCentralBank({ product; book; currency = ccy; amount; denominations = d; day }))
  };
  public func planCentralBankToVault(product : Text, book : Text, ccy : Text, amount : Nat, d : TT.DenominationSet, day : Nat) : Planned {
    switch (validDenominations(d)) { case (?reason) return #err(#InvalidDenominations({ reason })); case null {} };
    if (TT.value(d) != amount or amount == 0) return #err(#CountMismatch({ counted = TT.value(d); amount }));
    #ok(#centralBankToVault({ product; book; currency = ccy; amount; denominations = d; day }))
  };

  // cheques
  public func chequebookOf(s : State, account : Nat, serial : Nat) : ?(Nat, Nat) {
    // the book whose range holds the serial: the last book starting at or before it
    let lo = R.key2(account, 8, 0, 8); let hi = R.key2(account, 8, serial, 8);
    var cursor : ?Blob = null;
    var found : ?(Nat, Nat) = null;
    label walk loop {
      let page = RI.range(s.chequebooks, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) { let from = R.getNat(Blob.toArray(k), 8, 8); let to = R.getNat(Blob.toArray(v), 0, 8); if (serial >= from and serial <= to) found := ?(from, to) };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    found
  };
  public func planIssueChequebook(s : State, account : Nat, from : Nat, to : Nat, day : Nat) : Planned {
    if (from == 0 or to < from) return #err(#SerialRangeInvalid({ reason = "serials run from 1 and the range ends where it starts or after" }));
    if (to - from + 1 > MAX_CHEQUEBOOK) return #err(#SerialRangeInvalid({ reason = "a chequebook holds at most " # Nat.toText(MAX_CHEQUEBOOK) # " leaves" }));
    // no leaf may already belong to a book of the account
    if (chequebookOf(s, account, from) != null or chequebookOf(s, account, to) != null) return #err(#SerialRangeInvalid({ reason = "a serial of the range was issued before" }));
    let lo = R.key2(account, 8, from, 8); let hi = R.key2(account, 8, to, 8);
    let page = RI.range(s.chequebooks, lo, hi, null, 1);
    if (page.entries.size() > 0) return #err(#SerialRangeInvalid({ reason = "a serial of the range was issued before" }));
    #ok(#chequebookIssued({ account; from; to; day }))
  };
  func chequeState(s : State, account : Nat, serial : Nat) : Result.Result<TT.ChequeState, TT.TellerError> {
    if (chequebookOf(s, account, serial) == null) return #err(#SerialNotIssued({ account; serial }));
    #ok(switch (cheque(s, account, serial)) { case (?r) r.state; case null #unused })
  };
  public func planStop(s : State, account : Nat, serial : Nat, reason : Text, day : Nat) : Planned {
    let st = switch (chequeState(s, account, serial)) { case (#err(e)) return #err(e); case (#ok(st)) st };
    if (st != #unused) return #err(#ChequeNotIn({ account; serial; state = TT.chequeStateText(st); wanted = "unused" }));
    if (Text.encodeUtf8(reason).size() > 128) return #err(#InvalidRequest({ reason = "a reason is at most 128 bytes" }));
    #ok(#chequeStopped({ account; serial; reason; day }))
  };
  /// A presented cheque's fate from the recorded facts: stopped, stale or post-dated is returned at presentation
  /// (no hold); otherwise it is held for the clearing window and the caller places the journal's pending posting.
  public func presentationFate(s : State, account : Nat, serial : Nat, chequeDate : Nat, today : Nat) : Result.Result<?TT.ReturnReason, TT.TellerError> {
    let ?p = s.policy else return #err(#NoPolicy);
    let st = switch (chequeState(s, account, serial)) { case (#err(e)) return #err(e); case (#ok(st)) st };
    switch (st) {
      case (#unused) {};
      case (#stopped) return #ok(?#stopped);
      case (_) return #err(#ChequeNotIn({ account; serial; state = TT.chequeStateText(st); wanted = "unused or stopped" }));
    };
    if (chequeDate > today) return #ok(?#postDated);
    if (today - chequeDate > p.staleDays) return #ok(?#stale);
    #ok(null)
  };
  public func requireHeld(s : State, account : Nat, serial : Nat) : Result.Result<ChequeRow, TT.TellerError> {
    let ?r = cheque(s, account, serial) else return #err(#SerialNotIssued({ account; serial }));
    if (r.state != #held) return #err(#ChequeNotIn({ account; serial; state = TT.chequeStateText(r.state); wanted = "held" }));
    #ok(r)
  };

  // drafts
  public func planIssueDraft(s : State, serial : Text, payeeCommit : Blob, amount : Nat, currency : Text, source : TT.CashSource, day : Nat) : Planned {
    if (Text.size(serial) == 0 or Text.encodeUtf8(serial).size() > 64) return #err(#InvalidRequest({ reason = "a draft serial is 1..64 bytes" }));
    if (amount == 0) return #err(#InvalidRequest({ reason = "a draft for nothing" }));
    if (payeeCommit.size() != 32) return #err(#InvalidRequest({ reason = "the payee commitment is 32 bytes" }));
    if (draft(s, serial) != null) return #err(#DraftExists({ serial }));
    #ok(#draftIssued({ serial; payeeCommit; amount; currency; source; day }))
  };
  public func requireOutstanding(s : State, serial : Text) : Result.Result<DraftRow, TT.TellerError> {
    let ?r = draft(s, serial) else return #err(#UnknownDraft({ serial }));
    if (r.state != #outstanding) return #err(#DraftNotOutstanding({ serial }));
    #ok(r)
  };

  // ─── the fold ─────────────────────────────────────────────────────────────

  public func apply(s : State, block : Nat, e : TT.TellerEvent) {
    switch (e) {
      case (#policySet(p)) s.policy := ?p;
      case (#sessionOpened(x)) {
        ignore RI.put(s.sessions, R.key(block, 8), encodeSession({ till = x.till; teller = x.teller; openedBlock = block; closedBlock = 0; openingCounted = x.counted; openingBook = x.book; closingCounted = 0; closingBook = 0; difference = #balanced; resolvedBlock = 0; day = x.day; closed = false; resolved = false }));
        ignore RI.put(s.openSession, tillKey(x.till), R.key(block, 8));
        tillSet(s, x.till, x.opening);
        s.sessionsOpened += 1;
      };
      case (#sessionClosed(x)) {
        switch (session(s, x.session)) {
          case (?r) ignore RI.put(s.sessions, R.key(x.session, 8), encodeSession({ r with closedBlock = block; closingCounted = x.counted; closingBook = x.book; difference = x.difference; closed = true }));
          case null {};
        };
        ignore RI.put(s.openSession, tillKey(x.till), R.key(0, 8));
        tillSet(s, x.till, x.closing);
        if (x.difference != #balanced) s.differences += 1;
      };
      case (#differenceResolved(x)) {
        switch (session(s, x.session)) { case (?r) ignore RI.put(s.sessions, R.key(x.session, 8), encodeSession({ r with resolvedBlock = block; resolved = true })); case null {} };
      };
      case (#cashTaken(x)) { tillAdjust(s, x.till, x.tendered, true); tillAdjust(s, x.till, x.change, false) };
      case (#cashPaid(x)) tillAdjust(s, x.till, x.paid, false);
      case (#vaultToTill(x)) { tillAdjust(s, x.till, x.denominations, true); vaultAdjust(s, x.book, x.currency, x.denominations, false) };
      case (#tillToVault(x)) { tillAdjust(s, x.till, x.denominations, false); vaultAdjust(s, x.book, x.currency, x.denominations, true) };
      case (#cashDispatched(x)) {
        ignore RI.put(s.movements, R.key(block, 8), encodeMovement({ product = x.product; fromBook = x.fromBook; toBook = x.toBook; currency = x.currency; amount = x.amount; inTransit = true; dispatchedBlock = block; receivedBlock = 0 }));
        holdSub(s, transitSub(block));
        s.movementsDispatched += 1; s.movementsInTransit += 1;
      };
      case (#cashReceived(x)) {
        switch (movement(s, x.movement)) { case (?m) { if (m.inTransit and s.movementsInTransit > 0) s.movementsInTransit -= 1; ignore RI.put(s.movements, R.key(x.movement, 8), encodeMovement({ m with inTransit = false; receivedBlock = block })) }; case null {} };
      };
      case (#vaultToCentralBank(_) or #centralBankToVault(_)) {};
      case (#chequebookIssued(x)) ignore RI.put(s.chequebooks, R.key2(x.account, 8, x.from, 8), R.key(x.to, 8));
      case (#chequeStopped(x)) ignore RI.put(s.cheques, R.key2(x.account, 8, x.serial, 8), encodeCheque({ state = #stopped; amount = 0; hold = 0; chequeDate = 0; lastBlock = block; reason = null }));
      case (#chequePresented(x)) {
        ignore RI.put(s.cheques, R.key2(x.account, 8, x.serial, 8), encodeCheque({ state = #held; amount = x.amount; hold = x.hold; chequeDate = x.chequeDate; lastBlock = block; reason = null }));
        s.chequesPresented += 1;
      };
      case (#chequeCleared(x)) {
        switch (cheque(s, x.account, x.serial)) { case (?r) ignore RI.put(s.cheques, R.key2(x.account, 8, x.serial, 8), encodeCheque({ r with state = #cleared; lastBlock = block })); case null {} };
      };
      case (#chequeReturned(x)) {
        let r = switch (cheque(s, x.account, x.serial)) { case (?r) r; case null { { state = #unused; amount = x.amount; hold = 0; chequeDate = 0; lastBlock = block; reason = null } } };
        ignore RI.put(s.cheques, R.key2(x.account, 8, x.serial, 8), encodeCheque({ r with state = #returned; amount = x.amount; lastBlock = block; reason = ?x.reason }));
        s.chequesReturned += 1;
      };
      case (#draftIssued(x)) {
        ignore RI.put(s.drafts, draftKey(x.serial), encodeDraft({ state = #outstanding; amount = x.amount; currency = x.currency; issuedBlock = block; lastBlock = block; serialHash = Sha256.fromBlob(#sha256, Text.encodeUtf8(x.serial)) }));
        holdSub(s, draftSub(x.serial));
        s.draftsIssued += 1;
      };
      case (#draftPaid(x)) { switch (draft(s, x.serial)) { case (?r) ignore RI.put(s.drafts, draftKey(x.serial), encodeDraft({ r with state = #paid; lastBlock = block })); case null {} } };
      case (#draftCancelled(x)) { switch (draft(s, x.serial)) { case (?r) ignore RI.put(s.drafts, draftKey(x.serial), encodeDraft({ r with state = #cancelled; lastBlock = block })); case null {} } };
    };
    // the vault's denomination position follows the cash network's acts
    switch (e) {
      case (#cashDispatched(x)) vaultAdjust(s, x.fromBook, x.currency, x.denominations, false);
      case (#cashReceived(x)) { switch (movement(s, x.movement)) { case (?m) vaultAdjust(s, m.toBook, m.currency, x.denominations, true); case null {} } };
      case (#vaultToCentralBank(x)) vaultAdjust(s, x.book, x.currency, x.denominations, false);
      case (#centralBankToVault(x)) vaultAdjust(s, x.book, x.currency, x.denominations, true);
      case (_) {};
    };
  };

  // ─── reads ────────────────────────────────────────────────────────────────

  public func sessionView(s : State, id : TT.SessionId) : ?TT.SessionView {
    let ?r = session(s, id) else return null;
    ?{ id; till = r.till; teller = r.teller; openedBlock = r.openedBlock; closedBlock = if (r.closed) ?r.closedBlock else null; openingCounted = r.openingCounted; openingBook = r.openingBook;
       closingCounted = if (r.closed) ?r.closingCounted else null; closingBook = if (r.closed) ?r.closingBook else null; difference = if (r.closed) ?r.difference else null;
       resolvedBlock = if (r.resolved) ?r.resolvedBlock else null; day = r.day }
  };
  /// The till's most recent session, open or closed: the highest session id the till's rows carry.
  public func lastSessionOf(s : State, till : Text) : ?TT.SessionView {
    var best : ?TT.SessionView = null;
    let (lo, hi) = R.fullRange(8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.sessions, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) {
        let r = decodeSession(v);
        if (Text.equal(r.till, till)) { switch (sessionView(s, R.getNat(Blob.toArray(k), 0, 8))) { case (?sv) best := ?sv; case null {} } };
      };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    best
  };
  public func chequeView(s : State, account : Nat, serial : Nat) : ?TT.ChequeView {
    if (chequebookOf(s, account, serial) == null) return null;
    switch (cheque(s, account, serial)) {
      case (?r) ?{ account; serial; state = r.state; amount = r.amount; hold = if (r.hold == 0) null else ?r.hold; chequeDate = if (r.chequeDate == 0) null else ?r.chequeDate; lastBlock = r.lastBlock; reason = r.reason };
      case null ?{ account; serial; state = #unused; amount = 0; hold = null; chequeDate = null; lastBlock = 0; reason = null };
    }
  };
  public func draftView(s : State, serial : Text) : ?TT.DraftView {
    let ?r = draft(s, serial) else return null;
    ?{ serial; state = r.state; amount = r.amount; currency = r.currency; issuedBlock = r.issuedBlock; lastBlock = r.lastBlock }
  };
  public func movementView(s : State, id : TT.MovementId) : ?TT.MovementView {
    let ?m = movement(s, id) else return null;
    ?{ id; product = m.product; fromBook = m.fromBook; toBook = m.toBook; currency = m.currency; amount = m.amount; inTransit = m.inTransit; dispatchedBlock = m.dispatchedBlock; receivedBlock = if (m.inTransit) null else ?m.receivedBlock }
  };
  /// Every movement still in transit, bounded by the rows.
  public func inTransitCount(s : State) : Nat { s.movementsInTransit };
  /// One page of the movements still in transit, off the movement store from a cursor: `limit` bounds the rows examined.
  public func inTransitFrom(s : State, cursor : ?Blob, limit : Nat) : { rows : [TT.MovementView]; cursor : ?Blob } {
    let out = List.empty<TT.MovementView>();
    let (lo, hi) = R.fullRange(8);
    let page = RI.range(s.movements, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    for ((k, v) in page.entries.vals()) { let m = decodeMovement(v); if (m.inTransit) { switch (movementView(s, R.getNat(Blob.toArray(k), 0, 8))) { case (?mv) List.add(out, mv); case null {} } } };
    { rows = List.toArray(out); cursor = page.cursor }
  };
  public func inTransit(s : State) : [TT.MovementView] {
    let out = List.empty<TT.MovementView>();
    let (lo, hi) = R.fullRange(8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.movements, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) { let m = decodeMovement(v); if (m.inTransit) { switch (movementView(s, R.getNat(Blob.toArray(k), 0, 8))) { case (?mv) List.add(out, mv); case null {} } } };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  public func counts(s : State) : { sessions : Nat; differences : Nat; movements : Nat; chequesPresented : Nat; chequesReturned : Nat; drafts : Nat } {
    { sessions = s.sessionsOpened; differences = s.differences; movements = s.movementsDispatched; chequesPresented = s.chequesPresented; chequesReturned = s.chequesReturned; drafts = s.draftsIssued }
  };

  // ─── fingerprint ──────────────────────────────────────────────────────────

  /// One index into the fingerprint: its size and its row digest (`RegionIndex` improvement 5; the sum of the
  /// rows' hashes, maintained at every `put`), in place of a walk of every row: two states holding the same rows
  /// write the same words, and the cost is one word an index whatever the book's size.
  func fingerprintRows(w : C.Writer, idx : RI.State) { w.nat(RI.size(idx)); w.blobRaw(RI.digest(idx)) };
  public func fingerprintInto(w : C.Writer, s : State) {
    switch (s.policy) {
      case null w.byte(0);
      case (?p) { w.byte(1); w.text(p.overShort); w.text(p.cashInTransit); w.text(p.centralBank); w.text(p.draftsPayable); w.text(p.clearing); w.nat(p.staleDays); w.nat(p.clearingWindowDays) };
    };
    w.nat(s.sessionsOpened); w.nat(s.differences); w.nat(s.movementsDispatched); w.nat(s.movementsInTransit); w.nat(s.chequesPresented); w.nat(s.chequesReturned); w.nat(s.draftsIssued);
    fingerprintRows(w, s.sessions); fingerprintRows(w, s.openSession); fingerprintRows(w, s.tillDenoms); fingerprintRows(w, s.vaultDenoms);
    fingerprintRows(w, s.movements); fingerprintRows(w, s.chequebooks); fingerprintRows(w, s.cheques); fingerprintRows(w, s.drafts); fingerprintRows(w, s.subledgers);
  };
}
