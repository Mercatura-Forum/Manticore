/// Islamic.test.mo: Islamic banking Islamic banking: the AAOIFI arithmetic, the contract gates, the fold, the pool.
///
/// What is proved here (no journal, no canister; the pure layer):
///   1. the standards' arithmetic: a Murabaha's instalments and profit under both methods (the proportionate allocation
///      and the effective rate found by bisection, the markup exact to the cent), the straight-line profit by day, the
///      depreciation of an Ijarah asset to its residual, a Musharakah's profit by ratio and loss by capital, an
///      Istisna'a's percentage-of-completion figures, a pool's distribution with PER, IRR and the weighted balances;
///   2. the gates: the policy, the board approval, an interest product refused, each kind's terms (FAS 28, 32, 4, 7, 10);
///   3. the lives: a Murabaha acquired, sold, collected, rebated; an Ijarah commenced, rentals collected, the ownership
///      transferred; a diminishing Musharakah's units, a loss not by capital refused; a Mudarabah's result; a Salam
///      delivered and sold, another failed; an Istisna'a's milestones; settlement gates;
///   4. the pools: reserves within the ceilings, a month distributed once, the figures stated;
///   5. the fold's reads and the fingerprint.
// engine: wasi-only

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";
import IT "../src/bank/IslamicTypes";
import Core "../src/bank/IslamicCore";

func fail(what : Text) { Debug.print("FAIL: " # what); assert false };
func fp(s : Core.State) : Blob { let w = C.Writer(); Core.fingerprintInto(w, s); w.toBlob() };
func h(t : Text) : Blob { Sha256.fromBlob(#sha256, Text.encodeUtf8(t)) };

let arena = RI.newArena();
let s = Core.newState(arena);
var block = 900;
func next() : Nat { block += 1; block };
func apply(ev : IT.IslamicEvent) : Nat { let b = next(); Core.fold(s, b, ev); b };
func ok(r : { #ok : IT.IslamicEvent; #err : IT.IslamicError }) : IT.IslamicEvent { switch (r) { case (#ok(ev)) ev; case (#err(e)) { fail("refused: " # debug_show (e)); loop {} } } };
func act(r : { #ok : IT.IslamicEvent; #err : IT.IslamicError }) : Nat { apply(ok(r)) };
func refused(r : { #ok : IT.IslamicEvent; #err : IT.IslamicError }, what : Text) { switch (r) { case (#ok(ev)) fail(what # " accepted: " # debug_show ev); case (#err(_)) {} } };
func refused2<X>(r : { #ok : X; #err : IT.IslamicError }, what : Text) { switch (r) { case (#ok(_)) fail(what # " accepted"); case (#err(_)) {} } };

let day0 = 20_726;
let policy : IT.Policy = {
  murabahaInventory = "1500"; murabahaReceivable = "1510"; deferredProfit = "1515"; murabahaIncome = "4500"; securityDeposits = "2500"; ijarahAssets = "1520"; accumulatedDepreciation = "1525";
  depreciationExpense = "5500"; rentalReceivable = "1530"; ijarahIncome = "4510"; musharakahInvestment = "1540"; musharakahIncome = "4520"; mudarabahInvestment = "1550"; mudarabahIncome = "4530";
  investmentLosses = "5510"; salamReceivable = "1560"; salamInventory = "1565"; salamIncome = "4540"; istisnaWip = "1570"; istisnaReceivable = "1575"; istisnaRevenue = "4550"; istisnaCosts = "5520";
  iahEquity = "2600"; profitEqualisationReserve = "2610"; investmentRiskReserve = "2620"; profitPayableToHolders = "2630"; mudaribShareIncome = "4560"; profitAttributableToHolders = "5530";
  charityPayable = "2700"; nostro = "1005"; perCeilingBps = 1_000; irrCeilingBps = 1_000;
};

// ─── 1. the standards' arithmetic ───────────────────────────────────────────
var arith = 0;
// proportionate: 12 equal instalments of 112,000.00; the markup 12,000.00 in twelve equal parts
let prop = Core.murabahaSchedule(100_000_00, 12_000_00, 12, #monthly, day0, #proportionate);
if (prop.size() != 12) fail("12 instalments");
var sumA = 0; var sumP = 0; var sumPr = 0;
for ((d, a, p, pr) in prop.vals()) { sumA += a; sumP += p; sumPr += pr; if (a != p + pr) fail("an instalment is principal plus profit") };
if (sumA != 112_000_00 or sumP != 100_000_00 or sumPr != 12_000_00) fail("the proportionate totals " # debug_show (sumA, sumP, sumPr));
if (prop[0].3 != 1_000_00 or prop[11].3 != 1_000_00) fail("equal profit parts");
if (prop[0].0 != day0 + 30) fail("the first due date a month on (30 September to 30 October): " # Nat.toText(prop[0].0));
arith += 1;
// effective rate: the annuity schedule whose total interest is the markup; the profit front-loaded, the totals exact
let eff = Core.murabahaSchedule(100_000_00, 12_000_00, 12, #monthly, day0, #effectiveRate);
var sumE = 0; var sumEP = 0;
for ((_, a, _, pr) in eff.vals()) { sumE += a; sumEP += pr };
if (sumE != 112_000_00 or sumEP != 12_000_00) fail("the effective-rate totals " # debug_show (sumE, sumEP));
if (not (eff[0].3 > eff[11].3)) fail("the effective rate front-loads the profit: " # debug_show (eff[0].3, eff[11].3));
if (eff[0].3 == prop[0].3) fail("the two methods differ");
arith += 1;
// straight-line by day
if (Core.proportionateBy(12_000_00, day0, day0 + 365, day0 + 73) != 2_400_00) fail("a fifth of the year");
if (Core.proportionateBy(12_000_00, day0, day0 + 365, day0 + 400) != 12_000_00 or Core.proportionateBy(12_000_00, day0, day0 + 365, day0) != 0) fail("the ends of the line");
// depreciation to the residual over the months
if (Core.depreciationBy(240_000_00, 24_000_00, day0, 48, day0 + 9_999) != 216_000_00) fail("full depreciation");
let half = Core.depreciationBy(240_000_00, 24_000_00, day0, 48, day0 + 730);
if (not (half > 100_000_00 and half < 116_000_00)) fail("two years of a four-year line: " # Nat.toText(half));
arith += 2;
// Musharakah: profit by ratio, loss by capital
let partners : [IT.Partner] = [{ party = 7; account = 44; capital = 300_000_00; profitBps = 6_000 }, { party = 8; account = 45; capital = 100_000_00; profitBps = 1_000 }];
let (bp, pp) = Core.shareProfit(50_000_00, 3_000, partners);
if (bp != 15_000_00 or pp[0].1 != 30_000_00 or pp[1].1 != 5_000_00) fail("profit by ratio " # debug_show (bp, pp));
let (bl, pl) = Core.shareLoss(60_000_00, 200_000_00, partners);   // capitals 200 / 300 / 100 of 600
if (bl != 20_000_00 or pl[0].1 != 30_000_00 or pl[1].1 != 10_000_00) fail("loss by capital " # debug_show (bl, pl));
let (bl2, _) = Core.shareLoss(1_00, 200_000_00, partners);           // rounding: the remainder is the bank's
if (bl2 != 1_00 - 50 - 16) fail("loss rounding " # Nat.toText(bl2));
arith += 2;
// Istisna'a: percentage of completion, cumulative less recognised
let (rv1, c1) = Core.completionFigures(500_000_00, 400_000_00, 3_000, 0);
let (rv2, c2) = Core.completionFigures(500_000_00, 400_000_00, 7_000, 3_000);
let (rv3, c3) = Core.completionFigures(500_000_00, 400_000_00, 10_000, 7_000);
if (rv1 + rv2 + rv3 != 500_000_00 or c1 + c2 + c3 != 400_000_00 or rv1 != 150_000_00 or c2 != 160_000_00) fail("completion figures");
arith += 1;
// a pool's month: PER 5%, mudarib 30%, IRR 3%, weighted balances 3 : 1
let dist = Core.distribute(1_000_00, 3_000, 500, 300, [(44, 3_000_000_00), (45, 1_000_000_00)]);
if (dist.per != 50_00 or dist.distributable != 950_00 or dist.mudaribShare != 285_00 or dist.holdersShare != 665_00 or dist.irr != 19_95 or dist.paid != 645_05) fail("the distribution " # debug_show dist);
if (dist.allocations[0].1 + dist.allocations[1].1 != dist.paid or dist.allocations[1].1 != 161_26 or dist.allocations[0].1 != 483_79) fail("the allocations " # debug_show dist.allocations);
arith += 1;
Debug.print("count: figures of the standards reproduced = " # Nat.toText(arith));

// ─── 2. gates ────────────────────────────────────────────────────────────────
var gates = 0;
switch (Core.planPolicy({ policy with nostro = "" })) { case (#err(#InvalidPolicy(_))) gates += 1; case (_) fail("a policy missing an account") };
switch (Core.planPolicy({ policy with perCeilingBps = 10_001 })) { case (#err(#InvalidPolicy(_))) gates += 1; case (_) fail("a ceiling over the whole") };
let mur : IT.Murabaha = { customer = 7; account = 44; asset = "10 TONNES OF STEEL COILS"; supplier = #external({ name = "Ezz Steel"; reference = "PO-77" }); costPrice = 100_000_00; markup = 12_000_00; instalments = 12; every = #monthly; method = #proportionate; promise = #binding; securityDeposit = 5_000_00; latePaymentCharityBps = 500; reference = "MUR-2026-0001" };
refused(Core.planOpen(s, #murabaha(mur), "EGP", "BR01", "ISAV", false, day0), "a contract before the policy");
ignore act(Core.planPolicy(policy));
switch (Core.planOpen(s, #murabaha(mur), "EGP", "BR01", "ISAV", false, day0)) { case (#err(#NoBoardApproval(_))) gates += 1; case (_) fail("no board approval") };
refused(Core.planApproveProduct("ISAV", { ref = ""; sha256 = h("r") }, day0), "an approval without a reference");
ignore act(Core.planApproveProduct("ISAV", { ref = "SSB-2026-07"; sha256 = h("resolution") }, day0));
switch (Core.planOpen(s, #murabaha(mur), "EGP", "BR01", "ISAV", true, day0)) { case (#err(#InterestOnShariaProduct(_))) gates += 1; case (_) fail("an interest product") };
refused(Core.planOpen(s, #murabaha({ mur with markup = 0 }), "EGP", "BR01", "ISAV", false, day0), "a Murabaha without a markup (FAS 28)");
refused(Core.planOpen(s, #murabaha({ mur with promise = #nonBinding }), "EGP", "BR01", "ISAV", false, day0), "hamish jiddiyah without a binding promise");
refused(Core.planOpen(s, #murabaha({ mur with every = #atMaturity; instalments = 3 }), "EGP", "BR01", "ISAV", false, day0), "three instalments at maturity");
let ija : IT.Ijarah = { lessee = 7; account = 44; asset = "CNC MACHINE"; cost = 240_000_00; usefulLifeMonths = 60; residual = 24_000_00; rental = 5_000_00; every = #monthly; periods = 48; transfer = ?#sale({ price = 24_000_00 }); reference = "IJA-2026-0001" };
refused(Core.planOpen(s, #ijarah({ ija with residual = 240_000_00 }), "EGP", "BR01", "ISAV", false, day0), "a residual at cost (FAS 32)");
let mus : IT.Musharakah = { partners = [{ party = 7; account = 44; capital = 300_000_00; profitBps = 6_000 }]; bankCapital = 200_000_00; bankProfitBps = 4_000; diminishing = ?{ units = 20; unitPrice = 10_000_00; every = #quarterly; rentalBps = 800 }; reference = "MUS-2026-0001" };
refused(Core.planOpen(s, #musharakah({ mus with bankProfitBps = 5_000 }), "EGP", "BR01", "ISAV", false, day0), "profit ratios not summing to the whole (FAS 4)");
let mud : IT.Mudarabah = { mudarib = 7; account = 44; capital = 150_000_00; bankProfitBps = 7_000; term = 365; reference = "MUD-2026-0001" };
refused(Core.planOpen(s, #mudarabah({ mud with bankProfitBps = 10_000 }), "EGP", "BR01", "ISAV", false, day0), "rabb al-mal taking the whole profit");
let sal : IT.Salam = { seller = 7; account = 44; commodity = "WHEAT"; quantity = 500; unit = "TONNE"; delivery = day0 + 90; priceAdvanced = 90_000_00; reference = "SAL-2026-0001" };
refused(Core.planOpen(s, #salam({ sal with delivery = day0 }), "EGP", "BR01", "ISAV", false, day0), "delivery today (FAS 7)");
let ist : IT.Istisna = { customer = 7; account = 44; specification = h("spec"); price = 500_000_00; estimatedCost = 400_000_00; milestones = [(day0 + 30, 3_000), (day0 + 90, 7_000), (day0 + 150, 10_000)]; contractor = #external({ name = "Orascom"; reference = "CTR-9" }); reference = "IST-2026-0001" };
refused(Core.planOpen(s, #istisna({ ist with milestones = [(day0 + 30, 3_000), (day0 + 90, 7_000)] }), "EGP", "BR01", "ISAV", false, day0), "milestones not reaching the whole (FAS 10)");
refused(Core.planOpen(s, #istisna({ ist with estimatedCost = 600_000_00 }), "EGP", "BR01", "ISAV", false, day0), "a cost above the price");
gates += 9;
Debug.print("count: policy, governance and terms gates = " # Nat.toText(gates));

// ─── 3. the lives ────────────────────────────────────────────────────────────
let fp0 = fp(s);
let m = act(Core.planOpen(s, #murabaha(mur), "EGP", "BR01", "ISAV", false, day0));
if (fp(s) == fp0) fail("the fingerprint did not move");
refused(Core.planOpen(s, #murabaha(mur), "EGP", "BR01", "ISAV", false, day0), "the same reference twice");
refused(Core.planSell(s, m, mur, day0), "a sale of an asset the bank does not own (FAS 28 ¶8)");
refused2(Core.planCollect(s, m, day0), "a collection before the sale");
ignore act(Core.planAcquire(s, m, day0));
refused(Core.planAcquire(s, m, day0), "acquiring twice");
ignore act(Core.planSell(s, m, mur, day0 + 1));
let ?rm = Core.row(s, m) else { fail("no row"); loop {} };
if (rm.stage != #sold or rm.instalmentsDue != 12 or rm.profitTotal != 12_000_00 or rm.principal != 100_000_00 or Core.outstanding(rm) != 112_000_00 or rm.securityDeposit != 5_000_00) fail("the sold row " # debug_show rm.stage);
let insts = Core.instalmentsOf(s, m);
if (insts.size() != 12 or insts[0].amount != 9_333_33 or insts[11].amount != 9_333_37 or insts[0].profit != 1_000_00) fail("the instalment rows " # debug_show (insts[0].amount, insts[11].amount));
// profit to the day: proportionate over the credit period (sale day to the last due date)
let lastDue = insts[11].dueDate;
let due40 = Core.profitDueBy(s, rm, day0 + 41);
if (due40 != 12_000_00 * 40 / (lastDue - (day0 + 1))) fail("profit due after forty days " # Nat.toText(due40));
ignore apply(#profitRecognised({ contract = m; amount = due40; cumulative = due40; day = day0 + 41 }));
// collections in order, the rows marked
switch (Core.planCollect(s, m, insts[0].dueDate)) { case (#ok((ev, i))) { if (i.number != 1 or i.amount != 9_333_33) fail("the first instalment"); ignore apply(ev) }; case (#err(e)) fail(debug_show e) };
let ?rm2 = Core.row(s, m) else { fail("no row"); loop {} };
if (rm2.instalmentsPaid != 1 or rm2.collected != 9_333_33 or rm2.nextDue != insts[1].dueDate) fail("after the first collection");
// the late-payment undertaking on an overdue instalment: never income
let late = Core.lateCharity(insts[1], 500, insts[1].dueDate + 30);
if (late != 9_333_33 * 500 * 30 / (10_000 * 365)) fail("late charity " # Nat.toText(late));
if (Core.lateCharity(insts[1], 500, insts[1].dueDate) != 0) fail("not late yet");
ignore apply(#latePaymentToCharity({ contract = m; instalment = 2; amount = late; cumulative = late; day = insts[1].dueDate + 30 }));
if (Core.status(s).charity != late) fail("charity total");
// ibra': discretionary, at most the profit not yet recognised
refused(Core.planRebate(s, m, 500_00, "", day0 + 50), "a rebate without a reason");
refused(Core.planRebate(s, m, 12_000_00, "settlement", day0 + 50), "a rebate beyond the unrecognised profit");
ignore act(Core.planRebate(s, m, 500_00, "early settlement at the bank's discretion", day0 + 50));
let ?rm3 = Core.row(s, m) else { fail("no row"); loop {} };
if (rm3.profitTotal != 11_500_00) fail("the rebate reduces the profit");
refused2(Core.planSettle(s, m, day0 + 60), "settling with instalments outstanding");
Debug.print("count: Murabaha acts and refusals = 14");
// Ijarah
let ij = act(Core.planOpen(s, #ijarah(ija), "EGP", "BR01", "ISAV", false, day0));
refused2(Core.planCollectRental(s, ij, day0 + 40), "a rental before commencement");
ignore act(Core.planCommence(s, ij, day0 + 2));
let ?ri = Core.row(s, ij) else { fail("no row"); loop {} };
if (ri.stage != #running or ri.instalmentsDue != 48 or ri.profitTotal != 240_000_00 or Core.instalmentsOf(s, ij).size() != 48) fail("the running lease");
refused2(Core.planCollectRental(s, ij, day0 + 10), "a rental not yet due (FAS 32)");
switch (Core.planCollectRental(s, ij, day0 + 40)) { case (#ok((ev, i))) { if (i.amount != 5_000_00) fail("rental"); ignore apply(ev) }; case (#err(e)) fail(debug_show e) };
refused(Core.planTransfer(s, ij, ija, day0 + 41), "a transfer before the rentals are paid (FAS 32 ¶40)");
let dep = Core.depreciationBy(ija.cost, ija.residual, day0 + 2, 48, day0 + 100);
ignore apply(#depreciationPosted({ contract = ij; amount = dep; cumulative = dep; day = day0 + 100 }));
let ?ri2 = Core.row(s, ij) else { fail("no row"); loop {} };
if (ri2.depreciation != dep or ri2.instalmentsPaid != 1) fail("depreciation on the row");
Debug.print("count: Ijarah acts and refusals = 6");
// Musharakah, diminishing
let mk = act(Core.planOpen(s, #musharakah(mus), "EGP", "BR01", "ISAV", false, day0));
refused(Core.planDistributeProfit(s, mk, mus, 10_000_00, day0 + 5), "a distribution before the capital is in");
ignore apply(#capitalContributed({ contract = mk; party = null; amount = 200_000_00; day = day0 + 1 }));
let ev1 = ok(Core.planDistributeProfit(s, mk, mus, 50_000_00, day0 + 90));
let #profitDistributed(pd) = ev1 else { fail("not a distribution"); loop {} };
if (pd.bankShare != 20_000_00 or pd.partnerShares[0].1 != 30_000_00) fail("the Musharakah profit split");
ignore apply(ev1);
switch (Core.planAllocateLoss(s, mk, mus, 10_000_00, ?[(7, 5_000_00)], day0 + 120)) { case (#err(#LossNotByCapital(_))) {}; case (r) fail("a loss by ratio accepted: " # debug_show r) };
let ev2 = ok(Core.planAllocateLoss(s, mk, mus, 10_000_00, ?[(7, 6_000_00)], day0 + 120));   // capitals 200 : 300
let #lossAllocated(la) = ev2 else { fail("not a loss"); loop {} };
if (la.bankShare != 4_000_00) fail("the bank's loss by capital");
ignore apply(ev2);
refused(Core.planBuyUnit(s, mk, mus, 21, day0 + 130), "more units than the bank holds");
ignore act(Core.planBuyUnit(s, mk, mus, 5, day0 + 130));
refused2(Core.planSettle(s, mk, day0 + 131), "settling with units unsold");
ignore act(Core.planBuyUnit(s, mk, mus, 15, day0 + 200));
let ?rk = Core.row(s, mk) else { fail("no row"); loop {} };
if (rk.unitsLeft != 0 or rk.collected != 200_000_00 or rk.principal != 196_000_00) fail("the diminishing row " # debug_show (rk.unitsLeft, rk.collected, rk.principal));
switch (Core.planSettle(s, mk, day0 + 201)) { case (#ok((ev, _))) ignore apply(ev); case (#err(e)) fail(debug_show e) };
Debug.print("count: Musharakah acts and refusals = 9");
// Mudarabah
let md = act(Core.planOpen(s, #mudarabah(mud), "EGP", "BR01", "ISAV", false, day0));
ignore apply(#capitalContributed({ contract = md; party = null; amount = 150_000_00; day = day0 + 1 }));
refused(Core.planMudarabahResult(s, md, mud, 10_00, 10_00, day0 + 100), "a profit and a loss at once");
refused(Core.planMudarabahResult(s, md, mud, 0, 160_000_00, day0 + 100), "a loss beyond the capital charged to rabb al-mal (FAS 4 ¶31)");
let ev3 = ok(Core.planMudarabahResult(s, md, mud, 20_000_00, 0, day0 + 100));
let #profitDistributed(pm) = ev3 else { fail("not a result"); loop {} };
if (pm.bankShare != 14_000_00 or pm.partnerShares[0].1 != 6_000_00) fail("the Mudarabah split");
ignore apply(ev3);
Debug.print("count: Mudarabah acts and refusals = 4");
// Salam: one delivered and sold, one failed
let sa = act(Core.planOpen(s, #salam(sal), "EGP", "BR01", "ISAV", false, day0));
refused(Core.planDeliver(s, sa, sal, 400, day0 + 90), "a short delivery (FAS 7 ¶9)");
refused(Core.planSellCommodity(s, sa, 95_000_00, day0 + 90), "a sale before delivery");
ignore act(Core.planDeliver(s, sa, sal, 500, day0 + 90));
ignore act(Core.planSellCommodity(s, sa, 97_000_00, day0 + 92));
let ?rs = Core.row(s, sa) else { fail("no row"); loop {} };
if (rs.collected != 97_000_00 or rs.profitRecognised != 7_000_00) fail("the Salam's result");
switch (Core.planSettle(s, sa, day0 + 93)) { case (#ok((ev, _))) ignore apply(ev); case (#err(e)) fail(debug_show e) };
let sb = act(Core.planOpen(s, #salam({ sal with reference = "SAL-2026-0002" }), "EGP", "BR01", "ISAV", false, day0));
refused(Core.planDeliveryFailed(s, sb, sal, "price returned", day0 + 10), "a failure before the delivery date");
ignore act(Core.planDeliveryFailed(s, sb, sal, "the price returned by the seller", day0 + 90));
let ?rsb = Core.row(s, sb) else { fail("no row"); loop {} };
if (rsb.stage != #defaulted) fail("defaulted");
Debug.print("count: Salam acts and refusals = 7");
// Istisna'a
let iz = act(Core.planOpen(s, #istisna(ist), "EGP", "BR01", "ISAV", false, day0));
refused(Core.planMilestone(s, iz, ist, h("c"), 2_000, day0 + 30), "a percentage no milestone states");
let ev4 = ok(Core.planMilestone(s, iz, ist, h("c1"), 3_000, day0 + 30));
let #milestoneRecorded(ms) = ev4 else { fail("not a milestone"); loop {} };
if (ms.revenue != 150_000_00 or ms.cost != 120_000_00) fail("the first milestone's figures");
ignore apply(ev4);
refused(Core.planMilestone(s, iz, ist, h("c2"), 3_000, day0 + 60), "a milestone that does not advance");
refused2(Core.planSettle(s, iz, day0 + 60), "settling an incomplete Istisna'a");
ignore act(Core.planMilestone(s, iz, ist, h("c2"), 7_000, day0 + 90));
ignore act(Core.planMilestone(s, iz, ist, h("c3"), 10_000, day0 + 150));
let ?rz = Core.row(s, iz) else { fail("no row"); loop {} };
if (rz.percentBps != 10_000 or rz.profitRecognised != 100_000_00) fail("the completed work " # debug_show (rz.percentBps, rz.profitRecognised));
switch (Core.planSettle(s, iz, day0 + 151)) { case (#ok((ev, _))) ignore apply(ev); case (#err(e)) fail(debug_show e) };
refused(Core.planClose(s, iz, "", day0 + 152), "a close without a reason");
ignore act(Core.planClose(s, iz, "delivered and paid", day0 + 152));
Debug.print("count: Istisna'a acts and refusals = 8");

// ─── 4. the pools ────────────────────────────────────────────────────────────
let pool : IT.Pool = { id = "PSIA-EGP"; currency = "EGP"; mudaribBps = 3_000; perBps = 500; irrBps = 300; product = "ISAV"; incomeAccounts = ["4500", "4510"] };
switch (Core.planOpenPool(s, { pool with perBps = 1_500 }, day0)) { case (#err(#ReserveOverCeiling(_))) {}; case (r) fail("PER over the ceiling accepted: " # debug_show r) };
ignore act(Core.planOpenPool(s, pool, day0));
refused(Core.planOpenPool(s, pool, day0), "the same pool twice");
switch (Core.planReserves(s, "PSIA-EGP", null, ?1_100, day0)) { case (#err(#ReserveOverCeiling(_))) {}; case (r) fail("IRR over the ceiling accepted: " # debug_show r) };
ignore act(Core.planReserves(s, "PSIA-EGP", ?400, null, day0 + 1));
let evd = ok(Core.planDistribute(s, "PSIA-EGP", "2026-09", day0 - 28, day0 + 1, 1_000_00, [(44, 3_000_000_00), (45, 1_000_000_00)], day0 + 2));
let #poolDistributed(pdd) = evd else { fail("not a distribution"); loop {} };
if (pdd.distribution.per != 40_00 or pdd.distribution.mudaribShare != 288_00 or pdd.distribution.paid != 672_00 - (672_00 * 300 / 10_000)) fail("the distribution with PER 4% " # debug_show pdd.distribution);
ignore apply(evd);
switch (Core.planDistribute(s, "PSIA-EGP", "2026-09", day0 - 28, day0 + 1, 1_000_00, [], day0 + 2)) { case (#err(#PeriodAlreadyDistributed(_))) {}; case (r) fail("a month twice: " # debug_show r) };
let ?pr = Core.pool(s, "PSIA-EGP") else { fail("no pool"); loop {} };
if (pr.distributions != 1 or pr.perBalance != 40_00 or pr.perBps != 400 or Core.distributionsOf(s, "PSIA-EGP").size() != 1) fail("the pool after a month");
Debug.print("count: pool acts and refusals = 7");

// ─── 5. reads ────────────────────────────────────────────────────────────────
let st = Core.status(s);
if (st.contracts != 7 or st.pools != 1 or st.distributions != 1 or st.charity != late) fail("status " # debug_show st);
if (Core.listByParty(s, 7, null, 10).ids.size() != 7) fail("by party");
if (Core.listByStage(s, #settled, null, 10).ids.size() != 2 or Core.listByStage(s, #closed, null, 10).ids.size() != 1 or Core.listByStage(s, #defaulted, null, 10).ids.size() != 1) fail("by stage");
if (Core.openAll(s).size() != 3) fail("open: the Murabaha, the Ijarah, the Mudarabah — " # Nat.toText(Core.openAll(s).size()));
// the fold's counters (S4.1) equal the walk: three open, all in EGP, all in one book
let openRows = Core.openAll(s);
let theBook = openRows[0].book;
var egp = 0; var inBook = 0; for (r in openRows.vals()) { if (Text.equal(r.currency, "EGP")) egp += 1; if (Text.equal(r.book, theBook)) inBook += 1 };
if (egp == 0 or inBook == 0) fail("the open contracts are in EGP and in one book");
if (Core.openInCurrency(s, "EGP") != egp or Core.openInCurrency(s, "USD") != 0) fail("open in currency counter " # Nat.toText(Core.openInCurrency(s, "EGP")) # " vs walk " # Nat.toText(egp));
if (Core.openCountInBook(s, theBook) != inBook or Core.openCountInBook(s, "NO-SUCH-BOOK") != 0) fail("open in book counter " # Nat.toText(Core.openCountInBook(s, theBook)) # " vs walk " # Nat.toText(inBook));
Debug.print("count: contract counters held equal to a walk = 2");
if (Core.approval(s, "ISAV") == null or Core.approval(s, "SAV") != null) fail("approvals");
ignore act(Core.planFlagBook("BR01", true, day0));
if (not Core.isShariaBook(s, "BR01") or Core.isShariaBook(s, "HQ")) fail("the book flag");
let v = Core.view(rm3);
if (v.kind != "murabaha" or v.stage != "sold" or v.instalmentsDue != 12) fail("the view");
Debug.print("count: fold reads = 7");
Debug.print("ISLAMIC TEST GREEN");
