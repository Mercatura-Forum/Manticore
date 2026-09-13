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
import P "../src/bank/Permissions";
import Reconstruct "../src/bank/Reconstruct";
import OV "OriginationVectors";
import Text "mo:core/Text";

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

let segHash32 : Blob = "\e3\b0\c4\42\98\fc\1c\14\9a\fb\f4\c8\99\6f\b9\24\27\ae\41\e4\64\9b\93\4c\a4\95\99\1b\78\52\b8\56";
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
    accounts = [{ product = "SAV-01"; currency = "EGP"; termDays = null; allocationOrder = []; activate = true }, { product = "TD-12"; currency = "EGP"; termDays = ?365; allocationOrder = [#interest, #principal]; activate = false }]; application = null }),
  #createCustomer({
    party = { kind = #legal; salt = salt32; identityCommit = commit32(11); dedupCommit = null; attributes = []; book = "HQ"; cddLevel = #simplified; riskRating = #low; pep = false; reviewDue = 21001 };
    documents = []; screening = null; lifecycle = #prospect; extensions = []; accounts = []; application = null }),
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
  #pinArchiveImage({ sha256 = segHash32; bytes = 182; name = "archive-child" }),
  #setArchiveControllers({ controllers = [Principal.fromBlob("\6E\3E\78\13"), Principal.fromBlob("\7A\01")] }),
  #spawnArchive({ purpose = "2026-09 postings" }),
  #abandonArchiveSpawn({ spawn = 41; reason = "the create was rejected" }),
  #attachArchiveChild({ spawn = 42; cid = 1_000_001 : Nat64 }),
  #adoptArchiveChild({ cid = 1_000_007 : Nat64; moduleHash = segHash32; controllers = [Principal.fromBlob("\6E\3E\78\13")]; purpose = "operator-deployed" }),
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
  // origination and underwriting (origination and underwriting)
  #setOriginationPolicy({ rpId = "bank.example"; origin = "https://bank.example"; offerValidityDays = 14; bureaus = [("I-SCORE", #none, ""), ("PQ-BUREAU", #mldsa44, Blob.fromArray([9, 8, 7]))] }),
  #setAffordabilityModel({ id = "retail-v1"; version = 1; rules = [{ id = "dsr-45"; kind = #maxDebtServiceRatioBps(4500); onFail = #fail }, { id = "res"; kind = #minResidualIncome(2_500_00); onFail = #fail }, { id = "term"; kind = #maxTermDays(1826); onFail = #fail }, { id = "amt"; kind = #maxAmount(500_000_00); onFail = #refer }, { id = "inc"; kind = #minIncome(3_000_00); onFail = #refer }] }),
  #setScorecard({ id = "retail-card"; version = 2; attributes = [(#income, [{ lo = 0; hi = ?4_999_99; points = 10 }, { lo = 5_000_00; hi = null; points = 25 }]), (#obligationsRatioBps, [{ lo = 0; hi = ?2000; points = 30 }]), (#bureauScore, [{ lo = 700; hi = null; points = 35 }]), (#bureauFlags, [{ lo = 0; hi = ?0; points = 10 }]), (#termDays, [{ lo = 0; hi = ?365; points = 10 }]), (#amount, [{ lo = 0; hi = null; points = 1 }])]; declineBelow = 50; referBelow = 80 }),
  #registerPasskey({ party = 7; credentialId = OV.CREDENTIAL; publicKeySpki = OV.SPKI }),
  #openApplication({ party = ?7; book = "HQ"; request = { product = "PL-STD"; amount = 120_000_00; currency = "EGP"; termDays = 730; purpose = "car" }; channel = "branch" }),
  #openApplication({ party = null; book = "BR01"; request = { product = "PL-STD"; amount = 30_000_00; currency = "EGP"; termDays = 365; purpose = "" }; channel = "web" }),
  #recordApplicationData({ application = 900; facts = { income = 20_000_00; obligations = 2_000_00; proposedInstalment = 5_000_00; dependants = 2 }; commitments = [("employer", segHash32), ("address", segHash32)] }),
  #assessAffordability({ application = 900 }),
  #requestBureauReport({ application = 900; bureau = "I-SCORE"; consentCommit = segHash32 }),
  #scoreApplication({ application = 900 }),
  #underwrite({ application = 900; decision = #approve({ amount = 100_000_00; termDays = 730; rateBps = 1800; conditions = ["salary-assignment", "insurance"] }); rationale = "" }),
  #underwrite({ application = 901; decision = #decline({ reasons = ["affordability"] }); rationale = "score below the floor" }),
  #underwrite({ application = 902; decision = #refer({ to = "credit-committee" }); rationale = "" }),
  #issueOffer({ application = 900; terms = { amount = 90_000_00; termDays = 730; rateBps = 1800; product = "PL-STD"; currency = "EGP"; conditions = ["salary-assignment", "insurance"] } }),
  #acceptOffer({ application = 900; assertion = { credentialId = OV.CREDENTIAL; authenticatorData = OV.ASSERTIONS[0].2; clientDataJSON = OV.ASSERTIONS[0].3; signature = OV.ASSERTIONS[0].4 } }),
  #declineOffer({ application = 901 }),
  #recordDocument({ application = 900; kind = #facilityAgreement; sha256 = segHash32; signed = null }),
  #recordDocument({ application = 900; kind = #other("payslip"); sha256 = segHash32; signed = ?{ credentialId = OV.CREDENTIAL; authenticatorData = OV.ASSERTIONS[0].2; clientDataJSON = OV.ASSERTIONS[0].3; signature = OV.ASSERTIONS[0].4 } }),
  #recordConditionsMet({ application = 900; conditions = ["insurance"] }),
  #fulfilApplication({ application = 900 }),
  #withdrawApplication({ application = 903; reason = "found another lender" }),
  // corporate lending (corporate lending)
  #openFacility({ party = 7; book = "HQ"; product = "FACL"; kind = #revolving({ commitmentFeeBps = 50; cleanDown = ?{ everyDays = 30; forDays = 5 } }); currency = "EGP"; limit = 1_000_000_00; availabilityFrom = 20726; availabilityTo = 21091; pricing = #floating({ index = "CBE-ON"; spreadBps = 250; resetDays = 30 }); covenants = [{ id = "leverage"; kind = #financialRatio({ name = "net debt / EBITDA"; op = #atMost; thresholdBps = 35_000 }) }, { id = "accounts"; kind = #reporting({ due = 20800 }) }, { id = "npl"; kind = #negativePledge }]; collateral = [3]; reviewEvery = ?365 }),
  #openFacility({ party = 7; book = "HQ"; product = "FACL"; currency = "EGP"; limit = 1_000_000_00; availabilityFrom = 20726; availabilityTo = 21091; covenants = []; collateral = []; reviewEvery = null; kind = #syndicatedAgent({ shares = [{ participant = 8; bps = 2000 }, { participant = 9; bps = 1500 }]; agentFeeBps = 25 }); pricing = #fixed(1100) }),
  #openFacility({ party = 7; book = "HQ"; product = "FACL"; currency = "EGP"; limit = 1_000_000_00; availabilityFrom = 20726; availabilityTo = 21091; covenants = []; collateral = []; reviewEvery = null; kind = #syndicatedParticipant({ agent = "AGENTBANK"; agentScheme = #mldsa44; agentKey = Blob.fromArray([1, 2, 3]); agentAccount = "1998"; ourBps = 2500 }); pricing = #fixed(1000) }),
  #openFacility({ party = 7; book = "HQ"; product = "FACL"; currency = "EGP"; limit = 1_000_000_00; availabilityFrom = 20726; availabilityTo = 21091; covenants = []; collateral = []; reviewEvery = null; kind = #financeLease({ assetAccount = "1500"; residual = 20_000_00 }); pricing = #fixed(800) }),
  #openFacility({ party = 7; book = "HQ"; product = "FACL"; currency = "EGP"; limit = 1_000_000_00; availabilityFrom = 20726; availabilityTo = 21091; covenants = []; collateral = []; reviewEvery = null; kind = #operatingLease({ rentalPerPeriod = 30_000_00; every = #monthly; periods = 12 }); pricing = #fixed(0) }),
  #openFacility({ party = 7; book = "HQ"; product = "FACL"; currency = "EGP"; limit = 1_000_000_00; availabilityFrom = 20726; availabilityTo = 21091; covenants = []; collateral = []; reviewEvery = null; kind = #factoring({ advanceBps = 8000; discountBps = 300; recourse = true; clientAccount = 44 }); pricing = #fixed(0) }),
  #openFacility({ party = 7; book = "HQ"; product = "FACL"; currency = "EGP"; limit = 1_000_000_00; availabilityFrom = 20726; availabilityTo = 21091; covenants = []; collateral = []; reviewEvery = null; kind = #forfaiting({ discountBps = 500; clientAccount = 44 }); pricing = #fixed(0) }),
  #openFacility({ party = 7; book = "HQ"; product = "FACL"; currency = "EGP"; limit = 1_000_000_00; availabilityFrom = 20726; availabilityTo = 21091; covenants = []; collateral = []; reviewEvery = null; kind = #bilateralTerm; pricing = #fixed(1300) }),
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
  // branch and teller (branch and teller)
  #setTellerPolicy({ overShort = "5300"; cashInTransit = "1002"; centralBank = "1010"; draftsPayable = "2300"; clearing = "2310"; staleDays = 180; clearingWindowDays = 3 }),
  #openTellerSession({ till = "T1"; teller = carol; opening = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] } }),
  #closeTellerSession({ till = "T1"; closing = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] } }),
  #resolveTillDifference({ session = 700; note = "counted short"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #cashDeposit({ till = "T1"; account = 44; amount = 2_200_00; tendered = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; change = { notes = [(5_00, 1)]; coins = [] }; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #cashWithdrawal({ till = "T1"; account = 44; amount = 250_00; paid = { notes = [(200_00, 1), (50_00, 1)]; coins = [] }; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #vaultToTill({ till = "T1"; amount = 2_225_00; denominations = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #tillToVault({ till = "T1"; amount = 2_225_00; denominations = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #dispatchCash({ product = "TILL"; fromBook = "BR01"; toBook = "HQ"; currency = "EGP"; amount = 2_225_00; denominations = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; carrier = "ArmourCo"; sealBag = "SB-0001"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #receiveCash({ movement = 701; denominations = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #vaultToCentralBank({ product = "TILL"; book = "HQ"; currency = "EGP"; amount = 2_225_00; denominations = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #centralBankToVault({ product = "TILL"; book = "HQ"; currency = "EGP"; amount = 2_225_00; denominations = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #issueChequebook({ account = 44; from = 1; to = 50 }),
  #stopCheque({ account = 44; serial = 7; reason = "lost" }),
  #presentCheque({ account = 44; serial = 1; amount = 1_500_00; payee = #clearing({ house = "EGCH"; batch = "B-001" }); chequeDate = 20720; imageHash = segHash32; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #presentCheque({ account = 44; serial = 2; amount = 900_00; payee = #inBranch({ till = "T1" }); chequeDate = 20720; imageHash = segHash32; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #clearCheque({ account = 44; serial = 1; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #returnCheque({ account = 44; serial = 2; reason = #insufficientFunds; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #returnCheque({ account = 44; serial = 3; reason = #other("mutilated"); postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #issueDraft({ serial = "D-0001"; payeeCommit = segHash32; amount = 3_000_00; currency = "EGP"; source = #account(44); postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #issueDraft({ serial = "D-0002"; payeeCommit = segHash32; amount = 1_250_00; currency = "EGP"; source = #till("T1"); postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #payDraft({ serial = "D-0001"; to = #till("T1"); postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  #cancelDraft({ serial = "D-0002"; refundTo = 44; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s36" }),
  // trade finance (trade finance)
  #setTradePolicy({ bic = "THEBEGCX"; contingentLcs = "9101"; contingentGuarantees = "9102"; contingentCollections = "9103"; contingentContra = "9199"; marginDeposits = "2320"; unearnedCommission = "2330"; commissionIncome = "4310"; acceptancesPayable = "2340"; customersLiabilityAcceptances = "1310"; billsNegotiated = "1320"; billsDiscounted = "1330"; unearnedDiscount = "2350"; discountIncome = "4320"; billsRediscounted = "2360"; billLosses = "5310"; nostro = "1005"; claimProduct = "CLAIM"; examinationDays = 5 }),
  #issueLetterOfCredit({ lc = { role = #issuing; applicant = #party({ party = 7; account = 44 }); beneficiary = #external({ name = "NORDIC TEXTILES AB"; bic = "NDEASESS"; account = "SE4550000000058398257466" }); counterpartyBank = "NDEASESS"; terms = { documents = [{ kind = #invoice; copies = 3; checks = ["INV-AMOUNT", "INV-GOODS"] }, { kind = #transport; copies = 1; checks = ["TRANS-ONBOARD", "TRANS-PORTS"] }]; latestShipment = ?20800; presentationDays = 21; partialShipments = false; transhipment = true; incoterm = ?"CIF"; availableBy = #sight; portOfLoading = "ALEXANDRIA"; portOfDischarge = "ROTTERDAM"; goods = "COTTON YARN 20 TONNES" }; tolerance = ?500; marginBps = 2_000; facility = null; commissionBps = 150; reference = "LC-2026-0001" }; amount = 100_000_00; currency = "EGP"; expiry = 20900; placeOfExpiry = "CAIRO"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #adviseLetterOfCredit({ message = "{1:F01NDEASESSXXXX0000000000}{2:I700THEBEGCXXXXXN}{4:\n:27:1/1\n:40A:IRREVOCABLE\n:20:NDEA-77\n:31C:260901\n:40E:UCP LATEST VERSION\n:31D:261130STOCKHOLM\n:50:NORDIC TEXTILES AB\n:59:/44\nCUSTOMER 7\n:32B:EGP250000,00\n:41A:THEBEGCX\nBY PAYMENT\n:43P:NOT ALLOWED\n:43T:ALLOWED\n:44E:ALEXANDRIA\n:44F:GOTHENBURG\n:44C:261101\n:45A:COTTON YARN\n:46A:+SIGNED COMMERCIAL INVOICE IN 3 ORIGINALS\n+FULL SET CLEAN ON BOARD TRANSPORT DOCUMENT IN 1 ORIGINAL\n:48:21/DAYS FROM SHIPMENT DATE\n:49:CONFIRM\n-}"; beneficiary = 7; beneficiaryAccount = 44; confirm = true; checklist = [(#invoice, ["INV-AMOUNT"]), (#transport, ["TRANS-ONBOARD"])]; commissionBps = 100; facility = null; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #amendLetterOfCredit({ instrument = 900; amendment = { amount = ?120_000_00; expiry = ?20950; latestShipment = null; other = ""; consents = [#beneficiary, #applicant] }; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #presentDocuments({ instrument = 900; documents = [{ kind = #invoice; hash = segHash32 }, { kind = #transport; hash = segHash32 }]; amount = 60_000_00; shipmentDate = ?20790; presentedOn = 20800 }),
  #examinePresentation({ instrument = 900; claim = 1; checks = [{ document = #invoice; check = "INV-AMOUNT"; passed = true; finding = "" }, { document = #invoice; check = "INV-GOODS"; passed = false; finding = "goods description differs from the credit" }, { document = #transport; check = "TRANS-ONBOARD"; passed = true; finding = "" }, { document = #transport; check = "TRANS-PORTS"; passed = true; finding = "" }]; decision = #refuse({ discrepancies = ["INV-GOODS"]; disposal = #heldPendingWaiver }) }),
  #waiveDiscrepancies({ instrument = 900; claim = 1; applicantConsentHash = segHash32 }),
  #honourPresentation({ instrument = 900; claim = 1; honour = #sight; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #settleAcceptance({ instrument = 900; claim = 2; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #closeLetterOfCredit({ instrument = 900; reason = "fully utilised"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #issueGuarantee({ guarantee = { kind = #demandGuarantee; rules = #URDG758; principal = 7; principalAccount = 44; beneficiary = #external({ name = "PORT AUTHORITY"; bic = "CIBEEGCX"; account = "" }); counterpartyBank = ""; wording = segHash32; statementRequired = true; reductions = [(20850, 60_000_00)]; marginBps = 1_000; facility = null; commissionBps = 100; reference = "GT-2026-0001" }; amount = 80_000_00; currency = "EGP"; expiry = 20900; wordingText = "WE HEREBY UNDERTAKE TO PAY"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #amendGuarantee({ instrument = 901; amendment = { amount = null; expiry = ?20960; latestShipment = null; other = "EXTENDED"; consents = [#beneficiary] }; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #recordDemand({ instrument = 901; demand = { kind = #other("demand"); hash = segHash32 }; amount = 30_000_00; supportingStatement = true; presentedOn = 20810 }),
  #examineDemand({ instrument = 901; claim = 1; checklist = ["DEMAND-SIGNED", "DEMAND-STATEMENT"]; checks = [{ document = #other("demand"); check = "DEMAND-SIGNED"; passed = true; finding = "" }, { document = #other("demand"); check = "DEMAND-STATEMENT"; passed = true; finding = "" }]; decision = #complying }),
  #payDemand({ instrument = 901; claim = 1; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #reduceGuarantee({ instrument = 901; to = 50_000_00; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #releaseGuarantee({ instrument = 901; reason = "original returned by the beneficiary"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #registerCollection({ collection = { role = #collecting; terms = #DA({ tenorDays = 60 }); drawer = #external({ name = "SHANGHAI MACHINES"; bic = "BKCHCNBJ"; account = "" }); drawee = #party({ party = 7; account = 44 }); counterpartyBank = "BKCHCNBJ"; documents = [{ kind = #invoice; hash = segHash32 }, { kind = #transport; hash = segHash32 }]; instructions = "DELIVER DOCUMENTS AGAINST ACCEPTANCE"; commissionBps = 25; reference = "COL-2026-0001" }; amount = 40_000_00; currency = "EGP"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #presentCollection({ instrument = 902; presentedOn = 20805 }),
  #acceptCollection({ instrument = 902 }),
  #payCollection({ instrument = 902; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #protestCollection({ instrument = 902; reason = "non-acceptance" }),
  #returnCollection({ instrument = 902; reason = "drawee refused the documents"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #discountBill({ bill = { customer = 7; customerAccount = 44; acceptor = #external({ name = "SHANGHAI MACHINES"; bic = "BKCHCNBJ"; account = "" }); source = ?{ instrument = 900; claim = 1 }; discountBps = 800; recourse = true; reference = "BILL-2026-0001" }; face = 40_000_00; currency = "EGP"; maturity = 20865; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #rediscountBill({ instrument = 903; to = "CENTRAL BANK OF EGYPT"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #settleBill({ instrument = 903; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #dishonourBill({ instrument = 903; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s37" }),
  #recordTradeMessage({ instrument = 900; kind = #mt(707); direction = #outgoing; hash = segHash32 }),
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

// ─── the encoding freeze: golden vectors per reconstructible family ─────────────────────────────
// Once a pack has dropped a proposal's body, the command comes back only while the encoding of its family
// is byte-identical to what it was at proposal time. The first command of each reconstructible family in
// the list above is hashed under encoding version 1 and version 2 and compared with the hex recorded here
// on 2026-09-13 (the origination, facility, teller and trade families added the same day); a drift in any family's bytes fails this test — the change must be a new version with a
// new encoder, the old one kept. (`golden.py` below the test is the generator: `GOLDEN_PRINT = true`.)
func hex(b : Blob) : Text {
  let digits = "0123456789abcdef";
  var out = "";
  for (x in b.vals()) { let n = Nat8.toNat(x); out #= Text.fromChar(Text.toArray(digits)[n / 16]) # Text.fromChar(Text.toArray(digits)[n % 16]) };
  out
};
let GOLDEN_PRINT = false;
let golden : [(Text, Text, Text)] = [
  ("openBook", "a7203909a19209d57fb1179a8556e3374bd540213e4df2f7b8f5c85105779f00", "95d49526fbd1c8c37c7aa63e66e1eae4bf533795e871d69a50520ad8d4ca62a1"),
  ("closeBook", "6661f47455b71ca3ea6b213966e8345ca6fb91dad9e4d18a6c299c8a59cbb272", "392c346e4e6fab4cb81895a747b2aaaff97f142e7e4967c108a11e2c43cf1a34"),
  ("defineRole", "fee7c398a9c59cac7dc2336d6461aff0f0b1d3d9bdd84c36aeb7ba420329c84b", "edbeca1e04ec480c0d2de93f967ad55c34883673ff8cb52bf26229f94ee15835"),
  ("grantRole", "e47f91c06794dbe411b2da0e6ff2acb0af34666fe51f5a580119f41763f55426", "b39922f7e1cad1a81b597c4de7a7f0d92508276bfd3a040af8912e7905df6f74"),
  ("revokeRole", "5527addaabd7054526d76022f3f8e8eba80e473af4fde8e8e00cbb5b73085014", "cab0972e79f403fdee4e7a0a93c69ef7821582f6e3bc0337b0e96146d3ad338c"),
  ("setDualPolicy", "97ad214a54ef2187be67c2f11475535ab58fedee0bf94e183b07380956df6364", "7d8209af6a16531efd562b1b4bd36be678ccdf06df05abbacb5d56f3dc5fb1c1"),
  ("clearDualPolicy", "3001948a541ef6b140796bbcc0e75ac103502c4b8ae5dc40ef8838675cf4d4b0", "3f241008d1cf1fb4cc77a66b9c9ea28b0b674c687bb6320a75f89756446fccb4"),
  ("transferBankAdmin", "dd8ac9a795db0aaacf0efedf9c0a6ef918d24e4a0c81f076fb354b3671e15bf9", "147eed2d7562f7746c7fa31f119fb38271c0dbbee8dff950f3d70a2b1448c2c4"),
  ("setFeatureActivation", "c0756c1ffba7ad7f23b237b80a63b199489ea6d7007ed9af35690e72016eab01", "fb8ee0ddeb01da9fe9b8a62bcbc10f9d8e5dc50b415eb111b3ae0fb4d2f028df"),
  ("createParty", "038cad0fb0ddd0f837ee284a6c4342dd493006644dd1e9dd91126373cd67af26", "ad9c9c9d446310a13217c35310ecea6daca2c213efd5f2077dcf823a79f1b24d"),
  ("amendParty", "24b5d0345bddd14003b6d415aeaca388114985da5ee2adb7c2b574fabd4a615b", "5499bd3387b374353b26ccdb89ca759844a9f8a1cfa13f24a55eb1d8b0a1e5f2"),
  ("setPartyLifecycle", "780fe48da9824156c737c29db45151a27f2619edef34dfa57e2c01c819aa4c87", "c936ff075e81671ff230c08dd718dcf1a43cbfe25e44f9d48c92662a5a23ff73"),
  ("setPartyCdd", "988d3cb72a3f08efc89205d69cb4b9ba6e7abae72cd545cb251c2b90f9b2dff4", "22abd2bcae4a71f32a13984d64d32a4814902d95efde5cdfcb5c10e475aa35d0"),
  ("addPartyDocument", "db9eb1341c3152302ed2cabe0bde1d4e3399f05ca9c6ca36a0c40b826197345f", "f6227607423bc8060711a3b26c650e90cf815b362cccc89f3ba7ae6acd068572"),
  ("addPartyRelationship", "e2d3ad5288d265b1788413160c501706db6189a30988f45075c2921ad93879c3", "ebaf0c468ad7315fe12316118c58fbd4f63c3863b223b23801398a7422922e3c"),
  ("setPartyExtension", "ad63c6759ba6c6e286e17a4a8c03d0966b75889f62f27815121f5d6dcf0582f9", "a70d3c120e7640903486d0269c678ca9d57492233909be591ef4e6aa9a40e848"),
  ("commitScreeningList", "0eb51a40066ddc105203881f397fccd055b4cb575256b8556a6c0b5173dd8dd0", "ea59ef24e9e975d3607061ec6ebb29b8899860be28555f4759e537ee698f52e5"),
  ("recordScreeningDecision", "6a71072f35a08ea6495722e142a68bed74ab183980ed4d8e5c19c5e1af93f3c3", "f65738a5244e8a546093ae22406d4374503ed92f92bf40348a12113f3f6c8b3c"),
  ("registerSchema", "9236f0aaab95d72990ddb612f38d74dfff076efa71b5ad98538fc55ac3c907cb", "c0705a3c77492de056e2a6d289f6584a47aae080b6fec6bc9169505a71cb3845"),
  ("registerCollateral", "2b261713262057dd112de57935f959e7e72cfc17f59670a4a545cb5e5dbe9053", "bad288549d90b775da7a7cad8a2a90cd95ea0f346f5ee2dbe5e19ed387695fd1"),
  ("revalueCollateral", "020af9b4396ffed2b04bcb1c2b2b4504a207f629efd851542ce3e6cfd2a9689f", "e107f3629b7ebc451cd6beaae5fd782aabf6a7953ce6df1af77e3444efcd194e"),
  ("allocateCollateral", "f9e5629c49089246fcd7d7ee7c6723bf40da9dc452fa0d0d307d4ac2a3ce8e00", "ed0f6f5dfbc6d000a5fba676adb3ea587e530d89fb4035007bc679693056aab4"),
  ("releaseCollateral", "4501e9343f9c247925f128d7073f7dc8b873c35fc46c6c3ce632e3242301ec45", "a9fc4a2a83c24e40ab241d53da60da73ee2873e226432181341149d13acfbbf3"),
  ("addStaff", "8724694411d39551c1a474235accb09b2bf48dfcc0091458881878bf47ea3d28", "aaeaf37957fcb4d45205316beaebe5144a892117a609efe7d867a058e9280bb4"),
  ("removeStaff", "8597353faf8d2514e165221e02a0aaf84706906caeb3d5f54b43312dc52efc9a", "c362ce1177dcc7c9280e127d1e7cfc54181981da91f79a38ee8ea72ee3cc7809"),
  ("setAccountFormat", "2875ec6aa94c1e89ab95abfea6a6e3864732663776969799e1f3b896a720fa7f", "44b64be66efdf64d488b87dcf32c6cd9cde16a274e8011d90ff1d6896e9a4927"),
  ("setReviewGrace", "a29f16e6478fa09b797996dc16a8951d47d197a8e85ecaafacaf5a34ea4495b2", "9994b373d13e1c07a8d2099ceba743aab47223ee580352978430532bbd20f680"),
  ("registerProduct", "a0528113753afe63b1f2bf093490b3d2f45e28bb485dc4d83b7fbc64fe5dc558", "b9ce5026680ef8c2786f9fab82d10aea93f596505badac701d8f40c852d801ca"),
  ("amendProduct", "4547ccb53fa55c60c68c8df34f074b1daccc3d0ebf4da06c5b341f3810b64696", "cd1a915d6956f804368d3fc50bfcf641de7309c081c764b4d742edc5ad21d7a9"),
  ("closeProductToNewAccounts", "e1279d342b5d290e6d63456bc09ea910b8ba2feeea9179af87ae5a1d6c4d522a", "a1ea207edd2914c8cd08a933d2a1c71141acf62e24675b1dcd222c2ff80963e2"),
  ("openAccount", "1e197ca273813b62e7e32e10a61699df6f06483baeebf26094dec53d447b4bbe", "c15145a698ab030e39569cb384d9d31d3eca969554c2b28af7cc559f9f347876"),
  ("setAccountStatus", "5a90c9370ed0a322db1de5c035855f5ee414e5cdc8758167e3e8f385fdb3ce54", "53bd5ba0ace509392ed188a0d9ec67f5b8927bf835ff03d6b09b5abe8a51b21a"),
  ("migrateAccount", "f2c7d8cb19ce50832863137ee8a0c8c50b48bc670b654a2edd22c7b093a22e37", "69054684afb694cbb45830c7a830fbd9843ba4b1b9876799a43ec23f846f9a88"),
  ("openTill", "548a8d1cbdac46b960851f12efdf218e9fa38f4a58527403c2ce4e0737e7b08c", "e9896bb907a7b2b16b93a945853b3ca4c8085dc1a3905be40e47bc5f45f54d17"),
  ("createCustomer", "be7bdba924af2d0d7cad930fa350a61e6e94665d5a67c7340dfdeceac8f091fc", "2598e939f8e91518e8c5c85d8edb73d641ba15c17f6b10baabbb8ceca535df21"),
  ("setOriginationPolicy", "80aa8c6431c03d9624c49464ecf2999df0607fbb0b03edd606ff1798281945fe", "62fefefd76eea84087071df914b894336b1d430a0b7a9c7b4cfc913672b4127b"),
  ("setAffordabilityModel", "a26d28d79298096cea3838fedae0bee35862271550aba4c2984b68f255d64406", "bef62871c0fe46cf54345e79469355e632a04e43e039f2b865835241aa6a2059"),
  ("setScorecard", "3471eb0b251af7d0bb11b5621afbb532668f2876d1ce4997bbe06adec319429c", "e1333dbda8df7d71a581d020579e4927eeb67e7aed7879995ad969bc9e1f4d03"),
  ("registerPasskey", "c064a78eda4db9ab710a2d236ae39c360ca96522b23a08390cc8e3b54161118f", "0cc4a577fd6cb5934d1e24121cb56411c2919165f4a15b3bc6583e42bbed8849"),
  ("openApplication", "5ffed3439ecc89af098b6283d68807e117c5cb54af0ce73e93e9376c272a0a61", "f835ee0f227d6b708a7bcaa859e7c8b7ef254e2838eb84df611215b3a6be4595"),
  ("recordApplicationData", "3cb9d53d3f411e0400daad99fee6437185eac42b86f8754ff96fa34d9959e656", "af267124868f223ad5de1456122d151cc8fc1c507b8941e4986cbf9ceec66f76"),
  ("assessAffordability", "6b1f033af7d6edd3e24760a1f3cee8e2d941c2e166961635251b5d5044d43723", "ba091006225236f9682944149922d3b3e1d548280549d006536d05b628090d8b"),
  ("requestBureauReport", "e39d11f23f06017c124186b20ff33cd1961d63c2652e31a82ac6801fcf355dc5", "0b7be6eec763e9c646dcb88c0c86e0192114aaf78048cbd5dc917739f53bb891"),
  ("scoreApplication", "ac4d854be10ba399b9fe9823e21438388ea284a902f587fd337921eba0ba3a6c", "b7d6cebddfbcd00747558567ce17c7b7c156c676681f51749b5e058844f8f3fb"),
  ("underwrite", "64c6d2bc01cde4ab658a04222dc6e67ac2361b50d126430573d4e036e815f39d", "343e9960e0c74fe90fe6bca643f1bfccfd1f0ccf8d4d05abcd388a11f1eece12"),
  ("issueOffer", "7482d09fe2e295e8653d5f6649303ad17b3718085a1f0537c4bedfdcbeb2bc20", "47ec324f98e7a3187048053f79d7bd1418341cc890c264a8e2277cfbcf156dd6"),
  ("declineOffer", "20b534e6181a9fc3f3b16d507c8886ed0a82a2e4177bc84802b8c1fc98034187", "269de81902f252d988372efab8923a1423d2bf3323f12f36cc80ab5664bc2f4a"),
  ("recordDocument", "b5194d1082c38fb6328d15f7cca9f2764d69b6559853ee3330e2b93dc887dfa1", "88bee7a16d51ba9e415299060794daa713116dfdd964bbcd5e1b2cbb10eb30e3"),
  ("recordConditionsMet", "15e88c88052edfcbf6a39afad1bb3e8c048862726a1e61264442a0f8fc7dacf3", "a8f3ad82e0fb65d1841092397764c308808d8b9413180e7e599a5a4701d17795"),
  ("fulfilApplication", "1c5fc41aa147d5d4bb713c6cd62f541635868d81eece4a2606579814e30aa0bc", "de7c60bdc65c70631589febd8c5ce6c0b0f861863be657f875a72d2303f72ff3"),
  ("withdrawApplication", "64b1e008e72c060d5a8f6ea20cc1412a55b109d34237c1652670e84fad6fb8ed", "1de82a9bf9980e87bb13acdd758e1ffdfdff10aca94d60c61540041455251887"),
  ("openFacility", "434149a65dfa5cd440bf374960a932287bce2b440649138b175b3915148a32f7", "8dd6ba055bff744a01ac6dec63ef7b4dc23de923c9cec1f3bf5eda8fbdc0bf32"),
  ("transferParticipation", "255d4b8bc1042da51afcd822be932d239cf644772b3c4a5e06e25f3d826a3da2", "f53ba287bf39c815c96352809a00e173ba906fc3139f95dd494070da9571acea"),
  ("recordCovenantTest", "17d451c8f455921244a4b9d3beb05c01e040a366e44be63b1f7c3d843339f532", "a83c7f3feb576083985e5fd4b7ed174e643a53140d69bcefee905eaae1d7f582"),
  ("blockDrawdowns", "6611425d444c6bf2796be0b5328b98cbb591727b5f38ca9e4dfebdeb478ef7b5", "078ef77d49672222590e1d32437500fc69f37247e28e0c93380da5df06dd748b"),
  ("unblockDrawdowns", "194fe17b834afb2991a6a84cf7694ffec052e67b6a2742766a4a641fb8f73808", "efab863514c6d50c2a87e9f8d9b009134a638678929ea437fab89a1479468fd9"),
  ("recordFacilityReview", "66d0f3c544f055ba5c4d6297a564efb3bb5a59be9d197a4ca78bf8ed90a18cba", "20d3c47d9961a5afc8e9588584cbebf28a273bc362e4384de479a4c804828418"),
  ("recordRateFixing", "a90b21d72e38ac14b8853fc104307cee76087e94def2905a92e05396f574fb17", "ed757e4b8b04a254027b6486b553e21379a5cfaed4f38e5b70b9f7ae04a777d5"),
  ("closeFacility", "04644fdf81035192244ed76f3bc2ae4802afe1be0f983ea450072133cbbb715a", "e98d73e8a6b5c04b4f9e5c15801a5340581de47ad0fe0cd914ded063d1a92f1a"),
  ("setTellerPolicy", "8bc05d4317158352f4c0e8a666d09e9cd31ed9ac341e6a78ca924b5a78901d30", "8758ddff632ed1782336eda561300560ac0158b3605ca260151547d3575063ff"),
  ("openTellerSession", "755cbb3dc1cb303afc4d5ed30d1f9aaf83d23a6f3b55619742c9b9daf5533f8a", "7ab26bafc271ad8afbbed31359b7968647fe154ad39f54a4739ca6cb642c30d8"),
  ("closeTellerSession", "e25eb207c706813ca46380d50c0b86cb37c833c5831f9fd9a24b282f8210ee76", "4f133efa283e8a3c25abff5fe74dccd5ab34ed0c2392bde14ba31673d25c5743"),
  ("issueChequebook", "e0fd858b31026af5576158c7abf0de648fd1c1f723514073b7ad8a419d9b63e0", "642a2c1637270f7f49da23950d0691882f30d69336c3d9148cf08df4b7db0c87"),
  ("stopCheque", "dc737a2c61f6f69a667ba2e6e704e4300f337477be7051f791bb5a778930cfc2", "6cde2154b624063f9372e14440c37e1be7bca5ef632b0c1a4856c488f5a430dc"),
  ("setTradePolicy", "9ee4ca9a9eaffd3071aa5fa338ae9489d5624d7e87fff4adc9ef002dd6ce7d14", "faa38de17c31b657b6523047b84ee9ba90216f6ba7a37ababe73fdc7118724ec"),
  ("presentDocuments", "1da04817ac55ca0a6e0c463758388e757cdb1e30b808a4fe3731bcd4f3b88c8c", "92c325f503253c0950b1e05c544d7245022b21876ff46e5be3e232059d0c97b4"),
  ("examinePresentation", "740be3fedc034b0386b48cdf67115a422ffaaed01b43a0eba2af1562b4ba657e", "66ceab88d00f8e28f51d4efd9cd525cf40fc3569d27a1c833d33d07c86d99f4d"),
  ("waiveDiscrepancies", "4689f3f0ec25f4a2d3ff39259c1355d4ad8415182a87becfa44d19f8c6a7c12e", "ca70d448ea7768d2fa2846f2ec7601b8bdcb0722b9eb82112244d6f063491fb0"),
  ("recordDemand", "25666786dd1bd83fcbd066539591992898545367c5d9abdfa6b541e3c3bbc9a3", "321d3e651668cc278e4878bf88348822d6f8f81eb7c11f6224dace459f4a419b"),
  ("presentCollection", "7e4f6b6d7d71ace7fba6e469c256b5ac2012ba93f57cc216ab3a286f634cf5e5", "b4c544286bf42fde2115e0bf3b284fb08c6f62ca5781a6ace5dc5488dd13956b"),
  ("acceptCollection", "40a6131efe35b5b6a73dfa28a8040fe5a5e1d9097399a59d0a36087aeadc445e", "13f543f756727256d561ff9b20b9329d8b18797f47c365d57e29c90e5b2bd824"),
  ("protestCollection", "b4a1108e723fce4c7234595da8f419c9fdb42f73d4bb3d9e50ed2c0a04df535b", "e9912515ef288eae443854ff0f6ba2f22bed9d35726a9727ee6c81ed2c155671"),
  ("recordTradeMessage", "8cdd9bfe344a0530b69249d7fdd3272d325e390856f69479f85583cea6e4414a", "2c45470fd959e5c9f40782cba1cc9ad3059bd2293a90cc3dc8456b8004ac2a15"),
];
var goldenChecked = 0;
for (family in Reconstruct.families().vals()) {
  let ?c = Array.find<T.Command>(commands, func(x) { Text.equal(P.commandName(x), family) }) else { Debug.print("no fixture command for family " # family); assert false; loop {} };
  let ?h1 = C.commandHashAt(1, c) else { Debug.print("version 1 cannot encode " # family); assert false; loop {} };
  let ?h2 = C.commandHashAt(2, c) else { Debug.print("version 2 cannot encode " # family); assert false; loop {} };
  if (GOLDEN_PRINT) { Debug.print("  (\"" # family # "\", \"" # hex(h1) # "\", \"" # hex(h2) # "\"),") }
  else {
    let ?(_, g1, g2) = Array.find<(Text, Text, Text)>(golden, func((f, _, _)) { Text.equal(f, family) }) else { Debug.print("no golden vector for family " # family); assert false; loop {} };
    if (not Text.equal(hex(h1), g1)) { Debug.print("ENCODING DRIFT: version-1 bytes of " # family # " changed: the change must be a new encoder version"); assert false };
    if (not Text.equal(hex(h2), g2)) { Debug.print("ENCODING DRIFT: version-2 bytes of " # family # " changed: the change must be a new encoder version"); assert false };
    goldenChecked += 1;
  };
};
// version 1 and version 2 differ exactly where the freeze says — createCustomer's bytes, and nowhere else;
// the hashes differ everywhere because the domain carries the version
var sameAcrossVersions = 0;
for (c in commands.vals()) {
  switch (C.commandBytesAt(1, c), C.commandBytesAt(2, c), C.commandHashAt(1, c), C.commandHashAt(2, c)) {
    case (?a, ?b, ?ha, ?hb) {
      assert (ha != hb);
      switch (c) { case (#createCustomer(_)) assert (a != b); case (_) { assert (a == b); sameAcrossVersions += 1 } };
    };
    case (_, _, _, _) { Debug.print("a command the current encodings cannot represent"); assert false };
  };
};
// a command version 1 cannot carry: createCustomer with an application
let ?customerFixture = Array.find<T.Command>(commands, func(x) { Text.equal(P.commandName(x), "createCustomer") }) else { assert false; loop {} };
let withApplication : T.Command = switch (customerFixture) { case (#createCustomer(cc)) #createCustomer({ cc with application = ?7 }); case (_) { assert false; loop {} } };
assert (C.commandHashAt(1, withApplication) == null and C.commandHashAt(2, withApplication) != null);
assert (C.commandHashAt(3, withApplication) == null and not C.supportsCommandEncoding(0) and not C.supportsCommandEncoding(3));
if (not GOLDEN_PRINT) {
  Debug.print("count: golden command-hash vectors checked under two encodings = " # Nat.toText(goldenChecked));
  assert (goldenChecked == Reconstruct.families().size());
};
Debug.print("count: commands whose bytes are identical under encodings 1 and 2 = " # Nat.toText(sameAcrossVersions));

Debug.print("BANK CANONICAL TEST GREEN");
