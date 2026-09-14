/// IslamicTypes.mo: Islamic banking (Islamic banking): the Sharia contracts as recorded sequences of acts with their AAOIFI
/// accounting, profit-sharing investment accounts as the bank's funding, and the governance record every contract
/// names.
///
/// A contract is not an interest product under another name: each kind is its own sequence of acts with its own
/// recognition and measurement (AAOIFI FAS 28 Murabaha, FAS 32 Ijarah, FAS 4 Musharakah and Mudarabah, FAS 7 Salam,
/// FAS 10 Istisna'a, FAS 27 investment accounts), and every profit figure is a computation the bank states and an
/// oracle reproduces. Every contract names the Sharia board approval its product was opened under; income found
/// non-compliant moves to charity, never to income.

import ProdT "ProductTypes";
import PT "PartyTypes";

module {

  public type Day = Nat;
  public type Bps = Nat;
  public type ContractId = Nat;     // the bank block index of the contract's opening event
  public type PoolId = Text;

  /// The accounts the Sharia book posts under, and the rules.
  public type Policy = {
    // Murabaha (FAS 28)
    murabahaInventory : Text;        // the asset while the bank owns it
    murabahaReceivable : Text;       // cost plus markup, the customer's deferred price
    deferredProfit : Text;           // the markup not yet recognised (a contra to the receivable)
    murabahaIncome : Text;
    securityDeposits : Text;         // hamish jiddiyah held against a binding promise
    // Ijarah (FAS 32)
    ijarahAssets : Text;
    accumulatedDepreciation : Text;
    depreciationExpense : Text;
    rentalReceivable : Text;
    ijarahIncome : Text;
    // Musharakah and Mudarabah (FAS 4)
    musharakahInvestment : Text;
    musharakahIncome : Text;
    mudarabahInvestment : Text;
    mudarabahIncome : Text;
    investmentLosses : Text;
    // Salam (FAS 7) and Istisna'a (FAS 10)
    salamReceivable : Text;          // the commodity due, at the price advanced
    salamInventory : Text;
    salamIncome : Text;
    istisnaWip : Text;               // work in progress at cost plus recognised profit
    istisnaReceivable : Text;
    istisnaRevenue : Text;
    istisnaCosts : Text;
    // investment accounts (FAS 27)
    iahEquity : Text;                // equity of unrestricted investment account holders: the pool's principal
    profitEqualisationReserve : Text;
    investmentRiskReserve : Text;
    profitPayableToHolders : Text;
    mudaribShareIncome : Text;       // the bank's share as mudarib
    profitAttributableToHolders : Text; // the expense the distribution charges: what the holders and the reserves receive
    // governance
    charityPayable : Text;           // non-compliant income and late-payment amounts
    nostro : Text;                   // suppliers, contractors and counterparties paid across the correspondent account
    perCeilingBps : Bps;             // the most of the pool's income PER may take
    irrCeilingBps : Bps;             // the most of the holders' share IRR may take
  };

  /// The Sharia board's approval a product is opened under: the reference and the hash of the resolution.
  public type BoardApproval = { ref : Text; sha256 : Blob };

  public type ProfitMethod = { #proportionate; #effectiveRate };
  public func profitMethodText(m : ProfitMethod) : Text { switch (m) { case (#proportionate) "proportionate"; case (#effectiveRate) "effectiveRate" } };
  public type Promise = { #binding; #nonBinding };
  public type Transfer = { #gift; #sale : { price : Nat }; #gradual : { units : Nat } };
  public type Counterparty = { #party : { party : PT.PartyId; account : ProdT.AccountId }; #external : { name : Text; reference : Text } };

  public type Murabaha = {
    customer : PT.PartyId; account : ProdT.AccountId;
    asset : Text; supplier : Counterparty;
    costPrice : Nat; markup : Nat;               // the selling price is cost plus markup
    instalments : Nat; every : ProdT.Period;     // equal instalments of the selling price
    method : ProfitMethod; promise : Promise; securityDeposit : Nat;
    latePaymentCharityBps : Bps;                 // per annum on the overdue instalment, to charity
    reference : Text;
  };
  public type Ijarah = {
    lessee : PT.PartyId; account : ProdT.AccountId;
    asset : Text; cost : Nat; usefulLifeMonths : Nat; residual : Nat;
    rental : Nat; every : ProdT.Period; periods : Nat;
    transfer : ?Transfer;                        // Ijarah Muntahia Bittamleek when set
    reference : Text;
  };
  public type Partner = { party : PT.PartyId; account : ProdT.AccountId; capital : Nat; profitBps : Bps };
  public type Musharakah = {
    partners : [Partner];                        // the bank's own share is what the contract's capital less the partners' covers
    bankCapital : Nat; bankProfitBps : Bps;
    diminishing : ?{ units : Nat; unitPrice : Nat; every : ProdT.Period; rentalBps : Bps };   // the bank's units sold on a schedule, rental on the share kept
    reference : Text;
  };
  public type Mudarabah = {
    mudarib : PT.PartyId; account : ProdT.AccountId;
    capital : Nat; bankProfitBps : Bps;          // rabb al-mal's share of profit; losses are the capital's alone
    term : Nat;                                  // days
    reference : Text;
  };
  public type Salam = {
    seller : PT.PartyId; account : ProdT.AccountId;
    commodity : Text; quantity : Nat; unit : Text; delivery : Day; priceAdvanced : Nat;
    reference : Text;
  };
  public type Istisna = {
    customer : PT.PartyId; account : ProdT.AccountId;
    specification : Blob;                        // SHA-256 of the specification
    price : Nat; estimatedCost : Nat;
    milestones : [(Day, Bps)];                   // the cumulative percentage of completion due at each day
    contractor : Counterparty;
    reference : Text;
  };
  public type Kind = { #murabaha : Murabaha; #ijarah : Ijarah; #musharakah : Musharakah; #mudarabah : Mudarabah; #salam : Salam; #istisna : Istisna };
  public func kindText(k : Kind) : Text { switch (k) { case (#murabaha(_)) "murabaha"; case (#ijarah(_)) "ijarah"; case (#musharakah(_)) "musharakah"; case (#mudarabah(_)) "mudarabah"; case (#salam(_)) "salam"; case (#istisna(_)) "istisna" } };

  public type Stage = { #opened; #acquired; #sold; #running; #delivered; #settled; #closed; #defaulted };
  public func stageText(s : Stage) : Text { switch (s) { case (#opened) "opened"; case (#acquired) "acquired"; case (#sold) "sold"; case (#running) "running"; case (#delivered) "delivered"; case (#settled) "settled"; case (#closed) "closed"; case (#defaulted) "defaulted" } };

  /// An investment account pool (FAS 27): unrestricted, the bank as mudarib.
  public type Pool = { id : PoolId; currency : Text; mudaribBps : Bps; perBps : Bps; irrBps : Bps; product : ProdT.ProductId; incomeAccounts : [Text] };
  /// A month's distribution, every figure stated.
  public type Distribution = {
    pool : PoolId; period : Text; from : Day; to : Day;
    income : Nat;                                // the pool's income over the period, from the named income accounts
    per : Nat;                                   // taken before the split
    distributable : Nat;                         // income less PER
    mudaribShare : Nat;                          // the bank's
    holdersShare : Nat;                          // before IRR
    irr : Nat;                                   // taken from the holders' share
    paid : Nat;                                  // what the holders receive
    weightedBalances : [(ProdT.AccountId, Nat)]; // Σ daily balances per account over the period
    allocations : [(ProdT.AccountId, Nat)];      // each holder's part of `paid`
  };

  public type IslamicEvent = {
    #policySet : Policy;
    #productApproved : { product : ProdT.ProductId; approval : BoardApproval; day : Day };
    #bookFlagged : { book : Text; sharia : Bool; day : Day };
    #contractOpened : { kind : Kind; currency : Text; book : Text; day : Day };
    #assetAcquired : { contract : ContractId; cost : Nat; day : Day };                                   // Murabaha: the bank owns the asset
    #murabahaSold : { contract : ContractId; sellingPrice : Nat; deferredProfit : Nat; schedule : [(Day, Nat)]; day : Day };
    #instalmentCollected : { contract : ContractId; amount : Nat; principal : Nat; profit : Nat; day : Day };
    #profitRecognised : { contract : ContractId; amount : Nat; cumulative : Nat; day : Day };
    #rebateGranted : { contract : ContractId; amount : Nat; reason : Text; day : Day };                  // ibra', discretionary
    #latePaymentToCharity : { contract : ContractId; instalment : Nat; amount : Nat; cumulative : Nat; day : Day };
    #leaseCommenced : { contract : ContractId; day : Day };
    #rentalAccrued : { contract : ContractId; amount : Nat; period : Nat; day : Day };
    #rentalCollected : { contract : ContractId; amount : Nat; day : Day };
    #depreciationPosted : { contract : ContractId; amount : Nat; cumulative : Nat; day : Day };
    #ownershipTransferred : { contract : ContractId; how : Transfer; consideration : Nat; day : Day };
    #capitalContributed : { contract : ContractId; party : ?PT.PartyId; amount : Nat; day : Day };       // null: the bank's
    #profitDistributed : { contract : ContractId; profit : Nat; bankShare : Nat; partnerShares : [(PT.PartyId, Nat)]; day : Day };
    #lossAllocated : { contract : ContractId; loss : Nat; bankShare : Nat; partnerShares : [(PT.PartyId, Nat)]; day : Day };
    #unitBought : { contract : ContractId; units : Nat; price : Nat; bankUnitsLeft : Nat; day : Day };
    #commodityDelivered : { contract : ContractId; quantity : Nat; day : Day };
    #commoditySold : { contract : ContractId; proceeds : Nat; day : Day };
    #deliveryFailed : { contract : ContractId; recourse : Text; day : Day };
    #milestoneRecorded : { contract : ContractId; certificate : Blob; percentBps : Bps; revenue : Nat; cost : Nat; day : Day };
    #contractSettled : { contract : ContractId; day : Day };
    #contractClosed : { contract : ContractId; reason : Text; day : Day };
    #nonComplianceRecorded : { contract : ?ContractId; amount : Nat; account : Text; reason : Text; day : Day };
    #poolOpened : { pool : Pool; day : Day };
    #poolDistributed : { distribution : Distribution; day : Day };
    #reserveUpdated : { pool : PoolId; per : ?Bps; irr : ?Bps; day : Day };
  };

  public type IslamicError = {
    #NoPolicy;
    #InvalidPolicy : { reason : Text };
    #InvalidTerms : { reason : Text; standard : Text };
    #NoBoardApproval : { product : ProdT.ProductId };
    #InterestOnShariaProduct : { product : ProdT.ProductId };
    #UnknownContract : { contract : ContractId };
    #ContractNotIn : { contract : ContractId; stage : Text; wanted : Text };
    #WrongKind : { contract : ContractId; kind : Text; wanted : Text };
    #LossNotByCapital : { contract : ContractId };
    #ReserveOverCeiling : { pool : PoolId; which : Text; bps : Bps; ceiling : Bps };
    #UnknownPool : { pool : PoolId };
    #PeriodAlreadyDistributed : { pool : PoolId; period : Text };
    #RebateNotDiscretionary : { contract : ContractId };
  };

  public type ContractView = {
    id : ContractId; kind : Text; stage : Text; party : PT.PartyId; account : ProdT.AccountId; currency : Text; book : Text;
    principal : Nat; profitTotal : Nat; profitRecognised : Nat; collected : Nat; outstanding : Nat;
    openedDay : Day; nextDue : ?Day; instalmentsDue : Nat; instalmentsPaid : Nat; units : Nat; unitsLeft : Nat; percentComplete : Bps; lastBlock : Nat;
  };
  public type PoolView = { pool : Pool; distributions : Nat; lastPeriod : Text; perBalance : Nat; irrBalance : Nat };
}
