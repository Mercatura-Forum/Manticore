/// Reconstruct.mo: a settled proposal's command, rebuilt from the events its execution recorded.
///
/// The bank-log ruling of 12 September (measure 1) lets a proposal block's command body be dropped once
/// the act's events are in the log; but only where the command is reconstructible from those events
/// byte for byte, proven rather than asserted: the reconstruction is re-hashed and compared with the
/// `commandHash` the proposal block keeps, and a body whose reconstruction does not hash to it is kept.
/// This module is the reconstruction; `candidates` answers every command the events could have come
/// from (a command can carry a default the event records expanded, an empty allocation order, so
/// more than one command may have produced the same events), and the caller keeps the one that hashes
/// right, or keeps the body when none does.
///
/// What is reconstructed: every command whose event is its own image (the organisation, the party layer,
/// the product catalogue, an account's opening and status), `createCustomer` from the run of events it
/// records, the origination steps whose block is the instruction less what the contract computed (origination and underwriting;
/// an offer's acceptance and a signed document keep their body; the assertion is the evidence), and
/// nothing else; a command whose effect is a journal posting and no bank event, or whose event records
/// a computed figure rather than the instruction, is not here, and its body is carried. The
/// harness (`integration/bank_s28.py`) prints, per command family, how many bodies were dropped and how
/// many carried, so the saving is a measurement.

import Array "mo:core/Array";
import List "mo:core/List";

import T "BankTypes";
import PT "PartyTypes";
import ProdT "ProductTypes";

module {

  /// The bank events an execution recorded, in order (the proposal's act: its first event and the extras).
  public type Act = [T.Event];

  /// Every command the act's events could be the image of, most likely first; empty when the family is
  /// not reconstructed here.
  public func candidates(act : Act) : [T.Command] {
    if (act.size() == 0) return [];
    switch (act[0]) {
      // ── organisation and authority: the event is the command ──
      case (#bookOpened(x)) [#openBook({ id = x.id; name = x.name; parent = x.parent })];
      case (#bookClosed(x)) [#closeBook({ id = x.id })];
      case (#roleDefined(x)) [#defineRole({ id = x.id; name = x.name; permissions = x.permissions })];
      case (#roleGranted(x)) [#grantRole({ subject = x.subject; role = x.role; scope = x.scope })];
      case (#roleRevoked(x)) [#revokeRole({ subject = x.subject; role = x.role })];
      case (#dualPolicySet(p)) [#setDualPolicy(p)];
      case (#dualPolicyCleared(x)) [#clearDualPolicy({ permission = x.permission })];
      case (#bankAdminTransferred(x)) [#transferBankAdmin({ admin = x.admin })];
      case (#featureActivationSet(x)) [#setFeatureActivation({ feature = x.feature; height = x.height })];
      // ── the party layer ──
      case (#party(pe)) {
        // a run beginning with a party created is an onboarding (`createCustomer`); one block alone is
        // either that with nothing else, or `createParty`; both are offered, the hash decides
        switch (pe) {
          case (#partyCreated(x)) {
            let bare = if (act.size() == 1) [#createParty({ kind = x.kind; salt = x.salt; identityCommit = x.identityCommit; dedupCommit = x.dedupCommit; attributes = x.attributes; book = x.book; cddLevel = x.cddLevel; riskRating = x.riskRating; pep = x.pep; reviewDue = x.reviewDue })] else [];
            return Array.concat<T.Command>(bare, customer(act));
          };
          case (_) {};
        };
        if (act.size() > 1) return [];
        switch (pe) {
          case (#partyAmended(x)) [#amendParty({ party = x.party; attributes = x.attributes })];
          case (#partyLifecycleSet(x)) [#setPartyLifecycle({ party = x.party; to = x.to })];
          case (#partyCddSet(x)) [#setPartyCdd({ party = x.party; level = x.level; riskRating = x.riskRating; pep = x.pep; reviewDue = x.reviewDue })];
          case (#partyDocumentAdded(x)) [#addPartyDocument({ party = x.party; document = x.document })];
          case (#partyRelationshipAdded(x)) [#addPartyRelationship({ party = x.party; relationship = x.relationship })];
          case (#partyExtensionSet(x)) [#setPartyExtension({ party = x.party; values = x.values })];
          case (#screeningListCommitted(x)) [#commitScreeningList({ version = x.version; root = x.root; count = x.count; normalisation = x.normalisation })];
          case (#screeningDecisionRecorded(d)) [#recordScreeningDecision(d)];
          case (#schemaRegistered(x)) [#registerSchema({ id = x.id; entity = x.entity; fields = x.fields })];
          case (#collateralRegistered(x)) [#registerCollateral({ party = x.party; kind = x.kind; valuation = x.valuation; descriptionCommit = x.descriptionCommit })];
          case (#collateralRevalued(x)) [#revalueCollateral({ collateral = x.collateral; valuation = x.valuation })];
          case (#collateralAllocated(x)) [#allocateCollateral({ collateral = x.collateral; facility = x.facility; amount = x.amount })];
          case (#collateralReleased(x)) [#releaseCollateral({ collateral = x.collateral })];
          case (#staffAdded(x)) [#addStaff({ principal_ = x.principal_; book = x.book; title = x.title })];
          case (#staffRemoved(x)) [#removeStaff({ principal_ = x.principal_ })];
          case (#accountFormatSet(f)) [#setAccountFormat(f)];
          case (#reviewGraceSet(x)) [#setReviewGrace({ days = x.days })];
          case (_) [];
        }
      };
      // ── the product catalogue and accounts ──
      case (#product(pe)) {
        switch (pe) {
          case (#productRegistered(x)) [#registerProduct({ id = x.id; name = x.name; terms = x.terms })];
          case (#productAmended(x)) [#amendProduct({ id = x.id; name = x.name; terms = x.terms })];
          case (#productClosedToNewAccounts(x)) [#closeProductToNewAccounts({ id = x.id; version = x.version })];
          case (#accountOpened(o)) {
            // an opening followed by its activation and a fulfilment block is an application drawn (origination and underwriting):
            // the command names the application and nothing else
            if (act.size() == 3) {
              switch (act[1], act[2]) {
                case (#product(#accountStatusSet(_)), #origination(#fulfilled(f))) return [#fulfilApplication({ application = f.application })];
                case (_, _) {};
              };
            };
            if (act.size() > 1) return [];
            Array.map<[ProdT.Component], T.Command>(orders(o.allocationOrder), func(order) {
              #openAccount({ product = o.product; party = o.party; currency = o.currency; termDays = termOf(o); allocationOrder = order })
            })
          };
          case (#accountStatusSet(x)) [#setAccountStatus({ account = x.account; to = x.to })];
          case (#accountMigrated(x)) [#migrateAccount({ account = x.account; to = x.to })];
          case (#tillOpened(x)) [#openTill({ till = x.till; book = x.book; currency = x.currency; holder = x.holder; product = x.product })];
          case (_) [];
        }
      };
      // ── origination (origination and underwriting): the recorded step is the command, less what the contract computed ──
      case (#origination(oe)) {
        switch (oe) {
          case (#policySet(p)) { if (act.size() > 1) [] else [#setOriginationPolicy(p)] };
          case (#affordabilityModelSet(m)) { if (act.size() > 1) [] else [#setAffordabilityModel(m)] };
          case (#scorecardSet(c)) { if (act.size() > 1) [] else [#setScorecard(c)] };
          case (#passkeyRegistered(x)) { if (act.size() > 1) [] else [#registerPasskey({ party = x.party; credentialId = x.credentialId; publicKeySpki = x.publicKeySpki })] };
          case (#applicationOpened(x)) { if (act.size() > 1) [] else [#openApplication({ party = x.party; book = x.book; request = x.request; channel = x.channel })] };
          case (#dataRecorded(x)) { if (act.size() > 1) [] else [#recordApplicationData({ application = x.application; facts = x.facts; commitments = x.commitments })] };
          case (#affordabilityAssessed(x)) { if (act.size() > 1) [] else [#assessAffordability({ application = x.application })] };
          case (#bureauRequested(x)) { if (act.size() > 1) [] else [#requestBureauReport({ application = x.application; bureau = x.bureau; consentCommit = x.consentCommit })] };
          case (#scored(x)) { if (act.size() > 1) [] else [#scoreApplication({ application = x.application })] };
          case (#underwritten(x)) { if (act.size() > 1) [] else [#underwrite({ application = x.application; decision = x.decision; rationale = x.rationale })] };
          case (#offerIssued(x)) { if (act.size() > 1) [] else [#issueOffer({ application = x.application; terms = x.terms })] };
          case (#offerDeclined(x)) { if (act.size() > 1) [] else [#declineOffer({ application = x.application })] };
          // an unsigned document is its block's image; a signed one carries the assertion only in the body
          case (#documentRecorded(x)) { if (x.signed or not completion(act)) [] else [#recordDocument({ application = x.application; kind = x.kind; sha256 = x.sha256; signed = null })] };
          case (#conditionsMet(x)) { if (completion(act)) [#recordConditionsMet({ application = x.application; conditions = x.conditions })] else [] };
          case (#withdrawn(x)) { if (act.size() > 1) [] else [#withdrawApplication({ application = x.application; reason = x.reason })] };
          case (_) [];
        }
      };
      // ── corporate lending (corporate lending): the decisions whose block is the instruction less what the contract computed ──
      case (#facility(fe)) {
        if (act.size() > 1) return [];
        switch (fe) {
          case (#facilityOpened(x)) [#openFacility(x.terms)];
          case (#participationTransferred(x)) [#transferParticipation({ facility = x.facility; from = x.from; to = x.to; bps = x.bps })];
          case (#covenantTested(x)) [#recordCovenantTest({ facility = x.facility; covenant = x.covenant; value = x.value; statementHash = x.statementHash })];
          case (#drawdownsBlocked(x)) [#blockDrawdowns({ facility = x.facility; reason = x.reason })];
          case (#drawdownsUnblocked(x)) [#unblockDrawdowns({ facility = x.facility; reason = x.reason })];
          case (#reviewRecorded(x)) [#recordFacilityReview({ facility = x.facility; note = x.note })];
          case (#rateFixingRecorded(x)) [#recordRateFixing({ index = x.index; day = x.day; rateBps = x.rateBps })];
          case (#facilityClosed(x)) [#closeFacility({ facility = x.facility })];
          case (_) [];
        }
      };
      // ── branch and teller (branch and teller): the decisions and records whose block is the instruction less what was read ──
      case (#teller(te)) {
        if (act.size() > 1) return [];
        switch (te) {
          case (#policySet(p)) [#setTellerPolicy(p)];
          case (#sessionOpened(x)) [#openTellerSession({ till = x.till; teller = x.teller; opening = x.opening })];
          case (#sessionClosed(x)) [#closeTellerSession({ till = x.till; closing = x.closing })];
          case (#chequebookIssued(x)) [#issueChequebook({ account = x.account; from = x.from; to = x.to })];
          case (#chequeStopped(x)) [#stopCheque({ account = x.account; serial = x.serial; reason = x.reason })];
          case (_) [];
        }
      };
      // ── trade finance (trade finance): the records whose block carries the instruction whole ──
      case (#trade(tr)) {
        if (act.size() > 1) return [];
        switch (tr) {
          case (#policySet(p)) [#setTradePolicy(p)];
          case (#documentsPresented(x)) [#presentDocuments({ instrument = x.instrument; documents = x.documents; amount = x.amount; shipmentDate = x.shipmentDate; presentedOn = x.presentedOn })];
          case (#presentationExamined(x)) [#examinePresentation({ instrument = x.instrument; claim = x.claim; checks = x.checks; decision = x.decision })];
          case (#discrepanciesWaived(x)) [#waiveDiscrepancies({ instrument = x.instrument; claim = x.claim; applicantConsentHash = x.applicantConsentHash })];
          case (#demandRecorded(x)) [#recordDemand({ instrument = x.instrument; demand = x.demand; amount = x.amount; supportingStatement = x.supportingStatement; presentedOn = x.presentedOn })];
          case (#collectionPresented(x)) [#presentCollection({ instrument = x.instrument; presentedOn = x.presentedOn })];
          case (#collectionAccepted(x)) [#acceptCollection({ instrument = x.instrument })];
          case (#collectionProtested(x)) [#protestCollection({ instrument = x.instrument; reason = x.reason })];
          case (#tradeMessageRecorded(x)) [#recordTradeMessage({ instrument = x.instrument; kind = x.kind; direction = x.direction; hash = x.hash })];
          case (_) [];
        }
      };
      // ── Islamic banking (Islamic banking): the records whose block carries the instruction whole ──
      case (#islamic(ie)) {
        if (act.size() > 1) return [];
        switch (ie) {
          case (#policySet(p)) [#setIslamicPolicy(p)];
          case (#productApproved(x)) [#approveShariaProduct({ product = x.product; approval = x.approval })];
          case (#bookFlagged(x)) [#flagShariaBook({ book = x.book; sharia = x.sharia })];
          case (#contractClosed(x)) [#closeShariaContract({ contract = x.contract; reason = x.reason })];
          case (#poolOpened(x)) [#openInvestmentPool({ pool = x.pool })];
          case (#reserveUpdated(x)) [#updatePoolReserves({ pool = x.pool; per = x.per; irr = x.irr })];
          case (_) [];
        }
      };
      // ── treasury (treasury): the configuration whose block carries the instruction whole ──
      case (#treasury(te)) {
        if (act.size() > 1) return [];
        switch (te) {
          case (#policySet(p)) [#setTreasuryPolicy(p)];
          case (#securityRegistered(x)) [#registerSecurity({ terms = x.terms })];
          case (#curvePublished(x)) [#publishCurve({ curve = x.curve })];
          case (#limitSet(x)) [#setTreasuryLimit({ limit = x.limit })];
          case (#nostroRegistered(x)) [#registerNostro({ nostro = x.nostro })];
          case (#dealCancelled(x)) [#cancelDeal({ deal = x.deal; reason = x.reason })];
          case (_) [];
        }
      };
      // ── cards (cards): the configuration and the record-only lifecycle acts whose block carries the instruction whole ──
      // ── the close layer's currency acts (S4.1): the event carries the instruction; a redenomination's act is the
      // declaration followed by one product re-versioning per product of the currency
      case (#close(#currencyCalendarSet(x))) { if (act.size() > 1) return []; [#setCurrencyCalendar({ currency = x.currency; calendar = x.calendar })] };
      case (#close(#redenominationDeclared(x))) {
        var i = 1;
        while (i < act.size()) { switch (act[i]) { case (#product(#productRedenominated(_))) {}; case (_) return [] }; i += 1 };
        [#redenominateCurrency(x.redenomination)]
      };
      case (#card(ce)) {
        if (act.size() > 1) return [];
        switch (ce) {
          case (#policySet(p)) [#setCardPolicy(p)];
          case (#schemeDeclared(x)) [#declareCardScheme({ scheme = x.scheme })];
          case (#productDefined(x)) [#defineCardProduct({ product = x.product })];
          case (#cardActivated(x)) [#activateCard({ card = x.card })];
          case (#cardBlocked(x)) [#blockCard({ card = x.card; reason = x.reason })];
          case (#cardUnblocked(x)) [#unblockCard({ card = x.card })];
          case (#cardClosed(x)) [#closeCard({ card = x.card; reason = x.reason })];
          case (#controlsSet(x)) [#setCardControls({ card = x.card; controls = x.controls; byCustomer = x.byCustomer })];
          case (#disputeOpened(x)) [#openDispute({ transaction = x.transaction; reason = x.reason; amount = x.amount })];
          case (#preArbitrationRecorded(x)) [#recordPreArbitration({ dispute = x.dispute })];
          case (#fraudMarked(x)) [#markFraud({ transaction = x.transaction; blockCard = x.blocked })];
          case (_) [];
        }
      };
      case (_) [];
    }
  };

  /// A documentation act is one block, or two when it completed the documentation.
  func completion(act : Act) : Bool {
    switch (act.size()) {
      case 1 true;
      case 2 { switch (act[1]) { case (#origination(#documentationComplete(_))) true; case (_) false } };
      case _ false;
    }
  };

  /// An opening's term in days, from its maturity; an account without a maturity had no term.
  func termOf(o : { opened : ProdT.Day; maturity : ?ProdT.Day }) : ?Nat {
    switch (o.maturity) { case (?m) { if (m >= o.opened) ?(m - o.opened) else null }; case null null }
  };

  /// The allocation orders a recorded order could have come from: the order itself, and; when it is
  /// the default; the empty list the command may have carried.
  func orders(recorded : [ProdT.Component]) : [[ProdT.Component]] {
    if (recorded == DEFAULT_ORDER) [[], recorded] else [recorded]
  };
  let DEFAULT_ORDER : [ProdT.Component] = [#penalty, #fee, #interest, #principal];

  /// `createCustomer` from its run: the party created, then pendingKyc, the documents, the decision,
  /// active, the extension, and per account its opening and (when present) its activation; in the
  /// order `BankCore.planCreateCustomer` records them. Every account's allocation order doubles the
  /// candidates when it is the default; the caller keeps the one that hashes right.
  func customer(act : Act) : [T.Command] {
    let #party(#partyCreated(p)) = act[0] else return [];
    var i = 1;
    var lifecycle : PT.Lifecycle = #prospect;
    if (i < act.size()) { switch (act[i]) { case (#party(#partyLifecycleSet(x))) { if (x.to == #pendingKyc) { lifecycle := #pendingKyc; i += 1 } }; case (_) {} } };
    let docs = List.empty<PT.DocumentRef>();
    label d while (i < act.size()) { switch (act[i]) { case (#party(#partyDocumentAdded(x))) { List.add(docs, x.document); i += 1 }; case (_) break d } };
    var screening : ?T.CustomerScreening = null;
    if (i < act.size()) { switch (act[i]) { case (#party(#screeningDecisionRecorded(s))) { screening := ?{ listVersion = s.listVersion; listRoot = s.listRoot; decision = s.decision; screener = s.screener; justificationCommit = s.justificationCommit }; i += 1 }; case (_) {} } };
    if (i < act.size()) { switch (act[i]) { case (#party(#partyLifecycleSet(x))) { if (x.to == #active) { lifecycle := #active; i += 1 } }; case (_) {} } };
    var extensions : [PT.ExtensionValue] = [];
    if (i < act.size()) { switch (act[i]) { case (#party(#partyExtensionSet(x))) { extensions := x.values; i += 1 }; case (_) {} } };
    // the accounts: each opening, optionally followed by its activation; every recorded order may be
    // the default written for an empty one, so the candidates multiply
    var variants : [[T.CustomerAccount]] = [[]];
    var application : ?Nat = null;
    label accounts while (i < act.size()) {
      // the onboarding may end by naming the prospect's application it fulfils (origination and underwriting)
      switch (act[i]) {
        case (#origination(#prospectOnboarded(x))) { if (i + 1 != act.size()) return []; application := ?x.application; i += 1; break accounts };
        case (_) {};
      };
      let #product(#accountOpened(o)) = act[i] else return [];
      i += 1;
      var activate = false;
      if (i < act.size()) { switch (act[i]) { case (#product(#accountStatusSet(x))) { if (x.to == #active) { activate := true; i += 1 } }; case (_) {} } };
      let next = List.empty<[T.CustomerAccount]>();
      for (v in variants.vals()) {
        for (order in orders(o.allocationOrder).vals()) {
          List.add(next, Array.concat<T.CustomerAccount>(v, [{ product = o.product; currency = o.currency; termDays = termOf(o); allocationOrder = order; activate }]));
        };
      };
      variants := List.toArray(next);
      if (variants.size() > 64) return [];   // more defaults than any onboarding carries; the body is kept
    };
    let party = { kind = p.kind; salt = p.salt; identityCommit = p.identityCommit; dedupCommit = p.dedupCommit; attributes = p.attributes; book = p.book; cddLevel = p.cddLevel; riskRating = p.riskRating; pep = p.pep; reviewDue = p.reviewDue };
    Array.map<[T.CustomerAccount], T.Command>(variants, func(accounts) {
      #createCustomer({ party; documents = List.toArray(docs); screening; lifecycle; extensions; accounts; application })
    })
  };

  /// The names of the command families this module reconstructs, for the harness's table.
  public func families() : [Text] {
    ["openBook", "closeBook", "defineRole", "grantRole", "revokeRole", "setDualPolicy", "clearDualPolicy", "transferBankAdmin", "setFeatureActivation",
     "createParty", "amendParty", "setPartyLifecycle", "setPartyCdd", "addPartyDocument", "addPartyRelationship", "setPartyExtension", "commitScreeningList",
     "recordScreeningDecision", "registerSchema", "registerCollateral", "revalueCollateral", "allocateCollateral", "releaseCollateral", "addStaff", "removeStaff",
     "setAccountFormat", "setReviewGrace", "registerProduct", "amendProduct", "closeProductToNewAccounts", "openAccount", "setAccountStatus", "migrateAccount", "openTill", "createCustomer",
     "setOriginationPolicy", "setAffordabilityModel", "setScorecard", "registerPasskey", "openApplication", "recordApplicationData", "assessAffordability", "requestBureauReport",
     "scoreApplication", "underwrite", "issueOffer", "declineOffer", "recordDocument", "recordConditionsMet", "fulfilApplication", "withdrawApplication",
     "openFacility", "transferParticipation", "recordCovenantTest", "blockDrawdowns", "unblockDrawdowns", "recordFacilityReview", "recordRateFixing", "closeFacility",
     "setTellerPolicy", "openTellerSession", "closeTellerSession", "issueChequebook", "stopCheque",
     "setTradePolicy", "presentDocuments", "examinePresentation", "waiveDiscrepancies", "recordDemand", "presentCollection", "acceptCollection", "protestCollection", "recordTradeMessage",
     "setIslamicPolicy", "approveShariaProduct", "flagShariaBook", "closeShariaContract", "openInvestmentPool", "updatePoolReserves",
     "setTreasuryPolicy", "registerSecurity", "publishCurve", "setTreasuryLimit", "registerNostro", "cancelDeal",
     "setCardPolicy", "declareCardScheme", "defineCardProduct", "activateCard", "blockCard", "unblockCard", "closeCard", "setCardControls", "openDispute", "recordPreArbitration", "markFraud",
     "setCurrencyCalendar", "redenominateCurrency"]
  };
}
