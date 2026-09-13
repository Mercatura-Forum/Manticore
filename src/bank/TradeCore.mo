/// TradeCore.mo — the trade book folded from the bank's log in stable memory (trade finance): instruments, the claims
/// under them, the messages exchanged, and the contingent memoranda.
///
/// Rows: one per instrument (keyed by the block that issued, advised, registered or discounted it) with the fixed
/// facts — kind, state, rules, role, party and account, the counterparty's hash and bank, face and utilised,
/// issue day and expiry, margin and commission figures, the hash of the terms in the block; one per claim under an
/// instrument (instrument ‖ ordinal): a presentation of documents, a demand, a collection presented — with its
/// presentation day, the examination deadline counted in banking days from the journal's calendar, the checks
/// recorded and how many failed, how it was honoured and when it fell due; one per message (instrument ‖ ordinal)
/// holding the kind, the direction and the hash. Indexes by party, by state, by expiry (what the batch sweeps),
/// by facility (what counts against a facility's availability), by reference (how an incoming message finds its
/// instrument). The planners are pure over the rows and the calendar: they judge the ICC gates and return the
/// event; the postings are `BankCore`'s.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";
import JT "mo:journal/JournalTypes";

import TrT "TradeTypes";
import Conv "Conventions";
import PT "PartyTypes";
import ProdT "ProductTypes";
import Posting "Posting";
import R "StableRows";
import Map "mo:core/Map";

module {

  public let INSTRUMENT_ROW_BYTES : Nat = 225;
  public let CLAIM_ROW_BYTES : Nat = 83;
  public let MESSAGE_ROW_BYTES : Nat = 48;
  let MAX_PAGE = 512;

  /// Incoterms 2020: the eleven rules.
  public let INCOTERMS : [Text] = ["EXW", "FCA", "CPT", "CIP", "DAP", "DPU", "DDP", "FAS", "FOB", "CFR", "CIF"];

  // ─── keys and codes ───────────────────────────────────────────────────────

  /// The sub-ledger of an instrument's cash margin on the margin-deposits account.
  public func marginSub(id : TrT.InstrumentId) : JT.SubledgerKey { Posting.subledgerOf("trade/margin/" # Nat.toText(id)) };
  /// The sub-ledger of an acceptance (a deferred undertaking) on acceptances payable and on the customer's liability.
  public func acceptanceSub(id : TrT.InstrumentId, claim : TrT.ClaimSeq) : JT.SubledgerKey { Posting.subledgerOf("trade/acceptance/" # Nat.toText(id) # "/" # Nat.toText(claim)) };
  /// The sub-ledger of a bill on bills discounted / negotiated / rediscounted and their unearned discount.
  public func billSub(id : TrT.InstrumentId) : JT.SubledgerKey { Posting.subledgerOf("trade/bill/" # Nat.toText(id)) };
  /// The sub-ledger of an instrument's unearned commission.
  public func commissionSub(id : TrT.InstrumentId) : JT.SubledgerKey { Posting.subledgerOf("trade/commission/" # Nat.toText(id)) };
  public func holdsSubledger(s : State, sub : JT.SubledgerKey) : Bool { sub.size() == 32 and RI.get(s.subledgers, sub) != null };
  func holdSub(s : State, sub : JT.SubledgerKey) { ignore RI.put(s.subledgers, sub, Blob.fromArray([1])) };

  public func hashText(t : Text) : Blob { Sha256.fromBlob(#sha256, Text.encodeUtf8(t)) };
  func refKey(reference : Text) : Blob { R.key(R.getNat(Blob.toArray(hashText(reference)), 0, 8), 8) };
  public func counterpartyHash(c : TrT.Counterparty) : Blob {
    switch (c) { case (#party(p)) hashText("party:" # Nat.toText(p.party) # "/" # Nat.toText(p.account)); case (#external(e)) hashText("external:" # e.name # "|" # e.bic # "|" # e.account) }
  };

  func kindCode(k : TrT.Kind) : Nat8 { switch (k) { case (#letterOfCredit(_)) 1; case (#guarantee(_)) 2; case (#collection(_)) 3; case (#bill(_)) 4 } };
  func kindTextOf(c : Nat8) : Text { switch (c) { case 1 "letterOfCredit"; case 2 "guarantee"; case 3 "collection"; case 4 "bill"; case _ "?" } };
  public func stateCode(s : TrT.InstrumentState) : Nat8 {
    switch (s) {
      case (#issued) 1; case (#advised) 2; case (#confirmed) 3; case (#accepted) 4; case (#paid) 5; case (#expired) 6; case (#released) 7;
      case (#closed) 8; case (#protested) 9; case (#returned) 10; case (#rediscounted) 11; case (#matured) 12; case (#dishonoured) 13;
    }
  };
  func stateOf(c : Nat8) : TrT.InstrumentState {
    switch (c) {
      case 1 #issued; case 2 #advised; case 3 #confirmed; case 4 #accepted; case 5 #paid; case 6 #expired; case 7 #released;
      case 8 #closed; case 9 #protested; case 10 #returned; case 11 #rediscounted; case 12 #matured; case _ #dishonoured;
    }
  };
  func rulesCode(r : TrT.Rules) : Nat8 { switch (r) { case (#UCP600) 1; case (#ISP98) 2; case (#URDG758) 3; case (#URC522) 4 } };
  func rulesOf(c : Nat8) : TrT.Rules { switch (c) { case 1 #UCP600; case 2 #ISP98; case 3 #URDG758; case _ #URC522 } };
  /// The role byte: an LC's role, a guarantee's kind, a collection's role; a bill has none.
  func roleCode(k : TrT.Kind) : Nat8 {
    switch (k) {
      case (#letterOfCredit(lc)) { switch (lc.role) { case (#issuing) 1; case (#advising) 2; case (#confirming) 3 } };
      case (#guarantee(g)) { switch (g.kind) { case (#standby) 4; case (#demandGuarantee) 5; case (#counterGuarantee) 6 } };
      case (#collection(c)) { switch (c.role) { case (#remitting) 7; case (#collecting) 8 } };
      case (#bill(_)) 0;
    }
  };
  func roleText(c : Nat8) : Text {
    switch (c) { case 1 "issuing"; case 2 "advising"; case 3 "confirming"; case 4 "standby"; case 5 "demandGuarantee"; case 6 "counterGuarantee"; case 7 "remitting"; case 8 "collecting"; case _ "" }
  };
  func claimStateCode(s : TrT.ClaimState) : Nat8 {
    switch (s) {
      case (#presented) 1; case (#complying) 2; case (#discrepant) 3; case (#waived) 4; case (#refused) 5;
      case (#honoured) 6; case (#rejected) 7; case (#paid) 8; case (#accepted) 9; case (#withdrawn) 10;
    }
  };
  func claimStateOf(c : Nat8) : TrT.ClaimState {
    switch (c) {
      case 1 #presented; case 2 #complying; case 3 #discrepant; case 4 #waived; case 5 #refused;
      case 6 #honoured; case 7 #rejected; case 8 #paid; case 9 #accepted; case _ #withdrawn;
    }
  };
  func honourCode(h : ?TrT.Honour) : Nat8 { switch (h) { case null 0; case (?#sight) 1; case (?#deferred(_)) 2; case (?#acceptance(_)) 3; case (?#negotiation(_)) 4 } };
  func honourTextOf(c : Nat8) : Text { switch (c) { case 1 "sight"; case 2 "deferred"; case 3 "acceptance"; case 4 "negotiation"; case _ "" } };
  func msgKindCode(k : TrT.MessageKind) : (Nat8, Nat) { switch (k) { case (#mt(n)) (1, n); case (#tsrv(n)) (2, n) } };

  // ─── flags ────────────────────────────────────────────────────────────────
  let F_CONFIRMED : Nat8 = 1;          // we confirmed the credit (advising role) or it was issued confirmed
  let F_RECOURSE : Nat8 = 2;           // a bill bought with recourse
  let F_STATEMENT : Nat8 = 4;          // a URDG guarantee requiring the supporting statement
  let F_DA : Nat8 = 8;                 // a collection on D/A terms
  let CF_STATEMENT : Nat8 = 1;         // a demand carrying its supporting statement

  // ─── rows ─────────────────────────────────────────────────────────────────

  public type InstrumentRow = {
    id : TrT.InstrumentId;
    kind : Nat8; state : TrT.InstrumentState; rules : TrT.Rules; role : Nat8; flags : Nat8;
    party : PT.PartyId; account : ProdT.AccountId; counterpartyHash : Blob; counterpartyBank : Text;
    currency : Text; amount : Nat; utilised : Nat;
    issuedDay : Nat; expiry : Nat; facility : ?Nat;
    marginBps : Nat; margin : Nat;
    commissionBps : Nat; commissionTotal : Nat; commissionEarned : Nat;
    tolerance : Nat; claims : Nat; amendments : Nat; messages : Nat;
    termsHash : Blob; lastBlock : Nat; book : Text;
  };
  public type ClaimRow = {
    instrument : TrT.InstrumentId; seq : TrT.ClaimSeq;
    state : TrT.ClaimState; flags : Nat8; amount : Nat; presentedOn : Nat; deadline : Nat; documentsHash : Blob;
    checksTotal : Nat; checksFailed : Nat; examinedBlock : Nat; honour : Nat8; due : Nat; settledBlock : Nat; claimAccount : ?ProdT.AccountId;
  };
  public type MessageRow = { instrument : TrT.InstrumentId; seq : Nat; kind : Nat8; number : Nat; incoming : Bool; hash : Blob; block : Nat; day : Nat };

  func encodeInstrument(r : InstrumentRow) : Blob {
    let b = R.buf();
    R.putByte(b, r.kind); R.putByte(b, stateCode(r.state)); R.putByte(b, rulesCode(r.rules)); R.putByte(b, r.role); R.putByte(b, r.flags);
    R.putNat(b, r.party, 8); R.putNat(b, r.account, 8); R.putBlob(b, r.counterpartyHash, 32); R.putText(b, r.counterpartyBank, 12);
    R.putText(b, r.currency, 8); R.putNat(b, r.amount, 8); R.putNat(b, r.utilised, 8);
    R.putNat(b, r.issuedDay, 4); R.putNat(b, r.expiry, 4); R.putNat(b, switch (r.facility) { case null 0; case (?f) f + 1 }, 8);
    R.putNat(b, r.marginBps, 4); R.putNat(b, r.margin, 8);
    R.putNat(b, r.commissionBps, 4); R.putNat(b, r.commissionTotal, 8); R.putNat(b, r.commissionEarned, 8);
    R.putNat(b, r.tolerance, 4); R.putNat(b, r.claims, 4); R.putNat(b, r.amendments, 4); R.putNat(b, r.messages, 4);
    R.putBlob(b, r.termsHash, 32); R.putNat(b, r.lastBlock, 8); R.putText(b, r.book, 32);
    R.done(b, INSTRUMENT_ROW_BYTES)
  };
  func decodeInstrument(id : Nat, v : Blob) : InstrumentRow {
    let a = Blob.toArray(v);
    let fac = R.getNat(a, 97, 8);
    {
      id; kind = a[0]; state = stateOf(a[1]); rules = rulesOf(a[2]); role = a[3]; flags = a[4];
      party = R.getNat(a, 5, 8); account = R.getNat(a, 13, 8); counterpartyHash = R.getBlob(a, 21, 32); counterpartyBank = R.getText(a, 53, 12);
      currency = R.getText(a, 65, 8); amount = R.getNat(a, 73, 8); utilised = R.getNat(a, 81, 8);
      issuedDay = R.getNat(a, 89, 4); expiry = R.getNat(a, 93, 4); facility = if (fac == 0) null else ?(fac - 1);
      marginBps = R.getNat(a, 105, 4); margin = R.getNat(a, 109, 8);
      commissionBps = R.getNat(a, 117, 4); commissionTotal = R.getNat(a, 121, 8); commissionEarned = R.getNat(a, 129, 8);
      tolerance = R.getNat(a, 137, 4); claims = R.getNat(a, 141, 4); amendments = R.getNat(a, 145, 4); messages = R.getNat(a, 149, 4);
      termsHash = R.getBlob(a, 153, 32); lastBlock = R.getNat(a, 185, 8); book = R.getText(a, 193, 32);
    }
  };
  func encodeClaim(r : ClaimRow) : Blob {
    let b = R.buf();
    R.putByte(b, claimStateCode(r.state)); R.putByte(b, r.flags); R.putNat(b, r.amount, 8); R.putNat(b, r.presentedOn, 4); R.putNat(b, r.deadline, 4);
    R.putBlob(b, r.documentsHash, 32); R.putNat(b, r.checksTotal, 2); R.putNat(b, r.checksFailed, 2); R.putNat(b, r.examinedBlock, 8);
    R.putByte(b, r.honour); R.putNat(b, r.due, 4); R.putNat(b, r.settledBlock, 8); R.putNat(b, switch (r.claimAccount) { case null 0; case (?x) x + 1 }, 8);
    R.done(b, CLAIM_ROW_BYTES)
  };
  func decodeClaim(instrument : Nat, seq : Nat, v : Blob) : ClaimRow {
    let a = Blob.toArray(v);
    let ca = R.getNat(a, 75, 8);
    {
      instrument; seq; state = claimStateOf(a[0]); flags = a[1]; amount = R.getNat(a, 2, 8); presentedOn = R.getNat(a, 10, 4); deadline = R.getNat(a, 14, 4);
      documentsHash = R.getBlob(a, 18, 32); checksTotal = R.getNat(a, 50, 2); checksFailed = R.getNat(a, 52, 2); examinedBlock = R.getNat(a, 54, 8);
      honour = a[62]; due = R.getNat(a, 63, 4); settledBlock = R.getNat(a, 67, 8); claimAccount = if (ca == 0) null else ?(ca - 1);
    }
  };
  func encodeMessage(r : MessageRow) : Blob {
    let b = R.buf();
    R.putByte(b, r.kind); R.putNat(b, r.number, 2); R.putBool(b, r.incoming); R.putBlob(b, r.hash, 32); R.putNat(b, r.block, 8); R.putNat(b, r.day, 4);
    R.done(b, MESSAGE_ROW_BYTES)
  };
  func decodeMessage(instrument : Nat, seq : Nat, v : Blob) : MessageRow {
    let a = Blob.toArray(v);
    { instrument; seq; kind = a[0]; number = R.getNat(a, 1, 2); incoming = R.getBool(a, 3); hash = R.getBlob(a, 4, 32); block = R.getNat(a, 36, 8); day = R.getNat(a, 44, 4) }
  };

  // ─── state ────────────────────────────────────────────────────────────────

  public type State = {
    instruments : RI.State;   // id(8) -> row
    claims : RI.State;        // instrument(8) ‖ seq(8) -> row
    messages : RI.State;      // instrument(8) ‖ seq(8) -> row
    byParty : RI.State;       // party(8) ‖ id(8) -> 0
    byBook : RI.State;        // book(32) ‖ id(8) -> 0
    byState : RI.State;       // state(1) ‖ id(8) -> 0 (readers filter by the row)
    byExpiry : RI.State;      // expiry(4) ‖ id(8) -> 0 (readers filter by the row)
    byFacility : RI.State;    // facility(8) ‖ id(8) -> 0
    byReference : RI.State;   // sha(reference)[0..8) -> id(8)
    subledgers : RI.State;    // sub-ledger key(32) -> 1
    var policy : ?TrT.Policy;
    var contingentLcs : Nat;
    var contingentGuarantees : Nat;
    var contingentCollections : Nat;
    var issued : Nat;
    var open : Nat;
    openByCurrency : Map.Map<Text, Nat>;
    openByBook : Map.Map<Text, Nat>;
    var claimsTotal : Nat;
    var amendments : Nat;
    var messagesTotal : Nat;
    var paid : Nat;
    var expired : Nat;
  };

  public func newState(arena : RI.Arena) : State {
    {
      instruments = RI.newStateIn(arena, { keyBytes = 8; valBytes = INSTRUMENT_ROW_BYTES });
      claims = RI.newStateIn(arena, { keyBytes = 16; valBytes = CLAIM_ROW_BYTES });
      messages = RI.newStateIn(arena, { keyBytes = 16; valBytes = MESSAGE_ROW_BYTES });
      byParty = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      byBook = RI.newStateIn(arena, { keyBytes = 40; valBytes = 1 });
      byState = RI.newStateIn(arena, { keyBytes = 9; valBytes = 1 });
      byExpiry = RI.newStateIn(arena, { keyBytes = 12; valBytes = 1 });
      byFacility = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      byReference = RI.newStateIn(arena, { keyBytes = 8; valBytes = 8 });
      subledgers = RI.newStateIn(arena, { keyBytes = 32; valBytes = 1 });
      var policy = null; var contingentLcs = 0; var contingentGuarantees = 0; var contingentCollections = 0;
      openByCurrency = Map.empty<Text, Nat>();
      openByBook = Map.empty<Text, Nat>();
      var issued = 0; var open = 0; var claimsTotal = 0; var amendments = 0; var messagesTotal = 0; var paid = 0; var expired = 0;
    }
  };

  public func policy(s : State) : ?TrT.Policy { s.policy };
  public func row(s : State, id : TrT.InstrumentId) : ?InstrumentRow { switch (RI.get(s.instruments, R.key(id, 8))) { case (?v) ?decodeInstrument(id, v); case null null } };
  public func claim(s : State, id : TrT.InstrumentId, seq : TrT.ClaimSeq) : ?ClaimRow { switch (RI.get(s.claims, R.key2(id, 8, seq, 8))) { case (?v) ?decodeClaim(id, seq, v); case null null } };
  public func message(s : State, id : TrT.InstrumentId, seq : Nat) : ?MessageRow { switch (RI.get(s.messages, R.key2(id, 8, seq, 8))) { case (?v) ?decodeMessage(id, seq, v); case null null } };
  public func byReference(s : State, reference : Text) : ?TrT.InstrumentId { switch (RI.get(s.byReference, refKey(reference))) { case (?v) ?R.getNat(Blob.toArray(v), 0, 8); case null null } };
  func putRow(s : State, r : InstrumentRow) { ignore RI.put(s.instruments, R.key(r.id, 8), encodeInstrument(r)) };
  func putClaim(s : State, r : ClaimRow) { ignore RI.put(s.claims, R.key2(r.instrument, 8, r.seq, 8), encodeClaim(r)) };

  /// Outstanding = face less what was honoured or paid.
  public func outstanding(r : InstrumentRow) : Nat { if (r.amount > r.utilised) r.amount - r.utilised else 0 };
  public func isOpen(r : InstrumentRow) : Bool { switch (r.state) { case (#issued or #advised or #confirmed or #accepted or #rediscounted) true; case (_) false } };
  /// Whether the instrument is the bank's own undertaking: an issued or confirmed credit, an issued guarantee.
  public func isUndertaking(r : InstrumentRow) : Bool {
    switch (r.kind) { case 1 (r.role == 1 or (r.flags & F_CONFIRMED) != 0); case 2 true; case _ false }
  };

  // ─── figures ──────────────────────────────────────────────────────────────

  /// A straight-line figure on the face over the tenor, per annum in basis points, ACT/365 on calendar days.
  public func tenorFee(face : Nat, bps : Nat, from : Nat, to : Nat) : Nat {
    if (to <= from) return 0;
    face * bps * (to - from) / (10_000 * 365)
  };
  /// What is earned of a total by `day`, straight-line from issue to expiry: cumulative so rounding never drifts.
  public func earnedBy(total : Nat, issuedDay : Nat, expiry : Nat, day : Nat) : Nat {
    if (day >= expiry or expiry <= issuedDay) return total;
    if (day <= issuedDay) return 0;
    total * (day - issuedDay) / (expiry - issuedDay)
  };
  /// The face a presentation may draw: the outstanding plus the tolerance (UCP 600 art. 30(a)) on the face.
  public func availableWithTolerance(r : InstrumentRow) : Nat { outstanding(r) + r.amount * r.tolerance / 10_000 };
  /// The n-th banking day following `from` (UCP 600 art. 14(b): "five banking days following the day of
  /// presentation"; URDG 758 art. 20(a): "five business days following the day of presentation").
  public func bankingDaysAfter(calendar : ?JT.CalendarConfig, from : Nat, n : Nat) : Nat {
    var d = from; var left = n;
    while (left > 0) { d += 1; if (Conv.isBusinessDay(calendar, d)) left -= 1 };
    d
  };
  /// The day an instrument actually expires: its expiry, carried to the first following banking day when the
  /// expiry falls on a day the bank is closed (UCP 600 art. 29(a); URDG 758 art. 26(a)).
  public func effectiveExpiry(calendar : ?JT.CalendarConfig, expiry : Nat) : Nat {
    var d = expiry;
    while (not Conv.isBusinessDay(calendar, d)) d += 1;
    d
  };

  // ─── gates ────────────────────────────────────────────────────────────────

  func invalid(reason : Text, article : Text) : TrT.TradeError { #InvalidTerms({ reason; article }) };
  func require(s : State, id : TrT.InstrumentId) : Result.Result<InstrumentRow, TrT.TradeError> {
    switch (row(s, id)) { case (?r) #ok(r); case null #err(#UnknownInstrument({ instrument = id })) }
  };
  func requireKind(r : InstrumentRow, kind : Nat8) : ?TrT.TradeError {
    if (r.kind != kind) ?#WrongKind({ instrument = r.id; kind = kindTextOf(r.kind); wanted = kindTextOf(kind) }) else null
  };
  func requireOpen(r : InstrumentRow) : ?TrT.TradeError {
    if (isOpen(r)) null else ?#InstrumentNotIn({ instrument = r.id; state = TrT.stateText(r.state); wanted = "open" })
  };
  func requireClaim(s : State, id : TrT.InstrumentId, seq : TrT.ClaimSeq, wanted : [TrT.ClaimState]) : Result.Result<ClaimRow, TrT.TradeError> {
    let ?c = claim(s, id, seq) else return #err(#UnknownClaim({ instrument = id; claim = seq }));
    for (w in wanted.vals()) { if (c.state == w) return #ok(c) };
    var names = "";
    for (w in wanted.vals()) names := names # (if (names == "") "" else " or ") # TrT.claimStateText(w);
    #err(#ClaimNotIn({ instrument = id; claim = seq; state = TrT.claimStateText(c.state); wanted = names }))
  };
  /// No claim under the instrument is still being examined or awaiting its waiver.
  func noPendingClaim(s : State, r : InstrumentRow) : Bool {
    var i = 1;
    while (i <= r.claims) {
      switch (claim(s, r.id, i)) { case (?c) { switch (c.state) { case (#presented or #complying or #discrepant or #waived) return false; case (_) {} } }; case null {} };
      i += 1;
    };
    true
  };
  func validCounterparty(c : TrT.Counterparty) : ?Text {
    switch (c) {
      case (#party(_)) null;
      case (#external(e)) { if (e.name == "") ?"an external counterparty needs a name" else if (e.bic.size() != 8 and e.bic.size() != 11) ?"a BIC is 8 or 11 characters" else null };
    }
  };
  func validBank(bic : Text) : ?Text { if (bic != "" and bic.size() != 8 and bic.size() != 11) ?"a BIC is 8 or 11 characters" else null };

  // ─── planners: the policy ─────────────────────────────────────────────────

  public func planPolicy(p : TrT.Policy) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    if (p.bic.size() != 8 and p.bic.size() != 11) return #err(#InvalidPolicy({ reason = "the bank's BIC is 8 or 11 characters" }));
    for ((name, v) in [("contingentLcs", p.contingentLcs), ("contingentGuarantees", p.contingentGuarantees), ("contingentCollections", p.contingentCollections),
                       ("contingentContra", p.contingentContra), ("marginDeposits", p.marginDeposits), ("unearnedCommission", p.unearnedCommission),
                       ("commissionIncome", p.commissionIncome), ("acceptancesPayable", p.acceptancesPayable), ("customersLiabilityAcceptances", p.customersLiabilityAcceptances),
                       ("billsNegotiated", p.billsNegotiated), ("billsDiscounted", p.billsDiscounted), ("unearnedDiscount", p.unearnedDiscount), ("discountIncome", p.discountIncome),
                       ("billsRediscounted", p.billsRediscounted), ("billLosses", p.billLosses), ("nostro", p.nostro), ("claimProduct", p.claimProduct)].vals()) {
      if (v == "") return #err(#InvalidPolicy({ reason = name # " names no account" }));
    };
    if (p.examinationDays == 0) return #err(#InvalidPolicy({ reason = "the examination period is at least one banking day" }));
    #ok(#policySet(p))
  };

  // ─── planners: documentary credits ────────────────────────────────────────

  func validTerms(t : TrT.DocumentaryTerms, expiry : Nat, today : Nat) : ?TrT.TradeError {
    if (t.documents.size() == 0) return ?invalid("a credit calls for at least one document", "UCP 600 art. 5");
    if (t.presentationDays == 0 or t.presentationDays > 21) return ?invalid("the presentation period is between one and twenty-one days after shipment", "UCP 600 art. 14(c)");
    switch (t.latestShipment) { case (?d) { if (d > expiry) return ?invalid("the latest shipment date is not after the expiry", "UCP 600 art. 6(d)"); if (d < today) return ?invalid("the latest shipment date has passed", "UCP 600 art. 6(d)") }; case null {} };
    switch (t.incoterm) { case (?i) { if (Array.indexOf<Text>(INCOTERMS, Text.equal, i) == null) return ?invalid("the Incoterm is not one of the eleven rules", "Incoterms 2020") }; case null {} };
    switch (t.availableBy) { case (#deferred(d) or #acceptance(d)) { if (d.days == 0) return ?invalid("a deferred payment or acceptance credit names its tenor", "UCP 600 art. 6(b)") }; case (_) {} };
    for (d in t.documents.vals()) { if (d.copies == 0) return ?invalid("a document is called for in at least one original or copy", "UCP 600 art. 17"); if (d.checks.size() == 0) return ?invalid("every document carries at least one check of the examination checklist", "ISBP 821") };
    null
  };

  public func planIssueLc(s : State, lc : TrT.LetterOfCredit, amount : Nat, currency : Text, expiry : Nat, placeOfExpiry : Text, book : Text, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    if (s.policy == null) return #err(#NoPolicy);
    if (lc.role != #issuing) return #err(invalid("a credit the bank issues is issued in the issuing role; advising and confirming come by the counterparty's message", "UCP 600 art. 2"));
    switch (lc.applicant) { case (#party(_)) {}; case (#external(_)) return #err(invalid("the applicant of a credit the bank issues is its own customer", "UCP 600 art. 2")) };
    if (amount == 0) return #err(invalid("a credit for nothing", "UCP 600 art. 2"));
    if (expiry <= today) return #err(invalid("the expiry is after today", "UCP 600 art. 6(d)"));
    if (placeOfExpiry == "") return #err(invalid("a credit states a place for presentation", "UCP 600 art. 6(d)(ii)"));
    if (lc.reference == "") return #err(invalid("a credit carries its number", "MT 700 field 20"));
    if (byReference(s, lc.reference) != null) return #err(invalid("a credit with this number exists", "MT 700 field 20"));
    switch (validCounterparty(lc.beneficiary)) { case (?why) return #err(invalid(why, "UCP 600 art. 2")); case null {} };
    switch (validBank(lc.counterpartyBank)) { case (?why) return #err(invalid(why, "MT 700 receiver")); case null {} };
    switch (validTerms(lc.terms, expiry, today)) { case (?e) return #err(e); case null {} };
    switch (lc.tolerance) { case (?t) { if (t > 1_000) return #err(invalid("a tolerance beyond ten per cent is a different credit", "UCP 600 art. 30(a)")) }; case null {} };
    if (lc.marginBps > 10_000) return #err(invalid("a margin beyond the face", "policy"));
    let margin = amount * lc.marginBps / 10_000;
    let commission = tenorFee(amount, lc.commissionBps, today, expiry);
    #ok(#lcIssued({ lc; amount; currency; expiry; placeOfExpiry; margin; commission; book; day = today }))
  };

  /// A credit another bank issued, advised to (and, when asked, confirmed by) this bank from the recorded message.
  public func planAdviseLc(s : State, lc : TrT.LetterOfCredit, amount : Nat, currency : Text, expiry : Nat, placeOfExpiry : Text, messageHash : Blob, confirmed : Bool, book : Text, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    if (s.policy == null) return #err(#NoPolicy);
    if (lc.role == #issuing) return #err(invalid("an advised credit is advised or confirmed, not issued", "UCP 600 art. 9"));
    if (confirmed and lc.role != #confirming) return #err(invalid("a confirmation is given in the confirming role", "UCP 600 art. 8"));
    if (amount == 0) return #err(invalid("a credit for nothing", "UCP 600 art. 2"));
    if (expiry <= today) return #err(invalid("the expiry is after today", "UCP 600 art. 6(d)"));
    if (messageHash.size() != 32) return #err(#BadMessage({ reason = "the message hash is 32 bytes" }));
    if (lc.reference == "") return #err(invalid("a credit carries its number", "MT 700 field 20"));
    if (byReference(s, lc.reference) != null) return #err(invalid("a credit with this number exists", "MT 700 field 20"));
    switch (validBank(lc.counterpartyBank)) { case (?why) return #err(invalid(why, "MT 700 sender")); case null {} };
    if (lc.counterpartyBank == "") return #err(invalid("an advised credit names its issuing bank", "MT 700 sender"));
    switch (lc.beneficiary) { case (#party(_)) {}; case (#external(_)) return #err(invalid("a credit is advised to the bank's own customer, the beneficiary", "UCP 600 art. 9")) };
    switch (lc.applicant) { case (#external(_)) {}; case (#party(_)) return #err(invalid("the applicant of an advised credit is the issuing bank's customer", "UCP 600 art. 9")) };
    switch (validTerms(lc.terms, expiry, today)) { case (?e) return #err(e); case null {} };
    let commission = tenorFee(amount, lc.commissionBps, today, expiry);
    #ok(#lcAdvised({ lc; amount; currency; expiry; placeOfExpiry; messageHash; confirmed; commission; book; day = today }))
  };

  /// An amendment is effective only with the consents the rules require: the beneficiary's always (UCP 600 art.
  /// 10(a), (c); URDG 758 art. 11(b)), the confirming bank's when the credit is confirmed and we did not confirm it
  /// ourselves (art. 10(b)). The applicant's or the issuing bank's consent is recorded when given but never gates.
  public func planAmend(s : State, id : TrT.InstrumentId, amendment : TrT.Amendment, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    if (r.kind != 1 and r.kind != 2) return #err(#WrongKind({ instrument = id; kind = kindTextOf(r.kind); wanted = "letterOfCredit or guarantee" }));
    switch (requireOpen(r)) { case (?e) return #err(e); case null {} };
    let article = if (r.kind == 1) "UCP 600 art. 10" else if (r.rules == #URDG758) "URDG 758 art. 11" else "ISP98 rule 2.06";
    if (Array.indexOf<TrT.Consent>(amendment.consents, func(a : TrT.Consent, b : TrT.Consent) : Bool { a == b }, #beneficiary) == null) return #err(#ConsentMissing({ instrument = id; needed = "beneficiary"; article }));
    if (r.kind == 1 and (r.flags & F_CONFIRMED) != 0 and r.role == 1 and Array.indexOf<TrT.Consent>(amendment.consents, func(a : TrT.Consent, b : TrT.Consent) : Bool { a == b }, #confirmingBank) == null) {
      return #err(#ConsentMissing({ instrument = id; needed = "confirmingBank"; article = "UCP 600 art. 10(b)" }));
    };
    let amount = switch (amendment.amount) { case (?a) a; case null r.amount };
    let expiry = switch (amendment.expiry) { case (?e) e; case null r.expiry };
    if (amount < r.utilised) return #err(invalid("the amended face is below what was already drawn", article));
    if (amount == 0) return #err(invalid("an amendment to nothing is a cancellation", article));
    if (expiry <= today) return #err(invalid("an amended expiry is after today", article));
    switch (amendment.latestShipment) { case (?d) { if (r.kind != 1) return #err(invalid("a latest shipment date belongs to a credit", article)); if (d > expiry) return #err(invalid("the latest shipment date is not after the expiry", "UCP 600 art. 6(d)")) }; case null {} };
    if (amendment.amount == null and amendment.expiry == null and amendment.latestShipment == null and amendment.other == "") return #err(invalid("an amendment changes something", article));
    let ev = { instrument = id; amendment; number = r.amendments + 1; amount; expiry; day = today };
    #ok(if (r.kind == 1) #lcAmended(ev) else #guaranteeAmended(ev))
  };

  /// Documents presented under a credit: on or before the expiry (art. 6(e)), within the presentation period after
  /// shipment (art. 14(c)), for at most the available amount with the tolerance (art. 30). The fate is decided at
  /// examination; what is judged here is whether a presentation under the credit was made at all.
  public func planPresent(s : State, calendar : ?JT.CalendarConfig, id : TrT.InstrumentId, terms : TrT.DocumentaryTerms, documents : [TrT.DocumentRef], amount : Nat, shipmentDate : ?Nat, presentedOn : Nat, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let ?pol = s.policy else return #err(#NoPolicy);
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 1)) { case (?e) return #err(e); case null {} };
    switch (requireOpen(r)) { case (?e) return #err(e); case null {} };
    if (documents.size() == 0) return #err(invalid("a presentation is of documents", "UCP 600 art. 2"));
    for (d in documents.vals()) { if (d.hash.size() != 32) return #err(invalid("a document's hash is 32 bytes", "UCP 600 art. 2")) };
    if (amount == 0) return #err(invalid("a presentation for nothing", "UCP 600 art. 2"));
    if (presentedOn > today) return #err(invalid("a presentation is not in the future", "UCP 600 art. 14(b)"));
    if (presentedOn > effectiveExpiry(calendar, r.expiry)) return #err(#Expired({ instrument = id; expiry = r.expiry; day = presentedOn; article = "UCP 600 art. 6(e), 29(a)" }));
    switch (shipmentDate) {
      case (?sd) {
        switch (terms.latestShipment) { case (?ls) { if (sd > ls) return #err(#LatePresentation({ instrument = id; shipped = sd; presented = presentedOn; allowed = 0; article = "UCP 600 art. 44" })) }; case null {} };
        if (presentedOn > sd + terms.presentationDays) return #err(#LatePresentation({ instrument = id; shipped = sd; presented = presentedOn; allowed = terms.presentationDays; article = "UCP 600 art. 14(c)" }));
      };
      case null {};
    };
    let avail = availableWithTolerance(r);
    if (amount > avail) return #err(#OverUtilised({ instrument = id; available = avail; asked = amount; article = "UCP 600 art. 30" }));
    let deadline = bankingDaysAfter(calendar, presentedOn, pol.examinationDays);
    #ok(#documentsPresented({ instrument = id; claim = r.claims + 1; documents; amount; shipmentDate; presentedOn; deadline; day = today }))
  };

  /// The examination: within the deadline; the checks recorded are exactly the credit's checklist (every
  /// document's every check, once); the decision follows from them — complying only when none failed, a refusal
  /// naming each failed check once and what is done with the documents (art. 16(c)).
  public func planExamine(s : State, id : TrT.InstrumentId, seq : TrT.ClaimSeq, checklist : [(TrT.DocumentKind, Text)], checks : [TrT.CheckResult], decision : TrT.Decision, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    if (r.kind != 1 and r.kind != 2) return #err(#WrongKind({ instrument = id; kind = kindTextOf(r.kind); wanted = "letterOfCredit or guarantee" }));
    let c = switch (requireClaim(s, id, seq, [#presented])) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let lateArticle = if (r.kind == 1) "UCP 600 art. 14(b)" else if (r.rules == #URDG758) "URDG 758 art. 20(a)" else "ISP98 rule 5.01";
    let noticeArticle = if (r.kind == 1) "UCP 600 art. 16(c)" else if (r.rules == #URDG758) "URDG 758 art. 24(d)" else "ISP98 rule 5.02";
    if (today > c.deadline) return #err(#ExaminationLate({ instrument = id; claim = seq; presented = c.presentedOn; deadline = c.deadline; day = today; article = lateArticle }));
    // the checks recorded are the checklist, each once
    if (checks.size() != checklist.size()) return #err(invalid("the examination records every check of the checklist once: " # Nat.toText(checklist.size()) # " expected, " # Nat.toText(checks.size()) # " recorded", "ISBP 821"));
    for ((doc, chk) in checklist.vals()) {
      var n = 0;
      for (x in checks.vals()) { if (x.document == doc and x.check == chk) n += 1 };
      if (n != 1) return #err(invalid("check " # chk # " on the " # TrT.documentKindText(doc) # " recorded " # Nat.toText(n) # " times", "ISBP 821"));
    };
    let failed = List.empty<Text>();
    for (x in checks.vals()) { if (not x.passed) List.add(failed, x.check) };
    let failedArr = List.toArray(failed);
    switch (decision) {
      case (#complying) { if (failedArr.size() > 0) return #err(#DecisionContradictsChecks({ instrument = id; claim = seq; failed = failedArr; article = noticeArticle })) };
      case (#refuse(n)) {
        if (failedArr.size() == 0) return #err(#DecisionContradictsChecks({ instrument = id; claim = seq; failed = []; article = noticeArticle }));
        let missing = List.empty<Text>();
        for (f in failedArr.vals()) { if (Array.indexOf<Text>(n.discrepancies, Text.equal, f) == null) List.add(missing, f) };
        if (List.size(missing) > 0) return #err(#NoticeIncomplete({ instrument = id; claim = seq; missing = List.toArray(missing); article = noticeArticle }));
        for (d in n.discrepancies.vals()) { if (Array.indexOf<Text>(failedArr, Text.equal, d) == null) return #err(invalid("the notice names a discrepancy no check found: " # d, noticeArticle)) };
        if (n.discrepancies.size() != failedArr.size()) return #err(invalid("the notice states each discrepancy once", noticeArticle));
      };
    };
    let ev = { instrument = id; claim = seq; checks; decision; day = today };
    #ok(if (r.kind == 1) #presentationExamined(ev) else #demandExamined(ev))
  };

  /// The applicant waives the discrepancies (art. 16(b)): only the issuing bank may approach the applicant, and the
  /// waiver does not extend the five banking days.
  public func planWaive(s : State, id : TrT.InstrumentId, seq : TrT.ClaimSeq, applicantConsentHash : Blob, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 1)) { case (?e) return #err(e); case null {} };
    if (r.role != 1) return #err(invalid("only the issuing bank approaches the applicant for a waiver", "UCP 600 art. 16(b)"));
    let c = switch (requireClaim(s, id, seq, [#discrepant])) { case (#err(e)) return #err(e); case (#ok(c)) c };
    if (applicantConsentHash.size() != 32) return #err(invalid("the applicant's consent is recorded by its hash", "UCP 600 art. 16(b)"));
    if (today > c.deadline) return #err(#ExaminationLate({ instrument = id; claim = seq; presented = c.presentedOn; deadline = c.deadline; day = today; article = "UCP 600 art. 16(b)" }));
    #ok(#discrepanciesWaived({ instrument = id; claim = seq; applicantConsentHash; day = today }))
  };

  /// A complying (or waived) presentation is honoured the way the credit is available (art. 7(a), 8(a)): at sight,
  /// by deferred payment or acceptance falling due the stated days after presentation, or by negotiation.
  public func planHonour(s : State, id : TrT.InstrumentId, seq : TrT.ClaimSeq, availability : TrT.Availability, honour : TrT.Honour, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 1)) { case (?e) return #err(e); case null {} };
    switch (requireOpen(r)) { case (?e) return #err(e); case null {} };
    let c = switch (requireClaim(s, id, seq, [#complying, #waived])) { case (#err(e)) return #err(e); case (#ok(c)) c };
    switch (availability, honour) {
      case (#sight, #sight) {};
      case (#deferred(a), #deferred(h)) { if (h.due != c.presentedOn + a.days) return #err(invalid("a deferred payment falls due " # Nat.toText(a.days) # " days after presentation", "UCP 600 art. 7(a)(iii)")) };
      case (#acceptance(a), #acceptance(h)) { if (h.due != c.presentedOn + a.days) return #err(invalid("an acceptance matures " # Nat.toText(a.days) # " days after presentation", "UCP 600 art. 7(a)(iv)")) };
      case (#negotiation, #negotiation(h)) { if (h.due < today) return #err(invalid("a negotiation's reimbursement date is not past", "UCP 600 art. 7(a)(v)")) };
      case (_, _) return #err(invalid("the credit is available by " # TrT.availabilityText(availability) # ", not " # TrT.honourText(honour), "UCP 600 art. 6(b)"));
    };
    if (c.amount > availableWithTolerance(r)) return #err(#OverUtilised({ instrument = id; available = availableWithTolerance(r); asked = c.amount; article = "UCP 600 art. 30" }));
    #ok(#presentationHonoured({ instrument = id; claim = seq; amount = c.amount; honour; fromMargin = 0; day = today }))
  };

  /// A deferred payment, an acceptance or a negotiation falls due: paid on or after its date.
  public func planMature(s : State, id : TrT.InstrumentId, seq : TrT.ClaimSeq, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 1)) { case (?e) return #err(e); case null {} };
    let c = switch (requireClaim(s, id, seq, [#honoured])) { case (#err(e)) return #err(e); case (#ok(c)) c };
    if (c.honour == 1) return #err(#ClaimNotIn({ instrument = id; claim = seq; state = "honoured at sight"; wanted = "a deferred payment, acceptance or negotiation" }));
    if (today < c.due) return #err(invalid("the undertaking falls due on day " # Nat.toText(c.due), "UCP 600 art. 7(a)"));
    #ok(#acceptanceMatured({ instrument = id; claim = seq; amount = c.amount; fromMargin = 0; day = today }))
  };

  public func planCloseLc(s : State, id : TrT.InstrumentId, reason : Text, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 1)) { case (?e) return #err(e); case null {} };
    switch (requireOpen(r)) { case (?e) return #err(e); case null {} };
    if (not noPendingClaim(s, r)) return #err(invalid("a presentation is still under examination or awaiting a waiver", "UCP 600 art. 14(b)"));
    if (reason == "") return #err(invalid("a closure states its reason", "policy"));
    #ok(#lcClosed({ instrument = id; reason; marginReleased = r.margin; day = today }))
  };

  // ─── planners: undertakings (ISP98, URDG 758) ─────────────────────────────

  public func planIssueGuarantee(s : State, g : TrT.Guarantee, wordingText : Text, amount : Nat, currency : Text, expiry : Nat, book : Text, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    if (s.policy == null) return #err(#NoPolicy);
    switch (g.rules) { case (#ISP98 or #URDG758) {}; case (_) return #err(invalid("an undertaking is subject to ISP98 or URDG 758", "URDG 758 art. 1")) };
    if (g.kind == #standby and g.rules != #ISP98) return #err(invalid("a standby is subject to ISP98", "ISP98 rule 1.01"));
    if (g.kind != #standby and g.rules != #URDG758) return #err(invalid("a demand or counter-guarantee is subject to URDG 758", "URDG 758 art. 1"));
    if (amount == 0) return #err(invalid("an undertaking for nothing", "URDG 758 art. 2"));
    if (expiry <= today) return #err(invalid("the expiry is after today", "URDG 758 art. 2"));
    if (g.wording.size() != 32) return #err(invalid("the wording is recorded by its SHA-256", "URDG 758 art. 8"));
    if (wordingText == "") return #err(invalid("an undertaking has its wording", "URDG 758 art. 8"));
    if (Sha256.fromBlob(#sha256, Text.encodeUtf8(wordingText)) != g.wording) return #err(invalid("the wording text does not hash to the recorded wording", "URDG 758 art. 8"));
    if (g.reference == "") return #err(invalid("an undertaking carries its number", "MT 760 field 20"));
    if (byReference(s, g.reference) != null) return #err(invalid("an undertaking with this number exists", "MT 760 field 20"));
    switch (validCounterparty(g.beneficiary)) { case (?why) return #err(invalid(why, "URDG 758 art. 2")); case null {} };
    switch (validBank(g.counterpartyBank)) { case (?why) return #err(invalid(why, "MT 760 receiver")); case null {} };
    if (g.kind == #counterGuarantee and g.counterpartyBank == "") return #err(invalid("a counter-guarantee names the guarantor it supports", "URDG 758 art. 2"));
    if (g.marginBps > 10_000) return #err(invalid("a margin beyond the face", "policy"));
    var lastDay = 0; var lastAmount = amount;
    for ((d, a) in g.reductions.vals()) {
      if (d <= today or d > expiry) return #err(invalid("a reduction falls between today and the expiry", "URDG 758 art. 13"));
      if (d <= lastDay) return #err(invalid("reductions are in date order", "URDG 758 art. 13"));
      if (a >= lastAmount) return #err(invalid("each reduction lowers the amount", "URDG 758 art. 13"));
      lastDay := d; lastAmount := a;
    };
    let margin = amount * g.marginBps / 10_000;
    let commission = tenorFee(amount, g.commissionBps, today, expiry);
    #ok(#guaranteeIssued({ guarantee = g; wordingText; amount; currency; expiry; margin; commission; book; day = today }))
  };

  /// A demand: on or before expiry (art. 14(a)), with its supporting statement when the guarantee requires one
  /// (art. 15(a)), for no more than the amount available (art. 17(c)).
  public func planDemand(s : State, calendar : ?JT.CalendarConfig, id : TrT.InstrumentId, demand : TrT.DocumentRef, amount : Nat, supportingStatement : Bool, presentedOn : Nat, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let ?pol = s.policy else return #err(#NoPolicy);
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 2)) { case (?e) return #err(e); case null {} };
    switch (requireOpen(r)) { case (?e) return #err(e); case null {} };
    if (demand.hash.size() != 32) return #err(invalid("the demand is recorded by its hash", "URDG 758 art. 15"));
    if (amount == 0) return #err(invalid("a demand for nothing", "URDG 758 art. 15"));
    if (presentedOn > today) return #err(invalid("a demand is not in the future", "URDG 758 art. 14"));
    if (presentedOn > effectiveExpiry(calendar, r.expiry)) return #err(#Expired({ instrument = id; expiry = r.expiry; day = presentedOn; article = if (r.rules == #URDG758) "URDG 758 art. 14(a), 26(a)" else "ISP98 rule 3.13" }));
    if ((r.flags & F_STATEMENT) != 0 and not supportingStatement) return #err(#StatementMissing({ instrument = id; article = "URDG 758 art. 15(a)" }));
    if (amount > outstanding(r)) return #err(#OverUtilised({ instrument = id; available = outstanding(r); asked = amount; article = if (r.rules == #URDG758) "URDG 758 art. 17(c)" else "ISP98 rule 3.08" }));
    let deadline = bankingDaysAfter(calendar, presentedOn, pol.examinationDays);
    #ok(#demandRecorded({ instrument = id; claim = r.claims + 1; demand; amount; supportingStatement; presentedOn; deadline; day = today }))
  };

  /// A complying demand is paid (art. 20(b)); the figures — what the margin covers, what the principal's account
  /// pays, what becomes a claim — are `BankCore`'s from the balances; this gate says the payment may be made.
  public func planPayDemand(s : State, id : TrT.InstrumentId, seq : TrT.ClaimSeq, today : Nat) : Result.Result<ClaimRow, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 2)) { case (?e) return #err(e); case null {} };
    switch (requireOpen(r)) { case (?e) return #err(e); case null {} };
    let c = switch (requireClaim(s, id, seq, [#complying])) { case (#err(e)) return #err(e); case (#ok(c)) c };
    if (c.amount > outstanding(r)) return #err(#OverUtilised({ instrument = id; available = outstanding(r); asked = c.amount; article = "URDG 758 art. 17(c)" }));
    #ok(c)
  };

  public func planReduce(s : State, id : TrT.InstrumentId, to : Nat, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 2)) { case (?e) return #err(e); case null {} };
    switch (requireOpen(r)) { case (?e) return #err(e); case null {} };
    if (to >= r.amount) return #err(invalid("a reduction lowers the amount", "URDG 758 art. 13"));
    if (to < r.utilised) return #err(invalid("the amount cannot fall below what was paid", "URDG 758 art. 13"));
    #ok(#guaranteeReduced({ instrument = id; from = r.amount; to; day = today }))
  };

  public func planRelease(s : State, id : TrT.InstrumentId, reason : Text, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 2)) { case (?e) return #err(e); case null {} };
    switch (requireOpen(r)) { case (?e) return #err(e); case null {} };
    if (not noPendingClaim(s, r)) return #err(invalid("a demand is still under examination", "URDG 758 art. 20"));
    if (reason == "") return #err(invalid("a release states its ground: the beneficiary's release, the return of the original, the expiry", "URDG 758 art. 25"));
    #ok(#guaranteeReleased({ instrument = id; reason; marginReleased = r.margin; day = today }))
  };

  /// The instruments whose effective expiry has passed by `day` with no claim pending — what the batch expires.
  public func expiredBy(s : State, calendar : ?JT.CalendarConfig, day : Nat) : [InstrumentRow] {
    let out = List.empty<InstrumentRow>();
    let seen = List.empty<Nat>();   // an amended instrument is indexed under every expiry it has had
    let (lo, hi) = (R.key2(0, 4, 0, 8), R.key2(day, 4, 0xFFFF_FFFF_FFFF_FFFF, 8));
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.byExpiry, lo, hi, cursor, MAX_PAGE);
      for ((k, _) in page.entries.vals()) {
        let id = R.getNat(Blob.toArray(k), 4, 8);
        if (List.indexOf<Nat>(seen, Nat.equal, id) != null) continue;
        switch (row(s, id)) {
          case (?r) { if ((r.kind == 1 or r.kind == 2) and isOpen(r) and effectiveExpiry(calendar, r.expiry) < day and noPendingClaim(s, r)) { List.add(out, r); List.add(seen, id) } };
          case null {};
        };
      };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  /// The recorded reductions of a guarantee fallen due by `day`, from its terms: the lowest figure due, never below
  /// what was already paid (a clause that would cut under the utilised amount leaves nothing outstanding).
  public func reductionDue(g : TrT.Guarantee, r : InstrumentRow, day : Nat) : ?Nat {
    var target : ?Nat = null;
    for ((d, a) in g.reductions.vals()) { let floor = Nat.max(a, r.utilised); if (d <= day and floor < r.amount) target := ?floor };
    target
  };

  // ─── planners: documentary collections (URC 522) ──────────────────────────

  public func planRegisterCollection(s : State, c : TrT.Collection, amount : Nat, currency : Text, book : Text, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    if (s.policy == null) return #err(#NoPolicy);
    if (amount == 0) return #err(invalid("a collection for nothing", "URC 522 art. 2"));
    if (c.documents.size() == 0) return #err(invalid("a collection is of documents", "URC 522 art. 2"));
    for (d in c.documents.vals()) { if (d.hash.size() != 32) return #err(invalid("a document's hash is 32 bytes", "URC 522 art. 2")) };
    if (c.reference == "") return #err(invalid("a collection carries its reference", "URC 522 art. 4"));
    if (byReference(s, c.reference) != null) return #err(invalid("a collection with this reference exists", "URC 522 art. 4"));
    switch (validCounterparty(c.drawer)) { case (?why) return #err(invalid(why, "URC 522 art. 3")); case null {} };
    switch (validCounterparty(c.drawee)) { case (?why) return #err(invalid(why, "URC 522 art. 3")); case null {} };
    switch (validBank(c.counterpartyBank)) { case (?why) return #err(invalid(why, "URC 522 art. 3")); case null {} };
    switch (c.role, c.drawer, c.drawee) {
      case (#remitting, #external(_), _) return #err(invalid("the remitting bank acts for its own customer, the drawer", "URC 522 art. 3(a)(i)"));
      case (#collecting, _, #external(_)) return #err(invalid("the collecting bank presents to its own customer, the drawee", "URC 522 art. 3(a)(iii)"));
      case (_, _, _) {};
    };
    switch (c.terms) { case (#DA(t)) { if (t.tenorDays == 0) return #err(invalid("a D/A collection names its tenor", "URC 522 art. 7")) }; case (#DP) {} };
    #ok(#collectionRegistered({ collection = c; amount; currency; book; day = today }))
  };
  public func planPresentCollection(s : State, id : TrT.InstrumentId, presentedOn : Nat, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 3)) { case (?e) return #err(e); case null {} };
    if (r.state != #issued or r.claims > 0) return #err(#InstrumentNotIn({ instrument = id; state = TrT.stateText(r.state); wanted = "registered and not yet presented" }));
    if (presentedOn > today) return #err(invalid("a presentation is not in the future", "URC 522 art. 5"));
    #ok(#collectionPresented({ instrument = id; claim = 1; presentedOn; day = today }))
  };
  public func planAcceptCollection(s : State, id : TrT.InstrumentId, tenorDays : Nat, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 3)) { case (?e) return #err(e); case null {} };
    if ((r.flags & F_DA) == 0) return #err(invalid("a D/P collection is paid against the documents, not accepted", "URC 522 art. 7(a)"));
    let c = switch (requireClaim(s, id, 1, [#presented])) { case (#err(e)) return #err(e); case (#ok(c)) c };
    #ok(#collectionAccepted({ instrument = id; claim = 1; maturity = c.presentedOn + tenorDays; day = today }))
  };
  public func planPayCollection(s : State, id : TrT.InstrumentId, today : Nat) : Result.Result<(TrT.TradeEvent, InstrumentRow), TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 3)) { case (?e) return #err(e); case null {} };
    let wanted : [TrT.ClaimState] = if ((r.flags & F_DA) != 0) [#accepted] else [#presented];
    let _ = switch (requireClaim(s, id, 1, wanted)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let commission = r.amount * r.commissionBps / 10_000;
    #ok((#collectionPaid({ instrument = id; claim = 1; amount = r.amount; commission; day = today }), r))
  };
  public func planProtest(s : State, id : TrT.InstrumentId, reason : Text, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 3)) { case (?e) return #err(e); case null {} };
    let _ = switch (requireClaim(s, id, 1, [#presented, #accepted])) { case (#err(e)) return #err(e); case (#ok(c)) c };
    if (reason == "") return #err(invalid("a protest states the ground: non-acceptance or non-payment", "URC 522 art. 24"));
    #ok(#collectionProtested({ instrument = id; claim = 1; reason; day = today }))
  };
  public func planReturnCollection(s : State, id : TrT.InstrumentId, reason : Text, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 3)) { case (?e) return #err(e); case null {} };
    switch (r.state) { case (#issued or #protested) {}; case (_) return #err(#InstrumentNotIn({ instrument = id; state = TrT.stateText(r.state); wanted = "registered or protested" })) };
    if (reason == "") return #err(invalid("a return states its reason", "URC 522 art. 26"));
    #ok(#collectionReturned({ instrument = id; reason; day = today }))
  };

  // ─── planners: bills ──────────────────────────────────────────────────────

  /// The bank buys an accepted bill: the discount is the per-annum rate over the days to maturity, the proceeds
  /// the face less the discount. A bill arising from an accepted claim matches it in face and date.
  public func planDiscountBill(s : State, b : TrT.Bill, face : Nat, currency : Text, maturity : Nat, book : Text, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    if (s.policy == null) return #err(#NoPolicy);
    if (face == 0) return #err(invalid("a bill for nothing", "Bills of Exchange Act 1882 s.3"));
    if (maturity <= today) return #err(invalid("a bill bought before it matures", "Bills of Exchange Act 1882 s.10"));
    if (b.reference == "") return #err(invalid("a bill carries its reference", "policy"));
    if (byReference(s, b.reference) != null) return #err(invalid("a bill with this reference exists", "policy"));
    switch (validCounterparty(b.acceptor)) { case (?why) return #err(invalid(why, "Bills of Exchange Act 1882 s.17")); case null {} };
    switch (b.source) {
      case (?src) {
        let r = switch (require(s, src.instrument)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let c = switch (requireClaim(s, src.instrument, src.claim, [#honoured, #accepted])) { case (#err(e)) return #err(e); case (#ok(c)) c };
        if (r.kind == 1 and c.honour != 3) return #err(invalid("only an acceptance under a credit becomes a bill", "UCP 600 art. 7(a)(iv)"));
        if (c.amount != face) return #err(invalid("the bill's face is the accepted amount", "Bills of Exchange Act 1882 s.17"));
        if (c.due != maturity) return #err(invalid("the bill matures when the acceptance does", "Bills of Exchange Act 1882 s.11"));
        if (c.settledBlock != 0) return #err(#ClaimNotIn({ instrument = src.instrument; claim = src.claim; state = "settled"; wanted = "an outstanding acceptance" }));
      };
      case null {};
    };
    let discount = tenorFee(face, b.discountBps, today, maturity);
    if (discount >= face) return #err(invalid("the discount consumes the face", "policy"));
    #ok(#billDiscounted({ bill = b; face; currency; maturity; discount; proceeds = face - discount; book; day = today }))
  };
  public func planRediscount(s : State, id : TrT.InstrumentId, to : Text, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 4)) { case (?e) return #err(e); case null {} };
    if (r.state != #issued) return #err(#InstrumentNotIn({ instrument = id; state = TrT.stateText(r.state); wanted = "discounted and held" }));
    if (to == "") return #err(invalid("a rediscount names the taker", "policy"));
    #ok(#billRediscounted({ instrument = id; to; amount = r.amount; day = today }))
  };
  public func planBillMatured(s : State, id : TrT.InstrumentId, today : Nat) : Result.Result<(TrT.TradeEvent, InstrumentRow), TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 4)) { case (?e) return #err(e); case null {} };
    switch (r.state) { case (#issued or #rediscounted) {}; case (_) return #err(#InstrumentNotIn({ instrument = id; state = TrT.stateText(r.state); wanted = "discounted or rediscounted" })) };
    if (today < r.expiry) return #err(invalid("the bill matures on day " # Nat.toText(r.expiry), "Bills of Exchange Act 1882 s.14"));
    #ok((#billMatured({ instrument = id; face = r.amount; day = today }), r))
  };
  public func planBillDishonoured(s : State, id : TrT.InstrumentId, today : Nat) : Result.Result<(TrT.TradeEvent, InstrumentRow), TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 4)) { case (?e) return #err(e); case null {} };
    switch (r.state) { case (#issued or #rediscounted) {}; case (_) return #err(#InstrumentNotIn({ instrument = id; state = TrT.stateText(r.state); wanted = "discounted or rediscounted" })) };
    if (today < r.expiry) return #err(invalid("a bill is dishonoured by non-payment at maturity", "Bills of Exchange Act 1882 s.47"));
    let chargedBack = if ((r.flags & F_RECOURSE) != 0) r.amount else 0;
    #ok((#billDishonoured({ instrument = id; face = r.amount; chargedBack; day = today }), r))
  };

  // ─── planners: messages ───────────────────────────────────────────────────

  public func planRecordMessage(s : State, id : TrT.InstrumentId, kind : TrT.MessageKind, direction : TrT.Direction, hash : Blob, today : Nat) : Result.Result<TrT.TradeEvent, TrT.TradeError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    if (hash.size() != 32) return #err(#BadMessage({ reason = "the message hash is 32 bytes" }));
    switch (kind) {
      case (#mt(n)) { if (n < 700 or n > 799) return #err(#BadMessage({ reason = "a trade message is of the MT 7 series" })) };
      case (#tsrv(n)) { if (n == 0 or n > 19) return #err(#BadMessage({ reason = "tsrv.001 to tsrv.019" })) };
    };
    #ok(#tradeMessageRecorded({ instrument = id; seq = r.messages + 1; kind; direction; hash; day = today }))
  };

  // ─── the fold ─────────────────────────────────────────────────────────────

  func index(s : State, r : InstrumentRow) {
    ignore RI.put(s.byParty, R.key2(r.party, 8, r.id, 8), Blob.fromArray([0]));
    ignore RI.put(s.byState, R.key2(Nat8.toNat(stateCode(r.state)), 1, r.id, 8), Blob.fromArray([0]));
    ignore RI.put(s.byBook, bookKey(r.book, r.id), Blob.fromArray([0]));
    ignore RI.put(s.byExpiry, R.key2(r.expiry, 4, r.id, 8), Blob.fromArray([0]));
    switch (r.facility) { case (?f) ignore RI.put(s.byFacility, R.key2(f, 8, r.id, 8), Blob.fromArray([0])); case null {} };
  };
  func newRow(id : Nat, kind : TrT.Kind, rules : TrT.Rules, state : TrT.InstrumentState, flags : Nat8, party : Nat, account : Nat, cp : TrT.Counterparty, bank : Text, currency : Text, amount : Nat, issuedDay : Nat, expiry : Nat, facility : ?Nat, marginBps : Nat, margin : Nat, commissionBps : Nat, commissionTotal : Nat, tolerance : Nat, termsHash : Blob, book : Text) : InstrumentRow {
    {
      id; kind = kindCode(kind); state; rules; role = roleCode(kind); flags; party; account; counterpartyHash = counterpartyHash(cp); counterpartyBank = bank;
      currency; amount; utilised = 0; issuedDay; expiry; facility; marginBps; margin; commissionBps; commissionTotal; commissionEarned = 0;
      tolerance; claims = 0; amendments = 0; messages = 0; termsHash; lastBlock = id; book;
    }
  };
  /// The open instruments per currency, kept by the fold: what a redenomination asks before it closes a currency (S4.1).
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
  /// The open instruments of a book, from the fold's counter: what the end-of-day plan asks — no walk (S4.1).
  public func openCountInBook(s : State, book : Text) : Nat { switch (Map.get(s.openByBook, Text.compare, book)) { case (?v) v; case null 0 } };
  func moveState(s : State, r : InstrumentRow, to : TrT.InstrumentState, block : Nat) : InstrumentRow {
    let wasOpen = isOpen(r);
    let r2 = { r with state = to; lastBlock = block };
    if (wasOpen and not isOpen(r2)) { if (s.open > 0) s.open -= 1; bumpCurrency(s, r.currency, -1); bumpBook(s, r.book, -1) };
    ignore RI.put(s.byState, R.key2(Nat8.toNat(stateCode(to)), 1, r.id, 8), Blob.fromArray([0]));
    r2
  };
  /// The contingent memorandum an instrument carries: the outstanding of an undertaking, the face of an item for collection.
  func memo(s : State, r : InstrumentRow, delta : Int) {
    func apply(v : Nat) : Nat { let n : Int = v + delta; if (n < 0) 0 else Int.abs(n) };
    switch (r.kind) {
      case 1 { if (isUndertaking(r)) s.contingentLcs := apply(s.contingentLcs) };
      case 2 s.contingentGuarantees := apply(s.contingentGuarantees);
      case 3 s.contingentCollections := apply(s.contingentCollections);
      case _ {};
    }
  };
  /// The bank's own customer on an instrument, or none.
  public func ours(c : TrT.Counterparty) : (PT.PartyId, ProdT.AccountId) { switch (c) { case (#party(p)) (p.party, p.account); case (#external(_)) (0, 0) } };
  func register(s : State, r : InstrumentRow, reference : Text) {
    putRow(s, r); index(s, r);
    ignore RI.put(s.byReference, refKey(reference), R.key(r.id, 8));
    s.issued += 1; s.open += 1; bumpCurrency(s, r.currency, 1); bumpBook(s, r.book, 1);
    memo(s, r, outstanding(r));
  };
  func docsHash(docs : [TrT.DocumentRef]) : Blob {
    let w = C.Writer();
    w.nat(docs.size());
    for (d in docs.vals()) { w.text(TrT.documentKindText(d.kind)); w.blob(d.hash) };
    Sha256.fromBlob(#sha256, w.toBlob())
  };
  func openClaim(s : State, r : InstrumentRow, seq : Nat, amount : Nat, presentedOn : Nat, deadline : Nat, hash : Blob, flags : Nat8, block : Nat) {
    putClaim(s, { instrument = r.id; seq; state = #presented; flags; amount; presentedOn; deadline; documentsHash = hash; checksTotal = 0; checksFailed = 0; examinedBlock = 0; honour = 0; due = 0; settledBlock = 0; claimAccount = null });
    putRow(s, { r with claims = Nat.max(r.claims, seq); lastBlock = block });
    s.claimsTotal += 1;
  };

  public func fold(s : State, block : Nat, ev : TrT.TradeEvent) {
    switch (ev) {
      case (#policySet(p)) s.policy := ?p;
      case (#lcIssued(x)) {
        let termsHash = Sha256.fromBlob(#sha256, Text.encodeUtf8(debug_show x.lc.terms));
        let (party, account) = ours(x.lc.applicant);
        let r = newRow(block, #letterOfCredit(x.lc), #UCP600, #issued, 0, party, account, x.lc.beneficiary, x.lc.counterpartyBank, x.currency, x.amount, x.day, x.expiry, x.lc.facility,
                       x.lc.marginBps, x.margin, x.lc.commissionBps, x.commission, switch (x.lc.tolerance) { case (?t) t; case null 0 }, termsHash, x.book);
        register(s, r, x.lc.reference);
        if (x.margin > 0) holdSub(s, marginSub(block));
        if (x.commission > 0) holdSub(s, commissionSub(block));
      };
      case (#lcAdvised(x)) {
        let termsHash = Sha256.fromBlob(#sha256, Text.encodeUtf8(debug_show x.lc.terms));
        let flags : Nat8 = if (x.confirmed) F_CONFIRMED else 0;
        let (party, account) = ours(x.lc.beneficiary);
        let r = newRow(block, #letterOfCredit(x.lc), #UCP600, if (x.confirmed) #confirmed else #advised, flags, party, account, x.lc.applicant, x.lc.counterpartyBank, x.currency, x.amount, x.day, x.expiry, x.lc.facility,
                       0, 0, x.lc.commissionBps, x.commission, switch (x.lc.tolerance) { case (?t) t; case null 0 }, termsHash, x.book);
        register(s, r, x.lc.reference);
        if (x.commission > 0) holdSub(s, commissionSub(block));
        s.messagesTotal += 1;
        ignore RI.put(s.messages, R.key2(block, 8, 1, 8), encodeMessage({ instrument = block; seq = 1; kind = 1; number = 700; incoming = true; hash = x.messageHash; block; day = x.day }));
        putRow(s, { r with messages = 1 });
      };
      case (#lcAmended(x) or #guaranteeAmended(x)) {
        switch (row(s, x.instrument)) {
          case (?r) {
            memo(s, r, -outstanding(r));
            let r2 = { r with amount = x.amount; expiry = x.expiry; amendments = x.number; lastBlock = block };
            putRow(s, r2); ignore RI.put(s.byExpiry, R.key2(x.expiry, 4, r.id, 8), Blob.fromArray([0]));
            memo(s, r2, outstanding(r2)); s.amendments += 1;
          };
          case null {};
        }
      };
      case (#documentsPresented(x)) { switch (row(s, x.instrument)) { case (?r) openClaim(s, r, x.claim, x.amount, x.presentedOn, x.deadline, docsHash(x.documents), 0, block); case null {} } };
      case (#demandRecorded(x)) { switch (row(s, x.instrument)) { case (?r) openClaim(s, r, x.claim, x.amount, x.presentedOn, x.deadline, x.demand.hash, if (x.supportingStatement) CF_STATEMENT else 0, block); case null {} } };
      case (#collectionPresented(x)) { switch (row(s, x.instrument)) { case (?r) openClaim(s, r, x.claim, r.amount, x.presentedOn, 0, r.termsHash, 0, block); case null {} } };
      case (#presentationExamined(x) or #demandExamined(x)) {
        switch (claim(s, x.instrument, x.claim)) {
          case (?c) {
            var failed = 0; for (k in x.checks.vals()) { if (not k.passed) failed += 1 };
            let isLc = switch (ev) { case (#presentationExamined(_)) true; case (_) false };
            let st2 : TrT.ClaimState = switch (x.decision) {
              case (#complying) #complying;
              case (#refuse(n)) { if (isLc and n.disposal == #heldPendingWaiver) #discrepant else if (isLc) #refused else #rejected };
            };
            putClaim(s, { c with state = st2; checksTotal = x.checks.size(); checksFailed = failed; examinedBlock = block });
            switch (row(s, x.instrument)) { case (?r) putRow(s, { r with lastBlock = block }); case null {} };
          };
          case null {};
        }
      };
      case (#discrepanciesWaived(x)) { switch (claim(s, x.instrument, x.claim)) { case (?c) putClaim(s, { c with state = #waived }); case null {} } };
      case (#presentationHonoured(x)) {
        switch (claim(s, x.instrument, x.claim), row(s, x.instrument)) {
          case (?c, ?r) {
            let due = switch (x.honour) { case (#sight) x.day; case (#deferred(d) or #acceptance(d) or #negotiation(d)) d.due };
            putClaim(s, { c with state = #honoured; honour = honourCode(?x.honour); due; settledBlock = if (x.honour == #sight) block else 0 });
            memo(s, r, -outstanding(r));
            let r2 = { r with utilised = r.utilised + x.amount; margin = if (r.margin > x.fromMargin) r.margin - x.fromMargin else 0; lastBlock = block };
            putRow(s, r2); memo(s, r2, outstanding(r2));
            switch (x.honour) { case (#sight) s.paid += 1; case (#deferred(_) or #acceptance(_) or #negotiation(_)) holdSub(s, acceptanceSub(x.instrument, x.claim)) };
          };
          case (_, _) {};
        }
      };
      case (#acceptanceMatured(x)) {
        switch (claim(s, x.instrument, x.claim), row(s, x.instrument)) {
          case (?c, ?r) { putClaim(s, { c with state = #paid; settledBlock = block }); putRow(s, { r with margin = if (r.margin > x.fromMargin) r.margin - x.fromMargin else 0; lastBlock = block }); s.paid += 1 };
          case (_, _) {};
        }
      };
      // an end returns the margin and earns out the commission (the postings `BankCore` makes from the row)
      case (#lcClosed(x) or #guaranteeReleased(x)) {
        switch (row(s, x.instrument)) {
          case (?r) { if (isOpen(r)) memo(s, r, -outstanding(r)); putRow(s, moveState(s, { r with margin = if (r.margin > x.marginReleased) r.margin - x.marginReleased else 0; commissionEarned = r.commissionTotal }, if (r.kind == 1) #closed else #released, block)) };
          case null {};
        }
      };
      case (#lcExpired(x) or #guaranteeExpired(x)) {
        switch (row(s, x.instrument)) {
          case (?r) { if (isOpen(r)) memo(s, r, -outstanding(r)); putRow(s, moveState(s, { r with margin = if (r.margin > x.marginReleased) r.margin - x.marginReleased else 0; commissionEarned = r.commissionTotal }, #expired, block)); s.expired += 1 };
          case null {};
        }
      };
      case (#guaranteeIssued(x)) {
        let g = x.guarantee;
        let flags : Nat8 = if (g.statementRequired) F_STATEMENT else 0;
        let r = newRow(block, #guarantee(g), g.rules, #issued, flags, g.principal, g.principalAccount, g.beneficiary, g.counterpartyBank, x.currency, x.amount, x.day, x.expiry, g.facility,
                       g.marginBps, x.margin, g.commissionBps, x.commission, 0, g.wording, x.book);
        register(s, r, g.reference);
        if (x.margin > 0) holdSub(s, marginSub(block));
        if (x.commission > 0) holdSub(s, commissionSub(block));
      };
      case (#demandPaid(x)) {
        switch (claim(s, x.instrument, x.claim), row(s, x.instrument)) {
          case (?c, ?r) {
            putClaim(s, { c with state = #paid; settledBlock = block; claimAccount = x.claimAccount });
            memo(s, r, -outstanding(r));
            let r2 = { r with utilised = r.utilised + x.amount; margin = if (r.margin > x.fromMargin) r.margin - x.fromMargin else 0; lastBlock = block };
            putRow(s, r2); memo(s, r2, outstanding(r2)); s.paid += 1;
          };
          case (_, _) {};
        }
      };
      case (#guaranteeReduced(x)) {
        switch (row(s, x.instrument)) { case (?r) { memo(s, r, -outstanding(r)); let r2 = { r with amount = x.to; lastBlock = block }; putRow(s, r2); memo(s, r2, outstanding(r2)) }; case null {} }
      };
      case (#collectionRegistered(x)) {
        let c = x.collection;
        let flags : Nat8 = switch (c.terms) { case (#DA(_)) F_DA; case (#DP) 0 };
        let (party, account) = switch (c.role, c.drawer, c.drawee) {
          case (#remitting, #party(p), _) (p.party, p.account); case (#collecting, _, #party(p)) (p.party, p.account); case (_, _, _) (0, 0);
        };
        let cp = switch (c.role) { case (#remitting) c.drawee; case (#collecting) c.drawer };
        let r = newRow(block, #collection(c), #URC522, #issued, flags, party, account, cp, c.counterpartyBank, x.currency, x.amount, x.day, 0, null, 0, 0, c.commissionBps, 0, 0, docsHash(c.documents), x.book);
        register(s, r, c.reference);
      };
      case (#collectionAccepted(x)) {
        switch (claim(s, x.instrument, x.claim), row(s, x.instrument)) {
          case (?c, ?r) { putClaim(s, { c with state = #accepted; due = x.maturity }); putRow(s, moveState(s, r, #accepted, block)) };
          case (_, _) {};
        }
      };
      case (#collectionPaid(x)) {
        switch (claim(s, x.instrument, x.claim), row(s, x.instrument)) {
          case (?c, ?r) {
            putClaim(s, { c with state = #paid; settledBlock = block });
            memo(s, r, -outstanding(r));
            let r2 = moveState(s, { r with utilised = r.amount }, #paid, block); putRow(s, r2); s.paid += 1;
          };
          case (_, _) {};
        }
      };
      case (#collectionProtested(x)) {
        switch (claim(s, x.instrument, x.claim), row(s, x.instrument)) {
          case (?c, ?r) { putClaim(s, { c with state = #rejected; examinedBlock = block }); putRow(s, moveState(s, r, #protested, block)) };
          case (_, _) {};
        }
      };
      case (#collectionReturned(x)) {
        switch (row(s, x.instrument)) { case (?r) { memo(s, r, -outstanding(r)); putRow(s, moveState(s, r, #returned, block)) }; case null {} }
      };
      case (#billDiscounted(x)) {
        let b = x.bill;
        let flags : Nat8 = if (b.recourse) F_RECOURSE else 0;
        let r = newRow(block, #bill(b), #URC522, #issued, flags, b.customer, b.customerAccount, b.acceptor, "", x.currency, x.face, x.day, x.maturity, null, 0, 0, b.discountBps, x.discount, 0, hashText(b.reference), x.book);
        register(s, r, b.reference);
        holdSub(s, billSub(block));
        switch (b.source) { case (?src) { switch (claim(s, src.instrument, src.claim)) { case (?c) putClaim(s, { c with settledBlock = block }); case null {} } }; case null {} };
      };
      case (#billRediscounted(x)) { switch (row(s, x.instrument)) { case (?r) putRow(s, moveState(s, r, #rediscounted, block)); case null {} } };
      case (#billMatured(x)) { switch (row(s, x.instrument)) { case (?r) { putRow(s, moveState(s, { r with utilised = r.amount; commissionEarned = r.commissionTotal }, #matured, block)); s.paid += 1 }; case null {} } };
      case (#billDishonoured(x)) { switch (row(s, x.instrument)) { case (?r) putRow(s, moveState(s, { r with commissionEarned = r.commissionTotal }, #dishonoured, block)); case null {} } };
      case (#tradeMessageRecorded(x)) {
        switch (row(s, x.instrument)) {
          case (?r) {
            let (kc, n) = msgKindCode(x.kind);
            ignore RI.put(s.messages, R.key2(x.instrument, 8, x.seq, 8), encodeMessage({ instrument = x.instrument; seq = x.seq; kind = kc; number = n; incoming = x.direction == #incoming; hash = x.hash; block; day = x.day }));
            putRow(s, { r with messages = Nat.max(r.messages, x.seq); lastBlock = block }); s.messagesTotal += 1;
          };
          case null {};
        }
      };
      case (#commissionEarned(x) or #discountEarned(x)) { switch (row(s, x.instrument)) { case (?r) putRow(s, { r with commissionEarned = x.cumulative }); case null {} } };
    }
  };

  // ─── reads ────────────────────────────────────────────────────────────────

  public func view(s : State, r : InstrumentRow) : TrT.InstrumentView {
    {
      id = r.id; kind = kindTextOf(r.kind); state = TrT.stateText(r.state); rules = TrT.rulesText(r.rules); role = roleText(r.role);
      party = r.party; account = r.account; counterpartyHash = r.counterpartyHash; counterpartyBank = r.counterpartyBank;
      amount = r.amount; currency = r.currency; utilised = r.utilised; outstanding = outstanding(r);
      issuedDay = r.issuedDay; expiry = r.expiry; facility = r.facility;
      marginBps = r.marginBps; margin = r.margin;
      commissionBps = r.commissionBps; commissionTotal = r.commissionTotal; commissionEarned = r.commissionEarned;
      tolerance = r.tolerance; claims = r.claims; amendments = r.amendments; messages = r.messages;
      termsHash = r.termsHash; lastBlock = r.lastBlock; confirmed = (r.flags & F_CONFIRMED) != 0; book = r.book;
    }
  };
  public func claimView(c : ClaimRow) : TrT.ClaimView {
    {
      instrument = c.instrument; seq = c.seq; state = TrT.claimStateText(c.state); amount = c.amount;
      presentedOn = c.presentedOn; deadline = c.deadline; documentsHash = c.documentsHash; checksTotal = c.checksTotal; checksFailed = c.checksFailed;
      examinedBlock = if (c.examinedBlock == 0) null else ?c.examinedBlock; honour = honourTextOf(c.honour); due = if (c.due == 0) null else ?c.due;
      settledBlock = if (c.settledBlock == 0) null else ?c.settledBlock; claimAccount = c.claimAccount; supportingStatement = (c.flags & CF_STATEMENT) != 0;
    }
  };
  public func messageView(m : MessageRow) : TrT.MessageView {
    { instrument = m.instrument; seq = m.seq; kind = (if (m.kind == 1) "MT" else "tsrv.") # Nat.toText(m.number); direction = if (m.incoming) "incoming" else "outgoing"; hash = m.hash; block = m.block; day = m.day }
  };
  public func claimsOf(s : State, id : TrT.InstrumentId) : [ClaimRow] {
    let out = List.empty<ClaimRow>();
    let (lo, hi) = R.prefixRange(id, 8, 8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.claims, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) List.add(out, decodeClaim(id, R.getNat(Blob.toArray(k), 8, 8), v));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  public func messagesOf(s : State, id : TrT.InstrumentId) : [MessageRow] {
    let out = List.empty<MessageRow>();
    let (lo, hi) = R.prefixRange(id, 8, 8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.messages, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) List.add(out, decodeMessage(id, R.getNat(Blob.toArray(k), 8, 8), v));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  public func listByParty(s : State, party : PT.PartyId, cursor : ?Blob, limit : Nat) : { ids : [TrT.InstrumentId]; cursor : ?Blob } {
    let (lo, hi) = R.prefixRange(party, 8, 8);
    let page = RI.range(s.byParty, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    { ids = Array.map<(Blob, Blob), Nat>(page.entries, func((k, _)) { R.getNat(Blob.toArray(k), 8, 8) }); cursor = page.cursor }
  };
  public func listByState(s : State, state : TrT.InstrumentState, cursor : ?Blob, limit : Nat) : { ids : [TrT.InstrumentId]; cursor : ?Blob } {
    let (lo, hi) = R.prefixRange(Nat8.toNat(stateCode(state)), 1, 8);
    let page = RI.range(s.byState, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    let out = List.empty<Nat>();
    for ((k, _) in page.entries.vals()) { let id = R.getNat(Blob.toArray(k), 1, 8); switch (row(s, id)) { case (?r) { if (r.state == state) List.add(out, id) }; case null {} } };
    { ids = List.toArray(out); cursor = page.cursor }
  };
  /// Instruments expiring in a window of days, open ones only.
  public func expiringBetween(s : State, from : Nat, to : Nat, limit : Nat) : [InstrumentRow] {
    let out = List.empty<InstrumentRow>();
    let (lo, hi) = (R.key2(from, 4, 0, 8), R.key2(to, 4, 0xFFFF_FFFF_FFFF_FFFF, 8));
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.byExpiry, lo, hi, cursor, MAX_PAGE);
      for ((k, _) in page.entries.vals()) {
        let id = R.getNat(Blob.toArray(k), 4, 8);
        // an amended instrument is indexed under every expiry it has had: only the entry under its current expiry counts
        switch (row(s, id)) { case (?r) { if (isOpen(r) and r.expiry >= from and r.expiry <= to and R.getNat(Blob.toArray(k), 0, 4) == r.expiry) List.add(out, r) }; case null {} };
        if (List.size(out) >= limit) break walk;
      };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  /// Every open instrument — what the batch walks for commissions, discounts, reductions and maturities.
  public func openAll(s : State) : [InstrumentRow] {
    let out = List.empty<InstrumentRow>();
    for (st in [#issued, #advised, #confirmed, #accepted, #rediscounted].vals()) {
      let (lo, hi) = R.prefixRange(Nat8.toNat(stateCode(st)), 1, 8);
      var cursor : ?Blob = null;
      label walk loop {
        let page = RI.range(s.byState, lo, hi, cursor, MAX_PAGE);
        for ((k, _) in page.entries.vals()) { let id = R.getNat(Blob.toArray(k), 1, 8); switch (row(s, id)) { case (?r) { if (r.state == st) List.add(out, r) }; case null {} } };
        switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
      };
    };
    List.toArray(out)
  };
  func bookKey(book : Text, id : Nat) : Blob { Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.textKey(book, 32)), Blob.toArray(R.key(id, 8)))) };
  public func bookCursor(book : Text, id : Nat) : Blob { bookKey(book, id) };
  /// The open instruments of a book, one page off the book index from a cursor (`bookCursor(book, id)` to resume at an id):
  /// what the end-of-day walks a chunk at a time (the adversarial audit of 13 September, finding A2).
  public func openInBookFrom(s : State, book : Text, cursor : ?Blob, limit : Nat) : { ids : [TrT.InstrumentId]; cursor : ?Blob } {
    let lo = bookKey(book, 0);
    let hi = Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.textKey(book, 32)), Array.repeat<Nat8>(255, 8)));
    let page = RI.range(s.byBook, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    let out = List.empty<Nat>();
    for ((k, _) in page.entries.vals()) { let id = R.getNat(Blob.toArray(k), 32, 8); switch (row(s, id)) { case (?r) { if (isOpen(r)) List.add(out, id) }; case null {} } };
    { ids = List.toArray(out); cursor = page.cursor }
  };
  public func openInBook(s : State, book : Text) : [InstrumentRow] { Array.filter<InstrumentRow>(openAll(s), func(r) { Text.equal(r.book, book) }) };
  /// The undertakings outstanding against a facility — what reduces its availability (corporate lending).
  public func contingentOnFacility(s : State, facility : Nat) : Nat {
    var sum = 0;
    let (lo, hi) = R.prefixRange(facility, 8, 8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.byFacility, lo, hi, cursor, MAX_PAGE);
      for ((k, _) in page.entries.vals()) {
        let id = R.getNat(Blob.toArray(k), 8, 8);
        switch (row(s, id)) { case (?r) { if (isOpen(r) and isUndertaking(r)) sum += outstanding(r) }; case null {} };
      };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    sum
  };
  public func status(s : State) : TrT.TradeStatus {
    {
      instruments = s.issued; open = s.open; claims = s.claimsTotal; amendments = s.amendments; messages = s.messagesTotal; paid = s.paid; expired = s.expired;
      contingentLcs = s.contingentLcs; contingentGuarantees = s.contingentGuarantees; contingentCollections = s.contingentCollections;
    }
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
    w.nat(Map.size(s.openByBook));
    for ((k, v) in Map.entries(s.openByBook)) { w.text(k); w.nat(v) };
    w.nat(Map.size(s.openByCurrency));
    for ((k, v) in Map.entries(s.openByCurrency)) { w.text(k); w.nat(v) };
    switch (s.policy) {
      case null w.byte(0);
      case (?p) {
        w.byte(1);
        for (t in [p.bic, p.contingentLcs, p.contingentGuarantees, p.contingentCollections, p.contingentContra, p.marginDeposits, p.unearnedCommission, p.commissionIncome,
                   p.acceptancesPayable, p.customersLiabilityAcceptances, p.billsNegotiated, p.billsDiscounted, p.unearnedDiscount, p.discountIncome, p.billsRediscounted,
                   p.billLosses, p.nostro, p.claimProduct].vals()) w.text(t);
        w.nat(p.examinationDays);
      };
    };
    w.nat(s.contingentLcs); w.nat(s.contingentGuarantees); w.nat(s.contingentCollections);
    w.nat(s.issued); w.nat(s.open); w.nat(s.claimsTotal); w.nat(s.amendments); w.nat(s.messagesTotal); w.nat(s.paid); w.nat(s.expired);
    fingerprintRows(w, s.instruments, 8); fingerprintRows(w, s.claims, 16); fingerprintRows(w, s.messages, 16);
    fingerprintRows(w, s.byParty, 16); fingerprintRows(w, s.byBook, 40); fingerprintRows(w, s.byState, 9); fingerprintRows(w, s.byExpiry, 12); fingerprintRows(w, s.byFacility, 16);
    fingerprintRows(w, s.byReference, 8); fingerprintRows(w, s.subledgers, 32);
  };
}
