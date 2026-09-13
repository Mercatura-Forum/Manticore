/// IslamicCanonical.mo — the canonical bytes of the Islamic-banking vocabulary (Islamic banking): the policy, the contract
/// kinds and their terms, the pool and a distribution, and the events. `BankCanonical` calls these for the commands
/// and the event.

import List "mo:core/List";

import C "mo:journal/Canonical";

import IT "IslamicTypes";
import ProdT "ProductTypes";

module {

  func wTexts(w : C.Writer, xs : [Text]) { w.len16(xs.size()); for (x in xs.vals()) w.text(x) };
  func rTexts(r : C.Reader) : ?[Text] {
    let ?n = r.len16() else return null;
    let out = List.empty<Text>();
    var i = 0;
    while (i < n) { let ?x = r.text() else return null; List.add(out, x); i += 1 };
    ?List.toArray(out)
  };
  func wPairs(w : C.Writer, xs : [(Nat, Nat)]) { w.len16(xs.size()); for ((a, b) in xs.vals()) { w.nat(a); w.nat(b) } };
  func rPairs(r : C.Reader) : ?[(Nat, Nat)] {
    let ?n = r.len16() else return null;
    let out = List.empty<(Nat, Nat)>();
    var i = 0;
    while (i < n) { let ?a = r.nat() else return null; let ?b = r.nat() else return null; List.add(out, (a, b)); i += 1 };
    ?List.toArray(out)
  };
  func wPeriod(w : C.Writer, p : ProdT.Period) { w.byte(switch (p) { case (#daily) 0; case (#monthly) 1; case (#quarterly) 2; case (#semiAnnual) 3; case (#annual) 4; case (#atMaturity) 5 }) };
  func rPeriod(r : C.Reader) : ?ProdT.Period { switch (r.byte()) { case (?0) ?#daily; case (?1) ?#monthly; case (?2) ?#quarterly; case (?3) ?#semiAnnual; case (?4) ?#annual; case (?5) ?#atMaturity; case (_) null } };

  public func policyTexts(p : IT.Policy) : [Text] {
    [p.murabahaInventory, p.murabahaReceivable, p.deferredProfit, p.murabahaIncome, p.securityDeposits, p.ijarahAssets, p.accumulatedDepreciation, p.depreciationExpense, p.rentalReceivable, p.ijarahIncome,
     p.musharakahInvestment, p.musharakahIncome, p.mudarabahInvestment, p.mudarabahIncome, p.investmentLosses, p.salamReceivable, p.salamInventory, p.salamIncome, p.istisnaWip, p.istisnaReceivable, p.istisnaRevenue, p.istisnaCosts,
     p.iahEquity, p.profitEqualisationReserve, p.investmentRiskReserve, p.profitPayableToHolders, p.mudaribShareIncome, p.profitAttributableToHolders, p.charityPayable, p.nostro]
  };
  public func writePolicy(w : C.Writer, p : IT.Policy) { for (t in policyTexts(p).vals()) w.text(t); w.nat(p.perCeilingBps); w.nat(p.irrCeilingBps) };
  public func readPolicy(r : C.Reader) : ?IT.Policy {
    let ?murabahaInventory = r.text() else return null; let ?murabahaReceivable = r.text() else return null; let ?deferredProfit = r.text() else return null; let ?murabahaIncome = r.text() else return null; let ?securityDeposits = r.text() else return null;
    let ?ijarahAssets = r.text() else return null; let ?accumulatedDepreciation = r.text() else return null; let ?depreciationExpense = r.text() else return null; let ?rentalReceivable = r.text() else return null; let ?ijarahIncome = r.text() else return null;
    let ?musharakahInvestment = r.text() else return null; let ?musharakahIncome = r.text() else return null; let ?mudarabahInvestment = r.text() else return null; let ?mudarabahIncome = r.text() else return null; let ?investmentLosses = r.text() else return null;
    let ?salamReceivable = r.text() else return null; let ?salamInventory = r.text() else return null; let ?salamIncome = r.text() else return null; let ?istisnaWip = r.text() else return null; let ?istisnaReceivable = r.text() else return null; let ?istisnaRevenue = r.text() else return null; let ?istisnaCosts = r.text() else return null;
    let ?iahEquity = r.text() else return null; let ?profitEqualisationReserve = r.text() else return null; let ?investmentRiskReserve = r.text() else return null; let ?profitPayableToHolders = r.text() else return null; let ?mudaribShareIncome = r.text() else return null; let ?profitAttributableToHolders = r.text() else return null;
    let ?charityPayable = r.text() else return null; let ?nostro = r.text() else return null; let ?perCeilingBps = r.nat() else return null; let ?irrCeilingBps = r.nat() else return null;
    ?{ murabahaInventory; murabahaReceivable; deferredProfit; murabahaIncome; securityDeposits; ijarahAssets; accumulatedDepreciation; depreciationExpense; rentalReceivable; ijarahIncome;
       musharakahInvestment; musharakahIncome; mudarabahInvestment; mudarabahIncome; investmentLosses; salamReceivable; salamInventory; salamIncome; istisnaWip; istisnaReceivable; istisnaRevenue; istisnaCosts;
       iahEquity; profitEqualisationReserve; investmentRiskReserve; profitPayableToHolders; mudaribShareIncome; profitAttributableToHolders; charityPayable; nostro; perCeilingBps; irrCeilingBps }
  };
  public func writeApproval(w : C.Writer, a : IT.BoardApproval) { w.text(a.ref); w.blob(a.sha256) };
  public func readApproval(r : C.Reader) : ?IT.BoardApproval { let ?ref = r.text() else return null; let ?sha256 = r.blob() else return null; ?{ ref; sha256 } };
  public func writeCounterparty(w : C.Writer, c : IT.Counterparty) {
    switch (c) { case (#party(p)) { w.byte(0); w.nat(p.party); w.nat(p.account) }; case (#external(e)) { w.byte(1); w.text(e.name); w.text(e.reference) } }
  };
  public func readCounterparty(r : C.Reader) : ?IT.Counterparty {
    switch (r.byte()) {
      case (?0) { let ?party = r.nat() else return null; let ?account = r.nat() else return null; ?#party({ party; account }) };
      case (?1) { let ?name = r.text() else return null; let ?reference = r.text() else return null; ?#external({ name; reference }) };
      case (_) null;
    }
  };
  func wTransfer(w : C.Writer, t : ?IT.Transfer) {
    switch (t) { case null w.byte(0); case (?#gift) w.byte(1); case (?#sale(x)) { w.byte(2); w.nat(x.price) }; case (?#gradual(x)) { w.byte(3); w.nat(x.units) } }
  };
  func rTransfer(r : C.Reader) : ??IT.Transfer {
    switch (r.byte()) { case (?0) ?null; case (?1) ??#gift; case (?2) { let ?price = r.nat() else return null; ??#sale({ price }) }; case (?3) { let ?units = r.nat() else return null; ??#gradual({ units }) }; case (_) null }
  };
  public func writeTransfer(w : C.Writer, t : IT.Transfer) { wTransfer(w, ?t) };
  public func readTransfer(r : C.Reader) : ?IT.Transfer { switch (rTransfer(r)) { case (??t) ?t; case (_) null } };

  public func writeKind(w : C.Writer, k : IT.Kind) {
    switch (k) {
      case (#murabaha(m)) {
        w.byte(1); w.nat(m.customer); w.nat(m.account); w.text(m.asset); writeCounterparty(w, m.supplier); w.nat(m.costPrice); w.nat(m.markup); w.nat(m.instalments); wPeriod(w, m.every);
        w.byte(switch (m.method) { case (#proportionate) 0; case (#effectiveRate) 1 }); w.byte(switch (m.promise) { case (#binding) 1; case (#nonBinding) 0 }); w.nat(m.securityDeposit); w.nat(m.latePaymentCharityBps); w.text(m.reference);
      };
      case (#ijarah(i)) { w.byte(2); w.nat(i.lessee); w.nat(i.account); w.text(i.asset); w.nat(i.cost); w.nat(i.usefulLifeMonths); w.nat(i.residual); w.nat(i.rental); wPeriod(w, i.every); w.nat(i.periods); wTransfer(w, i.transfer); w.text(i.reference) };
      case (#musharakah(m)) {
        w.byte(3); w.len16(m.partners.size()); for (p in m.partners.vals()) { w.nat(p.party); w.nat(p.account); w.nat(p.capital); w.nat(p.profitBps) };
        w.nat(m.bankCapital); w.nat(m.bankProfitBps);
        switch (m.diminishing) { case null w.byte(0); case (?d) { w.byte(1); w.nat(d.units); w.nat(d.unitPrice); wPeriod(w, d.every); w.nat(d.rentalBps) } };
        w.text(m.reference);
      };
      case (#mudarabah(m)) { w.byte(4); w.nat(m.mudarib); w.nat(m.account); w.nat(m.capital); w.nat(m.bankProfitBps); w.nat(m.term); w.text(m.reference) };
      case (#salam(x)) { w.byte(5); w.nat(x.seller); w.nat(x.account); w.text(x.commodity); w.nat(x.quantity); w.text(x.unit); w.nat(x.delivery); w.nat(x.priceAdvanced); w.text(x.reference) };
      case (#istisna(x)) { w.byte(6); w.nat(x.customer); w.nat(x.account); w.blob(x.specification); w.nat(x.price); w.nat(x.estimatedCost); wPairs(w, x.milestones); writeCounterparty(w, x.contractor); w.text(x.reference) };
    }
  };
  public func readKind(r : C.Reader) : ?IT.Kind {
    switch (r.byte()) {
      case (?1) {
        let ?customer = r.nat() else return null; let ?account = r.nat() else return null; let ?asset = r.text() else return null; let ?supplier = readCounterparty(r) else return null;
        let ?costPrice = r.nat() else return null; let ?markup = r.nat() else return null; let ?instalments = r.nat() else return null; let ?every = rPeriod(r) else return null;
        let method : IT.ProfitMethod = switch (r.byte()) { case (?0) #proportionate; case (?1) #effectiveRate; case (_) return null };
        let promise : IT.Promise = switch (r.byte()) { case (?1) #binding; case (?0) #nonBinding; case (_) return null };
        let ?securityDeposit = r.nat() else return null; let ?latePaymentCharityBps = r.nat() else return null; let ?reference = r.text() else return null;
        ?#murabaha({ customer; account; asset; supplier; costPrice; markup; instalments; every; method; promise; securityDeposit; latePaymentCharityBps; reference })
      };
      case (?2) {
        let ?lessee = r.nat() else return null; let ?account = r.nat() else return null; let ?asset = r.text() else return null; let ?cost = r.nat() else return null; let ?usefulLifeMonths = r.nat() else return null;
        let ?residual = r.nat() else return null; let ?rental = r.nat() else return null; let ?every = rPeriod(r) else return null; let ?periods = r.nat() else return null; let ?transfer = rTransfer(r) else return null; let ?reference = r.text() else return null;
        ?#ijarah({ lessee; account; asset; cost; usefulLifeMonths; residual; rental; every; periods; transfer; reference })
      };
      case (?3) {
        let ?n = r.len16() else return null;
        let ps = List.empty<IT.Partner>();
        var i = 0;
        while (i < n) { let ?party = r.nat() else return null; let ?account = r.nat() else return null; let ?capital = r.nat() else return null; let ?profitBps = r.nat() else return null; List.add(ps, { party; account; capital; profitBps }); i += 1 };
        let ?bankCapital = r.nat() else return null; let ?bankProfitBps = r.nat() else return null;
        let diminishing : ?{ units : Nat; unitPrice : Nat; every : ProdT.Period; rentalBps : Nat } = switch (r.byte()) {
          case (?0) null;
          case (?1) { let ?units = r.nat() else return null; let ?unitPrice = r.nat() else return null; let ?every = rPeriod(r) else return null; let ?rentalBps = r.nat() else return null; ?{ units; unitPrice; every; rentalBps } };
          case (_) return null;
        };
        let ?reference = r.text() else return null;
        ?#musharakah({ partners = List.toArray(ps); bankCapital; bankProfitBps; diminishing; reference })
      };
      case (?4) { let ?mudarib = r.nat() else return null; let ?account = r.nat() else return null; let ?capital = r.nat() else return null; let ?bankProfitBps = r.nat() else return null; let ?term = r.nat() else return null; let ?reference = r.text() else return null; ?#mudarabah({ mudarib; account; capital; bankProfitBps; term; reference }) };
      case (?5) {
        let ?seller = r.nat() else return null; let ?account = r.nat() else return null; let ?commodity = r.text() else return null; let ?quantity = r.nat() else return null; let ?unit = r.text() else return null;
        let ?delivery = r.nat() else return null; let ?priceAdvanced = r.nat() else return null; let ?reference = r.text() else return null;
        ?#salam({ seller; account; commodity; quantity; unit; delivery; priceAdvanced; reference })
      };
      case (?6) {
        let ?customer = r.nat() else return null; let ?account = r.nat() else return null; let ?specification = r.blob() else return null; let ?price = r.nat() else return null; let ?estimatedCost = r.nat() else return null;
        let ?milestones = rPairs(r) else return null; let ?contractor = readCounterparty(r) else return null; let ?reference = r.text() else return null;
        ?#istisna({ customer; account; specification; price; estimatedCost; milestones; contractor; reference })
      };
      case (_) null;
    }
  };
  public func writePool(w : C.Writer, p : IT.Pool) { w.text(p.id); w.text(p.currency); w.nat(p.mudaribBps); w.nat(p.perBps); w.nat(p.irrBps); w.text(p.product); wTexts(w, p.incomeAccounts) };
  public func readPool(r : C.Reader) : ?IT.Pool {
    let ?id = r.text() else return null; let ?currency = r.text() else return null; let ?mudaribBps = r.nat() else return null; let ?perBps = r.nat() else return null; let ?irrBps = r.nat() else return null; let ?product = r.text() else return null; let ?incomeAccounts = rTexts(r) else return null;
    ?{ id; currency; mudaribBps; perBps; irrBps; product; incomeAccounts }
  };
  func wShares(w : C.Writer, xs : [(Nat, Nat)]) { wPairs(w, xs) };
  public func writeDistribution(w : C.Writer, d : IT.Distribution) {
    w.text(d.pool); w.text(d.period); w.nat(d.from); w.nat(d.to); w.nat(d.income); w.nat(d.per); w.nat(d.distributable); w.nat(d.mudaribShare); w.nat(d.holdersShare); w.nat(d.irr); w.nat(d.paid); wPairs(w, d.weightedBalances); wPairs(w, d.allocations);
  };
  public func readDistribution(r : C.Reader) : ?IT.Distribution {
    let ?pool = r.text() else return null; let ?period = r.text() else return null; let ?from = r.nat() else return null; let ?to = r.nat() else return null; let ?income = r.nat() else return null; let ?per = r.nat() else return null;
    let ?distributable = r.nat() else return null; let ?mudaribShare = r.nat() else return null; let ?holdersShare = r.nat() else return null; let ?irr = r.nat() else return null; let ?paid = r.nat() else return null;
    let ?weightedBalances = rPairs(r) else return null; let ?allocations = rPairs(r) else return null;
    ?{ pool; period; from; to; income; per; distributable; mudaribShare; holdersShare; irr; paid; weightedBalances; allocations }
  };

  // ─── events ───────────────────────────────────────────────────────────────

  func wOptNat(w : C.Writer, o : ?Nat) { w.optNat(o) };
  public func writeEvent(w : C.Writer, e : IT.IslamicEvent) {
    switch (e) {
      case (#policySet(p)) { w.byte(0x01); writePolicy(w, p) };
      case (#productApproved(x)) { w.byte(0x02); w.text(x.product); writeApproval(w, x.approval); w.nat(x.day) };
      case (#bookFlagged(x)) { w.byte(0x03); w.text(x.book); w.bool(x.sharia); w.nat(x.day) };
      case (#contractOpened(x)) { w.byte(0x04); writeKind(w, x.kind); w.text(x.currency); w.text(x.book); w.nat(x.day) };
      case (#assetAcquired(x)) { w.byte(0x05); w.nat(x.contract); w.nat(x.cost); w.nat(x.day) };
      case (#murabahaSold(x)) { w.byte(0x06); w.nat(x.contract); w.nat(x.sellingPrice); w.nat(x.deferredProfit); wPairs(w, x.schedule); w.nat(x.day) };
      case (#instalmentCollected(x)) { w.byte(0x07); w.nat(x.contract); w.nat(x.amount); w.nat(x.principal); w.nat(x.profit); w.nat(x.day) };
      case (#profitRecognised(x)) { w.byte(0x08); w.nat(x.contract); w.nat(x.amount); w.nat(x.cumulative); w.nat(x.day) };
      case (#rebateGranted(x)) { w.byte(0x09); w.nat(x.contract); w.nat(x.amount); w.text(x.reason); w.nat(x.day) };
      case (#latePaymentToCharity(x)) { w.byte(0x0A); w.nat(x.contract); w.nat(x.instalment); w.nat(x.amount); w.nat(x.cumulative); w.nat(x.day) };
      case (#leaseCommenced(x)) { w.byte(0x0B); w.nat(x.contract); w.nat(x.day) };
      case (#rentalAccrued(x)) { w.byte(0x0C); w.nat(x.contract); w.nat(x.amount); w.nat(x.period); w.nat(x.day) };
      case (#rentalCollected(x)) { w.byte(0x0D); w.nat(x.contract); w.nat(x.amount); w.nat(x.day) };
      case (#depreciationPosted(x)) { w.byte(0x0E); w.nat(x.contract); w.nat(x.amount); w.nat(x.cumulative); w.nat(x.day) };
      case (#ownershipTransferred(x)) { w.byte(0x0F); w.nat(x.contract); writeTransfer(w, x.how); w.nat(x.consideration); w.nat(x.day) };
      case (#capitalContributed(x)) { w.byte(0x10); w.nat(x.contract); wOptNat(w, x.party); w.nat(x.amount); w.nat(x.day) };
      case (#profitDistributed(x)) { w.byte(0x11); w.nat(x.contract); w.nat(x.profit); w.nat(x.bankShare); wShares(w, x.partnerShares); w.nat(x.day) };
      case (#lossAllocated(x)) { w.byte(0x12); w.nat(x.contract); w.nat(x.loss); w.nat(x.bankShare); wShares(w, x.partnerShares); w.nat(x.day) };
      case (#unitBought(x)) { w.byte(0x13); w.nat(x.contract); w.nat(x.units); w.nat(x.price); w.nat(x.bankUnitsLeft); w.nat(x.day) };
      case (#commodityDelivered(x)) { w.byte(0x14); w.nat(x.contract); w.nat(x.quantity); w.nat(x.day) };
      case (#commoditySold(x)) { w.byte(0x15); w.nat(x.contract); w.nat(x.proceeds); w.nat(x.day) };
      case (#deliveryFailed(x)) { w.byte(0x16); w.nat(x.contract); w.text(x.recourse); w.nat(x.day) };
      case (#milestoneRecorded(x)) { w.byte(0x17); w.nat(x.contract); w.blob(x.certificate); w.nat(x.percentBps); w.nat(x.revenue); w.nat(x.cost); w.nat(x.day) };
      case (#contractSettled(x)) { w.byte(0x18); w.nat(x.contract); w.nat(x.day) };
      case (#contractClosed(x)) { w.byte(0x19); w.nat(x.contract); w.text(x.reason); w.nat(x.day) };
      case (#nonComplianceRecorded(x)) { w.byte(0x1A); wOptNat(w, x.contract); w.nat(x.amount); w.text(x.account); w.text(x.reason); w.nat(x.day) };
      case (#poolOpened(x)) { w.byte(0x1B); writePool(w, x.pool); w.nat(x.day) };
      case (#poolDistributed(x)) { w.byte(0x1C); writeDistribution(w, x.distribution); w.nat(x.day) };
      case (#reserveUpdated(x)) { w.byte(0x1D); w.text(x.pool); wOptNat(w, x.per); wOptNat(w, x.irr); w.nat(x.day) };
    }
  };
  public func readEvent(r : C.Reader) : ?IT.IslamicEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 { let ?p = readPolicy(r) else return null; ?#policySet(p) };
      case 0x02 { let ?product = r.text() else return null; let ?approval = readApproval(r) else return null; let ?day = r.nat() else return null; ?#productApproved({ product; approval; day }) };
      case 0x03 { let ?book = r.text() else return null; let ?sharia = r.bool() else return null; let ?day = r.nat() else return null; ?#bookFlagged({ book; sharia; day }) };
      case 0x04 { let ?kind = readKind(r) else return null; let ?currency = r.text() else return null; let ?book = r.text() else return null; let ?day = r.nat() else return null; ?#contractOpened({ kind; currency; book; day }) };
      case 0x05 { let ?contract = r.nat() else return null; let ?cost = r.nat() else return null; let ?day = r.nat() else return null; ?#assetAcquired({ contract; cost; day }) };
      case 0x06 { let ?contract = r.nat() else return null; let ?sellingPrice = r.nat() else return null; let ?deferredProfit = r.nat() else return null; let ?schedule = rPairs(r) else return null; let ?day = r.nat() else return null; ?#murabahaSold({ contract; sellingPrice; deferredProfit; schedule; day }) };
      case 0x07 { let ?contract = r.nat() else return null; let ?amount = r.nat() else return null; let ?principal = r.nat() else return null; let ?profit = r.nat() else return null; let ?day = r.nat() else return null; ?#instalmentCollected({ contract; amount; principal; profit; day }) };
      case 0x08 { let ?contract = r.nat() else return null; let ?amount = r.nat() else return null; let ?cumulative = r.nat() else return null; let ?day = r.nat() else return null; ?#profitRecognised({ contract; amount; cumulative; day }) };
      case 0x09 { let ?contract = r.nat() else return null; let ?amount = r.nat() else return null; let ?reason = r.text() else return null; let ?day = r.nat() else return null; ?#rebateGranted({ contract; amount; reason; day }) };
      case 0x0A { let ?contract = r.nat() else return null; let ?instalment = r.nat() else return null; let ?amount = r.nat() else return null; let ?cumulative = r.nat() else return null; let ?day = r.nat() else return null; ?#latePaymentToCharity({ contract; instalment; amount; cumulative; day }) };
      case 0x0B { let ?contract = r.nat() else return null; let ?day = r.nat() else return null; ?#leaseCommenced({ contract; day }) };
      case 0x0C { let ?contract = r.nat() else return null; let ?amount = r.nat() else return null; let ?period = r.nat() else return null; let ?day = r.nat() else return null; ?#rentalAccrued({ contract; amount; period; day }) };
      case 0x0D { let ?contract = r.nat() else return null; let ?amount = r.nat() else return null; let ?day = r.nat() else return null; ?#rentalCollected({ contract; amount; day }) };
      case 0x0E { let ?contract = r.nat() else return null; let ?amount = r.nat() else return null; let ?cumulative = r.nat() else return null; let ?day = r.nat() else return null; ?#depreciationPosted({ contract; amount; cumulative; day }) };
      case 0x0F { let ?contract = r.nat() else return null; let ?how = readTransfer(r) else return null; let ?consideration = r.nat() else return null; let ?day = r.nat() else return null; ?#ownershipTransferred({ contract; how; consideration; day }) };
      case 0x10 { let ?contract = r.nat() else return null; let ?party = r.optNat() else return null; let ?amount = r.nat() else return null; let ?day = r.nat() else return null; ?#capitalContributed({ contract; party; amount; day }) };
      case 0x11 { let ?contract = r.nat() else return null; let ?profit = r.nat() else return null; let ?bankShare = r.nat() else return null; let ?partnerShares = rPairs(r) else return null; let ?day = r.nat() else return null; ?#profitDistributed({ contract; profit; bankShare; partnerShares; day }) };
      case 0x12 { let ?contract = r.nat() else return null; let ?loss = r.nat() else return null; let ?bankShare = r.nat() else return null; let ?partnerShares = rPairs(r) else return null; let ?day = r.nat() else return null; ?#lossAllocated({ contract; loss; bankShare; partnerShares; day }) };
      case 0x13 { let ?contract = r.nat() else return null; let ?units = r.nat() else return null; let ?price = r.nat() else return null; let ?bankUnitsLeft = r.nat() else return null; let ?day = r.nat() else return null; ?#unitBought({ contract; units; price; bankUnitsLeft; day }) };
      case 0x14 { let ?contract = r.nat() else return null; let ?quantity = r.nat() else return null; let ?day = r.nat() else return null; ?#commodityDelivered({ contract; quantity; day }) };
      case 0x15 { let ?contract = r.nat() else return null; let ?proceeds = r.nat() else return null; let ?day = r.nat() else return null; ?#commoditySold({ contract; proceeds; day }) };
      case 0x16 { let ?contract = r.nat() else return null; let ?recourse = r.text() else return null; let ?day = r.nat() else return null; ?#deliveryFailed({ contract; recourse; day }) };
      case 0x17 { let ?contract = r.nat() else return null; let ?certificate = r.blob() else return null; let ?percentBps = r.nat() else return null; let ?revenue = r.nat() else return null; let ?cost = r.nat() else return null; let ?day = r.nat() else return null; ?#milestoneRecorded({ contract; certificate; percentBps; revenue; cost; day }) };
      case 0x18 { let ?contract = r.nat() else return null; let ?day = r.nat() else return null; ?#contractSettled({ contract; day }) };
      case 0x19 { let ?contract = r.nat() else return null; let ?reason = r.text() else return null; let ?day = r.nat() else return null; ?#contractClosed({ contract; reason; day }) };
      case 0x1A { let ?contract = r.optNat() else return null; let ?amount = r.nat() else return null; let ?account = r.text() else return null; let ?reason = r.text() else return null; let ?day = r.nat() else return null; ?#nonComplianceRecorded({ contract; amount; account; reason; day }) };
      case 0x1B { let ?pool = readPool(r) else return null; let ?day = r.nat() else return null; ?#poolOpened({ pool; day }) };
      case 0x1C { let ?distribution = readDistribution(r) else return null; let ?day = r.nat() else return null; ?#poolDistributed({ distribution; day }) };
      case 0x1D { let ?pool = r.text() else return null; let ?per = r.optNat() else return null; let ?irr = r.optNat() else return null; let ?day = r.nat() else return null; ?#reserveUpdated({ pool; per; irr; day }) };
      case _ null;
    }
  };
}
