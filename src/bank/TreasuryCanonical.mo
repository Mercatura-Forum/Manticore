/// TreasuryCanonical.mo — the canonical bytes of the treasury vocabulary (treasury): the policy, securities, curves,
/// limits, nostros, the deal kinds and their terms, statement entries, confirmation fields, and the events.
/// `BankCanonical` calls these for the commands (extension tag 0xEF, second byte 0x20..) and the event (0x55).

import Int "mo:core/Int";
import List "mo:core/List";

import C "mo:journal/Canonical";

import TT "TreasuryTypes";
import PC "ProductCanonical";

module {

  func wInt(w : C.Writer, i : Int) { w.byte(if (i < 0) 1 else 0); w.nat(Int.abs(i)) };
  func rInt(r : C.Reader) : ?Int { let ?neg = r.byte() else return null; let ?m = r.nat() else return null; if (neg == 1) ?(-m) else ?m };
  func wPoints(w : C.Writer, xs : [(Nat, Int)]) { w.len16(xs.size()); for ((t, v) in xs.vals()) { w.nat(t); wInt(w, v) } };
  func rPoints(r : C.Reader) : ?[(Nat, Int)] {
    let ?n = r.len16() else return null;
    let out = List.empty<(Nat, Int)>();
    var i = 0;
    while (i < n) { let ?t = r.nat() else return null; let ?v = rInt(r) else return null; List.add(out, (t, v)); i += 1 };
    ?List.toArray(out)
  };
  func wNats(w : C.Writer, xs : [Nat]) { w.len16(xs.size()); for (x in xs.vals()) w.nat(x) };
  func rNats(r : C.Reader) : ?[Nat] {
    let ?n = r.len16() else return null;
    let out = List.empty<Nat>();
    var i = 0;
    while (i < n) { let ?x = r.nat() else return null; List.add(out, x); i += 1 };
    ?List.toArray(out)
  };
  func wOptText(w : C.Writer, t : ?Text) { switch (t) { case null w.byte(0); case (?x) { w.byte(1); w.text(x) } } };
  func rOptText(r : C.Reader) : ??Text { switch (r.byte()) { case (?0) ?null; case (?1) { let ?x = r.text() else return null; ??x }; case (_) null } };
  func wOptPrincipal(w : C.Writer, p : ?Principal) { switch (p) { case null w.byte(0); case (?x) { w.byte(1); w.principal(x) } } };
  func rOptPrincipal(r : C.Reader) : ??Principal { switch (r.byte()) { case (?0) ?null; case (?1) { let ?x = r.principal() else return null; ??x }; case (_) null } };
  func wDirection(w : C.Writer, d : TT.Direction) { w.byte(switch (d) { case (#buy) 0; case (#sell) 1 }) };
  func rDirection(r : C.Reader) : ?TT.Direction { switch (r.byte()) { case (?0) ?#buy; case (?1) ?#sell; case (_) null } };

  public func policyTexts(p : TT.Policy) : [Text] {
    [p.mmPlacements, p.mmTakings, p.mmInterestReceivable, p.mmInterestPayable, p.mmInterestIncome, p.mmInterestExpense, p.fxForwardMark, p.irsMark, p.fxOptionValue,
     p.unrealisedTradingGain, p.unrealisedTradingLoss, p.realisedTradingGain, p.realisedTradingLoss, p.securitiesAmortisedCost, p.securitiesFvoci, p.securitiesFvtpl, p.fvociReserve,
     p.couponReceivable, p.couponIncome, p.amortisationIncome, p.amortisationExpense, p.nostroSuspense]
  };
  public func writePolicy(w : C.Writer, p : TT.Policy) {
    for (t in policyTexts(p).vals()) w.text(t);
    w.byte(switch (p.lotMethod) { case (#fifo) 0; case (#averageCost) 1 }); w.nat(p.confirmationDueDays); w.nat(p.breakAgeAlertDays); w.nat(p.maxCurvePoints);
  };
  public func readPolicy(r : C.Reader) : ?TT.Policy {
    let ?mmPlacements = r.text() else return null; let ?mmTakings = r.text() else return null; let ?mmInterestReceivable = r.text() else return null; let ?mmInterestPayable = r.text() else return null;
    let ?mmInterestIncome = r.text() else return null; let ?mmInterestExpense = r.text() else return null; let ?fxForwardMark = r.text() else return null; let ?irsMark = r.text() else return null; let ?fxOptionValue = r.text() else return null;
    let ?unrealisedTradingGain = r.text() else return null; let ?unrealisedTradingLoss = r.text() else return null; let ?realisedTradingGain = r.text() else return null; let ?realisedTradingLoss = r.text() else return null;
    let ?securitiesAmortisedCost = r.text() else return null; let ?securitiesFvoci = r.text() else return null; let ?securitiesFvtpl = r.text() else return null; let ?fvociReserve = r.text() else return null;
    let ?couponReceivable = r.text() else return null; let ?couponIncome = r.text() else return null; let ?amortisationIncome = r.text() else return null; let ?amortisationExpense = r.text() else return null; let ?nostroSuspense = r.text() else return null;
    let lotMethod : TT.LotMethod = switch (r.byte()) { case (?0) #fifo; case (?1) #averageCost; case (_) return null };
    let ?confirmationDueDays = r.nat() else return null; let ?breakAgeAlertDays = r.nat() else return null; let ?maxCurvePoints = r.nat() else return null;
    ?{ mmPlacements; mmTakings; mmInterestReceivable; mmInterestPayable; mmInterestIncome; mmInterestExpense; fxForwardMark; irsMark; fxOptionValue; unrealisedTradingGain; unrealisedTradingLoss; realisedTradingGain; realisedTradingLoss;
       securitiesAmortisedCost; securitiesFvoci; securitiesFvtpl; fvociReserve; couponReceivable; couponIncome; amortisationIncome; amortisationExpense; nostroSuspense; lotMethod; confirmationDueDays; breakAgeAlertDays; maxCurvePoints }
  };

  public func writeCounterparty(w : C.Writer, c : TT.Counterparty) { w.optNat(c.party); w.text(c.name); w.text(c.bic); w.text(c.lei) };
  public func readCounterparty(r : C.Reader) : ?TT.Counterparty { let ?party = r.optNat() else return null; let ?name = r.text() else return null; let ?bic = r.text() else return null; let ?lei = r.text() else return null; ?{ party; name; bic; lei } };
  func wCash(w : C.Writer, c : TT.CashAccount) { w.text(c.account); wOptText(w, c.sub) };
  func rCash(r : C.Reader) : ?TT.CashAccount { let ?account = r.text() else return null; let ?sub = rOptText(r) else return null; ?{ account; sub } };

  public func writeSecurityTerms(w : C.Writer, t : TT.SecurityTerms) { w.text(t.isin); w.text(t.issuer); w.text(t.currency); w.nat(t.couponBps); w.nat(t.couponsPerYear); PC.wConvention(w, t.dayCount); w.nat(t.issue); w.nat(t.maturity) };
  public func readSecurityTerms(r : C.Reader) : ?TT.SecurityTerms {
    let ?isin = r.text() else return null; let ?issuer = r.text() else return null; let ?currency = r.text() else return null; let ?couponBps = r.nat() else return null; let ?couponsPerYear = r.nat() else return null;
    let ?dayCount = PC.rConvention(r) else return null; let ?issue = r.nat() else return null; let ?maturity = r.nat() else return null;
    ?{ isin; issuer; currency; couponBps; couponsPerYear; dayCount; issue; maturity }
  };
  public func writeCurve(w : C.Writer, c : TT.Curve) {
    w.text(c.id); w.byte(switch (c.kind) { case (#zeroRates) 0; case (#forwardPoints) 1; case (#volatility) 2; case (#securityPrice) 3 }); w.text(c.currency); w.nat(c.day); wPoints(w, c.points); w.blob(c.source)
  };
  public func readCurve(r : C.Reader) : ?TT.Curve {
    let ?id = r.text() else return null;
    let kind : TT.CurveKind = switch (r.byte()) { case (?0) #zeroRates; case (?1) #forwardPoints; case (?2) #volatility; case (?3) #securityPrice; case (_) return null };
    let ?currency = r.text() else return null; let ?day = r.nat() else return null; let ?points = rPoints(r) else return null; let ?source = r.blob() else return null;
    ?{ id; kind; currency; day; points; source }
  };
  public func writeLimit(w : C.Writer, l : TT.Limit) {
    w.text(l.book); w.byte(switch (l.kind) { case (#counterpartyExposure) 0; case (#openFxPosition) 1; case (#tenorBucket) 2; case (#dv01) 3; case (#stopLoss) 4; case (#issuerConcentration) 5 }); w.text(l.currency); w.text(l.subject); w.nat(l.value)
  };
  public func readLimit(r : C.Reader) : ?TT.Limit {
    let ?book = r.text() else return null;
    let kind : TT.LimitKind = switch (r.byte()) { case (?0) #counterpartyExposure; case (?1) #openFxPosition; case (?2) #tenorBucket; case (?3) #dv01; case (?4) #stopLoss; case (?5) #issuerConcentration; case (_) return null };
    let ?currency = r.text() else return null; let ?subject = r.text() else return null; let ?value = r.nat() else return null;
    ?{ book; kind; currency; subject; value }
  };
  public func writeNostro(w : C.Writer, n : TT.Nostro) { w.text(n.id); w.text(n.account); wOptText(w, n.sub); w.text(n.currency); writeCounterparty(w, n.correspondent); w.text(n.iban); w.nat(n.valueDateToleranceDays) };
  public func readNostro(r : C.Reader) : ?TT.Nostro {
    let ?id = r.text() else return null; let ?account = r.text() else return null; let ?sub = rOptText(r) else return null; let ?currency = r.text() else return null;
    let ?correspondent = readCounterparty(r) else return null; let ?iban = r.text() else return null; let ?valueDateToleranceDays = r.nat() else return null;
    ?{ id; account; sub; currency; correspondent; iban; valueDateToleranceDays }
  };

  func wForward(w : C.Writer, f : TT.FxForward) {
    w.text(f.base); w.text(f.quote); wDirection(w, f.direction); w.nat(f.baseAmount); w.nat(f.rateMicro); w.nat(f.valueDate); w.nat(f.spotMicro); wInt(w, f.forwardPointsMicro);
    wCash(w, f.baseAccount); wCash(w, f.quoteAccount); w.text(f.pointsCurve); w.text(f.discountCurve)
  };
  func rForward(r : C.Reader) : ?TT.FxForward {
    let ?base = r.text() else return null; let ?quote = r.text() else return null; let ?direction = rDirection(r) else return null; let ?baseAmount = r.nat() else return null; let ?rateMicro = r.nat() else return null;
    let ?valueDate = r.nat() else return null; let ?spotMicro = r.nat() else return null; let ?forwardPointsMicro = rInt(r) else return null; let ?baseAccount = rCash(r) else return null; let ?quoteAccount = rCash(r) else return null;
    let ?pointsCurve = r.text() else return null; let ?discountCurve = r.text() else return null;
    ?{ base; quote; direction; baseAmount; rateMicro; valueDate; spotMicro; forwardPointsMicro; baseAccount; quoteAccount; pointsCurve; discountCurve }
  };
  public func writeKind(w : C.Writer, k : TT.DealKind) {
    switch (k) {
      case (#moneyMarket(m)) { w.byte(1); w.bool(m.placement); w.text(m.currency); w.nat(m.principal); w.nat(m.rateBps); PC.wConvention(w, m.dayCount); w.nat(m.start); w.nat(m.maturity); wCash(w, m.cash) };
      case (#fxForward(f)) { w.byte(2); wForward(w, f) };
      case (#fxSwap(x)) { w.byte(3); wForward(w, x.near); wForward(w, x.far) };
      case (#security(t)) {
        w.byte(4); w.text(t.isin); wDirection(w, t.direction); w.nat(t.nominal); w.nat(t.priceMicro); w.nat(t.settlement);
        w.byte(switch (t.classification) { case (#amortisedCost) 0; case (#fvoci) 1; case (#fvtpl) 2 }); wCash(w, t.cash); w.text(t.priceCurve); wOptText(w, t.venue);
      };
      case (#irs(i)) { w.byte(5); w.text(i.currency); w.nat(i.notional); w.bool(i.payFixed); w.nat(i.fixedBps); w.text(i.floatingIndex); wInt(w, i.spreadBps); w.nat(i.start); w.nat(i.maturity); w.nat(i.paymentMonths); PC.wConvention(w, i.dayCount); wCash(w, i.cash); w.text(i.discountCurve) };
      case (#fxOption(o)) { w.byte(6); w.text(o.base); w.text(o.quote); w.bool(o.call); w.bool(o.bought); w.nat(o.baseAmount); w.nat(o.strikeMicro); w.nat(o.expiry); w.nat(o.premium); w.nat(o.start); wCash(w, o.cash); w.text(o.domesticCurve); w.text(o.foreignCurve); w.text(o.volCurve) };
    }
  };
  public func readKind(r : C.Reader) : ?TT.DealKind {
    switch (r.byte()) {
      case (?1) {
        let ?placement = r.bool() else return null; let ?currency = r.text() else return null; let ?principal = r.nat() else return null; let ?rateBps = r.nat() else return null; let ?dayCount = PC.rConvention(r) else return null;
        let ?start = r.nat() else return null; let ?maturity = r.nat() else return null; let ?cash = rCash(r) else return null;
        ?#moneyMarket({ placement; currency; principal; rateBps; dayCount; start; maturity; cash })
      };
      case (?2) { let ?f = rForward(r) else return null; ?#fxForward(f) };
      case (?3) { let ?near = rForward(r) else return null; let ?far = rForward(r) else return null; ?#fxSwap({ near; far }) };
      case (?4) {
        let ?isin = r.text() else return null; let ?direction = rDirection(r) else return null; let ?nominal = r.nat() else return null; let ?priceMicro = r.nat() else return null; let ?settlement = r.nat() else return null;
        let classification : TT.Classification = switch (r.byte()) { case (?0) #amortisedCost; case (?1) #fvoci; case (?2) #fvtpl; case (_) return null };
        let ?cash = rCash(r) else return null; let ?priceCurve = r.text() else return null; let ?venue = rOptText(r) else return null;
        ?#security({ isin; direction; nominal; priceMicro; settlement; classification; cash; priceCurve; venue })
      };
      case (?5) {
        let ?currency = r.text() else return null; let ?notional = r.nat() else return null; let ?payFixed = r.bool() else return null; let ?fixedBps = r.nat() else return null; let ?floatingIndex = r.text() else return null;
        let ?spreadBps = rInt(r) else return null; let ?start = r.nat() else return null; let ?maturity = r.nat() else return null; let ?paymentMonths = r.nat() else return null; let ?dayCount = PC.rConvention(r) else return null;
        let ?cash = rCash(r) else return null; let ?discountCurve = r.text() else return null;
        ?#irs({ currency; notional; payFixed; fixedBps; floatingIndex; spreadBps; start; maturity; paymentMonths; dayCount; cash; discountCurve })
      };
      case (?6) {
        let ?base = r.text() else return null; let ?quote = r.text() else return null; let ?call = r.bool() else return null; let ?bought = r.bool() else return null; let ?baseAmount = r.nat() else return null;
        let ?strikeMicro = r.nat() else return null; let ?expiry = r.nat() else return null; let ?premium = r.nat() else return null; let ?start = r.nat() else return null; let ?cash = rCash(r) else return null;
        let ?domesticCurve = r.text() else return null; let ?foreignCurve = r.text() else return null; let ?volCurve = r.text() else return null;
        ?#fxOption({ base; quote; call; bought; baseAmount; strikeMicro; expiry; premium; start; cash; domesticCurve; foreignCurve; volCurve })
      };
      case (_) null;
    }
  };
  public func writeEntries(w : C.Writer, xs : [TT.StatementEntry]) {
    w.len16(xs.size());
    for (e in xs.vals()) { w.text(e.reference); w.nat(e.amount); w.bool(e.credit); w.nat(e.valueDay); w.nat(e.bookingDay); w.text(e.counterparty) }
  };
  public func readEntries(r : C.Reader) : ?[TT.StatementEntry] {
    let ?n = r.len16() else return null;
    let out = List.empty<TT.StatementEntry>();
    var i = 0;
    while (i < n) {
      let ?reference = r.text() else return null; let ?amount = r.nat() else return null; let ?credit = r.bool() else return null; let ?valueDay = r.nat() else return null; let ?bookingDay = r.nat() else return null; let ?counterparty = r.text() else return null;
      List.add(out, { reference; amount; credit; valueDay; bookingDay; counterparty }); i += 1;
    };
    ?List.toArray(out)
  };
  public func writeFields(w : C.Writer, f : TT.ConfirmationFields) { w.text(f.kind); w.nat(f.amount1); w.text(f.currency1); w.nat(f.amount2); w.text(f.currency2); w.nat(f.valueDate); w.nat(f.rateMicro); w.text(f.counterparty) };
  public func readFields(r : C.Reader) : ?TT.ConfirmationFields {
    let ?kind = r.text() else return null; let ?amount1 = r.nat() else return null; let ?currency1 = r.text() else return null; let ?amount2 = r.nat() else return null; let ?currency2 = r.text() else return null;
    let ?valueDate = r.nat() else return null; let ?rateMicro = r.nat() else return null; let ?counterparty = r.text() else return null;
    ?{ kind; amount1; currency1; amount2; currency2; valueDate; rateMicro; counterparty }
  };
  public func writeOptFields(w : C.Writer, f : ?TT.ConfirmationFields) { switch (f) { case null w.byte(0); case (?x) { w.byte(1); writeFields(w, x) } } };
  public func readOptFields(r : C.Reader) : ??TT.ConfirmationFields { switch (r.byte()) { case (?0) ?null; case (?1) { let ?x = readFields(r) else return null; ??x }; case (_) null } };
  public func writeOptCorrection(w : C.Writer, c : ?{ account : Text; sub : ?Text; debit : Bool; amount : Nat; currency : Text }) {
    switch (c) { case null w.byte(0); case (?x) { w.byte(1); w.text(x.account); wOptText(w, x.sub); w.bool(x.debit); w.nat(x.amount); w.text(x.currency) } }
  };
  public func readOptCorrection(r : C.Reader) : ??{ account : Text; sub : ?Text; debit : Bool; amount : Nat; currency : Text } {
    switch (r.byte()) {
      case (?0) ?null;
      case (?1) { let ?account = r.text() else return null; let ?sub = rOptText(r) else return null; let ?debit = r.bool() else return null; let ?amount = r.nat() else return null; let ?currency = r.text() else return null; ??{ account; sub; debit; amount; currency } };
      case (_) null;
    }
  };
  public func writeOptPrincipal(w : C.Writer, p : ?Principal) { wOptPrincipal(w, p) };
  public func readOptPrincipal(r : C.Reader) : ??Principal { rOptPrincipal(r) };

  // ─── events ───────────────────────────────────────────────────────────────

  func wSide(w : C.Writer, s : TT.BreakSide) { w.byte(switch (s) { case (#onStatementOnly) 0; case (#inOurBooksOnly) 1 }) };
  func rSide(r : C.Reader) : ?TT.BreakSide { switch (r.byte()) { case (?0) ?#onStatementOnly; case (?1) ?#inOurBooksOnly; case (_) null } };

  public func writeEvent(w : C.Writer, ev : TT.TreasuryEvent) {
    switch (ev) {
      case (#policySet(p)) { w.byte(0x01); writePolicy(w, p) };
      case (#securityRegistered(x)) { w.byte(0x02); writeSecurityTerms(w, x.terms); w.nat(x.day) };
      case (#curvePublished(x)) { w.byte(0x03); writeCurve(w, x.curve) };
      case (#limitSet(x)) { w.byte(0x04); writeLimit(w, x.limit); w.nat(x.day) };
      case (#nostroRegistered(x)) { w.byte(0x05); writeNostro(w, x.nostro); w.nat(x.day) };
      case (#dealCaptured(x)) { w.byte(0x06); w.text(x.book); writeCounterparty(w, x.counterparty); writeKind(w, x.kind); w.text(x.reference); w.principal(x.trader); w.nat(x.day); w.bool(x.withinLimits); wOptPrincipal(w, x.approver); w.nat(x.secondAmount) };
      case (#limitBreached(x)) { w.byte(0x07); writeLimit(w, x.limit); w.nat(x.measured); w.nat(x.deal); w.principal(x.approver); w.nat(x.day) };
      case (#dealConfirmed(x)) { w.byte(0x08); w.nat(x.deal); w.blob(x.confirmation); w.nat(x.day) };
      case (#confirmationMismatch(x)) { w.byte(0x09); w.nat(x.deal); w.blob(x.confirmation); w.text(x.field); w.text(x.ours); w.text(x.theirs); w.nat(x.day) };
      case (#dealAmended(x)) { w.byte(0x0A); w.nat(x.deal); writeKind(w, x.kind); w.text(x.reason); w.nat(x.day); w.nat(x.secondAmount) };
      case (#dealCancelled(x)) { w.byte(0x0B); w.nat(x.deal); w.text(x.reason); w.nat(x.day) };
      case (#legSettled(x)) { w.byte(0x0C); w.nat(x.deal); w.nat(x.leg); w.nat(x.amount); w.text(x.currency); wInt(w, x.realised); w.nat(x.day); wInt(w, x.accrual); wInt(w, x.amortisation); wInt(w, x.fv); w.nat(x.nominal); w.nat(x.cost) };
      case (#lotConsumed(x)) { w.byte(0x0D); w.nat(x.lot); w.nat(x.by); w.nat(x.nominal); w.nat(x.cost); wInt(w, x.amortisation); wInt(w, x.fv); wInt(w, x.accrual); w.nat(x.day) };
      case (#accrued(x)) { w.byte(0x0E); w.nat(x.deal); wInt(w, x.interest); wInt(w, x.amortisation); w.nat(x.day) };
      case (#marked(x)) { w.byte(0x0F); w.nat(x.deal); wInt(w, x.value); wInt(w, x.previous); w.nat(x.day) };
      case (#couponPaid(x)) { w.byte(0x10); w.nat(x.deal); w.nat(x.amount); w.nat(x.day) };
      case (#statementRecorded(x)) { w.byte(0x11); w.text(x.nostro); w.blob(x.statement); w.nat(x.from); w.nat(x.to); w.nat(x.entries); wNats(w, x.matches); w.nat(x.breaks); w.nat(x.day) };
      case (#nostroBreak(x)) { w.byte(0x12); w.text(x.nostro); w.blob(x.statement); wSide(w, x.side); w.nat(x.amount); w.bool(x.credit); w.nat(x.valueDay); w.text(x.reference); w.optNat(x.posting); w.nat(x.day) };
      case (#breakResolved(x)) { w.byte(0x13); w.nat(x.breakId); w.text(x.resolution); w.bool(x.corrected); w.nat(x.day) };
      case (#breakAged(x)) { w.byte(0x14); w.nat(x.breakId); w.nat(x.ageDays); w.nat(x.day) };
      case (#confirmationOverdue(x)) { w.byte(0x15); w.nat(x.deal); w.nat(x.ageDays); w.nat(x.day) };
    }
  };
  public func readEvent(r : C.Reader) : ?TT.TreasuryEvent {
    switch (r.byte()) {
      case (?0x01) { let ?p = readPolicy(r) else return null; ?#policySet(p) };
      case (?0x02) { let ?terms = readSecurityTerms(r) else return null; let ?day = r.nat() else return null; ?#securityRegistered({ terms; day }) };
      case (?0x03) { let ?curve = readCurve(r) else return null; ?#curvePublished({ curve }) };
      case (?0x04) { let ?limit = readLimit(r) else return null; let ?day = r.nat() else return null; ?#limitSet({ limit; day }) };
      case (?0x05) { let ?nostro = readNostro(r) else return null; let ?day = r.nat() else return null; ?#nostroRegistered({ nostro; day }) };
      case (?0x06) {
        let ?book = r.text() else return null; let ?counterparty = readCounterparty(r) else return null; let ?kind = readKind(r) else return null; let ?reference = r.text() else return null; let ?trader = r.principal() else return null;
        let ?day = r.nat() else return null; let ?withinLimits = r.bool() else return null; let ?approver = rOptPrincipal(r) else return null; let ?secondAmount = r.nat() else return null;
        ?#dealCaptured({ book; counterparty; kind; reference; trader; day; withinLimits; approver; secondAmount })
      };
      case (?0x07) { let ?limit = readLimit(r) else return null; let ?measured = r.nat() else return null; let ?deal = r.nat() else return null; let ?approver = r.principal() else return null; let ?day = r.nat() else return null; ?#limitBreached({ limit; measured; deal; approver; day }) };
      case (?0x08) { let ?deal = r.nat() else return null; let ?confirmation = r.blob() else return null; let ?day = r.nat() else return null; ?#dealConfirmed({ deal; confirmation; day }) };
      case (?0x09) { let ?deal = r.nat() else return null; let ?confirmation = r.blob() else return null; let ?field = r.text() else return null; let ?ours = r.text() else return null; let ?theirs = r.text() else return null; let ?day = r.nat() else return null; ?#confirmationMismatch({ deal; confirmation; field; ours; theirs; day }) };
      case (?0x0A) { let ?deal = r.nat() else return null; let ?kind = readKind(r) else return null; let ?reason = r.text() else return null; let ?day = r.nat() else return null; let ?secondAmount = r.nat() else return null; ?#dealAmended({ deal; kind; reason; day; secondAmount }) };
      case (?0x0B) { let ?deal = r.nat() else return null; let ?reason = r.text() else return null; let ?day = r.nat() else return null; ?#dealCancelled({ deal; reason; day }) };
      case (?0x0C) {
        let ?deal = r.nat() else return null; let ?leg = r.nat() else return null; let ?amount = r.nat() else return null; let ?currency = r.text() else return null; let ?realised = rInt(r) else return null; let ?day = r.nat() else return null;
        let ?accrual = rInt(r) else return null; let ?amortisation = rInt(r) else return null; let ?fv = rInt(r) else return null; let ?nominal = r.nat() else return null; let ?cost = r.nat() else return null;
        ?#legSettled({ deal; leg; amount; currency; realised; day; accrual; amortisation; fv; nominal; cost })
      };
      case (?0x0D) { let ?lot = r.nat() else return null; let ?by = r.nat() else return null; let ?nominal = r.nat() else return null; let ?cost = r.nat() else return null; let ?amortisation = rInt(r) else return null; let ?fv = rInt(r) else return null; let ?accrual = rInt(r) else return null; let ?day = r.nat() else return null; ?#lotConsumed({ lot; by; nominal; cost; amortisation; fv; accrual; day }) };
      case (?0x0E) { let ?deal = r.nat() else return null; let ?interest = rInt(r) else return null; let ?amortisation = rInt(r) else return null; let ?day = r.nat() else return null; ?#accrued({ deal; interest; amortisation; day }) };
      case (?0x0F) { let ?deal = r.nat() else return null; let ?value = rInt(r) else return null; let ?previous = rInt(r) else return null; let ?day = r.nat() else return null; ?#marked({ deal; value; previous; day }) };
      case (?0x10) { let ?deal = r.nat() else return null; let ?amount = r.nat() else return null; let ?day = r.nat() else return null; ?#couponPaid({ deal; amount; day }) };
      case (?0x11) { let ?nostro = r.text() else return null; let ?statement = r.blob() else return null; let ?from = r.nat() else return null; let ?to = r.nat() else return null; let ?entries = r.nat() else return null; let ?matches = rNats(r) else return null; let ?breaks = r.nat() else return null; let ?day = r.nat() else return null; ?#statementRecorded({ nostro; statement; from; to; entries; matches; breaks; day }) };
      case (?0x12) { let ?nostro = r.text() else return null; let ?statement = r.blob() else return null; let ?side = rSide(r) else return null; let ?amount = r.nat() else return null; let ?credit = r.bool() else return null; let ?valueDay = r.nat() else return null; let ?reference = r.text() else return null; let ?posting = r.optNat() else return null; let ?day = r.nat() else return null; ?#nostroBreak({ nostro; statement; side; amount; credit; valueDay; reference; posting; day }) };
      case (?0x13) { let ?breakId = r.nat() else return null; let ?resolution = r.text() else return null; let ?corrected = r.bool() else return null; let ?day = r.nat() else return null; ?#breakResolved({ breakId; resolution; corrected; day }) };
      case (?0x14) { let ?breakId = r.nat() else return null; let ?ageDays = r.nat() else return null; let ?day = r.nat() else return null; ?#breakAged({ breakId; ageDays; day }) };
      case (?0x15) { let ?deal = r.nat() else return null; let ?ageDays = r.nat() else return null; let ?day = r.nat() else return null; ?#confirmationOverdue({ deal; ageDays; day }) };
      case (_) null;
    }
  };
}
