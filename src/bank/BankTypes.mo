/// BankTypes.mo — the vocabulary of the banking domain layer.
///
/// Two logs live in this canister. The journal (the pinned `thebes-ledger-core`
/// submodule) records what moved: postings, balances, periods, proofs. This
/// module's `Event` records *why it was allowed to move*: which permission was
/// held, which policy applied, who proposed a command, who approved it, and
/// which postings it produced. Both logs are hash-chained and Merkle-committed,
/// and one certified tree carries both roots (`BankCert.mo`), so a posting can be
/// proven and so can the authority behind it.
///
/// Every event is one immutable block. The domain state — books, roles, grants,
/// policies, proposals, feature activations — is a pure fold over those blocks.
///
/// Amounts are natural numbers of minor units, as in the journal. Nothing here
/// holds a balance: a balance is a journal balance.

import Principal "mo:core/Principal";

import JT "mo:journal/JournalTypes";
import PT "PartyTypes";
import ProdT "ProductTypes";
import CT "CloseTypes";
import BT "BatchTypes";
import RepT "ReportTypes";
import IdxT "IndexTypes";
import AT "ArchiveTypes";
import MT "MonitoringTypes";
import AlT "AlertTypes";
import ColT "CollectionsTypes";
import OT "OriginationTypes";
import FaT "FacilityTypes";
import TeT "TellerTypes";
import TrT "TradeTypes";
import IT "IslamicTypes";
import TT "TreasuryTypes";
import CdT "CardTypes";
import PkT "PackingTypes";
import ST "ShardTypes";
import SeT "SettlementTypes";
import PayT "PaymentsTypes";
import FT "FspiopTypes";
import Iban "Iban";

module {

  // ─── Identifiers ───────────────────────────────────────────────────────────

  /// An office / branch / book of account. One to thirty-two ASCII characters
  /// from [A-Za-z0-9-_.]. The root book of a deployment has no parent.
  public type BookId = Text;

  /// A role identifier, same grammar as a book id.
  public type RoleId = Text;

  /// A permission identifier: "<resource>.<action>", e.g. "product.create".
  /// The catalogue in `Permissions.mo` is the authority for which exist.
  public type PermissionId = Text;

  /// A feature whose money-visible behaviour is gated on an activation height.
  public type FeatureId = Text;

  public type Day = JT.Day;

  // ─── Organisation ──────────────────────────────────────────────────────────

  public type BookStatus = { #active; #closed };

  public type Book = {
    id : BookId;
    name : Text;
    parent : ?BookId;
    status : BookStatus;
    openedAtBlock : Nat;
    closedAtBlock : ?Nat;
  };

  // ─── Permissions and entitlements ──────────────────────────────────────────

  /// The verb set of the catalogue. These are the verbs Apache Fineract's 960
  /// permission rows use (CREATE, READ, UPDATE, DELETE, APPROVE, REJECT,
  /// ACTIVATE, CLOSE, REVERSE) plus the three this layer adds for operations a
  /// bank treats as distinct controls.
  public type Action = {
    #create; #read; #update; #delete;
    #approve; #reject; #activate; #close; #reverse;
    #waive;      // give up a charge or a fee
    #release;    // release a hold
    #breakGlass; // the emergency path of MakerChecker; never an ordinary role
  };

  /// What a permission guards. `#method` names a public update method of the
  /// actor; `#command` names a `Command` variant. `tools/permission_audit.py`
  /// compares both sides against the built Candid interface, so a method with no
  /// permission and a command with no permission each fail the build.
  public type Guards = { #method : Text; #command : Text };

  public type Permission = {
    id : PermissionId;
    resource : Text;
    action : Action;
    guards : Guards;
    /// True when exercising it can cause a journal posting.
    moneyMoving : Bool;
    /// True when the catalogue requires dual authorisation unless a policy
    /// says otherwise. A money-moving permission is dual by default.
    dualByDefault : Bool;
  };

  public type Money = { currency : JT.Currency; amount : Nat };

  /// A grant's scope, evaluated against the operation's own data — never
  /// against what the caller claims. `null` in a dimension means unrestricted.
  public type Scope = {
    books : ?[BookId];
    currencies : ?[JT.Currency];
    /// Maximum total per currency for a single operation.
    ceiling : ?[Money];
    /// Maximum total per currency for one subject in one business date.
    dailyLimit : ?[Money];
  };

  public type Role = {
    id : RoleId;
    name : Text;
    permissions : [PermissionId];
    definedAtBlock : Nat;
  };

  public type Grant = {
    subject : Principal;
    role : RoleId;
    scope : Scope;
    grantedAtBlock : Nat;
  };

  // ─── Maker-checker ─────────────────────────────────────────────────────────

  /// How many approvals a dual-authorised permission needs, who may give them,
  /// and how long a proposal stands.
  public type DualPolicy = {
    permission : PermissionId;
    required : Nat;              // 1 = four eyes, 2 = six eyes, ...
    eligibleRole : RoleId;       // the role an approver must hold
    ttlSeconds : Nat;            // proposal lifetime
  };

  public type ProposalStatus = {
    #awaitingApproval : { approvals : [Principal] };
    #executed : { at : Nat; postings : [Nat] };   // bank block index, journal block indices
    #rejected : { by : Principal; reason : Text };
    #expired;
  };

  // ─── Commands: what a maker proposes and a checker approves ────────────────
  //
  // A command is a structured operation, never a string. The proposal block
  // carries the command *and* the hash of its canonical encoding
  // (`BankCanonical.commandHash`); at execution the hash is re-derived from the
  // recorded command and must equal the hash in every approval. So the bytes the
  // checker approved are the bytes that execute, and a mutation in between is a
  // typed refusal rather than a silent substitution.

  public type ManualEntry = {
    book : BookId;
    /// The journal posting to admit. Its legs, dates, period and idempotency key
    /// are the caller's; the bank adds the source reference naming the command.
    postingDate : Day;
    valueDate : Day;
    period : JT.PeriodId;
    legs : [JT.Leg];
    narration : Text;
    idempotencyKey : Blob;
    correctionOf : ?Nat;
  };

  /// The parts of `#createCustomer`. `screening` has no party: the decision is about the party this act
  /// creates. `lifecycle` is the state the party is left in — `#prospect`, `#pendingKyc` or `#active`
  /// (active needs the documents its due-diligence level requires and a screening that permits movement,
  /// as `setPartyLifecycle` does). An account's `activate` is `setAccountStatus(#active)` after its opening.
  public type CustomerScreening = { listVersion : Text; listRoot : PT.Commitment; decision : { #clear; #hit : { matches : Nat }; #cleared : { reason : Text }; #confirmed }; screener : Principal; justificationCommit : PT.Commitment };
  public type CustomerAccount = { product : ProdT.ProductId; currency : JT.Currency; termDays : ?Nat; allocationOrder : [ProdT.Component]; activate : Bool };
  public type CreateCustomer = {
    party : { kind : PT.PartyKind; salt : Blob; identityCommit : PT.Commitment; dedupCommit : ?PT.Commitment; attributes : [PT.FieldCommit]; book : BookId; cddLevel : PT.CddLevel; riskRating : PT.RiskRating; pep : Bool; reviewDue : Day };
    documents : [PT.DocumentRef];
    screening : ?CustomerScreening;
    lifecycle : PT.Lifecycle;
    extensions : [PT.ExtensionValue];
    accounts : [CustomerAccount];
    /// The origination application this onboarding fulfils (origination and underwriting): a prospect's open application, which
    /// gains this party. Carried by command encoding 2 and later.
    application : ?Nat;
  };

  /// Money moving on a facility: a drawing funded from, or a rental received into, `funding`.
  public type FacilityMoney = { facility : FaT.FacilityId; amount : Nat; funding : ProdT.Funding; postingDate : Day; valueDate : Day; period : Text; narration : Text };

  public type Command = {
    // ── entitlements (this component's own configuration) ──
    #defineRole : { id : RoleId; name : Text; permissions : [PermissionId] };
    #grantRole : { subject : Principal; role : RoleId; scope : Scope };
    #revokeRole : { subject : Principal; role : RoleId };
    #setDualPolicy : DualPolicy;
    #clearDualPolicy : { permission : PermissionId };
    #openBook : { id : BookId; name : Text; parent : ?BookId };
    #closeBook : { id : BookId };
    #transferBankAdmin : { admin : Principal };
    // ── activation heights: money-visible behaviour, dual-authorised ──
    #setFeatureActivation : { feature : FeatureId; height : Nat64 };
    // ── the embedded journal's configuration, driven through this canister ──
    #journalRegisterCurrency : { code : JT.Currency; minorUnits : Nat8 };
    #journalOpenAccount : { code : JT.AccountCode; name : Text; normalSide : JT.Side; category : JT.Category; constraint : JT.BalanceConstraint };
    #journalCloseAccount : { code : JT.AccountCode };
    #journalOpenPeriod : { id : JT.PeriodId; start : Day; end : Day };
    #journalClosePeriod : { id : JT.PeriodId };
    #journalSetActivationHeight : { height : Nat64 };
    #journalSetLeadsheetSchema : { ranges : [JT.LeadsheetRange] };
    #journalAddPoster : { poster : Principal };
    #journalRemovePoster : { poster : Principal };
    #journalSetPosterScope : { poster : Principal; accounts : ?JT.PosterScope };
    #journalRollBusinessDate : { day : Day };
    #journalSetCalendar : { calendar : ?JT.CalendarConfig };
    /// Where the journal's "today" comes from (`JT.CalendarAuthority`); under `#businessDate` the act carries the
    /// first business date when none is set and the bound a roll may advance by.
    #journalSetCalendarAuthority : { authority : JT.CalendarAuthority; maxRollDays : Nat; businessDate : ?Day };
    // ── money: a manual general-ledger entry ──
    #postManualEntry : ManualEntry;
    #reverseManualEntry : { original : Nat; book : BookId; postingDate : Day; valueDate : Day; period : JT.PeriodId; narration : Text; idempotencyKey : Blob };
    /// A manual entry attributed to a party, so the KYC and screening gate of
    /// party and KYC applies to it. Product accounts carry their party from the product engine onwards;
    /// this is the path that exists before they do.
    #postManualEntryForParty : { party : PT.PartyId; entry : ManualEntry };
    // ── party / CIF and KYC ──
    #createParty : { kind : PT.PartyKind; salt : Blob; identityCommit : PT.Commitment; dedupCommit : ?PT.Commitment; attributes : [PT.FieldCommit]; book : BookId; cddLevel : PT.CddLevel; riskRating : PT.RiskRating; pep : Bool; reviewDue : Day };
    /// Onboarding as one dual act (one dual act): the party, its documents,
    /// the screening decision, the lifecycle it is left in, its extension values and its accounts, approved
    /// once. Planned whole and refused whole: every part is held to the rule its own command is held to,
    /// against the party and accounts as they will be, so nothing is applied unless all of it would be. The
    /// events it records are the same events the separate commands record, one block each, so every
    /// reader of the party and product layers reads them unchanged; the party is its `#partyCreated`
    /// block and each account its `#accountOpened` block, as ever.
    #createCustomer : CreateCustomer;
    #amendParty : { party : PT.PartyId; attributes : [PT.FieldCommit] };
    #setPartyLifecycle : { party : PT.PartyId; to : PT.Lifecycle };
    #setPartyCdd : { party : PT.PartyId; level : PT.CddLevel; riskRating : PT.RiskRating; pep : Bool; reviewDue : Day };
    #addPartyDocument : { party : PT.PartyId; document : PT.DocumentRef };
    #addPartyRelationship : { party : PT.PartyId; relationship : PT.Relationship };
    #setPartyExtension : { party : PT.PartyId; values : [PT.ExtensionValue] };
    #issueIdentifier : { party : PT.PartyId };
    #commitScreeningList : { version : Text; root : PT.Commitment; count : Nat; normalisation : Text };
    #proveScreeningClear : { party : PT.PartyId; listVersion : Text; subject : Blob; proof : PT.AdjacencyProof };
    #recordScreeningDecision : PT.ScreeningDecision;
    #registerSchema : { id : Text; entity : PT.EntityKind; fields : [PT.FieldDef] };
    #registerCollateral : { party : PT.PartyId; kind : PT.CollateralKind; valuation : PT.Valuation; descriptionCommit : PT.Commitment };
    #revalueCollateral : { collateral : PT.CollateralId; valuation : PT.Valuation };
    #allocateCollateral : { collateral : PT.CollateralId; facility : Text; amount : Nat };
    #releaseCollateral : { collateral : PT.CollateralId };
    #addStaff : { principal_ : Principal; book : BookId; title : Text };
    #removeStaff : { principal_ : Principal };
    #setAccountFormat : Iban.Format;
    #setReviewGrace : { days : Nat };
    #pinJwks : PT.Jwks;
    #registerCredential : PT.Credential;
    #revokeCredential : { subject : Principal };
    // ── the product engine ──
    // Configuration: no money moves, so a product can be registered and an
    // account opened below every activation height.
    #registerProduct : { id : ProdT.ProductId; name : Text; terms : ProdT.ProductTerms };
    /// An amendment registers the **next version**; the old version is retained
    /// and every account stays bound to the version it was opened under.
    #amendProduct : { id : ProdT.ProductId; name : Text; terms : ProdT.ProductTerms };
    #closeProductToNewAccounts : { id : ProdT.ProductId; version : ProdT.ProductVersion };
    #openAccount : { product : ProdT.ProductId; party : PT.PartyId; currency : JT.Currency; termDays : ?Nat; allocationOrder : [ProdT.Component] };
    #setAccountStatus : { account : ProdT.AccountId; to : ProdT.AccountStatus };
    /// The only way an account's product version changes, and a recorded decision.
    #migrateAccount : { account : ProdT.AccountId; to : ProdT.ProductVersion };
    #openTill : { till : ProdT.TillId; book : BookId; currency : JT.Currency; holder : Principal; product : ProdT.ProductId };
    #closeTill : { till : ProdT.TillId };
    // Money-visible: each sits behind an activation height defaulting to off.
    #grantFacility : { account : ProdT.AccountId; limit : Nat };
    #depositToAccount : MoneyMove;
    #withdrawFromAccount : MoneyMove;
    #transferBetweenAccounts : { from : ProdT.AccountId; to : ProdT.AccountId; amount : Nat; postingDate : Day; valueDate : Day; period : JT.PeriodId; narration : Text };
    #applyCharge : { account : ProdT.AccountId; charge : Text; occurrence : Day; base : ProdT.ChargeBase; postingDate : Day; valueDate : Day; period : JT.PeriodId; narration : Text };
    #waiveCharge : { account : ProdT.AccountId; charge : Text; occurrence : Day; postingDate : Day; valueDate : Day; period : JT.PeriodId; reason : Text };
    /// One aggregated accrual posting per product, currency and business date.
    #postAccrual : { product : ProdT.ProductId; currency : JT.Currency; day : Day; period : JT.PeriodId; narration : Text };
    /// Capitalisation: the accrued figure per account is credited and the accrued
    /// control relieved, in as many postings as the journal's leg bound needs.
    #capitaliseInterest : { product : ProdT.ProductId; currency : JT.Currency; to : Day; postingDate : Day; period : JT.PeriodId; narration : Text };
    #disburseLoan : MoneyMove;
    #repayLoan : MoneyMove;
    #rescheduleLoan : { account : ProdT.AccountId; effective : Day; terms : ProdT.ScheduleTerms; rate : ProdT.Rate };
    #setProvision : { account : ProdT.AccountId; asOf : Day; postingDate : Day; period : JT.PeriodId; narration : Text };
    #writeOffLoan : { account : ProdT.AccountId; postingDate : Day; valueDate : Day; period : JT.PeriodId; narration : Text };
    #recordRecovery : MoneyMove;
    #redeemTermDeposit : MoneyMove;
    #allocateCashToTill : { till : ProdT.TillId; amount : Nat; postingDate : Day; valueDate : Day; period : JT.PeriodId; narration : Text };
    #returnCashFromTill : { till : ProdT.TillId; amount : Nat; postingDate : Day; valueDate : Day; period : JT.PeriodId; narration : Text };
    #settleTill : { till : ProdT.TillId; declared : Nat; postingDate : Day; valueDate : Day; period : JT.PeriodId; narration : Text };
    // ── value dating, foreign currency and the close ──
    // Configuration: declares what the close will compute from, and moves no money.
    #setFunctionalCurrency : { currency : JT.Currency };
    #setFxPair : { pair : CT.PositionPair };
    #setFxRate : { rate : CT.Rate };
    #setBackValueWindow : { window : CT.BackValueWindow };
    /// A named day a book may be back-valued into beyond its free window. Recorded,
    /// so "who allowed this back-valued entry" is answerable by replay.
    #approveBackValue : { book : BookId; valueDate : Day; reason : Text };
    #openDeferralSchedule : { schedule : CT.Schedule };
    // Money-visible: each behind its own activation height.
    /// A cross-currency movement, booked as four legs through the currency's position
    /// pair so each currency balances within itself.
    #bookFxDeal : {
      sell : JT.Currency; sellAmount : Nat; sellFrom : CT.Endpoint;
      buy : JT.Currency; buyAmount : Nat; buyTo : CT.Endpoint;
      rateAsOf : Day; postingDate : Day; valueDate : Day; period : JT.PeriodId; narration : Text;
    };
    #realiseFxPosition : {
      currency : JT.Currency; closedPosition : Nat; bookedEquivalent : Nat; proceeds : Nat;
      postingDate : Day; valueDate : Day; period : JT.PeriodId; narration : Text;
    };
    /// The accrual correction a back-dated posting makes necessary: the fold
    /// re-evaluated less what was already booked for the same range.
    #adjustAccrual : {
      product : ProdT.ProductId; currency : JT.Currency; from : Day; to : Day;
      causedBy : Nat; postingDate : Day; period : JT.PeriodId; narration : Text;
    };
    #amortiseDeferral : { schedule : Text; postingDate : Day; valueDate : Day; period : JT.PeriodId; narration : Text };
    // The close, step by step. Each refuses unless its predecessor holds and each is
    // idempotent, so the order is a control rather than a habit.
    #openPeriodEnd : { book : BookId; period : JT.PeriodId };
    #recordClosingRates : { book : BookId; period : JT.PeriodId };
    #markAccrualComplete : { book : BookId; period : JT.PeriodId };
    #revaluePositions : { book : BookId; period : JT.PeriodId; postingDate : Day; narration : Text };
    #amortisePeriodDeferrals : { book : BookId; period : JT.PeriodId; postingDate : Day; narration : Text };
    #reconcilePeriod : { book : BookId; period : JT.PeriodId };
    #closePeriodEnd : { book : BookId; period : JT.PeriodId };
    /// The fiscal year's result closed to retained earnings. It sits between
    /// `reconciled` and `closed`: income and expense close to retained earnings after
    /// the period's accruals, revaluations and deferrals are in, and before the period
    /// is sealed — because the journal will not book a roll into a closed period, and
    /// booking it before the accruals would close a result that is not yet complete.
    #rollYearEnd : { book : BookId; period : JT.PeriodId; retainedEarnings : JT.AccountCode; narration : Text };
    // ── the end-of-day batch ──
    // Opening a run is an administrative act bound to the business-date roll and is
    // authorised. **Advancing** one is not a command at all: it is an open method on
    // the actor, because the plan is fixed when the run opens, so an advancing caller
    // cannot choose what is posted — only that progress happens.
    #setRetryPolicy : { policy : BT.RetryPolicy };
    #defineStandingInstruction : { instruction : BT.StandingInstruction };
    #cancelStandingInstruction : { id : Text };
    #openEndOfDay : { book : BookId; businessDate : Day; shardSize : Nat };
    /// An exception on the run's report, signed off. A failure the batch cannot repair
    /// by re-attempting it — a standing instruction the customer never funded, a till
    /// nobody settled — has to be answerable by a person, because the alternative is a
    /// period that can never close. The justification is recorded with the act, and a
    /// sign-off for a failure the run is not carrying is refused, so this cannot be used
    /// to assert that something was dealt with when it was not.
    #resolveBatchFailure : { book : BookId; businessDate : Day; item : Nat; entity : Text; justification : Text };
    // ── regulatory reporting and general-ledger export ──
    //
    // Reporting reads; none of these posts. What they write is the registration of the data
    // a report is computed from, and the record that an artefact was certified — which is
    // what makes a filed file provable rather than asserted.
    #registerReportDefinition : { definition : RepT.ReportDef };
    #registerReturnTemplate : { template : RepT.ReturnTemplate };
    #setStatementMap : { book : BookId; map : RepT.StatementMap };
    /// Evaluate a report at the current height and record its content hash. The hash goes
    /// into a bank block, and the bank's certified root already covers every bank block, so
    /// the artefact is proven the way a posting is.
    #certifyReport : { definition : Text; version : Nat; book : BookId; period : JT.PeriodId; view : RepT.CurrencyView; functional : ?JT.Currency };
    #certifyReturn : { template : Text; version : Nat; book : BookId; period : JT.PeriodId };
    #certifyExport : { shape : RepT.ExportShape; book : BookId; period : JT.PeriodId };
    #issueStatement : { account : ProdT.AccountId; kind : RepT.StatementKind; period : JT.PeriodId };
    #setFeedEndpoint : { endpoint : RepT.FeedEndpoint };
    /// A push that failed its declared retries. Recorded so it blocks nothing and is visible,
    /// which is the whole difference between a dead letter and a lost event.
    #recordFeedDeadLetter : { letter : RepT.DeadLetter };
    // ── indexing and bounded queries ──
    //
    // The indexes themselves are derived from the log and need no command. What does is the one
    // declared decision that gives a key its meaning: which registered party extension the
    // counterparty-class index keys on. `null` stops classifying new postings and is recorded for
    // the same reason setting one is.
    #setCounterpartyClassDimension : { dimension : ?IdxT.ClassDimension };
    // ── archive contracts ──
    //
    // The decisions of the archive component. Driving a spawn through its steps is not a command
    // (`ArchiveTypes.mo`); what is dual-authorised is what an archive child runs, who controls it,
    // that one is created, that an attempt made nothing, and that a child found or deployed
    // outside the flow is the bank's.
    #pinArchiveImage : { sha256 : Blob; bytes : Nat; name : Text };
    #setArchiveControllers : { controllers : [Principal] };
    #spawnArchive : { purpose : Text };
    #abandonArchiveSpawn : { spawn : Nat; reason : Text };
    #attachArchiveChild : { spawn : Nat; cid : Nat64 };
    #adoptArchiveChild : { cid : Nat64; moduleHash : Blob; controllers : [Principal]; purpose : Text };
    // ── monitoring: the closed rule set, as declared data ──
    #defineMonitoringRule : { id : MT.RuleId; currency : ?Text; spec : MT.RuleSpec };
    #retireMonitoringRule : { id : MT.RuleId };
    // ── alerts: the review of what monitoring found ──
    #clearAlert : { alert : AlT.AlertId; reason : Text };
    #escalateAlert : { alert : AlT.AlertId; reportRef : Text };
    // ── collections and recovery (collections and recovery): the decided transitions of a troubled exposure's life ──
    #setCollectionsPolicy : ColT.Policy;
    #markUnlikelyToPay : { account : ProdT.AccountId; reason : Text };
    #recordCollectionAction : { account : ProdT.AccountId; action : ColT.Action; outcome : Text; next : ?Day };
    #recordPromiseToPay : { account : ProdT.AccountId; amount : Nat; by : Day };
    #assignCollector : { account : ProdT.AccountId; staff : Principal };
    #closeRecovery : { account : ProdT.AccountId };
    // ── origination and underwriting (origination and underwriting): an application's life from the ask to the drawing ──
    #setOriginationPolicy : OT.Policy;
    #setAffordabilityModel : OT.AffordabilityModel;
    #setScorecard : OT.Scorecard;
    #registerPasskey : { party : PT.PartyId; credentialId : Blob; publicKeySpki : Blob };
    #openApplication : { party : ?PT.PartyId; book : BookId; request : OT.Request; channel : Text };
    #recordApplicationData : { application : OT.ApplicationId; facts : OT.Facts; commitments : [(Text, PT.Commitment)] };
    #assessAffordability : { application : OT.ApplicationId };
    #requestBureauReport : { application : OT.ApplicationId; bureau : Text; consentCommit : PT.Commitment };
    #scoreApplication : { application : OT.ApplicationId };
    #underwrite : { application : OT.ApplicationId; decision : OT.Decision; rationale : Text };
    #issueOffer : { application : OT.ApplicationId; terms : OT.OfferTerms };
    #acceptOffer : { application : OT.ApplicationId; assertion : OT.PasskeyAssertion };
    #declineOffer : { application : OT.ApplicationId };
    #recordDocument : { application : OT.ApplicationId; kind : OT.DocumentKind; sha256 : Blob; signed : ?OT.PasskeyAssertion };
    #recordConditionsMet : { application : OT.ApplicationId; conditions : [Text] };
    #fulfilApplication : { application : OT.ApplicationId };
    #withdrawApplication : { application : OT.ApplicationId; reason : Text };
    // ── corporate lending (corporate lending): facilities, drawings, syndication, leases, receivables, covenants, pricing ──
    #openFacility : FaT.Terms;
    #drawdown : FacilityMoney;
    #transferParticipation : { facility : FaT.FacilityId; from : PT.PartyId; to : PT.PartyId; bps : Nat };
    #distributeToParticipants : { facility : FaT.FacilityId; funding : ProdT.Funding; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #restructureFacility : { facility : FaT.FacilityId; effective : Day; terms : FaT.RestructureTerms };
    #recordCovenantTest : { facility : FaT.FacilityId; covenant : Text; value : Nat; statementHash : Blob };
    #blockDrawdowns : { facility : FaT.FacilityId; reason : Text };
    #unblockDrawdowns : { facility : FaT.FacilityId; reason : Text };
    #recordFacilityReview : { facility : FaT.FacilityId; note : Text };
    #recordRateFixing : { index : Text; day : Day; rateBps : Nat };
    #receiveRental : FacilityMoney;
    #remeasureResidual : { facility : FaT.FacilityId; residual : Nat; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #purchaseReceivables : { facility : FaT.FacilityId; receivables : [FaT.Receivable]; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #collectReceivable : { facility : FaT.FacilityId; ref : Blob; funding : ProdT.Funding; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #dishonourReceivable : { facility : FaT.FacilityId; ref : Blob; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #writeOffReceivable : { facility : FaT.FacilityId; ref : Blob; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #closeFacility : { facility : FaT.FacilityId };
    // ── branch and teller (branch and teller): counted cash, sessions, the cash network, cheques and drafts ──
    #setTellerPolicy : TeT.Policy;
    #openTellerSession : { till : ProdT.TillId; teller : Principal; opening : TeT.DenominationSet };
    #closeTellerSession : { till : ProdT.TillId; closing : TeT.DenominationSet };
    #resolveTillDifference : { session : TeT.SessionId; note : Text; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #cashDeposit : { till : ProdT.TillId; account : ProdT.AccountId; amount : Nat; tendered : TeT.DenominationSet; change : TeT.DenominationSet; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #cashWithdrawal : { till : ProdT.TillId; account : ProdT.AccountId; amount : Nat; paid : TeT.DenominationSet; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #vaultToTill : { till : ProdT.TillId; amount : Nat; denominations : TeT.DenominationSet; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #tillToVault : { till : ProdT.TillId; amount : Nat; denominations : TeT.DenominationSet; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #dispatchCash : { product : ProdT.ProductId; fromBook : BookId; toBook : BookId; currency : JT.Currency; amount : Nat; denominations : TeT.DenominationSet; carrier : Text; sealBag : Text; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #receiveCash : { movement : TeT.MovementId; denominations : TeT.DenominationSet; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #vaultToCentralBank : { product : ProdT.ProductId; book : BookId; currency : JT.Currency; amount : Nat; denominations : TeT.DenominationSet; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #centralBankToVault : { product : ProdT.ProductId; book : BookId; currency : JT.Currency; amount : Nat; denominations : TeT.DenominationSet; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #issueChequebook : { account : ProdT.AccountId; from : Nat; to : Nat };
    #stopCheque : { account : ProdT.AccountId; serial : Nat; reason : Text };
    #presentCheque : { account : ProdT.AccountId; serial : Nat; amount : Nat; payee : TeT.Payee; chequeDate : Day; imageHash : Blob; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #clearCheque : { account : ProdT.AccountId; serial : Nat; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #returnCheque : { account : ProdT.AccountId; serial : Nat; reason : TeT.ReturnReason; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #issueDraft : { serial : Text; payeeCommit : PT.Commitment; amount : Nat; currency : JT.Currency; source : TeT.CashSource; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #payDraft : { serial : Text; to : TeT.CashSource; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #cancelDraft : { serial : Text; refundTo : ProdT.AccountId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    // ── trade finance trade finance: documentary credits, undertakings, collections, bills, and the messages exchanged ──
    #setTradePolicy : TrT.Policy;
    #issueLetterOfCredit : { lc : TrT.LetterOfCredit; amount : Nat; currency : JT.Currency; expiry : Day; placeOfExpiry : Text; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #adviseLetterOfCredit : { message : Text; beneficiary : PT.PartyId; beneficiaryAccount : ProdT.AccountId; confirm : Bool; checklist : [(TrT.DocumentKind, [Text])]; commissionBps : Nat; facility : ?Nat; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #amendLetterOfCredit : { instrument : TrT.InstrumentId; amendment : TrT.Amendment; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #presentDocuments : { instrument : TrT.InstrumentId; documents : [TrT.DocumentRef]; amount : Nat; shipmentDate : ?Day; presentedOn : Day };
    #examinePresentation : { instrument : TrT.InstrumentId; claim : TrT.ClaimSeq; checks : [TrT.CheckResult]; decision : TrT.Decision };
    #waiveDiscrepancies : { instrument : TrT.InstrumentId; claim : TrT.ClaimSeq; applicantConsentHash : Blob };
    #honourPresentation : { instrument : TrT.InstrumentId; claim : TrT.ClaimSeq; honour : TrT.Honour; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #settleAcceptance : { instrument : TrT.InstrumentId; claim : TrT.ClaimSeq; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #closeLetterOfCredit : { instrument : TrT.InstrumentId; reason : Text; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #issueGuarantee : { guarantee : TrT.Guarantee; amount : Nat; currency : JT.Currency; expiry : Day; wordingText : Text; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #amendGuarantee : { instrument : TrT.InstrumentId; amendment : TrT.Amendment; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #recordDemand : { instrument : TrT.InstrumentId; demand : TrT.DocumentRef; amount : Nat; supportingStatement : Bool; presentedOn : Day };
    #examineDemand : { instrument : TrT.InstrumentId; claim : TrT.ClaimSeq; checklist : [Text]; checks : [TrT.CheckResult]; decision : TrT.Decision };
    #payDemand : { instrument : TrT.InstrumentId; claim : TrT.ClaimSeq; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #reduceGuarantee : { instrument : TrT.InstrumentId; to : Nat; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #releaseGuarantee : { instrument : TrT.InstrumentId; reason : Text; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #registerCollection : { collection : TrT.Collection; amount : Nat; currency : JT.Currency; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #presentCollection : { instrument : TrT.InstrumentId; presentedOn : Day };
    #acceptCollection : { instrument : TrT.InstrumentId };
    #payCollection : { instrument : TrT.InstrumentId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #protestCollection : { instrument : TrT.InstrumentId; reason : Text };
    #returnCollection : { instrument : TrT.InstrumentId; reason : Text; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #discountBill : { bill : TrT.Bill; face : Nat; currency : JT.Currency; maturity : Day; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #rediscountBill : { instrument : TrT.InstrumentId; to : Text; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #settleBill : { instrument : TrT.InstrumentId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #dishonourBill : { instrument : TrT.InstrumentId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #recordTradeMessage : { instrument : TrT.InstrumentId; kind : TrT.MessageKind; direction : TrT.Direction; hash : Blob };
    // ── Islamic banking Islamic banking: the Sharia contracts, their acts, the investment pools, the governance record ──
    #setIslamicPolicy : IT.Policy;
    #approveShariaProduct : { product : ProdT.ProductId; approval : IT.BoardApproval };
    #flagShariaBook : { book : BookId; sharia : Bool };
    #openShariaContract : { kind : IT.Kind; currency : JT.Currency; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #acquireMurabahaAsset : { contract : IT.ContractId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #sellMurabaha : { contract : IT.ContractId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #collectInstalment : { contract : IT.ContractId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #grantRebate : { contract : IT.ContractId; amount : Nat; reason : Text; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #commenceIjarah : { contract : IT.ContractId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #collectRental : { contract : IT.ContractId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #transferIjarahOwnership : { contract : IT.ContractId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #contributeCapital : { contract : IT.ContractId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #distributeMusharakahProfit : { contract : IT.ContractId; profit : Nat; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #allocateMusharakahLoss : { contract : IT.ContractId; loss : Nat; offered : ?[(PT.PartyId, Nat)]; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #buyMusharakahUnit : { contract : IT.ContractId; units : Nat; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #recordMudarabahResult : { contract : IT.ContractId; profit : Nat; loss : Nat; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #deliverSalam : { contract : IT.ContractId; quantity : Nat; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #sellSalamCommodity : { contract : IT.ContractId; proceeds : Nat; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #recordSalamFailure : { contract : IT.ContractId; recourse : Text; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #recordIstisnaMilestone : { contract : IT.ContractId; certificate : Blob; percentBps : Nat; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #collectIstisnaBilling : { contract : IT.ContractId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #settleShariaContract : { contract : IT.ContractId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #closeShariaContract : { contract : IT.ContractId; reason : Text };
    #recordNonCompliance : { contract : ?IT.ContractId; amount : Nat; account : Text; reason : Text; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #openInvestmentPool : { pool : IT.Pool };
    #updatePoolReserves : { pool : IT.PoolId; per : ?Nat; irr : ?Nat };
    #distributePool : { pool : IT.PoolId; month : Text; from : Day; to : Day; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    // ── treasury (treasury): deals as commands, positions as folds, valuation by declared curves, nostro reconciliation ──
    #setTreasuryPolicy : TT.Policy;
    #registerSecurity : { terms : TT.SecurityTerms };
    #publishCurve : { curve : TT.Curve };
    #setTreasuryLimit : { limit : TT.Limit };
    #registerNostro : { nostro : TT.Nostro };
    /// The trader's act within their limits; a breach is a refusal unless an approver is named, in which case the deal
    /// is recorded outside its limits and each breach is recorded after it with the approver.
    #captureDeal : { book : BookId; counterparty : TT.Counterparty; kind : TT.DealKind; reference : Text; approver : ?Principal };
    /// The counterparty's confirmation, by its hash and either the fields the connector read or the fxtr.014 document
    /// itself, which the contract parses.
    #confirmDeal : { deal : TT.DealId; confirmation : Blob; fields : ?TT.ConfirmationFields; document : ?Blob };
    #amendDeal : { deal : TT.DealId; kind : TT.DealKind; reason : Text };
    #cancelDeal : { deal : TT.DealId; reason : Text };
    #settleDealLeg : { deal : TT.DealId; leg : Nat; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #markDeal : { deal : TT.DealId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #recordNostroStatement : { nostro : TT.NostroId; statement : Blob; from : Day; to : Day; entries : [TT.StatementEntry]; document : ?Blob };
    #resolveNostroBreak : { breakId : TT.BreakId; resolution : Text; correction : ?{ account : Text; sub : ?Text; debit : Bool; amount : Nat; currency : Text }; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    // ── cards (cards): issuance, controls and disputes as commands; authorizations and clearing arrive as signed methods ──
    #setCardPolicy : CdT.Policy;
    #declareCardScheme : { scheme : CdT.Scheme };
    #defineCardProduct : { product : CdT.CardProduct };
    /// The token the vault minted stands for the card; the PAN never arrives.
    #issueCard : { token : CdT.Token; account : ProdT.AccountId; product : CdT.ProductId; form : CdT.Form; controls : CdT.Controls; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #activateCard : { card : CdT.CardId };
    #blockCard : { card : CdT.CardId; reason : CdT.BlockReason };
    #unblockCard : { card : CdT.CardId };
    #replaceCard : { card : CdT.CardId; newToken : CdT.Token; reason : CdT.ReplaceReason; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #closeCard : { card : CdT.CardId; reason : Text };
    /// `byCustomer` is the channel's statement of who asked (recorded); the permission's scope decides who may.
    #setCardControls : { card : CdT.CardId; controls : CdT.Controls; byCustomer : Bool };
    #openDispute : { transaction : CdT.ClearedId; reason : Text; amount : Nat };
    #grantProvisionalCredit : { dispute : CdT.DisputeId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #raiseChargeback : { dispute : CdT.DisputeId; schemeRef : Text; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #recordRepresentment : { dispute : CdT.DisputeId; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #recordPreArbitration : { dispute : CdT.DisputeId };
    #resolveDispute : { dispute : CdT.DisputeId; outcome : CdT.Outcome; finalAmount : Nat; postingDate : Day; valueDate : Day; period : Text; narration : Text };
    #markFraud : { transaction : CdT.ClearedId; blockCard : Bool };
    // ── closed-month packing: opening a pack over a closed period, rolling a sealed one to an archive ──
    #openPacking : { period : Text };
    #rollPackToArchive : { pack : Nat; cid : Nat64; archive : Principal };
    // ── shards: the routing rule, and a transfer to an account another shard holds ──
    #declareShardRule : { self : Nat; shards : [ST.ShardEntry] };
    #openShardTransfer : { from : ProdT.AccountId; toIdentifier : Text; amount : Nat; postingDate : Day; valueDate : Day; period : JT.PeriodId; narration : Text };
    // ── settlement: settlement on the journal ──
    #declareScheme : { id : SeT.SchemeId; granularity : SeT.Granularity; interchange : SeT.Interchange; delay : SeT.Delay; reconciliation : JT.AccountCode; feeIncome : JT.AccountCode; interchangeBps : Nat; hubFeeBps : Nat; alarmPercent : Nat };
    #registerParticipant : { party : PT.PartyId; bic : Text; scheme : SeT.SchemeId; accounts : [SeT.ParticipantAccounts] };
    #deactivateParticipant : { participant : SeT.ParticipantId };
    #recordFunds : { participant : SeT.ParticipantId; currency : JT.Currency; amount : Nat; direction : { #in_; #out }; postingDate : Day; valueDate : Day; period : JT.PeriodId; narration : Text };
    /// A payment's prepare, from the scheme: reserved in this message. The scheme principal's
    /// grant is what authorises it; the message's own validation and audit are the scheme's.
    #prepareTransfer : { scheme : SeT.SchemeId; payer : SeT.ParticipantId; payee : SeT.ParticipantId; currency : JT.Currency; amount : Nat; reference : Text; ttlSeconds : Nat };
    #fulfilTransfer : { transfer : SeT.TransferId };
    #rejectTransfer : { transfer : SeT.TransferId; reason : Text };
    #errorTransfer : { transfer : SeT.TransferId; reason : Text };
    #openSettlementWindow : { scheme : SeT.SchemeId; businessDate : Day };
    #closeSettlementWindow : { window : SeT.WindowId };
    #openSettlement : { window : SeT.WindowId };
    #abortSettlement : { settlement : SeT.SettlementId; reason : Text };
    #receiveBulk : { scheme : SeT.SchemeId; payer : SeT.ParticipantId; reference : Text; ttlSeconds : Nat; requests : [{ payee : SeT.ParticipantId; currency : JT.Currency; amount : Nat; reference : Text }] };
    #fulfilBulk : { bulk : SeT.BulkId };
    #rejectBulk : { bulk : SeT.BulkId; reason : Text };
    // ── ISO 20022 messaging on the journal ──
    #declareRail : { id : PayT.RailId; scheme : SeT.SchemeId; ttlSeconds : Nat; hold : PayT.HoldRules; signatures : PayT.SignatureScheme };
    #registerConnectorKey : { rail : PayT.RailId; bic : Text; scheme : PayT.SignatureScheme; publicKey : Blob };
    #releaseHold : { transfer : SeT.TransferId; reason : Text };
    #rejectHold : { transfer : SeT.TransferId; reason : Text };
    // the extended target list: a debtor participant's standing authority for FI direct debits, and the bank's decision on a mandate
    #grantDebitAuthority : { rail : PayT.RailId; debtor : SeT.ParticipantId; creditorBic : Text; currency : Text; maxAmount : Nat };
    #revokeDebitAuthority : { rail : PayT.RailId; debtor : SeT.ParticipantId; creditorBic : Text; currency : Text };
    #decideMandate : { rail : PayT.RailId; mandateId : Text; accepted : Bool; reason : ?Text };
    // ── FSPIOP interoperability: the participant directory with its callback endpoints ──
    #declareFspiopParticipant : { rail : PayT.RailId; participant : SeT.ParticipantId; fspId : FT.FspId; endpoints : [(Text, Text)] };
  };

  /// The shape every movement into or out of a customer account takes: which
  /// account, how much, when, and what the other side of the posting is. The
  /// counterparty is named rather than defaulted, so no posting can land in a
  /// bucket nobody chose.
  public type MoneyMove = {
    account : ProdT.AccountId;
    amount : Nat;
    postingDate : Day;
    valueDate : Day;
    period : JT.PeriodId;
    narration : Text;
    funding : ProdT.Funding;
  };

  // ─── Events: the only things that change bank state ───────────────────────

  public type Event = {
    // organisation and authority
    #bookOpened : { id : BookId; name : Text; parent : ?BookId };
    #bookClosed : { id : BookId };
    #roleDefined : { id : RoleId; name : Text; permissions : [PermissionId] };
    #roleGranted : { subject : Principal; role : RoleId; scope : Scope };
    #roleRevoked : { subject : Principal; role : RoleId };
    #dualPolicySet : DualPolicy;
    #dualPolicyCleared : { permission : PermissionId };
    #bankAdminTransferred : { admin : Principal };
    #featureActivationSet : { feature : FeatureId; height : Nat64 };
    // maker-checker
    /// A proposal: the command's hash, the permission it falls under and the book it is scoped to (read
    /// from the command when it was proposed, so the views and the read scoping need no body), the maker,
    /// the policy's requirement and role, the expiry and the justification — the preimage the block's hash
    /// covers. The command itself travels behind the hash as the block's trailer (block format 2), bound to
    /// the preimage by `commandHash`: `?Command` here is the trailer, `null` once a pack has dropped it under
    /// §18.2's rule (block format 2).
    /// `commandEncoding` names the frozen encoder the body and `commandHash` were made with; a reconstruction
    /// re-hashes under it, never under the current one (the review of 12 September).
    #commandProposed : { command : ?Command; commandHash : Blob; commandEncoding : Nat8; permission : PermissionId; book : ?BookId; maker : Principal; required : Nat; eligibleRole : RoleId; expiresAt : Nat64; justification : Text };
    #commandApproved : { proposal : Nat; commandHash : Blob; checker : Principal };
    #commandRejected : { proposal : Nat; checker : Principal; reason : Text };
    /// The execution: what it posted, and what it charged the maker's daily limit (`charge`, computed by the
    /// executor from the command), so the fold never needs the proposal's body.
    #commandExecuted : { proposal : Nat; commandHash : Blob; postings : [Nat]; charge : ?Charge };
    #commandExpired : { proposal : Nat };
    /// The authority block of an override. It does not carry the postings it
    /// causes, because their indices are not known until they are committed; the
    /// `#commandExecuted` block that follows records them and names this block.
    #emergencyOverride : { command : Command; commandEncoding : Nat8; commandHash : Blob; actor_ : Principal; witness : Principal; justification : Text };
    #overrideReviewed : { override_ : Nat; reviewer : Principal; disposition : Text };
    /// Everything the party layer records, under one case so there is one log.
    #party : PT.PartyEvent;
    /// Everything the product engine records, likewise.
    #product : ProdT.ProductEvent;
    /// Everything the close layer records, likewise.
    #close : CT.CloseEvent;
    /// Everything the end-of-day batch records, likewise.
    #batch : BT.BatchEvent;
    /// reporting — reporting. Registrations, certifications and issued statements; no figure.
    #report : RepT.ReportEvent;
    /// Indexing: the declared configuration that gives an index key its meaning.
    #index : IdxT.IndexEvent;
    /// Archive contracts: decisions, and every step of every spawn.
    #archive : AT.ArchiveEvent;
    /// Monitoring: the rules declared, versioned and retired.
    #monitoring : MT.MonitoringEvent;
    /// Alerts: a finding recorded, and its review.
    #alert : AlT.AlertEvent;
    /// Collections: the stage of an exposure and the acts on it (collections and recovery).
    #collections : ColT.CollectionsEvent;
    /// Origination: an application's steps, the models as data, the passkeys (origination and underwriting).
    #origination : OT.OriginationEvent;
    /// Corporate lending: the facilities and what happens on them (corporate lending).
    #facility : FaT.FacilityEvent;
    /// Branch and teller: counted cash, sessions, the cash network, cheques and drafts (branch and teller).
    #teller : TeT.TellerEvent;
    #trade : TrT.TradeEvent;
    #islamic : IT.IslamicEvent;
    /// Treasury: deals, curves, limits, nostro statements and breaks (treasury).
    #treasury : TT.TreasuryEvent;
    /// Cards: issuance, decisions, holds, clearing, disputes, statements (cards).
    #card : CdT.CardEvent;
    /// Closed-month packing: a pack opened, every segment, every advance, the seal.
    #packing : PkT.PackingEvent;
    /// Shards: the routing rule's versions, and every step of every inter-shard transfer.
    #shard : ST.ShardEvent;
    /// Settlement: schemes, participants, transfers, windows, settlements, bulks.
    #settlement : SeT.SettlementEvent;
    /// ISO 20022 messaging: rails, connector keys, every received message, the holds.
    #payments : PayT.PaymentsEvent;
    /// FSPIOP: the participant directory, the oracle, the quotes, the transfers, every request.
    #fspiop : FT.FspiopEvent;
    // refusals, recorded so a bank can prove what it prevented
    #operationRefused : { subject : Principal; permission : PermissionId; reason : RefusalReason; detail : Text };
  };

  /// What an execution charged against the maker's daily limit: the day and the totals by currency.
  public type Charge = { day : Day; totals : [(Text, Nat)] };

  public type RefusalReason = {
    #noGrant; #outsideBook; #outsideCurrency; #overCeiling; #overDailyLimit;
    #notEligibleChecker; #selfApproval; #commandHashMismatch; #proposalExpired;
    #featureInactive; #bookClosed; #noWitness; #notAdmin;
  };

  /// One block of the bank log. `hash` covers every other field; `parentHash`
  /// chains blocks; the MMR commits `hash` of every block. The shape is the
  /// journal's, deliberately, so one verifier reads both logs.
  public type Block = {
    index : Nat;
    timestamp : Nat64;
    caller : Principal;
    parentHash : ?Blob;
    hash : Blob;
    event : Event;
  };

  // ─── Views ─────────────────────────────────────────────────────────────────

  public type ProposalView = {
    index : Nat;
    /// the body: the block's trailer, or its reconstruction from the act's events once a pack dropped
    /// the trailer (`null` where no reconstruction hashes to `commandHash`)
    command : ?Command;
    commandHash : Blob;
    commandEncoding : Nat8;
    permission : PermissionId;
    book : ?BookId;
    maker : Principal;
    required : Nat;
    eligibleRole : RoleId;
    expiresAt : Nat64;
    justification : Text;
    status : ProposalStatus;
  };

  /// The command-audit row: maker, checker, result.
  public type AuditRow = {
    proposal : Nat;
    permission : PermissionId;
    maker : Principal;
    checkers : [Principal];
    result : Text;            // "Processed" | "Awaiting Approval" | "Rejected" | "Expired"
    proposedAtBlock : Nat;
    resolvedAtBlock : ?Nat;
    postings : [Nat];
  };

  public type GrantView = { subject : Principal; role : RoleId; scope : Scope; permissions : [PermissionId] };

  public type ConsumedView = { subject : Principal; currency : JT.Currency; day : Day; amount : Nat };

  // ─── Results and errors ────────────────────────────────────────────────────

  public type BankError = {
    #AnonymousCaller;
    #NotBankAdmin;
    #NoGrant : { permission : PermissionId };
    #UnknownPermission : { permission : PermissionId };
    #UnknownRole : { role : RoleId };
    #RoleExists : { role : RoleId };
    #RoleInUse : { role : RoleId; grants : Nat };
    #GrantExists : { subject : Principal; role : RoleId };
    #UnknownGrant : { subject : Principal; role : RoleId };
    #UnknownBook : { book : BookId };
    #BookExists : { book : BookId };
    #BookClosed : { book : BookId };
    #BookHasChildren : { book : BookId; children : Nat };
    #InvalidBook : { reason : Text };
    #InvalidRole : { reason : Text };
    #InvalidScope : { reason : Text };
    #OutsideBookScope : { book : BookId };
    #OutsideSubjectScope : { subject : Principal };
    #OutsideCurrencyScope : { currency : JT.Currency };
    #OverCeiling : { currency : JT.Currency; amount : Nat; ceiling : Nat };
    #OverDailyLimit : { currency : JT.Currency; amount : Nat; consumed : Nat; limit : Nat };
    #RequiresDualAuthorisation : { permission : PermissionId; required : Nat };
    #UnknownProposal : { index : Nat };
    #ProposalNotAwaiting : { index : Nat };
    #ProposalExpired : { index : Nat; expiresAt : Nat64 };
    #SelfApproval : { maker : Principal };
    #AlreadyApproved : { checker : Principal };
    #NotEligibleChecker : { checker : Principal; eligibleRole : RoleId };
    #CommandHashMismatch : { recorded : Blob; recomputed : Blob };
    #InsufficientApprovals : { have : Nat; required : Nat };
    #InvalidPolicy : { reason : Text };
    #WitnessRequired;
    #WitnessIsActor;
    #WitnessNotEligible : { witness : Principal };
    #OverrideReviewOutstanding : { overrides : Nat };
    #UnknownOverride : { index : Nat };
    #OverrideAlreadyReviewed : { index : Nat };
    #FeatureInactive : { feature : FeatureId; activationHeight : Nat64; height : Nat64 };
    #InvalidFeature : { reason : Text };
    #JournalError : { error : JT.PostError };
    #JournalConfigError : { error : JT.ConfigError };
    #JournalBatchError : { index : Nat; error : JT.PostError };
    #PartyError : { error : PT.PartyError };
    #ProductError : { error : ProdT.ProductError };
    #CloseError : { error : CT.CloseError };
    #BatchError : { error : BT.BatchError };
    #ReportError : { error : RepT.ReportError };
    #IndexError : { error : IdxT.IndexError };
    #QueryError : { error : IdxT.QueryError };
    #ArchiveError : { error : AT.ArchiveError };
    #MonitoringError : { error : MT.MonitoringError };
    #AlertError : { error : AlT.AlertError };
    #CollectionsError : { error : ColT.CollectionsError };
    #OriginationError : { error : OT.OriginationError };
    #FacilityError : { error : FaT.FacilityError };
    #TellerError : { error : TeT.TellerError };
    #TradeError : { error : TrT.TradeError };
    #IslamicError : { error : IT.IslamicError };
    #TreasuryError : { error : TT.TreasuryError };
    #CardError : { error : CdT.CardError };
    #PackingError : { error : PkT.Error };
    #ShardError : { error : ST.ShardError };
    #SettlementError : { error : SeT.SettlementError };
    #PaymentsError : { error : PayT.PaymentsError };
    #FspiopError : { error : FT.FspiopError };
    #ChargeError : { charge : Text; reason : Text };
    #LimitError : { reason : Text };
    #TermError : { reason : Text };
  };

  // ─── Limits (policy constants, enforced at admission) ──────────────────────

  public let MAX_BOOK_ID_BYTES : Nat = 32;
  public let MAX_ROLE_ID_BYTES : Nat = 32;
  public let MAX_NAME_BYTES : Nat = 128;
  public let MAX_PERMISSIONS_PER_ROLE : Nat = 1024;
  public let MAX_SCOPE_ENTRIES : Nat = 64;
  public let MAX_JUSTIFICATION_BYTES : Nat = 512;
  public let MAX_REQUIRED_APPROVALS : Nat = 8;
  public let MAX_BOOK_DEPTH : Nat = 16;
  public let MAX_PROPOSAL_TTL_SECONDS : Nat = 2_592_000;   // 30 days
  public let MIN_PROPOSAL_TTL_SECONDS : Nat = 60;
  /// The feature gate default: no money-visible feature is active until an
  /// activation height at or below the bank log's height is recorded.
  public let ACTIVATION_OFF : Nat64 = 0xFFFF_FFFF_FFFF_FFFF;

  public func actionText(a : Action) : Text {
    switch (a) {
      case (#create) "create"; case (#read) "read"; case (#update) "update"; case (#delete) "delete";
      case (#approve) "approve"; case (#reject) "reject"; case (#activate) "activate";
      case (#close) "close"; case (#reverse) "reverse"; case (#waive) "waive";
      case (#release) "release"; case (#breakGlass) "breakGlass";
    }
  };
};
