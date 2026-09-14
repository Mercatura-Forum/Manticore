/// SettlementCore.mo: the fold and the planners of settlement: schemes, participants, transfers,
/// windows, settlements and bulks, on the bank's book.
///
/// Shape rule, as everywhere in this layer: the block is the record, a fixed-width row carries the
/// mutable facts. Schemes, participants, windows and settlements are bounded by recorded acts and
/// are heap maps; transfers and bulks grow with payments and are rows in stable memory, their
/// records in their blocks (`Blocks`). The window's transfers are an index `window(8) ‖
/// transfer(8)`, which is what the netting fold walks, in chunks; a scheme reference is deduplicated
/// through `references` (sha256 of scheme ‖ reference → transfer).

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";

import ST "SettlementTypes";
import R "StableRows";

module {

  public type Blocks = { get : Nat -> ?ST.SettlementEvent };

  /// `state(1) ‖ payer(8) ‖ payee(8) ‖ amount(16) ‖ ccyOrd(2) ‖ schemeOrd(2) ‖ reservation(8) ‖ posting(8) ‖ window(8) ‖ bulk(8) ‖ expiresAt(8) ‖ lastBlock(8)`; 85 bytes.
  /// Zero for "none" in the optional block fields: block 0 is the bank's genesis and never a payment's.
  public let TRANSFER_ROW : Nat = 85;
  /// `state(1) ‖ processing(1) ‖ payer(8) ‖ items(4) ‖ prepared(4) ‖ done(4) ‖ failures(4) ‖ lastBlock(8)`; 34 bytes.
  public let BULK_ROW : Nat = 34;

  public type State = {
    schemes : Map.Map<ST.SchemeId, ST.Scheme>;
    schemeOrd : Map.Map<ST.SchemeId, Nat>;
    schemeName : Map.Map<Nat, ST.SchemeId>;
    currencyOrd : Map.Map<Text, Nat>;
    currencyName : Map.Map<Nat, Text>;
    participants : Map.Map<ST.ParticipantId, ST.Participant>;
    /// (party, scheme) -> participant, so a party is one participant per scheme.
    participantByParty : Map.Map<(Nat, ST.SchemeId), ST.ParticipantId>;
    /// (scheme, BIC) → participant: how an ISO 20022 agent names a participant.
    participantByBic : Map.Map<(ST.SchemeId, Text), ST.ParticipantId>;
    windows : Map.Map<ST.WindowId, ST.Window>;
    /// (scheme, businessDate) -> the open window, at most one.
    openWindows : Map.Map<(ST.SchemeId, Nat), ST.WindowId>;
    settlements : Map.Map<ST.SettlementId, ST.Settlement>;
    transferRows : RI.State;        // transfer(8) -> TRANSFER_ROW
    windowTransfers : RI.State;     // window(8) ‖ transfer(8) -> "" (a membership row)
    references : RI.State;          // sha256(scheme ‖ reference)(32) -> transfer(8)
    bulkRows : RI.State;            // bulk(8) -> BULK_ROW
    bulkTransfers : RI.State;       // bulk(8) ‖ transfer(8) -> "" (a membership row)
    var transferCount : Nat;
    var bulkCount : Nat;
    var byState : [var Nat];        // transfers per state, for the matrix
  };

  public func newState(arena : RI.Arena) : State {
    {
      schemes = Map.empty<ST.SchemeId, ST.Scheme>();
      schemeOrd = Map.empty<ST.SchemeId, Nat>();
      schemeName = Map.empty<Nat, ST.SchemeId>();
      currencyOrd = Map.empty<Text, Nat>();
      currencyName = Map.empty<Nat, Text>();
      participants = Map.empty<ST.ParticipantId, ST.Participant>();
      participantByParty = Map.empty<(Nat, ST.SchemeId), ST.ParticipantId>();
      participantByBic = Map.empty<(ST.SchemeId, Text), ST.ParticipantId>();
      windows = Map.empty<ST.WindowId, ST.Window>();
      openWindows = Map.empty<(ST.SchemeId, Nat), ST.WindowId>();
      settlements = Map.empty<ST.SettlementId, ST.Settlement>();
      transferRows = RI.newStateIn(arena, { keyBytes = 8; valBytes = TRANSFER_ROW });
      windowTransfers = RI.newStateIn(arena, { keyBytes = 16; valBytes = 0 });
      references = RI.newStateIn(arena, { keyBytes = 32; valBytes = 8 });
      bulkRows = RI.newStateIn(arena, { keyBytes = 8; valBytes = BULK_ROW });
      bulkTransfers = RI.newStateIn(arena, { keyBytes = 16; valBytes = 0 });
      var transferCount = 0;
      var bulkCount = 0;
      var byState = Array.repeat<Nat>(0, 16) |> Array.toVarArray<Nat>(_);
    }
  };

  func cmpPS(a : (Nat, Text), b : (Nat, Text)) : { #less; #equal; #greater } { switch (Nat.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o } };
  func cmpSD(a : (Text, Nat), b : (Text, Nat)) : { #less; #equal; #greater } { switch (Text.compare(a.0, b.0)) { case (#equal) Nat.compare(a.1, b.1); case (o) o } };
  func cmpTT(a : (Text, Text), b : (Text, Text)) : { #less; #equal; #greater } { switch (Text.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o } };

  func ordinal(ords : Map.Map<Text, Nat>, names : Map.Map<Nat, Text>, t : Text) : Nat {
    switch (Map.get(ords, Text.compare, t)) { case (?o) o; case null { let o = Map.size(ords) + 1; Map.add(ords, Text.compare, t, o); Map.add(names, Nat.compare, o, t); o } }
  };
  func nameOf(names : Map.Map<Nat, Text>, o : Nat) : Text { switch (Map.get(names, Nat.compare, o)) { case (?t) t; case null Runtime.trap("SettlementCore: an ordinal with no name") } };

  // ─── transfer rows ────────────────────────────────────────────────────────

  type TransferRow = { state : ST.TransferState; payer : Nat; payee : Nat; amount : Nat; ccyOrd : Nat; schemeOrd : Nat; reservation : Nat; posting : Nat; window : Nat; bulk : Nat; expiresAt : Nat64; lastBlock : Nat };

  func stateByte(s : ST.TransferState) : Nat8 {
    switch (s) {
      case (#receivedPrepare) 0; case (#reserved) 1; case (#receivedFulfil) 2; case (#committed) 3; case (#failed) 4; case (#reservedTimeout) 5;
      case (#receivedReject) 6; case (#abortedRejected) 7; case (#receivedError) 8; case (#abortedError) 9; case (#expiredPrepared) 10;
      case (#expiredReserved) 11; case (#invalid) 12; case (#reservedForwarded) 13; case (#receivedFulfilDependent) 14; case (#settled) 15;
    }
  };
  func stateOfByte(b : Nat8) : ST.TransferState {
    switch (b) {
      case 0 #receivedPrepare; case 1 #reserved; case 2 #receivedFulfil; case 3 #committed; case 4 #failed; case 5 #reservedTimeout;
      case 6 #receivedReject; case 7 #abortedRejected; case 8 #receivedError; case 9 #abortedError; case 10 #expiredPrepared;
      case 11 #expiredReserved; case 12 #invalid; case 13 #reservedForwarded; case 14 #receivedFulfilDependent; case _ #settled;
    }
  };
  func encodeTransfer(r : TransferRow) : Blob {
    let b = R.buf();
    R.putByte(b, stateByte(r.state)); R.putNat(b, r.payer, 8); R.putNat(b, r.payee, 8); R.putNat(b, r.amount, 16); R.putNat(b, r.ccyOrd, 2); R.putNat(b, r.schemeOrd, 2);
    R.putNat(b, r.reservation, 8); R.putNat(b, r.posting, 8); R.putNat(b, r.window, 8); R.putNat(b, r.bulk, 8); R.putNat(b, Nat64.toNat(r.expiresAt), 8); R.putNat(b, r.lastBlock, 8);
    R.done(b, TRANSFER_ROW)
  };
  func decodeTransfer(v : Blob) : TransferRow {
    let a = Blob.toArray(v);
    { state = stateOfByte(a[0]); payer = R.getNat(a, 1, 8); payee = R.getNat(a, 9, 8); amount = R.getNat(a, 17, 16); ccyOrd = R.getNat(a, 33, 2); schemeOrd = R.getNat(a, 35, 2);
      reservation = R.getNat(a, 37, 8); posting = R.getNat(a, 45, 8); window = R.getNat(a, 53, 8); bulk = R.getNat(a, 61, 8); expiresAt = Nat64.fromNat(R.getNat(a, 69, 8)); lastBlock = R.getNat(a, 77, 8) }
  };
  func transferRow(s : State, id : ST.TransferId) : ?TransferRow { switch (RI.get(s.transferRows, R.key(id, 8))) { case (?v) ?decodeTransfer(v); case null null } };
  func putTransferRow(s : State, id : ST.TransferId, r : TransferRow) { ignore RI.put(s.transferRows, R.key(id, 8), encodeTransfer(r)) };

  func referenceKey(scheme : ST.SchemeId, reference : Text) : Blob {
    let w = C.Writer(); w.text(scheme); w.text(reference);
    Sha256.fromBlob(#sha256, w.toBlob())
  };

  /// A transfer as the reads see it: the row and its block.
  public func transfer(s : State, bb : Blocks, id : ST.TransferId) : ?ST.Transfer {
    let ?r = transferRow(s, id) else return null;
    let ?(#transferPrepared(p)) = bb.get(id) else return null;
    ?{
      id; scheme = p.scheme; payer = r.payer; payee = r.payee; currency = nameOf(s.currencyName, r.ccyOrd); amount = r.amount; reference = p.reference;
      state = r.state; reservation = if (r.reservation == 0) null else ?r.reservation; posting = if (r.posting == 0) null else ?r.posting;
      window = if (r.window == 0) null else ?r.window; bulk = if (r.bulk == 0) null else ?r.bulk; correctionOf = p.correctionOf; expiresAt = r.expiresAt; lastBlock = r.lastBlock;
    }
  };

  public func transferByReference(s : State, scheme : ST.SchemeId, reference : Text) : ?ST.TransferId {
    switch (RI.get(s.references, referenceKey(scheme, reference))) { case (?v) ?R.getNat(Blob.toArray(v), 0, 8); case null null }
  };

  // ─── bulk rows ────────────────────────────────────────────────────────────

  type BulkRow = { state : ST.BulkState; processing : ST.BulkProcessingState; payer : Nat; items : Nat; prepared : Nat; done : Nat; failures : Nat; lastBlock : Nat };
  func bulkByte(s : ST.BulkState) : Nat8 {
    switch (s) { case (#received) 0; case (#pendingPrepare) 1; case (#accepted) 2; case (#processing) 3; case (#pendingFulfil) 4; case (#completed) 5; case (#rejected) 6; case (#invalid) 7; case (#expired) 8; case (#aborting) 9; case (#expiring) 10; case (#pendingInvalid) 11 }
  };
  func bulkOfByte(b : Nat8) : ST.BulkState {
    switch (b) { case 0 #received; case 1 #pendingPrepare; case 2 #accepted; case 3 #processing; case 4 #pendingFulfil; case 5 #completed; case 6 #rejected; case 7 #invalid; case 8 #expired; case 9 #aborting; case 10 #expiring; case _ #pendingInvalid }
  };
  func procByte(s : ST.BulkProcessingState) : Nat8 {
    switch (s) { case (#received) 0; case (#receivedDuplicate) 1; case (#receivedInvalid) 2; case (#accepted) 3; case (#processing) 4; case (#fulfilDuplicate) 5; case (#fulfilInvalid) 6; case (#completed) 7; case (#rejected) 8; case (#expired) 9; case (#aborting) 10 }
  };
  func procOfByte(b : Nat8) : ST.BulkProcessingState {
    switch (b) { case 0 #received; case 1 #receivedDuplicate; case 2 #receivedInvalid; case 3 #accepted; case 4 #processing; case 5 #fulfilDuplicate; case 6 #fulfilInvalid; case 7 #completed; case 8 #rejected; case 9 #expired; case _ #aborting }
  };
  func encodeBulk(r : BulkRow) : Blob {
    let b = R.buf();
    R.putByte(b, bulkByte(r.state)); R.putByte(b, procByte(r.processing)); R.putNat(b, r.payer, 8); R.putNat(b, r.items, 4); R.putNat(b, r.prepared, 4); R.putNat(b, r.done, 4); R.putNat(b, r.failures, 4); R.putNat(b, r.lastBlock, 8);
    R.done(b, BULK_ROW)
  };
  func decodeBulk(v : Blob) : BulkRow {
    let a = Blob.toArray(v);
    { state = bulkOfByte(a[0]); processing = procOfByte(a[1]); payer = R.getNat(a, 2, 8); items = R.getNat(a, 10, 4); prepared = R.getNat(a, 14, 4); done = R.getNat(a, 18, 4); failures = R.getNat(a, 22, 4); lastBlock = R.getNat(a, 26, 8) }
  };
  func bulkRow(s : State, id : ST.BulkId) : ?BulkRow { switch (RI.get(s.bulkRows, R.key(id, 8))) { case (?v) ?decodeBulk(v); case null null } };

  /// A bulk as the reads see it: the row, its block, and the latest state block's failures.
  public func bulk(s : State, bb : Blocks, id : ST.BulkId) : ?ST.Bulk {
    let ?r = bulkRow(s, id) else return null;
    let ?(#bulkReceived(b)) = bb.get(id) else return null;
    let failures : [(Nat, Text)] = if (r.lastBlock == id) [] else { switch (bb.get(r.lastBlock)) { case (?(#bulkStateChanged(x))) x.failures; case (_) [] } };
    ?{ id; scheme = b.scheme; payer = b.payer; reference = b.reference; ttlSeconds = b.ttlSeconds; state = r.state; processing = r.processing; requests = b.requests; prepared = r.prepared; done = r.done; failures; lastBlock = r.lastBlock }
  };

  // ─── reads ────────────────────────────────────────────────────────────────

  public func scheme(s : State, id : ST.SchemeId) : ?ST.Scheme { Map.get(s.schemes, Text.compare, id) };
  public func schemes(s : State) : [ST.Scheme] { Array.map<(Text, ST.Scheme), ST.Scheme>(Map.toArray(s.schemes), func((_, x)) { x }) };
  public func participant(s : State, id : ST.ParticipantId) : ?ST.Participant { Map.get(s.participants, Nat.compare, id) };
  public func participants(s : State) : [ST.Participant] { Array.map<(Nat, ST.Participant), ST.Participant>(Map.toArray(s.participants), func((_, x)) { x }) };
  public func participantOfParty(s : State, party : Nat, schemeId : ST.SchemeId) : ?ST.ParticipantId { Map.get(s.participantByParty, cmpPS, (party, schemeId)) };
  /// The participant an agent BIC names in a scheme; an 11-character BIC also answers for its 8-character head when no branch-specific participant exists.
  public func participantOfBic(s : State, schemeId : ST.SchemeId, bic : Text) : ?ST.ParticipantId {
    switch (Map.get(s.participantByBic, cmpTT, (schemeId, bic))) {
      case (?p) ?p;
      case null {
        if (Text.size(bic) == 11) { let cs = Text.toArray(bic); let head = Text.fromIter(Array.tabulate<Char>(8, func(i) { cs[i] }).vals()); Map.get(s.participantByBic, cmpTT, (schemeId, head)) } else null
      };
    }
  };
  public func accountsIn(p : ST.Participant, currency : Text) : ?ST.ParticipantAccounts { for (a in p.accounts.vals()) { if (Text.equal(a.currency, currency)) return ?a }; null };
  public func window(s : State, id : ST.WindowId) : ?ST.Window { Map.get(s.windows, Nat.compare, id) };
  /// One page of the windows, by id from a cursor (inclusive); `next` is the id to resume at.
  public func windowsFrom(s : State, cursor : ?Nat, limit : Nat) : { rows : [ST.Window]; next : ?Nat } {
    let rows = List.empty<ST.Window>();
    let it = switch (cursor) { case (?c) Map.entriesFrom(s.windows, Nat.compare, c); case null Map.entries(s.windows) };
    for ((k, x) in it) { if (List.size(rows) >= limit) return { rows = List.toArray(rows); next = ?k }; List.add(rows, x) };
    { rows = List.toArray(rows); next = null }
  };
  public func windowCount(s : State) : Nat { Map.size(s.windows) };
  /// One page of the settlements, by id from a cursor (inclusive); `next` is the id to resume at.
  public func settlementsFrom(s : State, cursor : ?Nat, limit : Nat) : { rows : [ST.Settlement]; next : ?Nat } {
    let rows = List.empty<ST.Settlement>();
    let it = switch (cursor) { case (?c) Map.entriesFrom(s.settlements, Nat.compare, c); case null Map.entries(s.settlements) };
    for ((k, x) in it) { if (List.size(rows) >= limit) return { rows = List.toArray(rows); next = ?k }; List.add(rows, x) };
    { rows = List.toArray(rows); next = null }
  };
  public func settlementCount(s : State) : Nat { Map.size(s.settlements) };
  /// One page of the participants, by id from a cursor (inclusive); `next` is the id to resume at.
  public func participantsFrom(s : State, cursor : ?Nat, limit : Nat) : { rows : [ST.Participant]; next : ?Nat } {
    let rows = List.empty<ST.Participant>();
    let it = switch (cursor) { case (?c) Map.entriesFrom(s.participants, Nat.compare, c); case null Map.entries(s.participants) };
    for ((k, x) in it) { if (List.size(rows) >= limit) return { rows = List.toArray(rows); next = ?k }; List.add(rows, x) };
    { rows = List.toArray(rows); next = null }
  };
  public func participantCount(s : State) : Nat { Map.size(s.participants) };
  public func windows(s : State) : [ST.Window] { Array.map<(Nat, ST.Window), ST.Window>(Map.toArray(s.windows), func((_, x)) { x }) };
  public func openWindow(s : State, schemeId : ST.SchemeId, businessDate : Nat) : ?ST.WindowId { Map.get(s.openWindows, cmpSD, (schemeId, businessDate)) };
  public func settlement(s : State, id : ST.SettlementId) : ?ST.Settlement { Map.get(s.settlements, Nat.compare, id) };
  public func settlements(s : State) : [ST.Settlement] { Array.map<(Nat, ST.Settlement), ST.Settlement>(Map.toArray(s.settlements), func((_, x)) { x }) };

  /// The transfers of a window, by id, paged by cursor: what the netting fold and the reads walk.
  public func windowTransferIds(s : State, w : ST.WindowId, cursor : ?Nat, limit : Nat) : { ids : [Nat]; next : ?Nat } {
    let (lo, hi) = R.prefixRange(w, 8, 8);
    let start = switch (cursor) { case (?c) ?R.key2(w, 8, c, 8); case null null };
    let page = RI.range(s.windowTransfers, lo, hi, start, Nat.max(1, limit));
    let ids = Array.map<(Blob, Blob), Nat>(page.entries, func((k, _)) { R.getNat(Blob.toArray(k), 8, 8) });
    { ids; next = switch (page.cursor) { case (?c) ?R.getNat(Blob.toArray(c), 8, 8); case null null } }
  };

  public func counts(s : State) : { schemes : Nat; participants : Nat; transfers : Nat; windows : Nat; settlements : Nat; bulks : Nat; byState : [(Text, Nat)] } {
    let names = ["RECEIVED_PREPARE", "RESERVED", "RECEIVED_FULFIL", "COMMITTED", "FAILED", "RESERVED_TIMEOUT", "RECEIVED_REJECT", "ABORTED_REJECTED", "RECEIVED_ERROR", "ABORTED_ERROR", "EXPIRED_PREPARED", "EXPIRED_RESERVED", "INVALID", "RESERVED_FORWARDED", "RECEIVED_FULFIL_DEPENDENT", "SETTLED"];
    { schemes = Map.size(s.schemes); participants = Map.size(s.participants); transfers = s.transferCount; windows = Map.size(s.windows); settlements = Map.size(s.settlements); bulks = s.bulkCount;
      byState = Array.tabulate<(Text, Nat)>(16, func(i) { (names[i], s.byState[i]) }) }
  };

  // ─── planners: schemes and participants ──────────────────────────────────

  public func planDeclareScheme(s : State, x : { id : ST.SchemeId; granularity : ST.Granularity; interchange : ST.Interchange; delay : ST.Delay; reconciliation : Text; feeIncome : Text; interchangeBps : Nat; hubFeeBps : Nat; alarmPercent : Nat }) : Result.Result<ST.SettlementEvent, ST.SettlementError> {
    if (Text.size(x.id) == 0 or Text.encodeUtf8(x.id).size() > 32) return #err(#InvalidScheme({ reason = "a scheme id is 1..32 bytes" }));
    if (Map.containsKey(s.schemes, Text.compare, x.id)) return #err(#SchemeExists({ scheme = x.id }));
    if (x.interchangeBps > 10_000 or x.hubFeeBps > 10_000) return #err(#InvalidScheme({ reason = "a fee is at most 10,000 basis points" }));
    if (x.alarmPercent == 0 or x.alarmPercent > 100) return #err(#InvalidScheme({ reason = "the alarm is 1..100 percent of the cap" }));
    #ok(#schemeDeclared({ id = x.id; granularity = x.granularity; interchange = x.interchange; delay = x.delay; reconciliation = x.reconciliation; feeIncome = x.feeIncome; interchangeBps = x.interchangeBps; hubFeeBps = x.hubFeeBps; alarmPercent = x.alarmPercent }))
  };

  public func planRegisterParticipant(s : State, party : Nat, bic : Text, schemeId : ST.SchemeId, accounts : [ST.ParticipantAccounts]) : Result.Result<ST.SettlementEvent, ST.SettlementError> {
    let ?_ = scheme(s, schemeId) else return #err(#UnknownScheme({ scheme = schemeId }));
    if (not ST.validBic(bic)) return #err(#InvalidParticipant({ reason = "a BIC is 8 or 11 characters" }));
    if (Map.containsKey(s.participantByParty, cmpPS, (party, schemeId))) return #err(#ParticipantExists({ party; scheme = schemeId }));
    if (Map.containsKey(s.participantByBic, cmpTT, (schemeId, bic))) return #err(#InvalidParticipant({ reason = "BIC " # bic # " is already a participant of the scheme" }));
    if (accounts.size() == 0) return #err(#InvalidParticipant({ reason = "a participant has accounts in at least one currency" }));
    var i = 0;
    while (i < accounts.size()) {
      var j = i + 1;
      while (j < accounts.size()) { if (Text.equal(accounts[i].currency, accounts[j].currency)) return #err(#InvalidParticipant({ reason = "one set of accounts per currency" })); j += 1 };
      let a = accounts[i];
      if (a.position == a.settlement or a.position == a.feeReceivable or a.settlement == a.feeReceivable) return #err(#InvalidParticipant({ reason = "the three accounts of a currency are distinct" }));
      i += 1;
    };
    #ok(#participantRegistered({ party; bic; scheme = schemeId; accounts }))
  };

  public func planDeactivateParticipant(s : State, id : ST.ParticipantId) : Result.Result<ST.SettlementEvent, ST.SettlementError> {
    let ?p = participant(s, id) else return #err(#UnknownParticipant({ participant = id }));
    if (not p.active) return #err(#ParticipantInactive({ participant = id }));
    #ok(#participantDeactivated({ participant = id }))
  };

  /// The participant and its accounts in a currency, active.
  public func activeAccounts(s : State, id : ST.ParticipantId, currency : Text) : Result.Result<(ST.Participant, ST.ParticipantAccounts), ST.SettlementError> {
    let ?p = participant(s, id) else return #err(#UnknownParticipant({ participant = id }));
    if (not p.active) return #err(#ParticipantInactive({ participant = id }));
    let ?a = accountsIn(p, currency) else return #err(#NoAccountsIn({ participant = id; currency }));
    #ok((p, a))
  };

  // ─── planners: transfers ─────────────────────────────────────────────────

  public func planPrepare(s : State, schemeId : ST.SchemeId, payer : ST.ParticipantId, payee : ST.ParticipantId, currency : Text, amount : Nat, reference : Text, expiresAt : Nat64, bulkId : ?ST.BulkId) : Result.Result<ST.SettlementEvent, ST.SettlementError> {
    planPrepareLinked(s, schemeId, payer, payee, currency, amount, reference, expiresAt, bulkId, null)
  };

  /// A prepare that may carry the journal link of a return (`correctionOf` = the original posting).
  public func planPrepareLinked(s : State, schemeId : ST.SchemeId, payer : ST.ParticipantId, payee : ST.ParticipantId, currency : Text, amount : Nat, reference : Text, expiresAt : Nat64, bulkId : ?ST.BulkId, correctionOf : ?Nat) : Result.Result<ST.SettlementEvent, ST.SettlementError> {
    let ?_ = scheme(s, schemeId) else return #err(#UnknownScheme({ scheme = schemeId }));
    if (amount == 0) return #err(#InvalidTransfer({ reason = "a transfer of zero moves nothing" }));
    if (payer == payee) return #err(#InvalidTransfer({ reason = "a participant cannot transfer to itself" }));
    if (Text.size(reference) == 0 or Text.encodeUtf8(reference).size() > ST.MAX_REFERENCE_BYTES) return #err(#InvalidTransfer({ reason = "a reference is 1.." # Nat.toText(ST.MAX_REFERENCE_BYTES) # " bytes" }));
    switch (transferByReference(s, schemeId, reference)) { case (?t) return #err(#DuplicateReference({ reference; transfer = t })); case null {} };
    switch (activeAccounts(s, payer, currency)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (activeAccounts(s, payee, currency)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    #ok(#transferPrepared({ scheme = schemeId; payer; payee; currency; amount; reference; expiresAt; bulk = bulkId; correctionOf }))
  };

  /// The transitions a transfer may make, and from which states: the matrix the tests enumerate.
  public func transition(from : ST.TransferState, to : ST.TransferState) : Bool {
    switch (from, to) {
      case (#receivedPrepare, #reserved) true;
      case (#receivedPrepare, #reservedForwarded) true;
      case (#receivedPrepare, #failed) true;
      case (#reserved, #receivedFulfil) true;
      case (#reserved, #receivedReject) true;
      case (#reserved, #receivedError) true;
      case (#reserved, #reservedTimeout) true;
      case (#reservedForwarded, #receivedFulfilDependent) true;
      case (#reservedForwarded, #receivedFulfil) true;
      case (#reservedForwarded, #receivedReject) true;
      case (#reservedForwarded, #receivedError) true;
      case (#reservedForwarded, #reservedTimeout) true;
      case (#receivedFulfilDependent, #receivedFulfil) true;
      case (#receivedFulfilDependent, #receivedError) true;
      case (#receivedFulfil, #committed) true;
      case (#receivedReject, #abortedRejected) true;
      case (#receivedError, #abortedError) true;
      case (#reservedTimeout, #expiredReserved) true;
      case (#committed, #settled) true;
      case (_, _) false;
    }
  };

  /// The transfer must be in a state from which `to` follows.
  public func requireTransition(s : State, id : ST.TransferId, to : ST.TransferState) : Result.Result<TransferRow, ST.SettlementError> {
    let ?r = transferRow(s, id) else return #err(#UnknownTransfer({ transfer = id }));
    if (not transition(r.state, to)) return #err(#TransferNotIn({ transfer = id; state = ST.transferStateName(r.state); expected = "a state " # ST.transferStateName(to) # " follows" }));
    #ok(r)
  };

  public func transferRowOf(s : State, id : ST.TransferId) : ?{ state : ST.TransferState; payer : Nat; payee : Nat; amount : Nat; currency : Text; scheme : ST.SchemeId; reservation : ?Nat; posting : ?Nat; window : ?Nat; bulk : ?Nat; expiresAt : Nat64 } {
    let ?r = transferRow(s, id) else return null;
    ?{ state = r.state; payer = r.payer; payee = r.payee; amount = r.amount; currency = nameOf(s.currencyName, r.ccyOrd); scheme = nameOf(s.schemeName, r.schemeOrd);
       reservation = if (r.reservation == 0) null else ?r.reservation; posting = if (r.posting == 0) null else ?r.posting; window = if (r.window == 0) null else ?r.window; bulk = if (r.bulk == 0) null else ?r.bulk; expiresAt = r.expiresAt }
  };

  /// Reserved transfers whose deadline has passed, oldest first; what the expiry sweep voids.
  /// Bounded by a walk of the rows from a cursor; a deployment with a million open reservations
  /// walks them a page at a time.
  public func expiredTransfers(s : State, now : Nat64, cursor : ?Nat, limit : Nat) : { ids : [Nat]; next : ?Nat } {
    let (lo, hi) = R.fullRange(8);
    let start = switch (cursor) { case (?c) ?R.key(c, 8); case null null };
    let page = RI.range(s.transferRows, lo, hi, start, Nat.max(1, limit));
    let out = List.empty<Nat>();
    for ((k, v) in page.entries.vals()) {
      let r = decodeTransfer(v);
      switch (r.state) { case (#reserved or #reservedForwarded or #receivedFulfilDependent) { if (r.expiresAt <= now) List.add(out, R.getNat(Blob.toArray(k), 0, 8)) }; case (_) {} };
    };
    { ids = List.toArray(out); next = switch (page.cursor) { case (?c) ?R.getNat(Blob.toArray(c), 0, 8); case null null } }
  };

  // ─── planners: windows and settlements ───────────────────────────────────

  public func planOpenWindow(s : State, schemeId : ST.SchemeId, businessDate : Nat) : Result.Result<ST.SettlementEvent, ST.SettlementError> {
    let ?_ = scheme(s, schemeId) else return #err(#UnknownScheme({ scheme = schemeId }));
    switch (openWindow(s, schemeId, businessDate)) { case (?w) return #err(#WindowNotIn({ window = w; state = "OPEN"; expected = "no open window for the scheme and date" })); case null {} };
    #ok(#windowOpened({ scheme = schemeId; businessDate }))
  };

  public func windowTransition(from : ST.WindowState, to : ST.WindowState) : Bool {
    switch (from, to) {
      case (#open, #closed) true;
      case (#closed, #pendingSettlement) true;
      case (#aborted, #pendingSettlement) true;
      case (#failed, #pendingSettlement) true;
      case (#pendingSettlement, #processing) true;
      case (#pendingSettlement, #aborted) true;
      case (#processing, #settled) true;
      case (#processing, #failed) true;
      case (#processing, #aborted) true;
      case (#failed, #processing) true;
      case (_, _) false;
    }
  };

  public func planWindowTransition(s : State, id : ST.WindowId, to : ST.WindowState, reason : Text) : Result.Result<ST.SettlementEvent, ST.SettlementError> {
    let ?w = window(s, id) else return #err(#UnknownWindow({ window = id }));
    if (not windowTransition(w.state, to)) return #err(#WindowNotIn({ window = id; state = ST.windowStateName(w.state); expected = "a state " # ST.windowStateName(to) # " follows" }));
    #ok(#windowStateChanged({ window = id; to; reason }))
  };

  public func planOpenSettlement(s : State, windowId : ST.WindowId) : Result.Result<ST.SettlementEvent, ST.SettlementError> {
    let ?w = window(s, windowId) else return #err(#UnknownWindow({ window = windowId }));
    switch (w.state) { case (#closed or #aborted or #failed) {}; case (st) return #err(#WindowNotIn({ window = windowId; state = ST.windowStateName(st); expected = "CLOSED, ABORTED or FAILED" })) };
    switch (w.settlement) {
      case (?sid) { switch (settlement(s, sid)) { case (?x) { switch (x.state) { case (#aborted or #settled) {}; case (st) return #err(#SettlementNotIn({ settlement = sid; state = ST.settlementStateName(st); expected = "ABORTED or SETTLED before another settlement" })) } }; case null {} } };
      case null {};
    };
    #ok(#settlementOpened({ window = windowId }))
  };

  public func settlementTransition(from : ST.SettlementState, to : ST.SettlementState) : Bool {
    switch (from, to) {
      case (#pendingSettlement, #psTransfersRecorded) true;
      case (#psTransfersRecorded, #psTransfersReserved) true;
      case (#psTransfersReserved, #psTransfersCommitted) true;
      case (#psTransfersCommitted, #settling) true;
      case (#settling, #settled) true;
      case (#pendingSettlement, #aborted) true;
      case (#psTransfersRecorded, #aborted) true;
      case (#psTransfersReserved, #aborted) true;
      case (#psTransfersCommitted, #aborted) true;
      case (_, _) false;
    }
  };

  public func planSettlementTransition(s : State, id : ST.SettlementId, to : ST.SettlementState, nets : [ST.NetPosition], postings : [Nat], reason : Text) : Result.Result<ST.SettlementEvent, ST.SettlementError> {
    let ?x = settlement(s, id) else return #err(#UnknownSettlement({ settlement = id }));
    if (not settlementTransition(x.state, to)) return #err(#SettlementNotIn({ settlement = id; state = ST.settlementStateName(x.state); expected = "a state " # ST.settlementStateName(to) # " follows" }));
    #ok(#settlementStateChanged({ settlement = id; to; nets; postings; reason }))
  };

  /// INV-P1: the nets of every currency sum to zero. Returns the currency and the sum that break it.
  public func conserved(nets : [ST.NetPosition]) : ?(Text, Int) {
    let sums = Map.empty<Text, Int>();
    for (n in nets.vals()) {
      let cur = switch (Map.get(sums, Text.compare, n.currency)) { case (?v) v; case null 0 };
      Map.add(sums, Text.compare, n.currency, cur + n.credits - n.debits);
    };
    for ((c, v) in Map.entries(sums)) { if (v != 0) return ?(c, v) };
    null
  };

  /// One chunk of the netting fold: the window's transfers from the cursor, their amounts added to
  /// the payer's debits and the payee's credits. Only committed transfers count.
  public func netChunk(s : State, windowId : ST.WindowId, acc : Map.Map<(Nat, Text), { var debits : Nat; var credits : Nat }>, cursor : ?Nat, limit : Nat) : { examined : Nat; next : ?Nat } {
    let page = windowTransferIds(s, windowId, cursor, limit);
    var examined = 0;
    for (id in page.ids.vals()) {
      switch (transferRow(s, id)) {
        case (?r) {
          if (r.state == #committed) {
            let ccy = nameOf(s.currencyName, r.ccyOrd);
            let payer = switch (Map.get(acc, cmpPS, (r.payer, ccy))) { case (?x) x; case null { let x = { var debits = 0; var credits = 0 }; Map.add(acc, cmpPS, (r.payer, ccy), x); x } };
            payer.debits += r.amount;
            let payee = switch (Map.get(acc, cmpPS, (r.payee, ccy))) { case (?x) x; case null { let x = { var debits = 0; var credits = 0 }; Map.add(acc, cmpPS, (r.payee, ccy), x); x } };
            payee.credits += r.amount;
          };
          examined += 1;
        };
        case null {};
      };
    };
    { examined; next = page.next }
  };

  public func netsOf(acc : Map.Map<(Nat, Text), { var debits : Nat; var credits : Nat }>) : [ST.NetPosition] {
    Array.map<((Nat, Text), { var debits : Nat; var credits : Nat }), ST.NetPosition>(Map.toArray(acc), func(((p, c), x)) { { participant = p; currency = c; debits = x.debits; credits = x.credits } })
  };

  // ─── planners: bulks ─────────────────────────────────────────────────────

  public func planReceiveBulk(s : State, schemeId : ST.SchemeId, payer : ST.ParticipantId, reference : Text, items : Nat) : Result.Result<ST.SettlementEvent, ST.SettlementError> {
    let ?_ = scheme(s, schemeId) else return #err(#UnknownScheme({ scheme = schemeId }));
    let ?p = participant(s, payer) else return #err(#UnknownParticipant({ participant = payer }));
    if (not p.active) return #err(#ParticipantInactive({ participant = payer }));
    if (items == 0 or items > ST.MAX_BULK_ITEMS) return #err(#InvalidBulk({ reason = "a bulk has 1.." # Nat.toText(ST.MAX_BULK_ITEMS) # " items" }));
    if (Text.size(reference) == 0 or Text.encodeUtf8(reference).size() > ST.MAX_REFERENCE_BYTES) return #err(#InvalidBulk({ reason = "a reference is 1.." # Nat.toText(ST.MAX_REFERENCE_BYTES) # " bytes" }));
    switch (transferByReference(s, schemeId, "bulk/" # reference)) { case (?t) return #err(#DuplicateReference({ reference; transfer = t })); case null {} };
    #ok(#bulkReceived({ scheme = schemeId; payer; reference; ttlSeconds = 0; requests = [] }))
  };

  public func bulkTransition(from : ST.BulkState, to : ST.BulkState) : Bool {
    switch (from, to) {
      case (#received, #pendingPrepare) true;
      case (#received, #pendingInvalid) true;
      case (#pendingInvalid, #invalid) true;
      case (#pendingPrepare, #accepted) true;
      case (#pendingPrepare, #rejected) true;
      case (#accepted, #processing) true;
      case (#processing, #pendingFulfil) true;
      case (#pendingFulfil, #completed) true;
      case (#pendingFulfil, #rejected) true;
      case (#pendingFulfil, #expiring) true;
      case (#expiring, #expired) true;
      case (#processing, #aborting) true;
      case (#accepted, #aborting) true;
      case (#pendingFulfil, #aborting) true;
      case (#aborting, #rejected) true;
      case (_, _) false;
    }
  };

  public func planBulkTransition(s : State, id : ST.BulkId, to : ST.BulkState, processing : ST.BulkProcessingState, prepared : Nat, done : Nat, failures : [(Nat, Text)]) : Result.Result<ST.SettlementEvent, ST.SettlementError> {
    let ?r = bulkRow(s, id) else return #err(#UnknownBulk({ bulk = id }));
    if (to != r.state and not bulkTransition(r.state, to)) return #err(#BulkNotIn({ bulk = id; state = ST.bulkStateName(r.state); expected = "a state " # ST.bulkStateName(to) # " follows" }));
    #ok(#bulkStateChanged({ bulk = id; to; processing; prepared; done; failures }))
  };

  public func bulkRowOf(s : State, id : ST.BulkId) : ?{ state : ST.BulkState; processing : ST.BulkProcessingState; payer : Nat; items : Nat; prepared : Nat; done : Nat; failures : Nat } {
    switch (bulkRow(s, id)) { case (?r) ?{ state = r.state; processing = r.processing; payer = r.payer; items = r.items; prepared = r.prepared; done = r.done; failures = r.failures }; case null null }
  };

  /// The transfers of a bulk, by the bulk index.
  public func bulkTransferIds(s : State, b : ST.BulkId, cursor : ?Nat, limit : Nat) : { ids : [Nat]; next : ?Nat } {
    let (lo, hi) = R.prefixRange(b, 8, 8);
    let start = switch (cursor) { case (?c) ?R.key2(b, 8, c, 8); case null null };
    let page = RI.range(s.bulkTransfers, lo, hi, start, Nat.max(1, limit));
    { ids = Array.map<(Blob, Blob), Nat>(page.entries, func((k, _)) { R.getNat(Blob.toArray(k), 8, 8) }); next = switch (page.cursor) { case (?c) ?R.getNat(Blob.toArray(c), 8, 8); case null null } }
  };

  // ─── the fold ─────────────────────────────────────────────────────────────

  public func apply(s : State, block : Nat, e : ST.SettlementEvent) {
    switch (e) {
      case (#schemeDeclared(x)) {
        Map.add(s.schemes, Text.compare, x.id, { id = x.id; granularity = x.granularity; interchange = x.interchange; delay = x.delay; reconciliation = x.reconciliation; feeIncome = x.feeIncome; interchangeBps = x.interchangeBps; hubFeeBps = x.hubFeeBps; alarmPercent = x.alarmPercent; declaredAt = block });
        ignore ordinal(s.schemeOrd, s.schemeName, x.id);
      };
      case (#participantRegistered(x)) {
        Map.add(s.participants, Nat.compare, block, { id = block; party = x.party; bic = x.bic; scheme = x.scheme; accounts = x.accounts; active = true });
        Map.add(s.participantByParty, cmpPS, (x.party, x.scheme), block);
        Map.add(s.participantByBic, cmpTT, (x.scheme, x.bic), block);
        for (a in x.accounts.vals()) ignore ordinal(s.currencyOrd, s.currencyName, a.currency);
      };
      case (#participantDeactivated(x)) { switch (participant(s, x.participant)) { case (?p) Map.add(s.participants, Nat.compare, x.participant, { p with active = false }); case null {} } };
      case (#fundsRecorded(_)) {};
      case (#capAlarm(_)) {};
      case (#transferPrepared(x)) {
        putTransferRow(s, block, { state = #receivedPrepare; payer = x.payer; payee = x.payee; amount = x.amount; ccyOrd = ordinal(s.currencyOrd, s.currencyName, x.currency); schemeOrd = ordinal(s.schemeOrd, s.schemeName, x.scheme); reservation = 0; posting = 0; window = 0; bulk = switch (x.bulk) { case (?b) b; case null 0 }; expiresAt = x.expiresAt; lastBlock = block });
        ignore RI.put(s.references, referenceKey(x.scheme, x.reference), R.key(block, 8));
        switch (x.bulk) { case (?b) ignore RI.put(s.bulkTransfers, R.key2(b, 8, block, 8), "" : Blob); case null {} };
        s.transferCount += 1;
        s.byState[0] += 1;
      };
      case (#transferReserved(x)) { move(s, block, x.transfer, [if (x.forwarded) #reservedForwarded else #reserved], func(r) { { r with reservation = x.reservation } }) };
      case (#transferFailed(x)) { move(s, block, x.transfer, [#failed], func(r) { r }) };
      case (#transferFulfilDependent(x)) { move(s, block, x.transfer, [#receivedFulfilDependent], func(r) { r }) };
      case (#transferCommitted(x)) {
        move(s, block, x.transfer, [#receivedFulfil, #committed], func(r) { { r with posting = x.posting; window = x.window } });
        ignore RI.put(s.windowTransfers, R.key2(x.window, 8, x.transfer, 8), "" : Blob);
        switch (window(s, x.window)) { case (?win) Map.add(s.windows, Nat.compare, x.window, { win with transfers = win.transfers + 1 }); case null {} };
      };
      case (#transferAborted(x)) {
        let path : [ST.TransferState] = switch (x.how) { case (#rejected) [#receivedReject, #abortedRejected]; case (#error) [#receivedError, #abortedError]; case (#expired) [#reservedTimeout, #expiredReserved] };
        move(s, block, x.transfer, path, func(r) { r });
      };
      case (#transfersSettled(x)) { for (t in x.transfers.vals()) move(s, block, t, [#settled], func(r) { r }) };
      case (#windowOpened(x)) {
        Map.add(s.windows, Nat.compare, block, { id = block; scheme = x.scheme; businessDate = x.businessDate; state = #open; transfers = 0; settlement = null; lastBlock = block });
        Map.add(s.openWindows, cmpSD, (x.scheme, x.businessDate), block);
      };
      case (#windowStateChanged(x)) {
        switch (window(s, x.window)) {
          case (?w) {
            Map.add(s.windows, Nat.compare, x.window, { w with state = x.to; lastBlock = block });
            // the day's open slot is freed only if this window still holds it: a later window for the
            // same scheme and day may have opened since this one closed
            if (x.to != #open) { switch (Map.get(s.openWindows, cmpSD, (w.scheme, w.businessDate))) { case (?held) { if (held == x.window) ignore Map.delete(s.openWindows, cmpSD, (w.scheme, w.businessDate)) }; case null {} } };
          };
          case null {};
        };
      };
      case (#settlementOpened(x)) {
        Map.add(s.settlements, Nat.compare, block, { id = block; window = x.window; state = #pendingSettlement; nets = []; postings = []; lastBlock = block });
        switch (window(s, x.window)) { case (?w) Map.add(s.windows, Nat.compare, x.window, { w with settlement = ?block; state = #pendingSettlement; lastBlock = block }); case null {} };
      };
      case (#settlementStateChanged(x)) {
        switch (settlement(s, x.settlement)) {
          case (?st) {
            Map.add(s.settlements, Nat.compare, x.settlement, { st with state = x.to; nets = if (x.nets.size() > 0) x.nets else st.nets; postings = if (x.postings.size() > 0) x.postings else st.postings; lastBlock = block });
            // the window follows its settlement's abort in the same block (PENDING_SETTLEMENT or
            // PROCESSING → ABORTED), from where a new settlement may be opened on it
            if (x.to == #aborted) {
              switch (window(s, st.window)) {
                case (?w) { if (windowTransition(w.state, #aborted)) Map.add(s.windows, Nat.compare, st.window, { w with state = #aborted; lastBlock = block }) };
                case null {};
              };
            };
          };
          case null {};
        };
      };
      case (#bulkReceived(x)) {
        ignore RI.put(s.bulkRows, R.key(block, 8), encodeBulk({ state = #received; processing = #received; payer = x.payer; items = x.requests.size(); prepared = 0; done = 0; failures = 0; lastBlock = block }));
        ignore RI.put(s.references, referenceKey(x.scheme, "bulk/" # x.reference), R.key(block, 8));
        s.bulkCount += 1;
      };
      case (#bulkStateChanged(x)) {
        switch (bulkRow(s, x.bulk)) { case (?r) ignore RI.put(s.bulkRows, R.key(x.bulk, 8), encodeBulk({ r with state = x.to; processing = x.processing; prepared = x.prepared; done = x.done; failures = x.failures.size(); lastBlock = block })); case null {} };
      };
    };
  };

  /// A transfer through a path of states, each counted, the row rewritten once.
  func move(s : State, block : Nat, id : ST.TransferId, path : [ST.TransferState], patch : TransferRow -> TransferRow) {
    let ?r = transferRow(s, id) else return;
    var from = r.state;
    for (to in path.vals()) {
      if (not transition(from, to)) Runtime.trap("SettlementCore: transfer " # Nat.toText(id) # " cannot go " # ST.transferStateName(from) # " -> " # ST.transferStateName(to) # " at apply");
      s.byState[Nat8.toNat(stateByte(from))] -= 1;
      s.byState[Nat8.toNat(stateByte(to))] += 1;
      from := to;
    };
    putTransferRow(s, id, { patch(r) with state = from; lastBlock = block });
  };

  public func fingerprintInto(w : C.Writer, s : State) {
    for ((id, x) in Map.entries(s.schemes)) { w.text(id); w.nat(x.interchangeBps); w.nat(x.hubFeeBps); w.nat(x.alarmPercent); w.text(x.reconciliation); w.text(x.feeIncome); w.nat(x.declaredAt) };
    for ((id, p) in Map.entries(s.participants)) { w.nat(id); w.nat(p.party); w.text(p.bic); w.text(p.scheme); w.bool(p.active); for (a in p.accounts.vals()) { w.text(a.currency); w.nat(a.position); w.nat(a.settlement); w.nat(a.feeReceivable) } };
    for ((id, x) in Map.entries(s.windows)) { w.nat(id); w.text(x.scheme); w.nat(x.businessDate); w.text(ST.windowStateName(x.state)); w.nat(x.transfers); w.optNat(x.settlement); w.nat(x.lastBlock) };
    for ((id, x) in Map.entries(s.settlements)) { w.nat(id); w.nat(x.window); w.text(ST.settlementStateName(x.state)); w.nat(x.nets.size()); for (n in x.nets.vals()) { w.nat(n.participant); w.text(n.currency); w.nat(n.debits); w.nat(n.credits) }; w.nat(x.postings.size()); for (p in x.postings.vals()) w.nat(p); w.nat(x.lastBlock) };
    w.nat(s.transferCount); w.nat(s.bulkCount);
    // each index as its size and row digest (`RegionIndex` improvement 5), not a walk of its rows
    for (idx in [s.transferRows, s.bulkRows].vals()) { w.nat(RI.size(idx)); w.blobRaw(RI.digest(idx)) };
  };
}
