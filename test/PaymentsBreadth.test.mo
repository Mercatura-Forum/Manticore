// PaymentsBreadth.test.mo; the declared the extended target list target list on the pure state machine: the
// 22 families added to the seven of the core messaging set, each read, acted on and recorded.
//
// The world of Payments.test.mo (a rail over the settlement scheme, six participants by BIC), then:
//
//   F-4  every family of the declared list has its official schema in the profile and a family of its
//        own; the bank's emitted camt.052, pain.012, camt.025 and admi.007 validate under their profiles
//   the mandate cycle; pain.009 initiates (PENDING), the bank's dual decision activates or rejects (the
//        pain.012 derived), pain.010 amends, pain.011 cancels, a pain.012 read reports; pacs.003
//        collections under an ACTIVE mandate are reserved (the mandate's agents, account, maximum,
//        sequence enforced), counted, FNAL and OOFF completing it
//   FI direct debit; pacs.010 pulls only under the debtor's dual debit authority, within its maximum,
//        not after revocation
//   reversals; pacs.007 and pain.007 reverse a committed payment as a transfer of its own, linked to the
//        original's posting and posted in the message; the original untouched
//   the multilateral settlement request; pacs.029 on a CLOSED window opens its settlement; the
//        movements are judged against the computed nets when netting completes: equal nets settle, a
//        wrong request aborts with the first difference on record
//   cash management; camt.060 recorded and answered (camt.052 / camt.053 of the account), camt.057
//        expected receipts matched by the payment that arrives, camt.050 liquidity moved between the
//        settlement account and the position (the camt.025 receipt derived)
//   exceptions and investigations; camt.026/027/028/087 recorded against their payment
//   administration; admi.006 and admi.017 recorded (the admi.007 acknowledgement derived)
//   the business file; head.002 with its payloads, each ingested as a message of its own
//   P-4  every message one block; replay to an identical fingerprint
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
import PayT "../src/bank/PaymentsTypes";
import IsoMessages "../src/bank/IsoMessages";
import IsoSchema "../src/bank/IsoSchema";
import Xml "../src/bank/Xml";
import PayCore "../src/bank/PaymentsCore";
import Posting "../src/bank/Posting";
import S "../src/bank/Screening";
import BankMemLog "support/BankMemLog";
import JMemLog "support/JournalMemLog";

var seed : Nat32 = 0x7D7D_1E01;
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


// ─── the rail, the participants by BIC ─────────────────────────────────────────
ignore cmd(#setFeatureActivation({ feature = ProdT.FEATURE_SETTLEMENT; height = 0 }));
func bicOf(p : Pt) : Text { let ?x = SC.participant(bs.settlement, p.id) else { fail("participant"); loop {} }; x.bic };
refuse(#declareRail({ id = "RTGS"; scheme = "NOPE"; ttlSeconds = 600; hold = { holdAbove = []; blockedBics = []; blockedNameFragments = [] }; signatures = #none }), "InvalidRail");
refuse(#declareRail({ id = "RTGS"; scheme = "SCHEME"; ttlSeconds = 0; hold = { holdAbove = []; blockedBics = []; blockedNameFragments = [] }; signatures = #none }), "InvalidRail");
refuse(#declareRail({ id = "RTGS"; scheme = "SCHEME"; ttlSeconds = 600; hold = { holdAbove = []; blockedBics = ["BAD"]; blockedNameFragments = [] }; signatures = #none }), "InvalidRail");
let HOLD_ABOVE = 50_000_00;
ignore cmd(#declareRail({ id = "RTGS"; scheme = "SCHEME"; ttlSeconds = 600; hold = { holdAbove = [("EGP", HOLD_ABOVE)]; blockedBics = ["BKZYEGCX"]; blockedNameFragments = ["SANCTIONED"] }; signatures = #none }));
refuse(#declareRail({ id = "RTGS"; scheme = "SCHEME"; ttlSeconds = 600; hold = { holdAbove = []; blockedBics = []; blockedNameFragments = [] }; signatures = #none }), "RailExists");
Debug.print("count: rails declared, bad rails refused = 1 + 3");
for (p in parts.vals()) { for (ccy in CURRENCIES.vals()) { ignore cmd(#recordFunds({ participant = p.id; currency = ccy; amount = 10_000_000_00; direction = #in_; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "prefunding" })) } };
ignore cmd(#openSettlementWindow({ scheme = "SCHEME"; businessDate = TODAY }));

// ─── the messages ──────────────────────────────────────────────────────────────
func noVerify(_ : PayT.SignatureScheme, _ : Blob, _ : Blob, _ : Blob) : Bool { false };
func ingest(xml : Text) : Core.IngestResult {
  switch (Core.ingestMessage(bs, bb(), js, jb(), bankP, clock, "RTGS", Text.encodeUtf8(xml), null, noVerify, recorder)) { case (#ok(r)) r; case (#err(e)) { fail("ingest: " # debug_show (e)); loop {} } }
};
var msgNo = 0;
func nextMsgId() : Text { msgNo += 1; "MSG-" # Nat.toText(msgNo) };
var uetrNo = 0x1000;
func nextUetr() : Text { uetrNo += 1; let h = hex(uetrNo, 12); "8f2b5e70-1d44-4e6a-9c4a-" # h };
func hex(n : Nat, width : Nat) : Text { let digits = "0123456789abcdef"; let d = Text.toArray(digits); var v = n; var out = ""; var i = 0; while (i < width) { out := Char.toText(d[v % 16]) # out; v /= 16; i += 1 }; out };
let NOW_T = "2026-09-15T12:00:00Z";
func pacs008(items : [IsoMessages.OutboundTransfer]) : Text { IsoMessages.pacs008Xml(nextMsgId(), NOW_T, 2, items) };
func tx(payer : Pt, payee : Pt, ccy : Text, amount : Nat) : IsoMessages.OutboundTransfer {
  { uetr = nextUetr(); endToEndId = "E2E-" # Nat.toText(uetrNo); amount = { currency = ccy; minor = amount }; debtorAgent = bicOf(payer); creditorAgent = bicOf(payee); debtorName = "Debtor " # Nat.toText(uetrNo); creditorName = "Creditor"; debtorIban = null; creditorIban = null; settlementDate = TODAY }
};
func pacs002(originalMsg : Text, items : [(Text, Text, ?Text)]) : Text {
  var body = "";
  for ((uetr, status, reason) in items.vals()) {
    body #= "<TxInfAndSts><OrgnlUETR>" # uetr # "</OrgnlUETR><TxSts>" # status # "</TxSts>" # (switch (reason) { case (?r) "<StsRsnInf><Rsn><Cd>" # r # "</Cd></Rsn></StsRsnInf>"; case null "" }) # "</TxInfAndSts>";
  };
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pacs.002.001.10\"><FIToFIPmtStsRpt><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm></GrpHdr><OrgnlGrpInfAndSts><OrgnlMsgId>" # originalMsg # "</OrgnlMsgId><OrgnlMsgNmId>pacs.008.001.08</OrgnlMsgNmId></OrgnlGrpInfAndSts>" # body # "</FIToFIPmtStsRpt></Document>"
};
func pacs004(items : [(Text, Text, Nat, Text)]) : Text {
  var body = "";
  for ((rtrId, uetr, amount, ccy) in items.vals()) {
    body #= "<TxInf><RtrId>" # rtrId # "</RtrId><OrgnlUETR>" # uetr # "</OrgnlUETR><RtrdIntrBkSttlmAmt Ccy=\"" # ccy # "\">" # IsoMessages.amountText(amount, 2) # "</RtrdIntrBkSttlmAmt><RtrRsnInf><Rsn><Cd>AC04</Cd></Rsn></RtrRsnInf></TxInf>";
  };
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pacs.004.001.09\"><PmtRtr><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm><NbOfTxs>" # Nat.toText(items.size()) # "</NbOfTxs><SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf></GrpHdr>" # body # "</PmtRtr></Document>"
};
func pacs009(payer : Pt, payee : Pt, ccy : Text, amount : Nat) : Text {
  let u = nextUetr();
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pacs.009.001.08\"><FICdtTrf><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm><NbOfTxs>1</NbOfTxs><SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf></GrpHdr><CdtTrfTxInf><PmtId><InstrId>I-" # Nat.toText(uetrNo) # "</InstrId><EndToEndId>E-" # Nat.toText(uetrNo) # "</EndToEndId><UETR>" # u # "</UETR></PmtId><IntrBkSttlmAmt Ccy=\"" # ccy # "\">" # IsoMessages.amountText(amount, 2) # "</IntrBkSttlmAmt><Dbtr><FinInstnId><BICFI>" # bicOf(payer) # "</BICFI></FinInstnId></Dbtr><Cdtr><FinInstnId><BICFI>" # bicOf(payee) # "</BICFI></FinInstnId></Cdtr></CdtTrfTxInf></FICdtTrf></Document>"
};
func stateOf(t : Nat) : SeT.TransferState { let ?r = SC.transferRowOf(bs.settlement, t) else { fail("row"); loop {} }; r.state };
func transferOfUetr(uetr : Text) : Nat { let ?t = SC.transferByReference(bs.settlement, "SCHEME", uetr) else { fail("no transfer for " # uetr); loop {} }; t };
func onlyOutcome(r : Core.IngestResult) : PayT.Outcome { if (r.outcomes.size() != 1) fail("expected one outcome: " # debug_show (r)); r.outcomes[0] };
func refusedWith(r : Core.IngestResult, rule : Text) { assert (r.verdict == #refused); var ok = false; for (i in r.issues.vals()) { if (i.rule == rule) ok := true }; for (o in r.outcomes.vals()) { switch (o) { case (#refused(x)) { if (x.rule == rule) ok := true }; case (_) {} } }; if (not ok) fail("wanted " # rule # " got " # debug_show (r)) };


// ─── F-4: the families and their schemas ─────────────────────────────────────────
var families = 0;
for ((f, name, ord) in PayT.FAMILIES.vals()) {
  assert (PayT.familyOf("urn:iso:std:iso:20022:tech:xsd:" # name) == f);
  assert (PayT.familyFromOrd(PayT.familyOrd(f)) == f and PayT.familyOrd(f) == ord);
  assert (IsoSchema.schemaFor("urn:iso:std:iso:20022:tech:xsd:" # name) != null);
  families += 1;
};
assert (families == 29);
Debug.print("count: message families with an official schema profile and a family of their own = " # Nat.toText(families));

func validUnderProfile(xml : Text) : Bool {
  switch (Xml.parseMessage(Text.encodeUtf8(xml))) {
    case (#err(e)) { Debug.print("parse: " # e.rule # " " # e.detail); false };
    case (#ok(roots)) {
      let doc = roots[roots.size() - 1];
      switch (IsoSchema.schemaFor(doc.namespace)) { case (?sch) { let is = IsoSchema.validate(sch, doc); if (is.size() > 0) Debug.print("schema: " # debug_show (is[0])); is.size() == 0 }; case null { Debug.print("no schema for " # doc.namespace); false } }
    };
  }
};
let A = parts[0]; let B = parts[1]; let C = parts[2]; let D = parts[3];
func bic(p : Pt) : Text { bicOf(p) };
var fpChecks = 0;
func journalUnchangedBy(f : () -> Core.IngestResult) : Core.IngestResult {
  let jf = JCore.fingerprint(js); let bh = Core.height(bs);
  let r = f();
  if (not (JCore.fingerprint(js) == jf and Core.height(bs) == bh + 1)) Debug.print("DBG journal moved or blocks " # Nat.toText(Core.height(bs) - bh) # ": " # debug_show (r));
  assert (JCore.fingerprint(js) == jf and Core.height(bs) == bh + 1);   // the audit block, nothing else
  fpChecks += 1;
  r
};

// ─── builders for the declared families (the templates of integration/iso_instances_7d.py) ─────────
func amt(a : Nat) : Text { IsoMessages.amountText(a, 2) };
func pacs003(cdtr : Pt, dbtr : Pt, mandateId : Text, ccy : Text, amount : Nat, seq : Text, dbtrIban : Text) : (Text, Text) {
  let u = nextUetr();
  (u, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pacs.003.001.08\"><FIToFICstmrDrctDbt><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm><NbOfTxs>1</NbOfTxs><SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf></GrpHdr><DrctDbtTxInf><PmtId><EndToEndId>E2E-" # Nat.toText(uetrNo) # "</EndToEndId><UETR>" # u # "</UETR></PmtId><PmtTpInf><SvcLvl><Cd>SEPA</Cd></SvcLvl><LclInstrm><Cd>CORE</Cd></LclInstrm><SeqTp>" # seq # "</SeqTp></PmtTpInf><IntrBkSttlmAmt Ccy=\"" # ccy # "\">" # amt(amount) # "</IntrBkSttlmAmt><IntrBkSttlmDt>2026-09-15</IntrBkSttlmDt><ChrgBr>SLEV</ChrgBr><DrctDbtTx><MndtRltdInf><MndtId>" # mandateId # "</MndtId></MndtRltdInf></DrctDbtTx><Cdtr><Nm>Utility</Nm></Cdtr><CdtrAgt><FinInstnId><BICFI>" # bic(cdtr) # "</BICFI></FinInstnId></CdtrAgt><Dbtr><Nm>Household</Nm></Dbtr><DbtrAcct><Id><IBAN>" # dbtrIban # "</IBAN></Id></DbtrAcct><DbtrAgt><FinInstnId><BICFI>" # bic(dbtr) # "</BICFI></FinInstnId></DbtrAgt></DrctDbtTxInf></FIToFICstmrDrctDbt></Document>")
};
func pacs010(cdtr : Pt, dbtr : Pt, ccy : Text, amount : Nat) : (Text, Text) {
  let u = nextUetr();
  (u, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pacs.010.001.04\"><FIDrctDbt><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm><NbOfTxs>1</NbOfTxs></GrpHdr><CdtInstr><CdtId>CDT-" # Nat.toText(uetrNo) # "</CdtId><Cdtr><FinInstnId><BICFI>" # bic(cdtr) # "</BICFI></FinInstnId></Cdtr><DrctDbtTxInf><PmtId><EndToEndId>E2E-" # Nat.toText(uetrNo) # "</EndToEndId><UETR>" # u # "</UETR></PmtId><IntrBkSttlmAmt Ccy=\"" # ccy # "\">" # amt(amount) # "</IntrBkSttlmAmt><Dbtr><FinInstnId><BICFI>" # bic(dbtr) # "</BICFI></FinInstnId></Dbtr></DrctDbtTxInf></CdtInstr></FIDrctDbt></Document>")
};
var rvNo = 0;
func pacs007(origUetr : Text, amount : Nat, ccy : Text, reason : Text) : Text { rvNo += 1; pacs007With("RV-" # Nat.toText(rvNo), origUetr, amount, ccy, reason) };
func pacs007With(rvId : Text, origUetr : Text, amount : Nat, ccy : Text, reason : Text) : Text {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pacs.007.001.10\"><FIToFIPmtRvsl><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm><NbOfTxs>1</NbOfTxs><SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf></GrpHdr><TxInf><RvslId>" # rvId # "</RvslId><OrgnlUETR>" # origUetr # "</OrgnlUETR><RvsdIntrBkSttlmAmt Ccy=\"" # ccy # "\">" # amt(amount) # "</RvsdIntrBkSttlmAmt><RvslRsnInf><Rsn><Cd>" # reason # "</Cd></Rsn></RvslRsnInf></TxInf></FIToFIPmtRvsl></Document>"
};
func pain007(origE2E : Text, amount : Nat, ccy : Text) : Text { pain007By(?origE2E, null, amount, ccy) };
func pain007By(origE2E : ?Text, origUetr : ?Text, amount : Nat, ccy : Text) : Text {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pain.007.001.10\"><CstmrPmtRvsl><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm><NbOfTxs>1</NbOfTxs><InitgPty><Nm>Utility</Nm></InitgPty></GrpHdr><OrgnlGrpInf><OrgnlMsgId>PAIN008-1</OrgnlMsgId><OrgnlMsgNmId>pain.008.001.08</OrgnlMsgNmId></OrgnlGrpInf><OrgnlPmtInfAndRvsl><OrgnlPmtInfId>PI-1</OrgnlPmtInfId><TxInf><RvslId>RV-" # Nat.toText(msgNo) # "</RvslId>" # (switch (origE2E) { case (?e) "<OrgnlEndToEndId>" # e # "</OrgnlEndToEndId>"; case null "" }) # (switch (origUetr) { case (?u) "<OrgnlUETR>" # u # "</OrgnlUETR>"; case null "" }) # "<RvsdInstdAmt Ccy=\"" # ccy # "\">" # amt(amount) # "</RvsdInstdAmt><RvslRsnInf><Rsn><Cd>AM05</Cd></Rsn></RvslRsnInf></TxInf></OrgnlPmtInfAndRvsl></CstmrPmtRvsl></Document>"
};
func pacs029(cycle : Text, movements : [(Text, Text, Nat, Bool)]) : Text {
  var recs = ""; var i = 0;
  for ((b, ccy, a, debit) in movements.vals()) { i += 1; recs #= "<MvmntRcrd><Id>MV" # Nat.toText(i) # "</Id><Amt><Amt Ccy=\"" # ccy # "\">" # amt(a) # "</Amt><CdtDbt>" # (if (debit) "DBIT" else "CRDT") # "</CdtDbt></Amt><Ptcpt><Id><OrgId><AnyBIC>" # b # "</AnyBIC></OrgId></Id></Ptcpt></MvmntRcrd>" };
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pacs.029.001.02\"><MulSttlmReq><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm><NbOfSttlmReqs>1</NbOfSttlmReqs><SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf></GrpHdr><SttlmReq><InstrId>INSTR-" # Nat.toText(msgNo) # "</InstrId><SttlmCycl>" # cycle # "</SttlmCycl><NbOfMvmntRcrds>" # Nat.toText(movements.size()) # "</NbOfMvmntRcrds>" # recs # "</SttlmReq></MulSttlmReq></Document>"
};
func pain009(mandateId : Text, cdtr : Pt, dbtr : Pt, iban : Text, maxAmount : Nat, ccy : Text, seq : Text) : Text {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pain.009.001.07\"><MndtInitnReq><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm><InitgPty><Nm>Utility</Nm></InitgPty></GrpHdr><Mndt><MndtId>" # mandateId # "</MndtId><MndtReqId>REQ-" # Nat.toText(msgNo) # "</MndtReqId><Ocrncs><SeqTp>" # seq # "</SeqTp><Frqcy><Tp>MNTH</Tp></Frqcy><FrstColltnDt>2026-10-01</FrstColltnDt></Ocrncs><TrckgInd>false</TrckgInd><MaxAmt Ccy=\"" # ccy # "\">" # amt(maxAmount) # "</MaxAmt><Cdtr><Nm>Utility</Nm></Cdtr><CdtrAgt><FinInstnId><BICFI>" # bic(cdtr) # "</BICFI></FinInstnId></CdtrAgt><Dbtr><Nm>Household</Nm></Dbtr><DbtrAcct><Id><IBAN>" # iban # "</IBAN></Id></DbtrAcct><DbtrAgt><FinInstnId><BICFI>" # bic(dbtr) # "</BICFI></FinInstnId></DbtrAgt></Mndt></MndtInitnReq></Document>"
};
func pain010(mandateId : Text, maxAmount : Nat, ccy : Text) : Text {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pain.010.001.07\"><MndtAmdmntReq><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm><InitgPty><Nm>Utility</Nm></InitgPty></GrpHdr><UndrlygAmdmntDtls><AmdmntRsn><Rsn><Cd>MD16</Cd></Rsn></AmdmntRsn><Mndt><MndtId>" # mandateId # "</MndtId><TrckgInd>false</TrckgInd><MaxAmt Ccy=\"" # ccy # "\">" # amt(maxAmount) # "</MaxAmt></Mndt><OrgnlMndt><OrgnlMndtId>" # mandateId # "</OrgnlMndtId></OrgnlMndt></UndrlygAmdmntDtls></MndtAmdmntReq></Document>"
};
func pain011(mandateId : Text) : Text {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pain.011.001.07\"><MndtCxlReq><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm><InitgPty><Nm>Utility</Nm></InitgPty></GrpHdr><UndrlygCxlDtls><CxlRsn><Rsn><Cd>MD16</Cd></Rsn></CxlRsn><OrgnlMndt><OrgnlMndtId>" # mandateId # "</OrgnlMndtId></OrgnlMndt></UndrlygCxlDtls></MndtCxlReq></Document>"
};
func pain012(mandateId : Text, accepted : Bool) : Text {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pain.012.001.07\"><MndtAccptncRpt><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm><InitgPty><Nm>Debtor Bank</Nm></InitgPty></GrpHdr><UndrlygAccptncDtls><AccptncRslt><Accptd>" # (if (accepted) "true" else "false") # "</Accptd>" # (if (accepted) "" else "<RjctRsn><Cd>MD01</Cd></RjctRsn>") # "</AccptncRslt><OrgnlMndt><OrgnlMndtId>" # mandateId # "</OrgnlMndtId></OrgnlMndt></UndrlygAccptncDtls></MndtAccptncRpt></Document>"
};
func camt060(owner : Pt, accountId : ?Text, kind : Text) : Text {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:camt.060.001.05\"><AcctRptgReq><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm></GrpHdr><RptgReq><Id>RQ-" # Nat.toText(msgNo) # "</Id><ReqdMsgNmId>" # kind # "</ReqdMsgNmId>" # (switch (accountId) { case (?a) "<Acct><Id><Othr><Id>" # a # "</Id></Othr></Id></Acct>"; case null "" }) # "<AcctOwnr><Agt><FinInstnId><BICFI>" # bic(owner) # "</BICFI></FinInstnId></Agt></AcctOwnr><RptgPrd><FrToDt><FrDt>2026-09-15</FrDt><ToDt>2026-09-15</ToDt></FrToDt><Tp>ALLL</Tp></RptgPrd></RptgReq></AcctRptgReq></Document>"
};
func camt057(accountId : Text, items : [(Text, Text, Nat, Text, Pt)]) : Text {
  var body = "";
  for ((iid, u, a, ccy, dbtr) in items.vals()) body #= "<Itm><Id>" # iid # "</Id><EndToEndId>E2E-" # iid # "</EndToEndId><UETR>" # u # "</UETR><Amt Ccy=\"" # ccy # "\">" # amt(a) # "</Amt><XpctdValDt>2026-09-15</XpctdValDt><DbtrAgt><FinInstnId><BICFI>" # bic(dbtr) # "</BICFI></FinInstnId></DbtrAgt></Itm>";
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:camt.057.001.06\"><NtfctnToRcv><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm></GrpHdr><Ntfctn><Id>NTF-" # Nat.toText(msgNo) # "</Id><Acct><Id><Othr><Id>" # accountId # "</Id></Othr></Id></Acct>" # body # "</Ntfctn></NtfctnToRcv></Document>"
};
func camt050(amount : Nat, ccy : Text, dbtr : ?Pt, cdtr : ?Pt, e2e : Text) : Text {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:camt.050.001.05\"><LqdtyCdtTrf><MsgHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm></MsgHdr><LqdtyCdtTrf><LqdtyTrfId><EndToEndId>" # e2e # "</EndToEndId></LqdtyTrfId>" # (switch (cdtr) { case (?p) "<Cdtr><FinInstnId><BICFI>" # bic(p) # "</BICFI></FinInstnId></Cdtr>"; case null "" }) # "<TrfdAmt><AmtWthCcy Ccy=\"" # ccy # "\">" # amt(amount) # "</AmtWthCcy></TrfdAmt>" # (switch (dbtr) { case (?p) "<Dbtr><FinInstnId><BICFI>" # bic(p) # "</BICFI></FinInstnId></Dbtr>"; case null "" }) # "<SttlmDt>2026-09-15</SttlmDt></LqdtyCdtTrf></LqdtyCdtTrf></Document>"
};
func investigation(family : Text, root : Text, assigner : Pt, assignee : Pt, origUetr : Text, tail : Text) : Text {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:" # family # "\"><" # root # "><Assgnmt><Id>ASG-" # Nat.toText(msgNo + 1) # "</Id><Assgnr><Agt><FinInstnId><BICFI>" # bic(assigner) # "</BICFI></FinInstnId></Agt></Assgnr><Assgne><Agt><FinInstnId><BICFI>" # bic(assignee) # "</BICFI></FinInstnId></Agt></Assgne><CreDtTm>" # NOW_T # "</CreDtTm></Assgnmt><Case><Id>CASE-" # nextMsgId() # "</Id><Cretr><Agt><FinInstnId><BICFI>" # bic(assigner) # "</BICFI></FinInstnId></Agt></Cretr></Case><Undrlyg><IntrBk><OrgnlGrpInf><OrgnlMsgId>MSG-ORIG</OrgnlMsgId><OrgnlMsgNmId>pacs.008.001.08</OrgnlMsgNmId></OrgnlGrpInf><OrgnlUETR>" # origUetr # "</OrgnlUETR><OrgnlIntrBkSttlmAmt Ccy=\"EGP\">100.00</OrgnlIntrBkSttlmAmt><OrgnlIntrBkSttlmDt>2026-09-15</OrgnlIntrBkSttlmDt></IntrBk></Undrlyg>" # tail # "</" # root # "></Document>"
};
func admi006(rcpt : Pt, seq : Text) : Text {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:admi.006.001.01\"><RsndReq><MsgHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm></MsgHdr><RsndSchCrit><BizDt>2026-09-15</BizDt><SeqNb>" # seq # "</SeqNb><OrgnlMsgNmId>pacs.002.001.10</OrgnlMsgNmId><Rcpt><Id><AnyBIC>" # bic(rcpt) # "</AnyBIC></Id></Rcpt></RsndSchCrit></RsndReq></Document>"
};
func admi017(tp : Text) : Text {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:admi.017.001.01\"><PrcgReq><MsgId>" # nextMsgId() # "</MsgId><SttlmSsnIdr>AB12</SttlmSsnIdr><Req><Tp>" # tp # "</Tp><AddtlReqInf>run end of day</AddtlReqInf></Req></PrcgReq></Document>"
};
func head002(payloads : [Text], declared : Nat) : Text {
  var pl = "";
  for (p in payloads.vals()) pl #= "<Pyld>" # Text.replace(p, #text "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "") # "</Pyld>";
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Xchg xmlns=\"urn:iso:std:iso:20022:tech:xsd:head.002.001.01\"><PyldDesc><PyldData><PyldIdr>FILE-" # nextMsgId() # "</PyldIdr><CreDtAndTm>" # NOW_T # "</CreDtAndTm></PyldData><ApplSpcfcs><SysUsr>ach</SysUsr><TtlNbOfDocs>" # Nat.toText(declared) # "</TtlNbOfDocs></ApplSpcfcs><PyldTp>pacs.008.001.08</PyldTp></PyldDesc>" # pl # "</Xchg>"
};
func outcomeOf(r : Core.IngestResult, want : Text) : PayT.Outcome {
  for (o in r.outcomes.vals()) { if (Text.startsWith(debug_show (o), #text ("#" # want))) return o };
  fail("no " # want # " outcome in " # debug_show (r)); loop {}
};

// ─── the mandate cycle, and collections under it ─────────────────────────────────
let IBAN1 = "EG380019000500000000263180002";
refusedWith(ingest(pain009("MNDT-X", A, B, IBAN1, 500_00, "EGP", "WEEKLY")), "ISO-XSD-ENUM");   // the schema refuses a sequence type outside SequenceType2Code before any rule of ours
let rM1 = ingest(pain009("MNDT-1", A, B, IBAN1, 500_00, "EGP", "RCUR"));
assert (rM1.verdict == #accepted);
let m1Block = switch (outcomeOf(rM1, "mandateInitiated")) { case (#mandateInitiated(m)) { assert (m.mandateId == "MNDT-1" and m.maxAmount == ?500_00); m.mandate }; case (_) 0 };
assert (m1Block == rM1.message);
let ?m1 = PayCore.mandate(bs.payments, "RTGS", "MNDT-1") else { fail("mandate"); loop {} };
assert (m1.state == #pending and m1.creditorAgent == bic(A) and m1.debtorAgent == bic(B) and m1.debtorAccount == IBAN1 and m1.maxAmount == ?500_00 and m1.currency == ?"EGP");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pain009("MNDT-1", A, B, IBAN1, 500_00, "EGP", "RCUR")) }), "ISO-BIZ-DUPLICATE-MANDATE");
// a collection before the bank's decision: refused
let (uX, xX) = pacs003(A, B, "MNDT-1", "EGP", 100_00, "FRST", IBAN1);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(xX) }), "ISO-BIZ-MANDATE-STATE");
// the bank's decision (dual): the pain.012 derives from the block
refuse(#decideMandate({ rail = "RTGS"; mandateId = "NOPE"; accepted = true; reason = null }), "UnknownMandate");
refuse(#decideMandate({ rail = "RTGS"; mandateId = "MNDT-1"; accepted = false; reason = null }), "InvalidRail");
let decided = cmd(#decideMandate({ rail = "RTGS"; mandateId = "MNDT-1"; accepted = true; reason = null }));
assert ((switch (PayCore.mandate(bs.payments, "RTGS", "MNDT-1")) { case (?m) m.state; case null #rejected }) == #active);
refuse(#decideMandate({ rail = "RTGS"; mandateId = "MNDT-1"; accepted = true; reason = null }), "MandateState");
let p012 = IsoMessages.pain012Xml("PAIN012-T", NOW_T, "MSG-1", "pain.009.001.07", "MNDT-1", true, null);
assert (validUnderProfile(p012));
assert (validUnderProfile(IsoMessages.pain012Xml("PAIN012-R", NOW_T, "MSG-1", "pain.009.001.07", "MNDT-1", false, ?"MD01")));
ignore decided;
// collections: the first, a second, the mandate's rules
let (u1, x1) = pacs003(A, B, "MNDT-1", "EGP", 100_00, "FRST", IBAN1);
let rC1 = ingest(x1);
let trC1 = switch (outcomeOf(rC1, "collected")) { case (#collected(c)) { assert (c.reserved and c.authority == m1Block and not c.final); c.transfer }; case (_) 0 };
assert (stateOf(trC1) == #reserved);
let ?rowC1 = SC.transferRowOf(bs.settlement, trC1) else { fail("row"); loop {} };
assert (rowC1.payer == B.id and rowC1.payee == A.id and rowC1.amount == 100_00);
assert ((switch (PayCore.mandate(bs.payments, "RTGS", "MNDT-1")) { case (?m) m.collections; case null 0 }) == 1);
let (u2, x2) = pacs003(A, B, "MNDT-1", "EGP", 600_00, "RCUR", IBAN1);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(x2) }), "ISO-BIZ-MANDATE-AMOUNT");
let (u3, x3) = pacs003(A, B, "MNDT-1", "USD", 10_00, "RCUR", IBAN1);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(x3) }), "ISO-BIZ-MANDATE-CURRENCY");
let (u4, x4) = pacs003(A, B, "MNDT-1", "EGP", 10_00, "RCUR", "EG380019000500000000263180099");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(x4) }), "ISO-BIZ-MANDATE-ACCOUNT");
let (u5, x5) = pacs003(C, B, "MNDT-1", "EGP", 10_00, "RCUR", IBAN1);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(x5) }), "ISO-BIZ-MANDATE-PARTIES");
let (u6, x6) = pacs003(A, B, "MNDT-1", "EGP", 10_00, "FRST", IBAN1);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(x6) }), "ISO-BIZ-MANDATE-SEQUENCE");
let (u7, x7) = pacs003(A, B, "MNDT-NONE", "EGP", 10_00, "RCUR", IBAN1);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(x7) }), "ISO-BIZ-UNKNOWN-MANDATE");
let noMandate = Text.replace(pacs003(A, B, "MNDT-1", "EGP", 10_00, "RCUR", IBAN1).1, #text "<DrctDbtTx><MndtRltdInf><MndtId>MNDT-1</MndtId></MndtRltdInf></DrctDbtTx>", "");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(noMandate) }), "ISO-BIZ-MANDATE-REQUIRED");
// the collection settles like any transfer: the debtor bank's pacs.002
let rC1s = ingest(Text.replace(pacs002("MSG-x", [(u1, "ACSC", null)]), #text "pacs.008.001.08", "pacs.003.001.08"));
assert (stateOf(trC1) == #committed);
ignore rC1s;
// amendment raises the maximum; the refused amount now passes
let rAm = ingest(pain010("MNDT-1", 800_00, "EGP"));
assert (rAm.verdict == #accepted);
assert ((switch (PayCore.mandate(bs.payments, "RTGS", "MNDT-1")) { case (?m) m.maxAmount; case null null }) == ?800_00);
let (u8, x8) = pacs003(A, B, "MNDT-1", "EGP", 600_00, "RCUR", IBAN1);
let trC2 = switch (outcomeOf(ingest(x8), "collected")) { case (#collected(c)) c.transfer; case (_) 0 };
assert (stateOf(trC2) == #reserved);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pain010("MNDT-NONE", 1, "EGP")) }), "ISO-BIZ-UNKNOWN-MANDATE");
// a FNAL collection completes the mandate; the next is refused
let (u9, x9) = pacs003(A, B, "MNDT-1", "EGP", 50_00, "FNAL", IBAN1);
switch (outcomeOf(ingest(x9), "collected")) { case (#collected(c)) assert (c.final); case (_) {} };
assert ((switch (PayCore.mandate(bs.payments, "RTGS", "MNDT-1")) { case (?m) m.state; case null #pending }) == #completed);
let (u10, x10) = pacs003(A, B, "MNDT-1", "EGP", 50_00, "RCUR", IBAN1);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(x10) }), "ISO-BIZ-MANDATE-STATE");
// a one-off mandate collects once
ignore ingest(pain009("MNDT-OOFF", A, B, IBAN1, 300_00, "EGP", "OOFF"));
ignore cmd(#decideMandate({ rail = "RTGS"; mandateId = "MNDT-OOFF"; accepted = true; reason = null }));
let (u11, x11) = pacs003(A, B, "MNDT-OOFF", "EGP", 300_00, "OOFF", IBAN1);
switch (outcomeOf(ingest(x11), "collected")) { case (#collected(c)) assert (c.final and c.reserved); case (_) {} };
let (u12, x12) = pacs003(A, B, "MNDT-OOFF", "EGP", 300_00, "OOFF", IBAN1);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(x12) }), "ISO-BIZ-MANDATE-STATE");
// cancellation, rejection, and an acceptance report read from the other bank
ignore ingest(pain009("MNDT-2", A, C, IBAN1, 200_00, "EGP", "RCUR"));
ignore cmd(#decideMandate({ rail = "RTGS"; mandateId = "MNDT-2"; accepted = true; reason = null }));
let rCx = ingest(pain011("MNDT-2"));
assert (rCx.verdict == #accepted and (switch (PayCore.mandate(bs.payments, "RTGS", "MNDT-2")) { case (?m) m.state; case null #pending }) == #cancelled);
let (u13, x13) = pacs003(A, C, "MNDT-2", "EGP", 10_00, "RCUR", IBAN1);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(x13) }), "ISO-BIZ-MANDATE-STATE");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pain011("MNDT-2")) }), "ISO-BIZ-MANDATE-STATE");
ignore ingest(pain009("MNDT-3", A, B, IBAN1, 200_00, "EGP", "RCUR"));
ignore cmd(#decideMandate({ rail = "RTGS"; mandateId = "MNDT-3"; accepted = false; reason = ?"customer declined" }));
assert ((switch (PayCore.mandate(bs.payments, "RTGS", "MNDT-3")) { case (?m) m.state; case null #pending }) == #rejected);
ignore ingest(pain009("MNDT-4", A, B, IBAN1, 200_00, "EGP", "RCUR"));
let rAcc = ingest(pain012("MNDT-4", true));
assert (rAcc.verdict == #accepted and (switch (PayCore.mandate(bs.payments, "RTGS", "MNDT-4")) { case (?m) m.state; case null #pending }) == #active);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pain012("MNDT-4", false)) }), "ISO-BIZ-MANDATE-STATE");
ignore ingest(pain009("MNDT-5", A, B, IBAN1, 200_00, "EGP", "RCUR"));
ignore ingest(pain012("MNDT-5", false));
assert ((switch (PayCore.mandate(bs.payments, "RTGS", "MNDT-5")) { case (?m) m.state; case null #pending }) == #rejected);
let page = PayCore.mandates(bs.payments, "RTGS", null, 50);
assert (page.mandates.size() == 6);
Debug.print("count: mandates initiated, decided dual (accepted, rejected), amended, cancelled, reported on = 6");
Debug.print("count: collections under an active mandate reserved, counted and settled; final and one-off completing = 4");
Debug.print("count: collections refused (pending, amount, currency, account, parties, sequence, unknown, no mandate, completed, cancelled) = 11");

// ─── FI direct debit under a debit authority ─────────────────────────────────────
let (u20, x20) = pacs010(A, B, "EGP", 1_000_00);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(x20) }), "ISO-BIZ-AUTHORITY-UNKNOWN");
refuse(#grantDebitAuthority({ rail = "RTGS"; debtor = B.id; creditorBic = bic(A); currency = "EGP"; maxAmount = 0 }), "InvalidAuthority");
refuse(#grantDebitAuthority({ rail = "RTGS"; debtor = B.id; creditorBic = "NOPEEGCX"; currency = "EGP"; maxAmount = 1 }), "InvalidAuthority");
refuse(#grantDebitAuthority({ rail = "NOPE"; debtor = B.id; creditorBic = bic(A); currency = "EGP"; maxAmount = 1 }), "UnknownRail");
refuse(#revokeDebitAuthority({ rail = "RTGS"; debtor = B.id; creditorBic = bic(A); currency = "EGP" }), "UnknownAuthority");
ignore cmd(#grantDebitAuthority({ rail = "RTGS"; debtor = B.id; creditorBic = bic(A); currency = "EGP"; maxAmount = 5_000_00 }));
assert (PayCore.authorities(bs.payments, "RTGS").size() == 1);
let (u21, x21) = pacs010(A, B, "EGP", 1_000_00);
let trF1 = switch (outcomeOf(ingest(x21), "collected")) { case (#collected(c)) { assert (c.reserved); c.transfer }; case (_) 0 };
let ?rowF1 = SC.transferRowOf(bs.settlement, trF1) else { fail("row"); loop {} };
assert (rowF1.payer == B.id and rowF1.payee == A.id and stateOf(trF1) == #reserved);
let (u22, x22) = pacs010(A, B, "EGP", 5_000_01);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(x22) }), "ISO-BIZ-AUTHORITY-AMOUNT");
let (u23, x23) = pacs010(A, B, "USD", 1_00);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(x23) }), "ISO-BIZ-AUTHORITY-UNKNOWN");
ignore cmd(#revokeDebitAuthority({ rail = "RTGS"; debtor = B.id; creditorBic = bic(A); currency = "EGP" }));
let (u24, x24) = pacs010(A, B, "EGP", 1_00);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(x24) }), "ISO-BIZ-AUTHORITY-REVOKED");
Debug.print("count: FI direct debits under a dual debit authority reserved = 1; refused (no authority, over the maximum, other currency, revoked) = 4");

// ─── reversals ───────────────────────────────────────────────────────────────────
let tR = tx(A, B, "EGP", 2_000_00);
let trR = switch (onlyOutcome(ingest(pacs008([tR]))) ) { case (#prepared(p)) p.transfer; case (_) 0 };
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pacs007(tR.uetr, 2_000_00, "EGP", "DUPL")) }), "ISO-BIZ-REVERSAL-STATE");
ignore ingest(pacs002("MSG-r", [(tR.uetr, "ACSC", null)]));
assert (stateOf(trR) == #committed);
let ?rowR = SC.transferRowOf(bs.settlement, trR) else { fail("row"); loop {} };
let jhBefore = JCore.height(js);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pacs007(tR.uetr, 2_000_01, "EGP", "DUPL")) }), "ISO-BIZ-REVERSAL-AMOUNT");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pacs007(tR.uetr, 1_00, "USD", "DUPL")) }), "ISO-BIZ-REVERSAL-CURRENCY");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pacs007(nextUetr(), 1_00, "EGP", "DUPL")) }), "ISO-BIZ-UNKNOWN-UETR");
let rRev = ingest(pacs007With("RV-FIRST", tR.uetr, 500_00, "EGP", "DUPL"));
let trRev = switch (outcomeOf(rRev, "reversed")) { case (#reversed(x)) { assert (x.original == trR and x.reserved and x.committed and x.reason == "DUPL"); x.transfer }; case (_) 0 };
assert (stateOf(trRev) == #committed and stateOf(trR) == #committed);
let ?rowRev = SC.transferRowOf(bs.settlement, trRev) else { fail("row"); loop {} };
assert (rowRev.payer == B.id and rowRev.payee == A.id and rowRev.amount == 500_00);
let ?revView = SC.transfer(bs.settlement, sb(), trRev) else { fail("view"); loop {} };
assert (revView.correctionOf == rowR.posting);
assert (JCore.height(js) > jhBefore);
// the same reversal id again is refused; a customer's reversal (pain.007) by end-to-end id
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pacs007With("RV-FIRST", tR.uetr, 1_00, "EGP", "DUPL")) }), "ISO-BIZ-DUPLICATE-REVERSAL");
let rRev2 = ingest(pain007(tR.endToEndId, 100_00, "EGP"));
switch (outcomeOf(rRev2, "refused")) { case (#refused(x)) assert (x.rule == "ISO-BIZ-UNKNOWN-UETR"); case (_) {} };   // a pacs.008's reference is its UETR, not its end-to-end id
let rRev3 = ingest(pain007By(null, ?tR.uetr, 100_00, "EGP"));
switch (outcomeOf(rRev3, "reversed")) { case (#reversed(x)) assert (x.committed and x.original == trR); case (_) {} };
Debug.print("count: reversals (pacs.007, pain.007) as linked transfers posted in the message = 2; refused (state, amount, currency, unknown, duplicate, reference) = 6");

// ─── the multilateral settlement request ─────────────────────────────────────────
// the window so far holds the committed collections and reversals; close it and ask
let ?w1 = SC.openWindow(bs.settlement, "SCHEME", TODAY) else { fail("window"); loop {} };
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pacs029(Nat.toText(w1), [(bic(A), "EGP", 1, true), (bic(B), "EGP", 1, false)])) }), "ISO-BIZ-WINDOW-STATE");
ignore cmd(#closeSettlementWindow({ window = w1 }));
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pacs029("9999", [(bic(A), "EGP", 1, true), (bic(B), "EGP", 1, false)])) }), "ISO-BIZ-UNKNOWN-WINDOW");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pacs029(Nat.toText(w1), [("NOPEEGCX", "EGP", 1, true), (bic(B), "EGP", 1, false)])) }), "ISO-BIZ-UNKNOWN-AGENT");
// the nets the bank will compute: a brute-force fold over the window's committed transfers
func netsOfWindow(w : Nat) : [(Nat, Text, Int)] {
  let acc = Map.empty<(Nat, Text), Int>();
  func cmp(a : (Nat, Text), b : (Nat, Text)) : { #less; #equal; #greater } { switch (Nat.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o } };
  var cursor : ?Nat = null;
  label pages loop {
    let pg = SC.windowTransferIds(bs.settlement, w, cursor, 100);
    for (id in pg.ids.vals()) {
      let ?t = SC.transferRowOf(bs.settlement, id) else continue pages;
      if (t.state == #committed or t.state == #settled) {
        Map.add(acc, cmp, (t.payer, t.currency), (switch (Map.get(acc, cmp, (t.payer, t.currency))) { case (?v) v; case null 0 }) + t.amount);
        Map.add(acc, cmp, (t.payee, t.currency), (switch (Map.get(acc, cmp, (t.payee, t.currency))) { case (?v) v; case null 0 }) - t.amount);
      };
    };
    switch (pg.next) { case (?c) cursor := ?c; case null break pages };
  };
  Array.map<((Nat, Text), Int), (Nat, Text, Int)>(Map.toArray(acc), func(((p, c), v)) { (p, c, v) })
};
func bicOfId(id : Nat) : Text { let ?x = SC.participant(bs.settlement, id) else { fail("p"); loop {} }; x.bic };
let nets1 = netsOfWindow(w1);
let moves1 = Array.map<(Nat, Text, Int), (Text, Text, Nat, Bool)>(Array.filter<(Nat, Text, Int)>(nets1, func((_, _, v)) { v != 0 }), func((p, c, v)) { (bicOfId(p), c, Int.abs(v), v > 0) });
assert (moves1.size() >= 2);
// a wrong request first: one amount off by a cent; the settlement opens, netting judges it, the settlement aborts
let wrong = Array.tabulate<(Text, Text, Nat, Bool)>(moves1.size(), func(i) { let (b, c, a, d) = moves1[i]; if (i == 0) (b, c, a + 1, d) else (b, c, a, d) });
let rBad = ingest(pacs029(Nat.toText(w1), wrong));
let sidBad = switch (outcomeOf(rBad, "settlementRequested")) { case (#settlementRequested(q)) { assert (q.window == w1 and q.movements.size() == moves1.size()); q.settlement }; case (_) 0 };
let job1 : Core.SettlementJob = Core.newSettlementJob();
var done1 = false; var steps1 = 0;
while (not done1 and steps1 < 1000) { switch (Core.advanceSettlement(bs, bb(), js, jb(), bankP, clock, sidBad, job1, 50, recorder)) { case (#ok(a)) done1 := a.done; case (#err(e)) { fail("advance: " # debug_show (e)) } }; steps1 += 1 };
let ?stBad = SC.settlement(bs.settlement, sidBad) else { fail("settlement"); loop {} };
assert (stBad.state == #aborted);
assert ((switch (PayCore.settlementRequest(bs.payments, sidBad)) { case (?q) q.judged; case null null }) == ?false);
let ?wBad = SC.window(bs.settlement, w1) else { fail("w"); loop {} };
assert (wBad.state == #aborted);
// the window is aborted by the mismatch: a fresh window carries the next day's payments for the right request
let TOMORROW = TODAY + 1;
clock += DAY_NS;
ignore cmd(#journalRollBusinessDate({ day = TOMORROW }));
ignore cmd(#openSettlementWindow({ scheme = "SCHEME"; businessDate = TOMORROW }));
let ?w2 = SC.openWindow(bs.settlement, "SCHEME", TOMORROW) else { fail("window 2"); loop {} };
let tW1 = tx(A, B, "EGP", 700_00); let tW2 = tx(C, A, "EGP", 300_00); let tW3 = tx(B, D, "USD", 120_00);
for (t in [tW1, tW2, tW3].vals()) { ignore ingest(pacs008([t])); ignore ingest(pacs002("m", [(t.uetr, "ACSC", null)])) };
ignore cmd(#closeSettlementWindow({ window = w2 }));
let nets2 = netsOfWindow(w2);
let moves2 = Array.map<(Nat, Text, Int), (Text, Text, Nat, Bool)>(Array.filter<(Nat, Text, Int)>(nets2, func((_, _, v)) { v != 0 }), func((p, c, v)) { (bicOfId(p), c, Int.abs(v), v > 0) });
let rGood = ingest(pacs029(Nat.toText(w2), moves2));
let sidGood = switch (outcomeOf(rGood, "settlementRequested")) { case (#settlementRequested(q)) q.settlement; case (_) 0 };
let job2 : Core.SettlementJob = Core.newSettlementJob();
var done2 = false; var steps2 = 0;
while (not done2 and steps2 < 1000) { switch (Core.advanceSettlement(bs, bb(), js, jb(), bankP, clock, sidGood, job2, 50, recorder)) { case (#ok(a)) done2 := a.done; case (#err(e)) { fail("advance: " # debug_show (e)) } }; steps2 += 1 };
let ?stGood = SC.settlement(bs.settlement, sidGood) else { fail("settlement"); loop {} };
assert (stGood.state == #settled);
assert ((switch (PayCore.settlementRequest(bs.payments, sidGood)) { case (?q) q.judged; case null null }) == ?true);
for (n in stGood.nets.vals()) { var named = false; for ((b, c, a, d) in moves2.vals()) { if (b == bicOfId(n.participant) and c == n.currency) { named := true; assert (a == (if (n.debits > n.credits) n.debits - n.credits else n.credits - n.debits) and d == (n.debits > n.credits)) } }; assert (named or n.debits == n.credits) };
Debug.print("count: multilateral settlement requests: a wrong one judged and aborted with the difference on record, a right one settled with nets equal to the request = 2; refused (open window, unknown window, unknown participant) = 3");

// ─── cash management: reporting requests, expected receipts, liquidity ──────────────
let setA = entryOf(setOf(A, "EGP"));
let rRq = ingest(camt060(A, ?setA.identifier, "camt.052.001.08"));
switch (outcomeOf(rRq, "reportRequested")) { case (#reportRequested(q)) { assert (q.kind == "camt.052.001.08" and q.account == ?setOf(A, "EGP") and q.fromDay == ?TODAY); }; case (_) {} };
let rRq2 = ingest(camt060(A, ?"NOPE-ACCOUNT", "camt.053.001.08"));
switch (outcomeOf(rRq2, "refused")) { case (#refused(x)) assert (x.rule == "ISO-BIZ-UNKNOWN-ACCOUNT"); case (_) {} };
let rRq3 = ingest(camt060(A, null, "camt.054.001.08"));
switch (outcomeOf(rRq3, "refused")) { case (#refused(x)) assert (x.rule == "ISO-BIZ-REPORT-KIND"); case (_) {} };
// the camt.052 the bank would answer with validates under the profile
let rpt = IsoMessages.camt052Xml("THEBES-052-T", NOW_T, "RQ-1", ?("MSG-9", "camt.060.001.05"), ?setA.identifier, Nat.toText(setOf(A, "EGP")), "EGP", 2, TODAY, TODAY,
  [{ code = "OPBD"; amount = { currency = "EGP"; minor = 10_000_000_00 }; credit = true; day = TODAY }],
  [{ reference = "R1"; amount = { currency = "EGP"; minor = 700_00 }; credit = false; bookingDay = TODAY; valueDay = TODAY; uetr = ?tW1.uetr; endToEndId = ?tW1.endToEndId; block = 12; counterparty = ?"B"; remittance = ["x"] }]);
assert (validUnderProfile(rpt));
// an expected receipt, matched by the payment that arrives
let uExp = nextUetr();
let rNt = ingest(camt057(setA.identifier, [("IT1", uExp, 250_00, "EGP", B)]));
switch (outcomeOf(rNt, "receiptExpected")) { case (#receiptExpected(e)) assert (e.reference == uExp and e.amount == 250_00 and e.account == ?setOf(A, "EGP")); case (_) {} };
assert ((switch (PayCore.expectedReceipt(bs.payments, "RTGS", uExp)) { case (?e) e.matched; case null ?0 }) == null);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(camt057(setA.identifier, [("IT2", uExp, 250_00, "EGP", B)])) }), "ISO-BIZ-DUPLICATE-EXPECTATION");
let tExp : IsoMessages.OutboundTransfer = { tx(B, A, "EGP", 250_00) with uetr = uExp };
let trExp = switch (onlyOutcome(ingest(pacs008([tExp]))) ) { case (#prepared(p)) p.transfer; case (_) 0 };
assert ((switch (PayCore.expectedReceipt(bs.payments, "RTGS", uExp)) { case (?e) e.matched; case null null }) == ?trExp);
// liquidity: settlement account to position and back, the receipt derived
let posA2 = entryOf(posOf(A, "EGP")); let setA2 = setA;
let posBefore = JCore.balance(js, "2130", ?posA2.subledger, "EGP"); let setBefore = JCore.balance(js, "2140", ?setA2.subledger, "EGP");
let rLq = ingest(camt050(1_000_00, "EGP", ?A, null, "LQ-1"));
switch (outcomeOf(rLq, "liquidityTransferred")) { case (#liquidityTransferred(l)) { assert (l.participant == A.id and l.toPosition and l.amount == 1_000_00); assert (jb().get(l.posting) != null) }; case (_) {} };
let posAfter = JCore.balance(js, "2130", ?posA2.subledger, "EGP"); let setAfter = JCore.balance(js, "2140", ?setA2.subledger, "EGP");
assert (posAfter.creditsPosted == posBefore.creditsPosted + 1_000_00 and setAfter.debitsPosted == setBefore.debitsPosted + 1_000_00);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(camt050(1_000_00, "EGP", ?A, null, "LQ-1")) }), "ISO-BIZ-DUPLICATE-UETR");
let rLq2 = ingest(camt050(400_00, "EGP", null, ?A, "LQ-2"));
switch (outcomeOf(rLq2, "liquidityTransferred")) { case (#liquidityTransferred(l)) assert (not l.toPosition); case (_) {} };
let posAfter2 = JCore.balance(js, "2130", ?posA2.subledger, "EGP");
assert (posAfter2.debitsPosted == posAfter.debitsPosted + 400_00);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(camt050(1_00, "EGP", null, null, "LQ-3")) }), "ISO-BIZ-AGENT-BIC");
let noCcy = Text.replace(camt050(1_00, "EGP", ?A, null, "LQ-4"), #text "<AmtWthCcy Ccy=\"EGP\">1.00</AmtWthCcy>", "<AmtWthtCcy>1.00</AmtWthtCcy>");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(noCcy) }), "ISO-BIZ-CURRENCY");
assert (validUnderProfile(IsoMessages.camt025Xml("CAMT025-T", NOW_T, "MSG-1", ?"camt.050.001.05", "ACPT", ?"posting 12")));
Debug.print("count: reporting requests recorded = 1, refused (unknown account, kind) = 2; expected receipts recorded and matched = 1, duplicate refused = 1; liquidity transfers posted both ways = 2, refused (duplicate, no participant, no currency) = 3");

// ─── exceptions and investigations, administration ─────────────────────────────
var cases = 0;
for ((fam, root, tail) in [("camt.026.001.07", "UblToApply", "<Justfn><MssngOrIncrrctInf><MssngInf><Cd>MS01</Cd></MssngInf></MssngOrIncrrctInf></Justfn>"), ("camt.027.001.07", "ClmNonRct", ""), ("camt.028.001.09", "AddtlPmtInf", "<Inf><InstrForNxtAgt><InstrInf>please apply</InstrInf></InstrForNxtAgt></Inf>"), ("camt.087.001.06", "ReqToModfyPmt", "<Mod><IntrBkSttlmAmt Ccy=\"EGP\">100.00</IntrBkSttlmAmt></Mod>")].vals()) {
  let r = ingest(investigation(fam, root, A, B, tW1.uetr, tail));
  switch (outcomeOf(r, "caseRecorded")) { case (#caseRecorded(c)) { assert (c.uetr == ?tW1.uetr and c.transfer == ?transferOfUetr(tW1.uetr)); cases += 1 }; case (_) {} };
};
let rUnk = ingest(investigation("camt.027.001.07", "ClmNonRct", A, B, nextUetr(), ""));
switch (outcomeOf(rUnk, "caseRecorded")) { case (#caseRecorded(c)) assert (c.transfer == null); case (_) {} };
let rRs = ingest(admi006(A, "MSG-2"));   // the first pain.009 was refused and took no id; MSG-2 is the mandate's
switch (outcomeOf(rRs, "resendRequested")) { case (#resendRequested(x)) { assert (x.reference == "MSG-2" and x.message == ?rM1.message) }; case (_) {} };
let rRs2 = ingest(admi006(A, "MSG-NONE"));
switch (outcomeOf(rRs2, "resendRequested")) { case (#resendRequested(x)) assert (x.message == null); case (_) {} };
let rPr = ingest(admi017("EODP"));
switch (outcomeOf(rPr, "processingRequested")) { case (#processingRequested(x)) assert (x.requestType == "EODP" and x.session == ?"AB12"); case (_) {} };
assert (validUnderProfile(IsoMessages.admi007Xml("ADMI007-T", NOW_T, "MSG-1", "ACPT", ?"acknowledged")));
Debug.print("count: investigation cases recorded against their payment = " # Nat.toText(cases) # " (+1 with no payment found); administrative requests recorded = 3");

// ─── the business file ─────────────────────────────────────────────────────────
ignore cmd(#openSettlementWindow({ scheme = "SCHEME"; businessDate = TOMORROW }));   // the day's next window, after the settled one
let f1 = tx(A, B, "EGP", 11_00); let f2 = tx(B, C, "EGP", 12_00);
let file = head002([pacs008([f1]), pacs008([f2]), pacs002("m", [(f1.uetr, "ACSC", null)])], 3);
let hBefore = Core.height(bs);
let rF = ingest(file);
assert (rF.family == #head002 and rF.verdict == #accepted);
switch (outcomeOf(rF, "fileReceived")) { case (#fileReceived(x)) { assert (x.messages.size() == 3 and x.declared == 3); for (m in x.messages.vals()) assert (m < rF.message and m >= hBefore) }; case (_) {} };
assert (stateOf(transferOfUetr(f1.uetr)) == #committed and stateOf(transferOfUetr(f2.uetr)) == #reserved);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(head002([pacs008([tx(A, B, "EGP", 1_00)])], 2)) }), "ISO-BIZ-COUNT");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(head002([], 0)) }), "ISO-BIZ-REQUIRED");
Debug.print("count: business files ingested with every payload a message of its own = 1 (3 payloads); refused (count, empty) = 2");

// ─── P-4 and replay ────────────────────────────────────────────────────────────
var blocks = 0; var i = 0;
while (i < Core.height(bs)) { switch (bb().get(i)) { case (?{ event = #payments(#messageReceived(_)) }) blocks += 1; case (_) {} }; i += 1 };
assert (blocks == PayCore.counts(bs.payments).messages);
Debug.print("count: message blocks, one per received message (the file's payloads included) = " # Nat.toText(blocks));
Debug.print("count: refusals shown to leave the journal untouched (fingerprint unchanged, one audit block) = " # Nat.toText(fpChecks));
let fresh = Core.replay(installer, BankMemLog.blocks(bchain));
assert (Core.fingerprint(fresh) == Core.fingerprint(bs));
let freshJ = JCore.replay(bankP, JMemLog.blocks(jchain));
assert (JCore.fingerprint(freshJ) == JCore.fingerprint(js));
Debug.print("count: bank and journal blocks replayed to identical fingerprints = " # Nat.toText(Core.height(bs)) # " + " # Nat.toText(JCore.height(js)));
Debug.print("PAYMENTS BREADTH TEST GREEN");
