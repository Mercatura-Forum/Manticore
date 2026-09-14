/// TokenLedger.mo: the ICRC-1/2/3/10 token ledger as a consumer of the journal.
///
/// Derived from the canonical ICRC-ME `IndexedLedger.mo` (src/ledger/, MIT; the
/// derivation is `docs/patches/tokenledger-vs-indexedledger.diff`) by embedding
/// the double-entry journal (src/journal/) behind an activation height:
///
///   journalActivation : Nat64 = 2^64-1   (off by default)
///   active  <=>  journalActivation <= current ICRC-3 block height
///
/// Below the gate every code path, every block, every hash, every certified
/// tree and every reply is the unmodified ledger's; `integration/facade_equivalence.py`
/// replays one transcript against both builds and compares the bytes. Above
/// the gate a balance movement is the consequence of a journal posting: each
/// ICRC account is a holder sub-ledger under control account 2110, the minting
/// account is the issuance account 3900, and a transfer is a balanced posting
/// (debit payer amount+fee, credit payee, credit fee collector or issuance).
/// Holders are migrated lazily; the first time an account is touched above
/// the gate its region balance becomes an opening posting; so activation is
/// one recorded act with no bulk migration. The ICRC-3 block log continues
/// unchanged as the presentation layer; each balance-moving ICRC-3 block above
/// the gate maps to exactly one journal block (a zero-value, zero-fee movement
/// gets an ICRC block only), and the certified tree carries both tips
/// (FacadeCert.mo). A two-phase transfer surface (reserve / post / void) lets
/// a settlement engine such as the DvP core escrow as a pending posting.
///
/// All state survives canister upgrades via Enhanced Orthogonal Persistence.

import Principal "mo:core/Principal";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Map "mo:core/Map";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import Cycles "mo:core/Cycles";
import Error "mo:core/Error";

import Array "mo:core/Array";

import Sha256 "mo:sha2/Sha256";

import T "../ledger/Types";
import Bal "../ledger/RegionBalances";
import Allow "../ledger/Allowances";
import BLog "../ledger/BlockLog";
import Cert "../ledger/CertifiedTree";
import Bloom "../ledger/BloomFilter";
import Archive "../ledger/Archive";

import Core "../journal/JournalCore";
import JT "../journal/JournalTypes";
import JLog "../journal/JournalLog";
import JCert "../journal/JournalCert";
import CivilDate "../journal/CivilDate";
import FCert "FacadeCert";
import Result "mo:core/Result";
import Text "mo:core/Text";

shared(initMsg) persistent actor class TokenLedger(args : T.InitArgs) = self {

  // ═══════════════════════════════════════════════════════
  //  CORE STATE; stable records (survive upgrades)
  // ═══════════════════════════════════════════════════════

  let maxSupply = switch (args.max_supply) { case (?m) m; case null Bal.DEFAULT_MAX_SUPPLY };
  var balState : Bal.State = Bal.newState(maxSupply);
  var allowState : Allow.State = Allow.newState();
  var blockState : BLog.State = BLog.newState();
  var certState : Cert.State = Cert.newState();

  // ── Journal: the authoritative record of balance movements above the gate ──
  let journalCore : Core.State = Core.newState(initMsg.caller);
  let journalLog : JLog.State = JLog.newState();
  let journalCert : JCert.State = JCert.newState();
  var journalActivation : Nat64 = JT.ACTIVATION_OFF;     // keyed on the ICRC-3 block height
  var journalChartReady : Bool = false;
  let migratedAccounts = Map.empty<Blob, ()>();          // holder keys whose balance lives in the journal
  let icrcToJournal = Map.empty<Nat, Nat>();             // ICRC-3 block index -> journal block index
  type Reservation = {
    reserver : Principal; from : T.Account; to : T.Account; spender : ?T.Account;
    amount : Nat; fee : Nat; memo : ?Blob; allowanceUsed : Nat;
  };
  let reservations = Map.empty<Nat, Reservation>();      // journal pending index -> reservation
  /// How each resolved reservation ended: the ICRC block of its transfer, or the
  /// journal block of its void. Lets a caller whose reply was lost learn the
  /// outcome instead of guessing (a settlement engine's lost-reply retry path).
  let reservationOutcomes = Map.empty<Nat, { #posted : Nat; #voided : Nat }>();

  // Token metadata (immutable after init)
  let tokenName : Text = args.name;
  let tokenSymbol : Text = args.symbol;
  let tokenDecimals : Nat8 = args.decimals;
  let tokenFee : Nat = args.fee;
  let mintingAccount : T.Account = args.minting_account;
  let maxMemoLength : Nat = switch (args.max_memo_length) { case (?m) m; case null 256 };

  // Fee collector (optional; fees go to pool if null)
  var feeCollector : ?T.Account = null;

  // ═══════════════════════════════════════════════════════
  //  ARCHIVE REGISTRY; Offload old blocks to child canisters
  //
  //  When the main StableLog exceeds archiveBlockThreshold blocks,
  //  a new Archive canister is spawned and old blocks are migrated.
  //  icrc3_get_archives returns the registry for client discovery.
  // ═══════════════════════════════════════════════════════

  type ArchiveEntry = { canisterId : Principal; firstBlock : Nat; lastBlock : Nat };
  var archives : [ArchiveEntry] = [];
  var archiveBlockThreshold : Nat = 2_000_000;  // trigger at 2M blocks (~500MB)
  var archiveBatchSize : Nat = 500;             // blocks per inter-canister call
  var archiveInProgress : Bool = false;
  var archiveNeeded : Bool = false;              // set by appendAndCertify, consumed by timer
  var localBlockOffset : Nat = 0;               // first block index still in local StableLog

  // ═══════════════════════════════════════════════════════
  //  CIRCUIT BREAKER; Cycle Drain Protection
  //
  //  Freezes ALL writes when cycle balance drops below threshold.
  //  Reads (queries) stay alive; balances, blocks, proofs all accessible.
  //  State is fully preserved. Resume automatically when topped off.
  //
  //  Cost of this check: ~200 instructions (one Cycles.balance() call).
  //  Attacker would need to drain from current balance → threshold
  //  at ~10M cycles/call = (balance - threshold) / 10M calls to trigger.
  // ═══════════════════════════════════════════════════════

  // Admin: defaults to deployer, transferable
  var adminPrincipal : Principal = initMsg.caller;

  func isAdmin(caller : Principal) : Bool {
    Principal.equal(caller, adminPrincipal);
  };

  // 100B cycles = ~30 days of idle burn. Configurable by admin.
  var circuitBreakerThreshold : Nat = 100_000_000_000;
  var circuitBreakerTripped : Bool = false;

  func guardCycles() : Bool {
    let bal = Cycles.balance();
    if (bal < circuitBreakerThreshold) {
      circuitBreakerTripped := true;
      true
    } else {
      if (circuitBreakerTripped) { circuitBreakerTripped := false };
      false
    }
  };

  // Dedup: keyed on (caller_principal, created_at_time, amount, memo_hash) to
  // avoid false collisions between different users or different transactions.
  // Bloom filter provides O(1) fast-path; Map is exact fallback.
  var bloomState : Bloom.State = Bloom.newState(86_400_000_000_000); // 24h window
  let TX_WINDOW_NS : Nat64 = 86_400_000_000_000;
  let PERMITTED_DRIFT_NS : Nat64 = 60_000_000_000;

  /// Build a dedup key from (caller, timestamp, amount, memo).
  /// Every variable-length field is length-prefixed to prevent cross-field ambiguity.
  /// SHA256 output is the fixed-size key for Map and Bloom filter.
  func buildDedupKey(caller : Principal, ts : Nat64, amount : Nat, memo : ?Blob) : Blob {
    let digest = Sha256.Digest(#sha256);
    // Principal: length-prefixed (variable 0-29 bytes)
    let pb = Principal.toBlob(caller);
    digest.writeArray([Nat8.fromNat(pb.size())]);
    digest.writeBlob(pb);
    // Timestamp: fixed 8-byte big-endian (no length prefix needed)
    let tsN = Nat64.toNat(ts);
    digest.writeArray([
      Nat8.fromNat((tsN / 72057594037927936) % 256),
      Nat8.fromNat((tsN / 281474976710656) % 256),
      Nat8.fromNat((tsN / 1099511627776) % 256),
      Nat8.fromNat((tsN / 4294967296) % 256),
      Nat8.fromNat((tsN / 16777216) % 256),
      Nat8.fromNat((tsN / 65536) % 256),
      Nat8.fromNat((tsN / 256) % 256),
      Nat8.fromNat(tsN % 256),
    ]);
    // Amount: length-prefixed big-endian (prevents boundary confusion with memo tag)
    if (amount == 0) { digest.writeArray([1, 0]) } else {
      var tmp = amount; var bc : Nat = 0;
      while (tmp > 0) { tmp /= 256; bc += 1 };
      digest.writeArray([Nat8.fromNat(bc)]); // byte count prefix
      let bytes = Array.tabulate<Nat8>(bc, func(i) {
        Nat8.fromNat((amount / (256 ** (bc - 1 - i))) % 256)
      });
      digest.writeArray(bytes);
    };
    // Memo: presence flag + length-prefixed content
    switch (memo) {
      case (?m) {
        digest.writeArray([0x01]);
        // Length as 2-byte big-endian (max memo = 256 bytes)
        digest.writeArray([Nat8.fromNat(m.size() / 256), Nat8.fromNat(m.size() % 256)]);
        digest.writeBlob(m);
      };
      case null { digest.writeArray([0x00]) };
    };
    digest.sum()
  };

  // ═══════════════════════════════════════════════════════
  //  INIT; Process initial balances (first install only)
  // ═══════════════════════════════════════════════════════

  func initBalances() {
    for ((account, amount) in args.initial_balances.vals()) {
      Bal.setBalance(balState, account, amount);
      Bal.reducePool(balState, amount);
      ignore BLog.append(blockState, {
        kind = "mint"; from = null; to = ?account; spender = null;
        amount; fee = null; memo = null;
        timestamp = Nat64.fromNat(Int.abs(Time.now())); index = BLog.length(blockState);
      }, null);
    };
    switch (BLog.tipHash(blockState)) {
      case (?hash) Cert.updateTip(certState, BLog.length(blockState) - 1, hash);
      case null {};
    };
  };

  // ═══════════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════════

  func isMintingAccount(account : T.Account) : Bool {
    T.accountsEqual(account, mintingAccount)
  };

  func now() : Nat64 { Nat64.fromNat(Int.abs(Time.now())) };

  // Dedup entries store (dedupKey -> (blockIndex, timestamp)) so we can prune by age.
  type DedupEntry = { blockIndex : Nat; timestamp : Nat64 };
  var recentTxEntries = Map.empty<Blob, DedupEntry>();
  var dedupMapSize : Nat = 0;
  let DEDUP_MAP_CAP : Nat = 500_000; // hard ceiling; emergency eviction if exceeded

  // Adaptive pruning: scales with map size. Emergency eviction at hard cap.
  var dedupPruneCounter : Nat = 0;
  func pruneDedupMap() {
    dedupPruneCounter += 1;
    // Normal pruning every 5th call; emergency every call if at cap
    let emergency = dedupMapSize >= DEDUP_MAP_CAP;
    if (not emergency and dedupPruneCounter % 5 != 0) return;
    let n = now();
    let cutoff = if (emergency) {
      // Emergency: aggressively evict anything older than half the window
      n - TX_WINDOW_NS / 2
    } else {
      n - TX_WINDOW_NS - PERMITTED_DRIFT_NS - 60_000_000_000
    };
    let batchSize = if (emergency) 2000 else Nat.min(500, Nat.max(20, dedupMapSize / 100));
    let toDelete = List.empty<Blob>();
    var count : Nat = 0;
    for ((key, entry) in Map.entries(recentTxEntries)) {
      if (count >= batchSize) return;
      if (entry.timestamp < cutoff) {
        List.add(toDelete, key);
        count += 1;
      };
    };
    for (key in List.values(toDelete)) {
      ignore Map.delete(recentTxEntries, Blob.compare, key);
      dedupMapSize -= 1;
    };
  };

  /// The deduplication check: the window and the drift first, then the key against what the ledger has RECORDED.
  /// Nothing is written here; a transfer refused after this check (allowance, funds, supply, the journal's gate)
  /// must leave no trace, or its own retry with the same `created_at_time` would be answered `#Duplicate` pointing
  /// at a block that never held it (ICRC-1: the ledger must not deduplicate a transfer that was rejected). The key
  /// comes back with `#ok` and is recorded by `recordDedup` once the block is appended, with that block's index.
  func checkDedupAndTime(caller : Principal, created_at_time : ?Nat64, amount : Nat, memo : ?Blob) : { #ok : ?(Blob, Nat64); #TooOld; #InFuture : Nat64; #Duplicate : Nat } {
    pruneDedupMap();
    switch (created_at_time) {
      case null #ok(null);
      case (?ts) {
        let n = now();
        if (ts + TX_WINDOW_NS + PERMITTED_DRIFT_NS < n) return #TooOld;
        if (ts > n + PERMITTED_DRIFT_NS) return #InFuture(n);
        let dedupKey = buildDedupKey(caller, ts, amount, memo);
        if (not Bloom.mightContain(bloomState, ts, n)) return #ok(?(dedupKey, ts));
        switch (Map.get(recentTxEntries, Blob.compare, dedupKey)) {
          case (?entry) #Duplicate(entry.blockIndex);
          case null #ok(?(dedupKey, ts));
        };
      };
    };
  };
  /// Record the key of a transfer the ledger has just appended, against the block that holds it.
  func recordDedup(dedup : ?(Blob, Nat64), blockIndex : Nat) {
    switch (dedup) {
      case null {};
      case (?(dedupKey, ts)) {
        Bloom.add(bloomState, ts, now());
        Map.add(recentTxEntries, Blob.compare, dedupKey, { blockIndex; timestamp = ts });
        dedupMapSize += 1;
      };
    };
  };

  func validateMemo(memo : ?Blob) : ?Text {
    switch (memo) {
      case (?m) { if (m.size() > maxMemoLength) ?("Memo too long: " # Nat.toText(m.size()) # " > " # Nat.toText(maxMemoLength)) else null };
      case null null;
    };
  };

  func validateSubaccount(sub : ?Blob) : ?Text {
    switch (sub) {
      case (?s) { if (s.size() != 32) ?("Subaccount must be 32 bytes, got " # Nat.toText(s.size())) else null };
      case null null;
    };
  };

  func makeTx(kind : Text, from : ?T.Account, to : ?T.Account, spender : ?T.Account, amount : Nat, fee : ?Nat, memo : ?Blob) : T.Transaction {
    { kind; from; to; spender; amount; fee; memo; timestamp = now(); index = BLog.length(blockState) }
  };

  /// Append block + update certified data atomically.
  /// Checks archive threshold and schedules auto-archive if exceeded.
  func appendAndCertify(tx : T.Transaction, effectiveFee : ?Nat) : Nat {
    let idx = BLog.append(blockState, tx, effectiveFee);
    switch (BLog.tipHash(blockState)) {
      case (?hash) certifyTip(idx, hash);
      case null {};
    };
    // Auto-archive flag: checked by the maintenance timer
    let localCount = BLog.length(blockState) - localBlockOffset;
    if (localCount > archiveBlockThreshold and not archiveInProgress) {
      archiveNeeded := true;
    };
    idx
  };


  // ═══════════════════════════════════════════════════════
  //  JOURNAL FACADE; helpers (no `await` anywhere in this block)
  // ═══════════════════════════════════════════════════════

  let HOLDERS : Text = "2110";     // control account: holder balances (liability, credit, no overdraft)
  let ISSUANCE : Text = "3900";    // issuance / burn counter-account (equity, credit)

  func journalActive() : Bool { journalActivation <= Nat64.fromNat(BLog.length(blockState)) };
  func selfPrincipal() : Principal { Principal.fromActor(self) };
  func holderKey(a : T.Account) : Blob { T.accountKeyToBlob(T.accountKey(a)) };
  func isMigrated(a : T.Account) : Bool { Map.containsKey(migratedAccounts, Blob.compare, holderKey(a)) };
  func today() : Nat { CivilDate.fromNanos(Nat64.toNat(now())) };

  /// Append one journal event and apply it; certification follows separately.
  /// The journal's record reader over this ledger's own log: the core reads posting records from the
  /// blocks rather than keeping a copy.
  func journalBlocks() : Core.Blocks { { get = func(i : Nat) : ?JT.Block { JLog.get(journalLog, i) } } };

  func commitJournal(caller : Principal, event : JT.Event) : JT.Block {
    let b = JLog.append(journalLog, now(), caller, event);
    Core.apply(journalCore, journalBlocks(), b);
    b
  };

  func journalConfig(r : Result.Result<JT.Event, JT.ConfigError>) : Result.Result<Nat, Text> {
    switch (r) {
      case (#ok(e)) #ok(commitJournal(journalCore.admin, e).index);
      case (#err(e)) #err("journal configuration refused: " # debug_show(e));
    }
  };

  /// Register the token's currency, the two control accounts and the facade as
  /// poster; activate the journal's own gate (the facade's gate governs).
  /// Idempotent. Runs when the activation height is first set.
  func initJournalChart() : Result.Result<(), Text> {
    if (journalChartReady) return #ok(());
    switch (Core.validateCurrencyCode(tokenSymbol)) {
      case (?reason) return #err("token symbol is not a journal currency code: " # reason);
      case null {};
    };
    if (tokenDecimals > 18) return #err("token decimals exceed the journal's 18");
    let admin = journalCore.admin;
    switch (journalConfig(Core.prepareRegisterCurrency(journalCore, admin, tokenSymbol, tokenDecimals))) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (journalConfig(Core.prepareOpenAccount(journalCore, admin, HOLDERS, "Token holders (" # tokenSymbol # ")", #credit, #liability, #debitsNotExceedCredits))) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (journalConfig(Core.prepareOpenAccount(journalCore, admin, ISSUANCE, "Issuance (" # tokenSymbol # ")", #credit, #equity, #none))) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (journalConfig(Core.prepareAddPoster(journalCore, admin, selfPrincipal()))) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    switch (journalConfig(Core.prepareSetActivationHeight(journalCore, admin, 0))) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    journalChartReady := true;
    #ok(())
  };

  /// The journal period for a day: one calendar month, opened on demand.
  func ensurePeriod(day : Nat) : Result.Result<Text, Text> {
    let (y, m, _) = CivilDate.toCivil(day);
    let id = Nat.toText(y) # "-" # (if (m < 10) "0" else "") # Nat.toText(m);
    switch (Core.getPeriod(journalCore, id)) {
      case (?_) #ok(id);
      case null {
        let ?start = CivilDate.fromCivil(y, m, 1) else return #err("invalid period start");
        let ?end = CivilDate.fromCivil(y, m, CivilDate.daysInMonth(y, m)) else return #err("invalid period end");
        switch (journalConfig(Core.prepareOpenPeriod(journalCore, journalCore.admin, id, start, end))) {
          case (#ok(_)) #ok(id);
          case (#err(e)) #err(e);
        }
      };
    }
  };

  func holderLeg(a : T.Account, side : JT.Side, amount : Nat) : JT.Leg {
    { account = HOLDERS; subledger = ?holderKey(a); side; currency = tokenSymbol; amount }
  };
  func issuanceLeg(side : JT.Side, amount : Nat) : JT.Leg {
    { account = ISSUANCE; subledger = null; side; currency = tokenSymbol; amount }
  };
  /// Fee destination: the fee collector's holder sub-ledger, or issuance (the
  /// unmodified ledger returns collector-less fees to the token pool).
  func feeLeg(fee : Nat) : JT.Leg {
    switch (feeCollector) { case (?fc) holderLeg(fc, #credit, fee); case null issuanceLeg(#credit, fee) }
  };
  /// Legs of a transfer, omitting zero-amount legs (the journal refuses them;
  /// a zero-value ICRC transfer moves nothing and gets an ICRC block only).
  func transferLegs(from : T.Account, to : T.Account, amount : Nat, fee : Nat) : [JT.Leg] {
    let out = List.empty<JT.Leg>();
    if (amount + fee > 0) List.add(out, holderLeg(from, #debit, amount + fee));
    if (amount > 0) List.add(out, holderLeg(to, #credit, amount));
    if (fee > 0) List.add(out, feeLeg(fee));
    List.toArray(out)
  };

  /// The unmodified ledger registers a dedup key when it checks a call, before any
  /// balance check, so a refused call poisons its key for the window and a retry
  /// with the same created_at_time answers #Duplicate of a phantom index. Above
  /// the gate a refusal forgets the key, so dedup covers recorded movements only
  /// (the ICRC-1 meaning of a duplicate). Below the gate nothing changes.

  func idemKey(caller : Principal, created_at_time : ?Nat64, amount : Nat, memo : ?Blob) : Blob {
    switch (created_at_time) {
      case (?ts) buildDedupKey(caller, ts, amount, memo);
      // unique per journal event: the journal height moves on every posting,
      // reservation and void (the ICRC height does not move on a void)
      case null Text.encodeUtf8("journal-block-" # Nat.toText(JLog.length(journalLog)));
    }
  };

  /// Move an account's region balance into the journal the first time it is
  /// touched above the gate. The opening posting is recorded with kind
  /// "migration"; the region balance is then zero and the journal is authoritative.
  func ensureMigrated(a : T.Account) : Result.Result<(), JT.PostError> {
    if (isMigrated(a)) return #ok(());
    let key = holderKey(a);
    let bal = Bal.getBalance(balState, a);
    if (bal > 0) {
      let legs = [issuanceLeg(#debit, bal), holderLeg(a, #credit, bal)];
      // idempotency key: the 62-byte holder key itself (unique per holder; no
      // ICRC posting uses a 62-byte key, so the scopes cannot collide)
      // source id: the owner principal (the full holder key is the leg's sub-ledger key)
      switch (journalPost(legs, "migration", Principal.toText(a.owner), key)) {
        case (#err(e)) return #err(e);
        case (#ok(_)) {};
      };
      Bal.setBalance(balState, a, 0);
    };
    Map.add(migratedAccounts, Blob.compare, key, ());
    #ok(())
  };

  func hexOf(b : Blob) : Text {
    let d = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"];
    var out = "";
    for (x in b.vals()) { let n = Nat8.toNat(x); out #= d[n / 16] # d[n % 16] };
    out
  };

  /// Admit and commit an immediate journal posting. Returns the journal block
  /// index, or null when there are no legs (a zero-value, zero-fee movement).
  /// A journal duplicate is a refusal: the ICRC dedup window runs first, so a
  /// duplicate here means an ICRC block would be appended for a posting that
  /// moved nothing in the authoritative record; that is never allowed to succeed.
  func journalPost(legs : [JT.Leg], kind : Text, id : Text, key : Blob) : Result.Result<?Nat, JT.PostError> {
    if (legs.size() == 0) return #ok(null);
    let day = today();
    let period = switch (ensurePeriod(day)) { case (#ok(p)) p; case (#err(e)) return #err(#SourceRefInvalid({ reason = e })) };
    let input : JT.PostingInput = {
      idempotencyKey = key; postingDate = day; valueDate = day; period; legs;
      sourceRef = { kind; id }; narration = ""; correctionOf = null;
    };
    switch (Core.preparePost(journalCore, selfPrincipal(), now(), input)) {
      case (#err(e)) #err(e);
      case (#ok(#duplicate(i))) #err(#IdempotencyKeyReused({ existing = i }));
      case (#ok(#event(e))) #ok(?commitJournal(selfPrincipal(), e).index);
    }
  };

  /// Available balance of a migrated holder: credits - debits - pending debits.
  func journalAvailable(a : T.Account) : Nat {
    let b = Core.balance(journalCore, HOLDERS, ?holderKey(a), tokenSymbol);
    let owed = b.debitsPosted + b.debitsPending;
    if (b.creditsPosted > owed) b.creditsPosted - owed else 0
  };

  /// The balance an ICRC-1 caller sees: the journal once the holder has
  /// migrated (a permanent fact, independent of the gate), the region before.
  /// Below the gate no holder is migrated, so this is the unmodified read.
  func holderBalance(a : T.Account) : Nat {
    if (isMigrated(a)) journalAvailable(a) else Bal.getBalance(balState, a)
  };

  func insufficient(a : T.Account) : T.TransferError { #InsufficientFunds({ balance = holderBalance(a) }) };
  func mapPostError(e : JT.PostError, from : T.Account) : T.TransferError {
    switch (e) {
      case (#ExceedsCredits(_)) insufficient(from);
      case (#IdempotencyKeyReused(x)) #GenericError({ error_code = 909; message = "journal already holds this posting (journal block " # Nat.toText(x.existing) # "); no ICRC block appended" });
      case (other) #GenericError({ error_code = 900; message = "journal refused the posting: " # debug_show(other) });
    }
  };

  /// Certify the current tips: the ICRC tree alone below the gate (byte-identical
  /// to the unmodified ledger), the combined tree above it.
  func certifyTip(idx : Nat, hash : Blob) {
    if (journalActive() and JLog.length(journalLog) > 0) {
      certState.lastBlockIndex := idx;
      certState.lastBlockHash := hash;
      let jIdx = JLog.length(journalLog) - 1;
      let jHash = switch (JLog.tipHash(journalLog)) { case (?h) h; case null "" : Blob };
      let root = switch (JLog.mmrRoot(journalLog)) { case (?r) r; case null "" : Blob };
      journalCert.lastBlockIndex := jIdx; journalCert.lastBlockHash := jHash; journalCert.mmrRoot := root; journalCert.committed := true;
      FCert.setCombined(idx, hash, jIdx, jHash, root);
    } else {
      Cert.updateTip(certState, idx, hash);
    };
  };
  /// Re-certify after a journal-only event (reservation, void, configuration).
  func certifyCurrent() {
    switch (BLog.tipHash(blockState)) {
      case (?hash) certifyTip(BLog.length(blockState) - 1, hash);
      case null {};
    };
  };

  /// A transfer above the gate: burn, mint or regular, as one balanced posting
  /// followed by the ICRC-3 block. Validation and dedup happened in the caller.
  func journalTransfer(caller : Principal, from : T.Account, to : T.Account, spender : ?T.Account, amount : Nat, fee : Nat, memo : ?Blob, created_at_time : ?Nat64, dedup : ?(Blob, Nat64)) : { #Ok : Nat; #Err : T.TransferError } {
    let key = idemKey(caller, created_at_time, amount, memo);
    if (isMintingAccount(to)) {
      if (amount == 0) return #Err(#BadBurn({ min_burn_amount = 1 }));
      switch (ensureMigrated(from)) { case (#err(e)) { return #Err(mapPostError(e, from)) }; case (#ok(_)) {} };
      let legs = [holderLeg(from, #debit, amount + fee), issuanceLeg(#credit, amount + fee)];
      switch (journalPost(legs, "1burn", "icrc:" # Nat.toText(BLog.length(blockState)), key)) {
        case (#err(e)) { return #Err(mapPostError(e, from)) };
        case (#ok(j)) {
          balState.tokenPool += amount + fee;
          let tx = makeTx("burn", ?from, null, spender, amount, ?fee, memo);
          let idx = appendAndCertify(tx, ?fee);
          recordDedup(dedup, idx);
          switch (j) { case (?ji) Map.add(icrcToJournal, Nat.compare, idx, ji); case null {} };
          return #Ok(idx);
        };
      };
    };
    if (isMintingAccount(from)) {
      if (amount > balState.tokenPool) { return #Err(#GenericError({ error_code = 1; message = "Mint exceeds supply" })) };
      switch (ensureMigrated(to)) { case (#err(e)) { return #Err(mapPostError(e, to)) }; case (#ok(_)) {} };
      let legs = if (amount == 0) [] else [issuanceLeg(#debit, amount), holderLeg(to, #credit, amount)];
      switch (journalPost(legs, "1mint", "icrc:" # Nat.toText(BLog.length(blockState)), key)) {
        case (#err(e)) { return #Err(mapPostError(e, to)) };
        case (#ok(j)) {
          Bal.reducePool(balState, amount);
          let tx = makeTx("mint", null, ?to, spender, amount, null, memo);
          let idx = appendAndCertify(tx, null);
          recordDedup(dedup, idx);
          switch (j) { case (?ji) Map.add(icrcToJournal, Nat.compare, idx, ji); case null {} };
          return #Ok(idx);
        };
      };
    };
    switch (ensureMigrated(from)) { case (#err(e)) { return #Err(mapPostError(e, from)) }; case (#ok(_)) {} };
    switch (ensureMigrated(to)) { case (#err(e)) { return #Err(mapPostError(e, to)) }; case (#ok(_)) {} };
    switch (feeCollector) { case (?fc) { switch (ensureMigrated(fc)) { case (#err(e)) { return #Err(mapPostError(e, fc)) }; case (#ok(_)) {} } }; case null {} };
    switch (journalPost(transferLegs(from, to, amount, fee), if (spender == null) "1xfer" else "2xfer", "icrc:" # Nat.toText(BLog.length(blockState)), key)) {
      case (#err(e)) { #Err(mapPostError(e, from)) };
      case (#ok(j)) {
        if (fee > 0 and feeCollector == null) balState.tokenPool += fee;
        let tx = makeTx("transfer", ?from, ?to, spender, amount, ?fee, memo);
        let idx = appendAndCertify(tx, ?fee);
        recordDedup(dedup, idx);
        switch (j) { case (?ji) Map.add(icrcToJournal, Nat.compare, idx, ji); case null {} };
        #Ok(idx)
      };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  ICRC-1: TRANSFER
  // ═══════════════════════════════════════════════════════

  public shared ({ caller }) func icrc1_transfer(transferArgs : T.TransferArgs) : async { #Ok : Nat; #Err : T.TransferError } {
    if (guardCycles()) return #Err(#TemporarilyUnavailable);
    switch (validateSubaccount(transferArgs.from_subaccount)) {
      case (?e) return #Err(#GenericError({ error_code = 100; message = e })); case null {};
    };
    switch (validateSubaccount(transferArgs.to.subaccount)) {
      case (?e) return #Err(#GenericError({ error_code = 100; message = e })); case null {};
    };

    let from : T.Account = { owner = caller; subaccount = transferArgs.from_subaccount };
    let to = transferArgs.to;
    let amount = transferArgs.amount;

    // Minting account: fee must be 0. Burns (to minting): fee must be 0. Regular: fee must be tokenFee.
    let isMint = isMintingAccount(from);
    let isBurn = isMintingAccount(to);
    let expectedFee : Nat = if (isMint or isBurn) 0 else tokenFee;
    let fee = switch (transferArgs.fee) {
      case (?f) { if (f != expectedFee) return #Err(#BadFee({ expected_fee = expectedFee })); f };
      case null expectedFee;
    };

    switch (validateMemo(transferArgs.memo)) {
      case (?e) return #Err(#GenericError({ error_code = 101; message = e })); case null {};
    };

    let dedup = switch (checkDedupAndTime(caller, transferArgs.created_at_time, amount, transferArgs.memo)) {
      case (#TooOld) return #Err(#TooOld);
      case (#InFuture(t)) return #Err(#CreatedInFuture({ ledger_time = t }));
      case (#Duplicate(idx)) return #Err(#Duplicate({ duplicate_of = idx }));
      case (#ok(d)) d;
    };

    if (journalActive()) return journalTransfer(caller, from, to, null, amount, fee, transferArgs.memo, transferArgs.created_at_time, dedup);

    // Burn; enforce min_burn_amount
    if (isMintingAccount(to)) {
      if (amount == 0) return #Err(#BadBurn({ min_burn_amount = 1 }));
      switch (Bal.burn(balState, from, amount + fee)) {
        case (#err(#InsufficientFunds({ balance }))) return #Err(#InsufficientFunds({ balance }));
        case (#ok(())) {};
      };
      let tx = makeTx("burn", ?from, null, null, amount, ?fee, transferArgs.memo);
      let idx = appendAndCertify(tx, ?fee);
      recordDedup(dedup, idx);
      return #Ok(idx);
    };

    // Mint
    if (isMintingAccount(from)) {
      switch (Bal.mint(balState, to, amount)) {
        case (#err(_)) return #Err(#GenericError({ error_code = 1; message = "Mint exceeds supply" }));
        case (#ok(())) {};
      };
      let tx = makeTx("mint", null, ?to, null, amount, null, transferArgs.memo);
      let idx = appendAndCertify(tx, null);
      recordDedup(dedup, idx);
      return #Ok(idx);
    };

    // Regular transfer
    switch (Bal.transfer(balState, from, to, amount, fee, feeCollector)) {
      case (#err(#InsufficientFunds({ balance }))) return #Err(#InsufficientFunds({ balance }));
      case (#ok(())) {};
    };
    let tx = makeTx("transfer", ?from, ?to, null, amount, ?fee, transferArgs.memo);
    let idx = appendAndCertify(tx, ?fee);
    recordDedup(dedup, idx);
    #Ok(idx)
  };

  // ═══════════════════════════════════════════════════════
  //  ICRC-2: APPROVE
  // ═══════════════════════════════════════════════════════

  public shared ({ caller }) func icrc2_approve(approveArgs : T.ApproveArgs) : async { #Ok : Nat; #Err : T.ApproveError } {
    if (guardCycles()) return #Err(#TemporarilyUnavailable);
    switch (validateSubaccount(approveArgs.from_subaccount)) {
      case (?e) return #Err(#GenericError({ error_code = 100; message = e })); case null {};
    };
    switch (validateSubaccount(approveArgs.spender.subaccount)) {
      case (?e) return #Err(#GenericError({ error_code = 100; message = e })); case null {};
    };

    let from : T.Account = { owner = caller; subaccount = approveArgs.from_subaccount };
    let spender = approveArgs.spender;

    // Minting account cannot approve (would delegate mint authority)
    if (isMintingAccount(from)) {
      return #Err(#GenericError({ error_code = 1; message = "the minting account cannot delegate mints" }));
    };

    // Cannot approve to self
    if (T.accountsEqual(from, spender)) {
      return #Err(#GenericError({ error_code = 2; message = "self-approval not allowed" }));
    };

    let fee = switch (approveArgs.fee) {
      case (?f) { if (f != tokenFee) return #Err(#BadFee({ expected_fee = tokenFee })); f };
      case null tokenFee;
    };

    switch (validateMemo(approveArgs.memo)) {
      case (?e) return #Err(#GenericError({ error_code = 101; message = e })); case null {};
    };

    let dedup = switch (checkDedupAndTime(caller, approveArgs.created_at_time, approveArgs.amount, approveArgs.memo)) {
      case (#TooOld) return #Err(#TooOld);
      case (#InFuture(t)) return #Err(#CreatedInFuture({ ledger_time = t }));
      case (#Duplicate(idx)) return #Err(#Duplicate({ duplicate_of = idx }));
      case (#ok(d)) d;
    };

    if (journalActive()) {
      // Above the gate: set the allowance, then post the fee; restore the
      // allowance if the fee cannot be paid. Same outcome, same block, as below.
      switch (ensureMigrated(from)) { case (#err(e)) return #Err(#InsufficientFunds({ balance = holderBalance(from) })); case (#ok(_)) {} };
      switch (feeCollector) { case (?fc) { switch (ensureMigrated(fc)) { case (#err(_)) return #Err(#InsufficientFunds({ balance = holderBalance(from) })); case (#ok(_)) {} } }; case null {} };
      let saved = Allow.getAllowance(allowState, from, spender);
      switch (Allow.approve(allowState, from, spender, approveArgs.amount, approveArgs.expires_at, approveArgs.expected_allowance)) {
        case (#err(#AllowanceChanged(a))) return #Err(#AllowanceChanged(a));
        case (#err(#Expired(e))) return #Err(#Expired(e));
        case (#err(#InsufficientFunds(f))) return #Err(#InsufficientFunds(f));
        case (#ok(())) {};
      };
      let feeLegs = if (fee == 0) [] else [holderLeg(from, #debit, fee), feeLeg(fee)];
      switch (journalPost(feeLegs, "2approve", "icrc:" # Nat.toText(BLog.length(blockState)), idemKey(caller, approveArgs.created_at_time, approveArgs.amount, approveArgs.memo))) {
        case (#err(_)) {
          ignore Allow.approve(allowState, from, spender, saved.allowance, saved.expires_at, null);
          return #Err(#InsufficientFunds({ balance = holderBalance(from) }));
        };
        case (#ok(j)) {
          if (fee > 0 and feeCollector == null) balState.tokenPool += fee;
          let tx = makeTx("approve", ?from, null, ?spender, approveArgs.amount, ?fee, approveArgs.memo);
          let idx = appendAndCertify(tx, ?fee);
          recordDedup(dedup, idx);
          switch (j) { case (?ji) Map.add(icrcToJournal, Nat.compare, idx, ji); case null {} };
          return #Ok(idx);
        };
      };
    };

    // Deduct fee FIRST (atomic: if approve fails, restore fee)
    switch (Bal.debit(balState, from, fee)) {
      case (#err(_)) return #Err(#InsufficientFunds({ balance = Bal.getBalance(balState, from) }));
      case (#ok(_)) {};
    };

    // Set allowance (restore fee on failure)
    switch (Allow.approve(allowState, from, spender, approveArgs.amount, approveArgs.expires_at, approveArgs.expected_allowance)) {
      case (#err(#AllowanceChanged(a))) {
        Bal.credit(balState, from, fee);
        return #Err(#AllowanceChanged(a));
      };
      case (#err(#Expired(e))) {
        Bal.credit(balState, from, fee);
        return #Err(#Expired(e));
      };
      case (#err(#InsufficientFunds(f))) {
        Bal.credit(balState, from, fee);
        return #Err(#InsufficientFunds(f));
      };
      case (#ok(())) {};
    };

    let tx = makeTx("approve", ?from, null, ?spender, approveArgs.amount, ?fee, approveArgs.memo);
    let idx = appendAndCertify(tx, ?fee);
    recordDedup(dedup, idx);
    #Ok(idx)
  };

  // ═══════════════════════════════════════════════════════
  //  ICRC-2: TRANSFER_FROM
  // ═══════════════════════════════════════════════════════

  public shared ({ caller }) func icrc2_transfer_from(tfArgs : T.TransferFromArgs) : async { #Ok : Nat; #Err : T.TransferFromError } {
    if (guardCycles()) return #Err(#TemporarilyUnavailable);
    switch (validateSubaccount(tfArgs.spender_subaccount)) {
      case (?e) return #Err(#GenericError({ error_code = 100; message = e })); case null {};
    };
    switch (validateSubaccount(tfArgs.from.subaccount)) {
      case (?e) return #Err(#GenericError({ error_code = 100; message = e })); case null {};
    };
    switch (validateSubaccount(tfArgs.to.subaccount)) {
      case (?e) return #Err(#GenericError({ error_code = 100; message = e })); case null {};
    };

    let spender : T.Account = { owner = caller; subaccount = tfArgs.spender_subaccount };
    let from = tfArgs.from;
    let to = tfArgs.to;
    let amount = tfArgs.amount;

    // Burns and mints have fee = 0; regular transfers use tokenFee
    let isBurnTf = isMintingAccount(to);
    let isMintTf = isMintingAccount(from);
    let expectedFeeTf : Nat = if (isBurnTf or isMintTf) 0 else tokenFee;
    let fee = switch (tfArgs.fee) {
      case (?f) { if (f != expectedFeeTf) return #Err(#BadFee({ expected_fee = expectedFeeTf })); f };
      case null expectedFeeTf;
    };

    switch (validateMemo(tfArgs.memo)) {
      case (?e) return #Err(#GenericError({ error_code = 101; message = e })); case null {};
    };

    let dedup = switch (checkDedupAndTime(caller, tfArgs.created_at_time, amount, tfArgs.memo)) {
      case (#TooOld) return #Err(#TooOld);
      case (#InFuture(t)) return #Err(#CreatedInFuture({ ledger_time = t }));
      case (#Duplicate(idx)) return #Err(#Duplicate({ duplicate_of = idx }));
      case (#ok(d)) d;
    };

    // Check + use allowance (skip if self-transfer)
    let needsAllowance = not T.accountsEqual(from, spender);
    // Save allowance BEFORE decrement so we can restore exactly on failure
    let savedAllowance = if (needsAllowance) {
      ?Allow.getAllowance(allowState, from, spender)
    } else { null };

    if (needsAllowance) {
      switch (Allow.useAllowance(allowState, from, spender, amount + fee)) {
        case (#err(#InsufficientAllowance(a))) return #Err(#InsufficientAllowance(a));
        case (#ok(())) {};
      };
    };

    if (journalActive()) {
      // Above the gate: the same three cases as below, as one posting; the
      // allowance is restored exactly when the posting is refused.
      let r = journalTransfer(caller, from, to, ?spender, amount, fee, tfArgs.memo, tfArgs.created_at_time, dedup);
      switch (r) {
        case (#Ok(idx)) return #Ok(idx);
        case (#Err(e)) {
          switch (savedAllowance) {
            case (?saved) { ignore Allow.approve(allowState, from, spender, saved.allowance, saved.expires_at, null) };
            case null {};
          };
          return #Err(switch (e) {
            case (#InsufficientFunds(x)) #InsufficientFunds(x);
            case (#BadBurn(x)) #GenericError({ error_code = 3; message = "BadBurn: min_burn_amount is 1" });
            case (#GenericError(x)) #GenericError(x);
            case (#BadFee(x)) #BadFee(x);
            case (#TooOld) #TooOld;
            case (#CreatedInFuture(x)) #CreatedInFuture(x);
            case (#Duplicate(x)) #Duplicate(x);
            case (#TemporarilyUnavailable) #TemporarilyUnavailable;
          });
        };
      };
    };

    // Handle burn (to == minting), mint (from == minting), or regular transfer
    let isBurn = isMintingAccount(to);
    let isMint = isMintingAccount(from);

    if (isBurn) {
      // BadBurn check: amount must be > 0 (same as icrc1_transfer burn path)
      if (amount == 0) {
        switch (savedAllowance) {
          case (?saved) { ignore Allow.approve(allowState, from, spender, saved.allowance, saved.expires_at, null) };
          case null {};
        };
        return #Err(#GenericError({ error_code = 3; message = "BadBurn: min_burn_amount is 1" }));
      };
      switch (Bal.burn(balState, from, amount)) {
        case (#err(#InsufficientFunds({ balance }))) {
          switch (savedAllowance) {
            case (?saved) { ignore Allow.approve(allowState, from, spender, saved.allowance, saved.expires_at, null) };
            case null {};
          };
          return #Err(#InsufficientFunds({ balance }));
        };
        case (#ok(())) {};
      };
      let tx = makeTx("burn", ?from, null, ?spender, amount, null, tfArgs.memo);
      let idx = appendAndCertify(tx, null);
      recordDedup(dedup, idx);
      return #Ok(idx);
    };

    if (isMint) {
      switch (Bal.mint(balState, to, amount)) {
        case (#err(_)) {
          // Restore allowance on mint failure (same pattern as burn + transfer paths)
          switch (savedAllowance) {
            case (?saved) { ignore Allow.approve(allowState, from, spender, saved.allowance, saved.expires_at, null) };
            case null {};
          };
          return #Err(#GenericError({ error_code = 1; message = "Mint exceeds supply" }));
        };
        case (#ok(())) {};
      };
      let tx = makeTx("mint", null, ?to, ?spender, amount, null, tfArgs.memo);
      let idx = appendAndCertify(tx, null);
      recordDedup(dedup, idx);
      return #Ok(idx);
    };

    // Regular transfer
    switch (Bal.transfer(balState, from, to, amount, fee, feeCollector)) {
      case (#err(#InsufficientFunds({ balance }))) {
        switch (savedAllowance) {
          case (?saved) { ignore Allow.approve(allowState, from, spender, saved.allowance, saved.expires_at, null) };
          case null {};
        };
        return #Err(#InsufficientFunds({ balance }));
      };
      case (#ok(())) {};
    };

    let tx = makeTx("transfer", ?from, ?to, ?spender, amount, ?fee, tfArgs.memo);
    let idx = appendAndCertify(tx, ?fee);
    recordDedup(dedup, idx);
    #Ok(idx)
  };

  // ═══════════════════════════════════════════════════════
  //  ICRC-1 QUERIES
  // ═══════════════════════════════════════════════════════

  public query func icrc1_name() : async Text { tokenName };
  public query func icrc1_symbol() : async Text { tokenSymbol };
  public query func icrc1_decimals() : async Nat8 { tokenDecimals };
  public query func icrc1_fee() : async Nat { tokenFee };
  public query func icrc1_total_supply() : async Nat { Bal.totalSupply(balState) };
  public query func icrc1_minting_account() : async ?T.Account { ?mintingAccount };

  public query func icrc1_balance_of(account : T.Account) : async Nat {
    holderBalance(account)
  };

  public query func icrc1_metadata() : async [(Text, T.Value)] {
    [
      ("icrc1:name", #Text(tokenName)),
      ("icrc1:symbol", #Text(tokenSymbol)),
      ("icrc1:decimals", #Nat(Nat8.toNat(tokenDecimals))),
      ("icrc1:fee", #Nat(tokenFee)),
      ("icrc1:max_memo_length", #Nat(maxMemoLength)),
    ]
  };

  public query func icrc1_supported_standards() : async [{ name : Text; url : Text }] {
    [
      { name = "ICRC-1"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-1" },
      { name = "ICRC-2"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-2" },
      { name = "ICRC-3"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
      { name = "ICRC-10"; url = "https://github.com/dfinity/ICRC/tree/main/ICRCs/ICRC-10" },
    ]
  };

  // ═══════════════════════════════════════════════════════
  //  CIRCUIT BREAKER STATUS
  // ═══════════════════════════════════════════════════════

  public query func getShieldStatus() : async {
    cycleBalance : Nat;
    threshold : Nat;
    tripped : Bool;
    blockCount : Nat;
  } {
    {
      cycleBalance = Cycles.balance();
      threshold = circuitBreakerThreshold;
      tripped = circuitBreakerTripped;
      blockCount = BLog.length(blockState);
    }
  };

  public shared ({ caller }) func setCircuitBreakerThreshold(newThreshold : Nat) : async () {
    assert(isAdmin(caller));
    circuitBreakerThreshold := newThreshold;
  };

  /// Transfer admin to a new principal. Only current admin can call.
  public shared ({ caller }) func transferAdmin(newAdmin : Principal) : async () {
    assert(isAdmin(caller));
    assert(not Principal.isAnonymous(newAdmin));
    adminPrincipal := newAdmin;
  };

  public query func getAdmin() : async Principal { adminPrincipal };

  /// ICRC-3: Supported block types
  public query func icrc3_supported_block_types() : async [{ block_type : Text; url : Text }] {
    [
      { block_type = "1xfer"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
      { block_type = "2xfer"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
      { block_type = "1burn"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
      { block_type = "1mint"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
      { block_type = "2approve"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
    ]
  };

  // ═══════════════════════════════════════════════════════
  //  ICRC-2 QUERIES
  // ═══════════════════════════════════════════════════════

  public query func icrc2_allowance(allowanceArgs : T.AllowanceArgs) : async T.Allowance {
    Allow.getAllowance(allowState, allowanceArgs.account, allowanceArgs.spender)
  };

  // ═══════════════════════════════════════════════════════
  //  INDEX QUERIES (index-ng compatible; THE INNOVATION)
  // ═══════════════════════════════════════════════════════

  public query func get_account_transactions(args : T.GetAccountTransactionsArgs) : async T.GetAccountTransactionsResult {
    let txs = BLog.getAccountTransactions(blockState, args.account, args.start, args.max_results);
    let balance = holderBalance(args.account);
    let oldest = BLog.getOldestTxId(blockState, args.account);
    { transactions = txs; oldest_tx_id = oldest; balance }
  };

  public query func list_subaccounts(owner : Principal, start : ?Blob) : async [Blob] {
    BLog.listSubaccounts(blockState, owner, start)
  };

  // ═══════════════════════════════════════════════════════
  //  ICRC-3: BLOCK LOG
  // ═══════════════════════════════════════════════════════

  public query func icrc3_get_blocks(args : [T.GetBlocksArgs]) : async { blocks : [T.Block]; log_length : Nat } {
    let allBlocks = List.empty<T.Block>();
    for (range in args.vals()) {
      // Clamp range to locally-held blocks (archived blocks are in archive canisters)
      let effectiveStart = Nat.max(range.start, localBlockOffset);
      if (effectiveStart < BLog.length(blockState)) {
        let localIdx = effectiveStart - localBlockOffset;
        let effectiveLen = Nat.min(range.length, BLog.length(blockState) - effectiveStart);
        let rawBlocks = BLog.getBlocks(blockState, localIdx, effectiveLen);
        for (b in rawBlocks.vals()) {
          // Restore absolute block index for the client
          List.add(allBlocks, { id = localBlockOffset + b.index; block = blockToValue(b) });
        };
      };
    };
    { blocks = List.toArray(allBlocks); log_length = BLog.length(blockState) }
  };

  /// Encode block as ICRC-3 Value (List-based O(1) field building)
  func blockToValue(b : BLog.Block) : T.Value {
    let btype = switch (b.transaction.kind) {
      case "transfer" {
        switch (b.transaction.spender) {
          case (?_) "2xfer";
          case null "1xfer";
        };
      };
      case "burn" "1burn";
      case "mint" "1mint";
      case "approve" "2approve";
      case (other) other;
    };

    let txFields = List.empty<(Text, T.Value)>();
    List.add(txFields, ("idx", #Nat(b.index)));
    List.add(txFields, ("amt", #Nat(b.transaction.amount)));
    switch (b.transaction.from) {
      case (?a) { List.add(txFields, ("from", accountToValue(a))) };
      case null {};
    };
    switch (b.transaction.to) {
      case (?a) { List.add(txFields, ("to", accountToValue(a))) };
      case null {};
    };
    switch (b.transaction.spender) {
      case (?a) { List.add(txFields, ("spender", accountToValue(a))) };
      case null {};
    };
    switch (b.transaction.memo) {
      case (?m) { List.add(txFields, ("memo", #Blob(m))) };
      case null {};
    };

    let fields = List.empty<(Text, T.Value)>();
    List.add(fields, ("btype", #Text(btype)));
    List.add(fields, ("ts", #Nat(Nat64.toNat(b.timestamp))));
    List.add(fields, ("tx", #Map(List.toArray(txFields))));
    switch (b.effectiveFee) {
      case (?f) { List.add(fields, ("fee", #Nat(f))) };
      case null {};
    };
    switch (b.parentHash) {
      case (?h) { List.add(fields, ("phash", #Blob(h))) };
      case null {};
    };
    #Map(List.toArray(fields))
  };

  func accountToValue(a : T.Account) : T.Value {
    switch (a.subaccount) {
      case (?s) #Map([("owner", #Blob(Principal.toBlob(a.owner))), ("subaccount", #Blob(s))]);
      case null #Map([("owner", #Blob(Principal.toBlob(a.owner)))]);
    };
  };

  // ═══════════════════════════════════════════════════════
  //  ICRC-3: GET TRANSACTIONS (required by spec)
  // ═══════════════════════════════════════════════════════

  type ArchiveQueryInterface = actor {
    icrc3_get_blocks : shared query [{ start : Nat; length : Nat }] -> async {
      blocks : [T.Block];
      log_length : Nat;
    };
  };

  public query func icrc3_get_transactions(args : { start : Nat; length : Nat }) : async {
    transactions : [T.Block];
    log_length : Nat;
    archived_transactions : [{
      args : [{ start : Nat; length : Nat }];
      callback : shared query [{ start : Nat; length : Nat }] -> async {
        blocks : [T.Block];
        log_length : Nat;
      };
    }];
  } {
    let requestedEnd = args.start + args.length;
    let totalLogLen = localBlockOffset + BLog.length(blockState);

    // Build archive callbacks for any requested blocks that fall in archived ranges
    type ArchiveCallback = {
      args : [{ start : Nat; length : Nat }];
      callback : shared query [{ start : Nat; length : Nat }] -> async {
        blocks : [T.Block];
        log_length : Nat;
      };
    };

    // Count matching archives first, then build array
    var matchCount : Nat = 0;
    for (a in archives.vals()) {
      if (args.start <= a.lastBlock and requestedEnd > a.firstBlock) {
        matchCount += 1;
      };
    };

    let archivedEntries = Array.tabulate<ArchiveCallback>(matchCount, func(idx : Nat) : ArchiveCallback {
      // Find the idx-th matching archive
      var matched : Nat = 0;
      var result : ArchiveCallback = {
        args = []; callback = (actor("aaaaa-aa") : ArchiveQueryInterface).icrc3_get_blocks;
      };
      label scan for (a in archives.vals()) {
        if (args.start <= a.lastBlock and requestedEnd > a.firstBlock) {
          if (matched == idx) {
            let overlapStart = Nat.max(args.start, a.firstBlock);
            let overlapEnd = Nat.min(requestedEnd, a.lastBlock + 1);
            let archiveActor : ArchiveQueryInterface = actor (Principal.toText(a.canisterId));
            result := {
              args = [{ start = overlapStart; length = overlapEnd - overlapStart }];
              callback = archiveActor.icrc3_get_blocks;
            };
            break scan;
          };
          matched += 1;
        };
      };
      result;
    });

    // Serve locally-held blocks
    let effectiveStart = Nat.max(args.start, localBlockOffset);
    let blocks = if (effectiveStart < totalLogLen) {
      let localIdx = effectiveStart - localBlockOffset;
      let effectiveLen = Nat.min(args.length, totalLogLen - effectiveStart);
      let rawBlocks = BLog.getBlocks(blockState, localIdx, effectiveLen);
      Array.map<BLog.Block, T.Block>(rawBlocks, func(b) {
        { id = localBlockOffset + b.index; block = blockToValue(b) }
      })
    } else { [] };

    {
      transactions = blocks;
      log_length = totalLogLen;
      archived_transactions = archivedEntries;
    }
  };

  // ═══════════════════════════════════════════════════════
  //  ICRC-10: SUPPORTED STANDARDS
  // ═══════════════════════════════════════════════════════

  public query func icrc10_supported_standards() : async [{ name : Text; url : Text }] {
    [
      { name = "ICRC-1"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-1" },
      { name = "ICRC-2"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-2" },
      { name = "ICRC-3"; url = "https://github.com/dfinity/ICRC-1/tree/main/standards/ICRC-3" },
      { name = "ICRC-10"; url = "https://github.com/dfinity/ICRC/tree/main/ICRCs/ICRC-10" },
    ]
  };

  // ═══════════════════════════════════════════════════════
  //  ICRC-3: ARCHIVES
  // ═══════════════════════════════════════════════════════

  public query func icrc3_get_archives(args : { from : ?Principal }) : async [{
    canister_id : Principal;
    start : Nat;
    end : Nat;
  }] {
    // Return all archive canisters, optionally filtered by `from` principal
    let startFrom : Nat = switch (args.from) {
      case null 0;
      case (?p) {
        var skip : Nat = 0;
        label find for (a in archives.vals()) {
          if (Principal.equal(a.canisterId, p)) break find;
          skip += 1;
        };
        skip
      };
    };
    Array.tabulate<{ canister_id : Principal; start : Nat; end : Nat }>(
      if (startFrom >= archives.size()) 0 else archives.size() - startFrom,
      func(i) {
        let a = archives[startFrom + i];
        { canister_id = a.canisterId; start = a.firstBlock; end = a.lastBlock }
      }
    )
  };

  // ═══════════════════════════════════════════════════════
  //  ICRC-3: TIP CERTIFICATE (certified data)
  // ═══════════════════════════════════════════════════════

  public query func icrc3_get_tip_certificate() : async ?{
    certificate : Blob;
    hash_tree : Blob;
  } {
    if (journalActive() and journalCert.committed) {
      FCert.combinedCertificate(certState.lastBlockIndex, certState.lastBlockHash, journalCert.lastBlockIndex, journalCert.lastBlockHash, journalCert.mmrRoot)
    } else {
      Cert.getTipCertificate(certState)
    }
  };

  // ═══════════════════════════════════════════════════════
  //  MERKLE MOUNTAIN RANGE; O(log n) inclusion proofs
  // ═══════════════════════════════════════════════════════

  /// Get the MMR root hash (commitment over all blocks)
  public query func mmr_root() : async ?Blob {
    BLog.mmrRoot(blockState)
  };

  /// Generate an inclusion proof for a specific block
  public query func mmr_proof(blockIndex : Nat) : async ?{
    siblings : [Blob];
    peakIndex : Nat;
    peaks : [Blob];
  } {
    BLog.mmrProof(blockState, blockIndex)
  };

  // ═══════════════════════════════════════════════════════
  //  STATUS + ADMIN
  // ═══════════════════════════════════════════════════════

  public query func status() : async {
    total_transactions : Nat;
    total_accounts : Nat;
    total_supply : Nat;
    total_allowances : Nat;
    index_synced : Bool;
    mmr_peaks : Nat;
  } {
    {
      total_transactions = BLog.length(blockState);
      total_accounts = Bal.numAccounts(balState);
      total_supply = Bal.totalSupply(balState);
      total_allowances = Allow.size(allowState);
      index_synced = true;
      mmr_peaks = BLog.mmrPeakCount(blockState);
    }
  };

  public shared ({ caller }) func set_fee_collector(fc : ?T.Account) : async () {
    assert(isAdmin(caller));
    feeCollector := fc;
  };


  // ═══════════════════════════════════════════════════════
  //  JOURNAL FACADE; activation, two-phase transfers, queries
  // ═══════════════════════════════════════════════════════

  /// Activation height, keyed on the ICRC-3 block height. Default 2^64-1 (off).
  /// The first call prepares the journal's chart; the gate itself flips when
  /// the block height reaches `height`. Admin only.
  public shared ({ caller }) func setJournalActivationHeight(height : Nat64) : async { #ok : Nat64; #err : Text } {
    if (not isAdmin(caller)) return #err("admin only");
    // Once a holder's balance lives in the journal, its region balance is zero;
    // taking the gate down would route its writes to an empty region balance
    // (stranded funds). Activation is therefore one-way from the first migration.
    if (Map.size(migratedAccounts) > 0 and height > Nat64.fromNat(BLog.length(blockState))) {
      return #err("holders have migrated into the journal; the gate cannot be raised above the current height");
    };
    if (height != JT.ACTIVATION_OFF) {
      switch (initJournalChart()) { case (#err(e)) return #err(e); case (#ok(_)) {} };
    };
    journalActivation := height;
    certifyCurrent();
    #ok(height)
  };

  /// Eager migration of holder balances into the journal (admin). Lazy
  /// migration on first touch makes this optional.
  public shared ({ caller }) func migrateHolders(accounts : [T.Account]) : async { #ok : Nat; #err : Text } {
    if (not isAdmin(caller)) return #err("admin only");
    if (not journalActive()) return #err("journal not active");
    var n = 0;
    for (a in accounts.vals()) {
      switch (ensureMigrated(a)) { case (#err(e)) return #err("migration refused: " # debug_show(e)); case (#ok(_)) n += 1 };
    };
    certifyCurrent();
    #ok(n)
  };

  public type ReserveArgs = {
    from : T.Account; to : T.Account; amount : Nat; fee : ?Nat; memo : ?Blob;
    created_at_time : ?Nat64; expires_at : ?Nat64;
  };

  /// Phase one of a two-phase transfer: hold `amount + fee` of `from` for `to`
  /// as a pending journal posting. The caller is the reserver; as with
  /// icrc2_transfer_from it needs an allowance unless it owns `from`.
  public shared ({ caller }) func reserve_transfer(a : ReserveArgs) : async { #Ok : Nat; #Err : T.TransferFromError } {
    if (guardCycles()) return #Err(#TemporarilyUnavailable);
    if (not journalActive()) return #Err(#GenericError({ error_code = 901; message = "journal not active" }));
    switch (validateSubaccount(a.from.subaccount)) { case (?e) return #Err(#GenericError({ error_code = 100; message = e })); case null {} };
    switch (validateSubaccount(a.to.subaccount)) { case (?e) return #Err(#GenericError({ error_code = 100; message = e })); case null {} };
    if (isMintingAccount(a.from) or isMintingAccount(a.to)) return #Err(#GenericError({ error_code = 902; message = "reservations cannot mint or burn" }));
    let fee = switch (a.fee) { case (?f) { if (f != tokenFee) return #Err(#BadFee({ expected_fee = tokenFee })); f }; case null tokenFee };
    switch (validateMemo(a.memo)) { case (?e) return #Err(#GenericError({ error_code = 101; message = e })); case null {} };
    let dedup = switch (checkDedupAndTime(caller, a.created_at_time, a.amount, a.memo)) {
      case (#TooOld) return #Err(#TooOld);
      case (#InFuture(t)) return #Err(#CreatedInFuture({ ledger_time = t }));
      case (#Duplicate(idx)) return #Err(#Duplicate({ duplicate_of = idx }));
      case (#ok(d)) d;
    };
    let spender : T.Account = { owner = caller; subaccount = null };
    let needsAllowance = not T.accountsEqual(a.from, spender) and not Principal.equal(a.from.owner, caller);
    var allowanceUsed = 0;
    if (needsAllowance) {
      switch (Allow.useAllowance(allowState, a.from, spender, a.amount + fee)) {
        case (#err(#InsufficientAllowance(x))) { return #Err(#InsufficientAllowance(x)) };
        case (#ok(())) allowanceUsed := a.amount + fee;
      };
    };
    func restoreAllowance() {
      if (allowanceUsed > 0) { let cur = Allow.getAllowance(allowState, a.from, spender); ignore Allow.approve(allowState, a.from, spender, cur.allowance + allowanceUsed, cur.expires_at, null) };
    };
    switch (ensureMigrated(a.from)) { case (#err(e)) { restoreAllowance(); return #Err(#InsufficientFunds({ balance = holderBalance(a.from) })) }; case (#ok(_)) {} };
    switch (ensureMigrated(a.to)) { case (#err(e)) { restoreAllowance(); return #Err(#InsufficientFunds({ balance = holderBalance(a.to) })) }; case (#ok(_)) {} };
    switch (feeCollector) { case (?fc) { switch (ensureMigrated(fc)) { case (#err(_)) { restoreAllowance(); return #Err(#InsufficientFunds({ balance = holderBalance(a.from) })) }; case (#ok(_)) {} } }; case null {} };
    let legs = transferLegs(a.from, a.to, a.amount, fee);
    if (legs.size() == 0) { restoreAllowance(); return #Err(#GenericError({ error_code = 903; message = "nothing to reserve" })) };
    let day = today();
    let period = switch (ensurePeriod(day)) { case (#ok(p)) p; case (#err(e)) { restoreAllowance(); return #Err(#GenericError({ error_code = 904; message = e })) } };
    let input : JT.PostingInput = {
      idempotencyKey = idemKey(caller, a.created_at_time, a.amount, a.memo); postingDate = day; valueDate = day; period; legs;
      sourceRef = { kind = "reserve"; id = Principal.toText(caller) }; narration = ""; correctionOf = null;
    };
    switch (Core.prepareReserve(journalCore, selfPrincipal(), now(), input, a.expires_at)) {
      case (#err(e)) { restoreAllowance(); #Err(switch (e) { case (#ExceedsCredits(_)) #InsufficientFunds({ balance = holderBalance(a.from) }); case (#ExpiryInPast(x)) #GenericError({ error_code = 905; message = "expiry in the past" }); case (other) #GenericError({ error_code = 900; message = debug_show(other) }) }) };
      case (#ok(#duplicate(i))) { restoreAllowance(); #Err(#GenericError({ error_code = 909; message = "journal already holds this reservation (journal block " # Nat.toText(i) # ")" })) };
      case (#ok(#event(e))) {
        let b = commitJournal(selfPrincipal(), e);
        Map.add(reservations, Nat.compare, b.index, { reserver = caller; from = a.from; to = a.to; spender = if (needsAllowance) ?spender else null; amount = a.amount; fee; memo = a.memo; allowanceUsed });
        // a replay of this reservation (same caller, created_at_time, amount, memo) answers #Duplicate with the
        // reservation's identity: the key is recorded now, against the journal block the reservation holds
        recordDedup(dedup, b.index);
        certifyCurrent();
        #Ok(b.index)
      };
    }
  };

  /// Phase two: post a reservation. Produces the ICRC-3 transfer block.
  public shared ({ caller }) func post_transfer(reservation : Nat) : async { #Ok : Nat; #Err : T.TransferFromError } {
    if (guardCycles()) return #Err(#TemporarilyUnavailable);
    if (not journalActive()) return #Err(#GenericError({ error_code = 901; message = "journal not active" }));
    let ?r = Map.get(reservations, Nat.compare, reservation) else return #Err(#GenericError({ error_code = 906; message = "unknown or resolved reservation" }));
    if (not Principal.equal(r.reserver, caller)) return #Err(#GenericError({ error_code = 907; message = "only the reserver may resolve" }));
    switch (Core.preparePostPending(journalCore, journalBlocks(), selfPrincipal(), now(), reservation, null)) {
      case (#err(e)) #Err(#GenericError({ error_code = 900; message = debug_show(e) }));
      case (#ok(#expired({ expiresAt }))) {
        ignore commitJournal(selfPrincipal(), Core.expiryVoidEvent(reservation));
        releaseReservation(reservation, r);
        certifyCurrent();
        #Err(#GenericError({ error_code = 908; message = "reservation expired at " # Nat64.toText(expiresAt) }))
      };
      case (#ok(#event(e))) {
        let jb = commitJournal(selfPrincipal(), e);
        ignore Map.delete(reservations, Nat.compare, reservation);
        if (r.fee > 0 and feeCollector == null) balState.tokenPool += r.fee;
        let tx = makeTx("transfer", ?r.from, ?r.to, r.spender, r.amount, ?r.fee, r.memo);
        let idx = appendAndCertify(tx, ?r.fee);
        Map.add(icrcToJournal, Nat.compare, idx, jb.index);
        Map.add(reservationOutcomes, Nat.compare, reservation, #posted(idx));
        #Ok(idx)
      };
    }
  };

  /// Phase two: void a reservation; the hold is released and any allowance
  /// consumed at reservation is restored.
  public shared ({ caller }) func void_transfer(reservation : Nat) : async { #Ok : Nat; #Err : T.TransferFromError } {
    if (guardCycles()) return #Err(#TemporarilyUnavailable);
    if (not journalActive()) return #Err(#GenericError({ error_code = 901; message = "journal not active" }));
    let ?r = Map.get(reservations, Nat.compare, reservation) else return #Err(#GenericError({ error_code = 906; message = "unknown or resolved reservation" }));
    if (not Principal.equal(r.reserver, caller) and not isAdmin(caller)) return #Err(#GenericError({ error_code = 907; message = "only the reserver may resolve" }));
    switch (Core.prepareVoidPending(journalCore, journalBlocks(), selfPrincipal(), reservation)) {
      case (#err(e)) #Err(#GenericError({ error_code = 900; message = debug_show(e) }));
      case (#ok(e)) {
        let b = commitJournal(selfPrincipal(), e);
        releaseReservation(reservation, r);
        certifyCurrent();
        #Ok(b.index)
      };
    }
  };

  func releaseReservation(reservation : Nat, r : Reservation) {
    ignore Map.delete(reservations, Nat.compare, reservation);
    Map.add(reservationOutcomes, Nat.compare, reservation, #voided(JLog.length(journalLog) - 1));
    switch (r.spender) {
      case (?sp) { if (r.allowanceUsed > 0) { let cur = Allow.getAllowance(allowState, r.from, sp); ignore Allow.approve(allowState, r.from, sp, cur.allowance + r.allowanceUsed, cur.expires_at, null) } };
      case null {};
    };
  };

  /// Void every expired reservation (timer and explicit). Returns the count.
  func expireReservations(limit : Nat) : Nat {
    if (not journalActive()) return 0;
    let expired = Core.expiredPendings(journalCore, now(), limit);
    for (idx in expired.vals()) {
      ignore commitJournal(selfPrincipal(), Core.expiryVoidEvent(idx));
      switch (Map.get(reservations, Nat.compare, idx)) { case (?r) releaseReservation(idx, r); case null {} };
    };
    if (expired.size() > 0) certifyCurrent();
    expired.size()
  };

  public shared func expire_reservations(limit : Nat) : async Nat { expireReservations(Nat.min(limit, 100)) };

  // ── journal queries ──
  public query func journal_activation_height() : async Nat64 { journalActivation };
  public query func journal_active() : async Bool { journalActive() };
  public query func journal_block_count() : async Nat { JLog.length(journalLog) };
  public query func journal_block(index : Nat) : async ?JT.Block { JLog.get(journalLog, index) };
  public query func journal_raw_block(index : Nat) : async ?Blob { JLog.rawBlock(journalLog, index) };
  public query func journal_proof(index : Nat) : async ?JLog.Proof { JLog.proof(journalLog, index) };
  public query func journal_mmr_root() : async ?Blob { JLog.mmrRoot(journalLog) };
  public query func journal_block_for_icrc_block(icrcIndex : Nat) : async ?Nat { Map.get(icrcToJournal, Nat.compare, icrcIndex) };
  public query func journal_holder_balance(account : T.Account) : async JT.Balance { Core.balance(journalCore, HOLDERS, ?holderKey(account), tokenSymbol) };
  public query func journal_is_migrated(account : T.Account) : async Bool { isMigrated(account) };
  public query func journal_trial_balance(period : Text) : async ?JT.TrialBalance { Core.trialBalance(journalCore, period) };
  public query func journal_periods() : async [JT.Period] { Core.listPeriods(journalCore) };
  /// Outcome of a resolved reservation (null while it is still pending or unknown).
  public query func reservation_outcome(index : Nat) : async ?{ #posted : Nat; #voided : Nat } { Map.get(reservationOutcomes, Nat.compare, index) };
  public query func journal_reservation(index : Nat) : async ?{ reserver : Principal; from : T.Account; to : T.Account; amount : Nat; fee : Nat } {
    switch (Map.get(reservations, Nat.compare, index)) { case (?r) ?{ reserver = r.reserver; from = r.from; to = r.to; amount = r.amount; fee = r.fee }; case null null }
  };
  public query func journal_fingerprints() : async { live : Blob; replayed : Blob; height : Nat } {
    let fresh = Core.replay(journalCore.admin, JLog.getRange(journalLog, 0, JLog.length(journalLog)));
    { live = Core.fingerprint(journalCore); replayed = Core.fingerprint(fresh); height = journalCore.height }
  };
  /// Holder balances summed in the journal (migrated) plus region balances of
  /// unmigrated accounts is the supply; this returns the journal side.
  public query func journal_migrated_supply() : async Nat {
    let t = Core.accountTotal(journalCore, HOLDERS, tokenSymbol);
    if (t.creditsPosted > t.debitsPosted) t.creditsPosted - t.debitsPosted else 0
  };

  // ═══════════════════════════════════════════════════════
  //  ARCHIVE MANAGEMENT
  // ═══════════════════════════════════════════════════════

  /// Set archive threshold (admin only). Blocks in the main canister's StableLog
  /// beyond this count trigger automatic archival.
  public shared ({ caller }) func setArchiveThreshold(threshold : Nat) : async () {
    assert(isAdmin(caller));
    archiveBlockThreshold := threshold;
  };

  /// Manually trigger archive spawning (admin only).
  /// Spawns a new Archive canister, migrates blocks [localBlockOffset..currentCount-retainCount],
  /// then updates the archive registry.
  public shared ({ caller }) func triggerArchive(retainCount : Nat, archiveCycles : Nat) : async { #ok : Principal; #err : Text } {
    assert(isAdmin(caller));
    if (archiveInProgress) return #err("Archive already in progress");
    let totalBlocks = BLog.length(blockState);
    if (totalBlocks <= retainCount) return #err("Nothing to archive");

    archiveInProgress := true;

    try {
      // Spawn new Archive canister
      let archive = await (with cycles = archiveCycles) Archive.Archive(Principal.fromActor(self));
      let archiveId = Principal.fromActor(archive);

      let migrateStart = localBlockOffset;
      let migrateEnd = totalBlocks - retainCount;

      await archive.init(migrateStart);

      // Migrate blocks in batches
      var pos = migrateStart;
      while (pos < migrateEnd) {
        let batchEnd = Nat.min(pos + archiveBatchSize, migrateEnd);
        let batch = BLog.getRawBlobs(blockState, pos - localBlockOffset, batchEnd - pos);
        ignore await archive.appendBlocks(batch);
        pos := batchEnd;
      };

      // Update registry
      let entry : ArchiveEntry = { canisterId = archiveId; firstBlock = migrateStart; lastBlock = migrateEnd - 1 };
      let newArchives = Array.tabulate<ArchiveEntry>(archives.size() + 1, func(i) {
        if (i < archives.size()) archives[i] else entry
      });
      archives := newArchives;
      localBlockOffset := migrateEnd;
      archiveInProgress := false;

      #ok(archiveId)
    } catch (e) {
      archiveInProgress := false;
      #err("Archive failed: " # Error.message(e))
    }
  };

  /// Query archive status
  public query func getArchiveStatus() : async {
    archiveCount : Nat;
    localBlockOffset : Nat;
    localBlockCount : Nat;
    totalBlocks : Nat;
    archiveThreshold : Nat;
  } {
    {
      archiveCount = archives.size();
      localBlockOffset;
      localBlockCount = BLog.length(blockState) - localBlockOffset;
      totalBlocks = BLog.length(blockState);
      archiveThreshold = archiveBlockThreshold;
    }
  };

  // Init at end to avoid forward references.
  // Only run on first install; state persists across upgrades.
  if (BLog.length(blockState) == 0) {
    initBalances();
  };

  // IC resets CertifiedData on upgrade; recertify from persisted state
  certifyCurrent();

  // ═══════════════════════════════════════════════════════
  //  MAINTENANCE TIMER; prune expired allowances every 60s
  // ═══════════════════════════════════════════════════════

  ignore Timer.recurringTimer<system>(#seconds 60, func() : async () {
    ignore Allow.prune(allowState, 50);
    ignore expireReservations(50);
    // Auto-archive: trigger when block count exceeds threshold
    if (archiveNeeded and not archiveInProgress) {
      archiveNeeded := false;
      try { ignore await triggerArchive(archiveBlockThreshold / 2, 1_000_000_000_000) }
      catch (_) { archiveInProgress := false }; // prevent permanent deadlock on failure
    };
  });
};
