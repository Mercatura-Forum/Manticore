/// IslamicCore.mo; the Sharia book folded from the bank's log in stable memory (Islamic banking): the contracts, their
/// instalment schedules, the investment-account pools and their distributions, the board approvals and the book
/// flags.
///
/// Rows: one per contract (keyed by the block that opened it) with the fixed facts; kind, stage, our party and
/// account, currency and book, the principal (cost, asset, capital, price advanced, contract price), the profit the
/// contract will earn and the part recognised, what was collected, the days, the counts of instalments, units and
/// the percentage complete, the hash of the terms; one per instalment of a Murabaha or rental of an Ijarah
/// (contract ‖ number); one per pool and one per distribution (pool ‖ period). The arithmetic the AAOIFI standards
/// prescribe is here as pure functions; the proportionate and effective-rate profit of a Murabaha (FAS 28), the
/// straight-line depreciation of an Ijarah asset (FAS 32), the distribution of a Musharakah's profit by the agreed
/// ratio and of its loss by capital (FAS 4), the percentage-of-completion revenue of an Istisna'a (FAS 10), the
/// weighted-average distribution of a pool's income with PER and IRR (FAS 27); so an oracle can reproduce every
/// figure from the standard's text.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";
import JT "mo:journal/JournalTypes";

import IT "IslamicTypes";
import PT "PartyTypes";
import ProdT "ProductTypes";
import Products "Products";
import I "Interest";
import Posting "Posting";
import R "StableRows";
import Map "mo:core/Map";
import Int "mo:core/Int";

module {

  public let CONTRACT_ROW_BYTES : Nat = 183;
  public let INSTALMENT_ROW_BYTES : Nat = 37;
  public let POOL_ROW_BYTES : Nat = 136;
  public let DISTRIBUTION_ROW_BYTES : Nat = 64;
  let MAX_PAGE = 512;

  // ─── keys, codes, sub-ledgers ─────────────────────────────────────────────

  /// The sub-ledger of a contract on every account the contract posts to: one identifier per contract.
  public func contractSub(id : IT.ContractId) : JT.SubledgerKey { Posting.subledgerOf("sharia/" # Nat.toText(id)) };
  /// The sub-ledger of a pool's reserves and payables.
  public func poolSub(pool : IT.PoolId) : JT.SubledgerKey { Posting.subledgerOf("psia/" # pool) };
  public func holdsSubledger(s : State, sub : JT.SubledgerKey) : Bool { sub.size() == 32 and RI.get(s.subledgers, sub) != null };
  func holdSub(s : State, sub : JT.SubledgerKey) { ignore RI.put(s.subledgers, sub, Blob.fromArray([1])) };
  func hashText(t : Text) : Blob { Sha256.fromBlob(#sha256, Text.encodeUtf8(t)) };
  func refKey(reference : Text) : Blob { R.key(R.getNat(Blob.toArray(hashText(reference)), 0, 8), 8) };
  func poolKey(pool : Text) : Blob { R.textKey(pool, 32) };
  func distKey(pool : Text, period : Text) : Blob { Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.textKey(pool, 32)), Blob.toArray(R.textKey(period, 8)))) };

  func kindCode(k : IT.Kind) : Nat8 { switch (k) { case (#murabaha(_)) 1; case (#ijarah(_)) 2; case (#musharakah(_)) 3; case (#mudarabah(_)) 4; case (#salam(_)) 5; case (#istisna(_)) 6 } };
  func kindTextOf(c : Nat8) : Text { switch (c) { case 1 "murabaha"; case 2 "ijarah"; case 3 "musharakah"; case 4 "mudarabah"; case 5 "salam"; case 6 "istisna"; case _ "?" } };
  public func stageCode(s : IT.Stage) : Nat8 { switch (s) { case (#opened) 1; case (#acquired) 2; case (#sold) 3; case (#running) 4; case (#delivered) 5; case (#settled) 6; case (#closed) 7; case (#defaulted) 8 } };
  func stageOf(c : Nat8) : IT.Stage { switch (c) { case 1 #opened; case 2 #acquired; case 3 #sold; case 4 #running; case 5 #delivered; case 6 #settled; case 7 #closed; case _ #defaulted } };
  let F_EFFECTIVE : Nat8 = 1;      // Murabaha profit by the effective rate (else proportionate)
  let F_BINDING : Nat8 = 2;        // Murabaha promise binding
  let F_IMB : Nat8 = 4;            // Ijarah ending in ownership transfer
  let F_DIMINISHING : Nat8 = 8;    // Musharakah with the bank's units sold on a schedule

  // ─── rows ─────────────────────────────────────────────────────────────────

  public type ContractRow = {
    id : IT.ContractId; kind : Nat8; stage : IT.Stage; flags : Nat8;
    party : PT.PartyId; account : ProdT.AccountId; currency : Text; book : Text;
    principal : Nat; profitTotal : Nat; profitRecognised : Nat; collected : Nat;
    openedDay : Nat; nextDue : Nat; instalmentsDue : Nat; instalmentsPaid : Nat; units : Nat; unitsLeft : Nat; percentBps : Nat;
    securityDeposit : Nat; depreciation : Nat; termsHash : Blob; lastBlock : Nat; unitPrice : Nat;
  };
  public type InstalmentRow = { contract : IT.ContractId; number : Nat; dueDate : Nat; amount : Nat; principal : Nat; profit : Nat; paid : Bool; charity : Nat };
  public type PoolRow = { id : IT.PoolId; currency : Text; product : Text; mudaribBps : Nat; perBps : Nat; irrBps : Nat; distributions : Nat; lastPeriod : Text; perBalance : Nat; irrBalance : Nat; incomeAccountsHash : Blob; openedBlock : Nat };
  public type DistributionRow = { pool : IT.PoolId; period : Text; from : Nat; to : Nat; income : Nat; per : Nat; mudaribShare : Nat; holdersShare : Nat; irr : Nat; paid : Nat; block : Nat };

  func encodeContract(r : ContractRow) : Blob {
    let b = R.buf();
    R.putByte(b, r.kind); R.putByte(b, stageCode(r.stage)); R.putByte(b, r.flags);
    R.putNat(b, r.party, 8); R.putNat(b, r.account, 8); R.putText(b, r.currency, 8); R.putText(b, r.book, 32);
    R.putNat(b, r.principal, 8); R.putNat(b, r.profitTotal, 8); R.putNat(b, r.profitRecognised, 8); R.putNat(b, r.collected, 8);
    R.putNat(b, r.openedDay, 4); R.putNat(b, r.nextDue, 4); R.putNat(b, r.instalmentsDue, 4); R.putNat(b, r.instalmentsPaid, 4); R.putNat(b, r.units, 4); R.putNat(b, r.unitsLeft, 4); R.putNat(b, r.percentBps, 4);
    R.putNat(b, r.securityDeposit, 8); R.putNat(b, r.depreciation, 8); R.putBlob(b, r.termsHash, 32); R.putNat(b, r.lastBlock, 8); R.putNat(b, r.unitPrice, 8);
    R.done(b, CONTRACT_ROW_BYTES)
  };
  func decodeContract(id : Nat, v : Blob) : ContractRow {
    let a = Blob.toArray(v);
    {
      id; kind = a[0]; stage = stageOf(a[1]); flags = a[2];
      party = R.getNat(a, 3, 8); account = R.getNat(a, 11, 8); currency = R.getText(a, 19, 8); book = R.getText(a, 27, 32);
      principal = R.getNat(a, 59, 8); profitTotal = R.getNat(a, 67, 8); profitRecognised = R.getNat(a, 75, 8); collected = R.getNat(a, 83, 8);
      openedDay = R.getNat(a, 91, 4); nextDue = R.getNat(a, 95, 4); instalmentsDue = R.getNat(a, 99, 4); instalmentsPaid = R.getNat(a, 103, 4); units = R.getNat(a, 107, 4); unitsLeft = R.getNat(a, 111, 4); percentBps = R.getNat(a, 115, 4);
      securityDeposit = R.getNat(a, 119, 8); depreciation = R.getNat(a, 127, 8); termsHash = R.getBlob(a, 135, 32); lastBlock = R.getNat(a, 167, 8); unitPrice = R.getNat(a, 175, 8);
    }
  };
  func encodeInstalment(r : InstalmentRow) : Blob {
    let b = R.buf();
    R.putNat(b, r.dueDate, 4); R.putNat(b, r.amount, 8); R.putNat(b, r.principal, 8); R.putNat(b, r.profit, 8); R.putBool(b, r.paid); R.putNat(b, r.charity, 8);
    R.done(b, INSTALMENT_ROW_BYTES)
  };
  func decodeInstalment(contract : Nat, number : Nat, v : Blob) : InstalmentRow {
    let a = Blob.toArray(v);
    { contract; number; dueDate = R.getNat(a, 0, 4); amount = R.getNat(a, 4, 8); principal = R.getNat(a, 12, 8); profit = R.getNat(a, 20, 8); paid = R.getBool(a, 28); charity = R.getNat(a, 29, 8) }
  };
  func encodePool(r : PoolRow) : Blob {
    let b = R.buf();
    R.putText(b, r.id, 32); R.putText(b, r.currency, 8); R.putText(b, r.product, 32); R.putNat(b, r.mudaribBps, 4); R.putNat(b, r.perBps, 4); R.putNat(b, r.irrBps, 4);
    R.putNat(b, r.distributions, 4); R.putText(b, r.lastPeriod, 8); R.putNat(b, r.perBalance, 8); R.putNat(b, r.irrBalance, 8); R.putBlob(b, r.incomeAccountsHash, 16); R.putNat(b, r.openedBlock, 8);
    R.done(b, POOL_ROW_BYTES)
  };
  func decodePool(v : Blob) : PoolRow {
    let a = Blob.toArray(v);
    { id = R.getText(a, 0, 32); currency = R.getText(a, 32, 8); product = R.getText(a, 40, 32); mudaribBps = R.getNat(a, 72, 4); perBps = R.getNat(a, 76, 4); irrBps = R.getNat(a, 80, 4);
      distributions = R.getNat(a, 84, 4); lastPeriod = R.getText(a, 88, 8); perBalance = R.getNat(a, 96, 8); irrBalance = R.getNat(a, 104, 8); incomeAccountsHash = R.getBlob(a, 112, 16); openedBlock = R.getNat(a, 128, 8) }
  };
  func encodeDistribution(r : DistributionRow) : Blob {
    let b = R.buf();
    R.putNat(b, r.from, 4); R.putNat(b, r.to, 4); R.putNat(b, r.income, 8); R.putNat(b, r.per, 8); R.putNat(b, r.mudaribShare, 8); R.putNat(b, r.holdersShare, 8); R.putNat(b, r.irr, 8); R.putNat(b, r.paid, 8); R.putNat(b, r.block, 8);
    R.done(b, DISTRIBUTION_ROW_BYTES)
  };
  func decodeDistribution(pool : Text, period : Text, v : Blob) : DistributionRow {
    let a = Blob.toArray(v);
    { pool; period; from = R.getNat(a, 0, 4); to = R.getNat(a, 4, 4); income = R.getNat(a, 8, 8); per = R.getNat(a, 16, 8); mudaribShare = R.getNat(a, 24, 8); holdersShare = R.getNat(a, 32, 8); irr = R.getNat(a, 40, 8); paid = R.getNat(a, 48, 8); block = R.getNat(a, 56, 8) }
  };

  // ─── state ────────────────────────────────────────────────────────────────

  public type State = {
    contracts : RI.State;     // id(8) -> row
    instalments : RI.State;   // contract(8) ‖ number(8) -> row
    pools : RI.State;         // pool(32) -> row
    distributions : RI.State; // pool(32) ‖ period(8) -> row
    byParty : RI.State;       // party(8) ‖ id(8)
    byBook : RI.State;        // book(32) ‖ id(8) -> 0
    byStage : RI.State;       // stage(1) ‖ id(8)
    byReference : RI.State;   // sha(reference)[0..8) -> id(8)
    approvals : RI.State;     // product(32) -> ref(32) ‖ sha256(32)
    shariaBooks : RI.State;   // book(32) -> 1
    subledgers : RI.State;
    var policy : ?IT.Policy;
    var opened : Nat;
    var open : Nat;
    openByCurrency : Map.Map<Text, Nat>;
    openByBook : Map.Map<Text, Nat>;
    var charity : Nat;        // Σ recorded non-compliance and late-payment amounts
    var distributionsTotal : Nat;
  };

  public func newState(arena : RI.Arena) : State {
    {
      contracts = RI.newStateIn(arena, { keyBytes = 8; valBytes = CONTRACT_ROW_BYTES });
      instalments = RI.newStateIn(arena, { keyBytes = 16; valBytes = INSTALMENT_ROW_BYTES });
      pools = RI.newStateIn(arena, { keyBytes = 32; valBytes = POOL_ROW_BYTES });
      distributions = RI.newStateIn(arena, { keyBytes = 40; valBytes = DISTRIBUTION_ROW_BYTES });
      byParty = RI.newStateIn(arena, { keyBytes = 16; valBytes = 1 });
      byBook = RI.newStateIn(arena, { keyBytes = 40; valBytes = 1 });
      byStage = RI.newStateIn(arena, { keyBytes = 9; valBytes = 1 });
      byReference = RI.newStateIn(arena, { keyBytes = 8; valBytes = 8 });
      approvals = RI.newStateIn(arena, { keyBytes = 32; valBytes = 64 });
      shariaBooks = RI.newStateIn(arena, { keyBytes = 32; valBytes = 1 });
      subledgers = RI.newStateIn(arena, { keyBytes = 32; valBytes = 1 });
      openByCurrency = Map.empty<Text, Nat>();
      openByBook = Map.empty<Text, Nat>();
      var policy = null; var opened = 0; var open = 0; var charity = 0; var distributionsTotal = 0;
    }
  };

  public func policy(s : State) : ?IT.Policy { s.policy };
  public func row(s : State, id : IT.ContractId) : ?ContractRow { switch (RI.get(s.contracts, R.key(id, 8))) { case (?v) ?decodeContract(id, v); case null null } };
  public func instalment(s : State, id : IT.ContractId, n : Nat) : ?InstalmentRow { switch (RI.get(s.instalments, R.key2(id, 8, n, 8))) { case (?v) ?decodeInstalment(id, n, v); case null null } };
  public func pool(s : State, id : IT.PoolId) : ?PoolRow { switch (RI.get(s.pools, poolKey(id))) { case (?v) ?decodePool(v); case null null } };
  public func distribution(s : State, pool_ : IT.PoolId, period : Text) : ?DistributionRow { switch (RI.get(s.distributions, distKey(pool_, period))) { case (?v) ?decodeDistribution(pool_, period, v); case null null } };
  public func byReference(s : State, reference : Text) : ?IT.ContractId { switch (RI.get(s.byReference, refKey(reference))) { case (?v) ?R.getNat(Blob.toArray(v), 0, 8); case null null } };
  public func approval(s : State, product : ProdT.ProductId) : ?IT.BoardApproval {
    switch (RI.get(s.approvals, R.textKey(product, 32))) { case (?v) { let a = Blob.toArray(v); ?{ ref = R.getText(a, 0, 32); sha256 = R.getBlob(a, 32, 32) } }; case null null }
  };
  public func isShariaBook(s : State, book : Text) : Bool { if (Text.encodeUtf8(book).size() > 32) return false; switch (RI.get(s.shariaBooks, R.textKey(book, 32))) { case (?v) Blob.toArray(v)[0] == 1; case null false } };
  func putRow(s : State, r : ContractRow) { ignore RI.put(s.contracts, R.key(r.id, 8), encodeContract(r)) };
  func putInstalment(s : State, r : InstalmentRow) { ignore RI.put(s.instalments, R.key2(r.contract, 8, r.number, 8), encodeInstalment(r)) };
  func putPool(s : State, r : PoolRow) { ignore RI.put(s.pools, poolKey(r.id), encodePool(r)) };

  public func isOpen(r : ContractRow) : Bool { switch (r.stage) { case (#opened or #acquired or #sold or #running or #delivered) true; case (_) false } };
  public func outstanding(r : ContractRow) : Nat { let total = r.principal + r.profitTotal; if (total > r.collected) total - r.collected else 0 };
  public func instalmentsOf(s : State, id : IT.ContractId) : [InstalmentRow] {
    let out = List.empty<InstalmentRow>();
    let (lo, hi) = R.prefixRange(id, 8, 8);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.instalments, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) List.add(out, decodeInstalment(id, R.getNat(Blob.toArray(k), 8, 8), v));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };

  // ─── the standards' arithmetic ────────────────────────────────────────────

  /// Equal instalments of a deferred price over `n` periods from `start` (FAS 28: the selling price is cost plus
  /// markup, payable by instalments); the rounding remainder falls on the last. Each instalment's profit part is
  /// the markup allocated by the method: proportionate; equal per instalment (FAS 28 ¶20, the allocation over the
  /// credit period in proportion to the periods); effective rate; the interest column of the annuity schedule at
  /// the implicit rate that makes the markup the total, found by bisection on the rate (FAS 28's effective profit
  /// rate method).
  public func murabahaSchedule(cost : Nat, markup : Nat, n : Nat, every : ProdT.Period, start : Nat, method : IT.ProfitMethod) : [(Nat, Nat, Nat, Nat)] {
    // (dueDate, amount, principal, profit)
    if (n == 0) return [];
    let price = cost + markup;
    let base = price / n;
    let rem = price - base * n;
    func due(i : Nat) : Nat { switch (every) { case (#monthly) Products.addMonths(start, i + 1); case (#quarterly) Products.addMonths(start, 3 * (i + 1)); case (#semiAnnual) Products.addMonths(start, 6 * (i + 1)); case (#annual) Products.addMonths(start, 12 * (i + 1)); case (#daily) start + i + 1; case (#atMaturity) Products.addMonths(start, n) } };
    switch (method) {
      case (#proportionate) {
        let pBase = markup / n; let pRem = markup - pBase * n;
        Array.tabulate<(Nat, Nat, Nat, Nat)>(n, func(i) {
          let amount = base + (if (i + 1 == n) rem else 0);
          let profit = pBase + (if (i + 1 == n) pRem else 0);
          (due(i), amount, amount - profit, profit)
        })
      };
      case (#effectiveRate) {
        // the implicit rate: the equal-instalment schedule of `cost` whose total interest equals the markup
        let sch : ProdT.ScheduleTerms = { amortisation = #equalInstalments; instalments = n; every; principalGrace = 0; interestGrace = 0; moratoriumDays = 0 };
        let rounding : I.Rounding = #halfEven;   // the schedule oracle rounds half-even
        var lo = 0; var hi = 2_000_000;   // basis points × 100: 0 .. 200% per annum
        var best : [ProdT.Instalment] = [];
        var iter = 0;
        while (iter < 40 and lo < hi) {
          let mid = (lo + hi) / 2;
          let g = Products.schedule(cost, { numerator = mid; denominator = 1_000_000; negative = false }, sch, rounding, start);
          if (g.totalInterest < markup) lo := mid + 1 else { hi := mid; best := g.rows };
          iter += 1;
        };
        if (best.size() == 0) best := Products.schedule(cost, { numerator = lo; denominator = 1_000_000; negative = false }, sch, rounding, start).rows;
        // the schedule's profit column, the difference to the markup settled on the last instalment
        var profitSum = 0;
        for (r in best.vals()) profitSum += r.interest;
        Array.tabulate<(Nat, Nat, Nat, Nat)>(n, func(i) {
          let r = best[i];
          var profit = r.interest;
          if (i + 1 == n) { profit := if (markup >= profitSum) profit + (markup - profitSum) else (if (profit >= profitSum - markup) profit - (profitSum - markup) else 0) };
          let amount = base + (if (i + 1 == n) rem else 0);
          (due(i), amount, if (amount >= profit) amount - profit else 0, profit)
        })
      };
    }
  };
  /// The profit of a proportionate Murabaha recognised by `day`: the markup over the credit period, straight-line
  /// on calendar days from the sale to the last due date (cumulative, rounding never drifts).
  public func proportionateBy(markup : Nat, soldDay : Nat, lastDue : Nat, day : Nat) : Nat {
    if (day >= lastDue or lastDue <= soldDay) return markup;
    if (day <= soldDay) return 0;
    markup * (day - soldDay) / (lastDue - soldDay)
  };
  /// Straight-line depreciation of an Ijarah asset to its residual over the shorter of the useful life and the
  /// lease term (FAS 32 lessor accounting), cumulative by day.
  public func depreciationBy(cost : Nat, residual : Nat, startDay : Nat, months : Nat, day : Nat) : Nat {
    let endDay = Products.addMonths(startDay, months);
    let base = if (cost > residual) cost - residual else 0;
    if (day >= endDay or endDay <= startDay) return base;
    if (day <= startDay) return 0;
    base * (day - startDay) / (endDay - startDay)
  };
  /// A Musharakah's profit by the agreed ratio (the bank's `bankBps`, each partner's `profitBps`; the ratios sum to
  /// 10,000), each rounded down, the remainder the bank's; a loss strictly by capital (FAS 4).
  public func shareProfit(profit : Nat, _bankBps : Nat, partners : [IT.Partner]) : (Nat, [(PT.PartyId, Nat)]) {
    var given = 0;
    let parts = Array.map<IT.Partner, (PT.PartyId, Nat)>(partners, func(p) { let x = profit * p.profitBps / 10_000; given += x; (p.party, x) });
    (profit - given, parts)
  };
  public func shareLoss(loss : Nat, bankCapital : Nat, partners : [IT.Partner]) : (Nat, [(PT.PartyId, Nat)]) {
    var total = bankCapital;
    for (p in partners.vals()) total += p.capital;
    if (total == 0) return (loss, []);
    var given = 0;
    let parts = Array.map<IT.Partner, (PT.PartyId, Nat)>(partners, func(p) { let x = loss * p.capital / total; given += x; (p.party, x) });
    (loss - given, parts)
  };
  /// Istisna'a revenue and cost recognised at a cumulative percentage of completion (FAS 10): the price and the
  /// estimated cost at the percentage, less what earlier milestones recognised.
  public func completionFigures(price : Nat, estimatedCost : Nat, cumulativeBps : Nat, previousBps : Nat) : (Nat, Nat) {
    let revenue = price * cumulativeBps / 10_000 - price * previousBps / 10_000;
    let cost = estimatedCost * cumulativeBps / 10_000 - estimatedCost * previousBps / 10_000;
    (revenue, cost)
  };
  /// A pool's monthly distribution (FAS 27): PER off the income within its ceiling, the mudarib's share of the rest,
  /// IRR off the holders' share within its ceiling, the remainder allocated by weighted average balances (Σ daily
  /// balances), each holder rounded down and the remainder to the largest.
  public func distribute(income : Nat, mudaribBps : Nat, perBps : Nat, irrBps : Nat, weights : [(ProdT.AccountId, Nat)]) : { per : Nat; distributable : Nat; mudaribShare : Nat; holdersShare : Nat; irr : Nat; paid : Nat; allocations : [(ProdT.AccountId, Nat)] } {
    let per = income * perBps / 10_000;
    let distributable = income - per;
    let mudaribShare = distributable * mudaribBps / 10_000;
    let holdersShare = distributable - mudaribShare;
    let irr = holdersShare * irrBps / 10_000;
    let paid = holdersShare - irr;
    var totalW = 0;
    for ((_, w) in weights.vals()) totalW += w;
    if (totalW == 0 or weights.size() == 0) return { per; distributable; mudaribShare; holdersShare; irr; paid; allocations = [] };
    var given = 0; var largest = 0; var largestW = 0;
    let alloc = Array.tabulate<(ProdT.AccountId, Nat)>(weights.size(), func(i) { let (a, w) = weights[i]; let x = paid * w / totalW; given += x; if (w > largestW) { largestW := w; largest := i }; (a, x) });
    let fixed = Array.tabulate<(ProdT.AccountId, Nat)>(alloc.size(), func(i) { if (i == largest) (alloc[i].0, alloc[i].1 + (paid - given)) else alloc[i] });
    { per; distributable; mudaribShare; holdersShare; irr; paid; allocations = fixed }
  };

  // ─── gates ────────────────────────────────────────────────────────────────

  func invalid(reason : Text, standard : Text) : IT.IslamicError { #InvalidTerms({ reason; standard }) };
  func require(s : State, id : IT.ContractId) : Result.Result<ContractRow, IT.IslamicError> {
    switch (row(s, id)) { case (?r) #ok(r); case null #err(#UnknownContract({ contract = id })) }
  };
  func requireKind(r : ContractRow, kind : Nat8) : ?IT.IslamicError { if (r.kind != kind) ?#WrongKind({ contract = r.id; kind = kindTextOf(r.kind); wanted = kindTextOf(kind) }) else null };
  func requireStage(r : ContractRow, wanted : [IT.Stage]) : ?IT.IslamicError {
    for (w in wanted.vals()) { if (r.stage == w) return null };
    var names = "";
    for (w in wanted.vals()) names := names # (if (names == "") "" else " or ") # IT.stageText(w);
    ?#ContractNotIn({ contract = r.id; stage = IT.stageText(r.stage); wanted = names })
  };
  func validCounterparty(c : IT.Counterparty) : ?Text { switch (c) { case (#party(_)) null; case (#external(e)) { if (e.name == "") ?"an external counterparty needs a name" else null } } };

  // ─── planners ─────────────────────────────────────────────────────────────

  public func planPolicy(p : IT.Policy) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    for ((name, v) in [("murabahaInventory", p.murabahaInventory), ("murabahaReceivable", p.murabahaReceivable), ("deferredProfit", p.deferredProfit), ("murabahaIncome", p.murabahaIncome), ("securityDeposits", p.securityDeposits),
                       ("ijarahAssets", p.ijarahAssets), ("accumulatedDepreciation", p.accumulatedDepreciation), ("depreciationExpense", p.depreciationExpense), ("rentalReceivable", p.rentalReceivable), ("ijarahIncome", p.ijarahIncome),
                       ("musharakahInvestment", p.musharakahInvestment), ("musharakahIncome", p.musharakahIncome), ("mudarabahInvestment", p.mudarabahInvestment), ("mudarabahIncome", p.mudarabahIncome), ("investmentLosses", p.investmentLosses),
                       ("salamReceivable", p.salamReceivable), ("salamInventory", p.salamInventory), ("salamIncome", p.salamIncome), ("istisnaWip", p.istisnaWip), ("istisnaReceivable", p.istisnaReceivable), ("istisnaRevenue", p.istisnaRevenue), ("istisnaCosts", p.istisnaCosts),
                       ("iahEquity", p.iahEquity), ("profitEqualisationReserve", p.profitEqualisationReserve), ("investmentRiskReserve", p.investmentRiskReserve), ("profitPayableToHolders", p.profitPayableToHolders), ("mudaribShareIncome", p.mudaribShareIncome), ("profitAttributableToHolders", p.profitAttributableToHolders),
                       ("charityPayable", p.charityPayable), ("nostro", p.nostro)].vals()) {
      if (v == "") return #err(#InvalidPolicy({ reason = name # " names no account" }));
    };
    if (p.perCeilingBps > 10_000 or p.irrCeilingBps > 10_000) return #err(#InvalidPolicy({ reason = "a reserve ceiling is at most the whole" }));
    #ok(#policySet(p))
  };
  public func planApproveProduct(product : ProdT.ProductId, approval : IT.BoardApproval, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    // the reference is a 32-byte row field: refused here, typed, before the fold would trap on it
    if (approval.ref == "" or Text.encodeUtf8(approval.ref).size() > 32) return #err(invalid("the board's approval carries its reference, in one to thirty-two bytes", "governance"));
    if (approval.sha256.size() != 32) return #err(invalid("the resolution is recorded by its SHA-256", "governance"));
    #ok(#productApproved({ product; approval; day = today }))
  };
  public func planFlagBook(book : Text, sharia : Bool, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    if (book == "" or Text.encodeUtf8(book).size() > 32) return #err(invalid("a book, named in one to thirty-two bytes", "governance"));
    #ok(#bookFlagged({ book; sharia; day = today }))
  };

  /// A contract opened: the terms of its kind gated by its standard. `product` is the Sharia product the customer's
  /// account is under: it must carry a board approval and no interest component.
  public func planOpen(s : State, kind : IT.Kind, currency : Text, book : Text, product : ProdT.ProductId, productHasInterest : Bool, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    if (s.policy == null) return #err(#NoPolicy);
    if (approval(s, product) == null) return #err(#NoBoardApproval({ product }));
    if (productHasInterest) return #err(#InterestOnShariaProduct({ product }));
    let reference = switch (kind) { case (#murabaha(m)) m.reference; case (#ijarah(i)) i.reference; case (#musharakah(m)) m.reference; case (#mudarabah(m)) m.reference; case (#salam(x)) x.reference; case (#istisna(x)) x.reference };
    if (reference == "") return #err(invalid("a contract carries its reference", "FAS 1"));
    if (byReference(s, reference) != null) return #err(invalid("a contract with this reference exists", "FAS 1"));
    switch (kind) {
      case (#murabaha(m)) {
        if (m.costPrice == 0) return #err(invalid("a Murabaha buys an asset for a price", "FAS 28 ¶8"));
        if (m.markup == 0) return #err(invalid("the markup is the bank's disclosed profit", "FAS 28 ¶8"));
        if (m.instalments == 0) return #err(invalid("the deferred price is payable by at least one instalment", "FAS 28 ¶9"));
        if (m.every == #atMaturity and m.instalments != 1) return #err(invalid("a price due at maturity is one instalment", "FAS 28 ¶9"));
        if (m.asset == "") return #err(invalid("the asset is described", "FAS 28 ¶6"));
        switch (validCounterparty(m.supplier)) { case (?why) return #err(invalid(why, "FAS 28")); case null {} };
        if (m.promise == #nonBinding and m.securityDeposit > 0) return #err(invalid("hamish jiddiyah is taken only against a binding promise", "FAS 28 ¶14"));
        if (m.latePaymentCharityBps > 5_000) return #err(invalid("a late-payment undertaking beyond fifty per cent per annum", "AAOIFI Sharia Standard 8"));
      };
      case (#ijarah(i)) {
        if (i.cost == 0 or i.rental == 0 or i.periods == 0 or i.usefulLifeMonths == 0) return #err(invalid("a lease has an asset with a cost, a rental and a term", "FAS 32 ¶6"));
        if (i.residual >= i.cost) return #err(invalid("the residual is below the cost", "FAS 32 ¶27"));
        switch (i.transfer) { case (?#gradual(g)) { if (g.units == 0) return #err(invalid("a gradual transfer is in units", "FAS 32 ¶40")) }; case (_) {} };
      };
      case (#musharakah(m)) {
        if (m.bankCapital == 0) return #err(invalid("the bank contributes capital", "FAS 4 ¶3"));
        var bps = m.bankProfitBps;
        for (p in m.partners.vals()) { if (p.capital == 0) return #err(invalid("every partner contributes capital", "FAS 4 ¶3")); bps += p.profitBps };
        if (bps != 10_000) return #err(invalid("the profit ratios sum to the whole", "FAS 4 ¶15"));
        if (m.partners.size() == 0) return #err(invalid("a partnership has a partner", "FAS 4 ¶2"));
        switch (m.diminishing) { case (?d) { if (d.units == 0 or d.unitPrice == 0) return #err(invalid("a diminishing Musharakah sells the bank's share in priced units", "FAS 4 ¶10")) }; case null {} };
      };
      case (#mudarabah(m)) {
        if (m.capital == 0) return #err(invalid("rabb al-mal provides the capital", "FAS 4 ¶25"));
        if (m.bankProfitBps == 0 or m.bankProfitBps >= 10_000) return #err(invalid("the profit is shared by an agreed ratio", "FAS 4 ¶30"));
        if (m.term == 0) return #err(invalid("a Mudarabah has a term", "FAS 4"));
      };
      case (#salam(x)) {
        if (x.priceAdvanced == 0 or x.quantity == 0) return #err(invalid("the price is paid in full at the contract for a stated quantity", "FAS 7 ¶6"));
        if (x.delivery <= today) return #err(invalid("delivery is at a future date", "FAS 7 ¶6"));
        if (x.commodity == "" or x.unit == "") return #err(invalid("the commodity and its unit are stated", "FAS 7 ¶6"));
      };
      case (#istisna(x)) {
        if (x.price == 0 or x.estimatedCost == 0) return #err(invalid("a price and an estimated cost", "FAS 10 ¶8"));
        if (x.estimatedCost >= x.price) return #err(invalid("the estimated cost is below the price: the difference is the profit", "FAS 10 ¶8"));
        if (x.specification.size() != 32) return #err(invalid("the specification is recorded by its SHA-256", "FAS 10 ¶6"));
        if (x.milestones.size() == 0) return #err(invalid("completion is recognised at recorded milestones", "FAS 10 ¶13"));
        var lastD = today; var lastP = 0;
        for ((d, p) in x.milestones.vals()) { if (d <= lastD or p <= lastP or p > 10_000) return #err(invalid("milestones are in date order with rising cumulative percentages up to the whole", "FAS 10 ¶13")); lastD := d; lastP := p };
        if (lastP != 10_000) return #err(invalid("the last milestone completes the work", "FAS 10 ¶13"));
        switch (validCounterparty(x.contractor)) { case (?why) return #err(invalid(why, "FAS 10")); case null {} };
      };
    };
    #ok(#contractOpened({ kind; currency; book; day = today }))
  };

  // Murabaha
  public func planAcquire(s : State, id : IT.ContractId, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 1)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#opened])) { case (?e) return #err(e); case null {} };
    #ok(#assetAcquired({ contract = id; cost = r.principal; day = today }))
  };
  public func planSell(s : State, id : IT.ContractId, m : IT.Murabaha, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 1)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#acquired])) { case (?e) return #err(e); case null {} };   // the bank sells what it owns (FAS 28 ¶8, Sharia Standard 8/3)
    let sch = murabahaSchedule(m.costPrice, m.markup, m.instalments, m.every, today, m.method);
    #ok(#murabahaSold({ contract = id; sellingPrice = m.costPrice + m.markup; deferredProfit = m.markup; schedule = Array.map<(Nat, Nat, Nat, Nat), (Nat, Nat)>(sch, func((d, a, _, _)) { (d, a) }); day = today }))
  };
  /// The next unpaid instalment collected: its principal and profit parts from the schedule row.
  public func planCollect(s : State, id : IT.ContractId, today : Nat) : Result.Result<(IT.IslamicEvent, InstalmentRow), IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 1)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#sold])) { case (?e) return #err(e); case null {} };
    let ?inst = instalment(s, id, r.instalmentsPaid + 1) else return #err(#ContractNotIn({ contract = id; stage = "sold"; wanted = "an instalment outstanding" }));
    #ok((#instalmentCollected({ contract = id; amount = inst.amount; principal = inst.principal; profit = inst.profit; day = today }), inst))
  };
  /// The profit recognised to the day under the contract's method: proportionate over the credit period, or by the
  /// instalments fallen due under the effective rate.
  public func profitDueBy(s : State, r : ContractRow, day : Nat) : Nat {
    if (r.kind != 1 or r.stage != #sold) return r.profitRecognised;
    let insts = instalmentsOf(s, r.id);
    if (insts.size() == 0) return r.profitRecognised;
    if ((r.flags & F_EFFECTIVE) == 0) {
      let soldDay = r.openedDay;   // the sale day is recorded on the row when sold
      let lastDue = insts[insts.size() - 1].dueDate;
      Nat.max(r.profitRecognised, proportionateBy(r.profitTotal, soldDay, lastDue, day))
    } else {
      var sum = 0;
      for (i in insts.vals()) { if (i.dueDate <= day) sum += i.profit };
      Nat.max(r.profitRecognised, Nat.min(sum, r.profitTotal))
    }
  };
  public func planRebate(s : State, id : IT.ContractId, amount : Nat, reason : Text, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 1)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#sold])) { case (?e) return #err(e); case null {} };
    if (reason == "") return #err(#RebateNotDiscretionary({ contract = id }));
    let unrecognised = if (r.profitTotal > r.profitRecognised) r.profitTotal - r.profitRecognised else 0;
    if (amount == 0 or amount > unrecognised) return #err(invalid("an ibra' forgives profit not yet recognised, at most " # Nat.toText(unrecognised), "Sharia Standard 8/5"));
    #ok(#rebateGranted({ contract = id; amount; reason; day = today }))
  };
  /// The late-payment amount an overdue instalment carries to charity: the undertaking's per-annum rate on the
  /// overdue amount over the days late (never income; Sharia Standard 8/5/6).
  public func lateCharity(inst : InstalmentRow, bps : Nat, today : Nat) : Nat {
    if (today <= inst.dueDate or inst.paid) return inst.charity;
    Nat.max(inst.charity, inst.amount * bps * (today - inst.dueDate) / (10_000 * 365))
  };

  // Ijarah
  public func planCommence(s : State, id : IT.ContractId, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 2)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#opened])) { case (?e) return #err(e); case null {} };
    #ok(#leaseCommenced({ contract = id; day = today }))
  };
  public func planCollectRental(s : State, id : IT.ContractId, today : Nat) : Result.Result<(IT.IslamicEvent, InstalmentRow), IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 2)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#running])) { case (?e) return #err(e); case null {} };
    let ?inst = instalment(s, id, r.instalmentsPaid + 1) else return #err(#ContractNotIn({ contract = id; stage = "running"; wanted = "a rental outstanding" }));
    if (inst.dueDate > today) return #err(invalid("the rental falls due on day " # Nat.toText(inst.dueDate), "FAS 32 ¶31"));
    #ok((#rentalCollected({ contract = id; amount = inst.amount; day = today }), inst))
  };
  public func planTransfer(s : State, id : IT.ContractId, i : IT.Ijarah, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 2)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#running])) { case (?e) return #err(e); case null {} };
    let ?how = i.transfer else return #err(invalid("an operating Ijarah transfers nothing", "FAS 32 ¶40"));
    if (r.instalmentsPaid < r.instalmentsDue) return #err(invalid("ownership passes when the rentals are paid", "FAS 32 ¶40"));
    let consideration = switch (how) { case (#gift) 0; case (#sale(x)) x.price; case (#gradual(_)) 0 };
    #ok(#ownershipTransferred({ contract = id; how; consideration; day = today }))
  };

  // Musharakah, Mudarabah
  public func planDistributeProfit(s : State, id : IT.ContractId, m : IT.Musharakah, profit : Nat, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 3)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#running])) { case (?e) return #err(e); case null {} };
    if (profit == 0) return #err(invalid("a distribution of nothing", "FAS 4 ¶15"));
    let (bankShare, partnerShares) = shareProfit(profit, m.bankProfitBps, m.partners);
    #ok(#profitDistributed({ contract = id; profit; bankShare; partnerShares; day = today }))
  };
  /// A loss is borne by capital alone (FAS 4 ¶16): the planner computes the allocation; an allocation offered by
  /// the caller that is not by capital is refused.
  public func planAllocateLoss(s : State, id : IT.ContractId, m : IT.Musharakah, loss : Nat, offered : ?[(PT.PartyId, Nat)], today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 3)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#running])) { case (?e) return #err(e); case null {} };
    if (loss == 0) return #err(invalid("a loss of nothing", "FAS 4 ¶16"));
    let (bankShare, partnerShares) = shareLoss(loss, m.bankCapital, m.partners);
    switch (offered) {
      case (?o) { if (o.size() != partnerShares.size()) return #err(#LossNotByCapital({ contract = id })); for (i in o.keys()) { if (o[i] != partnerShares[i]) return #err(#LossNotByCapital({ contract = id })) } };
      case null {};
    };
    #ok(#lossAllocated({ contract = id; loss; bankShare; partnerShares; day = today }))
  };
  public func planBuyUnit(s : State, id : IT.ContractId, m : IT.Musharakah, units : Nat, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 3)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#running])) { case (?e) return #err(e); case null {} };
    let ?d = m.diminishing else return #err(invalid("a constant Musharakah sells no units", "FAS 4 ¶10"));
    if (units == 0 or units > r.unitsLeft) return #err(invalid("the partner buys between one and the bank's remaining " # Nat.toText(r.unitsLeft) # " units", "FAS 4 ¶10"));
    #ok(#unitBought({ contract = id; units; price = units * d.unitPrice; bankUnitsLeft = r.unitsLeft - units; day = today }))
  };
  public func planMudarabahResult(s : State, id : IT.ContractId, m : IT.Mudarabah, profit : Nat, loss : Nat, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 4)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#running])) { case (?e) return #err(e); case null {} };
    if (profit > 0 and loss > 0) return #err(invalid("a period ends in a profit or a loss", "FAS 4 ¶30"));
    if (profit == 0 and loss == 0) return #err(invalid("a result of nothing", "FAS 4 ¶30"));
    if (loss > r.principal) return #err(invalid("a loss beyond the capital is the mudarib's, not rabb al-mal's", "FAS 4 ¶31"));
    if (profit > 0) { let bankShare = profit * m.bankProfitBps / 10_000; #ok(#profitDistributed({ contract = id; profit; bankShare; partnerShares = [(m.mudarib, profit - bankShare)]; day = today })) }
    else #ok(#lossAllocated({ contract = id; loss; bankShare = loss; partnerShares = [(m.mudarib, 0)]; day = today }))
  };

  // Salam, Istisna'a
  public func planDeliver(s : State, id : IT.ContractId, x : IT.Salam, quantity : Nat, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 5)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#opened])) { case (?e) return #err(e); case null {} };
    if (quantity != x.quantity) return #err(invalid("the whole quantity is delivered; a short delivery is a failure with recourse", "FAS 7 ¶9"));
    #ok(#commodityDelivered({ contract = id; quantity; day = today }))
  };
  public func planSellCommodity(s : State, id : IT.ContractId, proceeds : Nat, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 5)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#delivered])) { case (?e) return #err(e); case null {} };
    if (proceeds == 0) return #err(invalid("a sale for a price", "FAS 7 ¶12"));
    #ok(#commoditySold({ contract = id; proceeds; day = today }))
  };
  public func planDeliveryFailed(s : State, id : IT.ContractId, x : IT.Salam, recourse : Text, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 5)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#opened])) { case (?e) return #err(e); case null {} };
    if (today < x.delivery) return #err(invalid("a failure is declared on or after the delivery date", "FAS 7 ¶10"));
    if (recourse == "") return #err(invalid("the recourse is stated: the price returned, a later delivery, a substitute", "FAS 7 ¶10"));
    #ok(#deliveryFailed({ contract = id; recourse; day = today }))
  };
  public func planMilestone(s : State, id : IT.ContractId, x : IT.Istisna, certificate : Blob, percentBps : Nat, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (requireKind(r, 6)) { case (?e) return #err(e); case null {} };
    switch (requireStage(r, [#opened, #running])) { case (?e) return #err(e); case null {} };
    if (certificate.size() != 32) return #err(invalid("the completion certificate is recorded by its SHA-256", "FAS 10 ¶13"));
    if (percentBps <= r.percentBps or percentBps > 10_000) return #err(invalid("a milestone raises the percentage of completion, to the whole at most", "FAS 10 ¶13"));
    var listed = false;
    for ((_, p) in x.milestones.vals()) { if (p == percentBps) listed := true };
    if (not listed) return #err(invalid("the percentage is one the contract's milestones state", "FAS 10 ¶13"));
    let (revenue, cost) = completionFigures(x.price, x.estimatedCost, percentBps, r.percentBps);
    #ok(#milestoneRecorded({ contract = id; certificate; percentBps; revenue; cost; day = today }))
  };
  public func planSettle(s : State, id : IT.ContractId, today : Nat) : Result.Result<(IT.IslamicEvent, ContractRow), IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    switch (r.kind, r.stage) {
      case (1, #sold) { if (r.instalmentsPaid < r.instalmentsDue) return #err(invalid("a Murabaha settles when every instalment is paid", "FAS 28")) };
      case (2, #running) { if (r.instalmentsPaid < r.instalmentsDue) return #err(invalid("an Ijarah settles when every rental is paid", "FAS 32")) };
      case (3, #running) { if ((r.flags & F_DIMINISHING) != 0 and r.unitsLeft > 0) return #err(invalid("a diminishing Musharakah settles when the bank's units are sold", "FAS 4")) };
      case (4, #running) {};
      case (5, #delivered) { if (r.collected == 0) return #err(invalid("the commodity is sold before the Salam settles", "FAS 7")) };
      case (6, #running) { if (r.percentBps < 10_000) return #err(invalid("an Istisna'a settles when the work is complete and the price collected", "FAS 10")) };
      case (_, _) return #err(#ContractNotIn({ contract = id; stage = IT.stageText(r.stage); wanted = "a stage a settlement ends" }));
    };
    #ok((#contractSettled({ contract = id; day = today }), r))
  };
  public func planClose(s : State, id : IT.ContractId, reason : Text, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let r = switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(r)) r };
    if (r.stage == #closed) return #err(#ContractNotIn({ contract = id; stage = "closed"; wanted = "not closed" }));
    if (reason == "") return #err(invalid("a closure states its reason", "governance"));
    #ok(#contractClosed({ contract = id; reason; day = today }))
  };
  public func planNonCompliance(s : State, contract : ?IT.ContractId, amount : Nat, account : Text, reason : Text, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    if (s.policy == null) return #err(#NoPolicy);
    switch (contract) { case (?id) { switch (require(s, id)) { case (#err(e)) return #err(e); case (#ok(_)) {} } }; case null {} };
    if (amount == 0) return #err(invalid("an amount of income found non-compliant", "FAS 1 / IFSB-4"));
    if (reason == "" or account == "") return #err(invalid("the income account and the ground are stated", "FAS 1 / IFSB-4"));
    #ok(#nonComplianceRecorded({ contract; amount; account; reason; day = today }))
  };

  // investment accounts (FAS 27)
  public func planOpenPool(s : State, p : IT.Pool, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let ?pol = s.policy else return #err(#NoPolicy);
    if (p.id == "" or p.currency == "" or p.product == "") return #err(invalid("a pool has an identifier, a currency and the account product it pools", "FAS 27"));
    // the identifier and the product are 32-byte row fields, the currency an 8-byte one: refused typed, never a trap
    if (Text.encodeUtf8(p.id).size() > 32 or Text.encodeUtf8(p.product).size() > 32 or Text.encodeUtf8(p.currency).size() > 8) return #err(invalid("a pool's identifier and product are at most thirty-two bytes, its currency eight", "FAS 27"));
    if (pool(s, p.id) != null) return #err(invalid("a pool with this identifier exists", "FAS 27"));
    if (p.mudaribBps >= 10_000) return #err(invalid("the mudarib's share is a part of the profit", "FAS 27 ¶12"));
    if (p.perBps > pol.perCeilingBps) return #err(#ReserveOverCeiling({ pool = p.id; which = "PER"; bps = p.perBps; ceiling = pol.perCeilingBps }));
    if (p.irrBps > pol.irrCeilingBps) return #err(#ReserveOverCeiling({ pool = p.id; which = "IRR"; bps = p.irrBps; ceiling = pol.irrCeilingBps }));
    if (p.incomeAccounts.size() == 0) return #err(invalid("the pool's income is read from named accounts", "FAS 27 ¶9"));
    #ok(#poolOpened({ pool = p; day = today }))
  };
  public func planReserves(s : State, poolId : IT.PoolId, per : ?Nat, irr : ?Nat, today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let ?pol = s.policy else return #err(#NoPolicy);
    let ?_ = pool(s, poolId) else return #err(#UnknownPool({ pool = poolId }));
    switch (per) { case (?b) { if (b > pol.perCeilingBps) return #err(#ReserveOverCeiling({ pool = poolId; which = "PER"; bps = b; ceiling = pol.perCeilingBps })) }; case null {} };
    switch (irr) { case (?b) { if (b > pol.irrCeilingBps) return #err(#ReserveOverCeiling({ pool = poolId; which = "IRR"; bps = b; ceiling = pol.irrCeilingBps })) }; case null {} };
    if (per == null and irr == null) return #err(invalid("an update changes a reserve", "FAS 27"));
    #ok(#reserveUpdated({ pool = poolId; per; irr; day = today }))
  };
  /// A month's distribution from the figures `BankCore` read: the pool's income over the period and the holders'
  /// weighted balances. Every figure is stated on the event.
  public func planDistribute(s : State, poolId : IT.PoolId, period : Text, from : Nat, to : Nat, income : Nat, weights : [(ProdT.AccountId, Nat)], today : Nat) : Result.Result<IT.IslamicEvent, IT.IslamicError> {
    let ?p = pool(s, poolId) else return #err(#UnknownPool({ pool = poolId }));
    // the label is the row key's second half, an 8-byte field: refused here, typed, before any key is built from it
    if (period.size() == 0 or Text.encodeUtf8(period).size() > 8) return #err(invalid("a period label of one to eight bytes", "FAS 27"));
    if (distribution(s, poolId, period) != null) return #err(#PeriodAlreadyDistributed({ pool = poolId; period }));
    if (to < from) return #err(invalid("a period", "FAS 27"));
    let d = distribute(income, p.mudaribBps, p.perBps, p.irrBps, weights);
    #ok(#poolDistributed({ distribution = { pool = poolId; period; from; to; income; per = d.per; distributable = d.distributable; mudaribShare = d.mudaribShare; holdersShare = d.holdersShare; irr = d.irr; paid = d.paid; weightedBalances = weights; allocations = d.allocations }; day = today }))
  };

  // ─── the fold ─────────────────────────────────────────────────────────────

  func index(s : State, r : ContractRow) {
    ignore RI.put(s.byParty, R.key2(r.party, 8, r.id, 8), Blob.fromArray([0]));
    ignore RI.put(s.byStage, R.key2(Nat8.toNat(stageCode(r.stage)), 1, r.id, 8), Blob.fromArray([0]));
    ignore RI.put(s.byBook, bookKey(r.book, r.id), Blob.fromArray([0]));
  };
  /// The open contracts per currency, kept by the fold: what a redenomination asks before it closes a currency (S4.1).
  func bumpCurrency(s : State, ccy : Text, delta : Int) {
    let cur : Int = switch (Map.get(s.openByCurrency, Text.compare, ccy)) { case (?v) v; case null 0 };
    let next = cur + delta;
    if (next <= 0) ignore Map.delete(s.openByCurrency, Text.compare, ccy) else Map.add(s.openByCurrency, Text.compare, ccy, Int.abs(next));
  };
  public func openInCurrency(s : State, ccy : Text) : Nat { switch (Map.get(s.openByCurrency, Text.compare, ccy)) { case (?v) v; case null 0 } };
  func bumpBook(s : State, book : Text, delta : Int) {
    let cur : Int = switch (Map.get(s.openByBook, Text.compare, book)) { case (?v) v; case null 0 };
    let next = cur + delta;
    if (next <= 0) ignore Map.delete(s.openByBook, Text.compare, book) else Map.add(s.openByBook, Text.compare, book, Int.abs(next));
  };
  /// The open contracts of a book, from the fold's counter: what the end-of-day plan asks; no walk (S4.1).
  public func openCountInBook(s : State, book : Text) : Nat { switch (Map.get(s.openByBook, Text.compare, book)) { case (?v) v; case null 0 } };
  func moveStage(s : State, r : ContractRow, to : IT.Stage, block : Nat) : ContractRow {
    let wasOpen = isOpen(r);
    let r2 = { r with stage = to; lastBlock = block };
    if (wasOpen and not isOpen(r2)) { if (s.open > 0) s.open -= 1; bumpCurrency(s, r.currency, -1); bumpBook(s, r.book, -1) };
    ignore RI.put(s.byStage, R.key2(Nat8.toNat(stageCode(to)), 1, r.id, 8), Blob.fromArray([0]));
    r2
  };
  public func ours(c : IT.Counterparty) : (PT.PartyId, ProdT.AccountId) { switch (c) { case (#party(p)) (p.party, p.account); case (#external(_)) (0, 0) } };
  func termsHashOf(k : IT.Kind) : Blob { Sha256.fromBlob(#sha256, Text.encodeUtf8(debug_show k)) };

  public func fold(s : State, block : Nat, ev : IT.IslamicEvent) {
    switch (ev) {
      case (#policySet(p)) s.policy := ?p;
      case (#productApproved(x)) { let b = R.buf(); R.putText(b, x.approval.ref, 32); R.putBlob(b, x.approval.sha256, 32); ignore RI.put(s.approvals, R.textKey(x.product, 32), R.done(b, 64)) };
      case (#bookFlagged(x)) ignore RI.put(s.shariaBooks, R.textKey(x.book, 32), Blob.fromArray([if (x.sharia) 1 else 0]));
      case (#contractOpened(x)) {
        let (party, account, principal, profitTotal, flags, units, due, reference) : (Nat, Nat, Nat, Nat, Nat8, Nat, Nat, Text) = switch (x.kind) {
          case (#murabaha(m)) (m.customer, m.account, m.costPrice, m.markup, (if (m.method == #effectiveRate) F_EFFECTIVE else 0) | (if (m.promise == #binding) F_BINDING else 0), 0, m.instalments, m.reference);
          case (#ijarah(i)) (i.lessee, i.account, i.cost, i.rental * i.periods, if (i.transfer != null) F_IMB else 0, switch (i.transfer) { case (?#gradual(g)) g.units; case (_) 0 }, i.periods, i.reference);
          case (#musharakah(m)) { let (p, a) = (m.partners[0].party, m.partners[0].account); (p, a, m.bankCapital, 0, if (m.diminishing != null) F_DIMINISHING else 0, switch (m.diminishing) { case (?d) d.units; case null 0 }, 0, m.reference) };
          case (#mudarabah(m)) (m.mudarib, m.account, m.capital, 0, 0, 0, 0, m.reference);
          case (#salam(x_)) (x_.seller, x_.account, x_.priceAdvanced, 0, 0, 0, 0, x_.reference);
          case (#istisna(x_)) (x_.customer, x_.account, x_.price, x_.price - x_.estimatedCost, 0, 0, x_.milestones.size(), x_.reference);
        };
        let sd = switch (x.kind) { case (#murabaha(m)) m.securityDeposit; case (_) 0 };
        let unitPrice = switch (x.kind) { case (#musharakah(m)) { switch (m.diminishing) { case (?d) d.unitPrice; case null 0 } }; case (_) 0 };
        let r : ContractRow = {
          id = block; kind = kindCode(x.kind); stage = #opened; flags; party; account; currency = x.currency; book = x.book;
          principal; profitTotal; profitRecognised = 0; collected = 0; openedDay = x.day; nextDue = 0; instalmentsDue = due; instalmentsPaid = 0; units; unitsLeft = units; percentBps = 0;
          securityDeposit = sd; depreciation = 0; termsHash = termsHashOf(x.kind); lastBlock = block; unitPrice;
        };
        putRow(s, r); index(s, r);
        ignore RI.put(s.byReference, refKey(reference), R.key(block, 8));
        holdSub(s, contractSub(block));
        s.opened += 1; s.open += 1; bumpCurrency(s, r.currency, 1); bumpBook(s, r.book, 1);
      };
      case (#assetAcquired(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, moveStage(s, r, #acquired, block)); case null {} } };
      case (#murabahaSold(x)) {
        switch (row(s, x.contract)) {
          case (?r) {
            var n = 0;
            for ((d, a) in x.schedule.vals()) {
              n += 1;
              // the profit part per instalment: proportionate; equal parts; effective; from the schedule the planner produced;
              // the event carries amounts only, so the parts are re-derived under the method from the row's figures
              putInstalment(s, { contract = x.contract; number = n; dueDate = d; amount = a; principal = 0; profit = 0; paid = false; charity = 0 });
            };
            // fill the parts from the method (the same pure function the planner used)
            let method : IT.ProfitMethod = if ((r.flags & F_EFFECTIVE) != 0) #effectiveRate else #proportionate;
            let every : ProdT.Period = if (x.schedule.size() >= 2) periodOf(x.schedule[0].0, x.schedule[1].0) else #atMaturity;
            let parts = murabahaSchedule(r.principal, x.deferredProfit, x.schedule.size(), every, x.day, method);
            var i = 0;
            for ((d, a, p, pr) in parts.vals()) { i += 1; putInstalment(s, { contract = x.contract; number = i; dueDate = x.schedule[i - 1].0; amount = x.schedule[i - 1].1; principal = p; profit = pr; paid = false; charity = 0 }) };
            let first = if (x.schedule.size() > 0) x.schedule[0].0 else 0;
            putRow(s, moveStage(s, { r with openedDay = x.day; profitTotal = x.deferredProfit; nextDue = first; instalmentsDue = x.schedule.size() }, #sold, block));
          };
          case null {};
        }
      };
      case (#instalmentCollected(x)) {
        switch (row(s, x.contract)) {
          case (?r) {
            let n = r.instalmentsPaid + 1;
            switch (instalment(s, x.contract, n)) { case (?i) putInstalment(s, { i with paid = true }); case null {} };
            let next = switch (instalment(s, x.contract, n + 1)) { case (?i) i.dueDate; case null 0 };
            putRow(s, { r with instalmentsPaid = n; collected = r.collected + x.amount; nextDue = next; lastBlock = block });
          };
          case null {};
        }
      };
      case (#profitRecognised(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, { r with profitRecognised = x.cumulative; lastBlock = block }); case null {} } };
      case (#rebateGranted(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, { r with profitTotal = if (r.profitTotal > x.amount) r.profitTotal - x.amount else 0; lastBlock = block }); case null {} } };
      case (#latePaymentToCharity(x)) {
        s.charity += x.amount;
        switch (instalment(s, x.contract, x.instalment)) { case (?i) putInstalment(s, { i with charity = i.charity + x.amount }); case null {} };
        switch (row(s, x.contract)) { case (?r) putRow(s, { r with lastBlock = block }); case null {} };
      };
      case (#leaseCommenced(x)) {
        switch (row(s, x.contract)) {
          case (?r) {
            // the rentals from the commencement: one row per period
            var i = 0;
            let rental = if (r.instalmentsDue == 0) 0 else r.profitTotal / r.instalmentsDue;
            while (i < r.instalmentsDue) { i += 1; putInstalment(s, { contract = x.contract; number = i; dueDate = Products.addMonths(x.day, i); amount = rental + (if (i == r.instalmentsDue) r.profitTotal - rental * r.instalmentsDue else 0); principal = 0; profit = rental; paid = false; charity = 0 }) };
            putRow(s, moveStage(s, { r with openedDay = x.day; nextDue = Products.addMonths(x.day, 1) }, #running, block));
          };
          case null {};
        }
      };
      case (#rentalAccrued(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, { r with profitRecognised = r.profitRecognised + x.amount; lastBlock = block }); case null {} } };
      case (#rentalCollected(x)) {
        switch (row(s, x.contract)) {
          case (?r) {
            let n = r.instalmentsPaid + 1;
            switch (instalment(s, x.contract, n)) { case (?i) putInstalment(s, { i with paid = true }); case null {} };
            let next = switch (instalment(s, x.contract, n + 1)) { case (?i) i.dueDate; case null 0 };
            putRow(s, { r with instalmentsPaid = n; collected = r.collected + x.amount; nextDue = next; lastBlock = block });
          };
          case null {};
        }
      };
      case (#depreciationPosted(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, { r with depreciation = x.cumulative; lastBlock = block }); case null {} } };
      case (#ownershipTransferred(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, moveStage(s, { r with collected = r.collected + x.consideration }, #settled, block)); case null {} } };
      case (#capitalContributed(x)) {
        switch (row(s, x.contract)) {
          case (?r) { if (r.stage == #opened) putRow(s, moveStage(s, r, #running, block)) else putRow(s, { r with lastBlock = block }) };
          case null {};
        }
      };
      case (#profitDistributed(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, { r with profitRecognised = r.profitRecognised + x.bankShare; lastBlock = block }); case null {} } };
      case (#lossAllocated(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, { r with principal = if (r.principal > x.bankShare) r.principal - x.bankShare else 0; lastBlock = block }); case null {} } };
      case (#unitBought(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, { r with unitsLeft = x.bankUnitsLeft; collected = r.collected + x.price; lastBlock = block }); case null {} } };
      case (#commodityDelivered(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, moveStage(s, r, #delivered, block)); case null {} } };
      case (#commoditySold(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, { r with collected = x.proceeds; profitRecognised = if (x.proceeds > r.principal) x.proceeds - r.principal else 0; lastBlock = block }); case null {} } };
      case (#deliveryFailed(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, moveStage(s, r, #defaulted, block)); case null {} } };
      case (#milestoneRecorded(x)) {
        switch (row(s, x.contract)) {
          case (?r) { let r2 = if (r.stage == #opened) moveStage(s, r, #running, block) else r; putRow(s, { r2 with percentBps = x.percentBps; profitRecognised = r.profitRecognised + (if (x.revenue > x.cost) x.revenue - x.cost else 0); instalmentsPaid = r.instalmentsPaid + 1; lastBlock = block }) };
          case null {};
        }
      };
      case (#contractSettled(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, moveStage(s, r, #settled, block)); case null {} } };
      case (#contractClosed(x)) { switch (row(s, x.contract)) { case (?r) putRow(s, moveStage(s, r, #closed, block)); case null {} } };
      case (#nonComplianceRecorded(x)) s.charity += x.amount;
      case (#poolOpened(x)) {
        let w = C.Writer(); for (a in x.pool.incomeAccounts.vals()) w.text(a);
        let h = Blob.toArray(Sha256.fromBlob(#sha256, w.toBlob()));
        putPool(s, { id = x.pool.id; currency = x.pool.currency; product = x.pool.product; mudaribBps = x.pool.mudaribBps; perBps = x.pool.perBps; irrBps = x.pool.irrBps; distributions = 0; lastPeriod = ""; perBalance = 0; irrBalance = 0; incomeAccountsHash = Blob.fromArray(Array.tabulate<Nat8>(16, func(i) { h[i] })); openedBlock = block });
        holdSub(s, poolSub(x.pool.id));
      };
      case (#poolDistributed(x)) {
        let d = x.distribution;
        ignore RI.put(s.distributions, distKey(d.pool, d.period), encodeDistribution({ pool = d.pool; period = d.period; from = d.from; to = d.to; income = d.income; per = d.per; mudaribShare = d.mudaribShare; holdersShare = d.holdersShare; irr = d.irr; paid = d.paid; block }));
        switch (pool(s, d.pool)) { case (?p) putPool(s, { p with distributions = p.distributions + 1; lastPeriod = d.period; perBalance = p.perBalance + d.per; irrBalance = p.irrBalance + d.irr }); case null {} };
        s.distributionsTotal += 1;
      };
      case (#reserveUpdated(x)) { switch (pool(s, x.pool)) { case (?p) putPool(s, { p with perBps = switch (x.per) { case (?b) b; case null p.perBps }; irrBps = switch (x.irr) { case (?b) b; case null p.irrBps } }); case null {} } };
    }
  };
  /// The period between two due days, read back from a schedule.
  func periodOf(d0 : Nat, d1 : Nat) : ProdT.Period {
    let gap = if (d1 > d0) d1 - d0 else 0;
    if (gap <= 1) #daily else if (gap <= 31) #monthly else if (gap <= 92) #quarterly else if (gap <= 184) #semiAnnual else #annual
  };

  // ─── reads ────────────────────────────────────────────────────────────────

  public func view(r : ContractRow) : IT.ContractView {
    {
      id = r.id; kind = kindTextOf(r.kind); stage = IT.stageText(r.stage); party = r.party; account = r.account; currency = r.currency; book = r.book;
      principal = r.principal; profitTotal = r.profitTotal; profitRecognised = r.profitRecognised; collected = r.collected; outstanding = outstanding(r);
      openedDay = r.openedDay; nextDue = if (r.nextDue == 0) null else ?r.nextDue; instalmentsDue = r.instalmentsDue; instalmentsPaid = r.instalmentsPaid; units = r.units; unitsLeft = r.unitsLeft; percentComplete = r.percentBps; lastBlock = r.lastBlock;
    }
  };
  public func poolView(_s : State, p : PoolRow, incomeAccounts : [Text]) : IT.PoolView {
    { pool = { id = p.id; currency = p.currency; mudaribBps = p.mudaribBps; perBps = p.perBps; irrBps = p.irrBps; product = p.product; incomeAccounts }; distributions = p.distributions; lastPeriod = p.lastPeriod; perBalance = p.perBalance; irrBalance = p.irrBalance }
  };
  public func listByParty(s : State, party : PT.PartyId, cursor : ?Blob, limit : Nat) : { ids : [IT.ContractId]; cursor : ?Blob } {
    let (lo, hi) = R.prefixRange(party, 8, 8);
    let page = RI.range(s.byParty, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    { ids = Array.map<(Blob, Blob), Nat>(page.entries, func((k, _)) { R.getNat(Blob.toArray(k), 8, 8) }); cursor = page.cursor }
  };
  public func listByStage(s : State, stage : IT.Stage, cursor : ?Blob, limit : Nat) : { ids : [IT.ContractId]; cursor : ?Blob } {
    let (lo, hi) = R.prefixRange(Nat8.toNat(stageCode(stage)), 1, 8);
    let page = RI.range(s.byStage, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    let out = List.empty<Nat>();
    for ((k, _) in page.entries.vals()) { let id = R.getNat(Blob.toArray(k), 1, 8); switch (row(s, id)) { case (?r) { if (r.stage == stage) List.add(out, id) }; case null {} } };
    { ids = List.toArray(out); cursor = page.cursor }
  };
  /// Every open contract; what the batch walks.
  public func openAll(s : State) : [ContractRow] {
    let out = List.empty<ContractRow>();
    for (st in [#opened, #acquired, #sold, #running, #delivered].vals()) {
      let (lo, hi) = R.prefixRange(Nat8.toNat(stageCode(st)), 1, 8);
      var cursor : ?Blob = null;
      label walk loop {
        let page = RI.range(s.byStage, lo, hi, cursor, MAX_PAGE);
        for ((k, _) in page.entries.vals()) { let id = R.getNat(Blob.toArray(k), 1, 8); switch (row(s, id)) { case (?r) { if (r.stage == st) List.add(out, r) }; case null {} } };
        switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
      };
    };
    List.toArray(out)
  };
  func bookKey(book : Text, id : Nat) : Blob { Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.textKey(book, 32)), Blob.toArray(R.key(id, 8)))) };
  public func bookCursor(book : Text, id : Nat) : Blob { bookKey(book, id) };
  /// The open contracts of a book, one page off the book index from a cursor (`bookCursor(book, id)` to resume at an id):
  /// what the end-of-day walks a chunk at a time (the adversarial audit of 13 September, finding A2).
  public func openInBookFrom(s : State, book : Text, cursor : ?Blob, limit : Nat) : { ids : [IT.ContractId]; cursor : ?Blob } {
    let lo = bookKey(book, 0);
    let hi = Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.textKey(book, 32)), Array.repeat<Nat8>(255, 8)));
    let page = RI.range(s.byBook, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    let out = List.empty<Nat>();
    for ((k, _) in page.entries.vals()) { let id = R.getNat(Blob.toArray(k), 32, 8); switch (row(s, id)) { case (?r) { if (isOpen(r)) List.add(out, id) }; case null {} } };
    { ids = List.toArray(out); cursor = page.cursor }
  };
  public func openInBook(s : State, book : Text) : [ContractRow] { Array.filter<ContractRow>(openAll(s), func(r) { Text.equal(r.book, book) }) };
  public func pools(s : State) : [PoolRow] {
    let out = List.empty<PoolRow>();
    let (lo, hi) = R.fullRange(32);
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.pools, lo, hi, cursor, MAX_PAGE);
      for ((_, v) in page.entries.vals()) List.add(out, decodePool(v));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  /// One page of a pool's distributions off the distribution store from a cursor.
  public func distributionsOfFrom(s : State, poolId : IT.PoolId, cursor : ?Blob, limit : Nat) : { rows : [DistributionRow]; cursor : ?Blob } {
    let lo = distKey(poolId, ""); let hi = Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.textKey(poolId, 32)), Array.repeat<Nat8>(255, 8)));
    let page = RI.range(s.distributions, lo, hi, cursor, Nat.min(limit, MAX_PAGE));
    let rows = List.empty<DistributionRow>();
    for ((k, v) in page.entries.vals()) List.add(rows, decodeDistribution(poolId, R.getText(Blob.toArray(k), 32, 8), v));
    { rows = List.toArray(rows); cursor = page.cursor }
  };
  public func distributionCount(s : State, poolId : IT.PoolId) : Nat { switch (pool(s, poolId)) { case (?p) p.distributions; case null 0 } };
  public func distributionsOf(s : State, poolId : IT.PoolId) : [DistributionRow] {
    let out = List.empty<DistributionRow>();
    let lo = distKey(poolId, ""); let hi = Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.textKey(poolId, 32)), Array.repeat<Nat8>(255, 8)));
    var cursor : ?Blob = null;
    label walk loop {
      let page = RI.range(s.distributions, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) List.add(out, decodeDistribution(poolId, R.getText(Blob.toArray(k), 32, 8), v));
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    List.toArray(out)
  };
  public func status(s : State) : { contracts : Nat; open : Nat; charity : Nat; distributions : Nat; pools : Nat } {
    { contracts = s.opened; open = s.open; charity = s.charity; distributions = s.distributionsTotal; pools = pools(s).size() }
  };

  // ─── fingerprint ──────────────────────────────────────────────────────────

  func fingerprintRows(w : C.Writer, idx : RI.State, keyWidth : Nat) {
    let (lo, hi) = R.fullRange(keyWidth);
    var cursor : ?Blob = null;
    var n = 0;
    label walk loop {
      let page = RI.range(idx, lo, hi, cursor, MAX_PAGE);
      for ((k, v) in page.entries.vals()) { w.blob(k); w.blob(v); n += 1 };
      switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
    };
    w.nat(n);
  };
  public func fingerprintInto(w : C.Writer, s : State) {
    w.nat(Map.size(s.openByBook));
    for ((k, v) in Map.entries(s.openByBook)) { w.text(k); w.nat(v) };
    w.nat(Map.size(s.openByCurrency));
    for ((k, v) in Map.entries(s.openByCurrency)) { w.text(k); w.nat(v) };
    switch (s.policy) {
      case null w.byte(0);
      case (?p) {
        w.byte(1);
        for (t in [p.murabahaInventory, p.murabahaReceivable, p.deferredProfit, p.murabahaIncome, p.securityDeposits, p.ijarahAssets, p.accumulatedDepreciation, p.depreciationExpense, p.rentalReceivable, p.ijarahIncome,
                   p.musharakahInvestment, p.musharakahIncome, p.mudarabahInvestment, p.mudarabahIncome, p.investmentLosses, p.salamReceivable, p.salamInventory, p.salamIncome, p.istisnaWip, p.istisnaReceivable, p.istisnaRevenue, p.istisnaCosts,
                   p.iahEquity, p.profitEqualisationReserve, p.investmentRiskReserve, p.profitPayableToHolders, p.mudaribShareIncome, p.profitAttributableToHolders, p.charityPayable, p.nostro].vals()) w.text(t);
        w.nat(p.perCeilingBps); w.nat(p.irrCeilingBps);
      };
    };
    w.nat(s.opened); w.nat(s.open); w.nat(s.charity); w.nat(s.distributionsTotal);
    fingerprintRows(w, s.contracts, 8); fingerprintRows(w, s.instalments, 16); fingerprintRows(w, s.pools, 32); fingerprintRows(w, s.distributions, 40);
    fingerprintRows(w, s.byParty, 16); fingerprintRows(w, s.byBook, 40); fingerprintRows(w, s.byStage, 9); fingerprintRows(w, s.byReference, 8); fingerprintRows(w, s.approvals, 32); fingerprintRows(w, s.shariaBooks, 32); fingerprintRows(w, s.subledgers, 32);
  };
}
