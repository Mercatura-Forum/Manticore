// Facility.test.mo — corporate lending's facilities as the bank records them (corporate lending), on the pure core over a real
// stable-memory arena.
//
// What is proved:
//
//   * the terms' gates for every kind (a limit, the availability, the pricing, the covenants, the syndicate's
//     shares leaving the bank a part, a lease's residual, a factor's advance and discount);
//   * the arithmetic the postings rest on, pure and equal to the hand-worked figure: the allocation of an amount by
//     shares with the residue to the bank, the straight line of a rental or a discount over a term (reaching the
//     total exactly on the last day), a covenant's test, a purchase's split into advance, discount and retention;
//   * the drawing admitted under the aggregate limit inside the availability and refused over it, outside it, on a
//     blocked facility, twice on a bilateral term;
//   * the fold: rows, the indexes by party, stage, drawing and account, the syndicate's shares moved by a transfer,
//     the receivables' rows through purchase, unwind, collection, dishonour and write-off, the covenants' status,
//     the rate fixings and the fixing in force on a day, the review flag; the distribution and the counts; the
//     fingerprint deterministic and changing.
//
// engine: wasi-only — Regions.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Array "mo:core/Array";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";
import FT "../src/bank/FacilityTypes";
import Core "../src/bank/FacilityCore";

func fail(what : Text) { Debug.print("FAIL: " # what); assert false };
func fp(s : Core.State) : Blob { let w = C.Writer(); Core.fingerprintInto(w, s); w.toBlob() };
func h(t : Text) : Blob { Sha256.fromBlob(#sha256, Text.encodeUtf8(t)) };

let arena = RI.newArena();
let s = Core.newState(arena);
var block = 500;
func next() : Nat { block += 1; block };
func apply(ev : FT.FacilityEvent) : Nat { let b = next(); Core.apply(s, b, ev); b };
func ok(r : Core.Planned) : FT.FacilityEvent { switch (r) { case (#ok(ev)) ev; case (#err(e)) { fail("refused: " # debug_show (e)); loop {} } } };

let day0 = 20_726;
let base : FT.Terms = {
  party = 7; book = "HQ"; product = "FACL"; kind = #bilateralTerm; currency = "EGP"; limit = 1_000_000_00;
  availabilityFrom = day0; availabilityTo = day0 + 365; pricing = #fixed(1200); covenants = []; collateral = []; reviewEvery = null;
};

// ─── the terms' gates ─────────────────────────────────────────────────────────
func bad(t : FT.Terms, what : Text) { switch (Core.validTerms(t)) { case (?_) {}; case null fail(what # " accepted") } };
bad({ base with limit = 0 }, "no limit");
bad({ base with availabilityTo = day0 - 1 }, "availability ending before it starts");
bad({ base with pricing = #floating({ index = ""; spreadBps = 100; resetDays = 30 }) }, "a floating price without an index");
bad({ base with pricing = #floating({ index = "CBE-ON"; spreadBps = 100; resetDays = 0 }) }, "a zero reset");
bad({ base with covenants = [{ id = "a"; kind = #negativePledge }, { id = "a"; kind = #negativePledge }] }, "a covenant twice");
bad({ base with kind = #revolving({ commitmentFeeBps = 50; cleanDown = ?{ everyDays = 30; forDays = 31 } }) }, "a clean-down longer than its window");
bad({ base with kind = #syndicatedAgent({ shares = [{ participant = 8; bps = 6000 }, { participant = 9; bps = 4000 }]; agentFeeBps = 0 }) }, "shares leaving the bank nothing");
bad({ base with kind = #syndicatedAgent({ shares = [{ participant = 8; bps = 2000 }, { participant = 8; bps = 1000 }]; agentFeeBps = 0 }) }, "a participant twice");
bad({ base with kind = #syndicatedParticipant({ agent = "A"; agentScheme = #mldsa44; agentKey = ""; agentAccount = "1998"; ourBps = 2500 }) }, "a signing agent without a key");
bad({ base with kind = #financeLease({ assetAccount = "1500"; residual = 1_000_000_00 }) }, "a residual as large as the lease");
bad({ base with kind = #operatingLease({ rentalPerPeriod = 0; every = #monthly; periods = 12 }) }, "an operating lease without rentals");
bad({ base with kind = #factoring({ advanceBps = 9000; discountBps = 1500; recourse = true; clientAccount = 44 }) }, "advance and discount over the face");
bad({ base with kind = #forfaiting({ discountBps = 0; clientAccount = 44 }) }, "a forfaiting without a discount");
bad({ base with reviewEvery = ?0 }, "a zero review period");
if (Core.validTerms(base) != null) fail("the base terms refused");
Debug.print("count: terms gates held = 14");

// ─── the arithmetic ───────────────────────────────────────────────────────────
let shares : [FT.Share] = [{ participant = 8; bps = 2000 }, { participant = 9; bps = 1500 }, { participant = 10; bps = 2500 }];
let alloc = Core.allocate(shares, 1_000_001);
if (alloc.parts != [(8, 200_000), (9, 150_000), (10, 250_000)] or alloc.own != 400_001) fail("allocation " # debug_show (alloc));
var allocChecks = 0;
for (amount in [1, 7, 99, 12_345_67, 1_000_000_00].vals()) {
  let a = Core.allocate(shares, amount);
  var sum = a.own;
  for ((_, x) in a.parts.vals()) sum += x;
  if (sum != amount) fail("allocation does not sum");
  allocChecks += 1;
};
Debug.print("count: allocations summing to the whole with the residue the bank's = " # Nat.toText(allocChecks));
if (Core.straightLine(360_000_00, 360, 0) != 0 or Core.straightLine(360_000_00, 360, 1) != 1_000_00 or Core.straightLine(360_000_00, 360, 360) != 360_000_00 or Core.straightLine(360_000_00, 360, 400) != 360_000_00) fail("straight line");
if (Core.straightLine(1_000, 3, 1) != 333 or Core.straightLine(1_000, 3, 2) != 666 or Core.straightLine(1_000, 3, 3) != 1_000) fail("straight line residue to the last day");
if (Core.straightLine(5, 0, 9) != 5) fail("a zero term recognises everything");
Debug.print("count: straight-line figures = 8");
let lev : FT.Covenant = { id = "lev"; kind = #financialRatio({ name = "nd/ebitda"; op = #atMost; thresholdBps = 35_000 }) };
if (not Core.covenantMet(lev, 35_000, day0) or Core.covenantMet(lev, 35_001, day0)) fail("atMost");
if (Core.covenantMet({ lev with kind = #financialRatio({ name = "icr"; op = #atLeast; thresholdBps = 20_000 }) }, 19_999, day0)) fail("atLeast");
if (not Core.covenantMet({ lev with kind = #reporting({ due = day0 + 10 }) }, 0, day0 + 10) or Core.covenantMet({ lev with kind = #reporting({ due = day0 + 10 }) }, 0, day0 + 11)) fail("reporting");
if (not Core.covenantMet({ lev with kind = #negativePledge }, 1, day0) or Core.covenantMet({ lev with kind = #negativePledge }, 0, day0)) fail("pledge");
Debug.print("count: covenant tests = 6");
let fig = Core.purchaseFigures(#factoring({ advanceBps = 8000; discountBps = 300; recourse = true; clientAccount = 44 }), { ref = h("r"); debtorCommit = h("d"); face = 120_000_00; due = day0 + 60 });
if (fig.advance != 96_000_00 or fig.discount != 3_600_00 or fig.retention != 20_400_00) fail("factoring figures " # debug_show (fig));
let ffig = Core.purchaseFigures(#forfaiting({ discountBps = 500; clientAccount = 44 }), { ref = h("r"); debtorCommit = h("d"); face = 400_000_00; due = day0 + 60 });
if (ffig.advance != 380_000_00 or ffig.discount != 20_000_00 or ffig.retention != 0) fail("forfaiting figures");
Debug.print("count: purchase splits = 2");

// ─── the fold: a revolver, its drawings, the limit ────────────────────────────
let rev = apply(#facilityOpened({ terms = { base with kind = #revolving({ commitmentFeeBps = 50; cleanDown = ?{ everyDays = 30; forDays = 5 } }); covenants = [lev]; reviewEvery = ?45 }; day = day0 }));
switch (Core.view(s, rev, [lev])) { case (?v) { if (v.stage != #open or v.limit != base.limit or v.nextReview != ?(day0 + 45) or v.covenants.size() != 1) fail("the opened view") }; case null fail("no row") };
switch (Core.admitDrawdown(s, rev, 0, 0, day0, false)) { case (#err(#InvalidTerms(_))) {}; case (r) fail("a drawing of nothing " # debug_show (r)) };
switch (Core.admitDrawdown(s, rev, 600_000_00, 500_000_00, day0, false)) { case (#err(#OverLimit(_))) {}; case (r) fail("over the limit " # debug_show (r)) };
switch (Core.admitDrawdown(s, rev, 1, 0, day0 + 366, false)) { case (#err(#OutsideAvailability(_))) {}; case (r) fail("outside availability " # debug_show (r)) };
switch (Core.admitDrawdown(s, rev, 500_000_00, 500_000_00, day0, false)) { case (#ok(_)) {}; case (r) fail("exactly the limit refused " # debug_show (r)) };
ignore apply(#drawn({ facility = rev; account = 900; amount = 500_000_00; rateBps = 1200; day = day0; splits = [] }));
ignore apply(#drawn({ facility = rev; account = 901; amount = 200_000_00; rateBps = 1200; day = day0 + 3; splits = [] }));
if (Core.facilityOfDrawing(s, 900) != ?rev or Core.facilityOfDrawing(s, 902) != null) fail("the drawing's facility");
if (Core.drawingsOf(s, rev) != [(900, true), (901, true)]) fail("drawings " # debug_show (Core.drawingsOf(s, rev)));
ignore apply(#drawingClosed({ facility = rev; account = 900; day = day0 + 40 }));
switch (Core.row(s, rev)) { case (?r) { if (r.drawings != 2 or r.openDrawings != 1) fail("drawing counts") }; case null fail("no row") };
ignore apply(#drawdownsBlocked({ facility = rev; reason = "breach"; day = day0 + 5 }));
switch (Core.admitDrawdown(s, rev, 1_00, 0, day0 + 5, false)) { case (#err(#Blocked(_))) {}; case (r) fail("blocked " # debug_show (r)) };
switch (Core.planUnblock(s, rev, "", day0 + 6)) { case (#err(#InvalidTerms(_))) {}; case (_) fail("an unblock without a reason") };
ignore apply(ok(Core.planUnblock(s, rev, "waiver", day0 + 6)));
if (Core.listByStage(s, #open, null, 10).ids != [rev]) fail("by stage after unblocking");
ignore apply(ok(Core.planCovenantTest(s, rev, [lev], "lev", 41_000, h("fs"), day0 + 7)));
switch (Core.planCovenantTest(s, rev, [lev], "nope", 1, h("fs"), day0 + 7)) { case (#err(#UnknownCovenant(_))) {}; case (_) fail("a covenant the facility never set") };
if (Core.covenantStatus(s, rev, "lev") != #breached) fail("the covenant status");
ignore apply(#cleanDownJudged({ facility = rev; windowEnd = day0 + 30; cleanDays = 2; required = 5; met = false }));
switch (Core.row(s, rev)) { case (?r) { if (r.cleanWindowStart != day0 + 30 or r.breaches != 1) fail("window start / breaches") }; case null fail("no row") };
ignore apply(#reviewOverdue({ facility = rev; due = day0 + 45; day = day0 + 46 }));
ignore apply(ok(Core.planReview(s, rev, "annual", day0 + 47)));
switch (Core.row(s, rev)) { case (?r) { if (r.reviewFlagged) fail("the review flag stays after a review") }; case null fail("no row") };
let bil = apply(#facilityOpened({ terms = base; day = day0 }));
ignore apply(#drawn({ facility = bil; account = 910; amount = 300_000_00; rateBps = 1300; day = day0; splits = [] }));
switch (Core.admitDrawdown(s, bil, 1_00, 300_000_00, day0, false)) { case (#err(#InvalidTerms(_))) {}; case (r) fail("a bilateral drawn twice " # debug_show (r)) };
switch (Core.planClose(s, bil, day0 + 1)) { case (#err(#HasDrawings(_))) {}; case (_) fail("closing with a drawing open") };
ignore apply(#drawingClosed({ facility = bil; account = 910; day = day0 + 100 }));
ignore apply(ok(Core.planClose(s, bil, day0 + 100)));
if (Core.listByStage(s, #closed, null, 10).ids != [bil]) fail("closed index");
Debug.print("count: revolver and bilateral acts through the planners and the fold = 22");

// ─── syndication: shares and a transfer ───────────────────────────────────────
let syn = apply(#facilityOpened({ terms = { base with kind = #syndicatedAgent({ shares; agentFeeBps = 25 }) }; day = day0 }));
if (Core.sharesOf(s, syn) != shares) fail("shares " # debug_show (Core.sharesOf(s, syn)));
switch (Core.planTransferParticipation(s, syn, 8, 9, 2001, 0)) { case (#err(#InvalidTerms(_))) {}; case (_) fail("a transfer above the share") };
switch (Core.planTransferParticipation(s, syn, 11, 9, 100, 0)) { case (#err(#UnknownParticipant(_))) {}; case (_) fail("a transfer from a stranger") };
switch (Core.planTransferParticipation(s, syn, 8, 8, 100, 0)) { case (#err(#InvalidTerms(_))) {}; case (_) fail("a transfer to oneself") };
ignore apply(ok(Core.planTransferParticipation(s, syn, 8, 9, 500, 12_345)));
if (Core.shareOf(s, syn, 8) != 1500 or Core.shareOf(s, syn, 9) != 2000) fail("shares after the transfer");
ignore apply(ok(Core.planTransferParticipation(s, syn, 10, 12, 2500, 1)));
if (Core.shareOf(s, syn, 10) != 0 or Core.shareOf(s, syn, 12) != 2500 or Core.sharesOf(s, syn).size() != 3) fail("a whole share moved to a newcomer");
Debug.print("count: syndicate share transfers folded = 2");

// ─── pricing: fixings and the rate in force ───────────────────────────────────
switch (Core.planRateFixing("", day0, 900)) { case (#err(#InvalidTerms(_))) {}; case (_) fail("a fixing without an index") };
ignore apply(ok(Core.planRateFixing("CBE-ON", day0, 900)));
ignore apply(ok(Core.planRateFixing("CBE-ON", day0 + 20, 1100)));
ignore apply(ok(Core.planRateFixing("EIBOR", day0 + 5, 500)));
if (Core.fixingOn(s, "CBE-ON", day0 - 1) != null or Core.fixingOn(s, "CBE-ON", day0) != ?900 or Core.fixingOn(s, "CBE-ON", day0 + 19) != ?900 or Core.fixingOn(s, "CBE-ON", day0 + 20) != ?1100 or Core.fixingOn(s, "CBE-ON", day0 + 99) != ?1100) fail("fixing in force");
if (Core.fixingOn(s, "EIBOR", day0 + 30) != ?500 or Core.fixingOn(s, "NOPE", day0 + 30) != null) fail("another index");
let flo = apply(#facilityOpened({ terms = { base with pricing = #floating({ index = "CBE-ON"; spreadBps = 250; resetDays = 20 }) }; day = day0 }));
switch (Core.row(s, flo)) {
  case (?r) {
    switch (Core.rateFor(s, r, day0 + 1)) { case (#ok(p)) { if (p.rateBps != 1150 or p.fixing != 900) fail("priced " # debug_show (p)) }; case (#err(e)) fail(debug_show (e)) };
    switch (Core.rateFor(s, r, day0 + 25)) { case (#ok(p)) { if (p.rateBps != 1350) fail("repriced") }; case (#err(e)) fail(debug_show (e)) };
    switch (Core.rateFor(s, { r with pricing = #floating({ index = "NOPE"; spreadBps = 1; resetDays = 1 }) }, day0)) { case (#err(#NoFixing(_))) {}; case (_) fail("a price with no fixing") };
  };
  case null fail("no row");
};
Debug.print("count: fixings and prices read = 9");

// ─── receivables: purchase, unwind, collection, dishonour, write-off ─────────
let fac = apply(#facilityOpened({ terms = { base with kind = #factoring({ advanceBps = 8000; discountBps = 300; recourse = false; clientAccount = 44 }) }; day = day0 }));
let r1 : FT.Receivable = { ref = h("inv-1"); debtorCommit = h("debtor"); face = 120_000_00; due = day0 + 60 };
let r2 : FT.Receivable = { ref = h("inv-2"); debtorCommit = h("debtor"); face = 50_000_00; due = day0 + 30 };
switch (Core.admitPurchase(s, fac, [{ r1 with due = day0 }], day0)) { case (#err(#InvalidTerms(_))) {}; case (_) fail("a receivable already due") };
switch (Core.admitPurchase(s, fac, [r1, r1], day0)) { case (#err(#InvalidTerms(_))) {}; case (_) fail("a receivable twice") };
switch (Core.admitPurchase(s, rev, [r1], day0)) { case (#err(#WrongKind(_))) {}; case (_) fail("a purchase on a revolver") };
ignore apply(#receivablesPurchased({ facility = fac; receivables = [r1, r2]; face = 170_000_00; advance = 136_000_00; discount = 5_100_00; retention = 28_900_00; day = day0 }));
switch (Core.admitPurchase(s, fac, [r1], day0 + 1)) { case (#err(#InvalidTerms(_))) {}; case (_) fail("a receivable bought twice") };
switch (Core.receivable(s, fac, r1.ref)) { case (?rr) { if (rr.advance != 96_000_00 or rr.discount != 3_600_00 or rr.retention != 20_400_00 or rr.status != #open or rr.purchased != day0) fail("r1 row " # debug_show (rr)) }; case null fail("no r1") };
ignore apply(#discountUnwound({ facility = fac; day = day0 + 1; amount = 11_000; items = [(r1.ref, 6_000), (r2.ref, 5_000)] }));
switch (Core.receivable(s, fac, r2.ref)) { case (?rr) { if (rr.recognised != 5_000) fail("recognised") }; case null fail("no r2") };
ignore apply(#receivableCollected({ facility = fac; ref = r2.ref; amount = 50_000_00; retentionReleased = 8_500_00; day = day0 + 30 }));
switch (Core.receivable(s, fac, r2.ref)) { case (?rr) { if (rr.status != #collected or rr.recognised != rr.discount) fail("collected row") }; case null fail("no r2") };
ignore apply(#receivableDishonoured({ facility = fac; ref = r1.ref; face = 120_000_00; chargedBack = false; day = day0 + 60 }));
switch (Core.row(s, fac)) { case (?r) { if (r.receivables != 2 or r.openReceivables != 1) fail("receivable counts after dishonour " # debug_show ((r.receivables, r.openReceivables))) }; case null fail("no row") };
ignore apply(#receivableWrittenOff({ facility = fac; ref = r1.ref; amount = 96_000_00; day = day0 + 90 }));
switch (Core.row(s, fac)) { case (?r) { if (r.openReceivables != 0) fail("open after write-off") }; case null fail("no row") };
if (Core.receivablesOf(s, fac).size() != 2) fail("receivables listed");
let forf = apply(#facilityOpened({ terms = { base with kind = #forfaiting({ discountBps = 500; clientAccount = 44 }) }; day = day0 }));
switch (Core.admitPurchase(s, forf, [r1, r2], day0)) { case (#err(#InvalidTerms(_))) {}; case (_) fail("two instruments on a forfaiting") };
ignore apply(#receivablesPurchased({ facility = forf; receivables = [r1]; face = 120_000_00; advance = 114_000_00; discount = 6_000_00; retention = 0; day = day0 }));
switch (Core.admitPurchase(s, forf, [r2], day0)) { case (#err(#InvalidTerms(_))) {}; case (_) fail("a second instrument") };
Debug.print("count: receivable acts through the gates and the fold = 12");

// ─── leases ───────────────────────────────────────────────────────────────────
let lease = apply(#facilityOpened({ terms = { base with kind = #financeLease({ assetAccount = "1500"; residual = 20_000_00 }) }; day = day0 }));
ignore apply(#residualRemeasured({ facility = lease; from = 20_000_00; to = 15_000_00; day = day0 + 10 }));
switch (Core.row(s, lease)) { case (?r) { switch (r.kind) { case (#financeLease(l)) { if (l.residual != 15_000_00) fail("residual folded") }; case (_) fail("kind") } }; case null fail("no row") };
let op = apply(#facilityOpened({ terms = { base with kind = #operatingLease({ rentalPerPeriod = 30_000_00; every = #monthly; periods = 12 }) }; day = day0 }));
ignore apply(#leaseRentalAccrued({ facility = op; day = day0 + 1; amount = 100_000 }));
switch (Core.row(s, op)) { case (?r) { if (r.lastAccrualDay != day0 + 1 or r.leaseStart != day0 + 1) fail("lease accrual folded") }; case null fail("no row") };
Debug.print("count: lease rows folded = 2");

// ─── indexes, counts, fingerprint ─────────────────────────────────────────────
if (Core.listByParty(s, 7, null, 20).ids.size() != 8) fail("by party " # debug_show (Core.listByParty(s, 7, null, 20).ids));
if (Core.openInBook(s, "HQ").size() != 7 or Core.openInBook(s, "BR01").size() != 0) fail("open in book");
// the fold's counters (S4.1) equal the walks
if (Core.openCountInBook(s, "HQ") != 7 or Core.openCountInBook(s, "BR01") != 0) fail("open count in book " # Nat.toText(Core.openCountInBook(s, "HQ")));
for (c in ["EGP", "USD", "XXX"].vals()) { if (Core.openInCurrency(s, c) != Core.openInCurrencyWalked(s, c)) fail("open in currency " # c # ": counter " # Nat.toText(Core.openInCurrency(s, c)) # " walk " # Nat.toText(Core.openInCurrencyWalked(s, c))) };
if (Core.openInCurrency(s, "EGP") == 0) fail("open in EGP counted");
Debug.print("count: facility counters held equal to a walk = 4");
let cs = Core.counts(s);
if (cs.facilities != 8 or cs.closed != 1 or cs.drawn != 3 or cs.fixings != 3) fail("counts " # debug_show (cs));
let dist = Core.kindDistribution(s);
func at(name : Text) : Nat { for ((n, c) in dist.vals()) { if (Text.equal(n, name)) return c }; 0 };
if (at("revolving") != 1 or at("bilateralTerm") != 2 or at("syndicatedAgent") != 1 or at("factoring") != 1 or at("forfaiting") != 1 or at("financeLease") != 1 or at("operatingLease") != 1) fail("distribution " # debug_show (dist));
let f1 = fp(s);
if (f1 != fp(s)) fail("fingerprint not deterministic");
ignore apply(ok(Core.planRateFixing("CBE-ON", day0 + 40, 1000)));
if (fp(s) == f1) fail("fingerprint did not change");
Debug.print("count: facilities folded = " # Nat.toText(cs.facilities));
Debug.print("FACILITY TEST GREEN");
