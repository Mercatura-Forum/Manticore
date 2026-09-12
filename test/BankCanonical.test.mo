// BankCanonical.test.mo — the command hash a checker approves.
//
// `commandHash` is the hash the maker-checker path binds a proposal to: a
// deterministic function of the command, sensitive to every field, so "the
// approved bytes execute" is enforceable. Proved here over one value of every
// `Command` variant, which is also how a new variant missing from the codec is
// caught.
//
// The block encoding and its byte-flip tamper sweep are in
// test/BankTamper.test.mo, which is WASI-only and says why in its own header.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Nat64 "mo:core/Nat64";

import T "../src/bank/BankTypes";
import ProdT "../src/bank/ProductTypes";
import CT "../src/bank/CloseTypes";
import RepT "../src/bank/ReportTypes";
import C "../src/bank/BankCanonical";

let alice = Principal.fromBlob("\A1\01");
let bob = Principal.fromBlob("\B0\02");
let carol = Principal.fromBlob("\C0\03");

let fullScope : T.Scope = {
  books = ?["HQ", "BR01"];
  currencies = ?["EGP", "USD"];
  ceiling = ?[{ currency = "EGP"; amount = 50_000_00 }, { currency = "USD"; amount = 1_000_00 }];
  dailyLimit = ?[{ currency = "EGP"; amount = 500_000_00 }];
};
let emptyScope : T.Scope = { books = null; currencies = null; ceiling = null; dailyLimit = null };

let legs : [{ account : Text; subledger : ?Blob; side : { #debit; #credit }; currency : Text; amount : Nat }] = [
  { account = "1001"; subledger = null; side = #debit; currency = "EGP"; amount = 1_234_56 },
  { account = "2110"; subledger = ?Blob.fromArray([7, 7, 7]); side = #credit; currency = "EGP"; amount = 1_234_56 },
];

func commit32(n : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((n * 7 + i) % 256) })) };
let salt32 : Blob = commit32(1);

let manual : T.ManualEntry = {
  book = "BR01"; postingDate = 20705; valueDate = 20704; period = "2026-09";
  legs; narration = "manual entry — عربي — <xml> & 'quotes'";
  idempotencyKey = Blob.fromArray(Array.tabulate<Nat8>(64, func(i) { Nat8.fromNat(i) }));
  correctionOf = ?41;
};

// ─── the product engine product fixtures: one value of every shape the terms can take ──────

func pRate(n : Nat, d : Nat) : ProdT.Rate { { numerator = n; denominator = d; negative = false } };

let scheduleTerms : ProdT.ScheduleTerms = {
  amortisation = #balloon({ finalPrincipal = 200_000 });
  instalments = 18; every = #quarterly; principalGrace = 2; interestGrace = 1; moratoriumDays = 15;
};

let savingsTerms : ProdT.ProductTerms = {
  kind = #savings;
  currency = "EGP";
  control = "2110";
  roles = [
    { role = #principal; account = "2110" },
    { role = #interestPayable; account = "2120" },
    { role = #interestExpense; account = "5100" },
    { role = #feeIncome; account = "4100" },
  ];
  interest = ?{
    chart = { bands = [{ from = 0; to = ?100_000; rate = pRate(2, 100) }, { from = 100_000; to = null; rate = pRate(5, 100) }]; by = #balance };
    convention = #a004_Act365Fixed;
    basis = #dailyBalance;
    compounding = #monthly;
    compoundingAlignment = #anniversary;
    posting = #quarterly;
    minimumBalance = 10_000;
    allowNegative = false;
  };
  charges = [
    { id = "ledger-fee"; calculation = #flat({ amount = 1_000 }); timing = #recurring({ every = #monthly }); currency = "EGP"; role = #feeIncome; waivable = true },
    { id = "txn-fee"; calculation = #percentOfAmount({ rate = pRate(1, 200) }); timing = #onTransaction; currency = "EGP"; role = #feeIncome; waivable = true },
    { id = "open-fee"; calculation = #flat({ amount = 5_000 }); timing = #onActivation; currency = "EGP"; role = #feeIncome; waivable = false },
    { id = "close-fee"; calculation = #percentOfInterest({ rate = pRate(10, 100) }); timing = #onClosure; currency = "EGP"; role = #feeIncome; waivable = true },
    { id = "dated-fee"; calculation = #flat({ amount = 700 }); timing = #onDate({ day = 20800 }); currency = "EGP"; role = #feeIncome; waivable = true },
    { id = "late-fee"; calculation = #percentOfPrincipalOutstanding({ rate = pRate(2, 100) }); timing = #overdue({ afterDays = 7 }); currency = "EGP"; role = #feeIncome; waivable = true },
  ];
  limits = { overdraft = ?50_000; minimumOperating = 10_000; perOperation = ?1_000_000 };
  schedule = null;
  delinquency = [];
  provisioning = [];
  accounting = #accrualPeriodic;
  withholdingTax = ?pRate(20, 100);
  rounding = #halfEven;
  earlyRedemptionPenalty = null;
  valueDateConvention = #following;
};

let loanTerms : ProdT.ProductTerms = {
  kind = #loan;
  currency = "EGP";
  control = "1210";
  roles = [
    { role = #principal; account = "1210" },
    { role = #interestReceivable; account = "1220" },
    { role = #interestIncome; account = "4200" },
    { role = #feeIncome; account = "4100" },
    { role = #penaltyIncome; account = "4110" },
    { role = #feeReceivable; account = "1230" },
    { role = #penaltyReceivable; account = "1240" },
    { role = #writeOff; account = "5210" },
    { role = #recovery; account = "4300" },
    { role = #allowance; account = "1290" },
    { role = #impairmentExpense; account = "5200" },
    { role = #overdraftPortfolio; account = "1300" },
    { role = #suspense; account = "1900" },
    { role = #cash; account = "1001" },
    { role = #taxPayable; account = "2300" },
  ];
  interest = ?{
    chart = { bands = [{ from = 0; to = ?365; rate = pRate(12, 100) }, { from = 365; to = null; rate = pRate(14, 100) }]; by = #termDays };
    convention = #a001_ActActIcma({ couponsPerYear = 4 });
    basis = #averageDailyBalance;
    compounding = #semiAnnual;
    compoundingAlignment = #anniversary;
    posting = #atMaturity;
    minimumBalance = 0;
    allowNegative = true;
  };
  charges = [];
  limits = { overdraft = null; minimumOperating = 0; perOperation = null };
  schedule = ?scheduleTerms;
  delinquency = [
    { name = "current"; fromDays = 0; toDays = ?31 },
    { name = "30-59"; fromDays = 31; toDays = ?61 },
    { name = "90+"; fromDays = 61; toDays = null },
  ];
  provisioning = [
    { band = "current"; stage = 1; percentOfOutstanding = pRate(1, 100) },
    { band = "30-59"; stage = 2; percentOfOutstanding = pRate(20, 100) },
    { band = "90+"; stage = 3; percentOfOutstanding = pRate(100, 100) },
  ];
  accounting = #cash;
  withholdingTax = null;
  rounding = #down;
  earlyRedemptionPenalty = null;
  valueDateConvention = #following;
};


// ─── value dating and the close close fixtures: one value of every shape the close can record ──────

let usdPair : CT.PositionPair = {
  currency = "USD"; position = "1410"; equivalent = "1411";
  unrealised = "4410"; realised = "4411"; monetary = true;
};
let kwdPair : CT.PositionPair = {
  currency = "KWD"; position = "1420"; equivalent = "1421";
  unrealised = "4410"; realised = "4411"; monetary = false;
};
let usdRate : CT.Rate = {
  currency = "USD"; functional = "EGP"; numerator = 4850; denominator = 100;
  asOf = 20726; source = "central bank reference";
};
let window : CT.BackValueWindow = { book = "BR01"; freeDays = 5; approvedDays = 20 };
let unearnedSchedule : CT.Schedule = {
  id = "arrangement-fee-2026"; kind = #unearnedIncome; currency = "EGP";
  amount = 1_200_00; periods = 12; deferralAccount = "2400";
  recognitionAccount = "4100"; book = "HQ"; openedOn = 20697;
};
let prepaidSchedule : CT.Schedule = {
  unearnedSchedule with id = "rent-2026"; kind = #prepaidExpense;
  deferralAccount = "1450"; recognitionAccount = "5300"; amount = 600_00; periods = 6;
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

let commands : [T.Command] = [
  #defineRole({ id = "checker"; name = "Checker"; permissions = ["command.approve", "role.grant"] }),
  #grantRole({ subject = alice; role = "checker"; scope = fullScope }),
  #grantRole({ subject = bob; role = "maker"; scope = emptyScope }),
  #revokeRole({ subject = alice; role = "checker" }),
  #setDualPolicy({ permission = "journal.entry.create"; required = 2; eligibleRole = "checker"; ttlSeconds = 86_400 }),
  #clearDualPolicy({ permission = "book.create" }),
  #openBook({ id = "BR01"; name = "Branch 1"; parent = ?"HQ" }),
  #openBook({ id = "HQ"; name = "Head office"; parent = null }),
  #closeBook({ id = "BR01" }),
  #transferBankAdmin({ admin = carol }),
  #setFeatureActivation({ feature = "manual-entry"; height = 0xFFFF_FFFF_FFFF_FFFF }),
  #setFeatureActivation({ feature = "manual-entry"; height = 17 : Nat64 }),
  #journalRegisterCurrency({ code = "EGP"; minorUnits = 2 }),
  #journalOpenAccount({ code = "2110"; name = "Customer deposits"; normalSide = #credit; category = #liability; constraint = #debitsNotExceedCredits }),
  #journalCloseAccount({ code = "2110" }),
  #journalOpenPeriod({ id = "2026-09"; start = 20697; end = 20726 }),
  #journalClosePeriod({ id = "2026-09" }),
  #journalSetActivationHeight({ height = 0 }),
  #journalSetLeadsheetSchema({ ranges = [{ lo = 1000; hi = 1099; leadsheet = "1"; name = "PPE"; category = "non_current_assets"; cycle = "ppe" }] }),
  #journalAddPoster({ poster = bob }),
  #journalRemovePoster({ poster = bob }),
  #journalSetPosterScope({ poster = bob; accounts = ?["1001", "2110"] }),
  #journalSetPosterScope({ poster = bob; accounts = null }),
  #journalRollBusinessDate({ day = 20705 }),
  #journalSetCalendar({ calendar = ?{ restDays = [4, 5]; holidays = [20710, 20711]; policy = #nearest } }),
  #journalSetCalendar({ calendar = null }),
  #postManualEntry(manual),
  #reverseManualEntry({ original = 41; book = "BR01"; postingDate = 20706; valueDate = 20706; period = "2026-09"; narration = "reversal"; idempotencyKey = Blob.fromArray([9, 9]) }),
  // ── party and KYC: party / CIF and KYC ──
  #postManualEntryForParty({ party = 17; entry = manual }),
  #createParty({ kind = #natural; salt = salt32; identityCommit = commit32(7); dedupCommit = ?commit32(8); attributes = [{ name = "screeningSubject"; commit = commit32(9) }, { name = "nationalId"; commit = commit32(10) }]; book = "BR01"; cddLevel = #enhanced; riskRating = #high; pep = true; reviewDue = 21000 }),
  #createParty({ kind = #legal; salt = salt32; identityCommit = commit32(11); dedupCommit = null; attributes = []; book = "HQ"; cddLevel = #simplified; riskRating = #low; pep = false; reviewDue = 21001 }),
  #createCustomer({
    party = { kind = #natural; salt = salt32; identityCommit = commit32(7); dedupCommit = ?commit32(8); attributes = [{ name = "screeningSubject"; commit = commit32(9) }]; book = "BR01"; cddLevel = #standard; riskRating = #low; pep = false; reviewDue = 21000 };
    documents = [{ kind = "identity"; commit = commit32(12); issued = 20_000; expires = null }, { kind = "address"; commit = commit32(13); issued = 20_100; expires = ?22_000 }];
    screening = ?{ listVersion = "2026-09"; listRoot = commit32(14); decision = #clear; screener = bob; justificationCommit = commit32(15) };
    lifecycle = #active;
    extensions = [{ schema = "kyc"; name = "sector"; value = #enumerated("retail") }];
    accounts = [{ product = "SAV-01"; currency = "EGP"; termDays = null; allocationOrder = []; activate = true }, { product = "TD-12"; currency = "EGP"; termDays = ?365; allocationOrder = [#interest, #principal]; activate = false }];
  }),
  #createCustomer({
    party = { kind = #legal; salt = salt32; identityCommit = commit32(11); dedupCommit = null; attributes = []; book = "HQ"; cddLevel = #simplified; riskRating = #low; pep = false; reviewDue = 21001 };
    documents = []; screening = null; lifecycle = #prospect; extensions = []; accounts = [];
  }),
  #amendParty({ party = 17; attributes = [{ name = "address"; commit = commit32(12) }] }),
  #setPartyLifecycle({ party = 17; to = #active }),
  #setPartyLifecycle({ party = 17; to = #blocked }),
  #setPartyCdd({ party = 17; level = #standard; riskRating = #medium; pep = false; reviewDue = 21100 }),
  #addPartyDocument({ party = 17; document = { kind = "identity"; commit = commit32(13); issued = 20000; expires = ?21000 } }),
  #addPartyDocument({ party = 17; document = { kind = "address"; commit = commit32(14); issued = 20000; expires = null } }),
  #addPartyRelationship({ party = 17; relationship = { kind = #guarantor; other = 18 } }),
  #addPartyRelationship({ party = 17; relationship = { kind = #other("trustee"); other = 19 } }),
  #setPartyExtension({ party = 17; values = [
    { schema = "kyc"; name = "sector"; value = #enumerated("retail") },
    { schema = "kyc"; name = "employees"; value = #integer(-42) },
    { schema = "kyc"; name = "note"; value = #text("a note") },
    { schema = "kyc"; name = "onboarded"; value = #date(20700) },
    { schema = "kyc"; name = "resident"; value = #boolean(true) },
    { schema = "kyc"; name = "taxIdCommit"; value = #commitment(commit32(15)) },
  ] }),
  #issueIdentifier({ party = 17 }),
  #commitScreeningList({ version = "UN-2026-09"; root = commit32(16); count = 5000; normalisation = "thebes-norm-v1" }),
  #proveScreeningClear({ party = 17; listVersion = "UN-2026-09"; subject = Blob.fromArray([65, 66, 67]); proof = {
    lower = ?{ entry = Blob.fromArray([65]); index = 3; path = [commit32(17), commit32(18)] };
    upper = ?{ entry = Blob.fromArray([66]); index = 4; path = [commit32(19)] };
  } }),
  #proveScreeningClear({ party = 17; listVersion = "UN-2026-09"; subject = Blob.fromArray([1]); proof = { lower = null; upper = ?{ entry = Blob.fromArray([2]); index = 0; path = [] } } }),
  #recordScreeningDecision({ party = 17; listVersion = "UN-2026-09"; listRoot = commit32(16); decision = #hit({ matches = 3 }); screener = carol; justificationCommit = commit32(20) }),
  #recordScreeningDecision({ party = 17; listVersion = "UN-2026-09"; listRoot = commit32(16); decision = #cleared({ reason = "different date of birth" }); screener = carol; justificationCommit = commit32(21) }),
  #recordScreeningDecision({ party = 17; listVersion = "UN-2026-09"; listRoot = commit32(16); decision = #confirmed; screener = carol; justificationCommit = commit32(22) }),
  #registerSchema({ id = "kyc"; entity = #party; fields = [
    { name = "sector"; fieldType = #enumerated(["retail", "corporate"]); required = true },
    { name = "employees"; fieldType = #integer({ min = -100; max = 100000 }); required = false },
    { name = "note"; fieldType = #text({ maxBytes = 128 }); required = false },
    { name = "onboarded"; fieldType = #date; required = false },
    { name = "resident"; fieldType = #boolean; required = false },
    { name = "taxIdCommit"; fieldType = #commitment; required = false },
  ] }),
  #registerCollateral({ party = 17; kind = #property; valuation = { amount = 5_000_000_00; currency = "EGP"; asOf = 20700; source = "valuer A"; haircut = 30 }; descriptionCommit = commit32(23) }),
  #registerCollateral({ party = 17; kind = #tokenisedTitle({ registry = carol; tokenId = 77 }); valuation = { amount = 1_000_000_00; currency = "EGP"; asOf = 20700; source = "registry"; haircut = 20 }; descriptionCommit = commit32(24) }),
  #revalueCollateral({ collateral = 51; valuation = { amount = 4_000_000_00; currency = "EGP"; asOf = 20720; source = "valuer B"; haircut = 30 } }),
  #allocateCollateral({ collateral = 51; facility = "LOAN-1"; amount = 1_000_000_00 }),
  #releaseCollateral({ collateral = 51 }),
  #addStaff({ principal_ = alice; book = "BR01"; title = "branch manager" }),
  #removeStaff({ principal_ = alice }),
  #setAccountFormat({ country = "EG"; bank = "0037"; branch = "0001"; serialWidth = 12; prefix = "00000" }),
  #setReviewGrace({ days = 45 }),
  #pinJwks({ issuer = "https://login.example.invalid"; keys = [{ kid = "k1"; n = commit32(25); e = Blob.fromArray([1, 0, 1]) }]; pinnedAtBlock = 9 }),
  #registerCredential({ subject = alice; kind = #passkey({ aaguid = Blob.fromArray([0xAA, 0xBB]) }); assurance = #aal2; registeredAtBlock = 3; revokedAtBlock = null }),
  #registerCredential({ subject = bob; kind = #oidc({ issuer = "https://login.example.invalid"; subjectCommit = commit32(26) }); assurance = #aal2; registeredAtBlock = 4; revokedAtBlock = ?9 }),
  #revokeCredential({ subject = alice }),
  // ── the product engine: the product engine ──
  #registerProduct({ id = "SAV"; name = "Savings"; terms = savingsTerms }),
  #registerProduct({ id = "LOAN"; name = "Term loan"; terms = loanTerms }),
  #amendProduct({ id = "SAV"; name = "Savings v2"; terms = savingsTerms }),
  #closeProductToNewAccounts({ id = "SAV"; version = 1 }),
  #openAccount({ product = "SAV"; party = 17; currency = "EGP"; termDays = null; allocationOrder = [] }),
  #openAccount({ product = "FD"; party = 17; currency = "EGP"; termDays = ?182; allocationOrder = [#principal, #interest, #fee, #penalty] }),
  #setAccountStatus({ account = 61; to = #active }),
  #setAccountStatus({ account = 61; to = #closed }),
  #migrateAccount({ account = 61; to = 2 }),
  #openTill({ till = "T01"; book = "BR01"; currency = "EGP"; holder = alice; product = "TILL" }),
  #closeTill({ till = "T01" }),
  #grantFacility({ account = 61; limit = 50_000_00 }),
  #depositToAccount({ account = 61; amount = 1_000_00; postingDate = 20705; valueDate = 20705; period = "2026-09"; narration = "cash in"; funding = #till("T01") }),
  #depositToAccount({ account = 61; amount = 1_000_00; postingDate = 20705; valueDate = 20704; period = "2026-09"; narration = "transfer in"; funding = #glAccount("1999") }),
  #withdrawFromAccount({ account = 61; amount = 250_00; postingDate = 20705; valueDate = 20705; period = "2026-09"; narration = "cash out"; funding = #till("T01") }),
  #transferBetweenAccounts({ from = 61; to = 62; amount = 500_00; postingDate = 20705; valueDate = 20705; period = "2026-09"; narration = "standing instruction" }),
  #applyCharge({ account = 61; charge = "ledger-fee"; occurrence = 20705; base = { amount = null; interest = null; outstanding = null }; postingDate = 20705; valueDate = 20705; period = "2026-09"; narration = "monthly fee" }),
  #applyCharge({ account = 61; charge = "txn-fee"; occurrence = 20705; base = { amount = ?1_000_00; interest = ?86; outstanding = ?600_000 }; postingDate = 20705; valueDate = 20705; period = "2026-09"; narration = "transaction fee" }),
  #waiveCharge({ account = 61; charge = "ledger-fee"; occurrence = 20705; postingDate = 20706; valueDate = 20706; period = "2026-09"; reason = "goodwill" }),
  #postAccrual({ product = "SAV"; currency = "EGP"; day = 20705; period = "2026-09"; narration = "daily accrual" }),
  #capitaliseInterest({ product = "SAV"; currency = "EGP"; to = 20726; postingDate = 20726; period = "2026-09"; narration = "monthly capitalisation" }),
  #disburseLoan({ account = 63; amount = 600_000; postingDate = 20705; valueDate = 20705; period = "2026-09"; narration = "disbursement"; funding = #glAccount("1999") }),
  #repayLoan({ account = 63; amount = 52_500; postingDate = 20705; valueDate = 20705; period = "2026-09"; narration = "repayment"; funding = #till("T01") }),
  #rescheduleLoan({ account = 63; effective = 20760; terms = scheduleTerms; rate = { numerator = 10; denominator = 100; negative = false } }),
  #setProvision({ account = 63; asOf = 20800; postingDate = 20800; period = "2026-09"; narration = "provision" }),
  #writeOffLoan({ account = 63; postingDate = 20800; valueDate = 20800; period = "2026-09"; narration = "written off" }),
  #recordRecovery({ account = 63; amount = 100_000; postingDate = 20810; valueDate = 20810; period = "2026-09"; narration = "recovery"; funding = #glAccount("1999") }),
  #redeemTermDeposit({ account = 62; amount = 1_049_863; postingDate = 20880; valueDate = 20880; period = "2026-09"; narration = "maturity"; funding = #glAccount("1999") }),
  #allocateCashToTill({ till = "T01"; amount = 250_000; postingDate = 20705; valueDate = 20705; period = "2026-09"; narration = "load" }),
  #returnCashFromTill({ till = "T01"; amount = 250_000; postingDate = 20705; valueDate = 20705; period = "2026-09"; narration = "return" }),
  #settleTill({ till = "T01"; declared = 299_500; postingDate = 20705; valueDate = 20705; period = "2026-09"; narration = "end of shift" }),
  // ── value dating and the close: value dating, foreign currency and the close ──
  #setFunctionalCurrency({ currency = "EGP" }),
  #setFxPair({ pair = usdPair }),
  #setFxPair({ pair = kwdPair }),
  #setFxRate({ rate = usdRate }),
  #setBackValueWindow({ window }),
  #approveBackValue({ book = "BR01"; valueDate = 20700; reason = "a customer complaint, corrected" }),
  #openDeferralSchedule({ schedule = unearnedSchedule }),
  #openDeferralSchedule({ schedule = prepaidSchedule }),
  #bookFxDeal({
    sell = "EGP"; sellAmount = 48_500_00; sellFrom = #glAccount("1001");
    buy = "USD"; buyAmount = 1_000_00; buyTo = #account(61);
    rateAsOf = 20726; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "buy USD";
  }),
  #bookFxDeal({
    sell = "USD"; sellAmount = 1_000_00; sellFrom = #account(61);
    buy = "EGP"; buyAmount = 48_500_00; buyTo = #glAccount("1001");
    rateAsOf = 20726; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "sell USD";
  }),
  #realiseFxPosition({
    currency = "USD"; closedPosition = 1_000_00; bookedEquivalent = 48_000_00; proceeds = 48_500_00;
    postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "realise";
  }),
  #adjustAccrual({
    product = "SAV"; currency = "EGP"; from = 20697; to = 20726;
    causedBy = 412; postingDate = 20726; period = "2026-09"; narration = "back-value correction";
  }),
  #amortiseDeferral({ schedule = "rent-2026"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "amortise" }),
  #openPeriodEnd({ book = "HQ"; period = "2026-09" }),
  #recordClosingRates({ book = "HQ"; period = "2026-09" }),
  #markAccrualComplete({ book = "HQ"; period = "2026-09" }),
  #revaluePositions({ book = "HQ"; period = "2026-09"; postingDate = 20726; narration = "revaluation" }),
  #amortisePeriodDeferrals({ book = "HQ"; period = "2026-09"; postingDate = 20726; narration = "amortisation" }),
  #reconcilePeriod({ book = "HQ"; period = "2026-09" }),
  #closePeriodEnd({ book = "HQ"; period = "2026-09" }),
  #rollYearEnd({ book = "HQ"; period = "2026-12"; retainedEarnings = "3200"; narration = "close the year" }),
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
  #rejectBulk({ bulk = 601; reason = "cancelled by the payer" }),  // ISO 20022 messaging and FSPIOP interoperability (FSPIOP interoperability)
  #declareRail({ id = "RTGS"; scheme = "EGP-RTGS"; ttlSeconds = 600; hold = { holdAbove = [("EGP", 5_000_000_00)]; blockedBics = ["BKZYEGCX"]; blockedNameFragments = ["SANCTIONED"] }; signatures = #mldsa44 }),
  #registerConnectorKey({ rail = "RTGS"; bic = "CIBEEGCX"; scheme = #mayo2; publicKey = Blob.fromArray([1, 2, 3, 4]) }),
  #releaseHold({ transfer = 700; reason = "reviewed" }),
  #rejectHold({ transfer = 701; reason = "sanctions match" }),
  #declareFspiopParticipant({ rail = "RTGS"; participant = 310; fspId = "dfspa"; endpoints = [("FSPIOP_CALLBACK_URL_TRANSFER_POST", "http://dfspa.local/transfers"), ("FSPIOP_CALLBACK_URL_TRANSFER_ERROR", "http://dfspa.local/transfers/{{transferId}}/error")] }),
  #declareFspiopParticipant({ rail = "RTGS"; participant = 311; fspId = "dfspb"; endpoints = [] }),  #grantDebitAuthority({ rail = "RTGS"; debtor = 311; creditorBic = "CIBEEGCX"; currency = "EGP"; maxAmount = 5_000_00 }),
  #revokeDebitAuthority({ rail = "RTGS"; debtor = 311; creditorBic = "CIBEEGCX"; currency = "EGP" }),
  #decideMandate({ rail = "RTGS"; mandateId = "MNDT-1"; accepted = false; reason = ?"customer declined" }),
  #decideMandate({ rail = "RTGS"; mandateId = "MNDT-2"; accepted = true; reason = null }),
];

// ─── 1. command hash: deterministic, and sensitive to every field ────────────
var hashChecks = 0;
for (c in commands.vals()) {
  let h1 = C.commandHash(c);
  let h2 = C.commandHash(c);
  assert (h1 == h2);
  assert (h1.size() == 32);
  hashChecks += 1;
};
Debug.print("count: command hashes computed twice and equal = " # Nat.toText(hashChecks));
assert (hashChecks == commands.size());

// Distinct commands hash distinctly. The hashes are computed once and compared
// from the array: recomputing inside the O(n^2) loop would be thousands of
// SHA-256 passes for the same claim, which is what made this file too slow to run
// in the interpreter.
let hashes = Array.tabulate<Blob>(commands.size(), func(i) { C.commandHash(commands[i]) });
var pairChecks = 0;
var i = 0;
while (i < commands.size()) {
  var j = i + 1;
  while (j < commands.size()) {
    if (hashes[i] == hashes[j]) {
      Debug.print("hash collision between command " # Nat.toText(i) # " and " # Nat.toText(j));
      assert false;
    };
    pairChecks += 1;
    j += 1;
  };
  i += 1;
};
Debug.print("count: command hash pair comparisons = " # Nat.toText(pairChecks));

// one altered field changes the hash
let base = #postManualEntry(manual);
let mutations : [T.Command] = [
  #postManualEntry({ manual with book = "HQ" }),
  #postManualEntry({ manual with postingDate = 20706 }),
  #postManualEntry({ manual with valueDate = 20705 }),
  #postManualEntry({ manual with period = "2026-10" }),
  #postManualEntry({ manual with narration = manual.narration # " " }),
  #postManualEntry({ manual with correctionOf = null }),
  #postManualEntry({ manual with correctionOf = ?42 }),
  #postManualEntry({ manual with idempotencyKey = Blob.fromArray([1]) }),
  #postManualEntry({ manual with legs = [legs[0], { legs[1] with amount = 1_234_57 }] }),
  #postManualEntry({ manual with legs = [legs[0], { legs[1] with account = "2111" }] }),
  #postManualEntry({ manual with legs = [legs[0], { legs[1] with subledger = null }] }),
  #postManualEntry({ manual with legs = [legs[0], { legs[1] with side = #debit }] }),
  #postManualEntry({ manual with legs = [legs[0], { legs[1] with currency = "USD" }] }),
];
var mutationChecks = 0;
for (m in mutations.vals()) {
  if (C.commandHash(m) == C.commandHash(base)) { Debug.print("mutation did not change the command hash"); assert false };
  mutationChecks += 1;
};
Debug.print("count: single-field mutations that changed the command hash = " # Nat.toText(mutationChecks));
assert (mutationChecks == 13);
assert (commands.size() >= 50);

Debug.print("BANK CANONICAL TEST GREEN");
