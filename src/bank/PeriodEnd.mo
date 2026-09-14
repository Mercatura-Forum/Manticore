/// PeriodEnd.mo; the close as a recorded state machine.
///
/// Period end is an ordered sequence whose steps must not run out of order or twice,
/// and "the operator remembered the order" is not a control. So the bank log carries
/// a run per (book, period) with an explicit state, each transition is a block, each
/// refuses unless its predecessor holds, and each is idempotent:
///
///     opened
///       -> ratesRecorded       every foreign currency has a closing rate for the date
///       -> accrualComplete     the end-of-day run for the final business date is done
///       -> revalued            FX revaluation posted, or no foreign position exists
///       -> deferralsAmortised  every active deferral schedule posted for the period
///       -> reconciled          the trial balance balances and every control account
///                              equals the sum of its sub-ledgers
///       -> closed              the journal period closed, the book closed
///
/// The year-end roll is admitted only from `closed` on the final period of the fiscal
/// year, which is the ordering IAS 1 requires: income and expense close to retained
/// earnings *after* the period's accruals and revaluations are in, never before.
///
/// `reconciled` is the step a conventional core cannot offer. The control-account
/// check is an equality between a general-ledger balance and the sum of its
/// sub-ledger balances, and both are folds over the same Merkle-committed log. There
/// is no second database to agree with, so it is a self-consistency proof rather than
/// a reconciliation; and when it fails it fails *before* the period closes, not in a
/// break report afterwards.

import Nat "mo:core/Nat";
import Text "mo:core/Text";
import List "mo:core/List";

import JT "mo:journal/JournalTypes";

module {

  public type Day = JT.Day;

  public type State = {
    #opened;
    #ratesRecorded;
    #accrualComplete;
    #revalued;
    #deferralsAmortised;
    #reconciled;
    #closed;
  };

  public func stateText(s : State) : Text {
    switch (s) {
      case (#opened) "opened"; case (#ratesRecorded) "ratesRecorded";
      case (#accrualComplete) "accrualComplete"; case (#revalued) "revalued";
      case (#deferralsAmortised) "deferralsAmortised"; case (#reconciled) "reconciled";
      case (#closed) "closed";
    }
  };

  public func states() : [State] {
    [#opened, #ratesRecorded, #accrualComplete, #revalued, #deferralsAmortised, #reconciled, #closed]
  };

  public func rank(s : State) : Nat {
    switch (s) {
      case (#opened) 0; case (#ratesRecorded) 1; case (#accrualComplete) 2;
      case (#revalued) 3; case (#deferralsAmortised) 4; case (#reconciled) 5; case (#closed) 6;
    }
  };

  /// The state that must hold before `to` can be entered. There is exactly one, which
  /// is what makes the sequence an order rather than a set of flags.
  public func predecessorOf(to : State) : ?State {
    switch (to) {
      case (#opened) null;
      case (#ratesRecorded) ?#opened;
      case (#accrualComplete) ?#ratesRecorded;
      case (#revalued) ?#accrualComplete;
      case (#deferralsAmortised) ?#revalued;
      case (#reconciled) ?#deferralsAmortised;
      case (#closed) ?#reconciled;
    }
  };

  public type Transition = { #allowed; #idempotent; #outOfOrder : { from : State; to : State; requires : State } };

  /// May the run move from `from` to `to`? Re-running a transition already made is
  /// `#idempotent`; the caller records nothing and posts nothing; and anything else
  /// out of order is refused with the state it requires named.
  public func transition(from : State, to : State) : Transition {
    if (rank(to) <= rank(from)) return #idempotent;
    switch (predecessorOf(to)) {
      case null #outOfOrder({ from; to; requires = #opened });
      case (?needs) {
        if (rank(from) == rank(needs)) #allowed
        else #outOfOrder({ from; to; requires = needs })
      };
    }
  };

  public type Fault = {
    #outOfOrder : { from : Text; to : Text; requires : Text };
    #unknownRun : { book : Text; period : Text };
    #runExists : { book : Text; period : Text };
    #periodNotOpen : { period : Text };
    #calendarPolicy : { reason : Text };
    #missingRate : { currency : JT.Currency; asOf : Day };
    #accrualIncomplete : { day : Day; reason : Text };
    #businessDayNotRolled : { lastBusinessDay : Day; businessDate : Day };
    #deferralOutstanding : { schedule : Text };
    #controlAccountDivergence : { account : JT.AccountCode; currency : JT.Currency; ledger : Nat; subledgers : Nat };
    #trialBalanceUnbalanced : { currency : JT.Currency; debits : Nat; credits : Nat };
    #notClosed : { state : Text };
    #notFinalPeriod : { period : Text };
  };

  /// A control account and the sum of its sub-ledgers, in one currency. The close
  /// compares these and refuses if any pair disagrees.
  public type ControlCheck = {
    account : JT.AccountCode;
    currency : JT.Currency;
    ledgerDebits : Nat;
    ledgerCredits : Nat;
    subledgerDebits : Nat;
    subledgerCredits : Nat;
  };

  public func controlAgrees(c : ControlCheck) : Bool {
    c.ledgerDebits == c.subledgerDebits and c.ledgerCredits == c.subledgerCredits
  };

  /// The first control account that disagrees, if any. Returned rather than asserted
  /// so the refusal can name it.
  public func firstDivergence(checks : [ControlCheck]) : ?ControlCheck {
    for (c in checks.vals()) { if (not controlAgrees(c)) return ?c };
    null
  };

  /// Every currency in a trial balance whose debits do not equal its credits. The
  /// journal's own invariant makes this empty by construction at admission; checking
  /// it again at the close is cheap and is the difference between believing the
  /// invariant and having measured it.
  public func unbalancedCurrencies(totals : [{ currency : JT.Currency; periodDebits : Nat; periodCredits : Nat; closingDebits : Nat; closingCredits : Nat }]) : [JT.Currency] {
    let out = List.empty<JT.Currency>();
    for (t in totals.vals()) {
      if (t.closingDebits != t.closingCredits) List.add(out, t.currency);
    };
    List.toArray(out)
  };

  /// A run, as the state machine sees it.
  public type Run = {
    book : Text;
    period : JT.PeriodId;
    /// The date the close is struck at: the last business day of the period.
    closingDate : Day;
    state : State;
    openedAtBlock : Nat;
    /// What each completed step recorded, so a reader can see the close happened in
    /// the declared order with the figures it claimed.
    ratesAtBlock : ?Nat;
    accrualAtBlock : ?Nat;
    revaluedAtBlock : ?Nat;
    deferralsAtBlock : ?Nat;
    reconciledAtBlock : ?Nat;
    closedAtBlock : ?Nat;
    /// Counts the steps recorded, so "nothing was revalued" and "revaluation was
    /// skipped" are different facts.
    currenciesRevalued : Nat;
    unrealisedPosted : Nat;
    deferralsPosted : Nat;
    controlsChecked : Nat;
  };

  public func isFinalState(r : Run) : Bool { r.state == #closed };

  /// A back-value window, declared per book as recorded data. Inside the window a
  /// back-dated posting is admitted; beyond it, only through the four-eyes path; a
  /// closed period is impossible in any case because the journal refuses it.
  public type BackValueWindow = {
    book : Text;
    /// Business days a posting may be back-valued freely.
    freeDays : Nat;
    /// Business days a posting may be back-valued with an approval. Zero means a
    /// posting beyond the free window cannot be back-valued at all.
    approvedDays : Nat;
  };

  public type BackValueVerdict = {
    #inWindow : { businessDaysBack : Nat };
    #needsApproval : { businessDaysBack : Nat; freeDays : Nat };
    #beyondWindow : { businessDaysBack : Nat; approvedDays : Nat };
  };

  public func classifyBackValue(w : BackValueWindow, businessDaysBack : Nat) : BackValueVerdict {
    if (businessDaysBack <= w.freeDays) #inWindow({ businessDaysBack })
    else if (businessDaysBack <= w.freeDays + w.approvedDays) #needsApproval({ businessDaysBack; freeDays = w.freeDays })
    else #beyondWindow({ businessDaysBack; approvedDays = w.approvedDays });
  };

  public let DEFAULT_FREE_DAYS : Nat = 5;
  public let DEFAULT_APPROVED_DAYS : Nat = 25;
  public let MAX_WINDOW_DAYS : Nat = 365;

  public func validateWindow(w : BackValueWindow) : ?Text {
    if (w.freeDays > MAX_WINDOW_DAYS) return ?"the free window exceeds the bound";
    if (w.approvedDays > MAX_WINDOW_DAYS) return ?"the approved window exceeds the bound";
    null
  };
};
