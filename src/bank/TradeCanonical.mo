/// TradeCanonical.mo — the canonical bytes of the trade-finance vocabulary (trade finance): the policy, the instrument
/// kinds and their terms, documents and checks, decisions, honours, amendments, messages, and the events.
/// `BankCanonical` calls these for the commands and the event.

import List "mo:core/List";

import C "mo:journal/Canonical";

import TrT "TradeTypes";

module {

  func wTexts(w : C.Writer, xs : [Text]) { w.len16(xs.size()); for (x in xs.vals()) w.text(x) };
  func rTexts(r : C.Reader) : ?[Text] {
    let ?n = r.len16() else return null;
    let out = List.empty<Text>();
    var i = 0;
    while (i < n) { let ?x = r.text() else return null; List.add(out, x); i += 1 };
    ?List.toArray(out)
  };
  func wOptText(w : C.Writer, t : ?Text) { switch (t) { case null w.byte(0); case (?x) { w.byte(1); w.text(x) } } };
  func rOptText(r : C.Reader) : ??Text { switch (r.byte()) { case (?0) ?null; case (?1) { let ?x = r.text() else return null; ??x }; case (_) null } };

  public func writePolicy(w : C.Writer, p : TrT.Policy) {
    for (t in [p.bic, p.contingentLcs, p.contingentGuarantees, p.contingentCollections, p.contingentContra, p.marginDeposits, p.unearnedCommission, p.commissionIncome,
               p.acceptancesPayable, p.customersLiabilityAcceptances, p.billsNegotiated, p.billsDiscounted, p.unearnedDiscount, p.discountIncome, p.billsRediscounted,
               p.billLosses, p.nostro, p.claimProduct].vals()) w.text(t);
    w.nat(p.examinationDays);
  };
  public func readPolicy(r : C.Reader) : ?TrT.Policy {
    let ?bic = r.text() else return null; let ?contingentLcs = r.text() else return null; let ?contingentGuarantees = r.text() else return null; let ?contingentCollections = r.text() else return null;
    let ?contingentContra = r.text() else return null; let ?marginDeposits = r.text() else return null; let ?unearnedCommission = r.text() else return null;
    let ?commissionIncome = r.text() else return null; let ?acceptancesPayable = r.text() else return null; let ?customersLiabilityAcceptances = r.text() else return null;
    let ?billsNegotiated = r.text() else return null; let ?billsDiscounted = r.text() else return null; let ?unearnedDiscount = r.text() else return null;
    let ?discountIncome = r.text() else return null; let ?billsRediscounted = r.text() else return null; let ?billLosses = r.text() else return null;
    let ?nostro = r.text() else return null; let ?claimProduct = r.text() else return null; let ?examinationDays = r.nat() else return null;
    ?{ bic; contingentLcs; contingentGuarantees; contingentCollections; contingentContra; marginDeposits; unearnedCommission; commissionIncome; acceptancesPayable;
       customersLiabilityAcceptances; billsNegotiated; billsDiscounted; unearnedDiscount; discountIncome; billsRediscounted; billLosses; nostro; claimProduct; examinationDays }
  };

  public func writeRules(w : C.Writer, x : TrT.Rules) { w.byte(switch (x) { case (#UCP600) 0; case (#ISP98) 1; case (#URDG758) 2; case (#URC522) 3 }) };
  public func readRules(r : C.Reader) : ?TrT.Rules { switch (r.byte()) { case (?0) ?#UCP600; case (?1) ?#ISP98; case (?2) ?#URDG758; case (?3) ?#URC522; case (_) null } };

  public func writeDocumentKind(w : C.Writer, k : TrT.DocumentKind) {
    switch (k) {
      case (#invoice) w.byte(0); case (#transport) w.byte(1); case (#insurance) w.byte(2); case (#origin) w.byte(3); case (#packing) w.byte(4);
      case (#inspection) w.byte(5); case (#draft) w.byte(6); case (#other(t)) { w.byte(7); w.text(t) };
    }
  };
  public func readDocumentKind(r : C.Reader) : ?TrT.DocumentKind {
    switch (r.byte()) {
      case (?0) ?#invoice; case (?1) ?#transport; case (?2) ?#insurance; case (?3) ?#origin; case (?4) ?#packing; case (?5) ?#inspection; case (?6) ?#draft;
      case (?7) { let ?t = r.text() else return null; ?#other(t) }; case (_) null;
    }
  };
  public func writeDocumentRefs(w : C.Writer, ds : [TrT.DocumentRef]) { w.len16(ds.size()); for (d in ds.vals()) { writeDocumentKind(w, d.kind); w.blob(d.hash) } };
  public func readDocumentRefs(r : C.Reader) : ?[TrT.DocumentRef] {
    let ?n = r.len16() else return null;
    let out = List.empty<TrT.DocumentRef>();
    var i = 0;
    while (i < n) { let ?kind = readDocumentKind(r) else return null; let ?hash = r.blob() else return null; List.add(out, { kind; hash }); i += 1 };
    ?List.toArray(out)
  };
  public func writeDocumentRef(w : C.Writer, d : TrT.DocumentRef) { writeDocumentKind(w, d.kind); w.blob(d.hash) };
  public func readDocumentRef(r : C.Reader) : ?TrT.DocumentRef { let ?kind = readDocumentKind(r) else return null; let ?hash = r.blob() else return null; ?{ kind; hash } };

  public func writeAvailability(w : C.Writer, a : TrT.Availability) {
    switch (a) { case (#sight) w.byte(0); case (#deferred(d)) { w.byte(1); w.nat(d.days) }; case (#acceptance(d)) { w.byte(2); w.nat(d.days) }; case (#negotiation) w.byte(3) }
  };
  public func readAvailability(r : C.Reader) : ?TrT.Availability {
    switch (r.byte()) {
      case (?0) ?#sight; case (?1) { let ?days = r.nat() else return null; ?#deferred({ days }) }; case (?2) { let ?days = r.nat() else return null; ?#acceptance({ days }) }; case (?3) ?#negotiation; case (_) null;
    }
  };
  public func writeTerms(w : C.Writer, t : TrT.DocumentaryTerms) {
    w.len16(t.documents.size());
    for (d in t.documents.vals()) { writeDocumentKind(w, d.kind); w.nat(d.copies); wTexts(w, d.checks) };
    w.optNat(t.latestShipment); w.nat(t.presentationDays); w.bool(t.partialShipments); w.bool(t.transhipment); wOptText(w, t.incoterm);
    writeAvailability(w, t.availableBy); w.text(t.portOfLoading); w.text(t.portOfDischarge); w.text(t.goods);
  };
  public func readTerms(r : C.Reader) : ?TrT.DocumentaryTerms {
    let ?n = r.len16() else return null;
    let docs = List.empty<TrT.RequiredDocument>();
    var i = 0;
    while (i < n) { let ?kind = readDocumentKind(r) else return null; let ?copies = r.nat() else return null; let ?checks = rTexts(r) else return null; List.add(docs, { kind; copies; checks }); i += 1 };
    let ?latestShipment = r.optNat() else return null; let ?presentationDays = r.nat() else return null; let ?partialShipments = r.bool() else return null;
    let ?transhipment = r.bool() else return null; let ?incoterm = rOptText(r) else return null; let ?availableBy = readAvailability(r) else return null;
    let ?portOfLoading = r.text() else return null; let ?portOfDischarge = r.text() else return null; let ?goods = r.text() else return null;
    ?{ documents = List.toArray(docs); latestShipment; presentationDays; partialShipments; transhipment; incoterm; availableBy; portOfLoading; portOfDischarge; goods }
  };

  public func writeCounterparty(w : C.Writer, c : TrT.Counterparty) {
    switch (c) { case (#party(p)) { w.byte(0); w.nat(p.party); w.nat(p.account) }; case (#external(e)) { w.byte(1); w.text(e.name); w.text(e.bic); w.text(e.account) } }
  };
  public func readCounterparty(r : C.Reader) : ?TrT.Counterparty {
    switch (r.byte()) {
      case (?0) { let ?party = r.nat() else return null; let ?account = r.nat() else return null; ?#party({ party; account }) };
      case (?1) { let ?name = r.text() else return null; let ?bic = r.text() else return null; let ?account = r.text() else return null; ?#external({ name; bic; account }) };
      case (_) null;
    }
  };

  public func writeLc(w : C.Writer, lc : TrT.LetterOfCredit) {
    w.byte(switch (lc.role) { case (#issuing) 0; case (#advising) 1; case (#confirming) 2 });
    writeCounterparty(w, lc.applicant); writeCounterparty(w, lc.beneficiary); w.text(lc.counterpartyBank); writeTerms(w, lc.terms);
    w.optNat(lc.tolerance); w.nat(lc.marginBps); w.optNat(lc.facility); w.nat(lc.commissionBps); w.text(lc.reference);
  };
  public func readLc(r : C.Reader) : ?TrT.LetterOfCredit {
    let role : TrT.LcRole = switch (r.byte()) { case (?0) #issuing; case (?1) #advising; case (?2) #confirming; case (_) return null };
    let ?applicant = readCounterparty(r) else return null; let ?beneficiary = readCounterparty(r) else return null;
    let ?counterpartyBank = r.text() else return null; let ?terms = readTerms(r) else return null; let ?tolerance = r.optNat() else return null;
    let ?marginBps = r.nat() else return null; let ?facility = r.optNat() else return null; let ?commissionBps = r.nat() else return null; let ?reference = r.text() else return null;
    ?{ role; applicant; beneficiary; counterpartyBank; terms; tolerance; marginBps; facility; commissionBps; reference }
  };
  public func writeGuarantee(w : C.Writer, g : TrT.Guarantee) {
    w.byte(switch (g.kind) { case (#standby) 0; case (#demandGuarantee) 1; case (#counterGuarantee) 2 }); writeRules(w, g.rules);
    w.nat(g.principal); w.nat(g.principalAccount); writeCounterparty(w, g.beneficiary); w.text(g.counterpartyBank); w.blob(g.wording); w.bool(g.statementRequired);
    w.len16(g.reductions.size()); for ((d, a) in g.reductions.vals()) { w.nat(d); w.nat(a) };
    w.nat(g.marginBps); w.optNat(g.facility); w.nat(g.commissionBps); w.text(g.reference);
  };
  public func readGuarantee(r : C.Reader) : ?TrT.Guarantee {
    let kind : TrT.GuaranteeKind = switch (r.byte()) { case (?0) #standby; case (?1) #demandGuarantee; case (?2) #counterGuarantee; case (_) return null };
    let ?rules = readRules(r) else return null; let ?principal = r.nat() else return null; let ?principalAccount = r.nat() else return null;
    let ?beneficiary = readCounterparty(r) else return null; let ?counterpartyBank = r.text() else return null; let ?wording = r.blob() else return null;
    let ?statementRequired = r.bool() else return null; let ?n = r.len16() else return null;
    let red = List.empty<(Nat, Nat)>();
    var i = 0;
    while (i < n) { let ?d = r.nat() else return null; let ?a = r.nat() else return null; List.add(red, (d, a)); i += 1 };
    let ?marginBps = r.nat() else return null; let ?facility = r.optNat() else return null; let ?commissionBps = r.nat() else return null; let ?reference = r.text() else return null;
    ?{ kind; rules; principal; principalAccount; beneficiary; counterpartyBank; wording; statementRequired; reductions = List.toArray(red); marginBps; facility; commissionBps; reference }
  };
  public func writeCollection(w : C.Writer, c : TrT.Collection) {
    w.byte(switch (c.role) { case (#remitting) 0; case (#collecting) 1 });
    switch (c.terms) { case (#DP) w.byte(0); case (#DA(t)) { w.byte(1); w.nat(t.tenorDays) } };
    writeCounterparty(w, c.drawer); writeCounterparty(w, c.drawee); w.text(c.counterpartyBank); writeDocumentRefs(w, c.documents); w.text(c.instructions); w.nat(c.commissionBps); w.text(c.reference);
  };
  public func readCollection(r : C.Reader) : ?TrT.Collection {
    let role : TrT.CollectionRole = switch (r.byte()) { case (?0) #remitting; case (?1) #collecting; case (_) return null };
    let terms : TrT.CollectionTerms = switch (r.byte()) { case (?0) #DP; case (?1) { let ?tenorDays = r.nat() else return null; #DA({ tenorDays }) }; case (_) return null };
    let ?drawer = readCounterparty(r) else return null; let ?drawee = readCounterparty(r) else return null; let ?counterpartyBank = r.text() else return null;
    let ?documents = readDocumentRefs(r) else return null; let ?instructions = r.text() else return null; let ?commissionBps = r.nat() else return null; let ?reference = r.text() else return null;
    ?{ role; terms; drawer; drawee; counterpartyBank; documents; instructions; commissionBps; reference }
  };
  public func writeBill(w : C.Writer, b : TrT.Bill) {
    w.nat(b.customer); w.nat(b.customerAccount); writeCounterparty(w, b.acceptor);
    switch (b.source) { case null w.byte(0); case (?s) { w.byte(1); w.nat(s.instrument); w.nat(s.claim) } };
    w.nat(b.discountBps); w.bool(b.recourse); w.text(b.reference);
  };
  public func readBill(r : C.Reader) : ?TrT.Bill {
    let ?customer = r.nat() else return null; let ?customerAccount = r.nat() else return null; let ?acceptor = readCounterparty(r) else return null;
    let source : ?{ instrument : Nat; claim : Nat } = switch (r.byte()) { case (?0) null; case (?1) { let ?instrument = r.nat() else return null; let ?claim = r.nat() else return null; ?{ instrument; claim } }; case (_) return null };
    let ?discountBps = r.nat() else return null; let ?recourse = r.bool() else return null; let ?reference = r.text() else return null;
    ?{ customer; customerAccount; acceptor; source; discountBps; recourse; reference }
  };

  public func writeChecks(w : C.Writer, cs : [TrT.CheckResult]) { w.len16(cs.size()); for (c in cs.vals()) { writeDocumentKind(w, c.document); w.text(c.check); w.bool(c.passed); w.text(c.finding) } };
  public func readChecks(r : C.Reader) : ?[TrT.CheckResult] {
    let ?n = r.len16() else return null;
    let out = List.empty<TrT.CheckResult>();
    var i = 0;
    while (i < n) { let ?document = readDocumentKind(r) else return null; let ?check = r.text() else return null; let ?passed = r.bool() else return null; let ?finding = r.text() else return null; List.add(out, { document; check; passed; finding }); i += 1 };
    ?List.toArray(out)
  };
  public func writeDecision(w : C.Writer, d : TrT.Decision) {
    switch (d) {
      case (#complying) w.byte(0);
      case (#refuse(x)) { w.byte(1); wTexts(w, x.discrepancies); w.byte(switch (x.disposal) { case (#held) 0; case (#returned) 1; case (#heldPendingWaiver) 2; case (#actingOnInstructions) 3 }) };
    }
  };
  public func readDecision(r : C.Reader) : ?TrT.Decision {
    switch (r.byte()) {
      case (?0) ?#complying;
      case (?1) {
        let ?discrepancies = rTexts(r) else return null;
        let disposal : TrT.Disposal = switch (r.byte()) { case (?0) #held; case (?1) #returned; case (?2) #heldPendingWaiver; case (?3) #actingOnInstructions; case (_) return null };
        ?#refuse({ discrepancies; disposal })
      };
      case (_) null;
    }
  };
  public func writeHonour(w : C.Writer, h : TrT.Honour) {
    switch (h) { case (#sight) w.byte(0); case (#deferred(d)) { w.byte(1); w.nat(d.due) }; case (#acceptance(d)) { w.byte(2); w.nat(d.due) }; case (#negotiation(d)) { w.byte(3); w.nat(d.due) } }
  };
  public func readHonour(r : C.Reader) : ?TrT.Honour {
    switch (r.byte()) {
      case (?0) ?#sight; case (?1) { let ?due = r.nat() else return null; ?#deferred({ due }) }; case (?2) { let ?due = r.nat() else return null; ?#acceptance({ due }) };
      case (?3) { let ?due = r.nat() else return null; ?#negotiation({ due }) }; case (_) null;
    }
  };
  public func writeAmendment(w : C.Writer, a : TrT.Amendment) {
    w.optNat(a.amount); w.optNat(a.expiry); w.optNat(a.latestShipment); w.text(a.other);
    w.len16(a.consents.size()); for (c in a.consents.vals()) w.byte(switch (c) { case (#beneficiary) 0; case (#confirmingBank) 1; case (#applicant) 2; case (#issuingBank) 3 });
  };
  public func readAmendment(r : C.Reader) : ?TrT.Amendment {
    let ?amount = r.optNat() else return null; let ?expiry = r.optNat() else return null; let ?latestShipment = r.optNat() else return null; let ?other = r.text() else return null;
    let ?n = r.len16() else return null;
    let cs = List.empty<TrT.Consent>();
    var i = 0;
    while (i < n) { let c : TrT.Consent = switch (r.byte()) { case (?0) #beneficiary; case (?1) #confirmingBank; case (?2) #applicant; case (?3) #issuingBank; case (_) return null }; List.add(cs, c); i += 1 };
    ?{ amount; expiry; latestShipment; other; consents = List.toArray(cs) }
  };
  public func writeMessageKind(w : C.Writer, k : TrT.MessageKind) { switch (k) { case (#mt(n)) { w.byte(0); w.nat(n) }; case (#tsrv(n)) { w.byte(1); w.nat(n) } } };
  public func readMessageKind(r : C.Reader) : ?TrT.MessageKind { switch (r.byte()) { case (?0) { let ?n = r.nat() else return null; ?#mt(n) }; case (?1) { let ?n = r.nat() else return null; ?#tsrv(n) }; case (_) null } };
  public func writeDirection(w : C.Writer, d : TrT.Direction) { w.byte(switch (d) { case (#outgoing) 0; case (#incoming) 1 }) };
  public func readDirection(r : C.Reader) : ?TrT.Direction { switch (r.byte()) { case (?0) ?#outgoing; case (?1) ?#incoming; case (_) null } };

  // ─── events ───────────────────────────────────────────────────────────────

  func wAmend(w : C.Writer, x : { instrument : Nat; amendment : TrT.Amendment; number : Nat; amount : Nat; expiry : Nat; day : Nat }) { w.nat(x.instrument); writeAmendment(w, x.amendment); w.nat(x.number); w.nat(x.amount); w.nat(x.expiry); w.nat(x.day) };
  func rAmend(r : C.Reader) : ?{ instrument : Nat; amendment : TrT.Amendment; number : Nat; amount : Nat; expiry : Nat; day : Nat } {
    let ?instrument = r.nat() else return null; let ?amendment = readAmendment(r) else return null; let ?number = r.nat() else return null; let ?amount = r.nat() else return null; let ?expiry = r.nat() else return null; let ?day = r.nat() else return null;
    ?{ instrument; amendment; number; amount; expiry; day }
  };
  func wExam(w : C.Writer, x : { instrument : Nat; claim : Nat; checks : [TrT.CheckResult]; decision : TrT.Decision; day : Nat }) { w.nat(x.instrument); w.nat(x.claim); writeChecks(w, x.checks); writeDecision(w, x.decision); w.nat(x.day) };
  func rExam(r : C.Reader) : ?{ instrument : Nat; claim : Nat; checks : [TrT.CheckResult]; decision : TrT.Decision; day : Nat } {
    let ?instrument = r.nat() else return null; let ?claim = r.nat() else return null; let ?checks = readChecks(r) else return null; let ?decision = readDecision(r) else return null; let ?day = r.nat() else return null;
    ?{ instrument; claim; checks; decision; day }
  };
  func wEnd(w : C.Writer, x : { instrument : Nat; reason : Text; marginReleased : Nat; day : Nat }) { w.nat(x.instrument); w.text(x.reason); w.nat(x.marginReleased); w.nat(x.day) };
  func rEnd(r : C.Reader) : ?{ instrument : Nat; reason : Text; marginReleased : Nat; day : Nat } {
    let ?instrument = r.nat() else return null; let ?reason = r.text() else return null; let ?marginReleased = r.nat() else return null; let ?day = r.nat() else return null; ?{ instrument; reason; marginReleased; day }
  };
  func wExp(w : C.Writer, x : { instrument : Nat; expiry : Nat; marginReleased : Nat; day : Nat }) { w.nat(x.instrument); w.nat(x.expiry); w.nat(x.marginReleased); w.nat(x.day) };
  func rExp(r : C.Reader) : ?{ instrument : Nat; expiry : Nat; marginReleased : Nat; day : Nat } {
    let ?instrument = r.nat() else return null; let ?expiry = r.nat() else return null; let ?marginReleased = r.nat() else return null; let ?day = r.nat() else return null; ?{ instrument; expiry; marginReleased; day }
  };
  func wEarned(w : C.Writer, x : { instrument : Nat; amount : Nat; cumulative : Nat; day : Nat }) { w.nat(x.instrument); w.nat(x.amount); w.nat(x.cumulative); w.nat(x.day) };
  func rEarned(r : C.Reader) : ?{ instrument : Nat; amount : Nat; cumulative : Nat; day : Nat } {
    let ?instrument = r.nat() else return null; let ?amount = r.nat() else return null; let ?cumulative = r.nat() else return null; let ?day = r.nat() else return null; ?{ instrument; amount; cumulative; day }
  };

  public func writeEvent(w : C.Writer, e : TrT.TradeEvent) {
    switch (e) {
      case (#policySet(p)) { w.byte(0x01); writePolicy(w, p) };
      case (#lcIssued(x)) { w.byte(0x02); writeLc(w, x.lc); w.nat(x.amount); w.text(x.currency); w.nat(x.expiry); w.text(x.placeOfExpiry); w.nat(x.margin); w.nat(x.commission); w.text(x.book); w.nat(x.day) };
      case (#lcAdvised(x)) { w.byte(0x03); writeLc(w, x.lc); w.nat(x.amount); w.text(x.currency); w.nat(x.expiry); w.text(x.placeOfExpiry); w.blob(x.messageHash); w.bool(x.confirmed); w.nat(x.commission); w.text(x.book); w.nat(x.day) };
      case (#lcAmended(x)) { w.byte(0x04); wAmend(w, x) };
      case (#documentsPresented(x)) { w.byte(0x05); w.nat(x.instrument); w.nat(x.claim); writeDocumentRefs(w, x.documents); w.nat(x.amount); w.optNat(x.shipmentDate); w.nat(x.presentedOn); w.nat(x.deadline); w.nat(x.day) };
      case (#presentationExamined(x)) { w.byte(0x06); wExam(w, x) };
      case (#discrepanciesWaived(x)) { w.byte(0x07); w.nat(x.instrument); w.nat(x.claim); w.blob(x.applicantConsentHash); w.nat(x.day) };
      case (#presentationHonoured(x)) { w.byte(0x08); w.nat(x.instrument); w.nat(x.claim); w.nat(x.amount); writeHonour(w, x.honour); w.nat(x.fromMargin); w.nat(x.day) };
      case (#acceptanceMatured(x)) { w.byte(0x09); w.nat(x.instrument); w.nat(x.claim); w.nat(x.amount); w.nat(x.fromMargin); w.nat(x.day) };
      case (#lcClosed(x)) { w.byte(0x0A); wEnd(w, x) };
      case (#lcExpired(x)) { w.byte(0x0B); wExp(w, x) };
      case (#guaranteeIssued(x)) { w.byte(0x0C); writeGuarantee(w, x.guarantee); w.text(x.wordingText); w.nat(x.amount); w.text(x.currency); w.nat(x.expiry); w.nat(x.margin); w.nat(x.commission); w.text(x.book); w.nat(x.day) };
      case (#guaranteeAmended(x)) { w.byte(0x0D); wAmend(w, x) };
      case (#demandRecorded(x)) { w.byte(0x0E); w.nat(x.instrument); w.nat(x.claim); writeDocumentRef(w, x.demand); w.nat(x.amount); w.bool(x.supportingStatement); w.nat(x.presentedOn); w.nat(x.deadline); w.nat(x.day) };
      case (#demandExamined(x)) { w.byte(0x0F); wExam(w, x) };
      case (#demandPaid(x)) { w.byte(0x10); w.nat(x.instrument); w.nat(x.claim); w.nat(x.amount); w.nat(x.fromMargin); w.nat(x.fromAccount); w.optNat(x.claimAccount); w.nat(x.day) };
      case (#guaranteeReduced(x)) { w.byte(0x11); w.nat(x.instrument); w.nat(x.from); w.nat(x.to); w.nat(x.day) };
      case (#guaranteeReleased(x)) { w.byte(0x12); wEnd(w, x) };
      case (#guaranteeExpired(x)) { w.byte(0x13); wExp(w, x) };
      case (#collectionRegistered(x)) { w.byte(0x14); writeCollection(w, x.collection); w.nat(x.amount); w.text(x.currency); w.text(x.book); w.nat(x.day) };
      case (#collectionPresented(x)) { w.byte(0x15); w.nat(x.instrument); w.nat(x.claim); w.nat(x.presentedOn); w.nat(x.day) };
      case (#collectionAccepted(x)) { w.byte(0x16); w.nat(x.instrument); w.nat(x.claim); w.nat(x.maturity); w.nat(x.day) };
      case (#collectionPaid(x)) { w.byte(0x17); w.nat(x.instrument); w.nat(x.claim); w.nat(x.amount); w.nat(x.commission); w.nat(x.day) };
      case (#collectionProtested(x)) { w.byte(0x18); w.nat(x.instrument); w.nat(x.claim); w.text(x.reason); w.nat(x.day) };
      case (#collectionReturned(x)) { w.byte(0x19); w.nat(x.instrument); w.text(x.reason); w.nat(x.day) };
      case (#billDiscounted(x)) { w.byte(0x1A); writeBill(w, x.bill); w.nat(x.face); w.text(x.currency); w.nat(x.maturity); w.nat(x.discount); w.nat(x.proceeds); w.text(x.book); w.nat(x.day) };
      case (#billRediscounted(x)) { w.byte(0x1B); w.nat(x.instrument); w.text(x.to); w.nat(x.amount); w.nat(x.day) };
      case (#billMatured(x)) { w.byte(0x1C); w.nat(x.instrument); w.nat(x.face); w.nat(x.day) };
      case (#billDishonoured(x)) { w.byte(0x1D); w.nat(x.instrument); w.nat(x.face); w.nat(x.chargedBack); w.nat(x.day) };
      case (#tradeMessageRecorded(x)) { w.byte(0x1E); w.nat(x.instrument); w.nat(x.seq); writeMessageKind(w, x.kind); writeDirection(w, x.direction); w.blob(x.hash); w.nat(x.day) };
      case (#commissionEarned(x)) { w.byte(0x1F); wEarned(w, x) };
      case (#discountEarned(x)) { w.byte(0x20); wEarned(w, x) };
    }
  };

  public func readEvent(r : C.Reader) : ?TrT.TradeEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 { let ?p = readPolicy(r) else return null; ?#policySet(p) };
      case 0x02 {
        let ?lc = readLc(r) else return null; let ?amount = r.nat() else return null; let ?currency = r.text() else return null; let ?expiry = r.nat() else return null;
        let ?placeOfExpiry = r.text() else return null; let ?margin = r.nat() else return null; let ?commission = r.nat() else return null; let ?book = r.text() else return null; let ?day = r.nat() else return null;
        ?#lcIssued({ lc; amount; currency; expiry; placeOfExpiry; margin; commission; book; day })
      };
      case 0x03 {
        let ?lc = readLc(r) else return null; let ?amount = r.nat() else return null; let ?currency = r.text() else return null; let ?expiry = r.nat() else return null;
        let ?placeOfExpiry = r.text() else return null; let ?messageHash = r.blob() else return null; let ?confirmed = r.bool() else return null; let ?commission = r.nat() else return null; let ?book = r.text() else return null; let ?day = r.nat() else return null;
        ?#lcAdvised({ lc; amount; currency; expiry; placeOfExpiry; messageHash; confirmed; commission; book; day })
      };
      case 0x04 { let ?x = rAmend(r) else return null; ?#lcAmended(x) };
      case 0x05 {
        let ?instrument = r.nat() else return null; let ?claim = r.nat() else return null; let ?documents = readDocumentRefs(r) else return null; let ?amount = r.nat() else return null;
        let ?shipmentDate = r.optNat() else return null; let ?presentedOn = r.nat() else return null; let ?deadline = r.nat() else return null; let ?day = r.nat() else return null;
        ?#documentsPresented({ instrument; claim; documents; amount; shipmentDate; presentedOn; deadline; day })
      };
      case 0x06 { let ?x = rExam(r) else return null; ?#presentationExamined(x) };
      case 0x07 { let ?instrument = r.nat() else return null; let ?claim = r.nat() else return null; let ?applicantConsentHash = r.blob() else return null; let ?day = r.nat() else return null; ?#discrepanciesWaived({ instrument; claim; applicantConsentHash; day }) };
      case 0x08 { let ?instrument = r.nat() else return null; let ?claim = r.nat() else return null; let ?amount = r.nat() else return null; let ?honour = readHonour(r) else return null; let ?fromMargin = r.nat() else return null; let ?day = r.nat() else return null; ?#presentationHonoured({ instrument; claim; amount; honour; fromMargin; day }) };
      case 0x09 { let ?instrument = r.nat() else return null; let ?claim = r.nat() else return null; let ?amount = r.nat() else return null; let ?fromMargin = r.nat() else return null; let ?day = r.nat() else return null; ?#acceptanceMatured({ instrument; claim; amount; fromMargin; day }) };
      case 0x0A { let ?x = rEnd(r) else return null; ?#lcClosed(x) };
      case 0x0B { let ?x = rExp(r) else return null; ?#lcExpired(x) };
      case 0x0C {
        let ?guarantee = readGuarantee(r) else return null; let ?wordingText = r.text() else return null; let ?amount = r.nat() else return null; let ?currency = r.text() else return null; let ?expiry = r.nat() else return null;
        let ?margin = r.nat() else return null; let ?commission = r.nat() else return null; let ?book = r.text() else return null; let ?day = r.nat() else return null;
        ?#guaranteeIssued({ guarantee; wordingText; amount; currency; expiry; margin; commission; book; day })
      };
      case 0x0D { let ?x = rAmend(r) else return null; ?#guaranteeAmended(x) };
      case 0x0E {
        let ?instrument = r.nat() else return null; let ?claim = r.nat() else return null; let ?demand = readDocumentRef(r) else return null; let ?amount = r.nat() else return null;
        let ?supportingStatement = r.bool() else return null; let ?presentedOn = r.nat() else return null; let ?deadline = r.nat() else return null; let ?day = r.nat() else return null;
        ?#demandRecorded({ instrument; claim; demand; amount; supportingStatement; presentedOn; deadline; day })
      };
      case 0x0F { let ?x = rExam(r) else return null; ?#demandExamined(x) };
      case 0x10 {
        let ?instrument = r.nat() else return null; let ?claim = r.nat() else return null; let ?amount = r.nat() else return null; let ?fromMargin = r.nat() else return null;
        let ?fromAccount = r.nat() else return null; let ?claimAccount = r.optNat() else return null; let ?day = r.nat() else return null;
        ?#demandPaid({ instrument; claim; amount; fromMargin; fromAccount; claimAccount; day })
      };
      case 0x11 { let ?instrument = r.nat() else return null; let ?from = r.nat() else return null; let ?to = r.nat() else return null; let ?day = r.nat() else return null; ?#guaranteeReduced({ instrument; from; to; day }) };
      case 0x12 { let ?x = rEnd(r) else return null; ?#guaranteeReleased(x) };
      case 0x13 { let ?x = rExp(r) else return null; ?#guaranteeExpired(x) };
      case 0x14 { let ?collection = readCollection(r) else return null; let ?amount = r.nat() else return null; let ?currency = r.text() else return null; let ?book = r.text() else return null; let ?day = r.nat() else return null; ?#collectionRegistered({ collection; amount; currency; book; day }) };
      case 0x15 { let ?instrument = r.nat() else return null; let ?claim = r.nat() else return null; let ?presentedOn = r.nat() else return null; let ?day = r.nat() else return null; ?#collectionPresented({ instrument; claim; presentedOn; day }) };
      case 0x16 { let ?instrument = r.nat() else return null; let ?claim = r.nat() else return null; let ?maturity = r.nat() else return null; let ?day = r.nat() else return null; ?#collectionAccepted({ instrument; claim; maturity; day }) };
      case 0x17 { let ?instrument = r.nat() else return null; let ?claim = r.nat() else return null; let ?amount = r.nat() else return null; let ?commission = r.nat() else return null; let ?day = r.nat() else return null; ?#collectionPaid({ instrument; claim; amount; commission; day }) };
      case 0x18 { let ?instrument = r.nat() else return null; let ?claim = r.nat() else return null; let ?reason = r.text() else return null; let ?day = r.nat() else return null; ?#collectionProtested({ instrument; claim; reason; day }) };
      case 0x19 { let ?instrument = r.nat() else return null; let ?reason = r.text() else return null; let ?day = r.nat() else return null; ?#collectionReturned({ instrument; reason; day }) };
      case 0x1A {
        let ?bill = readBill(r) else return null; let ?face = r.nat() else return null; let ?currency = r.text() else return null; let ?maturity = r.nat() else return null;
        let ?discount = r.nat() else return null; let ?proceeds = r.nat() else return null; let ?book = r.text() else return null; let ?day = r.nat() else return null;
        ?#billDiscounted({ bill; face; currency; maturity; discount; proceeds; book; day })
      };
      case 0x1B { let ?instrument = r.nat() else return null; let ?to = r.text() else return null; let ?amount = r.nat() else return null; let ?day = r.nat() else return null; ?#billRediscounted({ instrument; to; amount; day }) };
      case 0x1C { let ?instrument = r.nat() else return null; let ?face = r.nat() else return null; let ?day = r.nat() else return null; ?#billMatured({ instrument; face; day }) };
      case 0x1D { let ?instrument = r.nat() else return null; let ?face = r.nat() else return null; let ?chargedBack = r.nat() else return null; let ?day = r.nat() else return null; ?#billDishonoured({ instrument; face; chargedBack; day }) };
      case 0x1E {
        let ?instrument = r.nat() else return null; let ?seq = r.nat() else return null; let ?kind = readMessageKind(r) else return null; let ?direction = readDirection(r) else return null;
        let ?hash = r.blob() else return null; let ?day = r.nat() else return null;
        ?#tradeMessageRecorded({ instrument; seq; kind; direction; hash; day })
      };
      case 0x1F { let ?x = rEarned(r) else return null; ?#commissionEarned(x) };
      case 0x20 { let ?x = rEarned(r) else return null; ?#discountEarned(x) };
      case _ null;
    }
  };
}
