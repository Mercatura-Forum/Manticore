/// Journal.mo: the double-entry journal canister.
///
/// Composition:
///   JournalCore  pure admission and state (heap, persisted across upgrades)
///   JournalLog   Region-backed, hash-chained, MMR-committed block log
///   JournalCert  certified tip (last block index, last block hash, MMR root)
///
/// Every update method follows one shape: validate with the core (no state
/// change), append the resulting event to the log, apply it to the core,
/// re-certify the tip. There is no `await` anywhere on that path, so each call
/// is atomic: it either commits one block and its consequences or
/// changes nothing.
///
/// Gate: financial writes are refused until an administrator sets an
/// activation height at or below the journal's current height. The default
/// is `ACTIVATION_OFF` (2^64-1). Configuration is allowed before activation so
/// that a journal can be set up, then switched on in one recorded act.

import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import Text "mo:core/Text";
import List "mo:core/List";
import Runtime "mo:core/Runtime";

import T "JournalTypes";
import Core "JournalCore";
import JLog "JournalLog";
import JCert "JournalCert";
import Camt "Camt053";
import YearEnd "YearEnd";
import Archive "JournalArchive";
import Error "mo:core/Error";
import Array "mo:core/Array";
import CivilDate "CivilDate";

shared (initMsg) persistent actor class Journal() = self {

  // ─── persisted state ──────────────────────────────────────────────────────

  let genesisAdmin : Principal = initMsg.caller;
  let core : Core.State = Core.newState(genesisAdmin);
  let log : JLog.State = JLog.newState();
  let cert : JCert.State = JCert.newState();

  // ── archive registry: blocks below `localOffset` are served by child canisters ──
  type ArchiveEntry = { canisterId : Principal; firstBlock : Nat; lastBlock : Nat };
  var archives : [ArchiveEntry] = [];
  var localOffset : Nat = 0;
  var archiveInProgress : Bool = false;
  var archiveBatchSize : Nat = 200;

  // ─── helpers ──────────────────────────────────────────────────────────────

  func now() : Nat64 { Nat64.fromNat(Int.abs(Time.now())) };

  /// How the core reads a posting's record back. The records are in the log, so this is the log.
  /// A posting whose block has been archived is not readable here, which is why the core traps rather
  /// than answering partially: an archived posting is a closed period's, and nothing in the live state
  /// should still be asking for one.
  func blocks() : Core.Blocks { { get = func(i : Nat) : ?T.Block { JLog.get(log, i) } } };

  /// Append an event, apply it, certify the tip. Atomic within the message.
  func commit(caller : Principal, event : T.Event) : T.Block {
    let block = JLog.append(log, now(), caller, event);
    Core.apply(core, blocks(), block);
    switch (JLog.mmrRoot(log)) {
      case (?root) JCert.update(cert, block.index, block.hash, root);
      case null assert false; // an MMR with one or more leaves always has a root
    };
    block
  };

  func hashOf(index : Nat) : ?Blob {
    switch (JLog.get(log, index)) { case (?b) ?b.hash; case null null }
  };

  type PostReply = Result.Result<T.PostResult, T.PostError>;

  func replyFor(prepared : Core.Prepared, caller : Principal) : PostReply {
    switch (prepared) {
      case (#duplicate(existing)) {
        switch (hashOf(existing)) {
          case (?h) #ok({ index = existing; duplicate = true; hash = h });
          case null #err(#UnknownPosting({ index = existing }));
        }
      };
      case (#event(e)) {
        let b = commit(caller, e);
        #ok({ index = b.index; duplicate = false; hash = b.hash })
      };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  FINANCIAL WRITES (posters)
  // ═══════════════════════════════════════════════════════

  /// Admit and post a balanced posting.
  public shared ({ caller }) func post(input : T.PostingInput) : async PostReply {
    switch (Core.preparePost(core, caller, now(), input)) {
      case (#err(e)) #err(e);
      case (#ok(p)) replyFor(p, caller);
    }
  };

  /// Admit several postings atomically: all are committed or none is. The
  /// error names the first offending position. Exact duplicates of postings
  /// already committed are returned with `duplicate = true`.
  public shared ({ caller }) func postBatch(inputs : [T.PostingInput]) : async Result.Result<[T.PostResult], T.BatchError> {
    switch (Core.prepareBatch(core, caller, now(), inputs)) {
      case (#err(e)) #err(e);
      case (#ok(prepared)) {
        let results = List.empty<T.PostResult>();
        var i = 0;
        while (i < prepared.size()) {
          switch (replyFor(prepared[i], caller)) {
            case (#ok(r)) List.add(results, r);
            // Unreachable by construction: every item was admitted above and
            // duplicates resolve to existing blocks. A trap rolls the whole
            // message back, so a batch can never land partially.
            case (#err(_)) Runtime.trap("postBatch: admitted item " # Nat.toText(i) # " failed to commit");
          };
          i += 1;
        };
        #ok(List.toArray(results))
      };
    }
  };

  /// Phase one: reserve a balanced posting as pending.
  public shared ({ caller }) func reserve(input : T.PostingInput, expiresAt : ?Nat64) : async PostReply {
    switch (Core.prepareReserve(core, caller, now(), input, expiresAt)) {
      case (#err(e)) #err(e);
      case (#ok(p)) replyFor(p, caller);
    }
  };

  public type ResolveResult = { pendingIndex : Nat; blockIndex : Nat; hash : Blob };

  /// Phase two: post a pending posting. An expired pending is voided in this
  /// call and the typed error names the void block.
  public shared ({ caller }) func postPending(pendingIndex : Nat, override : ?T.Resolution) : async Result.Result<ResolveResult, T.PostError> {
    switch (Core.preparePostPending(core, blocks(), caller, now(), pendingIndex, override)) {
      case (#err(e)) #err(e);
      case (#ok(#expired({ expiresAt }))) {
        let v = commit(Principal.fromActor(self), Core.expiryVoidEvent(pendingIndex));
        #err(#PendingExpired({ index = pendingIndex; expiresAt; voidedBy = v.index }))
      };
      case (#ok(#event(e))) {
        let b = commit(caller, e);
        #ok({ pendingIndex; blockIndex = b.index; hash = b.hash })
      };
    }
  };

  /// Phase two: void a pending posting.
  public shared ({ caller }) func voidPending(pendingIndex : Nat) : async Result.Result<ResolveResult, T.PostError> {
    switch (Core.prepareVoidPending(core, blocks(), caller, pendingIndex)) {
      case (#err(e)) #err(e);
      case (#ok(e)) { let b = commit(caller, e); #ok({ pendingIndex; blockIndex = b.index; hash = b.hash }) };
    }
  };

  /// Reverse a posted posting with its exact mirror. The original is untouched.
  public shared ({ caller }) func reverse(original : Nat, args : Core.ReverseArgs) : async PostReply {
    switch (Core.prepareReverse(core, blocks(), caller, now(), original, args)) {
      case (#err(e)) #err(e);
      case (#ok(p)) replyFor(p, caller);
    }
  };

  /// Void every pending posting whose expiry has passed (at most `limit`, at
  /// most 100). Anyone may call: expiry is a fact of the clock, and the void is
  /// recorded as a block attributed to the canister itself.
  public shared func expirePending(limit : Nat) : async Nat {
    sweep(Nat.min(limit, 100))
  };

  func sweep(limit : Nat) : Nat {
    let expired = Core.expiredPendings(core, now(), limit);
    for (idx in expired.vals()) { ignore commit(Principal.fromActor(self), Core.expiryVoidEvent(idx)) };
    expired.size()
  };

  // ═══════════════════════════════════════════════════════
  //  CONFIGURATION (administrator); each returns the block index
  // ═══════════════════════════════════════════════════════

  type ConfigReply = Result.Result<Nat, T.ConfigError>;

  func configReply(r : Result.Result<T.Event, T.ConfigError>, caller : Principal) : ConfigReply {
    switch (r) { case (#err(e)) #err(e); case (#ok(e)) #ok(commit(caller, e).index) }
  };

  public shared ({ caller }) func registerCurrency(code : T.Currency, minorUnits : Nat8) : async ConfigReply {
    configReply(Core.prepareRegisterCurrency(core, caller, code, minorUnits), caller)
  };

  public shared ({ caller }) func openAccount(code : T.AccountCode, name : Text, normalSide : T.Side, category : T.Category, constraint : T.BalanceConstraint) : async ConfigReply {
    configReply(Core.prepareOpenAccount(core, caller, code, name, normalSide, category, constraint), caller)
  };

  public shared ({ caller }) func closeAccount(code : T.AccountCode) : async ConfigReply {
    configReply(Core.prepareCloseAccount(core, caller, code), caller)
  };

  public shared ({ caller }) func openPeriod(id : T.PeriodId, start : T.Day, end : T.Day) : async ConfigReply {
    configReply(Core.prepareOpenPeriod(core, caller, id, start, end), caller)
  };

  public shared ({ caller }) func closePeriod(id : T.PeriodId) : async ConfigReply {
    configReply(Core.prepareClosePeriod(core, caller, id), caller)
  };

  /// Activation gate. `height <= current height` activates now; ACTIVATION_OFF
  /// (2^64-1) switches financial writes off again. Recorded as a block.
  public shared ({ caller }) func setActivationHeight(height : Nat64) : async ConfigReply {
    configReply(Core.prepareSetActivationHeight(core, caller, height), caller)
  };

  public shared ({ caller }) func setLeadsheetSchema(ranges : [T.LeadsheetRange]) : async ConfigReply {
    configReply(Core.prepareSetLeadsheetSchema(core, caller, ranges), caller)
  };

  public shared ({ caller }) func addPoster(poster : Principal) : async ConfigReply {
    configReply(Core.prepareAddPoster(core, caller, poster), caller)
  };

  public shared ({ caller }) func removePoster(poster : Principal) : async ConfigReply {
    configReply(Core.prepareRemovePoster(core, caller, poster), caller)
  };

  /// Restrict a poster to a set of general-ledger accounts, or pass null to
  /// lift the restriction. Admin only; recorded as a block. Every poster is
  /// unrestricted until a scope is set.
  public shared ({ caller }) func setPosterScope(poster : Principal, accounts : ?T.PosterScope) : async ConfigReply {
    configReply(Core.prepareSetPosterScope(core, caller, poster, accounts), caller)
  };

  /// Record a numeric balance limit for one (account, sub-ledger, currency); an
  /// overdraft facility or a net debit cap; or `#none` to lift the account's
  /// constraint there. Admin only; recorded as a block.
  public shared ({ caller }) func setBalanceLimit(account : T.AccountCode, subledger : ?T.SubledgerKey, currency : T.Currency, limit : T.BalanceLimit) : async ConfigReply {
    configReply(Core.prepareSetBalanceLimit(core, caller, account, subledger, currency, limit), caller)
  };

  /// Record chart-of-accounts attributes: header or detail, the manual-entry flag
  /// and the parent of the rollup tree. Admin only; recorded as a block.
  public shared ({ caller }) func setAccountAttributes(code : T.AccountCode, attributes : T.AccountAttributes) : async ConfigReply {
    configReply(Core.prepareSetAccountAttributes(core, caller, code, attributes), caller)
  };

  public shared ({ caller }) func transferAdmin(admin : Principal) : async ConfigReply {
    configReply(Core.prepareTransferAdmin(core, caller, admin), caller)
  };

  // ═══════════════════════════════════════════════════════
  //  PERIOD-END PROCESSES
  // ═══════════════════════════════════════════════════════

  /// Roll the business date (admin). One block; never backwards; never past the clock day.
  public shared ({ caller }) func rollBusinessDate(day : T.Day) : async ConfigReply {
    configReply(Core.prepareRollBusinessDate(core, caller, now(), day), caller)
  };

  /// Set (or clear with null) the working-day calendar and value-date policy (admin).
  public shared ({ caller }) func setCalendar(calendar : ?T.CalendarConfig) : async ConfigReply {
    configReply(Core.prepareSetCalendar(core, caller, calendar), caller)
  };

  /// Post against the business date: dates default to it, the period is resolved from it.
  public shared ({ caller }) func postAtBusinessDate(input : T.BusinessPostingInput) : async PostReply {
    switch (Core.preparePostAtBusinessDate(core, caller, now(), input)) {
      case (#err(e)) #err(e);
      case (#ok(p)) replyFor(p, caller);
    }
  };

  public query func businessDate() : async ?T.Day { Core.businessDate(core) };
  public query func calendar() : async ?T.CalendarConfig { Core.calendar(core) };
  /// The accounting "today" admission uses: the business date, else the clock day.
  public query func accountingToday() : async T.Day { Core.effectiveToday(core, now()) };

  /// Plan the year-end roll without posting it.
  public query func yearEndPlan(args : YearEnd.RollArgs) : async { #ok : YearEnd.RollPlan; #err : YearEnd.RollError } {
    YearEnd.plan(core, args)
  };

  /// Post the year-end roll: one balanced posting per currency, booked in the
  /// closing period, admitted as one atomic batch by the calling poster.
  /// Idempotent for the same key prefix. Closing the periods stays explicit.
  public shared ({ caller }) func yearEndRoll(args : YearEnd.RollArgs) : async { #ok : { results : [T.PostResult]; plan : YearEnd.RollPlan }; #err : { #plan : YearEnd.RollError; #batch : T.BatchError } } {
    switch (YearEnd.plan(core, args)) {
      case (#err(e)) #err(#plan(e));
      case (#ok(plan)) {
        switch (Core.prepareBatch(core, caller, now(), plan.postings)) {
          case (#err(e)) #err(#batch(e));
          case (#ok(prepared)) {
            let results = List.empty<T.PostResult>();
            for (p in prepared.vals()) {
              switch (replyFor(p, caller)) {
                case (#ok(r)) List.add(results, r);
                case (#err(_)) Runtime.trap("yearEndRoll: admitted posting failed to commit");
              };
            };
            #ok({ results = List.toArray(results); plan })
          };
        }
      };
    }
  };

  // ── archive ──

  /// Spawn a child archive and copy blocks [localOffset, count - retainCount)
  /// into it. Admin only; the only path in this actor with `await`s, and it
  /// copies immutable bytes: writes keep appending at the tail meanwhile.
  public shared ({ caller }) func triggerArchive(retainCount : Nat, archiveCycles : Nat) : async { #ok : { canisterId : Principal; firstBlock : Nat; lastBlock : Nat }; #err : Text } {
    if (not Core.isAdmin(core, caller)) return #err("admin only");
    if (archiveInProgress) return #err("archive already in progress");
    let total = JLog.length(log);
    if (total <= localOffset + retainCount) return #err("nothing to archive");
    archiveInProgress := true;
    try {
      let archive = await (with cycles = archiveCycles) Archive.JournalArchive(Principal.fromActor(self));
      let archiveId = Principal.fromActor(archive);
      let migrateStart = localOffset;
      let migrateEnd = total - retainCount;
      await archive.init(migrateStart);
      var pos = migrateStart;
      var copied = 0;
      while (pos < migrateEnd) {
        let batchEnd = Nat.min(pos + archiveBatchSize, migrateEnd);
        let batch = JLog.rawRange(log, pos, batchEnd - pos);
        copied += await archive.appendBlocks(batch);
        pos := batchEnd;
      };
      if (copied != migrateEnd - migrateStart) { archiveInProgress := false; return #err("archive copied " # Nat.toText(copied) # " of " # Nat.toText(migrateEnd - migrateStart) # " blocks") };
      let entry : ArchiveEntry = { canisterId = archiveId; firstBlock = migrateStart; lastBlock = migrateEnd - 1 };
      archives := Array.concat(archives, [entry]);
      localOffset := migrateEnd;
      archiveInProgress := false;
      #ok({ canisterId = archiveId; firstBlock = entry.firstBlock; lastBlock = entry.lastBlock })
    } catch (e) {
      archiveInProgress := false;
      #err("archive failed: " # Error.message(e))
    }
  };

  public query func journalArchives() : async [{ canisterId : Principal; firstBlock : Nat; lastBlock : Nat }] {
    Array.map<ArchiveEntry, { canisterId : Principal; firstBlock : Nat; lastBlock : Nat }>(archives, func(a) { a })
  };
  public query func archiveStatus() : async { archives : Nat; localOffset : Nat; localBlocks : Nat; totalBlocks : Nat; inProgress : Bool } {
    { archives = archives.size(); localOffset; localBlocks = JLog.length(log) - localOffset; totalBlocks = JLog.length(log); inProgress = archiveInProgress }
  };

  // ═══════════════════════════════════════════════════════
  //  LOG AND PROOF QUERIES
  // ═══════════════════════════════════════════════════════

  public query func blockCount() : async Nat { JLog.length(log) };
  public query func tipHash() : async ?Blob { JLog.tipHash(log) };
  public query func mmrRoot() : async ?Blob { JLog.mmrRoot(log) };
  /// Blocks below the archive offset are served by the archive canisters (journalArchives).
  public query func getBlock(index : Nat) : async ?T.Block { if (index < localOffset) null else JLog.get(log, index) };
  public query func getBlocks(start : Nat, length : Nat) : async [T.Block] {
    let s = Nat.max(start, localOffset);
    if (s >= start + length) [] else JLog.getRange(log, s, Nat.min(start + length - s, 1000))
  };
  public query func getRawBlock(index : Nat) : async ?Blob { if (index < localOffset) null else JLog.rawBlock(log, index) };
  public query func proof(index : Nat) : async ?JLog.Proof { JLog.proof(log, index) };

  /// Certificate over the journal tip, including the MMR root.
  public query func tipCertificate() : async ?{ certificate : Blob; hash_tree : Blob; last_block_index : Nat; last_block_hash : Blob; mmr_root : Blob } {
    JCert.certificate(cert)
  };

  /// Full hash-chain walk; returns how many blocks were checked.
  public query func verifyChain() : async { checked : Nat; fault : ?Text } { JLog.verifyChain(log) };

  /// Local proof check (the same arithmetic an external verifier performs).
  public query func verifyProofLocally(index : Nat) : async Bool {
    switch (JLog.get(log, index), JLog.proof(log, index), JLog.mmrRoot(log)) {
      case (?b, ?p, ?root) JLog.verify(b.hash, index, p, root);
      case _ false;
    }
  };

  // ═══════════════════════════════════════════════════════
  //  ACCOUNTING QUERIES
  // ═══════════════════════════════════════════════════════

  public query func getPosting(index : Nat) : async ?T.PostingView { Core.postingView(core, blocks(), index) };
  public query func listPending() : async [T.PendingView] { Core.listPending(core, blocks()) };
  public query func trialBalance(period : T.PeriodId) : async ?T.TrialBalance { Core.trialBalance(core, period) };
  public query func trialBalanceMapped(period : T.PeriodId) : async ?T.MappedTrialBalance { Core.mappedTrialBalance(core, period) };
  public query func generalLedger(period : T.PeriodId, account : ?T.AccountCode) : async ?T.GeneralLedger { Core.generalLedger(core, blocks(), period, account) };
  public query func balance(account : T.AccountCode, subledger : ?T.SubledgerKey, currency : T.Currency) : async T.Balance { Core.balance(core, account, subledger, currency) };
  public query func accountTotal(account : T.AccountCode, currency : T.Currency) : async T.Balance { Core.accountTotal(core, account, currency) };
  public query func subledgerBalances(account : T.AccountCode) : async [T.Balance] { Core.subledgerBalances(core, account) };
  public query func allBalances() : async [T.Balance] { Core.allBalances(core) };
  public query func valueDatedBalance(account : T.AccountCode, subledger : ?T.SubledgerKey, currency : T.Currency, asOf : T.Day) : async { debits : Nat; credits : Nat } {
    Core.valueDatedBalance(core, account, subledger, currency, asOf)
  };
  /// Balance as the books stood at the end of `asOf` (by posting date).
  public query func balanceAsOf(account : T.AccountCode, subledger : ?T.SubledgerKey, currency : T.Currency, asOf : T.Day) : async { debits : Nat; credits : Nat } {
    Core.balanceAsOf(core, account, subledger, currency, asOf)
  };
  public query func listAccounts() : async [T.Account] { Core.listAccounts(core) };
  public query func listPeriods() : async [T.Period] { Core.listPeriods(core) };
  public query func listCurrencies() : async [T.CurrencyInfo] { Core.listCurrencies(core) };
  public query func listPosters() : async [Principal] { Core.listPosters(core) };
  public query func posterScope(poster : Principal) : async ?T.PosterScope { Core.posterScope(core, poster) };
  public query func listPosterScopes() : async [(Principal, T.PosterScope)] { Core.listPosterScopes(core) };
  public query func balanceLimit(account : T.AccountCode, subledger : ?T.SubledgerKey, currency : T.Currency) : async ?T.BalanceLimit {
    Core.balanceLimit(core, account, subledger, currency)
  };
  public query func accountAttributes(code : T.AccountCode) : async T.AccountAttributes { Core.accountAttributes(core, code) };
  public query func leadsheetSchema() : async [T.LeadsheetRange] { Core.leadsheetSchema(core) };
  public query func getAdmin() : async Principal { core.admin };
  public query func activationHeight() : async Nat64 { core.activationHeight };
  public query func periodPostingIndices(period : T.PeriodId) : async [Nat] { Core.periodPostingIndices(core, period) };

  /// Trial balance recomputed from scratch by replaying every block of the
  /// log into a fresh state; the "empty cache" path against which the
  /// materialised trial balance is compared.
  public query func recomputeTrialBalance(period : T.PeriodId) : async ?T.TrialBalance {
    let fresh = Core.replay(genesisAdmin, JLog.getRange(log, 0, JLog.length(log)));
    Core.trialBalance(fresh, period)
  };

  /// Fingerprint of the derived state (see JournalCore.fingerprint) and of a
  /// state replayed from the log; equal when the materialised state is exactly
  /// the fold of the log.
  public query func fingerprints() : async { live : Blob; replayed : Blob; height : Nat } {
    let fresh = Core.replay(genesisAdmin, JLog.getRange(log, 0, JLog.length(log)));
    { live = Core.fingerprint(core); replayed = Core.fingerprint(fresh); height = core.height }
  };

  public query func status() : async {
    height : Nat; posted : Nat; pending : Nat; voided : Nat; active : Bool; activationHeight : Nat64;
    accounts : Nat; periods : Nat; currencies : Nat; mmrPeaks : Nat; fingerprint : Blob;
  } {
    {
      height = core.height; posted = Core.postedCount(core); pending = Core.pendingCount(core); voided = Core.voidedCount(core);
      active = Core.isActive(core); activationHeight = core.activationHeight;
      accounts = Core.listAccounts(core).size(); periods = Core.listPeriods(core).size(); currencies = Core.listCurrencies(core).size();
      mmrPeaks = JLog.mmrPeakCount(log); fingerprint = Core.fingerprint(core);
    }
  };

  // ═══════════════════════════════════════════════════════
  //  camt.053 PROJECTION
  // ═══════════════════════════════════════════════════════

  public query func camt053Statement(period : T.PeriodId, account : T.AccountCode, subledger : ?T.SubledgerKey, currency : T.Currency) : async ?Camt.Statement {
    Camt.statement(core, blocks(), period, account, subledger, currency, hashOf)
  };

  /// camt.053 XML for a statement. Null if the period, account or currency is
  /// unknown. The message id is derived from the statement key and the
  /// journal height so that it is stable for an unchanged journal.
  public query func camt053Xml(period : T.PeriodId, account : T.AccountCode, subledger : ?T.SubledgerKey, currency : T.Currency) : async ?Text {
    let ?mu = Core.currencyMinorUnits(core, currency) else return null;
    switch (Camt.statement(core, blocks(), period, account, subledger, currency, hashOf)) {
      case null null;
      case (?s) {
        let msgId = "THEBES-" # period # "-" # account # "-" # currency # "-H" # Nat.toText(core.height);
        let day = CivilDate.fromNanos(Nat64.toNat(now()));
        ?Camt.toXml(s, mu, msgId, CivilDate.toText(day) # "T00:00:00Z")
      };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  LIFECYCLE
  // ═══════════════════════════════════════════════════════

  // The substrate clears certified data on upgrade; restore it from persisted state.
  JCert.recertify(cert);

  // Expiry sweep: pending postings past their expiry are voided, recorded, and
  // never silently dropped.
  ignore Timer.recurringTimer<system>(#seconds 60, func() : async () { ignore sweep(50) });
};
