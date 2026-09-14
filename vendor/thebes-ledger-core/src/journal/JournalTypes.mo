/// JournalTypes.mo: the vocabulary of the double-entry journal.
///
/// Everything the journal records is one of the `Event` variants below, and
/// every event is one immutable block in the Merkle-committed journal log.
/// The accounting state (chart of accounts, currencies, periods, balances,
/// trial balances) is a pure fold over those blocks; nothing is stored that
/// cannot be recomputed from them.
///
/// Amounts are natural numbers of minor units of one registered currency
/// (piastres for EGP, cents for USD). A leg is a debit or a credit; a posting
/// is a set of legs that balances per currency. Signed arithmetic never
/// appears in the record; debits and credits are kept as separate totals so
/// that a balance can be audited from either side without rounding.

import Principal "mo:core/Principal";

module {

  // ─── Identifiers ───────────────────────────────────────────────────────────

  /// Days since 1970-01-01 UTC (see CivilDate.mo).
  public type Day = Nat;

  /// Chart-of-accounts code: four ASCII digits, optionally followed by "." and
  /// one to six ASCII letters or digits, e.g. "1500" or "1400.01". The four
  /// digit prefix is what the leadsheet schema maps.
  public type AccountCode = Text;

  /// ISO 4217 alphabetic code, three ASCII upper-case letters.
  public type Currency = Text;

  /// Accounting period identifier chosen by the operator, e.g. "2026-09".
  /// One to sixteen ASCII characters from [A-Za-z0-9-_].
  public type PeriodId = Text;

  // ─── Chart of accounts ─────────────────────────────────────────────────────

  public type Side = { #debit; #credit };

  public type Category = { #asset; #liability; #equity; #income; #expense };

  public type AccountStatus = { #active; #closed };

  /// Engine-enforced balance limit, checked at admission over posted and
  /// pending amounts (the same rule as TigerBeetle's must-not-exceed flags):
  ///   #debitsNotExceedCredits  debitsPosted + debitsPending + amount <= creditsPosted
  ///                            (a deposit account that may not be overdrawn)
  ///   #creditsNotExceedDebits  creditsPosted + creditsPending + amount <= debitsPosted
  ///                            (a cash or nostro account that may not go negative)
  public type BalanceConstraint = { #none; #debitsNotExceedCredits; #creditsNotExceedDebits };

  public type Account = {
    code : AccountCode;
    name : Text;
    normalSide : Side;
    category : Category;
    constraint : BalanceConstraint;
    status : AccountStatus;
    openedAtBlock : Nat;
    closedAtBlock : ?Nat;
    /// Defaults to `{ usage = #detail; manualEntriesAllowed = true; parent = null }`
    /// for an account opened before attributes existed.
    attributes : AccountAttributes;
  };

  public type CurrencyInfo = { code : Currency; minorUnits : Nat8 };

  // ─── Periods ───────────────────────────────────────────────────────────────

  public type PeriodStatus = { #open; #closed };

  public type Period = {
    id : PeriodId;
    start : Day;          // inclusive
    end : Day;            // inclusive
    status : PeriodStatus;
    openedAtBlock : Nat;
    closedAtBlock : ?Nat;
  };

  // ─── Postings ──────────────────────────────────────────────────────────────

  /// A sub-ledger key identifies one holder under a general-ledger control
  /// account (a customer under "Customer deposits", an ICRC account under
  /// "Token holders"). Balances and limits are kept per (account, sub-ledger,
  /// currency); the trial balance and general ledger report the control
  /// account's totals. At most 64 bytes; null means the account itself.
  public type SubledgerKey = Blob;

  /// Which general-ledger accounts a poster may name in a leg. `null` (no entry
  /// recorded) means unrestricted, which is every poster's state until a scope
  /// is set, so a journal that has never set one behaves exactly as before.
  /// A recorded scope is an explicit allow-list: a leg naming an account outside
  /// it is refused at admission. This is what makes "only the bank posts to the
  /// customer-deposit control accounts" a property of the engine rather than a
  /// convention above it (proposal entitlements and maker-checker section 1.5).
  public type PosterScope = [AccountCode];

  /// A numeric balance limit for one (account, sub-ledger, currency), recorded by
  /// an administrator and checked at admission over posted **and** pending
  /// amounts. The account-level `BalanceConstraint` is the default; a recorded
  /// limit overrides it for that sub-ledger.
  ///
  ///   #debitsNotExceedCreditsPlus n   debits + pending <= credits + n
  ///                                   (a deposit account overdrawn by at most n;
  ///                                   an overdraft facility of n)
  ///   #creditsNotExceedDebitsPlus n   credits + pending <= debits + n
  ///                                   (a position that may go short by at most n;
  ///                                   a net debit cap of n)
  ///
  /// TigerBeetle has the all-or-nothing flags; the numeric form is what an
  /// overdraft facility and a net debit cap need, and putting it here rather than
  /// in a layer above is what makes it engine-enforced.
  public type BalanceLimit = { #none; #debitsNotExceedCreditsPlus : Nat; #creditsNotExceedDebitsPlus : Nat };

  /// Chart-of-accounts attributes. A `#header` account is a
  /// rollup and may not be posted to; `manualEntriesAllowed = false` refuses a
  /// posting whose source kind is a manual correction. Every account opened
  /// before this event existed reads as `#detail`, manual entries allowed, no
  /// parent; so nothing already written changes meaning.
  public type AccountUsage = { #header; #detail };

  public type AccountAttributes = {
    usage : AccountUsage;
    manualEntriesAllowed : Bool;
    parent : ?AccountCode;
  };

  public type Leg = {
    account : AccountCode;
    subledger : ?SubledgerKey;
    side : Side;
    currency : Currency;
    amount : Nat;         // minor units, strictly positive
  };

  /// Where the posting came from: an ICRC transfer, an ISO 20022 message, a
  /// batch run, an operator correction. `kind` is a short classifier and `id`
  /// the reference inside that system (block index, UETR, message id, ...).
  public type SourceRef = { kind : Text; id : Text };

  public type RelationKind = { #reversal; #correction };

  /// Link from a posting to the earlier posting it reverses or corrects.
  public type Relation = { original : Nat; kind : RelationKind };

  /// What a caller submits.
  public type PostingInput = {
    idempotencyKey : Blob;   // 1..64 bytes; scoped to the submitting principal
    postingDate : Day;       // booking date; must lie inside `period`
    valueDate : Day;         // interest/value date; may precede or follow postingDate
    period : PeriodId;
    legs : [Leg];
    sourceRef : SourceRef;
    narration : Text;        // at most MAX_NARRATION_BYTES of UTF-8
    correctionOf : ?Nat;     // index of the posting this one corrects, if any
  };

  /// What the journal stores; the input plus the relation resolved at admission,
  /// and the value date as requested when the working-day calendar moved it.
  public type PostingRecord = {
    idempotencyKey : Blob;
    postingDate : Day;
    valueDate : Day;              // effective (after any calendar shift)
    valueDateRequested : ?Day;    // the date asked for, only when it was shifted
    period : PeriodId;
    legs : [Leg];
    sourceRef : SourceRef;
    narration : Text;
    relation : ?Relation;
  };

  /// A posting submitted against the business date: posting and value date
  /// are the business date, the period is the open period containing it.
  public type BusinessPostingInput = {
    idempotencyKey : Blob;
    legs : [Leg];
    sourceRef : SourceRef;
    narration : Text;
    correctionOf : ?Nat;
  };

  /// Working-day calendar configuration: rest weekdays (0 = Monday),
  /// holidays, and what to do with a value date that is not a business day.
  public type ShiftPolicy = { #reject; #previous; #next; #nearest };
  public type CalendarConfig = { restDays : [Nat]; holidays : [Day]; policy : ShiftPolicy };

  public type VoidReason = { #requested; #expired };

  /// Dates and period applied when a pending posting is posted. Defaults to
  /// the values reserved with the pending posting; a caller may override them
  /// when the reserved period has since closed.
  public type Resolution = { postingDate : Day; valueDate : Day; valueDateRequested : ?Day; period : PeriodId };

  // ─── Leadsheet schema (tb_schema.json shape) ───────────────────────────────

  public type LeadsheetRange = {
    lo : Nat;             // inclusive four-digit prefix
    hi : Nat;             // inclusive four-digit prefix
    leadsheet : Text;
    name : Text;
    category : Text;
    cycle : Text;
  };

  // ─── Events: the only things that change journal state ────────────────────

  /// Where the journal's "today" comes from when no business date has been rolled, and whether a roll is
  /// measured against the substrate's clock. `#substrateClock`: the clock's day is today until a business date
  /// is set, and a business date may not pass the clock's day; right where the substrate's time is consensus
  /// time (the substrate). `#businessDate`: the rolled business date is the calendar and the clock is not consulted for
  /// days; a substrate whose `Time.now()` is not wall time (Thebes: the block height in seconds) cannot be the
  /// bank's calendar; the act that sets this authority carries the first business date when none is set, so
  /// under it a business date always exists, and a roll may advance by at most `maxRollDays`.
  public type CalendarAuthority = { #substrateClock; #businessDate };

  public type Event = {
    // financial
    #posted : PostingRecord;
    #pending : { record : PostingRecord; expiresAt : ?Nat64 };
    #post : { pendingIndex : Nat; resolution : Resolution };
    #void : { pendingIndex : Nat; reason : VoidReason };
    // configuration
    #currencyRegistered : CurrencyInfo;
    #accountOpened : { code : AccountCode; name : Text; normalSide : Side; category : Category; constraint : BalanceConstraint };
    #accountClosed : { code : AccountCode };
    #periodOpened : { id : PeriodId; start : Day; end : Day };
    #periodClosed : { id : PeriodId };
    #activationHeight : { height : Nat64 };
    #leadsheetSchema : { ranges : [LeadsheetRange] };
    #posterAdded : { poster : Principal };
    #posterRemoved : { poster : Principal };
    #posterScopeSet : { poster : Principal; accounts : ?PosterScope };   // null clears the restriction
    #balanceLimitSet : { account : AccountCode; subledger : ?SubledgerKey; currency : Currency; limit : BalanceLimit };
    #accountAttributesSet : { code : AccountCode; attributes : AccountAttributes };
    #adminTransferred : { admin : Principal };
    // period-end processes
    #businessDateRolled : { day : Day };
    #calendarSet : { calendar : ?CalendarConfig };   // null clears the calendar
    /// Which authority the journal's calendar has (see `CalendarAuthority`); under `#businessDate` the act
    /// carries the first business date when none is set yet, and the bound a roll may advance by.
    #calendarAuthoritySet : { authority : CalendarAuthority; maxRollDays : Nat; businessDate : ?Day };
    /// A checkpoint: the derived state as it stood after block `through`, in parts, written into the
    /// log by the archive roll before the blocks up to `through` leave the live contract. A fold of
    /// the retained log starts from the latest complete series and applies the blocks after
    /// `through`; applying the checkpoint blocks themselves changes nothing but the height. The
    /// series is `seq` 0 … n with `last` on the final part.
    #checkpoint : { through : Nat; seq : Nat; last : Bool; part : CheckpointPart };
  };

  /// The derived state, as a checkpoint carries it. Per-posting rows are not here: a fold from the
  /// checkpoint re-derives the rows of the retained blocks, and the rows of the archived ones have
  /// left the live contract with their blocks. The dated balances are carried rolled up: every day
  /// at or before `datedRolledUpThrough` folded into one row at that day per (account, currency,
  /// sub-ledger), which is what the live contract holds after the roll as well.
  public type CheckpointPart = {
    #config : {
      admin : Principal;
      activationHeight : Nat64;
      businessDate : ?Day;
      calendar : ?CalendarConfig;
      calendarAuthority : CalendarAuthority;
      maxRollDays : Nat;
      leadsheet : [LeadsheetRange];
      currencies : [(Currency, Nat8)];
      posters : [Principal];
      posterScopes : [(Principal, PosterScope)];
      balanceLimits : [{ account : AccountCode; subledger : Blob; currency : Currency; limit : BalanceLimit }];
      accountAttributes : [(AccountCode, AccountAttributes)];
      accountOrdinals : [(AccountCode, Nat)];
      currencyOrdinals : [(Currency, Nat)];
      periodOrdinals : [(PeriodId, Nat)];
      postedCount : Nat;
      voidedCount : Nat;
      datedRolledUpThrough : Nat;
    };
    #accounts : [{ code : AccountCode; name : Text; normalSide : Side; category : Category; constraint : BalanceConstraint; active : Bool; openedAtBlock : Nat; closedAtBlock : ?Nat }];
    #periods : [{ id : PeriodId; start : Day; end : Day; open : Bool; openedAtBlock : Nat; closedAtBlock : ?Nat; postings : Nat; pendings : Nat }];
    #balances : [{ account : AccountCode; subledger : Blob; currency : Currency; drPosted : Nat; crPosted : Nat; drPending : Nat; crPending : Nat }];
    #periodBalances : [{ period : PeriodId; account : AccountCode; currency : Currency; debits : Nat; credits : Nat }];
    #dated : { valueDated : Bool; rows : [{ account : AccountCode; currency : Currency; subledger : Blob; day : Day; debits : Nat; credits : Nat }] };
    #pendings : { open : [Nat]; byAccount : [(AccountCode, Nat)]; byCurrency : [(Currency, Nat)] };
  };

  /// One block of the journal log. `hash` covers every other field; `parentHash`
  /// chains blocks; the MMR commits `hash` of every block.
  public type Block = {
    index : Nat;
    timestamp : Nat64;    // chain time (ns) when the block was appended
    caller : Principal;   // principal whose call produced the block
    parentHash : ?Blob;
    hash : Blob;
    event : Event;
  };

  // ─── Views ─────────────────────────────────────────────────────────────────

  public type Balance = {
    account : AccountCode;
    subledger : ?SubledgerKey;
    currency : Currency;
    debitsPosted : Nat;
    creditsPosted : Nat;
    debitsPending : Nat;
    creditsPending : Nat;
  };

  public type TrialBalanceRow = {
    account : AccountCode;
    currency : Currency;
    periodDebits : Nat;
    periodCredits : Nat;
    closingDebits : Nat;     // cumulative through the end of the period
    closingCredits : Nat;
  };

  public type CurrencyTotals = {
    currency : Currency;
    periodDebits : Nat;
    periodCredits : Nat;
    closingDebits : Nat;
    closingCredits : Nat;
  };

  public type TrialBalance = {
    period : PeriodId;
    rows : [TrialBalanceRow];
    totals : [CurrencyTotals];
    balanced : Bool;          // every currency: periodDebits == periodCredits and closingDebits == closingCredits
    postingCount : Nat;       // posted postings booked in this period
  };

  public type MappedRow = {
    row : TrialBalanceRow;
    leadsheet : Text;
    leadsheetName : Text;
    category : Text;
    cycle : Text;
  };

  public type LeadsheetTotal = {
    leadsheet : Text;
    name : Text;
    currency : Currency;
    closingDebits : Nat;
    closingCredits : Nat;
  };

  public type MappedTrialBalance = {
    period : PeriodId;
    mapped : [MappedRow];
    unmapped : [TrialBalanceRow];   // reported, never bucketed
    leadsheets : [LeadsheetTotal];
    balanced : Bool;
  };

  public type GlEntry = {
    index : Nat;              // block index of the posting
    postingDate : Day;
    valueDate : Day;
    subledger : ?SubledgerKey;
    side : Side;
    amount : Nat;
    narration : Text;
    sourceRef : SourceRef;
    counterparts : [AccountCode];   // accounts on the other side, same currency
  };

  public type GlAccount = {
    account : AccountCode;
    currency : Currency;
    openingDebits : Nat;
    openingCredits : Nat;
    entries : [GlEntry];
    periodDebits : Nat;
    periodCredits : Nat;
    closingDebits : Nat;
    closingCredits : Nat;
  };

  public type GeneralLedger = { period : PeriodId; accounts : [GlAccount]; entryCount : Nat };

  public type PostingStatus = {
    #posted;
    #pending : { expiresAt : ?Nat64 };
    #postedFromPending : { by : Nat; resolution : Resolution };
    #voided : { by : Nat; reason : VoidReason };
  };

  public type PostingView = {
    index : Nat;
    timestamp : Nat64;
    caller : Principal;
    record : PostingRecord;
    status : PostingStatus;
    reversedBy : ?Nat;
    correctedBy : [Nat];
  };

  public type PendingView = {
    index : Nat;
    record : PostingRecord;
    expiresAt : ?Nat64;
    caller : Principal;
  };

  // ─── Results and errors ────────────────────────────────────────────────────

  public type PostResult = {
    index : Nat;
    duplicate : Bool;    // true when an earlier submission with the same key was returned
    hash : Blob;
  };

  public type PostError = {
    #NotActivated : { activationHeight : Nat64; height : Nat64 };
    #Unauthorized;
    #AnonymousCaller;
    #PosterNotScopedForAccount : { poster : Principal; account : AccountCode };
    #Unbalanced : { currency : Currency; debits : Nat; credits : Nat };
    #TooFewLegs : { count : Nat };
    #TooManyLegs : { count : Nat; max : Nat };
    #ZeroAmountLeg : { index : Nat };
    #SubledgerKeyInvalid : { index : Nat; size : Nat };
    #UnknownAccount : { account : AccountCode };
    #AccountClosed : { account : AccountCode };
    #UnknownCurrency : { currency : Currency };
    #UnknownPeriod : { period : PeriodId };
    #PeriodClosed : { period : PeriodId };
    #PostingDateOutsidePeriod : { period : PeriodId; postingDate : Day; start : Day; end : Day };
    #PostingDateInFuture : { postingDate : Day; today : Day };
    #ValueDateTooFar : { valueDate : Day; postingDate : Day; maxDriftDays : Nat };
    #IdempotencyKeyInvalid : { size : Nat };
    #IdempotencyKeyReused : { existing : Nat };
    #NarrationTooLong : { size : Nat; max : Nat };
    #SourceRefInvalid : { reason : Text };
    #UnknownPosting : { index : Nat };
    #NotAPosting : { index : Nat };
    #AlreadyReversed : { original : Nat; reversedBy : Nat };
    #NotPending : { index : Nat };
    #PendingAlreadyResolved : { index : Nat; resolvedBy : Nat };
    #PendingExpired : { index : Nat; expiresAt : Nat64; voidedBy : Nat };
    #ExpiryInPast : { expiresAt : Nat64; now : Nat64 };
    #ExceedsCredits : { account : AccountCode; subledger : ?SubledgerKey; currency : Currency; debitsPosted : Nat; debitsPending : Nat; creditsPosted : Nat; amount : Nat; allowance : Nat };
    #ExceedsDebits : { account : AccountCode; subledger : ?SubledgerKey; currency : Currency; creditsPosted : Nat; creditsPending : Nat; debitsPosted : Nat; amount : Nat; allowance : Nat };
    #AccountIsHeader : { account : AccountCode };
    #ManualEntriesNotAllowed : { account : AccountCode };
    #DuplicateKeyInBatch : { first : Nat; index : Nat };
    #ValueDateNotBusinessDay : { valueDate : Day };
    #NoBusinessDate;
    #NoOpenPeriodForBusinessDate : { businessDate : Day };
    #BatchTooLarge : { count : Nat; max : Nat };
    #EmptyBatch;
  };

  /// Failure of an atomic batch: the position of the offending posting and its error.
  public type BatchError = { index : Nat; error : PostError };

  public type ConfigError = {
    #Unauthorized;
    #AnonymousCaller;
    #InvalidAccountCode : { code : AccountCode; reason : Text };
    #AccountExists : { code : AccountCode };
    #UnknownAccount : { code : AccountCode };
    #AccountAlreadyClosed : { code : AccountCode };
    #AccountHasBalance : { code : AccountCode; subledger : ?SubledgerKey; currency : Currency; debits : Nat; credits : Nat };
    #AccountHasPending : { code : AccountCode; count : Nat };
    #InvalidCurrency : { code : Currency; reason : Text };
    #CurrencyExists : { code : Currency };
    #InvalidPeriod : { id : PeriodId; reason : Text };
    #PeriodExists : { id : PeriodId };
    #PeriodOverlaps : { id : PeriodId; overlapping : PeriodId };
    #UnknownPeriod : { id : PeriodId };
    #PeriodAlreadyClosed : { id : PeriodId };
    #EarlierPeriodOpen : { id : PeriodId; earlier : PeriodId };
    #PendingPostingsOutstanding : { id : PeriodId; count : Nat };
    #InvalidLeadsheetSchema : { reason : Text };
    #BusinessDateBackwards : { current : Day; requested : Day };
    #BusinessDateInFuture : { requested : Day; today : Day };
    /// Under `#businessDate` a roll advances by at most the recorded bound.
    #BusinessDateRollTooFar : { current : Day; requested : Day; maxRollDays : Nat };
    /// `#businessDate` needs a business date: none is set and the act carries none; or the act carries one
    /// under `#substrateClock`, where the roll command is the way; or the bound is 0 under `#businessDate`.
    #InvalidCalendarAuthority : { reason : Text };
    #InvalidCalendar : { reason : Text };
    #PosterExists : { poster : Principal };
    #UnknownPoster : { poster : Principal };
    #InvalidPosterScope : { reason : Text };
    #InvalidBalanceLimit : { reason : Text };
    #InvalidAccountAttributes : { reason : Text };
    #InvalidPrincipal;
  };

  // ─── Limits (policy constants, enforced at admission) ──────────────────────

  public let MAX_LEGS : Nat = 128;
  public let MAX_NARRATION_BYTES : Nat = 512;
  public let MAX_IDEMPOTENCY_KEY_BYTES : Nat = 64;
  public let MAX_SOURCE_KIND_BYTES : Nat = 32;
  public let MAX_SOURCE_ID_BYTES : Nat = 128;
  public let MAX_ACCOUNT_NAME_BYTES : Nat = 128;
  public let MAX_VALUE_DATE_DRIFT_DAYS : Nat = 366;
  public let MAX_PERIOD_ID_BYTES : Nat = 16;
  public let MAX_BATCH : Nat = 256;
  public let MAX_SUBLEDGER_BYTES : Nat = 64;
  public let MAX_POSTER_SCOPE_ACCOUNTS : Nat = 256;
  /// Source kinds that count as a manual correction for the manual-entry flag.
  public let MANUAL_SOURCE_KINDS : [Text] = ["manual", "manual-rev", "manual-party", "correction"];
  public let DEFAULT_ACCOUNT_ATTRIBUTES : AccountAttributes = { usage = #detail; manualEntriesAllowed = true; parent = null };

  /// Activation gate default: the journal refuses financial writes until an
  /// administrator sets an activation height at or below the current height.
  public let ACTIVATION_OFF : Nat64 = 0xFFFF_FFFF_FFFF_FFFF;

  public func sideText(s : Side) : Text { switch (s) { case (#debit) "debit"; case (#credit) "credit" } };
};
