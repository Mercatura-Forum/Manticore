/// OriginationCanonical.mo; the canonical bytes of the origination vocabulary (origination and underwriting): the models, the
/// request and the facts, the decision and the offer, the bureau's report, the passkey assertion, and the
/// events. `BankCanonical` calls these for the commands and the event; `OriginationCore` for the fingerprint.
/// Every reader refuses what its writer would not have produced.

import List "mo:core/List";

import C "mo:journal/Canonical";

import OT "OriginationTypes";
import PayT "PaymentsTypes";

module {

  public func schemeCode(x : PayT.SignatureScheme) : Nat8 { switch (x) { case (#none) 0; case (#mayo2) 1; case (#mldsa44) 2 } };
  public func schemeOfCode(c : Nat8) : ?PayT.SignatureScheme { switch (c) { case 0 ?#none; case 1 ?#mayo2; case 2 ?#mldsa44; case _ null } };

  func rTexts(r : C.Reader) : ?[Text] {
    let ?n = r.len16() else return null;
    let out = List.empty<Text>();
    var i = 0;
    while (i < n) { let ?t = r.text() else return null; List.add(out, t); i += 1 };
    ?List.toArray(out)
  };
  func wTexts(w : C.Writer, xs : [Text]) { w.len16(xs.size()); for (x in xs.vals()) w.text(x) };

  // ── the models ──

  public func writePolicy(w : C.Writer, p : OT.Policy) {
    w.text(p.rpId); w.text(p.origin); w.nat(p.offerValidityDays);
    w.len16(p.bureaus.size());
    for ((name, scheme, key) in p.bureaus.vals()) { w.text(name); w.byte(schemeCode(scheme)); w.blob(key) };
  };
  public func readPolicy(r : C.Reader) : ?OT.Policy {
    let ?rpId = r.text() else return null; let ?origin = r.text() else return null; let ?offerValidityDays = r.nat() else return null;
    let ?n = r.len16() else return null;
    let bureaus = List.empty<(Text, PayT.SignatureScheme, Blob)>();
    var i = 0;
    while (i < n) {
      let ?name = r.text() else return null; let ?sc = r.byte() else return null; let ?scheme = schemeOfCode(sc) else return null; let ?key = r.blob() else return null;
      List.add(bureaus, (name, scheme, key)); i += 1;
    };
    ?{ rpId; origin; offerValidityDays; bureaus = List.toArray(bureaus) }
  };

  public func writeAffordabilityModel(w : C.Writer, m : OT.AffordabilityModel) {
    w.text(m.id); w.nat(m.version); w.len16(m.rules.size());
    for (r in m.rules.vals()) {
      w.text(r.id);
      switch (r.kind) {
        case (#maxDebtServiceRatioBps(x)) { w.byte(0); w.nat(x) }; case (#minResidualIncome(x)) { w.byte(1); w.nat(x) };
        case (#maxTermDays(x)) { w.byte(2); w.nat(x) }; case (#maxAmount(x)) { w.byte(3); w.nat(x) }; case (#minIncome(x)) { w.byte(4); w.nat(x) };
      };
      w.byte(switch (r.onFail) { case (#fail) 0; case (#refer) 1 });
    };
  };
  public func readAffordabilityModel(r : C.Reader) : ?OT.AffordabilityModel {
    let ?id = r.text() else return null; let ?version = r.nat() else return null; let ?n = r.len16() else return null;
    let rules = List.empty<OT.Rule>();
    var i = 0;
    while (i < n) {
      let ?rid = r.text() else return null; let ?k = r.byte() else return null; let ?x = r.nat() else return null;
      let kind : OT.RuleKind = switch (k) {
        case 0 #maxDebtServiceRatioBps(x); case 1 #minResidualIncome(x); case 2 #maxTermDays(x); case 3 #maxAmount(x); case 4 #minIncome(x);
        case _ return null;
      };
      let onFail : { #fail; #refer } = switch (r.byte()) { case (?0) #fail; case (?1) #refer; case (_) return null };
      List.add(rules, { id = rid; kind; onFail }); i += 1;
    };
    ?{ id; version; rules = List.toArray(rules) }
  };

  public func attributeCode(a : OT.Attribute) : Nat8 {
    switch (a) { case (#income) 0; case (#obligationsRatioBps) 1; case (#bureauScore) 2; case (#bureauFlags) 3; case (#termDays) 4; case (#amount) 5 }
  };
  public func attributeOfCode(c : Nat8) : ?OT.Attribute {
    switch (c) { case 0 ?#income; case 1 ?#obligationsRatioBps; case 2 ?#bureauScore; case 3 ?#bureauFlags; case 4 ?#termDays; case 5 ?#amount; case _ null }
  };
  public func writeScorecard(w : C.Writer, c : OT.Scorecard) {
    w.text(c.id); w.nat(c.version); w.len16(c.attributes.size());
    for ((attr, bands) in c.attributes.vals()) {
      w.byte(attributeCode(attr)); w.len16(bands.size());
      for (b in bands.vals()) { w.nat(b.lo); w.optNat(b.hi); w.nat(b.points) };
    };
    w.nat(c.declineBelow); w.nat(c.referBelow);
  };
  public func readScorecard(r : C.Reader) : ?OT.Scorecard {
    let ?id = r.text() else return null; let ?version = r.nat() else return null; let ?n = r.len16() else return null;
    let attributes = List.empty<(OT.Attribute, [OT.Band])>();
    var i = 0;
    while (i < n) {
      let ?ac = r.byte() else return null; let ?attr = attributeOfCode(ac) else return null; let ?m = r.len16() else return null;
      let bands = List.empty<OT.Band>();
      var j = 0;
      while (j < m) {
        let ?lo = r.nat() else return null; let ?hi = r.optNat() else return null; let ?points = r.nat() else return null;
        List.add(bands, { lo; hi; points }); j += 1;
      };
      List.add(attributes, (attr, List.toArray(bands))); i += 1;
    };
    let ?declineBelow = r.nat() else return null; let ?referBelow = r.nat() else return null;
    ?{ id; version; attributes = List.toArray(attributes); declineBelow; referBelow }
  };

  // ── the application's parts ──

  public func writeRequest(w : C.Writer, x : OT.Request) { w.text(x.product); w.nat(x.amount); w.text(x.currency); w.nat(x.termDays); w.text(x.purpose) };
  public func readRequest(r : C.Reader) : ?OT.Request {
    let ?product = r.text() else return null; let ?amount = r.nat() else return null; let ?currency = r.text() else return null;
    let ?termDays = r.nat() else return null; let ?purpose = r.text() else return null;
    ?{ product; amount; currency; termDays; purpose }
  };
  public func writeFacts(w : C.Writer, f : OT.Facts) { w.nat(f.income); w.nat(f.obligations); w.nat(f.proposedInstalment); w.nat(f.dependants) };
  public func readFacts(r : C.Reader) : ?OT.Facts {
    let ?income = r.nat() else return null; let ?obligations = r.nat() else return null; let ?proposedInstalment = r.nat() else return null; let ?dependants = r.nat() else return null;
    ?{ income; obligations; proposedInstalment; dependants }
  };
  public func writeCommitments(w : C.Writer, xs : [(Text, Blob)]) { w.len16(xs.size()); for ((k, v) in xs.vals()) { w.text(k); w.blob(v) } };
  public func readCommitments(r : C.Reader) : ?[(Text, Blob)] {
    let ?n = r.len16() else return null;
    let out = List.empty<(Text, Blob)>();
    var i = 0;
    while (i < n) { let ?k = r.text() else return null; let ?v = r.blob() else return null; List.add(out, (k, v)); i += 1 };
    ?List.toArray(out)
  };
  public func writeVerdict(w : C.Writer, v : OT.Verdict) {
    switch (v) { case (#pass) w.byte(0); case (#fail(xs)) { w.byte(1); wTexts(w, xs) }; case (#refer(xs)) { w.byte(2); wTexts(w, xs) } }
  };
  public func readVerdict(r : C.Reader) : ?OT.Verdict {
    switch (r.byte()) {
      case (?0) ?#pass; case (?1) { let ?xs = rTexts(r) else return null; ?#fail(xs) }; case (?2) { let ?xs = rTexts(r) else return null; ?#refer(xs) };
      case (_) null;
    }
  };
  public func writeBand(w : C.Writer, b : OT.ScoreBand) { w.byte(switch (b) { case (#approve) 0; case (#refer) 1; case (#decline) 2 }) };
  public func readBand(r : C.Reader) : ?OT.ScoreBand { switch (r.byte()) { case (?0) ?#approve; case (?1) ?#refer; case (?2) ?#decline; case (_) null } };
  public func writeReport(w : C.Writer, x : OT.BureauReport) { w.text(x.bureau); w.nat(x.score); wTexts(w, x.flags); w.blob(x.reportHash); w.nat(x.reportedOn) };
  public func readReport(r : C.Reader) : ?OT.BureauReport {
    let ?bureau = r.text() else return null; let ?score = r.nat() else return null; let ?flags = rTexts(r) else return null;
    let ?reportHash = r.blob() else return null; let ?reportedOn = r.nat() else return null;
    ?{ bureau; score; flags; reportHash; reportedOn }
  };
  public func writeDecision(w : C.Writer, d : OT.Decision) {
    switch (d) {
      case (#approve(a)) { w.byte(0); w.nat(a.amount); w.nat(a.termDays); w.nat(a.rateBps); wTexts(w, a.conditions) };
      case (#decline(x)) { w.byte(1); wTexts(w, x.reasons) };
      case (#refer(x)) { w.byte(2); w.text(x.to) };
    }
  };
  public func readDecision(r : C.Reader) : ?OT.Decision {
    switch (r.byte()) {
      case (?0) {
        let ?amount = r.nat() else return null; let ?termDays = r.nat() else return null; let ?rateBps = r.nat() else return null; let ?conditions = rTexts(r) else return null;
        ?#approve({ amount; termDays; rateBps; conditions })
      };
      case (?1) { let ?reasons = rTexts(r) else return null; ?#decline({ reasons }) };
      case (?2) { let ?to = r.text() else return null; ?#refer({ to }) };
      case (_) null;
    }
  };
  public func writeTerms(w : C.Writer, t : OT.OfferTerms) { w.nat(t.amount); w.nat(t.termDays); w.nat(t.rateBps); w.text(t.product); w.text(t.currency); wTexts(w, t.conditions) };
  public func readTerms(r : C.Reader) : ?OT.OfferTerms {
    let ?amount = r.nat() else return null; let ?termDays = r.nat() else return null; let ?rateBps = r.nat() else return null;
    let ?product = r.text() else return null; let ?currency = r.text() else return null; let ?conditions = rTexts(r) else return null;
    ?{ amount; termDays; rateBps; product; currency; conditions }
  };
  public func writeAssertion(w : C.Writer, a : OT.PasskeyAssertion) { w.blob(a.credentialId); w.blob(a.authenticatorData); w.blob(a.clientDataJSON); w.blob(a.signature) };
  public func readAssertion(r : C.Reader) : ?OT.PasskeyAssertion {
    let ?credentialId = r.blob() else return null; let ?authenticatorData = r.blob() else return null; let ?clientDataJSON = r.blob() else return null; let ?signature = r.blob() else return null;
    ?{ credentialId; authenticatorData; clientDataJSON; signature }
  };
  public func writeOptAssertion(w : C.Writer, a : ?OT.PasskeyAssertion) { switch (a) { case null w.byte(0); case (?x) { w.byte(1); writeAssertion(w, x) } } };
  public func readOptAssertion(r : C.Reader) : ??OT.PasskeyAssertion {
    switch (r.byte()) { case (?0) ?null; case (?1) { let ?a = readAssertion(r) else return null; ?(?a) }; case (_) null }
  };
  public func writeKind(w : C.Writer, k : OT.DocumentKind) {
    switch (k) { case (#facilityAgreement) w.byte(0); case (#collateralPledge) w.byte(1); case (#insurance) w.byte(2); case (#guarantee) w.byte(3); case (#other(t)) { w.byte(4); w.text(t) } }
  };
  public func readKind(r : C.Reader) : ?OT.DocumentKind {
    switch (r.byte()) {
      case (?0) ?#facilityAgreement; case (?1) ?#collateralPledge; case (?2) ?#insurance; case (?3) ?#guarantee;
      case (?4) { let ?t = r.text() else return null; ?#other(t) }; case (_) null;
    }
  };

  // ── the event ──

  public func writeEvent(w : C.Writer, e : OT.OriginationEvent) {
    switch (e) {
      case (#policySet(p)) { w.byte(0x01); writePolicy(w, p) };
      case (#affordabilityModelSet(m)) { w.byte(0x02); writeAffordabilityModel(w, m) };
      case (#scorecardSet(c)) { w.byte(0x03); writeScorecard(w, c) };
      case (#passkeyRegistered(x)) { w.byte(0x04); w.nat(x.party); w.blob(x.credentialId); w.blob(x.publicKeySpki) };
      case (#applicationOpened(x)) { w.byte(0x05); w.optNat(x.party); w.text(x.book); writeRequest(w, x.request); w.text(x.channel); w.nat(x.day) };
      case (#dataRecorded(x)) { w.byte(0x06); w.nat(x.application); writeFacts(w, x.facts); writeCommitments(w, x.commitments) };
      case (#affordabilityAssessed(x)) { w.byte(0x07); w.nat(x.application); w.text(x.model); w.nat(x.version); writeVerdict(w, x.verdict) };
      case (#bureauRequested(x)) { w.byte(0x08); w.nat(x.application); w.text(x.bureau); w.blob(x.consentCommit); w.nat(x.day) };
      case (#bureauRecorded(x)) { w.byte(0x09); w.nat(x.application); writeReport(w, x.report) };
      case (#scored(x)) { w.byte(0x0A); w.nat(x.application); w.text(x.scorecard); w.nat(x.version); w.nat(x.points); writeBand(w, x.band) };
      case (#underwritten(x)) { w.byte(0x0B); w.nat(x.application); writeDecision(w, x.decision); w.text(x.rationale); w.bool(x.overrode) };
      case (#offerIssued(x)) { w.byte(0x0C); w.nat(x.application); writeTerms(w, x.terms); w.blob(x.offerHash); w.nat(x.expiresAt) };
      case (#offerAccepted(x)) { w.byte(0x0D); w.nat(x.application); w.blob(x.credentialId); w.blob(x.assertionHash); w.nat(x.day) };
      case (#offerDeclined(x)) { w.byte(0x0E); w.nat(x.application); w.nat(x.day) };
      case (#offerExpired(x)) { w.byte(0x0F); w.nat(x.application); w.nat(x.day) };
      case (#documentRecorded(x)) { w.byte(0x10); w.nat(x.application); writeKind(w, x.kind); w.blob(x.sha256); w.bool(x.signed) };
      case (#conditionsMet(x)) { w.byte(0x11); w.nat(x.application); wTexts(w, x.conditions); w.nat(x.outstanding) };
      case (#documentationComplete(x)) { w.byte(0x12); w.nat(x.application); w.nat(x.day) };
      case (#prospectOnboarded(x)) { w.byte(0x13); w.nat(x.application); w.nat(x.party) };
      case (#fulfilled(x)) { w.byte(0x14); w.nat(x.application); w.nat(x.party); w.nat(x.account); w.nat(x.day) };
      case (#withdrawn(x)) { w.byte(0x15); w.nat(x.application); w.text(x.reason); w.nat(x.day) };
    }
  };

  public func readEvent(r : C.Reader) : ?OT.OriginationEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 { let ?p = readPolicy(r) else return null; ?#policySet(p) };
      case 0x02 { let ?m = readAffordabilityModel(r) else return null; ?#affordabilityModelSet(m) };
      case 0x03 { let ?c = readScorecard(r) else return null; ?#scorecardSet(c) };
      case 0x04 { let ?party = r.nat() else return null; let ?credentialId = r.blob() else return null; let ?publicKeySpki = r.blob() else return null; ?#passkeyRegistered({ party; credentialId; publicKeySpki }) };
      case 0x05 {
        let ?party = r.optNat() else return null; let ?book = r.text() else return null; let ?request = readRequest(r) else return null;
        let ?channel = r.text() else return null; let ?day = r.nat() else return null;
        ?#applicationOpened({ party; book; request; channel; day })
      };
      case 0x06 { let ?application = r.nat() else return null; let ?facts = readFacts(r) else return null; let ?commitments = readCommitments(r) else return null; ?#dataRecorded({ application; facts; commitments }) };
      case 0x07 {
        let ?application = r.nat() else return null; let ?model = r.text() else return null; let ?version = r.nat() else return null; let ?verdict = readVerdict(r) else return null;
        ?#affordabilityAssessed({ application; model; version; verdict })
      };
      case 0x08 {
        let ?application = r.nat() else return null; let ?bureau = r.text() else return null; let ?consentCommit = r.blob() else return null; let ?day = r.nat() else return null;
        ?#bureauRequested({ application; bureau; consentCommit; day })
      };
      case 0x09 { let ?application = r.nat() else return null; let ?report = readReport(r) else return null; ?#bureauRecorded({ application; report }) };
      case 0x0A {
        let ?application = r.nat() else return null; let ?scorecard = r.text() else return null; let ?version = r.nat() else return null;
        let ?points = r.nat() else return null; let ?band = readBand(r) else return null;
        ?#scored({ application; scorecard; version; points; band })
      };
      case 0x0B {
        let ?application = r.nat() else return null; let ?decision = readDecision(r) else return null; let ?rationale = r.text() else return null; let ?overrode = r.bool() else return null;
        ?#underwritten({ application; decision; rationale; overrode })
      };
      case 0x0C {
        let ?application = r.nat() else return null; let ?terms = readTerms(r) else return null; let ?offerHash = r.blob() else return null; let ?expiresAt = r.nat() else return null;
        ?#offerIssued({ application; terms; offerHash; expiresAt })
      };
      case 0x0D {
        let ?application = r.nat() else return null; let ?credentialId = r.blob() else return null; let ?assertionHash = r.blob() else return null; let ?day = r.nat() else return null;
        ?#offerAccepted({ application; credentialId; assertionHash; day })
      };
      case 0x0E { let ?application = r.nat() else return null; let ?day = r.nat() else return null; ?#offerDeclined({ application; day }) };
      case 0x0F { let ?application = r.nat() else return null; let ?day = r.nat() else return null; ?#offerExpired({ application; day }) };
      case 0x10 {
        let ?application = r.nat() else return null; let ?kind = readKind(r) else return null; let ?sha256 = r.blob() else return null; let ?signed = r.bool() else return null;
        ?#documentRecorded({ application; kind; sha256; signed })
      };
      case 0x11 { let ?application = r.nat() else return null; let ?conditions = rTexts(r) else return null; let ?outstanding = r.nat() else return null; ?#conditionsMet({ application; conditions; outstanding }) };
      case 0x12 { let ?application = r.nat() else return null; let ?day = r.nat() else return null; ?#documentationComplete({ application; day }) };
      case 0x13 { let ?application = r.nat() else return null; let ?party = r.nat() else return null; ?#prospectOnboarded({ application; party }) };
      case 0x14 {
        let ?application = r.nat() else return null; let ?party = r.nat() else return null; let ?account = r.nat() else return null; let ?day = r.nat() else return null;
        ?#fulfilled({ application; party; account; day })
      };
      case 0x15 { let ?application = r.nat() else return null; let ?reason = r.text() else return null; let ?day = r.nat() else return null; ?#withdrawn({ application; reason; day }) };
      case _ null;
    }
  };
}
