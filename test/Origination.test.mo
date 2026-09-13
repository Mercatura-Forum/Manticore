// Origination.test.mo — an application for credit as the bank records it (origination and underwriting), on the pure core over a
// real stable-memory arena.
//
// What is proved:
//
//   * the models' gates (a policy, an affordability model, a scorecard refused where malformed; a version that
//     does not follow refused);
//   * the affordability rules and the scorecard as pure functions over recorded facts — the same functions the
//     Python oracle of bank_s32.py writes again — over a table of cases;
//   * the WebAuthn assertion verifier against vectors from an independent implementation (Python cryptography):
//     the valid assertion accepted, and every refusal named — wrong challenge, wrong origin, wrong relying
//     party, user not present, tampered signature, another key, an unknown credential, the wrong ceremony;
//   * the life of an application through the planners and the fold: every act refused where its stage forbids
//     it, the decision against the band needing a rationale, the offer bound to the approval, the documentation
//     completing, the drawing; a prospect's application gaining its party at onboarding; decline, withdrawal,
//     expiry; the indexes by stage, party and account; the fingerprint deterministic and changing.
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
import OT "../src/bank/OriginationTypes";
import Core "../src/bank/OriginationCore";
import V "OriginationVectors";

func fail(what : Text) { Debug.print("FAIL: " # what); assert false };
func fp(s : Core.State) : Blob { let w = C.Writer(); Core.fingerprintInto(w, s); w.toBlob() };
func h(t : Text) : Blob { Sha256.fromBlob(#sha256, Text.encodeUtf8(t)) };

let arena = RI.newArena();
let s = Core.newState(arena);
var block = 100;
func next() : Nat { block += 1; block };
func apply(ev : OT.OriginationEvent) : Nat { let b = next(); Core.apply(s, b, ev); b };
func plan(r : Core.Planned) : OT.OriginationEvent { switch (r) { case (#ok(ev)) ev; case (#err(e)) { fail("refused: " # debug_show (e)); loop {} } } };
func act(r : Core.Planned) : Nat { apply(plan(r)) };

let policy : OT.Policy = { rpId = V.RP_ID; origin = V.ORIGIN; offerValidityDays = 14; bureaus = [("I-SCORE", #none, ""), ("PQ-BUREAU", #mldsa44, "\01\02")] };
let model : OT.AffordabilityModel = {
  id = "retail-v1"; version = 1;
  rules = [
    { id = "dsr-45"; kind = #maxDebtServiceRatioBps(4500); onFail = #fail },
    { id = "residual-2500"; kind = #minResidualIncome(2_500_00); onFail = #fail },
    { id = "term-60m"; kind = #maxTermDays(1826); onFail = #fail },
    { id = "amount-500k"; kind = #maxAmount(500_000_00); onFail = #refer },
    { id = "income-3000"; kind = #minIncome(3_000_00); onFail = #refer },
  ];
};
let card : OT.Scorecard = {
  id = "retail-card"; version = 1;
  attributes = [
    (#income, [{ lo = 0; hi = ?4_999_99; points = 10 }, { lo = 5_000_00; hi = ?14_999_99; points = 25 }, { lo = 15_000_00; hi = null; points = 40 }]),
    (#obligationsRatioBps, [{ lo = 0; hi = ?2000; points = 30 }, { lo = 2001; hi = ?4000; points = 15 }, { lo = 4001; hi = null; points = 0 }]),
    (#bureauScore, [{ lo = 0; hi = ?499; points = 0 }, { lo = 500; hi = ?699; points = 20 }, { lo = 700; hi = null; points = 35 }]),
    (#bureauFlags, [{ lo = 0; hi = ?0; points = 10 }, { lo = 1; hi = null; points = 0 }]),
    (#termDays, [{ lo = 0; hi = ?365; points = 10 }, { lo = 366; hi = null; points = 5 }]),
  ];
  declineBelow = 50; referBelow = 80;
};
let request : OT.Request = { product = "PL-STD"; amount = 120_000_00; currency = "EGP"; termDays = 730; purpose = "car" };

// ─── the models' gates ────────────────────────────────────────────────────────
switch (Core.planPolicy({ policy with rpId = "" })) { case (#err(#InvalidModel(_))) {}; case (_) fail("a policy without a relying party accepted") };
switch (Core.planPolicy({ policy with offerValidityDays = 0 })) { case (#err(#InvalidModel(_))) {}; case (_) fail("a zero offer validity accepted") };
switch (Core.planPolicy({ policy with bureaus = [("A", #none, ""), ("A", #none, "")] })) { case (#err(#InvalidModel(_))) {}; case (_) fail("a bureau listed twice accepted") };
switch (Core.planPolicy({ policy with bureaus = [("A", #mldsa44, "")] })) { case (#err(#InvalidModel(_))) {}; case (_) fail("a signing bureau without a key accepted") };
switch (Core.planAffordabilityModel(s, { model with rules = [] })) { case (#err(#InvalidModel(_))) {}; case (_) fail("a model without rules accepted") };
switch (Core.planAffordabilityModel(s, { model with rules = [{ id = "x"; kind = #maxDebtServiceRatioBps(0); onFail = #fail }] })) { case (#err(#InvalidModel(_))) {}; case (_) fail("a zero ratio accepted") };
switch (Core.planAffordabilityModel(s, { model with rules = [model.rules[0], model.rules[0]] })) { case (#err(#InvalidModel(_))) {}; case (_) fail("a rule listed twice accepted") };
switch (Core.planScorecard(s, { card with declineBelow = 90 })) { case (#err(#InvalidModel(_))) {}; case (_) fail("decline above refer accepted") };
switch (Core.planScorecard(s, { card with attributes = [(#income, [])] })) { case (#err(#InvalidModel(_))) {}; case (_) fail("an attribute without bands accepted") };
switch (Core.planScorecard(s, { card with attributes = [(#income, [{ lo = 10; hi = ?5; points = 1 }])] })) { case (#err(#InvalidModel(_))) {}; case (_) fail("an inverted band accepted") };
ignore act(Core.planPolicy(policy));
ignore act(Core.planAffordabilityModel(s, model));
ignore act(Core.planScorecard(s, card));
switch (Core.planAffordabilityModel(s, model)) { case (#err(#InvalidModel(_))) {}; case (_) fail("the same model version set twice") };
switch (Core.planScorecard(s, { card with version = 0 })) { case (#err(#InvalidModel(_))) {}; case (_) fail("a scorecard version going backwards accepted") };
Debug.print("count: model gates held = 13");

// ─── the affordability rules, case by case ────────────────────────────────────
type Case = { facts : OT.Facts; req : OT.Request; want : OT.Verdict };
let cases : [Case] = [
  { facts = { income = 20_000_00; obligations = 2_000_00; proposedInstalment = 5_000_00; dependants = 2 }; req = request; want = #pass },
  // 45% of 10,000 is 4,500: obligations 2,000 + instalment 3,000 = 5,000 fires the ratio, and the residual of 5,000 for three heads (7,500) fires too
  { facts = { income = 10_000_00; obligations = 2_000_00; proposedInstalment = 3_000_00; dependants = 2 }; req = request; want = #fail(["dsr-45", "residual-2500"]) },
  // exactly at the ratio does not fire; residual 5,500 ≥ 2 heads × 2,500
  { facts = { income = 10_000_00; obligations = 1_500_00; proposedInstalment = 3_000_00; dependants = 1 }; req = request; want = #pass },
  // a long term fails; a large amount only refers, but fail wins
  { facts = { income = 50_000_00; obligations = 0; proposedInstalment = 9_000_00; dependants = 0 }; req = { request with termDays = 2000; amount = 900_000_00 }; want = #fail(["term-60m"]) },
  // a large amount alone refers
  { facts = { income = 50_000_00; obligations = 0; proposedInstalment = 9_000_00; dependants = 0 }; req = { request with amount = 900_000_00 }; want = #refer(["amount-500k"]) },
  // income below the floor refers; with an instalment larger than the income the ratio and residual fail first
  { facts = { income = 2_800_00; obligations = 0; proposedInstalment = 100_00; dependants = 0 }; req = request; want = #refer(["income-3000"]) },
  { facts = { income = 2_800_00; obligations = 0; proposedInstalment = 3_000_00; dependants = 0 }; req = request; want = #fail(["dsr-45", "residual-2500"]) },
  // no income at all: the ratio fires on any commitment, the residual on any dependant
  { facts = { income = 0; obligations = 0; proposedInstalment = 1; dependants = 0 }; req = request; want = #fail(["dsr-45", "residual-2500"]) },
  { facts = { income = 0; obligations = 0; proposedInstalment = 0; dependants = 0 }; req = request; want = #fail(["residual-2500"]) },
];
var ruleCases = 0;
for (c in cases.vals()) {
  let got = Core.assess(model, c.facts, c.req);
  if (got != c.want) fail("assess " # debug_show (c.facts) # " gave " # debug_show (got) # " wanted " # debug_show (c.want));
  ruleCases += 1;
};
Debug.print("count: affordability cases equal to the hand-worked verdict = " # Nat.toText(ruleCases));

// ─── the scorecard ────────────────────────────────────────────────────────────
// income 20,000 (40) + ratio 1000 bps (30) + bureau 720 (35) + no flags (10) + term 730 (5) = 120: approve
let f1 : OT.Facts = { income = 20_000_00; obligations = 2_000_00; proposedInstalment = 5_000_00; dependants = 2 };
switch (Core.score(card, f1, request, ?{ score = 720; flags = 0 })) { case ((120, #approve)) {}; case (x) fail("score 1 " # debug_show (x)) };
// without a bureau report the bureau attributes score nothing: 40 + 30 + 5 = 75: refer
switch (Core.score(card, f1, request, null)) { case ((75, #refer)) {}; case (x) fail("score 2 " # debug_show (x)) };
// income 4,000 (10) + ratio 7500 bps (0) + bureau 480 (0) + 2 flags (0) + term 300 (10) = 20: decline
let f2 : OT.Facts = { income = 4_000_00; obligations = 3_000_00; proposedInstalment = 500_00; dependants = 0 };
switch (Core.score(card, f2, { request with termDays = 300 }, ?{ score = 480; flags = 2 })) { case ((20, #decline)) {}; case (x) fail("score 3 " # debug_show (x)) };
// zero income: the ratio is the largest value, held only by the unbounded top band
switch (Core.attributeValue(#obligationsRatioBps, { f2 with income = 0 }, request, null)) { case (?v) { if (Core.bandPoints(card.attributes[1].1, v) != 0) fail("zero income ratio band") }; case null fail("no ratio") };
// a value no band holds scores nothing
if (Core.bandPoints([{ lo = 10; hi = ?20; points = 7 }], 21) != 0) fail("a value past every band scored");
if (Core.bandPoints([{ lo = 10; hi = ?20; points = 7 }], 20) != 7) fail("the top of a band is inclusive");
// the cut-offs are read as strict lower bounds of the band above
switch (Core.score({ card with declineBelow = 121 }, f1, request, ?{ score = 720; flags = 0 })) { case ((120, #decline)) {}; case (x) fail("cut-off " # debug_show (x)) };
Debug.print("count: scorecard cases = 7");
if (not Core.departsFromBand(#approve({ amount = 1; termDays = 1; rateBps = 1; conditions = [] }), #decline)) fail("approve against decline not an override");
if (Core.departsFromBand(#approve({ amount = 1; termDays = 1; rateBps = 1; conditions = [] }), #refer)) fail("approve on refer is not an override");
if (not Core.departsFromBand(#decline({ reasons = ["x"] }), #approve)) fail("decline against approve not an override");

// ─── passkeys and the assertion verifier ──────────────────────────────────────
let party = 7;
switch (Core.planRegisterPasskey(s, party, V.CREDENTIAL, "\30\59")) { case (#err(#InvalidRequest(_))) {}; case (_) fail("a malformed key registered") };
switch (Core.planRegisterPasskey(s, party, "", V.SPKI)) { case (#err(#InvalidRequest(_))) {}; case (_) fail("an empty credential registered") };
ignore act(Core.planRegisterPasskey(s, party, V.CREDENTIAL, V.SPKI));
switch (Core.planRegisterPasskey(s, party, V.CREDENTIAL, V.SPKI)) { case (#err(#PasskeyExists(_))) {}; case (_) fail("a passkey registered twice") };
if (Core.passkey(s, party, V.CREDENTIAL) != ?V.SPKI) fail("the passkey row");
if (Core.passkey(s, party + 1, V.CREDENTIAL) != null) fail("a passkey found under another party");
var assertions = 0;
for ((name, cred, ad, cd, sig, want) in V.ASSERTIONS.vals()) {
  let a : OT.PasskeyAssertion = { credentialId = cred; authenticatorData = ad; clientDataJSON = cd; signature = sig };
  switch (Core.verifyAssertion(s, party, V.CHALLENGE, a), want) {
    case (#ok(_), true) {};
    case (#err(_), false) {};
    case (r, _) fail("assertion '" # name # "' gave " # debug_show (r) # " wanted verifies=" # debug_show (want));
  };
  assertions += 1;
};
// the refusals name their reason
let valid = V.ASSERTIONS[0];
let good : OT.PasskeyAssertion = { credentialId = valid.1; authenticatorData = valid.2; clientDataJSON = valid.3; signature = valid.4 };
switch (Core.verifyAssertion(s, party, h("other"), good)) { case (#err(#AssertionRefused(x))) { if (not Text.contains(x.reason, #text "challenge")) fail("reason " # x.reason) }; case (r) fail("another challenge accepted " # debug_show (r)) };
switch (Core.verifyAssertion(s, party + 1, V.CHALLENGE, good)) { case (#err(#UnknownPasskey(_))) {}; case (r) fail("another party's assertion " # debug_show (r)) };
Debug.print("count: WebAuthn assertion vectors judged as the independent implementation says = " # Nat.toText(assertions));

// ─── the life of an application ───────────────────────────────────────────────
let day0 = 20_700;
switch (Core.planOpen(?party, "HQ", { request with amount = 0 }, "branch", day0)) { case (#err(#InvalidRequest(_))) {}; case (_) fail("an application for nothing opened") };
let app = act(Core.planOpen(?party, "HQ", request, "branch", day0));
switch (Core.view(s, app)) { case (?v) { if (v.stage != #capture or v.party != ?party or v.amount != request.amount or v.openedBlock != app) fail("the opened view") }; case null fail("no row") };
switch (Core.planAssess(s, app)) { case (#err(#InvalidRequest(_))) {}; case (_) fail("assessed without facts") };
switch (Core.planScore(s, app)) { case (#err(#WrongStage(_))) {}; case (_) fail("scored at capture") };
switch (Core.planUnderwrite(s, app, #decline({ reasons = ["x"] }), "")) { case (#err(#WrongStage(_))) {}; case (_) fail("underwritten at capture") };
switch (Core.planRecordData(s, app, f1, [("employer", "\00")])) { case (#err(#InvalidRequest(_))) {}; case (_) fail("a short commitment accepted") };
ignore act(Core.planRecordData(s, app, f1, [("employer", h("acme")), ("address", h("12 nile st"))]));
// the bureau: requested before recorded, only a policy bureau, only with a verifying signature
switch (Core.planRequestBureau(s, app, "NOBODY", h("consent"), day0)) { case (#err(#UnknownBureau(_))) {}; case (_) fail("an unknown bureau asked") };
let report : OT.BureauReport = { bureau = "I-SCORE"; score = 720; flags = []; reportHash = h("report body"); reportedOn = day0 };
func verifyNone(scheme : { #none; #mayo2; #mldsa44 }, _key : Blob, _msg : Blob, sig : Blob) : Bool { scheme == #none and sig.size() == 0 };
switch (Core.planRecordBureau(s, app, report, "", verifyNone)) { case (#err(#BureauNotRequested(_))) {}; case (_) fail("a report recorded before it was requested") };
ignore act(Core.planRequestBureau(s, app, "I-SCORE", h("consent"), day0));
switch (Core.planRecordBureau(s, app, { report with bureau = "PQ-BUREAU" }, "\ff", verifyNone)) { case (#err(#SignatureInvalid(_))) {}; case (_) fail("a report whose signature fails recorded") };
ignore act(Core.planRecordBureau(s, app, report, "", verifyNone));
let assessed = plan(Core.planAssess(s, app));
switch (assessed) { case (#affordabilityAssessed(x)) { if (x.verdict != #pass or x.version != 1 or not Text.equal(x.model, "retail-v1")) fail("the assessment " # debug_show (x)) }; case (_) fail("not an assessment") };
ignore apply(assessed);
switch (Core.planAssess(s, app)) { case (#err(#WrongStage(_))) {}; case (_) fail("assessed twice") };
let scored = plan(Core.planScore(s, app));
switch (scored) { case (#scored(x)) { if (x.points != 120 or x.band != #approve) fail("the score " # debug_show (x)) }; case (_) fail("not a score") };
ignore apply(scored);
// underwriting: within the request, against a failed affordability never, against the band only with a rationale
switch (Core.planUnderwrite(s, app, #approve({ amount = request.amount + 1; termDays = 730; rateBps = 1800; conditions = [] }), "")) { case (#err(#InvalidRequest(_))) {}; case (_) fail("an approval above the request") };
switch (Core.planUnderwrite(s, app, #decline({ reasons = ["policy"] }), "")) { case (#err(#DecisionAgainstBand(_))) {}; case (_) fail("a decline against an approve band without a rationale") };
switch (Core.planUnderwrite(s, app, #approve({ amount = 1; termDays = 730; rateBps = 1800; conditions = ["a", "a"] }), "")) { case (#err(#InvalidRequest(_))) {}; case (_) fail("a condition listed twice") };
let approved = plan(Core.planUnderwrite(s, app, #approve({ amount = 100_000_00; termDays = 730; rateBps = 1800; conditions = ["salary-assignment", "insurance"] }), ""));
switch (approved) { case (#underwritten(x)) { if (x.overrode) fail("an approval on an approve band is not an override") }; case (_) fail("not a decision") };
ignore apply(approved);
switch (Core.view(s, app)) { case (?v) { if (v.stage != #underwritten or v.conditions != 2 or v.approved != ?{ amount = 100_000_00; termDays = 730; rateBps = 1800 }) fail("the underwritten view") }; case null fail("no row") };
// the offer is the approval's terms or less
let terms : OT.OfferTerms = { amount = 100_000_00; termDays = 730; rateBps = 1800; product = "PL-STD"; currency = "EGP"; conditions = ["salary-assignment", "insurance"] };
switch (Core.planIssueOffer(s, app, { terms with amount = 100_000_01 }, day0 + 1)) { case (#err(#OfferMismatch(_))) {}; case (_) fail("an offer above the approval") };
switch (Core.planIssueOffer(s, app, { terms with rateBps = 1700 }, day0 + 1)) { case (#err(#OfferMismatch(_))) {}; case (_) fail("an offer at another rate") };
switch (Core.planIssueOffer(s, app, { terms with conditions = ["salary-assignment"] }, day0 + 1)) { case (#err(#OfferMismatch(_))) {}; case (_) fail("an offer with fewer conditions") };
switch (Core.planIssueOffer(s, app, { terms with conditions = ["salary-assignment", "guarantor"] }, day0 + 1)) { case (#err(#OfferMismatch(_))) {}; case (_) fail("an offer with another condition") };
let offered = plan(Core.planIssueOffer(s, app, { terms with amount = 90_000_00 }, day0 + 1));
let offerHash = switch (offered) { case (#offerIssued(x)) { if (x.expiresAt != day0 + 15 or x.offerHash != Core.offerHash(app, { terms with amount = 90_000_00 }, day0 + 15)) fail("the offer's hash or expiry"); x.offerHash }; case (_) { fail("not an offer"); "" } };
ignore apply(offered);
switch (Core.planAccept(s, app, good, day0 + 16)) { case (#err(#OfferExpired(_))) {}; case (_) fail("an expired offer accepted") };
switch (Core.planAccept(s, app, good, day0 + 5)) { case (#err(#AssertionRefused(_))) {}; case (_) fail("an assertion over another challenge accepted") };
switch (Core.planRecordDocument(s, app, #facilityAgreement, h("agreement"), null)) { case (#err(#WrongStage(_))) {}; case (_) fail("a document before acceptance") };
// the acceptance block as the actor records it once the assertion over this offer's hash verified
ignore apply(#offerAccepted({ application = app; credentialId = V.CREDENTIAL; assertionHash = h("assertion"); day = day0 + 5 }));
switch (Core.planFulfil(s, app)) { case (#err(#WrongStage(_))) {}; case (_) fail("fulfilled before documentation") };
switch (Core.planConditionsMet(s, app, ["guarantor"])) { case (#err(#UnknownCondition(_))) {}; case (_) fail("a condition the approval never set") };
let met1 = plan(Core.planConditionsMet(s, app, ["insurance"]));
switch (met1) { case (#conditionsMet(x)) { if (x.outstanding != 1) fail("outstanding after one") }; case (_) fail("not conditions") };
if (Core.completesDocumentation(s, app, met1)) fail("one condition completed the documentation");
ignore apply(met1);
let met2 = plan(Core.planConditionsMet(s, app, ["salary-assignment", "insurance"]));
switch (met2) { case (#conditionsMet(x)) { if (x.outstanding != 0) fail("outstanding after both") }; case (_) fail("not conditions") };
if (Core.completesDocumentation(s, app, met2)) fail("conditions without the agreement completed the documentation");
ignore apply(met2);
let doc = plan(Core.planRecordDocument(s, app, #facilityAgreement, h("agreement"), null));
if (not Core.completesDocumentation(s, app, doc)) fail("the agreement after every condition did not complete the documentation");
ignore apply(doc);
ignore apply(#documentationComplete({ application = app; day = day0 + 6 }));
let conds = Core.conditionsOf(s, app, ["salary-assignment", "insurance", "guarantor"]);
if (conds.size() != 3 or not conds[0].1 or not conds[1].1 or conds[2].1) fail("conditions " # debug_show (conds));
let drawing = switch (Core.planFulfil(s, app)) { case (#ok(f)) f; case (#err(e)) { fail("fulfil refused " # debug_show (e)); loop {} } };
if (drawing.amount != 100_000_00 or drawing.rateBps != 1800 or not Text.equal(drawing.product, "PL-STD") or drawing.party != party) fail("the drawing's terms");
let account = 9_001;
ignore apply(#fulfilled({ application = app; party; account; day = day0 + 7 }));
switch (Core.view(s, app)) { case (?v) { if (v.stage != #fulfilled or v.account != ?account or v.documents != 1) fail("the fulfilled view") }; case null fail("no row") };
if (Core.applicationOfAccount(s, account) != ?app) fail("the account does not name its application");
switch (Core.planWithdraw(s, app, "changed mind", day0 + 8)) { case (#err(#WrongStage(_))) {}; case (_) fail("a fulfilled application withdrawn") };
Debug.print("count: acts of one application's life refused where the stage forbids them = 24");

// ─── a prospect, onboarded at acceptance time ─────────────────────────────────
let prospect = act(Core.planOpen(null, "BR01", { request with amount = 30_000_00 }, "web", day0));
ignore act(Core.planRecordData(s, prospect, f1, []));
ignore act(Core.planAssess(s, prospect));
ignore act(Core.planScore(s, prospect));
ignore act(Core.planUnderwrite(s, prospect, #approve({ amount = 30_000_00; termDays = 730; rateBps = 2000; conditions = [] }), ""));
ignore act(Core.planIssueOffer(s, prospect, { terms with amount = 30_000_00; rateBps = 2000; conditions = [] }, day0 + 1));
switch (Core.planAccept(s, prospect, good, day0 + 2)) { case (#err(#NoParty(_))) {}; case (_) fail("a prospect accepted an offer") };
switch (Core.planOnboard(s, app)) { case (#err(#PartyMismatch(_))) {}; case (_) fail("onboarding named a customer's application") };
let newParty = 8;
switch (Core.planOnboard(s, prospect)) { case (#ok(r)) { if (not Text.equal(r.book, "BR01")) fail("the prospect's book") }; case (#err(e)) fail("onboarding refused " # debug_show (e)) };
ignore apply(#prospectOnboarded({ application = prospect; party = newParty }));
switch (Core.view(s, prospect)) { case (?v) { if (v.party != ?newParty or v.stage != #offered) fail("the onboarded prospect") }; case null fail("no row") };
if (Core.listByParty(s, newParty, null, 10).entries.size() != 1) fail("the party index after onboarding");
if (Core.listByParty(s, party, null, 10).entries.size() != 1) fail("the customer's applications");
// with no conditions, acceptance alone does not complete the documentation: the agreement must be on file
ignore apply(#offerAccepted({ application = prospect; credentialId = V.CREDENTIAL; assertionHash = h("a2"); day = day0 + 3 }));
let agreement = plan(Core.planRecordDocument(s, prospect, #facilityAgreement, h("agreement-2"), null));
if (not Core.completesDocumentation(s, prospect, agreement)) fail("the agreement alone did not complete an unconditional approval");
ignore apply(agreement);
ignore apply(#documentationComplete({ application = prospect; day = day0 + 3 }));
switch (Core.planFulfil(s, prospect)) { case (#ok(f)) { if (f.party != newParty) fail("the drawing's party") }; case (#err(e)) fail("fulfil refused " # debug_show (e)) };
Debug.print("count: a prospect's application fulfilled through its onboarding = 1");

// ─── decline, withdrawal, expiry ──────────────────────────────────────────────
let declined = act(Core.planOpen(?party, "HQ", request, "branch", day0));
ignore act(Core.planRecordData(s, declined, f2, []));
ignore act(Core.planAssess(s, declined));
switch (Core.view(s, declined)) { case (?v) { if (v.verdict != ?#fail) fail("f2 should fail affordability") }; case null fail("no row") };
ignore act(Core.planScore(s, declined));
switch (Core.planUnderwrite(s, declined, #approve({ amount = 1_000_00; termDays = 730; rateBps = 1800; conditions = [] }), "special case")) { case (#err(#DecisionAgainstBand(_))) {}; case (_) fail("a failed affordability approved") };
let dec = plan(Core.planUnderwrite(s, declined, #decline({ reasons = ["affordability", "score"] }), ""));
switch (dec) { case (#underwritten(x)) { if (x.overrode) fail("a decline on a decline band is not an override") }; case (_) fail("not a decision") };
ignore apply(dec);
switch (Core.view(s, declined)) { case (?v) { if (v.stage != #declined) fail("declined stage") }; case null fail("no row") };
let withdrawn = act(Core.planOpen(?party, "HQ", request, "branch", day0));
ignore act(Core.planWithdraw(s, withdrawn, "found another lender", day0 + 1));
switch (Core.planRecordData(s, withdrawn, f1, [])) { case (#err(#WrongStage(_))) {}; case (_) fail("facts on a withdrawn application") };
// a referred decision leaves the application scored, for the referee's decision
let referred = act(Core.planOpen(?party, "HQ", request, "branch", day0));
ignore act(Core.planRecordData(s, referred, f1, []));
ignore act(Core.planAssess(s, referred));
ignore act(Core.planScore(s, referred));
ignore act(Core.planUnderwrite(s, referred, #refer({ to = "credit-committee" }), ""));
switch (Core.view(s, referred)) { case (?v) { if (v.stage != #scored) fail("a referral left the wrong stage") }; case null fail("no row") };
ignore act(Core.planUnderwrite(s, referred, #approve({ amount = 50_000_00; termDays = 730; rateBps = 1900; conditions = [] }), "committee minute 12"));
ignore act(Core.planIssueOffer(s, referred, { terms with amount = 50_000_00; rateBps = 1900; conditions = [] }, day0 + 2));
// expiry: offered in HQ (referred) and BR01 (the prospect, since accepted: not offered any more)
if (Core.offeredInBookIds(s, "HQ") != [referred]) fail("offered in HQ " # debug_show (Core.offeredInBookIds(s, "HQ")));
if (Core.offeredInBook(s, "BR01") != 0) fail("BR01 has an offer standing");
if (Core.expiredOffers(s, day0 + 16).size() != 0) fail("expired before the validity ended");
if (Core.expiredOffers(s, day0 + 17) != [referred]) fail("expired " # debug_show (Core.expiredOffers(s, day0 + 17)));
ignore apply(#offerExpired({ application = referred; day = day0 + 17 }));
switch (Core.planAccept(s, referred, good, day0 + 17)) { case (#err(#WrongStage(_))) {}; case (_) fail("an expired offer accepted") };
Debug.print("count: decline, withdrawal, referral and expiry paths = 4");

// ─── indexes, counts, distribution, fingerprint ───────────────────────────────
let byStage = Core.listByStage(s, #fulfilled, null, 10);
if (byStage.entries.size() != 1 or byStage.entries[0].id != app) fail("by stage: fulfilled");
if (Core.listByStage(s, #offered, null, 10).entries.size() != 0) fail("by stage: offered after expiry (stale entries skipped)");
if (Core.listByStage(s, #documented, null, 10).entries.size() != 1) fail("by stage: documented");
let counts = Core.counts(s);
if (counts.applications != 5 or counts.fulfilled != 1 or counts.declined != 1 or counts.withdrawn != 1 or counts.expired != 1 or counts.passkeys != 1) fail("counts " # debug_show (counts));
let dist = Core.stageDistribution(s);
func at(name : Text) : Nat { for ((n, c) in dist.vals()) { if (Text.equal(n, name)) return c }; 0 };
if (at("fulfilled") != 1 or at("documented") != 1 or at("declined") != 1 or at("withdrawn") != 1 or at("expired") != 1) fail("distribution " # debug_show (dist));
let a1 = fp(s); let a2 = fp(s);
if (a1 != a2) fail("the fingerprint is not deterministic");
ignore act(Core.planOpen(?party, "HQ", request, "branch", day0 + 20));
if (fp(s) == a1) fail("the fingerprint did not change with a block");
Debug.print("count: applications folded = " # Nat.toText(Core.counts(s).applications));
Debug.print("ORIGINATION TEST GREEN");
