/// ReportTypes.mo; the reporting layer's vocabulary.
///
/// Three things in here are decisions rather than shapes, and they are stated where a
/// reader meets them:
///
///   1. **A report definition is closed data and carries no expression.** There is no
///      stored predicate, no SQL, no evaluator. A definition names row dimensions from a
///      fixed set, filters from three fixed operators, and measures from a fixed set of
///      folds the journal already computes. Apache Fineract stores SQL in a table and
///      executes it; the right amount of flexibility for a database and the wrong thing
///      inside a canister holding money, because a stored expression is an
///      arbitrary-behaviour surface and a report that can be slow can be a denial of
///      service.
///   2. **A report is identified by (definition hash, parameters, journal height).**
///      Evaluating it at that height is deterministic, so any party can recompute it, and
///      two parties who disagree about a figure resolve it by recomputing rather than by
///      comparing files.
///   3. **Nothing here forms a judgement.** Every mapping, risk weight, run-off factor
///      and rounding is declared data recorded in a block. The engine maps, sums and
///      certifies.

import JT "mo:journal/JournalTypes";

import I "Interest";

module {

  public type Day = JT.Day;
  public type BookId = Text;
  public type AccountCode = JT.AccountCode;
  public type Currency = JT.Currency;
  public type PeriodId = JT.PeriodId;

  // ═══════════════════════════════════════════════════════════
  //  THE REPORT DEFINITION
  // ═══════════════════════════════════════════════════════════

  /// What a row of a report is keyed by. Two sources of rows exist and a definition uses
  /// one of them, which `Reports.sourceOf` decides and `Reports.validateDef` enforces:
  ///
  ///   * the **chart** source; one row per (account, currency) of the journal's trial
  ///     balance, which is every figure a primary statement or a regulatory return is
  ///     built from;
  ///   * the **sub-ledger** source; one row per product account, which is what a
  ///     breakdown by book, product or counterparty class needs, because a posting in the
  ///     journal carries a sub-ledger key and not a branch.
  ///
  /// Mixing the two in one definition is refused rather than silently answered from one
  /// of them.
  public type Dimension = {
    #account;
    #accountRange : { lo : Nat; hi : Nat };    // inclusive four-digit prefixes
    #leadsheet;
    #category;
    #currency;
    #book;
    #product;
    /// A **declared** classification held on the party as an extension field: the schema
    /// and the field name. The value is an enumerated label the institution declared, not
    /// anything derived from personal data, which this layer holds only as commitments.
    /// A party carrying no value for the field is keyed `unclassified` and reported as
    /// such; never bucketed into a default.
    #counterpartyClass : { schema : Text; field : Text };
  };

  /// The three operators, and only these three.
  public type FilterOp = {
    #eq : Text;
    #inSet : [Text];
    #range : { lo : Nat; hi : Nat };
  };

  public type Filter = { dimension : Dimension; op : FilterOp };

  /// Every measure is a fold the journal already computes. None of them is a formula.
  public type Measure = {
    #periodDebits;
    #periodCredits;
    #closingDebits;
    #closingCredits;
    /// Closing debits less closing credits, expressed on the account's normal side, so a
    /// liability's movement reads positive when it grows.
    #netMovement;
    #closingBalance;
    #entryCount;
    #balanceAsOf : Day;
    #valueDatedBalance : Day;
  };

  public type Ordering = {
    #byRowKey;
    #byCategoryThenAccount;
    #byMeasureDescending : Nat;      // the index of the measure to order by
  };

  /// Presentation scaling. A report in thousands is still exact about what it did: the
  /// scale and the rounding mode are part of the definition and therefore part of its
  /// hash, and the unscaled figure is always recoverable from the journal.
  public type Scale = { #minorUnits; #units; #thousands; #millions };

  public type Comparative = { #none; #priorPeriod; #priorYear };

  /// The currency view. `#native` is the journal's own, always exact. `#functional` is an
  /// IAS 21 presentation translation and **posts nothing**: monetary items at the closing
  /// rate, non-monetary at historic, income and expense at the period's rate, and the
  /// translation difference shown as its own line rather than absorbed into a total.
  public type CurrencyView = { #native; #functional };

  public type ReportDef = {
    id : Text;
    version : Nat;
    title : Text;
    rows : [Dimension];
    filters : [Filter];
    measures : [Measure];
    ordering : Ordering;
    scale : Scale;
    comparatives : Comparative;
    /// The declared cost bound. The engine sizes the slice **before** evaluating and
    /// refuses a definition whose slice exceeds this, naming the size, rather than
    /// trapping halfway through.
    maxSlice : Nat;
  };

  /// What an evaluation is asked for. Together with the definition's hash and the journal
  /// height, this is the report's identity.
  public type ReportParams = {
    book : BookId;
    period : PeriodId;
    view : CurrencyView;
    /// The currency a `#functional` view translates into; ignored for `#native`.
    functional : ?Currency;
  };

  // ═══════════════════════════════════════════════════════════
  //  WHAT AN EVALUATION PRODUCES
  // ═══════════════════════════════════════════════════════════

  /// One value of one dimension, as a label. Labels are text because a row key has to be
  /// canonically encodable and comparable across dimensions of different kinds; the
  /// underlying figures are never text.
  public type RowKey = [Text];

  public type Cell = { measure : Measure; amount : Int; currency : ?Currency };

  public type ReportRow = {
    key : RowKey;
    cells : [Cell];
    /// The comparative row, when the definition asked for one.
    comparative : ?[Cell];
  };

  public type ReportTotals = { currency : ?Currency; cells : [Cell] };

  public type Report = {
    definition : Text;
    version : Nat;
    definitionHash : Blob;
    params : ReportParams;
    /// The journal height the evaluation read. Two reports that differ are explained by
    /// their heights rather than by suspicion.
    atHeight : Nat;
    /// The bank height the evaluation read at, as context; which registration a reader was
    /// looking at. It is **not** part of the report's hashed identity: that is (definition
    /// hash, parameters, journal height), and the definition hash already pins the arithmetic.
    atBankHeight : Nat;
    rows : [ReportRow];
    totals : [ReportTotals];
    /// Rows whose dimension value could not be resolved; an account in no leadsheet, a
    /// party with no declared classification. Reported, never bucketed.
    unresolved : [ReportRow];
    /// The canonical bytes' hash, which is what is committed into the certified tree.
    contentHash : Blob;
    rowCount : Nat;
    sliceSize : Nat;
  };

  // ═══════════════════════════════════════════════════════════
  //  PRIMARY STATEMENTS
  // ═══════════════════════════════════════════════════════════

  public type StatementLine = {
    caption : Text;
    /// The accounts that make the line up, so a figure decomposes without guesswork.
    accounts : [AccountCode];
    amount : Int;
    comparative : ?Int;
  };

  public type IncomeStatement = {
    book : BookId;
    period : PeriodId;
    currency : Currency;
    view : CurrencyView;
    income : [StatementLine];
    expense : [StatementLine];
    totalIncome : Int;
    totalExpense : Int;
    /// Income less expense, for the period.
    result : Int;
    /// The same figure read from the movement in retained earnings, and whether the two
    /// agree. A statement that cannot reconcile its own result to the equity movement
    /// says so on its face.
    retainedEarningsMovement : ?Int;
    reconciles : Bool;
    atHeight : Nat;
  };

  public type BalanceSheet = {
    book : BookId;
    period : PeriodId;
    currency : Currency;
    view : CurrencyView;
    assets : [StatementLine];
    liabilities : [StatementLine];
    equity : [StatementLine];
    totalAssets : Int;
    totalLiabilities : Int;
    totalEquity : Int;
    /// The period's result, carried as an explicit line until the year-end roll moves it
    /// into retained earnings.
    periodResult : Int;
    /// `assets = liabilities + equity + result`; **asserted**, not presented. A balance
    /// sheet that does not balance is refused rather than printed.
    balances : Bool;
    /// Present only in a `#functional` view, and never absorbed into a total.
    translationDifference : ?Int;
    atHeight : Nat;
  };

  /// Indirect method, from the accounts the chart declares as cash and cash equivalents.
  public type CashFlow = {
    book : BookId;
    period : PeriodId;
    currency : Currency;
    operating : [StatementLine];
    investing : [StatementLine];
    financing : [StatementLine];
    totalOperating : Int;
    totalInvesting : Int;
    totalFinancing : Int;
    netMovement : Int;
    openingCash : Int;
    closingCash : Int;
    /// `opening + net = closing`; asserted, like the balance sheet's identity.
    reconciles : Bool;
    atHeight : Nat;
  };

  /// Which accounts a statement treats as what. Declared per deployment and recorded, so
  /// no classification is inferred from an account's name or code.
  public type StatementMap = {
    /// Cash and cash equivalents, for the cash-flow statement.
    cash : [AccountCode];
    /// Retained earnings, for the income statement's reconciliation.
    retainedEarnings : AccountCode;
    /// Accounts whose movement is an investing or a financing flow; everything else that
    /// is not cash is operating.
    investing : [AccountCode];
    financing : [AccountCode];
    /// Monetary accounts, for the IAS 21 translation. Non-monetary items translate at the
    /// historic rate and monetary ones at the closing rate, and which is which is a
    /// declared classification rather than a judgement the engine makes.
    monetary : [AccountCode];
  };

  // ═══════════════════════════════════════════════════════════
  //  REGULATORY RETURNS
  // ═══════════════════════════════════════════════════════════

  /// How a return line gets its figure. Three shapes and no more: a sum of mapped
  /// accounts, a difference of two lines, or a ratio of two lines with a **declared**
  /// behaviour when the denominator is zero.
  public type LineSource = {
    #sumOfAccounts : { accounts : [AccountCode]; measure : Measure };
    #sumOfRanges : { ranges : [{ lo : Nat; hi : Nat }]; measure : Measure };
    #sumOfLines : { lines : [Text] };
    #difference : { minuend : Text; subtrahend : Text };
    #ratio : { numerator : Text; denominator : Text; scale : Nat; whenZero : ZeroDenominator };
    /// A figure the institution declares rather than computes; a risk weight applied to
    /// a line, a run-off factor, a haircut. The weight is data; the multiplication is
    /// arithmetic.
    #weighted : { line : Text; numerator : Nat; denominator : Nat };
    #declared : { value : Int };
  };

  public type ZeroDenominator = { #reportZero; #reportUnmeasurable; #refuse };

  public type ReturnLine = {
    code : Text;
    caption : Text;
    source : LineSource;
    /// Where the line sits in the filed instance: the XBRL element or SDMX concept.
    binding : ?Text;
  };

  public type ReturnTemplate = {
    id : Text;
    version : Nat;
    title : Text;
    authority : Text;                 // "CBE", "BCBS", …
    currency : Currency;
    lines : [ReturnLine];
    /// The declared taxonomy or data structure the instance is filed against.
    taxonomy : ?Text;
    /// The parameters the template's weights are taken from, recorded so a filing's basis
    /// is part of its identity.
    parameters : [{ name : Text; numerator : Nat; denominator : Nat }];
  };

  public type ReturnValue = { code : Text; caption : Text; amount : Int; measurable : Bool; binding : ?Text };

  public type ReturnResult = {
    template : Text;
    version : Nat;
    templateHash : Blob;
    book : BookId;
    period : PeriodId;
    currency : Currency;
    values : [ReturnValue];
    /// Accounts the template maps to no line at all, with their balances. A return whose
    /// unmapped total is non-zero is **flagged on its face**; a regulator receiving that
    /// is being told the truth; one receiving a return whose residual was swept into
    /// "other assets" is not.
    unmapped : [{ account : AccountCode; currency : Currency; amount : Int }];
    unmappedTotal : Int;
    flagged : Bool;
    atHeight : Nat;
    contentHash : Blob;
  };

  // ═══════════════════════════════════════════════════════════
  //  STATEMENTS (camt.052 / 053 / 054)
  // ═══════════════════════════════════════════════════════════

  /// The ISO 20022 balance kinds a statement must state. `CLAV` differs from `CLBD` by
  /// exactly the reservations the journal is holding, which a conventional core computes
  /// by subtracting a hold table.
  public type BalanceType = { #OPBD; #CLBD; #ITBD; #PRCD; #CLAV };

  public type StatementBalance = { kind : BalanceType; debits : Nat; credits : Nat; net : Int };

  /// The figures a statement cut recorded, which is what a camt.053 states as `OPBD` and
  /// `CLBD`. Taken from the end-of-day batch cut rather than recomputed, so they do not move when a
  /// posting is later value-dated into the cut day.
  public type StatementCutFigures = {
    openingDebits : Nat;
    openingCredits : Nat;
    closingDebits : Nat;
    closingCredits : Nat;
  };

  public type StatementKind = {
    #camt053 : { cut : Day };         // from the end-of-day batch statement cut: a record, not a re-derivation
    #camt052 : { asOf : Day };        // intraday, from the live fold
    #camt054 : { movement : Nat };    // one notification, naming the journal block
  };

  public type StatementRef = {
    /// The register key. A re-issued statement is identifiably the same statement.
    id : Text;
    account : Nat;
    kind : StatementKind;
    currency : Currency;
    period : PeriodId;
    balances : [StatementBalance];
    /// Per entry, the journal block it came from; so one line can be verified against
    /// the certified root without being given the rest of the book.
    entryBlocks : [Nat];
    issued : Nat;                     // how many times this statement has been issued
    contentHash : Blob;
    atHeight : Nat;
  };

  // ═══════════════════════════════════════════════════════════
  //  GENERAL-LEDGER EXPORT
  // ═══════════════════════════════════════════════════════════

  public type ExportShape = {
    #safT;                 // OECD Standard Audit File for Tax, general-ledger entries
    #aicpaAds;             // AICPA Audit Data Standards GL and trial balance
    #normalisedTrialBalance;   // the audit product's own contract, with proofs
  };

  /// A line of the audit product's normalised trial balance. `proof` is what makes the
  /// auditor's population-completeness assertion a computation rather than a management
  /// representation: today every import of that contract populates `lines_with_proof` as
  /// `representation`, because no producer could do better.
  public type ExportLine = {
    account : AccountCode;
    currency : Currency;
    openingDebits : Nat;
    openingCredits : Nat;
    periodDebits : Nat;
    periodCredits : Nat;
    closingDebits : Nat;
    closingCredits : Nat;
    /// The journal blocks this line folds over, each provable against the certified root.
    blocks : [Nat];
    proven : Bool;
  };

  public type ExportResult = {
    shape : ExportShape;
    book : BookId;
    period : PeriodId;
    lines : [ExportLine];
    linesWithProof : Nat;
    evidenceGrade : Text;          // "proven" when every line carries its blocks
    atHeight : Nat;
    contentHash : Blob;
  };

  // ═══════════════════════════════════════════════════════════
  //  THE EVENT FEED
  // ═══════════════════════════════════════════════════════════

  /// A consumer asks for events after a cursor and receives them with the certified tip,
  /// so a consumer that trusts nothing can verify it received a prefix of the real
  /// sequence and detect a gap or a rewrite. That is strictly stronger than a webhook,
  /// which a consumer must trust.
  public type FeedEvent = {
    cursor : Nat;
    /// The bank block this event reports, so the event and its proof are the same object.
    block : Nat;
    kind : Text;
    book : ?BookId;
  };

  public type FeedEndpoint = {
    url : Text;
    /// Declared retry schedule, in seconds between attempts.
    retries : [Nat];
    active : Bool;
  };

  public type DeadLetter = { cursor : Nat; endpoint : Text; attempts : Nat; reason : Text };

  // ═══════════════════════════════════════════════════════════
  //  EVENTS, ERRORS, VIEWS
  // ═══════════════════════════════════════════════════════════

  public type ReportEvent = {
    #reportDefinitionRegistered : { definition : ReportDef; hash : Blob };
    #returnTemplateRegistered : { template : ReturnTemplate; hash : Blob };
    #statementMapSet : { book : BookId; map : StatementMap };
    /// A report's canonical bytes committed into the certified tree. The artefact that
    /// leaves the building can be proven to be the report the books produced.
    #reportCertified : {
      kind : Text;                 // "report", "return", "statement", "export"
      id : Text;
      book : BookId;
      period : PeriodId;
      atHeight : Nat;
      contentHash : Blob;
      rows : Nat;
    };
    #statementIssued : { statement : StatementRef };
    #feedEndpointSet : { endpoint : FeedEndpoint };
    #feedDeadLettered : { letter : DeadLetter };
  };

  public type ReportError = {
    #UnknownDefinition : { definition : Text; version : Nat };
    #DefinitionExists : { definition : Text; version : Nat };
    #InvalidDefinition : { reason : Text };
    #MixedRowSources : { reason : Text };
    #SliceTooLarge : { slice : Nat; bound : Nat };
    #UnknownTemplate : { template : Text; version : Nat };
    #TemplateExists : { template : Text; version : Nat };
    #InvalidTemplate : { reason : Text };
    #AccountMappedTwice : { account : AccountCode; first : Text; second : Text };
    #UnknownLine : { line : Text };
    #CircularLine : { line : Text };
    #ZeroDenominator : { line : Text };
    #NoStatementMap : { book : BookId };
    #DoesNotBalance : { assets : Int; liabilities : Int; equity : Int; result : Int };
    #DoesNotReconcile : { stated : Int; computed : Int };
    #UnknownPeriod : { period : PeriodId };
    #NoFunctionalCurrency;
    #MissingRate : { currency : Currency; asOf : Day };
    #UnknownStatement : { id : Text };
    #EndpointNotRecorded : { url : Text };
    #InvalidEndpoint : { reason : Text };
  };

  // ─── bounds ────────────────────────────────────────────────────────────────

  public let MAX_DEF_ID_BYTES : Nat = 32;
  public let MAX_DIMENSIONS : Nat = 4;
  public let MAX_MEASURES : Nat = 8;
  public let MAX_FILTERS : Nat = 8;
  public let MAX_SET_MEMBERS : Nat = 64;
  public let MAX_RETURN_LINES : Nat = 256;
  public let MAX_SLICE : Nat = 20_000;
  public let MAX_REPORT_ROWS : Nat = 5_000;
  public let MAX_ENDPOINTS : Nat = 8;
  public let MAX_DEAD_LETTERS : Nat = 512;
  public let MAX_RETRIES : Nat = 8;

  /// The reporting layer posts nothing, so it carries no money-visible feature gate. It
  /// does commit report hashes into the certified tree, which is a recorded act and is
  /// gated on the same activation as the rest of the close layer would be if it posted;
  /// stated here so the absence is deliberate rather than an omission.
  public let FEATURE_REPORTING : Text = "report.certify";

  public type Rounding = I.Rounding;
};
