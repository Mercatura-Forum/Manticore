/// ProductCore.mo — the product engine's state, which holds no money.
///
/// Shaped exactly like `PartyCore`: every field is the fold of the bank log, `apply`
/// is the only place state changes, and `fingerprintInto` digests it so "the
/// materialised state is the fold of the log" is a property a test asserts.
///
/// What is here: products and their versions, accounts and the version each was
/// opened under, loan schedules and their revisions, the running allowance per
/// loan, tills and who holds them. What is deliberately **not** here: any balance.
/// Principal outstanding, interest receivable, fees, penalties, cash in a drawer —
/// every one of those is a journal balance read through `Posting`, so there is
/// nothing to reconcile and nothing to go stale when a posting is back-dated.
///
/// The one figure that looks like a balance and is not is `allowance`: the
/// provision *decision* against a loan. It is the last figure the engine set, kept
/// so the next provisioning run can post the movement rather than the total. The
/// allowance account's own balance is the journal's, and the battery asserts the
/// two agree.
///
/// ## Where an account lives
///
/// An account *is* its `#accountOpened` block, and a till its `#tillOpened` block. The heap holds
/// nothing per account: the fold keeps one fixed-width **row** per account in stable memory
/// (`AccountRow`: status, version, the block that closed it, pointers to the blocks that granted
/// its facility, set its provision and disbursed it, the count of its schedule versions, and the
/// ordinals a scan filters on), and stable indexes for what a row cannot hold — the schedule
/// versions and the charges applied and waived, each an index entry pointing at its block — and
/// for the lookups (identifier, party, product). An `AccountEntry` is rebuilt from the row and its
/// blocks when a planner or a reader needs one. The last capitalisation day is not stored per
/// account at all: a capitalisation run is one event per product and currency, so the per-account
/// figure is computed from the run history and the account's own opening. What stays on the heap is
/// bounded by the product catalogue, not the customer base.

import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Principal "mo:core/Principal";
import Map "mo:core/Map";
import List "mo:core/List";
import Array "mo:core/Array";
import Order "mo:core/Order";
import Runtime "mo:core/Runtime";

import JT "mo:journal/JournalTypes";
import JC "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";

import T "ProductTypes";
import I "Interest";
import Posting "Posting";
import R "StableRows";

module {

  // ═══════════════════════════════════════════════════════
  //  STATE
  // ═══════════════════════════════════════════════════════

  /// How the fold reads its own blocks back: the product events of the bank's log, by block index.
  public type Blocks = { get : Nat -> ?T.ProductEvent };

  public type VersionEntry = {
    id : T.ProductId;
    version : T.ProductVersion;
    name : Text;
    terms : T.ProductTerms;
    registeredAtBlock : Nat;
    var supersededBy : ?T.ProductVersion;
    var openToNewAccounts : Bool;
  };

  public type ScheduleVersion = { version : Nat; effective : T.Day; rows : [T.Instalment]; recordedAtBlock : Nat };

  /// An account, rebuilt from its row and its blocks. Immutable: a reader's view of one moment.
  public type AccountEntry = {
    id : T.AccountId;
    product : T.ProductId;
    version : T.ProductVersion;
    party : Nat;
    book : Text;
    identifier : Text;
    subledger : JT.SubledgerKey;
    currency : JT.Currency;
    status : T.AccountStatus;
    opened : T.Day;
    maturity : ?T.Day;
    openingRate : ?I.Rate;
    allocationOrder : [T.Component];
    /// The day interest was last capitalised. Accrual is recomputed from here, so
    /// this is a cursor and not a balance.
    lastCapitalised : T.Day;
    facility : Nat;
    scheduleVersions : Nat;
    disbursed : ?T.Day;
    writtenOff : Bool;
    allowance : Nat;
    band : ?Text;
    openedAtBlock : Nat;
    closedAtBlock : ?Nat;
  };

  public type TillEntry = {
    id : T.TillId;
    book : Text;
    currency : JT.Currency;
    holder : Principal;
    product : T.ProductId;
    subledger : JT.SubledgerKey;
    status : T.TillStatus;
    allocated : Nat;
    returned : Nat;
    settlements : Nat;
    lastDifference : T.Difference;
    openedAtBlock : Nat;
  };

  /// `status(1) ‖ version(4) ‖ closedAt(8) ‖ facilityBlock(8) ‖ provisionBlock(8) ‖ disbursedBlock(8)
  /// ‖ writtenOff(1) ‖ scheduleCount(4) ‖ productOrd(4) ‖ currencyOrd(4) ‖ bookOrd(4) ‖ party(8) ‖
  /// opened(4)` — 66 bytes. A pointer of 0 means "never": block 0 is the genesis administrator
  /// record and can be none of these.
  public type AccountRow = {
    status : T.AccountStatus;
    version : Nat;
    closedAt : Nat;
    facilityBlock : Nat;
    provisionBlock : Nat;
    disbursedBlock : Nat;
    writtenOff : Bool;
    scheduleCount : Nat;
    productOrd : Nat;
    currencyOrd : Nat;
    bookOrd : Nat;
    party : Nat;
    opened : Nat;
  };

  public let ACCOUNT_ROW_BYTES : Nat = 66;

  /// `status(1) ‖ allocated(16) ‖ returned(16) ‖ settlements(4) ‖ diffTag(1) ‖ diffAmount(16) ‖
  /// openedAt(8) ‖ currencyOrd(4) ‖ bookOrd(4)` — 70 bytes. The running sums are folds of many
  /// events, so the row carries them; the currency and book are what a command's scoping asks for
  /// before anything else, so the row carries their ordinals.
  public type TillRow = {
    status : T.TillStatus;
    allocated : Nat;
    returned : Nat;
    settlements : Nat;
    lastDifference : T.Difference;
    openedAt : Nat;
    currencyOrd : Nat;
    bookOrd : Nat;
  };

  public let TILL_ROW_BYTES : Nat = 70;
  public let TILL_KEY_BYTES : Nat = 32;
  public let CHARGE_KEY_BYTES : Nat = 44;    // account(8) ‖ charge(32) ‖ day(4)
  public let IDENTIFIER_KEY_BYTES : Nat = 64;

  public type State = {
    /// (product id, version) -> the version. Every version is retained.
    versions : Map.Map<(Text, Nat), VersionEntry>;
    /// product id -> its newest version, so "the current terms" is a map read.
    current : Map.Map<Text, Nat>;
    accountRows : RI.State;            // account(8) -> AccountRow
    accountsByIdentifier : RI.State;   // identifier(64) -> account(8)
    /// subledger(32) -> account or till block(8): every sub-ledger key this shard holds. A posting
    /// naming any other sub-ledger is refused — a shard admits only what it holds.
    subledgers : RI.State;
    accountsByParty : RI.State;        // party(8) ‖ account(8) -> 0
    accountsByProduct : RI.State;      // productOrd(4) ‖ account(8) -> 0
    schedules : RI.State;              // account(8) ‖ seq(4) -> block(8)
    chargesApplied : RI.State;         // account(8) ‖ charge(32) ‖ day(4) -> block(8)
    chargesWaived : RI.State;          // likewise
    tillRows : RI.State;               // till(32) -> TillRow
    productOrdinals : Map.Map<Text, Nat>;
    productNames : List.List<Text>;
    currencyOrdinals : Map.Map<Text, Nat>;
    currencyNames : List.List<Text>;
    bookOrdinals : Map.Map<Text, Nat>;
    bookNames : List.List<Text>;
    /// The capitalisation runs per (product, currency): (block, to). One per run, so bounded by
    /// runs; an account's last capitalisation is computed from these and its own opening.
    capitalisations : Map.Map<(Text, Text), List.List<(Nat, Nat)>>;
    /// The last accrual posted per (product, currency), so a run cannot post the
    /// same business date twice and a gap is visible.
    accruedTo : Map.Map<(Text, Text), Nat>;
    /// (product, currency, business date) -> the amount that accrual posting booked.
    /// This is what makes a back-value correction a subtraction of two knowable
    /// quantities: the fold recomputed now, less what was actually booked. It is the
    /// recorded amount of each `#accrualPosted` block, so it is a fold of the log and
    /// not a running total that could drift.
    accruals : Map.Map<(Text, Text, Nat), Nat>;
    var highestAccount : Nat;
  };

  func cmpTN(a : (Text, Nat), b : (Text, Nat)) : Order.Order {
    switch (Text.compare(a.0, b.0)) { case (#equal) Nat.compare(a.1, b.1); case (o) o }
  };
  func cmpTT(a : (Text, Text), b : (Text, Text)) : Order.Order {
    switch (Text.compare(a.0, b.0)) { case (#equal) Text.compare(a.1, b.1); case (o) o }
  };
  func cmpTTN(a : (Text, Text, Nat), b : (Text, Text, Nat)) : Order.Order {
    switch (Text.compare(a.0, b.0)) {
      case (#equal) { switch (Text.compare(a.1, b.1)) { case (#equal) Nat.compare(a.2, b.2); case (o) o } };
      case (o) o;
    }
  };

  public func newState(arena : RI.Arena) : State {
    {
      versions = Map.empty<(Text, Nat), VersionEntry>();
      current = Map.empty<Text, Nat>();
      accountRows = RI.newStateIn(arena, { keyBytes = 8; valBytes = ACCOUNT_ROW_BYTES });
      accountsByIdentifier = RI.newStateIn(arena, { keyBytes = IDENTIFIER_KEY_BYTES; valBytes = 8 });
      subledgers = RI.newStateIn(arena, { keyBytes = 32; valBytes = 8 });
      accountsByParty = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      accountsByProduct = RI.newStateIn(arena, { keyBytes = 12; valBytes = 1 });
      schedules = RI.newStateIn(arena, { keyBytes = 12; valBytes = 8 });
      chargesApplied = RI.newStateIn(arena, { keyBytes = CHARGE_KEY_BYTES; valBytes = 8 });
      chargesWaived = RI.newStateIn(arena, { keyBytes = CHARGE_KEY_BYTES; valBytes = 8 });
      tillRows = RI.newStateIn(arena, { keyBytes = TILL_KEY_BYTES; valBytes = TILL_ROW_BYTES });
      productOrdinals = Map.empty<Text, Nat>();
      productNames = List.empty<Text>();
      currencyOrdinals = Map.empty<Text, Nat>();
      currencyNames = List.empty<Text>();
      bookOrdinals = Map.empty<Text, Nat>();
      bookNames = List.empty<Text>();
      capitalisations = Map.empty<(Text, Text), List.List<(Nat, Nat)>>();
      accruedTo = Map.empty<(Text, Text), Nat>();
      accruals = Map.empty<(Text, Text, Nat), Nat>();
      var highestAccount = 0;
    }
  };

  public type Event = T.ProductEvent;

  // ─── rows ─────────────────────────────────────────────────────────────────

  func statusTag(st : T.AccountStatus) : Nat8 { switch (st) { case (#pending) 0; case (#active) 1; case (#dormant) 2; case (#closed) 3 } };
  func statusFromTag(t : Nat8) : T.AccountStatus { switch (t) { case 0 #pending; case 1 #active; case 2 #dormant; case 3 #closed; case _ Runtime.trap("ProductCore: an account status tag that is not one") } };
  func tillTag(st : T.TillStatus) : Nat8 { switch (st) { case (#open) 0; case (#settled) 1; case (#closed) 2 } };
  func tillFromTag(t : Nat8) : T.TillStatus { switch (t) { case 0 #open; case 1 #settled; case 2 #closed; case _ Runtime.trap("ProductCore: a till status tag that is not one") } };

  public func encodeAccountRow(r : AccountRow) : Blob {
    let b = R.buf();
    R.putByte(b, statusTag(r.status)); R.putNat(b, r.version, 4); R.putNat(b, r.closedAt, 8);
    R.putNat(b, r.facilityBlock, 8); R.putNat(b, r.provisionBlock, 8); R.putNat(b, r.disbursedBlock, 8);
    R.putBool(b, r.writtenOff); R.putNat(b, r.scheduleCount, 4);
    R.putNat(b, r.productOrd, 4); R.putNat(b, r.currencyOrd, 4); R.putNat(b, r.bookOrd, 4);
    R.putNat(b, r.party, 8); R.putNat(b, r.opened, 4);
    R.done(b, ACCOUNT_ROW_BYTES)
  };

  public func decodeAccountRow(v : Blob) : AccountRow {
    let a = Blob.toArray(v);
    assert (a.size() == ACCOUNT_ROW_BYTES);
    {
      status = statusFromTag(a[0]); version = R.getNat(a, 1, 4); closedAt = R.getNat(a, 5, 8);
      facilityBlock = R.getNat(a, 13, 8); provisionBlock = R.getNat(a, 21, 8); disbursedBlock = R.getNat(a, 29, 8);
      writtenOff = R.getBool(a, 37); scheduleCount = R.getNat(a, 38, 4);
      productOrd = R.getNat(a, 42, 4); currencyOrd = R.getNat(a, 46, 4); bookOrd = R.getNat(a, 50, 4);
      party = R.getNat(a, 54, 8); opened = R.getNat(a, 62, 4);
    }
  };

  public func encodeTillRow(r : TillRow) : Blob {
    let b = R.buf();
    R.putByte(b, tillTag(r.status)); R.putNat(b, r.allocated, 16); R.putNat(b, r.returned, 16); R.putNat(b, r.settlements, 4);
    switch (r.lastDifference) {
      case (#balanced) { R.putByte(b, 0); R.putNat(b, 0, 16) };
      case (#over(n)) { R.putByte(b, 1); R.putNat(b, n, 16) };
      case (#short(n)) { R.putByte(b, 2); R.putNat(b, n, 16) };
    };
    R.putNat(b, r.openedAt, 8); R.putNat(b, r.currencyOrd, 4); R.putNat(b, r.bookOrd, 4);
    R.done(b, TILL_ROW_BYTES)
  };

  public func decodeTillRow(v : Blob) : TillRow {
    let a = Blob.toArray(v);
    assert (a.size() == TILL_ROW_BYTES);
    let amount = R.getNat(a, 38, 16);
    {
      status = tillFromTag(a[0]); allocated = R.getNat(a, 1, 16); returned = R.getNat(a, 17, 16); settlements = R.getNat(a, 33, 4);
      lastDifference = switch (a[37]) { case 0 #balanced; case 1 #over(amount); case 2 #short(amount); case _ Runtime.trap("ProductCore: a difference tag that is not one") };
      openedAt = R.getNat(a, 54, 8); currencyOrd = R.getNat(a, 62, 4); bookOrd = R.getNat(a, 66, 4);
    }
  };

  func ordinalOf(ords : Map.Map<Text, Nat>, names : List.List<Text>, t : Text) : Nat {
    switch (Map.get(ords, Text.compare, t)) {
      case (?o) o;
      case null { let o = List.size(names); List.add(names, t); Map.add(ords, Text.compare, t, o); o };
    }
  };

  func nameOf(names : List.List<Text>, o : Nat) : Text {
    switch (List.get(names, o)) { case (?t) t; case null Runtime.trap("ProductCore: an ordinal with no name") }
  };

  public func accountRow(s : State, id : T.AccountId) : ?AccountRow {
    switch (RI.get(s.accountRows, R.key(id, 8))) { case (?v) ?decodeAccountRow(v); case null null }
  };

  func putAccountRow(s : State, id : T.AccountId, r : AccountRow) { ignore RI.put(s.accountRows, R.key(id, 8), encodeAccountRow(r)) };

  func mustRow(s : State, id : Nat) : AccountRow {
    switch (accountRow(s, id)) { case (?r) r; case null Runtime.trap("product fold: unknown account " # Nat.toText(id)) }
  };

  func tillKey(id : T.TillId) : Blob { R.textKey(id, TILL_KEY_BYTES) };

  public func tillRow(s : State, id : T.TillId) : ?TillRow {
    if (Text.encodeUtf8(id).size() > TILL_KEY_BYTES) return null;
    switch (RI.get(s.tillRows, tillKey(id))) { case (?v) ?decodeTillRow(v); case null null }
  };

  func putTillRow(s : State, id : T.TillId, r : TillRow) { ignore RI.put(s.tillRows, tillKey(id), encodeTillRow(r)) };

  func mustTillRow(s : State, id : T.TillId) : TillRow {
    switch (tillRow(s, id)) { case (?r) r; case null Runtime.trap("product fold: unknown till " # id) }
  };

  func chargeKey(account : Nat, charge : Text, day : Nat) : Blob {
    let b = R.buf();
    R.putNat(b, account, 8); R.putText(b, charge, 32); R.putNat(b, day, 4);
    R.done(b, CHARGE_KEY_BYTES)
  };

  func eventAt(bb : Blocks, index : Nat, what : Text) : T.ProductEvent {
    let ?e = bb.get(index) else Runtime.trap("ProductCore: the log has no product event at block " # Nat.toText(index) # " for " # what);
    e
  };

  func blockOf(v : Blob) : Nat { R.getNat(Blob.toArray(v), 0, 8) };

  // ═══════════════════════════════════════════════════════
  //  LOOKUPS
  // ═══════════════════════════════════════════════════════

  public func getVersion(s : State, id : T.ProductId, v : T.ProductVersion) : ?VersionEntry {
    Map.get(s.versions, cmpTN, (id, v))
  };

  public func currentVersion(s : State, id : T.ProductId) : ?VersionEntry {
    switch (Map.get(s.current, Text.compare, id)) {
      case (?v) getVersion(s, id, v);
      case null null;
    }
  };

  public func productCount(s : State) : Nat { Map.size(s.current) };
  public func versionCount(s : State) : Nat { Map.size(s.versions) };
  public func accountCount(s : State) : Nat { RI.size(s.accountRows) };
  public func tillCount(s : State) : Nat { RI.size(s.tillRows) };
  public func exists(s : State, id : T.AccountId) : Bool { accountRow(s, id) != null };

  /// The day interest was last capitalised for an account: its opening, or the latest run for its
  /// product and currency that happened after it was opened — which is what the per-account cursor
  /// used to record, event by event.
  func lastCapitalisedOf(s : State, product : Text, currency : Text, openedAtBlock : Nat, opened : Nat) : Nat {
    var last = opened;
    switch (Map.get(s.capitalisations, cmpTT, (product, currency))) {
      case (?runs) { for ((block, to) in List.values(runs)) { if (block > openedAtBlock and to > last) last := to } };
      case null {};
    };
    last
  };

  /// An account, rebuilt from its row and its blocks: the opening block, and the blocks the row
  /// points at for the facility, the provision and the disbursement.
  public func get(s : State, bb : Blocks, id : T.AccountId) : ?AccountEntry {
    let ?row = accountRow(s, id) else return null;
    let #accountOpened(o) = eventAt(bb, id, "an account") else Runtime.trap("ProductCore: block " # Nat.toText(id) # " has an account row but is not an opening");
    let facility = if (row.facilityBlock == 0) 0 else {
      let #facilityGranted(f) = eventAt(bb, row.facilityBlock, "a facility") else Runtime.trap("ProductCore: facility pointer to a block that is not a grant");
      f.limit
    };
    let (allowance, band) : (Nat, ?Text) = if (row.provisionBlock == 0) (0, null) else {
      let #provisionSet(p) = eventAt(bb, row.provisionBlock, "a provision") else Runtime.trap("ProductCore: provision pointer to a block that is not a provision");
      (p.required, p.band)
    };
    let disbursed : ?T.Day = if (row.disbursedBlock == 0) null else {
      let #loanDisbursed(d) = eventAt(bb, row.disbursedBlock, "a disbursement") else Runtime.trap("ProductCore: disbursement pointer to a block that is not a disbursement");
      ?d.day
    };
    ?{
      id; product = o.product; version = row.version; party = o.party; book = o.book; identifier = o.identifier;
      subledger = Posting.subledgerOf(o.identifier); currency = o.currency; status = row.status;
      opened = o.opened; maturity = o.maturity; openingRate = o.openingRate; allocationOrder = o.allocationOrder;
      lastCapitalised = lastCapitalisedOf(s, o.product, o.currency, id, o.opened);
      facility; scheduleVersions = row.scheduleCount; disbursed; writtenOff = row.writtenOff; allowance; band;
      openedAtBlock = id; closedAtBlock = if (row.closedAt == 0) null else ?row.closedAt;
    }
  };

  /// Whether this shard holds the account or till a sub-ledger key belongs to.
  public func holdsSubledger(s : State, sub : JT.SubledgerKey) : Bool {
    if (sub.size() != 32) return false;
    switch (RI.get(s.subledgers, sub)) { case (?_) true; case null false }
  };

  public func byIdentifier(s : State, identifier : Text) : ?T.AccountId {
    if (Text.encodeUtf8(identifier).size() > IDENTIFIER_KEY_BYTES) return null;
    switch (RI.get(s.accountsByIdentifier, R.textKey(identifier, IDENTIFIER_KEY_BYTES))) { case (?v) ?blockOf(v); case null null }
  };

  public func getTill(s : State, bb : Blocks, id : T.TillId) : ?TillEntry {
    let ?row = tillRow(s, id) else return null;
    let #tillOpened(t) = eventAt(bb, row.openedAt, "a till") else Runtime.trap("ProductCore: till pointer to a block that is not an opening");
    ?{
      id; book = t.book; currency = t.currency; holder = t.holder; product = t.product;
      subledger = Posting.subledgerOf("till/" # id); status = row.status; allocated = row.allocated; returned = row.returned;
      settlements = row.settlements; lastDifference = row.lastDifference; openedAtBlock = row.openedAt;
    }
  };

  public func accruedTo(s : State, product : Text, ccy : Text) : ?Nat { Map.get(s.accruedTo, cmpTT, (product, ccy)) };

  /// The amount the accrual run for one business date booked, if it ran. Null is the
  /// evidence a day is missing, which is what gates a period close.
  public func accrualOn(s : State, product : Text, ccy : Text, day : Nat) : ?Nat {
    Map.get(s.accruals, cmpTTN, (product, ccy, day))
  };

  /// The total the accrual postings booked over `[from, to)`, read from the recorded
  /// amounts. A back-value correction is the fold recomputed now less this.
  public func accrualTotalBetween(s : State, product : Text, ccy : Text, from : Nat, to : Nat) : Nat {
    var total = 0;
    for (((p, c, d), amount) in Map.entries(s.accruals)) {
      if (Text.equal(p, product) and Text.equal(c, ccy) and d >= from and d < to) total += amount;
    };
    total
  };

  public func accrualCount(s : State) : Nat { Map.size(s.accruals) };

  /// The terms an account computes on: the version it was opened under, which does
  /// not move when the product is amended.
  public func termsOf(s : State, a : AccountEntry) : ?T.ProductTerms {
    switch (getVersion(s, a.product, a.version)) { case (?v) ?v.terms; case null null }
  };

  /// The account's book, from the row.
  public func bookOf(s : State, id : T.AccountId) : ?Text {
    switch (accountRow(s, id)) { case (?r) ?nameOf(s.bookNames, r.bookOrd); case null null }
  };

  public func currencyOf(s : State, id : T.AccountId) : ?JT.Currency {
    switch (accountRow(s, id)) { case (?r) ?nameOf(s.currencyNames, r.currencyOrd); case null null }
  };

  public func tillCurrencyOf(s : State, id : T.TillId) : ?JT.Currency {
    switch (tillRow(s, id)) { case (?r) ?nameOf(s.currencyNames, r.currencyOrd); case null null }
  };

  public func tillBookOf(s : State, id : T.TillId) : ?Text {
    switch (tillRow(s, id)) { case (?r) ?nameOf(s.bookNames, r.bookOrd); case null null }
  };

  public func statusOf(s : State, id : T.AccountId) : ?T.AccountStatus {
    switch (accountRow(s, id)) { case (?r) ?r.status; case null null }
  };

  func scheduleAt(bb : Blocks, block : Nat) : ScheduleVersion {
    switch (eventAt(bb, block, "a schedule")) {
      case (#loanDisbursed(d)) { { version = 1; effective = d.day; rows = d.schedule; recordedAtBlock = block } };
      case (#loanRescheduled(r)) { { version = r.version; effective = r.effective; rows = r.schedule; recordedAtBlock = block } };
      case (_) Runtime.trap("ProductCore: a schedule index entry that is not a schedule");
    }
  };

  /// The account's newest schedule, which is the one in force: the last entry of its schedule index.
  public func schedule(s : State, bb : Blocks, a : AccountEntry) : ?ScheduleVersion {
    if (a.scheduleVersions == 0) return null;
    switch (RI.get(s.schedules, R.key2(a.id, 8, a.scheduleVersions - 1, 4))) {
      case (?v) ?scheduleAt(bb, blockOf(v));
      case null Runtime.trap("ProductCore: a schedule count with no last entry");
    }
  };

  public func scheduleCount(a : AccountEntry) : Nat { a.scheduleVersions };

  /// The amount a charge was applied for on an occurrence, from its block; null when it was not.
  public func chargeApplied(s : State, bb : Blocks, account : T.AccountId, charge : Text, occurrence : T.Day) : ?Nat {
    if (Text.encodeUtf8(charge).size() > 32) return null;
    switch (RI.get(s.chargesApplied, chargeKey(account, charge, occurrence))) {
      case (?v) {
        let #chargeApplied(x) = eventAt(bb, blockOf(v), "an applied charge") else Runtime.trap("ProductCore: an applied-charge entry that is not one");
        ?x.amount
      };
      case null null;
    }
  };

  public func chargeWaived(s : State, bb : Blocks, account : T.AccountId, charge : Text, occurrence : T.Day) : ?Text {
    if (Text.encodeUtf8(charge).size() > 32) return null;
    switch (RI.get(s.chargesWaived, chargeKey(account, charge, occurrence))) {
      case (?v) {
        let #chargeWaived(x) = eventAt(bb, blockOf(v), "a waived charge") else Runtime.trap("ProductCore: a waived-charge entry that is not one");
        ?x.reason
      };
      case null null;
    }
  };

  /// Every entry of a prefix range, as the second key part.
  func rangeIds(idx : RI.State, lo : Blob, hi : Blob, at : Nat) : [Nat] {
    let out = List.empty<Nat>();
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(idx, lo, hi, cursor, MAX_PAGE);
      for ((k, _) in page.entries.vals()) List.add(out, R.getNat(Blob.toArray(k), at, 8));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };

  public func accountsOfParty(s : State, party : Nat) : [T.AccountId] {
    let (lo, hi) = R.prefixRange(party, 8, 8);
    rangeIds(s.accountsByParty, lo, hi, 8)
  };

  /// The account ids of a product, ascending — a range over the product index, no block read.
  public func accountIdsOfProduct(s : State, product : T.ProductId) : [T.AccountId] {
    let ?ord = Map.get(s.productOrdinals, Text.compare, product) else return [];
    let (lo, hi) = R.prefixRange(ord, 4, 8);
    rangeIds(s.accountsByProduct, lo, hi, 4)
  };

  func mustGet(s : State, bb : Blocks, id : T.AccountId) : AccountEntry {
    let ?a = get(s, bb, id) else Runtime.trap("ProductCore: an account row without an opening at " # Nat.toText(id));
    a
  };

  /// The accounts of a product, rebuilt. Bounded by the product's account count, which is the
  /// caller's business: the batch shards it, a preview is a preview.
  public func accountsOfProduct(s : State, bb : Blocks, product : T.ProductId) : [AccountEntry] {
    Array.map<Nat, AccountEntry>(accountIdsOfProduct(s, product), func(id) { mustGet(s, bb, id) })
  };

  public let MAX_PAGE : Nat = 500;

  func rowKeys(idx : RI.State, cursor : ?Nat, limit : Nat) : { ids : [Nat]; next : ?Nat } {
    let (lo, hi) = R.fullRange(8);
    let page = RI.range(idx, lo, hi, switch (cursor) { case (?c) ?R.key(c, 8); case null null }, limit);
    { ids = Array.map<(Blob, Blob), Nat>(page.entries, func((k, _)) { blockOf(k) }); next = switch (page.cursor) { case (?k) ?blockOf(k); case null null } }
  };

  /// Every account id, ascending.
  public func accountIds(s : State) : [T.AccountId] {
    let (lo, hi) = R.fullRange(8);
    rangeIds(s.accountRows, lo, hi, 0)
  };

  public func listAccounts(s : State, bb : Blocks) : [AccountEntry] {
    Array.map<Nat, AccountEntry>(accountIds(s), func(id) { mustGet(s, bb, id) })
  };

  /// Accounts, paged. The unbounded read of this whole estate: a national bank's account count is the
  /// number this component exists for. The cursor is the account id, which is the row key, so a page
  /// is a seek plus the page.
  public type AccountPage = { rows : [AccountEntry]; cursor : ?Nat; total : Nat };

  public func listAccountsPaged(s : State, bb : Blocks, cursor : ?Nat, limit : Nat) : AccountPage {
    let n = if (limit == 0 or limit > MAX_PAGE) MAX_PAGE else limit;
    let pg = rowKeys(s.accountRows, cursor, n);
    { rows = Array.map<Nat, AccountEntry>(pg.ids, func(id) { mustGet(s, bb, id) }); cursor = pg.next; total = RI.size(s.accountRows) }
  };

  public func highestAccount(s : State) : Nat { s.highestAccount };

  func tillIds(s : State, cursor : ?Text, limit : Nat) : { ids : [Text]; next : ?Text } {
    let (lo, hi) = R.fullRange(TILL_KEY_BYTES);
    let page = RI.range(s.tillRows, lo, hi, switch (cursor) { case (?c) ?tillKey(c); case null null }, limit);
    let id = func(k : Blob) : Text { R.getText(Blob.toArray(k), 0, TILL_KEY_BYTES) };
    { ids = Array.map<(Blob, Blob), Text>(page.entries, func((k, _)) { id(k) }); next = switch (page.cursor) { case (?k) ?id(k); case null null } }
  };

  func mustTill(s : State, bb : Blocks, id : T.TillId) : TillEntry {
    let ?t = getTill(s, bb, id) else Runtime.trap("ProductCore: a till row without an opening: " # id);
    t
  };

  public type TillPage = { rows : [TillEntry]; cursor : ?Text; total : Nat };

  public func listTillsPaged(s : State, bb : Blocks, cursor : ?Text, limit : Nat) : TillPage {
    let n = if (limit == 0 or limit > MAX_PAGE) MAX_PAGE else limit;
    let pg = tillIds(s, cursor, n);
    { rows = Array.map<Text, TillEntry>(pg.ids, func(id) { mustTill(s, bb, id) }); cursor = pg.next; total = RI.size(s.tillRows) }
  };

  public func listVersions(s : State) : [VersionEntry] {
    Array.map<((Text, Nat), VersionEntry), VersionEntry>(Map.toArray(s.versions), func((_, v)) { v })
  };

  public func listTills(s : State, bb : Blocks) : [TillEntry] {
    let out = List.empty<TillEntry>();
    var cursor : ?Text = null;
    label walk loop {
      let pg = tillIds(s, cursor, MAX_PAGE);
      for (id in pg.ids.vals()) List.add(out, mustTill(s, bb, id));
      switch (pg.next) { case null break walk; case (?n) cursor := ?n };
    };
    List.toArray(out)
  };

  /// Which side a product's customer balance sits on: the side of its principal
  /// role's required category. A deposit is a credit balance, a loan a debit one.
  public func normalSideOf(kind : T.ProductKind) : JT.Side {
    switch (T.requiredCategoryFor(kind, #principal)) {
      case (#asset) #debit;
      case (#expense) #debit;
      case (_) #credit;
    }
  };

  public func statusText(st : T.AccountStatus) : Text {
    switch (st) { case (#pending) "pending"; case (#active) "active"; case (#dormant) "dormant"; case (#closed) "closed" }
  };

  public func tillStatusText(st : T.TillStatus) : Text {
    switch (st) { case (#open) "open"; case (#settled) "settled"; case (#closed) "closed" }
  };

  // ═══════════════════════════════════════════════════════
  //  VIEWS
  // ═══════════════════════════════════════════════════════

  public func productView(v : VersionEntry) : T.ProductView {
    {
      id = v.id; version = v.version; name = v.name; terms = v.terms;
      registeredAtBlock = v.registeredAtBlock;
      supersededBy = v.supersededBy;
      openToNewAccounts = v.openToNewAccounts;
    }
  };

  public func accountView(a : AccountEntry) : T.AccountView {
    {
      id = a.id; product = a.product; version = a.version; party = a.party; book = a.book;
      identifier = a.identifier; subledger = a.subledger; currency = a.currency;
      status = a.status; opened = a.opened; maturity = a.maturity; openingRate = a.openingRate;
      allocationOrder = a.allocationOrder; lastCapitalised = a.lastCapitalised;
      facility = a.facility; scheduleVersions = a.scheduleVersions;
      disbursed = a.disbursed; writtenOff = a.writtenOff; allowance = a.allowance; band = a.band;
      openedAtBlock = a.openedAtBlock; closedAtBlock = a.closedAtBlock;
    }
  };

  public func tillView(t : TillEntry) : T.TillView {
    {
      id = t.id; book = t.book; currency = t.currency; holder = t.holder; product = t.product;
      subledger = t.subledger; status = t.status; allocated = t.allocated; returned = t.returned;
      settlements = t.settlements; lastDifference = t.lastDifference; openedAtBlock = t.openedAtBlock;
    }
  };

  public func listProductViews(s : State) : [T.ProductView] {
    Array.map<VersionEntry, T.ProductView>(listVersions(s), productView)
  };

  public func listAccountViews(s : State, bb : Blocks) : [T.AccountView] {
    Array.map<AccountEntry, T.AccountView>(listAccounts(s, bb), accountView)
  };

  public func listTillViews(s : State, bb : Blocks) : [T.TillView] {
    Array.map<TillEntry, T.TillView>(listTills(s, bb), tillView)
  };

  /// The schedule in force, as rows a reader can recompute from the terms.
  public func scheduleRows(s : State, bb : Blocks, id : T.AccountId) : ?[T.Instalment] {
    switch (get(s, bb, id)) {
      case (?a) { switch (schedule(s, bb, a)) { case (?sv) ?sv.rows; case null null } };
      case null null;
    }
  };

  /// Every schedule version an account has had, oldest first, so a reschedule is
  /// inspectable rather than only recorded.
  public func scheduleHistory(s : State, bb : Blocks, id : T.AccountId) : [ScheduleVersion] {
    let ?row = accountRow(s, id) else return [];
    let (lo, hi) = R.prefixRange(id, 8, 4);
    let page = RI.range(s.schedules, lo, hi, null, row.scheduleCount);
    Array.map<(Blob, Blob), ScheduleVersion>(page.entries, func((_, v)) { scheduleAt(bb, blockOf(v)) })
  };

  // ═══════════════════════════════════════════════════════
  //  THE FOLD
  // ═══════════════════════════════════════════════════════

  public func apply(s : State, blockIndex : Nat, e : Event) {
    switch (e) {
      case (#productRegistered(x)) {
        let entry : VersionEntry = {
          id = x.id; version = x.version; name = x.name; terms = x.terms;
          registeredAtBlock = blockIndex;
          var supersededBy = null;
          var openToNewAccounts = true;
        };
        Map.add(s.versions, cmpTN, (x.id, x.version), entry);
        Map.add(s.current, Text.compare, x.id, x.version);
      };
      case (#productAmended(x)) {
        switch (Map.get(s.versions, cmpTN, (x.id, x.supersedes))) {
          case (?old) { old.supersededBy := ?x.version; old.openToNewAccounts := false };
          case null {};
        };
        let entry : VersionEntry = {
          id = x.id; version = x.version; name = x.name; terms = x.terms;
          registeredAtBlock = blockIndex;
          var supersededBy = null;
          var openToNewAccounts = true;
        };
        Map.add(s.versions, cmpTN, (x.id, x.version), entry);
        Map.add(s.current, Text.compare, x.id, x.version);
      };
      case (#productClosedToNewAccounts(x)) {
        switch (Map.get(s.versions, cmpTN, (x.id, x.version))) {
          case (?v) v.openToNewAccounts := false;
          case null {};
        };
      };
      case (#accountOpened(x)) {
        let productOrd = ordinalOf(s.productOrdinals, s.productNames, x.product);
        putAccountRow(s, blockIndex, {
          status = #pending; version = x.version; closedAt = 0;
          facilityBlock = 0; provisionBlock = 0; disbursedBlock = 0; writtenOff = false; scheduleCount = 0;
          productOrd; currencyOrd = ordinalOf(s.currencyOrdinals, s.currencyNames, x.currency);
          bookOrd = ordinalOf(s.bookOrdinals, s.bookNames, x.book); party = x.party; opened = x.opened;
        });
        ignore RI.put(s.accountsByIdentifier, R.textKey(x.identifier, IDENTIFIER_KEY_BYTES), R.key(blockIndex, 8));
        ignore RI.put(s.subledgers, Posting.subledgerOf(x.identifier), R.key(blockIndex, 8));
        ignore RI.put(s.accountsByParty, R.key2(x.party, 8, blockIndex, 8), "\00");
        ignore RI.put(s.accountsByProduct, R.key2(productOrd, 4, blockIndex, 8), "\00");
        if (blockIndex > s.highestAccount) s.highestAccount := blockIndex;
      };
      case (#accountStatusSet(x)) {
        let r = mustRow(s, x.account);
        putAccountRow(s, x.account, { r with status = x.to; closedAt = if (x.to == #closed) blockIndex else r.closedAt });
      };
      case (#accountMigrated(x)) { putAccountRow(s, x.account, { mustRow(s, x.account) with version = x.to }) };
      case (#facilityGranted(x)) { putAccountRow(s, x.account, { mustRow(s, x.account) with facilityBlock = blockIndex }) };
      case (#chargeApplied(x)) { ignore RI.put(s.chargesApplied, chargeKey(x.account, x.charge, x.day), R.key(blockIndex, 8)) };
      case (#chargeWaived(x)) { ignore RI.put(s.chargesWaived, chargeKey(x.account, x.charge, x.occurrence), R.key(blockIndex, 8)) };
      case (#accrualPosted(x)) {
        Map.add(s.accruedTo, cmpTT, (x.product, x.currency), x.day);
        Map.add(s.accruals, cmpTTN, (x.product, x.currency, x.day), x.amount);
      };
      case (#interestCapitalised(x)) {
        // every account of the product in that currency has been capitalised to the run's end day;
        // recorded once, and read per account against its opening block
        let runs = switch (Map.get(s.capitalisations, cmpTT, (x.product, x.currency))) {
          case (?l) l;
          case null { let l = List.empty<(Nat, Nat)>(); Map.add(s.capitalisations, cmpTT, (x.product, x.currency), l); l };
        };
        List.add(runs, (blockIndex, x.to));
      };
      case (#loanDisbursed(x)) {
        let r = mustRow(s, x.account);
        ignore RI.put(s.schedules, R.key2(x.account, 8, r.scheduleCount, 4), R.key(blockIndex, 8));
        putAccountRow(s, x.account, { r with disbursedBlock = blockIndex; scheduleCount = r.scheduleCount + 1 });
      };
      case (#loanRescheduled(x)) {
        let r = mustRow(s, x.account);
        ignore RI.put(s.schedules, R.key2(x.account, 8, r.scheduleCount, 4), R.key(blockIndex, 8));
        putAccountRow(s, x.account, { r with scheduleCount = r.scheduleCount + 1 });
      };
      case (#repaymentReceived(_)) {};   // the money is the journal's; nothing to fold
      case (#provisionSet(x)) { putAccountRow(s, x.account, { mustRow(s, x.account) with provisionBlock = blockIndex }) };
      case (#loanWrittenOff(x)) { putAccountRow(s, x.account, { mustRow(s, x.account) with writtenOff = true }) };
      case (#recoveryReceived(_)) {};
      case (#termDepositRedeemed(x)) { putAccountRow(s, x.account, { mustRow(s, x.account) with status = #closed; closedAt = blockIndex }) };
      case (#tillOpened(x)) {
        putTillRow(s, x.till, {
          status = #open; allocated = 0; returned = 0; settlements = 0; lastDifference = #balanced; openedAt = blockIndex;
          currencyOrd = ordinalOf(s.currencyOrdinals, s.currencyNames, x.currency); bookOrd = ordinalOf(s.bookOrdinals, s.bookNames, x.book);
        });
        ignore RI.put(s.subledgers, Posting.subledgerOf("till/" # x.till), R.key(blockIndex, 8));
      };
      case (#tillAllocated(x)) { let t = mustTillRow(s, x.till); putTillRow(s, x.till, { t with allocated = t.allocated + x.amount; status = #open }) };
      case (#tillReturned(x)) { let t = mustTillRow(s, x.till); putTillRow(s, x.till, { t with returned = t.returned + x.amount }) };
      case (#tillSettled(x)) {
        let t = mustTillRow(s, x.till);
        putTillRow(s, x.till, { t with settlements = t.settlements + 1; lastDifference = x.difference; status = #settled });
      };
      case (#tillClosed(x)) { putTillRow(s, x.till, { mustTillRow(s, x.till) with status = #closed }) };
    };
  };

  // ═══════════════════════════════════════════════════════
  //  FINGERPRINT
  // ═══════════════════════════════════════════════════════

  func fingerprintRows(w : JC.Writer, idx : RI.State, width : Nat) {
    let (lo, hi) = R.fullRange(width);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(idx, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) { w.blobRaw(k); w.blobRaw(v) };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
  };

  public func fingerprintInto(w : JC.Writer, s : State) {
    w.nat(Map.size(s.versions));
    for (((id, v), e) in Map.entries(s.versions)) {
      w.text(id); w.nat(v); w.text(e.name);
      w.nat(e.registeredAtBlock);
      switch (e.supersededBy) { case null w.byte(0); case (?n) { w.byte(1); w.nat(n) } };
      w.bool(e.openToNewAccounts);
      // the terms themselves are digested by the canonical encoder, which the
      // block carrying them already used; here the role map and the headline
      // numbers are enough to make a divergence visible
      w.text(e.terms.currency); w.text(e.terms.control);
      w.len16(e.terms.roles.size());
      for (m in e.terms.roles.vals()) { w.text(T.roleText(m.role)); w.text(m.account) };
      w.len16(e.terms.charges.size());
      for (c in e.terms.charges.vals()) { w.text(c.id) };
      w.len16(e.terms.delinquency.size());
      for (b in e.terms.delinquency.vals()) { w.text(b.name); w.nat(b.fromDays) };
    };
    // the rows and indexes, raw: each is a deterministic function of the log
    w.nat(RI.size(s.accountRows));
    fingerprintRows(w, s.accountRows, 8);
    fingerprintRows(w, s.accountsByIdentifier, IDENTIFIER_KEY_BYTES);
    fingerprintRows(w, s.subledgers, 32);
    fingerprintRows(w, s.accountsByParty, 16);
    fingerprintRows(w, s.accountsByProduct, 12);
    fingerprintRows(w, s.schedules, 12);
    fingerprintRows(w, s.chargesApplied, CHARGE_KEY_BYTES);
    fingerprintRows(w, s.chargesWaived, CHARGE_KEY_BYTES);
    w.nat(RI.size(s.tillRows));
    fingerprintRows(w, s.tillRows, TILL_KEY_BYTES);
    for (n in List.values(s.productNames)) w.text(n);
    for (n in List.values(s.currencyNames)) w.text(n);
    for (n in List.values(s.bookNames)) w.text(n);
    for (((p, c), runs) in Map.entries(s.capitalisations)) { w.text(p); w.text(c); w.len16(List.size(runs)); for ((b, to) in List.values(runs)) { w.nat(b); w.nat(to) } };
    w.nat(s.highestAccount);
    w.nat(Map.size(s.accruedTo));
    for (((p, c), d) in Map.entries(s.accruedTo)) { w.text(p); w.text(c); w.nat(d) };
    w.nat(Map.size(s.accruals));
    for (((p, c, d), amount) in Map.entries(s.accruals)) { w.text(p); w.text(c); w.nat(d); w.nat(amount) };
  };
};
