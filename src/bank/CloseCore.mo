/// CloseCore.mo; the close layer's state, which is the fold of the log.
///
/// Rates, position pairs, deferral schedules, back-value windows and approvals, the
/// period-end runs and the books closed per period. No balance: a position is a
/// journal balance in its currency and its equivalent is a journal balance in the
/// functional currency, both read through `Posting`, so a revaluation cannot disagree
/// with the deal that created the position.
///
/// The one figure here that looks like money and is not is a deferral schedule's
/// posted-period count: it is the cursor that makes the next amortisation the right
/// one, and the amount it implies is recomputed from the schedule's own arithmetic
/// every time rather than carried.

import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Principal "mo:core/Principal";
import Map "mo:core/Map";
import List "mo:core/List";
import Array "mo:core/Array";
import Order "mo:core/Order";
import Runtime "mo:core/Runtime";

import JT "mo:journal/JournalTypes";
import JC "mo:journal/Canonical";

import T "CloseTypes";
import Fx "Fx";
import Deferrals "Deferrals";
import PeriodEnd "PeriodEnd";

module {

  public type RunEntry = {
    book : Text;
    period : JT.PeriodId;
    closingDate : JT.Day;
    var state : PeriodEnd.State;
    openedAtBlock : Nat;
    var currenciesRevalued : Nat;
    var unrealisedPosted : Nat;
    var deferralsPosted : Nat;
    var controlsChecked : Nat;
    var closedAtBlock : ?Nat;
  };

  public type ScheduleEntry = {
    schedule : Deferrals.Schedule;
    /// Which accounting periods have been posted, in order, so a re-run is a
    /// recognised duplicate and a gap is visible.
    posted : List.List<JT.PeriodId>;
    openedAtBlock : Nat;
  };

  public type State = {
    var functional : ?JT.Currency;
    /// (book, period) -> the block that rolled the fiscal year's result. A year is
    /// rolled once, and the record is what makes a second attempt a refusal.
    rolled : Map.Map<(Text, Text), Nat>;
    pairs : Map.Map<Text, Fx.PositionPair>;
    /// (currency, day) -> the rate recorded for that day. A revaluation reads the
    /// rate for its own closing date and nothing else: there is no nearest-match and
    /// no carry-forward.
    rates : Map.Map<(Text, Nat), Fx.Rate>;
    windows : Map.Map<Text, PeriodEnd.BackValueWindow>;
    /// (book, value date) -> the approval that opened that day for back-valuing.
    approvals : Map.Map<(Text, Nat), { approver : Principal; reason : Text; atBlock : Nat }>;
    runs : Map.Map<(Text, Text), RunEntry>;
    schedules : Map.Map<Text, ScheduleEntry>;
    /// (book, period) -> closed. The bank layer refuses a posting touching the book.
    closedBooks : Map.Map<(Text, Text), Nat>;
    /// currency -> its own working-day calendar (S4.1); a value date in the currency is a business day in both.
    calendars : Map.Map<Text, JT.CalendarConfig>;
    /// from -> the redenomination declared, with the products it re-versioned and whether the end-of-day job completed it.
    /// The record stays after completion: the day's plan is derived from what was declared for the day, which must not
    /// change while the run is open.
    redenominations : Map.Map<Text, { redenomination : T.Redenomination; products : [Text]; completed : Bool }>;
    /// from -> to, for every currency closed by a completed redenomination.
    closedCurrencies : Map.Map<Text, Text>;
  };

  func cmpTN(a : (Text, Nat), b : (Text, Nat)) : Order.Order {
    switch (Text.compare(a.0, b.0)) { case (#equal) Nat.compare(a.1, b.1); case (o) o }
  };
  func cmpTT(a : (Text, Text), b : (Text, Text)) : Order.Order {
    switch (Text.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o }
  };

  public func newState() : State {
    {
      var functional = null;
      rolled = Map.empty<(Text, Text), Nat>();
      pairs = Map.empty<Text, Fx.PositionPair>();
      rates = Map.empty<(Text, Nat), Fx.Rate>();
      windows = Map.empty<Text, PeriodEnd.BackValueWindow>();
      approvals = Map.empty<(Text, Nat), { approver : Principal; reason : Text; atBlock : Nat }>();
      runs = Map.empty<(Text, Text), RunEntry>();
      schedules = Map.empty<Text, ScheduleEntry>();
      closedBooks = Map.empty<(Text, Text), Nat>();
      calendars = Map.empty<Text, JT.CalendarConfig>();
      redenominations = Map.empty<Text, { redenomination : T.Redenomination; products : [Text]; completed : Bool }>();
      closedCurrencies = Map.empty<Text, Text>();
    }
  };

  public type Event = T.CloseEvent;

  // ═══════════════════════════════════════════════════════
  //  LOOKUPS
  // ═══════════════════════════════════════════════════════

  public func functional(s : State) : ?JT.Currency { s.functional };
  public func currencyCalendar(s : State, currency : Text) : ?JT.CalendarConfig { Map.get(s.calendars, Text.compare, currency) };
  public func listCurrencyCalendars(s : State) : [(Text, JT.CalendarConfig)] { Map.toArray(s.calendars) };
  public type RedenominationEntry = { redenomination : T.Redenomination; products : [Text]; completed : Bool };
  /// The redenomination of a currency declared and not yet carried out.
  public func pendingRedenomination(s : State, from : Text) : ?RedenominationEntry { switch (Map.get(s.redenominations, Text.compare, from)) { case (?e) { if (e.completed) null else ?e }; case null null } };
  public func pendingRedenominations(s : State) : [RedenominationEntry] { Array.filter<RedenominationEntry>(Array.map<(Text, RedenominationEntry), RedenominationEntry>(Map.toArray(s.redenominations), func((_, r)) { r }), func(e) { not e.completed }) };
  /// The completed redenomination a product went through, if any: its day, its old currency and its ratio; what an
  /// accrual window spanning the day needs to value the old-currency days.
  public func redenominationOfProduct(s : State, product : Text) : ?{ day : Nat; from : Text; to : Text; ratioNumerator : Nat; ratioDenominator : Nat } {
    var best : ?{ day : Nat; from : Text; to : Text; ratioNumerator : Nat; ratioDenominator : Nat } = null;
    for ((_, e) in Map.entries(s.redenominations)) {
      if (e.completed and Array.find<Text>(e.products, func(p) { Text.equal(p, product) }) != null) {
        let r = e.redenomination;
        switch (best) { case (?b) { if (r.day > b.day) best := ?{ day = r.day; from = r.from; to = r.to; ratioNumerator = r.ratioNumerator; ratioDenominator = r.ratioDenominator } }; case null best := ?{ day = r.day; from = r.from; to = r.to; ratioNumerator = r.ratioNumerator; ratioDenominator = r.ratioDenominator } };
      };
    };
    best
  };
  /// Every redenomination declared for a business date, completed or not: what the date's end-of-day plan is built from.
  public func redenominationsDeclaredOn(s : State, day : Nat) : [RedenominationEntry] { Array.filter<RedenominationEntry>(Array.map<(Text, RedenominationEntry), RedenominationEntry>(Map.toArray(s.redenominations), func((_, r)) { r }), func(e) { e.redenomination.day == day }) };
  /// The successor of a currency closed by a redenomination, if it was.
  public func closedTo(s : State, currency : Text) : ?Text { Map.get(s.closedCurrencies, Text.compare, currency) };
  /// The bank's calendar merged with the currencies' own: a rest day or holiday of any is one of the result; the
  /// shift policy is the bank's (`#reject` in a bank deployment; the product layer resolves, the journal refuses).
  public func mergedCalendar(s : State, bank : ?JT.CalendarConfig, currencies : [Text]) : ?JT.CalendarConfig {
    var out = bank;
    for (c in currencies.vals()) {
      switch (Map.get(s.calendars, Text.compare, c)) {
        case (?cal) {
          out := switch (out) {
            case null ?cal;
            case (?b) ?{ restDays = union(b.restDays, cal.restDays); holidays = union(b.holidays, cal.holidays); policy = b.policy };
          };
        };
        case null {};
      };
    };
    out
  };
  func union(a : [Nat], b : [Nat]) : [Nat] {
    let out = List.fromArray<Nat>(a);
    for (x in b.vals()) { if (Array.find<Nat>(a, func(y) { y == x }) == null) List.add(out, x) };
    List.toArray(out)
  };
  public func getPair(s : State, currency : Text) : ?Fx.PositionPair { Map.get(s.pairs, Text.compare, currency) };
  public func listPairs(s : State) : [Fx.PositionPair] {
    Array.map<(Text, Fx.PositionPair), Fx.PositionPair>(Map.toArray(s.pairs), func((_, p)) { p })
  };
  public func pairCount(s : State) : Nat { Map.size(s.pairs) };

  /// The rate recorded for exactly this day, and nothing else. An earlier day's rate
  /// is never substituted, which is why this takes the day rather than searching.
  public func rateOn(s : State, currency : Text, day : JT.Day) : ?Fx.Rate {
    Map.get(s.rates, cmpTN, (currency, day))
  };

  public func rateCount(s : State) : Nat { Map.size(s.rates) };

  /// One page of the recorded rates, by (currency, day) from a cursor (inclusive).
  public func ratesFrom(s : State, cursor : ?(Text, Nat), limit : Nat) : { rows : [Fx.Rate]; next : ?(Text, Nat) } {
    let rows = List.empty<Fx.Rate>();
    let it = switch (cursor) { case (?c) Map.entriesFrom(s.rates, cmpTN, c); case null Map.entries(s.rates) };
    for ((k, r) in it) { if (List.size(rows) >= limit) return { rows = List.toArray(rows); next = ?k }; List.add(rows, r) };
    { rows = List.toArray(rows); next = null }
  };
  public func listRates(s : State) : [Fx.Rate] {
    Array.map<((Text, Nat), Fx.Rate), Fx.Rate>(Map.toArray(s.rates), func((_, r)) { r })
  };

  public func window(s : State, book : Text) : PeriodEnd.BackValueWindow {
    switch (Map.get(s.windows, Text.compare, book)) {
      case (?w) w;
      case null { { book; freeDays = PeriodEnd.DEFAULT_FREE_DAYS; approvedDays = PeriodEnd.DEFAULT_APPROVED_DAYS } };
    }
  };

  public func windowRecorded(s : State, book : Text) : Bool { Map.containsKey(s.windows, Text.compare, book) };

  public func approvalFor(s : State, book : Text, valueDate : JT.Day) : ?{ approver : Principal; reason : Text; atBlock : Nat } {
    Map.get(s.approvals, cmpTN, (book, valueDate))
  };

  public func approvalCount(s : State) : Nat { Map.size(s.approvals) };

  public func getRun(s : State, book : Text, period : Text) : ?RunEntry { Map.get(s.runs, cmpTT, (book, period)) };
  public func runCount(s : State) : Nat { Map.size(s.runs) };

  public func getSchedule(s : State, id : Text) : ?ScheduleEntry { Map.get(s.schedules, Text.compare, id) };
  public func scheduleCount(s : State) : Nat { Map.size(s.schedules) };

  public func listSchedules(s : State) : [ScheduleEntry] {
    Array.map<(Text, ScheduleEntry), ScheduleEntry>(Map.toArray(s.schedules), func((_, e)) { e })
  };

  public func yearRolled(s : State, book : Text, period : Text) : Bool {
    Map.containsKey(s.rolled, cmpTT, (book, period))
  };

  public func rolledCount(s : State) : Nat { Map.size(s.rolled) };

  public func bookClosed(s : State, book : Text, period : Text) : Bool {
    Map.containsKey(s.closedBooks, cmpTT, (book, period))
  };

  public func closedBookCount(s : State) : Nat { Map.size(s.closedBooks) };

  public func postedPeriods(e : ScheduleEntry) : Nat { List.size(e.posted) };

  public func hasPosted(e : ScheduleEntry, period : Text) : Bool {
    for (p in List.values(e.posted)) { if (Text.equal(p, period)) return true };
    false
  };

  /// How much of a schedule has been amortised, recomputed from its own arithmetic
  /// over the periods posted; never carried as a running total.
  public func amortised(e : ScheduleEntry) : Nat {
    var total = 0;
    var n = 1;
    let posted = List.size(e.posted);
    while (n <= posted) {
      switch (Deferrals.amountFor(e.schedule, n)) { case (#ok(a)) total += a; case (#err(_)) {} };
      n += 1;
    };
    total
  };

  public func remaining(e : ScheduleEntry) : Nat { Deferrals.remainingAfter(e.schedule, List.size(e.posted)) };

  // ═══════════════════════════════════════════════════════
  //  VIEWS
  // ═══════════════════════════════════════════════════════

  public func runView(r : RunEntry) : T.RunView {
    {
      book = r.book; period = r.period; closingDate = r.closingDate;
      state = PeriodEnd.stateText(r.state); openedAtBlock = r.openedAtBlock;
      currenciesRevalued = r.currenciesRevalued; unrealisedPosted = r.unrealisedPosted;
      deferralsPosted = r.deferralsPosted; controlsChecked = r.controlsChecked;
      closedAtBlock = r.closedAtBlock;
    }
  };

  public func listRunViews(s : State) : [T.RunView] {
    Array.map<((Text, Text), RunEntry), T.RunView>(Map.toArray(s.runs), func((_, r)) { runView(r) })
  };
  /// One page of the period-end runs, by (book, period) from a cursor (inclusive).
  public func runViewsFrom(s : State, cursor : ?(Text, Text), limit : Nat) : { rows : [T.RunView]; next : ?(Text, Text) } {
    let rows = List.empty<T.RunView>();
    let it = switch (cursor) { case (?c) Map.entriesFrom(s.runs, cmpTT, c); case null Map.entries(s.runs) };
    for ((k, r) in it) { if (List.size(rows) >= limit) return { rows = List.toArray(rows); next = ?k }; List.add(rows, runView(r)) };
    { rows = List.toArray(rows); next = null }
  };

  public func scheduleView(e : ScheduleEntry) : T.ScheduleView {
    {
      schedule = e.schedule; postedPeriods = List.size(e.posted);
      amortised = amortised(e); remaining = remaining(e); openedAtBlock = e.openedAtBlock;
    }
  };

  public func listScheduleViews(s : State) : [T.ScheduleView] {
    Array.map<(Text, ScheduleEntry), T.ScheduleView>(Map.toArray(s.schedules), func((_, e)) { scheduleView(e) })
  };

  // ═══════════════════════════════════════════════════════
  //  THE FOLD
  // ═══════════════════════════════════════════════════════

  func mustRun(s : State, book : Text, period : Text) : RunEntry {
    switch (Map.get(s.runs, cmpTT, (book, period))) {
      case (?r) r;
      case null Runtime.trap("close fold: unknown period-end run " # book # "/" # period);
    }
  };

  public func apply(s : State, blockIndex : Nat, e : Event) {
    switch (e) {
      case (#functionalCurrencySet(x)) { s.functional := ?x.currency };
      case (#fxPairSet(x)) { Map.add(s.pairs, Text.compare, x.pair.currency, x.pair) };
      case (#fxRateSet(x)) { Map.add(s.rates, cmpTN, (x.rate.currency, x.rate.asOf), x.rate) };
      case (#backValueWindowSet(x)) { Map.add(s.windows, Text.compare, x.window.book, x.window) };
      case (#backValueApproved(x)) {
        Map.add(s.approvals, cmpTN, (x.book, x.valueDate), { approver = x.approver; reason = x.reason; atBlock = blockIndex });
      };
      case (#currencyCalendarSet(x)) { switch (x.calendar) { case (?c) Map.add(s.calendars, Text.compare, x.currency, c); case null ignore Map.delete(s.calendars, Text.compare, x.currency) } };
      case (#redenominationDeclared(x)) { Map.add(s.redenominations, Text.compare, x.redenomination.from, { redenomination = x.redenomination; products = x.products; completed = false }) };
      case (#balanceRedenominated(_)) {};   // the money is the journal's
      case (#redenominationCompleted(x)) {
        switch (Map.get(s.redenominations, Text.compare, x.from)) { case (?e) Map.add(s.redenominations, Text.compare, x.from, { e with completed = true }); case null {} };
        Map.add(s.closedCurrencies, Text.compare, x.from, x.to);
        // the position pair of the old currency, if one exists, is the new currency's from here on
        switch (Map.get(s.pairs, Text.compare, x.from)) {
          case (?p) { ignore Map.delete(s.pairs, Text.compare, x.from); Map.add(s.pairs, Text.compare, x.to, { p with currency = x.to }) };
          case null {};
        };
      };
      case (#fxDealBooked(_)) {};      // the money is the journal's; nothing to fold
      case (#fxRevalued(_)) {};
      case (#fxRealised(_)) {};
      case (#accrualAdjusted(_)) {};
      case (#deferralScheduleOpened(x)) {
        let entry : ScheduleEntry = {
          schedule = x.schedule; posted = List.empty<JT.PeriodId>(); openedAtBlock = blockIndex;
        };
        Map.add(s.schedules, Text.compare, x.schedule.id, entry);
      };
      case (#deferralAmortised(x)) {
        switch (Map.get(s.schedules, Text.compare, x.schedule)) {
          case (?entry) List.add(entry.posted, x.period);
          case null Runtime.trap("close fold: amortisation of unknown schedule " # x.schedule);
        };
      };
      case (#periodEndOpened(x)) {
        let entry : RunEntry = {
          book = x.book; period = x.period; closingDate = x.closingDate;
          var state = #opened; openedAtBlock = blockIndex;
          var currenciesRevalued = 0; var unrealisedPosted = 0;
          var deferralsPosted = 0; var controlsChecked = 0;
          var closedAtBlock = null;
        };
        Map.add(s.runs, cmpTT, (x.book, x.period), entry);
      };
      case (#periodEndRatesRecorded(x)) { mustRun(s, x.book, x.period).state := #ratesRecorded };
      case (#periodEndAccrualComplete(x)) { mustRun(s, x.book, x.period).state := #accrualComplete };
      case (#periodEndRevalued(x)) {
        let r = mustRun(s, x.book, x.period);
        r.state := #revalued;
        r.currenciesRevalued := x.currencies;
        r.unrealisedPosted := x.posted;
      };
      case (#periodEndDeferralsAmortised(x)) {
        let r = mustRun(s, x.book, x.period);
        r.state := #deferralsAmortised;
        r.deferralsPosted := x.rows.size();
        // every schedule the step amortised advances its own cursor, so the next
        // period takes the next instalment rather than repeating this one
        for (row in x.rows.vals()) {
          switch (Map.get(s.schedules, Text.compare, row.schedule)) {
            case (?entry) List.add(entry.posted, x.period);
            case null Runtime.trap("close fold: the deferral step names unknown schedule " # row.schedule);
          };
        };
      };
      case (#periodEndReconciled(x)) {
        let r = mustRun(s, x.book, x.period);
        r.state := #reconciled;
        r.controlsChecked := x.controls;
      };
      case (#periodEndClosed(x)) {
        let r = mustRun(s, x.book, x.period);
        r.state := #closed;
        r.closedAtBlock := ?blockIndex;
      };
      case (#yearEndRolled(x)) { Map.add(s.rolled, cmpTT, (x.book, x.period), blockIndex) };
      case (#bookClosedForPeriod(x)) { Map.add(s.closedBooks, cmpTT, (x.book, x.period), blockIndex) };
    };
  };

  // ═══════════════════════════════════════════════════════
  //  FINGERPRINT
  // ═══════════════════════════════════════════════════════

  public func fingerprintInto(w : JC.Writer, s : State) {
    switch (s.functional) { case null w.byte(0); case (?c) { w.byte(1); w.text(c) } };
    w.nat(Map.size(s.pairs));
    for ((_, p) in Map.entries(s.pairs)) {
      w.text(p.currency); w.text(p.position); w.text(p.equivalent);
      w.text(p.unrealised); w.text(p.realised); w.bool(p.monetary);
    };
    w.nat(Map.size(s.rates));
    for (((c, d), r) in Map.entries(s.rates)) {
      w.text(c); w.nat(d); w.nat(r.numerator); w.nat(r.denominator); w.text(r.functional); w.text(r.source);
    };
    w.nat(Map.size(s.windows));
    for ((_, win) in Map.entries(s.windows)) { w.text(win.book); w.nat(win.freeDays); w.nat(win.approvedDays) };
    w.nat(Map.size(s.calendars));
    for ((c, cal) in Map.entries(s.calendars)) { w.text(c); w.calendar(?cal) };
    w.nat(Map.size(s.redenominations));
    for ((_, e) in Map.entries(s.redenominations)) { let r = e.redenomination; w.text(r.from); w.text(r.to); w.nat(Nat8.toNat(r.minorUnits)); w.nat(r.ratioNumerator); w.nat(r.ratioDenominator); w.text(r.bridgeAccount); w.text(r.roundingAccount); w.nat(r.day); w.bool(e.completed); w.nat(e.products.size()); for (p in e.products.vals()) w.text(p) };
    w.nat(Map.size(s.closedCurrencies));
    for ((f, t) in Map.entries(s.closedCurrencies)) { w.text(f); w.text(t) };
    w.nat(Map.size(s.approvals));
    for (((b, d), a) in Map.entries(s.approvals)) { w.text(b); w.nat(d); w.principal(a.approver); w.text(a.reason); w.nat(a.atBlock) };
    w.nat(Map.size(s.runs));
    for ((_, r) in Map.entries(s.runs)) {
      w.text(r.book); w.text(r.period); w.nat(r.closingDate);
      w.text(PeriodEnd.stateText(r.state)); w.nat(r.openedAtBlock);
      w.nat(r.currenciesRevalued); w.nat(r.unrealisedPosted);
      w.nat(r.deferralsPosted); w.nat(r.controlsChecked);
      switch (r.closedAtBlock) { case null w.byte(0); case (?n) { w.byte(1); w.nat(n) } };
    };
    w.nat(Map.size(s.schedules));
    for ((_, e) in Map.entries(s.schedules)) {
      let sch = e.schedule;
      w.text(sch.id); w.text(Deferrals.kindText(sch.kind)); w.text(sch.currency);
      w.nat(sch.amount); w.nat(sch.periods); w.text(sch.deferralAccount);
      w.text(sch.recognitionAccount); w.text(sch.book); w.nat(sch.openedOn);
      w.len16(List.size(e.posted));
      for (p in List.values(e.posted)) { w.text(p) };
      w.nat(e.openedAtBlock);
    };
    w.nat(Map.size(s.closedBooks));
    for (((b, p), at) in Map.entries(s.closedBooks)) { w.text(b); w.text(p); w.nat(at) };
    w.nat(Map.size(s.rolled));
    for (((b, p), at) in Map.entries(s.rolled)) { w.text(b); w.text(p); w.nat(at) };
  };
};
