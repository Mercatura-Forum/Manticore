/// BankCore.mo — the banking domain state machine: admission, the fold, views.
///
/// Shaped after `mo:journal/JournalCore`, deliberately. Every state change is
/// one event applied by `apply`, which is the only place state changes; every
/// `prepare*` function is pure and returns either a typed error or the event(s)
/// to commit; `replay` rebuilds the state from the log and `fingerprint` digests
/// it, so "the materialised state is exactly the fold of the log" is a property
/// a test asserts rather than a claim.
///
/// This module holds no balance. A balance is a journal balance. What it holds is
/// authority: books, roles, grants, dual-authorisation policies, proposals,
/// overrides, feature activation heights, and the consumed-today figures that
/// daily limits are measured against.
///
/// Two rules are worth finding here rather than in a commit message.
///
/// **Fail closed on dual control.** A permission the catalogue marks
/// `dualByDefault` with no policy recorded cannot be performed and cannot be
/// approved: nobody is declared eligible, so nothing is. `Bank.mo` writes a
/// policy for every such permission at install, from the genesis declaration, so
/// the table is complete from block 0.
///
/// **What a refusal records.** A refusal to exceed *authority* — no grant,
/// outside scope, over a ceiling or a daily limit, self-approval, an ineligible
/// checker, a command-hash mismatch, an expired proposal — is recorded as an
/// `#operationRefused` block, because a bank has to be able to prove what it
/// prevented. A refusal for *malformed or impossible input* — an unknown book, a
/// closed period, an unbalanced posting — returns a typed error and records
/// nothing, exactly as the journal refuses. The line is drawn at "did someone
/// try to exceed what they were given", and only principals the bank has
/// onboarded (those holding at least one grant) can cause a block, so the log
/// cannot be grown by an unknown caller.

import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Principal "mo:core/Principal";
import Map "mo:core/Map";
import List "mo:core/List";
import Array "mo:core/Array";
import Order "mo:core/Order";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Sha256 "mo:sha2/Sha256";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";
import JC "mo:journal/Canonical";
import YearEnd "mo:journal/YearEnd";

import T "BankTypes";
import C "BankCanonical";
import P "Permissions";
import E "Entitlements";
import PT "PartyTypes";
import PartyCore "PartyCore";
import Screening "Screening";
import Commit "Commitments";
import Iban "Iban";
import MC "MakerChecker";
import Reconstruct "Reconstruct";
import RI "mo:ledger/RegionIndex";
import ProdT "ProductTypes";
import ProductCore "ProductCore";
import Products "Products";
import Charges "Charges";
import Loans "Loans";
import TermProducts "TermProducts";
import Till "Till";
import Limits "Limits";
import Posting "Posting";
import I "Interest";
import DC "DayCount";
import CT "CloseTypes";
import CloseCore "CloseCore";
import Conv "Conventions";
import Fx "Fx";
import Deferrals "Deferrals";
import PE "PeriodEnd";
import BackValue "BackValue";
import BT "BatchTypes";
import Batch "Batch";
import BatchCore "BatchCore";
import RepT "ReportTypes";
import Reports "Reports";
import ReturnsM "Returns";
import StatementsM "Statements";
import Filings "Filings";
import FeedM "Feed";
import ReportCore "ReportCore";
import IndexCore "IndexCore";
import IdxT "IndexTypes";
import ArchiveCore "ArchiveCore";
import MonitoringCore "MonitoringCore";
import MT "MonitoringTypes";
import AlertCore "AlertCore";
import ColT "CollectionsTypes";
import CollectionsCore "CollectionsCore";
import OT "OriginationTypes";
import OriginationCore "OriginationCore";
import FaT "FacilityTypes";
import FacilityCore "FacilityCore";
import FCan "FacilityCanonical";
import TeT "TellerTypes";
import TellerCore "TellerCore";
import TrT "TradeTypes";
import TradeCore "TradeCore";
import TradeMessages "TradeMessages";
import IT "IslamicTypes";
import IslamicCore "IslamicCore";
import AlT "AlertTypes";
import Packing "Packing";
import ST "ShardTypes";
import ShardCore "ShardCore";
import SeT "SettlementTypes";
import SettlementCore "SettlementCore";
import PayT "PaymentsTypes";
import PaymentsCore "PaymentsCore";
import FT "FspiopTypes";
import FspiopCore "FspiopCore";
import Json "Json";
import Base64 "Base64";
import IsoMessages "IsoMessages";
import IsoSchema "IsoSchema";
import Xml "Xml";
import Leadsheet "mo:journal/Leadsheet";

module {

  // ═══════════════════════════════════════════════════════
  //  STATE
  // ═══════════════════════════════════════════════════════

  public type BookEntry = {
    id : T.BookId;
    name : Text;
    parent : ?T.BookId;
    var status : T.BookStatus;
    openedAtBlock : Nat;
    var closedAtBlock : ?Nat;
  };

  public type RoleEntry = { id : T.RoleId; name : Text; permissions : [T.PermissionId]; definedAtBlock : Nat };
  public type GrantEntry = { subject : Principal; role : T.RoleId; scope : T.Scope; grantedAtBlock : Nat };

  public type State = {
    var admin : Principal;
    var height : Nat;
    books : Map.Map<T.BookId, BookEntry>;
    roles : Map.Map<T.RoleId, RoleEntry>;
    grants : Map.Map<(Principal, T.RoleId), GrantEntry>;
    policies : Map.Map<T.PermissionId, T.DualPolicy>;
    features : Map.Map<T.FeatureId, Nat64>;
    /// One fixed-width row per proposal, in stable memory, keyed by the proposal's block index
    /// (`MC.ProposalRow`). The proposal itself is its block; the row is what happened to it.
    /// The one region every stable index of the bank's state allocates from — the maker-checker
    /// rows, the party and product sub-states. A Region reserves 8 MiB; an arena shares it.
    arena : RI.Arena;
    proposalRows : RI.State;
    /// The proposals still awaiting: bounded by the policies' lifetimes, not by the book.
    openProposals : Map.Map<Nat, ()>;
    /// One row per override (`MC.OverrideRow`), likewise.
    overrideRows : RI.State;
    openOverrides : Map.Map<Nat, ()>;
    /// (subject, currency, business day) -> minor units already used. Maintained
    /// by `apply`, so it is the fold of the log and `replay` reproduces it.
    consumed : Map.Map<(Principal, Text, Nat), Nat>;
    /// The party / CIF and KYC sub-state, folded from the same log.
    party : PartyCore.State;
    /// The product engine's sub-state, folded from the same log. It holds
    /// products, accounts, schedules and tills — and no balance, because a balance
    /// is a journal balance.
    product : ProductCore.State;
    /// Value dating, foreign currency and the close: rates, position pairs,
    /// deferral schedules, back-value windows and approvals, and the period-end runs.
    /// No balance here either: a position is a journal balance in its own currency
    /// and its equivalent is a journal balance in the functional one.
    close : CloseCore.State;
    /// The end-of-day batch: runs and their cursors, standing instructions, the
    /// latest statement cut per account, and the retry policy per book. The plan is not
    /// stored — it is a pure function of what the opening block records, so it is
    /// recomputed and checked against the recorded hash rather than kept as a second
    /// copy that could disagree.
    batch : BatchCore.State;
    /// Reporting: the registered definitions and templates, the declared statement
    /// map, the statement register, the hashes of the artefacts that have been certified,
    /// and the feed's recorded endpoints. No figure is stored — a report is a fold over the
    /// journal at a stated height.
    report : ReportCore.State;
    /// Indexing: the declared dimension the counterparty-class index keys on. The indexes
    /// themselves are derived from the log and live in stable memory under `PostingIndex`; what is
    /// folded here is only the declaration that gives a key its meaning.
    index : IndexCore.State;
    /// Archive contracts: the pinned image, the controller set, and every spawn with the step it
    /// has reached. The image bytes themselves are in stable memory beside this state
    /// (`ArchiveImage`), like the indexes: bytes, not decisions.
    archive : ArchiveCore.State;
    /// Monitoring: the declared rules. The aggregates they read live beside the posting indexes.
    monitoring : MonitoringCore.State;
    /// Alerts: findings recorded, and their review. Rows in stable memory; the finding is its block.
    alerts : AlertCore.State;
    /// Collections and recovery (collections and recovery): the stage of every lending exposure, the policy, the collectors'
    /// records. Rows in stable memory; every transition is a block.
    collections : CollectionsCore.State;
    /// Origination and underwriting (origination and underwriting): the applications, the models as data, the passkeys. Rows in
    /// stable memory; every step is a block.
    origination : OriginationCore.State;
    /// Corporate lending (corporate lending): the facilities, their drawings, syndicate shares, receivables, covenants and
    /// rate fixings. Rows in stable memory; every act is a block; every amount is the journal's.
    facility : FacilityCore.State;
    /// Branch and teller (branch and teller): sessions, the denomination positions of tills and vaults, cash in transit, cheques
    /// and drafts. Rows in stable memory; every act is a block; every amount is the journal's.
    teller : TellerCore.State;
    /// Trade finance (trade finance): documentary credits, undertakings, collections, bills, their claims and messages.
    trade : TradeCore.State;
    /// Islamic banking (Islamic banking): the Sharia contracts, their instalments, the investment pools, the governance record.
    islamic : IslamicCore.State;
    /// Closed-month packing as the log says it: the pack in progress and the boundary the reads
    /// honour. The packs themselves — segments, rows, lists — live beside the indexes (`Packing`).
    packing : PackingFold;
    /// Shards: the routing rule's versions and the inter-shard transfers.
    shard : ShardCore.State;
    /// Settlement on the journal: schemes, participants, transfers, windows, settlements.
    settlement : SettlementCore.State;
    /// ISO 20022 messaging on the journal: rails, connector keys, messages, holds.
    payments : PaymentsCore.State;
    /// FSPIOP: the participant directory, the oracle, the quotes, the transfers by id.
    fspiop : FspiopCore.State;
    var refusedCount : Nat;
    var executedCount : Nat;
  };

  public type PackingFold = {
    var current : ?{ pack : Nat; period : Text; periodEnd : Nat; lo : Nat; hi : Nat; bankLo : Nat; bankHi : Nat };
    var packedThroughBlock : Nat;
    var packedThroughDay : Nat;
    /// the bank log's own packed boundary (§18.3)
    var bankPackedThroughBlock : Nat;
    var packs : Nat;
    /// Every sealed pack: its range and period, for the roll's gate.
    sealed : Map.Map<Nat, { period : Text; periodEnd : Nat; lo : Nat; hi : Nat; segments : Nat; bankLo : Nat; bankHi : Nat; bankSegments : Nat }>;
    var roll : ?{ pack : Nat; cid : Nat64; archive : Principal; hi : Nat };
    var archivedThroughBlock : Nat;
    var archivedPacks : Nat;
    /// pack -> where its blocks went
    archives : Map.Map<Nat, { cid : Nat64; archive : Principal; hi : Nat }>;
  };

  func cmpPR(a : (Principal, Text), b : (Principal, Text)) : Order.Order {
    switch (Principal.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o }
  };
  func cmpPCD(a : (Principal, Text, Nat), b : (Principal, Text, Nat)) : Order.Order {
    switch (Principal.compare(a.0, b.0)) {
      case (#equal) { switch (Text.compare(a.1, b.1)) { case (#equal) Nat.compare(a.2, b.2); case (o) o } };
      case (o) o;
    }
  };

  public func newState(admin : Principal) : State {
    let arena = RI.newArena();
    {
      arena;
      var admin;
      var height = 0;
      books = Map.empty<T.BookId, BookEntry>();
      roles = Map.empty<T.RoleId, RoleEntry>();
      grants = Map.empty<(Principal, T.RoleId), GrantEntry>();
      policies = Map.empty<T.PermissionId, T.DualPolicy>();
      features = Map.empty<T.FeatureId, Nat64>();
      proposalRows = RI.newStateIn(arena, { keyBytes = 8; valBytes = MC.PROPOSAL_ROW_BYTES });
      openProposals = Map.empty<Nat, ()>();
      overrideRows = RI.newStateIn(arena, { keyBytes = 8; valBytes = MC.OVERRIDE_ROW_BYTES });
      openOverrides = Map.empty<Nat, ()>();
      consumed = Map.empty<(Principal, Text, Nat), Nat>();
      party = PartyCore.newState(arena);
      product = ProductCore.newState(arena);
      close = CloseCore.newState();
      batch = BatchCore.newState();
      report = ReportCore.newState();
      index = IndexCore.newState();
      archive = ArchiveCore.newState();
      monitoring = MonitoringCore.newState();
      alerts = AlertCore.newState(arena);
      collections = CollectionsCore.newState(arena);
      origination = OriginationCore.newState(arena);
      facility = FacilityCore.newState(arena);
      teller = TellerCore.newState(arena);
      trade = TradeCore.newState(arena);
      islamic = IslamicCore.newState(arena);
      packing = { var current = null; var packedThroughBlock = 0; var packedThroughDay = 0; var bankPackedThroughBlock = 0; var packs = 0; sealed = Map.empty<Nat, { period : Text; periodEnd : Nat; lo : Nat; hi : Nat; segments : Nat; bankLo : Nat; bankHi : Nat; bankSegments : Nat }>(); var roll = null; var archivedThroughBlock = 0; var archivedPacks = 0; archives = Map.empty<Nat, { cid : Nat64; archive : Principal; hi : Nat }>() };
      shard = ShardCore.newState();
      settlement = SettlementCore.newState(arena);
      payments = PaymentsCore.newState(arena);
      fspiop = FspiopCore.newState(arena);
      var refusedCount = 0;
      var executedCount = 0;
    }
  };

  // ═══════════════════════════════════════════════════════
  //  PREDICATES AND LOOKUPS
  // ═══════════════════════════════════════════════════════

  public func isAdmin(s : State, p : Principal) : Bool { Principal.equal(s.admin, p) };
  public func height(s : State) : Nat { s.height };

  public func getBook(s : State, id : T.BookId) : ?T.Book {
    switch (Map.get(s.books, Text.compare, id)) {
      case (?b) ?{ id = b.id; name = b.name; parent = b.parent; status = b.status; openedAtBlock = b.openedAtBlock; closedAtBlock = b.closedAtBlock };
      case null null;
    }
  };

  public func getRole(s : State, id : T.RoleId) : ?T.Role {
    switch (Map.get(s.roles, Text.compare, id)) {
      case (?r) ?{ id = r.id; name = r.name; permissions = r.permissions; definedAtBlock = r.definedAtBlock };
      case null null;
    }
  };

  public func holdsRole(s : State, subject : Principal, role : T.RoleId) : Bool {
    Map.containsKey(s.grants, cmpPR, (subject, role))
  };

  /// How many principals hold a role. A policy requiring more approvals than
  /// this can never be satisfied, which is why `validatePolicy` is given it.
  public func roleHolderCount(s : State, role : T.RoleId) : Nat {
    var n = 0;
    for (((_, r), _) in Map.entries(s.grants)) { if (Text.equal(r, role)) n += 1 };
    n
  };

  /// The subject's grants, resolved to their roles' permissions, in a
  /// deterministic order.
  public func grantsOf(s : State, subject : Principal) : [E.ResolvedGrant] {
    let out = List.empty<E.ResolvedGrant>();
    for (((p, role), g) in Map.entries(s.grants)) {
      if (Principal.equal(p, subject)) {
        let perms = switch (Map.get(s.roles, Text.compare, role)) { case (?r) r.permissions; case null [] };
        List.add(out, { role; permissions = perms; scope = g.scope });
      };
    };
    E.sortGrants(List.toArray(out))
  };

  public func consumedFor(s : State, subject : Principal, currency : Text, day : Nat) : Nat {
    switch (Map.get(s.consumed, cmpPCD, (subject, currency, day))) { case (?n) n; case null 0 }
  };

  /// A money-visible feature is inactive until an activation height at or below
  /// the bank log's own height is recorded. The default is no entry at all,
  /// which reads as `ACTIVATION_OFF`.
  public func featureActivation(s : State, feature : T.FeatureId) : Nat64 {
    switch (Map.get(s.features, Text.compare, feature)) { case (?h) h; case null T.ACTIVATION_OFF }
  };

  public func featureActive(s : State, feature : T.FeatureId) : Bool {
    featureActivation(s, feature) <= Nat64.fromNat(s.height)
  };

  public func listBooks(s : State) : [T.Book] {
    Array.map<(Text, BookEntry), T.Book>(Map.toArray(s.books), func((_, b)) {
      { id = b.id; name = b.name; parent = b.parent; status = b.status; openedAtBlock = b.openedAtBlock; closedAtBlock = b.closedAtBlock }
    })
  };

  public func listRoles(s : State) : [T.Role] {
    Array.map<(Text, RoleEntry), T.Role>(Map.toArray(s.roles), func((_, r)) {
      { id = r.id; name = r.name; permissions = r.permissions; definedAtBlock = r.definedAtBlock }
    })
  };

  public func listGrants(s : State) : [T.GrantView] {
    Array.map<((Principal, Text), GrantEntry), T.GrantView>(Map.toArray(s.grants), func((_, g)) {
      let perms = switch (Map.get(s.roles, Text.compare, g.role)) { case (?r) r.permissions; case null [] };
      { subject = g.subject; role = g.role; scope = g.scope; permissions = perms }
    })
  };

  public func listPolicies(s : State) : [T.DualPolicy] {
    Array.map<(Text, T.DualPolicy), T.DualPolicy>(Map.toArray(s.policies), func((_, p)) { p })
  };

  public func listFeatures(s : State) : [(T.FeatureId, Nat64)] { Map.toArray(s.features) };

  public func listConsumed(s : State) : [T.ConsumedView] {
    Array.map<((Principal, Text, Nat), Nat), T.ConsumedView>(Map.toArray(s.consumed), func(((p, c, d), n)) {
      { subject = p; currency = c; day = d; amount = n }
    })
  };

  // ─── the bank's own log, read back ────────────────────────────────────────
  //
  // A proposal and an override are their blocks; the state keeps a row per one saying what happened
  // to it. Rebuilding an entry therefore reads blocks, and every function that needs an entry takes
  // the reader — the same shape as the journal's `JCore.Blocks`. `Bank.mo` hands in its `BankLog`;
  // the tests hand in their in-heap chain; `replay` hands in the array it is folding.

  public type Blocks = { get : Nat -> ?T.Block };

  /// The party and product events of the log, for the sub-states that rebuild their records from
  /// their blocks. A closure over the bank's reader; the sub-state never sees a bank block.
  public func partyBlocks(bb : Blocks) : PartyCore.Blocks {
    { get = func(i : Nat) : ?PT.PartyEvent { switch (bb.get(i)) { case (?b) { switch (b.event) { case (#party(pe)) ?pe; case (_) null } }; case null null } } }
  };

  public func productBlocks(bb : Blocks) : ProductCore.Blocks {
    { get = func(i : Nat) : ?ProdT.ProductEvent { switch (bb.get(i)) { case (?b) { switch (b.event) { case (#product(pe)) ?pe; case (_) null } }; case null null } } }
  };

  func rowKey(index : Nat) : Blob { RI.key([RI.beBytes(index, 8)], 8) };
  func rowIndex(key : Blob) : Nat { var v = 0; for (b in key.vals()) { v := v * 256 + Nat8.toNat(b) }; v };

  public func proposalRow(s : State, index : Nat) : ?MC.ProposalRow {
    switch (RI.get(s.proposalRows, rowKey(index))) { case (?v) ?MC.decodeProposalRow(v); case null null }
  };

  public func overrideRow(s : State, index : Nat) : ?MC.OverrideRow {
    switch (RI.get(s.overrideRows, rowKey(index))) { case (?v) ?MC.decodeOverrideRow(v); case null null }
  };

  func blockAt(bb : Blocks, index : Nat, what : Text) : T.Block {
    let ?b = bb.get(index) else Runtime.trap("BankCore: the log has no block " # Nat.toText(index) # " for " # what);
    b
  };

  /// The last bank block whose timestamp is at most `ts` — a binary search over the log, whose timestamps
  /// never decrease — for the bank range a pack takes (§18.3). 0 when no block is that old.
  public func lastBankBlockStamped(s : State, bb : Blocks, ts : Nat64) : Nat {
    if (s.height == 0) return 0;
    var lo = 0;
    var hi = s.height - 1;
    // the answer is the greatest i with blockAt(i).timestamp <= ts, or 0
    if (blockAt(bb, lo, "the first block").timestamp > ts) return 0;
    while (lo < hi) {
      let mid = (lo + hi + 1) / 2;
      if (blockAt(bb, mid, "a block of the range").timestamp <= ts) lo := mid else hi := mid - 1;
    };
    lo
  };

  /// The bytes a pack keeps of bank block `index` whose stored bytes are `raw` (§18.2, §18.3): the same,
  /// or — for an executed proposal whose reconstruction from its act hashes to the kept hash — the preimage
  /// and hash with the empty trailer. A proposal still awaiting, rejected or expired keeps its body; so does
  /// one whose family is not reconstructed, or whose reconstruction does not hash right.
  public func keptBytes(s : State, bb : Blocks, index : Nat, raw : Blob) : Blob {
    let ?row = proposalRow(s, index) else return raw;
    let #executed(_) = row.status else return raw;
    let ?b = C.decodeBlock(raw) else return raw;
    let #commandProposed(x) = b.event else return raw;
    if (x.command == null) return raw;
    switch (reconstruction(bb, row, x.commandHash, x.commandEncoding)) {
      case (?(_, true)) {
        let ?parts = C.splitTrailer(raw) else return raw;
        Blob.fromArray(Array.concat<Nat8>(Blob.toArray(parts.head), [0]))
      };
      case (_) raw;
    }
  };

  /// A proposal, from its row and its blocks. `null` when no proposal was ever made at that index.
  public func proposalEntry(s : State, bb : Blocks, index : Nat) : ?MC.Entry {
    let ?row = proposalRow(s, index) else return null;
    let proposed = blockAt(bb, index, "a proposal");
    let #commandProposed(x) = proposed.event else Runtime.trap("BankCore: block " # Nat.toText(index) # " has a proposal row but is not a proposal");
    let approvals = Array.map<Nat, Principal>(row.approvalBlocks, func(i) {
      let #commandApproved(a) = blockAt(bb, i, "an approval").event else Runtime.trap("BankCore: block " # Nat.toText(i) # " is named as an approval but is not one");
      a.checker
    });
    let status : MC.Status = switch (row.status) {
      case (#awaiting) #awaiting;
      case (#executed(at)) {
        let #commandExecuted(e) = blockAt(bb, at, "an execution").event else Runtime.trap("BankCore: block " # Nat.toText(at) # " is named as an execution but is not one");
        #executed({ at; postings = e.postings })
      };
      case (#rejected(at)) {
        let #commandRejected(r) = blockAt(bb, at, "a rejection").event else Runtime.trap("BankCore: block " # Nat.toText(at) # " is named as a rejection but is not one");
        #rejected({ by = r.checker; reason = r.reason })
      };
      case (#expired(_)) #expired;
    };
    // the body: the block's trailer while it carries one; once a pack dropped it, the reconstruction
    // from the act's events when one hashes to the kept hash (§18.2), else nothing
    let command : ?T.Command = switch (x.command) {
      case (?c) ?c;
      case null { switch (reconstruction(bb, row, x.commandHash, x.commandEncoding)) { case (?(c, true)) ?c; case (_) null } };
    };
    ?{
      index; command; commandHash = x.commandHash; commandEncoding = x.commandEncoding; permission = x.permission; book = x.book;
      maker = x.maker; required = x.required; eligibleRole = x.eligibleRole; expiresAt = x.expiresAt;
      justification = x.justification; approvals; status;
    }
  };

  /// The act's events of an executed proposal: the blocks between its last approval and its execution
  /// (the first event and the extras the plan committed, in order).
  func actEvents(bb : Blocks, row : MC.ProposalRow) : ?[T.Event] {
    let #executed(at) = row.status else return null;
    if (row.approvalBlocks.size() == 0) return null;
    let from = row.approvalBlocks[row.approvalBlocks.size() - 1] + 1;
    if (from >= at) return ?[];
    ?Array.tabulate<T.Event>(at - from, func(i) { blockAt(bb, from + i, "an event of the act").event })
  };

  /// A settled proposal's command rebuilt from its act (`Reconstruct`), with whether the rebuilt command
  /// hashes to the hash the proposal block keeps — the rule under which a pack may drop the body. `null`
  /// when the proposal was not executed or its family is not reconstructed; `(c, false)` when the best
  /// candidate does not hash right (so the body must be kept).
  /// The candidates are re-hashed under the encoding the proposal block recorded — never under the current
  /// one — so a body dropped under version 1 is recovered for as long as version 1's encoder is kept.
  public func reconstruction(bb : Blocks, row : MC.ProposalRow, commandHash : Blob, encoding : Nat8) : ?(T.Command, Bool) {
    let ?events = actEvents(bb, row) else return null;
    let cands = Reconstruct.candidates(events);
    if (cands.size() == 0) return null;
    for (c in cands.vals()) { if (C.commandHashAt(encoding, c) == ?commandHash) return ?(c, true) };
    ?(cands[0], false)
  };

  /// The reconstruction of proposal `index`, for the harness: the command the act's events rebuild and
  /// whether it hashes to the proposal's hash.
  public func reconstructProposal(s : State, bb : Blocks, index : Nat) : ?{ command : ?T.Command; matches : Bool; family : Text } {
    let ?row = proposalRow(s, index) else return null;
    let proposed = blockAt(bb, index, "a proposal");
    let #commandProposed(x) = proposed.event else return null;
    switch (reconstruction(bb, row, x.commandHash, x.commandEncoding)) {
      case (?(c, ok)) ?{ command = ?c; matches = ok; family = P.commandName(c) };
      case null ?{ command = null; matches = false; family = "" };
    }
  };

  /// An override, from its row and its blocks.
  public func overrideEntry(s : State, bb : Blocks, index : Nat) : ?MC.OverrideEntry {
    let ?row = overrideRow(s, index) else return null;
    let #emergencyOverride(x) = blockAt(bb, index, "an override").event else Runtime.trap("BankCore: block " # Nat.toText(index) # " has an override row but is not an override");
    let postings = if (row.executedAt == 0) [] else {
      let #commandExecuted(e) = blockAt(bb, row.executedAt, "an override's execution").event else Runtime.trap("BankCore: block " # Nat.toText(row.executedAt) # " is named as an execution but is not one");
      e.postings
    };
    let (reviewedBy, disposition) : (?Principal, ?Text) = if (row.reviewedAt == 0) (null, null) else {
      let #overrideReviewed(r) = blockAt(bb, row.reviewedAt, "an override's review").event else Runtime.trap("BankCore: block " # Nat.toText(row.reviewedAt) # " is named as a review but is not one");
      (?r.reviewer, ?r.disposition)
    };
    ?{ index; command = x.command; commandHash = x.commandHash; commandEncoding = x.commandEncoding; actor_ = x.actor_; witness = x.witness; justification = x.justification; postings; reviewedBy; disposition }
  };

  /// Every row key in `idx` from `cursor` on, in key order, in pages of `MAX_PAGE`. The whole range
  /// is one descent plus sequential leaves per page.
  func rowIndices(idx : RI.State, cursor : ?Nat, limit : Nat) : { indices : [Nat]; next : ?Nat } {
    let (lo, hi) = RI.rangeEnds([], 8);
    let start = switch (cursor) { case (?c) ?rowKey(c); case null null };
    let page = RI.range(idx, lo, hi, start, limit);
    { indices = Array.map<(Blob, Blob), Nat>(page.entries, func((k, _)) { rowIndex(k) }); next = switch (page.cursor) { case (?k) ?rowIndex(k); case null null } }
  };

  func entryAt(s : State, bb : Blocks, i : Nat) : MC.Entry {
    let ?e = proposalEntry(s, bb, i) else Runtime.trap("BankCore: a proposal row without a proposal at " # Nat.toText(i));
    e
  };

  public func getProposal(s : State, bb : Blocks, index : Nat) : ?T.ProposalView {
    switch (proposalEntry(s, bb, index)) { case (?e) ?MC.view(e); case null null }
  };

  /// Every proposal — bounded by the caller's judgement, not by the function; `listProposalsPaged`
  /// is the read that scales.
  public func listProposals(s : State, bb : Blocks) : [T.ProposalView] {
    let out = List.empty<T.ProposalView>();
    var cursor : ?Nat = null;
    label walk loop {
      let pg = rowIndices(s.proposalRows, cursor, MAX_PAGE);
      for (i in pg.indices.vals()) List.add(out, MC.view(entryAt(s, bb, i)));
      switch (pg.next) { case null break walk; case (?n) cursor := ?n };
    };
    List.toArray(out)
  };

  public func auditTrail(s : State, bb : Blocks) : [T.AuditRow] {
    let out = List.empty<T.AuditRow>();
    var cursor : ?Nat = null;
    label walk loop {
      let pg = rowIndices(s.proposalRows, cursor, MAX_PAGE);
      for (i in pg.indices.vals()) List.add(out, MC.auditRow(entryAt(s, bb, i)));
      switch (pg.next) { case null break walk; case (?n) cursor := ?n };
    };
    List.toArray(out)
  };

  // ─── paged reads ──────────────────────────────────────────────────────────
  //
  // Proposals grow by one for every dual-authorised command the bank ever runs, and the audit trail is
  // one row each, so both are unbounded in the bank's lifetime. Overrides grow more slowly and by the
  // same mechanism. Each has a cursor-paged form; the cursor is the proposal index, which is the map's
  // key, so a page is a seek plus the page.

  public let MAX_PAGE : Nat = 500;

  func pageLimit(limit : Nat) : Nat { if (limit == 0 or limit > MAX_PAGE) MAX_PAGE else limit };

  public type ProposalPage = { rows : [T.ProposalView]; cursor : ?Nat; total : Nat };

  public func listProposalsPaged(s : State, bb : Blocks, cursor : ?Nat, limit : Nat) : ProposalPage {
    let pg = rowIndices(s.proposalRows, cursor, pageLimit(limit));
    { rows = Array.map<Nat, T.ProposalView>(pg.indices, func(i) { MC.view(entryAt(s, bb, i)) }); cursor = pg.next; total = RI.size(s.proposalRows) }
  };

  public type AuditPage = { rows : [T.AuditRow]; cursor : ?Nat; total : Nat };

  public func auditTrailPaged(s : State, bb : Blocks, cursor : ?Nat, limit : Nat) : AuditPage {
    let pg = rowIndices(s.proposalRows, cursor, pageLimit(limit));
    { rows = Array.map<Nat, T.AuditRow>(pg.indices, func(i) { MC.auditRow(entryAt(s, bb, i)) }); cursor = pg.next; total = RI.size(s.proposalRows) }
  };

  public type OverrideView = { index : Nat; command : T.Command; actor_ : Principal; witness : Principal; justification : Text; reviewedBy : ?Principal; disposition : ?Text };
  public type OverridePage = { rows : [OverrideView]; cursor : ?Nat; total : Nat };

  func overrideView(o : MC.OverrideEntry) : OverrideView {
    { index = o.index; command = o.command; actor_ = o.actor_; witness = o.witness; justification = o.justification; reviewedBy = o.reviewedBy; disposition = o.disposition }
  };

  func overrideAt(s : State, bb : Blocks, i : Nat) : MC.OverrideEntry {
    let ?o = overrideEntry(s, bb, i) else Runtime.trap("BankCore: an override row without an override at " # Nat.toText(i));
    o
  };

  public func listOverridesPaged(s : State, bb : Blocks, cursor : ?Nat, limit : Nat) : OverridePage {
    let pg = rowIndices(s.overrideRows, cursor, pageLimit(limit));
    { rows = Array.map<Nat, OverrideView>(pg.indices, func(i) { overrideView(overrideAt(s, bb, i)) }); cursor = pg.next; total = RI.size(s.overrideRows) }
  };

  public type ConsumedPage = { rows : [T.ConsumedView]; cursor : ?(Principal, Text, Nat); total : Nat };

  public func listConsumedPaged(s : State, cursor : ?(Principal, Text, Nat), limit : Nat) : ConsumedPage {
    let n = pageLimit(limit);
    let rows = List.empty<T.ConsumedView>();
    var next : ?(Principal, Text, Nat) = null;
    let it = switch (cursor) {
      case (?c) Map.entriesFrom(s.consumed, cmpPCD, c);
      case null Map.entries(s.consumed);
    };
    label walk for (((subject, currency, day), amount) in it) {
      if (List.size(rows) == n) { next := ?(subject, currency, day); break walk };
      List.add(rows, { subject; currency; day; amount });
    };
    { rows = List.toArray(rows); cursor = next; total = Map.size(s.consumed) }
  };

  public func openOverrideCount(s : State) : Nat { Map.size(s.openOverrides) };
  public func proposalCount(s : State) : Nat { RI.size(s.proposalRows) };
  public func overrideCount(s : State) : Nat { RI.size(s.overrideRows) };
  public func openProposalCount(s : State) : Nat { Map.size(s.openProposals) };
  public func refusedCount(s : State) : Nat { s.refusedCount };
  public func executedCount(s : State) : Nat { s.executedCount };

  public func listOverrides(s : State, bb : Blocks) : [OverrideView] {
    let out = List.empty<OverrideView>();
    var cursor : ?Nat = null;
    label walk loop {
      let pg = rowIndices(s.overrideRows, cursor, MAX_PAGE);
      for (i in pg.indices.vals()) List.add(out, overrideView(overrideAt(s, bb, i)));
      switch (pg.next) { case null break walk; case (?n) cursor := ?n };
    };
    List.toArray(out)
  };

  // ═══════════════════════════════════════════════════════
  //  READ SCOPING
  // ═══════════════════════════════════════════════════════

  /// The books a subject may read, or `null` for unrestricted. The union of the
  /// subject's grants: a grant with no book dimension makes the subject
  /// unrestricted, which is the same union semantics authorisation uses.
  /// A subject with no grant at all reads nothing, which is `?[]`.
  public func readableBooks(s : State, subject : Principal) : ?[T.BookId] {
    let gs = grantsOf(s, subject);
    if (gs.size() == 0) return ?[];
    let out = List.empty<T.BookId>();
    for (g in gs.vals()) {
      switch (g.scope.books) {
        case null return null;                      // unrestricted
        case (?books) {
          for (b in books.vals()) {
            var seen = false;
            for (x in List.values(out)) { if (Text.equal(x, b)) seen := true };
            if (not seen) List.add(out, b);
          };
        };
      };
    };
    ?List.toArray(out)
  };

  public func mayReadBook(scope : ?[T.BookId], book : T.BookId) : Bool {
    switch (scope) {
      case null true;
      case (?books) {
        for (b in books.vals()) { if (Text.equal(b, book)) return true };
        false
      };
    }
  };

  /// A row with no book dimension is readable by anyone the bank has onboarded:
  /// there is no office it belongs to. A row with a book is readable only inside
  /// that book's scope.
  public func mayReadOptBook(scope : ?[T.BookId], book : ?T.BookId) : Bool {
    switch (book) { case null true; case (?b) mayReadBook(scope, b) }
  };

  // ═══════════════════════════════════════════════════════
  //  THE OPERATION, READ OUT OF THE COMMAND
  // ═══════════════════════════════════════════════════════

  /// The permission a command requires.
  public func commandPermission(c : T.Command) : T.PermissionId {
    switch (P.forCommand(c)) {
      case (?p) p.id;
      // Unreachable: `Permissions.commandName` is exhaustive over `Command` and
      // the catalogue has an entry for every name, which
      // `tools/permission_audit.py` and test/Permissions.test.mo both assert.
      case null Runtime.trap("BankCore: no permission for command " # P.commandName(c));
    }
  };

  public func commandPermissionRecord(c : T.Command) : T.Permission {
    switch (P.forCommand(c)) {
      case (?p) p;
      case null Runtime.trap("BankCore: no permission for command " # P.commandName(c));
    }
  };

  /// Per-currency totals of the money a command moves. For a reversal the legs
  /// are the original posting's, read from the journal rather than supplied, so a
  /// caller cannot understate the amount to slip under a ceiling.
  public func commandTotals(bs : State, js : JCore.State, jb : JCore.Blocks, c : T.Command) : [(JT.Currency, Nat)] {
    switch (c) {
      case (#postManualEntry(x)) E.legTotals(x.legs);
      case (#postManualEntryForParty(x)) E.legTotals(x.entry.legs);
      case (#reverseManualEntry(x)) {
        switch (JCore.postingView(js, jb, x.original)) {
          case (?v) E.legTotals(v.record.legs);
          case null [];
        }
      };
      // A product movement's currency is the account's own, read from state rather
      // than taken from the caller, which is the same rule as everywhere else.
      case (#depositToAccount(m)) accountTotals(bs, m.account, m.amount);
      case (#openShardTransfer(x)) accountTotals(bs, x.from, x.amount);
      case (#recordFunds(x)) [(x.currency, x.amount)];
      case (#withdrawFromAccount(m)) accountTotals(bs, m.account, m.amount);
      case (#disburseLoan(m)) accountTotals(bs, m.account, m.amount);
      case (#repayLoan(m)) accountTotals(bs, m.account, m.amount);
      case (#recordRecovery(m)) accountTotals(bs, m.account, m.amount);
      case (#redeemTermDeposit(m)) accountTotals(bs, m.account, m.amount);
      case (#transferBetweenAccounts(x)) accountTotals(bs, x.from, x.amount);
      case (#allocateCashToTill(x)) tillTotals(bs, x.till, x.amount);
      case (#returnCashFromTill(x)) tillTotals(bs, x.till, x.amount);
      case (#settleTill(x)) tillTotals(bs, x.till, x.declared);
      case (#grantFacility(x)) accountTotals(bs, x.account, x.limit);
      // A cross-currency deal consumes the amount it sells, in the currency it sells.
      case (#bookFxDeal(x)) [(x.sell, x.sellAmount)];
      case (#realiseFxPosition(x)) [(x.currency, x.closedPosition)];
      // A credit decision and the drawing it leads to are bounded by the underwriter's ceiling in the
      // application's currency, read from the row rather than the request.
      case (#underwrite(x)) {
        switch (x.decision, OriginationCore.row(bs.origination, x.application)) { case (#approve(a), ?r) [(r.currency, a.amount)]; case (_, _) [] }
      };
      case (#issueOffer(x)) [(x.terms.currency, x.terms.amount)];
      case (#fulfilApplication(x)) {
        switch (OriginationCore.row(bs.origination, x.application)) { case (?r) { switch (r.decision) { case (?#approve(a)) [(r.currency, a.amount)]; case (_) [] } }; case null [] }
      };
      case (#drawdown(x)) facilityTotals(bs, x.facility, x.amount);
      case (#receiveRental(x)) facilityTotals(bs, x.facility, x.amount);
      case (#purchaseReceivables(x)) { var face = 0; for (r in x.receivables.vals()) face += r.face; facilityTotals(bs, x.facility, face) };
      case (#collectReceivable(x)) { switch (FacilityCore.receivable(bs.facility, x.facility, x.ref)) { case (?r) facilityTotals(bs, x.facility, r.face); case null [] } };
      case (#dishonourReceivable(x)) { switch (FacilityCore.receivable(bs.facility, x.facility, x.ref)) { case (?r) facilityTotals(bs, x.facility, r.face); case null [] } };
      case (#writeOffReceivable(x)) { switch (FacilityCore.receivable(bs.facility, x.facility, x.ref)) { case (?r) facilityTotals(bs, x.facility, r.face); case null [] } };
      // the teller's money acts, in the till's, the account's or the movement's currency
      // trade finance (trade finance): the instrument's currency, the face or the claim
      case (#issueLetterOfCredit(x)) [(x.currency, x.amount)];
      case (#issueGuarantee(x)) [(x.currency, x.amount)];
      case (#registerCollection(x)) [(x.currency, x.amount)];
      case (#discountBill(x)) [(x.currency, x.face)];
      case (#amendLetterOfCredit(x) or #amendGuarantee(x)) { switch (TradeCore.row(bs.trade, x.instrument), x.amendment.amount) { case (?r, ?a) [(r.currency, if (a > r.amount) a - r.amount else r.amount - a)]; case (?r, null) [(r.currency, 0)]; case (_, _) [] } };
      case (#honourPresentation(x) or #settleAcceptance(x) or #payDemand(x)) { switch (TradeCore.row(bs.trade, x.instrument), TradeCore.claim(bs.trade, x.instrument, x.claim)) { case (?r, ?c) [(r.currency, c.amount)]; case (_, _) [] } };
      case (#closeLetterOfCredit(x) or #releaseGuarantee(x)) { switch (TradeCore.row(bs.trade, x.instrument)) { case (?r) [(r.currency, TradeCore.outstanding(r))]; case null [] } };
      case (#reduceGuarantee(x)) { switch (TradeCore.row(bs.trade, x.instrument)) { case (?r) [(r.currency, if (r.amount > x.to) r.amount - x.to else 0)]; case null [] } };
      case (#payCollection(x) or #returnCollection(x) or #rediscountBill(x) or #settleBill(x) or #dishonourBill(x)) { switch (TradeCore.row(bs.trade, x.instrument)) { case (?r) [(r.currency, r.amount)]; case null [] } };
      // Islamic banking (Islamic banking): the contract's currency
      case (#openShariaContract(x)) { switch (x.kind) { case (#murabaha(m)) [(x.currency, m.costPrice + m.markup)]; case (#ijarah(i)) [(x.currency, i.cost)]; case (#musharakah(m)) [(x.currency, m.bankCapital)]; case (#mudarabah(m)) [(x.currency, m.capital)]; case (#salam(s)) [(x.currency, s.priceAdvanced)]; case (#istisna(s)) [(x.currency, s.price)] } };
      case (#acquireMurabahaAsset(x) or #sellMurabaha(x) or #commenceIjarah(x) or #contributeCapital(x) or #deliverSalam(x) or #recordSalamFailure(x) or #settleShariaContract(x) or #transferIjarahOwnership(x) or #collectIstisnaBilling(x)) { switch (IslamicCore.row(bs.islamic, x.contract)) { case (?r) [(r.currency, r.principal)]; case null [] } };
      case (#collectInstalment(x) or #collectRental(x)) { switch (IslamicCore.row(bs.islamic, x.contract)) { case (?r) { switch (IslamicCore.instalment(bs.islamic, x.contract, r.instalmentsPaid + 1)) { case (?i) [(r.currency, i.amount)]; case null [] } }; case null [] } };
      case (#grantRebate(x)) { switch (IslamicCore.row(bs.islamic, x.contract)) { case (?r) [(r.currency, x.amount)]; case null [] } };
      case (#distributeMusharakahProfit(x)) { switch (IslamicCore.row(bs.islamic, x.contract)) { case (?r) [(r.currency, x.profit)]; case null [] } };
      case (#allocateMusharakahLoss(x)) { switch (IslamicCore.row(bs.islamic, x.contract)) { case (?r) [(r.currency, x.loss)]; case null [] } };
      case (#buyMusharakahUnit(x)) { switch (IslamicCore.row(bs.islamic, x.contract)) { case (?r) [(r.currency, x.units * r.unitPrice)]; case null [] } };
      case (#recordMudarabahResult(x)) { switch (IslamicCore.row(bs.islamic, x.contract)) { case (?r) [(r.currency, x.profit + x.loss)]; case null [] } };
      case (#sellSalamCommodity(x)) { switch (IslamicCore.row(bs.islamic, x.contract)) { case (?r) [(r.currency, x.proceeds)]; case null [] } };
      case (#recordIstisnaMilestone(x)) { switch (IslamicCore.row(bs.islamic, x.contract)) { case (?r) [(r.currency, r.principal * x.percentBps / 10_000)]; case null [] } };
      case (#recordNonCompliance(x)) { switch (x.contract) { case (?id) { switch (IslamicCore.row(bs.islamic, id)) { case (?r) [(r.currency, x.amount)]; case null [] } }; case null [] } };
      case (#distributePool(x)) { switch (IslamicCore.pool(bs.islamic, x.pool)) { case (?p) [(p.currency, 0)]; case null [] } };
      case (#cashDeposit(x)) tillTotals(bs, x.till, x.amount);
      case (#cashWithdrawal(x)) tillTotals(bs, x.till, x.amount);
      case (#vaultToTill(x)) tillTotals(bs, x.till, x.amount);
      case (#tillToVault(x)) tillTotals(bs, x.till, x.amount);
      case (#dispatchCash(x)) [(x.currency, x.amount)];
      case (#receiveCash(x)) { switch (TellerCore.movement(bs.teller, x.movement)) { case (?m) [(m.currency, m.amount)]; case null [] } };
      case (#vaultToCentralBank(x)) [(x.currency, x.amount)];
      case (#centralBankToVault(x)) [(x.currency, x.amount)];
      case (#presentCheque(x)) accountTotals(bs, x.account, x.amount);
      case (#clearCheque(x)) { switch (TellerCore.cheque(bs.teller, x.account, x.serial)) { case (?c) accountTotals(bs, x.account, c.amount); case null [] } };
      case (#issueDraft(x)) [(x.currency, x.amount)];
      case (#payDraft(x)) { switch (TellerCore.draft(bs.teller, x.serial)) { case (?d) [(d.currency, d.amount)]; case null [] } };
      case (#cancelDraft(x)) { switch (TellerCore.draft(bs.teller, x.serial)) { case (?d) [(d.currency, d.amount)]; case null [] } };
      case (#resolveTillDifference(x)) { switch (TellerCore.session(bs.teller, x.session)) { case (?r) tillTotals(bs, r.till, TellerCore.diffAmount(r.difference)); case null [] } };
      case (_) [];
    }
  };

  func facilityTotals(bs : State, id : FaT.FacilityId, amount : Nat) : [(JT.Currency, Nat)] {
    switch (FacilityCore.row(bs.facility, id)) { case (?r) [(r.currency, amount)]; case null [] }
  };

  func accountTotals(bs : State, id : ProdT.AccountId, amount : Nat) : [(JT.Currency, Nat)] {
    switch (ProductCore.currencyOf(bs.product, id)) { case (?c) [(c, amount)]; case null [] }
  };

  func tillTotals(bs : State, id : ProdT.TillId, amount : Nat) : [(JT.Currency, Nat)] {
    switch (ProductCore.tillCurrencyOf(bs.product, id)) { case (?c) [(c, amount)]; case null [] }
  };

  /// The business day a command's limit consumption is attributed to.
  public func commandDay(c : T.Command) : ?Nat {
    switch (c) {
      case (#postManualEntry(x)) ?x.postingDate;
      case (#postManualEntryForParty(x)) ?x.entry.postingDate;
      case (#reverseManualEntry(x)) ?x.postingDate;
      case (#depositToAccount(m)) ?m.postingDate;
      case (#openShardTransfer(x)) ?x.postingDate;
      case (#recordFunds(x)) ?x.postingDate;
      case (#withdrawFromAccount(m)) ?m.postingDate;
      case (#disburseLoan(m)) ?m.postingDate;
      case (#repayLoan(m)) ?m.postingDate;
      case (#recordRecovery(m)) ?m.postingDate;
      case (#redeemTermDeposit(m)) ?m.postingDate;
      case (#transferBetweenAccounts(x)) ?x.postingDate;
      case (#drawdown(x)) ?x.postingDate;
      case (#receiveRental(x)) ?x.postingDate;
      case (#purchaseReceivables(x)) ?x.postingDate;
      case (#collectReceivable(x)) ?x.postingDate;
      case (#cashDeposit(x)) ?x.postingDate;
      case (#cashWithdrawal(x)) ?x.postingDate;
      case (#vaultToTill(x)) ?x.postingDate;
      case (#tillToVault(x)) ?x.postingDate;
      case (#dispatchCash(x)) ?x.postingDate;
      case (#receiveCash(x)) ?x.postingDate;
      case (#presentCheque(x)) ?x.postingDate;
      case (#issueDraft(x)) ?x.postingDate;
      case (#payDraft(x)) ?x.postingDate;
      case (#issueLetterOfCredit(x)) ?x.postingDate; case (#adviseLetterOfCredit(x)) ?x.postingDate; case (#amendLetterOfCredit(x)) ?x.postingDate;
      case (#honourPresentation(x)) ?x.postingDate; case (#settleAcceptance(x)) ?x.postingDate; case (#closeLetterOfCredit(x)) ?x.postingDate;
      case (#issueGuarantee(x)) ?x.postingDate; case (#amendGuarantee(x)) ?x.postingDate; case (#payDemand(x)) ?x.postingDate; case (#reduceGuarantee(x)) ?x.postingDate;
      case (#releaseGuarantee(x)) ?x.postingDate; case (#registerCollection(x)) ?x.postingDate; case (#payCollection(x)) ?x.postingDate; case (#returnCollection(x)) ?x.postingDate;
      case (#discountBill(x)) ?x.postingDate; case (#rediscountBill(x)) ?x.postingDate; case (#settleBill(x)) ?x.postingDate; case (#dishonourBill(x)) ?x.postingDate;
      case (#openShariaContract(x)) ?x.postingDate; case (#acquireMurabahaAsset(x)) ?x.postingDate; case (#sellMurabaha(x)) ?x.postingDate; case (#collectInstalment(x)) ?x.postingDate;
      case (#grantRebate(x)) ?x.postingDate; case (#commenceIjarah(x)) ?x.postingDate; case (#collectRental(x)) ?x.postingDate; case (#transferIjarahOwnership(x)) ?x.postingDate;
      case (#contributeCapital(x)) ?x.postingDate; case (#distributeMusharakahProfit(x)) ?x.postingDate; case (#allocateMusharakahLoss(x)) ?x.postingDate; case (#buyMusharakahUnit(x)) ?x.postingDate;
      case (#recordMudarabahResult(x)) ?x.postingDate; case (#deliverSalam(x)) ?x.postingDate; case (#sellSalamCommodity(x)) ?x.postingDate; case (#recordSalamFailure(x)) ?x.postingDate;
      case (#recordIstisnaMilestone(x)) ?x.postingDate; case (#collectIstisnaBilling(x)) ?x.postingDate; case (#settleShariaContract(x)) ?x.postingDate; case (#recordNonCompliance(x)) ?x.postingDate; case (#distributePool(x)) ?x.postingDate;
      case (#applyCharge(x)) ?x.postingDate;
      case (#waiveCharge(x)) ?x.postingDate;
      case (#postAccrual(x)) ?x.day;
      case (#capitaliseInterest(x)) ?x.postingDate;
      case (#setProvision(x)) ?x.postingDate;
      case (#writeOffLoan(x)) ?x.postingDate;
      case (#allocateCashToTill(x)) ?x.postingDate;
      case (#returnCashFromTill(x)) ?x.postingDate;
      case (#settleTill(x)) ?x.postingDate;
      case (#bookFxDeal(x)) ?x.postingDate;
      case (#realiseFxPosition(x)) ?x.postingDate;
      case (#adjustAccrual(x)) ?x.postingDate;
      case (#amortiseDeferral(x)) ?x.postingDate;
      case (#revaluePositions(x)) ?x.postingDate;
      case (#openEndOfDay(x)) ?x.businessDate;
      case (#amortisePeriodDeferrals(x)) ?x.postingDate;
      case (_) null;
    }
  };

  /// The book an operation acts in. Party commands name a party rather than a
  /// book, so the book is read out of the party record — which is the same rule
  /// as everywhere else: the scope is evaluated against the operation's own data,
  /// not against what the caller says.
  public func commandBookOf(bs : State, c : T.Command) : ?T.BookId {
    switch (c) {
      case (#createParty(x)) ?x.book;
      case (#createCustomer(c)) ?c.party.book;
      case (#amendParty(x)) PartyCore.bookOf(bs.party, x.party);
      case (#setPartyLifecycle(x)) PartyCore.bookOf(bs.party, x.party);
      case (#setPartyCdd(x)) PartyCore.bookOf(bs.party, x.party);
      case (#addPartyDocument(x)) PartyCore.bookOf(bs.party, x.party);
      case (#addPartyRelationship(x)) PartyCore.bookOf(bs.party, x.party);
      case (#setPartyExtension(x)) PartyCore.bookOf(bs.party, x.party);
      case (#issueIdentifier(x)) PartyCore.bookOf(bs.party, x.party);
      case (#proveScreeningClear(x)) PartyCore.bookOf(bs.party, x.party);
      case (#recordScreeningDecision(d)) PartyCore.bookOf(bs.party, d.party);
      case (#registerCollateral(x)) PartyCore.bookOf(bs.party, x.party);
      case (#revalueCollateral(x)) {
        switch (PartyCore.collateralPartyOf(bs.party, x.collateral)) { case (?party) PartyCore.bookOf(bs.party, party); case null null }
      };
      case (#allocateCollateral(x)) {
        switch (PartyCore.collateralPartyOf(bs.party, x.collateral)) { case (?party) PartyCore.bookOf(bs.party, party); case null null }
      };
      case (#releaseCollateral(x)) {
        switch (PartyCore.collateralPartyOf(bs.party, x.collateral)) { case (?party) PartyCore.bookOf(bs.party, party); case null null }
      };
      case (#addStaff(x)) ?x.book;
      case (#removeStaff(x)) { switch (PartyCore.getStaff(bs.party, x.principal_)) { case (?st) ?st.book; case null null } };
      case (#postManualEntryForParty(x)) ?x.entry.book;
      // Product commands name an account or a till, so the book is read out of the
      // record rather than out of the request.
      case (#openAccount(x)) PartyCore.bookOf(bs.party, x.party);
      case (#setAccountStatus(x)) ProductCore.bookOf(bs.product, x.account);
      case (#migrateAccount(x)) ProductCore.bookOf(bs.product, x.account);
      case (#grantFacility(x)) ProductCore.bookOf(bs.product, x.account);
      case (#depositToAccount(m)) ProductCore.bookOf(bs.product, m.account);
      case (#openShardTransfer(x)) ProductCore.bookOf(bs.product, x.from);
      case (#withdrawFromAccount(m)) ProductCore.bookOf(bs.product, m.account);
      case (#disburseLoan(m)) ProductCore.bookOf(bs.product, m.account);
      case (#repayLoan(m)) ProductCore.bookOf(bs.product, m.account);
      case (#recordRecovery(m)) ProductCore.bookOf(bs.product, m.account);
      case (#redeemTermDeposit(m)) ProductCore.bookOf(bs.product, m.account);
      case (#transferBetweenAccounts(x)) ProductCore.bookOf(bs.product, x.from);
      case (#applyCharge(x)) ProductCore.bookOf(bs.product, x.account);
      case (#waiveCharge(x)) ProductCore.bookOf(bs.product, x.account);
      case (#rescheduleLoan(x)) ProductCore.bookOf(bs.product, x.account);
      case (#setProvision(x)) ProductCore.bookOf(bs.product, x.account);
      case (#writeOffLoan(x)) ProductCore.bookOf(bs.product, x.account);
      case (#openTill(x)) ?x.book;
      case (#closeTill(x)) ProductCore.tillBookOf(bs.product, x.till);
      case (#allocateCashToTill(x)) ProductCore.tillBookOf(bs.product, x.till);
      case (#returnCashFromTill(x)) ProductCore.tillBookOf(bs.product, x.till);
      case (#settleTill(x)) ProductCore.tillBookOf(bs.product, x.till);
      // The close is per book, and a deferral schedule names the book it belongs to.
      case (#approveBackValue(x)) ?x.book;
      case (#setBackValueWindow(x)) ?x.window.book;
      case (#openDeferralSchedule(x)) ?x.schedule.book;
      case (#amortiseDeferral(x)) { switch (CloseCore.getSchedule(bs.close, x.schedule)) { case (?e) ?e.schedule.book; case null null } };
      case (#openPeriodEnd(x)) ?x.book;
      case (#recordClosingRates(x)) ?x.book;
      case (#markAccrualComplete(x)) ?x.book;
      case (#revaluePositions(x)) ?x.book;
      case (#amortisePeriodDeferrals(x)) ?x.book;
      case (#reconcilePeriod(x)) ?x.book;
      case (#closePeriodEnd(x)) ?x.book;
      case (#rollYearEnd(x)) ?x.book;
      case (#setRetryPolicy(x)) ?x.policy.book;
      case (#defineStandingInstruction(x)) ?x.instruction.book;
      case (#cancelStandingInstruction(x)) { switch (BatchCore.getInstruction(bs.batch, x.id)) { case (?e) ?e.instruction.book; case null null } };
      case (#openEndOfDay(x)) ?x.book;
      case (#resolveBatchFailure(x)) ?x.book;
      // Origination commands name an application, whose row carries its book; a passkey is the party's.
      case (#openApplication(x)) ?x.book;
      case (#registerPasskey(x)) PartyCore.bookOf(bs.party, x.party);
      case (#recordApplicationData(x)) applicationBook(bs, x.application);
      case (#assessAffordability(x)) applicationBook(bs, x.application);
      case (#requestBureauReport(x)) applicationBook(bs, x.application);
      case (#scoreApplication(x)) applicationBook(bs, x.application);
      case (#underwrite(x)) applicationBook(bs, x.application);
      case (#issueOffer(x)) applicationBook(bs, x.application);
      case (#acceptOffer(x)) applicationBook(bs, x.application);
      case (#declineOffer(x)) applicationBook(bs, x.application);
      case (#recordDocument(x)) applicationBook(bs, x.application);
      case (#recordConditionsMet(x)) applicationBook(bs, x.application);
      case (#fulfilApplication(x)) applicationBook(bs, x.application);
      case (#withdrawApplication(x)) applicationBook(bs, x.application);
      // Facility commands name a facility, whose row carries its book; a fixing is the bank's.
      case (#openFacility(x)) ?x.book;
      case (#drawdown(x)) facilityBook(bs, x.facility);
      case (#transferParticipation(x)) facilityBook(bs, x.facility);
      case (#distributeToParticipants(x)) facilityBook(bs, x.facility);
      case (#restructureFacility(x)) facilityBook(bs, x.facility);
      case (#recordCovenantTest(x)) facilityBook(bs, x.facility);
      case (#blockDrawdowns(x)) facilityBook(bs, x.facility);
      case (#unblockDrawdowns(x)) facilityBook(bs, x.facility);
      case (#recordFacilityReview(x)) facilityBook(bs, x.facility);
      case (#receiveRental(x)) facilityBook(bs, x.facility);
      case (#remeasureResidual(x)) facilityBook(bs, x.facility);
      case (#purchaseReceivables(x)) facilityBook(bs, x.facility);
      case (#collectReceivable(x)) facilityBook(bs, x.facility);
      case (#dishonourReceivable(x)) facilityBook(bs, x.facility);
      case (#writeOffReceivable(x)) facilityBook(bs, x.facility);
      case (#closeFacility(x)) facilityBook(bs, x.facility);
      // Teller commands name a till (the till's book), an account (the account's), a session (its till's) or a book.
      case (#openTellerSession(x)) ProductCore.tillBookOf(bs.product, x.till);
      case (#closeTellerSession(x)) ProductCore.tillBookOf(bs.product, x.till);
      case (#resolveTillDifference(x)) { switch (TellerCore.session(bs.teller, x.session)) { case (?r) ProductCore.tillBookOf(bs.product, r.till); case null null } };
      case (#cashDeposit(x)) ProductCore.tillBookOf(bs.product, x.till);
      case (#cashWithdrawal(x)) ProductCore.tillBookOf(bs.product, x.till);
      case (#vaultToTill(x)) ProductCore.tillBookOf(bs.product, x.till);
      case (#tillToVault(x)) ProductCore.tillBookOf(bs.product, x.till);
      case (#dispatchCash(x)) ?x.fromBook;
      case (#receiveCash(x)) { switch (TellerCore.movement(bs.teller, x.movement)) { case (?m) ?m.toBook; case null null } };
      case (#vaultToCentralBank(x)) ?x.book;
      case (#centralBankToVault(x)) ?x.book;
      case (#issueChequebook(x)) ProductCore.bookOf(bs.product, x.account);
      case (#stopCheque(x)) ProductCore.bookOf(bs.product, x.account);
      case (#presentCheque(x)) ProductCore.bookOf(bs.product, x.account);
      case (#clearCheque(x)) ProductCore.bookOf(bs.product, x.account);
      case (#returnCheque(x)) ProductCore.bookOf(bs.product, x.account);
      case (#issueDraft(x)) { switch (x.source) { case (#till(id)) ProductCore.tillBookOf(bs.product, id); case (#account(id)) ProductCore.bookOf(bs.product, id) } };
      case (#payDraft(x)) { switch (x.to) { case (#till(id)) ProductCore.tillBookOf(bs.product, id); case (#account(id)) ProductCore.bookOf(bs.product, id) } };
      case (#cancelDraft(x)) ProductCore.bookOf(bs.product, x.refundTo);
      // trade commands name an instrument (its book) or open one on a customer's account (the account's book)
      case (#issueLetterOfCredit(x)) { switch (x.lc.applicant) { case (#party(p)) ProductCore.bookOf(bs.product, p.account); case (#external(_)) null } };
      case (#adviseLetterOfCredit(x)) ProductCore.bookOf(bs.product, x.beneficiaryAccount);
      case (#issueGuarantee(x)) ProductCore.bookOf(bs.product, x.guarantee.principalAccount);
      case (#registerCollection(x)) { switch (x.collection.role, x.collection.drawer, x.collection.drawee) { case (#remitting, #party(p), _) ProductCore.bookOf(bs.product, p.account); case (#collecting, _, #party(p)) ProductCore.bookOf(bs.product, p.account); case (_, _, _) null } };
      case (#discountBill(x)) ProductCore.bookOf(bs.product, x.bill.customerAccount);
      case (#amendLetterOfCredit(x) or #amendGuarantee(x) or #closeLetterOfCredit(x) or #releaseGuarantee(x) or #reduceGuarantee(x) or #payCollection(x) or #returnCollection(x) or #rediscountBill(x) or #settleBill(x) or #dishonourBill(x) or #presentCollection(x) or #acceptCollection(x)) tradeBook(bs, x.instrument);
      case (#protestCollection(x)) tradeBook(bs, x.instrument);
      case (#presentDocuments(x)) tradeBook(bs, x.instrument);
      case (#examinePresentation(x) or #examineDemand(x)) tradeBook(bs, x.instrument);
      case (#waiveDiscrepancies(x)) tradeBook(bs, x.instrument);
      case (#honourPresentation(x) or #settleAcceptance(x) or #payDemand(x)) tradeBook(bs, x.instrument);
      case (#recordDemand(x)) tradeBook(bs, x.instrument);
      case (#recordTradeMessage(x)) tradeBook(bs, x.instrument);
      // Islamic commands name a contract (its book), open one on a customer's account (the account's book), or name a book
      case (#openShariaContract(x)) { switch (x.kind) { case (#murabaha(m)) ProductCore.bookOf(bs.product, m.account); case (#ijarah(i)) ProductCore.bookOf(bs.product, i.account); case (#musharakah(m)) ProductCore.bookOf(bs.product, m.partners[0].account); case (#mudarabah(m)) ProductCore.bookOf(bs.product, m.account); case (#salam(s)) ProductCore.bookOf(bs.product, s.account); case (#istisna(s)) ProductCore.bookOf(bs.product, s.account) } };
      case (#flagShariaBook(x)) ?x.book;
      case (#acquireMurabahaAsset(x) or #sellMurabaha(x) or #collectInstalment(x) or #grantRebate(x) or #commenceIjarah(x) or #collectRental(x) or #transferIjarahOwnership(x) or #contributeCapital(x) or #distributeMusharakahProfit(x) or #allocateMusharakahLoss(x) or #buyMusharakahUnit(x) or #recordMudarabahResult(x) or #deliverSalam(x) or #sellSalamCommodity(x) or #recordSalamFailure(x) or #recordIstisnaMilestone(x) or #collectIstisnaBilling(x) or #settleShariaContract(x)) islamicBook(bs, x.contract);
      case (#closeShariaContract(x)) islamicBook(bs, x.contract);
      case (#recordNonCompliance(x)) { switch (x.contract) { case (?id) islamicBook(bs, id); case null null } };
      case (other) E.commandBook(other);
    }
  };

  func tradeBook(bs : State, id : TrT.InstrumentId) : ?T.BookId {
    switch (TradeCore.row(bs.trade, id)) { case (?r) ?r.book; case null null }
  };
  func facilityBook(bs : State, id : FaT.FacilityId) : ?T.BookId {
    switch (FacilityCore.row(bs.facility, id)) { case (?r) ?r.book; case null null }
  };

  func applicationBook(bs : State, id : OT.ApplicationId) : ?T.BookId {
    switch (OriginationCore.row(bs.origination, id)) { case (?r) ?r.book; case null null }
  };

  public func operationOf(bs : State, js : JCore.State, jb : JCore.Blocks, c : T.Command) : E.Operation {
    { permission = commandPermission(c); book = commandBookOf(bs, c); totals = commandTotals(bs, js, jb, c) }
  };

  // ═══════════════════════════════════════════════════════
  //  AUTHORISATION
  // ═══════════════════════════════════════════════════════

  /// Evaluate the subject's grants against the operation. `day` selects the
  /// consumed figures the daily limit is measured against.
  public func authorise(s : State, subject : Principal, op : E.Operation, day : Nat) : Result.Result<{ role : T.RoleId }, T.BankError> {
    if (Principal.isAnonymous(subject)) return #err(#AnonymousCaller);
    let grants = grantsOf(s, subject);
    switch (E.evaluate(grants, op, func(ccy) { consumedFor(s, subject, ccy, day) })) {
      case (#allow(x)) #ok(x);
      case (#deny(e)) #err(e);
    }
  };

  /// True when a refusal by this subject should be recorded. Only a principal the
  /// bank has onboarded can grow the log.
  public func recordableRefusal(s : State, subject : Principal) : Bool {
    if (Principal.isAnonymous(subject)) return false;
    grantsOf(s, subject).size() > 0
  };

  public func refusalEvent(subject : Principal, permission : T.PermissionId, e : T.BankError, detail : Text) : T.Event {
    #operationRefused({ subject; permission; reason = E.refusalReason(e); detail })
  };

  /// The effective dual-authorisation policy, or null when the permission is
  /// single-authority. A `dualByDefault` permission with no policy is not
  /// single-authority — it is unusable, which `requireUsable` reports.
  public func policyFor(s : State, permission : T.PermissionId) : ?T.DualPolicy {
    Map.get(s.policies, Text.compare, permission)
  };

  public func requireUsable(s : State, perm : T.Permission) : ?T.BankError {
    switch (policyFor(s, perm.id)) {
      case (?_) null;
      case null {
        if (perm.dualByDefault) {
          return ?#InvalidPolicy({ reason = "permission " # perm.id # " requires dual authorisation and no policy is recorded; nobody is eligible to approve it" });
        };
        null
      };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  COMMAND VALIDATION AND PLANNING
  // ═══════════════════════════════════════════════════════

  /// One step of a command's effect on the journal. `#existing` is an
  /// idempotent replay: the posting is already committed and its index is named.
  public type JournalStep = { #event : JT.Event; #existing : Nat };

  /// What a command does when it executes: its bank event, the bank events that follow it in the same
  /// act (`extra`, one block each, in order — empty for every command but `createCustomer`), and its
  /// journal steps. The events are committed in that order: bank event, extras, journal.
  public type Plan = { bankEvent : ?T.Event; extra : [T.Event]; journal : [JournalStep] };

  func validIdentifier(t : Text, maxBytes : Nat) : Bool {
    let bytes = Text.encodeUtf8(t).size();
    if (bytes == 0 or bytes > maxBytes) return false;
    for (c in t.chars()) {
      let ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')
        or c == '-' or c == '_' or c == '.';
      if (not ok) return false;
    };
    true
  };

  func bookDepthOk(s : State, parent : ?T.BookId) : Bool {
    var depth = 0;
    var cur = parent;
    label walk loop {
      switch (cur) {
        case null break walk;
        case (?id) {
          depth += 1;
          if (depth > T.MAX_BOOK_DEPTH) return false;
          switch (Map.get(s.books, Text.compare, id)) {
            case (?b) cur := b.parent;
            case null break walk;
          };
        };
      };
    };
    depth < T.MAX_BOOK_DEPTH
  };

  func childCount(s : State, id : T.BookId) : Nat {
    var n = 0;
    for ((_, b) in Map.entries(s.books)) {
      switch (b.parent) { case (?p) { if (Text.equal(p, id) and b.status == #active) n += 1 }; case null {} };
    };
    n
  };

  /// Plan a command: validate it against both states and return the events to
  /// commit. Pure — nothing is changed here. `authorityIndex` is the bank block
  /// index that authorises the command (a proposal, or an override), which every
  /// posting it produces names in its source reference.
  /// `journalCaller` is the principal the journal sees: the bank canister
  /// itself, which is the journal's administrator and its only registered
  /// poster. The maker is an authority in the bank's own log, not a journal
  /// poster, so it must never be passed here.
  /// The value-day floor after closed-month packing: every value day at or before
  /// `packedThroughDay` is answered from the packs, and every rule that runs in a posting's message
  /// must see the whole of its window in the live rows — so a posting, a resolution or a batch is
  /// refused at or below `packedThroughDay + the longest active window`. Zero when nothing is
  /// packed.
  public func valueDayFloor(bs : State) : Nat {
    if (bs.packing.packedThroughDay == 0) 0 else bs.packing.packedThroughDay + MonitoringCore.longestWindow(bs.monitoring)
  };

  func packedDay(bs : State, day : Nat) : ?T.BankError {
    let floor = valueDayFloor(bs);
    if (floor > 0 and day <= floor) ?#PackingError({ error = #DayPacked({ day; packedThroughDay = bs.packing.packedThroughDay }) }) else null
  };

  /// Plan a command, then hold every journal step it would write to the value-day floor. One
  /// funnel: every posting, pending, resolution and batch the bank plans passes here.
  /// The value day a command names outright, held to the floor before anything else is planned —
  /// so a value day in packed history is refused as that, whatever else the command would have
  /// been refused for. Every journal step the plan produces is held to the floor as well.
  func commandValueDay(c : T.Command) : ?Nat {
    switch (c) {
      case (#postManualEntry(x)) ?x.valueDate;
      case (#postManualEntryForParty(x)) ?x.entry.valueDate;
      case (#reverseManualEntry(x)) ?x.valueDate;
      case (#depositToAccount(m)) ?m.valueDate;
      case (#openShardTransfer(x)) ?x.valueDate;
      case (#recordFunds(x)) ?x.valueDate;
      case (#withdrawFromAccount(m)) ?m.valueDate;
      case (#disburseLoan(m)) ?m.valueDate;
      case (#repayLoan(m)) ?m.valueDate;
      case (#recordRecovery(m)) ?m.valueDate;
      case (#redeemTermDeposit(m)) ?m.valueDate;
      case (#transferBetweenAccounts(x)) ?x.valueDate;
      case (#applyCharge(x)) ?x.valueDate;
      case (#waiveCharge(x)) ?x.valueDate;
      case (#writeOffLoan(x)) ?x.valueDate;
      case (#allocateCashToTill(x)) ?x.valueDate;
      case (#returnCashFromTill(x)) ?x.valueDate;
      case (#settleTill(x)) ?x.valueDate;
      case (#amortiseDeferral(x)) ?x.valueDate;
      case (#postAccrual(x)) ?x.day;
      case (#openEndOfDay(x)) ?x.businessDate;
      case (_) null;
    }
  };

  /// A block a command names as the original of a reversal or a correction.
  func commandOriginal(c : T.Command) : ?Nat {
    switch (c) {
      case (#reverseManualEntry(x)) ?x.original;
      case (#postManualEntry(x)) x.correctionOf;
      case (#postManualEntryForParty(x)) x.entry.correctionOf;
      case (_) null;
    }
  };

  public func blockArchived(bs : State, index : Nat) : ?T.BankError {
    if (bs.packing.archivedPacks > 0 and index <= bs.packing.archivedThroughBlock) ?#PackingError({ error = #BlockArchived({ index; archivedThroughBlock = bs.packing.archivedThroughBlock }) }) else null
  };

  /// Where a period's blocks are: the archive that holds them, when its close is at or below the
  /// archived boundary.
  public func periodArchived(bs : State, js : JCore.State, period : Text) : ?{ pack : Nat; cid : Nat64; archive : Principal } {
    let ?p = JCore.getPeriod(js, period) else return null;
    let ?closed = p.closedAtBlock else return null;
    if (bs.packing.archivedPacks == 0 or closed > bs.packing.archivedThroughBlock) return null;
    for ((pack, a) in Map.entries(bs.packing.archives)) { if (closed <= a.hi) return ?{ pack; cid = a.cid; archive = a.archive } };
    null
  };


  /// The opening of one account, the rule of `openAccount` stated once: the product's current version,
  /// its kind and currency, the term, the identifier issued behind this shard's index from `serialIndex`
  /// (the block the opening occupies), and the journal's balance limit for the account's sub-ledger.
  /// `party` and `partyBook` are the party as it is — or, for `createCustomer`, as it will be; `taken`
  /// are identifiers issued earlier in the same act, which the registers do not hold yet.
  public type OpenedAccount = { opened : ProdT.ProductEvent; limit : JT.Event; identifier : Text };
  func planOpenAccount(bs : State, js : JCore.State, journalCaller : Principal, product : ProdT.ProductId, party : PT.PartyId, partyBook : T.BookId, currency : JT.Currency, termDays : ?Nat, allocationOrder : [ProdT.Component], rateOverride : ?I.Rate, serialIndex : Nat, taken : [Text]) : Result.Result<OpenedAccount, T.BankError> {
    let ?v = ProductCore.currentVersion(bs.product, product) else return #err(#ProductError({ error = #UnknownProduct({ product }) }));
    if (not v.openToNewAccounts) {
      return #err(#ProductError({ error = #ProductClosedToNewAccounts({ product; version = v.version }) }));
    };
    if (v.terms.kind == #till) {
      return #err(#ProductError({ error = #AccountNotOfKind({ account = 0; expected = "a customer product"; actual = "till" }) }));
    };
    if (not Text.equal(v.terms.currency, currency)) {
      return #err(#ProductError({ error = #CurrencyMismatch({ expected = v.terms.currency; actual = currency }) }));
    };
    let ?opened = JCore.businessDate(js) else return #err(#ProductError({ error = #InvalidTerms({ reason = "no business date is set; roll it before opening accounts" }) }));
    // the allocation order is a loan term; an empty list takes the default
    let order = if (allocationOrder.size() == 0) Loans.defaultOrder() else allocationOrder;
    switch (Loans.validOrder(order)) { case (?r) return #err(#ProductError({ error = #InvalidAllocationOrder({ reason = r }) })); case null {} };
    // a term product needs a term, and nothing else may carry one
    let isTerm = v.terms.kind == #termDeposit or v.terms.kind == #recurringDeposit;
    var maturity : ?ProdT.Day = null;
    var openingRate : ?I.Rate = null;
    switch (termDays) {
      case (?days) {
        if (not isTerm) return #err(#ProductError({ error = #InvalidTerms({ reason = "only a term product carries a term" }) }));
        if (days == 0) return #err(#ProductError({ error = #InvalidTerms({ reason = "a term of zero days is not a term" }) }));
        maturity := ?(opened + days);
        let ?it = v.terms.interest else return #err(#ProductError({ error = #InvalidTerms({ reason = "a term product needs interest terms" }) }));
        if (it.chart.by == #termDays) {
          switch (TermProducts.rateForTerm(it.chart, days)) {
            case (#ok(r)) openingRate := ?r;
            case (#err(_)) return #err(#TermError({ reason = "no rate band covers a term of " # Nat.toText(days) # " days" }));
          };
        };
      };
      case null { if (isTerm) return #err(#ProductError({ error = #InvalidTerms({ reason = "a term product needs a term in days" }) })) };
    };
    // An underwritten rate (origination and underwriting) is the loan's own rate for its life: it is written as the opening rate, which
    // is what the accrual and the schedule read first, so a priced facility never falls back to the chart.
    switch (rateOverride) {
      case (?r) {
        if (v.terms.kind != #loan) return #err(#ProductError({ error = #InvalidTerms({ reason = "only a loan carries an underwritten rate" }) }));
        switch (I.validRate(r)) { case (?reason) return #err(#ProductError({ error = #InvalidTerms({ reason }) })); case null {} };
        openingRate := ?r;
      };
      case null {};
    };
    let ?fmt = PartyCore.format(bs.party) else return #err(#PartyError({ error = #InvalidIdentifier({ identifier = ""; reason = "no account-number format is recorded" }) }));
    // The serial is the bank block index this opening will occupy, so two accounts can never receive
    // the same identifier — the same rule the party layer issues under, behind this shard's index.
    let ?serial = ShardCore.serialFor(bs.shard, fmt, serialIndex) else return #err(#PartyError({ error = #InvalidIdentifier({ identifier = ""; reason = "the serial does not fit the format behind the shard index" }) }));
    switch (Iban.issue(fmt, serial)) {
      case (#err(r)) #err(#PartyError({ error = #InvalidIdentifier({ identifier = ""; reason = r }) }));
      case (#ok(identifier)) {
        if (PartyCore.byIdentifier(bs.party, identifier) != null or ProductCore.byIdentifier(bs.product, identifier) != null or Array.find<Text>(taken, func(t) { Text.equal(t, identifier) }) != null) {
          return #err(#PartyError({ error = #IdentifierExists({ identifier }) }));
        };
        // The account's own numeric balance limit is written when the account is
        // opened, not when money first moves: a deposit account may go debit by
        // at most its declared overdraft (none means zero) and a credit account
        // may not go credit at all. The limit lives on the journal's
        // (control account, sub-ledger, currency) triple, so it is enforced at
        // admission over posted and pending amounts by the same engine that
        // enforces the balance invariant: engine-enforced rather than checked by
        // the application.
        let sub = Posting.subledgerOf(identifier);
        let side = ProductCore.normalSideOf(v.terms.kind);
        let limit = Limits.journalLimit(side, v.terms.limits.overdraft);
        switch (JCore.prepareSetBalanceLimit(js, journalCaller, v.terms.control, ?sub, currency, limit)) {
          case (#err(e)) #err(#JournalConfigError({ error = e }));
          case (#ok(limitEvent)) #ok({
            opened = #accountOpened({ product; version = v.version; party; book = partyBook; identifier; currency; opened; maturity; openingRate; allocationOrder = order });
            limit = limitEvent; identifier;
          });
        }
      };
    }
  };

  /// `createCustomer`, planned whole. The party is built as it will be after each part and every part is
  /// held to its own command's rule against that party: the documents to `addPartyDocument`'s, the
  /// decision to `recordScreeningDecision`'s, the lifecycle to `setPartyLifecycle`'s (active needs the
  /// due-diligence documents and a screening that permits movement), the extensions to
  /// `setPartyExtension`'s, each account to `openAccount`'s and `setAccountStatus`'s. The party's id is
  /// the index of its `#partyCreated` block — the first block this act appends, `base` — and each
  /// account's is the index of its `#accountOpened` block, so every id is known before anything is
  /// written. One refusal refuses the whole: nothing is applied unless all of it would be.
  func planCreateCustomer(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, c : T.CreateCustomer, base : Nat) : Result.Result<Plan, T.BankError> {
    let x = c.party;
    // the party, as createParty plans it
    switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
    if (not Commit.validSalt(x.salt)) return #err(#PartyError({ error = #InvalidCommitment({ reason = "the salt must be 32 bytes" }) }));
    if (not Commit.validCommitment(x.identityCommit)) return #err(#PartyError({ error = #InvalidCommitment({ reason = "the identity commitment must be 32 bytes" }) }));
    switch (x.dedupCommit) {
      case (?d) {
        if (not Commit.validCommitment(d)) return #err(#PartyError({ error = #InvalidCommitment({ reason = "the deduplication commitment must be 32 bytes" }) }));
        switch (PartyCore.byDedup(bs.party, d)) { case (?existing) return #err(#PartyError({ error = #DuplicateIdentity({ existing }) })); case null {} };
      };
      case null {};
    };
    switch (PartyCore.validateAttributes(x.attributes)) { case (?r) return #err(#PartyError({ error = #InvalidParty({ reason = r }) })); case null {} };
    let partyId = base;
    let events = List.empty<T.Event>();
    List.add(events, #party(#partyCreated({ kind = x.kind; salt = x.salt; identityCommit = x.identityCommit; dedupCommit = x.dedupCommit; attributes = x.attributes; book = x.book; cddLevel = x.cddLevel; riskRating = x.riskRating; pep = x.pep; reviewDue = x.reviewDue })));
    // the party as it will be, carried through the parts
    var hyp : PartyCore.PartyEntry = {
      id = partyId; kind = x.kind; identityCommit = x.identityCommit; salt = x.salt; dedupCommit = x.dedupCommit; attributes = x.attributes;
      lifecycle = #prospect; cddLevel = x.cddLevel; riskRating = x.riskRating; pep = x.pep; screening = #unscreened; reviewDue = x.reviewDue;
      documents = []; relationships = []; extensions = []; book = x.book; identifiers = []; createdAtBlock = partyId;
    };
    // the lifecycle the party is left in: prospect, or pendingKyc, or active through pendingKyc
    switch (c.lifecycle) {
      case (#prospect or #pendingKyc or #active) {};
      case (other) return #err(#PartyError({ error = #IllegalTransition({ from = #prospect; to = other }) }));
    };
    if (c.lifecycle != #prospect) {
      List.add(events, #party(#partyLifecycleSet({ party = partyId; to = #pendingKyc })));
      hyp := { hyp with lifecycle = #pendingKyc };
    };
    // the documents, as addPartyDocument plans them
    if (c.documents.size() > PT.MAX_DOCUMENTS) return #err(#PartyError({ error = #InvalidParty({ reason = "too many documents" }) }));
    for (d in c.documents.vals()) {
      if (not Commit.validCommitment(d.commit)) return #err(#PartyError({ error = #InvalidCommitment({ reason = "the document commitment must be 32 bytes" }) }));
      if (Text.encodeUtf8(d.kind).size() == 0) return #err(#PartyError({ error = #InvalidParty({ reason = "a document needs a kind" }) }));
      switch (d.expires) { case (?e) { if (e <= d.issued) return #err(#PartyError({ error = #InvalidParty({ reason = "a document cannot expire before it was issued" }) })) }; case null {} };
      List.add(events, #party(#partyDocumentAdded({ party = partyId; document = d })));
    };
    hyp := { hyp with documents = c.documents };
    // the screening decision, as recordScreeningDecision plans it; the decision block's index is where it lands
    switch (c.screening) {
      case (?sc) {
        let ?list = PartyCore.getList(bs.party, sc.listVersion) else return #err(#PartyError({ error = #UnknownList({ version = sc.listVersion }) }));
        if (list.root != sc.listRoot) return #err(#PartyError({ error = #CommitmentMismatch({ field = "list root"; recorded = list.root; recomputed = sc.listRoot }) }));
        if (not Commit.validCommitment(sc.justificationCommit)) return #err(#PartyError({ error = #InvalidCommitment({ reason = "the justification commitment must be 32 bytes" }) }));
        if (Principal.isAnonymous(sc.screener)) return #err(#PartyError({ error = #InvalidParty({ reason = "a screening decision needs a named screener" }) }));
        let at = base + List.size(events);
        List.add(events, #party(#screeningDecisionRecorded({ party = partyId; listVersion = sc.listVersion; listRoot = sc.listRoot; decision = sc.decision; screener = sc.screener; justificationCommit = sc.justificationCommit })));
        let state : PT.ScreeningState = switch (sc.decision) {
          case (#clear) #clear({ listVersion = sc.listVersion; at });
          case (#hit({ matches })) #hit({ listVersion = sc.listVersion; matches; at });
          case (#cleared({ reason })) #cleared({ listVersion = sc.listVersion; at; reason });
          case (#confirmed) #confirmed({ listVersion = sc.listVersion; at });
        };
        hyp := { hyp with screening = state };
      };
      case null {};
    };
    // active, as setPartyLifecycle plans it
    if (c.lifecycle == #active) {
      let missing = PartyCore.missingDocuments(hyp);
      if (missing.size() > 0) return #err(#PartyError({ error = #CddIncomplete({ party = partyId; level = hyp.cddLevel; missing }) }));
      let eff = PartyCore.effectiveScreening(bs.party, hyp);
      if (not Screening.permitsMovement(eff)) return #err(#PartyError({ error = #ScreeningBlocks({ party = partyId; state = eff }) }));
      List.add(events, #party(#partyLifecycleSet({ party = partyId; to = #active })));
      hyp := { hyp with lifecycle = #active };
    };
    // the extensions, as setPartyExtension plans them
    if (c.extensions.size() > 0) {
      switch (PartyCore.validateExtensionValues(bs.party, #party, c.extensions)) { case (?e) return #err(#PartyError({ error = e })); case null {} };
      List.add(events, #party(#partyExtensionSet({ party = partyId; values = c.extensions })));
    };
    // the accounts, as openAccount and setAccountStatus plan them; each is the block its opening occupies
    let journal = List.empty<JournalStep>();
    let taken = List.empty<Text>();
    for (a in c.accounts.vals()) {
      let accountIndex = base + List.size(events);
      switch (planOpenAccount(bs, js, journalCaller, a.product, partyId, x.book, a.currency, a.termDays, a.allocationOrder, null, accountIndex, List.toArray(taken))) {
        case (#err(e)) return #err(e);
        case (#ok(o)) {
          List.add(events, #product(o.opened));
          List.add(journal, #event(o.limit));
          List.add(taken, o.identifier);
          if (a.activate) {
            // an opened account's status is the one `accountTransitionAllowed` admits #active from
            if (not accountTransitionAllowed(#pending, #active)) return #err(#ProductError({ error = #AccountNotActive({ account = accountIndex; status = #pending }) }));
            List.add(events, #product(#accountStatusSet({ account = accountIndex; to = #active })));
          };
        };
      };
    };
    // the application this onboarding fulfils (origination and underwriting): a prospect's open application in this book gains the party
    switch (c.application) {
      case (?application) {
        switch (OriginationCore.planOnboard(bs.origination, application)) {
          case (#err(e)) return #err(#OriginationError({ error = e }));
          case (#ok(r)) {
            if (not Text.equal(r.book, x.book)) return #err(#OriginationError({ error = #PartyMismatch({ application }) }));
            List.add(events, #origination(#prospectOnboarded({ application; party = partyId })));
          };
        };
      };
      case null {};
    };
    let all = List.toArray(events);
    #ok({ bankEvent = ?all[0]; extra = Array.tabulate<T.Event>(all.size() - 1, func(i) { all[i + 1] }); journal = List.toArray(journal) })
  };

  public func planCommand(bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64, command : T.Command, authorityIndex : Nat) : Result.Result<Plan, T.BankError> {
    switch (commandValueDay(command)) {
      case (?d) { switch (packedDay(bs, d)) { case (?e) return #err(e); case null {} } };
      case null {};
    };
    switch (commandOriginal(command)) {
      case (?o) { switch (blockArchived(bs, o)) { case (?e) return #err(e); case null {} } };
      case null {};
    };
    let plan = switch (planCommandInner(bs, bb, js, jb, journalCaller, now, command, authorityIndex)) { case (#err(e)) return #err(e); case (#ok(p)) p };
    // the sub-ledgers of accounts this very plan opens are the shard's from the block they open on
    let introduced = List.empty<JT.SubledgerKey>();
    switch (plan.bankEvent) { case (?#product(#accountOpened(o))) List.add(introduced, Posting.subledgerOf(o.identifier)); case (_) {} };
    for (ev in plan.extra.vals()) { switch (ev) { case (#product(#accountOpened(o))) List.add(introduced, Posting.subledgerOf(o.identifier)); case (_) {} } };
    switch (plan.bankEvent) {
      case (?#teller(#cashDispatched(_))) List.add(introduced, TellerCore.transitSub(bs.height));
      case (?#teller(#draftIssued(d))) List.add(introduced, TellerCore.draftSub(d.serial));
      case (?#trade(#lcIssued(_)) or ?#trade(#guaranteeIssued(_))) { List.add(introduced, TradeCore.marginSub(bs.height)); List.add(introduced, TradeCore.commissionSub(bs.height)) };
      case (?#trade(#lcAdvised(_))) List.add(introduced, TradeCore.commissionSub(bs.height));
      case (?#trade(#presentationHonoured(h))) List.add(introduced, TradeCore.acceptanceSub(h.instrument, h.claim));
      case (?#trade(#billDiscounted(_))) List.add(introduced, TradeCore.billSub(bs.height));
      case (?#islamic(#contractOpened(_))) List.add(introduced, IslamicCore.contractSub(bs.height));
      case (?#islamic(#poolOpened(p))) List.add(introduced, IslamicCore.poolSub(p.pool.id));
      case (_) {};
    };
    let opened = List.toArray(introduced);
    for (step in plan.journal.vals()) {
      switch (step) {
        case (#event(#posted(r))) { switch (packedDay(bs, r.valueDate)) { case (?e) return #err(e); case null {} }; switch (foreignLeg(bs, r.legs, opened)) { case (?e) return #err(e); case null {} } };
        case (#event(#pending(x))) { switch (packedDay(bs, x.record.valueDate)) { case (?e) return #err(e); case null {} }; switch (foreignLeg(bs, x.record.legs, opened)) { case (?e) return #err(e); case null {} } };
        case (#event(#post(x))) { switch (packedDay(bs, x.resolution.valueDate)) { case (?e) return #err(e); case null {} } };
        case (_) {};
      };
    };
    #ok(plan)
  };

  // ─── the receiving and settling sides of an inter-shard transfer ───────────

  /// The receiving shard's side: from a shard principal of the rule, for an identifier this shard
  /// holds as an active account, a posting under the transfer's own idempotency key — debit the
  /// settlement account for the sending shard, credit the customer. A second delivery is
  /// `#Duplicate` with the posting already made.
  public func planReceiveShardTransfer(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, caller : Principal, fromShard : Nat, transfer : Nat, toIdentifier : Text, amount : Nat, currency : Text, valueDay : Nat, period : Text, narration : Text) : Result.Result<{ account : ProdT.AccountId; step : JournalStep }, T.BankError> {
    let ?_ = ShardCore.rule(bs.shard) else return #err(#ShardError({ error = #NoRule }));
    let ?from = ShardCore.shardByPrincipal(bs.shard, caller) else return #err(#ShardError({ error = #NotAShard({ caller }) }));
    if (from.index != fromShard) return #err(#ShardError({ error = #NotAShard({ caller }) }));
    switch (ShardCore.inbound(bs.shard, fromShard, transfer)) { case (?x) return #err(#ShardError({ error = #Duplicate({ fromShard; transfer; posting = x.posting }) })); case null {} };
    let ?acctId = ProductCore.byIdentifier(bs.product, toIdentifier) else return #err(#ShardError({ error = #IdentifierNotHere({ identifier = toIdentifier }) }));
    let today = JCore.effectiveToday(js, now);
    switch (movableAccount(bs, bb, js, acctId, today)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        if (not Text.equal(a.currency, currency)) return #err(#ProductError({ error = #CurrencyMismatch({ expected = a.currency; actual = currency }) }));
        if (terms.kind == #loan) return #err(#ProductError({ error = #AccountNotOfKind({ account = acctId; expected = "a deposit product"; actual = "loan" }) }));
        // the value day is the sender's when this shard's calendar allows it, else today's
        let effective = switch (valueDateGate(bs, js, a.book, period, terms.valueDateConvention, valueDay)) { case (#ok(d)) d; case (#err(_)) today };
        let openPeriod = switch (periodContaining(js, today)) { case (?p) p; case null return #err(#ProductError({ error = #InvalidTerms({ reason = "no open period contains today" }) })) };
        let (postingDate, bookPeriod, valueDate) = switch (JCore.getPeriod(js, period)) {
          case (?p) { if (p.status == #open and p.start <= today and today <= p.end) (today, period, effective) else (today, openPeriod, today) };
          case null (today, openPeriod, today);
        };
        let debit = Posting.leg(from.settlement, null, #debit, currency, amount);
        let credit = Posting.leg(terms.control, ?a.subledger, #credit, currency, amount);
        let input : JT.PostingInput = {
          idempotencyKey = ShardCore.inboundKey(fromShard, transfer);
          postingDate; valueDate; period = bookPeriod; legs = [debit, credit];
          sourceRef = { kind = "shard-transfer"; id = Nat.toText(fromShard) # "/" # Nat.toText(transfer) }; narration; correctionOf = null;
        };
        switch (JCore.preparePost(js, journalCaller, now, input)) {
          case (#err(e)) #err(#JournalError({ error = e }));
          case (#ok(#event(ev))) #ok({ account = acctId; step = #event(ev) });
          case (#ok(#duplicate(idx))) #ok({ account = acctId; step = #existing(idx) });
        }
      };
    }
  };

  // ─── settlement: the legs and the two-phase acts ─────────────────────────

  /// The control account and sub-ledger of a participant's account, active.
  func participantLeg(bs : State, bb : Blocks, js : JCore.State, id : ProdT.AccountId, day : Nat) : Result.Result<(JT.AccountCode, JT.SubledgerKey), T.BankError> {
    switch (movableAccount(bs, bb, js, id, day)) { case (#err(e)) #err(e); case (#ok((a, terms))) #ok((terms.control, a.subledger)) }
  };

  /// The reservation of a prepared transfer: the payer's position debited pending, the payee's
  /// credited pending, expiring with the transfer. The journal's numeric limit on the payer's
  /// position is the net debit cap: the refusal, when it comes, is the engine's (`#ExceedsCredits`).
  public func planReserve(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, transfer : SeT.TransferId) : Result.Result<{ event : SeT.SettlementEvent; step : ?JournalStep; forwarded : Bool }, T.BankError> {
    let ?t = SettlementCore.transferRowOf(bs.settlement, transfer) else return #err(#SettlementError({ error = #UnknownTransfer({ transfer }) }));
    if (t.state != #receivedPrepare) return #err(#SettlementError({ error = #TransferNotIn({ transfer; state = SeT.transferStateName(t.state); expected = "RECEIVED_PREPARE" }) }));
    let today = JCore.effectiveToday(js, now);
    // every refusal of the reservation is the transfer's failure, recorded with its reason: a
    // participant deactivated or a party frozen since the prepare as much as the journal's cap
    func failed(reason : Text) : Result.Result<{ event : SeT.SettlementEvent; step : ?JournalStep; forwarded : Bool }, T.BankError> { #ok({ event = #transferFailed({ transfer; reason }); step = null; forwarded = false }) };
    let (_, payerAccts) = switch (SettlementCore.activeAccounts(bs.settlement, t.payer, t.currency)) { case (#err(e)) return failed(debug_show (e)); case (#ok(v)) v };
    let (_, payeeAccts) = switch (SettlementCore.activeAccounts(bs.settlement, t.payee, t.currency)) { case (#err(e)) return failed(debug_show (e)); case (#ok(v)) v };
    let (payerControl, payerSub) = switch (participantLeg(bs, bb, js, payerAccts.position, today)) { case (#err(e)) return failed(debug_show (e)); case (#ok(v)) v };
    let (payeeControl, payeeSub) = switch (participantLeg(bs, bb, js, payeeAccts.position, today)) { case (#err(e)) return failed(debug_show (e)); case (#ok(v)) v };
    let ?period = periodContaining(js, today) else return failed("no open period contains today");
    // a return carries the journal's correction link to the posting it reverses
    let correctionOf = switch (bb.get(transfer)) { case (?{ event = #settlement(#transferPrepared(p)) }) p.correctionOf; case (_) null };
    let input : JT.PostingInput = {
      idempotencyKey = Posting.key("PRINCIPLE_VALUE", [t.scheme, Nat.toText(transfer)]);
      postingDate = today; valueDate = today; period;
      legs = [Posting.leg(payerControl, ?payerSub, #debit, t.currency, t.amount), Posting.leg(payeeControl, ?payeeSub, #credit, t.currency, t.amount)];
      sourceRef = { kind = "PRINCIPLE_VALUE"; id = t.scheme # "/" # Nat.toText(transfer) }; narration = (switch (correctionOf) { case (?o) "return of posting " # Nat.toText(o) # ", transfer "; case null "transfer " }) # Nat.toText(transfer); correctionOf;
    };
    switch (JCore.prepareReserve(js, journalCaller, now, input, ?t.expiresAt)) {
      // the engine's refusal is the transfer's failure, recorded as such: FAILED with the reason
      case (#err(e)) failed(debug_show (e));
      case (#ok(#duplicate(idx))) #err(#JournalError({ error = #IdempotencyKeyReused({ existing = idx }) }));
      case (#ok(#event(ev))) #ok({ event = #transferReserved({ transfer; reservation = JCore.height(js); forwarded = false }); step = ?#event(ev); forwarded = false });
    }
  };

  /// The cap alarm: after a reservation, the payer's exposure against its cap. The cap is the
  /// journal's own limit on the position; the alarm is the scheme's percentage of it.
  public func capAlarm(bs : State, bb : Blocks, js : JCore.State, now : Nat64, transfer : SeT.TransferId) : ?SeT.SettlementEvent {
    let ?t = SettlementCore.transferRowOf(bs.settlement, transfer) else return null;
    let ?sch = SettlementCore.scheme(bs.settlement, t.scheme) else return null;
    let (_, accts) = switch (SettlementCore.activeAccounts(bs.settlement, t.payer, t.currency)) { case (#err(_)) return null; case (#ok(v)) v };
    let today = JCore.effectiveToday(js, now);
    let (control, sub) = switch (participantLeg(bs, bb, js, accts.position, today)) { case (#err(_)) return null; case (#ok(v)) v };
    let ?limit = JCore.balanceLimit(js, control, ?sub, t.currency) else return null;
    let cap = switch (limit) { case (#debitsNotExceedCreditsPlus(n)) n; case (_) return null };
    let b = JCore.balance(js, control, ?sub, t.currency);
    let debits = b.debitsPosted + b.debitsPending;
    let exposure = if (debits > b.creditsPosted) debits - b.creditsPosted else 0;
    if (cap > 0 and exposure * 100 >= cap * sch.alarmPercent) ?#capAlarm({ participant = t.payer; currency = t.currency; exposure; cap; alarmPercent = sch.alarmPercent }) else null
  };

  func planFulfil(bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64, transfer : SeT.TransferId) : Result.Result<Plan, T.BankError> {
    // a payment held for compliance review posts only when the hold is released (dual)
    switch (PaymentsCore.holdOf(bs.payments, transfer)) { case (?rule) return #err(#PaymentsError({ error = #Held({ transfer; rule }) })); case null {} };
    let r = switch (SettlementCore.requireTransition(bs.settlement, transfer, #receivedFulfil)) { case (#err(e)) return #err(#SettlementError({ error = e })); case (#ok(r)) r };
    let ?t = SettlementCore.transferRowOf(bs.settlement, transfer) else return #err(#SettlementError({ error = #UnknownTransfer({ transfer }) }));
    let ?reservation = t.reservation else return #err(#SettlementError({ error = #TransferNotIn({ transfer; state = SeT.transferStateName(t.state); expected = "a reserved transfer" }) }));
    let ?sch = SettlementCore.scheme(bs.settlement, t.scheme) else return #err(#SettlementError({ error = #UnknownScheme({ scheme = t.scheme }) }));
    let today = JCore.effectiveToday(js, now);
    let ?windowId = SettlementCore.openWindow(bs.settlement, t.scheme, today) else return #err(#SettlementError({ error = #NoOpenWindow({ scheme = t.scheme; businessDate = today }) }));
    // the post of the pending: today's date and open period
    let ?period = periodContaining(js, today) else return #err(#ProductError({ error = #InvalidTerms({ reason = "no open period contains today" }) }));
    let steps = List.empty<JournalStep>();
    switch (JCore.preparePostPending(js, jb, journalCaller, now, reservation, ?{ postingDate = today; valueDate = today; valueDateRequested = null; period })) {
      case (#err(e)) return #err(#JournalError({ error = e }));
      case (#ok(#expired(x))) return #err(#JournalError({ error = #PendingExpired({ index = reservation; expiresAt = x.expiresAt; voidedBy = 0 }) }));
      case (#ok(#event(ev))) List.add(steps, #event(ev));
    };
    // the fees, as postings of their own kinds: interchange from the payer's position to the
    // payee's, the hub's from the payer's position to the scheme's income
    // a return (pacs.004) carries no fees: the principal goes back, the original's fees stand
    let isReturn = switch (bb.get(transfer)) { case (?{ event = #settlement(#transferPrepared(p)) }) p.correctionOf != null; case (_) false };
    let interchange = if (isReturn) 0 else t.amount * sch.interchangeBps / 10_000;
    let hubFee = if (isReturn) 0 else t.amount * sch.hubFeeBps / 10_000;
    let (_, payerAccts) = switch (SettlementCore.activeAccounts(bs.settlement, t.payer, t.currency)) { case (#err(e)) return #err(#SettlementError({ error = e })); case (#ok(v)) v };
    let (_, payeeAccts) = switch (SettlementCore.activeAccounts(bs.settlement, t.payee, t.currency)) { case (#err(e)) return #err(#SettlementError({ error = e })); case (#ok(v)) v };
    let (payerControl, payerSub) = switch (participantLeg(bs, bb, js, payerAccts.position, today)) { case (#err(e)) return #err(e); case (#ok(v)) v };
    let (feeControl, feeSub) = switch (participantLeg(bs, bb, js, payeeAccts.feeReceivable, today)) { case (#err(e)) return #err(e); case (#ok(v)) v };
    let feePostings = List.empty<Nat>();
    var nextPosting = JCore.height(js) + 1;   // the post itself is the height's block
    if (interchange > 0) {
      let input : JT.PostingInput = {
        idempotencyKey = Posting.key("INTERCHANGE_FEE", [t.scheme, Nat.toText(transfer)]); postingDate = today; valueDate = today; period;
        legs = [Posting.leg(payerControl, ?payerSub, #debit, t.currency, interchange), Posting.leg(feeControl, ?feeSub, #credit, t.currency, interchange)];
        sourceRef = { kind = "INTERCHANGE_FEE"; id = t.scheme # "/" # Nat.toText(transfer) }; narration = "interchange on " # Nat.toText(transfer); correctionOf = null;
      };
      switch (JCore.preparePost(js, journalCaller, now, input)) { case (#err(e)) return #err(#JournalError({ error = e })); case (#ok(#duplicate(idx))) return #err(#JournalError({ error = #IdempotencyKeyReused({ existing = idx }) })); case (#ok(#event(ev))) { List.add(steps, #event(ev)); List.add(feePostings, nextPosting); nextPosting += 1 } };
    };
    if (hubFee > 0) {
      let input : JT.PostingInput = {
        idempotencyKey = Posting.key("HUB_FEE", [t.scheme, Nat.toText(transfer)]); postingDate = today; valueDate = today; period;
        legs = [Posting.leg(payerControl, ?payerSub, #debit, t.currency, hubFee), Posting.leg(sch.feeIncome, null, #credit, t.currency, hubFee)];
        sourceRef = { kind = "HUB_FEE"; id = t.scheme # "/" # Nat.toText(transfer) }; narration = "hub fee on " # Nat.toText(transfer); correctionOf = null;
      };
      switch (JCore.preparePost(js, journalCaller, now, input)) { case (#err(e)) return #err(#JournalError({ error = e })); case (#ok(#duplicate(idx))) return #err(#JournalError({ error = #IdempotencyKeyReused({ existing = idx }) })); case (#ok(#event(ev))) { List.add(steps, #event(ev)); List.add(feePostings, nextPosting); nextPosting += 1 } };
    };
    ignore r;
    #ok({ bankEvent = ?#settlement(#transferCommitted({ transfer; posting = reservation; window = windowId; interchangeFee = interchange; hubFee; feePostings = List.toArray(feePostings) })); extra = []; journal = List.toArray(steps) })
  };

  func planAbort(bs : State, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, transfer : SeT.TransferId, how : { #rejected; #error; #expired }, reason : Text) : Result.Result<Plan, T.BankError> {
    let first : SeT.TransferState = switch (how) { case (#rejected) #receivedReject; case (#error) #receivedError; case (#expired) #reservedTimeout };
    let r = switch (SettlementCore.requireTransition(bs.settlement, transfer, first)) { case (#err(e)) return #err(#SettlementError({ error = e })); case (#ok(r)) r };
    if (Text.size(reason) == 0) return #err(#SettlementError({ error = #InvalidTransfer({ reason = "an abort carries its reason" }) }));
    if (r.reservation == 0) return #err(#SettlementError({ error = #TransferNotIn({ transfer; state = SeT.transferStateName(r.state); expected = "a reserved transfer" }) }));
    let step : JT.Event = switch (how) {
      case (#expired) JCore.expiryVoidEvent(r.reservation);
      case (_) { switch (JCore.prepareVoidPending(js, jb, journalCaller, r.reservation)) { case (#err(e)) return #err(#JournalError({ error = e })); case (#ok(ev)) ev } };
    };
    #ok({ bankEvent = ?#settlement(#transferAborted({ transfer; how; reason })); extra = []; journal = [#event(step)] })
  };

  /// The expiry sweep's plan for one transfer whose deadline has passed.
  public func planExpire(bs : State, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64, transfer : SeT.TransferId) : Result.Result<Plan, T.BankError> {
    let ?t = SettlementCore.transferRowOf(bs.settlement, transfer) else return #err(#SettlementError({ error = #UnknownTransfer({ transfer }) }));
    if (t.expiresAt > now) return #err(#SettlementError({ error = #TransferNotIn({ transfer; state = SeT.transferStateName(t.state); expected = "a reservation past its deadline" }) }));
    planAbort(bs, js, jb, journalCaller, transfer, #expired, "the reservation's deadline passed")
  };

  /// INV-P2: the settlement of a window is one journal batch. For every net position, one posting
  /// between the participant's position and its settlement account — a net sender's settlement
  /// account is debited and its position credited, a net recipient's the reverse; a zero net posts
  /// nothing and is recorded as SETTLEMENT_NET_ZERO. The batch is prepared whole by the journal:
  /// either every posting is admitted or the first refusal names the position and nothing is.
  public func planSettlementBatch(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, settlementId : SeT.SettlementId) : Result.Result<{ events : [SeT.SettlementEvent]; journal : [JT.Event]; postings : [Nat] }, T.BankError> {
    let ?st = SettlementCore.settlement(bs.settlement, settlementId) else return #err(#SettlementError({ error = #UnknownSettlement({ settlement = settlementId }) }));
    if (st.state != #psTransfersRecorded) return #err(#SettlementError({ error = #SettlementNotIn({ settlement = settlementId; state = SeT.settlementStateName(st.state); expected = "PS_TRANSFERS_RECORDED" }) }));
    switch (SettlementCore.conserved(st.nets)) { case (?(c, sum)) return #err(#SettlementError({ error = #NettingNotConserved({ currency = c; sum }) })); case null {} };
    let today = JCore.effectiveToday(js, now);
    let ?period = periodContaining(js, today) else return #err(#ProductError({ error = #InvalidTerms({ reason = "no open period contains today" }) }));
    let inputs = List.empty<JT.PostingInput>();
    var zeros = 0;
    for (n in st.nets.vals()) {
      if (n.debits == n.credits) { zeros += 1 } else {
        let (_, accts) = switch (SettlementCore.activeAccounts(bs.settlement, n.participant, n.currency)) { case (#err(e)) return #err(#SettlementError({ error = e })); case (#ok(v)) v };
        let (posControl, posSub) = switch (participantLeg(bs, bb, js, accts.position, today)) { case (#err(e)) return #err(e); case (#ok(v)) v };
        let (setControl, setSub) = switch (participantLeg(bs, bb, js, accts.settlement, today)) { case (#err(e)) return #err(e); case (#ok(v)) v };
        let (kind, legs) = if (n.debits > n.credits) {
          let owed = n.debits - n.credits;
          ("SETTLEMENT_NET_SENDER", [Posting.leg(setControl, ?setSub, #debit, n.currency, owed), Posting.leg(posControl, ?posSub, #credit, n.currency, owed)])
        } else {
          let due = n.credits - n.debits;
          ("SETTLEMENT_NET_RECIPIENT", [Posting.leg(posControl, ?posSub, #debit, n.currency, due), Posting.leg(setControl, ?setSub, #credit, n.currency, due)])
        };
        List.add(inputs, {
          idempotencyKey = Posting.key(kind, [Nat.toText(settlementId), Nat.toText(n.participant), n.currency]);
          postingDate = today; valueDate = today; period; legs;
          sourceRef = { kind; id = Nat.toText(settlementId) # "/" # Nat.toText(n.participant) # "/" # n.currency }; narration = "settlement " # Nat.toText(settlementId); correctionOf = null;
        });
      };
    };
    let events = List.empty<SeT.SettlementEvent>();
    switch (SettlementCore.planSettlementTransition(bs.settlement, settlementId, #psTransfersReserved, [], [], "the batch prepared: " # Nat.toText(List.size(inputs)) # " positions, " # Nat.toText(zeros) # " at zero (SETTLEMENT_NET_ZERO)")) { case (#ok(ev)) List.add(events, ev); case (#err(e)) return #err(#SettlementError({ error = e })) };
    if (List.size(inputs) == 0) return #ok({ events = List.toArray(events); journal = []; postings = [] });
    switch (JCore.prepareBatch(js, journalCaller, now, List.toArray(inputs))) {
      case (#err(e)) #err(#JournalBatchError({ index = e.index; error = e.error }));
      case (#ok(prepared)) {
        let journal = List.empty<JT.Event>();
        let postings = List.empty<Nat>();
        var next = JCore.height(js);
        for (p in prepared.vals()) {
          switch (p) {
            case (#event(ev)) { List.add(journal, ev); List.add(postings, next); next += 1 };
            case (#duplicate(idx)) List.add(postings, idx);
          };
        };
        #ok({ events = List.toArray(events); journal = List.toArray(journal); postings = List.toArray(postings) })
      };
    }
  };

  // ─── the settlement and bulk advances, shared with the unit battery ──────────

  public type SettlementJob = { acc : Map.Map<(Nat, Text), { var debits : Nat; var credits : Nat }>; var cursor : ?Nat; var settleCursor : ?Nat };
  public func newSettlementJob() : SettlementJob { { acc = Map.empty<(Nat, Text), { var debits : Nat; var credits : Nat }>(); var cursor = null; var settleCursor = null } };
  public type SettlementAdvance = { settlement : Nat; state : Text; windowState : Text; work : Nat; done : Bool };

  func run(recorder : Recorder, plan : Plan) : [Nat] {
    switch (plan.bankEvent) { case (?ev) ignore recorder.bank(ev); case null {} };
    for (ev in plan.extra.vals()) { ignore recorder.bank(ev) };
    let out = List.empty<Nat>();
    for (step in plan.journal.vals()) { switch (step) { case (#event(ev)) List.add(out, recorder.journal(ev)); case (#existing(i)) List.add(out, i) } };
    List.toArray(out)
  };

  /// One bounded step of an open settlement: the netting fold over the window's committed transfers
  /// (INV-P1 checked before anything is recorded), the batch (INV-P2: all positions or none, the
  /// window FAILED and the settlement left re-drivable on a refusal), then the transfers marked
  /// SETTLED a chunk at a time.
  public func advanceSettlement(bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64, settlementId : Nat, job : SettlementJob, limit : Nat, recorder : Recorder) : Result.Result<SettlementAdvance, T.BankError> {
    ignore jb;
    let ?st = SettlementCore.settlement(bs.settlement, settlementId) else return #err(#SettlementError({ error = #UnknownSettlement({ settlement = settlementId }) }));
    let ?win = SettlementCore.window(bs.settlement, st.window) else return #err(#SettlementError({ error = #UnknownWindow({ window = st.window }) }));
    let n = Nat.min(Nat.max(limit, 1), 5_000);
    func reply(work : Nat, done : Bool) : Result.Result<SettlementAdvance, T.BankError> {
      let ?st2 = SettlementCore.settlement(bs.settlement, settlementId) else Runtime.trap("BankCore: the settlement vanished");
      let ?w2 = SettlementCore.window(bs.settlement, st.window) else Runtime.trap("BankCore: the window vanished");
      #ok({ settlement = settlementId; state = SeT.settlementStateName(st2.state); windowState = SeT.windowStateName(w2.state); work; done })
    };
    func record(ev : SeT.SettlementEvent) { ignore recorder.bank(#settlement(ev)) };
    switch (st.state) {
      case (#pendingSettlement) {
        let r = SettlementCore.netChunk(bs.settlement, st.window, job.acc, job.cursor, n);
        switch (r.next) {
          case (?c) { job.cursor := ?c; reply(r.examined, false) };
          case null {
            let nets = SettlementCore.netsOf(job.acc);
            switch (SettlementCore.conserved(nets)) { case (?(c, sum)) return #err(#SettlementError({ error = #NettingNotConserved({ currency = c; sum }) })); case null {} };
            // a settlement opened by a multilateral settlement request (pacs.029) settles only the
            // movements the operator asked for: the request is judged against the nets here, and a
            // disagreement aborts the settlement with the first difference on record
            switch (PaymentsCore.settlementRequest(bs.payments, settlementId)) {
              case (?req) {
                switch (PaymentsCore.judgeSettlementRequest(bs.settlement, win.scheme, req.movements, nets)) {
                  case (?detail) {
                    ignore recorder.bank(#payments(#settlementRequestJudged({ settlement = settlementId; matched = false; detail })));
                    // the window follows the settlement to ABORTED in the fold
                    switch (SettlementCore.planSettlementTransition(bs.settlement, settlementId, #aborted, [], [], "settlement request mismatch: " # detail)) { case (#ok(ev)) record(ev); case (#err(e)) return #err(#SettlementError({ error = e })) };
                    return reply(r.examined, true);
                  };
                  case null ignore recorder.bank(#payments(#settlementRequestJudged({ settlement = settlementId; matched = true; detail = "every movement equals its net" })));
                };
              };
              case null {};
            };
            switch (SettlementCore.planSettlementTransition(bs.settlement, settlementId, #psTransfersRecorded, nets, [], "netted over " # Nat.toText(win.transfers) # " transfers")) {
              case (#err(e)) #err(#SettlementError({ error = e }));
              case (#ok(ev)) { record(ev); reply(r.examined, false) };
            }
          };
        }
      };
      case (#psTransfersRecorded) {
        // the attempt is the processing: the window is PROCESSING while the batch is prepared, and
        // FAILED — re-drivable, back through PROCESSING — when the journal refuses it
        if (win.state != #processing) {
          switch (SettlementCore.planWindowTransition(bs.settlement, st.window, #processing, "settling")) { case (#ok(ev)) record(ev); case (#err(e)) return #err(#SettlementError({ error = e })) };
        };
        switch (planSettlementBatch(bs, bb, js, journalCaller, now, settlementId)) {
          case (#err(e)) {
            switch (SettlementCore.planWindowTransition(bs.settlement, st.window, #failed, debug_show (e))) { case (#ok(ev)) record(ev); case (#err(x)) Runtime.trap("BankCore: a processing window could not be marked failed: " # debug_show (x)) };
            #err(e)
          };
          case (#ok(batch)) {
            for (ev in batch.events.vals()) record(ev);
            for (ev in batch.journal.vals()) ignore recorder.journal(ev);
            switch (SettlementCore.planSettlementTransition(bs.settlement, settlementId, #psTransfersCommitted, [], batch.postings, "the batch posted")) { case (#ok(ev)) record(ev); case (#err(e)) return #err(#SettlementError({ error = e })) };
            switch (SettlementCore.planSettlementTransition(bs.settlement, settlementId, #settling, [], [], "marking the transfers")) { case (#ok(ev)) record(ev); case (#err(e)) return #err(#SettlementError({ error = e })) };
            reply(batch.postings.size(), false)
          };
        }
      };
      case (#settling) {
        let page = SettlementCore.windowTransferIds(bs.settlement, st.window, job.settleCursor, n);
        let committed = List.empty<Nat>();
        for (id in page.ids.vals()) { switch (SettlementCore.transferRowOf(bs.settlement, id)) { case (?t) { if (t.state == #committed) List.add(committed, id) }; case null {} } };
        if (List.size(committed) > 0) record(#transfersSettled({ settlement = settlementId; transfers = List.toArray(committed) }));
        switch (page.next) {
          case (?c) { job.settleCursor := ?c; reply(page.ids.size(), false) };
          case null {
            switch (SettlementCore.planSettlementTransition(bs.settlement, settlementId, #settled, [], [], "settled")) { case (#ok(ev)) record(ev); case (#err(e)) return #err(#SettlementError({ error = e })) };
            switch (SettlementCore.planWindowTransition(bs.settlement, st.window, #settled, "settled")) { case (#ok(ev)) record(ev); case (#err(e)) return #err(#SettlementError({ error = e })) };
            reply(page.ids.size(), true)
          };
        }
      };
      case (#settled) reply(0, true);
      case (st2) #err(#SettlementError({ error = #SettlementNotIn({ settlement = settlementId; state = SeT.settlementStateName(st2); expected = "PENDING_SETTLEMENT, PS_TRANSFERS_RECORDED or SETTLING" }) }));
    }
  };

  /// A prepared transfer recorded and reserved: the two acts every credit transfer makes, whether it
  /// came as a command, a bulk item or an ISO 20022 message. The actor reserves in the commit of the
  /// prepare itself (`Bank.reserveOnEvent`), so the transfer may already be RESERVED or FAILED when
  /// the recorder returns; a recorder without that hook leaves it RECEIVED_PREPARE and the
  /// reservation is made here. `failure` carries the journal's reason when the reservation was refused.
  public func prepareAndReserve(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, prepared : SeT.SettlementEvent, recorder : Recorder) : { transfer : Nat; reserved : Bool; failure : ?Text } {
    let sb : SettlementCore.Blocks = { get = func(i : Nat) : ?SeT.SettlementEvent { switch (bb.get(i)) { case (?b) { switch (b.event) { case (#settlement(se)) ?se; case (_) null } }; case null null } } };
    let id = recorder.bank(#settlement(prepared));
    switch (SettlementCore.transferRowOf(bs.settlement, id)) {
      case (?{ state = #receivedPrepare }) {
        switch (planReserve(bs, bb, js, journalCaller, now, id)) {
          case (#err(e)) { { transfer = id; reserved = false; failure = ?debug_show (e) } };
          case (#ok(r)) {
            switch (r.step) { case (?#event(jev)) ignore recorder.journal(jev); case (_) {} };
            ignore recorder.bank(#settlement(r.event));
            switch (r.event) {
              case (#transferFailed(f)) { { transfer = id; reserved = false; failure = ?f.reason } };
              case (_) { switch (capAlarm(bs, bb, js, now, id)) { case (?a) ignore recorder.bank(#settlement(a)); case null {} }; { transfer = id; reserved = true; failure = null } };
            };
          };
        }
      };
      case (?{ state = #failed }) {
        let reason = switch (SettlementCore.transfer(bs.settlement, sb, id)) {
          case (?t) { switch (sb.get(t.lastBlock)) { case (?(#transferFailed(f))) f.reason; case (_) "the reservation was refused" } };
          case null "the reservation was refused";
        };
        { transfer = id; reserved = false; failure = ?reason }
      };
      case (_) { { transfer = id; reserved = true; failure = null } };
    }
  };

  // ─── FSPIOP: the request engine, shared with the unit battery ───

  /// One FSPIOP request on a rail: read and judged by FspiopCore, acted on through the settlement
  /// layer, answered with the specification's status and the callbacks the relay delivers, and
  /// recorded as one block whatever the outcome.
  public func handleFspiop(bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64, railId : Text, req : FT.Request, recorder : Recorder) : Result.Result<FT.Response, T.BankError> {
    let ?rail = PaymentsCore.rail(bs.payments, railId) else return #err(#PaymentsError({ error = #UnknownRail({ rail = railId }) }));
    switch (requireFeature(bs, ProdT.FEATURE_SETTLEMENT)) { case (?e) return #err(e); case null {} };
    func minorUnitsOf(ccy : Text) : ?Nat8 { for (c in JCore.listCurrencies(js).vals()) { if (Text.equal(c.code, ccy)) return ?c.minorUnits }; null };
    let planned = FspiopCore.handle(bs.fspiop, bs.settlement, railId, rail.scheme, rail.ttlSeconds, req, now, minorUnitsOf);
    let callbacks = List.empty<FT.Callback>();
    func url(dest : Text, endpointType : Text) : ?Text { FspiopCore.endpoint(bs.fspiop, railId, dest, endpointType) };
    func cb(dest : Text, method : Text, path : Text, body : Text, endpointType : Text) { List.add(callbacks, { destination = dest; method; path; body; url = url(dest, endpointType) }) };
    func rec(ev : FT.FspiopEvent) { ignore recorder.bank(#fspiop(ev)) };
    var status = 202;
    var body = "";
    var errorCode : ?Text = null;
    func errorCb(dest : Text, transferId : Text, code : Text, detail : Text) {
      cb(dest, "PUT", "/transfers/" # transferId # "/error", FspiopCore.errorBody(code, detail), "FSPIOP_CALLBACK_URL_TRANSFER_ERROR")
    };
    switch (planned.act) {
      case (#respond(r)) {
        status := r.status; body := r.body;
        switch (Json.parse(r.body)) { case (#ok(j)) { switch (Json.obj(j, "errorInformation")) { case (?ei) errorCode := Json.str(ei, "errorCode"); case null {} } }; case (#err(_)) {} };
      };
      case (#forward(fw)) {
        for (ev in fw.events.vals()) rec(ev);
        let et = FspiopCore.endpointTypeFor(fw.method, fw.path);
        cb(fw.destination, fw.method, fw.path, fw.body, et);
        status := if (planned.method == "PUT") 200 else 202;   // a callback is answered 200; a request (POST, GET, DELETE) is accepted 202
      };
      case (#prepareTransfer(p)) {
        switch (SettlementCore.planPrepare(bs.settlement, rail.scheme, p.payer, p.payee, p.currency, p.amount, p.transferId, now + Nat64.fromNat(p.ttlSeconds) * 1_000_000_000, null)) {
          case (#err(e)) { errorCode := ?"3100"; errorCb(p.payerFsp, p.transferId, "3100", debug_show (e)) };
          case (#ok(ev)) {
            let r = prepareAndReserve(bs, bb, js, journalCaller, now, ev, recorder);
            rec(#transferPrepared({ rail = railId; transferId = p.transferId; transfer = r.transfer; condition = p.condition; expiration = p.expiration; ilpPacketHash = p.ilpPacketHash }));
            if (r.reserved) {
              // the switch forwards the prepare to the payee; the payer hears nothing until the fulfil
              cb(p.payeeFsp, "POST", "/transfers", p.body, "FSPIOP_CALLBACK_URL_TRANSFER_POST");
            } else {
              let reason = switch (r.failure) { case (?x) x; case null "the reservation was refused" };
              rec(#transferAborted({ rail = railId; transferId = p.transferId; transfer = r.transfer; errorCode = "4001"; reason }));
              errorCode := ?"4001";
              errorCb(p.payerFsp, p.transferId, "4001", reason);
            };
          };
        };
      };
      case (#fulfilTransfer(fl)) {
        if (not fl.conditionMet) {
          // Mojaloop's own handler: an invalid fulfilment aborts the transfer (VALIDATION_ERROR, "invalid fulfilment")
          switch (planAbort(bs, js, jb, journalCaller, fl.transfer, #rejected, "invalid fulfilment")) { case (#ok(plan)) ignore run(recorder, plan); case (#err(_)) {} };
          rec(#transferAborted({ rail = railId; transferId = fl.transferId; transfer = fl.transfer; errorCode = "3100"; reason = "invalid fulfilment" }));
          errorCode := ?"3100";
          errorCb(fl.payerFsp, fl.transferId, "3100", "invalid fulfilment");
          errorCb(fl.payeeFsp, fl.transferId, "3100", "invalid fulfilment");
          status := 200;
        } else {
          switch (planFulfil(bs, bb, js, jb, journalCaller, now, fl.transfer)) {
            case (#ok(plan)) {
              ignore run(recorder, plan);
              rec(#transferFulfilled({ rail = railId; transferId = fl.transferId; transfer = fl.transfer; fulfilment = fl.fulfilment; completedAt = fl.completedTimestamp }));
              let notice = Json.emit(#object_([("transferState", #string("COMMITTED")), ("fulfilment", #string(Base64.encodeUrl(fl.fulfilment))), ("completedTimestamp", #string(fl.completedTimestamp))]));
              cb(fl.payerFsp, "PUT", "/transfers/" # fl.transferId, notice, "FSPIOP_CALLBACK_URL_TRANSFER_PUT");
              status := 200;
            };
            case (#err(e)) {
              // a fulfil the settlement layer refuses (no open window, a hold, an expired reservation) is an error to both
              let detail = debug_show (e);
              rec(#transferAborted({ rail = railId; transferId = fl.transferId; transfer = fl.transfer; errorCode = "3100"; reason = detail }));
              errorCode := ?"3100";
              errorCb(fl.payerFsp, fl.transferId, "3100", detail);
              errorCb(fl.payeeFsp, fl.transferId, "3100", detail);
              status := 200;
            };
          };
        };
      };
      case (#abortTransfer(ab)) {
        switch (planAbort(bs, js, jb, journalCaller, ab.transfer, #rejected, ab.errorCode # ": " # ab.reason)) {
          case (#ok(plan)) { ignore run(recorder, plan); rec(#transferAborted({ rail = railId; transferId = ab.transferId; transfer = ab.transfer; errorCode = ab.errorCode; reason = ab.reason })) };
          case (#err(e)) { errorCode := ?"3100"; body := FspiopCore.errorBody("3100", "the transfer cannot be aborted: " # debug_show (e)); status := 400 };
        };
        if (status == 200 or status == 202) {
          let other = switch (planned.source) { case (?srcFsp) { if (srcFsp == ab.payerFsp) ab.payeeFsp else ab.payerFsp }; case null ab.payerFsp };
          errorCb(other, ab.transferId, ab.errorCode, ab.reason);
          status := 200;
        };
      };
      case (#transferStatus(q)) {
        let st = switch (SettlementCore.transferRowOf(bs.settlement, q.transfer)) {
          case (?t) { switch (t.state) { case (#committed or #settled) "COMMITTED"; case (#reserved or #receivedPrepare or #receivedFulfil or #receivedFulfilDependent or #reservedForwarded) "RESERVED"; case (_) "ABORTED" } };
          case null "ABORTED";
        };
        var fields : [(Text, Json.Json)] = [("transferState", #string(st))];
        if (st == "COMMITTED") {
          // the fulfilment the transfer was committed with is in the block its row names
          switch (FspiopCore.transferOf(bs.fspiop, railId, q.transferId)) {
            case (?row) { switch (bb.get(row.resolvedAt)) { case (?{ event = #fspiop(#transferFulfilled(x)) }) { if (x.transferId == q.transferId) fields := Array.concat(fields, [("fulfilment", #string(Base64.encodeUrl(x.fulfilment))), ("completedTimestamp", #string(x.completedAt))]) }; case (_) {} } };
            case null {};
          };
        };
        cb(q.requester, "PUT", "/transfers/" # q.transferId, Json.emit(#object_(fields)), "FSPIOP_CALLBACK_URL_TRANSFER_PUT");
        status := 202;
      };
    };
    let cbs = List.toArray(callbacks);
    rec(#requestHandled({ rail = railId; method = planned.method; path = planned.path; source = planned.source; destination = planned.destination; hash = Sha256.fromBlob(#sha256, Text.encodeUtf8(req.body)); status; errorCode; callbacks = cbs.size() }));
    #ok({ status; body; callbacks = cbs })
  };

  // ─── ISO 20022 messaging: the ingest engine, shared with the unit battery ───

  public type IngestResult = { message : Nat; family : PayT.Family; verdict : PayT.Verdict; issues : [PayT.Issue]; outcomes : [PayT.Outcome] };

  /// How a rail's connector signatures are checked: the scheme, the registered public key, the
  /// message bytes and the signature. The actor supplies the post-quantum verifiers; the unit battery
  /// supplies what it proves with.
  public type Verify = (PayT.SignatureScheme, Blob, Blob, Blob) -> Bool;

  /// One received message, whatever its verdict, recorded as one block after the acts it asked for.
  /// A liquidity credit transfer (camt.050): the participant's settlement account to its position
  /// (`toPosition`: more headroom under the cap, the way a settlement's net-sender posting moves it)
  /// or the position back to the settlement account — one posting between the two sub-ledgers.
  func planLiquidity(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, scheme : SeT.SchemeId, railId : Text, l : { endToEndId : Text; participant : Nat; currency : Text; amount : Nat; toPosition : Bool }) : Result.Result<JT.Event, T.BankError> {
    switch (requireFeature(bs, ProdT.FEATURE_ACCOUNT_MONEY)) { case (?e) return #err(e); case null {} };
    let (_, accts) = switch (SettlementCore.activeAccounts(bs.settlement, l.participant, l.currency)) { case (#err(e)) return #err(#SettlementError({ error = e })); case (#ok(v)) v };
    let today = JCore.effectiveToday(js, now);
    let (setControl, setSub) = switch (participantLeg(bs, bb, js, accts.settlement, today)) { case (#err(e)) return #err(e); case (#ok(v)) v };
    let (posControl, posSub) = switch (participantLeg(bs, bb, js, accts.position, today)) { case (#err(e)) return #err(e); case (#ok(v)) v };
    let ?period = periodContaining(js, today) else return #err(#ProductError({ error = #InvalidTerms({ reason = "no open period contains today" }) }));
    let legs = if (l.toPosition) [Posting.leg(setControl, ?setSub, #debit, l.currency, l.amount), Posting.leg(posControl, ?posSub, #credit, l.currency, l.amount)]
               else [Posting.leg(posControl, ?posSub, #debit, l.currency, l.amount), Posting.leg(setControl, ?setSub, #credit, l.currency, l.amount)];
    let input : JT.PostingInput = {
      idempotencyKey = Posting.key("LIQUIDITY_TRANSFER", [scheme, railId, l.endToEndId]);
      postingDate = today; valueDate = today; period; legs;
      sourceRef = { kind = "LIQUIDITY_TRANSFER"; id = railId # "/" # l.endToEndId }; narration = "liquidity transfer " # l.endToEndId # (if (l.toPosition) " to the position" else " to the settlement account"); correctionOf = null;
    };
    switch (JCore.preparePost(js, journalCaller, now, input)) {
      case (#err(e)) #err(#JournalError({ error = e }));
      case (#ok(#duplicate(idx))) #err(#JournalError({ error = #IdempotencyKeyReused({ existing = idx }) }));
      case (#ok(#event(ev))) #ok(ev);
    }
  };

  public func ingestMessage(bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64, railId : PayT.RailId, bytes : Blob, signature : ?Blob, verify : Verify, recorder : Recorder) : Result.Result<IngestResult, T.BankError> {
    let sb : SettlementCore.Blocks = { get = func(i : Nat) : ?SeT.SettlementEvent { switch (bb.get(i)) { case (?b) { switch (b.event) { case (#settlement(se)) ?se; case (_) null } }; case null null } } };
    let ?rail = PaymentsCore.rail(bs.payments, railId) else return #err(#PaymentsError({ error = #UnknownRail({ rail = railId }) }));
    switch (requireFeature(bs, ProdT.FEATURE_SETTLEMENT)) { case (?e) return #err(e); case null {} };
    func minorUnitsOf(ccy : Text) : ?Nat8 { for (c in JCore.listCurrencies(js).vals()) { if (Text.equal(c.code, ccy)) return ?c.minorUnits }; null };
    func accountOfId(id : Text) : ?Nat { ProductCore.byIdentifier(bs.product, id) };
    var parsed = switch (PaymentsCore.planIngest(bs.payments, bs.settlement, sb, railId, bytes, minorUnitsOf, accountOfId)) { case (#err(e)) return #err(#PaymentsError({ error = e })); case (#ok(p)) p };
    // the connector's signature, when the rail requires one: over the bytes, by the header's sender.
    // It is judged before anything else the message says (a duplicate included): a message that is
    // not the connector's is refused as such, whatever it carries
    if (rail.signatures != #none) {
      let sigIssue : ?PayT.Issue = switch (parsed.signer) {
        case null ?{ rule = "ISO-SIG-SIGNER"; path = "/AppHdr/Fr"; detail = "a signed rail needs the Business Application Header naming the sender" };
        case (?bic) {
          switch (PaymentsCore.connectorKey(bs.payments, railId, bic)) {
            case null ?{ rule = "ISO-SIG-UNKNOWN-CONNECTOR"; path = "/AppHdr/Fr"; detail = "no connector key registered for " # bic # " on rail " # railId };
            case (?key) {
              if (key.scheme != rail.signatures) ?{ rule = "ISO-SIG-SCHEME"; path = "$signature"; detail = "the connector's key is " # PayT.schemeName(key.scheme) # ", the rail requires " # PayT.schemeName(rail.signatures) }
              else switch (signature) {
                case null ?{ rule = "ISO-SIG-REQUIRED"; path = "$signature"; detail = "rail " # railId # " requires a " # PayT.schemeName(rail.signatures) # " signature" };
                case (?sig) { if (verify(rail.signatures, key.publicKey, bytes, sig)) null else ?{ rule = "ISO-SIG-INVALID"; path = "$signature"; detail = "the " # PayT.schemeName(rail.signatures) # " signature does not verify over the message bytes" } };
              };
            };
          }
        };
      };
      switch (sigIssue) { case (?i) parsed := { parsed with issues = [i]; acts = [] }; case null {} };
    };
    let outcomes = List.empty<PayT.Outcome>();
    for (act in parsed.acts.vals()) {
      switch (act) {
        case (#prepare(p)) {
          switch (SettlementCore.planPrepareLinked(bs.settlement, rail.scheme, p.payer, p.payee, p.currency, p.amount, p.uetr, now + Nat64.fromNat(rail.ttlSeconds) * 1_000_000_000, null, p.correctionOf)) {
            case (#err(e)) List.add(outcomes, #refused({ uetr = ?p.uetr; rule = "ISO-BIZ-PREPARE"; detail = debug_show (e) }));
            case (#ok(ev)) {
              let r = prepareAndReserve(bs, bb, js, journalCaller, now, ev, recorder);
              switch (p.originalTransfer) {
                case (?original) {
                  // a return is an instruction, not a proposal: reserved and posted in this message
                  var committed = false;
                  if (r.reserved) { switch (planFulfil(bs, bb, js, jb, journalCaller, now, r.transfer)) { case (#ok(plan)) { ignore run(recorder, plan); committed := true }; case (#err(e)) List.add(outcomes, #refused({ uetr = ?p.uetr; rule = "ISO-BIZ-RETURN-POST"; detail = debug_show (e) })) } };
                  List.add(outcomes, #returned({ uetr = p.uetr; original; transfer = r.transfer; reserved = r.reserved; committed }));
                };
                case null {
                  switch (p.hold, r.reserved) {
                    case (?rule, true) List.add(outcomes, #held({ uetr = p.uetr; transfer = r.transfer; rule }));
                    case (_, _) List.add(outcomes, #prepared({ uetr = p.uetr; transfer = r.transfer; reserved = r.reserved }));
                  };
                };
              };
            };
          };
        };
        case (#fulfil(f)) {
          switch (planFulfil(bs, bb, js, jb, journalCaller, now, f.transfer)) {
            case (#ok(plan)) { ignore run(recorder, plan); List.add(outcomes, #fulfilled({ uetr = f.uetr; transfer = f.transfer })) };
            case (#err(e)) List.add(outcomes, #refused({ uetr = ?f.uetr; rule = "ISO-BIZ-FULFIL"; detail = debug_show (e) }));
          };
        };
        case (#reject(x)) {
          switch (planAbort(bs, js, jb, journalCaller, x.transfer, #rejected, x.reason)) {
            case (#ok(plan)) { ignore run(recorder, plan); List.add(outcomes, #rejected({ uetr = x.uetr; transfer = x.transfer; reason = x.reason })) };
            case (#err(e)) List.add(outcomes, #refused({ uetr = ?x.uetr; rule = "ISO-BIZ-REJECT"; detail = debug_show (e) }));
          };
        };
        case (#acknowledge(a)) List.add(outcomes, #acknowledged({ uetr = a.uetr; transfer = a.transfer; status = a.status }));
        case (#refuse(x)) List.add(outcomes, #refused({ uetr = x.uetr; rule = x.rule; detail = x.detail }));
        // ── the extended target list ──
        case (#reverse(rv)) {
          // a reversal is an instruction like a return: the correcting transfer reserved and posted here
          switch (SettlementCore.planPrepareLinked(bs.settlement, rail.scheme, rv.payer, rv.payee, rv.currency, rv.amount, rv.uetr, now + Nat64.fromNat(rail.ttlSeconds) * 1_000_000_000, null, ?rv.correctionOf)) {
            case (#err(e)) List.add(outcomes, #refused({ uetr = ?rv.uetr; rule = "ISO-BIZ-PREPARE"; detail = debug_show (e) }));
            case (#ok(ev)) {
              let r = prepareAndReserve(bs, bb, js, journalCaller, now, ev, recorder);
              var committed = false;
              if (r.reserved) { switch (planFulfil(bs, bb, js, jb, journalCaller, now, r.transfer)) { case (#ok(plan)) { ignore run(recorder, plan); committed := true }; case (#err(e)) List.add(outcomes, #refused({ uetr = ?rv.uetr; rule = "ISO-BIZ-REVERSAL-POST"; detail = debug_show (e) })) } };
              List.add(outcomes, #reversed({ uetr = rv.uetr; original = rv.original; transfer = r.transfer; reserved = r.reserved; committed; reason = rv.reason }));
            };
          };
        };
        case (#collect(c)) {
          switch (SettlementCore.planPrepareLinked(bs.settlement, rail.scheme, c.payer, c.payee, c.currency, c.amount, c.uetr, now + Nat64.fromNat(rail.ttlSeconds) * 1_000_000_000, null, null)) {
            case (#err(e)) List.add(outcomes, #refused({ uetr = ?c.uetr; rule = "ISO-BIZ-PREPARE"; detail = debug_show (e) }));
            case (#ok(ev)) {
              let r = prepareAndReserve(bs, bb, js, journalCaller, now, ev, recorder);
              switch (c.hold, r.reserved) {
                case (?rule, true) { List.add(outcomes, #held({ uetr = c.uetr; transfer = r.transfer; rule })); List.add(outcomes, #collected({ uetr = c.uetr; transfer = r.transfer; reserved = true; authority = c.authority; final = c.final })) };
                case (_, _) List.add(outcomes, #collected({ uetr = c.uetr; transfer = r.transfer; reserved = r.reserved; authority = c.authority; final = c.final }));
              };
            };
          };
        };
        case (#mandate(o)) List.add(outcomes, o);
        case (#record(o)) List.add(outcomes, o);
        case (#settlementRequest(q)) {
          switch (SettlementCore.planOpenSettlement(bs.settlement, q.window)) {
            case (#err(e)) List.add(outcomes, #refused({ uetr = ?q.cycle; rule = "ISO-BIZ-SETTLEMENT-OPEN"; detail = debug_show (e) }));
            case (#ok(ev)) {
              let sid = recorder.bank(#settlement(ev));
              List.add(outcomes, #settlementRequested({ window = q.window; settlement = sid; cycle = q.cycle; movements = q.movements }));
            };
          };
        };
        case (#liquidity(l)) {
          switch (planLiquidity(bs, bb, js, journalCaller, now, rail.scheme, railId, l)) {
            case (#err(e)) List.add(outcomes, #refused({ uetr = ?l.endToEndId; rule = "ISO-BIZ-LIQUIDITY"; detail = debug_show (e) }));
            case (#ok(jev)) { let posting = recorder.journal(jev); List.add(outcomes, #liquidityTransferred({ endToEndId = l.endToEndId; participant = l.participant; currency = l.currency; amount = l.amount; toPosition = l.toPosition; posting })) };
          };
        };
        case (#file(f)) {
          // every payload is a message of its own, recorded before the file's own record
          let ids = List.empty<Nat>();
          for (pl in f.payloads.vals()) {
            switch (ingestMessage(bs, bb, js, jb, journalCaller, now, railId, pl, null, verify, recorder)) {
              case (#ok(r)) List.add(ids, r.message);
              case (#err(e)) List.add(outcomes, #refused({ uetr = null; rule = "ISO-BIZ-FILE-PAYLOAD"; detail = debug_show (e) }));
            };
          };
          List.add(outcomes, #fileReceived({ payloadId = f.payloadId; declared = f.declared; messages = List.toArray(ids) }));
        };
      };
    };
    // a mandate initiated here is its own block: the record names the block about to be written
    let fixed = Array.map<PayT.Outcome, PayT.Outcome>(List.toArray(outcomes), func(o) { switch (o) { case (#mandateInitiated(m)) { if (m.mandate == 0) #mandateInitiated({ m with mandate = bs.height }) else o }; case (_) o } });
    let ev = PaymentsCore.received(railId, parsed, bytes, fixed);
    let message = recorder.bank(#payments(ev));
    switch (ev) {
      case (#messageReceived(m)) #ok({ message; family = m.family; verdict = m.verdict; issues = m.issues; outcomes = m.outcomes });
      case (_) Runtime.trap("BankCore: the message record is not a message record");
    }
  };

  /// The acts a lifted hold asks for, performed through the recorder: a release posts the held
  /// transfer, a rejection voids it (`Bank.paymentsOnEvent`, and the unit battery's mirror).
  public func settleHold(bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64, e : PayT.PaymentsEvent, recorder : Recorder) : Result.Result<(), T.BankError> {
    switch (e) {
      case (#holdReleased(x)) { switch (planFulfil(bs, bb, js, jb, journalCaller, now, x.transfer)) { case (#ok(plan)) { ignore run(recorder, plan); #ok(()) }; case (#err(err)) #err(err) } };
      case (#holdRejected(x)) { switch (planAbort(bs, js, jb, journalCaller, x.transfer, #rejected, "hold rejected: " # x.reason)) { case (#ok(plan)) { ignore run(recorder, plan); #ok(()) }; case (#err(err)) #err(err) } };
      case (_) #ok(());
    }
  };

  public func holdOfTransfer(bs : State, transfer : Nat) : ?Text { PaymentsCore.holdOf(bs.payments, transfer) };

  /// The pacs.002 answering a received message, and a validation of any message against its
  /// family's schema-derived profile (a read: nothing is recorded).
  public func statusReportXml(bs : State, bb : Blocks, now : Nat64, messageId : Nat) : ?Text {
    let pb : PaymentsCore.Blocks = { get = func(i : Nat) : ?PayT.PaymentsEvent { switch (bb.get(i)) { case (?b) { switch (b.event) { case (#payments(pe)) ?pe; case (_) null } }; case null null } } };
    let ?m = PaymentsCore.message(bs.payments, pb, messageId) else return null;
    // a message refused before its id could be read is named by the hash of its bytes; a refusal with
    // no transaction to answer for is a group status
    let originalId = if (Text.size(m.messageId) > 0) m.messageId else "SHA256:" # IsoMessages.clip(JC.hex(m.hash), 16);
    let originalName = switch (m.family) { case (#unknown) "unknown"; case (f) PayT.familyName(f) };
    let lines = PaymentsCore.statusLines(m);
    let group : ?IsoMessages.GroupStatus = if (m.verdict == #refused and lines.size() == 0) {
      let first = if (m.issues.size() > 0) ?m.issues[0] else null;
      ?{ status = "RJCT"; reasonProprietary = switch (first) { case (?i) ?i.rule; case null ?"REFUSED" }; additionalInfo = switch (first) { case (?i) ?(i.path # ": " # i.detail); case null null } }
    } else null;
    ?IsoMessages.pacs002Xml("PACS002-" # Nat.toText(messageId), IsoMessages.isoDateTime(now), originalId, originalName, group, lines)
  };

  public func validateMessage(bytes : Blob) : { family : Text; issues : [PayT.Issue] } {
    switch (Xml.parseMessage(bytes)) {
      case (#err(e)) { { family = "unknown"; issues = [{ rule = e.rule; path = "$xml@" # Nat.toText(e.offset); detail = e.detail }] } };
      case (#ok(roots)) {
        let out = List.empty<PayT.Issue>();
        var family = "unknown";
        // two elements are a business message only when the first is the header
        if (roots.size() == 2 and PayT.familyOf(roots[0].namespace) != #head001) return { family; issues = [{ rule = "XML-ROOT"; path = "/" # roots[1].name; detail = "content after the root element (a two-element message is an AppHdr followed by a Document)" }] };
        for (root in roots.vals()) {
          switch (IsoSchema.schemaFor(root.namespace)) {
            case (?sc) { if (root.name == "Document" or root.name == "Xchg") family := sc.family; for (i in IsoSchema.validate(sc, root).vals()) List.add(out, { rule = i.rule; path = i.path; detail = i.detail }) };
            case null List.add(out, { rule = "ISO-XSD-ROOT"; path = "/" # root.name; detail = "namespace " # root.namespace # " is not a family this component carries" });
          };
          // a business file (head.002) carries its payloads under a lax `xs:any`: the verdict on the file is
          // the header's and every payload's against its own schema, the way the ingest reads them
          if (root.name == "Xchg" and PayT.familyOf(root.namespace) == #head002) {
            var j = 0;
            for (pl in Xml.children(root, "Pyld").vals()) {
              for (payload in pl.children.vals()) {
                let prefix = "/Xchg/Pyld[" # Nat.toText(j + 1) # "]";
                switch (IsoSchema.schemaFor(payload.namespace)) {
                  case (?sc) { for (i in IsoSchema.validate(sc, payload).vals()) List.add(out, { rule = i.rule; path = prefix # i.path; detail = i.detail }) };
                  case null List.add(out, { rule = "ISO-XSD-ROOT"; path = prefix # "/" # payload.name; detail = "namespace " # payload.namespace # " is not a family this component carries" });
                };
              };
              j += 1;
            };
          };
        };
        { family; issues = List.toArray(out) }
      };
    }
  };

  public type BulkAdvance = { bulk : Nat; state : Text; work : Nat; done : Bool };

  /// A bulk's items prepared and reserved (RECEIVED → PENDING_PREPARE → ACCEPTED, or REJECTED when
  /// every item failed), committed after `fulfilBulk` (PROCESSING → PENDING_FULFIL → COMPLETED), or
  /// voided after `rejectBulk` (ABORTING → REJECTED), a chunk at a time. A re-driven bulk finds
  /// nothing left to do.
  public func advanceBulk(bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64, bulkId : Nat, limit : Nat, recorder : Recorder) : Result.Result<BulkAdvance, T.BankError> {
    let sb : SettlementCore.Blocks = { get = func(i : Nat) : ?SeT.SettlementEvent { switch (bb.get(i)) { case (?b) { switch (b.event) { case (#settlement(se)) ?se; case (_) null } }; case null null } } };
    let ?b = SettlementCore.bulk(bs.settlement, sb, bulkId) else return #err(#SettlementError({ error = #UnknownBulk({ bulk = bulkId }) }));
    let n = Nat.min(Nat.max(limit, 1), 500);
    func reply(work : Nat, done : Bool) : Result.Result<BulkAdvance, T.BankError> {
      let ?b2 = SettlementCore.bulkRowOf(bs.settlement, bulkId) else Runtime.trap("BankCore: the bulk vanished");
      #ok({ bulk = bulkId; state = SeT.bulkStateName(b2.state); work; done })
    };
    func move(to : SeT.BulkState, processing : SeT.BulkProcessingState, prepared : Nat, done : Nat, failures : [(Nat, Text)]) : ?T.BankError {
      switch (SettlementCore.planBulkTransition(bs.settlement, bulkId, to, processing, prepared, done, failures)) { case (#ok(ev)) { ignore recorder.bank(#settlement(ev)); null }; case (#err(e)) ?#SettlementError({ error = e }) }
    };
    func reservedItems() : [Nat] {
      let page = SettlementCore.bulkTransferIds(bs.settlement, bulkId, null, 100_000);
      Array.filter<Nat>(page.ids, func(id) { switch (SettlementCore.transferRowOf(bs.settlement, id)) { case (?t) t.state == #reserved; case null false } })
    };
    switch (b.state) {
      case (#received) { switch (move(#pendingPrepare, #accepted, 0, 0, [])) { case (?e) #err(e); case null reply(0, false) } };
      case (#pendingPrepare) {
        var i = b.prepared;
        var work = 0;
        let failures = List.fromArray<(Nat, Text)>(b.failures);
        while (i < b.requests.size() and work < n) {
          let q = b.requests[i];
          switch (SettlementCore.planPrepare(bs.settlement, b.scheme, b.payer, q.payee, q.currency, q.amount, b.reference # "/" # q.reference, now + Nat64.fromNat(b.ttlSeconds) * 1_000_000_000, ?bulkId)) {
            case (#err(e)) List.add(failures, (i, debug_show (e)));
            case (#ok(ev)) {
              // the item's prepare, then its reservation — the same two acts the single transfer makes
              let r = prepareAndReserve(bs, bb, js, journalCaller, now, ev, recorder);
              switch (r.failure) { case (?reason) List.add(failures, (i, reason)); case null {} };
            };
          };
          i += 1; work += 1;
        };
        if (i >= b.requests.size()) {
          let failed = List.size(failures);
          let allFailed = failed == b.requests.size();
          switch (move(if (allFailed) #rejected else #accepted, if (allFailed) #receivedInvalid else #accepted, i, 0, List.toArray(failures))) { case (?e) #err(e); case null reply(work, allFailed) }
        } else {
          switch (move(#pendingPrepare, #accepted, i, 0, List.toArray(failures))) { case (?e) #err(e); case null reply(work, false) }
        }
      };
      case (#processing) {
        var done = b.done;
        var work = 0;
        let failures = List.fromArray<(Nat, Text)>(b.failures);
        label items for (id in reservedItems().vals()) {
          if (work >= n) break items;
          switch (planFulfil(bs, bb, js, jb, journalCaller, now, id)) {
            case (#ok(plan)) { ignore run(recorder, plan); done += 1 };
            case (#err(e)) { List.add(failures, (id, debug_show (e))); done += 1 };
          };
          work += 1;
        };
        if (reservedItems().size() == 0) {
          switch (move(#pendingFulfil, #completed, b.prepared, done, List.toArray(failures))) { case (?e) return #err(e); case null {} };
          switch (move(#completed, #completed, b.prepared, done, List.toArray(failures))) { case (?e) #err(e); case null reply(work, true) }
        } else { switch (move(#processing, #processing, b.prepared, done, List.toArray(failures))) { case (?e) #err(e); case null reply(work, false) } }
      };
      case (#aborting) {
        var work = 0;
        label items for (id in reservedItems().vals()) {
          if (work >= n) break items;
          switch (planAbort(bs, js, jb, journalCaller, id, #rejected, "the bulk was rejected")) { case (#ok(plan)) ignore run(recorder, plan); case (#err(_)) {} };
          work += 1;
        };
        if (reservedItems().size() == 0) { switch (move(#rejected, #rejected, b.prepared, b.done, b.failures)) { case (?e) #err(e); case null reply(work, true) } } else reply(work, false)
      };
      // ACCEPTED rests until `fulfilBulk` or `rejectBulk`; the terminal states rest for good
      case (#accepted or #completed or #rejected or #invalid or #expired) reply(0, true);
      case (st) #err(#SettlementError({ error = #BulkNotIn({ bulk = bulkId; state = SeT.bulkStateName(st); expected = "RECEIVED, PENDING_PREPARE, PROCESSING or ABORTING" }) }));
    }
  };

  public func periodOfDay(js : JCore.State, day : Nat) : ?Text { periodContaining(js, day) };
  func periodContaining(js : JCore.State, day : Nat) : ?Text {
    for (p in JCore.listPeriods(js).vals()) { if (p.status == #open and p.start <= day and day <= p.end) return ?p.id };
    null
  };

  /// The sending shard's side on acknowledgement: the pending posted, under its reserved dates when
  /// its period is still open and under today's otherwise.
  public func planSettleShardTransfer(bs : State, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64, caller : Principal, id : Nat, receiverPosting : Nat) : Result.Result<{ event : ST.ShardEvent; step : JT.Event }, T.BankError> {
    let (ev, t) = switch (ShardCore.planSettle(bs.shard, caller, id, receiverPosting)) { case (#err(e)) return #err(#ShardError({ error = e })); case (#ok(x)) x };
    let today = JCore.effectiveToday(js, now);
    let override : ?JT.Resolution = switch (JCore.getPeriod(js, t.period)) {
      case (?p) { if (p.status == #open and today >= p.start and today <= p.end) null else { switch (periodContaining(js, today)) { case (?op) ?{ postingDate = today; valueDate = today; valueDateRequested = null; period = op }; case null null } } };
      case null null;
    };
    switch (JCore.preparePostPending(js, jb, journalCaller, now, t.pendingIndex, override)) {
      case (#err(e)) #err(#JournalError({ error = e }));
      case (#ok(#expired(x))) #err(#JournalError({ error = #PendingExpired({ index = t.pendingIndex; expiresAt = x.expiresAt; voidedBy = 0 }) }));
      case (#ok(#event(step))) #ok({ event = ev; step });
    }
  };

  /// The sending shard's side on refusal: the pending voided, the customer's money released.
  public func planReturnShardTransfer(bs : State, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, caller : Principal, id : Nat, reason : Text) : Result.Result<{ event : ST.ShardEvent; step : JT.Event }, T.BankError> {
    let (ev, t) = switch (ShardCore.planReturn(bs.shard, caller, id, reason)) { case (#err(e)) return #err(#ShardError({ error = e })); case (#ok(x)) x };
    switch (JCore.prepareVoidPending(js, jb, journalCaller, t.pendingIndex)) {
      case (#err(e)) #err(#JournalError({ error = e }));
      case (#ok(step)) #ok({ event = ev; step });
    }
  };

  /// A posting touching two shards is refused: every sub-ledger a posting names must be an account
  /// or a till this shard holds. Stated in `ShardTypes.mo`; checked on every journal step planned.
  func foreignLeg(bs : State, legs : [JT.Leg], introduced : [JT.SubledgerKey]) : ?T.BankError {
    for (l in legs.vals()) {
      switch (l.subledger) {
        case (?sub) {
          // an account or a till of this shard, one of its books' vaults in the leg's currency, a facility's or a
          // participant's (corporate lending), or an account the same plan opens — the only sub-ledgers a shard's own postings name
          var held = ProductCore.holdsSubledger(bs.product, sub) or FacilityCore.holdsSubledger(bs.facility, sub) or TellerCore.holdsSubledger(bs.teller, sub) or TradeCore.holdsSubledger(bs.trade, sub) or IslamicCore.holdsSubledger(bs.islamic, sub);
          if (not held) { for (i in introduced.vals()) { if (i == sub) held := true } };
          if (not held) { for ((book, _) in Map.entries(bs.books)) { if (sub == Till.vaultSubledger(book, l.currency)) held := true } };
          if (not held) return ?#ShardError({ error = #NotRouted({ identifier = ""; reason = "the posting names a sub-ledger this shard does not hold" }) });
        };
        case null {};
      };
    };
    null
  };

  func planCommandInner(bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64, command : T.Command, authorityIndex : Nat) : Result.Result<Plan, T.BankError> {
    let authId = Nat.toText(authorityIndex);
    switch (command) {

      // ── entitlements and organisation ──
      case (#defineRole(x)) {
        if (not validIdentifier(x.id, T.MAX_ROLE_ID_BYTES)) return #err(#InvalidRole({ reason = "role id must be 1.." # Nat.toText(T.MAX_ROLE_ID_BYTES) # " characters of [A-Za-z0-9-_.]" }));
        if (Text.encodeUtf8(x.name).size() > T.MAX_NAME_BYTES) return #err(#InvalidRole({ reason = "name exceeds the bound" }));
        if (Map.containsKey(bs.roles, Text.compare, x.id)) return #err(#RoleExists({ role = x.id }));
        if (x.permissions.size() == 0) return #err(#InvalidRole({ reason = "a role with no permissions cannot do anything; define it with at least one" }));
        if (x.permissions.size() > T.MAX_PERMISSIONS_PER_ROLE) return #err(#InvalidRole({ reason = "permission list exceeds the bound" }));
        var i = 0;
        while (i < x.permissions.size()) {
          if (not P.exists(x.permissions[i])) return #err(#UnknownPermission({ permission = x.permissions[i] }));
          var j = i + 1;
          while (j < x.permissions.size()) {
            if (Text.equal(x.permissions[i], x.permissions[j])) return #err(#InvalidRole({ reason = "duplicate permission " # x.permissions[i] }));
            j += 1;
          };
          i += 1;
        };
        #ok({ bankEvent = ?#roleDefined({ id = x.id; name = x.name; permissions = x.permissions }); extra = []; journal = [] })
      };

      case (#grantRole(x)) {
        if (Principal.isAnonymous(x.subject)) return #err(#InvalidScope({ reason = "the anonymous principal cannot hold a grant" }));
        if (not Map.containsKey(bs.roles, Text.compare, x.role)) return #err(#UnknownRole({ role = x.role }));
        if (Map.containsKey(bs.grants, cmpPR, (x.subject, x.role))) return #err(#GrantExists({ subject = x.subject; role = x.role }));
        switch (E.validateScope(x.scope)) { case (?r) return #err(#InvalidScope({ reason = r })); case null {} };
        switch (x.scope.books) {
          case (?books) {
            for (b in books.vals()) {
              if (not Map.containsKey(bs.books, Text.compare, b)) return #err(#UnknownBook({ book = b }));
            };
          };
          case null {};
        };
        #ok({ bankEvent = ?#roleGranted({ subject = x.subject; role = x.role; scope = x.scope }); extra = []; journal = [] })
      };

      case (#revokeRole(x)) {
        if (not Map.containsKey(bs.grants, cmpPR, (x.subject, x.role))) return #err(#UnknownGrant({ subject = x.subject; role = x.role }));
        // Revoking the last holder of a role that a policy names as eligible
        // would leave that policy unsatisfiable. Refuse here rather than leave a
        // queue nobody can clear.
        for ((_, pol) in Map.entries(bs.policies)) {
          if (Text.equal(pol.eligibleRole, x.role)) {
            if (roleHolderCount(bs, x.role) <= pol.required) {
              return #err(#InvalidPolicy({ reason = "policy for " # pol.permission # " requires " # Nat.toText(pol.required) # " approvals from role " # x.role # "; revoking this grant would leave too few holders" }));
            };
          };
        };
        #ok({ bankEvent = ?#roleRevoked({ subject = x.subject; role = x.role }); extra = []; journal = [] })
      };

      case (#setDualPolicy(x)) {
        let exists = P.exists(x.permission);
        let roleExists = Map.containsKey(bs.roles, Text.compare, x.eligibleRole);
        switch (MC.validatePolicy(x, exists, roleExists, roleHolderCount(bs, x.eligibleRole))) {
          case (?r) return #err(#InvalidPolicy({ reason = r }));
          case null {};
        };
        #ok({ bankEvent = ?#dualPolicySet(x); extra = []; journal = [] })
      };

      case (#clearDualPolicy(x)) {
        switch (policyFor(bs, x.permission)) {
          case null return #err(#InvalidPolicy({ reason = "no policy recorded for " # x.permission }));
          case (?_) {};
        };
        // A money-moving permission may never be taken below dual control.
        switch (P.find(x.permission)) {
          case (?perm) {
            if (perm.moneyMoving) {
              return #err(#InvalidPolicy({ reason = "permission " # x.permission # " is money-moving; its dual-authorisation policy may be raised or re-pointed but not cleared" }));
            };
          };
          case null return #err(#UnknownPermission({ permission = x.permission }));
        };
        #ok({ bankEvent = ?#dualPolicyCleared({ permission = x.permission }); extra = []; journal = [] })
      };

      case (#openBook(x)) {
        if (not validIdentifier(x.id, T.MAX_BOOK_ID_BYTES)) return #err(#InvalidBook({ reason = "book id must be 1.." # Nat.toText(T.MAX_BOOK_ID_BYTES) # " characters of [A-Za-z0-9-_.]" }));
        if (Text.encodeUtf8(x.name).size() > T.MAX_NAME_BYTES) return #err(#InvalidBook({ reason = "name exceeds the bound" }));
        if (Map.containsKey(bs.books, Text.compare, x.id)) return #err(#BookExists({ book = x.id }));
        switch (x.parent) {
          case (?p) {
            switch (Map.get(bs.books, Text.compare, p)) {
              case null return #err(#UnknownBook({ book = p }));
              case (?b) { if (b.status == #closed) return #err(#BookClosed({ book = p })) };
            };
            if (not bookDepthOk(bs, x.parent)) return #err(#InvalidBook({ reason = "book tree deeper than " # Nat.toText(T.MAX_BOOK_DEPTH) }));
          };
          case null {};
        };
        #ok({ bankEvent = ?#bookOpened({ id = x.id; name = x.name; parent = x.parent }); extra = []; journal = [] })
      };

      case (#closeBook(x)) {
        switch (Map.get(bs.books, Text.compare, x.id)) {
          case null return #err(#UnknownBook({ book = x.id }));
          case (?b) { if (b.status == #closed) return #err(#BookClosed({ book = x.id })) };
        };
        let kids = childCount(bs, x.id);
        if (kids > 0) return #err(#BookHasChildren({ book = x.id; children = kids }));
        #ok({ bankEvent = ?#bookClosed({ id = x.id }); extra = []; journal = [] })
      };

      case (#transferBankAdmin(x)) {
        if (Principal.isAnonymous(x.admin)) return #err(#InvalidScope({ reason = "the anonymous principal cannot be the bank administrator" }));
        #ok({ bankEvent = ?#bankAdminTransferred({ admin = x.admin }); extra = []; journal = [] })
      };

      case (#setFeatureActivation(x)) {
        if (not validIdentifier(x.feature, T.MAX_ROLE_ID_BYTES)) return #err(#InvalidFeature({ reason = "feature id must be 1.." # Nat.toText(T.MAX_ROLE_ID_BYTES) # " characters of [A-Za-z0-9-_.]" }));
        // A money-visible feature cannot be activated while the journal beneath
        // it is inactive: the postings it would make could not be admitted.
        if (x.height != T.ACTIVATION_OFF and not JCore.isActive(js)) {
          return #err(#FeatureInactive({ feature = x.feature; activationHeight = x.height; height = Nat64.fromNat(bs.height) }));
        };
        #ok({ bankEvent = ?#featureActivationSet({ feature = x.feature; height = x.height }); extra = []; journal = [] })
      };

      // ── the embedded journal's configuration ──
      case (#journalRegisterCurrency(x)) journalConfig(JCore.prepareRegisterCurrency(js, journalCaller, x.code, x.minorUnits));
      case (#journalOpenAccount(x)) journalConfig(JCore.prepareOpenAccount(js, journalCaller, x.code, x.name, x.normalSide, x.category, x.constraint));
      case (#journalCloseAccount(x)) journalConfig(JCore.prepareCloseAccount(js, journalCaller, x.code));
      case (#journalOpenPeriod(x)) journalConfig(JCore.prepareOpenPeriod(js, journalCaller, x.id, x.start, x.end));
      case (#journalClosePeriod(x)) journalConfig(JCore.prepareClosePeriod(js, journalCaller, x.id));
      case (#journalSetActivationHeight(x)) journalConfig(JCore.prepareSetActivationHeight(js, journalCaller, x.height));
      case (#journalSetLeadsheetSchema(x)) journalConfig(JCore.prepareSetLeadsheetSchema(js, journalCaller, x.ranges));
      case (#journalAddPoster(x)) journalConfig(JCore.prepareAddPoster(js, journalCaller, x.poster));
      case (#journalRemovePoster(x)) journalConfig(JCore.prepareRemovePoster(js, journalCaller, x.poster));
      case (#journalSetPosterScope(x)) journalConfig(JCore.prepareSetPosterScope(js, journalCaller, x.poster, x.accounts));
      case (#journalRollBusinessDate(x)) journalConfig(JCore.prepareRollBusinessDate(js, journalCaller, now, x.day));
      case (#journalSetCalendar(x)) journalConfig(JCore.prepareSetCalendar(js, journalCaller, x.calendar));
      case (#journalSetCalendarAuthority(x)) journalConfig(JCore.prepareSetCalendarAuthority(js, journalCaller, x.authority, x.maxRollDays, x.businessDate));

      // ── money ──
      case (#postManualEntry(x)) {
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        let input : JT.PostingInput = {
          idempotencyKey = x.idempotencyKey;
          postingDate = x.postingDate;
          valueDate = x.valueDate;
          period = x.period;
          legs = x.legs;
          sourceRef = { kind = "manual"; id = authId };
          narration = x.narration;
          correctionOf = x.correctionOf;
        };
        switch (JCore.preparePost(js, journalCaller, now, input)) {
          case (#err(e)) #err(#JournalError({ error = e }));
          case (#ok(#event(e))) #ok({ bankEvent = null; extra = []; journal = [#event(e)] });
          case (#ok(#duplicate(idx))) #ok({ bankEvent = null; extra = []; journal = [#existing(idx)] });
        }
      };

      // ── party / CIF and KYC ──
      case (#createParty(x)) {
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        if (not Commit.validSalt(x.salt)) return #err(#PartyError({ error = #InvalidCommitment({ reason = "the salt must be 32 bytes" }) }));
        if (not Commit.validCommitment(x.identityCommit)) return #err(#PartyError({ error = #InvalidCommitment({ reason = "the identity commitment must be 32 bytes" }) }));
        switch (x.dedupCommit) {
          case (?d) {
            if (not Commit.validCommitment(d)) return #err(#PartyError({ error = #InvalidCommitment({ reason = "the deduplication commitment must be 32 bytes" }) }));
            // exact-match deduplication: the control a bank needs, with the
            // privacy trade-off stated in Commitments.mo rather than hidden
            switch (PartyCore.byDedup(bs.party, d)) {
              case (?existing) return #err(#PartyError({ error = #DuplicateIdentity({ existing }) }));
              case null {};
            };
          };
          case null {};
        };
        switch (PartyCore.validateAttributes(x.attributes)) {
          case (?r) return #err(#PartyError({ error = #InvalidParty({ reason = r }) }));
          case null {};
        };
        #ok({ bankEvent = ?#party(#partyCreated({ kind = x.kind; salt = x.salt; identityCommit = x.identityCommit; dedupCommit = x.dedupCommit; attributes = x.attributes; book = x.book; cddLevel = x.cddLevel; riskRating = x.riskRating; pep = x.pep; reviewDue = x.reviewDue })); extra = []; journal = [] })
      };

      case (#createCustomer(c)) planCreateCustomer(bs, bb, js, journalCaller, c, bs.height);

      case (#amendParty(x)) {
        switch (requireParty(bs, x.party)) { case (?e) return #err(e); case null {} };
        switch (PartyCore.validateAttributes(x.attributes)) {
          case (?r) return #err(#PartyError({ error = #InvalidParty({ reason = r }) }));
          case null {};
        };
        #ok({ bankEvent = ?#party(#partyAmended({ party = x.party; attributes = x.attributes })); extra = []; journal = [] })
      };

      case (#setPartyLifecycle(x)) {
        let ?p = PartyCore.get(bs.party, partyBlocks(bb), x.party) else return #err(#PartyError({ error = #UnknownParty({ party = x.party }) }));
        if (not PartyCore.transitionAllowed(p.lifecycle, x.to)) {
          return #err(#PartyError({ error = #IllegalTransition({ from = p.lifecycle; to = x.to }) }));
        };
        // becoming active requires the customer due diligence its level demands
        if (x.to == #active) {
          let missing = PartyCore.missingDocuments(p);
          if (missing.size() > 0) {
            return #err(#PartyError({ error = #CddIncomplete({ party = x.party; level = p.cddLevel; missing }) }));
          };
          if (not Screening.permitsMovement(PartyCore.effectiveScreening(bs.party, p))) {
            return #err(#PartyError({ error = #ScreeningBlocks({ party = x.party; state = PartyCore.effectiveScreening(bs.party, p) }) }));
          };
        };
        // closing requires no balance and no allocated collateral, checked
        // against the journal and the register rather than against a cached figure
        if (x.to == #closed) {
          switch (partyHasBalance(bs, bb, js, x.party)) { case (?e) return #err(e); case null {} };
          var allocated = 0;
          for (cid in PartyCore.collateralOfParty(bs.party, x.party).vals()) {
            let ?cl = PartyCore.getCollateral(bs.party, partyBlocks(bb), cid) else return #err(#PartyError({ error = #UnknownCollateral({ collateral = cid }) }));
            if (not cl.released) allocated += PartyCore.allocatedAgainst(cl);
          };
          if (allocated > 0) return #err(#PartyError({ error = #PartyHasCollateral({ party = x.party; allocated }) }));
        };
        #ok({ bankEvent = ?#party(#partyLifecycleSet({ party = x.party; to = x.to })); extra = []; journal = [] })
      };

      case (#setPartyCdd(x)) {
        switch (requireParty(bs, x.party)) { case (?e) return #err(e); case null {} };
        #ok({ bankEvent = ?#party(#partyCddSet({ party = x.party; level = x.level; riskRating = x.riskRating; pep = x.pep; reviewDue = x.reviewDue })); extra = []; journal = [] })
      };

      case (#addPartyDocument(x)) {
        let ?p = PartyCore.get(bs.party, partyBlocks(bb), x.party) else return #err(#PartyError({ error = #UnknownParty({ party = x.party }) }));
        if (not Commit.validCommitment(x.document.commit)) return #err(#PartyError({ error = #InvalidCommitment({ reason = "the document commitment must be 32 bytes" }) }));
        if (Text.encodeUtf8(x.document.kind).size() == 0) return #err(#PartyError({ error = #InvalidParty({ reason = "a document needs a kind" }) }));
        if (p.documents.size() >= PT.MAX_DOCUMENTS) return #err(#PartyError({ error = #InvalidParty({ reason = "too many documents" }) }));
        switch (x.document.expires) {
          case (?e) { if (e <= x.document.issued) return #err(#PartyError({ error = #InvalidParty({ reason = "a document cannot expire before it was issued" }) })) };
          case null {};
        };
        #ok({ bankEvent = ?#party(#partyDocumentAdded({ party = x.party; document = x.document })); extra = []; journal = [] })
      };

      case (#addPartyRelationship(x)) {
        let ?p = PartyCore.get(bs.party, partyBlocks(bb), x.party) else return #err(#PartyError({ error = #UnknownParty({ party = x.party }) }));
        switch (requireParty(bs, x.relationship.other)) { case (?e) return #err(e); case null {} };
        if (x.relationship.other == x.party) return #err(#PartyError({ error = #InvalidParty({ reason = "a party cannot be related to itself" }) }));
        if (p.relationships.size() >= PT.MAX_RELATIONSHIPS) return #err(#PartyError({ error = #InvalidParty({ reason = "too many relationships" }) }));
        #ok({ bankEvent = ?#party(#partyRelationshipAdded({ party = x.party; relationship = x.relationship })); extra = []; journal = [] })
      };

      case (#setPartyExtension(x)) {
        switch (requireParty(bs, x.party)) { case (?e) return #err(e); case null {} };
        switch (PartyCore.validateExtensionValues(bs.party, #party, x.values)) {
          case (?e) return #err(#PartyError({ error = e }));
          case null {};
        };
        #ok({ bankEvent = ?#party(#partyExtensionSet({ party = x.party; values = x.values })); extra = []; journal = [] })
      };

      case (#issueIdentifier(x)) {
        let ?p = PartyCore.get(bs.party, partyBlocks(bb), x.party) else return #err(#PartyError({ error = #UnknownParty({ party = x.party }) }));
        let ?fmt = PartyCore.format(bs.party) else return #err(#PartyError({ error = #InvalidIdentifier({ identifier = ""; reason = "no account-number format is recorded" }) }));
        if (p.identifiers.size() >= PT.MAX_IDENTIFIERS_PER_PARTY) {
          return #err(#PartyError({ error = #InvalidIdentifier({ identifier = ""; reason = "too many identifiers for this party" }) }));
        };
        // The serial is the bank block index this command will occupy, so two
        // accounts can never receive the same identifier — behind this shard's index, so the
        // identifier routes to this shard (`ShardCore.serialFor`).
        let ?serial = ShardCore.serialFor(bs.shard, fmt, authorityIndex) else return #err(#PartyError({ error = #InvalidIdentifier({ identifier = ""; reason = "the serial does not fit the format behind the shard index" }) }));
        switch (Iban.issue(fmt, serial)) {
          case (#err(r)) #err(#PartyError({ error = #InvalidIdentifier({ identifier = ""; reason = r }) }));
          case (#ok(identifier)) {
            switch (PartyCore.byIdentifier(bs.party, identifier)) {
              case (?_) #err(#PartyError({ error = #IdentifierExists({ identifier }) }));
              case null #ok({ bankEvent = ?#party(#partyIdentifierIssued({ party = x.party; identifier })); extra = []; journal = [] });
            }
          };
        }
      };

      case (#commitScreeningList(x)) {
        if (Text.encodeUtf8(x.version).size() == 0) return #err(#PartyError({ error = #InvalidParty({ reason = "a list needs a version" }) }));
        switch (PartyCore.getList(bs.party, x.version)) {
          case (?_) return #err(#PartyError({ error = #ListExists({ version = x.version }) }));
          case null {};
        };
        if (not Commit.validCommitment(x.root)) return #err(#PartyError({ error = #InvalidCommitment({ reason = "the list root must be 32 bytes" }) }));
        if (x.count == 0) return #err(#PartyError({ error = #InvalidParty({ reason = "an empty list has nothing to commit to" }) }));
        if (not Text.equal(x.normalisation, Commit.NORMALISATION)) {
          return #err(#PartyError({ error = #InvalidParty({ reason = "the list must be normalised by this build's rule set" }) }));
        };
        #ok({ bankEvent = ?#party(#screeningListCommitted({ version = x.version; root = x.root; count = x.count; normalisation = x.normalisation })); extra = []; journal = [] })
      };

      case (#proveScreeningClear(x)) {
        let ?p = PartyCore.get(bs.party, partyBlocks(bb), x.party) else return #err(#PartyError({ error = #UnknownParty({ party = x.party }) }));
        let ?list = PartyCore.getList(bs.party, x.listVersion) else return #err(#PartyError({ error = #UnknownList({ version = x.listVersion }) }));
        // The subject must be the party's own recorded screening subject. Without
        // this the proof would be about some other string, and "this party is not
        // on the list" would mean nothing.
        var recorded : ?PT.Commitment = null;
        for (a in p.attributes.vals()) { if (Text.equal(a.name, Commit.SCREENING_SUBJECT)) recorded := ?a.commit };
        let ?subjectCommit = recorded else return #err(#PartyError({ error = #InvalidParty({ reason = "the party carries no " # Commit.SCREENING_SUBJECT # " attribute to bind a proof to" }) }));
        let recomputed = Commit.fieldBytes(p.salt, Commit.SCREENING_SUBJECT, x.subject);
        if (recomputed != subjectCommit) {
          return #err(#PartyError({ error = #CommitmentMismatch({ field = Commit.SCREENING_SUBJECT; recorded = subjectCommit; recomputed }) }));
        };
        if (x.subject.size() == 0 or x.subject.size() > PT.MAX_LIST_ENTRY_BYTES) {
          return #err(#PartyError({ error = #InvalidParty({ reason = "the screening subject is empty or over the bound" }) }));
        };
        switch (Screening.verifyNonMembership(x.subject, x.proof, list)) {
          case (#absent) #ok({ bankEvent = ?#party(#screeningProven({ party = x.party; listVersion = x.listVersion })); extra = []; journal = [] });
          case (#present) #err(#PartyError({ error = #SubjectIsOnTheList({ listVersion = x.listVersion }) }));
          case (#invalid(r)) #err(#PartyError({ error = #AdjacencyProofFailed({ reason = r }) }));
        }
      };

      case (#recordScreeningDecision(d)) {
        switch (requireParty(bs, d.party)) { case (?e) return #err(e); case null {} };
        let ?list = PartyCore.getList(bs.party, d.listVersion) else return #err(#PartyError({ error = #UnknownList({ version = d.listVersion }) }));
        if (list.root != d.listRoot) {
          return #err(#PartyError({ error = #CommitmentMismatch({ field = "list root"; recorded = list.root; recomputed = d.listRoot }) }));
        };
        if (not Commit.validCommitment(d.justificationCommit)) {
          return #err(#PartyError({ error = #InvalidCommitment({ reason = "the justification commitment must be 32 bytes" }) }));
        };
        if (Principal.isAnonymous(d.screener)) return #err(#PartyError({ error = #InvalidParty({ reason = "a screening decision needs a named screener" }) }));
        #ok({ bankEvent = ?#party(#screeningDecisionRecorded(d)); extra = []; journal = [] })
      };

      case (#registerSchema(x)) {
        switch (PartyCore.getSchema(bs.party, x.id)) {
          case (?_) return #err(#PartyError({ error = #SchemaExists({ schema = x.id }) }));
          case null {};
        };
        switch (PartyCore.validateSchema(x)) {
          case (?r) return #err(#PartyError({ error = #InvalidSchema({ reason = r }) }));
          case null {};
        };
        #ok({ bankEvent = ?#party(#schemaRegistered({ id = x.id; entity = x.entity; fields = x.fields })); extra = []; journal = [] })
      };

      case (#registerCollateral(x)) {
        switch (requireParty(bs, x.party)) { case (?e) return #err(e); case null {} };
        switch (PartyCore.validateValuation(x.valuation)) {
          case (?r) return #err(#PartyError({ error = #InvalidValuation({ reason = r }) }));
          case null {};
        };
        if (not Commit.validCommitment(x.descriptionCommit)) return #err(#PartyError({ error = #InvalidCommitment({ reason = "the description commitment must be 32 bytes" }) }));
        #ok({ bankEvent = ?#party(#collateralRegistered({ party = x.party; kind = x.kind; valuation = x.valuation; descriptionCommit = x.descriptionCommit })); extra = []; journal = [] })
      };

      case (#revalueCollateral(x)) {
        let ?cl = PartyCore.getCollateral(bs.party, partyBlocks(bb), x.collateral) else return #err(#PartyError({ error = #UnknownCollateral({ collateral = x.collateral }) }));
        if (cl.released) return #err(#PartyError({ error = #CollateralReleased({ collateral = x.collateral }) }));
        switch (PartyCore.validateValuation(x.valuation)) {
          case (?r) return #err(#PartyError({ error = #InvalidValuation({ reason = r }) }));
          case null {};
        };
        if (not Text.equal(x.valuation.currency, cl.valuation.currency)) {
          return #err(#PartyError({ error = #InvalidValuation({ reason = "a revaluation cannot change the currency" }) }));
        };
        // A revaluation below what is already allocated is admitted and leaves the
        // facility under-secured, which is a fact the register must show; it is
        // not silently de-allocated.
        #ok({ bankEvent = ?#party(#collateralRevalued({ collateral = x.collateral; valuation = x.valuation })); extra = []; journal = [] })
      };

      case (#allocateCollateral(x)) {
        let ?cl = PartyCore.getCollateral(bs.party, partyBlocks(bb), x.collateral) else return #err(#PartyError({ error = #UnknownCollateral({ collateral = x.collateral }) }));
        if (cl.released) return #err(#PartyError({ error = #CollateralReleased({ collateral = x.collateral }) }));
        if (x.amount == 0) return #err(#PartyError({ error = #InvalidValuation({ reason = "an allocation of zero secures nothing" }) }));
        if (Text.encodeUtf8(x.facility).size() == 0) return #err(#PartyError({ error = #InvalidValuation({ reason = "an allocation needs a facility" }) }));
        let already = PartyCore.allocatedAgainst(cl);
        let available = PartyCore.haircutValue(cl.valuation);
        if (already + x.amount > available) {
          return #err(#PartyError({ error = #AllocationExceedsValue({ collateral = x.collateral; haircutValue = available; allocated = already; requested = x.amount }) }));
        };
        #ok({ bankEvent = ?#party(#collateralAllocated({ collateral = x.collateral; facility = x.facility; amount = x.amount })); extra = []; journal = [] })
      };

      case (#releaseCollateral(x)) {
        let ?cl = PartyCore.getCollateral(bs.party, partyBlocks(bb), x.collateral) else return #err(#PartyError({ error = #UnknownCollateral({ collateral = x.collateral }) }));
        if (cl.released) return #err(#PartyError({ error = #CollateralReleased({ collateral = x.collateral }) }));
        let already = PartyCore.allocatedAgainst(cl);
        if (already > 0) {
          return #err(#PartyError({ error = #AllocationExceedsValue({ collateral = x.collateral; haircutValue = PartyCore.haircutValue(cl.valuation); allocated = already; requested = 0 }) }));
        };
        #ok({ bankEvent = ?#party(#collateralReleased({ collateral = x.collateral })); extra = []; journal = [] })
      };

      case (#addStaff(x)) {
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        if (Principal.isAnonymous(x.principal_)) return #err(#PartyError({ error = #InvalidParty({ reason = "the anonymous principal cannot be staff" }) }));
        switch (PartyCore.getStaff(bs.party, x.principal_)) {
          case (?_) return #err(#PartyError({ error = #StaffExists({ principal_ = x.principal_ }) }));
          case null {};
        };
        #ok({ bankEvent = ?#party(#staffAdded({ principal_ = x.principal_; book = x.book; title = x.title })); extra = []; journal = [] })
      };

      case (#removeStaff(x)) {
        switch (PartyCore.getStaff(bs.party, x.principal_)) {
          case null return #err(#PartyError({ error = #UnknownStaff({ principal_ = x.principal_ }) }));
          case (?_) {};
        };
        #ok({ bankEvent = ?#party(#staffRemoved({ principal_ = x.principal_ })); extra = []; journal = [] })
      };

      case (#setAccountFormat(f)) {
        switch (Iban.validateFormat(f)) {
          case (?r) return #err(#PartyError({ error = #InvalidIdentifier({ identifier = ""; reason = r }) }));
          case null {};
        };
        #ok({ bankEvent = ?#party(#accountFormatSet(f)); extra = []; journal = [] })
      };

      case (#setReviewGrace(x)) {
        if (x.days > 365) return #err(#PartyError({ error = #InvalidParty({ reason = "a review grace longer than a year is not a grace" }) }));
        #ok({ bankEvent = ?#party(#reviewGraceSet({ days = x.days })); extra = []; journal = [] })
      };

      case (#pinJwks(j)) {
        if (Text.encodeUtf8(j.issuer).size() == 0) return #err(#PartyError({ error = #UnknownIssuer({ issuer = "" }) }));
        if (j.keys.size() == 0) return #err(#PartyError({ error = #InvalidParty({ reason = "a key set with no keys verifies nothing" }) }));
        if (j.keys.size() > PT.MAX_JWKS_KEYS) return #err(#PartyError({ error = #InvalidParty({ reason = "too many keys" }) }));
        var i = 0;
        while (i < j.keys.size()) {
          if (j.keys[i].n.size() == 0 or j.keys[i].e.size() == 0) return #err(#PartyError({ error = #InvalidParty({ reason = "a key needs a modulus and an exponent" }) }));
          var k2 = i + 1;
          while (k2 < j.keys.size()) {
            if (Text.equal(j.keys[i].kid, j.keys[k2].kid)) return #err(#PartyError({ error = #InvalidParty({ reason = "duplicate key id " # j.keys[i].kid }) }));
            k2 += 1;
          };
          i += 1;
        };
        #ok({ bankEvent = ?#party(#jwksPinned(j)); extra = []; journal = [] })
      };

      case (#registerCredential(c)) {
        if (Principal.isAnonymous(c.subject)) return #err(#PartyError({ error = #InvalidParty({ reason = "the anonymous principal cannot hold a credential" }) }));
        switch (PartyCore.getCredential(bs.party, c.subject)) {
          case (?existing) { if (existing.revokedAtBlock == null) return #err(#PartyError({ error = #CredentialExists({ subject = c.subject }) })) };
          case null {};
        };
        switch (c.kind) {
          case (#oidc({ issuer; subjectCommit })) {
            switch (Map.get(bs.party.jwks, Text.compare, issuer)) {
              case null return #err(#PartyError({ error = #UnknownIssuer({ issuer }) }));
              case (?_) {};
            };
            if (not Commit.validCommitment(subjectCommit)) return #err(#PartyError({ error = #InvalidCommitment({ reason = "the OIDC subject commitment must be 32 bytes" }) }));
          };
          case (#passkey({ aaguid })) {
            if (aaguid.size() == 0) return #err(#PartyError({ error = #InvalidParty({ reason = "a passkey credential needs an authenticator identifier" }) }));
          };
        };
        #ok({ bankEvent = ?#party(#credentialRegistered(c)); extra = []; journal = [] })
      };

      case (#revokeCredential(x)) {
        switch (PartyCore.getCredential(bs.party, x.subject)) {
          case null return #err(#PartyError({ error = #UnknownCredential({ subject = x.subject }) }));
          case (?c) { if (c.revokedAtBlock != null) return #err(#PartyError({ error = #UnknownCredential({ subject = x.subject }) })) };
        };
        #ok({ bankEvent = ?#party(#credentialRevoked({ subject = x.subject })); extra = []; journal = [] })
      };

      // ── money, attributed to a party: the KYC and screening gate applies ──
      case (#postManualEntryForParty(x)) {
        switch (requireOpenBook(bs, x.entry.book)) { case (?e) return #err(e); case null {} };
        // The gate. It runs before the journal is asked to admit anything, in the
        // same message, so a blocked party's posting never exists.
        switch (PartyCore.permitsMovement(bs.party, partyBlocks(bb), x.party, JCore.effectiveToday(js, now))) {
          case (?e) return #err(#PartyError({ error = e }));
          case null {};
        };
        let input : JT.PostingInput = {
          idempotencyKey = x.entry.idempotencyKey;
          postingDate = x.entry.postingDate;
          valueDate = x.entry.valueDate;
          period = x.entry.period;
          legs = x.entry.legs;
          sourceRef = { kind = "manual-party"; id = authId };
          narration = x.entry.narration;
          correctionOf = x.entry.correctionOf;
        };
        switch (JCore.preparePost(js, journalCaller, now, input)) {
          case (#err(e)) #err(#JournalError({ error = e }));
          case (#ok(#event(e))) #ok({ bankEvent = null; extra = []; journal = [#event(e)] });
          case (#ok(#duplicate(idx))) #ok({ bankEvent = null; extra = []; journal = [#existing(idx)] });
        }
      };

      case (#reverseManualEntry(x)) {
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        let args : JCore.ReverseArgs = {
          idempotencyKey = x.idempotencyKey;
          postingDate = x.postingDate;
          valueDate = x.valueDate;
          period = x.period;
          narration = x.narration;
          sourceRef = { kind = "manual-rev"; id = authId };
        };
        switch (JCore.prepareReverse(js, jb, journalCaller, now, x.original, args)) {
          case (#err(e)) #err(#JournalError({ error = e }));
          case (#ok(#event(e))) #ok({ bankEvent = null; extra = []; journal = [#event(e)] });
          case (#ok(#duplicate(idx))) #ok({ bankEvent = null; extra = []; journal = [#existing(idx)] });
        }
      };

      // ═══════════════════════════════════════════════════════
      //  THE PRODUCT ENGINE
      // ═══════════════════════════════════════════════════════
      //
      // Configuration first. Registering a product and opening an account move no
      // money, so they are admitted below every activation height; what they do is
      // make the terms a block, which is what makes an interest dispute answerable.

      case (#registerProduct(x)) {
        switch (ProductCore.currentVersion(bs.product, x.id)) {
          case (?v) return #err(#ProductError({ error = #ProductExists({ product = x.id; version = v.version }) }));
          case null {};
        };
        switch (Products.validateTerms(js, x.id, x.terms)) { case (?e) return #err(#ProductError({ error = e })); case null {} };
        if (Text.encodeUtf8(x.name).size() == 0 or Text.encodeUtf8(x.name).size() > T.MAX_NAME_BYTES) {
          return #err(#ProductError({ error = #InvalidTerms({ reason = "a product needs a name within the bound" }) }));
        };
        #ok({ bankEvent = ?#product(#productRegistered({ id = x.id; version = 1; name = x.name; terms = x.terms })); extra = []; journal = [] })
      };

      case (#amendProduct(x)) {
        let ?cur = ProductCore.currentVersion(bs.product, x.id) else return #err(#ProductError({ error = #UnknownProduct({ product = x.id }) }));
        // The kind and the currency are what every account's postings are shaped by,
        // so an amendment may not change either: that would restate the meaning of
        // balances already on the books. A different kind is a different product.
        // Checked before the terms are validated, so the refusal names the thing the
        // caller actually got wrong rather than a role map that is only wrong
        // because the kind is.
        if (cur.terms.kind != x.terms.kind) {
          return #err(#ProductError({ error = #InvalidTerms({ reason = "an amendment cannot change a product's kind" }) }));
        };
        if (not Text.equal(cur.terms.currency, x.terms.currency)) {
          return #err(#ProductError({ error = #CurrencyMismatch({ expected = cur.terms.currency; actual = x.terms.currency }) }));
        };
        switch (Products.validateTerms(js, x.id, x.terms)) { case (?e) return #err(#ProductError({ error = e })); case null {} };
        #ok({ bankEvent = ?#product(#productAmended({ id = x.id; version = cur.version + 1; supersedes = cur.version; name = x.name; terms = x.terms })); extra = []; journal = [] })
      };

      case (#closeProductToNewAccounts(x)) {
        let ?v = ProductCore.getVersion(bs.product, x.id, x.version) else {
          return #err(#ProductError({ error = #UnknownVersion({ product = x.id; version = x.version }) }));
        };
        if (not v.openToNewAccounts) {
          return #err(#ProductError({ error = #ProductClosedToNewAccounts({ product = x.id; version = x.version }) }));
        };
        #ok({ bankEvent = ?#product(#productClosedToNewAccounts({ id = x.id; version = x.version })); extra = []; journal = [] })
      };

      case (#openAccount(x)) {
        let ?party = PartyCore.get(bs.party, partyBlocks(bb), x.party) else return #err(#PartyError({ error = #UnknownParty({ party = x.party }) }));
        switch (planOpenAccount(bs, js, journalCaller, x.product, x.party, party.book, x.currency, x.termDays, x.allocationOrder, null, authorityIndex, [])) {
          case (#err(e)) #err(e);
          case (#ok(o)) #ok({ bankEvent = ?#product(o.opened); extra = []; journal = [#event(o.limit)] });
        }
      };

      case (#setAccountStatus(x)) {
        let ?a = ProductCore.get(bs.product, productBlocks(bb), x.account) else return #err(#ProductError({ error = #UnknownAccount({ account = x.account }) }));
        if (not accountTransitionAllowed(a.status, x.to)) {
          return #err(#ProductError({ error = #AccountNotActive({ account = x.account; status = a.status }) }));
        };
        if (x.to == #closed) {
          // an account is closed when it owes and is owed nothing; the figures are
          // the journal's, so there is no cached balance that could say otherwise
          let ?terms = ProductCore.termsOf(bs.product, a) else return #err(#ProductError({ error = #UnknownVersion({ product = a.product; version = a.version }) }));
          let total = accountExposure(js, a, terms);
          if (total > 0) return #err(#ProductError({ error = #AccountHasBalance({ account = x.account; balance = total }) }));
        };
        #ok({ bankEvent = ?#product(#accountStatusSet({ account = x.account; to = x.to })); extra = []; journal = [] })
      };

      case (#migrateAccount(x)) {
        let ?a = ProductCore.get(bs.product, productBlocks(bb), x.account) else return #err(#ProductError({ error = #UnknownAccount({ account = x.account }) }));
        if (a.version == x.to) {
          return #err(#ProductError({ error = #InvalidTerms({ reason = "the account is already on version " # Nat.toText(x.to) }) }));
        };
        let ?target = ProductCore.getVersion(bs.product, a.product, x.to) else {
          return #err(#ProductError({ error = #UnknownVersion({ product = a.product; version = x.to }) }));
        };
        if (not Text.equal(target.terms.currency, a.currency)) {
          return #err(#ProductError({ error = #CurrencyMismatch({ expected = a.currency; actual = target.terms.currency }) }));
        };
        #ok({ bankEvent = ?#product(#accountMigrated({ account = x.account; from = a.version; to = x.to })); extra = []; journal = [] })
      };

      case (#openTill(x)) {
        if (not validIdentifier(x.till, T.MAX_BOOK_ID_BYTES)) {
          return #err(#ProductError({ error = #InvalidTerms({ reason = "a till id must be 1.." # Nat.toText(T.MAX_BOOK_ID_BYTES) # " characters of [A-Za-z0-9-_.]" }) }));
        };
        switch (ProductCore.getTill(bs.product, productBlocks(bb), x.till)) {
          case (?_) return #err(#ProductError({ error = #TillExists({ till = x.till }) }));
          case null {};
        };
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        let ?v = ProductCore.currentVersion(bs.product, x.product) else return #err(#ProductError({ error = #UnknownProduct({ product = x.product }) }));
        if (v.terms.kind != #till) {
          return #err(#ProductError({ error = #AccountNotOfKind({ account = 0; expected = "till"; actual = debug_show (v.terms.kind) }) }));
        };
        if (not Text.equal(v.terms.currency, x.currency)) {
          return #err(#ProductError({ error = #CurrencyMismatch({ expected = v.terms.currency; actual = x.currency }) }));
        };
        // the holder is a member of staff of that book, checked against the staff
        // register rather than taken on trust
        let ?st = PartyCore.getStaff(bs.party, x.holder) else {
          return #err(#PartyError({ error = #UnknownStaff({ principal_ = x.holder }) }));
        };
        if (not Text.equal(st.book, x.book)) return #err(#OutsideBookScope({ book = x.book }));
        // A drawer cannot hold negative cash, and that is the engine's to enforce:
        // the till's sub-ledger is limited so credits may never exceed debits.
        let sub = Till.tillSubledger(x.till);
        let limit = Limits.journalLimit(#debit, null);
        switch (JCore.prepareSetBalanceLimit(js, journalCaller, v.terms.control, ?sub, x.currency, limit)) {
          case (#err(e)) #err(#JournalConfigError({ error = e }));
          case (#ok(ev)) #ok({
            bankEvent = ?#product(#tillOpened({ till = x.till; book = x.book; currency = x.currency; holder = x.holder; product = x.product }));
            extra = []; journal = [#event(ev)];
          });
        }
      };

      case (#closeTill(x)) {
        let ?t = ProductCore.getTill(bs.product, productBlocks(bb), x.till) else return #err(#ProductError({ error = #UnknownTill({ till = x.till }) }));
        if (t.status == #closed) return #err(#ProductError({ error = #TillNotOpen({ till = x.till; status = t.status }) }));
        let ?v = ProductCore.currentVersion(bs.product, t.product) else return #err(#ProductError({ error = #UnknownProduct({ product = t.product }) }));
        let ?today = JCore.businessDate(js) else return #err(#ProductError({ error = #InvalidTerms({ reason = "no business date is set" }) }));
        let held = Till.bookBalance(js, v.terms.control, t.subledger, t.currency, today);
        if (held > 0) return #err(#ProductError({ error = #TillHasCash({ till = x.till; balance = held }) }));
        #ok({ bankEvent = ?#product(#tillClosed({ till = x.till })); extra = []; journal = [] })
      };

      // ── money-visible, each behind its own activation height ──

      case (#grantFacility(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_ACCOUNT_MONEY)) { case (?e) return #err(e); case null {} };
        switch (activeAccount(bs, bb, x.account)) {
          case (#err(e)) #err(e);
          case (#ok(a)) {
            let ?terms = ProductCore.termsOf(bs.product, a) else return #err(#ProductError({ error = #UnknownVersion({ product = a.product; version = a.version }) }));
            if (terms.kind == #loan) {
              return #err(#ProductError({ error = #AccountNotOfKind({ account = x.account; expected = "a deposit product"; actual = "loan" }) }));
            };
            let side = ProductCore.normalSideOf(terms.kind);
            let limit = Limits.journalLimit(side, ?x.limit);
            switch (JCore.prepareSetBalanceLimit(js, journalCaller, terms.control, ?a.subledger, a.currency, limit)) {
              case (#err(e)) #err(#JournalConfigError({ error = e }));
              case (#ok(ev)) #ok({
                bankEvent = ?#product(#facilityGranted({ account = x.account; limit = x.limit }));
                extra = []; journal = [#event(ev)];
              });
            }
          };
        }
      };

      case (#depositToAccount(m)) {
        switch (requireFeature(bs, ProdT.FEATURE_ACCOUNT_MONEY)) { case (?e) return #err(e); case null {} };
        switch (movableAccount(bs, bb, js, m.account, m.postingDate)) {
          case (#err(e)) #err(e);
          case (#ok((a, terms))) {
            if (terms.kind == #loan) {
              return #err(#ProductError({ error = #AccountNotOfKind({ account = m.account; expected = "a deposit product"; actual = "loan" }) }));
            };
            if (m.amount == 0) return #err(#ProductError({ error = #InvalidTerms({ reason = "a deposit of zero moves nothing" }) }));
            switch (valueDateGate(bs, js, a.book, m.period, terms.valueDateConvention, m.valueDate)) {
              case (#err(e)) return #err(e);
              case (#ok(valueDate)) {
                switch (fundingLeg(bs, bb, js, terms, m.funding, a.currency, #debit, m.amount)) {
                  case (#err(e)) #err(e);
                  case (#ok(source)) {
                    let credit = Posting.leg(terms.control, ?a.subledger, #credit, a.currency, m.amount);
                    postOne(js, journalCaller, now, Posting.simple("deposit", [authId, Nat.toText(m.account)], source, credit, m.postingDate, valueDate, m.period, m.narration))
                  };
                }
              };
            }
          };
        }
      };

      case (#withdrawFromAccount(m)) {
        switch (requireFeature(bs, ProdT.FEATURE_ACCOUNT_MONEY)) { case (?e) return #err(e); case null {} };
        switch (movableAccount(bs, bb, js, m.account, m.postingDate)) {
          case (#err(e)) #err(e);
          case (#ok((a, terms))) {
            if (terms.kind == #loan) {
              return #err(#ProductError({ error = #AccountNotOfKind({ account = m.account; expected = "a deposit product"; actual = "loan" }) }));
            };
            if (m.amount == 0) return #err(#ProductError({ error = #InvalidTerms({ reason = "a withdrawal of zero moves nothing" }) }));
            switch (valueDateGate(bs, js, a.book, m.period, terms.valueDateConvention, m.valueDate)) {
              case (#err(e)) return #err(e);
              case (#ok(valueDate)) {
                let side = ProductCore.normalSideOf(terms.kind);
                let after = Limits.after(js, terms.control, a.subledger, a.currency, side, valueDate, m.amount);
                switch (Limits.checkWithdrawal(terms.limits, m.amount, after.balance, after.overdrawn)) {
                  case (?f) return #err(#LimitError({ reason = Limits.faultText(f) }));
                  case null {};
                };
                switch (fundingLeg(bs, bb, js, terms, m.funding, a.currency, #credit, m.amount)) {
                  case (#err(e)) #err(e);
                  case (#ok(sink)) {
                    let debit = Posting.leg(terms.control, ?a.subledger, #debit, a.currency, m.amount);
                    postOne(js, journalCaller, now, Posting.simple("withdrawal", [authId, Nat.toText(m.account)], debit, sink, m.postingDate, valueDate, m.period, m.narration))
                  };
                }
              };
            }
          };
        }
      };

      case (#transferBetweenAccounts(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_ACCOUNT_MONEY)) { case (?e) return #err(e); case null {} };
        if (x.from == x.to) return #err(#ProductError({ error = #InvalidTerms({ reason = "an account cannot transfer to itself" }) }));
        if (x.amount == 0) return #err(#ProductError({ error = #InvalidTerms({ reason = "a transfer of zero moves nothing" }) }));
        switch (movableAccount(bs, bb, js, x.from, x.postingDate)) {
          case (#err(e)) #err(e);
          case (#ok((from_, fromTerms))) {
            switch (movableAccount(bs, bb, js, x.to, x.postingDate)) {
              case (#err(e)) #err(e);
              case (#ok((to_, toTerms))) {
                if (not Text.equal(from_.currency, to_.currency)) {
                  return #err(#ProductError({ error = #CurrencyMismatch({ expected = from_.currency; actual = to_.currency }) }));
                };
                if (fromTerms.kind == #loan or toTerms.kind == #loan) {
                  return #err(#ProductError({ error = #AccountNotOfKind({ account = x.from; expected = "two deposit products"; actual = "loan" }) }));
                };
                switch (valueDateGate(bs, js, from_.book, x.period, fromTerms.valueDateConvention, x.valueDate)) {
                  case (#err(e)) return #err(e);
                  case (#ok(valueDate)) {
                    switch (valueDateGate(bs, js, to_.book, x.period, toTerms.valueDateConvention, valueDate)) {
                      case (#err(e)) return #err(e);
                      case (#ok(effective)) {
                        let side = ProductCore.normalSideOf(fromTerms.kind);
                        let after = Limits.after(js, fromTerms.control, from_.subledger, from_.currency, side, effective, x.amount);
                        switch (Limits.checkWithdrawal(fromTerms.limits, x.amount, after.balance, after.overdrawn)) {
                          case (?f) return #err(#LimitError({ reason = Limits.faultText(f) }));
                          case null {};
                        };
                        let debit = Posting.leg(fromTerms.control, ?from_.subledger, #debit, from_.currency, x.amount);
                        let credit = Posting.leg(toTerms.control, ?to_.subledger, #credit, to_.currency, x.amount);
                        postOne(js, journalCaller, now, Posting.simple("transfer", [authId, Nat.toText(x.from), Nat.toText(x.to)], debit, credit, x.postingDate, effective, x.period, x.narration))
                      };
                    }
                  };
                }
              };
            }
          };
        }
      };

      case (#applyCharge(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_CHARGES)) { case (?e) return #err(e); case null {} };
        switch (movableAccount(bs, bb, js, x.account, x.postingDate)) {
          case (#err(e)) #err(e);
          case (#ok((a, terms))) {
            let ?c = Charges.find(terms, x.charge) else return #err(#ProductError({ error = #UnknownCharge({ charge = x.charge }) }));
            if (ProductCore.chargeApplied(bs.product, productBlocks(bb), a.id, x.charge, x.occurrence) != null) {
              return #err(#ChargeError({ charge = x.charge; reason = "already applied for the occurrence on day " # Nat.toText(x.occurrence) }));
            };
            if (ProductCore.chargeWaived(bs.product, productBlocks(bb), a.id, x.charge, x.occurrence) != null) {
              return #err(#ChargeError({ charge = x.charge; reason = "waived for the occurrence on day " # Nat.toText(x.occurrence) }));
            };
            switch (Charges.amountOf(c, x.base, terms.rounding)) {
              case (#err(#baseMissing(b))) #err(#ChargeError({ charge = b.charge; reason = "needs " # b.needs }));
              case (#err(#roundsToZero(b))) #err(#ChargeError({ charge = b.charge; reason = "rounds to zero, and a posting that moves nothing is not made" }));
              case (#ok(r)) {
                let ?income = Charges.incomeAccount(terms, c) else return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = ProdT.roleText(c.role) }) }));
                switch (chargeDebitAccount(terms, c)) {
                  case (#err(e)) #err(e);
                  case (#ok(debitAccount)) {
                    let debit = Posting.leg(debitAccount, ?a.subledger, #debit, a.currency, r.amount);
                    let credit = Posting.leg(income, null, #credit, a.currency, r.amount);
                    switch (postOne(js, journalCaller, now, Posting.simple("charge", [Nat.toText(x.account), x.charge, Nat.toText(x.occurrence)], debit, credit, x.postingDate, x.valueDate, x.period, x.narration))) {
                      case (#err(e)) #err(e);
                      case (#ok(plan)) #ok({
                        bankEvent = ?#product(#chargeApplied({ account = x.account; charge = x.charge; amount = r.amount; day = x.occurrence }));
                        extra = []; journal = plan.journal;
                      });
                    }
                  };
                }
              };
            }
          };
        }
      };

      case (#waiveCharge(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_CHARGES)) { case (?e) return #err(e); case null {} };
        let ?a = ProductCore.get(bs.product, productBlocks(bb), x.account) else return #err(#ProductError({ error = #UnknownAccount({ account = x.account }) }));
        let ?terms = ProductCore.termsOf(bs.product, a) else return #err(#ProductError({ error = #UnknownVersion({ product = a.product; version = a.version }) }));
        let ?c = Charges.find(terms, x.charge) else return #err(#ProductError({ error = #UnknownCharge({ charge = x.charge }) }));
        if (not c.waivable) return #err(#ProductError({ error = #ChargeNotWaivable({ charge = x.charge }) }));
        if (ProductCore.chargeWaived(bs.product, productBlocks(bb), a.id, x.charge, x.occurrence) != null) {
          return #err(#ChargeError({ charge = x.charge; reason = "already waived for the occurrence on day " # Nat.toText(x.occurrence) }));
        };
        if (not MC.textFits(x.reason, T.MAX_JUSTIFICATION_BYTES) or Text.encodeUtf8(x.reason).size() == 0) {
          return #err(#ChargeError({ charge = x.charge; reason = "a waiver states why, within the bound" }));
        };
        // A waiver is a decision, never a deletion. Before application there is
        // nothing to reverse; after it there is exactly one posting to reverse, and
        // it is found by the key the application derived rather than by an index
        // someone stored.
        switch (ProductCore.chargeApplied(bs.product, productBlocks(bb), a.id, x.charge, x.occurrence)) {
          case null {
            #ok({ bankEvent = ?#product(#chargeWaived({ account = x.account; charge = x.charge; occurrence = x.occurrence; reversalOf = null; reason = x.reason })); extra = []; journal = [] })
          };
          case (?_) {
            let key = Posting.key("charge", [Nat.toText(x.account), x.charge, Nat.toText(x.occurrence)]);
            let ?original = JCore.postingIndexByKey(js, journalCaller, key) else {
              return #err(#ChargeError({ charge = x.charge; reason = "the charge is recorded as applied but its posting cannot be found by its derived key" }));
            };
            let args : JCore.ReverseArgs = {
              idempotencyKey = Posting.key("charge-waiver", [Nat.toText(x.account), x.charge, Nat.toText(x.occurrence)]);
              postingDate = x.postingDate;
              valueDate = x.valueDate;
              period = x.period;
              narration = x.reason;
              sourceRef = { kind = "charge-waiver"; id = authId };
            };
            switch (JCore.prepareReverse(js, jb, journalCaller, now, original, args)) {
              case (#err(e)) #err(#JournalError({ error = e }));
              case (#ok(#event(e))) #ok({
                bankEvent = ?#product(#chargeWaived({ account = x.account; charge = x.charge; occurrence = x.occurrence; reversalOf = ?original; reason = x.reason }));
                extra = []; journal = [#event(e)];
              });
              case (#ok(#duplicate(idx))) #ok({
                bankEvent = ?#product(#chargeWaived({ account = x.account; charge = x.charge; occurrence = x.occurrence; reversalOf = ?original; reason = x.reason }));
                extra = []; journal = [#existing(idx)];
              });
            }
          };
        }
      };

      case (#postAccrual(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_INTEREST)) { case (?e) return #err(e); case null {} };
        switch (accrualFor(bs, bb, js, x.product, x.currency, x.day)) {
          case (#err(e)) #err(e);
          case (#ok(r)) {
            let ?v = ProductCore.currentVersion(bs.product, x.product) else return #err(#ProductError({ error = #UnknownProduct({ product = x.product }) }));
            // A day on which nothing accrued is still a day the run happened, and the
            // block records it with an amount of zero and no posting. The distinction
            // matters twice: the journal refuses a zero-amount leg, so there is
            // nothing to post; and the period close needs evidence that *every*
            // business day was run, which a refusal would not give it. The accounts
            // examined are reported either way.
            // the part held in suspense (collections and recovery): its own posting to the suspense role and a block per exposure
            var suspenseJournal : [JournalStep] = [];
            var suspenseExtra : [T.Event] = [];
            if (r.suspended.size() > 0) {
              var total = 0;
              for ((_, amt) in r.suspended.vals()) total += amt;
              let ?receivable = Products.roleAccount(v.terms, #interestReceivable) else return #err(#ProductError({ error = #RoleUnmapped({ product = x.product; role = "interestReceivable" }) }));
              let ?suspense = Products.roleAccount(v.terms, #suspense) else return #err(#ProductError({ error = #RoleUnmapped({ product = x.product; role = "suspense" }) }));
              switch (postOne(js, journalCaller, now, Posting.simple("accrual-suspense", [x.product, x.currency, Nat.toText(x.day)],
                Posting.leg(receivable, null, #debit, x.currency, total), Posting.leg(suspense, null, #credit, x.currency, total), x.day, x.day, x.period, x.narration # " (held in suspense)"))) {
                case (#err(e)) return #err(e);
                case (#ok(plan)) {
                  suspenseJournal := plan.journal;
                  suspenseExtra := Array.map<(ProdT.AccountId, Nat), T.Event>(r.suspended, func((account, amount)) { #collections(#interestSuspended({ account; amount; day = x.day })) });
                };
              };
            };
            if (r.amount == 0) {
              return #ok({
                bankEvent = ?#product(#accrualPosted({ product = x.product; currency = x.currency; day = x.day; amount = 0; accounts = r.examined }));
                extra = suspenseExtra; journal = suspenseJournal;
              });
            };
            switch (accrualLegs(v.terms, x.currency, r.amount)) {
              case (#err(e)) #err(e);
              case (#ok((debit, credit))) {
                switch (postOne(js, journalCaller, now, Posting.simple("accrual", [x.product, x.currency, Nat.toText(x.day)], debit, credit, x.day, x.day, x.period, x.narration))) {
                  case (#err(e)) #err(e);
                  case (#ok(plan)) #ok({
                    bankEvent = ?#product(#accrualPosted({ product = x.product; currency = x.currency; day = x.day; amount = r.amount; accounts = r.accounts }));
                    extra = suspenseExtra; journal = Array.concat<JournalStep>(plan.journal, suspenseJournal);
                  });
                }
              };
            }
          };
        }
      };

      case (#capitaliseInterest(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_INTEREST)) { case (?e) return #err(e); case null {} };
        capitalisePlan(bs, bb, js, journalCaller, now, x, authId)
      };

      case (#disburseLoan(m)) {
        switch (requireFeature(bs, ProdT.FEATURE_CREDIT)) { case (?e) return #err(e); case null {} };
        switch (movableAccount(bs, bb, js, m.account, m.postingDate)) {
          case (#err(e)) #err(e);
          case (#ok((a, terms))) {
            if (terms.kind != #loan) {
              return #err(#ProductError({ error = #AccountNotOfKind({ account = m.account; expected = "loan"; actual = debug_show (terms.kind) }) }));
            };
            if (a.disbursed != null) return #err(#ProductError({ error = #LoanAlreadyDisbursed({ account = m.account }) }));
            if (m.amount == 0) return #err(#ProductError({ error = #InvalidTerms({ reason = "a disbursement of zero moves nothing" }) }));
            let ?sch = terms.schedule else return #err(#ProductError({ error = #ScheduleRequired({ product = a.product }) }));
            let ?it = terms.interest else return #err(#ProductError({ error = #InvalidTerms({ reason = "a loan product needs interest terms" }) }));
            let rate = switch (a.openingRate) {
              case (?r) r;
              case null {
                switch (Products.rateAt(it.chart, if (it.chart.by == #balance) m.amount else sch.instalments * ProdT.periodDays(sch.every))) {
                  case (?r) r;
                  case null return #err(#TermError({ reason = "no rate band covers this loan" }));
                }
              };
            };
            let valueDate = switch (valueDateGate(bs, js, a.book, m.period, terms.valueDateConvention, m.valueDate)) {
              case (#err(e)) return #err(e);
              case (#ok(d)) d;
            };
            let generated = Products.schedule(m.amount, rate, sch, terms.rounding, valueDate);
            let faults = Products.scheduleFaults(m.amount, generated.rows);
            if (faults.size() > 0) return #err(#ProductError({ error = #InvalidSchedule({ reason = faults[0] }) }));
            switch (fundingLeg(bs, bb, js, terms, m.funding, a.currency, #credit, m.amount)) {
              case (#err(e)) #err(e);
              case (#ok(sink)) {
                let debit = Posting.leg(terms.control, ?a.subledger, #debit, a.currency, m.amount);
                switch (postOne(js, journalCaller, now, Posting.simple("disbursement", [authId, Nat.toText(m.account)], debit, sink, m.postingDate, valueDate, m.period, m.narration))) {
                  case (#err(e)) #err(e);
                  case (#ok(plan)) #ok({
                    bankEvent = ?#product(#loanDisbursed({ account = m.account; amount = m.amount; day = valueDate; schedule = generated.rows }));
                    extra = []; journal = plan.journal;
                  });
                }
              };
            }
          };
        }
      };

      case (#repayLoan(m)) {
        switch (requireFeature(bs, ProdT.FEATURE_CREDIT)) { case (?e) return #err(e); case null {} };
        switch (repayPlan(bs, bb, js, journalCaller, now, m, authId)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) {
            // a drawing of a facility (corporate lending): a syndicate shares what was received; a drawing repaid in full closes
            let ?#product(#repaymentReceived(rep)) = plan.bankEvent else return #ok(plan);
            let extra = List.empty<T.Event>();
            for (ev in plan.extra.vals()) List.add(extra, ev);
            let journal = List.empty<JournalStep>();
            for (st in plan.journal.vals()) List.add(journal, st);
            switch (syndicationOnRepayment(bs, bb, js, journalCaller, now, authId, m.account, rep.applied, m, rep.day)) {
              case (#err(e)) return #err(e);
              case (#ok(?share)) { List.add(extra, share.event); for (st in share.journal.vals()) List.add(journal, st) };
              case (#ok(null)) {};
            };
            switch (FacilityCore.facilityOfDrawing(bs.facility, m.account)) {
              case (?fid) {
                switch (creditAccount(bs, bb, js, m.account, rep.day)) {
                  case (#ok((a, terms))) { if (Loans.allocationTotal(loanOutstanding(js, a, terms, rep.day)) == m.amount) List.add(extra, #facility(#drawingClosed({ facility = fid; account = m.account; day = rep.day }))) };
                  case (#err(_)) {};
                };
              };
              case null {};
            };
            #ok({ bankEvent = plan.bankEvent; extra = List.toArray(extra); journal = List.toArray(journal) })
          };
        }
      };

      case (#rescheduleLoan(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_CREDIT)) { case (?e) return #err(e); case null {} };
        reschedulePlan(bs, bb, js, journalCaller, now, authId, x.account, x.effective, x.terms, x.rate, true)
      };

      case (#setProvision(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_CREDIT)) { case (?e) return #err(e); case null {} };
        provisionPlan(bs, bb, js, journalCaller, now, x)
      };

      case (#writeOffLoan(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_CREDIT)) { case (?e) return #err(e); case null {} };
        writeOffPlan(bs, bb, js, journalCaller, now, x, authId)
      };

      case (#recordRecovery(m)) {
        switch (requireFeature(bs, ProdT.FEATURE_CREDIT)) { case (?e) return #err(e); case null {} };
        let ?a = ProductCore.get(bs.product, productBlocks(bb), m.account) else return #err(#ProductError({ error = #UnknownAccount({ account = m.account }) }));
        let ?terms = ProductCore.termsOf(bs.product, a) else return #err(#ProductError({ error = #UnknownVersion({ product = a.product; version = a.version }) }));
        if (not a.writtenOff) {
          return #err(#ProductError({ error = #InvalidTerms({ reason = "a recovery follows a write-off; this loan has not been written off" }) }));
        };
        if (m.amount == 0) return #err(#ProductError({ error = #InvalidTerms({ reason = "a recovery of zero moves nothing" }) }));
        let ?recovery = Products.roleAccount(terms, #recovery) else return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = "recovery" }) }));
        switch (fundingLeg(bs, bb, js, terms, m.funding, a.currency, #debit, m.amount)) {
          case (#err(e)) #err(e);
          case (#ok(source)) {
            let credit = Posting.leg(recovery, null, #credit, a.currency, m.amount);
            switch (postOne(js, journalCaller, now, Posting.simple("recovery", [authId, Nat.toText(m.account)], source, credit, m.postingDate, m.valueDate, m.period, m.narration))) {
              case (#err(e)) #err(e);
              case (#ok(plan)) #ok({
                bankEvent = ?#product(#recoveryReceived({ account = m.account; amount = m.amount; day = m.valueDate }));
                extra = switch (CollectionsCore.noteRecovered(bs.collections, m.account, m.amount, m.valueDate)) { case (?ev) [#collections(ev)]; case null [] };
                journal = plan.journal;
              });
            }
          };
        }
      };

      case (#redeemTermDeposit(m)) {
        switch (requireFeature(bs, ProdT.FEATURE_ACCOUNT_MONEY)) { case (?e) return #err(e); case null {} };
        redeemPlan(bs, bb, js, journalCaller, now, m, authId)
      };

      case (#allocateCashToTill(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_TILL)) { case (?e) return #err(e); case null {} };
        switch (openTill(bs, bb, x.till)) {
          case (#err(e)) #err(e);
          case (#ok((t, terms))) {
            if (x.amount == 0) return #err(#ProductError({ error = #InvalidTerms({ reason = "an allocation of zero moves nothing" }) }));
            let legs = Till.allocationLegs(terms.control, Till.vaultSubledger(t.book, t.currency), t.subledger, t.currency, x.amount);
            switch (postLegs(js, journalCaller, now, "till-allocation", [authId, x.till], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
              case (#err(e)) #err(e);
              case (#ok(plan)) #ok({
                bankEvent = ?#product(#tillAllocated({ till = x.till; amount = x.amount; day = x.valueDate }));
                extra = []; journal = plan.journal;
              });
            }
          };
        }
      };

      case (#returnCashFromTill(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_TILL)) { case (?e) return #err(e); case null {} };
        switch (openTill(bs, bb, x.till)) {
          case (#err(e)) #err(e);
          case (#ok((t, terms))) {
            if (x.amount == 0) return #err(#ProductError({ error = #InvalidTerms({ reason = "a return of zero moves nothing" }) }));
            let legs = Till.returnLegs(terms.control, Till.vaultSubledger(t.book, t.currency), t.subledger, t.currency, x.amount);
            switch (postLegs(js, journalCaller, now, "till-return", [authId, x.till], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
              case (#err(e)) #err(e);
              case (#ok(plan)) #ok({
                bankEvent = ?#product(#tillReturned({ till = x.till; amount = x.amount; day = x.valueDate }));
                extra = []; journal = plan.journal;
              });
            }
          };
        }
      };

      case (#settleTill(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_TILL)) { case (?e) return #err(e); case null {} };
        switch (openTill(bs, bb, x.till)) {
          case (#err(e)) #err(e);
          case (#ok((t, terms))) {
            let book = Till.bookBalance(js, terms.control, t.subledger, t.currency, x.valueDate);
            let diff = Till.difference(x.declared, book);
            let ?suspense = Products.roleAccount(terms, #suspense) else return #err(#ProductError({ error = #RoleUnmapped({ product = t.product; role = "suspense" }) }));
            // A settlement that agrees is a recorded fact with no posting: there is
            // nothing to move, and the journal refuses a posting that moves
            // nothing. A difference is posted to suspense with the cashier named;
            // there is no path that adjusts the till to match the count.
            switch (Till.settlementLegs(terms.control, t.subledger, suspense, t.currency, diff)) {
              case null #ok({
                bankEvent = ?#product(#tillSettled({ till = x.till; declared = x.declared; book; difference = diff; day = x.valueDate }));
                extra = []; journal = [];
              });
              case (?legs) {
                switch (postLegs(js, journalCaller, now, "till-settlement", [authId, x.till], legs, x.postingDate, x.valueDate, x.period, x.narration # " (cashier " # Principal.toText(t.holder) # ")")) {
                  case (#err(e)) #err(e);
                  case (#ok(plan)) #ok({
                    bankEvent = ?#product(#tillSettled({ till = x.till; declared = x.declared; book; difference = diff; day = x.valueDate }));
                    extra = []; journal = plan.journal;
                  });
                }
              };
            }
          };
        }
      };

      // ═══════════════════════════════════════════════════════
      //  VALUE DATING, FOREIGN CURRENCY AND THE CLOSE
      // ═══════════════════════════════════════════════════════
      //
      // Configuration first: a functional currency, the position pairs, the rates and
      // the back-value policy. None of it moves money; all of it is what the close
      // then computes from, which is why it is recorded rather than configured.

      case (#setFunctionalCurrency(x)) {
        if (JCore.currencyMinorUnits(js, x.currency) == null) {
          return #err(#CloseError({ error = #InvalidRate({ reason = "currency " # x.currency # " is not registered in the journal" }) }));
        };
        switch (CloseCore.functional(bs.close)) {
          case (?c) {
            // Changing it would restate every equivalent already on the books, so it
            // is set once. Setting it again to the same currency is a no-op.
            if (Text.equal(c, x.currency)) #ok({ bankEvent = null; extra = []; journal = [] })
            else #err(#CloseError({ error = #FunctionalCurrencyAlreadySet({ currency = c }) }))
          };
          case null #ok({ bankEvent = ?#close(#functionalCurrencySet({ currency = x.currency })); extra = []; journal = [] });
        }
      };

      case (#setFxPair(x)) {
        let ?functional = CloseCore.functional(bs.close) else return #err(#CloseError({ error = #NoFunctionalCurrency }));
        if (Text.equal(x.pair.currency, functional)) {
          return #err(#CloseError({ error = #InvalidPair({ reason = "the functional currency has no position against itself" }) }));
        };
        if (JCore.currencyMinorUnits(js, x.pair.currency) == null) {
          return #err(#CloseError({ error = #InvalidPair({ reason = "currency " # x.pair.currency # " is not registered in the journal" }) }));
        };
        // The pair's four accounts must exist, and each must carry the category its
        // role requires: the position is where the foreign currency sits, the
        // equivalent is what it was booked at, and the two result accounts are income
        // and expense in the accounting sense. Checked here so a revaluation cannot
        // discover it later.
        switch (requirePairAccounts(js, x.pair)) { case (?e) return #err(e); case null {} };
        #ok({ bankEvent = ?#close(#fxPairSet({ pair = x.pair })); extra = []; journal = [] })
      };

      case (#setFxRate(x)) {
        let ?functional = CloseCore.functional(bs.close) else return #err(#CloseError({ error = #NoFunctionalCurrency }));
        switch (Fx.validateRate(x.rate)) {
          case (?r) return #err(#CloseError({ error = #InvalidRate({ reason = r }) }));
          case null {};
        };
        if (not Text.equal(x.rate.functional, functional)) {
          return #err(#CloseError({ error = #InvalidRate({ reason = "the rate is quoted into " # x.rate.functional # "; the functional currency is " # functional }) }));
        };
        if (CloseCore.getPair(bs.close, x.rate.currency) == null) {
          return #err(#CloseError({ error = #UnknownPair({ currency = x.rate.currency }) }));
        };
        // A rate for a day already recorded is replaced only by an identical one;
        // a different rate for the same day would make a revaluation depend on which
        // block a reader stopped at.
        switch (CloseCore.rateOn(bs.close, x.rate.currency, x.rate.asOf)) {
          case (?existing) {
            if (existing.numerator == x.rate.numerator and existing.denominator == x.rate.denominator) {
              return #ok({ bankEvent = null; extra = []; journal = [] });
            };
            return #err(#CloseError({ error = #InvalidRate({
              reason = "a different rate is already recorded for " # x.rate.currency # " on day " # Nat.toText(x.rate.asOf);
            }) }));
          };
          case null {};
        };
        #ok({ bankEvent = ?#close(#fxRateSet({ rate = x.rate })); extra = []; journal = [] })
      };

      case (#setBackValueWindow(x)) {
        switch (PE.validateWindow(x.window)) {
          case (?r) return #err(#CloseError({ error = #InvalidWindow({ reason = r }) }));
          case null {};
        };
        switch (requireOpenBook(bs, x.window.book)) { case (?e) return #err(e); case null {} };
        #ok({ bankEvent = ?#close(#backValueWindowSet({ window = x.window })); extra = []; journal = [] })
      };

      case (#approveBackValue(x)) {
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        if (not MC.textFits(x.reason, T.MAX_JUSTIFICATION_BYTES) or Text.encodeUtf8(x.reason).size() == 0) {
          return #err(#CloseError({ error = #InvalidWindow({ reason = "an approval states why, within the bound" }) }));
        };
        switch (CloseCore.approvalFor(bs.close, x.book, x.valueDate)) {
          case (?_) return #err(#CloseError({ error = #BackValueApprovalExists({ book = x.book; valueDate = x.valueDate }) }));
          case null {};
        };
        // An approval cannot reach past the window the policy allows at all: beyond
        // that, no authority admits the posting.
        let ?today = JCore.businessDate(js) else return #err(#CloseError({ error = #AccrualIncomplete({ reason = "no business date is set" }) }));
        let w = CloseCore.window(bs.close, x.book);
        let back = Conv.businessDaysApart(JCore.calendar(js), x.valueDate, today);
        switch (PE.classifyBackValue(w, back)) {
          case (#beyondWindow(d)) return #err(#CloseError({ error = #BackValueBeyondWindow({ businessDaysBack = d.businessDaysBack; freeDays = w.freeDays; approvedDays = w.approvedDays }) }));
          case (_) {};
        };
        #ok({ bankEvent = ?#close(#backValueApproved({ book = x.book; valueDate = x.valueDate; approver = journalCaller; reason = x.reason })); extra = []; journal = [] })
      };

      case (#openDeferralSchedule(x)) {
        switch (Deferrals.validate(x.schedule)) {
          case (?#invalid(d)) return #err(#CloseError({ error = #InvalidSchedule({ reason = d.reason }) }));
          case (?_) return #err(#CloseError({ error = #InvalidSchedule({ reason = "invalid schedule" }) }));
          case null {};
        };
        switch (requireOpenBook(bs, x.schedule.book)) { case (?e) return #err(e); case null {} };
        switch (CloseCore.getSchedule(bs.close, x.schedule.id)) {
          case (?_) return #err(#CloseError({ error = #ScheduleExists({ schedule = x.schedule.id }) }));
          case null {};
        };
        if (JCore.currencyMinorUnits(js, x.schedule.currency) == null) {
          return #err(#CloseError({ error = #InvalidSchedule({ reason = "currency " # x.schedule.currency # " is not registered in the journal" }) }));
        };
        switch (requirePostableAccount(js, x.schedule.deferralAccount)) { case (?e) return #err(e); case null {} };
        switch (requirePostableAccount(js, x.schedule.recognitionAccount)) { case (?e) return #err(e); case null {} };
        // The faults the schedule's own arithmetic can have are checked when it is
        // written, not when it fails to close to zero a year later.
        let faults = Deferrals.faults(x.schedule);
        if (faults.size() > 0) return #err(#CloseError({ error = #InvalidSchedule({ reason = faults[0] }) }));
        #ok({ bankEvent = ?#close(#deferralScheduleOpened({ schedule = x.schedule })); extra = []; journal = [] })
      };

      // ── money-visible ──

      case (#bookFxDeal(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_FX)) { case (?e) return #err(e); case null {} };
        fxDealPlan(bs, bb, js, journalCaller, now, x, authId)
      };

      case (#realiseFxPosition(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_FX)) { case (?e) return #err(e); case null {} };
        let ?functional = CloseCore.functional(bs.close) else return #err(#CloseError({ error = #NoFunctionalCurrency }));
        let ?pair = CloseCore.getPair(bs.close, x.currency) else return #err(#CloseError({ error = #UnknownPair({ currency = x.currency }) }));
        if (x.closedPosition == 0) return #err(#CloseError({ error = #NothingToRevalue({ currency = x.currency }) }));
        let r = Fx.realise(x.currency, x.closedPosition, x.bookedEquivalent, x.proceeds);
        let ev : T.Event = #close(#fxRealised({
          currency = x.currency; closedPosition = x.closedPosition;
          bookedEquivalent = x.bookedEquivalent; proceeds = x.proceeds;
          movement = r.movement; direction = r.direction; day = x.valueDate;
        }));
        switch (Fx.realisationLegs(pair, functional, r)) {
          case null #ok({ bankEvent = ?ev; extra = []; journal = [] });
          case (?legs) {
            switch (postLegs(js, journalCaller, now, "fx-realised", [authId, x.currency], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
              case (#err(e)) #err(e);
              case (#ok(plan)) #ok({ bankEvent = ?ev; extra = []; journal = plan.journal });
            }
          };
        }
      };

      case (#adjustAccrual(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_INTEREST)) { case (?e) return #err(e); case null {} };
        adjustAccrualPlan(bs, bb, js, journalCaller, now, x)
      };

      case (#amortiseDeferral(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_DEFERRALS)) { case (?e) return #err(e); case null {} };
        amortiseOnePlan(bs, js, journalCaller, now, x.schedule, x.period, x.postingDate, x.valueDate, x.narration)
      };

      // ── the close, step by step ──

      case (#openPeriodEnd(x)) {
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        // The deployment invariant: this layer is the only thing that moves a value
        // date. A close cannot even be opened while the journal would shift one.
        switch (Conv.requiresRejectPolicy(JCore.calendar(js))) {
          case (?r) return #err(#CloseError({ error = #CalendarPolicy({ reason = r }) }));
          case null {};
        };
        switch (CloseCore.getRun(bs.close, x.book, x.period)) {
          case (?_) return #err(#CloseError({ error = #RunExists({ book = x.book; period = x.period }) }));
          case null {};
        };
        let ?period = JCore.getPeriod(js, x.period) else return #err(#CloseError({ error = #UnknownRun({ book = x.book; period = x.period }) }));
        if (period.status == #closed) return #err(#CloseError({ error = #BookClosedForPeriod({ book = x.book; period = x.period }) }));
        // the close is struck at the last business day of the period
        let ?closingDate = Conv.lastBusinessDayOnOrBefore(JCore.calendar(js), period.end) else {
          return #err(#CloseError({ error = #AccrualIncomplete({ reason = "the period contains no business day" }) }));
        };
        #ok({ bankEvent = ?#close(#periodEndOpened({ book = x.book; period = x.period; closingDate })); extra = []; journal = [] })
      };

      case (#recordClosingRates(x)) {
        switch (runStep(bs, x.book, x.period, #ratesRecorded)) {
          case (#err(e)) #err(e);
          case (#ok(#idempotent)) #ok({ bankEvent = null; extra = []; journal = [] });
          case (#ok(#go(run))) {
            // every pair must have a rate recorded for this run's own closing date;
            // an earlier day's rate is never substituted
            var currencies = 0;
            for (pair in CloseCore.listPairs(bs.close).vals()) {
              if (pair.monetary) {
                switch (CloseCore.rateOn(bs.close, pair.currency, run.closingDate)) {
                  case null return #err(#CloseError({ error = #MissingRate({ currency = pair.currency; asOf = run.closingDate }) }));
                  case (?_) currencies += 1;
                };
              };
            };
            #ok({ bankEvent = ?#close(#periodEndRatesRecorded({ book = x.book; period = x.period; currencies })); extra = []; journal = [] })
          };
        }
      };

      case (#markAccrualComplete(x)) {
        switch (runStep(bs, x.book, x.period, #accrualComplete)) {
          case (#err(e)) #err(e);
          case (#ok(#idempotent)) #ok({ bankEvent = null; extra = []; journal = [] });
          case (#ok(#go(run))) {
            // A period cannot close over an incomplete day. Two things are checked:
            // the business date has reached the period's last business day, and every
            // product has posted an accrual for every business day of the period.
            let ?today = JCore.businessDate(js) else return #err(#CloseError({ error = #AccrualIncomplete({ reason = "no business date is set" }) }));
            if (today < run.closingDate) {
              return #err(#CloseError({ error = #BusinessDayNotRolled({ lastBusinessDay = run.closingDate; businessDate = today }) }));
            };
            let ?period = JCore.getPeriod(js, x.period) else return #err(#CloseError({ error = #UnknownRun({ book = x.book; period = x.period }) }));
            switch (accrualGaps(bs, bb, js, period.start, run.closingDate)) {
              case (?reason) return #err(#CloseError({ error = #AccrualIncomplete({ reason }) }));
              case null {};
            };
            #ok({ bankEvent = ?#close(#periodEndAccrualComplete({ book = x.book; period = x.period; lastBusinessDay = run.closingDate })); extra = []; journal = [] })
          };
        }
      };

      case (#revaluePositions(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_FX)) { case (?e) return #err(e); case null {} };
        revaluePlan(bs, js, journalCaller, now, x)
      };

      case (#amortisePeriodDeferrals(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_DEFERRALS)) { case (?e) return #err(e); case null {} };
        amortisePeriodPlan(bs, js, journalCaller, now, x)
      };

      case (#reconcilePeriod(x)) {
        switch (runStep(bs, x.book, x.period, #reconciled)) {
          case (#err(e)) #err(e);
          case (#ok(#idempotent)) #ok({ bankEvent = null; extra = []; journal = [] });
          case (#ok(#go(_))) {
            // Two checks, both folds over the same log and therefore a
            // self-consistency proof rather than a reconciliation between databases:
            // the trial balance balances per currency, and every account's maintained
            // balance equals the sum of its postings' legs.
            let ?tb = JCore.trialBalance(js, x.period) else return #err(#CloseError({ error = #NoTrialBalance({ period = x.period }) }));
            let unbalanced = PE.unbalancedCurrencies(tb.totals);
            if (unbalanced.size() > 0) {
              return #err(#CloseError({ error = #TrialBalanceUnbalanced({ currency = unbalanced[0] }) }));
            };
            // A permanently failing batch item stops the period close, which a human
            // sees, rather than stopping the batch, which nobody sees.
            let ?p = JCore.getPeriod(js, x.period) else return #err(#CloseError({ error = #NoTrialBalance({ period = x.period }) }));
            let outstanding = BatchCore.unresolvedFailures(bs.batch, x.book, p.start, p.end);
            if (outstanding > 0) {
              return #err(#BatchError({ error = #UnresolvedFailures({ book = x.book; businessDate = p.end; failures = outstanding }) }));
            };
            switch (controlDivergence(bs, js, jb)) {
              case (?c) return #err(#CloseError({ error = #ControlAccountDivergence({
                account = c.account; currency = c.currency;
                ledgerDebits = c.ledgerDebits; ledgerCredits = c.ledgerCredits;
                subledgerDebits = c.subledgerDebits; subledgerCredits = c.subledgerCredits;
              }) }));
              case null {};
            };
            #ok({ bankEvent = ?#close(#periodEndReconciled({ book = x.book; period = x.period; controls = controlCount(bs) })); extra = []; journal = [] })
          };
        }
      };

      case (#rollYearEnd(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_INTEREST)) { case (?e) return #err(e); case null {} };
        let ?run = CloseCore.getRun(bs.close, x.book, x.period) else {
          return #err(#CloseError({ error = #UnknownRun({ book = x.book; period = x.period }) }));
        };
        // The roll sits between `reconciled` and `closed`. Before `reconciled` the
        // result is not complete — the accruals, the revaluation and the deferrals of
        // the period are what make it so — and after `closed` the journal will not
        // book into the period at all, which is the hard stop this relies on rather
        // than works around.
        if (run.state != #reconciled) {
          return #err(#CloseError({ error = #NotReconciled({ book = x.book; period = x.period; state = PE.stateText(run.state) }) }));
        };
        if (CloseCore.yearRolled(bs.close, x.book, x.period)) {
          return #err(#CloseError({ error = #YearEndAlreadyRolled({ book = x.book; period = x.period }) }));
        };
        let args : YearEnd.RollArgs = {
          closingPeriod = x.period;
          retainedEarnings = x.retainedEarnings;
          keyPrefix = Posting.key("year-end", [x.book, x.period]);
          narration = x.narration;
        };
        switch (YearEnd.plan(js, args)) {
          case (#err(e)) #err(#CloseError({ error = #YearEndError({ reason = debug_show (e) }) }));
          case (#ok(plan)) {
            switch (JCore.prepareBatch(js, journalCaller, now, plan.postings)) {
              case (#err(b)) #err(#JournalBatchError({ index = b.index; error = b.error }));
              case (#ok(prepared)) {
                let steps = List.empty<JournalStep>();
                for (pr in prepared.vals()) {
                  switch (pr) { case (#event(e)) List.add(steps, #event(e)); case (#duplicate(i)) List.add(steps, #existing(i)) };
                };
                #ok({
                  bankEvent = ?#close(#yearEndRolled({
                    book = x.book; period = x.period; retainedEarnings = x.retainedEarnings;
                    accountsClosed = plan.accountsClosed; results = plan.results;
                  }));
                  extra = []; journal = List.toArray(steps);
                })
              };
            }
          };
        }
      };

      // ═══════════════════════════════════════════════════════
      //  THE END-OF-DAY BATCH
      // ═══════════════════════════════════════════════════════

      case (#setRetryPolicy(x)) {
        switch (Batch.validateRetry(x.policy)) {
          case (?r) return #err(#BatchError({ error = #InvalidRetryPolicy({ reason = r }) }));
          case null {};
        };
        switch (requireOpenBook(bs, x.policy.book)) { case (?e) return #err(e); case null {} };
        #ok({ bankEvent = ?#batch(#retryPolicySet({ policy = x.policy })); extra = []; journal = [] })
      };

      case (#defineStandingInstruction(x)) {
        let si = x.instruction;
        if (not validIdentifier(si.id, T.MAX_BOOK_ID_BYTES)) {
          return #err(#BatchError({ error = #InvalidInstruction({ reason = "an instruction id must be 1.." # Nat.toText(T.MAX_BOOK_ID_BYTES) # " characters of [A-Za-z0-9-_.]" }) }));
        };
        switch (BatchCore.getInstruction(bs.batch, si.id)) {
          case (?_) return #err(#BatchError({ error = #InstructionExists({ id = si.id }) }));
          case null {};
        };
        switch (requireOpenBook(bs, si.book)) { case (?e) return #err(e); case null {} };
        if (si.amount == 0) return #err(#BatchError({ error = #InvalidInstruction({ reason = "an instruction for zero moves nothing" }) }));
        if (si.everyDays == 0) return #err(#BatchError({ error = #InvalidInstruction({ reason = "a recurrence of zero days never falls due" }) }));
        if (si.from == si.to) return #err(#BatchError({ error = #InvalidInstruction({ reason = "an instruction cannot pay itself" }) }));
        switch (si.endDay) {
          case (?e) { if (e < si.startDay) return #err(#BatchError({ error = #InvalidInstruction({ reason = "the instruction ends before it starts" }) })) };
          case null {};
        };
        // both accounts must exist, be in the instruction's book and its currency
        for (id in [si.from, si.to].vals()) {
          switch (requireAccount(bs, bb, id)) {
            case (#err(e)) return #err(e);
            case (#ok((a, _))) {
              if (not Text.equal(a.currency, si.currency)) {
                return #err(#ProductError({ error = #CurrencyMismatch({ expected = a.currency; actual = si.currency }) }));
              };
              if (not Text.equal(a.book, si.book)) return #err(#OutsideBookScope({ book = si.book }));
            };
          };
        };
        #ok({ bankEvent = ?#batch(#standingInstructionDefined({ instruction = si })); extra = []; journal = [] })
      };

      case (#cancelStandingInstruction(x)) {
        let ?e = BatchCore.getInstruction(bs.batch, x.id) else {
          return #err(#BatchError({ error = #UnknownInstruction({ id = x.id }) }));
        };
        if (e.cancelled) return #ok({ bankEvent = null; extra = []; journal = [] });
        #ok({ bankEvent = ?#batch(#standingInstructionCancelled({ id = x.id })); extra = []; journal = [] })
      };

      // ── reporting. None of these posts; each records what a report was computed
      // from, or that an artefact was certified. ──

      case (#registerReportDefinition(x)) {
        switch (Reports.validateDef(x.definition)) {
          case (?e) return #err(#ReportError({ error = e }));
          case null {};
        };
        // A version is immutable once registered, so "report R34 version 2" names exact
        // arithmetic for ever and an amendment is a new version with the old one still
        // evaluable.
        switch (ReportCore.getDef(bs.report, x.definition.id, x.definition.version)) {
          case (?_) return #err(#ReportError({ error = #DefinitionExists({ definition = x.definition.id; version = x.definition.version }) }));
          case null {};
        };
        #ok({
          bankEvent = ?#report(#reportDefinitionRegistered({ definition = x.definition; hash = Reports.defHash(x.definition) }));
          extra = []; journal = [];
        })
      };

      case (#registerReturnTemplate(x)) {
        switch (ReturnsM.validate(x.template)) {
          case (?e) return #err(#ReportError({ error = e }));
          case null {};
        };
        switch (ReportCore.getTemplate(bs.report, x.template.id, x.template.version)) {
          case (?_) return #err(#ReportError({ error = #TemplateExists({ template = x.template.id; version = x.template.version }) }));
          case null {};
        };
        #ok({
          bankEvent = ?#report(#returnTemplateRegistered({ template = x.template; hash = ReturnsM.templateHash(x.template) }));
          extra = []; journal = [];
        })
      };

      case (#setStatementMap(x)) {
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        // every account the map names has to exist, because a statement map that points at
        // nothing produces a cash-flow statement that reconciles by accident
        for (code in x.map.cash.vals()) {
          if (JCore.getAccount(js, code) == null) return #err(#JournalConfigError({ error = #UnknownAccount({ code }) }));
        };
        if (JCore.getAccount(js, x.map.retainedEarnings) == null) {
          return #err(#JournalConfigError({ error = #UnknownAccount({ code = x.map.retainedEarnings }) }));
        };
        for (code in x.map.investing.vals()) {
          if (JCore.getAccount(js, code) == null) return #err(#JournalConfigError({ error = #UnknownAccount({ code }) }));
        };
        for (code in x.map.financing.vals()) {
          if (JCore.getAccount(js, code) == null) return #err(#JournalConfigError({ error = #UnknownAccount({ code }) }));
        };
        for (code in x.map.monetary.vals()) {
          if (JCore.getAccount(js, code) == null) return #err(#JournalConfigError({ error = #UnknownAccount({ code }) }));
        };
        #ok({ bankEvent = ?#report(#statementMapSet({ book = x.book; map = x.map })); extra = []; journal = [] })
      };

      case (#certifyReport(x)) {
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        let ?entry = ReportCore.getDef(bs.report, x.definition, x.version) else {
          return #err(#ReportError({ error = #UnknownDefinition({ definition = x.definition; version = x.version }) }));
        };
        let params : RepT.ReportParams = {
          book = x.book; period = x.period; view = x.view; functional = x.functional;
        };
        switch (Reports.evaluate(js, jb, entry.definition, params, reportContext(bs, bb, js, entry.definition), bs.height)) {
          case (#err(e)) #err(#ReportError({ error = e }));
          case (#ok(r)) {
            #ok({
              bankEvent = ?#report(#reportCertified({
                kind = "report"; id = x.definition; book = x.book; period = x.period;
                atHeight = r.atHeight; contentHash = r.contentHash; rows = r.rowCount;
              }));
              extra = []; journal = [];
            })
          };
        }
      };

      case (#certifyReturn(x)) {
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        let ?entry = ReportCore.getTemplate(bs.report, x.template, x.version) else {
          return #err(#ReportError({ error = #UnknownTemplate({ template = x.template; version = x.version }) }));
        };
        switch (ReturnsM.evaluate(js, entry.template, x.book, x.period)) {
          case (#err(e)) #err(#ReportError({ error = e }));
          case (#ok(r)) {
            #ok({
              bankEvent = ?#report(#reportCertified({
                kind = "return"; id = x.template; book = x.book; period = x.period;
                atHeight = r.atHeight; contentHash = r.contentHash; rows = r.values.size();
              }));
              extra = []; journal = [];
            })
          };
        }
      };

      case (#certifyExport(x)) {
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        switch (Filings.exportResult(js, jb, x.shape, x.book, x.period)) {
          case (#err(e)) #err(#ReportError({ error = e }));
          case (#ok(r)) {
            #ok({
              bankEvent = ?#report(#reportCertified({
                kind = "export"; id = exportShapeName(x.shape); book = x.book; period = x.period;
                atHeight = r.atHeight; contentHash = r.contentHash; rows = r.lines.size();
              }));
              extra = []; journal = [];
            })
          };
        }
      };

      case (#issueStatement(x)) {
        switch (statementRefFor(bs, bb, js, jb, x.account, x.kind, x.period)) {
          case (#err(e)) #err(e);
          case (#ok(ref)) #ok({ bankEvent = ?#report(#statementIssued({ statement = ref })); extra = []; journal = [] });
        }
      };

      case (#setFeedEndpoint(x)) {
        switch (FeedM.validateEndpoint(x.endpoint)) {
          case (?e) return #err(#ReportError({ error = e }));
          case null {};
        };
        if (ReportCore.endpoint(bs.report, x.endpoint.url) == null
            and ReportCore.endpointCount(bs.report) >= RepT.MAX_ENDPOINTS) {
          return #err(#ReportError({ error = #InvalidEndpoint({ reason = "at most " # Nat.toText(RepT.MAX_ENDPOINTS) # " endpoints" }) }));
        };
        #ok({ bankEvent = ?#report(#feedEndpointSet({ endpoint = x.endpoint })); extra = []; journal = [] })
      };

      case (#recordFeedDeadLetter(x)) {
        // A dead letter names an endpoint the bank recorded. One naming anything else would
        // be a record of a push to somewhere nobody authorised, which is the thing the
        // recorded-endpoint rule exists to make impossible.
        let ?ep = ReportCore.endpoint(bs.report, x.letter.endpoint) else {
          return #err(#ReportError({ error = #EndpointNotRecorded({ url = x.letter.endpoint }) }));
        };
        if (x.letter.attempts == 0 or x.letter.attempts > ep.retries.size() + 1) {
          return #err(#ReportError({ error = #InvalidEndpoint({
            reason = "the endpoint declares " # Nat.toText(ep.retries.size()) # " retries, so at most "
              # Nat.toText(ep.retries.size() + 1) # " attempts; " # Nat.toText(x.letter.attempts) # " were reported";
          }) }));
        };
        if (Text.encodeUtf8(x.letter.reason).size() == 0) {
          return #err(#ReportError({ error = #InvalidEndpoint({ reason = "a dead letter states why it is dead" }) }));
        };
        #ok({ bankEvent = ?#report(#feedDeadLettered({ letter = x.letter })); extra = []; journal = [] })
      };

      // ── indexing: the one declared decision the indexes need ──

      case (#setCounterpartyClassDimension(x)) {
        switch (x.dimension) {
          case null {
            // Clearing when nothing is declared would be a block that changes nothing, and a log
            // of acts that change nothing is a log nobody reads.
            switch (IndexCore.classDimension(bs.index)) {
              case null return #err(#IndexError({ error = #InvalidClassDimension({ reason = "no counterparty-class dimension is declared, so there is nothing to clear" }) }));
              case (?_) {};
            };
          };
          case (?d) {
            if (not IdxT.validPart(d.schema) or not IdxT.validPart(d.field)) {
              return #err(#IndexError({ error = #InvalidClassDimension({
                reason = "a schema and field are each 1.." # Nat.toText(IdxT.MAX_DIMENSION_PART_BYTES) # " characters of [A-Za-z0-9-_.]";
              }) }));
            };
            // The dimension must name a field of a registered party schema. A declaration naming a
            // field nothing records would produce an index with no rows and no error, which is the
            // worst of both: a query that answers "nothing" for a reason nobody can see.
            let ?sch = PartyCore.getSchema(bs.party, d.schema) else {
              return #err(#IndexError({ error = #InvalidClassDimension({ reason = "schema " # d.schema # " is not registered" }) }));
            };
            switch (sch.entity) {
              case (#party) {};
              case (#collateral) return #err(#IndexError({ error = #InvalidClassDimension({ reason = "schema " # d.schema # " classifies collateral, not parties" }) }));
            };
            var found = false;
            for (f in sch.fields.vals()) { if (Text.equal(f.name, d.field)) found := true };
            if (not found) {
              return #err(#IndexError({ error = #InvalidClassDimension({ reason = "schema " # d.schema # " has no field " # d.field }) }));
            };
            switch (IndexCore.classDimension(bs.index)) {
              case (?cur) {
                if (Text.equal(cur.schema, d.schema) and Text.equal(cur.field, d.field)) {
                  return #err(#IndexError({ error = #InvalidClassDimension({ reason = "that dimension is already the declared one" }) }));
                };
              };
              case null {};
            };
          };
        };
        #ok({ bankEvent = ?#index(#counterpartyClassDimensionSet({ dimension = x.dimension })); extra = []; journal = [] })
      };

      // ── archive contracts: the decisions; the steps are methods (`ArchiveTypes.mo`) ──

      case (#pinArchiveImage(x)) {
        switch (ArchiveCore.planPin(bs.archive, x.sha256, x.bytes, x.name)) {
          case (#err(e)) #err(#ArchiveError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#archive(ev); extra = []; journal = [] });
        }
      };
      case (#setArchiveControllers(x)) {
        switch (ArchiveCore.planSetControllers(bs.archive, x.controllers)) {
          case (#err(e)) #err(#ArchiveError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#archive(ev); extra = []; journal = [] });
        }
      };
      case (#spawnArchive(x)) {
        switch (ArchiveCore.planSpawn(bs.archive, x.purpose)) {
          case (#err(e)) #err(#ArchiveError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#archive(ev); extra = []; journal = [] });
        }
      };
      case (#abandonArchiveSpawn(x)) {
        switch (ArchiveCore.planAbandon(bs.archive, x.spawn, x.reason)) {
          case (#err(e)) #err(#ArchiveError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#archive(ev); extra = []; journal = [] });
        }
      };
      case (#attachArchiveChild(x)) {
        switch (ArchiveCore.planAttach(bs.archive, x.spawn, x.cid)) {
          case (#err(e)) #err(#ArchiveError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#archive(ev); extra = []; journal = [] });
        }
      };
      case (#adoptArchiveChild(x)) {
        switch (ArchiveCore.planAdopt(bs.archive, x.cid, x.moduleHash, x.controllers, x.purpose)) {
          case (#err(e)) #err(#ArchiveError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#archive(ev); extra = []; journal = [] });
        }
      };

      // ── monitoring: the closed rule set ──

      case (#defineMonitoringRule(x)) {
        // a rule may not read where the daily rows have been rolled up: its window, from today,
        // must end after the packed boundary
        let w = MT.windowOf(x.spec);
        let today = JCore.effectiveToday(js, now);
        if (bs.packing.packedThroughDay > 0 and today <= bs.packing.packedThroughDay + w) {
          return #err(#PackingError({ error = #WindowReachesPacked({ windowDays = w; today; packedThroughDay = bs.packing.packedThroughDay }) }));
        };
        switch (MonitoringCore.planDefine(bs.monitoring, x.id, x.currency, x.spec)) {
          case (#err(e)) #err(#MonitoringError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#monitoring(ev); extra = []; journal = [] });
        }
      };
      case (#retireMonitoringRule(x)) {
        switch (MonitoringCore.planRetire(bs.monitoring, x.id)) {
          case (#err(e)) #err(#MonitoringError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#monitoring(ev); extra = []; journal = [] });
        }
      };

      // ── alerts: the review ──

      case (#clearAlert(x)) {
        switch (AlertCore.planClear(bs.alerts, x.alert, x.reason)) {
          case (#err(e)) #err(#AlertError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#alert(ev); extra = []; journal = [] });
        }
      };
      case (#escalateAlert(x)) {
        switch (AlertCore.planEscalate(bs.alerts, x.alert, x.reportRef)) {
          case (#err(e)) #err(#AlertError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#alert(ev); extra = []; journal = [] });
        }
      };

      // ── collections and recovery (collections and recovery): the decided transitions ──

      case (#setCollectionsPolicy(pol)) {
        switch (CollectionsCore.planPolicy(pol)) {
          case (#err(e)) #err(#CollectionsError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#collections(ev); extra = []; journal = [] });
        }
      };
      case (#markUnlikelyToPay(x)) {
        switch (requireLoanAccount(bs, bb, x.account)) { case (?e) return #err(e); case null {} };
        switch (CollectionsCore.planUnlikelyToPay(bs.collections, x.account, x.reason, JCore.effectiveToday(js, now))) {
          case (#err(e)) #err(#CollectionsError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#collections(ev); extra = []; journal = [] });
        }
      };
      case (#recordCollectionAction(x)) {
        switch (requireLoanAccount(bs, bb, x.account)) { case (?e) return #err(e); case null {} };
        switch (CollectionsCore.planAction(bs.collections, x.account, x.action, x.outcome, x.next, JCore.effectiveToday(js, now))) {
          case (#err(e)) #err(#CollectionsError({ error = e }));
          case (#ok(evs)) #ok({ bankEvent = ?#collections(evs[0]); extra = Array.map<ColT.CollectionsEvent, T.Event>(Array.sliceToArray<ColT.CollectionsEvent>(evs, 1, evs.size()), func(e) { #collections(e) }); journal = [] });
        }
      };
      case (#recordPromiseToPay(x)) {
        switch (requireLoanAccount(bs, bb, x.account)) { case (?e) return #err(e); case null {} };
        let ?acct = ProductCore.get(bs.product, productBlocks(bb), x.account) else return #err(#ProductError({ error = #UnknownAccount({ account = x.account }) }));
        let ?acctTerms = ProductCore.termsOf(bs.product, acct) else return #err(#ProductError({ error = #UnknownVersion({ product = acct.product; version = acct.version }) }));
        let today = JCore.effectiveToday(js, now);
        switch (CollectionsCore.planPromise(bs.collections, x.account, x.amount, x.by, today, loanRepaid(js, acct, acctTerms, today))) {
          case (#err(e)) #err(#CollectionsError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#collections(ev); extra = []; journal = [] });
        }
      };
      case (#assignCollector(x)) {
        switch (requireLoanAccount(bs, bb, x.account)) { case (?e) return #err(e); case null {} };
        switch (CollectionsCore.planAssign(bs.collections, x.account, x.staff)) {
          case (#err(e)) #err(#CollectionsError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#collections(ev); extra = []; journal = [] });
        }
      };
      case (#closeRecovery(x)) {
        switch (CollectionsCore.planCloseRecovery(bs.collections, x.account, JCore.effectiveToday(js, now))) {
          case (#err(e)) #err(#CollectionsError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#collections(ev); extra = []; journal = [] });
        }
      };

      // ── origination and underwriting (origination and underwriting): the application's steps ──
      case (#setOriginationPolicy(pol)) originationPlan(OriginationCore.planPolicy(pol));
      case (#setAffordabilityModel(m)) originationPlan(OriginationCore.planAffordabilityModel(bs.origination, m));
      case (#setScorecard(c)) originationPlan(OriginationCore.planScorecard(bs.origination, c));
      case (#registerPasskey(x)) {
        switch (requireParty(bs, x.party)) { case (?e) return #err(e); case null {} };
        originationPlan(OriginationCore.planRegisterPasskey(bs.origination, x.party, x.credentialId, x.publicKeySpki))
      };
      case (#openApplication(x)) {
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        // an application for a customer is in the customer's book; a prospect's is in the book that opens it
        switch (x.party) {
          case (?party) {
            let ?pe = PartyCore.get(bs.party, partyBlocks(bb), party) else return #err(#PartyError({ error = #UnknownParty({ party }) }));
            if (not Text.equal(pe.book, x.book)) return #err(#OriginationError({ error = #PartyMismatch({ application = 0 }) }));
            if (pe.lifecycle != #active) return #err(#PartyError({ error = #PartyNotActive({ party; lifecycle = pe.lifecycle }) }));
          };
          case null {};
        };
        // the product is a loan product open to new accounts in the requested currency
        let ?v = ProductCore.currentVersion(bs.product, x.request.product) else return #err(#ProductError({ error = #UnknownProduct({ product = x.request.product }) }));
        if (v.terms.kind != #loan) return #err(#OriginationError({ error = #InvalidRequest({ reason = "an application is for a loan product" }) }));
        if (not v.openToNewAccounts) return #err(#ProductError({ error = #ProductClosedToNewAccounts({ product = x.request.product; version = v.version }) }));
        if (not Text.equal(v.terms.currency, x.request.currency)) return #err(#ProductError({ error = #CurrencyMismatch({ expected = v.terms.currency; actual = x.request.currency }) }));
        originationPlan(OriginationCore.planOpen(x.party, x.book, x.request, x.channel, JCore.effectiveToday(js, now)))
      };
      case (#recordApplicationData(x)) originationPlan(OriginationCore.planRecordData(bs.origination, x.application, x.facts, x.commitments));
      case (#assessAffordability(x)) originationPlan(OriginationCore.planAssess(bs.origination, x.application));
      case (#requestBureauReport(x)) originationPlan(OriginationCore.planRequestBureau(bs.origination, x.application, x.bureau, x.consentCommit, JCore.effectiveToday(js, now)));
      case (#scoreApplication(x)) originationPlan(OriginationCore.planScore(bs.origination, x.application));
      case (#underwrite(x)) originationPlan(OriginationCore.planUnderwrite(bs.origination, x.application, x.decision, x.rationale));
      case (#issueOffer(x)) originationPlan(OriginationCore.planIssueOffer(bs.origination, x.application, x.terms, JCore.effectiveToday(js, now)));
      case (#acceptOffer(x)) originationPlan(OriginationCore.planAccept(bs.origination, x.application, x.assertion, JCore.effectiveToday(js, now)));
      case (#declineOffer(x)) originationPlan(OriginationCore.planDeclineOffer(bs.origination, x.application, JCore.effectiveToday(js, now)));
      case (#recordDocument(x)) {
        switch (OriginationCore.planRecordDocument(bs.origination, x.application, x.kind, x.sha256, x.signed)) {
          case (#err(e)) #err(#OriginationError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#origination(ev); extra = documentationExtra(bs, js, now, x.application, ev); journal = [] });
        }
      };
      case (#recordConditionsMet(x)) {
        switch (OriginationCore.planConditionsMet(bs.origination, x.application, x.conditions)) {
          case (#err(e)) #err(#OriginationError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#origination(ev); extra = documentationExtra(bs, js, now, x.application, ev); journal = [] });
        }
      };
      case (#fulfilApplication(x)) {
        // The drawing: the loan account opens under the existing planner with the underwritten rate as its
        // opening rate, is activated, and the application records the account it became. Disbursement is
        // the product engine's own command from here, under its own permission.
        let f = switch (OriginationCore.planFulfil(bs.origination, x.application)) { case (#err(e)) return #err(#OriginationError({ error = e })); case (#ok(f)) f };
        let ?pe = PartyCore.get(bs.party, partyBlocks(bb), f.party) else return #err(#PartyError({ error = #UnknownParty({ party = f.party }) }));
        if (pe.lifecycle != #active) return #err(#PartyError({ error = #PartyNotActive({ party = f.party; lifecycle = pe.lifecycle }) }));
        let rate : I.Rate = { numerator = f.rateBps; denominator = 10_000; negative = false };
        // the account's id is the block the opening lands on — the height at execution, as `createCustomer`
        // numbers its accounts; the authority index is the serial's, as `openAccount` uses it
        let accountId = bs.height;
        switch (planOpenAccount(bs, js, journalCaller, f.product, f.party, pe.book, f.currency, null, [], ?rate, authorityIndex, [])) {
          case (#err(e)) #err(e);
          case (#ok(o)) {
            if (not accountTransitionAllowed(#pending, #active)) return #err(#ProductError({ error = #AccountNotActive({ account = accountId; status = #pending }) }));
            #ok({
              bankEvent = ?#product(o.opened);
              extra = [#product(#accountStatusSet({ account = accountId; to = #active })),
                       #origination(#fulfilled({ application = x.application; party = f.party; account = accountId; day = JCore.effectiveToday(js, now) }))];
              journal = [#event(o.limit)];
            })
          };
        }
      };
      case (#withdrawApplication(x)) originationPlan(OriginationCore.planWithdraw(bs.origination, x.application, x.reason, JCore.effectiveToday(js, now)));

      // ── corporate lending (corporate lending): the facility's acts ──
      case (#openFacility(terms)) planOpenFacility(bs, bb, js, terms, JCore.effectiveToday(js, now));
      case (#drawdown(m)) planDrawdown(bs, bb, js, journalCaller, now, authId, m, authorityIndex, false);
      case (#transferParticipation(x)) {
        let ?r = FacilityCore.row(bs.facility, x.facility) else return #err(#FacilityError({ error = #UnknownFacility({ facility = x.facility }) }));
        switch (requireParty(bs, x.to)) { case (?e) return #err(e); case null {} };
        let ?terms = facilityTerms(bs, r) else return #err(#ProductError({ error = #UnknownProduct({ product = r.product }) }));
        let ?due = Products.roleAccount(terms, #dueToParticipants) else return #err(#ProductError({ error = #RoleUnmapped({ product = r.product; role = "dueToParticipants" }) }));
        let have = FacilityCore.shareOf(bs.facility, x.facility, x.from);
        let funded = Posting.accountBalanceOn(js, due, participantSub(x.facility, x.from), r.currency, #credit, JCore.effectiveToday(js, now)).net;
        let moved = if (have == 0) 0 else funded * x.bps / have;
        switch (FacilityCore.planTransferParticipation(bs.facility, x.facility, x.from, x.to, x.bps, moved)) {
          case (#err(e)) #err(#FacilityError({ error = e }));
          case (#ok(ev)) {
            var journal : [JournalStep] = [];
            if (moved > 0) {
              let today = JCore.effectiveToday(js, now);
              let ?period = periodForDay(js, today) else return #err(#JournalConfigError({ error = #UnknownPeriod({ id = "day " # Nat.toText(today) }) }));
              let legs = [Posting.leg(due, ?participantSub(x.facility, x.from), #debit, r.currency, moved), Posting.leg(due, ?participantSub(x.facility, x.to), #credit, r.currency, moved)];
              switch (postLegs(js, journalCaller, now, "participation-transfer", [authId, Nat.toText(x.facility), Nat.toText(x.from), Nat.toText(x.to)], legs, today, today, period, "participation transferred by novation")) {
                case (#err(e)) return #err(e);
                case (#ok(plan)) journal := plan.journal;
              };
            };
            #ok({ bankEvent = ?#facility(ev); extra = []; journal })
          };
        }
      };
      case (#distributeToParticipants(x)) planDistribute(bs, bb, js, journalCaller, now, authId, x);
      case (#restructureFacility(x)) {
        let ?r = FacilityCore.row(bs.facility, x.facility) else return #err(#FacilityError({ error = #UnknownFacility({ facility = x.facility }) }));
        if (r.stage == #closed) return #err(#FacilityError({ error = #WrongStage({ facility = x.facility; stage = "closed"; wanted = "open or blocked" }) }));
        let rate : I.Rate = { numerator = x.terms.rateBps; denominator = 10_000; negative = false };
        let extra = List.empty<T.Event>();
        let journal = List.empty<JournalStep>();
        let drawings = List.empty<ProdT.AccountId>();
        for ((acct, open) in FacilityCore.drawingsOf(bs.facility, x.facility).vals()) {
          if (open) {
            switch (reschedulePlan(bs, bb, js, journalCaller, now, authId, acct, x.effective, x.terms.schedule, rate, true)) {
              case (#err(e)) return #err(e);
              case (#ok(plan)) {
                switch (plan.bankEvent) { case (?ev) List.add(extra, ev); case null {} };
                for (ev in plan.extra.vals()) List.add(extra, ev);
                for (st in plan.journal.vals()) List.add(journal, st);
                List.add(drawings, acct);
              };
            };
          };
        };
        if (List.size(drawings) == 0) return #err(#FacilityError({ error = #HasDrawings({ facility = x.facility; open = 0 }) }));
        #ok({ bankEvent = ?#facility(#facilityRestructured({ facility = x.facility; terms = x.terms; effective = x.effective; drawings = List.toArray(drawings) })); extra = List.toArray(extra); journal = List.toArray(journal) })
      };
      case (#recordCovenantTest(x)) {
        let ?opened = facilityTermsBlock(bb, x.facility) else return #err(#FacilityError({ error = #UnknownFacility({ facility = x.facility }) }));
        facilityPlan(FacilityCore.planCovenantTest(bs.facility, x.facility, opened.covenants, x.covenant, x.value, x.statementHash, JCore.effectiveToday(js, now)))
      };
      case (#blockDrawdowns(x)) facilityPlan(FacilityCore.planBlock(bs.facility, x.facility, x.reason, JCore.effectiveToday(js, now)));
      case (#unblockDrawdowns(x)) facilityPlan(FacilityCore.planUnblock(bs.facility, x.facility, x.reason, JCore.effectiveToday(js, now)));
      case (#recordFacilityReview(x)) {
        let ?opened = facilityTermsBlock(bb, x.facility) else return #err(#FacilityError({ error = #UnknownFacility({ facility = x.facility }) }));
        let today = JCore.effectiveToday(js, now);
        switch (FacilityCore.planReview(bs.facility, x.facility, x.note, today)) {
          case (#err(e)) #err(#FacilityError({ error = e }));
          case (#ok(#reviewRecorded(ev))) {
            let nextDue : ?Nat = switch (opened.reviewEvery) { case (?n) ?(today + n); case null null };
            #ok({ bankEvent = ?#facility(#reviewRecorded({ facility = ev.facility; day = ev.day; nextDue; note = ev.note })); extra = []; journal = [] })
          };
          case (#ok(ev)) #ok({ bankEvent = ?#facility(ev); extra = []; journal = [] });
        }
      };
      case (#recordRateFixing(x)) facilityPlan(FacilityCore.planRateFixing(x.index, x.day, x.rateBps));
      case (#receiveRental(m)) {
        let ?r = FacilityCore.row(bs.facility, m.facility) else return #err(#FacilityError({ error = #UnknownFacility({ facility = m.facility }) }));
        switch (r.kind) { case (#operatingLease(_)) {}; case (k) return #err(#FacilityError({ error = #WrongKind({ facility = m.facility; kind = FaT.kindText(k); wanted = "operatingLease" }) })) };
        if (r.stage == #closed) return #err(#FacilityError({ error = #WrongStage({ facility = m.facility; stage = "closed"; wanted = "open" }) }));
        if (m.amount == 0) return #err(#FacilityError({ error = #InvalidTerms({ reason = "a rental of nothing" }) }));
        let ?terms = facilityTerms(bs, r) else return #err(#ProductError({ error = #UnknownProduct({ product = r.product }) }));
        let ?rent = Products.roleAccount(terms, #rentReceivable) else return #err(#ProductError({ error = #RoleUnmapped({ product = r.product; role = "rentReceivable" }) }));
        let valueDate = switch (valueDateGate(bs, js, r.book, m.period, terms.valueDateConvention, m.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        switch (fundingLeg(bs, bb, js, terms, m.funding, r.currency, #debit, m.amount)) {
          case (#err(e)) #err(e);
          case (#ok(source)) {
            switch (postLegs(js, journalCaller, now, "rental", [authId, Nat.toText(m.facility)], [source, Posting.leg(rent, ?facilitySub(m.facility), #credit, r.currency, m.amount)], m.postingDate, valueDate, m.period, m.narration)) {
              case (#err(e)) #err(e);
              case (#ok(plan)) #ok({ bankEvent = ?#facility(#rentalReceived({ facility = m.facility; amount = m.amount; day = valueDate })); extra = []; journal = plan.journal });
            }
          };
        }
      };
      case (#remeasureResidual(x)) planRemeasureResidual(bs, bb, js, journalCaller, now, authId, x);
      case (#purchaseReceivables(x)) planPurchase(bs, bb, js, journalCaller, now, authId, x);
      case (#collectReceivable(x)) planCollect(bs, bb, js, journalCaller, now, authId, x);
      case (#dishonourReceivable(x)) planDishonour(bs, bb, js, journalCaller, now, authId, x);
      case (#writeOffReceivable(x)) planWriteOffReceivable(bs, bb, js, journalCaller, now, authId, x);
      case (#closeFacility(x)) facilityPlan(FacilityCore.planClose(bs.facility, x.facility, JCore.effectiveToday(js, now)));

      // ── branch and teller (branch and teller) ──
      case (#setTellerPolicy(pol)) {
        for (code in [pol.overShort, pol.cashInTransit, pol.centralBank, pol.draftsPayable, pol.clearing].vals()) {
          switch (JCore.getAccount(js, code)) { case null return #err(#ProductError({ error = #RoleAccountUnknown({ role = "teller policy"; account = code }) })); case (?_) {} };
        };
        tellerPlan(TellerCore.planPolicy(pol))
      };
      case (#openTellerSession(x)) {
        let (till, terms) = switch (openTill(bs, bb, x.till)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        if (till.status != #open) return #err(#ProductError({ error = #TillNotOpen({ till = x.till; status = till.status }) }));
        if (till.holder != x.teller) return #err(#TellerError({ error = #NotTheHolder({ till = x.till }) }));
        let today = JCore.effectiveToday(js, now);
        tellerPlan(TellerCore.planOpenSession(bs.teller, x.till, x.teller, x.opening, Till.bookBalance(js, terms.control, till.subledger, till.currency, today), today))
      };
      case (#closeTellerSession(x)) {
        let (till, terms) = switch (openTill(bs, bb, x.till)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let today = JCore.effectiveToday(js, now);
        tellerPlan(TellerCore.planCloseSession(bs.teller, x.till, x.closing, Till.bookBalance(js, terms.control, till.subledger, till.currency, today), today))
      };
      case (#resolveTillDifference(x)) {
        let ?pol = TellerCore.policy(bs.teller) else return #err(#TellerError({ error = #NoPolicy }));
        let ev = switch (TellerCore.planResolve(bs.teller, x.session, pol.overShort, x.note, x.valueDate)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(ev)) ev };
        let #differenceResolved(d) = ev else return #err(#TellerError({ error = #InvalidRequest({ reason = "not a resolution" }) }));
        let (till, terms) = switch (openTill(bs, bb, d.till)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let tillDiff : Till.Difference = switch (d.difference) { case (#balanced) #balanced; case (#over(n)) #over(n); case (#short(n)) #short(n) };
        let ?legs = Till.settlementLegs(terms.control, till.subledger, pol.overShort, till.currency, tillDiff) else return #err(#TellerError({ error = #DifferenceNotOpen({ session = x.session }) }));
        switch (postLegs(js, journalCaller, now, "till-difference", [authId, Nat.toText(x.session)], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = ?#teller(ev); extra = []; journal = plan.journal });
        }
      };
      case (#cashDeposit(x)) {
        let ev = switch (TellerCore.planCashTaken(bs.teller, x.till, x.account, x.amount, x.tendered, x.change, x.valueDate)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(ev)) ev };
        let m : T.MoneyMove = { account = x.account; amount = x.amount; postingDate = x.postingDate; valueDate = x.valueDate; period = x.period; narration = x.narration; funding = #till(x.till) };
        switch (planCommandInner(bs, bb, js, jb, journalCaller, now, #depositToAccount(m), authorityIndex)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = ?#teller(ev); extra = plan.extra; journal = plan.journal });
        }
      };
      case (#cashWithdrawal(x)) {
        let ev = switch (TellerCore.planCashPaid(bs.teller, x.till, x.account, x.amount, x.paid, x.valueDate)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(ev)) ev };
        let m : T.MoneyMove = { account = x.account; amount = x.amount; postingDate = x.postingDate; valueDate = x.valueDate; period = x.period; narration = x.narration; funding = #till(x.till) };
        switch (planCommandInner(bs, bb, js, jb, journalCaller, now, #withdrawFromAccount(m), authorityIndex)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = ?#teller(ev); extra = plan.extra; journal = plan.journal });
        }
      };
      case (#vaultToTill(x)) {
        let (till, terms) = switch (openTill(bs, bb, x.till)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        if (till.status != #open) return #err(#ProductError({ error = #TillNotOpen({ till = x.till; status = till.status }) }));
        let ev = switch (TellerCore.planVaultToTill(bs.teller, x.till, till.book, till.currency, x.amount, x.denominations, x.valueDate)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(ev)) ev };
        let legs = Till.allocationLegs(terms.control, Till.vaultSubledger(till.book, till.currency), till.subledger, till.currency, x.amount);
        switch (postLegs(js, journalCaller, now, "vault-to-till", [authId, x.till], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = ?#teller(ev); extra = [#product(#tillAllocated({ till = x.till; amount = x.amount; day = x.valueDate }))]; journal = plan.journal });
        }
      };
      case (#tillToVault(x)) {
        let (till, terms) = switch (openTill(bs, bb, x.till)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let ev = switch (TellerCore.planTillToVault(bs.teller, x.till, till.book, till.currency, x.amount, x.denominations, x.valueDate)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(ev)) ev };
        let legs = Till.returnLegs(terms.control, Till.vaultSubledger(till.book, till.currency), till.subledger, till.currency, x.amount);
        switch (postLegs(js, journalCaller, now, "till-to-vault", [authId, x.till], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = ?#teller(ev); extra = [#product(#tillReturned({ till = x.till; amount = x.amount; day = x.valueDate }))]; journal = plan.journal });
        }
      };
      case (#dispatchCash(x)) {
        let ?pol = TellerCore.policy(bs.teller) else return #err(#TellerError({ error = #NoPolicy }));
        let control = switch (tillProductControl(bs, x.product, x.currency)) { case (#err(e)) return #err(e); case (#ok(c)) c };
        switch (requireOpenBook(bs, x.fromBook)) { case (?e) return #err(e); case null {} };
        switch (requireOpenBook(bs, x.toBook)) { case (?e) return #err(e); case null {} };
        let ev = switch (TellerCore.planDispatch(bs.teller, x.product, x.fromBook, x.toBook, x.currency, x.amount, x.denominations, x.carrier, x.sealBag, x.valueDate)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(ev)) ev };
        let legs = [Posting.leg(pol.cashInTransit, ?TellerCore.transitSub(bs.height), #debit, x.currency, x.amount), Posting.leg(control, ?Till.vaultSubledger(x.fromBook, x.currency), #credit, x.currency, x.amount)];
        switch (postLegs(js, journalCaller, now, "cash-dispatch", [authId, x.fromBook, x.toBook], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = ?#teller(ev); extra = []; journal = plan.journal });
        }
      };
      case (#receiveCash(x)) {
        let ?pol = TellerCore.policy(bs.teller) else return #err(#TellerError({ error = #NoPolicy }));
        let (ev, m) = switch (TellerCore.planReceive(bs.teller, x.movement, x.denominations, x.valueDate)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(p)) p };
        let control = switch (tillProductControl(bs, m.product, m.currency)) { case (#err(e)) return #err(e); case (#ok(c)) c };
        let legs = [Posting.leg(control, ?Till.vaultSubledger(m.toBook, m.currency), #debit, m.currency, m.amount), Posting.leg(pol.cashInTransit, ?TellerCore.transitSub(x.movement), #credit, m.currency, m.amount)];
        switch (postLegs(js, journalCaller, now, "cash-receipt", [authId, Nat.toText(x.movement)], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = ?#teller(ev); extra = []; journal = plan.journal });
        }
      };
      case (#vaultToCentralBank(x)) {
        let ?pol = TellerCore.policy(bs.teller) else return #err(#TellerError({ error = #NoPolicy }));
        let control = switch (tillProductControl(bs, x.product, x.currency)) { case (#err(e)) return #err(e); case (#ok(c)) c };
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        let ev = switch (TellerCore.planVaultToCentralBank(bs.teller, x.product, x.book, x.currency, x.amount, x.denominations, x.valueDate)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(ev)) ev };
        let legs = [Posting.leg(pol.centralBank, null, #debit, x.currency, x.amount), Posting.leg(control, ?Till.vaultSubledger(x.book, x.currency), #credit, x.currency, x.amount)];
        switch (postLegs(js, journalCaller, now, "vault-to-central-bank", [authId, x.book], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = ?#teller(ev); extra = []; journal = plan.journal });
        }
      };
      case (#centralBankToVault(x)) {
        let ?pol = TellerCore.policy(bs.teller) else return #err(#TellerError({ error = #NoPolicy }));
        let control = switch (tillProductControl(bs, x.product, x.currency)) { case (#err(e)) return #err(e); case (#ok(c)) c };
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        let ev = switch (TellerCore.planCentralBankToVault(x.product, x.book, x.currency, x.amount, x.denominations, x.valueDate)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(ev)) ev };
        let legs = [Posting.leg(control, ?Till.vaultSubledger(x.book, x.currency), #debit, x.currency, x.amount), Posting.leg(pol.centralBank, null, #credit, x.currency, x.amount)];
        switch (postLegs(js, journalCaller, now, "central-bank-to-vault", [authId, x.book], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = ?#teller(ev); extra = []; journal = plan.journal });
        }
      };
      case (#issueChequebook(x)) {
        switch (depositAccount(bs, bb, x.account)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
        tellerPlan(TellerCore.planIssueChequebook(bs.teller, x.account, x.from, x.to, JCore.effectiveToday(js, now)))
      };
      case (#stopCheque(x)) {
        switch (depositAccount(bs, bb, x.account)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
        tellerPlan(TellerCore.planStop(bs.teller, x.account, x.serial, x.reason, JCore.effectiveToday(js, now)))
      };
      case (#presentCheque(x)) planPresentCheque(bs, bb, js, journalCaller, now, authId, x);
      case (#clearCheque(x)) {
        let held = switch (TellerCore.requireHeld(bs.teller, x.account, x.serial)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(r)) r };
        let ?period = periodForDay(js, x.valueDate) else return #err(#JournalConfigError({ error = #UnknownPeriod({ id = "day " # Nat.toText(x.valueDate) }) }));
        switch (JCore.preparePostPending(js, jb, journalCaller, now, held.hold, ?{ postingDate = x.postingDate; valueDate = x.valueDate; valueDateRequested = null; period })) {
          case (#err(e)) #err(#JournalError({ error = e }));
          case (#ok(#expired(e))) #err(#JournalError({ error = #PendingExpired({ index = held.hold; expiresAt = e.expiresAt; voidedBy = 0 }) }));
          case (#ok(#event(ev))) #ok({ bankEvent = ?#teller(#chequeCleared({ account = x.account; serial = x.serial; amount = held.amount; day = x.valueDate })); extra = []; journal = [#event(ev)] });
          case (#ok(#duplicate(idx))) #ok({ bankEvent = ?#teller(#chequeCleared({ account = x.account; serial = x.serial; amount = held.amount; day = x.valueDate })); extra = []; journal = [#existing(idx)] });
        }
      };
      case (#returnCheque(x)) {
        let held = switch (TellerCore.requireHeld(bs.teller, x.account, x.serial)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(r)) r };
        switch (JCore.prepareVoidPending(js, jb, journalCaller, held.hold)) {
          case (#err(e)) #err(#JournalError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#teller(#chequeReturned({ account = x.account; serial = x.serial; amount = held.amount; reason = x.reason; day = x.valueDate })); extra = []; journal = [#event(ev)] });
        }
      };
      case (#issueDraft(x)) {
        let ?pol = TellerCore.policy(bs.teller) else return #err(#TellerError({ error = #NoPolicy }));
        let ev = switch (TellerCore.planIssueDraft(bs.teller, x.serial, x.payeeCommit, x.amount, x.currency, x.source, x.valueDate)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(ev)) ev };
        let source = switch (cashSourceLeg(bs, bb, js, x.source, x.currency, #debit, x.amount, x.postingDate)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        let legs = [source, Posting.leg(pol.draftsPayable, ?TellerCore.draftSub(x.serial), #credit, x.currency, x.amount)];
        switch (postLegs(js, journalCaller, now, "draft-issue", [authId, x.serial], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = ?#teller(ev); extra = []; journal = plan.journal });
        }
      };
      case (#payDraft(x)) {
        let ?pol = TellerCore.policy(bs.teller) else return #err(#TellerError({ error = #NoPolicy }));
        let d = switch (TellerCore.requireOutstanding(bs.teller, x.serial)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(r)) r };
        let sink = switch (cashSourceLeg(bs, bb, js, x.to, d.currency, #credit, d.amount, x.postingDate)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        let legs = [Posting.leg(pol.draftsPayable, ?TellerCore.draftSub(x.serial), #debit, d.currency, d.amount), sink];
        switch (postLegs(js, journalCaller, now, "draft-pay", [authId, x.serial], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = ?#teller(#draftPaid({ serial = x.serial; amount = d.amount; to = x.to; day = x.valueDate })); extra = []; journal = plan.journal });
        }
      };
      case (#cancelDraft(x)) {
        let ?pol = TellerCore.policy(bs.teller) else return #err(#TellerError({ error = #NoPolicy }));
        let d = switch (TellerCore.requireOutstanding(bs.teller, x.serial)) { case (#err(e)) return #err(#TellerError({ error = e })); case (#ok(r)) r };
        let sink = switch (cashSourceLeg(bs, bb, js, #account(x.refundTo), d.currency, #credit, d.amount, x.postingDate)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        let legs = [Posting.leg(pol.draftsPayable, ?TellerCore.draftSub(x.serial), #debit, d.currency, d.amount), sink];
        switch (postLegs(js, journalCaller, now, "draft-cancel", [authId, x.serial], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = ?#teller(#draftCancelled({ serial = x.serial; amount = d.amount; refundTo = x.refundTo; day = x.valueDate })); extra = []; journal = plan.journal });
        }
      };

      // ── closed-month packing ──

      case (#openPacking(x)) {
        switch (bs.packing.current) { case (?c) return #err(#PackingError({ error = #PackingInProgress({ pack = c.pack }) })); case null {} };
        let ?p = JCore.getPeriod(js, x.period) else return #err(#PackingError({ error = #PeriodNotClosed({ period = x.period }) }));
        let ?hi = p.closedAtBlock else return #err(#PackingError({ error = #PeriodNotClosed({ period = x.period }) }));
        if (p.end <= bs.packing.packedThroughDay) return #err(#PackingError({ error = #PeriodAlreadyPacked({ period = x.period; packedThroughDay = bs.packing.packedThroughDay }) }));
        // the gate: the period's last day is older than every window a rule could read and than
        // the dedup window that keeps a duplicate submission refused — by one day more, so the
        // business date is always above the value-day floor the pack sets
        let today = JCore.effectiveToday(js, now);
        let requiredAge = Nat.max(MonitoringCore.longestWindow(bs.monitoring), Packing.DEDUP_WINDOW_DAYS) + 1;
        if (today < p.end + requiredAge) return #err(#PackingError({ error = #TooRecent({ period = x.period; periodEnd = p.end; today; requiredAge }) }));
        let lo = if (bs.packing.packs == 0) 0 else bs.packing.packedThroughBlock + 1;
        if (hi < lo) return #err(#PackingError({ error = #NothingToPack({ period = x.period }) }));
        // the bank's range (§18.3): from the block after the last pack's to the last bank block stamped no
        // later than the journal block that closed the period — the close is one message, its journal block
        // and its bank block carry one timestamp — and every proposal in it settled, every override reviewed
        let ?closeBlock = jb.get(hi) else return #err(#PackingError({ error = #PeriodNotClosed({ period = x.period }) }));
        let bankLo = if (bs.packing.packs == 0) 0 else bs.packing.bankPackedThroughBlock + 1;
        let bankHi = lastBankBlockStamped(bs, bb, closeBlock.timestamp);
        if (bankHi + 1 < bankLo + 1) return #err(#PackingError({ error = #NothingToPack({ period = x.period }) }));
        for ((i, _) in Map.entries(bs.openProposals)) { if (i >= bankLo and i <= bankHi) return #err(#PackingError({ error = #OpenProposalInRange({ proposal = i; bankHi }) })) };
        for ((i, _) in Map.entries(bs.openOverrides)) { if (i >= bankLo and i <= bankHi) return #err(#PackingError({ error = #OpenOverrideInRange({ override_ = i; bankHi }) })) };
        #ok({ bankEvent = ?#packing(#packOpened({ pack = bs.packing.packs + 1; period = x.period; periodEnd = p.end; lo; hi; bankLo; bankHi })); extra = []; journal = [] })
      };

      case (#rollPackToArchive(x)) {
        switch (bs.packing.roll) { case (?r) return #err(#PackingError({ error = #RollInProgress({ pack = r.pack }) })); case null {} };
        switch (bs.packing.current) { case (?c) { if (c.pack == x.pack) return #err(#PackingError({ error = #PackNotSealed({ pack = x.pack }) })) }; case null {} };
        let ?p = Map.get(bs.packing.sealed, Nat.compare, x.pack) else return #err(#PackingError({ error = #UnknownPack({ pack = x.pack }) }));
        if (Map.containsKey(bs.packing.archives, Nat.compare, x.pack)) return #err(#PackingError({ error = #PackAlreadyArchived({ pack = x.pack }) }));
        if (x.pack != bs.packing.archivedPacks + 1) return #err(#PackingError({ error = #PackNotNext({ pack = x.pack; next = bs.packing.archivedPacks + 1 }) }));
        let ?_ = ArchiveCore.child(bs.archive, x.cid) else return #err(#PackingError({ error = #UnknownArchive({ cid = x.cid }) }));
        if (Principal.isAnonymous(x.archive)) return #err(#PackingError({ error = #UnknownArchive({ cid = x.cid }) }));
        switch (JCore.oldestOpenPending(js)) { case (?i) { if (i <= p.hi) return #err(#PackingError({ error = #OpenPendingInRange({ pending = i; hi = p.hi }) })) }; case null {} };
        #ok({ bankEvent = ?#packing(#rollAuthorised({ pack = x.pack; cid = x.cid; archive = x.archive; hi = p.hi; periodEnd = p.periodEnd })); extra = []; journal = [] })
      };

      // ── shards ──

      case (#declareShardRule(x)) {
        // every settlement account named must exist here and be postable
        for (e in x.shards.vals()) {
          let ?acct = JCore.getAccount(js, e.settlement) else return #err(#ShardError({ error = #InvalidRule({ reason = "settlement account " # e.settlement # " is not in the chart" }) }));
          if (acct.status == #closed or acct.attributes.usage == #header) return #err(#ShardError({ error = #InvalidRule({ reason = "settlement account " # e.settlement # " is closed or a header" }) }));
        };
        switch (ShardCore.planDeclare(bs.shard, x.self, x.shards)) {
          case (#err(e)) #err(#ShardError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#shard(ev); extra = []; journal = [] });
        }
      };

      case (#openShardTransfer(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_ACCOUNT_MONEY)) { case (?e) return #err(e); case null {} };
        let ?_ = ShardCore.rule(bs.shard) else return #err(#ShardError({ error = #NoRule }));
        if (x.amount == 0) return #err(#ProductError({ error = #InvalidTerms({ reason = "a transfer of zero moves nothing" }) }));
        let ?fmt = PartyCore.format(bs.party) else return #err(#ShardError({ error = #NotRouted({ identifier = x.toIdentifier; reason = "no account-number format is recorded" }) }));
        let ?toShard = ShardCore.shardOf(fmt, x.toIdentifier) else return #err(#ShardError({ error = #NotRouted({ identifier = x.toIdentifier; reason = "not an identifier of this bank's format" }) }));
        if (toShard == ShardCore.selfIndex(bs.shard)) return #err(#ShardError({ error = #SameShard({ identifier = x.toIdentifier }) }));
        let ?to = ShardCore.shard(bs.shard, toShard) else return #err(#ShardError({ error = #UnknownShard({ shard = toShard }) }));
        switch (movableAccount(bs, bb, js, x.from, x.postingDate)) {
          case (#err(e)) #err(e);
          case (#ok((from_, fromTerms))) {
            if (fromTerms.kind == #loan) return #err(#ProductError({ error = #AccountNotOfKind({ account = x.from; expected = "a deposit product"; actual = "loan" }) }));
            switch (valueDateGate(bs, js, from_.book, x.period, fromTerms.valueDateConvention, x.valueDate)) {
              case (#err(e)) #err(e);
              case (#ok(valueDate)) {
                let side = ProductCore.normalSideOf(fromTerms.kind);
                let after = Limits.after(js, fromTerms.control, from_.subledger, from_.currency, side, valueDate, x.amount);
                switch (Limits.checkWithdrawal(fromTerms.limits, x.amount, after.balance, after.overdrawn)) {
                  case (?f) return #err(#LimitError({ reason = Limits.faultText(f) }));
                  case null {};
                };
                // reserved, not posted: the customer's money leaves when the other shard has said it
                // holds it, and comes back if it says it cannot
                let debit = Posting.leg(fromTerms.control, ?from_.subledger, #debit, from_.currency, x.amount);
                let credit = Posting.leg(to.settlement, null, #credit, from_.currency, x.amount);
                let input : JT.PostingInput = {
                  idempotencyKey = Posting.key("shard-out", [authId, Nat.toText(x.from), x.toIdentifier]);
                  postingDate = x.postingDate; valueDate; period = x.period; legs = [debit, credit];
                  sourceRef = { kind = "shard-transfer"; id = authId }; narration = x.narration; correctionOf = null;
                };
                switch (JCore.prepareReserve(js, journalCaller, now, input, null)) {
                  case (#err(e)) #err(#JournalError({ error = e }));
                  case (#ok(#duplicate(idx))) #err(#JournalError({ error = #IdempotencyKeyReused({ existing = idx }) }));
                  case (#ok(#event(ev))) #ok({
                    // the pending's index is the journal's next block: the plan and the execution share the message
                    bankEvent = ?#shard(#outboundOpened({ from = x.from; toIdentifier = x.toIdentifier; toShard; amount = x.amount; currency = from_.currency; valueDay = valueDate; period = x.period; narration = x.narration; pendingIndex = JCore.height(js) }));
                    extra = []; journal = [#event(ev)];
                  });
                }
              };
            }
          };
        }
      };

      // ── settlement on the journal ──

      case (#declareScheme(x)) {
        for (code in [x.reconciliation, x.feeIncome].vals()) {
          let ?acct = JCore.getAccount(js, code) else return #err(#SettlementError({ error = #InvalidScheme({ reason = "account " # code # " is not in the chart" }) }));
          if (acct.status == #closed or acct.attributes.usage == #header) return #err(#SettlementError({ error = #InvalidScheme({ reason = "account " # code # " is closed or a header" }) }));
        };
        switch (SettlementCore.planDeclareScheme(bs.settlement, x)) { case (#err(e)) #err(#SettlementError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#settlement(ev); extra = []; journal = [] }) }
      };

      case (#registerParticipant(x)) {
        let ?p = PartyCore.get(bs.party, partyBlocks(bb), x.party) else return #err(#PartyError({ error = #UnknownParty({ party = x.party }) }));
        if (p.lifecycle != #active) return #err(#SettlementError({ error = #InvalidParticipant({ reason = "the party is not active" }) }));
        for (a in x.accounts.vals()) {
          for (id in [a.position, a.settlement, a.feeReceivable].vals()) {
            switch (activeAccount(bs, bb, id)) {
              case (#err(e)) return #err(e);
              case (#ok(acct)) {
                if (acct.party != x.party) return #err(#SettlementError({ error = #InvalidParticipant({ reason = "account " # Nat.toText(id) # " is not the party's" }) }));
                if (not Text.equal(acct.currency, a.currency)) return #err(#ProductError({ error = #CurrencyMismatch({ expected = a.currency; actual = acct.currency }) }));
              };
            };
          };
        };
        switch (SettlementCore.planRegisterParticipant(bs.settlement, x.party, x.bic, x.scheme, x.accounts)) { case (#err(e)) #err(#SettlementError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#settlement(ev); extra = []; journal = [] }) }
      };

      case (#deactivateParticipant(x)) {
        switch (SettlementCore.planDeactivateParticipant(bs.settlement, x.participant)) { case (#err(e)) #err(#SettlementError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#settlement(ev); extra = []; journal = [] }) }
      };

      case (#recordFunds(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_SETTLEMENT)) { case (?e) return #err(e); case null {} };
        switch (requireFeature(bs, ProdT.FEATURE_ACCOUNT_MONEY)) { case (?e) return #err(e); case null {} };
        if (x.amount == 0) return #err(#ProductError({ error = #InvalidTerms({ reason = "funds of zero move nothing" }) }));
        let (p, accts) = switch (SettlementCore.activeAccounts(bs.settlement, x.participant, x.currency)) { case (#err(e)) return #err(#SettlementError({ error = e })); case (#ok(v)) v };
        let ?sch = SettlementCore.scheme(bs.settlement, p.scheme) else return #err(#SettlementError({ error = #UnknownScheme({ scheme = p.scheme }) }));
        let (settle, terms) = switch (movableAccount(bs, bb, js, accts.settlement, x.postingDate)) { case (#err(e)) return #err(e); case (#ok(v)) v };
        // funds in: the participant's prefunded settlement balance rises against the hub's
        // reconciliation account; funds out: the reverse, and never past what was funded
        let (kind, legs) = switch (x.direction) {
          case (#in_) ("RECORD_FUNDS_IN", [Posting.leg(sch.reconciliation, null, #debit, x.currency, x.amount), Posting.leg(terms.control, ?settle.subledger, #credit, x.currency, x.amount)]);
          case (#out) ("RECORD_FUNDS_OUT", [Posting.leg(terms.control, ?settle.subledger, #debit, x.currency, x.amount), Posting.leg(sch.reconciliation, null, #credit, x.currency, x.amount)]);
        };
        let input : JT.PostingInput = {
          idempotencyKey = Posting.key(kind, [authId, Nat.toText(x.participant)]);
          postingDate = x.postingDate; valueDate = x.valueDate; period = x.period; legs;
          sourceRef = { kind; id = authId }; narration = x.narration; correctionOf = null;
        };
        switch (JCore.preparePost(js, journalCaller, now, input)) {
          case (#err(e)) #err(#JournalError({ error = e }));
          case (#ok(#duplicate(idx))) #err(#JournalError({ error = #IdempotencyKeyReused({ existing = idx }) }));
          case (#ok(#event(ev))) #ok({ bankEvent = ?#settlement(#fundsRecorded({ participant = x.participant; currency = x.currency; amount = x.amount; direction = x.direction; posting = JCore.height(js) })); extra = []; journal = [#event(ev)] });
        }
      };

      case (#prepareTransfer(x)) {
        // the prepare is recorded first (RECEIVED_PREPARE); the reservation is the next act, in
        // the same message, by the bank (`Bank.mo` reserves right after this block lands)
        switch (requireFeature(bs, ProdT.FEATURE_SETTLEMENT)) { case (?e) return #err(e); case null {} };
        if (x.ttlSeconds == 0 or x.ttlSeconds > SeT.MAX_TRANSFER_TTL_SECONDS) return #err(#SettlementError({ error = #InvalidTransfer({ reason = "a reservation lives 1.." # Nat.toText(SeT.MAX_TRANSFER_TTL_SECONDS) # " seconds" }) }));
        let expiresAt = now + Nat64.fromNat(x.ttlSeconds) * 1_000_000_000;
        switch (SettlementCore.planPrepare(bs.settlement, x.scheme, x.payer, x.payee, x.currency, x.amount, x.reference, expiresAt, null)) {
          case (#err(e)) #err(#SettlementError({ error = e }));
          case (#ok(ev)) #ok({ bankEvent = ?#settlement(ev); extra = []; journal = [] });
        }
      };

      case (#fulfilTransfer(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_SETTLEMENT)) { case (?e) return #err(e); case null {} };
        planFulfil(bs, bb, js, jb, journalCaller, now, x.transfer)
      };
      case (#rejectTransfer(x)) planAbort(bs, js, jb, journalCaller, x.transfer, #rejected, x.reason);
      case (#errorTransfer(x)) planAbort(bs, js, jb, journalCaller, x.transfer, #error, x.reason);

      case (#openSettlementWindow(x)) {
        switch (SettlementCore.planOpenWindow(bs.settlement, x.scheme, x.businessDate)) { case (#err(e)) #err(#SettlementError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#settlement(ev); extra = []; journal = [] }) }
      };
      case (#closeSettlementWindow(x)) {
        switch (SettlementCore.planWindowTransition(bs.settlement, x.window, #closed, "closed")) { case (#err(e)) #err(#SettlementError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#settlement(ev); extra = []; journal = [] }) }
      };
      case (#openSettlement(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_SETTLEMENT)) { case (?e) return #err(e); case null {} };
        switch (SettlementCore.planOpenSettlement(bs.settlement, x.window)) { case (#err(e)) #err(#SettlementError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#settlement(ev); extra = []; journal = [] }) }
      };
      case (#abortSettlement(x)) {
        if (Text.size(x.reason) == 0) return #err(#SettlementError({ error = #InvalidScheme({ reason = "an abort carries its reason" }) }));
        switch (SettlementCore.planSettlementTransition(bs.settlement, x.settlement, #aborted, [], [], x.reason)) { case (#err(e)) #err(#SettlementError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#settlement(ev); extra = []; journal = [] }) }
      };

      case (#receiveBulk(x)) {
        switch (requireFeature(bs, ProdT.FEATURE_SETTLEMENT)) { case (?e) return #err(e); case null {} };
        if (x.ttlSeconds == 0 or x.ttlSeconds > SeT.MAX_TRANSFER_TTL_SECONDS) return #err(#SettlementError({ error = #InvalidBulk({ reason = "a reservation lives 1.." # Nat.toText(SeT.MAX_TRANSFER_TTL_SECONDS) # " seconds" }) }));
        switch (SettlementCore.planReceiveBulk(bs.settlement, x.scheme, x.payer, x.reference, x.requests.size())) {
          case (#err(e)) #err(#SettlementError({ error = e }));
          case (#ok(#bulkReceived(b))) #ok({ bankEvent = ?#settlement(#bulkReceived({ b with requests = x.requests; ttlSeconds = x.ttlSeconds })); extra = []; journal = [] });
          case (#ok(_)) Runtime.trap("BankCore: receiveBulk planned something else");
        }
      };
      case (#fulfilBulk(x)) {
        let ?r = SettlementCore.bulkRowOf(bs.settlement, x.bulk) else return #err(#SettlementError({ error = #UnknownBulk({ bulk = x.bulk }) }));
        if (r.state != #accepted) return #err(#SettlementError({ error = #BulkNotIn({ bulk = x.bulk; state = SeT.bulkStateName(r.state); expected = "ACCEPTED" }) }));
        switch (SettlementCore.planBulkTransition(bs.settlement, x.bulk, #processing, #processing, r.prepared, r.done, [])) { case (#err(e)) #err(#SettlementError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#settlement(ev); extra = []; journal = [] }) }
      };
      case (#rejectBulk(x)) {
        let ?r = SettlementCore.bulkRowOf(bs.settlement, x.bulk) else return #err(#SettlementError({ error = #UnknownBulk({ bulk = x.bulk }) }));
        let to : SeT.BulkState = switch (r.state) { case (#accepted or #pendingFulfil) #aborting; case (#processing) #aborting; case (#pendingPrepare) #rejected; case (st) return #err(#SettlementError({ error = #BulkNotIn({ bulk = x.bulk; state = SeT.bulkStateName(st); expected = "PENDING_PREPARE, ACCEPTED, PROCESSING or PENDING_FULFIL" }) })) };
        switch (SettlementCore.planBulkTransition(bs.settlement, x.bulk, to, #rejected, r.prepared, r.done, [(0, x.reason)])) { case (#err(e)) #err(#SettlementError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#settlement(ev); extra = []; journal = [] }) }
      };

      // ── ISO 20022 messaging on the journal ──
      case (#declareRail(x)) {
        switch (PaymentsCore.planDeclareRail(bs.payments, bs.settlement, x)) { case (#err(e)) #err(#PaymentsError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#payments(ev); extra = []; journal = [] }) }
      };
      case (#registerConnectorKey(x)) {
        switch (PaymentsCore.planRegisterConnectorKey(bs.payments, x)) { case (#err(e)) #err(#PaymentsError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#payments(ev); extra = []; journal = [] }) }
      };
      // a release posts and a rejection voids: the hold's block lands first and the transfer's act
      // follows in the same message (`Bank.paymentsOnEvent`), the way a prepare is reserved
      case (#releaseHold(x)) {
        switch (PaymentsCore.planReleaseHold(bs.payments, bs.settlement, x.transfer, x.reason)) { case (#err(e)) #err(#PaymentsError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#payments(ev); extra = []; journal = [] }) }
      };
      case (#rejectHold(x)) {
        switch (PaymentsCore.planRejectHold(bs.payments, x.transfer, x.reason)) { case (#err(e)) #err(#PaymentsError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#payments(ev); extra = []; journal = [] }) }
      };
      case (#grantDebitAuthority(x)) {
        switch (PaymentsCore.planGrantDebitAuthority(bs.payments, bs.settlement, x)) { case (#err(e)) #err(#PaymentsError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#payments(ev); extra = []; journal = [] }) }
      };
      case (#revokeDebitAuthority(x)) {
        switch (PaymentsCore.planRevokeDebitAuthority(bs.payments, x)) { case (#err(e)) #err(#PaymentsError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#payments(ev); extra = []; journal = [] }) }
      };
      case (#decideMandate(x)) {
        switch (PaymentsCore.planDecideMandate(bs.payments, x)) { case (#err(e)) #err(#PaymentsError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#payments(ev); extra = []; journal = [] }) }
      };
      case (#declareFspiopParticipant(x)) {
        switch (FspiopCore.planDeclareParticipant(bs.fspiop, bs.settlement, func(r : Text) : ?SeT.SchemeId { switch (PaymentsCore.rail(bs.payments, r)) { case (?rl) ?rl.scheme; case null null } }, x)) {
          case (#err(e)) #err(#FspiopError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#fspiop(ev); extra = []; journal = [] })
        }
      };

      case (#resolveBatchFailure(x)) {
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        if (Text.size(x.justification) == 0) {
          return #err(#BatchError({ error = #InvalidJustification({ reason = "a sign-off carries the reason it was given" }) }));
        };
        let ?r = BatchCore.getRun(bs.batch, x.book, x.businessDate) else {
          return #err(#BatchError({ error = #UnknownRun({ book = x.book; businessDate = x.businessDate }) }));
        };
        if (not BatchCore.hasFailure(r, x.item, x.entity)) {
          return #err(#BatchError({ error = #UnknownFailure({ book = x.book; businessDate = x.businessDate; item = x.item; entity = x.entity }) }));
        };
        #ok({
          bankEvent = ?#batch(#eodFailureResolved({
            book = x.book; businessDate = x.businessDate; item = x.item; entity = x.entity; justification = x.justification;
          }));
          extra = []; journal = [];
        })
      };

      case (#openEndOfDay(x)) {
        switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} };
        switch (BatchCore.getRun(bs.batch, x.book, x.businessDate)) {
          case (?_) return #err(#BatchError({ error = #RunExists({ book = x.book; businessDate = x.businessDate }) }));
          case null {};
        };
        // A run is for the business date the journal is on: a run for some other date
        // would be taking a book that is either not closed yet or already reopened.
        let ?today = JCore.businessDate(js) else {
          return #err(#BatchError({ error = #BusinessDateMismatch({ businessDate = x.businessDate; requested = x.businessDate }) }));
        };
        if (today != x.businessDate) {
          return #err(#BatchError({ error = #BusinessDateMismatch({ businessDate = today; requested = x.businessDate }) }));
        };
        let shardSize = if (x.shardSize == 0) Batch.DEFAULT_SHARD_SIZE else x.shardSize;
        // the plan is fixed here, from the accounts that exist now
        let maxAccount = highestAccount(bs);
        switch (Batch.plan(planInput(bs, bb, x.book, maxAccount, shardSize))) {
          case (#err(#invalidShardSize(d))) #err(#BatchError({ error = #InvalidShardSize({ shardSize = d.shardSize }) }));
          case (#err(#planTooLarge(d))) #err(#BatchError({ error = #PlanTooLarge({ items = d.items }) }));
          case (#ok(items)) {
            // The gate, checked once here rather than nine times inside the run: a run
            // may not open unless the batch's own feature and every feature its plan's
            // jobs would post under are past their activation height. So a batch cannot
            // post below a gate, and a partially activated deployment cannot half-run a
            // day — it is told which feature is missing.
            switch (requireFeature(bs, ProdT.FEATURE_END_OF_DAY)) { case (?e) return #err(e); case null {} };
            for (it in items.vals()) {
              switch (Batch.featureOf(it.job)) {
                case (?f) { switch (requireFeature(bs, f)) { case (?e) return #err(e); case null {} } };
                case null {};
              };
            };
            #ok({
              bankEvent = ?#batch(#eodOpened({
                book = x.book; businessDate = x.businessDate; shardSize;
                openedAtHeight = JCore.height(js); maxAccount;
                planHash = Batch.planHash(items); items = items.size();
                entities = Batch.entityCount(items);
              }));
              extra = []; journal = [];
            })
          };
        }
      };

      case (#closePeriodEnd(x)) {
        switch (runStep(bs, x.book, x.period, #closed)) {
          case (#err(e)) #err(e);
          case (#ok(#idempotent)) #ok({ bankEvent = null; extra = []; journal = [] });
          case (#ok(_)) {
            // the journal's own period close is the hard stop no poster can cross;
            // the book closure is the bank layer's, and both are recorded
            switch (JCore.prepareClosePeriod(js, journalCaller, x.period)) {
              case (#err(e)) #err(#JournalConfigError({ error = e }));
              case (#ok(ev)) #ok({
                bankEvent = ?#close(#periodEndClosed({ book = x.book; period = x.period }));
                extra = []; journal = [#event(ev)];
              });
            }
          };
        }
      };
      // ── trade finance (trade finance): planned in their own function so this switch stays under the chain's function-complexity bound ──
      case (#setTradePolicy(_) or #issueLetterOfCredit(_) or #adviseLetterOfCredit(_) or #amendLetterOfCredit(_) or #presentDocuments(_) or #examinePresentation(_) or #waiveDiscrepancies(_)
            or #honourPresentation(_) or #settleAcceptance(_) or #closeLetterOfCredit(_) or #issueGuarantee(_) or #amendGuarantee(_) or #recordDemand(_) or #examineDemand(_) or #payDemand(_)
            or #reduceGuarantee(_) or #releaseGuarantee(_) or #registerCollection(_) or #presentCollection(_) or #acceptCollection(_) or #payCollection(_) or #protestCollection(_)
            or #returnCollection(_) or #discountBill(_) or #rediscountBill(_) or #settleBill(_) or #dishonourBill(_) or #recordTradeMessage(_)) planTradeInner(bs, bb, js, journalCaller, now, command, authorityIndex, authId);
      case (#setIslamicPolicy(_) or #approveShariaProduct(_) or #flagShariaBook(_) or #openShariaContract(_) or #acquireMurabahaAsset(_) or #sellMurabaha(_) or #collectInstalment(_) or #grantRebate(_)
            or #commenceIjarah(_) or #collectRental(_) or #transferIjarahOwnership(_) or #contributeCapital(_) or #distributeMusharakahProfit(_) or #allocateMusharakahLoss(_) or #buyMusharakahUnit(_)
            or #recordMudarabahResult(_) or #deliverSalam(_) or #sellSalamCommodity(_) or #recordSalamFailure(_) or #recordIstisnaMilestone(_) or #collectIstisnaBilling(_) or #settleShariaContract(_)
            or #closeShariaContract(_) or #recordNonCompliance(_) or #openInvestmentPool(_) or #updatePoolReserves(_) or #distributePool(_)) planIslamicInner(bs, bb, js, journalCaller, now, command, authorityIndex, authId);
    }
  };

  // ═══════════════════════════════════════════════════════
  //  THE PRODUCT ENGINE'S HELPERS
  // ═══════════════════════════════════════════════════════
  //
  // Every figure these read is the journal's. Nothing here keeps a balance, and
  // nothing here decides what money is — they shape domain facts into postings and
  // refuse the facts the terms do not admit.

  /// A money-visible feature is refused below its activation height, which
  /// defaults to `ACTIVATION_OFF`. An administrator's flag activates nothing: the
  /// only thing that moves a gate is a recorded `#featureActivationSet` block.
  func requireFeature(bs : State, feature : T.FeatureId) : ?T.BankError {
    if (featureActive(bs, feature)) null
    else ?#FeatureInactive({ feature; activationHeight = featureActivation(bs, feature); height = Nat64.fromNat(bs.height) })
  };

  /// The account lifecycle. Everything outside this matrix is refused.
  func accountTransitionAllowed(from : ProdT.AccountStatus, to : ProdT.AccountStatus) : Bool {
    switch (from, to) {
      case (#pending, #active) true;
      case (#pending, #closed) true;
      case (#active, #dormant) true;
      case (#dormant, #active) true;
      case (#active, #closed) true;
      case (#dormant, #closed) true;
      case (_, _) false;
    }
  };

  func requireAccount(bs : State, bb : Blocks, id : ProdT.AccountId) : Result.Result<(ProductCore.AccountEntry, ProdT.ProductTerms), T.BankError> {
    let ?a = ProductCore.get(bs.product, productBlocks(bb), id) else return #err(#ProductError({ error = #UnknownAccount({ account = id }) }));
    let ?terms = ProductCore.termsOf(bs.product, a) else return #err(#ProductError({ error = #UnknownVersion({ product = a.product; version = a.version }) }));
    #ok((a, terms))
  };

  func activeAccount(bs : State, bb : Blocks, id : ProdT.AccountId) : Result.Result<ProductCore.AccountEntry, T.BankError> {
    switch (requireAccount(bs, bb, id)) {
      case (#err(e)) #err(e);
      case (#ok((a, _))) {
        if (a.status != #active) #err(#ProductError({ error = #AccountNotActive({ account = id; status = a.status }) }))
        else #ok(a)
      };
    }
  };

  /// An account money may move on today: active, and its party's KYC and screening
  /// position permits movement. The party gate is party and KYC's and is applied here rather
  /// than restated, so there is one answer to "may this customer transact".
  func movableAccount(bs : State, bb : Blocks, js : JCore.State, id : ProdT.AccountId, day : ProdT.Day) : Result.Result<(ProductCore.AccountEntry, ProdT.ProductTerms), T.BankError> {
    switch (requireAccount(bs, bb, id)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        if (a.status != #active) return #err(#ProductError({ error = #AccountNotActive({ account = id; status = a.status }) }));
        let today = switch (JCore.businessDate(js)) { case (?d) d; case null day };
        switch (PartyCore.permitsMovement(bs.party, partyBlocks(bb), a.party, today)) {
          case (?e) #err(#PartyError({ error = e }));
          case null #ok((a, terms));
        }
      };
    }
  };

  func openTill(bs : State, bb : Blocks, id : ProdT.TillId) : Result.Result<(ProductCore.TillEntry, ProdT.ProductTerms), T.BankError> {
    let ?t = ProductCore.getTill(bs.product, productBlocks(bb), id) else return #err(#ProductError({ error = #UnknownTill({ till = id }) }));
    if (t.status == #closed) return #err(#ProductError({ error = #TillNotOpen({ till = id; status = t.status }) }));
    let ?v = ProductCore.currentVersion(bs.product, t.product) else return #err(#ProductError({ error = #UnknownProduct({ product = t.product }) }));
    #ok((t, v.terms))
  };

  /// What an account owes and is owed, as one figure, read from the journal. Used
  /// to refuse closing an account that still has a position.
  func accountExposure(js : JCore.State, a : ProductCore.AccountEntry, terms : ProdT.ProductTerms) : Nat {
    let side = ProductCore.normalSideOf(terms.kind);
    var total = Posting.accountBalanceOn(js, terms.control, a.subledger, a.currency, side, DAY_MAX).net;
    let roles : [(ProdT.Role, JT.Side)] = [
      (#interestReceivable, #debit), (#feeReceivable, #debit),
      (#penaltyReceivable, #debit), (#interestPayable, #credit),
    ];
    for ((role, s2) in roles.vals()) {
      switch (Products.roleAccount(terms, role)) {
        case (?code) { total += Posting.accountBalanceOn(js, code, a.subledger, a.currency, s2, DAY_MAX).net };
        case null {};
      };
    };
    total
  };

  /// A day far enough in the future that a value-dated read includes everything
  /// already posted. The journal's days are day numbers from the epoch, so this is
  /// roughly the year 27,000 — a bound, not a date anyone will reach.
  let DAY_MAX : Nat = 9_000_000;

  /// The other side of a customer movement, as a leg. A till must be open, in the
  /// same currency, and the posting is between two sub-ledgers of the cash control
  /// account; a named general-ledger account must exist and be open.
  func fundingLeg(
    bs : State, bb : Blocks,
    js : JCore.State,
    terms : ProdT.ProductTerms,
    funding : ProdT.Funding,
    ccy : JT.Currency,
    side : JT.Side,
    amount : Nat,
  ) : Result.Result<JT.Leg, T.BankError> {
    switch (funding) {
      case (#till(id)) {
        switch (openTill(bs, bb, id)) {
          case (#err(e)) #err(e);
          case (#ok((t, tillTerms))) {
            if (t.status != #open) return #err(#ProductError({ error = #TillNotOpen({ till = id; status = t.status }) }));
            if (not Text.equal(t.currency, ccy)) {
              return #err(#ProductError({ error = #CurrencyMismatch({ expected = ccy; actual = t.currency }) }));
            };
            #ok(Posting.leg(tillTerms.control, ?t.subledger, side, ccy, amount))
          };
        }
      };
      case (#glAccount(code)) {
        let ?acct = JCore.getAccount(js, code) else return #err(#ProductError({ error = #RoleAccountUnknown({ role = "funding"; account = code }) }));
        if (acct.status == #closed) return #err(#ProductError({ error = #RoleAccountClosed({ role = "funding"; account = code }) }));
        if (acct.attributes.usage == #header) {
          return #err(#ProductError({ error = #InvalidTerms({ reason = "funding account " # code # " is a header account and cannot carry postings" }) }));
        };
        ignore terms;
        #ok(Posting.leg(code, null, side, ccy, amount))
      };
    }
  };

  /// Which account a charge debits. On a deposit product the customer's own balance
  /// falls, so the control account's sub-ledger is debited; on a credit product the
  /// charge becomes receivable, which is a different balance-sheet line and
  /// therefore a different control account.
  func chargeDebitAccount(terms : ProdT.ProductTerms, c : ProdT.Charge) : Result.Result<JT.AccountCode, T.BankError> {
    if (terms.kind != #loan) return #ok(terms.control);
    let role : ProdT.Role = switch (c.role) {
      case (#penaltyIncome) #penaltyReceivable;
      case (_) #feeReceivable;
    };
    switch (Products.roleAccount(terms, role)) {
      case (?code) #ok(code);
      case null #err(#ProductError({ error = #RoleUnmapped({ product = terms.control; role = ProdT.roleText(role) }) }));
    }
  };

  func postOne(js : JCore.State, journalCaller : Principal, now : Nat64, input : JT.PostingInput) : Result.Result<Plan, T.BankError> {
    switch (JCore.preparePost(js, journalCaller, now, input)) {
      case (#err(e)) #err(#JournalError({ error = e }));
      case (#ok(#event(e))) #ok({ bankEvent = null; extra = []; journal = [#event(e)] });
      case (#ok(#duplicate(idx))) #ok({ bankEvent = null; extra = []; journal = [#existing(idx)] });
    }
  };

  /// A posting of arbitrary legs, asserted to balance here rather than discovered
  /// at admission, so a builder fault is named by the builder.
  func postLegs(
    js : JCore.State,
    journalCaller : Principal,
    now : Nat64,
    purpose : Text,
    parts : [Text],
    legs : [JT.Leg],
    postingDate : ProdT.Day,
    valueDate : ProdT.Day,
    period : JT.PeriodId,
    narration : Text,
  ) : Result.Result<Plan, T.BankError> {
    if (not Posting.balances(legs)) {
      return #err(#ProductError({ error = #InvalidTerms({ reason = purpose # ": the generated legs do not balance" }) }));
    };
    let input : JT.PostingInput = {
      idempotencyKey = Posting.key(purpose, parts);
      postingDate; valueDate; period; legs;
      sourceRef = { kind = purpose; id = Text.join(parts.vals(), "/") };
      narration;
      correctionOf = null;
    };
    postOne(js, journalCaller, now, input)
  };

  // ─── interest: the fold ───────────────────────────────────────────────────

  /// The interest earned by every account of a product in a currency on one day,
  /// as the sum of per-account folds over the journal's value-dated balances. The
  /// aggregate is rounded once; per-account figures are rounded at capitalisation,
  /// and the residue between the two is what a run reports.
  /// `amount` is the accrual that is income; `suspended` the accounts whose accrual the collections policy
  /// holds in suspense (collections and recovery: an exposure at or past the policy's suspending stage), each rounded on its own
  /// so the exposure row carries exactly what the posting holds for it.
  public func accrualFor(bs : State, bb : Blocks, js : JCore.State, product : Text, ccy : Text, day : ProdT.Day) : Result.Result<{ amount : Nat; accounts : Nat; examined : Nat; suspended : [(ProdT.AccountId, Nat)] }, T.BankError> {
    let ?v = ProductCore.currentVersion(bs.product, product) else return #err(#ProductError({ error = #UnknownProduct({ product }) }));
    if (not Text.equal(v.terms.currency, ccy)) {
      return #err(#ProductError({ error = #CurrencyMismatch({ expected = v.terms.currency; actual = ccy }) }));
    };
    var num : Nat = 0;
    var den : Nat = 1;
    var negative = false;
    var counted = 0;
    var examined = 0;
    let suspended = List.empty<(ProdT.AccountId, Nat)>();
    let policy = CollectionsCore.policy(bs.collections);
    for (a in ProductCore.accountsOfProduct(bs.product, productBlocks(bb), product).vals()) {
      if (Text.equal(a.currency, ccy) and a.status != #closed) {
        examined += 1;
        switch (accountAccrual(bs, js, a, day, day + 1)) {
          case (#err(e)) return #err(e);
          case (#ok(x)) {
            if (x.numerator != 0) {
              counted += 1;
              let inSuspense = switch (policy, CollectionsCore.row(bs.collections, a.id)) {
                case (?pol, ?r) v.terms.kind == #loan and CollectionsCore.suspends(pol, r.stage) and not x.negative;
                case (_, _) false;
              };
              if (inSuspense) {
                let rounded = I.round(x, v.terms.rounding);
                if (rounded.amount > 0) List.add(suspended, (a.id, rounded.amount));
              } else {
                if (x.negative) negative := true;
                num := num * x.denominator + x.numerator * den;
                den := den * x.denominator;
              };
            };
          };
        };
      };
    };
    let r = I.round({ numerator = num; denominator = den; negative }, v.terms.rounding);
    #ok({ amount = r.amount; accounts = counted; examined; suspended = List.toArray(suspended) })
  };

  /// One account's accrual over `[from, to)`, on the terms of the version it was
  /// opened under — not the product's current terms, which is what makes an
  /// amendment safe.
  func accountAccrual(bs : State, js : JCore.State, a : ProductCore.AccountEntry, from : ProdT.Day, to : ProdT.Day) : Result.Result<I.Signed, T.BankError> {
    let ?terms = ProductCore.termsOf(bs.product, a) else return #err(#ProductError({ error = #UnknownVersion({ product = a.product; version = a.version }) }));
    let ?it = terms.interest else return #ok(I.zero());
    let side = ProductCore.normalSideOf(terms.kind);
    // A term product's rate was fixed at opening; a balance-banded chart is read
    // for the balance the window closes on, which is the documented resolution of
    // "which band" and is why a boundary balance is answered the same way twice.
    let rate = switch (a.openingRate) {
      case (?r) r;
      case null {
        let reference = Posting.accountBalanceOn(js, terms.control, a.subledger, a.currency, side, to).net;
        switch (Products.rateAt(it.chart, reference)) {
          case (?r) r;
          case null return #err(#TermError({ reason = "no rate band covers a balance of " # Nat.toText(reference) }));
        }
      };
    };
    let reader = Posting.creditBalanceReader(js, terms.control, a.subledger, a.currency, side, it.minimumBalance);
    let result = switch (it.basis) {
      case (#dailyBalance) I.dailyBalanceAccrual(reader, rate, it.convention, from, to);
      case (#averageDailyBalance) I.averageBalanceAccrual(reader, rate, it.convention, from, to);
    };
    switch (result) {
      case (?r) #ok(r.accrued);
      case null #err(#ProductError({ error = #ConventionNotDailyBalance({ code = DC.isoCode(it.convention) }) }));
    }
  };

  /// The two legs of an aggregated accrual. A liability product recognises an
  /// expense against an accrued payable; an asset product recognises income
  /// against an accrued receivable. Nothing else is a valid shape.
  func accrualLegs(terms : ProdT.ProductTerms, ccy : JT.Currency, amount : Nat) : Result.Result<(JT.Leg, JT.Leg), T.BankError> {
    if (terms.kind == #loan) {
      let ?receivable = Products.roleAccount(terms, #interestReceivable) else return #err(#ProductError({ error = #RoleUnmapped({ product = terms.control; role = "interestReceivable" }) }));
      let ?income = Products.roleAccount(terms, #interestIncome) else return #err(#ProductError({ error = #RoleUnmapped({ product = terms.control; role = "interestIncome" }) }));
      #ok((Posting.leg(receivable, null, #debit, ccy, amount), Posting.leg(income, null, #credit, ccy, amount)))
    } else {
      let ?expense = Products.roleAccount(terms, #interestExpense) else return #err(#ProductError({ error = #RoleUnmapped({ product = terms.control; role = "interestExpense" }) }));
      let ?payable = Products.roleAccount(terms, #interestPayable) else return #err(#ProductError({ error = #RoleUnmapped({ product = terms.control; role = "interestPayable" }) }));
      #ok((Posting.leg(expense, null, #debit, ccy, amount), Posting.leg(payable, null, #credit, ccy, amount)))
    }
  };

  // ─── capitalisation ───────────────────────────────────────────────────────

  /// Capitalisation. For a deposit product the accrued figure per account is
  /// credited to the customer's sub-ledger and the accrued-payable control is
  /// relieved; for a term product the entitlement is moved into the depositor's own
  /// sub-ledger under the payable control, so what a depositor has been credited is
  /// a balance and not a derivation. For a credit product the instalment interest
  /// that has fallen due is moved into the borrower's receivable sub-ledger, which
  /// is what a repayment is then allocated against.
  ///
  /// The contra leg is the sum of the rounded legs, so the posting balances by
  /// construction and no rounding-difference account exists. Accounts whose accrual
  /// rounds to zero are examined and not posted. The run is chunked to the
  /// journal's leg bound with the chunk index in each derived key, so the whole run
  /// is idempotent and not merely each posting of it.
  func capitalisePlan(
    bs : State, bb : Blocks,
    js : JCore.State,
    journalCaller : Principal,
    now : Nat64,
    x : { product : ProdT.ProductId; currency : JT.Currency; to : ProdT.Day; postingDate : ProdT.Day; period : JT.PeriodId; narration : Text },
    authId : Text,
  ) : Result.Result<Plan, T.BankError> {
    let ?v = ProductCore.currentVersion(bs.product, x.product) else return #err(#ProductError({ error = #UnknownProduct({ product = x.product }) }));
    if (not Text.equal(v.terms.currency, x.currency)) {
      return #err(#ProductError({ error = #CurrencyMismatch({ expected = v.terms.currency; actual = x.currency }) }));
    };
    let rows = List.empty<{ sub : JT.SubledgerKey; amount : Nat }>();
    let exacts = List.empty<I.Signed>();
    var examined = 0;
    var zeroes = 0;
    var from : ProdT.Day = x.to;
    for (a in ProductCore.accountsOfProduct(bs.product, productBlocks(bb), x.product).vals()) {
      if (Text.equal(a.currency, x.currency) and a.status != #closed) {
        if (a.lastCapitalised >= x.to) {
          return #err(#ProductError({ error = #AlreadyCapitalised({ account = a.id; upTo = a.lastCapitalised }) }));
        };
        examined += 1;
        if (a.lastCapitalised < from) from := a.lastCapitalised;
        switch (accountAccrual(bs, js, a, a.lastCapitalised, x.to)) {
          case (#err(e)) return #err(e);
          case (#ok(exact_)) {
            List.add(exacts, exact_);
            let r = I.round(exact_, v.terms.rounding);
            if (r.amount == 0) zeroes += 1;
            List.add(rows, { sub = a.subledger; amount = r.amount });
          };
        };
      };
    };
    if (examined == 0) return #err(#ProductError({ error = #NothingToAccrue({ account = 0; from; to = x.to }) }));
    // which control account the customer leg and the contra leg name
    let customerSide : JT.Side = if (v.terms.kind == #loan) #debit else #credit;
    let isTerm = v.terms.kind == #termDeposit or v.terms.kind == #recurringDeposit;
    let contraRole : ProdT.Role = if (v.terms.kind == #loan) #interestReceivable else #interestPayable;
    let ?contra = Products.roleAccount(v.terms, contraRole) else {
      return #err(#ProductError({ error = #RoleUnmapped({ product = x.product; role = ProdT.roleText(contraRole) }) }));
    };
    // A term deposit's credited interest is held under the payable control in the
    // depositor's own sub-ledger until redemption, so "what has been credited" is a
    // balance. A loan's billed interest likewise sits in the borrower's receivable
    // sub-ledger. Both are a move between two sub-ledgers of the same control
    // account; a savings account is credited to its own principal control.
    let customerControl = if (isTerm or v.terms.kind == #loan) contra else v.terms.control;
    let inputs = List.empty<JT.PostingInput>();
    let chunks = Posting.chunk<{ sub : JT.SubledgerKey; amount : Nat }>(List.toArray(rows), Posting.CAPITALISATION_CHUNK);
    var total : Nat = 0;
    var c = 0;
    while (c < chunks.size()) {
      switch (Posting.capitalisation(
        customerControl, contra, x.currency, customerSide, chunks[c],
        [x.product, x.currency, Nat.toText(x.to), Nat.toText(c)],
        x.postingDate, x.to, x.period,
        x.narration,
      )) {
        case (?built) {
          total += built.total;
          List.add(inputs, built.posting);
        };
        case null {};   // a chunk in which every figure rounded to zero posts nothing
      };
      c += 1;
    };
    if (List.size(inputs) == 0) {
      return #err(#ProductError({ error = #NothingToAccrue({ account = 0; from; to = x.to }) }));
    };
    let res = Posting.residue(List.toArray(exacts), total);
    let ev : T.Event = #product(#interestCapitalised({
      product = x.product; currency = x.currency; from; to = x.to;
      examined; posted = examined - zeroes; zero = zeroes; total;
      residueNumerator = res.numerator; residueDenominator = res.denominator; residueNegative = res.negative;
    }));
    switch (JCore.prepareBatch(js, journalCaller, now, List.toArray(inputs))) {
      case (#err(b)) #err(#JournalBatchError({ index = b.index; error = b.error }));
      case (#ok(prepared)) {
        let steps = List.empty<JournalStep>();
        for (pr in prepared.vals()) {
          switch (pr) {
            case (#event(e)) List.add(steps, #event(e));
            case (#duplicate(idx)) List.add(steps, #existing(idx));
          };
        };
        ignore authId;
        #ok({ bankEvent = ?ev; extra = []; journal = List.toArray(steps) })
      };
    }
  };

  // ─── what a credit account owes, read from the journal ────────────────────

  /// The four components of a borrower's position, each the net balance of its own
  /// control account under the account's sub-ledger. Nothing is stored: a
  /// back-dated repayment changes these figures by construction.
  func loanOutstanding(js : JCore.State, a : ProductCore.AccountEntry, terms : ProdT.ProductTerms, asOf : ProdT.Day) : ProdT.Allocation {
    func netOf(role : ProdT.Role) : Nat {
      switch (Products.roleAccount(terms, role)) {
        case (?code) Posting.accountBalanceOn(js, code, a.subledger, a.currency, #debit, asOf).net;
        case null 0;
      }
    };
    {
      penalty = netOf(#penaltyReceivable);
      fee = netOf(#feeReceivable);
      interest = netOf(#interestReceivable);
      principal = Posting.accountBalanceOn(js, terms.control, a.subledger, a.currency, #debit, asOf).net;
    }
  };

  /// What a borrower has repaid in total: the credits to its four positions. Used
  /// for the arrears fold, which is cumulative and therefore correct after a
  /// back-dated repayment.
  func loanRepaid(js : JCore.State, a : ProductCore.AccountEntry, terms : ProdT.ProductTerms, asOf : ProdT.Day) : Nat {
    var paid = JCore.valueDatedBalance(js, terms.control, ?a.subledger, a.currency, asOf).credits;
    for (role in ([#interestReceivable, #feeReceivable, #penaltyReceivable] : [ProdT.Role]).vals()) {
      switch (Products.roleAccount(terms, role)) {
        case (?code) paid += JCore.valueDatedBalance(js, code, ?a.subledger, a.currency, asOf).credits;
        case null {};
      };
    };
    paid
  };

  func creditAccount(bs : State, bb : Blocks, js : JCore.State, id : ProdT.AccountId, day : ProdT.Day) : Result.Result<(ProductCore.AccountEntry, ProdT.ProductTerms), T.BankError> {
    switch (movableAccount(bs, bb, js, id, day)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        if (terms.kind != #loan) {
          return #err(#ProductError({ error = #AccountNotOfKind({ account = id; expected = "loan"; actual = debug_show (terms.kind) }) }));
        };
        if (a.disbursed == null) return #err(#ProductError({ error = #LoanNotDisbursed({ account = id }) }));
        #ok((a, terms))
      };
    }
  };

  /// A repayment, allocated across the borrower's four positions in the order the
  /// account was opened under. Every allocated component credits its own control
  /// account, so each balance-sheet line is relieved of its own figure and nothing
  /// is netted. An amount larger than the whole position is refused with the total
  /// named rather than absorbed somewhere.
  func repayPlan(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, m : T.MoneyMove, authId : Text) : Result.Result<Plan, T.BankError> {
    switch (creditAccount(bs, bb, js, m.account, m.postingDate)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        if (a.writtenOff) return #err(#ProductError({ error = #LoanWrittenOffAlready({ account = m.account }) }));
        if (m.amount == 0) return #err(#ProductError({ error = #InvalidTerms({ reason = "a repayment of zero moves nothing" }) }));
        let valueDate = switch (valueDateGate(bs, js, a.book, m.period, terms.valueDateConvention, m.valueDate)) {
          case (#err(e)) return #err(e);
          case (#ok(d)) d;
        };
        let outstanding = loanOutstanding(js, a, terms, valueDate);
        let alloc = Loans.allocate(m.amount, outstanding, a.allocationOrder);
        if (alloc.overpayment > 0) {
          return #err(#ProductError({ error = #InvalidTerms({
            reason = "the repayment exceeds the position by " # Nat.toText(alloc.overpayment)
              # "; the whole position is " # Nat.toText(Loans.allocationTotal(outstanding));
          }) }));
        };
        let legs = List.empty<JT.Leg>();
        switch (fundingLeg(bs, bb, js, terms, m.funding, a.currency, #debit, m.amount)) {
          case (#err(e)) return #err(e);
          case (#ok(source)) List.add(legs, source);
        };
        let parts : [(ProdT.Role, Nat)] = [
          (#penaltyReceivable, alloc.applied.penalty),
          (#feeReceivable, alloc.applied.fee),
          (#interestReceivable, alloc.applied.interest),
        ];
        for ((role, amount) in parts.vals()) {
          if (amount > 0) {
            let ?code = Products.roleAccount(terms, role) else {
              return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = ProdT.roleText(role) }) }));
            };
            List.add(legs, Posting.leg(code, ?a.subledger, #credit, a.currency, amount));
          };
        };
        if (alloc.applied.principal > 0) {
          List.add(legs, Posting.leg(terms.control, ?a.subledger, #credit, a.currency, alloc.applied.principal));
        };
        switch (postLegs(js, journalCaller, now, "repayment", [authId, Nat.toText(m.account)], List.toArray(legs), m.postingDate, valueDate, m.period, m.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({
            bankEvent = ?#product(#repaymentReceived({ account = m.account; day = valueDate; amount = m.amount; applied = alloc.applied; overpayment = 0 }));
            extra = []; journal = plan.journal;
          });
        }
      };
    }
  };

  /// A loan's schedule re-derived from an effective day under new terms and a rate (`rescheduleLoan`, a facility's
  /// restructuring across its drawings, a floating drawing's reset). `modification` says whether this is a
  /// modification of the contract — a restructuring, with collections and recovery's stage move and the IFRS 9 §5.4.3 figure — or a
  /// contractual reset, which changes the rate and the schedule and nothing else (IFRS 9 B5.4.5).
  func reschedulePlan(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, authId : Text, account : ProdT.AccountId, effective : Nat, terms_ : ProdT.ScheduleTerms, rate : I.Rate, modification : Bool) : Result.Result<Plan, T.BankError> {
        let ?a = ProductCore.get(bs.product, productBlocks(bb), account) else return #err(#ProductError({ error = #UnknownAccount({ account = account }) }));
        let ?terms = ProductCore.termsOf(bs.product, a) else return #err(#ProductError({ error = #UnknownVersion({ product = a.product; version = a.version }) }));
        if (terms.kind != #loan) {
          return #err(#ProductError({ error = #AccountNotOfKind({ account = account; expected = "loan"; actual = debug_show (terms.kind) }) }));
        };
        if (a.disbursed == null) return #err(#ProductError({ error = #LoanNotDisbursed({ account = account }) }));
        if (a.writtenOff) return #err(#ProductError({ error = #LoanWrittenOffAlready({ account = account }) }));
        let ?current = ProductCore.schedule(bs.product, productBlocks(bb), a) else return #err(#ProductError({ error = #ScheduleRequired({ product = a.product }) }));
        switch (I.validRate(rate)) { case (?r) return #err(#ProductError({ error = #InvalidRateChart({ reason = r }) })); case null {} };
        if (terms_.instalments == 0 or terms_.instalments > ProdT.MAX_INSTALMENTS) {
          return #err(#ProductError({ error = #InvalidSchedule({ reason = "instalments out of range" }) }));
        };
        let out = Loans.reschedule(current.rows, { effective = effective; terms = terms_; rate = rate }, terms.rounding);
        if (out.reamortised == 0) return #err(#ProductError({ error = #InvalidSchedule({ reason = "the new terms generate no instalments" }) }));
        // the exposure's stage moves to restructuring (collections and recovery), and under the policy's rule the IFRS 9 §5.4.3
        // modification gain or loss — carrying amount against the modified flows discounted at the original
        // rate — posts against the modification-adjustment contra of the loan
        let extra = List.empty<T.Event>();
        var journal : [JournalStep] = [];
        switch (CollectionsCore.policy(bs.collections)) {
          case null {};
          case (?pol) {
            if (modification) { switch (CollectionsCore.noteRestructured(bs.collections, account, effective)) { case (?ev) List.add(extra, #collections(ev)); case null {} } };
            if (modification and pol.recogniseModificationLoss) {
              let ?it = terms.interest else return #err(#ProductError({ error = #InvalidTerms({ reason = "a loan product needs interest terms" }) }));
              let originalRate = switch (a.openingRate) {
                case (?r) r;
                case null { switch (Products.rateAt(it.chart, out.outstandingAtEffective)) { case (?r) r; case null rate } };
              };
              let carrying = Loans.allocationTotal(loanOutstanding(js, a, terms, effective));
              let arrearsNow = Loans.arrears(current.rows, loanRepaid(js, a, terms, effective), effective);
              let pastDueUnpaid = if (arrearsNow.dueToDate > arrearsNow.paid) arrearsNow.dueToDate - arrearsNow.paid else 0;
              let m = Loans.modificationGainLoss(out.rows, effective, originalRate, it.convention, carrying, terms.rounding, pastDueUnpaid);
              let amount = if (m.loss > 0) m.loss else m.gain;
              if (amount > 0) {
                let ?adjustment = Products.roleAccount(terms, #modificationAdjustment) else return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = "modificationAdjustment" }) }));
                let ?expense = Products.roleAccount(terms, #impairmentExpense) else return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = "impairmentExpense" }) }));
                let ?period = periodForDay(js, effective) else return #err(#JournalConfigError({ error = #UnknownPeriod({ id = "day " # Nat.toText(effective) }) }));
                let legs = if (m.loss > 0) [Posting.leg(expense, null, #debit, a.currency, amount), Posting.leg(adjustment, ?a.subledger, #credit, a.currency, amount)]
                           else [Posting.leg(adjustment, ?a.subledger, #debit, a.currency, amount), Posting.leg(expense, null, #credit, a.currency, amount)];
                switch (postLegs(js, journalCaller, now, "modification", [authId, Nat.toText(account), Nat.toText(effective)], legs, effective, effective, period,
                                 if (m.loss > 0) "modification loss on restructuring" else "modification gain on restructuring")) {
                  case (#err(e)) return #err(e);
                  case (#ok(plan)) journal := plan.journal;
                };
              };
            };
          };
        };
        // the contractual rate from the effective day, when it moves: the accrual reads it before the chart
        let rateNow : ?I.Rate = switch (a.openingRate) { case (?r) ?r; case null { switch (terms.interest) { case (?it) Products.rateAt(it.chart, out.outstandingAtEffective); case null null } } };
        if (rateNow != ?rate) List.add(extra, #product(#accountRateSet({ account; rate; effective })));
        #ok({
          bankEvent = ?#product(#loanRescheduled({ account = account; version = ProductCore.scheduleCount(a) + 1; effective = effective; schedule = out.rows }));
          extra = List.toArray(extra); journal;
        })
      };

  /// Provisioning. The band and the percentage against it are declared parameters;
  /// this computes the figure and posts the **movement** against the allowance, so
  /// the expense side moves with it and the allowance is never restated on its own.
  func provisionPlan(
    bs : State, bb : Blocks,
    js : JCore.State,
    journalCaller : Principal,
    now : Nat64,
    x : { account : ProdT.AccountId; asOf : ProdT.Day; postingDate : ProdT.Day; period : JT.PeriodId; narration : Text },
  ) : Result.Result<Plan, T.BankError> {
    switch (requireAccount(bs, bb, x.account)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        if (terms.kind != #loan) {
          return #err(#ProductError({ error = #AccountNotOfKind({ account = x.account; expected = "loan"; actual = debug_show (terms.kind) }) }));
        };
        let ?sch = ProductCore.schedule(bs.product, productBlocks(bb), a) else return #err(#ProductError({ error = #LoanNotDisbursed({ account = x.account }) }));
        let outstanding = loanOutstanding(js, a, terms, x.asOf);
        let exposure = Loans.allocationTotal(outstanding);
        let arr = Loans.arrears(sch.rows, loanRepaid(js, a, terms, x.asOf), x.asOf);
        let req = Loans.requiredProvision(terms, arr, exposure, terms.rounding);
        let ?allowance = Products.roleAccount(terms, #allowance) else return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = "allowance" }) }));
        let ?expense = Products.roleAccount(terms, #impairmentExpense) else return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = "impairmentExpense" }) }));
        // the allowance already carried is the journal's figure, not the recorded
        // decision, so the two can be compared rather than assumed equal
        let carried = Posting.accountBalanceOn(js, allowance, a.subledger, a.currency, #credit, x.asOf).net;
        let ev : T.Event = #product(#provisionSet({ account = x.account; band = req.band; stage = req.stage; required = req.amount; previous = carried }));
        switch (Loans.provisionMovement(carried, req.amount)) {
          case (#unchanged) #ok({ bankEvent = ?ev; extra = []; journal = [] });
          case (#increase(n)) {
            let legs = [
              Posting.leg(expense, null, #debit, a.currency, n),
              Posting.leg(allowance, ?a.subledger, #credit, a.currency, n),
            ];
            switch (postLegs(js, journalCaller, now, "provision", [Nat.toText(x.account), Nat.toText(x.asOf)], legs, x.postingDate, x.asOf, x.period, x.narration)) {
              case (#err(e)) #err(e);
              case (#ok(plan)) #ok({ bankEvent = ?ev; extra = []; journal = plan.journal });
            }
          };
          case (#release(n)) {
            let legs = [
              Posting.leg(allowance, ?a.subledger, #debit, a.currency, n),
              Posting.leg(expense, null, #credit, a.currency, n),
            ];
            switch (postLegs(js, journalCaller, now, "provision-release", [Nat.toText(x.account), Nat.toText(x.asOf)], legs, x.postingDate, x.asOf, x.period, x.narration)) {
              case (#err(e)) #err(e);
              case (#ok(plan)) #ok({ bankEvent = ?ev; extra = []; journal = plan.journal });
            }
          };
        }
      };
    }
  };

  /// Write-off. Every position is relieved of its own figure; the allowance absorbs
  /// as much of the loss as it carries and the remainder is a charge to impairment
  /// expense. That is the only treatment that leaves both the allowance and the
  /// expense at a figure an auditor can tie to the movement.
  func writeOffPlan(
    bs : State, bb : Blocks,
    js : JCore.State,
    journalCaller : Principal,
    now : Nat64,
    x : { account : ProdT.AccountId; postingDate : ProdT.Day; valueDate : ProdT.Day; period : JT.PeriodId; narration : Text },
    authId : Text,
  ) : Result.Result<Plan, T.BankError> {
    switch (requireAccount(bs, bb, x.account)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        if (terms.kind != #loan) {
          return #err(#ProductError({ error = #AccountNotOfKind({ account = x.account; expected = "loan"; actual = debug_show (terms.kind) }) }));
        };
        if (a.writtenOff) return #err(#ProductError({ error = #LoanWrittenOffAlready({ account = x.account }) }));
        if (a.disbursed == null) return #err(#ProductError({ error = #LoanNotDisbursed({ account = x.account }) }));
        let outstanding = loanOutstanding(js, a, terms, x.valueDate);
        let total = Loans.allocationTotal(outstanding);
        if (total == 0) return #err(#ProductError({ error = #AccountHasBalance({ account = x.account; balance = 0 }) }));
        let ?allowance = Products.roleAccount(terms, #allowance) else return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = "allowance" }) }));
        let ?writeOffAccount = Products.roleAccount(terms, #writeOff) else return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = "writeOff" }) }));
        let carried = Posting.accountBalanceOn(js, allowance, a.subledger, a.currency, #credit, x.valueDate).net;
        let wo = Loans.writeOff(outstanding, carried);
        let legs = List.empty<JT.Leg>();
        if (outstanding.principal > 0) List.add(legs, Posting.leg(terms.control, ?a.subledger, #credit, a.currency, outstanding.principal));
        let parts : [(ProdT.Role, Nat)] = [
          (#interestReceivable, outstanding.interest),
          (#feeReceivable, outstanding.fee),
          (#penaltyReceivable, outstanding.penalty),
        ];
        for ((role, amount) in parts.vals()) {
          if (amount > 0) {
            let ?code = Products.roleAccount(terms, role) else {
              return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = ProdT.roleText(role) }) }));
            };
            List.add(legs, Posting.leg(code, ?a.subledger, #credit, a.currency, amount));
          };
        };
        if (wo.fromAllowance > 0) List.add(legs, Posting.leg(allowance, ?a.subledger, #debit, a.currency, wo.fromAllowance));
        if (wo.toExpense > 0) List.add(legs, Posting.leg(writeOffAccount, null, #debit, a.currency, wo.toExpense));
        // interest held in suspense for this exposure (collections and recovery) was never income: it leaves against the write-off
        // expense, and the exposure's stage moves to write-off in its own block
        let extra = List.empty<T.Event>();
        switch (CollectionsCore.row(bs.collections, x.account)) {
          case (?r) {
            if (r.suspenseHeld > 0) {
              let ?suspense = Products.roleAccount(terms, #suspense) else return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = "suspense" }) }));
              List.add(legs, Posting.leg(suspense, ?a.subledger, #debit, a.currency, r.suspenseHeld));
              List.add(legs, Posting.leg(writeOffAccount, null, #credit, a.currency, r.suspenseHeld));
              List.add(extra, #collections(#suspenseReleased({ account = x.account; amount = r.suspenseHeld; day = x.valueDate })));
            };
            switch (CollectionsCore.noteWrittenOff(bs.collections, 0, x.account, total, x.valueDate)) { case (?ev) List.add(extra, #collections(ev)); case null {} };
          };
          case null {};
        };
        switch (postLegs(js, journalCaller, now, "write-off", [authId, Nat.toText(x.account)], List.toArray(legs), x.postingDate, x.valueDate, x.period, x.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) {
            // a facility's drawing written off is closed on the facility (corporate lending)
            switch (FacilityCore.facilityOfDrawing(bs.facility, x.account)) { case (?fid) List.add(extra, #facility(#drawingClosed({ facility = fid; account = x.account; day = x.valueDate }))); case null {} };
            #ok({
              bankEvent = ?#product(#loanWrittenOff({ account = x.account; components = outstanding; fromAllowance = wo.fromAllowance; toExpense = wo.toExpense; day = x.valueDate }));
              extra = List.toArray(extra); journal = plan.journal;
            })
          };
        }
      };
    }
  };

  /// Redemption of a term deposit, at or before maturity. The interest is
  /// recomputed over the period actually held at the penalised rate, and the
  /// difference against what had already been credited is recovered to penalty
  /// income. Both directions exist: a penalty that cannot produce a shortfall is a
  /// penalty that was never applied.
  func redeemPlan(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, m : T.MoneyMove, authId : Text) : Result.Result<Plan, T.BankError> {
    switch (movableAccount(bs, bb, js, m.account, m.postingDate)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        if (terms.kind != #termDeposit and terms.kind != #recurringDeposit) {
          return #err(#ProductError({ error = #AccountNotOfKind({ account = m.account; expected = "a term product"; actual = debug_show (terms.kind) }) }));
        };
        let ?maturity = a.maturity else return #err(#ProductError({ error = #NoMaturity({ account = m.account }) }));
        let ?it = terms.interest else return #err(#ProductError({ error = #InvalidTerms({ reason = "a term product needs interest terms" }) }));
        let ?rate = a.openingRate else return #err(#ProductError({ error = #InvalidTerms({ reason = "the account carries no opening rate" }) }));
        let ?payable = Products.roleAccount(terms, #interestPayable) else return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = "interestPayable" }) }));
        let ?penaltyIncome = Products.roleAccount(terms, #penaltyIncome) else return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = "penaltyIncome" }) }));
        let ?expense = Products.roleAccount(terms, #interestExpense) else return #err(#ProductError({ error = #RoleUnmapped({ product = a.product; role = "interestExpense" }) }));
        let early = m.valueDate < maturity;
        let penalty : I.Rate = if (early) {
          switch (terms.earlyRedemptionPenalty) {
            case (?r) r;
            case null return #err(#TermError({ reason = "this product declares no early redemption penalty, so it cannot be redeemed before maturity" }));
          }
        } else { { numerator = 0; denominator = 1; negative = false } };
        let principal = Posting.accountBalanceOn(js, terms.control, a.subledger, a.currency, #credit, m.valueDate).net;
        if (principal == 0) return #err(#ProductError({ error = #AccountHasBalance({ account = m.account; balance = 0 }) }));
        let credited = Posting.accountBalanceOn(js, payable, a.subledger, a.currency, #credit, m.valueDate).net;
        let r = TermProducts.earlyRedemption(principal, rate, penalty, it, terms.rounding, a.opened, m.valueDate, credited);
        let payout = principal + r.entitled;
        if (m.amount != payout) {
          return #err(#TermError({ reason = "the redemption pays " # Nat.toText(payout) # "; the command asked for " # Nat.toText(m.amount) }));
        };
        let legs = List.empty<JT.Leg>();
        List.add(legs, Posting.leg(terms.control, ?a.subledger, #debit, a.currency, principal));
        if (credited > 0) List.add(legs, Posting.leg(payable, ?a.subledger, #debit, a.currency, credited));
        if (r.entitled > credited) List.add(legs, Posting.leg(expense, null, #debit, a.currency, r.entitled - credited));
        switch (fundingLeg(bs, bb, js, terms, m.funding, a.currency, #credit, payout)) {
          case (#err(e)) return #err(e);
          case (#ok(sink)) List.add(legs, sink);
        };
        if (r.recoverable > 0) List.add(legs, Posting.leg(penaltyIncome, null, #credit, a.currency, r.recoverable));
        switch (postLegs(js, journalCaller, now, "redemption", [authId, Nat.toText(m.account)], List.toArray(legs), m.postingDate, m.valueDate, m.period, m.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({
            bankEvent = ?#product(#termDepositRedeemed({ account = m.account; day = m.valueDate; entitled = r.entitled; recoverable = r.recoverable; payable = r.payable; early }));
            extra = []; journal = plan.journal;
          });
        }
      };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  PRODUCT READS
  // ═══════════════════════════════════════════════════════
  //
  // Every one of these recomputes from the journal and the terms. None of them
  // reads a stored figure, which is why a back-dated posting needs no recalculation
  // job for any of them to be right.

  public func accountBalanceView(bs : State, bb : Blocks, js : JCore.State, id : ProdT.AccountId, asOf : ProdT.Day) : Result.Result<ProdT.BalanceView, T.BankError> {
    switch (requireAccount(bs, bb, id)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        let side = ProductCore.normalSideOf(terms.kind);
        let b = Posting.accountBalanceOn(js, terms.control, a.subledger, a.currency, side, asOf);
        let h = Limits.headroom(js, terms.control, a.subledger, a.currency, side);
        #ok({
          account = id; identifier = a.identifier; currency = a.currency; asOf;
          net = b.net; overdrawn = b.overdrawn;
          postedNet = h.net; postedOverdrawn = h.overdrawn;
          facility = h.facility; available = h.available;
        })
      };
    }
  };

  /// One account's accrual over a window, exact and rounded. The window defaults to
  /// "since it was last capitalised", which is the figure a statement quotes.
  /// What one account accrued over an arbitrary window, as the fold evaluates it — not
  /// the difference of two rounded figures, which is not the same number.
  ///
  /// This is the quantity a percent-of-interest charge is a percentage of, so a customer
  /// disputing such a charge can be answered with the figure it was computed from rather
  /// than with an assurance.
  public func accruedBetween(bs : State, bb : Blocks, js : JCore.State, id : ProdT.AccountId, from : ProdT.Day, to : ProdT.Day) : Result.Result<ProdT.AccrualView, T.BankError> {
    switch (requireAccount(bs, bb, id)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        if (to <= from) {
          return #ok({ account = id; from; to; numerator = 0; denominator = 1; negative = false; amount = 0 });
        };
        switch (accountAccrual(bs, js, a, from, to)) {
          case (#err(e)) #err(e);
          case (#ok(x)) {
            let r = I.round(x, terms.rounding);
            #ok({ account = id; from; to; numerator = x.numerator; denominator = x.denominator; negative = x.negative; amount = r.amount })
          };
        }
      };
    }
  };

  public func accruedInterest(bs : State, bb : Blocks, js : JCore.State, id : ProdT.AccountId, to : ProdT.Day) : Result.Result<ProdT.AccrualView, T.BankError> {
    switch (requireAccount(bs, bb, id)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        if (to <= a.lastCapitalised) {
          return #ok({ account = id; from = a.lastCapitalised; to; numerator = 0; denominator = 1; negative = false; amount = 0 });
        };
        switch (accountAccrual(bs, js, a, a.lastCapitalised, to)) {
          case (#err(e)) #err(e);
          case (#ok(x)) {
            let r = I.round(x, terms.rounding);
            #ok({
              account = id; from = a.lastCapitalised; to;
              numerator = x.numerator; denominator = x.denominator; negative = x.negative;
              amount = r.amount;
            })
          };
        }
      };
    }
  };

  /// A borrower's whole position: what is outstanding per component, what has been
  /// repaid, the arrears fold over the schedule, the band the age falls in, the
  /// provision the declared parameters require, and the allowance actually carried.
  public func loanPosition(bs : State, bb : Blocks, js : JCore.State, id : ProdT.AccountId, asOf : ProdT.Day) : Result.Result<ProdT.LoanPositionView, T.BankError> {
    switch (requireAccount(bs, bb, id)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        if (terms.kind != #loan) {
          return #err(#ProductError({ error = #AccountNotOfKind({ account = id; expected = "loan"; actual = debug_show (terms.kind) }) }));
        };
        let ?sch = ProductCore.schedule(bs.product, productBlocks(bb), a) else return #err(#ProductError({ error = #LoanNotDisbursed({ account = id }) }));
        let outstanding = loanOutstanding(js, a, terms, asOf);
        let exposure = Loans.allocationTotal(outstanding);
        let repaid = loanRepaid(js, a, terms, asOf);
        let arr = Loans.arrears(sch.rows, repaid, asOf);
        let req = Loans.requiredProvision(terms, arr, exposure, terms.rounding);
        let carried = switch (Products.roleAccount(terms, #allowance)) {
          case (?code) Posting.accountBalanceOn(js, code, a.subledger, a.currency, #credit, asOf).net;
          case null 0;
        };
        #ok({
          account = id; asOf; outstanding; exposure; repaid;
          dueToDate = arr.dueToDate; overdueTotal = arr.overdueTotal;
          overdueDays = arr.overdueDays; instalmentsOverdue = arr.instalmentsOverdue;
          band = req.band; stage = req.stage; requiredProvision = req.amount;
          carriedAllowance = carried; writtenOff = a.writtenOff;
        })
      };
    }
  };

  public func tillPosition(bs : State, bb : Blocks, js : JCore.State, id : ProdT.TillId, asOf : ProdT.Day) : Result.Result<ProdT.TillPositionView, T.BankError> {
    switch (openTill(bs, bb, id)) {
      case (#err(e)) {
        // a closed till still has a readable position
        let ?t = ProductCore.getTill(bs.product, productBlocks(bb), id) else return #err(e);
        let ?v = ProductCore.currentVersion(bs.product, t.product) else return #err(e);
        #ok(tillPositionOf(js, t, v.terms, asOf))
      };
      case (#ok((t, terms))) #ok(tillPositionOf(js, t, terms, asOf));
    }
  };

  func tillPositionOf(js : JCore.State, t : ProductCore.TillEntry, terms : ProdT.ProductTerms, asOf : ProdT.Day) : ProdT.TillPositionView {
    {
      till = t.id; currency = t.currency; asOf;
      book = Till.bookBalance(js, terms.control, t.subledger, t.currency, asOf);
      allocated = t.allocated; returned = t.returned; settlements = t.settlements;
      lastDifference = t.lastDifference;
    }
  };

  /// The due days of one of a product's charges over a window, so a charge calendar
  /// can be compared against a reference system's rather than inspected by hand.
  public func chargeDueDays(bs : State, bb : Blocks, js : JCore.State, id : ProdT.AccountId, charge : Text, from : ProdT.Day, to : ProdT.Day) : Result.Result<[ProdT.Day], T.BankError> {
    switch (requireAccount(bs, bb, id)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        let ?c = Charges.find(terms, charge) else return #err(#ProductError({ error = #UnknownCharge({ charge }) }));
        let closed : ?ProdT.Day = switch (a.status) { case (#closed) a.maturity; case (_) null };
        let rows : [ProdT.Instalment] = switch (ProductCore.schedule(bs.product, productBlocks(bb), a)) { case (?sv) sv.rows; case null [] };
        func overdueOn(d : ProdT.Day) : Nat {
          if (rows.size() == 0) 0
          else Loans.arrears(rows, loanRepaid(js, a, terms, d), d).overdueDays
        };
        #ok(Charges.dueDays(c.timing, from, to, a.opened, closed, overdueOn))
      };
    }
  };

  /// A term deposit quote: the rate the term resolves to and what the deposit would
  /// mature at. Computed from the product's current version, because a quote is for
  /// an account that does not exist yet.
  public func depositQuote(bs : State, js : JCore.State, product : ProdT.ProductId, principal : Nat, termDays : Nat, from_ : ?ProdT.Day) : Result.Result<ProdT.DepositQuoteView, T.BankError> {
    let ?v = ProductCore.currentVersion(bs.product, product) else return #err(#ProductError({ error = #UnknownProduct({ product }) }));
    if (v.terms.kind != #termDeposit and v.terms.kind != #recurringDeposit) {
      return #err(#ProductError({ error = #InvalidTerms({ reason = "only a term product is quoted" }) }));
    };
    if (principal == 0 or termDays == 0) {
      return #err(#ProductError({ error = #InvalidTerms({ reason = "a quote needs a principal and a term" }) }));
    };
    let ?it = v.terms.interest else return #err(#ProductError({ error = #InvalidTerms({ reason = "a term product needs interest terms" }) }));
    let rate = switch (it.chart.by) {
      case (#termDays) {
        switch (TermProducts.rateForTerm(it.chart, termDays)) {
          case (#ok(r)) r;
          case (#err(_)) return #err(#TermError({ reason = "no rate band covers a term of " # Nat.toText(termDays) # " days" }));
        }
      };
      case (#balance) {
        switch (Products.rateAt(it.chart, principal)) {
          case (?r) r;
          case null return #err(#TermError({ reason = "no rate band covers a balance of " # Nat.toText(principal) }));
        }
      };
    };
    // A day-count convention is a function of the actual dates and not of a term
    // alone, so the quote is taken from a named day: the one asked for, or the
    // business date when none is given.
    let from = switch (from_) {
      case (?d) d;
      case null { switch (JCore.businessDate(js)) { case (?d) d; case null 0 } };
    };
    let m = TermProducts.maturityValue(principal, rate, it, v.terms.rounding, from, from + termDays);
    #ok({
      product; version = v.version; principal; termDays;
      from; maturity = from + termDays;
      rateNumerator = rate.numerator; rateDenominator = rate.denominator;
      interest = m.interest; maturityValue = m.value; compoundings = m.compoundings;
      exactNumerator = m.exact_.numerator; exactDenominator = m.exact_.denominator;
    })
  };

  // ═══════════════════════════════════════════════════════
  //  CLOSE READS
  // ═══════════════════════════════════════════════════════

  /// How a value date resolves under a product's own convention, and whether the
  /// deployment leaves this layer as the only thing that can move it. Exposed because
  /// "which day will this land on" is a question a branch asks before it acts.
  public func resolveValueDate(bs : State, js : JCore.State, product : ProdT.ProductId, requested : ProdT.Day) : Result.Result<CT.ResolvedDateView, T.BankError> {
    let ?v = ProductCore.currentVersion(bs.product, product) else return #err(#ProductError({ error = #UnknownProduct({ product }) }));
    let sole = Conv.requiresRejectPolicy(JCore.calendar(js)) == null;
    switch (Conv.resolve(JCore.calendar(js), v.terms.valueDateConvention, requested)) {
      case (#ok(r)) #ok({
        requested = r.requested; effective = r.effective; moved = r.moved;
        convention = Conv.conventionText(r.convention); soleShiftingLayer = sole;
      });
      case (#err(#notABusinessDay(d))) #err(#CloseError({ error = #ValueDateNotResolved({
        requested = d.day; convention = Conv.conventionText(v.terms.valueDateConvention);
        reason = "the convention is sameDay and the date is not a business day";
      }) }));
      case (#err(#noEarlierBusinessDay(d))) #err(#CloseError({ error = #ValueDateNotResolved({
        requested = d.requested; convention = Conv.conventionText(v.terms.valueDateConvention);
        reason = "no earlier business day exists";
      }) }));
    }
  };

  /// A currency's position as the close sees it: the foreign balance, what it was
  /// booked at, the rate recorded for the day asked about, and what the revaluation
  /// would be. With no rate for that day the revaluation fields are null — which is
  /// the refusal, surfaced as a read rather than as a surprise during the close.
  public func positionView(bs : State, js : JCore.State, currency : JT.Currency, asOf : ProdT.Day) : Result.Result<CT.PositionView, T.BankError> {
    let ?functional = CloseCore.functional(bs.close) else return #err(#CloseError({ error = #NoFunctionalCurrency }));
    let ?pair = CloseCore.getPair(bs.close, currency) else return #err(#CloseError({ error = #UnknownPair({ currency }) }));
    let pos = JCore.balance(js, pair.position, null, pair.currency);
    let eq = JCore.balance(js, pair.equivalent, null, functional);
    let position = if (pos.debitsPosted >= pos.creditsPosted) pos.debitsPosted - pos.creditsPosted else pos.creditsPosted - pos.debitsPosted;
    let positionSide : JT.Side = if (pos.debitsPosted >= pos.creditsPosted) #debit else #credit;
    let equivalent = if (eq.debitsPosted >= eq.creditsPosted) eq.debitsPosted - eq.creditsPosted else eq.creditsPosted - eq.debitsPosted;
    switch (CloseCore.rateOn(bs.close, currency, asOf)) {
      case null #ok({
        currency; pair; position; positionSide; equivalent;
        rateNumerator = null; rateDenominator = null; rateAsOf = null;
        revalued = null; movement = null; direction = "no rate recorded";
      });
      case (?rate) {
        switch (Fx.revalue(pair, position, positionSide, equivalent, rate, #halfEven)) {
          case (#err(_)) #ok({
            currency; pair; position; positionSide; equivalent;
            rateNumerator = ?rate.numerator; rateDenominator = ?rate.denominator; rateAsOf = ?rate.asOf;
            revalued = null; movement = null; direction = "not monetary";
          });
          case (#ok(rev)) #ok({
            currency; pair; position; positionSide; equivalent;
            rateNumerator = ?rate.numerator; rateDenominator = ?rate.denominator; rateAsOf = ?rate.asOf;
            revalued = ?rev.revalued; movement = ?rev.movement;
            direction = Fx.directionText(rev.direction);
          });
        }
      };
    }
  };

  /// What a back-value correction would be, without posting it. Both figures are
  /// returned: the fold recomputed now and what was booked, because their difference
  /// is only checkable if each side is.
  public func accrualAdjustmentPreview(bs : State, bb : Blocks, js : JCore.State, product : ProdT.ProductId, currency : JT.Currency, from : ProdT.Day, to : ProdT.Day) : Result.Result<{ recomputed : Nat; booked : Nat; movement : Nat; direction : Text; examined : Nat }, T.BankError> {
    let ?v = ProductCore.currentVersion(bs.product, product) else return #err(#ProductError({ error = #UnknownProduct({ product }) }));
    var num : Nat = 0;
    var den : Nat = 1;
    var negative = false;
    var examined = 0;
    for (a in ProductCore.accountsOfProduct(bs.product, productBlocks(bb), product).vals()) {
      if (Text.equal(a.currency, currency)) {
        examined += 1;
        switch (accountAccrual(bs, js, a, from, to)) {
          case (#err(e)) return #err(e);
          case (#ok(x)) {
            if (x.numerator != 0) {
              if (x.negative) negative := true;
              num := num * x.denominator + x.numerator * den;
              den := den * x.denominator;
            };
          };
        };
      };
    };
    let recomputed = (I.round({ numerator = num; denominator = den; negative }, v.terms.rounding)).amount;
    let booked = ProductCore.accrualTotalBetween(bs.product, product, currency, from, to);
    let adj = BackValue.compute(product, currency, from, to, recomputed, booked, examined);
    #ok({
      recomputed = adj.recomputed; booked = adj.booked; movement = adj.movement;
      direction = BackValue.directionText(adj.direction); examined = adj.examined;
    })
  };

  /// The control-account check the close runs, exposed so it can be read before the
  /// close rather than discovered by it.
  public func controlCheck(bs : State, js : JCore.State, jb : JCore.Blocks) : { accounts : Nat; divergence : ?PE.ControlCheck } {
    { accounts = controlCount(bs); divergence = controlDivergence(bs, js, jb) }
  };

  /// How a back-dated value date would be classified for a book today.
  public func backValueVerdict(bs : State, js : JCore.State, book : Text, valueDate : ProdT.Day) : { verdict : Text; businessDaysBack : Nat; freeDays : Nat; approvedDays : Nat; approved : Bool } {
    let w = CloseCore.window(bs.close, book);
    let today = switch (JCore.businessDate(js)) { case (?d) d; case null valueDate };
    let back = Conv.businessDaysApart(JCore.calendar(js), valueDate, today);
    let approved = CloseCore.approvalFor(bs.close, book, valueDate) != null;
    let verdict = switch (PE.classifyBackValue(w, back)) {
      case (#inWindow(_)) "inWindow";
      case (#needsApproval(_)) if (approved) "approved" else "needsApproval";
      case (#beyondWindow(_)) "beyondWindow";
    };
    { verdict; businessDaysBack = back; freeDays = w.freeDays; approvedDays = w.approvedDays; approved }
  };

  public func closeStatus(bs : State) : { functional : ?JT.Currency; pairs : Nat; rates : Nat; runs : Nat; schedules : Nat; approvals : Nat; closedBooks : Nat; yearsRolled : Nat } {
    {
      functional = CloseCore.functional(bs.close);
      pairs = CloseCore.pairCount(bs.close);
      rates = CloseCore.rateCount(bs.close);
      runs = CloseCore.runCount(bs.close);
      schedules = CloseCore.scheduleCount(bs.close);
      approvals = CloseCore.approvalCount(bs.close);
      closedBooks = CloseCore.closedBookCount(bs.close);
      yearsRolled = CloseCore.rolledCount(bs.close);
    }
  };

  public func productStatus(bs : State) : { products : Nat; versions : Nat; accounts : Nat; tills : Nat } {
    {
      products = ProductCore.productCount(bs.product);
      versions = ProductCore.versionCount(bs.product);
      accounts = ProductCore.accountCount(bs.product);
      tills = ProductCore.tillCount(bs.product);
    }
  };

  // ═══════════════════════════════════════════════════════
  //  THE CLOSE LAYER'S HELPERS
  // ═══════════════════════════════════════════════════════

  /// The value-date gate every money-moving product command passes through, and the
  /// only place a value date is moved.
  ///
  /// Three things happen here and nowhere else:
  ///
  ///   1. the requested date is resolved under the **product's** convention and the
  ///      bank calendar, so the journal — whose policy is `#reject` — never shifts it;
  ///   2. a value date in the past is classified against the book's back-value window:
  ///      inside the free window it is admitted, in the approval band it needs a
  ///      recorded approval for that day, and beyond the band nothing admits it;
  ///   3. a book closed for the posting's period refuses it.
  ///
  /// The effective date is returned, and it is the date the posting carries.
  func valueDateGate(
    bs : State,
    js : JCore.State,
    book : Text,
    period : JT.PeriodId,
    convention : Conv.Convention,
    requested : ProdT.Day,
  ) : Result.Result<ProdT.Day, T.BankError> {
    if (CloseCore.bookClosed(bs.close, book, period)) {
      return #err(#CloseError({ error = #BookClosedForPeriod({ book; period }) }));
    };
    // The book for a date is closed to new history while an end-of-day run for that
    // date is open. That is what "close of business" has always meant, and it is what
    // keeps a run's output from depending on the order postings happened to arrive in.
    switch (BatchCore.openRunCovering(bs.batch, book, requested)) {
      case (?run) {
        return #err(#BatchError({ error = #RunOpenForDate({
          book = run.book; businessDate = run.businessDate; valueDate = requested;
        }) }));
      };
      case null {};
    };
    let effective = switch (Conv.resolve(JCore.calendar(js), convention, requested)) {
      case (#ok(r)) r.effective;
      case (#err(#notABusinessDay(d))) {
        return #err(#CloseError({ error = #ValueDateNotResolved({
          requested = d.day; convention = Conv.conventionText(convention);
          reason = "the convention is sameDay and the date is not a business day";
        }) }));
      };
      case (#err(#noEarlierBusinessDay(d))) {
        return #err(#CloseError({ error = #ValueDateNotResolved({
          requested = d.requested; convention = Conv.conventionText(convention);
          reason = "no earlier business day exists";
        }) }));
      };
    };
    let ?today = JCore.businessDate(js) else return #ok(effective);
    if (effective >= today) return #ok(effective);
    let w = CloseCore.window(bs.close, book);
    let back = Conv.businessDaysApart(JCore.calendar(js), effective, today);
    switch (PE.classifyBackValue(w, back)) {
      case (#inWindow(_)) #ok(effective);
      case (#needsApproval(d)) {
        switch (CloseCore.approvalFor(bs.close, book, effective)) {
          case (?_) #ok(effective);
          case null #err(#CloseError({ error = #BackValueNeedsApproval({
            book; valueDate = effective; businessDaysBack = d.businessDaysBack; freeDays = d.freeDays;
          }) }));
        }
      };
      case (#beyondWindow(d)) #err(#CloseError({ error = #BackValueBeyondWindow({
        businessDaysBack = d.businessDaysBack; freeDays = w.freeDays; approvedDays = w.approvedDays;
      }) }));
    }
  };

  /// An account that must exist, be open, and be able to carry a posting.
  func requirePostableAccount(js : JCore.State, code : JT.AccountCode) : ?T.BankError {
    let ?a = JCore.getAccount(js, code) else return ?#ProductError({ error = #RoleAccountUnknown({ role = "account"; account = code }) });
    if (a.status == #closed) return ?#ProductError({ error = #RoleAccountClosed({ role = "account"; account = code }) });
    if (a.attributes.usage == #header) {
      return ?#ProductError({ error = #InvalidTerms({ reason = "account " # code # " is a header account and cannot carry postings" }) });
    };
    null
  };

  /// A position pair's four accounts, each checked for the category its role needs.
  /// The position holds the foreign currency and the equivalent holds the functional
  /// one, so both are assets or liabilities depending on which way the bank is, and
  /// the two result accounts are an income and an expense in the accounting sense.
  func requirePairAccounts(js : JCore.State, pair : Fx.PositionPair) : ?T.BankError {
    for (code in [pair.position, pair.equivalent, pair.unrealised, pair.realised].vals()) {
      switch (requirePostableAccount(js, code)) { case (?e) return ?e; case null {} };
    };
    if (Text.equal(pair.position, pair.equivalent)) {
      return ?#CloseError({ error = #InvalidPair({ reason = "the position and its equivalent must be different accounts" }) });
    };
    if (Text.equal(pair.unrealised, pair.realised)) {
      return ?#CloseError({ error = #InvalidPair({ reason = "unrealised and realised results must be different accounts" }) });
    };
    null
  };

  /// A step of the close: the run must exist and the transition must be in order.
  /// `#idempotent` means the step has already been taken and the caller records and
  /// posts nothing.
  type RunStep = { #go : CloseCore.RunEntry; #idempotent };

  func runStep(bs : State, book : Text, period : Text, to : PE.State) : Result.Result<RunStep, T.BankError> {
    let ?run = CloseCore.getRun(bs.close, book, period) else {
      return #err(#CloseError({ error = #UnknownRun({ book; period }) }));
    };
    switch (PE.transition(run.state, to)) {
      case (#allowed) #ok(#go(run));
      case (#idempotent) #ok(#idempotent);
      case (#outOfOrder(d)) #err(#CloseError({ error = #OutOfOrder({
        from = PE.stateText(d.from); to = PE.stateText(d.to); requires = PE.stateText(d.requires);
      }) }));
    }
  };

  /// Is there a business day inside `[from, to]` for which some product has no
  /// accrual posted? Returns the reason a close must wait, naming the day and the
  /// product, so the refusal is actionable.
  func accrualGaps(bs : State, bb : Blocks, js : JCore.State, from : ProdT.Day, to : ProdT.Day) : ?Text {
    let days = Conv.businessDaysBetween(JCore.calendar(js), from, to);
    if (days.size() == 0) return ?"the period contains no business day";
    for (v in ProductCore.listVersions(bs.product).vals()) {
      // Only products that accrue are expected to have posted an accrual — and only
      // products that have an account to accrue on. A product registered but not yet
      // sold has nothing to accrue, and demanding an accrual for it would make the close
      // wait for a posting no one can make: the end-of-day plan does not shard a product
      // with no accounts, and `#postAccrual` over an empty product posts nothing either.
      switch (v.terms.interest) {
        case null {};
        case (?_) {
          if (v.terms.kind != #till and ProductCore.accountsOfProduct(bs.product, productBlocks(bb), v.id).size() > 0) {
            for (d in days.vals()) {
              if (ProductCore.accrualOn(bs.product, v.id, v.terms.currency, d) == null) {
                return ?("product " # v.id # " has no accrual posted for business day " # Nat.toText(d));
              };
            };
          };
        };
      };
    };
    null
  };

  /// Every control account the bank knows of: the product control accounts, the
  /// roles they map, and the FX pairs' four accounts. The close checks each one.
  func controlAccounts(bs : State) : [JT.AccountCode] {
    let out = List.empty<JT.AccountCode>();
    func add(code : JT.AccountCode) {
      for (c in List.values(out)) { if (Text.equal(c, code)) return };
      List.add(out, code);
    };
    for (v in ProductCore.listVersions(bs.product).vals()) {
      add(v.terms.control);
      for (m in v.terms.roles.vals()) { add(m.account) };
    };
    for (pair in CloseCore.listPairs(bs.close).vals()) {
      add(pair.position); add(pair.equivalent); add(pair.unrealised); add(pair.realised);
    };
    List.toArray(out)
  };

  public func controlCount(bs : State) : Nat { controlAccounts(bs).size() };

  /// The first control account whose **maintained balance** differs from the sum of
  /// its postings' legs. These are two different folds over the same log — the
  /// balance map is accumulated by `apply`, the legs are read back out of the posting
  /// records — so an equality between them is a self-consistency proof, and it fails
  /// before the period closes rather than in a break report afterwards.
  func controlDivergence(bs : State, js : JCore.State, jb : JCore.Blocks) : ?PE.ControlCheck {
    let accounts = controlAccounts(bs);
    if (accounts.size() == 0) return null;
    // fold every posting's legs once, into (account, currency) -> (debits, credits)
    let folded = Map.empty<(Text, Text), { var dr : Nat; var cr : Nat }>();
    let height = JCore.height(js);
    var i = 0;
    while (i < height) {
      switch (JCore.postingView(js, jb, i)) {
        case (?v) {
          // a voided posting never counted, and a pending one is not posted yet
          let counts = switch (v.status) {
            case (#posted) true;
            case (#postedFromPending(_)) true;
            case (#pending(_)) false;
            case (#voided(_)) false;
          };
          if (counts) {
            for (l in v.record.legs.vals()) {
              let key = (l.account, l.currency);
              switch (Map.get(folded, cmpAC, key)) {
                case (?acc) { switch (l.side) { case (#debit) acc.dr += l.amount; case (#credit) acc.cr += l.amount } };
                case null {
                  let acc = { var dr = 0 : Nat; var cr = 0 : Nat };
                  switch (l.side) { case (#debit) acc.dr += l.amount; case (#credit) acc.cr += l.amount };
                  Map.add(folded, cmpAC, key, acc);
                };
              };
            };
          };
        };
        case null {};
      };
      i += 1;
    };
    for (code in accounts.vals()) {
      for (ccy in JCore.listCurrencies(js).vals()) {
        let maintained = JCore.accountTotal(js, code, ccy.code);
        let (dr, cr) = switch (Map.get(folded, cmpAC, (code, ccy.code))) {
          case (?acc) (acc.dr, acc.cr);
          case null (0, 0);
        };
        if (maintained.debitsPosted != dr or maintained.creditsPosted != cr) {
          return ?{
            account = code; currency = ccy.code;
            ledgerDebits = maintained.debitsPosted; ledgerCredits = maintained.creditsPosted;
            subledgerDebits = dr; subledgerCredits = cr;
          };
        };
      };
    };
    null
  };

  func cmpAC(a : (Text, Text), b : (Text, Text)) : Order.Order {
    switch (Text.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o }
  };

  /// A cross-currency deal: four legs through the position pair, each currency
  /// balancing within itself, at the rate recorded for the day named. The rate is
  /// read for that day alone — there is no nearest match and no carry-forward — and
  /// the amounts are checked against it so a deal cannot be booked at a rate it does
  /// not use.
  func fxDealPlan(
    bs : State, bb : Blocks,
    js : JCore.State,
    journalCaller : Principal,
    now : Nat64,
    x : {
      sell : JT.Currency; sellAmount : Nat; sellFrom : CT.Endpoint;
      buy : JT.Currency; buyAmount : Nat; buyTo : CT.Endpoint;
      rateAsOf : ProdT.Day; postingDate : ProdT.Day; valueDate : ProdT.Day;
      period : JT.PeriodId; narration : Text;
    },
    authId : Text,
  ) : Result.Result<Plan, T.BankError> {
    let ?functional = CloseCore.functional(bs.close) else return #err(#CloseError({ error = #NoFunctionalCurrency }));
    if (Text.equal(x.sell, x.buy)) return #err(#CloseError({ error = #InvalidRate({ reason = "a deal needs two different currencies" }) }));
    if (x.sellAmount == 0 or x.buyAmount == 0) return #err(#CloseError({ error = #InvalidRate({ reason = "a deal of zero moves nothing" }) }));
    let foreign = if (Text.equal(x.sell, functional)) x.buy else x.sell;
    if (not Text.equal(x.sell, functional) and not Text.equal(x.buy, functional)) {
      return #err(#CloseError({ error = #InvalidRate({ reason = "one side of a deal is the functional currency" }) }));
    };
    let ?pair = CloseCore.getPair(bs.close, foreign) else return #err(#CloseError({ error = #UnknownPair({ currency = foreign }) }));
    let ?rate = CloseCore.rateOn(bs.close, foreign, x.rateAsOf) else {
      return #err(#CloseError({ error = #MissingRate({ currency = foreign; asOf = x.rateAsOf }) }));
    };
    // the two amounts must be each other at the recorded rate, to the minor unit
    let foreignAmount = if (Text.equal(x.sell, functional)) x.buyAmount else x.sellAmount;
    let functionalAmount = if (Text.equal(x.sell, functional)) x.sellAmount else x.buyAmount;
    let expected = Fx.convert(foreignAmount, rate, #halfEven);
    if (expected.amount != functionalAmount) {
      return #err(#CloseError({ error = #InvalidRate({
        reason = "at the recorded rate " # Nat.toText(foreignAmount) # " " # foreign # " is "
          # Nat.toText(expected.amount) # " " # functional # ", not " # Nat.toText(functionalAmount);
      }) }));
    };
    switch (endpointLeg(bs, bb, js, x.sellFrom, x.sell)) {
      case (#err(e)) #err(e);
      case (#ok((sellAccount, sellSub))) {
        switch (endpointLeg(bs, bb, js, x.buyTo, x.buy)) {
          case (#err(e)) #err(e);
          case (#ok((buyAccount, buySub))) {
            let deal : Fx.Deal = {
              sell = x.sell; sellAmount = x.sellAmount; sellAccount; sellSubledger = sellSub;
              buy = x.buy; buyAmount = x.buyAmount; buyAccount; buySubledger = buySub;
            };
            switch (Fx.dealLegs(pair, functional, deal)) {
              case (#err(_)) #err(#CloseError({ error = #InvalidRate({ reason = "the deal's currencies do not match the pair" }) }));
              case (#ok(legs)) {
                if (not Fx.balancesPerCurrency(legs)) {
                  return #err(#CloseError({ error = #InvalidRate({ reason = "the generated legs do not balance per currency" }) }));
                };
                let ev : T.Event = #close(#fxDealBooked({
                  sell = x.sell; sellAmount = x.sellAmount; buy = x.buy; buyAmount = x.buyAmount;
                  rateNumerator = rate.numerator; rateDenominator = rate.denominator;
                  asOf = x.rateAsOf; day = x.valueDate;
                }));
                switch (postLegs(js, journalCaller, now, "fx-deal", [authId, x.sell, x.buy], legs, x.postingDate, x.valueDate, x.period, x.narration)) {
                  case (#err(e)) #err(e);
                  case (#ok(plan)) #ok({ bankEvent = ?ev; extra = []; journal = plan.journal });
                }
              };
            }
          };
        }
      };
    }
  };

  /// Resolve one side of a deal to an account and a sub-ledger. A product account
  /// brings its own sub-ledger and must be in the currency it is being moved in.
  func endpointLeg(bs : State, bb : Blocks, js : JCore.State, e : CT.Endpoint, currency : JT.Currency) : Result.Result<(JT.AccountCode, ?JT.SubledgerKey), T.BankError> {
    switch (e) {
      case (#glAccount(code)) {
        switch (requirePostableAccount(js, code)) { case (?err) #err(err); case null #ok((code, null)) }
      };
      case (#account(id)) {
        switch (requireAccount(bs, bb, id)) {
          case (#err(err)) #err(err);
          case (#ok((a, terms))) {
            if (not Text.equal(a.currency, currency)) {
              #err(#ProductError({ error = #CurrencyMismatch({ expected = a.currency; actual = currency }) }))
            } else #ok((terms.control, ?a.subledger))
          };
        }
      };
    }
  };

  /// The accrual correction: the fold re-evaluated over the range, less what was
  /// already booked for it, read back out of the log.
  func adjustAccrualPlan(
    bs : State, bb : Blocks,
    js : JCore.State,
    journalCaller : Principal,
    now : Nat64,
    x : { product : ProdT.ProductId; currency : JT.Currency; from : ProdT.Day; to : ProdT.Day; causedBy : Nat; postingDate : ProdT.Day; period : JT.PeriodId; narration : Text },
  ) : Result.Result<Plan, T.BankError> {
    let ?v = ProductCore.currentVersion(bs.product, x.product) else return #err(#ProductError({ error = #UnknownProduct({ product = x.product }) }));
    if (x.to <= x.from) return #err(#ProductError({ error = #NothingToAccrue({ account = 0; from = x.from; to = x.to }) }));
    // recomputed: the fold over every account of the product, for the range
    var num : Nat = 0;
    var den : Nat = 1;
    var negative = false;
    var examined = 0;
    for (a in ProductCore.accountsOfProduct(bs.product, productBlocks(bb), x.product).vals()) {
      if (Text.equal(a.currency, x.currency)) {
        examined += 1;
        switch (accountAccrual(bs, js, a, x.from, x.to)) {
          case (#err(e)) return #err(e);
          case (#ok(exact_)) {
            if (exact_.numerator != 0) {
              if (exact_.negative) negative := true;
              num := num * exact_.denominator + exact_.numerator * den;
              den := den * exact_.denominator;
            };
          };
        };
      };
    };
    if (examined == 0) return #err(#ProductError({ error = #NothingToAccrue({ account = 0; from = x.from; to = x.to }) }));
    let recomputed = (I.round({ numerator = num; denominator = den; negative }, v.terms.rounding)).amount;
    // booked: the sum of the accrual postings already recorded for the range, read
    // from the fold of the log rather than from a counter
    let booked = ProductCore.accrualTotalBetween(bs.product, x.product, x.currency, x.from, x.to);
    let adj = BackValue.compute(x.product, x.currency, x.from, x.to, recomputed, booked, examined);
    let ev : T.Event = #close(#accrualAdjusted({
      product = x.product; currency = x.currency; from = x.from; to = x.to;
      recomputed = adj.recomputed; booked = adj.booked; movement = adj.movement;
      direction = adj.direction; causedBy = x.causedBy; examined = adj.examined;
    }));
    switch (accrualLegs(v.terms, x.currency, 1)) {
      case (#err(e)) #err(e);
      case (#ok((debitLeg, creditLeg))) {
        switch (BackValue.legs(debitLeg.account, creditLeg.account, x.currency, adj)) {
          case null #ok({ bankEvent = ?ev; extra = []; journal = [] });
          case (?legs) {
            let input : JT.PostingInput = {
              idempotencyKey = BackValue.key(x.product, x.currency, x.from, x.to, x.causedBy);
              postingDate = x.postingDate; valueDate = x.to; period = x.period; legs;
              sourceRef = { kind = "accrual-adjustment"; id = Nat.toText(x.causedBy) };
              narration = x.narration;
              correctionOf = null;
            };
            switch (postOne(js, journalCaller, now, input)) {
              case (#err(e)) #err(e);
              case (#ok(plan)) #ok({ bankEvent = ?ev; extra = []; journal = plan.journal });
            }
          };
        }
      };
    }
  };

  /// One deferral schedule's amortisation for a period.
  func amortiseOnePlan(
    bs : State,
    js : JCore.State,
    journalCaller : Principal,
    now : Nat64,
    id : Text,
    period : JT.PeriodId,
    postingDate : ProdT.Day,
    valueDate : ProdT.Day,
    narration : Text,
  ) : Result.Result<Plan, T.BankError> {
    let ?entry = CloseCore.getSchedule(bs.close, id) else return #err(#CloseError({ error = #UnknownSchedule({ schedule = id }) }));
    if (CloseCore.hasPosted(entry, period)) {
      return #err(#CloseError({ error = #AlreadyAmortised({ schedule = id; period }) }));
    };
    let n = CloseCore.postedPeriods(entry) + 1;
    switch (Deferrals.amountFor(entry.schedule, n)) {
      case (#err(#beyondSchedule(d))) #err(#CloseError({ error = #ScheduleComplete({ schedule = d.schedule; periods = d.periods }) }));
      case (#err(_)) #err(#CloseError({ error = #InvalidSchedule({ reason = "the schedule cannot amortise" }) }));
      case (#ok(amount)) {
        let remaining = Deferrals.remainingAfter(entry.schedule, n);
        let ev : T.Event = #close(#deferralAmortised({ schedule = id; period; sequence = n; amount; remaining }));
        switch (Deferrals.legs(entry.schedule, amount)) {
          case null #ok({ bankEvent = ?ev; extra = []; journal = [] });
          case (?legs) {
            switch (postLegs(js, journalCaller, now, "deferral", [id, period, Nat.toText(n)], legs, postingDate, valueDate, period, narration)) {
              case (#err(e)) #err(e);
              case (#ok(plan)) #ok({ bankEvent = ?ev; extra = []; journal = plan.journal });
            }
          };
        }
      };
    }
  };

  /// The revaluation step: every monetary pair, at the rate recorded for the run's
  /// own closing date, posted entirely in the functional currency.
  func revaluePlan(
    bs : State,
    js : JCore.State,
    journalCaller : Principal,
    now : Nat64,
    x : { book : Text; period : JT.PeriodId; postingDate : ProdT.Day; narration : Text },
  ) : Result.Result<Plan, T.BankError> {
    switch (runStep(bs, x.book, x.period, #revalued)) {
      case (#err(e)) #err(e);
      case (#ok(#idempotent)) #ok({ bankEvent = null; extra = []; journal = [] });
      case (#ok(#go(run))) {
        let ?functional = CloseCore.functional(bs.close) else return #err(#CloseError({ error = #NoFunctionalCurrency }));
        let inputs = List.empty<JT.PostingInput>();
        var currencies = 0;
        var posted = 0;
        var total = 0;
        for (pair in CloseCore.listPairs(bs.close).vals()) {
          if (pair.monetary) {
            currencies += 1;
            let ?rate = CloseCore.rateOn(bs.close, pair.currency, run.closingDate) else {
              return #err(#CloseError({ error = #MissingRate({ currency = pair.currency; asOf = run.closingDate }) }));
            };
            let pos = JCore.balance(js, pair.position, null, pair.currency);
            let eq = JCore.balance(js, pair.equivalent, null, functional);
            // the position on its own side, and the equivalent on its own
            let position = if (pos.debitsPosted >= pos.creditsPosted) pos.debitsPosted - pos.creditsPosted else pos.creditsPosted - pos.debitsPosted;
            let positionSide : JT.Side = if (pos.debitsPosted >= pos.creditsPosted) #debit else #credit;
            let equivalent = if (eq.debitsPosted >= eq.creditsPosted) eq.debitsPosted - eq.creditsPosted else eq.creditsPosted - eq.debitsPosted;
            switch (Fx.revalue(pair, position, positionSide, equivalent, rate, #halfEven)) {
              case (#err(_)) return #err(#CloseError({ error = #NotMonetary({ currency = pair.currency }) }));
              case (#ok(rev)) {
                switch (Fx.revaluationLegs(pair, functional, rev)) {
                  case null {};
                  case (?legs) {
                    if (not Posting.balances(legs)) {
                      return #err(#CloseError({ error = #InvalidPair({ reason = "the revaluation legs do not balance" }) }));
                    };
                    List.add(inputs, {
                      idempotencyKey = Posting.key("fx-revaluation", [x.book, x.period, pair.currency]);
                      postingDate = x.postingDate; valueDate = run.closingDate; period = x.period; legs;
                      sourceRef = { kind = "fx-revaluation"; id = pair.currency };
                      narration = x.narration;
                      correctionOf = null;
                    });
                    posted += 1;
                    total += rev.movement;
                  };
                };
              };
            };
          };
        };
        let ev : T.Event = #close(#periodEndRevalued({ book = x.book; period = x.period; currencies; posted; total }));
        if (List.size(inputs) == 0) return #ok({ bankEvent = ?ev; extra = []; journal = [] });
        switch (JCore.prepareBatch(js, journalCaller, now, List.toArray(inputs))) {
          case (#err(b)) #err(#JournalBatchError({ index = b.index; error = b.error }));
          case (#ok(prepared)) {
            let steps = List.empty<JournalStep>();
            for (pr in prepared.vals()) {
              switch (pr) { case (#event(e)) List.add(steps, #event(e)); case (#duplicate(i)) List.add(steps, #existing(i)) };
            };
            #ok({ bankEvent = ?ev; extra = []; journal = List.toArray(steps) })
          };
        }
      };
    }
  };

  /// The deferral step of the close: every active schedule amortised for the period,
  /// in one batch, so the step is one transition rather than a sequence a caller must
  /// remember to finish.
  func amortisePeriodPlan(
    bs : State,
    js : JCore.State,
    journalCaller : Principal,
    now : Nat64,
    x : { book : Text; period : JT.PeriodId; postingDate : ProdT.Day; narration : Text },
  ) : Result.Result<Plan, T.BankError> {
    switch (runStep(bs, x.book, x.period, #deferralsAmortised)) {
      case (#err(e)) #err(e);
      case (#ok(#idempotent)) #ok({ bankEvent = null; extra = []; journal = [] });
      case (#ok(#go(run))) {
        let inputs = List.empty<JT.PostingInput>();
        let rows = List.empty<{ schedule : Text; sequence : Nat; amount : Nat; remaining : Nat }>();
        var total = 0;
        for (entry in CloseCore.listSchedules(bs.close).vals()) {
          if (Text.equal(entry.schedule.book, x.book) and not CloseCore.hasPosted(entry, x.period)) {
            let n = CloseCore.postedPeriods(entry) + 1;
            switch (Deferrals.amountFor(entry.schedule, n)) {
              case (#err(_)) {};                 // a completed schedule amortises nothing further
              case (#ok(amount)) {
                switch (Deferrals.legs(entry.schedule, amount)) {
                  case null {};
                  case (?legs) {
                    List.add(inputs, {
                      idempotencyKey = Posting.key("deferral", [entry.schedule.id, x.period, Nat.toText(n)]);
                      postingDate = x.postingDate; valueDate = run.closingDate; period = x.period; legs;
                      sourceRef = { kind = "deferral"; id = entry.schedule.id };
                      narration = x.narration;
                      correctionOf = null;
                    });
                    List.add(rows, {
                      schedule = entry.schedule.id; sequence = n; amount;
                      remaining = Deferrals.remainingAfter(entry.schedule, n);
                    });
                    total += amount;
                  };
                };
              };
            };
          };
        };
        let ev : T.Event = #close(#periodEndDeferralsAmortised({ book = x.book; period = x.period; total; rows = List.toArray(rows) }));
        if (List.size(inputs) == 0) return #ok({ bankEvent = ?ev; extra = []; journal = [] });
        switch (JCore.prepareBatch(js, journalCaller, now, List.toArray(inputs))) {
          case (#err(b)) #err(#JournalBatchError({ index = b.index; error = b.error }));
          case (#ok(prepared)) {
            let steps = List.empty<JournalStep>();
            for (pr in prepared.vals()) {
              switch (pr) { case (#event(e)) List.add(steps, #event(e)); case (#duplicate(i)) List.add(steps, #existing(i)) };
            };
            #ok({ bankEvent = ?ev; extra = []; journal = List.toArray(steps) })
          };
        }
      };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  THE END-OF-DAY BATCH
  // ═══════════════════════════════════════════════════════

  /// The highest account identifier in existence. Recorded when a run opens and used as
  /// its upper bound, so accounts opened after the run are excluded by construction
  /// rather than by hoping an iteration order is stable.
  public func highestAccount(bs : State) : Nat { ProductCore.highestAccount(bs.product) };

  /// The accounts of a product at or below a bound, in identifier order. This is the
  /// list a plan item's position range indexes into, and ordering it by identifier is
  /// what makes a position range mean the same thing on every chunk.
  func shardAccounts(bs : State, bb : Blocks, product : Text, maxAccount : Nat) : [ProductCore.AccountEntry] {
    let all = ProductCore.accountsOfProduct(bs.product, productBlocks(bb), product);
    let kept = List.empty<ProductCore.AccountEntry>();
    for (a in all.vals()) { if (a.id <= maxAccount and a.status != #closed) List.add(kept, a) };
    let arr = List.toArray(kept);
    Array.sort<ProductCore.AccountEntry>(arr, func(x, y) { Nat.compare(x.id, y.id) })
  };

  /// What the plan is built from. A pure projection of the product registry and the
  /// account set, so the plan is a function of its inputs and nothing else.
  public func planInput(bs : State, bb : Blocks, book : Text, maxAccount : Nat, shardSize : Nat) : Batch.Input {
    let products = List.empty<{ product : Text; currency : JT.Currency; accounts : Nat; accrues : Bool; credit : Bool; term : Bool; charges : Bool }>();
    // the registry in identifier order, so the plan does not depend on map iteration
    let versions = Array.sort<ProductCore.VersionEntry>(
      ProductCore.listVersions(bs.product),
      func(a, b) { switch (Text.compare(a.id, b.id)) { case (#equal) Nat.compare(a.version, b.version); case (o) o } },
    );
    let seen = List.empty<Text>();
    for (v in versions.vals()) {
      var already = false;
      for (id in List.values(seen)) { if (Text.equal(id, v.id)) already := true };
      if (not already) {
        List.add(seen, v.id);
        if (v.terms.kind != #till) {
          // only the accounts of this book are this book's work
          var n = 0;
          for (a in shardAccounts(bs, bb, v.id, maxAccount).vals()) { if (Text.equal(a.book, book)) n += 1 };
          List.add(products, {
            product = v.id; currency = v.terms.currency; accounts = n;
            accrues = v.terms.interest != null;
            credit = v.terms.kind == #loan;
            term = v.terms.kind == #termDeposit or v.terms.kind == #recurringDeposit;
            charges = v.terms.charges.size() > 0;
          });
        };
      };
    };
    var tills = 0;
    for (t in ProductCore.listTills(bs.product, productBlocks(bb)).vals()) {
      if (Text.equal(t.book, book) and t.status != #closed) tills += 1;
    };
    {
      products = List.toArray(products);
      instructions = BatchCore.instructionsOf(bs.batch, book).size();
      tills;
      monitoringRules = MonitoringCore.active(bs.monitoring, #endOfDay).size();
      offers = OriginationCore.offeredInBook(bs.origination, book);
      facilities = FacilityCore.openInBook(bs.facility, book).size();
      trade = TradeCore.openInBook(bs.trade, book).size();
      sharia = IslamicCore.openInBook(bs.islamic, book).size();
      shardSize;
    }
  };

  /// What one advance did. The run commits as it goes — see `runEndOfDayChunk` — so this
  /// is a report and not a plan the caller still has to apply.
  public type Advance = {
    completed : Bool;
    cursorFrom : Nat;
    cursorTo : Nat;
    posted : Nat;
    examined : Nat;
    zeroMovement : Nat;
    failures : [BT.Failure];
    /// The failures the retry pass cleared, and the ones it re-attempted without
    /// success.
    resolved : [{ item : Nat; entity : Text }];
    retried : [BT.Failure];
    /// Every bank block this advance recorded, and every journal posting it used —
    /// whether it made the posting or read an existing one under the same derived key.
    blocks : [Nat];
    postings : [Nat];
  };

  /// The accumulator a chunk fills. Kept as one record so every job adds to the same
  /// totals and a job cannot quietly fail to count.
  /// How a run records. Both callbacks append to the log **and** apply to state, exactly
  /// as the actor's own `commitBank` and `commitJournal` do, and they are called as the
  /// run proceeds rather than after it.
  ///
  /// That is not a convenience. A job reads what earlier jobs posted — a
  /// percent-of-interest charge reads job 1's accrual, a statement cut reads the day's
  /// movements, a provision reads the allowance already carried — so a chunk whose
  /// postings were invisible to the rest of the chunk would produce a different answer
  /// depending on where the chunk boundaries happened to fall. It would also let two
  /// postings in one chunk each pass a sub-ledger limit that together they breach, and
  /// let a second posting under a key the same chunk already used be written as a second
  /// block instead of being recognised as the duplicate it is. The whole advance is one
  /// message, so committing as it goes is as atomic as committing at the end: a trap
  /// rolls back all of it.
  public type Recorder = {
    bank : T.Event -> Nat;
    journal : JT.Event -> Nat;
    /// The window rules for one account on one day, or the refusal. The aggregates live beside
    /// the posting indexes, outside this state, so the batch is handed the evaluation the way it
    /// is handed the logs.
    monitor : (Nat, Nat) -> Result.Result<[MT.Finding], MT.MonitoringError>;
  };

  /// A recorder's evaluation when a caller has no rules: nothing found.
  public func noMonitor(_ : Nat, _ : Nat) : Result.Result<[MT.Finding], MT.MonitoringError> { #ok([]) };

  /// The alert events of the log, for the alert rows that rebuild their records from blocks.
  public func alertBlocks(bb : Blocks) : AlertCore.Blocks {
    { get = func(i : Nat) : ?AlT.AlertEvent { switch (bb.get(i)) { case (?b) { switch (b.event) { case (#alert(ae)) ?ae; case (_) null } }; case null null } } }
  };

  /// Open an alert for a finding unless one already exists for the same finding: the event to
  /// record, or null. Idempotent by the finding's key, which is what lets a chunk be re-derived.
  public func alertFor(bs : State, finding : MT.Finding, source : AlT.Source) : ?T.Event {
    switch (AlertCore.known(bs.alerts, finding)) {
      case (?_) null;
      case null ?#alert(#alertOpened({ finding; source }));
    }
  };

  type ChunkAcc = {
    recorder : Recorder;
    blocks : List.List<Nat>;
    postings : List.List<Nat>;
    var posted : Nat;
    var examined : Nat;
    var zeroMovement : Nat;
    failures : List.List<BT.Failure>;
  };

  func newAcc(recorder : Recorder) : ChunkAcc {
    {
      recorder;
      blocks = List.empty<Nat>();
      postings = List.empty<Nat>();
      var posted = 0;
      var examined = 0;
      var zeroMovement = 0;
      failures = List.empty<BT.Failure>();
    }
  };

  /// Record a bank event now, so a later item of the same chunk reads the state it made.
  func record(acc : ChunkAcc, event : T.Event) { List.add(acc.blocks, acc.recorder.bank(event)) };

  /// Submit one posting on behalf of the batch.
  ///
  /// Where the journal answers `#duplicate`, the run does **not** treat the flag as
  /// success. It reads the named block and checks that its legs are the legs the job
  /// intended, and refuses with a typed error if they are not.
  ///
  /// The division of labour, stated so neither side is assumed: the journal refuses a key
  /// reused with different content outright — `#IdempotencyKeyReused`, naming the block
  /// that already holds the key — and only returns `#duplicate` when its own content hash
  /// over the whole record matches. So the leg check here finds no mismatch that the
  /// journal lets through *today*. It stays because it is the run's own guard over the
  /// one thing the run cares about, across a module boundary, and because it does not
  /// depend on what some other module's content hash happens to cover. That rule is not a
  /// precaution invented here: the deployed DvP core's phantom-escrow defect was
  /// exactly "recorded a duplicate as success while holding nothing", and the
  /// correction was to read the named block before believing it.
  func batchPost(js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64, acc : ChunkAcc, input : JT.PostingInput) : ?Text {
    switch (JCore.preparePost(js, journalCaller, now, input)) {
      case (#err(e)) ?debug_show (e);
      case (#ok(#event(ev))) { List.add(acc.postings, acc.recorder.journal(ev)); acc.posted += 1; null };
      case (#ok(#duplicate(idx))) {
        switch (JCore.postingView(js, jb, idx)) {
          case null ?("the journal named block " # Nat.toText(idx) # " as a duplicate and it cannot be read");
          case (?v) {
            if (not legsEqual(v.record.legs, input.legs)) {
              ?("the duplicate at block " # Nat.toText(idx) # " does not carry the legs this job intended")
            } else {
              List.add(acc.postings, idx);
              null
            }
          };
        }
      };
    }
  };

  /// Leg-for-leg equality, in order. A duplicate whose legs differ in any field is not
  /// the posting the job meant to make.
  func legsEqual(a : [JT.Leg], b : [JT.Leg]) : Bool {
    if (a.size() != b.size()) return false;
    var i = 0;
    while (i < a.size()) {
      let x = a[i];
      let y = b[i];
      if (not Text.equal(x.account, y.account)) return false;
      if (x.subledger != y.subledger) return false;
      if (x.side != y.side) return false;
      if (not Text.equal(x.currency, y.currency)) return false;
      if (x.amount != y.amount) return false;
      i += 1;
    };
    true
  };

  func fail(acc : ChunkAcc, item : Nat, job : Batch.Job, entity : Text, error : Text) {
    if (List.size(acc.failures) < Batch.MAX_FAILURES) {
      List.add(acc.failures, { item; job; entity; error; attempts = 1 });
    };
  };

  /// Advance an open run by up to `limit` plan items.
  ///
  /// Anyone may call this. The plan was fixed when the run opened and is re-derived here
  /// and checked against the recorded hash, so a caller cannot choose what is posted —
  /// only that progress happens. The postings are attributed to the canister.
  public func runEndOfDayChunk(
    bs : State, bb : Blocks,
    js : JCore.State,
    jb : JCore.Blocks,
    journalCaller : Principal,
    now : Nat64,
    book : Text,
    businessDate : ProdT.Day,
    limit : Nat,
    recorder : Recorder,
  ) : Result.Result<Advance, T.BankError> {
    if (limit == 0 or limit > Batch.MAX_ADVANCE_LIMIT) {
      return #err(#BatchError({ error = #AdvanceLimit({ limit; max = Batch.MAX_ADVANCE_LIMIT }) }));
    };
    let ?run = BatchCore.getRun(bs.batch, book, businessDate) else {
      return #err(#BatchError({ error = #UnknownRun({ book; businessDate }) }));
    };
    if (BatchCore.isComplete(run)) {
      return #err(#BatchError({ error = #RunComplete({ book; businessDate }) }));
    };
    // the plan, re-derived and checked against what the opening block recorded
    let items = switch (Batch.plan(planInput(bs, bb, book, run.maxAccount, run.shardSize))) {
      case (#ok(xs)) xs;
      case (#err(#invalidShardSize(d))) return #err(#BatchError({ error = #InvalidShardSize({ shardSize = d.shardSize }) }));
      case (#err(#planTooLarge(d))) return #err(#BatchError({ error = #PlanTooLarge({ items = d.items }) }));
    };
    let recomputed = Batch.planHash(items);
    if (recomputed != run.planHash) {
      return #err(#BatchError({ error = #PlanHashMismatch({ recorded = run.planHash; recomputed }) }));
    };
    if (run.cursor >= items.size()) {
      return #err(#BatchError({ error = #NothingToAdvance({ book; businessDate; cursor = run.cursor }) }));
    };
    // ── the retry pass ──────────────────────────────────────────────────────
    //
    // Before any new work, the run re-attempts the failures it is still carrying whose
    // attempt count is below the book's declared retry limit. Only the entity that
    // failed is worked, so a re-attempt can neither re-examine nor re-record anything
    // that already succeeded; and because every posting key is derived, a re-attempt of
    // something that did in fact post reads the existing block rather than making a
    // second one.
    //
    // A re-attempt that succeeds resolves the failure and so unblocks the period close.
    // One that fails again comes back with its attempt count raised by one; once that
    // count reaches the limit the failure is parked — never re-attempted, and still
    // blocking the close until someone resolves it. The pass reports what it posted and
    // nothing else: `examined` is the plan's coverage, not a tally of repair work.
    let acc = newAcc(recorder);
    let resolved = List.empty<{ item : Nat; entity : Text }>();
    let reFailed = List.empty<BT.Failure>();
    for (f in BatchCore.retryable(bs.batch, run).vals()) {
      if (f.item < items.size()) {
        let before = List.size(acc.failures);
        runItem(bs, bb, js, jb, journalCaller, now, acc, run, items[f.item], f.item, businessDate, ?f.entity);
        var again = false;
        var i = before;
        while (i < List.size(acc.failures)) {
          let g = List.at(acc.failures, i);
          if (g.item == f.item and Text.equal(g.entity, f.entity)) again := true;
          i += 1;
        };
        if (again) List.add(reFailed, { f with attempts = f.attempts + 1 })
        else List.add(resolved, { item = f.item; entity = f.entity });
      };
    };
    // What the repair work cost is reported as repair work: the chunk's own figures
    // below are measured from here, so `examined` stays the plan's coverage.
    let retryPosted = acc.posted;
    let retryExamined = acc.examined;
    let retryZero = acc.zeroMovement;
    let retryFailures = List.size(acc.failures);
    if (List.size(resolved) > 0 or List.size(reFailed) > 0) {
      record(acc, #batch(#eodRetry({
        book; businessDate;
        resolved = List.toArray(resolved);
        failures = List.toArray(reFailed);
        posted = retryPosted;
      })));
    };

    // ── the cursor pass ─────────────────────────────────────────────────────
    let from = run.cursor;
    var cursor = run.cursor;
    var done = 0;
    while (done < limit and cursor < items.size()) {
      runItem(bs, bb, js, jb, journalCaller, now, acc, run, items[cursor], cursor, businessDate, null);
      cursor += 1;
      done += 1;
    };
    // the failures this chunk found, which are the ones after the retry pass's
    let chunkFailures = List.empty<BT.Failure>();
    var fi = retryFailures;
    while (fi < List.size(acc.failures)) { List.add(chunkFailures, List.at(acc.failures, fi)); fi += 1 };
    record(acc, #batch(#eodChunk({
      book; businessDate; cursorFrom = from; cursorTo = cursor;
      posted = acc.posted - retryPosted;
      examined = acc.examined - retryExamined;
      zeroMovement = acc.zeroMovement - retryZero;
      failures = List.toArray(chunkFailures);
    })));
    let completed = cursor >= items.size();
    if (completed) {
      // the totals are the run's own, so the completion block states what the whole run
      // did rather than what its last chunk did
      record(acc, #batch(#eodCompleted({
        book; businessDate;
        posted = run.posted; examined = run.examined; zeroMovement = run.zeroMovement;
        failures = BatchCore.failureCount(run);
      })));
    };
    #ok({
      completed; cursorFrom = from; cursorTo = cursor;
      posted = acc.posted;
      examined = acc.examined - retryExamined;
      zeroMovement = acc.zeroMovement - retryZero;
      failures = List.toArray(chunkFailures);
      resolved = List.toArray(resolved);
      retried = List.toArray(reFailed);
      blocks = List.toArray(acc.blocks);
      postings = List.toArray(acc.postings);
    })
  };

  /// One plan item. Every job records what it examined, so a zero-movement entity is
  /// counted rather than invisible, and a failure advances the cursor rather than
  /// stopping it.
  func runItem(
    bs : State, bb : Blocks,
    js : JCore.State,
    jb : JCore.Blocks,
    journalCaller : Principal,
    now : Nat64,
    acc : ChunkAcc,
    run : BatchCore.RunEntry,
    item : Batch.PlanItem,
    index : Nat,
    day : ProdT.Day,
    /// When set, only the named entity is worked: the retry pass re-attempts the one
    /// entity that failed and never the whole shard again, so a re-attempt cannot
    /// re-examine or re-record anything that already succeeded.
    only : ?Text,
  ) {
    let period = switch (periodForDay(js, day)) { case (?p) p; case null "" };
    if (Text.equal(period, "") and item.job != #ageing and item.job != #statementCut and item.job != #tillCheck and item.job != #offerExpiry) {
      acc.examined += 1;
      fail(acc, index, item.job, item.product, "no open period contains day " # Nat.toText(day));
      return;
    };
    switch (item.job) {
      case (#accrual) jobAccrual(bs, bb, js, jb, journalCaller, now, acc, item, index, day, period);
      case (#charges) forShard(bs, bb, run, item, only, func(a) { jobCharge(bs, bb, js, jb, journalCaller, now, acc, item, index, day, period, a) });
      case (#instalmentsDue) forShard(bs, bb, run, item, only, func(a) { jobInstalment(bs, bb, js, jb, journalCaller, now, acc, item, index, day, period, a) });
      case (#ageing) forShard(bs, bb, run, item, only, func(a) { jobAgeing(bs, bb, js, jb, journalCaller, now, acc, item, index, day, period, a) });
      case (#provisioning) forShard(bs, bb, run, item, only, func(a) { jobProvision(bs, bb, js, jb, journalCaller, now, acc, item, index, day, period, a) });
      case (#maturity) forShard(bs, bb, run, item, only, func(a) { jobMaturity(bs, js, jb, journalCaller, now, acc, item, index, day, period, a) });
      case (#standingInstructions) jobInstructions(bs, bb, js, jb, journalCaller, now, acc, run, item, index, day, period, only);
      case (#statementCut) forShard(bs, bb, run, item, only, func(a) { jobStatement(bs, js, acc, item, index, day, a) });
      case (#tillCheck) jobTillCheck(bs, bb, js, acc, item, index, day, run.book, only);
      case (#monitoring) forShard(bs, bb, run, item, only, func(a) { jobMonitoring(bs, acc, item, index, day, a) });
      case (#offerExpiry) jobOfferExpiry(bs, acc, item, index, day, run.book, only);
      case (#facilities) jobFacilities(bs, bb, js, jb, journalCaller, now, acc, item, index, day, period, run.book, only);
      case (#trade) jobTrade(bs, bb, js, jb, journalCaller, now, acc, item, index, day, period, run.book, only);
      case (#sharia) jobSharia(bs, bb, js, jb, journalCaller, now, acc, item, index, day, period, run.book, only);
    };
  };

  /// The accounts a per-account item covers: the product's accounts of the run's book,
  /// in identifier order, in the item's own half-open position range.
  func forShard(bs : State, bb : Blocks, run : BatchCore.RunEntry, item : Batch.PlanItem, only : ?Text, body : (ProductCore.AccountEntry) -> ()) {
    let all = shardAccounts(bs, bb, item.product, run.maxAccount);
    let mine = List.empty<ProductCore.AccountEntry>();
    for (a in all.vals()) { if (Text.equal(a.book, run.book)) List.add(mine, a) };
    let arr = List.toArray(mine);
    // `from` and `to` are 1-based and the range is **half-open**, exactly as
    // `Batch.plan` emits it and as `Batch.entityCount` counts it. Treating it as closed
    // would process the account at every shard boundary twice, which is invisible in
    // the journal — the derived key makes the second attempt a duplicate — and visible
    // only as an `examined` total that changes with the shard size.
    var i = item.from;
    while (i < item.to and i >= 1 and i <= arr.size()) {
      let a = arr[i - 1];
      switch (only) {
        case null body(a);
        case (?e) { if (Text.equal(e, Nat.toText(a.id))) body(a) };
      };
      i += 1;
    };
  };

  // ─── job 1: interest accrual ──────────────────────────────────────────────

  /// One aggregate posting per (product, currency) for the date. Must precede anything
  /// that reads accrued interest, which is why it is first in the plan and not a matter
  /// of when the operator happened to run it.
  func jobAccrual(
    bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64,
    acc : ChunkAcc, item : Batch.PlanItem, index : Nat, day : ProdT.Day, period : JT.PeriodId,
  ) {
    switch (accrualFor(bs, bb, js, item.product, item.currency, day)) {
      case (#err(e)) { acc.examined += 1; fail(acc, index, item.job, item.product, debug_show (e)) };
      case (#ok(r)) {
        acc.examined += r.examined;
        // The run is recorded whether or not it posts: a day on which nothing accrued is
        // still a day that was run, and the period close needs that evidence.
        record(acc, #product(#accrualPosted({
          product = item.product; currency = item.currency; day; amount = r.amount; accounts = r.examined;
        })));
        let ?v = ProductCore.currentVersion(bs.product, item.product) else {
          fail(acc, index, item.job, item.product, "the product is no longer registered");
          return;
        };
        // interest on exposures in suspense (collections and recovery): one posting to the suspense role for the sum, a block per exposure
        if (r.suspended.size() > 0) {
          var total = 0;
          for ((_, amt) in r.suspended.vals()) total += amt;
          switch (Products.roleAccount(v.terms, #interestReceivable), Products.roleAccount(v.terms, #suspense)) {
            case (?receivable, ?suspense) {
              let input = Posting.simple("accrual-suspense", [item.product, item.currency, Nat.toText(day)],
                Posting.leg(receivable, null, #debit, item.currency, total), Posting.leg(suspense, null, #credit, item.currency, total), day, day, period, "end-of-day accrual held in suspense");
              switch (batchPost(js, jb, journalCaller, now, acc, input)) {
                case (?why) fail(acc, index, item.job, item.product, why);
                case null { for ((account, amount) in r.suspended.vals()) record(acc, #collections(#interestSuspended({ account; amount; day }))) };
              };
            };
            case (_, _) fail(acc, index, item.job, item.product, "the product maps no suspense account for interest on exposures in default");
          };
        };
        if (r.amount == 0) { acc.zeroMovement += r.examined; return };
        switch (accrualLegs(v.terms, item.currency, r.amount)) {
          case (#err(e)) fail(acc, index, item.job, item.product, debug_show (e));
          case (#ok((debit, credit))) {
            let input = Posting.simple("accrual", [item.product, item.currency, Nat.toText(day)], debit, credit, day, day, period, "end-of-day accrual");
            switch (batchPost(js, jb, journalCaller, now, acc, input)) {
              case (?why) fail(acc, index, item.job, item.product, why);
              case null {};
            };
          };
        };
      };
    };
  };

  // ─── job 2: charges ───────────────────────────────────────────────────────

  /// Charges whose declared due date is the business date. A percent-of-interest charge
  /// reads the accrual job 1 has already posted, which is the dependency the plan order
  /// exists to honour.
  func jobCharge(
    bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64,
    acc : ChunkAcc, item : Batch.PlanItem, index : Nat, day : ProdT.Day, period : JT.PeriodId,
    a : ProductCore.AccountEntry,
  ) {
    acc.examined += 1;
    let ?terms = ProductCore.termsOf(bs.product, a) else {
      fail(acc, index, item.job, Nat.toText(a.id), "the account's product version is gone");
      return;
    };
    if (a.status != #active) { acc.zeroMovement += 1; return };
    let rows = switch (ProductCore.schedule(bs.product, productBlocks(bb), a)) { case (?sv) sv.rows; case null [] };
    let overdueDays = if (rows.size() == 0) 0 else Loans.arrears(rows, loanRepaid(js, a, terms, day), day).overdueDays;
    let closed : ?ProdT.Day = switch (a.status) { case (#closed) ?day; case (_) null };
    var any = false;
    for (c in terms.charges.vals()) {
      if (Charges.dueOn(c.timing, day, a.opened, closed, overdueDays)) {
        if (ProductCore.chargeApplied(bs.product, productBlocks(bb), a.id, c.id, day) == null and ProductCore.chargeWaived(bs.product, productBlocks(bb), a.id, c.id, day) == null) {
          // the bases a batch can supply: the outstanding position and the interest the
          // accrual job posted for this account's own window
          let outstanding = Posting.accountBalanceOn(js, terms.control, a.subledger, a.currency, ProductCore.normalSideOf(terms.kind), day).net;
          let interest = switch (accountAccrual(bs, js, a, day, day + 1)) {
            case (#ok(x)) ?(I.round(x, terms.rounding)).amount;
            case (#err(_)) null;
          };
          let base : Charges.Base = { amount = null; interest; outstanding = ?outstanding };
          switch (Charges.amountOf(c, base, terms.rounding)) {
            case (#err(#roundsToZero(_))) { acc.zeroMovement += 1 };
            case (#err(#baseMissing(d))) fail(acc, index, item.job, Nat.toText(a.id), "charge " # d.charge # " needs " # d.needs);
            case (#ok(r)) {
              let ?income = Charges.incomeAccount(terms, c) else {
                fail(acc, index, item.job, Nat.toText(a.id), "charge " # c.id # " has no income account");
                return;
              };
              switch (chargeDebitAccount(terms, c)) {
                case (#err(e)) fail(acc, index, item.job, Nat.toText(a.id), debug_show (e));
                case (#ok(debitAccount)) {
                  let debit = Posting.leg(debitAccount, ?a.subledger, #debit, a.currency, r.amount);
                  let credit = Posting.leg(income, null, #credit, a.currency, r.amount);
                  let input = Posting.simple("charge", [Nat.toText(a.id), c.id, Nat.toText(day)], debit, credit, day, day, period, "end-of-day charge " # c.id);
                  switch (batchPost(js, jb, journalCaller, now, acc, input)) {
                    case (?why) fail(acc, index, item.job, Nat.toText(a.id), why);
                    case null {
                      record(acc, #product(#chargeApplied({ account = a.id; charge = c.id; amount = r.amount; day })));
                      any := true;
                    };
                  };
                };
              };
            };
          };
        };
      };
    };
    if (not any) acc.zeroMovement += 1;
  };

  // ─── job 3: instalments falling due ───────────────────────────────────────

  /// The instalment whose due date is the business date moves into the borrower's own
  /// receivable sub-ledger, so a repayment has something to be allocated against. The
  /// control account's total does not change — this is a move between the aggregate
  /// receivable and one borrower's share of it.
  func jobInstalment(
    bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64,
    acc : ChunkAcc, item : Batch.PlanItem, index : Nat, day : ProdT.Day, period : JT.PeriodId,
    a : ProductCore.AccountEntry,
  ) {
    acc.examined += 1;
    let ?terms = ProductCore.termsOf(bs.product, a) else {
      fail(acc, index, item.job, Nat.toText(a.id), "the account's product version is gone");
      return;
    };
    let ?sv = ProductCore.schedule(bs.product, productBlocks(bb), a) else { acc.zeroMovement += 1; return };
    if (a.writtenOff) { acc.zeroMovement += 1; return };
    var due : ?ProdT.Instalment = null;
    for (r in sv.rows.vals()) { if (r.dueDate == day) due := ?r };
    switch (due) {
      case null { acc.zeroMovement += 1 };
      case (?r) {
        if (r.interest == 0) {
          record(acc, #batch(#instalmentDue({ account = a.id; day; instalment = r.number; interest = 0; principal = r.principal })));
          acc.zeroMovement += 1;
          return;
        };
        let ?receivable = Products.roleAccount(terms, #interestReceivable) else {
          fail(acc, index, item.job, Nat.toText(a.id), "the product maps no interest receivable");
          return;
        };
        let debit = Posting.leg(receivable, ?a.subledger, #debit, a.currency, r.interest);
        let credit = Posting.leg(receivable, null, #credit, a.currency, r.interest);
        let input = Posting.simple("instalment-due", [Nat.toText(a.id), Nat.toText(r.number), Nat.toText(day)], debit, credit, day, day, period, "instalment " # Nat.toText(r.number) # " due");
        switch (batchPost(js, jb, journalCaller, now, acc, input)) {
          case (?why) fail(acc, index, item.job, Nat.toText(a.id), why);
          case null {
            record(acc, #batch(#instalmentDue({ account = a.id; day; instalment = r.number; interest = r.interest; principal = r.principal })));
          };
        };
      };
    };
  };

  // ─── job 4: arrears ageing ────────────────────────────────────────────────

  /// The band recomputed from job 3's result and recorded. Nothing is posted: a band is
  /// a classification, and the posting it implies is job 5's.
  func jobAgeing(
    bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64,
    acc : ChunkAcc, item : Batch.PlanItem, index : Nat, day : ProdT.Day, period : JT.PeriodId, a : ProductCore.AccountEntry,
  ) {
    acc.examined += 1;
    let ?terms = ProductCore.termsOf(bs.product, a) else {
      fail(acc, index, item.job, Nat.toText(a.id), "the account's product version is gone");
      return;
    };
    let ?sv = ProductCore.schedule(bs.product, productBlocks(bb), a) else { acc.zeroMovement += 1; return };
    let repaid = loanRepaid(js, a, terms, day);
    let arr = Loans.arrears(sv.rows, repaid, day);
    record(acc, #batch(#loanAged({
      account = a.id; day; band = Loans.band(terms, arr);
      overdueDays = arr.overdueDays; overdueTotal = arr.overdueTotal;
      instalmentsOverdue = arr.instalmentsOverdue;
    })));
    if (arr.overdueTotal == 0) acc.zeroMovement += 1;
    // ── the exposure's stage (collections and recovery): derived from the days past due under the recorded policy; a block only
    // when it moves. A cure out of a suspending stage releases the interest held in suspense to income.
    switch (CollectionsCore.policy(bs.collections)) {
      case null {};
      case (?pol) {
        let before = CollectionsCore.row(bs.collections, a.id);
        switch (CollectionsCore.transitionFor(bs.collections, a.id, arr.overdueDays, day, 0)) {
          case null {};
          case (?ev) {
            record(acc, #collections(ev));
            switch (before, ev) {
              case (?r, #stageDerived(x)) {
                if (r.suspenseHeld > 0 and CollectionsCore.suspends(pol, r.stage) and not CollectionsCore.suspends(pol, x.to)) {
                  releaseSuspense(bs, js, jb, journalCaller, now, acc, index, item.job, terms, a, r.suspenseHeld, day, period);
                };
              };
              case (_, _) {};
            };
          };
        };
        // a promise that fell due before today is judged against the repayments since it was made
        switch (CollectionsCore.duePromise(bs.collections, a.id, day)) {
          case (?p) record(acc, #collections(#promiseJudged({ account = a.id; amount = p.amount; by = p.by; kept = CollectionsCore.judgePromise(p, repaid); day })));
          case null {};
        };
      };
    };
  };

  /// Interest held in suspense while an exposure was in default returns to income on its cure (collections and recovery).
  func releaseSuspense(
    bs : State, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64, acc : ChunkAcc, index : Nat, job : Batch.Job,
    terms : ProdT.ProductTerms, a : ProductCore.AccountEntry, amount : Nat, day : ProdT.Day, period : JT.PeriodId,
  ) {
    ignore bs;
    let ?suspense = Products.roleAccount(terms, #suspense) else { fail(acc, index, job, Nat.toText(a.id), "the product maps no suspense account"); return };
    let ?income = Products.roleAccount(terms, #interestIncome) else { fail(acc, index, job, Nat.toText(a.id), "the product maps no interest income"); return };
    let legs = [Posting.leg(suspense, ?a.subledger, #debit, a.currency, amount), Posting.leg(income, null, #credit, a.currency, amount)];
    batchLegs(js, jb, journalCaller, now, acc, index, job, Nat.toText(a.id), "suspense-release", [Nat.toText(a.id), Nat.toText(day)], legs, day, period, "interest in suspense released on cure");
    record(acc, #collections(#suspenseReleased({ account = a.id; amount; day })));
  };

  // ─── job 5: provision staging ─────────────────────────────────────────────

  /// The allowance movement implied by job 4's band, from the declared parameters. The
  /// engine computes and posts; it estimates nothing.
  func jobProvision(
    bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64,
    acc : ChunkAcc, item : Batch.PlanItem, index : Nat, day : ProdT.Day, period : JT.PeriodId,
    a : ProductCore.AccountEntry,
  ) {
    acc.examined += 1;
    let ?terms = ProductCore.termsOf(bs.product, a) else {
      fail(acc, index, item.job, Nat.toText(a.id), "the account's product version is gone");
      return;
    };
    let ?sv = ProductCore.schedule(bs.product, productBlocks(bb), a) else { acc.zeroMovement += 1; return };
    let outstanding = loanOutstanding(js, a, terms, day);
    let exposure = Loans.allocationTotal(outstanding);
    let arr = Loans.arrears(sv.rows, loanRepaid(js, a, terms, day), day);
    let req = Loans.requiredProvision(terms, arr, exposure, terms.rounding);
    let ?allowance = Products.roleAccount(terms, #allowance) else {
      fail(acc, index, item.job, Nat.toText(a.id), "the product maps no allowance");
      return;
    };
    let ?expense = Products.roleAccount(terms, #impairmentExpense) else {
      fail(acc, index, item.job, Nat.toText(a.id), "the product maps no impairment expense");
      return;
    };
    let carried = Posting.accountBalanceOn(js, allowance, a.subledger, a.currency, #credit, day).net;
    record(acc, #product(#provisionSet({ account = a.id; band = req.band; stage = req.stage; required = req.amount; previous = carried })));
    switch (Loans.provisionMovement(carried, req.amount)) {
      case (#unchanged) { acc.zeroMovement += 1 };
      case (#increase(n)) {
        let legs = [
          Posting.leg(expense, null, #debit, a.currency, n),
          Posting.leg(allowance, ?a.subledger, #credit, a.currency, n),
        ];
        batchLegs(js, jb, journalCaller, now, acc, index, item.job, Nat.toText(a.id), "provision", [Nat.toText(a.id), Nat.toText(day)], legs, day, period, "end-of-day provision");
      };
      case (#release(n)) {
        let legs = [
          Posting.leg(allowance, ?a.subledger, #debit, a.currency, n),
          Posting.leg(expense, null, #credit, a.currency, n),
        ];
        batchLegs(js, jb, journalCaller, now, acc, index, item.job, Nat.toText(a.id), "provision-release", [Nat.toText(a.id), Nat.toText(day)], legs, day, period, "end-of-day provision release");
      };
    };
  };

  func batchLegs(
    js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64, acc : ChunkAcc,
    index : Nat, job : Batch.Job, entity : Text, purpose : Text, parts : [Text],
    legs : [JT.Leg], day : ProdT.Day, period : JT.PeriodId, narration : Text,
  ) {
    if (not Posting.balances(legs)) {
      fail(acc, index, job, entity, purpose # ": the generated legs do not balance");
      return;
    };
    let input : JT.PostingInput = {
      idempotencyKey = Posting.key(purpose, parts);
      postingDate = day; valueDate = day; period; legs;
      sourceRef = { kind = purpose; id = Text.join(parts.vals(), "/") };
      narration;
      correctionOf = null;
    };
    switch (batchPost(js, jb, journalCaller, now, acc, input)) {
      case (?why) fail(acc, index, job, entity, why);
      case null {};
    };
  };

  // ─── job 6: term deposit maturity ─────────────────────────────────────────

  /// A deposit maturing on the date has its entitlement moved into the depositor's own
  /// sub-ledger under the payable control, so "what has been credited" is a balance
  /// rather than a derivation when the deposit is redeemed.
  func jobMaturity(
    bs : State, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64,
    acc : ChunkAcc, item : Batch.PlanItem, index : Nat, day : ProdT.Day, period : JT.PeriodId,
    a : ProductCore.AccountEntry,
  ) {
    acc.examined += 1;
    if (a.maturity != ?day) { acc.zeroMovement += 1; return };
    let ?terms = ProductCore.termsOf(bs.product, a) else {
      fail(acc, index, item.job, Nat.toText(a.id), "the account's product version is gone");
      return;
    };
    let ?it = terms.interest else { acc.zeroMovement += 1; return };
    let ?rate = a.openingRate else {
      fail(acc, index, item.job, Nat.toText(a.id), "the account carries no opening rate");
      return;
    };
    let ?payable = Products.roleAccount(terms, #interestPayable) else {
      fail(acc, index, item.job, Nat.toText(a.id), "the product maps no interest payable");
      return;
    };
    let principal = Posting.accountBalanceOn(js, terms.control, a.subledger, a.currency, #credit, day).net;
    if (principal == 0) { acc.zeroMovement += 1; return };
    let credited = Posting.accountBalanceOn(js, payable, a.subledger, a.currency, #credit, day).net;
    let m = TermProducts.maturityValue(principal, rate, it, terms.rounding, a.opened, day);
    if (m.interest <= credited) {
      record(acc, #batch(#depositMatured({ account = a.id; day; entitled = m.interest })));
      acc.zeroMovement += 1;
      return;
    };
    let movement = m.interest - credited;
    let legs = [
      Posting.leg(payable, null, #debit, a.currency, movement),
      Posting.leg(payable, ?a.subledger, #credit, a.currency, movement),
    ];
    batchLegs(js, jb, journalCaller, now, acc, index, item.job, Nat.toText(a.id), "maturity", [Nat.toText(a.id), Nat.toText(day)], legs, day, period, "deposit matured");
    record(acc, #batch(#depositMatured({ account = a.id; day; entitled = m.interest })));
  };

  // ─── job 7: standing instructions ─────────────────────────────────────────

  /// Recurring transfers due on the date. An instruction that fails for insufficient
  /// funds is a recorded failure with the declared retry policy, never a silent skip.
  func jobInstructions(
    bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64,
    acc : ChunkAcc, run : BatchCore.RunEntry, item : Batch.PlanItem, index : Nat,
    day : ProdT.Day, period : JT.PeriodId, only : ?Text,
  ) {
    let all = BatchCore.instructionsOf(bs.batch, run.book);
    let sorted = Array.sort<BatchCore.InstructionEntry>(all, func(x, y) { Text.compare(x.instruction.id, y.instruction.id) });
    // half-open, as above
    var i = item.from;
    label work while (i < item.to and i >= 1 and i <= sorted.size()) {
      let si = sorted[i - 1].instruction;
      let mine = switch (only) { case null true; case (?e) Text.equal(e, si.id) };
      if (not mine) { i += 1; continue work };
      acc.examined += 1;
      if (not BT.dueOn(si, day)) { acc.zeroMovement += 1 }
      else {
        switch (requireAccount(bs, bb, si.from), requireAccount(bs, bb, si.to)) {
          case (#ok((fromA, fromTerms)), #ok((toA, toTerms))) {
            let legs = [
              Posting.leg(fromTerms.control, ?fromA.subledger, #debit, si.currency, si.amount),
              Posting.leg(toTerms.control, ?toA.subledger, #credit, si.currency, si.amount),
            ];
            let input : JT.PostingInput = {
              idempotencyKey = Posting.key("standing-instruction", [si.id, Nat.toText(day)]);
              postingDate = day; valueDate = day; period; legs;
              sourceRef = { kind = "standing-instruction"; id = si.id };
              narration = si.narration;
              correctionOf = null;
            };
            switch (batchPost(js, jb, journalCaller, now, acc, input)) {
              case (?why) fail(acc, index, item.job, si.id, why);
              case null record(acc, #batch(#standingInstructionExecuted({ id = si.id; day; amount = si.amount })));
            };
          };
          case (_, _) fail(acc, index, item.job, si.id, "an account the instruction names no longer exists");
        };
      };
      i += 1;
    };
  };

  // ─── job 8: the statement cut ─────────────────────────────────────────────

  /// The per-account statement data for the date, **recorded** rather than re-derived,
  /// so a statement stays reproducible after later back-valued activity is admitted.
  func jobStatement(
    bs : State, js : JCore.State, acc : ChunkAcc, item : Batch.PlanItem, index : Nat,
    day : ProdT.Day, a : ProductCore.AccountEntry,
  ) {
    acc.examined += 1;
    let ?terms = ProductCore.termsOf(bs.product, a) else {
      fail(acc, index, item.job, Nat.toText(a.id), "the account's product version is gone");
      return;
    };
    let opening = if (day == 0) { { debits = 0; credits = 0 } }
      else JCore.valueDatedBalance(js, terms.control, ?a.subledger, a.currency, day - 1);
    let closing = JCore.valueDatedBalance(js, terms.control, ?a.subledger, a.currency, day);
    let movements = (closing.debits - opening.debits) + (closing.credits - opening.credits);
    record(acc, #batch(#statementCutRecorded({ cut = {
      account = a.id; day; currency = a.currency;
      openingDebits = opening.debits; openingCredits = opening.credits;
      closingDebits = closing.debits; closingCredits = closing.credits;
      movements;
    } })));
    if (movements == 0) acc.zeroMovement += 1;
  };

  // ─── job 10: monitoring ───────────────────────────────────────────────────

  /// The window rules over one account for the date, as alerts. A refusal — a rule too wide for
  /// its declared bound on this account — is a recorded failure of the item, retried by the
  /// book's policy and parked, so an evaluation that did not run is never mistaken for one that
  /// found nothing. An alert already open for the same finding is not opened again.
  func jobMonitoring(bs : State, acc : ChunkAcc, item : Batch.PlanItem, index : Nat, day : ProdT.Day, a : ProductCore.AccountEntry) {
    acc.examined += 1;
    switch (acc.recorder.monitor(a.id, day)) {
      case (#err(e)) fail(acc, index, item.job, Nat.toText(a.id), debug_show (e));
      case (#ok(findings)) {
        if (findings.size() == 0) acc.zeroMovement += 1;
        for (f in findings.vals()) {
          switch (alertFor(bs, f, #endOfDay)) { case (?ev) record(acc, ev); case null {} };
        };
      };
    };
  };

  // ─── job 9: the till check ────────────────────────────────────────────────

  /// A till left unsettled at close is a recorded failure, which blocks the period
  /// close. A drawer nobody counted is not a thing to discover next month.
  func jobTillCheck(
    bs : State, bb : Blocks, js : JCore.State, acc : ChunkAcc, item : Batch.PlanItem, index : Nat,
    day : ProdT.Day, book : Text, only : ?Text,
  ) {
    for (t in ProductCore.listTills(bs.product, productBlocks(bb)).vals()) {
      let mine = switch (only) { case null true; case (?e) Text.equal(e, t.id) };
      if (mine and Text.equal(t.book, book) and t.status != #closed) {
        acc.examined += 1;
        if (t.status == #open) {
          let held = switch (ProductCore.currentVersion(bs.product, t.product)) {
            case (?v) Till.bookBalance(js, v.terms.control, t.subledger, t.currency, day);
            case null 0;
          };
          fail(acc, index, item.job, t.id, "the till was not settled at close and holds " # Nat.toText(held));
        } else acc.zeroMovement += 1;
      };
    };
  };

  /// Job 11 (origination and underwriting): every credit offer of the book still standing is examined; one whose validity ended
  /// before the date lapses, as a block. A retry names the one application.
  func jobOfferExpiry(bs : State, acc : ChunkAcc, item : Batch.PlanItem, index : Nat, day : ProdT.Day, book : Text, only : ?Text) {
    for (id in OriginationCore.offeredInBookIds(bs.origination, book).vals()) {
      let mine = switch (only) { case null true; case (?e) Text.equal(e, Nat.toText(id)) };
      if (mine) {
        acc.examined += 1;
        switch (OriginationCore.row(bs.origination, id)) {
          case (?r) {
            switch (r.offer) {
              case (?o) { if (o.expiresAt < day) record(acc, #origination(#offerExpired({ application = id; day }))) else acc.zeroMovement += 1 };
              case null acc.zeroMovement += 1;
            };
          };
          case null fail(acc, index, item.job, Nat.toText(id), "the application's row is gone");
        };
      };
    };
  };

  /// The business date of the book's latest end-of-day run before `day`, or the day before when there is none.
  func previousRunDay(bs : State, book : Text, day : Nat) : Nat {
    var prev = 0;
    for (run in BatchCore.listRuns(bs.batch).vals()) { if (Text.equal(run.book, book) and run.businessDate < day and run.businessDate > prev) prev := run.businessDate };
    if (prev == 0) day - 1 else prev
  };

  /// Job 12 (corporate lending): every facility of the book not yet closed is examined. A revolver's commitment fee accrues on
  /// the undrawn amount for the day (the product's day count, or ACT/365F; the product's rounding), an operating
  /// lease's income straight-line, a factoring facility's discount straight-line to each receivable's maturity —
  /// each as a posting and a block only when the figure is not zero. A clean-down window that ends today is judged
  /// from the journal's balances day by day; a review due and not held is flagged once; a floating drawing at its
  /// reset day is re-priced to the fixing plus the spread when the rate moves. A retry names the one facility.
  func jobFacilities(
    bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64,
    acc : ChunkAcc, item : Batch.PlanItem, index : Nat, day : ProdT.Day, period : JT.PeriodId, book : Text, only : ?Text,
  ) {
    for (fid in FacilityCore.openInBook(bs.facility, book).vals()) {
      let mine = switch (only) { case null true; case (?e) Text.equal(e, Nat.toText(fid)) };
      if (not mine) continue;
      acc.examined += 1;
      let ?r = FacilityCore.row(bs.facility, fid) else { fail(acc, index, item.job, Nat.toText(fid), "the facility's row is gone"); continue };
      let ?terms = facilityTerms(bs, r) else { fail(acc, index, item.job, Nat.toText(fid), "the facility's product is gone"); continue };
      let convention : DC.Convention = switch (terms.interest) { case (?it) it.convention; case null #a004_Act365Fixed };
      var moved = false;
      let sub = facilitySub(fid);
      func postPair(kind : Text, debit : JT.Leg, credit : JT.Leg, narration : Text) : Bool {
        let input = Posting.simple(kind, [Nat.toText(fid), Nat.toText(day)], debit, credit, day, day, period, narration);
        switch (batchPost(js, jb, journalCaller, now, acc, input)) { case (?why) { fail(acc, index, item.job, Nat.toText(fid), why); false }; case null true }
      };
      switch (r.kind) {
        case (#revolving(rv)) {
          if (r.stage != #closed and day >= r.availabilityFrom and day <= r.availabilityTo and rv.commitmentFeeBps > 0) {
            let drawn = facilityDrawn(bs, bb, js, fid, day);
            let undrawn = if (r.limit > drawn) r.limit - drawn else 0;
            // since the book's previous run (the day before when there is none): the rest days between two runs accrue too
            let from = Nat.max(previousRunDay(bs, book, day), r.availabilityFrom);
            let fee = if (from >= day) 0 else (I.round(I.periodAccrual(undrawn, { numerator = rv.commitmentFeeBps; denominator = 10_000; negative = false }, convention, from, day), terms.rounding)).amount;
            if (fee > 0) {
              switch (Products.roleAccount(terms, #feeReceivable), Products.roleAccount(terms, #feeIncome)) {
                case (?recv, ?inc) {
                  if (postPair("commitment-fee", Posting.leg(recv, ?sub, #debit, r.currency, fee), Posting.leg(inc, ?sub, #credit, r.currency, fee), "commitment fee on the undrawn amount")) {
                    record(acc, #facility(#commitmentFeeAccrued({ facility = fid; day; undrawn; amount = fee }))); moved := true;
                  };
                };
                case (_, _) fail(acc, index, item.job, Nat.toText(fid), "the fee roles are not mapped");
              };
            };
          };
          // the clean-down window ending today: the days the facility stood undrawn, read from the journal
          switch (rv.cleanDown) {
            case (?cd) {
              if (day >= r.cleanWindowStart + cd.everyDays) {
                var clean = 0;
                var d0 = r.cleanWindowStart + 1;
                while (d0 <= r.cleanWindowStart + cd.everyDays) { if (facilityDrawn(bs, bb, js, fid, d0) == 0) clean += 1; d0 += 1 };
                record(acc, #facility(#cleanDownJudged({ facility = fid; windowEnd = r.cleanWindowStart + cd.everyDays; cleanDays = clean; required = cd.forDays; met = FacilityCore.cleanDownMet(clean, cd.forDays) })));
                moved := true;
              };
            };
            case null {};
          };
        };
        case (#operatingLease(ol)) {
          let start = r.availabilityFrom;
          let termDays = ol.periods * ProdT.periodDays(ol.every);
          let total = ol.rentalPerPeriod * ol.periods;
          if (day > start) {
            switch (Products.roleAccount(terms, #rentReceivable), Products.roleAccount(terms, #rentalIncome)) {
              case (?recv, ?inc) {
                let recognised = Posting.accountBalanceOn(js, inc, sub, r.currency, #credit, day).net;
                let cumulative = FacilityCore.straightLine(total, termDays, day - start);
                if (cumulative > recognised) {
                  let amount = cumulative - recognised;
                  if (postPair("rental-income", Posting.leg(recv, ?sub, #debit, r.currency, amount), Posting.leg(inc, ?sub, #credit, r.currency, amount), "rental income straight-line")) {
                    record(acc, #facility(#leaseRentalAccrued({ facility = fid; day; amount }))); moved := true;
                  };
                };
              };
              case (_, _) fail(acc, index, item.job, Nat.toText(fid), "the lease roles are not mapped");
            };
          };
        };
        case (#factoring(_) or #forfaiting(_)) {
          let items = List.empty<(Blob, Nat)>();
          var total = 0;
          for (rec in FacilityCore.receivablesOf(bs.facility, fid).vals()) {
            if (rec.status == #open) {
              let cumulative = FacilityCore.straightLine(rec.discount, if (rec.due > rec.purchased) rec.due - rec.purchased else 0, if (day > rec.purchased) day - rec.purchased else 0);
              if (cumulative > rec.recognised) { let delta = cumulative - rec.recognised; List.add(items, (rec.ref, delta)); total += delta };
            };
          };
          if (total > 0) {
            switch (Products.roleAccount(terms, #unearnedDiscount), Products.roleAccount(terms, #discountIncome)) {
              case (?unearned, ?inc) {
                if (postPair("discount-unwind", Posting.leg(unearned, ?sub, #debit, r.currency, total), Posting.leg(inc, ?sub, #credit, r.currency, total), "discount earned to date")) {
                  record(acc, #facility(#discountUnwound({ facility = fid; day; amount = total; items = List.toArray(items) }))); moved := true;
                };
              };
              case (_, _) fail(acc, index, item.job, Nat.toText(fid), "the discount roles are not mapped");
            };
          };
        };
        case (_) {};
      };
      // a floating drawing at its reset: re-priced to the fixing plus the spread when the rate moves
      switch (r.pricing) {
        case (#floating(fl)) {
          for ((acct, open) in FacilityCore.drawingsOf(bs.facility, fid).vals()) {
            if (open) {
              switch (ProductCore.get(bs.product, productBlocks(bb), acct)) {
                case (?a) {
                  switch (a.disbursed) {
                    case (?since) {
                      if (day > since and (day - since) % fl.resetDays == 0) {
                        switch (FacilityCore.rateFor(bs.facility, r, day)) {
                          case (#err(_)) fail(acc, index, item.job, Nat.toText(fid), "no fixing of " # fl.index # " for the reset");
                          case (#ok(pr)) {
                            let rate : I.Rate = { numerator = pr.rateBps; denominator = 10_000; negative = false };
                            if (a.openingRate != ?rate) {
                              switch (ProductCore.schedule(bs.product, productBlocks(bb), a), terms.schedule) {
                                case (?current, ?sch) {
                                  var remaining = 0;
                                  for (row in current.rows.vals()) { if (row.dueDate >= day) remaining += 1 };
                                  if (remaining > 0) {
                                    switch (reschedulePlan(bs, bb, js, journalCaller, now, "reset-" # Nat.toText(fid), acct, day, ({ sch with instalments = remaining; moratoriumDays = 0 } : ProdT.ScheduleTerms), rate, false)) {
                                      case (#err(e)) fail(acc, index, item.job, Nat.toText(fid), debug_show (e));
                                      case (#ok(plan)) {
                                        switch (plan.bankEvent) { case (?ev) record(acc, ev); case null {} };
                                        for (ev in plan.extra.vals()) record(acc, ev);
                                        record(acc, #facility(#drawingRepriced({ facility = fid; account = acct; day; rateBps = pr.rateBps; fixing = pr.fixing })));
                                        moved := true;
                                      };
                                    };
                                  };
                                };
                                case (_, _) {};
                              };
                            };
                          };
                        };
                      };
                    };
                    case null {};
                  };
                };
                case null {};
              };
            };
          };
        };
        case (#fixed(_)) {};
      };
      // a review due and not held, flagged once
      switch (r.nextReview) {
        case (?due) { if (due < day and not r.reviewFlagged) { record(acc, #facility(#reviewOverdue({ facility = fid; due; day }))); moved := true } };
        case null {};
      };
      if (not moved) acc.zeroMovement += 1;
    };
  };

  /// The open period a day falls in, if any.
  func periodForDay(js : JCore.State, day : ProdT.Day) : ?JT.PeriodId {
    for (p in JCore.listPeriods(js).vals()) {
      if (p.status == #open and day >= p.start and day <= p.end) return ?p.id;
    };
    null
  };

  func journalConfig(r : Result.Result<JT.Event, JT.ConfigError>) : Result.Result<Plan, T.BankError> {
    switch (r) {
      case (#err(e)) #err(#JournalConfigError({ error = e }));
      case (#ok(e)) #ok({ bankEvent = null; extra = []; journal = [#event(e)] });
    }
  };

  func requireParty(bs : State, id : PT.PartyId) : ?T.BankError {
    if (PartyCore.exists(bs.party, id)) null else ?#PartyError({ error = #UnknownParty({ party = id }) })
  };

  /// Does this party still hold money anywhere? Read from the journal through the
  /// identifiers issued to it, never from a cached figure.
  func partyHasBalance(bs : State, bb : Blocks, js : JCore.State, id : PT.PartyId) : ?T.BankError {
    let ?p = PartyCore.get(bs.party, partyBlocks(bb), id) else return ?#PartyError({ error = #UnknownParty({ party = id }) });
    for (identifier in p.identifiers.vals()) {
      let key = Text.encodeUtf8(identifier);
      for (b in JCore.allBalances(js).vals()) {
        switch (b.subledger) {
          case (?sub) {
            if (sub == key) {
              let net = if (b.creditsPosted > b.debitsPosted) b.creditsPosted - b.debitsPosted else b.debitsPosted - b.creditsPosted;
              if (net != 0 or b.debitsPending != 0 or b.creditsPending != 0) {
                return ?#PartyError({ error = #PartyHasBalance({ party = id; account = b.account; currency = b.currency; debits = b.debitsPosted + b.debitsPending; credits = b.creditsPosted + b.creditsPending }) });
              };
            };
          };
          case null {};
        };
      };
    };
    null
  };

  /// A bureau's report on an application, arriving by the bureau connector's call: the signature over the
  /// report's canonical bytes is judged under the key the policy registers for the bureau, and the report
  /// is the block; a report that does not verify is refused and nothing is recorded.
  public func planBureauReport(bs : State, application : OT.ApplicationId, report : OT.BureauReport, signature : Blob, verify : Verify) : Result.Result<T.Event, T.BankError> {
    switch (OriginationCore.planRecordBureau(bs.origination, application, report, signature, verify)) {
      case (#err(e)) #err(#OriginationError({ error = e }));
      case (#ok(ev)) #ok(#origination(ev));
    }
  };


  /// The trade book's commands (trade finance), planned apart from the main switch so that switch stays under the chain's
  /// function-complexity bound.
  func planTradeInner(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, command : T.Command, authorityIndex : Nat, authId : Text) : Result.Result<Plan, T.BankError> {
    switch (command) {
      // ── trade finance (trade finance) ──
      case (#setTradePolicy(pol)) {
        for (code in tradeAccounts(pol).vals()) {
          switch (JCore.getAccount(js, code)) { case null return #err(#ProductError({ error = #RoleAccountUnknown({ role = "trade policy"; account = code }) })); case (?_) {} };
        };
        switch (ProductCore.currentVersion(bs.product, pol.claimProduct)) { case null return #err(#ProductError({ error = #UnknownProduct({ product = pol.claimProduct }) })); case (?_) {} };
        tradePlan(TradeCore.planPolicy(pol))
      };
      case (#issueLetterOfCredit(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let today = JCore.effectiveToday(js, now);
        let (party, account) = TradeCore.ours(x.lc.applicant);
        switch (requireParty(bs, party)) { case (?e) return #err(e); case null {} };
        let (a, _) = switch (requireAccount(bs, bb, account)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        if (a.party != party) return tradeErr(#InvalidTerms({ reason = "account " # Nat.toText(account) # " is not the party's"; article = "policy" }));
        switch (x.lc.facility) { case (?f) { switch (facilityRoom(bs, bb, js, f, x.currency, x.amount, x.valueDate)) { case (?e) return #err(e); case null {} } }; case null {} };
        let ev = switch (TradeCore.planIssueLc(bs.trade, x.lc, x.amount, x.currency, x.expiry, x.placeOfExpiry, a.book, today)) { case (#err(e)) return tradeErr(e); case (#ok(ev)) ev };
        let #lcIssued(i) = ev else return tradeErr(#InvalidTerms({ reason = "not an issue"; article = "" }));
        let valueDate = switch (tradeValueDate(bs, bb, js, a.book, account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let legs = switch (issueLegs(bs, bb, js, pol, ?pol.contingentLcs, account, x.currency, x.amount, i.margin, i.commission, bs.height, valueDate)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        tradePost(js, journalCaller, now, "lc-issue", [authId, x.lc.reference], legs, x.postingDate, valueDate, x.period, x.narration, ev, [])
      };
      case (#adviseLetterOfCredit(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let today = JCore.effectiveToday(js, now);
        switch (requireParty(bs, x.beneficiary)) { case (?e) return #err(e); case null {} };
        let (a, _) = switch (requireAccount(bs, bb, x.beneficiaryAccount)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        if (a.party != x.beneficiary) return tradeErr(#InvalidTerms({ reason = "account " # Nat.toText(x.beneficiaryAccount) # " is not the party\'s"; article = "policy" }));
        func mu(c : Text) : ?Nat8 { minorUnitsOfCurrency(js, c) };
        let parsed = switch (TradeMessages.parseMt700(x.message, mu, x.checklist)) { case (#err(why)) return tradeErr(#BadMessage({ reason = why })); case (#ok(p)) p };
        if (not Text.equal(parsed.currency, a.currency)) return #err(#ProductError({ error = #CurrencyMismatch({ expected = a.currency; actual = parsed.currency }) }));
        if (x.confirm and not parsed.confirmationAsked) return tradeErr(#MessageMismatch({ reason = "the credit does not ask for confirmation (field 49)" }));
        let lc : TrT.LetterOfCredit = {
          role = if (x.confirm) #confirming else #advising; applicant = parsed.applicant; beneficiary = #party({ party = x.beneficiary; account = x.beneficiaryAccount });
          counterpartyBank = parsed.issuingBank; terms = parsed.terms; tolerance = parsed.tolerance; marginBps = 0; facility = x.facility; commissionBps = x.commissionBps; reference = parsed.reference;
        };
        switch (x.facility) { case (?f) { if (x.confirm) { switch (facilityRoom(bs, bb, js, f, parsed.currency, parsed.amount, x.valueDate)) { case (?e) return #err(e); case null {} } } }; case null {} };
        let hash = Sha256.fromBlob(#sha256, Text.encodeUtf8(x.message));
        let ev = switch (TradeCore.planAdviseLc(bs.trade, lc, parsed.amount, parsed.currency, parsed.expiry, parsed.placeOfExpiry, hash, x.confirm, a.book, today)) { case (#err(e)) return tradeErr(e); case (#ok(ev)) ev };
        let #lcAdvised(i) = ev else return tradeErr(#InvalidTerms({ reason = "not an advice"; article = "" }));
        let valueDate = switch (tradeValueDate(bs, bb, js, a.book, x.beneficiaryAccount, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let legs = switch (issueLegs(bs, bb, js, pol, if (x.confirm) ?pol.contingentLcs else null, x.beneficiaryAccount, parsed.currency, parsed.amount, 0, i.commission, bs.height, valueDate)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        tradePost(js, journalCaller, now, "lc-advise", [authId, parsed.reference], legs, x.postingDate, valueDate, x.period, x.narration, ev, [])
      };
      case (#amendLetterOfCredit(x) or #amendGuarantee(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let today = JCore.effectiveToday(js, now);
        let r = switch (tradeRow(bs, x.instrument)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        switch (command, r.kind) { case (#amendLetterOfCredit(_), 1) {}; case (#amendGuarantee(_), 2) {}; case (_, k) return tradeErr(#WrongKind({ instrument = x.instrument; kind = if (k == 1) "letterOfCredit" else if (k == 2) "guarantee" else "other"; wanted = if (r.kind == 1) "guarantee" else "letterOfCredit" })) };
        let ev = switch (TradeCore.planAmend(bs.trade, x.instrument, x.amendment, today)) { case (#err(e)) return tradeErr(e); case (#ok(ev)) ev };
        let newAmount = switch (x.amendment.amount) { case (?a) a; case null r.amount };
        // an increase against a facility needs the room; the memorandum moves by the change in the outstanding
        switch (r.facility) { case (?f) { if (newAmount > r.amount) { switch (facilityRoom(bs, bb, js, f, r.currency, newAmount - r.amount, x.valueDate)) { case (?e) return #err(e); case null {} } } }; case null {} };
        let legs = switch (memoAccount(pol, r)) {
          case (?m) { if (newAmount > r.amount) memoLegs(pol, m, r.currency, newAmount - r.amount, true) else memoLegs(pol, m, r.currency, r.amount - newAmount, false) };
          case null [];
        };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        tradePost(js, journalCaller, now, "trade-amend", [authId, Nat.toText(x.instrument)], legs, x.postingDate, valueDate, x.period, x.narration, ev, [])
      };
      case (#presentDocuments(x)) {
        let today = JCore.effectiveToday(js, now);
        let lc = switch (lcTerms(bb, x.instrument)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        tradePlan(TradeCore.planPresent(bs.trade, JCore.calendar(js), x.instrument, lc.terms, x.documents, x.amount, x.shipmentDate, x.presentedOn, today))
      };
      case (#examinePresentation(x)) {
        let today = JCore.effectiveToday(js, now);
        let lc = switch (lcTerms(bb, x.instrument)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        tradePlan(TradeCore.planExamine(bs.trade, x.instrument, x.claim, checklistOf(lc.terms), x.checks, x.decision, today))
      };
      case (#waiveDiscrepancies(x)) tradePlan(TradeCore.planWaive(bs.trade, x.instrument, x.claim, x.applicantConsentHash, JCore.effectiveToday(js, now)));
      case (#honourPresentation(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let today = JCore.effectiveToday(js, now);
        let r = switch (tradeRow(bs, x.instrument)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let lc = switch (lcTerms(bb, x.instrument)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        let ev = switch (TradeCore.planHonour(bs.trade, x.instrument, x.claim, lc.terms.availableBy, x.honour, today)) { case (#err(e)) return tradeErr(e); case (#ok(ev)) ev };
        let #presentationHonoured(h) = ev else return tradeErr(#InvalidTerms({ reason = "not an honour"; article = "" }));
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let legs = List.empty<JT.Leg>();
        let extra : [T.Event] = [];
        var fromMargin = 0;
        let sub = TradeCore.acceptanceSub(x.instrument, x.claim);
        switch (x.honour) {
          case (#sight) {
            // paid now: to the beneficiary, from the margin then the applicant (issuing) — or from the correspondent
            // account when we pay as the confirming or advising bank
            let sink = switch (counterpartyLeg(bs, bb, js, pol, lc.beneficiary, #credit, r.currency, h.amount, valueDate)) { case (#err(e)) return #err(e); case (#ok(l)) l };
            if (lc.role == #issuing) {
              let paid = switch (payFromCustomer(bs, bb, js, journalCaller, pol, r, h.amount, sink, valueDate, authorityIndex, false)) { case (#err(e)) return #err(e); case (#ok(p)) p };
              for (l in paid.legs.vals()) List.add(legs, l);
              fromMargin := paid.fromMargin;
            } else {
              List.add(legs, Posting.leg(pol.nostro, null, #debit, r.currency, h.amount)); List.add(legs, sink);
            };
          };
          case (#deferred(_) or #acceptance(_)) {
            // the undertaking to pay at maturity: the applicant's liability to us against our acceptance payable
            let liable = if (lc.role == #issuing) pol.customersLiabilityAcceptances else pol.nostro;
            List.add(legs, Posting.leg(liable, if (lc.role == #issuing) ?sub else null, #debit, r.currency, h.amount));
            List.add(legs, Posting.leg(pol.acceptancesPayable, ?sub, #credit, r.currency, h.amount));
          };
          case (#negotiation(_)) {
            // documents bought: the beneficiary paid now, the issuing bank's reimbursement due
            let sink = switch (counterpartyLeg(bs, bb, js, pol, lc.beneficiary, #credit, r.currency, h.amount, valueDate)) { case (#err(e)) return #err(e); case (#ok(l)) l };
            List.add(legs, Posting.leg(pol.billsNegotiated, ?sub, #debit, r.currency, h.amount)); List.add(legs, sink);
          };
        };
        switch (memoAccount(pol, r)) { case (?m) { for (l in memoLegs(pol, m, r.currency, h.amount, false).vals()) List.add(legs, l) }; case null {} };
        tradePost(js, journalCaller, now, "lc-honour", [authId, Nat.toText(x.instrument), Nat.toText(x.claim)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, #presentationHonoured({ h with fromMargin }), extra)
      };
      case (#settleAcceptance(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let today = JCore.effectiveToday(js, now);
        let r = switch (tradeRow(bs, x.instrument)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let lc = switch (lcTerms(bb, x.instrument)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        let ev = switch (TradeCore.planMature(bs.trade, x.instrument, x.claim, today)) { case (#err(e)) return tradeErr(e); case (#ok(ev)) ev };
        let #acceptanceMatured(m) = ev else return tradeErr(#InvalidTerms({ reason = "not a maturity"; article = "" }));
        let ?c = TradeCore.claim(bs.trade, x.instrument, x.claim) else return tradeErr(#UnknownClaim({ instrument = x.instrument; claim = x.claim }));
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        switch (settleAcceptanceLegs(bs, bb, js, journalCaller, pol, r, lc, c, m.amount, valueDate, authorityIndex)) {
          case (#err(e)) #err(e);
          case (#ok(p)) {
            switch (tradePost(js, journalCaller, now, "lc-settle", [authId, Nat.toText(x.instrument), Nat.toText(x.claim)], p.legs, x.postingDate, valueDate, x.period, x.narration, #acceptanceMatured({ m with fromMargin = p.fromMargin }), p.extra)) {
              case (#err(e)) #err(e);
              case (#ok(plan)) #ok({ plan with journal = switch (p.limitEvent) { case (?l) Array.concat<JournalStep>([#event(l)], plan.journal); case null plan.journal } });
            }
          };
        }
      };
      case (#closeLetterOfCredit(x) or #releaseGuarantee(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let today = JCore.effectiveToday(js, now);
        let r = switch (tradeRow(bs, x.instrument)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ev = switch (command) {
          case (#closeLetterOfCredit(_)) { switch (TradeCore.planCloseLc(bs.trade, x.instrument, x.reason, today)) { case (#err(e)) return tradeErr(e); case (#ok(ev)) ev } };
          case (_) { switch (TradeCore.planRelease(bs.trade, x.instrument, x.reason, today)) { case (#err(e)) return tradeErr(e); case (#ok(ev)) ev } };
        };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let legs = switch (endLegs(bs, bb, js, pol, r, valueDate)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        tradePost(js, journalCaller, now, "trade-end", [authId, Nat.toText(x.instrument)], legs, x.postingDate, valueDate, x.period, x.narration, ev, [])
      };
      case (#issueGuarantee(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let today = JCore.effectiveToday(js, now);
        let g = x.guarantee;
        switch (requireParty(bs, g.principal)) { case (?e) return #err(e); case null {} };
        let (a, _) = switch (requireAccount(bs, bb, g.principalAccount)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        if (a.party != g.principal) return tradeErr(#InvalidTerms({ reason = "account " # Nat.toText(g.principalAccount) # " is not the party\'s"; article = "policy" }));
        switch (g.facility) { case (?f) { switch (facilityRoom(bs, bb, js, f, x.currency, x.amount, x.valueDate)) { case (?e) return #err(e); case null {} } }; case null {} };
        let ev = switch (TradeCore.planIssueGuarantee(bs.trade, g, x.wordingText, x.amount, x.currency, x.expiry, a.book, today)) { case (#err(e)) return tradeErr(e); case (#ok(ev)) ev };
        let #guaranteeIssued(i) = ev else return tradeErr(#InvalidTerms({ reason = "not an issue"; article = "" }));
        let valueDate = switch (tradeValueDate(bs, bb, js, a.book, g.principalAccount, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let legs = switch (issueLegs(bs, bb, js, pol, ?pol.contingentGuarantees, g.principalAccount, x.currency, x.amount, i.margin, i.commission, bs.height, valueDate)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        tradePost(js, journalCaller, now, "guarantee-issue", [authId, g.reference], legs, x.postingDate, valueDate, x.period, x.narration, ev, [])
      };
      case (#recordDemand(x)) tradePlan(TradeCore.planDemand(bs.trade, JCore.calendar(js), x.instrument, x.demand, x.amount, x.supportingStatement, x.presentedOn, JCore.effectiveToday(js, now)));
      case (#examineDemand(x)) {
        let r = switch (tradeRow(bs, x.instrument)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        if (r.kind != 2) return tradeErr(#WrongKind({ instrument = x.instrument; kind = if (r.kind == 1) "letterOfCredit" else "other"; wanted = "guarantee" }));
        if (x.checklist.size() == 0) return tradeErr(#InvalidTerms({ reason = "a demand is examined against at least one check"; article = "URDG 758 art. 19" }));
        let cl = Array.map<Text, (TrT.DocumentKind, Text)>(x.checklist, func(c) { (#other("demand"), c) });
        tradePlan(TradeCore.planExamine(bs.trade, x.instrument, x.claim, cl, x.checks, x.decision, JCore.effectiveToday(js, now)))
      };
      case (#payDemand(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let today = JCore.effectiveToday(js, now);
        let r = switch (tradeRow(bs, x.instrument)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let g = switch (guaranteeTerms(bb, x.instrument)) { case (#err(e)) return #err(e); case (#ok(g)) g };
        let c = switch (TradeCore.planPayDemand(bs.trade, x.instrument, x.claim, today)) { case (#err(e)) return tradeErr(e); case (#ok(c)) c };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sink = switch (counterpartyLeg(bs, bb, js, pol, g.beneficiary, #credit, r.currency, c.amount, valueDate)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        let paid = switch (payFromCustomer(bs, bb, js, journalCaller, pol, r, c.amount, sink, valueDate, authorityIndex, true)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let legs = List.empty<JT.Leg>();
        for (l in paid.legs.vals()) List.add(legs, l);
        for (l in memoLegs(pol, pol.contingentGuarantees, r.currency, c.amount, false).vals()) List.add(legs, l);
        let ev : TrT.TradeEvent = #demandPaid({ instrument = x.instrument; claim = x.claim; amount = c.amount; fromMargin = paid.fromMargin; fromAccount = paid.fromAccount; claimAccount = paid.claimAccount; day = today });
        switch (postLegs(js, journalCaller, now, "guarantee-pay", [authId, Nat.toText(x.instrument), Nat.toText(x.claim)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = ?#trade(ev); extra = paid.extra; journal = switch (paid.limitEvent) { case (?l) Array.concat<JournalStep>([#event(l)], plan.journal); case null plan.journal } });
        }
      };
      case (#reduceGuarantee(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (tradeRow(bs, x.instrument)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ev = switch (TradeCore.planReduce(bs.trade, x.instrument, x.to, JCore.effectiveToday(js, now))) { case (#err(e)) return tradeErr(e); case (#ok(ev)) ev };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        tradePost(js, journalCaller, now, "guarantee-reduce", [authId, Nat.toText(x.instrument)], memoLegs(pol, pol.contingentGuarantees, r.currency, r.amount - x.to, false), x.postingDate, valueDate, x.period, x.narration, ev, [])
      };
      case (#registerCollection(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let today = JCore.effectiveToday(js, now);
        let c = x.collection;
        let (party, account) = switch (c.role) { case (#remitting) TradeCore.ours(c.drawer); case (#collecting) TradeCore.ours(c.drawee) };
        switch (requireParty(bs, party)) { case (?e) return #err(e); case null {} };
        let (a, _) = switch (requireAccount(bs, bb, account)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        if (a.party != party) return tradeErr(#InvalidTerms({ reason = "account " # Nat.toText(account) # " is not the party's"; article = "policy" }));
        if (not Text.equal(a.currency, x.currency)) return #err(#ProductError({ error = #CurrencyMismatch({ expected = a.currency; actual = x.currency }) }));
        let ev = switch (TradeCore.planRegisterCollection(bs.trade, c, x.amount, x.currency, a.book, today)) { case (#err(e)) return tradeErr(e); case (#ok(ev)) ev };
        let valueDate = switch (tradeValueDate(bs, bb, js, a.book, account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        tradePost(js, journalCaller, now, "collection-register", [authId, c.reference], memoLegs(pol, pol.contingentCollections, x.currency, x.amount, true), x.postingDate, valueDate, x.period, x.narration, ev, [])
      };
      case (#presentCollection(x)) tradePlan(TradeCore.planPresentCollection(bs.trade, x.instrument, x.presentedOn, JCore.effectiveToday(js, now)));
      case (#acceptCollection(x)) {
        let tenor = switch (tradeKindOf(bb, x.instrument)) { case (?#collection(c)) { switch (c.terms) { case (#DA(t)) t.tenorDays; case (#DP) 0 } }; case (_) 0 };
        tradePlan(TradeCore.planAcceptCollection(bs.trade, x.instrument, tenor, JCore.effectiveToday(js, now)))
      };
      case (#payCollection(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let today = JCore.effectiveToday(js, now);
        let (ev, r) = switch (TradeCore.planPayCollection(bs.trade, x.instrument, today)) { case (#err(e)) return tradeErr(e); case (#ok(p)) p };
        let #collectionPaid(cp) = ev else return tradeErr(#InvalidTerms({ reason = "not a payment"; article = "" }));
        let ?#collection(c) = tradeKindOf(bb, x.instrument) else return tradeErr(#UnknownInstrument({ instrument = x.instrument }));
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        // the drawee pays the face; the drawer receives it less our commission; the collecting and remitting banks
        // settle across the correspondent account
        let legs = List.empty<JT.Leg>();
        switch (counterpartyLeg(bs, bb, js, pol, c.drawee, #debit, r.currency, cp.amount, valueDate)) { case (#err(e)) return #err(e); case (#ok(l)) List.add(legs, l) };
        switch (counterpartyLeg(bs, bb, js, pol, c.drawer, #credit, r.currency, cp.amount - cp.commission, valueDate)) { case (#err(e)) return #err(e); case (#ok(l)) List.add(legs, l) };
        if (cp.commission > 0) List.add(legs, Posting.leg(pol.commissionIncome, null, #credit, r.currency, cp.commission));
        for (l in memoLegs(pol, pol.contingentCollections, r.currency, r.amount, false).vals()) List.add(legs, l);
        tradePost(js, journalCaller, now, "collection-pay", [authId, Nat.toText(x.instrument)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, ev, [])
      };
      case (#protestCollection(x)) tradePlan(TradeCore.planProtest(bs.trade, x.instrument, x.reason, JCore.effectiveToday(js, now)));
      case (#returnCollection(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (tradeRow(bs, x.instrument)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ev = switch (TradeCore.planReturnCollection(bs.trade, x.instrument, x.reason, JCore.effectiveToday(js, now))) { case (#err(e)) return tradeErr(e); case (#ok(ev)) ev };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        tradePost(js, journalCaller, now, "collection-return", [authId, Nat.toText(x.instrument)], memoLegs(pol, pol.contingentCollections, r.currency, TradeCore.outstanding(r), false), x.postingDate, valueDate, x.period, x.narration, ev, [])
      };
      case (#discountBill(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let today = JCore.effectiveToday(js, now);
        let b = x.bill;
        switch (requireParty(bs, b.customer)) { case (?e) return #err(e); case null {} };
        let (a, _) = switch (requireAccount(bs, bb, b.customerAccount)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        if (a.party != b.customer) return tradeErr(#InvalidTerms({ reason = "account " # Nat.toText(b.customerAccount) # " is not the party\'s"; article = "policy" }));
        let ev = switch (TradeCore.planDiscountBill(bs.trade, b, x.face, x.currency, x.maturity, a.book, today)) { case (#err(e)) return tradeErr(e); case (#ok(ev)) ev };
        let #billDiscounted(d) = ev else return tradeErr(#InvalidTerms({ reason = "not a discount"; article = "" }));
        let valueDate = switch (tradeValueDate(bs, bb, js, a.book, b.customerAccount, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(dd)) dd };
        let sub = TradeCore.billSub(bs.height);
        let legs = List.empty<JT.Leg>();
        List.add(legs, Posting.leg(pol.billsDiscounted, ?sub, #debit, x.currency, d.face));
        switch (customerLeg(bs, bb, js, b.customerAccount, #credit, x.currency, d.proceeds, valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) };
        if (d.discount > 0) List.add(legs, Posting.leg(pol.unearnedDiscount, ?sub, #credit, x.currency, d.discount));
        tradePost(js, journalCaller, now, "bill-discount", [authId, b.reference], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, ev, [])
      };
      case (#rediscountBill(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (tradeRow(bs, x.instrument)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ev = switch (TradeCore.planRediscount(bs.trade, x.instrument, x.to, JCore.effectiveToday(js, now))) { case (#err(e)) return tradeErr(e); case (#ok(ev)) ev };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let legs = [Posting.leg(pol.nostro, null, #debit, r.currency, r.amount), Posting.leg(pol.billsRediscounted, ?TradeCore.billSub(x.instrument), #credit, r.currency, r.amount)];
        tradePost(js, journalCaller, now, "bill-rediscount", [authId, Nat.toText(x.instrument)], legs, x.postingDate, valueDate, x.period, x.narration, ev, [])
      };
      case (#settleBill(x) or #dishonourBill(x)) {
        let pol = switch (tradePolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let today = JCore.effectiveToday(js, now);
        let dishonour = switch (command) { case (#dishonourBill(_)) true; case (_) false };
        let (ev, r) = if (dishonour) { switch (TradeCore.planBillDishonoured(bs.trade, x.instrument, today)) { case (#err(e)) return tradeErr(e); case (#ok(p)) p } }
                      else { switch (TradeCore.planBillMatured(bs.trade, x.instrument, today)) { case (#err(e)) return tradeErr(e); case (#ok(p)) p } };
        let ?#bill(b) = tradeKindOf(bb, x.instrument) else return tradeErr(#UnknownInstrument({ instrument = x.instrument }));
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let legs = switch (billEndLegs(bs, bb, js, pol, r, b, dishonour, valueDate)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        tradePost(js, journalCaller, now, if (dishonour) "bill-dishonour" else "bill-settle", [authId, Nat.toText(x.instrument)], legs, x.postingDate, valueDate, x.period, x.narration, ev, [])
      };
      case (#recordTradeMessage(x)) tradePlan(TradeCore.planRecordMessage(bs.trade, x.instrument, x.kind, x.direction, x.hash, JCore.effectiveToday(js, now)));

      case (_) #err(#TradeError({ error = #InvalidTerms({ reason = "not a trade command"; article = "" }) }));
    }
  };

  // ─── Islamic banking (Islamic banking): the planners and their postings ─────────────────

  func islamicPlan(r : Result.Result<IT.IslamicEvent, IT.IslamicError>) : Result.Result<Plan, T.BankError> {
    switch (r) { case (#err(e)) #err(#IslamicError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#islamic(ev); extra = []; journal = [] }) }
  };
  func islamicErr<X>(e : IT.IslamicError) : Result.Result<X, T.BankError> { #err(#IslamicError({ error = e })) };
  func islamicPolicy(bs : State) : Result.Result<IT.Policy, T.BankError> {
    switch (IslamicCore.policy(bs.islamic)) { case (?p) #ok(p); case null #err(#IslamicError({ error = #NoPolicy })) }
  };
  func contractRow(bs : State, id : IT.ContractId) : Result.Result<IslamicCore.ContractRow, T.BankError> {
    switch (IslamicCore.row(bs.islamic, id)) { case (?r) #ok(r); case null islamicErr(#UnknownContract({ contract = id })) }
  };
  /// The contract's terms, read from the block that opened it.
  public func islamicKind(bb : Blocks, id : IT.ContractId) : ?IT.Kind {
    switch (bb.get(id)) { case (?b) { switch (b.event) { case (#islamic(#contractOpened(x))) ?x.kind; case (_) null } }; case null null }
  };
  func islamicBook(bs : State, id : IT.ContractId) : ?T.BookId { switch (IslamicCore.row(bs.islamic, id)) { case (?r) ?r.book; case null null } };
  func islamicCounterpartyLeg(bs : State, bb : Blocks, js : JCore.State, pol : IT.Policy, cp : IT.Counterparty, side : JT.Side, ccy : Text, amount : Nat, day : Nat) : Result.Result<JT.Leg, T.BankError> {
    switch (cp) {
      case (#party(p)) { switch (customerLeg(bs, bb, js, p.account, side, ccy, amount, day)) { case (#err(e)) #err(e); case (#ok((l, _, _))) #ok(l) } };
      case (#external(_)) #ok(Posting.leg(pol.nostro, null, side, ccy, amount));
    }
  };
  func islamicPost(js : JCore.State, journalCaller : Principal, now : Nat64, purpose : Text, parts : [Text], legs : [JT.Leg], postingDate : Nat, valueDate : Nat, period : Text, narration : Text, ev : IT.IslamicEvent) : Result.Result<Plan, T.BankError> {
    if (legs.size() == 0) return #ok({ bankEvent = ?#islamic(ev); extra = []; journal = [] });
    switch (postLegs(js, journalCaller, now, purpose, parts, legs, postingDate, valueDate, period, narration)) {
      case (#err(e)) #err(e);
      case (#ok(plan)) #ok({ bankEvent = ?#islamic(ev); extra = []; journal = plan.journal });
    }
  };
  /// The balance a contract's sub-ledger holds on an account (debit-normal), zero when the other way.
  func subBalance(js : JCore.State, account : Text, sub : JT.SubledgerKey, ccy : Text, day : Nat, normal : JT.Side) : Nat {
    let b = Posting.accountBalanceOn(js, account, sub, ccy, normal, day);
    if (b.overdrawn) 0 else b.net
  };
  func islamicAccounts(pol : IT.Policy) : [Text] {
    [pol.murabahaInventory, pol.murabahaReceivable, pol.deferredProfit, pol.murabahaIncome, pol.securityDeposits, pol.ijarahAssets, pol.accumulatedDepreciation, pol.depreciationExpense, pol.rentalReceivable, pol.ijarahIncome,
     pol.musharakahInvestment, pol.musharakahIncome, pol.mudarabahInvestment, pol.mudarabahIncome, pol.investmentLosses, pol.salamReceivable, pol.salamInventory, pol.salamIncome, pol.istisnaWip, pol.istisnaReceivable, pol.istisnaRevenue, pol.istisnaCosts,
     pol.iahEquity, pol.profitEqualisationReserve, pol.investmentRiskReserve, pol.profitPayableToHolders, pol.mudaribShareIncome, pol.profitAttributableToHolders, pol.charityPayable, pol.nostro]
  };
  /// Whether a product's terms carry an interest component — what a Sharia product may not.
  func productHasInterest(bs : State, product : ProdT.ProductId) : ?Bool {
    switch (ProductCore.currentVersion(bs.product, product)) { case (?v) ?(v.terms.interest != null); case null null }
  };
  /// The accounts of a pool's product in its currency, with Σ daily balances over [from, to].
  func poolWeights(bs : State, bb : Blocks, js : JCore.State, product : ProdT.ProductId, ccy : Text, from : Nat, to : Nat) : [(ProdT.AccountId, Nat)] {
    let out = List.empty<(ProdT.AccountId, Nat)>();
    for (a in ProductCore.accountsOfProduct(bs.product, productBlocks(bb), product).vals()) {
      if (not Text.equal(a.currency, ccy) or a.status == #closed) continue;
      let ?terms = ProductCore.termsOf(bs.product, a) else continue;
      var sum = 0; var d = from;
      while (d <= to) { sum += subBalance(js, terms.control, a.subledger, ccy, d, #credit); d += 1 };
      if (sum > 0) List.add(out, (a.id, sum));
    };
    List.toArray(out)
  };
  /// A pool's income over a period: the credit movement of the named income accounts between the day before the
  /// period and its last day, value-dated.
  func poolIncome(js : JCore.State, accounts : [Text], ccy : Text, from : Nat, to : Nat) : Nat {
    var sum = 0;
    for (a in accounts.vals()) {
      let after = JCore.valueDatedBalance(js, a, null, ccy, to);
      let before = if (from == 0) { { debits = 0; credits = 0 } } else JCore.valueDatedBalance(js, a, null, ccy, from - 1);
      let net : Int = (after.credits - after.debits) - (before.credits - before.debits);
      if (net > 0) sum += Int.abs(net);
    };
    sum
  };

  /// The Islamic-banking commands (Islamic banking), planned apart from the main switch so that switch stays under the chain's
  /// function-complexity bound.
  func planIslamicInner(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, command : T.Command, authorityIndex : Nat, authId : Text) : Result.Result<Plan, T.BankError> {
    let today = JCore.effectiveToday(js, now);
    switch (command) {
      case (#setIslamicPolicy(pol)) {
        for (code in islamicAccounts(pol).vals()) {
          switch (JCore.getAccount(js, code)) { case null return #err(#ProductError({ error = #RoleAccountUnknown({ role = "sharia policy"; account = code }) })); case (?_) {} };
        };
        islamicPlan(IslamicCore.planPolicy(pol))
      };
      case (#approveShariaProduct(x)) {
        switch (productHasInterest(bs, x.product)) {
          case null return #err(#ProductError({ error = #UnknownProduct({ product = x.product }) }));
          case (?true) return islamicErr(#InterestOnShariaProduct({ product = x.product }));
          case (?false) {};
        };
        islamicPlan(IslamicCore.planApproveProduct(x.product, x.approval, today))
      };
      case (#flagShariaBook(x)) { switch (requireOpenBook(bs, x.book)) { case (?e) return #err(e); case null {} }; islamicPlan(IslamicCore.planFlagBook(x.book, x.sharia, today)) };
      case (#openShariaContract(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let (party, account) = switch (x.kind) {
          case (#murabaha(m)) (m.customer, m.account); case (#ijarah(i)) (i.lessee, i.account); case (#musharakah(m)) (m.partners[0].party, m.partners[0].account);
          case (#mudarabah(m)) (m.mudarib, m.account); case (#salam(s)) (s.seller, s.account); case (#istisna(s)) (s.customer, s.account);
        };
        switch (requireParty(bs, party)) { case (?e) return #err(e); case null {} };
        let (a, _) = switch (requireAccount(bs, bb, account)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        if (a.party != party) return islamicErr(#InvalidTerms({ reason = "account " # Nat.toText(account) # " is not the party's"; standard = "governance" }));
        if (not Text.equal(a.currency, x.currency)) return #err(#ProductError({ error = #CurrencyMismatch({ expected = a.currency; actual = x.currency }) }));
        let hasInterest = switch (productHasInterest(bs, a.product)) { case (?b) b; case null true };
        let ev = switch (IslamicCore.planOpen(bs.islamic, x.kind, x.currency, a.book, a.product, hasInterest, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let valueDate = switch (tradeValueDate(bs, bb, js, a.book, account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(bs.height);
        let legs = List.empty<JT.Leg>();
        switch (x.kind) {
          case (#murabaha(m)) { if (m.securityDeposit > 0) { switch (customerLeg(bs, bb, js, account, #debit, x.currency, m.securityDeposit, valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) }; List.add(legs, Posting.leg(pol.securityDeposits, ?sub, #credit, x.currency, m.securityDeposit)) } };
          case (#salam(s)) {
            // the price is paid in full at the contract (FAS 7 ¶6)
            List.add(legs, Posting.leg(pol.salamReceivable, ?sub, #debit, x.currency, s.priceAdvanced));
            switch (customerLeg(bs, bb, js, account, #credit, x.currency, s.priceAdvanced, valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) };
          };
          case (_) {};
        };
        islamicPost(js, journalCaller, now, "sharia-open", [authId, IT.kindText(x.kind)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#acquireMurabahaAsset(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ?#murabaha(m) = islamicKind(bb, x.contract) else return islamicErr(#WrongKind({ contract = x.contract; kind = "?"; wanted = "murabaha" }));
        let ev = switch (IslamicCore.planAcquire(bs.islamic, x.contract, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        let supplier = switch (islamicCounterpartyLeg(bs, bb, js, pol, m.supplier, #credit, r.currency, m.costPrice, valueDate)) { case (#err(e)) return #err(e); case (#ok(l)) l };
        islamicPost(js, journalCaller, now, "murabaha-acquire", [authId, Nat.toText(x.contract)], [Posting.leg(pol.murabahaInventory, ?sub, #debit, r.currency, m.costPrice), supplier], x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#sellMurabaha(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ?#murabaha(m) = islamicKind(bb, x.contract) else return islamicErr(#WrongKind({ contract = x.contract; kind = "?"; wanted = "murabaha" }));
        let ev = switch (IslamicCore.planSell(bs.islamic, x.contract, m, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        let legs = List.empty<JT.Leg>();
        List.add(legs, Posting.leg(pol.murabahaReceivable, ?sub, #debit, r.currency, m.costPrice + m.markup));
        List.add(legs, Posting.leg(pol.murabahaInventory, ?sub, #credit, r.currency, m.costPrice));
        List.add(legs, Posting.leg(pol.deferredProfit, ?sub, #credit, r.currency, m.markup));
        // hamish jiddiyah returned at the sale (FAS 28 ¶14): the promise was kept
        if (r.securityDeposit > 0) {
          List.add(legs, Posting.leg(pol.securityDeposits, ?sub, #debit, r.currency, r.securityDeposit));
          switch (customerLeg(bs, bb, js, r.account, #credit, r.currency, r.securityDeposit, valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) };
        };
        islamicPost(js, journalCaller, now, "murabaha-sell", [authId, Nat.toText(x.contract)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#collectInstalment(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let (ev, inst) = switch (IslamicCore.planCollect(bs.islamic, x.contract, today)) { case (#err(e)) return islamicErr(e); case (#ok(p)) p };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        let legs = List.empty<JT.Leg>();
        switch (customerLeg(bs, bb, js, r.account, #debit, r.currency, inst.amount, valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) };
        List.add(legs, Posting.leg(pol.murabahaReceivable, ?sub, #credit, r.currency, inst.amount));
        islamicPost(js, journalCaller, now, "murabaha-collect", [authId, Nat.toText(x.contract), Nat.toText(inst.number)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#grantRebate(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ev = switch (IslamicCore.planRebate(bs.islamic, x.contract, x.amount, x.reason, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        islamicPost(js, journalCaller, now, "murabaha-rebate", [authId, Nat.toText(x.contract)], [Posting.leg(pol.deferredProfit, ?sub, #debit, r.currency, x.amount), Posting.leg(pol.murabahaReceivable, ?sub, #credit, r.currency, x.amount)], x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#commenceIjarah(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ev = switch (IslamicCore.planCommence(bs.islamic, x.contract, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        // the asset bought for the lease (FAS 32 ¶10): the lessor's asset
        islamicPost(js, journalCaller, now, "ijarah-commence", [authId, Nat.toText(x.contract)], [Posting.leg(pol.ijarahAssets, ?sub, #debit, r.currency, r.principal), Posting.leg(pol.nostro, null, #credit, r.currency, r.principal)], x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#collectRental(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let (ev, inst) = switch (IslamicCore.planCollectRental(bs.islamic, x.contract, today)) { case (#err(e)) return islamicErr(e); case (#ok(p)) p };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        let legs = List.empty<JT.Leg>();
        switch (customerLeg(bs, bb, js, r.account, #debit, r.currency, inst.amount, valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) };
        List.add(legs, Posting.leg(pol.rentalReceivable, ?sub, #credit, r.currency, inst.amount));
        islamicPost(js, journalCaller, now, "ijarah-collect", [authId, Nat.toText(x.contract), Nat.toText(inst.number)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#transferIjarahOwnership(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ?#ijarah(i) = islamicKind(bb, x.contract) else return islamicErr(#WrongKind({ contract = x.contract; kind = "?"; wanted = "ijarah" }));
        let ev = switch (IslamicCore.planTransfer(bs.islamic, x.contract, i, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let #ownershipTransferred(tr) = ev else return islamicErr(#InvalidTerms({ reason = "not a transfer"; standard = "" }));
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        // the asset leaves at cost against its accumulated depreciation and the consideration; the difference is the lessor's gain or loss
        let legs = List.empty<JT.Leg>();
        List.add(legs, Posting.leg(pol.ijarahAssets, ?sub, #credit, r.currency, r.principal));
        if (r.depreciation > 0) List.add(legs, Posting.leg(pol.accumulatedDepreciation, ?sub, #debit, r.currency, r.depreciation));
        if (tr.consideration > 0) { switch (customerLeg(bs, bb, js, r.account, #debit, r.currency, tr.consideration, valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) } };
        let covered = r.depreciation + tr.consideration;
        if (covered < r.principal) List.add(legs, Posting.leg(pol.investmentLosses, null, #debit, r.currency, r.principal - covered))
        else if (covered > r.principal) List.add(legs, Posting.leg(pol.ijarahIncome, null, #credit, r.currency, covered - r.principal));
        islamicPost(js, journalCaller, now, "ijarah-transfer", [authId, Nat.toText(x.contract)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#contributeCapital(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        if (r.stage != #opened) return islamicErr(#ContractNotIn({ contract = x.contract; stage = IT.stageText(r.stage); wanted = "opened" }));
        switch (islamicKind(bb, x.contract)) {
          case (?#musharakah(_)) islamicPost(js, journalCaller, now, "musharakah-capital", [authId, Nat.toText(x.contract)], [Posting.leg(pol.musharakahInvestment, ?sub, #debit, r.currency, r.principal), Posting.leg(pol.nostro, null, #credit, r.currency, r.principal)], x.postingDate, valueDate, x.period, x.narration, #capitalContributed({ contract = x.contract; party = null; amount = r.principal; day = today }));
          case (?#mudarabah(_)) {
            let legs = List.empty<JT.Leg>();
            List.add(legs, Posting.leg(pol.mudarabahInvestment, ?sub, #debit, r.currency, r.principal));
            switch (customerLeg(bs, bb, js, r.account, #credit, r.currency, r.principal, valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) };
            islamicPost(js, journalCaller, now, "mudarabah-capital", [authId, Nat.toText(x.contract)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, #capitalContributed({ contract = x.contract; party = null; amount = r.principal; day = today }))
          };
          case (?k) islamicErr(#WrongKind({ contract = x.contract; kind = IT.kindText(k); wanted = "musharakah or mudarabah" }));
          case null islamicErr(#UnknownContract({ contract = x.contract }));
        }
      };
      case (#distributeMusharakahProfit(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ?#musharakah(m) = islamicKind(bb, x.contract) else return islamicErr(#WrongKind({ contract = x.contract; kind = "?"; wanted = "musharakah" }));
        let ev = switch (IslamicCore.planDistributeProfit(bs.islamic, x.contract, m, x.profit, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let #profitDistributed(pd) = ev else return islamicErr(#InvalidTerms({ reason = "not a distribution"; standard = "" }));
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        islamicPost(js, journalCaller, now, "musharakah-profit", [authId, Nat.toText(x.contract), Nat.toText(today)], if (pd.bankShare == 0) [] else [Posting.leg(pol.nostro, null, #debit, r.currency, pd.bankShare), Posting.leg(pol.musharakahIncome, null, #credit, r.currency, pd.bankShare)], x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#allocateMusharakahLoss(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ?#musharakah(m) = islamicKind(bb, x.contract) else return islamicErr(#WrongKind({ contract = x.contract; kind = "?"; wanted = "musharakah" }));
        let ev = switch (IslamicCore.planAllocateLoss(bs.islamic, x.contract, m, x.loss, x.offered, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let #lossAllocated(la) = ev else return islamicErr(#InvalidTerms({ reason = "not a loss"; standard = "" }));
        if (la.bankShare > r.principal) return islamicErr(#InvalidTerms({ reason = "the bank's loss exceeds its capital"; standard = "FAS 4 ¶16" }));
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        islamicPost(js, journalCaller, now, "musharakah-loss", [authId, Nat.toText(x.contract), Nat.toText(today)], if (la.bankShare == 0) [] else [Posting.leg(pol.investmentLosses, null, #debit, r.currency, la.bankShare), Posting.leg(pol.musharakahInvestment, ?sub, #credit, r.currency, la.bankShare)], x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#buyMusharakahUnit(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ?#musharakah(m) = islamicKind(bb, x.contract) else return islamicErr(#WrongKind({ contract = x.contract; kind = "?"; wanted = "musharakah" }));
        let ev = switch (IslamicCore.planBuyUnit(bs.islamic, x.contract, m, x.units, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let #unitBought(ub) = ev else return islamicErr(#InvalidTerms({ reason = "not a purchase"; standard = "" }));
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        // the units leave the investment at their carrying amount; a price above it is the bank's gain on the sale
        let carrying = subBalance(js, pol.musharakahInvestment, sub, r.currency, valueDate, #debit);
        let portion = Nat.min(ub.price, carrying);
        let legs = List.empty<JT.Leg>();
        switch (customerLeg(bs, bb, js, r.account, #debit, r.currency, ub.price, valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) };
        if (portion > 0) List.add(legs, Posting.leg(pol.musharakahInvestment, ?sub, #credit, r.currency, portion));
        if (ub.price > portion) List.add(legs, Posting.leg(pol.musharakahIncome, null, #credit, r.currency, ub.price - portion));
        islamicPost(js, journalCaller, now, "musharakah-unit", [authId, Nat.toText(x.contract), Nat.toText(ub.bankUnitsLeft)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#recordMudarabahResult(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ?#mudarabah(m) = islamicKind(bb, x.contract) else return islamicErr(#WrongKind({ contract = x.contract; kind = "?"; wanted = "mudarabah" }));
        let ev = switch (IslamicCore.planMudarabahResult(bs.islamic, x.contract, m, x.profit, x.loss, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        let legs = List.empty<JT.Leg>();
        switch (ev) {
          case (#profitDistributed(pd)) { if (pd.bankShare > 0) { switch (customerLeg(bs, bb, js, r.account, #debit, r.currency, pd.bankShare, valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) }; List.add(legs, Posting.leg(pol.mudarabahIncome, null, #credit, r.currency, pd.bankShare)) } };
          case (#lossAllocated(la)) { if (la.bankShare > 0) { List.add(legs, Posting.leg(pol.investmentLosses, null, #debit, r.currency, la.bankShare)); List.add(legs, Posting.leg(pol.mudarabahInvestment, ?sub, #credit, r.currency, la.bankShare)) } };
          case (_) {};
        };
        islamicPost(js, journalCaller, now, "mudarabah-result", [authId, Nat.toText(x.contract), Nat.toText(today)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#deliverSalam(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ?#salam(sl) = islamicKind(bb, x.contract) else return islamicErr(#WrongKind({ contract = x.contract; kind = "?"; wanted = "salam" }));
        let ev = switch (IslamicCore.planDeliver(bs.islamic, x.contract, sl, x.quantity, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        islamicPost(js, journalCaller, now, "salam-deliver", [authId, Nat.toText(x.contract)], [Posting.leg(pol.salamInventory, ?sub, #debit, r.currency, r.principal), Posting.leg(pol.salamReceivable, ?sub, #credit, r.currency, r.principal)], x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#sellSalamCommodity(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ev = switch (IslamicCore.planSellCommodity(bs.islamic, x.contract, x.proceeds, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        let legs = List.empty<JT.Leg>();
        List.add(legs, Posting.leg(pol.nostro, null, #debit, r.currency, x.proceeds));
        List.add(legs, Posting.leg(pol.salamInventory, ?sub, #credit, r.currency, r.principal));
        if (x.proceeds > r.principal) List.add(legs, Posting.leg(pol.salamIncome, null, #credit, r.currency, x.proceeds - r.principal))
        else if (x.proceeds < r.principal) List.add(legs, Posting.leg(pol.investmentLosses, null, #debit, r.currency, r.principal - x.proceeds));
        islamicPost(js, journalCaller, now, "salam-sell", [authId, Nat.toText(x.contract)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#recordSalamFailure(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ?#salam(sl) = islamicKind(bb, x.contract) else return islamicErr(#WrongKind({ contract = x.contract; kind = "?"; wanted = "salam" }));
        let ev = switch (IslamicCore.planDeliveryFailed(bs.islamic, x.contract, sl, x.recourse, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        // the price advanced comes back from the seller (FAS 7 ¶10)
        let legs = List.empty<JT.Leg>();
        switch (customerLeg(bs, bb, js, r.account, #debit, r.currency, r.principal, valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) };
        List.add(legs, Posting.leg(pol.salamReceivable, ?sub, #credit, r.currency, r.principal));
        islamicPost(js, journalCaller, now, "salam-failure", [authId, Nat.toText(x.contract)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#recordIstisnaMilestone(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        let ?#istisna(ist) = islamicKind(bb, x.contract) else return islamicErr(#WrongKind({ contract = x.contract; kind = "?"; wanted = "istisna" }));
        let ev = switch (IslamicCore.planMilestone(bs.islamic, x.contract, ist, x.certificate, x.percentBps, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let #milestoneRecorded(ms) = ev else return islamicErr(#InvalidTerms({ reason = "not a milestone"; standard = "" }));
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        // the contractor paid for the work (into WIP), the work billed (the receivable against revenue), the cost of the work recognised out of WIP (FAS 10 ¶13-17)
        let legs = List.empty<JT.Leg>();
        if (ms.cost > 0) {
          List.add(legs, Posting.leg(pol.istisnaWip, ?sub, #debit, r.currency, ms.cost));
          switch (islamicCounterpartyLeg(bs, bb, js, pol, ist.contractor, #credit, r.currency, ms.cost, valueDate)) { case (#err(e)) return #err(e); case (#ok(l)) List.add(legs, l) };
          List.add(legs, Posting.leg(pol.istisnaCosts, null, #debit, r.currency, ms.cost));
          List.add(legs, Posting.leg(pol.istisnaWip, ?sub, #credit, r.currency, ms.cost));
        };
        if (ms.revenue > 0) { List.add(legs, Posting.leg(pol.istisnaReceivable, ?sub, #debit, r.currency, ms.revenue)); List.add(legs, Posting.leg(pol.istisnaRevenue, null, #credit, r.currency, ms.revenue)) };
        islamicPost(js, journalCaller, now, "istisna-milestone", [authId, Nat.toText(x.contract), Nat.toText(x.percentBps)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#collectIstisnaBilling(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let r = switch (contractRow(bs, x.contract)) { case (#err(e)) return #err(e); case (#ok(r)) r };
        if (r.kind != 6) return islamicErr(#WrongKind({ contract = x.contract; kind = "?"; wanted = "istisna" }));
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        let due = subBalance(js, pol.istisnaReceivable, sub, r.currency, valueDate, #debit);
        if (due == 0) return islamicErr(#InvalidTerms({ reason = "nothing billed is outstanding"; standard = "FAS 10" }));
        let legs = List.empty<JT.Leg>();
        switch (customerLeg(bs, bb, js, r.account, #debit, r.currency, due, valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) };
        List.add(legs, Posting.leg(pol.istisnaReceivable, ?sub, #credit, r.currency, due));
        islamicPost(js, journalCaller, now, "istisna-collect", [authId, Nat.toText(x.contract), Nat.toText(valueDate)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, #instalmentCollected({ contract = x.contract; amount = due; principal = due; profit = 0; day = today }))
      };
      case (#settleShariaContract(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let (ev, r) = switch (IslamicCore.planSettle(bs.islamic, x.contract, today)) { case (#err(e)) return islamicErr(e); case (#ok(p)) p };
        let valueDate = switch (tradeValueDate(bs, bb, js, r.book, r.account, x.period, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let sub = IslamicCore.contractSub(x.contract);
        let legs = List.empty<JT.Leg>();
        switch (r.kind) {
          case 3 { let left = subBalance(js, pol.musharakahInvestment, sub, r.currency, valueDate, #debit); if (left > 0) { List.add(legs, Posting.leg(pol.nostro, null, #debit, r.currency, left)); List.add(legs, Posting.leg(pol.musharakahInvestment, ?sub, #credit, r.currency, left)) } };
          case 4 { let left = subBalance(js, pol.mudarabahInvestment, sub, r.currency, valueDate, #debit); if (left > 0) { switch (customerLeg(bs, bb, js, r.account, #debit, r.currency, left, valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) }; List.add(legs, Posting.leg(pol.mudarabahInvestment, ?sub, #credit, r.currency, left)) } };
          case _ {};
        };
        islamicPost(js, journalCaller, now, "sharia-settle", [authId, Nat.toText(x.contract)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration, ev)
      };
      case (#closeShariaContract(x)) islamicPlan(IslamicCore.planClose(bs.islamic, x.contract, x.reason, today));
      case (#recordNonCompliance(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        switch (JCore.getAccount(js, x.account)) { case null return #err(#JournalConfigError({ error = #UnknownAccount({ code = x.account }) })); case (?_) {} };
        let ev = switch (IslamicCore.planNonCompliance(bs.islamic, x.contract, x.amount, x.account, x.reason, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let ccy = switch (x.contract) { case (?id) { switch (IslamicCore.row(bs.islamic, id)) { case (?r) r.currency; case null "EGP" } }; case null { switch (JCore.listCurrencies(js).size()) { case 0 "EGP"; case _ JCore.listCurrencies(js)[0].code } } };
        islamicPost(js, journalCaller, now, "sharia-charity", [authId, Nat.toText(today), x.account], [Posting.leg(x.account, null, #debit, ccy, x.amount), Posting.leg(pol.charityPayable, null, #credit, ccy, x.amount)], x.postingDate, x.valueDate, x.period, x.narration, ev)
      };
      case (#openInvestmentPool(x)) {
        switch (productHasInterest(bs, x.pool.product)) {
          case null return #err(#ProductError({ error = #UnknownProduct({ product = x.pool.product }) }));
          case (?true) return islamicErr(#InterestOnShariaProduct({ product = x.pool.product }));
          case (?false) {};
        };
        if (IslamicCore.approval(bs.islamic, x.pool.product) == null) return islamicErr(#NoBoardApproval({ product = x.pool.product }));
        for (a in x.pool.incomeAccounts.vals()) { switch (JCore.getAccount(js, a)) { case null return #err(#JournalConfigError({ error = #UnknownAccount({ code = a }) })); case (?_) {} } };
        islamicPlan(IslamicCore.planOpenPool(bs.islamic, x.pool, today))
      };
      case (#updatePoolReserves(x)) islamicPlan(IslamicCore.planReserves(bs.islamic, x.pool, x.per, x.irr, today));
      case (#distributePool(x)) {
        let pol = switch (islamicPolicy(bs)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        let ?p = IslamicCore.pool(bs.islamic, x.pool) else return islamicErr(#UnknownPool({ pool = x.pool }));
        let incomeAccounts = switch (poolIncomeAccounts(bs, bb, x.pool)) { case (?a) a; case null return islamicErr(#UnknownPool({ pool = x.pool })) };
        let income = poolIncome(js, incomeAccounts, p.currency, x.from, x.to);
        let weights = poolWeights(bs, bb, js, p.product, p.currency, x.from, x.to);
        let ev = switch (IslamicCore.planDistribute(bs.islamic, x.pool, x.month, x.from, x.to, income, weights, today)) { case (#err(e)) return islamicErr(e); case (#ok(ev)) ev };
        let #poolDistributed(pd) = ev else return islamicErr(#InvalidTerms({ reason = "not a distribution"; standard = "" }));
        let d = pd.distribution;
        let psub = IslamicCore.poolSub(x.pool);
        let legs = List.empty<JT.Leg>();
        let charged = d.per + d.irr + d.paid;
        if (charged > 0) List.add(legs, Posting.leg(pol.profitAttributableToHolders, null, #debit, p.currency, charged));
        if (d.per > 0) List.add(legs, Posting.leg(pol.profitEqualisationReserve, ?psub, #credit, p.currency, d.per));
        if (d.irr > 0) List.add(legs, Posting.leg(pol.investmentRiskReserve, ?psub, #credit, p.currency, d.irr));
        for ((acct, amount) in d.allocations.vals()) {
          if (amount > 0) { switch (customerLeg(bs, bb, js, acct, #credit, p.currency, amount, x.valueDate)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) } };
        };
        islamicPost(js, journalCaller, now, "psia-distribute", [authId, x.pool, x.month], List.toArray(legs), x.postingDate, x.valueDate, x.period, x.narration, ev)
      };
      case (_) #err(#IslamicError({ error = #InvalidTerms({ reason = "not an Islamic-banking command"; standard = "" }) }));
    }
  };
  /// A pool's income accounts, from the block that opened it.
  func poolIncomeAccounts(bs : State, bb : Blocks, poolId : IT.PoolId) : ?[Text] {
    let ?p = IslamicCore.pool(bs.islamic, poolId) else return null;
    switch (bb.get(p.openedBlock)) { case (?b) { switch (b.event) { case (#islamic(#poolOpened(x))) ?x.pool.incomeAccounts; case (_) null } }; case null null }
  };

  /// End of day, job 14 (`sharia`): per open contract of the book — a Murabaha's profit recognised to the day under
  /// its method (the cumulative straight line of the proportionate method, or the instalments fallen due under the
  /// effective rate), the late-payment undertaking on an overdue instalment carried to charity (never income), an
  /// Ijarah's rental accrued when it falls due and its asset depreciated straight-line (cumulative) — each a posting
  /// and a block only when the figure is not zero.
  func jobSharia(
    bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64,
    acc : ChunkAcc, item : Batch.PlanItem, index : Nat, day : ProdT.Day, period : JT.PeriodId, book : Text, only : ?Text,
  ) {
    let ?pol = IslamicCore.policy(bs.islamic) else { fail(acc, index, item.job, book, "no sharia policy"); return };
    func post(kind : Text, id : Nat, part : Text, legs : [JT.Leg], narration : Text) : Bool {
      if (legs.size() == 0) return true;
      if (not Posting.balances(legs)) { fail(acc, index, item.job, Nat.toText(id), kind # ": the legs do not balance"); return false };
      let input : JT.PostingInput = { idempotencyKey = Posting.key(kind, [Nat.toText(id), part, Nat.toText(day)]); postingDate = day; valueDate = day; period; legs; sourceRef = { kind; id = Nat.toText(id) # "/" # part # "/" # Nat.toText(day) }; narration; correctionOf = null };
      switch (batchPost(js, jb, journalCaller, now, acc, input)) { case (?why) { fail(acc, index, item.job, Nat.toText(id), why); false }; case null true }
    };
    for (r in IslamicCore.openInBook(bs.islamic, book).vals()) {
      let mine = switch (only) { case null true; case (?e) Text.equal(e, Nat.toText(r.id)) };
      if (not mine) continue;
      acc.examined += 1;
      let sub = IslamicCore.contractSub(r.id);
      switch (r.kind, r.stage) {
        case (1, #sold) {
          // profit to the day
          let due = IslamicCore.profitDueBy(bs.islamic, r, day);
          if (due > r.profitRecognised) {
            let delta = due - r.profitRecognised;
            if (post("murabaha-profit", r.id, "p", [Posting.leg(pol.deferredProfit, ?sub, #debit, r.currency, delta), Posting.leg(pol.murabahaIncome, null, #credit, r.currency, delta)], "profit recognised to day " # Nat.toText(day))) {
              record(acc, #islamic(#profitRecognised({ contract = r.id; amount = delta; cumulative = due; day })));
            };
          };
          // the late-payment undertaking on overdue instalments, to charity
          switch (islamicKind(bb, r.id)) {
            case (?#murabaha(m)) {
              if (m.latePaymentCharityBps > 0) {
                for (inst in IslamicCore.instalmentsOf(bs.islamic, r.id).vals()) {
                  if (inst.paid or inst.dueDate >= day) continue;
                  let cum = IslamicCore.lateCharity(inst, m.latePaymentCharityBps, day);
                  if (cum > inst.charity) {
                    let delta = cum - inst.charity;
                    switch (customerLeg(bs, bb, js, r.account, #debit, r.currency, delta, day)) {
                      case (#ok((l, _, _))) {
                        if (post("murabaha-charity", r.id, Nat.toText(inst.number), [l, Posting.leg(pol.charityPayable, null, #credit, r.currency, delta)], "late-payment undertaking to charity")) {
                          record(acc, #islamic(#latePaymentToCharity({ contract = r.id; instalment = inst.number; amount = delta; cumulative = cum; day })));
                        };
                      };
                      case (#err(e)) fail(acc, index, item.job, Nat.toText(r.id), debug_show e);
                    };
                  };
                };
              };
            };
            case (_) {};
          };
        };
        case (2, #running) {
          switch (islamicKind(bb, r.id)) {
            case (?#ijarah(i)) {
              // rentals fallen due and not yet accrued: the accrued count is the rows whose due day has passed
              var accrued = 0;
              for (inst in IslamicCore.instalmentsOf(bs.islamic, r.id).vals()) {
                if (inst.dueDate <= day) {
                  accrued += inst.amount;
                };
              };
              if (accrued > r.profitRecognised) {
                let delta = accrued - r.profitRecognised;
                if (post("ijarah-rental", r.id, "r", [Posting.leg(pol.rentalReceivable, ?sub, #debit, r.currency, delta), Posting.leg(pol.ijarahIncome, null, #credit, r.currency, delta)], "rental due")) {
                  record(acc, #islamic(#rentalAccrued({ contract = r.id; amount = delta; period = r.instalmentsDue; day })));
                };
              };
              // depreciation to the day: straight-line over the shorter of the term and the useful life
              let months = Nat.min(i.usefulLifeMonths, i.periods * (switch (i.every) { case (#monthly) 1; case (#quarterly) 3; case (#semiAnnual) 6; case (#annual) 12; case (_) 1 }));
              let dep = IslamicCore.depreciationBy(i.cost, i.residual, r.openedDay, months, day);
              if (dep > r.depreciation) {
                let delta = dep - r.depreciation;
                if (post("ijarah-depreciation", r.id, "d", [Posting.leg(pol.depreciationExpense, null, #debit, r.currency, delta), Posting.leg(pol.accumulatedDepreciation, ?sub, #credit, r.currency, delta)], "depreciation to day " # Nat.toText(day))) {
                  record(acc, #islamic(#depreciationPosted({ contract = r.id; amount = delta; cumulative = dep; day })));
                };
              };
            };
            case (_) {};
          };
        };
        case (_, _) {};
      };
    };
  };

  // ─── trade finance (trade finance): the planners' helpers ────────────────────────────

  func tradePlan(r : Result.Result<TrT.TradeEvent, TrT.TradeError>) : Result.Result<Plan, T.BankError> {
    switch (r) { case (#err(e)) #err(#TradeError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#trade(ev); extra = []; journal = [] }) }
  };
  func tradeErr<X>(e : TrT.TradeError) : Result.Result<X, T.BankError> { #err(#TradeError({ error = e })) };
  func tradePolicy(bs : State) : Result.Result<TrT.Policy, T.BankError> {
    switch (TradeCore.policy(bs.trade)) { case (?p) #ok(p); case null #err(#TradeError({ error = #NoPolicy })) }
  };
  func tradeRow(bs : State, id : TrT.InstrumentId) : Result.Result<TradeCore.InstrumentRow, T.BankError> {
    switch (TradeCore.row(bs.trade, id)) { case (?r) #ok(r); case null #err(#TradeError({ error = #UnknownInstrument({ instrument = id }) })) }
  };
  func minorUnitsOfCurrency(js : JCore.State, ccy : Text) : ?Nat8 { for (c in JCore.listCurrencies(js).vals()) { if (Text.equal(c.code, ccy)) return ?c.minorUnits }; null };
  /// The memorandum pair: the contingent account against its contra, debited when an undertaking is given and
  /// credited back as it is honoured, reduced, released or expires.
  func memoLegs(pol : TrT.Policy, memo : Text, ccy : Text, amount : Nat, give : Bool) : [JT.Leg] {
    if (amount == 0) return [];
    [Posting.leg(memo, null, if (give) #debit else #credit, ccy, amount), Posting.leg(pol.contingentContra, null, if (give) #credit else #debit, ccy, amount)]
  };
  func memoAccount(pol : TrT.Policy, r : TradeCore.InstrumentRow) : ?Text {
    switch (r.kind) { case 1 { if (TradeCore.isUndertaking(r)) ?pol.contingentLcs else null }; case 2 ?pol.contingentGuarantees; case 3 ?pol.contingentCollections; case _ null }
  };
  /// A customer's account as a posting leg, in the instrument's currency, movable on the day.
  func customerLeg(bs : State, bb : Blocks, js : JCore.State, account : ProdT.AccountId, side : JT.Side, ccy : Text, amount : Nat, day : Nat) : Result.Result<(JT.Leg, ProductCore.AccountEntry, ProdT.ProductTerms), T.BankError> {
    let (a, terms) = switch (movableAccount(bs, bb, js, account, day)) { case (#err(e)) return #err(e); case (#ok(p)) p };
    if (not Text.equal(a.currency, ccy)) return #err(#ProductError({ error = #CurrencyMismatch({ expected = ccy; actual = a.currency }) }));
    #ok((Posting.leg(terms.control, ?a.subledger, side, ccy, amount), a, terms))
  };
  /// The other side of a settlement: one of our customers' accounts, or the correspondent account.
  func counterpartyLeg(bs : State, bb : Blocks, js : JCore.State, pol : TrT.Policy, cp : TrT.Counterparty, side : JT.Side, ccy : Text, amount : Nat, day : Nat) : Result.Result<JT.Leg, T.BankError> {
    switch (cp) {
      case (#party(p)) { switch (customerLeg(bs, bb, js, p.account, side, ccy, amount, day)) { case (#err(e)) #err(e); case (#ok((l, _, _))) #ok(l) } };
      case (#external(_)) #ok(Posting.leg(pol.nostro, null, side, ccy, amount));
    }
  };
  /// The applicant's or principal's account: our customer, whose account the instrument row names.
  func ownAccountLeg(bs : State, bb : Blocks, js : JCore.State, r : TradeCore.InstrumentRow, side : JT.Side, amount : Nat, day : Nat) : Result.Result<JT.Leg, T.BankError> {
    if (r.account == 0) return #err(#TradeError({ error = #InvalidTerms({ reason = "the instrument names no account of ours"; article = "policy" }) }));
    switch (customerLeg(bs, bb, js, r.account, side, r.currency, amount, day)) { case (#err(e)) #err(e); case (#ok((l, _, _))) #ok(l) }
  };
  /// The balance a customer's account holds on the day, zero when overdrawn.
  func customerBalance(bs : State, bb : Blocks, js : JCore.State, account : ProdT.AccountId, day : Nat) : Nat {
    switch (requireAccount(bs, bb, account)) {
      case (#ok((a, terms))) { let b = Posting.accountBalanceOn(js, terms.control, a.subledger, a.currency, #credit, day); if (b.overdrawn) 0 else b.net };
      case (#err(_)) 0;
    }
  };
  func tradeAccounts(pol : TrT.Policy) : [Text] {
    [pol.contingentLcs, pol.contingentGuarantees, pol.contingentCollections, pol.contingentContra, pol.marginDeposits, pol.unearnedCommission, pol.commissionIncome,
     pol.acceptancesPayable, pol.customersLiabilityAcceptances, pol.billsNegotiated, pol.billsDiscounted, pol.unearnedDiscount, pol.discountIncome, pol.billsRediscounted, pol.billLosses, pol.nostro]
  };
  /// The instrument's terms, read from the block that issued it.
  func tradeKindOf(bb : Blocks, id : TrT.InstrumentId) : ?TrT.Kind {
    let ?b = bb.get(id) else return null;
    switch (?b.event) {
      case (?#trade(#lcIssued(x))) ?#letterOfCredit(x.lc);
      case (?#trade(#lcAdvised(x))) ?#letterOfCredit(x.lc);
      case (?#trade(#guaranteeIssued(x))) ?#guarantee(x.guarantee);
      case (?#trade(#collectionRegistered(x))) ?#collection(x.collection);
      case (?#trade(#billDiscounted(x))) ?#bill(x.bill);
      case (_) null;
    }
  };
  public func tradeKind(bb : Blocks, id : TrT.InstrumentId) : ?TrT.Kind { tradeKindOf(bb, id) };
  func lcTerms(bb : Blocks, id : TrT.InstrumentId) : Result.Result<TrT.LetterOfCredit, T.BankError> {
    switch (tradeKindOf(bb, id)) { case (?#letterOfCredit(lc)) #ok(lc); case (?k) tradeErr(#WrongKind({ instrument = id; kind = TrT.kindText(k); wanted = "letterOfCredit" })); case null tradeErr(#UnknownInstrument({ instrument = id })) }
  };
  func guaranteeTerms(bb : Blocks, id : TrT.InstrumentId) : Result.Result<TrT.Guarantee, T.BankError> {
    switch (tradeKindOf(bb, id)) { case (?#guarantee(g)) #ok(g); case (?k) tradeErr(#WrongKind({ instrument = id; kind = TrT.kindText(k); wanted = "guarantee" })); case null tradeErr(#UnknownInstrument({ instrument = id })) }
  };
  func checklistOf(terms : TrT.DocumentaryTerms) : [(TrT.DocumentKind, Text)] {
    let out = List.empty<(TrT.DocumentKind, Text)>();
    for (d in terms.documents.vals()) { for (c in d.checks.vals()) List.add(out, (d.kind, c)) };
    List.toArray(out)
  };
  /// An undertaking against a facility: the facility open, in the currency, with room for it beside the drawings
  /// and the undertakings already outstanding.
  func facilityRoom(bs : State, bb : Blocks, js : JCore.State, facility : Nat, ccy : Text, amount : Nat, day : Nat) : ?T.BankError {
    let ?r = FacilityCore.row(bs.facility, facility) else return ?#FacilityError({ error = #UnknownFacility({ facility }) });
    if (r.stage != #open) return ?#FacilityError({ error = #Blocked({ facility; reason = "the facility is " # FaT.stageText(r.stage) }) });
    if (not Text.equal(r.currency, ccy)) return ?#ProductError({ error = #CurrencyMismatch({ expected = r.currency; actual = ccy }) });
    let used = facilityDrawn(bs, bb, js, facility, day) + TradeCore.contingentOnFacility(bs.trade, facility);
    if (used + amount > r.limit) return ?#FacilityError({ error = #OverLimit({ facility; limit = r.limit; drawn = used; requested = amount }) });
    null
  };
  /// The postings of an issue: the margin lodged from the customer's account into the margin sub-ledger, the
  /// commission taken into unearned commission, the undertaking on the memorandum pair — one posting.
  func issueLegs(bs : State, bb : Blocks, js : JCore.State, pol : TrT.Policy, memo : ?Text, account : ProdT.AccountId, ccy : Text, amount : Nat, margin : Nat, commission : Nat, id : Nat, day : Nat) : Result.Result<[JT.Leg], T.BankError> {
    let legs = List.empty<JT.Leg>();
    if (margin + commission > 0) {
      switch (customerLeg(bs, bb, js, account, #debit, ccy, margin + commission, day)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) };
      if (margin > 0) List.add(legs, Posting.leg(pol.marginDeposits, ?TradeCore.marginSub(id), #credit, ccy, margin));
      if (commission > 0) List.add(legs, Posting.leg(pol.unearnedCommission, ?TradeCore.commissionSub(id), #credit, ccy, commission));
    };
    switch (memo) { case (?m) { for (l in memoLegs(pol, m, ccy, amount, true).vals()) List.add(legs, l) }; case null {} };
    #ok(List.toArray(legs))
  };
  /// The postings of an end: the margin returned, the memorandum reversed for what is still outstanding, the
  /// commission not yet earned recognised.
  func endLegs(bs : State, bb : Blocks, js : JCore.State, pol : TrT.Policy, r : TradeCore.InstrumentRow, day : Nat) : Result.Result<[JT.Leg], T.BankError> {
    let legs = List.empty<JT.Leg>();
    if (r.margin > 0) {
      List.add(legs, Posting.leg(pol.marginDeposits, ?TradeCore.marginSub(r.id), #debit, r.currency, r.margin));
      switch (ownAccountLeg(bs, bb, js, r, #credit, r.margin, day)) { case (#err(e)) return #err(e); case (#ok(l)) List.add(legs, l) };
    };
    switch (memoAccount(pol, r)) { case (?m) { for (l in memoLegs(pol, m, r.currency, TradeCore.outstanding(r), false).vals()) List.add(legs, l) }; case null {} };
    let left = if (r.commissionTotal > r.commissionEarned) r.commissionTotal - r.commissionEarned else 0;
    if (left > 0) { List.add(legs, Posting.leg(pol.unearnedCommission, ?TradeCore.commissionSub(r.id), #debit, r.currency, left)); List.add(legs, Posting.leg(pol.commissionIncome, null, #credit, r.currency, left)) };
    #ok(List.toArray(legs))
  };
  /// A plan with no posting when the legs are empty, one posting otherwise.
  func tradePost(js : JCore.State, journalCaller : Principal, now : Nat64, purpose : Text, parts : [Text], legs : [JT.Leg], postingDate : Nat, valueDate : Nat, period : Text, narration : Text, ev : TrT.TradeEvent, extra : [T.Event]) : Result.Result<Plan, T.BankError> {
    if (legs.size() == 0) return #ok({ bankEvent = ?#trade(ev); extra; journal = [] });
    switch (postLegs(js, journalCaller, now, purpose, parts, legs, postingDate, valueDate, period, narration)) {
      case (#err(e)) #err(e);
      case (#ok(plan)) #ok({ bankEvent = ?#trade(ev); extra; journal = plan.journal });
    }
  };
  /// The value day of a trade posting: the account's convention where the instrument has our account, the day as
  /// given otherwise (a memorandum has no customer).
  func tradeValueDate(bs : State, bb : Blocks, js : JCore.State, book : Text, account : ProdT.AccountId, period : Text, requested : Nat) : Result.Result<Nat, T.BankError> {
    if (account == 0) return #ok(requested);
    switch (ProductCore.get(bs.product, productBlocks(bb), account)) {
      case (?a) { switch (ProductCore.termsOf(bs.product, a)) { case (?terms) valueDateGate(bs, js, book, period, terms.valueDateConvention, requested); case null #ok(requested) } };
      case null #ok(requested);
    }
  };
  /// Paying a demand or a sight presentation: the margin first, the customer's account next, and what neither
  /// covers a claim — a loan account opened under the policy's claim product, disbursed to the beneficiary, so the
  /// bank's reimbursement right ages under collections and recovery from the day it was paid.
  type PaidFrom = { fromMargin : Nat; fromAccount : Nat; claim : Nat; legs : [JT.Leg]; claimAccount : ?ProdT.AccountId; extra : [T.Event]; limitEvent : ?JT.Event };
  func payFromCustomer(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, pol : TrT.Policy, r : TradeCore.InstrumentRow, amount : Nat, sink : JT.Leg, day : Nat, authorityIndex : Nat, allowClaim : Bool) : Result.Result<PaidFrom, T.BankError> {
    let legs = List.empty<JT.Leg>();
    let fromMargin = Nat.min(r.margin, amount);
    if (fromMargin > 0) List.add(legs, Posting.leg(pol.marginDeposits, ?TradeCore.marginSub(r.id), #debit, r.currency, fromMargin));
    var rest = amount - fromMargin;
    let balance = if (r.account == 0) 0 else customerBalance(bs, bb, js, r.account, day);
    let fromAccount = if (allowClaim) Nat.min(balance, rest) else rest;
    if (fromAccount > 0) { switch (ownAccountLeg(bs, bb, js, r, #debit, fromAccount, day)) { case (#err(e)) return #err(e); case (#ok(l)) List.add(legs, l) } };
    rest -= fromAccount;
    var claimAccount : ?ProdT.AccountId = null;
    var extra : [T.Event] = [];
    var limitEvent : ?JT.Event = null;
    if (rest > 0) {
      // the claim: a loan account under the claim product, its schedule one instalment due at once
      let ?pe = PartyCore.get(bs.party, partyBlocks(bb), r.party) else return #err(#PartyError({ error = #UnknownParty({ party = r.party }) }));
      let ?v = ProductCore.currentVersion(bs.product, pol.claimProduct) else return #err(#ProductError({ error = #UnknownProduct({ product = pol.claimProduct }) }));
      let terms = v.terms;
      if (terms.kind != #loan) return #err(#ProductError({ error = #AccountNotOfKind({ account = 0; expected = "loan"; actual = debug_show (terms.kind) }) }));
      let ?sch = terms.schedule else return #err(#ProductError({ error = #ScheduleRequired({ product = pol.claimProduct }) }));
      let ?it = terms.interest else return #err(#ProductError({ error = #InvalidTerms({ reason = "the claim product needs interest terms" }) }));
      let rate = switch (Products.rateAt(it.chart, if (it.chart.by == #balance) rest else sch.instalments * ProdT.periodDays(sch.every))) { case (?x) x; case null return #err(#TermError({ reason = "no rate band covers the claim" })) };
      let accountId = bs.height;
      let opened = switch (planOpenAccount(bs, js, journalCaller, pol.claimProduct, r.party, pe.book, r.currency, null, [], ?rate, authorityIndex, [])) { case (#err(e)) return #err(e); case (#ok(o)) o };
      let generated = Products.schedule(rest, rate, sch, terms.rounding, day);
      let faults = Products.scheduleFaults(rest, generated.rows);
      if (faults.size() > 0) return #err(#ProductError({ error = #InvalidSchedule({ reason = faults[0] }) }));
      List.add(legs, Posting.leg(terms.control, ?Posting.subledgerOf(opened.identifier), #debit, r.currency, rest));
      claimAccount := ?accountId;
      extra := [#product(opened.opened), #product(#accountStatusSet({ account = accountId; to = #active })), #product(#loanDisbursed({ account = accountId; amount = rest; day; schedule = generated.rows }))];
      limitEvent := ?opened.limit;
    };
    List.add(legs, sink);
    #ok({ fromMargin; fromAccount; claim = rest; legs = List.toArray(legs); claimAccount; extra; limitEvent })
  };
  /// The bank's own name for the messages it renders: the book's name, or the book id when it has none.
  func bankNameOf(bs : State, book : Text) : Text {
    switch (getBook(bs, book)) { case (?b) b.name; case null book }
  };
  /// The postings when a deferred payment, an acceptance or a negotiation falls due: the applicant (or the margin,
  /// or a claim) settles its liability to us and we pay the beneficiary out of acceptances payable; a negotiation is
  /// reimbursed by the issuing bank across the correspondent account.
  func settleAcceptanceLegs(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, pol : TrT.Policy, r : TradeCore.InstrumentRow, lc : TrT.LetterOfCredit, c : TradeCore.ClaimRow, amount : Nat, day : Nat, authorityIndex : Nat) : Result.Result<{ legs : [JT.Leg]; extra : [T.Event]; limitEvent : ?JT.Event; fromMargin : Nat }, T.BankError> {
    let sub = TradeCore.acceptanceSub(r.id, c.seq);
    let legs = List.empty<JT.Leg>();
    if (c.honour == 4) {
      // negotiation: the issuing bank reimburses us
      List.add(legs, Posting.leg(pol.nostro, null, #debit, r.currency, amount));
      List.add(legs, Posting.leg(pol.billsNegotiated, ?sub, #credit, r.currency, amount));
      return #ok({ legs = List.toArray(legs); extra = []; limitEvent = null; fromMargin = 0 });
    };
    var extra : [T.Event] = [];
    var limitEvent : ?JT.Event = null;
    var fromMargin = 0;
    if (lc.role == #issuing) {
      // the applicant settles its liability under the acceptance; what it cannot pay becomes a claim
      let liability = Posting.leg(pol.customersLiabilityAcceptances, ?sub, #credit, r.currency, amount);
      let paid = switch (payFromCustomer(bs, bb, js, journalCaller, pol, r, amount, liability, day, authorityIndex, true)) { case (#err(e)) return #err(e); case (#ok(p)) p };
      for (l in paid.legs.vals()) List.add(legs, l);
      extra := paid.extra; limitEvent := paid.limitEvent; fromMargin := paid.fromMargin;
    } else {
      List.add(legs, Posting.leg(pol.nostro, null, #debit, r.currency, amount));
      List.add(legs, Posting.leg(pol.nostro, null, #credit, r.currency, amount));
    };
    // and we pay the beneficiary
    List.add(legs, Posting.leg(pol.acceptancesPayable, ?sub, #debit, r.currency, amount));
    switch (counterpartyLeg(bs, bb, js, pol, lc.beneficiary, #credit, r.currency, amount, day)) { case (#err(e)) return #err(e); case (#ok(l)) List.add(legs, l) };
    // a nostro debit and credit of the same amount cancel: drop the pair the confirming case produced
    let out = List.filter<JT.Leg>(legs, func(l) { not (Text.equal(l.account, pol.nostro) and l.subledger == null and lc.role != #issuing and l.side == #credit and l.amount == amount) });
    #ok({ legs = List.toArray(out); extra; limitEvent; fromMargin })
  };
  /// The postings at a bill's end: at maturity the acceptor pays the face against bills discounted (and a
  /// rediscounted bill is redeemed across the correspondent account), the discount left is earned; on dishonour the
  /// face is charged back to the customer under recourse — the discount earned in full — or written to bill losses
  /// without recourse, the unearned discount reducing the loss.
  func billEndLegs(bs : State, bb : Blocks, js : JCore.State, pol : TrT.Policy, r : TradeCore.InstrumentRow, b : TrT.Bill, dishonour : Bool, day : Nat) : Result.Result<[JT.Leg], T.BankError> {
    let sub = TradeCore.billSub(r.id);
    let legs = List.empty<JT.Leg>();
    let left = if (r.commissionTotal > r.commissionEarned) r.commissionTotal - r.commissionEarned else 0;
    if (not dishonour) {
      switch (counterpartyLeg(bs, bb, js, pol, b.acceptor, #debit, r.currency, r.amount, day)) { case (#err(e)) return #err(e); case (#ok(l)) List.add(legs, l) };
      List.add(legs, Posting.leg(pol.billsDiscounted, ?sub, #credit, r.currency, r.amount));
      if (left > 0) { List.add(legs, Posting.leg(pol.unearnedDiscount, ?sub, #debit, r.currency, left)); List.add(legs, Posting.leg(pol.discountIncome, null, #credit, r.currency, left)) };
    } else if (b.recourse) {
      switch (customerLeg(bs, bb, js, b.customerAccount, #debit, r.currency, r.amount, day)) { case (#err(e)) return #err(e); case (#ok((l, _, _))) List.add(legs, l) };
      List.add(legs, Posting.leg(pol.billsDiscounted, ?sub, #credit, r.currency, r.amount));
      if (left > 0) { List.add(legs, Posting.leg(pol.unearnedDiscount, ?sub, #debit, r.currency, left)); List.add(legs, Posting.leg(pol.discountIncome, null, #credit, r.currency, left)) };
    } else {
      List.add(legs, Posting.leg(pol.billLosses, null, #debit, r.currency, r.amount - left));
      if (left > 0) List.add(legs, Posting.leg(pol.unearnedDiscount, ?sub, #debit, r.currency, left));
      List.add(legs, Posting.leg(pol.billsDiscounted, ?sub, #credit, r.currency, r.amount));
    };
    if (r.state == #rediscounted) {
      List.add(legs, Posting.leg(pol.billsRediscounted, ?sub, #debit, r.currency, r.amount));
      List.add(legs, Posting.leg(pol.nostro, null, #credit, r.currency, r.amount));
    };
    #ok(List.toArray(legs))
  };

  /// End of day, job 13 (`trade`): per open instrument of the book — the commission or discount earned to the day
  /// (cumulative, straight-line from issue to expiry, so rounding never drifts), a guarantee's recorded reduction
  /// fallen due, a deferred payment or acceptance fallen due (settled as `settleAcceptance` would), a bill matured
  /// (settled as `settleBill` would), and an undertaking past its effective expiry with no claim pending (its
  /// margin returned, its memorandum reversed, its commission earned out) — each a posting and a block only when the
  /// figure is not zero.
  func jobTrade(
    bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, now : Nat64,
    acc : ChunkAcc, item : Batch.PlanItem, index : Nat, day : ProdT.Day, period : JT.PeriodId, book : Text, only : ?Text,
  ) {
    let ?pol = TradeCore.policy(bs.trade) else { fail(acc, index, item.job, book, "no trade policy"); return };
    let calendar = JCore.calendar(js);
    func post(kind : Text, id : Nat, legs : [JT.Leg], narration : Text) : Bool {
      if (legs.size() == 0) return true;
      if (not Posting.balances(legs)) { fail(acc, index, item.job, Nat.toText(id), kind # ": the legs do not balance"); return false };
      let input : JT.PostingInput = { idempotencyKey = Posting.key(kind, [Nat.toText(id), Nat.toText(day)]); postingDate = day; valueDate = day; period; legs; sourceRef = { kind; id = Nat.toText(id) # "/" # Nat.toText(day) }; narration; correctionOf = null };
      switch (batchPost(js, jb, journalCaller, now, acc, input)) { case (?why) { fail(acc, index, item.job, Nat.toText(id), why); false }; case null true }
    };
    // the blocks this run records fold after the chunk: what step 1 earns is carried here so the steps after it
    // read the figure as it will stand, not the row as it was
    let earnedNow = List.empty<(Nat, Nat)>();
    func rowNow(r : TradeCore.InstrumentRow) : TradeCore.InstrumentRow {
      for ((id, e) in List.values(earnedNow)) { if (id == r.id) return { r with commissionEarned = e } };
      r
    };
    for (r in TradeCore.openInBook(bs.trade, book).vals()) {
      let mine = switch (only) { case null true; case (?e) Text.equal(e, Nat.toText(r.id)) };
      if (not mine) continue;
      acc.examined += 1;
      // 1. commission (undertakings) or discount (bills) earned to the day
      if (r.commissionTotal > 0 and (r.kind == 1 or r.kind == 2 or r.kind == 4)) {
        let earned = TradeCore.earnedBy(r.commissionTotal, r.issuedDay, r.expiry, day);
        if (earned > r.commissionEarned) {
          let delta = earned - r.commissionEarned;
          let legs = if (r.kind == 4) [Posting.leg(pol.unearnedDiscount, ?TradeCore.billSub(r.id), #debit, r.currency, delta), Posting.leg(pol.discountIncome, null, #credit, r.currency, delta)]
                     else [Posting.leg(pol.unearnedCommission, ?TradeCore.commissionSub(r.id), #debit, r.currency, delta), Posting.leg(pol.commissionIncome, null, #credit, r.currency, delta)];
          if (post(if (r.kind == 4) "discount-earned" else "commission-earned", r.id, legs, "earned to day " # Nat.toText(day))) {
            record(acc, if (r.kind == 4) #trade(#discountEarned({ instrument = r.id; amount = delta; cumulative = earned; day })) else #trade(#commissionEarned({ instrument = r.id; amount = delta; cumulative = earned; day })));
            List.add(earnedNow, (r.id, earned));
          };
        };
      };
      // 2. a guarantee's recorded reduction fallen due
      if (r.kind == 2) {
        switch (tradeKindOf(bb, r.id)) {
          case (?#guarantee(g)) {
            switch (TradeCore.reductionDue(g, r, day)) {
              case (?to) {
                switch (TradeCore.planReduce(bs.trade, r.id, to, day)) {
                  case (#ok(ev)) { if (post("guarantee-reduce", r.id, memoLegs(pol, pol.contingentGuarantees, r.currency, r.amount - to, false), "reduction due")) record(acc, #trade(ev)) };
                  case (#err(_)) {};
                };
              };
              case null {};
            };
          };
          case (_) {};
        };
      };
      // 3. a deferred payment, acceptance or negotiation fallen due
      if (r.kind == 1) {
        switch (tradeKindOf(bb, r.id)) {
          case (?#letterOfCredit(lc)) {
            for (c in TradeCore.claimsOf(bs.trade, r.id).vals()) {
              if (c.state == #honoured and c.honour != 1 and c.settledBlock == 0 and c.due <= day) {
                switch (TradeCore.planMature(bs.trade, r.id, c.seq, day)) {
                  case (#ok(ev)) {
                    switch (settleAcceptanceLegs(bs, bb, js, journalCaller, pol, r, lc, c, c.amount, day, 0)) {
                      case (#ok(p)) {
                        let ev2 : TrT.TradeEvent = switch (ev) { case (#acceptanceMatured(m)) #acceptanceMatured({ m with fromMargin = p.fromMargin }); case (e) e };
                        if (p.extra.size() == 0 and post("lc-settle", r.id, p.legs, "due day " # Nat.toText(c.due))) record(acc, #trade(ev2)) else if (p.extra.size() > 0) fail(acc, index, item.job, Nat.toText(r.id), "the applicant cannot settle the acceptance: a claim needs the dual act settleAcceptance")
                      };
                      case (#err(e)) fail(acc, index, item.job, Nat.toText(r.id), debug_show e);
                    };
                  };
                  case (#err(_)) {};
                };
              };
            };
          };
          case (_) {};
        };
      };
      // 4. a bill matured: the acceptor pays
      if (r.kind == 4 and day >= r.expiry) {
        switch (tradeKindOf(bb, r.id)) {
          case (?#bill(b)) {
            switch (TradeCore.planBillMatured(bs.trade, r.id, day)) {
              case (#ok((ev, _))) {
                switch (billEndLegs(bs, bb, js, pol, rowNow(r), b, false, day)) {
                  case (#ok(legs)) { if (post("bill-settle", r.id, legs, "matured")) record(acc, #trade(ev)) };
                  case (#err(e)) fail(acc, index, item.job, Nat.toText(r.id), debug_show e);
                };
              };
              case (#err(_)) {};
            };
          };
          case (_) {};
        };
      };
    };
    // 5. undertakings past their effective expiry with nothing pending
    for (r in TradeCore.expiredBy(bs.trade, calendar, day).vals()) {
      if (not Text.equal(r.book, book)) continue;
      let mine = switch (only) { case null true; case (?e) Text.equal(e, Nat.toText(r.id)) };
      if (not mine) continue;
      // step 1 may have earned commission on this row in this run: the end legs earn what is left after it
      let fresh = rowNow(r);
      switch (endLegs(bs, bb, js, pol, fresh, day)) {
        case (#ok(legs)) {
          if (post("trade-expire", r.id, legs, "expired " # Nat.toText(r.expiry))) {
            let ev : TrT.TradeEvent = if (r.kind == 1) #lcExpired({ instrument = r.id; expiry = r.expiry; marginReleased = fresh.margin; day }) else #guaranteeExpired({ instrument = r.id; expiry = r.expiry; marginReleased = fresh.margin; day });
            record(acc, #trade(ev));
          };
        };
        case (#err(e)) fail(acc, index, item.job, Nat.toText(r.id), debug_show e);
      };
    };
  };

  // ─── branch and teller (branch and teller): the planners' helpers ───────────────────────

  func tellerPlan(r : Result.Result<TeT.TellerEvent, TeT.TellerError>) : Result.Result<Plan, T.BankError> {
    switch (r) { case (#err(e)) #err(#TellerError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#teller(ev); extra = []; journal = [] }) }
  };
  /// The control account of a till product in the currency: the vault's account for the book's cash.
  func tillProductControl(bs : State, product : ProdT.ProductId, currency : JT.Currency) : Result.Result<JT.AccountCode, T.BankError> {
    let ?v = ProductCore.currentVersion(bs.product, product) else return #err(#ProductError({ error = #UnknownProduct({ product }) }));
    if (v.terms.kind != #till) return #err(#ProductError({ error = #AccountNotOfKind({ account = 0; expected = "till"; actual = debug_show (v.terms.kind) }) }));
    if (not Text.equal(v.terms.currency, currency)) return #err(#ProductError({ error = #CurrencyMismatch({ expected = v.terms.currency; actual = currency }) }));
    #ok(v.terms.control)
  };
  /// A customer's deposit account, for a chequebook or a draft.
  func depositAccount(bs : State, bb : Blocks, id : ProdT.AccountId) : Result.Result<(ProductCore.AccountEntry, ProdT.ProductTerms), T.BankError> {
    switch (requireAccount(bs, bb, id)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        if (terms.kind == #loan or terms.kind == #till) return #err(#ProductError({ error = #AccountNotOfKind({ account = id; expected = "a deposit account"; actual = debug_show (terms.kind) }) }));
        #ok((a, terms))
      };
    }
  };
  /// The cash leg of a draft: a till's drawer (open, the currency's) or a customer's account that may move.
  func cashSourceLeg(bs : State, bb : Blocks, js : JCore.State, source : TeT.CashSource, currency : JT.Currency, side : JT.Side, amount : Nat, day : Nat) : Result.Result<JT.Leg, T.BankError> {
    switch (source) {
      case (#till(id)) {
        let (till, terms) = switch (openTill(bs, bb, id)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        if (till.status != #open) return #err(#ProductError({ error = #TillNotOpen({ till = id; status = till.status }) }));
        if (not Text.equal(till.currency, currency)) return #err(#ProductError({ error = #CurrencyMismatch({ expected = currency; actual = till.currency }) }));
        #ok(Posting.leg(terms.control, ?till.subledger, side, currency, amount))
      };
      case (#account(id)) {
        let (a, terms) = switch (movableAccount(bs, bb, js, id, day)) { case (#err(e)) return #err(e); case (#ok(p)) p };
        if (terms.kind == #loan) return #err(#ProductError({ error = #AccountNotOfKind({ account = id; expected = "a deposit account"; actual = "loan" }) }));
        if (not Text.equal(a.currency, currency)) return #err(#ProductError({ error = #CurrencyMismatch({ expected = currency; actual = a.currency }) }));
        #ok(Posting.leg(terms.control, ?a.subledger, side, currency, amount))
      };
    }
  };
  /// A cheque presented: returned at once when stopped, stale or post-dated; otherwise held — the journal's own
  /// pending posting from the drawer to the till or the clearing house, expiring with the clearing window.
  func planPresentCheque(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, authId : Text, x : { account : ProdT.AccountId; serial : Nat; amount : Nat; payee : TeT.Payee; chequeDate : Nat; imageHash : Blob; postingDate : Nat; valueDate : Nat; period : Text; narration : Text }) : Result.Result<Plan, T.BankError> {
    let ?pol = TellerCore.policy(bs.teller) else return #err(#TellerError({ error = #NoPolicy }));
    if (x.amount == 0) return #err(#TellerError({ error = #InvalidRequest({ reason = "a cheque for nothing" }) }));
    if (x.imageHash.size() != 32) return #err(#TellerError({ error = #InvalidRequest({ reason = "the image hash is 32 bytes" }) }));
    let (a, terms) = switch (depositAccount(bs, bb, x.account)) { case (#err(e)) return #err(e); case (#ok(p)) p };
    let today = JCore.effectiveToday(js, now);
    switch (TellerCore.presentationFate(bs.teller, x.account, x.serial, x.chequeDate, today)) {
      case (#err(e)) #err(#TellerError({ error = e }));
      case (#ok(?reason)) #ok({ bankEvent = ?#teller(#chequeReturned({ account = x.account; serial = x.serial; amount = x.amount; reason; day = today })); extra = []; journal = [] });
      case (#ok(null)) {
        let sink = switch (x.payee) {
          case (#inBranch(p)) { switch (cashSourceLeg(bs, bb, js, #till(p.till), a.currency, #credit, x.amount, x.postingDate)) { case (#err(e)) return #err(e); case (#ok(l)) l } };
          case (#clearing(_)) Posting.leg(pol.clearing, null, #credit, a.currency, x.amount);
        };
        let valueDate = switch (valueDateGate(bs, js, a.book, x.period, terms.valueDateConvention, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
        let input = Posting.simple("cheque", [authId, Nat.toText(x.account), Nat.toText(x.serial)], Posting.leg(terms.control, ?a.subledger, #debit, a.currency, x.amount), sink, x.postingDate, valueDate, x.period, x.narration);
        let expiresAt = now + Nat64.fromNat(pol.clearingWindowDays) * 86_400_000_000_000;
        switch (JCore.prepareReserve(js, journalCaller, now, input, ?expiresAt)) {
          case (#err(e)) #err(#JournalError({ error = e }));
          case (#ok(#duplicate(_))) #err(#TellerError({ error = #ChequeNotIn({ account = x.account; serial = x.serial; state = "held"; wanted = "unused" }) }));
          case (#ok(#event(ev))) #ok({
            bankEvent = ?#teller(#chequePresented({ account = x.account; serial = x.serial; amount = x.amount; payee = x.payee; chequeDate = x.chequeDate; imageHash = x.imageHash; hold = JCore.height(js); expiresAt = today + pol.clearingWindowDays; day = today }));
            extra = []; journal = [#event(ev)];
          });
        }
      };
    }
  };

  // ─── corporate lending (corporate lending): the facility's planners ──────────────────────

  func facilityPlan(r : Result.Result<FaT.FacilityEvent, FaT.FacilityError>) : Result.Result<Plan, T.BankError> {
    switch (r) { case (#err(e)) #err(#FacilityError({ error = e })); case (#ok(ev)) #ok({ bankEvent = ?#facility(ev); extra = []; journal = [] }) }
  };
  func facilitySub(id : FaT.FacilityId) : JT.SubledgerKey { FacilityCore.facilitySub(id) };
  func participantSub(id : FaT.FacilityId, p : PT.PartyId) : JT.SubledgerKey { FacilityCore.participantSub(id, p) };
  /// The terms of the loan product a facility's drawings are accounts of.
  func facilityTerms(bs : State, r : FacilityCore.Row) : ?ProdT.ProductTerms {
    switch (ProductCore.currentVersion(bs.product, r.product)) { case (?v) ?v.terms; case null null }
  };
  /// The facility's opening block, where the covenants, the collateral and the agent's key live.
  func facilityTermsBlock(bb : Blocks, id : FaT.FacilityId) : ?FaT.Terms {
    switch (bb.get(id)) { case (?b) { switch (b.event) { case (#facility(#facilityOpened(x))) ?x.terms; case (_) null } }; case null null }
  };
  /// What a facility had drawn on a day: the outstanding principal of every drawing it ever made, read from the
  /// journal as of that day — a drawing since repaid still counts for the days it stood, which is what a clean-down
  /// window judged after the fact needs; today it reads as zero.
  public func facilityDrawnOn(bs : State, bb : Blocks, js : JCore.State, id : FaT.FacilityId, day : Nat) : Nat { facilityDrawn(bs, bb, js, id, day) };
  func facilityDrawn(bs : State, bb : Blocks, js : JCore.State, id : FaT.FacilityId, day : Nat) : Nat {
    var drawn = 0;
    for ((acct, _) in FacilityCore.drawingsOf(bs.facility, id).vals()) {
      switch (ProductCore.get(bs.product, productBlocks(bb), acct)) {
        case (?a) { switch (ProductCore.termsOf(bs.product, a)) { case (?terms) drawn += Posting.accountBalanceOn(js, terms.control, a.subledger, a.currency, #debit, day).net; case null {} } };
        case null {};
      };
    };
    drawn
  };
  func roleOf(terms : ProdT.ProductTerms, product : Text, role : ProdT.Role) : Result.Result<JT.AccountCode, T.BankError> {
    switch (Products.roleAccount(terms, role)) { case (?c) #ok(c); case null #err(#ProductError({ error = #RoleUnmapped({ product; role = ProdT.roleText(role) }) })) }
  };

  /// A facility opened: the terms validated, the party active and in the book, the product a loan product in the
  /// currency whose mapping carries the roles the kind posts to, the participants and the client account real.
  func planOpenFacility(bs : State, bb : Blocks, js : JCore.State, terms : FaT.Terms, today : Nat) : Result.Result<Plan, T.BankError> {
    switch (FacilityCore.validTerms(terms)) { case (?reason) return #err(#FacilityError({ error = #InvalidTerms({ reason }) })); case null {} };
    switch (requireOpenBook(bs, terms.book)) { case (?e) return #err(e); case null {} };
    let ?pe = PartyCore.get(bs.party, partyBlocks(bb), terms.party) else return #err(#PartyError({ error = #UnknownParty({ party = terms.party }) }));
    if (not Text.equal(pe.book, terms.book)) return #err(#FacilityError({ error = #InvalidTerms({ reason = "the facility's book is not the party's" }) }));
    if (pe.lifecycle != #active) return #err(#PartyError({ error = #PartyNotActive({ party = terms.party; lifecycle = pe.lifecycle }) }));
    let ?v = ProductCore.currentVersion(bs.product, terms.product) else return #err(#ProductError({ error = #UnknownProduct({ product = terms.product }) }));
    if (v.terms.kind != #loan) return #err(#FacilityError({ error = #InvalidTerms({ reason = "a facility's drawings are accounts of a loan product" }) }));
    if (not Text.equal(v.terms.currency, terms.currency)) return #err(#ProductError({ error = #CurrencyMismatch({ expected = v.terms.currency; actual = terms.currency }) }));
    let needed : [ProdT.Role] = switch (terms.kind) {
      case (#bilateralTerm) []; case (#revolving(_)) [#feeReceivable, #feeIncome];
      case (#syndicatedAgent(_)) [#dueToParticipants, #participantPayable]; case (#syndicatedParticipant(_)) [];
      case (#financeLease(_)) [#impairmentExpense, #allowance]; case (#operatingLease(_)) [#rentReceivable, #rentalIncome];
      case (#factoring(_)) [#purchasedReceivables, #retentionPayable, #unearnedDiscount, #discountIncome, #writeOff];
      case (#forfaiting(_)) [#purchasedReceivables, #unearnedDiscount, #discountIncome, #writeOff];
    };
    for (role in needed.vals()) { switch (roleOf(v.terms, terms.product, role)) { case (#err(e)) return #err(e); case (#ok(_)) {} } };
    switch (terms.kind) {
      case (#syndicatedAgent(x)) { for (sh in x.shares.vals()) { switch (requireParty(bs, sh.participant)) { case (?e) return #err(e); case null {} } } };
      case (#syndicatedParticipant(x)) { switch (JCore.getAccount(js, x.agentAccount)) { case null return #err(#ProductError({ error = #RoleAccountUnknown({ role = "agentAccount"; account = x.agentAccount }) })); case (?_) {} } };
      case (#financeLease(x)) { switch (JCore.getAccount(js, x.assetAccount)) { case null return #err(#ProductError({ error = #RoleAccountUnknown({ role = "assetAccount"; account = x.assetAccount }) })); case (?_) {} } };
      case (#factoring(x)) { switch (clientAccount(bs, bb, x.clientAccount, terms.party, terms.currency)) { case (#err(e)) return #err(e); case (#ok(_)) {} } };
      case (#forfaiting(x)) { switch (clientAccount(bs, bb, x.clientAccount, terms.party, terms.currency)) { case (#err(e)) return #err(e); case (#ok(_)) {} } };
      case (_) {};
    };
    for (c in terms.collateral.vals()) { if (PartyCore.collateralPartyOf(bs.party, c) != ?terms.party) return #err(#FacilityError({ error = #InvalidTerms({ reason = "collateral " # Nat.toText(c) # " is not the party's" }) })) };
    #ok({ bankEvent = ?#facility(#facilityOpened({ terms; day = today })); extra = []; journal = [] })
  };

  /// The client's deposit account a factoring facility advances into: the party's, active, in the currency.
  func clientAccount(bs : State, bb : Blocks, id : ProdT.AccountId, party : PT.PartyId, currency : Text) : Result.Result<(ProductCore.AccountEntry, ProdT.ProductTerms), T.BankError> {
    switch (requireAccount(bs, bb, id)) {
      case (#err(e)) #err(e);
      case (#ok((a, terms))) {
        if (a.party != party) return #err(#FacilityError({ error = #InvalidTerms({ reason = "the client account is not the party's" }) }));
        if (a.status != #active) return #err(#ProductError({ error = #AccountNotActive({ account = id; status = a.status }) }));
        if (terms.kind == #loan or terms.kind == #till) return #err(#ProductError({ error = #AccountNotOfKind({ account = id; expected = "a deposit account"; actual = debug_show (terms.kind) }) }));
        if (not Text.equal(a.currency, currency)) return #err(#ProductError({ error = #CurrencyMismatch({ expected = currency; actual = a.currency }) }));
        #ok((a, terms))
      };
    }
  };

  /// A drawing: the aggregate limit checked against the journal, the rate from the pricing, a loan account opened
  /// under the existing planner at that rate and activated, the disbursement posted — funded by the bank alone, or
  /// by the syndicate's shares with the participants' parts credited to what the agent owes them; a finance
  /// lease's drawing is the asset moving into the net investment, its schedule carrying the residual as a balloon.
  func planDrawdown(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, authId : Text, m : T.FacilityMoney, authorityIndex : Nat, byNotice : Bool) : Result.Result<Plan, T.BankError> {
    switch (requireFeature(bs, ProdT.FEATURE_CREDIT)) { case (?e) return #err(e); case null {} };
    let drawn = facilityDrawn(bs, bb, js, m.facility, m.valueDate) + TradeCore.contingentOnFacility(bs.trade, m.facility);
    let r = switch (FacilityCore.admitDrawdown(bs.facility, m.facility, m.amount, drawn, m.valueDate, byNotice)) { case (#err(e)) return #err(#FacilityError({ error = e })); case (#ok(r)) r };
    let ?terms = facilityTerms(bs, r) else return #err(#ProductError({ error = #UnknownProduct({ product = r.product }) }));
    let ?pe = PartyCore.get(bs.party, partyBlocks(bb), r.party) else return #err(#PartyError({ error = #UnknownParty({ party = r.party }) }));
    let priced = switch (FacilityCore.rateFor(bs.facility, r, m.valueDate)) { case (#err(e)) return #err(#FacilityError({ error = e })); case (#ok(p)) p };
    let rate : I.Rate = { numerator = priced.rateBps; denominator = 10_000; negative = false };
    let accountId = bs.height;
    let opened = switch (planOpenAccount(bs, js, journalCaller, r.product, r.party, pe.book, r.currency, null, [], ?rate, authorityIndex, [])) { case (#err(e)) return #err(e); case (#ok(o)) o };
    let ?sch = terms.schedule else return #err(#ProductError({ error = #ScheduleRequired({ product = r.product }) }));
    let valueDate = switch (valueDateGate(bs, js, r.book, m.period, terms.valueDateConvention, m.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
    // a finance lease's schedule carries the residual as the balloon the lessee does not pay
    let schTerms : ProdT.ScheduleTerms = switch (r.kind) { case (#financeLease(l)) ({ sch with amortisation = #balloon({ finalPrincipal = l.residual }) }); case (_) sch };
    let generated = Products.schedule(m.amount, rate, schTerms, terms.rounding, valueDate);
    let faults = Products.scheduleFaults(m.amount, generated.rows);
    if (faults.size() > 0) return #err(#ProductError({ error = #InvalidSchedule({ reason = faults[0] }) }));
    let sub = Posting.subledgerOf(opened.identifier);
    let legs = List.empty<JT.Leg>();
    List.add(legs, Posting.leg(terms.control, ?sub, #debit, r.currency, m.amount));
    var splits : [(PT.PartyId, Nat)] = [];
    switch (r.kind) {
      case (#syndicatedAgent(_)) {
        let shares = FacilityCore.sharesOf(bs.facility, m.facility);
        let alloc = FacilityCore.allocate(shares, m.amount);
        let due = switch (roleOf(terms, r.product, #dueToParticipants)) { case (#err(e)) return #err(e); case (#ok(c)) c };
        switch (fundingLeg(bs, bb, js, terms, m.funding, r.currency, #credit, alloc.own)) { case (#err(e)) return #err(e); case (#ok(l)) List.add(legs, l) };
        for ((p, part) in alloc.parts.vals()) { if (part > 0) List.add(legs, Posting.leg(due, ?participantSub(m.facility, p), #credit, r.currency, part)) };
        splits := alloc.parts;
      };
      case (#financeLease(l)) List.add(legs, Posting.leg(l.assetAccount, null, #credit, r.currency, m.amount));
      case (_) { switch (fundingLeg(bs, bb, js, terms, m.funding, r.currency, #credit, m.amount)) { case (#err(e)) return #err(e); case (#ok(l)) List.add(legs, l) } };
    };
    let posting = switch (postLegs(js, journalCaller, now, "drawdown", [authId, Nat.toText(m.facility), Nat.toText(accountId)], List.toArray(legs), m.postingDate, valueDate, m.period, m.narration)) { case (#err(e)) return #err(e); case (#ok(p)) p };
    if (not accountTransitionAllowed(#pending, #active)) return #err(#ProductError({ error = #AccountNotActive({ account = accountId; status = #pending }) }));
    #ok({
      bankEvent = ?#product(opened.opened);
      extra = [#product(#accountStatusSet({ account = accountId; to = #active })),
               #product(#loanDisbursed({ account = accountId; amount = m.amount; day = valueDate; schedule = generated.rows })),
               #facility(#drawn({ facility = m.facility; account = accountId; amount = m.amount; rateBps = priced.rateBps; day = valueDate; splits }))];
      journal = Array.concat<JournalStep>([#event(opened.limit)], posting.journal);
    })
  };

  /// What the agent pays its participants: each one's payable balance, in one posting.
  func planDistribute(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, authId : Text, x : { facility : FaT.FacilityId; funding : ProdT.Funding; postingDate : Nat; valueDate : Nat; period : Text; narration : Text }) : Result.Result<Plan, T.BankError> {
    let ?r = FacilityCore.row(bs.facility, x.facility) else return #err(#FacilityError({ error = #UnknownFacility({ facility = x.facility }) }));
    switch (r.kind) { case (#syndicatedAgent(_)) {}; case (k) return #err(#FacilityError({ error = #WrongKind({ facility = x.facility; kind = FaT.kindText(k); wanted = "syndicatedAgent" }) })) };
    let ?terms = facilityTerms(bs, r) else return #err(#ProductError({ error = #UnknownProduct({ product = r.product }) }));
    let payable = switch (roleOf(terms, r.product, #participantPayable)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let valueDate = switch (valueDateGate(bs, js, r.book, x.period, terms.valueDateConvention, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
    let legs = List.empty<JT.Leg>();
    let amounts = List.empty<(PT.PartyId, Nat)>();
    var total = 0;
    for (sh in FacilityCore.sharesOf(bs.facility, x.facility).vals()) {
      let owed = Posting.accountBalanceOn(js, payable, participantSub(x.facility, sh.participant), r.currency, #credit, valueDate).net;
      if (owed > 0) { List.add(legs, Posting.leg(payable, ?participantSub(x.facility, sh.participant), #debit, r.currency, owed)); List.add(amounts, (sh.participant, owed)); total += owed };
    };
    if (total == 0) return #err(#FacilityError({ error = #InvalidTerms({ reason = "nothing is payable to the participants" }) }));
    switch (fundingLeg(bs, bb, js, terms, x.funding, r.currency, #credit, total)) { case (#err(e)) return #err(e); case (#ok(l)) List.add(legs, l) };
    switch (postLegs(js, journalCaller, now, "distribution", [authId, Nat.toText(x.facility), Nat.toText(valueDate)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration)) {
      case (#err(e)) #err(e);
      case (#ok(plan)) #ok({ bankEvent = ?#facility(#distributedToParticipants({ facility = x.facility; day = valueDate; amounts = List.toArray(amounts) })); extra = []; journal = plan.journal });
    }
  };

  /// A repayment on a syndicated drawing shares what was received: the principal part moves from what the
  /// agent owes for the funding to what is payable, the interest part from the bank's income to what is payable.
  func syndicationOnRepayment(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, authId : Text, account : ProdT.AccountId, applied : ProdT.Allocation, m : T.MoneyMove, valueDate : Nat) : Result.Result<?{ event : T.Event; journal : [JournalStep] }, T.BankError> {
    let ?fid = FacilityCore.facilityOfDrawing(bs.facility, account) else return #ok(null);
    let ?r = FacilityCore.row(bs.facility, fid) else return #ok(null);
    switch (r.kind) { case (#syndicatedAgent(_)) {}; case (_) return #ok(null) };
    let ?terms = facilityTerms(bs, r) else return #err(#ProductError({ error = #UnknownProduct({ product = r.product }) }));
    let due = switch (roleOf(terms, r.product, #dueToParticipants)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let payable = switch (roleOf(terms, r.product, #participantPayable)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let income = switch (roleOf(terms, r.product, #interestIncome)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let shares = FacilityCore.sharesOf(bs.facility, fid);
    let principalParts = FacilityCore.allocate(shares, applied.principal).parts;
    let interestParts = FacilityCore.allocate(shares, applied.interest).parts;
    let legs = List.empty<JT.Leg>();
    for ((p, part) in principalParts.vals()) { if (part > 0) { List.add(legs, Posting.leg(due, ?participantSub(fid, p), #debit, r.currency, part)); List.add(legs, Posting.leg(payable, ?participantSub(fid, p), #credit, r.currency, part)) } };
    var interestTotal = 0;
    for ((p, part) in interestParts.vals()) { if (part > 0) { List.add(legs, Posting.leg(payable, ?participantSub(fid, p), #credit, r.currency, part)); interestTotal += part } };
    if (interestTotal > 0) List.add(legs, Posting.leg(income, null, #debit, r.currency, interestTotal));
    let ev : T.Event = #facility(#drawingRepaid({ facility = fid; account; amount = m.amount; day = valueDate; interestShared = interestParts }));
    if (List.size(legs) == 0) return #ok(?{ event = ev; journal = [] });
    switch (postLegs(js, journalCaller, now, "syndicate-share", [authId, Nat.toText(fid), Nat.toText(account), Nat.toText(valueDate)], List.toArray(legs), m.postingDate, valueDate, m.period, "the syndicate's share of a repayment")) {
      case (#err(e)) #err(e);
      case (#ok(plan)) #ok(?{ event = ev; journal = plan.journal });
    }
  };

  /// A finance lease's residual re-measured downwards (IFRS 16 §77): the loss against the allowance of the
  /// drawing, the schedule's balloon re-derived to the new residual at the lease's own rate.
  func planRemeasureResidual(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, authId : Text, x : { facility : FaT.FacilityId; residual : Nat; postingDate : Nat; valueDate : Nat; period : Text; narration : Text }) : Result.Result<Plan, T.BankError> {
    let ?r = FacilityCore.row(bs.facility, x.facility) else return #err(#FacilityError({ error = #UnknownFacility({ facility = x.facility }) }));
    let lease = switch (r.kind) { case (#financeLease(l)) l; case (k) return #err(#FacilityError({ error = #WrongKind({ facility = x.facility; kind = FaT.kindText(k); wanted = "financeLease" }) })) };
    if (x.residual >= lease.residual) return #err(#FacilityError({ error = #InvalidTerms({ reason = "a residual is re-measured downwards; an increase is not recognised (IFRS 16 §77)" }) }));
    let ?terms = facilityTerms(bs, r) else return #err(#ProductError({ error = #UnknownProduct({ product = r.product }) }));
    let open = Array.filter<(ProdT.AccountId, Bool)>(FacilityCore.drawingsOf(bs.facility, x.facility), func((_, o)) { o });
    if (open.size() != 1) return #err(#FacilityError({ error = #HasDrawings({ facility = x.facility; open = open.size() }) }));
    let acct = open[0].0;
    let ?a = ProductCore.get(bs.product, productBlocks(bb), acct) else return #err(#ProductError({ error = #UnknownAccount({ account = acct }) }));
    let expense = switch (roleOf(terms, r.product, #impairmentExpense)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let allowance = switch (roleOf(terms, r.product, #allowance)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let loss = lease.residual - x.residual;
    let valueDate = switch (valueDateGate(bs, js, r.book, x.period, terms.valueDateConvention, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
    let posting = switch (postLegs(js, journalCaller, now, "residual", [authId, Nat.toText(x.facility), Nat.toText(valueDate)], [Posting.leg(expense, null, #debit, r.currency, loss), Posting.leg(allowance, ?a.subledger, #credit, r.currency, loss)], x.postingDate, valueDate, x.period, x.narration)) { case (#err(e)) return #err(e); case (#ok(p)) p };
    // the balloon re-derived: the remaining instalments at the lease's rate, the new residual at the end
    let ?current = ProductCore.schedule(bs.product, productBlocks(bb), a) else return #err(#ProductError({ error = #ScheduleRequired({ product = r.product }) }));
    let ?sch = terms.schedule else return #err(#ProductError({ error = #ScheduleRequired({ product = r.product }) }));
    var remaining = 0;
    for (row in current.rows.vals()) { if (row.dueDate >= valueDate) remaining += 1 };
    if (remaining == 0) return #err(#ProductError({ error = #InvalidSchedule({ reason = "the lease has no instalment left" }) }));
    let rate : I.Rate = switch (a.openingRate) { case (?rt) rt; case null return #err(#ProductError({ error = #InvalidTerms({ reason = "the lease carries no rate" }) })) };
    let plan = switch (reschedulePlan(bs, bb, js, journalCaller, now, authId, acct, valueDate, ({ sch with amortisation = #balloon({ finalPrincipal = x.residual }); instalments = remaining; moratoriumDays = 0 } : ProdT.ScheduleTerms), rate, false)) { case (#err(e)) return #err(e); case (#ok(p)) p };
    let extra = List.empty<T.Event>();
    switch (plan.bankEvent) { case (?ev) List.add(extra, ev); case null {} };
    for (ev in plan.extra.vals()) List.add(extra, ev);
    #ok({ bankEvent = ?#facility(#residualRemeasured({ facility = x.facility; from = lease.residual; to = x.residual; day = valueDate })); extra = List.toArray(extra); journal = Array.concat<JournalStep>(posting.journal, plan.journal) })
  };

  /// Receivables bought: the faces into purchased receivables, the advance to the client's account, the
  /// retention held for the client, the discount not yet earned.
  func planPurchase(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, authId : Text, x : { facility : FaT.FacilityId; receivables : [FaT.Receivable]; postingDate : Nat; valueDate : Nat; period : Text; narration : Text }) : Result.Result<Plan, T.BankError> {
    let r = switch (FacilityCore.admitPurchase(bs.facility, x.facility, x.receivables, x.valueDate)) { case (#err(e)) return #err(#FacilityError({ error = e })); case (#ok(r)) r };
    let ?terms = facilityTerms(bs, r) else return #err(#ProductError({ error = #UnknownProduct({ product = r.product }) }));
    let clientId = switch (r.kind) { case (#factoring(f)) f.clientAccount; case (#forfaiting(f)) f.clientAccount; case (_) 0 };
    let (client, clientTerms) = switch (clientAccount(bs, bb, clientId, r.party, r.currency)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let purchased = switch (roleOf(terms, r.product, #purchasedReceivables)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let unearned = switch (roleOf(terms, r.product, #unearnedDiscount)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    var face = 0; var advance = 0; var discount = 0; var retention = 0;
    for (it in x.receivables.vals()) { let fig = FacilityCore.purchaseFigures(r.kind, it); face += it.face; advance += fig.advance; discount += fig.discount; retention += fig.retention };
    let valueDate = switch (valueDateGate(bs, js, r.book, x.period, terms.valueDateConvention, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
    let legs = List.empty<JT.Leg>();
    List.add(legs, Posting.leg(purchased, ?facilitySub(x.facility), #debit, r.currency, face));
    if (advance > 0) List.add(legs, Posting.leg(clientTerms.control, ?client.subledger, #credit, r.currency, advance));
    if (retention > 0) { let ret = switch (roleOf(terms, r.product, #retentionPayable)) { case (#err(e)) return #err(e); case (#ok(c)) c }; List.add(legs, Posting.leg(ret, ?facilitySub(x.facility), #credit, r.currency, retention)) };
    if (discount > 0) List.add(legs, Posting.leg(unearned, ?facilitySub(x.facility), #credit, r.currency, discount));
    switch (postLegs(js, journalCaller, now, "purchase", [authId, Nat.toText(x.facility), Nat.toText(valueDate)], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration)) {
      case (#err(e)) #err(e);
      case (#ok(plan)) #ok({ bankEvent = ?#facility(#receivablesPurchased({ facility = x.facility; receivables = x.receivables; face; advance; discount; retention; day = valueDate })); extra = []; journal = plan.journal });
    }
  };

  func openReceivable(bs : State, id : FaT.FacilityId, ref : Blob, wanted : [FacilityCore.ReceivableStatus]) : Result.Result<(FacilityCore.Row, FacilityCore.ReceivableRow), T.BankError> {
    let ?r = FacilityCore.row(bs.facility, id) else return #err(#FacilityError({ error = #UnknownFacility({ facility = id }) }));
    switch (r.kind) { case (#factoring(_) or #forfaiting(_)) {}; case (k) return #err(#FacilityError({ error = #WrongKind({ facility = id; kind = FaT.kindText(k); wanted = "factoring or forfaiting" }) })) };
    let ?rec = FacilityCore.receivable(bs.facility, id, ref) else return #err(#FacilityError({ error = #UnknownReceivable({ facility = id; ref }) }));
    if (Array.find<FacilityCore.ReceivableStatus>(wanted, func(s) { s == rec.status }) == null) return #err(#FacilityError({ error = #ReceivableNotOpen({ facility = id; ref }) }));
    #ok((r, rec))
  };

  /// A receivable collected from the debtor: the face in, the retention released to the client, the discount not
  /// yet earned recognised now.
  func planCollect(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, authId : Text, x : { facility : FaT.FacilityId; ref : Blob; funding : ProdT.Funding; postingDate : Nat; valueDate : Nat; period : Text; narration : Text }) : Result.Result<Plan, T.BankError> {
    let (r, rec) = switch (openReceivable(bs, x.facility, x.ref, [#open, #dishonoured])) { case (#err(e)) return #err(e); case (#ok(p)) p };
    let ?terms = facilityTerms(bs, r) else return #err(#ProductError({ error = #UnknownProduct({ product = r.product }) }));
    let clientId = switch (r.kind) { case (#factoring(f)) f.clientAccount; case (#forfaiting(f)) f.clientAccount; case (_) 0 };
    let (client, clientTerms) = switch (clientAccount(bs, bb, clientId, r.party, r.currency)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let purchased = switch (roleOf(terms, r.product, #purchasedReceivables)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let unearned = switch (roleOf(terms, r.product, #unearnedDiscount)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let income = switch (roleOf(terms, r.product, #discountIncome)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let valueDate = switch (valueDateGate(bs, js, r.book, x.period, terms.valueDateConvention, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
    let legs = List.empty<JT.Leg>();
    switch (fundingLeg(bs, bb, js, terms, x.funding, r.currency, #debit, rec.face)) { case (#err(e)) return #err(e); case (#ok(l)) List.add(legs, l) };
    List.add(legs, Posting.leg(purchased, ?facilitySub(x.facility), #credit, r.currency, rec.face));
    if (rec.retention > 0) {
      let ret = switch (roleOf(terms, r.product, #retentionPayable)) { case (#err(e)) return #err(e); case (#ok(c)) c };
      List.add(legs, Posting.leg(ret, ?facilitySub(x.facility), #debit, r.currency, rec.retention));
      List.add(legs, Posting.leg(clientTerms.control, ?client.subledger, #credit, r.currency, rec.retention));
    };
    let remaining = if (rec.discount > rec.recognised) rec.discount - rec.recognised else 0;
    if (remaining > 0) { List.add(legs, Posting.leg(unearned, ?facilitySub(x.facility), #debit, r.currency, remaining)); List.add(legs, Posting.leg(income, ?facilitySub(x.facility), #credit, r.currency, remaining)) };
    switch (postLegs(js, journalCaller, now, "collection", [authId, Nat.toText(x.facility), Nat.toText(FacilityCore.textKey(debug_show (x.ref)))], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration)) {
      case (#err(e)) #err(e);
      case (#ok(plan)) #ok({ bankEvent = ?#facility(#receivableCollected({ facility = x.facility; ref = x.ref; amount = rec.face; retentionReleased = rec.retention; day = valueDate })); extra = []; journal = plan.journal });
    }
  };

  /// A receivable dishonoured by the debtor: with recourse the client repays the advance and the earned
  /// discount, the retention and the unearned discount are released, the receivable is gone; without it the
  /// receivable stays the bank's exposure on the debtor, to be collected or written off.
  func planDishonour(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, authId : Text, x : { facility : FaT.FacilityId; ref : Blob; postingDate : Nat; valueDate : Nat; period : Text; narration : Text }) : Result.Result<Plan, T.BankError> {
    let (r, rec) = switch (openReceivable(bs, x.facility, x.ref, [#open])) { case (#err(e)) return #err(e); case (#ok(p)) p };
    let recourse = switch (r.kind) { case (#factoring(f)) f.recourse; case (_) false };
    let valueDate = switch (facilityTerms(bs, r)) { case (?terms) { switch (valueDateGate(bs, js, r.book, x.period, terms.valueDateConvention, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d } }; case null return #err(#ProductError({ error = #UnknownProduct({ product = r.product }) })) };
    if (not recourse) return #ok({ bankEvent = ?#facility(#receivableDishonoured({ facility = x.facility; ref = x.ref; face = rec.face; chargedBack = false; day = valueDate })); extra = []; journal = [] });
    let ?terms = facilityTerms(bs, r) else return #err(#ProductError({ error = #UnknownProduct({ product = r.product }) }));
    let clientId = switch (r.kind) { case (#factoring(f)) f.clientAccount; case (_) 0 };
    let (client, clientTerms) = switch (clientAccount(bs, bb, clientId, r.party, r.currency)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let purchased = switch (roleOf(terms, r.product, #purchasedReceivables)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let unearned = switch (roleOf(terms, r.product, #unearnedDiscount)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let ret = switch (roleOf(terms, r.product, #retentionPayable)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let legs = List.empty<JT.Leg>();
    let fromClient = rec.advance + rec.recognised;
    if (fromClient > 0) List.add(legs, Posting.leg(clientTerms.control, ?client.subledger, #debit, r.currency, fromClient));
    if (rec.retention > 0) List.add(legs, Posting.leg(ret, ?facilitySub(x.facility), #debit, r.currency, rec.retention));
    let unearnedLeft = if (rec.discount > rec.recognised) rec.discount - rec.recognised else 0;
    if (unearnedLeft > 0) List.add(legs, Posting.leg(unearned, ?facilitySub(x.facility), #debit, r.currency, unearnedLeft));
    List.add(legs, Posting.leg(purchased, ?facilitySub(x.facility), #credit, r.currency, rec.face));
    switch (postLegs(js, journalCaller, now, "chargeback", [authId, Nat.toText(x.facility), Nat.toText(FacilityCore.textKey(debug_show (x.ref)))], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration)) {
      case (#err(e)) #err(e);
      case (#ok(plan)) #ok({ bankEvent = ?#facility(#receivableDishonoured({ facility = x.facility; ref = x.ref; face = rec.face; chargedBack = true; day = valueDate })); extra = []; journal = plan.journal });
    }
  };

  /// A dishonoured receivable without recourse written off: the advance and the earned discount are the loss,
  /// the retention never falls due to the client, the unearned discount is released.
  func planWriteOffReceivable(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, authId : Text, x : { facility : FaT.FacilityId; ref : Blob; postingDate : Nat; valueDate : Nat; period : Text; narration : Text }) : Result.Result<Plan, T.BankError> {
    let (r, rec) = switch (openReceivable(bs, x.facility, x.ref, [#dishonoured])) { case (#err(e)) return #err(e); case (#ok(p)) p };
    let ?terms = facilityTerms(bs, r) else return #err(#ProductError({ error = #UnknownProduct({ product = r.product }) }));
    let purchased = switch (roleOf(terms, r.product, #purchasedReceivables)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let unearned = switch (roleOf(terms, r.product, #unearnedDiscount)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let writeOff = switch (roleOf(terms, r.product, #writeOff)) { case (#err(e)) return #err(e); case (#ok(c)) c };
    let valueDate = switch (valueDateGate(bs, js, r.book, x.period, terms.valueDateConvention, x.valueDate)) { case (#err(e)) return #err(e); case (#ok(d)) d };
    let legs = List.empty<JT.Leg>();
    let loss = rec.advance + rec.recognised;
    if (loss > 0) List.add(legs, Posting.leg(writeOff, null, #debit, r.currency, loss));
    if (rec.retention > 0) { let ret = switch (roleOf(terms, r.product, #retentionPayable)) { case (#err(e)) return #err(e); case (#ok(c)) c }; List.add(legs, Posting.leg(ret, ?facilitySub(x.facility), #debit, r.currency, rec.retention)) };
    let unearnedLeft = if (rec.discount > rec.recognised) rec.discount - rec.recognised else 0;
    if (unearnedLeft > 0) List.add(legs, Posting.leg(unearned, ?facilitySub(x.facility), #debit, r.currency, unearnedLeft));
    List.add(legs, Posting.leg(purchased, ?facilitySub(x.facility), #credit, r.currency, rec.face));
    switch (postLegs(js, journalCaller, now, "receivable-writeoff", [authId, Nat.toText(x.facility), Nat.toText(FacilityCore.textKey(debug_show (x.ref)))], List.toArray(legs), x.postingDate, valueDate, x.period, x.narration)) {
      case (#err(e)) #err(e);
      case (#ok(plan)) #ok({ bankEvent = ?#facility(#receivableWrittenOff({ facility = x.facility; ref = x.ref; amount = loss; day = valueDate })); extra = []; journal = plan.journal });
    }
  };

  /// The agent's notice on a facility the bank participates in, judged by the agent's signature over the notice's
  /// canonical bytes and by the arithmetic (our share is the total by our basis points): a drawdown opens the
  /// bank's drawing funded from the agent's account; a repayment or an interest distribution repays it.
  public func planAgentNotice(bs : State, bb : Blocks, js : JCore.State, journalCaller : Principal, now : Nat64, facility : FaT.FacilityId, notice : FaT.AgentNotice, signature : Blob, verify : Verify) : Result.Result<Plan, T.BankError> {
    let ?r = FacilityCore.row(bs.facility, facility) else return #err(#FacilityError({ error = #UnknownFacility({ facility }) }));
    let ?opened = facilityTermsBlock(bb, facility) else return #err(#FacilityError({ error = #UnknownFacility({ facility }) }));
    let part = switch (opened.kind) { case (#syndicatedParticipant(p)) p; case (k) return #err(#FacilityError({ error = #WrongKind({ facility; kind = FaT.kindText(k); wanted = "syndicatedParticipant" }) })) };
    if (r.stage == #closed) return #err(#FacilityError({ error = #WrongStage({ facility; stage = "closed"; wanted = "open" }) }));
    if (not verify(part.agentScheme, part.agentKey, FCan.noticeBytes(facility, notice), signature)) return #err(#FacilityError({ error = #SignatureInvalid({ facility }) }));
    let (total, ourShare, valueDay) = switch (notice) { case (#drawdown(x)) (x.total, x.ourShare, x.valueDate); case (#repayment(x)) (x.total, x.ourShare, x.valueDate); case (#interestDistribution(x)) (x.total, x.ourShare, x.valueDate) };
    if (ourShare != total * part.ourBps / 10_000) return #err(#FacilityError({ error = #NoticeMismatch({ reason = "our share is not the total by our basis points" }) }));
    if (ourShare == 0) return #err(#FacilityError({ error = #NoticeMismatch({ reason = "a notice of nothing" }) }));
    let ?period = periodForDay(js, valueDay) else return #err(#JournalConfigError({ error = #UnknownPeriod({ id = "day " # Nat.toText(valueDay) }) }));
    let hash = FCan.noticeHash(facility, notice);
    let authId = "notice-" # Nat.toText(facility);
    switch (notice) {
      case (#drawdown(_)) {
        let m : T.FacilityMoney = { facility; amount = ourShare; funding = #glAccount(part.agentAccount); postingDate = valueDay; valueDate = valueDay; period; narration = "the bank's share of the syndicate's drawing" };
        // the drawing's limit is our participation's: the facility's limit is the bank's share of the whole
        switch (planDrawdown(bs, bb, js, journalCaller, now, authId, m, bs.height, true)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) {
            // the drawing block comes from planDrawdown; the notice block names the account it opened
            #ok({ bankEvent = plan.bankEvent; journal = plan.journal; extra = Array.concat<T.Event>(plan.extra, [#facility(#agentNoticeRecorded({ facility; notice; noticeHash = hash; account = ?bs.height }))]) })
          };
        }
      };
      case (_) {
        let open = Array.filter<(ProdT.AccountId, Bool)>(FacilityCore.drawingsOf(bs.facility, facility), func((_, o)) { o });
        if (open.size() != 1) return #err(#FacilityError({ error = #HasDrawings({ facility; open = open.size() }) }));
        let m : T.MoneyMove = { account = open[0].0; amount = ourShare; postingDate = valueDay; valueDate = valueDay; period; narration = "the bank's share of the syndicate's repayment"; funding = #glAccount(part.agentAccount) };
        switch (repayPlan(bs, bb, js, journalCaller, now, m, authId)) {
          case (#err(e)) #err(e);
          case (#ok(plan)) #ok({ bankEvent = plan.bankEvent; journal = plan.journal; extra = Array.concat<T.Event>(plan.extra, [#facility(#agentNoticeRecorded({ facility; notice; noticeHash = hash; account = null }))]) });
        }
      };
    }
  };

  func originationPlan(r : Result.Result<OT.OriginationEvent, OT.OriginationError>) : Result.Result<Plan, T.BankError> {
    switch (r) {
      case (#err(e)) #err(#OriginationError({ error = e }));
      case (#ok(ev)) #ok({ bankEvent = ?#origination(ev); extra = []; journal = [] });
    }
  };

  /// The block that says the documentation is complete, when the act just planned completes it.
  func documentationExtra(bs : State, js : JCore.State, now : Nat64, application : OT.ApplicationId, ev : OT.OriginationEvent) : [T.Event] {
    if (OriginationCore.completesDocumentation(bs.origination, application, ev)) [#origination(#documentationComplete({ application; day = JCore.effectiveToday(js, now) }))] else []
  };

  /// A collections act names a loan account that exists and has been disbursed.
  func requireLoanAccount(bs : State, bb : Blocks, account : ProdT.AccountId) : ?T.BankError {
    let ?a = ProductCore.get(bs.product, productBlocks(bb), account) else return ?#ProductError({ error = #UnknownAccount({ account }) });
    let ?terms = ProductCore.termsOf(bs.product, a) else return ?#ProductError({ error = #UnknownVersion({ product = a.product; version = a.version }) });
    if (terms.kind != #loan) return ?#CollectionsError({ error = #NotALoan({ account }) });
    null
  };

  func requireOpenBook(bs : State, book : T.BookId) : ?T.BankError {
    switch (Map.get(bs.books, Text.compare, book)) {
      case null ?#UnknownBook({ book });
      case (?b) { if (b.status == #closed) ?#BookClosed({ book }) else null };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  THE MAKER-CHECKER PATHS
  // ═══════════════════════════════════════════════════════

  public type ProposeOutcome = { event : T.Event; permission : T.PermissionId };

  /// A maker proposes. The maker must hold the command's own permission (and
  /// `command.create` on the method, checked by the actor), the command must be
  /// dual-authorised, and it must already validate against both states — a
  /// proposal that could never execute is refused at the point it is made.
  public func prepareProposal(bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, caller : Principal, now : Nat64, command : T.Command, justification : Text) : Result.Result<ProposeOutcome, { error : T.BankError; record : Bool }> {
    let perm = commandPermissionRecord(command);
    if (not MC.textFits(justification, T.MAX_JUSTIFICATION_BYTES)) {
      return #err({ error = #InvalidPolicy({ reason = "justification exceeds the bound" }); record = false });
    };
    let op = operationOf(bs, js, jb, command);
    let day = switch (commandDay(command)) { case (?d) d; case null JCore.effectiveToday(js, now) };
    switch (authorise(bs, caller, op, day)) {
      case (#err(e)) return #err({ error = e; record = recordableRefusal(bs, caller) });
      case (#ok(_)) {};
    };
    let ?policy = policyFor(bs, perm.id) else {
      return #err({ error = #InvalidPolicy({ reason = "permission " # perm.id # " is single-authority; use perform" }); record = false });
    };
    // The command must validate now. `authorityIndex` is the index this very
    // proposal block will take.
    switch (planCommand(bs, bb, js, jb, journalCaller, now, command, bs.height)) {
      case (#err(e)) return #err({ error = e; record = false });
      case (#ok(_)) {};
    };
    let hash = C.commandHash(command);
    let expiresAt = now + Nat64.fromNat(policy.ttlSeconds) * 1_000_000_000;
    #ok({
      event = #commandProposed({
        command = ?command; commandHash = hash; commandEncoding = C.COMMAND_ENCODING; permission = perm.id; book = commandBookOf(bs, command); maker = caller;
        required = policy.required; eligibleRole = policy.eligibleRole;
        expiresAt; justification;
      });
      permission = perm.id;
    })
  };

  public type ApproveOutcome = {
    approval : T.Event;
    /// Set when this approval completes the policy: the command to execute, with
    /// the proposal's own index as its authority.
    execute : ?{ command : T.Command; commandHash : Blob; permission : T.PermissionId; maker : Principal; proposal : Nat };
  };

  public func prepareApprove(bs : State, js : JCore.State, jb : JCore.Blocks, bb : Blocks, journalCaller : Principal, caller : Principal, now : Nat64, index : Nat) : Result.Result<ApproveOutcome, { error : T.BankError; record : Bool }> {
    let ?e = proposalEntry(bs, bb, index) else return #err({ error = #UnknownProposal({ index }); record = false });
    let eligible = holdsRole(bs, caller, e.eligibleRole);
    switch (MC.checkApprover(e, caller, eligible, now)) {
      case (?err) return #err({ error = err; record = recordableRefusal(bs, caller) });
      case null {};
    };
    // An awaiting proposal always carries its body: a pack drops bodies of settled proposals only.
    let ?command = e.command else Runtime.trap("BankCore: proposal " # Nat.toText(index) # " is awaiting approval without its command body");
    // The bytes the checker is approving must still be the bytes recorded — under the encoding recorded.
    let ?recomputed = C.commandHashAt(e.commandEncoding, command) else return #err({ error = #CommandHashMismatch({ recorded = e.commandHash; recomputed = "" }); record = true });
    if (not MC.hashesAgree(e.commandHash, recomputed)) {
      return #err({ error = #CommandHashMismatch({ recorded = e.commandHash; recomputed }); record = true });
    };
    let approval : T.Event = #commandApproved({ proposal = index; commandHash = recomputed; checker = caller });
    if (not MC.completesWith(e, caller)) return #ok({ approval; execute = null });
    // This approval completes the policy: the command must still validate, and
    // the maker must still be within scope and limits.
    let op = operationOf(bs, js, jb, command);
    let day = switch (commandDay(command)) { case (?d) d; case null JCore.effectiveToday(js, now) };
    switch (authorise(bs, e.maker, op, day)) {
      case (#err(err)) return #err({ error = err; record = true });
      case (#ok(_)) {};
    };
    switch (planCommand(bs, bb, js, jb, journalCaller, now, command, index)) {
      case (#err(err)) return #err({ error = err; record = false });
      case (#ok(_)) {};
    };
    #ok({ approval; execute = ?{ command; commandHash = recomputed; permission = e.permission; maker = e.maker; proposal = index } })
  };

  public func prepareReject(bs : State, bb : Blocks, caller : Principal, now : Nat64, index : Nat, reason : Text) : Result.Result<T.Event, { error : T.BankError; record : Bool }> {
    let ?e = proposalEntry(bs, bb, index) else return #err({ error = #UnknownProposal({ index }); record = false });
    if (not MC.isAwaiting(e)) return #err({ error = #ProposalNotAwaiting({ index }); record = false });
    if (not MC.textFits(reason, T.MAX_JUSTIFICATION_BYTES)) return #err({ error = #InvalidPolicy({ reason = "reason exceeds the bound" }); record = false });
    if (not holdsRole(bs, caller, e.eligibleRole)) {
      return #err({ error = #NotEligibleChecker({ checker = caller; eligibleRole = e.eligibleRole }); record = recordableRefusal(bs, caller) });
    };
    if (MC.isExpired(e, now)) return #err({ error = #ProposalExpired({ index; expiresAt = e.expiresAt }); record = true });
    #ok(#commandRejected({ proposal = index; checker = caller; reason }))
  };

  /// Proposals past their expiry, oldest first, at most `limit`.
  public func expiredProposals(bs : State, now : Nat64, limit : Nat) : [Nat] {
    let out = List.empty<Nat>();
    // The row carries the expiry, so the sweep reads no block.
    label scan for ((idx, _) in Map.entries(bs.openProposals)) {
      if (List.size(out) >= limit) break scan;
      switch (proposalRow(bs, idx)) {
        case (?r) { switch (r.status) { case (#awaiting) { if (r.expiresAt <= now) List.add(out, idx) }; case (_) {} } };
        case null {};
      };
    };
    List.toArray(out)
  };

  public func expiryEvent(index : Nat) : T.Event { #commandExpired({ proposal = index }) };

  /// A single-authority command: the caller holds the permission and the
  /// permission has no dual-authorisation policy.
  public func preparePerform(bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, caller : Principal, now : Nat64, command : T.Command) : Result.Result<{ permission : T.PermissionId }, { error : T.BankError; record : Bool }> {
    let perm = commandPermissionRecord(command);
    switch (requireUsable(bs, perm)) { case (?e) return #err({ error = e; record = false }); case null {} };
    switch (policyFor(bs, perm.id)) {
      case (?p) return #err({ error = #RequiresDualAuthorisation({ permission = perm.id; required = p.required }); record = false });
      case null {};
    };
    let op = operationOf(bs, js, jb, command);
    let day = switch (commandDay(command)) { case (?d) d; case null JCore.effectiveToday(js, now) };
    switch (authorise(bs, caller, op, day)) {
      case (#err(e)) return #err({ error = e; record = recordableRefusal(bs, caller) });
      case (#ok(_)) {};
    };
    switch (planCommand(bs, bb, js, jb, journalCaller, now, command, bs.height)) {
      case (#err(e)) return #err({ error = e; record = false });
      case (#ok(_)) {};
    };
    #ok({ permission = perm.id })
  };

  /// The emergency path. Not a bypass of dual control: a distinct permission no
  /// operational role carries, a named witness who must hold the eligible role of
  /// the command's own policy, and a review item that blocks the period close
  /// until a disposition is recorded.
  public func prepareOverride(bs : State, bb : Blocks, js : JCore.State, jb : JCore.Blocks, journalCaller : Principal, caller : Principal, now : Nat64, command : T.Command, witness : Principal, justification : Text) : Result.Result<{ event : T.Event; permission : T.PermissionId }, { error : T.BankError; record : Bool }> {
    let perm = commandPermissionRecord(command);
    if (not MC.textFits(justification, T.MAX_JUSTIFICATION_BYTES)) return #err({ error = #InvalidPolicy({ reason = "justification exceeds the bound" }); record = false });
    if (Text.encodeUtf8(justification).size() == 0) return #err({ error = #InvalidPolicy({ reason = "an override requires a justification" }); record = false });
    if (Principal.isAnonymous(witness)) return #err({ error = #WitnessRequired; record = false });
    if (Principal.equal(witness, caller)) return #err({ error = #WitnessIsActor; record = recordableRefusal(bs, caller) });
    // The witness must be someone who could have approved the command.
    switch (policyFor(bs, perm.id)) {
      case (?p) {
        if (not holdsRole(bs, witness, p.eligibleRole)) {
          return #err({ error = #WitnessNotEligible({ witness }); record = recordableRefusal(bs, caller) });
        };
      };
      case null return #err({ error = #InvalidPolicy({ reason = "permission " # perm.id # " has no dual policy; it needs no override" }); record = false });
    };
    // The actor needs the break-glass permission *and* the command's own
    // permission with its scope: an override relaxes who approves, never what
    // the actor was entitled to do. Both are checked here rather than only in the
    // actor's method gate, so the core function is sound on its own.
    let breakGlass : E.Operation = { permission = "command.breakGlass"; book = null; totals = [] };
    switch (authorise(bs, caller, breakGlass, 0)) {
      case (#err(e)) return #err({ error = e; record = recordableRefusal(bs, caller) });
      case (#ok(_)) {};
    };
    let op = operationOf(bs, js, jb, command);
    let day = switch (commandDay(command)) { case (?d) d; case null JCore.effectiveToday(js, now) };
    switch (authorise(bs, caller, op, day)) {
      case (#err(e)) return #err({ error = e; record = recordableRefusal(bs, caller) });
      case (#ok(_)) {};
    };
    switch (planCommand(bs, bb, js, jb, journalCaller, now, command, bs.height)) {
      case (#err(e)) return #err({ error = e; record = false });
      case (#ok(_)) {};
    };
    #ok({
      event = #emergencyOverride({ command; commandEncoding = C.COMMAND_ENCODING; commandHash = C.commandHash(command); actor_ = caller; witness; justification });
      permission = perm.id;
    })
  };

  public func prepareReviewOverride(bs : State, bb : Blocks, caller : Principal, index : Nat, disposition : Text) : Result.Result<T.Event, T.BankError> {
    let ?o = overrideEntry(bs, bb, index) else return #err(#UnknownOverride({ index }));
    if (MC.isReviewed(o)) return #err(#OverrideAlreadyReviewed({ index }));
    if (Principal.equal(o.actor_, caller)) return #err(#SelfApproval({ maker = o.actor_ }));
    if (not MC.textFits(disposition, T.MAX_JUSTIFICATION_BYTES)) return #err(#InvalidPolicy({ reason = "disposition exceeds the bound" }));
    if (Text.encodeUtf8(disposition).size() == 0) return #err(#InvalidPolicy({ reason = "a review requires a disposition" }));
    #ok(#overrideReviewed({ override_ = index; reviewer = caller; disposition }))
  };

  // ═══════════════════════════════════════════════════════
  //  APPLY — the only place state changes
  // ═══════════════════════════════════════════════════════

  public func apply(s : State, bb : Blocks, block : T.Block) {
    switch (block.event) {
      case (#bookOpened(x)) {
        let entry : BookEntry = { id = x.id; name = x.name; parent = x.parent; var status = #active; openedAtBlock = block.index; var closedAtBlock = null };
        Map.add(s.books, Text.compare, x.id, entry);
      };
      case (#bookClosed(x)) {
        let ?b = Map.get(s.books, Text.compare, x.id) else Runtime.trap("BankCore: close of unknown book");
        b.status := #closed;
        b.closedAtBlock := ?block.index;
      };
      case (#roleDefined(x)) {
        Map.add(s.roles, Text.compare, x.id, { id = x.id; name = x.name; permissions = x.permissions; definedAtBlock = block.index });
      };
      case (#roleGranted(x)) {
        Map.add(s.grants, cmpPR, (x.subject, x.role), { subject = x.subject; role = x.role; scope = x.scope; grantedAtBlock = block.index });
      };
      case (#roleRevoked(x)) { ignore Map.delete(s.grants, cmpPR, (x.subject, x.role)) };
      case (#dualPolicySet(x)) { Map.add(s.policies, Text.compare, x.permission, x) };
      case (#dualPolicyCleared(x)) { ignore Map.delete(s.policies, Text.compare, x.permission) };
      case (#bankAdminTransferred(x)) { s.admin := x.admin };
      case (#featureActivationSet(x)) { Map.add(s.features, Text.compare, x.feature, x.height) };
      case (#commandProposed(x)) {
        ignore RI.put(s.proposalRows, rowKey(block.index), MC.encodeProposalRow({ expiresAt = x.expiresAt; status = #awaiting; approvalBlocks = [] }));
        Map.add(s.openProposals, Nat.compare, block.index, ());
      };
      case (#commandApproved(x)) {
        let ?r = proposalRow(s, x.proposal) else Runtime.trap("BankCore: approval of unknown proposal");
        // An approval that completes the policy executes in the same step, so the row can never
        // need more than the bound; a log that says otherwise is not this bank's log.
        if (r.approvalBlocks.size() >= T.MAX_REQUIRED_APPROVALS) Runtime.trap("BankCore: more approvals than any policy can require");
        ignore RI.put(s.proposalRows, rowKey(x.proposal), MC.encodeProposalRow({ r with approvalBlocks = Array.concat<Nat>(r.approvalBlocks, [block.index]) }));
      };
      case (#commandRejected(x)) {
        let ?r = proposalRow(s, x.proposal) else Runtime.trap("BankCore: rejection of unknown proposal");
        ignore RI.put(s.proposalRows, rowKey(x.proposal), MC.encodeProposalRow({ r with status = #rejected(block.index) }));
        ignore Map.delete(s.openProposals, Nat.compare, x.proposal);
      };
      case (#commandExecuted(x)) {
        // The executed record names either a proposal or an override. The maker and the command it
        // charges against the daily limit are in the authority's own block.
        switch (proposalRow(s, x.proposal)) {
          case (?r) {
            ignore RI.put(s.proposalRows, rowKey(x.proposal), MC.encodeProposalRow({ r with status = #executed(block.index) }));
            ignore Map.delete(s.openProposals, Nat.compare, x.proposal);
            let #commandProposed(p) = blockAt(bb, x.proposal, "the executed proposal").event else Runtime.trap("BankCore: block " # Nat.toText(x.proposal) # " has a proposal row but is not a proposal");
            switch (x.charge) { case (?c) consumeTotals(s, p.maker, c.day, c.totals); case null {} };
          };
          case null {
            let ?o = overrideRow(s, x.proposal) else Runtime.trap("BankCore: execution names neither a proposal nor an override");
            ignore RI.put(s.overrideRows, rowKey(x.proposal), MC.encodeOverrideRow({ o with executedAt = block.index }));
            let #emergencyOverride(ov) = blockAt(bb, x.proposal, "the executed override").event else Runtime.trap("BankCore: block " # Nat.toText(x.proposal) # " has an override row but is not an override");
            switch (x.charge) { case (?c) consumeTotals(s, ov.actor_, c.day, c.totals); case null {} };
          };
        };
        s.executedCount += 1;
      };
      case (#commandExpired(x)) {
        let ?r = proposalRow(s, x.proposal) else Runtime.trap("BankCore: expiry of unknown proposal");
        ignore RI.put(s.proposalRows, rowKey(x.proposal), MC.encodeProposalRow({ r with status = #expired(block.index) }));
        ignore Map.delete(s.openProposals, Nat.compare, x.proposal);
      };
      case (#emergencyOverride(_)) {
        ignore RI.put(s.overrideRows, rowKey(block.index), MC.encodeOverrideRow({ executedAt = 0; reviewedAt = 0 }));
        Map.add(s.openOverrides, Nat.compare, block.index, ());
      };
      case (#overrideReviewed(x)) {
        let ?o = overrideRow(s, x.override_) else Runtime.trap("BankCore: review of unknown override");
        ignore RI.put(s.overrideRows, rowKey(x.override_), MC.encodeOverrideRow({ o with reviewedAt = block.index }));
        ignore Map.delete(s.openOverrides, Nat.compare, x.override_);
      };
      case (#party(pe)) { PartyCore.apply(s.party, block.index, pe) };
      case (#product(pe)) {
        ProductCore.apply(s.product, block.index, pe);
        // the exposure rows carry what left and what came back (collections and recovery); the stage moves are their own blocks
        switch (pe) {
          case (#loanWrittenOff(x)) CollectionsCore.addWrittenOff(s.collections, x.account, Loans.allocationTotal(x.components));
          case (#recoveryReceived(x)) CollectionsCore.addRecovered(s.collections, x.account, x.amount);
          case (_) {};
        };
      };
      case (#close(ce)) { CloseCore.apply(s.close, block.index, ce) };
      case (#batch(be)) { BatchCore.apply(s.batch, block.index, be) };
      case (#report(re)) { ReportCore.apply(s.report, block.index, re) };
      case (#index(ie)) { IndexCore.apply(s.index, ie) };
      case (#archive(ae)) { ArchiveCore.apply(s.archive, block.index, ae) };
      case (#monitoring(me)) { MonitoringCore.apply(s.monitoring, block.index, me) };
      case (#alert(ae)) { AlertCore.apply(s.alerts, block.index, ae) };
      case (#collections(ce)) { CollectionsCore.apply(s.collections, block.index, ce) };
      case (#origination(oe)) { OriginationCore.apply(s.origination, block.index, oe) };
      case (#facility(fe)) { FacilityCore.apply(s.facility, block.index, fe) };
      case (#teller(te)) { TellerCore.apply(s.teller, block.index, te) };
      case (#trade(tr)) { TradeCore.fold(s.trade, block.index, tr) };
      case (#islamic(ie)) { IslamicCore.fold(s.islamic, block.index, ie) };
      case (#shard(se)) { ShardCore.apply(s.shard, block.index, se) };
      case (#settlement(se)) { SettlementCore.apply(s.settlement, block.index, se) };
      case (#payments(pe)) { PaymentsCore.apply(s.payments, block.index, block.timestamp, pe) };
      case (#fspiop(fe)) { FspiopCore.apply(s.fspiop, block.index, fe) };
      case (#packing(pe)) {
        switch (pe) {
          case (#packOpened(x)) { s.packing.current := ?{ pack = x.pack; period = x.period; periodEnd = x.periodEnd; lo = x.lo; hi = x.hi; bankLo = x.bankLo; bankHi = x.bankHi } };
          case (#packSealed(x)) {
            switch (s.packing.current) { case (?c) Map.add(s.packing.sealed, Nat.compare, x.pack, { period = c.period; periodEnd = x.periodEnd; lo = c.lo; hi = x.hi; segments = x.segments; bankLo = c.bankLo; bankHi = x.bankHi; bankSegments = x.bankSegments }); case null {} };
            s.packing.current := null;
            s.packing.packedThroughBlock := x.hi;
            s.packing.bankPackedThroughBlock := x.bankHi;
            if (x.periodEnd > s.packing.packedThroughDay) s.packing.packedThroughDay := x.periodEnd;
            s.packing.packs += 1;
          };
          case (#segmentPacked(_)) {};
          case (#bankSegmentPacked(_)) {};
          case (#packAdvanced(_)) {};
          case (#rollAuthorised(x)) { s.packing.roll := ?{ pack = x.pack; cid = x.cid; archive = x.archive; hi = x.hi } };
          case (#rollAdvanced(_)) {};
          case (#checkpointWritten(_)) {};
          case (#segmentSent(_)) {};
          case (#segmentArchived(_)) {};
          case (#packArchived(x)) {
            s.packing.roll := null;
            s.packing.archivedThroughBlock := x.hi;
            s.packing.archivedPacks := x.pack;
            Map.add(s.packing.archives, Nat.compare, x.pack, { cid = x.cid; archive = x.archive; hi = x.hi });
          };
        };
      };
      case (#operationRefused(_)) { s.refusedCount += 1 };
    };
    s.height += 1;
  };

  /// What executing `command` charges the maker's daily limit: the day and the totals by currency, computed
  /// by the executor and recorded in the `#commandExecuted` block, which the fold then applies — so the
  /// fold never needs the proposal's body (§18.2). Manual entries carry their legs; a reversal's legs are
  /// the original's and are charged by the executor through `consumeTotals`.
  public func chargeOf(s : State, command : T.Command) : ?T.Charge {
    let ?day = commandDay(command) else return null;
    let totals : [(Text, Nat)] = switch (command) {
      case (#postManualEntry(x)) E.legTotals(x.legs);
      // A product movement's currency is the account's own and its amount is the
      // command's, which is exactly what the ceiling and the daily limit were
      // measured against when the operation was authorised.
      case (#depositToAccount(m)) accountTotals(s, m.account, m.amount);
      case (#withdrawFromAccount(m)) accountTotals(s, m.account, m.amount);
      case (#disburseLoan(m)) accountTotals(s, m.account, m.amount);
      case (#repayLoan(m)) accountTotals(s, m.account, m.amount);
      case (#recordRecovery(m)) accountTotals(s, m.account, m.amount);
      case (#redeemTermDeposit(m)) accountTotals(s, m.account, m.amount);
      case (#transferBetweenAccounts(x)) accountTotals(s, x.from, x.amount);
      case (#allocateCashToTill(x)) tillTotals(s, x.till, x.amount);
      case (#returnCashFromTill(x)) tillTotals(s, x.till, x.amount);
      case (#settleTill(x)) tillTotals(s, x.till, x.declared);
      case (#grantFacility(x)) accountTotals(s, x.account, x.limit);
      case (#bookFxDeal(x)) [(x.sell, x.sellAmount)];
      case (#realiseFxPosition(x)) [(x.currency, x.closedPosition)];
      case (_) return null;
    };
    ?{ day; totals }
  };

  public func consumeTotals(s : State, subject : Principal, day : Nat, totals : [(Text, Nat)]) {
    for ((ccy, amount) in totals.vals()) {
      let prev = consumedFor(s, subject, ccy, day);
      Map.add(s.consumed, cmpPCD, (subject, ccy, day), prev + amount);
    };
  };

  public func replay(admin : Principal, blocks : [T.Block]) : State {
    let s = newState(admin);
    let bb : Blocks = { get = func(i : Nat) : ?T.Block { if (i < blocks.size()) ?blocks[i] else null } };
    for (b in blocks.vals()) { apply(s, bb, b) };
    s
  };

  // ═══════════════════════════════════════════════════════
  //  FINGERPRINT
  // ═══════════════════════════════════════════════════════

  func wScopeFp(w : JC.Writer, sc : T.Scope) {
    switch (sc.books) { case null w.byte(0); case (?xs) { w.byte(1); w.len16(xs.size()); for (x in xs.vals()) { w.text(x) } } };
    switch (sc.currencies) { case null w.byte(0); case (?xs) { w.byte(1); w.len16(xs.size()); for (x in xs.vals()) { w.text(x) } } };
    switch (sc.ceiling) { case null w.byte(0); case (?xs) { w.byte(1); w.len16(xs.size()); for (x in xs.vals()) { w.text(x.currency); w.nat(x.amount) } } };
    switch (sc.dailyLimit) { case null w.byte(0); case (?xs) { w.byte(1); w.len16(xs.size()); for (x in xs.vals()) { w.text(x.currency); w.nat(x.amount) } } };
  };

  /// SHA-256 over a canonical serialisation of the derived state. Two states with
  /// the same fingerprint have the same books, roles, grants, policies, features,
  /// proposals, overrides and consumed figures.
  // ═══════════════════════════════════════════════════════
  //  REPORTING — the helpers the engine reads through
  // ═══════════════════════════════════════════════════════

  /// The kind label the feed gives an event. One place, derived from the union itself, so a
  /// new event cannot reach a consumer unlabelled — which is the failure a hand-maintained
  /// list of event names always eventually has.
  public func eventKind(e : T.Event) : Text {
    switch (e) {
      case (#bankAdminTransferred(_)) "bankAdminTransferred";
      case (#bookOpened(_)) "bookOpened";
      case (#bookClosed(_)) "bookClosed";
      case (#roleDefined(_)) "roleDefined";
      case (#roleGranted(_)) "roleGranted";
      case (#roleRevoked(_)) "roleRevoked";
      case (#dualPolicySet(_)) "dualPolicySet";
      case (#dualPolicyCleared(_)) "dualPolicyCleared";
      case (#featureActivationSet(_)) "featureActivationSet";
      case (#commandProposed(_)) "commandProposed";
      case (#commandApproved(_)) "commandApproved";
      case (#commandExecuted(_)) "commandExecuted";
      case (#commandRejected(_)) "commandRejected";
      case (#commandExpired(_)) "commandExpired";
      case (#emergencyOverride(_)) "emergencyOverride";
      case (#overrideReviewed(_)) "overrideReviewed";
      case (#operationRefused(_)) "operationRefused";
      case (#party(_)) "party";
      case (#product(_)) "product";
      case (#close(_)) "close";
      case (#batch(_)) "batch";
      case (#report(_)) "report";
      case (#index(_)) "index";
      case (#archive(_)) "archive";
      case (#monitoring(_)) "monitoring";
      case (#alert(_)) "alert";
      case (#collections(_)) "collections";
      case (#origination(_)) "origination";
      case (#facility(_)) "facility";
      case (#teller(_)) "teller";
      case (#trade(_)) "trade";
      case (#islamic(_)) "islamic";
      case (#packing(_)) "packing";
      case (#shard(_)) "shard";
      case (#settlement(_)) "settlement";
      case (#payments(_)) "payments";
      case (#fspiop(_)) "fspiop";
    }
  };

  /// The book an event belongs to, where it belongs to one. A consumer subscribed to a branch
  /// filters on this; an event with no book is bank-wide and reaches everyone.
  public func eventBook(e : T.Event) : ?Text {
    switch (e) {
      case (#bookOpened(x)) ?x.id;
      case (#bookClosed(x)) ?x.id;
      case (#close(ce)) {
        switch (ce) {
          case (#periodEndOpened(x)) ?x.book;
          case (#periodEndClosed(x)) ?x.book;
          case (#bookClosedForPeriod(x)) ?x.book;
          case (_) null;
        }
      };
      case (#batch(be)) {
        switch (be) {
          case (#eodOpened(x)) ?x.book;
          case (#eodChunk(x)) ?x.book;
          case (#eodCompleted(x)) ?x.book;
          case (#eodFailed(x)) ?x.book;
          case (#eodRetry(x)) ?x.book;
          case (#eodFailureResolved(x)) ?x.book;
          case (_) null;
        }
      };
      case (#report(re)) {
        switch (re) {
          case (#reportCertified(x)) ?x.book;
          case (#statementMapSet(x)) ?x.book;
          case (_) null;
        }
      };
      case (_) null;
    }
  };

  public func exportShapeName(sh : RepT.ExportShape) : Text {
    switch (sh) { case (#safT) "saf-t"; case (#aicpaAds) "aicpa-ads"; case (#normalisedTrialBalance) "normalised-trial-balance" }
  };

  /// What the report engine reads the bank's own state through.
  ///
  /// The engine is a fold with no knowledge of products, parties or books; everything it
  /// needs that is not in the journal arrives here. Two things in particular:
  ///
  ///   * `leadsheetOf` is the journal's own leadsheet schema, which already carries the
  ///     discipline that an account in no range is **reported** rather than bucketed;
  ///   * `subledgerRows` is one row per product account, which is what a breakdown by book,
  ///     product or counterparty class needs — a posting in the journal carries a sub-ledger
  ///     key and not a branch, so the branch has to come from the account register.
  ///
  /// A counterparty class is a **declared** extension field on the party. Nothing is derived
  /// from personal data, which this layer holds only as commitments, and a party with no
  /// value for the field is keyed `unclassified` and reported as such.
  public func reportContext(bs : State, bb : Blocks, js : JCore.State, def : RepT.ReportDef) : Reports.Context {
    {
      leadsheetOf = func(code : JT.AccountCode) : ?Text {
        switch (Leadsheet.lookup(JCore.leadsheetSchema(js), code)) { case (?r) ?r.leadsheet; case null null }
      };
      subledgerRows = func() : [Reports.SubledgerRow] { subledgerRows(bs, bb, js, def) };
    }
  };

  /// The declared classification a definition's `#counterpartyClass` dimension names, read
  /// from the party's recorded extension values.
  func classOf(bs : State, bb : Blocks, party : PT.PartyId, def : RepT.ReportDef) : ?Text {
    var schema = "";
    var field = "";
    for (d in def.rows.vals()) {
      switch (d) { case (#counterpartyClass(c)) { schema := c.schema; field := c.field }; case (_) {} };
    };
    if (Text.size(schema) == 0) return null;
    let ?p = PartyCore.get(bs.party, partyBlocks(bb), party) else return null;
    for (e in PartyCore.extensions(p).vals()) {
      if (Text.equal(e.schema, schema) and Text.equal(e.name, field)) {
        return ?PartyCore.extensionText(e.value);
      };
    };
    null
  };

  func subledgerRows(bs : State, bb : Blocks, js : JCore.State, def : RepT.ReportDef) : [Reports.SubledgerRow] {
    let out = List.empty<Reports.SubledgerRow>();
    for (a in ProductCore.listAccounts(bs.product, productBlocks(bb)).vals()) {
      switch (ProductCore.termsOf(bs.product, a)) {
        case null {};
        case (?terms) {
          let bal = JCore.balance(js, terms.control, ?a.subledger, a.currency);
          List.add(out, {
            account = terms.control;
            currency = a.currency;
            book = a.book;
            product = a.product;
            class_ = classOf(bs, bb, a.party, def);
            // A sub-ledger's period figures are its posted totals: the journal keeps no
            // per-period sub-ledger column, and a report keyed by book asks what the
            // sub-ledger holds rather than what moved in one period. Stated here so the
            // difference from the chart source is deliberate.
            periodDebits = bal.debitsPosted;
            periodCredits = bal.creditsPosted;
            closingDebits = bal.debitsPosted;
            closingCredits = bal.creditsPosted;
            entryCount = 0;
            balanceAsOf = func(d : Nat) : { debits : Nat; credits : Nat } {
              JCore.balanceAsOf(js, terms.control, ?a.subledger, a.currency, d)
            };
            valueDated = func(d : Nat) : { debits : Nat; credits : Nat } {
              JCore.valueDatedBalance(js, terms.control, ?a.subledger, a.currency, d)
            };
          });
        };
      };
    };
    List.toArray(out)
  };

  /// The statement a `#issueStatement` records, built from the end-of-day batch cut for a camt.053 and from
  /// the live fold for the other two.
  ///
  /// It does **not** build the camt message. The register entry is the statement's identity —
  /// the account, the kind, the balances and the journal blocks its entries came from — and the
  /// message is a projection the read surface serves from the log. Keeping them apart is what
  /// lets the planner work with state alone: the camt projection derives each entry's UETR from
  /// a block hash, and a planner that has to invent one would be a planner inventing an
  /// identifier a customer could be shown.
  public func statementRefFor(
    bs : State, bb : Blocks,
    js : JCore.State,
    jb : JCore.Blocks,
    account : ProdT.AccountId,
    kind : RepT.StatementKind,
    period : JT.PeriodId,
  ) : Result.Result<RepT.StatementRef, T.BankError> {
    let (a, terms) = switch (requireAccount(bs, bb, account)) {
      case (#err(e)) return #err(e);
      case (#ok(x)) x;
    };
    let ?p = JCore.getPeriod(js, period) else return #err(#ReportError({ error = #UnknownPeriod({ period }) }));
    let figures : RepT.StatementCutFigures = switch (kind) {
      case (#camt053(k)) {
        // The cut, not a re-derivation. A statement for a day whose cut was never taken is
        // refused rather than answered from the live fold, because the two are different claims
        // and only one of them is what the customer was sent.
        let ?cut = BatchCore.cutFor(bs.batch, account) else {
          return #err(#BatchError({ error = #NoStatementCut({ account }) }));
        };
        if (cut.day != k.cut) {
          return #err(#BatchError({ error = #NoStatementCut({ account }) }));
        };
        { openingDebits = cut.openingDebits; openingCredits = cut.openingCredits;
          closingDebits = cut.closingDebits; closingCredits = cut.closingCredits }
      };
      case (#camt052(k)) {
        // an intraday report has no cut behind it: the figures are the live fold at the date
        let o = JCore.valueDatedBalance(js, terms.control, ?a.subledger, a.currency, p.start - 1);
        let c = JCore.valueDatedBalance(js, terms.control, ?a.subledger, a.currency, k.asOf);
        { openingDebits = o.debits; openingCredits = o.credits;
          closingDebits = c.debits; closingCredits = c.credits }
      };
      case (#camt054(_)) {
        { openingDebits = 0; openingCredits = 0; closingDebits = 0; closingCredits = 0 }
      };
    };
    let priorClose : ?{ debits : Nat; credits : Nat } = switch (priorPeriodOf(js, period)) {
      case null null;
      case (?prior) {
        switch (JCore.getPeriod(js, prior)) {
          case null null;
          case (?q) ?JCore.valueDatedBalance(js, terms.control, ?a.subledger, a.currency, q.end);
        }
      };
    };
    let balances = StatementsM.statementBalances(js, terms.control, ?a.subledger, a.currency, figures, priorClose);
    let ref : RepT.StatementRef = {
      id = StatementsM.registerKey(account, kind);
      account;
      kind;
      currency = a.currency;
      period;
      balances;
      entryBlocks = statementEntryBlocks(js, jb, period, terms.control, a.subledger, a.currency);
      issued = 1;
      contentHash = "";
      atHeight = JCore.height(js);
    };
    #ok({ ref with contentHash = StatementsM.refHash(ref) })
  };

  /// The journal blocks an account's statement entries come from, read out of the journal's own
  /// general ledger. These are what make one line of a statement provable on its own: a holder
  /// asks for that block's inclusion proof and verifies it against the certified root without
  /// being given the rest of the book.
  func statementEntryBlocks(
    js : JCore.State,
    jb : JCore.Blocks,
    period : JT.PeriodId,
    control : JT.AccountCode,
    subledger : JT.SubledgerKey,
    currency : JT.Currency,
  ) : [Nat] {
    let out = List.empty<Nat>();
    switch (JCore.generalLedger(js, jb, period, ?control)) {
      case null {};
      case (?gl) {
        for (acct in gl.accounts.vals()) {
          if (Text.equal(acct.currency, currency)) {
            for (e in acct.entries.vals()) {
              if (e.subledger == ?subledger) List.add(out, e.index);
            };
          };
        };
      };
    };
    List.toArray(out)
  };

  /// The period immediately before this one, by end date. `PRCD` is the prior period's close,
  /// which is what makes a statement's continuity checkable by its reader.
  func priorPeriodOf(js : JCore.State, period : JT.PeriodId) : ?JT.PeriodId {
    let ?p = JCore.getPeriod(js, period) else return null;
    var best : ?JT.Period = null;
    for (q in JCore.listPeriods(js).vals()) {
      if (q.end < p.start) {
        switch (best) {
          case null best := ?q;
          case (?b) { if (q.end > b.end) best := ?q };
        };
      };
    };
    switch (best) { case (?b) ?b.id; case null null }
  };

  func fingerprintRows(w : JC.Writer, idx : RI.State) {
    let (lo, hi) = RI.rangeEnds([], 8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(idx, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) { w.blobRaw(k); w.blobRaw(v) };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
  };

  public func fingerprint(s : State) : Blob {
    let w = JC.Writer();
    w.principal(s.admin);
    w.nat(s.height);
    w.nat(s.refusedCount);
    w.nat(s.executedCount);
    for ((_, b) in Map.entries(s.books)) {
      w.text(b.id); w.text(b.name);
      switch (b.parent) { case null w.byte(0); case (?p) { w.byte(1); w.text(p) } };
      w.bool(b.status == #active); w.nat(b.openedAtBlock); w.optNat(b.closedAtBlock);
    };
    for ((_, r) in Map.entries(s.roles)) {
      w.text(r.id); w.text(r.name); w.nat(r.definedAtBlock);
      w.len16(r.permissions.size());
      for (p in r.permissions.vals()) { w.text(p) };
    };
    for (((subj, role), g) in Map.entries(s.grants)) {
      w.principal(subj); w.text(role); w.nat(g.grantedAtBlock); wScopeFp(w, g.scope);
    };
    for ((_, p) in Map.entries(s.policies)) {
      w.text(p.permission); w.nat(p.required); w.text(p.eligibleRole); w.nat(p.ttlSeconds);
    };
    for ((f, h) in Map.entries(s.features)) { w.text(f); w.nat64(h) };
    // The proposal and override rows, raw: each is a deterministic function of the log, so two folds
    // of the same log write the same bytes, and a fold that saw a different approval or resolution
    // writes different ones. What a row points at — the command, the maker, the checkers — is in the
    // log the fingerprint is compared across, so hashing the rows is hashing that.
    w.nat(RI.size(s.proposalRows));
    fingerprintRows(w, s.proposalRows);
    w.nat(RI.size(s.overrideRows));
    fingerprintRows(w, s.overrideRows);
    for (((subj, ccy, day), n) in Map.entries(s.consumed)) { w.principal(subj); w.text(ccy); w.nat(day); w.nat(n) };
    PartyCore.fingerprintInto(w, s.party);
    ProductCore.fingerprintInto(w, s.product);
    CloseCore.fingerprintInto(w, s.close);
    BatchCore.fingerprintInto(w, s.batch);
    w.blob(ReportCore.fingerprint(s.report));
    IndexCore.fingerprintInto(w, s.index);
    ArchiveCore.fingerprintInto(w, s.archive);
    MonitoringCore.fingerprintInto(w, s.monitoring);
    AlertCore.fingerprintInto(w, s.alerts);
    CollectionsCore.fingerprintInto(w, s.collections);
    OriginationCore.fingerprintInto(w, s.origination);
    FacilityCore.fingerprintInto(w, s.facility);
    TellerCore.fingerprintInto(w, s.teller);
    TradeCore.fingerprintInto(w, s.trade);
    IslamicCore.fingerprintInto(w, s.islamic);
    w.nat(s.packing.packs); w.nat(s.packing.packedThroughBlock); w.nat(s.packing.packedThroughDay); w.nat(s.packing.bankPackedThroughBlock);
    switch (s.packing.current) { case (?c) { w.byte(1); w.nat(c.pack); w.text(c.period); w.nat(c.periodEnd); w.nat(c.lo); w.nat(c.hi); w.nat(c.bankLo); w.nat(c.bankHi) }; case null w.byte(0) };
    w.nat(s.packing.archivedThroughBlock); w.nat(s.packing.archivedPacks);
    switch (s.packing.roll) { case (?r) { w.byte(1); w.nat(r.pack); w.nat64(r.cid); w.principal(r.archive); w.nat(r.hi) }; case null w.byte(0) };
    for ((pack, a) in Map.entries(s.packing.archives)) { w.nat(pack); w.nat64(a.cid); w.principal(a.archive); w.nat(a.hi) };
    ShardCore.fingerprintInto(w, s.shard);
    SettlementCore.fingerprintInto(w, s.settlement);
    PaymentsCore.fingerprintInto(w, s.payments);
    FspiopCore.fingerprintInto(w, s.fspiop);
    let d = Sha256.Digest(#sha256);
    d.writeArray(w.toArray());
    d.sum()
  };
};
