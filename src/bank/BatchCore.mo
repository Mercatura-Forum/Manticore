/// BatchCore.mo — the batch's state, which is the fold of the log.
///
/// Runs and their cursors, standing instructions, the latest statement cut per account,
/// and the retry policy per book. The plan itself is not stored: it is a pure function
/// of the inputs the opening block records, so it is recomputed when a chunk runs and
/// checked against the recorded hash. Storing it would be a second copy of something
/// already in the log, and a second copy is a thing that can disagree.

import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Map "mo:core/Map";
import List "mo:core/List";
import Array "mo:core/Array";
import Order "mo:core/Order";
import Runtime "mo:core/Runtime";

import JT "mo:journal/JournalTypes";
import JC "mo:journal/Canonical";

import T "BatchTypes";
import Batch "Batch";

module {

  public type RunEntry = {
    book : Text;
    businessDate : JT.Day;
    shardSize : Nat;
    openedAtBlock : Nat;
    openedAtHeight : Nat;
    maxAccount : Nat;
    planHash : Blob;
    items : Nat;
    entities : Nat;
    var cursor : Nat;
    var posted : Nat;
    var examined : Nat;
    var zeroMovement : Nat;
    var chunks : Nat;
    failures : List.List<T.Failure>;
    var state : Batch.RunState;
  };

  public type InstructionEntry = {
    instruction : T.StandingInstruction;
    var cancelled : Bool;
    var executions : Nat;
    definedAtBlock : Nat;
  };

  public type State = {
    /// (book, business date) -> the run. Keyed on the date, which is what makes the
    /// date exclusion a map lookup rather than a scan.
    runs : Map.Map<(Text, Nat), RunEntry>;
    instructions : Map.Map<Text, InstructionEntry>;
    /// account -> the latest statement cut recorded for it.
    cuts : Map.Map<Nat, T.StatementCut>;
    retry : Map.Map<Text, Batch.RetryPolicy>;
  };

  func cmpTN(a : (Text, Nat), b : (Text, Nat)) : Order.Order {
    switch (Text.compare(a.0, b.0)) { case (#equal) Nat.compare(a.1, b.1); case (o) o }
  };

  public func newState() : State {
    {
      runs = Map.empty<(Text, Nat), RunEntry>();
      instructions = Map.empty<Text, InstructionEntry>();
      cuts = Map.empty<Nat, T.StatementCut>();
      retry = Map.empty<Text, Batch.RetryPolicy>();
    }
  };

  public type Event = T.BatchEvent;

  // ═══════════════════════════════════════════════════════
  //  LOOKUPS
  // ═══════════════════════════════════════════════════════

  public func getRun(s : State, book : Text, day : JT.Day) : ?RunEntry { Map.get(s.runs, cmpTN, (book, day)) };
  public func runCount(s : State) : Nat { Map.size(s.runs) };

  public func listRuns(s : State) : [RunEntry] {
    Array.map<((Text, Nat), RunEntry), RunEntry>(Map.toArray(s.runs), func((_, r)) { r })
  };

  /// Is a run open for a date at or after this value date? While one is, a posting
  /// value-dated on or before that date is refused: the book for the date is closed to
  /// new history for the duration of the run.
  public func openRunCovering(s : State, book : Text, valueDate : JT.Day) : ?RunEntry {
    for (((b, d), r) in Map.entries(s.runs)) {
      if (Text.equal(b, book) and valueDate <= d) {
        switch (r.state) {
          case (#completed) {};
          case (#failed(_)) {};
          case (_) return ?r;
        };
      };
    };
    null
  };

  public func isComplete(r : RunEntry) : Bool {
    switch (r.state) { case (#completed) true; case (_) false }
  };

  public func failureCount(r : RunEntry) : Nat { List.size(r.failures) };

  /// The failures a run still carries. A period cannot close while any run inside it
  /// has some, which is what makes a permanently failing item stop the close rather
  /// than the batch.
  public func unresolvedFailures(s : State, book : Text, from : JT.Day, to : JT.Day) : Nat {
    var n = 0;
    for (((b, d), r) in Map.entries(s.runs)) {
      if (Text.equal(b, book) and d >= from and d <= to) n += List.size(r.failures);
    };
    n
  };

  public func getInstruction(s : State, id : Text) : ?InstructionEntry { Map.get(s.instructions, Text.compare, id) };
  public func instructionCount(s : State) : Nat { Map.size(s.instructions) };

  /// Every live instruction of a book, in identifier order, which is the order the plan
  /// shards them in.
  public func instructionsOf(s : State, book : Text) : [InstructionEntry] {
    let out = List.empty<InstructionEntry>();
    for ((_, e) in Map.entries(s.instructions)) {
      if (Text.equal(e.instruction.book, book) and not e.cancelled) List.add(out, e);
    };
    List.toArray(out)
  };

  public func cutFor(s : State, account : Nat) : ?T.StatementCut { Map.get(s.cuts, Nat.compare, account) };
  public func cutCount(s : State) : Nat { Map.size(s.cuts) };

  /// The failures of a run, in the order they were recorded. The retry pass works from
  /// this list, and the period close counts it.
  public func failuresOf(r : RunEntry) : [T.Failure] { List.toArray(r.failures) };

  /// Is this run carrying the named failure? A sign-off for one it is not carrying is
  /// refused rather than recorded.
  public func hasFailure(r : RunEntry, item : Nat, entity : Text) : Bool {
    for (f in List.values(r.failures)) { if (f.item == item and Text.equal(f.entity, entity)) return true };
    false
  };

  /// The failures still worth re-attempting: those whose attempt count has not reached
  /// the book's declared limit. A failure at the limit is parked — it is never
  /// re-attempted and it still blocks the close.
  public func retryable(s : State, r : RunEntry) : [T.Failure] {
    let limit = retryLimit(s, r.book);
    let out = List.empty<T.Failure>();
    for (f in List.values(r.failures)) { if (f.attempts < limit) List.add(out, f) };
    List.toArray(out)
  };

  public func retryLimit(s : State, book : Text) : Nat {
    switch (Map.get(s.retry, Text.compare, book)) { case (?p) p.limit; case null Batch.DEFAULT_RETRY_LIMIT }
  };

  // ═══════════════════════════════════════════════════════
  //  VIEWS
  // ═══════════════════════════════════════════════════════

  public func runView(r : RunEntry) : T.RunView {
    {
      book = r.book; businessDate = r.businessDate; shardSize = r.shardSize;
      openedAtBlock = r.openedAtBlock; openedAtHeight = r.openedAtHeight;
      maxAccount = r.maxAccount; planHash = r.planHash; items = r.items; entities = r.entities;
      cursor = r.cursor; posted = r.posted; examined = r.examined; zeroMovement = r.zeroMovement;
      failures = List.toArray(r.failures); state = Batch.runStateText(r.state); chunks = r.chunks;
    }
  };

  public func listRunViews(s : State) : [T.RunView] {
    Array.map<RunEntry, T.RunView>(listRuns(s), runView)
  };

  public func instructionView(e : InstructionEntry) : T.InstructionView {
    { instruction = e.instruction; cancelled = e.cancelled; executions = e.executions; definedAtBlock = e.definedAtBlock }
  };

  public func listInstructionViews(s : State) : [T.InstructionView] {
    Array.map<(Text, InstructionEntry), T.InstructionView>(Map.toArray(s.instructions), func((_, e)) { instructionView(e) })
  };

  public func listCuts(s : State) : [T.StatementCut] {
    Array.map<(Nat, T.StatementCut), T.StatementCut>(Map.toArray(s.cuts), func((_, c)) { c })
  };

  // ═══════════════════════════════════════════════════════
  //  THE FOLD
  // ═══════════════════════════════════════════════════════

  func mustRun(s : State, book : Text, day : Nat) : RunEntry {
    switch (Map.get(s.runs, cmpTN, (book, day))) {
      case (?r) r;
      case null Runtime.trap("batch fold: unknown run " # book # "/" # Nat.toText(day));
    }
  };

  public func apply(s : State, blockIndex : Nat, e : Event) {
    switch (e) {
      case (#retryPolicySet(x)) { Map.add(s.retry, Text.compare, x.policy.book, x.policy) };
      case (#standingInstructionDefined(x)) {
        let entry : InstructionEntry = {
          instruction = x.instruction; var cancelled = false; var executions = 0;
          definedAtBlock = blockIndex;
        };
        Map.add(s.instructions, Text.compare, x.instruction.id, entry);
      };
      case (#standingInstructionCancelled(x)) {
        switch (Map.get(s.instructions, Text.compare, x.id)) {
          case (?e2) e2.cancelled := true;
          case null Runtime.trap("batch fold: cancel of unknown instruction " # x.id);
        };
      };
      case (#eodOpened(x)) {
        let entry : RunEntry = {
          book = x.book; businessDate = x.businessDate; shardSize = x.shardSize;
          openedAtBlock = blockIndex; openedAtHeight = x.openedAtHeight;
          maxAccount = x.maxAccount; planHash = x.planHash; items = x.items; entities = x.entities;
          var cursor = 0; var posted = 0; var examined = 0; var zeroMovement = 0; var chunks = 0;
          failures = List.empty<T.Failure>();
          var state = #open;
        };
        Map.add(s.runs, cmpTN, (x.book, x.businessDate), entry);
      };
      case (#eodChunk(x)) {
        let r = mustRun(s, x.book, x.businessDate);
        r.cursor := x.cursorTo;
        r.posted += x.posted;
        r.examined += x.examined;
        r.zeroMovement += x.zeroMovement;
        r.chunks += 1;
        r.state := #running;
        for (f in x.failures.vals()) { List.add(r.failures, f) };
      };
      case (#eodFailureResolved(x)) {
        let r = mustRun(s, x.book, x.businessDate);
        let kept = List.empty<T.Failure>();
        for (f in List.values(r.failures)) {
          if (not (f.item == x.item and Text.equal(f.entity, x.entity))) List.add(kept, f);
        };
        List.clear(r.failures);
        List.addAll(r.failures, List.values(kept));
      };
      case (#eodRetry(x)) {
        let r = mustRun(s, x.book, x.businessDate);
        r.posted += x.posted;
        // The failure list is rebuilt: every entry the pass resolved is dropped, every
        // entry it re-attempted is replaced by the one carrying the raised attempt
        // count, and everything it did not touch is kept as it was.
        let kept = List.empty<T.Failure>();
        for (f in List.values(r.failures)) {
          var drop = false;
          for (rz in x.resolved.vals()) {
            if (rz.item == f.item and Text.equal(rz.entity, f.entity)) drop := true;
          };
          for (g in x.failures.vals()) {
            if (g.item == f.item and Text.equal(g.entity, f.entity)) drop := true;
          };
          if (not drop) List.add(kept, f);
        };
        for (g in x.failures.vals()) { List.add(kept, g) };
        List.clear(r.failures);
        List.addAll(r.failures, List.values(kept));
      };
      case (#eodCompleted(x)) { mustRun(s, x.book, x.businessDate).state := #completed };
      case (#eodFailed(x)) { mustRun(s, x.book, x.businessDate).state := #failed(x.reason) };
      case (#loanAged(_)) {};               // the figures are recomputable; the block is the record
      case (#depositMatured(_)) {};
      case (#instalmentDue(_)) {};
      case (#statementCutRecorded(x)) { Map.add(s.cuts, Nat.compare, x.cut.account, x.cut) };
      case (#standingInstructionExecuted(x)) {
        switch (Map.get(s.instructions, Text.compare, x.id)) {
          case (?e2) e2.executions += 1;
          case null Runtime.trap("batch fold: execution of unknown instruction " # x.id);
        };
      };
    };
  };

  // ═══════════════════════════════════════════════════════
  //  FINGERPRINT
  // ═══════════════════════════════════════════════════════

  public func fingerprintInto(w : JC.Writer, s : State) {
    w.nat(Map.size(s.runs));
    for ((_, r) in Map.entries(s.runs)) {
      w.text(r.book); w.nat(r.businessDate); w.nat(r.shardSize);
      w.nat(r.openedAtBlock); w.nat(r.openedAtHeight); w.nat(r.maxAccount);
      w.blobRaw(r.planHash); w.nat(r.items); w.nat(r.entities);
      w.nat(r.cursor); w.nat(r.posted); w.nat(r.examined); w.nat(r.zeroMovement); w.nat(r.chunks);
      w.text(Batch.runStateText(r.state));
      w.len16(List.size(r.failures));
      for (f in List.values(r.failures)) {
        w.nat(f.item); w.nat(Batch.jobRank(f.job)); w.text(f.entity); w.text(f.error); w.nat(f.attempts);
      };
    };
    w.nat(Map.size(s.instructions));
    for ((_, e) in Map.entries(s.instructions)) {
      let si = e.instruction;
      w.text(si.id); w.text(si.book); w.nat(si.from); w.nat(si.to); w.nat(si.amount);
      w.text(si.currency); w.nat(si.everyDays); w.nat(si.startDay);
      switch (si.endDay) { case null w.byte(0); case (?d) { w.byte(1); w.nat(d) } };
      w.bool(e.cancelled); w.nat(e.executions); w.nat(e.definedAtBlock);
    };
    w.nat(Map.size(s.cuts));
    for ((_, c) in Map.entries(s.cuts)) {
      w.nat(c.account); w.nat(c.day); w.text(c.currency);
      w.nat(c.openingDebits); w.nat(c.openingCredits);
      w.nat(c.closingDebits); w.nat(c.closingCredits); w.nat(c.movements);
    };
    w.nat(Map.size(s.retry));
    for ((_, p) in Map.entries(s.retry)) { w.text(p.book); w.nat(p.limit) };
  };
};
