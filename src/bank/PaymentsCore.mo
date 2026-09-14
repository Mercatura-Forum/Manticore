/// PaymentsCore.mo: the state and the planners of ISO 20022 messaging on the journal.
///
/// State: the rails, the connector keys, the message register (one fixed-width row per received
/// message, keyed by its block; a uniqueness index on (rail, message id) and on the message hash),
/// and the holds (transfer → the rule that held it). Everything here is derived from the bank's
/// blocks and rebuilt by replay, like every other component's state.
///
/// Planning: `planIngest` turns a received message into the acts the actor performs; the settlement
/// prepares a credit transfer becomes, the fulfils and rejects a status report asks for, the
/// returns a pacs.004 opens; and the audit record that closes the message whatever the verdict.
/// Nothing here touches the journal: the settlement layer does, through the same planners the
/// single `prepareTransfer` / `fulfilTransfer` / `rejectTransfer` commands use, so a message can
/// do nothing a command could not.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import CivilDate "mo:journal/CivilDate";
import RI "mo:ledger/RegionIndex";

import PayT "PaymentsTypes";
import ST "SettlementTypes";
import SC "SettlementCore";
import IsoSchema "IsoSchema";
import M "IsoMessages";
import R "StableRows";
import Xml "Xml";

module {

  public type Blocks = { get : Nat -> ?PayT.PaymentsEvent };

  /// family(1) ‖ verdict(1) ‖ hash(32) ‖ outcomes(4) ‖ receivedAt(8); the facts; the event block is the record.
  public let MESSAGE_ROW : Nat = 46;
  public let HOLD_ROW : Nat = 48;
  /// state(1) ‖ mandate block(8) ‖ last block(8) ‖ collections(4) ‖ maxPresent(1) ‖ maxAmount(16) ‖ creditorAgent(11)
  /// ‖ debtorAgent(11) ‖ sequence(4) ‖ currency(3) ‖ debtorAccount(34) ‖ mandateId(35); the register row.
  public let MANDATE_ROW : Nat = 136;
  /// state(1: 1 expected, 2 matched) ‖ notification block(8) ‖ amount(16) ‖ currency(3) ‖ transfer(8) ‖ itemId(35).
  public let EXPECT_ROW : Nat = 71;

  public type State = {
    rails : Map.Map<PayT.RailId, PayT.Rail>;
    keys : Map.Map<(PayT.RailId, Text), PayT.ConnectorKey>;
    messageRows : RI.State;      // block(8) -> MESSAGE_ROW
    messageIds : RI.State;       // sha256(rail ‖ messageId)(32) -> block(8)
    messageHashes : RI.State;    // hash(32) -> block(8)
    /// transfer(8) -> HOLD_ROW: state(1: 1 held, 2 released, 3 rejected) ‖ the rule (47, padded). The
    /// index has no deletion, so a lifted hold is a row that says so.
    holds : RI.State;
    // ── the extended target list ──
    mandates : RI.State;         // sha256(rail ‖ mandateId)(32) -> MANDATE_ROW
    expected : RI.State;         // sha256(rail ‖ reference)(32) -> EXPECT_ROW (camt.057 items)
    liquidity : RI.State;        // sha256(rail ‖ endToEndId)(32) -> block(8): the liquidity transfers made
    authorities : Map.Map<(PayT.RailId, Nat, Text, Text), PayT.DebitAuthority>;   // (rail, debtor, creditor BIC, currency)
    settlementRequests : Map.Map<Nat, { message : Nat; movements : [PayT.Movement]; var judged : ?Bool }>;   // by settlement
    var messageCount : Nat;
    var accepted : Nat;
    var refused : Nat;
    var held : Nat;
    var mandateCount : Nat;
    var expectedCount : Nat;
  };

  public func newState(arena : RI.Arena) : State {
    {
      rails = Map.empty<PayT.RailId, PayT.Rail>();
      keys = Map.empty<(PayT.RailId, Text), PayT.ConnectorKey>();
      messageRows = RI.newStateIn(arena, { keyBytes = 8; valBytes = MESSAGE_ROW });
      messageIds = RI.newStateIn(arena, { keyBytes = 32; valBytes = 8 });
      messageHashes = RI.newStateIn(arena, { keyBytes = 32; valBytes = 8 });
      holds = RI.newStateIn(arena, { keyBytes = 8; valBytes = HOLD_ROW });
      mandates = RI.newStateIn(arena, { keyBytes = 32; valBytes = MANDATE_ROW });
      expected = RI.newStateIn(arena, { keyBytes = 32; valBytes = EXPECT_ROW });
      liquidity = RI.newStateIn(arena, { keyBytes = 32; valBytes = 8 });
      authorities = Map.empty<(PayT.RailId, Nat, Text, Text), PayT.DebitAuthority>();
      settlementRequests = Map.empty<Nat, { message : Nat; movements : [PayT.Movement]; var judged : ?Bool }>();
      var messageCount = 0; var accepted = 0; var refused = 0; var held = 0;
      var mandateCount = 0; var expectedCount = 0;
    }
  };

  func cmpAuth(a : (Text, Nat, Text, Text), b : (Text, Nat, Text, Text)) : { #less; #equal; #greater } {
    switch (Text.compare(a.0, b.0)) { case (#equal) { switch (Nat.compare(a.1, b.1)) { case (#equal) { switch (Text.compare(a.2, b.2)) { case (#equal) Text.compare(a.3, b.3); case (o) o } }; case (o) o } }; case (o) o }
  };
  func mandateKey(rail : Text, mandateId : Text) : Blob { let w = C.Writer(); w.text("mandate"); w.text(rail); w.text(mandateId); Sha256.fromBlob(#sha256, w.toBlob()) };
  func liquidityKey(rail : Text, endToEndId : Text) : Blob { let w = C.Writer(); w.text("liquidity"); w.text(rail); w.text(endToEndId); Sha256.fromBlob(#sha256, w.toBlob()) };
  public func liquidityDone(s : State, rail : Text, endToEndId : Text) : Bool { RI.get(s.liquidity, liquidityKey(rail, endToEndId)) != null };
  func expectKey(rail : Text, reference : Text) : Blob { let w = C.Writer(); w.text("expect"); w.text(rail); w.text(reference); Sha256.fromBlob(#sha256, w.toBlob()) };

  func cmpRB(a : (Text, Text), b : (Text, Text)) : { #less; #equal; #greater } { switch (Text.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o } };

  func messageIdKey(rail : Text, messageId : Text) : Blob { let w = C.Writer(); w.text(rail); w.text(messageId); Sha256.fromBlob(#sha256, w.toBlob()) };

  public func hashOf(bytes : Blob) : Blob { Sha256.fromBlob(#sha256, bytes) };

  // ─── reads ───

  public func rail(s : State, id : PayT.RailId) : ?PayT.Rail { Map.get(s.rails, Text.compare, id) };
  public func rails(s : State) : [PayT.Rail] { Array.map<(Text, PayT.Rail), PayT.Rail>(Map.toArray(s.rails), func((_, r)) { r }) };
  public func connectorKey(s : State, railId : PayT.RailId, bic : Text) : ?PayT.ConnectorKey { Map.get(s.keys, cmpRB, (railId, bic)) };
  public func messageByMessageId(s : State, railId : PayT.RailId, messageId : Text) : ?Nat {
    switch (RI.get(s.messageIds, messageIdKey(railId, messageId))) { case (?v) ?R.getNat(Blob.toArray(v), 0, 8); case null null }
  };
  public func messageByHash(s : State, hash : Blob) : ?Nat {
    switch (RI.get(s.messageHashes, hash)) { case (?v) ?R.getNat(Blob.toArray(v), 0, 8); case null null }
  };
  public func holdOf(s : State, transfer : Nat) : ?Text {
    switch (RI.get(s.holds, R.key(transfer, 8))) { case (?v) { let a = Blob.toArray(v); if (a[0] == 1) ?R.getText(a, 1, 47) else null }; case null null }
  };
  func holdRow(state : Nat8, rule : Text) : Blob { let hb = R.buf(); R.putByte(hb, state); R.putText(hb, M.clip(rule, 47), 47); R.done(hb, HOLD_ROW) };
  func setHoldState(s : State, transfer : Nat, state : Nat8) {
    switch (RI.get(s.holds, R.key(transfer, 8))) { case (?v) ignore RI.put(s.holds, R.key(transfer, 8), holdRow(state, R.getText(Blob.toArray(v), 1, 47))); case null {} }
  };
  /// Open holds: the rows whose state is still "held".
  public func openHolds(s : State) : Nat {
    let (lo, hi) = R.fullRange(8);
    var n = 0;
    var cursor : ?Blob = null;
    label rows loop {
      let page = RI.range(s.holds, lo, hi, cursor, 256);
      for ((_, v) in page.entries.vals()) { if (Blob.toArray(v)[0] == 1) n += 1 };
      switch (page.cursor) { case (?c) cursor := ?c; case null break rows };
    };
    n
  };
  public func message(s : State, bb : Blocks, id : Nat) : ?PayT.Message {
    let ?row = RI.get(s.messageRows, R.key(id, 8)) else return null;
    let ?(#messageReceived(m)) = bb.get(id) else return null;
    let a = Blob.toArray(row);
    ?{ id; rail = m.rail; family = m.family; messageId = m.messageId; hash = m.hash; bytes = m.bytes; signer = m.signer; verdict = m.verdict; issues = m.issues; outcomes = m.outcomes; receivedAt = Nat64.fromNat(R.getNat(a, 38, 8)) }
  };
  public func counts(s : State) : { rails : Nat; keys : Nat; messages : Nat; accepted : Nat; refused : Nat; held : Nat; holdsOpen : Nat; mandates : Nat; authorities : Nat; expected : Nat; settlementRequests : Nat } {
    { rails = Map.size(s.rails); keys = Map.size(s.keys); messages = s.messageCount; accepted = s.accepted; refused = s.refused; held = s.held; holdsOpen = openHolds(s);
      mandates = s.mandateCount; authorities = Map.size(s.authorities); expected = s.expectedCount; settlementRequests = Map.size(s.settlementRequests) }
  };

  // ─── extended-list reads: the mandate register, the debit authorities, the expected receipts, the settlement requests ───

  func mandateRow(m : PayT.Mandate) : Blob {
    let b = R.buf();
    R.putByte(b, PayT.mandateStateOrd(m.state)); R.putNat(b, m.mandate, 8); R.putNat(b, m.lastBlock, 8); R.putNat(b, m.collections, 4);
    switch (m.maxAmount) { case (?a) { R.putByte(b, 1); R.putNat(b, a, 16) }; case null { R.putByte(b, 0); R.putNat(b, 0, 16) } };
    R.putText(b, M.clip(m.creditorAgent, 11), 11); R.putText(b, M.clip(m.debtorAgent, 11), 11); R.putText(b, M.clip(m.sequence, 4), 4);
    R.putText(b, (switch (m.currency) { case (?c) M.clip(c, 3); case null "" }), 3); R.putText(b, M.clip(m.debtorAccount, 34), 34); R.putText(b, M.clip(m.mandateId, 35), 35);
    R.done(b, MANDATE_ROW)
  };
  func mandateOfRow(rail : Text, v : Blob) : PayT.Mandate {
    let a = Blob.toArray(v);
    let ccy = R.getText(a, 64, 3);
    { rail; mandateId = R.getText(a, 101, 35); mandate = R.getNat(a, 1, 8); state = PayT.mandateStateFromOrd(a[0]); creditorAgent = R.getText(a, 38, 11); debtorAgent = R.getText(a, 49, 11);
      debtorAccount = R.getText(a, 67, 34); sequence = R.getText(a, 60, 4); maxAmount = if (a[21] == 1) ?R.getNat(a, 22, 16) else null; currency = if (ccy == "") null else ?ccy;
      collections = R.getNat(a, 17, 4); lastBlock = R.getNat(a, 9, 8) }
  };
  public func mandate(s : State, rail : PayT.RailId, mandateId : Text) : ?PayT.Mandate {
    switch (RI.get(s.mandates, mandateKey(rail, mandateId))) { case (?v) ?mandateOfRow(rail, v); case null null }
  };
  public func mandates(s : State, rail : PayT.RailId, cursor : ?Blob, limit : Nat) : { mandates : [PayT.Mandate]; next : ?Blob } {
    let (lo, hi) = R.fullRange(32);
    let page = RI.range(s.mandates, lo, hi, cursor, Nat.max(limit, 1));
    let out = List.empty<PayT.Mandate>();
    for ((_, v) in page.entries.vals()) { let m = mandateOfRow(rail, v); if (m.rail == rail) List.add(out, m) };
    { mandates = List.toArray(out); next = page.cursor }
  };
  public func authority(s : State, rail : PayT.RailId, debtor : Nat, creditorBic : Text, currency : Text) : ?PayT.DebitAuthority { Map.get(s.authorities, cmpAuth, (rail, debtor, creditorBic, currency)) };
  public func authorities(s : State, rail : PayT.RailId) : [PayT.DebitAuthority] {
    Array.filter<PayT.DebitAuthority>(Array.map<((Text, Nat, Text, Text), PayT.DebitAuthority), PayT.DebitAuthority>(Map.toArray(s.authorities), func((_, a)) { a }), func(a) { a.rail == rail })
  };
  public type Expected = { reference : Text; itemId : Text; notification : Nat; amount : Nat; currency : Text; matched : ?Nat };
  public func expectedReceipt(s : State, rail : PayT.RailId, reference : Text) : ?Expected {
    switch (RI.get(s.expected, expectKey(rail, reference))) {
      case (?v) { let a = Blob.toArray(v); ?{ reference; itemId = R.getText(a, 36, 35); notification = R.getNat(a, 1, 8); amount = R.getNat(a, 9, 16); currency = R.getText(a, 25, 3); matched = if (a[0] == 2) ?R.getNat(a, 28, 8) else null } };
      case null null;
    }
  };
  func expectRow(state : Nat8, notification : Nat, amount : Nat, currency : Text, transfer : Nat, itemId : Text) : Blob {
    let b = R.buf(); R.putByte(b, state); R.putNat(b, notification, 8); R.putNat(b, amount, 16); R.putText(b, M.clip(currency, 3), 3); R.putNat(b, transfer, 8); R.putText(b, M.clip(itemId, 35), 35); R.done(b, EXPECT_ROW)
  };
  public func settlementRequest(s : State, settlement : Nat) : ?{ message : Nat; movements : [PayT.Movement]; judged : ?Bool } {
    switch (Map.get(s.settlementRequests, Nat.compare, settlement)) { case (?r) ?{ message = r.message; movements = r.movements; judged = r.judged }; case null null }
  };
  public func messageIds(s : State, cursor : ?Nat, limit : Nat) : { ids : [Nat]; next : ?Nat } {
    let lo = switch (cursor) { case (?c) R.key(c, 8); case null R.key(0, 8) };
    let page = RI.range(s.messageRows, lo, R.key(0xFFFF_FFFF_FFFF_FFFF, 8), null, limit + 1);
    let ids = Array.map<(Blob, Blob), Nat>(page.entries, func((k, _)) { R.getNat(Blob.toArray(k), 0, 8) });
    if (ids.size() > limit) { { ids = Array.tabulate<Nat>(limit, func(i) { ids[i] }); next = ?ids[limit] } } else { { ids; next = null } }
  };

  // ─── configuration planners ───

  public func planDeclareRail(s : State, sc : SC.State, x : { id : PayT.RailId; scheme : ST.SchemeId; ttlSeconds : Nat; hold : PayT.HoldRules; signatures : PayT.SignatureScheme }) : Result.Result<PayT.PaymentsEvent, PayT.PaymentsError> {
    if (Text.size(x.id) == 0 or Text.size(x.id) > 35) return #err(#InvalidRail({ reason = "a rail id is 1..35 characters" }));
    if (Map.containsKey(s.rails, Text.compare, x.id)) return #err(#RailExists({ rail = x.id }));
    let ?_ = SC.scheme(sc, x.scheme) else return #err(#InvalidRail({ reason = "scheme " # x.scheme # " is not declared" }));
    if (x.ttlSeconds == 0 or x.ttlSeconds > ST.MAX_TRANSFER_TTL_SECONDS) return #err(#InvalidRail({ reason = "a reservation lives 1.." # Nat.toText(ST.MAX_TRANSFER_TTL_SECONDS) # " seconds" }));
    for (b in x.hold.blockedBics.vals()) { if (not ST.validBic(b)) return #err(#InvalidRail({ reason = "blocked BIC " # b # " is not ISO 9362" })) };
    for ((_, amount) in x.hold.holdAbove.vals()) { if (amount == 0) return #err(#InvalidRail({ reason = "a hold threshold of zero would hold every payment; declare no threshold instead" })) };
    #ok(#railDeclared({ id = x.id; scheme = x.scheme; ttlSeconds = x.ttlSeconds; hold = x.hold; signatures = x.signatures }))
  };

  public func planRegisterConnectorKey(s : State, x : { rail : PayT.RailId; bic : Text; scheme : PayT.SignatureScheme; publicKey : Blob }) : Result.Result<PayT.PaymentsEvent, PayT.PaymentsError> {
    let ?_ = rail(s, x.rail) else return #err(#UnknownRail({ rail = x.rail }));
    if (not ST.validBic(x.bic)) return #err(#InvalidKey({ scheme = x.scheme; reason = "BIC " # x.bic # " is not ISO 9362" }));
    // MAYO-2 compact public keys are 4,912 bytes; ML-DSA-44 public keys 1,312 (PqSchemes.mo)
    let expected = switch (x.scheme) { case (#mayo2) ?4_912; case (#mldsa44) ?1_312; case (#none) null };
    switch (expected) {
      case (?n) { if (x.publicKey.size() != n) return #err(#InvalidKey({ scheme = x.scheme; reason = PayT.schemeName(x.scheme) # " public keys are " # Nat.toText(n) # " bytes" })) };
      case null return #err(#InvalidKey({ scheme = x.scheme; reason = "a connector key names a signature scheme" }));
    };
    #ok(#connectorKeyRegistered({ rail = x.rail; bic = x.bic; scheme = x.scheme; publicKey = x.publicKey }))
  };

  // ─── the message ───

  /// What a parsed message asks the settlement layer to do, in order. The actor performs each act
  /// through the settlement planners and records the outcomes in the closing `#messageReceived`.
  public type Act = {
    #prepare : { uetr : Text; payer : ST.ParticipantId; payee : ST.ParticipantId; currency : Text; amount : Nat; correctionOf : ?Nat; originalTransfer : ?Nat; hold : ?Text };
    #fulfil : { uetr : Text; transfer : Nat };
    #reject : { uetr : Text; transfer : Nat; reason : Text };
    #acknowledge : { uetr : Text; transfer : Nat; status : Text };
    #refuse : { uetr : ?Text; rule : Text; detail : Text };
    // ── the extended target list ──
    /// A reversal: the original's posting corrected by a transfer payee → payer, posted in this message.
    #reverse : { uetr : Text; original : Nat; payer : ST.ParticipantId; payee : ST.ParticipantId; currency : Text; amount : Nat; correctionOf : Nat; reason : Text };
    /// A collection under a mandate (pacs.003) or an FI direct debit under a debit authority (pacs.010).
    #collect : { uetr : Text; payer : ST.ParticipantId; payee : ST.ParticipantId; currency : Text; amount : Nat; authority : Nat; final : Bool; mandateId : ?Text; hold : ?Text };
    /// The mandate register's changes; the outcome is the record.
    #mandate : PayT.Outcome;
    /// A multilateral settlement request: open the window's settlement and hold the movements against its nets.
    #settlementRequest : { window : Nat; cycle : Text; movements : [PayT.Movement] };
    /// A liquidity transfer between a participant's settlement account and its position.
    #liquidity : { endToEndId : Text; participant : ST.ParticipantId; currency : Text; amount : Nat; toPosition : Bool };
    /// A fact recorded as it was read (a reporting request, an expected receipt, a case, an
    /// administrative request).
    #record : PayT.Outcome;
    /// A business file: its payloads, each ingested as a message of its own.
    #file : { payloadId : Text; declared : Nat; payloads : [Blob] };
  };

  public type Parsed = {
    family : PayT.Family;
    messageId : Text;
    originalMessageId : ?Text;
    signer : ?Text;
    issues : [PayT.Issue];
    acts : [Act];
  };

  /// Parse, validate and read a message on a rail; the acts the actor will perform, or the issues
  /// that refuse it whole. A message that fails parsing or the schema is refused whole (no act);
  /// one that reads but names an unknown agent, currency or original is refused transaction by
  /// transaction (a `#refuse` act each), and the accepted transactions still go through.
  /// The largest business file (head.002) ingested as one message: its payloads each become a message.
  public let MAX_FILE_PAYLOADS : Nat = 100;

  public func planIngest(s : State, sc : SC.State, sb : SC.Blocks, railId : PayT.RailId, bytes : Blob, minorUnitsOf : Text -> ?Nat8, accountOfId : Text -> ?Nat) : Result.Result<Parsed, PayT.PaymentsError> {
    let ?r = rail(s, railId) else return #err(#UnknownRail({ rail = railId }));
    func refusedWhole(family : PayT.Family, messageId : Text, signer : ?Text, issues : [PayT.Issue]) : Result.Result<Parsed, PayT.PaymentsError> {
      #ok({ family; messageId; originalMessageId = null; signer; issues; acts = [] })
    };
    // 1. well-formedness
    let roots = switch (Xml.parseMessage(bytes)) {
      case (#err(e)) return refusedWhole(#unknown, "", null, [{ rule = e.rule; path = "$xml@" # Nat.toText(e.offset); detail = e.detail }]);
      case (#ok(rs)) rs;
    };
    // 2. the envelope: a Document, or an AppHdr followed by a Document
    var signer : ?Text = null;
    var hdrIssues : [PayT.Issue] = [];
    let doc = if (roots.size() == 2) {
      let hdr = roots[0];
      // two elements are a business message only when the first is the header
      if (PayT.familyOf(hdr.namespace) != #head001) return refusedWhole(#unknown, "", null, [{ rule = "XML-ROOT"; path = "/" # roots[1].name; detail = "content after the root element (a two-element message is an AppHdr followed by a Document)" }]);
      switch (IsoSchema.schemaFor(hdr.namespace)) {
        case (?hs) {
          let hi = IsoSchema.validate(hs, hdr);
          if (hi.size() > 0) hdrIssues := Array.map<IsoSchema.Issue, PayT.Issue>(hi, func(i) { { rule = i.rule; path = i.path; detail = i.detail } })
          else { switch (M.readHeader(hdr)) { case (#ok(h)) signer := ?h.fromBic; case (#err(is)) hdrIssues := is } };
        };
        case null hdrIssues := [{ rule = "ISO-XSD-ROOT"; path = "/" # hdr.name; detail = "the first element of a two-element message must be a head.001 AppHdr" }];
      };
      roots[1]
    } else roots[0];
    let family = PayT.familyOf(doc.namespace);
    if (hdrIssues.size() > 0) return refusedWhole(family, "", null, hdrIssues);
    // 3. the schema
    let ?schema = IsoSchema.schemaFor(doc.namespace) else return refusedWhole(#unknown, "", signer, [{ rule = "ISO-XSD-ROOT"; path = "/" # doc.name; detail = "namespace " # doc.namespace # " is not a message family this rail carries" }]);
    let xsd = IsoSchema.validate(schema, doc);
    if (xsd.size() > 0) return refusedWhole(family, "", signer, Array.map<IsoSchema.Issue, PayT.Issue>(xsd, func(i) { { rule = i.rule; path = i.path; detail = i.detail } }));
    // 4. the business content, into acts
    let acts = List.empty<Act>();
    func participantFor(bic : Text, uetr : Text, role : Text) : ?ST.ParticipantId {
      switch (SC.participantOfBic(sc, r.scheme, bic)) {
        case (?p) { switch (SC.participant(sc, p)) { case (?x) { if (x.active) ?p else { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-PARTICIPANT-INACTIVE"; detail = role # " " # bic # " is a deactivated participant" })); null } }; case null null } };
        case null { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-UNKNOWN-AGENT"; detail = role # " " # bic # " is not a participant of scheme " # r.scheme })); null };
      }
    };
    func holdRule(tx : M.CreditTransfer) : ?Text {
      for ((ccy, threshold) in r.hold.holdAbove.vals()) { if (Text.equal(ccy, tx.amount.currency) and tx.amount.minor >= threshold) return ?("HOLD-AMOUNT-" # ccy) };
      for (b in r.hold.blockedBics.vals()) { if (Text.equal(b, tx.debtorAgent) or Text.equal(b, tx.creditorAgent)) return ?("HOLD-BIC-" # b) };
      for (f in r.hold.blockedNameFragments.vals()) {
        let fu = Text.toUpper(f);
        switch (tx.debtorName) { case (?n) { if (Text.contains(Text.toUpper(n), #text fu)) return ?("HOLD-NAME") }; case null {} };
        switch (tx.creditorName) { case (?n) { if (Text.contains(Text.toUpper(n), #text fu)) return ?("HOLD-NAME") }; case null {} };
      };
      null
    };
    func dayOf(d : Text) : ?Nat { CivilDate.fromText(d) };
    // the hold rules read a credit transfer's fields; a collection is judged on the same ones
    func asCredit(tx : M.DirectDebit) : M.CreditTransfer { { uetr = tx.uetr; endToEndId = tx.endToEndId; instructionId = tx.instructionId; amount = tx.amount; settlementDate = null; debtorAgent = tx.debtorAgent; creditorAgent = tx.creditorAgent; debtorName = tx.debtorName; creditorName = tx.creditorName; chargeBearer = null } };
    /// A collection: a customer direct debit (pacs.003) under an active mandate of the register, or an
    /// FI direct debit (pacs.010) under the debtor participant's standing authority.
    func collection(tx : M.DirectDebit, customer : Bool) {
      switch (SC.transferByReference(sc, r.scheme, tx.uetr)) {
        case (?existing) { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-DUPLICATE-UETR"; detail = "UETR already carried by transfer " # Nat.toText(existing) })); return };
        case null {};
      };
      let ?payee = participantFor(tx.creditorAgent, tx.uetr, "creditor agent") else return;
      let ?payer = participantFor(tx.debtorAgent, tx.uetr, "debtor agent") else return;
      if (payer == payee) { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-SAME-PARTICIPANT"; detail = "debtor and creditor agents are one participant" })); return };
      if (customer) {
        let ?mid = tx.mandateId else { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-MANDATE-REQUIRED"; detail = "a collection names its mandate (DrctDbtTx/MndtRltdInf/MndtId)" })); return };
        let ?m = mandate(s, railId, mid) else { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-UNKNOWN-MANDATE"; detail = "no mandate " # mid # " on rail " # railId })); return };
        if (m.state != #active) { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-MANDATE-STATE"; detail = "mandate " # mid # " is " # PayT.mandateStateName(m.state) })); return };
        if (not Text.equal(m.creditorAgent, tx.creditorAgent) or not Text.equal(m.debtorAgent, tx.debtorAgent)) { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-MANDATE-PARTIES"; detail = "the collection's agents are not the mandate's" })); return };
        switch (tx.debtorAccount) { case (?acct) { if (m.debtorAccount != "" and not Text.equal(acct, m.debtorAccount)) { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-MANDATE-ACCOUNT"; detail = "the debtor account is not the mandate's" })); return } }; case null {} };
        switch (m.maxAmount, m.currency) {
          case (?mx, ?ccy) { if (not Text.equal(ccy, tx.amount.currency)) { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-MANDATE-CURRENCY"; detail = "the mandate is in " # ccy })); return }; if (tx.amount.minor > mx) { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-MANDATE-AMOUNT"; detail = "the collection exceeds the mandate's maximum" })); return } };
          case (_, _) {};
        };
        let seq = switch (tx.sequence) { case (?q) q; case null m.sequence };
        if (m.sequence == "OOFF" and m.collections > 0) { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-MANDATE-SEQUENCE"; detail = "a one-off mandate was already collected" })); return };
        if (seq == "FRST" and m.collections > 0) { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-MANDATE-SEQUENCE"; detail = "FRST after a collection under this mandate" })); return };
        List.add(acts, #collect({ uetr = tx.uetr; payer; payee; currency = tx.amount.currency; amount = tx.amount.minor; authority = m.mandate; final = seq == "FNAL" or m.sequence == "OOFF"; mandateId = ?mid; hold = holdRule(asCredit(tx)) }));
      } else {
        let ?auth = authority(s, railId, payer, tx.creditorAgent, tx.amount.currency) else { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-AUTHORITY-UNKNOWN"; detail = "participant " # tx.debtorAgent # " has granted " # tx.creditorAgent # " no debit authority in " # tx.amount.currency })); return };
        if (not auth.active) { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-AUTHORITY-REVOKED"; detail = "the debit authority was revoked" })); return };
        if (tx.amount.minor > auth.maxAmount) { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-AUTHORITY-AMOUNT"; detail = "the debit exceeds the authority's maximum" })); return };
        List.add(acts, #collect({ uetr = tx.uetr; payer; payee; currency = tx.amount.currency; amount = tx.amount.minor; authority = auth.grantedAt; final = false; mandateId = null; hold = holdRule(asCredit(tx)) }));
      };
    };
    func creditTransfers(msg : M.CreditTransferMessage) {
      for (tx in msg.transactions.vals()) {
        switch (SC.transferByReference(sc, r.scheme, tx.uetr)) {
          case (?existing) { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-DUPLICATE-UETR"; detail = "UETR already carried by transfer " # Nat.toText(existing) })); continue };
          case null {};
        };
        let payer = participantFor(tx.debtorAgent, tx.uetr, "debtor agent");
        let payee = participantFor(tx.creditorAgent, tx.uetr, "creditor agent");
        switch (payer, payee) {
          case (?a, ?b) {
            if (a == b) { List.add(acts, #refuse({ uetr = ?tx.uetr; rule = "ISO-BIZ-SAME-PARTICIPANT"; detail = "debtor and creditor agents are one participant" })); continue };
            List.add(acts, #prepare({ uetr = tx.uetr; payer = a; payee = b; currency = tx.amount.currency; amount = tx.amount.minor; correctionOf = null; originalTransfer = null; hold = holdRule(tx) }));
          };
          case (_, _) {};
        };
      };
    };
    var messageId = "";
    var originalMessageId : ?Text = null;
    var issues : [PayT.Issue] = [];
    switch (family) {
      case (#pacs008) { switch (M.readPacs008(doc, minorUnitsOf)) { case (#ok(m)) { messageId := m.messageId; creditTransfers(m) }; case (#err(is)) issues := is } };
      case (#pacs009) { switch (M.readPacs009(doc, minorUnitsOf)) { case (#ok(m)) { messageId := m.messageId; creditTransfers(m) }; case (#err(is)) issues := is } };
      case (#pacs002) {
        switch (M.readPacs002(doc)) {
          case (#err(is)) issues := is;
          case (#ok(rep)) {
            messageId := rep.messageId; originalMessageId := rep.originalMessageId;
            for (item in rep.items.vals()) {
              let ?uetr = item.originalUetr else { List.add(acts, #refuse({ uetr = null; rule = "ISO-BIZ-UETR-REQUIRED"; detail = "a status names its transaction by OrgnlUETR on this rail" })); continue };
              let ?status = item.status else { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-STATUS-REQUIRED"; detail = "TxSts missing" })); continue };
              // a status for a return names the original's UETR and the return's id in OrgnlTxId or OrgnlInstrId
              let returnRef : ?Text = switch (item.originalTransactionId, item.originalInstructionId) { case (?id, _) ?("RTR:" # uetr # ":" # id); case (null, ?id) ?("RTR:" # uetr # ":" # id); case (null, null) null };
              let addressed : ?Nat = switch (returnRef) { case (?rr) { switch (SC.transferByReference(sc, r.scheme, rr)) { case (?t) ?t; case null SC.transferByReference(sc, r.scheme, uetr) } }; case null SC.transferByReference(sc, r.scheme, uetr) };
              let ?transfer = addressed else { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-UNKNOWN-UETR"; detail = "no transfer carries this UETR" })); continue };
              let reasonText = switch (item.reasonCode, item.reasonProprietary) { case (?c, _) c; case (null, ?p) p; case (null, null) status };
              switch (status) {
                case ("ACSC" or "ACCC") List.add(acts, #fulfil({ uetr; transfer }));
                case ("RJCT" or "CANC") List.add(acts, #reject({ uetr; transfer; reason = reasonText }));
                case ("ACSP" or "ACTC" or "ACWC" or "ACWP" or "PDNG" or "RCVD") List.add(acts, #acknowledge({ uetr; transfer; status }));
                case (other) List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-STATUS"; detail = "transaction status " # other # " is not one this rail acts on" }));
              };
            };
          };
        };
      };
      case (#pacs004) {
        switch (M.readPacs004(doc, minorUnitsOf)) {
          case (#err(is)) issues := is;
          case (#ok(ret)) {
            messageId := ret.messageId;
            for (item in ret.items.vals()) {
              let ?uetr = item.originalUetr else { List.add(acts, #refuse({ uetr = null; rule = "ISO-BIZ-UETR-REQUIRED"; detail = "a return names its original by OrgnlUETR on this rail" })); continue };
              let ?original = SC.transferByReference(sc, r.scheme, uetr) else { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-UNKNOWN-UETR"; detail = "no transfer carries this UETR" })); continue };
              let ?t = SC.transfer(sc, sb, original) else { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-UNKNOWN-UETR"; detail = "no transfer carries this UETR" })); continue };
              if (t.state != #committed and t.state != #settled) { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-RETURN-STATE"; detail = "only a COMMITTED or SETTLED payment can be returned; this one is " # ST.transferStateName(t.state) })); continue };
              if (not Text.equal(item.amount.currency, t.currency)) { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-RETURN-CURRENCY"; detail = "the return is in " # item.amount.currency # ", the payment in " # t.currency })); continue };
              if (item.amount.minor > t.amount) { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-RETURN-AMOUNT"; detail = "the return exceeds the payment" })); continue };
              let ?posting = t.posting else { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-RETURN-STATE"; detail = "the payment has no posting" })); continue };
              // the return is a transfer of its own, payee to payer, under its own reference
              let returnRef = "RTR:" # uetr # ":" # (switch (item.returnId) { case (?id) id; case null ret.messageId });
              switch (SC.transferByReference(sc, r.scheme, returnRef)) {
                case (?existing) { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-DUPLICATE-RETURN"; detail = "this return is already transfer " # Nat.toText(existing) })); continue };
                case null {};
              };
              List.add(acts, #prepare({ uetr = returnRef; payer = t.payee; payee = t.payer; currency = t.currency; amount = item.amount.minor; correctionOf = ?posting; originalTransfer = ?original; hold = null }));
            };
          };
        };
      };
      // ── the extended target list ──
      case (#pacs003) {
        switch (M.readPacs003(doc, minorUnitsOf)) {
          case (#err(is)) issues := is;
          case (#ok(m)) { messageId := m.messageId; for (tx in m.transactions.vals()) collection(tx, true) };
        };
      };
      case (#pacs010) {
        switch (M.readPacs010(doc, minorUnitsOf)) {
          case (#err(is)) issues := is;
          case (#ok(m)) { messageId := m.messageId; for (tx in m.transactions.vals()) collection(tx, false) };
        };
      };
      case (#pacs007 or #pain007) {
        let read = if (family == #pacs007) M.readPacs007(doc, minorUnitsOf) else M.readPain007(doc, minorUnitsOf);
        switch (read) {
          case (#err(is)) issues := is;
          case (#ok(rev)) {
            messageId := rev.messageId; originalMessageId := rev.originalMessageId;
            var i = 0;
            for (item in rev.items.vals()) {
              i += 1;
              // the original by UETR, else by end-to-end id (the customer's reversal names what it knows)
              let ref : ?Text = switch (item.originalUetr) { case (?u) ?u; case null item.originalEndToEndId };
              let ?uetr = ref else { List.add(acts, #refuse({ uetr = null; rule = "ISO-BIZ-UETR-REQUIRED"; detail = "a reversal names its original by OrgnlUETR or OrgnlEndToEndId" })); continue };
              let ?original = SC.transferByReference(sc, r.scheme, uetr) else { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-UNKNOWN-UETR"; detail = "no transfer carries this reference" })); continue };
              let ?t = SC.transfer(sc, sb, original) else { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-UNKNOWN-UETR"; detail = "no transfer carries this reference" })); continue };
              if (t.state != #committed and t.state != #settled) { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-REVERSAL-STATE"; detail = "only a COMMITTED or SETTLED payment can be reversed; this one is " # ST.transferStateName(t.state) })); continue };
              let amount : M.Amount = switch (item.amount) { case (?a) a; case null ({ currency = t.currency; minor = t.amount }) };
              if (not Text.equal(amount.currency, t.currency)) { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-REVERSAL-CURRENCY"; detail = "the reversal is in " # amount.currency # ", the payment in " # t.currency })); continue };
              if (amount.minor > t.amount or amount.minor == 0) { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-REVERSAL-AMOUNT"; detail = "the reversal exceeds the payment or is zero" })); continue };
              let ?posting = t.posting else { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-REVERSAL-STATE"; detail = "the payment has no posting" })); continue };
              let rvId = switch (item.reversalId) { case (?id) id; case null rev.messageId # "-" # Nat.toText(i) };
              let rvRef = "RVS:" # uetr # ":" # rvId;
              switch (SC.transferByReference(sc, r.scheme, rvRef)) { case (?existing) { List.add(acts, #refuse({ uetr = ?uetr; rule = "ISO-BIZ-DUPLICATE-REVERSAL"; detail = "this reversal is already transfer " # Nat.toText(existing) })); continue }; case null {} };
              let reasonText = switch (item.reasonCode, item.reasonProprietary, rev.groupReasonCode, rev.groupReasonProprietary) { case (?c, _, _, _) c; case (null, ?p, _, _) p; case (null, null, ?c, _) c; case (null, null, null, ?p) p; case (_, _, _, _) "reversal" };
              List.add(acts, #reverse({ uetr = rvRef; original; payer = t.payee; payee = t.payer; currency = t.currency; amount = amount.minor; correctionOf = posting; reason = reasonText }));
            };
          };
        };
      };
      case (#pacs029) {
        switch (M.readPacs029(doc, minorUnitsOf)) {
          case (#err(is)) issues := is;
          case (#ok(req)) {
            messageId := req.messageId;
            for (item in req.items.vals()) {
              // the settlement cycle names the window; it must be CLOSED, its settlement not yet opened
              let ?cycle = item.cycle else { List.add(acts, #refuse({ uetr = ?item.instructionId; rule = "ISO-BIZ-REQUIRED"; detail = "SttlmCycl names the settlement window on this rail" })); continue };
              let ?wid = Nat.fromText(cycle) else { List.add(acts, #refuse({ uetr = ?item.instructionId; rule = "ISO-BIZ-UNKNOWN-WINDOW"; detail = "SttlmCycl " # cycle # " is not a window id" })); continue };
              let ?w = SC.window(sc, wid) else { List.add(acts, #refuse({ uetr = ?item.instructionId; rule = "ISO-BIZ-UNKNOWN-WINDOW"; detail = "no window " # cycle })); continue };
              if (w.scheme != r.scheme) { List.add(acts, #refuse({ uetr = ?item.instructionId; rule = "ISO-BIZ-UNKNOWN-WINDOW"; detail = "window " # cycle # " belongs to another scheme" })); continue };
              if (w.state != #closed) { List.add(acts, #refuse({ uetr = ?item.instructionId; rule = "ISO-BIZ-WINDOW-STATE"; detail = "a settlement request needs a CLOSED window; " # cycle # " is " # ST.windowStateName(w.state) })); continue };
              var bad : ?Text = null;
              for (mv in item.movements.vals()) {
                switch (SC.participantOfBic(sc, r.scheme, mv.participantBic)) { case null bad := ?("participant " # mv.participantBic # " is not of scheme " # r.scheme); case (?_) {} };
                if (minorUnitsOf(mv.currency) == null) bad := ?("currency " # mv.currency # " is not registered on the journal");
              };
              switch (bad) { case (?d) { List.add(acts, #refuse({ uetr = ?item.instructionId; rule = "ISO-BIZ-UNKNOWN-AGENT"; detail = d })); continue }; case null {} };
              List.add(acts, #settlementRequest({ window = wid; cycle; movements = item.movements }));
            };
          };
        };
      };
      case (#pain009) {
        switch (M.readPain009(doc, minorUnitsOf)) {
          case (#err(is)) issues := is;
          case (#ok(m)) {
            messageId := m.messageId;
            for (item in m.mandates.vals()) {
              if (mandate(s, railId, item.mandateId) != null) { List.add(acts, #refuse({ uetr = ?item.mandateId; rule = "ISO-BIZ-DUPLICATE-MANDATE"; detail = "mandate " # item.mandateId # " is already in the register" })); continue };
              if (SC.participantOfBic(sc, r.scheme, item.creditorAgent) == null) { List.add(acts, #refuse({ uetr = ?item.mandateId; rule = "ISO-BIZ-UNKNOWN-AGENT"; detail = "creditor agent " # item.creditorAgent # " is not a participant of scheme " # r.scheme })); continue };
              if (SC.participantOfBic(sc, r.scheme, item.debtorAgent) == null) { List.add(acts, #refuse({ uetr = ?item.mandateId; rule = "ISO-BIZ-UNKNOWN-AGENT"; detail = "debtor agent " # item.debtorAgent # " is not a participant of scheme " # r.scheme })); continue };
              switch (item.sequence) { case ("FRST" or "RCUR" or "OOFF" or "FNAL") {}; case (other) { List.add(acts, #refuse({ uetr = ?item.mandateId; rule = "ISO-BIZ-SEQUENCE"; detail = "sequence type " # other })); continue } };
              List.add(acts, #mandate(#mandateInitiated({ mandate = 0; mandateId = item.mandateId; creditorAgent = item.creditorAgent; debtorAgent = item.debtorAgent; debtorAccount = item.debtorAccount; sequence = item.sequence; maxAmount = switch (item.maxAmount) { case (?a) ?a.minor; case null null }; currency = switch (item.maxAmount) { case (?a) ?a.currency; case null null } })));
            };
          };
        };
      };
      case (#pain010) {
        switch (M.readPain010(doc, minorUnitsOf)) {
          case (#err(is)) issues := is;
          case (#ok(m)) {
            messageId := m.messageId;
            for (item in m.items.vals()) {
              let ?existing = mandate(s, railId, item.originalMandateId) else { List.add(acts, #refuse({ uetr = ?item.originalMandateId; rule = "ISO-BIZ-UNKNOWN-MANDATE"; detail = "no mandate " # item.originalMandateId # " on rail " # railId })); continue };
              if (existing.state != #active and existing.state != #pending) { List.add(acts, #refuse({ uetr = ?item.originalMandateId; rule = "ISO-BIZ-MANDATE-STATE"; detail = "mandate is " # PayT.mandateStateName(existing.state) })); continue };
              let acct = if (item.mandate.debtorAccount == "") existing.debtorAccount else item.mandate.debtorAccount;
              let (maxA, ccy) = switch (item.mandate.maxAmount) { case (?a) (?a.minor, ?a.currency); case null (existing.maxAmount, existing.currency) };
              List.add(acts, #mandate(#mandateAmended({ mandate = existing.mandate; mandateId = existing.mandateId; maxAmount = maxA; currency = ccy; debtorAccount = acct; reason = item.reason })));
            };
          };
        };
      };
      case (#pain011) {
        switch (M.readPain011(doc)) {
          case (#err(is)) issues := is;
          case (#ok(m)) {
            messageId := m.messageId;
            for (item in m.items.vals()) {
              let ?existing = mandate(s, railId, item.originalMandateId) else { List.add(acts, #refuse({ uetr = ?item.originalMandateId; rule = "ISO-BIZ-UNKNOWN-MANDATE"; detail = "no mandate " # item.originalMandateId # " on rail " # railId })); continue };
              if (existing.state == #cancelled or existing.state == #completed) { List.add(acts, #refuse({ uetr = ?item.originalMandateId; rule = "ISO-BIZ-MANDATE-STATE"; detail = "mandate is " # PayT.mandateStateName(existing.state) })); continue };
              List.add(acts, #mandate(#mandateCancelled({ mandate = existing.mandate; mandateId = existing.mandateId; reason = item.reason })));
            };
          };
        };
      };
      case (#pain012) {
        switch (M.readPain012(doc)) {
          case (#err(is)) issues := is;
          case (#ok(m)) {
            messageId := m.messageId;
            for (item in m.items.vals()) {
              let ?existing = mandate(s, railId, item.originalMandateId) else { List.add(acts, #refuse({ uetr = ?item.originalMandateId; rule = "ISO-BIZ-UNKNOWN-MANDATE"; detail = "no mandate " # item.originalMandateId # " on rail " # railId })); continue };
              if (existing.state != #pending) { List.add(acts, #refuse({ uetr = ?item.originalMandateId; rule = "ISO-BIZ-MANDATE-STATE"; detail = "only a PENDING mandate takes an acceptance report; this one is " # PayT.mandateStateName(existing.state) })); continue };
              List.add(acts, #mandate(#mandateAccepted({ mandate = existing.mandate; mandateId = existing.mandateId; accepted = item.accepted; reason = item.reason })));
            };
          };
        };
      };
      case (#camt060) {
        switch (M.readCamt060(doc)) {
          case (#err(is)) issues := is;
          case (#ok(m)) {
            messageId := m.messageId;
            var i = 0;
            for (item in m.items.vals()) {
              i += 1;
              let kind = item.requestedMessage;
              if (not (Text.startsWith(kind, #text "camt.052") or Text.startsWith(kind, #text "camt.053"))) { List.add(acts, #refuse({ uetr = item.id; rule = "ISO-BIZ-REPORT-KIND"; detail = "this bank answers camt.052 and camt.053 requests; " # kind # " was asked" })); continue };
              let account : ?Nat = switch (item.accountId) { case (?id) { switch (accountOfId(id)) { case (?a) ?a; case null { List.add(acts, #refuse({ uetr = item.id; rule = "ISO-BIZ-UNKNOWN-ACCOUNT"; detail = "no account " # id })); continue } } }; case null null };
              let fromDay = switch (item.fromDate) { case (?d) dayOf(d); case null null };
              let toDay = switch (item.toDate) { case (?d) dayOf(d); case null null };
              List.add(acts, #record(#reportRequested({ requestId = switch (item.id) { case (?x) x; case null m.messageId # "-" # Nat.toText(i) }; kind; account; fromDay; toDay })));
            };
          };
        };
      };
      case (#camt057) {
        switch (M.readCamt057(doc, minorUnitsOf)) {
          case (#err(is)) issues := is;
          case (#ok(m)) {
            messageId := m.messageId;
            for (item in m.items.vals()) {
              let reference = switch (item.uetr) { case (?u) u; case null { switch (item.endToEndId) { case (?e) e; case null { List.add(acts, #refuse({ uetr = ?item.id; rule = "ISO-BIZ-REQUIRED"; detail = "an item names the payment it expects by UETR or EndToEndId" })); continue } } } };
              if (expectedReceipt(s, railId, reference) != null) { List.add(acts, #refuse({ uetr = ?item.id; rule = "ISO-BIZ-DUPLICATE-EXPECTATION"; detail = "a receipt is already expected under " # reference })); continue };
              let account : ?Nat = switch (item.accountId, m.accountId) { case (?id, _) accountOfId(id); case (null, ?id) accountOfId(id); case (null, null) null };
              List.add(acts, #record(#receiptExpected({ notificationId = m.notificationId; itemId = item.id; reference; amount = item.amount.minor; currency = item.amount.currency; account })));
            };
          };
        };
      };
      case (#camt050) {
        switch (M.readCamt050(doc, minorUnitsOf)) {
          case (#err(is)) issues := is;
          case (#ok(lt)) {
            messageId := lt.messageId;
            // the participant is the debtor institution (liquidity out of its settlement account into its
            // position) or, when only a creditor is named, the creditor (back into the settlement account)
            switch (lt.debtorBic, lt.creditorBic) {
              case (null, null) List.add(acts, #refuse({ uetr = ?lt.endToEndId; rule = "ISO-BIZ-AGENT-BIC"; detail = "a liquidity transfer names the participant by BICFI" }));
              case (d, c) {
                let (bic, toPosition) = switch (d) { case (?b) (b, true); case null { switch (c) { case (?b) (b, false); case null ("", false) } } };
                switch (SC.participantOfBic(sc, r.scheme, bic)) {
                  case null List.add(acts, #refuse({ uetr = ?lt.endToEndId; rule = "ISO-BIZ-UNKNOWN-AGENT"; detail = bic # " is not a participant of scheme " # r.scheme }));
                  case (?p) {
                    if (SC.transferByReference(sc, r.scheme, "LQT:" # lt.endToEndId) != null or liquidityDone(s, railId, lt.endToEndId)) List.add(acts, #refuse({ uetr = ?lt.endToEndId; rule = "ISO-BIZ-DUPLICATE-UETR"; detail = "liquidity transfer " # lt.endToEndId # " was already made" }))
                    else List.add(acts, #liquidity({ endToEndId = lt.endToEndId; participant = p; currency = lt.amount.currency; amount = lt.amount.minor; toPosition }));
                  };
                };
              };
            };
          };
        };
      };
      case (#camt026 or #camt027 or #camt028 or #camt087) {
        switch (M.readInvestigation(doc, family)) {
          case (#err(is)) issues := is;
          case (#ok(inv)) {
            messageId := inv.assignmentId;
            let ref : ?Text = switch (inv.originalUetr) { case (?u) ?u; case null inv.originalEndToEndId };
            let transfer : ?Nat = switch (ref) { case (?u) SC.transferByReference(sc, r.scheme, u); case null null };
            let kind = switch (family) { case (#camt026) "UNABLE_TO_APPLY"; case (#camt027) "CLAIM_NON_RECEIPT"; case (#camt028) "ADDITIONAL_PAYMENT_INFORMATION"; case (_) "REQUEST_TO_MODIFY_PAYMENT" };
            List.add(acts, #record(#caseRecorded({ caseId = switch (inv.caseId) { case (?c) c; case null inv.assignmentId }; assignmentId = inv.assignmentId; kind; uetr = ref; transfer })));
          };
        };
      };
      case (#admi006) {
        switch (M.readAdmi006(doc)) {
          case (#err(is)) issues := is;
          case (#ok(rq)) {
            messageId := rq.messageId;
            if (rq.criteria.size() == 0) issues := [{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/RsndReq/RsndSchCrit"; detail = "a resend request names what to resend" }]
            else {
              for (c in rq.criteria.vals()) {
                // the reference is the message id of the original (SeqNb on this rail); the bank finds it by id
                let reference = switch (c.sequenceNumber) { case (?n) n; case null { switch (c.fileReference) { case (?f) f; case null "" } } };
                let found = if (reference == "") null else messageByMessageId(s, railId, reference);
                List.add(acts, #record(#resendRequested({ reference; messageName = c.originalMessageName; message = found })));
              };
            };
          };
        };
      };
      case (#admi017) {
        switch (M.readAdmi017(doc)) {
          case (#err(is)) issues := is;
          case (#ok(pr)) { messageId := pr.messageId; List.add(acts, #record(#processingRequested({ requestType = pr.requestType; session = pr.session }))) };
        };
      };
      case (#head002) {
        switch (M.readHead002(doc)) {
          case (#err(is)) issues := is;
          case (#ok(fh)) {
            messageId := fh.payloadId;
            if (fh.payloads.size() == 0) issues := [{ rule = "ISO-BIZ-REQUIRED"; path = "/Xchg/Pyld"; detail = "a business file carries at least one payload" }]
            else if (fh.payloads.size() > MAX_FILE_PAYLOADS) issues := [{ rule = "ISO-BIZ-FILE-SIZE"; path = "/Xchg/Pyld"; detail = "a file carries at most " # Nat.toText(MAX_FILE_PAYLOADS) # " payloads; this one " # Nat.toText(fh.payloads.size()) }]
            else {
              // an AppHdr payload is joined to the Document that follows it: one message
              let msgs = List.empty<Blob>();
              var pendingHdr : ?Xml.Element = null;
              for (pl in fh.payloads.vals()) {
                if (PayT.familyOf(pl.namespace) == #head001) pendingHdr := ?pl
                else {
                  let bytes = switch (pendingHdr) { case (?h) Text.encodeUtf8(Xml.serialize(h) # Xml.serializeBody(pl)); case null Text.encodeUtf8(Xml.serialize(pl)) };
                  pendingHdr := null;
                  List.add(msgs, bytes);
                };
              };
              switch (pendingHdr) { case (?_) issues := [{ rule = "ISO-BIZ-FILE-HEADER"; path = "/Xchg/Pyld"; detail = "an AppHdr payload without the Document it heads" }]; case null {} };
              switch (fh.declaredDocuments) { case (?n) { if (n != List.size(msgs)) issues := [{ rule = "ISO-BIZ-COUNT"; path = "/Xchg/PyldDesc/ApplSpcfcs/TtlNbOfDocs"; detail = "TtlNbOfDocs says " # Nat.toText(n) # ", the file carries " # Nat.toText(List.size(msgs)) }] }; case null {} };
              if (issues.size() == 0) List.add(acts, #file({ payloadId = fh.payloadId; declared = switch (fh.declaredDocuments) { case (?n) n; case null List.size(msgs) }; payloads = List.toArray(msgs) }));
            };
          };
        };
      };
      case (#camt053 or #camt054 or #camt052 or #camt025 or #admi007) issues := [{ rule = "ISO-BIZ-OUTBOUND-ONLY"; path = "/" # doc.name; detail = PayT.familyName(family) # " is a message this bank emits, not one it receives" }];
      case (#head001) issues := [{ rule = "ISO-XSD-ROOT"; path = "/AppHdr"; detail = "a header without a document" }];
      case (#unknown) issues := [{ rule = "ISO-XSD-ROOT"; path = "/" # doc.name; detail = "not a family this rail carries" }];
    };
    if (issues.size() > 0) return refusedWhole(family, messageId, signer, issues);
    if (Text.size(messageId) == 0) return refusedWhole(family, messageId, signer, [{ rule = "ISO-BIZ-REQUIRED"; path = "/Document/*/GrpHdr/MsgId"; detail = "message id missing" }]);
    // a message id is unique per rail; the same bytes are never taken twice
    switch (messageByMessageId(s, railId, messageId)) {
      case (?b) return refusedWhole(family, messageId, signer, [{ rule = "ISO-BIZ-DUPLICATE-MESSAGE"; path = "/Document/*/GrpHdr/MsgId"; detail = "message id already received as message " # Nat.toText(b) }]);
      case null {};
    };
    switch (messageByHash(s, hashOf(bytes))) {
      case (?b) return refusedWhole(family, messageId, signer, [{ rule = "ISO-BIZ-DUPLICATE-MESSAGE"; path = "$xml"; detail = "the same bytes were received as message " # Nat.toText(b) }]);
      case null {};
    };
    #ok({ family; messageId; originalMessageId; signer; issues = []; acts = List.toArray(acts) })
  };

  /// The closing record of a message, from the outcomes the actor collected.
  public func received(railId : PayT.RailId, parsed : Parsed, bytes : Blob, outcomes : [PayT.Outcome]) : PayT.PaymentsEvent {
    var anyActed = false; var anyRefused = false; var anyHeld = false;
    for (o in outcomes.vals()) {
      switch (o) {
        case (#held(_)) { anyHeld := true; anyActed := true };
        case (#refused(_)) anyRefused := true;
        case (_) anyActed := true;   // every other outcome is something the message did
      };
    };
    let verdict : PayT.Verdict = if (parsed.issues.size() > 0) #refused else if (anyHeld) #held else if (anyActed) #accepted else if (anyRefused) #refused else #accepted;
    #messageReceived({ rail = railId; family = parsed.family; messageId = parsed.messageId; hash = hashOf(bytes); bytes = bytes.size(); signer = parsed.signer; verdict; issues = parsed.issues; outcomes })
  };

  // ─── extended-list planners: debit authorities and mandate decisions (dual) ───

  public func planGrantDebitAuthority(s : State, sc : SC.State, x : { rail : PayT.RailId; debtor : ST.ParticipantId; creditorBic : Text; currency : Text; maxAmount : Nat }) : Result.Result<PayT.PaymentsEvent, PayT.PaymentsError> {
    let ?r = rail(s, x.rail) else return #err(#UnknownRail({ rail = x.rail }));
    let ?p = SC.participant(sc, x.debtor) else return #err(#InvalidAuthority({ reason = "participant " # Nat.toText(x.debtor) # " is not registered" }));
    if (p.scheme != r.scheme) return #err(#InvalidAuthority({ reason = "participant " # Nat.toText(x.debtor) # " is not of the rail's scheme" }));
    if (not ST.validBic(x.creditorBic)) return #err(#InvalidAuthority({ reason = "creditor BIC " # x.creditorBic # " is not ISO 9362" }));
    if (SC.participantOfBic(sc, r.scheme, x.creditorBic) == null) return #err(#InvalidAuthority({ reason = "creditor " # x.creditorBic # " is not a participant of scheme " # r.scheme }));
    if (SC.accountsIn(p, x.currency) == null) return #err(#InvalidAuthority({ reason = "participant " # Nat.toText(x.debtor) # " holds no accounts in " # x.currency }));
    if (x.maxAmount == 0) return #err(#InvalidAuthority({ reason = "an authority for zero allows nothing; revoke instead" }));
    #ok(#debitAuthorityGranted({ rail = x.rail; debtor = x.debtor; creditorBic = x.creditorBic; currency = x.currency; maxAmount = x.maxAmount }))
  };
  public func planRevokeDebitAuthority(s : State, x : { rail : PayT.RailId; debtor : ST.ParticipantId; creditorBic : Text; currency : Text }) : Result.Result<PayT.PaymentsEvent, PayT.PaymentsError> {
    switch (authority(s, x.rail, x.debtor, x.creditorBic, x.currency)) {
      case (?a) { if (not a.active) return #err(#UnknownAuthority({ rail = x.rail; debtor = x.debtor; creditorBic = x.creditorBic; currency = x.currency })) };
      case null return #err(#UnknownAuthority({ rail = x.rail; debtor = x.debtor; creditorBic = x.creditorBic; currency = x.currency }));
    };
    #ok(#debitAuthorityRevoked({ rail = x.rail; debtor = x.debtor; creditorBic = x.creditorBic; currency = x.currency }))
  };
  /// The bank's decision on a pending mandate of its register (the debtor bank accepts or rejects what
  /// the creditor's bank asked); the pain.012 is derived from the block.
  public func planDecideMandate(s : State, x : { rail : PayT.RailId; mandateId : Text; accepted : Bool; reason : ?Text }) : Result.Result<PayT.PaymentsEvent, PayT.PaymentsError> {
    let ?m = mandate(s, x.rail, x.mandateId) else return #err(#UnknownMandate({ rail = x.rail; mandateId = x.mandateId }));
    if (m.state != #pending) return #err(#MandateState({ rail = x.rail; mandateId = x.mandateId; state = PayT.mandateStateName(m.state) }));
    if (not x.accepted and x.reason == null) return #err(#InvalidRail({ reason = "a rejection carries its reason" }));
    #ok(#mandateDecided({ rail = x.rail; mandateId = x.mandateId; accepted = x.accepted; reason = x.reason }))
  };

  public func planReleaseHold(s : State, sc : SC.State, transfer : Nat, reason : Text) : Result.Result<PayT.PaymentsEvent, PayT.PaymentsError> {
    let ?_ = holdOf(s, transfer) else return #err(#NotHeld({ transfer }));
    ignore sc;
    if (Text.size(reason) == 0) return #err(#InvalidRail({ reason = "a release carries its reason" }));
    #ok(#holdReleased({ transfer; reason }))
  };
  public func planRejectHold(s : State, transfer : Nat, reason : Text) : Result.Result<PayT.PaymentsEvent, PayT.PaymentsError> {
    let ?_ = holdOf(s, transfer) else return #err(#NotHeld({ transfer }));
    if (Text.size(reason) == 0) return #err(#InvalidRail({ reason = "a rejection carries its reason" }));
    #ok(#holdRejected({ transfer; reason }))
  };

  /// The status a received message's pacs.002 answer carries per transaction.
  public func statusLines(m : PayT.Message) : [M.StatusLine] {
    let out = List.empty<M.StatusLine>();
    for (o in m.outcomes.vals()) {
      switch (o) {
        case (#prepared(p)) List.add(out, { originalEndToEndId = null; originalUetr = p.uetr; status = if (p.reserved) "ACSP" else "RJCT"; reasonCode = if (p.reserved) null else ?"AM04"; reasonProprietary = null; additionalInfo = if (p.reserved) null else ?"the reservation was refused by the journal" });
        case (#held(h)) List.add(out, { originalEndToEndId = null; originalUetr = h.uetr; status = "PDNG"; reasonCode = null; reasonProprietary = ?M.clip(h.rule, 35); additionalInfo = ?"held for compliance review" });
        case (#fulfilled(f)) List.add(out, { originalEndToEndId = null; originalUetr = f.uetr; status = "ACSC"; reasonCode = null; reasonProprietary = null; additionalInfo = null });
        case (#rejected(x)) List.add(out, { originalEndToEndId = null; originalUetr = x.uetr; status = "RJCT"; reasonCode = null; reasonProprietary = ?M.clip(x.reason, 35); additionalInfo = null });
        case (#acknowledged(a)) List.add(out, { originalEndToEndId = null; originalUetr = a.uetr; status = a.status; reasonCode = null; reasonProprietary = null; additionalInfo = null });
        case (#returned(r)) {
          // the return's own reference is not a UETR: the answer names the original's UETR and the return id
          let parts = Array.fromIter<Text>(Text.split(r.uetr, #char ':'));
          let (origUetr, rtrId) = if (parts.size() >= 3) (parts[1], parts[2]) else (r.uetr, "");
          List.add(out, { originalEndToEndId = null; originalUetr = origUetr; status = if (r.committed) "ACSC" else if (r.reserved) "ACSP" else "RJCT"; reasonCode = null; reasonProprietary = ?M.clip("RTR " # rtrId, 35); additionalInfo = ?("return of transfer " # Nat.toText(r.original)) });
        };
        case (#reversed(r)) {
          let parts = Array.fromIter<Text>(Text.split(r.uetr, #char ':'));
          let (origUetr, rvId) = if (parts.size() >= 3) (parts[1], parts[2]) else (r.uetr, "");
          List.add(out, { originalEndToEndId = null; originalUetr = origUetr; status = if (r.committed) "ACSC" else if (r.reserved) "ACSP" else "RJCT"; reasonCode = null; reasonProprietary = ?M.clip("RVS " # rvId, 35); additionalInfo = ?("reversal of transfer " # Nat.toText(r.original) # ": " # r.reason) });
        };
        case (#collected(c)) List.add(out, { originalEndToEndId = null; originalUetr = c.uetr; status = if (c.reserved) "ACSP" else "RJCT"; reasonCode = if (c.reserved) null else ?"AM04"; reasonProprietary = null; additionalInfo = if (c.reserved) null else ?"the reservation was refused by the journal" });
        case (#mandateInitiated(_) or #mandateAmended(_) or #mandateCancelled(_) or #mandateAccepted(_) or #settlementRequested(_) or #reportRequested(_) or #receiptExpected(_) or #receiptMatched(_) or #liquidityTransferred(_) or #caseRecorded(_) or #resendRequested(_) or #processingRequested(_) or #fileReceived(_)) {};
        case (#refused(x)) {
          // the ISO external status reason nearest the refusal, the rule id in the additional information
          let code = if (Text.startsWith(x.rule, #text "ISO-BIZ-DUPLICATE")) "AM05" else if (Text.startsWith(x.rule, #text "ISO-BIZ-UNKNOWN-AGENT") or Text.startsWith(x.rule, #text "ISO-BIZ-PARTICIPANT")) "RC01" else if (Text.startsWith(x.rule, #text "ISO-BIZ-UNKNOWN-UETR")) "RR04" else if (Text.startsWith(x.rule, #text "ISO-BIZ-RETURN")) "AM09" else "NARR";
          switch (x.uetr) { case (?u) List.add(out, { originalEndToEndId = null; originalUetr = u; status = "RJCT"; reasonCode = ?code; reasonProprietary = null; additionalInfo = ?M.clip(x.rule # ": " # x.detail, 105) }); case null {} };
        };
      };
    };
    List.toArray(out)
  };

  /// A settlement request's movements against the computed nets: every movement names a participant
  /// whose net in that currency is the movement's amount in the movement's direction, and every
  /// non-zero net is named by a movement. Null when they agree; the first disagreement otherwise.
  public func judgeSettlementRequest(sc : SC.State, scheme : ST.SchemeId, movements : [PayT.Movement], nets : [ST.NetPosition]) : ?Text {
    var covered = 0;
    for (mv in movements.vals()) {
      let ?p = SC.participantOfBic(sc, scheme, mv.participantBic) else return ?("participant " # mv.participantBic # " is not of the scheme");
      var found = false;
      for (n in nets.vals()) {
        if (n.participant == p and Text.equal(n.currency, mv.currency)) {
          found := true;
          let owes = n.debits > n.credits;
          let net = if (owes) n.debits - n.credits else n.credits - n.debits;
          if (net != mv.amount or (net > 0 and owes != mv.debit)) return ?("participant " # mv.participantBic # " " # mv.currency # ": the request says " # (if (mv.debit) "DBIT " else "CRDT ") # Nat.toText(mv.amount) # ", the window nets " # (if (owes) "DBIT " else "CRDT ") # Nat.toText(net));
          if (net > 0) covered += 1;
        };
      };
      if (not found and mv.amount != 0) return ?("participant " # mv.participantBic # " " # mv.currency # ": the request says " # Nat.toText(mv.amount) # ", the window has no position for it");
    };
    var nonZero = 0;
    for (n in nets.vals()) { if (n.debits != n.credits) nonZero += 1 };
    if (nonZero != covered) return ?("the window nets " # Nat.toText(nonZero) # " non-zero positions, the request names " # Nat.toText(covered));
    null
  };

  // ─── the fold ───

  public func apply(s : State, block : Nat, now : Nat64, e : PayT.PaymentsEvent) {
    switch (e) {
      case (#railDeclared(x)) Map.add(s.rails, Text.compare, x.id, { id = x.id; scheme = x.scheme; ttlSeconds = x.ttlSeconds; hold = x.hold; signatures = x.signatures; declaredAt = block });
      case (#connectorKeyRegistered(x)) Map.add(s.keys, cmpRB, (x.rail, x.bic), { rail = x.rail; bic = x.bic; scheme = x.scheme; publicKey = x.publicKey; registeredAt = block });
      case (#messageReceived(x)) {
        let b = R.buf();
        R.putByte(b, PayT.familyOrd(x.family));
        R.putByte(b, switch (x.verdict) { case (#accepted) 1; case (#refused) 2; case (#held) 3 });
        R.putBlob(b, x.hash, 32);
        R.putNat(b, x.outcomes.size(), 4);
        R.putNat(b, Nat64.toNat(now), 8);
        ignore RI.put(s.messageRows, R.key(block, 8), R.done(b, MESSAGE_ROW));
        // only a message that was acted on takes its id and its bytes: a refused one (a bad signature,
        // a schema fault) may be corrected and sent again, and the retry must not be "the same message"
        if (x.verdict != #refused) {
          if (Text.size(x.messageId) > 0) ignore RI.put(s.messageIds, messageIdKey(x.rail, x.messageId), R.key(block, 8));
          ignore RI.put(s.messageHashes, x.hash, R.key(block, 8));
        };
        s.messageCount += 1;
        switch (x.verdict) { case (#accepted) s.accepted += 1; case (#refused) s.refused += 1; case (#held) s.held += 1 };
        for (o in x.outcomes.vals()) {
          switch (o) {
            case (#held(h)) ignore RI.put(s.holds, R.key(h.transfer, 8), holdRow(1, h.rule));
            // ── the extended target list: the register, the expected receipts, the liquidity transfers, the settlement requests ──
            case (#mandateInitiated(m)) {
              ignore RI.put(s.mandates, mandateKey(x.rail, m.mandateId), mandateRow({ rail = x.rail; mandateId = m.mandateId; mandate = block; state = #pending; creditorAgent = m.creditorAgent; debtorAgent = m.debtorAgent; debtorAccount = m.debtorAccount; sequence = m.sequence; maxAmount = m.maxAmount; currency = m.currency; collections = 0; lastBlock = block }));
              s.mandateCount += 1;
            };
            case (#mandateAmended(m)) { switch (mandate(s, x.rail, m.mandateId)) { case (?ex) ignore RI.put(s.mandates, mandateKey(x.rail, m.mandateId), mandateRow({ ex with maxAmount = m.maxAmount; currency = m.currency; debtorAccount = m.debtorAccount; lastBlock = block })); case null {} } };
            case (#mandateCancelled(m)) { switch (mandate(s, x.rail, m.mandateId)) { case (?ex) ignore RI.put(s.mandates, mandateKey(x.rail, m.mandateId), mandateRow({ ex with state = #cancelled; lastBlock = block })); case null {} } };
            case (#mandateAccepted(m)) { switch (mandate(s, x.rail, m.mandateId)) { case (?ex) ignore RI.put(s.mandates, mandateKey(x.rail, m.mandateId), mandateRow({ ex with state = if (m.accepted) #active else #rejected; lastBlock = block })); case null {} } };
            case (#collected(c)) {
              // a collection counts against its mandate; a final or one-off one completes it
              switch (findMandateByBlock(s, x.rail, c.authority, c.uetr)) {
                case (?ex) { if (c.reserved) ignore RI.put(s.mandates, mandateKey(x.rail, ex.mandateId), mandateRow({ ex with collections = ex.collections + 1; state = if (c.final) #completed else ex.state; lastBlock = block })) };
                case null {};
              };
            };
            case (#receiptExpected(e)) { ignore RI.put(s.expected, expectKey(x.rail, e.reference), expectRow(1, block, e.amount, e.currency, 0, e.itemId)); s.expectedCount += 1 };
            case (#receiptMatched(m)) {
              // the matched row is found by the item's notification block: the reference is on the prepared outcome
              ignore m;
            };
            case (#liquidityTransferred(l)) ignore RI.put(s.liquidity, liquidityKey(x.rail, l.endToEndId), R.key(block, 8));
            case (#settlementRequested(q)) Map.add(s.settlementRequests, Nat.compare, q.settlement, { message = block; movements = q.movements; var judged : ?Bool = null });
            case (_) {};
          };
        };
        // a prepared transfer whose reference was expected matches the expectation
        for (o in x.outcomes.vals()) {
          switch (o) {
            case (#prepared(p)) { if (p.reserved) matchExpectation(s, x.rail, p.uetr, p.transfer) };
            case (_) {};
          };
        };
      };
      case (#holdReleased(x)) setHoldState(s, x.transfer, 2);
      case (#holdRejected(x)) setHoldState(s, x.transfer, 3);
      // ── the extended target list ──
      case (#debitAuthorityGranted(x)) Map.add(s.authorities, cmpAuth, (x.rail, x.debtor, x.creditorBic, x.currency), { rail = x.rail; debtor = x.debtor; creditorBic = x.creditorBic; currency = x.currency; maxAmount = x.maxAmount; active = true; grantedAt = block });
      case (#debitAuthorityRevoked(x)) { switch (Map.get(s.authorities, cmpAuth, (x.rail, x.debtor, x.creditorBic, x.currency))) { case (?a) Map.add(s.authorities, cmpAuth, (x.rail, x.debtor, x.creditorBic, x.currency), { a with active = false }); case null {} } };
      case (#mandateDecided(x)) { switch (mandate(s, x.rail, x.mandateId)) { case (?ex) ignore RI.put(s.mandates, mandateKey(x.rail, x.mandateId), mandateRow({ ex with state = if (x.accepted) #active else #rejected; lastBlock = block })); case null {} } };
      case (#settlementRequestJudged(x)) { switch (Map.get(s.settlementRequests, Nat.compare, x.settlement)) { case (?r) r.judged := ?x.matched; case null {} } };
    };
  };

  /// The mandate a collection was made under: the register row whose initiating block is the authority.
  /// Collections carry the mandate id in their transfer's reference path only through the message, so the
  /// register is scanned by block; mandates are few next to postings.
  func findMandateByBlock(s : State, rail : Text, block : Nat, _uetr : Text) : ?PayT.Mandate {
    let (lo, hi) = R.fullRange(32);
    var cursor : ?Blob = null;
    label rows loop {
      let page = RI.range(s.mandates, lo, hi, cursor, 256);
      for ((_, v) in page.entries.vals()) { let m = mandateOfRow(rail, v); if (m.mandate == block) return ?m };
      switch (page.cursor) { case (?c) cursor := ?c; case null break rows };
    };
    null
  };

  /// An expected receipt (camt.057) is matched by the first reserved transfer carrying its reference.
  func matchExpectation(s : State, rail : Text, reference : Text, transfer : Nat) {
    switch (RI.get(s.expected, expectKey(rail, reference))) {
      case (?v) { let a = Blob.toArray(v); if (a[0] == 1) ignore RI.put(s.expected, expectKey(rail, reference), expectRow(2, R.getNat(a, 1, 8), R.getNat(a, 9, 16), R.getText(a, 25, 3), transfer, R.getText(a, 36, 35))) };
      case null {};
    }
  };

  public func fingerprintInto(w : C.Writer, s : State) {
    for ((id, r) in Map.entries(s.rails)) { w.text(id); w.text(r.scheme); w.nat(r.ttlSeconds); w.nat(r.hold.blockedBics.size()); w.nat(r.hold.holdAbove.size()); w.text(PayT.schemeName(r.signatures)); w.nat(r.declaredAt) };
    for (((rl, bic), k) in Map.entries(s.keys)) { w.text(rl); w.text(bic); w.text(PayT.schemeName(k.scheme)); w.blob(k.publicKey) };
    w.nat(s.messageCount); w.nat(s.accepted); w.nat(s.refused); w.nat(s.held);
    // each index as its size and row digest (`RegionIndex` improvement 5), not a walk of its rows
    for (idx in [s.messageRows, s.holds, s.mandates, s.expected, s.liquidity].vals()) { w.nat(RI.size(idx)); w.blobRaw(RI.digest(idx)) };
    w.nat(s.mandateCount); w.nat(s.expectedCount);
    for (((rl, d, cb, cc), a) in Map.entries(s.authorities)) { w.text(rl); w.nat(d); w.text(cb); w.text(cc); w.nat(a.maxAmount); w.bool(a.active); w.nat(a.grantedAt) };
    for ((sid, r) in Map.entries(s.settlementRequests)) { w.nat(sid); w.nat(r.message); w.nat(r.movements.size()); for (m in r.movements.vals()) { w.text(m.participantBic); w.text(m.currency); w.nat(m.amount); w.bool(m.debit) }; switch (r.judged) { case (?j) { w.byte(1); w.bool(j) }; case null w.byte(0) } };
  };
}
