/// CollectionsCore.mo; the exposures' stages, folded from the bank's log, in stable memory (collections and recovery).
///
/// One 100-byte row per lending exposure keyed by account; an index by stage (stage ‖ account → dpd) for the
/// worklist by stage, an index by collector (collector key ‖ account → stage) for a collector's worklist. Rows
/// are written by the fold only: the end-of-day batch derives a stage change and records it as a block, the
/// decided acts are blocks, and the product engine's restructuring, write-off and recovery move the stage as
/// their events are folded. `deriveStage` is the one rule, pure, so the Python oracle of `bank_s31.py` is the
/// same function written twice.

import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";

import CT "CollectionsTypes";
import R "StableRows";

module {

  /// `stage(1) ‖ dpd(4) ‖ sinceDay(4) ‖ sinceBlock(8) ‖ flags(1: utp=1, restructured=2, hasCollector=4, hasPromise=8)
  ///  ‖ collector(30: len ‖ bytes, zero-padded) ‖ promiseAmount(8) ‖ promiseBy(4) ‖ suspenseHeld(8) ‖ writtenOff(8)
  ///  ‖ recovered(8) ‖ actions(4) ‖ lastActionDay(4) ‖ promiseBaseline(8)`; 100 bytes.
  public type Row = {
    stage : CT.Stage; dpd : Nat; sinceDay : Nat; sinceBlock : Nat;
    unlikelyToPay : Bool; restructured : Bool; collector : ?Principal; promise : ?{ amount : Nat; by : Nat; baseline : Nat };
    suspenseHeld : Nat; writtenOff : Nat; recovered : Nat; actions : Nat; lastActionDay : ?Nat;
  };
  public let ROW_BYTES : Nat = 100;
  let MAX_PAGE : Nat = 500;

  public type State = {
    rows : RI.State;          // account(8) -> Row
    byStage : RI.State;       // stage(1) ‖ account(8) -> dpd(4); a stale entry is one whose row's stage differs
    byCollector : RI.State;   // collector key(8) ‖ account(8) -> stage(1); stale when the row's collector differs
    var policy : ?CT.Policy;
    var exposures : Nat;
    var transitions : Nat;
    var actions : Nat;
    var promises : Nat;
    var promisesKept : Nat;
    var promisesBroken : Nat;
  };

  public func newState(arena : RI.Arena) : State {
    {
      rows = RI.newStateIn(arena, { keyBytes = 8; valBytes = ROW_BYTES });
      byStage = RI.newStateIn(arena, { keyBytes = 9; valBytes = 4 });
      byCollector = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      var policy = null; var exposures = 0; var transitions = 0; var actions = 0; var promises = 0; var promisesKept = 0; var promisesBroken = 0;
    }
  };

  // ─── rows ─────────────────────────────────────────────────────────────────

  func encodeRow(r : Row) : Blob {
    let b = R.buf();
    R.putByte(b, CT.stageCode(r.stage)); R.putNat(b, r.dpd, 4); R.putNat(b, r.sinceDay, 4); R.putNat(b, r.sinceBlock, 8);
    var flags : Nat8 = 0;
    if (r.unlikelyToPay) flags |= 1; if (r.restructured) flags |= 2; if (r.collector != null) flags |= 4; if (r.promise != null) flags |= 8;
    R.putByte(b, flags);
    let pb = switch (r.collector) { case (?p) Blob.toArray(Principal.toBlob(p)); case null [] };
    if (pb.size() > 29) Runtime.trap("CollectionsCore: a principal of more than 29 bytes");
    R.putByte(b, Nat8.fromNat(pb.size()));
    R.putBlob(b, Blob.fromArray(Array.tabulate<Nat8>(29, func(i) { if (i < pb.size()) pb[i] else 0 })), 29);
    switch (r.promise) {
      case (?p) { R.putNat(b, p.amount, 8); R.putNat(b, p.by, 4) };
      case null { R.putNat(b, 0, 8); R.putNat(b, 0, 4) };
    };
    R.putNat(b, r.suspenseHeld, 8); R.putNat(b, r.writtenOff, 8); R.putNat(b, r.recovered, 8); R.putNat(b, r.actions, 4);
    R.putNat(b, switch (r.lastActionDay) { case (?d) d; case null 0 }, 4);
    R.putNat(b, switch (r.promise) { case (?p) p.baseline; case null 0 }, 8);
    R.done(b, ROW_BYTES)
  };

  func decodeRow(v : Blob) : Row {
    let a = Blob.toArray(v);
    let ?stage = CT.stageOfCode(a[0]) else Runtime.trap("CollectionsCore: a row with an unknown stage code");
    let flags = a[17];
    let len = Nat8.toNat(a[18]);
    let collector = if (flags & 4 == 0) null else ?Principal.fromBlob(Blob.fromArray(Array.tabulate<Nat8>(len, func(i) { a[19 + i] })));
    let promise = if (flags & 8 == 0) null else ?{ amount = R.getNat(a, 48, 8); by = R.getNat(a, 56, 4); baseline = R.getNat(a, 92, 8) };
    let lastAction = R.getNat(a, 88, 4);
    {
      stage; dpd = R.getNat(a, 1, 4); sinceDay = R.getNat(a, 5, 4); sinceBlock = R.getNat(a, 9, 8);
      unlikelyToPay = flags & 1 != 0; restructured = flags & 2 != 0; collector; promise;
      suspenseHeld = R.getNat(a, 60, 8); writtenOff = R.getNat(a, 68, 8); recovered = R.getNat(a, 76, 8); actions = R.getNat(a, 84, 4);
      lastActionDay = if (lastAction == 0) null else ?lastAction;
    }
  };

  public func row(s : State, account : Nat) : ?Row {
    switch (RI.get(s.rows, R.key(account, 8))) { case (?v) ?decodeRow(v); case null null }
  };

  func collectorKey(p : Principal) : Nat {
    let h = Blob.toArray(Sha256.fromBlob(#sha256, Principal.toBlob(p)));
    R.getNat(h, 0, 8)
  };

  func putRow(s : State, account : Nat, r : Row, previous : ?Row) {
    ignore RI.put(s.rows, R.key(account, 8), encodeRow(r));
    ignore RI.put(s.byStage, R.key2(Nat8.toNat(CT.stageCode(r.stage)), 1, account, 8), R.key(r.dpd, 4));
    switch (r.collector) { case (?c) ignore RI.put(s.byCollector, R.key2(collectorKey(c), 8, account, 8), Blob.fromArray([CT.stageCode(r.stage)])); case null {} };
    switch (previous) { case null s.exposures += 1; case (?_) {} };
  };

  func fresh(day : Nat, block : Nat) : Row {
    { stage = #current; dpd = 0; sinceDay = day; sinceBlock = block; unlikelyToPay = false; restructured = false; collector = null; promise = null;
      suspenseHeld = 0; writtenOff = 0; recovered = 0; actions = 0; lastActionDay = null }
  };

  // ─── the rule ─────────────────────────────────────────────────────────────

  public func stageRank(s : CT.Stage) : Nat { Nat8.toNat(CT.stageCode(s)) };

  /// The stage an exposure is in, from its days past due and what has been decided about it; the one rule,
  /// written once here and once in the Python oracle. Write-off, recovery and closed are left where they are
  /// (the product engine's acts and the closing command move them); a restructured exposure re-enters by its
  /// days past due on the new schedule and keeps its flag; an exposure in collections stays there while it is
  /// in arrears or unlikely to pay; unlikely-to-pay is at least default; otherwise the day thresholds decide,
  /// and zero days past due with nothing decided is a cure.
  public func deriveStage(policy : CT.Policy, r : Row, dpd : Nat) : CT.Stage {
    switch (r.stage) {
      case (#writeOff) return #writeOff; case (#recovery) return #recovery; case (#closed) return #closed;
      case (_) {};
    };
    if (dpd == 0 and not r.unlikelyToPay) return #current;
    if (r.stage == #collections) return #collections;
    if (r.unlikelyToPay or dpd >= policy.defaultDpd) return #default_;
    if (dpd >= policy.delinquentDpd) return #delinquent;
    #overdue
  };

  /// Whether interest accrued on the exposure is held in suspense under the policy.
  public func suspends(policy : CT.Policy, stage : CT.Stage) : Bool {
    switch (stage) { case (#writeOff or #recovery or #closed) false; case (_) stageRank(stage) >= stageRank(policy.suspendInterestFrom) }
  };

  public func policy(s : State) : ?CT.Policy { s.policy };

  /// What the end-of-day batch asks per loan account: the transition to record, if any, at `dpd` on `day`.
  public func transitionFor(s : State, account : Nat, dpd : Nat, day : Nat, block : Nat) : ?CT.CollectionsEvent {
    let ?p = s.policy else return null;
    let r = switch (row(s, account)) { case (?r) r; case null fresh(day, block) };
    let to = deriveStage(p, r, dpd);
    if (to == r.stage and row(s, account) != null) return null;
    let reason : CT.Reason = if (to == #current and r.stage != #current) #cured else #daysPastDue;
    ?#stageDerived({ account; from = r.stage; to; dpd; day; reason; note = "" })
  };

  // ─── the fold ─────────────────────────────────────────────────────────────

  public func apply(s : State, block : Nat, e : CT.CollectionsEvent) {
    switch (e) {
      case (#policySet(p)) s.policy := ?p;
      case (#stageDerived(x)) {
        let prev = row(s, x.account);
        let r = switch (prev) { case (?r) r; case null fresh(x.day, block) };
        let moved = r.stage != x.to;
        let r2 = { r with stage = x.to; dpd = x.dpd; sinceDay = if (moved) x.day else r.sinceDay; sinceBlock = if (moved) block else r.sinceBlock;
                   // a restructuring is a credit decision that supersedes the unlikely-to-pay judgement: the exposure is
                   // judged on the new schedule from here, its `restructured` flag kept for disclosure
                   unlikelyToPay = switch (x.reason) { case (#unlikelyToPay) true; case (#cured or #writtenOff or #closed or #restructured) false; case (_) r.unlikelyToPay };
                   restructured = switch (x.reason) { case (#restructured) true; case (_) r.restructured };
                   promise = switch (x.reason) { case (#cured or #writtenOff or #closed) null; case (_) r.promise } };
        putRow(s, x.account, r2, prev);
        if (moved) s.transitions += 1;
      };
      case (#actionRecorded(x)) {
        let prev = row(s, x.account);
        let r = switch (prev) { case (?r) r; case null fresh(x.day, block) };
        putRow(s, x.account, { r with actions = r.actions + 1; lastActionDay = ?x.day }, prev);
        s.actions += 1;
      };
      case (#promiseRecorded(x)) {
        let prev = row(s, x.account);
        let r = switch (prev) { case (?r) r; case null fresh(x.day, block) };
        putRow(s, x.account, { r with promise = ?{ amount = x.amount; by = x.by; baseline = x.baseline } }, prev);
        s.promises += 1;
      };
      case (#promiseJudged(x)) {
        let ?r = row(s, x.account) else Runtime.trap("CollectionsCore: a promise judged on an unknown exposure");
        putRow(s, x.account, { r with promise = null }, ?r);
        if (x.kept) s.promisesKept += 1 else s.promisesBroken += 1;
      };
      case (#collectorAssigned(x)) {
        let prev = row(s, x.account);
        let r = switch (prev) { case (?r) r; case null fresh(0, block) };
        putRow(s, x.account, { r with collector = ?x.staff }, prev);
      };
      case (#interestSuspended(x)) {
        let ?r = row(s, x.account) else Runtime.trap("CollectionsCore: interest suspended on an unknown exposure");
        putRow(s, x.account, { r with suspenseHeld = r.suspenseHeld + x.amount }, ?r);
      };
      case (#suspenseReleased(x)) {
        let ?r = row(s, x.account) else Runtime.trap("CollectionsCore: suspense released on an unknown exposure");
        if (x.amount > r.suspenseHeld) Runtime.trap("CollectionsCore: a release above the suspense held");
        putRow(s, x.account, { r with suspenseHeld = r.suspenseHeld - x.amount }, ?r);
      };
    }
  };

  /// The product engine's acts, as the fold sees them: a write-off, a recovery, a restructuring.
  public func noteWrittenOff(s : State, block : Nat, account : Nat, amount : Nat, day : Nat) : ?CT.CollectionsEvent {
    let ?r = row(s, account) else return null;
    if (r.stage == #writeOff or r.stage == #recovery or r.stage == #closed) return null;
    ignore block;
    ?#stageDerived({ account; from = r.stage; to = #writeOff; dpd = r.dpd; day; reason = #writtenOff; note = "written off " # Nat.toText(amount) })
  };
  public func noteRecovered(s : State, account : Nat, amount : Nat, day : Nat) : ?CT.CollectionsEvent {
    let ?r = row(s, account) else return null;
    if (r.stage != #writeOff and r.stage != #recovery) return null;
    if (r.stage == #recovery) return null;
    ?#stageDerived({ account; from = r.stage; to = #recovery; dpd = r.dpd; day; reason = #recovery; note = "recovered " # Nat.toText(amount) })
  };
  public func noteRestructured(s : State, account : Nat, day : Nat) : ?CT.CollectionsEvent {
    let ?r = row(s, account) else return null;
    if (r.stage == #writeOff or r.stage == #recovery or r.stage == #closed) return null;
    ?#stageDerived({ account; from = r.stage; to = #restructuring; dpd = r.dpd; day; reason = #restructured; note = "" })
  };
  /// Amounts a write-off and a recovery add to the row (recorded beside the stage move).
  public func addWrittenOff(s : State, account : Nat, amount : Nat) {
    let ?r = row(s, account) else return;
    putRow(s, account, { r with writtenOff = r.writtenOff + amount }, ?r);
  };
  public func addRecovered(s : State, account : Nat, amount : Nat) {
    let ?r = row(s, account) else return;
    putRow(s, account, { r with recovered = r.recovered + amount }, ?r);
  };

  // ─── the decided acts, planned ────────────────────────────────────────────

  public func planPolicy(p : CT.Policy) : Result.Result<CT.CollectionsEvent, CT.CollectionsError> {
    if (p.delinquentDpd == 0) return #err(#InvalidPolicy({ reason = "the delinquent threshold is at least one day past due" }));
    if (p.defaultDpd <= p.delinquentDpd) return #err(#InvalidPolicy({ reason = "the default threshold is later than the delinquent one" }));
    switch (p.suspendInterestFrom) {
      case (#current or #writeOff or #recovery or #closed) return #err(#InvalidPolicy({ reason = "interest is suspended from overdue, delinquent, default, collections or restructuring" }));
      case (_) {};
    };
    #ok(#policySet(p))
  };

  public func planUnlikelyToPay(s : State, account : Nat, reason : Text, day : Nat) : Result.Result<CT.CollectionsEvent, CT.CollectionsError> {
    let ?p = s.policy else return #err(#NoPolicy);
    let r = switch (row(s, account)) { case (?r) r; case null fresh(day, 0) };
    switch (r.stage) {
      case (#writeOff or #recovery or #closed) return #err(#InvalidStageTransition({ account; from = CT.stageText(r.stage); to = "default" }));
      case (_) {};
    };
    let to = deriveStage(p, { r with unlikelyToPay = true }, r.dpd);
    #ok(#stageDerived({ account; from = r.stage; to; dpd = r.dpd; day; reason = #unlikelyToPay; note = reason }))
  };

  public func planAction(s : State, account : Nat, action : CT.Action, outcome : Text, next : ?Nat, day : Nat) : Result.Result<[CT.CollectionsEvent], CT.CollectionsError> {
    let ?_ = s.policy else return #err(#NoPolicy);
    let ?r = row(s, account) else return #err(#UnknownExposure({ account }));
    switch (r.stage) {
      case (#current or #writeOff or #recovery or #closed) return #err(#InvalidStageTransition({ account; from = CT.stageText(r.stage); to = "collections" }));
      case (_) {};
    };
    let act : CT.CollectionsEvent = #actionRecorded({ account; action; outcome; next; day });
    // the first action on an exposure in arrears moves it into collections
    if (r.stage == #overdue or r.stage == #delinquent or r.stage == #default_) {
      #ok([#stageDerived({ account; from = r.stage; to = #collections; dpd = r.dpd; day; reason = #collectionAction; note = "" }), act])
    } else #ok([act])
  };

  public func planPromise(s : State, account : Nat, amount : Nat, by : Nat, day : Nat, baseline : Nat) : Result.Result<CT.CollectionsEvent, CT.CollectionsError> {
    let ?_ = s.policy else return #err(#NoPolicy);
    let ?r = row(s, account) else return #err(#UnknownExposure({ account }));
    switch (r.stage) {
      case (#current or #writeOff or #recovery or #closed) return #err(#InvalidStageTransition({ account; from = CT.stageText(r.stage); to = "promise" }));
      case (_) {};
    };
    if (by <= day) return #err(#PromiseInThePast({ by; today = day }));
    #ok(#promiseRecorded({ account; amount; by; day; baseline }))
  };

  public func planAssign(s : State, account : Nat, staff : Principal) : Result.Result<CT.CollectionsEvent, CT.CollectionsError> {
    let ?_ = s.policy else return #err(#NoPolicy);
    let ?_ = row(s, account) else return #err(#UnknownExposure({ account }));
    #ok(#collectorAssigned({ account; staff }))
  };

  public func planCloseRecovery(s : State, account : Nat, day : Nat) : Result.Result<CT.CollectionsEvent, CT.CollectionsError> {
    let ?r = row(s, account) else return #err(#UnknownExposure({ account }));
    if (r.stage != #writeOff and r.stage != #recovery) return #err(#InvalidStageTransition({ account; from = CT.stageText(r.stage); to = "closed" }));
    #ok(#stageDerived({ account; from = r.stage; to = #closed; dpd = r.dpd; day; reason = #closed; note = "" }))
  };

  /// The promise the end-of-day judges on `day`; the one that fell due before it; with the repaid total
  /// it was made against; kept when what has been repaid since reaches the amount.
  public func duePromise(s : State, account : Nat, day : Nat) : ?{ amount : Nat; by : Nat; baseline : Nat } {
    let ?r = row(s, account) else return null;
    switch (r.promise) { case (?p) { if (p.by < day) ?{ amount = p.amount; by = p.by; baseline = p.baseline } else null }; case null null }
  };
  public func judgePromise(p : { amount : Nat; by : Nat; baseline : Nat }, repaidNow : Nat) : Bool { repaidNow >= p.baseline + p.amount };

  // ─── reads ────────────────────────────────────────────────────────────────

  public func view(s : State, account : Nat) : ?CT.ExposureView {
    let ?r = row(s, account) else return null;
    ?{ account; stage = r.stage; dpd = r.dpd; sinceDay = r.sinceDay; sinceBlock = r.sinceBlock; unlikelyToPay = r.unlikelyToPay; restructured = r.restructured;
       collector = r.collector; promise = switch (r.promise) { case (?p) ?{ amount = p.amount; by = p.by }; case null null };
       suspenseHeld = r.suspenseHeld; writtenOff = r.writtenOff; recovered = r.recovered; actions = r.actions; lastActionDay = r.lastActionDay }
  };

  public type Page = { entries : [CT.ExposureView]; cursor : ?Blob };

  /// The exposures in a stage, by account, paged; a stale index entry (the row moved on) is skipped.
  public func listByStage(s : State, stage : CT.Stage, cursor : ?Blob, limit : Nat) : Page {
    let (lo, hi) = R.prefixRange(Nat8.toNat(CT.stageCode(stage)), 1, 8);
    let page = RI.range(s.byStage, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    let out = List.empty<CT.ExposureView>();
    for ((k, _) in page.entries.vals()) {
      let account = R.getNat(Blob.toArray(k), 1, 8);
      switch (view(s, account)) { case (?v) { if (v.stage == stage) List.add(out, v) }; case null {} };
    };
    { entries = List.toArray(out); cursor = page.cursor }
  };

  /// A collector's worklist: their exposures not yet closed, paged.
  public func worklist(s : State, collector : Principal, cursor : ?Blob, limit : Nat) : Page {
    let (lo, hi) = R.prefixRange(collectorKey(collector), 8, 8);
    let page = RI.range(s.byCollector, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    let out = List.empty<CT.ExposureView>();
    for ((k, _) in page.entries.vals()) {
      let account = R.getNat(Blob.toArray(k), 8, 8);
      switch (view(s, account)) {
        case (?v) { switch (v.collector) { case (?c) { if (Principal.equal(c, collector) and v.stage != #closed) List.add(out, v) }; case null {} } };
        case null {};
      };
    };
    { entries = List.toArray(out); cursor = page.cursor }
  };

  public func counts(s : State) : { exposures : Nat; transitions : Nat; actions : Nat; promises : Nat; promisesKept : Nat; promisesBroken : Nat } {
    { exposures = s.exposures; transitions = s.transitions; actions = s.actions; promises = s.promises; promisesKept = s.promisesKept; promisesBroken = s.promisesBroken }
  };

  /// Exposures per stage, walked; a report figure, bounded by the rows.
  public func stageDistribution(s : State) : [(Text, Nat)] {
    let counts = VarArray.repeat<Nat>(0, 9);
    let (lo, hi) = R.fullRange(8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.rows, lo, hi, cursor, MAX_PAGE);
      for ((_, v) in page.entries.vals()) { let r = decodeRow(v); counts[stageRank(r.stage)] += 1 };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    Array.tabulate<(Text, Nat)>(9, func(i) { let ?st = CT.stageOfCode(Nat8.fromNat(i)) else Runtime.trap("stage"); (CT.stageText(st), counts[i]) })
  };

  // ─── fingerprint ──────────────────────────────────────────────────────────

  /// One index into the fingerprint: its size and its row digest (`RegionIndex` improvement 5; the sum of the
  /// rows' hashes, maintained at every `put`), in place of a walk of every row: two states holding the same rows
  /// write the same words, and the cost is one word an index whatever the book's size.
  func fingerprintRows(w : C.Writer, idx : RI.State) { w.nat(RI.size(idx)); w.blobRaw(RI.digest(idx)) };

  public func fingerprintInto(w : C.Writer, s : State) {
    switch (s.policy) {
      case null w.byte(0);
      case (?p) { w.byte(1); w.nat(p.delinquentDpd); w.nat(p.defaultDpd); w.byte(CT.stageCode(p.suspendInterestFrom)); w.bool(p.recogniseModificationLoss) };
    };
    w.nat(s.exposures); w.nat(s.transitions); w.nat(s.actions); w.nat(s.promises); w.nat(s.promisesKept); w.nat(s.promisesBroken);
    fingerprintRows(w, s.rows);
    fingerprintRows(w, s.byStage);
    fingerprintRows(w, s.byCollector);
  };
}
