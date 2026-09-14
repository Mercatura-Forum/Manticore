/// BatchTypes.mo; the end-of-day batch's vocabulary.
///
/// Every transition of a run is a block, so a claim about last night's accrual is
/// answered with an inclusion proof rather than a log file. The chunk event carries the
/// cursor before and after, what was posted, what was examined and what failed, which
/// is what makes a run replayable rather than merely recorded.

import JT "mo:journal/JournalTypes";

import Batch "Batch";

module {

  public type Day = JT.Day;
  public type BookId = Text;
  public type Job = Batch.Job;
  public type PlanItem = Batch.PlanItem;
  public type Failure = Batch.Failure;
  public type RunState = Batch.RunState;
  public type RetryPolicy = Batch.RetryPolicy;

  /// A standing instruction: a recurring transfer between two accounts. The definition
  /// lives here because the batch is what executes it, and an instruction that fails
  /// for insufficient funds is a recorded failure with the declared retry policy rather
  /// than a silent skip.
  public type StandingInstruction = {
    id : Text;
    book : BookId;
    from : Nat;                  // the paying product account
    to : Nat;                    // the receiving product account
    amount : Nat;
    currency : JT.Currency;
    /// Every how many days the instruction falls due, counted from `startDay`. Days
    /// rather than a calendar period, because the batch runs on a date and a recurrence
    /// a reader cannot compute from the record is a recurrence nobody can audit.
    everyDays : Nat;
    startDay : Day;
    endDay : ?Day;
    narration : Text;
  };

  public func dueOn(si : StandingInstruction, day : Day) : Bool {
    if (day < si.startDay) return false;
    switch (si.endDay) { case (?e) { if (day > e) return false }; case null {} };
    if (si.everyDays == 0) return false;
    (day - si.startDay) % si.everyDays == 0
  };

  /// The statement data cut for one account on one date: the balances as they stood,
  /// recorded rather than re-derived, so a statement stays reproducible after later
  /// back-valued activity is admitted.
  public type StatementCut = {
    account : Nat;
    day : Day;
    currency : JT.Currency;
    openingDebits : Nat;
    openingCredits : Nat;
    closingDebits : Nat;
    closingCredits : Nat;
    movements : Nat;
  };

  /// Everything the batch records.
  public type BatchEvent = {
    #retryPolicySet : { policy : RetryPolicy };
    #standingInstructionDefined : { instruction : StandingInstruction };
    #standingInstructionCancelled : { id : Text };
    /// The plan is fixed here: the hash and the item count are in the block, so the
    /// work is declared before any of it is done.
    #eodOpened : {
      book : BookId; businessDate : Day; shardSize : Nat;
      openedAtHeight : Nat; maxAccount : Nat;
      planHash : Blob; items : Nat; entities : Nat;
    };
    #eodChunk : {
      book : BookId; businessDate : Day;
      cursorFrom : Nat; cursorTo : Nat;
      posted : Nat; examined : Nat; zeroMovement : Nat;
      failures : [Failure];
    };
    /// A chunk that ended inside one item: the item is a walk of its own (the treasury job's deals and
    /// breaks) and stopped at this cursor, so the next advance resumes the walk there instead of the
    /// item's start. Recorded after the chunk's own block; absent when the chunk closed its items whole.
    #eodItemCursor : { book : BookId; businessDate : Day; item : Nat; cursor : Blob };
    #eodCompleted : {
      book : BookId; businessDate : Day;
      posted : Nat; examined : Nat; zeroMovement : Nat; failures : Nat;
    };
    #eodFailed : { book : BookId; businessDate : Day; reason : Text };
    /// What a retry pass did. A run carries its unresolved failures, and every advance
    /// re-attempts the ones whose attempt count is still below the book's declared
    /// retry limit; and only the entity that failed, never the whole shard again.
    ///
    /// `resolved` names the failures the re-attempt cleared, `failures` carries the ones
    /// that failed again with their attempt count raised by one. A failure whose
    /// `attempts` has reached the limit is parked: never re-attempted, and still
    /// blocking the period close until someone resolves it. The pass reports only what
    /// it posted: `examined` belongs to the plan's coverage and is not inflated by
    /// repair work.
    /// One exception signed off by a person, with the reason they gave.
    #eodFailureResolved : { book : BookId; businessDate : Day; item : Nat; entity : Text; justification : Text };
    #eodRetry : {
      book : BookId; businessDate : Day;
      resolved : [{ item : Nat; entity : Text }];
      failures : [Failure];
      posted : Nat;
    };
    /// What job 4 recorded for one loan.
    #loanAged : { account : Nat; day : Day; band : ?Text; overdueDays : Nat; overdueTotal : Nat; instalmentsOverdue : Nat };
    /// What job 8 recorded for one account.
    #statementCutRecorded : { cut : StatementCut };
    /// What job 7 did, per instruction.
    #standingInstructionExecuted : { id : Text; day : Day; amount : Nat };
    /// What job 6 did: a term deposit reaching maturity on the date, with the interest
    /// it is entitled to moved into the depositor's own sub-ledger.
    #depositMatured : { account : Nat; day : Day; entitled : Nat };
    /// What job 3 did: the instalment falling due on the date moved into the
    /// borrower's receivable, so a repayment has something to be allocated against.
    #instalmentDue : { account : Nat; day : Day; instalment : Nat; interest : Nat; principal : Nat };
  };

  public type BatchError = {
    #InvalidShardSize : { shardSize : Nat };
    #PlanTooLarge : { items : Nat };
    #RunExists : { book : BookId; businessDate : Day };
    #UnknownRun : { book : BookId; businessDate : Day };
    #RunComplete : { book : BookId; businessDate : Day };
    #RunOpenForDate : { book : BookId; businessDate : Day; valueDate : Day };
    #BusinessDateMismatch : { businessDate : Day; requested : Day };
    #NothingToAdvance : { book : BookId; businessDate : Day; cursor : Nat };
    #PlanHashMismatch : { recorded : Blob; recomputed : Blob };
    #DuplicateNamesWrongBlock : { key : Blob; index : Nat; reason : Text };
    #TooManyFailures : { failures : Nat };
    #UnresolvedFailures : { book : BookId; businessDate : Day; failures : Nat };
    #UnknownFailure : { book : BookId; businessDate : Day; item : Nat; entity : Text };
    #NoStatementCut : { account : Nat };
    #InvalidJustification : { reason : Text };
    #InstructionExists : { id : Text };
    #UnknownInstruction : { id : Text };
    #InvalidInstruction : { reason : Text };
    #InvalidRetryPolicy : { reason : Text };
    #AdvanceLimit : { limit : Nat; max : Nat };
  };

  // ─── views ────────────────────────────────────────────────────────────────

  public type RunView = {
    book : BookId;
    businessDate : Day;
    shardSize : Nat;
    openedAtBlock : Nat;
    openedAtHeight : Nat;
    maxAccount : Nat;
    planHash : Blob;
    items : Nat;
    entities : Nat;
    cursor : Nat;
    /// Where the item at `cursor` stopped, when a chunk ended inside it.
    itemCursor : ?Blob;
    posted : Nat;
    examined : Nat;
    zeroMovement : Nat;
    failures : [Failure];
    state : Text;
    chunks : Nat;
  };

  public type InstructionView = { instruction : StandingInstruction; cancelled : Bool; executions : Nat; definedAtBlock : Nat };
};
