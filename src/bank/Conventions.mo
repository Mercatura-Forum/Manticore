/// Conventions.mo: product value-date conventions, and the one place a date moves.
///
/// The journal can shift a non-business value date according to a journal-wide
/// policy and record what was asked for. A product layer also has value-date
/// conventions, and they differ per product: a payment moves to the next business
/// day, a term deposit's maturity uses modified following, a deposit credit values
/// same day. Two layers that can both move a date will eventually disagree, and the
/// disagreement will be silent because each layer's output looks correct on its own.
///
/// So this is a configuration invariant rather than a convention:
///
///   In a bank deployment the journal's calendar policy is `#reject`. The product
///   layer resolves the effective value date from the product's convention and the
///   bank calendar, records the requested date beside it, and submits the resolved
///   date. A date the bank has already resolved can never be moved again, because
///   the journal refuses rather than shifts.
///
/// The journal's calendar stays the backstop that makes a mistake loud: if this
/// layer ever submits a non-business date the posting is refused with
/// `#ValueDateNotBusinessDay` rather than quietly moved. `requiresRejectPolicy`
/// is the check a deployment is held to, and the period-end process refuses to
/// open while it does not hold.
///
/// The conventions are the money-market set. `modifiedFollowing` is the one worth
/// knowing: the next business day unless that crosses into the next month, in which
/// case the previous business day; ISDA's definition and what every money-market
/// desk means by it.

import Nat "mo:core/Nat";
import Text "mo:core/Text";
import List "mo:core/List";

import JT "mo:journal/JournalTypes";
import Calendar "mo:journal/Calendar";
import CivilDate "mo:journal/CivilDate";

module {

  public type Day = JT.Day;

  public type Convention = {
    #sameDay;
    #following;
    #modifiedFollowing;
    #preceding;
    #modifiedPreceding;
    #endOfMonth;
  };

  public func conventionText(c : Convention) : Text {
    switch (c) {
      case (#sameDay) "sameDay"; case (#following) "following";
      case (#modifiedFollowing) "modifiedFollowing"; case (#preceding) "preceding";
      case (#modifiedPreceding) "modifiedPreceding"; case (#endOfMonth) "endOfMonth";
    }
  };

  public func conventions() : [Convention] {
    [#sameDay, #following, #modifiedFollowing, #preceding, #modifiedPreceding, #endOfMonth]
  };

  /// A resolved date: what was asked for and what it became. `moved` is false when
  /// the requested date was already a business day, which is the common case and
  /// the one that must not be recorded as a shift.
  public type Resolved = { requested : Day; effective : Day; moved : Bool; convention : Convention };

  public type Fault = { #noEarlierBusinessDay : { requested : Day }; #notABusinessDay : { day : Day } };

  /// The deployment invariant: the journal's own policy must be `#reject`, so that
  /// this layer is the only thing that moves a date. A journal with no calendar at
  /// all also satisfies it, it shifts nothing, and that is stated rather than
  /// assumed, because "no calendar" and "a calendar that rejects" are the same
  /// thing for this invariant and different things for the date arithmetic.
  public func requiresRejectPolicy(calendar : ?JT.CalendarConfig) : ?Text {
    switch (calendar) {
      case null null;
      case (?c) {
        switch (c.policy) {
          case (#reject) null;
          case (other) ?("the journal's calendar policy is " # policyText(other)
            # "; a bank deployment requires #reject so the product layer is the only "
            # "thing that moves a value date");
        }
      };
    }
  };

  public func policyText(p : JT.ShiftPolicy) : Text {
    switch (p) { case (#reject) "#reject"; case (#previous) "#previous"; case (#next) "#next"; case (#nearest) "#nearest" }
  };

  func cal(c : JT.CalendarConfig) : Calendar.Calendar { { restDays = c.restDays; holidays = c.holidays } };

  func sameMonth(a : Day, b : Day) : Bool {
    let (ay, am, _) = CivilDate.toCivil(a);
    let (by, bm, _) = CivilDate.toCivil(b);
    ay == by and am == bm
  };

  /// The last day of the month `d` falls in.
  public func monthEnd(d : Day) : Day {
    let (y, m, _) = CivilDate.toCivil(d);
    switch (CivilDate.fromCivil(y, m, CivilDate.daysInMonth(y, m))) { case (?x) x; case null d }
  };

  /// Resolve a requested value date under a convention and a calendar. With no
  /// calendar every date is a business day and nothing moves.
  public func resolve(calendar : ?JT.CalendarConfig, convention : Convention, requested : Day) : { #ok : Resolved; #err : Fault } {
    let ?cfg = calendar else return #ok({ requested; effective = requested; moved = false; convention });
    let c = cal(cfg);
    switch (convention) {
      case (#sameDay) {
        if (Calendar.isBusinessDay(c, requested)) #ok({ requested; effective = requested; moved = false; convention })
        else #err(#notABusinessDay({ day = requested }))
      };
      case (#following) {
        let e = Calendar.nextBusinessDay(c, requested);
        #ok({ requested; effective = e; moved = e != requested; convention })
      };
      case (#preceding) {
        switch (Calendar.previousBusinessDay(c, requested)) {
          case (?e) #ok({ requested; effective = e; moved = e != requested; convention });
          case null #err(#noEarlierBusinessDay({ requested }));
        }
      };
      case (#modifiedFollowing) {
        let e = Calendar.nextBusinessDay(c, requested);
        if (sameMonth(e, requested)) #ok({ requested; effective = e; moved = e != requested; convention })
        else {
          // crossing the month end: fall back to the preceding business day
          switch (Calendar.previousBusinessDay(c, requested)) {
            case (?p) #ok({ requested; effective = p; moved = p != requested; convention });
            case null #err(#noEarlierBusinessDay({ requested }));
          }
        }
      };
      case (#modifiedPreceding) {
        switch (Calendar.previousBusinessDay(c, requested)) {
          case (?p) {
            if (sameMonth(p, requested)) #ok({ requested; effective = p; moved = p != requested; convention })
            else {
              let e = Calendar.nextBusinessDay(c, requested);
              #ok({ requested; effective = e; moved = e != requested; convention })
            }
          };
          case null {
            let e = Calendar.nextBusinessDay(c, requested);
            #ok({ requested; effective = e; moved = e != requested; convention })
          };
        }
      };
      case (#endOfMonth) {
        // the last business day of the requested date's own month
        let last = monthEnd(requested);
        switch (Calendar.previousBusinessDay(c, last)) {
          case (?p) {
            if (sameMonth(p, requested)) #ok({ requested; effective = p; moved = p != requested; convention })
            else #err(#noEarlierBusinessDay({ requested }))
          };
          case null #err(#noEarlierBusinessDay({ requested }));
        }
      };
    }
  };

  /// Is this day a business day under the deployment's calendar? Used by the
  /// period-end process, which may not close a period before its final business day
  /// has been rolled through.
  public func isBusinessDay(calendar : ?JT.CalendarConfig, day : Day) : Bool {
    switch (calendar) { case null true; case (?cfg) Calendar.isBusinessDay(cal(cfg), day) }
  };

  /// The last business day on or before `day`, or `day` itself with no calendar.
  public func lastBusinessDayOnOrBefore(calendar : ?JT.CalendarConfig, day : Day) : ?Day {
    switch (calendar) {
      case null ?day;
      case (?cfg) Calendar.previousBusinessDay(cal(cfg), day);
    }
  };

  /// Every business day in `[from, to]`, which is what an end-of-day completeness
  /// check enumerates.
  public func businessDaysBetween(calendar : ?JT.CalendarConfig, from : Day, to : Day) : [Day] {
    if (to < from) return [];
    let out = List.empty<Day>();
    var d = from;
    while (d <= to) {
      if (isBusinessDay(calendar, d)) List.add(out, d);
      d += 1;
    };
    List.toArray(out)
  };

  /// The number of business days strictly between two dates, which is what a
  /// back-value window is measured in.
  public func businessDaysApart(calendar : ?JT.CalendarConfig, earlier : Day, later : Day) : Nat {
    if (later <= earlier) return 0;
    var n = 0;
    var d = earlier + 1;
    while (d <= later) {
      if (isBusinessDay(calendar, d)) n += 1;
      d += 1;
    };
    n
  };
};
