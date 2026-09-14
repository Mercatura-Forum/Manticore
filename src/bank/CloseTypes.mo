/// CloseTypes.mo; the vocabulary of value dating, foreign currency and the close.
///
/// Everything value dating and the close records, in one place, so the bank's own event list can name it
/// without importing the state module. The shapes follow the same rules as the rest
/// of the estate: a tag per variant, additive, never renumbered; every figure in
/// minor units; every rate and every policy declared data rather than a constant in
/// the binary.

import Principal "mo:core/Principal";

import JT "mo:journal/JournalTypes";

import Conventions "Conventions";
import Fx "Fx";
import Deferrals "Deferrals";
import PeriodEnd "PeriodEnd";

module {

  public type Day = JT.Day;
  public type BookId = Text;

  public type Convention = Conventions.Convention;
  public type Rate = Fx.Rate;
  public type PositionPair = Fx.PositionPair;
  public type Schedule = Deferrals.Schedule;
  public type BackValueWindow = PeriodEnd.BackValueWindow;
  public type RunState = PeriodEnd.State;
  public type Direction = { #gain; #loss; #unchanged };
  public type AdjustmentDirection = { #increase; #decrease; #unchanged };

  /// One side of a cross-currency movement: a customer's product account, or a named
  /// general-ledger account. Named rather than defaulted, so no leg of a deal lands
  /// in a bucket nobody chose.
  public type Endpoint = { #account : Nat; #glAccount : JT.AccountCode };

  /// A currency redenominated (S4.1): every balance in `from` re-expressed in `to` at the ratio; `newMinor =
  /// oldMinor × ratioNumerator / ratioDenominator`, rounded half-even per balance row; through the bridge account
  /// (which keeps, in `from`, the record of what was converted and, in `to`, its counterpart), the sum of the
  /// per-row rounding differences posted to the rounding account so the bridge's two sides are each other at the
  /// ratio exactly. Declared by a dual act; carried out by the end-of-day job of the day; `from` is closed to new
  /// postings when the job completes.
  public type Redenomination = {
    from : JT.Currency; to : JT.Currency; minorUnits : Nat8;
    ratioNumerator : Nat; ratioDenominator : Nat;
    bridgeAccount : JT.AccountCode; roundingAccount : JT.AccountCode;
    day : Day;
  };

  /// Everything the close layer records. Each of these is a block in the bank log.
  public type CloseEvent = {
    /// The functional currency, declared once. Every revaluation posts in it and
    /// nothing else, so naming it is a precondition of opening a close.
    #functionalCurrencySet : { currency : JT.Currency };
    #fxPairSet : { pair : PositionPair };
    #fxRateSet : { rate : Rate };
    #backValueWindowSet : { window : BackValueWindow };
    /// A named day the book may be back-valued into beyond its free window. Without
    /// one, a posting in the approval band is refused; beyond the approval band
    /// nothing admits it.
    #backValueApproved : { book : BookId; valueDate : Day; approver : Principal; reason : Text };
    /// A currency's own working-day calendar (S4.1): a value date in that currency is a business day in the bank's
    /// calendar and in the currency's; null removes it.
    #currencyCalendarSet : { currency : JT.Currency; calendar : ?JT.CalendarConfig };
    /// The declaration names the products re-versioned into the new currency by the same act.
    #redenominationDeclared : { redenomination : Redenomination; products : [Text] };
    /// One balance row re-expressed: the account (and sub-ledger) whose `from` balance was moved to `to`.
    #balanceRedenominated : { from : JT.Currency; to : JT.Currency; account : JT.AccountCode; subledger : ?Blob; productAccount : ?Nat; oldAmount : Nat; newAmount : Nat; creditBalance : Bool; day : Day };
    /// The job's last act: the rounding difference posted, the pair re-keyed, `from` closed.
    #redenominationCompleted : { from : JT.Currency; to : JT.Currency; rows : Nat; oldTotal : Nat; newTotal : Nat; roundingAmount : Nat; roundingDebit : Bool; day : Day };
    /// A cross-currency deal, booked as four legs through the position pair.
    #fxDealBooked : {
      sell : JT.Currency; sellAmount : Nat; buy : JT.Currency; buyAmount : Nat;
      rateNumerator : Nat; rateDenominator : Nat; asOf : Day; day : Day;
    };
    #fxRevalued : {
      currency : JT.Currency; position : Nat; equivalent : Nat; revalued : Nat;
      movement : Nat; direction : Direction; rateNumerator : Nat; rateDenominator : Nat;
      rateAsOf : Day; day : Day;
    };
    #fxRealised : {
      currency : JT.Currency; closedPosition : Nat; bookedEquivalent : Nat;
      proceeds : Nat; movement : Nat; direction : Direction; day : Day;
    };
    /// The accrual correction a back-dated posting makes necessary. Both figures are
    /// recorded, not only their difference.
    #accrualAdjusted : {
      product : Text; currency : JT.Currency; from : Day; to : Day;
      recomputed : Nat; booked : Nat; movement : Nat; direction : AdjustmentDirection;
      causedBy : Nat; examined : Nat;
    };
    #deferralScheduleOpened : { schedule : Schedule };
    #deferralAmortised : { schedule : Text; period : JT.PeriodId; sequence : Nat; amount : Nat; remaining : Nat };
    // ── the close, step by step ──
    #periodEndOpened : { book : BookId; period : JT.PeriodId; closingDate : Day };
    #periodEndRatesRecorded : { book : BookId; period : JT.PeriodId; currencies : Nat };
    #periodEndAccrualComplete : { book : BookId; period : JT.PeriodId; lastBusinessDay : Day };
    #periodEndRevalued : { book : BookId; period : JT.PeriodId; currencies : Nat; posted : Nat; total : Nat };
    /// The deferral step of the close, carrying what each schedule amortised. The
    /// rows are in the event because a plan commits one bank block and the fold has
    /// to advance every schedule's cursor from it; a step that posted but recorded
    /// no rows would amortise the same period again next time.
    #periodEndDeferralsAmortised : {
      book : BookId; period : JT.PeriodId; total : Nat;
      rows : [{ schedule : Text; sequence : Nat; amount : Nat; remaining : Nat }];
    };
    #periodEndReconciled : { book : BookId; period : JT.PeriodId; controls : Nat };
    #periodEndClosed : { book : BookId; period : JT.PeriodId };
    /// The fiscal year's result closed to retained earnings. Recorded with the
    /// figures per currency, so "what was the result and where did it go" is answered
    /// by replay rather than by recomputing a trial balance that has since moved.
    #yearEndRolled : {
      book : BookId; period : JT.PeriodId; retainedEarnings : JT.AccountCode;
      accountsClosed : Nat;
      results : [{ currency : JT.Currency; profitCredits : Nat; lossDebits : Nat }];
    };
    /// A book closed for a period: the bank layer refuses any posting touching a
    /// sub-ledger in that book for that period, and the refusal is recorded.
    #bookClosedForPeriod : { book : BookId; period : JT.PeriodId };
  };

  public type CloseError = {
    #NoFunctionalCurrency;
    #FunctionalCurrencyAlreadySet : { currency : JT.Currency };
    #InvalidRate : { reason : Text };
    #UnknownPair : { currency : JT.Currency };
    #PairExists : { currency : JT.Currency };
    #InvalidPair : { reason : Text };
    #InvalidWindow : { reason : Text };
    #InvalidSchedule : { reason : Text };
    #ScheduleExists : { schedule : Text };
    #UnknownSchedule : { schedule : Text };
    #ScheduleComplete : { schedule : Text; periods : Nat };
    #AlreadyAmortised : { schedule : Text; period : JT.PeriodId };
    #BackValueBeyondWindow : { businessDaysBack : Nat; freeDays : Nat; approvedDays : Nat };
    #BackValueNeedsApproval : { book : BookId; valueDate : Day; businessDaysBack : Nat; freeDays : Nat };
    #BackValueApprovalExists : { book : BookId; valueDate : Day };
    #BookClosedForPeriod : { book : BookId; period : JT.PeriodId };
    #CalendarPolicy : { reason : Text };
    #ValueDateNotResolved : { requested : Day; convention : Text; reason : Text };
    #RunExists : { book : BookId; period : JT.PeriodId };
    #UnknownRun : { book : BookId; period : JT.PeriodId };
    #OutOfOrder : { from : Text; to : Text; requires : Text };
    #MissingRate : { currency : JT.Currency; asOf : Day };
    #AccrualIncomplete : { reason : Text };
    #BusinessDayNotRolled : { lastBusinessDay : Day; businessDate : Day };
    #DeferralOutstanding : { schedule : Text };
    #ControlAccountDivergence : { account : JT.AccountCode; currency : JT.Currency; ledgerDebits : Nat; ledgerCredits : Nat; subledgerDebits : Nat; subledgerCredits : Nat };
    #TrialBalanceUnbalanced : { currency : JT.Currency };
    #NothingToRevalue : { currency : JT.Currency };
    #NotMonetary : { currency : JT.Currency };
    #NoTrialBalance : { period : JT.PeriodId };
    #YearEndError : { reason : Text };
    #YearEndAlreadyRolled : { book : BookId; period : JT.PeriodId };
    #NotReconciled : { book : BookId; period : JT.PeriodId; state : Text };
    /// A value date that is not a business day in one of the currencies' own calendars (S4.1).
    #ValueDateNotBusinessInCurrency : { currency : JT.Currency; day : Day };
    #RedenominationRefused : { reason : Text };
    /// The currency was redenominated: new postings go in its successor.
    #CurrencyClosed : { currency : JT.Currency; successor : JT.Currency };
  };

  // ─── views ────────────────────────────────────────────────────────────────

  public type RunView = {
    book : BookId;
    period : JT.PeriodId;
    closingDate : Day;
    state : Text;
    openedAtBlock : Nat;
    currenciesRevalued : Nat;
    unrealisedPosted : Nat;
    deferralsPosted : Nat;
    controlsChecked : Nat;
    closedAtBlock : ?Nat;
  };

  public type PositionView = {
    currency : JT.Currency;
    pair : PositionPair;
    position : Nat;
    positionSide : JT.Side;
    equivalent : Nat;
    /// The rate recorded for the day asked about, if any; a revaluation with none is
    /// a refusal rather than a substitution.
    rateNumerator : ?Nat;
    rateDenominator : ?Nat;
    rateAsOf : ?Day;
    revalued : ?Nat;
    movement : ?Nat;
    direction : Text;
  };

  public type ScheduleView = {
    schedule : Schedule;
    postedPeriods : Nat;
    amortised : Nat;
    remaining : Nat;
    openedAtBlock : Nat;
  };

  /// The control-account check as a reader sees it.
  public type ControlCheckView = {
    account : JT.AccountCode;
    currency : JT.Currency;
    ledgerDebits : Nat;
    ledgerCredits : Nat;
    subledgerDebits : Nat;
    subledgerCredits : Nat;
  };

  public type ResolvedDateView = {
    requested : Day;
    effective : Day;
    moved : Bool;
    convention : Text;
    /// Whether the deployment's journal policy leaves this layer as the only thing
    /// that moves a date.
    soleShiftingLayer : Bool;
  };
};
