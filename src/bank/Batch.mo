/// Batch.mo — the end-of-day run's plan, as pure arithmetic.
///
/// A canister message has a bounded instruction budget, so a run over a portfolio of
/// any size cannot be one message. The moment it is chunked, three failure modes open
/// that a conventional core does not have, and each is closed here by construction
/// rather than by operational care.
///
/// **The inputs cannot move.** A run is keyed on a business date, and its inputs are
/// the journal's value-dated balances at that date — immutable once the date has
/// passed, unless a posting is back-valued into it. So while a run for a date is open
/// the bank layer refuses any posting value-dated on or before it. The book for the
/// date is closed to new history for the duration of the run, which is what "close of
/// business" has always meant. The alternative — letting back-valued postings land and
/// partially recomputing an in-flight run — makes the output a function of arrival
/// order, which is the class of bug that is invisible in testing and expensive in
/// production.
///
/// **The plan is fixed before the work.** It is computed once when the run opens, and
/// the opening block carries its canonical hash and its item count. A plan is a pure
/// function of (book, business date, the product registry, the accounts that existed
/// when it opened), which is what makes "the same date at chunk sizes 1, 7 and 1,000
/// gives the same result" a property rather than a coincidence. Accounts opened after
/// the run are excluded by the recorded `maxAccount` bound rather than by hoping the
/// iteration order is stable.
///
/// **A failing item cannot stop the queue.** An item that fails is recorded with its
/// typed error and the cursor advances past it. Failures accumulate in a bounded
/// per-run list with a declared retry policy, and a parked failure is loud: a period
/// cannot close while a run inside it has unresolved failures. So a permanently
/// failing item stops the period close, which a human sees, instead of stopping the
/// batch, which nobody sees.

import Nat "mo:core/Nat";
import Text "mo:core/Text";
import List "mo:core/List";
import Blob "mo:core/Blob";
import Sha256 "mo:sha2/Sha256";

import JT "mo:journal/JournalTypes";
import JC "mo:journal/Canonical";

module {

  public type Day = JT.Day;

  /// The nine jobs, in the order the plan runs them. The order is part of the plan and
  /// is not configurable, because these jobs have real dependencies: a
  /// percent-of-interest charge reads job 1's accrual, a delinquency band reads job
  /// 3's result, a provision reads job 4's band.
  public type Job = {
    #accrual;                 // 1: one aggregate posting per (product, currency)
    #charges;                 // 2: charges whose due date is the business date
    #instalmentsDue;          // 3: instalments falling due move into the receivable
    #ageing;                  // 4: arrears recomputed and the delinquency band recorded
    #provisioning;            // 5: the allowance movement from the declared parameters
    #maturity;                // 6: term deposits maturing on the date
    #standingInstructions;    // 7: recurring transfers due on the date
    #statementCut;            // 8: the per-account statement data for the date
    #tillCheck;               // 9: a till left unsettled at close is a failure
    #monitoring;              // 10: the window rules over the day's active accounts, as alerts
    #offerExpiry;             // 11: credit offers whose validity ended lapse (origination and underwriting)
    #facilities;              // 12: commitment fees, lease income, discount unwind, clean-downs, resets, reviews (corporate lending)
  };

  public func jobs() : [Job] {
    [#accrual, #charges, #instalmentsDue, #ageing, #provisioning, #maturity,
     #standingInstructions, #statementCut, #tillCheck, #monitoring, #offerExpiry, #facilities]
  };

  public func jobText(j : Job) : Text {
    switch (j) {
      case (#accrual) "accrual"; case (#charges) "charges";
      case (#instalmentsDue) "instalmentsDue"; case (#ageing) "ageing";
      case (#provisioning) "provisioning"; case (#maturity) "maturity";
      case (#standingInstructions) "standingInstructions";
      case (#statementCut) "statementCut"; case (#tillCheck) "tillCheck";
      case (#monitoring) "monitoring"; case (#offerExpiry) "offerExpiry"; case (#facilities) "facilities";
    }
  };

  public func jobRank(j : Job) : Nat {
    switch (j) {
      case (#accrual) 1; case (#charges) 2; case (#instalmentsDue) 3; case (#ageing) 4;
      case (#provisioning) 5; case (#maturity) 6; case (#standingInstructions) 7;
      case (#statementCut) 8; case (#tillCheck) 9; case (#monitoring) 10; case (#offerExpiry) 11; case (#facilities) 12;
    }
  };

  /// One unit of work. A per-account job's item covers a half-open range of positions
  /// in the product's own ordered account list; a per-product job's item covers the
  /// product as a whole and carries an empty range.
  ///
  /// Ranges are positions rather than account identifiers because a position range is
  /// what a shard size divides evenly, and the list is ordered by identifier and
  /// bounded above by the run's recorded `maxAccount`, so the prefix a position names
  /// cannot move under the cursor.
  public type PlanItem = {
    job : Job;
    /// The product the item works on; empty for a job that is not per product.
    product : Text;
    currency : JT.Currency;
    from : Nat;
    to : Nat;
  };

  public func itemIsPerProduct(i : PlanItem) : Bool { i.from == 0 and i.to == 0 };

  /// The money-visible feature a job's postings belong to, if it posts at all. A run
  /// cannot open unless every one of these is past its activation height, which is why
  /// no job has to check a gate while it works: the run could not exist otherwise.
  public func featureOf(j : Job) : ?Text {
    switch (j) {
      case (#accrual) ?"product.interest";
      case (#charges) ?"product.charges";
      case (#instalmentsDue) ?"product.credit";
      case (#ageing) null;                        // records a band; posts nothing
      case (#provisioning) ?"product.credit";
      case (#maturity) ?"product.interest";
      case (#standingInstructions) ?"product.account.money";
      case (#statementCut) null;                  // records a cut; posts nothing
      case (#tillCheck) ?"product.till";
      case (#monitoring) null;                    // records alerts; posts nothing
      case (#offerExpiry) null;                   // records lapses; posts nothing
      case (#facilities) ?"product.credit";       // fees, rentals and discounts on the credit book
    }
  };

  public let DEFAULT_SHARD_SIZE : Nat = 128;
  public let MAX_SHARD_SIZE : Nat = 4096;
  public let MAX_PLAN_ITEMS : Nat = 20_000;
  public let MAX_FAILURES : Nat = 512;
  public let DEFAULT_RETRY_LIMIT : Nat = 3;
  public let MAX_ADVANCE_LIMIT : Nat = 64;

  public type Fault = {
    #invalidShardSize : { shardSize : Nat };
    #planTooLarge : { items : Nat };
  };

  /// What a plan is built from. Passed in rather than read here, so the plan is a
  /// function of its inputs and a test can build one without a journal.
  public type Input = {
    /// (product id, currency, the number of accounts at or below `maxAccount`,
    /// whether the product accrues interest, whether it is a credit product,
    /// whether it is a term product, whether it has charges).
    products : [{
      product : Text;
      currency : JT.Currency;
      accounts : Nat;
      accrues : Bool;
      credit : Bool;
      term : Bool;
      charges : Bool;
    }];
    /// How many standing instructions exist for the book.
    instructions : Nat;
    /// How many tills the book has open.
    tills : Nat;
    /// How many monitoring rules run at end of day. None, and the plan has no monitoring items,
    /// so a book that declared no rules plans exactly as before.
    monitoringRules : Nat;
    /// How many credit offers stand open in the book. None, and the plan has no expiry item.
    offers : Nat;
    /// How many facilities of the book are not closed. None, and the plan has no facilities item.
    facilities : Nat;
    shardSize : Nat;
  };

  func shardsOf(items : List.List<PlanItem>, job : Job, product : Text, currency : JT.Currency, accounts : Nat, shardSize : Nat) {
    if (accounts == 0) return;
    var from = 0;
    while (from < accounts) {
      let to = if (from + shardSize < accounts) from + shardSize else accounts;
      // a per-account shard always has a non-empty range, so it is never mistaken for
      // a per-product item
      List.add(items, { job; product; currency; from = from + 1; to = to + 1 });
      from := to;
    };
  };

  /// Build the plan. Deterministic in its input and in the order of `products`, which
  /// the caller supplies sorted.
  public func plan(input : Input) : { #ok : [PlanItem]; #err : Fault } {
    if (input.shardSize == 0 or input.shardSize > MAX_SHARD_SIZE) {
      return #err(#invalidShardSize({ shardSize = input.shardSize }));
    };
    let items = List.empty<PlanItem>();
    // 1. accrual: one item per product and currency that accrues
    for (p in input.products.vals()) {
      if (p.accrues and p.accounts > 0) {
        List.add(items, { job = #accrual; product = p.product; currency = p.currency; from = 0; to = 0 });
      };
    };
    // 2. charges, per account, for products that declare any
    for (p in input.products.vals()) {
      if (p.charges) shardsOf(items, #charges, p.product, p.currency, p.accounts, input.shardSize);
    };
    // 3, 4, 5. the credit jobs, per account
    for (job in ([#instalmentsDue, #ageing, #provisioning] : [Job]).vals()) {
      for (p in input.products.vals()) {
        if (p.credit) shardsOf(items, job, p.product, p.currency, p.accounts, input.shardSize);
      };
    };
    // 6. maturity, per account, for term products
    for (p in input.products.vals()) {
      if (p.term) shardsOf(items, #maturity, p.product, p.currency, p.accounts, input.shardSize);
    };
    // 7. standing instructions, sharded over the instruction list
    if (input.instructions > 0) {
      var from = 0;
      while (from < input.instructions) {
        let to = if (from + input.shardSize < input.instructions) from + input.shardSize else input.instructions;
        List.add(items, { job = #standingInstructions; product = ""; currency = ""; from = from + 1; to = to + 1 });
        from := to;
      };
    };
    // 8. the statement cut, per account, for every product
    for (p in input.products.vals()) {
      shardsOf(items, #statementCut, p.product, p.currency, p.accounts, input.shardSize);
    };
    // 9. the till check, one item for the book
    if (input.tills > 0) {
      List.add(items, { job = #tillCheck; product = ""; currency = ""; from = 0; to = 0 });
    };
    // 10. monitoring, per account, for every product, after every posting job has landed — the
    // window rules read the day the batch just finished writing. An account with no activity on
    // the date costs the job one row read and nothing else.
    if (input.monitoringRules > 0) {
      for (p in input.products.vals()) {
        shardsOf(items, #monitoring, p.product, p.currency, p.accounts, input.shardSize);
      };
    };
    // 11. offer expiry, one item for the book, only while offers stand open
    if (input.offers > 0) {
      List.add(items, { job = #offerExpiry; product = ""; currency = ""; from = 0; to = 0 });
    };
    // 12. the facilities, one item for the book while any stands open
    if (input.facilities > 0) {
      List.add(items, { job = #facilities; product = ""; currency = ""; from = 0; to = 0 });
    };
    if (List.size(items) > MAX_PLAN_ITEMS) return #err(#planTooLarge({ items = List.size(items) }));
    #ok(List.toArray(items))
  };

  /// The plan's canonical bytes, and its hash. The opening block carries the hash and
  /// the item count, so a reader can re-derive the plan from the recorded inputs and
  /// check that the work done was the work declared.
  public func planBytes(items : [PlanItem]) : Blob {
    let w = JC.Writer();
    w.text("thebes.bank.eod.plan.v1");
    w.nat(items.size());
    for (i in items.vals()) {
      w.nat(jobRank(i.job));
      w.text(i.product);
      w.text(i.currency);
      w.nat(i.from);
      w.nat(i.to);
    };
    Blob.fromArray(w.toArray())
  };

  public func planHash(items : [PlanItem]) : Blob { Sha256.fromBlob(#sha256, planBytes(items)) };

  /// Are the items in job order, with no job appearing before one that must precede
  /// it? Asserted rather than assumed, because the dependencies are the reason the
  /// order is not configurable.
  public func inJobOrder(items : [PlanItem]) : Bool {
    var previous = 0;
    for (i in items.vals()) {
      let r = jobRank(i.job);
      if (r < previous) return false;
      previous := r;
    };
    true
  };

  /// How many entities a plan **names**: a product for the aggregate accrual, one
  /// account for each position of a per-account shard, one instruction, one till check.
  ///
  /// This is not the same number as a run's `examined` total and is not meant to be.
  /// The aggregate accrual names one entity — the product — and examines every account
  /// of it, and the till check names one entity and examines every open till of the
  /// book. So `examined` is at least `entities` and usually more. What both figures are
  /// is **independent of the shard size**, which is the property chunking has to have.
  public func entityCount(items : [PlanItem]) : Nat {
    var n = 0;
    for (i in items.vals()) {
      if (itemIsPerProduct(i)) n += 1 else n += i.to - i.from;
    };
    n
  };

  /// The retry policy, declared as data. An item that fails is retried on the next
  /// run up to `limit` times and then parks; a parked failure blocks the period close.
  public type RetryPolicy = { book : Text; limit : Nat };

  public func validateRetry(p : RetryPolicy) : ?Text {
    if (p.limit > 16) return ?"a retry limit above sixteen is a queue nobody is watching";
    null
  };

  public type RunState = { #open; #running; #completed; #failed : Text };

  public func runStateText(s : RunState) : Text {
    switch (s) {
      case (#open) "open"; case (#running) "running"; case (#completed) "completed";
      case (#failed(r)) "failed: " # r;
    }
  };

  /// A failure, recorded with the item it came from and the typed error's own text so
  /// a reader can see what went wrong without replaying the whole run.
  public type Failure = { item : Nat; job : Job; entity : Text; error : Text; attempts : Nat };
};
