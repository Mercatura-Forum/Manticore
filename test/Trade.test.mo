/// Trade.test.mo — trade finance trade finance: the ICC gates in the planners, the fold, the messages.
///
/// What is proved here (no journal, no canister — the pure layer):
///   1. the policy and terms gates: rules, expiry, presentation period, incoterms, tolerance, BICs, reductions;
///   2. a documentary credit's life: issue, a presentation within the period, an examination within five banking
///      days (the sixth day refused, art. 14(b)), a refusal that must name every failed check once (art. 16(c)),
///      a waiver, an honour matching the availability, a maturity, an amendment needing the beneficiary's consent
///      (art. 10) and a close that waits for pending claims;
///   3. an undertaking's life: a URDG demand without its supporting statement refused (art. 15), one over the
///      amount available refused (art. 17(c)), one after the effective expiry refused (art. 26 carries the expiry
///      past a closed day), a complying demand paid, a recorded reduction due, a release;
///   4. a collection on D/A terms: registered, presented, accepted, paid; a bill discounted from the acceptance;
///   5. the fold: rows, indexes, memoranda, the fingerprint changing with every event;
///   6. the messages: an MT 700 rendered and read back into the same terms, an MT 760 likewise, five tsrv
///      messages schema-valid under the generated profiles, the FIN amount and date codecs.
// engine: wasi-only

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Array "mo:core/Array";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";
import JT "mo:journal/JournalTypes";
import TrT "../src/bank/TradeTypes";
import Core "../src/bank/TradeCore";
import Msg "../src/bank/TradeMessages";
import Xml "../src/bank/Xml";
import IsoSchema "../src/bank/IsoSchema";

func fail(what : Text) { Debug.print("FAIL: " # what); assert false };
func fp(s : Core.State) : Blob { let w = C.Writer(); Core.fingerprintInto(w, s); w.toBlob() };
func h(t : Text) : Blob { Sha256.fromBlob(#sha256, Text.encodeUtf8(t)) };

let arena = RI.newArena();
let s = Core.newState(arena);
var block = 900;
func next() : Nat { block += 1; block };
func apply(ev : TrT.TradeEvent) : Nat { let b = next(); Core.fold(s, b, ev); b };
func ok(r : { #ok : TrT.TradeEvent; #err : TrT.TradeError }) : TrT.TradeEvent { switch (r) { case (#ok(ev)) ev; case (#err(e)) { fail("refused: " # debug_show (e)); loop {} } } };
func act(r : { #ok : TrT.TradeEvent; #err : TrT.TradeError }) : Nat { apply(ok(r)) };
func refused(r : { #ok : TrT.TradeEvent; #err : TrT.TradeError }, what : Text) { switch (r) { case (#ok(ev)) fail(what # " accepted: " # debug_show ev); case (#err(_)) {} } };

// a five-day week: Saturday and Sunday closed. Day 20726 (2026-09-30) is a Wednesday.
let weekend : ?JT.CalendarConfig = ?{ restDays = [5, 6]; holidays = []; policy = #next };   // Saturday = 5, Sunday = 6 (Monday = 0)
let day0 = 20_726;
let policy : TrT.Policy = {
  bic = "THEBEGCX"; contingentLcs = "9101"; contingentGuarantees = "9102"; contingentCollections = "9103"; contingentContra = "9199"; marginDeposits = "2320";
  unearnedCommission = "2330"; commissionIncome = "4310"; acceptancesPayable = "2340"; customersLiabilityAcceptances = "1310"; billsNegotiated = "1320";
  billsDiscounted = "1330"; unearnedDiscount = "2350"; discountIncome = "4320"; billsRediscounted = "2360"; billLosses = "5310"; nostro = "1005"; claimProduct = "CLAIM"; examinationDays = 5;
};

// ─── 1. gates ────────────────────────────────────────────────────────────────
var gates = 0;
switch (Core.planPolicy({ policy with bic = "THEB" })) { case (#err(#InvalidPolicy(_))) gates += 1; case (_) fail("a short BIC") };
switch (Core.planPolicy({ policy with examinationDays = 0 })) { case (#err(#InvalidPolicy(_))) gates += 1; case (_) fail("no examination period") };

let terms : TrT.DocumentaryTerms = {
  documents = [{ kind = #invoice; copies = 3; checks = ["INV-AMOUNT", "INV-GOODS"] }, { kind = #transport; copies = 1; checks = ["TRANS-ONBOARD", "TRANS-PORTS"] }, { kind = #insurance; copies = 1; checks = ["INS-COVER-110"] }];
  latestShipment = ?(day0 + 40); presentationDays = 21; partialShipments = false; transhipment = true; incoterm = ?"CIF"; availableBy = #sight;
  portOfLoading = "ALEXANDRIA"; portOfDischarge = "ROTTERDAM"; goods = "COTTON YARN 20 TONNES";
};
func lcTerms() : TrT.LetterOfCredit {
  { role = #issuing; applicant = #party({ party = 7; account = 44 }); beneficiary = #external({ name = "Nordic Textiles AB"; bic = "NDEASESS"; account = "SE4550000000058398257466" });
    counterpartyBank = "NDEASESS"; terms; tolerance = ?500; marginBps = 2_000; facility = null; commissionBps = 150; reference = "LC-2026-0001" }
};
let lc0 = lcTerms();
refused(Core.planIssueLc(s, lc0, 100_000_00, "EGP", day0 + 60, "CAIRO", "BR01", day0), "an issue before the policy");
ignore act(Core.planPolicy(policy));
refused(Core.planIssueLc(s, lc0, 0, "EGP", day0 + 60, "CAIRO", "BR01", day0), "a credit for nothing");
refused(Core.planIssueLc(s, lc0, 100_000_00, "EGP", day0, "CAIRO", "BR01", day0), "an expiry today");
refused(Core.planIssueLc(s, lc0, 100_000_00, "EGP", day0 + 60, "", "BR01", day0), "no place of expiry");
refused(Core.planIssueLc(s, { lc0 with terms = { terms with presentationDays = 22 } }, 100_000_00, "EGP", day0 + 60, "CAIRO", "BR01", day0), "22 days of presentation (art. 14(c))");
refused(Core.planIssueLc(s, { lc0 with terms = { terms with incoterm = ?"XYZ" } }, 100_000_00, "EGP", day0 + 60, "CAIRO", "BR01", day0), "an unknown Incoterm");
refused(Core.planIssueLc(s, { lc0 with terms = { terms with latestShipment = ?(day0 + 70) } }, 100_000_00, "EGP", day0 + 60, "CAIRO", "BR01", day0), "shipment after expiry");
refused(Core.planIssueLc(s, { lc0 with tolerance = ?1_500 }, 100_000_00, "EGP", day0 + 60, "CAIRO", "BR01", day0), "a fifteen per cent tolerance");
refused(Core.planIssueLc(s, { lc0 with counterpartyBank = "NDEA" }, 100_000_00, "EGP", day0 + 60, "CAIRO", "BR01", day0), "a five-character BIC");
refused(Core.planIssueLc(s, { lc0 with role = #advising }, 100_000_00, "EGP", day0 + 60, "CAIRO", "BR01", day0), "issuing in the advising role");
refused(Core.planIssueLc(s, { lc0 with applicant = #external({ name = "X"; bic = "NDEASESS"; account = "" }) }, 100_000_00, "EGP", day0 + 60, "CAIRO", "BR01", day0), "an external applicant on our own credit");
gates += 10;
Debug.print("count: policy and terms gates = " # Nat.toText(gates));

// ─── 2. a documentary credit ─────────────────────────────────────────────────
let fpBefore = fp(s);
let ev1 = ok(Core.planIssueLc(s, lc0, 100_000_00, "EGP", day0 + 60, "CAIRO", "BR01", day0));
let #lcIssued(iss) = ev1 else { fail("not an issue"); loop {} };
if (iss.margin != 20_000_00) fail("margin " # Nat.toText(iss.margin));
// commission: 100,000.00 × 1.5% × 60/365 = 246.57
if (iss.commission != 246_57) fail("commission " # Nat.toText(iss.commission));
let lc = apply(ev1);
if (fp(s) == fpBefore) fail("the fingerprint did not move on issue");
refused(Core.planIssueLc(s, lc0, 100_000_00, "EGP", day0 + 60, "CAIRO", "BR01", day0), "the same credit number twice");
let ?r1 = Core.row(s, lc) else { fail("no row"); loop {} };
if (r1.amount != 100_000_00 or r1.party != 7 or r1.account != 44 or r1.expiry != day0 + 60 or r1.book != "BR01" or r1.margin != 20_000_00) fail("the issued row");
if (Core.byReference(s, "LC-2026-0001") != ?lc) fail("the reference index");
if (Core.status(s).contingentLcs != 100_000_00) fail("contingent LCs " # Nat.toText(Core.status(s).contingentLcs));
if (Core.availableWithTolerance(r1) != 105_000_00) fail("tolerance");
// presentation: within 21 days of shipment, on or before expiry, within the tolerance
let docs : [TrT.DocumentRef] = [{ kind = #invoice; hash = h("inv") }, { kind = #transport; hash = h("bl") }, { kind = #insurance; hash = h("ins") }];
refused(Core.planPresent(s, weekend, lc, terms, docs, 60_000_00, ?(day0 + 10), day0 + 32, day0 + 32), "a presentation 22 days after shipment (art. 14(c))");
refused(Core.planPresent(s, weekend, lc, terms, docs, 60_000_00, ?(day0 + 45), day0 + 50, day0 + 50), "a shipment after the latest date (art. 44)");
refused(Core.planPresent(s, weekend, lc, terms, docs, 106_000_00, ?(day0 + 10), day0 + 20, day0 + 20), "over the face with the tolerance (art. 30)");
refused(Core.planPresent(s, weekend, lc, terms, docs, 60_000_00, ?(day0 + 10), day0 + 61, day0 + 61), "after expiry (art. 6(e))");
// day0 + 14 is a Wednesday: five banking days after it is the next Wednesday, day0 + 21
let p1 = ok(Core.planPresent(s, weekend, lc, terms, docs, 60_000_00, ?(day0 + 10), day0 + 14, day0 + 14));
let #documentsPresented(pr) = p1 else { fail("not a presentation"); loop {} };
if (pr.deadline != day0 + 21) fail("deadline " # Nat.toText(pr.deadline) # " expected " # Nat.toText(day0 + 21));
if (pr.claim != 1) fail("claim seq");
ignore apply(p1);
let checklist = [(#invoice : TrT.DocumentKind, "INV-AMOUNT"), (#invoice, "INV-GOODS"), (#transport, "TRANS-ONBOARD"), (#transport, "TRANS-PORTS"), (#insurance, "INS-COVER-110")];
func check(d : TrT.DocumentKind, c : Text, p : Bool) : TrT.CheckResult { { document = d; check = c; passed = p; finding = if (p) "" else "differs" } };
let allPass = [check(#invoice, "INV-AMOUNT", true), check(#invoice, "INV-GOODS", true), check(#transport, "TRANS-ONBOARD", true), check(#transport, "TRANS-PORTS", true), check(#insurance, "INS-COVER-110", true)];
let twoFail = [check(#invoice, "INV-AMOUNT", true), check(#invoice, "INV-GOODS", false), check(#transport, "TRANS-ONBOARD", true), check(#transport, "TRANS-PORTS", false), check(#insurance, "INS-COVER-110", true)];
refused(Core.planExamine(s, lc, 1, checklist, allPass, #complying, day0 + 22), "an examination on the sixth banking day (art. 14(b))");
refused(Core.planExamine(s, lc, 1, checklist, Array.sliceToArray<TrT.CheckResult>(allPass, 0, 4), #complying, day0 + 20), "a check of the checklist missing");
refused(Core.planExamine(s, lc, 1, checklist, twoFail, #complying, day0 + 20), "complying with two failed checks");
refused(Core.planExamine(s, lc, 1, checklist, twoFail, #refuse({ discrepancies = ["INV-GOODS"]; disposal = #heldPendingWaiver }), day0 + 20), "a notice naming one of two discrepancies (art. 16(c)(ii))");
refused(Core.planExamine(s, lc, 1, checklist, twoFail, #refuse({ discrepancies = ["INV-GOODS", "TRANS-PORTS", "INS-COVER-110"]; disposal = #heldPendingWaiver }), day0 + 20), "a notice naming a discrepancy no check found");
refused(Core.planExamine(s, lc, 1, checklist, allPass, #refuse({ discrepancies = []; disposal = #returned }), day0 + 20), "a refusal with nothing failed");
ignore act(Core.planExamine(s, lc, 1, checklist, twoFail, #refuse({ discrepancies = ["INV-GOODS", "TRANS-PORTS"]; disposal = #heldPendingWaiver }), day0 + 20));
let ?c1 = Core.claim(s, lc, 1) else { fail("no claim"); loop {} };
if (c1.state != #discrepant or c1.checksFailed != 2 or c1.checksTotal != 5) fail("the discrepant claim");
refused(Core.planHonour(s, lc, 1, terms.availableBy, #sight, day0 + 20), "honouring a discrepant presentation");
refused(Core.planWaive(s, lc, 1, h("consent"), day0 + 22), "a waiver on the sixth day (art. 16(b))");
ignore act(Core.planWaive(s, lc, 1, h("consent"), day0 + 21));
refused(Core.planHonour(s, lc, 1, terms.availableBy, #deferred({ due = day0 + 100 }), day0 + 21), "a deferred honour on a sight credit (art. 6(b))");
ignore act(Core.planHonour(s, lc, 1, terms.availableBy, #sight, day0 + 21));
let ?r2 = Core.row(s, lc) else { fail("no row"); loop {} };
if (r2.utilised != 60_000_00 or Core.outstanding(r2) != 40_000_00) fail("utilised after the honour");
if (Core.status(s).contingentLcs != 40_000_00) fail("contingent after the honour");
// an acceptance credit: a second presentation honoured by acceptance matures on its date
let accTerms = { terms with availableBy = #acceptance({ days = 90 }) };
ignore apply(ok(Core.planPresent(s, weekend, lc, accTerms, docs, 30_000_00, ?(day0 + 20), day0 + 25, day0 + 25)));
ignore act(Core.planExamine(s, lc, 2, checklist, allPass, #complying, day0 + 28));
refused(Core.planHonour(s, lc, 2, accTerms.availableBy, #acceptance({ due = day0 + 100 }), day0 + 28), "an acceptance maturing on the wrong day");
ignore act(Core.planHonour(s, lc, 2, accTerms.availableBy, #acceptance({ due = day0 + 25 + 90 }), day0 + 28));
refused(Core.planMature(s, lc, 2, day0 + 100), "settling an acceptance before its date");
refused(Core.planMature(s, lc, 1, day0 + 120), "settling a sight honour as an acceptance");
if (Core.holdsSubledger(s, Core.acceptanceSub(lc, 2)) != true) fail("the acceptance sub-ledger is not the shard's");
// amendments: the beneficiary's consent
refused(Core.planAmend(s, lc, { amount = ?90_000_00; expiry = null; latestShipment = null; other = ""; consents = [#applicant] }, day0 + 30), "an amendment without the beneficiary (art. 10)");
refused(Core.planAmend(s, lc, { amount = ?80_000_00; expiry = null; latestShipment = null; other = ""; consents = [#beneficiary] }, day0 + 30), "an amended face below what was drawn");
refused(Core.planAmend(s, lc, { amount = null; expiry = null; latestShipment = null; other = ""; consents = [#beneficiary] }, day0 + 30), "an amendment changing nothing");
ignore act(Core.planAmend(s, lc, { amount = ?120_000_00; expiry = ?(day0 + 90); latestShipment = null; other = "AMOUNT INCREASED"; consents = [#beneficiary, #applicant] }, day0 + 30));
let ?r3 = Core.row(s, lc) else { fail("no row"); loop {} };
if (r3.amount != 120_000_00 or r3.expiry != day0 + 90 or r3.amendments != 1) fail("the amended row");
if (Core.status(s).contingentLcs != 30_000_00) fail("contingent after the amendment " # Nat.toText(Core.status(s).contingentLcs));
// a close waits for the pending acceptance: it is honoured (not pending), so the close goes through
ignore apply(ok(Core.planPresent(s, weekend, lc, terms, docs, 10_000_00, ?(day0 + 30), day0 + 35, day0 + 35)));
refused(Core.planCloseLc(s, lc, "done", day0 + 36), "closing with a presentation under examination");
ignore act(Core.planExamine(s, lc, 3, checklist, twoFail, #refuse({ discrepancies = ["INV-GOODS", "TRANS-PORTS"]; disposal = #returned }), day0 + 36));
ignore act(Core.planMature(s, lc, 2, day0 + 25 + 90));
ignore act(Core.planCloseLc(s, lc, "fully utilised", day0 + 120));
let ?r4 = Core.row(s, lc) else { fail("no row"); loop {} };
if (r4.state != #closed or Core.status(s).contingentLcs != 0 or Core.status(s).open != 0) fail("closed");
refused(Core.planPresent(s, weekend, lc, terms, docs, 1_00, null, day0 + 121, day0 + 121), "a presentation under a closed credit");
Debug.print("count: documentary credit acts and refusals = 35");

// ─── 3. an undertaking ───────────────────────────────────────────────────────
let g0 : TrT.Guarantee = {
  kind = #demandGuarantee; rules = #URDG758; principal = 7; principalAccount = 44; beneficiary = #external({ name = "Port Authority"; bic = "CIBEEGCX"; account = "" });
  counterpartyBank = ""; wording = h("WE HEREBY UNDERTAKE"); statementRequired = true; reductions = [(day0 + 30, 60_000_00), (day0 + 60, 30_000_00)]; marginBps = 1_000; facility = ?77; commissionBps = 100; reference = "GT-2026-0001";
};
// day0 + 87 is a Saturday (day0 is a Wednesday): the effective expiry carries to the Monday, day0 + 89
let gExpiry = day0 + 87;
refused(Core.planIssueGuarantee(s, { g0 with rules = #UCP600 }, "WE HEREBY UNDERTAKE", 80_000_00, "EGP", gExpiry, "BR01", day0), "a guarantee under UCP");
refused(Core.planIssueGuarantee(s, { g0 with kind = #standby }, "WE HEREBY UNDERTAKE", 80_000_00, "EGP", gExpiry, "BR01", day0), "a standby under URDG");
refused(Core.planIssueGuarantee(s, g0, "OTHER WORDS", 80_000_00, "EGP", gExpiry, "BR01", day0), "wording that does not hash to the record");
refused(Core.planIssueGuarantee(s, { g0 with reductions = [(day0 + 60, 30_000_00), (day0 + 30, 60_000_00)] }, "WE HEREBY UNDERTAKE", 80_000_00, "EGP", gExpiry, "BR01", day0), "reductions out of order");
refused(Core.planIssueGuarantee(s, { g0 with reductions = [(day0 + 30, 90_000_00)] }, "WE HEREBY UNDERTAKE", 80_000_00, "EGP", gExpiry, "BR01", day0), "a reduction above the face");
let gt = act(Core.planIssueGuarantee(s, g0, "WE HEREBY UNDERTAKE", 80_000_00, "EGP", gExpiry, "BR01", day0));
if (Core.contingentOnFacility(s, 77) != 80_000_00) fail("the facility's contingent " # Nat.toText(Core.contingentOnFacility(s, 77)));
if (Core.contingentOnFacility(s, 78) != 0) fail("another facility's contingent");
if (Core.effectiveExpiry(weekend, gExpiry) != day0 + 89) fail("effective expiry " # Nat.toText(Core.effectiveExpiry(weekend, gExpiry)));
let demand : TrT.DocumentRef = { kind = #other("demand"); hash = h("demand") };
refused(Core.planDemand(s, weekend, gt, demand, 30_000_00, false, day0 + 10, day0 + 10), "a demand without its supporting statement (art. 15)");
refused(Core.planDemand(s, weekend, gt, demand, 90_000_00, true, day0 + 10, day0 + 10), "a demand over the amount available (art. 17(c))");
refused(Core.planDemand(s, weekend, gt, demand, 1_00, true, day0 + 90, day0 + 90), "a demand after the effective expiry");
ignore apply(ok(Core.planDemand(s, weekend, gt, demand, 1_00, true, day0 + 88, day0 + 88)));   // Sunday: still within the expiry carried to Monday
ignore act(Core.planExamine(s, gt, 1, [(#other("demand"), "DEMAND-SIGNED")], [check(#other("demand"), "DEMAND-SIGNED", false)], #refuse({ discrepancies = ["DEMAND-SIGNED"]; disposal = #returned }), day0 + 89));
let ?gc1 = Core.claim(s, gt, 1) else { fail("no demand"); loop {} };
if (gc1.state != #rejected) fail("a refused demand is rejected, not held for a waiver: " # TrT.claimStateText(gc1.state));
let d2 = ok(Core.planDemand(s, weekend, gt, demand, 30_000_00, true, day0 + 10, day0 + 10));
let #demandRecorded(dr) = d2 else { fail("not a demand"); loop {} };
// day0 + 10 is a Saturday; five business days following it end on the Friday, day0 + 16
if (dr.deadline != day0 + 16) fail("demand deadline " # Nat.toText(dr.deadline));
ignore apply(d2);
switch (Core.planPayDemand(s, gt, 2, day0 + 12)) { case (#err(_)) {}; case (#ok(_)) fail("paying an unexamined demand") };
ignore act(Core.planExamine(s, gt, 2, [(#other("demand"), "DEMAND-SIGNED"), (#other("demand"), "DEMAND-STATEMENT")], [check(#other("demand"), "DEMAND-SIGNED", true), check(#other("demand"), "DEMAND-STATEMENT", true)], #complying, day0 + 15));
switch (Core.planPayDemand(s, gt, 2, day0 + 15)) { case (#ok(c)) { if (c.amount != 30_000_00) fail("the demand's amount") }; case (#err(e)) fail("pay refused: " # debug_show e) };
ignore apply(#demandPaid({ instrument = gt; claim = 2; amount = 30_000_00; fromMargin = 8_000_00; fromAccount = 22_000_00; claimAccount = null; day = day0 + 15 }));
let ?rg = Core.row(s, gt) else { fail("no row"); loop {} };
if (rg.utilised != 30_000_00 or rg.margin != 0 or Core.status(s).contingentGuarantees != 50_000_00) fail("after the demand was paid");
// the recorded reductions: on day0 + 30 to 60,000 — the utilised 30,000 leaves 30,000 outstanding
switch (Core.reductionDue(g0, rg, day0 + 29)) { case null {}; case (?x) fail("a reduction due early: " # Nat.toText(x)) };
switch (Core.reductionDue(g0, rg, day0 + 30)) { case (?60_000_00) {}; case (x) fail("the first reduction: " # debug_show x) };
ignore act(Core.planReduce(s, gt, 60_000_00, day0 + 30));
refused(Core.planReduce(s, gt, 20_000_00, day0 + 60), "a reduction below what was paid");
switch (Core.reductionDue(g0, { rg with amount = 60_000_00 }, day0 + 60)) { case (?30_000_00) {}; case (x) fail("the second reduction: " # debug_show x) };
ignore act(Core.planReduce(s, gt, 30_000_00, day0 + 60));
if (Core.status(s).contingentGuarantees != 0) fail("contingent after the reductions " # Nat.toText(Core.status(s).contingentGuarantees));
if (Core.expiredBy(s, weekend, day0 + 89).size() != 0) fail("expired before the carried expiry passed");
if (Core.expiredBy(s, weekend, day0 + 90).size() != 1) fail("not expired the day after the carried expiry");
ignore act(Core.planRelease(s, gt, "the original returned by the beneficiary", day0 + 70));
refused(Core.planDemand(s, weekend, gt, demand, 1_00, true, day0 + 71, day0 + 71), "a demand under a released guarantee");
if (Core.contingentOnFacility(s, 77) != 0) fail("the facility's contingent after release");
Debug.print("count: undertaking acts and refusals = 22");

// ─── 4. a collection and a bill ──────────────────────────────────────────────
let col0 : TrT.Collection = {
  role = #collecting; terms = #DA({ tenorDays = 60 }); drawer = #external({ name = "Shanghai Machines"; bic = "BKCHCNBJ"; account = "" }); drawee = #party({ party = 7; account = 44 });
  counterpartyBank = "BKCHCNBJ"; documents = docs; instructions = "DELIVER DOCUMENTS AGAINST ACCEPTANCE"; commissionBps = 25; reference = "COL-2026-0001";
};
refused(Core.planRegisterCollection(s, { col0 with drawee = #external({ name = "X"; bic = "BKCHCNBJ"; account = "" }) }, 40_000_00, "EGP", "BR01", day0), "a collecting bank presenting to a stranger");
refused(Core.planRegisterCollection(s, { col0 with terms = #DA({ tenorDays = 0 }) }, 40_000_00, "EGP", "BR01", day0), "a D/A collection without a tenor");
let col = act(Core.planRegisterCollection(s, col0, 40_000_00, "EGP", "BR01", day0));
if (Core.status(s).contingentCollections != 40_000_00) fail("items for collection");
refused(Core.planAcceptCollection(s, col, 60, day0 + 2), "accepting before presentation");
switch (Core.planPayCollection(s, col, day0 + 2)) { case (#err(_)) {}; case (#ok(_)) fail("paying a D/A collection before acceptance") };
ignore act(Core.planPresentCollection(s, col, day0 + 2, day0 + 2));
ignore act(Core.planAcceptCollection(s, col, 60, day0 + 3));
let ?cc = Core.claim(s, col, 1) else { fail("no collection claim"); loop {} };
if (cc.state != #accepted or cc.due != day0 + 62) fail("the acceptance");
// the bill drawn on the acceptance: face and maturity must match
let bill0 : TrT.Bill = { customer = 7; customerAccount = 44; acceptor = col0.drawer; source = ?{ instrument = col; claim = 1 }; discountBps = 800; recourse = true; reference = "BILL-2026-0001" };
refused(Core.planDiscountBill(s, bill0, 41_000_00, "EGP", day0 + 62, "BR01", day0 + 3), "a bill for more than the acceptance");
refused(Core.planDiscountBill(s, bill0, 40_000_00, "EGP", day0 + 61, "BR01", day0 + 3), "a bill maturing on another day");
let bd = ok(Core.planDiscountBill(s, bill0, 40_000_00, "EGP", day0 + 62, "BR01", day0 + 3));
let #billDiscounted(bdx) = bd else { fail("not a discount"); loop {} };
// 40,000.00 × 8% × 59/365 = 517.26
if (bdx.discount != 517_26 or bdx.proceeds != 39_482_74) fail("discount " # Nat.toText(bdx.discount) # " proceeds " # Nat.toText(bdx.proceeds));
let bill = apply(bd);
refused(Core.planDiscountBill(s, bill0, 40_000_00, "EGP", day0 + 62, "BR01", day0 + 3), "the same acceptance discounted twice");
switch (Core.planBillMatured(s, bill, day0 + 61)) { case (#err(_)) {}; case (#ok(_)) fail("a bill matured early") };
ignore act(Core.planRediscount(s, bill, "CENTRAL BANK", day0 + 10));
if (Core.earnedBy(bdx.discount, day0 + 3, day0 + 62, day0 + 32) != 517_26 * 29 / 59) fail("straight-line discount");
if (Core.earnedBy(bdx.discount, day0 + 3, day0 + 62, day0 + 70) != 517_26) fail("straight-line at the end");
switch (Core.planBillMatured(s, bill, day0 + 62)) { case (#ok((ev, _))) ignore apply(ev); case (#err(e)) fail("maturity: " # debug_show e) };
switch (Core.planPayCollection(s, col, day0 + 62)) { case (#ok((ev, _))) { let #collectionPaid(cp) = ev else { fail("not a payment"); loop {} }; if (cp.commission != 100_00) fail("commission"); ignore apply(ev) }; case (#err(e)) fail("collection payment: " # debug_show e) };
if (Core.status(s).contingentCollections != 0) fail("items for collection after payment");
let ?rb = Core.row(s, bill) else { fail("no bill"); loop {} };
if (rb.state != #matured or rb.commissionEarned != 517_26) fail("the matured bill");
Debug.print("count: collection and bill acts and refusals = 13");

// ─── 5. the fold's reads ─────────────────────────────────────────────────────
let st = Core.status(s);
if (st.instruments != 4 or st.claims != 6 or st.amendments != 1 or st.open != 0) fail("status " # debug_show st);
if (Core.listByParty(s, 7, null, 10).ids.size() != 4) fail("by party");
if (Core.listByState(s, #closed, null, 10).ids.size() != 1 or Core.listByState(s, #released, null, 10).ids.size() != 1 or Core.listByState(s, #matured, null, 10).ids.size() != 1 or Core.listByState(s, #paid, null, 10).ids.size() != 1) fail("by state");
if (Core.openAll(s).size() != 0) fail("open all");
if (Core.openInCurrency(s, "EGP") != 0 or Core.openInCurrency(s, "USD") != 0 or Core.openCountInBook(s, "HQ") != 0) fail("the per-currency and per-book counters return to zero with the last instrument closed");
Debug.print("count: instrument counters at zero after every close = 3");
if (Core.claimsOf(s, lc).size() != 3 or Core.messagesOf(s, lc).size() != 0) fail("claims of the credit");
ignore act(Core.planRecordMessage(s, lc, #mt(707), #outgoing, h("mt707"), day0 + 30));
refused(Core.planRecordMessage(s, lc, #mt(103), #outgoing, h("mt103"), day0 + 30), "an MT 103 as a trade message");
if (Core.messagesOf(s, lc).size() != 1) fail("messages of the credit");
let v = Core.view(s, r4);
if (v.kind != "letterOfCredit" or v.state != "closed" or v.role != "issuing" or v.claims != 3) fail("the view");
Debug.print("count: fold reads = 8");

// ─── 6. the messages ─────────────────────────────────────────────────────────
if (Msg.finDate(20_726) != "260930") fail("finDate " # Msg.finDate(20_726));
if (Msg.parseFinDate("260930") != ?20_726) fail("parseFinDate");
if (Msg.finAmount(100_000_00, 2) != "100000,00" or Msg.finAmount(5, 2) != "0,05" or Msg.finAmount(7, 0) != "7,") fail("finAmount");
if (Msg.parseFinAmount("100000,00", 2) != ?100_000_00 or Msg.parseFinAmount("0,5", 2) != ?50 or Msg.parseFinAmount("12", 2) != ?12_00 or Msg.parseFinAmount("1,234", 2) != null) fail("parseFinAmount");
if (Msg.terminal("THEBEGCX") != "THEBEGCXXXXX" or Msg.terminal("THEBEGCXABC") != "THEBEGCXXABC") fail("terminal");
let facts : Msg.LcFacts = { lc = lc0; amount = 100_000_00; currency = "EGP"; minorUnits = 2; expiry = day0 + 60; placeOfExpiry = "CAIRO"; issuedDay = day0; bankName = "Thebes Bank" };
let mt700 = Msg.mt700(policy.bic, facts);
if (not Text.startsWith(mt700, #text "{1:F01THEBEGCXXXXX0000000000}{2:I700NDEASESSXXXXN}{4:")) fail("the FIN envelope: " # mt700);
func mu(c : Text) : ?Nat8 { if (c == "EGP") ?2 else null };
let checklistByKind : [(TrT.DocumentKind, [Text])] = [(#invoice, ["INV-AMOUNT", "INV-GOODS"]), (#transport, ["TRANS-ONBOARD", "TRANS-PORTS"]), (#insurance, ["INS-COVER-110"])];
switch (Msg.parseMt700(mt700, mu, checklistByKind)) {
  case (#err(why)) fail("parseMt700: " # why);
  case (#ok(p)) {
    if (p.reference != "LC-2026-0001" or p.amount != 100_000_00 or p.currency != "EGP" or p.expiry != day0 + 60 or p.placeOfExpiry != "CAIRO" or p.issuedDay != day0) fail("parsed head: " # debug_show (p.reference, p.amount, p.expiry, p.placeOfExpiry));
    if (p.tolerance != ?500 or p.issuingBank != "THEBEGCX" or p.beneficiaryName != "NORDIC TEXTILES AB" or p.beneficiaryAccount != "SE4550000000058398257466") fail("parsed parties");
    if (p.terms.documents.size() != 3 or p.terms.documents[0].kind != #invoice or p.terms.documents[0].copies != 3 or p.terms.documents[0].checks != ["INV-AMOUNT", "INV-GOODS"]) fail("parsed documents " # debug_show p.terms.documents);
    if (p.terms.latestShipment != terms.latestShipment or p.terms.presentationDays != 21 or p.terms.partialShipments or not p.terms.transhipment or p.terms.incoterm != ?"CIF") fail("parsed terms");
    if (p.terms.portOfLoading != "ALEXANDRIA" or p.terms.portOfDischarge != "ROTTERDAM" or p.terms.availableBy != #sight or p.confirmationAsked) fail("parsed shipment terms");
  };
};
let mt700acc = Msg.mt700(policy.bic, { facts with lc = { lc0 with terms = accTerms; role = #confirming } });
switch (Msg.parseMt700(mt700acc, mu, checklistByKind)) { case (#ok(p)) { if (p.terms.availableBy != #acceptance({ days = 90 }) or not p.confirmationAsked) fail("acceptance availability parsed as " # TrT.availabilityText(p.terms.availableBy)) }; case (#err(why)) fail(why) };
let mt760 = Msg.mt760(policy.bic, { g = g0; amount = 80_000_00; currency = "EGP"; minorUnits = 2; expiry = gExpiry; issuedDay = day0; wordingText = "WE HEREBY UNDERTAKE" });
switch (Msg.parseMt760(mt760, mu)) {
  case (#err(why)) fail("parseMt760: " # why);
  case (#ok(p)) { if (p.reference != "GT-2026-0001" or p.amount != 80_000_00 or p.expiry != gExpiry or p.kind != #demandGuarantee or p.rules != #URDG758 or not p.statementRequired or p.issuingBank != "THEBEGCX") fail("parsed guarantee " # debug_show (p.reference, p.amount, p.kind)) };
};
// the other MTs render as FIN messages with their type
for ((mt, text) in [(707, Msg.mt707(policy.bic, "NDEASESS", "LC-2026-0001", day0, 1, day0 + 30, "EGP", 2, 100_000_00, { amount = ?120_000_00; expiry = ?(day0 + 90); latestShipment = null; other = "INCREASED"; consents = [#beneficiary] })),
                    (750, Msg.mt750(policy.bic, "NDEASESS", "LC-2026-0001", "EGP", 2, 60_000_00, ["INV-GOODS", "TRANS-PORTS"], #heldPendingWaiver)),
                    (752, Msg.mt752(policy.bic, "NDEASESS", "LC-2026-0001", day0 + 21, "EGP", 2, 60_000_00)),
                    (754, Msg.mt754(policy.bic, "NDEASESS", "LC-2026-0001", "EGP", 2, 30_000_00, #acceptance({ due = day0 + 115 }))),
                    (767, Msg.mt767(policy.bic, "CIBEEGCX", "GT-2026-0001", day0, 1, day0 + 5, "EGP", 2, 80_000_00, { amount = null; expiry = ?(day0 + 100); latestShipment = null; other = ""; consents = [#beneficiary] })),
                    (765, Msg.mt765(policy.bic, "CIBEEGCX", "GT-2026-0001", day0 + 10, "EGP", 2, 30_000_00, true)),
                    (768, Msg.mt768(policy.bic, "CIBEEGCX", "GT-2026-0001", day0 + 11)),
                    (769, Msg.mt769(policy.bic, "CIBEEGCX", "GT-2026-0001", day0 + 30, "EGP", 2, 20_000_00, 60_000_00)),
                    (799, Msg.mt799(policy.bic, "CIBEEGCX", "GT-2026-0001", "free text"))].vals()) {
  switch (Msg.fields(text)) { case (?f) { if (f.mt != mt or f.sender != "THEBEGCX") fail("MT " # Nat.toText(mt) # " envelope") }; case null fail("MT " # Nat.toText(mt) # " unparseable") };
};
// the tsrv messages validate under the generated profiles
func valid(name : Text, xml : Text) {
  switch (Xml.parse(Text.encodeUtf8(xml))) {
    case (#err(i)) fail(name # " does not parse: " # debug_show i);
    case (#ok(doc)) {
      switch (IsoSchema.schemaFor(doc.namespace)) {
        case null fail(name # ": no profile for " # doc.namespace);
        case (?sch) { let issues = IsoSchema.validate(sch, doc); if (issues.size() > 0) fail(name # " schema: " # debug_show issues[0]) };
      };
    };
  };
};
let gf : Msg.GuaranteeFacts = { g = g0; amount = 80_000_00; currency = "EGP"; minorUnits = 2; expiry = gExpiry; issuedDay = day0; wordingText = "WE HEREBY UNDERTAKE & PAY <ON DEMAND>" };
valid("tsrv.001", Msg.tsrv001(policy.bic, "Thebes Bank", gf));
valid("tsrv.005", Msg.tsrv005(policy.bic, "Thebes Bank", "GT-2026-0001", 1, day0 + 5, "EGP", 2, 80_000_00, { amount = ?90_000_00; expiry = ?(day0 + 100); latestShipment = null; other = "EXTENDED & INCREASED"; consents = [#beneficiary] }));
valid("tsrv.013", Msg.tsrv013(policy.bic, "Thebes Bank", "GT-2026-0001", "GT-2026-0001/D1", "EGP", 2, 30_000_00, true));
valid("tsrv.016", Msg.tsrv016(policy.bic, "Thebes Bank", "GT-2026-0001", "GT-2026-0001/D1", 1_790_000_000_000_000_000, "EGP", 2, 30_000_00, ["DEMAND-SIGNED", "DEMAND-STATEMENT"], "documents held at the disposal of the presenter"));
valid("tsrv.012", Msg.tsrv012(policy.bic, "Thebes Bank", "GT-2026-0001", day0 + 70, "released: the original returned"));
Debug.print("count: messages rendered, read back and schema-validated = 18");
Debug.print("TRADE TEST GREEN");
