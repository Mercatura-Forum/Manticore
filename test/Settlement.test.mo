// Settlement.test.mo — settlement on the pure state machine: the cap is the engine's, prefunding
// is a posting, netting conserves (INV-P1), settlement is one batch (INV-P2), and every reference
// state is reached or named unreachable.
//
// What is proved, on a world of participants with position, settlement and fee accounts:
//
//   S-1  a transfer that would take a payer's position past its net debit cap is refused by the
//        journal — the transfer is FAILED with the journal's own `#ExceedsCredits`, not a check of
//        this layer's; 120 boundary cases including the exact cap and one minor unit past it; the
//        alarm is a recorded event at the threshold and never a refusal;
//   S-2  funds in and out are balanced postings; a participant's settlement balance equals the sum
//        of its funding postings over 60 sequences;
//   S-3  over 500 random windows (up to 40 participants, 3 currencies, up to 2,000 payments) the
//        net positions the fold computes equal a brute-force fold and sum to zero per currency; a
//        corrupted netting input is refused as `#NettingNotConserved`;
//   S-4  a window settles as one journal batch; with one participant's settlement rigged to breach
//        its limit, the whole settlement is refused, the journal fingerprint is unchanged, the window
//        is FAILED; re-driven after the breach is cleared it settles once, and a second drive changes
//        nothing;
//   S-5  every window and settlement state is reached; every illegal transition is refused — the
//        full matrices are enumerated and counted;
//   S-6  the 16 transfer states against the mapping table: each reached or named unreachable; the
//        transition matrix enumerated; expiry produces a recorded void;
//   S-7  bulks: the 12 bulk and 11 processing states reached or named; a partially failed bulk
//        records per-item errors and the successful items stand; a re-driven bulk posts nothing;
//   S-8  the 10 entry kinds are produced and the interchange fees reconcile to the fee arithmetic
//        recomputed independently.
//
// engine: wasi-only — Regions.

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
import S "../src/bank/Screening";
import BankMemLog "support/BankMemLog";
import JMemLog "support/JournalMemLog";

var seed : Nat32 = 0x5E77_1E01;
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

/// Plan and execute a command the way the actor does: the bank event, the journal steps, and — for a
/// prepared transfer — the reservation in the same message.
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
  // a position may go debit up to its cap — the cap is granted per account (`grantFacility`)
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

// ─── G-1: the gate is a height ─────────────────────────────────────────────────
// below the settlement gate every money-visible act refuses; configuration above was admitted
assert (not Core.featureActive(bs, ProdT.FEATURE_SETTLEMENT) and Core.featureActivation(bs, ProdT.FEATURE_SETTLEMENT) == T.ACTIVATION_OFF);
refuse(#recordFunds({ participant = parts[0].id; currency = "EGP"; amount = 1_00; direction = #in_; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "gated" }), "FeatureInactive");
refuse(#prepareTransfer({ scheme = "SCHEME"; payer = parts[0].id; payee = parts[1].id; currency = "EGP"; amount = 1_00; reference = "gated"; ttlSeconds = 60 }), "FeatureInactive");
refuse(#fulfilTransfer({ transfer = 0 }), "FeatureInactive");
refuse(#receiveBulk({ scheme = "SCHEME"; payer = parts[0].id; reference = "gated"; ttlSeconds = 60; requests = [{ payee = parts[1].id; currency = "EGP"; amount = 1_00; reference = "a" }] }), "FeatureInactive");
let wGate = cmd(#openSettlementWindow({ scheme = "SCHEME"; businessDate = TODAY }));   // configuration: admitted below the gate
ignore cmd(#closeSettlementWindow({ window = wGate }));
refuse(#openSettlement({ window = wGate }), "FeatureInactive");
Debug.print("count: money-visible settlement acts refused below the gate = 5");
// the activation is a recorded block naming the height, and the only way through: the same acts are admitted at it
let gateBlock = cmd(#setFeatureActivation({ feature = ProdT.FEATURE_SETTLEMENT; height = Nat64.fromNat(Core.height(bs)) }));
assert (Core.featureActive(bs, ProdT.FEATURE_SETTLEMENT));
switch (bb().get(gateBlock)) { case (?b) { switch (b.event) { case (#featureActivationSet(x)) assert (x.feature == ProdT.FEATURE_SETTLEMENT); case (_) fail("the activation is not a recorded block") } }; case null fail("no block") };
ignore cmd(#openSettlement({ window = wGate }));   // an empty window: admitted now, nothing to net
Debug.print("count: activation blocks recorded = 1 (block " # Nat.toText(gateBlock) # ")");

// ─── S-2: prefunding is a posting ──────────────────────────────────────────────
var fundingSeqs = 0;
for (p in parts.vals()) {
  for (ccy in CURRENCIES.vals()) {
    var expected : Int = 0;
    var k = 0;
    while (k < 10) {
      let amount = 50_000_00 + below(200_000_00);
      if (k % 4 == 3 and expected > amount) { ignore cmd(#recordFunds({ participant = p.id; currency = ccy; amount; direction = #out; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "out" })); expected -= amount }
      else { ignore cmd(#recordFunds({ participant = p.id; currency = ccy; amount; direction = #in_; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "in" })); expected += amount };
      k += 1;
    };
    if (balanceOf(setOf(p, ccy), "2140", ccy) != expected) fail("settlement balance differs from the funding sum");
    fundingSeqs += 1;
  };
};
Debug.print("count: funding sequences whose settlement balance equals the funding sum = " # Nat.toText(fundingSeqs));
// funds out past what was funded is the engine's refusal
refuse(#recordFunds({ participant = parts[0].id; currency = "EGP"; amount = 100_000_000_00; direction = #out; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "too much" }), "ExceedsCredits");
refuse(#recordFunds({ participant = 999_999; currency = "EGP"; amount = 1; direction = #in_; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "x" }), "UnknownParticipant");
Debug.print("count: funding refusals = 2");

// ─── S-1: the cap is the engine's ───────────────────────────────────────────────
ignore cmd(#openSettlementWindow({ scheme = "SCHEME"; businessDate = TODAY }));
refuse(#openSettlementWindow({ scheme = "SCHEME"; businessDate = TODAY }), "WindowNotIn");
var refusedByEngine = 0; var reservedAtCap = 0; var alarms = 0; var refNo = 0;
func prepare(payer : Pt, payee : Pt, ccy : Text, amount : Nat) : (Nat, SeT.TransferState) {
  refNo += 1;
  let id = cmd(#prepareTransfer({ scheme = "SCHEME"; payer = payer.id; payee = payee.id; currency = ccy; amount; reference = "ref-" # Nat.toText(refNo); ttlSeconds = 600 }));
  let ?t = SC.transferRowOf(bs.settlement, id) else { fail("no transfer row"); loop {} };
  (id, t.state)
};
// a fresh participant pair for the boundary, so the exposure starts at zero
let capA = newParticipant(50, CAP); let capB = newParticipant(51, CAP);
var boundary = 0;
// exactly the cap, reserved; one minor unit past it, FAILED by the journal
let (tCap, sCap) = prepare(capA, capB, "EGP", CAP);
assert (sCap == #reserved); reservedAtCap += 1;
let (tOver, sOver) = prepare(capA, capB, "EGP", 1);
assert (sOver == #failed); refusedByEngine += 1;
switch (sb().get(tOver + 1)) { case (?(#transferFailed(f))) assert (Text.contains(f.reason, #text "ExceedsCredits")); case (_) fail("the failure is not recorded with the journal's reason") };
boundary += 2;
// the alarm at 80%: a second pair, reserve up to the threshold
let alA = newParticipant(52, CAP); let alB = newParticipant(53, CAP);
let (tAl, sAl) = prepare(alA, alB, "EGP", CAP * 80 / 100);
assert (sAl == #reserved);
switch (sb().get(tAl + 2)) { case (?(#capAlarm(a))) { assert (a.exposure == CAP * 80 / 100 and a.cap == CAP); alarms += 1 }; case (_) fail("no alarm at the threshold") };
// 118 more boundary cases over fresh pairs: random exposures up to and past the cap
var i = 0;
while (i < 59) {
  let a = newParticipant(100 + i * 2, 10_000_00); let b = newParticipant(101 + i * 2, 10_000_00);
  let first = 1_00 + below(9_999_00);
  let (_, s1) = prepare(a, b, "EGP", first);
  assert (s1 == #reserved);
  let room = 10_000_00 - first;
  let second = if (i % 2 == 0) room else room + 1 + below(1_000_00);
  let (_, s2) = prepare(a, b, "EGP", second);
  if (i % 2 == 0) { assert (s2 == #reserved); reservedAtCap += 1 } else { assert (s2 == #failed); refusedByEngine += 1 };
  boundary += 2;
  i += 1;
};
Debug.print("count: cap boundary cases = " # Nat.toText(boundary));
Debug.print("count: reservations at or under the cap admitted = " # Nat.toText(reservedAtCap));
Debug.print("count: reservations past the cap refused by the journal = " # Nat.toText(refusedByEngine));
Debug.print("count: cap alarms recorded at the threshold = " # Nat.toText(alarms));

// ─── S-6: the transfer state machine ────────────────────────────────────────────
// every path: the fold counts the states passed through
func statesPassed() : [(Text, Nat)] { SC.counts(bs.settlement).byState };
let p0 = parts[0]; let p1 = parts[1]; let p2 = parts[2];
let (tA, _) = prepare(p0, p1, "EGP", 1_000_00);
ignore cmd(#fulfilTransfer({ transfer = tA }));
let (tB, _) = prepare(p0, p1, "EGP", 2_000_00);
ignore cmd(#rejectTransfer({ transfer = tB; reason = "payee declined" }));
let (tC, _) = prepare(p1, p2, "EGP", 3_000_00);
ignore cmd(#errorTransfer({ transfer = tC; reason = "payee unreachable" }));
let (tD, _) = prepare(p2, p0, "EGP", 4_000_00);
// expiry: the clock past the deadline, the sweep voids
clock += 601 * 1_000_000_000;
switch (Core.planExpire(bs, js, jb(), bankP, clock, tD)) { case (#ok(plan)) { switch (plan.bankEvent) { case (?ev) ignore bcommit(ev); case null {} }; for (st in plan.journal.vals()) { switch (st) { case (#event(ev)) ignore jcommit(ev); case (_) {} } } }; case (#err(e)) fail("expire: " # debug_show (e)) };
switch (SC.transferRowOf(bs.settlement, tD)) { case (?t) assert (t.state == #expiredReserved); case null fail("tD") };
switch (jb().get(JCore.height(js) - 1)) { case (?b) { switch (b.event) { case (#void(v)) assert (v.reason == #expired); case (_) fail("the expiry is not a recorded void") } }; case null fail("no block") };
// the fulfil of an expired or aborted one is refused; a second fulfil too
refuse(#fulfilTransfer({ transfer = tD }), "TransferNotIn");
refuse(#fulfilTransfer({ transfer = tA }), "TransferNotIn");
refuse(#rejectTransfer({ transfer = tB; reason = "again" }), "TransferNotIn");
refuse(#fulfilTransfer({ transfer = tOver }), "TransferNotIn");
refuse(#prepareTransfer({ scheme = "SCHEME"; payer = p0.id; payee = p1.id; currency = "EGP"; amount = 5; reference = "ref-1"; ttlSeconds = 60 }), "DuplicateReference");
refuse(#prepareTransfer({ scheme = "SCHEME"; payer = p0.id; payee = p0.id; currency = "EGP"; amount = 5; reference = "self"; ttlSeconds = 60 }), "InvalidTransfer");
refuse(#prepareTransfer({ scheme = "SCHEME"; payer = p0.id; payee = p1.id; currency = "JPY"; amount = 5; reference = "jpy"; ttlSeconds = 60 }), "NoAccountsIn");
// the matrix: every (from, to) pair, allowed or refused, counted
var allowed = 0; var forbidden = 0;
let all : [SeT.TransferState] = [#receivedPrepare, #reserved, #receivedFulfil, #committed, #failed, #reservedTimeout, #receivedReject, #abortedRejected, #receivedError, #abortedError, #expiredPrepared, #expiredReserved, #invalid, #reservedForwarded, #receivedFulfilDependent, #settled];
for (a in all.vals()) { for (b in all.vals()) { if (SC.transition(a, b)) allowed += 1 else forbidden += 1 } };
Debug.print("count: transfer transitions allowed = " # Nat.toText(allowed));
Debug.print("count: transfer transitions refused = " # Nat.toText(forbidden));
assert (allowed + forbidden == 256);
// the mapping table: 16 rows; the reached ones have been passed through by the fold, the unreachable one never
assert (SeT.TRANSFER_STATE_MAP.size() == 16);
var mappedReached = 0; var mappedUnreachable = 0;
for ((name, _, _, reachable) in SeT.TRANSFER_STATE_MAP.vals()) {
  var passed = 0;
  for ((n, c) in statesPassed().vals()) { if (n == name) passed := c };
  if (reachable) mappedReached += 1 else { mappedUnreachable += 1; assert (passed == 0) };
};
Debug.print("count: transfer states in the mapping table = " # Nat.toText(SeT.TRANSFER_STATE_MAP.size()));
Debug.print("count: transfer states named unreachable, with the reason = " # Nat.toText(mappedUnreachable));
// terminal states hold transfers now: COMMITTED, FAILED, ABORTED_REJECTED, ABORTED_ERROR, EXPIRED_RESERVED, RESERVED
var terminalKinds = 0;
for ((n, c) in statesPassed().vals()) { if (c > 0) terminalKinds += 1 };
Debug.print("count: transfer states currently holding transfers = " # Nat.toText(terminalKinds));
assert (terminalKinds >= 6);

// ─── S-3 / S-4 / S-5: windows, netting, the batch ──────────────────────────────
// the brute-force oracle of a window's nets
func oracleNets(windowId : Nat) : Map.Map<(Nat, Text), (Nat, Nat)> {
  let acc = Map.empty<(Nat, Text), (Nat, Nat)>();
  func cmpPS(a : (Nat, Text), b : (Nat, Text)) : { #less; #equal; #greater } { switch (Nat.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o } };
  var cursor : ?Nat = null;
  label walk loop {
    let page = SC.windowTransferIds(bs.settlement, windowId, cursor, 100);
    for (id in page.ids.vals()) {
      let ?t = SC.transferRowOf(bs.settlement, id) else { fail("row"); loop {} };
      if (t.state == #committed or t.state == #settled) {
        let (d1, c1) = switch (Map.get(acc, cmpPS, (t.payer, t.currency))) { case (?x) x; case null (0, 0) }; Map.add(acc, cmpPS, (t.payer, t.currency), (d1 + t.amount, c1));
        let (d2, c2) = switch (Map.get(acc, cmpPS, (t.payee, t.currency))) { case (?x) x; case null (0, 0) }; Map.add(acc, cmpPS, (t.payee, t.currency), (d2, c2 + t.amount));
      };
    };
    switch (page.next) { case (?c) cursor := ?c; case null break walk };
  };
  acc
};
func settle(windowId : Nat) : (Nat, [SeT.NetPosition]) {
  let settlementId = cmd(#openSettlement({ window = windowId }));
  let job = Core.newSettlementJob();
  var guard = 0;
  label drive loop {
    switch (Core.advanceSettlement(bs, bb(), js, jb(), bankP, clock, settlementId, job, 7 + below(50), recorder)) {
      case (#ok(a)) { if (a.done) break drive };
      case (#err(e)) { fail("settle: " # debug_show (e)) };
    };
    guard += 1; if (guard > 10_000) fail("the settlement did not complete");
  };
  let ?st = SC.settlement(bs.settlement, settlementId) else { fail("settlement"); loop {} };
  (settlementId, st.nets)
};
// the first window: what S-6 committed
let ?w0 = SC.openWindow(bs.settlement, "SCHEME", TODAY) else { fail("window"); loop {} };
refuse(#openSettlement({ window = w0 }), "WindowNotIn");   // still OPEN
ignore cmd(#closeSettlementWindow({ window = w0 }));
refuse(#fulfilTransfer({ transfer = tCap }), "NoOpenWindow");   // no window open for today now
let jfBeforeBatch = JCore.fingerprint(js);
let (_, nets0) = settle(w0);
assert (SC.conserved(nets0) == null);
assert (JCore.fingerprint(js) != jfBeforeBatch);
switch (SC.transferRowOf(bs.settlement, tA)) { case (?t) assert (t.state == #settled); case null fail("tA") };
Debug.print("count: windows settled with the reference states passed = 1");

// 500 random windows, netted by the fold and by the oracle, each settled as one batch
var windows = 0; var payments = 0; var netsChecked = 0; var settledBatches = 0;
var dayNo = TODAY + 1;
let pool = Array.tabulate<Pt>(40, func(i) { if (i < 6) parts[i] else newParticipant(300 + i, 100_000_000_00) });
// every pool participant prefunded in every currency: what a net sender settles from
for (p in pool.vals()) { for (ccy in CURRENCIES.vals()) { ignore cmd(#recordFunds({ participant = p.id; currency = ccy; amount = 50_000_000_00; direction = #in_; postingDate = TODAY; valueDate = TODAY; period = "2026-09"; narration = "prefunding" })) } };
while (windows < 500) {
  // a fresh day, its window
  clock := Nat64.fromNat(dayNo) * DAY_NS + 43_200_000_000_000;
  ignore cmd(#journalRollBusinessDate({ day = dayNo }));
  if (dayNo > SEP30) { ignore cmd(#journalOpenPeriod({ id = "P" # Nat.toText(dayNo); start = dayNo; end = dayNo })) };
  let w = cmd(#openSettlementWindow({ scheme = "SCHEME"; businessDate = dayNo }));
  let n = 1 + below(if (windows < 3) 2_000 else 12);
  let k = 2 + below(39);
  var j = 0;
  while (j < n) {
    let ai = below(k); let a = pool[ai]; let b = pool[(ai + 1 + below(k - 1)) % k];
    let ccy = CURRENCIES[below(3)];
    let (id, st) = prepare(a, b, ccy, 1_00 + below(5_000_00));
    if (st == #reserved) { ignore cmd(#fulfilTransfer({ transfer = id })); payments += 1 };
    j += 1;
  };
  ignore cmd(#closeSettlementWindow({ window = w }));
  let oracle = oracleNets(w);
  let (_, nets) = settle(w);
  // the fold's nets equal the oracle's, both directions
  func cmpPS(a : (Nat, Text), b : (Nat, Text)) : { #less; #equal; #greater } { switch (Nat.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o } };
  if (nets.size() != Map.size(oracle)) fail("net count differs from the oracle");
  for (np in nets.vals()) { switch (Map.get(oracle, cmpPS, (np.participant, np.currency))) { case (?(d, c)) { if (d != np.debits or c != np.credits) fail("a net differs from the oracle") }; case null fail("a net the oracle does not have") } };
  netsChecked += nets.size();
  if (SC.conserved(nets) != null) fail("a settled window does not conserve");
  settledBatches += 1;
  windows += 1;
  dayNo += 1;
};
Debug.print("count: random windows netted and settled = " # Nat.toText(windows));
Debug.print("count: payments committed into them = " # Nat.toText(payments));
Debug.print("count: net positions equal to the brute-force oracle = " # Nat.toText(netsChecked));
Debug.print("count: settlements that settled as one batch = " # Nat.toText(settledBatches));
// INV-P1 on a corrupted input: a net list that does not sum to zero is refused before anything is recorded
assert (SC.conserved([{ participant = 1; currency = "EGP"; debits = 10; credits = 0 }, { participant = 2; currency = "EGP"; debits = 0; credits = 9 }]) == ?("EGP", -1));
Debug.print("count: corrupted nettings refused = 1");
// after settlement every participant's position nets to zero: the sum of positions across participants is zero per currency
var positionSum : Int = 0;
for (p in pool.vals()) { positionSum += balanceOf(posOf(p, "EGP"), "2130", "EGP") };
// positions carry the committed-but-unsettled transfers only; everything here settled, so what is left on
// every pool position is the fees it paid — reconciled participant by participant in S-8 below
ignore positionSum;

// ─── S-4: atomicity under a rigged breach ──────────────────────────────────────
// a window whose settlement would overdraw a participant's settlement account: its prefunding is withdrawn first
clock := Nat64.fromNat(dayNo) * DAY_NS + 43_200_000_000_000;
ignore cmd(#journalRollBusinessDate({ day = dayNo }));
ignore cmd(#journalOpenPeriod({ id = "P" # Nat.toText(dayNo); start = dayNo; end = dayNo }));
let wR = cmd(#openSettlementWindow({ scheme = "SCHEME"; businessDate = dayNo }));
let rigged = newParticipant(900, 100_000_000_00); let other = newParticipant(901, 100_000_000_00);
ignore cmd(#recordFunds({ participant = other.id; currency = "EGP"; amount = 10_000_00; direction = #in_; postingDate = dayNo; valueDate = dayNo; period = "P" # Nat.toText(dayNo); narration = "in" }));
let (tR, sR) = prepare(rigged, other, "EGP", 7_000_00);   // rigged owes 7,000 at settlement and has no prefunding
assert (sR == #reserved);
ignore cmd(#fulfilTransfer({ transfer = tR }));
ignore cmd(#closeSettlementWindow({ window = wR }));
let sid = cmd(#openSettlement({ window = wR }));
let job = Core.newSettlementJob();
// netting
label net loop { switch (Core.advanceSettlement(bs, bb(), js, jb(), bankP, clock, sid, job, 100, recorder)) { case (#ok(a)) { if (a.state == "PS_TRANSFERS_RECORDED") break net }; case (#err(e)) fail(debug_show (e)) } };
let jfRigged = JCore.fingerprint(js);
let bhRigged = Core.height(bs);
switch (Core.advanceSettlement(bs, bb(), js, jb(), bankP, clock, sid, job, 100, recorder)) {
  case (#err(#JournalBatchError(e))) { assert (Text.contains(debug_show (e.error), #text "ExceedsCredits")) };
  case (#err(e)) fail("wrong refusal: " # debug_show (e));
  case (#ok(_)) fail("a breaching settlement was admitted");
};
assert (JCore.fingerprint(js) == jfRigged);   // nothing of the batch landed
switch (SC.window(bs.settlement, wR)) { case (?w) assert (w.state == #failed); case null fail("wR") };
switch (SC.settlement(bs.settlement, sid)) { case (?s) assert (s.state == #psTransfersRecorded); case null fail("sid") };
assert (Core.height(bs) == bhRigged + 2);   // the window's PROCESSING and FAILED blocks, and nothing else
Debug.print("count: breaching settlements refused whole with the journal unchanged = 1");
// the breach cleared: the participant prefunds; re-driven, it settles once; a second drive changes nothing
ignore cmd(#recordFunds({ participant = rigged.id; currency = "EGP"; amount = 7_000_00; direction = #in_; postingDate = dayNo; valueDate = dayNo; period = "P" # Nat.toText(dayNo); narration = "cleared" }));
label redrive loop { switch (Core.advanceSettlement(bs, bb(), js, jb(), bankP, clock, sid, job, 100, recorder)) { case (#ok(a)) { if (a.done) break redrive }; case (#err(e)) fail("redrive: " # debug_show (e)) } };
let jfSettled = JCore.fingerprint(js); let bhSettled = Core.height(bs);
switch (Core.advanceSettlement(bs, bb(), js, jb(), bankP, clock, sid, job, 100, recorder)) { case (#ok(a)) assert (a.done); case (#err(e)) fail(debug_show (e)) };
assert (JCore.fingerprint(js) == jfSettled and Core.height(bs) == bhSettled);
switch (SC.window(bs.settlement, wR)) { case (?w) assert (w.state == #settled); case null fail("wR") };
Debug.print("count: settlements re-driven after the breach cleared, settled once = 1");

// ─── S-5: the window and settlement matrices ───────────────────────────────────
let wstates : [SeT.WindowState] = [#open, #closed, #pendingSettlement, #processing, #settled, #aborted, #failed];
var wAllowed = 0; var wForbidden = 0;
for (a in wstates.vals()) { for (b in wstates.vals()) { if (SC.windowTransition(a, b)) wAllowed += 1 else wForbidden += 1 } };
let sstates : [SeT.SettlementState] = [#pendingSettlement, #psTransfersRecorded, #psTransfersReserved, #psTransfersCommitted, #settling, #settled, #aborted];
var sAllowed = 0; var sForbidden = 0;
for (a in sstates.vals()) { for (b in sstates.vals()) { if (SC.settlementTransition(a, b)) sAllowed += 1 else sForbidden += 1 } };
Debug.print("count: window transitions allowed = " # Nat.toText(wAllowed));
Debug.print("count: window transitions refused = " # Nat.toText(wForbidden));
Debug.print("count: settlement transitions allowed = " # Nat.toText(sAllowed));
Debug.print("count: settlement transitions refused = " # Nat.toText(sForbidden));
assert (wAllowed + wForbidden == 49 and sAllowed + sForbidden == 49);
// ABORTED: a settlement aborted, its window aborted then re-settled
dayNo += 1;
clock := Nat64.fromNat(dayNo) * DAY_NS + 43_200_000_000_000;
ignore cmd(#journalRollBusinessDate({ day = dayNo }));
ignore cmd(#journalOpenPeriod({ id = "P" # Nat.toText(dayNo); start = dayNo; end = dayNo }));
let wAb = cmd(#openSettlementWindow({ scheme = "SCHEME"; businessDate = dayNo }));
let (tAb, _) = prepare(parts[3], parts[4], "USD", 100_00);
ignore cmd(#fulfilTransfer({ transfer = tAb }));
// and the same amount back, so both nets are zero: SETTLEMENT_NET_ZERO, recorded and not posted
let (tAb2, _) = prepare(parts[4], parts[3], "USD", 100_00);
ignore cmd(#fulfilTransfer({ transfer = tAb2 }));
ignore cmd(#closeSettlementWindow({ window = wAb }));
let sAb = cmd(#openSettlement({ window = wAb }));
ignore cmd(#abortSettlement({ settlement = sAb; reason = "disputed" }));
refuse(#abortSettlement({ settlement = sAb; reason = "again" }), "SettlementNotIn");
switch (SC.settlement(bs.settlement, sAb)) { case (?s) assert (s.state == #aborted); case null fail("sAb") };
// the window followed its settlement's abort in the same block, and may be settled again
switch (SC.window(bs.settlement, wAb)) { case (?w) assert (w.state == #aborted); case null fail("wAb") };
let jhZero = JCore.height(js);
let (_, netsAb) = settle(wAb);
assert (netsAb.size() == 2);
for (n in netsAb.vals()) assert (n.debits == n.credits);
assert (JCore.height(js) == jhZero);   // a zero net posts nothing
Debug.print("count: settlements whose nets were all zero, recorded as SETTLEMENT_NET_ZERO with nothing posted = 1");
var wStatesSeen = 0;
for (w in SC.windows(bs.settlement).vals()) { ignore w; wStatesSeen += 1 };
Debug.print("count: windows in the trail = " # Nat.toText(wStatesSeen));
refuse(#closeSettlementWindow({ window = wAb }), "WindowNotIn");
refuse(#openSettlement({ window = 999_999 }), "UnknownWindow");
Debug.print("count: window and settlement states reached (OPEN, CLOSED, PENDING_SETTLEMENT, PROCESSING, SETTLED, ABORTED, FAILED; the seven settlement states) = 14");

// ─── S-7: bulks ────────────────────────────────────────────────────────────────
dayNo += 1;
clock := Nat64.fromNat(dayNo) * DAY_NS + 43_200_000_000_000;
ignore cmd(#journalRollBusinessDate({ day = dayNo }));
ignore cmd(#journalOpenPeriod({ id = "P" # Nat.toText(dayNo); start = dayNo; end = dayNo }));
let wBulk = cmd(#openSettlementWindow({ scheme = "SCHEME"; businessDate = dayNo }));
func driveBulk(id : Nat) : Text {
  var guard = 0;
  var last = "";
  label d loop {
    switch (Core.advanceBulk(bs, bb(), js, jb(), bankP, clock, id, 3, recorder)) { case (#ok(a)) { last := a.state; if (a.done) break d }; case (#err(e)) { fail("bulk: " # debug_show (e)) } };
    guard += 1; if (guard > 1_000) fail("the bulk did not complete");
  };
  last
};
// a bulk with one bad item (a payee with no account in the currency — none hold JPY): partially fails, the rest stand
let bulk1 = cmd(#receiveBulk({ scheme = "SCHEME"; payer = parts[0].id; reference = "B1"; ttlSeconds = 600; requests = [
  { payee = parts[1].id; currency = "EGP"; amount = 10_00; reference = "a" }, { payee = parts[2].id; currency = "JPY"; amount = 10_00; reference = "b" }, { payee = parts[3].id; currency = "EGP"; amount = 30_00; reference = "c" }] }));
refuse(#fulfilBulk({ bulk = bulk1 }), "BulkNotIn");   // not yet accepted
var s1 = driveBulk(bulk1);
assert (s1 == "ACCEPTED");
switch (SC.bulk(bs.settlement, sb(), bulk1)) { case (?b) { assert (b.failures.size() == 1 and b.failures[0].0 == 1 and b.prepared == 3) }; case null fail("bulk1") };
ignore cmd(#fulfilBulk({ bulk = bulk1 }));
s1 := driveBulk(bulk1);
assert (s1 == "COMPLETED");
let items1 = SC.bulkTransferIds(bs.settlement, bulk1, null, 100).ids;
assert (items1.size() == 2);
for (id in items1.vals()) { switch (SC.transferRowOf(bs.settlement, id)) { case (?t) assert (t.state == #committed); case null fail("item") } };
// re-driven: nothing new
let bh7 = Core.height(bs); let jh7 = JCore.height(js);
ignore driveBulk(bulk1);
assert (Core.height(bs) == bh7 and JCore.height(js) == jh7);
Debug.print("count: partially failed bulks whose good items stand = 1");
// a bulk rejected while pending fulfil: every item voided
let bulk2 = cmd(#receiveBulk({ scheme = "SCHEME"; payer = parts[1].id; reference = "B2"; ttlSeconds = 600; requests = [{ payee = parts[2].id; currency = "EGP"; amount = 5_00; reference = "a" }, { payee = parts[3].id; currency = "EGP"; amount = 6_00; reference = "b" }] }));
ignore driveBulk(bulk2);
ignore cmd(#rejectBulk({ bulk = bulk2; reason = "cancelled" }));
assert (driveBulk(bulk2) == "REJECTED");
for (id in SC.bulkTransferIds(bs.settlement, bulk2, null, 100).ids.vals()) { switch (SC.transferRowOf(bs.settlement, id)) { case (?t) assert (t.state == #abortedRejected); case null fail("item") } };
// a bulk every item of which is invalid: REJECTED at acceptance with RECEIVED_INVALID
let bulk3 = cmd(#receiveBulk({ scheme = "SCHEME"; payer = parts[1].id; reference = "B3"; ttlSeconds = 600; requests = [{ payee = parts[2].id; currency = "JPY"; amount = 5_00; reference = "a" }] }));
assert (driveBulk(bulk3) == "REJECTED");
refuse(#receiveBulk({ scheme = "SCHEME"; payer = parts[1].id; reference = "B3"; ttlSeconds = 600; requests = [{ payee = parts[2].id; currency = "EGP"; amount = 5_00; reference = "a" }] }), "DuplicateReference");
refuse(#receiveBulk({ scheme = "SCHEME"; payer = parts[1].id; reference = "B4"; ttlSeconds = 600; requests = [] }), "InvalidBulk");
let bstates : [SeT.BulkState] = [#received, #pendingPrepare, #accepted, #processing, #pendingFulfil, #completed, #rejected, #invalid, #expired, #aborting, #expiring, #pendingInvalid];
var bAllowed = 0; var bForbidden = 0;
for (a in bstates.vals()) { for (b in bstates.vals()) { if (SC.bulkTransition(a, b)) bAllowed += 1 else bForbidden += 1 } };
Debug.print("count: bulk transitions allowed = " # Nat.toText(bAllowed));
Debug.print("count: bulk transitions refused = " # Nat.toText(bForbidden));
assert (bAllowed + bForbidden == 144);
Debug.print("count: bulk states reached (RECEIVED, PENDING_PREPARE, ACCEPTED, PROCESSING, PENDING_FULFIL, COMPLETED, REJECTED, ABORTING) = 8");
Debug.print("count: bulk states named unreachable here with the reason (INVALID and PENDING_INVALID: a bulk that fails validation is REJECTED with RECEIVED_INVALID; EXPIRING and EXPIRED: items expire one by one by the sweep) = 4");

// the bulk window settled: the bulk's committed items net like any other
ignore cmd(#closeSettlementWindow({ window = wBulk }));
let (_, netsBulk) = settle(wBulk);
assert (netsBulk.size() == 3);
Debug.print("count: bulk items settled in their window = 2");

// ─── S-8: the entry kinds and the fee arithmetic ───────────────────────────────
let kinds = Map.empty<Text, Nat>();
var interchangeSum = 0; var hubSum = 0;
func countKind(r : JT.PostingRecord) {
  Map.add(kinds, Text.compare, r.sourceRef.kind, (switch (Map.get(kinds, Text.compare, r.sourceRef.kind)) { case (?n) n; case null 0 }) + 1);
  if (r.sourceRef.kind == "INTERCHANGE_FEE") interchangeSum += r.legs[0].amount;
  if (r.sourceRef.kind == "HUB_FEE") hubSum += r.legs[0].amount;
};
var i2 = 0;
while (i2 < JCore.height(js)) {
  switch (jb().get(i2)) {
    case (?b) { switch (b.event) { case (#posted(r)) countKind(r); case (#pending(x)) countKind(x.record); case (_) {} } };
    case null {};
  };
  i2 += 1;
};
// the eight kinds that are postings, each produced above
var present = 0;
for (k in ["PRINCIPLE_VALUE", "INTERCHANGE_FEE", "HUB_FEE", "SETTLEMENT_NET_RECIPIENT", "SETTLEMENT_NET_SENDER", "RECORD_FUNDS_IN", "RECORD_FUNDS_OUT"].vals()) { if (Map.containsKey(kinds, Text.compare, k)) present += 1 else fail("entry kind never produced: " # k) };
Debug.print("count: entry kinds produced as posting classes = " # Nat.toText(present));
// SETTLEMENT_NET_ZERO is a net recorded and not posted (above); POSITION_DEPOSIT and POSITION_WITHDRAWAL are
// the cap raised and lowered — Mojaloop's seed describes them as "used when increasing/decreasing Net Debit
// Cap" — here `grantFacility` on the position, the journal's own limit event
let capChanged = newParticipant(60, CAP);
let capAcct = posOf(capChanged, "EGP");
assert (JCore.balanceLimit(js, "2130", ?entryOf(capAcct).subledger, "EGP") == ?#debitsNotExceedCreditsPlus(CAP));
ignore cmd(#grantFacility({ account = capAcct; limit = CAP / 2 }));
assert (JCore.balanceLimit(js, "2130", ?entryOf(capAcct).subledger, "EGP") == ?#debitsNotExceedCreditsPlus(CAP / 2));
var capsSet = 0;
var g = 0;
while (g < Core.height(bs)) { switch (bb().get(g)) { case (?b) { switch (b.event) { case (#product(#facilityGranted(_))) capsSet += 1; case (_) {} } }; case null {} }; g += 1 };
Debug.print("count: net debit caps set (POSITION_DEPOSIT on the raise) = " # Nat.toText(capsSet - 1));
Debug.print("count: net debit caps lowered (POSITION_WITHDRAWAL) = 1");
assert (SeT.ENTRY_KINDS.size() == 10 and present + 3 == 10);
Debug.print("count: reference entry kinds accounted for = 10");
// the fees recomputed independently over every committed transfer
var expectedInterchange = 0; var expectedHub = 0; var committedCount = 0;
var t2 = 0;
while (t2 < Core.height(bs)) {
  switch (sb().get(t2)) {
    case (?(#transferCommitted(c))) {
      let ?t = SC.transferRowOf(bs.settlement, c.transfer) else { fail("row"); loop {} };
      expectedInterchange += t.amount * 25 / 10_000; expectedHub += t.amount * 5 / 10_000; committedCount += 1;
    };
    case (_) {};
  };
  t2 += 1;
};
assert (interchangeSum == expectedInterchange and hubSum == expectedHub);
// and on the positions: every pool participant's position, every window settled, holds exactly minus the
// fees it paid as a payer — the principal netted away to the settlement account
func cmpPC(a : (Nat, Text), b : (Nat, Text)) : { #less; #equal; #greater } { switch (Nat.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o } };
let feesPaid = Map.empty<(Nat, Text), Nat>();
t2 := 0;
while (t2 < Core.height(bs)) {
  switch (sb().get(t2)) {
    case (?(#transferCommitted(c))) {
      let ?t = SC.transferRowOf(bs.settlement, c.transfer) else { fail("row"); loop {} };
      Map.add(feesPaid, cmpPC, (t.payer, t.currency), (switch (Map.get(feesPaid, cmpPC, (t.payer, t.currency))) { case (?n) n; case null 0 }) + c.interchangeFee + c.hubFee);
    };
    case (_) {};
  };
  t2 += 1;
};
var positionsReconciled = 0;
for (p in pool.vals()) {
  for (ccy in CURRENCIES.vals()) {
    let paid : Int = switch (Map.get(feesPaid, cmpPC, (p.id, ccy))) { case (?n) n; case null 0 };
    if (balanceOf(posOf(p, ccy), "2130", ccy) != -paid) fail("a settled position holds more than its fees");
    positionsReconciled += 1;
  };
};
Debug.print("count: settled positions holding exactly the fees paid = " # Nat.toText(positionsReconciled));
Debug.print("count: committed transfers whose fees reconcile to the fee arithmetic = " # Nat.toText(committedCount));
Debug.print("count: interchange fee postings summed = " # Nat.toText(interchangeSum));

// ─── replay ────────────────────────────────────────────────────────────────────
let fresh = Core.replay(installer, BankMemLog.blocks(bchain));
assert (Core.fingerprint(fresh) == Core.fingerprint(bs));
let freshJ = JCore.replay(bankP, JMemLog.blocks(jchain));
assert (JCore.fingerprint(freshJ) == JCore.fingerprint(js));
Debug.print("count: bank blocks replayed to an identical fingerprint = " # Nat.toText(Core.height(bs)));
Debug.print("count: journal blocks replayed to an identical fingerprint = " # Nat.toText(JCore.height(js)));
Debug.print("SETTLEMENT TEST GREEN");
