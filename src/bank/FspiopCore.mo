/// FspiopCore.mo — the FSPIOP v1.1 adapter's state and its planning.
///
/// State: the participant directory per rail (FSP id ↔ participant, callback endpoints per type),
/// the account-lookup oracle (party identifier → FSP), the quotes recorded on their way through, and
/// every FSPIOP transfer bound to its settlement transfer with the ILP condition it must be fulfilled
/// against. All of it derived from the bank's blocks and rebuilt by replay.
///
/// Planning: `handle` reads one request — method, path, headers, JSON body — validates it the way the
/// specification does (the mandatory elements, the data types' patterns, the FSPIOP headers, the
/// content type's resource and version) and says what it is: a synchronous refusal with the error
/// shape, a routing (a forward to the destination FSP), or an act on the settlement layer (a transfer
/// to prepare, to post against its condition, or to abort). The actor performs the act and answers
/// with the specification's status and the callbacks the relay delivers.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import Int "mo:core/Int";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import CivilDate "mo:journal/CivilDate";
import RI "mo:ledger/RegionIndex";

import FT "FspiopTypes";
import ST "SettlementTypes";
import SC "SettlementCore";
import Json "Json";
import Base64 "Base64";
import Rx "Rx";
import Runtime "mo:core/Runtime";
import FS "FspiopSchema";
import FP "FspiopProfiles";
import R "StableRows";

module {

  public type Blocks = { get : Nat -> ?FT.FspiopEvent };

  /// condition(32) ‖ transfer(8) ‖ state(1: 1 reserved, 2 committed, 3 aborted) ‖ the block of the
  /// fulfilment or the abort(8) — so a status answer finds the fulfilment without scanning the log
  public let TRANSFER_ROW : Nat = 49;
  /// condition(32) ‖ transferAmount(16) ‖ answered(1)
  public let QUOTE_ROW : Nat = 49;

  public type Participant = { rail : Text; participant : Nat; fspId : FT.FspId; endpoints : [(Text, Text)]; declaredAt : Nat };
  public type Party = { fspId : FT.FspId; currency : ?Text; registeredAt : Nat };

  public type State = {
    byFspId : Map.Map<(Text, FT.FspId), Participant>;
    byParticipant : Map.Map<(Text, Nat), FT.FspId>;
    parties : Map.Map<Text, Party>;          // "rail|type|id|subId"
    transfers : RI.State;                    // sha256(rail ‖ transferId)(32) -> TRANSFER_ROW
    quotes : RI.State;                       // sha256(rail ‖ quoteId)(32) -> QUOTE_ROW
    var requests : Nat;
    var refused : Nat;
    var forwarded : Nat;
  };

  public func newState(arena : RI.Arena) : State {
    {
      byFspId = Map.empty<(Text, FT.FspId), Participant>();
      byParticipant = Map.empty<(Text, Nat), FT.FspId>();
      parties = Map.empty<Text, Party>();
      transfers = RI.newStateIn(arena, { keyBytes = 32; valBytes = TRANSFER_ROW });
      quotes = RI.newStateIn(arena, { keyBytes = 32; valBytes = QUOTE_ROW });
      var requests = 0; var refused = 0; var forwarded = 0;
    }
  };

  func cmpTT(a : (Text, Text), b : (Text, Text)) : { #less; #equal; #greater } { switch (Text.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o } };
  func cmpTN(a : (Text, Nat), b : (Text, Nat)) : { #less; #equal; #greater } { switch (Text.compare(a.0, b.0)) { case (#equal) Nat.compare(a.1, b.1); case (o) o } };
  func key2(a : Text, b : Text) : Blob { let w = C.Writer(); w.text(a); w.text(b); Sha256.fromBlob(#sha256, w.toBlob()) };
  func partyKey(rail : Text, idType : Text, id : Text, subId : ?Text) : Text { rail # "|" # idType # "|" # id # "|" # (switch (subId) { case (?s) s; case null "" }) };

  // ─── reads ───

  public func participantOfFsp(s : State, rail : Text, fspId : FT.FspId) : ?Participant { Map.get(s.byFspId, cmpTT, (rail, fspId)) };
  public func fspOfParticipant(s : State, rail : Text, participant : Nat) : ?FT.FspId { Map.get(s.byParticipant, cmpTN, (rail, participant)) };
  public func endpoint(s : State, rail : Text, fspId : FT.FspId, endpointType : Text) : ?Text {
    switch (participantOfFsp(s, rail, fspId)) { case (?p) { for ((t, u) in p.endpoints.vals()) { if (t == endpointType) return ?u }; null }; case null null }
  };
  public func party(s : State, rail : Text, idType : Text, id : Text, subId : ?Text) : ?Party { Map.get(s.parties, Text.compare, partyKey(rail, idType, id, subId)) };
  public func participants(s : State, rail : Text) : [Participant] {
    Array.filter<Participant>(Array.map<((Text, Text), Participant), Participant>(Map.toArray(s.byFspId), func((_, p)) { p }), func(p) { p.rail == rail })
  };
  public type TransferRow = { condition : Blob; transfer : Nat; state : Nat8; resolvedAt : Nat };
  public func transferOf(s : State, rail : Text, transferId : Text) : ?TransferRow {
    switch (RI.get(s.transfers, key2(rail, transferId))) {
      case (?v) { let a = Blob.toArray(v); ?{ condition = R.getBlob(a, 0, 32); transfer = R.getNat(a, 32, 8); state = a[40]; resolvedAt = R.getNat(a, 41, 8) } };
      case null null;
    }
  };
  public func quoteOf(s : State, rail : Text, quoteId : Text) : ?{ condition : Blob; transferAmount : Nat; answered : Bool } {
    switch (RI.get(s.quotes, key2(rail, quoteId))) {
      case (?v) { let a = Blob.toArray(v); ?{ condition = R.getBlob(a, 0, 32); transferAmount = R.getNat(a, 32, 16); answered = a[48] == 1 } };
      case null null;
    }
  };
  public func counts(s : State) : { participants : Nat; parties : Nat; transfers : Nat; quotes : Nat; requests : Nat; refused : Nat; forwarded : Nat } {
    { participants = Map.size(s.byFspId); parties = Map.size(s.parties); transfers = RI.size(s.transfers); quotes = RI.size(s.quotes); requests = s.requests; refused = s.refused; forwarded = s.forwarded }
  };

  // ─── configuration ───

  public func planDeclareParticipant(s : State, sc : SC.State, rails : Text -> ?ST.SchemeId, x : { rail : Text; participant : Nat; fspId : FT.FspId; endpoints : [(Text, Text)] }) : Result.Result<FT.FspiopEvent, FT.FspiopError> {
    let ?scheme = rails(x.rail) else return #err(#UnknownRail({ rail = x.rail }));
    let ?p = SC.participant(sc, x.participant) else return #err(#UnknownParticipant({ participant = x.participant }));
    if (p.scheme != scheme) return #err(#UnknownParticipant({ participant = x.participant }));
    let n = Text.size(x.fspId);
    if (n == 0 or n > 32) return #err(#InvalidEndpoint({ reason = "an FSP id is 1..32 characters" }));
    switch (Map.get(s.byFspId, cmpTT, (x.rail, x.fspId))) { case (?q) { if (q.participant != x.participant) return #err(#FspIdTaken({ rail = x.rail; fspId = x.fspId })) }; case null {} };
    for ((t, u) in x.endpoints.vals()) {
      var known = false;
      for (k in FT.ENDPOINT_TYPES.vals()) { if (k == t) known := true };
      if (not known) return #err(#InvalidEndpoint({ reason = "endpoint type " # t # " is not one of the reference's " # Nat.toText(FT.ENDPOINT_TYPES.size()) }));
      if (Text.size(u) == 0 or Text.size(u) > 512) return #err(#InvalidEndpoint({ reason = "an endpoint value is 1..512 characters" }));
    };
    #ok(#participantDeclared({ rail = x.rail; participant = x.participant; fspId = x.fspId; endpoints = x.endpoints }))
  };

  // ─── the request ───

  public type Act = {
    #respond : { status : Nat; body : Text };
    #forward : { destination : FT.FspId; method : Text; path : Text; body : Text; events : [FT.FspiopEvent] };
    #prepareTransfer : { transferId : Text; payerFsp : FT.FspId; payeeFsp : FT.FspId; payer : Nat; payee : Nat; currency : Text; amount : Nat; condition : Blob; ilpPacketHash : Blob; expiration : Text; ttlSeconds : Nat; body : Text };
    #fulfilTransfer : { transferId : Text; transfer : Nat; payerFsp : FT.FspId; payeeFsp : FT.FspId; fulfilment : Blob; conditionMet : Bool; completedTimestamp : Text; body : Text };
    #abortTransfer : { transferId : Text; transfer : Nat; payerFsp : FT.FspId; payeeFsp : FT.FspId; errorCode : Text; reason : Text; body : Text };
    #transferStatus : { transferId : Text; transfer : Nat; requester : FT.FspId };
  };

  public type Planned = { act : Act; source : ?FT.FspId; destination : ?FT.FspId; method : Text; path : Text };

  /// The specification's ErrorInformation: the code and a description of at most 128 characters
  /// (ErrorDescription maxLength) — the detail is cut, never the shape broken.
  public func errorBody(code : Text, detail : Text) : Text {
    let full = FT.errorText(code) # " - " # detail;
    let desc = if (Text.size(full) <= 128) full else { var out = ""; var k = 0; for (c in full.chars()) { if (k < 127) out #= Char.toText(c); k += 1 }; out # "…" };
    Json.emit(#object_([("errorInformation", #object_([("errorCode", #string(code)), ("errorDescription", #string(desc))]))]))
  };

  func header(req : FT.Request, name : Text) : ?Text {
    let want = Text.toLower(name);
    for ((k, v) in req.headers.vals()) { if (Text.toLower(k) == want) return ?v };
    null
  };

  func segments(path : Text) : [Text] {
    let q = switch (Text.split(path, #char '?').next()) { case (?p) p; case null path };
    Array.filter<Text>(Array.fromIter<Text>(Text.split(q, #char '/')), func(x) { Text.size(x) > 0 })
  };

  // the specification's patterns (fspiop-rest-v1.1-openapi3-snippets: CorrelationId, Amount, IlpCondition,
  // DateTime); a pattern outside Rx's subset is a defect of this module and traps, never a silent mismatch
  let UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
  let AMOUNT = "([0]|([1-9][0-9]{0,17}))([.][0-9]{0,3}[1-9])?";
  let B64_43 = "[A-Za-z0-9\\-_]{43}";
  let B64_ANY = "[A-Za-z0-9\\-_]+[=]{0,2}";
  let DATE_TIME = "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})";

  func matches(pattern : Text, value : Text) : Bool {
    switch (Rx.compile(pattern)) { case (#ok(p)) Rx.matches(p, value); case (#err(m)) Runtime.trap("FspiopCore: " # m # " in " # pattern) }
  };

  /// The FSPIOP `Amount` string in minor units of its currency; null when it is not a canonical
  /// amount or carries more decimals than the currency has.
  public func amountMinor(text : Text, minorUnits : Nat8) : ?Nat {
    if (not matches(AMOUNT, text)) return null;
    let parts = Array.fromIter<Text>(Text.split(text, #char '.'));
    var v = 0;
    for (c in parts[0].chars()) v := v * 10 + Nat32.toNat(Char.toNat32(c) - 48);
    var fd = 0;
    if (parts.size() == 2) { for (c in parts[1].chars()) { fd += 1; if (fd > Nat8.toNat(minorUnits)) return null; v := v * 10 + Nat32.toNat(Char.toNat32(c) - 48) } };
    while (fd < Nat8.toNat(minorUnits)) { v *= 10; fd += 1 };
    ?v
  };

  /// Minor units to the canonical FSPIOP `Amount`: no trailing zeros in the fraction.
  public func amountText(minor : Nat, minorUnits : Nat8) : Text {
    let mu = Nat8.toNat(minorUnits);
    var scale = 1; var i = 0; while (i < mu) { scale *= 10; i += 1 };
    let whole = Nat.toText(minor / scale);
    if (mu == 0) return whole;
    var frac = Nat.toText(minor % scale);
    while (Text.size(frac) < mu) frac := "0" # frac;
    frac := Text.trimEnd(frac, #char '0');
    if (Text.size(frac) == 0) whole else whole # "." # frac
  };

  /// An FSPIOP DateTime to nanoseconds since the epoch (UTC), for the expiration.
  public func dateTimeNanos(t : Text) : ?Nat64 {
    if (not matches(DATE_TIME, t)) return null;
    let cs = Text.toArray(t);
    func num(from : Nat, len : Nat) : Nat { var v = 0; var i = 0; while (i < len) { v := v * 10 + Nat32.toNat(Char.toNat32(cs[from + i]) - 48); i += 1 }; v };
    let ?day = CivilDate.fromCivil(num(0, 4), num(5, 2), num(8, 2)) else return null;
    let secs = num(11, 2) * 3600 + num(14, 2) * 60 + num(17, 2);
    // fraction and zone
    var i = 19;
    var fracNanos = 0;
    if (i < cs.size() and cs[i] == '.') { i += 1; var digits = 0; var f = 0; while (i < cs.size() and Char.isDigit(cs[i])) { if (digits < 9) { f := f * 10 + Nat32.toNat(Char.toNat32(cs[i]) - 48); digits += 1 }; i += 1 }; while (digits < 9) { f *= 10; digits += 1 }; fracNanos := f };
    var offset : Int = 0;
    if (i < cs.size() and cs[i] != 'Z') { let sign : Int = if (cs[i] == '-') -1 else 1; offset := sign * (num(i + 1, 2) * 3600 + num(i + 4, 2) * 60) };
    let total : Int = (day * 86_400 + secs) - offset;
    if (total < 0) return null;
    ?(Nat64.fromNat(Int.abs(total)) * 1_000_000_000 + Nat64.fromNat(fracNanos))
  };

  public func nanosToDateTime(ns : Nat64) : Text {
    let secs = Nat64.toNat(ns / 1_000_000_000);
    let ms = Nat64.toNat(ns % 1_000_000_000) / 1_000_000;
    func two(n : Nat) : Text { if (n < 10) "0" # Nat.toText(n) else Nat.toText(n) };
    func three(n : Nat) : Text { if (n < 10) "00" # Nat.toText(n) else if (n < 100) "0" # Nat.toText(n) else Nat.toText(n) };
    let rem = secs % 86_400;
    CivilDate.toText(secs / 86_400) # "T" # two(rem / 3600) # ":" # two(rem % 3600 / 60) # ":" # two(rem % 60) # "." # three(ms) # "Z"
  };

  /// The content type's resource and version: `application/vnd.interoperability.<resource>+json;version=1.1`.
  func contentTypeOk(req : FT.Request, resource : Text) : ?Text {
    switch (header(req, "Content-Type")) {
      case null null;   // absent is allowed (a GET, or a relay that sets it downstream)
      case (?ct) {
        let lower = Text.toLower(ct);
        if (not Text.startsWith(lower, #text "application/vnd.interoperability.")) return ?"3001";
        let rest = Text.trimStart(lower, #text "application/vnd.interoperability.");
        let res = switch (Text.split(rest, #char '+').next()) { case (?r) r; case null "" };
        if (res != Text.toLower(resource)) return ?"3001";
        if (not Text.contains(lower, #text "version=1.")) return ?"3001";
        null
      };
    }
  };

  /// The endpoint type (central-ledger's `endpointType` names) a callback of this method and path is
  /// delivered to: the resource, whether the path carries a SubId, whether it is an `/error` — the
  /// reference's own selection (account-lookup-service `getCallbackEndpointTypes`, ml-api-adapter's
  /// notification handler).
  public func endpointTypeFor(method : Text, path : Text) : Text {
    let segs = segments(path);
    if (segs.size() == 0) return "FSPIOP_CALLBACK_URL_TRX_REQ_SERVICE";
    let isError = segs[segs.size() - 1] == "error";
    let n = if (isError) segs.size() - 1 else segs.size();   // segments without the trailing /error
    switch (segs[0]) {
      case ("transfers") { if (isError) "FSPIOP_CALLBACK_URL_TRANSFER_ERROR" else if (method == "POST") "FSPIOP_CALLBACK_URL_TRANSFER_POST" else "FSPIOP_CALLBACK_URL_TRANSFER_PUT" };
      case ("participants") {
        // the reference's account lookup answers a DELETE with a PUT to the same PARTICIPANT_PUT endpoint
        let sub = n == 4;   // /participants/{Type}/{ID}/{SubId}
        if (isError) { if (sub) "FSPIOP_CALLBACK_URL_PARTICIPANT_SUB_ID_PUT_ERROR" else "FSPIOP_CALLBACK_URL_PARTICIPANT_PUT_ERROR" }
        else { if (sub) "FSPIOP_CALLBACK_URL_PARTICIPANT_SUB_ID_PUT" else "FSPIOP_CALLBACK_URL_PARTICIPANT_PUT" }
      };
      case ("parties") {
        let sub = n == 4;
        if (isError) { if (sub) "FSPIOP_CALLBACK_URL_PARTIES_SUB_ID_PUT_ERROR" else "FSPIOP_CALLBACK_URL_PARTIES_PUT_ERROR" }
        else if (method == "GET") { if (sub) "FSPIOP_CALLBACK_URL_PARTIES_SUB_ID_GET" else "FSPIOP_CALLBACK_URL_PARTIES_GET" }
        else { if (sub) "FSPIOP_CALLBACK_URL_PARTIES_SUB_ID_PUT" else "FSPIOP_CALLBACK_URL_PARTIES_PUT" }
      };
      case ("quotes") "FSPIOP_CALLBACK_URL_QUOTES";
      case ("bulkQuotes") "FSPIOP_CALLBACK_URL_BULK_QUOTES";
      case ("bulkTransfers") { if (isError) "FSPIOP_CALLBACK_URL_BULK_TRANSFER_ERROR" else if (method == "POST") "FSPIOP_CALLBACK_URL_BULK_TRANSFER_POST" else "FSPIOP_CALLBACK_URL_BULK_TRANSFER_PUT" };
      case ("authorizations") "FSPIOP_CALLBACK_URL_AUTHORIZATIONS";
      case (_) "FSPIOP_CALLBACK_URL_TRX_REQ_SERVICE";
    }
  };

  /// The largest request body accepted (UTF-8 bytes): 3104 beyond it.
  public let MAX_BODY : Nat = 1_048_576;

  func implemented(method : Text, template : Text) : Bool { for ((m, p) in FT.IMPLEMENTED.vals()) { if (m == method and p == template) return true }; false };

  func fail(code : Text, detail : Text, method : Text, path : Text, source : ?Text, destination : ?Text) : Planned {
    { act = #respond({ status = FT.errorStatus(code); body = errorBody(code, detail) }); source; destination; method; path }
  };

  /// Read the request and say what it asks for.
  public func handle(s : State, sc : SC.State, rail : Text, scheme : ST.SchemeId, ttlSeconds : Nat, req : FT.Request, now : Nat64, minorUnitsOf : Text -> ?Nat8) : Planned {
    let method = Text.toUpper(req.method);
    let segs = segments(req.path);
    let source = header(req, "FSPIOP-Source");
    let destination = header(req, "FSPIOP-Destination");
    var path = "";
    for (sg in segs.vals()) path #= "/" # sg;
    func f(code : Text, detail : Text) : Planned { fail(code, detail, method, path, source, destination) };
    if (segs.size() == 0) return f("3002", "no resource in the path");
    let resource = segs[0];
    switch (source) { case null return f("3102", "the FSPIOP-Source header is mandatory"); case (?sname) { if (Text.size(sname) == 0 or Text.size(sname) > 32) return f("3100", "FSPIOP-Source is 1..32 characters") } };
    let ?src = source else return f("3102", "FSPIOP-Source");
    switch (contentTypeOk(req, resource)) { case (?code) return f(code, "the Content-Type names another resource or version than " # resource # " v1"); case null {} };
    // the operation the specification defines for this method and path; its request schema is enforced
    // before any business rule, and a path or method outside the API is refused by code
    let ?op = FS.operation(method, path) else {
      // a path of the API with another method: 405 Method Not Allowed (Table 4), the generic client error code
      if (FS.pathKnown(path)) return { act = #respond({ status = 405; body = errorBody("3000", method # " is not an operation of " # path # " in FSPIOP v1.1") }); source; destination; method; path };
      return f("3002", method # " " # path # " is not a resource of FSPIOP v1.1");
    };
    if (not implemented(method, op.path)) return f("2002", op.operationId # " (" # method # " " # op.path # ") is not implemented by this switch");
    let body : ?Json.Json = switch (op.request) {
      case (?schemaName) {
        if (req.body.size() > MAX_BODY) return f("3104", "the body is " # Nat.toText(req.body.size()) # " bytes, at most " # Nat.toText(MAX_BODY) # " accepted");
        let j = switch (Json.parse(req.body)) { case (#ok(j)) j; case (#err(e)) return f("3101", "the body is not JSON: " # e) };
        let issues = FS.validate(schemaName, j);
        if (issues.size() > 0) {
          let i0 = issues[0];
          var detail = i0.path # ": " # i0.detail;
          if (issues.size() > 1) detail #= " (and " # Nat.toText(issues.size() - 1) # " more)";
          // the specification's codes for the kinds of defect it names; the generic validation error otherwise
          let code = switch (i0.rule) { case ("FSPIOP-JSON-REQUIRED") "3102"; case ("FSPIOP-JSON-ITEMS") { if (Text.contains(i0.detail, #text "at most")) "3103" else "3100" }; case (_) "3100" };
          return f(code, schemaName # " " # detail);
        };
        ?j
      };
      case null null;
    };
    func need(j : Json.Json, k : Text) : ?Text { Json.str(j, k) };
    func forwardTo(dest : Text, events : [FT.FspiopEvent]) : Planned {
      if (participantOfFsp(s, rail, dest) == null) return f("3201", "destination FSP " # dest # " is not a participant of rail " # rail);
      { act = #forward({ destination = dest; method; path; body = req.body; events }); source; destination; method; path }
    };
    switch (resource, method) {
      // ── the account-lookup oracle ──
      case ("participants", "POST" or "GET" or "DELETE") {
        if (segs.size() < 3 or segs.size() > 4) return f("3002", "participants takes /{Type}/{ID}[/{SubId}]");
        let idType = segs[1]; let id = segs[2]; let subId = if (segs.size() == 4) ?segs[3] else null;
        var known = false; for (t in FT.PARTY_ID_TYPES.vals()) { if (t == idType) known := true };
        if (not known) return f("3100", "party identifier type " # idType # " is not one of the specification's");
        if (Text.size(id) == 0 or Text.size(id) > 128) return f("3100", "a party identifier is 1..128 characters");
        let cbPath = path;
        if (method == "POST") {
          let ?j = body else return f("3102", "a body");
          let ?fsp = need(j, "fspId") else return f("3102", "fspId");
          if (participantOfFsp(s, rail, fsp) == null) return f("3003", "fspId " # fsp # " is not a participant of rail " # rail);
          let ccy = need(j, "currency");
          let ev = #partyRegistered({ rail; idType; id; subId; fspId = fsp; currency = ccy });
          // the oracle answers the registering FSP with the PUT of what it holds
          let cb = Json.emit(#object_([("fspId", #string(fsp))]));
          return { act = #forward({ destination = src; method = "PUT"; path = cbPath; body = cb; events = [ev] }); source; destination; method; path };
        };
        switch (party(s, rail, idType, id, subId)) {
          case null return f("3204", "no FSP holds " # idType # " " # id);
          case (?p) {
            if (method == "DELETE") {
              return { act = #forward({ destination = src; method = "PUT"; path = cbPath; body = Json.emit(#object_([("fspId", #string(p.fspId))])); events = [#partyDeregistered({ rail; idType; id; subId })] }); source; destination; method; path };
            };
            return { act = #forward({ destination = src; method = "PUT"; path = cbPath; body = Json.emit(#object_([("fspId", #string(p.fspId))])); events = [] }); source; destination; method; path };
          };
        };
      };
      // ── parties: routed to the FSP the oracle names, or to the destination the request names ──
      case ("parties", "GET") {
        if (segs.size() < 3 or segs.size() > 4) return f("3002", "parties takes /{Type}/{ID}[/{SubId}]");
        let dest = switch (destination) {
          case (?d) d;
          case null { switch (party(s, rail, segs[1], segs[2], if (segs.size() == 4) ?segs[3] else null)) { case (?p) p.fspId; case null return f("3204", "no FSP holds " # segs[1] # " " # segs[2]) } };
        };
        forwardTo(dest, [])
      };
      case ("parties", "PUT") {
        let ?dest = destination else return f("3102", "the FSPIOP-Destination header names the requester a PUT answers");
        forwardTo(dest, [])
      };
      // ── quotes: recorded on their way through ──
      case ("quotes", "POST") {
        let ?j = body else return f("3102", "a body");
        let ?quoteId = need(j, "quoteId") else return f("3102", "quoteId");
        if (not matches(UUID, quoteId)) return f("3100", "quoteId is not a UUID");
        let ?transactionId = need(j, "transactionId") else return f("3102", "transactionId");
        let ?amountType = need(j, "amountType") else return f("3102", "amountType");
        let ?amt = Json.obj(j, "amount") else return f("3102", "amount");
        let ?ccy = need(amt, "currency") else return f("3102", "amount.currency");
        let ?mu = minorUnitsOf(ccy) else return f("3100", "currency " # ccy # " is not one the scheme settles");
        let ?a = need(amt, "amount") else return f("3102", "amount.amount");
        let ?minor = amountMinor(a, mu) else return f("3100", "amount " # a # " is not a canonical Amount in " # ccy);
        let ?payee = Json.obj(j, "payee") else return f("3102", "payee");
        let ?payer = Json.obj(j, "payer") else return f("3102", "payer");
        let ?payeeInfo = Json.obj(payee, "partyIdInfo") else return f("3102", "payee.partyIdInfo");
        let payeeFsp = switch (destination, need(payeeInfo, "fspId")) { case (?d, _) d; case (null, ?fsp) fsp; case (null, null) return f("3102", "FSPIOP-Destination or payee.partyIdInfo.fspId") };
        let payerFsp = switch (Json.obj(payer, "partyIdInfo")) { case (?pi) { switch (need(pi, "fspId")) { case (?x) x; case null src } }; case null src };
        if (participantOfFsp(s, rail, payeeFsp) == null) return f("3203", "payee FSP " # payeeFsp # " is not a participant");
        forwardTo(payeeFsp, [#quoteReceived({ rail; quoteId; transactionId; payerFsp; payeeFsp; amount = minor; currency = ccy; amountType; expiration = need(j, "expiration") })])
      };
      case ("quotes", "PUT") {
        if (segs.size() < 2) return f("3002", "quotes PUT takes /{ID}");
        let ?dest = destination else return f("3102", "the FSPIOP-Destination header");
        if (segs.size() == 3 and segs[2] == "error") return forwardTo(dest, []);
        let ?j = body else return f("3102", "a body");
        let ?ta = Json.obj(j, "transferAmount") else return f("3102", "transferAmount");
        let ?ccy = need(ta, "currency") else return f("3102", "transferAmount.currency");
        let ?mu = minorUnitsOf(ccy) else return f("3100", "currency " # ccy # " is not one the scheme settles");
        let ?a = need(ta, "amount") else return f("3102", "transferAmount.amount");
        let ?minor = amountMinor(a, mu) else return f("3100", "transferAmount is not a canonical Amount in " # ccy);
        let ?cond = need(j, "condition") else return f("3102", "condition");
        let ?condBytes = (if (matches(B64_43, cond)) Base64.decodeUrl(cond) else null) else return f("3100", "condition is not 43 base64url characters of 32 bytes");
        let ?packet = need(j, "ilpPacket") else return f("3102", "ilpPacket");
        let ?expiration = need(j, "expiration") else return f("3102", "expiration");
        if (dateTimeNanos(expiration) == null) return f("3100", "expiration is not a DateTime");
        forwardTo(dest, [#quoteAnswered({ rail; quoteId = segs[1]; transferAmount = minor; currency = ccy; condition = condBytes; ilpPacketHash = Sha256.fromBlob(#sha256, Text.encodeUtf8(packet)); expiration })])
      };
      case ("quotes", "GET") { if (segs.size() != 2) return f("3002", "quotes GET takes /{ID}"); let ?dest = destination else return f("3102", "FSPIOP-Destination"); forwardTo(dest, []) };
      case ("transactionRequests", "POST" or "PUT" or "GET") { let ?dest = destination else return f("3102", "FSPIOP-Destination"); forwardTo(dest, []) };
      // ── transfers: the settlement layer ──
      case ("transfers", "POST") {
        if (segs.size() != 1) return f("3002", "transfers POST takes no id in the path");
        let ?j = body else return f("3102", "a body");
        for (k in ["transferId", "payeeFsp", "payerFsp", "amount", "ilpPacket", "condition", "expiration"].vals()) { if (not Json.has(j, k)) return f("3102", k) };
        let ?transferId = need(j, "transferId") else return f("3102", "transferId");
        if (not matches(UUID, transferId)) return f("3100", "transferId is not a UUID");
        let ?payerFsp = need(j, "payerFsp") else return f("3102", "payerFsp");
        let ?payeeFsp = need(j, "payeeFsp") else return f("3102", "payeeFsp");
        if (payerFsp != src) return f("3100", "payerFsp must be the FSPIOP-Source");
        let ?payerP = participantOfFsp(s, rail, payerFsp) else return f("3202", "payer FSP " # payerFsp # " is not a participant");
        let ?payeeP = participantOfFsp(s, rail, payeeFsp) else return f("3203", "payee FSP " # payeeFsp # " is not a participant");
        if (payerP.participant == payeeP.participant) return f("3100", "payer and payee are one participant");
        let ?amt = Json.obj(j, "amount") else return f("3102", "amount");
        let ?ccy = need(amt, "currency") else return f("3102", "amount.currency");
        let ?mu = minorUnitsOf(ccy) else return f("3100", "currency " # ccy # " is not one the scheme settles");
        let ?a = need(amt, "amount") else return f("3102", "amount.amount");
        let ?minor = amountMinor(a, mu) else return f("3100", "amount " # a # " is not a canonical Amount in " # ccy);
        if (minor == 0) return f("3100", "an amount of zero moves nothing");
        let ?cond = need(j, "condition") else return f("3102", "condition");
        let ?condBytes = (if (matches(B64_43, cond)) Base64.decodeUrl(cond) else null) else return f("3100", "condition is not 43 base64url characters of 32 bytes");
        let ?packet = need(j, "ilpPacket") else return f("3102", "ilpPacket");
        if (Text.size(packet) == 0 or Text.size(packet) > 32_768 or not matches(B64_ANY, packet)) return f("3100", "ilpPacket is not base64url");
        let ?expiration = need(j, "expiration") else return f("3102", "expiration");
        let ?expiresAt = dateTimeNanos(expiration) else return f("3100", "expiration is not a DateTime");
        if (expiresAt <= now) return f("3303", "the transfer expired at " # expiration);
        let ttl = Nat.min(ttlSeconds, Nat64.toNat((expiresAt - now) / 1_000_000_000));
        if (transferOf(s, rail, transferId) != null or SC.transferByReference(sc, scheme, transferId) != null) return f("3100", "transferId " # transferId # " was already received");
        { act = #prepareTransfer({ transferId; payerFsp; payeeFsp; payer = payerP.participant; payee = payeeP.participant; currency = ccy; amount = minor; condition = condBytes; ilpPacketHash = Sha256.fromBlob(#sha256, Text.encodeUtf8(packet)); expiration; ttlSeconds = Nat.max(ttl, 1); body = req.body }); source; destination; method; path }
      };
      case ("transfers", "PUT") {
        if (segs.size() < 2 or segs.size() > 3) return f("3002", "transfers PUT takes /{ID}[/error]");
        let transferId = segs[1];
        let ?row = transferOf(s, rail, transferId) else return f("3208", "transfer " # transferId # " is not known to the switch");
        let ?t = SC.transferRowOf(sc, row.transfer) else return f("3208", "transfer " # transferId);
        let payerFsp = switch (fspOfParticipant(s, rail, t.payer)) { case (?x) x; case null "" };
        let payeeFsp = switch (fspOfParticipant(s, rail, t.payee)) { case (?x) x; case null "" };
        let ?j = body else return f("3102", "a body");
        if (segs.size() == 3) {
          if (segs[2] != "error") return f("3002", "transfers PUT takes /{ID}[/error]");
          let ?ei = Json.obj(j, "errorInformation") else return f("3102", "errorInformation");
          let ?code = need(ei, "errorCode") else return f("3102", "errorInformation.errorCode");
          let reason = switch (need(ei, "errorDescription")) { case (?d) d; case null FT.errorText(code) };
          if (src != payeeFsp and src != payerFsp) return f("3100", "only the transfer's FSPs may abort it");
          return { act = #abortTransfer({ transferId; transfer = row.transfer; payerFsp; payeeFsp; errorCode = code; reason; body = req.body }); source; destination; method; path };
        };
        if (src != payeeFsp) return f("3100", "only the payee FSP fulfils a transfer");
        let ?state = need(j, "transferState") else return f("3102", "transferState");
        switch (state) {
          case ("COMMITTED") {};
          case ("ABORTED") return { act = #abortTransfer({ transferId; transfer = row.transfer; payerFsp; payeeFsp; errorCode = "5105"; reason = "Payee FSP rejected transaction"; body = req.body }); source; destination; method; path };
          case ("RESERVED" or "RECEIVED") return { act = #forward({ destination = payerFsp; method = "PUT"; path; body = req.body; events = [] }); source; destination; method; path };
          case (other) return f("3100", "transferState " # other # " is not one of RECEIVED, RESERVED, COMMITTED, ABORTED");
        };
        let ?ful = need(j, "fulfilment") else return f("3102", "fulfilment (a COMMITTED transfer carries it)");
        let ?fulBytes = (if (matches(B64_43, ful)) Base64.decodeUrl(ful) else null) else return f("3100", "fulfilment is not 43 base64url characters of 32 bytes");
        let conditionMet = Sha256.fromBlob(#sha256, fulBytes) == row.condition;
        let completed = switch (need(j, "completedTimestamp")) { case (?c) c; case null nanosToDateTime(now) };
        { act = #fulfilTransfer({ transferId; transfer = row.transfer; payerFsp; payeeFsp; fulfilment = fulBytes; conditionMet; completedTimestamp = completed; body = req.body }); source; destination; method; path }
      };
      case ("transfers", "GET") {
        if (segs.size() != 2) return f("3002", "transfers GET takes /{ID}");
        let ?row = transferOf(s, rail, segs[1]) else return f("3208", "transfer " # segs[1] # " is not known to the switch");
        { act = #transferStatus({ transferId = segs[1]; transfer = row.transfer; requester = src }); source; destination; method; path }
      };
      case (_, _) f("2002", op.operationId # " is not implemented by this switch");
    }
  };

  // ─── the fold ───

  public func apply(s : State, block : Nat, e : FT.FspiopEvent) {
    switch (e) {
      case (#participantDeclared(x)) {
        // an FSP id renamed releases the old one
        switch (Map.get(s.byParticipant, cmpTN, (x.rail, x.participant))) { case (?old) { if (old != x.fspId) ignore Map.delete(s.byFspId, cmpTT, (x.rail, old)) }; case null {} };
        Map.add(s.byFspId, cmpTT, (x.rail, x.fspId), { rail = x.rail; participant = x.participant; fspId = x.fspId; endpoints = x.endpoints; declaredAt = block });
        Map.add(s.byParticipant, cmpTN, (x.rail, x.participant), x.fspId);
      };
      case (#partyRegistered(x)) Map.add(s.parties, Text.compare, partyKey(x.rail, x.idType, x.id, x.subId), { fspId = x.fspId; currency = x.currency; registeredAt = block });
      case (#partyDeregistered(x)) ignore Map.delete(s.parties, Text.compare, partyKey(x.rail, x.idType, x.id, x.subId));
      case (#quoteReceived(x)) { if (RI.get(s.quotes, key2(x.rail, x.quoteId)) == null) { let b = R.buf(); R.putBlob(b, Blob.fromArray(Array.tabulate<Nat8>(32, func(_) { 0 })), 32); R.putNat(b, x.amount, 16); R.putByte(b, 0); ignore RI.put(s.quotes, key2(x.rail, x.quoteId), R.done(b, QUOTE_ROW)) } };
      case (#quoteAnswered(x)) { let b = R.buf(); R.putBlob(b, x.condition, 32); R.putNat(b, x.transferAmount, 16); R.putByte(b, 1); ignore RI.put(s.quotes, key2(x.rail, x.quoteId), R.done(b, QUOTE_ROW)) };
      case (#transferPrepared(x)) { let b = R.buf(); R.putBlob(b, x.condition, 32); R.putNat(b, x.transfer, 8); R.putByte(b, 1); R.putNat(b, 0, 8); ignore RI.put(s.transfers, key2(x.rail, x.transferId), R.done(b, TRANSFER_ROW)) };
      case (#transferFulfilled(x)) setTransferState(s, x.rail, x.transferId, 2, block);
      case (#transferAborted(x)) setTransferState(s, x.rail, x.transferId, 3, block);
      case (#requestHandled(x)) { s.requests += 1; if (x.errorCode != null) s.refused += 1; s.forwarded += x.callbacks };
    };
  };

  func setTransferState(s : State, rail : Text, transferId : Text, state : Nat8, block : Nat) {
    switch (RI.get(s.transfers, key2(rail, transferId))) {
      case (?v) { let a = Blob.toArray(v); let b = R.buf(); R.putBlob(b, R.getBlob(a, 0, 32), 32); R.putNat(b, R.getNat(a, 32, 8), 8); R.putByte(b, state); R.putNat(b, block, 8); ignore RI.put(s.transfers, key2(rail, transferId), R.done(b, TRANSFER_ROW)) };
      case null {};
    }
  };

  public func fingerprintInto(w : C.Writer, s : State) {
    for (((rail, fsp), p) in Map.entries(s.byFspId)) { w.text(rail); w.text(fsp); w.nat(p.participant); for ((t, u) in p.endpoints.vals()) { w.text(t); w.text(u) }; w.nat(p.declaredAt) };
    for ((k, p) in Map.entries(s.parties)) { w.text(k); w.text(p.fspId); w.nat(p.registeredAt) };
    w.nat(s.requests); w.nat(s.refused); w.nat(s.forwarded);
    let (lo, hi) = R.fullRange(32);
    var cursor : ?Blob = null;
    label rows loop {
      let page = RI.range(s.transfers, lo, hi, cursor, 256);
      for ((k, v) in page.entries.vals()) { w.blobRaw(k); w.blobRaw(v) };
      switch (page.cursor) { case (?c) cursor := ?c; case null break rows };
    };
  };

}
