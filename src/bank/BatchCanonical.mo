/// BatchCanonical.mo — the canonical bytes of the batch vocabulary.

import List "mo:core/List";

import C "mo:journal/Canonical";

import T "BatchTypes";
import Batch "Batch";

module {

  public func wJob(w : C.Writer, j : Batch.Job) { w.nat(Batch.jobRank(j)) };

  public func rJob(r : C.Reader) : ?Batch.Job {
    switch (r.nat()) {
      case (?1) ?#accrual; case (?2) ?#charges; case (?3) ?#instalmentsDue;
      case (?4) ?#ageing; case (?5) ?#provisioning; case (?6) ?#maturity;
      case (?7) ?#standingInstructions; case (?8) ?#statementCut; case (?9) ?#tillCheck;
      case (?10) ?#monitoring; case (?11) ?#offerExpiry; case (?12) ?#facilities;
      case (_) null;
    }
  };

  public func wFailures(w : C.Writer, fs : [T.Failure]) {
    w.len16(fs.size());
    for (f in fs.vals()) { w.nat(f.item); wJob(w, f.job); w.text(f.entity); w.text(f.error); w.nat(f.attempts) };
  };

  public func rFailures(r : C.Reader) : ?[T.Failure] {
    let ?n = r.len16() else return null;
    let out = List.empty<T.Failure>();
    var i = 0;
    while (i < n) {
      let ?item = r.nat() else return null;
      let ?job = rJob(r) else return null;
      let ?entity = r.text() else return null;
      let ?error = r.text() else return null;
      let ?attempts = r.nat() else return null;
      List.add(out, { item; job; entity; error; attempts });
      i += 1;
    };
    ?List.toArray(out)
  };

  public func wInstruction(w : C.Writer, si : T.StandingInstruction) {
    w.text(si.id); w.text(si.book); w.nat(si.from); w.nat(si.to); w.nat(si.amount);
    w.text(si.currency); w.nat(si.everyDays); w.nat(si.startDay); w.optNat(si.endDay); w.text(si.narration);
  };

  public func rInstruction(r : C.Reader) : ?T.StandingInstruction {
    let ?id = r.text() else return null;
    let ?book = r.text() else return null;
    let ?from = r.nat() else return null;
    let ?to = r.nat() else return null;
    let ?amount = r.nat() else return null;
    let ?currency = r.text() else return null;
    let ?everyDays = r.nat() else return null;
    let ?startDay = r.nat() else return null;
    let ?endDay = r.optNat() else return null;
    let ?narration = r.text() else return null;
    ?{ id; book; from; to; amount; currency; everyDays; startDay; endDay; narration }
  };

  public func wCut(w : C.Writer, c : T.StatementCut) {
    w.nat(c.account); w.nat(c.day); w.text(c.currency);
    w.nat(c.openingDebits); w.nat(c.openingCredits);
    w.nat(c.closingDebits); w.nat(c.closingCredits); w.nat(c.movements);
  };

  public func rCut(r : C.Reader) : ?T.StatementCut {
    let ?account = r.nat() else return null;
    let ?day = r.nat() else return null;
    let ?currency = r.text() else return null;
    let ?openingDebits = r.nat() else return null;
    let ?openingCredits = r.nat() else return null;
    let ?closingDebits = r.nat() else return null;
    let ?closingCredits = r.nat() else return null;
    let ?movements = r.nat() else return null;
    ?{ account; day; currency; openingDebits; openingCredits; closingDebits; closingCredits; movements }
  };

  public func writeEvent(w : C.Writer, e : T.BatchEvent) {
    switch (e) {
      case (#retryPolicySet(x)) { w.byte(0x01); w.text(x.policy.book); w.nat(x.policy.limit) };
      case (#standingInstructionDefined(x)) { w.byte(0x02); wInstruction(w, x.instruction) };
      case (#standingInstructionCancelled(x)) { w.byte(0x03); w.text(x.id) };
      case (#eodOpened(x)) {
        w.byte(0x10); w.text(x.book); w.nat(x.businessDate); w.nat(x.shardSize);
        w.nat(x.openedAtHeight); w.nat(x.maxAccount); w.blob(x.planHash); w.nat(x.items); w.nat(x.entities);
      };
      case (#eodChunk(x)) {
        w.byte(0x11); w.text(x.book); w.nat(x.businessDate); w.nat(x.cursorFrom); w.nat(x.cursorTo);
        w.nat(x.posted); w.nat(x.examined); w.nat(x.zeroMovement); wFailures(w, x.failures);
      };
      case (#eodCompleted(x)) {
        w.byte(0x12); w.text(x.book); w.nat(x.businessDate);
        w.nat(x.posted); w.nat(x.examined); w.nat(x.zeroMovement); w.nat(x.failures);
      };
      case (#eodFailed(x)) { w.byte(0x13); w.text(x.book); w.nat(x.businessDate); w.text(x.reason) };
      case (#eodFailureResolved(x)) {
        w.byte(0x15); w.text(x.book); w.nat(x.businessDate); w.nat(x.item); w.text(x.entity); w.text(x.justification);
      };
      case (#eodRetry(x)) {
        w.byte(0x14); w.text(x.book); w.nat(x.businessDate);
        w.nat(x.resolved.size());
        for (rz in x.resolved.vals()) { w.nat(rz.item); w.text(rz.entity) };
        wFailures(w, x.failures); w.nat(x.posted);
      };
      case (#loanAged(x)) {
        w.byte(0x20); w.nat(x.account); w.nat(x.day);
        switch (x.band) { case null w.byte(0); case (?b) { w.byte(1); w.text(b) } };
        w.nat(x.overdueDays); w.nat(x.overdueTotal); w.nat(x.instalmentsOverdue);
      };
      case (#statementCutRecorded(x)) { w.byte(0x21); wCut(w, x.cut) };
      case (#standingInstructionExecuted(x)) { w.byte(0x22); w.text(x.id); w.nat(x.day); w.nat(x.amount) };
      case (#depositMatured(x)) { w.byte(0x23); w.nat(x.account); w.nat(x.day); w.nat(x.entitled) };
      case (#instalmentDue(x)) { w.byte(0x24); w.nat(x.account); w.nat(x.day); w.nat(x.instalment); w.nat(x.interest); w.nat(x.principal) };
    };
  };

  public func readEvent(r : C.Reader) : ?T.BatchEvent {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 0x01 {
        let ?book = r.text() else return null;
        let ?limit = r.nat() else return null;
        ?#retryPolicySet({ policy = { book; limit } })
      };
      case 0x02 { let ?si = rInstruction(r) else return null; ?#standingInstructionDefined({ instruction = si }) };
      case 0x03 { let ?id = r.text() else return null; ?#standingInstructionCancelled({ id }) };
      case 0x10 {
        let ?book = r.text() else return null;
        let ?businessDate = r.nat() else return null;
        let ?shardSize = r.nat() else return null;
        let ?openedAtHeight = r.nat() else return null;
        let ?maxAccount = r.nat() else return null;
        let ?planHash = r.blob() else return null;
        let ?items = r.nat() else return null;
        let ?entities = r.nat() else return null;
        ?#eodOpened({ book; businessDate; shardSize; openedAtHeight; maxAccount; planHash; items; entities })
      };
      case 0x11 {
        let ?book = r.text() else return null;
        let ?businessDate = r.nat() else return null;
        let ?cursorFrom = r.nat() else return null;
        let ?cursorTo = r.nat() else return null;
        let ?posted = r.nat() else return null;
        let ?examined = r.nat() else return null;
        let ?zeroMovement = r.nat() else return null;
        let ?failures = rFailures(r) else return null;
        ?#eodChunk({ book; businessDate; cursorFrom; cursorTo; posted; examined; zeroMovement; failures })
      };
      case 0x12 {
        let ?book = r.text() else return null;
        let ?businessDate = r.nat() else return null;
        let ?posted = r.nat() else return null;
        let ?examined = r.nat() else return null;
        let ?zeroMovement = r.nat() else return null;
        let ?failures = r.nat() else return null;
        ?#eodCompleted({ book; businessDate; posted; examined; zeroMovement; failures })
      };
      case 0x13 {
        let ?book = r.text() else return null;
        let ?businessDate = r.nat() else return null;
        let ?reason = r.text() else return null;
        ?#eodFailed({ book; businessDate; reason })
      };
      case 0x14 {
        let ?book = r.text() else return null;
        let ?businessDate = r.nat() else return null;
        let ?n = r.nat() else return null;
        let resolved = List.empty<{ item : Nat; entity : Text }>();
        var i = 0;
        while (i < n) {
          let ?item = r.nat() else return null;
          let ?entity = r.text() else return null;
          List.add(resolved, { item; entity });
          i += 1;
        };
        let ?failures = rFailures(r) else return null;
        let ?posted = r.nat() else return null;
        ?#eodRetry({ book; businessDate; resolved = List.toArray(resolved); failures; posted })
      };
      case 0x15 {
        let ?book = r.text() else return null;
        let ?businessDate = r.nat() else return null;
        let ?item = r.nat() else return null;
        let ?entity = r.text() else return null;
        let ?justification = r.text() else return null;
        ?#eodFailureResolved({ book; businessDate; item; entity; justification })
      };
      case 0x20 {
        let ?account = r.nat() else return null;
        let ?day = r.nat() else return null;
        let band = switch (r.byte()) {
          case (?0) null;
          case (?1) { let ?b = r.text() else return null; ?b };
          case (_) return null;
        };
        let ?overdueDays = r.nat() else return null;
        let ?overdueTotal = r.nat() else return null;
        let ?instalmentsOverdue = r.nat() else return null;
        ?#loanAged({ account; day; band; overdueDays; overdueTotal; instalmentsOverdue })
      };
      case 0x21 { let ?c = rCut(r) else return null; ?#statementCutRecorded({ cut = c }) };
      case 0x22 {
        let ?id = r.text() else return null;
        let ?day = r.nat() else return null;
        let ?amount = r.nat() else return null;
        ?#standingInstructionExecuted({ id; day; amount })
      };
      case 0x23 {
        let ?account = r.nat() else return null;
        let ?day = r.nat() else return null;
        let ?entitled = r.nat() else return null;
        ?#depositMatured({ account; day; entitled })
      };
      case 0x24 {
        let ?account = r.nat() else return null;
        let ?day = r.nat() else return null;
        let ?instalment = r.nat() else return null;
        let ?interest = r.nat() else return null;
        let ?principal = r.nat() else return null;
        ?#instalmentDue({ account; day; instalment; interest; principal })
      };
      case _ null;
    }
  };
};
