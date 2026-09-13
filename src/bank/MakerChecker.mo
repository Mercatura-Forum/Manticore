/// MakerChecker.mo — the four-eyes lifecycle, as pure functions.
///
/// The hole in the obvious implementation is that the checker approves a stored
/// *row*. If anything can alter that row between proposal and approval, the
/// checker approved one thing and another thing happened. So a proposal records
/// the command **and** the hash of its canonical encoding, an approval carries
/// the hash the checker saw, and execution re-derives the hash from the recorded
/// command and requires equality with every approval. That check is
/// `hashesAgree` below, and it is the reason this module exists as something
/// other than a counter.
///
/// Fail-closed is the other rule. A permission the catalogue marks
/// `dualByDefault` with no policy recorded has nobody declared eligible to
/// approve it, so it cannot be approved, so the command is refused rather than
/// executed single-handed. `Bank.mo` writes a policy for every such permission
/// at install from the declared genesis default, so the table is complete from
/// block 0 and resolution is always a lookup, never an implicit default.
///
/// ## Where a proposal lives
///
/// The heap holds nothing per proposal. Everything a proposal *is* — the command, its hash, the
/// maker, the policy it was proposed under, the justification — is in its `#commandProposed` block;
/// everything that *happens* to it is a later block (`#commandApproved`, `#commandExecuted`,
/// `#commandRejected`, `#commandExpired`). The fold keeps one fixed-width **row** per proposal in
/// stable memory (`ProposalRow`: the expiry, the status with the block that resolved it, and the
/// block indices of its approvals), and an `Entry` is rebuilt from the row plus those blocks when a
/// reader or a checker needs one. The same shape as the journal's per-posting state: the log is the
/// record, the row is the pointer, and the heap does not grow with the book. Overrides are the same
/// (`OverrideRow`).

import Text "mo:core/Text";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import List "mo:core/List";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";

import T "BankTypes";

module {

  /// A proposal, rebuilt from its row and its blocks. Immutable: a reader's view of one moment.
  public type Entry = {
    index : Nat;                    // bank block index of #commandProposed
    command : ?T.Command;           // the body, or its reconstruction; null where neither is available
    commandHash : Blob;
    commandEncoding : Nat8;         // the frozen encoder the hash and the body were made with
    permission : T.PermissionId;
    book : ?T.BookId;
    maker : Principal;
    required : Nat;
    eligibleRole : T.RoleId;
    expiresAt : Nat64;
    justification : Text;
    approvals : [Principal];
    status : Status;
  };

  /// What the fold keeps per proposal, in stable memory. `approvalBlocks` are the indices of the
  /// `#commandApproved` blocks, at most `T.MAX_REQUIRED_APPROVALS` of them: an approval that
  /// completes the policy executes the command in the same step, so no proposal ever collects more.
  public type ProposalRow = {
    expiresAt : Nat64;
    status : RowStatus;
    approvalBlocks : [Nat];
  };

  /// The status as the row holds it: the tag, and the block that resolved the proposal.
  public type RowStatus = {
    #awaiting;
    #executed : Nat;
    #rejected : Nat;
    #expired : Nat;
  };

  /// `tag(1) ‖ resolvedAt(8 BE) ‖ expiresAt(8 BE) ‖ count(1) ‖ 8 × approvalBlock(8 BE)`.
  public let PROPOSAL_ROW_BYTES : Nat = 82;   // 1 + 8 + 8 + 1 + 8 × 8

  public func encodeProposalRow(r : ProposalRow) : Blob {
    let out = List.empty<Nat8>();
    let (tag, at) : (Nat8, Nat) = switch (r.status) {
      case (#awaiting) (0, 0);
      case (#executed(b)) (1, b);
      case (#rejected(b)) (2, b);
      case (#expired(b)) (3, b);
    };
    List.add(out, tag);
    for (b in be8(at).vals()) List.add(out, b);
    for (b in be8(Nat64.toNat(r.expiresAt)).vals()) List.add(out, b);
    assert (r.approvalBlocks.size() <= T.MAX_REQUIRED_APPROVALS);
    List.add(out, Nat8.fromNat(r.approvalBlocks.size()));
    var i = 0;
    while (i < T.MAX_REQUIRED_APPROVALS) {
      let v = if (i < r.approvalBlocks.size()) r.approvalBlocks[i] else 0;
      for (b in be8(v).vals()) List.add(out, b);
      i += 1;
    };
    Blob.fromArray(List.toArray(out))
  };

  public func decodeProposalRow(bytes : Blob) : ProposalRow {
    let a = Blob.toArray(bytes);
    assert (a.size() == PROPOSAL_ROW_BYTES);
    let at = beNat(a, 1);
    let status : RowStatus = switch (a[0]) {
      case 0 #awaiting;
      case 1 #executed(at);
      case 2 #rejected(at);
      case 3 #expired(at);
      case _ { assert false; #awaiting };
    };
    let expiresAt = Nat64.fromNat(beNat(a, 9));
    let n = Nat8.toNat(a[17]);
    let approvalBlocks = Array.tabulate<Nat>(n, func(i) { beNat(a, 18 + 8 * i) });
    { expiresAt; status; approvalBlocks }
  };

  /// What the fold keeps per override: the block that executed it and the block that reviewed it,
  /// 0 meaning not yet — block 0 is the genesis administrator record and can be neither.
  public type OverrideRow = { executedAt : Nat; reviewedAt : Nat };

  public let OVERRIDE_ROW_BYTES : Nat = 16;

  public func encodeOverrideRow(r : OverrideRow) : Blob {
    let out = List.empty<Nat8>();
    for (b in be8(r.executedAt).vals()) List.add(out, b);
    for (b in be8(r.reviewedAt).vals()) List.add(out, b);
    Blob.fromArray(List.toArray(out))
  };

  public func decodeOverrideRow(bytes : Blob) : OverrideRow {
    let a = Blob.toArray(bytes);
    assert (a.size() == OVERRIDE_ROW_BYTES);
    { executedAt = beNat(a, 0); reviewedAt = beNat(a, 8) }
  };

  func be8(v : Nat) : [Nat8] {
    var x = v;
    let le = Array.tabulate<Nat8>(8, func(_) { let b = Nat8.fromNat(x % 256); x /= 256; b });
    Array.tabulate<Nat8>(8, func(i) { le[7 - i] })
  };

  func beNat(a : [Nat8], from : Nat) : Nat {
    var v = 0;
    var i = 0;
    while (i < 8) { v := v * 256 + Nat8.toNat(a[from + i]); i += 1 };
    v
  };

  public type Status = {
    #awaiting;
    #executed : { at : Nat; postings : [Nat] };
    #rejected : { by : Principal; reason : Text };
    #expired;
  };

  public func isAwaiting(e : Entry) : Bool { switch (e.status) { case (#awaiting) true; case (_) false } };

  public func hasApproved(e : Entry, p : Principal) : Bool {
    for (a in e.approvals.vals()) { if (Principal.equal(a, p)) return true };
    false
  };

  public func approvalCount(e : Entry) : Nat { e.approvals.size() };

  public func approvers(e : Entry) : [Principal] { e.approvals };

  public func isExpired(e : Entry, now : Nat64) : Bool { e.expiresAt <= now };

  /// The command the proposal recorded must still hash to what the approvers
  /// signed off. Re-derivation happens at execution, from the recorded command.
  public func hashesAgree(recorded : Blob, recomputed : Blob) : Bool { recorded == recomputed };

  /// Validate a policy before it is recorded. A policy that cannot be satisfied
  /// is refused when it is written, not discovered when a command cannot be
  /// approved.
  public func validatePolicy(p : T.DualPolicy, permissionExists : Bool, roleExists : Bool, eligibleCount : Nat) : ?Text {
    if (not permissionExists) return ?("unknown permission " # p.permission);
    if (not roleExists) return ?("unknown role " # p.eligibleRole);
    if (p.required == 0) return ?"required approvals must be at least one; a permission with no approvals is not dual control";
    if (p.required > T.MAX_REQUIRED_APPROVALS) return ?"required approvals exceed the bound";
    if (p.ttlSeconds < T.MIN_PROPOSAL_TTL_SECONDS) return ?"proposal lifetime is shorter than the minimum";
    if (p.ttlSeconds > T.MAX_PROPOSAL_TTL_SECONDS) return ?"proposal lifetime exceeds the maximum";
    // A policy requiring more approvers than there are principals holding the
    // eligible role can never be satisfied. Refusing here is the difference
    // between a configuration error and a queue nobody can clear.
    if (eligibleCount < p.required) {
      return ?("policy requires " # debug_show (p.required) # " approvals but only " # debug_show (eligibleCount) # " principals hold role " # p.eligibleRole);
    };
    null
  };

  /// What a checker must satisfy. Self-approval and double-approval are refused
  /// by comparing principals, which is the whole of the control: a maker who
  /// also holds the checker role still cannot approve its own proposal.
  public func checkApprover(e : Entry, checker : Principal, holdsEligibleRole : Bool, now : Nat64) : ?T.BankError {
    if (not isAwaiting(e)) return ?#ProposalNotAwaiting({ index = e.index });
    if (isExpired(e, now)) return ?#ProposalExpired({ index = e.index; expiresAt = e.expiresAt });
    if (Principal.equal(e.maker, checker)) return ?#SelfApproval({ maker = e.maker });
    if (hasApproved(e, checker)) return ?#AlreadyApproved({ checker });
    if (not holdsEligibleRole) return ?#NotEligibleChecker({ checker; eligibleRole = e.eligibleRole });
    null
  };

  /// True when this approval is the one that completes the policy.
  public func completesWith(e : Entry, _checker : Principal) : Bool {
    approvalCount(e) + 1 >= e.required
  };

  public func statusView(e : Entry) : T.ProposalStatus {
    switch (e.status) {
      case (#awaiting) #awaitingApproval({ approvals = approvers(e) });
      case (#executed(x)) #executed(x);
      case (#rejected(x)) #rejected(x);
      case (#expired) #expired;
    }
  };

  public func resultText(e : Entry) : Text {
    switch (e.status) {
      case (#awaiting) "Awaiting Approval";
      case (#executed(_)) "Processed";
      case (#rejected(_)) "Rejected";
      case (#expired) "Expired";
    }
  };

  public func view(e : Entry) : T.ProposalView {
    {
      index = e.index; command = e.command; commandHash = e.commandHash; commandEncoding = e.commandEncoding; permission = e.permission; book = e.book;
      maker = e.maker; required = e.required; eligibleRole = e.eligibleRole;
      expiresAt = e.expiresAt; justification = e.justification;
      status = statusView(e);
    }
  };

  public func auditRow(e : Entry) : T.AuditRow {
    {
      proposal = e.index;
      permission = e.permission;
      maker = e.maker;
      checkers = approvers(e);
      result = resultText(e);
      proposedAtBlock = e.index;
      resolvedAtBlock = switch (e.status) { case (#executed(x)) ?x.at; case (_) null };
      postings = switch (e.status) { case (#executed(x)) x.postings; case (_) [] };
    }
  };

  /// An override, rebuilt from its row and its blocks.
  public type OverrideEntry = {
    index : Nat;
    command : T.Command;
    commandHash : Blob;
    commandEncoding : Nat8;
    actor_ : Principal;
    witness : Principal;
    justification : Text;
    postings : [Nat];
    reviewedBy : ?Principal;
    disposition : ?Text;
  };

  public func isReviewed(o : OverrideEntry) : Bool { o.reviewedBy != null };

  public func textFits(t : Text, max : Nat) : Bool { Text.encodeUtf8(t).size() <= max };
};
