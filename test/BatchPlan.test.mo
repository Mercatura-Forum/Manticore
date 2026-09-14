// BatchPlan.test.mo: the end-of-day plan, as arithmetic.
//
// The plan is what makes the batch safe to chunk, so it is proved on its own terms
// before any of it is run:
//
//   * the same inputs always give the same plan, and the plan's hash is a function of
//     the plan alone; which is what lets a chunk re-derive it and check that the work
//     it is about to do is the work the opening block declared;
//   * the jobs come out in their declared order, because they have real dependencies: a
//     percent-of-interest charge reads job 1's accrual, a band reads job 3's result, a
//     provision reads job 4's band;
//   * **the shard size changes nothing in the plan**: since the audit of 13 September (finding A1) an item
//     is a walk of one product's accounts (or one book's instructions, offers, facilities, instruments,
//     contracts, deals or cards) and the shard size is the page a chunk takes, so the plan and its hash
//     are identical at sizes 1, 7 and 1,000 and no count of rows is an input; nothing that happens during
//     a run can change the plan under it (finding B1);
//   * a standing instruction's recurrence is computable from its record alone;
//   * the retry policy and the run-state vocabulary say what they mean.
//
// engine: wasi-only; the journal core now keeps its per-posting state in a stable-memory Region, and
// the moc interpreter provides no Region. The dual-engine check this loses was worth having, and the
// loss is stated rather than hidden: the reason the state moved is that a heap map per posting makes
// the heap grow with the journal. Every test below still runs under wasmtime, the engine the chain runs.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Array "mo:core/Array";
import List "mo:core/List";

import JT "mo:journal/JournalTypes";

import Batch "../src/bank/Batch";
import BT "../src/bank/BatchTypes";

// ─── a portfolio to plan over ────────────────────────────────────────────────

func product(id : Text, ccy : Text, accrues : Bool, credit : Bool, term : Bool, charges : Bool)
  : { product : Text; currency : JT.Currency; accrues : Bool; credit : Bool; term : Bool; charges : Bool } {
  { product = id; currency = ccy; accrues; credit; term; charges }
};

let portfolio = [
  product("CUR", "EGP", true, false, false, true),    // a current account with charges
  product("FD", "EGP", true, false, true, false),      // a term deposit
  product("LOAN", "EGP", true, true, false, true),     // a loan with a penalty charge
  product("SAVUSD", "USD", true, false, false, false), // a second currency
];
let allDomains = { facilities = true; trade = true; sharia = true; treasury = true; cards = true };
let noDomains = { facilities = false; trade = false; sharia = false; treasury = false; cards = false };

func input(shardSize : Nat) : Batch.Input {
  { products = portfolio; domains = noDomains; redenominations = []; shardSize }
};

func planOf(shardSize : Nat) : [Batch.PlanItem] {
  switch (Batch.plan(input(shardSize))) {
    case (#ok(items)) items;
    case (#err(e)) { Debug.print("plan failed: " # debug_show (e)); assert false; [] };
  }
};
func countJob(items : [Batch.PlanItem], job : Batch.Job) : Nat { var n = 0; for (i in items.vals()) { if (i.job == job) n += 1 }; n };

// ─── 1. the plan is deterministic, and its hash is a function of it ──────────

let p128 = planOf(128);
let p128again = planOf(128);
assert (p128.size() == p128again.size());
assert (Batch.planHash(p128) == Batch.planHash(p128again));
assert (Batch.planHash(p128).size() == 32);
Debug.print("count: plan items at the default shard size = " # Nat.toText(p128.size()));

// the shard size is the page a chunk walks, never a shape of the plan
var sameAtEverySize = 0;
for (shardSize in [1, 7, 128, 1_000, Batch.MAX_SHARD_SIZE].vals()) {
  let items = planOf(shardSize);
  assert (items.size() == p128.size() and Batch.planHash(items) == Batch.planHash(p128));
  if (not Batch.inJobOrder(items)) { Debug.print("the plan is out of job order at shard size " # Nat.toText(shardSize)); assert false };
  sameAtEverySize += 1;
};
Debug.print("count: shard sizes whose plan and hash are identical and in job order = " # Nat.toText(sameAtEverySize));

// every single-field change to an input changes the hash: the plan is a function of its inputs and nothing else
var hashChecks = 0;
func differs(i : Batch.Input) { switch (Batch.plan(i)) { case (#ok(items)) { assert (Batch.planHash(items) != Batch.planHash(p128)); hashChecks += 1 }; case (#err(_)) assert false } };
differs({ input(128) with products = [portfolio[0], portfolio[1], portfolio[2]] });
differs({ input(128) with products = Array.concat<{ product : Text; currency : JT.Currency; accrues : Bool; credit : Bool; term : Bool; charges : Bool }>(portfolio, [product("NEW", "EGP", false, false, false, false)]) });
differs({ input(128) with products = [{ portfolio[0] with charges = false }, portfolio[1], portfolio[2], portfolio[3]] });
differs({ input(128) with products = [{ portfolio[0] with currency = "USD" }, portfolio[1], portfolio[2], portfolio[3]] });
differs({ input(128) with domains = { noDomains with treasury = true } });
differs({ input(128) with domains = allDomains });
differs({ input(128) with redenominations = [{ from = "USD"; to = "USN"; products = ["SAVUSD"] }] });
Debug.print("count: single-field plan mutations that changed the hash = " # Nat.toText(hashChecks));

// ─── 2. the jobs come out in their declared order ────────────────────────────

// the jobs are a total order of ranks with no gaps, and each has a name; the rank is the job's name in every
// encoding, the position its place in the day; they differ for the redenomination alone, which is first
var rank = 1;
for (j in Batch.jobs().vals()) {
  assert (Batch.jobRank(j) == rank);
  assert (Text.encodeUtf8(Batch.jobText(j)).size() > 0);
  assert (Batch.jobPosition(j) == (if (j == #redenomination) 0 else rank));
  rank += 1;
};
Debug.print("count: jobs in the declared order = " # Nat.toText(Batch.jobs().size()));
assert (Batch.jobs().size() == 17);
assert (Batch.jobRank(#redenomination) == 17 and Batch.jobPosition(#redenomination) == 0);

// accrual is first and the till check is the last posting job, because the first must precede
// anything that reads accrued interest and the till check is the one that blocks a close;
// monitoring comes after every posting job, because its window rules read the day the batch
// just finished writing
assert (Batch.jobRank(#accrual) == 1);
assert (Batch.jobRank(#tillCheck) == 9);
assert (Batch.jobRank(#monitoring) == 10);
assert (Batch.jobRank(#offerExpiry) == 11);
assert (Batch.jobRank(#facilities) == 12);
assert (Batch.jobRank(#trade) == 13);
assert (Batch.jobRank(#sharia) == 14);
assert (Batch.jobRank(#treasury) == 15);
assert (Batch.jobRank(#cards) == 16);
assert (Batch.jobRank(#charges) > Batch.jobRank(#accrual));
assert (Batch.jobRank(#ageing) > Batch.jobRank(#instalmentsDue));
assert (Batch.jobRank(#provisioning) > Batch.jobRank(#ageing));
Debug.print("count: job dependency orderings asserted = 8");

// ─── 3. what the plan holds: one item per product per job the product's terms call for, the book's items always ───

// a per-account job's item is a walk of the product's accounts: the classification the run uses
for (i in p128.vals()) {
  let walks = Batch.walksAccounts(i);
  switch (i.job) {
    case (#charges or #instalmentsDue or #ageing or #provisioning or #maturity or #statementCut or #monitoring) assert (walks and i.product.size() > 0);
    case (_) assert (not walks);
  };
};
var coverageChecks = 0;
func expectCount(items : [Batch.PlanItem], job : Batch.Job, want : Nat) {
  let got = countJob(items, job);
  if (got != want) { Debug.print("job " # Batch.jobText(job) # ": " # Nat.toText(got) # " items, wanted " # Nat.toText(want)); assert false };
  coverageChecks += 1;
};
expectCount(p128, #accrual, 4);          // every product accrues
expectCount(p128, #charges, 2);          // CUR and LOAN carry charges
expectCount(p128, #instalmentsDue, 1);   // the loan
expectCount(p128, #ageing, 1);
expectCount(p128, #provisioning, 1);
expectCount(p128, #maturity, 1);         // the term deposit
expectCount(p128, #standingInstructions, 1);   // the book's, always
expectCount(p128, #statementCut, 4);     // every product
expectCount(p128, #tillCheck, 1);        // the book's, always
expectCount(p128, #monitoring, 4);       // every product, rule or no rule
expectCount(p128, #offerExpiry, 1);      // the book's, always
for (job in ([#facilities, #trade, #sharia, #treasury, #cards] : [Batch.Job]).vals()) expectCount(p128, job, 0);
// the domain items follow the features active when the run opened, one each
let withDomains = switch (Batch.plan({ input(128) with domains = allDomains })) { case (#ok(xs)) xs; case (#err(_)) { assert false; [] } };
for (job in ([#facilities, #trade, #sharia, #treasury, #cards] : [Batch.Job]).vals()) expectCount(withDomains, job, 1);
assert (withDomains.size() == p128.size() + 5 and Batch.inJobOrder(withDomains));
let onlyTreasury = switch (Batch.plan({ input(128) with domains = { noDomains with treasury = true } })) { case (#ok(xs)) xs; case (#err(_)) { assert false; [] } };
expectCount(onlyTreasury, #treasury, 1); expectCount(onlyTreasury, #cards, 0);
Debug.print("count: per-job item counts asserted = " # Nat.toText(coverageChecks));

// a redenomination puts its per-product walks and its completion item first
let rdPlan = switch (Batch.plan({ input(128) with redenominations = [{ from = "USD"; to = "USN"; products = ["SAVUSD"] }] })) { case (#ok(xs)) xs; case (#err(_)) { assert false; [] } };
assert (rdPlan[0].job == #redenomination and Text.equal(rdPlan[0].product, "SAVUSD") and Batch.walksAccounts(rdPlan[0]));
assert (rdPlan[1].job == #redenomination and rdPlan[1].product.size() == 0 and not Batch.walksAccounts(rdPlan[1]) and Text.equal(rdPlan[1].currency, "USD"));
assert (rdPlan.size() == p128.size() + 2 and Batch.inJobOrder(rdPlan));
Debug.print("count: redenomination items planned first = 2");

// ─── 4. refusals and the empty portfolio ─────────────────────────────────────

var planRefusals = 0;
for (bad in [0, Batch.MAX_SHARD_SIZE + 1].vals()) {
  switch (Batch.plan(input(bad))) {
    case (#ok(_)) assert false;
    case (#err(#invalidShardSize(d))) { assert (d.shardSize == bad); planRefusals += 1 };
    case (#err(_)) assert false;
  };
};
// a registry so large the plan would exceed its bound is refused, not truncated
let huge = Array.tabulate<{ product : Text; currency : JT.Currency; accrues : Bool; credit : Bool; term : Bool; charges : Bool }>(Batch.MAX_PLAN_ITEMS / 3, func(i) { product("P" # Nat.toText(i), "EGP", true, true, true, true) });
switch (Batch.plan({ products = huge; domains = noDomains; redenominations = []; shardSize = 128 })) {
  case (#ok(_)) assert false;
  case (#err(#planTooLarge(d))) { assert (d.items > Batch.MAX_PLAN_ITEMS); planRefusals += 1 };
  case (#err(_)) assert false;
};
Debug.print("count: plans refused = " # Nat.toText(planRefusals));

// no products and no domains: the book's three items and nothing else
switch (Batch.plan({ products = []; domains = noDomains; redenominations = []; shardSize = 128 })) {
  case (#ok(items)) { assert (items.size() == 3); assert (items[0].job == #standingInstructions and items[1].job == #tillCheck and items[2].job == #offerExpiry) };
  case (#err(_)) assert false;
};
// a product whose terms call for nothing beyond the statement cut and monitoring
switch (Batch.plan({ products = [product("PLAIN", "EGP", false, false, false, false)]; domains = noDomains; redenominations = []; shardSize = 128 })) {
  case (#ok(items)) { assert (items.size() == 5); assert (countJob(items, #statementCut) == 1 and countJob(items, #monitoring) == 1 and countJob(items, #accrual) == 0) };
  case (#err(_)) assert false;
};
Debug.print("count: empty-portfolio plans verified = 2");

// ─── 5. a standing instruction's recurrence ─────────────────────────────────

let si : BT.StandingInstruction = {
  id = "rent"; book = "BR01"; from = 10; to = 11; amount = 5_000_00; currency = "EGP";
  everyDays = 30; startDay = 20697; endDay = ?20937; narration = "monthly rent";
};
var dueChecks = 0;
for ((day, want) in [
  (20696, false),          // before it starts
  (20697, true),           // the first occurrence
  (20698, false),
  (20727, true),           // thirty days later
  (20937, true),           // the last day it runs
  (20967, false),          // after it ends
].vals()) {
  if (BT.dueOn(si, day) != want) {
    Debug.print("instruction due on day " # Nat.toText(day) # ": wanted " # debug_show (want));
    assert false;
  };
  dueChecks += 1;
};
Debug.print("count: standing instruction due dates verified = " # Nat.toText(dueChecks));
assert (dueChecks == 6);
// an instruction with no end runs for ever, and one with a zero recurrence never runs
assert (BT.dueOn({ si with endDay = null }, 99_999 ) == ((99_999 - si.startDay) % 30 == 0));
assert (not BT.dueOn({ si with everyDays = 0 }, si.startDay));
Debug.print("count: recurrence edge cases verified = 2");

// ─── 6. the retry policy and the run states ─────────────────────────────────

assert (Batch.validateRetry({ book = "HQ"; limit = 0 }) == null);
assert (Batch.validateRetry({ book = "HQ"; limit = 16 }) == null);
assert (Batch.validateRetry({ book = "HQ"; limit = 17 }) != null);
assert (Batch.DEFAULT_RETRY_LIMIT > 0);
Debug.print("count: retry policies validated = 3");

var stateTexts = 0;
for (st in ([#open, #running, #completed, #failed("a reason")] : [Batch.RunState]).vals()) {
  assert (Text.encodeUtf8(Batch.runStateText(st)).size() > 0);
  stateTexts += 1;
};
assert (Text.contains(Batch.runStateText(#failed("a reason")), #text "a reason"));
Debug.print("count: run states named = " # Nat.toText(stateTexts));

Debug.print("BATCH PLAN TEST GREEN");
