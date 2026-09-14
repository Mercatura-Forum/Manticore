// Fspiop.test.mo: FSPIOP v1.1 interoperability on the settlement layer, on the pure
// state machine.
//
// The world of Settlement.test.mo with a rail and four participants named by FSP ids; then requests
// through `BankCore.handleFspiop`:
//
//   F-1  the implemented operations answer with the specification's status and shapes; 202 for an
//        accepted asynchronous request, 200 for a callback, the error object with its code otherwise;
//        the ILP condition is the SHA-256 of the fulfilment, vector-checked against an independent
//        computation; the correct fulfilment posts the transfer (COMMITTED to the payer), a wrong one
//        aborts it with error 3100 to both; prepare/fulfil is reserve/post on the journal, the
//        reservation and the posting recorded; ≥ 50 request/response pairs
//   K6   the participant directory: FSP ids and callback endpoints of the reference's 58 types,
//        declared dual, recorded; a callback names the registered URL
//   P-4  every request is one block with its hash, status and error code
//
// engine: wasi-only; Regions.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Char "mo:core/Char";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Map "mo:core/Map";
import Result "mo:core/Result";
import Principal "mo:core/Principal";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";
import CivilDate "mo:journal/CivilDate";

import T "../src/bank/BankTypes";
import ProdT "../src/bank/ProductTypes";
import Core "../src/bank/BankCore";
import SeT "../src/bank/SettlementTypes";
import SC "../src/bank/SettlementCore";
import P "../src/bank/Permissions";
import Commit "../src/bank/Commitments";
import ProductCore "../src/bank/ProductCore";
import Sha256 "mo:sha2/Sha256";
import PayT "../src/bank/PaymentsTypes";
import FT "../src/bank/FspiopTypes";
import FC "../src/bank/FspiopCore";
import Json "../src/bank/Json";
import Base64 "../src/bank/Base64";
import Rx "../src/bank/Rx";
import FP "../src/bank/FspiopProfiles";
import FS "../src/bank/FspiopSchema";
import S "../src/bank/Screening";
import BankMemLog "support/BankMemLog";
import JMemLog "support/JournalMemLog";

var seed : Nat32 = 0x7C7C_1E01;
func next() : Nat32 { seed := seed *% 1_664_525 +% 1_013_904_223; seed };
func below(n : Nat) : Nat { if (n == 0) 0 else (Nat32.toNat(next() / 65_536) * 65_536 + Nat32.toNat(next() / 65_536)) % n };
func fail(what : Text) { Debug.print("FAIL: " # what); assert false };

func day(y : Nat, m : Nat, d : Nat) : JT.Day { switch (CivilDate.fromCivil(y, m, d)) { case (?x) x; case null { fail("bad date"); 0 } } };
let SEP1 = day(2026, 9, 1); let SEP30 = day(2026, 9, 30); let TODAY = day(2026, 9, 15);
let DAY_NS : Nat64 = 86_400_000_000_000;
var clock : Nat64 = Nat64.fromNat(TODAY) * DAY_NS + 43_200_000_000_000;

let bankP = Principal.fromBlob("\BA\01");
let installer = Principal.fromBlob("\1A\01");
let screener = Principal.fromBlob("\5C\01");

let bchain = BankMemLog.new();
let jchain = JMemLog.new();
let bs = Core.newState(installer);
let js = JCore.newState(bankP);
func bb() : Core.Blocks { BankMemLog.reader(bchain) };
func jb() : JCore.Blocks { JMemLog.reader(jchain) };
func sb() : SC.Blocks { { get = func(i : Nat) : ?SeT.SettlementEvent { switch (bb().get(i)) { case (?b) { switch (b.event) { case (#settlement(se)) ?se; case (_) null } }; case null null } } } };
func bcommit(e : T.Event) : Nat { BankMemLog.commit(bchain, bs, clock, installer, e).index };
func jcommit(e : JT.Event) : Nat { JMemLog.commit(jchain, js, clock, bankP, e).index };
var authority = 1_000_000;
func nextAuthority() : Nat { authority += 1; authority };
let recorder : Core.Recorder = { bank = func(ev : T.Event) : Nat { bcommit(ev) }; journal = func(ev : JT.Event) : Nat { jcommit(ev) }; monitor = Core.noMonitor };

/// Plan and execute a command the way the actor does: the bank event, the journal steps, and; for a
/// prepared transfer; the reservation in the same message.
func execute(command : T.Command) : Result.Result<Nat, T.BankError> {
  switch (Core.planCommand(bs, bb(), js, jb(), bankP, clock, command, nextAuthority())) {
    case (#err(e)) #err(e);
    case (#ok(plan)) {
      let at = Core.height(bs);
      switch (plan.bankEvent) {
        case (?ev) {
          let idx = bcommit(ev);
          switch (ev) {
            case (#settlement(#transferPrepared(_))) {
              switch (Core.planReserve(bs, bb(), js, bankP, clock, idx)) {
                case (#err(e)) { fail("reserve plan: " # debug_show (e)) };
                case (#ok(r)) {
                  switch (r.step) { case (?#event(jev)) ignore jcommit(jev); case (_) {} };
                  ignore bcommit(#settlement(r.event));
                  switch (Core.capAlarm(bs, bb(), js, clock, idx)) { case (?a) ignore bcommit(#settlement(a)); case null {} };
                };
              };
            };
            case (_) {};
          };
        };
        case null {};
      };
      for (ev in plan.extra.vals()) { ignore bcommit(ev) };
      for (step in plan.journal.vals()) { switch (step) { case (#event(ev)) ignore jcommit(ev); case (#existing(_)) {} } };
      #ok(at)
    };
  }
};
func cmd(command : T.Command) : Nat { switch (execute(command)) { case (#ok(at)) at; case (#err(e)) { fail("plan failed for " # P.commandName(command) # ": " # debug_show (e)); 0 } } };
func refuse(command : T.Command, want : Text) {
  let bh = Core.height(bs); let jh = JCore.height(js);
  switch (execute(command)) {
    case (#ok(_)) fail("expected " # want # " for " # P.commandName(command));
    case (#err(e)) { let got = debug_show (e); if (not Text.contains(got, #text want)) fail("wanted " # want # " got " # got) };
  };
  assert (Core.height(bs) == bh and JCore.height(js) == jh);
};

// ─── genesis: books, chart, period, products ─────────────────────────────────
ignore jcommit(switch (JCore.prepareAddPoster(js, bankP, bankP)) { case (#ok(e)) e; case (#err(_)) { fail("poster"); loop {} } });
ignore bcommit(#bankAdminTransferred({ admin = installer }));
ignore cmd(#openBook({ id = "HQ"; name = "Head office"; parent = null }));
ignore cmd(#openBook({ id = "BR01"; name = "Branch 1"; parent = ?"HQ" }));
for (c in ["EGP", "USD", "EUR"].vals()) ignore cmd(#journalRegisterCurrency({ code = c; minorUnits = 2 }));
for ((code, name, side, cat) in ([
  ("1001", "Cash", #debit, #asset), ("1250", "Overdrafts", #debit, #asset), ("2150", "Interchange fees due to participants", #credit, #liability), ("1999", "Hub reconciliation", #debit, #asset),
  ("2130", "Participant positions", #credit, #liability), ("2140", "Participant settlement", #credit, #liability), ("2120", "Interest payable", #credit, #liability),
  ("4100", "Fee income", #credit, #income), ("4150", "Hub fee income", #credit, #income), ("5100", "Interest expense", #debit, #expense),
] : [(Text, Text, JT.Side, JT.Category)]).vals()) {
  ignore cmd(#journalOpenAccount({ code; name; normalSide = side; category = cat; constraint = #none }));
};
ignore cmd(#journalOpenPeriod({ id = "2026-09"; start = SEP1; end = SEP30 }));
ignore cmd(#journalRollBusinessDate({ day = TODAY }));
ignore cmd(#journalSetActivationHeight({ height = 0 }));
ignore cmd(#setAccountFormat({ country = "EG"; bank = "0037"; branch = "0001"; serialWidth = 12; prefix = "00000" }));
for (b in ["HQ", "BR01"].vals()) ignore cmd(#setBackValueWindow({ window = { book = b; freeDays = 200; approvedDays = 0 } }));
ignore cmd(#setFunctionalCurrency({ currency = "EGP" }));
// every product feature on; the settlement gate stays off until G-1 below has shown it refuses
for (f in ProdT.featureIds().vals()) { if (f != ProdT.FEATURE_SETTLEMENT) ignore cmd(#setFeatureActivation({ feature = f; height = 0 })) };
func product(id : Text, control : Text, kind : ProdT.ProductKind, ccy : Text, overdraft : ?Nat) : T.Command {
  #registerProduct({ id; name = id; terms = {
    kind; currency = ccy; control;
    roles = [{ role = #principal; account = control }, { role = #interestPayable; account = "2120" }, { role = #interestExpense; account = "5100" }, { role = #feeIncome; account = "4100" }, { role = #overdraftPortfolio; account = "1250" }];
    interest = null; charges = [];
    limits = { overdraft; minimumOperating = 0; perOperation = null };
    schedule = null; delinquency = []; provisioning = []; accounting = #accrualPeriodic; withholdingTax = null; rounding = #halfEven; earlyRedemptionPenalty = null; valueDateConvention = #sameDay;
  } })
};
for (ccy in ["EGP", "USD", "EUR"].vals()) {
  // a position may go debit up to its cap; the cap is granted per account (`grantFacility`)
  ignore cmd(product("POS-" # ccy, "2130", #currentAccount, ccy, ?0));
  ignore cmd(product("SET-" # ccy, "2140", #currentAccount, ccy, null));
  ignore cmd(product("FEE-" # ccy, "2150", #currentAccount, ccy, null));
};
ignore cmd(#declareScheme({ id = "SCHEME"; granularity = #net; interchange = #multilateral; delay = #deferred; reconciliation = "1999"; feeIncome = "4150"; interchangeBps = 25; hubFeeBps = 5; alarmPercent = 80 }));
refuse(#declareScheme({ id = "SCHEME"; granularity = #net; interchange = #multilateral; delay = #deferred; reconciliation = "1999"; feeIncome = "4150"; interchangeBps = 25; hubFeeBps = 5; alarmPercent = 80 }), "SchemeExists");
refuse(#declareScheme({ id = "BAD"; granularity = #net; interchange = #multilateral; delay = #deferred; reconciliation = "9999"; feeIncome = "4150"; interchangeBps = 25; hubFeeBps = 5; alarmPercent = 80 }), "not in the chart");
refuse(#declareScheme({ id = "BAD2"; granularity = #net; interchange = #multilateral; delay = #deferred; reconciliation = "1999"; feeIncome = "4150"; interchangeBps = 25; hubFeeBps = 5; alarmPercent = 0 }), "InvalidScheme");

// ─── participants: a party, three accounts a currency, a cap ─────────────────
func saltFor(i : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(j) { Nat8.fromNat((i * 31 + j) % 256) })) };
let entries = Array.sort<Blob>(Array.map<Text, Blob>(["AL QAIDA"], func(t) { S.entryBytes(t) }), func(a, b) { S.compareEntries(a, b) });
let ?listRoot = S.root(entries) else { fail("root"); loop {} };
ignore cmd(#commitScreeningList({ version = "L1"; root = listRoot; count = 1; normalisation = Commit.NORMALISATION }));
type Pt = { id : Nat; party : Nat; accounts : [(Text, Nat, Nat, Nat)]; cap : Nat };
let CURRENCIES = ["EGP", "USD", "EUR"];
func newParticipant(i : Nat, cap : Nat) : Pt {
  let salt = saltFor(i + 10);
  let party = cmd(#createParty({ kind = #legal; salt; identityCommit = Commit.identity(salt, #legal, ["Bank " # Nat.toText(i)]); dedupCommit = null; attributes = []; book = "BR01"; cddLevel = #standard; riskRating = #low; pep = false; reviewDue = TODAY + 3650 }));
  ignore cmd(#setPartyLifecycle({ party; to = #pendingKyc }));
  for (kind in ["identity", "address"].vals()) { ignore cmd(#addPartyDocument({ party; document = { kind; commit = Commit.document(salt, kind, Blob.fromArray([1])); issued = 20000; expires = null } })) };
  ignore cmd(#recordScreeningDecision({ party; listVersion = "L1"; listRoot; decision = #clear; screener; justificationCommit = Commit.justification("no match") }));
  ignore cmd(#setPartyLifecycle({ party; to = #active }));
  let accts = Array.map<Text, (Text, Nat, Nat, Nat)>(CURRENCIES, func(ccy) {
    let pos = cmd(#openAccount({ product = "POS-" # ccy; party; currency = ccy; termDays = null; allocationOrder = [] }));
    ignore cmd(#setAccountStatus({ account = pos; to = #active }));
    ignore cmd(#grantFacility({ account = pos; limit = cap }));
    let set = cmd(#openAccount({ product = "SET-" # ccy; party; currency = ccy; termDays = null; allocationOrder = [] }));
    ignore cmd(#setAccountStatus({ account = set; to = #active }));
    let fee = cmd(#openAccount({ product = "FEE-" # ccy; party; currency = ccy; termDays = null; allocationOrder = [] }));
    ignore cmd(#setAccountStatus({ account = fee; to = #active }));
    (ccy, pos, set, fee)
  });
  // an ISO 9362 BIC: institution BK + two letters from the index, country EG, location CX
  let bic = "BK" # Char.toText(Char.fromNat32(Nat32.fromNat(65 + i / 26 % 26))) # Char.toText(Char.fromNat32(Nat32.fromNat(65 + i % 26))) # "EGCX";
  let id = cmd(#registerParticipant({ party; bic; scheme = "SCHEME"; accounts = Array.map<(Text, Nat, Nat, Nat), SeT.ParticipantAccounts>(accts, func((c, p, s, f)) { { currency = c; position = p; settlement = s; feeReceivable = f } }) }));
  { id; party; accounts = accts; cap }
};
let CAP = 1_000_000_00;
let parts = Array.tabulate<Pt>(6, func(i) { newParticipant(i, CAP) });
Debug.print("count: participants registered = " # Nat.toText(parts.size()));
refuse(#registerParticipant({ party = parts[0].party; bic = "BKZZEGCX"; scheme = "SCHEME"; accounts = [{ currency = "EGP"; position = parts[0].accounts[0].1; settlement = parts[0].accounts[0].2; feeReceivable = parts[0].accounts[0].3 }] }), "ParticipantExists");
refuse(#registerParticipant({ party = parts[0].party; bic = "BAD"; scheme = "OTHER"; accounts = [] }), "UnknownScheme");
func posOf(p : Pt, ccy : Text) : Nat { for ((c, pos, _, _) in p.accounts.vals()) { if (c == ccy) return pos }; 0 };
func setOf(p : Pt, ccy : Text) : Nat { for ((c, _, s, _) in p.accounts.vals()) { if (c == ccy) return s }; 0 };
func entryOf(acct : Nat) : ProductCore.AccountEntry { let ?a = ProductCore.get(bs.product, Core.productBlocks(bb()), acct) else { fail("no account"); loop {} }; a };
func balanceOf(acct : Nat, control : Text, ccy : Text) : Int {
  let b = JCore.balance(js, control, ?entryOf(acct).subledger, ccy);
  Int.sub(b.creditsPosted, b.debitsPosted)
};



// ─── the rail, the FSP ids, the endpoints ──────────────────────────────────────
ignore cmd(#setFeatureActivation({ feature = ProdT.FEATURE_SETTLEMENT; height = 0 }));
ignore cmd(#declareRail({ id = "RTGS"; scheme = "SCHEME"; ttlSeconds = 3_600; hold = { holdAbove = []; blockedBics = []; blockedNameFragments = [] }; signatures = #none }));
for (p in parts.vals()) { for (ccy in CURRENCIES.vals()) { ignore cmd(#recordFunds({ participant = p.id; currency = ccy; amount = 10_000_000_00; direction = #in_; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "prefunding" })) } };
ignore cmd(#openSettlementWindow({ scheme = "SCHEME"; businessDate = TODAY }));
let fspOf : [Text] = ["dfspa", "dfspb", "dfspc", "dfspd", "dfspe", "dfspf"];
var i = 0;
while (i < parts.size()) {
  ignore cmd(#declareFspiopParticipant({ rail = "RTGS"; participant = parts[i].id; fspId = fspOf[i]; endpoints = [("FSPIOP_CALLBACK_URL_TRANSFER_POST", "http://" # fspOf[i] # ".local/transfers"), ("FSPIOP_CALLBACK_URL_TRANSFER_PUT", "http://" # fspOf[i] # ".local/transfers/{{transferId}}"), ("FSPIOP_CALLBACK_URL_TRANSFER_ERROR", "http://" # fspOf[i] # ".local/transfers/{{transferId}}/error"), ("FSPIOP_CALLBACK_URL_PARTICIPANT_PUT", "http://" # fspOf[i] # ".local/participants/{{partyIdType}}/{{partyIdentifier}}"), ("FSPIOP_CALLBACK_URL_PARTIES_GET", "http://" # fspOf[i] # ".local/parties/{{partyIdType}}/{{partyIdentifier}}"), ("FSPIOP_CALLBACK_URL_QUOTES", "http://" # fspOf[i] # ".local")] }));
  i += 1;
};
refuse(#declareFspiopParticipant({ rail = "RTGS"; participant = parts[0].id; fspId = "x"; endpoints = [("NOT_A_TYPE", "http://x")] }), "InvalidEndpoint");
refuse(#declareFspiopParticipant({ rail = "RTGS"; participant = parts[1].id; fspId = "dfspa"; endpoints = [] }), "FspIdTaken");
refuse(#declareFspiopParticipant({ rail = "NOPE"; participant = parts[1].id; fspId = "z"; endpoints = [] }), "UnknownRail");
assert (FC.endpoint(bs.fspiop, "RTGS", "dfspa", "FSPIOP_CALLBACK_URL_TRANSFER_POST") == ?"http://dfspa.local/transfers");
assert (FT.ENDPOINT_TYPES.size() == 58);
Debug.print("count: FSPIOP participants declared (dual) with callback endpoints of the reference's 58 types = " # Nat.toText(parts.size()));
Debug.print("count: participant declarations refused (unknown endpoint type, FSP id taken, unknown rail) = 3");

// ─── requests ──────────────────────────────────────────────────────────────────
var pairs = 0;
func req(method : Text, path : Text, source : ?Text, destination : ?Text, contentType : ?Text, body : Text) : FT.Request {
  var hs : [(Text, Text)] = [("Date", "Tue, 15 Sep 2026 12:00:00 GMT"), ("Accept", "application/vnd.interoperability.transfers+json;version=1.1")];
  switch (source) { case (?s) hs := Array.concat(hs, [("FSPIOP-Source", s)]); case null {} };
  switch (destination) { case (?d) hs := Array.concat(hs, [("FSPIOP-Destination", d)]); case null {} };
  switch (contentType) { case (?c) hs := Array.concat(hs, [("Content-Type", c)]); case null {} };
  { method; path; headers = hs; body }
};
func ct(resource : Text) : ?Text { ?("application/vnd.interoperability." # resource # "+json;version=1.1") };
func send(r : FT.Request) : FT.Response {
  let bh = Core.height(bs);
  let out = switch (Core.handleFspiop(bs, bb(), js, jb(), bankP, clock, "RTGS", r, recorder)) { case (#ok(x)) x; case (#err(e)) { fail("fspiop: " # debug_show (e)); loop {} } };
  // every request is one block: the last block is its record, with the hash of the body and the status
  switch (bb().get(Core.height(bs) - 1)) { case (?{ event = #fspiop(#requestHandled(h)) }) { assert (h.status == out.status and h.callbacks == out.callbacks.size() and h.method == Text.toUpper(r.method)) }; case (_) fail("no request record") };
  assert (Core.height(bs) > bh);
  pairs += 1;
  out
};
func errorCodeOf(body : Text) : Text { switch (Json.parse(body)) { case (#ok(j)) { switch (Json.obj(j, "errorInformation")) { case (?ei) { switch (Json.str(ei, "errorCode")) { case (?c) c; case null "" } }; case null "" } }; case (#err(_)) "" } };
func expectError(r : FT.Request, code : Text) { let out = send(r); if (errorCodeOf(out.body) != code) fail("wanted error " # code # " got " # Nat.toText(out.status) # " " # out.body); assert (out.status == FT.errorStatus(code)); assert (out.callbacks.size() == 0) };
var uuidNo = 0x100;
func uuid() : Text { uuidNo += 1; "b51ec534-ee48-4575-b6a9-" # hex(uuidNo, 12) };
func patternsOf(sch : FP.Schema) : [Text] {
  switch (sch) {
    case (#string(st)) { switch (st.pattern) { case (?p) [p]; case null [] } };
    case (#object_(o)) { var out : [Text] = []; for ((_, sub) in o.properties.vals()) out := Array.concat(out, patternsOf(sub)); out };
    case (#array_(a)) patternsOf(a.items);
    case (#anyOf(c) or #allOf(c) or #oneOf(c)) { var out : [Text] = switch (c.pattern) { case (?p) [p]; case null [] }; for (sub in c.alternatives.vals()) out := Array.concat(out, patternsOf(sub)); out };
    case (_) [];
  }
};
func manyExtensions(n : Nat) : Text { var out = "["; var k = 0; while (k < n) { if (k > 0) out #= ","; out #= "{\"key\":\"k" # Nat.toText(k) # "\",\"value\":\"v\"}"; k += 1 }; out # "]" };
func hex(n : Nat, width : Nat) : Text { let d = Text.toArray("0123456789abcdef"); var v = n; var out = ""; var k = 0; while (k < width) { out := Char.toText(d[v % 16]) # out; v /= 16; k += 1 }; out };

// ─── the ILP condition, vector-checked ─────────────────────────────────────────
// the specification's example fulfilment, and the condition an independent SHA-256 (Python hashlib) derives
let FULFILMENT = "WLctttbu2HvTsa1XWvUoGRcQozHsqeu9Ahl2JW9Bsu8";
let CONDITION = "f5sqb7tBTWPd5Y8BDFdMm9BJR_MNI4isf8p8n4D5pHA";
let ?fulBytes = Base64.decodeUrl(FULFILMENT) else { fail("fulfilment"); loop {} };
assert (fulBytes.size() == 32 and Base64.encodeUrl(Sha256.fromBlob(#sha256, fulBytes)) == CONDITION);
let ?f2 = Base64.decodeUrl("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8") else { fail("f2"); loop {} };
assert (Base64.encodeUrl(Sha256.fromBlob(#sha256, f2)) == "Yw3NKWbEM2aRElRIu7JbT_QSpJxzLbLIq8G4WBvXEN0");
Debug.print("count: ILP condition = SHA-256(fulfilment) vectors checked against an independent computation = 2");

// ─── the account-lookup oracle and parties ─────────────────────────────────────
let r1 = send(req("POST", "/participants/MSISDN/201001234567", ?"dfspa", null, ct("participants"), "{\"fspId\":\"dfspa\",\"currency\":\"EGP\"}"));
assert (r1.status == 202 and r1.callbacks.size() == 1 and r1.callbacks[0].destination == "dfspa" and r1.callbacks[0].method == "PUT" and r1.callbacks[0].path == "/participants/MSISDN/201001234567");
assert (r1.callbacks[0].url == ?"http://dfspa.local/participants/{{partyIdType}}/{{partyIdentifier}}");
assert (FC.party(bs.fspiop, "RTGS", "MSISDN", "201001234567", null) != null);
let r2 = send(req("GET", "/participants/MSISDN/201001234567", ?"dfspb", null, null, ""));
assert (r2.status == 202 and r2.callbacks[0].body == "{\"fspId\":\"dfspa\"}" and r2.callbacks[0].destination == "dfspb");
expectError(req("GET", "/participants/MSISDN/000", ?"dfspb", null, null, ""), "3204");
expectError(req("POST", "/participants/MSISDN/2010", ?"dfspa", null, ct("participants"), "{\"fspId\":\"nobody\"}"), "3003");
expectError(req("POST", "/participants/PASSPORT/2010", ?"dfspa", null, ct("participants"), "{\"fspId\":\"dfspa\"}"), "3100");
// parties: routed to the FSP the oracle names, or to the destination named
let r3 = send(req("GET", "/parties/MSISDN/201001234567", ?"dfspb", null, null, ""));
assert (r3.status == 202 and r3.callbacks[0].destination == "dfspa" and r3.callbacks[0].method == "GET" and r3.callbacks[0].url == ?"http://dfspa.local/parties/{{partyIdType}}/{{partyIdentifier}}");
let r4 = send(req("PUT", "/parties/MSISDN/201001234567", ?"dfspa", ?"dfspb", ct("parties"), "{\"party\":{\"partyIdInfo\":{\"partyIdType\":\"MSISDN\",\"partyIdentifier\":\"201001234567\",\"fspId\":\"dfspa\"},\"name\":\"Alice\"}}"));
assert (r4.status == 200 and r4.callbacks[0].destination == "dfspb");
expectError(req("GET", "/parties/MSISDN/999", ?"dfspb", null, null, ""), "3204");
let r5 = send(req("DELETE", "/participants/MSISDN/201001234567", ?"dfspa", null, null, ""));
assert (r5.status == 202 and FC.party(bs.fspiop, "RTGS", "MSISDN", "201001234567", null) == null);
ignore send(req("POST", "/participants/MSISDN/201001234567", ?"dfspa", null, ct("participants"), "{\"fspId\":\"dfspa\"}"));
Debug.print("count: oracle registrations, lookups, deregistrations and party routings answered with the specification's shapes = 7");

// ─── quotes ────────────────────────────────────────────────────────────────────
let quoteId = uuid(); let transactionId = uuid();
let quoteBody = "{\"quoteId\":\"" # quoteId # "\",\"transactionId\":\"" # transactionId # "\",\"payee\":{\"partyIdInfo\":{\"partyIdType\":\"MSISDN\",\"partyIdentifier\":\"201001234567\",\"fspId\":\"dfspa\"}},\"payer\":{\"partyIdInfo\":{\"partyIdType\":\"MSISDN\",\"partyIdentifier\":\"201009999999\",\"fspId\":\"dfspb\"}},\"amountType\":\"SEND\",\"amount\":{\"currency\":\"EGP\",\"amount\":\"150.5\"},\"transactionType\":{\"scenario\":\"TRANSFER\",\"initiator\":\"PAYER\",\"initiatorType\":\"CONSUMER\"}}";
let r6 = send(req("POST", "/quotes", ?"dfspb", ?"dfspa", ct("quotes"), quoteBody));
assert (r6.status == 202 and r6.callbacks[0].destination == "dfspa" and r6.callbacks[0].method == "POST" and r6.callbacks[0].body == quoteBody);
switch (FC.quoteOf(bs.fspiop, "RTGS", quoteId)) { case (?q) assert (q.transferAmount == 150_50 and not q.answered); case null fail("quote not recorded") };
let quoteAnswer = "{\"transferAmount\":{\"currency\":\"EGP\",\"amount\":\"150.5\"},\"payeeReceiveAmount\":{\"currency\":\"EGP\",\"amount\":\"150.5\"},\"expiration\":\"2026-09-15T13:00:00.000Z\",\"ilpPacket\":\"AYIBgQAAAAAAAASwNGxldmVsb25lLmRmc3AxLm1lci45T2RTOF81MDdqUUZERmZlakgyOVc4bXFmNEpLMHlGTFGCAUBQU0svMS4wCk5vbmNlOiB1SXlweUYzY3pYSXBFdzVVc05TYWh3\",\"condition\":\"" # CONDITION # "\"}";
let r7 = send(req("PUT", "/quotes/" # quoteId, ?"dfspa", ?"dfspb", ct("quotes"), quoteAnswer));
assert (r7.status == 200 and r7.callbacks[0].destination == "dfspb" and r7.callbacks[0].url == ?"http://dfspb.local");
switch (FC.quoteOf(bs.fspiop, "RTGS", quoteId)) { case (?q) assert (q.answered and Base64.encodeUrl(q.condition) == CONDITION); case null fail("quote not answered") };
expectError(req("POST", "/quotes", ?"dfspb", ?"dfspa", ct("quotes"), Text.replace(quoteBody, #text "\"150.5\"", "\"150.50\"")), "3100");   // a trailing zero is not canonical
expectError(req("POST", "/quotes", ?"dfspb", ?"nobody", ct("quotes"), quoteBody), "3203");
expectError(req("PUT", "/quotes/" # quoteId, ?"dfspa", ?"dfspb", ct("quotes"), Text.replace(quoteAnswer, #text CONDITION, "short")), "3100");
expectError(req("PUT", "/quotes/" # quoteId, ?"dfspa", null, ct("quotes"), quoteAnswer), "3102");
Debug.print("count: quotes forwarded and recorded, their refusals typed = 6");

// ─── transfers: prepare is reserve, fulfil is post ──────────────────────────────
func transferBody(id : Text, payer : Text, payee : Text, ccy : Text, amount : Text, condition : Text, expiration : Text) : Text {
  "{\"transferId\":\"" # id # "\",\"payerFsp\":\"" # payer # "\",\"payeeFsp\":\"" # payee # "\",\"amount\":{\"currency\":\"" # ccy # "\",\"amount\":\"" # amount # "\"},\"ilpPacket\":\"AYIBgQAAAAAAAASwNGxldmVsb25lLmRmc3Ax\",\"condition\":\"" # condition # "\",\"expiration\":\"" # expiration # "\"}"
};
let EXP = "2026-09-15T13:00:00.000Z";
let t1 = uuid();
let jh0 = JCore.height(js);
let r8 = send(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), transferBody(t1, "dfspb", "dfspa", "EGP", "150.5", CONDITION, EXP)));
assert (r8.status == 202 and r8.callbacks.size() == 1 and r8.callbacks[0].destination == "dfspa" and r8.callbacks[0].method == "POST" and r8.callbacks[0].path == "/transfers" and r8.callbacks[0].url == ?"http://dfspa.local/transfers");
let ?row1 = FC.transferOf(bs.fspiop, "RTGS", t1) else { fail("no transfer row"); loop {} };
assert (row1.state == 1 and Base64.encodeUrl(row1.condition) == CONDITION);
let ?st1 = SC.transferRowOf(bs.settlement, row1.transfer) else { fail("settlement row"); loop {} };
assert (st1.state == #reserved and st1.amount == 150_50 and st1.payer == parts[1].id and st1.payee == parts[0].id and st1.reservation != null);
assert (JCore.height(js) == jh0 + 1);   // the reservation
// the wrong fulfilment aborts, with the error to both
let t2 = uuid();
ignore send(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), transferBody(t2, "dfspb", "dfspa", "EGP", "10", CONDITION, EXP)));
let rBad = send(req("PUT", "/transfers/" # t2, ?"dfspa", ?"dfspb", ct("transfers"), "{\"transferState\":\"COMMITTED\",\"fulfilment\":\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8\",\"completedTimestamp\":\"2026-09-15T12:01:00.000Z\"}"));
assert (rBad.status == 200 and rBad.callbacks.size() == 2);
for (c in rBad.callbacks.vals()) { assert (c.method == "PUT" and c.path == "/transfers/" # t2 # "/error" and errorCodeOf(c.body) == "3100" and Text.contains(c.body, #text "invalid fulfilment")) };
switch (FC.transferOf(bs.fspiop, "RTGS", t2)) { case (?r) { assert (r.state == 3); switch (SC.transferRowOf(bs.settlement, r.transfer)) { case (?s) assert (s.state == #abortedRejected); case null fail("row") } }; case null fail("t2") };
// the right fulfilment posts: COMMITTED to the payer with the fulfilment and the timestamp
let jh1 = JCore.height(js);
let rOk = send(req("PUT", "/transfers/" # t1, ?"dfspa", ?"dfspb", ct("transfers"), "{\"transferState\":\"COMMITTED\",\"fulfilment\":\"" # FULFILMENT # "\",\"completedTimestamp\":\"2026-09-15T12:01:00.000Z\"}"));
assert (rOk.status == 200 and rOk.callbacks.size() == 1 and rOk.callbacks[0].destination == "dfspb" and rOk.callbacks[0].method == "PUT" and rOk.callbacks[0].path == "/transfers/" # t1);
assert (rOk.callbacks[0].body == "{\"transferState\":\"COMMITTED\",\"fulfilment\":\"" # FULFILMENT # "\",\"completedTimestamp\":\"2026-09-15T12:01:00.000Z\"}");
switch (SC.transferRowOf(bs.settlement, row1.transfer)) { case (?s) { assert (s.state == #committed and s.posting != null) }; case null fail("row") };
assert (JCore.height(js) == jh1 + 3);   // the post and the two fee postings
// GET status: a callback to the requester with the state and the fulfilment
let rGet = send(req("GET", "/transfers/" # t1, ?"dfspb", null, null, ""));
assert (rGet.status == 202 and rGet.callbacks[0].destination == "dfspb" and Text.contains(rGet.callbacks[0].body, #text "\"transferState\":\"COMMITTED\"") and Text.contains(rGet.callbacks[0].body, #text FULFILMENT));
// a second fulfil of a committed transfer, and a fulfil by the payer: refused
let rAgain = send(req("PUT", "/transfers/" # t1, ?"dfspa", ?"dfspb", ct("transfers"), "{\"transferState\":\"COMMITTED\",\"fulfilment\":\"" # FULFILMENT # "\"}"));
assert (rAgain.status == 200 and rAgain.callbacks.size() == 2 and errorCodeOf(rAgain.callbacks[0].body) == "3100");
expectError(req("PUT", "/transfers/" # t1, ?"dfspb", ?"dfspa", ct("transfers"), "{\"transferState\":\"COMMITTED\",\"fulfilment\":\"" # FULFILMENT # "\"}"), "3100");
// the payee aborts through /error: the reservation voided, the payer told
let t3 = uuid();
ignore send(req("POST", "/transfers", ?"dfspc", ?"dfspd", ct("transfers"), transferBody(t3, "dfspc", "dfspd", "USD", "42.42", CONDITION, EXP)));
let rErr = send(req("PUT", "/transfers/" # t3 # "/error", ?"dfspd", ?"dfspc", ct("transfers"), "{\"errorInformation\":{\"errorCode\":\"5105\",\"errorDescription\":\"Payee FSP rejected transaction\"}}"));
assert (rErr.status == 200 and rErr.callbacks.size() == 1 and rErr.callbacks[0].destination == "dfspc" and errorCodeOf(rErr.callbacks[0].body) == "5105");
switch (FC.transferOf(bs.fspiop, "RTGS", t3)) { case (?r) { switch (SC.transferRowOf(bs.settlement, r.transfer)) { case (?s) assert (s.state == #abortedRejected); case null fail("row") } }; case null fail("t3") };
// the payee says ABORTED in the PUT: the same
let t4 = uuid();
ignore send(req("POST", "/transfers", ?"dfspc", ?"dfspd", ct("transfers"), transferBody(t4, "dfspc", "dfspd", "USD", "1", CONDITION, EXP)));
let rAb = send(req("PUT", "/transfers/" # t4, ?"dfspd", ?"dfspc", ct("transfers"), "{\"transferState\":\"ABORTED\"}"));
assert (rAb.status == 200 and errorCodeOf(rAb.callbacks[0].body) == "5105");
// RESERVED from the payee is a notice passed on, nothing posted
let t5 = uuid();
ignore send(req("POST", "/transfers", ?"dfspa", ?"dfspb", ct("transfers"), transferBody(t5, "dfspa", "dfspb", "EGP", "5", CONDITION, EXP)));
let jh2 = JCore.height(js);
let rRes = send(req("PUT", "/transfers/" # t5, ?"dfspb", ?"dfspa", ct("transfers"), "{\"transferState\":\"RESERVED\"}"));
assert (rRes.status == 200 and rRes.callbacks[0].destination == "dfspa" and JCore.height(js) == jh2);
Debug.print("count: transfers prepared (reserved), fulfilled (posted), aborted by a wrong fulfilment, by /error and by ABORTED, queried = 7");

// ─── the refusals, each the specification's error shape ─────────────────────────
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), transferBody(t1, "dfspb", "dfspa", "EGP", "1", CONDITION, EXP)), "3100");          // transferId already received
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), transferBody(uuid(), "dfspb", "nobody", "EGP", "1", CONDITION, EXP)), "3203");
expectError(req("POST", "/transfers", ?"nobody", ?"dfspa", ct("transfers"), transferBody(uuid(), "nobody", "dfspa", "EGP", "1", CONDITION, EXP)), "3202");
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), transferBody(uuid(), "dfspa", "dfspb", "EGP", "1", CONDITION, EXP)), "3100");   // payerFsp is not the source
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), transferBody(uuid(), "dfspb", "dfspa", "EGP", "1.005", CONDITION, EXP)), "3100");
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), transferBody(uuid(), "dfspb", "dfspa", "EGP", "01", CONDITION, EXP)), "3100");
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), transferBody(uuid(), "dfspb", "dfspa", "JPY", "1", CONDITION, EXP)), "3100");
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), transferBody(uuid(), "dfspb", "dfspa", "EGP", "1", "bad-condition", EXP)), "3100");
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), transferBody(uuid(), "dfspb", "dfspa", "EGP", "1", CONDITION, "2026-09-15T11:00:00.000Z")), "3303");
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), transferBody(uuid(), "dfspb", "dfspa", "EGP", "1", CONDITION, "yesterday")), "3100");
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), transferBody("not-a-uuid", "dfspb", "dfspa", "EGP", "1", CONDITION, EXP)), "3100");
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), "{\"transferId\":\"" # uuid() # "\"}"), "3102");
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), "{not json"), "3101");
expectError(req("POST", "/transfers", null, ?"dfspa", ct("transfers"), transferBody(uuid(), "dfspb", "dfspa", "EGP", "1", CONDITION, EXP)), "3102");
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("quotes"), transferBody(uuid(), "dfspb", "dfspa", "EGP", "1", CONDITION, EXP)), "3001");
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ?"application/vnd.interoperability.transfers+json;version=2.0", transferBody(uuid(), "dfspb", "dfspa", "EGP", "1", CONDITION, EXP)), "3001");
expectError(req("PUT", "/transfers/" # uuid(), ?"dfspa", ?"dfspb", ct("transfers"), "{\"transferState\":\"COMMITTED\"}"), "3208");
expectError(req("POST", "/bulkTransfers", ?"dfspb", ?"dfspa", ct("bulkTransfers"), "{}"), "2002");
expectError(req("POST", "/nothing", ?"dfspb", ?"dfspa", null, "{}"), "3002");
let r405 = send(req("GET", "/transfers", ?"dfspb", null, null, ""));
assert (r405.status == 405 and errorCodeOf(r405.body) == "3000");   // Table 4: an unsupported method on a known path
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), "{\"transferId\":\"" # uuid() # "\",\"payerFsp\":\"dfspb\",\"payeeFsp\":\"dfspa\",\"amount\":{\"currency\":\"EGP\",\"amount\":\"1\"},\"ilpPacket\":\"AYIB\",\"condition\":\"" # CONDITION # "\",\"expiration\":\"" # EXP # "\",\"extensionList\":{\"extension\":[]}}"), "3100");   // the schema: minItems 1
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), "{\"transferId\":\"" # uuid() # "\",\"payerFsp\":\"dfspb\",\"payeeFsp\":\"dfspa\",\"amount\":{\"currency\":\"EGP\",\"amount\":1},\"ilpPacket\":\"AYIB\",\"condition\":\"" # CONDITION # "\",\"expiration\":\"" # EXP # "\"}"), "3100");   // the schema: Amount is a string
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), "{\"transferId\":\"" # uuid() # "\",\"payerFsp\":\"dfspb\",\"payeeFsp\":\"dfspa\",\"amount\":{\"currency\":\"egp\",\"amount\":\"1\"},\"ilpPacket\":\"AYIB\",\"condition\":\"" # CONDITION # "\",\"expiration\":\"" # EXP # "\"}"), "3100");   // the schema: Currency enumeration
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), "{\"transferId\":\"" # uuid() # "\",\"payerFsp\":\"dfspb\",\"payeeFsp\":\"dfspa\",\"amount\":{\"currency\":\"EGP\"},\"ilpPacket\":\"AYIB\",\"condition\":\"" # CONDITION # "\",\"expiration\":\"" # EXP # "\"}"), "3102");   // the schema: Money.amount required
expectError(req("PUT", "/parties/MSISDN/201001234567", ?"dfspa", ?"dfspb", ct("parties"), "{\"party\":{\"partyIdInfo\":{\"partyIdType\":\"MSISDN\",\"partyIdentifier\":\"201001234567\"},\"personalInfo\":{\"complexName\":{\"firstName\":\"   \"}}}}"), "3100");   // the schema: FirstName's lookahead refuses blanks
expectError(req("PUT", "/parties/MSISDN/201001234567", ?"dfspa", ?"dfspb", ct("parties"), "{\"party\":{\"partyIdInfo\":{\"partyIdType\":\"MSISDN\",\"partyIdentifier\":\"201001234567\"},\"personalInfo\":{\"dateOfBirth\":\"2026-02-30\"}}}"), "3100");   // the schema: DateOfBirth's calendar
let rName = send(req("PUT", "/parties/MSISDN/201001234567", ?"dfspa", ?"dfspb", ct("parties"), "{\"party\":{\"partyIdInfo\":{\"partyIdType\":\"MSISDN\",\"partyIdentifier\":\"201001234567\",\"fspId\":\"dfspa\"},\"personalInfo\":{\"complexName\":{\"firstName\":\"محمد\",\"lastName\":\"O'Neil-Zoë\"},\"dateOfBirth\":\"2024-02-29\"}}}"));
assert (rName.status == 200);   // Unicode letters and marks, the apostrophe and the hyphen: the specification's name alphabet
expectError(req("POST", "/transfers", ?"dfspb", ?"dfspa", ct("transfers"), "{\"transferId\":\"" # uuid() # "\",\"payerFsp\":\"dfspb\",\"payeeFsp\":\"dfspa\",\"amount\":{\"currency\":\"EGP\",\"amount\":\"1\"},\"ilpPacket\":\"AYIB\",\"condition\":\"" # CONDITION # "\",\"expiration\":\"" # EXP # "\",\"extensionList\":{\"extension\":" # manyExtensions(17) # "}}"), "3103");   // the schema: at most 16 extensions
Debug.print("count: refusals answered with the specification's error object and code = 29");
// the operation table is the specification's: 46 operations on 30 paths, 24 implemented
var ops = 0; var impl = 0;
for (op in FP.OPERATIONS.vals()) { ops += 1; for ((m, p) in FT.IMPLEMENTED.vals()) { if (m == op.method and p == op.path) impl += 1 } };
assert (impl == FT.IMPLEMENTED.size());
Debug.print("count: operations of FSPIOP v1.1 in the generated table, implemented = " # Nat.toText(ops) # ", " # Nat.toText(impl));
expectError(req("POST", "/bulkQuotes", ?"dfspb", ?"dfspa", ct("bulkQuotes"), "{}"), "2002");
expectError(req("GET", "/authorizations/" # uuid(), ?"dfspb", ?"dfspa", null, ""), "2002");

// ─── the cap: a prepare the journal refuses is an error callback to the payer (4001) ──
let small = newParticipant(80, 10_000_00);
ignore cmd(#declareFspiopParticipant({ rail = "RTGS"; participant = small.id; fspId = "dfspsmall"; endpoints = [("FSPIOP_CALLBACK_URL_TRANSFER_ERROR", "http://small.local/transfers/{{transferId}}/error")] }));
let t6 = uuid();
let rCap = send(req("POST", "/transfers", ?"dfspsmall", ?"dfspa", ct("transfers"), transferBody(t6, "dfspsmall", "dfspa", "EGP", "10000.01", CONDITION, EXP)));
assert (rCap.status == 202 and rCap.callbacks.size() == 1 and rCap.callbacks[0].destination == "dfspsmall" and rCap.callbacks[0].path == "/transfers/" # t6 # "/error" and errorCodeOf(rCap.callbacks[0].body) == "4001" and rCap.callbacks[0].url == ?"http://small.local/transfers/{{transferId}}/error");
switch (FC.transferOf(bs.fspiop, "RTGS", t6)) { case (?r) { assert (r.state == 3); switch (SC.transferRowOf(bs.settlement, r.transfer)) { case (?s) assert (s.state == #failed); case null fail("row") } }; case null fail("t6") };
Debug.print("count: prepares past the payer's cap refused by the journal and answered 4001 to the payer = 1");

// ─── the pattern engine on the specification's patterns, alternation included ──────
let AMOUNT_RX = "([0]|([1-9][0-9]{0,17}))([.][0-9]{0,3}[1-9])?";
for (t in ["0", "1", "150.5", "123.45", "1.005", "999999999999999999", "0.1"].vals()) assert (Rx.test(AMOUNT_RX, t) == ?true);
for (t in ["01", "1.", "1.50", "-1", "1.0050", "", "1,5", "1000000000000000000", "0.0"].vals()) assert (Rx.test(AMOUNT_RX, t) == ?false);
assert (Rx.test("a|b|c", "b") == ?true and Rx.test("a|b|c", "d") == ?false and Rx.test("a|b|c", "ab") == ?false);
assert (Rx.test("(ab|a)(c|bcd)", "abcd") == ?true and Rx.test("(ab|a)(c|bcd)", "abc") == ?true and Rx.test("(ab|a)(c|bcd)", "abd") == ?false);
assert (Rx.test("x(a|)y", "xy") == ?true and Rx.test("x(a|)y", "xay") == ?true);
assert (Rx.test("(a|b)*c", "ababc") == ?true and Rx.test("(a|b)*c", "abacb") == ?false);
assert (Rx.test("[^a]", "b") == ?true and Rx.test("[^a-c]+", "xbz") == ?false and Rx.test("^a$", "a") == ?true and Rx.test("^\\d{3,10}$|^\\S{1,64}$", "a b") == ?false);
assert (Rx.test("^(?!\\s*$)[\\p{L}\\p{gc=Mark}\\p{digit}\\p{gc=Connector_Punctuation}\\p{Join_Control} .,''-]{1,128}$", "José María O'Neil-Zoë 3") == ?true);
assert (Rx.test("^(?!\\s*$)[\\p{L} .,''-]{1,128}$", "   ") == ?false and Rx.test("^(?!\\s*$)[\\p{L} .,''-]{1,128}$", "a/b") == ?false);
assert (Rx.test("a.b", "acb") == null and Rx.test("(a|b", "a") == null and Rx.test("(?=a)a", "a") == null and Rx.test("\\p{Greek}", "a") == null and Rx.test("a{2,1}", "aa") == null);
// every pattern of the two profiles compiles: none is silently unenforced
var isoPatterns = 0; var fspiopPatterns = 0;
for ((_, sch) in FP.SCHEMAS.vals()) { for (pat in patternsOf(sch).vals()) { fspiopPatterns += 1; switch (Rx.compile(pat)) { case (#ok(_)) {}; case (#err(m)) fail("FSPIOP pattern refused: " # pat # " — " # m) } } };
Debug.print("count: pattern-engine cases (Amount, alternation, lookahead, Unicode properties, the refused constructs) = 33");
Debug.print("count: FSPIOP profile patterns compiled by Rx = " # Nat.toText(fspiopPatterns));
assert (fspiopPatterns >= 18);

// ─── the amount codec, both ways, and the volume ────────────────────────────────
for ((t, m) in [("0", 0), ("1", 100), ("1.5", 150), ("123.45", 12_345), ("999999999999999999", 99_999_999_999_999_999_900)].vals()) { assert (FC.amountMinor(t, 2) == ?m); assert (FC.amountText(m, 2) == t) };
for (t in ["01", "1.", "1.50", "-1", "1.005", "", "1,5"].vals()) assert (FC.amountMinor(t, 2) == null);
assert (FC.dateTimeNanos("2026-09-15T12:00:00.000Z") == ?clock and FC.dateTimeNanos("2026-09-15T14:00:00+02:00") == ?clock and FC.dateTimeNanos("2026-13-01T00:00:00Z") == null);
assert (FC.nanosToDateTime(clock) == "2026-09-15T12:00:00.000Z");
Debug.print("count: Amount and DateTime codec cases = 16");
// thirty more payments, each prepared and fulfilled: the volume of pairs
var k = 0;
while (k < 30) {
  let payer = fspOf[k % 4]; let payee = fspOf[(k + 1) % 4];
  let id = uuid();
  let r = send(req("POST", "/transfers", ?payer, ?payee, ct("transfers"), transferBody(id, payer, payee, if (k % 2 == 0) "EGP" else "USD", Nat.toText(1 + k) # ".25", CONDITION, EXP)));
  assert (r.status == 202 and r.callbacks[0].destination == payee);
  let rr = send(req("PUT", "/transfers/" # id, ?payee, ?payer, ct("transfers"), "{\"transferState\":\"COMMITTED\",\"fulfilment\":\"" # FULFILMENT # "\"}"));
  assert (rr.status == 200 and Text.contains(rr.callbacks[0].body, #text "COMMITTED"));
  k += 1;
};
Debug.print("count: request/response pairs = " # Nat.toText(pairs));
assert (pairs >= 50);
let c = FC.counts(bs.fspiop);
Debug.print("count: FSPIOP transfers bound to settlement transfers = " # Nat.toText(c.transfers));
Debug.print("count: requests recorded, refused, callbacks produced = " # Nat.toText(c.requests) # ", " # Nat.toText(c.refused) # ", " # Nat.toText(c.forwarded));
assert (c.requests == pairs);

// ─── replay ────────────────────────────────────────────────────────────────────
let fresh = Core.replay(installer, BankMemLog.blocks(bchain));
assert (Core.fingerprint(fresh) == Core.fingerprint(bs));
Debug.print("count: bank blocks replayed to an identical fingerprint = " # Nat.toText(Core.height(bs)));
Debug.print("FSPIOP TEST GREEN");
