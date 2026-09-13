/// CloseCanonical.mo — the canonical bytes of the close vocabulary.
///
/// Tag per variant, additive, never renumbered, every variable-length part carrying
/// its own length. Writers and readers are mirror images and the battery proves it by
/// round-tripping one value of every variant and then flipping every byte.


import List "mo:core/List";

import C "mo:journal/Canonical";

import T "CloseTypes";
import Fx "Fx";
import Deferrals "Deferrals";
import PeriodEnd "PeriodEnd";

module {

  // ═══════════════════════════════════════════════════════
  //  WRITERS
  // ═══════════════════════════════════════════════════════

  public func wConvention(w : C.Writer, c : T.Convention) {
    w.byte(switch (c) {
      case (#sameDay) 0; case (#following) 1; case (#modifiedFollowing) 2;
      case (#preceding) 3; case (#modifiedPreceding) 4; case (#endOfMonth) 5;
    });
  };

  public func wRate(w : C.Writer, r : Fx.Rate) {
    w.text(r.currency); w.text(r.functional); w.nat(r.numerator); w.nat(r.denominator);
    w.nat(r.asOf); w.text(r.source);
  };

  public func wPair(w : C.Writer, p : Fx.PositionPair) {
    w.text(p.currency); w.text(p.position); w.text(p.equivalent);
    w.text(p.unrealised); w.text(p.realised); w.bool(p.monetary);
  };

  public func wWindow(w : C.Writer, x : PeriodEnd.BackValueWindow) {
    w.text(x.book); w.nat(x.freeDays); w.nat(x.approvedDays);
  };

  public func wRedenomination(w : C.Writer, r : T.Redenomination) {
    w.text(r.from); w.text(r.to); w.byte(r.minorUnits); w.nat(r.ratioNumerator); w.nat(r.ratioDenominator); w.text(r.bridgeAccount); w.text(r.roundingAccount); w.nat(r.day);
  };
  public func rRedenomination(r : C.Reader) : ?T.Redenomination {
    let ?from = r.text() else return null; let ?to = r.text() else return null; let ?minorUnits = r.byte() else return null;
    let ?ratioNumerator = r.nat() else return null; let ?ratioDenominator = r.nat() else return null;
    let ?bridgeAccount = r.text() else return null; let ?roundingAccount = r.text() else return null; let ?day = r.nat() else return null;
    ?{ from; to; minorUnits; ratioNumerator; ratioDenominator; bridgeAccount; roundingAccount; day }
  };

  public func wDirection(w : C.Writer, d : T.Direction) {
    w.byte(switch (d) { case (#gain) 0; case (#loss) 1; case (#unchanged) 2 });
  };

  public func wAdjustmentDirection(w : C.Writer, d : T.AdjustmentDirection) {
    w.byte(switch (d) { case (#increase) 0; case (#decrease) 1; case (#unchanged) 2 });
  };

  public func wSchedule(w : C.Writer, s : Deferrals.Schedule) {
    w.text(s.id);
    w.byte(switch (s.kind) { case (#unearnedIncome) 0; case (#prepaidExpense) 1 });
    w.text(s.currency); w.nat(s.amount); w.nat(s.periods);
    w.text(s.deferralAccount); w.text(s.recognitionAccount); w.text(s.book); w.nat(s.openedOn);
  };

  public func writeEvent(w : C.Writer, e : T.CloseEvent) {
    switch (e) {
      case (#functionalCurrencySet(x)) { w.byte(0x01); w.text(x.currency) };
      case (#fxPairSet(x)) { w.byte(0x02); wPair(w, x.pair) };
      case (#fxRateSet(x)) { w.byte(0x03); wRate(w, x.rate) };
      case (#backValueWindowSet(x)) { w.byte(0x04); wWindow(w, x.window) };
      case (#backValueApproved(x)) { w.byte(0x05); w.text(x.book); w.nat(x.valueDate); w.principal(x.approver); w.text(x.reason) };
      case (#currencyCalendarSet(x)) { w.byte(0x19); w.text(x.currency); w.calendar(x.calendar) };
      case (#redenominationDeclared(x)) { w.byte(0x1A); wRedenomination(w, x.redenomination); w.len16(x.products.size()); for (p in x.products.vals()) w.text(p) };
      case (#balanceRedenominated(x)) {
        w.byte(0x1B); w.text(x.from); w.text(x.to); w.text(x.account); w.optBlob(x.subledger); w.optNat(x.productAccount);
        w.nat(x.oldAmount); w.nat(x.newAmount); w.bool(x.creditBalance); w.nat(x.day);
      };
      case (#redenominationCompleted(x)) { w.byte(0x1C); w.text(x.from); w.text(x.to); w.nat(x.rows); w.nat(x.oldTotal); w.nat(x.newTotal); w.nat(x.roundingAmount); w.bool(x.roundingDebit); w.nat(x.day) };
      case (#fxDealBooked(x)) {
        w.byte(0x06); w.text(x.sell); w.nat(x.sellAmount); w.text(x.buy); w.nat(x.buyAmount);
        w.nat(x.rateNumerator); w.nat(x.rateDenominator); w.nat(x.asOf); w.nat(x.day);
      };
      case (#fxRevalued(x)) {
        w.byte(0x07); w.text(x.currency); w.nat(x.position); w.nat(x.equivalent); w.nat(x.revalued);
        w.nat(x.movement); wDirection(w, x.direction);
        w.nat(x.rateNumerator); w.nat(x.rateDenominator); w.nat(x.rateAsOf); w.nat(x.day);
      };
      case (#fxRealised(x)) {
        w.byte(0x08); w.text(x.currency); w.nat(x.closedPosition); w.nat(x.bookedEquivalent);
        w.nat(x.proceeds); w.nat(x.movement); wDirection(w, x.direction); w.nat(x.day);
      };
      case (#accrualAdjusted(x)) {
        w.byte(0x09); w.text(x.product); w.text(x.currency); w.nat(x.from); w.nat(x.to);
        w.nat(x.recomputed); w.nat(x.booked); w.nat(x.movement); wAdjustmentDirection(w, x.direction);
        w.nat(x.causedBy); w.nat(x.examined);
      };
      case (#deferralScheduleOpened(x)) { w.byte(0x0A); wSchedule(w, x.schedule) };
      case (#deferralAmortised(x)) { w.byte(0x0B); w.text(x.schedule); w.text(x.period); w.nat(x.sequence); w.nat(x.amount); w.nat(x.remaining) };
      case (#periodEndOpened(x)) { w.byte(0x10); w.text(x.book); w.text(x.period); w.nat(x.closingDate) };
      case (#periodEndRatesRecorded(x)) { w.byte(0x11); w.text(x.book); w.text(x.period); w.nat(x.currencies) };
      case (#periodEndAccrualComplete(x)) { w.byte(0x12); w.text(x.book); w.text(x.period); w.nat(x.lastBusinessDay) };
      case (#periodEndRevalued(x)) { w.byte(0x13); w.text(x.book); w.text(x.period); w.nat(x.currencies); w.nat(x.posted); w.nat(x.total) };
      case (#periodEndDeferralsAmortised(x)) {
        w.byte(0x14); w.text(x.book); w.text(x.period); w.nat(x.total);
        w.len16(x.rows.size());
        for (r in x.rows.vals()) { w.text(r.schedule); w.nat(r.sequence); w.nat(r.amount); w.nat(r.remaining) };
      };
      case (#periodEndReconciled(x)) { w.byte(0x15); w.text(x.book); w.text(x.period); w.nat(x.controls) };
      case (#periodEndClosed(x)) { w.byte(0x16); w.text(x.book); w.text(x.period) };
      case (#yearEndRolled(x)) {
        w.byte(0x18); w.text(x.book); w.text(x.period); w.text(x.retainedEarnings);
        w.nat(x.accountsClosed); w.len16(x.results.size());
        for (r in x.results.vals()) { w.text(r.currency); w.nat(r.profitCredits); w.nat(r.lossDebits) };
      };
      case (#bookClosedForPeriod(x)) { w.byte(0x17); w.text(x.book); w.text(x.period) };
    };
  };

  // ═══════════════════════════════════════════════════════
  //  READERS
  // ═══════════════════════════════════════════════════════

  public func rConvention(r : C.Reader) : ?T.Convention {
    switch (r.byte()) {
      case (?0) ?#sameDay; case (?1) ?#following; case (?2) ?#modifiedFollowing;
      case (?3) ?#preceding; case (?4) ?#modifiedPreceding; case (?5) ?#endOfMonth;
      case (_) null;
    }
  };

  public func rRate(r : C.Reader) : ?Fx.Rate {
    let ?currency = r.text() else return null;
    let ?functional = r.text() else return null;
    let ?numerator = r.nat() else return null;
    let ?denominator = r.nat() else return null;
    let ?asOf = r.nat() else return null;
    let ?source = r.text() else return null;
    ?{ currency; functional; numerator; denominator; asOf; source }
  };

  public func rPair(r : C.Reader) : ?Fx.PositionPair {
    let ?currency = r.text() else return null;
    let ?position = r.text() else return null;
    let ?equivalent = r.text() else return null;
    let ?unrealised = r.text() else return null;
    let ?realised = r.text() else return null;
    let ?monetary = r.bool() else return null;
    ?{ currency; position; equivalent; unrealised; realised; monetary }
  };

  public func rWindow(r : C.Reader) : ?PeriodEnd.BackValueWindow {
    let ?book = r.text() else return null;
    let ?freeDays = r.nat() else return null;
    let ?approvedDays = r.nat() else return null;
    ?{ book; freeDays; approvedDays }
  };

  public func rDirection(r : C.Reader) : ?T.Direction {
    switch (r.byte()) { case (?0) ?#gain; case (?1) ?#loss; case (?2) ?#unchanged; case (_) null }
  };

  public func rAdjustmentDirection(r : C.Reader) : ?T.AdjustmentDirection {
    switch (r.byte()) { case (?0) ?#increase; case (?1) ?#decrease; case (?2) ?#unchanged; case (_) null }
  };

  public func rSchedule(r : C.Reader) : ?Deferrals.Schedule {
    let ?id = r.text() else return null;
    let kind : Deferrals.Kind = switch (r.byte()) { case (?0) #unearnedIncome; case (?1) #prepaidExpense; case (_) return null };
    let ?currency = r.text() else return null;
    let ?amount = r.nat() else return null;
    let ?periods = r.nat() else return null;
    let ?deferralAccount = r.text() else return null;
    let ?recognitionAccount = r.text() else return null;
    let ?book = r.text() else return null;
    let ?openedOn = r.nat() else return null;
    ?{ id; kind; currency; amount; periods; deferralAccount; recognitionAccount; book; openedOn }
  };

  public func readEvent(r : C.Reader) : ?T.CloseEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 { let ?c = r.text() else return null; ?#functionalCurrencySet({ currency = c }) };
      case 0x02 { let ?p = rPair(r) else return null; ?#fxPairSet({ pair = p }) };
      case 0x03 { let ?x = rRate(r) else return null; ?#fxRateSet({ rate = x }) };
      case 0x04 { let ?x = rWindow(r) else return null; ?#backValueWindowSet({ window = x }) };
      case 0x05 {
        let ?book = r.text() else return null;
        let ?valueDate = r.nat() else return null;
        let ?approver = r.principal() else return null;
        let ?reason = r.text() else return null;
        ?#backValueApproved({ book; valueDate; approver; reason })
      };
      case 0x06 {
        let ?sell = r.text() else return null;
        let ?sellAmount = r.nat() else return null;
        let ?buy = r.text() else return null;
        let ?buyAmount = r.nat() else return null;
        let ?rateNumerator = r.nat() else return null;
        let ?rateDenominator = r.nat() else return null;
        let ?asOf = r.nat() else return null;
        let ?day = r.nat() else return null;
        ?#fxDealBooked({ sell; sellAmount; buy; buyAmount; rateNumerator; rateDenominator; asOf; day })
      };
      case 0x07 {
        let ?currency = r.text() else return null;
        let ?position = r.nat() else return null;
        let ?equivalent = r.nat() else return null;
        let ?revalued = r.nat() else return null;
        let ?movement = r.nat() else return null;
        let ?direction = rDirection(r) else return null;
        let ?rateNumerator = r.nat() else return null;
        let ?rateDenominator = r.nat() else return null;
        let ?rateAsOf = r.nat() else return null;
        let ?day = r.nat() else return null;
        ?#fxRevalued({ currency; position; equivalent; revalued; movement; direction; rateNumerator; rateDenominator; rateAsOf; day })
      };
      case 0x08 {
        let ?currency = r.text() else return null;
        let ?closedPosition = r.nat() else return null;
        let ?bookedEquivalent = r.nat() else return null;
        let ?proceeds = r.nat() else return null;
        let ?movement = r.nat() else return null;
        let ?direction = rDirection(r) else return null;
        let ?day = r.nat() else return null;
        ?#fxRealised({ currency; closedPosition; bookedEquivalent; proceeds; movement; direction; day })
      };
      case 0x09 {
        let ?product = r.text() else return null;
        let ?currency = r.text() else return null;
        let ?from = r.nat() else return null;
        let ?to = r.nat() else return null;
        let ?recomputed = r.nat() else return null;
        let ?booked = r.nat() else return null;
        let ?movement = r.nat() else return null;
        let ?direction = rAdjustmentDirection(r) else return null;
        let ?causedBy = r.nat() else return null;
        let ?examined = r.nat() else return null;
        ?#accrualAdjusted({ product; currency; from; to; recomputed; booked; movement; direction; causedBy; examined })
      };
      case 0x0A { let ?s = rSchedule(r) else return null; ?#deferralScheduleOpened({ schedule = s }) };
      case 0x0B {
        let ?schedule = r.text() else return null;
        let ?period = r.text() else return null;
        let ?sequence = r.nat() else return null;
        let ?amount = r.nat() else return null;
        let ?remaining = r.nat() else return null;
        ?#deferralAmortised({ schedule; period; sequence; amount; remaining })
      };
      case 0x10 {
        let ?book = r.text() else return null;
        let ?period = r.text() else return null;
        let ?closingDate = r.nat() else return null;
        ?#periodEndOpened({ book; period; closingDate })
      };
      case 0x11 {
        let ?book = r.text() else return null;
        let ?period = r.text() else return null;
        let ?currencies = r.nat() else return null;
        ?#periodEndRatesRecorded({ book; period; currencies })
      };
      case 0x12 {
        let ?book = r.text() else return null;
        let ?period = r.text() else return null;
        let ?lastBusinessDay = r.nat() else return null;
        ?#periodEndAccrualComplete({ book; period; lastBusinessDay })
      };
      case 0x13 {
        let ?book = r.text() else return null;
        let ?period = r.text() else return null;
        let ?currencies = r.nat() else return null;
        let ?posted = r.nat() else return null;
        let ?total = r.nat() else return null;
        ?#periodEndRevalued({ book; period; currencies; posted; total })
      };
      case 0x14 {
        let ?book = r.text() else return null;
        let ?period = r.text() else return null;
        let ?total = r.nat() else return null;
        let ?n = r.len16() else return null;
        let rows = List.empty<{ schedule : Text; sequence : Nat; amount : Nat; remaining : Nat }>();
        var i = 0;
        while (i < n) {
          let ?schedule = r.text() else return null;
          let ?sequence = r.nat() else return null;
          let ?amount = r.nat() else return null;
          let ?remaining = r.nat() else return null;
          List.add(rows, { schedule; sequence; amount; remaining });
          i += 1;
        };
        ?#periodEndDeferralsAmortised({ book; period; total; rows = List.toArray(rows) })
      };
      case 0x15 {
        let ?book = r.text() else return null;
        let ?period = r.text() else return null;
        let ?controls = r.nat() else return null;
        ?#periodEndReconciled({ book; period; controls })
      };
      case 0x16 {
        let ?book = r.text() else return null;
        let ?period = r.text() else return null;
        ?#periodEndClosed({ book; period })
      };
      case 0x17 {
        let ?book = r.text() else return null;
        let ?period = r.text() else return null;
        ?#bookClosedForPeriod({ book; period })
      };
      case 0x19 { let ?currency = r.text() else return null; let ?calendar = r.calendar() else return null; ?#currencyCalendarSet({ currency; calendar }) };
      case 0x1A {
        let ?redenomination = rRedenomination(r) else return null;
        let ?n = r.len16() else return null;
        let products = List.empty<Text>();
        var i = 0; while (i < n) { let ?p = r.text() else return null; List.add(products, p); i += 1 };
        ?#redenominationDeclared({ redenomination; products = List.toArray(products) })
      };
      case 0x1B {
        let ?from = r.text() else return null; let ?to = r.text() else return null; let ?account = r.text() else return null;
        let ?subledger = r.optBlob() else return null; let ?productAccount = r.optNat() else return null;
        let ?oldAmount = r.nat() else return null; let ?newAmount = r.nat() else return null; let ?creditBalance = r.bool() else return null; let ?day = r.nat() else return null;
        ?#balanceRedenominated({ from; to; account; subledger; productAccount; oldAmount; newAmount; creditBalance; day })
      };
      case 0x1C {
        let ?from = r.text() else return null; let ?to = r.text() else return null; let ?rows = r.nat() else return null; let ?oldTotal = r.nat() else return null;
        let ?newTotal = r.nat() else return null; let ?roundingAmount = r.nat() else return null; let ?roundingDebit = r.bool() else return null; let ?day = r.nat() else return null;
        ?#redenominationCompleted({ from; to; rows; oldTotal; newTotal; roundingAmount; roundingDebit; day })
      };
      case 0x18 {
        let ?book = r.text() else return null;
        let ?period = r.text() else return null;
        let ?retainedEarnings = r.text() else return null;
        let ?accountsClosed = r.nat() else return null;
        let ?n = r.len16() else return null;
        let results = List.empty<{ currency : Text; profitCredits : Nat; lossDebits : Nat }>();
        var i = 0;
        while (i < n) {
          let ?currency = r.text() else return null;
          let ?profitCredits = r.nat() else return null;
          let ?lossDebits = r.nat() else return null;
          List.add(results, { currency; profitCredits; lossDebits });
          i += 1;
        };
        ?#yearEndRolled({ book; period; retainedEarnings; accountsClosed; results = List.toArray(results) })
      };
      case _ null;
    }
  };
};
