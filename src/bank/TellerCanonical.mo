/// TellerCanonical.mo: the canonical bytes of the branch-and-teller vocabulary (branch and teller): denominations, the policy,
/// the payee of a presented cheque, a return's reason, the cash source of a draft, and the events. `BankCanonical`
/// calls these for the commands and the event.

import List "mo:core/List";

import C "mo:journal/Canonical";

import TT "TellerTypes";

module {

  func wPairs(w : C.Writer, xs : [(Nat, Nat)]) { w.len16(xs.size()); for ((a, b) in xs.vals()) { w.nat(a); w.nat(b) } };
  func rPairs(r : C.Reader) : ?[(Nat, Nat)] {
    let ?n = r.len16() else return null;
    let out = List.empty<(Nat, Nat)>();
    var i = 0;
    while (i < n) { let ?a = r.nat() else return null; let ?b = r.nat() else return null; List.add(out, (a, b)); i += 1 };
    ?List.toArray(out)
  };

  public func writeDenominations(w : C.Writer, d : TT.DenominationSet) { wPairs(w, d.notes); wPairs(w, d.coins) };
  public func readDenominations(r : C.Reader) : ?TT.DenominationSet {
    let ?notes = rPairs(r) else return null; let ?coins = rPairs(r) else return null;
    ?{ notes; coins }
  };

  public func writePolicy(w : C.Writer, p : TT.Policy) {
    w.text(p.overShort); w.text(p.cashInTransit); w.text(p.centralBank); w.text(p.draftsPayable); w.text(p.clearing); w.nat(p.staleDays); w.nat(p.clearingWindowDays);
  };
  public func readPolicy(r : C.Reader) : ?TT.Policy {
    let ?overShort = r.text() else return null; let ?cashInTransit = r.text() else return null; let ?centralBank = r.text() else return null;
    let ?draftsPayable = r.text() else return null; let ?clearing = r.text() else return null; let ?staleDays = r.nat() else return null; let ?clearingWindowDays = r.nat() else return null;
    ?{ overShort; cashInTransit; centralBank; draftsPayable; clearing; staleDays; clearingWindowDays }
  };

  public func writeDifference(w : C.Writer, d : TT.Difference) {
    switch (d) { case (#balanced) w.byte(0); case (#over(n)) { w.byte(1); w.nat(n) }; case (#short(n)) { w.byte(2); w.nat(n) } }
  };
  public func readDifference(r : C.Reader) : ?TT.Difference {
    switch (r.byte()) { case (?0) ?#balanced; case (?1) { let ?n = r.nat() else return null; ?#over(n) }; case (?2) { let ?n = r.nat() else return null; ?#short(n) }; case (_) null }
  };

  public func writePayee(w : C.Writer, p : TT.Payee) {
    switch (p) { case (#inBranch(x)) { w.byte(0); w.text(x.till) }; case (#clearing(x)) { w.byte(1); w.text(x.house); w.text(x.batch) } }
  };
  public func readPayee(r : C.Reader) : ?TT.Payee {
    switch (r.byte()) {
      case (?0) { let ?till = r.text() else return null; ?#inBranch({ till }) };
      case (?1) { let ?house = r.text() else return null; let ?batch = r.text() else return null; ?#clearing({ house; batch }) };
      case (_) null;
    }
  };

  public func writeReason(w : C.Writer, x : TT.ReturnReason) {
    switch (x) { case (#insufficientFunds) w.byte(0); case (#stopped) w.byte(1); case (#signature) w.byte(2); case (#stale) w.byte(3); case (#postDated) w.byte(4); case (#other(t)) { w.byte(5); w.text(t) } }
  };
  public func readReason(r : C.Reader) : ?TT.ReturnReason {
    switch (r.byte()) {
      case (?0) ?#insufficientFunds; case (?1) ?#stopped; case (?2) ?#signature; case (?3) ?#stale; case (?4) ?#postDated;
      case (?5) { let ?t = r.text() else return null; ?#other(t) }; case (_) null;
    }
  };

  public func writeSource(w : C.Writer, s : TT.CashSource) { switch (s) { case (#till(t)) { w.byte(0); w.text(t) }; case (#account(a)) { w.byte(1); w.nat(a) } } };
  public func readSource(r : C.Reader) : ?TT.CashSource {
    switch (r.byte()) { case (?0) { let ?t = r.text() else return null; ?#till(t) }; case (?1) { let ?a = r.nat() else return null; ?#account(a) }; case (_) null }
  };

  public func writeEvent(w : C.Writer, e : TT.TellerEvent) {
    switch (e) {
      case (#policySet(p)) { w.byte(0x01); writePolicy(w, p) };
      case (#sessionOpened(x)) { w.byte(0x02); w.text(x.till); w.principal(x.teller); writeDenominations(w, x.opening); w.nat(x.counted); w.nat(x.book); w.nat(x.day) };
      case (#sessionClosed(x)) { w.byte(0x03); w.nat(x.session); w.text(x.till); writeDenominations(w, x.closing); w.nat(x.counted); w.nat(x.book); writeDifference(w, x.difference); w.nat(x.day) };
      case (#differenceResolved(x)) { w.byte(0x04); w.nat(x.session); w.text(x.till); writeDifference(w, x.difference); w.text(x.account); w.text(x.note); w.nat(x.day) };
      case (#cashTaken(x)) { w.byte(0x05); w.text(x.till); w.nat(x.account); w.nat(x.amount); writeDenominations(w, x.tendered); writeDenominations(w, x.change); w.nat(x.day) };
      case (#cashPaid(x)) { w.byte(0x06); w.text(x.till); w.nat(x.account); w.nat(x.amount); writeDenominations(w, x.paid); w.nat(x.day) };
      case (#vaultToTill(x)) { w.byte(0x07); w.text(x.till); w.text(x.book); w.text(x.currency); w.nat(x.amount); writeDenominations(w, x.denominations); w.nat(x.day) };
      case (#tillToVault(x)) { w.byte(0x08); w.text(x.till); w.text(x.book); w.text(x.currency); w.nat(x.amount); writeDenominations(w, x.denominations); w.nat(x.day) };
      case (#cashDispatched(x)) { w.byte(0x09); w.text(x.product); w.text(x.fromBook); w.text(x.toBook); w.text(x.currency); w.nat(x.amount); writeDenominations(w, x.denominations); w.text(x.carrier); w.text(x.sealBag); w.nat(x.day) };
      case (#cashReceived(x)) { w.byte(0x0A); w.nat(x.movement); writeDenominations(w, x.denominations); w.nat(x.day) };
      case (#vaultToCentralBank(x)) { w.byte(0x0B); w.text(x.product); w.text(x.book); w.text(x.currency); w.nat(x.amount); writeDenominations(w, x.denominations); w.nat(x.day) };
      case (#centralBankToVault(x)) { w.byte(0x0C); w.text(x.product); w.text(x.book); w.text(x.currency); w.nat(x.amount); writeDenominations(w, x.denominations); w.nat(x.day) };
      case (#chequebookIssued(x)) { w.byte(0x0D); w.nat(x.account); w.nat(x.from); w.nat(x.to); w.nat(x.day) };
      case (#chequeStopped(x)) { w.byte(0x0E); w.nat(x.account); w.nat(x.serial); w.text(x.reason); w.nat(x.day) };
      case (#chequePresented(x)) { w.byte(0x0F); w.nat(x.account); w.nat(x.serial); w.nat(x.amount); writePayee(w, x.payee); w.nat(x.chequeDate); w.blob(x.imageHash); w.nat(x.hold); w.nat(x.expiresAt); w.nat(x.day) };
      case (#chequeCleared(x)) { w.byte(0x10); w.nat(x.account); w.nat(x.serial); w.nat(x.amount); w.nat(x.day) };
      case (#chequeReturned(x)) { w.byte(0x11); w.nat(x.account); w.nat(x.serial); w.nat(x.amount); writeReason(w, x.reason); w.nat(x.day) };
      case (#draftIssued(x)) { w.byte(0x12); w.text(x.serial); w.blob(x.payeeCommit); w.nat(x.amount); w.text(x.currency); writeSource(w, x.source); w.nat(x.day) };
      case (#draftPaid(x)) { w.byte(0x13); w.text(x.serial); w.nat(x.amount); writeSource(w, x.to); w.nat(x.day) };
      case (#draftCancelled(x)) { w.byte(0x14); w.text(x.serial); w.nat(x.amount); w.nat(x.refundTo); w.nat(x.day) };
    }
  };

  public func readEvent(r : C.Reader) : ?TT.TellerEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 { let ?p = readPolicy(r) else return null; ?#policySet(p) };
      case 0x02 {
        let ?till = r.text() else return null; let ?teller = r.principal() else return null; let ?opening = readDenominations(r) else return null;
        let ?counted = r.nat() else return null; let ?book = r.nat() else return null; let ?day = r.nat() else return null;
        ?#sessionOpened({ till; teller; opening; counted; book; day })
      };
      case 0x03 {
        let ?session = r.nat() else return null; let ?till = r.text() else return null; let ?closing = readDenominations(r) else return null;
        let ?counted = r.nat() else return null; let ?book = r.nat() else return null; let ?difference = readDifference(r) else return null; let ?day = r.nat() else return null;
        ?#sessionClosed({ session; till; closing; counted; book; difference; day })
      };
      case 0x04 {
        let ?session = r.nat() else return null; let ?till = r.text() else return null; let ?difference = readDifference(r) else return null;
        let ?account = r.text() else return null; let ?note = r.text() else return null; let ?day = r.nat() else return null;
        ?#differenceResolved({ session; till; difference; account; note; day })
      };
      case 0x05 {
        let ?till = r.text() else return null; let ?account = r.nat() else return null; let ?amount = r.nat() else return null;
        let ?tendered = readDenominations(r) else return null; let ?change = readDenominations(r) else return null; let ?day = r.nat() else return null;
        ?#cashTaken({ till; account; amount; tendered; change; day })
      };
      case 0x06 {
        let ?till = r.text() else return null; let ?account = r.nat() else return null; let ?amount = r.nat() else return null; let ?paid = readDenominations(r) else return null; let ?day = r.nat() else return null;
        ?#cashPaid({ till; account; amount; paid; day })
      };
      case 0x07 { let ?till = r.text() else return null; let ?book = r.text() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?denominations = readDenominations(r) else return null; let ?day = r.nat() else return null; ?#vaultToTill({ till; book; currency; amount; denominations; day }) };
      case 0x08 { let ?till = r.text() else return null; let ?book = r.text() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?denominations = readDenominations(r) else return null; let ?day = r.nat() else return null; ?#tillToVault({ till; book; currency; amount; denominations; day }) };
      case 0x09 {
        let ?product = r.text() else return null; let ?fromBook = r.text() else return null; let ?toBook = r.text() else return null; let ?currency = r.text() else return null;
        let ?amount = r.nat() else return null; let ?denominations = readDenominations(r) else return null; let ?carrier = r.text() else return null; let ?sealBag = r.text() else return null; let ?day = r.nat() else return null;
        ?#cashDispatched({ product; fromBook; toBook; currency; amount; denominations; carrier; sealBag; day })
      };
      case 0x0A { let ?movement = r.nat() else return null; let ?denominations = readDenominations(r) else return null; let ?day = r.nat() else return null; ?#cashReceived({ movement; denominations; day }) };
      case 0x0B {
        let ?product = r.text() else return null; let ?book = r.text() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?denominations = readDenominations(r) else return null; let ?day = r.nat() else return null;
        ?#vaultToCentralBank({ product; book; currency; amount; denominations; day })
      };
      case 0x0C {
        let ?product = r.text() else return null; let ?book = r.text() else return null; let ?currency = r.text() else return null; let ?amount = r.nat() else return null; let ?denominations = readDenominations(r) else return null; let ?day = r.nat() else return null;
        ?#centralBankToVault({ product; book; currency; amount; denominations; day })
      };
      case 0x0D { let ?account = r.nat() else return null; let ?from = r.nat() else return null; let ?to = r.nat() else return null; let ?day = r.nat() else return null; ?#chequebookIssued({ account; from; to; day }) };
      case 0x0E { let ?account = r.nat() else return null; let ?serial = r.nat() else return null; let ?reason = r.text() else return null; let ?day = r.nat() else return null; ?#chequeStopped({ account; serial; reason; day }) };
      case 0x0F {
        let ?account = r.nat() else return null; let ?serial = r.nat() else return null; let ?amount = r.nat() else return null; let ?payee = readPayee(r) else return null;
        let ?chequeDate = r.nat() else return null; let ?imageHash = r.blob() else return null; let ?hold = r.nat() else return null; let ?expiresAt = r.nat() else return null; let ?day = r.nat() else return null;
        ?#chequePresented({ account; serial; amount; payee; chequeDate; imageHash; hold; expiresAt; day })
      };
      case 0x10 { let ?account = r.nat() else return null; let ?serial = r.nat() else return null; let ?amount = r.nat() else return null; let ?day = r.nat() else return null; ?#chequeCleared({ account; serial; amount; day }) };
      case 0x11 { let ?account = r.nat() else return null; let ?serial = r.nat() else return null; let ?amount = r.nat() else return null; let ?reason = readReason(r) else return null; let ?day = r.nat() else return null; ?#chequeReturned({ account; serial; amount; reason; day }) };
      case 0x12 {
        let ?serial = r.text() else return null; let ?payeeCommit = r.blob() else return null; let ?amount = r.nat() else return null; let ?currency = r.text() else return null; let ?source = readSource(r) else return null; let ?day = r.nat() else return null;
        ?#draftIssued({ serial; payeeCommit; amount; currency; source; day })
      };
      case 0x13 { let ?serial = r.text() else return null; let ?amount = r.nat() else return null; let ?to = readSource(r) else return null; let ?day = r.nat() else return null; ?#draftPaid({ serial; amount; to; day }) };
      case 0x14 { let ?serial = r.text() else return null; let ?amount = r.nat() else return null; let ?refundTo = r.nat() else return null; let ?day = r.nat() else return null; ?#draftCancelled({ serial; amount; refundTo; day }) };
      case _ null;
    }
  };
}
