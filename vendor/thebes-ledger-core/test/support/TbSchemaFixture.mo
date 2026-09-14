/// TbSchemaFixture.mo; the 28 account ranges of the audit product's tb_schema.json.
///
/// Source: tb_schema.json, md5 9c318db8872149469bca42831bc6c384, generated_at 2026-02-08T17:05:14.260862,
/// total_account_ranges 28, total_leadsheets_mapped 21.
/// Generated mechanically from the JSON (integration/fixtures/tb_schema.json carries
/// the same bytes); do not edit by hand.

import T "../../src/journal/JournalTypes";

module {
  public let SOURCE_MD5 : Text = "9c318db8872149469bca42831bc6c384";
  public let RANGE_COUNT : Nat = 28;
  public let LEADSHEETS_MAPPED : Nat = 21;
  public let ranges : [T.LeadsheetRange] = [
    { lo = 1000; hi = 1099; leadsheet = "1"; name = "Property, Plant & Equipment"; category = "non_current_assets"; cycle = "ppe" },
    { lo = 1100; hi = 1149; leadsheet = "5"; name = "Investment Property"; category = "non_current_assets"; cycle = "ppe" },
    { lo = 1150; hi = 1199; leadsheet = "10"; name = "Intangible Assets & Goodwill"; category = "non_current_assets"; cycle = "general" },
    { lo = 1200; hi = 1249; leadsheet = "20"; name = "Investments"; category = "non_current_assets"; cycle = "equity" },
    { lo = 1250; hi = 1299; leadsheet = "35"; name = "Receivables (Non-current)"; category = "non_current_assets"; cycle = "revenue" },
    { lo = 1300; hi = 1349; leadsheet = "120"; name = "Other Financial Assets (Current)"; category = "current_assets"; cycle = "general" },
    { lo = 1350; hi = 1399; leadsheet = "110"; name = "Inventories"; category = "current_assets"; cycle = "inventory" },
    { lo = 1400; hi = 1449; leadsheet = "130"; name = "Receivables (Current)"; category = "current_assets"; cycle = "revenue" },
    { lo = 1450; hi = 1499; leadsheet = "135"; name = "Prepayments"; category = "current_assets"; cycle = "general" },
    { lo = 1500; hi = 1599; leadsheet = "140"; name = "Cash & Cash Equivalents"; category = "current_assets"; cycle = "cash" },
    { lo = 2000; hi = 2099; leadsheet = "200"; name = "Share Capital"; category = "equity"; cycle = "equity" },
    { lo = 2100; hi = 2199; leadsheet = "200"; name = "Reserves"; category = "equity"; cycle = "equity" },
    { lo = 2200; hi = 2299; leadsheet = "200"; name = "Retained Earnings"; category = "equity"; cycle = "equity" },
    { lo = 3000; hi = 3099; leadsheet = "300"; name = "Borrowings (Non-current)"; category = "non_current_liabilities"; cycle = "general" },
    { lo = 3100; hi = 3199; leadsheet = "325"; name = "Deferred Tax Liabilities"; category = "non_current_liabilities"; cycle = "general" },
    { lo = 3200; hi = 3299; leadsheet = "330"; name = "Other Liabilities (Non-current)"; category = "non_current_liabilities"; cycle = "general" },
    { lo = 4000; hi = 4099; leadsheet = "400"; name = "Borrowings (Current)"; category = "current_liabilities"; cycle = "general" },
    { lo = 4100; hi = 4199; leadsheet = "425"; name = "Trade Payables"; category = "current_liabilities"; cycle = "expenditure" },
    { lo = 4200; hi = 4299; leadsheet = "430"; name = "Other Current Liabilities"; category = "current_liabilities"; cycle = "expenditure" },
    { lo = 5000; hi = 5099; leadsheet = "1500"; name = "Revenue"; category = "income"; cycle = "revenue" },
    { lo = 5100; hi = 5199; leadsheet = "1700"; name = "Other Income"; category = "income"; cycle = "revenue" },
    { lo = 6000; hi = 6099; leadsheet = "1600"; name = "Cost of Sales"; category = "expenses"; cycle = "expenditure" },
    { lo = 6100; hi = 6199; leadsheet = "1600"; name = "Distribution Costs"; category = "expenses"; cycle = "expenditure" },
    { lo = 6200; hi = 6299; leadsheet = "1600"; name = "Administrative Expenses"; category = "expenses"; cycle = "expenditure" },
    { lo = 6300; hi = 6399; leadsheet = "1600"; name = "Staff Costs"; category = "expenses"; cycle = "payroll" },
    { lo = 6400; hi = 6499; leadsheet = "1800"; name = "Other Expenses"; category = "expenses"; cycle = "general" },
    { lo = 6500; hi = 6599; leadsheet = "1800"; name = "Finance Costs"; category = "expenses"; cycle = "general" },
    { lo = 6600; hi = 6699; leadsheet = "325"; name = "Tax Expense"; category = "expenses"; cycle = "general" },
  ];
};
