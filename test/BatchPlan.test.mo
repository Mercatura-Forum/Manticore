// BatchPlan.test.mo — the end-of-day plan, as arithmetic.
//
// The plan is what makes the batch safe to chunk, so it is proved on its own terms
// before any of it is run:
//
//   * the same inputs always give the same plan, and the plan's hash is a function of
//     the plan alone — which is what lets a chunk re-derive it and check that the work
//     it is about to do is the work the opening block declared;
//   * the jobs come out in their declared order, because they have real dependencies: a
//     percent-of-interest charge reads job 1's accrual, a band reads job 3's result, a
//     provision reads job 4's band;
//   * **the shard size changes the number of items and never the set of entities**,
//     which is criterion E1's arithmetic half: at sizes 1, 7 and 1,000 the entity count
//     and the per-job coverage are identical;
//   * a standing instruction's recurrence is computable from its record alone;
//   * the retry policy and the run-state vocabulary say what they mean.
//
// engine: wasi-only — the journal core now keeps its per-posting state in a stable-memory Region, and
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

func product(id : Text, ccy : Text, accounts : Nat, accrues : Bool, credit : Bool, term : Bool, charges : Bool)
  : { product : Text; currency : JT.Currency; accounts : Nat; accrues : Bool; credit : Bool; term : Bool; charges : Bool } {
  { product = id; currency = ccy; accounts; accrues; credit; term; charges }
};

let portfolio = [
  product("CUR", "EGP", 137, true, false, false, true),    // a current account with charges
  product("FD", "EGP", 41, true, false, true, false),      // a term deposit
  product("LOAN", "EGP", 89, true, true, false, true),     // a loan with a penalty charge
  product("SAVUSD", "USD", 23, true, false, false, false), // a second currency
];

func input(shardSize : Nat) : Batch.Input {
  { products = portfolio; instructions = 17; tills = 3; monitoringRules = 2; offers = 0; facilities = 0; trade = 0; sharia = 0; shardSize }
};

func planOf(shardSize : Nat) : [Batch.PlanItem] {
  switch (Batch.plan(input(shardSize))) {
    case (#ok(items)) items;
    case (#err(e)) { Debug.print("plan failed: " # debug_show (e)); assert false; [] };
  }
};

// ─── 1. the plan is deterministic, and its hash is a function of it ──────────

let p128 = planOf(128);
let p128again = planOf(128);
assert (p128.size() == p128again.size());
assert (Batch.planHash(p128) == Batch.planHash(p128again));
assert (Batch.planHash(p128).size() == 32);
Debug.print("count: plan items at the default shard size = " # Nat.toText(p128.size()));

// a different shard size is a different plan, and says so
let p7 = planOf(7);
assert (Batch.planHash(p7) != Batch.planHash(p128));
Debug.print("count: plan items at shard size 7 = " # Nat.toText(p7.size()));

// and the hash is sensitive to every field of every item
var hashChecks = 0;
let base = p128[p128.size() - 1];
for (mutation in ([
  { base with from = base.from + 1 },
  { base with to = base.to + 1 },
  { base with product = base.product # "x" },
  { base with currency = "KWD" },
  { base with job = #accrual },
] : [Batch.PlanItem]).vals()) {
  let mutated = Array.tabulate<Batch.PlanItem>(p128.size(), func(i) { if (i == p128.size() - 1) mutation else p128[i] });
  if (Batch.planHash(mutated) == Batch.planHash(p128)) {
    Debug.print("a mutated plan hashed the same");
    assert false;
  };
  hashChecks += 1;
};
Debug.print("count: single-field plan mutations that changed the hash = " # Nat.toText(hashChecks));
assert (hashChecks == 5);

// ─── 2. the jobs come out in their declared order ───────────────────────────

for (shardSize in [1, 7, 128, 1_000].vals()) {
  let items = planOf(shardSize);
  if (not Batch.inJobOrder(items)) { Debug.print("the plan is out of job order at shard size " # Nat.toText(shardSize)); assert false };
};
Debug.print("count: shard sizes whose plan is in job order = 4");

// the ten jobs are a total order with no gaps, and each has a name
var rank = 1;
for (j in Batch.jobs().vals()) {
  assert (Batch.jobRank(j) == rank);
  assert (Text.encodeUtf8(Batch.jobText(j)).size() > 0);
  rank += 1;
};
Debug.print("count: jobs in the declared order = " # Nat.toText(Batch.jobs().size()));
assert (Batch.jobs().size() == 14);

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
assert (Batch.jobRank(#charges) > Batch.jobRank(#accrual));
assert (Batch.jobRank(#ageing) > Batch.jobRank(#instalmentsDue));
assert (Batch.jobRank(#provisioning) > Batch.jobRank(#ageing));
Debug.print("count: job dependency orderings asserted = 8");

// ─── 3. E1's arithmetic half: the shard size changes items, not entities ────

let sizes = [1, 7, 128, 1_000];
let entityCounts = List.empty<Nat>();
let itemCounts = List.empty<Nat>();
for (shardSize in sizes.vals()) {
  let items = planOf(shardSize);
  List.add(entityCounts, Batch.entityCount(items));
  List.add(itemCounts, items.size());
};
let entities = List.toArray(entityCounts);
let counts = List.toArray(itemCounts);
Debug.print("entities at shard sizes " # debug_show (sizes) # " = " # debug_show (entities));
Debug.print("items at the same sizes = " # debug_show (counts));
var i = 1;
while (i < entities.size()) {
  if (entities[i] != entities[0]) { Debug.print("the entity count changed with the shard size"); assert false };
  i += 1;
};
// and the item count really does change, so the comparison is not vacuous
assert (counts[0] != counts[counts.size() - 1]);
assert (counts[0] > counts[counts.size() - 1]);
Debug.print("count: shard sizes covering an identical entity set = " # Nat.toText(sizes.size()));

// the coverage per job is identical too, not only the total
func coverage(items : [Batch.PlanItem], job : Batch.Job) : Nat {
  var n = 0;
  for (it in items.vals()) {
    if (Batch.jobRank(it.job) == Batch.jobRank(job)) {
      if (Batch.itemIsPerProduct(it)) n += 1 else n += it.to - it.from;
    };
  };
  n
};
var jobChecks = 0;
for (job in Batch.jobs().vals()) {
  let want = coverage(planOf(1), job);
  for (shardSize in sizes.vals()) {
    let got = coverage(planOf(shardSize), job);
    if (got != want) {
      Debug.print("job " # Batch.jobText(job) # " covers " # Nat.toText(got) # " at shard " # Nat.toText(shardSize) # " but " # Nat.toText(want) # " at 1");
      assert false;
    };
  };
  jobChecks += 1;
};
Debug.print("count: jobs whose coverage is shard-size independent = " # Nat.toText(jobChecks));
assert (jobChecks == 14);

// the per-account jobs cover exactly the accounts of the products they apply to
let accrualItems = coverage(p128, #accrual);
assert (accrualItems == 4);                        // one per product that accrues
let chargeItems = coverage(p128, #charges);
assert (chargeItems == 137 + 89);                   // the two products with charges
let creditItems = coverage(p128, #instalmentsDue);
assert (creditItems == 89);                         // the loan only
let termItems = coverage(p128, #maturity);
assert (termItems == 41);                           // the term product only
let cutItems = coverage(p128, #statementCut);
assert (cutItems == 137 + 41 + 89 + 23);            // every account
let instructionItems = coverage(p128, #standingInstructions);
assert (instructionItems == 17);
assert (coverage(p128, #tillCheck) == 1);
assert (coverage(p128, #offerExpiry) == 0);         // no offers stand: no expiry item, so a book without origination plans as before
switch (Batch.plan({ products = portfolio; instructions = 17; tills = 3; monitoringRules = 2; offers = 5; facilities = 0; trade = 0; sharia = 0; shardSize = 128 })) {
  case (#ok(withOffers)) { assert (coverage(withOffers, #offerExpiry) == 1); assert (withOffers.size() == p128.size() + 1) };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};
assert (coverage(p128, #facilities) == 0);
switch (Batch.plan({ products = portfolio; instructions = 17; tills = 3; monitoringRules = 2; offers = 0; facilities = 3; trade = 0; sharia = 0; shardSize = 128 })) {
  case (#ok(withFacilities)) { assert (coverage(withFacilities, #facilities) == 1); assert (withFacilities.size() == p128.size() + 1) };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};
assert (coverage(p128, #trade) == 0);
switch (Batch.plan({ products = portfolio; instructions = 17; tills = 3; monitoringRules = 2; offers = 0; facilities = 0; trade = 4; sharia = 0; shardSize = 128 })) {
  case (#ok(withTrade)) { assert (coverage(withTrade, #trade) == 1); assert (withTrade.size() == p128.size() + 1) };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};
assert (coverage(p128, #sharia) == 0);
switch (Batch.plan({ products = portfolio; instructions = 17; tills = 3; monitoringRules = 2; offers = 0; facilities = 0; trade = 0; sharia = 2; shardSize = 128 })) {
  case (#ok(withSharia)) { assert (coverage(withSharia, #sharia) == 1); assert (withSharia.size() == p128.size() + 1) };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};
Debug.print("count: per-job coverage figures asserted = 15");

// ─── 4. what a plan refuses ─────────────────────────────────────────────────

var planRefusals = 0;
for (bad in [0, Batch.MAX_SHARD_SIZE + 1].vals()) {
  switch (Batch.plan(input(bad))) {
    case (#err(#invalidShardSize(d))) { assert (d.shardSize == bad); planRefusals += 1 };
    case (other) { Debug.print(debug_show (other)); assert false };
  };
};
// a portfolio large enough to exceed the item bound at shard size 1
let huge = Array.tabulate<{ product : Text; currency : JT.Currency; accounts : Nat; accrues : Bool; credit : Bool; term : Bool; charges : Bool }>(
  30, func(k) { product("P" # Nat.toText(k), "EGP", 1_000, true, true, true, true) });
switch (Batch.plan({ products = huge; instructions = 0; tills = 0; monitoringRules = 0; offers = 0; facilities = 0; trade = 0; sharia = 0; shardSize = 1 })) {
  case (#err(#planTooLarge(d))) { assert (d.items > Batch.MAX_PLAN_ITEMS); planRefusals += 1 };
  case (other) { Debug.print(debug_show (other)); assert false };
};
Debug.print("count: plans refused = " # Nat.toText(planRefusals));
assert (planRefusals == 3);

// an empty portfolio plans nothing at all, rather than an empty shard nobody notices
switch (Batch.plan({ products = []; instructions = 0; tills = 0; monitoringRules = 0; offers = 0; facilities = 0; trade = 0; sharia = 0; shardSize = 128 })) {
  case (#ok(items)) { assert (items.size() == 0); assert (Batch.entityCount(items) == 0) };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};
// a product with no accounts contributes no shard, and no accrual item either
switch (Batch.plan({ products = [product("EMPTY", "EGP", 0, true, true, true, true)]; instructions = 0; tills = 0; monitoringRules = 0; offers = 0; facilities = 0; trade = 0; sharia = 0; shardSize = 128 })) {
  case (#ok(items)) { assert (items.size() == 0) };
  case (#err(e)) { Debug.print(debug_show (e)); assert false };
};
Debug.print("count: empty-portfolio plans verified = 2");

// shards partition their product's accounts exactly: no gap, no overlap
var partitions = 0;
for (shardSize in sizes.vals()) {
  let items = planOf(shardSize);
  for (job in Batch.jobs().vals()) {
    for (p in portfolio.vals()) {
      let mine = List.empty<Batch.PlanItem>();
      for (it in items.vals()) {
        if (Batch.jobRank(it.job) == Batch.jobRank(job) and Text.equal(it.product, p.product) and not Batch.itemIsPerProduct(it)) {
          List.add(mine, it);
        };
      };
      let arr = List.toArray(mine);
      if (arr.size() > 0) {
        // positions are 1-based and the range is half-open, so the first shard starts
        // at 1, each one starts where the last ended, and the last ends one past the
        // highest account: no gap and no overlap, whatever the shard size
        assert (arr[0].from == 1);
        var k = 1;
        while (k < arr.size()) {
          assert (arr[k].from == arr[k - 1].to);
          assert (arr[k].to > arr[k].from);
          k += 1;
        };
        assert (arr[arr.size() - 1].to == p.accounts + 1);
        partitions += 1;
      };
    };
  };
};
Debug.print("count: shard partitions verified = " # Nat.toText(partitions));
assert (partitions > 0);

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
