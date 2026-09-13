/// BankCanonical.mo — the byte encoding of the bank log, and of a command.
///
/// Two things are encoded here, for two reasons.
///
/// **Blocks.** Every bank event becomes one block whose bytes are hashed and
/// chained, exactly as the journal's are. The primitive writer and reader are
/// the journal's own (`mo:journal/Canonical`, Apache-2.0, called rather than
/// copied), so the two logs share one encoding of a text, a principal, a
/// natural number and a leg, and one external verifier reads both.
///
/// **Commands.** `commandHash` is the hash a checker approves. The proposal
/// block records the command and this hash; at execution the hash is re-derived
/// from the recorded command and must equal the hash in every approval. A
/// mutation of the stored command between proposal and approval therefore
/// produces a typed refusal instead of executing something nobody approved.
/// That property is the whole reason the encoding must be deterministic: the
/// same command must always produce the same bytes, so every optional field,
/// every array length and every variant tag is written explicitly and nothing
/// depends on map iteration order.
///
/// Versioning follows the lesson recorded in the journal's design note: the
/// decoder accepts every version it can read, from the first commit, so adding
/// a tag later can never make an existing log unreadable.

import Blob "mo:core/Blob";
import Int "mo:core/Int";
import Nat8 "mo:core/Nat8";
import Array "mo:core/Array";
import List "mo:core/List";
import Principal "mo:core/Principal";
import Sha256 "mo:sha2/Sha256";
import Runtime "mo:core/Runtime";

import C "mo:journal/Canonical";
import JT "mo:journal/JournalTypes";

import T "BankTypes";
import PT "PartyTypes";
import PC "ProductCanonical";
import CC "CloseCanonical";
import BC "BatchCanonical";
import RepT "ReportTypes";
import RC "ReportCanonical";
import Iban "Iban";
import AT "ArchiveTypes";
import MT "MonitoringTypes";
import AlT "AlertTypes";
import ColT "CollectionsTypes";
import OCan "OriginationCanonical";
import FCan "FacilityCanonical";
import TCan "TellerCanonical";
import TrT "TradeTypes";
import TrCan "TradeCanonical";
import ICan "IslamicCanonical";
import TyCan "TreasuryCanonical";
import CdCan "CardCanonical";
import IT "IslamicTypes";
import PkT "PackingTypes";
import ST "ShardTypes";
import SeT "SettlementTypes";
import PayT "PaymentsTypes";
import FT "FspiopTypes";

module {

  /// Block format 2 (block format 2): a proposal's command body travels
  /// as a trailer behind the block hash, bound to the preimage by `commandHash`; the execution records the
  /// charge. Format 1 blocks exist only in the batteries' history and are refused.
  public let BLOCK_VERSION : Nat8 = 0x02;
  public let SUPPORTED_BLOCK_VERSIONS : [Nat8] = [0x02];
  public let BLOCK_DOMAIN : Text = "THEBES-BANK-BLOCK-v2";
  /// The command encoding in force for new proposals. The encoders are **frozen per version** (the review of
  /// 12 September): once a pack has dropped a proposal's body, the command is recoverable only while the
  /// encoding of its family is byte-identical to what it was at proposal time, so a change to any existing
  /// family's bytes is a new version with a new encoder function, the old one kept — the rule the block
  /// decoder already follows. A new family (a new tag) may join the current version: it changes no existing
  /// family's bytes. Version 1 is the encoding of every command before 2026-09-13; version 2 appends
  /// `application : ?Nat` to `createCustomer` (the origination link of origination and underwriting) and is otherwise version 1.
  public let COMMAND_ENCODING : Nat8 = 2;
  public func supportsCommandEncoding(v : Nat8) : Bool { v == 1 or v == 2 };
  public func commandDomain(v : Nat8) : Text { "THEBES-BANK-COMMAND-v" # Nat8.toText(v) };
  /// The version-1 domain, kept by name for the readers of the design notes.
  public let COMMAND_DOMAIN : Text = "THEBES-BANK-COMMAND-v1";

  public func supportsVersion(v : Nat8) : Bool {
    for (s in SUPPORTED_BLOCK_VERSIONS.vals()) { if (s == v) return true };
    false
  };

  // ═══════════════════════════════════════════════════════
  //  WRITERS
  // ═══════════════════════════════════════════════════════

  func wOptTexts(w : C.Writer, o : ?[Text]) {
    switch (o) {
      case null w.byte(0);
      case (?xs) { w.byte(1); w.len16(xs.size()); for (x in xs.vals()) { w.text(x) } };
    };
  };

  func wMoney(w : C.Writer, m : T.Money) { w.text(m.currency); w.nat(m.amount) };

  func wOptMoney(w : C.Writer, o : ?[T.Money]) {
    switch (o) {
      case null w.byte(0);
      case (?xs) { w.byte(1); w.len16(xs.size()); for (x in xs.vals()) { wMoney(w, x) } };
    };
  };

  func wScope(w : C.Writer, s : T.Scope) {
    wOptTexts(w, s.books);
    wOptTexts(w, s.currencies);
    wOptMoney(w, s.ceiling);
    wOptMoney(w, s.dailyLimit);
  };


  func wRefusal(w : C.Writer, r : T.RefusalReason) {
    w.byte(switch (r) {
      case (#noGrant) 0; case (#outsideBook) 1; case (#outsideCurrency) 2;
      case (#overCeiling) 3; case (#overDailyLimit) 4; case (#notEligibleChecker) 5;
      case (#selfApproval) 6; case (#commandHashMismatch) 7; case (#proposalExpired) 8;
      case (#featureInactive) 9; case (#bookClosed) 10; case (#noWitness) 11;
      case (#notAdmin) 12;
    })
  };

  func wPolicy(w : C.Writer, p : T.DualPolicy) {
    w.text(p.permission); w.nat(p.required); w.text(p.eligibleRole); w.nat(p.ttlSeconds)
  };

  func wLegs(w : C.Writer, legs : [JT.Leg]) {
    w.len16(legs.size());
    for (l in legs.vals()) {
      w.text(l.account);
      switch (l.subledger) { case null w.byte(0); case (?b) { w.byte(1); w.blob(b) } };
      w.side(l.side); w.text(l.currency); w.nat(l.amount);
    };
  };

  func wManualEntry(w : C.Writer, m : T.ManualEntry) {
    w.text(m.book); w.nat(m.postingDate); w.nat(m.valueDate); w.text(m.period);
    wLegs(w, m.legs); w.text(m.narration); w.blob(m.idempotencyKey); w.optNat(m.correctionOf)
  };

  func wEndpoint(w : C.Writer, e : { #account : Nat; #glAccount : Text }) {
    switch (e) {
      case (#account(n)) { w.byte(0); w.nat(n) };
      case (#glAccount(a)) { w.byte(1); w.text(a) };
    };
  };

  func rEndpoint(r : C.Reader) : ?{ #account : Nat; #glAccount : Text } {
    switch (r.byte()) {
      case (?0) { let ?n = r.nat() else return null; ?#account(n) };
      case (?1) { let ?a = r.text() else return null; ?#glAccount(a) };
      case (_) null;
    }
  };

  func wMoneyMove(w : C.Writer, m : T.MoneyMove) {
    w.nat(m.account); w.nat(m.amount); w.nat(m.postingDate); w.nat(m.valueDate);
    w.text(m.period); w.text(m.narration); PC.wFunding(w, m.funding);
  };

  func wNats(w : C.Writer, xs : [Nat]) { w.len16(xs.size()); for (x in xs.vals()) { w.nat(x) } };


  // ─── party shapes ─────────────────────────────────────────────────────────

  /// The journal's writer has no signed integer, and extension fields have
  /// integer bounds, so one is defined here: a sign byte then the magnitude as a
  /// minimal natural. Zero is written with sign 0, so there is exactly one
  /// encoding of it.
  func wInt(w : C.Writer, i : Int) { w.byte(if (i < 0) 1 else 0); w.nat(Int.abs(i)) };

  func rInt(r : C.Reader) : ?Int {
    let ?sign = r.byte() else return null;
    if (sign > 1) return null;
    let ?mag = r.nat() else return null;
    if (sign == 1) { if (mag == 0) return null;  // negative zero is not an encoding
      ?(-(mag : Int)) } else ?(mag : Int)
  };

  func wPartyKind(w : C.Writer, k : PT.PartyKind) { w.byte(switch (k) { case (#natural) 0; case (#legal) 1 }) };

  func wLifecycle(w : C.Writer, l : PT.Lifecycle) {
    w.byte(switch (l) { case (#prospect) 0; case (#pendingKyc) 1; case (#active) 2; case (#dormant) 3; case (#blocked) 4; case (#closed) 5 })
  };

  func wCdd(w : C.Writer, c : PT.CddLevel) { w.byte(switch (c) { case (#simplified) 0; case (#standard) 1; case (#enhanced) 2 }) };
  func wRisk(w : C.Writer, r : PT.RiskRating) { w.byte(switch (r) { case (#low) 0; case (#medium) 1; case (#high) 2 }) };

  func wFields(w : C.Writer, fs : [PT.FieldCommit]) {
    w.len16(fs.size());
    for (f in fs.vals()) { w.text(f.name); w.blob(f.commit) };
  };

  func wDocument(w : C.Writer, d : PT.DocumentRef) { w.text(d.kind); w.blob(d.commit); w.nat(d.issued); w.optNat(d.expires) };

  func wRelationKind(w : C.Writer, k : PT.RelationKind) {
    switch (k) {
      case (#guarantor) w.byte(0);
      case (#authorisedSignatory) w.byte(1);
      case (#beneficialOwner) w.byte(2);
      case (#director) w.byte(3);
      case (#spouse) w.byte(4);
      case (#parent) w.byte(5);
      case (#child) w.byte(6);
      case (#groupMember) w.byte(7);
      case (#other(t)) { w.byte(8); w.text(t) };
    };
  };

  func wRelationship(w : C.Writer, r : PT.Relationship) { wRelationKind(w, r.kind); w.nat(r.other) };

  func wFieldType(w : C.Writer, t : PT.FieldType) {
    switch (t) {
      case (#text({ maxBytes })) { w.byte(0); w.nat(maxBytes) };
      case (#integer({ min; max })) { w.byte(1); wInt(w, min); wInt(w, max) };
      case (#date) w.byte(2);
      case (#enumerated(vs)) { w.byte(3); w.len16(vs.size()); for (v in vs.vals()) { w.text(v) } };
      case (#boolean) w.byte(4);
      case (#commitment) w.byte(5);
    };
  };

  func wFieldValue(w : C.Writer, v : PT.FieldValue) {
    switch (v) {
      case (#text(t)) { w.byte(0); w.text(t) };
      case (#integer(i)) { w.byte(1); wInt(w, i) };
      case (#date(d)) { w.byte(2); w.nat(d) };
      case (#enumerated(e)) { w.byte(3); w.text(e) };
      case (#boolean(b)) { w.byte(4); w.bool(b) };
      case (#commitment(c)) { w.byte(5); w.blob(c) };
    };
  };

  func wEntityKind(w : C.Writer, e : PT.EntityKind) { w.byte(switch (e) { case (#party) 0; case (#collateral) 1 }) };

  func wFieldDefs(w : C.Writer, fs : [PT.FieldDef]) {
    w.len16(fs.size());
    for (f in fs.vals()) { w.text(f.name); wFieldType(w, f.fieldType); w.bool(f.required) };
  };

  func wExtensionValues(w : C.Writer, vs : [PT.ExtensionValue]) {
    w.len16(vs.size());
    for (v in vs.vals()) { w.text(v.schema); w.text(v.name); wFieldValue(w, v.value) };
  };

  func wCollateralKind(w : C.Writer, k : PT.CollateralKind) {
    switch (k) {
      case (#cashDeposit) w.byte(0);
      case (#property) w.byte(1);
      case (#vehicle) w.byte(2);
      case (#securities) w.byte(3);
      case (#tokenisedTitle({ registry; tokenId })) { w.byte(4); w.principal(registry); w.nat(tokenId) };
      case (#other(t)) { w.byte(5); w.text(t) };
    };
  };

  func wValuation(w : C.Writer, v : PT.Valuation) { w.nat(v.amount); w.text(v.currency); w.nat(v.asOf); w.text(v.source); w.nat(v.haircut) };

  func wAdjacencySide(w : C.Writer, o : ?{ entry : Blob; index : Nat; path : [Blob] }) {
    switch (o) {
      case null w.byte(0);
      case (?x) {
        w.byte(1); w.blob(x.entry); w.nat(x.index);
        w.len16(x.path.size());
        for (h in x.path.vals()) { w.blob(h) };
      };
    };
  };

  func wAdjacency(w : C.Writer, p : PT.AdjacencyProof) { wAdjacencySide(w, p.lower); wAdjacencySide(w, p.upper) };

  func wScreeningDecision(w : C.Writer, d : PT.ScreeningDecision) {
    w.nat(d.party); w.text(d.listVersion); w.blob(d.listRoot);
    switch (d.decision) {
      case (#clear) w.byte(0);
      case (#hit({ matches })) { w.byte(1); w.nat(matches) };
      case (#cleared({ reason })) { w.byte(2); w.text(reason) };
      case (#confirmed) w.byte(3);
    };
    w.principal(d.screener); w.blob(d.justificationCommit);
  };

  func wFormat(w : C.Writer, f : Iban.Format) { w.text(f.country); w.text(f.bank); w.text(f.branch); w.nat(f.serialWidth); w.text(f.prefix) };

  func wJwks(w : C.Writer, j : PT.Jwks) {
    w.text(j.issuer); w.len16(j.keys.size());
    for (k in j.keys.vals()) { w.text(k.kid); w.blob(k.n); w.blob(k.e) };
    w.nat(j.pinnedAtBlock);
  };

  func wAssurance(w : C.Writer, a : PT.Assurance) { w.byte(switch (a) { case (#aal1) 0; case (#aal2) 1; case (#aal3) 2 }) };

  func wCredential(w : C.Writer, c : PT.Credential) {
    w.principal(c.subject);
    switch (c.kind) {
      case (#passkey({ aaguid })) { w.byte(0); w.blob(aaguid) };
      case (#oidc({ issuer; subjectCommit })) { w.byte(1); w.text(issuer); w.blob(subjectCommit) };
    };
    wAssurance(w, c.assurance); w.nat(c.registeredAtBlock); w.optNat(c.revokedAtBlock);
  };

  public func writePartyEvent(w : C.Writer, e : PT.PartyEvent) {
    switch (e) {
      case (#partyCreated(x)) {
        w.byte(0x01); wPartyKind(w, x.kind); w.blob(x.salt); w.blob(x.identityCommit);
        switch (x.dedupCommit) { case null w.byte(0); case (?d) { w.byte(1); w.blob(d) } };
        wFields(w, x.attributes); w.text(x.book); wCdd(w, x.cddLevel); wRisk(w, x.riskRating); w.bool(x.pep); w.nat(x.reviewDue);
      };
      case (#partyAmended(x)) { w.byte(0x02); w.nat(x.party); wFields(w, x.attributes) };
      case (#partyLifecycleSet(x)) { w.byte(0x03); w.nat(x.party); wLifecycle(w, x.to) };
      case (#partyCddSet(x)) { w.byte(0x04); w.nat(x.party); wCdd(w, x.level); wRisk(w, x.riskRating); w.bool(x.pep); w.nat(x.reviewDue) };
      case (#partyDocumentAdded(x)) { w.byte(0x05); w.nat(x.party); wDocument(w, x.document) };
      case (#partyRelationshipAdded(x)) { w.byte(0x06); w.nat(x.party); wRelationship(w, x.relationship) };
      case (#partyExtensionSet(x)) { w.byte(0x07); w.nat(x.party); wExtensionValues(w, x.values) };
      case (#partyIdentifierIssued(x)) { w.byte(0x08); w.nat(x.party); w.text(x.identifier) };
      case (#screeningListCommitted(x)) { w.byte(0x09); w.text(x.version); w.blob(x.root); w.nat(x.count); w.text(x.normalisation) };
      case (#screeningProven(x)) { w.byte(0x0A); w.nat(x.party); w.text(x.listVersion) };
      case (#screeningDecisionRecorded(d)) { w.byte(0x0B); wScreeningDecision(w, d) };
      case (#schemaRegistered(x)) { w.byte(0x0C); w.text(x.id); wEntityKind(w, x.entity); wFieldDefs(w, x.fields) };
      case (#collateralRegistered(x)) { w.byte(0x0D); w.nat(x.party); wCollateralKind(w, x.kind); wValuation(w, x.valuation); w.blob(x.descriptionCommit) };
      case (#collateralRevalued(x)) { w.byte(0x0E); w.nat(x.collateral); wValuation(w, x.valuation) };
      case (#collateralAllocated(x)) { w.byte(0x0F); w.nat(x.collateral); w.text(x.facility); w.nat(x.amount) };
      case (#collateralReleased(x)) { w.byte(0x10); w.nat(x.collateral) };
      case (#staffAdded(x)) { w.byte(0x11); w.principal(x.principal_); w.text(x.book); w.text(x.title) };
      case (#staffRemoved(x)) { w.byte(0x12); w.principal(x.principal_) };
      case (#accountFormatSet(f)) { w.byte(0x13); wFormat(w, f) };
      case (#jwksPinned(j)) { w.byte(0x14); wJwks(w, j) };
      case (#credentialRegistered(c)) { w.byte(0x15); wCredential(w, c) };
      case (#credentialRevoked(x)) { w.byte(0x16); w.principal(x.subject) };
      case (#reviewGraceSet(x)) { w.byte(0x17); w.nat(x.days) };
    };
  };

  func wStatementMap(w : C.Writer, m : RepT.StatementMap) {
    w.len16(m.cash.size()); for (x in m.cash.vals()) w.text(x);
    w.text(m.retainedEarnings);
    w.len16(m.investing.size()); for (x in m.investing.vals()) w.text(x);
    w.len16(m.financing.size()); for (x in m.financing.vals()) w.text(x);
    w.len16(m.monetary.size()); for (x in m.monetary.vals()) w.text(x);
  };

  func rTextList(r : C.Reader) : ?[Text] {
    let ?n = r.len16() else return null;
    let out = List.empty<Text>();
    var i = 0;
    while (i < n) { let ?x = r.text() else return null; List.add(out, x); i += 1 };
    ?List.toArray(out)
  };

  func rStatementMap(r : C.Reader) : ?RepT.StatementMap {
    let ?cash = rTextList(r) else return null;
    let ?re = r.text() else return null;
    let ?investing = rTextList(r) else return null;
    let ?financing = rTextList(r) else return null;
    let ?monetary = rTextList(r) else return null;
    ?{ cash; retainedEarnings = re; investing; financing; monetary }
  };

  /// The current encoding of a command — what a new proposal hashes and carries.
  public func writeCommand(w : C.Writer, c : T.Command) { ignore writeCommandAt(COMMAND_ENCODING, w, c) };

  /// A command's bytes under a recorded encoding version. False when the version is not one this build
  /// knows, or the command carries a field that version cannot represent (version 1 has no `application`
  /// on `createCustomer`): the caller treats either as "no bytes", never as an encoding.
  public func writeCommandAt(version : Nat8, w : C.Writer, c : T.Command) : Bool {
    switch (version) {
      case 1 {
        switch (c) { case (#createCustomer(cc)) { if (cc.application != null) return false }; case (_) {} };
        writeCommandBody(w, c, false); true
      };
      case 2 { writeCommandBody(w, c, true); true };
      case (_) false;
    }
  };

  /// The one body both versions share: `withApplication` is the only difference between them — version 2
  /// writes `createCustomer`'s `application` after the accounts. FROZEN for every family listed as of
  /// 2026-09-13 (the golden vectors in test/BankCanonical.test.mo fail the build the moment a family's
  /// bytes drift); a change to an existing family's bytes is version 3, written as a new function.
  func writeCommandBody(w : C.Writer, c : T.Command, withApplication : Bool) {
    switch (c) {
      case (#defineRole(x)) { w.byte(0x01); w.text(x.id); w.text(x.name); w.len16(x.permissions.size()); for (p in x.permissions.vals()) { w.text(p) } };
      case (#grantRole(x)) { w.byte(0x02); w.principal(x.subject); w.text(x.role); wScope(w, x.scope) };
      case (#revokeRole(x)) { w.byte(0x03); w.principal(x.subject); w.text(x.role) };
      case (#setDualPolicy(x)) { w.byte(0x04); wPolicy(w, x) };
      case (#clearDualPolicy(x)) { w.byte(0x05); w.text(x.permission) };
      case (#openBook(x)) { w.byte(0x06); w.text(x.id); w.text(x.name); switch (x.parent) { case null w.byte(0); case (?p) { w.byte(1); w.text(p) } } };
      case (#closeBook(x)) { w.byte(0x07); w.text(x.id) };
      case (#transferBankAdmin(x)) { w.byte(0x08); w.principal(x.admin) };
      case (#setFeatureActivation(x)) { w.byte(0x09); w.text(x.feature); w.nat64(x.height) };
      case (#journalRegisterCurrency(x)) { w.byte(0x20); w.text(x.code); w.nat8(x.minorUnits) };
      case (#journalOpenAccount(x)) { w.byte(0x21); w.text(x.code); w.text(x.name); w.side(x.normalSide); w.category(x.category); w.constraint(x.constraint) };
      case (#journalCloseAccount(x)) { w.byte(0x22); w.text(x.code) };
      case (#journalOpenPeriod(x)) { w.byte(0x23); w.text(x.id); w.nat(x.start); w.nat(x.end) };
      case (#journalClosePeriod(x)) { w.byte(0x24); w.text(x.id) };
      case (#journalSetActivationHeight(x)) { w.byte(0x25); w.nat64(x.height) };
      case (#journalSetLeadsheetSchema(x)) { w.byte(0x26); w.len16(x.ranges.size()); for (r in x.ranges.vals()) { w.range(r) } };
      case (#journalAddPoster(x)) { w.byte(0x27); w.principal(x.poster) };
      case (#journalRemovePoster(x)) { w.byte(0x28); w.principal(x.poster) };
      case (#journalSetPosterScope(x)) { w.byte(0x29); w.principal(x.poster); wOptTexts(w, x.accounts) };
      case (#journalRollBusinessDate(x)) { w.byte(0x2A); w.nat(x.day) };
      case (#journalSetCalendar(x)) { w.byte(0x2B); w.calendar(x.calendar) };
      case (#journalSetCalendarAuthority(x)) { w.byte(0x2C); w.calendarAuthority(x.authority); w.nat(x.maxRollDays); w.optNat(x.businessDate) };
      case (#postManualEntry(x)) { w.byte(0x40); wManualEntry(w, x) };
      case (#reverseManualEntry(x)) { w.byte(0x41); w.nat(x.original); w.text(x.book); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration); w.blob(x.idempotencyKey) };
      case (#postManualEntryForParty(x)) { w.byte(0x42); w.nat(x.party); wManualEntry(w, x.entry) };
      case (#createParty(x)) {
        w.byte(0x50); wPartyKind(w, x.kind); w.blob(x.salt); w.blob(x.identityCommit);
        switch (x.dedupCommit) { case null w.byte(0); case (?d) { w.byte(1); w.blob(d) } };
        wFields(w, x.attributes); w.text(x.book); wCdd(w, x.cddLevel); wRisk(w, x.riskRating); w.bool(x.pep); w.nat(x.reviewDue);
      };
      case (#amendParty(x)) { w.byte(0x51); w.nat(x.party); wFields(w, x.attributes) };
      case (#createCustomer(c)) {
        w.byte(0x19);
        let x = c.party;
        wPartyKind(w, x.kind); w.blob(x.salt); w.blob(x.identityCommit);
        switch (x.dedupCommit) { case null w.byte(0); case (?d) { w.byte(1); w.blob(d) } };
        wFields(w, x.attributes); w.text(x.book); wCdd(w, x.cddLevel); wRisk(w, x.riskRating); w.bool(x.pep); w.nat(x.reviewDue);
        w.len16(c.documents.size()); for (d in c.documents.vals()) wDocument(w, d);
        switch (c.screening) {
          case null w.byte(0);
          case (?sc) {
            w.byte(1); w.text(sc.listVersion); w.blob(sc.listRoot);
            switch (sc.decision) { case (#clear) w.byte(0); case (#hit({ matches })) { w.byte(1); w.nat(matches) }; case (#cleared({ reason })) { w.byte(2); w.text(reason) }; case (#confirmed) w.byte(3) };
            w.principal(sc.screener); w.blob(sc.justificationCommit);
          };
        };
        wLifecycle(w, c.lifecycle);
        wExtensionValues(w, c.extensions);
        w.len16(c.accounts.size());
        for (a in c.accounts.vals()) { w.text(a.product); w.text(a.currency); w.optNat(a.termDays); PC.wComponents(w, a.allocationOrder); w.bool(a.activate) };
        if (withApplication) w.optNat(c.application);
      };
      case (#setPartyLifecycle(x)) { w.byte(0x52); w.nat(x.party); wLifecycle(w, x.to) };
      case (#setPartyCdd(x)) { w.byte(0x53); w.nat(x.party); wCdd(w, x.level); wRisk(w, x.riskRating); w.bool(x.pep); w.nat(x.reviewDue) };
      case (#addPartyDocument(x)) { w.byte(0x54); w.nat(x.party); wDocument(w, x.document) };
      case (#addPartyRelationship(x)) { w.byte(0x55); w.nat(x.party); wRelationship(w, x.relationship) };
      case (#setPartyExtension(x)) { w.byte(0x56); w.nat(x.party); wExtensionValues(w, x.values) };
      case (#issueIdentifier(x)) { w.byte(0x57); w.nat(x.party) };
      case (#commitScreeningList(x)) { w.byte(0x58); w.text(x.version); w.blob(x.root); w.nat(x.count); w.text(x.normalisation) };
      case (#proveScreeningClear(x)) { w.byte(0x59); w.nat(x.party); w.text(x.listVersion); w.blob(x.subject); wAdjacency(w, x.proof) };
      case (#recordScreeningDecision(d)) { w.byte(0x5A); wScreeningDecision(w, d) };
      case (#registerSchema(x)) { w.byte(0x5B); w.text(x.id); wEntityKind(w, x.entity); wFieldDefs(w, x.fields) };
      case (#registerCollateral(x)) { w.byte(0x5C); w.nat(x.party); wCollateralKind(w, x.kind); wValuation(w, x.valuation); w.blob(x.descriptionCommit) };
      case (#revalueCollateral(x)) { w.byte(0x5D); w.nat(x.collateral); wValuation(w, x.valuation) };
      case (#allocateCollateral(x)) { w.byte(0x5E); w.nat(x.collateral); w.text(x.facility); w.nat(x.amount) };
      case (#releaseCollateral(x)) { w.byte(0x5F); w.nat(x.collateral) };
      case (#addStaff(x)) { w.byte(0x60); w.principal(x.principal_); w.text(x.book); w.text(x.title) };
      case (#removeStaff(x)) { w.byte(0x61); w.principal(x.principal_) };
      case (#setAccountFormat(f)) { w.byte(0x62); wFormat(w, f) };
      case (#setReviewGrace(x)) { w.byte(0x63); w.nat(x.days) };
      case (#pinJwks(j)) { w.byte(0x64); wJwks(w, j) };
      case (#registerCredential(c)) { w.byte(0x65); wCredential(w, c) };
      case (#revokeCredential(x)) { w.byte(0x66); w.principal(x.subject) };
      // ── the product engine ──
      case (#registerProduct(x)) { w.byte(0x70); w.text(x.id); w.text(x.name); PC.wTerms(w, x.terms) };
      case (#amendProduct(x)) { w.byte(0x71); w.text(x.id); w.text(x.name); PC.wTerms(w, x.terms) };
      case (#closeProductToNewAccounts(x)) { w.byte(0x72); w.text(x.id); w.nat(x.version) };
      case (#openAccount(x)) { w.byte(0x73); w.text(x.product); w.nat(x.party); w.text(x.currency); w.optNat(x.termDays); PC.wComponents(w, x.allocationOrder) };
      case (#setAccountStatus(x)) { w.byte(0x74); w.nat(x.account); PC.wStatus(w, x.to) };
      case (#migrateAccount(x)) { w.byte(0x75); w.nat(x.account); w.nat(x.to) };
      case (#openTill(x)) { w.byte(0x76); w.text(x.till); w.text(x.book); w.text(x.currency); w.principal(x.holder); w.text(x.product) };
      case (#closeTill(x)) { w.byte(0x77); w.text(x.till) };
      case (#grantFacility(x)) { w.byte(0x78); w.nat(x.account); w.nat(x.limit) };
      case (#depositToAccount(x)) { w.byte(0x79); wMoneyMove(w, x) };
      case (#withdrawFromAccount(x)) { w.byte(0x7A); wMoneyMove(w, x) };
      case (#transferBetweenAccounts(x)) {
        w.byte(0x7B); w.nat(x.from); w.nat(x.to); w.nat(x.amount);
        w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration);
      };
      case (#applyCharge(x)) {
        w.byte(0x7C); w.nat(x.account); w.text(x.charge); w.nat(x.occurrence); PC.wChargeBase(w, x.base);
        w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration);
      };
      case (#waiveCharge(x)) {
        w.byte(0x7D); w.nat(x.account); w.text(x.charge); w.nat(x.occurrence);
        w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.reason);
      };
      case (#postAccrual(x)) { w.byte(0x7E); w.text(x.product); w.text(x.currency); w.nat(x.day); w.text(x.period); w.text(x.narration) };
      case (#capitaliseInterest(x)) {
        w.byte(0x7F); w.text(x.product); w.text(x.currency); w.nat(x.to);
        w.nat(x.postingDate); w.text(x.period); w.text(x.narration);
      };
      case (#disburseLoan(x)) { w.byte(0x80); wMoneyMove(w, x) };
      case (#repayLoan(x)) { w.byte(0x81); wMoneyMove(w, x) };
      case (#rescheduleLoan(x)) { w.byte(0x82); w.nat(x.account); w.nat(x.effective); PC.wSchedule(w, x.terms); PC.wRate(w, x.rate) };
      case (#setProvision(x)) { w.byte(0x83); w.nat(x.account); w.nat(x.asOf); w.nat(x.postingDate); w.text(x.period); w.text(x.narration) };
      case (#writeOffLoan(x)) { w.byte(0x84); w.nat(x.account); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#recordRecovery(x)) { w.byte(0x85); wMoneyMove(w, x) };
      case (#redeemTermDeposit(x)) { w.byte(0x86); wMoneyMove(w, x) };
      case (#allocateCashToTill(x)) { w.byte(0x87); w.text(x.till); w.nat(x.amount); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#returnCashFromTill(x)) { w.byte(0x88); w.text(x.till); w.nat(x.amount); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#settleTill(x)) { w.byte(0x89); w.text(x.till); w.nat(x.declared); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      // ── value dating, foreign currency and the close ──
      case (#setFunctionalCurrency(x)) { w.byte(0x90); w.text(x.currency) };
      case (#setFxPair(x)) { w.byte(0x91); CC.wPair(w, x.pair) };
      case (#setFxRate(x)) { w.byte(0x92); CC.wRate(w, x.rate) };
      case (#setBackValueWindow(x)) { w.byte(0x93); CC.wWindow(w, x.window) };
      case (#approveBackValue(x)) { w.byte(0x94); w.text(x.book); w.nat(x.valueDate); w.text(x.reason) };
      case (#openDeferralSchedule(x)) { w.byte(0x95); CC.wSchedule(w, x.schedule) };
      case (#bookFxDeal(x)) {
        w.byte(0x96); w.text(x.sell); w.nat(x.sellAmount); wEndpoint(w, x.sellFrom);
        w.text(x.buy); w.nat(x.buyAmount); wEndpoint(w, x.buyTo);
        w.nat(x.rateAsOf); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration);
      };
      case (#realiseFxPosition(x)) {
        w.byte(0x97); w.text(x.currency); w.nat(x.closedPosition); w.nat(x.bookedEquivalent);
        w.nat(x.proceeds); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration);
      };
      case (#adjustAccrual(x)) {
        w.byte(0x98); w.text(x.product); w.text(x.currency); w.nat(x.from); w.nat(x.to);
        w.nat(x.causedBy); w.nat(x.postingDate); w.text(x.period); w.text(x.narration);
      };
      case (#amortiseDeferral(x)) {
        w.byte(0x99); w.text(x.schedule); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration);
      };
      case (#openPeriodEnd(x)) { w.byte(0x9A); w.text(x.book); w.text(x.period) };
      case (#recordClosingRates(x)) { w.byte(0x9B); w.text(x.book); w.text(x.period) };
      case (#markAccrualComplete(x)) { w.byte(0x9C); w.text(x.book); w.text(x.period) };
      case (#revaluePositions(x)) { w.byte(0x9D); w.text(x.book); w.text(x.period); w.nat(x.postingDate); w.text(x.narration) };
      case (#amortisePeriodDeferrals(x)) { w.byte(0x9E); w.text(x.book); w.text(x.period); w.nat(x.postingDate); w.text(x.narration) };
      case (#reconcilePeriod(x)) { w.byte(0x9F); w.text(x.book); w.text(x.period) };
      case (#closePeriodEnd(x)) { w.byte(0xA0); w.text(x.book); w.text(x.period) };
      case (#rollYearEnd(x)) { w.byte(0xA1); w.text(x.book); w.text(x.period); w.text(x.retainedEarnings); w.text(x.narration) };
      // ── the end-of-day batch ──
      case (#setRetryPolicy(x)) { w.byte(0xB0); w.text(x.policy.book); w.nat(x.policy.limit) };
      case (#defineStandingInstruction(x)) { w.byte(0xB1); BC.wInstruction(w, x.instruction) };
      case (#cancelStandingInstruction(x)) { w.byte(0xB2); w.text(x.id) };
      case (#openEndOfDay(x)) { w.byte(0xB3); w.text(x.book); w.nat(x.businessDate); w.nat(x.shardSize) };
      case (#resolveBatchFailure(x)) {
        w.byte(0xB4); w.text(x.book); w.nat(x.businessDate); w.nat(x.item); w.text(x.entity); w.text(x.justification);
      };
      // ── reporting ──
      case (#registerReportDefinition(x)) { w.byte(0xC0); RC.wDef(w, x.definition) };
      case (#registerReturnTemplate(x)) { w.byte(0xC1); RC.wTemplate(w, x.template) };
      case (#setStatementMap(x)) { w.byte(0xC2); w.text(x.book); wStatementMap(w, x.map) };
      case (#certifyReport(x)) {
        w.byte(0xC3); w.text(x.definition); w.nat(x.version); w.text(x.book); w.text(x.period);
        w.byte(switch (x.view) { case (#native) 0; case (#functional) 1 });
        switch (x.functional) { case null w.byte(0); case (?c) { w.byte(1); w.text(c) } };
      };
      case (#certifyReturn(x)) { w.byte(0xC4); w.text(x.template); w.nat(x.version); w.text(x.book); w.text(x.period) };
      case (#certifyExport(x)) {
        w.byte(0xC5);
        w.byte(switch (x.shape) { case (#safT) 1; case (#aicpaAds) 2; case (#normalisedTrialBalance) 3 });
        w.text(x.book); w.text(x.period);
      };
      case (#issueStatement(x)) {
        w.byte(0xC6); w.nat(x.account);
        switch (x.kind) {
          case (#camt053(k)) { w.byte(0x53); w.nat(k.cut) };
          case (#camt052(k)) { w.byte(0x52); w.nat(k.asOf) };
          case (#camt054(k)) { w.byte(0x54); w.nat(k.movement) };
        };
        w.text(x.period);
      };
      case (#setFeedEndpoint(x)) {
        w.byte(0xC7); w.text(x.endpoint.url);
        w.len16(x.endpoint.retries.size());
        for (r in x.endpoint.retries.vals()) w.nat(r);
        w.byte(if (x.endpoint.active) 1 else 0);
      };
      case (#recordFeedDeadLetter(x)) {
        w.byte(0xC8); w.nat(x.letter.cursor); w.text(x.letter.endpoint);
        w.nat(x.letter.attempts); w.text(x.letter.reason);
      };
      case (#setCounterpartyClassDimension(x)) {
        w.byte(0xC9);
        switch (x.dimension) {
          case (?d) { w.byte(1); w.text(d.schema); w.text(d.field) };
          case null w.byte(0);
        };
      };
      case (#pinArchiveImage(x)) { w.byte(0xCA); w.blob(x.sha256); w.nat(x.bytes); w.text(x.name) };
      case (#setArchiveControllers(x)) { w.byte(0xCB); wPrincipals(w, x.controllers) };
      case (#spawnArchive(x)) { w.byte(0xCC); w.text(x.purpose) };
      case (#abandonArchiveSpawn(x)) { w.byte(0xCD); w.nat(x.spawn); w.text(x.reason) };
      case (#attachArchiveChild(x)) { w.byte(0xCE); w.nat(x.spawn); w.nat64(x.cid) };
      case (#adoptArchiveChild(x)) { w.byte(0xCF); w.nat64(x.cid); w.blob(x.moduleHash); wPrincipals(w, x.controllers); w.text(x.purpose) };
      case (#defineMonitoringRule(x)) { w.byte(0xD0); w.text(x.id); wOptText(w, x.currency); writeRuleSpec(w, x.spec) };
      case (#retireMonitoringRule(x)) { w.byte(0xD1); w.text(x.id) };
      case (#clearAlert(x)) { w.byte(0xD2); w.nat(x.alert); w.text(x.reason) };
      case (#escalateAlert(x)) { w.byte(0xD3); w.nat(x.alert); w.text(x.reportRef) };
      // ── collections and recovery (collections and recovery) ──
      case (#setCollectionsPolicy(p)) { w.byte(0xF0); wCollectionsPolicy(w, p) };
      case (#markUnlikelyToPay(x)) { w.byte(0xF1); w.nat(x.account); w.text(x.reason) };
      case (#recordCollectionAction(x)) { w.byte(0xF2); w.nat(x.account); wCollectionAction(w, x.action); w.text(x.outcome); w.optNat(x.next) };
      case (#recordPromiseToPay(x)) { w.byte(0xF3); w.nat(x.account); w.nat(x.amount); w.nat(x.by) };
      case (#assignCollector(x)) { w.byte(0xF4); w.nat(x.account); w.principal(x.staff) };
      case (#closeRecovery(x)) { w.byte(0xF5); w.nat(x.account) };
      // ── origination and underwriting (origination and underwriting) ──
      case (#setOriginationPolicy(p)) { w.byte(0xA2); OCan.writePolicy(w, p) };
      case (#setAffordabilityModel(m)) { w.byte(0xA3); OCan.writeAffordabilityModel(w, m) };
      case (#setScorecard(c)) { w.byte(0xA4); OCan.writeScorecard(w, c) };
      case (#registerPasskey(x)) { w.byte(0xA5); w.nat(x.party); w.blob(x.credentialId); w.blob(x.publicKeySpki) };
      case (#openApplication(x)) { w.byte(0xA6); w.optNat(x.party); w.text(x.book); OCan.writeRequest(w, x.request); w.text(x.channel) };
      case (#recordApplicationData(x)) { w.byte(0xA7); w.nat(x.application); OCan.writeFacts(w, x.facts); OCan.writeCommitments(w, x.commitments) };
      case (#assessAffordability(x)) { w.byte(0xA8); w.nat(x.application) };
      case (#requestBureauReport(x)) { w.byte(0xA9); w.nat(x.application); w.text(x.bureau); w.blob(x.consentCommit) };
      case (#scoreApplication(x)) { w.byte(0xAA); w.nat(x.application) };
      case (#underwrite(x)) { w.byte(0xAB); w.nat(x.application); OCan.writeDecision(w, x.decision); w.text(x.rationale) };
      case (#issueOffer(x)) { w.byte(0xAC); w.nat(x.application); OCan.writeTerms(w, x.terms) };
      case (#acceptOffer(x)) { w.byte(0xAD); w.nat(x.application); OCan.writeAssertion(w, x.assertion) };
      case (#declineOffer(x)) { w.byte(0xAE); w.nat(x.application) };
      case (#recordDocument(x)) { w.byte(0xAF); w.nat(x.application); OCan.writeKind(w, x.kind); w.blob(x.sha256); OCan.writeOptAssertion(w, x.signed) };
      case (#recordConditionsMet(x)) { w.byte(0xB5); w.nat(x.application); w.len16(x.conditions.size()); for (c in x.conditions.vals()) w.text(c) };
      case (#fulfilApplication(x)) { w.byte(0xB6); w.nat(x.application) };
      case (#withdrawApplication(x)) { w.byte(0xB7); w.nat(x.application); w.text(x.reason) };
      // ── corporate lending (corporate lending) ──
      case (#openFacility(t)) { w.byte(0x30); FCan.writeTerms(w, t) };
      case (#drawdown(x)) { w.byte(0x31); w.nat(x.facility); w.nat(x.amount); PC.wFunding(w, x.funding); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#transferParticipation(x)) { w.byte(0x32); w.nat(x.facility); w.nat(x.from); w.nat(x.to); w.nat(x.bps) };
      case (#distributeToParticipants(x)) { w.byte(0x33); w.nat(x.facility); PC.wFunding(w, x.funding); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#restructureFacility(x)) { w.byte(0x34); w.nat(x.facility); w.nat(x.effective); FCan.writeRestructure(w, x.terms) };
      case (#recordCovenantTest(x)) { w.byte(0x35); w.nat(x.facility); w.text(x.covenant); w.nat(x.value); w.blob(x.statementHash) };
      case (#blockDrawdowns(x)) { w.byte(0x36); w.nat(x.facility); w.text(x.reason) };
      case (#unblockDrawdowns(x)) { w.byte(0x37); w.nat(x.facility); w.text(x.reason) };
      case (#recordFacilityReview(x)) { w.byte(0x38); w.nat(x.facility); w.text(x.note) };
      case (#recordRateFixing(x)) { w.byte(0x39); w.text(x.index); w.nat(x.day); w.nat(x.rateBps) };
      case (#receiveRental(x)) { w.byte(0x3A); w.nat(x.facility); w.nat(x.amount); PC.wFunding(w, x.funding); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#remeasureResidual(x)) { w.byte(0x3B); w.nat(x.facility); w.nat(x.residual); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#purchaseReceivables(x)) { w.byte(0x3C); w.nat(x.facility); FCan.writeReceivables(w, x.receivables); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#collectReceivable(x)) { w.byte(0x3D); w.nat(x.facility); w.blob(x.ref); PC.wFunding(w, x.funding); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#dishonourReceivable(x)) { w.byte(0x3E); w.nat(x.facility); w.blob(x.ref); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#writeOffReceivable(x)) { w.byte(0x3F); w.nat(x.facility); w.blob(x.ref); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#closeFacility(x)) { w.byte(0x43); w.nat(x.facility) };
      // ── branch and teller (branch and teller) ──
      case (#setTellerPolicy(p)) { w.byte(0xF6); TCan.writePolicy(w, p) };
      // trade finance trade finance: tags 0x67-0x6F, 0x8A-0x8F, 0xB8-0xBF, 0x1E-0x1F, 0x2D-0x2F
      case (#setTradePolicy(p)) { w.byte(0x67); TrCan.writePolicy(w, p) };
      // Islamic banking Islamic banking: the extension tag 0xEF with a second byte (the single-byte space is spent)
      case (#setIslamicPolicy(p)) { w.byte(0xEF); w.byte(0x01); ICan.writePolicy(w, p) };
      case (#approveShariaProduct(x)) { w.byte(0xEF); w.byte(0x02); w.text(x.product); ICan.writeApproval(w, x.approval) };
      case (#flagShariaBook(x)) { w.byte(0xEF); w.byte(0x03); w.text(x.book); w.bool(x.sharia) };
      case (#openShariaContract(x)) { w.byte(0xEF); w.byte(0x04); ICan.writeKind(w, x.kind); w.text(x.currency); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#acquireMurabahaAsset(x)) { w.byte(0xEF); w.byte(0x05); w.nat(x.contract); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#sellMurabaha(x)) { w.byte(0xEF); w.byte(0x06); w.nat(x.contract); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#collectInstalment(x)) { w.byte(0xEF); w.byte(0x07); w.nat(x.contract); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#grantRebate(x)) { w.byte(0xEF); w.byte(0x08); w.nat(x.contract); w.nat(x.amount); w.text(x.reason); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#commenceIjarah(x)) { w.byte(0xEF); w.byte(0x09); w.nat(x.contract); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#collectRental(x)) { w.byte(0xEF); w.byte(0x0A); w.nat(x.contract); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#transferIjarahOwnership(x)) { w.byte(0xEF); w.byte(0x0B); w.nat(x.contract); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#contributeCapital(x)) { w.byte(0xEF); w.byte(0x0C); w.nat(x.contract); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#distributeMusharakahProfit(x)) { w.byte(0xEF); w.byte(0x0D); w.nat(x.contract); w.nat(x.profit); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#allocateMusharakahLoss(x)) { w.byte(0xEF); w.byte(0x0E); w.nat(x.contract); w.nat(x.loss); switch (x.offered) { case null w.byte(0); case (?o) { w.byte(1); w.len16(o.size()); for ((p, a) in o.vals()) { w.nat(p); w.nat(a) } } }; w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#buyMusharakahUnit(x)) { w.byte(0xEF); w.byte(0x0F); w.nat(x.contract); w.nat(x.units); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#recordMudarabahResult(x)) { w.byte(0xEF); w.byte(0x10); w.nat(x.contract); w.nat(x.profit); w.nat(x.loss); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#deliverSalam(x)) { w.byte(0xEF); w.byte(0x11); w.nat(x.contract); w.nat(x.quantity); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#sellSalamCommodity(x)) { w.byte(0xEF); w.byte(0x12); w.nat(x.contract); w.nat(x.proceeds); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#recordSalamFailure(x)) { w.byte(0xEF); w.byte(0x13); w.nat(x.contract); w.text(x.recourse); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#recordIstisnaMilestone(x)) { w.byte(0xEF); w.byte(0x14); w.nat(x.contract); w.blob(x.certificate); w.nat(x.percentBps); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#collectIstisnaBilling(x)) { w.byte(0xEF); w.byte(0x15); w.nat(x.contract); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#settleShariaContract(x)) { w.byte(0xEF); w.byte(0x16); w.nat(x.contract); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#closeShariaContract(x)) { w.byte(0xEF); w.byte(0x17); w.nat(x.contract); w.text(x.reason) };
      case (#recordNonCompliance(x)) { w.byte(0xEF); w.byte(0x18); w.optNat(x.contract); w.nat(x.amount); w.text(x.account); w.text(x.reason); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#openInvestmentPool(x)) { w.byte(0xEF); w.byte(0x19); ICan.writePool(w, x.pool) };
      case (#updatePoolReserves(x)) { w.byte(0xEF); w.byte(0x1A); w.text(x.pool); w.optNat(x.per); w.optNat(x.irr) };
      case (#distributePool(x)) { w.byte(0xEF); w.byte(0x1B); w.text(x.pool); w.text(x.month); w.nat(x.from); w.nat(x.to); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      // treasury treasury: the extension tag 0xEF with a second byte 0x20..0x2C
      case (#setTreasuryPolicy(p)) { w.byte(0xEF); w.byte(0x20); TyCan.writePolicy(w, p) };
      case (#registerSecurity(x)) { w.byte(0xEF); w.byte(0x21); TyCan.writeSecurityTerms(w, x.terms) };
      case (#publishCurve(x)) { w.byte(0xEF); w.byte(0x22); TyCan.writeCurve(w, x.curve) };
      case (#setTreasuryLimit(x)) { w.byte(0xEF); w.byte(0x23); TyCan.writeLimit(w, x.limit) };
      case (#registerNostro(x)) { w.byte(0xEF); w.byte(0x24); TyCan.writeNostro(w, x.nostro) };
      case (#captureDeal(x)) { w.byte(0xEF); w.byte(0x25); w.text(x.book); TyCan.writeCounterparty(w, x.counterparty); TyCan.writeKind(w, x.kind); w.text(x.reference); TyCan.writeOptPrincipal(w, x.approver) };
      case (#confirmDeal(x)) { w.byte(0xEF); w.byte(0x26); w.nat(x.deal); w.blob(x.confirmation); TyCan.writeOptFields(w, x.fields); w.optBlob(x.document) };
      case (#amendDeal(x)) { w.byte(0xEF); w.byte(0x27); w.nat(x.deal); TyCan.writeKind(w, x.kind); w.text(x.reason) };
      case (#cancelDeal(x)) { w.byte(0xEF); w.byte(0x28); w.nat(x.deal); w.text(x.reason) };
      case (#settleDealLeg(x)) { w.byte(0xEF); w.byte(0x29); w.nat(x.deal); w.nat(x.leg); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#markDeal(x)) { w.byte(0xEF); w.byte(0x2A); w.nat(x.deal); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#recordNostroStatement(x)) { w.byte(0xEF); w.byte(0x2B); w.text(x.nostro); w.blob(x.statement); w.nat(x.from); w.nat(x.to); TyCan.writeEntries(w, x.entries); w.optBlob(x.document) };
      case (#resolveNostroBreak(x)) { w.byte(0xEF); w.byte(0x2C); w.nat(x.breakId); w.text(x.resolution); TyCan.writeOptCorrection(w, x.correction); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      // cards cards: the extension tag 0xEF with a second byte 0x30..0x40
      case (#setCardPolicy(p)) { w.byte(0xEF); w.byte(0x30); CdCan.writePolicy(w, p) };
      case (#declareCardScheme(x)) { w.byte(0xEF); w.byte(0x31); CdCan.writeScheme(w, x.scheme) };
      case (#defineCardProduct(x)) { w.byte(0xEF); w.byte(0x32); CdCan.writeProduct(w, x.product) };
      case (#issueCard(x)) { w.byte(0xEF); w.byte(0x33); w.blob(x.token); w.nat(x.account); w.text(x.product); CdCan.writeForm(w, x.form); CdCan.writeControls(w, x.controls); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#activateCard(x)) { w.byte(0xEF); w.byte(0x34); w.nat(x.card) };
      case (#blockCard(x)) { w.byte(0xEF); w.byte(0x35); w.nat(x.card); CdCan.writeBlockReason(w, x.reason) };
      case (#unblockCard(x)) { w.byte(0xEF); w.byte(0x36); w.nat(x.card) };
      case (#replaceCard(x)) { w.byte(0xEF); w.byte(0x37); w.nat(x.card); w.blob(x.newToken); CdCan.writeReplaceReason(w, x.reason); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#closeCard(x)) { w.byte(0xEF); w.byte(0x38); w.nat(x.card); w.text(x.reason) };
      case (#setCardControls(x)) { w.byte(0xEF); w.byte(0x39); w.nat(x.card); CdCan.writeControls(w, x.controls); w.bool(x.byCustomer) };
      case (#openDispute(x)) { w.byte(0xEF); w.byte(0x3A); w.nat(x.transaction); w.text(x.reason); w.nat(x.amount) };
      case (#grantProvisionalCredit(x)) { w.byte(0xEF); w.byte(0x3B); w.nat(x.dispute); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#raiseChargeback(x)) { w.byte(0xEF); w.byte(0x3C); w.nat(x.dispute); w.text(x.schemeRef); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#recordRepresentment(x)) { w.byte(0xEF); w.byte(0x3D); w.nat(x.dispute); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#recordPreArbitration(x)) { w.byte(0xEF); w.byte(0x3E); w.nat(x.dispute) };
      case (#resolveDispute(x)) { w.byte(0xEF); w.byte(0x3F); w.nat(x.dispute); CdCan.writeOutcome(w, x.outcome); w.nat(x.finalAmount); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#markFraud(x)) { w.byte(0xEF); w.byte(0x40); w.nat(x.transaction); w.bool(x.blockCard) };
      // S4.1: the close layer's currency calendars and redenomination, 0xEF + 0x50..0x5F
      case (#setCurrencyCalendar(x)) { w.byte(0xEF); w.byte(0x50); w.text(x.currency); w.calendar(x.calendar) };
      case (#redenominateCurrency(x)) { w.byte(0xEF); w.byte(0x51); CC.wRedenomination(w, x) };
      case (#issueLetterOfCredit(x)) { w.byte(0x68); TrCan.writeLc(w, x.lc); w.nat(x.amount); w.text(x.currency); w.nat(x.expiry); w.text(x.placeOfExpiry); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#adviseLetterOfCredit(x)) { w.byte(0x69); w.text(x.message); w.nat(x.beneficiary); w.nat(x.beneficiaryAccount); w.bool(x.confirm); w.len16(x.checklist.size()); for ((k, cs) in x.checklist.vals()) { TrCan.writeDocumentKind(w, k); w.len16(cs.size()); for (c in cs.vals()) w.text(c) }; w.nat(x.commissionBps); w.optNat(x.facility); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#amendLetterOfCredit(x)) { w.byte(0x6A); w.nat(x.instrument); TrCan.writeAmendment(w, x.amendment); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#presentDocuments(x)) { w.byte(0x6B); w.nat(x.instrument); TrCan.writeDocumentRefs(w, x.documents); w.nat(x.amount); w.optNat(x.shipmentDate); w.nat(x.presentedOn) };
      case (#examinePresentation(x)) { w.byte(0x6C); w.nat(x.instrument); w.nat(x.claim); TrCan.writeChecks(w, x.checks); TrCan.writeDecision(w, x.decision) };
      case (#waiveDiscrepancies(x)) { w.byte(0x6D); w.nat(x.instrument); w.nat(x.claim); w.blob(x.applicantConsentHash) };
      case (#honourPresentation(x)) { w.byte(0x6E); w.nat(x.instrument); w.nat(x.claim); TrCan.writeHonour(w, x.honour); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#settleAcceptance(x)) { w.byte(0x6F); w.nat(x.instrument); w.nat(x.claim); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#closeLetterOfCredit(x)) { w.byte(0x8A); w.nat(x.instrument); w.text(x.reason); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#issueGuarantee(x)) { w.byte(0x8B); TrCan.writeGuarantee(w, x.guarantee); w.nat(x.amount); w.text(x.currency); w.nat(x.expiry); w.text(x.wordingText); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#amendGuarantee(x)) { w.byte(0x8C); w.nat(x.instrument); TrCan.writeAmendment(w, x.amendment); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#recordDemand(x)) { w.byte(0x8D); w.nat(x.instrument); TrCan.writeDocumentRef(w, x.demand); w.nat(x.amount); w.bool(x.supportingStatement); w.nat(x.presentedOn) };
      case (#examineDemand(x)) { w.byte(0x8E); w.nat(x.instrument); w.nat(x.claim); w.len16(x.checklist.size()); for (c in x.checklist.vals()) w.text(c); TrCan.writeChecks(w, x.checks); TrCan.writeDecision(w, x.decision) };
      case (#payDemand(x)) { w.byte(0x8F); w.nat(x.instrument); w.nat(x.claim); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#reduceGuarantee(x)) { w.byte(0xB8); w.nat(x.instrument); w.nat(x.to); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#releaseGuarantee(x)) { w.byte(0xB9); w.nat(x.instrument); w.text(x.reason); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#registerCollection(x)) { w.byte(0xBA); TrCan.writeCollection(w, x.collection); w.nat(x.amount); w.text(x.currency); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#presentCollection(x)) { w.byte(0xBB); w.nat(x.instrument); w.nat(x.presentedOn) };
      case (#acceptCollection(x)) { w.byte(0xBC); w.nat(x.instrument) };
      case (#payCollection(x)) { w.byte(0xBD); w.nat(x.instrument); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#protestCollection(x)) { w.byte(0xBE); w.nat(x.instrument); w.text(x.reason) };
      case (#returnCollection(x)) { w.byte(0xBF); w.nat(x.instrument); w.text(x.reason); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#discountBill(x)) { w.byte(0x1E); TrCan.writeBill(w, x.bill); w.nat(x.face); w.text(x.currency); w.nat(x.maturity); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#rediscountBill(x)) { w.byte(0x1F); w.nat(x.instrument); w.text(x.to); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#settleBill(x)) { w.byte(0x2D); w.nat(x.instrument); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#dishonourBill(x)) { w.byte(0x2E); w.nat(x.instrument); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#recordTradeMessage(x)) { w.byte(0x2F); w.nat(x.instrument); TrCan.writeMessageKind(w, x.kind); TrCan.writeDirection(w, x.direction); w.blob(x.hash) };
      case (#openTellerSession(x)) { w.byte(0xF7); w.text(x.till); w.principal(x.teller); TCan.writeDenominations(w, x.opening) };
      case (#closeTellerSession(x)) { w.byte(0xF8); w.text(x.till); TCan.writeDenominations(w, x.closing) };
      case (#resolveTillDifference(x)) { w.byte(0xF9); w.nat(x.session); w.text(x.note); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#cashDeposit(x)) { w.byte(0xFA); w.text(x.till); w.nat(x.account); w.nat(x.amount); TCan.writeDenominations(w, x.tendered); TCan.writeDenominations(w, x.change); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#cashWithdrawal(x)) { w.byte(0xFB); w.text(x.till); w.nat(x.account); w.nat(x.amount); TCan.writeDenominations(w, x.paid); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#vaultToTill(x)) { w.byte(0xFC); w.text(x.till); w.nat(x.amount); TCan.writeDenominations(w, x.denominations); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#tillToVault(x)) { w.byte(0xFD); w.text(x.till); w.nat(x.amount); TCan.writeDenominations(w, x.denominations); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#dispatchCash(x)) { w.byte(0xFE); w.text(x.product); w.text(x.fromBook); w.text(x.toBook); w.text(x.currency); w.nat(x.amount); TCan.writeDenominations(w, x.denominations); w.text(x.carrier); w.text(x.sealBag); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#receiveCash(x)) { w.byte(0xFF); w.nat(x.movement); TCan.writeDenominations(w, x.denominations); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#vaultToCentralBank(x)) { w.byte(0x13); w.text(x.product); w.text(x.book); w.text(x.currency); w.nat(x.amount); TCan.writeDenominations(w, x.denominations); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#centralBankToVault(x)) { w.byte(0x14); w.text(x.product); w.text(x.book); w.text(x.currency); w.nat(x.amount); TCan.writeDenominations(w, x.denominations); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#issueChequebook(x)) { w.byte(0x15); w.nat(x.account); w.nat(x.from); w.nat(x.to) };
      case (#stopCheque(x)) { w.byte(0x16); w.nat(x.account); w.nat(x.serial); w.text(x.reason) };
      case (#presentCheque(x)) { w.byte(0x17); w.nat(x.account); w.nat(x.serial); w.nat(x.amount); TCan.writePayee(w, x.payee); w.nat(x.chequeDate); w.blob(x.imageHash); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#clearCheque(x)) { w.byte(0x18); w.nat(x.account); w.nat(x.serial); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#returnCheque(x)) { w.byte(0x1A); w.nat(x.account); w.nat(x.serial); TCan.writeReason(w, x.reason); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#issueDraft(x)) { w.byte(0x1B); w.text(x.serial); w.blob(x.payeeCommit); w.nat(x.amount); w.text(x.currency); TCan.writeSource(w, x.source); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#payDraft(x)) { w.byte(0x1C); w.text(x.serial); TCan.writeSource(w, x.to); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#cancelDraft(x)) { w.byte(0x1D); w.text(x.serial); w.nat(x.refundTo); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#openPacking(x)) { w.byte(0xD4); w.text(x.period) };
      case (#rollPackToArchive(x)) { w.byte(0xD5); w.nat(x.pack); w.nat64(x.cid); w.principal(x.archive) };
      case (#declareShardRule(x)) { w.byte(0xD6); w.nat(x.self); writeShards(w, x.shards) };
      case (#openShardTransfer(x)) { w.byte(0xD7); w.nat(x.from); w.text(x.toIdentifier); w.nat(x.amount); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      // ── settlement: 0xD8–0xE6 ──
      case (#declareScheme(x)) { w.byte(0xD8); w.text(x.id); w.byte(switch (x.granularity) { case (#gross) 0; case (#net) 1 }); w.byte(switch (x.interchange) { case (#bilateral) 0; case (#multilateral) 1 }); w.byte(switch (x.delay) { case (#immediate) 0; case (#deferred) 1 }); w.text(x.reconciliation); w.text(x.feeIncome); w.nat(x.interchangeBps); w.nat(x.hubFeeBps); w.nat(x.alarmPercent) };
      case (#registerParticipant(x)) { w.byte(0xD9); w.nat(x.party); w.text(x.bic); w.text(x.scheme); writeParticipantAccounts(w, x.accounts) };
      case (#deactivateParticipant(x)) { w.byte(0xDA); w.nat(x.participant) };
      case (#recordFunds(x)) { w.byte(0xDB); w.nat(x.participant); w.text(x.currency); w.nat(x.amount); w.byte(switch (x.direction) { case (#in_) 0; case (#out) 1 }); w.nat(x.postingDate); w.nat(x.valueDate); w.text(x.period); w.text(x.narration) };
      case (#prepareTransfer(x)) { w.byte(0xDC); w.text(x.scheme); w.nat(x.payer); w.nat(x.payee); w.text(x.currency); w.nat(x.amount); w.text(x.reference); w.nat(x.ttlSeconds) };
      case (#fulfilTransfer(x)) { w.byte(0xDD); w.nat(x.transfer) };
      case (#rejectTransfer(x)) { w.byte(0xDE); w.nat(x.transfer); w.text(x.reason) };
      case (#errorTransfer(x)) { w.byte(0xDF); w.nat(x.transfer); w.text(x.reason) };
      case (#openSettlementWindow(x)) { w.byte(0xE0); w.text(x.scheme); w.nat(x.businessDate) };
      case (#closeSettlementWindow(x)) { w.byte(0xE1); w.nat(x.window) };
      case (#openSettlement(x)) { w.byte(0xE2); w.nat(x.window) };
      case (#abortSettlement(x)) { w.byte(0xE3); w.nat(x.settlement); w.text(x.reason) };
      case (#receiveBulk(x)) { w.byte(0xE4); w.text(x.scheme); w.nat(x.payer); w.text(x.reference); w.nat(x.ttlSeconds); w.len16(x.requests.size()); for (r in x.requests.vals()) { w.nat(r.payee); w.text(r.currency); w.nat(r.amount); w.text(r.reference) } };
      case (#fulfilBulk(x)) { w.byte(0xE5); w.nat(x.bulk) };
      case (#rejectBulk(x)) { w.byte(0xE6); w.nat(x.bulk); w.text(x.reason) };
      // ── ISO 20022 messaging: 0xE7–0xEA ──
      case (#declareRail(x)) { w.byte(0xE7); w.text(x.id); w.text(x.scheme); w.nat(x.ttlSeconds); writeHoldRules(w, x.hold); w.byte(sigScheme(x.signatures)) };
      case (#registerConnectorKey(x)) { w.byte(0xE8); w.text(x.rail); w.text(x.bic); w.byte(sigScheme(x.scheme)); w.blob(x.publicKey) };
      case (#releaseHold(x)) { w.byte(0xE9); w.nat(x.transfer); w.text(x.reason) };
      case (#rejectHold(x)) { w.byte(0xEA); w.nat(x.transfer); w.text(x.reason) };
      case (#grantDebitAuthority(x)) { w.byte(0xEC); w.text(x.rail); w.nat(x.debtor); w.text(x.creditorBic); w.text(x.currency); w.nat(x.maxAmount) };
      case (#revokeDebitAuthority(x)) { w.byte(0xED); w.text(x.rail); w.nat(x.debtor); w.text(x.creditorBic); w.text(x.currency) };
      case (#decideMandate(x)) { w.byte(0xEE); w.text(x.rail); w.text(x.mandateId); w.bool(x.accepted); writeOptText(w, x.reason) };
      case (#declareFspiopParticipant(x)) { w.byte(0xEB); w.text(x.rail); w.nat(x.participant); w.text(x.fspId); writePairs(w, x.endpoints) };
    };
  };

  public func writeFinding(w : C.Writer, f : MT.Finding) {
    w.text(f.rule); w.nat(f.version); w.nat(f.account); w.nat(f.day); wNats(w, f.postings); w.text(f.detail);
  };

  public func readFinding(r : C.Reader) : ?MT.Finding {
    let ?rule = r.text() else return null; let ?version = r.nat() else return null; let ?account = r.nat() else return null;
    let ?day = r.nat() else return null; let ?postings = rNats(r) else return null; let ?detail = r.text() else return null;
    ?{ rule; version; account; day; postings; detail }
  };

  func writeAlertEvent(w : C.Writer, e : AlT.AlertEvent) {
    switch (e) {
      case (#alertOpened(x)) { w.byte(0x01); writeFinding(w, x.finding); w.byte(switch (x.source) { case (#posting) 0; case (#endOfDay) 1 }) };
      case (#alertCleared(x)) { w.byte(0x02); w.nat(x.alert); w.text(x.reason) };
      case (#alertEscalated(x)) { w.byte(0x03); w.nat(x.alert); w.text(x.reportRef) };
    }
  };

  // ── collections (collections and recovery) ──

  func wStage(w : C.Writer, s : ColT.Stage) { w.byte(ColT.stageCode(s)) };
  func rStage(r : C.Reader) : ?ColT.Stage { let ?b = r.byte() else return null; ColT.stageOfCode(b) };
  func wCollectionsPolicy(w : C.Writer, p : ColT.Policy) { w.nat(p.delinquentDpd); w.nat(p.defaultDpd); wStage(w, p.suspendInterestFrom); w.bool(p.recogniseModificationLoss) };
  func rCollectionsPolicy(r : C.Reader) : ?ColT.Policy {
    let ?delinquentDpd = r.nat() else return null; let ?defaultDpd = r.nat() else return null;
    let ?suspendInterestFrom = rStage(r) else return null; let ?recogniseModificationLoss = r.bool() else return null;
    ?{ delinquentDpd; defaultDpd; suspendInterestFrom; recogniseModificationLoss }
  };
  func wCollectionAction(w : C.Writer, a : ColT.Action) {
    switch (a) {
      case (#call) w.byte(0); case (#letter) w.byte(1); case (#visit) w.byte(2); case (#legalNotice) w.byte(3); case (#fieldAgent) w.byte(4);
      case (#other(t)) { w.byte(5); w.text(t) };
    }
  };
  func rCollectionAction(r : C.Reader) : ?ColT.Action {
    switch (r.byte()) {
      case (?0) ?#call; case (?1) ?#letter; case (?2) ?#visit; case (?3) ?#legalNotice; case (?4) ?#fieldAgent;
      case (?5) { let ?t = r.text() else return null; ?#other(t) };
      case (_) null;
    }
  };
  func wReason(w : C.Writer, x : ColT.Reason) {
    w.byte(switch (x) { case (#daysPastDue) 0; case (#unlikelyToPay) 1; case (#collectionAction) 2; case (#restructured) 3; case (#writtenOff) 4; case (#recovery) 5; case (#cured) 6; case (#closed) 7 })
  };
  func rReason(r : C.Reader) : ?ColT.Reason {
    switch (r.byte()) {
      case (?0) ?#daysPastDue; case (?1) ?#unlikelyToPay; case (?2) ?#collectionAction; case (?3) ?#restructured; case (?4) ?#writtenOff;
      case (?5) ?#recovery; case (?6) ?#cured; case (?7) ?#closed; case (_) null;
    }
  };
  func writeCollectionsEvent(w : C.Writer, e : ColT.CollectionsEvent) {
    switch (e) {
      case (#policySet(p)) { w.byte(0x01); wCollectionsPolicy(w, p) };
      case (#stageDerived(x)) { w.byte(0x02); w.nat(x.account); wStage(w, x.from); wStage(w, x.to); w.nat(x.dpd); w.nat(x.day); wReason(w, x.reason); w.text(x.note) };
      case (#actionRecorded(x)) { w.byte(0x03); w.nat(x.account); wCollectionAction(w, x.action); w.text(x.outcome); w.optNat(x.next); w.nat(x.day) };
      case (#promiseRecorded(x)) { w.byte(0x04); w.nat(x.account); w.nat(x.amount); w.nat(x.by); w.nat(x.day); w.nat(x.baseline) };
      case (#promiseJudged(x)) { w.byte(0x05); w.nat(x.account); w.nat(x.amount); w.nat(x.by); w.bool(x.kept); w.nat(x.day) };
      case (#collectorAssigned(x)) { w.byte(0x06); w.nat(x.account); w.principal(x.staff) };
      case (#interestSuspended(x)) { w.byte(0x07); w.nat(x.account); w.nat(x.amount); w.nat(x.day) };
      case (#suspenseReleased(x)) { w.byte(0x08); w.nat(x.account); w.nat(x.amount); w.nat(x.day) };
    }
  };
  func readCollectionsEvent(r : C.Reader) : ?ColT.CollectionsEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 { let ?p = rCollectionsPolicy(r) else return null; ?#policySet(p) };
      case 0x02 {
        let ?account = r.nat() else return null; let ?from = rStage(r) else return null; let ?to = rStage(r) else return null;
        let ?dpd = r.nat() else return null; let ?day = r.nat() else return null; let ?reason = rReason(r) else return null; let ?note = r.text() else return null;
        ?#stageDerived({ account; from; to; dpd; day; reason; note })
      };
      case 0x03 {
        let ?account = r.nat() else return null; let ?action = rCollectionAction(r) else return null; let ?outcome = r.text() else return null;
        let ?next = r.optNat() else return null; let ?day = r.nat() else return null;
        ?#actionRecorded({ account; action; outcome; next; day })
      };
      case 0x04 {
        let ?account = r.nat() else return null; let ?amount = r.nat() else return null; let ?by = r.nat() else return null;
        let ?day = r.nat() else return null; let ?baseline = r.nat() else return null;
        ?#promiseRecorded({ account; amount; by; day; baseline })
      };
      case 0x05 {
        let ?account = r.nat() else return null; let ?amount = r.nat() else return null; let ?by = r.nat() else return null;
        let ?kept = r.bool() else return null; let ?day = r.nat() else return null;
        ?#promiseJudged({ account; amount; by; kept; day })
      };
      case 0x06 { let ?account = r.nat() else return null; let ?staff = r.principal() else return null; ?#collectorAssigned({ account; staff }) };
      case 0x07 { let ?account = r.nat() else return null; let ?amount = r.nat() else return null; let ?day = r.nat() else return null; ?#interestSuspended({ account; amount; day }) };
      case 0x08 { let ?account = r.nat() else return null; let ?amount = r.nat() else return null; let ?day = r.nat() else return null; ?#suspenseReleased({ account; amount; day }) };
      case _ null;
    }
  };

  func readAlertEvent(r : C.Reader) : ?AlT.AlertEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 {
        let ?finding = readFinding(r) else return null;
        let ?src = r.byte() else return null;
        let source : AlT.Source = switch (src) { case 0 #posting; case 1 #endOfDay; case _ return null };
        ?#alertOpened({ finding; source })
      };
      case 0x02 { let ?alert = r.nat() else return null; let ?reason = r.text() else return null; ?#alertCleared({ alert; reason }) };
      case 0x03 { let ?alert = r.nat() else return null; let ?reportRef = r.text() else return null; ?#alertEscalated({ alert; reportRef }) };
      case _ null;
    }
  };

  func writePackingEvent(w : C.Writer, e : PkT.PackingEvent) {
    switch (e) {
      case (#packOpened(x)) { w.byte(0x01); w.nat(x.pack); w.text(x.period); w.nat(x.periodEnd); w.nat(x.lo); w.nat(x.hi); w.nat(x.bankLo); w.nat(x.bankHi) };
      case (#bankSegmentPacked(x)) { w.byte(0x0B); w.nat(x.pack); w.nat(x.seq); w.nat(x.lo); w.nat(x.hi); w.nat(x.bytes); w.nat(x.rawBytes); w.nat(x.dropped); w.nat(x.kept); w.blob(x.sha256) };
      case (#segmentPacked(x)) { w.byte(0x02); w.nat(x.pack); w.nat(x.seq); w.nat(x.lo); w.nat(x.hi); w.nat(x.bytes); w.nat(x.rawBytes); w.nat(x.postings); w.blob(x.sha256) };
      case (#packAdvanced(x)) { w.byte(0x03); w.nat(x.pack); w.text(x.phase); w.nat(x.work) };
      case (#packSealed(x)) {
        w.byte(0x04); w.nat(x.pack); w.nat(x.segments); w.nat(x.postings); w.nat(x.accounts); w.nat(x.packedBytes); w.nat(x.rawBytes); w.blob(x.sha256); w.nat(x.hi); w.nat(x.periodEnd);
        w.nat(x.bankHi); w.nat(x.bankSegments); w.nat(x.bankPackedBytes); w.nat(x.bankRawBytes); w.nat(x.bankDropped); w.nat(x.bankKept);
      };
      case (#rollAuthorised(x)) { w.byte(0x05); w.nat(x.pack); w.nat64(x.cid); w.principal(x.archive); w.nat(x.hi); w.nat(x.periodEnd) };
      case (#rollAdvanced(x)) { w.byte(0x06); w.nat(x.pack); w.text(x.phase); w.nat(x.work) };
      case (#checkpointWritten(x)) { w.byte(0x07); w.nat(x.pack); w.nat(x.through); w.nat(x.first); w.nat(x.last) };
      case (#segmentSent(x)) { w.byte(0x08); w.nat(x.pack); w.nat(x.seq); w.nat(x.attempt) };
      case (#segmentArchived(x)) { w.byte(0x09); w.nat(x.pack); w.nat(x.seq); w.blob(x.sha256) };
      case (#packArchived(x)) { w.byte(0x0A); w.nat(x.pack); w.nat64(x.cid); w.principal(x.archive); w.nat(x.hi); w.nat(x.journalBase); w.nat(x.segments) };
    }
  };

  func readPackingEvent(r : C.Reader) : ?PkT.PackingEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 {
        let ?pack = r.nat() else return null; let ?period = r.text() else return null; let ?periodEnd = r.nat() else return null;
        let ?lo = r.nat() else return null; let ?hi = r.nat() else return null;
        let ?bankLo = r.nat() else return null; let ?bankHi = r.nat() else return null;
        ?#packOpened({ pack; period; periodEnd; lo; hi; bankLo; bankHi })
      };
      case 0x0B {
        let ?pack = r.nat() else return null; let ?seq = r.nat() else return null; let ?lo = r.nat() else return null; let ?hi = r.nat() else return null;
        let ?bytes = r.nat() else return null; let ?rawBytes = r.nat() else return null; let ?dropped = r.nat() else return null; let ?kept = r.nat() else return null; let ?sha256 = r.blob() else return null;
        ?#bankSegmentPacked({ pack; seq; lo; hi; bytes; rawBytes; dropped; kept; sha256 })
      };
      case 0x02 {
        let ?pack = r.nat() else return null; let ?seq = r.nat() else return null; let ?lo = r.nat() else return null; let ?hi = r.nat() else return null;
        let ?bytes = r.nat() else return null; let ?rawBytes = r.nat() else return null; let ?postings = r.nat() else return null; let ?sha256 = r.blob() else return null;
        ?#segmentPacked({ pack; seq; lo; hi; bytes; rawBytes; postings; sha256 })
      };
      case 0x03 { let ?pack = r.nat() else return null; let ?phase = r.text() else return null; let ?work = r.nat() else return null; ?#packAdvanced({ pack; phase; work }) };
      case 0x04 {
        let ?pack = r.nat() else return null; let ?segments = r.nat() else return null; let ?postings = r.nat() else return null; let ?accounts = r.nat() else return null;
        let ?packedBytes = r.nat() else return null; let ?rawBytes = r.nat() else return null; let ?sha256 = r.blob() else return null; let ?hi = r.nat() else return null; let ?periodEnd = r.nat() else return null;
        let ?bankHi = r.nat() else return null; let ?bankSegments = r.nat() else return null; let ?bankPackedBytes = r.nat() else return null;
        let ?bankRawBytes = r.nat() else return null; let ?bankDropped = r.nat() else return null; let ?bankKept = r.nat() else return null;
        ?#packSealed({ pack; segments; postings; accounts; packedBytes; rawBytes; sha256; hi; periodEnd; bankHi; bankSegments; bankPackedBytes; bankRawBytes; bankDropped; bankKept })
      };
      case 0x05 { let ?pack = r.nat() else return null; let ?cid = r.nat64() else return null; let ?archive = r.principal() else return null; let ?hi = r.nat() else return null; let ?periodEnd = r.nat() else return null; ?#rollAuthorised({ pack; cid; archive; hi; periodEnd }) };
      case 0x06 { let ?pack = r.nat() else return null; let ?phase = r.text() else return null; let ?work = r.nat() else return null; ?#rollAdvanced({ pack; phase; work }) };
      case 0x07 { let ?pack = r.nat() else return null; let ?through = r.nat() else return null; let ?first = r.nat() else return null; let ?last = r.nat() else return null; ?#checkpointWritten({ pack; through; first; last }) };
      case 0x08 { let ?pack = r.nat() else return null; let ?seq = r.nat() else return null; let ?attempt = r.nat() else return null; ?#segmentSent({ pack; seq; attempt }) };
      case 0x09 { let ?pack = r.nat() else return null; let ?seq = r.nat() else return null; let ?sha256 = r.blob() else return null; ?#segmentArchived({ pack; seq; sha256 }) };
      case 0x0A { let ?pack = r.nat() else return null; let ?cid = r.nat64() else return null; let ?archive = r.principal() else return null; let ?hi = r.nat() else return null; let ?journalBase = r.nat() else return null; let ?segments = r.nat() else return null; ?#packArchived({ pack; cid; archive; hi; journalBase; segments }) };
      case _ null;
    }
  };

  func writeShards(w : C.Writer, shards : [ST.ShardEntry]) {
    w.len16(shards.size());
    for (e in shards.vals()) { w.nat(e.index); w.principal(e.principal); w.text(e.settlement) };
  };
  func readShards(r : C.Reader) : ?[ST.ShardEntry] {
    let ?n = r.len16() else return null;
    let out = List.empty<ST.ShardEntry>();
    var i = 0;
    while (i < n) { let ?index = r.nat() else return null; let ?principal = r.principal() else return null; let ?settlement = r.text() else return null; List.add(out, { index; principal; settlement }); i += 1 };
    ?List.toArray(out)
  };

  func writeShardEvent(w : C.Writer, e : ST.ShardEvent) {
    switch (e) {
      case (#ruleDeclared(x)) { w.byte(0x01); w.nat(x.version); w.nat(x.self); writeShards(w, x.shards) };
      case (#outboundOpened(x)) { w.byte(0x02); w.nat(x.from); w.text(x.toIdentifier); w.nat(x.toShard); w.nat(x.amount); w.text(x.currency); w.nat(x.valueDay); w.text(x.period); w.text(x.narration); w.nat(x.pendingIndex) };
      case (#outboundSent(x)) { w.byte(0x03); w.nat(x.transfer); w.nat(x.attempt) };
      case (#outboundSettled(x)) { w.byte(0x04); w.nat(x.transfer); w.nat(x.receiverPosting) };
      case (#outboundReturned(x)) { w.byte(0x05); w.nat(x.transfer); w.text(x.reason) };
      case (#inboundPosted(x)) { w.byte(0x06); w.nat(x.fromShard); w.nat(x.transfer); w.nat(x.toAccount); w.nat(x.amount); w.nat(x.posting) };
      case (#inboundRefused(x)) { w.byte(0x07); w.nat(x.fromShard); w.nat(x.transfer); w.text(x.toIdentifier); w.text(x.reason) };
    }
  };

  func readShardEvent(r : C.Reader) : ?ST.ShardEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 { let ?version = r.nat() else return null; let ?self = r.nat() else return null; let ?shards = readShards(r) else return null; ?#ruleDeclared({ version; self; shards }) };
      case 0x02 {
        let ?from = r.nat() else return null; let ?toIdentifier = r.text() else return null; let ?toShard = r.nat() else return null; let ?amount = r.nat() else return null;
        let ?currency = r.text() else return null; let ?valueDay = r.nat() else return null; let ?period = r.text() else return null; let ?narration = r.text() else return null; let ?pendingIndex = r.nat() else return null;
        ?#outboundOpened({ from; toIdentifier; toShard; amount; currency; valueDay; period; narration; pendingIndex })
      };
      case 0x03 { let ?transfer = r.nat() else return null; let ?attempt = r.nat() else return null; ?#outboundSent({ transfer; attempt }) };
      case 0x04 { let ?transfer = r.nat() else return null; let ?receiverPosting = r.nat() else return null; ?#outboundSettled({ transfer; receiverPosting }) };
      case 0x05 { let ?transfer = r.nat() else return null; let ?reason = r.text() else return null; ?#outboundReturned({ transfer; reason }) };
      case 0x06 { let ?fromShard = r.nat() else return null; let ?transfer = r.nat() else return null; let ?toAccount = r.nat() else return null; let ?amount = r.nat() else return null; let ?posting = r.nat() else return null; ?#inboundPosted({ fromShard; transfer; toAccount; amount; posting }) };
      case 0x07 { let ?fromShard = r.nat() else return null; let ?transfer = r.nat() else return null; let ?toIdentifier = r.text() else return null; let ?reason = r.text() else return null; ?#inboundRefused({ fromShard; transfer; toIdentifier; reason }) };
      case _ null;
    }
  };

  func writeParticipantAccounts(w : C.Writer, accounts : [SeT.ParticipantAccounts]) {
    w.len16(accounts.size());
    for (a in accounts.vals()) { w.text(a.currency); w.nat(a.position); w.nat(a.settlement); w.nat(a.feeReceivable) };
  };
  func readParticipantAccounts(r : C.Reader) : ?[SeT.ParticipantAccounts] {
    let ?n = r.len16() else return null;
    let out = List.empty<SeT.ParticipantAccounts>();
    var i = 0;
    while (i < n) { let ?currency = r.text() else return null; let ?position = r.nat() else return null; let ?settlement = r.nat() else return null; let ?feeReceivable = r.nat() else return null; List.add(out, { currency; position; settlement; feeReceivable }); i += 1 };
    ?List.toArray(out)
  };
  func writeNets(w : C.Writer, nets : [SeT.NetPosition]) { w.nat(nets.size()); for (n in nets.vals()) { w.nat(n.participant); w.text(n.currency); w.nat(n.debits); w.nat(n.credits) } };
  func readNets(r : C.Reader) : ?[SeT.NetPosition] {
    let ?n = r.nat() else return null;
    if (n > 1_000_000) return null;
    let out = List.empty<SeT.NetPosition>();
    var i = 0;
    while (i < n) { let ?participant = r.nat() else return null; let ?currency = r.text() else return null; let ?debits = r.nat() else return null; let ?credits = r.nat() else return null; List.add(out, { participant; currency; debits; credits }); i += 1 };
    ?List.toArray(out)
  };
  func writeNats(w : C.Writer, xs : [Nat]) { w.nat(xs.size()); for (x in xs.vals()) w.nat(x) };
  func readNatList(r : C.Reader) : ?[Nat] {
    let ?n = r.nat() else return null;
    if (n > 1_000_000) return null;
    let out = List.empty<Nat>();
    var i = 0;
    while (i < n) { let ?x = r.nat() else return null; List.add(out, x); i += 1 };
    ?List.toArray(out)
  };
  func writeFailures(w : C.Writer, xs : [(Nat, Text)]) { w.nat(xs.size()); for ((i, t) in xs.vals()) { w.nat(i); w.text(t) } };
  func readFailures(r : C.Reader) : ?[(Nat, Text)] {
    let ?n = r.nat() else return null;
    if (n > 1_000_000) return null;
    let out = List.empty<(Nat, Text)>();
    var i = 0;
    while (i < n) { let ?k = r.nat() else return null; let ?t = r.text() else return null; List.add(out, (k, t)); i += 1 };
    ?List.toArray(out)
  };

  // ── payments ──
  func sigScheme(x : PayT.SignatureScheme) : Nat8 { switch (x) { case (#none) 0; case (#mayo2) 1; case (#mldsa44) 2 } };
  func readSigScheme(b : Nat8) : ?PayT.SignatureScheme { switch (b) { case 0 ?#none; case 1 ?#mayo2; case 2 ?#mldsa44; case _ null } };
  func writeTexts(w : C.Writer, xs : [Text]) { w.len16(xs.size()); for (x in xs.vals()) w.text(x) };
  func readTexts(r : C.Reader) : ?[Text] {
    let ?n = r.len16() else return null;
    let out = List.empty<Text>();
    var i = 0;
    while (i < n) { let ?t = r.text() else return null; List.add(out, t); i += 1 };
    ?List.toArray(out)
  };
  func writeHoldRules(w : C.Writer, h : PayT.HoldRules) {
    w.len16(h.holdAbove.size()); for ((c, a) in h.holdAbove.vals()) { w.text(c); w.nat(a) };
    writeTexts(w, h.blockedBics); writeTexts(w, h.blockedNameFragments);
  };
  func readHoldRules(r : C.Reader) : ?PayT.HoldRules {
    let ?n = r.len16() else return null;
    let above = List.empty<(Text, Nat)>();
    var i = 0;
    while (i < n) { let ?c = r.text() else return null; let ?a = r.nat() else return null; List.add(above, (c, a)); i += 1 };
    let ?blockedBics = readTexts(r) else return null;
    let ?blockedNameFragments = readTexts(r) else return null;
    ?{ holdAbove = List.toArray(above); blockedBics; blockedNameFragments }
  };
  func familyByte(f : PayT.Family) : Nat8 { PayT.familyOrd(f) };
  func writeIssues(w : C.Writer, xs : [PayT.Issue]) { w.nat(xs.size()); for (x in xs.vals()) { w.text(x.rule); w.text(x.path); w.text(x.detail) } };
  func readIssues(r : C.Reader) : ?[PayT.Issue] {
    let ?n = r.nat() else return null;
    if (n > 100_000) return null;
    let out = List.empty<PayT.Issue>();
    var i = 0;
    while (i < n) { let ?rule = r.text() else return null; let ?path = r.text() else return null; let ?detail = r.text() else return null; List.add(out, { rule; path; detail }); i += 1 };
    ?List.toArray(out)
  };
  func writeOutcomes(w : C.Writer, xs : [PayT.Outcome]) {
    w.nat(xs.size());
    for (o in xs.vals()) {
      switch (o) {
        case (#prepared(x)) { w.byte(1); w.text(x.uetr); w.nat(x.transfer); w.bool(x.reserved) };
        case (#held(x)) { w.byte(2); w.text(x.uetr); w.nat(x.transfer); w.text(x.rule) };
        case (#fulfilled(x)) { w.byte(3); w.text(x.uetr); w.nat(x.transfer) };
        case (#rejected(x)) { w.byte(4); w.text(x.uetr); w.nat(x.transfer); w.text(x.reason) };
        case (#acknowledged(x)) { w.byte(5); w.text(x.uetr); w.nat(x.transfer); w.text(x.status) };
        case (#returned(x)) { w.byte(6); w.text(x.uetr); w.nat(x.original); w.nat(x.transfer); w.bool(x.reserved); w.bool(x.committed) };
        case (#refused(x)) { w.byte(7); w.byte(switch (x.uetr) { case null 0; case (?_) 1 }); switch (x.uetr) { case (?u) w.text(u); case null {} }; w.text(x.rule); w.text(x.detail) };
        // ── the extended target list: tags 8–21 ──
        case (#reversed(x)) { w.byte(8); w.text(x.uetr); w.nat(x.original); w.nat(x.transfer); w.bool(x.reserved); w.bool(x.committed); w.text(x.reason) };
        case (#mandateInitiated(x)) { w.byte(9); w.nat(x.mandate); w.text(x.mandateId); w.text(x.creditorAgent); w.text(x.debtorAgent); w.text(x.debtorAccount); w.text(x.sequence); w.optNat(x.maxAmount); writeOptText(w, x.currency) };
        case (#mandateAmended(x)) { w.byte(10); w.nat(x.mandate); w.text(x.mandateId); w.optNat(x.maxAmount); writeOptText(w, x.currency); w.text(x.debtorAccount); w.text(x.reason) };
        case (#mandateCancelled(x)) { w.byte(11); w.nat(x.mandate); w.text(x.mandateId); w.text(x.reason) };
        case (#mandateAccepted(x)) { w.byte(12); w.nat(x.mandate); w.text(x.mandateId); w.bool(x.accepted); writeOptText(w, x.reason) };
        case (#collected(x)) { w.byte(13); w.text(x.uetr); w.nat(x.transfer); w.bool(x.reserved); w.nat(x.authority); w.bool(x.final) };
        case (#settlementRequested(x)) { w.byte(14); w.nat(x.window); w.nat(x.settlement); w.text(x.cycle); writeMovements(w, x.movements) };
        case (#reportRequested(x)) { w.byte(15); w.text(x.requestId); w.text(x.kind); w.optNat(x.account); w.optNat(x.fromDay); w.optNat(x.toDay) };
        case (#receiptExpected(x)) { w.byte(16); w.text(x.notificationId); w.text(x.itemId); w.text(x.reference); w.nat(x.amount); w.text(x.currency); w.optNat(x.account) };
        case (#receiptMatched(x)) { w.byte(17); w.nat(x.notification); w.text(x.itemId); w.nat(x.transfer) };
        case (#liquidityTransferred(x)) { w.byte(18); w.text(x.endToEndId); w.nat(x.participant); w.text(x.currency); w.nat(x.amount); w.bool(x.toPosition); w.nat(x.posting) };
        case (#caseRecorded(x)) { w.byte(19); w.text(x.caseId); w.text(x.assignmentId); w.text(x.kind); writeOptText(w, x.uetr); w.optNat(x.transfer) };
        case (#resendRequested(x)) { w.byte(20); w.text(x.reference); writeOptText(w, x.messageName); w.optNat(x.message) };
        case (#processingRequested(x)) { w.byte(21); w.text(x.requestType); writeOptText(w, x.session) };
        case (#fileReceived(x)) { w.byte(22); w.text(x.payloadId); w.nat(x.declared); writeNats(w, x.messages) };
      };
    };
  };
  func writeMovements(w : C.Writer, xs : [PayT.Movement]) { w.len16(xs.size()); for (m in xs.vals()) { w.text(m.participantBic); w.text(m.currency); w.nat(m.amount); w.bool(m.debit) } };
  func readMovements(r : C.Reader) : ?[PayT.Movement] {
    let ?n = r.len16() else return null;
    let out = List.empty<PayT.Movement>();
    var i = 0;
    while (i < n) { let ?participantBic = r.text() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?debit = r.bool() else return null; List.add(out, { participantBic; currency; amount; debit }); i += 1 };
    ?List.toArray(out)
  };
  func readOutcomes(r : C.Reader) : ?[PayT.Outcome] {
    let ?n = r.nat() else return null;
    if (n > 100_000) return null;
    let out = List.empty<PayT.Outcome>();
    var i = 0;
    while (i < n) {
      let ?tag = r.byte() else return null;
      switch (tag) {
        case 1 { let ?uetr = r.text() else return null; let ?transfer = r.nat() else return null; let ?reserved = r.bool() else return null; List.add(out, #prepared({ uetr; transfer; reserved })) };
        case 2 { let ?uetr = r.text() else return null; let ?transfer = r.nat() else return null; let ?rule = r.text() else return null; List.add(out, #held({ uetr; transfer; rule })) };
        case 3 { let ?uetr = r.text() else return null; let ?transfer = r.nat() else return null; List.add(out, #fulfilled({ uetr; transfer })) };
        case 4 { let ?uetr = r.text() else return null; let ?transfer = r.nat() else return null; let ?reason = r.text() else return null; List.add(out, #rejected({ uetr; transfer; reason })) };
        case 5 { let ?uetr = r.text() else return null; let ?transfer = r.nat() else return null; let ?status = r.text() else return null; List.add(out, #acknowledged({ uetr; transfer; status })) };
        case 6 { let ?uetr = r.text() else return null; let ?original = r.nat() else return null; let ?transfer = r.nat() else return null; let ?reserved = r.bool() else return null; let ?committed = r.bool() else return null; List.add(out, #returned({ uetr; original; transfer; reserved; committed })) };
        case 7 { let ?has = r.byte() else return null; let uetr : ?Text = if (has == 1) { let ?u = r.text() else return null; ?u } else null; let ?rule = r.text() else return null; let ?detail = r.text() else return null; List.add(out, #refused({ uetr; rule; detail })) };
        case 8 { let ?uetr = r.text() else return null; let ?original = r.nat() else return null; let ?transfer = r.nat() else return null; let ?reserved = r.bool() else return null; let ?committed = r.bool() else return null; let ?reason = r.text() else return null; List.add(out, #reversed({ uetr; original; transfer; reserved; committed; reason })) };
        case 9 { let ?mandate = r.nat() else return null; let ?mandateId = r.text() else return null; let ?creditorAgent = r.text() else return null; let ?debtorAgent = r.text() else return null; let ?debtorAccount = r.text() else return null; let ?sequence = r.text() else return null; let ?maxAmount = r.optNat() else return null; let ?currency = readOptText(r) else return null; List.add(out, #mandateInitiated({ mandate; mandateId; creditorAgent; debtorAgent; debtorAccount; sequence; maxAmount; currency })) };
        case 10 { let ?mandate = r.nat() else return null; let ?mandateId = r.text() else return null; let ?maxAmount = r.optNat() else return null; let ?currency = readOptText(r) else return null; let ?debtorAccount = r.text() else return null; let ?reason = r.text() else return null; List.add(out, #mandateAmended({ mandate; mandateId; maxAmount; currency; debtorAccount; reason })) };
        case 11 { let ?mandate = r.nat() else return null; let ?mandateId = r.text() else return null; let ?reason = r.text() else return null; List.add(out, #mandateCancelled({ mandate; mandateId; reason })) };
        case 12 { let ?mandate = r.nat() else return null; let ?mandateId = r.text() else return null; let ?accepted = r.bool() else return null; let ?reason = readOptText(r) else return null; List.add(out, #mandateAccepted({ mandate; mandateId; accepted; reason })) };
        case 13 { let ?uetr = r.text() else return null; let ?transfer = r.nat() else return null; let ?reserved = r.bool() else return null; let ?authority = r.nat() else return null; let ?final = r.bool() else return null; List.add(out, #collected({ uetr; transfer; reserved; authority; final })) };
        case 14 { let ?window = r.nat() else return null; let ?settlement = r.nat() else return null; let ?cycle = r.text() else return null; let ?movements = readMovements(r) else return null; List.add(out, #settlementRequested({ window; settlement; cycle; movements })) };
        case 15 { let ?requestId = r.text() else return null; let ?kind = r.text() else return null; let ?account = r.optNat() else return null; let ?fromDay = r.optNat() else return null; let ?toDay = r.optNat() else return null; List.add(out, #reportRequested({ requestId; kind; account; fromDay; toDay })) };
        case 16 { let ?notificationId = r.text() else return null; let ?itemId = r.text() else return null; let ?reference = r.text() else return null; let ?amount = r.nat() else return null; let ?currency = r.text() else return null; let ?account = r.optNat() else return null; List.add(out, #receiptExpected({ notificationId; itemId; reference; amount; currency; account })) };
        case 17 { let ?notification = r.nat() else return null; let ?itemId = r.text() else return null; let ?transfer = r.nat() else return null; List.add(out, #receiptMatched({ notification; itemId; transfer })) };
        case 18 { let ?endToEndId = r.text() else return null; let ?participant = r.nat() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?toPosition = r.bool() else return null; let ?posting = r.nat() else return null; List.add(out, #liquidityTransferred({ endToEndId; participant; currency; amount; toPosition; posting })) };
        case 19 { let ?caseId = r.text() else return null; let ?assignmentId = r.text() else return null; let ?kind = r.text() else return null; let ?uetr = readOptText(r) else return null; let ?transfer = r.optNat() else return null; List.add(out, #caseRecorded({ caseId; assignmentId; kind; uetr; transfer })) };
        case 20 { let ?reference = r.text() else return null; let ?messageName = readOptText(r) else return null; let ?message = r.optNat() else return null; List.add(out, #resendRequested({ reference; messageName; message })) };
        case 21 { let ?requestType = r.text() else return null; let ?session = readOptText(r) else return null; List.add(out, #processingRequested({ requestType; session })) };
        case 22 { let ?payloadId = r.text() else return null; let ?declared = r.nat() else return null; let ?messages = readNatList(r) else return null; List.add(out, #fileReceived({ payloadId; declared; messages })) };
        case _ return null;
      };
      i += 1;
    };
    ?List.toArray(out)
  };
  func writePaymentsEvent(w : C.Writer, e : PayT.PaymentsEvent) {
    switch (e) {
      case (#railDeclared(x)) { w.byte(0x01); w.text(x.id); w.text(x.scheme); w.nat(x.ttlSeconds); writeHoldRules(w, x.hold); w.byte(sigScheme(x.signatures)) };
      case (#connectorKeyRegistered(x)) { w.byte(0x02); w.text(x.rail); w.text(x.bic); w.byte(sigScheme(x.scheme)); w.blob(x.publicKey) };
      case (#messageReceived(x)) {
        w.byte(0x03); w.text(x.rail); w.byte(familyByte(x.family)); w.text(x.messageId); w.blob(x.hash); w.nat(x.bytes);
        w.byte(switch (x.signer) { case null 0; case (?_) 1 }); switch (x.signer) { case (?sg) w.text(sg); case null {} };
        w.byte(switch (x.verdict) { case (#accepted) 1; case (#refused) 2; case (#held) 3 });
        writeIssues(w, x.issues); writeOutcomes(w, x.outcomes);
      };
      case (#holdReleased(x)) { w.byte(0x04); w.nat(x.transfer); w.text(x.reason) };
      case (#holdRejected(x)) { w.byte(0x05); w.nat(x.transfer); w.text(x.reason) };
      // ── the extended target list ──
      case (#debitAuthorityGranted(x)) { w.byte(0x06); w.text(x.rail); w.nat(x.debtor); w.text(x.creditorBic); w.text(x.currency); w.nat(x.maxAmount) };
      case (#debitAuthorityRevoked(x)) { w.byte(0x07); w.text(x.rail); w.nat(x.debtor); w.text(x.creditorBic); w.text(x.currency) };
      case (#mandateDecided(x)) { w.byte(0x08); w.text(x.rail); w.text(x.mandateId); w.bool(x.accepted); writeOptText(w, x.reason) };
      case (#settlementRequestJudged(x)) { w.byte(0x09); w.nat(x.settlement); w.bool(x.matched); w.text(x.detail) };
    };
  };
  func readPaymentsEvent(r : C.Reader) : ?PayT.PaymentsEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 { let ?id = r.text() else return null; let ?scheme = r.text() else return null; let ?ttlSeconds = r.nat() else return null; let ?hold = readHoldRules(r) else return null; let ?sb = r.byte() else return null; let ?signatures = readSigScheme(sb) else return null; ?#railDeclared({ id; scheme; ttlSeconds; hold; signatures }) };
      case 0x02 { let ?rail = r.text() else return null; let ?bic = r.text() else return null; let ?sb = r.byte() else return null; let ?scheme = readSigScheme(sb) else return null; let ?publicKey = r.blob() else return null; ?#connectorKeyRegistered({ rail; bic; scheme; publicKey }) };
      case 0x03 {
        let ?rail = r.text() else return null; let ?fb = r.byte() else return null; let ?messageId = r.text() else return null; let ?hash = r.blob() else return null; let ?bytes = r.nat() else return null;
        let ?has = r.byte() else return null; let signer : ?Text = if (has == 1) { let ?sg = r.text() else return null; ?sg } else null;
        let ?vb = r.byte() else return null; let verdict : PayT.Verdict = switch (vb) { case 1 #accepted; case 2 #refused; case 3 #held; case _ return null };
        let ?issues = readIssues(r) else return null; let ?outcomes = readOutcomes(r) else return null;
        ?#messageReceived({ rail; family = PayT.familyFromOrd(fb); messageId; hash; bytes; signer; verdict; issues; outcomes })
      };
      case 0x04 { let ?transfer = r.nat() else return null; let ?reason = r.text() else return null; ?#holdReleased({ transfer; reason }) };
      case 0x05 { let ?transfer = r.nat() else return null; let ?reason = r.text() else return null; ?#holdRejected({ transfer; reason }) };
      case 0x06 { let ?rail = r.text() else return null; let ?debtor = r.nat() else return null; let ?creditorBic = r.text() else return null; let ?currency = r.text() else return null; let ?maxAmount = r.nat() else return null; ?#debitAuthorityGranted({ rail; debtor; creditorBic; currency; maxAmount }) };
      case 0x07 { let ?rail = r.text() else return null; let ?debtor = r.nat() else return null; let ?creditorBic = r.text() else return null; let ?currency = r.text() else return null; ?#debitAuthorityRevoked({ rail; debtor; creditorBic; currency }) };
      case 0x08 { let ?rail = r.text() else return null; let ?mandateId = r.text() else return null; let ?accepted = r.bool() else return null; let ?reason = readOptText(r) else return null; ?#mandateDecided({ rail; mandateId; accepted; reason }) };
      case 0x09 { let ?settlement = r.nat() else return null; let ?matched = r.bool() else return null; let ?detail = r.text() else return null; ?#settlementRequestJudged({ settlement; matched; detail }) };
      case _ null;
    }
  };

  // ── FSPIOP ──
  func writePairs(w : C.Writer, xs : [(Text, Text)]) { w.len16(xs.size()); for ((a, b) in xs.vals()) { w.text(a); w.text(b) } };
  func readPairs(r : C.Reader) : ?[(Text, Text)] {
    let ?n = r.len16() else return null;
    let out = List.empty<(Text, Text)>();
    var i = 0;
    while (i < n) { let ?a = r.text() else return null; let ?b = r.text() else return null; List.add(out, (a, b)); i += 1 };
    ?List.toArray(out)
  };
  func writeOptText(w : C.Writer, o : ?Text) { switch (o) { case null w.byte(0); case (?t) { w.byte(1); w.text(t) } } };
  func readOptText(r : C.Reader) : ??Text { switch (r.byte()) { case (?0) ?null; case (?1) { switch (r.text()) { case (?t) ??t; case null null } }; case (_) null } };
  func writeFspiopEvent(w : C.Writer, e : FT.FspiopEvent) {
    switch (e) {
      case (#participantDeclared(x)) { w.byte(0x01); w.text(x.rail); w.nat(x.participant); w.text(x.fspId); writePairs(w, x.endpoints) };
      case (#partyRegistered(x)) { w.byte(0x02); w.text(x.rail); w.text(x.idType); w.text(x.id); writeOptText(w, x.subId); w.text(x.fspId); writeOptText(w, x.currency) };
      case (#partyDeregistered(x)) { w.byte(0x03); w.text(x.rail); w.text(x.idType); w.text(x.id); writeOptText(w, x.subId) };
      case (#quoteReceived(x)) { w.byte(0x04); w.text(x.rail); w.text(x.quoteId); w.text(x.transactionId); w.text(x.payerFsp); w.text(x.payeeFsp); w.nat(x.amount); w.text(x.currency); w.text(x.amountType); writeOptText(w, x.expiration) };
      case (#quoteAnswered(x)) { w.byte(0x05); w.text(x.rail); w.text(x.quoteId); w.nat(x.transferAmount); w.text(x.currency); w.blob(x.condition); w.blob(x.ilpPacketHash); w.text(x.expiration) };
      case (#transferPrepared(x)) { w.byte(0x06); w.text(x.rail); w.text(x.transferId); w.nat(x.transfer); w.blob(x.condition); w.text(x.expiration); w.blob(x.ilpPacketHash) };
      case (#transferFulfilled(x)) { w.byte(0x07); w.text(x.rail); w.text(x.transferId); w.nat(x.transfer); w.blob(x.fulfilment); w.text(x.completedAt) };
      case (#transferAborted(x)) { w.byte(0x08); w.text(x.rail); w.text(x.transferId); w.nat(x.transfer); w.text(x.errorCode); w.text(x.reason) };
      case (#requestHandled(x)) { w.byte(0x09); w.text(x.rail); w.text(x.method); w.text(x.path); writeOptText(w, x.source); writeOptText(w, x.destination); w.blob(x.hash); w.nat(x.status); writeOptText(w, x.errorCode); w.nat(x.callbacks) };
    };
  };
  func readFspiopEvent(r : C.Reader) : ?FT.FspiopEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 { let ?rail = r.text() else return null; let ?participant = r.nat() else return null; let ?fspId = r.text() else return null; let ?endpoints = readPairs(r) else return null; ?#participantDeclared({ rail; participant; fspId; endpoints }) };
      case 0x02 { let ?rail = r.text() else return null; let ?idType = r.text() else return null; let ?id = r.text() else return null; let ?subId = readOptText(r) else return null; let ?fspId = r.text() else return null; let ?currency = readOptText(r) else return null; ?#partyRegistered({ rail; idType; id; subId; fspId; currency }) };
      case 0x03 { let ?rail = r.text() else return null; let ?idType = r.text() else return null; let ?id = r.text() else return null; let ?subId = readOptText(r) else return null; ?#partyDeregistered({ rail; idType; id; subId }) };
      case 0x04 { let ?rail = r.text() else return null; let ?quoteId = r.text() else return null; let ?transactionId = r.text() else return null; let ?payerFsp = r.text() else return null; let ?payeeFsp = r.text() else return null; let ?amount = r.nat() else return null; let ?currency = r.text() else return null; let ?amountType = r.text() else return null; let ?expiration = readOptText(r) else return null; ?#quoteReceived({ rail; quoteId; transactionId; payerFsp; payeeFsp; amount; currency; amountType; expiration }) };
      case 0x05 { let ?rail = r.text() else return null; let ?quoteId = r.text() else return null; let ?transferAmount = r.nat() else return null; let ?currency = r.text() else return null; let ?condition = r.blob() else return null; let ?ilpPacketHash = r.blob() else return null; let ?expiration = r.text() else return null; ?#quoteAnswered({ rail; quoteId; transferAmount; currency; condition; ilpPacketHash; expiration }) };
      case 0x06 { let ?rail = r.text() else return null; let ?transferId = r.text() else return null; let ?transfer = r.nat() else return null; let ?condition = r.blob() else return null; let ?expiration = r.text() else return null; let ?ilpPacketHash = r.blob() else return null; ?#transferPrepared({ rail; transferId; transfer; condition; expiration; ilpPacketHash }) };
      case 0x07 { let ?rail = r.text() else return null; let ?transferId = r.text() else return null; let ?transfer = r.nat() else return null; let ?fulfilment = r.blob() else return null; let ?completedAt = r.text() else return null; ?#transferFulfilled({ rail; transferId; transfer; fulfilment; completedAt }) };
      case 0x08 { let ?rail = r.text() else return null; let ?transferId = r.text() else return null; let ?transfer = r.nat() else return null; let ?errorCode = r.text() else return null; let ?reason = r.text() else return null; ?#transferAborted({ rail; transferId; transfer; errorCode; reason }) };
      case 0x09 { let ?rail = r.text() else return null; let ?method = r.text() else return null; let ?path = r.text() else return null; let ?source = readOptText(r) else return null; let ?destination = readOptText(r) else return null; let ?hash = r.blob() else return null; let ?status = r.nat() else return null; let ?errorCode = readOptText(r) else return null; let ?callbacks = r.nat() else return null; ?#requestHandled({ rail; method; path; source; destination; hash; status; errorCode; callbacks }) };
      case _ null;
    }
  };

  func writeSettlementEvent(w : C.Writer, e : SeT.SettlementEvent) {
    switch (e) {
      case (#schemeDeclared(x)) { w.byte(0x01); w.text(x.id); w.byte(switch (x.granularity) { case (#gross) 0; case (#net) 1 }); w.byte(switch (x.interchange) { case (#bilateral) 0; case (#multilateral) 1 }); w.byte(switch (x.delay) { case (#immediate) 0; case (#deferred) 1 }); w.text(x.reconciliation); w.text(x.feeIncome); w.nat(x.interchangeBps); w.nat(x.hubFeeBps); w.nat(x.alarmPercent) };
      case (#participantRegistered(x)) { w.byte(0x02); w.nat(x.party); w.text(x.bic); w.text(x.scheme); writeParticipantAccounts(w, x.accounts) };
      case (#participantDeactivated(x)) { w.byte(0x03); w.nat(x.participant) };
      case (#fundsRecorded(x)) { w.byte(0x04); w.nat(x.participant); w.text(x.currency); w.nat(x.amount); w.byte(switch (x.direction) { case (#in_) 0; case (#out) 1 }); w.nat(x.posting) };
      case (#capAlarm(x)) { w.byte(0x05); w.nat(x.participant); w.text(x.currency); w.nat(x.exposure); w.nat(x.cap); w.nat(x.alarmPercent) };
      case (#transferPrepared(x)) { w.byte(0x06); w.text(x.scheme); w.nat(x.payer); w.nat(x.payee); w.text(x.currency); w.nat(x.amount); w.text(x.reference); w.nat64(x.expiresAt); w.optNat(x.bulk); w.optNat(x.correctionOf) };
      case (#transferReserved(x)) { w.byte(0x07); w.nat(x.transfer); w.nat(x.reservation); w.bool(x.forwarded) };
      case (#transferFailed(x)) { w.byte(0x08); w.nat(x.transfer); w.text(x.reason) };
      case (#transferFulfilDependent(x)) { w.byte(0x09); w.nat(x.transfer) };
      case (#transferCommitted(x)) { w.byte(0x0A); w.nat(x.transfer); w.nat(x.posting); w.nat(x.window); w.nat(x.interchangeFee); w.nat(x.hubFee); writeNats(w, x.feePostings) };
      case (#transferAborted(x)) { w.byte(0x0B); w.nat(x.transfer); w.byte(switch (x.how) { case (#rejected) 0; case (#error) 1; case (#expired) 2 }); w.text(x.reason) };
      case (#transfersSettled(x)) { w.byte(0x0C); w.nat(x.settlement); writeNats(w, x.transfers) };
      case (#windowOpened(x)) { w.byte(0x0D); w.text(x.scheme); w.nat(x.businessDate) };
      case (#windowStateChanged(x)) { w.byte(0x0E); w.nat(x.window); w.byte(windowStateByte(x.to)); w.text(x.reason) };
      case (#settlementOpened(x)) { w.byte(0x0F); w.nat(x.window) };
      case (#settlementStateChanged(x)) { w.byte(0x10); w.nat(x.settlement); w.byte(settlementStateByte(x.to)); writeNets(w, x.nets); writeNats(w, x.postings); w.text(x.reason) };
      case (#bulkReceived(x)) { w.byte(0x11); w.text(x.scheme); w.nat(x.payer); w.text(x.reference); w.nat(x.ttlSeconds); w.len16(x.requests.size()); for (q in x.requests.vals()) { w.nat(q.payee); w.text(q.currency); w.nat(q.amount); w.text(q.reference) } };
      case (#bulkStateChanged(x)) { w.byte(0x12); w.nat(x.bulk); w.byte(bulkStateByte(x.to)); w.byte(bulkProcessingByte(x.processing)); w.nat(x.prepared); w.nat(x.done); writeFailures(w, x.failures) };
    }
  };

  func windowStateByte(s : SeT.WindowState) : Nat8 { switch (s) { case (#open) 0; case (#closed) 1; case (#pendingSettlement) 2; case (#processing) 3; case (#settled) 4; case (#aborted) 5; case (#failed) 6 } };
  func windowStateOf(b : Nat8) : ?SeT.WindowState { switch (b) { case 0 ?#open; case 1 ?#closed; case 2 ?#pendingSettlement; case 3 ?#processing; case 4 ?#settled; case 5 ?#aborted; case 6 ?#failed; case _ null } };
  func settlementStateByte(s : SeT.SettlementState) : Nat8 { switch (s) { case (#pendingSettlement) 0; case (#psTransfersRecorded) 1; case (#psTransfersReserved) 2; case (#psTransfersCommitted) 3; case (#settling) 4; case (#settled) 5; case (#aborted) 6 } };
  func settlementStateOf(b : Nat8) : ?SeT.SettlementState { switch (b) { case 0 ?#pendingSettlement; case 1 ?#psTransfersRecorded; case 2 ?#psTransfersReserved; case 3 ?#psTransfersCommitted; case 4 ?#settling; case 5 ?#settled; case 6 ?#aborted; case _ null } };
  func bulkStateByte(s : SeT.BulkState) : Nat8 { switch (s) { case (#received) 0; case (#pendingPrepare) 1; case (#accepted) 2; case (#processing) 3; case (#pendingFulfil) 4; case (#completed) 5; case (#rejected) 6; case (#invalid) 7; case (#expired) 8; case (#aborting) 9; case (#expiring) 10; case (#pendingInvalid) 11 } };
  func bulkStateOf(b : Nat8) : ?SeT.BulkState { switch (b) { case 0 ?#received; case 1 ?#pendingPrepare; case 2 ?#accepted; case 3 ?#processing; case 4 ?#pendingFulfil; case 5 ?#completed; case 6 ?#rejected; case 7 ?#invalid; case 8 ?#expired; case 9 ?#aborting; case 10 ?#expiring; case 11 ?#pendingInvalid; case _ null } };
  func bulkProcessingByte(s : SeT.BulkProcessingState) : Nat8 { switch (s) { case (#received) 0; case (#receivedDuplicate) 1; case (#receivedInvalid) 2; case (#accepted) 3; case (#processing) 4; case (#fulfilDuplicate) 5; case (#fulfilInvalid) 6; case (#completed) 7; case (#rejected) 8; case (#expired) 9; case (#aborting) 10 } };
  func bulkProcessingOf(b : Nat8) : ?SeT.BulkProcessingState { switch (b) { case 0 ?#received; case 1 ?#receivedDuplicate; case 2 ?#receivedInvalid; case 3 ?#accepted; case 4 ?#processing; case 5 ?#fulfilDuplicate; case 6 ?#fulfilInvalid; case 7 ?#completed; case 8 ?#rejected; case 9 ?#expired; case 10 ?#aborting; case _ null } };

  func readSettlementEvent(r : C.Reader) : ?SeT.SettlementEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 {
        let ?id = r.text() else return null; let ?g = r.byte() else return null; let ?ic = r.byte() else return null; let ?d = r.byte() else return null;
        let ?reconciliation = r.text() else return null; let ?feeIncome = r.text() else return null; let ?interchangeBps = r.nat() else return null; let ?hubFeeBps = r.nat() else return null; let ?alarmPercent = r.nat() else return null;
        let granularity : SeT.Granularity = switch (g) { case 0 #gross; case 1 #net; case _ return null };
        let interchange : SeT.Interchange = switch (ic) { case 0 #bilateral; case 1 #multilateral; case _ return null };
        let delay : SeT.Delay = switch (d) { case 0 #immediate; case 1 #deferred; case _ return null };
        ?#schemeDeclared({ id; granularity; interchange; delay; reconciliation; feeIncome; interchangeBps; hubFeeBps; alarmPercent })
      };
      case 0x02 { let ?party = r.nat() else return null; let ?bic = r.text() else return null; let ?scheme = r.text() else return null; let ?accounts = readParticipantAccounts(r) else return null; ?#participantRegistered({ party; bic; scheme; accounts }) };
      case 0x03 { let ?participant = r.nat() else return null; ?#participantDeactivated({ participant }) };
      case 0x04 { let ?participant = r.nat() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?d = r.byte() else return null; let ?posting = r.nat() else return null; let direction : { #in_; #out } = switch (d) { case 0 #in_; case 1 #out; case _ return null }; ?#fundsRecorded({ participant; currency; amount; direction; posting }) };
      case 0x05 { let ?participant = r.nat() else return null; let ?currency = r.text() else return null; let ?exposure = r.nat() else return null; let ?cap = r.nat() else return null; let ?alarmPercent = r.nat() else return null; ?#capAlarm({ participant; currency; exposure; cap; alarmPercent }) };
      case 0x06 { let ?scheme = r.text() else return null; let ?payer = r.nat() else return null; let ?payee = r.nat() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?reference = r.text() else return null; let ?expiresAt = r.nat64() else return null; let ?bulk = r.optNat() else return null; let ?correctionOf = r.optNat() else return null; ?#transferPrepared({ scheme; payer; payee; currency; amount; reference; expiresAt; bulk; correctionOf }) };
      case 0x07 { let ?transfer = r.nat() else return null; let ?reservation = r.nat() else return null; let ?forwarded = r.bool() else return null; ?#transferReserved({ transfer; reservation; forwarded }) };
      case 0x08 { let ?transfer = r.nat() else return null; let ?reason = r.text() else return null; ?#transferFailed({ transfer; reason }) };
      case 0x09 { let ?transfer = r.nat() else return null; ?#transferFulfilDependent({ transfer }) };
      case 0x0A { let ?transfer = r.nat() else return null; let ?posting = r.nat() else return null; let ?window = r.nat() else return null; let ?interchangeFee = r.nat() else return null; let ?hubFee = r.nat() else return null; let ?feePostings = readNatList(r) else return null; ?#transferCommitted({ transfer; posting; window; interchangeFee; hubFee; feePostings }) };
      case 0x0B { let ?transfer = r.nat() else return null; let ?h = r.byte() else return null; let ?reason = r.text() else return null; let how : { #rejected; #error; #expired } = switch (h) { case 0 #rejected; case 1 #error; case 2 #expired; case _ return null }; ?#transferAborted({ transfer; how; reason }) };
      case 0x0C { let ?settlement = r.nat() else return null; let ?transfers = readNatList(r) else return null; ?#transfersSettled({ settlement; transfers }) };
      case 0x0D { let ?scheme = r.text() else return null; let ?businessDate = r.nat() else return null; ?#windowOpened({ scheme; businessDate }) };
      case 0x0E { let ?window = r.nat() else return null; let ?b = r.byte() else return null; let ?to = windowStateOf(b) else return null; let ?reason = r.text() else return null; ?#windowStateChanged({ window; to; reason }) };
      case 0x0F { let ?window = r.nat() else return null; ?#settlementOpened({ window }) };
      case 0x10 { let ?settlement = r.nat() else return null; let ?b = r.byte() else return null; let ?to = settlementStateOf(b) else return null; let ?nets = readNets(r) else return null; let ?postings = readNatList(r) else return null; let ?reason = r.text() else return null; ?#settlementStateChanged({ settlement; to; nets; postings; reason }) };
      case 0x11 {
        let ?scheme = r.text() else return null; let ?payer = r.nat() else return null; let ?reference = r.text() else return null; let ?ttlSeconds = r.nat() else return null; let ?n = r.len16() else return null;
        let requests = List.empty<SeT.BulkRequest>();
        var i = 0;
        while (i < n) { let ?payee = r.nat() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?ref = r.text() else return null; List.add(requests, { payee; currency; amount; reference = ref }); i += 1 };
        ?#bulkReceived({ scheme; payer; reference; ttlSeconds; requests = List.toArray(requests) })
      };
      case 0x12 { let ?bulk = r.nat() else return null; let ?b = r.byte() else return null; let ?to = bulkStateOf(b) else return null; let ?p = r.byte() else return null; let ?processing = bulkProcessingOf(p) else return null; let ?prepared = r.nat() else return null; let ?done = r.nat() else return null; let ?failures = readFailures(r) else return null; ?#bulkStateChanged({ bulk; to; processing; prepared; done; failures }) };
      case _ null;
    }
  };

  func wOptText(w : C.Writer, o : ?Text) { switch (o) { case null w.byte(0); case (?t) { w.byte(1); w.text(t) } } };

  /// A rule specification: the type tag, then its parameters in declaration order.
  public func writeRuleSpec(w : C.Writer, spec : MT.RuleSpec) {
    switch (spec) {
      case (#velocity(x)) { w.byte(1); w.nat(x.count); w.nat(x.windowDays) };
      case (#structuring(x)) { w.byte(2); w.nat(x.threshold); w.nat(x.bandPercent); w.nat(x.count); w.nat(x.windowDays); w.nat(x.maxScan) };
      case (#roundTrip(x)) { w.byte(3); w.nat(x.windowDays); w.nat(x.minAmount) };
      case (#fanOut(x)) { w.byte(4); w.nat(x.distinct); w.nat(x.windowDays) };
      case (#fanIn(x)) { w.byte(5); w.nat(x.distinct); w.nat(x.windowDays) };
      case (#dormantThenActive(x)) { w.byte(6); w.nat(x.dormantDays); w.nat(x.amount) };
      case (#passThrough(x)) { w.byte(7); w.nat(x.inOutPercent); w.nat(x.windowDays); w.nat(x.minAmount) };
      case (#largeCash(x)) { w.byte(8); w.nat(x.threshold); w.len16(x.channels.size()); for (c in x.channels.vals()) w.text(c) };
    }
  };

  public func readRuleSpec(r : C.Reader) : ?MT.RuleSpec {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 1 { let ?count = r.nat() else return null; let ?windowDays = r.nat() else return null; ?#velocity({ count; windowDays }) };
      case 2 {
        let ?threshold = r.nat() else return null; let ?bandPercent = r.nat() else return null; let ?count = r.nat() else return null;
        let ?windowDays = r.nat() else return null; let ?maxScan = r.nat() else return null;
        ?#structuring({ threshold; bandPercent; count; windowDays; maxScan })
      };
      case 3 { let ?windowDays = r.nat() else return null; let ?minAmount = r.nat() else return null; ?#roundTrip({ windowDays; minAmount }) };
      case 4 { let ?distinct = r.nat() else return null; let ?windowDays = r.nat() else return null; ?#fanOut({ distinct; windowDays }) };
      case 5 { let ?distinct = r.nat() else return null; let ?windowDays = r.nat() else return null; ?#fanIn({ distinct; windowDays }) };
      case 6 { let ?dormantDays = r.nat() else return null; let ?amount = r.nat() else return null; ?#dormantThenActive({ dormantDays; amount }) };
      case 7 { let ?inOutPercent = r.nat() else return null; let ?windowDays = r.nat() else return null; let ?minAmount = r.nat() else return null; ?#passThrough({ inOutPercent; windowDays; minAmount }) };
      case 8 {
        let ?threshold = r.nat() else return null;
        let ?n = r.len16() else return null;
        let channels = List.empty<Text>();
        var i = 0;
        while (i < n) { let ?c = r.text() else return null; List.add(channels, c); i += 1 };
        ?#largeCash({ threshold; channels = List.toArray(channels) })
      };
      case _ null;
    }
  };

  func rOptTextM(r : C.Reader) : ??Text {
    let ?present = r.byte() else return null;
    if (present == 0) return ?null;
    if (present != 1) return null;
    let ?t = r.text() else return null;
    ?(?t)
  };

  func writeMonitoringEvent(w : C.Writer, e : MT.MonitoringEvent) {
    switch (e) {
      case (#ruleDefined(x)) { w.byte(0x01); w.text(x.id); w.nat(x.version); wOptText(w, x.currency); writeRuleSpec(w, x.spec) };
      case (#ruleRetired(x)) { w.byte(0x02); w.text(x.id); w.nat(x.version) };
    }
  };

  func readMonitoringEvent(r : C.Reader) : ?MT.MonitoringEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 {
        let ?id = r.text() else return null; let ?version = r.nat() else return null;
        let ?currency = rOptTextM(r) else return null; let ?spec = readRuleSpec(r) else return null;
        ?#ruleDefined({ id; version; currency; spec })
      };
      case 0x02 { let ?id = r.text() else return null; let ?version = r.nat() else return null; ?#ruleRetired({ id; version }) };
      case _ null;
    }
  };

  func wPrincipals(w : C.Writer, ps : [Principal]) { w.len16(ps.size()); for (p in ps.vals()) { w.principal(p) } };

  func rPrincipals(r : C.Reader) : ?[Principal] {
    let ?n = r.len16() else return null;
    let out = List.empty<Principal>();
    var i = 0;
    while (i < n) { let ?p = r.principal() else return null; List.add(out, p); i += 1 };
    ?List.toArray(out)
  };

  /// Archive events, tag 0x46. Each variant has its own sub-tag; the layout is the variant's fields
  /// in declaration order.
  func writeArchiveEvent(w : C.Writer, e : AT.ArchiveEvent) {
    switch (e) {
      case (#imagePinned(x)) { w.byte(0x01); w.blob(x.sha256); w.nat(x.bytes); w.text(x.name) };
      case (#imageSealed(x)) { w.byte(0x02); w.blob(x.sha256); w.nat(x.bytes) };
      case (#controllersSet(x)) { w.byte(0x03); wPrincipals(w, x.controllers) };
      case (#spawnAuthorised(x)) { w.byte(0x04); w.text(x.purpose) };
      case (#createIssued(x)) { w.byte(0x05); w.nat(x.spawn); w.nat(x.attempt) };
      case (#childRemembered(x)) { w.byte(0x06); w.nat(x.spawn); w.nat64(x.cid) };
      case (#installIssued(x)) { w.byte(0x07); w.nat(x.spawn); w.nat64(x.cid); w.blob(x.image); w.nat(x.attempt) };
      case (#childConfirmed(x)) { w.byte(0x08); w.nat(x.spawn); w.nat64(x.cid); w.blob(x.image) };
      case (#confirmRefused(x)) { w.byte(0x09); w.nat(x.spawn); w.nat64(x.cid); w.blob(x.offered) };
      case (#controllersIssued(x)) { w.byte(0x0A); w.nat(x.spawn); w.nat64(x.cid); wPrincipals(w, x.controllers); w.nat(x.attempt) };
      case (#childReady(x)) { w.byte(0x0B); w.nat(x.spawn); w.nat64(x.cid) };
      case (#spawnAbandoned(x)) { w.byte(0x0C); w.nat(x.spawn); w.text(x.reason) };
      case (#childAdopted(x)) { w.byte(0x0D); w.nat64(x.cid); w.blob(x.image); wPrincipals(w, x.controllers); w.text(x.purpose) };
    }
  };

  func readArchiveEvent(r : C.Reader) : ?AT.ArchiveEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 { let ?sha256 = r.blob() else return null; let ?bytes = r.nat() else return null; let ?name = r.text() else return null; ?#imagePinned({ sha256; bytes; name }) };
      case 0x02 { let ?sha256 = r.blob() else return null; let ?bytes = r.nat() else return null; ?#imageSealed({ sha256; bytes }) };
      case 0x03 { let ?controllers = rPrincipals(r) else return null; ?#controllersSet({ controllers }) };
      case 0x04 { let ?purpose = r.text() else return null; ?#spawnAuthorised({ purpose }) };
      case 0x05 { let ?spawn = r.nat() else return null; let ?attempt = r.nat() else return null; ?#createIssued({ spawn; attempt }) };
      case 0x06 { let ?spawn = r.nat() else return null; let ?cid = r.nat64() else return null; ?#childRemembered({ spawn; cid }) };
      case 0x07 {
        let ?spawn = r.nat() else return null; let ?cid = r.nat64() else return null;
        let ?image = r.blob() else return null; let ?attempt = r.nat() else return null;
        ?#installIssued({ spawn; cid; image; attempt })
      };
      case 0x08 { let ?spawn = r.nat() else return null; let ?cid = r.nat64() else return null; let ?image = r.blob() else return null; ?#childConfirmed({ spawn; cid; image }) };
      case 0x09 { let ?spawn = r.nat() else return null; let ?cid = r.nat64() else return null; let ?offered = r.blob() else return null; ?#confirmRefused({ spawn; cid; offered }) };
      case 0x0A {
        let ?spawn = r.nat() else return null; let ?cid = r.nat64() else return null;
        let ?controllers = rPrincipals(r) else return null; let ?attempt = r.nat() else return null;
        ?#controllersIssued({ spawn; cid; controllers; attempt })
      };
      case 0x0B { let ?spawn = r.nat() else return null; let ?cid = r.nat64() else return null; ?#childReady({ spawn; cid }) };
      case 0x0C { let ?spawn = r.nat() else return null; let ?reason = r.text() else return null; ?#spawnAbandoned({ spawn; reason }) };
      case 0x0D {
        let ?cid = r.nat64() else return null; let ?image = r.blob() else return null;
        let ?controllers = rPrincipals(r) else return null; let ?purpose = r.text() else return null;
        ?#childAdopted({ cid; image; controllers; purpose })
      };
      case _ null;
    }
  };

  public func writeEvent(w : C.Writer, e : T.Event) {
    switch (e) {
      case (#bookOpened(x)) { w.byte(0x10); w.text(x.id); w.text(x.name); switch (x.parent) { case null w.byte(0); case (?p) { w.byte(1); w.text(p) } } };
      case (#bookClosed(x)) { w.byte(0x11); w.text(x.id) };
      case (#roleDefined(x)) { w.byte(0x12); w.text(x.id); w.text(x.name); w.len16(x.permissions.size()); for (p in x.permissions.vals()) { w.text(p) } };
      case (#roleGranted(x)) { w.byte(0x13); w.principal(x.subject); w.text(x.role); wScope(w, x.scope) };
      case (#roleRevoked(x)) { w.byte(0x14); w.principal(x.subject); w.text(x.role) };
      case (#dualPolicySet(x)) { w.byte(0x15); wPolicy(w, x) };
      case (#dualPolicyCleared(x)) { w.byte(0x16); w.text(x.permission) };
      case (#bankAdminTransferred(x)) { w.byte(0x17); w.principal(x.admin) };
      case (#featureActivationSet(x)) { w.byte(0x18); w.text(x.feature); w.nat64(x.height) };
      case (#commandProposed(x)) {
        // the body is not here: it is the block's trailer (encodeBlockAtVersion), bound by commandHash
        w.byte(0x30); w.blob(x.commandHash); w.byte(x.commandEncoding); w.text(x.permission); writeOptText(w, x.book); w.principal(x.maker);
        w.nat(x.required); w.text(x.eligibleRole); w.nat64(x.expiresAt); w.text(x.justification);
      };
      case (#commandApproved(x)) { w.byte(0x31); w.nat(x.proposal); w.blob(x.commandHash); w.principal(x.checker) };
      case (#commandRejected(x)) { w.byte(0x32); w.nat(x.proposal); w.principal(x.checker); w.text(x.reason) };
      case (#commandExecuted(x)) {
        w.byte(0x33); w.nat(x.proposal); w.blob(x.commandHash); wNats(w, x.postings);
        switch (x.charge) { case null w.byte(0); case (?c) { w.byte(1); w.nat(c.day); w.len16(c.totals.size()); for ((ccy, amt) in c.totals.vals()) { w.text(ccy); w.nat(amt) } } };
      };
      case (#commandExpired(x)) { w.byte(0x34); w.nat(x.proposal) };
      case (#emergencyOverride(x)) {
        w.byte(0x35); w.byte(x.commandEncoding); ignore writeCommandAt(x.commandEncoding, w, x.command); w.blob(x.commandHash); w.principal(x.actor_);
        w.principal(x.witness); w.text(x.justification);
      };
      case (#overrideReviewed(x)) { w.byte(0x36); w.nat(x.override_); w.principal(x.reviewer); w.text(x.disposition) };
      case (#operationRefused(x)) { w.byte(0x50); w.principal(x.subject); w.text(x.permission); wRefusal(w, x.reason); w.text(x.detail) };
      case (#party(pe)) { w.byte(0x40); writePartyEvent(w, pe) };
      case (#product(pe)) { w.byte(0x41); PC.writeEvent(w, pe) };
      case (#close(ce)) { w.byte(0x42); CC.writeEvent(w, ce) };
      case (#batch(be)) { w.byte(0x43); BC.writeEvent(w, be) };
      case (#report(re)) { w.byte(0x44); RC.writeEvent(w, re) };
      case (#index(ie)) {
        w.byte(0x45);
        switch (ie) {
          case (#counterpartyClassDimensionSet(x)) {
            w.byte(0x01);
            switch (x.dimension) {
              case (?d) { w.byte(1); w.text(d.schema); w.text(d.field) };
              case null w.byte(0);
            };
          };
        };
      };
      case (#archive(ae)) { w.byte(0x46); writeArchiveEvent(w, ae) };
      case (#monitoring(me)) { w.byte(0x47); writeMonitoringEvent(w, me) };
      case (#alert(ae)) { w.byte(0x48); writeAlertEvent(w, ae) };
      case (#collections(ce)) { w.byte(0x4E); writeCollectionsEvent(w, ce) };
      case (#origination(oe)) { w.byte(0x4F); OCan.writeEvent(w, oe) };
      case (#facility(fe)) { w.byte(0x51); FCan.writeEvent(w, fe) };
      case (#teller(te)) { w.byte(0x52); TCan.writeEvent(w, te) };
      case (#trade(tr)) { w.byte(0x53); TrCan.writeEvent(w, tr) };
      case (#islamic(ie)) { w.byte(0x54); ICan.writeEvent(w, ie) };
      case (#treasury(te)) { w.byte(0x55); TyCan.writeEvent(w, te) };
      case (#card(ce)) { w.byte(0x56); CdCan.writeEvent(w, ce) };
      case (#packing(pe)) { w.byte(0x49); writePackingEvent(w, pe) };
      case (#shard(se)) { w.byte(0x4A); writeShardEvent(w, se) };
      case (#settlement(se)) { w.byte(0x4B); writeSettlementEvent(w, se) };
      case (#payments(pe)) { w.byte(0x4C); writePaymentsEvent(w, pe) };
      case (#fspiop(fe)) { w.byte(0x4D); writeFspiopEvent(w, fe) };
    };
  };

  // ═══════════════════════════════════════════════════════
  //  READERS
  // ═══════════════════════════════════════════════════════

  func rOptTexts(r : C.Reader) : ??[Text] {
    let ?present = r.byte() else return null;
    if (present == 0) return ?null;
    if (present != 1) return null;
    let ?n = r.len16() else return null;
    let out = List.empty<Text>();
    var i = 0;
    while (i < n) { let ?t = r.text() else return null; List.add(out, t); i += 1 };
    ?(?List.toArray(out))
  };

  func rOptMoney(r : C.Reader) : ??[T.Money] {
    let ?present = r.byte() else return null;
    if (present == 0) return ?null;
    if (present != 1) return null;
    let ?n = r.len16() else return null;
    let out = List.empty<T.Money>();
    var i = 0;
    while (i < n) {
      let ?c = r.text() else return null;
      let ?a = r.nat() else return null;
      List.add(out, { currency = c; amount = a });
      i += 1;
    };
    ?(?List.toArray(out))
  };

  func rScope(r : C.Reader) : ?T.Scope {
    let ?books = rOptTexts(r) else return null;
    let ?currencies = rOptTexts(r) else return null;
    let ?ceiling = rOptMoney(r) else return null;
    let ?dailyLimit = rOptMoney(r) else return null;
    ?{ books; currencies; ceiling; dailyLimit }
  };

  func rRefusal(r : C.Reader) : ?T.RefusalReason {
    switch (r.byte()) {
      case (?0) ?#noGrant; case (?1) ?#outsideBook; case (?2) ?#outsideCurrency;
      case (?3) ?#overCeiling; case (?4) ?#overDailyLimit; case (?5) ?#notEligibleChecker;
      case (?6) ?#selfApproval; case (?7) ?#commandHashMismatch; case (?8) ?#proposalExpired;
      case (?9) ?#featureInactive; case (?10) ?#bookClosed; case (?11) ?#noWitness;
      case (?12) ?#notAdmin; case _ null;
    }
  };

  func rPolicy(r : C.Reader) : ?T.DualPolicy {
    let ?permission = r.text() else return null;
    let ?required = r.nat() else return null;
    let ?eligibleRole = r.text() else return null;
    let ?ttlSeconds = r.nat() else return null;
    ?{ permission; required; eligibleRole; ttlSeconds }
  };

  func rOptText(r : C.Reader) : ??Text {
    let ?present = r.byte() else return null;
    if (present == 0) return ?null;
    if (present != 1) return null;
    let ?t = r.text() else return null;
    ?(?t)
  };

  func rTexts(r : C.Reader) : ?[Text] {
    let ?n = r.len16() else return null;
    let out = List.empty<Text>();
    var i = 0;
    while (i < n) { let ?t = r.text() else return null; List.add(out, t); i += 1 };
    ?List.toArray(out)
  };

  func rLegs(r : C.Reader) : ?[JT.Leg] {
    let ?n = r.len16() else return null;
    let out = List.empty<JT.Leg>();
    var i = 0;
    while (i < n) { let ?l = r.leg() else return null; List.add(out, l); i += 1 };
    ?List.toArray(out)
  };

  func rNats(r : C.Reader) : ?[Nat] {
    let ?n = r.len16() else return null;
    let out = List.empty<Nat>();
    var i = 0;
    while (i < n) { let ?x = r.nat() else return null; List.add(out, x); i += 1 };
    ?List.toArray(out)
  };

  func rManualEntry(r : C.Reader) : ?T.ManualEntry {
    let ?book = r.text() else return null;
    let ?postingDate = r.nat() else return null;
    let ?valueDate = r.nat() else return null;
    let ?period = r.text() else return null;
    let ?legs = rLegs(r) else return null;
    let ?narration = r.text() else return null;
    let ?idempotencyKey = r.blob() else return null;
    let ?correctionOf = r.optNat() else return null;
    ?{ book; postingDate; valueDate; period; legs; narration; idempotencyKey; correctionOf }
  };


  // ─── party readers ────────────────────────────────────────────────────────

  func rPartyKind(r : C.Reader) : ?PT.PartyKind {
    switch (r.byte()) { case (?0) ?#natural; case (?1) ?#legal; case _ null }
  };

  func rLifecycle(r : C.Reader) : ?PT.Lifecycle {
    switch (r.byte()) {
      case (?0) ?#prospect; case (?1) ?#pendingKyc; case (?2) ?#active;
      case (?3) ?#dormant; case (?4) ?#blocked; case (?5) ?#closed; case _ null;
    }
  };

  func rCdd(r : C.Reader) : ?PT.CddLevel {
    switch (r.byte()) { case (?0) ?#simplified; case (?1) ?#standard; case (?2) ?#enhanced; case _ null }
  };

  func rRisk(r : C.Reader) : ?PT.RiskRating {
    switch (r.byte()) { case (?0) ?#low; case (?1) ?#medium; case (?2) ?#high; case _ null }
  };

  func rFields(r : C.Reader) : ?[PT.FieldCommit] {
    let ?n = r.len16() else return null;
    let out = List.empty<PT.FieldCommit>();
    var i = 0;
    while (i < n) {
      let ?name = r.text() else return null;
      let ?commit = r.blob() else return null;
      List.add(out, { name; commit });
      i += 1;
    };
    ?List.toArray(out)
  };

  func rOptCommit(r : C.Reader) : ??Blob {
    let ?present = r.byte() else return null;
    if (present == 0) return ?null;
    if (present != 1) return null;
    let ?c = r.blob() else return null;
    ?(?c)
  };

  func rDocument(r : C.Reader) : ?PT.DocumentRef {
    let ?kind = r.text() else return null;
    let ?commit = r.blob() else return null;
    let ?issued = r.nat() else return null;
    let ?expires = r.optNat() else return null;
    ?{ kind; commit; issued; expires }
  };

  func rRelationKind(r : C.Reader) : ?PT.RelationKind {
    switch (r.byte()) {
      case (?0) ?#guarantor; case (?1) ?#authorisedSignatory; case (?2) ?#beneficialOwner;
      case (?3) ?#director; case (?4) ?#spouse; case (?5) ?#parent; case (?6) ?#child;
      case (?7) ?#groupMember;
      case (?8) { let ?t = r.text() else return null; ?#other(t) };
      case _ null;
    }
  };

  func rRelationship(r : C.Reader) : ?PT.Relationship {
    let ?kind = rRelationKind(r) else return null;
    let ?other = r.nat() else return null;
    ?{ kind; other }
  };

  func rFieldType(r : C.Reader) : ?PT.FieldType {
    switch (r.byte()) {
      case (?0) { let ?m = r.nat() else return null; ?#text({ maxBytes = m }) };
      case (?1) { let ?lo = rInt(r) else return null; let ?hi = rInt(r) else return null; ?#integer({ min = lo; max = hi }) };
      case (?2) ?#date;
      case (?3) {
        let ?n = r.len16() else return null;
        let out = List.empty<Text>();
        var i = 0;
        while (i < n) { let ?t = r.text() else return null; List.add(out, t); i += 1 };
        ?#enumerated(List.toArray(out))
      };
      case (?4) ?#boolean;
      case (?5) ?#commitment;
      case _ null;
    }
  };

  func rFieldValue(r : C.Reader) : ?PT.FieldValue {
    switch (r.byte()) {
      case (?0) { let ?t = r.text() else return null; ?#text(t) };
      case (?1) { let ?i = rInt(r) else return null; ?#integer(i) };
      case (?2) { let ?d = r.nat() else return null; ?#date(d) };
      case (?3) { let ?e = r.text() else return null; ?#enumerated(e) };
      case (?4) { let ?b = r.bool() else return null; ?#boolean(b) };
      case (?5) { let ?c = r.blob() else return null; ?#commitment(c) };
      case _ null;
    }
  };

  func rEntityKind(r : C.Reader) : ?PT.EntityKind {
    switch (r.byte()) { case (?0) ?#party; case (?1) ?#collateral; case _ null }
  };

  func rFieldDefs(r : C.Reader) : ?[PT.FieldDef] {
    let ?n = r.len16() else return null;
    let out = List.empty<PT.FieldDef>();
    var i = 0;
    while (i < n) {
      let ?name = r.text() else return null;
      let ?ft = rFieldType(r) else return null;
      let ?req = r.bool() else return null;
      List.add(out, { name; fieldType = ft; required = req });
      i += 1;
    };
    ?List.toArray(out)
  };

  func rExtensionValues(r : C.Reader) : ?[PT.ExtensionValue] {
    let ?n = r.len16() else return null;
    let out = List.empty<PT.ExtensionValue>();
    var i = 0;
    while (i < n) {
      let ?schema = r.text() else return null;
      let ?name = r.text() else return null;
      let ?value = rFieldValue(r) else return null;
      List.add(out, { schema; name; value });
      i += 1;
    };
    ?List.toArray(out)
  };

  func rCollateralKind(r : C.Reader) : ?PT.CollateralKind {
    switch (r.byte()) {
      case (?0) ?#cashDeposit; case (?1) ?#property; case (?2) ?#vehicle; case (?3) ?#securities;
      case (?4) {
        let ?reg = r.principal() else return null;
        let ?tok = r.nat() else return null;
        ?#tokenisedTitle({ registry = reg; tokenId = tok })
      };
      case (?5) { let ?t = r.text() else return null; ?#other(t) };
      case _ null;
    }
  };

  func rValuation(r : C.Reader) : ?PT.Valuation {
    let ?amount = r.nat() else return null;
    let ?currency = r.text() else return null;
    let ?asOf = r.nat() else return null;
    let ?source = r.text() else return null;
    let ?haircut = r.nat() else return null;
    ?{ amount; currency; asOf; source; haircut }
  };

  func rAdjacencySide(r : C.Reader) : ??{ entry : Blob; index : Nat; path : [Blob] } {
    let ?present = r.byte() else return null;
    if (present == 0) return ?null;
    if (present != 1) return null;
    let ?entry = r.blob() else return null;
    let ?index = r.nat() else return null;
    let ?n = r.len16() else return null;
    let out = List.empty<Blob>();
    var i = 0;
    while (i < n) { let ?h = r.blob() else return null; List.add(out, h); i += 1 };
    ?(?{ entry; index; path = List.toArray(out) })
  };

  func rAdjacency(r : C.Reader) : ?PT.AdjacencyProof {
    let ?lower = rAdjacencySide(r) else return null;
    let ?upper = rAdjacencySide(r) else return null;
    ?{ lower; upper }
  };

  func rScreeningDecision(r : C.Reader) : ?PT.ScreeningDecision {
    let ?party = r.nat() else return null;
    let ?listVersion = r.text() else return null;
    let ?listRoot = r.blob() else return null;
    let decision = switch (r.byte()) {
      case (?0) #clear;
      case (?1) { let ?m = r.nat() else return null; #hit({ matches = m }) };
      case (?2) { let ?t = r.text() else return null; #cleared({ reason = t }) };
      case (?3) #confirmed;
      case _ return null;
    };
    let ?screener = r.principal() else return null;
    let ?justificationCommit = r.blob() else return null;
    ?{ party; listVersion; listRoot; decision; screener; justificationCommit }
  };

  func rFormat(r : C.Reader) : ?Iban.Format {
    let ?country = r.text() else return null;
    let ?bank = r.text() else return null;
    let ?branch = r.text() else return null;
    let ?serialWidth = r.nat() else return null;
    let ?prefix = r.text() else return null;
    ?{ country; bank; branch; serialWidth; prefix }
  };

  func rJwks(r : C.Reader) : ?PT.Jwks {
    let ?issuer = r.text() else return null;
    let ?n = r.len16() else return null;
    let out = List.empty<{ kid : Text; n : Blob; e : Blob }>();
    var i = 0;
    while (i < n) {
      let ?kid = r.text() else return null;
      let ?nn = r.blob() else return null;
      let ?ee = r.blob() else return null;
      List.add(out, { kid; n = nn; e = ee });
      i += 1;
    };
    let ?pinnedAtBlock = r.nat() else return null;
    ?{ issuer; keys = List.toArray(out); pinnedAtBlock }
  };

  func rAssurance(r : C.Reader) : ?PT.Assurance {
    switch (r.byte()) { case (?0) ?#aal1; case (?1) ?#aal2; case (?2) ?#aal3; case _ null }
  };

  func rCredential(r : C.Reader) : ?PT.Credential {
    let ?subject = r.principal() else return null;
    let kind = switch (r.byte()) {
      case (?0) { let ?a = r.blob() else return null; #passkey({ aaguid = a }) };
      case (?1) {
        let ?iss = r.text() else return null;
        let ?sc = r.blob() else return null;
        #oidc({ issuer = iss; subjectCommit = sc })
      };
      case _ return null;
    };
    let ?assurance = rAssurance(r) else return null;
    let ?registeredAtBlock = r.nat() else return null;
    let ?revokedAtBlock = r.optNat() else return null;
    ?{ subject; kind; assurance; registeredAtBlock; revokedAtBlock }
  };

  public func readPartyEvent(r : C.Reader) : ?PT.PartyEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 {
        let ?kind = rPartyKind(r) else return null;
        let ?salt = r.blob() else return null;
        let ?identityCommit = r.blob() else return null;
        let ?dedupCommit = rOptCommit(r) else return null;
        let ?attributes = rFields(r) else return null;
        let ?book = r.text() else return null;
        let ?cddLevel = rCdd(r) else return null;
        let ?riskRating = rRisk(r) else return null;
        let ?pep = r.bool() else return null;
        let ?reviewDue = r.nat() else return null;
        ?#partyCreated({ kind; salt; identityCommit; dedupCommit; attributes; book; cddLevel; riskRating; pep; reviewDue })
      };
      case 0x02 { let ?party = r.nat() else return null; let ?attributes = rFields(r) else return null; ?#partyAmended({ party; attributes }) };
      case 0x03 { let ?party = r.nat() else return null; let ?to = rLifecycle(r) else return null; ?#partyLifecycleSet({ party; to }) };
      case 0x04 {
        let ?party = r.nat() else return null;
        let ?level = rCdd(r) else return null;
        let ?riskRating = rRisk(r) else return null;
        let ?pep = r.bool() else return null;
        let ?reviewDue = r.nat() else return null;
        ?#partyCddSet({ party; level; riskRating; pep; reviewDue })
      };
      case 0x05 { let ?party = r.nat() else return null; let ?d = rDocument(r) else return null; ?#partyDocumentAdded({ party; document = d }) };
      case 0x06 { let ?party = r.nat() else return null; let ?rel = rRelationship(r) else return null; ?#partyRelationshipAdded({ party; relationship = rel }) };
      case 0x07 { let ?party = r.nat() else return null; let ?values = rExtensionValues(r) else return null; ?#partyExtensionSet({ party; values }) };
      case 0x08 { let ?party = r.nat() else return null; let ?identifier = r.text() else return null; ?#partyIdentifierIssued({ party; identifier }) };
      case 0x09 {
        let ?version = r.text() else return null;
        let ?root = r.blob() else return null;
        let ?count = r.nat() else return null;
        let ?normalisation = r.text() else return null;
        ?#screeningListCommitted({ version; root; count; normalisation })
      };
      case 0x0A { let ?party = r.nat() else return null; let ?listVersion = r.text() else return null; ?#screeningProven({ party; listVersion }) };
      case 0x0B { let ?d = rScreeningDecision(r) else return null; ?#screeningDecisionRecorded(d) };
      case 0x0C {
        let ?id = r.text() else return null;
        let ?entity = rEntityKind(r) else return null;
        let ?fields = rFieldDefs(r) else return null;
        ?#schemaRegistered({ id; entity; fields })
      };
      case 0x0D {
        let ?party = r.nat() else return null;
        let ?kind = rCollateralKind(r) else return null;
        let ?valuation = rValuation(r) else return null;
        let ?descriptionCommit = r.blob() else return null;
        ?#collateralRegistered({ party; kind; valuation; descriptionCommit })
      };
      case 0x0E { let ?collateral = r.nat() else return null; let ?valuation = rValuation(r) else return null; ?#collateralRevalued({ collateral; valuation }) };
      case 0x0F {
        let ?collateral = r.nat() else return null;
        let ?facility = r.text() else return null;
        let ?amount = r.nat() else return null;
        ?#collateralAllocated({ collateral; facility; amount })
      };
      case 0x10 { let ?collateral = r.nat() else return null; ?#collateralReleased({ collateral }) };
      case 0x11 {
        let ?principal_ = r.principal() else return null;
        let ?book = r.text() else return null;
        let ?title = r.text() else return null;
        ?#staffAdded({ principal_; book; title })
      };
      case 0x12 { let ?principal_ = r.principal() else return null; ?#staffRemoved({ principal_ }) };
      case 0x13 { let ?f = rFormat(r) else return null; ?#accountFormatSet(f) };
      case 0x14 { let ?j = rJwks(r) else return null; ?#jwksPinned(j) };
      case 0x15 { let ?c = rCredential(r) else return null; ?#credentialRegistered(c) };
      case 0x16 { let ?subject = r.principal() else return null; ?#credentialRevoked({ subject }) };
      case 0x17 { let ?days = r.nat() else return null; ?#reviewGraceSet({ days }) };
      case _ null;
    }
  };

  /// A command under the current encoding.
  public func readCommand(r : C.Reader) : ?T.Command { readCommandAt(COMMAND_ENCODING, r) };

  public func readCommandAt(version : Nat8, r : C.Reader) : ?T.Command {
    switch (version) { case 1 readCommandBody(r, false); case 2 readCommandBody(r, true); case (_) null }
  };

  /// The Islamic-banking commands (Islamic banking): the extension tag 0xEF with a second byte; `null` when the second byte is
  /// not one of theirs, `?null` when the body is malformed.
  func readIslamicCommandBody(sub : Nat8, r : C.Reader) : ??T.Command {
    switch (sub) {
      case 0x01 { let ?p = ICan.readPolicy(r) else return ?null; ??#setIslamicPolicy(p) };
      case 0x02 { let ?product = r.text() else return ?null; let ?approval = ICan.readApproval(r) else return ?null; ??#approveShariaProduct({ product; approval }) };
      case 0x03 { let ?book = r.text() else return ?null; let ?sharia = r.bool() else return ?null; ??#flagShariaBook({ book; sharia }) };
      case 0x04 { let ?kind = ICan.readKind(r) else return ?null; let ?currency = r.text() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#openShariaContract({ kind; currency; postingDate; valueDate; period; narration }) };
      case 0x05 { let ?contract = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#acquireMurabahaAsset({ contract; postingDate; valueDate; period; narration }) };
      case 0x06 { let ?contract = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#sellMurabaha({ contract; postingDate; valueDate; period; narration }) };
      case 0x07 { let ?contract = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#collectInstalment({ contract; postingDate; valueDate; period; narration }) };
      case 0x08 { let ?contract = r.nat() else return ?null; let ?amount = r.nat() else return ?null; let ?reason = r.text() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#grantRebate({ contract; amount; reason; postingDate; valueDate; period; narration }) };
      case 0x09 { let ?contract = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#commenceIjarah({ contract; postingDate; valueDate; period; narration }) };
      case 0x0A { let ?contract = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#collectRental({ contract; postingDate; valueDate; period; narration }) };
      case 0x0B { let ?contract = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#transferIjarahOwnership({ contract; postingDate; valueDate; period; narration }) };
      case 0x0C { let ?contract = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#contributeCapital({ contract; postingDate; valueDate; period; narration }) };
      case 0x0D { let ?contract = r.nat() else return ?null; let ?profit = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#distributeMusharakahProfit({ contract; profit; postingDate; valueDate; period; narration }) };
      case 0x0E { let ?contract = r.nat() else return ?null; let ?loss = r.nat() else return ?null;
        let offered : ?[(Nat, Nat)] = switch (r.byte()) { case (?0) null; case (?1) { let ?n = r.len16() else return ?null; let o = List.empty<(Nat, Nat)>(); var i = 0; while (i < n) { let ?p = r.nat() else return ?null; let ?a = r.nat() else return ?null; List.add(o, (p, a)); i += 1 }; ?List.toArray(o) }; case (_) return ?null };
        let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#allocateMusharakahLoss({ contract; loss; offered; postingDate; valueDate; period; narration }) };
      case 0x0F { let ?contract = r.nat() else return ?null; let ?units = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#buyMusharakahUnit({ contract; units; postingDate; valueDate; period; narration }) };
      case 0x10 { let ?contract = r.nat() else return ?null; let ?profit = r.nat() else return ?null; let ?loss = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#recordMudarabahResult({ contract; profit; loss; postingDate; valueDate; period; narration }) };
      case 0x11 { let ?contract = r.nat() else return ?null; let ?quantity = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#deliverSalam({ contract; quantity; postingDate; valueDate; period; narration }) };
      case 0x12 { let ?contract = r.nat() else return ?null; let ?proceeds = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#sellSalamCommodity({ contract; proceeds; postingDate; valueDate; period; narration }) };
      case 0x13 { let ?contract = r.nat() else return ?null; let ?recourse = r.text() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#recordSalamFailure({ contract; recourse; postingDate; valueDate; period; narration }) };
      case 0x14 { let ?contract = r.nat() else return ?null; let ?certificate = r.blob() else return ?null; let ?percentBps = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#recordIstisnaMilestone({ contract; certificate; percentBps; postingDate; valueDate; period; narration }) };
      case 0x15 { let ?contract = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#collectIstisnaBilling({ contract; postingDate; valueDate; period; narration }) };
      case 0x16 { let ?contract = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#settleShariaContract({ contract; postingDate; valueDate; period; narration }) };
      case 0x17 { let ?contract = r.nat() else return ?null; let ?reason = r.text() else return ?null; ??#closeShariaContract({ contract; reason }) };
      case 0x18 { let ?contract = r.optNat() else return ?null; let ?amount = r.nat() else return ?null; let ?account = r.text() else return ?null; let ?reason = r.text() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#recordNonCompliance({ contract; amount; account; reason; postingDate; valueDate; period; narration }) };
      case 0x19 { let ?pool = ICan.readPool(r) else return ?null; ??#openInvestmentPool({ pool }) };
      case 0x1A { let ?pool = r.text() else return ?null; let ?per = r.optNat() else return ?null; let ?irr = r.optNat() else return ?null; ??#updatePoolReserves({ pool; per; irr }) };
      case 0x1B { let ?pool = r.text() else return ?null; let ?month = r.text() else return ?null; let ?from = r.nat() else return ?null; let ?to = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#distributePool({ pool; month; from; to; postingDate; valueDate; period; narration }) };
      case (_) null;
    }
  };

  /// The trade book's commands (trade finance), read apart from the main switch so that switch stays under the chain's
  /// function-complexity bound: `null` when the tag is not a trade command's, `?null` when the body is malformed.
  func readTradeCommand(tag : Nat8, r : C.Reader) : ??T.Command {
    switch (tag) {
      case 0x67 { let ?p = TrCan.readPolicy(r) else return ?null; ??#setTradePolicy(p) };
      case 0x68 { let ?lc = TrCan.readLc(r) else return ?null; let ?amount = r.nat() else return ?null; let ?currency = r.text() else return ?null; let ?expiry = r.nat() else return ?null; let ?placeOfExpiry = r.text() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#issueLetterOfCredit({ lc; amount; currency; expiry; placeOfExpiry; postingDate; valueDate; period; narration }) };
      case 0x69 {
        let ?message = r.text() else return ?null; let ?beneficiary = r.nat() else return ?null; let ?beneficiaryAccount = r.nat() else return ?null; let ?confirm = r.bool() else return ?null;
        let ?n = r.len16() else return ?null;
        let cl = List.empty<(TrT.DocumentKind, [Text])>();
        var i = 0;
        while (i < n) {
          let ?k = TrCan.readDocumentKind(r) else return ?null; let ?m = r.len16() else return ?null;
          let cs = List.empty<Text>(); var j = 0; while (j < m) { let ?c = r.text() else return ?null; List.add(cs, c); j += 1 };
          List.add(cl, (k, List.toArray(cs))); i += 1;
        };
        let ?commissionBps = r.nat() else return ?null; let ?facility = r.optNat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null;
        ??#adviseLetterOfCredit({ message; beneficiary; beneficiaryAccount; confirm; checklist = List.toArray(cl); commissionBps; facility; postingDate; valueDate; period; narration })
      };
      case 0x6A { let ?instrument = r.nat() else return ?null; let ?amendment = TrCan.readAmendment(r) else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#amendLetterOfCredit({ instrument; amendment; postingDate; valueDate; period; narration }) };
      case 0x6B { let ?instrument = r.nat() else return ?null; let ?documents = TrCan.readDocumentRefs(r) else return ?null; let ?amount = r.nat() else return ?null; let ?shipmentDate = r.optNat() else return ?null; let ?presentedOn = r.nat() else return ?null; ??#presentDocuments({ instrument; documents; amount; shipmentDate; presentedOn }) };
      case 0x6C { let ?instrument = r.nat() else return ?null; let ?claim = r.nat() else return ?null; let ?checks = TrCan.readChecks(r) else return ?null; let ?decision = TrCan.readDecision(r) else return ?null; ??#examinePresentation({ instrument; claim; checks; decision }) };
      case 0x6D { let ?instrument = r.nat() else return ?null; let ?claim = r.nat() else return ?null; let ?applicantConsentHash = r.blob() else return ?null; ??#waiveDiscrepancies({ instrument; claim; applicantConsentHash }) };
      case 0x6E { let ?instrument = r.nat() else return ?null; let ?claim = r.nat() else return ?null; let ?honour = TrCan.readHonour(r) else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#honourPresentation({ instrument; claim; honour; postingDate; valueDate; period; narration }) };
      case 0x6F { let ?instrument = r.nat() else return ?null; let ?claim = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#settleAcceptance({ instrument; claim; postingDate; valueDate; period; narration }) };
      case 0x8A { let ?instrument = r.nat() else return ?null; let ?reason = r.text() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#closeLetterOfCredit({ instrument; reason; postingDate; valueDate; period; narration }) };
      case 0x8B { let ?guarantee = TrCan.readGuarantee(r) else return ?null; let ?amount = r.nat() else return ?null; let ?currency = r.text() else return ?null; let ?expiry = r.nat() else return ?null; let ?wordingText = r.text() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#issueGuarantee({ guarantee; amount; currency; expiry; wordingText; postingDate; valueDate; period; narration }) };
      case 0x8C { let ?instrument = r.nat() else return ?null; let ?amendment = TrCan.readAmendment(r) else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#amendGuarantee({ instrument; amendment; postingDate; valueDate; period; narration }) };
      case 0x8D { let ?instrument = r.nat() else return ?null; let ?demand = TrCan.readDocumentRef(r) else return ?null; let ?amount = r.nat() else return ?null; let ?supportingStatement = r.bool() else return ?null; let ?presentedOn = r.nat() else return ?null; ??#recordDemand({ instrument; demand; amount; supportingStatement; presentedOn }) };
      case 0x8E {
        let ?instrument = r.nat() else return ?null; let ?claim = r.nat() else return ?null; let ?n = r.len16() else return ?null;
        let cl = List.empty<Text>(); var i = 0; while (i < n) { let ?c = r.text() else return ?null; List.add(cl, c); i += 1 };
        let ?checks = TrCan.readChecks(r) else return ?null; let ?decision = TrCan.readDecision(r) else return ?null;
        ??#examineDemand({ instrument; claim; checklist = List.toArray(cl); checks; decision })
      };
      case 0x8F { let ?instrument = r.nat() else return ?null; let ?claim = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#payDemand({ instrument; claim; postingDate; valueDate; period; narration }) };
      case 0xB8 { let ?instrument = r.nat() else return ?null; let ?to = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#reduceGuarantee({ instrument; to; postingDate; valueDate; period; narration }) };
      case 0xB9 { let ?instrument = r.nat() else return ?null; let ?reason = r.text() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#releaseGuarantee({ instrument; reason; postingDate; valueDate; period; narration }) };
      case 0xBA { let ?collection = TrCan.readCollection(r) else return ?null; let ?amount = r.nat() else return ?null; let ?currency = r.text() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#registerCollection({ collection; amount; currency; postingDate; valueDate; period; narration }) };
      case 0xBB { let ?instrument = r.nat() else return ?null; let ?presentedOn = r.nat() else return ?null; ??#presentCollection({ instrument; presentedOn }) };
      case 0xBC { let ?instrument = r.nat() else return ?null; ??#acceptCollection({ instrument }) };
      case 0xBD { let ?instrument = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#payCollection({ instrument; postingDate; valueDate; period; narration }) };
      case 0xBE { let ?instrument = r.nat() else return ?null; let ?reason = r.text() else return ?null; ??#protestCollection({ instrument; reason }) };
      case 0xBF { let ?instrument = r.nat() else return ?null; let ?reason = r.text() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#returnCollection({ instrument; reason; postingDate; valueDate; period; narration }) };
      case 0x1E { let ?bill = TrCan.readBill(r) else return ?null; let ?face = r.nat() else return ?null; let ?currency = r.text() else return ?null; let ?maturity = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#discountBill({ bill; face; currency; maturity; postingDate; valueDate; period; narration }) };
      case 0x1F { let ?instrument = r.nat() else return ?null; let ?to = r.text() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#rediscountBill({ instrument; to; postingDate; valueDate; period; narration }) };
      case 0x2D { let ?instrument = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#settleBill({ instrument; postingDate; valueDate; period; narration }) };
      case 0x2E { let ?instrument = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#dishonourBill({ instrument; postingDate; valueDate; period; narration }) };
      case 0x2F { let ?instrument = r.nat() else return ?null; let ?kind = TrCan.readMessageKind(r) else return ?null; let ?direction = TrCan.readDirection(r) else return ?null; let ?hash = r.blob() else return ?null; ??#recordTradeMessage({ instrument; kind; direction; hash }) };
      case (_) null;
    }
  };

  /// The treasury commands (treasury): the extension tag 0xEF with a second byte 0x20..; `null` when the second byte is
  /// not one of theirs, `?null` when the body is malformed.
  func readTreasuryCommand(sub : Nat8, r : C.Reader) : ??T.Command {
    switch (sub) {
      case 0x20 { let ?p = TyCan.readPolicy(r) else return ?null; ??#setTreasuryPolicy(p) };
      case 0x21 { let ?terms = TyCan.readSecurityTerms(r) else return ?null; ??#registerSecurity({ terms }) };
      case 0x22 { let ?curve = TyCan.readCurve(r) else return ?null; ??#publishCurve({ curve }) };
      case 0x23 { let ?limit = TyCan.readLimit(r) else return ?null; ??#setTreasuryLimit({ limit }) };
      case 0x24 { let ?nostro = TyCan.readNostro(r) else return ?null; ??#registerNostro({ nostro }) };
      case 0x25 { let ?book = r.text() else return ?null; let ?counterparty = TyCan.readCounterparty(r) else return ?null; let ?kind = TyCan.readKind(r) else return ?null; let ?reference = r.text() else return ?null; let ?approver = TyCan.readOptPrincipal(r) else return ?null; ??#captureDeal({ book; counterparty; kind; reference; approver }) };
      case 0x26 { let ?deal = r.nat() else return ?null; let ?confirmation = r.blob() else return ?null; let ?fields = TyCan.readOptFields(r) else return ?null; let ?document = r.optBlob() else return ?null; ??#confirmDeal({ deal; confirmation; fields; document }) };
      case 0x27 { let ?deal = r.nat() else return ?null; let ?kind = TyCan.readKind(r) else return ?null; let ?reason = r.text() else return ?null; ??#amendDeal({ deal; kind; reason }) };
      case 0x28 { let ?deal = r.nat() else return ?null; let ?reason = r.text() else return ?null; ??#cancelDeal({ deal; reason }) };
      case 0x29 { let ?deal = r.nat() else return ?null; let ?leg = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#settleDealLeg({ deal; leg; postingDate; valueDate; period; narration }) };
      case 0x2A { let ?deal = r.nat() else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#markDeal({ deal; postingDate; valueDate; period; narration }) };
      case 0x2B { let ?nostro = r.text() else return ?null; let ?statement = r.blob() else return ?null; let ?from = r.nat() else return ?null; let ?to = r.nat() else return ?null; let ?entries = TyCan.readEntries(r) else return ?null; let ?document = r.optBlob() else return ?null; ??#recordNostroStatement({ nostro; statement; from; to; entries; document }) };
      case 0x2C { let ?breakId = r.nat() else return ?null; let ?resolution = r.text() else return ?null; let ?correction = TyCan.readOptCorrection(r) else return ?null; let ?postingDate = r.nat() else return ?null; let ?valueDate = r.nat() else return ?null; let ?period = r.text() else return ?null; let ?narration = r.text() else return ?null; ??#resolveNostroBreak({ breakId; resolution; correction; postingDate; valueDate; period; narration }) };
      case (_) null;
    }
  };

  /// The card commands (cards): the extension tag 0xEF with a second byte 0x30..0x40.
  func readCurrencyCommand(sub : Nat8, r : C.Reader) : ??T.Command {
    switch (sub) {
      case 0x50 { let ?currency = r.text() else return ?null; let ?calendar = r.calendar() else return ?null; ??#setCurrencyCalendar({ currency; calendar }) };
      case 0x51 { let ?x = CC.rRedenomination(r) else return ?null; ??#redenominateCurrency(x) };
      case _ null;
    }
  };
  func readCardCommand(sub : Nat8, r : C.Reader) : ??T.Command {
    func dates() : ?(Nat, Nat, Text, Text) { let ?pd = r.nat() else return null; let ?vd = r.nat() else return null; let ?p = r.text() else return null; let ?n = r.text() else return null; ?(pd, vd, p, n) };
    switch (sub) {
      case 0x30 { let ?p = CdCan.readPolicy(r) else return ?null; ??#setCardPolicy(p) };
      case 0x31 { let ?scheme = CdCan.readScheme(r) else return ?null; ??#declareCardScheme({ scheme }) };
      case 0x32 { let ?product = CdCan.readProduct(r) else return ?null; ??#defineCardProduct({ product }) };
      case 0x33 { let ?token = r.blob() else return ?null; let ?account = r.nat() else return ?null; let ?product = r.text() else return ?null; let ?form = CdCan.readForm(r) else return ?null; let ?controls = CdCan.readControls(r) else return ?null; let ?(postingDate, valueDate, period, narration) = dates() else return ?null; ??#issueCard({ token; account; product; form; controls; postingDate; valueDate; period; narration }) };
      case 0x34 { let ?card = r.nat() else return ?null; ??#activateCard({ card }) };
      case 0x35 { let ?card = r.nat() else return ?null; let ?reason = CdCan.readBlockReason(r) else return ?null; ??#blockCard({ card; reason }) };
      case 0x36 { let ?card = r.nat() else return ?null; ??#unblockCard({ card }) };
      case 0x37 { let ?card = r.nat() else return ?null; let ?newToken = r.blob() else return ?null; let ?reason = CdCan.readReplaceReason(r) else return ?null; let ?(postingDate, valueDate, period, narration) = dates() else return ?null; ??#replaceCard({ card; newToken; reason; postingDate; valueDate; period; narration }) };
      case 0x38 { let ?card = r.nat() else return ?null; let ?reason = r.text() else return ?null; ??#closeCard({ card; reason }) };
      case 0x39 { let ?card = r.nat() else return ?null; let ?controls = CdCan.readControls(r) else return ?null; let ?byCustomer = r.bool() else return ?null; ??#setCardControls({ card; controls; byCustomer }) };
      case 0x3A { let ?transaction = r.nat() else return ?null; let ?reason = r.text() else return ?null; let ?amount = r.nat() else return ?null; ??#openDispute({ transaction; reason; amount }) };
      case 0x3B { let ?dispute = r.nat() else return ?null; let ?(postingDate, valueDate, period, narration) = dates() else return ?null; ??#grantProvisionalCredit({ dispute; postingDate; valueDate; period; narration }) };
      case 0x3C { let ?dispute = r.nat() else return ?null; let ?schemeRef = r.text() else return ?null; let ?(postingDate, valueDate, period, narration) = dates() else return ?null; ??#raiseChargeback({ dispute; schemeRef; postingDate; valueDate; period; narration }) };
      case 0x3D { let ?dispute = r.nat() else return ?null; let ?(postingDate, valueDate, period, narration) = dates() else return ?null; ??#recordRepresentment({ dispute; postingDate; valueDate; period; narration }) };
      case 0x3E { let ?dispute = r.nat() else return ?null; ??#recordPreArbitration({ dispute }) };
      case 0x3F { let ?dispute = r.nat() else return ?null; let ?outcome = CdCan.readOutcome(r) else return ?null; let ?finalAmount = r.nat() else return ?null; let ?(postingDate, valueDate, period, narration) = dates() else return ?null; ??#resolveDispute({ dispute; outcome; finalAmount; postingDate; valueDate; period; narration }) };
      case 0x40 { let ?transaction = r.nat() else return ?null; let ?blockCard = r.bool() else return ?null; ??#markFraud({ transaction; blockCard }) };
      case (_) null;
    }
  };

  func readCommandBody(r : C.Reader, withApplication : Bool) : ?T.Command {
    let ?tag = r.byte() else return null;
    switch (readTradeCommand(tag, r)) { case (?c) return c; case null {} };
    if (tag == 0xEF) {
      // the second byte selects the domain: 0x01.. Islamic banking, 0x20.. treasury
      let ?sub = r.byte() else return null;
      if (sub >= 0x50) { switch (readCurrencyCommand(sub, r)) { case (?c) return c; case null return null } };
      if (sub >= 0x30) { switch (readCardCommand(sub, r)) { case (?c) return c; case null return null } };
      if (sub >= 0x20) { switch (readTreasuryCommand(sub, r)) { case (?c) return c; case null return null } };
      switch (readIslamicCommandBody(sub, r)) { case (?c) return c; case null return null };
    };
    switch (tag) {
      case 0x01 { let ?id = r.text() else return null; let ?name = r.text() else return null; let ?permissions = rTexts(r) else return null; ?#defineRole({ id; name; permissions }) };
      case 0x02 { let ?subject = r.principal() else return null; let ?role = r.text() else return null; let ?scope = rScope(r) else return null; ?#grantRole({ subject; role; scope }) };
      case 0x03 { let ?subject = r.principal() else return null; let ?role = r.text() else return null; ?#revokeRole({ subject; role }) };
      case 0x04 { let ?p = rPolicy(r) else return null; ?#setDualPolicy(p) };
      case 0x05 { let ?permission = r.text() else return null; ?#clearDualPolicy({ permission }) };
      case 0x06 { let ?id = r.text() else return null; let ?name = r.text() else return null; let ?parent = rOptText(r) else return null; ?#openBook({ id; name; parent }) };
      case 0x07 { let ?id = r.text() else return null; ?#closeBook({ id }) };
      case 0x08 { let ?admin = r.principal() else return null; ?#transferBankAdmin({ admin }) };
      case 0x09 { let ?feature = r.text() else return null; let ?height = r.nat64() else return null; ?#setFeatureActivation({ feature; height }) };
      case 0x20 { let ?code = r.text() else return null; let ?minorUnits = r.nat8() else return null; ?#journalRegisterCurrency({ code; minorUnits }) };
      case 0x21 {
        let ?code = r.text() else return null; let ?name = r.text() else return null;
        let ?normalSide = r.side() else return null; let ?category = r.category() else return null;
        let ?constraint = r.constraint() else return null;
        ?#journalOpenAccount({ code; name; normalSide; category; constraint })
      };
      case 0x22 { let ?code = r.text() else return null; ?#journalCloseAccount({ code }) };
      case 0x23 { let ?id = r.text() else return null; let ?start = r.nat() else return null; let ?end = r.nat() else return null; ?#journalOpenPeriod({ id; start; end }) };
      case 0x24 { let ?id = r.text() else return null; ?#journalClosePeriod({ id }) };
      case 0x25 { let ?height = r.nat64() else return null; ?#journalSetActivationHeight({ height }) };
      case 0x26 {
        let ?n = r.len16() else return null;
        let out = List.empty<JT.LeadsheetRange>();
        var i = 0;
        while (i < n) { let ?x = r.range() else return null; List.add(out, x); i += 1 };
        ?#journalSetLeadsheetSchema({ ranges = List.toArray(out) })
      };
      case 0x27 { let ?poster = r.principal() else return null; ?#journalAddPoster({ poster }) };
      case 0x28 { let ?poster = r.principal() else return null; ?#journalRemovePoster({ poster }) };
      case 0x29 { let ?poster = r.principal() else return null; let ?accounts = rOptTexts(r) else return null; ?#journalSetPosterScope({ poster; accounts }) };
      case 0x2A { let ?day = r.nat() else return null; ?#journalRollBusinessDate({ day }) };
      case 0x2B { let ?calendar = r.calendar() else return null; ?#journalSetCalendar({ calendar }) };
      case 0x2C {
        let ?authority = r.calendarAuthority() else return null; let ?maxRollDays = r.nat() else return null; let ?businessDate = r.optNat() else return null;
        ?#journalSetCalendarAuthority({ authority; maxRollDays; businessDate })
      };
      case 0x40 { let ?m = rManualEntry(r) else return null; ?#postManualEntry(m) };
      case 0x41 {
        let ?original = r.nat() else return null; let ?book = r.text() else return null;
        let ?postingDate = r.nat() else return null; let ?valueDate = r.nat() else return null;
        let ?period = r.text() else return null; let ?narration = r.text() else return null;
        let ?idempotencyKey = r.blob() else return null;
        ?#reverseManualEntry({ original; book; postingDate; valueDate; period; narration; idempotencyKey })
      };
      case 0x42 { let ?party = r.nat() else return null; let ?e = rManualEntry(r) else return null; ?#postManualEntryForParty({ party; entry = e }) };
      case 0x50 {
        let ?kind = rPartyKind(r) else return null;
        let ?salt = r.blob() else return null;
        let ?identityCommit = r.blob() else return null;
        let ?dedupCommit = rOptCommit(r) else return null;
        let ?attributes = rFields(r) else return null;
        let ?book = r.text() else return null;
        let ?cddLevel = rCdd(r) else return null;
        let ?riskRating = rRisk(r) else return null;
        let ?pep = r.bool() else return null;
        let ?reviewDue = r.nat() else return null;
        ?#createParty({ kind; salt; identityCommit; dedupCommit; attributes; book; cddLevel; riskRating; pep; reviewDue })
      };
      case 0x19 {
        let ?kind = rPartyKind(r) else return null;
        let ?salt = r.blob() else return null;
        let ?identityCommit = r.blob() else return null;
        let ?dedupCommit = rOptCommit(r) else return null;
        let ?attributes = rFields(r) else return null;
        let ?book = r.text() else return null;
        let ?cddLevel = rCdd(r) else return null;
        let ?riskRating = rRisk(r) else return null;
        let ?pep = r.bool() else return null;
        let ?reviewDue = r.nat() else return null;
        let ?nd = r.len16() else return null;
        let docs = List.empty<PT.DocumentRef>();
        var i = 0;
        while (i < nd) { let ?d = rDocument(r) else return null; List.add(docs, d); i += 1 };
        let screening : ?T.CustomerScreening = switch (r.byte()) {
          case (?0) null;
          case (?1) {
            let ?listVersion = r.text() else return null;
            let ?listRoot = r.blob() else return null;
            let decision = switch (r.byte()) {
              case (?0) #clear;
              case (?1) { let ?m = r.nat() else return null; #hit({ matches = m }) };
              case (?2) { let ?t = r.text() else return null; #cleared({ reason = t }) };
              case (?3) #confirmed;
              case _ return null;
            };
            let ?screener = r.principal() else return null;
            let ?justificationCommit = r.blob() else return null;
            ?{ listVersion; listRoot; decision; screener; justificationCommit }
          };
          case _ return null;
        };
        let ?lifecycle = rLifecycle(r) else return null;
        let ?extensions = rExtensionValues(r) else return null;
        let ?na = r.len16() else return null;
        let accounts = List.empty<T.CustomerAccount>();
        i := 0;
        while (i < na) {
          let ?product = r.text() else return null;
          let ?currency = r.text() else return null;
          let ?termDays = r.optNat() else return null;
          let ?allocationOrder = PC.rComponents(r) else return null;
          let ?activate = r.bool() else return null;
          List.add(accounts, { product; currency; termDays; allocationOrder; activate });
          i += 1;
        };
        let application : ?Nat = if (withApplication) { let ?a = r.optNat() else return null; a } else null;
        ?#createCustomer({ party = { kind; salt; identityCommit; dedupCommit; attributes; book; cddLevel; riskRating; pep; reviewDue }; documents = List.toArray(docs); screening; lifecycle; extensions; accounts = List.toArray(accounts); application })
      };
      case 0x51 { let ?party = r.nat() else return null; let ?attributes = rFields(r) else return null; ?#amendParty({ party; attributes }) };
      case 0x52 { let ?party = r.nat() else return null; let ?to = rLifecycle(r) else return null; ?#setPartyLifecycle({ party; to }) };
      case 0x53 {
        let ?party = r.nat() else return null;
        let ?level = rCdd(r) else return null;
        let ?riskRating = rRisk(r) else return null;
        let ?pep = r.bool() else return null;
        let ?reviewDue = r.nat() else return null;
        ?#setPartyCdd({ party; level; riskRating; pep; reviewDue })
      };
      case 0x54 { let ?party = r.nat() else return null; let ?d = rDocument(r) else return null; ?#addPartyDocument({ party; document = d }) };
      case 0x55 { let ?party = r.nat() else return null; let ?rel = rRelationship(r) else return null; ?#addPartyRelationship({ party; relationship = rel }) };
      case 0x56 { let ?party = r.nat() else return null; let ?values = rExtensionValues(r) else return null; ?#setPartyExtension({ party; values }) };
      case 0x57 { let ?party = r.nat() else return null; ?#issueIdentifier({ party }) };
      case 0x58 {
        let ?version = r.text() else return null;
        let ?root = r.blob() else return null;
        let ?count = r.nat() else return null;
        let ?normalisation = r.text() else return null;
        ?#commitScreeningList({ version; root; count; normalisation })
      };
      case 0x59 {
        let ?party = r.nat() else return null;
        let ?listVersion = r.text() else return null;
        let ?subject = r.blob() else return null;
        let ?proof = rAdjacency(r) else return null;
        ?#proveScreeningClear({ party; listVersion; subject; proof })
      };
      case 0x5A { let ?d = rScreeningDecision(r) else return null; ?#recordScreeningDecision(d) };
      case 0x5B {
        let ?id = r.text() else return null;
        let ?entity = rEntityKind(r) else return null;
        let ?fields = rFieldDefs(r) else return null;
        ?#registerSchema({ id; entity; fields })
      };
      case 0x5C {
        let ?party = r.nat() else return null;
        let ?kind = rCollateralKind(r) else return null;
        let ?valuation = rValuation(r) else return null;
        let ?descriptionCommit = r.blob() else return null;
        ?#registerCollateral({ party; kind; valuation; descriptionCommit })
      };
      case 0x5D { let ?collateral = r.nat() else return null; let ?valuation = rValuation(r) else return null; ?#revalueCollateral({ collateral; valuation }) };
      case 0x5E {
        let ?collateral = r.nat() else return null;
        let ?facility = r.text() else return null;
        let ?amount = r.nat() else return null;
        ?#allocateCollateral({ collateral; facility; amount })
      };
      case 0x5F { let ?collateral = r.nat() else return null; ?#releaseCollateral({ collateral }) };
      case 0x60 {
        let ?principal_ = r.principal() else return null;
        let ?book = r.text() else return null;
        let ?title = r.text() else return null;
        ?#addStaff({ principal_; book; title })
      };
      case 0x61 { let ?principal_ = r.principal() else return null; ?#removeStaff({ principal_ }) };
      case 0x62 { let ?f = rFormat(r) else return null; ?#setAccountFormat(f) };
      case 0x63 { let ?days = r.nat() else return null; ?#setReviewGrace({ days }) };
      case 0x64 { let ?j = rJwks(r) else return null; ?#pinJwks(j) };
      case 0x65 { let ?c = rCredential(r) else return null; ?#registerCredential(c) };
      case 0x66 { let ?subject = r.principal() else return null; ?#revokeCredential({ subject }) };
      // ── the product engine ──
      case 0x70 {
        let ?id = r.text() else return null;
        let ?name = r.text() else return null;
        let ?terms = PC.rTerms(r) else return null;
        ?#registerProduct({ id; name; terms })
      };
      case 0x71 {
        let ?id = r.text() else return null;
        let ?name = r.text() else return null;
        let ?terms = PC.rTerms(r) else return null;
        ?#amendProduct({ id; name; terms })
      };
      case 0x72 {
        let ?id = r.text() else return null;
        let ?version = r.nat() else return null;
        ?#closeProductToNewAccounts({ id; version })
      };
      case 0x73 {
        let ?product = r.text() else return null;
        let ?party = r.nat() else return null;
        let ?currency = r.text() else return null;
        let ?termDays = r.optNat() else return null;
        let ?allocationOrder = PC.rComponents(r) else return null;
        ?#openAccount({ product; party; currency; termDays; allocationOrder })
      };
      case 0x74 {
        let ?account = r.nat() else return null;
        let ?to = PC.rStatus(r) else return null;
        ?#setAccountStatus({ account; to })
      };
      case 0x75 {
        let ?account = r.nat() else return null;
        let ?to = r.nat() else return null;
        ?#migrateAccount({ account; to })
      };
      case 0x76 {
        let ?till = r.text() else return null;
        let ?book = r.text() else return null;
        let ?currency = r.text() else return null;
        let ?holder = r.principal() else return null;
        let ?product = r.text() else return null;
        ?#openTill({ till; book; currency; holder; product })
      };
      case 0x77 { let ?till = r.text() else return null; ?#closeTill({ till }) };
      case 0x78 {
        let ?account = r.nat() else return null;
        let ?limit = r.nat() else return null;
        ?#grantFacility({ account; limit })
      };
      case 0x79 { let ?m = rMoneyMove(r) else return null; ?#depositToAccount(m) };
      case 0x7A { let ?m = rMoneyMove(r) else return null; ?#withdrawFromAccount(m) };
      case 0x7B {
        let ?from = r.nat() else return null;
        let ?to = r.nat() else return null;
        let ?amount = r.nat() else return null;
        let ?postingDate = r.nat() else return null;
        let ?valueDate = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?narration = r.text() else return null;
        ?#transferBetweenAccounts({ from; to; amount; postingDate; valueDate; period; narration })
      };
      case 0x7C {
        let ?account = r.nat() else return null;
        let ?charge = r.text() else return null;
        let ?occurrence = r.nat() else return null;
        let ?base = PC.rChargeBase(r) else return null;
        let ?postingDate = r.nat() else return null;
        let ?valueDate = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?narration = r.text() else return null;
        ?#applyCharge({ account; charge; occurrence; base; postingDate; valueDate; period; narration })
      };
      case 0x7D {
        let ?account = r.nat() else return null;
        let ?charge = r.text() else return null;
        let ?occurrence = r.nat() else return null;
        let ?postingDate = r.nat() else return null;
        let ?valueDate = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?reason = r.text() else return null;
        ?#waiveCharge({ account; charge; occurrence; postingDate; valueDate; period; reason })
      };
      case 0x7E {
        let ?product = r.text() else return null;
        let ?currency = r.text() else return null;
        let ?day = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?narration = r.text() else return null;
        ?#postAccrual({ product; currency; day; period; narration })
      };
      case 0x7F {
        let ?product = r.text() else return null;
        let ?currency = r.text() else return null;
        let ?to = r.nat() else return null;
        let ?postingDate = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?narration = r.text() else return null;
        ?#capitaliseInterest({ product; currency; to; postingDate; period; narration })
      };
      case 0x80 { let ?m = rMoneyMove(r) else return null; ?#disburseLoan(m) };
      case 0x81 { let ?m = rMoneyMove(r) else return null; ?#repayLoan(m) };
      case 0x82 {
        let ?account = r.nat() else return null;
        let ?effective = r.nat() else return null;
        let ?terms = PC.rSchedule(r) else return null;
        let ?rate = PC.rRate(r) else return null;
        ?#rescheduleLoan({ account; effective; terms; rate })
      };
      case 0x83 {
        let ?account = r.nat() else return null;
        let ?asOf = r.nat() else return null;
        let ?postingDate = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?narration = r.text() else return null;
        ?#setProvision({ account; asOf; postingDate; period; narration })
      };
      case 0x84 {
        let ?account = r.nat() else return null;
        let ?postingDate = r.nat() else return null;
        let ?valueDate = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?narration = r.text() else return null;
        ?#writeOffLoan({ account; postingDate; valueDate; period; narration })
      };
      case 0x85 { let ?m = rMoneyMove(r) else return null; ?#recordRecovery(m) };
      case 0x86 { let ?m = rMoneyMove(r) else return null; ?#redeemTermDeposit(m) };
      case 0x87 {
        let ?till = r.text() else return null;
        let ?amount = r.nat() else return null;
        let ?postingDate = r.nat() else return null;
        let ?valueDate = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?narration = r.text() else return null;
        ?#allocateCashToTill({ till; amount; postingDate; valueDate; period; narration })
      };
      case 0x88 {
        let ?till = r.text() else return null;
        let ?amount = r.nat() else return null;
        let ?postingDate = r.nat() else return null;
        let ?valueDate = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?narration = r.text() else return null;
        ?#returnCashFromTill({ till; amount; postingDate; valueDate; period; narration })
      };
      case 0x89 {
        let ?till = r.text() else return null;
        let ?declared = r.nat() else return null;
        let ?postingDate = r.nat() else return null;
        let ?valueDate = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?narration = r.text() else return null;
        ?#settleTill({ till; declared; postingDate; valueDate; period; narration })
      };
      // ── value dating, foreign currency and the close ──
      case 0x90 { let ?c = r.text() else return null; ?#setFunctionalCurrency({ currency = c }) };
      case 0x91 { let ?p = CC.rPair(r) else return null; ?#setFxPair({ pair = p }) };
      case 0x92 { let ?x = CC.rRate(r) else return null; ?#setFxRate({ rate = x }) };
      case 0x93 { let ?x = CC.rWindow(r) else return null; ?#setBackValueWindow({ window = x }) };
      case 0x94 {
        let ?book = r.text() else return null;
        let ?valueDate = r.nat() else return null;
        let ?reason = r.text() else return null;
        ?#approveBackValue({ book; valueDate; reason })
      };
      case 0x95 { let ?x = CC.rSchedule(r) else return null; ?#openDeferralSchedule({ schedule = x }) };
      case 0x96 {
        let ?sell = r.text() else return null;
        let ?sellAmount = r.nat() else return null;
        let ?sellFrom = rEndpoint(r) else return null;
        let ?buy = r.text() else return null;
        let ?buyAmount = r.nat() else return null;
        let ?buyTo = rEndpoint(r) else return null;
        let ?rateAsOf = r.nat() else return null;
        let ?postingDate = r.nat() else return null;
        let ?valueDate = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?narration = r.text() else return null;
        ?#bookFxDeal({ sell; sellAmount; sellFrom; buy; buyAmount; buyTo; rateAsOf; postingDate; valueDate; period; narration })
      };
      case 0x97 {
        let ?currency = r.text() else return null;
        let ?closedPosition = r.nat() else return null;
        let ?bookedEquivalent = r.nat() else return null;
        let ?proceeds = r.nat() else return null;
        let ?postingDate = r.nat() else return null;
        let ?valueDate = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?narration = r.text() else return null;
        ?#realiseFxPosition({ currency; closedPosition; bookedEquivalent; proceeds; postingDate; valueDate; period; narration })
      };
      case 0x98 {
        let ?product = r.text() else return null;
        let ?currency = r.text() else return null;
        let ?from = r.nat() else return null;
        let ?to = r.nat() else return null;
        let ?causedBy = r.nat() else return null;
        let ?postingDate = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?narration = r.text() else return null;
        ?#adjustAccrual({ product; currency; from; to; causedBy; postingDate; period; narration })
      };
      case 0x99 {
        let ?schedule = r.text() else return null;
        let ?postingDate = r.nat() else return null;
        let ?valueDate = r.nat() else return null;
        let ?period = r.text() else return null;
        let ?narration = r.text() else return null;
        ?#amortiseDeferral({ schedule; postingDate; valueDate; period; narration })
      };
      case 0x9A { let ?b = r.text() else return null; let ?p = r.text() else return null; ?#openPeriodEnd({ book = b; period = p }) };
      case 0x9B { let ?b = r.text() else return null; let ?p = r.text() else return null; ?#recordClosingRates({ book = b; period = p }) };
      case 0x9C { let ?b = r.text() else return null; let ?p = r.text() else return null; ?#markAccrualComplete({ book = b; period = p }) };
      case 0x9D {
        let ?b = r.text() else return null;
        let ?p = r.text() else return null;
        let ?postingDate = r.nat() else return null;
        let ?narration = r.text() else return null;
        ?#revaluePositions({ book = b; period = p; postingDate; narration })
      };
      case 0x9E {
        let ?b = r.text() else return null;
        let ?p = r.text() else return null;
        let ?postingDate = r.nat() else return null;
        let ?narration = r.text() else return null;
        ?#amortisePeriodDeferrals({ book = b; period = p; postingDate; narration })
      };
      case 0x9F { let ?b = r.text() else return null; let ?p = r.text() else return null; ?#reconcilePeriod({ book = b; period = p }) };
      case 0xA0 { let ?b = r.text() else return null; let ?p = r.text() else return null; ?#closePeriodEnd({ book = b; period = p }) };
      case 0xA1 {
        let ?b = r.text() else return null;
        let ?p = r.text() else return null;
        let ?re = r.text() else return null;
        let ?n = r.text() else return null;
        ?#rollYearEnd({ book = b; period = p; retainedEarnings = re; narration = n })
      };
      case 0xB0 {
        let ?b = r.text() else return null;
        let ?limit = r.nat() else return null;
        ?#setRetryPolicy({ policy = { book = b; limit } })
      };
      case 0xB1 { let ?si = BC.rInstruction(r) else return null; ?#defineStandingInstruction({ instruction = si }) };
      case 0xB2 { let ?id = r.text() else return null; ?#cancelStandingInstruction({ id }) };
      case 0xB3 {
        let ?b = r.text() else return null;
        let ?d = r.nat() else return null;
        let ?shardSize = r.nat() else return null;
        ?#openEndOfDay({ book = b; businessDate = d; shardSize })
      };
      case 0xB4 {
        let ?b = r.text() else return null;
        let ?d = r.nat() else return null;
        let ?item = r.nat() else return null;
        let ?entity = r.text() else return null;
        let ?justification = r.text() else return null;
        ?#resolveBatchFailure({ book = b; businessDate = d; item; entity; justification })
      };
      case 0xC0 { let ?d = RC.rDef(r) else return null; ?#registerReportDefinition({ definition = d }) };
      case 0xC1 { let ?t = RC.rTemplate(r) else return null; ?#registerReturnTemplate({ template = t }) };
      case 0xC2 {
        let ?b = r.text() else return null;
        let ?m = rStatementMap(r) else return null;
        ?#setStatementMap({ book = b; map = m })
      };
      case 0xC3 {
        let ?def = r.text() else return null;
        let ?version = r.nat() else return null;
        let ?b = r.text() else return null;
        let ?p = r.text() else return null;
        let ?vtag = r.byte() else return null;
        let view : RepT.CurrencyView = switch (vtag) { case (0) #native; case (1) #functional; case (_) return null };
        let functional = switch (r.byte()) {
          case (?0) null;
          case (?1) { let ?c = r.text() else return null; ?c };
          case (_) return null;
        };
        ?#certifyReport({ definition = def; version; book = b; period = p; view; functional })
      };
      case 0xC4 {
        let ?t = r.text() else return null;
        let ?version = r.nat() else return null;
        let ?b = r.text() else return null;
        let ?p = r.text() else return null;
        ?#certifyReturn({ template = t; version; book = b; period = p })
      };
      case 0xC5 {
        let ?stag = r.byte() else return null;
        let shape : RepT.ExportShape = switch (stag) { case (1) #safT; case (2) #aicpaAds; case (3) #normalisedTrialBalance; case (_) return null };
        let ?b = r.text() else return null;
        let ?p = r.text() else return null;
        ?#certifyExport({ shape; book = b; period = p })
      };
      case 0xC6 {
        let ?account = r.nat() else return null;
        let ?ktag = r.byte() else return null;
        let kind : RepT.StatementKind = switch (ktag) {
          case (0x53) { let ?d = r.nat() else return null; #camt053({ cut = d }) };
          case (0x52) { let ?d = r.nat() else return null; #camt052({ asOf = d }) };
          case (0x54) { let ?d = r.nat() else return null; #camt054({ movement = d }) };
          case (_) return null;
        };
        let ?p = r.text() else return null;
        ?#issueStatement({ account; kind; period = p })
      };
      case 0xC7 {
        let ?url = r.text() else return null;
        let ?n = r.len16() else return null;
        let retries = List.empty<Nat>();
        var i = 0;
        while (i < n) { let ?x = r.nat() else return null; List.add(retries, x); i += 1 };
        let ?a = r.byte() else return null;
        ?#setFeedEndpoint({ endpoint = { url; retries = List.toArray(retries); active = a == 1 } })
      };
      case 0xC8 {
        let ?cursor = r.nat() else return null;
        let ?endpoint = r.text() else return null;
        let ?attempts = r.nat() else return null;
        let ?reason = r.text() else return null;
        ?#recordFeedDeadLetter({ letter = { cursor; endpoint; attempts; reason } })
      };
      case 0xC9 {
        let ?present = r.byte() else return null;
        if (present == 0) return ?#setCounterpartyClassDimension({ dimension = null });
        let ?schema = r.text() else return null;
        let ?field = r.text() else return null;
        ?#setCounterpartyClassDimension({ dimension = ?{ schema; field } })
      };
      case 0xCA { let ?sha256 = r.blob() else return null; let ?bytes = r.nat() else return null; let ?name = r.text() else return null; ?#pinArchiveImage({ sha256; bytes; name }) };
      case 0xCB { let ?controllers = rPrincipals(r) else return null; ?#setArchiveControllers({ controllers }) };
      case 0xCC { let ?purpose = r.text() else return null; ?#spawnArchive({ purpose }) };
      case 0xCD { let ?spawn = r.nat() else return null; let ?reason = r.text() else return null; ?#abandonArchiveSpawn({ spawn; reason }) };
      case 0xCE { let ?spawn = r.nat() else return null; let ?cid = r.nat64() else return null; ?#attachArchiveChild({ spawn; cid }) };
      case 0xCF {
        let ?cid = r.nat64() else return null; let ?moduleHash = r.blob() else return null;
        let ?controllers = rPrincipals(r) else return null; let ?purpose = r.text() else return null;
        ?#adoptArchiveChild({ cid; moduleHash; controllers; purpose })
      };
      case 0xD0 {
        let ?id = r.text() else return null; let ?currency = rOptTextM(r) else return null; let ?spec = readRuleSpec(r) else return null;
        ?#defineMonitoringRule({ id; currency; spec })
      };
      case 0xD1 { let ?id = r.text() else return null; ?#retireMonitoringRule({ id }) };
      case 0xD2 { let ?alert = r.nat() else return null; let ?reason = r.text() else return null; ?#clearAlert({ alert; reason }) };
      case 0xA2 { let ?p = OCan.readPolicy(r) else return null; ?#setOriginationPolicy(p) };
      case 0xA3 { let ?m = OCan.readAffordabilityModel(r) else return null; ?#setAffordabilityModel(m) };
      case 0xA4 { let ?c = OCan.readScorecard(r) else return null; ?#setScorecard(c) };
      case 0xA5 { let ?party = r.nat() else return null; let ?credentialId = r.blob() else return null; let ?publicKeySpki = r.blob() else return null; ?#registerPasskey({ party; credentialId; publicKeySpki }) };
      case 0xA6 {
        let ?party = r.optNat() else return null; let ?book = r.text() else return null; let ?request = OCan.readRequest(r) else return null; let ?channel = r.text() else return null;
        ?#openApplication({ party; book; request; channel })
      };
      case 0xA7 { let ?application = r.nat() else return null; let ?facts = OCan.readFacts(r) else return null; let ?commitments = OCan.readCommitments(r) else return null; ?#recordApplicationData({ application; facts; commitments }) };
      case 0xA8 { let ?application = r.nat() else return null; ?#assessAffordability({ application }) };
      case 0xA9 { let ?application = r.nat() else return null; let ?bureau = r.text() else return null; let ?consentCommit = r.blob() else return null; ?#requestBureauReport({ application; bureau; consentCommit }) };
      case 0xAA { let ?application = r.nat() else return null; ?#scoreApplication({ application }) };
      case 0xAB { let ?application = r.nat() else return null; let ?decision = OCan.readDecision(r) else return null; let ?rationale = r.text() else return null; ?#underwrite({ application; decision; rationale }) };
      case 0xAC { let ?application = r.nat() else return null; let ?terms = OCan.readTerms(r) else return null; ?#issueOffer({ application; terms }) };
      case 0xAD { let ?application = r.nat() else return null; let ?assertion = OCan.readAssertion(r) else return null; ?#acceptOffer({ application; assertion }) };
      case 0xAE { let ?application = r.nat() else return null; ?#declineOffer({ application }) };
      case 0xAF {
        let ?application = r.nat() else return null; let ?kind = OCan.readKind(r) else return null; let ?sha256 = r.blob() else return null; let ?signed = OCan.readOptAssertion(r) else return null;
        ?#recordDocument({ application; kind; sha256; signed })
      };
      case 0xB5 { let ?application = r.nat() else return null; let ?conditions = rTexts(r) else return null; ?#recordConditionsMet({ application; conditions }) };
      case 0xB6 { let ?application = r.nat() else return null; ?#fulfilApplication({ application }) };
      case 0xB7 { let ?application = r.nat() else return null; let ?reason = r.text() else return null; ?#withdrawApplication({ application; reason }) };
      case 0x30 { let ?t = FCan.readTerms(r) else return null; ?#openFacility(t) };
      case 0x31 { let ?m = rFacilityMoney(r) else return null; ?#drawdown(m) };
      case 0x32 { let ?facility = r.nat() else return null; let ?from = r.nat() else return null; let ?to = r.nat() else return null; let ?bps = r.nat() else return null; ?#transferParticipation({ facility; from; to; bps }) };
      case 0x33 {
        let ?facility = r.nat() else return null; let ?funding = PC.rFunding(r) else return null; let ?d = rDates(r) else return null;
        ?#distributeToParticipants({ facility; funding; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration })
      };
      case 0x34 { let ?facility = r.nat() else return null; let ?effective = r.nat() else return null; let ?terms = FCan.readRestructure(r) else return null; ?#restructureFacility({ facility; effective; terms }) };
      case 0x35 { let ?facility = r.nat() else return null; let ?covenant = r.text() else return null; let ?value = r.nat() else return null; let ?statementHash = r.blob() else return null; ?#recordCovenantTest({ facility; covenant; value; statementHash }) };
      case 0x36 { let ?facility = r.nat() else return null; let ?reason = r.text() else return null; ?#blockDrawdowns({ facility; reason }) };
      case 0x37 { let ?facility = r.nat() else return null; let ?reason = r.text() else return null; ?#unblockDrawdowns({ facility; reason }) };
      case 0x38 { let ?facility = r.nat() else return null; let ?note = r.text() else return null; ?#recordFacilityReview({ facility; note }) };
      case 0x39 { let ?index = r.text() else return null; let ?day = r.nat() else return null; let ?rateBps = r.nat() else return null; ?#recordRateFixing({ index; day; rateBps }) };
      case 0x3A { let ?m = rFacilityMoney(r) else return null; ?#receiveRental(m) };
      case 0x3B {
        let ?facility = r.nat() else return null; let ?residual = r.nat() else return null; let ?d = rDates(r) else return null;
        ?#remeasureResidual({ facility; residual; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration })
      };
      case 0x3C {
        let ?facility = r.nat() else return null; let ?receivables = FCan.readReceivables(r) else return null; let ?d = rDates(r) else return null;
        ?#purchaseReceivables({ facility; receivables; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration })
      };
      case 0x3D {
        let ?facility = r.nat() else return null; let ?ref = r.blob() else return null; let ?funding = PC.rFunding(r) else return null; let ?d = rDates(r) else return null;
        ?#collectReceivable({ facility; ref; funding; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration })
      };
      case 0x3E {
        let ?facility = r.nat() else return null; let ?ref = r.blob() else return null; let ?d = rDates(r) else return null;
        ?#dishonourReceivable({ facility; ref; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration })
      };
      case 0x3F {
        let ?facility = r.nat() else return null; let ?ref = r.blob() else return null; let ?d = rDates(r) else return null;
        ?#writeOffReceivable({ facility; ref; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration })
      };
      case 0x43 { let ?facility = r.nat() else return null; ?#closeFacility({ facility }) };
      case 0xF6 { let ?p = TCan.readPolicy(r) else return null; ?#setTellerPolicy(p) };
      case 0xF7 { let ?till = r.text() else return null; let ?teller = r.principal() else return null; let ?opening = TCan.readDenominations(r) else return null; ?#openTellerSession({ till; teller; opening }) };
      case 0xF8 { let ?till = r.text() else return null; let ?closing = TCan.readDenominations(r) else return null; ?#closeTellerSession({ till; closing }) };
      case 0xF9 { let ?session = r.nat() else return null; let ?note = r.text() else return null; let ?d = rDates(r) else return null; ?#resolveTillDifference({ session; note; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration }) };
      case 0xFA {
        let ?till = r.text() else return null; let ?account = r.nat() else return null; let ?amount = r.nat() else return null;
        let ?tendered = TCan.readDenominations(r) else return null; let ?change = TCan.readDenominations(r) else return null; let ?d = rDates(r) else return null;
        ?#cashDeposit({ till; account; amount; tendered; change; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration })
      };
      case 0xFB {
        let ?till = r.text() else return null; let ?account = r.nat() else return null; let ?amount = r.nat() else return null; let ?paid = TCan.readDenominations(r) else return null; let ?d = rDates(r) else return null;
        ?#cashWithdrawal({ till; account; amount; paid; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration })
      };
      case 0xFC { let ?till = r.text() else return null; let ?amount = r.nat() else return null; let ?denominations = TCan.readDenominations(r) else return null; let ?d = rDates(r) else return null; ?#vaultToTill({ till; amount; denominations; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration }) };
      case 0xFD { let ?till = r.text() else return null; let ?amount = r.nat() else return null; let ?denominations = TCan.readDenominations(r) else return null; let ?d = rDates(r) else return null; ?#tillToVault({ till; amount; denominations; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration }) };
      case 0xFE {
        let ?product = r.text() else return null; let ?fromBook = r.text() else return null; let ?toBook = r.text() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null;
        let ?denominations = TCan.readDenominations(r) else return null; let ?carrier = r.text() else return null; let ?sealBag = r.text() else return null; let ?d = rDates(r) else return null;
        ?#dispatchCash({ product; fromBook; toBook; currency; amount; denominations; carrier; sealBag; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration })
      };
      case 0xFF { let ?movement = r.nat() else return null; let ?denominations = TCan.readDenominations(r) else return null; let ?d = rDates(r) else return null; ?#receiveCash({ movement; denominations; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration }) };
      case 0x13 {
        let ?product = r.text() else return null; let ?book = r.text() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?denominations = TCan.readDenominations(r) else return null; let ?d = rDates(r) else return null;
        ?#vaultToCentralBank({ product; book; currency; amount; denominations; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration })
      };
      case 0x14 {
        let ?product = r.text() else return null; let ?book = r.text() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?denominations = TCan.readDenominations(r) else return null; let ?d = rDates(r) else return null;
        ?#centralBankToVault({ product; book; currency; amount; denominations; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration })
      };
      case 0x15 { let ?account = r.nat() else return null; let ?from = r.nat() else return null; let ?to = r.nat() else return null; ?#issueChequebook({ account; from; to }) };
      case 0x16 { let ?account = r.nat() else return null; let ?serial = r.nat() else return null; let ?reason = r.text() else return null; ?#stopCheque({ account; serial; reason }) };
      case 0x17 {
        let ?account = r.nat() else return null; let ?serial = r.nat() else return null; let ?amount = r.nat() else return null; let ?payee = TCan.readPayee(r) else return null;
        let ?chequeDate = r.nat() else return null; let ?imageHash = r.blob() else return null; let ?d = rDates(r) else return null;
        ?#presentCheque({ account; serial; amount; payee; chequeDate; imageHash; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration })
      };
      case 0x18 { let ?account = r.nat() else return null; let ?serial = r.nat() else return null; let ?d = rDates(r) else return null; ?#clearCheque({ account; serial; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration }) };
      case 0x1A { let ?account = r.nat() else return null; let ?serial = r.nat() else return null; let ?reason = TCan.readReason(r) else return null; let ?d = rDates(r) else return null; ?#returnCheque({ account; serial; reason; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration }) };
      case 0x1B {
        let ?serial = r.text() else return null; let ?payeeCommit = r.blob() else return null; let ?amount = r.nat() else return null; let ?currency = r.text() else return null; let ?source = TCan.readSource(r) else return null; let ?d = rDates(r) else return null;
        ?#issueDraft({ serial; payeeCommit; amount; currency; source; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration })
      };
      case 0x1C { let ?serial = r.text() else return null; let ?to = TCan.readSource(r) else return null; let ?d = rDates(r) else return null; ?#payDraft({ serial; to; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration }) };
      case 0x1D { let ?serial = r.text() else return null; let ?refundTo = r.nat() else return null; let ?d = rDates(r) else return null; ?#cancelDraft({ serial; refundTo; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration }) };
      case 0xF0 { let ?p = rCollectionsPolicy(r) else return null; ?#setCollectionsPolicy(p) };
      case 0xF1 { let ?account = r.nat() else return null; let ?reason = r.text() else return null; ?#markUnlikelyToPay({ account; reason }) };
      case 0xF2 {
        let ?account = r.nat() else return null; let ?action = rCollectionAction(r) else return null;
        let ?outcome = r.text() else return null; let ?next = r.optNat() else return null;
        ?#recordCollectionAction({ account; action; outcome; next })
      };
      case 0xF3 { let ?account = r.nat() else return null; let ?amount = r.nat() else return null; let ?by = r.nat() else return null; ?#recordPromiseToPay({ account; amount; by }) };
      case 0xF4 { let ?account = r.nat() else return null; let ?staff = r.principal() else return null; ?#assignCollector({ account; staff }) };
      case 0xF5 { let ?account = r.nat() else return null; ?#closeRecovery({ account }) };
      case 0xD3 { let ?alert = r.nat() else return null; let ?reportRef = r.text() else return null; ?#escalateAlert({ alert; reportRef }) };
      case 0xD4 { let ?period = r.text() else return null; ?#openPacking({ period }) };
      case 0xD5 { let ?pack = r.nat() else return null; let ?cid = r.nat64() else return null; let ?archive = r.principal() else return null; ?#rollPackToArchive({ pack; cid; archive }) };
      case 0xD6 { let ?self = r.nat() else return null; let ?shards = readShards(r) else return null; ?#declareShardRule({ self; shards }) };
      case 0xD7 {
        let ?from = r.nat() else return null; let ?toIdentifier = r.text() else return null; let ?amount = r.nat() else return null; let ?postingDate = r.nat() else return null;
        let ?valueDate = r.nat() else return null; let ?period = r.text() else return null; let ?narration = r.text() else return null;
        ?#openShardTransfer({ from; toIdentifier; amount; postingDate; valueDate; period; narration })
      };
      case 0xD8 {
        let ?id = r.text() else return null; let ?g = r.byte() else return null; let ?ic = r.byte() else return null; let ?d = r.byte() else return null;
        let ?reconciliation = r.text() else return null; let ?feeIncome = r.text() else return null; let ?interchangeBps = r.nat() else return null; let ?hubFeeBps = r.nat() else return null; let ?alarmPercent = r.nat() else return null;
        let granularity : SeT.Granularity = switch (g) { case 0 #gross; case 1 #net; case _ return null };
        let interchange : SeT.Interchange = switch (ic) { case 0 #bilateral; case 1 #multilateral; case _ return null };
        let delay : SeT.Delay = switch (d) { case 0 #immediate; case 1 #deferred; case _ return null };
        ?#declareScheme({ id; granularity; interchange; delay; reconciliation; feeIncome; interchangeBps; hubFeeBps; alarmPercent })
      };
      case 0xD9 { let ?party = r.nat() else return null; let ?bic = r.text() else return null; let ?scheme = r.text() else return null; let ?accounts = readParticipantAccounts(r) else return null; ?#registerParticipant({ party; bic; scheme; accounts }) };
      case 0xDA { let ?participant = r.nat() else return null; ?#deactivateParticipant({ participant }) };
      case 0xDB { let ?participant = r.nat() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?d = r.byte() else return null; let ?postingDate = r.nat() else return null; let ?valueDate = r.nat() else return null; let ?period = r.text() else return null; let ?narration = r.text() else return null; let direction : { #in_; #out } = switch (d) { case 0 #in_; case 1 #out; case _ return null }; ?#recordFunds({ participant; currency; amount; direction; postingDate; valueDate; period; narration }) };
      case 0xDC { let ?scheme = r.text() else return null; let ?payer = r.nat() else return null; let ?payee = r.nat() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?reference = r.text() else return null; let ?ttlSeconds = r.nat() else return null; ?#prepareTransfer({ scheme; payer; payee; currency; amount; reference; ttlSeconds }) };
      case 0xDD { let ?transfer = r.nat() else return null; ?#fulfilTransfer({ transfer }) };
      case 0xDE { let ?transfer = r.nat() else return null; let ?reason = r.text() else return null; ?#rejectTransfer({ transfer; reason }) };
      case 0xDF { let ?transfer = r.nat() else return null; let ?reason = r.text() else return null; ?#errorTransfer({ transfer; reason }) };
      case 0xE0 { let ?scheme = r.text() else return null; let ?businessDate = r.nat() else return null; ?#openSettlementWindow({ scheme; businessDate }) };
      case 0xE1 { let ?window = r.nat() else return null; ?#closeSettlementWindow({ window }) };
      case 0xE2 { let ?window = r.nat() else return null; ?#openSettlement({ window }) };
      case 0xE3 { let ?settlement = r.nat() else return null; let ?reason = r.text() else return null; ?#abortSettlement({ settlement; reason }) };
      case 0xE4 {
        let ?scheme = r.text() else return null; let ?payer = r.nat() else return null; let ?reference = r.text() else return null; let ?ttlSeconds = r.nat() else return null;
        let ?n = r.len16() else return null;
        let requests = List.empty<{ payee : Nat; currency : Text; amount : Nat; reference : Text }>();
        var i = 0;
        while (i < n) { let ?payee = r.nat() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?ref = r.text() else return null; List.add(requests, { payee; currency; amount; reference = ref }); i += 1 };
        ?#receiveBulk({ scheme; payer; reference; ttlSeconds; requests = List.toArray(requests) })
      };
      case 0xE5 { let ?bulk = r.nat() else return null; ?#fulfilBulk({ bulk }) };
      case 0xE6 { let ?bulk = r.nat() else return null; let ?reason = r.text() else return null; ?#rejectBulk({ bulk; reason }) };
      case 0xE7 { let ?id = r.text() else return null; let ?scheme = r.text() else return null; let ?ttlSeconds = r.nat() else return null; let ?hold = readHoldRules(r) else return null; let ?sb = r.byte() else return null; let ?signatures = readSigScheme(sb) else return null; ?#declareRail({ id; scheme; ttlSeconds; hold; signatures }) };
      case 0xE8 { let ?rail = r.text() else return null; let ?bic = r.text() else return null; let ?sb = r.byte() else return null; let ?scheme = readSigScheme(sb) else return null; let ?publicKey = r.blob() else return null; ?#registerConnectorKey({ rail; bic; scheme; publicKey }) };
      case 0xE9 { let ?transfer = r.nat() else return null; let ?reason = r.text() else return null; ?#releaseHold({ transfer; reason }) };
      case 0xEA { let ?transfer = r.nat() else return null; let ?reason = r.text() else return null; ?#rejectHold({ transfer; reason }) };
      case 0xEC { let ?rail = r.text() else return null; let ?debtor = r.nat() else return null; let ?creditorBic = r.text() else return null; let ?currency = r.text() else return null; let ?maxAmount = r.nat() else return null; ?#grantDebitAuthority({ rail; debtor; creditorBic; currency; maxAmount }) };
      case 0xED { let ?rail = r.text() else return null; let ?debtor = r.nat() else return null; let ?creditorBic = r.text() else return null; let ?currency = r.text() else return null; ?#revokeDebitAuthority({ rail; debtor; creditorBic; currency }) };
      case 0xEE { let ?rail = r.text() else return null; let ?mandateId = r.text() else return null; let ?accepted = r.bool() else return null; let ?reason = readOptText(r) else return null; ?#decideMandate({ rail; mandateId; accepted; reason }) };
      case 0xEB { let ?rail = r.text() else return null; let ?participant = r.nat() else return null; let ?fspId = r.text() else return null; let ?endpoints = readPairs(r) else return null; ?#declareFspiopParticipant({ rail; participant; fspId; endpoints }) };
      case _ null;
    }
  };

  func rDates(r : C.Reader) : ?{ postingDate : Nat; valueDate : Nat; period : Text; narration : Text } {
    let ?postingDate = r.nat() else return null; let ?valueDate = r.nat() else return null; let ?period = r.text() else return null; let ?narration = r.text() else return null;
    ?{ postingDate; valueDate; period; narration }
  };
  func rFacilityMoney(r : C.Reader) : ?T.FacilityMoney {
    let ?facility = r.nat() else return null; let ?amount = r.nat() else return null; let ?funding = PC.rFunding(r) else return null; let ?d = rDates(r) else return null;
    ?{ facility; amount; funding; postingDate = d.postingDate; valueDate = d.valueDate; period = d.period; narration = d.narration }
  };

  func rMoneyMove(r : C.Reader) : ?T.MoneyMove {
    let ?account = r.nat() else return null;
    let ?amount = r.nat() else return null;
    let ?postingDate = r.nat() else return null;
    let ?valueDate = r.nat() else return null;
    let ?period = r.text() else return null;
    let ?narration = r.text() else return null;
    let ?funding = PC.rFunding(r) else return null;
    ?{ account; amount; postingDate; valueDate; period; narration; funding }
  };

  public func readEvent(r : C.Reader) : ?T.Event {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x10 { let ?id = r.text() else return null; let ?name = r.text() else return null; let ?parent = rOptText(r) else return null; ?#bookOpened({ id; name; parent }) };
      case 0x11 { let ?id = r.text() else return null; ?#bookClosed({ id }) };
      case 0x12 { let ?id = r.text() else return null; let ?name = r.text() else return null; let ?permissions = rTexts(r) else return null; ?#roleDefined({ id; name; permissions }) };
      case 0x13 { let ?subject = r.principal() else return null; let ?role = r.text() else return null; let ?scope = rScope(r) else return null; ?#roleGranted({ subject; role; scope }) };
      case 0x14 { let ?subject = r.principal() else return null; let ?role = r.text() else return null; ?#roleRevoked({ subject; role }) };
      case 0x15 { let ?p = rPolicy(r) else return null; ?#dualPolicySet(p) };
      case 0x16 { let ?permission = r.text() else return null; ?#dualPolicyCleared({ permission }) };
      case 0x17 { let ?admin = r.principal() else return null; ?#bankAdminTransferred({ admin }) };
      case 0x18 { let ?feature = r.text() else return null; let ?height = r.nat64() else return null; ?#featureActivationSet({ feature; height }) };
      case 0x30 {
        let ?commandHash = r.blob() else return null;
        let ?commandEncoding = r.byte() else return null;
        if (not supportsCommandEncoding(commandEncoding)) return null;
        let ?permission = r.text() else return null;
        let ?book = readOptText(r) else return null;
        let ?maker = r.principal() else return null;
        let ?required = r.nat() else return null;
        let ?eligibleRole = r.text() else return null;
        let ?expiresAt = r.nat64() else return null;
        let ?justification = r.text() else return null;
        // the body, if the block carries one, is read from the trailer by decodeBlock
        ?#commandProposed({ command = null; commandHash; commandEncoding; permission; book; maker; required; eligibleRole; expiresAt; justification })
      };
      case 0x31 { let ?proposal = r.nat() else return null; let ?commandHash = r.blob() else return null; let ?checker = r.principal() else return null; ?#commandApproved({ proposal; commandHash; checker }) };
      case 0x32 { let ?proposal = r.nat() else return null; let ?checker = r.principal() else return null; let ?reason = r.text() else return null; ?#commandRejected({ proposal; checker; reason }) };
      case 0x33 {
        let ?proposal = r.nat() else return null; let ?commandHash = r.blob() else return null; let ?postings = rNats(r) else return null;
        let charge : ?T.Charge = switch (r.byte()) {
          case (?0) null;
          case (?1) {
            let ?day = r.nat() else return null;
            let ?n = r.len16() else return null;
            let totals = List.empty<(Text, Nat)>();
            var i = 0;
            while (i < n) { let ?ccy = r.text() else return null; let ?amt = r.nat() else return null; List.add(totals, (ccy, amt)); i += 1 };
            ?{ day; totals = List.toArray(totals) }
          };
          case (_) return null;
        };
        ?#commandExecuted({ proposal; commandHash; postings; charge })
      };
      case 0x34 { let ?proposal = r.nat() else return null; ?#commandExpired({ proposal }) };
      case 0x35 {
        let ?commandEncoding = r.byte() else return null;
        if (not supportsCommandEncoding(commandEncoding)) return null;
        let ?command = readCommandAt(commandEncoding, r) else return null;
        let ?commandHash = r.blob() else return null;
        let ?actor_ = r.principal() else return null;
        let ?witness = r.principal() else return null;
        let ?justification = r.text() else return null;
        ?#emergencyOverride({ command; commandEncoding; commandHash; actor_; witness; justification })
      };
      case 0x36 { let ?override_ = r.nat() else return null; let ?reviewer = r.principal() else return null; let ?disposition = r.text() else return null; ?#overrideReviewed({ override_; reviewer; disposition }) };
      case 0x50 {
        let ?subject = r.principal() else return null; let ?permission = r.text() else return null;
        let ?reason = rRefusal(r) else return null; let ?detail = r.text() else return null;
        ?#operationRefused({ subject; permission; reason; detail })
      };
      case 0x40 { let ?pe = readPartyEvent(r) else return null; ?#party(pe) };
      case 0x41 { let ?pe = PC.readEvent(r) else return null; ?#product(pe) };
      case 0x42 { let ?ce = CC.readEvent(r) else return null; ?#close(ce) };
      case 0x43 { let ?be = BC.readEvent(r) else return null; ?#batch(be) };
      case 0x44 { let ?re = RC.readEvent(r) else return null; ?#report(re) };
      case 0x45 {
        let ?tag = r.byte() else return null;
        if (tag != 0x01) return null;
        let ?present = r.byte() else return null;
        if (present == 0) return ?#index(#counterpartyClassDimensionSet({ dimension = null }));
        let ?schema = r.text() else return null;
        let ?field = r.text() else return null;
        ?#index(#counterpartyClassDimensionSet({ dimension = ?{ schema; field } }))
      };
      case 0x46 { let ?ae = readArchiveEvent(r) else return null; ?#archive(ae) };
      case 0x47 { let ?me = readMonitoringEvent(r) else return null; ?#monitoring(me) };
      case 0x48 { let ?ae = readAlertEvent(r) else return null; ?#alert(ae) };
      case 0x4E { let ?ce = readCollectionsEvent(r) else return null; ?#collections(ce) };
      case 0x4F { let ?oe = OCan.readEvent(r) else return null; ?#origination(oe) };
      case 0x51 { let ?fe = FCan.readEvent(r) else return null; ?#facility(fe) };
      case 0x52 { let ?te = TCan.readEvent(r) else return null; ?#teller(te) };
      case 0x53 { let ?tr = TrCan.readEvent(r) else return null; ?#trade(tr) };
      case 0x54 { let ?ie = ICan.readEvent(r) else return null; ?#islamic(ie) };
      case 0x55 { let ?te = TyCan.readEvent(r) else return null; ?#treasury(te) };
      case 0x56 { let ?ce = CdCan.readEvent(r) else return null; ?#card(ce) };
      case 0x49 { let ?pe = readPackingEvent(r) else return null; ?#packing(pe) };
      case 0x4A { let ?se = readShardEvent(r) else return null; ?#shard(se) };
      case 0x4B { let ?se = readSettlementEvent(r) else return null; ?#settlement(se) };
      case 0x4C { let ?pe = readPaymentsEvent(r) else return null; ?#payments(pe) };
      case 0x4D { let ?fe = readFspiopEvent(r) else return null; ?#fspiop(fe) };
      case _ null;
    }
  };

  // ═══════════════════════════════════════════════════════
  //  HASHING AND BLOCKS
  // ═══════════════════════════════════════════════════════

  func sha256Domain(domain : Text, payload : [Nat8]) : Blob {
    let d = Sha256.Digest(#sha256);
    let w = C.Writer();
    w.text(domain);
    d.writeArray(w.toArray());
    d.writeArray(payload);
    d.sum()
  };

  /// The hash a checker approves and the executor re-derives.
  /// The hash a new proposal carries: the current encoding under its domain.
  public func commandHash(c : T.Command) : Blob {
    let ?h = commandHashAt(COMMAND_ENCODING, c) else Runtime.trap("BankCanonical: the current encoding represents every command");
    h
  };

  /// The hash under a recorded version — what a reconstruction is compared with, and what a body's check
  /// at approval uses; null when the version is unknown or cannot represent the command.
  public func commandHashAt(version : Nat8, c : T.Command) : ?Blob {
    switch (commandBytesAt(version, c)) { case (?b) ?sha256Domain(commandDomain(version), Blob.toArray(b)); case null null }
  };

  /// A command's canonical bytes under a version — the preimage of `commandHashAt`.
  public func commandBytesAt(version : Nat8, c : T.Command) : ?Blob {
    let w = C.Writer();
    if (not writeCommandAt(version, w, c)) return null;
    ?w.toBlob()
  };

  public func encodeBlock(index : Nat, timestamp : Nat64, caller : Principal, parentHash : ?Blob, event : T.Event) : { bytes : Blob; hash : Blob } {
    encodeBlockAtVersion(BLOCK_VERSION, index, timestamp, caller, parentHash, event)
  };

  public func encodeBlockAtVersion(version : Nat8, index : Nat, timestamp : Nat64, caller : Principal, parentHash : ?Blob, event : T.Event) : { bytes : Blob; hash : Blob } {
    let w = C.Writer();
    w.byte(version);
    w.nat(index);
    w.nat64(timestamp);
    w.principal(caller);
    w.optBlob(parentHash);
    writeEvent(w, event);
    let preimage = w.toArray();
    let hash = sha256Domain(BLOCK_DOMAIN, preimage);
    w.blobRaw(hash);
    // the trailer: a proposal's body, behind the hash and bound to the preimage by commandHash
    switch (event) {
      case (#commandProposed(x)) { switch (x.command) { case (?c) { w.byte(1); ignore writeCommandAt(x.commandEncoding, w, c) }; case null w.byte(0) } };
      case (_) {};
    };
    { bytes = w.toBlob(); hash }
  };

  /// A stored block's bytes without its trailer — the preimage and the hash — for a packer that drops a
  /// proposal's body, and the trailer on its own.
  public func splitTrailer(bytes : Blob) : ?{ head : Blob; trailer : Blob } {
    let data = Blob.toArray(bytes);
    let r = C.Reader(data);
    let ?version = r.byte() else return null;
    if (not supportsVersion(version)) return null;
    let ?_ = r.nat() else return null;
    let ?_ = r.nat64() else return null;
    let ?_ = r.principal() else return null;
    let ?_ = r.optBlob() else return null;
    let ?_ = readEvent(r) else return null;
    let ?_ = r.take(32) else return null;
    let cut = r.position();
    ?{ head = Blob.fromArray(Array.tabulate<Nat8>(cut, func(i) { data[i] })); trailer = Blob.fromArray(Array.tabulate<Nat8>(data.size() - cut, func(i) { data[cut + i] })) }
  };

  /// Decode a stored block, verifying that the stored hash matches the
  /// recomputed hash of the preimage. A mismatch yields null, so a corrupted
  /// entry can never be served as genuine.
  public func decodeBlock(bytes : Blob) : ?T.Block {
    let data = Blob.toArray(bytes);
    let r = C.Reader(data);
    let ?version = r.byte() else return null;
    if (not supportsVersion(version)) return null;
    let ?index = r.nat() else return null;
    let ?timestamp = r.nat64() else return null;
    let ?caller = r.principal() else return null;
    let ?parentHash = r.optBlob() else return null;
    let ?event0 = readEvent(r) else return null;
    let preimageLen = r.position();
    let ?storedHash = r.take(32) else return null;
    // the trailer: a proposal block carries its body here, or a 0 once a pack dropped it; a body that
    // does not hash to the preimage's commandHash is refused as a tampered preimage is
    let event = switch (event0) {
      case (#commandProposed(x)) {
        switch (r.byte()) {
          case (?0) event0;
          case (?1) {
            let ?c = readCommandAt(x.commandEncoding, r) else return null;
            if (commandHashAt(x.commandEncoding, c) != ?x.commandHash) return null;
            #commandProposed({ x with command = ?c })
          };
          case (_) return null;
        }
      };
      case (e) e;
    };
    if (r.remaining() != 0) return null;
    let preimage = Array.tabulate<Nat8>(preimageLen, func(i) { data[i] });
    let recomputed = sha256Domain(BLOCK_DOMAIN, preimage);
    let stored = Blob.fromArray(storedHash);
    if (recomputed != stored) return null;
    ?{ index; timestamp; caller; parentHash; hash = stored; event }
  };
};
