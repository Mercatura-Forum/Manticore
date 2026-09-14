/// ProductTypes.mo; the product engine's vocabulary.
///
/// A product is a named, **versioned** composition of property groups: interest,
/// charges, limits, schedule, accounting and tax. That decomposition is Temenos
/// T24's Arrangement Architecture and Mambu's product factory, and the reason to
/// follow it is the versioning: an amendment creates a new version and every
/// account stays bound to the version it was opened under, unless an explicit,
/// recorded migration moves it. Product terms can therefore never be silently
/// restated under an account, which is how an interest dispute becomes
/// unanswerable.
///
/// An account is not a new object with a number in it. It is a **sub-ledger key
/// under a general-ledger control account**; the shape the token ledger proved for token
/// holders; so every balance is a journal balance and there is nothing to
/// reconcile.


import Principal "mo:core/Principal";

import JT "mo:journal/JournalTypes";

import DC "DayCount";
import I "Interest";
import PT "PartyTypes";
import Conv "Conventions";

module {

  public type Day = JT.Day;
  public type ProductId = Text;
  public type ProductVersion = Nat;
  public type AccountId = Nat;          // the bank block index of #accountOpened

  // ─── the accounting property: role → general-ledger account ───────────────

  /// The posting roles a product maps to accounts. Registration validates that
  /// each mapped account exists, is active and has the **category the role
  /// requires**; the check Fineract performs per slot and refuses the product
  /// without (behaviour 6: two rejections observed before acceptance).
  public type Role = {
    #principal;              // the customer's own balance: liability for a deposit, asset for a loan
    #interestPayable;        // accrued interest owed to a depositor
    #interestExpense;
    #interestReceivable;     // accrued interest owed by a borrower
    #interestIncome;
    #feeIncome;
    #penaltyIncome;
    /// Fees and penalties charged to a credit account are receivable until they
    /// are repaid, and they are a different balance-sheet line from principal, so
    /// they get their own control accounts rather than sharing the principal one.
    #feeReceivable;
    #penaltyReceivable;
    #taxPayable;
    #overdraftPortfolio;
    #writeOff;
    #recovery;
    #allowance;              // contra-asset for expected credit loss
    #impairmentExpense;
    #suspense;
    #cash;                   // the till or vault counterpart
    /// The IFRS 9 §5.4.3 adjustment of a restructured loan's gross carrying amount (collections and recovery): a contra to the
    /// principal, so the borrower's contractual balance stays what the schedule says.
    #modificationAdjustment;
    /// Corporate lending (corporate lending): what a syndicate's agent owes its participants for the principal they funded
    /// and for what is payable to them; a lessor's rent receivable and rental income; a factor's purchased
    /// receivables, the retention it holds for the client, the discount not yet earned and the discount income.
    #dueToParticipants;
    #participantPayable;
    #rentReceivable;
    #rentalIncome;
    #purchasedReceivables;
    #retentionPayable;
    #unearnedDiscount;
    #discountIncome;
  };

  public type RoleMapping = { role : Role; account : JT.AccountCode };

  /// What a role requires of the account it maps to. A product whose mapping
  /// breaks one of these cannot be registered, so there is no run-time path where
  /// a posting lands in a default bucket.
  public func requiredCategory(r : Role) : JT.Category {
    switch (r) {
      case (#principal) #liability;          // overridden for credit products, see `requiredCategoryFor`
      case (#interestPayable) #liability;
      case (#interestExpense) #expense;
      case (#interestReceivable) #asset;
      case (#interestIncome) #income;
      case (#feeIncome) #income;
      case (#penaltyIncome) #income;
      case (#feeReceivable) #asset;
      case (#penaltyReceivable) #asset;
      case (#taxPayable) #liability;
      case (#overdraftPortfolio) #asset;
      case (#writeOff) #expense;
      case (#recovery) #income;
      case (#allowance) #asset;
      case (#impairmentExpense) #expense;
      case (#suspense) #asset;
      case (#cash) #asset;
      case (#modificationAdjustment) #asset;
      case (#dueToParticipants) #liability;
      case (#participantPayable) #liability;
      case (#rentReceivable) #asset;
      case (#rentalIncome) #income;
      case (#purchasedReceivables) #asset;
      case (#retentionPayable) #liability;
      case (#unearnedDiscount) #liability;
      case (#discountIncome) #income;
    }
  };

  public type ProductKind = {
    #currentAccount;
    #savings;
    #termDeposit;
    #recurringDeposit;
    #loan;
    #shareAccount;
    #till;                   // a cashier's drawer, which is cash with a constraint
  };

  /// A deposit product's principal is a liability; a credit product's is an asset.
  /// Getting this backwards would put every customer balance on the wrong side of
  /// the balance sheet, so it is a function of the kind rather than a field.
  public func requiredCategoryFor(kind : ProductKind, r : Role) : JT.Category {
    switch (r, kind) {
      case (#principal, #loan) #asset;
      case (#principal, #shareAccount) #equity;
      case (#principal, #till) #asset;
      case (#principal, _) #liability;
      case (_, _) requiredCategory(r);
    }
  };

  public func roleText(r : Role) : Text {
    switch (r) {
      case (#principal) "principal"; case (#interestPayable) "interestPayable";
      case (#interestExpense) "interestExpense"; case (#interestReceivable) "interestReceivable";
      case (#interestIncome) "interestIncome"; case (#feeIncome) "feeIncome";
      case (#penaltyIncome) "penaltyIncome"; case (#feeReceivable) "feeReceivable";
      case (#penaltyReceivable) "penaltyReceivable"; case (#taxPayable) "taxPayable";
      case (#overdraftPortfolio) "overdraftPortfolio"; case (#writeOff) "writeOff";
      case (#recovery) "recovery"; case (#allowance) "allowance";
      case (#impairmentExpense) "impairmentExpense"; case (#suspense) "suspense";
      case (#cash) "cash"; case (#modificationAdjustment) "modificationAdjustment";
      case (#dueToParticipants) "dueToParticipants"; case (#participantPayable) "participantPayable";
      case (#rentReceivable) "rentReceivable"; case (#rentalIncome) "rentalIncome";
      case (#purchasedReceivables) "purchasedReceivables"; case (#retentionPayable) "retentionPayable";
      case (#unearnedDiscount) "unearnedDiscount"; case (#discountIncome) "discountIncome";
    }
  };

  /// The roles a product kind must map before it can be registered. A product with
  /// an unmapped required role is refused at registration, never discovered when a
  /// posting has nowhere to go.
  public func requiredRoles(kind : ProductKind) : [Role] {
    switch (kind) {
      case (#currentAccount) [#principal, #interestPayable, #interestExpense, #feeIncome, #overdraftPortfolio];
      case (#savings) [#principal, #interestPayable, #interestExpense, #feeIncome];
      case (#termDeposit) [#principal, #interestPayable, #interestExpense, #penaltyIncome];
      case (#recurringDeposit) [#principal, #interestPayable, #interestExpense, #penaltyIncome];
      case (#loan) [#principal, #interestReceivable, #interestIncome, #feeIncome, #penaltyIncome, #feeReceivable, #penaltyReceivable, #writeOff, #recovery, #allowance, #impairmentExpense];
      case (#shareAccount) [#principal, #feeIncome];
      case (#till) [#principal, #cash, #suspense];
    }
  };

  // ─── the interest property ────────────────────────────────────────────────

  public type Basis = { #dailyBalance; #averageDailyBalance };

  /// Where a compounding period boundary falls. Both conventions are in use and the
  /// figures they produce differ by a minor unit or two over a few months, so a
  /// product declares which one it is sold under rather than inheriting whichever
  /// the implementation happened to choose:
  ///
  ///   * `#anniversary`; the boundary is the same day of the month as the opening
  ///     day (clamped at a short month end). The term runs from the opening date, so
  ///     this is the natural convention for a term deposit.
  ///   * `#calendar`; the boundary is the first of each calendar month, so a deposit
  ///     opened mid-month has a short first period. This is the convention Apache
  ///     Fineract's monthly compounding uses, and declaring it reproduces Fineract's
  ///     figure exactly (criterion F8).
  public type CompoundingAlignment = { #anniversary; #calendar };

  public type Period = { #daily; #monthly; #quarterly; #semiAnnual; #annual; #atMaturity };

  /// A rate band: the rate that applies while the balance (or the term, for a
  /// deposit) falls in `[from, to)`. Bands must partition the space, which
  /// registration checks; a gap is a balance with no rate.
  public type RateBand = { from : Nat; to : ?Nat; rate : I.Rate };

  public type RateChart = { bands : [RateBand]; by : { #balance; #termDays } };

  public type InterestTerms = {
    /// A single rate, or a chart. A chart with one open band is the single-rate
    /// case, but both shapes are kept so a product says which it is.
    chart : RateChart;
    convention : DC.Convention;
    basis : Basis;
    compounding : Period;
    /// Where each compounding boundary falls. See `CompoundingAlignment`.
    compoundingAlignment : CompoundingAlignment;
    posting : Period;
    /// No interest accrues while the balance is below this.
    minimumBalance : Nat;
    /// A negative rate is a real instrument; a product must opt in, so one cannot
    /// arrive by a sign error in a rate table.
    allowNegative : Bool;
  };

  // ─── the charges property ─────────────────────────────────────────────────

  public type ChargeCalculation = {
    #flat : { amount : Nat };
    #percentOfAmount : { rate : I.Rate };
    #percentOfInterest : { rate : I.Rate };
    #percentOfPrincipalOutstanding : { rate : I.Rate };
  };

  public type ChargeTiming = {
    #onActivation;
    #onTransaction;
    #onDate : { day : Day };
    #recurring : { every : Period };
    #overdue : { afterDays : Nat };
    #onClosure;
  };

  public type Charge = {
    id : Text;
    calculation : ChargeCalculation;
    timing : ChargeTiming;
    currency : JT.Currency;
    /// Which income role the charge credits: fee or penalty.
    role : Role;
    waivable : Bool;
  };

  // ─── the limits property ──────────────────────────────────────────────────

  public type Limits = {
    /// An overdraft facility, expressed as the journal's numeric balance limit so
    /// it is enforced by the engine and not by this layer.
    overdraft : ?Nat;
    /// Minimum balance that must remain after a withdrawal.
    minimumOperating : Nat;
    /// Largest single movement.
    perOperation : ?Nat;
  };

  // ─── the schedule property (credit products) ──────────────────────────────

  public type Amortisation = {
    #equalInstalments;       // declining balance, equal total payment (EMI)
    #equalPrincipal;
    #flat;
    #balloon : { finalPrincipal : Nat };
  };

  public type ScheduleTerms = {
    amortisation : Amortisation;
    instalments : Nat;
    every : Period;
    principalGrace : Nat;    // instalments with no principal component
    interestGrace : Nat;     // instalments with no interest component
    moratoriumDays : Nat;    // days before the first instalment falls due
  };

  /// One row of a generated repayment schedule. Every figure is minor units and
  /// every row is a pure function of the terms, so a schedule can be recomputed
  /// and compared rather than trusted.
  public type Instalment = {
    number : Nat;
    dueDate : Day;
    openingPrincipal : Nat;
    principal : Nat;
    interest : Nat;
    fees : Nat;
    closingPrincipal : Nat;
  };

  // ─── delinquency and provisioning ─────────────────────────────────────────

  public type DelinquencyBand = { name : Text; fromDays : Nat; toDays : ?Nat };

  /// IFRS 9 staging and the CBE classification bands are **declared parameters**:
  /// the engine computes and posts from them and estimates nothing. No model is
  /// fitted, inferred or hidden anywhere in this component.
  public type ProvisionRule = { band : Text; stage : Nat; percentOfOutstanding : I.Rate };

  // ─── the product itself ───────────────────────────────────────────────────

  public type Accounting = { #cash; #accrualPeriodic };

  public type ProductTerms = {
    kind : ProductKind;
    currency : JT.Currency;
    /// The general-ledger control account customer balances sit under, as
    /// sub-ledgers. Must be the account mapped to `#principal`.
    control : JT.AccountCode;
    roles : [RoleMapping];
    interest : ?InterestTerms;
    charges : [Charge];
    limits : Limits;
    schedule : ?ScheduleTerms;
    delinquency : [DelinquencyBand];
    provisioning : [ProvisionRule];
    accounting : Accounting;
    /// Withholding tax on interest credited, as a rate and a liability role.
    withholdingTax : ?I.Rate;
    /// The rounding mode for **every** monetary rounding this product performs;
    /// interest, charges, provisions, schedules. One declared mode per product, so
    /// two figures in the same statement can never have been rounded differently.
    rounding : I.Rounding;
    /// The rate a term deposit's interest is recomputed at when it is redeemed
    /// before maturity: the opening rate less this, floored at zero.
    earlyRedemptionPenalty : ?I.Rate;
    /// How a requested value date that is not a business day is resolved. This is
    /// the **only** layer that moves a date: the journal's own calendar policy is
    /// `#reject` in a bank deployment, so a date this layer has resolved can never
    /// be moved again. See `Conventions.mo`.
    valueDateConvention : Conv.Convention;
  };

  public type Product = {
    id : ProductId;
    version : ProductVersion;
    name : Text;
    terms : ProductTerms;
    registeredAtBlock : Nat;
    /// A version is never edited; an amendment registers the next one.
    supersededBy : ?ProductVersion;
  };

  // ─── accounts ─────────────────────────────────────────────────────────────

  public type AccountStatus = { #pending; #active; #dormant; #closed };

  public type ProductAccount = {
    id : AccountId;
    product : ProductId;
    /// The version the account was opened under. It does not move when the product
    /// is amended; only a recorded migration changes it.
    version : ProductVersion;
    party : PT.PartyId;
    book : Text;
    identifier : Text;              // the issued account identifier (IBAN)
    /// The sub-ledger key under the product's control account, derived from the
    /// identifier so a balance can be found from either.
    subledger : Blob;
    currency : JT.Currency;
    status : AccountStatus;
    openedAtBlock : Nat;
    /// The day interest was last capitalised; accrual is recomputed from here.
    lastCapitalised : Day;
    maturity : ?Day;
    closedAtBlock : ?Nat;
  };

  // ─── tills ────────────────────────────────────────────────────────────────

  public type TillId = Text;

  public type TillStatus = { #open; #settled; #closed };

  public type Difference = { #balanced; #over : Nat; #short : Nat };

  /// A rate, re-exported so the bank's own command vocabulary can name one
  /// without importing the interest module.
  public type Rate = I.Rate;

  /// The value-date convention, re-exported so the codec can name it without a
  /// second import path.
  public type ValueDateConvention = Conv.Convention;

  /// What a charge is computed against. A charge whose calculation needs a figure
  /// the caller has not supplied is refused rather than computed from zero.
  public type ChargeBase = { amount : ?Nat; interest : ?Nat; outstanding : ?Nat };

  /// The other side of a movement into or out of a customer account: a cashier's
  /// drawer for cash, or a named general-ledger account for a transfer in from
  /// clearing, settlement or a suspense position. Named rather than defaulted, so
  /// no posting can land in a bucket nobody chose.
  public type Funding = { #till : TillId; #glAccount : JT.AccountCode };

  // ─── repayment allocation ─────────────────────────────────────────────────

  /// The four things a repayment can be applied to. The order they are applied in
  /// is product data rather than a constant, because it is a term a bank
  /// negotiates and a regulator reads; Fineract's default (penalties, fees,
  /// interest, principal) is the default here.
  public type Component = { #penalty; #fee; #interest; #principal };

  public type Allocation = { penalty : Nat; fee : Nat; interest : Nat; principal : Nat };

  public func componentText(c : Component) : Text {
    switch (c) { case (#penalty) "penalty"; case (#fee) "fee"; case (#interest) "interest"; case (#principal) "principal" }
  };

  // ─── the product engine's events ──────────────────────────────────────────

  /// Everything the product engine records. Each of these is a block in the bank
  /// log: the decision is provable, and the postings it caused are named by the
  /// `#commandExecuted` block that carries them.
  public type ProductEvent = {
    #productRegistered : { id : ProductId; version : ProductVersion; name : Text; terms : ProductTerms };
    /// An amendment is a **new version**. The old version is retained and every
    /// account stays bound to the version it was opened under.
    #productAmended : { id : ProductId; version : ProductVersion; supersedes : ProductVersion; name : Text; terms : ProductTerms };
    #productClosedToNewAccounts : { id : ProductId; version : ProductVersion };
    /// A redenomination (S4.1): the one amendment that changes the currency; a new version whose terms are the
    /// old ones in the new currency, with the accrual evidence of the old currency carried to the new.
    #productRedenominated : { id : ProductId; version : ProductVersion; supersedes : ProductVersion; from : JT.Currency; to : JT.Currency; terms : ProductTerms };
    /// An account re-expressed in the new currency and bound to the redenominated version.
    #accountRedenominated : { account : AccountId; version : ProductVersion; from : JT.Currency; to : JT.Currency };
    #accountOpened : {
      product : ProductId; version : ProductVersion; party : PT.PartyId; book : Text;
      identifier : Text; currency : JT.Currency; opened : Day; maturity : ?Day;
      openingRate : ?I.Rate; allocationOrder : [Component];
    };
    #accountStatusSet : { account : AccountId; to : AccountStatus };
    /// A migration is the only way an account's product version changes, and it is
    /// a recorded decision naming both versions.
    #accountMigrated : { account : AccountId; from : ProductVersion; to : ProductVersion };
    /// The decision to grant a facility. The engine-enforced limit is the journal
    /// event that accompanies it; this block is why it was granted.
    #facilityGranted : { account : AccountId; limit : Nat };
    #chargeApplied : { account : AccountId; charge : Text; amount : Nat; day : Day };
    #chargeWaived : { account : AccountId; charge : Text; occurrence : Day; reversalOf : ?Nat; reason : Text };
    /// One aggregated accrual for a product and currency on a business date.
    #accrualPosted : { product : ProductId; currency : JT.Currency; day : Day; amount : Nat; accounts : Nat };
    /// A capitalisation run: what it examined, what it posted, and the residue it
    /// reports rather than absorbs.
    #interestCapitalised : {
      product : ProductId; currency : JT.Currency; from : Day; to : Day;
      examined : Nat; posted : Nat; zero : Nat; total : Nat;
      residueNumerator : Nat; residueDenominator : Nat; residueNegative : Bool;
    };
    #loanDisbursed : { account : AccountId; amount : Nat; day : Day; schedule : [Instalment] };
    /// The schedule terms a reschedule gave one account (S4.1): what a later contractual reset re-derives from,
    /// so a reset inside a modification keeps the modification's structure (amortisation, frequency, grace).
    #scheduleTermsSet : { account : AccountId; terms : ScheduleTerms; effective : Day };
    #loanRescheduled : { account : AccountId; version : Nat; effective : Day; schedule : [Instalment] };
    #repaymentReceived : { account : AccountId; day : Day; amount : Nat; applied : Allocation; overpayment : Nat };
    #provisionSet : { account : AccountId; band : ?Text; stage : ?Nat; required : Nat; previous : Nat };
    #loanWrittenOff : { account : AccountId; components : Allocation; fromAllowance : Nat; toExpense : Nat; day : Day };
    #recoveryReceived : { account : AccountId; amount : Nat; day : Day };
    #termDepositRedeemed : { account : AccountId; day : Day; entitled : Nat; recoverable : Nat; payable : Nat; early : Bool };
    #tillOpened : { till : TillId; book : Text; currency : JT.Currency; holder : Principal; product : ProductId };
    #tillAllocated : { till : TillId; amount : Nat; day : Day };
    #tillReturned : { till : TillId; amount : Nat; day : Day };
    #tillSettled : { till : TillId; declared : Nat; book : Nat; difference : Difference; day : Day };
    #tillClosed : { till : TillId };
    /// The account's contractual rate from `effective` on (corporate lending): a restructuring or a floating reset writes it,
    /// and the accrual reads it before the product's chart. Kept as a block the row points at.
    #accountRateSet : { account : AccountId; rate : I.Rate; effective : Day };
  };

  // ─── errors ───────────────────────────────────────────────────────────────

  public type ProductError = {
    #UnknownProduct : { product : ProductId };
    #ProductExists : { product : ProductId; version : ProductVersion };
    #ProductSuperseded : { product : ProductId; version : ProductVersion; by : ProductVersion };
    #UnknownVersion : { product : ProductId; version : ProductVersion };
    #RoleUnmapped : { product : ProductId; role : Text };
    #RoleAccountUnknown : { role : Text; account : JT.AccountCode };
    #RoleAccountWrongCategory : { role : Text; account : JT.AccountCode; expected : Text; actual : Text };
    #RoleAccountClosed : { role : Text; account : JT.AccountCode };
    #ControlIsNotPrincipal : { control : JT.AccountCode; principal_ : JT.AccountCode };
    #InvalidTerms : { reason : Text };
    #InvalidRateChart : { reason : Text };
    #ConventionNotDailyBalance : { code : Text };
    #NegativeRateNotAllowed : { product : ProductId };
    #UnknownAccount : { account : AccountId };
    #AccountNotActive : { account : AccountId; status : AccountStatus };
    #AccountExists : { identifier : Text };
    #CurrencyMismatch : { expected : JT.Currency; actual : JT.Currency };
    #UnknownCharge : { charge : Text };
    #ChargeNotWaivable : { charge : Text };
    #ScheduleRequired : { product : ProductId };
    #InvalidSchedule : { reason : Text };
    #NothingToAccrue : { account : AccountId; from : Day; to : Day };
    #AlreadyCapitalised : { account : AccountId; upTo : Day };
    #ProductClosedToNewAccounts : { product : ProductId; version : ProductVersion };
    #AccountNotOfKind : { account : AccountId; expected : Text; actual : Text };
    #AccountHasBalance : { account : AccountId; balance : Nat };
    #IdentifierNotIssued : { identifier : Text };
    #UnknownTill : { till : TillId };
    #TillExists : { till : TillId };
    #TillNotOpen : { till : TillId; status : TillStatus };
    #NotTillHolder : { till : TillId };
    #TillHasCash : { till : TillId; balance : Nat };
    #InvalidAllocationOrder : { reason : Text };
    #LoanNotDisbursed : { account : AccountId };
    #LoanAlreadyDisbursed : { account : AccountId };
    #LoanWrittenOffAlready : { account : AccountId };
    #NothingOverdue : { account : AccountId };
    #MaturityNotReached : { account : AccountId; maturity : Day };
    #NoMaturity : { account : AccountId };
  };

  // ─── views: what a reader is given ────────────────────────────────────────
  //
  // The state entries carry `var` fields so the fold can update them in place; a
  // reader is given these immutable projections instead. Each one is shareable, so
  // it crosses the canister boundary as itself rather than as a re-derivation.

  public type ProductView = {
    id : ProductId;
    version : ProductVersion;
    name : Text;
    terms : ProductTerms;
    registeredAtBlock : Nat;
    supersededBy : ?ProductVersion;
    openToNewAccounts : Bool;
  };

  public type AccountView = {
    id : AccountId;
    product : ProductId;
    version : ProductVersion;
    party : PT.PartyId;
    book : Text;
    identifier : Text;
    subledger : Blob;
    currency : JT.Currency;
    status : AccountStatus;
    opened : Day;
    maturity : ?Day;
    openingRate : ?Rate;
    allocationOrder : [Component];
    lastCapitalised : Day;
    facility : Nat;
    scheduleVersions : Nat;
    disbursed : ?Day;
    writtenOff : Bool;
    allowance : Nat;
    band : ?Text;
    openedAtBlock : Nat;
    closedAtBlock : ?Nat;
  };

  public type TillView = {
    id : TillId;
    book : Text;
    currency : JT.Currency;
    holder : Principal;
    product : ProductId;
    subledger : Blob;
    status : TillStatus;
    allocated : Nat;
    returned : Nat;
    settlements : Nat;
    lastDifference : Difference;
    openedAtBlock : Nat;
  };

  /// A customer balance, with the two different questions answered separately and
  /// labelled, because conflating them is how a statement and a teller screen come
  /// to disagree:
  ///
  ///   * `net` / `overdrawn` are **value-dated as at `asOf`**; the balance interest
  ///     is computed on and the figure a statement for that date shows;
  ///   * `postedNet` / `postedOverdrawn` are over everything posted whatever its
  ///     value date;
  ///   * `available` is what the **engine will still admit now**: the posted
  ///     position less amounts already reserved, plus the facility. It has no as-of
  ///     notion because admission has none; the journal checks a limit against
  ///     everything posted and pending at the moment the posting arrives.
  public type BalanceView = {
    account : AccountId;
    identifier : Text;
    currency : JT.Currency;
    asOf : Day;
    net : Nat;
    overdrawn : Bool;
    postedNet : Nat;
    postedOverdrawn : Bool;
    facility : Nat;
    available : Nat;
  };

  /// An accrual, as the exact rational and as the figure that would be posted. Both
  /// are returned because the unrounded figure is what makes a dispute settleable.
  public type AccrualView = {
    account : AccountId;
    from : Day;
    to : Day;
    numerator : Nat;
    denominator : Nat;
    negative : Bool;
    amount : Nat;
  };

  /// A borrower's whole position, every figure read from the journal or computed
  /// from the schedule, none of it stored.
  public type LoanPositionView = {
    account : AccountId;
    asOf : Day;
    outstanding : Allocation;
    exposure : Nat;
    repaid : Nat;
    dueToDate : Nat;
    overdueTotal : Nat;
    overdueDays : Nat;
    instalmentsOverdue : Nat;
    band : ?Text;
    stage : ?Nat;
    requiredProvision : Nat;
    carriedAllowance : Nat;
    writtenOff : Bool;
  };

  /// A quote for a term deposit: the rate the term resolves to from the product's
  /// own chart, and the figure the deposit matures at. A branch quotes this before
  /// the account exists, so it is a read on the product rather than on an account;
  /// and it is the figure a depositor checks with a calculator.
  public type DepositQuoteView = {
    product : ProductId;
    version : ProductVersion;
    principal : Nat;
    termDays : Nat;
    /// The day the deposit is quoted from, and the day it would mature. A day-count
    /// convention is a function of the actual dates, so a quote says which dates it
    /// used rather than leaving the reader to assume today's.
    from : Day;
    maturity : Day;
    rateNumerator : Nat;
    rateDenominator : Nat;
    interest : Nat;
    maturityValue : Nat;
    compoundings : Nat;
    /// The exact interest before rounding, so a dispute about the last minor unit
    /// is settleable.
    exactNumerator : Nat;
    exactDenominator : Nat;
  };

  public type TillPositionView = {
    till : TillId;
    currency : JT.Currency;
    asOf : Day;
    book : Nat;
    allocated : Nat;
    returned : Nat;
    settlements : Nat;
    lastDifference : Difference;
  };

  // ─── activation gates ─────────────────────────────────────────────────────

  /// Every money-visible behaviour of the product engine sits behind one of these
  /// feature gates, each defaulting to `ACTIVATION_OFF`. Below its gate a feature
  /// refuses; configuration; registering a product, opening an account, opening a
  /// till; is not gated, because it moves no money.
  public let FEATURE_ACCOUNT_MONEY : Text = "product.account.money";
  public let FEATURE_INTEREST : Text = "product.interest";
  public let FEATURE_CHARGES : Text = "product.charges";
  public let FEATURE_CREDIT : Text = "product.credit";
  public let FEATURE_TILL : Text = "product.till";
  /// The close layer's own gates. Foreign currency and deferral amortisation
  /// both post, so both sit behind a height like everything else that moves money.
  public let FEATURE_FX : Text = "close.fx";
  public let FEATURE_DEFERRALS : Text = "close.deferrals";
  /// The end-of-day batch's own gate. A run posts under the product features
  /// below, and it also posts *unattended*, on an open method, so it carries a gate of
  /// its own: an institution that has activated interest for the single-command path has
  /// not thereby activated a nightly batch that exercises it over the whole book.
  public let FEATURE_END_OF_DAY : Text = "batch.endOfDay";
  /// Settlement on the journal: funds in and out, the reservation of a transfer, its
  /// commit with the fees, a bulk, and the settlement batch all post, so they sit behind one gate of
  /// their own. Declaring a scheme, registering a participant and opening a window move no money.
  public let FEATURE_SETTLEMENT : Text = "settlement.money";

  public func featureIds() : [Text] {
    [FEATURE_ACCOUNT_MONEY, FEATURE_INTEREST, FEATURE_CHARGES, FEATURE_CREDIT, FEATURE_TILL,
     FEATURE_FX, FEATURE_DEFERRALS, FEATURE_END_OF_DAY, FEATURE_SETTLEMENT]
  };

  // ─── bounds ───────────────────────────────────────────────────────────────

  public let MAX_PRODUCT_ID_BYTES : Nat = 32;
  public let MAX_ROLES : Nat = 32;
  public let MAX_CHARGES : Nat = 32;
  /// A charge id is part of a stable-memory key (`ProductCore.chargesApplied`), so it is bounded.
  public let MAX_CHARGE_ID_BYTES : Nat = 32;
  public let MAX_RATE_BANDS : Nat = 32;
  public let MAX_INSTALMENTS : Nat = 480;      // forty years of monthly payments
  public let MAX_DELINQUENCY_BANDS : Nat = 16;
  public let MAX_PROVISION_RULES : Nat = 16;

  public func periodDays(p : Period) : Nat {
    switch (p) {
      case (#daily) 1; case (#monthly) 30; case (#quarterly) 91;
      case (#semiAnnual) 182; case (#annual) 365; case (#atMaturity) 0;
    }
  };

  public func periodMonths(p : Period) : Nat {
    switch (p) {
      case (#daily) 0; case (#monthly) 1; case (#quarterly) 3;
      case (#semiAnnual) 6; case (#annual) 12; case (#atMaturity) 0;
    }
  };

  public func categoryText(c : JT.Category) : Text {
    switch (c) { case (#asset) "asset"; case (#liability) "liability"; case (#equity) "equity"; case (#income) "income"; case (#expense) "expense" }
  };
};
