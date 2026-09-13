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
import Array "mo:core/Array";
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
    #trade;                   // 13: trade commissions and discounts earned, expiries, reductions, maturities (trade finance)
    #sharia;                  // 14: Murabaha profit and late-payment charity, Ijarah rentals and depreciation (Islamic banking)
    #treasury;                // 15: deal accruals, coupons, marks against the day's curves, legs falling due, break aging, overdue confirmations (treasury)
    #cards;                   // 16: holds expired by the scheme's window, dispute steps due, statement cycles cut (cards)
    #redenomination;          // 17: a declared redenomination carried out — the products re-versioned, every balance re-expressed, the currency closed (S4.1)
  };

  public func jobs() : [Job] {
    [#accrual, #charges, #instalmentsDue, #ageing, #provisioning, #maturity,
     #standingInstructions, #statementCut, #tillCheck, #monitoring, #offerExpiry, #facilities, #trade, #sharia, #treasury, #cards, #redenomination]
  };

  public func jobText(j : Job) : Text {
    switch (j) {
      case (#accrual) "accrual"; case (#charges) "charges";
      case (#instalmentsDue) "instalmentsDue"; case (#ageing) "ageing";
      case (#provisioning) "provisioning"; case (#maturity) "maturity";
      case (#standingInstructions) "standingInstructions";
      case (#statementCut) "statementCut"; case (#tillCheck) "tillCheck";
      case (#monitoring) "monitoring"; case (#offerExpiry) "offerExpiry"; case (#facilities) "facilities"; case (#trade) "trade"; case (#sharia) "sharia"; case (#treasury) "treasury"; case (#cards) "cards"; case (#redenomination) "redenomination";
    }
  };

  public func jobRank(j : Job) : Nat {
    switch (j) {
      case (#accrual) 1; case (#charges) 2; case (#instalmentsDue) 3; case (#ageing) 4;
      case (#provisioning) 5; case (#maturity) 6; case (#standingInstructions) 7;
      case (#statementCut) 8; case (#tillCheck) 9; case (#monitoring) 10; case (#offerExpiry) 11; case (#facilities) 12; case (#trade) 13; case (#sharia) 14; case (#treasury) 15; case (#cards) 16; case (#redenomination) 17;
    }
  };

  /// Where a job's items stand in the plan. The rank is the job's name in every encoding and never changes; the
  /// position is the order of the day's work. They differ once: a redenomination re-expresses every balance of its
  /// currency **before** the day's accrual, charges and statements, so those run in the new currency on the
  /// converted balances — its rank names it (17), its position is first (0).
  public func jobPosition(j : Job) : Nat { switch (j) { case (#redenomination) 0; case (other) jobRank(other) } };

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
      case (#trade) ?"product.credit";            // the trade book is part of the credit book: commissions, discounts, expiries, maturities
      case (#sharia) ?"product.credit";           // the Sharia book likewise: profit recognised, rentals, depreciation, charity
      case (#treasury) ?"close.fx";             // the treasury book moves money across currencies: accruals, marks, settlements
      case (#cards) ?"product.account.money";    // expired holds release the customer's funds; a statement cut records
      case (#redenomination) ?"close.fx";        // every balance of the currency re-expressed through the bridge: cross-currency postings
    }
  };

  public let DEFAULT_SHARD_SIZE : Nat = 128;
  public let MAX_SHARD_SIZE : Nat = 4096;
  public let MAX_PLAN_ITEMS : Nat = 20_000;
  public let MAX_FAILURES : Nat = 512;
  public let DEFAULT_RETRY_LIMIT : Nat = 3;
  public let MAX_ADVANCE_LIMIT : Nat = 64;
  /// How many of a book's deals the treasury job walks in one chunk, and how many open breaks: the item is a
  /// walk of its own, resumed from a recorded cursor, so its cost per message is bounded whatever the book holds.
  public let ROWS_PER_CHUNK : Nat = 64;
  public let ALERTS_PER_CHUNK : Nat = 256;
  public let TREASURY_DEALS_PER_CHUNK : Nat = ROWS_PER_CHUNK;
  public let TREASURY_BREAKS_PER_CHUNK : Nat = ALERTS_PER_CHUNK;

  public type Fault = {
    #invalidShardSize : { shardSize : Nat };
    #planTooLarge : { items : Nat };
  };

  /// What a plan is built from. Passed in rather than read here, so the plan is a
  /// function of its inputs and a test can build one without a journal.
  /// What the plan is a function of — and nothing else. Every field is fixed for the life of a run: the
  /// products are the registry as it stood at the block that opened the run (a version registered later
  /// waits for the next run), the domain flags are the features active at that block, the redenominations
  /// are those declared for the date. Nothing here counts rows: an item over a product, a book's
  /// instructions, tills, offers, facilities, instruments, contracts, deals or cards is in the plan whether
  /// the book holds one of them or none — an item over nothing examines nothing — so no account opening,
  /// closing, capture, settlement or definition during the run can change the plan's hash and leave the
  /// run unadvanceable (the adversarial audit of 13 September, finding B1).
  public type Input = {
    products : [{
      product : Text;
      currency : JT.Currency;
      accrues : Bool;
      credit : Bool;
      term : Bool;
      charges : Bool;
    }];
    /// the domains whose feature is active at the run's opening block
    domains : { facilities : Bool; trade : Bool; sharia : Bool; treasury : Bool; cards : Bool };
    redenominations : [{ from : JT.Currency; to : JT.Currency; products : [Text] }];
    /// how many entities a per-account, per-instruction, per-offer or per-row item walks in one chunk
    shardSize : Nat;
  };

  func perProduct(items : List.List<PlanItem>, job : Job, product : Text, currency : JT.Currency) {
    List.add(items, { job; product; currency; from = 0; to = 0 });
  };
  func perBook(items : List.List<PlanItem>, job : Job) {
    List.add(items, { job; product = ""; currency = ""; from = 0; to = 0 });
  };

  public func plan(input : Input) : { #ok : [PlanItem]; #err : Fault } {
    if (input.shardSize == 0 or input.shardSize > MAX_SHARD_SIZE) {
      return #err(#invalidShardSize({ shardSize = input.shardSize }));
    };
    let items = List.empty<PlanItem>();
    // 0. redenomination, first: every account of a product in the currency re-expressed (one walk per product),
    //    then the book's other balances in the currency and the completion (one item per redenomination)
    for (rd in input.redenominations.vals()) {
      for (p in input.products.vals()) {
        if (Array.find<Text>(rd.products, func(id) { Text.equal(id, p.product) }) != null) perProduct(items, #redenomination, p.product, rd.from);
      };
      List.add(items, { job = #redenomination; product = ""; currency = rd.from; from = 0; to = 0 });
    };
    // 1. the accrual, one aggregate item per accruing product
    for (p in input.products.vals()) { if (p.accrues) perProduct(items, #accrual, p.product, p.currency) };
    // 2. charges, a walk of the product's accounts
    for (p in input.products.vals()) { if (p.charges) perProduct(items, #charges, p.product, p.currency) };
    // 3–5. the credit jobs
    for (job in ([#instalmentsDue, #ageing, #provisioning] : [Job]).vals()) {
      for (p in input.products.vals()) { if (p.credit) perProduct(items, job, p.product, p.currency) };
    };
    // 6. maturities
    for (p in input.products.vals()) { if (p.term) perProduct(items, #maturity, p.product, p.currency) };
    // 7. the book's standing instructions, walked
    perBook(items, #standingInstructions);
    // 8. the statement cut, every product
    for (p in input.products.vals()) { perProduct(items, #statementCut, p.product, p.currency) };
    // 9. the tills of the book
    perBook(items, #tillCheck);
    // 10. monitoring, every product
    for (p in input.products.vals()) { perProduct(items, #monitoring, p.product, p.currency) };
    // 11. offers lapsing
    perBook(items, #offerExpiry);
    // 12–16. the domain books, where the domain's feature was active when the run opened
    if (input.domains.facilities) perBook(items, #facilities);
    if (input.domains.trade) perBook(items, #trade);
    if (input.domains.sharia) perBook(items, #sharia);
    if (input.domains.treasury) perBook(items, #treasury);
    if (input.domains.cards) perBook(items, #cards);
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
      let r = jobPosition(i.job);
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
  /// The items that walk one product's accounts: every per-account job's item, and a redenomination's per-product item.
  public func walksAccounts(i : PlanItem) : Bool {
    if (i.product.size() == 0) return false;
    switch (i.job) {
      case (#charges or #instalmentsDue or #ageing or #provisioning or #maturity or #statementCut or #monitoring or #redenomination) true;
      case (_) false;
    }
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
