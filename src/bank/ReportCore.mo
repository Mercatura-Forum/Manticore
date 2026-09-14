/// ReportCore.mo; the reporting layer's state, as a fold over its own blocks.
///
/// The reporting layer **reads**. The only state it holds is what was registered or issued:
/// report definitions, return templates, the statement map a deployment declares, the
/// statement register, the hashes of the artefacts that have been certified, the feed's
/// recorded endpoints and its dead letters. No figure is stored anywhere; a report is a
/// fold over the journal at a stated height, which is why a back-dated posting needs no
/// recalculation for any report to be right about the height it names.

import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Map "mo:core/Map";
import Order "mo:core/Order";
import Runtime "mo:core/Runtime";

import RT "ReportTypes";
import Reports "Reports";
import Statements "Statements";

module {

  public type DefEntry = {
    definition : RT.ReportDef;
    hash : Blob;
    registeredAtBlock : Nat;
  };

  public type TemplateEntry = {
    template : RT.ReturnTemplate;
    hash : Blob;
    registeredAtBlock : Nat;
  };

  /// A certified artefact: what it was, and the bytes' hash that went into the certified
  /// tree. Keyed by (kind, id, book, period, height) so re-certifying the same report at the
  /// same height is the same entry rather than a second one.
  public type CertifiedEntry = {
    kind : Text;
    id : Text;
    book : Text;
    period : Text;
    atHeight : Nat;
    contentHash : Blob;
    rows : Nat;
    certifiedAtBlock : Nat;
  };

  public type StatementEntry = {
    statement : RT.StatementRef;
    issuedAtBlock : Nat;
  };

  public type State = {
    /// (id, version) -> the definition. A version is immutable once registered, so "report
    /// R34 version 2" names exact arithmetic for ever.
    defs : Map.Map<(Text, Nat), DefEntry>;
    templates : Map.Map<(Text, Nat), TemplateEntry>;
    maps : Map.Map<Text, RT.StatementMap>;
    /// The statement register, keyed as `Statements.registerKey`: a re-issued statement is
    /// identifiably the same statement.
    statements : Map.Map<Text, StatementEntry>;
    certified : Map.Map<Text, CertifiedEntry>;
    endpoints : Map.Map<Text, RT.FeedEndpoint>;
    deadLetters : List.List<RT.DeadLetter>;
  };

  func cmpTN(a : (Text, Nat), b : (Text, Nat)) : Order.Order {
    switch (Text.compare(a.0, b.0)) { case (#equal) Nat.compare(a.1, b.1); case (o) o }
  };

  public func newState() : State {
    {
      defs = Map.empty<(Text, Nat), DefEntry>();
      templates = Map.empty<(Text, Nat), TemplateEntry>();
      maps = Map.empty<Text, RT.StatementMap>();
      statements = Map.empty<Text, StatementEntry>();
      certified = Map.empty<Text, CertifiedEntry>();
      endpoints = Map.empty<Text, RT.FeedEndpoint>();
      deadLetters = List.empty<RT.DeadLetter>();
    }
  };

  public type Event = RT.ReportEvent;

  // ═══════════════════════════════════════════════════════
  //  LOOKUPS
  // ═══════════════════════════════════════════════════════

  public func getDef(s : State, id : Text, version : Nat) : ?DefEntry {
    Map.get(s.defs, cmpTN, (id, version))
  };

  /// The highest version registered for a definition, which is what a caller naming no
  /// version means.
  public func latestDef(s : State, id : Text) : ?DefEntry {
    var best : ?DefEntry = null;
    for (((i, v), e) in Map.entries(s.defs)) {
      if (Text.equal(i, id)) {
        switch (best) {
          case null best := ?e;
          case (?b) { if (v > b.definition.version) best := ?e };
        };
      };
    };
    best
  };

  public func getTemplate(s : State, id : Text, version : Nat) : ?TemplateEntry {
    Map.get(s.templates, cmpTN, (id, version))
  };

  public func latestTemplate(s : State, id : Text) : ?TemplateEntry {
    var best : ?TemplateEntry = null;
    for (((i, v), e) in Map.entries(s.templates)) {
      if (Text.equal(i, id)) {
        switch (best) {
          case null best := ?e;
          case (?b) { if (v > b.template.version) best := ?e };
        };
      };
    };
    best
  };

  public func statementMap(s : State, book : Text) : ?RT.StatementMap { Map.get(s.maps, Text.compare, book) };

  public func getStatement(s : State, key : Text) : ?StatementEntry { Map.get(s.statements, Text.compare, key) };

  /// The register key of a certified artefact.
  ///
  /// It includes the **content hash**, because the hash is what distinguishes two artefacts that
  /// share a kind, an identifier, a book, a period and a height but not their parameters; the
  /// native and the functional view of one report, say. Keying without it would file two
  /// different artefacts under one entry and lose one of them; including it makes
  /// re-certification of the identical artefact idempotent and certification of a different one
  /// a new entry, which is the behaviour a reader needs from a register.
  public func certifiedKey(kind : Text, id : Text, book : Text, period : Text, atHeight : Nat, contentHash : Blob) : Text {
    kind # "|" # id # "|" # book # "|" # period # "|" # Nat.toText(atHeight) # "|" # hex(contentHash)
  };

  let HEX : [Text] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];

  func hex(b : Blob) : Text {
    var out = "";
    for (x in b.vals()) { let n = Nat8.toNat(x); out #= HEX[n / 16] # HEX[n % 16] };
    out
  };

  public func getCertified(s : State, key : Text) : ?CertifiedEntry { Map.get(s.certified, Text.compare, key) };

  public func endpoint(s : State, url : Text) : ?RT.FeedEndpoint { Map.get(s.endpoints, Text.compare, url) };

  public func activeEndpoints(s : State) : [RT.FeedEndpoint] {
    let out = List.empty<RT.FeedEndpoint>();
    for ((_, e) in Map.entries(s.endpoints)) { if (e.active) List.add(out, e) };
    List.toArray(out)
  };

  public func defCount(s : State) : Nat { Map.size(s.defs) };
  public func templateCount(s : State) : Nat { Map.size(s.templates) };
  public func statementCount(s : State) : Nat { Map.size(s.statements) };
  public func certifiedCount(s : State) : Nat { Map.size(s.certified) };
  public func endpointCount(s : State) : Nat { Map.size(s.endpoints) };
  public func deadLetterCount(s : State) : Nat { List.size(s.deadLetters) };
  public func deadLetters(s : State) : [RT.DeadLetter] { List.toArray(s.deadLetters) };

  public func listDefs(s : State) : [RT.ReportDef] {
    let out = List.empty<RT.ReportDef>();
    for ((_, e) in Map.entries(s.defs)) List.add(out, e.definition);
    List.toArray(out)
  };

  public func listTemplates(s : State) : [RT.ReturnTemplate] {
    let out = List.empty<RT.ReturnTemplate>();
    for ((_, e) in Map.entries(s.templates)) List.add(out, e.template);
    List.toArray(out)
  };

  /// One page of the issued statements, by key from a cursor (inclusive).
  public func statementsFrom(s : State, cursor : ?Text, limit : Nat) : { rows : [RT.StatementRef]; next : ?Text } {
    let rows = List.empty<RT.StatementRef>();
    let it = switch (cursor) { case (?c) Map.entriesFrom(s.statements, Text.compare, c); case null Map.entries(s.statements) };
    for ((k, e) in it) { if (List.size(rows) >= limit) return { rows = List.toArray(rows); next = ?k }; List.add(rows, e.statement) };
    { rows = List.toArray(rows); next = null }
  };
  /// One page of the certified artefacts, by key from a cursor (inclusive).
  public func certifiedFrom(s : State, cursor : ?Text, limit : Nat) : { rows : [CertifiedEntry]; next : ?Text } {
    let rows = List.empty<CertifiedEntry>();
    let it = switch (cursor) { case (?c) Map.entriesFrom(s.certified, Text.compare, c); case null Map.entries(s.certified) };
    for ((k, e) in it) { if (List.size(rows) >= limit) return { rows = List.toArray(rows); next = ?k }; List.add(rows, e) };
    { rows = List.toArray(rows); next = null }
  };
  /// One page of the dead letters, by position from a cursor (inclusive).
  public func deadLettersFrom(s : State, cursor : ?Nat, limit : Nat) : { rows : [RT.DeadLetter]; next : ?Nat } {
    let rows = List.empty<RT.DeadLetter>();
    var i = switch (cursor) { case (?c) c; case null 0 };
    let n = List.size(s.deadLetters);
    while (i < n) { if (List.size(rows) >= limit) return { rows = List.toArray(rows); next = ?i }; List.add(rows, List.at(s.deadLetters, i)); i += 1 };
    { rows = List.toArray(rows); next = null }
  };
  public func listStatements(s : State) : [RT.StatementRef] {
    let out = List.empty<RT.StatementRef>();
    for ((_, e) in Map.entries(s.statements)) List.add(out, e.statement);
    List.toArray(out)
  };

  public func listCertified(s : State) : [CertifiedEntry] {
    let out = List.empty<CertifiedEntry>();
    for ((_, e) in Map.entries(s.certified)) List.add(out, e);
    List.toArray(out)
  };

  // ═══════════════════════════════════════════════════════
  //  THE FOLD
  // ═══════════════════════════════════════════════════════

  public func apply(s : State, blockIndex : Nat, e : Event) {
    switch (e) {
      case (#reportDefinitionRegistered(x)) {
        Map.add(s.defs, cmpTN, (x.definition.id, x.definition.version), {
          definition = x.definition; hash = x.hash; registeredAtBlock = blockIndex;
        });
      };
      case (#returnTemplateRegistered(x)) {
        Map.add(s.templates, cmpTN, (x.template.id, x.template.version), {
          template = x.template; hash = x.hash; registeredAtBlock = blockIndex;
        });
      };
      case (#statementMapSet(x)) { Map.add(s.maps, Text.compare, x.book, x.map) };
      case (#reportCertified(x)) {
        let key = certifiedKey(x.kind, x.id, x.book, x.period, x.atHeight, x.contentHash);
        Map.add(s.certified, Text.compare, key, {
          kind = x.kind; id = x.id; book = x.book; period = x.period;
          atHeight = x.atHeight; contentHash = x.contentHash; rows = x.rows;
          certifiedAtBlock = blockIndex;
        });
      };
      case (#statementIssued(x)) {
        let key = Statements.registerKey(x.statement.account, x.statement.kind);
        // A re-issue is the same statement with its issue count raised, which is what makes
        // "this is the statement you were sent in April" answerable.
        let issued = switch (Map.get(s.statements, Text.compare, key)) {
          case (?prev) prev.statement.issued + 1;
          case null 1;
        };
        Map.add(s.statements, Text.compare, key, {
          statement = { x.statement with issued };
          issuedAtBlock = blockIndex;
        });
      };
      case (#feedEndpointSet(x)) { Map.add(s.endpoints, Text.compare, x.endpoint.url, x.endpoint) };
      case (#feedDeadLettered(x)) {
        if (List.size(s.deadLetters) < RT.MAX_DEAD_LETTERS) List.add(s.deadLetters, x.letter);
      };
    };
  };

  // ═══════════════════════════════════════════════════════
  //  THE ARTEFACT ROOT
  // ═══════════════════════════════════════════════════════

  /// A root over every certified artefact, as a fold over the entries in key order; so it
  /// is a function of the state rather than of the order the blocks arrived in.
  ///
  /// This is **not** a new leaf in the certified tree, and deliberately. A report's content
  /// hash is recorded in a `#reportCertified` bank block, and the bank's MMR root over every
  /// bank block is already in the certified tree. So the artefact that leaves the building is
  /// proven exactly as a posting is: fetch its block, fetch the block's inclusion proof, and
  /// verify the proof against the certified bank root. Adding a third leaf would add a second
  /// thing to keep in step with the first and prove nothing the first does not already.
  ///
  /// What this root is for is the state fingerprint below, which an upgrade is checked
  /// against element by element.
  public func artefactRoot(s : State) : Blob {
    let keys = List.empty<Text>();
    for ((k, _) in Map.entries(s.certified)) List.add(keys, k);
    let sorted = Array.sort<Text>(List.toArray(keys), Text.compare);
    let w = Reports.certifiedRootWriter();
    for (k in sorted.vals()) {
      let ?e = Map.get(s.certified, Text.compare, k) else Runtime.trap("ReportCore: a certified entry vanished");
      w.text(k);
      w.blob(e.contentHash);
      w.nat(e.atHeight);
      w.nat(e.rows);
    };
    w.digest()
  };

  // ═══════════════════════════════════════════════════════
  //  THE FINGERPRINT
  // ═══════════════════════════════════════════════════════

  /// Everything this layer holds, in one hash, so an upgrade is checked element by element
  /// rather than by looking at a few fields.
  public func fingerprint(s : State) : Blob {
    let w = Reports.certifiedRootWriter();
    w.text("thebes.bank.report.state.v1");
    let defKeys = List.empty<Text>();
    for (((i, v), _) in Map.entries(s.defs)) List.add(defKeys, i # "|" # Nat.toText(v));
    for (k in Array.sort<Text>(List.toArray(defKeys), Text.compare).vals()) w.text(k);
    let tKeys = List.empty<Text>();
    for (((i, v), _) in Map.entries(s.templates)) List.add(tKeys, i # "|" # Nat.toText(v));
    for (k in Array.sort<Text>(List.toArray(tKeys), Text.compare).vals()) w.text(k);
    for ((b, m) in Map.entries(s.maps)) { w.text(b); w.text(m.retainedEarnings); w.nat(m.cash.size()) };
    let sKeys = List.empty<Text>();
    for ((k, e) in Map.entries(s.statements)) List.add(sKeys, k # "|" # Nat.toText(e.statement.issued));
    for (k in Array.sort<Text>(List.toArray(sKeys), Text.compare).vals()) w.text(k);
    w.blob(artefactRoot(s));
    for ((u, e) in Map.entries(s.endpoints)) { w.text(u); w.byte(if (e.active) 1 else 0) };
    w.nat(List.size(s.deadLetters));
    w.digest()
  };
};
