/// FacilityCanonical.mo — the canonical bytes of the corporate-lending vocabulary (corporate lending): terms and kinds,
/// covenants, pricing, receivables, the agent's notice, the restructuring terms, and the events. `BankCanonical`
/// calls these for the commands and the event; the agent's notice bytes are what the agent signs.

import List "mo:core/List";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";

import FT "FacilityTypes";
import PC "ProductCanonical";
import PT "PartyTypes";

module {

  func rNats(r : C.Reader) : ?[Nat] {
    let ?n = r.len16() else return null;
    let out = List.empty<Nat>();
    var i = 0;
    while (i < n) { let ?x = r.nat() else return null; List.add(out, x); i += 1 };
    ?List.toArray(out)
  };
  func wPairs(w : C.Writer, xs : [(PT.PartyId, Nat)]) { w.len16(xs.size()); for ((p, a) in xs.vals()) { w.nat(p); w.nat(a) } };
  func rPairs(r : C.Reader) : ?[(PT.PartyId, Nat)] {
    let ?n = r.len16() else return null;
    let out = List.empty<(PT.PartyId, Nat)>();
    var i = 0;
    while (i < n) { let ?p = r.nat() else return null; let ?a = r.nat() else return null; List.add(out, (p, a)); i += 1 };
    ?List.toArray(out)
  };
  func schemeCode(x : { #none; #mayo2; #mldsa44 }) : Nat8 { switch (x) { case (#none) 0; case (#mayo2) 1; case (#mldsa44) 2 } };
  func schemeOfCode(c : Nat8) : ?{ #none; #mayo2; #mldsa44 } { switch (c) { case 0 ?#none; case 1 ?#mayo2; case 2 ?#mldsa44; case _ null } };

  public func writePricing(w : C.Writer, p : FT.Pricing) {
    switch (p) { case (#fixed(bps)) { w.byte(0); w.nat(bps) }; case (#floating(f)) { w.byte(1); w.text(f.index); w.nat(f.spreadBps); w.nat(f.resetDays) } }
  };
  public func readPricing(r : C.Reader) : ?FT.Pricing {
    switch (r.byte()) {
      case (?0) { let ?bps = r.nat() else return null; ?#fixed(bps) };
      case (?1) { let ?index = r.text() else return null; let ?spreadBps = r.nat() else return null; let ?resetDays = r.nat() else return null; ?#floating({ index; spreadBps; resetDays }) };
      case (_) null;
    }
  };

  public func writeShares(w : C.Writer, xs : [FT.Share]) { w.len16(xs.size()); for (s in xs.vals()) { w.nat(s.participant); w.nat(s.bps) } };
  public func readShares(r : C.Reader) : ?[FT.Share] {
    let ?n = r.len16() else return null;
    let out = List.empty<FT.Share>();
    var i = 0;
    while (i < n) { let ?participant = r.nat() else return null; let ?bps = r.nat() else return null; List.add(out, { participant; bps }); i += 1 };
    ?List.toArray(out)
  };

  public func writeKind(w : C.Writer, k : FT.Kind) {
    w.byte(FT.kindCode(k));
    switch (k) {
      case (#bilateralTerm) {};
      case (#revolving(x)) { w.nat(x.commitmentFeeBps); switch (x.cleanDown) { case null w.byte(0); case (?c) { w.byte(1); w.nat(c.everyDays); w.nat(c.forDays) } } };
      case (#syndicatedAgent(x)) { writeShares(w, x.shares); w.nat(x.agentFeeBps) };
      case (#syndicatedParticipant(x)) { w.text(x.agent); w.byte(schemeCode(x.agentScheme)); w.blob(x.agentKey); w.text(x.agentAccount); w.nat(x.ourBps) };
      case (#financeLease(x)) { w.text(x.assetAccount); w.nat(x.residual) };
      case (#operatingLease(x)) { w.nat(x.rentalPerPeriod); PC.wPeriod(w, x.every); w.nat(x.periods) };
      case (#factoring(x)) { w.nat(x.advanceBps); w.nat(x.discountBps); w.bool(x.recourse); w.nat(x.clientAccount) };
      case (#forfaiting(x)) { w.nat(x.discountBps); w.nat(x.clientAccount) };
    }
  };
  public func readKind(r : C.Reader) : ?FT.Kind {
    switch (r.byte()) {
      case (?0) ?#bilateralTerm;
      case (?1) {
        let ?commitmentFeeBps = r.nat() else return null;
        let cleanDown : ?{ everyDays : Nat; forDays : Nat } = switch (r.byte()) {
          case (?0) null;
          case (?1) { let ?everyDays = r.nat() else return null; let ?forDays = r.nat() else return null; ?{ everyDays; forDays } };
          case (_) return null;
        };
        ?#revolving({ commitmentFeeBps; cleanDown })
      };
      case (?2) { let ?shares = readShares(r) else return null; let ?agentFeeBps = r.nat() else return null; ?#syndicatedAgent({ shares; agentFeeBps }) };
      case (?3) {
        let ?agent = r.text() else return null; let ?sc = r.byte() else return null; let ?agentScheme = schemeOfCode(sc) else return null;
        let ?agentKey = r.blob() else return null; let ?agentAccount = r.text() else return null; let ?ourBps = r.nat() else return null;
        ?#syndicatedParticipant({ agent; agentScheme; agentKey; agentAccount; ourBps })
      };
      case (?4) { let ?assetAccount = r.text() else return null; let ?residual = r.nat() else return null; ?#financeLease({ assetAccount; residual }) };
      case (?5) { let ?rentalPerPeriod = r.nat() else return null; let ?every = PC.rPeriod(r) else return null; let ?periods = r.nat() else return null; ?#operatingLease({ rentalPerPeriod; every; periods }) };
      case (?6) { let ?advanceBps = r.nat() else return null; let ?discountBps = r.nat() else return null; let ?recourse = r.bool() else return null; let ?clientAccount = r.nat() else return null; ?#factoring({ advanceBps; discountBps; recourse; clientAccount }) };
      case (?7) { let ?discountBps = r.nat() else return null; let ?clientAccount = r.nat() else return null; ?#forfaiting({ discountBps; clientAccount }) };
      case (_) null;
    }
  };

  public func writeCovenants(w : C.Writer, cs : [FT.Covenant]) {
    w.len16(cs.size());
    for (c in cs.vals()) {
      w.text(c.id);
      switch (c.kind) {
        case (#financialRatio(x)) { w.byte(0); w.text(x.name); w.byte(switch (x.op) { case (#atMost) 0; case (#atLeast) 1 }); w.nat(x.thresholdBps) };
        case (#reporting(x)) { w.byte(1); w.nat(x.due) };
        case (#negativePledge) w.byte(2);
      };
    };
  };
  public func readCovenants(r : C.Reader) : ?[FT.Covenant] {
    let ?n = r.len16() else return null;
    let out = List.empty<FT.Covenant>();
    var i = 0;
    while (i < n) {
      let ?id = r.text() else return null;
      let kind : { #financialRatio : { name : Text; op : { #atMost; #atLeast }; thresholdBps : Nat }; #reporting : { due : Nat }; #negativePledge } = switch (r.byte()) {
        case (?0) {
          let ?name = r.text() else return null;
          let op : { #atMost; #atLeast } = switch (r.byte()) { case (?0) #atMost; case (?1) #atLeast; case (_) return null };
          let ?thresholdBps = r.nat() else return null;
          #financialRatio({ name; op; thresholdBps })
        };
        case (?1) { let ?due = r.nat() else return null; #reporting({ due }) };
        case (?2) #negativePledge;
        case (_) return null;
      };
      List.add(out, { id; kind }); i += 1;
    };
    ?List.toArray(out)
  };

  public func writeTerms(w : C.Writer, t : FT.Terms) {
    w.nat(t.party); w.text(t.book); w.text(t.product); writeKind(w, t.kind); w.text(t.currency); w.nat(t.limit);
    w.nat(t.availabilityFrom); w.nat(t.availabilityTo); writePricing(w, t.pricing); writeCovenants(w, t.covenants);
    w.len16(t.collateral.size()); for (c in t.collateral.vals()) w.nat(c);
    w.optNat(t.reviewEvery);
  };
  public func readTerms(r : C.Reader) : ?FT.Terms {
    let ?party = r.nat() else return null; let ?book = r.text() else return null; let ?product = r.text() else return null; let ?kind = readKind(r) else return null;
    let ?currency = r.text() else return null; let ?limit = r.nat() else return null; let ?availabilityFrom = r.nat() else return null; let ?availabilityTo = r.nat() else return null;
    let ?pricing = readPricing(r) else return null; let ?covenants = readCovenants(r) else return null; let ?collateral = rNats(r) else return null; let ?reviewEvery = r.optNat() else return null;
    ?{ party; book; product; kind; currency; limit; availabilityFrom; availabilityTo; pricing; covenants; collateral; reviewEvery }
  };

  public func writeReceivables(w : C.Writer, xs : [FT.Receivable]) { w.len16(xs.size()); for (x in xs.vals()) { w.blob(x.ref); w.blob(x.debtorCommit); w.nat(x.face); w.nat(x.due) } };
  public func readReceivables(r : C.Reader) : ?[FT.Receivable] {
    let ?n = r.len16() else return null;
    let out = List.empty<FT.Receivable>();
    var i = 0;
    while (i < n) {
      let ?ref = r.blob() else return null; let ?debtorCommit = r.blob() else return null; let ?face = r.nat() else return null; let ?due = r.nat() else return null;
      List.add(out, { ref; debtorCommit; face; due }); i += 1;
    };
    ?List.toArray(out)
  };

  public func writeNotice(w : C.Writer, n : FT.AgentNotice) {
    switch (n) {
      case (#drawdown(x)) { w.byte(0); w.text(x.drawing); w.nat(x.total); w.nat(x.ourShare); w.nat(x.valueDate) };
      case (#repayment(x)) { w.byte(1); w.text(x.drawing); w.nat(x.total); w.nat(x.ourShare); w.nat(x.valueDate) };
      case (#interestDistribution(x)) { w.byte(2); w.text(x.drawing); w.nat(x.total); w.nat(x.ourShare); w.nat(x.valueDate) };
    }
  };
  public func readNotice(r : C.Reader) : ?FT.AgentNotice {
    let ?tag = r.byte() else return null;
    let ?drawing = r.text() else return null; let ?total = r.nat() else return null; let ?ourShare = r.nat() else return null; let ?valueDate = r.nat() else return null;
    switch (tag) {
      case 0 ?#drawdown({ drawing; total; ourShare; valueDate }); case 1 ?#repayment({ drawing; total; ourShare; valueDate });
      case 2 ?#interestDistribution({ drawing; total; ourShare; valueDate }); case _ null;
    }
  };
  /// What the agent signs: the notice under a domain, for the facility it addresses.
  public func noticeBytes(facility : FT.FacilityId, n : FT.AgentNotice) : Blob {
    let w = C.Writer();
    w.text("THEBES-BANK-AGENT-NOTICE-v1"); w.nat(facility); writeNotice(w, n);
    w.toBlob()
  };
  public func noticeHash(facility : FT.FacilityId, n : FT.AgentNotice) : Blob { Sha256.fromBlob(#sha256, noticeBytes(facility, n)) };

  public func writeRestructure(w : C.Writer, t : FT.RestructureTerms) { PC.wSchedule(w, t.schedule); w.nat(t.rateBps) };
  public func readRestructure(r : C.Reader) : ?FT.RestructureTerms {
    let ?schedule = PC.rSchedule(r) else return null; let ?rateBps = r.nat() else return null;
    ?{ schedule; rateBps }
  };

  public func writeEvent(w : C.Writer, e : FT.FacilityEvent) {
    switch (e) {
      case (#facilityOpened(x)) { w.byte(0x01); writeTerms(w, x.terms); w.nat(x.day) };
      case (#drawn(x)) { w.byte(0x02); w.nat(x.facility); w.nat(x.account); w.nat(x.amount); w.nat(x.rateBps); w.nat(x.day); wPairs(w, x.splits) };
      case (#drawingRepaid(x)) { w.byte(0x03); w.nat(x.facility); w.nat(x.account); w.nat(x.amount); w.nat(x.day); wPairs(w, x.interestShared) };
      case (#commitmentFeeAccrued(x)) { w.byte(0x04); w.nat(x.facility); w.nat(x.day); w.nat(x.undrawn); w.nat(x.amount) };
      case (#cleanDownJudged(x)) { w.byte(0x05); w.nat(x.facility); w.nat(x.windowEnd); w.nat(x.cleanDays); w.nat(x.required); w.bool(x.met) };
      case (#participationTransferred(x)) { w.byte(0x06); w.nat(x.facility); w.nat(x.from); w.nat(x.to); w.nat(x.bps); w.nat(x.moved) };
      case (#distributedToParticipants(x)) { w.byte(0x07); w.nat(x.facility); w.nat(x.day); wPairs(w, x.amounts) };
      case (#agentNoticeRecorded(x)) { w.byte(0x08); w.nat(x.facility); writeNotice(w, x.notice); w.blob(x.noticeHash); w.optNat(x.account) };
      case (#facilityRestructured(x)) { w.byte(0x09); w.nat(x.facility); writeRestructure(w, x.terms); w.nat(x.effective); w.len16(x.drawings.size()); for (d in x.drawings.vals()) w.nat(d) };
      case (#drawingRepriced(x)) { w.byte(0x0A); w.nat(x.facility); w.nat(x.account); w.nat(x.day); w.nat(x.rateBps); w.nat(x.fixing) };
      case (#covenantTested(x)) { w.byte(0x0B); w.nat(x.facility); w.text(x.covenant); w.nat(x.value); w.bool(x.met); w.blob(x.statementHash); w.nat(x.day) };
      case (#drawdownsBlocked(x)) { w.byte(0x0C); w.nat(x.facility); w.text(x.reason); w.nat(x.day) };
      case (#drawdownsUnblocked(x)) { w.byte(0x0D); w.nat(x.facility); w.text(x.reason); w.nat(x.day) };
      case (#reviewRecorded(x)) { w.byte(0x0E); w.nat(x.facility); w.nat(x.day); w.optNat(x.nextDue); w.text(x.note) };
      case (#reviewOverdue(x)) { w.byte(0x0F); w.nat(x.facility); w.nat(x.due); w.nat(x.day) };
      case (#leaseRentalAccrued(x)) { w.byte(0x10); w.nat(x.facility); w.nat(x.day); w.nat(x.amount) };
      case (#rentalReceived(x)) { w.byte(0x11); w.nat(x.facility); w.nat(x.amount); w.nat(x.day) };
      case (#residualRemeasured(x)) { w.byte(0x12); w.nat(x.facility); w.nat(x.from); w.nat(x.to); w.nat(x.day) };
      case (#receivablesPurchased(x)) { w.byte(0x13); w.nat(x.facility); writeReceivables(w, x.receivables); w.nat(x.face); w.nat(x.advance); w.nat(x.discount); w.nat(x.retention); w.nat(x.day) };
      case (#discountUnwound(x)) { w.byte(0x14); w.nat(x.facility); w.nat(x.day); w.nat(x.amount); w.len16(x.items.size()); for ((ref, a) in x.items.vals()) { w.blob(ref); w.nat(a) } };
      case (#receivableCollected(x)) { w.byte(0x15); w.nat(x.facility); w.blob(x.ref); w.nat(x.amount); w.nat(x.retentionReleased); w.nat(x.day) };
      case (#receivableDishonoured(x)) { w.byte(0x16); w.nat(x.facility); w.blob(x.ref); w.nat(x.face); w.bool(x.chargedBack); w.nat(x.day) };
      case (#receivableWrittenOff(x)) { w.byte(0x17); w.nat(x.facility); w.blob(x.ref); w.nat(x.amount); w.nat(x.day) };
      case (#drawingClosed(x)) { w.byte(0x18); w.nat(x.facility); w.nat(x.account); w.nat(x.day) };
      case (#rateFixingRecorded(x)) { w.byte(0x19); w.text(x.index); w.nat(x.day); w.nat(x.rateBps) };
      case (#facilityClosed(x)) { w.byte(0x1A); w.nat(x.facility); w.nat(x.day) };
    }
  };

  public func readEvent(r : C.Reader) : ?FT.FacilityEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 { let ?terms = readTerms(r) else return null; let ?day = r.nat() else return null; ?#facilityOpened({ terms; day }) };
      case 0x02 {
        let ?facility = r.nat() else return null; let ?account = r.nat() else return null; let ?amount = r.nat() else return null; let ?rateBps = r.nat() else return null;
        let ?day = r.nat() else return null; let ?splits = rPairs(r) else return null;
        ?#drawn({ facility; account; amount; rateBps; day; splits })
      };
      case 0x03 {
        let ?facility = r.nat() else return null; let ?account = r.nat() else return null; let ?amount = r.nat() else return null; let ?day = r.nat() else return null; let ?interestShared = rPairs(r) else return null;
        ?#drawingRepaid({ facility; account; amount; day; interestShared })
      };
      case 0x04 { let ?facility = r.nat() else return null; let ?day = r.nat() else return null; let ?undrawn = r.nat() else return null; let ?amount = r.nat() else return null; ?#commitmentFeeAccrued({ facility; day; undrawn; amount }) };
      case 0x05 {
        let ?facility = r.nat() else return null; let ?windowEnd = r.nat() else return null; let ?cleanDays = r.nat() else return null; let ?required = r.nat() else return null; let ?met = r.bool() else return null;
        ?#cleanDownJudged({ facility; windowEnd; cleanDays; required; met })
      };
      case 0x06 {
        let ?facility = r.nat() else return null; let ?from = r.nat() else return null; let ?to = r.nat() else return null; let ?bps = r.nat() else return null; let ?moved = r.nat() else return null;
        ?#participationTransferred({ facility; from; to; bps; moved })
      };
      case 0x07 { let ?facility = r.nat() else return null; let ?day = r.nat() else return null; let ?amounts = rPairs(r) else return null; ?#distributedToParticipants({ facility; day; amounts }) };
      case 0x08 {
        let ?facility = r.nat() else return null; let ?notice = readNotice(r) else return null; let ?noticeHash = r.blob() else return null; let ?account = r.optNat() else return null;
        ?#agentNoticeRecorded({ facility; notice; noticeHash; account })
      };
      case 0x09 {
        let ?facility = r.nat() else return null; let ?terms = readRestructure(r) else return null; let ?effective = r.nat() else return null; let ?drawings = rNats(r) else return null;
        ?#facilityRestructured({ facility; terms; effective; drawings })
      };
      case 0x0A {
        let ?facility = r.nat() else return null; let ?account = r.nat() else return null; let ?day = r.nat() else return null; let ?rateBps = r.nat() else return null; let ?fixing = r.nat() else return null;
        ?#drawingRepriced({ facility; account; day; rateBps; fixing })
      };
      case 0x0B {
        let ?facility = r.nat() else return null; let ?covenant = r.text() else return null; let ?value = r.nat() else return null; let ?met = r.bool() else return null;
        let ?statementHash = r.blob() else return null; let ?day = r.nat() else return null;
        ?#covenantTested({ facility; covenant; value; met; statementHash; day })
      };
      case 0x0C { let ?facility = r.nat() else return null; let ?reason = r.text() else return null; let ?day = r.nat() else return null; ?#drawdownsBlocked({ facility; reason; day }) };
      case 0x0D { let ?facility = r.nat() else return null; let ?reason = r.text() else return null; let ?day = r.nat() else return null; ?#drawdownsUnblocked({ facility; reason; day }) };
      case 0x0E { let ?facility = r.nat() else return null; let ?day = r.nat() else return null; let ?nextDue = r.optNat() else return null; let ?note = r.text() else return null; ?#reviewRecorded({ facility; day; nextDue; note }) };
      case 0x0F { let ?facility = r.nat() else return null; let ?due = r.nat() else return null; let ?day = r.nat() else return null; ?#reviewOverdue({ facility; due; day }) };
      case 0x10 { let ?facility = r.nat() else return null; let ?day = r.nat() else return null; let ?amount = r.nat() else return null; ?#leaseRentalAccrued({ facility; day; amount }) };
      case 0x11 { let ?facility = r.nat() else return null; let ?amount = r.nat() else return null; let ?day = r.nat() else return null; ?#rentalReceived({ facility; amount; day }) };
      case 0x12 { let ?facility = r.nat() else return null; let ?from = r.nat() else return null; let ?to = r.nat() else return null; let ?day = r.nat() else return null; ?#residualRemeasured({ facility; from; to; day }) };
      case 0x13 {
        let ?facility = r.nat() else return null; let ?receivables = readReceivables(r) else return null; let ?face = r.nat() else return null; let ?advance = r.nat() else return null;
        let ?discount = r.nat() else return null; let ?retention = r.nat() else return null; let ?day = r.nat() else return null;
        ?#receivablesPurchased({ facility; receivables; face; advance; discount; retention; day })
      };
      case 0x14 {
        let ?facility = r.nat() else return null; let ?day = r.nat() else return null; let ?amount = r.nat() else return null; let ?n = r.len16() else return null;
        let items = List.empty<(Blob, Nat)>();
        var i = 0;
        while (i < n) { let ?ref = r.blob() else return null; let ?a = r.nat() else return null; List.add(items, (ref, a)); i += 1 };
        ?#discountUnwound({ facility; day; amount; items = List.toArray(items) })
      };
      case 0x15 {
        let ?facility = r.nat() else return null; let ?ref = r.blob() else return null; let ?amount = r.nat() else return null; let ?retentionReleased = r.nat() else return null; let ?day = r.nat() else return null;
        ?#receivableCollected({ facility; ref; amount; retentionReleased; day })
      };
      case 0x16 {
        let ?facility = r.nat() else return null; let ?ref = r.blob() else return null; let ?face = r.nat() else return null; let ?chargedBack = r.bool() else return null; let ?day = r.nat() else return null;
        ?#receivableDishonoured({ facility; ref; face; chargedBack; day })
      };
      case 0x17 { let ?facility = r.nat() else return null; let ?ref = r.blob() else return null; let ?amount = r.nat() else return null; let ?day = r.nat() else return null; ?#receivableWrittenOff({ facility; ref; amount; day }) };
      case 0x18 { let ?facility = r.nat() else return null; let ?account = r.nat() else return null; let ?day = r.nat() else return null; ?#drawingClosed({ facility; account; day }) };
      case 0x19 { let ?index = r.text() else return null; let ?day = r.nat() else return null; let ?rateBps = r.nat() else return null; ?#rateFixingRecorded({ index; day; rateBps }) };
      case 0x1A { let ?facility = r.nat() else return null; let ?day = r.nat() else return null; ?#facilityClosed({ facility; day }) };
      case _ null;
    }
  };
}
