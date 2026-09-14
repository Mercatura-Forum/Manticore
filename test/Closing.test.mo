// Closing.test.mo; value dating, foreign currency, deferrals and the close, as
// arithmetic and as a state machine, before the state machine uses them.
//
//   * V1/V2 the six value-date conventions reproduce their definitions over a full
//     year of a fixture calendar (Friday and Saturday rest days, an Egyptian holiday
//     list), including month-end crossings, consecutive holidays and the year
//     boundary; and the deployment invariant; the journal's policy must be `#reject`
//     so this is the only layer that moves a date; is checked in both directions;
//   * V6/V7/V8 FX: a revaluation is functional-currency only, the position is
//     untouched by it, the unrealised figure is `position × rate − equivalent`
//     exactly, a cross-currency deal balances **per currency**, and realised and
//     unrealised are the same arithmetic through the same pair so a round trip sums
//     to the economic result and nothing more;
//   * V9 every deferral schedule closes to zero and each period's amortisation is the
//     schedule's own arithmetic;
//   * V11 the close is an order: every out-of-order transition is refused and every
//     re-run is a no-op, over the whole transition matrix;
//   * the back-value window classifies a date into exactly one of three bands.
//
// engine: wasi-only; the journal core now keeps its per-posting state in a stable-memory Region, and
// the moc interpreter provides no Region. The dual-engine check this loses was worth having, and the
// loss is stated rather than hidden: the reason the state moved is that a heap map per posting makes
// the heap grow with the journal. Every test below still runs under wasmtime, the engine the chain runs.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Array "mo:core/Array";

import JT "mo:journal/JournalTypes";
import CivilDate "mo:journal/CivilDate";

import Conv "../src/bank/Conventions";
import Fx "../src/bank/Fx";
import Deferrals "../src/bank/Deferrals";
import PE "../src/bank/PeriodEnd";
import BackValue "../src/bank/BackValue";
import I "../src/bank/Interest";
import Posting "../src/bank/Posting";

func day(y : Nat, m : Nat, d : Nat) : JT.Day {
  switch (CivilDate.fromCivil(y, m, d)) { case (?x) x; case null { Debug.print("bad date"); assert false; 0 } }
};

func text(d : JT.Day) : Text { CivilDate.toText(d) };

// ─── the fixture calendar: Friday and Saturday rest, Egyptian holidays 2026 ──
//
// The holiday list is the set a bank in Egypt would carry: 25 January, Coptic
// Christmas (7 January), Sinai Liberation (25 April), Labour Day (1 May),
// 30 June, 23 July, 6 October, plus a three-day Eid run in March to exercise
// consecutive holidays and 31 December to exercise the year boundary.

let holidays : [JT.Day] = [
  day(2026, 1, 7), day(2026, 1, 25),
  day(2026, 3, 19), day(2026, 3, 20), day(2026, 3, 21),   // a three-day run
  day(2026, 4, 25), day(2026, 5, 1),
  day(2026, 6, 30), day(2026, 7, 23), day(2026, 10, 6),
  day(2026, 11, 30),                                       // the last day of a month
  day(2026, 12, 31),                                       // the year boundary
];

let calendar : ?JT.CalendarConfig = ?{
  restDays = [4, 5];            // Friday and Saturday, ISO weekday numbering
  holidays = Array.sort<JT.Day>(holidays, Nat.compare);
  policy = #reject;
};

Debug.print("count: fixture holidays = " # Nat.toText(holidays.size()));

// ─── 1. the deployment invariant ─────────────────────────────────────────────

assert (Conv.requiresRejectPolicy(calendar) == null);
assert (Conv.requiresRejectPolicy(null) == null);      // no calendar shifts nothing
var policyRefusals = 0;
for (p in [#previous, #next, #nearest].vals()) {
  let bad : ?JT.CalendarConfig = ?{ restDays = [4, 5]; holidays = []; policy = p };
  switch (Conv.requiresRejectPolicy(bad)) {
    case (?reason) { assert (Text.contains(reason, #text "#reject")); policyRefusals += 1 };
    case null { Debug.print("a shifting policy was accepted"); assert false };
  };
};
Debug.print("count: journal shift policies refused for a bank deployment = " # Nat.toText(policyRefusals));
assert (policyRefusals == 3);

// ─── 2. the conventions, over a full year ────────────────────────────────────

// every convention resolves every day of 2026 to a business day, or refuses
var resolved = 0;
var refused = 0;
var moved = 0;
let jan1 = day(2026, 1, 1);
let dec31 = day(2026, 12, 31);
for (c in Conv.conventions().vals()) {
  var d = jan1;
  while (d <= dec31) {
    switch (Conv.resolve(calendar, c, d)) {
      case (#ok(r)) {
        // whatever it resolved to must itself be a business day
        assert (Conv.isBusinessDay(calendar, r.effective));
        assert (r.requested == d);
        if (r.moved) moved += 1;
        resolved += 1;
      };
      case (#err(_)) refused += 1;
    };
    d += 1;
  };
};
Debug.print("count: convention resolutions over a year = " # Nat.toText(resolved));
Debug.print("count: resolutions that moved the date = " # Nat.toText(moved));
Debug.print("count: resolutions refused = " # Nat.toText(refused));
assert (resolved == 6 * 365 - refused);
assert (moved > 0);

// sameDay refuses a non-business day and accepts a business one
switch (Conv.resolve(calendar, #sameDay, day(2026, 1, 7))) {      // a holiday
  case (#err(#notABusinessDay(x))) assert (x.day == day(2026, 1, 7));
  case (other) { Debug.print(debug_show (other)); assert false };
};
switch (Conv.resolve(calendar, #sameDay, day(2026, 1, 8))) {      // a Thursday
  case (#ok(r)) { assert (not r.moved and r.effective == day(2026, 1, 8)) };
  case (other) { Debug.print(debug_show (other)); assert false };
};

// following and preceding across a weekend: 2026-01-02 is a Friday (rest day)
func eff(c : Conv.Convention, d : JT.Day) : JT.Day {
  switch (Conv.resolve(calendar, c, d)) { case (#ok(r)) r.effective; case (#err(_)) { Debug.print("refused " # text(d)); assert false; 0 } }
};
assert (Conv.isBusinessDay(calendar, day(2026, 1, 1)));           // Thursday
assert (not Conv.isBusinessDay(calendar, day(2026, 1, 2)));       // Friday
assert (not Conv.isBusinessDay(calendar, day(2026, 1, 3)));       // Saturday
assert (eff(#following, day(2026, 1, 2)) == day(2026, 1, 4));     // Sunday
assert (eff(#preceding, day(2026, 1, 2)) == day(2026, 1, 1));
Debug.print("count: weekend resolutions verified = 2");

// a three-day holiday run in the middle of a week: 19, 20, 21 March 2026
var runChecks = 0;
for (d in [day(2026, 3, 19), day(2026, 3, 20), day(2026, 3, 21)].vals()) {
  assert (not Conv.isBusinessDay(calendar, d));
  runChecks += 1;
};
assert (eff(#following, day(2026, 3, 19)) == day(2026, 3, 22));
assert (eff(#preceding, day(2026, 3, 19)) == day(2026, 3, 18));
Debug.print("count: consecutive-holiday days verified = " # Nat.toText(runChecks));

// modifiedFollowing is the one worth testing: 30 November 2026 is a holiday and the
// next business day is in December, so it falls back to the previous business day
assert (not Conv.isBusinessDay(calendar, day(2026, 11, 30)));
assert (eff(#following, day(2026, 11, 30)) == day(2026, 12, 1));
assert (eff(#modifiedFollowing, day(2026, 11, 30)) == day(2026, 11, 29));
Debug.print("a month-end holiday: following gives " # text(eff(#following, day(2026, 11, 30)))
  # ", modified following gives " # text(eff(#modifiedFollowing, day(2026, 11, 30))));

// and where the next business day stays inside the month, modifiedFollowing agrees
// with following
assert (eff(#modifiedFollowing, day(2026, 1, 2)) == eff(#following, day(2026, 1, 2)));
Debug.print("count: modified-following month-end crossings verified = 2");

// modifiedPreceding is the mirror: 1 May 2026 is a holiday and 2 May is a Saturday,
// so the previous business day is 30 April; inside the previous month; and the
// convention goes forward instead
assert (not Conv.isBusinessDay(calendar, day(2026, 5, 1)));
assert (eff(#preceding, day(2026, 5, 1)) == day(2026, 4, 30));
assert (eff(#modifiedPreceding, day(2026, 5, 1)) == day(2026, 5, 3));
Debug.print("count: modified-preceding month-start crossings verified = 1");

// endOfMonth is the last business day of the requested date's own month
assert (eff(#endOfMonth, day(2026, 11, 2)) == day(2026, 11, 29));    // 30 Nov is a holiday
assert (eff(#endOfMonth, day(2026, 1, 15)) == day(2026, 1, 29));     // 31 Jan 2026 is a Saturday
assert (Conv.monthEnd(day(2026, 2, 10)) == day(2026, 2, 28));
assert (Conv.monthEnd(day(2024, 2, 10)) == day(2024, 2, 29));        // a leap year
Debug.print("count: end-of-month resolutions verified = 4");

// the year boundary: 31 December 2026 is a holiday
assert (not Conv.isBusinessDay(calendar, dec31));
assert (eff(#following, dec31) == day(2027, 1, 3));
assert (eff(#modifiedFollowing, dec31) == day(2026, 12, 30));
Debug.print("count: year-boundary resolutions verified = 2");

// business-day arithmetic: the window a back-value policy is measured in
let businessDays = Conv.businessDaysBetween(calendar, day(2026, 1, 1), day(2026, 1, 31));
Debug.print("count: business days in January 2026 = " # Nat.toText(businessDays.size()));
assert (businessDays.size() == 19);
for (d in businessDays.vals()) { assert (Conv.isBusinessDay(calendar, d)) };
assert (Conv.businessDaysApart(calendar, day(2026, 1, 1), day(2026, 1, 1)) == 0);
assert (Conv.businessDaysApart(calendar, day(2026, 1, 1), day(2026, 1, 8)) == 4);
assert (Conv.businessDaysApart(calendar, day(2026, 1, 8), day(2026, 1, 1)) == 0);
Debug.print("count: business-day distances verified = 3");

// ─── 3. foreign currency ─────────────────────────────────────────────────────

let pair : Fx.PositionPair = {
  currency = "USD";
  position = "1410";         // the USD position
  equivalent = "1411";       // what it was booked at, in EGP
  unrealised = "4410";
  realised = "4411";
  monetary = true;
};

// a rate: 48.50 EGP per USD, as a ratio of minor units (4850 piastres per 100 cents)
func rate(num : Nat, den : Nat, asOf : JT.Day) : Fx.Rate {
  { currency = "USD"; functional = "EGP"; numerator = num; denominator = den; asOf; source = "test" }
};
let r0 = rate(4850, 100, day(2026, 1, 31));
assert (Fx.validateRate(r0) == null);

var rateRefusals = 0;
for (bad in [
  rate(4850, 0, day(2026, 1, 31)),
  rate(0, 100, day(2026, 1, 31)),
  { r0 with currency = "US" },
  { r0 with functional = "EGP "; },
  { r0 with currency = "EGP" },
  { r0 with source = "" },
].vals()) {
  switch (Fx.validateRate(bad)) { case (?_) rateRefusals += 1; case null { Debug.print("a bad rate was accepted"); assert false } };
};
Debug.print("count: invalid rates refused = " # Nat.toText(rateRefusals));
assert (rateRefusals == 6);

// the equivalent of a position is exact: 10,000.00 USD at 48.50 is 485,000.00 EGP
let eq = Fx.equivalentOf(1_000_000, r0);
assert (eq.numerator == 1_000_000 * 4850 and eq.denominator == 100);
assert ((I.round(eq, #halfEven)).amount == 48_500_000);
Debug.print("10,000.00 USD at 48.50 is " # Nat.toText((I.round(eq, #halfEven)).amount) # " piastres");

// a revaluation: the position was booked at 48.00 and the closing rate is 48.50
var revaluations = 0;
switch (Fx.revalue(pair, 1_000_000, #debit, 48_000_000, r0, #halfEven)) {
  case (#ok(rev)) {
    assert (rev.revalued == 48_500_000);
    assert (rev.movement == 500_000);
    assert (rev.direction == #gain);
    // the figure is exactly position × rate − equivalent
    assert (rev.revalued - rev.equivalent == rev.movement);
    // and the legs are **entirely in the functional currency**: no USD leg at all
    let ?legs = Fx.revaluationLegs(pair, "EGP", rev) else { Debug.print("no legs"); assert false; loop {} };
    assert (legs.size() == 2);
    assert (Posting.balances(legs));
    for (l in legs.vals()) { assert (Text.equal(l.currency, "EGP")); assert (l.amount == 500_000) };
    // the position account is not touched, which is what leaves the position intact
    for (l in legs.vals()) { assert (not Text.equal(l.account, pair.position)) };
    revaluations += 1;
  };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};
// a loss is the mirror
switch (Fx.revalue(pair, 1_000_000, #debit, 49_000_000, r0, #halfEven)) {
  case (#ok(rev)) {
    assert (rev.direction == #loss and rev.movement == 500_000);
    let ?legs = Fx.revaluationLegs(pair, "EGP", rev) else { assert false; loop {} };
    var unrealisedDebit = false;
    for (l in legs.vals()) { if (Text.equal(l.account, pair.unrealised) and l.side == #debit) unrealisedDebit := true };
    assert unrealisedDebit;
    revaluations += 1;
  };
  case (#err(_)) assert false;
};
// and a position already at its revalued figure posts nothing at all
switch (Fx.revalue(pair, 1_000_000, #debit, 48_500_000, r0, #halfEven)) {
  case (#ok(rev)) {
    assert (rev.direction == #unchanged and rev.movement == 0);
    assert (Fx.revaluationLegs(pair, "EGP", rev) == null);
    revaluations += 1;
  };
  case (#err(_)) assert false;
};
Debug.print("count: revaluations verified = " # Nat.toText(revaluations));
assert (revaluations == 3);

// a non-monetary item is not revalued at all (IAS 21), and says so
switch (Fx.revalue({ pair with monetary = false }, 1_000_000, #debit, 48_000_000, r0, #halfEven)) {
  case (#err(#notMonetary(d))) assert (Text.equal(d.currency, "USD"));
  case (other) { Debug.print(debug_show (other)); assert false };
};
Debug.print("count: non-monetary items refused for revaluation = 1");

// a cross-currency deal: four legs, each currency balancing within itself
var deals = 0;
let buyUsd : Fx.Deal = {
  sell = "EGP"; sellAmount = 48_500_000; sellAccount = "1001"; sellSubledger = null;
  buy = "USD"; buyAmount = 1_000_000; buyAccount = "2110"; buySubledger = null;
};
func sideOfAccount(legs : [JT.Leg], account : Text) : ?JT.Side {
  for (l in legs.vals()) { if (Text.equal(l.account, account)) return ?l.side };
  null
};
switch (Fx.dealLegs(pair, "EGP", buyUsd)) {
  case (#ok(legs)) {
    assert (legs.size() == 4);
    assert (Fx.balancesPerCurrency(legs));
    var egp = 0;
    var usd = 0;
    for (l in legs.vals()) { if (Text.equal(l.currency, "EGP")) egp += 1 else usd += 1 };
    assert (egp == 2 and usd == 2);
    // The **directions** matter, not only the balance: inverting all four legs still
    // balances per currency and means the opposite thing. Buying USD: the currency
    // arrives (debit), the position becomes long it (credit), the equivalent records
    // what it cost (debit), and the functional currency leaves (credit).
    assert (sideOfAccount(legs, "2110") == ?#debit);          // the receiving account
    assert (sideOfAccount(legs, pair.position) == ?#credit);
    assert (sideOfAccount(legs, pair.equivalent) == ?#debit);
    assert (sideOfAccount(legs, "1001") == ?#credit);         // the funding account
    deals += 1;
  };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};
let sellUsd : Fx.Deal = {
  sell = "USD"; sellAmount = 1_000_000; sellAccount = "2110"; sellSubledger = null;
  buy = "EGP"; buyAmount = 48_500_000; buyAccount = "1001"; buySubledger = null;
};
switch (Fx.dealLegs(pair, "EGP", sellUsd)) {
  case (#ok(legs)) {
    assert (Fx.balancesPerCurrency(legs));
    // selling is the mirror in every leg
    assert (sideOfAccount(legs, pair.position) == ?#debit);
    assert (sideOfAccount(legs, pair.equivalent) == ?#credit);
    assert (sideOfAccount(legs, "2110") == ?#credit);
    assert (sideOfAccount(legs, "1001") == ?#debit);
    deals += 1;
  };
  case (#err(_)) assert false;
};
// a deal in neither the functional currency nor the pair's is refused
switch (Fx.dealLegs(pair, "EGP", { buyUsd with sell = "KWD"; buy = "GBP" })) {
  case (#err(#functionalMismatch(_))) {};
  case (other) { Debug.print(debug_show (other)); assert false };
};
switch (Fx.dealLegs(pair, "EGP", { buyUsd with buy = "EGP" })) {
  case (#err(#sameCurrency(_))) {};
  case (other) { Debug.print(debug_show (other)); assert false };
};
Debug.print("count: cross-currency deals balancing per currency = " # Nat.toText(deals));
assert (deals == 2);

// a total that balances but whose currencies do not is caught: this is exactly the
// mistake the pair exists to prevent
let crossed : [JT.Leg] = [
  Posting.leg("1001", null, #debit, "EGP", 48_500_000),
  Posting.leg("2110", null, #credit, "USD", 1_000_000),
];
assert (not Fx.balancesPerCurrency(crossed));
Debug.print("count: per-currency imbalances caught = 1");

// V7: realised and unrealised are the same arithmetic through the same pair, so a
// round trip sums to the economic result and nothing more.
//
// Open at 48.00, revalue to 48.50 at the first close, revalue to 49.00 at the
// second, then sell at 49.25. The unrealised movements plus the realised movement
// must equal the whole economic result: 49.25 − 48.00 on 10,000 USD.
let opened = 48_000_000;
let afterFirst = (I.round(Fx.equivalentOf(1_000_000, rate(4850, 100, day(2026, 1, 31))), #halfEven)).amount;
let afterSecond = (I.round(Fx.equivalentOf(1_000_000, rate(4900, 100, day(2026, 2, 28))), #halfEven)).amount;
let proceeds = (I.round(Fx.equivalentOf(1_000_000, rate(4925, 100, day(2026, 3, 31))), #halfEven)).amount;
let unrealised1 = afterFirst - opened;
let unrealised2 = afterSecond - afterFirst;
let realisation = Fx.realise("USD", 1_000_000, afterSecond, proceeds);
assert (realisation.direction == #gain);
let economic = proceeds - opened;
Debug.print("the round trip: unrealised " # Nat.toText(unrealised1) # " + " # Nat.toText(unrealised2)
  # " + realised " # Nat.toText(realisation.movement) # " = " # Nat.toText(economic));
assert (unrealised1 + unrealised2 + realisation.movement == economic);
Debug.print("count: FX round trips with zero residue = 1");

// the realisation's legs are also functional-currency only
let ?realLegs = Fx.realisationLegs(pair, "EGP", realisation) else { assert false; loop {} };
for (l in realLegs.vals()) { assert (Text.equal(l.currency, "EGP")) };
assert (Posting.balances(realLegs));
// and a position sold at what it was booked at realises nothing
assert (Fx.realisationLegs(pair, "EGP", Fx.realise("USD", 1_000_000, opened, opened)) == null);
Debug.print("count: realisation leg shapes verified = 2");

// conversion at a rate is exact and then rounded once
let conv = Fx.convert(333_333, r0, #halfEven);
assert (conv.exact_.numerator == 333_333 * 4850 and conv.exact_.denominator == 100);
Debug.print("333.33 USD at 48.50 converts to " # Nat.toText(conv.amount) # " piastres");
// 333,333 x 48.50 = 16,166,650.5 exactly; half-even breaks the tie to the even
// neighbour, which is 16,166,650
assert (conv.amount == 16_166_650);
Debug.print("count: conversions verified = 1");

// ─── 4. deferrals ────────────────────────────────────────────────────────────

let unearned : Deferrals.Schedule = {
  id = "fee-2026-01";
  kind = #unearnedIncome;
  currency = "EGP";
  amount = 1_000_00;
  periods = 12;
  deferralAccount = "2400";
  recognitionAccount = "4100";
  book = "HQ";
  openedOn = day(2026, 1, 1);
};
assert (Deferrals.validate(unearned) == null);
assert (Deferrals.faults(unearned).size() == 0);

// every period's amount is the schedule's own arithmetic and the column closes to zero
var scheduleChecks = 0;
for (periods in [1, 2, 3, 7, 12, 13, 360].vals()) {
  for (amount in [1_000_00, 100_001, 999_999, 7].vals()) {
    if (amount >= periods) {
      let s : Deferrals.Schedule = { unearned with id = "s" # Nat.toText(periods) # "-" # Nat.toText(amount); amount; periods };
      let faults = Deferrals.faults(s);
      if (faults.size() > 0) { Debug.print("deferral fault: " # faults[0]); assert false };
      let rows = Deferrals.rows(s);
      assert (rows.size() == periods);
      assert (rows[rows.size() - 1].remaining == 0);
      var total = 0;
      for (r in rows.vals()) { total += r.amount };
      assert (total == amount);
      scheduleChecks += 1;
    };
  };
};
Debug.print("count: deferral schedules verified = " # Nat.toText(scheduleChecks));
assert (scheduleChecks >= 20);

// the residue lands in the final period: 100,001 over 12 periods is 8,333 a period
// and 8,338 in the last
let odd : Deferrals.Schedule = { unearned with id = "odd"; amount = 100_001; periods = 12 };
switch (Deferrals.amountFor(odd, 1)) { case (#ok(a)) assert (a == 8_333); case (#err(_)) assert false };
switch (Deferrals.amountFor(odd, 12)) { case (#ok(a)) assert (a == 100_001 - 8_333 * 11); case (#err(_)) assert false };
assert (Deferrals.remainingAfter(odd, 12) == 0);
assert (Deferrals.remainingAfter(odd, 0) == 100_001);
Debug.print("count: deferral residue placements verified = 2");

// a period outside the schedule is refused rather than computed
switch (Deferrals.amountFor(odd, 13)) { case (#err(#beyondSchedule(d))) assert (d.periods == 12); case (_) assert false };
switch (Deferrals.amountFor(odd, 0)) { case (#err(#beyondSchedule(_))) {}; case (_) assert false };

// validation refuses what cannot amortise
var deferralRefusals = 0;
for (bad in [
  { unearned with id = "" },
  { unearned with amount = 0 },
  { unearned with periods = 0 },
  { unearned with periods = Deferrals.MAX_PERIODS + 1 },
  { unearned with amount = 5; periods = 12 },
  { unearned with recognitionAccount = unearned.deferralAccount },
  { unearned with currency = "EG" },
].vals()) {
  switch (Deferrals.validate(bad)) { case (?_) deferralRefusals += 1; case null { Debug.print("a bad schedule was accepted"); assert false } };
};
Debug.print("count: deferral schedules refused = " # Nat.toText(deferralRefusals));
assert (deferralRefusals == 7);

// the legs: unearned income releases a liability into income, prepaid expense the
// mirror, and a zero amount posts nothing
let ?uLegs = Deferrals.legs(unearned, 8_333) else { assert false; loop {} };
assert (Posting.balances(uLegs));
for (l in uLegs.vals()) {
  if (Text.equal(l.account, unearned.deferralAccount)) assert (l.side == #debit);
  if (Text.equal(l.account, unearned.recognitionAccount)) assert (l.side == #credit);
};
let prepaid : Deferrals.Schedule = { unearned with id = "rent"; kind = #prepaidExpense; deferralAccount = "1450"; recognitionAccount = "5300" };
let ?pLegs = Deferrals.legs(prepaid, 8_333) else { assert false; loop {} };
for (l in pLegs.vals()) {
  if (Text.equal(l.account, prepaid.deferralAccount)) assert (l.side == #credit);
  if (Text.equal(l.account, prepaid.recognitionAccount)) assert (l.side == #debit);
};
assert (Deferrals.legs(unearned, 0) == null);
Debug.print("count: deferral leg shapes verified = 3");

// ─── 5. the close is an order ────────────────────────────────────────────────

// the whole transition matrix: exactly one predecessor admits each state, every
// backward or equal transition is a no-op, and everything else is refused
var allowed = 0;
var idempotent = 0;
var outOfOrder = 0;
for (from in PE.states().vals()) {
  for (to in PE.states().vals()) {
    switch (PE.transition(from, to)) {
      case (#allowed) {
        // an allowed transition is always to the state whose predecessor is `from`
        switch (PE.predecessorOf(to)) { case (?p) assert (PE.rank(p) == PE.rank(from)); case null assert false };
        allowed += 1;
      };
      case (#idempotent) { assert (PE.rank(to) <= PE.rank(from)); idempotent += 1 };
      case (#outOfOrder(d)) {
        assert (PE.rank(to) > PE.rank(from));
        assert (PE.rank(d.requires) != PE.rank(from));
        outOfOrder += 1;
      };
    };
  };
};
Debug.print("count: close transitions examined = " # Nat.toText(allowed + idempotent + outOfOrder));
Debug.print("count: transitions allowed = " # Nat.toText(allowed));
Debug.print("count: transitions that are a no-op = " # Nat.toText(idempotent));
Debug.print("count: transitions refused as out of order = " # Nat.toText(outOfOrder));
assert (allowed == 6);                    // one per step after `opened`
assert (allowed + idempotent + outOfOrder == 49);
assert (PE.predecessorOf(#opened) == null);
assert (PE.rank(#closed) == 6);

// the states are a total order with no gaps
var previousRank = 0;
var first = true;
for (st in PE.states().vals()) {
  if (first) { assert (PE.rank(st) == 0); first := false }
  else { assert (PE.rank(st) == previousRank + 1) };
  previousRank := PE.rank(st);
  assert (Text.encodeUtf8(PE.stateText(st)).size() > 0);
};
Debug.print("count: close states ordered without gaps = " # Nat.toText(PE.states().size()));

// the control-account check
let agreeing : PE.ControlCheck = {
  account = "2110"; currency = "EGP";
  ledgerDebits = 1_000; ledgerCredits = 5_000;
  subledgerDebits = 1_000; subledgerCredits = 5_000;
};
assert (PE.controlAgrees(agreeing));
let diverging : PE.ControlCheck = { agreeing with subledgerCredits = 4_999 };
assert (not PE.controlAgrees(diverging));
switch (PE.firstDivergence([agreeing, diverging, agreeing])) {
  case (?c) assert (c.subledgerCredits == 4_999);
  case null assert false;
};
assert (PE.firstDivergence([agreeing, agreeing]) == null);
Debug.print("count: control-account checks verified = 4");

// an unbalanced currency in a trial balance is named
let totals = [
  { currency = "EGP"; periodDebits = 100; periodCredits = 100; closingDebits = 500; closingCredits = 500 },
  { currency = "USD"; periodDebits = 10; periodCredits = 10; closingDebits = 50; closingCredits = 49 },
];
let unbalanced = PE.unbalancedCurrencies(totals);
assert (unbalanced.size() == 1 and Text.equal(unbalanced[0], "USD"));
Debug.print("count: unbalanced currencies detected = 1");

// ─── 6. the back-value window ────────────────────────────────────────────────

let window : PE.BackValueWindow = { book = "BR01"; freeDays = 5; approvedDays = 20 };
assert (PE.validateWindow(window) == null);
var bands = 0;
for ((back, want) in [(0, "in"), (1, "in"), (5, "in"), (6, "approval"), (25, "approval"), (26, "beyond"), (400, "beyond")].vals()) {
  let got = switch (PE.classifyBackValue(window, back)) {
    case (#inWindow(_)) "in";
    case (#needsApproval(_)) "approval";
    case (#beyondWindow(_)) "beyond";
  };
  if (not Text.equal(got, want)) { Debug.print("at " # Nat.toText(back) # " days back wanted " # want # " got " # got); assert false };
  bands += 1;
};
Debug.print("count: back-value classifications verified = " # Nat.toText(bands));
assert (bands == 7);

// a window of zero approved days means nothing beyond the free window admits
let strict : PE.BackValueWindow = { book = "BR01"; freeDays = 2; approvedDays = 0 };
switch (PE.classifyBackValue(strict, 3)) { case (#beyondWindow(_)) {}; case (_) assert false };
assert (PE.validateWindow({ strict with freeDays = PE.MAX_WINDOW_DAYS + 1 }) != null);
Debug.print("count: strict windows verified = 1");

// ─── 7. the back-value correction ────────────────────────────────────────────

// the correction is a subtraction of two knowable quantities, and both are reported
var adjustments = 0;
for ((recomputed, booked, wantMovement, wantDirection) in [
  (1_000, 900, 100, "increase"),
  (900, 1_000, 100, "decrease"),
  (1_000, 1_000, 0, "unchanged"),
  (0, 500, 500, "decrease"),
].vals()) {
  let a = BackValue.compute("SAV", "EGP", day(2026, 1, 1), day(2026, 1, 31), recomputed, booked, 7);
  assert (a.movement == wantMovement);
  assert (Text.equal(BackValue.directionText(a.direction), wantDirection));
  assert (a.recomputed == recomputed and a.booked == booked);
  assert (a.examined == 7);
  // the legs are the accrual's own, with the sides decided by the direction
  switch (BackValue.legs("5100", "2120", "EGP", a)) {
    case null assert (wantMovement == 0);
    case (?legs) {
      assert (Posting.balances(legs));
      assert (legs.size() == 2);
      for (l in legs.vals()) { assert (l.amount == wantMovement) };
      // an increase posts what the accrual posts; a decrease posts its reverse
      var expenseSide : ?JT.Side = null;
      for (l in legs.vals()) { if (Text.equal(l.account, "5100")) expenseSide := ?l.side };
      switch (expenseSide, a.direction) {
        case (?#debit, #increase) {};
        case (?#credit, #decrease) {};
        case (_, _) { Debug.print("the adjustment's sides are wrong for " # wantDirection); assert false };
      };
    };
  };
  adjustments += 1;
};
Debug.print("count: back-value corrections verified = " # Nat.toText(adjustments));
assert (adjustments == 4);

// the correction's key is a function of the facts, so a re-run is a duplicate
let k1 = BackValue.key("SAV", "EGP", 100, 200, 42);
assert (k1 == BackValue.key("SAV", "EGP", 100, 200, 42));
assert (k1 != BackValue.key("SAV", "EGP", 100, 200, 43));
assert (k1 != BackValue.key("SAV", "USD", 100, 200, 42));
assert (k1 != BackValue.key("LOAN", "EGP", 100, 200, 42));
assert (k1.size() == 32);
Debug.print("count: correction key separations verified = 4");

Debug.print("CLOSING TEST GREEN");
