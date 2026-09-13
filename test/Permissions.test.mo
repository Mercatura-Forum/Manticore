// Permissions.test.mo — the catalogue is total over the command vocabulary.
//
// `tools/permission_audit.py` checks the catalogue against the built Candid
// interface. This checks it from inside the language: one value of every
// `Command` variant is walked, every one resolves to a permission, identifiers
// are unique, and the money-moving-implies-dual rule holds. The two checks
// overlap on purpose — one would catch a table edit, the other a new variant.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";

import T "../src/bank/BankTypes";
import ProdT "../src/bank/ProductTypes";
import CT "../src/bank/CloseTypes";
import RepT "../src/bank/ReportTypes";
import P "../src/bank/Permissions";
import OV "OriginationVectors";

let p1 = Principal.fromBlob("\01\02");
let scope : T.Scope = { books = null; currencies = null; ceiling = null; dailyLimit = null };
let salt32 : Blob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat(i) }));

// One value of every Command variant. A new variant with no entry here does not
// compile against `commandName`, and a new variant missing from this list is
// caught by the count assertion below.
// the smallest product fixtures that let one value of every product command exist;
// the codec and engine batteries exercise the shapes, this list exercises coverage
let schedule : ProdT.ScheduleTerms = {
  amortisation = #equalInstalments; instalments = 6; every = #monthly;
  principalGrace = 0; interestGrace = 0; moratoriumDays = 0;
};
let terms : ProdT.ProductTerms = {
  kind = #savings; currency = "EGP"; control = "2110";
  roles = [{ role = #principal; account = "2110" }];
  interest = null; charges = [];
  limits = { overdraft = null; minimumOperating = 0; perOperation = null };
  schedule = null; delinquency = []; provisioning = [];
  accounting = #cash; withholdingTax = null; rounding = #halfEven;
  earlyRedemptionPenalty = null;
  valueDateConvention = #following;
};
let pair : CT.PositionPair = {
  currency = "USD"; position = "1410"; equivalent = "1411";
  unrealised = "4410"; realised = "4411"; monetary = true;
};
let fxRate : CT.Rate = {
  currency = "USD"; functional = "EGP"; numerator = 4850; denominator = 100;
  asOf = 20000; source = "test";
};
let deferral : CT.Schedule = {
  id = "d"; kind = #unearnedIncome; currency = "EGP"; amount = 1_200; periods = 12;
  deferralAccount = "2400"; recognitionAccount = "4100"; book = "HQ"; openedOn = 20000;
};
let move : T.MoneyMove = {
  account = 1; amount = 1; postingDate = 20000; valueDate = 20000;
  period = "p"; narration = "n"; funding = #glAccount("1001");
};

let sampleHash32 : Blob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((i * 7 + 3) % 256) }));

// ─── the reporting fixtures ───────────────────────────────────────────
//
// A definition, a template, a statement map, a statement and a feed endpoint, each
// exercising every shape its type admits: all three filter operators, every line source of a
// return including a ratio with a declared zero-denominator behaviour, and all five balance
// kinds.

let sampleReportDef : RepT.ReportDef = {
  id = "R34";
  version = 2;
  title = "Deposits by book and counterparty class";
  rows = [#book, #counterpartyClass({ schema = "cbe"; field = "sector" })];
  filters = [
    { dimension = #currency; op = #eq("EGP") },
    { dimension = #account; op = #inSet(["2110", "2115"]) },
    { dimension = #accountRange({ lo = 2000; hi = 2999 }); op = #range({ lo = 2000; hi = 2999 }) },
  ];
  measures = [#closingBalance, #periodDebits, #periodCredits, #entryCount, #balanceAsOf(20726), #valueDatedBalance(20726), #netMovement, #closingDebits];
  ordering = #byMeasureDescending(0);
  scale = #thousands;
  comparatives = #priorPeriod;
  maxSlice = 5_000;
};

let sampleReturnTemplate : RepT.ReturnTemplate = {
  id = "CBE-BS";
  version = 1;
  title = "CBE balance sheet return";
  authority = "CBE";
  currency = "EGP";
  taxonomy = ?"http://cbe.org.eg/xbrl/2026/bs";
  parameters = [
    { name = "corporate risk weight"; numerator = 100; denominator = 100 },
    { name = "retail risk weight"; numerator = 75; denominator = 100 },
  ];
  lines = [
    { code = "A10"; caption = "Cash and balances with the central bank"; source = #sumOfAccounts({ accounts = ["1001"]; measure = #closingBalance }); binding = ?"CashAndCentralBank" },
    { code = "A20"; caption = "Loans and advances"; source = #sumOfRanges({ ranges = [{ lo = 1200; hi = 1299 }]; measure = #closingBalance }); binding = ?"LoansAndAdvances" },
    { code = "A99"; caption = "Total assets"; source = #sumOfLines({ lines = ["A10", "A20"] }); binding = ?"TotalAssets" },
    { code = "L10"; caption = "Customer deposits"; source = #sumOfAccounts({ accounts = ["2110"]; measure = #closingBalance }); binding = ?"CustomerDeposits" },
    { code = "E10"; caption = "Equity"; source = #difference({ minuend = "A99"; subtrahend = "L10" }); binding = ?"Equity" },
    { code = "RWA"; caption = "Risk-weighted assets"; source = #weighted({ line = "A20"; numerator = 75; denominator = 100 }); binding = ?"RiskWeightedAssets" },
    { code = "CAR"; caption = "Capital adequacy ratio, basis points"; source = #ratio({ numerator = "E10"; denominator = "RWA"; scale = 10_000; whenZero = #reportUnmeasurable }); binding = ?"CapitalAdequacyRatio" },
    { code = "BUF"; caption = "Declared countercyclical buffer, basis points"; source = #declared({ value = 250 }); binding = ?"CountercyclicalBuffer" },
  ];
};

let sampleStatementMap : RepT.StatementMap = {
  cash = ["1001", "1999"];
  retainedEarnings = "3200";
  investing = ["1410"];
  financing = ["2400"];
  monetary = ["1001", "2110", "2120"];
};

let sampleStatement : RepT.StatementRef = {
  id = "053|137|20726";
  account = 137;
  kind = #camt053({ cut = 20726 });
  currency = "EGP";
  period = "2026-09";
  balances = [
    { kind = #OPBD; debits = 0; credits = 1_000_00; net = -100_000 },
    { kind = #CLBD; debits = 10_14; credits = 1_000_00; net = -98_986 },
    { kind = #PRCD; debits = 0; credits = 900_00; net = -90_000 },
    { kind = #ITBD; debits = 10_14; credits = 1_777_00; net = -176_686 },
    { kind = #CLAV; debits = 10_14; credits = 1_777_00; net = -176_686 },
  ];
  entryBlocks = [17, 41, 63];
  issued = 1;
  contentHash = sampleHash32;
  atHeight = 417;
};

let segHash32 : Blob = "\e3\b0\c4\42\98\fc\1c\14\9a\fb\f4\c8\99\6f\b9\24\27\ae\41\e4\64\9b\93\4c\a4\95\99\1b\78\52\b8\56";
let commands : [T.Command] = [
  #defineRole({ id = "r"; name = "R"; permissions = ["role.grant"] }),
  #grantRole({ subject = p1; role = "r"; scope }),
  #revokeRole({ subject = p1; role = "r" }),
  #setDualPolicy({ permission = "role.grant"; required = 1; eligibleRole = "r"; ttlSeconds = 3600 }),
  #clearDualPolicy({ permission = "role.grant" }),
  #openBook({ id = "HQ"; name = "Head office"; parent = null }),
  #closeBook({ id = "HQ" }),
  #transferBankAdmin({ admin = p1 }),
  #setFeatureActivation({ feature = "manual-entry"; height = 0 }),
  #journalRegisterCurrency({ code = "EGP"; minorUnits = 2 }),
  #journalOpenAccount({ code = "1001"; name = "Cash"; normalSide = #debit; category = #asset; constraint = #none }),
  #journalCloseAccount({ code = "1001" }),
  #journalOpenPeriod({ id = "2026-09"; start = 20697; end = 20726 }),
  #journalClosePeriod({ id = "2026-09" }),
  #journalSetActivationHeight({ height = 0 }),
  #journalSetLeadsheetSchema({ ranges = [] }),
  #journalAddPoster({ poster = p1 }),
  #journalRemovePoster({ poster = p1 }),
  #journalSetPosterScope({ poster = p1; accounts = ?["1001"] }),
  #journalRollBusinessDate({ day = 20705 }),
  #journalSetCalendar({ calendar = null }),
  #journalSetCalendarAuthority({ authority = #businessDate; maxRollDays = 31; businessDate = ?20705 }),
  #postManualEntry({ book = "HQ"; postingDate = 20705; valueDate = 20705; period = "2026-09"; legs = []; narration = ""; idempotencyKey = Blob.fromArray([1]); correctionOf = null }),
  #reverseManualEntry({ original = 1; book = "HQ"; postingDate = 20705; valueDate = 20705; period = "2026-09"; narration = ""; idempotencyKey = Blob.fromArray([2]) }),
  #postManualEntryForParty({ party = 1; entry = { book = "HQ"; postingDate = 20705; valueDate = 20705; period = "2026-09"; legs = []; narration = ""; idempotencyKey = Blob.fromArray([3]); correctionOf = null } }),
  #createParty({ kind = #natural; salt = salt32; identityCommit = salt32; dedupCommit = null; attributes = []; book = "HQ"; cddLevel = #standard; riskRating = #low; pep = false; reviewDue = 21000 }),
  #createCustomer({ party = { kind = #natural; salt = salt32; identityCommit = salt32; dedupCommit = null; attributes = []; book = "HQ"; cddLevel = #standard; riskRating = #low; pep = false; reviewDue = 21000 }; documents = []; screening = null; lifecycle = #prospect; extensions = []; accounts = []; application = null }),
  #amendParty({ party = 1; attributes = [] }),
  #setPartyLifecycle({ party = 1; to = #active }),
  #setPartyCdd({ party = 1; level = #enhanced; riskRating = #high; pep = true; reviewDue = 21000 }),
  #addPartyDocument({ party = 1; document = { kind = "identity"; commit = salt32; issued = 20000; expires = null } }),
  #addPartyRelationship({ party = 1; relationship = { kind = #guarantor; other = 2 } }),
  #setPartyExtension({ party = 1; values = [] }),
  #issueIdentifier({ party = 1 }),
  #commitScreeningList({ version = "v1"; root = salt32; count = 1; normalisation = "n" }),
  #proveScreeningClear({ party = 1; listVersion = "v1"; subject = Blob.fromArray([1]); proof = { lower = null; upper = null } }),
  #recordScreeningDecision({ party = 1; listVersion = "v1"; listRoot = salt32; decision = #clear; screener = p1; justificationCommit = salt32 }),
  #registerSchema({ id = "s1"; entity = #party; fields = [] }),
  #registerCollateral({ party = 1; kind = #cashDeposit; valuation = { amount = 1; currency = "EGP"; asOf = 20000; source = "x"; haircut = 0 }; descriptionCommit = salt32 }),
  #revalueCollateral({ collateral = 1; valuation = { amount = 2; currency = "EGP"; asOf = 20000; source = "x"; haircut = 0 } }),
  #allocateCollateral({ collateral = 1; facility = "f"; amount = 1 }),
  #releaseCollateral({ collateral = 1 }),
  #addStaff({ principal_ = p1; book = "HQ"; title = "teller" }),
  #removeStaff({ principal_ = p1 }),
  #setAccountFormat({ country = "EG"; bank = "0037"; branch = "0001"; serialWidth = 12; prefix = "00000" }),
  #setReviewGrace({ days = 30 }),
  #pinJwks({ issuer = "https://issuer.invalid"; keys = []; pinnedAtBlock = 0 }),
  #registerCredential({ subject = p1; kind = #passkey({ aaguid = Blob.fromArray([1]) }); assurance = #aal2; registeredAtBlock = 0; revokedAtBlock = null }),
  #revokeCredential({ subject = p1 }),
  // ── the product engine: the product engine ──
  #registerProduct({ id = "SAV"; name = "Savings"; terms = terms }),
  #amendProduct({ id = "SAV"; name = "Savings"; terms = terms }),
  #closeProductToNewAccounts({ id = "SAV"; version = 1 }),
  #openAccount({ product = "SAV"; party = 1; currency = "EGP"; termDays = null; allocationOrder = [] }),
  #setAccountStatus({ account = 1; to = #active }),
  #migrateAccount({ account = 1; to = 2 }),
  #openTill({ till = "T01"; book = "HQ"; currency = "EGP"; holder = p1; product = "TILL" }),
  #closeTill({ till = "T01" }),
  #grantFacility({ account = 1; limit = 1 }),
  #depositToAccount(move),
  #withdrawFromAccount(move),
  #transferBetweenAccounts({ from = 1; to = 2; amount = 1; postingDate = 20000; valueDate = 20000; period = "p"; narration = "n" }),
  #applyCharge({ account = 1; charge = "c"; occurrence = 20000; base = { amount = null; interest = null; outstanding = null }; postingDate = 20000; valueDate = 20000; period = "p"; narration = "n" }),
  #waiveCharge({ account = 1; charge = "c"; occurrence = 20000; postingDate = 20000; valueDate = 20000; period = "p"; reason = "r" }),
  #postAccrual({ product = "SAV"; currency = "EGP"; day = 20000; period = "p"; narration = "n" }),
  #capitaliseInterest({ product = "SAV"; currency = "EGP"; to = 20000; postingDate = 20000; period = "p"; narration = "n" }),
  #disburseLoan(move),
  #repayLoan(move),
  #rescheduleLoan({ account = 1; effective = 20000; terms = schedule; rate = { numerator = 1; denominator = 100; negative = false } }),
  #setProvision({ account = 1; asOf = 20000; postingDate = 20000; period = "p"; narration = "n" }),
  #writeOffLoan({ account = 1; postingDate = 20000; valueDate = 20000; period = "p"; narration = "n" }),
  #recordRecovery(move),
  #redeemTermDeposit(move),
  #allocateCashToTill({ till = "T01"; amount = 1; postingDate = 20000; valueDate = 20000; period = "p"; narration = "n" }),
  #returnCashFromTill({ till = "T01"; amount = 1; postingDate = 20000; valueDate = 20000; period = "p"; narration = "n" }),
  #settleTill({ till = "T01"; declared = 1; postingDate = 20000; valueDate = 20000; period = "p"; narration = "n" }),
  // ── value dating and the close: value dating, foreign currency and the close ──
  #setFunctionalCurrency({ currency = "EGP" }),
  #setFxPair({ pair = pair }),
  #setFxRate({ rate = fxRate }),
  #setBackValueWindow({ window = { book = "HQ"; freeDays = 5; approvedDays = 20 } }),
  #approveBackValue({ book = "HQ"; valueDate = 20000; reason = "r" }),
  #openDeferralSchedule({ schedule = deferral }),
  #bookFxDeal({ sell = "EGP"; sellAmount = 1; sellFrom = #glAccount("1001"); buy = "USD"; buyAmount = 1; buyTo = #glAccount("1001"); rateAsOf = 20000; postingDate = 20000; valueDate = 20000; period = "p"; narration = "n" }),
  #realiseFxPosition({ currency = "USD"; closedPosition = 1; bookedEquivalent = 1; proceeds = 1; postingDate = 20000; valueDate = 20000; period = "p"; narration = "n" }),
  #adjustAccrual({ product = "SAV"; currency = "EGP"; from = 20000; to = 20001; causedBy = 1; postingDate = 20000; period = "p"; narration = "n" }),
  #amortiseDeferral({ schedule = "d"; postingDate = 20000; valueDate = 20000; period = "p"; narration = "n" }),
  #openPeriodEnd({ book = "HQ"; period = "p" }),
  #recordClosingRates({ book = "HQ"; period = "p" }),
  #markAccrualComplete({ book = "HQ"; period = "p" }),
  #revaluePositions({ book = "HQ"; period = "p"; postingDate = 20000; narration = "n" }),
  #amortisePeriodDeferrals({ book = "HQ"; period = "p"; postingDate = 20000; narration = "n" }),
  #reconcilePeriod({ book = "HQ"; period = "p" }),
  #closePeriodEnd({ book = "HQ"; period = "p" }),
  #rollYearEnd({ book = "HQ"; period = "p"; retainedEarnings = "3200"; narration = "n" }),
  #setRetryPolicy({ policy = { book = "HQ"; limit = 3 } }),
  #defineStandingInstruction({ instruction = { id = "rent"; book = "HQ"; from = 10; to = 11; amount = 5_000_00; currency = "EGP"; everyDays = 30; startDay = 20697; endDay = ?20937; narration = "monthly rent" } }),
  #cancelStandingInstruction({ id = "rent" }),
  #openEndOfDay({ book = "HQ"; businessDate = 20726; shardSize = 128 }),
  #resolveBatchFailure({ book = "HQ"; businessDate = 20726; item = 9; entity = "17"; justification = "the customer never funded it; written to the exception report" }),
  #registerReportDefinition({ definition = sampleReportDef }),
  #registerReturnTemplate({ template = sampleReturnTemplate }),
  #setStatementMap({ book = "HQ"; map = sampleStatementMap }),
  #certifyReport({ definition = "R34"; version = 2; book = "HQ"; period = "2026-09"; view = #native; functional = null }),
  #certifyReturn({ template = "CBE-BS"; version = 1; book = "HQ"; period = "2026-09" }),
  #certifyExport({ shape = #normalisedTrialBalance; book = "HQ"; period = "2026-09" }),
  #issueStatement({ account = 137; kind = #camt053({ cut = 20726 }); period = "2026-09" }),
  #setFeedEndpoint({ endpoint = { url = "https://feed.example.test/thebes"; retries = [30, 120, 600]; active = true } }),
  #recordFeedDeadLetter({ letter = { cursor = 417; endpoint = "https://feed.example.test/thebes"; attempts = 4; reason = "504 from the consumer" } }),
  // ── indexing and bounded queries ──
  #setCounterpartyClassDimension({ dimension = ?{ schema = "thebes.party"; field = "sector" } }),
  // ── archive contracts ──
  #pinArchiveImage({ sha256 = "\e3\b0\c4\42\98\fc\1c\14\9a\fb\f4\c8\99\6f\b9\24\27\ae\41\e4\64\9b\93\4c\a4\95\99\1b\78\52\b8\56"; bytes = 182; name = "archive-child" }),
  #setArchiveControllers({ controllers = [Principal.fromBlob("\6E\3E\78\13"), Principal.fromBlob("\7A\01")] }),
  #spawnArchive({ purpose = "2026-09 postings" }),
  #abandonArchiveSpawn({ spawn = 41; reason = "the create was rejected" }),
  #attachArchiveChild({ spawn = 42; cid = 1_000_001 : Nat64 }),
  #adoptArchiveChild({ cid = 1_000_007 : Nat64; moduleHash = "\e3\b0\c4\42\98\fc\1c\14\9a\fb\f4\c8\99\6f\b9\24\27\ae\41\e4\64\9b\93\4c\a4\95\99\1b\78\52\b8\56"; controllers = [Principal.fromBlob("\6E\3E\78\13")]; purpose = "operator-deployed" }),
  // ── monitoring: the closed rule set ──
  #defineMonitoringRule({ id = "structuring-egp"; currency = ?"EGP"; spec = #structuring({ threshold = 500_000_00; bandPercent = 10; count = 3; windowDays = 7; maxScan = 2_000 }) }),
  #retireMonitoringRule({ id = "structuring-egp" }),
  // ── alerts ──
  #clearAlert({ alert = 901; reason = "the customer's salary, as expected" }),
  #escalateAlert({ alert = 902; reportRef = "STR-2026-000017" }),
  #setCollectionsPolicy({ delinquentDpd = 31; defaultDpd = 90; suspendInterestFrom = #default_; recogniseModificationLoss = true }),
  #markUnlikelyToPay({ account = 7; reason = "bankruptcy filing" }),
  #recordCollectionAction({ account = 7; action = #call; outcome = "no answer"; next = ?20710 }),
  #recordPromiseToPay({ account = 7; amount = 5_000_00; by = 20715 }),
  #assignCollector({ account = 7; staff = p1 }),
  #closeRecovery({ account = 7 }),
  // origination and underwriting (origination and underwriting)
  #setOriginationPolicy({ rpId = "bank.example"; origin = "https://bank.example"; offerValidityDays = 14; bureaus = [("I-SCORE", #none, ""), ("PQ-BUREAU", #mldsa44, Blob.fromArray([9, 8, 7]))] }),
  #setAffordabilityModel({ id = "retail-v1"; version = 1; rules = [{ id = "dsr-45"; kind = #maxDebtServiceRatioBps(4500); onFail = #fail }, { id = "res"; kind = #minResidualIncome(2_500_00); onFail = #fail }, { id = "term"; kind = #maxTermDays(1826); onFail = #fail }, { id = "amt"; kind = #maxAmount(500_000_00); onFail = #refer }, { id = "inc"; kind = #minIncome(3_000_00); onFail = #refer }] }),
  #setScorecard({ id = "retail-card"; version = 2; attributes = [(#income, [{ lo = 0; hi = ?4_999_99; points = 10 }, { lo = 5_000_00; hi = null; points = 25 }]), (#obligationsRatioBps, [{ lo = 0; hi = ?2000; points = 30 }]), (#bureauScore, [{ lo = 700; hi = null; points = 35 }]), (#bureauFlags, [{ lo = 0; hi = ?0; points = 10 }]), (#termDays, [{ lo = 0; hi = ?365; points = 10 }]), (#amount, [{ lo = 0; hi = null; points = 1 }])]; declineBelow = 50; referBelow = 80 }),
  #registerPasskey({ party = 7; credentialId = OV.CREDENTIAL; publicKeySpki = OV.SPKI }),
  #openApplication({ party = ?7; book = "HQ"; request = { product = "PL-STD"; amount = 120_000_00; currency = "EGP"; termDays = 730; purpose = "car" }; channel = "branch" }),
  #recordApplicationData({ application = 900; facts = { income = 20_000_00; obligations = 2_000_00; proposedInstalment = 5_000_00; dependants = 2 }; commitments = [("employer", segHash32), ("address", segHash32)] }),
  #assessAffordability({ application = 900 }),
  #requestBureauReport({ application = 900; bureau = "I-SCORE"; consentCommit = segHash32 }),
  #scoreApplication({ application = 900 }),
  #underwrite({ application = 900; decision = #approve({ amount = 100_000_00; termDays = 730; rateBps = 1800; conditions = ["salary-assignment", "insurance"] }); rationale = "" }),
  #issueOffer({ application = 900; terms = { amount = 90_000_00; termDays = 730; rateBps = 1800; product = "PL-STD"; currency = "EGP"; conditions = ["salary-assignment", "insurance"] } }),
  #acceptOffer({ application = 900; assertion = { credentialId = OV.CREDENTIAL; authenticatorData = OV.ASSERTIONS[0].2; clientDataJSON = OV.ASSERTIONS[0].3; signature = OV.ASSERTIONS[0].4 } }),
  #declineOffer({ application = 901 }),
  #recordDocument({ application = 900; kind = #facilityAgreement; sha256 = segHash32; signed = null }),
  #recordConditionsMet({ application = 900; conditions = ["insurance"] }),
  #fulfilApplication({ application = 900 }),
  #withdrawApplication({ application = 903; reason = "found another lender" }),
  #openFacility({ party = 7; book = "HQ"; product = "FACL"; kind = #revolving({ commitmentFeeBps = 50; cleanDown = ?{ everyDays = 30; forDays = 5 } }); currency = "EGP"; limit = 1_000_000_00; availabilityFrom = 20726; availabilityTo = 21091; pricing = #floating({ index = "CBE-ON"; spreadBps = 250; resetDays = 30 }); covenants = [{ id = "leverage"; kind = #financialRatio({ name = "net debt / EBITDA"; op = #atMost; thresholdBps = 35_000 }) }, { id = "accounts"; kind = #reporting({ due = 20800 }) }, { id = "npl"; kind = #negativePledge }]; collateral = [3]; reviewEvery = ?365 }),
  #drawdown({ facility = 500; amount = 250_000_00; funding = #glAccount("1999"); postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s31" }),
  #transferParticipation({ facility = 501; from = 8; to = 9; bps = 500 }),
  #distributeToParticipants({ facility = 501; funding = #glAccount("1999"); postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s31" }),
  #restructureFacility({ facility = 500; effective = 20800; terms = { schedule = { amortisation = #equalInstalments; instalments = 9; every = #monthly; principalGrace = 0; interestGrace = 0; moratoriumDays = 0 }; rateBps = 1500 } }),
  #recordCovenantTest({ facility = 500; covenant = "leverage"; value = 28_000; statementHash = segHash32 }),
  #blockDrawdowns({ facility = 500; reason = "covenant review" }),
  #unblockDrawdowns({ facility = 500; reason = "review complete" }),
  #recordFacilityReview({ facility = 500; note = "annual review" }),
  #recordRateFixing({ index = "CBE-ON"; day = 20726; rateBps = 900 }),
  #receiveRental({ facility = 504; amount = 30_000_00; funding = #glAccount("1999"); postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s31" }),
  #remeasureResidual({ facility = 503; residual = 15_000_00; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s31" }),
  #purchaseReceivables({ facility = 505; receivables = [{ ref = segHash32; debtorCommit = segHash32; face = 120_000_00; due = 20800 }]; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s31" }),
  #collectReceivable({ facility = 505; ref = segHash32; funding = #glAccount("1999"); postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s31" }),
  #dishonourReceivable({ facility = 505; ref = segHash32; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s31" }),
  #writeOffReceivable({ facility = 505; ref = segHash32; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s31" }),
  #closeFacility({ facility = 507 }),
  // ── closed-month packing ──
  #openPacking({ period = "2026-09" }),
  #rollPackToArchive({ pack = 1; cid = 1_000_003 : Nat64; archive = Principal.fromBlob("\6E\3E\78\13") }),
  // ── shards ──
  #declareShardRule({ self = 0; shards = [{ index = 0; principal = Principal.fromBlob("\6E\3E\78\13"); settlement = "1901" }, { index = 1; principal = Principal.fromBlob("\6E\3E\78\14"); settlement = "1900" }] }),
  #openShardTransfer({ from = 284; toIdentifier = "EG870037000100000001000000000031"; amount = 250_000; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "to the other shard" }),
  // ── settlement ──
  #declareScheme({ id = "EGP-RTGS"; granularity = #net; interchange = #multilateral; delay = #deferred; reconciliation = "1999"; feeIncome = "4100"; interchangeBps = 25; hubFeeBps = 5; alarmPercent = 90 }),
  #registerParticipant({ party = 12; bic = "CIBEEGCX"; scheme = "EGP-RTGS"; accounts = [{ currency = "EGP"; position = 301; settlement = 302; feeReceivable = 304 }] }),
  #deactivateParticipant({ participant = 310 }),
  #recordFunds({ participant = 310; currency = "EGP"; amount = 500_000_00; direction = #in_; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "prefunding" }),
  #prepareTransfer({ scheme = "EGP-RTGS"; payer = 310; payee = 311; currency = "EGP"; amount = 1_250_00; reference = "8f1e3a9c-0000-4000-8000-000000000001"; ttlSeconds = 300 }),
  #fulfilTransfer({ transfer = 400 }),
  #rejectTransfer({ transfer = 401; reason = "payee unknown" }),
  #errorTransfer({ transfer = 402; reason = "timeout at the payee" }),
  #openSettlementWindow({ scheme = "EGP-RTGS"; businessDate = 20726 }),
  #closeSettlementWindow({ window = 500 }),
  #openSettlement({ window = 500 }),
  #abortSettlement({ settlement = 501; reason = "a participant disputed its position" }),
  #receiveBulk({ scheme = "EGP-RTGS"; payer = 310; reference = "BULK-7"; ttlSeconds = 600; requests = [{ payee = 311; currency = "EGP"; amount = 100_00; reference = "a" }, { payee = 312; currency = "EGP"; amount = 200_00; reference = "b" }] }),
  #fulfilBulk({ bulk = 600 }),
  #rejectBulk({ bulk = 601; reason = "cancelled by the payer" }),
  // ISO 20022 messaging
  #declareRail({ id = "RTGS"; scheme = "EGP-RTGS"; ttlSeconds = 600; hold = { holdAbove = [("EGP", 5_000_000_00)]; blockedBics = []; blockedNameFragments = [] }; signatures = #mldsa44 }),
  #registerConnectorKey({ rail = "RTGS"; bic = "CIBEEGCX"; scheme = #mldsa44; publicKey = "" : Blob }),
  #releaseHold({ transfer = 700; reason = "reviewed" }),
  #rejectHold({ transfer = 701; reason = "sanctions match" }),
  // FSPIOP interoperability
  #declareFspiopParticipant({ rail = "RTGS"; participant = 310; fspId = "dfspa"; endpoints = [("FSPIOP_CALLBACK_URL_TRANSFER_POST", "http://dfspa.local/transfers")] }),
  // the declared the extended target list list
  #grantDebitAuthority({ rail = "RTGS"; debtor = 311; creditorBic = "CIBEEGCX"; currency = "EGP"; maxAmount = 5_000_00 }),
  #revokeDebitAuthority({ rail = "RTGS"; debtor = 311; creditorBic = "CIBEEGCX"; currency = "EGP" }),
  #decideMandate({ rail = "RTGS"; mandateId = "MNDT-1"; accepted = false; reason = ?"customer declined" }),
];

var resolved = 0;
var moneyMoving = 0;
for (c in commands.vals()) {
  let name = P.commandName(c);
  switch (P.forCommand(c)) {
    case null { Debug.print("no permission for command " # name); assert false };
    case (?perm) {
      assert (Text.size(perm.id) > 0);
      switch (perm.guards) {
        case (#command(target)) { assert (Text.equal(target, name)) };
        case (#method(m)) { Debug.print("command " # name # " is guarded by method " # m); assert false };
      };
      if (perm.moneyMoving) { moneyMoving += 1; assert perm.dualByDefault };
      resolved += 1;
    };
  };
};
Debug.print("count: command variants resolved to a permission = " # Nat.toText(resolved));
Debug.print("count: money-moving command permissions = " # Nat.toText(moneyMoving));
assert (resolved == commands.size());

// Every command entry in the catalogue is covered by the list above: the number
// of catalogue entries guarding a command must equal the number of variants.
var commandEntries = 0;
var methodEntries = 0;
for (x in P.catalogue().vals()) {
  switch (x.guards) { case (#command(_)) commandEntries += 1; case (#method(_)) methodEntries += 1 };
};
Debug.print("count: catalogue entries guarding a command = " # Nat.toText(commandEntries));
Debug.print("count: catalogue entries guarding a method = " # Nat.toText(methodEntries));
assert (commandEntries == commands.size());
assert (methodEntries == 21);   // 6 maker-checker, 11 archive steps, the message ingest, the FSPIOP request, the bureau report (origination and underwriting), the agent's notice (corporate lending)
assert (commandEntries == 185);   // 143 + createCustomer (one dual act) + journalSetCalendarAuthority (the Thebes clock finding of the same day) + the six collections acts (collections and recovery) + the seventeen origination acts (origination and underwriting) + the seventeen facility acts (corporate lending)

// Identifiers are unique, and every identifier resolves through `find`.
let ids = P.ids();
var i = 0;
var uniqueChecks = 0;
while (i < ids.size()) {
  assert (P.exists(ids[i]));
  var j = i + 1;
  while (j < ids.size()) {
    if (Text.equal(ids[i], ids[j])) { Debug.print("duplicate permission " # ids[i]); assert false };
    uniqueChecks += 1;
    j += 1;
  };
  i += 1;
};
Debug.print("count: permission identifier pair comparisons = " # Nat.toText(uniqueChecks));
assert (P.count() == ids.size());
assert (P.count() == commandEntries + methodEntries);

// Money-moving implies dual by default, with the single stated exception of the
// break-glass permission, whose control is the witness plus the review.
var moneyTotal = 0;
var exceptions = 0;
for (x in P.catalogue().vals()) {
  if (x.moneyMoving) {
    moneyTotal += 1;
    if (not x.dualByDefault) {
      assert (Text.equal(x.id, "command.breakGlass"));
      exceptions += 1;
    };
  };
};
Debug.print("count: money-moving permissions in the catalogue = " # Nat.toText(moneyTotal));
assert (P.moneyMovingCount() == moneyTotal);
assert (exceptions == 1);

// A permission that does not exist resolves to nothing.
assert (not P.exists("no.such.permission"));
assert (P.byMethod("noSuchMethod") == null);
assert (P.byCommandName("noSuchCommand") == null);
Debug.print("count: unknown-identifier lookups refused = 3");

// Every deliberately open method has a reason.
var opens = 0;
for ((m, reason) in P.openMethods().vals()) {
  assert (Text.size(m) > 0 and Text.size(reason) > 0);
  opens += 1;
};
Debug.print("count: deliberately open methods with a stated reason = " # Nat.toText(opens));
// Twelve, and only twelve: the proposal expiry sweep, the three advances (end of day, packing,
// archive roll), the archive's acknowledgement, the four steps of an inter-shard transfer after
// its dual-authorised opening, the reservation expiry sweep, and the settlement and bulk advances. All are paths where the caller chooses nothing — expiry
// is a fact of the clock, an advance can only execute the plan the opening block already
// fixed, and the acknowledgements and the receive are held to the declared counterpart's
// principal and to the act's own key or hash — and the advances would leave a bank stuck
// behind a stalled timer if they were guarded.
assert (opens == 12);
var openNames = "";
for ((m, _) in P.openMethods().vals()) { openNames #= m # " " };
assert (Text.contains(openNames, #text "expireProposals"));
assert (Text.contains(openNames, #text "advanceEndOfDay"));
assert (Text.contains(openNames, #text "advancePacking"));
assert (Text.contains(openNames, #text "advanceArchiveRoll"));
assert (Text.contains(openNames, #text "acknowledgeArchivedSegment"));
for (m in ["sendShardTransfer", "receiveShardTransfer", "acknowledgeShardTransfer", "rejectShardTransfer", "expireTransfers", "advanceSettlement", "advanceBulk"].vals()) assert (Text.contains(openNames, #text m));

Debug.print("PERMISSIONS TEST GREEN");
