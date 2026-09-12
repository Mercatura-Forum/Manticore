/// YearEnd.mo — the year-end retained-earnings roll as ordinary postings.
///
/// At the end of a fiscal year every income and expense account is closed into
/// retained earnings. This module builds those postings from the journal's own
/// fold — one balanced posting per currency, booked in the year's closing
/// period with source kind "year-end" — and nothing else: they are admitted by
/// `JournalCore.prepareBatch` like any other postings, so they are proven,
/// reversible and visible in the trial balance, and a repeated roll with the
/// same key prefix is idempotent (exact duplicates). Closing the periods stays
/// an explicit administrative act after the roll.
///
/// Rule: for each (income or expense account, currency) with cumulative net
/// balance N ≠ 0 at the end of the closing period, add a leg on the side that
/// brings it to zero; the sum of those legs per currency is the year's result,
/// which goes to retained earnings on the opposite side (a profit credits
/// retained earnings). IAS 1 / IFRS Conceptual Framework: profit or loss for
/// the period is transferred to equity at the reporting date.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Map "mo:core/Map";
import Text "mo:core/Text";

import T "JournalTypes";
import Core "JournalCore";
import Calendar "Calendar";

module {

  public type RollArgs = {
    closingPeriod : T.PeriodId;          // last period of the fiscal year; the roll is booked into it
    retainedEarnings : T.AccountCode;    // equity account receiving the result
    keyPrefix : Blob;                    // idempotency key prefix (≤ 56 bytes); currency code appended
    narration : Text;
  };

  public type RollPlan = {
    postings : [T.PostingInput];         // one per currency with a non-zero result
    accountsClosed : Nat;                // (account, currency) pairs with a non-zero balance
    results : [{ currency : T.Currency; profitCredits : Nat; lossDebits : Nat }];
  };

  public type RollError = {
    #UnknownPeriod : T.PeriodId;
    #PeriodClosed : T.PeriodId;
    #UnknownRetainedEarnings : T.AccountCode;
    #RetainedEarningsNotEquity : T.AccountCode;
    #KeyPrefixTooLong : Nat;
    #NothingToRoll;
  };

  /// The day the roll is booked on: the last day of the closing period, moved back to
  /// the last business day on or before it when a working-day calendar is configured.
  ///
  /// The period's own end date is the accounting answer, but it is not always a
  /// business day — 31 January 2026 is a Saturday — and a deployment whose calendar
  /// policy is `#reject` would have the roll refused with
  /// `#ValueDateNotBusinessDay`. Moving it back here rather than leaving the caller
  /// to is the right place: the roll is the journal's own arithmetic, and the journal
  /// is where the calendar lives.
  public func rollDay(state : Core.State, period : T.Period) : T.Day {
    switch (Core.calendar(state)) {
      case null period.end;
      case (?cfg) {
        let cal : Calendar.Calendar = { restDays = cfg.restDays; holidays = cfg.holidays };
        if (Calendar.isBusinessDay(cal, period.end)) period.end
        else {
          switch (Calendar.previousBusinessDay(cal, period.end)) {
            case (?d) { if (d >= period.start) d else period.end };
            case null period.end;
          }
        }
      };
    }
  };

  /// Build the roll from the trial balance of the closing period (closing
  /// columns are cumulative, so prior years already rolled contribute zero).
  public func plan(state : Core.State, a : RollArgs) : { #ok : RollPlan; #err : RollError } {
    let ?period = Core.getPeriod(state, a.closingPeriod) else return #err(#UnknownPeriod(a.closingPeriod));
    if (period.status == #closed) return #err(#PeriodClosed(a.closingPeriod));
    let ?re = Core.getAccount(state, a.retainedEarnings) else return #err(#UnknownRetainedEarnings(a.retainedEarnings));
    if (re.category != #equity) return #err(#RetainedEarningsNotEquity(a.retainedEarnings));
    if (a.keyPrefix.size() > 56) return #err(#KeyPrefixTooLong(a.keyPrefix.size()));
    let ?tb = Core.trialBalance(state, a.closingPeriod) else return #err(#UnknownPeriod(a.closingPeriod));
    // legs per currency
    type Acc = { legs : List.List<T.Leg>; var profit : Nat; var loss : Nat };
    let byCcy = Map.empty<Text, Acc>();
    var closed = 0;
    for (row in tb.rows.vals()) {
      switch (Core.getAccount(state, row.account)) {
        case (?acct) {
          if (acct.category == #income or acct.category == #expense) {
            if (row.closingDebits != row.closingCredits) {
              let acc = switch (Map.get(byCcy, Text.compare, row.currency)) {
                case (?x) x;
                case null { let x : Acc = { legs = List.empty<T.Leg>(); var profit = 0; var loss = 0 }; Map.add(byCcy, Text.compare, row.currency, x); x };
              };
              if (row.closingCredits > row.closingDebits) {
                // credit balance (income): debit it to zero; the amount is profit
                let n : Nat = row.closingCredits - row.closingDebits;   // guarded above
                List.add(acc.legs, { account = row.account; subledger = null; side = #debit; currency = row.currency; amount = n });
                acc.profit += n;
              } else {
                let n : Nat = row.closingDebits - row.closingCredits;   // guarded above
                List.add(acc.legs, { account = row.account; subledger = null; side = #credit; currency = row.currency; amount = n });
                acc.loss += n;
              };
              closed += 1;
            };
          };
        };
        case null {};
      };
    };
    if (closed == 0) return #err(#NothingToRoll);
    let booked = rollDay(state, period);
    let postings = List.empty<T.PostingInput>();
    let results = List.empty<{ currency : T.Currency; profitCredits : Nat; lossDebits : Nat }>();
    for ((ccy, acc) in Map.entries(byCcy)) {
      let legs = List.toArray(acc.legs);
      // the net goes to retained earnings on the side that balances the posting
      let balancing : [T.Leg] =
        if (acc.profit > acc.loss) [{ account = a.retainedEarnings; subledger = null; side = #credit; currency = ccy; amount = (acc.profit - acc.loss : Nat) }]
        else if (acc.loss > acc.profit) [{ account = a.retainedEarnings; subledger = null; side = #debit; currency = ccy; amount = (acc.loss - acc.profit : Nat) }]
        else [];
      let key = Blob.fromArray(Array.concat(Blob.toArray(a.keyPrefix), Blob.toArray(Text.encodeUtf8(ccy))));
      List.add(postings, {
        idempotencyKey = key;
        postingDate = booked;
        valueDate = booked;
        period = a.closingPeriod;
        legs = Array.concat(legs, balancing);
        sourceRef = { kind = "year-end"; id = a.closingPeriod };
        narration = a.narration;
        correctionOf = null;
      });
      List.add(results, { currency = ccy; profitCredits = acc.profit; lossDebits = acc.loss });
    };
    #ok({ postings = List.toArray(postings); accountsClosed = closed; results = List.toArray(results) })
  };
};
