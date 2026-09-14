// Payments.test.mo; ISO 20022 messaging on the journal, on the pure state machine.
//
// The world of Settlement.test.mo; scheme, participants with ISO 9362 BICs, three accounts a
// currency, caps; with a rail declared on the scheme; then messages, each one block:
//
//   M-1  message to posting, exhaustively: a pacs.008 produces the reservation (one per transaction,
//        keyed on its UETR); a rejected message produces none; pacs.002 ACSC posts, pacs.002 RJCT
//        voids; a pacs.004 produces a transfer of its own, payee to payer, whose reservation carries
//        the correction link to the original posting, which stays untouched and retrievable; a
//        pacs.009 the same as a pacs.008; a three-transaction message with one unknown agent does
//        the two and refuses the one; duplicates (UETR, message id, bytes) refused; every case
//        fingerprint-checked (a refused message leaves the journal's fingerprint where it was and
//        adds exactly its audit block to the bank's)
//   M-2  a held payment holds funds: the rail's threshold holds a transfer RESERVED, the available
//        balance reflects it while the booked does not, a pacs.002 ACSC cannot post it (#Held), the
//        dual release posts, the dual rejection voids, both recorded
//   M-4  the misplaced XML declaration is refused with a stable rule id, and twenty related
//        malformations with theirs
//   M-9  every message that moved money maps to exactly one reservation or posting; every message
//        that did not is read and shown non-money-moving; the split is exhaustive
//   P-1  the reservation's key is a pure function of (scheme, transfer) and the transfer of the UETR:
//        re-derived for every message, no counter, no timestamp
//   P-4  every message has its audit record (accepted, held or refused); every settlement posting
//        made by a message names a transfer whose UETR is in an accepted message
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
import Posting "../src/bank/Posting";
import S "../src/bank/Screening";
import BankMemLog "support/BankMemLog";
import JMemLog "support/JournalMemLog";

var seed : Nat32 = 0x7B7B_1E01;
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

// ─── M-1: message to posting ───────────────────────────────────────────────────
let A = parts[0]; let B = parts[1]; let C = parts[2];
var moneyMessages = 0; var moneyless = 0; var fpChecks = 0;
func journalUnchangedBy(f : () -> Core.IngestResult) : Core.IngestResult {
  let jf = JCore.fingerprint(js); let bh = Core.height(bs);
  let r = f();
  assert (JCore.fingerprint(js) == jf and Core.height(bs) == bh + 1);   // the audit block, nothing else
  fpChecks += 1;
  r
};
// a pacs.008: prepared and reserved, the reservation's key the pure function of (scheme, transfer)
let t1 = tx(A, B, "EGP", 1_200_00);
let r1 = ingest(pacs008([t1]));
assert (r1.verdict == #accepted and r1.family == #pacs008);
let tr1 = switch (onlyOutcome(r1)) { case (#prepared(p)) { assert (p.reserved and p.uetr == t1.uetr); p.transfer }; case (o) { fail(debug_show (o)); 0 } };
assert (stateOf(tr1) == #reserved and transferOfUetr(t1.uetr) == tr1);
moneyMessages += 1;
let ?res1 = SC.transferRowOf(bs.settlement, tr1) else { fail("row"); loop {} };
let ?pendingBlock = jb().get(switch (res1.reservation) { case (?x) x; case null 0 }) else { fail("no pending"); loop {} };
switch (pendingBlock.event) { case (#pending(p)) { assert (p.record.idempotencyKey == Posting.key("PRINCIPLE_VALUE", ["SCHEME", Nat.toText(tr1)])); assert (p.record.sourceRef.kind == "PRINCIPLE_VALUE") }; case (_) fail("not a pending") };
Debug.print("count: reservations keyed by the pure function of (scheme, transfer) = 1");
// pacs.002 ACSC posts it
let r2 = ingest(pacs002("MSG-1", [(t1.uetr, "ACSC", null)]));
switch (onlyOutcome(r2)) { case (#fulfilled(f)) assert (f.transfer == tr1); case (o) fail(debug_show (o)) };
assert (stateOf(tr1) == #committed);
moneyMessages += 1;
// pacs.002 RJCT voids another
let t2 = tx(B, C, "USD", 300_00);
let tr2 = switch (onlyOutcome(ingest(pacs008([t2])))) { case (#prepared(p)) p.transfer; case (o) { fail(debug_show (o)); 0 } };
let r3 = ingest(pacs002("MSG-3", [(t2.uetr, "RJCT", ?"AC01")]));
switch (onlyOutcome(r3)) { case (#rejected(x)) { assert (x.transfer == tr2 and x.reason == "AC01") }; case (o) fail(debug_show (o)) };
assert (stateOf(tr2) == #abortedRejected);
moneyMessages += 2;
// a status that moves no money: ACSP / PDNG acknowledged, RCVD acknowledged
let t3 = tx(A, C, "EGP", 75_00);
let tr3 = switch (onlyOutcome(ingest(pacs008([t3])))) { case (#prepared(p)) p.transfer; case (o) { fail(debug_show (o)); 0 } };
moneyMessages += 1;
let r4 = journalUnchangedBy(func() : Core.IngestResult { ingest(pacs002("MSG-5", [(t3.uetr, "ACSP", null), (t3.uetr, "PDNG", null)])) });
assert (r4.verdict == #accepted and r4.outcomes.size() == 2);
switch (r4.outcomes[0]) { case (#acknowledged(a)) assert (a.status == "ACSP" and a.transfer == tr3); case (o) fail(debug_show (o)) };
assert (stateOf(tr3) == #reserved);
moneyless += 1;
// pacs.004: the return of the committed payment; a transfer of its own, payee to payer, linked
let r5 = ingest(pacs004([("RTR-1", t1.uetr, 1_200_00, "EGP")]));
let trRet = switch (onlyOutcome(r5)) { case (#returned(x)) { assert (x.original == tr1 and x.reserved and x.committed); x.transfer }; case (o) { fail(debug_show (o)); 0 } };
assert (stateOf(tr1) == #committed);   // the original untouched
let ?retRow = SC.transferRowOf(bs.settlement, trRet) else { fail("row"); loop {} };
assert (retRow.payer == B.id and retRow.payee == A.id and retRow.amount == 1_200_00 and retRow.state == #committed);   // an instruction: posted in its message
let ?retView = SC.transfer(bs.settlement, sb(), trRet) else { fail("view"); loop {} };
assert (retView.correctionOf == res1.reservation);
let ?retPending = jb().get(switch (retRow.reservation) { case (?x) x; case null 0 }) else { fail("no pending"); loop {} };
switch (retPending.event) { case (#pending(p)) { switch (p.record.relation) { case (?rel) { assert (rel.kind == #correction and ?rel.original == res1.reservation) }; case null fail("the return is not linked to its original") } }; case (_) fail("not a pending") };
// the original's posting is retrievable, unchanged: the same record
let ?origNow = jb().get(switch (res1.reservation) { case (?x) x; case null 0 }) else { fail("orig"); loop {} };
assert (origNow.hash == pendingBlock.hash);
moneyMessages += 1;
// no fees on a return: its post is one journal block after its reservation
let ?retRow2 = SC.transferRowOf(bs.settlement, trRet) else { fail("row"); loop {} };
switch (retRow2.reservation, retRow2.posting) { case (?res, ?post) assert (post == res); case (_, _) fail("the return has no posting") };
var feeBlocks = 0;
var jj = (switch (retRow2.reservation) { case (?x) x; case null 0 }) + 1;
while (jj < JCore.height(js)) { switch (jb().get(jj)) { case (?{ event = #posted(rec) }) { if (Text.contains(rec.sourceRef.id, #text (Nat.toText(trRet)))) feeBlocks += 1 }; case (_) {} }; jj += 1 };
assert (feeBlocks == 0);
// a status for the return names the original UETR and the return id in OrgnlTxId: acknowledged against the return
let rRetStatus = journalUnchangedBy(func() : Core.IngestResult { ingest(Text.replace(pacs002("MSG-7", [(t1.uetr, "ACSP", null)]), #text "<OrgnlUETR>", "<OrgnlTxId>RTR-1</OrgnlTxId><OrgnlUETR>")) });
switch (onlyOutcome(rRetStatus)) { case (#acknowledged(a)) assert (a.transfer == trRet); case (o) fail(debug_show (o)) };
moneyless += 1;
// a second return of the same payment for more than it was: refused; a partial return: admitted
let r6 = journalUnchangedBy(func() : Core.IngestResult { ingest(pacs004([("RTR-2", t1.uetr, 2_000_00, "EGP")])) });
refusedWith(r6, "ISO-BIZ-RETURN-AMOUNT");
let rPartial = ingest(pacs004([("RTR-3", t1.uetr, 200_00, "EGP")]));
switch (onlyOutcome(rPartial)) { case (#returned(x)) assert (x.reserved); case (o) fail(debug_show (o)) };
moneyMessages += 1;
// a return of a transfer that was never committed: refused, nothing moved
let r7 = journalUnchangedBy(func() : Core.IngestResult { ingest(pacs004([("RTR-4", t3.uetr, 1_00, "EGP")])) });
refusedWith(r7, "ISO-BIZ-RETURN-STATE");
// pacs.009: the same mapping, the FI debtor and creditor as the participants
let r8 = ingest(pacs009(C, A, "USD", 5_000_00));
switch (onlyOutcome(r8)) { case (#prepared(p)) assert (p.reserved); case (o) fail(debug_show (o)) };
assert (r8.family == #pacs009);
moneyMessages += 1;
// three transactions, one naming an agent that is not a participant: two prepared, one refused
let tUnknown : IsoMessages.OutboundTransfer = { tx(A, B, "EGP", 10_00) with creditorAgent = "NOPEEGCX" };
let r9 = ingest(pacs008([tx(A, B, "EGP", 10_00), tUnknown, tx(B, A, "EGP", 20_00)]));
assert (r9.verdict == #accepted and r9.outcomes.size() == 3);
var prepared9 = 0; var refused9 = 0;
for (o in r9.outcomes.vals()) { switch (o) { case (#prepared(p)) { assert (p.reserved); prepared9 += 1 }; case (#refused(x)) { assert (x.rule == "ISO-BIZ-UNKNOWN-AGENT"); refused9 += 1 }; case (_) {} } };
assert (prepared9 == 2 and refused9 == 1);
moneyMessages += 1;
// refused whole, nothing moved: a duplicate UETR, a duplicate message id, the same bytes twice,
// a currency the journal does not know, an amount with too many decimals, a zero amount, the same
// participant on both sides, a deactivated participant, a status for an unknown UETR, a status
// without a UETR
let dupXml = pacs008([{ tx(A, B, "EGP", 1_00) with uetr = t1.uetr }]);
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(dupXml) }), "ISO-BIZ-DUPLICATE-UETR");
let once = pacs008([tx(A, B, "EGP", 1_00)]);
ignore ingest(once); moneyMessages += 1;
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(once) }), "ISO-BIZ-DUPLICATE-MESSAGE");
let sameId = Text.replace(pacs008([tx(A, B, "EGP", 2_00)]), #text ("<MsgId>MSG-" # Nat.toText(msgNo) # "</MsgId>"), "<MsgId>MSG-1</MsgId>");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(sameId) }), "ISO-BIZ-DUPLICATE-MESSAGE");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pacs008([tx(A, B, "JPY", 1_00)])) }), "ISO-BIZ-CURRENCY");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(Text.replace(pacs008([tx(A, B, "EGP", 1_00)]), #text "\">1.00</IntrBkSttlmAmt>", "\">1.005</IntrBkSttlmAmt>")) }), "ISO-BIZ-AMOUNT");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pacs008([tx(A, B, "EGP", 0)])) }), "ISO-BIZ-AMOUNT");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pacs008([tx(A, A, "EGP", 1_00)])) }), "ISO-BIZ-SAME-PARTICIPANT");
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pacs002("MSG-1", [("8f2b5e70-1d44-4e6a-9c4a-000000000000", "ACSC", null)])) }), "ISO-BIZ-UNKNOWN-UETR");
let noUetr = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:pacs.002.001.10\"><FIToFIPmtStsRpt><GrpHdr><MsgId>" # nextMsgId() # "</MsgId><CreDtTm>" # NOW_T # "</CreDtTm></GrpHdr><TxInfAndSts><TxSts>ACSC</TxSts></TxInfAndSts></FIToFIPmtStsRpt></Document>";
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(noUetr) }), "ISO-BIZ-UETR-REQUIRED");
let deact = newParticipant(70, CAP);
ignore cmd(#deactivateParticipant({ participant = deact.id }));
refusedWith(journalUnchangedBy(func() : Core.IngestResult { ingest(pacs008([tx(A, deact, "EGP", 1_00)])) }), "ISO-BIZ-PARTICIPANT-INACTIVE");
// the cap: a payment past the payer's net debit cap is prepared and FAILED by the journal, recorded so
let capA = newParticipant(72, 10_000_00); let capB = newParticipant(73, 10_000_00);
let r10 = ingest(pacs008([tx(capA, capB, "EGP", 10_000_01)]));
switch (onlyOutcome(r10)) { case (#prepared(p)) { assert (not p.reserved); assert (stateOf(p.transfer) == #failed) }; case (o) fail(debug_show (o)) };
moneyMessages += 1;
Debug.print("count: messages that moved money = " # Nat.toText(moneyMessages));
Debug.print("count: messages read and shown non-money-moving = " # Nat.toText(moneyless));
Debug.print("count: refused messages leaving the journal fingerprint unchanged and adding exactly their audit block = " # Nat.toText(fpChecks));

// ─── M-2: a held payment holds funds ───────────────────────────────────────────
let tHeld = tx(A, B, "EGP", HOLD_ABOVE);
let posA = posOf(A, "EGP");
let before = JCore.balance(js, "2130", ?entryOf(posA).subledger, "EGP");
let rH = ingest(pacs008([tHeld]));
assert (rH.verdict == #held);
let trH = switch (onlyOutcome(rH)) { case (#held(h)) { assert (h.rule == "HOLD-AMOUNT-EGP"); h.transfer }; case (o) { fail(debug_show (o)); 0 } };
assert (stateOf(trH) == #reserved and Core.holdOfTransfer(bs, trH) == ?"HOLD-AMOUNT-EGP");
let during = JCore.balance(js, "2130", ?entryOf(posA).subledger, "EGP");
assert (during.debitsPosted == before.debitsPosted and during.debitsPending == before.debitsPending + HOLD_ABOVE);   // available reflects it, booked does not
// a status report cannot post a held payment
let rHs = journalUnchangedBy(func() : Core.IngestResult { ingest(pacs002("x", [(tHeld.uetr, "ACSC", null)])) });
refusedWith(rHs, "ISO-BIZ-FULFIL");
assert (Text.contains(debug_show (rHs.outcomes), #text "Held"));
// the dual release posts it, in the block after the release's
refuse(#releaseHold({ transfer = tr3; reason = "not held" }), "NotHeld");
refuse(#releaseHold({ transfer = trH; reason = "" }), "InvalidRail");
let relBlock = cmd(#releaseHold({ transfer = trH; reason = "reviewed, clean" }));
switch (Core.settleHold(bs, bb(), js, jb(), bankP, clock, #holdReleased({ transfer = trH; reason = "reviewed, clean" }), recorder)) { case (#ok(())) {}; case (#err(e)) fail(debug_show (e)) };
assert (stateOf(trH) == #committed and Core.holdOfTransfer(bs, trH) == null);
let after = JCore.balance(js, "2130", ?entryOf(posA).subledger, "EGP");
assert (after.debitsPosted >= before.debitsPosted + HOLD_ABOVE);
refuse(#releaseHold({ transfer = trH; reason = "again" }), "NotHeld");
// a blocked BIC and a blocked name hold too; the rejection voids
let blocked = newParticipant(71, CAP);   // index 71 → BKCT..; the blocked BIC is BKZYEGCX: rename through a fresh scheme participant is not possible, so hold by name
let tName : IsoMessages.OutboundTransfer = { tx(A, B, "EGP", 1_00) with debtorName = "Sanctioned Trading LLC" };
let rN = ingest(pacs008([tName]));
let trN = switch (onlyOutcome(rN)) { case (#held(h)) { assert (h.rule == "HOLD-NAME"); h.transfer }; case (o) { fail(debug_show (o)); 0 } };
ignore cmd(#rejectHold({ transfer = trN; reason = "sanctions match" }));
switch (Core.settleHold(bs, bb(), js, jb(), bankP, clock, #holdRejected({ transfer = trN; reason = "sanctions match" }), recorder)) { case (#ok(())) {}; case (#err(e)) fail(debug_show (e)) };
assert (stateOf(trN) == #abortedRejected);
ignore blocked; ignore relBlock;
Debug.print("count: payments held by the rail's rules, the available balance reflecting the hold = 2");
Debug.print("count: holds released (posted) and rejected (voided), both dual and recorded = 2");

// ─── M-4: the misplaced declaration and its relatives ──────────────────────────
let good = pacs008([tx(A, B, "EGP", 5_00)]);
let noDecl = Text.replace(good, #text "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n", "");
let malformed : [(Text, Text)] = [
  ("XML-DECL-POSITION", "<Document xmlns=\"x\"/>" # good),                                  // a declaration after an element (the pacs.003 fixture's defect)
  ("XML-DECL-POSITION", " " # good),                                                           // after whitespace
  ("XML-DECL-POSITION", "<!-- c -->" # good),                                                  // after a comment
  ("XML-DECL-POSITION", Text.replace(noDecl, #text "<GrpHdr>", "<?xml version=\"1.0\"?><GrpHdr>")),   // in the middle
  ("XML-DECL-DUPLICATE", Text.replace(good, #text "<Document", "<?xml version=\"1.0\"?><Document")),
  ("XML-DECL-ENCODING", Text.replace(good, #text "UTF-8", "ISO-8859-1")),
  ("XML-BOM-POSITION", Text.replace(good, #text "<Document", "\u{FEFF}<Document")),
  ("XML-UNSAFE-DECL", Text.replace(good, #text "<Document", "<!DOCTYPE Document [<!ENTITY x \"y\">]><Document")),
  ("XML-UNSAFE-DECL", Text.replace(good, #text "<GrpHdr>", "<!ENTITY x \"y\"><GrpHdr>")),
  ("XML-PI", Text.replace(good, #text "<Document", "<?xml-stylesheet href=\"x\"?><Document")),
  ("XML-PI", Text.replace(good, #text "<GrpHdr>", "<?php echo 1 ?><GrpHdr>")),
  ("XML-TAG-MISMATCH", Text.replace(good, #text "</GrpHdr>", "</GrpHd>")),
  ("XML-UNCLOSED", Text.replace(good, #text "</Document>", "")),
  ("XML-ROOT", good # "<Extra/>"),
  ("XML-ROOT", Text.replace(good, #text "<Document", "text<Document")),
  ("XML-ENTITY", Text.replace(good, #text "<MsgId>", "<MsgId>&nbsp;")),
  ("XML-ATTRIBUTE", Text.replace(good, #text "<Document xmlns=", "<Document xmlns xmlns=")),
  ("XML-ATTRIBUTE", Text.replace(good, #text "Ccy=\"EGP\"", "Ccy=\"EGP\" Ccy=\"EGP\"")),
  ("XML-CHAR", Text.replace(good, #text "<MsgId>", "<MsgId>a<b")),
  ("XML-NAMESPACE", Text.replace(good, #text "<GrpHdr>", "<p:GrpHdr>")),
  ("XML-NAME", Text.replace(good, #text "<GrpHdr>", "<1GrpHdr>")),
];
var malformedRefused = 0;
for ((rule, xml) in malformed.vals()) {
  let r = journalUnchangedBy(func() : Core.IngestResult { ingest(xml) });
  assert (r.verdict == #refused and r.outcomes.size() == 0);
  if (r.issues.size() == 0 or r.issues[0].rule != rule) fail("wanted " # rule # " got " # debug_show (r.issues));
  malformedRefused += 1;
};
Debug.print("count: the misplaced XML declaration refused with its rule id = 1");
Debug.print("count: malformations refused with stable rule ids = " # Nat.toText(malformedRefused));
// and schema refusals: an unknown element, a missing required one, a wrong enumeration, a bad BIC pattern
let schemaBad : [(Text, Text)] = [
  ("ISO-XSD-UNEXPECTED", Text.replace(good, #text "<NbOfTxs>", "<Bogus>1</Bogus><NbOfTxs>")),
  ("ISO-XSD-MISSING", Text.replace(good, #text "<SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf>", "")),
  ("ISO-XSD-ENUM", Text.replace(good, #text "<ChrgBr>SLEV</ChrgBr>", "<ChrgBr>SLEX</ChrgBr>")),
  ("ISO-XSD-PATTERN", Text.replace(good, #text ("<BICFI>" # bicOf(B) # "</BICFI>"), "<BICFI>bk12egcx</BICFI>")),
  ("ISO-XSD-ROOT", Text.replace(good, #text "pacs.008.001.08", "pacs.008.001.07")),
];
var schemaRefused = 0;
for ((rule, xml) in schemaBad.vals()) { let r = journalUnchangedBy(func() : Core.IngestResult { ingest(xml) }); refusedWith(r, rule); schemaRefused += 1 };
Debug.print("count: schema-invalid messages refused with the profile's rule ids = " # Nat.toText(schemaRefused));

// ─── M-9 / P-4: the split, exhaustive ──────────────────────────────────────────
// every message block: its outcomes that moved money name a transfer whose reservation exists; a
// message with no such outcome moved nothing (no settlement block follows it before the next message)
var messages = 0; var moving = 0; var notMoving = 0; var postingsNamed = 0;
var i = 0;
while (i < Core.height(bs)) {
  switch (bb().get(i)) {
    case (?{ event = #payments(#messageReceived(m)) }) {
      messages += 1;
      var moved = false;
      for (o in m.outcomes.vals()) {
        switch (o) {
          case (#prepared(p)) { if (p.reserved) { let ?row = SC.transferRowOf(bs.settlement, p.transfer) else { fail("row"); loop {} }; assert (row.reservation != null); postingsNamed += 1; moved := true } };
          case (#held(h)) { let ?row = SC.transferRowOf(bs.settlement, h.transfer) else { fail("row"); loop {} }; assert (row.reservation != null); postingsNamed += 1; moved := true };
          case (#returned(x)) { if (x.reserved) { postingsNamed += 1; moved := true } };
          case (#fulfilled(f)) { let ?row = SC.transferRowOf(bs.settlement, f.transfer) else { fail("row"); loop {} }; assert (row.posting != null); postingsNamed += 1; moved := true };
          case (#rejected(_)) { moved := true };
          case (#acknowledged(_) or #refused(_)) {};
        };
      };
      if (moved) moving += 1 else notMoving += 1;
    };
    case (_) {};
  };
  i += 1;
};
assert (messages == moving + notMoving);
// and in the other direction: every PRINCIPLE_VALUE reservation made since the rail was declared names a transfer whose UETR is in an accepted message's outcomes
var principle = 0; var traced = 0;
let uetrs = Map.empty<Text, Nat>();
i := 0;
while (i < Core.height(bs)) {
  switch (bb().get(i)) { case (?{ event = #payments(#messageReceived(m)) }) { for (o in m.outcomes.vals()) { switch (o) { case (#prepared(p)) { if (p.reserved) Map.add(uetrs, Text.compare, p.uetr, i) }; case (#held(h)) Map.add(uetrs, Text.compare, h.uetr, i); case (#returned(x)) { if (x.reserved) Map.add(uetrs, Text.compare, x.uetr, i) }; case (_) {} } } }; case (_) {} };
  i += 1;
};
i := 0;
while (i < JCore.height(js)) {
  switch (jb().get(i)) {
    case (?{ event = #pending(p) }) {
      if (p.record.sourceRef.kind == "PRINCIPLE_VALUE") {
        principle += 1;
        // the transfer id is the second part of the sourceRef id; its reference is its UETR
        let parts2 = Array.fromIter<Text>(Text.split(p.record.sourceRef.id, #char '/'));
        let tid = switch (Nat.fromText(parts2[1])) { case (?n) n; case null { fail("id"); 0 } };
        let ?v = SC.transfer(bs.settlement, sb(), tid) else { fail("transfer"); loop {} };
        if (Map.containsKey(uetrs, Text.compare, v.reference)) traced += 1;
      };
    };
    case (_) {};
  };
  i += 1;
};
Debug.print("count: message blocks = " # Nat.toText(messages));
Debug.print("count: messages that moved money, each naming its reservations or postings = " # Nat.toText(moving));
Debug.print("count: messages shown non-money-moving = " # Nat.toText(notMoving));
Debug.print("count: reservations and postings named by messages = " # Nat.toText(postingsNamed));
Debug.print("count: PRINCIPLE_VALUE reservations on the journal traced to an accepted message = " # Nat.toText(traced) # " of " # Nat.toText(principle));

// ─── the pacs.002 answers, schema-valid under our own profile ───────────────────
var reports = 0;
i := 0;
while (i < Core.height(bs)) {
  switch (bb().get(i)) {
    case (?{ event = #payments(#messageReceived(_)) }) {
      let ?xml = Core.statusReportXml(bs, bb(), clock, i) else { fail("no report"); loop {} };
      let v = Core.validateMessage(Text.encodeUtf8(xml));
      if (v.issues.size() > 0) fail("our pacs.002 fails our profile: " # debug_show (v.issues));
      assert (v.family == "pacs.002.001.10");
      reports += 1;
    };
    case (_) {};
  };
  i += 1;
};
Debug.print("count: pacs.002 answers emitted and valid under the pacs.002 profile = " # Nat.toText(reports));

// ─── replay ────────────────────────────────────────────────────────────────────
let fresh = Core.replay(installer, BankMemLog.blocks(bchain));
assert (Core.fingerprint(fresh) == Core.fingerprint(bs));
let freshJ = JCore.replay(bankP, JMemLog.blocks(jchain));
assert (JCore.fingerprint(freshJ) == JCore.fingerprint(js));
Debug.print("count: bank blocks replayed to an identical fingerprint = " # Nat.toText(Core.height(bs)));
Debug.print("PAYMENTS TEST GREEN");
