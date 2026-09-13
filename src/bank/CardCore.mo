/// CardCore.mo — the card book folded from the bank's log in stable memory (cards): cards by their token digest, every
/// authorization decision, the holds, the cleared transactions, the disputes, the statements; the schemes and
/// products whose rules are data.
///
/// Rows: one per card (keyed by the block that issued it), one per authorization decision (approved and declined
/// alike — the dispute and fraud patterns need both), one per cleared item, one per dispute, one per statement cut;
/// indexes by token digest, by account, by party, by state, by card and day (the daily and velocity folds), by
/// hold (the journal's pending index), by acquirer reference and day (duplicates), disputes by stage. The decision
/// engine is a pure function of the request, the card's row and controls, the product's bounds and the scheme's
/// rules, the day's approved authorizations and the account's availability — the same inputs the battery's Python
/// engine reads, so every decision is reproducible. The PAN is not here: the token's SHA-256 is the key, and the
/// token itself is kept nowhere.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Char "mo:core/Char";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";
import JT "mo:journal/JournalTypes";

import CT "CardTypes";
import PT "PartyTypes";
import ProdT "ProductTypes";
import Posting "Posting";
import R "StableRows";

module {

  public let CARD_ROW_BYTES : Nat = 179;
  public let AUTH_ROW_BYTES : Nat = 77;
  public let CLEARED_ROW_BYTES : Nat = 76;
  public let DISPUTE_ROW_BYTES : Nat = 59;
  public let STATEMENT_ROW_BYTES : Nat = 45;
  public let SCHEME_ROW_BYTES : Nat = 97;
  public let PRODUCT_ROW_BYTES : Nat = 65;
  public let MAX_BATCH_ITEMS : Nat = 200;
  public let MAX_LIST : Nat = 64;
  let MAX_PAGE = 512;
  let MINUTE_NS : Nat64 = 60_000_000_000;

  // ─── keys, codes, sub-ledgers ─────────────────────────────────────────────

  public func tokenHash(token : CT.Token) : Blob { Sha256.fromBlob(#sha256, token) };
  public func disputeSub(id : CT.DisputeId) : JT.SubledgerKey { Posting.subledgerOf("card-dispute/" # Nat.toText(id)) };
  public func holdsSubledger(s : State, sub : JT.SubledgerKey) : Bool { sub.size() == 32 and RI.get(s.subledgers, sub) != null };
  func holdSub(s : State, sub : JT.SubledgerKey) { ignore RI.put(s.subledgers, sub, Blob.fromArray([1])) };
  func hash8(t : Text) : Nat { R.getNat(Blob.toArray(Sha256.fromBlob(#sha256, Text.encodeUtf8(t))), 0, 8) };
  /// The authorization code the acquirer quotes back: six base-36 characters of the decision's block index, so the
  /// code names the block and no index is needed to find it.
  public func authCodeOf(id : Nat) : Text {
    let digits = Text.toArray("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    var n = id; var out : [Char] = [];
    var i = 0;
    while (i < 6) { out := Array.concat([digits[n % 36]], out); n /= 36; i += 1 };
    Text.fromArray(out)
  };
  public func authIdOf(code : Text) : ?Nat {
    if (code.size() != 6) return null;
    var n = 0;
    for (c in code.chars()) {
      let v : Nat = if (c >= '0' and c <= '9') Nat32.toNat(Char.toNat32(c)) - 48 else if (c >= 'A' and c <= 'Z') Nat32.toNat(Char.toNat32(c)) - 55 else return null;
      n := n * 36 + v;
    };
    ?n
  };
  func stateCode(s : CT.CardState) : Nat8 { switch (s) { case (#issued) 1; case (#active) 2; case (#blocked) 3; case (#closed) 4 } };
  func stateOf(c : Nat8) : CT.CardState { switch (c) { case 1 #issued; case 2 #active; case 3 #blocked; case _ #closed } };
  func stageCode(s : CT.DisputeStage) : Nat8 { switch (s) { case (#opened) 1; case (#provisionalCredit) 2; case (#chargeback) 3; case (#representment) 4; case (#preArbitration) 5; case (#resolved) 6 } };
  func stageOf(c : Nat8) : CT.DisputeStage { switch (c) { case 1 #opened; case 2 #provisionalCredit; case 3 #chargeback; case 4 #representment; case 5 #preArbitration; case _ #resolved } };
  func kindCode(k : CT.AuthKind) : Nat8 { switch (k) { case (#purchase) 1; case (#preAuthorization) 2; case (#incremental(_)) 3; case (#completion(_)) 4; case (#refund) 5; case (#reversal(_)) 6 } };
  public func kindTextOf(c : Nat8) : Text { switch (c) { case 1 "purchase"; case 2 "preAuthorization"; case 3 "incremental"; case 4 "completion"; case 5 "refund"; case 6 "reversal"; case _ "?" } };
  func channelCode(c : CT.Channel) : Nat8 { switch (c) { case (#pos) 1; case (#atm) 2; case (#ecom) 3; case (#contactless) 4 } };
  public func channelTextOf(c : Nat8) : Text { switch (c) { case 1 "pos"; case 2 "atm"; case 3 "ecom"; case 4 "contactless"; case _ "?" } };
  func channelsByte(c : CT.Channels) : Nat8 { (if (c.pos) 1 else 0) | (if (c.atm) 2 else 0) | (if (c.ecom) 4 else 0) | (if (c.contactless) 8 else 0) | (if (c.international) 16 else 0) };
  func declineCode(r : CT.DeclineReason) : Nat8 {
    switch (r) {
      case (#unknownCard) 1; case (#cardNotActive) 2; case (#cardBlocked) 3; case (#cardExpired) 4; case (#mccDenied) 5; case (#channelDenied) 6; case (#internationalDenied) 7; case (#overPerTransaction) 8; case (#overDailyLimit) 9; case (#velocity) 10;
      case (#insufficientFunds) 11; case (#cryptogramInvalid) 12; case (#pinFailed) 13; case (#duplicate) 14; case (#unknownOriginal) 15; case (#originalNotOpen) 16; case (#amountExceedsOriginal) 17; case (#currencyMismatch) 18; case (#schemeMismatch) 19;
    }
  };
  public func declineOf(c : Nat8) : ?CT.DeclineReason {
    switch (c) {
      case 1 ?#unknownCard; case 2 ?#cardNotActive; case 3 ?#cardBlocked; case 4 ?#cardExpired; case 5 ?#mccDenied; case 6 ?#channelDenied; case 7 ?#internationalDenied; case 8 ?#overPerTransaction; case 9 ?#overDailyLimit; case 10 ?#velocity;
      case 11 ?#insufficientFunds; case 12 ?#cryptogramInvalid; case 13 ?#pinFailed; case 14 ?#duplicate; case 15 ?#unknownOriginal; case 16 ?#originalNotOpen; case 17 ?#amountExceedsOriginal; case 18 ?#currencyMismatch; case 19 ?#schemeMismatch; case _ null;
    }
  };
  func putInt(b : R.Buf, v : Int) { R.putByte(b, if (v < 0) 1 else 0); R.putNat(b, Int.abs(v), 8) };
  func getInt(a : [Nat8], off : Nat) : Int { let m = R.getNat(a, off + 1, 8); if (a[off] == 1) -m else m };

  // ─── rows ─────────────────────────────────────────────────────────────────

  public type CardRow = {
    id : CT.CardId; tokenHash : Blob; account : ProdT.AccountId; party : PT.PartyId; product : Text; form : CT.Form; state : CT.CardState; expiryMonth : Nat;
    controlsBlock : Nat; issuedDay : Nat; replaces : Nat; replacedBy : Nat; authorizations : Nat; declines : Nat; openHolds : Nat; heldAmount : Nat; clearedCount : Nat; clearedAmount : Nat; lastBlock : Nat;
    dailyLimit : Nat; perTransactionLimit : Nat; velocityCount : Nat; velocityWindowMinutes : Nat; channels : Nat8;
  };
  public type AuthRow = {
    id : CT.AuthId; card : Nat; kind : Nat8; amount : Nat; currency : Text; mcc : Nat; channel : Nat8; approved : Bool; decline : Nat8; hold : Nat; holdAmount : Nat; holdOpen : Bool; day : Nat; localTime : Nat64; original : Nat; refHash : Nat;
  };
  public type ClearedRow = { id : CT.ClearedId; card : Nat; auth : Nat; amount : Nat; currency : Text; mcc : Nat; interchange : Nat; fee : Nat; posting : Nat; day : Nat; outcome : Nat8; refund : Bool; disputed : Bool; fraud : Bool; scheme : Text };
  public type DisputeRow = { id : CT.DisputeId; transaction : Nat; card : Nat; stage : CT.DisputeStage; amount : Nat; provisional : Nat; dueDay : Nat; reasonHash : Nat; outcome : Nat8; finalAmount : Nat; openedDay : Nat; alerted : Bool };
  public type StatementRow = { card : Nat; cycleEnd : Nat; balance : Int; minimumDue : Nat; dueDay : Nat; purchases : Nat; payments : Nat; interest : Nat };
  public type SchemeRow = { id : Text; settlementAccount : Text; settlementCurrency : Text; floorLimit : Nat; holdDays : Nat; feeBps : Nat; connectorScheme : Nat8; keyHash : Blob; block : Nat };
  public type ProductRow = { id : Text; credit : Bool; statementDay : Nat; minimumDueBps : Nat; minimumDueFloor : Nat; graceDays : Nat; scheme : Text; issueFee : Nat; replacementFee : Nat; expiryMonths : Nat; block : Nat };

  func encodeCard(r : CardRow) : Blob {
    let b = R.buf();
    R.putBlob(b, r.tokenHash, 32); R.putNat(b, r.account, 8); R.putNat(b, r.party, 8); R.putText(b, r.product, 32); R.putByte(b, switch (r.form) { case (#physical) 1; case (#virtual) 2 }); R.putByte(b, stateCode(r.state)); R.putNat(b, r.expiryMonth, 4);
    R.putNat(b, r.controlsBlock, 8); R.putNat(b, r.issuedDay, 4); R.putNat(b, r.replaces, 8); R.putNat(b, r.replacedBy, 8); R.putNat(b, r.authorizations, 4); R.putNat(b, r.declines, 4); R.putNat(b, r.openHolds, 4); R.putNat(b, r.heldAmount, 8);
    R.putNat(b, r.clearedCount, 4); R.putNat(b, r.clearedAmount, 8); R.putNat(b, r.lastBlock, 8); R.putNat(b, r.dailyLimit, 8); R.putNat(b, r.perTransactionLimit, 8); R.putNat(b, r.velocityCount, 4); R.putNat(b, r.velocityWindowMinutes, 4); R.putByte(b, r.channels);
    R.done(b, CARD_ROW_BYTES)
  };
  func decodeCard(id : Nat, v : Blob) : CardRow {
    let a = Blob.toArray(v);
    { id; tokenHash = R.getBlob(a, 0, 32); account = R.getNat(a, 32, 8); party = R.getNat(a, 40, 8); product = R.getText(a, 48, 32); form = if (a[80] == 1) #physical else #virtual; state = stateOf(a[81]); expiryMonth = R.getNat(a, 82, 4);
      controlsBlock = R.getNat(a, 86, 8); issuedDay = R.getNat(a, 94, 4); replaces = R.getNat(a, 98, 8); replacedBy = R.getNat(a, 106, 8); authorizations = R.getNat(a, 114, 4); declines = R.getNat(a, 118, 4); openHolds = R.getNat(a, 122, 4); heldAmount = R.getNat(a, 126, 8);
      clearedCount = R.getNat(a, 134, 4); clearedAmount = R.getNat(a, 138, 8); lastBlock = R.getNat(a, 146, 8); dailyLimit = R.getNat(a, 154, 8); perTransactionLimit = R.getNat(a, 162, 8); velocityCount = R.getNat(a, 170, 4); velocityWindowMinutes = R.getNat(a, 174, 4); channels = a[178] }
  };
  func encodeAuth(r : AuthRow) : Blob {
    let b = R.buf();
    R.putNat(b, r.card, 8); R.putByte(b, r.kind); R.putNat(b, r.amount, 8); R.putText(b, r.currency, 8); R.putNat(b, r.mcc, 4); R.putByte(b, r.channel); R.putBool(b, r.approved); R.putByte(b, r.decline);
    R.putNat(b, r.hold, 8); R.putNat(b, r.holdAmount, 8); R.putBool(b, r.holdOpen); R.putNat(b, r.day, 4); R.putNat(b, Nat64.toNat(r.localTime), 8); R.putNat(b, r.original, 8); R.putNat(b, r.refHash, 8);
    R.done(b, AUTH_ROW_BYTES)
  };
  func decodeAuth(id : Nat, v : Blob) : AuthRow {
    let a = Blob.toArray(v);
    { id; card = R.getNat(a, 0, 8); kind = a[8]; amount = R.getNat(a, 9, 8); currency = R.getText(a, 17, 8); mcc = R.getNat(a, 25, 4); channel = a[29]; approved = R.getBool(a, 30); decline = a[31];
      hold = R.getNat(a, 32, 8); holdAmount = R.getNat(a, 40, 8); holdOpen = R.getBool(a, 48); day = R.getNat(a, 49, 4); localTime = Nat64.fromNat(R.getNat(a, 53, 8)); original = R.getNat(a, 61, 8); refHash = R.getNat(a, 69, 8) }
  };
  func encodeCleared(r : ClearedRow) : Blob {
    let b = R.buf();
    R.putNat(b, r.card, 8); R.putNat(b, r.auth, 8); R.putNat(b, r.amount, 8); R.putText(b, r.currency, 8); R.putNat(b, r.mcc, 4); R.putNat(b, r.interchange, 8); R.putNat(b, r.fee, 8); R.putNat(b, r.posting, 8); R.putNat(b, r.day, 4);
    R.putByte(b, r.outcome); R.putBool(b, r.refund); R.putBool(b, r.disputed); R.putBool(b, r.fraud); R.putText(b, r.scheme, 8);
    R.done(b, CLEARED_ROW_BYTES)
  };
  func decodeCleared(id : Nat, v : Blob) : ClearedRow {
    let a = Blob.toArray(v);
    { id; card = R.getNat(a, 0, 8); auth = R.getNat(a, 8, 8); amount = R.getNat(a, 16, 8); currency = R.getText(a, 24, 8); mcc = R.getNat(a, 32, 4); interchange = R.getNat(a, 36, 8); fee = R.getNat(a, 44, 8); posting = R.getNat(a, 52, 8); day = R.getNat(a, 60, 4);
      outcome = a[64]; refund = R.getBool(a, 65); disputed = R.getBool(a, 66); fraud = R.getBool(a, 67); scheme = R.getText(a, 68, 8) }
  };
  func encodeDispute(r : DisputeRow) : Blob {
    let b = R.buf();
    R.putNat(b, r.transaction, 8); R.putNat(b, r.card, 8); R.putByte(b, stageCode(r.stage)); R.putNat(b, r.amount, 8); R.putNat(b, r.provisional, 8); R.putNat(b, r.dueDay, 4); R.putNat(b, r.reasonHash, 8); R.putByte(b, r.outcome); R.putNat(b, r.finalAmount, 8); R.putNat(b, r.openedDay, 4); R.putBool(b, r.alerted);
    R.done(b, DISPUTE_ROW_BYTES)
  };
  func decodeDispute(id : Nat, v : Blob) : DisputeRow {
    let a = Blob.toArray(v);
    { id; transaction = R.getNat(a, 0, 8); card = R.getNat(a, 8, 8); stage = stageOf(a[16]); amount = R.getNat(a, 17, 8); provisional = R.getNat(a, 25, 8); dueDay = R.getNat(a, 33, 4); reasonHash = R.getNat(a, 37, 8); outcome = a[45]; finalAmount = R.getNat(a, 46, 8); openedDay = R.getNat(a, 54, 4); alerted = R.getBool(a, 58) }
  };
  func encodeStatement(r : StatementRow) : Blob { let b = R.buf(); putInt(b, r.balance); R.putNat(b, r.minimumDue, 8); R.putNat(b, r.dueDay, 4); R.putNat(b, r.purchases, 8); R.putNat(b, r.payments, 8); R.putNat(b, r.interest, 8); R.done(b, STATEMENT_ROW_BYTES) };
  func decodeStatement(card : Nat, cycleEnd : Nat, v : Blob) : StatementRow {
    let a = Blob.toArray(v);
    { card; cycleEnd; balance = getInt(a, 0); minimumDue = R.getNat(a, 9, 8); dueDay = R.getNat(a, 17, 4); purchases = R.getNat(a, 21, 8); payments = R.getNat(a, 29, 8); interest = R.getNat(a, 37, 8) }
  };
  func encodeScheme(r : SchemeRow) : Blob {
    let b = R.buf();
    R.putText(b, r.settlementAccount, 32); R.putText(b, r.settlementCurrency, 8); R.putNat(b, r.floorLimit, 8); R.putNat(b, r.holdDays, 4); R.putNat(b, r.feeBps, 4); R.putByte(b, r.connectorScheme); R.putBlob(b, r.keyHash, 32); R.putNat(b, r.block, 8);
    R.done(b, SCHEME_ROW_BYTES)
  };
  func decodeScheme(id : Text, v : Blob) : SchemeRow {
    let a = Blob.toArray(v);
    { id; settlementAccount = R.getText(a, 0, 32); settlementCurrency = R.getText(a, 32, 8); floorLimit = R.getNat(a, 40, 8); holdDays = R.getNat(a, 48, 4); feeBps = R.getNat(a, 52, 4); connectorScheme = a[56]; keyHash = R.getBlob(a, 57, 32); block = R.getNat(a, 89, 8) }
  };
  func encodeProduct(r : ProductRow) : Blob {
    let b = R.buf();
    R.putBool(b, r.credit); R.putNat(b, r.statementDay, 4); R.putNat(b, r.minimumDueBps, 4); R.putNat(b, r.minimumDueFloor, 8); R.putNat(b, r.graceDays, 4); R.putText(b, r.scheme, 16); R.putNat(b, r.issueFee, 8); R.putNat(b, r.replacementFee, 8); R.putNat(b, r.expiryMonths, 4); R.putNat(b, r.block, 8);
    R.done(b, PRODUCT_ROW_BYTES)
  };
  func decodeProduct(id : Text, v : Blob) : ProductRow {
    let a = Blob.toArray(v);
    { id; credit = R.getBool(a, 0); statementDay = R.getNat(a, 1, 4); minimumDueBps = R.getNat(a, 5, 4); minimumDueFloor = R.getNat(a, 9, 8); graceDays = R.getNat(a, 17, 4); scheme = R.getText(a, 21, 16); issueFee = R.getNat(a, 37, 8); replacementFee = R.getNat(a, 45, 8); expiryMonths = R.getNat(a, 53, 4); block = R.getNat(a, 57, 8) }
  };

  // ─── state ────────────────────────────────────────────────────────────────

  public type State = {
    cards : RI.State;          // id(8) -> row
    byToken : RI.State;        // sha256(token)(32) -> id(8)
    byAccount : RI.State;      // account(8) ‖ id(8)
    byParty : RI.State;        // party(8) ‖ id(8)
    byState : RI.State;        // state(1) ‖ id(8)
    auths : RI.State;          // id(8) -> row
    byCardDay : RI.State;      // card(8) ‖ day(4) ‖ id(8)
    byHold : RI.State;         // hold(8) -> auth(8)
    byRef : RI.State;          // refHash(8) ‖ day(4) -> auth(8)
    cleared : RI.State;        // id(8) -> row
    clearedByCard : RI.State;  // card(8) ‖ id(8)
    batches : RI.State;        // sha256(32) -> block(8)
    disputes : RI.State;       // id(8) -> row
    byStage : RI.State;        // stage(1) ‖ id(8)
    statements : RI.State;     // card(8) ‖ cycleEnd(4) -> row
    schemes : RI.State;        // id(16) -> row
    products : RI.State;       // id(32) -> row
    subledgers : RI.State;
    var policy : ?CT.Policy;
    var issued : Nat;
    var active : Nat;
    var authorizations : Nat;
    var approved : Nat;
    var declined : Nat;
    var openHolds : Nat;
    var clearedCount : Nat;
    var exceptions : Nat;
    var disputesTotal : Nat;
    var disputesOpen : Nat;
    var statementCount : Nat;
    var schemeCount : Nat;
    var productCount : Nat;
  };

  public func newState(arena : RI.Arena) : State {
    {
      cards = RI.newStateIn(arena, { keyBytes = 8; valBytes = CARD_ROW_BYTES });
      byToken = RI.newStateIn(arena, { keyBytes = 32; valBytes = 8 });
      byAccount = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      byParty = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      byState = RI.newStateIn(arena, { keyBytes = 9; valBytes = 1 });
      auths = RI.newStateIn(arena, { keyBytes = 8; valBytes = AUTH_ROW_BYTES });
      byCardDay = RI.newStateIn(arena, { keyBytes = 20; valBytes = 1 });
      byHold = RI.newStateIn(arena, { keyBytes = 8; valBytes = 8 });
      byRef = RI.newStateIn(arena, { keyBytes = 12; valBytes = 8 });
      cleared = RI.newStateIn(arena, { keyBytes = 8; valBytes = CLEARED_ROW_BYTES });
      clearedByCard = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      batches = RI.newStateIn(arena, { keyBytes = 32; valBytes = 8 });
      disputes = RI.newStateIn(arena, { keyBytes = 8; valBytes = DISPUTE_ROW_BYTES });
      byStage = RI.newStateIn(arena, { keyBytes = 9; valBytes = 1 });
      statements = RI.newStateIn(arena, { keyBytes = 12; valBytes = STATEMENT_ROW_BYTES });
      schemes = RI.newStateIn(arena, { keyBytes = 16; valBytes = SCHEME_ROW_BYTES });
      products = RI.newStateIn(arena, { keyBytes = 32; valBytes = PRODUCT_ROW_BYTES });
      subledgers = RI.newStateIn(arena, { keyBytes = 32; valBytes = 1 });
      var policy = null; var issued = 0; var active = 0; var authorizations = 0; var approved = 0; var declined = 0; var openHolds = 0; var clearedCount = 0; var exceptions = 0;
      var disputesTotal = 0; var disputesOpen = 0; var statementCount = 0; var schemeCount = 0; var productCount = 0;
    }
  };

  public func policy(s : State) : ?CT.Policy { s.policy };
  public func card(s : State, id : CT.CardId) : ?CardRow { switch (RI.get(s.cards, R.key(id, 8))) { case (?v) ?decodeCard(id, v); case null null } };
  public func cardByToken(s : State, token : CT.Token) : ?CardRow { switch (RI.get(s.byToken, tokenHash(token))) { case (?v) card(s, R.getNat(Blob.toArray(v), 0, 8)); case null null } };
  public func auth(s : State, id : CT.AuthId) : ?AuthRow { switch (RI.get(s.auths, R.key(id, 8))) { case (?v) ?decodeAuth(id, v); case null null } };
  public func authByCode(s : State, code : Text) : ?AuthRow { switch (authIdOf(code)) { case (?id) auth(s, id); case null null } };
  public func authOfHold(s : State, hold : Nat) : ?AuthRow { switch (RI.get(s.byHold, R.key(hold, 8))) { case (?v) auth(s, R.getNat(Blob.toArray(v), 0, 8)); case null null } };
  public func clearedRow(s : State, id : CT.ClearedId) : ?ClearedRow { switch (RI.get(s.cleared, R.key(id, 8))) { case (?v) ?decodeCleared(id, v); case null null } };
  public func dispute(s : State, id : CT.DisputeId) : ?DisputeRow { switch (RI.get(s.disputes, R.key(id, 8))) { case (?v) ?decodeDispute(id, v); case null null } };
  public func statement(s : State, cardId : Nat, cycleEnd : Nat) : ?StatementRow { switch (RI.get(s.statements, R.key2(cardId, 8, cycleEnd, 4))) { case (?v) ?decodeStatement(cardId, cycleEnd, v); case null null } };
  public func scheme(s : State, id : Text) : ?SchemeRow { switch (RI.get(s.schemes, R.textKey(id, 16))) { case (?v) ?decodeScheme(id, v); case null null } };
  public func product(s : State, id : Text) : ?ProductRow { switch (RI.get(s.products, R.textKey(id, 32))) { case (?v) ?decodeProduct(id, v); case null null } };
  public func batchKnown(s : State, hash : Blob) : Bool { hash.size() == 32 and RI.get(s.batches, hash) != null };
  func putCard(s : State, r : CardRow) { ignore RI.put(s.cards, R.key(r.id, 8), encodeCard(r)) };
  func putAuth(s : State, r : AuthRow) { ignore RI.put(s.auths, R.key(r.id, 8), encodeAuth(r)) };
  func putCleared(s : State, r : ClearedRow) { ignore RI.put(s.cleared, R.key(r.id, 8), encodeCleared(r)) };
  func putDispute(s : State, r : DisputeRow) { ignore RI.put(s.disputes, R.key(r.id, 8), encodeDispute(r)) };

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
  /// The approved authorizations of a card on a day, ascending.
  public func authsOfCardDay(s : State, cardId : Nat, day : Nat) : [AuthRow] {
    let lo = R.key2(cardId, 8, day, 4); let lo20 = Blob.fromArray(Array.concat<Nat8>(Blob.toArray(lo), Array.repeat<Nat8>(0, 8))); let hi20 = Blob.fromArray(Array.concat<Nat8>(Blob.toArray(lo), Array.repeat<Nat8>(255, 8)));
    Array.filterMap<Nat, AuthRow>(idsUnder(s.byCardDay, lo20, hi20, 12), func(id) { auth(s, id) })
  };
  public func cardsOfAccount(s : State, account : Nat) : [CardRow] { let (lo, hi) = R.prefixRange(account, 8, 8); Array.filterMap<Nat, CardRow>(idsUnder(s.byAccount, lo, hi, 8), func(id) { card(s, id) }) };
  public func cardsOfParty(s : State, party : Nat) : [CardRow] { let (lo, hi) = R.prefixRange(party, 8, 8); Array.filterMap<Nat, CardRow>(idsUnder(s.byParty, lo, hi, 8), func(id) { card(s, id) }) };
  public func cardsInState(s : State, st : CT.CardState) : [CardRow] {
    let (lo, hi) = R.prefixRange(Nat8.toNat(stateCode(st)), 1, 8);
    Array.filter<CardRow>(Array.filterMap<Nat, CardRow>(idsUnder(s.byState, lo, hi, 1), func(id) { card(s, id) }), func(r) { r.state == st })
  };
  public func clearedOfCard(s : State, cardId : Nat) : [ClearedRow] { let (lo, hi) = R.prefixRange(cardId, 8, 8); Array.filterMap<Nat, ClearedRow>(idsUnder(s.clearedByCard, lo, hi, 8), func(id) { clearedRow(s, id) }) };
  public func disputesInStage(s : State, st : CT.DisputeStage) : [DisputeRow] {
    let (lo, hi) = R.prefixRange(Nat8.toNat(stageCode(st)), 1, 8);
    Array.filter<DisputeRow>(Array.filterMap<Nat, DisputeRow>(idsUnder(s.byStage, lo, hi, 1), func(id) { dispute(s, id) }), func(d) { d.stage == st })
  };
  public func openDisputes(s : State) : [DisputeRow] {
    var out : [DisputeRow] = [];
    for (st in [#opened, #provisionalCredit, #chargeback, #representment, #preArbitration].vals()) out := Array.concat(out, disputesInStage(s, st));
    out
  };
  /// The open holds of a card: its approved authorizations whose pending is still open.
  /// The card's authorizations with an open hold over `[from, to]`: one range scan of the card/day index (never a walk
  /// day by day), the window clipped to a year — a hold lives at most the scheme's 31 days.
  public func openHoldsOf(s : State, cardId : Nat, from : Nat, to : Nat) : [AuthRow] {
    if (to < from) return [];
    let hiDay = Nat.min(to, from + 366);
    let lo = Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.key2(cardId, 8, from, 4)), Array.repeat<Nat8>(0, 8)));
    let hi = Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.key2(cardId, 8, hiDay, 4)), Array.repeat<Nat8>(255, 8)));
    Array.filter<AuthRow>(Array.filterMap<Nat, AuthRow>(idsUnder(s.byCardDay, lo, hi, 12), func(id) { auth(s, id) }), func(a) { a.holdOpen })
  };

  // ─── validation ───────────────────────────────────────────────────────────

  type Res<X> = Result.Result<X, CT.CardError>;
  func bad<X>(reason : Text) : Res<X> { #err(#InvalidTerms({ reason })) };
  func bytesOf(t : Text) : Nat { Text.encodeUtf8(t).size() };

  public func accountsOf(p : CT.Policy) : [Text] { [p.disputeSuspense, p.interchangeIncome, p.schemeFees, p.fraudLosses, p.cardFeeIncome] };
  public func planPolicy(p : CT.Policy) : Res<CT.CardEvent> {
    for (a in accountsOf(p).vals()) { if (bytesOf(a) == 0) return #err(#InvalidPolicy({ reason = "every role account is named" })) };
    if (p.stanReplayDays == 0 or p.stanReplayDays > 30) return #err(#InvalidPolicy({ reason = "stanReplayDays in 1..30" }));
    #ok(#policySet(p))
  };
  public func planDeclareScheme(s : State, sc : CT.Scheme, day : Nat) : Res<CT.CardEvent> {
    if (bytesOf(sc.id) == 0 or bytesOf(sc.id) > 16) return bad("a scheme id is 1..16 bytes");
    if (scheme(s, sc.id) != null) return bad("scheme " # sc.id # " is already declared");
    if (bytesOf(sc.settlementAccount) == 0 or bytesOf(sc.settlementCurrency) != 3) return bad("the settlement account and its three-letter currency are named");
    let r = sc.rules;
    if (bytesOf(r.source) == 0) return bad("the rules name their source");
    if (r.holdDays == 0 or r.holdDays > 31) return bad("holdDays in 1..31");
    if (r.interchange.size() > MAX_LIST or r.reasons.size() > MAX_LIST) return bad("at most " # Nat.toText(MAX_LIST) # " interchange bands and reason codes");
    for (b in r.interchange.vals()) { if (b.mccFrom > b.mccTo or b.mccTo > 9999 or b.bps > 10_000) return bad("an interchange band is mccFrom ≤ mccTo ≤ 9999 with bps ≤ 10000") };
    for (rr in r.reasons.vals()) { if (bytesOf(rr.code) == 0 or bytesOf(rr.code) > 8 or rr.chargebackDays == 0) return bad("a reason code is 1..8 bytes with a chargeback window") };
    if (r.feeBps > 10_000) return bad("the scheme fee is at most 100 %");
    switch (sc.connectorScheme) { case (#none) {}; case (_) { if (sc.connectorKey.size() == 0) return bad("a signing scheme needs the connector's key") } };
    #ok(#schemeDeclared({ scheme = sc; day }))
  };
  func controlsWithinBounds(c : CT.Controls, b : CT.Controls) : ?Text {
    if (c.dailyLimit > b.dailyLimit) return ?"dailyLimit";
    if (c.perTransactionLimit > b.perTransactionLimit) return ?"perTransactionLimit";
    if (c.velocityCount > b.velocityCount) return ?"velocityCount";
    if (c.mccAllow.size() > MAX_LIST or c.mccDeny.size() > MAX_LIST) return ?"mccLists";
    for (m in c.mccAllow.vals()) { if (m > 9999) return ?"mccAllow" };
    for (m in c.mccDeny.vals()) { if (m > 9999) return ?"mccDeny" };
    if (c.channels.pos and not b.channels.pos) return ?"channels.pos";
    if (c.channels.atm and not b.channels.atm) return ?"channels.atm";
    if (c.channels.ecom and not b.channels.ecom) return ?"channels.ecom";
    if (c.channels.contactless and not b.channels.contactless) return ?"channels.contactless";
    if (c.channels.international and not b.channels.international) return ?"channels.international";
    null
  };
  public func planDefineProduct(s : State, p : CT.CardProduct, day : Nat) : Res<CT.CardEvent> {
    if (bytesOf(p.id) == 0 or bytesOf(p.id) > 32) return bad("a product id is 1..32 bytes");
    if (product(s, p.id) != null) return bad("card product " # p.id # " is already defined");
    if (scheme(s, p.scheme) == null) return #err(#UnknownScheme({ scheme = p.scheme }));
    if (p.expiryMonths == 0 or p.expiryMonths > 120) return bad("expiryMonths in 1..120");
    if (p.bounds.perTransactionLimit == 0 or p.bounds.dailyLimit == 0) return bad("the bounds carry positive limits");
    if (p.bounds.mccAllow.size() > MAX_LIST or p.bounds.mccDeny.size() > MAX_LIST) return bad("at most " # Nat.toText(MAX_LIST) # " MCCs a list");
    switch (p.kind) {
      case (#credit(c)) { if (c.statementDay == 0 or c.statementDay > 28) return bad("statementDay in 1..28"); if (c.minimumDueBps > 10_000) return bad("minimumDueBps ≤ 10000"); if (c.graceDays > 60) return bad("graceDays ≤ 60") };
      case (#debit) {};
    };
    #ok(#productDefined({ product = p; day }))
  };
  /// Issue: the token's digest must be new, the product known, the controls within its bounds.
  public func planIssue(s : State, token : CT.Token, account : ProdT.AccountId, party : PT.PartyId, productId : Text, form : CT.Form, controls : CT.Controls, bounds : CT.Controls, day : Nat, expiryMonth : Nat, replaces : ?CT.CardId) : Res<CT.CardEvent> {
    if (token.size() < 8 or token.size() > 32) return bad("a token is 8..32 bytes");
    if (cardByToken(s, token) != null) return bad("a card with this token exists");
    if (product(s, productId) == null) return #err(#UnknownProduct({ product = productId }));
    switch (controlsWithinBounds(controls, bounds)) { case (?f) return #err(#ControlsOutsideBounds({ field = f })); case null {} };
    switch (replaces) { case (?old) { switch (card(s, old)) { case null return #err(#UnknownCard({ card = old })); case (?r) { if (r.state == #closed) return #err(#CardNotIn({ card = old; state = "closed"; wanted = "issued|active|blocked" })) } } }; case null {} };
    #ok(#cardIssued({ tokenHash = tokenHash(token); account; party; product = productId; form; expiryMonth; controls; day; replaces }))
  };
  func cardIn(s : State, id : CT.CardId, wanted : [CT.CardState], wantedText : Text) : Res<CardRow> {
    let ?r = card(s, id) else return #err(#UnknownCard({ card = id }));
    for (w in wanted.vals()) { if (r.state == w) return #ok(r) };
    #err(#CardNotIn({ card = id; state = CT.stateText(r.state); wanted = wantedText }))
  };
  public func planActivate(s : State, id : CT.CardId, day : Nat) : Res<CT.CardEvent> { switch (cardIn(s, id, [#issued], "issued")) { case (#err(e)) #err(e); case (#ok(_)) #ok(#cardActivated({ card = id; day })) } };
  public func planBlock(s : State, id : CT.CardId, reason : CT.BlockReason, day : Nat) : Res<CT.CardEvent> { switch (cardIn(s, id, [#issued, #active], "issued|active")) { case (#err(e)) #err(e); case (#ok(_)) #ok(#cardBlocked({ card = id; reason; day })) } };
  public func planUnblock(s : State, id : CT.CardId, day : Nat) : Res<CT.CardEvent> { switch (cardIn(s, id, [#blocked], "blocked")) { case (#err(e)) #err(e); case (#ok(_)) #ok(#cardUnblocked({ card = id; day })) } };
  public func planClose(s : State, id : CT.CardId, reason : Text, day : Nat) : Res<CT.CardEvent> {
    let r = switch (cardIn(s, id, [#issued, #active, #blocked], "not closed")) { case (#err(e)) return #err(e); case (#ok(r)) r };
    if (r.openHolds > 0) return #err(#Busy({ reason = Nat.toText(r.openHolds) # " holds are open on the card" }));
    if (bytesOf(reason) == 0 or bytesOf(reason) > 128) return bad("a closure states its reason in 1..128 bytes");
    #ok(#cardClosed({ card = id; reason; day }))
  };
  public func planSetControls(s : State, id : CT.CardId, controls : CT.Controls, bounds : CT.Controls, byCustomer : Bool, day : Nat) : Res<CT.CardEvent> {
    switch (cardIn(s, id, [#issued, #active, #blocked], "not closed")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (controlsWithinBounds(controls, bounds)) { case (?f) return #err(#ControlsOutsideBounds({ field = f })); case null {} };
    #ok(#controlsSet({ card = id; controls; byCustomer; day }))
  };

  // ─── the decision engine ───────────────────────────────────────────────────

  public type Facts = { available : Nat; today : Nat; nowNs : Nat64; bounds : CT.Controls; controls : CT.Controls; rules : CT.SchemeRules; productScheme : Text; settlementCurrency : Text };
  func mccIn(list : [CT.Mcc], m : CT.Mcc) : Bool { for (x in list.vals()) { if (x == m) return true }; false };
  func channelAllowed(c : CT.Channels, ch : CT.Channel) : Bool { switch (ch) { case (#pos) c.pos; case (#atm) c.atm; case (#ecom) c.ecom; case (#contactless) c.contactless } };
  public func refHashOf(acquirer : Text, stan : Text, rrn : Text) : Nat { hash8(acquirer # "/" # stan # "/" # rrn) };
  func duplicate(s : State, req : CT.AuthRequest, today : Nat, replayDays : Nat) : Bool {
    let h = refHashOf(req.acquirer, req.stan, req.rrn);
    var d = if (today >= replayDays) today - replayDays else 0;
    while (d <= today) { if (RI.get(s.byRef, R.key2(h, 8, d, 4)) != null) return true; d += 1 };
    false
  };
  /// The decision: the card's state, the HSM's verdicts, the controls, the day's sums and the window's count over
  /// the approved authorizations already recorded, the availability the journal reports. A decline names its first
  /// reason in this order, which the battery's engine follows.
  public func decide(s : State, req : CT.AuthRequest, r : ?CardRow, f : Facts, replayDays : Nat) : CT.Decision {
    let ?c = r else return #declined(#unknownCard);
    if (duplicate(s, req, f.today, replayDays)) return #declined(#duplicate);
    switch (c.state) { case (#active) {}; case (#issued) return #declined(#cardNotActive); case (#blocked) return #declined(#cardBlocked); case (#closed) return #declined(#cardBlocked) };
    // the expiry month counts from the epoch: the request is good through the last day of that month
    if (monthOf(f.today) > c.expiryMonth) return #declined(#cardExpired);
    if (not req.cryptogramValid) return #declined(#cryptogramInvalid);
    switch (req.pinVerified) { case (?false) return #declined(#pinFailed); case (_) {} };
    if (not Text.equal(req.currency, f.settlementCurrency)) return #declined(#currencyMismatch);
    switch (req.kind) {
      case (#reversal(of) or #completion(of) or #incremental(of)) {
        let ?o = auth(s, of.of) else return #declined(#unknownOriginal);
        if (not o.approved or o.card != c.id) return #declined(#unknownOriginal);
        switch (req.kind) {
          case (#reversal(_)) { if (not o.holdOpen) return #declined(#originalNotOpen); if (req.amount > o.holdAmount) return #declined(#amountExceedsOriginal); return #approved({ authCode = authCodeOf(of.of); hold = ?o.hold; amount = req.amount }) };
          case (#completion(_)) { if (not o.holdOpen) return #declined(#originalNotOpen); if (req.amount > o.holdAmount) return #declined(#amountExceedsOriginal); return #approved({ authCode = authCodeOf(of.of); hold = ?o.hold; amount = req.amount }) };
          case (_) { if (not o.holdOpen) return #declined(#originalNotOpen) };
        };
      };
      case (_) {};
    };
    if (req.kind != #refund) {
      if (f.controls.mccDeny.size() > 0 and mccIn(f.controls.mccDeny, req.mcc)) return #declined(#mccDenied);
      if (f.controls.mccAllow.size() > 0 and not mccIn(f.controls.mccAllow, req.mcc)) return #declined(#mccDenied);
      if (f.bounds.mccDeny.size() > 0 and mccIn(f.bounds.mccDeny, req.mcc)) return #declined(#mccDenied);
      if (not channelAllowed(f.controls.channels, req.channel)) return #declined(#channelDenied);
      if (not f.controls.channels.international and not Text.equal(req.merchantCountry, "EG")) return #declined(#internationalDenied);
      if (req.amount > f.controls.perTransactionLimit) return #declined(#overPerTransaction);
      let today = authsOfCardDay(s, c.id, f.today);
      var daySum = 0; var inWindow = 0;
      let windowNs = Nat64.fromNat(f.controls.velocityWindowMinutes) * MINUTE_NS;
      for (a in today.vals()) {
        if (a.approved and (a.kind == 1 or a.kind == 2 or a.kind == 3)) {
          daySum += a.amount;
          if (f.controls.velocityWindowMinutes > 0 and a.localTime + windowNs > req.localTime and a.localTime <= req.localTime) inWindow += 1;
        };
      };
      // the window can reach into yesterday
      if (f.controls.velocityWindowMinutes > 0 and f.today > 0) {
        for (a in authsOfCardDay(s, c.id, f.today - 1).vals()) { if (a.approved and (a.kind == 1 or a.kind == 2 or a.kind == 3) and a.localTime + windowNs > req.localTime and a.localTime <= req.localTime) inWindow += 1 };
      };
      if (daySum + req.amount > f.controls.dailyLimit) return #declined(#overDailyLimit);
      if (f.controls.velocityCount > 0 and inWindow + 1 > f.controls.velocityCount) return #declined(#velocity);
      if (req.amount > f.available) return #declined(#insufficientFunds);
    };
    #approved({ authCode = ""; hold = null; amount = req.amount })   // the code and the hold are the block's and the journal's; the caller fills them
  };
  /// The month index of a day (months since the epoch), the unit card expiries are recorded in.
  public func monthOf(day : Nat) : Nat { let (y, m, _) = toCivil(day); (y - 1970) * 12 + (m - 1) };
  func toCivil(day : Nat) : (Nat, Nat, Nat) {
    // Howard Hinnant's civil-from-days, for days since 1970-01-01
    let z = day + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if (mp < 10) mp + 3 else mp - 9;
    (if (m <= 2) y + 1 else y, m, d)
  };
  public func interchangeOf(rules : CT.SchemeRules, mcc : CT.Mcc, amount : Nat) : Nat {
    for (b in rules.interchange.vals()) { if (mcc >= b.mccFrom and mcc <= b.mccTo) return amount * b.bps / 10_000 + b.fixed };
    0
  };
  public func feeOf(rules : CT.SchemeRules, amount : Nat) : Nat { amount * rules.feeBps / 10_000 };
  public func reasonRule(rules : CT.SchemeRules, code : Text) : ?CT.ReasonRule { for (r in rules.reasons.vals()) { if (Text.equal(r.code, code)) return ?r }; null };

  // ─── disputes and fraud ───────────────────────────────────────────────────

  public func planOpenDispute(s : State, transaction : CT.ClearedId, reason : Text, amount : Nat, rules : CT.SchemeRules, day : Nat) : Res<CT.CardEvent> {
    let ?t = clearedRow(s, transaction) else return #err(#UnknownTransaction({ transaction }));
    if (t.card == 0) return bad("the transaction has no card");
    if (t.disputed) return bad("the transaction is already disputed");
    if (amount == 0 or amount > t.amount) return bad("the disputed amount is positive and at most the transaction's");
    let ?rr = reasonRule(rules, reason) else return #err(#UnknownReason({ code = reason }));
    if (day > t.day + rr.chargebackDays) return bad("the chargeback window of " # Nat.toText(rr.chargebackDays) # " days from the transaction has passed");
    #ok(#disputeOpened({ transaction; card = t.card; reason; amount; dueDay = t.day + rr.chargebackDays; day }))
  };
  func disputeIn(s : State, id : CT.DisputeId, wanted : [CT.DisputeStage], text : Text) : Res<DisputeRow> {
    let ?d = dispute(s, id) else return #err(#UnknownDispute({ dispute = id }));
    for (w in wanted.vals()) { if (d.stage == w) return #ok(d) };
    #err(#DisputeNotIn({ dispute = id; stage = CT.stageText(d.stage); wanted = text }))
  };
  public func planProvisionalCredit(s : State, id : CT.DisputeId, day : Nat) : Res<(CT.CardEvent, DisputeRow)> {
    let d = switch (disputeIn(s, id, [#opened], "opened")) { case (#err(e)) return #err(e); case (#ok(d)) d };
    #ok((#provisionalCredited({ dispute = id; amount = d.amount; day }), d))
  };
  public func planChargeback(s : State, id : CT.DisputeId, schemeRef : Text, rules : CT.SchemeRules, reason : Text, day : Nat) : Res<(CT.CardEvent, DisputeRow)> {
    let d = switch (disputeIn(s, id, [#opened, #provisionalCredit], "opened|provisionalCredit")) { case (#err(e)) return #err(e); case (#ok(d)) d };
    if (bytesOf(schemeRef) == 0 or bytesOf(schemeRef) > 35) return bad("the scheme's case reference is 1..35 bytes");
    let ?rr = reasonRule(rules, reason) else return #err(#UnknownReason({ code = reason }));
    #ok((#chargebackRaised({ dispute = id; schemeRef; dueDay = day + rr.representmentDays; day }), d))
  };
  public func planRepresentment(s : State, id : CT.DisputeId, rules : CT.SchemeRules, reason : Text, day : Nat) : Res<(CT.CardEvent, DisputeRow)> {
    let d = switch (disputeIn(s, id, [#chargeback], "chargeback")) { case (#err(e)) return #err(e); case (#ok(d)) d };
    let ?rr = reasonRule(rules, reason) else return #err(#UnknownReason({ code = reason }));
    #ok((#representmentRecorded({ dispute = id; dueDay = day + rr.preArbitrationDays; day }), d))
  };
  public func planPreArbitration(s : State, id : CT.DisputeId, rules : CT.SchemeRules, reason : Text, day : Nat) : Res<(CT.CardEvent, DisputeRow)> {
    let d = switch (disputeIn(s, id, [#representment], "representment")) { case (#err(e)) return #err(e); case (#ok(d)) d };
    let ?rr = reasonRule(rules, reason) else return #err(#UnknownReason({ code = reason }));
    #ok((#preArbitrationRecorded({ dispute = id; dueDay = day + rr.preArbitrationDays; day }), d))
  };
  public func planResolve(s : State, id : CT.DisputeId, outcome : CT.Outcome, finalAmount : Nat, day : Nat) : Res<(CT.CardEvent, DisputeRow)> {
    let d = switch (disputeIn(s, id, [#opened, #provisionalCredit, #chargeback, #representment, #preArbitration], "open")) { case (#err(e)) return #err(e); case (#ok(d)) d };
    if (finalAmount > d.amount) return bad("the final amount is at most the disputed amount");
    #ok((#disputeResolved({ dispute = id; outcome; finalAmount; day }), d))
  };
  public func planMarkFraud(s : State, transaction : CT.ClearedId, blockCard : Bool, day : Nat) : Res<CT.CardEvent> {
    let ?t = clearedRow(s, transaction) else return #err(#UnknownTransaction({ transaction }));
    if (t.card == 0) return bad("the transaction has no card");
    if (t.fraud) return bad("the transaction is already marked");
    #ok(#fraudMarked({ transaction; card = t.card; blocked = blockCard; day }))
  };
  /// Disputes whose current step is due on or before `day` and not yet reported.
  public func dueDisputes(s : State, day : Nat) : [CT.CardEvent] {
    let out = List.empty<CT.CardEvent>();
    for (d in openDisputes(s).vals()) { if (not d.alerted and d.dueDay <= day) List.add(out, #disputeStepDue({ dispute = d.id; stage = d.stage; dueDay = d.dueDay; day })) };
    List.toArray(out)
  };

  // ─── the fold ──────────────────────────────────────────────────────────────

  func withState(s : State, r : CardRow, st : CT.CardState, block : Nat) : CardRow {
    ignore RI.put(s.byState, R.key2(Nat8.toNat(stateCode(st)), 1, r.id, 8), Blob.fromArray([1]));
    if (r.state != #active and st == #active) s.active += 1;
    if (r.state == #active and st != #active) s.active -= 1;
    { r with state = st; lastBlock = block }
  };
  func withControls(r : CardRow, c : CT.Controls, block : Nat) : CardRow {
    { r with controlsBlock = block; dailyLimit = c.dailyLimit; perTransactionLimit = c.perTransactionLimit; velocityCount = c.velocityCount; velocityWindowMinutes = c.velocityWindowMinutes; channels = channelsByte(c.channels); lastBlock = block }
  };
  func withDisputeStage(s : State, d : DisputeRow, st : CT.DisputeStage, dueDay : Nat) : DisputeRow {
    ignore RI.put(s.byStage, R.key2(Nat8.toNat(stageCode(st)), 1, d.id, 8), Blob.fromArray([1]));
    if (st == #resolved and d.stage != #resolved) s.disputesOpen -= 1;
    { d with stage = st; dueDay; alerted = false }
  };

  public func fold(s : State, block : Nat, ev : CT.CardEvent) {
    switch (ev) {
      case (#policySet(p)) s.policy := ?p;
      case (#schemeDeclared(x)) {
        let sc = x.scheme;
        ignore RI.put(s.schemes, R.textKey(sc.id, 16), encodeScheme({ id = sc.id; settlementAccount = sc.settlementAccount; settlementCurrency = sc.settlementCurrency; floorLimit = sc.rules.floorLimit; holdDays = sc.rules.holdDays; feeBps = sc.rules.feeBps;
                                                                      connectorScheme = switch (sc.connectorScheme) { case (#none) 0; case (#mayo2) 1; case (#mldsa44) 2 }; keyHash = Sha256.fromBlob(#sha256, sc.connectorKey); block }));
        s.schemeCount += 1;
      };
      case (#productDefined(x)) {
        let p = x.product;
        let (credit, sd, mdb, mdf, gd) = switch (p.kind) { case (#credit(c)) (true, c.statementDay, c.minimumDueBps, c.minimumDueFloor, c.graceDays); case (#debit) (false, 0, 0, 0, 0) };
        ignore RI.put(s.products, R.textKey(p.id, 32), encodeProduct({ id = p.id; credit; statementDay = sd; minimumDueBps = mdb; minimumDueFloor = mdf; graceDays = gd; scheme = p.scheme; issueFee = p.issueFee; replacementFee = p.replacementFee; expiryMonths = p.expiryMonths; block }));
        s.productCount += 1;
      };
      case (#cardIssued(x)) {
        let r : CardRow = withControls({
          id = block; tokenHash = x.tokenHash; account = x.account; party = x.party; product = x.product; form = x.form; state = #issued; expiryMonth = x.expiryMonth;
          controlsBlock = block; issuedDay = x.day; replaces = switch (x.replaces) { case (?o) o; case null 0 }; replacedBy = 0; authorizations = 0; declines = 0; openHolds = 0; heldAmount = 0; clearedCount = 0; clearedAmount = 0; lastBlock = block;
          dailyLimit = 0; perTransactionLimit = 0; velocityCount = 0; velocityWindowMinutes = 0; channels = 0;
        }, x.controls, block);
        putCard(s, r);
        ignore RI.put(s.byToken, x.tokenHash, R.key(block, 8));
        ignore RI.put(s.byAccount, R.key2(x.account, 8, block, 8), Blob.fromArray([1]));
        ignore RI.put(s.byParty, R.key2(x.party, 8, block, 8), Blob.fromArray([1]));
        ignore RI.put(s.byState, R.key2(1, 1, block, 8), Blob.fromArray([1]));
        switch (x.replaces) { case (?old) { switch (card(s, old)) { case (?o) putCard(s, withState(s, { o with replacedBy = block }, #closed, block)); case null {} } }; case null {} };
        s.issued += 1;
      };
      case (#cardActivated(x)) { switch (card(s, x.card)) { case (?r) putCard(s, withState(s, r, #active, block)); case null {} } };
      case (#cardBlocked(x)) { switch (card(s, x.card)) { case (?r) putCard(s, withState(s, r, #blocked, block)); case null {} } };
      case (#cardUnblocked(x)) { switch (card(s, x.card)) { case (?r) putCard(s, withState(s, r, #active, block)); case null {} } };
      case (#cardClosed(x)) { switch (card(s, x.card)) { case (?r) putCard(s, withState(s, r, #closed, block)); case null {} } };
      case (#controlsSet(x)) { switch (card(s, x.card)) { case (?r) putCard(s, withControls(r, x.controls, block)); case null {} } };
      case (#authorised(x)) {
        let req = x.request;
        let cardId = switch (x.card) { case (?c) c; case null 0 };
        let (approved, decline, hold, holdAmount, holdOpen) : (Bool, Nat8, Nat, Nat, Bool) = switch (x.decision) {
          case (#approved(a)) (true, 0, switch (a.hold) { case (?h) h; case null 0 }, switch (a.hold) { case (?_) a.amount; case null 0 }, a.hold != null);
          case (#declined(r)) (false, declineCode(r), 0, 0, false);
        };
        let original = switch (req.kind) { case (#incremental(o) or #completion(o) or #reversal(o)) o.of; case (_) 0 };
        let k = kindCode(req.kind);
        // an adjustment (completion, incremental, reversal) records its own row but the hold it names stays the original's
        let ownHold = approved and (k == 1 or k == 2) and hold != 0;
        putAuth(s, { id = block; card = cardId; kind = k; amount = req.amount; currency = req.currency; mcc = req.mcc; channel = channelCode(req.channel); approved; decline; hold = if (ownHold) hold else 0; holdAmount = if (ownHold) holdAmount else 0; holdOpen = ownHold and holdOpen; day = x.day; localTime = req.localTime; original; refHash = refHashOf(req.acquirer, req.stan, req.rrn) });
        if (cardId != 0) {
          ignore RI.put(s.byCardDay, Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.key2(cardId, 8, x.day, 4)), Blob.toArray(R.key(block, 8)))), Blob.fromArray([1]));
          switch (card(s, cardId)) {
            case (?c) putCard(s, { c with authorizations = c.authorizations + 1; declines = c.declines + (if (approved) 0 else 1); openHolds = c.openHolds + (if (ownHold) 1 else 0); heldAmount = c.heldAmount + (if (ownHold) holdAmount else 0); lastBlock = block });
            case null {};
          };
        };
        if (approved) ignore RI.put(s.byRef, R.key2(refHashOf(req.acquirer, req.stan, req.rrn), 8, x.day, 4), R.key(block, 8));
        if (ownHold) { ignore RI.put(s.byHold, R.key(hold, 8), R.key(block, 8)); s.openHolds += 1 };
        s.authorizations += 1;
        if (approved) s.approved += 1 else s.declined += 1;
      };
      case (#holdAdjusted(x)) {
        switch (auth(s, x.auth)) {
          case (?a) {
            let newHold = switch (x.hold) { case (?h) h; case null 0 };
            let stillOpen = x.to > 0 and x.hold != null;
            putAuth(s, { a with hold = newHold; holdAmount = x.to; holdOpen = stillOpen });
            if (newHold != 0) ignore RI.put(s.byHold, R.key(newHold, 8), R.key(a.id, 8));
            switch (card(s, a.card)) {
              case (?c) {
                let held : Nat = if (c.heldAmount + x.to >= x.from) c.heldAmount + x.to - x.from else 0;
                putCard(s, { c with heldAmount = held; openHolds = if (a.holdOpen and not stillOpen and c.openHolds > 0) c.openHolds - 1 else c.openHolds; lastBlock = block });
              };
              case null {};
            };
            if (a.holdOpen and not stillOpen and s.openHolds > 0) s.openHolds -= 1;
          };
          case null {};
        };
      };
      case (#holdExpired(x)) {
        switch (auth(s, x.auth)) {
          case (?a) {
            if (a.holdOpen) {
              putAuth(s, { a with holdOpen = false });
              switch (card(s, a.card)) { case (?c) putCard(s, { c with openHolds = if (c.openHolds > 0) c.openHolds - 1 else 0; heldAmount = if (c.heldAmount >= a.holdAmount) c.heldAmount - a.holdAmount else 0; lastBlock = block }); case null {} };
              if (s.openHolds > 0) s.openHolds -= 1;
            };
          };
          case null {};
        };
      };
      case (#clearingRecorded(x)) { ignore RI.put(s.batches, x.batch, R.key(block, 8)) };
      case (#cleared(x)) {
        let cardId = switch (x.card) { case (?c) c; case null 0 };
        let (authId, outcome) : (Nat, Nat8) = switch (x.outcome) { case (#postedAgainstHold(h)) (h.auth, 1); case (#postedDirect(_)) (0, 2); case (#exception(_)) (0, 3) };
        putCleared(s, { id = block; card = cardId; auth = authId; amount = x.item.amount; currency = x.item.currency; mcc = x.item.mcc; interchange = x.interchange; fee = x.fee; posting = switch (x.posting) { case (?p) p; case null 0 }; day = x.day; outcome; refund = x.item.refund; disputed = false; fraud = false; scheme = x.scheme });
        if (cardId != 0) {
          ignore RI.put(s.clearedByCard, R.key2(cardId, 8, block, 8), Blob.fromArray([1]));
          switch (card(s, cardId)) { case (?c) { if (outcome != 3) putCard(s, { c with clearedCount = c.clearedCount + 1; clearedAmount = c.clearedAmount + x.item.amount; lastBlock = block }) }; case null {} };
        };
        switch (x.outcome) {
          case (#postedAgainstHold(h)) {
            switch (auth(s, h.auth)) {
              case (?a) {
                if (a.holdOpen) {
                  putAuth(s, { a with holdOpen = false });
                  switch (card(s, a.card)) { case (?c) putCard(s, { c with openHolds = if (c.openHolds > 0) c.openHolds - 1 else 0; heldAmount = if (c.heldAmount >= a.holdAmount) c.heldAmount - a.holdAmount else 0 }); case null {} };
                  if (s.openHolds > 0) s.openHolds -= 1;
                };
              };
              case null {};
            };
          };
          case (_) {};
        };
        if (outcome == 3) s.exceptions += 1 else s.clearedCount += 1;
      };
      case (#disputeOpened(x)) {
        putDispute(s, { id = block; transaction = x.transaction; card = x.card; stage = #opened; amount = x.amount; provisional = 0; dueDay = x.dueDay; reasonHash = hash8(x.reason); outcome = 0; finalAmount = 0; openedDay = x.day; alerted = false });
        ignore RI.put(s.byStage, R.key2(1, 1, block, 8), Blob.fromArray([1]));
        switch (clearedRow(s, x.transaction)) { case (?t) putCleared(s, { t with disputed = true }); case null {} };
        holdSub(s, disputeSub(block));
        s.disputesTotal += 1; s.disputesOpen += 1;
      };
      case (#provisionalCredited(x)) { switch (dispute(s, x.dispute)) { case (?d) putDispute(s, { withDisputeStage(s, d, #provisionalCredit, d.dueDay) with provisional = x.amount }); case null {} } };
      // a chargeback raised with no provisional credit yet credits the cardholder directly: that credit is conditional too, so the row records it as the provisional figure the resolution settles
      case (#chargebackRaised(x)) { switch (dispute(s, x.dispute)) { case (?d) putDispute(s, { withDisputeStage(s, d, #chargeback, x.dueDay) with provisional = (if (d.provisional == 0) d.amount else d.provisional) }); case null {} } };
      case (#representmentRecorded(x)) { switch (dispute(s, x.dispute)) { case (?d) putDispute(s, withDisputeStage(s, d, #representment, x.dueDay)); case null {} } };
      case (#preArbitrationRecorded(x)) { switch (dispute(s, x.dispute)) { case (?d) putDispute(s, withDisputeStage(s, d, #preArbitration, x.dueDay)); case null {} } };
      case (#disputeResolved(x)) { switch (dispute(s, x.dispute)) { case (?d) putDispute(s, { withDisputeStage(s, d, #resolved, d.dueDay) with outcome = switch (x.outcome) { case (#cardholder) 1; case (#merchant) 2 }; finalAmount = x.finalAmount }); case null {} } };
      case (#disputeStepDue(x)) { switch (dispute(s, x.dispute)) { case (?d) putDispute(s, { d with alerted = true }); case null {} } };
      case (#fraudMarked(x)) {
        switch (clearedRow(s, x.transaction)) { case (?t) putCleared(s, { t with fraud = true }); case null {} };
        if (x.blocked) { switch (card(s, x.card)) { case (?r) { if (r.state != #closed and r.state != #blocked) putCard(s, withState(s, r, #blocked, block)) }; case null {} } };
      };
      case (#statementCut(x)) {
        ignore RI.put(s.statements, R.key2(x.card, 8, x.cycleEnd, 4), encodeStatement({ card = x.card; cycleEnd = x.cycleEnd; balance = x.balance; minimumDue = x.minimumDue; dueDay = x.dueDay; purchases = x.purchases; payments = x.payments; interest = x.interest }));
        s.statementCount += 1;
      };
    }
  };

  // ─── reads ────────────────────────────────────────────────────────────────

  public func view(s : State, r : CardRow, controls : CT.Controls) : CT.CardView {
    let sch = switch (product(s, r.product)) { case (?p) p.scheme; case null "" };
    { id = r.id; account = r.account; party = r.party; product = r.product; scheme = sch; form = switch (r.form) { case (#physical) "physical"; case (#virtual) "virtual" }; state = CT.stateText(r.state); expiryMonth = r.expiryMonth; controls;
      issuedDay = r.issuedDay; replaces = if (r.replaces == 0) null else ?r.replaces; replacedBy = if (r.replacedBy == 0) null else ?r.replacedBy; authorizations = r.authorizations; declines = r.declines; openHolds = r.openHolds; heldAmount = r.heldAmount;
      clearedCount = r.clearedCount; clearedAmount = r.clearedAmount; lastBlock = r.lastBlock }
  };
  public func authView(a : AuthRow, stan : Text, rrn : Text) : CT.AuthView {
    let d : CT.Decision = if (a.approved) #approved({ authCode = authCodeOf(if (a.original != 0 and a.kind != 1 and a.kind != 2) a.original else a.id); hold = if (a.hold == 0) null else ?a.hold; amount = a.amount }) else #declined(switch (declineOf(a.decline)) { case (?r) r; case null #unknownCard });
    { id = a.id; card = if (a.card == 0) null else ?a.card; kind = kindTextOf(a.kind); amount = a.amount; currency = a.currency; mcc = a.mcc; channel = channelTextOf(a.channel); approved = a.approved; responseCode = CT.responseCode(d);
      authCode = switch (d) { case (#approved(x)) x.authCode; case (_) "" }; hold = if (a.hold == 0) null else ?a.hold; holdAmount = a.holdAmount; holdOpen = a.holdOpen; day = a.day; stan; rrn }
  };
  public func disputeView(d : DisputeRow, reason : Text) : CT.DisputeView {
    { id = d.id; transaction = d.transaction; card = d.card; reason; amount = d.amount; stage = CT.stageText(d.stage); dueDay = d.dueDay; outcome = switch (d.outcome) { case 1 ?"cardholder"; case 2 ?"merchant"; case _ null }; finalAmount = d.finalAmount; provisional = d.provisional; block = d.id }
  };
  public func status(s : State) : CT.Status {
    { schemes = s.schemeCount; products = s.productCount; cards = s.issued; active = s.active; authorizations = s.authorizations; approved = s.approved; declined = s.declined; openHolds = s.openHolds; cleared = s.clearedCount; exceptions = s.exceptions; disputes = s.disputesTotal; openDisputes = s.disputesOpen; statements = s.statementCount }
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
    switch (s.policy) { case null w.byte(0); case (?p) { w.byte(1); for (t in accountsOf(p).vals()) w.text(t); w.nat(p.provisionalCreditCeiling); w.nat(p.clearingTolerance); w.nat(p.stanReplayDays) } };
    w.nat(s.issued); w.nat(s.active); w.nat(s.authorizations); w.nat(s.approved); w.nat(s.declined); w.nat(s.openHolds); w.nat(s.clearedCount); w.nat(s.exceptions); w.nat(s.disputesTotal); w.nat(s.disputesOpen); w.nat(s.statementCount); w.nat(s.schemeCount); w.nat(s.productCount);
    fingerprintRows(w, s.cards, 8); fingerprintRows(w, s.byToken, 32); fingerprintRows(w, s.byAccount, 16); fingerprintRows(w, s.byParty, 16); fingerprintRows(w, s.byState, 9);
    fingerprintRows(w, s.auths, 8); fingerprintRows(w, s.byCardDay, 20); fingerprintRows(w, s.byHold, 8); fingerprintRows(w, s.byRef, 12); fingerprintRows(w, s.cleared, 8); fingerprintRows(w, s.clearedByCard, 16); fingerprintRows(w, s.batches, 32);
    fingerprintRows(w, s.disputes, 8); fingerprintRows(w, s.byStage, 9); fingerprintRows(w, s.statements, 12); fingerprintRows(w, s.schemes, 16); fingerprintRows(w, s.products, 32); fingerprintRows(w, s.subledgers, 32);
  };
}
