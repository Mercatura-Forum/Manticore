/// Bank.mo — the banking domain canister, with the journal embedded.
///
/// Composition (the same shape `src/facade/TokenLedger.mo` uses in the pinned
/// submodule for the ICRC surface):
///
///   JCore / JLog / JCert   the double-entry journal: postings, balances,
///                          periods, proofs — the record of what moved
///   BankCore / BankLog     the domain layer: books, roles, grants, policies,
///                          proposals, overrides — the record of why it was
///                          allowed to move
///   BankCert               one certified tree carrying both Merkle roots
///
/// Every update method is validate → append → apply → certify, with no `await`
/// anywhere on that path, so a call is atomic on the IC: it commits the authority
/// block, the postings it caused and both certified roots together, or it changes
/// nothing. That is the whole reason the domain layer embeds the journal instead
/// of calling it: a four-eyes approval and the posting it authorises cannot end
/// up on opposite sides of a failed message.
///
/// **Genesis.** Dual control governs its own configuration, which leaves the
/// question of how a deployment gets its first role and its first checker. There
/// is no bootstrap exception and no superuser: the genesis books, roles, grants
/// and policies arrive as **install arguments** and are written to the bank log as
/// ordinary blocks in the install message. Installing is a controller action, so
/// genesis authority is exactly as trusted as the wasm itself, and from block 0
/// the log is complete and dual control holds without exception. An install whose
/// arguments do not validate traps, so a misconfigured deployment fails loudly
/// rather than coming up with authority nobody intended.
///
/// The journal's administrator and its only registered poster are this canister.
/// Nothing else can reach the journal, because nothing else has a reference to it.

import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import List "mo:core/List";
import Map "mo:core/Map";
import Array "mo:core/Array";
import Runtime "mo:core/Runtime";
import Error "mo:core/Error";
import Prim "mo:⛔";
import IC "mo:core/InternetComputer";
import Sha256 "mo:sha2/Sha256";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";
import JLog "mo:journal/JournalLog";
import JCamt "mo:journal/Camt053";
import CivilDate "mo:journal/CivilDate";

import T "BankTypes";
import PT "PartyTypes";
import PartyCore "PartyCore";
import Iban "Iban";
import C "BankCanonical";
import Commit "Commitments";
import BLog "BankLog";
import BCert "BankCert";
import BankCore "BankCore";
import PIdx "PostingIndex";
import Posting "Posting";
import IdxT "IndexTypes";
import IndexCore "IndexCore";
import Queries "Queries";
import RI "mo:ledger/RegionIndex";
import AT "ArchiveTypes";
import ArchiveCore "ArchiveCore";
import AW "ArchiveWire";
import AImg "ArchiveImage";
import Activity "Activity";
import MT "MonitoringTypes";
import Monitoring "Monitoring";
import MonitoringCore "MonitoringCore";
import AlT "AlertTypes";
import AlertCore "AlertCore";
import ColT "CollectionsTypes";
import CollectionsCore "CollectionsCore";
import OT "OriginationTypes";
import OriginationCore "OriginationCore";
import FaT "FacilityTypes";
import FacilityCore "FacilityCore";
import TeT "TellerTypes";
import TellerCore "TellerCore";
import TrT "TradeTypes";
import TradeCore "TradeCore";
import TradeMessages "TradeMessages";
import IT "IslamicTypes";
import IslamicCore "IslamicCore";
import PkT "PackingTypes";
import Packing "Packing";
import Pack "Pack";
import ArchiveRoll "ArchiveRoll";
import ST "ShardTypes";
import ShardCore "ShardCore";
import SeT "SettlementTypes";
import SettlementCore "SettlementCore";
import PayT "PaymentsTypes";
import PaymentsCore "PaymentsCore";
import FT "FspiopTypes";
import FspiopCore "FspiopCore";
import FspiopProfiles "FspiopProfiles";
import IsoMessages "IsoMessages";
import PqSchemes "../pq/PqSchemes";
import Rx "Rx";
import P "Permissions";
import E "Entitlements";
import ProdT "ProductTypes";
import ProductCore "ProductCore";
import CT "CloseTypes";
import RepT "ReportTypes";
import Reports "Reports";
import Returns "Returns";
import Statements "Statements";
import Filings "Filings";
import Feed "Feed";
import ReportCore "ReportCore";
import CloseCore "CloseCore";
import BT "BatchTypes";
import Batch "Batch";
import BatchCore "BatchCore";
import Conv "Conventions";

shared (initMsg) persistent actor class Bank(init : {
  /// Books (offices) to open at genesis, parents before children.
  books : [{ id : T.BookId; name : Text; parent : ?T.BookId }];
  /// Roles to define at genesis.
  roles : [{ id : T.RoleId; name : Text; permissions : [T.PermissionId] }];
  /// Grants to make at genesis. Without at least one, the canister has no
  /// authority at all and can do nothing, which is the safe failure.
  grants : [{ subject : Principal; role : T.RoleId; scope : T.Scope }];
  /// Explicit dual-authorisation policies.
  policies : [T.DualPolicy];
  /// Applied to every `dualByDefault` permission in the catalogue that the
  /// explicit list does not cover, so the policy table is complete from block 0
  /// and nothing falls back to an implicit default at run time.
  defaultDual : ?{ eligibleRole : T.RoleId; required : Nat; ttlSeconds : Nat };
  /// The journal's calendar authority at genesis (`JournalTypes.CalendarAuthority`): `#businessDate` with the
  /// first business date on a substrate whose clock is not wall time (Thebes), absent on the IC, where the
  /// substrate clock is consensus time and the business date travels by the roll command.
  calendar : ?{ authority : JT.CalendarAuthority; maxRollDays : Nat; businessDate : ?JT.Day };
}) = self {

  // ─── persisted state ──────────────────────────────────────────────────────

  let installer : Principal = initMsg.caller;
  let bank : BankCore.State = BankCore.newState(installer);
  let bankLog : BLog.State = BLog.newState();
  let cert : BCert.State = BCert.newState();
  let journal : JCore.State = JCore.newState(Principal.fromActor(self));
  let journalLog : JLog.State = JLog.newState();
  /// The posting indexes, in stable memory, maintained in the posting's own message. Not part of
  /// `BankCore.State` on purpose: nothing here is the authority for anything. A balance is a journal
  /// balance, a posting is a block in the journal's log, and every row here only says where to find
  /// one.
  ///
  /// What is and is not reproducible from the logs alone is worth stating exactly, because "derived"
  /// is often claimed more widely than it is true. I0, the headers, I1, I2 and I3 are pure functions
  /// of the two logs: the same logs produce the same rows, byte for byte. **I4 is not** — a
  /// counterparty class is the declared dimension and the party's recorded extension *as they stood
  /// when the posting was made*, and the two logs carry no recorded alignment between a journal
  /// block and the bank state of that moment. That is precisely why I4 is maintained in the
  /// posting's own message rather than computed later, and why the dimension is a recorded,
  /// dual-authorised act: a class row means what it meant when it was written.
  let postingIndex : PIdx.State = PIdx.newState();
  /// The archive child image, in stable memory. Bytes, not a decision: the decision is the pin in
  /// `bank.archive`, and `sealArchiveImage` is where the two are made to agree.
  let archiveImage : AImg.State = AImg.newState();
  /// The monitoring aggregates (A1..A4 of the cross-account addendum), in the posting indexes'
  /// arena, maintained in the posting's own message right after the indexes. Derived, like them.
  let activity : Activity.State = Activity.newState(postingIndex.arena);
  /// Closed-month packing: the packs' segments, rows and lists, in the same arena and in stores of
  /// their own. Derived from the journal's log like the indexes; what the log says about it — which
  /// pack is open, where the boundary is — is folded in `bank.packing`.
  let packing : Packing.State = Packing.newState(postingIndex.arena);
  /// The archive roll: a sealed pack's segments to an archive child, the journal's prefix gone.
  let roll : ArchiveRoll.State = ArchiveRoll.newState();

  // ─── helpers ──────────────────────────────────────────────────────────────

  func now() : Nat64 { Nat64.fromNat(Int.abs(Time.now())) };
  func me() : Principal { Principal.fromActor(self) };

  /// Re-certify both tips together, so the two roots always describe the same
  /// message. An empty log contributes index 0 and empty hashes.
  func recertify() {
    let bn = BLog.length(bankLog);
    let jn = JLog.length(journalLog);
    let bIndex = if (bn == 0) 0 else bn - 1;
    let jIndex = if (jn == 0) 0 else jn - 1;
    let bHash = switch (BLog.tipHash(bankLog)) { case (?h) h; case null ("" : Blob) };
    let jHash = switch (JLog.tipHash(journalLog)) { case (?h) h; case null ("" : Blob) };
    let bRoot = switch (BLog.mmrRoot(bankLog)) { case (?r) r; case null ("" : Blob) };
    let jRoot = switch (JLog.mmrRoot(journalLog)) { case (?r) r; case null ("" : Blob) };
    BCert.update(cert, bIndex, bHash, bRoot, jIndex, jHash, jRoot);
  };

  /// Register the sub-ledger key of a newly opened account or till against its id, in the same
  /// message that opened it, so the index's reverse lookup can never lag the account. The id is the
  /// bank block index of the opening act, which is what `ProdT.AccountId` is defined as, so a till
  /// and an account can never collide: they are different blocks.
  ///
  /// The sub-ledger key is re-derived here the same way the product engine derives it. A failure to
  /// register is not something to carry on past: it can only mean two accounts claiming one
  /// sub-ledger key, which would put one account's movements under the other's statement.
  func registerIndexAccounts(b : T.Block) {
    switch (b.event) {
      case (#product(#accountOpened(x))) {
        if (not PIdx.registerAccount(postingIndex, Posting.subledgerOf(x.identifier), b.index)) {
          Runtime.trap("Bank: the sub-ledger key of account " # x.identifier # " is already registered to another account");
        };
      };
      case (#product(#tillOpened(x))) {
        if (not PIdx.registerAccount(postingIndex, Posting.subledgerOf("till/" # x.till), b.index)) {
          Runtime.trap("Bank: the sub-ledger key of till " # x.till # " is already registered");
        };
      };
      case (_) {};
    };
  };

  /// How the bank reads its own proposals and overrides back: its log. The state keeps a row per
  /// one — what happened to it — and the block is the thing itself, so nothing holds a command twice.
  /// A bank block's stored bytes below the log's base: the packs' (§18.3).
  func packedBankBlock(i : Nat) : ?Blob { Packing.bankBlock(packing, i) };
  /// The bank log as every reader sees it: the `StableLog`, and below its base the packs.
  func bankRaw(i : Nat) : ?Blob { BLog.rawBlockWith(bankLog, packedBankBlock, i) };
  func bankBlock(i : Nat) : ?T.Block { BLog.getWith(bankLog, packedBankBlock, i) };
  func bankBlocks() : BankCore.Blocks { { get = func(i : Nat) : ?T.Block { bankBlock(i) } } };
  func partyBlocks() : PartyCore.Blocks { BankCore.partyBlocks(bankBlocks()) };
  func productBlocks() : ProductCore.Blocks { BankCore.productBlocks(bankBlocks()) };

  func commitBank(caller : Principal, event : T.Event) : T.Block {
    let b = BLog.append(bankLog, now(), caller, event);
    BankCore.apply(bank, bankBlocks(), b);
    registerIndexAccounts(b);
    openPackOnEvent(b);
    recertify();
    reserveOnEvent(b);
    paymentsOnEvent(b);
    b
  };

  /// A lifted compliance hold acts in the message that recorded it: a release posts the held
  /// transfer, a rejection voids it. A refusal of the act (no open window for the day, say) traps
  /// and so refuses the release whole — a hold is never lifted with its payment left hanging.
  func paymentsOnEvent(b : T.Block) {
    switch (b.event) {
      case (#payments(#holdReleased(_)) or #payments(#holdRejected(_))) {
        let ?pe = (switch (b.event) { case (#payments(x)) ?x; case (_) null }) else return;
        switch (BankCore.settleHold(bank, bankBlocks(), journal, journalBlocks(), me(), now(), pe, bankRecorder())) {
          case (#ok(())) {};
          case (#err(e)) Runtime.trap("Bank: the held payment could not be settled with its hold: " # debug_show (e));
        };
      };
      case (_) {};
    };
  };

  /// A prepared transfer is reserved in the message that recorded it: the journal's two-phase
  /// posting against the payer's and the payee's positions, expiring with the transfer. The
  /// engine's refusal — the cap, above all — is recorded as the transfer's failure, so a payment
  /// that could not be reserved is in the trail with the journal's own reason.
  func reserveOnEvent(b : T.Block) {
    switch (b.event) {
      case (#settlement(#transferPrepared(_))) {
        switch (BankCore.planReserve(bank, bankBlocks(), journal, me(), now(), b.index)) {
          case (#err(e)) Runtime.trap("Bank: a prepared transfer could not be planned for reservation: " # debug_show (e));
          case (#ok(r)) {
            switch (r.step) { case (?#event(ev)) ignore commitJournal(ev); case (_) {} };
            ignore commitBank(me(), #settlement(r.event));
            switch (BankCore.capAlarm(bank, bankBlocks(), journal, now(), b.index)) { case (?alarm) ignore commitBank(me(), #settlement(alarm)); case null {} };
          };
        };
      };
      case (_) {};
    };
  };

  func settlementBlocks() : SettlementCore.Blocks { { get = func(i : Nat) : ?SeT.SettlementEvent { switch (bankBlock(i)) { case (?b) { switch (b.event) { case (#settlement(se)) ?se; case (_) null } }; case null null } } } };

  /// A pack opens in the message that records its opening, so the engine's job and the log's fact
  /// can never disagree: the engine computes the range from its own boundary and the block says the
  /// range the bank planned; a difference is a defect and traps the message.
  func openPackOnEvent(b : T.Block) {
    switch (b.event) {
      case (#packing(#rollAuthorised(x))) {
        switch (ArchiveRoll.open(roll, rollContext(), x.pack, x.cid, x.archive)) {
          case (#ok(_)) {};
          case (#err(e)) Runtime.trap("Bank: a planned roll could not open: " # debug_show (e));
        };
      };
      case (#packing(#packOpened(x))) {
        switch (Packing.open(packing, x.period, PIdx.periodOrdinal(postingIndex, x.period), x.periodEnd, x.hi, x.bankLo, x.bankHi)) {
          case (#ok(job)) {
            if (job.pack != x.pack or job.lo != x.lo or job.bankLo != x.bankLo) Runtime.trap("Bank: the packing engine and the log disagree about pack " # Nat.toText(x.pack));
          };
          case (#err(e)) Runtime.trap("Bank: a planned pack could not open: " # debug_show (e));
        };
      };
      case (_) {};
    };
  };

  func rollContext() : ArchiveRoll.Context {
    {
      packing; journal; admin = me();
      journalHeight = func() : Nat { JLog.length(journalLog) };
      blockOf = func(i : Nat) : ?JT.Block { JLog.get(journalLog, i) };
      appendJournal = func(ev : JT.Event) : Nat { commitJournal(ev).index };
      truncateLog = func(hi : Nat) { JLog.truncateThrough(journalLog, hi) };
      pruneMmr = func(hi : Nat) { JLog.pruneMmrThroughBlock(journalLog, hi) };
      idemBegin = func(hi : Nat) : Bool { switch (JCore.idempotencyRebuildInProgress(journal)) { case (?_) true; case null JCore.beginIdempotencyRebuild(journal, hi) } };
      idemStep = func(limit : Nat) : { examined : Nat; done : Bool } { JCore.stepIdempotencyRebuild(journal, limit) };
      idemFinish = func() : Bool { JCore.finishIdempotencyRebuild(journal) != null };
    }
  };

  /// What the packing engine reads and rebuilds: the log's bytes, the indexes, the aggregates, and
  /// the journal's idempotency keys through the three closures the journal exposes for it.
  func packingContext() : Packing.Context {
    {
      pidx = postingIndex;
      activity;
      rawBlock = func(i : Nat) : ?Blob { JLog.rawBlock(journalLog, i) };
      blockOf = func(i : Nat) : ?JT.Block { JLog.get(journalLog, i) };
      rawBankBlock = func(i : Nat) : ?Blob { bankRaw(i) };
      bankKeep = func(i : Nat, raw : Blob) : Blob { BankCore.keptBytes(bank, bankBlocks(), i, raw) };
      idemBegin = func(hi : Nat) : Bool { switch (JCore.idempotencyRebuildInProgress(journal)) { case (?_) true; case null JCore.beginIdempotencyRebuild(journal, hi) } };
      idemStep = func(limit : Nat) : { examined : Nat; done : Bool } { JCore.stepIdempotencyRebuild(journal, limit) };
      idemFinish = func() : Bool { JCore.finishIdempotencyRebuild(journal) != null };
    }
  };

  /// What the index asks the bank for. `classOf` is the declared counterparty class of a product
  /// account, built from the declared dimension and the party's recorded extension value — party
  /// data the index deliberately does not hold a second copy of. `blockOf` is the journal's own log.
  func indexContext() : PIdx.Context {
    {
      classOf = func(acctId : Nat) : ?Text {
        let ?dim = IndexCore.classDimension(bank.index) else return null;
        let ?a = ProductCore.accountRow(bank.product, acctId) else return null;
        let ?exts = PartyCore.extensionsOf(bank.party, partyBlocks(), a.party) else return null;
        for (e in exts.vals()) {
          if (Text.equal(e.schema, dim.schema) and Text.equal(e.name, dim.field)) {
            return ?IdxT.labelOf(dim, PartyCore.extensionText(e.value));
          };
        };
        null
      };
      blockOf = func(i : Nat) : ?JT.Block { JLog.get(journalLog, i) };
    }
  };

  /// How the journal reads a posting's record back: its own log. The records are there — the log is a
  /// Region-backed `StableLog` — so the journal's state keeps only the mutable facts about a posting,
  /// and nothing holds a posting twice.
  func journalBlocks() : JCore.Blocks { { get = func(i : Nat) : ?JT.Block { JLog.get(journalLog, i) } } };

  /// The instruction meter over every journal commit: what a posting costs the contract in
  /// instructions — the log append, the journal's fold, the indexes and the aggregates — read by
  /// the measured runs against `the capacity model` §6. Split by what the index component
  /// added (`indexInstructions`) and the whole.
  var meterCommits : Nat = 0;
  var meterInstructions : Nat = 0;
  var meterIndexInstructions : Nat = 0;
  var meterAppend : Nat = 0;
  var meterApply : Nat = 0;
  var meterIndex : Nat = 0;
  var meterActivity : Nat = 0;
  var meterLast : Nat = 0;

  func commitJournal(event : JT.Event) : JT.Block {
    var made : ?JT.Block = null;
    var recordedOpt : ?Activity.Recorded = null;
    var appendN : Nat64 = 0; var applyN : Nat64 = 0; var indexN : Nat64 = 0; var activityN : Nat64 = 0;
    let total = IC.countInstructions(func() {
      appendN := IC.countInstructions(func() { made := ?JLog.append(journalLog, now(), me(), event) });
      let ?blk = made else Runtime.trap("Bank: a commit that produced no block");
      applyN := IC.countInstructions(func() { JCore.apply(journal, journalBlocks(), blk) });
      // In the posting's own message, after the block is in the log and the journal has applied it,
      // so the index can never lag the journal and a trap anywhere in this message rolls both back
      // together. This is acceptance criterion 5 ("atomic") and it is a property of the ordering
      // here, not of anything the index does.
      indexN := IC.countInstructions(func() { ignore PIdx.indexBlock(postingIndex, blk, indexContext()) });
      // The aggregates, in the same message and after the indexes, so a rule's range and a query's
      // range describe the same journal.
      activityN := IC.countInstructions(func() { recordedOpt := ?Activity.record(activity, blk, activityContext()) });
    });
    meterCommits += 1;
    meterInstructions += Nat64.toNat(total);
    meterIndexInstructions += Nat64.toNat(indexN) + Nat64.toNat(activityN);
    meterAppend += Nat64.toNat(appendN); meterApply += Nat64.toNat(applyN); meterIndex += Nat64.toNat(indexN); meterActivity += Nat64.toNat(activityN);
    meterLast := Nat64.toNat(total);
    let ?b = made else Runtime.trap("Bank: a commit that produced no block");
    let ?recorded = recordedOpt else Runtime.trap("Bank: a commit that recorded nothing");
    recertify();
    // The cheap rules, in the posting's own message, and their alerts in the bank's log — citing
    // the posting that was just written, and opened once per finding.
    if (recorded.posted != null) {
      let rules = MonitoringCore.active(bank.monitoring, #atPosting);
      if (rules.size() > 0) {
        for (f in Monitoring.atPosting(monitoringContext(), rules, recorded).vals()) {
          switch (BankCore.alertFor(bank, f, #posting)) { case (?ev) ignore commitBank(me(), ev); case null {} };
        };
      };
    };
    b
  };

  /// The window rules for one account on one day, as the end-of-day batch asks for them: nothing
  /// for an account with no activity on the day (one row read), the evaluation otherwise.
  func monitorAtDay(account : Nat, day : Nat) : Result.Result<[MT.Finding], MT.MonitoringError> {
    if (Activity.dayActivity(activity, account, day).count == 0) return #ok([]);
    Monitoring.atDay(monitoringContext(), MonitoringCore.active(bank.monitoring, #endOfDay), account, day)
  };

  func activityContext() : Activity.Context {
    {
      accountOf = func(sub : JT.SubledgerKey) : ?Nat { PIdx.accountOf(postingIndex, sub) };
      blockOf = func(i : Nat) : ?JT.Block { JLog.get(journalLog, i) };
    }
  };

  /// What a rule evaluation reads: the aggregates, the account's own postings from I1 (live rows
  /// only, sized by the caller's bound), and the account's currency.
  func monitoringContext() : Monitoring.Context {
    {
      activity;
      postingsOf = func(acct : Nat, from : Nat, to : Nat, bound : Nat) : { rows : [Monitoring.PostingRow]; exceeded : Bool } {
        let (lo, hi) = PIdx.accountRangeEnds(acct, from, to);
        let page = RI.range(postingIndex.byAccount, lo, hi, null, bound + 1);
        let rows = List.empty<Monitoring.PostingRow>();
        for ((k, v) in page.entries.vals()) {
          let parts = PIdx.splitAccountKey(k);
          if (PIdx.isPosted(postingIndex, parts.postingNo, parts.valueDay)) {
            let m = PIdx.readMovement(v);
            List.add(rows, { posting = parts.postingNo; day = parts.valueDay; debits = m.debits; credits = m.credits });
          };
        };
        if (List.size(rows) > bound) { { rows = Array.tabulate<Monitoring.PostingRow>(bound, func(i) { switch (List.get(rows, i)) { case (?r) r; case null Runtime.trap("Bank: a row that was just listed is missing") } }); exceeded = true } }
        else { { rows = List.toArray(rows); exceeded = page.cursor != null } }
      };
      currencyOf = func(acct : Nat) : ?Text { ProductCore.currencyOf(bank.product, acct) };
    }
  };

  /// Record a refusal to exceed authority. Only a principal the bank has
  /// onboarded can cause a block, so an unknown caller cannot grow the log.
  func recordRefusal(caller : Principal, permission : T.PermissionId, e : T.BankError) {
    if (BankCore.recordableRefusal(bank, caller)) {
      ignore commitBank(caller, BankCore.refusalEvent(caller, permission, e, debug_show (e)));
    };
  };

  func fail<X>(caller : Principal, permission : T.PermissionId, r : { error : T.BankError; record : Bool }) : Result.Result<X, T.BankError> {
    if (r.record) recordRefusal(caller, permission, r.error);
    #err(r.error)
  };

  /// The method-level permission gate. Every write method names its permission
  /// from the catalogue; there is no default-allow branch because the identifier
  /// is a required argument.
  func requireMethodPermission(caller : Principal, method : Text) : Result.Result<T.PermissionId, T.BankError> {
    let ?perm = P.byMethod(method) else Runtime.trap("Bank: method " # method # " has no catalogue entry");
    let op : E.Operation = { permission = perm.id; book = null; totals = [] };
    switch (BankCore.authorise(bank, caller, op, JCore.effectiveToday(journal, now()))) {
      case (#ok(_)) #ok(perm.id);
      case (#err(e)) {
        if (BankCore.recordableRefusal(bank, caller)) recordRefusal(caller, perm.id, e);
        #err(e)
      };
    }
  };

  /// Commit a command's effects. Called only after the command has been planned
  /// successfully in the same message.
  /// The bank block a command's own event took, if it had one — a party's or an account's id is
  /// that block — and the journal postings it made.
  var lastExecutedEvent : ?Nat = null;

  func executeCommand(authority : Principal, command : T.Command, authorityIndex : Nat) : [Nat] {
    let plan = switch (BankCore.planCommand(bank, bankBlocks(), journal, journalBlocks(), me(), now(), command, authorityIndex)) {
      case (#ok(p)) p;
      // Unreachable: every caller plans the command before committing anything,
      // and nothing changes in between within one message. A trap rolls the
      // whole message back, so an execution can never land partially.
      case (#err(e)) Runtime.trap("Bank: planned command failed at execution: " # debug_show (e));
    };
    lastExecutedEvent := switch (plan.bankEvent) { case (?ev) ?commitBank(authority, ev).index; case null null };
    for (ev in plan.extra.vals()) { ignore commitBank(authority, ev) };
    let indices = List.empty<Nat>();
    for (step in plan.journal.vals()) {
      switch (step) {
        case (#event(ev)) List.add(indices, commitJournal(ev).index);
        case (#existing(idx)) List.add(indices, idx);
      };
    };
    List.toArray(indices)
  };

  // ═══════════════════════════════════════════════════════
  //  GENESIS (install message)
  // ═══════════════════════════════════════════════════════

  func genesis() {
    // The journal's administrator is this canister; register it as the only
    // poster before anything can be posted.
    switch (JCore.prepareAddPoster(journal, me(), me())) {
      case (#ok(ev)) ignore commitJournal(ev);
      case (#err(e)) Runtime.trap("Bank genesis: cannot register the bank as a journal poster: " # debug_show (e));
    };
    // Block 0 of the bank log records who administers it.
    ignore commitBank(installer, #bankAdminTransferred({ admin = installer }));
    // The calendar's authority, before any dated act: on Thebes the substrate clock is the block height, so the
    // first business date comes with the authority and the clock is never the bank's calendar.
    switch (init.calendar) {
      case (?c) genesisCommand(#journalSetCalendarAuthority({ authority = c.authority; maxRollDays = c.maxRollDays; businessDate = c.businessDate }));
      case null {};
    };
    // Books, then roles, then grants, then policies: each validated by the same
    // `planCommand` that validates a run-time command, so a genesis argument
    // cannot create state a command could not.
    for (b in init.books.vals()) { genesisCommand(#openBook({ id = b.id; name = b.name; parent = b.parent })) };
    for (r in init.roles.vals()) { genesisCommand(#defineRole({ id = r.id; name = r.name; permissions = r.permissions })) };
    for (g in init.grants.vals()) { genesisCommand(#grantRole({ subject = g.subject; role = g.role; scope = g.scope })) };
    for (p in init.policies.vals()) { genesisCommand(#setDualPolicy(p)) };
    // Complete the policy table, so no permission is left with an implicit
    // default at run time.
    switch (init.defaultDual) {
      case (?d) {
        for (perm in P.catalogue().vals()) {
          if (perm.dualByDefault and BankCore.policyFor(bank, perm.id) == null) {
            genesisCommand(#setDualPolicy({ permission = perm.id; required = d.required; eligibleRole = d.eligibleRole; ttlSeconds = d.ttlSeconds }));
          };
        };
      };
      case null {};
    };
  };

  func genesisCommand(command : T.Command) {
    switch (BankCore.planCommand(bank, bankBlocks(), journal, journalBlocks(), me(), now(), command, BankCore.height(bank))) {
      case (#err(e)) Runtime.trap("Bank genesis: " # P.commandName(command) # " rejected: " # debug_show (e));
      case (#ok(plan)) {
        switch (plan.bankEvent) { case (?ev) ignore commitBank(installer, ev); case null {} };
        for (ev in plan.extra.vals()) { ignore commitBank(installer, ev) };
        for (step in plan.journal.vals()) {
          switch (step) { case (#event(ev)) ignore commitJournal(ev); case (#existing(_)) {} };
        };
      };
    };
  };

  // ═══════════════════════════════════════════════════════
  //  MAKER-CHECKER
  // ═══════════════════════════════════════════════════════

  public type ProposeResult = { proposal : Nat; commandHash : Blob; required : Nat; expiresAt : Nat64 };

  /// A maker proposes a dual-authorised command. Nothing it would do happens:
  /// no posting, no state change beyond the proposal block itself.
  public shared ({ caller }) func propose(command : T.Command, justification : Text) : async Result.Result<ProposeResult, T.BankError> {
    switch (requireMethodPermission(caller, "propose")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (BankCore.prepareProposal(bank, bankBlocks(), journal, journalBlocks(), me(), caller, now(), command, justification)) {
      case (#err(r)) fail<ProposeResult>(caller, BankCore.commandPermission(command), r);
      case (#ok(out)) {
        let b = commitBank(caller, out.event);
        switch (b.event) {
          case (#commandProposed(x)) #ok({ proposal = b.index; commandHash = x.commandHash; required = x.required; expiresAt = x.expiresAt });
          case (_) Runtime.trap("Bank: proposal block is not a proposal");
        }
      };
    }
  };

  /// `event` is the bank block the executed command's own event took, when it had one: a created
  /// party's or an opened account's id is that block.
  public type ApproveResult = { proposal : Nat; approvals : Nat; required : Nat; executed : Bool; postings : [Nat]; event : ?Nat };

  /// A checker approves. The approval carries the hash the checker saw; when it
  /// completes the policy the command executes in this same message, so there is
  /// no state in which a command is approved and unexecuted.
  public shared ({ caller }) func approve(proposal : Nat) : async Result.Result<ApproveResult, T.BankError> {
    switch (requireMethodPermission(caller, "approve")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (BankCore.prepareApprove(bank, journal, journalBlocks(), bankBlocks(), me(), caller, now(), proposal)) {
      case (#err(r)) {
        let perm = switch (BankCore.getProposal(bank, bankBlocks(), proposal)) { case (?v) v.permission; case null "command.approve" };
        fail<ApproveResult>(caller, perm, r)
      };
      case (#ok(out)) {
        ignore commitBank(caller, out.approval);
        switch (out.execute) {
          case null {
            let ?v = BankCore.getProposal(bank, bankBlocks(), proposal) else Runtime.trap("Bank: approved proposal vanished");
            let approvals = switch (v.status) { case (#awaitingApproval(x)) x.approvals.size(); case (_) 0 };
            #ok({ proposal; approvals; required = v.required; executed = false; postings = []; event = null })
          };
          case (?ex) {
            let postings = executeCommand(ex.maker, ex.command, ex.proposal);
            // the charge the fold applies, computed here from the command so the proposal body is never needed again
            ignore commitBank(caller, #commandExecuted({ proposal = ex.proposal; commandHash = ex.commandHash; postings; charge = BankCore.chargeOf(bank, ex.command) }));
            #ok({ proposal; approvals = ex.proposal; required = 0; executed = true; postings; event = lastExecutedEvent })
          };
        }
      };
    }
  };

  public shared ({ caller }) func reject(proposal : Nat, reason : Text) : async Result.Result<{ block : Nat }, T.BankError> {
    switch (requireMethodPermission(caller, "reject")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (BankCore.prepareReject(bank, bankBlocks(), caller, now(), proposal, reason)) {
      case (#err(r)) fail<{ block : Nat }>(caller, "command.reject", r);
      case (#ok(ev)) #ok({ block = commitBank(caller, ev).index });
    }
  };

  /// Expire proposals past their lifetime. Open to any caller, for the journal's
  /// own reason: expiry is a fact of the clock, the caller chooses nothing, and
  /// the block is attributed to the canister.
  public shared func expireProposals(limit : Nat) : async Nat {
    let expired = BankCore.expiredProposals(bank, now(), Nat.min(limit, 100));
    for (idx in expired.vals()) { ignore commitBank(me(), BankCore.expiryEvent(idx)) };
    expired.size()
  };

  public type AdvanceResult = {
    book : T.BookId;
    businessDate : ProdT.Day;
    cursor : Nat;
    items : Nat;
    posted : Nat;
    examined : Nat;
    zeroMovement : Nat;
    failures : Nat;
    completed : Bool;
    blocks : [Nat];
    postings : [Nat];
  };

  /// Advance an open end-of-day run by up to `limit` plan items.
  ///
  /// **Anyone may call this, and that is deliberate.** The plan was fixed when the run
  /// opened: it is re-derived here and checked against the hash the opening block
  /// recorded, so an advancing caller cannot choose what is posted — only that progress
  /// happens. The postings are attributed to the canister, never to the caller. The
  /// reasoning is the journal's own for its expiry sweep: an open advance path means a
  /// stalled timer cannot leave a bank unable to close its books.
  public shared func advanceEndOfDay(book : T.BookId, businessDate : ProdT.Day, limit : Nat) : async Result.Result<AdvanceResult, T.BankError> {
    // The run records through these, as it goes, so every job reads what the jobs before
    // it posted — in this very chunk as well as in earlier ones. Both append to the log
    // and apply to state, which is what `commitBank` and `commitJournal` do everywhere
    // else; the whole advance is one message, so a trap rolls all of it back.
    let recorder : BankCore.Recorder = {
      bank = func(ev : T.Event) : Nat { commitBank(me(), ev).index };
      journal = func(ev : JT.Event) : Nat { commitJournal(ev).index };
      monitor = monitorAtDay;
    };
    switch (BankCore.runEndOfDayChunk(bank, bankBlocks(), journal, journalBlocks(), me(), now(), book, businessDate, limit, recorder)) {
      case (#err(e)) #err(e);
      case (#ok(advance)) {
        let run = switch (BatchCore.getRun(bank.batch, book, businessDate)) {
          case (?r) BatchCore.runView(r);
          // unreachable: the advance ran against this run inside this message
          case null Runtime.trap("Bank: the run vanished while it was being advanced");
        };
        #ok({
          book; businessDate; cursor = run.cursor; items = run.items;
          posted = run.posted; examined = run.examined; zeroMovement = run.zeroMovement;
          failures = run.failures.size(); completed = advance.completed;
          blocks = advance.blocks; postings = advance.postings;
        })
      };
    }
  };

  public type PackAdvanceResult = { pack : Nat; phase : Text; work : Nat; sealed : Bool; block : Nat };

  /// One bounded step of the open pack. Open to any caller for the same reason `advanceEndOfDay`
  /// is: the pack's range and phases were fixed by the dual-authorised opening, every segment has
  /// round-tripped before it is stored, and the blocks are attributed to the canister. Each step
  /// is a bank block — a segment, an advance, the seal — so the log carries the pack's progress and
  /// a restart resumes from what the engine holds.
  public shared func advancePacking(limit : Nat) : async Result.Result<PackAdvanceResult, T.BankError> {
    let ?_ = bank.packing.current else return #err(#PackingError({ error = #NotPacking }));
    switch (Packing.advance(packing, packingContext(), limit)) {
      case (#err(e)) #err(#PackingError({ error = e }));
      case (#ok(a)) {
        let ev : PkT.PackingEvent = switch (a.segment, a.bankSegment) {
          case (?sg, _) #segmentPacked({ pack = sg.pack; seq = sg.seq; lo = sg.lo; hi = sg.hi; bytes = sg.bytes; rawBytes = sg.rawBytes; postings = sg.postings; sha256 = sg.sha256 });
          case (null, ?bg) #bankSegmentPacked({ pack = bg.pack; seq = bg.seq; lo = bg.lo; hi = bg.hi; bytes = bg.bytes; rawBytes = bg.rawBytes; dropped = bg.dropped; kept = bg.kept; sha256 = bg.sha256 });
          case (null, null) {
            if (a.sealed) {
              let ?p = Packing.getPack(packing, a.pack) else Runtime.trap("Bank: a pack sealed in this message is missing");
              #packSealed({ pack = p.pack; segments = p.segments; postings = p.postings; accounts = p.accounts; packedBytes = p.packedBytes; rawBytes = p.rawBytes; sha256 = p.sha256; hi = p.hi; periodEnd = p.periodEnd;
                            bankHi = p.bankHi; bankSegments = p.bankSegments; bankPackedBytes = p.bankPackedBytes; bankRawBytes = p.bankRawBytes; bankDropped = p.bankDropped; bankKept = p.bankKept })
            } else #packAdvanced({ pack = a.pack; phase = a.phase; work = a.work })
          };
        };
        let b = commitBank(me(), #packing(ev));
        // the bank log's prefix through the pack's bank range leaves the StableLog: the pack holds every
        // block and every reader reads below the base from it (§18.3); the MMR and the tip are unchanged
        if (a.sealed) { let ?p = Packing.getPack(packing, a.pack) else Runtime.trap("Bank: a pack sealed in this message is missing"); BLog.truncateThrough(bankLog, p.bankHi) };
        #ok({ pack = a.pack; phase = a.phase; work = a.work; sealed = a.sealed; block = b.index })
      };
    }
  };

  public type RollAdvanceResult = { pack : Nat; phase : Text; work : Nat; sent : ?Nat; done : Bool; block : Nat };

  /// One bounded step of the open archive roll. Open for the same reason `advancePacking` is. A
  /// segment to send is recorded (`#segmentSent`) **before** the call to the archive is made, and
  /// the call's reply is not waited for: the archive acknowledges by calling back, and only that
  /// acknowledgement is recorded as the segment being archived.
  public shared func advanceArchiveRoll(limit : Nat) : async Result.Result<RollAdvanceResult, T.BankError> {
    let ?_ = bank.packing.roll else return #err(#PackingError({ error = #NotRolling }));
    switch (ArchiveRoll.advance(roll, rollContext(), limit)) {
      case (#err(e)) #err(#PackingError({ error = e }));
      case (#ok(a)) {
        let ev : PkT.PackingEvent = switch (a.send, a.checkpoint) {
          case (?sg, _) #segmentSent({ pack = a.pack; seq = sg.seq; attempt = sg.attempt });
          case (null, ?cp) #checkpointWritten({ pack = a.pack; through = cp.through; first = cp.first; last = cp.last });
          case (null, null) {
            if (a.done) {
              let ?where = ArchiveRoll.archiveOf(roll, a.pack) else Runtime.trap("Bank: a pack archived in this message has no archive");
              let ?p = Packing.getPack(packing, a.pack) else Runtime.trap("Bank: a pack archived in this message is missing");
              #packArchived({ pack = a.pack; cid = where.cid; archive = where.archive; hi = p.hi; journalBase = JLog.base(journalLog); segments = p.segments })
            } else #rollAdvanced({ pack = a.pack; phase = a.phase; work = a.work })
          };
        };
        let b = commitBank(me(), #packing(ev));
        switch (a.send) {
          case (?sg) {
            let ?j = ArchiveRoll.current(roll) else Runtime.trap("Bank: a roll that just advanced is gone");
            let child = actor (Principal.toText(j.archive)) : actor { putSegment : shared (Nat, Nat, Nat, Nat, Blob, Blob, Nat) -> async Result.Result<{ acknowledged : Bool }, { #NotParent; #HashMismatch : { computed : Blob; offered : Blob }; #DoesNotUnpack : { reason : Text }; #RangeMismatch : { lo : Nat; hi : Nat; blocks : Nat }; #Conflict : { held : Blob } }> };
            // fire, and do not wait: the block above is this message's record, the archive's own
            // acknowledgement is the next
            ignore child.putSegment(a.pack, sg.seq, sg.lo, sg.hi, sg.bytes, sg.sha256, sg.postings);
          };
          case null {};
        };
        #ok({ pack = a.pack; phase = a.phase; work = a.work; sent = switch (a.send) { case (?sg) ?sg.seq; case null null }; done = a.done; block = b.index })
      };
    }
  };

  /// The archive's word that it holds a segment. The caller must be the roll's declared archive
  /// principal, the segment one that was sent, the hash the segment's own; anything else is
  /// refused and recorded nowhere. Recorded as `#segmentArchived`.
  public shared ({ caller }) func acknowledgeArchivedSegment(pack : Nat, seq : Nat, sha256 : Blob) : async Bool {
    switch (ArchiveRoll.ack(roll, rollContext(), caller, pack, seq, sha256)) {
      case (#err(_)) false;
      case (#ok(_)) { ignore commitBank(me(), #packing(#segmentArchived({ pack; seq; sha256 }))); true };
    }
  };

  // ─── shards: the inter-shard transfer, step by step ───
  //
  // The shape is `ShardTypes.mo`'s: the sending shard reserves and records, sends and does not wait;
  // the receiving shard posts once under the transfer's own key and calls back; the sending shard
  // resolves the pending on the receiving shard's word and nothing else's.

  type ShardActor = actor {
    receiveShardTransfer : shared (Nat, Nat, Text, Nat, Text, Nat, Text, Text) -> async Result.Result<{ posting : Nat }, T.BankError>;
    acknowledgeShardTransfer : shared (Nat, Nat) -> async Result.Result<(), T.BankError>;
    rejectShardTransfer : shared (Nat, Text) -> async Result.Result<(), T.BankError>;
  };

  /// Send an open transfer to its shard. Open (`Permissions.openMethods`); recorded before the call.
  public shared func sendShardTransfer(transfer : Nat) : async Result.Result<{ attempt : Nat; block : Nat }, T.BankError> {
    let ev = switch (ShardCore.planSend(bank.shard, transfer)) { case (#err(e)) return #err(#ShardError({ error = e })); case (#ok(ev)) ev };
    let ?t = ShardCore.outbound(bank.shard, transfer) else return #err(#ShardError({ error = #UnknownTransfer({ transfer }) }));
    let ?to = ShardCore.shard(bank.shard, t.toShard) else return #err(#ShardError({ error = #UnknownShard({ shard = t.toShard }) }));
    let attempt = switch (ev) { case (#outboundSent(x)) x.attempt; case (_) 0 };
    let b = commitBank(me(), #shard(ev));
    let peer : ShardActor = actor (Principal.toText(to.principal));
    // fire, and do not wait: the receiving shard's own call back is what settles this
    ignore peer.receiveShardTransfer(ShardCore.selfIndex(bank.shard), transfer, t.toIdentifier, t.amount, t.currency, t.valueDay, t.period, t.narration);
    #ok({ attempt; block = b.index })
  };

  /// The receiving side. Caller held to a shard principal of the rule; the posting is idempotent
  /// in (sending shard, transfer). The sending shard is called back with the posting, or with the
  /// refusal.
  public shared ({ caller }) func receiveShardTransfer(fromShard : Nat, transfer : Nat, toIdentifier : Text, amount : Nat, currency : Text, valueDay : Nat, period : Text, narration : Text) : async Result.Result<{ posting : Nat }, T.BankError> {
    let ?_ = ShardCore.rule(bank.shard) else return #err(#ShardError({ error = #NoRule }));
    let ?from = ShardCore.shardByPrincipal(bank.shard, caller) else return #err(#ShardError({ error = #NotAShard({ caller }) }));
    if (from.index != fromShard) return #err(#ShardError({ error = #NotAShard({ caller }) }));
    let peer : ShardActor = actor (Principal.toText(from.principal));
    switch (ShardCore.inbound(bank.shard, fromShard, transfer)) {
      case (?x) {
        // a second delivery: posted already, acknowledged again
        ignore peer.acknowledgeShardTransfer(transfer, x.posting);
        return #ok({ posting = x.posting });
      };
      case null {};
    };
    switch (BankCore.planReceiveShardTransfer(bank, bankBlocks(), journal, me(), now(), caller, fromShard, transfer, toIdentifier, amount, currency, valueDay, period, narration)) {
      case (#err(e)) {
        // refused here, and the sending shard told so its customer's money comes back
        ignore commitBank(me(), #shard(#inboundRefused({ fromShard; transfer; toIdentifier; reason = debug_show (e) })));
        ignore peer.rejectShardTransfer(transfer, debug_show (e));
        #err(e)
      };
      case (#ok(r)) {
        let posting = switch (r.step) { case (#event(ev)) commitJournal(ev).index; case (#existing(idx)) idx };
        ignore commitBank(me(), #shard(#inboundPosted({ fromShard; transfer; toAccount = r.account; amount; posting })));
        ignore peer.acknowledgeShardTransfer(transfer, posting);
        #ok({ posting })
      };
    }
  };

  /// The receiving shard's word that it posted: the pending is posted here, once.
  public shared ({ caller }) func acknowledgeShardTransfer(transfer : Nat, receiverPosting : Nat) : async Result.Result<(), T.BankError> {
    switch (BankCore.planSettleShardTransfer(bank, journal, journalBlocks(), me(), now(), caller, transfer, receiverPosting)) {
      case (#err(e)) #err(e);
      case (#ok(r)) { ignore commitJournal(r.step); ignore commitBank(me(), #shard(r.event)); #ok(()) };
    }
  };

  /// The receiving shard's word that it could not: the pending is voided here, once.
  public shared ({ caller }) func rejectShardTransfer(transfer : Nat, reason : Text) : async Result.Result<(), T.BankError> {
    switch (BankCore.planReturnShardTransfer(bank, journal, journalBlocks(), me(), caller, transfer, reason)) {
      case (#err(e)) #err(e);
      case (#ok(r)) { ignore commitJournal(r.step); ignore commitBank(me(), #shard(r.event)); #ok(()) };
    }
  };

  public query func shardRule() : async ?ST.Rule { ShardCore.rule(bank.shard) };
  public query func shardRuleVersions() : async [ST.Rule] { ShardCore.versions(bank.shard) };
  public query func shardTransfer(transfer : Nat) : async ?ST.Outbound { ShardCore.outbound(bank.shard, transfer) };
  public query func shardInbound(fromShard : Nat, transfer : Nat) : async ?ST.Inbound { ShardCore.inbound(bank.shard, fromShard, transfer) };
  public query func openShardTransfers(limit : Nat) : async [ST.Outbound] { ShardCore.openTransfers(bank.shard, Nat.min(Nat.max(limit, 1), 500)) };
  public query func shardStatus() : async { open : Nat; settled : Nat; returned : Nat; inbound : Nat; version : Nat; self : Nat } {
    { ShardCore.counts(bank.shard) with self = ShardCore.selfIndex(bank.shard) }
  };
  /// The shard an identifier routes to under this bank's format: arithmetic on the identifier.
  public query func routeIdentifier(identifier : Text) : async ?{ shard : Nat; here : Bool; principal : ?Principal } {
    let ?fmt = PartyCore.format(bank.party) else return null;
    let ?shard = ShardCore.shardOf(fmt, identifier) else return null;
    ?{ shard; here = shard == ShardCore.selfIndex(bank.shard); principal = switch (ShardCore.shard(bank.shard, shard)) { case (?e) ?e.principal; case null null } }
  };

  // ─── settlement on the journal: the open paths ───

  /// Void every reservation past its deadline, up to `limit`, from the row cursor. Open: expiry is a
  /// fact of the clock.
  public shared func expireTransfers(limit : Nat) : async { examined : Nat; expired : Nat; next : ?Nat } {
    var cursor : ?Nat = null;
    var examined = 0;
    var expired = 0;
    let n = Nat.min(Nat.max(limit, 1), 2_000);
    label sweep loop {
      let page = SettlementCore.expiredTransfers(bank.settlement, now(), cursor, 200);
      for (id in page.ids.vals()) {
        switch (BankCore.planExpire(bank, journal, journalBlocks(), me(), now(), id)) {
          case (#ok(plan)) { executePlan(me(), plan); expired += 1 };
          case (#err(_)) {};
        };
      };
      examined += 200;
      switch (page.next) { case (?c) { cursor := ?c; if (examined >= n) break sweep }; case null { cursor := null; break sweep } };
    };
    { examined; expired; next = cursor }
  };

  func executePlan(authority : Principal, plan : BankCore.Plan) {
    switch (plan.bankEvent) { case (?ev) ignore commitBank(authority, ev); case null {} };
    for (ev in plan.extra.vals()) { ignore commitBank(authority, ev) };
    for (step in plan.journal.vals()) { switch (step) { case (#event(ev)) ignore commitJournal(ev); case (#existing(_)) {} } };
  };

  /// The netting fold of an open settlement, in chunks, and then the batch: one bounded step. The
  /// engine is `BankCore.advanceSettlement`, shared with the unit battery; the job's accumulator
  /// lives here across messages.
  let settlementJobs : Map.Map<Nat, BankCore.SettlementJob> = Map.empty<Nat, BankCore.SettlementJob>();

  public shared func advanceSettlement(settlement : Nat, limit : Nat) : async Result.Result<BankCore.SettlementAdvance, T.BankError> {
    let job = switch (Map.get(settlementJobs, Nat.compare, settlement)) { case (?j) j; case null { let j = BankCore.newSettlementJob(); Map.add(settlementJobs, Nat.compare, settlement, j); j } };
    let r = BankCore.advanceSettlement(bank, bankBlocks(), journal, journalBlocks(), me(), now(), settlement, job, limit, bankRecorder());
    switch (r) { case (#ok(a)) { if (a.done) ignore Map.delete(settlementJobs, Nat.compare, settlement) }; case (#err(_)) {} };
    r
  };

  /// A bulk's items, prepared and reserved, or committed, or voided, a chunk at a time.
  public shared func advanceBulk(bulk : Nat, limit : Nat) : async Result.Result<BankCore.BulkAdvance, T.BankError> {
    BankCore.advanceBulk(bank, bankBlocks(), journal, journalBlocks(), me(), now(), bulk, limit, bankRecorder())
  };

  func bankRecorder() : BankCore.Recorder {
    { bank = func(ev : T.Event) : Nat { commitBank(me(), ev).index }; journal = func(ev : JT.Event) : Nat { commitJournal(ev).index }; monitor = monitorAtDay }
  };

  // ─── ISO 20022 messaging on the journal ───

  /// One received business message on a rail: parsed, validated against its family's schema-derived
  /// profile, read, acted on through the settlement layer, and recorded as one block whatever the
  /// verdict. The caller holds `payments.message.ingest`; the rail may require a connector signature.
  public shared ({ caller }) func ingestMessage(rail : Text, xml : Blob, signature : ?Blob) : async Result.Result<BankCore.IngestResult, T.BankError> {
    switch (requireMethodPermission(caller, "ingestMessage")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    BankCore.ingestMessage(bank, bankBlocks(), journal, journalBlocks(), me(), now(), rail, xml, signature, verifyConnectorSignature, bankRecorder())
  };

  // ─── origination (origination and underwriting): the bureau's report ───

  /// A credit bureau's report on an application, from the bureau's connector: the caller holds
  /// `origination.bureau.record`; the report's signature is judged under the bureau key the policy
  /// registers, over the report's canonical bytes; the report is the block, attributed to the caller.
  public shared ({ caller }) func recordBureauReport(application : Nat, report : OT.BureauReport, signature : Blob) : async Result.Result<{ block : Nat }, T.BankError> {
    switch (requireMethodPermission(caller, "recordBureauReport")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (BankCore.planBureauReport(bank, application, report, signature, verifyConnectorSignature)) {
      case (#err(e)) fail<{ block : Nat }>(caller, "origination.bureau.record", { error = e; record = true });
      case (#ok(ev)) #ok({ block = commitBank(caller, ev).index });
    }
  };

  // ─── corporate lending (corporate lending): the agent's notice ───

  /// The agent's notice on a facility the bank participates in, from the agent's connector: the caller holds
  /// `facility.notice.record`; the signature is judged under the agent key the facility's terms carry, over the
  /// notice's canonical bytes; a drawdown funds the bank's share, a repayment or a distribution repays it.
  public shared ({ caller }) func recordAgentNotice(facility : Nat, notice : FaT.AgentNotice, signature : Blob) : async Result.Result<{ block : Nat; postings : [Nat] }, T.BankError> {
    switch (requireMethodPermission(caller, "recordAgentNotice")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (BankCore.planAgentNotice(bank, bankBlocks(), journal, me(), now(), facility, notice, signature, verifyConnectorSignature)) {
      case (#err(e)) fail<{ block : Nat; postings : [Nat] }>(caller, "facility.notice.record", { error = e; record = true });
      case (#ok(plan)) {
        let at = BankCore.height(bank);
        switch (plan.bankEvent) { case (?ev) ignore commitBank(caller, ev); case null {} };
        for (ev in plan.extra.vals()) ignore commitBank(caller, ev);
        let postings = List.empty<Nat>();
        for (step in plan.journal.vals()) { switch (step) { case (#event(ev)) List.add(postings, commitJournal(ev).index); case (#existing(idx)) List.add(postings, idx) } };
        #ok({ block = at; postings = List.toArray(postings) })
      };
    }
  };

  /// The post-quantum connector schemes (M-6). Verification is over the exact message bytes.
  func verifyConnectorSignature(scheme : PayT.SignatureScheme, publicKey : Blob, message : Blob, signature : Blob) : Bool {
    switch (scheme) {
      case (#none) true;
      case (#mayo2) PqSchemes.verifyMayo2(publicKey, message, signature);
      case (#mldsa44) PqSchemes.verifyMlDsa44(publicKey, message, signature);
    }
  };

  /// One FSPIOP v1.1 request on a rail, from the relay that holds `payments.fspiop.handle`: the
  /// specification's status and body, and the callbacks the relay delivers to the destination FSPs.
  public shared ({ caller }) func fspiop(rail : Text, request : FT.Request) : async Result.Result<FT.Response, T.BankError> {
    switch (requireMethodPermission(caller, "fspiop")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    BankCore.handleFspiop(bank, bankBlocks(), journal, journalBlocks(), me(), now(), rail, request, bankRecorder())
  };
  public query func fspiopParticipants(rail : Text) : async [FspiopCore.Participant] { FspiopCore.participants(bank.fspiop, rail) };
  public query func fspiopParty(rail : Text, idType : Text, id : Text, subId : ?Text) : async ?FspiopCore.Party { FspiopCore.party(bank.fspiop, rail, idType, id, subId) };
  public query func fspiopTransfer(rail : Text, transferId : Text) : async ?FspiopCore.TransferRow { FspiopCore.transferOf(bank.fspiop, rail, transferId) };
  public query func fspiopQuote(rail : Text, quoteId : Text) : async ?{ condition : Blob; transferAmount : Nat; answered : Bool } { FspiopCore.quoteOf(bank.fspiop, rail, quoteId) };
  public query func fspiopEndpoint(rail : Text, fspId : Text, endpointType : Text) : async ?Text { FspiopCore.endpoint(bank.fspiop, rail, fspId, endpointType) };
  public query func fspiopStatus() : async { participants : Nat; parties : Nat; transfers : Nat; quotes : Nat; requests : Nat; refused : Nat; forwarded : Nat } { FspiopCore.counts(bank.fspiop) };
  /// Every operation of FSPIOP v1.1 (the official snippets' table) and whether this switch implements it.
  public query func fspiopOperations() : async [{ method : Text; path : Text; operationId : Text; implemented : Bool }] {
    Array.map<FspiopProfiles.Operation, { method : Text; path : Text; operationId : Text; implemented : Bool }>(FspiopProfiles.OPERATIONS, func(op) {
      var impl = false;
      for ((m, p) in FT.IMPLEMENTED.vals()) { if (m == op.method and p == op.path) impl := true };
      { method = op.method; path = op.path; operationId = op.operationId; implemented = impl }
    })
  };
  /// The provenance of the request profile: the snippets package, version and commit it was generated from.
  public query func fspiopProfileSource() : async { package : Text; version : Text; commit : Text; api : Text } { FspiopProfiles.SOURCE };
  public query func fspiopEndpointTypes() : async [Text] { FT.ENDPOINT_TYPES };

  public query func validateMessage(xml : Blob) : async { family : Text; issues : [PayT.Issue] } { BankCore.validateMessage(xml) };
  public query func listRails() : async [PayT.Rail] { PaymentsCore.rails(bank.payments) };
  public query func getRail(id : Text) : async ?PayT.Rail { PaymentsCore.rail(bank.payments, id) };
  public query func getConnectorKey(rail : Text, bic : Text) : async ?PayT.ConnectorKey { PaymentsCore.connectorKey(bank.payments, rail, bic) };
  public query func getMessage(id : Nat) : async ?PayT.Message { PaymentsCore.message(bank.payments, paymentsBlocks(), id) };
  public query func messageByMessageId(rail : Text, messageId : Text) : async ?Nat { PaymentsCore.messageByMessageId(bank.payments, rail, messageId) };
  public query func listMessages(cursor : ?Nat, limit : Nat) : async { ids : [Nat]; next : ?Nat } { PaymentsCore.messageIds(bank.payments, cursor, Nat.min(Nat.max(limit, 1), 500)) };
  public query func holdOf(transfer : Nat) : async ?Text { PaymentsCore.holdOf(bank.payments, transfer) };
  public query func paymentsStatus() : async { rails : Nat; keys : Nat; messages : Nat; accepted : Nat; refused : Nat; held : Nat; holdsOpen : Nat; mandates : Nat; authorities : Nat; expected : Nat; settlementRequests : Nat } { PaymentsCore.counts(bank.payments) };
  // ── the extended target list: the mandate register, the debit authorities, the expected receipts, the settlement requests, and the answers ──
  public query func getMandate(rail : Text, mandateId : Text) : async ?PayT.Mandate { PaymentsCore.mandate(bank.payments, rail, mandateId) };
  public query func listMandates(rail : Text, cursor : ?Blob, limit : Nat) : async { mandates : [PayT.Mandate]; next : ?Blob } { PaymentsCore.mandates(bank.payments, rail, cursor, Nat.min(Nat.max(limit, 1), 500)) };
  public query func debitAuthorities(rail : Text) : async [PayT.DebitAuthority] { PaymentsCore.authorities(bank.payments, rail) };
  public query func expectedReceipt(rail : Text, reference : Text) : async ?PaymentsCore.Expected { PaymentsCore.expectedReceipt(bank.payments, rail, reference) };
  public query func settlementRequestOf(settlement : Nat) : async ?{ message : Nat; movements : [PayT.Movement]; judged : ?Bool } { PaymentsCore.settlementRequest(bank.payments, settlement) };
  public query func messageFamilies() : async [(Text, Nat8)] { Array.map<(PayT.Family, Text, Nat8), (Text, Nat8)>(PayT.FAMILIES, func((_, n, o)) { (n, o) }) };
  /// The pain.012 derived from the bank's decision on a mandate (the `#mandateDecided` block), naming
  /// the initiating pain.009 as the original message.
  public query func mandateAcceptanceReport(decision : Nat) : async ?Text {
    let ?b = bankBlock(decision) else return null;
    let #payments(#mandateDecided(d)) = b.event else return null;
    let ?m = PaymentsCore.mandate(bank.payments, d.rail, d.mandateId) else return null;
    let originalId = switch (PaymentsCore.message(bank.payments, paymentsBlocks(), m.mandate)) { case (?msg) msg.messageId; case null Nat.toText(m.mandate) };
    ?IsoMessages.pain012Xml("PAIN012-" # Nat.toText(decision), IsoMessages.isoDateTime(now()), originalId, "pain.009.001.07", d.mandateId, d.accepted, d.reason)
  };
  /// The camt.025 receipt answering a camt.050 liquidity transfer (accepted when the posting was made,
  /// rejected with the refusal's rule otherwise).
  public query func liquidityReceipt(message : Nat) : async ?Text {
    let ?m = PaymentsCore.message(bank.payments, paymentsBlocks(), message) else return null;
    if (m.family != #camt050) return null;
    var status = "RJCT"; var desc : ?Text = null;
    for (o in m.outcomes.vals()) { switch (o) { case (#liquidityTransferred(l)) { status := "ACPT"; desc := ?("posting " # Nat.toText(l.posting)) }; case (#refused(x)) desc := ?(x.rule # ": " # x.detail); case (_) {} } };
    if (m.issues.size() > 0) desc := ?(m.issues[0].rule # ": " # m.issues[0].detail);
    ?IsoMessages.camt025Xml("CAMT025-" # Nat.toText(message), IsoMessages.isoDateTime(now()), m.messageId, ?"camt.050.001.05", status, desc)
  };
  /// The admi.007 receipt acknowledgement answering an administrative request (admi.006, admi.017).
  public query func receiptAcknowledgement(message : Nat) : async ?Text {
    let ?m = PaymentsCore.message(bank.payments, paymentsBlocks(), message) else return null;
    if (m.family != #admi006 and m.family != #admi017) return null;
    var desc : ?Text = null;
    for (o in m.outcomes.vals()) { switch (o) { case (#resendRequested(r)) desc := ?(switch (r.message) { case (?id) "message " # Nat.toText(id) # " found; its answer is statusReport(" # Nat.toText(id) # ")"; case null "no message " # r.reference # " on this rail" }); case (#processingRequested(p)) desc := ?("request " # p.requestType # " recorded"); case (#refused(x)) desc := ?(x.rule # ": " # x.detail); case (_) {} } };
    if (m.issues.size() > 0) desc := ?(m.issues[0].rule # ": " # m.issues[0].detail);
    ?IsoMessages.admi007Xml("ADMI007-" # Nat.toText(message), IsoMessages.isoDateTime(now()), m.messageId, if (m.verdict == #refused) "RJCT" else "ACPT", desc)
  };
  /// The report answering the n-th reporting request of a camt.060 message: a camt.052 intraday
  /// report or a camt.053 statement of the account named, over the period the request's dates fall
  /// in (today's when none is given), naming the request as the original business query.
  public shared query ({ caller }) func reportForRequest(message : Nat, index : Nat) : async Result.Result<{ xml : Text; kind : Text; account : ProdT.AccountId; period : JT.PeriodId }, T.BankError> {
    let ?m = PaymentsCore.message(bank.payments, paymentsBlocks(), message) else return #err(#PaymentsError({ error = #UnknownMessage({ message }) }));
    var seen = 0; var found : ?{ requestId : Text; kind : Text; account : ?Nat; fromDay : ?Nat; toDay : ?Nat } = null;
    for (o in m.outcomes.vals()) { switch (o) { case (#reportRequested(r)) { if (seen == index) found := ?r; seen += 1 }; case (_) {} } };
    let ?req = found else return #err(#PaymentsError({ error = #UnknownMessage({ message }) }));
    let ?account = req.account else return #err(#ProductError({ error = #UnknownAccount({ account = 0 }) }));
    switch (scopedAccount(caller, account)) {
      case (#err(e)) #err(e);
      case (#ok(_)) {
        let day = switch (req.fromDay) { case (?d) d; case null JCore.effectiveToday(journal, now()) };
        let ?period = BankCore.periodOfDay(journal, day) else return #err(#ReportError({ error = #UnknownPeriod({ period = "day " # Nat.toText(day) }) }));
        let ?(st, mu) = camtStatement(account, period) else return #err(#ReportError({ error = #UnknownPeriod({ period }) }));
        let ?entry = ProductCore.get(bank.product, productBlocks(), account) else return #err(#ProductError({ error = #UnknownAccount({ account }) }));
        let creation = IsoMessages.isoDateTime(now());
        let entries = Array.map<JCamt.StatementEntry, IsoMessages.Entry>(st.entries, func(e) { isoEntry(e) });
        func bal(code : Text, debits : Nat, credits : Nat, d : Nat) : IsoMessages.Balance { { code; amount = { currency = st.currency; minor = if (credits >= debits) credits - debits else debits - credits }; credit = credits >= debits; day = d } };
        let live = JCore.balance(journal, st.account, ?entry.subledger, st.currency);
        let balances = [bal("OPBD", st.openingDebits, st.openingCredits, st.periodStart), bal("CLBD", st.closingDebits, st.closingCredits, st.periodEnd), bal("CLAV", live.debitsPosted + live.debitsPending, live.creditsPosted + live.creditsPending, st.periodEnd)];
        let kind = if (Text.startsWith(req.kind, #text "camt.052")) "camt.052.001.08" else "camt.053.001.08";
        let xml = if (kind == "camt.052.001.08")
          IsoMessages.camt052Xml("THEBES-052R-" # Nat.toText(message) # "-" # Nat.toText(index), creation, req.requestId, ?(m.messageId, "camt.060.001.05"), ?entry.identifier, Nat.toText(account), st.currency, mu, st.periodStart, st.periodEnd, balances, entries)
        else IsoMessages.camt053Xml("THEBES-053R-" # Nat.toText(message) # "-" # Nat.toText(index), creation, req.requestId, ?entry.identifier, Nat.toText(account), st.currency, mu, st.periodStart, st.periodEnd, balances, entries);
        #ok({ xml; kind; account; period })
      };
    }
  };
  /// The pacs.002 answering a received message — schema-valid, one TxInfAndSts per transaction.
  public query func statusReport(message : Nat) : async ?Text { BankCore.statusReportXml(bank, bankBlocks(), now(), message) };
  public query func statusActions() : async [(Text, Text)] { PayT.STATUS_ACTIONS };

  func paymentsBlocks() : PaymentsCore.Blocks { { get = func(i : Nat) : ?PayT.PaymentsEvent { switch (bankBlock(i)) { case (?b) { switch (b.event) { case (#payments(pe)) ?pe; case (_) null } }; case null null } } } };

  /// A participant account's statement in the schema's own shape (camt.053.001.08), from the book:
  /// opening and closing from the period's fold, one entry per journal block, each naming its block.
  /// The compact shape the deployed example reads is `statementCamt053`.
  public shared query ({ caller }) func accountStatementIso(account : ProdT.AccountId, period : JT.PeriodId) : async Result.Result<{ xml : Text; entries : Nat; blocks : [Nat] }, T.BankError> {
    switch (scopedAccount(caller, account)) {
      case (#err(e)) #err(e);
      case (#ok(_)) {
        let ?(st, mu) = camtStatement(account, period) else return #err(#ReportError({ error = #UnknownPeriod({ period }) }));
        let ?entry = ProductCore.get(bank.product, productBlocks(), account) else return #err(#ProductError({ error = #UnknownAccount({ account }) }));
        let creation = IsoMessages.isoDateTime(now());
        let entries = Array.map<JCamt.StatementEntry, IsoMessages.Entry>(st.entries, func(e) { isoEntry(e) });
        func bal(code : Text, debits : Nat, credits : Nat, day : Nat) : IsoMessages.Balance { { code; amount = { currency = st.currency; minor = if (credits >= debits) credits - debits else debits - credits }; credit = credits >= debits; day } };
        let live = JCore.balance(journal, st.account, ?entry.subledger, st.currency);
        let balances = [
          bal("OPBD", st.openingDebits, st.openingCredits, st.periodStart),
          bal("CLBD", st.closingDebits, st.closingCredits, st.periodEnd),
          bal("CLAV", live.debitsPosted + live.debitsPending, live.creditsPosted + live.creditsPending, st.periodEnd),
        ];
        let xml = IsoMessages.camt053Xml("THEBES-053I-" # Nat.toText(account) # "-H" # Nat.toText(BankCore.height(bank)), creation, period # "-" # Nat.toText(account), ?entry.identifier, Nat.toText(account), st.currency, mu, st.periodStart, st.periodEnd, balances, entries);
        #ok({ xml; entries = entries.size(); blocks = Statements.entryBlocks(st) })
      };
    }
  };

  /// A participant account's statement in the compact shape the deployed published ISO 20022 example
  /// reads (`iso20022-xml-subset-v1`, Statements.mo), from the book rather than from an end-of-day
  /// cut: opening and closing are the period's fold at the query height, which the message id names.
  public shared query ({ caller }) func participantStatementCamt053(account : ProdT.AccountId, period : JT.PeriodId) : async Result.Result<{ xml : Text; entryBlocks : [Nat]; balances : [RepT.StatementBalance] }, T.BankError> {
    switch (scopedAccount(caller, account)) {
      case (#err(e)) #err(e);
      case (#ok(_)) {
        let ?(st, mu) = camtStatement(account, period) else return #err(#ReportError({ error = #UnknownPeriod({ period }) }));
        let ?entry = ProductCore.get(bank.product, productBlocks(), account) else return #err(#ProductError({ error = #UnknownAccount({ account }) }));
        let balances = Statements.statementBalances(journal, st.account, ?entry.subledger, st.currency,
          { openingDebits = st.openingDebits; openingCredits = st.openingCredits; closingDebits = st.closingDebits; closingCredits = st.closingCredits }, null);
        let xml = Statements.camt053Xml(st, balances, mu, "THEBES-053P-" # Nat.toText(account) # "-H" # Nat.toText(BankCore.height(bank)), IsoMessages.isoDateTime(now()));
        #ok({ xml; entryBlocks = Statements.entryBlocks(st); balances })
      };
    }
  };

  /// One movement of a participant account as a camt.054.001.08 notification.
  public shared query ({ caller }) func accountNotificationIso(account : ProdT.AccountId, period : JT.PeriodId, block : Nat) : async Result.Result<{ xml : Text }, T.BankError> {
    switch (scopedAccount(caller, account)) {
      case (#err(e)) #err(e);
      case (#ok(_)) {
        let ?(st, mu) = camtStatement(account, period) else return #err(#ReportError({ error = #UnknownPeriod({ period }) }));
        let ?entry = ProductCore.get(bank.product, productBlocks(), account) else return #err(#ProductError({ error = #UnknownAccount({ account }) }));
        for (e in st.entries.vals()) {
          if (e.paymentId == block) return #ok({ xml = IsoMessages.camt054Xml("THEBES-054I-" # Nat.toText(block), IsoMessages.isoDateTime(now()), "NTF-" # Nat.toText(block), ?entry.identifier, Nat.toText(account), st.currency, mu, isoEntry(e)) });
        };
        #err(#ReportError({ error = #UnknownPeriod({ period }) }))
      };
    }
  };

  /// The schema's `UETR` is the payment's own (ISO UUIDv4Identifier): for a posting a settlement
  /// transfer made, the transfer's reference when that is a UUID v4; the journal's derived
  /// version-8 identifier is not one and is left out (the element is optional).
  func isoEntry(e : JCamt.StatementEntry) : IsoMessages.Entry {
    let day = CivilDate.fromNanos(Int.abs(e.bookedAt));
    let uetr : ?Text = switch (JLog.get(journalLog, e.paymentId)) {
      case (?b) {
        let rec : ?JT.PostingRecord = switch (b.event) { case (#posted(r)) ?r; case (#pending(p)) ?p.record; case (#post(x)) { switch (JLog.get(journalLog, x.pendingIndex)) { case (?pb) { switch (pb.event) { case (#pending(p)) ?p.record; case (_) null } }; case null null } }; case (_) null };
        switch (rec) {
          case (?r) {
            if (r.sourceRef.kind == "PRINCIPLE_VALUE") {
              let parts = Array.fromIter<Text>(Text.split(r.sourceRef.id, #char '/'));
              switch (if (parts.size() == 2) Nat.fromText(parts[1]) else null) {
                case (?tid) { switch (SettlementCore.transfer(bank.settlement, settlementBlocks(), tid)) { case (?t) { if (Rx.test("[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}", t.reference) == ?true) ?t.reference else null }; case null null } };
                case null null;
              }
            } else null
          };
          case null null;
        }
      };
      case null null;
    };
    { reference = e.entryId; amount = { currency = e.amount.currency; minor = e.amount.minorUnits }; credit = e.creditDebit == "CRDT"; bookingDay = day; valueDay = day;
      uetr; endToEndId = null; block = e.paymentId; counterparty = if (Text.size(e.counterpartyName) > 0) ?e.counterpartyName else null; remittance = e.remittance }
  };

  // ─── settlement reads ───
  public query func listSchemes() : async [SeT.Scheme] { SettlementCore.schemes(bank.settlement) };
  public query func getScheme(id : Text) : async ?SeT.Scheme { SettlementCore.scheme(bank.settlement, id) };
  public query func listParticipants() : async [SeT.Participant] { SettlementCore.participants(bank.settlement) };
  public query func getParticipant(id : Nat) : async ?SeT.Participant { SettlementCore.participant(bank.settlement, id) };
  public query func getTransfer(id : Nat) : async ?SeT.Transfer { SettlementCore.transfer(bank.settlement, settlementBlocks(), id) };
  public query func transferByReference(scheme : Text, reference : Text) : async ?Nat { SettlementCore.transferByReference(bank.settlement, scheme, reference) };
  public query func listSettlementWindows() : async [SeT.Window] { SettlementCore.windows(bank.settlement) };
  public query func getSettlementWindow(id : Nat) : async ?SeT.Window { SettlementCore.window(bank.settlement, id) };
  public query func windowTransfers(window : Nat, cursor : ?Nat, limit : Nat) : async { ids : [Nat]; next : ?Nat } { SettlementCore.windowTransferIds(bank.settlement, window, cursor, Nat.min(Nat.max(limit, 1), 500)) };
  public query func listSettlements() : async [SeT.Settlement] { SettlementCore.settlements(bank.settlement) };
  public query func getSettlement(id : Nat) : async ?SeT.Settlement { SettlementCore.settlement(bank.settlement, id) };
  public query func getBulk(id : Nat) : async ?SeT.Bulk { SettlementCore.bulk(bank.settlement, settlementBlocks(), id) };
  public query func bulkTransfers(bulk : Nat, cursor : ?Nat, limit : Nat) : async { ids : [Nat]; next : ?Nat } { SettlementCore.bulkTransferIds(bank.settlement, bulk, cursor, Nat.min(Nat.max(limit, 1), 500)) };
  public query func settlementStatus() : async { schemes : Nat; participants : Nat; transfers : Nat; windows : Nat; settlements : Nat; bulks : Nat; byState : [(Text, Nat)] } { SettlementCore.counts(bank.settlement) };
  public query func transferStateMap() : async [(Text, Text, Text, Bool)] { SeT.TRANSFER_STATE_MAP };
  public query func settlementEntryKinds() : async [Text] { SeT.ENTRY_KINDS };

  public type PerformResult = { block : Nat; postings : [Nat] };

  /// A single-authority command: one whose permission has no dual-authorisation
  /// policy. A money-moving permission always has one, so it can never arrive
  /// here.
  public shared ({ caller }) func perform(command : T.Command) : async Result.Result<PerformResult, T.BankError> {
    switch (requireMethodPermission(caller, "perform")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (BankCore.preparePerform(bank, bankBlocks(), journal, journalBlocks(), me(), caller, now(), command)) {
      case (#err(r)) fail<PerformResult>(caller, BankCore.commandPermission(command), r);
      case (#ok(_)) {
        let at = BankCore.height(bank);
        let postings = executeCommand(caller, command, at);
        #ok({ block = at; postings })
      };
    }
  };

  public type OverrideResult = { override_ : Nat; postings : [Nat] };

  /// The emergency path: a distinct permission, a named witness who could have
  /// approved, and a mandatory review that blocks the period close.
  public shared ({ caller }) func emergencyOverride(command : T.Command, witness : Principal, justification : Text) : async Result.Result<OverrideResult, T.BankError> {
    switch (requireMethodPermission(caller, "emergencyOverride")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (BankCore.prepareOverride(bank, bankBlocks(), journal, journalBlocks(), me(), caller, now(), command, witness, justification)) {
      case (#err(r)) fail<OverrideResult>(caller, "command.breakGlass", r);
      case (#ok(out)) {
        let b = commitBank(caller, out.event);
        let postings = executeCommand(caller, command, b.index);
        ignore commitBank(caller, #commandExecuted({ proposal = b.index; commandHash = C.commandHash(command); postings; charge = BankCore.chargeOf(bank, command) }));
        #ok({ override_ = b.index; postings })
      };
    }
  };

  public shared ({ caller }) func reviewOverride(index : Nat, disposition : Text) : async Result.Result<{ block : Nat }, T.BankError> {
    switch (requireMethodPermission(caller, "reviewOverride")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (BankCore.prepareReviewOverride(bank, bankBlocks(), caller, index, disposition)) {
      case (#err(e)) #err(e);
      case (#ok(ev)) #ok({ block = commitBank(caller, ev).index });
    }
  };

  // ═══════════════════════════════════════════════════════
  //  BANK QUERIES
  // ═══════════════════════════════════════════════════════

  public query func bankAdmin() : async Principal { bank.admin };
  public query func bankHeight() : async Nat { BankCore.height(bank) };
  /// Read scoping. A single-object read outside the caller's
  /// books is a typed refusal; a list read returns the rows in scope **and the
  /// number withheld**, because a page that silently omits rows is how a scoping
  /// bug becomes a data-leak finding. A caller with no grant reads nothing.
  public type Page<X> = { rows : [X]; withheld : Nat; scope : ?[T.BookId] };

  /// A cursor page: the rows, the scope filter's withheld count, and the cursor to resume at.
  ///
  /// `Page<X>` above filters by book scope but still builds the whole list, so it bounds the *reply*
  /// and not the *work*. Criterion 2 of the index proposal is that every unpaged read is gone, so
  /// every list that grows with the bank now returns this instead: the underlying accessor seeks to
  /// the cursor and walks one page, so the cost is the page and not the position.
  ///
  /// `total` is the whole population before the scope filter, so a caller can see how much it is
  /// paging through. `withheld` is what this page's scope filter dropped, not a running total —
  /// a cursor page cannot know what earlier pages withheld without keeping state nobody asked for.
  public type CursorPage<X, C> = { rows : [X]; cursor : ?C; total : Nat; withheld : Nat; scope : ?[T.BookId] };

  /// Apply the book-scope filter to one page's rows. The cursor is the accessor's, untouched: a row
  /// the scope withholds must still advance the cursor past it, or a restricted caller would loop.
  func scopePage<X, C>(caller : Principal, rows : [X], cursor : ?C, total : Nat, bookOf : X -> ?T.BookId) : CursorPage<X, C> {
    let sc = readScope(caller);
    let kept = List.empty<X>();
    var withheld = 0;
    for (x in rows.vals()) {
      if (BankCore.mayReadOptBook(sc, bookOf(x))) List.add(kept, x) else withheld += 1;
    };
    { rows = List.toArray(kept); cursor; total; withheld; scope = sc }
  };

  func readScope(caller : Principal) : ?[T.BookId] { BankCore.readableBooks(bank, caller) };

  func page<X>(caller : Principal, all : [X], bookOf : X -> ?T.BookId) : Page<X> {
    let sc = readScope(caller);
    let rows = List.empty<X>();
    var withheld = 0;
    for (x in all.vals()) {
      if (BankCore.mayReadOptBook(sc, bookOf(x))) List.add(rows, x) else withheld += 1;
    };
    { rows = List.toArray(rows); withheld; scope = sc }
  };

  /// Books are the bank's branch and office structure: tens, not millions, and bounded by a recorded
  /// act each. It is left unpaged deliberately, and the reason is stated so the next reader does not
  /// have to guess whether it was missed.
  public shared query ({ caller }) func listBooks() : async Page<T.Book> {
    page<T.Book>(caller, BankCore.listBooks(bank), func(b) { ?b.id })
  };
  public query func listRoles() : async [T.Role] { BankCore.listRoles(bank) };
  public query func listGrants() : async [T.GrantView] { BankCore.listGrants(bank) };
  public query func listPolicies() : async [T.DualPolicy] { BankCore.listPolicies(bank) };
  public query func listFeatures() : async [(T.FeatureId, Nat64)] { BankCore.listFeatures(bank) };
  public query func featureActivation(feature : T.FeatureId) : async Nat64 { BankCore.featureActivation(bank, feature) };
  public query func featureActive(feature : T.FeatureId) : async Bool { BankCore.featureActive(bank, feature) };
  /// A settled proposal's command rebuilt from the events its execution recorded, and whether the rebuilt
  /// command hashes to the hash the proposal block keeps — the rule under which a pack drops the body
  /// (DESIGN-bank.md §18.2). `family` is the command's, "" when the act is not one the reconstruction covers.
  public shared query ({ caller }) func reconstructProposal(index : Nat) : async Result.Result<{ command : ?T.Command; matches : Bool; family : Text }, T.BankError> {
    switch (BankCore.getProposal(bank, bankBlocks(), index)) {
      case null #err(#UnknownProposal({ index }));
      case (?v) {
        if (not BankCore.mayReadOptBook(readScope(caller), v.book)) return #err(#OutsideBookScope({ book = switch (v.book) { case (?b) b; case null "" } }));
        switch (BankCore.reconstructProposal(bank, bankBlocks(), index)) { case (?r) #ok(r); case null #err(#UnknownProposal({ index })) }
      };
    }
  };
  public shared query ({ caller }) func getProposal(index : Nat) : async Result.Result<T.ProposalView, T.BankError> {
    switch (BankCore.getProposal(bank, bankBlocks(), index)) {
      case null #err(#UnknownProposal({ index }));
      case (?v) {
        let book = v.book;
        if (BankCore.mayReadOptBook(readScope(caller), book)) #ok(v)
        else #err(#OutsideBookScope({ book = switch (book) { case (?b) b; case null "" } }))
      };
    }
  };

  public shared query ({ caller }) func listProposals(cursor : ?Nat, limit : Nat) : async CursorPage<T.ProposalView, Nat> {
    let p = BankCore.listProposalsPaged(bank, bankBlocks(), cursor, limit);
    scopePage<T.ProposalView, Nat>(caller, p.rows, p.cursor, p.total, func(v) { v.book })
  };

  public shared query ({ caller }) func auditTrail(cursor : ?Nat, limit : Nat) : async CursorPage<T.AuditRow, Nat> {
    // An audit row's book is its command's book, looked up through the proposal.
    let p = BankCore.auditTrailPaged(bank, bankBlocks(), cursor, limit);
    scopePage<T.AuditRow, Nat>(caller, p.rows, p.cursor, p.total, func(r) {
      switch (BankCore.getProposal(bank, bankBlocks(), r.proposal)) { case (?v) v.book; case null null }
    })
  };

  public shared query ({ caller }) func listOverrides(cursor : ?Nat, limit : Nat) : async CursorPage<BankCore.OverrideView, Nat> {
    let p = BankCore.listOverridesPaged(bank, bankBlocks(), cursor, limit);
    scopePage<BankCore.OverrideView, Nat>(caller, p.rows, p.cursor, p.total, func(o) { E.commandBook(o.command) })
  };
  public query func openOverrideCount() : async Nat { BankCore.openOverrideCount(bank) };
  /// A subject's own consumption is its own business: a caller reads its own
  /// figures, and a caller with an unrestricted book scope reads everyone's.
  public shared query ({ caller }) func listConsumed(cursor : ?(Principal, Text, Nat), limit : Nat) : async { rows : [T.ConsumedView]; cursor : ?(Principal, Text, Nat); total : Nat; withheld : Nat } {
    let unrestricted = switch (readScope(caller)) { case null true; case (?_) false };
    let p = BankCore.listConsumedPaged(bank, cursor, limit);
    let rows = List.empty<T.ConsumedView>();
    var withheld = 0;
    for (r in p.rows.vals()) {
      if (unrestricted or Principal.equal(r.subject, caller)) List.add(rows, r) else withheld += 1;
    };
    { rows = List.toArray(rows); cursor = p.cursor; total = p.total; withheld }
  };

  public shared query ({ caller }) func consumedBy(subject : Principal, currency : Text, day : Nat) : async Result.Result<Nat, T.BankError> {
    if (Principal.equal(subject, caller) or readScope(caller) == null) #ok(BankCore.consumedFor(bank, subject, currency, day))
    else #err(#OutsideSubjectScope({ subject }))
  };

  /// The catalogue, so the audit tool and an operator read the same table the
  /// canister enforces.
  public query func permissions() : async [T.Permission] { P.catalogue() };
  public query func openMethods() : async [(Text, Text)] { P.openMethods() };
  public query func permissionCounts() : async { total : Nat; moneyMoving : Nat; dualByDefault : Nat } {
    { total = P.count(); moneyMoving = P.moneyMovingCount(); dualByDefault = P.dualByDefaultCount() }
  };
  /// The permission a command requires, for a client that wants to know before
  /// it proposes.
  public query func permissionForCommand(command : T.Command) : async ?T.Permission { P.forCommand(command) };
  public query func commandHashOf(command : T.Command) : async Blob { C.commandHash(command) };

  public query func bankStatus() : async {
    height : Nat; proposals : Nat; openProposals : Nat; executed : Nat; refused : Nat;
    openOverrides : Nat; books : Nat; roles : Nat; grants : Nat; policies : Nat;
    fingerprint : Blob;
  } {
    {
      height = BankCore.height(bank);
      proposals = BankCore.proposalCount(bank);
      openProposals = BankCore.openProposalCount(bank);
      executed = BankCore.executedCount(bank);
      refused = BankCore.refusedCount(bank);
      openOverrides = BankCore.openOverrideCount(bank);
      books = BankCore.listBooks(bank).size();
      roles = BankCore.listRoles(bank).size();
      grants = BankCore.listGrants(bank).size();
      policies = BankCore.listPolicies(bank).size();
      fingerprint = BankCore.fingerprint(bank);
    }
  };

  // ─── party / CIF and KYC queries, scoped by book ───

  /// A party record outside the caller's books is a typed refusal. Note what the
  /// record contains: commitments, states and dates. There is no name in it to
  /// leak, which is the point of party and KYC section 1.1 — but the scope is enforced
  /// anyway, because which customers exist in which branch is itself information.
  public shared query ({ caller }) func getParty(id : PT.PartyId) : async Result.Result<PT.PartyView, T.BankError> {
    switch (PartyCore.get(bank.party, partyBlocks(), id)) {
      case null #err(#PartyError({ error = #UnknownParty({ party = id }) }));
      case (?p) {
        if (BankCore.mayReadBook(readScope(caller), p.book)) #ok(PartyCore.view(bank.party, p))
        else #err(#OutsideBookScope({ book = p.book }))
      };
    }
  };

  public shared query ({ caller }) func listParties(cursor : ?PT.PartyId, limit : Nat) : async CursorPage<PT.PartyView, PT.PartyId> {
    let p = PartyCore.listPartiesPaged(bank.party, partyBlocks(), cursor, limit);
    scopePage<PT.PartyView, PT.PartyId>(caller, p.rows, p.cursor, p.total, func(x) { ?x.book })
  };

  /// Lookup by an issued account identifier. The identifier is
  /// not personal data, and the party it names is returned only inside scope.
  public shared query ({ caller }) func partyByIdentifier(identifier : Text) : async Result.Result<PT.PartyId, T.BankError> {
    switch (PartyCore.byIdentifier(bank.party, identifier)) {
      case null #err(#PartyError({ error = #InvalidIdentifier({ identifier; reason = "no party holds this identifier" }) }));
      case (?id) {
        switch (PartyCore.bookOf(bank.party, id)) {
          case (?b) { if (BankCore.mayReadBook(readScope(caller), b)) #ok(id) else #err(#OutsideBookScope({ book = b })) };
          case null #err(#PartyError({ error = #UnknownParty({ party = id }) }));
        }
      };
    }
  };

  /// Is this identifier already a customer? The deduplication control of
  /// Commitments.mo, answered on a commitment the caller computes.
  public query func partyByDedupCommitment(commit : PT.Commitment) : async ?PT.PartyId {
    PartyCore.byDedup(bank.party, commit)
  };

  /// May money move for this party today, and if not, why. The same check the
  /// money path runs, exposed so a client can ask before it proposes.
  public query func partyPermitsMovement(id : PT.PartyId) : async Result.Result<(), PT.PartyError> {
    switch (PartyCore.permitsMovement(bank.party, partyBlocks(), id, JCore.effectiveToday(journal, now()))) {
      case null #ok(());
      case (?e) #err(e);
    }
  };

  public query func listScreeningLists() : async [PT.ScreeningList] { PartyCore.listLists(bank.party) };
  public query func getScreeningList(version : Text) : async ?PT.ScreeningList { PartyCore.getList(bank.party, version) };
  public query func screeningNormalisation() : async Text { Commit.NORMALISATION };
  public query func listSchemas() : async [PT.ExtensionSchema] { PartyCore.listSchemas(bank.party) };

  public shared query ({ caller }) func listCollateral(cursor : ?PT.CollateralId, limit : Nat) : async CursorPage<PT.Collateral, PT.CollateralId> {
    let p = PartyCore.listCollateralPaged(bank.party, partyBlocks(), cursor, limit);
    scopePage<PT.Collateral, PT.CollateralId>(caller, p.rows, p.cursor, p.total, func(c) { PartyCore.bookOf(bank.party, c.party) })
  };

  public query func collateralAllocations(id : PT.CollateralId) : async [PT.Allocation] {
    PartyCore.allocationsOf(bank.party, partyBlocks(), id)
  };

  /// The value still available to allocate against a collateral item: the
  /// valuation less the haircut, less what is already allocated.
  public query func collateralAvailable(id : PT.CollateralId) : async ?{ haircutValue : Nat; allocated : Nat; available : Nat } {
    switch (PartyCore.getCollateral(bank.party, partyBlocks(), id)) {
      case null null;
      case (?c) {
        let hv = PartyCore.haircutValue(c.valuation);
        let al = PartyCore.allocatedAgainst(c);
        ?{ haircutValue = hv; allocated = al; available = if (hv > al) hv - al else 0 }
      };
    }
  };

  public shared query ({ caller }) func listStaff(cursor : ?Principal, limit : Nat) : async CursorPage<PT.Staff, Principal> {
    let p = PartyCore.listStaffPaged(bank.party, cursor, limit);
    scopePage<PT.Staff, Principal>(caller, p.rows, p.cursor, p.total, func(st) { ?st.book })
  };

  public query func listCredentials() : async [PT.Credential] { PartyCore.listCredentials(bank.party) };
  public query func listJwks() : async [PT.Jwks] { PartyCore.listJwks(bank.party) };
  public query func accountFormat() : async ?Iban.Format { PartyCore.format(bank.party) };
  public query func reviewGraceDays() : async Nat { PartyCore.reviewGraceDays(bank.party) };

  /// Verify a set of field commitments against a party record without being told
  /// the values: the check a payment's originator block goes through (party and KYC
  /// section 1.2), so a message can never carry originator data that disagrees
  /// with the customer file. payments wires this to pacs.008.
  public query func verifyPartyFields(id : PT.PartyId, claimed : [PT.FieldCommit]) : async Result.Result<(), PT.PartyError> {
    switch (PartyCore.get(bank.party, partyBlocks(), id)) {
      case null #err(#UnknownParty({ party = id }));
      case (?p) { switch (PartyCore.verifyFields(p, claimed)) { case null #ok(()); case (?e) #err(e) } };
    }
  };

  public query func partyStatus() : async { parties : Nat; lists : Nat; schemas : Nat; collateral : Nat; staff : Nat; credentials : Nat } {
    {
      parties = PartyCore.partyCount(bank.party);
      lists = PartyCore.listCount(bank.party);
      schemas = PartyCore.schemaCount(bank.party);
      collateral = PartyCore.collateralCount(bank.party);
      staff = PartyCore.staffCount(bank.party);
      credentials = PartyCore.listCredentials(bank.party).size();
    }
  };

  // ─── the product engine ───
  //
  // Everything here recomputes: a balance is the journal's, an accrual is a fold
  // over value-dated balances, an arrears position is a fold over the schedule. No
  // query returns a figure that was stored when it was computed, which is why a
  // back-dated posting needs no recalculation for any of them to be right.

  public query func listProducts() : async [ProdT.ProductView] { ProductCore.listProductViews(bank.product) };

  public query func getProduct(id : ProdT.ProductId, version : ProdT.ProductVersion) : async ?ProdT.ProductView {
    switch (ProductCore.getVersion(bank.product, id, version)) { case (?v) ?ProductCore.productView(v); case null null }
  };

  public query func currentProduct(id : ProdT.ProductId) : async ?ProdT.ProductView {
    switch (ProductCore.currentVersion(bank.product, id)) { case (?v) ?ProductCore.productView(v); case null null }
  };

  public query func productStatus() : async { products : Nat; versions : Nat; accounts : Nat; tills : Nat } {
    BankCore.productStatus(bank)
  };

  public query func productFeatures() : async [(T.FeatureId, Nat64)] {
    Array.map<Text, (T.FeatureId, Nat64)>(ProdT.featureIds(), func(f) { (f, BankCore.featureActivation(bank, f)) })
  };

  /// A customer account, inside the caller's book scope. Which customers hold which
  /// accounts in which branch is itself information, so the scope is enforced here
  /// exactly as it is on parties.
  public shared query ({ caller }) func getProductAccount(id : ProdT.AccountId) : async Result.Result<ProdT.AccountView, T.BankError> {
    switch (ProductCore.get(bank.product, productBlocks(), id)) {
      case null #err(#ProductError({ error = #UnknownAccount({ account = id }) }));
      case (?a) {
        if (BankCore.mayReadBook(readScope(caller), a.book)) #ok(ProductCore.accountView(a))
        else #err(#OutsideBookScope({ book = a.book }))
      };
    }
  };

  public shared query ({ caller }) func listProductAccounts(cursor : ?ProdT.AccountId, limit : Nat) : async CursorPage<ProdT.AccountView, ProdT.AccountId> {
    let p = ProductCore.listAccountsPaged(bank.product, productBlocks(), cursor, limit);
    scopePage<ProdT.AccountView, ProdT.AccountId>(
      caller,
      Array.map<ProductCore.AccountEntry, ProdT.AccountView>(p.rows, func(a) { ProductCore.accountView(a) }),
      p.cursor, p.total, func(a) { ?a.book }
    )
  };

  public shared query ({ caller }) func accountByIdentifier(identifier : Text) : async Result.Result<ProdT.AccountView, T.BankError> {
    switch (ProductCore.byIdentifier(bank.product, identifier)) {
      case null #err(#ProductError({ error = #IdentifierNotIssued({ identifier }) }));
      case (?id) {
        switch (ProductCore.get(bank.product, productBlocks(), id)) {
          case null #err(#ProductError({ error = #UnknownAccount({ account = id }) }));
          case (?a) {
            if (BankCore.mayReadBook(readScope(caller), a.book)) #ok(ProductCore.accountView(a))
            else #err(#OutsideBookScope({ book = a.book }))
          };
        }
      };
    }
  };

  public shared query ({ caller }) func accountsOfParty(party : PT.PartyId) : async Result.Result<[ProdT.AccountView], T.BankError> {
    switch (PartyCore.bookOf(bank.party, party)) {
      case null #err(#PartyError({ error = #UnknownParty({ party }) }));
      case (?book) {
        if (not BankCore.mayReadBook(readScope(caller), book)) return #err(#OutsideBookScope({ book }));
        let out = List.empty<ProdT.AccountView>();
        for (id in ProductCore.accountsOfParty(bank.product, party).vals()) {
          switch (ProductCore.get(bank.product, productBlocks(), id)) { case (?a) List.add(out, ProductCore.accountView(a)); case null {} };
        };
        #ok(List.toArray(out))
      };
    }
  };

  /// The balance the engine sees: the journal figure on the account's own side, the
  /// facility it will admit against it, and what remains. Value-dated on the day
  /// asked about, defaulting to the business date.
  public shared query ({ caller }) func accountBalance(id : ProdT.AccountId, asOf : ?ProdT.Day) : async Result.Result<ProdT.BalanceView, T.BankError> {
    switch (scopedAccount(caller, id)) {
      case (#err(e)) #err(e);
      case (#ok(_)) BankCore.accountBalanceView(bank, bankBlocks(), journal, id, dayOr(asOf));
    }
  };

  /// The accrual since the account was last capitalised, exact and rounded. The
  /// unrounded rational is returned because it is what makes a dispute settleable.
  public shared query ({ caller }) func accruedInterest(id : ProdT.AccountId, to : ?ProdT.Day) : async Result.Result<ProdT.AccrualView, T.BankError> {
    switch (scopedAccount(caller, id)) {
      case (#err(e)) #err(e);
      case (#ok(_)) BankCore.accruedInterest(bank, bankBlocks(), journal, id, dayOr(to));
    }
  };

  /// What an aggregated accrual posting for a product and currency on one day would
  /// be, as the sum of the per-account folds. Exposed so the figure a run posts can
  /// be recomputed by a reader before or after it is posted.
  /// What an account accrued over a window, which is the base a percent-of-interest
  /// charge is taken from.
  public shared query ({ caller }) func accruedInterestOver(id : ProdT.AccountId, from : ProdT.Day, to : ProdT.Day) : async Result.Result<ProdT.AccrualView, T.BankError> {
    switch (scopedAccount(caller, id)) {
      case (#err(e)) #err(e);
      case (#ok(_)) BankCore.accruedBetween(bank, bankBlocks(), journal, id, from, to);
    }
  };

  public query func accrualPreview(product : ProdT.ProductId, currency : JT.Currency, day : ProdT.Day) : async Result.Result<{ amount : Nat; accounts : Nat; examined : Nat }, T.BankError> {
    BankCore.accrualFor(bank, bankBlocks(), journal, product, currency, day)
  };

  public shared query ({ caller }) func loanPosition(id : ProdT.AccountId, asOf : ?ProdT.Day) : async Result.Result<ProdT.LoanPositionView, T.BankError> {
    switch (scopedAccount(caller, id)) {
      case (#err(e)) #err(e);
      case (#ok(_)) BankCore.loanPosition(bank, bankBlocks(), journal, id, dayOr(asOf));
    }
  };

  public shared query ({ caller }) func loanSchedule(id : ProdT.AccountId) : async Result.Result<[ProdT.Instalment], T.BankError> {
    switch (scopedAccount(caller, id)) {
      case (#err(e)) #err(e);
      case (#ok(_)) {
        switch (ProductCore.scheduleRows(bank.product, productBlocks(), id)) {
          case (?rows) #ok(rows);
          case null #err(#ProductError({ error = #LoanNotDisbursed({ account = id }) }));
        }
      };
    }
  };

  /// Every schedule an account has had, oldest first, so a reschedule is
  /// inspectable and the superseded schedule is still there.
  public shared query ({ caller }) func loanScheduleHistory(id : ProdT.AccountId) : async Result.Result<[{ version : Nat; effective : ProdT.Day; rows : [ProdT.Instalment]; recordedAtBlock : Nat }], T.BankError> {
    switch (scopedAccount(caller, id)) {
      case (#err(e)) #err(e);
      case (#ok(_)) #ok(ProductCore.scheduleHistory(bank.product, productBlocks(), id));
    }
  };

  public shared query ({ caller }) func chargeDueDays(id : ProdT.AccountId, charge : Text, from : ProdT.Day, to : ProdT.Day) : async Result.Result<[ProdT.Day], T.BankError> {
    switch (scopedAccount(caller, id)) {
      case (#err(e)) #err(e);
      case (#ok(_)) BankCore.chargeDueDays(bank, bankBlocks(), journal, id, charge, from, to);
    }
  };

  /// A term deposit quote: the rate the term resolves to from the product's chart
  /// and the figure the deposit matures at, with the unrounded interest beside it.
  public query func depositQuote(product : ProdT.ProductId, principal : Nat, termDays : Nat, from : ?ProdT.Day) : async Result.Result<ProdT.DepositQuoteView, T.BankError> {
    BankCore.depositQuote(bank, journal, product, principal, termDays, from)
  };

  public shared query ({ caller }) func listTills(cursor : ?ProdT.TillId, limit : Nat) : async CursorPage<ProdT.TillView, ProdT.TillId> {
    let p = ProductCore.listTillsPaged(bank.product, productBlocks(), cursor, limit);
    scopePage<ProdT.TillView, ProdT.TillId>(
      caller,
      Array.map<ProductCore.TillEntry, ProdT.TillView>(p.rows, func(t) { ProductCore.tillView(t) }),
      p.cursor, p.total, func(t) { ?t.book }
    )
  };

  public shared query ({ caller }) func tillPosition(id : ProdT.TillId, asOf : ?ProdT.Day) : async Result.Result<ProdT.TillPositionView, T.BankError> {
    switch (ProductCore.getTill(bank.product, productBlocks(), id)) {
      case null #err(#ProductError({ error = #UnknownTill({ till = id }) }));
      case (?t) {
        if (not BankCore.mayReadBook(readScope(caller), t.book)) return #err(#OutsideBookScope({ book = t.book }));
        BankCore.tillPosition(bank, bankBlocks(), journal, id, dayOr(asOf))
      };
    }
  };

  func scopedAccount(caller : Principal, id : ProdT.AccountId) : Result.Result<(), T.BankError> {
    switch (ProductCore.get(bank.product, productBlocks(), id)) {
      case null #err(#ProductError({ error = #UnknownAccount({ account = id }) }));
      case (?a) {
        if (BankCore.mayReadBook(readScope(caller), a.book)) #ok(())
        else #err(#OutsideBookScope({ book = a.book }))
      };
    }
  };

  /// The day a read is taken at: the one asked for, or the business date, or zero
  /// when no business date has been rolled yet.
  func dayOr(d : ?ProdT.Day) : ProdT.Day {
    switch (d) {
      case (?x) x;
      case null { switch (JCore.businessDate(journal)) { case (?b) b; case null 0 } };
    }
  };

  // ─── value dating, foreign currency and the close ───

  /// How a value date resolves under a product's convention, and whether this layer
  /// is the only thing that can move it in this deployment.
  public query func resolveValueDate(product : ProdT.ProductId, requested : ProdT.Day) : async Result.Result<CT.ResolvedDateView, T.BankError> {
    BankCore.resolveValueDate(bank, journal, product, requested)
  };

  public query func functionalCurrency() : async ?JT.Currency { CloseCore.functional(bank.close) };
  public query func listFxPairs() : async [CT.PositionPair] { CloseCore.listPairs(bank.close) };
  public query func listFxRates() : async [CT.Rate] { CloseCore.listRates(bank.close) };

  /// The rate recorded for exactly this day, and nothing else: an earlier day's rate
  /// is never substituted, which is why this takes the day rather than searching.
  public query func fxRate(currency : JT.Currency, asOf : ProdT.Day) : async ?CT.Rate {
    CloseCore.rateOn(bank.close, currency, asOf)
  };

  /// A currency's position, what it was booked at, and what a revaluation at the day
  /// asked about would be. With no rate recorded for that day the revaluation fields
  /// are null, which is the refusal surfaced as a read.
  public query func fxPosition(currency : JT.Currency, asOf : ProdT.Day) : async Result.Result<CT.PositionView, T.BankError> {
    BankCore.positionView(bank, journal, currency, asOf)
  };

  public query func listPeriodEndRuns() : async [CT.RunView] { CloseCore.listRunViews(bank.close) };

  public query func periodEndRun(book : T.BookId, period : JT.PeriodId) : async ?CT.RunView {
    switch (CloseCore.getRun(bank.close, book, period)) { case (?r) ?CloseCore.runView(r); case null null }
  };

  public query func listDeferralSchedules() : async [CT.ScheduleView] { CloseCore.listScheduleViews(bank.close) };

  public query func deferralSchedule(id : Text) : async ?CT.ScheduleView {
    switch (CloseCore.getSchedule(bank.close, id)) { case (?e) ?CloseCore.scheduleView(e); case null null }
  };

  /// What a back-value correction would be, without posting it.
  public query func accrualAdjustmentPreview(product : ProdT.ProductId, currency : JT.Currency, from : ProdT.Day, to : ProdT.Day) : async Result.Result<{ recomputed : Nat; booked : Nat; movement : Nat; direction : Text; examined : Nat }, T.BankError> {
    BankCore.accrualAdjustmentPreview(bank, bankBlocks(), journal, product, currency, from, to)
  };

  /// How a back-dated value date would be classified for a book today.
  public query func backValueVerdict(book : T.BookId, valueDate : ProdT.Day) : async { verdict : Text; businessDaysBack : Nat; freeDays : Nat; approvedDays : Nat; approved : Bool } {
    BankCore.backValueVerdict(bank, journal, book, valueDate)
  };

  /// The control-account check the close runs, readable before the close runs it.
  public query func controlCheck() : async { accounts : Nat; divergence : ?CT.ControlCheckView } {
    let r = BankCore.controlCheck(bank, journal, journalBlocks());
    {
      accounts = r.accounts;
      divergence = switch (r.divergence) {
        case null null;
        case (?c) ?{
          account = c.account; currency = c.currency;
          ledgerDebits = c.ledgerDebits; ledgerCredits = c.ledgerCredits;
          subledgerDebits = c.subledgerDebits; subledgerCredits = c.subledgerCredits;
        };
      };
    }
  };

  public query func closeStatus() : async { functional : ?JT.Currency; pairs : Nat; rates : Nat; runs : Nat; schedules : Nat; approvals : Nat; closedBooks : Nat; yearsRolled : Nat } {
    BankCore.closeStatus(bank)
  };

  public query func valueDateConventions() : async [Text] {
    Array.map<CT.Convention, Text>(Conv.conventions(), Conv.conventionText)
  };

  // ─── the end-of-day batch ───

  public query func listEndOfDayRuns() : async [BT.RunView] { BatchCore.listRunViews(bank.batch) };

  public query func endOfDayRun(book : T.BookId, businessDate : ProdT.Day) : async ?BT.RunView {
    switch (BatchCore.getRun(bank.batch, book, businessDate)) { case (?r) ?BatchCore.runView(r); case null null }
  };

  /// The plan a run is working through, re-derived from what its opening block recorded.
  /// It is not stored: a second copy of something already in the log is a thing that can
  /// disagree with it.
  public query func endOfDayPlan(book : T.BookId, businessDate : ProdT.Day) : async Result.Result<{ items : [Batch.PlanItem]; planHash : Blob; entities : Nat; inJobOrder : Bool }, T.BankError> {
    switch (BatchCore.getRun(bank.batch, book, businessDate)) {
      case null #err(#BatchError({ error = #UnknownRun({ book; businessDate }) }));
      case (?run) {
        switch (Batch.plan(BankCore.planInput(bank, bankBlocks(), book, run.maxAccount, run.shardSize))) {
          case (#err(#invalidShardSize(d))) #err(#BatchError({ error = #InvalidShardSize({ shardSize = d.shardSize }) }));
          case (#err(#planTooLarge(d))) #err(#BatchError({ error = #PlanTooLarge({ items = d.items }) }));
          case (#ok(items)) #ok({
            items; planHash = Batch.planHash(items);
            entities = Batch.entityCount(items);
            inJobOrder = Batch.inJobOrder(items);
          });
        }
      };
    }
  };

  public query func listStandingInstructions() : async [BT.InstructionView] {
    BatchCore.listInstructionViews(bank.batch)
  };

  public query func standingInstruction(id : Text) : async ?BT.InstructionView {
    switch (BatchCore.getInstruction(bank.batch, id)) { case (?e) ?BatchCore.instructionView(e); case null null }
  };

  /// The statement data cut for an account, as it was recorded. A statement built from
  /// this stays the same after later back-valued activity is admitted, which is the
  /// whole reason the cut is a record and not a re-derivation.
  public shared query ({ caller }) func statementCut(account : ProdT.AccountId) : async Result.Result<BT.StatementCut, T.BankError> {
    switch (scopedAccount(caller, account)) {
      case (#err(e)) #err(e);
      case (#ok(_)) {
        switch (BatchCore.cutFor(bank.batch, account)) {
          case (?c) #ok(c);
          case null #err(#BatchError({ error = #UnknownRun({ book = ""; businessDate = 0 }) }));
        }
      };
    }
  };

  public query func batchStatus() : async { runs : Nat; instructions : Nat; cuts : Nat; jobs : [Text] } {
    {
      runs = BatchCore.runCount(bank.batch);
      instructions = BatchCore.instructionCount(bank.batch);
      cuts = BatchCore.cutCount(bank.batch);
      jobs = Array.map<Batch.Job, Text>(Batch.jobs(), Batch.jobText);
    }
  };

  // ─── regulatory reporting and general-ledger export ───
  //
  // Every one of these is a query: reporting reads, and the only thing the layer writes is
  // the registration of what a report is computed from and the record that an artefact was
  // certified. A report's identity is (definition hash, parameters, journal height), all
  // three of which come back with it, so two parties who disagree about a figure resolve it
  // by recomputing rather than by comparing files.

  public query func listReportDefinitions() : async [RepT.ReportDef] { ReportCore.listDefs(bank.report) };

  public query func reportDefinition(id : Text, version : Nat) : async ?{ definition : RepT.ReportDef; hash : Blob; registeredAtBlock : Nat } {
    ReportCore.getDef(bank.report, id, version)
  };

  /// Evaluate a registered definition. Deterministic in its identity triple, so calling this
  /// twice at the same journal height returns byte-identical canonical output.
  public query func evaluateReport(id : Text, version : Nat, book : T.BookId, period : JT.PeriodId, view : RepT.CurrencyView, functional : ?JT.Currency) : async Result.Result<RepT.Report, T.BankError> {
    switch (ReportCore.getDef(bank.report, id, version)) {
      case null #err(#ReportError({ error = #UnknownDefinition({ definition = id; version }) }));
      case (?e) {
        let params : RepT.ReportParams = { book; period; view; functional };
        switch (Reports.evaluate(journal, journalBlocks(), e.definition, params, BankCore.reportContext(bank, bankBlocks(), journal, e.definition), BankCore.height(bank))) {
          case (#err(err)) #err(#ReportError({ error = err }));
          case (#ok(r)) #ok(r);
        }
      };
    }
  };

  /// The slice a definition would read, which is what the declared bound is compared against
  /// **before** any evaluation. A caller can ask this first and learn that a report is too
  /// large rather than discovering it by being refused.
  public query func reportSlice(id : Text, version : Nat, book : T.BookId, period : JT.PeriodId) : async Result.Result<{ slice : Nat; bound : Nat; source : Text }, T.BankError> {
    switch (ReportCore.getDef(bank.report, id, version)) {
      case null #err(#ReportError({ error = #UnknownDefinition({ definition = id; version }) }));
      case (?e) {
        let params : RepT.ReportParams = { book; period; view = #native; functional = null };
        switch (Reports.sliceSize(journal, e.definition, params, BankCore.reportContext(bank, bankBlocks(), journal, e.definition))) {
          case (#err(err)) #err(#ReportError({ error = err }));
          case (#ok(n)) {
            let source = switch (Reports.sourceOf(e.definition)) {
              case (#ok(#chart)) "chart";
              case (#ok(#subledger)) "subledger";
              case (#err(_)) "refused";
            };
            #ok({ slice = n; bound = e.definition.maxSlice; source })
          };
        }
      };
    }
  };

  public query func listReturnTemplates() : async [RepT.ReturnTemplate] { ReportCore.listTemplates(bank.report) };

  public query func returnTemplate(id : Text, version : Nat) : async ?{ template : RepT.ReturnTemplate; hash : Blob; registeredAtBlock : Nat } {
    ReportCore.getTemplate(bank.report, id, version)
  };

  public query func evaluateReturn(id : Text, version : Nat, book : T.BookId, period : JT.PeriodId) : async Result.Result<RepT.ReturnResult, T.BankError> {
    switch (ReportCore.getTemplate(bank.report, id, version)) {
      case null #err(#ReportError({ error = #UnknownTemplate({ template = id; version }) }));
      case (?e) {
        switch (Returns.evaluate(journal, e.template, book, period)) {
          case (#err(err)) #err(#ReportError({ error = err }));
          case (#ok(r)) #ok(r);
        }
      };
    }
  };

  public query func statementMap(book : T.BookId) : async ?RepT.StatementMap { ReportCore.statementMap(bank.report, book) };

  public query func incomeStatement(book : T.BookId, period : JT.PeriodId, currency : JT.Currency) : async Result.Result<RepT.IncomeStatement, T.BankError> {
    switch (ReportCore.statementMap(bank.report, book)) {
      case null #err(#ReportError({ error = #NoStatementMap({ book }) }));
      case (?m) {
        switch (Reports.incomeStatement(journal, book, period, currency, m, BankCore.height(bank))) {
          case (#err(e)) #err(#ReportError({ error = e }));
          case (#ok(r)) #ok(r);
        }
      };
    }
  };

  public query func balanceSheet(book : T.BookId, period : JT.PeriodId, currency : JT.Currency) : async Result.Result<RepT.BalanceSheet, T.BankError> {
    switch (Reports.balanceSheet(journal, book, period, currency, BankCore.height(bank))) {
      case (#err(e)) #err(#ReportError({ error = e }));
      case (#ok(r)) #ok(r);
    }
  };

  public query func cashFlow(book : T.BookId, period : JT.PeriodId, currency : JT.Currency) : async Result.Result<RepT.CashFlow, T.BankError> {
    switch (ReportCore.statementMap(bank.report, book)) {
      case null #err(#ReportError({ error = #NoStatementMap({ book }) }));
      case (?m) {
        switch (Reports.cashFlow(journal, book, period, currency, m, null)) {
          case (#err(e)) #err(#ReportError({ error = e }));
          case (#ok(r)) #ok(r);
        }
      };
    }
  };

  /// The IAS 21 presentation translation, which **posts nothing**: the journal is untouched
  /// and the translation difference comes back as its own field rather than absorbed into a
  /// total.
  public query func translatedBalanceSheet(book : T.BookId, period : JT.PeriodId, currency : JT.Currency, closingDay : ProdT.Day, historicDay : ProdT.Day) : async Result.Result<RepT.BalanceSheet, T.BankError> {
    switch (ReportCore.statementMap(bank.report, book)) {
      case null #err(#ReportError({ error = #NoStatementMap({ book }) }));
      case (?m) {
        let ?functional = CloseCore.functional(bank.close) else return #err(#ReportError({ error = #NoFunctionalCurrency }));
        switch (Reports.balanceSheet(journal, book, period, currency, BankCore.height(bank))) {
          case (#err(e)) #err(#ReportError({ error = e }));
          case (#ok(native)) {
            let rateFor = func(c : JT.Currency, d : ProdT.Day) : ?{ numerator : Nat; denominator : Nat } {
              switch (CloseCore.rateOn(bank.close, c, d)) {
                case (?r) ?{ numerator = r.numerator; denominator = r.denominator };
                case null null;
              }
            };
            switch (Reports.translate(native, functional, closingDay, historicDay, m, rateFor)) {
              case (#err(e)) #err(#ReportError({ error = e }));
              case (#ok(r)) #ok(r);
            }
          };
        }
      };
    }
  };

  // ─── statements ───

  public query func listIssuedStatements() : async [RepT.StatementRef] { ReportCore.listStatements(bank.report) };

  public shared query ({ caller }) func issuedStatement(account : ProdT.AccountId, kind : RepT.StatementKind) : async Result.Result<RepT.StatementRef, T.BankError> {
    switch (scopedAccount(caller, account)) {
      case (#err(e)) #err(e);
      case (#ok(_)) {
        switch (ReportCore.getStatement(bank.report, Statements.registerKey(account, kind))) {
          case (?e) #ok(e.statement);
          case null #err(#ReportError({ error = #UnknownStatement({ id = Statements.registerKey(account, kind) }) }));
        }
      };
    }
  };

  /// The camt.053 of a recorded statement cut, with all five balance kinds. `OPBD` and
  /// `CLBD` come from the cut, so they do not move when a posting is later value-dated into
  /// the cut day; `CLAV` is the available figure, which is the booked one less the
  /// reservations the journal is holding.
  public shared query ({ caller }) func statementCamt053(account : ProdT.AccountId, period : JT.PeriodId) : async Result.Result<{ ref : RepT.StatementRef; xml : Text }, T.BankError> {
    switch (scopedAccount(caller, account)) {
      case (#err(e)) #err(e);
      case (#ok(_)) {
        let ?cut = BatchCore.cutFor(bank.batch, account) else return #err(#BatchError({ error = #NoStatementCut({ account }) }));
        switch (BankCore.statementRefFor(bank, bankBlocks(), journal, journalBlocks(), account, #camt053({ cut = cut.day }), period)) {
          case (#err(e)) #err(e);
          case (#ok(ref)) {
            switch (camtStatement(account, period)) {
              case null #err(#ReportError({ error = #UnknownPeriod({ period }) }));
              case (?(st, mu)) {
                #ok({
                  ref;
                  xml = Statements.camt053Xml(st, ref.balances, mu,
                    "THEBES-053-" # Nat.toText(account) # "-" # Nat.toText(cut.day) # "-H" # Nat.toText(BankCore.height(bank)),
                    CivilDate.toText(CivilDate.fromNanos(Nat64.toNat(now()))) # "T00:00:00Z");
                })
              };
            }
          };
        }
      };
    }
  };

  /// The camt.052 intraday report, from the live fold. No cut stands behind it, and it states
  /// no closing booked figure for that reason.
  public shared query ({ caller }) func statementCamt052(account : ProdT.AccountId, period : JT.PeriodId, asOf : ProdT.Day) : async Result.Result<{ ref : RepT.StatementRef; xml : Text }, T.BankError> {
    switch (scopedAccount(caller, account)) {
      case (#err(e)) #err(e);
      case (#ok(_)) {
        switch (BankCore.statementRefFor(bank, bankBlocks(), journal, journalBlocks(), account, #camt052({ asOf }), period)) {
          case (#err(e)) #err(e);
          case (#ok(ref)) {
            switch (camtStatement(account, period)) {
              case null #err(#ReportError({ error = #UnknownPeriod({ period }) }));
              case (?(st, mu)) {
                #ok({
                  ref;
                  xml = Statements.camt052Xml(st, ref.balances, mu,
                    "THEBES-052-" # Nat.toText(account) # "-" # Nat.toText(asOf) # "-H" # Nat.toText(BankCore.height(bank)),
                    CivilDate.toText(CivilDate.fromNanos(Nat64.toNat(now()))) # "T00:00:00Z", asOf);
                })
              };
            }
          };
        }
      };
    }
  };

  /// One camt.054 notification, naming the journal block the movement is — so the
  /// notification and its proof are the same object.
  public shared query ({ caller }) func statementCamt054(account : ProdT.AccountId, period : JT.PeriodId, block : Nat) : async Result.Result<{ ref : RepT.StatementRef; xml : Text }, T.BankError> {
    switch (scopedAccount(caller, account)) {
      case (#err(e)) #err(e);
      case (#ok(_)) {
        switch (BankCore.statementRefFor(bank, bankBlocks(), journal, journalBlocks(), account, #camt054({ movement = block }), period)) {
          case (#err(e)) #err(e);
          case (#ok(ref)) {
            switch (camtStatement(account, period)) {
              case null #err(#ReportError({ error = #UnknownPeriod({ period }) }));
              case (?(st, mu)) {
                var found : ?JCamt.StatementEntry = null;
                for (e in st.entries.vals()) { if (e.paymentId == block) found := ?e };
                switch (found) {
                  case null #err(#ReportError({ error = #UnknownStatement({ id = "block " # Nat.toText(block) # " is not an entry of this account's statement" }) }));
                  case (?entry) {
                    #ok({
                      ref;
                      xml = Statements.camt054Xml(st.account, st.currency, entry, mu,
                        "THEBES-054-" # Nat.toText(block),
                        CivilDate.toText(CivilDate.fromNanos(Nat64.toNat(now()))) # "T00:00:00Z");
                    })
                  };
                }
              };
            }
          };
        }
      };
    }
  };

  /// The journal's own camt projection for a product account, with the currency's minor units.
  func camtStatement(account : ProdT.AccountId, period : JT.PeriodId) : ?(JCamt.Statement, Nat8) {
    let ?entry = ProductCore.get(bank.product, productBlocks(), account) else return null;
    let ?terms = ProductCore.termsOf(bank.product, entry) else return null;
    let ?mu = JCore.currencyMinorUnits(journal, entry.currency) else return null;
    switch (JCamt.statement(journal, journalBlocks(), period, terms.control, ?entry.subledger, entry.currency,
                            func(i) { switch (JLog.get(journalLog, i)) { case (?b) ?b.hash; case null null } })) {
      case null null;
      case (?st) ?(st, mu);
    }
  };

  // ─── general-ledger export, and the proof-bearing trial balance ───

  public query func exportTrialBalance(book : T.BookId, period : JT.PeriodId, shape : RepT.ExportShape) : async Result.Result<RepT.ExportResult, T.BankError> {
    switch (Filings.exportResult(journal, journalBlocks(), shape, book, period)) {
      case (#err(e)) #err(#ReportError({ error = e }));
      case (#ok(r)) #ok(r);
    }
  };

  /// The audit product's normalised trial balance. Every line names the journal blocks it
  /// folds over; the caller adds each block's inclusion proof and the certified root, which
  /// it has and this canister does not, and the result is a trial balance whose completeness
  /// is a computation rather than a management representation.
  public query func exportNormalisedTrialBalance(book : T.BookId, period : JT.PeriodId, currency : JT.Currency) : async Result.Result<{ json : Text; lines : Nat; evidenceGrade : Text; contentHash : Blob; atHeight : Nat }, T.BankError> {
    let ?mu = JCore.currencyMinorUnits(journal, currency) else return #err(#ReportError({ error = #MissingRate({ currency; asOf = 0 }) }));
    switch (Filings.exportResult(journal, journalBlocks(), #normalisedTrialBalance, book, period)) {
      case (#err(e)) #err(#ReportError({ error = e }));
      case (#ok(r)) {
        let out = Filings.normalisedTrialBalanceJson(r, currency, mu);
        #ok({ json = out.json; lines = out.lines; evidenceGrade = r.evidenceGrade; contentHash = r.contentHash; atHeight = r.atHeight })
      };
    }
  };

  public query func exportSafT(book : T.BookId, period : JT.PeriodId, ctx : Filings.SafTContext) : async Result.Result<{ xml : Text; accounts : Nat; transactions : Nat; lines : Nat }, T.BankError> {
    ignore book;
    let ?mu = JCore.currencyMinorUnits(journal, ctx.currency) else return #err(#ReportError({ error = #MissingRate({ currency = ctx.currency; asOf = 0 }) }));
    switch (Filings.safTXml(journal, period, ctx, mu, func(i : Nat) : ?JT.PostingView { JCore.postingView(journal, journalBlocks(), i) })) {
      case (#err(e)) #err(#ReportError({ error = e }));
      case (#ok(r)) #ok(r);
    }
  };

  public query func exportAicpa(book : T.BookId, period : JT.PeriodId, currency : JT.Currency) : async Result.Result<{ trialBalance : Text; generalLedger : Text; trialBalanceRows : Nat; generalLedgerRows : Nat }, T.BankError> {
    let ?mu = JCore.currencyMinorUnits(journal, currency) else return #err(#ReportError({ error = #MissingRate({ currency; asOf = 0 }) }));
    switch (Filings.exportResult(journal, journalBlocks(), #aicpaAds, book, period)) {
      case (#err(e)) #err(#ReportError({ error = e }));
      case (#ok(r)) {
        let tb = Filings.aicpaTrialBalanceCsv(r, mu);
        let gl = Filings.aicpaGeneralLedgerCsv(journal, period, mu, func(i : Nat) : ?JT.PostingView { JCore.postingView(journal, journalBlocks(), i) });
        #ok({ trialBalance = tb.csv; generalLedger = gl.csv; trialBalanceRows = tb.rows; generalLedgerRows = gl.rows })
      };
    }
  };

  // ─── filings ───

  public query func xbrlInstance(template : Text, version : Nat, book : T.BookId, period : JT.PeriodId, ctx : Filings.XbrlContext) : async Result.Result<{ xml : Text; facts : Nat; unbound : Nat }, T.BankError> {
    switch (ReportCore.getTemplate(bank.report, template, version)) {
      case null #err(#ReportError({ error = #UnknownTemplate({ template; version }) }));
      case (?e) {
        switch (Returns.evaluate(journal, e.template, book, period)) {
          case (#err(err)) #err(#ReportError({ error = err }));
          case (#ok(r)) {
            let ?p = JCore.getPeriod(journal, period) else return #err(#ReportError({ error = #UnknownPeriod({ period }) }));
            let ?mu = JCore.currencyMinorUnits(journal, e.template.currency) else return #err(#ReportError({ error = #MissingRate({ currency = e.template.currency; asOf = 0 }) }));
            #ok(Filings.xbrlInstance(r, p.start, p.end, ctx, mu))
          };
        }
      };
    }
  };

  public query func sdmxInstance(template : Text, version : Nat, book : T.BookId, period : JT.PeriodId, ctx : Filings.SdmxContext) : async Result.Result<{ xml : Text; observations : Nat }, T.BankError> {
    switch (ReportCore.getTemplate(bank.report, template, version)) {
      case null #err(#ReportError({ error = #UnknownTemplate({ template; version }) }));
      case (?e) {
        switch (Returns.evaluate(journal, e.template, book, period)) {
          case (#err(err)) #err(#ReportError({ error = err }));
          case (#ok(r)) {
            let ?mu = JCore.currencyMinorUnits(journal, e.template.currency) else return #err(#ReportError({ error = #MissingRate({ currency = e.template.currency; asOf = 0 }) }));
            #ok(Filings.sdmxInstance(r, ctx, mu))
          };
        }
      };
    }
  };

  // ─── the posting indexes ───

  /// What the indexes hold, and what they cost. Every figure here is one the capacity model
  /// predicts, so a measured run reads it rather than guessing from the contract's total memory.
  public query func indexStats() : async PIdx.Stats { PIdx.stats(postingIndex) };

  /// The instruction meter: every journal commit's instructions, the index component's share, the
  /// last one. What the measured runs read for instructions per posting.
  public query func instructionMeter() : async { commits : Nat; instructions : Nat; indexInstructions : Nat; append : Nat; apply : Nat; index : Nat; activity : Nat; last : Nat } {
    { commits = meterCommits; instructions = meterInstructions; indexInstructions = meterIndexInstructions; append = meterAppend; apply = meterApply; index = meterIndex; activity = meterActivity; last = meterLast }
  };

  /// `queryEntries` with its own instruction count: what a page costs, measured in the query.
  public shared query ({ caller }) func queryEntriesMetered(filter : Queries.Filter) : async { page : Result.Result<Queries.Page, T.BankError>; instructions : Nat } {
    var page : ?Result.Result<Queries.Page, T.BankError> = null;
    let n = IC.countInstructions(func() { page := ?runQuery(caller, filter) });
    let ?p = page else Runtime.trap("Bank: a query that produced no page");
    { page = p; instructions = Nat64.toNat(n) }
  };

  /// Stable memory by component, in bytes: what the capacity model predicts, read from the
  /// regions themselves. An arena's pages are the index's 8 KiB nodes; a log's, a store's and the
  /// MMR's are the 64 KiB pages their regions grew by.
  /// Stable memory by component, in bytes of pages held (pages are never returned to the system, so each
  /// figure is its component's high-water mark). `bankLog` is the bank's `StableLog` regions and its MMR;
  /// `bankPackStores` the bank segments of the packs (§18.3), which the `StableLog`'s prefix left for.
  public query func stableMemory() : async { bankArena : Nat; postingArena : Nat; journalArena : Nat; journalLog : Nat; mmr : Nat; packStores : Nat; packLists : Nat; bankLog : Nat; bankPackStores : Nat; bankLogBase : Nat; total : Nat } {
    let bankArena = RI.arenaStats(bank.arena).pages * 8_192;
    let postingArena = RI.arenaStats(postingIndex.arena).pages * 8_192;
    let journalArena = RI.arenaStats(journal.arena).pages * 8_192;
    let log = JLog.regionStats(journalLog).pages * 65_536;
    let mmr = JLog.mmrStats(journalLog).pages * 65_536;
    let ps = Packing.stats(packing);
    let blog = BLog.regionPages(bankLog) * 65_536;
    let bankPacks = ps.bankStorePages * 65_536;
    { bankArena; postingArena; journalArena; journalLog = log; mmr; packStores = ps.storePages * 65_536; packLists = ps.listPages * 65_536; bankLog = blog; bankPackStores = bankPacks; bankLogBase = BLog.base(bankLog);
      total = bankArena + postingArena + journalArena + log + mmr + ps.storePages * 65_536 + ps.listPages * 65_536 + blog + bankPacks }
  };

  /// The declared dimension the counterparty-class index keys on, and every dimension ever
  /// declared, oldest first. A reader needs the history to say which dimension a given class label
  /// came from, because a label written under an earlier dimension keeps its meaning.
  public query func counterpartyClassDimension() : async {
    current : ?IdxT.ClassDimension;
    declared : [IdxT.ClassDimension];
  } {
    { current = IndexCore.classDimension(bank.index); declared = IndexCore.declarations(bank.index) }
  };

  /// The account id a sub-ledger key belongs to, which is the lookup every per-account index key is
  /// built on. Public because a caller holding a statement row can check that the row is about the
  /// account it claims to be about.
  public query func indexedAccountOf(subledger : Blob) : async ?Nat { PIdx.accountOf(postingIndex, subledger) };

  /// One posting's index header: the effective dates, the primary currency, the leg count, the
  /// status and the period. This is what a query page reads per row instead of decoding a block.
  public query func postingIndexHeader(postingNo : Nat) : async ?PIdx.Header {
    PIdx.header(postingIndex, postingNo)
  };

  /// **The bounded, paged read over the indexes.** One surface, proposal §4: the engine picks the
  /// narrowest index the filter allows, sizes the walk first and refuses a filter wider than the
  /// bound naming its size, and pages with a cursor handed straight back.
  ///
  /// Scope. A query naming an account is a read of that account's book, and is refused outside the
  /// caller's read scope. A query **not** naming an account walks rows that are about postings rather
  /// than about one account, so there is no book to check it against: it requires an unrestricted read
  /// scope. That is a real restriction and it is stated rather than discovered — the alternative, a
  /// per-row book lookup, would make the page's cost depend on the chart rather than on the page.
  public shared query ({ caller }) func queryEntries(filter : Queries.Filter) : async Result.Result<Queries.Page, T.BankError> {
    runQuery(caller, filter)
  };

  func runQuery(caller : Principal, filter : Queries.Filter) : Result.Result<Queries.Page, T.BankError> {
    let sc = readScope(caller);
    switch (filter.account) {
      case (?a) {
        let ?entry = ProductCore.get(bank.product, productBlocks(), a) else return #err(#ProductError({ error = #UnknownAccount({ account = a }) }));
        if (not BankCore.mayReadOptBook(sc, ?entry.book)) return #err(#OutsideBookScope({ book = entry.book }));
      };
      case null {
        switch (sc) {
          case (?books) {
            return #err(#OutsideBookScope({
              book = if (books.size() == 0) "" else books[0];
            }));
          };
          case null {};
        };
      };
    };
    let ctx : Queries.Context = {
      recordOf = func(i : Nat) : ?JT.PostingRecord {
        switch (JLog.get(journalLog, i)) {
          case (?b) {
            switch (b.event) {
              case (#posted(r)) ?r;
              case (#pending(x)) ?x.record;
              case (_) null;
            }
          };
          case null null;
        }
      };
      height = JLog.length(journalLog);
      accountExists = func(a : Nat) : Bool {
        ProductCore.exists(bank.product, a)
      };
      // The same classifier the index was written with, so a saturated row's amount band is decided
      // over the same legs the row was summed from.
      classOf = indexContext().classOf;
    };
    // a range that reaches packed days has no per-posting rows to walk: refused with the boundary,
    // and an account's packed rows are `packedAccountEntries`
    let packedThrough = bank.packing.packedThroughDay;
    if (packedThrough > 0) {
      let from = switch (filter.from) { case (?d) d; case null 0 };
      if (from <= packedThrough) {
        return #err(#QueryError({ error = #PackedRange({ from; to = switch (filter.to) { case (?d) d; case null 0 }; packedThroughDay = packedThrough }) }));
      };
    };
    switch (Queries.run(postingIndex, filter, ctx)) {
      case (#ok(p)) #ok(p);
      case (#err(e)) #err(#QueryError({ error = e }));
    }
  };

  // ─── closed-month packing: what the packs hold ───

  /// An account's packed postings over `[from, to]`, ascending — the statement rows for packed
  /// days, exactly the fields the pack keeps per posting: the number, the value and posting days,
  /// and the account's own debits and credits. Sized from the summary rows before any list is
  /// read; refused past the bound naming the size. Days after the boundary are answered by
  /// `queryEntries`.
  public shared query ({ caller }) func packedAccountEntries(account : Nat, from : Nat, to : Nat, bound : Nat) : async Result.Result<{ entries : [Pack.AccountEntry]; size : Nat; packedThroughDay : Nat }, T.BankError> {
    switch (scopedAccount(caller, account)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    if (to < from) return #err(#QueryError({ error = #InvalidRange({ reason = "to before from" }) }));
    let n = Nat.min(Nat.max(bound, 1), Queries.MAX_SCAN);
    let r = Packing.packedEntries(packing, account, from, to, n);
    if (r.exceeded) return #err(#QueryError({ error = #TooWide({ size = r.size; bound = n; narrow = "fewer days, or a larger bound up to " # Nat.toText(Queries.MAX_SCAN) }) }));
    #ok({ entries = r.entries; size = r.size; packedThroughDay = bank.packing.packedThroughDay })
  };

  /// An account's summary row and list for one pack.
  public shared query ({ caller }) func packedAccount(account : Nat, pack : Nat) : async Result.Result<?Packing.PackedAccount, T.BankError> {
    switch (scopedAccount(caller, account)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    #ok(Packing.packedAccount(packing, account, pack))
  };

  public query func packingStatus() : async {
    current : ?Packing.Current;
    packedThroughBlock : Nat; packedThroughDay : Nat; packs : Nat; valueDayFloor : Nat; requiredAgeDays : Nat;
  } {
    {
      current = Packing.current(packing);
      packedThroughBlock = bank.packing.packedThroughBlock; packedThroughDay = bank.packing.packedThroughDay; packs = bank.packing.packs;
      valueDayFloor = BankCore.valueDayFloor(bank);
      requiredAgeDays = Nat.max(MonitoringCore.longestWindow(bank.monitoring), Packing.DEDUP_WINDOW_DAYS) + 1;
    }
  };
  public query func listPacks() : async [Packing.PackView] { Packing.listPacks(packing) };
  public query func getPack(pack : Nat) : async ?Packing.PackView { Packing.getPack(packing, pack) };
  public query func packSegments(pack : Nat) : async [Packing.Segment] { Packing.segmentsOf(packing, pack) };
  /// A segment's bytes — what an archive is given, and what `Pack.unpack` turns back into the
  /// journal's blocks, byte for byte.
  public query func packSegmentBytes(pack : Nat, seq : Nat) : async ?Blob { Packing.segmentBytes(packing, pack, seq) };
  public query func packingStats() : async Packing.Stats { Packing.stats(packing) };
  /// The bank segments of a pack (§18.3), and one segment's bytes.
  public query func bankPackSegments(pack : Nat) : async [Packing.BankSegment] { Packing.bankSegmentsOf(packing, pack) };
  public query func bankPackSegmentBytes(pack : Nat, seq : Nat) : async ?Blob { Packing.bankSegmentBytes(packing, pack, seq) };
  /// Every block of a bank segment read back from the pack, decoded, its hash checked against the MMR
  /// leaf the chain committed (the proof of the packed block), and its index its own.
  /// Every block of `lo … hi` read back — from the pack below the log's base, from the StableLog above it —
  /// decoded, its index its own, its parent hash its predecessor's, and its hash proved against the bank's
  /// MMR root; the dropped bodies counted. The one check behind the packed-segment and the live-range reads.
  func verifyBankRange(lo : Nat, hi : Nat, root : Blob) : { verified : Nat; dropped : Nat; fault : ?Nat } {
    var verified = 0; var dropped = 0; var fault : ?Nat = null;
    var prev : ?Blob = if (lo == 0) null else switch (bankBlock(lo - 1)) { case (?p) ?p.hash; case null { return { verified = 0; dropped = 0; fault = ?lo } } };
    var i = lo;
    label walk while (i <= hi) {
      switch (bankRaw(i), BLog.proof(bankLog, i)) {
        case (?raw, ?pf) {
          switch (C.decodeBlock(raw)) {
            case (?b) {
              if (b.index == i and b.parentHash == prev and BLog.verify(b.hash, i, pf, root)) verified += 1 else { fault := ?i; break walk };
              switch (b.event) { case (#commandProposed(x)) { if (x.command == null) dropped += 1 }; case (_) {} };
              prev := ?b.hash;
            };
            case null { fault := ?i; break walk };
          };
        };
        case (_) { fault := ?i; break walk };
      };
      i += 1;
    };
    { verified; dropped; fault }
  };

  public query func verifyBankPackSegment(pack : Nat, seq : Nat) : async ?{ blocks : Nat; verified : Nat; bodiesDropped : Nat; hashOk : Bool; firstFault : ?Nat } {
    let ?sg = Array.find<Packing.BankSegment>(Packing.bankSegmentsOf(packing, pack), func(g) { g.seq == seq }) else return null;
    let ?bytes = Packing.bankSegmentBytes(packing, pack, seq) else return null;
    let hashOk = Sha256.fromBlob(#sha256, bytes) == sg.sha256;
    let ?root = BLog.mmrRoot(bankLog) else return ?{ blocks = 0; verified = 0; bodiesDropped = 0; hashOk; firstFault = ?sg.lo };
    let r = verifyBankRange(sg.lo, sg.hi, root);
    ?{ blocks = sg.hi + 1 - sg.lo; verified = r.verified; bodiesDropped = r.dropped; hashOk; firstFault = r.fault }
  };

  /// A range of the bank log proved against the certified root — packed or live, up to 2,000 blocks a read —
  /// so a log of millions of blocks is verified in pages by a reader that never decodes a block itself.
  public query func verifyBankBlocks(start : Nat, length : Nat) : async { blocks : Nat; verified : Nat; bodiesDropped : Nat; firstFault : ?Nat } {
    let height = BLog.length(bankLog);
    if (start >= height or length == 0) return { blocks = 0; verified = 0; bodiesDropped = 0; firstFault = null };
    let hi = Nat.min(height - 1, start + Nat.min(length, 2_000) - 1);
    let ?root = BLog.mmrRoot(bankLog) else return { blocks = 0; verified = 0; bodiesDropped = 0; firstFault = ?start };
    let r = verifyBankRange(start, hi, root);
    { blocks = hi + 1 - start; verified = r.verified; bodiesDropped = r.dropped; firstFault = r.fault }
  };

  public query func archiveRollStatus() : async {
    current : ?{ pack : Nat; cid : Nat64; archive : Principal; hi : Nat; phase : Text; foldNext : Nat; checkpointParts : Nat; sent : Nat; acked : Nat; segments : Nat };
    archivedThroughBlock : Nat; archivedPacks : Nat; journalBase : Nat; journalHeight : Nat;
    checkpoint : ?{ through : Nat; first : Nat; last : ?Nat };
    shadow : { pages : Nat; free : Nat }; logRegions : { regions : Nat; free : Nat; pages : Nat };
  } {
    let st = ArchiveRoll.stats(roll);
    {
      current = ArchiveRoll.current(roll);
      archivedThroughBlock = bank.packing.archivedThroughBlock; archivedPacks = bank.packing.archivedPacks;
      journalBase = JLog.base(journalLog); journalHeight = JLog.length(journalLog);
      checkpoint = JCore.checkpointPosition(journal);
      shadow = st.shadow; logRegions = JLog.regionStats(journalLog);
    }
  };

  /// Where a journal block is: here, in an archive (the pack and segment that hold it), or not yet.
  public query func journalBlockLocation(index : Nat) : async { #live; #archived : { pack : Nat; cid : Nat64; archive : Principal; seq : ?Nat }; #none } {
    if (index >= JLog.length(journalLog)) return #none;
    if (index >= JLog.base(journalLog)) return #live;
    for ((pack, a) in Map.entries(bank.packing.archives)) {
      if (index <= a.hi) {
        var seq : ?Nat = null;
        for (sg in Packing.segmentsOf(packing, pack).vals()) { if (sg.lo <= index and index <= sg.hi) seq := ?sg.seq };
        return #archived({ pack; cid = a.cid; archive = a.archive; seq });
      };
    };
    #none
  };

  /// Where a period's blocks are.
  public query func periodLocation(period : JT.PeriodId) : async { #live; #archived : { pack : Nat; cid : Nat64; archive : Principal }; #unknown } {
    switch (JCore.getPeriod(journal, period)) {
      case null #unknown;
      case (?_) { switch (BankCore.periodArchived(bank, journal, period)) { case (?a) #archived(a); case null #live } };
    }
  };

  /// The lossless round trip, on the deployed contract: a segment's bytes hashed and unpacked, and
  /// every block compared with the log's own bytes. `firstDifference` names the first block that
  /// differs, if any; `reason` is the codec's, when the bytes do not unpack at all.
  public query func verifyPackSegment(pack : Nat, seq : Nat) : async ?{ blocks : Nat; equal : Bool; hashOk : Bool; firstDifference : ?Nat; reason : ?Text } {
    let ?sg = Packing.segment(packing, pack, seq) else return null;
    let ?bytes = Packing.segmentBytes(packing, pack, seq) else return null;
    let hashOk = Sha256.fromBlob(#sha256, bytes) == sg.sha256;
    switch (Pack.unpack(bytes)) {
      case (#err(reason)) ?{ blocks = 0; equal = false; hashOk; firstDifference = null; reason = ?reason };
      case (#ok(back)) {
        if (back.size() != sg.hi + 1 - sg.lo) return ?{ blocks = back.size(); equal = false; hashOk; firstDifference = ?sg.lo; reason = ?"block count differs" };
        var i = 0;
        while (i < back.size()) {
          switch (JLog.rawBlock(journalLog, sg.lo + i)) {
            case (?raw) { if (raw != back[i].raw) return ?{ blocks = back.size(); equal = false; hashOk; firstDifference = ?(sg.lo + i); reason = null } };
            case null return ?{ blocks = back.size(); equal = false; hashOk; firstDifference = ?(sg.lo + i); reason = ?"the log has no such block" };
          };
          i += 1;
        };
        ?{ blocks = back.size(); equal = true; hashOk; firstDifference = null; reason = null }
      };
    }
  };

  /// The bounds `queryEntries` enforces, so a caller can size a request rather than discover the
  /// refusal.
  public query func queryBounds() : async { maxLimit : Nat; maxScan : Nat } {
    { maxLimit = Queries.MAX_LIMIT; maxScan = Queries.MAX_SCAN }
  };

  /// What the contract is using, from the runtime itself.
  ///
  /// `heapBytes` is the figure that matters most: the heap is resident memory, which is why "the heap
  /// does not grow with the number of postings" matters more than it looks. `indexBytes` is the stable memory the indexes occupy, which is what
  /// the capacity model predicts — so a measured run reads both
  /// here rather than inferring them from the outside.
  public query func runtimeMemory() : async {
    heapBytes : Nat;
    totalAllocatedBytes : Nat;
    maxLiveBytes : Nat;
    indexBytes : Nat;
  } {
    {
      heapBytes = Prim.rts_heap_size();
      totalAllocatedBytes = Prim.rts_total_allocation();
      maxLiveBytes = Prim.rts_max_live_size();
      // Deliberately not the whole contract's stable-memory size: the only way to read that is the
      // deprecated `ExperimentalStableMemory` page count, and every Region this contract owns reports
      // its own size already. `indexBytes` is the figure the capacity model predicts.
      indexBytes = PIdx.stats(postingIndex).bytes + Activity.stats(activity).bytes + Packing.stats(packing).storeBytes;
    }
  };

  // ─── monitoring: the aggregates and the closed rule set ───
  //
  // The rules are declared data (`defineMonitoringRule`, `retireMonitoringRule`, dual); the
  // aggregates are maintained in the posting's own message; an evaluation is a bounded read. The
  // alert component records what an evaluation finds; here the findings are readable on demand, so
  // the engine is reachable and testable from outside before an alert exists.

  public query func listMonitoringRules() : async [MT.Rule] { MonitoringCore.list(bank.monitoring) };
  public query func getMonitoringRule(id : MT.RuleId) : async ?MT.Rule { MonitoringCore.get(bank.monitoring, id) };
  public query func monitoringRuleVersion(id : MT.RuleId, version : Nat) : async ?MT.Rule { MonitoringCore.version(bank.monitoring, id, version) };
  public query func monitoringRuleCost(spec : MT.RuleSpec) : async Text { Monitoring.costBound(spec) };

  public query func accountActivity(account : Nat, from : Nat, to : Nat) : async Result.Result<[(Nat, Activity.DayActivity)], T.BankError> {
    if (to < from or to + 1 - from > MT.MAX_WINDOW_DAYS) return #err(#QueryError({ error = #InvalidRange({ reason = "a window of at most " # Nat.toText(MT.MAX_WINDOW_DAYS) # " days" }) }));
    #ok(Activity.activityOver(activity, account, from, to))
  };

  public query func accountDormancy(account : Nat) : async ?Activity.Dormancy { Activity.dormancy(activity, account) };

  public query func accountEdges(account : Nat, from : Nat, to : Nat, outward : Bool, limit : Nat) : async Result.Result<{ rows : [Activity.Neighbour]; more : Bool }, T.BankError> {
    if (to < from or to + 1 - from > MT.MAX_WINDOW_DAYS) return #err(#QueryError({ error = #InvalidRange({ reason = "a window of at most " # Nat.toText(MT.MAX_WINDOW_DAYS) # " days" }) }));
    let n = Nat.min(Nat.max(limit, 1), MT.MAX_SCAN);
    #ok(if (outward) Activity.edgesOut(activity, #account(account), from, to, n) else Activity.edgesIn(activity, #account(account), from, to, n))
  };

  public query func edgesBetweenAccounts(from : Nat, to : Nat, fromDay : Nat, toDay : Nat, limit : Nat) : async Result.Result<{ rows : [Activity.EdgeRow]; more : Bool }, T.BankError> {
    if (toDay < fromDay or toDay + 1 - fromDay > MT.MAX_WINDOW_DAYS) return #err(#QueryError({ error = #InvalidRange({ reason = "a window of at most " # Nat.toText(MT.MAX_WINDOW_DAYS) # " days" }) }));
    #ok(Activity.edgesBetween(activity, #account(from), #account(to), fromDay, toDay, Nat.min(Nat.max(limit, 1), MT.MAX_SCAN)))
  };

  /// The window rules for one account on one day, evaluated now. What the end-of-day batch will
  /// record as alerts; readable here so the evaluation is a fact anyone can check.
  public query func evaluateAccountRules(account : Nat, day : Nat) : async Result.Result<[MT.Finding], T.BankError> {
    switch (Monitoring.atDay(monitoringContext(), MonitoringCore.active(bank.monitoring, #endOfDay), account, day)) {
      case (#err(e)) #err(#MonitoringError({ error = e }));
      case (#ok(fs)) #ok(fs);
    }
  };

  /// The cheap rules against a posting, re-derived from its block: the same reading the posting's
  /// own message made, because the latest activity before a day is a range over A1 that the
  /// posting itself does not change.
  public query func evaluatePostingRules(postingNo : Nat) : async Result.Result<[MT.Finding], T.BankError> {
    switch (BankCore.blockArchived(bank, postingNo)) { case (?e) return #err(e); case null {} };
    let ?b = JLog.get(journalLog, postingNo) else return #err(#JournalError({ error = #UnknownPosting({ index = postingNo }) }));
    let (rec, day) = switch (b.event) {
      case (#posted(r)) (r, r.valueDate);
      case (#pending(p)) { switch (PIdx.header(postingIndex, postingNo)) { case (?h) (p.record, h.valueDay); case null return #ok([]) } };
      case (_) return #ok([]);
    };
    let posted = Activity.derive(rec, postingNo, day, func(sub : JT.SubledgerKey) : ?Nat { PIdx.accountOf(postingIndex, sub) });
    let before = Array.map<Activity.AccountActivity, (Nat, ?Nat)>(posted.accounts, func(a) { (a.account, Activity.latestBefore(activity, a.account, day)) });
    #ok(Monitoring.atPosting(monitoringContext(), MonitoringCore.active(bank.monitoring, #atPosting), { posted = ?posted; before }))
  };

  public query func activityStats() : async Activity.Stats { Activity.stats(activity) };

  // ─── alerts: what monitoring found, under review ───

  func alertBlocks() : AlertCore.Blocks { BankCore.alertBlocks(bankBlocks()) };

  public shared query ({ caller }) func getAlert(alert : Nat) : async Result.Result<AlT.Alert, T.BankError> {
    let ?a = AlertCore.get(bank.alerts, alertBlocks(), alert) else return #err(#AlertError({ error = #UnknownAlert({ alert }) }));
    switch (scopedAccount(caller, a.finding.account)) { case (#err(e)) #err(e); case (#ok(_)) #ok(a) };
  };

  public shared query ({ caller }) func listAlerts(cursor : ?Nat, limit : Nat) : async CursorPage<AlT.Alert, Nat> {
    let p = AlertCore.listPaged(bank.alerts, alertBlocks(), cursor, limit);
    scopePage<AlT.Alert, Nat>(caller, p.rows, p.cursor, p.total, func(a) { ProductCore.bookOf(bank.product, a.finding.account) })
  };

  public shared query ({ caller }) func listOpenAlerts(cursor : ?Nat, limit : Nat) : async CursorPage<AlT.Alert, Nat> {
    let p = AlertCore.listOpenPaged(bank.alerts, alertBlocks(), cursor, limit);
    scopePage<AlT.Alert, Nat>(caller, p.rows, p.cursor, p.total, func(a) { ProductCore.bookOf(bank.product, a.finding.account) })
  };

  public shared query ({ caller }) func alertsOfAccount(account : Nat, limit : Nat) : async Result.Result<[AlT.Alert], T.BankError> {
    switch (scopedAccount(caller, account)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    #ok(AlertCore.alertsOfAccount(bank.alerts, alertBlocks(), account, limit))
  };

  public query func alertStatus() : async { opened : Nat; cleared : Nat; escalated : Nat; open : Nat } { AlertCore.counts(bank.alerts) };

  // ─── collections and recovery (collections and recovery) ──────────────────────────────────────

  /// One exposure's stage and record, within the caller's book scope.
  public shared query ({ caller }) func exposure(account : Nat) : async Result.Result<?ColT.ExposureView, T.BankError> {
    switch (scopedAccount(caller, account)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    #ok(CollectionsCore.view(bank.collections, account))
  };

  /// The exposures in a stage, paged, filtered to the caller's books.
  public shared query ({ caller }) func exposuresByStage(stage : ColT.Stage, cursor : ?Blob, limit : Nat) : async { entries : [ColT.ExposureView]; cursor : ?Blob } {
    let page = CollectionsCore.listByStage(bank.collections, stage, cursor, limit);
    let scope = readScope(caller);
    { entries = Array.filter<ColT.ExposureView>(page.entries, func(v) { BankCore.mayReadOptBook(scope, ProductCore.bookOf(bank.product, v.account)) }); cursor = page.cursor }
  };

  /// A collector's worklist: their exposures not yet closed, paged, filtered to the caller's books.
  public shared query ({ caller }) func collectorWorklist(staff : Principal, cursor : ?Blob, limit : Nat) : async { entries : [ColT.ExposureView]; cursor : ?Blob } {
    let page = CollectionsCore.worklist(bank.collections, staff, cursor, limit);
    let scope = readScope(caller);
    { entries = Array.filter<ColT.ExposureView>(page.entries, func(v) { BankCore.mayReadOptBook(scope, ProductCore.bookOf(bank.product, v.account)) }); cursor = page.cursor }
  };

  // ─── origination (origination and underwriting): the applications ───

  /// One application, within the caller's books.
  public shared query ({ caller }) func application(id : Nat) : async Result.Result<?OT.ApplicationView, T.BankError> {
    switch (OriginationCore.view(bank.origination, id)) {
      case null #ok(null);
      case (?v) { if (BankCore.mayReadBook(readScope(caller), v.book)) #ok(?v) else #err(#OutsideBookScope({ book = v.book })) };
    }
  };

  /// The applications in a stage, paged, filtered to the caller's books.
  public shared query ({ caller }) func applicationsByStage(stage : OT.Stage, cursor : ?Blob, limit : Nat) : async { entries : [OT.ApplicationView]; cursor : ?Blob } {
    let page = OriginationCore.listByStage(bank.origination, stage, cursor, limit);
    let scope = readScope(caller);
    { entries = Array.filter<OT.ApplicationView>(page.entries, func(v) { BankCore.mayReadBook(scope, v.book) }); cursor = page.cursor }
  };

  /// A party's applications, paged, filtered to the caller's books.
  public shared query ({ caller }) func applicationsOfParty(party : Nat, cursor : ?Blob, limit : Nat) : async { entries : [OT.ApplicationView]; cursor : ?Blob } {
    let page = OriginationCore.listByParty(bank.origination, party, cursor, limit);
    let scope = readScope(caller);
    { entries = Array.filter<OT.ApplicationView>(page.entries, func(v) { BankCore.mayReadBook(scope, v.book) }); cursor = page.cursor }
  };

  /// The application a loan account was drawn from, if it was.
  public shared query ({ caller }) func applicationOfAccount(account : Nat) : async Result.Result<?Nat, T.BankError> {
    switch (scopedAccount(caller, account)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    #ok(OriginationCore.applicationOfAccount(bank.origination, account))
  };

  /// Which of an approval's conditions are met, by the names the approval block carries.
  public shared query ({ caller }) func applicationConditions(id : Nat, names : [Text]) : async Result.Result<[(Text, Bool)], T.BankError> {
    switch (OriginationCore.view(bank.origination, id)) {
      case null #err(#OriginationError({ error = #UnknownApplication({ application = id }) }));
      case (?v) { if (BankCore.mayReadBook(readScope(caller), v.book)) #ok(OriginationCore.conditionsOf(bank.origination, id, names)) else #err(#OutsideBookScope({ book = v.book })) };
    }
  };

  /// Whether a party has a passkey registered under a credential id (the key itself is never served).
  public shared query ({ caller }) func hasPasskey(party : Nat, credentialId : Blob) : async Result.Result<Bool, T.BankError> {
    switch (PartyCore.bookOf(bank.party, party)) {
      case null #err(#PartyError({ error = #UnknownParty({ party }) }));
      case (?book) { if (BankCore.mayReadBook(readScope(caller), book)) #ok(OriginationCore.passkey(bank.origination, party, credentialId) != null) else #err(#OutsideBookScope({ book })) };
    }
  };

  /// The origination pipeline at a glance: the models in force, the counts, the applications per stage.
  public query func originationStatus() : async { policy : ?OT.Policy; affordability : ?{ id : Text; version : Nat }; scorecard : ?{ id : Text; version : Nat }; counts : { applications : Nat; fulfilled : Nat; declined : Nat; withdrawn : Nat; expired : Nat; passkeys : Nat }; stages : [(Text, Nat)] } {
    {
      policy = OriginationCore.policy(bank.origination);
      affordability = switch (OriginationCore.affordabilityModel(bank.origination)) { case (?m) ?{ id = m.id; version = m.version }; case null null };
      scorecard = switch (OriginationCore.scorecard(bank.origination)) { case (?c) ?{ id = c.id; version = c.version }; case null null };
      counts = OriginationCore.counts(bank.origination);
      stages = OriginationCore.stageDistribution(bank.origination);
    }
  };

  // ─── corporate lending (corporate lending): the facilities ───

  func facilityView(id : Nat) : ?FaT.FacilityView {
    let covenants = switch (bankBlocks().get(id)) { case (?b) { switch (b.event) { case (#facility(#facilityOpened(x))) x.terms.covenants; case (_) [] } }; case null [] };
    FacilityCore.view(bank.facility, id, covenants)
  };

  /// One facility, within the caller's books; its drawn and available figures read from the journal.
  public shared query ({ caller }) func facility(id : Nat) : async Result.Result<?FaT.FacilityView, T.BankError> {
    switch (facilityView(id)) {
      case null #ok(null);
      case (?v) { if (BankCore.mayReadBook(readScope(caller), v.book)) #ok(?v) else #err(#OutsideBookScope({ book = v.book })) };
    }
  };

  /// What a facility has drawn and has available, read from the journal on a day.
  public shared query ({ caller }) func facilityPosition(id : Nat, asOf : ?Nat) : async Result.Result<{ limit : Nat; drawn : Nat; available : Nat; stage : FaT.Stage }, T.BankError> {
    switch (facilityView(id)) {
      case null #err(#FacilityError({ error = #UnknownFacility({ facility = id }) }));
      case (?v) {
        if (not BankCore.mayReadBook(readScope(caller), v.book)) return #err(#OutsideBookScope({ book = v.book }));
        let drawn = BankCore.facilityDrawnOn(bank, bankBlocks(), journal, id, dayOr(asOf));
        #ok({ limit = v.limit; drawn; available = if (v.stage == #open and v.limit > drawn) v.limit - drawn else 0; stage = v.stage })
      };
    }
  };

  /// A party's facilities, paged, filtered to the caller's books.
  public shared query ({ caller }) func facilitiesOfParty(party : Nat, cursor : ?Blob, limit : Nat) : async { entries : [FaT.FacilityView]; cursor : ?Blob } {
    let page = FacilityCore.listByParty(bank.facility, party, cursor, limit);
    let scope = readScope(caller);
    let out = List.empty<FaT.FacilityView>();
    for (id in page.ids.vals()) { switch (facilityView(id)) { case (?v) { if (BankCore.mayReadBook(scope, v.book)) List.add(out, v) }; case null {} } };
    { entries = List.toArray(out); cursor = page.cursor }
  };

  /// The facilities in a stage, paged, filtered to the caller's books.
  public shared query ({ caller }) func facilitiesByStage(stage : FaT.Stage, cursor : ?Blob, limit : Nat) : async { entries : [FaT.FacilityView]; cursor : ?Blob } {
    let page = FacilityCore.listByStage(bank.facility, stage, cursor, limit);
    let scope = readScope(caller);
    let out = List.empty<FaT.FacilityView>();
    for (id in page.ids.vals()) { switch (facilityView(id)) { case (?v) { if (BankCore.mayReadBook(scope, v.book)) List.add(out, v) }; case null {} } };
    { entries = List.toArray(out); cursor = page.cursor }
  };

  /// A facility's drawings: the loan accounts and whether each still stands.
  public shared query ({ caller }) func facilityDrawings(id : Nat) : async Result.Result<[{ account : Nat; open : Bool }], T.BankError> {
    switch (facilityView(id)) {
      case null #err(#FacilityError({ error = #UnknownFacility({ facility = id }) }));
      case (?v) {
        if (not BankCore.mayReadBook(readScope(caller), v.book)) return #err(#OutsideBookScope({ book = v.book }));
        #ok(Array.map<(Nat, Bool), { account : Nat; open : Bool }>(FacilityCore.drawingsOf(bank.facility, id), func((account, open)) { { account; open } }))
      };
    }
  };

  /// The receivables of a factoring facility with their status and figures.
  public shared query ({ caller }) func facilityReceivables(id : Nat) : async Result.Result<[FacilityCore.ReceivableRow], T.BankError> {
    switch (facilityView(id)) {
      case null #err(#FacilityError({ error = #UnknownFacility({ facility = id }) }));
      case (?v) { if (not BankCore.mayReadBook(readScope(caller), v.book)) return #err(#OutsideBookScope({ book = v.book })); #ok(FacilityCore.receivablesOf(bank.facility, id)) };
    }
  };

  /// A facility's covenants with the status of each.
  public shared query ({ caller }) func facilityCovenants(id : Nat) : async Result.Result<[{ id : Text; status : { #untested; #met; #breached } }], T.BankError> {
    switch (facilityView(id)) {
      case null #err(#FacilityError({ error = #UnknownFacility({ facility = id }) }));
      case (?v) {
        if (not BankCore.mayReadBook(readScope(caller), v.book)) return #err(#OutsideBookScope({ book = v.book }));
        #ok(Array.map<FaT.Covenant, { id : Text; status : { #untested; #met; #breached } }>(v.covenants, func(c) { { id = c.id; status = FacilityCore.covenantStatus(bank.facility, id, c.id) } }))
      };
    }
  };

  /// The fixing of a rate index in force on a day.
  public query func rateFixing(index : Text, day : Nat) : async ?Nat { FacilityCore.fixingOn(bank.facility, index, day) };

  /// The facilities at a glance: the counts and the facilities per kind.
  public query func facilityStatus() : async { counts : { facilities : Nat; closed : Nat; drawn : Nat; accruals : Nat; fixings : Nat }; kinds : [(Text, Nat)] } {
    { counts = FacilityCore.counts(bank.facility); kinds = FacilityCore.kindDistribution(bank.facility) }
  };

  // ─── branch and teller (branch and teller) ───

  func scopedTill(caller : Principal, till : Text) : Result.Result<(), T.BankError> {
    switch (ProductCore.tillBookOf(bank.product, till)) {
      case null #err(#ProductError({ error = #UnknownTill({ till }) }));
      case (?book) { if (BankCore.mayReadBook(readScope(caller), book)) #ok(()) else #err(#OutsideBookScope({ book })) };
    }
  };

  /// The till's open session, or its last one.
  public shared query ({ caller }) func tellerSession(till : Text) : async Result.Result<?TeT.SessionView, T.BankError> {
    switch (scopedTill(caller, till)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (TellerCore.openSessionOf(bank.teller, till)) { case (?id) #ok(TellerCore.sessionView(bank.teller, id)); case null #ok(TellerCore.lastSessionOf(bank.teller, till)) }
  };

  public shared query ({ caller }) func tellerSessionById(id : Nat) : async Result.Result<?TeT.SessionView, T.BankError> {
    switch (TellerCore.sessionView(bank.teller, id)) {
      case null #ok(null);
      case (?v) { switch (scopedTill(caller, v.till)) { case (#err(e)) #err(e); case (#ok(_)) #ok(?v) } };
    }
  };

  /// A till's denomination position, as (face, count).
  public shared query ({ caller }) func tillDenominations(till : Text) : async Result.Result<[(Nat, Nat)], T.BankError> {
    switch (scopedTill(caller, till)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    #ok(TellerCore.tillDenominations(bank.teller, till))
  };

  /// A vault's denomination position in a currency, within the caller's books.
  public shared query ({ caller }) func vaultDenominations(book : Text, currency : Text) : async Result.Result<[(Nat, Nat)], T.BankError> {
    if (not BankCore.mayReadBook(readScope(caller), book)) return #err(#OutsideBookScope({ book }));
    #ok(TellerCore.vaultDenominations(bank.teller, book, currency))
  };

  /// Every cash movement dispatched and not yet received.
  public query func cashInTransit() : async [TeT.MovementView] { TellerCore.inTransit(bank.teller) };

  public shared query ({ caller }) func chequeStatus(account : Nat, serial : Nat) : async Result.Result<?TeT.ChequeView, T.BankError> {
    switch (scopedAccount(caller, account)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    #ok(TellerCore.chequeView(bank.teller, account, serial))
  };

  public query func draftStatus(serial : Text) : async ?TeT.DraftView { TellerCore.draftView(bank.teller, serial) };

  /// The branch layer at a glance: the policy and the counts.
  public query func tellerStatus() : async { policy : ?TeT.Policy; counts : { sessions : Nat; differences : Nat; movements : Nat; chequesPresented : Nat; chequesReturned : Nat; drafts : Nat } } {
    { policy = TellerCore.policy(bank.teller); counts = TellerCore.counts(bank.teller) }
  };

  // ─── trade finance (trade finance) ───────────────────────────────────────────────────

  func tradeView(caller : Principal, id : Nat) : Result.Result<?TrT.InstrumentView, T.BankError> {
    switch (TradeCore.row(bank.trade, id)) {
      case null #ok(null);
      case (?r) { if (not BankCore.mayReadBook(readScope(caller), r.book)) #err(#OutsideBookScope({ book = r.book })) else #ok(?TradeCore.view(bank.trade, r)) };
    }
  };
  /// An instrument's row: kind, state, parties, face, utilised, expiry, margin and commission figures, the hash of its terms.
  public shared query ({ caller }) func tradeInstrument(id : Nat) : async Result.Result<?TrT.InstrumentView, T.BankError> { tradeView(caller, id) };
  /// The terms an instrument was issued with, from its block.
  public shared query ({ caller }) func tradeTerms(id : Nat) : async Result.Result<?TrT.Kind, T.BankError> {
    switch (tradeView(caller, id)) { case (#err(e)) #err(e); case (#ok(null)) #ok(null); case (#ok(?_)) #ok(BankCore.tradeKind(bankBlocks(), id)) }
  };
  /// The claims under an instrument: presentations, demands, the collection's presentation.
  public shared query ({ caller }) func tradeClaims(id : Nat) : async Result.Result<[TrT.ClaimView], T.BankError> {
    switch (tradeView(caller, id)) { case (#err(e)) #err(e); case (#ok(null)) #ok([]); case (#ok(?_)) #ok(Array.map<TradeCore.ClaimRow, TrT.ClaimView>(TradeCore.claimsOf(bank.trade, id), TradeCore.claimView)) }
  };
  /// The messages exchanged under an instrument, by their hashes.
  public shared query ({ caller }) func tradeMessages(id : Nat) : async Result.Result<[TrT.MessageView], T.BankError> {
    switch (tradeView(caller, id)) { case (#err(e)) #err(e); case (#ok(null)) #ok([]); case (#ok(?_)) #ok(Array.map<TradeCore.MessageRow, TrT.MessageView>(TradeCore.messagesOf(bank.trade, id), TradeCore.messageView)) }
  };
  /// A party's instruments, paged, filtered to the caller's books.
  public shared query ({ caller }) func tradeInstrumentsOfParty(party : Nat, cursor : ?Blob, limit : Nat) : async { entries : [TrT.InstrumentView]; cursor : ?Blob } {
    let page = TradeCore.listByParty(bank.trade, party, cursor, limit);
    let out = List.empty<TrT.InstrumentView>();
    for (id in page.ids.vals()) { switch (tradeView(caller, id)) { case (#ok(?v)) List.add(out, v); case (_) {} } };
    { entries = List.toArray(out); cursor = page.cursor }
  };
  public shared query ({ caller }) func tradeInstrumentsByState(state : TrT.InstrumentState, cursor : ?Blob, limit : Nat) : async { entries : [TrT.InstrumentView]; cursor : ?Blob } {
    let page = TradeCore.listByState(bank.trade, state, cursor, limit);
    let out = List.empty<TrT.InstrumentView>();
    for (id in page.ids.vals()) { switch (tradeView(caller, id)) { case (#ok(?v)) List.add(out, v); case (_) {} } };
    { entries = List.toArray(out); cursor = page.cursor }
  };
  /// Open instruments expiring in a window of days, filtered to the caller's books.
  public shared query ({ caller }) func tradeExpiring(from : Nat, to : Nat, limit : Nat) : async [TrT.InstrumentView] {
    let out = List.empty<TrT.InstrumentView>();
    for (r in TradeCore.expiringBetween(bank.trade, from, to, limit).vals()) { if (BankCore.mayReadBook(readScope(caller), r.book)) List.add(out, TradeCore.view(bank.trade, r)) };
    List.toArray(out)
  };
  /// The undertakings outstanding against a facility — what its availability is reduced by.
  public query func tradeContingentOnFacility(facility : Nat) : async Nat { TradeCore.contingentOnFacility(bank.trade, facility) };
  /// The trade book at a glance: the policy, the counts, the contingent memoranda.
  public query func tradeStatus() : async { policy : ?TrT.Policy; status : TrT.TradeStatus } {
    { policy = TradeCore.policy(bank.trade); status = TradeCore.status(bank.trade) }
  };
  /// A message rendered from the instrument's recorded state: the SWIFT MT or the ISO 20022 tsrv message the
  /// counterparty bank receives. The message is a function of the block; what is returned is not stored.
  public shared query ({ caller }) func renderTradeMessage(id : Nat, kind : TrT.MessageKind, claim : ?Nat, amendment : ?Nat) : async Result.Result<Text, T.BankError> {
    let r = switch (tradeView(caller, id)) { case (#err(e)) return #err(e); case (#ok(null)) return #err(#TradeError({ error = #UnknownInstrument({ instrument = id }) })); case (#ok(?v)) v };
    let ?pol = TradeCore.policy(bank.trade) else return #err(#TradeError({ error = #NoPolicy }));
    let ?row = TradeCore.row(bank.trade, id) else return #err(#TradeError({ error = #UnknownInstrument({ instrument = id }) }));
    let mu : Nat8 = switch (Array.find<JT.CurrencyInfo>(JCore.listCurrencies(journal), func(c) { Text.equal(c.code, r.currency) })) { case (?c) c.minorUnits; case null 2 };
    let bankName = switch (BankCore.getBook(bank, r.book)) { case (?b) b.name; case null r.book };
    func bad(reason : Text) : Result.Result<Text, T.BankError> { #err(#TradeError({ error = #BadMessage({ reason }) })) };
    func claimOf() : ?TradeCore.ClaimRow { switch (claim) { case (?c) TradeCore.claim(bank.trade, id, c); case null null } };
    func amendmentOf() : ?{ amendment : TrT.Amendment; number : Nat; day : Nat; oldAmount : Nat } {
      let ?n = amendment else return null;
      // the n-th amendment block of the instrument: walk the claims' and amendments' blocks from the issue forward
      var i = id + 1; var found : ?{ amendment : TrT.Amendment; number : Nat; day : Nat; oldAmount : Nat } = null; var before = r.amount;
      // the face before each amendment is re-derived from the issue forward
      before := switch (bankBlock(id)) { case (?b) { switch (b.event) { case (#trade(#lcIssued(x))) x.amount; case (#trade(#lcAdvised(x))) x.amount; case (#trade(#guaranteeIssued(x))) x.amount; case (_) r.amount } }; case null r.amount };
      label walk while (i < BankCore.height(bank) and found == null) {
        switch (bankBlock(i)) {
          case (?b) { switch (b.event) { case (#trade(#lcAmended(x)) or #trade(#guaranteeAmended(x))) { if (x.instrument == id) { if (x.number == n) found := ?{ amendment = x.amendment; number = x.number; day = x.day; oldAmount = before } else before := x.amount } }; case (_) {} } };
          case null break walk;
        };
        i += 1;
      };
      found
    };
    switch (BankCore.tradeKind(bankBlocks(), id), kind) {
      case (?#letterOfCredit(lc), #mt(700)) {
        let place = switch (bankBlock(id)) { case (?b) { switch (b.event) { case (#trade(#lcIssued(x))) x.placeOfExpiry; case (#trade(#lcAdvised(x))) x.placeOfExpiry; case (_) "" } }; case null "" };
        #ok(TradeMessages.mt700(pol.bic, { lc; amount = row.amount; currency = row.currency; minorUnits = mu; expiry = row.expiry; placeOfExpiry = place; issuedDay = row.issuedDay; bankName }))
      };
      case (?#letterOfCredit(lc), #mt(707)) {
        let ?a = amendmentOf() else return bad("the amendment number names no amendment of this credit");
        #ok(TradeMessages.mt707(pol.bic, lc.counterpartyBank, lc.reference, row.issuedDay, a.number, a.day, row.currency, mu, a.oldAmount, a.amendment))
      };
      case (?#letterOfCredit(lc), #mt(750)) {
        let ?c = claimOf() else return bad("a refusal advice names the presentation");
        // the discrepancies from the examination block
        var disc : [Text] = []; var disp : TrT.Disposal = #held;
        var i = c.instrument + 1;
        label walk while (i < BankCore.height(bank)) {
          switch (bankBlock(i)) { case (?b) { switch (b.event) { case (#trade(#presentationExamined(x))) { if (x.instrument == id and x.claim == c.seq) { switch (x.decision) { case (#refuse(n)) { disc := n.discrepancies; disp := n.disposal }; case (#complying) {} }; break walk } }; case (_) {} } }; case null break walk };
          i += 1;
        };
        if (disc.size() == 0) return bad("the presentation was not refused");
        #ok(TradeMessages.mt750(pol.bic, lc.counterpartyBank, lc.reference, row.currency, mu, c.amount, disc, disp))
      };
      case (?#letterOfCredit(lc), #mt(752)) { let ?c = claimOf() else return bad("an authorisation names the presentation"); #ok(TradeMessages.mt752(pol.bic, lc.counterpartyBank, lc.reference, c.presentedOn, row.currency, mu, c.amount)) };
      case (?#letterOfCredit(lc), #mt(754)) {
        let ?c = claimOf() else return bad("an advice of payment names the presentation");
        let honour : TrT.Honour = switch (c.honour) { case 1 #sight; case 2 #deferred({ due = c.due }); case 3 #acceptance({ due = c.due }); case 4 #negotiation({ due = c.due }); case _ return bad("the presentation was not honoured") };
        #ok(TradeMessages.mt754(pol.bic, lc.counterpartyBank, lc.reference, row.currency, mu, c.amount, honour))
      };
      case (?#letterOfCredit(lc), #mt(799)) #ok(TradeMessages.mt799(pol.bic, lc.counterpartyBank, lc.reference, "CREDIT " # lc.reference # " STATE " # r.state # " OUTSTANDING " # TradeMessages.finAmount(r.outstanding, mu)));
      case (?#guarantee(g), #mt(760)) {
        let wording = switch (wordingOf(id)) { case (?w) w; case null "" };
        #ok(TradeMessages.mt760(pol.bic, { g; amount = row.amount; currency = row.currency; minorUnits = mu; expiry = row.expiry; issuedDay = row.issuedDay; wordingText = wording }))
      };
      case (?#guarantee(g), #mt(767)) {
        let ?a = amendmentOf() else return bad("the amendment number names no amendment of this undertaking");
        #ok(TradeMessages.mt767(pol.bic, guaranteeReceiver(g, pol.bic), g.reference, row.issuedDay, a.number, a.day, row.currency, mu, a.oldAmount, a.amendment))
      };
      case (?#guarantee(g), #mt(765)) { let ?c = claimOf() else return bad("a demand message names the demand"); #ok(TradeMessages.mt765(pol.bic, guaranteeReceiver(g, pol.bic), g.reference, c.presentedOn, row.currency, mu, c.amount, (c.flags & 1) != 0)) };
      case (?#guarantee(g), #mt(768)) #ok(TradeMessages.mt768(pol.bic, guaranteeReceiver(g, pol.bic), g.reference, row.issuedDay));
      case (?#guarantee(g), #mt(769)) #ok(TradeMessages.mt769(pol.bic, guaranteeReceiver(g, pol.bic), g.reference, row.issuedDay, row.currency, mu, row.utilised, r.outstanding));
      case (?#guarantee(g), #mt(799)) #ok(TradeMessages.mt799(pol.bic, guaranteeReceiver(g, pol.bic), g.reference, "UNDERTAKING " # g.reference # " STATE " # r.state));
      case (?#guarantee(g), #tsrv(1)) {
        let wording = switch (wordingOf(id)) { case (?w) w; case null "" };
        #ok(TradeMessages.tsrv001(pol.bic, bankName, { g; amount = row.amount; currency = row.currency; minorUnits = mu; expiry = row.expiry; issuedDay = row.issuedDay; wordingText = wording }))
      };
      case (?#guarantee(g), #tsrv(5)) { let ?a = amendmentOf() else return bad("the amendment number names no amendment of this undertaking"); #ok(TradeMessages.tsrv005(pol.bic, bankName, g.reference, a.number, a.day, row.currency, mu, a.oldAmount, a.amendment)) };
      case (?#guarantee(g), #tsrv(13)) { let ?c = claimOf() else return bad("a demand message names the demand"); #ok(TradeMessages.tsrv013(pol.bic, bankName, g.reference, g.reference # "/D" # Nat.toText(c.seq), row.currency, mu, c.amount, (c.flags & 1) != 0)) };
      case (?#guarantee(g), #tsrv(16)) {
        let ?c = claimOf() else return bad("a refusal names the demand");
        var disc : [Text] = []; var disp = "";
        var i = c.instrument + 1;
        label walk while (i < BankCore.height(bank)) {
          switch (bankBlock(i)) { case (?b) { switch (b.event) { case (#trade(#demandExamined(x))) { if (x.instrument == id and x.claim == c.seq) { switch (x.decision) { case (#refuse(n)) { disc := n.discrepancies; disp := debug_show n.disposal }; case (#complying) {} }; break walk } }; case (_) {} } }; case null break walk };
          i += 1;
        };
        if (disc.size() == 0) return bad("the demand was not refused");
        #ok(TradeMessages.tsrv016(pol.bic, bankName, g.reference, g.reference # "/D" # Nat.toText(c.seq), Nat64.fromNat(c.presentedOn) * 86_400_000_000_000, row.currency, mu, c.amount, disc, disp))
      };
      case (?#guarantee(g), #tsrv(12)) {
        let (effective, reason) = switch (r.state) { case ("released" or "expired") { (row.expiry, "undertaking " # r.state) }; case (_) return bad("the undertaking has not ended") };
        #ok(TradeMessages.tsrv012(pol.bic, bankName, g.reference, effective, reason))
      };
      case (null, _) #err(#TradeError({ error = #UnknownInstrument({ instrument = id }) }));
      case (?_, k) bad("no rendering of " # TrT.messageKindText(k) # " for this instrument")
    }
  };
  func guaranteeReceiver(g : TrT.Guarantee, own : Text) : Text {
    if (g.counterpartyBank != "") g.counterpartyBank else (switch (g.beneficiary) { case (#external(e)) e.bic; case (#party(_)) own })
  };
  /// The wording text of an undertaking, from its issuing block.
  func wordingOf(id : Nat) : ?Text {
    switch (bankBlock(id)) { case (?b) { switch (b.event) { case (#trade(#guaranteeIssued(x))) ?x.wordingText; case (_) null } }; case null null }
  };

  // ─── Islamic banking (Islamic banking) ─────────────────────────────────────────────────

  func shariaView(caller : Principal, id : Nat) : Result.Result<?IT.ContractView, T.BankError> {
    switch (IslamicCore.row(bank.islamic, id)) {
      case null #ok(null);
      case (?r) { if (not BankCore.mayReadBook(readScope(caller), r.book)) #err(#OutsideBookScope({ book = r.book })) else #ok(?IslamicCore.view(r)) };
    }
  };
  /// A contract's row: kind, stage, the party and account, principal, the profit total and recognised, collected, the counts.
  public shared query ({ caller }) func shariaContract(id : Nat) : async Result.Result<?IT.ContractView, T.BankError> { shariaView(caller, id) };
  /// The terms a contract was opened with, from its block.
  public shared query ({ caller }) func shariaContractTerms(id : Nat) : async Result.Result<?IT.Kind, T.BankError> {
    switch (shariaView(caller, id)) { case (#err(e)) #err(e); case (#ok(null)) #ok(null); case (#ok(?_)) #ok(BankCore.islamicKind(bankBlocks(), id)) }
  };
  /// The instalments (Murabaha) or rentals (Ijarah) of a contract with what was paid and what went to charity.
  public shared query ({ caller }) func shariaInstalments(id : Nat) : async Result.Result<[IslamicCore.InstalmentRow], T.BankError> {
    switch (shariaView(caller, id)) { case (#err(e)) #err(e); case (#ok(null)) #ok([]); case (#ok(?_)) #ok(IslamicCore.instalmentsOf(bank.islamic, id)) }
  };
  public shared query ({ caller }) func shariaContractsOfParty(party : Nat, cursor : ?Blob, limit : Nat) : async { entries : [IT.ContractView]; cursor : ?Blob } {
    let page = IslamicCore.listByParty(bank.islamic, party, cursor, limit);
    let out = List.empty<IT.ContractView>();
    for (id in page.ids.vals()) { switch (shariaView(caller, id)) { case (#ok(?v)) List.add(out, v); case (_) {} } };
    { entries = List.toArray(out); cursor = page.cursor }
  };
  public shared query ({ caller }) func shariaContractsByStage(stage : IT.Stage, cursor : ?Blob, limit : Nat) : async { entries : [IT.ContractView]; cursor : ?Blob } {
    let page = IslamicCore.listByStage(bank.islamic, stage, cursor, limit);
    let out = List.empty<IT.ContractView>();
    for (id in page.ids.vals()) { switch (shariaView(caller, id)) { case (#ok(?v)) List.add(out, v); case (_) {} } };
    { entries = List.toArray(out); cursor = page.cursor }
  };
  /// A pool with its reserves and the count of its distributions.
  public query func shariaPool(id : Text) : async ?IT.PoolView {
    switch (IslamicCore.pool(bank.islamic, id)) {
      case null null;
      case (?p) {
        let accounts = switch (bankBlock(p.openedBlock)) { case (?b) { switch (b.event) { case (#islamic(#poolOpened(x))) x.pool.incomeAccounts; case (_) [] } }; case null [] };
        ?IslamicCore.poolView(bank.islamic, p, accounts)
      };
    }
  };
  /// A pool's distributions, one row per period.
  public query func shariaDistributions(pool : Text) : async [IslamicCore.DistributionRow] { IslamicCore.distributionsOf(bank.islamic, pool) };
  /// The board approval a product carries, if any.
  public query func shariaApproval(product : Text) : async ?IT.BoardApproval { IslamicCore.approval(bank.islamic, product) };
  public query func isShariaBook(book : Text) : async Bool { IslamicCore.isShariaBook(bank.islamic, book) };
  /// The Sharia book at a glance: the policy, the counts, the charity total.
  public query func shariaStatus() : async { policy : ?IT.Policy; status : { contracts : Nat; open : Nat; charity : Nat; distributions : Nat; pools : Nat } } {
    { policy = IslamicCore.policy(bank.islamic); status = IslamicCore.status(bank.islamic) }
  };

  /// The collections book at a glance: the policy, the counts, the exposures per stage.
  public query func collectionsStatus() : async { policy : ?ColT.Policy; counts : { exposures : Nat; transitions : Nat; actions : Nat; promises : Nat; promisesKept : Nat; promisesBroken : Nat }; stages : [(Text, Nat)] } {
    { policy = CollectionsCore.policy(bank.collections); counts = CollectionsCore.counts(bank.collections); stages = CollectionsCore.stageDistribution(bank.collections) }
  };

  /// The suspicious-transaction report for an escalated alert — and for nothing else. Every field
  /// is read from the alert's blocks and the postings it cites: the rule as its version said it,
  /// the account's issued identifier (never a name), each cited posting's dates, legs and the
  /// movement on the reported account. An open or cleared alert has no report.
  public shared query ({ caller }) func suspiciousTransactionReport(alert : Nat) : async Result.Result<AlT.SuspiciousTransactionReport, T.BankError> {
    let ?a = AlertCore.get(bank.alerts, alertBlocks(), alert) else return #err(#AlertError({ error = #UnknownAlert({ alert }) }));
    switch (scopedAccount(caller, a.finding.account)) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    let (escalatedAt, reportRef) = switch (a.status) {
      case (#escalated(x)) (x.at, x.reportRef);
      case (other) return #err(#AlertError({ error = #AlertNotEscalated({ alert; status = AlT.statusText(other) }) }));
    };
    let ?rule = MonitoringCore.version(bank.monitoring, a.finding.rule, a.finding.version) else return #err(#MonitoringError({ error = #UnknownRule({ rule = a.finding.rule }) }));
    let ?acct = ProductCore.get(bank.product, productBlocks(), a.finding.account) else return #err(#ProductError({ error = #UnknownAccount({ account = a.finding.account }) }));
    let cited = List.empty<AlT.CitedPosting>();
    for (pn in a.finding.postings.vals()) {
      switch (BankCore.blockArchived(bank, pn)) { case (?e) return #err(e); case null {} };
      let ?b = JLog.get(journalLog, pn) else return #err(#JournalError({ error = #UnknownPosting({ index = pn }) }));
      let (rec, valueDate, postingDate) : (JT.PostingRecord, Nat, Nat) = switch (b.event) {
        case (#posted(r)) (r, r.valueDate, r.postingDate);
        case (#pending(p)) {
          switch (PIdx.header(postingIndex, pn)) { case (?h) (p.record, h.valueDay, h.postingDay); case null (p.record, p.record.valueDate, p.record.postingDate) }
        };
        case (_) return #err(#JournalError({ error = #UnknownPosting({ index = pn }) }));
      };
      var debits = 0; var credits = 0;
      for (leg in rec.legs.vals()) {
        switch (leg.subledger) {
          case (?sub) { if (sub == acct.subledger) { switch (leg.side) { case (#debit) debits += leg.amount; case (#credit) credits += leg.amount } } };
          case null {};
        };
      };
      List.add(cited, { posting = pn; valueDate; postingDate; legs = rec.legs.size(); debits; credits; sourceKind = rec.sourceRef.kind });
    };
    #ok({
      alert; rule = a.finding.rule; version = a.finding.version;
      ruleText = MT.specName(rule.spec) # " " # debug_show (rule.spec) # " (cost: " # Monitoring.costBound(rule.spec) # ")";
      account = a.finding.account; identifier = acct.identifier; currency = acct.currency; day = a.finding.day;
      detail = a.finding.detail; postings = List.toArray(cited); openedAt = a.openedAt; escalatedAt; reportRef;
    })
  };

  // ─── archive contracts: this contract creating contracts ───
  //
  // The step-by-step flow of `ArchiveTypes.mo`, each step one ingress message. The shape of every
  // step that sends a management call is the same and the order matters: **plan, commit the block,
  // then call.** The block is written before the first `await`, which is the only kind of write
  // that persists on this engine today; what follows the await is dropped, and the method's reply
  // is the management call's raw bytes rather than the declared record (the continuation
  // defect, `tools/spawn-proof/FINDING-async-raw-calls.md`). So a driver of these methods reads
  // the raw reply — `create_canister` answers eight little-endian bytes, `canister_status` the
  // 57-byte layout `ArchiveWire.parseStatusReply` decodes — and calls the next await-free step with
  // what it read. Once the substrate delivers management replies to the continuation, the declared records come through, the
  // caller-supplied facts are read here instead, and the steps fold into one message; every
  // transition is already a pure `ArchiveCore` function, so that is the whole of the change.

  /// `aaaaa-aa` — `CanisterId(0)` on this substrate. An empty callee principal is management.
  transient let MANAGEMENT : Principal = Principal.fromText("aaaaa-aa");

  /// Every management call. Raw bytes in and out — management replies are not Candid here. `async*`
  /// because a nested plain `async` is the buggy shape; it is still not enough for a raw call
  /// (the primitive's wrapper is itself plain `async`), which is why nothing after an `await*` of
  /// this is relied on.
  func mgmtCall(method : Text, arg : Blob) : async* Blob {
    await Prim.call_raw(MANAGEMENT, method, arg)
  };

  func archiveErr<X>(e : AT.ArchiveError) : Result.Result<X, T.BankError> { #err(#ArchiveError({ error = e })) };

  /// Upload the pinned image, one chunk at a time. Refused before a pin exists, after the pin is
  /// sealed, and past the pinned size — so the region can never hold more than the decision said.
  public shared ({ caller }) func uploadArchiveImageChunk(chunk : Blob) : async Result.Result<{ bytes : Nat; expected : Nat }, T.BankError> {
    switch (requireMethodPermission(caller, "uploadArchiveImageChunk")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    let ?img = ArchiveCore.currentImage(bank.archive) else return archiveErr(#NoImagePinned);
    switch (img.sealedAt) { case (?_) return archiveErr(#ImageAlreadySealed({ sha256 = img.sha256 })); case null {} };
    if (AImg.size(archiveImage) + chunk.size() > img.bytes) {
      return archiveErr(#ImageTooLarge({ bytes = AImg.size(archiveImage) + chunk.size(); cap = img.bytes }));
    };
    switch (AImg.append(archiveImage, chunk)) {
      case (#err(e)) archiveErr(e);
      case (#ok(n)) #ok({ bytes = n; expected = img.bytes });
    }
  };

  /// Forget an upload that went wrong. Refused once the image is sealed: a sealed image is what a
  /// spawn in flight installs.
  public shared ({ caller }) func resetArchiveImage() : async Result.Result<{ bytes : Nat }, T.BankError> {
    switch (requireMethodPermission(caller, "resetArchiveImage")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (ArchiveCore.currentImage(bank.archive)) {
      case (?img) { switch (img.sealedAt) { case (?_) return archiveErr(#ImageAlreadySealed({ sha256 = img.sha256 })); case null {} } };
      case null {};
    };
    AImg.reset(archiveImage);
    #ok({ bytes = 0 })
  };

  /// Seal: the SHA-256 of what is stored equals the pin, and the block says so. Computed here over
  /// the region, never taken from the uploader.
  public shared ({ caller }) func sealArchiveImage() : async Result.Result<{ sha256 : Blob; bytes : Nat; block : Nat }, T.BankError> {
    switch (requireMethodPermission(caller, "sealArchiveImage")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    let computed = AImg.hash(archiveImage);
    switch (ArchiveCore.planSeal(bank.archive, computed, AImg.size(archiveImage))) {
      case (#err(e)) archiveErr(e);
      case (#ok(ev)) { let b = commitBank(caller, #archive(ev)); #ok({ sha256 = computed; bytes = AImg.size(archiveImage); block = b.index }) };
    }
  };

  /// Step 1: record that a create is issued, then `create_canister` (no argument; the reply is the
  /// new id as eight little-endian bytes). Today the caller receives those eight bytes as the reply.
  public shared ({ caller }) func createArchiveChild(spawn : Nat) : async Result.Result<{ spawn : Nat; cid : Nat64; block : Nat }, T.BankError> {
    switch (requireMethodPermission(caller, "createArchiveChild")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    let ev = switch (ArchiveCore.planCreate(bank.archive, spawn)) { case (#err(e)) return archiveErr(e); case (#ok(ev)) ev };
    let b = commitBank(caller, #archive(ev));
    let reply = await* mgmtCall("create_canister", AW.CREATE_ARG);
    switch (AW.parseCreateReply(reply)) {
      case (#err(why)) throw Error.reject(why);
      case (#ok(cid)) #ok({ spawn; cid; block = b.index });
    }
  };

  /// Step 2, await-free: the id the create replied with, against the spawn. Refused for a spawn that
  /// issued no create, and for an id any spawn or child already holds; the same id again records
  /// nothing.
  public shared ({ caller }) func rememberArchiveChild(spawn : Nat, cid : Nat64) : async Result.Result<{ spawn : Nat; cid : Nat64; block : ?Nat }, T.BankError> {
    switch (requireMethodPermission(caller, "rememberArchiveChild")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (ArchiveCore.planRemember(bank.archive, spawn, cid)) {
      case (#err(e)) archiveErr(e);
      case (#ok(null)) #ok({ spawn; cid; block = null });
      case (#ok(?ev)) #ok({ spawn; cid; block = ?commitBank(caller, #archive(ev)).index });
    }
  };

  /// Step 3: record that an install is issued, then `install_code` with the sealed image and an
  /// **empty** init argument. Repeatable for the same id; the engine refuses a second install onto a
  /// child that holds code, which the caller reads as "installed — confirm it".
  public shared ({ caller }) func installArchiveChild(spawn : Nat) : async Result.Result<{ spawn : Nat; cid : Nat64; image : Blob; bytes : Nat; block : Nat }, T.BankError> {
    switch (requireMethodPermission(caller, "installArchiveChild")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    let plan = switch (ArchiveCore.planInstall(bank.archive, spawn)) { case (#err(e)) return archiveErr(e); case (#ok(p)) p };
    let wasm = AImg.bytes(archiveImage);
    let frame = switch (AW.installFrame(plan.cid, wasm)) { case (#err(e)) return archiveErr(e); case (#ok(f)) f };
    let b = commitBank(caller, #archive(plan.event));
    ignore await* mgmtCall("install_code", frame);
    #ok({ spawn; cid = plan.cid; image = plan.image; bytes = wasm.size(); block = b.index })
  };

  /// `canister_status` for any id, decoded from the engine's 57-byte layout; the raw bytes are
  /// returned too so a reader can check the decoding. Writes nothing. Today the caller receives the
  /// raw 57 bytes as the reply.
  public shared ({ caller }) func archiveChildStatus(cid : Nat64) : async Result.Result<{ raw : Blob; status : ?AW.Status }, T.BankError> {
    switch (requireMethodPermission(caller, "archiveChildStatus")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    let raw = await* mgmtCall("canister_status", AW.idArg(cid));
    #ok({ raw; status = switch (AW.parseStatusReply(raw)) { case (#ok(st)) ?st; case (#err(_)) null } })
  };

  /// Step 4, await-free. `moduleHash` is what the caller read from the chain, and it is compared with
  /// the parent's own pin of the image it sent (the confirmation rule). A refusal is recorded and the
  /// install can be retried; the empty-module hash means it never landed.
  public shared ({ caller }) func confirmArchiveChild(spawn : Nat, moduleHash : Blob) : async Result.Result<{ spawn : Nat; cid : Nat64; confirmed : Bool; block : Nat }, T.BankError> {
    switch (requireMethodPermission(caller, "confirmArchiveChild")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (ArchiveCore.planConfirm(bank.archive, spawn, moduleHash)) {
      case (#err(e)) archiveErr(e);
      case (#ok(out)) {
        let b = commitBank(caller, #archive(out.event));
        let cid = switch (out.event) { case (#childConfirmed(x)) x.cid; case (#confirmRefused(x)) x.cid; case (_) 0 : Nat64 };
        #ok({ spawn; cid; confirmed = out.confirmed; block = b.index })
      };
    }
  };

  /// Step 5: record, then `update_settings` with the parent first and the configured principals
  /// after — the engine replaces the set, so the parent lists itself to stay a controller.
  public shared ({ caller }) func setArchiveChildControllers(spawn : Nat) : async Result.Result<{ spawn : Nat; cid : Nat64; controllers : [Principal]; block : Nat }, T.BankError> {
    switch (requireMethodPermission(caller, "setArchiveChildControllers")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    let plan = switch (ArchiveCore.planControllers(bank.archive, spawn, me())) { case (#err(e)) return archiveErr(e); case (#ok(p)) p };
    let frame = switch (AW.controllersFrame(plan.cid, plan.controllers)) { case (#err(e)) return archiveErr(e); case (#ok(f)) f };
    let b = commitBank(caller, #archive(plan.event));
    ignore await* mgmtCall("update_settings", frame);
    #ok({ spawn; cid = plan.cid; controllers = plan.controllers; block = b.index })
  };

  /// Step 6, await-free: the child is an archive of this bank. Nothing a contract can call reports a
  /// child's controllers, so what this records is that the driver saw `update_settings` reply — the
  /// second place that substrate change closes a gap.
  public shared ({ caller }) func completeArchiveChild(spawn : Nat) : async Result.Result<{ spawn : Nat; cid : Nat64; block : Nat }, T.BankError> {
    switch (requireMethodPermission(caller, "completeArchiveChild")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (ArchiveCore.planComplete(bank.archive, spawn)) {
      case (#err(e)) archiveErr(e);
      case (#ok(ev)) {
        let b = commitBank(caller, #archive(ev));
        let cid = switch (ev) { case (#childReady(x)) x.cid; case (_) 0 : Nat64 };
        #ok({ spawn; cid; block = b.index })
      };
    }
  };

  /// The re-check before an archive write: the chain's module hash for a child against the recorded
  /// one. Writes nothing. Today the caller receives the raw status bytes as the reply and compares
  /// them with `getArchiveChild`.
  public shared ({ caller }) func recheckArchiveChild(cid : Nat64) : async Result.Result<{ matches : Bool; recorded : Blob; found : Blob }, T.BankError> {
    switch (requireMethodPermission(caller, "recheckArchiveChild")) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    let ?_ = ArchiveCore.child(bank.archive, cid) else return archiveErr(#UnknownChild({ cid }));
    let raw = await* mgmtCall("canister_status", AW.idArg(cid));
    let st = switch (AW.parseStatusReply(raw)) { case (#err(why)) throw Error.reject(why); case (#ok(st)) st };
    switch (ArchiveCore.checkChild(bank.archive, cid, st.moduleHash)) {
      case (#err(e)) archiveErr(e);
      case (#ok(r)) #ok({ matches = r.matches; recorded = r.recorded; found = st.moduleHash });
    }
  };

  public query func archiveStatus() : async {
    image : ?AT.Image; uploadedBytes : Nat; controllers : [Principal];
    images : Nat; spawns : Nat; children : Nat; inFlight : Nat; refusedConfirmations : Nat;
  } {
    let c = ArchiveCore.counts(bank.archive);
    {
      image = ArchiveCore.currentImage(bank.archive);
      uploadedBytes = AImg.size(archiveImage);
      controllers = ArchiveCore.controllers(bank.archive);
      images = c.images; spawns = c.spawns; children = c.children; inFlight = c.inFlight; refusedConfirmations = c.refusedConfirmations;
    }
  };

  public query func getArchiveSpawn(spawn : Nat) : async ?AT.Spawn { ArchiveCore.spawn(bank.archive, spawn) };
  public query func getArchiveChild(cid : Nat64) : async ?AT.Child { ArchiveCore.child(bank.archive, cid) };
  public query func getArchiveImage(sha256 : Blob) : async ?AT.Image { ArchiveCore.image(bank.archive, sha256) };

  public query func listArchiveSpawns(cursor : ?Nat, limit : Nat) : async { rows : [AT.Spawn]; cursor : ?Nat; total : Nat } {
    ArchiveCore.listSpawnsPaged(bank.archive, cursor, Nat.min(Nat.max(limit, 1), JCore.MAX_PAGE))
  };

  public query func listArchiveChildren(cursor : ?Nat64, limit : Nat) : async { rows : [AT.Child]; cursor : ?Nat64; total : Nat } {
    ArchiveCore.listChildrenPaged(bank.archive, cursor, Nat.min(Nat.max(limit, 1), JCore.MAX_PAGE))
  };

  /// The child's principal, for a caller that wants to address it directly: the id as eight
  /// big-endian bytes. Pure; here so the two endiannesses have one authority.
  public query func archiveChildPrincipal(cid : Nat64) : async Principal { AW.childPrincipal(cid) };

  // ─── the certified pull feed ───

  /// Events after a cursor, with the bounds, the tip and a digest over the slice in order. A
  /// consumer that trusts nothing recomputes the digest, checks the run is contiguous from
  /// where it asked, and verifies the tip's certificate — so a splice, a reorder or a
  /// truncation is detectable rather than invisible.
  public query func feedPage(from : Nat, limit : Nat) : async Feed.FeedPage {
    let n = if (limit == 0 or limit > Feed.MAX_PAGE) Feed.MAX_PAGE else limit;
    let tip = BLog.length(bankLog);
    let events = List.empty<RepT.FeedEvent>();
    var i = from;
    var last = from;
    while (i < tip and List.size(events) < n) {
      switch (bankBlock(i)) {
        case (?b) {
          List.add(events, { cursor = i; block = i; kind = BankCore.eventKind(b.event); book = BankCore.eventBook(b.event) });
          last := i;
        };
        case null {};
      };
      i += 1;
    };
    let to = if (List.size(events) == 0) from else last + 1;
    let arr = List.toArray(events);
    {
      events = arr;
      from;
      to;
      tipCursor = tip;
      caughtUp = to >= tip;
      digest = Feed.pageDigest(arr, from, to);
    }
  };

  public query func listFeedEndpoints() : async [RepT.FeedEndpoint] {
    let out = List.empty<RepT.FeedEndpoint>();
    for (e in ReportCore.activeEndpoints(bank.report).vals()) List.add(out, e);
    List.toArray(out)
  };

  public query func listDeadLetters() : async [RepT.DeadLetter] { ReportCore.deadLetters(bank.report) };

  public query func listCertifiedArtefacts() : async [ReportCore.CertifiedEntry] { ReportCore.listCertified(bank.report) };

  public query func reportStatus() : async {
    definitions : Nat; templates : Nat; statements : Nat; certified : Nat;
    endpoints : Nat; deadLetters : Nat; artefactRoot : Blob; feedTip : Nat;
  } {
    {
      definitions = ReportCore.defCount(bank.report);
      templates = ReportCore.templateCount(bank.report);
      statements = ReportCore.statementCount(bank.report);
      certified = ReportCore.certifiedCount(bank.report);
      endpoints = ReportCore.endpointCount(bank.report);
      deadLetters = ReportCore.deadLetterCount(bank.report);
      artefactRoot = ReportCore.artefactRoot(bank.report);
      feedTip = BLog.length(bankLog);
    }
  };

  // ─── bank log and proofs ───

  public query func bankBlockCount() : async Nat { BLog.length(bankLog) };
  public query func getBankBlock(index : Nat) : async ?T.Block { bankBlock(index) };
  public query func getBankBlocks(start : Nat, length : Nat) : async [T.Block] { BLog.getRangeWith(bankLog, packedBankBlock, start, Nat.min(length, 1000)) };
  /// The stored bytes: the log's, or the pack's once the prefix has left — a packed proposal's body may be
  /// gone (the trailer byte 0), its preimage and hash never.
  public query func getRawBankBlock(index : Nat) : async ?Blob { bankRaw(index) };
  /// Where the bank log's `StableLog` begins: blocks below it are read from the packs.
  public query func bankLogBase() : async Nat { BLog.base(bankLog) };
  public query func bankMmrRoot() : async ?Blob { BLog.mmrRoot(bankLog) };
  public query func bankProof(index : Nat) : async ?BLog.Proof { BLog.proof(bankLog, index) };
  public query func verifyBankChain() : async { checked : Nat; fault : ?Text } { BLog.verifyChainWith(bankLog, packedBankBlock) };
  public query func verifyBankProofLocally(index : Nat) : async Bool {
    switch (bankBlock(index), BLog.proof(bankLog, index), BLog.mmrRoot(bankLog)) {
      case (?b, ?p, ?root) BLog.verify(b.hash, index, p, root);
      case _ false;
    }
  };

  /// One certificate over both tips.
  public query func tipCertificate() : async ?BCert.Certificate { BCert.certificate(cert) };

  /// Fingerprints of both derived states, live and replayed from their logs.
  public query func fingerprints() : async {
    bankLive : Blob; bankReplayed : Blob; journalLive : Blob; journalReplayed : Blob;
    bankHeight : Nat; journalHeight : Nat;
  } {
    let freshBank = BankCore.replay(installer, BLog.getRangeWith(bankLog, packedBankBlock, 0, BLog.length(bankLog)));
    // a log whose prefix has left is folded from its checkpoint series; one still whole from genesis
    let freshJournal = switch (JCore.checkpointPosition(journal)) {
      case (?cp) {
        let ?last = cp.last else Runtime.trap("Bank: the checkpoint series is incomplete");
        JCore.replayFrom(me(), journalBlocks(), cp.first, last, JLog.length(journalLog))
      };
      case null JCore.replay(me(), JLog.getRange(journalLog, 0, JLog.length(journalLog)));
    };
    // the live journal dropped the idempotency keys of every packed range; the replayed one must
    // drop the same, and the bank's log says through which block
    JCore.dropIdempotencyThrough(freshJournal, bank.packing.packedThroughBlock);
    {
      bankLive = BankCore.fingerprint(bank);
      bankReplayed = BankCore.fingerprint(freshBank);
      journalLive = JCore.fingerprint(journal);
      journalReplayed = JCore.fingerprint(freshJournal);
      bankHeight = BankCore.height(bank);
      journalHeight = JCore.height(journal);
    }
  };

  // ═══════════════════════════════════════════════════════
  //  JOURNAL QUERIES (the books this canister keeps)
  // ═══════════════════════════════════════════════════════

  public query func journalBlockCount() : async Nat { JLog.length(journalLog) };
  public query func getJournalBlock(index : Nat) : async ?JT.Block { JLog.get(journalLog, index) };
  public query func getJournalBlocks(start : Nat, length : Nat) : async [JT.Block] { JLog.getRange(journalLog, start, Nat.min(length, 1000)) };
  public query func getRawJournalBlock(index : Nat) : async ?Blob { JLog.rawBlock(journalLog, index) };
  public query func journalMmrRoot() : async ?Blob { JLog.mmrRoot(journalLog) };
  public query func journalProof(index : Nat) : async ?JLog.Proof { JLog.proof(journalLog, index) };
  /// The upper part of an archived block's proof: the siblings from the kept height up, the peaks
  /// and the peak index. The siblings below come from the archive that holds the block's aligned
  /// block of 2^keptHeight leaves (`subtreeRoot` on the archive child); joined, they are a proof
  /// `journalProof` would have given, checked by the same `verifyJournalProof`.
  public query func journalProofAbove(index : Nat) : async ?{ lower : [?Blob]; siblings : [Blob]; fromHeight : Nat; peakIndex : Nat; peaks : [Blob]; treeHeight : Nat } { JLog.proofAbove(journalLog, index) };
  public query func journalMmrStats() : async { leaves : Nat; nodes : Nat; prunedThroughLeaf : Nat; prunedThroughPos : Nat; chunks : Nat; freeChunks : Nat; kept : Nat; pages : Nat; keptHeight : Nat } {
    let st = JLog.mmrStats(journalLog);
    { st with keptHeight = JLog.mmrKeptHeight() }
  };

  /// The posting the canister made under a derived idempotency key, if any.
  ///
  /// Every posting the bank submits carries a key derived from what it is for — the
  /// account, the charge, the day — so a disputed figure is found by deriving the key
  /// again rather than by searching the log. The index this returns is the block to fetch
  /// and prove; the batch's own duplicate rule reads the same index.
  public query func journalPostingByKey(key : Blob) : async ?Nat {
    JCore.postingIndexByKey(journal, me(), key)
  };
  public query func verifyJournalChain() : async { checked : Nat; fault : ?Text } { JLog.verifyChain(journalLog) };
  public query func journalAdmin() : async Principal { journal.admin };
  public query func journalActive() : async Bool { JCore.isActive(journal) };
  public query func journalActivationHeight() : async Nat64 { journal.activationHeight };
  public query func listPosters() : async [Principal] { JCore.listPosters(journal) };
  public query func listPosterScopes() : async [(Principal, JT.PosterScope)] { JCore.listPosterScopes(journal) };
  /// ─── the journal's reads, bounded ───
  ///
  /// Each of these was a read of "all of them". The chart, the balance set, a period's postings and the
  /// open pendings all grow with the book, so each now takes a cursor and a limit and each underlying
  /// accessor seeks rather than scans. What stays unpaged is what a recorded act bounds: periods,
  /// currencies, posters, the leadsheet schema — tens of rows each, every one the result of a
  /// dual-authorised command, and the reason is stated rather than left to be inferred.
  public query func listAccounts(cursor : ?JT.AccountCode, limit : Nat) : async JCore.AccountPage {
    JCore.listAccountsPaged(journal, cursor, limit)
  };
  public query func listPeriods() : async [JT.Period] { JCore.listPeriods(journal) };
  public query func listCurrencies() : async [JT.CurrencyInfo] { JCore.listCurrencies(journal) };
  public query func trialBalance(period : JT.PeriodId) : async ?JT.TrialBalance { JCore.trialBalance(journal, period) };
  public query func trialBalanceMapped(period : JT.PeriodId) : async ?JT.MappedTrialBalance { JCore.mappedTrialBalance(journal, period) };
  /// The general ledger of a period. Its shape is a nest — accounts, each with its entries — so a flat
  /// cursor would not describe it; it is bounded the way a report is bounded instead. The period's own
  /// posting count is the size, it is checked **before** the fold runs, and a period past the bound is
  /// refused naming its size and what to do about it.
  ///
  /// A caller who wants one account's ledger at any size wants `accountLedger` below, which is a range
  /// scan of the account index and pages.
  public query func generalLedger(period : JT.PeriodId, account : ?JT.AccountCode) : async Result.Result<?JT.GeneralLedger, T.BankError> {
    switch (BankCore.periodArchived(bank, journal, period)) { case (?a) return #err(#PackingError({ error = #PeriodArchived({ period; pack = a.pack; cid = a.cid; archive = a.archive }) })); case null {} };
    let size = JCore.periodPostingIndicesPaged(journal, period, 0, 1).total;
    if (size > Queries.MAX_SCAN) {
      return #err(#QueryError({ error = #TooWide({
        size;
        bound = Queries.MAX_SCAN;
        narrow = "the period holds more postings than one general-ledger fold is allowed; read one account at a time with accountLedger, or export the period with certifyExport";
      }) }));
    };
    #ok(JCore.generalLedger(journal, journalBlocks(), period, account))
  };

  /// One account's ledger entries over a value-date window, paged: a range scan of the account index,
  /// so the cost is the page. This is the general ledger a caller reads at a million accounts, and it
  /// carries the journal height the page was read at so every row is checkable against the certified
  /// root.
  public shared query ({ caller }) func accountLedger(account : ProdT.AccountId, from : ?JT.Day, to : ?JT.Day, cursor : ?Blob, limit : Nat) : async Result.Result<Queries.Page, T.BankError> {
    runQuery(caller, {
      account = ?account;
      currency = null;
      class_ = null;
      from;
      to;
      minAmount = null;
      maxAmount = null;
      statuses = null;
      cursor;
      limit;
    })
  };
  public query func balance(account : JT.AccountCode, subledger : ?JT.SubledgerKey, currency : JT.Currency) : async JT.Balance { JCore.balance(journal, account, subledger, currency) };
  /// The journal's numeric limit on a balance — a participant's net debit cap is this, on its position.
  public query func balanceLimit(account : JT.AccountCode, subledger : ?JT.SubledgerKey, currency : JT.Currency) : async ?JT.BalanceLimit { JCore.balanceLimit(journal, account, subledger, currency) };
  public query func accountTotal(account : JT.AccountCode, currency : JT.Currency) : async JT.Balance { JCore.accountTotal(journal, account, currency) };
  /// The sub-ledgers under one account. The read that most needed paging: the chart has thousands of
  /// accounts, but one customer-accounts control carries a sub-ledger for every account the bank holds.
  public query func subledgerBalances(account : JT.AccountCode, cursor : ?JCore.BalanceCursor, limit : Nat) : async JCore.BalancePage {
    JCore.subledgerBalancesPaged(journal, account, cursor, limit)
  };
  public query func allBalances(cursor : ?JCore.BalanceCursor, limit : Nat) : async JCore.BalancePage {
    JCore.allBalancesPaged(journal, cursor, limit)
  };
  public query func getPosting(index : Nat) : async ?JT.PostingView { JCore.postingView(journal, journalBlocks(), index) };
  public query func listPending(cursor : ?Nat, limit : Nat) : async JCore.PendingPage {
    JCore.listPendingPaged(journal, journalBlocks(), cursor, limit)
  };
  public query func balanceAsOf(account : JT.AccountCode, subledger : ?JT.SubledgerKey, currency : JT.Currency, asOf : JT.Day) : async { debits : Nat; credits : Nat } {
    JCore.balanceAsOf(journal, account, subledger, currency, asOf)
  };
  public query func valueDatedBalance(account : JT.AccountCode, subledger : ?JT.SubledgerKey, currency : JT.Currency, asOf : JT.Day) : async { debits : Nat; credits : Nat } {
    JCore.valueDatedBalance(journal, account, subledger, currency, asOf)
  };
  public query func businessDate() : async ?JT.Day { JCore.businessDate(journal) };
  public query func accountingToday() : async JT.Day { JCore.effectiveToday(journal, now()) };
  public query func calendar() : async ?JT.CalendarConfig { JCore.calendar(journal) };
  public query func leadsheetSchema() : async [JT.LeadsheetRange] { JCore.leadsheetSchema(journal) };
  public query func periodPostingIndices(period : JT.PeriodId, cursor : Nat, limit : Nat) : async JCore.PostingIndexPage {
    JCore.periodPostingIndicesPaged(journal, period, cursor, limit)
  };
  public query func camt053Statement(period : JT.PeriodId, account : JT.AccountCode, subledger : ?JT.SubledgerKey, currency : JT.Currency) : async ?JCamt.Statement {
    // an archived period's entries are in the archive: `periodLocation` says where
    if (BankCore.periodArchived(bank, journal, period) != null) return null;
    JCamt.statement(journal, journalBlocks(), period, account, subledger, currency, func(i) { switch (JLog.get(journalLog, i)) { case (?b) ?b.hash; case null null } })
  };
  /// camt.053 XML for a statement, as the journal itself serves it. The message id is
  /// derived from the statement key and the bank's height, so it is stable for an
  /// unchanged log and changes when the log does.
  public query func camt053Xml(period : JT.PeriodId, account : JT.AccountCode, subledger : ?JT.SubledgerKey, currency : JT.Currency) : async ?Text {
    camtXml(period, account, subledger, currency)
  };

  /// The camt.053 projection of a recorded statement cut: the customer statement for the
  /// account the cut was taken on, over the period the cut day falls in.
  ///
  /// The cut is the bank's record of where an account stood at close of business; this is
  /// that account's statement in the form a customer's bank sends it. The two are read
  /// together in `statementCutCamt053`, which returns the cut beside the projection so a
  /// disputed figure can be traced from the message back to the block that recorded it.
  public shared query ({ caller }) func statementCutCamt053(account : ProdT.AccountId) : async Result.Result<{ cut : BT.StatementCut; statement : ?JCamt.Statement; xml : ?Text }, T.BankError> {
    switch (scopedAccount(caller, account)) {
      case (#err(e)) #err(e);
      case (#ok(_)) {
        let ?cut = BatchCore.cutFor(bank.batch, account) else {
          return #err(#BatchError({ error = #NoStatementCut({ account }) }));
        };
        let ?entry = ProductCore.get(bank.product, productBlocks(), account) else {
          return #err(#ProductError({ error = #UnknownAccount({ account }) }));
        };
        let ?terms = ProductCore.termsOf(bank.product, entry) else {
          return #err(#ProductError({ error = #UnknownAccount({ account }) }));
        };
        var period = "";
        for (p in JCore.listPeriods(journal).vals()) {
          if (cut.day >= p.start and cut.day <= p.end) period := p.id;
        };
        switch (BankCore.periodArchived(bank, journal, period)) { case (?a) return #err(#PackingError({ error = #PeriodArchived({ period; pack = a.pack; cid = a.cid; archive = a.archive }) })); case null {} };
        #ok({
          cut;
          statement = JCamt.statement(journal, journalBlocks(), period, terms.control, ?entry.subledger, cut.currency, func(i) { switch (JLog.get(journalLog, i)) { case (?b) ?b.hash; case null null } });
          xml = camtXml(period, terms.control, ?entry.subledger, cut.currency);
        })
      };
    }
  };

  func camtXml(period : JT.PeriodId, account : JT.AccountCode, subledger : ?JT.SubledgerKey, currency : JT.Currency) : ?Text {
    if (BankCore.periodArchived(bank, journal, period) != null) return null;
    let ?mu = JCore.currencyMinorUnits(journal, currency) else return null;
    switch (JCamt.statement(journal, journalBlocks(), period, account, subledger, currency, func(i) { switch (JLog.get(journalLog, i)) { case (?b) ?b.hash; case null null } })) {
      case null null;
      case (?st) {
        let msgId = "THEBES-BANK-" # period # "-" # account # "-" # currency # "-H" # Nat.toText(BankCore.height(bank));
        let day = CivilDate.fromNanos(Nat64.toNat(now()));
        ?JCamt.toXml(st, mu, msgId, CivilDate.toText(day) # "T00:00:00Z")
      };
    }
  };

  public query func journalStatus() : async {
    height : Nat; posted : Nat; pending : Nat; voided : Nat; active : Bool;
    accounts : Nat; periods : Nat; currencies : Nat; fingerprint : Blob;
  } {
    {
      height = JCore.height(journal);
      posted = JCore.postedCount(journal);
      pending = JCore.pendingCount(journal);
      voided = JCore.voidedCount(journal);
      active = JCore.isActive(journal);
      accounts = JCore.listAccounts(journal).size();
      periods = JCore.listPeriods(journal).size();
      currencies = JCore.listCurrencies(journal).size();
      fingerprint = JCore.fingerprint(journal);
    }
  };

  // ═══════════════════════════════════════════════════════
  //  LIFECYCLE
  // ═══════════════════════════════════════════════════════

  // Genesis runs once, in the install message. On an upgrade the logs are
  // already populated and nothing is written again.
  if (BLog.length(bankLog) == 0) { genesis() };

  // The IC clears certified data on upgrade; restore it from persisted state.
  BCert.recertify(cert);

  // Proposals past their lifetime are recorded expired, never silently dropped —
  // the rule the journal applies to its own pending postings.
  ignore Timer.recurringTimer<system>(#seconds 60, func() : async () {
    let expired = BankCore.expiredProposals(bank, now(), 50);
    for (idx in expired.vals()) { ignore commitBank(me(), BankCore.expiryEvent(idx)) };
  });
};
