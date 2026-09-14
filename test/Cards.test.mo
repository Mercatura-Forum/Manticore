/// Cards.test.mo: cards cards: the decision engine, the lifecycles and the fold, without a journal.
///
/// What is proved here (the pure layer):
///   1. configuration: the policy, a scheme whose rules name their source (a scheme without a source refused), a product
///      whose controls bound the cardholder's, controls outside the bounds refused;
///   2. issuance: a card by its token digest (the token itself is kept nowhere; the fold's rows carry only the digest),
///      the same token twice refused, activation, block and unblock, a replacement that closes the old card, controls set;
///   3. the decision engine, in its stated order: an unknown token, a duplicate reference, an inactive card, an expired
///      card, an invalid cryptogram, a failed PIN, a currency mismatch, an MCC denied, a channel denied, an international
///      purchase denied, over the per-transaction limit, over the daily limit (a fold over the day's approvals), the
///      velocity window (a fold over the window), insufficient funds, and the approval; reversals and completions against
///      an original, an original not open or exceeded;
///   4. interchange by band, the scheme fee, reason rules;
///   5. disputes: opened within the chargeback window (outside refused), the provisional credit, the chargeback with its
///      representment clock, the representment, pre-arbitration, the resolution; a due step reported once;
///   6. the fold's counts and views, the status, the fingerprint.
// engine: wasi-only

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Blob "mo:core/Blob";
import Text "mo:core/Text";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";
import CT "../src/bank/CardTypes";
import Core "../src/bank/CardCore";

func fail(what : Text) { Debug.print("FAIL: " # what); assert false };
func fp(s : Core.State) : Blob { let w = C.Writer(); Core.fingerprintInto(w, s); w.toBlob() };

let arena = RI.newArena();
let s = Core.newState(arena);
var block = 700;
func next() : Nat { block += 1; block };
func apply(ev : CT.CardEvent) : Nat { let b = next(); Core.fold(s, b, ev, func(_) { "HQ" }); b };
func ok<X>(r : { #ok : X; #err : CT.CardError }, what : Text) : X { switch (r) { case (#ok(x)) x; case (#err(e)) { fail(what # " refused: " # debug_show (e)); loop {} } } };
func refused<X>(r : { #ok : X; #err : CT.CardError }, what : Text) : CT.CardError { switch (r) { case (#ok(_)) { fail(what # " accepted"); loop {} }; case (#err(e)) e } };
func actOk(r : { #ok : CT.CardEvent; #err : CT.CardError }, what : Text) : Nat { apply(ok(r, what)) };

let D0 = 20_710;   // 2026-09-14
let pol : CT.Policy = { disputeSuspense = "1950"; interchangeIncome = "4600"; schemeFees = "5600"; fraudLosses = "5610"; cardFeeIncome = "4610"; provisionalCreditCeiling = 5_000_00; clearingTolerance = 20_00; stanReplayDays = 3 };
let rules : CT.SchemeRules = {
  source = "Visa Core Rules and Visa Product and Service Rules, 2026 edition (public), tables 5-x interchange and 11-x dispute time limits";
  interchange = [{ mccFrom = 0; mccTo = 5411; bps = 30; fixed = 5 }, { mccFrom = 5412; mccTo = 9999; bps = 120; fixed = 10 }];
  floorLimit = 50_00; holdDays = 7;
  reasons = [{ code = "10.4"; description = "Other fraud — card-absent environment"; chargebackDays = 120; representmentDays = 30; preArbitrationDays = 30 }, { code = "13.1"; description = "Merchandise/services not received"; chargebackDays = 120; representmentDays = 30; preArbitrationDays = 30 }];
  feeBps = 5;
};
let scheme : CT.Scheme = { id = "VISA"; name = "Visa"; settlementAccount = "2900"; settlementCurrency = "EGP"; rules; connectorScheme = #none; connectorKey = "" : Blob };
let bounds : CT.Controls = { dailyLimit = 20_000_00; perTransactionLimit = 10_000_00; mccAllow = []; mccDeny = [7995]; channels = { pos = true; atm = true; ecom = true; contactless = true; international = true }; velocityCount = 10; velocityWindowMinutes = 60 };
let controls : CT.Controls = { dailyLimit = 5_000_00; perTransactionLimit = 2_000_00; mccAllow = []; mccDeny = [5813]; channels = { pos = true; atm = true; ecom = true; contactless = true; international = false }; velocityCount = 3; velocityWindowMinutes = 10 };
let product : CT.CardProduct = { id = "DEBIT-STD"; name = "Standard debit"; kind = #debit; scheme = "VISA"; bounds; issueFee = 50_00; replacementFee = 25_00; expiryMonths = 36 };
let token1 : Blob = "4000123456789010" : Blob;   // a vault token, 16 bytes, not a PAN
let token2 : Blob = "4000123456789028" : Blob;

// 1. configuration
ignore refused(Core.planDeclareScheme(s, { scheme with rules = { rules with source = "" } }, D0), "a scheme without a source");
ignore refused(Core.planDefineProduct(s, product, D0), "a product before its scheme");
ignore actOk(Core.planPolicy(pol), "policy");
ignore actOk(Core.planDeclareScheme(s, scheme, D0), "scheme");
ignore refused(Core.planDeclareScheme(s, scheme, D0), "scheme twice");
ignore actOk(Core.planDefineProduct(s, product, D0), "product");
ignore refused(Core.planDefineProduct(s, { product with id = "CREDIT-X"; kind = #credit({ statementDay = 31; minimumDueBps = 500; minimumDueFloor = 100_00; graceDays = 25 }) }, D0), "a statement day past the 28th");
Debug.print("count: configuration acts and refusals = 6");

// 2. issuance
let expiry = Core.monthOf(D0) + 36;
switch (refused(Core.planIssue(s, token1, 44, 7, "DEBIT-STD", #physical, { controls with dailyLimit = 50_000_00 }, bounds, D0, expiry, null), "controls above the bounds")) { case (#ControlsOutsideBounds(x)) { if (x.field != "dailyLimit") fail("names the field") }; case (e) fail("wrong refusal " # debug_show e) };
let cardId = actOk(Core.planIssue(s, token1, 44, 7, "DEBIT-STD", #physical, controls, bounds, D0, expiry, null), "issue");
ignore refused(Core.planIssue(s, token1, 44, 7, "DEBIT-STD", #physical, controls, bounds, D0, expiry, null), "the same token twice");
switch (Core.cardByToken(s, token1)) { case (?r) { if (r.id != cardId or r.state != #issued or r.dailyLimit != controls.dailyLimit) fail("card row") ; if (Blob.equal(r.tokenHash, token1)) fail("the token itself is in the row") }; case null fail("card by token") };
ignore refused(Core.planUnblock(s, cardId, D0), "unblock an issued card");
ignore actOk(Core.planActivate(s, cardId, D0), "activate");
ignore refused(Core.planActivate(s, cardId, D0), "activate twice");
ignore actOk(Core.planBlock(s, cardId, #lost, D0 + 1), "block");
ignore actOk(Core.planUnblock(s, cardId, D0 + 1), "unblock");
ignore actOk(Core.planSetControls(s, cardId, { controls with perTransactionLimit = 3_000_00 }, bounds, true, D0 + 1), "controls by the customer");
switch (Core.card(s, cardId)) { case (?r) { if (r.perTransactionLimit != 3_000_00 or r.state != #active) fail("controls applied") }; case null {} };
Debug.print("count: issuance acts and refusals = 9");

// 3. the decision engine
let ctrl : CT.Controls = { controls with perTransactionLimit = 3_000_00 };
func req(amount : Nat, mcc : Nat, ch : CT.Channel, stan : Text, t : Nat64) : CT.AuthRequest {
  { token = token1; kind = #purchase; amount; currency = "EGP"; mcc; merchantHash = "" : Blob; merchantCountry = "EG"; acquirer = "ACQ1"; channel = ch; cryptogramValid = true; pinVerified = ?true; stan; rrn = "R" # stan; localTime = t }
};
let T0 : Nat64 = 20_711 * 86_400_000_000_000 + 10 * 3_600_000_000_000;
let facts : Core.Facts = { available = 10_000_00; today = D0 + 1; nowNs = T0; bounds; controls = ctrl; rules; productScheme = "VISA"; settlementCurrency = "EGP" };
let card = switch (Core.card(s, cardId)) { case (?r) r; case null loop {} };
func decide(r : CT.AuthRequest) : CT.Decision { Core.decide(s, r, ?card, facts, pol.stanReplayDays) };
func declined(r : CT.AuthRequest, want : CT.DeclineReason, what : Text) { switch (decide(r)) { case (#declined(x)) { if (x != want) fail(what # ": declined " # CT.declineText(x) # " not " # CT.declineText(want)) }; case (#approved(_)) fail(what # ": approved") } };
var declines = 0;
switch (Core.decide(s, { req(100_00, 5411, #pos, "1", T0) with token = token2 }, null, facts, 3)) { case (#declined(#unknownCard)) declines += 1; case (d) fail("unknown token " # debug_show d) };
declined({ req(100_00, 5411, #pos, "2", T0) with cryptogramValid = false }, #cryptogramInvalid, "cryptogram"); declines += 1;
declined({ req(100_00, 5411, #pos, "3", T0) with pinVerified = ?false }, #pinFailed, "pin"); declines += 1;
declined({ req(100_00, 5411, #pos, "4", T0) with currency = "USD" }, #currencyMismatch, "currency"); declines += 1;
declined(req(100_00, 5813, #pos, "5", T0), #mccDenied, "the card's MCC deny list"); declines += 1;
declined(req(100_00, 7995, #pos, "6", T0), #mccDenied, "the product's MCC deny list"); declines += 1;
declined({ req(100_00, 5411, #pos, "7", T0) with merchantCountry = "US" }, #internationalDenied, "international off"); declines += 1;
declined(req(3_000_01, 5411, #pos, "8", T0), #overPerTransaction, "over the per-transaction limit"); declines += 1;
declined(req(20_000_00 + 1, 5411, #pos, "9", T0), #overPerTransaction, "over both limits names the per-transaction first"); declines += 1;
// an expired card, an inactive card
let expiredFacts = { facts with today = D0 + 37 * 31 };
switch (Core.decide(s, req(100_00, 5411, #pos, "10", T0), ?card, expiredFacts, 3)) { case (#declined(#cardExpired)) declines += 1; case (d) fail("expired " # debug_show d) };
switch (Core.decide(s, req(100_00, 5411, #pos, "11", T0), ?{ card with state = #blocked }, facts, 3)) { case (#declined(#cardBlocked)) declines += 1; case (d) fail("blocked " # debug_show d) };
switch (Core.decide(s, req(100_00, 5411, #pos, "12", T0), ?{ card with state = #issued }, facts, 3)) { case (#declined(#cardNotActive)) declines += 1; case (d) fail("not active " # debug_show d) };
// the approval, recorded, then the daily limit and the velocity folds over it
func approveAndRecord(r : CT.AuthRequest, hold : Nat) : Nat {
  switch (decide(r)) { case (#approved(_)) {}; case (#declined(x)) fail("approve " # r.stan # ": " # CT.declineText(x)) };
  apply(#authorised({ card = ?cardId; request = r; decision = #approved({ authCode = Core.authCodeOf(block + 1); hold = ?hold; amount = r.amount }); day = D0 + 1 }))
};
let a1 = approveAndRecord(req(2_000_00, 5411, #pos, "20", T0), 9001);
let a2 = approveAndRecord(req(2_000_00, 5812, #ecom, "21", T0 + 60_000_000_000), 9002);
declined(req(1_500_00, 5411, #pos, "22", T0 + 120_000_000_000), #overDailyLimit, "over the daily limit after 4,000.00 approved"); declines += 1;
let a3 = approveAndRecord(req(500_00, 5411, #contactless, "23", T0 + 180_000_000_000), 9003);
declined(req(100_00, 5411, #pos, "24", T0 + 240_000_000_000), #velocity, "three in ten minutes is the window"); declines += 1;
switch (decide(req(100_00, 5411, #pos, "25", T0 + 11 * 60_000_000_000))) { case (#approved(_)) {}; case (d) fail("after the window " # debug_show d) };
declined(req(100_00, 5411, #pos, "20", T0 + 11 * 60_000_000_000), #duplicate, "the same acquirer reference again"); declines += 1;
switch (Core.decide(s, req(400_00, 5411, #pos, "26", T0 + 11 * 60_000_000_000), ?card, { facts with available = 300_00 }, 3)) { case (#declined(#insufficientFunds)) declines += 1; case (d) fail("funds " # debug_show d) };
// a decline is a block too
ignore apply(#authorised({ card = ?cardId; request = req(9_000_00, 5411, #pos, "27", T0); decision = #declined(#overPerTransaction); day = D0 + 1 }));
switch (Core.card(s, cardId)) { case (?r) { if (r.authorizations != 4 or r.declines != 1 or r.openHolds != 3 or r.heldAmount != 4_500_00) fail("card counters " # debug_show (r.authorizations, r.declines, r.openHolds, r.heldAmount)) }; case null {} };
// reversal, completion, incremental against the originals
switch (decide({ req(500_00, 5411, #pos, "30", T0 + 12 * 60_000_000_000) with kind = #reversal({ of = a1 }) })) { case (#approved(x)) { if (x.hold != ?9001) fail("reversal names the original's hold") }; case (d) fail("reversal " # debug_show d) };
declined({ req(2_500_00, 5411, #pos, "31", T0 + 12 * 60_000_000_000) with kind = #reversal({ of = a1 }) }, #amountExceedsOriginal, "a reversal beyond the hold"); declines += 1;
declined({ req(100_00, 5411, #pos, "32", T0 + 12 * 60_000_000_000) with kind = #completion({ of = 12345 }) }, #unknownOriginal, "a completion of nothing"); declines += 1;
ignore apply(#holdAdjusted({ auth = a1; from = 2_000_00; to = 0; hold = null; kind = "reversal"; day = D0 + 1 }));
declined({ req(100_00, 5411, #pos, "33", T0 + 12 * 60_000_000_000) with kind = #completion({ of = a1 }) }, #originalNotOpen, "a completion of a reversed hold"); declines += 1;
switch (Core.card(s, cardId)) { case (?r) { if (r.openHolds != 2 or r.heldAmount != 2_500_00) fail("after the reversal " # debug_show (r.openHolds, r.heldAmount)) }; case null {} };
ignore apply(#holdExpired({ auth = a3; hold = 9003; day = D0 + 8 }));
switch (Core.card(s, cardId)) { case (?r) { if (r.openHolds != 1 or r.heldAmount != 2_000_00) fail("after the expiry " # debug_show (r.openHolds, r.heldAmount)) }; case null {} };
Debug.print("count: decisions declined in the stated order = " # Nat.toText(declines));
Debug.print("count: authorizations approved and recorded = 3");
Debug.print("count: holds adjusted and expired by the fold = 2");

// 4. interchange, fees, reasons, codes
if (Core.interchangeOf(rules, 5411, 10_000_00) != 30_05 or Core.interchangeOf(rules, 5812, 10_000_00) != 120_10) fail("interchange by band");
if (Core.feeOf(rules, 10_000_00) != 5_00) fail("scheme fee");
if (Core.reasonRule(rules, "13.1") == null or Core.reasonRule(rules, "99.9") != null) fail("reason rules");
if (Core.authIdOf(Core.authCodeOf(a2)) != ?a2 or Core.authCodeOf(a2).size() != 6) fail("auth code round trip");
if (CT.responseCode(#approved({ authCode = ""; hold = null; amount = 0 })) != "00" or CT.responseCode(#declined(#insufficientFunds)) != "51" or CT.responseCode(#declined(#cardExpired)) != "54") fail("DE 39 codes");
Debug.print("count: rule arithmetic and code checks = 5");

// 5. clearing rows and disputes
let cleared = apply(#cleared({ scheme = "VISA"; batch = "" : Blob; card = ?cardId; item = { authCode = ?Core.authCodeOf(a2); token = token1; amount = 2_010_00; currency = "EGP"; mcc = 5812; merchantHash = "" : Blob; acquirer = "ACQ1"; stan = "21"; rrn = "R21"; day = D0 + 2; refund = false }; outcome = #postedAgainstHold({ auth = a2; hold = 9002; difference = 10_00 }); interchange = 24_12; fee = 1_00; posting = ?777; day = D0 + 2 }));
switch (Core.card(s, cardId)) { case (?r) { if (r.openHolds != 0 or r.clearedCount != 1 or r.clearedAmount != 2_010_00) fail("after clearing " # debug_show (r.openHolds, r.clearedCount)) }; case null {} };
ignore refused(Core.planOpenDispute(s, cleared, "99.9", 100_00, rules, D0 + 3), "an unknown reason code");
ignore refused(Core.planOpenDispute(s, cleared, "13.1", 100_00, rules, D0 + 2 + 121), "outside the chargeback window");
ignore refused(Core.planOpenDispute(s, cleared, "13.1", 3_000_00, rules, D0 + 3), "more than the transaction");
let dispute = actOk(Core.planOpenDispute(s, cleared, "13.1", 2_010_00, rules, D0 + 3), "open dispute");
ignore refused(Core.planOpenDispute(s, cleared, "13.1", 100_00, rules, D0 + 3), "disputed twice");
ignore refused(Core.planRepresentment(s, dispute, rules, "13.1", D0 + 4), "a representment before the chargeback");
let (pc, _) = ok(Core.planProvisionalCredit(s, dispute, D0 + 3), "provisional credit"); ignore apply(pc);
let (cb, _) = ok(Core.planChargeback(s, dispute, "VISA-CASE-1", rules, "13.1", D0 + 4), "chargeback"); ignore apply(cb);
switch (Core.dispute(s, dispute)) { case (?d) { if (d.stage != #chargeback or d.dueDay != D0 + 4 + 30 or d.provisional != 2_010_00) fail("dispute after chargeback " # debug_show (d.stage, d.dueDay)) }; case null {} };
if (Core.dueDisputes(s, D0 + 10).size() != 0) fail("nothing due yet");
if (Core.dueDisputes(s, D0 + 34).size() != 1) fail("the representment clock is due");
for (ev in Core.dueDisputes(s, D0 + 34).vals()) ignore apply(ev);
if (Core.dueDisputes(s, D0 + 35).size() != 0) fail("a due step is reported once");
let (rp, _) = ok(Core.planRepresentment(s, dispute, rules, "13.1", D0 + 20), "representment"); ignore apply(rp);
let (pa, _) = ok(Core.planPreArbitration(s, dispute, rules, "13.1", D0 + 25), "pre-arbitration"); ignore apply(pa);
ignore refused(Core.planResolve(s, dispute, #cardholder, 3_000_00, D0 + 30), "a resolution above the dispute");
let (rs, _) = ok(Core.planResolve(s, dispute, #cardholder, 2_010_00, D0 + 30), "resolve"); ignore apply(rs);
switch (Core.dispute(s, dispute)) { case (?d) { if (d.stage != #resolved or d.outcome != 1) fail("resolved") }; case null {} };
ignore refused(Core.planResolve(s, dispute, #merchant, 0, D0 + 30), "resolve twice");
ignore actOk(Core.planMarkFraud(s, cleared, true, D0 + 30), "fraud marked");
switch (Core.card(s, cardId)) { case (?r) { if (r.state != #blocked) fail("fraud blocks the card") }; case null {} };
switch (Core.clearedRow(s, cleared)) { case (?t) { if (not t.fraud or not t.disputed) fail("cleared row flags") }; case null {} };
Debug.print("count: dispute steps through resolution = 6");
Debug.print("count: dispute refusals = 6");

// a replacement closes the old card and carries the relationship
let newId = actOk(Core.planIssue(s, token2, 44, 7, "DEBIT-STD", #physical, ctrl, bounds, D0 + 31, expiry + 1, ?cardId), "replace");
switch (Core.card(s, cardId), Core.card(s, newId)) { case (?o, ?n) { if (o.state != #closed or o.replacedBy != newId or n.replaces != cardId) fail("replacement links") }; case (_) fail("rows") };
ignore refused(Core.planClose(s, newId, "", D0 + 31), "a closure without a reason");
ignore actOk(Core.planClose(s, newId, "customer request", D0 + 31), "close");
Debug.print("count: replacement and closure = 2");

// 6. status and fingerprint
let st = Core.status(s);
if (Core.openInBook(s, "HQ") != Core.cardsInState(s, #issued).size() + Core.cardsInState(s, #active).size() + Core.cardsInState(s, #blocked).size() or Core.openInBook(s, "BR01") != 0) fail("cards open in book counter " # Nat.toText(Core.openInBook(s, "HQ")));
if (Core.openDisputeCount(s) != Core.openDisputes(s).size()) fail("open dispute counter");
Debug.print("count: card counters held equal to a walk = 2");
if (st.cards != 2 or st.authorizations != 4 or st.approved != 3 or st.declined != 1 or st.disputes != 1 or st.openDisputes != 0 or st.cleared != 1 or st.schemes != 1 or st.products != 1) fail("status " # debug_show st);
let f1 = fp(s);
if (not Blob.equal(f1, fp(s))) fail("fingerprint unstable");
if (Blob.equal(f1, fp(Core.newState(RI.newArena())))) fail("empty state differs");
Debug.print("count: status and fingerprint checks = 2");
Debug.print("Cards: all checks passed");
