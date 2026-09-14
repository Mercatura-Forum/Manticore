/// ArchiveRoll.mo; a sealed pack's segments to an archive child, and the journal's prefix gone.
///
/// The roll is the second half of closed-month packing: the pack holds the range's blocks in a
/// third of their bytes, and the roll moves those bytes to an archive contract, writes the
/// journal's derived state at the boundary into the journal's own log as a **checkpoint**, drops
/// the journal's per-posting rows of the range, and lets the log's prefix go. After it the live
/// contract keeps, per archived block, the MMR's node (every proof is still generated here) and
/// nothing else; per account and month, the summary row and the list. A fold of the retained log
/// starts from the checkpoint and equals the live state (`JournalCore.replayFrom`).
///
/// The phases, each advanced in bounded steps by an open method, each step a bank block:
///
///   1. **folding**; a shadow journal state, restored from the previous checkpoint (or empty for
///      the first roll), applies the blocks up to the pack's boundary: the state as it stood then;
///   2. **checkpointing**; that state, in parts, appended to the live journal's log;
///   3. **sending**; each segment's bytes to the archive, recorded before the call; the archive
///      acknowledges by calling back (`ack`), and only its own word is recorded;
///   4. **dropping**; the journal's five per-posting indexes rebuilt without the range;
///   5. **truncating**; the log's prefix released, the MMR pruned below the boundary, the pack's
///      store given back, the pack archived.
///
/// Packs roll in order, because the prefix leaves as a prefix. A roll is refused while a pending
/// reserved in the range is still open: its record would leave before its resolution.

import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";
import RI "mo:ledger/RegionIndex";

import PT "PackingTypes";
import Packing "Packing";

module {

  public type Phase = { #folding; #checkpointing; #sending; #dropping : Nat; #truncating; #done };

  public type Job = {
    pack : Nat;
    cid : Nat64;
    archive : Principal;
    hi : Nat;
    periodEnd : Nat;
    segments : Nat;
    var phase : Phase;
    /// The shadow fold: the state as it stood after `hi`, built from the previous checkpoint.
    var shadow : ?JCore.State;
    var foldNext : Nat;
    var cursor : JCore.CheckpointCursor;
    var checkpointSeq : Nat;
    var checkpointFirst : ?Nat;
    var checkpointLast : ?Nat;
    var sendNext : Nat;
    sent : Map.Map<Nat, Nat>;      // seq -> attempts
    acked : Map.Map<Nat, ()>;
  };

  public type State = {
    /// One arena for every shadow fold, its pages released back after each roll.
    shadowArena : RI.Arena;
    var current : ?Job;
    var archivedThroughBlock : Nat;
    var archivedPacks : Nat;
    /// pack -> where its bytes went
    archives : Map.Map<Nat, { cid : Nat64; archive : Principal }>;
  };

  public func newState() : State {
    { shadowArena = RI.newArena(); var current = null; var archivedThroughBlock = 0; var archivedPacks = 0; archives = Map.empty<Nat, { cid : Nat64; archive : Principal }>() }
  };

  public type Error = PT.Error;

  /// What the roll reads and writes, as closures: the journal, its log and the bank's commit funnel
  /// stay the bank's.
  public type Context = {
    packing : Packing.State;
    journal : JCore.State;
    admin : Principal;
    journalHeight : () -> Nat;
    blockOf : Nat -> ?JT.Block;
    /// Append a journal event through the bank's funnel; returns the block index.
    appendJournal : JT.Event -> Nat;
    truncateLog : Nat -> ();
    /// Prune the MMR below the boundary block.
    pruneMmr : Nat -> ();
    /// The journal's idempotency rebuild, again at the roll: a pending reserved in the range and
    /// resolved after the pack kept its key then; it leaves now, as the fold from the checkpoint
    /// would never register it.
    idemBegin : Nat -> Bool;
    idemStep : Nat -> { examined : Nat; done : Bool };
    idemFinish : () -> Bool;
  };

  public func phaseText(p : Phase) : Text {
    switch (p) { case (#folding) "folding"; case (#checkpointing) "checkpointing"; case (#sending) "sending"; case (#dropping(k)) "dropping:" # (if (k < JCore.DROPPABLES.size()) JCore.droppableText(JCore.DROPPABLES[k]) else if (k == JCore.DROPPABLES.size()) "idempotency" else "?"); case (#truncating) "truncating"; case (#done) "done" }
  };

  /// Open a roll for a sealed pack. The caller has planned the decision (`rollAuthorised`).
  public func open(s : State, ctx : Context, pack : Nat, cid : Nat64, archive : Principal) : Result.Result<Job, Error> {
    switch (s.current) { case (?j) return #err(#RollInProgress({ pack = j.pack })); case null {} };
    let ?p = Packing.getPack(ctx.packing, pack) else return #err(#UnknownPack({ pack }));
    if (p.archived) return #err(#PackAlreadyArchived({ pack }));
    if (pack != s.archivedPacks + 1) return #err(#PackNotNext({ pack; next = s.archivedPacks + 1 }));
    switch (JCore.oldestOpenPending(ctx.journal)) { case (?i) { if (i <= p.hi) return #err(#OpenPendingInRange({ pending = i; hi = p.hi })) }; case null {} };
    let job : Job = {
      pack; cid; archive; hi = p.hi; periodEnd = p.periodEnd; segments = p.segments;
      var phase = #folding; var shadow = null; var foldNext = 0; var cursor = #config; var checkpointSeq = 0;
      var checkpointFirst = null; var checkpointLast = null; var sendNext = 0;
      sent = Map.empty<Nat, Nat>(); acked = Map.empty<Nat, ()>();
    };
    s.current := ?job;
    #ok(job)
  };

  public type Send = { seq : Nat; lo : Nat; hi : Nat; bytes : Blob; sha256 : Blob; postings : Nat; attempt : Nat };

  public type Advance = {
    pack : Nat;
    phase : Text;
    work : Nat;
    /// A segment to send to the archive, recorded by the caller before the call.
    send : ?Send;
    /// The checkpoint series, once written.
    checkpoint : ?{ through : Nat; first : Nat; last : Nat };
    done : Bool;
  };

  func shadowOf(s : State, ctx : Context, job : Job) : JCore.State {
    switch (job.shadow) {
      case (?sh) sh;
      case null {
        // from the previous checkpoint, or from nothing
        let sh = switch (JCore.checkpointPosition(ctx.journal)) {
          case (?cp) {
            let ?last = cp.last else Runtime.trap("ArchiveRoll: the previous checkpoint series is incomplete");
            // restore only: the blocks after its boundary are applied by the fold below
            JCore.replayFromIn(ctx.admin, s.shadowArena, { get = ctx.blockOf }, cp.first, last, cp.through + 1)
          };
          case null JCore.newStateIn(ctx.admin, s.shadowArena);
        };
        job.shadow := ?sh;
        job.foldNext := JCore.height(sh);
        sh
      };
    }
  };

  /// One bounded step.
  public func advance(s : State, ctx : Context, limit : Nat) : Result.Result<Advance, Error> {
    let ?job = s.current else return #err(#NotRolling);
    let n = Nat.max(1, Nat.min(limit, Packing.MAX_ADVANCE));
    switch (job.phase) {
      case (#folding) {
        let sh = shadowOf(s, ctx, job);
        var work = 0;
        let reader : JCore.Blocks = { get = ctx.blockOf };
        while (work < n and job.foldNext <= job.hi) {
          let ?b = ctx.blockOf(job.foldNext) else return #err(#BlockArchived({ index = job.foldNext; archivedThroughBlock = s.archivedThroughBlock }));
          JCore.apply(sh, reader, b);
          job.foldNext += 1;
          work += 1;
        };
        if (job.foldNext > job.hi) job.phase := #checkpointing;
        #ok({ pack = job.pack; phase = "folding"; work; send = null; checkpoint = null; done = false })
      };
      case (#checkpointing) {
        let sh = shadowOf(s, ctx, job);
        let r = JCore.checkpointPart(sh, job.cursor, job.periodEnd);
        let last = r.next == #done;
        let index = ctx.appendJournal(#checkpoint({ through = job.hi; seq = job.checkpointSeq; last; part = r.part }));
        if (job.checkpointSeq == 0) job.checkpointFirst := ?index;
        job.checkpointSeq += 1;
        job.cursor := r.next;
        if (last) {
          job.checkpointLast := ?index;
          JCore.releaseIndexes(sh);
          job.shadow := null;
          job.phase := #sending;
          let ?first = job.checkpointFirst else Runtime.trap("ArchiveRoll: a series without a first part");
          return #ok({ pack = job.pack; phase = "checkpointing"; work = 1; send = null; checkpoint = ?{ through = job.hi; first; last = index }; done = false });
        };
        #ok({ pack = job.pack; phase = "checkpointing"; work = 1; send = null; checkpoint = null; done = false })
      };
      case (#sending) {
        // the next segment never sent; else the first sent and not acknowledged, again
        var seq : ?Nat = null;
        if (job.sendNext < job.segments) { seq := ?job.sendNext; job.sendNext += 1 }
        else {
          var i = 0;
          label find while (i < job.segments) { if (not Map.containsKey(job.acked, Nat.compare, i)) { seq := ?i; break find }; i += 1 };
        };
        switch (seq) {
          case null { job.phase := #dropping(0); #ok({ pack = job.pack; phase = "sending"; work = 0; send = null; checkpoint = null; done = false }) };
          case (?q) {
            let ?sg = Packing.segment(ctx.packing, job.pack, q) else return #err(#UnknownSegment({ pack = job.pack; seq = q }));
            let ?bytes = Packing.segmentBytes(ctx.packing, job.pack, q) else return #err(#UnknownSegment({ pack = job.pack; seq = q }));
            let attempt = (switch (Map.get(job.sent, Nat.compare, q)) { case (?a) a; case null 0 }) + 1;
            Map.add(job.sent, Nat.compare, q, attempt);
            #ok({ pack = job.pack; phase = "sending"; work = 1; send = ?{ seq = q; lo = sg.lo; hi = sg.hi; bytes; sha256 = sg.sha256; postings = sg.postings; attempt }; checkpoint = null; done = false })
          };
        }
      };
      case (#dropping(k)) {
        let five = JCore.DROPPABLES.size();
        if (k > five) { job.phase := #truncating; return advance(s, ctx, limit) };
        let name = phaseText(#dropping(k));
        let began = if (k < five) { switch (JCore.archiveDropInProgress(ctx.journal)) { case (?_) true; case null JCore.beginArchiveDrop(ctx.journal, JCore.DROPPABLES[k], job.hi, job.periodEnd) } } else ctx.idemBegin(job.hi);
        if (not began) return #err(#RebuildBusy({ index = name }));
        let st = if (k < five) JCore.stepArchiveDrop(ctx.journal, n) else ctx.idemStep(n);
        if (st.done) {
          let finished = if (k < five) (JCore.finishArchiveDrop(ctx.journal) != null) else ctx.idemFinish();
          if (not finished) return #err(#RebuildBusy({ index = name }));
          job.phase := #dropping(k + 1);
        };
        #ok({ pack = job.pack; phase = name; work = st.examined; send = null; checkpoint = null; done = false })
      };
      case (#truncating) {
        ctx.truncateLog(job.hi);
        ctx.pruneMmr(job.hi);
        ignore Packing.markArchived(ctx.packing, job.pack);
        s.archivedThroughBlock := job.hi;
        s.archivedPacks := job.pack;
        Map.add(s.archives, Nat.compare, job.pack, { cid = job.cid; archive = job.archive });
        job.phase := #done;
        s.current := null;
        #ok({ pack = job.pack; phase = "truncating"; work = 1; send = null; checkpoint = null; done = true })
      };
      case (#done) #err(#NotRolling);
    }
  };

  /// The archive's acknowledgement of a segment: from the roll's archive principal, for a segment
  /// that was sent, with the segment's own hash. Returns whether every segment is now acknowledged.
  public func ack(s : State, ctx : Context, caller : Principal, pack : Nat, seq : Nat, sha256 : Blob) : Result.Result<{ complete : Bool }, Error> {
    let ?job = s.current else return #err(#NotRolling);
    if (job.pack != pack) return #err(#UnexpectedAck({ pack; seq; reason = "not the pack being rolled" }));
    if (caller != job.archive) return #err(#UnexpectedAck({ pack; seq; reason = "not the roll's archive: " # Principal.toText(caller) }));
    if (not Map.containsKey(job.sent, Nat.compare, seq)) return #err(#UnexpectedAck({ pack; seq; reason = "a segment that was not sent" }));
    let ?sg = Packing.segment(ctx.packing, pack, seq) else return #err(#UnknownSegment({ pack; seq }));
    if (sg.sha256 != sha256) return #err(#UnexpectedAck({ pack; seq; reason = "the hash is not the segment's" }));
    Map.add(job.acked, Nat.compare, seq, ());
    #ok({ complete = Map.size(job.acked) == job.segments })
  };

  public func current(s : State) : ?{ pack : Nat; cid : Nat64; archive : Principal; hi : Nat; phase : Text; foldNext : Nat; checkpointParts : Nat; sent : Nat; acked : Nat; segments : Nat } {
    switch (s.current) { case (?j) ?{ pack = j.pack; cid = j.cid; archive = j.archive; hi = j.hi; phase = phaseText(j.phase); foldNext = j.foldNext; checkpointParts = j.checkpointSeq; sent = Map.size(j.sent); acked = Map.size(j.acked); segments = j.segments }; case null null }
  };

  public func archiveOf(s : State, pack : Nat) : ?{ cid : Nat64; archive : Principal } { Map.get(s.archives, Nat.compare, pack) };

  public func stats(s : State) : { archivedThroughBlock : Nat; archivedPacks : Nat; shadow : { pages : Nat; free : Nat }; inProgress : Bool } {
    let a = RI.arenaStats(s.shadowArena);
    { archivedThroughBlock = s.archivedThroughBlock; archivedPacks = s.archivedPacks; shadow = { pages = a.pages; free = a.free }; inProgress = switch (s.current) { case (?_) true; case null false } }
  };
}
