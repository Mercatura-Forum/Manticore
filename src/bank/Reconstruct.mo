/// Reconstruct.mo — a settled proposal's command, rebuilt from the events its execution recorded.
///
/// The bank-log ruling of 12 September (measure 1) lets a proposal block's command body be dropped once
/// the act's events are in the log — but only where the command is reconstructible from those events
/// byte for byte, proven rather than asserted: the reconstruction is re-hashed and compared with the
/// `commandHash` the proposal block keeps, and a body whose reconstruction does not hash to it is kept.
/// This module is the reconstruction; `candidates` answers every command the events could have come
/// from (a command can carry a default the event records expanded — an empty allocation order — so
/// more than one command may have produced the same events), and the caller keeps the one that hashes
/// right, or keeps the body when none does.
///
/// What is reconstructed: every command whose event is its own image (the organisation, the party layer,
/// the product catalogue, an account's opening and status), `createCustomer` from the run of events it
/// records, and nothing else — a command whose effect is a journal posting and no bank event, or whose
/// event records a computed figure rather than the instruction, is not here, and its body is carried. The
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
        // either that with nothing else, or `createParty` — both are offered, the hash decides
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
      case (_) [];
    }
  };

  /// An opening's term in days, from its maturity; an account without a maturity had no term.
  func termOf(o : { opened : ProdT.Day; maturity : ?ProdT.Day }) : ?Nat {
    switch (o.maturity) { case (?m) { if (m >= o.opened) ?(m - o.opened) else null }; case null null }
  };

  /// The allocation orders a recorded order could have come from: the order itself, and — when it is
  /// the default — the empty list the command may have carried.
  func orders(recorded : [ProdT.Component]) : [[ProdT.Component]] {
    if (recorded == DEFAULT_ORDER) [[], recorded] else [recorded]
  };
  let DEFAULT_ORDER : [ProdT.Component] = [#penalty, #fee, #interest, #principal];

  /// `createCustomer` from its run: the party created, then pendingKyc, the documents, the decision,
  /// active, the extension, and per account its opening and (when present) its activation — in the
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
    while (i < act.size()) {
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
      #createCustomer({ party; documents = List.toArray(docs); screening; lifecycle; extensions; accounts })
    })
  };

  /// The names of the command families this module reconstructs, for the harness's table.
  public func families() : [Text] {
    ["openBook", "closeBook", "defineRole", "grantRole", "revokeRole", "setDualPolicy", "clearDualPolicy", "transferBankAdmin", "setFeatureActivation",
     "createParty", "amendParty", "setPartyLifecycle", "setPartyCdd", "addPartyDocument", "addPartyRelationship", "setPartyExtension", "commitScreeningList",
     "recordScreeningDecision", "registerSchema", "registerCollateral", "revalueCollateral", "allocateCollateral", "releaseCollateral", "addStaff", "removeStaff",
     "setAccountFormat", "setReviewGrace", "registerProduct", "amendProduct", "closeProductToNewAccounts", "openAccount", "setAccountStatus", "migrateAccount", "openTill", "createCustomer"]
  };
}
