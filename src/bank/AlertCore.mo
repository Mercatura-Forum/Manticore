/// AlertCore.mo; the alerts, folded from the bank's log, in stable memory.
///
/// Alerts grow with activity, so the heap holds none of them. The fold keeps one 22-byte row per
/// alert (the status, the block that resolved it, the account, the day, the source), an index from
/// the finding's key to the alert that opened it; which is what makes opening idempotent; and
/// two ranges a reviewer reads: the open alerts, and an account's alerts. The finding itself is in
/// the `#alertOpened` block; an `Alert` is rebuilt from the row and that block.

import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Array "mo:core/Array";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";

import MT "MonitoringTypes";
import AT "AlertTypes";
import R "StableRows";

module {

  public type Blocks = { get : Nat -> ?AT.AlertEvent };

  /// `status(1) ‖ resolvedAt(8) ‖ account(8) ‖ day(4) ‖ source(1)`; 22 bytes.
  public type Row = { status : Nat8; resolvedAt : Nat; account : Nat; day : Nat; source : Nat8 };
  public let ROW_BYTES : Nat = 22;

  public type State = {
    rows : RI.State;          // alert(8) -> Row
    byKey : RI.State;         // finding key(32) -> alert(8)
    open : RI.State;          // alert(8) -> 0
    byAccount : RI.State;     // account(8) ‖ alert(8) -> status(1)
    var opened : Nat;
    var cleared : Nat;
    var escalated : Nat;
  };

  public func newState(arena : RI.Arena) : State {
    {
      rows = RI.newStateIn(arena, { keyBytes = 8; valBytes = ROW_BYTES });
      byKey = RI.newStateIn(arena, { keyBytes = 32; valBytes = 8 });
      open = RI.newStateIn(arena, { keyBytes = 8; valBytes = 1 });
      byAccount = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      var opened = 0; var cleared = 0; var escalated = 0;
    }
  };

  let STATUS_OPEN : Nat8 = 0;
  let STATUS_CLEARED : Nat8 = 1;
  let STATUS_ESCALATED : Nat8 = 2;

  func encodeRow(r : Row) : Blob {
    let b = R.buf();
    R.putByte(b, r.status); R.putNat(b, r.resolvedAt, 8); R.putNat(b, r.account, 8); R.putNat(b, r.day, 4); R.putByte(b, r.source);
    R.done(b, ROW_BYTES)
  };
  func decodeRow(v : Blob) : Row {
    let a = Blob.toArray(v);
    { status = a[0]; resolvedAt = R.getNat(a, 1, 8); account = R.getNat(a, 9, 8); day = R.getNat(a, 17, 4); source = a[21] }
  };

  /// The finding's key: the rule, version, account, day and the cited postings, hashed. Two
  /// findings that say the same thing have one key, whatever produced them.
  public func keyOf(f : MT.Finding) : Blob {
    let w = C.Writer();
    w.text("thebes.bank.alert.key.v1");
    w.text(f.rule); w.nat(f.version); w.nat(f.account); w.nat(f.day);
    let ps = Array.sort<Nat>(f.postings, Nat.compare);
    w.len16(ps.size());
    for (p in ps.vals()) w.nat(p);
    Sha256.fromArray(#sha256, w.toArray())
  };

  public func row(s : State, id : AT.AlertId) : ?Row {
    switch (RI.get(s.rows, R.key(id, 8))) { case (?v) ?decodeRow(v); case null null }
  };

  /// The alert already opened for a finding, if any.
  public func known(s : State, f : MT.Finding) : ?AT.AlertId {
    switch (RI.get(s.byKey, keyOf(f))) { case (?v) ?R.getNat(Blob.toArray(v), 0, 8); case null null }
  };

  public func apply(s : State, block : Nat, e : AT.AlertEvent) {
    switch (e) {
      case (#alertOpened(x)) {
        let source : Nat8 = switch (x.source) { case (#posting) 0; case (#endOfDay) 1 };
        ignore RI.put(s.rows, R.key(block, 8), encodeRow({ status = STATUS_OPEN; resolvedAt = 0; account = x.finding.account; day = x.finding.day; source }));
        ignore RI.put(s.byKey, keyOf(x.finding), R.key(block, 8));
        ignore RI.put(s.open, R.key(block, 8), "\00");
        ignore RI.put(s.byAccount, R.key2(x.finding.account, 8, block, 8), "\00");
        s.opened += 1;
      };
      case (#alertCleared(x)) resolve(s, x.alert, block, STATUS_CLEARED);
      case (#alertEscalated(x)) resolve(s, x.alert, block, STATUS_ESCALATED);
    }
  };

  func resolve(s : State, id : AT.AlertId, block : Nat, status : Nat8) {
    let ?r = row(s, id) else Runtime.trap("AlertCore: review of an unknown alert " # Nat.toText(id));
    ignore RI.put(s.rows, R.key(id, 8), encodeRow({ r with status; resolvedAt = block }));
    // an open-set entry cannot be removed from a RegionIndex; it is marked and skipped by readers
    ignore RI.put(s.open, R.key(id, 8), if (status == STATUS_CLEARED) "\01" else "\02");
    ignore RI.put(s.byAccount, R.key2(r.account, 8, id, 8), Blob.fromArray([status]));
    if (status == STATUS_CLEARED) s.cleared += 1 else s.escalated += 1;
  };

  func eventAt(bb : Blocks, index : Nat, what : Text) : AT.AlertEvent {
    let ?e = bb.get(index) else Runtime.trap("AlertCore: the log has no alert event at block " # Nat.toText(index) # " for " # what);
    e
  };

  /// An alert, rebuilt from its row and its blocks.
  public func get(s : State, bb : Blocks, id : AT.AlertId) : ?AT.Alert {
    let ?r = row(s, id) else return null;
    let #alertOpened(o) = eventAt(bb, id, "an alert") else Runtime.trap("AlertCore: block " # Nat.toText(id) # " has an alert row but is not an opening");
    let status : AT.Status = if (r.status == STATUS_OPEN) #open else {
      switch (eventAt(bb, r.resolvedAt, "an alert's review")) {
        case (#alertCleared(c)) #cleared({ reason = c.reason; at = r.resolvedAt });
        case (#alertEscalated(e)) #escalated({ reportRef = e.reportRef; at = r.resolvedAt });
        case (_) Runtime.trap("AlertCore: a resolution pointer to a block that is not a review");
      }
    };
    ?{ id; finding = o.finding; source = o.source; openedAt = id; status }
  };

  public func counts(s : State) : { opened : Nat; cleared : Nat; escalated : Nat; open : Nat } {
    { opened = s.opened; cleared = s.cleared; escalated = s.escalated; open = s.opened - s.cleared - s.escalated }
  };

  public let MAX_PAGE : Nat = 500;

  func mustGet(s : State, bb : Blocks, id : AT.AlertId) : AT.Alert {
    let ?a = get(s, bb, id) else Runtime.trap("AlertCore: an alert row without an opening at " # Nat.toText(id));
    a
  };

  public type Page = { rows : [AT.Alert]; cursor : ?AT.AlertId; total : Nat };

  func pageOf(s : State, bb : Blocks, idx : RI.State, cursor : ?Nat, limit : Nat, keep : Nat8 -> Bool) : Page {
    let n = if (limit == 0 or limit > MAX_PAGE) MAX_PAGE else limit;
    let (lo, hi) = R.fullRange(8);
    let page = RI.range(idx, lo, hi, switch (cursor) { case (?c) ?R.key(c, 8); case null null }, n);
    let out = List.empty<AT.Alert>();
    for ((k, v) in page.entries.vals()) {
      if (keep(Blob.toArray(v)[0])) List.add(out, mustGet(s, bb, R.getNat(Blob.toArray(k), 0, 8)));
    };
    { rows = List.toArray(out); cursor = switch (page.cursor) { case (?k) ?R.getNat(Blob.toArray(k), 0, 8); case null null }; total = RI.size(idx) }
  };

  /// Every alert, ascending, paged.
  public func listPaged(s : State, bb : Blocks, cursor : ?AT.AlertId, limit : Nat) : Page {
    pageOf(s, bb, s.rows, cursor, limit, func(_) { true })
  };

  /// The open alerts, ascending, paged. A page walks the open set and skips the entries that were
  /// resolved (marked, since the set cannot shrink), so `rows` may be shorter than `limit`; the
  /// cursor still advances and `total` counts the set as written.
  public func listOpenPaged(s : State, bb : Blocks, cursor : ?AT.AlertId, limit : Nat) : Page {
    pageOf(s, bb, s.open, cursor, limit, func(v) { v == 0 })
  };

  public func alertsOfAccount(s : State, bb : Blocks, account : Nat, limit : Nat) : [AT.Alert] {
    let n = if (limit == 0 or limit > MAX_PAGE) MAX_PAGE else limit;
    let (lo, hi) = R.prefixRange(account, 8, 8);
    let page = RI.range(s.byAccount, lo, hi, null, n);
    Array.map<(Blob, Blob), AT.Alert>(page.entries, func((k, _)) { mustGet(s, bb, R.getNat(Blob.toArray(k), 8, 8)) })
  };

  // ─── the review, under maker-checker ──────────────────────────────────────

  public func planClear(s : State, id : AT.AlertId, reason : Text) : Result.Result<AT.AlertEvent, AT.AlertError> {
    let ?r = row(s, id) else return #err(#UnknownAlert({ alert = id }));
    if (r.status != STATUS_OPEN) return #err(#AlertNotOpen({ alert = id; status = if (r.status == STATUS_CLEARED) "cleared" else "escalated" }));
    if (not AT.textFits(reason, AT.MAX_REASON_BYTES)) return #err(#InvalidReview({ reason = "a clearance carries a reason of 1.." # Nat.toText(AT.MAX_REASON_BYTES) # " bytes" }));
    #ok(#alertCleared({ alert = id; reason }))
  };

  public func planEscalate(s : State, id : AT.AlertId, reportRef : Text) : Result.Result<AT.AlertEvent, AT.AlertError> {
    let ?r = row(s, id) else return #err(#UnknownAlert({ alert = id }));
    if (r.status != STATUS_OPEN) return #err(#AlertNotOpen({ alert = id; status = if (r.status == STATUS_CLEARED) "cleared" else "escalated" }));
    if (not AT.textFits(reportRef, AT.MAX_REPORT_REF_BYTES)) return #err(#InvalidReview({ reason = "an escalation carries the report reference it is filed under, 1.." # Nat.toText(AT.MAX_REPORT_REF_BYTES) # " bytes" }));
    #ok(#alertEscalated({ alert = id; reportRef }))
  };

  /// One index into the fingerprint: its size and its row digest (`RegionIndex` improvement 5; the sum of the
  /// rows' hashes, maintained at every `put`), in place of a walk of every row: two states holding the same rows
  /// write the same words, and the cost is one word an index whatever the book's size.
  func fingerprintRows(w : C.Writer, idx : RI.State) { w.nat(RI.size(idx)); w.blobRaw(RI.digest(idx)) };

  public func fingerprintInto(w : C.Writer, s : State) {
    w.nat(s.opened); w.nat(s.cleared); w.nat(s.escalated);
    fingerprintRows(w, s.rows);
    fingerprintRows(w, s.byKey);
    fingerprintRows(w, s.open);
    fingerprintRows(w, s.byAccount);
  };
}
