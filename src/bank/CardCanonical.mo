/// CardCanonical.mo; the canonical bytes of the cards vocabulary (cards): the policy, schemes and their rules,
/// products, controls, authorization requests (the bytes the connector signs), decisions, clearing items, and the
/// events. `BankCanonical` calls these for the commands (extension tag 0xEF, second byte 0x30..) and the event (0x56).

import List "mo:core/List";
import Int "mo:core/Int";

import C "mo:journal/Canonical";

import CT "CardTypes";
import PayT "PaymentsTypes";

module {

  func wInt(w : C.Writer, i : Int) { w.byte(if (i < 0) 1 else 0); w.nat(Int.abs(i)) };
  func rInt(r : C.Reader) : ?Int { let ?neg = r.byte() else return null; let ?m = r.nat() else return null; if (neg == 1) ?(-m) else ?m };
  func wNats(w : C.Writer, xs : [Nat]) { w.len16(xs.size()); for (x in xs.vals()) w.nat(x) };
  func rNats(r : C.Reader) : ?[Nat] {
    let ?n = r.len16() else return null;
    let out = List.empty<Nat>();
    var i = 0;
    while (i < n) { let ?x = r.nat() else return null; List.add(out, x); i += 1 };
    ?List.toArray(out)
  };
  func wOptBool(w : C.Writer, b : ?Bool) { switch (b) { case null w.byte(0); case (?true) w.byte(1); case (?false) w.byte(2) } };
  func rOptBool(r : C.Reader) : ??Bool { switch (r.byte()) { case (?0) ?null; case (?1) ??true; case (?2) ??false; case (_) null } };
  func wOptText(w : C.Writer, t : ?Text) { switch (t) { case null w.byte(0); case (?x) { w.byte(1); w.text(x) } } };
  func rOptText(r : C.Reader) : ??Text { switch (r.byte()) { case (?0) ?null; case (?1) { let ?x = r.text() else return null; ??x }; case (_) null } };
  func wSigScheme(w : C.Writer, s : PayT.SignatureScheme) { w.byte(switch (s) { case (#none) 0; case (#mayo2) 1; case (#mldsa44) 2 }) };
  func rSigScheme(r : C.Reader) : ?PayT.SignatureScheme { switch (r.byte()) { case (?0) ?#none; case (?1) ?#mayo2; case (?2) ?#mldsa44; case (_) null } };

  public func policyTexts(p : CT.Policy) : [Text] { [p.disputeSuspense, p.interchangeIncome, p.schemeFees, p.fraudLosses, p.cardFeeIncome] };
  public func writePolicy(w : C.Writer, p : CT.Policy) { for (t in policyTexts(p).vals()) w.text(t); w.nat(p.provisionalCreditCeiling); w.nat(p.clearingTolerance); w.nat(p.stanReplayDays) };
  public func readPolicy(r : C.Reader) : ?CT.Policy {
    let ?disputeSuspense = r.text() else return null; let ?interchangeIncome = r.text() else return null; let ?schemeFees = r.text() else return null; let ?fraudLosses = r.text() else return null; let ?cardFeeIncome = r.text() else return null;
    let ?provisionalCreditCeiling = r.nat() else return null; let ?clearingTolerance = r.nat() else return null; let ?stanReplayDays = r.nat() else return null;
    ?{ disputeSuspense; interchangeIncome; schemeFees; fraudLosses; cardFeeIncome; provisionalCreditCeiling; clearingTolerance; stanReplayDays }
  };
  public func writeRules(w : C.Writer, x : CT.SchemeRules) {
    w.text(x.source); w.len16(x.interchange.size()); for (b in x.interchange.vals()) { w.nat(b.mccFrom); w.nat(b.mccTo); w.nat(b.bps); w.nat(b.fixed) };
    w.nat(x.floorLimit); w.nat(x.holdDays);
    w.len16(x.reasons.size()); for (rr in x.reasons.vals()) { w.text(rr.code); w.text(rr.description); w.nat(rr.chargebackDays); w.nat(rr.representmentDays); w.nat(rr.preArbitrationDays) };
    w.nat(x.feeBps);
  };
  public func readRules(r : C.Reader) : ?CT.SchemeRules {
    let ?source = r.text() else return null;
    let ?nb = r.len16() else return null;
    let bands = List.empty<CT.InterchangeBand>();
    var i = 0;
    while (i < nb) { let ?mccFrom = r.nat() else return null; let ?mccTo = r.nat() else return null; let ?bps = r.nat() else return null; let ?fixed = r.nat() else return null; List.add(bands, { mccFrom; mccTo; bps; fixed }); i += 1 };
    let ?floorLimit = r.nat() else return null; let ?holdDays = r.nat() else return null;
    let ?nr = r.len16() else return null;
    let reasons = List.empty<CT.ReasonRule>();
    i := 0;
    while (i < nr) { let ?code = r.text() else return null; let ?description = r.text() else return null; let ?chargebackDays = r.nat() else return null; let ?representmentDays = r.nat() else return null; let ?preArbitrationDays = r.nat() else return null; List.add(reasons, { code; description; chargebackDays; representmentDays; preArbitrationDays }); i += 1 };
    let ?feeBps = r.nat() else return null;
    ?{ source; interchange = List.toArray(bands); floorLimit; holdDays; reasons = List.toArray(reasons); feeBps }
  };
  public func writeScheme(w : C.Writer, s : CT.Scheme) { w.text(s.id); w.text(s.name); w.text(s.settlementAccount); w.text(s.settlementCurrency); writeRules(w, s.rules); wSigScheme(w, s.connectorScheme); w.blob(s.connectorKey) };
  public func readScheme(r : C.Reader) : ?CT.Scheme {
    let ?id = r.text() else return null; let ?name = r.text() else return null; let ?settlementAccount = r.text() else return null; let ?settlementCurrency = r.text() else return null; let ?rules = readRules(r) else return null;
    let ?connectorScheme = rSigScheme(r) else return null; let ?connectorKey = r.blob() else return null;
    ?{ id; name; settlementAccount; settlementCurrency; rules; connectorScheme; connectorKey }
  };
  func wChannels(w : C.Writer, c : CT.Channels) { w.bool(c.pos); w.bool(c.atm); w.bool(c.ecom); w.bool(c.contactless); w.bool(c.international) };
  func rChannels(r : C.Reader) : ?CT.Channels { let ?pos = r.bool() else return null; let ?atm = r.bool() else return null; let ?ecom = r.bool() else return null; let ?contactless = r.bool() else return null; let ?international = r.bool() else return null; ?{ pos; atm; ecom; contactless; international } };
  public func writeControls(w : C.Writer, c : CT.Controls) { w.nat(c.dailyLimit); w.nat(c.perTransactionLimit); wNats(w, c.mccAllow); wNats(w, c.mccDeny); wChannels(w, c.channels); w.nat(c.velocityCount); w.nat(c.velocityWindowMinutes) };
  public func readControls(r : C.Reader) : ?CT.Controls {
    let ?dailyLimit = r.nat() else return null; let ?perTransactionLimit = r.nat() else return null; let ?mccAllow = rNats(r) else return null; let ?mccDeny = rNats(r) else return null; let ?channels = rChannels(r) else return null;
    let ?velocityCount = r.nat() else return null; let ?velocityWindowMinutes = r.nat() else return null;
    ?{ dailyLimit; perTransactionLimit; mccAllow; mccDeny; channels; velocityCount; velocityWindowMinutes }
  };
  public func writeProduct(w : C.Writer, p : CT.CardProduct) {
    w.text(p.id); w.text(p.name);
    switch (p.kind) { case (#debit) w.byte(0); case (#credit(c)) { w.byte(1); w.nat(c.statementDay); w.nat(c.minimumDueBps); w.nat(c.minimumDueFloor); w.nat(c.graceDays) } };
    w.text(p.scheme); writeControls(w, p.bounds); w.nat(p.issueFee); w.nat(p.replacementFee); w.nat(p.expiryMonths);
  };
  public func readProduct(r : C.Reader) : ?CT.CardProduct {
    let ?id = r.text() else return null; let ?name = r.text() else return null;
    let kind : CT.CardKind = switch (r.byte()) {
      case (?0) #debit;
      case (?1) { let ?statementDay = r.nat() else return null; let ?minimumDueBps = r.nat() else return null; let ?minimumDueFloor = r.nat() else return null; let ?graceDays = r.nat() else return null; #credit({ statementDay; minimumDueBps; minimumDueFloor; graceDays }) };
      case (_) return null;
    };
    let ?scheme = r.text() else return null; let ?bounds = readControls(r) else return null; let ?issueFee = r.nat() else return null; let ?replacementFee = r.nat() else return null; let ?expiryMonths = r.nat() else return null;
    ?{ id; name; kind; scheme; bounds; issueFee; replacementFee; expiryMonths }
  };
  public func writeForm(w : C.Writer, f : CT.Form) { w.byte(switch (f) { case (#physical) 0; case (#virtual) 1 }) };
  public func readForm(r : C.Reader) : ?CT.Form { switch (r.byte()) { case (?0) ?#physical; case (?1) ?#virtual; case (_) null } };
  public func writeBlockReason(w : C.Writer, x : CT.BlockReason) { switch (x) { case (#customer) w.byte(0); case (#lost) w.byte(1); case (#stolen) w.byte(2); case (#fraud) w.byte(3); case (#bank(t)) { w.byte(4); w.text(t) } } };
  public func readBlockReason(r : C.Reader) : ?CT.BlockReason { switch (r.byte()) { case (?0) ?#customer; case (?1) ?#lost; case (?2) ?#stolen; case (?3) ?#fraud; case (?4) { let ?t = r.text() else return null; ?#bank(t) }; case (_) null } };
  public func writeReplaceReason(w : C.Writer, x : CT.ReplaceReason) { w.byte(switch (x) { case (#lost) 0; case (#stolen) 1; case (#damaged) 2; case (#expired) 3 }) };
  public func readReplaceReason(r : C.Reader) : ?CT.ReplaceReason { switch (r.byte()) { case (?0) ?#lost; case (?1) ?#stolen; case (?2) ?#damaged; case (?3) ?#expired; case (_) null } };
  func wChannel(w : C.Writer, c : CT.Channel) { w.byte(switch (c) { case (#pos) 0; case (#atm) 1; case (#ecom) 2; case (#contactless) 3 }) };
  func rChannel(r : C.Reader) : ?CT.Channel { switch (r.byte()) { case (?0) ?#pos; case (?1) ?#atm; case (?2) ?#ecom; case (?3) ?#contactless; case (_) null } };
  func wKind(w : C.Writer, k : CT.AuthKind) { switch (k) { case (#purchase) w.byte(0); case (#preAuthorization) w.byte(1); case (#incremental(o)) { w.byte(2); w.nat(o.of) }; case (#completion(o)) { w.byte(3); w.nat(o.of) }; case (#refund) w.byte(4); case (#reversal(o)) { w.byte(5); w.nat(o.of) } } };
  func rKind(r : C.Reader) : ?CT.AuthKind {
    switch (r.byte()) {
      case (?0) ?#purchase; case (?1) ?#preAuthorization; case (?2) { let ?of = r.nat() else return null; ?#incremental({ of }) }; case (?3) { let ?of = r.nat() else return null; ?#completion({ of }) }; case (?4) ?#refund; case (?5) { let ?of = r.nat() else return null; ?#reversal({ of }) }; case (_) null;
    }
  };
  /// The request's bytes: what the connector signs and what the block records.
  public func writeRequest(w : C.Writer, q : CT.AuthRequest) {
    w.text("THEBES-BANK-CARD-AUTH-v1");
    w.blob(q.token); wKind(w, q.kind); w.nat(q.amount); w.text(q.currency); w.nat(q.mcc); w.blob(q.merchantHash); w.text(q.merchantCountry); w.text(q.acquirer);
    wChannel(w, q.channel); w.bool(q.cryptogramValid); wOptBool(w, q.pinVerified); w.text(q.stan); w.text(q.rrn); w.nat64(q.localTime);
  };
  public func readRequest(r : C.Reader) : ?CT.AuthRequest {
    let ?domain = r.text() else return null;
    if (domain != "THEBES-BANK-CARD-AUTH-v1") return null;
    let ?token = r.blob() else return null; let ?kind = rKind(r) else return null; let ?amount = r.nat() else return null; let ?currency = r.text() else return null; let ?mcc = r.nat() else return null;
    let ?merchantHash = r.blob() else return null; let ?merchantCountry = r.text() else return null; let ?acquirer = r.text() else return null; let ?channel = rChannel(r) else return null;
    let ?cryptogramValid = r.bool() else return null; let ?pinVerified = rOptBool(r) else return null; let ?stan = r.text() else return null; let ?rrn = r.text() else return null; let ?localTime = r.nat64() else return null;
    ?{ token; kind; amount; currency; mcc; merchantHash; merchantCountry; acquirer; channel; cryptogramValid; pinVerified; stan; rrn; localTime }
  };
  public func requestBytes(q : CT.AuthRequest) : Blob { let w = C.Writer(); writeRequest(w, q); w.toBlob() };
  func declineByte(d : CT.DeclineReason) : Nat8 {
    switch (d) {
      case (#unknownCard) 1; case (#cardNotActive) 2; case (#cardBlocked) 3; case (#cardExpired) 4; case (#mccDenied) 5; case (#channelDenied) 6; case (#internationalDenied) 7; case (#overPerTransaction) 8; case (#overDailyLimit) 9; case (#velocity) 10;
      case (#insufficientFunds) 11; case (#cryptogramInvalid) 12; case (#pinFailed) 13; case (#duplicate) 14; case (#unknownOriginal) 15; case (#originalNotOpen) 16; case (#amountExceedsOriginal) 17; case (#currencyMismatch) 18; case (#schemeMismatch) 19;
    }
  };
  func declineOf(b : Nat8) : ?CT.DeclineReason {
    switch (b) {
      case 1 ?#unknownCard; case 2 ?#cardNotActive; case 3 ?#cardBlocked; case 4 ?#cardExpired; case 5 ?#mccDenied; case 6 ?#channelDenied; case 7 ?#internationalDenied; case 8 ?#overPerTransaction; case 9 ?#overDailyLimit; case 10 ?#velocity;
      case 11 ?#insufficientFunds; case 12 ?#cryptogramInvalid; case 13 ?#pinFailed; case 14 ?#duplicate; case 15 ?#unknownOriginal; case 16 ?#originalNotOpen; case 17 ?#amountExceedsOriginal; case 18 ?#currencyMismatch; case 19 ?#schemeMismatch; case _ null;
    }
  };
  public func writeDecision(w : C.Writer, d : CT.Decision) { switch (d) { case (#approved(a)) { w.byte(0); w.text(a.authCode); w.optNat(a.hold); w.nat(a.amount) }; case (#declined(r)) { w.byte(1); w.byte(declineByte(r)) } } };
  public func readDecision(r : C.Reader) : ?CT.Decision {
    switch (r.byte()) {
      case (?0) { let ?authCode = r.text() else return null; let ?hold = r.optNat() else return null; let ?amount = r.nat() else return null; ?#approved({ authCode; hold; amount }) };
      case (?1) { let ?b = r.byte() else return null; let ?d = declineOf(b) else return null; ?#declined(d) };
      case (_) null;
    }
  };
  public func writeItem(w : C.Writer, x : CT.ClearingItem) { wOptText(w, x.authCode); w.blob(x.token); w.nat(x.amount); w.text(x.currency); w.nat(x.mcc); w.blob(x.merchantHash); w.text(x.acquirer); w.text(x.stan); w.text(x.rrn); w.nat(x.day); w.bool(x.refund) };
  public func readItem(r : C.Reader) : ?CT.ClearingItem {
    let ?authCode = rOptText(r) else return null; let ?token = r.blob() else return null; let ?amount = r.nat() else return null; let ?currency = r.text() else return null; let ?mcc = r.nat() else return null; let ?merchantHash = r.blob() else return null;
    let ?acquirer = r.text() else return null; let ?stan = r.text() else return null; let ?rrn = r.text() else return null; let ?day = r.nat() else return null; let ?refund = r.bool() else return null;
    ?{ authCode; token; amount; currency; mcc; merchantHash; acquirer; stan; rrn; day; refund }
  };
  public func writeItems(w : C.Writer, xs : [CT.ClearingItem]) { w.len16(xs.size()); for (x in xs.vals()) writeItem(w, x) };
  public func readItems(r : C.Reader) : ?[CT.ClearingItem] {
    let ?n = r.len16() else return null;
    let out = List.empty<CT.ClearingItem>();
    var i = 0;
    while (i < n) { let ?x = readItem(r) else return null; List.add(out, x); i += 1 };
    ?List.toArray(out)
  };
  /// The batch's bytes the connector signs: the scheme, the hash and the items.
  public func batchBytes(scheme : Text, batch : Blob, items : [CT.ClearingItem]) : Blob { let w = C.Writer(); w.text("THEBES-BANK-CARD-CLEARING-v1"); w.text(scheme); w.blob(batch); writeItems(w, items); w.toBlob() };
  func wOutcome(w : C.Writer, o : CT.ClearingOutcome) {
    switch (o) { case (#postedAgainstHold(h)) { w.byte(0); w.nat(h.auth); w.nat(h.hold); wInt(w, h.difference) }; case (#postedDirect(d)) { w.byte(1); w.bool(d.belowFloor) }; case (#exception(e)) { w.byte(2); w.text(e.reason) } }
  };
  func rOutcome(r : C.Reader) : ?CT.ClearingOutcome {
    switch (r.byte()) {
      case (?0) { let ?auth = r.nat() else return null; let ?hold = r.nat() else return null; let ?difference = rInt(r) else return null; ?#postedAgainstHold({ auth; hold; difference }) };
      case (?1) { let ?belowFloor = r.bool() else return null; ?#postedDirect({ belowFloor }) };
      case (?2) { let ?reason = r.text() else return null; ?#exception({ reason }) };
      case (_) null;
    }
  };
  func wStage(w : C.Writer, s : CT.DisputeStage) { w.byte(switch (s) { case (#opened) 0; case (#provisionalCredit) 1; case (#chargeback) 2; case (#representment) 3; case (#preArbitration) 4; case (#resolved) 5 }) };
  func rStage(r : C.Reader) : ?CT.DisputeStage { switch (r.byte()) { case (?0) ?#opened; case (?1) ?#provisionalCredit; case (?2) ?#chargeback; case (?3) ?#representment; case (?4) ?#preArbitration; case (?5) ?#resolved; case (_) null } };
  public func writeOutcome(w : C.Writer, o : CT.Outcome) { w.byte(switch (o) { case (#cardholder) 0; case (#merchant) 1 }) };
  public func readOutcome(r : C.Reader) : ?CT.Outcome { switch (r.byte()) { case (?0) ?#cardholder; case (?1) ?#merchant; case (_) null } };

  public func writeEvent(w : C.Writer, ev : CT.CardEvent) {
    switch (ev) {
      case (#policySet(p)) { w.byte(0x01); writePolicy(w, p) };
      case (#schemeDeclared(x)) { w.byte(0x02); writeScheme(w, x.scheme); w.nat(x.day) };
      case (#productDefined(x)) { w.byte(0x03); writeProduct(w, x.product); w.nat(x.day) };
      case (#cardIssued(x)) { w.byte(0x04); w.blob(x.tokenHash); w.nat(x.account); w.nat(x.party); w.text(x.product); writeForm(w, x.form); w.nat(x.expiryMonth); writeControls(w, x.controls); w.nat(x.day); w.optNat(x.replaces) };
      case (#cardActivated(x)) { w.byte(0x05); w.nat(x.card); w.nat(x.day) };
      case (#cardBlocked(x)) { w.byte(0x06); w.nat(x.card); writeBlockReason(w, x.reason); w.nat(x.day) };
      case (#cardUnblocked(x)) { w.byte(0x07); w.nat(x.card); w.nat(x.day) };
      case (#cardClosed(x)) { w.byte(0x08); w.nat(x.card); w.text(x.reason); w.nat(x.day) };
      case (#controlsSet(x)) { w.byte(0x09); w.nat(x.card); writeControls(w, x.controls); w.bool(x.byCustomer); w.nat(x.day) };
      case (#authorised(x)) { w.byte(0x0A); w.optNat(x.card); writeRequest(w, x.request); writeDecision(w, x.decision); w.nat(x.day) };
      case (#holdAdjusted(x)) { w.byte(0x0B); w.nat(x.auth); w.nat(x.from); w.nat(x.to); w.optNat(x.hold); w.text(x.kind); w.nat(x.day) };
      case (#holdExpired(x)) { w.byte(0x0C); w.nat(x.auth); w.nat(x.hold); w.nat(x.day) };
      case (#clearingRecorded(x)) { w.byte(0x0D); w.text(x.scheme); w.blob(x.batch); w.nat(x.items); w.nat(x.posted); w.nat(x.exceptions); w.nat(x.interchange); w.nat(x.fees); w.nat(x.day) };
      case (#cleared(x)) { w.byte(0x0E); w.text(x.scheme); w.blob(x.batch); w.optNat(x.card); writeItem(w, x.item); wOutcome(w, x.outcome); w.nat(x.interchange); w.nat(x.fee); w.optNat(x.posting); w.nat(x.day) };
      case (#disputeOpened(x)) { w.byte(0x0F); w.nat(x.transaction); w.nat(x.card); w.text(x.reason); w.nat(x.amount); w.nat(x.dueDay); w.nat(x.day) };
      case (#provisionalCredited(x)) { w.byte(0x10); w.nat(x.dispute); w.nat(x.amount); w.nat(x.day) };
      case (#chargebackRaised(x)) { w.byte(0x11); w.nat(x.dispute); w.text(x.schemeRef); w.nat(x.dueDay); w.nat(x.day) };
      case (#representmentRecorded(x)) { w.byte(0x12); w.nat(x.dispute); w.nat(x.dueDay); w.nat(x.day) };
      case (#preArbitrationRecorded(x)) { w.byte(0x13); w.nat(x.dispute); w.nat(x.dueDay); w.nat(x.day) };
      case (#disputeResolved(x)) { w.byte(0x14); w.nat(x.dispute); writeOutcome(w, x.outcome); w.nat(x.finalAmount); w.nat(x.day) };
      case (#disputeStepDue(x)) { w.byte(0x15); w.nat(x.dispute); wStage(w, x.stage); w.nat(x.dueDay); w.nat(x.day) };
      case (#fraudMarked(x)) { w.byte(0x16); w.nat(x.transaction); w.nat(x.card); w.bool(x.blocked); w.nat(x.day) };
      case (#statementCut(x)) { w.byte(0x17); w.nat(x.card); w.nat(x.cycleEnd); wInt(w, x.balance); w.nat(x.minimumDue); w.nat(x.dueDay); w.nat(x.purchases); w.nat(x.payments); w.nat(x.interest); w.nat(x.day) };
    }
  };
  public func readEvent(r : C.Reader) : ?CT.CardEvent {
    switch (r.byte()) {
      case (?0x01) { let ?p = readPolicy(r) else return null; ?#policySet(p) };
      case (?0x02) { let ?scheme = readScheme(r) else return null; let ?day = r.nat() else return null; ?#schemeDeclared({ scheme; day }) };
      case (?0x03) { let ?product = readProduct(r) else return null; let ?day = r.nat() else return null; ?#productDefined({ product; day }) };
      case (?0x04) {
        let ?tokenHash = r.blob() else return null; let ?account = r.nat() else return null; let ?party = r.nat() else return null; let ?product = r.text() else return null; let ?form = readForm(r) else return null; let ?expiryMonth = r.nat() else return null;
        let ?controls = readControls(r) else return null; let ?day = r.nat() else return null; let ?replaces = r.optNat() else return null;
        ?#cardIssued({ tokenHash; account; party; product; form; expiryMonth; controls; day; replaces })
      };
      case (?0x05) { let ?card = r.nat() else return null; let ?day = r.nat() else return null; ?#cardActivated({ card; day }) };
      case (?0x06) { let ?card = r.nat() else return null; let ?reason = readBlockReason(r) else return null; let ?day = r.nat() else return null; ?#cardBlocked({ card; reason; day }) };
      case (?0x07) { let ?card = r.nat() else return null; let ?day = r.nat() else return null; ?#cardUnblocked({ card; day }) };
      case (?0x08) { let ?card = r.nat() else return null; let ?reason = r.text() else return null; let ?day = r.nat() else return null; ?#cardClosed({ card; reason; day }) };
      case (?0x09) { let ?card = r.nat() else return null; let ?controls = readControls(r) else return null; let ?byCustomer = r.bool() else return null; let ?day = r.nat() else return null; ?#controlsSet({ card; controls; byCustomer; day }) };
      case (?0x0A) { let ?card = r.optNat() else return null; let ?request = readRequest(r) else return null; let ?decision = readDecision(r) else return null; let ?day = r.nat() else return null; ?#authorised({ card; request; decision; day }) };
      case (?0x0B) { let ?auth = r.nat() else return null; let ?from = r.nat() else return null; let ?to = r.nat() else return null; let ?hold = r.optNat() else return null; let ?kind = r.text() else return null; let ?day = r.nat() else return null; ?#holdAdjusted({ auth; from; to; hold; kind; day }) };
      case (?0x0C) { let ?auth = r.nat() else return null; let ?hold = r.nat() else return null; let ?day = r.nat() else return null; ?#holdExpired({ auth; hold; day }) };
      case (?0x0D) { let ?scheme = r.text() else return null; let ?batch = r.blob() else return null; let ?items = r.nat() else return null; let ?posted = r.nat() else return null; let ?exceptions = r.nat() else return null; let ?interchange = r.nat() else return null; let ?fees = r.nat() else return null; let ?day = r.nat() else return null; ?#clearingRecorded({ scheme; batch; items; posted; exceptions; interchange; fees; day }) };
      case (?0x0E) { let ?scheme = r.text() else return null; let ?batch = r.blob() else return null; let ?card = r.optNat() else return null; let ?item = readItem(r) else return null; let ?outcome = rOutcome(r) else return null; let ?interchange = r.nat() else return null; let ?fee = r.nat() else return null; let ?posting = r.optNat() else return null; let ?day = r.nat() else return null; ?#cleared({ scheme; batch; card; item; outcome; interchange; fee; posting; day }) };
      case (?0x0F) { let ?transaction = r.nat() else return null; let ?card = r.nat() else return null; let ?reason = r.text() else return null; let ?amount = r.nat() else return null; let ?dueDay = r.nat() else return null; let ?day = r.nat() else return null; ?#disputeOpened({ transaction; card; reason; amount; dueDay; day }) };
      case (?0x10) { let ?dispute = r.nat() else return null; let ?amount = r.nat() else return null; let ?day = r.nat() else return null; ?#provisionalCredited({ dispute; amount; day }) };
      case (?0x11) { let ?dispute = r.nat() else return null; let ?schemeRef = r.text() else return null; let ?dueDay = r.nat() else return null; let ?day = r.nat() else return null; ?#chargebackRaised({ dispute; schemeRef; dueDay; day }) };
      case (?0x12) { let ?dispute = r.nat() else return null; let ?dueDay = r.nat() else return null; let ?day = r.nat() else return null; ?#representmentRecorded({ dispute; dueDay; day }) };
      case (?0x13) { let ?dispute = r.nat() else return null; let ?dueDay = r.nat() else return null; let ?day = r.nat() else return null; ?#preArbitrationRecorded({ dispute; dueDay; day }) };
      case (?0x14) { let ?dispute = r.nat() else return null; let ?outcome = readOutcome(r) else return null; let ?finalAmount = r.nat() else return null; let ?day = r.nat() else return null; ?#disputeResolved({ dispute; outcome; finalAmount; day }) };
      case (?0x15) { let ?dispute = r.nat() else return null; let ?stage = rStage(r) else return null; let ?dueDay = r.nat() else return null; let ?day = r.nat() else return null; ?#disputeStepDue({ dispute; stage; dueDay; day }) };
      case (?0x16) { let ?transaction = r.nat() else return null; let ?card = r.nat() else return null; let ?blocked = r.bool() else return null; let ?day = r.nat() else return null; ?#fraudMarked({ transaction; card; blocked; day }) };
      case (?0x17) { let ?card = r.nat() else return null; let ?cycleEnd = r.nat() else return null; let ?balance = rInt(r) else return null; let ?minimumDue = r.nat() else return null; let ?dueDay = r.nat() else return null; let ?purchases = r.nat() else return null; let ?payments = r.nat() else return null; let ?interest = r.nat() else return null; let ?day = r.nat() else return null; ?#statementCut({ card; cycleEnd; balance; minimumDue; dueDay; purchases; payments; interest; day }) };
      case (_) null;
    }
  };
}
