// BankTamper.test.mo; the bank log's block encoding, and tamper detection.
//
// Every `Event` variant round-trips byte-for-byte, including a proposal carrying
// every `Command` variant; a single flipped byte anywhere in a block is detected
// and never served; every unsupported version byte and every truncated or
// over-long buffer is refused.
//
// engine: wasi-only; the sweep flips every byte of every block of a hundred-odd
// events, which is over sixteen thousand decode-and-hash attempts. Under `moc -r`
// it does not finish in a useful time (killed after twelve minutes with its output
// frozen), the same reason the journal's own core battery is exempted. Its proof is
// the WASI run alone, and that is said here, in the component record and in the
// release note.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Principal "mo:core/Principal";
import Nat64 "mo:core/Nat64";

import T "../src/bank/BankTypes";
import MT "../src/bank/MonitoringTypes";
import SeT "../src/bank/SettlementTypes";
import OV "OriginationVectors";
import ProdT "../src/bank/ProductTypes";
import CT "../src/bank/CloseTypes";
import RepT "../src/bank/ReportTypes";
import C "../src/bank/BankCanonical";
import P "../src/bank/Permissions";

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

let instalments : [ProdT.Instalment] = [
  { number = 1; dueDate = 20730; openingPrincipal = 600_000; principal = 95_000; interest = 6_000; fees = 500; closingPrincipal = 505_000 },
  { number = 2; dueDate = 20760; openingPrincipal = 505_000; principal = 100_000; interest = 5_050; fees = 0; closingPrincipal = 405_000 },
];

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
  #journalSetCalendarAuthority({ authority = #businessDate; maxRollDays = 31; businessDate = ?20705 }),
  #journalSetCalendarAuthority({ authority = #substrateClock; maxRollDays = 0; businessDate = null }),
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
  #recordFeedDeadLetter({ letter = { cursor = 417; endpoint = "https://feed.example.test/thebes"; attempts = 4; reason = "504 from the consumer" } }),  // ISO 20022 messaging and FSPIOP interoperability (FSPIOP interoperability)
  #declareRail({ id = "RTGS"; scheme = "EGP-RTGS"; ttlSeconds = 600; hold = { holdAbove = [("EGP", 5_000_000_00)]; blockedBics = ["BKZYEGCX"]; blockedNameFragments = ["SANCTIONED"] }; signatures = #mldsa44 }),
  #registerConnectorKey({ rail = "RTGS"; bic = "CIBEEGCX"; scheme = #mayo2; publicKey = Blob.fromArray([1, 2, 3, 4]) }),
  #releaseHold({ transfer = 700; reason = "reviewed" }),
  #rejectHold({ transfer = 701; reason = "sanctions match" }),
  #declareFspiopParticipant({ rail = "RTGS"; participant = 310; fspId = "dfspa"; endpoints = [("FSPIOP_CALLBACK_URL_TRANSFER_POST", "http://dfspa.local/transfers"), ("FSPIOP_CALLBACK_URL_TRANSFER_ERROR", "http://dfspa.local/transfers/{{transferId}}/error")] }),
  #declareFspiopParticipant({ rail = "RTGS"; participant = 311; fspId = "dfspb"; endpoints = [] }),  #grantDebitAuthority({ rail = "RTGS"; debtor = 311; creditorBic = "CIBEEGCX"; currency = "EGP"; maxAmount = 5_000_00 }),
  #revokeDebitAuthority({ rail = "RTGS"; debtor = 311; creditorBic = "CIBEEGCX"; currency = "EGP" }),
  #decideMandate({ rail = "RTGS"; mandateId = "MNDT-1"; accepted = false; reason = ?"customer declined" }),
  #decideMandate({ rail = "RTGS"; mandateId = "MNDT-2"; accepted = true; reason = null }),
  // collections and recovery (collections and recovery)
  #setCollectionsPolicy({ delinquentDpd = 31; defaultDpd = 90; suspendInterestFrom = #default_; recogniseModificationLoss = true }),
  #setCollectionsPolicy({ delinquentDpd = 16; defaultDpd = 60; suspendInterestFrom = #delinquent; recogniseModificationLoss = false }),
  #markUnlikelyToPay({ account = 89; reason = "insolvency petition filed" }),
  #recordCollectionAction({ account = 89; action = #call; outcome = "no answer"; next = ?20730 }),
  #recordCollectionAction({ account = 89; action = #other("sms"); outcome = "delivered"; next = null }),
  #recordPromiseToPay({ account = 89; amount = 1_500_00; by = 20740 }),
  #assignCollector({ account = 89; staff = carol }),
  #closeRecovery({ account = 89 }),
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
  // Islamic banking (Islamic banking)
  #setIslamicPolicy({ murabahaInventory = "1500"; murabahaReceivable = "1510"; deferredProfit = "1515"; murabahaIncome = "4500"; securityDeposits = "2500"; ijarahAssets = "1520"; accumulatedDepreciation = "1525"; depreciationExpense = "5500"; rentalReceivable = "1530"; ijarahIncome = "4510"; musharakahInvestment = "1540"; musharakahIncome = "4520"; mudarabahInvestment = "1550"; mudarabahIncome = "4530"; investmentLosses = "5510"; salamReceivable = "1560"; salamInventory = "1565"; salamIncome = "4540"; istisnaWip = "1570"; istisnaReceivable = "1575"; istisnaRevenue = "4550"; istisnaCosts = "5520"; iahEquity = "2600"; profitEqualisationReserve = "2610"; investmentRiskReserve = "2620"; profitPayableToHolders = "2630"; mudaribShareIncome = "4560"; profitAttributableToHolders = "5530"; charityPayable = "2700"; nostro = "1005"; perCeilingBps = 1_000; irrCeilingBps = 1_000 }),
  #approveShariaProduct({ product = "ISAV"; approval = { ref = "SSB-2026-07"; sha256 = segHash32 } }),
  #flagShariaBook({ book = "BR01"; sharia = true }),
  #openShariaContract({ kind = #murabaha({ customer = 7; account = 44; asset = "10 TONNES OF STEEL COILS"; supplier = #external({ name = "Ezz Steel"; reference = "PO-77" }); costPrice = 100_000_00; markup = 12_000_00; instalments = 12; every = #monthly; method = #proportionate; promise = #binding; securityDeposit = 5_000_00; latePaymentCharityBps = 500; reference = "MUR-2026-0001" }); currency = "EGP"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #openShariaContract({ kind = #ijarah({ lessee = 7; account = 44; asset = "CNC MACHINE"; cost = 240_000_00; usefulLifeMonths = 60; residual = 24_000_00; rental = 5_000_00; every = #monthly; periods = 48; transfer = ?#sale({ price = 24_000_00 }); reference = "IJA-2026-0001" }); currency = "EGP"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #openShariaContract({ kind = #musharakah({ partners = [{ party = 7; account = 44; capital = 300_000_00; profitBps = 6_000 }]; bankCapital = 200_000_00; bankProfitBps = 4_000; diminishing = ?{ units = 20; unitPrice = 10_000_00; every = #quarterly; rentalBps = 800 }; reference = "MUS-2026-0001" }); currency = "EGP"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #openShariaContract({ kind = #mudarabah({ mudarib = 7; account = 44; capital = 150_000_00; bankProfitBps = 7_000; term = 365; reference = "MUD-2026-0001" }); currency = "EGP"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #openShariaContract({ kind = #salam({ seller = 7; account = 44; commodity = "WHEAT"; quantity = 500; unit = "TONNE"; delivery = 20900; priceAdvanced = 90_000_00; reference = "SAL-2026-0001" }); currency = "EGP"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #openShariaContract({ kind = #istisna({ customer = 7; account = 44; specification = segHash32; price = 500_000_00; estimatedCost = 400_000_00; milestones = [(20800, 3_000), (20860, 7_000), (20920, 10_000)]; contractor = #external({ name = "Orascom"; reference = "CTR-9" }); reference = "IST-2026-0001" }); currency = "EGP"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #acquireMurabahaAsset({ contract = 910; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #sellMurabaha({ contract = 910; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #collectInstalment({ contract = 910; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #grantRebate({ contract = 910; amount = 1_000_00; reason = "early settlement, at the bank's discretion"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #commenceIjarah({ contract = 911; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #collectRental({ contract = 911; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #transferIjarahOwnership({ contract = 911; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #contributeCapital({ contract = 912; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #distributeMusharakahProfit({ contract = 912; profit = 50_000_00; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #allocateMusharakahLoss({ contract = 912; loss = 10_000_00; offered = ?[(7, 6_000_00)]; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #buyMusharakahUnit({ contract = 912; units = 2; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #recordMudarabahResult({ contract = 913; profit = 20_000_00; loss = 0; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #deliverSalam({ contract = 914; quantity = 500; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #sellSalamCommodity({ contract = 914; proceeds = 97_000_00; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #recordSalamFailure({ contract = 914; recourse = "price returned"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #recordIstisnaMilestone({ contract = 915; certificate = segHash32; percentBps = 3_000; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #collectIstisnaBilling({ contract = 915; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #settleShariaContract({ contract = 912; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #closeShariaContract({ contract = 912; reason = "settled" }),
  #recordNonCompliance({ contract = ?910; amount = 250_00; account = "4500"; reason = "late-payment amount posted to income by mistake"; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
  #openInvestmentPool({ pool = { id = "PSIA-EGP"; currency = "EGP"; mudaribBps = 3_000; perBps = 500; irrBps = 300; product = "ISAV"; incomeAccounts = ["4500", "4510"] } }),
  #updatePoolReserves({ pool = "PSIA-EGP"; per = ?400; irr = null }),
  #distributePool({ pool = "PSIA-EGP"; month = "2026-09"; from = 20698; to = 20727; postingDate = 20726; valueDate = 20726; period = "2026-09"; narration = "s38" }),
];

/// The command a proposal and an override in the event list below carry.
let base : T.Command = #postManualEntry(manual);

// ─── every event variant round-trips ────────────────────────────────────────
let events = List.empty<T.Event>();
List.add(events, #bookOpened({ id = "HQ"; name = "Head office"; parent = null }));
List.add(events, #bookOpened({ id = "BR01"; name = "Branch 1"; parent = ?"HQ" }));
List.add(events, #bookClosed({ id = "BR01" }));
List.add(events, #roleDefined({ id = "checker"; name = "Checker"; permissions = ["command.approve"] }));
List.add(events, #roleGranted({ subject = alice; role = "checker"; scope = fullScope }));
List.add(events, #roleGranted({ subject = bob; role = "maker"; scope = emptyScope }));
List.add(events, #roleRevoked({ subject = alice; role = "checker" }));
List.add(events, #dualPolicySet({ permission = "journal.entry.create"; required = 2; eligibleRole = "checker"; ttlSeconds = 86_400 }));
List.add(events, #dualPolicyCleared({ permission = "book.create" }));
List.add(events, #bankAdminTransferred({ admin = carol }));
List.add(events, #featureActivationSet({ feature = "manual-entry"; height = 17 : Nat64 }));
List.add(events, #commandApproved({ proposal = 7; commandHash = C.commandHash(base); checker = alice }));
List.add(events, #commandRejected({ proposal = 7; checker = alice; reason = "wrong account" }));
List.add(events, #commandExecuted({ proposal = 7; commandHash = C.commandHash(base); postings = [11, 12, 13]; charge = ?{ day = 20705; totals = [("EGP", 1_250_000), ("USD", 7)] } }));
List.add(events, #commandExecuted({ proposal = 7; commandHash = C.commandHash(base); postings = []; charge = null }));
List.add(events, #commandExpired({ proposal = 7 }));
List.add(events, #emergencyOverride({ command = base; commandHash = C.commandHash(base); commandEncoding = 2 : Nat8; actor_ = bob; witness = alice; justification = "checker unreachable" }));
List.add(events, #overrideReviewed({ override_ = 9; reviewer = carol; disposition = "accepted, rate limit reviewed" }));
List.add(events, #operationRefused({ subject = bob; permission = "journal.entry.create"; reason = #overCeiling; detail = "60000 over 50000" }));
List.add(events, #operationRefused({ subject = bob; permission = "command.approve"; reason = #selfApproval; detail = "" }));
// every party event variant
List.add(events, #party(#partyCreated({ kind = #natural; salt = salt32; identityCommit = commit32(30); dedupCommit = ?commit32(31); attributes = [{ name = "screeningSubject"; commit = commit32(32) }]; book = "BR01"; cddLevel = #standard; riskRating = #medium; pep = false; reviewDue = 21000 })));
List.add(events, #party(#partyAmended({ party = 5; attributes = [] })));
List.add(events, #party(#partyLifecycleSet({ party = 5; to = #dormant })));
List.add(events, #party(#partyCddSet({ party = 5; level = #enhanced; riskRating = #high; pep = true; reviewDue = 21200 })));
List.add(events, #party(#partyDocumentAdded({ party = 5; document = { kind = "sourceOfFunds"; commit = commit32(33); issued = 20500; expires = ?21500 } })));
List.add(events, #party(#partyRelationshipAdded({ party = 5; relationship = { kind = #beneficialOwner; other = 6 } })));
List.add(events, #party(#partyExtensionSet({ party = 5; values = [{ schema = "kyc"; name = "resident"; value = #boolean(false) }] })));
List.add(events, #party(#partyIdentifierIssued({ party = 5; identifier = "EG380037000100000000000000042" })));
List.add(events, #party(#screeningListCommitted({ version = "OFAC-2026-09"; root = commit32(34); count = 12345; normalisation = "thebes-norm-v1" })));
List.add(events, #party(#screeningProven({ party = 5; listVersion = "OFAC-2026-09" })));
List.add(events, #party(#screeningDecisionRecorded({ party = 5; listVersion = "OFAC-2026-09"; listRoot = commit32(34); decision = #clear; screener = carol; justificationCommit = commit32(35) })));
List.add(events, #party(#schemaRegistered({ id = "collateralExt"; entity = #collateral; fields = [{ name = "insurer"; fieldType = #text({ maxBytes = 64 }); required = true }] })));
List.add(events, #party(#collateralRegistered({ party = 5; kind = #securities; valuation = { amount = 250_000_00; currency = "USD"; asOf = 20700; source = "custodian"; haircut = 15 }; descriptionCommit = commit32(36) })));
List.add(events, #party(#collateralRevalued({ collateral = 40; valuation = { amount = 260_000_00; currency = "USD"; asOf = 20730; source = "custodian"; haircut = 15 } })));
List.add(events, #party(#collateralAllocated({ collateral = 40; facility = "OD-9"; amount = 100_000_00 })));
List.add(events, #party(#collateralReleased({ collateral = 40 })));
List.add(events, #party(#staffAdded({ principal_ = bob; book = "HQ"; title = "compliance" })));
List.add(events, #party(#staffRemoved({ principal_ = bob })));
List.add(events, #party(#accountFormatSet({ country = "EG"; bank = "0037"; branch = "0002"; serialWidth = 12; prefix = "00000" })));
List.add(events, #party(#jwksPinned({ issuer = "https://id.example.invalid"; keys = [{ kid = "a"; n = commit32(37); e = Blob.fromArray([1, 0, 1]) }]; pinnedAtBlock = 2 })));
List.add(events, #party(#credentialRegistered({ subject = carol; kind = #passkey({ aaguid = Blob.fromArray([7]) }); assurance = #aal3; registeredAtBlock = 2; revokedAtBlock = null })));
List.add(events, #party(#credentialRevoked({ subject = carol })));
List.add(events, #party(#reviewGraceSet({ days = 60 })));
// every product event variant
List.add(events, #product(#productRegistered({ id = "SAV"; version = 1; name = "Savings"; terms = savingsTerms })));
List.add(events, #product(#productRegistered({ id = "LOAN"; version = 1; name = "Term loan"; terms = loanTerms })));
List.add(events, #product(#productAmended({ id = "SAV"; version = 2; supersedes = 1; name = "Savings v2"; terms = savingsTerms })));
List.add(events, #product(#productRedenominated({ id = "SAV"; version = 3; supersedes = 2; from = "EGP"; to = "EGN"; terms = savingsTerms })));
List.add(events, #product(#accountRedenominated({ account = 600; version = 3; from = "EGP"; to = "EGN" })));
List.add(events, #product(#scheduleTermsSet({ account = 600; terms = { amortisation = #equalInstalments; instalments = 4; every = #quarterly; principalGrace = 0; interestGrace = 0; moratoriumDays = 0 }; effective = 20756 })));
List.add(events, #product(#productClosedToNewAccounts({ id = "SAV"; version = 1 })));
List.add(events, #product(#accountOpened({ product = "SAV"; version = 2; party = 5; book = "BR01"; identifier = "EG380037000100000000000000055"; currency = "EGP"; opened = 20705; maturity = null; openingRate = null; allocationOrder = [] })));
List.add(events, #product(#accountOpened({ product = "FD"; version = 1; party = 5; book = "HQ"; identifier = "EG380037000100000000000000056"; currency = "EGP"; opened = 20705; maturity = ?20887; openingRate = ?pRate(10, 100); allocationOrder = [#principal, #interest, #fee, #penalty] })));
List.add(events, #product(#accountStatusSet({ account = 61; to = #active })));
List.add(events, #product(#accountStatusSet({ account = 61; to = #dormant })));
List.add(events, #product(#accountMigrated({ account = 61; from = 1; to = 2 })));
List.add(events, #product(#facilityGranted({ account = 61; limit = 50_000_00 })));
List.add(events, #product(#chargeApplied({ account = 61; charge = "ledger-fee"; amount = 1_000; day = 20705 })));
List.add(events, #product(#chargeWaived({ account = 61; charge = "ledger-fee"; occurrence = 20705; reversalOf = ?88; reason = "goodwill" })));
List.add(events, #product(#chargeWaived({ account = 61; charge = "txn-fee"; occurrence = 20705; reversalOf = null; reason = "never applied" })));
List.add(events, #product(#accrualPosted({ product = "SAV"; currency = "EGP"; day = 20705; amount = 1_234; accounts = 417 })));
List.add(events, #product(#interestCapitalised({ product = "SAV"; currency = "EGP"; from = 20697; to = 20726; examined = 417; posted = 410; zero = 7; total = 98_765; residueNumerator = 34; residueDenominator = 73; residueNegative = false })));
List.add(events, #product(#interestCapitalised({ product = "NEGSAV"; currency = "EGP"; from = 20697; to = 20726; examined = 3; posted = 3; zero = 0; total = 137; residueNumerator = 1; residueDenominator = 2; residueNegative = true })));
List.add(events, #product(#loanDisbursed({ account = 63; amount = 600_000; day = 20705; schedule = instalments })));
List.add(events, #product(#loanRescheduled({ account = 63; version = 2; effective = 20760; schedule = instalments })));
List.add(events, #product(#repaymentReceived({ account = 63; day = 20730; amount = 101_500; applied = { penalty = 500; fee = 1_000; interest = 6_000; principal = 94_000 }; overpayment = 0 })));
List.add(events, #product(#provisionSet({ account = 63; band = ?"30-59"; stage = ?2; required = 80_000; previous = 4_000 })));
List.add(events, #product(#provisionSet({ account = 63; band = null; stage = null; required = 0; previous = 80_000 })));
List.add(events, #product(#loanWrittenOff({ account = 63; components = { penalty = 500; fee = 1_000; interest = 6_000; principal = 400_000 }; fromAllowance = 80_000; toExpense = 327_500; day = 20800 })));
List.add(events, #product(#recoveryReceived({ account = 63; amount = 100_000; day = 20810 })));
List.add(events, #product(#termDepositRedeemed({ account = 62; day = 20790; entitled = 24_931; recoverable = 24_932; payable = 0; early = true })));
List.add(events, #product(#termDepositRedeemed({ account = 62; day = 20887; entitled = 49_863; recoverable = 0; payable = 49_863; early = false })));
List.add(events, #product(#tillOpened({ till = "T01"; book = "BR01"; currency = "EGP"; holder = alice; product = "TILL" })));
List.add(events, #product(#tillAllocated({ till = "T01"; amount = 250_000; day = 20705 })));
List.add(events, #product(#tillReturned({ till = "T01"; amount = 100_000; day = 20705 })));
List.add(events, #product(#tillSettled({ till = "T01"; declared = 299_500; book = 300_000; difference = #short(500); day = 20705 })));
List.add(events, #product(#tillSettled({ till = "T01"; declared = 300_500; book = 300_000; difference = #over(500); day = 20706 })));
List.add(events, #product(#tillSettled({ till = "T01"; declared = 300_000; book = 300_000; difference = #balanced; day = 20707 })));
List.add(events, #product(#tillClosed({ till = "T01" })));
// every close event variant
List.add(events, #close(#functionalCurrencySet({ currency = "EGP" })));
List.add(events, #close(#fxPairSet({ pair = usdPair })));
List.add(events, #close(#fxPairSet({ pair = kwdPair })));
List.add(events, #close(#fxRateSet({ rate = usdRate })));
List.add(events, #close(#backValueWindowSet({ window })));
List.add(events, #close(#backValueApproved({ book = "BR01"; valueDate = 20700; approver = carol; reason = "corrected" })));
List.add(events, #close(#currencyCalendarSet({ currency = "USD"; calendar = ?{ restDays = [5, 6]; holidays = [20817]; policy = #reject } })));
List.add(events, #close(#currencyCalendarSet({ currency = "USD"; calendar = null })));
List.add(events, #close(#redenominationDeclared({ redenomination = { from = "TRY"; to = "TRN"; minorUnits = 2 : Nat8; ratioNumerator = 1; ratioDenominator = 1_000_000; bridgeAccount = "1998"; roundingAccount = "5900"; day = 20726 }; products = ["SAV-TRY", "CUR-TRY"] })));
List.add(events, #close(#balanceRedenominated({ from = "TRY"; to = "TRN"; account = "2110"; subledger = ?("\01\02\03" : Blob); productAccount = ?600; oldAmount = 1_234_567_890; newAmount = 1_235; creditBalance = true; day = 20726 })));
List.add(events, #close(#balanceRedenominated({ from = "TRY"; to = "TRN"; account = "1201"; subledger = null; productAccount = null; oldAmount = 500_000_000; newAmount = 500; creditBalance = false; day = 20726 })));
List.add(events, #close(#redenominationCompleted({ from = "TRY"; to = "TRN"; rows = 3; oldTotal = 1_734_567_890; newTotal = 1_735; roundingAmount = 1; roundingDebit = true; day = 20726 })));
List.add(events, #close(#redenominationCompleted({ from = "TRY"; to = "TRN"; rows = 3; oldTotal = 1_734_567_890; newTotal = 1_735; roundingAmount = 0; roundingDebit = false; day = 20726 })));
List.add(events, #close(#fxDealBooked({ sell = "EGP"; sellAmount = 48_500_00; buy = "USD"; buyAmount = 1_000_00; rateNumerator = 4850; rateDenominator = 100; asOf = 20726; day = 20726 })));
List.add(events, #close(#fxRevalued({ currency = "USD"; position = 1_000_00; equivalent = 48_000_00; revalued = 48_500_00; movement = 500_00; direction = #gain; rateNumerator = 4850; rateDenominator = 100; rateAsOf = 20726; day = 20726 })));
List.add(events, #close(#fxRevalued({ currency = "USD"; position = 1_000_00; equivalent = 49_000_00; revalued = 48_500_00; movement = 500_00; direction = #loss; rateNumerator = 4850; rateDenominator = 100; rateAsOf = 20726; day = 20726 })));
List.add(events, #close(#fxRevalued({ currency = "USD"; position = 0; equivalent = 0; revalued = 0; movement = 0; direction = #unchanged; rateNumerator = 4850; rateDenominator = 100; rateAsOf = 20726; day = 20726 })));
List.add(events, #close(#fxRealised({ currency = "USD"; closedPosition = 1_000_00; bookedEquivalent = 48_000_00; proceeds = 48_500_00; movement = 500_00; direction = #gain; day = 20726 })));
List.add(events, #close(#accrualAdjusted({ product = "SAV"; currency = "EGP"; from = 20697; to = 20726; recomputed = 305; booked = 196; movement = 109; direction = #increase; causedBy = 412; examined = 7 })));
List.add(events, #close(#accrualAdjusted({ product = "SAV"; currency = "EGP"; from = 20697; to = 20726; recomputed = 100; booked = 200; movement = 100; direction = #decrease; causedBy = 413; examined = 7 })));
List.add(events, #close(#accrualAdjusted({ product = "SAV"; currency = "EGP"; from = 20697; to = 20726; recomputed = 200; booked = 200; movement = 0; direction = #unchanged; causedBy = 414; examined = 7 })));
List.add(events, #close(#deferralScheduleOpened({ schedule = unearnedSchedule })));
List.add(events, #close(#deferralScheduleOpened({ schedule = prepaidSchedule })));
List.add(events, #close(#deferralAmortised({ schedule = "rent-2026"; period = "2026-09"; sequence = 3; amount = 100_00; remaining = 300_00 })));
List.add(events, #close(#periodEndOpened({ book = "HQ"; period = "2026-09"; closingDate = 20726 })));
List.add(events, #close(#periodEndRatesRecorded({ book = "HQ"; period = "2026-09"; currencies = 2 })));
List.add(events, #close(#periodEndAccrualComplete({ book = "HQ"; period = "2026-09"; lastBusinessDay = 20726 })));
List.add(events, #close(#periodEndRevalued({ book = "HQ"; period = "2026-09"; currencies = 2; posted = 1; total = 500_00 })));
List.add(events, #close(#periodEndDeferralsAmortised({ book = "HQ"; period = "2026-09"; total = 200_00; rows = [
  { schedule = "arrangement-fee-2026"; sequence = 9; amount = 100_00; remaining = 300_00 },
  { schedule = "rent-2026"; sequence = 3; amount = 100_00; remaining = 300_00 },
] })));
List.add(events, #close(#periodEndDeferralsAmortised({ book = "HQ"; period = "2026-10"; total = 0; rows = [] })));
List.add(events, #close(#periodEndReconciled({ book = "HQ"; period = "2026-09"; controls = 17 })));
List.add(events, #close(#periodEndClosed({ book = "HQ"; period = "2026-09" })));
List.add(events, #close(#yearEndRolled({ book = "HQ"; period = "2026-12"; retainedEarnings = "3200"; accountsClosed = 6; results = [
  { currency = "EGP"; profitCredits = 1_234_56; lossDebits = 0 },
  { currency = "USD"; profitCredits = 0; lossDebits = 99_00 },
] })));
List.add(events, #close(#yearEndRolled({ book = "HQ"; period = "2027-12"; retainedEarnings = "3200"; accountsClosed = 0; results = [] })));
List.add(events, #close(#bookClosedForPeriod({ book = "BR01"; period = "2026-09" })));

// a 32-byte stand-in for a real plan hash: the encoding must carry it byte for byte
let samplePlanHash : Blob = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat(i + 1) }));

// ─── the end-of-day batch ───────────────────────────────────────────────────
List.add(events, #batch(#retryPolicySet({ policy = { book = "HQ"; limit = 3 } })));
List.add(events, #batch(#retryPolicySet({ policy = { book = "BR01"; limit = 0 } })));
List.add(events, #batch(#standingInstructionDefined({ instruction = { id = "rent"; book = "HQ"; from = 10; to = 11; amount = 5_000_00; currency = "EGP"; everyDays = 30; startDay = 20697; endDay = ?20937; narration = "monthly rent" } })));
List.add(events, #batch(#standingInstructionDefined({ instruction = { id = "sweep"; book = "BR01"; from = 12; to = 13; amount = 1; currency = "USD"; everyDays = 1; startDay = 0; endDay = null; narration = "" } })));
List.add(events, #batch(#standingInstructionCancelled({ id = "rent" })));
List.add(events, #batch(#eodOpened({
  book = "HQ"; businessDate = 20726; shardSize = 128; openedAtHeight = 417; maxAccount = 846;
  planHash = samplePlanHash;
  items = 18; entities = 846;
})));
List.add(events, #batch(#eodOpened({
  book = "BR01"; businessDate = 0; shardSize = 1; openedAtHeight = 0; maxAccount = 0;
  planHash = Blob.fromArray([]); items = 0; entities = 0;
})));
List.add(events, #batch(#eodChunk({
  book = "HQ"; businessDate = 20726; cursorFrom = 0; cursorTo = 7;
  posted = 5; examined = 311; zeroMovement = 306; failures = [];
})));
List.add(events, #batch(#eodChunk({
  book = "HQ"; businessDate = 20726; cursorFrom = 7; cursorTo = 18;
  posted = 2; examined = 535; zeroMovement = 0;
  failures = [
    { item = 9; job = #charges; entity = "17"; error = "InsufficientFunds"; attempts = 1 },
    { item = 14; job = #standingInstructions; entity = "rent"; error = "LimitExceeded"; attempts = 3 },
  ];
})));
List.add(events, #batch(#eodCompleted({ book = "HQ"; businessDate = 20726; posted = 7; examined = 846; zeroMovement = 306; failures = 2 })));
List.add(events, #batch(#eodCompleted({ book = "BR01"; businessDate = 0; posted = 0; examined = 0; zeroMovement = 0; failures = 0 })));
List.add(events, #batch(#eodFailed({ book = "HQ"; businessDate = 20726; reason = "PlanHashMismatch" })));
List.add(events, #batch(#eodRetry({
  book = "HQ"; businessDate = 20726;
  resolved = [{ item = 9; entity = "17" }];
  failures = [{ item = 14; job = #standingInstructions; entity = "rent"; error = "LimitExceeded"; attempts = 3 }];
  posted = 1;
})));
List.add(events, #batch(#eodRetry({ book = "BR01"; businessDate = 0; resolved = []; failures = []; posted = 0 })));
List.add(events, #batch(#eodFailureResolved({ book = "HQ"; businessDate = 20726; item = 14; entity = "rent"; justification = "customer closed the mandate" })));
List.add(events, #batch(#eodFailureResolved({ book = "BR01"; businessDate = 0; item = 0; entity = ""; justification = "x" })));
List.add(events, #batch(#eodItemCursor({ book = "HQ"; businessDate = 20726; item = 14; cursor = Blob.fromArray([0x00, 0x48, 0x51, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07]) })));
List.add(events, #batch(#eodItemCursor({ book = "BR01"; businessDate = 0; item = 0; cursor = Blob.fromArray([0x01]) })));
// ─── reporting ────────────────────────────────────────────────────────
List.add(events, #report(#reportDefinitionRegistered({ definition = sampleReportDef; hash = sampleHash32 })));
List.add(events, #report(#reportDefinitionRegistered({ definition = {
  sampleReportDef with id = "R1"; version = 1; rows = [#account]; filters = []; measures = [#closingBalance];
  ordering = #byRowKey; scale = #minorUnits; comparatives = #none; maxSlice = 1;
}; hash = sampleHash32 })));
List.add(events, #report(#returnTemplateRegistered({ template = sampleReturnTemplate; hash = sampleHash32 })));
List.add(events, #report(#returnTemplateRegistered({ template = {
  sampleReturnTemplate with id = "MIN"; version = 1; taxonomy = null; parameters = [];
  lines = [{ code = "X"; caption = "x"; source = #declared({ value = -7 }); binding = null }];
}; hash = sampleHash32 })));
List.add(events, #report(#statementMapSet({ book = "HQ"; map = sampleStatementMap })));
List.add(events, #report(#statementMapSet({ book = "BR01"; map = { cash = []; retainedEarnings = "3200"; investing = []; financing = []; monetary = [] } })));
List.add(events, #report(#reportCertified({ kind = "report"; id = "R34"; book = "HQ"; period = "2026-09"; atHeight = 417; contentHash = sampleHash32; rows = 18 })));
List.add(events, #report(#reportCertified({ kind = "return"; id = "CBE-BS"; book = "HQ"; period = "2026-09"; atHeight = 417; contentHash = sampleHash32; rows = 8 })));
List.add(events, #report(#reportCertified({ kind = "export"; id = "normalised-trial-balance"; book = "HQ"; period = "2026-09"; atHeight = 417; contentHash = sampleHash32; rows = 14 })));
List.add(events, #report(#statementIssued({ statement = sampleStatement })));
List.add(events, #report(#statementIssued({ statement = { sampleStatement with id = "052|23|20726"; account = 23; kind = #camt052({ asOf = 20726 }); balances = []; entryBlocks = [] } })));
List.add(events, #report(#statementIssued({ statement = { sampleStatement with id = "054|89|63"; account = 89; kind = #camt054({ movement = 63 }) } })));
List.add(events, #report(#feedEndpointSet({ endpoint = { url = "https://feed.example.test/thebes"; retries = [30, 120, 600]; active = true } })));
List.add(events, #report(#feedEndpointSet({ endpoint = { url = "https://feed.example.test/off"; retries = []; active = false } })));
List.add(events, #report(#feedDeadLettered({ letter = { cursor = 417; endpoint = "https://feed.example.test/thebes"; attempts = 4; reason = "504 from the consumer" } })));

List.add(events, #batch(#loanAged({ account = 89; day = 20726; band = ?"substandard"; overdueDays = 97; overdueTotal = 12_345_67; instalmentsOverdue = 4 })));
List.add(events, #batch(#loanAged({ account = 90; day = 20726; band = null; overdueDays = 0; overdueTotal = 0; instalmentsOverdue = 0 })));
List.add(events, #batch(#statementCutRecorded({ cut = {
  account = 137; day = 20726; currency = "EGP";
  openingDebits = 1_000_00; openingCredits = 250_00;
  closingDebits = 1_100_00; closingCredits = 250_00; movements = 3;
} })));
List.add(events, #batch(#statementCutRecorded({ cut = {
  account = 23; day = 20726; currency = "USD";
  openingDebits = 0; openingCredits = 0; closingDebits = 0; closingCredits = 0; movements = 0;
} })));
List.add(events, #batch(#standingInstructionExecuted({ id = "rent"; day = 20726; amount = 5_000_00 })));
List.add(events, #batch(#depositMatured({ account = 41; day = 20726; entitled = 3_217_49 })));
List.add(events, #batch(#instalmentDue({ account = 89; day = 20726; instalment = 7; interest = 412_33; principal = 1_587_67 })));
List.add(events, #batch(#instalmentDue({ account = 89; day = 20726; instalment = 0; interest = 0; principal = 0 })));
// one proposal per command variant, so every command encoding is exercised
for (c in commands.vals()) {
  List.add(events, #commandProposed({
    command = ?c; commandHash = C.commandHash(c); commandEncoding = 2 : Nat8; permission = P.commandName(c); book = ?"BR01"; maker = bob;
    required = 1; eligibleRole = "checker"; expiresAt = 1_900_000_000_000_000_000 : Nat64;
    justification = "because";
  }));
};
// every archive event variant
let imageHash : Blob = "\e3\b0\c4\42\98\fc\1c\14\9a\fb\f4\c8\99\6f\b9\24\27\ae\41\e4\64\9b\93\4c\a4\95\99\1b\78\52\b8\56";
List.add(events, #archive(#imagePinned({ sha256 = imageHash; bytes = 182; name = "archive-child" })));
List.add(events, #archive(#imageSealed({ sha256 = imageHash; bytes = 182 })));
List.add(events, #archive(#controllersSet({ controllers = [alice, bob] })));
List.add(events, #archive(#spawnAuthorised({ purpose = "2026-09 postings" })));
List.add(events, #archive(#createIssued({ spawn = 9; attempt = 2 })));
List.add(events, #archive(#childRemembered({ spawn = 9; cid = 1_000_002 : Nat64 })));
List.add(events, #archive(#installIssued({ spawn = 9; cid = 1_000_002 : Nat64; image = imageHash; attempt = 1 })));
List.add(events, #archive(#childConfirmed({ spawn = 9; cid = 1_000_002 : Nat64; image = imageHash })));
List.add(events, #archive(#confirmRefused({ spawn = 9; cid = 1_000_002 : Nat64; offered = commit32(37) })));
List.add(events, #archive(#controllersIssued({ spawn = 9; cid = 1_000_002 : Nat64; controllers = [carol, alice]; attempt = 1 })));
List.add(events, #archive(#childReady({ spawn = 9; cid = 1_000_002 : Nat64 })));
List.add(events, #archive(#spawnAbandoned({ spawn = 9; reason = "rejected" })));
List.add(events, #archive(#childAdopted({ cid = 1_000_007 : Nat64; image = imageHash; controllers = [alice]; purpose = "operator-deployed" })));
// every monitoring event variant, with every rule type
let specs : [MT.RuleSpec] = [
  #velocity({ count = 20; windowDays = 7 }),
  #structuring({ threshold = 500_000_00; bandPercent = 10; count = 3; windowDays = 7; maxScan = 2_000 }),
  #roundTrip({ windowDays = 3; minAmount = 100_000_00 }),
  #fanOut({ distinct = 25; windowDays = 30 }),
  #fanIn({ distinct = 25; windowDays = 30 }),
  #dormantThenActive({ dormantDays = 180; amount = 50_000_00 }),
  #passThrough({ inOutPercent = 90; windowDays = 7; minAmount = 1_000_000_00 }),
  #largeCash({ threshold = 1_000_000_00; channels = ["deposit", "withdrawal"] }),
];
var specNo = 0;
for (spec in specs.vals()) {
  List.add(events, #monitoring(#ruleDefined({ id = "rule-" # Nat.toText(specNo); version = specNo + 1; currency = if (specNo % 2 == 0) ?"EGP" else null; spec })));
  specNo += 1;
};
List.add(events, #monitoring(#ruleRetired({ id = "rule-3"; version = 4 })));
// every alert event variant
let sampleFinding : MT.Finding = { rule = "rule-1"; version = 2; account = 137; day = 20726; postings = [401, 405, 419]; detail = "5 postings in 5 days" };
List.add(events, #alert(#alertOpened({ finding = sampleFinding; source = #posting })));
List.add(events, #alert(#alertOpened({ finding = { sampleFinding with postings = [] }; source = #endOfDay })));
List.add(events, #alert(#alertCleared({ alert = 903; reason = "documented payroll" })));
List.add(events, #alert(#alertEscalated({ alert = 904; reportRef = "STR-2026-000017" })));
// every collections event variant (collections and recovery)
List.add(events, #collections(#policySet({ delinquentDpd = 31; defaultDpd = 90; suspendInterestFrom = #default_; recogniseModificationLoss = true })));
List.add(events, #collections(#stageDerived({ account = 89; from = #current; to = #overdue; dpd = 3; day = 20726; reason = #daysPastDue; note = "" })));
List.add(events, #collections(#stageDerived({ account = 89; from = #delinquent; to = #default_; dpd = 40; day = 20760; reason = #unlikelyToPay; note = "insolvency petition filed" })));
List.add(events, #collections(#actionRecorded({ account = 89; action = #legalNotice; outcome = "served"; next = ?20790; day = 20761 })));
List.add(events, #collections(#actionRecorded({ account = 89; action = #other("sms"); outcome = "delivered"; next = null; day = 20762 })));
List.add(events, #collections(#promiseRecorded({ account = 89; amount = 1_500_00; by = 20770; day = 20762; baseline = 12_000_00 })));
List.add(events, #collections(#promiseJudged({ account = 89; amount = 1_500_00; by = 20770; kept = false; day = 20771 })));
List.add(events, #collections(#collectorAssigned({ account = 89; staff = carol })));
List.add(events, #collections(#interestSuspended({ account = 89; amount = 412_33; day = 20761 })));
List.add(events, #collections(#suspenseReleased({ account = 89; amount = 412_33; day = 20800 })));
// every origination event variant (origination and underwriting)
List.add(events, #origination(#policySet({ rpId = "bank.example"; origin = "https://bank.example"; offerValidityDays = 14; bureaus = [("I-SCORE", #none, Blob.fromArray([])), ("PQ-BUREAU", #mldsa44, Blob.fromArray([9, 8, 7]))] })));
List.add(events, #origination(#affordabilityModelSet({ id = "retail-v1"; version = 1; rules = [{ id = "dsr-45"; kind = #maxDebtServiceRatioBps(4500); onFail = #fail }, { id = "inc"; kind = #minIncome(3_000_00); onFail = #refer }] })));
List.add(events, #origination(#scorecardSet({ id = "retail-card"; version = 2; attributes = [(#income, [{ lo = 0; hi = ?4_999_99; points = 10 }, { lo = 5_000_00; hi = null; points = 25 }]), (#bureauFlags, [{ lo = 0; hi = ?0; points = 10 }])]; declineBelow = 50; referBelow = 80 })));
List.add(events, #origination(#passkeyRegistered({ party = 7; credentialId = OV.CREDENTIAL; publicKeySpki = OV.SPKI })));
List.add(events, #origination(#applicationOpened({ party = ?7; book = "HQ"; request = { product = "PL-STD"; amount = 120_000_00; currency = "EGP"; termDays = 730; purpose = "car" }; channel = "branch"; day = 20726 })));
List.add(events, #origination(#applicationOpened({ party = null; book = "BR01"; request = { product = "PL-STD"; amount = 30_000_00; currency = "EGP"; termDays = 365; purpose = "" }; channel = "web"; day = 20726 })));
List.add(events, #origination(#dataRecorded({ application = 900; facts = { income = 20_000_00; obligations = 2_000_00; proposedInstalment = 5_000_00; dependants = 2 }; commitments = [("employer", segHash32)] })));
List.add(events, #origination(#affordabilityAssessed({ application = 900; model = "retail-v1"; version = 1; verdict = #pass })));
List.add(events, #origination(#affordabilityAssessed({ application = 901; model = "retail-v1"; version = 1; verdict = #fail(["dsr-45", "res"]) })));
List.add(events, #origination(#affordabilityAssessed({ application = 902; model = "retail-v1"; version = 1; verdict = #refer(["inc"]) })));
List.add(events, #origination(#bureauRequested({ application = 900; bureau = "I-SCORE"; consentCommit = segHash32; day = 20726 })));
List.add(events, #origination(#bureauRecorded({ application = 900; report = { bureau = "I-SCORE"; score = 720; flags = ["enquiries-3"]; reportHash = segHash32; reportedOn = 20726 } })));
List.add(events, #origination(#scored({ application = 900; scorecard = "retail-card"; version = 2; points = 120; band = #approve })));
List.add(events, #origination(#underwritten({ application = 900; decision = #approve({ amount = 100_000_00; termDays = 730; rateBps = 1800; conditions = ["salary-assignment"] }); rationale = ""; overrode = false })));
List.add(events, #origination(#underwritten({ application = 901; decision = #decline({ reasons = ["affordability"] }); rationale = "below the floor"; overrode = true })));
List.add(events, #origination(#underwritten({ application = 902; decision = #refer({ to = "credit-committee" }); rationale = ""; overrode = false })));
List.add(events, #origination(#offerIssued({ application = 900; terms = { amount = 90_000_00; termDays = 730; rateBps = 1800; product = "PL-STD"; currency = "EGP"; conditions = ["salary-assignment"] }; offerHash = segHash32; expiresAt = 20740 })));
List.add(events, #origination(#offerAccepted({ application = 900; credentialId = OV.CREDENTIAL; assertionHash = segHash32; day = 20730 })));
List.add(events, #origination(#offerDeclined({ application = 901; day = 20730 })));
List.add(events, #origination(#offerExpired({ application = 902; day = 20741 })));
List.add(events, #origination(#documentRecorded({ application = 900; kind = #facilityAgreement; sha256 = segHash32; signed = true })));
List.add(events, #origination(#documentRecorded({ application = 900; kind = #other("payslip"); sha256 = segHash32; signed = false })));
List.add(events, #origination(#conditionsMet({ application = 900; conditions = ["salary-assignment"]; outstanding = 0 })));
List.add(events, #origination(#documentationComplete({ application = 900; day = 20731 })));
List.add(events, #origination(#prospectOnboarded({ application = 904; party = 8 })));
List.add(events, #origination(#fulfilled({ application = 900; party = 7; account = 9_001; day = 20732 })));
List.add(events, #origination(#withdrawn({ application = 903; reason = "found another lender"; day = 20727 })));
// every facility event variant (corporate lending)
List.add(events, #facility(#facilityOpened({ terms = { party = 7; book = "HQ"; product = "FACL"; kind = #revolving({ commitmentFeeBps = 50; cleanDown = ?{ everyDays = 30; forDays = 5 } }); currency = "EGP"; limit = 1_000_000_00; availabilityFrom = 20726; availabilityTo = 21091; pricing = #floating({ index = "CBE-ON"; spreadBps = 250; resetDays = 30 }); covenants = [{ id = "leverage"; kind = #financialRatio({ name = "net debt / EBITDA"; op = #atMost; thresholdBps = 35_000 }) }, { id = "npl"; kind = #negativePledge }]; collateral = [3]; reviewEvery = ?365 }; day = 20726 })));
List.add(events, #facility(#facilityOpened({ terms = { party = 7; book = "HQ"; product = "FACL"; currency = "EGP"; limit = 1_000_000_00; availabilityFrom = 20726; availabilityTo = 21091; covenants = []; collateral = []; reviewEvery = null; kind = #syndicatedParticipant({ agent = "AGENTBANK"; agentScheme = #mldsa44; agentKey = Blob.fromArray([1, 2, 3]); agentAccount = "1998"; ourBps = 2500 }); pricing = #fixed(1000) }; day = 20726 })));
List.add(events, #facility(#drawn({ facility = 500; account = 600; amount = 250_000_00; rateBps = 1150; day = 20726; splits = [(8, 50_000_00), (9, 37_500_00)] })));
List.add(events, #facility(#drawingRepaid({ facility = 500; account = 600; amount = 10_000_00; day = 20756; interestShared = [(8, 400_00), (9, 300_00)] })));
List.add(events, #facility(#commitmentFeeAccrued({ facility = 500; day = 20727; undrawn = 750_000_00; amount = 1_027 })));
List.add(events, #facility(#cleanDownJudged({ facility = 500; windowEnd = 20756; cleanDays = 3; required = 5; met = false })));
List.add(events, #facility(#participationTransferred({ facility = 501; from = 8; to = 9; bps = 500; moved = 12_500_00 })));
List.add(events, #facility(#distributedToParticipants({ facility = 501; day = 20760; amounts = [(8, 700_00), (9, 525_00)] })));
List.add(events, #facility(#agentNoticeRecorded({ facility = 502; notice = #drawdown({ drawing = "TL-1"; total = 800_000_00; ourShare = 200_000_00; valueDate = 20726 }); noticeHash = segHash32; account = ?601 })));
List.add(events, #facility(#agentNoticeRecorded({ facility = 502; notice = #interestDistribution({ drawing = "TL-1"; total = 8_000_00; ourShare = 2_000_00; valueDate = 20756 }); noticeHash = segHash32; account = null })));
List.add(events, #facility(#facilityRestructured({ facility = 500; terms = { schedule = { amortisation = #equalInstalments; instalments = 9; every = #monthly; principalGrace = 0; interestGrace = 0; moratoriumDays = 0 }; rateBps = 1500 }; effective = 20800; drawings = [600, 602] })));
List.add(events, #facility(#drawingRepriced({ facility = 500; account = 600; day = 20756; rateBps = 1350; fixing = 1100 })));
List.add(events, #facility(#covenantTested({ facility = 500; covenant = "leverage"; value = 41_000; met = false; statementHash = segHash32; day = 20760 })));
List.add(events, #facility(#drawdownsBlocked({ facility = 500; reason = "covenant breach"; day = 20760 })));
List.add(events, #facility(#drawdownsUnblocked({ facility = 500; reason = "waiver granted"; day = 20770 })));
List.add(events, #facility(#reviewRecorded({ facility = 500; day = 20770; nextDue = ?21135; note = "annual review" })));
List.add(events, #facility(#reviewOverdue({ facility = 500; due = 20769; day = 20770 })));
List.add(events, #facility(#leaseRentalAccrued({ facility = 504; day = 20727; amount = 100_000 })));
List.add(events, #facility(#rentalReceived({ facility = 504; amount = 30_000_00; day = 20756 })));
List.add(events, #facility(#residualRemeasured({ facility = 503; from = 20_000_00; to = 15_000_00; day = 20760 })));
List.add(events, #facility(#receivablesPurchased({ facility = 505; receivables = [{ ref = segHash32; debtorCommit = segHash32; face = 120_000_00; due = 20800 }]; face = 120_000_00; advance = 96_000_00; discount = 3_600_00; retention = 20_400_00; day = 20726 })));
List.add(events, #facility(#discountUnwound({ facility = 505; day = 20727; amount = 4_864; items = [(segHash32, 4_864)] })));
List.add(events, #facility(#receivableCollected({ facility = 505; ref = segHash32; amount = 120_000_00; retentionReleased = 20_400_00; day = 20800 })));
List.add(events, #facility(#receivableDishonoured({ facility = 505; ref = segHash32; face = 120_000_00; chargedBack = true; day = 20800 })));
List.add(events, #facility(#receivableWrittenOff({ facility = 506; ref = segHash32; amount = 96_400_00; day = 20830 })));
List.add(events, #facility(#drawingClosed({ facility = 500; account = 600; day = 20900 })));
List.add(events, #facility(#rateFixingRecorded({ index = "CBE-ON"; day = 20726; rateBps = 900 })));
List.add(events, #facility(#facilityClosed({ facility = 507; day = 20900 })));
List.add(events, #product(#accountRateSet({ account = 600; rate = { numerator = 1350; denominator = 10_000; negative = false }; effective = 20756 })));
// every teller event variant (branch and teller)
List.add(events, #teller(#policySet({ overShort = "5300"; cashInTransit = "1002"; centralBank = "1010"; draftsPayable = "2300"; clearing = "2310"; staleDays = 180; clearingWindowDays = 3 })));
List.add(events, #teller(#sessionOpened({ till = "T1"; teller = carol; opening = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; counted = 2_225_00; book = 2_225_00; day = 20726 })));
List.add(events, #teller(#sessionClosed({ session = 700; till = "T1"; closing = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; counted = 2_225_00; book = 2_275_00; difference = #short(50_00); day = 20726 })));
List.add(events, #teller(#sessionClosed({ session = 701; till = "T2"; closing = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; counted = 2_225_00; book = 2_225_00; difference = #balanced; day = 20726 })));
List.add(events, #teller(#differenceResolved({ session = 700; till = "T1"; difference = #over(100_00); account = "5300"; note = "counted over"; day = 20727 })));
List.add(events, #teller(#cashTaken({ till = "T1"; account = 44; amount = 2_200_00; tendered = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; change = { notes = [(5_00, 1)]; coins = [] }; day = 20726 })));
List.add(events, #teller(#cashPaid({ till = "T1"; account = 44; amount = 250_00; paid = { notes = [(200_00, 1), (50_00, 1)]; coins = [] }; day = 20726 })));
List.add(events, #teller(#vaultToTill({ till = "T1"; book = "BR01"; currency = "EGP"; amount = 2_225_00; denominations = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; day = 20726 })));
List.add(events, #teller(#tillToVault({ till = "T1"; book = "BR01"; currency = "EGP"; amount = 2_225_00; denominations = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; day = 20726 })));
List.add(events, #teller(#cashDispatched({ product = "TILL"; fromBook = "BR01"; toBook = "HQ"; currency = "EGP"; amount = 2_225_00; denominations = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; carrier = "ArmourCo"; sealBag = "SB-0001"; day = 20726 })));
List.add(events, #teller(#cashReceived({ movement = 701; denominations = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; day = 20727 })));
List.add(events, #teller(#vaultToCentralBank({ product = "TILL"; book = "HQ"; currency = "EGP"; amount = 2_225_00; denominations = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; day = 20727 })));
List.add(events, #teller(#centralBankToVault({ product = "TILL"; book = "HQ"; currency = "EGP"; amount = 2_225_00; denominations = { notes = [(200_00, 10), (50_00, 4)]; coins = [(1_00, 25), (50, 10)] }; day = 20727 })));
List.add(events, #teller(#chequebookIssued({ account = 44; from = 1; to = 50; day = 20726 })));
List.add(events, #teller(#chequeStopped({ account = 44; serial = 7; reason = "lost"; day = 20726 })));
List.add(events, #teller(#chequePresented({ account = 44; serial = 1; amount = 1_500_00; payee = #clearing({ house = "EGCH"; batch = "B-001" }); chequeDate = 20720; imageHash = segHash32; hold = 4_000; expiresAt = 20729; day = 20726 })));
List.add(events, #teller(#chequePresented({ account = 44; serial = 2; amount = 900_00; payee = #inBranch({ till = "T1" }); chequeDate = 20720; imageHash = segHash32; hold = 4_001; expiresAt = 20729; day = 20726 })));
List.add(events, #teller(#chequeCleared({ account = 44; serial = 1; amount = 1_500_00; day = 20727 })));
List.add(events, #teller(#chequeReturned({ account = 44; serial = 2; amount = 900_00; reason = #insufficientFunds; day = 20727 })));
List.add(events, #teller(#chequeReturned({ account = 44; serial = 9; amount = 500_00; reason = #other("mutilated"); day = 20727 })));
List.add(events, #teller(#draftIssued({ serial = "D-0001"; payeeCommit = segHash32; amount = 3_000_00; currency = "EGP"; source = #account(44); day = 20726 })));
List.add(events, #teller(#draftPaid({ serial = "D-0001"; amount = 3_000_00; to = #till("T1"); day = 20727 })));
List.add(events, #teller(#draftCancelled({ serial = "D-0002"; amount = 1_250_00; refundTo = 44; day = 20727 })));
// every trade event variant (trade finance)
List.add(events, #trade(#policySet({ bic = "THEBEGCX"; contingentLcs = "9101"; contingentGuarantees = "9102"; contingentCollections = "9103"; contingentContra = "9199"; marginDeposits = "2320"; unearnedCommission = "2330"; commissionIncome = "4310"; acceptancesPayable = "2340"; customersLiabilityAcceptances = "1310"; billsNegotiated = "1320"; billsDiscounted = "1330"; unearnedDiscount = "2350"; discountIncome = "4320"; billsRediscounted = "2360"; billLosses = "5310"; nostro = "1005"; claimProduct = "CLAIM"; examinationDays = 5 })));
List.add(events, #trade(#lcIssued({ lc = { role = #issuing; applicant = #party({ party = 7; account = 44 }); beneficiary = #external({ name = "NORDIC TEXTILES AB"; bic = "NDEASESS"; account = "SE4550000000058398257466" }); counterpartyBank = "NDEASESS"; terms = { documents = [{ kind = #invoice; copies = 3; checks = ["INV-AMOUNT", "INV-GOODS"] }, { kind = #transport; copies = 1; checks = ["TRANS-ONBOARD", "TRANS-PORTS"] }]; latestShipment = ?20800; presentationDays = 21; partialShipments = false; transhipment = true; incoterm = ?"CIF"; availableBy = #sight; portOfLoading = "ALEXANDRIA"; portOfDischarge = "ROTTERDAM"; goods = "COTTON YARN 20 TONNES" }; tolerance = ?500; marginBps = 2_000; facility = null; commissionBps = 150; reference = "LC-2026-0001" }; amount = 100_000_00; currency = "EGP"; expiry = 20900; placeOfExpiry = "CAIRO"; margin = 20_000_00; commission = 715_06; book = "BR01"; day = 20726 })));
List.add(events, #trade(#lcAdvised({ lc = { role = #issuing; applicant = #party({ party = 7; account = 44 }); beneficiary = #external({ name = "NORDIC TEXTILES AB"; bic = "NDEASESS"; account = "SE4550000000058398257466" }); counterpartyBank = "NDEASESS"; terms = { documents = [{ kind = #invoice; copies = 3; checks = ["INV-AMOUNT", "INV-GOODS"] }, { kind = #transport; copies = 1; checks = ["TRANS-ONBOARD", "TRANS-PORTS"] }]; latestShipment = ?20800; presentationDays = 21; partialShipments = false; transhipment = true; incoterm = ?"CIF"; availableBy = #sight; portOfLoading = "ALEXANDRIA"; portOfDischarge = "ROTTERDAM"; goods = "COTTON YARN 20 TONNES" }; tolerance = ?500; marginBps = 2_000; facility = null; commissionBps = 150; reference = "LC-2026-0001" }; amount = 250_000_00; currency = "EGP"; expiry = 20900; placeOfExpiry = "STOCKHOLM"; messageHash = segHash32; confirmed = true; commission = 100_00; book = "BR01"; day = 20726 })));
List.add(events, #trade(#lcAmended({ instrument = 900; amendment = { amount = ?120_000_00; expiry = ?20950; latestShipment = null; other = ""; consents = [#beneficiary] }; number = 1; amount = 120_000_00; expiry = 20950; day = 20727 })));
List.add(events, #trade(#documentsPresented({ instrument = 900; claim = 1; documents = [{ kind = #invoice; hash = segHash32 }]; amount = 60_000_00; shipmentDate = ?20790; presentedOn = 20800; deadline = 20807; day = 20800 })));
List.add(events, #trade(#presentationExamined({ instrument = 900; claim = 1; checks = [{ document = #invoice; check = "INV-AMOUNT"; passed = false; finding = "over the credit" }]; decision = #refuse({ discrepancies = ["INV-AMOUNT"]; disposal = #returned }); day = 20802 })));
List.add(events, #trade(#discrepanciesWaived({ instrument = 900; claim = 1; applicantConsentHash = segHash32; day = 20803 })));
List.add(events, #trade(#presentationHonoured({ instrument = 900; claim = 1; amount = 60_000_00; honour = #acceptance({ due = 20890 }); fromMargin = 0; day = 20804 })));
List.add(events, #trade(#acceptanceMatured({ instrument = 900; claim = 1; amount = 60_000_00; fromMargin = 12_000_00; day = 20890 })));
List.add(events, #trade(#lcClosed({ instrument = 900; reason = "utilised"; marginReleased = 20_000_00; day = 20891 })));
List.add(events, #trade(#lcExpired({ instrument = 900; expiry = 20900; marginReleased = 0; day = 20901 })));
List.add(events, #trade(#guaranteeIssued({ guarantee = { kind = #demandGuarantee; rules = #URDG758; principal = 7; principalAccount = 44; beneficiary = #external({ name = "PORT AUTHORITY"; bic = "CIBEEGCX"; account = "" }); counterpartyBank = ""; wording = segHash32; statementRequired = true; reductions = [(20850, 60_000_00)]; marginBps = 1_000; facility = null; commissionBps = 100; reference = "GT-2026-0001" }; wordingText = "WE HEREBY UNDERTAKE TO PAY"; amount = 80_000_00; currency = "EGP"; expiry = 20900; margin = 8_000_00; commission = 381_36; book = "BR01"; day = 20726 })));
List.add(events, #trade(#guaranteeAmended({ instrument = 901; amendment = { amount = null; expiry = ?20960; latestShipment = null; other = "EXTENDED"; consents = [#beneficiary] }; number = 1; amount = 80_000_00; expiry = 20960; day = 20730 })));
List.add(events, #trade(#demandRecorded({ instrument = 901; claim = 1; demand = { kind = #other("demand"); hash = segHash32 }; amount = 30_000_00; supportingStatement = true; presentedOn = 20810; deadline = 20817; day = 20810 })));
List.add(events, #trade(#demandExamined({ instrument = 901; claim = 1; checks = [{ document = #other("demand"); check = "DEMAND-SIGNED"; passed = true; finding = "" }]; decision = #complying; day = 20812 })));
List.add(events, #trade(#demandPaid({ instrument = 901; claim = 1; amount = 30_000_00; fromMargin = 8_000_00; fromAccount = 12_000_00; claimAccount = ?950; day = 20813 })));
List.add(events, #trade(#guaranteeReduced({ instrument = 901; from = 80_000_00; to = 50_000_00; day = 20850 })));
List.add(events, #trade(#guaranteeReleased({ instrument = 901; reason = "returned"; marginReleased = 0; day = 20860 })));
List.add(events, #trade(#guaranteeExpired({ instrument = 901; expiry = 20960; marginReleased = 0; day = 20961 })));
List.add(events, #trade(#collectionRegistered({ collection = { role = #collecting; terms = #DA({ tenorDays = 60 }); drawer = #external({ name = "SHANGHAI MACHINES"; bic = "BKCHCNBJ"; account = "" }); drawee = #party({ party = 7; account = 44 }); counterpartyBank = "BKCHCNBJ"; documents = [{ kind = #invoice; hash = segHash32 }, { kind = #transport; hash = segHash32 }]; instructions = "DELIVER DOCUMENTS AGAINST ACCEPTANCE"; commissionBps = 25; reference = "COL-2026-0001" }; amount = 40_000_00; currency = "EGP"; book = "BR01"; day = 20726 })));
List.add(events, #trade(#collectionPresented({ instrument = 902; claim = 1; presentedOn = 20805; day = 20805 })));
List.add(events, #trade(#collectionAccepted({ instrument = 902; claim = 1; maturity = 20865; day = 20806 })));
List.add(events, #trade(#collectionPaid({ instrument = 902; claim = 1; amount = 40_000_00; commission = 100_00; day = 20865 })));
List.add(events, #trade(#collectionProtested({ instrument = 902; claim = 1; reason = "non-payment"; day = 20866 })));
List.add(events, #trade(#collectionReturned({ instrument = 902; reason = "refused"; day = 20867 })));
List.add(events, #trade(#billDiscounted({ bill = { customer = 7; customerAccount = 44; acceptor = #external({ name = "SHANGHAI MACHINES"; bic = "BKCHCNBJ"; account = "" }); source = ?{ instrument = 900; claim = 1 }; discountBps = 800; recourse = true; reference = "BILL-2026-0001" }; face = 40_000_00; currency = "EGP"; maturity = 20865; discount = 517_80; proceeds = 39_482_20; book = "BR01"; day = 20806 })));
List.add(events, #trade(#billRediscounted({ instrument = 903; to = "CENTRAL BANK OF EGYPT"; amount = 40_000_00; day = 20810 })));
List.add(events, #trade(#billMatured({ instrument = 903; face = 40_000_00; day = 20865 })));
List.add(events, #trade(#billDishonoured({ instrument = 903; face = 40_000_00; chargedBack = 40_000_00; day = 20865 })));
List.add(events, #trade(#tradeMessageRecorded({ instrument = 900; seq = 2; kind = #tsrv(1); direction = #incoming; hash = segHash32; day = 20727 })));
List.add(events, #trade(#commissionEarned({ instrument = 900; amount = 4_11; cumulative = 4_11; day = 20727 })));
List.add(events, #trade(#discountEarned({ instrument = 903; amount = 8_77; cumulative = 8_77; day = 20807 })));
// every Islamic event variant (Islamic banking)
List.add(events, #islamic(#policySet({ murabahaInventory = "1500"; murabahaReceivable = "1510"; deferredProfit = "1515"; murabahaIncome = "4500"; securityDeposits = "2500"; ijarahAssets = "1520"; accumulatedDepreciation = "1525"; depreciationExpense = "5500"; rentalReceivable = "1530"; ijarahIncome = "4510"; musharakahInvestment = "1540"; musharakahIncome = "4520"; mudarabahInvestment = "1550"; mudarabahIncome = "4530"; investmentLosses = "5510"; salamReceivable = "1560"; salamInventory = "1565"; salamIncome = "4540"; istisnaWip = "1570"; istisnaReceivable = "1575"; istisnaRevenue = "4550"; istisnaCosts = "5520"; iahEquity = "2600"; profitEqualisationReserve = "2610"; investmentRiskReserve = "2620"; profitPayableToHolders = "2630"; mudaribShareIncome = "4560"; profitAttributableToHolders = "5530"; charityPayable = "2700"; nostro = "1005"; perCeilingBps = 1_000; irrCeilingBps = 1_000 })));
List.add(events, #islamic(#productApproved({ product = "ISAV"; approval = { ref = "SSB-2026-07"; sha256 = segHash32 }; day = 20726 })));
List.add(events, #islamic(#bookFlagged({ book = "BR01"; sharia = true; day = 20726 })));
List.add(events, #islamic(#contractOpened({ kind = #murabaha({ customer = 7; account = 44; asset = "10 TONNES OF STEEL COILS"; supplier = #external({ name = "Ezz Steel"; reference = "PO-77" }); costPrice = 100_000_00; markup = 12_000_00; instalments = 12; every = #monthly; method = #proportionate; promise = #binding; securityDeposit = 5_000_00; latePaymentCharityBps = 500; reference = "MUR-2026-0001" }); currency = "EGP"; book = "BR01"; day = 20726 })));
List.add(events, #islamic(#contractOpened({ kind = #ijarah({ lessee = 7; account = 44; asset = "CNC MACHINE"; cost = 240_000_00; usefulLifeMonths = 60; residual = 24_000_00; rental = 5_000_00; every = #monthly; periods = 48; transfer = ?#sale({ price = 24_000_00 }); reference = "IJA-2026-0001" }); currency = "EGP"; book = "BR01"; day = 20726 })));
List.add(events, #islamic(#contractOpened({ kind = #musharakah({ partners = [{ party = 7; account = 44; capital = 300_000_00; profitBps = 6_000 }]; bankCapital = 200_000_00; bankProfitBps = 4_000; diminishing = ?{ units = 20; unitPrice = 10_000_00; every = #quarterly; rentalBps = 800 }; reference = "MUS-2026-0001" }); currency = "EGP"; book = "BR01"; day = 20726 })));
List.add(events, #islamic(#contractOpened({ kind = #mudarabah({ mudarib = 7; account = 44; capital = 150_000_00; bankProfitBps = 7_000; term = 365; reference = "MUD-2026-0001" }); currency = "EGP"; book = "BR01"; day = 20726 })));
List.add(events, #islamic(#contractOpened({ kind = #salam({ seller = 7; account = 44; commodity = "WHEAT"; quantity = 500; unit = "TONNE"; delivery = 20900; priceAdvanced = 90_000_00; reference = "SAL-2026-0001" }); currency = "EGP"; book = "BR01"; day = 20726 })));
List.add(events, #islamic(#contractOpened({ kind = #istisna({ customer = 7; account = 44; specification = segHash32; price = 500_000_00; estimatedCost = 400_000_00; milestones = [(20800, 3_000), (20860, 7_000), (20920, 10_000)]; contractor = #external({ name = "Orascom"; reference = "CTR-9" }); reference = "IST-2026-0001" }); currency = "EGP"; book = "BR01"; day = 20726 })));
List.add(events, #islamic(#assetAcquired({ contract = 910; cost = 100_000_00; day = 20727 })));
List.add(events, #islamic(#murabahaSold({ contract = 910; sellingPrice = 112_000_00; deferredProfit = 12_000_00; schedule = [(20757, 9_333_33), (20788, 9_333_33), (20818, 9_333_34)]; day = 20727 })));
List.add(events, #islamic(#instalmentCollected({ contract = 910; amount = 9_333_33; principal = 8_333_33; profit = 1_000_00; day = 20757 })));
List.add(events, #islamic(#profitRecognised({ contract = 910; amount = 32_87; cumulative = 32_87; day = 20728 })));
List.add(events, #islamic(#rebateGranted({ contract = 910; amount = 1_000_00; reason = "early settlement"; day = 20800 })));
List.add(events, #islamic(#latePaymentToCharity({ contract = 910; instalment = 2; amount = 12_79; cumulative = 12_79; day = 20789 })));
List.add(events, #islamic(#leaseCommenced({ contract = 911; day = 20727 })));
List.add(events, #islamic(#rentalAccrued({ contract = 911; amount = 5_000_00; period = 1; day = 20757 })));
List.add(events, #islamic(#rentalCollected({ contract = 911; amount = 5_000_00; day = 20758 })));
List.add(events, #islamic(#depreciationPosted({ contract = 911; amount = 118_35; cumulative = 118_35; day = 20728 })));
List.add(events, #islamic(#ownershipTransferred({ contract = 911; how = #sale({ price = 24_000_00 }); consideration = 24_000_00; day = 22187 })));
List.add(events, #islamic(#capitalContributed({ contract = 912; party = null; amount = 200_000_00; day = 20727 })));
List.add(events, #islamic(#profitDistributed({ contract = 912; profit = 50_000_00; bankShare = 20_000_00; partnerShares = [(7, 30_000_00)]; day = 20800 })));
List.add(events, #islamic(#lossAllocated({ contract = 912; loss = 10_000_00; bankShare = 4_000_00; partnerShares = [(7, 6_000_00)]; day = 20830 })));
List.add(events, #islamic(#unitBought({ contract = 912; units = 2; price = 20_000_00; bankUnitsLeft = 18; day = 20818 })));
List.add(events, #islamic(#commodityDelivered({ contract = 914; quantity = 500; day = 20900 })));
List.add(events, #islamic(#commoditySold({ contract = 914; proceeds = 97_000_00; day = 20902 })));
List.add(events, #islamic(#deliveryFailed({ contract = 914; recourse = "price returned"; day = 20901 })));
List.add(events, #islamic(#milestoneRecorded({ contract = 915; certificate = segHash32; percentBps = 3_000; revenue = 150_000_00; cost = 120_000_00; day = 20800 })));
List.add(events, #islamic(#contractSettled({ contract = 912; day = 20950 })));
List.add(events, #islamic(#contractClosed({ contract = 912; reason = "settled"; day = 20951 })));
List.add(events, #islamic(#nonComplianceRecorded({ contract = ?910; amount = 250_00; account = "4500"; reason = "posted to income by mistake"; day = 20790 })));
List.add(events, #islamic(#poolOpened({ pool = { id = "PSIA-EGP"; currency = "EGP"; mudaribBps = 3_000; perBps = 500; irrBps = 300; product = "ISAV"; incomeAccounts = ["4500", "4510"] }; day = 20726 })));
List.add(events, #islamic(#poolDistributed({ distribution = { pool = "PSIA-EGP"; period = "2026-09"; from = 20698; to = 20727; income = 1_000_00; per = 50_00; distributable = 950_00; mudaribShare = 285_00; holdersShare = 665_00; irr = 19_95; paid = 645_05; weightedBalances = [(44, 3_000_000_00), (45, 1_000_000_00)]; allocations = [(44, 483_79), (45, 161_26)] }; day = 20728 })));
List.add(events, #islamic(#reserveUpdated({ pool = "PSIA-EGP"; per = ?400; irr = null; day = 20730 })));
List.add(events, #treasury(#policySet({ mmPlacements = "1300"; mmTakings = "2300"; mmInterestReceivable = "1310"; mmInterestPayable = "2310"; mmInterestIncome = "4300"; mmInterestExpense = "5300"; fxForwardMark = "1400"; irsMark = "1410"; fxOptionValue = "1420"; unrealisedTradingGain = "4400"; unrealisedTradingLoss = "5400"; realisedTradingGain = "4410"; realisedTradingLoss = "5410"; securitiesAmortisedCost = "1500"; securitiesFvoci = "1510"; securitiesFvtpl = "1520"; fvociReserve = "3500"; couponReceivable = "1530"; couponIncome = "4500"; amortisationIncome = "4510"; amortisationExpense = "5510"; nostroSuspense = "1990"; lotMethod = #fifo; confirmationDueDays = 1; breakAgeAlertDays = 5; maxCurvePoints = 8 })));
List.add(events, #treasury(#securityRegistered({ terms = { isin = "EG0000012345"; issuer = "ARE"; currency = "EGP"; couponBps = 1200; couponsPerYear = 2; dayCount = #a001_ActActIcma({ couponsPerYear = 2 }); issue = 20_500; maturity = 21_596 }; day = 20726 })));
List.add(events, #treasury(#curvePublished({ curve = { id = "EGP-ZERO"; kind = #zeroRates; currency = "EGP"; day = 20726; points = [(1, 2000), (30, 2050), (365, 2200)]; source = segHash32 } })));
List.add(events, #treasury(#curvePublished({ curve = { id = "USDEGP-PTS"; kind = #forwardPoints; currency = "USD"; day = 20726; points = [(1, -20_000), (30, 600_000)]; source = segHash32 } })));
List.add(events, #treasury(#limitSet({ limit = { book = "BR01"; kind = #tenorBucket; currency = "EGP"; subject = "0-400"; value = 100_000_000_00 }; day = 20726 })));
List.add(events, #treasury(#nostroRegistered({ nostro = { id = "NOSTRO-USD-CITI"; account = "1100"; sub = ?"NOSTRO-USD"; currency = "USD"; correspondent = { party = null; name = "CITI"; bic = "CITIUS33"; lei = "6SHGI4ZSSLCXXQSBB395" }; iban = "GB29NWBK60161331926819"; valueDateToleranceDays = 2 }; day = 20726 })));
List.add(events, #treasury(#dealCaptured({ book = "BR01"; counterparty = { party = null; name = "CITI"; bic = "CITIUS33"; lei = "6SHGI4ZSSLCXXQSBB395" }; kind = #fxForward({ base = "USD"; quote = "EGP"; direction = #buy; baseAmount = 500_000_00; rateMicro = 48_600_000; valueDate = 20740; spotMicro = 48_000_000; forwardPointsMicro = 600_000; baseAccount = { account = "1100"; sub = ?"NOSTRO-USD" }; quoteAccount = { account = "1101"; sub = null }; pointsCurve = "USDEGP-PTS"; discountCurve = "EGP-ZERO" }); reference = "FWD-1"; trader = alice; day = 20726; withinLimits = false; approver = ?bob; secondAmount = 24_300_000_00 })));
List.add(events, #treasury(#dealCaptured({ book = "BR01"; counterparty = { party = null; name = "CITI"; bic = "CITIUS33"; lei = "6SHGI4ZSSLCXXQSBB395" }; kind = #fxSwap({ near = { base = "USD"; quote = "EGP"; direction = #buy; baseAmount = 500_000_00; rateMicro = 48_600_000; valueDate = 20740; spotMicro = 48_000_000; forwardPointsMicro = 600_000; baseAccount = { account = "1100"; sub = ?"NOSTRO-USD" }; quoteAccount = { account = "1101"; sub = null }; pointsCurve = "USDEGP-PTS"; discountCurve = "EGP-ZERO" }; far = { base = "USD"; quote = "EGP"; direction = #sell; baseAmount = 500_000_00; rateMicro = 49_800_000; valueDate = 20800; spotMicro = 48_000_000; forwardPointsMicro = 1_800_000; baseAccount = { account = "1100"; sub = ?"NOSTRO-USD" }; quoteAccount = { account = "1101"; sub = null }; pointsCurve = "USDEGP-PTS"; discountCurve = "EGP-ZERO" } }); reference = "SWP-1"; trader = alice; day = 20726; withinLimits = true; approver = null; secondAmount = 24_300_000_00 })));
List.add(events, #treasury(#dealCaptured({ book = "BR01"; counterparty = { party = null; name = "CITI"; bic = "CITIUS33"; lei = "6SHGI4ZSSLCXXQSBB395" }; kind = #moneyMarket({ placement = false; currency = "USD"; principal = 1_000_000_00; rateBps = 450; dayCount = #a003_Act360; start = 20726; maturity = 20816; cash = { account = "1100"; sub = ?"NOSTRO-USD" } }); reference = "MM-1"; trader = alice; day = 20726; withinLimits = true; approver = null; secondAmount = 0 })));
List.add(events, #treasury(#dealCaptured({ book = "BR01"; counterparty = { party = null; name = "CITI"; bic = "CITIUS33"; lei = "6SHGI4ZSSLCXXQSBB395" }; kind = #security({ isin = "EG0000012345"; direction = #buy; nominal = 10_000_000_00; priceMicro = 98_000_000; settlement = 20728; classification = #fvoci; cash = { account = "1101"; sub = null }; priceCurve = "EG0000012345"; venue = ?"EGX" }); reference = "BND-1"; trader = alice; day = 20726; withinLimits = true; approver = null; secondAmount = 9_800_000_00 })));
List.add(events, #treasury(#dealCaptured({ book = "BR01"; counterparty = { party = null; name = "CITI"; bic = "CITIUS33"; lei = "6SHGI4ZSSLCXXQSBB395" }; kind = #irs({ currency = "EGP"; notional = 50_000_000_00; payFixed = true; fixedBps = 2100; floatingIndex = "CBE-ON"; spreadBps = -25; start = 20726; maturity = 21091; paymentMonths = 3; dayCount = #a003_Act360; cash = { account = "1101"; sub = null }; discountCurve = "EGP-ZERO" }); reference = "IRS-1"; trader = alice; day = 20726; withinLimits = true; approver = null; secondAmount = 0 })));
List.add(events, #treasury(#dealCaptured({ book = "BR01"; counterparty = { party = null; name = "CITI"; bic = "CITIUS33"; lei = "6SHGI4ZSSLCXXQSBB395" }; kind = #fxOption({ base = "USD"; quote = "EGP"; call = true; bought = false; baseAmount = 200_000_00; strikeMicro = 49_000_000; expiry = 20786; premium = 150_000_00; start = 20726; cash = { account = "1101"; sub = null }; domesticCurve = "EGP-ZERO"; foreignCurve = "USD-ZERO"; volCurve = "USDEGP-VOL" }); reference = "OPT-1"; trader = alice; day = 20726; withinLimits = true; approver = null; secondAmount = 150_000_00 })));
List.add(events, #treasury(#limitBreached({ limit = { book = "BR01"; kind = #counterpartyExposure; currency = "USD"; subject = "CITI"; value = 3_000_000_00 }; measured = 3_500_000_00; deal = 1201; approver = bob; day = 20726 })));
List.add(events, #treasury(#dealConfirmed({ deal = 1201; confirmation = segHash32; day = 20727 })));
List.add(events, #treasury(#confirmationMismatch({ deal = 1202; confirmation = segHash32; field = "amount1"; ours = "50000000"; theirs = "50000001"; day = 20727 })));
List.add(events, #treasury(#dealAmended({ deal = 1201; kind = #fxForward({ base = "USD"; quote = "EGP"; direction = #buy; baseAmount = 500_000_00; rateMicro = 48_650_000; valueDate = 20740; spotMicro = 48_000_000; forwardPointsMicro = 650_000; baseAccount = { account = "1100"; sub = ?"NOSTRO-USD" }; quoteAccount = { account = "1101"; sub = null }; pointsCurve = "USDEGP-PTS"; discountCurve = "EGP-ZERO" }); reason = "points corrected"; day = 20727; secondAmount = 24_325_000_00 })));
List.add(events, #treasury(#dealCancelled({ deal = 1203; reason = "counterparty withdrew"; day = 20727 })));
List.add(events, #treasury(#legSettled({ deal = 1201; leg = 0; amount = 500_000_00; currency = "USD"; realised = 200_000_00; day = 20740; accrual = 0; amortisation = 0; fv = -1_234_56; nominal = 0; cost = 0 })));
List.add(events, #treasury(#legSettled({ deal = 1204; leg = 1; amount = 1_011_250_00; currency = "USD"; realised = 0; day = 20816; accrual = 6_250_00; amortisation = 0; fv = 0; nominal = 0; cost = 0 })));
List.add(events, #treasury(#lotConsumed({ lot = 1205; by = 1210; nominal = 4_000_000_00; cost = 3_920_000_00; amortisation = -12_345_00; fv = 30_000_00; accrual = -45_000_00; day = 20900 })));
List.add(events, #treasury(#accrued({ deal = 1204; interest = 125_00; amortisation = -17; day = 20727 })));
List.add(events, #treasury(#marked({ deal = 1201; value = -45_678_90; previous = 12_000_00; day = 20727 })));
List.add(events, #treasury(#couponPaid({ deal = 1205; amount = 600_000_00; day = 20865 })));
List.add(events, #treasury(#statementRecorded({ nostro = "NOSTRO-USD-CITI"; statement = segHash32; from = 20720; to = 20726; entries = 4; matches = [7002, 7001, 7003]; breaks = 2; day = 20727 })));
List.add(events, #treasury(#nostroBreak({ nostro = "NOSTRO-USD-CITI"; statement = segHash32; side = #onStatementOnly; amount = 999_00; credit = true; valueDay = 20724; reference = "Q9"; posting = null; day = 20727 })));
List.add(events, #treasury(#nostroBreak({ nostro = "NOSTRO-USD-CITI"; statement = segHash32; side = #inOurBooksOnly; amount = 77_00; credit = false; valueDay = 20725; reference = ""; posting = ?7004; day = 20727 })));
List.add(events, #treasury(#breakResolved({ breakId = 1301; resolution = "correspondent fee, booked"; corrected = true; day = 20730 })));
List.add(events, #treasury(#breakAged({ breakId = 1302; ageDays = 7; day = 20732 })));
List.add(events, #treasury(#confirmationOverdue({ deal = 1202; ageDays = 2; day = 20729 })));
List.add(events, #card(#policySet({ disputeSuspense = "1950"; interchangeIncome = "4600"; schemeFees = "5600"; fraudLosses = "5610"; cardFeeIncome = "4610"; provisionalCreditCeiling = 5_000_00; clearingTolerance = 20_00; stanReplayDays = 3 })));
List.add(events, #card(#schemeDeclared({ scheme = { id = "VISA"; name = "Visa"; settlementAccount = "2900"; settlementCurrency = "EGP"; rules = { source = "Visa Core Rules 2026 (public)"; interchange = [{ mccFrom = 0; mccTo = 5411; bps = 30; fixed = 5 }, { mccFrom = 5412; mccTo = 9999; bps = 120; fixed = 10 }]; floorLimit = 50_00; holdDays = 7; reasons = [{ code = "13.1"; description = "Merchandise not received"; chargebackDays = 120; representmentDays = 30; preArbitrationDays = 30 }]; feeBps = 5 }; connectorScheme = #mldsa44; connectorKey = segHash32 }; day = 20726 })));
List.add(events, #card(#productDefined({ product = { id = "CREDIT-GOLD"; name = "Gold credit"; kind = #credit({ statementDay = 15; minimumDueBps = 500; minimumDueFloor = 100_00; graceDays = 25 }); scheme = "VISA"; bounds = { dailyLimit = 5_000_00; perTransactionLimit = 2_000_00; mccAllow = []; mccDeny = [5813]; channels = { pos = true; atm = true; ecom = true; contactless = true; international = false }; velocityCount = 3; velocityWindowMinutes = 10 }; issueFee = 0; replacementFee = 25_00; expiryMonths = 48 }; day = 20726 })));
List.add(events, #card(#cardIssued({ tokenHash = segHash32; account = 44; party = 7; product = "CREDIT-GOLD"; form = #virtual; expiryMonth = 728; controls = { dailyLimit = 5_000_00; perTransactionLimit = 2_000_00; mccAllow = []; mccDeny = [5813]; channels = { pos = true; atm = true; ecom = true; contactless = true; international = false }; velocityCount = 3; velocityWindowMinutes = 10 }; day = 20726; replaces = ?1400 })));
List.add(events, #card(#cardActivated({ card = 1401; day = 20726 })));
List.add(events, #card(#cardBlocked({ card = 1401; reason = #bank("suspected compromise"); day = 20727 })));
List.add(events, #card(#cardUnblocked({ card = 1401; day = 20727 })));
List.add(events, #card(#cardClosed({ card = 1401; reason = "customer request"; day = 20800 })));
List.add(events, #card(#controlsSet({ card = 1401; controls = { dailyLimit = 5_000_00; perTransactionLimit = 2_000_00; mccAllow = []; mccDeny = [5813]; channels = { pos = true; atm = true; ecom = true; contactless = true; international = false }; velocityCount = 3; velocityWindowMinutes = 10 }; byCustomer = true; day = 20727 })));
List.add(events, #card(#authorised({ card = ?1401; request = { token = "4000123456789010" : Blob; kind = #purchase; amount = 250_00; currency = "EGP"; mcc = 5411; merchantHash = segHash32; merchantCountry = "EG"; acquirer = "40000001"; channel = #pos; cryptogramValid = true; pinVerified = ?true; stan = "000123"; rrn = "092612000123"; localTime = 1_790_000_000_000_000_000 : Nat64 }; decision = #approved({ authCode = "00001B"; hold = ?9001; amount = 250_00 }); day = 20726 })));
List.add(events, #card(#authorised({ card = null; request = { token = "4000123456789010" : Blob; kind = #reversal({ of = 1402 }); amount = 250_00; currency = "EGP"; mcc = 5411; merchantHash = segHash32; merchantCountry = "EG"; acquirer = "40000001"; channel = #pos; cryptogramValid = true; pinVerified = null; stan = "000123"; rrn = "092612000123"; localTime = 1_790_000_000_000_000_000 : Nat64 }; decision = #declined(#unknownCard); day = 20726 })));
List.add(events, #card(#holdAdjusted({ auth = 1402; from = 250_00; to = 100_00; hold = ?9002; kind = "reversal"; day = 20726 })));
List.add(events, #card(#holdExpired({ auth = 1402; hold = 9002; day = 20734 })));
List.add(events, #card(#clearingRecorded({ scheme = "VISA"; batch = segHash32; items = 3; posted = 2; exceptions = 1; interchange = 75_10; fees = 12_50; day = 20727 })));
List.add(events, #card(#cleared({ scheme = "VISA"; batch = segHash32; card = ?1401; item = { authCode = ?"00001B"; token = "4000123456789010" : Blob; amount = 250_00; currency = "EGP"; mcc = 5411; merchantHash = segHash32; acquirer = "40000001"; stan = "000123"; rrn = "092612000123"; day = 20726; refund = false }; outcome = #postedAgainstHold({ auth = 1402; hold = 9001; difference = -5_00 }); interchange = 30_05; fee = 1_25; posting = ?777; day = 20727 })));
List.add(events, #card(#cleared({ scheme = "VISA"; batch = segHash32; card = null; item = { authCode = null; token = "4000123456789010" : Blob; amount = 250_00; currency = "EGP"; mcc = 5411; merchantHash = segHash32; acquirer = "40000001"; stan = "000123"; rrn = "092612000123"; day = 20726; refund = false }; outcome = #exception({ reason = "unknown card token" }); interchange = 0; fee = 0; posting = null; day = 20727 })));
List.add(events, #card(#cleared({ scheme = "VISA"; batch = segHash32; card = ?1401; item = { authCode = null; token = "4000123456789010" : Blob; amount = 250_00; currency = "EGP"; mcc = 5411; merchantHash = segHash32; acquirer = "40000001"; stan = "000123"; rrn = "092612000123"; day = 20726; refund = true }; outcome = #postedDirect({ belowFloor = true }); interchange = 0; fee = 0; posting = ?778; day = 20727 })));
List.add(events, #card(#disputeOpened({ transaction = 1450; card = 1401; reason = "13.1"; amount = 250_00; dueDay = 20847; day = 20730 })));
List.add(events, #card(#provisionalCredited({ dispute = 1460; amount = 250_00; day = 20730 })));
List.add(events, #card(#chargebackRaised({ dispute = 1460; schemeRef = "VISA-CASE-77"; dueDay = 20760; day = 20730 })));
List.add(events, #card(#representmentRecorded({ dispute = 1460; dueDay = 20790; day = 20745 })));
List.add(events, #card(#preArbitrationRecorded({ dispute = 1460; dueDay = 20820; day = 20760 })));
List.add(events, #card(#disputeResolved({ dispute = 1460; outcome = #merchant; finalAmount = 0; day = 20790 })));
List.add(events, #card(#disputeStepDue({ dispute = 1460; stage = #chargeback; dueDay = 20760; day = 20760 })));
List.add(events, #card(#fraudMarked({ transaction = 1450; card = 1401; blocked = true; day = 20731 })));
List.add(events, #card(#statementCut({ card = 1401; cycleEnd = 20740; balance = 1_234_56; minimumDue = 100_00; dueDay = 20765; purchases = 2_000_00; payments = 800_00; interest = 34_56; day = 20740 })));
// every packing event variant
let segHash : Blob = "\e3\b0\c4\42\98\fc\1c\14\9a\fb\f4\c8\99\6f\b9\24\27\ae\41\e4\64\9b\93\4c\a4\95\99\1b\78\52\b8\56";
List.add(events, #packing(#packOpened({ pack = 1; period = "2026-09"; periodEnd = 20726; lo = 0; hi = 4_211; bankLo = 0; bankHi = 17_902 })));
List.add(events, #packing(#segmentPacked({ pack = 1; seq = 0; lo = 0; hi = 1_999; bytes = 61_204; rawBytes = 190_331; postings = 1_954; sha256 = segHash })));
List.add(events, #packing(#bankSegmentPacked({ pack = 1; seq = 0; lo = 0; hi = 1_999; bytes = 402_118; rawBytes = 471_009; dropped = 388; kept = 1_612; sha256 = segHash })));
List.add(events, #packing(#packAdvanced({ pack = 1; phase = "rebuilding:byAccount"; work = 20_000 })));
List.add(events, #packing(#packSealed({ pack = 1; segments = 3; postings = 4_100; accounts = 312; packedBytes = 130_000; rawBytes = 400_000; sha256 = segHash; hi = 4_211; periodEnd = 20726;
                                        bankHi = 17_902; bankSegments = 9; bankPackedBytes = 3_600_000; bankRawBytes = 4_200_000; bankDropped = 3_500; bankKept = 14_403 })));
let archivePrincipal = Principal.fromBlob("\00\00\00\00\00\0F\42\43");
List.add(events, #packing(#rollAuthorised({ pack = 1; cid = 1_000_003 : Nat64; archive = archivePrincipal; hi = 4_211; periodEnd = 20726 })));
List.add(events, #packing(#rollAdvanced({ pack = 1; phase = "folding"; work = 20_000 })));
List.add(events, #packing(#checkpointWritten({ pack = 1; through = 4_211; first = 9_100; last = 9_107 })));
List.add(events, #packing(#segmentSent({ pack = 1; seq = 2; attempt = 1 })));
List.add(events, #packing(#segmentArchived({ pack = 1; seq = 2; sha256 = segHash })));
List.add(events, #packing(#packArchived({ pack = 1; cid = 1_000_003 : Nat64; archive = archivePrincipal; hi = 4_211; journalBase = 4_212; segments = 3 })));
// every shard event variant
List.add(events, #shard(#ruleDeclared({ version = 1; self = 0; shards = [{ index = 0; principal = archivePrincipal; settlement = "1901" }, { index = 1; principal = Principal.fromBlob("\00\00\00\00\00\0F\42\44"); settlement = "1900" }] })));
List.add(events, #shard(#outboundOpened({ from = 284; toIdentifier = "EG870037000100000001000000000031"; toShard = 1; amount = 250_000; currency = "EGP"; valueDay = 20726; period = "2026-09"; narration = "to the other shard"; pendingIndex = 9_310 })));
List.add(events, #shard(#outboundSent({ transfer = 9_200; attempt = 2 })));
List.add(events, #shard(#outboundSettled({ transfer = 9_200; receiverPosting = 77 })));
List.add(events, #shard(#outboundReturned({ transfer = 9_201; reason = "IdentifierNotHere" })));
List.add(events, #shard(#inboundPosted({ fromShard = 1; transfer = 512; toAccount = 284; amount = 250_000; posting = 9_311 })));
List.add(events, #shard(#inboundRefused({ fromShard = 1; transfer = 513; toIdentifier = "EG87003700010000000000000000099"; reason = "IdentifierNotHere" })));
// every settlement event variant
let accts : [SeT.ParticipantAccounts] = [{ currency = "EGP"; position = 301; settlement = 302; feeReceivable = 304 }];
List.add(events, #settlement(#schemeDeclared({ id = "EGP-RTGS"; granularity = #net; interchange = #multilateral; delay = #deferred; reconciliation = "1999"; feeIncome = "4100"; interchangeBps = 25; hubFeeBps = 5; alarmPercent = 90 })));
List.add(events, #settlement(#participantRegistered({ party = 12; bic = "CIBEEGCX"; scheme = "EGP-RTGS"; accounts = accts })));
List.add(events, #settlement(#participantDeactivated({ participant = 310 })));
List.add(events, #settlement(#fundsRecorded({ participant = 310; currency = "EGP"; amount = 500_000_00; direction = #in_; posting = 77 })));
List.add(events, #settlement(#capAlarm({ participant = 310; currency = "EGP"; exposure = 950_000; cap = 1_000_000; alarmPercent = 90 })));
List.add(events, #settlement(#transferPrepared({ scheme = "EGP-RTGS"; payer = 310; payee = 311; currency = "EGP"; amount = 1_250_00; reference = "8f1e3a9c"; expiresAt = 1_700_000_000_000_000_000 : Nat64; bulk = ?(600 : Nat); correctionOf = ?(77 : Nat) })));
List.add(events, #settlement(#transferReserved({ transfer = 400; reservation = 78; forwarded = true })));
List.add(events, #settlement(#transferFailed({ transfer = 401; reason = "ExceedsCredits" })));
List.add(events, #settlement(#transferFulfilDependent({ transfer = 400 })));
List.add(events, #settlement(#transferCommitted({ transfer = 400; posting = 78; window = 500; interchangeFee = 312; hubFee = 62; feePostings = [79, 80] })));
List.add(events, #settlement(#transferAborted({ transfer = 402; how = #expired; reason = "deadline" })));
List.add(events, #settlement(#transfersSettled({ settlement = 501; transfers = [400, 403, 404] })));
List.add(events, #settlement(#windowOpened({ scheme = "EGP-RTGS"; businessDate = 20726 })));
List.add(events, #settlement(#windowStateChanged({ window = 500; to = #processing; reason = "settling" })));
List.add(events, #settlement(#settlementOpened({ window = 500 })));
List.add(events, #settlement(#settlementStateChanged({ settlement = 501; to = #psTransfersRecorded; nets = [{ participant = 310; currency = "EGP"; debits = 1_250_00; credits = 0 }, { participant = 311; currency = "EGP"; debits = 0; credits = 1_250_00 }]; postings = []; reason = "netted" })));
List.add(events, #settlement(#bulkReceived({ scheme = "EGP-RTGS"; payer = 310; reference = "BULK-7"; ttlSeconds = 600; requests = [{ payee = 311; currency = "EGP"; amount = 100_00; reference = "a" }] })));
List.add(events, #settlement(#bulkStateChanged({ bulk = 600; to = #accepted; processing = #accepted; prepared = 1; done = 0; failures = [(0, "x")] })));
// ISO 20022 messaging: the rail, a connector key, a message with every outcome kind, the holds
List.add(events, #payments(#railDeclared({ id = "RTGS"; scheme = "EGP-RTGS"; ttlSeconds = 600; hold = { holdAbove = [("EGP", 5_000_000_00)]; blockedBics = ["BKZYEGCX"]; blockedNameFragments = ["SANCTIONED"] }; signatures = #mldsa44 })));
List.add(events, #payments(#connectorKeyRegistered({ rail = "RTGS"; bic = "CIBEEGCX"; scheme = #mayo2; publicKey = Blob.fromArray([1, 2, 3, 4]) })));
List.add(events, #payments(#messageReceived({ rail = "RTGS"; family = #pacs008; messageId = "MSG-1"; hash = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat(i) })); bytes = 2_048; signer = ?"CIBEEGCX"; verdict = #held; issues = [];
  outcomes = [#prepared({ uetr = "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011"; transfer = 700; reserved = true }), #held({ uetr = "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0012"; transfer = 701; rule = "HOLD-AMOUNT-EGP" }),
              #fulfilled({ uetr = "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0013"; transfer = 702 }), #rejected({ uetr = "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0014"; transfer = 703; reason = "AC01" }),
              #acknowledged({ uetr = "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0015"; transfer = 704; status = "ACSP" }), #returned({ uetr = "RTR:8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011:R1"; original = 700; transfer = 705; reserved = true; committed = true }),
              #refused({ uetr = null; rule = "ISO-BIZ-UETR-REQUIRED"; detail = "no UETR" }), #refused({ uetr = ?"8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0016"; rule = "ISO-BIZ-UNKNOWN-AGENT"; detail = "NOPEEGCX" })] })));
List.add(events, #payments(#messageReceived({ rail = "RTGS"; family = #unknown; messageId = ""; hash = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat(255 - i) })); bytes = 12; signer = null; verdict = #refused; issues = [{ rule = "XML-DECL-POSITION"; path = "$xml@40"; detail = "an XML declaration not at the start" }]; outcomes = [] })));
List.add(events, #payments(#holdReleased({ transfer = 701; reason = "reviewed" })));
List.add(events, #payments(#holdRejected({ transfer = 706; reason = "sanctions match" })));
// the extended target list outcomes and events
List.add(events, #payments(#messageReceived({ rail = "RTGS"; family = #pacs003; messageId = "MSG-7D"; hash = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((i * 3) % 256) })); bytes = 4_096; signer = null; verdict = #accepted; issues = []; outcomes = [
  #reversed({ uetr = "RVS:8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011:RV-1"; original = 700; transfer = 710; reserved = true; committed = true; reason = "DUPL" }),
  #mandateInitiated({ mandate = 800; mandateId = "MNDT-1"; creditorAgent = "CIBEEGCX"; debtorAgent = "BKZYEGCX"; debtorAccount = "EG380019000500000000263180002"; sequence = "RCUR"; maxAmount = ?500_00; currency = ?"EGP" }),
  #mandateInitiated({ mandate = 801; mandateId = "MNDT-2"; creditorAgent = "CIBEEGCX"; debtorAgent = "BKZYEGCX"; debtorAccount = ""; sequence = "OOFF"; maxAmount = null; currency = null }),
  #mandateAmended({ mandate = 800; mandateId = "MNDT-1"; maxAmount = ?800_00; currency = ?"EGP"; debtorAccount = "EG380019000500000000263180002"; reason = "MD16" }),
  #mandateCancelled({ mandate = 800; mandateId = "MNDT-1"; reason = "MD16" }),
  #mandateAccepted({ mandate = 801; mandateId = "MNDT-2"; accepted = false; reason = ?"MD01" }),
  #collected({ uetr = "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0012"; transfer = 711; reserved = true; authority = 800; final = false }),
  #settlementRequested({ window = 500; settlement = 501; cycle = "500"; movements = [{ participantBic = "CIBEEGCX"; currency = "EGP"; amount = 1_250_00; debit = true }, { participantBic = "BKZYEGCX"; currency = "EGP"; amount = 1_250_00; debit = false }] }),
  #reportRequested({ requestId = "RQ-1"; kind = "camt.052.001.08"; account = ?137; fromDay = ?20726; toDay = ?20726 }),
  #reportRequested({ requestId = "RQ-2"; kind = "camt.053.001.08"; account = null; fromDay = null; toDay = null }),
  #receiptExpected({ notificationId = "NTF-1"; itemId = "IT1"; reference = "8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0013"; amount = 250_00; currency = "EGP"; account = ?137 }),
  #receiptMatched({ notification = 802; itemId = "IT1"; transfer = 712 }),
  #liquidityTransferred({ endToEndId = "LQ-1"; participant = 310; currency = "EGP"; amount = 1_000_00; toPosition = true; posting = 9_001 }),
  #caseRecorded({ caseId = "CASE-1"; assignmentId = "ASG-1"; kind = "CLAIM_NON_RECEIPT"; uetr = ?"8f2b5e70-1d44-4e6a-9c4a-2d9c87fd0011"; transfer = ?700 }),
  #caseRecorded({ caseId = "CASE-2"; assignmentId = "ASG-2"; kind = "UNABLE_TO_APPLY"; uetr = null; transfer = null }),
  #resendRequested({ reference = "MSG-1"; messageName = ?"pacs.002.001.10"; message = ?77 }),
  #resendRequested({ reference = "MSG-9"; messageName = null; message = null }),
  #processingRequested({ requestType = "EODP"; session = ?"AB12" }),
  #fileReceived({ payloadId = "FILE-1"; declared = 3; messages = [803, 804, 805] }),
] })));
List.add(events, #payments(#debitAuthorityGranted({ rail = "RTGS"; debtor = 311; creditorBic = "CIBEEGCX"; currency = "EGP"; maxAmount = 5_000_00 })));
List.add(events, #payments(#debitAuthorityRevoked({ rail = "RTGS"; debtor = 311; creditorBic = "CIBEEGCX"; currency = "EGP" })));
List.add(events, #payments(#mandateDecided({ rail = "RTGS"; mandateId = "MNDT-1"; accepted = true; reason = null })));
List.add(events, #payments(#mandateDecided({ rail = "RTGS"; mandateId = "MNDT-3"; accepted = false; reason = ?"customer declined" })));
List.add(events, #payments(#settlementRequestJudged({ settlement = 501; matched = false; detail = "participant CIBEEGCX EGP: the request says DBIT 125001, the window nets DBIT 125000" })));
// the FSPIOP events
List.add(events, #fspiop(#participantDeclared({ rail = "RTGS"; participant = 310; fspId = "dfspa"; endpoints = [("FSPIOP_CALLBACK_URL_TRANSFER_POST", "http://dfspa.local/transfers"), ("FSPIOP_CALLBACK_URL_TRANSFER_ERROR", "http://dfspa.local/transfers/{{transferId}}/error")] })));
List.add(events, #fspiop(#participantDeclared({ rail = "RTGS"; participant = 311; fspId = "dfspb"; endpoints = [] })));
List.add(events, #fspiop(#partyRegistered({ rail = "RTGS"; idType = "MSISDN"; id = "201001234567"; subId = ?"wallet"; fspId = "dfspa"; currency = ?"EGP" })));
List.add(events, #fspiop(#partyRegistered({ rail = "RTGS"; idType = "MSISDN"; id = "201001234568"; subId = null; fspId = "dfspb"; currency = null })));
List.add(events, #fspiop(#partyDeregistered({ rail = "RTGS"; idType = "MSISDN"; id = "201001234567"; subId = ?"wallet" })));
List.add(events, #fspiop(#partyDeregistered({ rail = "RTGS"; idType = "IBAN"; id = "EG380019000500000000263180002"; subId = null })));
List.add(events, #fspiop(#quoteReceived({ rail = "RTGS"; quoteId = "b51ec534-ee48-4575-b6a9-ead2955b8069"; transactionId = "b51ec534-ee48-4575-b6a9-ead2955b806a"; payerFsp = "dfspb"; payeeFsp = "dfspa"; amount = 150_50; currency = "EGP"; amountType = "SEND"; expiration = ?"2026-09-15T13:00:00.000Z" })));
List.add(events, #fspiop(#quoteReceived({ rail = "RTGS"; quoteId = "b51ec534-ee48-4575-b6a9-ead2955b806b"; transactionId = "b51ec534-ee48-4575-b6a9-ead2955b806c"; payerFsp = "dfspb"; payeeFsp = "dfspa"; amount = 1; currency = "USD"; amountType = "RECEIVE"; expiration = null })));
List.add(events, #fspiop(#quoteAnswered({ rail = "RTGS"; quoteId = "b51ec534-ee48-4575-b6a9-ead2955b8069"; transferAmount = 150_50; currency = "EGP"; condition = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((i * 7) % 256) })); ilpPacketHash = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((i * 11) % 256) })); expiration = "2026-09-15T13:00:00.000Z" })));
List.add(events, #fspiop(#transferPrepared({ rail = "RTGS"; transferId = "b51ec534-ee48-4575-b6a9-ead2955b8070"; transfer = 700; condition = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((i * 7) % 256) })); expiration = "2026-09-15T13:00:00.000Z"; ilpPacketHash = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((i * 11) % 256) })) })));
List.add(events, #fspiop(#transferFulfilled({ rail = "RTGS"; transferId = "b51ec534-ee48-4575-b6a9-ead2955b8070"; transfer = 700; fulfilment = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((i * 13) % 256) })); completedAt = "2026-09-15T12:01:00.000Z" })));
List.add(events, #fspiop(#transferAborted({ rail = "RTGS"; transferId = "b51ec534-ee48-4575-b6a9-ead2955b8071"; transfer = 701; errorCode = "3100"; reason = "invalid fulfilment" })));
List.add(events, #fspiop(#requestHandled({ rail = "RTGS"; method = "POST"; path = "/transfers"; source = ?"dfspb"; destination = ?"dfspa"; hash = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((i * 7) % 256) })); status = 202; errorCode = null; callbacks = 1 })));
List.add(events, #fspiop(#requestHandled({ rail = "RTGS"; method = "GET"; path = "/participants/MSISDN/000"; source = ?"dfspb"; destination = null; hash = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((i * 7) % 256) })); status = 404; errorCode = ?"3204"; callbacks = 0 })));
List.add(events, #fspiop(#requestHandled({ rail = "RTGS"; method = "POST"; path = "/transfers"; source = null; destination = null; hash = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat((i * 7) % 256) })); status = 400; errorCode = ?"3102"; callbacks = 0 })));
// the index event as well
List.add(events, #index(#counterpartyClassDimensionSet({ dimension = ?{ schema = "thebes.party"; field = "sector" } })));
List.add(events, #index(#counterpartyClassDimensionSet({ dimension = null })));
let evs = List.toArray(events);

var roundTrips = 0;
var tamperTrials = 0;
var tampersDetected = 0;
var prev : ?Blob = null;
var k = 0;
for (e in evs.vals()) {
  let enc = C.encodeBlock(k, 1_700_000_000_000_000_000 + Nat64.fromNat(k), if (k % 2 == 0) alice else bob, prev, e);
  switch (C.decodeBlock(enc.bytes)) {
    case null { Debug.print("decode failed for event " # Nat.toText(k) # ": " # debug_show e); assert false };
    case (?b) {
      assert (b.index == k);
      assert (b.parentHash == prev);
      assert (b.hash == enc.hash);
      assert (b.event == e);
      let again = C.encodeBlock(b.index, b.timestamp, b.caller, b.parentHash, b.event);
      assert (again.bytes == enc.bytes and again.hash == enc.hash);
    };
  };
  roundTrips += 1;
  // flip every byte in turn
  let bytes = Blob.toArray(enc.bytes);
  var x = 0;
  while (x < bytes.size()) {
    let tampered = Array.tabulate<Nat8>(bytes.size(), func(y) { if (y == x) bytes[y] ^ 0x01 else bytes[y] });
    tamperTrials += 1;
    switch (C.decodeBlock(Blob.fromArray(tampered))) {
      case null tampersDetected += 1;
      case (?_) { Debug.print("tamper undetected at byte " # Nat.toText(x) # " of event " # Nat.toText(k)); assert false };
    };
    x += 1;
  };
  prev := ?enc.hash;
  k += 1;
};
Debug.print("count: bank event round trips = " # Nat.toText(roundTrips));
Debug.print("count: bank block tamper trials = " # Nat.toText(tamperTrials));
Debug.print("count: bank block tampers detected = " # Nat.toText(tampersDetected));
assert (roundTrips == evs.size());
assert (tamperTrials == tampersDetected and tamperTrials > 2000);

// ─── 3. versions ────────────────────────────────────────────────────────────
assert (C.supportsVersion(0x02));
var refused = 0;
var v : Nat = 0;
while (v < 256) {
  if (v != 2) {
    assert (not C.supportsVersion(Nat8.fromNat(v)));
    let enc = C.encodeBlockAtVersion(Nat8.fromNat(v), 0, 1, alice, null, evs[0]);
    switch (C.decodeBlock(enc.bytes)) { case null refused += 1; case (?_) { assert false } };
  };
  v += 1;
};
Debug.print("count: unsupported bank block versions refused = " # Nat.toText(refused));
assert (refused == 255);

// truncated and over-long buffers are refused, never half-decoded
var malformed = 0;
let good = C.encodeBlock(0, 1, alice, null, evs[0]);
let gb = Blob.toArray(good.bytes);
var cut = 1;
while (cut < gb.size()) {
  let short = Array.tabulate<Nat8>(cut, func(y) { gb[y] });
  switch (C.decodeBlock(Blob.fromArray(short))) { case null malformed += 1; case (?_) { Debug.print("truncated block decoded"); assert false } };
  cut += 1;
};
let long = Array.tabulate<Nat8>(gb.size() + 1, func(y) { if (y < gb.size()) gb[y] else 0 });
switch (C.decodeBlock(Blob.fromArray(long))) { case null malformed += 1; case (?_) { Debug.print("over-long block decoded"); assert false } };
Debug.print("count: malformed buffers refused = " # Nat.toText(malformed));
assert (malformed == gb.size());

Debug.print("BANK TAMPER TEST GREEN");
