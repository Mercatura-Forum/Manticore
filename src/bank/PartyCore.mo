/// PartyCore.mo: the party / CIF and KYC sub-state machine.
///
/// Owned by `BankCore.State` as one field and folded by `BankCore.apply`, so
/// there is still exactly one log and one fold. Everything here is either a
/// commitment, a state, a date or a decision; see `PartyTypes.mo` for why no
/// plaintext personal data is ever written.
///
/// The control that matters is not the state diagram, it is this: a money-moving
/// operation on a party that is blocked, whose screening does not permit
/// movement, or whose periodic review is overdue past the declared grace is
/// **refused in the same message that would have posted it**, and the refusal is
/// recorded. `permitsMovement` below is that check, and `BankCore.planCommand`
/// calls it before the journal is ever asked to admit anything.
///
/// ## Where a party lives
///
/// The heap holds nothing per party. A party *is* its `#partyCreated` block; what happened to it
/// since is later blocks. The fold keeps one fixed-width **row** per party in stable memory
/// (`PartyRow`): the lifecycle, the screening as the movement gate needs it, the review date, and
/// pointers, block indices, to the blocks that hold the current attributes, due-diligence
/// decision and extension values; and three small stable indexes list the blocks that added each
/// document, relationship and identifier. A `PartyEntry` is rebuilt from the row and those blocks
/// when a reader or a planner needs one. The movement gate reads the row alone, because it runs on
/// every money-moving command. Collateral is the same shape (`CollateralRow`). What stays on the
/// heap is bounded by the organisation, not the customer base: screening lists, schemas, staff,
/// credentials, keys, the identifier format.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import List "mo:core/List";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

import JC "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";

import T "PartyTypes";
import C "Commitments";
import Iban "Iban";
import R "StableRows";

module {

  // ═══════════════════════════════════════════════════════
  //  STATE
  // ═══════════════════════════════════════════════════════

  /// How the fold reads its own blocks back: the party events of the bank's log, by block index.
  /// `BankCore` derives it from the bank's reader; the tests from their in-heap chain.
  public type Blocks = { get : Nat -> ?T.PartyEvent };

  /// A party, rebuilt from its row and its blocks. Immutable: a reader's view of one moment.
  public type PartyEntry = {
    id : T.PartyId;
    kind : T.PartyKind;
    identityCommit : T.Commitment;
    salt : Blob;
    dedupCommit : ?T.Commitment;
    attributes : [T.FieldCommit];
    lifecycle : T.Lifecycle;
    cddLevel : T.CddLevel;
    riskRating : T.RiskRating;
    pep : Bool;
    screening : T.ScreeningState;
    reviewDue : T.Day;
    documents : [T.DocumentRef];
    relationships : [T.Relationship];
    extensions : [T.ExtensionValue];
    book : Text;
    identifiers : [Text];
    createdAtBlock : Nat;
  };

  public type CollateralEntry = {
    id : T.CollateralId;
    party : T.PartyId;
    kind : T.CollateralKind;
    valuation : T.Valuation;
    descriptionCommit : T.Commitment;
    allocations : [T.Allocation];
    released : Bool;
    registeredAtBlock : Nat;
  };

  /// The screening as the row holds it: enough for the movement gate without a block. `at` is the
  /// block that recorded it; `#cleared`'s reason and nothing else needs that block.
  public type ScreeningRow = { tag : Nat8; listOrd : Nat; at : Nat; matches : Nat };

  /// What the fold keeps per party.
  ///
  /// `lifecycle(1) ‖ screening(tag 1, listOrd 4, at 8, matches 4) ‖ attrBlock(8) ‖ cddBlock(8) ‖
  /// extBlock(8) ‖ reviewDue(4) ‖ bookOrd(4) ‖ docCount(2) ‖ relCount(2) ‖ idCount(2)`; 56 bytes.
  /// The attribute and due-diligence pointers start as the party's own block, which carries both.
  public type PartyRow = {
    lifecycle : T.Lifecycle;
    screening : ScreeningRow;
    attrBlock : Nat;
    cddBlock : Nat;
    extBlock : Nat;          // 0: none recorded
    reviewDue : Nat;
    bookOrd : Nat;
    docCount : Nat;
    relCount : Nat;
    idCount : Nat;
  };

  public let PARTY_ROW_BYTES : Nat = 56;

  /// `valuationBlock(8) ‖ allocCount(4) ‖ released(1) ‖ party(8)`; 21 bytes. The valuation pointer
  /// starts as the registration block; the party is what a command's scoping asks for first.
  public type CollateralRow = { valuationBlock : Nat; allocCount : Nat; released : Bool; party : Nat };

  public let COLLATERAL_ROW_BYTES : Nat = 21;

  /// The identifier index key width. An identifier is an IBAN-shaped string (`Iban.mo`), at most 34
  /// characters; the key is the text padded, so two identifiers are one key only if they are equal.
  public let IDENTIFIER_KEY_BYTES : Nat = 64;

  public type State = {
    partyRows : RI.State;                 // party(8) -> PartyRow
    partyDocuments : RI.State;            // party(8) ‖ seq(2) -> block(8)
    partyRelationships : RI.State;        // party(8) ‖ seq(2) -> block(8)
    partyIdentifiers : RI.State;          // party(8) ‖ seq(2) -> block(8)
    /// Institution-wide deduplication index: commitment -> party.
    dedupRows : RI.State;                 // commit(32) -> party(8)
    /// Issued account identifiers -> party, so a lookup by identifier is one read and an identifier
    /// can never be issued twice.
    identifierRows : RI.State;            // identifier(64) -> party(8)
    collateralRows : RI.State;            // collateral(8) -> CollateralRow
    collateralAllocations : RI.State;     // collateral(8) ‖ seq(4) -> block(8)
    collateralByParty : RI.State;         // party(8) ‖ collateral(8) -> 0
    /// Ordinals for the texts a row refers to: books and screening-list versions. Both are bounded
    /// by the organisation, so they stay on the heap; the row carries the number.
    bookOrdinals : Map.Map<Text, Nat>;
    bookNames : List.List<Text>;
    listOrdinals : Map.Map<Text, Nat>;
    listNames : List.List<Text>;
    lists : Map.Map<Text, T.ScreeningList>;
    /// The version of the newest committed list, for staleness.
    var newestList : ?Text;
    schemas : Map.Map<Text, T.ExtensionSchema>;
    staff : Map.Map<Principal, T.Staff>;
    credentials : Map.Map<Principal, T.Credential>;
    jwks : Map.Map<Text, T.Jwks>;
    var format : ?Iban.Format;
    var reviewGraceDays : Nat;
  };

  public func newState(arena : RI.Arena) : State {
    {
      partyRows = RI.newStateIn(arena, { keyBytes = 8; valBytes = PARTY_ROW_BYTES });
      partyDocuments = RI.newStateIn(arena, { keyBytes = 10; valBytes = 8 });
      partyRelationships = RI.newStateIn(arena, { keyBytes = 10; valBytes = 8 });
      partyIdentifiers = RI.newStateIn(arena, { keyBytes = 10; valBytes = 8 });
      dedupRows = RI.newStateIn(arena, { keyBytes = 32; valBytes = 8 });
      identifierRows = RI.newStateIn(arena, { keyBytes = IDENTIFIER_KEY_BYTES; valBytes = 8 });
      collateralRows = RI.newStateIn(arena, { keyBytes = 8; valBytes = COLLATERAL_ROW_BYTES });
      collateralAllocations = RI.newStateIn(arena, { keyBytes = 12; valBytes = 8 });
      collateralByParty = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      bookOrdinals = Map.empty<Text, Nat>();
      bookNames = List.empty<Text>();
      listOrdinals = Map.empty<Text, Nat>();
      listNames = List.empty<Text>();
      lists = Map.empty<Text, T.ScreeningList>();
      var newestList = null;
      schemas = Map.empty<Text, T.ExtensionSchema>();
      staff = Map.empty<Principal, T.Staff>();
      credentials = Map.empty<Principal, T.Credential>();
      jwks = Map.empty<Text, T.Jwks>();
      var format = null;
      var reviewGraceDays = T.DEFAULT_REVIEW_GRACE_DAYS;
    }
  };

  // ─── rows ─────────────────────────────────────────────────────────────────

  func lifecycleTag(l : T.Lifecycle) : Nat8 {
    switch (l) { case (#prospect) 0; case (#pendingKyc) 1; case (#active) 2; case (#dormant) 3; case (#blocked) 4; case (#closed) 5 }
  };
  func lifecycleFromTag(t : Nat8) : T.Lifecycle {
    switch (t) { case 0 #prospect; case 1 #pendingKyc; case 2 #active; case 3 #dormant; case 4 #blocked; case 5 #closed; case _ Runtime.trap("PartyCore: a lifecycle tag that is not one") }
  };

  public let SCREENING_UNSCREENED : Nat8 = 0;
  public let SCREENING_CLEAR : Nat8 = 1;
  public let SCREENING_HIT : Nat8 = 2;
  public let SCREENING_CLEARED : Nat8 = 3;
  public let SCREENING_CONFIRMED : Nat8 = 4;

  public func encodePartyRow(r : PartyRow) : Blob {
    let b = R.buf();
    R.putByte(b, lifecycleTag(r.lifecycle));
    R.putByte(b, r.screening.tag); R.putNat(b, r.screening.listOrd, 4); R.putNat(b, r.screening.at, 8); R.putNat(b, r.screening.matches, 4);
    R.putNat(b, r.attrBlock, 8); R.putNat(b, r.cddBlock, 8); R.putNat(b, r.extBlock, 8);
    R.putNat(b, r.reviewDue, 4); R.putNat(b, r.bookOrd, 4);
    R.putNat(b, r.docCount, 2); R.putNat(b, r.relCount, 2); R.putNat(b, r.idCount, 2);
    R.done(b, PARTY_ROW_BYTES)
  };

  public func decodePartyRow(v : Blob) : PartyRow {
    let a = Blob.toArray(v);
    assert (a.size() == PARTY_ROW_BYTES);
    {
      lifecycle = lifecycleFromTag(a[0]);
      screening = { tag = a[1]; listOrd = R.getNat(a, 2, 4); at = R.getNat(a, 6, 8); matches = R.getNat(a, 14, 4) };
      attrBlock = R.getNat(a, 18, 8); cddBlock = R.getNat(a, 26, 8); extBlock = R.getNat(a, 34, 8);
      reviewDue = R.getNat(a, 42, 4); bookOrd = R.getNat(a, 46, 4);
      docCount = R.getNat(a, 50, 2); relCount = R.getNat(a, 52, 2); idCount = R.getNat(a, 54, 2);
    }
  };

  public func encodeCollateralRow(r : CollateralRow) : Blob {
    let b = R.buf();
    R.putNat(b, r.valuationBlock, 8); R.putNat(b, r.allocCount, 4); R.putBool(b, r.released); R.putNat(b, r.party, 8);
    R.done(b, COLLATERAL_ROW_BYTES)
  };

  public func decodeCollateralRow(v : Blob) : CollateralRow {
    let a = Blob.toArray(v);
    assert (a.size() == COLLATERAL_ROW_BYTES);
    { valuationBlock = R.getNat(a, 0, 8); allocCount = R.getNat(a, 8, 4); released = R.getBool(a, 12); party = R.getNat(a, 13, 8) }
  };

  func ordinalOf(ords : Map.Map<Text, Nat>, names : List.List<Text>, t : Text) : Nat {
    switch (Map.get(ords, Text.compare, t)) {
      case (?o) o;
      case null { let o = List.size(names); List.add(names, t); Map.add(ords, Text.compare, t, o); o };
    }
  };

  func nameOf(names : List.List<Text>, o : Nat) : Text {
    switch (List.get(names, o)) { case (?t) t; case null Runtime.trap("PartyCore: an ordinal with no name") }
  };

  public func partyRow(s : State, id : T.PartyId) : ?PartyRow {
    switch (RI.get(s.partyRows, R.key(id, 8))) { case (?v) ?decodePartyRow(v); case null null }
  };

  func putPartyRow(s : State, id : T.PartyId, r : PartyRow) { ignore RI.put(s.partyRows, R.key(id, 8), encodePartyRow(r)) };

  func mustRow(s : State, id : T.PartyId) : PartyRow {
    switch (partyRow(s, id)) { case (?r) r; case null Runtime.trap("PartyCore: unknown party " # Nat.toText(id)) }
  };

  public func collateralRow(s : State, id : T.CollateralId) : ?CollateralRow {
    switch (RI.get(s.collateralRows, R.key(id, 8))) { case (?v) ?decodeCollateralRow(v); case null null }
  };

  func putCollateralRow(s : State, id : T.CollateralId, r : CollateralRow) { ignore RI.put(s.collateralRows, R.key(id, 8), encodeCollateralRow(r)) };

  func mustCollateralRow(s : State, id : T.CollateralId) : CollateralRow {
    switch (collateralRow(s, id)) { case (?r) r; case null Runtime.trap("PartyCore: unknown collateral " # Nat.toText(id)) }
  };

  /// The block indices listed under a party (or a collateral item) in one of the sequence indexes,
  /// in the order they were recorded.
  func listed(idx : RI.State, owner : Nat, seqWidth : Nat, count : Nat) : [Nat] {
    if (count == 0) return [];
    let (lo, hi) = R.prefixRange(owner, 8, seqWidth);
    let page = RI.range(idx, lo, hi, null, count);
    Array.map<(Blob, Blob), Nat>(page.entries, func((_, v)) { R.getNat(Blob.toArray(v), 0, 8) })
  };

  func eventAt(bb : Blocks, index : Nat, what : Text) : T.PartyEvent {
    let ?e = bb.get(index) else Runtime.trap("PartyCore: the log has no party event at block " # Nat.toText(index) # " for " # what);
    e
  };

  // ═══════════════════════════════════════════════════════
  //  EVENTS
  // ═══════════════════════════════════════════════════════

  /// The party events live in `PartyTypes` so the bank's own vocabulary can
  /// name them without importing this state module.
  public type Event = T.PartyEvent;

  // ═══════════════════════════════════════════════════════
  //  LOOKUPS AND THE MOVEMENT GATE
  // ═══════════════════════════════════════════════════════

  /// A party, rebuilt from its row and its blocks: the creation block, the blocks the row points at
  /// for attributes, due diligence, extensions and screening, and one block per document,
  /// relationship and identifier. `null` when no party was ever created at that index.
  public func get(s : State, bb : Blocks, id : T.PartyId) : ?PartyEntry {
    let ?row = partyRow(s, id) else return null;
    let #partyCreated(c) = eventAt(bb, id, "a party") else Runtime.trap("PartyCore: block " # Nat.toText(id) # " has a party row but is not a party");
    let attributes = if (row.attrBlock == id) c.attributes else {
      let #partyAmended(x) = eventAt(bb, row.attrBlock, "the party's attributes") else Runtime.trap("PartyCore: attribute pointer to a block that is not an amendment");
      x.attributes
    };
    let (cddLevel, riskRating, pep, reviewDue) = if (row.cddBlock == id) (c.cddLevel, c.riskRating, c.pep, c.reviewDue) else {
      let #partyCddSet(x) = eventAt(bb, row.cddBlock, "the party's due diligence") else Runtime.trap("PartyCore: due-diligence pointer to a block that is not a decision");
      (x.level, x.riskRating, x.pep, x.reviewDue)
    };
    let extensions = if (row.extBlock == 0) [] else {
      let #partyExtensionSet(x) = eventAt(bb, row.extBlock, "the party's extensions") else Runtime.trap("PartyCore: extension pointer to a block that is not an extension record");
      x.values
    };
    let documents = Array.map<Nat, T.DocumentRef>(listed(s.partyDocuments, id, 2, row.docCount), func(i) {
      let #partyDocumentAdded(x) = eventAt(bb, i, "a document") else Runtime.trap("PartyCore: a document index entry that is not a document");
      x.document
    });
    let relationships = Array.map<Nat, T.Relationship>(listed(s.partyRelationships, id, 2, row.relCount), func(i) {
      let #partyRelationshipAdded(x) = eventAt(bb, i, "a relationship") else Runtime.trap("PartyCore: a relationship index entry that is not a relationship");
      x.relationship
    });
    let identifiers = Array.map<Nat, Text>(listed(s.partyIdentifiers, id, 2, row.idCount), func(i) {
      let #partyIdentifierIssued(x) = eventAt(bb, i, "an identifier") else Runtime.trap("PartyCore: an identifier index entry that is not an issue");
      x.identifier
    });
    ?{
      id; kind = c.kind; identityCommit = c.identityCommit; salt = c.salt; dedupCommit = c.dedupCommit;
      attributes; lifecycle = row.lifecycle; cddLevel; riskRating; pep;
      screening = screeningOf(s, bb, row.screening);
      reviewDue; documents; relationships; extensions;
      book = nameOf(s.bookNames, row.bookOrd); identifiers; createdAtBlock = id;
    }
  };

  /// The recorded screening state, from the row and; for a cleared hit, whose reason is not in the
  /// row; its block.
  func screeningOf(s : State, bb : Blocks, r : ScreeningRow) : T.ScreeningState {
    if (r.tag == SCREENING_UNSCREENED) return #unscreened;
    let listVersion = nameOf(s.listNames, r.listOrd);
    if (r.tag == SCREENING_CLEAR) return #clear({ listVersion; at = r.at });
    if (r.tag == SCREENING_HIT) return #hit({ listVersion; matches = r.matches; at = r.at });
    if (r.tag == SCREENING_CONFIRMED) return #confirmed({ listVersion; at = r.at });
    let #screeningDecisionRecorded(d) = eventAt(bb, r.at, "a cleared screening") else Runtime.trap("PartyCore: a cleared screening whose block is not a decision");
    let #cleared({ reason }) = d.decision else Runtime.trap("PartyCore: a cleared screening whose block is not a clearance");
    #cleared({ listVersion; at = r.at; reason })
  };

  public func partyCount(s : State) : Nat { RI.size(s.partyRows) };
  public func listCount(s : State) : Nat { Map.size(s.lists) };
  public func schemaCount(s : State) : Nat { Map.size(s.schemas) };
  public func collateralCount(s : State) : Nat { RI.size(s.collateralRows) };
  public func staffCount(s : State) : Nat { Map.size(s.staff) };
  public func byIdentifier(s : State, identifier : Text) : ?T.PartyId {
    if (Text.encodeUtf8(identifier).size() > IDENTIFIER_KEY_BYTES) return null;
    switch (RI.get(s.identifierRows, R.textKey(identifier, IDENTIFIER_KEY_BYTES))) { case (?v) ?R.getNat(Blob.toArray(v), 0, 8); case null null }
  };
  public func byDedup(s : State, commit : T.Commitment) : ?T.PartyId {
    if (commit.size() != 32) return null;
    switch (RI.get(s.dedupRows, commit)) { case (?v) ?R.getNat(Blob.toArray(v), 0, 8); case null null }
  };
  public func getList(s : State, version : Text) : ?T.ScreeningList { Map.get(s.lists, Text.compare, version) };
  public func getStaff(s : State, p : Principal) : ?T.Staff { Map.get(s.staff, Principal.compare, p) };
  public func getCredential(s : State, p : Principal) : ?T.Credential { Map.get(s.credentials, Principal.compare, p) };
  public func getSchema(s : State, id : Text) : ?T.ExtensionSchema { Map.get(s.schemas, Text.compare, id) };
  public func exists(s : State, id : T.PartyId) : Bool { partyRow(s, id) != null };

  /// The counts the planners bound: documents, relationships and identifiers; from the row.
  public func counts(s : State, id : T.PartyId) : ?{ documents : Nat; relationships : Nat; identifiers : Nat } {
    switch (partyRow(s, id)) { case (?r) ?{ documents = r.docCount; relationships = r.relCount; identifiers = r.idCount }; case null null }
  };

  /// A recorded extension value as the text a classification is keyed on. One copy, used by the
  /// report engine's `#counterpartyClass` dimension and by the counterparty-class index, because two
  /// copies of this mapping would eventually disagree and a class row would mean one thing in a
  /// report and another in an index.
  ///
  /// A commitment is **not** a classification: it is deliberately unreadable, so anything keyed on
  /// one is keyed on nothing and says so rather than inventing a bucket.
  public func extensionText(v : T.FieldValue) : Text {
    switch (v) {
      case (#text(t)) t;
      case (#enumerated(t)) t;
      case (#integer(i)) Int.toText(i);
      case (#date(d)) Nat.toText(d);
      case (#boolean(b)) (if (b) "true" else "false");
      case (#commitment(_)) "unclassified";
    }
  };

  /// The recorded extension values of a party, in the order they were recorded.
  public func extensions(p : PartyEntry) : [T.ExtensionValue] { p.extensions };

  /// The extension values alone, from the one block the row points at; for the index, which asks
  /// for them on every posting and needs nothing else of the party.
  public func extensionsOf(s : State, bb : Blocks, id : T.PartyId) : ?[T.ExtensionValue] {
    let ?row = partyRow(s, id) else return null;
    if (row.extBlock == 0) return ?[];
    let #partyExtensionSet(x) = eventAt(bb, row.extBlock, "the party's extensions") else Runtime.trap("PartyCore: extension pointer to a block that is not an extension record");
    ?x.values
  };

  public func getCollateral(s : State, bb : Blocks, id : T.CollateralId) : ?CollateralEntry {
    let ?row = collateralRow(s, id) else return null;
    let #collateralRegistered(c) = eventAt(bb, id, "a collateral item") else Runtime.trap("PartyCore: block " # Nat.toText(id) # " has a collateral row but is not a registration");
    let valuation = if (row.valuationBlock == id) c.valuation else {
      let #collateralRevalued(x) = eventAt(bb, row.valuationBlock, "a revaluation") else Runtime.trap("PartyCore: valuation pointer to a block that is not a revaluation");
      x.valuation
    };
    let allocations = Array.map<Nat, T.Allocation>(listed(s.collateralAllocations, id, 4, row.allocCount), func(i) {
      let #collateralAllocated(x) = eventAt(bb, i, "an allocation") else Runtime.trap("PartyCore: an allocation index entry that is not an allocation");
      { collateral = x.collateral; facility = x.facility; amount = x.amount }
    });
    ?{ id; party = c.party; kind = c.kind; valuation; descriptionCommit = c.descriptionCommit; allocations; released = row.released; registeredAtBlock = id }
  };

  /// The party a collateral item is registered to, from the row.
  public func collateralPartyOf(s : State, id : T.CollateralId) : ?T.PartyId {
    switch (collateralRow(s, id)) { case (?r) ?r.party; case null null }
  };

  /// The collateral items registered to a party, by the party index; a range, not a scan.
  public func collateralOfParty(s : State, party : T.PartyId) : [T.CollateralId] {
    let (lo, hi) = R.prefixRange(party, 8, 8);
    let out = List.empty<T.CollateralId>();
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.collateralByParty, lo, hi, cursor, MAX_PAGE);
      for ((k, _) in page.entries.vals()) List.add(out, R.getNat(Blob.toArray(k), 8, 8));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };

  public func format(s : State) : ?Iban.Format { s.format };
  public func reviewGraceDays(s : State) : Nat { s.reviewGraceDays };

  /// The effective screening state, which is the recorded one unless a newer list
  /// has been committed since; in which case the party is stale and money stops.
  public func effectiveScreening(s : State, p : PartyEntry) : T.ScreeningState {
    switch (p.screening, s.newestList) {
      case (#clear({ listVersion; at = _ }), ?newest) {
        if (Text.equal(listVersion, newest)) p.screening else #rescreenDue({ since = newest })
      };
      case (#cleared({ listVersion; at = _; reason = _ }), ?newest) {
        if (Text.equal(listVersion, newest)) p.screening else #rescreenDue({ since = newest })
      };
      case (st, _) st;
    }
  };

  /// The same, from the row alone, for the gate.
  func effectiveScreeningRow(s : State, bb : Blocks, r : ScreeningRow) : T.ScreeningState {
    switch (s.newestList) {
      case (?newest) {
        if ((r.tag == SCREENING_CLEAR or r.tag == SCREENING_CLEARED) and not Text.equal(nameOf(s.listNames, r.listOrd), newest)) {
          return #rescreenDue({ since = newest });
        };
      };
      case null {};
    };
    screeningOf(s, bb, r)
  };

  /// May money move for this party today? The one check every money-moving
  /// command runs, returning the typed reason it refused. **Reads the row only** on the path that
  /// permits; a refusal for screening reads the screening block once, to name the state exactly.
  public func permitsMovement(s : State, bb : Blocks, id : T.PartyId, today : T.Day) : ?T.PartyError {
    let ?r = partyRow(s, id) else return ?#UnknownParty({ party = id });
    switch (r.lifecycle) {
      case (#active) {};
      case (other) return ?#PartyNotActive({ party = id; lifecycle = other });
    };
    let permitted = (r.screening.tag == SCREENING_CLEAR or r.screening.tag == SCREENING_CLEARED) and (switch (s.newestList) {
      case (?newest) Text.equal(nameOf(s.listNames, r.screening.listOrd), newest);
      case null true;
    });
    if (not permitted) return ?#ScreeningBlocks({ party = id; state = effectiveScreeningRow(s, bb, r.screening) });
    if (today > r.reviewDue + s.reviewGraceDays) {
      return ?#ReviewOverdue({ party = id; due = r.reviewDue; today; grace = s.reviewGraceDays });
    };
    null
  };

  /// Which books a party's data belongs to, for read scoping. From the row.
  public func bookOf(s : State, id : T.PartyId) : ?Text {
    switch (partyRow(s, id)) { case (?r) ?nameOf(s.bookNames, r.bookOrd); case null null }
  };

  public func lifecycleOf(s : State, id : T.PartyId) : ?T.Lifecycle {
    switch (partyRow(s, id)) { case (?r) ?r.lifecycle; case null null }
  };

  public func allocatedAgainst(c : CollateralEntry) : Nat {
    var total = 0;
    for (a in c.allocations.vals()) { total += a.amount };
    total
  };

  /// The value available to allocate: the valuation less the haircut.
  public func haircutValue(v : T.Valuation) : Nat {
    if (v.haircut >= 100) 0 else v.amount * (100 - v.haircut) / 100
  };

  // ═══════════════════════════════════════════════════════
  //  VALIDATION
  // ═══════════════════════════════════════════════════════

  /// The legal lifecycle transitions. Everything else is refused, and the full
  /// matrix is enumerated by the battery.
  public func transitionAllowed(from : T.Lifecycle, to : T.Lifecycle) : Bool {
    switch (from, to) {
      case (#prospect, #pendingKyc) true;
      case (#prospect, #closed) true;
      case (#pendingKyc, #active) true;
      case (#pendingKyc, #blocked) true;
      case (#pendingKyc, #closed) true;
      case (#active, #dormant) true;
      case (#active, #blocked) true;
      case (#active, #closed) true;
      case (#dormant, #active) true;
      case (#dormant, #blocked) true;
      case (#dormant, #closed) true;
      case (#blocked, #active) true;
      case (#blocked, #closed) true;
      case (_, _) false;
    }
  };

  /// What a CDD level requires before a party may become active. FATF
  /// Recommendation 10: more risk, more evidence.
  public func requiredDocuments(level : T.CddLevel) : [Text] {
    switch (level) {
      case (#simplified) ["identity"];
      case (#standard) ["identity", "address"];
      case (#enhanced) ["identity", "address", "sourceOfFunds"];
    }
  };

  func hasDocument(p : PartyEntry, kind : Text) : Bool {
    for (d in p.documents.vals()) { if (Text.equal(d.kind, kind)) return true };
    false
  };

  public func missingDocuments(p : PartyEntry) : [Text] {
    let out = List.empty<Text>();
    for (k in requiredDocuments(p.cddLevel).vals()) { if (not hasDocument(p, k)) List.add(out, k) };
    List.toArray(out)
  };

  func validFieldName(t : Text) : Bool {
    let n = Text.encodeUtf8(t).size();
    n > 0 and n <= T.MAX_FIELD_NAME_BYTES
  };

  public func validateAttributes(attrs : [T.FieldCommit]) : ?Text {
    if (attrs.size() > T.MAX_ATTRIBUTES) return ?"too many attributes";
    var i = 0;
    while (i < attrs.size()) {
      if (not validFieldName(attrs[i].name)) return ?("attribute name out of bounds: " # attrs[i].name);
      if (not C.validCommitment(attrs[i].commit)) return ?("attribute " # attrs[i].name # " is not a 32-byte commitment");
      var j = i + 1;
      while (j < attrs.size()) {
        if (Text.equal(attrs[i].name, attrs[j].name)) return ?("duplicate attribute " # attrs[i].name);
        j += 1;
      };
      i += 1;
    };
    null
  };

  public func validateValuation(v : T.Valuation) : ?Text {
    if (v.amount == 0) return ?"a valuation of zero cannot secure anything";
    if (v.haircut > 100) return ?"a haircut cannot exceed 100 percent";
    if (Text.encodeUtf8(v.currency).size() != 3) return ?"the currency must be a three-letter code";
    if (Text.encodeUtf8(v.source).size() == 0) return ?"a valuation needs a source";
    null
  };

  public func validateSchema(sch : { id : Text; entity : T.EntityKind; fields : [T.FieldDef] }) : ?Text {
    if (not validFieldName(sch.id)) return ?"schema id out of bounds";
    if (sch.fields.size() == 0) return ?"a schema with no fields cannot validate anything";
    if (sch.fields.size() > T.MAX_SCHEMA_FIELDS) return ?"too many fields";
    var i = 0;
    while (i < sch.fields.size()) {
      let f = sch.fields[i];
      if (not validFieldName(f.name)) return ?("field name out of bounds: " # f.name);
      switch (f.fieldType) {
        case (#text({ maxBytes })) { if (maxBytes == 0 or maxBytes > T.MAX_TEXT_FIELD_BYTES) return ?("text field " # f.name # " has an impossible bound") };
        case (#integer({ min; max })) { if (min > max) return ?("integer field " # f.name # " has min above max") };
        case (#enumerated(vs)) {
          if (vs.size() == 0) return ?("enumerated field " # f.name # " has no values");
          if (vs.size() > T.MAX_ENUM_VALUES) return ?("enumerated field " # f.name # " has too many values");
          var a = 0;
          while (a < vs.size()) {
            var b = a + 1;
            while (b < vs.size()) { if (Text.equal(vs[a], vs[b])) return ?("duplicate enumerated value " # vs[a]); b += 1 };
            a += 1;
          };
        };
        case (_) {};
      };
      var j = i + 1;
      while (j < sch.fields.size()) {
        if (Text.equal(f.name, sch.fields[j].name)) return ?("duplicate field " # f.name);
        j += 1;
      };
      i += 1;
    };
    null
  };

  /// Validate extension values against their schema. Returns the first typed
  /// failure; nothing is stored that the schema does not admit.
  public func validateExtensionValues(s : State, entity : T.EntityKind, values : [T.ExtensionValue]) : ?T.PartyError {
    if (values.size() > T.MAX_EXTENSIONS) return ?#InvalidSchema({ reason = "too many extension values" });
    for (v in values.vals()) {
      let ?sch = getSchema(s, v.schema) else return ?#UnknownSchema({ schema = v.schema });
      if (sch.entity != entity) return ?#InvalidSchema({ reason = "schema " # v.schema # " is not for this entity kind" });
      var def : ?T.FieldDef = null;
      for (f in sch.fields.vals()) { if (Text.equal(f.name, v.name)) def := ?f };
      let ?d = def else return ?#FieldNotInSchema({ schema = v.schema; name = v.name });
      switch (d.fieldType, v.value) {
        case (#text({ maxBytes }), #text(t)) {
          if (Text.encodeUtf8(t).size() > maxBytes) return ?#FieldOutOfRange({ schema = v.schema; name = v.name; detail = "longer than " # Nat.toText(maxBytes) # " bytes" });
        };
        case (#integer({ min; max }), #integer(i)) {
          if (i < min or i > max) return ?#FieldOutOfRange({ schema = v.schema; name = v.name; detail = "outside [" # Int.toText(min) # ", " # Int.toText(max) # "]" });
        };
        case (#date, #date(_)) {};
        case (#enumerated(vs), #enumerated(x)) {
          var ok = false;
          for (w in vs.vals()) { if (Text.equal(w, x)) ok := true };
          if (not ok) return ?#FieldOutOfRange({ schema = v.schema; name = v.name; detail = "not a declared value" });
        };
        case (#boolean, #boolean(_)) {};
        case (#commitment, #commitment(c)) {
          if (not C.validCommitment(c)) return ?#InvalidCommitment({ reason = "extension field " # v.name # " is not a 32-byte commitment" });
        };
        case (expected, _) return ?#FieldTypeMismatch({ schema = v.schema; name = v.name; expected = typeName(expected) });
      };
    };
    // required fields must be present for every schema mentioned
    let mentioned = List.empty<Text>();
    for (v in values.vals()) {
      var seen = false;
      for (m in List.values(mentioned)) { if (Text.equal(m, v.schema)) seen := true };
      if (not seen) List.add(mentioned, v.schema);
    };
    for (sid in List.values(mentioned)) {
      let ?sch = getSchema(s, sid) else return ?#UnknownSchema({ schema = sid });
      for (f in sch.fields.vals()) {
        if (f.required) {
          var present = false;
          for (v in values.vals()) { if (Text.equal(v.schema, sid) and Text.equal(v.name, f.name)) present := true };
          if (not present) return ?#MissingRequiredField({ schema = sid; name = f.name });
        };
      };
    };
    null
  };

  func typeName(t : T.FieldType) : Text {
    switch (t) {
      case (#text(_)) "text"; case (#integer(_)) "integer"; case (#date) "date";
      case (#enumerated(_)) "enumerated"; case (#boolean) "boolean"; case (#commitment) "commitment";
    }
  };

  /// Recompute a party's identity commitment from the components a client
  /// submits, and compare. The canister never learns the plaintext: it is given
  /// the commitment to check and the salt it already holds.
  public func verifyIdentity(p : PartyEntry, claimed : T.Commitment) : ?T.PartyError {
    if (claimed != p.identityCommit) {
      return ?#CommitmentMismatch({ field = "identity"; recorded = p.identityCommit; recomputed = claimed });
    };
    null
  };

  /// Verify a set of field commitments against the record; the check a payment's
  /// originator block goes through, so a message can never carry originator data
  /// that disagrees with the customer file.
  public func verifyFields(p : PartyEntry, claimed : [T.FieldCommit]) : ?T.PartyError {
    for (c in claimed.vals()) {
      var found = false;
      for (a in p.attributes.vals()) {
        if (Text.equal(a.name, c.name)) {
          found := true;
          if (a.commit != c.commit) {
            return ?#CommitmentMismatch({ field = c.name; recorded = a.commit; recomputed = c.commit });
          };
        };
      };
      if (not found) return ?#CommitmentMismatch({ field = c.name; recorded = "" : Blob; recomputed = c.commit });
    };
    null
  };

  // ═══════════════════════════════════════════════════════
  //  APPLY
  // ═══════════════════════════════════════════════════════

  func seqKey(owner : Nat, seq : Nat, width : Nat) : Blob { R.key2(owner, 8, seq, width) };

  public func apply(s : State, blockIndex : Nat, e : Event) {
    switch (e) {
      case (#partyCreated(x)) {
        putPartyRow(s, blockIndex, {
          lifecycle = #prospect;
          screening = { tag = SCREENING_UNSCREENED; listOrd = 0; at = 0; matches = 0 };
          attrBlock = blockIndex; cddBlock = blockIndex; extBlock = 0;
          reviewDue = x.reviewDue; bookOrd = ordinalOf(s.bookOrdinals, s.bookNames, x.book);
          docCount = 0; relCount = 0; idCount = 0;
        });
        switch (x.dedupCommit) { case (?d) { ignore RI.put(s.dedupRows, d, R.key(blockIndex, 8)) }; case null {} };
      };
      case (#partyAmended(x)) { putPartyRow(s, x.party, { mustRow(s, x.party) with attrBlock = blockIndex }) };
      case (#partyLifecycleSet(x)) { putPartyRow(s, x.party, { mustRow(s, x.party) with lifecycle = x.to }) };
      case (#partyCddSet(x)) { putPartyRow(s, x.party, { mustRow(s, x.party) with cddBlock = blockIndex; reviewDue = x.reviewDue }) };
      case (#partyDocumentAdded(x)) {
        let r = mustRow(s, x.party);
        ignore RI.put(s.partyDocuments, seqKey(x.party, r.docCount, 2), R.key(blockIndex, 8));
        putPartyRow(s, x.party, { r with docCount = r.docCount + 1 });
      };
      case (#partyRelationshipAdded(x)) {
        let r = mustRow(s, x.party);
        ignore RI.put(s.partyRelationships, seqKey(x.party, r.relCount, 2), R.key(blockIndex, 8));
        putPartyRow(s, x.party, { r with relCount = r.relCount + 1 });
      };
      case (#partyExtensionSet(x)) { putPartyRow(s, x.party, { mustRow(s, x.party) with extBlock = blockIndex }) };
      case (#partyIdentifierIssued(x)) {
        let r = mustRow(s, x.party);
        ignore RI.put(s.partyIdentifiers, seqKey(x.party, r.idCount, 2), R.key(blockIndex, 8));
        putPartyRow(s, x.party, { r with idCount = r.idCount + 1 });
        ignore RI.put(s.identifierRows, R.textKey(x.identifier, IDENTIFIER_KEY_BYTES), R.key(x.party, 8));
      };
      case (#screeningListCommitted(x)) {
        Map.add(s.lists, Text.compare, x.version, {
          version = x.version; root = x.root; count = x.count;
          normalisation = x.normalisation; committedAtBlock = blockIndex;
        });
        ignore ordinalOf(s.listOrdinals, s.listNames, x.version);
        s.newestList := ?x.version;
      };
      case (#screeningProven(x)) {
        let r = mustRow(s, x.party);
        putPartyRow(s, x.party, { r with screening = { tag = SCREENING_CLEAR; listOrd = ordinalOf(s.listOrdinals, s.listNames, x.listVersion); at = blockIndex; matches = 0 } });
      };
      case (#screeningDecisionRecorded(d)) {
        let r = mustRow(s, d.party);
        let ord = ordinalOf(s.listOrdinals, s.listNames, d.listVersion);
        let (tag, matches) : (Nat8, Nat) = switch (d.decision) {
          case (#clear) (SCREENING_CLEAR, 0);
          case (#hit({ matches })) (SCREENING_HIT, matches);
          case (#cleared(_)) (SCREENING_CLEARED, 0);
          case (#confirmed) (SCREENING_CONFIRMED, 0);
        };
        // A confirmed match blocks the party outright; the state alone would stop
        // money, and the lifecycle makes it visible everywhere a lifecycle is read.
        let lifecycle = switch (d.decision) { case (#confirmed) #blocked; case (_) r.lifecycle };
        putPartyRow(s, d.party, { r with screening = { tag; listOrd = ord; at = blockIndex; matches }; lifecycle });
      };
      case (#schemaRegistered(x)) {
        Map.add(s.schemas, Text.compare, x.id, { id = x.id; entity = x.entity; fields = x.fields; registeredAtBlock = blockIndex });
      };
      case (#collateralRegistered(x)) {
        putCollateralRow(s, blockIndex, { valuationBlock = blockIndex; allocCount = 0; released = false; party = x.party });
        ignore RI.put(s.collateralByParty, R.key2(x.party, 8, blockIndex, 8), "\00");
      };
      case (#collateralRevalued(x)) { putCollateralRow(s, x.collateral, { mustCollateralRow(s, x.collateral) with valuationBlock = blockIndex }) };
      case (#collateralAllocated(x)) {
        let r = mustCollateralRow(s, x.collateral);
        ignore RI.put(s.collateralAllocations, seqKey(x.collateral, r.allocCount, 4), R.key(blockIndex, 8));
        putCollateralRow(s, x.collateral, { r with allocCount = r.allocCount + 1 });
      };
      case (#collateralReleased(x)) { putCollateralRow(s, x.collateral, { mustCollateralRow(s, x.collateral) with released = true }) };
      case (#staffAdded(x)) {
        Map.add(s.staff, Principal.compare, x.principal_, { principal_ = x.principal_; book = x.book; title = x.title; status = #active; addedAtBlock = blockIndex });
      };
      case (#staffRemoved(x)) { ignore Map.delete(s.staff, Principal.compare, x.principal_) };
      case (#accountFormatSet(f)) { s.format := ?f };
      case (#jwksPinned(j)) { Map.add(s.jwks, Text.compare, j.issuer, { j with pinnedAtBlock = blockIndex }) };
      case (#credentialRegistered(c)) { Map.add(s.credentials, Principal.compare, c.subject, { c with registeredAtBlock = blockIndex }) };
      case (#credentialRevoked(x)) {
        switch (Map.get(s.credentials, Principal.compare, x.subject)) {
          case (?c) Map.add(s.credentials, Principal.compare, x.subject, { c with revokedAtBlock = ?blockIndex });
          case null Runtime.trap("PartyCore: revoke of unknown credential");
        };
      };
      case (#reviewGraceSet(x)) { s.reviewGraceDays := x.days };
    };
  };

  // ═══════════════════════════════════════════════════════
  //  VIEWS
  // ═══════════════════════════════════════════════════════

  public func view(s : State, p : PartyEntry) : T.PartyView {
    {
      id = p.id; kind = p.kind; identityCommit = p.identityCommit; salt = p.salt;
      dedupCommit = p.dedupCommit; attributes = p.attributes;
      lifecycle = p.lifecycle; cddLevel = p.cddLevel; riskRating = p.riskRating; pep = p.pep;
      screening = effectiveScreening(s, p);
      reviewDue = p.reviewDue;
      documents = p.documents;
      relationships = p.relationships;
      extensions = p.extensions;
      book = p.book;
      identifiers = p.identifiers;
      createdAtBlock = p.createdAtBlock;
    }
  };

  func mustGet(s : State, bb : Blocks, id : T.PartyId) : PartyEntry {
    let ?p = get(s, bb, id) else Runtime.trap("PartyCore: a party row without a party at " # Nat.toText(id));
    p
  };

  // ─── paged reads ──────────────────────────────────────────────────────────
  //
  // Parties, collateral and staff all grow with the bank, so every list of them is unbounded and
  // every one has a cursor-paged form. A party page is one range over the rows and then the blocks
  // of each party on the page, so a page costs the page and not the position. The unpaged forms
  // stay for the internal callers that are bounded by something else.

  public let MAX_PAGE : Nat = 500;

  public func pageLimit(limit : Nat) : Nat { if (limit == 0 or limit > MAX_PAGE) MAX_PAGE else limit };

  /// Row keys from `cursor` on, one page.
  func rowKeys(idx : RI.State, cursor : ?Nat, limit : Nat) : { ids : [Nat]; next : ?Nat } {
    let (lo, hi) = R.fullRange(8);
    let page = RI.range(idx, lo, hi, switch (cursor) { case (?c) ?R.key(c, 8); case null null }, limit);
    { ids = Array.map<(Blob, Blob), Nat>(page.entries, func((k, _)) { R.getNat(Blob.toArray(k), 0, 8) }); next = switch (page.cursor) { case (?k) ?R.getNat(Blob.toArray(k), 0, 8); case null null } }
  };

  public func listParties(s : State, bb : Blocks) : [T.PartyView] {
    let out = List.empty<T.PartyView>();
    var cursor : ?Nat = null;
    label walk loop {
      let pg = rowKeys(s.partyRows, cursor, MAX_PAGE);
      for (id in pg.ids.vals()) List.add(out, view(s, mustGet(s, bb, id)));
      switch (pg.next) { case null break walk; case (?n) cursor := ?n };
    };
    List.toArray(out)
  };

  public type PartyPage = { rows : [T.PartyView]; cursor : ?Nat; total : Nat };

  public func listPartiesPaged(s : State, bb : Blocks, cursor : ?Nat, limit : Nat) : PartyPage {
    let pg = rowKeys(s.partyRows, cursor, pageLimit(limit));
    { rows = Array.map<Nat, T.PartyView>(pg.ids, func(id) { view(s, mustGet(s, bb, id)) }); cursor = pg.next; total = RI.size(s.partyRows) }
  };

  public type CollateralPage = { rows : [T.Collateral]; cursor : ?Nat; total : Nat };

  func mustCollateral(s : State, bb : Blocks, id : T.CollateralId) : CollateralEntry {
    let ?c = getCollateral(s, bb, id) else Runtime.trap("PartyCore: a collateral row without a registration at " # Nat.toText(id));
    c
  };

  public func listCollateralPaged(s : State, bb : Blocks, cursor : ?Nat, limit : Nat) : CollateralPage {
    let pg = rowKeys(s.collateralRows, cursor, pageLimit(limit));
    { rows = Array.map<Nat, T.Collateral>(pg.ids, func(id) { collateralView(mustCollateral(s, bb, id)) }); cursor = pg.next; total = RI.size(s.collateralRows) }
  };

  public type StaffPage = { rows : [T.Staff]; cursor : ?Principal; total : Nat };

  public func listStaffPaged(s : State, cursor : ?Principal, limit : Nat) : StaffPage {
    let n = pageLimit(limit);
    let rows = List.empty<T.Staff>();
    var next : ?Principal = null;
    let it = switch (cursor) {
      case (?c) Map.entriesFrom(s.staff, Principal.compare, c);
      case null Map.entries(s.staff);
    };
    label walk for ((who, x) in it) {
      if (List.size(rows) == n) { next := ?who; break walk };
      List.add(rows, x);
    };
    { rows = List.toArray(rows); cursor = next; total = Map.size(s.staff) }
  };

  public func listLists(s : State) : [T.ScreeningList] {
    Array.map<(Text, T.ScreeningList), T.ScreeningList>(Map.toArray(s.lists), func((_, l)) { l })
  };

  public func listSchemas(s : State) : [T.ExtensionSchema] {
    Array.map<(Text, T.ExtensionSchema), T.ExtensionSchema>(Map.toArray(s.schemas), func((_, x)) { x })
  };

  public func collateralView(c : CollateralEntry) : T.Collateral {
    { id = c.id; party = c.party; kind = c.kind; valuation = c.valuation; descriptionCommit = c.descriptionCommit; registeredAtBlock = c.registeredAtBlock; released = c.released }
  };

  public func listCollateral(s : State, bb : Blocks) : [T.Collateral] {
    let out = List.empty<T.Collateral>();
    var cursor : ?Nat = null;
    label walk loop {
      let pg = rowKeys(s.collateralRows, cursor, MAX_PAGE);
      for (id in pg.ids.vals()) List.add(out, collateralView(mustCollateral(s, bb, id)));
      switch (pg.next) { case null break walk; case (?n) cursor := ?n };
    };
    List.toArray(out)
  };

  public func allocationsOf(s : State, bb : Blocks, id : T.CollateralId) : [T.Allocation] {
    switch (getCollateral(s, bb, id)) { case (?c) c.allocations; case null [] }
  };

  public func listStaff(s : State) : [T.Staff] {
    Array.map<(Principal, T.Staff), T.Staff>(Map.toArray(s.staff), func((_, x)) { x })
  };

  public func listCredentials(s : State) : [T.Credential] {
    Array.map<(Principal, T.Credential), T.Credential>(Map.toArray(s.credentials), func((_, x)) { x })
  };

  public func listJwks(s : State) : [T.Jwks] {
    Array.map<(Text, T.Jwks), T.Jwks>(Map.toArray(s.jwks), func((_, x)) { x })
  };

  // ═══════════════════════════════════════════════════════
  //  FINGERPRINT
  // ═══════════════════════════════════════════════════════

  /// One index into the fingerprint: its size and its row digest (`RegionIndex` improvement 5; the sum of the
  /// rows' hashes, maintained at every `put`), in place of a walk of every row: two states holding the same rows
  /// write the same words, and the cost is one word an index whatever the book's size.
  func fingerprintRows(w : JC.Writer, idx : RI.State) { w.nat(RI.size(idx)); w.blobRaw(RI.digest(idx)) };

  /// Contribute the party sub-state to `BankCore.fingerprint`, so replay equality covers it. The
  /// rows and the indexes are hashed raw: each is a deterministic function of the log, and what a
  /// row points at is in the log the fingerprint is compared across.
  public func fingerprintInto(w : JC.Writer, s : State) {
    w.nat(RI.size(s.partyRows));
    w.nat(s.reviewGraceDays);
    fingerprintRows(w, s.partyRows);
    fingerprintRows(w, s.partyDocuments);
    fingerprintRows(w, s.partyRelationships);
    fingerprintRows(w, s.partyIdentifiers);
    fingerprintRows(w, s.dedupRows);
    fingerprintRows(w, s.identifierRows);
    w.nat(RI.size(s.collateralRows));
    fingerprintRows(w, s.collateralRows);
    fingerprintRows(w, s.collateralAllocations);
    fingerprintRows(w, s.collateralByParty);
    for (n in List.values(s.bookNames)) w.text(n);
    for (n in List.values(s.listNames)) w.text(n);
    for ((_, l) in Map.entries(s.lists)) { w.text(l.version); w.blob(l.root); w.nat(l.count); w.text(l.normalisation); w.nat(l.committedAtBlock) };
    switch (s.newestList) { case null w.byte(0); case (?v) { w.byte(1); w.text(v) } };
    for ((_, sch) in Map.entries(s.schemas)) {
      w.text(sch.id); w.len16(sch.fields.size());
      for (f in sch.fields.vals()) { w.text(f.name); w.text(typeName(f.fieldType)); w.bool(f.required) };
    };
    for ((_, st) in Map.entries(s.staff)) { w.principal(st.principal_); w.text(st.book); w.text(st.title); w.bool(st.status == #active) };
    for ((_, cr) in Map.entries(s.credentials)) { w.principal(cr.subject); w.optNat(cr.revokedAtBlock) };
    for ((_, j) in Map.entries(s.jwks)) { w.text(j.issuer); w.len16(j.keys.size()); for (k in j.keys.vals()) { w.text(k.kid); w.blob(k.n); w.blob(k.e) } };
    switch (s.format) {
      case null w.byte(0);
      case (?f) { w.byte(1); w.text(f.country); w.text(f.bank); w.text(f.branch); w.nat(f.serialWidth); w.text(f.prefix) };
    };
  };
};
