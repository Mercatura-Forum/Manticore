// Teller.test.mo; the branch's counted cash, sessions, cash network, cheques and drafts as the bank records them
// (branch and teller), on the pure core over a real stable-memory arena.
//
// What is proved:
//
//   * the policy's and the denominations' gates; the value of a denomination set;
//   * sessions: one open per till, the count against the book, the close with its difference (balanced, short, over),
//     the resolution only of a closed session with a difference and only once;
//   * counted cash: the tender less the change is the amount, the change and a payment must be in the drawer, the
//     drawer's position follows every act, a load moves the vault's position to the drawer and back;
//   * the cash network: a dispatch leaves the vault and a receipt reaches the other, the movement in transit between,
//     a receipt whose count is not the movement refused, a second receipt refused; the central bank lodgement and
//     drawing;
//   * cheques: a book's serials issued once (overlap refused), a stopped cheque returned at presentation, a stale and a
//     post-dated one likewise, a fresh one held, a held one cleared or returned and not twice;
//   * drafts: issued once per serial, paid or cancelled once;
//   * the fingerprint deterministic and changing.
//
// engine: wasi-only; Regions.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Principal "mo:core/Principal";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";
import TT "../src/bank/TellerTypes";
import Core "../src/bank/TellerCore";

func fail(what : Text) { Debug.print("FAIL: " # what); assert false };
func fp(s : Core.State) : Blob { let w = C.Writer(); Core.fingerprintInto(w, s); w.toBlob() };
func h(t : Text) : Blob { Sha256.fromBlob(#sha256, Text.encodeUtf8(t)) };

let arena = RI.newArena();
let s = Core.newState(arena);
var block = 700;
func next() : Nat { block += 1; block };
func apply(ev : TT.TellerEvent) : Nat { let b = next(); Core.apply(s, b, ev); b };
func ok(r : Core.Planned) : TT.TellerEvent { switch (r) { case (#ok(ev)) ev; case (#err(e)) { fail("refused: " # debug_show (e)); loop {} } } };
func act(r : Core.Planned) : Nat { apply(ok(r)) };

let teller = Principal.fromBlob("\7A\01");
let day0 = 20_726;
let policy : TT.Policy = { overShort = "5300"; cashInTransit = "1002"; centralBank = "1010"; draftsPayable = "2300"; clearing = "2310"; staleDays = 180; clearingWindowDays = 3 };
let d1 : TT.DenominationSet = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] };
if (TT.value(d1) != 2_230_00) fail("value " # Nat.toText(TT.value(d1)));

// ─── gates ────────────────────────────────────────────────────────────────────
switch (Core.planPolicy({ policy with staleDays = 0 })) { case (#err(#InvalidPolicy(_))) {}; case (_) fail("a zero stale period") };
switch (Core.planPolicy({ policy with clearing = "" })) { case (#err(#InvalidPolicy(_))) {}; case (_) fail("a policy without a clearing account") };
if (Core.validDenominations({ notes = [(0, 1)]; coins = [] }) == null) fail("a zero face accepted");
if (Core.validDenominations({ notes = [(100_00, 1), (100_00, 2)]; coins = [] }) == null) fail("a face twice accepted");
ignore act(Core.planPolicy(policy));
Debug.print("count: policy and denomination gates = 4");

// ─── the vault, the till, the session ─────────────────────────────────────────
let vault : TT.DenominationSet = { notes = [(200_00, 100), (100_00, 100), (50_00, 100)]; coins = [(1_00, 500), (50, 200)] };
ignore act(Core.planCentralBankToVault("TILL", "BR01", "EGP", TT.value(vault), vault, day0));
if (Core.vaultCount(s, "BR01", "EGP", 200_00) != 100 or Core.positionValue(Core.vaultDenominations(s, "BR01", "EGP")) != TT.value(vault)) fail("vault after lodgement");
switch (Core.planVaultToTill(s, "T1", "BR01", "EGP", 2_230_00, d1, day0)) { case (#ok(_)) {}; case (r) fail("load " # debug_show (r)) };
switch (Core.planVaultToTill(s, "T1", "BR01", "EGP", 2_230_01, d1, day0)) { case (#err(#CountMismatch(_))) {}; case (_) fail("a load whose count is not the amount") };
switch (Core.planVaultToTill(s, "T1", "BR01", "EGP", 40_000_00, { notes = [(200_00, 200)]; coins = [] }, day0)) { case (#err(#InvalidDenominations(_))) {}; case (_) fail("more notes than the vault holds") };
ignore act(Core.planVaultToTill(s, "T1", "BR01", "EGP", 2_230_00, d1, day0));
if (Core.tillCount(s, "T1", 200_00) != 10 or Core.vaultCount(s, "BR01", "EGP", 200_00) != 90) fail("positions after the load");
if (Core.positionValue(Core.tillDenominations(s, "T1")) != 2_230_00) fail("till value");
// no act at the drawer before a session
switch (Core.planCashTaken(s, "T1", 44, 100_00, { notes = [(100_00, 1)]; coins = [] }, TT.empty(), day0)) { case (#err(#NoSession(_))) {}; case (_) fail("a cash act before the session") };
let sess = act(Core.planOpenSession(s, "T1", teller, d1, 2_230_00, day0));
switch (Core.planOpenSession(s, "T1", teller, d1, 2_230_00, day0)) { case (#err(#SessionOpen(_))) {}; case (_) fail("a second session") };
switch (Core.sessionView(s, sess)) { case (?v) { if (v.openingCounted != 2_230_00 or v.closedBlock != null) fail("session view") }; case null fail("no session") };
// a deposit: tender 220.00 for a 215.50 deposit, change 4.50 from the drawer's coins
ignore act(Core.planCashTaken(s, "T1", 44, 215_50, { notes = [(200_00, 1), (20_00, 1)]; coins = [] }, { notes = []; coins = [(1_00, 4), (50, 1)] }, day0));
if (Core.tillCount(s, "T1", 200_00) != 11 or Core.tillCount(s, "T1", 20_00) != 1 or Core.tillCount(s, "T1", 1_00) != 21 or Core.tillCount(s, "T1", 50) != 9) fail("position after a deposit");
switch (Core.planCashTaken(s, "T1", 44, 100_00, { notes = [(100_00, 1)]; coins = [] }, { notes = [(5_00, 1)]; coins = [] }, day0)) { case (#err(#CountMismatch(_))) {}; case (_) fail("tender less change not the amount") };
switch (Core.planCashTaken(s, "T1", 44, 95_00, { notes = [(100_00, 1)]; coins = [] }, { notes = [(5_00, 1)]; coins = [] }, day0)) { case (#err(#InvalidDenominations(_))) {}; case (_) fail("change the drawer does not hold") };
// a withdrawal in notes the drawer holds, and one it does not
ignore act(Core.planCashPaid(s, "T1", 44, 450_00, { notes = [(200_00, 2), (50_00, 1)]; coins = [] }, day0));
if (Core.tillCount(s, "T1", 200_00) != 9 or Core.tillCount(s, "T1", 50_00) != 3) fail("position after a payment");
switch (Core.planCashPaid(s, "T1", 44, 100_00, { notes = [(100_00, 1)]; coins = [] }, day0)) { case (#err(#InvalidDenominations(_))) {}; case (_) fail("a note the drawer does not hold paid") };
switch (Core.planCashPaid(s, "T1", 44, 100_00, { notes = [(50_00, 1)]; coins = [] }, day0)) { case (#err(#CountMismatch(_))) {}; case (_) fail("a payment whose count is not the amount") };
Debug.print("count: counted cash acts and their refusals at the drawer = 10");
// the close: the book says 2,230.00 + 215.50 − 450.00 = 1,995.50; the count matches (balanced), then a short and an over on other tills
let closing = { notes = [(200_00, 9), (50_00, 3), (20_00, 1)]; coins = [(1_00, 21), (50, 9)] };
if (TT.value(closing) != 1_995_50) fail("closing value " # Nat.toText(TT.value(closing)));
let closed = ok(Core.planCloseSession(s, "T1", closing, 1_995_50, day0));
switch (closed) { case (#sessionClosed(x)) { if (x.difference != #balanced or x.session != sess) fail("balanced close") }; case (_) fail("not a close") };
ignore apply(closed);
if (Core.openSessionOf(s, "T1") != null) fail("session still open");
switch (Core.planResolve(s, sess, "5300", "nothing", day0)) { case (#err(#DifferenceNotOpen(_))) {}; case (_) fail("resolving a balanced session") };
switch (Core.planCashPaid(s, "T1", 44, 50_00, { notes = [(50_00, 1)]; coins = [] }, day0)) { case (#err(#NoSession(_))) {}; case (_) fail("a payment after the close") };
let s2 = act(Core.planOpenSession(s, "T2", teller, { notes = [(100_00, 10)]; coins = [] }, 1_000_00, day0));
let short = ok(Core.planCloseSession(s, "T2", { notes = [(100_00, 9)]; coins = [] }, 1_000_00, day0));
switch (short) { case (#sessionClosed(x)) { if (x.difference != #short(100_00)) fail("short") }; case (_) fail("not a close") };
ignore apply(short);
ignore act(Core.planResolve(s, s2, "5300", "teller statement on file", day0));
switch (Core.planResolve(s, s2, "5300", "again", day0)) { case (#err(#DifferenceNotOpen(_))) {}; case (_) fail("resolving twice") };
let s3 = act(Core.planOpenSession(s, "T3", teller, { notes = [(100_00, 10)]; coins = [] }, 1_000_00, day0));
let over = ok(Core.planCloseSession(s, "T3", { notes = [(100_00, 10), (50_00, 1)]; coins = [] }, 1_000_00, day0));
switch (over) { case (#sessionClosed(x)) { if (x.difference != #over(50_00)) fail("over") }; case (_) fail("not a close") };
ignore apply(over);
switch (Core.planResolve(s, 999_999, "5300", "x", day0)) { case (#err(#UnknownSession(_))) {}; case (_) fail("an unknown session resolved") };
switch (Core.lastSessionOf(s, "T1")) { case (?v) { if (v.id != sess) fail("last session of T1") }; case null fail("no last session") };
Debug.print("count: sessions closed balanced, short and over, resolved once = 3");
// the drawer back to the vault
ignore act(Core.planTillToVault(s, "T1", "BR01", "EGP", 1_995_50, closing, day0 + 1));
if (Core.positionValue(Core.tillDenominations(s, "T1")) != 0 or Core.vaultCount(s, "BR01", "EGP", 200_00) != 99) fail("positions after the return");

// ─── the cash network ─────────────────────────────────────────────────────────
let bag : TT.DenominationSet = { notes = [(200_00, 50), (100_00, 20)]; coins = [] };
switch (Core.planDispatch(s, "TILL", "BR01", "BR01", "EGP", TT.value(bag), bag, "ArmourCo", "SB-1", day0 + 1)) { case (#err(#InvalidRequest(_))) {}; case (_) fail("a movement to itself") };
switch (Core.planDispatch(s, "TILL", "BR01", "HQ", "EGP", TT.value(bag) + 1, bag, "ArmourCo", "SB-1", day0 + 1)) { case (#err(#CountMismatch(_))) {}; case (_) fail("a dispatch whose count is not the amount") };
let mv = act(Core.planDispatch(s, "TILL", "BR01", "HQ", "EGP", TT.value(bag), bag, "ArmourCo", "SB-1", day0 + 1));
if (Core.vaultCount(s, "BR01", "EGP", 200_00) != 49 or Core.inTransit(s).size() != 1) fail("after dispatch");
switch (Core.planReceive(s, mv, { notes = [(200_00, 50)]; coins = [] }, day0 + 2)) { case (#err(#CountMismatch(_))) {}; case (_) fail("a receipt whose count is not the movement") };
switch (Core.planReceive(s, 999_999, bag, day0 + 2)) { case (#err(#UnknownMovement(_))) {}; case (_) fail("an unknown movement received") };
switch (Core.planReceive(s, mv, bag, day0 + 2)) { case (#ok((ev, _))) ignore apply(ev); case (#err(e)) fail(debug_show (e)) };
if (Core.vaultCount(s, "HQ", "EGP", 200_00) != 50 or Core.inTransit(s).size() != 0) fail("after receipt");
switch (Core.planReceive(s, mv, bag, day0 + 2)) { case (#err(#MovementNotInTransit(_))) {}; case (_) fail("received twice") };
ignore act(Core.planVaultToCentralBank(s, "TILL", "HQ", "EGP", 10_000_00, { notes = [(200_00, 50)]; coins = [] }, day0 + 2));
if (Core.vaultCount(s, "HQ", "EGP", 200_00) != 0) fail("after lodgement to the central bank");
switch (Core.planVaultToCentralBank(s, "TILL", "HQ", "EGP", 200_00, { notes = [(200_00, 1)]; coins = [] }, day0 + 2)) { case (#err(#InvalidDenominations(_))) {}; case (_) fail("lodging notes the vault does not hold") };
Debug.print("count: cash network acts and refusals = 8");

// ─── cheques ──────────────────────────────────────────────────────────────────
switch (Core.planIssueChequebook(s, 44, 0, 10, day0)) { case (#err(#SerialRangeInvalid(_))) {}; case (_) fail("serials from zero") };
switch (Core.planIssueChequebook(s, 44, 10, 5, day0)) { case (#err(#SerialRangeInvalid(_))) {}; case (_) fail("a range ending before it starts") };
ignore act(Core.planIssueChequebook(s, 44, 1, 50, day0));
ignore act(Core.planIssueChequebook(s, 44, 51, 100, day0));
switch (Core.planIssueChequebook(s, 44, 40, 60, day0)) { case (#err(#SerialRangeInvalid(_))) {}; case (_) fail("an overlapping book") };
switch (Core.planIssueChequebook(s, 44, 101, 1_200, day0)) { case (#err(#SerialRangeInvalid(_))) {}; case (_) fail("a book too large") };
ignore act(Core.planIssueChequebook(s, 45, 1, 20, day0));   // another account's book with the same serials
if (Core.chequebookOf(s, 44, 75) != ?(51, 100) or Core.chequebookOf(s, 44, 101) != null or Core.chequebookOf(s, 45, 21) != null) fail("chequebook lookup");
switch (Core.planStop(s, 44, 500, "never issued", day0)) { case (#err(#SerialNotIssued(_))) {}; case (_) fail("stopping a serial never issued") };
ignore act(Core.planStop(s, 44, 7, "lost", day0));
switch (Core.planStop(s, 44, 7, "again", day0)) { case (#err(#ChequeNotIn(_))) {}; case (_) fail("stopping twice") };
switch (Core.presentationFate(s, 44, 7, day0 - 3, day0)) { case (#ok(?#stopped)) {}; case (r) fail("a stopped cheque " # debug_show (r)) };
switch (Core.presentationFate(s, 44, 8, day0 - 181, day0)) { case (#ok(?#stale)) {}; case (r) fail("a stale cheque " # debug_show (r)) };
switch (Core.presentationFate(s, 44, 8, day0 - 180, day0)) { case (#ok(null)) {}; case (r) fail("a cheque at the stale bound " # debug_show (r)) };
switch (Core.presentationFate(s, 44, 9, day0 + 1, day0)) { case (#ok(?#postDated)) {}; case (r) fail("a post-dated cheque " # debug_show (r)) };
switch (Core.presentationFate(s, 44, 500, day0, day0)) { case (#err(#SerialNotIssued(_))) {}; case (_) fail("presenting a serial never issued") };
ignore apply(#chequePresented({ account = 44; serial = 1; amount = 1_500_00; payee = #clearing({ house = "EGCH"; batch = "B-1" }); chequeDate = day0 - 3; imageHash = h("img"); hold = 4_000; expiresAt = day0 + 3; day = day0 }));
switch (Core.presentationFate(s, 44, 1, day0 - 3, day0)) { case (#err(#ChequeNotIn(_))) {}; case (_) fail("presenting a held cheque again") };
switch (Core.requireHeld(s, 44, 1)) { case (#ok(r)) { if (r.hold != 4_000 or r.amount != 1_500_00) fail("held row") }; case (#err(e)) fail(debug_show (e)) };
switch (Core.requireHeld(s, 44, 2)) { case (#err(#SerialNotIssued(_))) {}; case (_) fail("clearing an unused cheque") };
ignore apply(#chequeCleared({ account = 44; serial = 1; amount = 1_500_00; day = day0 + 1 }));
switch (Core.requireHeld(s, 44, 1)) { case (#err(#ChequeNotIn(_))) {}; case (_) fail("clearing twice") };
ignore apply(#chequePresented({ account = 44; serial = 2; amount = 900_00; payee = #inBranch({ till = "T1" }); chequeDate = day0; imageHash = h("img2"); hold = 4_001; expiresAt = day0 + 3; day = day0 }));
ignore apply(#chequeReturned({ account = 44; serial = 2; amount = 900_00; reason = #insufficientFunds; day = day0 + 1 }));
switch (Core.chequeView(s, 44, 2)) { case (?v) { if (v.state != #returned or v.reason != ?#insufficientFunds) fail("returned view") }; case null fail("no cheque") };
switch (Core.chequeView(s, 44, 3)) { case (?v) { if (v.state != #unused) fail("unused view") }; case null fail("no view for an issued serial") };
if (Core.chequeView(s, 44, 500) != null) fail("a view for a serial never issued");
Debug.print("count: cheque gates, fates and states = 20");

// ─── drafts ───────────────────────────────────────────────────────────────────
switch (Core.planIssueDraft(s, "", h("p"), 1_00, "EGP", #till("T1"), day0)) { case (#err(#InvalidRequest(_))) {}; case (_) fail("a draft without a serial") };
ignore act(Core.planIssueDraft(s, "D-1", h("p"), 3_000_00, "EGP", #account(44), day0));
switch (Core.planIssueDraft(s, "D-1", h("p"), 1_00, "EGP", #till("T1"), day0)) { case (#err(#DraftExists(_))) {}; case (_) fail("a serial issued twice") };
switch (Core.requireOutstanding(s, "D-1")) { case (#ok(r)) { if (r.amount != 3_000_00) fail("draft row") }; case (#err(e)) fail(debug_show (e)) };
ignore apply(#draftPaid({ serial = "D-1"; amount = 3_000_00; to = #till("T1"); day = day0 + 1 }));
switch (Core.requireOutstanding(s, "D-1")) { case (#err(#DraftNotOutstanding(_))) {}; case (_) fail("paying a paid draft") };
switch (Core.requireOutstanding(s, "D-9")) { case (#err(#UnknownDraft(_))) {}; case (_) fail("an unknown draft") };
Debug.print("count: draft gates and states = 6");

// ─── counts and fingerprint ───────────────────────────────────────────────────
let cs = Core.counts(s);
if (cs.sessions != 3 or cs.differences != 2 or cs.movements != 1 or cs.chequesPresented != 2 or cs.chequesReturned != 1 or cs.drafts != 1) fail("counts " # debug_show (cs));
let f1 = fp(s);
if (f1 != fp(s)) fail("fingerprint not deterministic");
ignore act(Core.planStop(s, 44, 8, "lost", day0));
if (fp(s) == f1) fail("fingerprint did not change");
Debug.print("count: sessions folded = " # Nat.toText(cs.sessions));
Debug.print("TELLER TEST GREEN");
