/// Permissions.mo — the permission catalogue.
///
/// Apache Fineract carries 960 permission rows in a table. A hand-maintained
/// catalogue drifts from the code, and the drift is invisible until someone
/// finds the method nobody protected. So this catalogue is the single authority
/// and two checks keep it honest:
///
///   1. `tools/permission_audit.py` reads the built Candid interface and the
///      table below and fails the build if any public update method is not
///      guarded, if any `Command` variant has no permission, or if the table
///      names a method or command that does not exist.
///   2. `BankCore` takes the permission identifier as a required argument of
///      its authorisation check. There is no default-allow branch: a method
///      that forgot its permission cannot compile, because there is nothing to
///      pass.
///
/// `moneyMoving` is true when exercising the permission can cause a journal
/// posting. Every money-moving permission is `dualByDefault`, which is the
/// four-eyes rule of proposal entitlements and maker-checker section 1.3; a deployment may raise the
/// requirement with a policy but an operator cannot lower a money-moving
/// permission below dual control without replacing this table, which is a code
/// change and a review.

import Text "mo:core/Text";
import Array "mo:core/Array";

import T "BankTypes";

module {

  func p(id : Text, resource : Text, action : T.Action, guards : T.Guards, moneyMoving : Bool, dual : Bool) : T.Permission {
    { id; resource; action; guards; moneyMoving; dualByDefault = dual }
  };

  /// The catalogue. Order is the order the audit prints; identifiers are unique.
  /// A function rather than a module-level `let` because Motoko requires a
  /// static expression there; `BankCore` builds its lookup map from this once.
  public func catalogue() : [T.Permission] {
    [
    // ── the maker-checker methods themselves ──
    p("command.create", "command", #create, #method("propose"), false, false),
    p("command.approve", "command", #approve, #method("approve"), false, false),
    p("command.reject", "command", #reject, #method("reject"), false, false),
    p("command.perform", "command", #update, #method("perform"), false, false),
    p("command.breakGlass", "command", #breakGlass, #method("emergencyOverride"), true, false),
    p("override.review", "override", #approve, #method("reviewOverride"), false, false),

    // ── entitlements and organisation ──
    p("role.create", "role", #create, #command("defineRole"), false, true),
    p("role.grant", "role", #update, #command("grantRole"), false, true),
    p("role.revoke", "role", #delete, #command("revokeRole"), false, true),
    p("policy.update", "policy", #update, #command("setDualPolicy"), false, true),
    p("policy.delete", "policy", #delete, #command("clearDualPolicy"), false, true),
    p("book.create", "book", #create, #command("openBook"), false, true),
    p("book.close", "book", #close, #command("closeBook"), false, true),
    p("bank.admin.update", "bank", #update, #command("transferBankAdmin"), false, true),

    // ── activation heights: money-visible behaviour ──
    p("feature.activate", "feature", #activate, #command("setFeatureActivation"), true, true),

    // ── the embedded journal's configuration ──
    p("journal.currency.create", "journal.currency", #create, #command("journalRegisterCurrency"), false, true),
    p("journal.account.create", "journal.account", #create, #command("journalOpenAccount"), false, true),
    p("journal.account.close", "journal.account", #close, #command("journalCloseAccount"), false, true),
    p("journal.period.create", "journal.period", #create, #command("journalOpenPeriod"), false, true),
    p("journal.period.close", "journal.period", #close, #command("journalClosePeriod"), false, true),
    p("journal.activation.update", "journal", #activate, #command("journalSetActivationHeight"), true, true),
    p("journal.leadsheet.update", "journal.leadsheet", #update, #command("journalSetLeadsheetSchema"), false, true),
    p("journal.poster.create", "journal.poster", #create, #command("journalAddPoster"), false, true),
    p("journal.poster.delete", "journal.poster", #delete, #command("journalRemovePoster"), false, true),
    p("journal.posterscope.update", "journal.poster", #update, #command("journalSetPosterScope"), false, true),
    p("journal.businessdate.update", "journal", #update, #command("journalRollBusinessDate"), false, true),
    p("journal.calendar.update", "journal.calendar", #update, #command("journalSetCalendar"), false, true),
    p("journal.calendar.authority", "journal.calendar", #update, #command("journalSetCalendarAuthority"), false, true),

    // ── money ──
    p("journal.entry.create", "journal.entry", #create, #command("postManualEntry"), true, true),
    p("journal.entry.reverse", "journal.entry", #reverse, #command("reverseManualEntry"), true, true),
    p("journal.entry.party.create", "journal.entry", #create, #command("postManualEntryForParty"), true, true),

    // ── party / CIF and KYC ──
    p("party.create", "party", #create, #command("createParty"), false, true),
    p("customer.create", "customer", #create, #command("createCustomer"), false, true),
    p("party.update", "party", #update, #command("amendParty"), false, true),
    p("party.lifecycle.update", "party", #activate, #command("setPartyLifecycle"), false, true),
    p("party.cdd.update", "party.cdd", #update, #command("setPartyCdd"), false, true),
    p("party.document.create", "party.document", #create, #command("addPartyDocument"), false, true),
    p("party.relationship.create", "party.relationship", #create, #command("addPartyRelationship"), false, true),
    p("party.extension.update", "party.extension", #update, #command("setPartyExtension"), false, true),
    p("party.identifier.create", "party.identifier", #create, #command("issueIdentifier"), false, true),
    p("screening.list.create", "screening.list", #create, #command("commitScreeningList"), false, true),
    p("screening.prove", "screening", #update, #command("proveScreeningClear"), false, false),
    p("screening.decide", "screening", #approve, #command("recordScreeningDecision"), false, true),
    p("schema.create", "schema", #create, #command("registerSchema"), false, true),
    p("collateral.create", "collateral", #create, #command("registerCollateral"), false, true),
    p("collateral.revalue", "collateral", #update, #command("revalueCollateral"), false, true),
    p("collateral.allocate", "collateral", #activate, #command("allocateCollateral"), false, true),
    p("collateral.release", "collateral", #release, #command("releaseCollateral"), false, true),
    p("staff.create", "staff", #create, #command("addStaff"), false, true),
    p("staff.delete", "staff", #delete, #command("removeStaff"), false, true),
    p("identifier.format.update", "identifier.format", #update, #command("setAccountFormat"), false, true),
    p("party.review.grace.update", "party.review", #update, #command("setReviewGrace"), false, true),
    p("credential.jwks.update", "credential.jwks", #update, #command("pinJwks"), false, true),
    p("credential.create", "credential", #create, #command("registerCredential"), false, true),
    p("credential.delete", "credential", #delete, #command("revokeCredential"), false, true),

    // ── the product engine ──
    // Configuration first: registering a product and opening an account move no
    // money, so they are dual-controlled but not money-moving.
    p("product.create", "product", #create, #command("registerProduct"), false, true),
    p("product.update", "product", #update, #command("amendProduct"), false, true),
    p("product.close", "product", #close, #command("closeProductToNewAccounts"), false, true),
    p("account.create", "account", #create, #command("openAccount"), false, true),
    p("account.status.update", "account", #activate, #command("setAccountStatus"), false, true),
    p("account.migrate", "account", #update, #command("migrateAccount"), false, true),
    p("till.create", "till", #create, #command("openTill"), false, true),
    p("till.close", "till", #close, #command("closeTill"), false, true),
    // Money-visible, therefore money-moving and dual by default. A facility grant
    // is money-moving because it widens what the engine will admit.
    p("account.facility.grant", "account.facility", #activate, #command("grantFacility"), true, true),
    p("account.deposit", "account", #create, #command("depositToAccount"), true, true),
    p("account.withdraw", "account", #update, #command("withdrawFromAccount"), true, true),
    p("account.transfer", "account", #update, #command("transferBetweenAccounts"), true, true),
    p("charge.apply", "charge", #create, #command("applyCharge"), true, true),
    p("charge.waive", "charge", #waive, #command("waiveCharge"), true, true),
    p("interest.accrue", "interest", #create, #command("postAccrual"), true, true),
    p("interest.capitalise", "interest", #update, #command("capitaliseInterest"), true, true),
    p("loan.disburse", "loan", #create, #command("disburseLoan"), true, true),
    p("loan.repay", "loan", #update, #command("repayLoan"), true, true),
    p("loan.reschedule", "loan", #update, #command("rescheduleLoan"), false, true),
    p("loan.provision", "loan.provision", #update, #command("setProvision"), true, true),
    p("loan.writeoff", "loan", #close, #command("writeOffLoan"), true, true),
    p("loan.recovery", "loan", #create, #command("recordRecovery"), true, true),
    p("deposit.redeem", "deposit", #close, #command("redeemTermDeposit"), true, true),
    p("till.allocate", "till", #activate, #command("allocateCashToTill"), true, true),
    p("till.return", "till", #update, #command("returnCashFromTill"), true, true),
    p("till.settle", "till", #approve, #command("settleTill"), true, true),

    // ── value dating, foreign currency and the close ──
    // Configuration declares what the close computes from and moves no money.
    p("fx.functional.update", "fx", #update, #command("setFunctionalCurrency"), false, true),
    p("fx.pair.update", "fx.pair", #update, #command("setFxPair"), false, true),
    p("fx.rate.create", "fx.rate", #create, #command("setFxRate"), false, true),
    p("backvalue.window.update", "backvalue", #update, #command("setBackValueWindow"), false, true),
    p("backvalue.approve", "backvalue", #approve, #command("approveBackValue"), false, true),
    p("deferral.create", "deferral", #create, #command("openDeferralSchedule"), false, true),
    // Money-visible, therefore money-moving and dual by default.
    p("fx.deal.create", "fx.deal", #create, #command("bookFxDeal"), true, true),
    p("fx.realise", "fx", #close, #command("realiseFxPosition"), true, true),
    p("interest.adjust", "interest", #reverse, #command("adjustAccrual"), true, true),
    p("deferral.amortise", "deferral", #update, #command("amortiseDeferral"), true, true),
    // The close. Every step is dual-controlled; the three that post are money-moving.
    p("close.open", "close", #create, #command("openPeriodEnd"), false, true),
    p("close.rates", "close", #update, #command("recordClosingRates"), false, true),
    p("close.accrual", "close", #update, #command("markAccrualComplete"), false, true),
    p("close.revalue", "close", #update, #command("revaluePositions"), true, true),
    p("close.deferrals", "close", #update, #command("amortisePeriodDeferrals"), true, true),
    p("close.reconcile", "close", #approve, #command("reconcilePeriod"), false, true),
    p("close.close", "close", #close, #command("closePeriodEnd"), true, true),
    p("close.yearend", "close", #reverse, #command("rollYearEnd"), true, true),

    // ── the end-of-day batch ──
    // Opening a run is authorised because it is bound to the business-date roll.
    // Advancing one is deliberately not a command: see `openMethods` below.
    p("eod.retry.update", "eod", #update, #command("setRetryPolicy"), false, true),
    p("instruction.create", "instruction", #create, #command("defineStandingInstruction"), false, true),
    p("instruction.delete", "instruction", #delete, #command("cancelStandingInstruction"), false, true),
    p("eod.open", "eod", #create, #command("openEndOfDay"), true, true),
    p("eod.failure.resolve", "eod", #update, #command("resolveBatchFailure"), false, true),
    // ── reporting. Nothing here posts, so nothing here is money-moving; all of it
    // is dual-authorised anyway, because what a return says and what a filing claims are
    // outward-facing acts.
    p("report.definition.create", "report", #create, #command("registerReportDefinition"), false, true),
    p("report.template.create", "report", #create, #command("registerReturnTemplate"), false, true),
    p("report.map.update", "report", #update, #command("setStatementMap"), false, true),
    p("report.certify", "report", #create, #command("certifyReport"), false, true),
    p("return.certify", "report", #create, #command("certifyReturn"), false, true),
    p("export.certify", "report", #create, #command("certifyExport"), false, true),
    p("statement.issue", "statement", #create, #command("issueStatement"), false, true),
    p("feed.endpoint.update", "feed", #update, #command("setFeedEndpoint"), false, true),
    p("feed.deadletter.create", "feed", #create, #command("recordFeedDeadLetter"), false, true),

    // ── indexing and bounded queries ──
    // Declaring what the counterparty-class index keys on changes what a later index key means, so
    // it is dual-authorised like every other declaration a report or a return is computed from. It
    // moves no money.
    p("index.dimension.update", "index", #update, #command("setCounterpartyClassDimension"), false, true),

    // ── archive contracts ──
    // The decisions are dual-authorised: what an archive child runs, who controls it, that one is
    // created, that an attempt made nothing, and that a child found or deployed outside the flow is
    // the bank's. None moves money.
    p("archive.image.pin", "archive", #update, #command("pinArchiveImage"), false, true),
    p("archive.controllers.update", "archive", #update, #command("setArchiveControllers"), false, true),
    p("archive.spawn.authorise", "archive", #create, #command("spawnArchive"), false, true),
    p("archive.spawn.abandon", "archive", #delete, #command("abandonArchiveSpawn"), false, true),
    p("archive.child.attach", "archive", #update, #command("attachArchiveChild"), false, true),
    p("archive.child.adopt", "archive", #create, #command("adoptArchiveChild"), false, true),
    // The steps are single-authority methods, each its own ingress message, because a spawn's plan
    // is fixed when it is authorised and a step can only advance it or be refused. The two that
    // carry caller-supplied facts — the id a create replied with, and the module hash read from the
    // chain — are guarded like the rest and checked against what the parent already holds
    // (`ArchiveCore.planRemember`, `planConfirm`).
    p("archive.image.upload", "archive", #update, #method("uploadArchiveImageChunk"), false, false),
    p("archive.image.reset", "archive", #delete, #method("resetArchiveImage"), false, false),
    p("archive.image.seal", "archive", #update, #method("sealArchiveImage"), false, false),
    p("archive.spawn.create", "archive", #create, #method("createArchiveChild"), false, false),
    p("archive.spawn.remember", "archive", #update, #method("rememberArchiveChild"), false, false),
    p("archive.spawn.install", "archive", #update, #method("installArchiveChild"), false, false),
    p("archive.spawn.confirm", "archive", #approve, #method("confirmArchiveChild"), false, false),
    p("archive.spawn.controllers", "archive", #update, #method("setArchiveChildControllers"), false, false),
    p("archive.spawn.complete", "archive", #activate, #method("completeArchiveChild"), false, false),
    p("archive.child.status", "archive", #read, #method("archiveChildStatus"), false, false),
    p("archive.child.recheck", "archive", #read, #method("recheckArchiveChild"), false, false),

    // ── monitoring: the closed rule set ──
    // A rule decides what the bank flags; declaring or retiring one is dual-authorised like a report
    // definition. Neither moves money.
    p("monitoring.rule.update", "monitoring", #update, #command("defineMonitoringRule"), false, true),
    p("monitoring.rule.delete", "monitoring", #delete, #command("retireMonitoringRule"), false, true),
    // ── alerts ──
    // A review is compliance's decision about a customer: cleared with a reason, or escalated to
    // the financial intelligence unit. Dual, so no one person can make a finding go away.
    p("alert.clear", "alert", #approve, #command("clearAlert"), false, true),
    p("alert.escalate", "alert", #update, #command("escalateAlert"), false, true),
    // ── collections and recovery (collections and recovery) ──
    // The policy (the day thresholds, the suspense stage, the modification-loss rule) and the qualitative
    // default are decisions about how the book is classified and provisioned: dual. A collector's action,
    // a promise and an assignment are the collector's own record: single, under a scope. Closing a recovery
    // ends a claim: dual.
    p("collections.policy", "collections", #update, #command("setCollectionsPolicy"), false, true),
    p("collections.utp", "collections", #update, #command("markUnlikelyToPay"), false, true),
    p("collections.action", "collections", #create, #command("recordCollectionAction"), false, false),
    p("collections.promise", "collections", #create, #command("recordPromiseToPay"), false, false),
    p("collections.assign", "collections", #update, #command("assignCollector"), false, false),
    p("collections.recovery.close", "collections", #update, #command("closeRecovery"), false, true),
    // ── origination and underwriting (origination and underwriting) ──
    // The policy, the affordability model and the scorecard decide how credit is granted: dual. A passkey
    // registration lets a key accept offers for a party: dual. The credit decision and the drawing are four
    // eyes. Capture, assessment, the bureau request, scoring, the offer and its acceptance, documents and
    // conditions are the officer's own record under a scope: single. The bureau's report arrives by a
    // method the bureau's connector calls, its signature judged by the contract.
    p("origination.policy", "origination", #update, #command("setOriginationPolicy"), false, true),
    p("origination.model.affordability", "origination", #update, #command("setAffordabilityModel"), false, true),
    p("origination.model.scorecard", "origination", #update, #command("setScorecard"), false, true),
    p("origination.passkey", "origination", #create, #command("registerPasskey"), false, true),
    p("origination.open", "origination", #create, #command("openApplication"), false, false),
    p("origination.data", "origination", #update, #command("recordApplicationData"), false, false),
    p("origination.affordability", "origination", #update, #command("assessAffordability"), false, false),
    p("origination.bureau.request", "origination", #create, #command("requestBureauReport"), false, false),
    p("origination.bureau.record", "origination", #create, #method("recordBureauReport"), false, false),
    p("origination.score", "origination", #update, #command("scoreApplication"), false, false),
    p("origination.underwrite", "origination", #approve, #command("underwrite"), false, true),
    p("origination.offer", "origination", #create, #command("issueOffer"), false, false),
    p("origination.offer.accept", "origination", #update, #command("acceptOffer"), false, false),
    p("origination.offer.decline", "origination", #update, #command("declineOffer"), false, false),
    p("origination.document", "origination", #create, #command("recordDocument"), false, false),
    p("origination.conditions", "origination", #update, #command("recordConditionsMet"), false, false),
    p("origination.fulfil", "origination", #create, #command("fulfilApplication"), false, true),
    p("origination.withdraw", "origination", #update, #command("withdrawApplication"), false, false),
    // ── corporate lending (corporate lending) ──
    // Opening a facility, changing the syndicate, restructuring, blocking and closing are decisions: dual. Every
    // act that posts — a drawing, a distribution, a rental, a remeasurement, a purchase, a collection, a
    // dishonour, a write-off — moves money: dual by the rule. A covenant test and a review are the officer's
    // record: single. A rate fixing is data the pricing rests on: dual. The agent's notice arrives by a method.
    p("facility.open", "facility", #create, #command("openFacility"), false, true),
    p("facility.drawdown", "facility", #create, #command("drawdown"), true, true),
    p("facility.participation.update", "facility", #update, #command("transferParticipation"), false, true),
    p("facility.distribute", "facility", #create, #command("distributeToParticipants"), true, true),
    p("facility.restructure", "facility", #update, #command("restructureFacility"), false, true),
    p("facility.covenant.test", "facility", #create, #command("recordCovenantTest"), false, false),
    p("facility.block", "facility", #update, #command("blockDrawdowns"), false, true),
    p("facility.unblock", "facility", #update, #command("unblockDrawdowns"), false, true),
    p("facility.review", "facility", #create, #command("recordFacilityReview"), false, false),
    p("facility.notice.record", "facility", #create, #method("recordAgentNotice"), false, false),
    p("rate.fixing.record", "facility", #create, #command("recordRateFixing"), false, true),
    p("lease.rental", "facility", #create, #command("receiveRental"), true, true),
    p("lease.residual.update", "facility", #update, #command("remeasureResidual"), true, true),
    p("factoring.purchase", "facility", #create, #command("purchaseReceivables"), true, true),
    p("factoring.collect", "facility", #create, #command("collectReceivable"), true, true),
    p("factoring.dishonour", "facility", #update, #command("dishonourReceivable"), true, true),
    p("factoring.writeoff", "facility", #update, #command("writeOffReceivable"), true, true),
    p("facility.close", "facility", #close, #command("closeFacility"), false, true),
    // ── branch and teller (branch and teller) ──
    // The policy is a decision: dual. Opening and closing a session, issuing a chequebook and stopping a cheque are
    // the officer's record: single. Every act that posts — counted cash in or out, a till loaded or returned, cash
    // dispatched, received, lodged or drawn, a difference resolved, a cheque held, cleared or returned, a draft
    // issued, paid or cancelled — moves money: dual by the rule of entitlements and maker-checker §1.3, so no teller resolves their own
    // difference and no one person moves cash alone.
    p("teller.policy", "teller", #update, #command("setTellerPolicy"), false, true),
    p("teller.session.open", "teller", #create, #command("openTellerSession"), false, false),
    p("teller.session.close", "teller", #close, #command("closeTellerSession"), false, false),
    p("teller.difference.resolve", "teller", #approve, #command("resolveTillDifference"), true, true),
    p("teller.cash.deposit", "teller", #create, #command("cashDeposit"), true, true),
    p("teller.cash.withdraw", "teller", #create, #command("cashWithdrawal"), true, true),
    p("vault.till.load", "vault", #create, #command("vaultToTill"), true, true),
    p("vault.till.return", "vault", #create, #command("tillToVault"), true, true),
    p("vault.dispatch", "vault", #create, #command("dispatchCash"), true, true),
    p("vault.receive", "vault", #create, #command("receiveCash"), true, true),
    p("vault.centralbank.lodge", "vault", #create, #command("vaultToCentralBank"), true, true),
    p("vault.centralbank.draw", "vault", #create, #command("centralBankToVault"), true, true),
    p("cheque.book.issue", "cheque", #create, #command("issueChequebook"), false, false),
    p("cheque.stop", "cheque", #update, #command("stopCheque"), false, false),
    p("cheque.present", "cheque", #create, #command("presentCheque"), true, true),
    p("cheque.clear", "cheque", #approve, #command("clearCheque"), true, true),
    p("cheque.return", "cheque", #reject, #command("returnCheque"), true, true),
    p("draft.issue", "draft", #create, #command("issueDraft"), true, true),
    p("draft.pay", "draft", #update, #command("payDraft"), true, true),
    p("draft.cancel", "draft", #reverse, #command("cancelDraft"), true, true),
    // trade finance trade finance: the acts that create or move an undertaking, pay or take money are dual; recording a
    // presentation, a demand, an examination, an acceptance, a protest or a message is the officer's own act
    p("trade.policy", "trade", #update, #command("setTradePolicy"), false, true),
    p("trade.lc.issue", "trade", #create, #command("issueLetterOfCredit"), true, true),
    p("trade.lc.advise", "trade", #create, #command("adviseLetterOfCredit"), true, true),
    p("trade.lc.amend", "trade", #update, #command("amendLetterOfCredit"), true, true),
    p("trade.lc.present", "trade", #create, #command("presentDocuments"), false, false),
    p("trade.lc.examine", "trade", #approve, #command("examinePresentation"), false, false),
    p("trade.lc.waive", "trade", #approve, #command("waiveDiscrepancies"), false, true),
    p("trade.lc.honour", "trade", #update, #command("honourPresentation"), true, true),
    p("trade.lc.settle", "trade", #update, #command("settleAcceptance"), true, true),
    p("trade.lc.close", "trade", #close, #command("closeLetterOfCredit"), true, true),
    p("trade.guarantee.issue", "trade", #create, #command("issueGuarantee"), true, true),
    p("trade.guarantee.amend", "trade", #update, #command("amendGuarantee"), true, true),
    p("trade.guarantee.demand.record", "trade", #create, #command("recordDemand"), false, false),
    p("trade.guarantee.demand.examine", "trade", #approve, #command("examineDemand"), false, false),
    p("trade.guarantee.pay", "trade", #update, #command("payDemand"), true, true),
    p("trade.guarantee.reduce", "trade", #update, #command("reduceGuarantee"), true, true),
    p("trade.guarantee.release", "trade", #close, #command("releaseGuarantee"), true, true),
    p("trade.collection.register", "trade", #create, #command("registerCollection"), true, true),
    p("trade.collection.present", "trade", #update, #command("presentCollection"), false, false),
    p("trade.collection.accept", "trade", #update, #command("acceptCollection"), false, false),
    p("trade.collection.pay", "trade", #update, #command("payCollection"), true, true),
    p("trade.collection.protest", "trade", #reject, #command("protestCollection"), false, false),
    p("trade.collection.return", "trade", #close, #command("returnCollection"), true, true),
    p("trade.bill.discount", "trade", #create, #command("discountBill"), true, true),
    p("trade.bill.rediscount", "trade", #update, #command("rediscountBill"), true, true),
    p("trade.bill.settle", "trade", #update, #command("settleBill"), true, true),
    p("trade.bill.dishonour", "trade", #reverse, #command("dishonourBill"), true, true),
    p("trade.message.record", "trade", #create, #command("recordTradeMessage"), false, false),
    // Islamic banking Islamic banking: every act that moves money is dual; the board's approval and the policy are dual acts of governance;
    // closing a contract's record is the officer's own act
    p("sharia.policy", "sharia", #update, #command("setIslamicPolicy"), false, true),
    p("sharia.product.approve", "sharia", #approve, #command("approveShariaProduct"), false, true),
    p("sharia.book.flag", "sharia", #update, #command("flagShariaBook"), false, true),
    p("sharia.contract.open", "sharia", #create, #command("openShariaContract"), true, true),
    p("sharia.murabaha.acquire", "sharia", #update, #command("acquireMurabahaAsset"), true, true),
    p("sharia.murabaha.sell", "sharia", #update, #command("sellMurabaha"), true, true),
    p("sharia.murabaha.collect", "sharia", #update, #command("collectInstalment"), true, true),
    p("sharia.rebate", "sharia", #waive, #command("grantRebate"), true, true),
    p("sharia.ijarah.commence", "sharia", #update, #command("commenceIjarah"), true, true),
    p("sharia.ijarah.collect", "sharia", #update, #command("collectRental"), true, true),
    p("sharia.ijarah.transfer", "sharia", #close, #command("transferIjarahOwnership"), true, true),
    p("sharia.partnership.capital", "sharia", #update, #command("contributeCapital"), true, true),
    p("sharia.partnership.profit", "sharia", #update, #command("distributeMusharakahProfit"), true, true),
    p("sharia.partnership.loss", "sharia", #update, #command("allocateMusharakahLoss"), true, true),
    p("sharia.partnership.unit", "sharia", #update, #command("buyMusharakahUnit"), true, true),
    p("sharia.mudarabah.result", "sharia", #update, #command("recordMudarabahResult"), true, true),
    p("sharia.salam.deliver", "sharia", #update, #command("deliverSalam"), true, true),
    p("sharia.salam.sell", "sharia", #update, #command("sellSalamCommodity"), true, true),
    p("sharia.salam.failure", "sharia", #reverse, #command("recordSalamFailure"), true, true),
    p("sharia.istisna.milestone", "sharia", #update, #command("recordIstisnaMilestone"), true, true),
    p("sharia.istisna.collect", "sharia", #update, #command("collectIstisnaBilling"), true, true),
    p("sharia.contract.settle", "sharia", #close, #command("settleShariaContract"), true, true),
    p("sharia.contract.close", "sharia", #close, #command("closeShariaContract"), false, false),
    p("sharia.noncompliance.record", "sharia", #update, #command("recordNonCompliance"), true, true),
    p("psia.pool.open", "psia", #create, #command("openInvestmentPool"), false, true),
    p("psia.reserve.update", "psia", #update, #command("updatePoolReserves"), false, true),
    p("psia.distribute", "psia", #update, #command("distributePool"), true, true),
    // treasury treasury: configuration and market data are dual acts of governance; the capture records a contract and moves no
    // money — it is the trader's own act, within the entitlements' ceiling on the deal's notional, and a breach above the
    // recorded limits needs an approver named on the command; the legs that move money settle under dual control, as do
    // marks, amendments, cancellations and break resolutions; the connector records confirmations and statements alone
    p("treasury.policy", "treasury", #update, #command("setTreasuryPolicy"), false, true),
    p("treasury.security.register", "treasury", #create, #command("registerSecurity"), false, true),
    p("treasury.curve.publish", "treasury", #update, #command("publishCurve"), false, true),
    p("treasury.limit.update", "treasury", #update, #command("setTreasuryLimit"), false, true),
    p("nostro.register", "nostro", #create, #command("registerNostro"), false, true),
    p("treasury.deal.capture", "treasury", #create, #command("captureDeal"), false, false),
    p("treasury.deal.confirm", "treasury", #update, #command("confirmDeal"), false, false),
    p("treasury.deal.amend", "treasury", #update, #command("amendDeal"), true, true),
    p("treasury.deal.cancel", "treasury", #reverse, #command("cancelDeal"), true, true),
    p("treasury.deal.settle", "treasury", #update, #command("settleDealLeg"), true, true),
    p("treasury.deal.mark", "treasury", #update, #command("markDeal"), true, true),
    p("nostro.statement.record", "nostro", #create, #command("recordNostroStatement"), false, false),
    p("nostro.break.resolve", "nostro", #update, #command("resolveNostroBreak"), true, true),
    // ── closed-month packing ──
    // Opening a pack decides which history leaves the live indexes; dual, like the close it
    // follows. Advancing one is an open method: see `openMethods`.
    p("packing.open", "packing", #close, #command("openPacking"), false, true),
    // Rolling a pack to an archive decides where a month's blocks live from then on; dual.
    p("packing.roll", "packing", #close, #command("rollPackToArchive"), false, true),
    // ── shards ──
    // The routing rule decides where every account lives from then on; dual. A transfer to another
    // shard moves a customer's money out of this contract: money-moving, dual.
    p("shard.rule.update", "shard", #update, #command("declareShardRule"), false, true),
    p("shard.transfer.create", "shard", #create, #command("openShardTransfer"), true, true),
    // ── settlement on the journal ──
    // The scheme, its participants and their prefunding are the bank's acts: dual, and prefunding is
    // money-moving. A payment's prepare, fulfil, reject and error, the windows and the bulks are the
    // scheme's flow: single-authority under the scheme principal's grant, whose own control is the
    // message's validation and audit and the engine's cap — a person cannot make a payment here, only
    // a scheme can, and the grant that makes a principal a scheme is dual.
    p("settlement.scheme.update", "settlement", #update, #command("declareScheme"), false, true),
    p("settlement.participant.create", "settlement", #create, #command("registerParticipant"), false, true),
    p("settlement.participant.delete", "settlement", #delete, #command("deactivateParticipant"), false, true),
    p("settlement.funds.record", "settlement", #create, #command("recordFunds"), true, true),
    p("settlement.transfer.prepare", "settlement", #create, #command("prepareTransfer"), false, false),
    p("settlement.transfer.fulfil", "settlement", #update, #command("fulfilTransfer"), false, false),
    p("settlement.transfer.reject", "settlement", #update, #command("rejectTransfer"), false, false),
    p("settlement.transfer.error", "settlement", #update, #command("errorTransfer"), false, false),
    p("settlement.window.open", "settlement", #create, #command("openSettlementWindow"), false, false),
    p("settlement.window.close", "settlement", #close, #command("closeSettlementWindow"), false, false),
    p("settlement.open", "settlement", #create, #command("openSettlement"), false, true),
    p("settlement.abort", "settlement", #delete, #command("abortSettlement"), false, true),
    p("settlement.bulk.receive", "settlement", #create, #command("receiveBulk"), false, false),
    p("settlement.bulk.fulfil", "settlement", #update, #command("fulfilBulk"), false, false),
    p("settlement.bulk.reject", "settlement", #update, #command("rejectBulk"), false, false),
    // ISO 20022 messaging on the journal. Declaring a rail and a connector's key and
    // lifting or rejecting a compliance hold are decisions (dual); receiving a message is the
    // scheme's automaton, single-authority like the transfer acts it performs.
    p("payments.rail.update", "payments", #update, #command("declareRail"), false, true),
    p("payments.connector.update", "payments", #update, #command("registerConnectorKey"), false, true),
    p("payments.hold.release", "payments", #approve, #command("releaseHold"), false, true),
    p("payments.hold.reject", "payments", #reject, #command("rejectHold"), false, true),
    p("payments.message.ingest", "payments", #create, #method("ingestMessage"), false, false),
    // FSPIOP: the participant directory is a decision (dual); a request is the scheme's automaton (single)
    p("payments.fspiop.participant", "payments", #update, #command("declareFspiopParticipant"), false, true),
    p("payments.fspiop.handle", "payments", #create, #method("fspiop"), false, false),
    // the declared the extended target list list: a debit authority is the debtor's decision, a mandate's acceptance the bank's (dual)
    p("payments.authority.grant", "payments", #update, #command("grantDebitAuthority"), false, true),
    p("payments.authority.revoke", "payments", #update, #command("revokeDebitAuthority"), false, true),
    p("payments.mandate.decide", "payments", #approve, #command("decideMandate"), false, true),
    ]
  };

  /// Methods that are deliberately open to any caller, with the reason. The
  /// audit requires every public update method to be either guarded above or
  /// listed here, so an unguarded method is never silently accepted.
  ///
  /// `expireProposals` follows the journal's own rule for its expiry sweep
  /// (`Journal.mo` `expirePending`): expiry is a fact of the clock, the caller
  /// cannot choose what happens, and the resulting block is attributed to the
  /// canister, so keeping it open means a stalled timer cannot leave a bank
  /// unable to clear its queue.
  public func openMethods() : [(Text, Text)] {
    [
    ("expireProposals", "expiry is a fact of the clock; the block is attributed to the canister and the caller chooses nothing"),
    ("advanceEndOfDay", "the plan is fixed when the run opens, so an advancing caller cannot choose what is posted — only that progress happens; the postings are attributed to the canister, and an open advance path means a stalled timer cannot leave a bank unable to close its books"),
    ("advancePacking", "the pack's range and phases are fixed when it opens, so an advancing caller cannot choose what is packed — only that progress happens; every segment round-trips before it is stored, the blocks are attributed to the canister, and an open advance path means a stalled timer cannot leave a bank with a pack half done"),
    ("advanceArchiveRoll", "the roll's pack, archive and phases are fixed by the dual-authorised decision, so an advancing caller cannot choose what leaves or where it goes — only that progress happens; a segment is recorded as archived only on the archive's own acknowledgement, and the blocks are attributed to the canister"),
    ("acknowledgeArchivedSegment", "the caller is held to the roll's declared archive principal and the hash to the segment's own; any other caller, segment or hash is refused and recorded nowhere — the method is open because the archive is not a bank principal and holds no grant"),
    ("sendShardTransfer", "the transfer's amount, accounts and shard were fixed by the dual-authorised opening, so a sending caller cannot choose what moves — only that the call to the other shard is made; the attempt is recorded before the call and a second delivery is a duplicate the receiver refuses"),
    ("receiveShardTransfer", "the caller is held to a shard principal of the declared rule and the posting to an idempotency key derived from the sending shard and the transfer, so anyone else is refused and a second delivery posts nothing; the method is open because a shard is not a bank principal and holds no grant"),
    ("acknowledgeShardTransfer", "the caller is held to the receiving shard's principal for a transfer that was sent; the pending is resolved once and a second acknowledgement finds it resolved"),
    ("rejectShardTransfer", "the caller is held to the receiving shard's principal for a transfer that was sent; the pending is voided once and the customer's money released"),
    ("expireTransfers", "expiry is a fact of the clock: a reservation past its deadline is voided as the journal's own sweep voids, the caller chooses nothing, and an open path means a stalled timer cannot leave money reserved for ever"),
    ("advanceSettlement", "the settlement's window and phases were fixed by the dual-authorised opening; the netting is arithmetic over the window's committed transfers and the batch either settles whole or is refused, so an advancing caller cannot choose what settles — only that progress happens"),
    ("advanceBulk", "the bulk's items were fixed when it was received under the scheme's grant; advancing reserves or commits the next items exactly as the scheme asked, and a re-driven bulk posts nothing new"),
    ]
  };

  public func count() : Nat { catalogue().size() };

  public func moneyMovingCount() : Nat {
    var n = 0;
    for (x in catalogue().vals()) { if (x.moneyMoving) n += 1 };
    n
  };

  public func dualByDefaultCount() : Nat {
    var n = 0;
    for (x in catalogue().vals()) { if (x.dualByDefault) n += 1 };
    n
  };

  public func find(id : T.PermissionId) : ?T.Permission {
    for (x in catalogue().vals()) { if (Text.equal(x.id, id)) return ?x };
    null
  };

  public func exists(id : T.PermissionId) : Bool {
    switch (find(id)) { case (?_) true; case null false }
  };

  public func byMethod(method : Text) : ?T.Permission {
    for (x in catalogue().vals()) {
      switch (x.guards) { case (#method(m)) { if (Text.equal(m, method)) return ?x }; case (#command(_)) {} };
    };
    null
  };

  public func byCommandName(name : Text) : ?T.Permission {
    for (x in catalogue().vals()) {
      switch (x.guards) { case (#command(c)) { if (Text.equal(c, name)) return ?x }; case (#method(_)) {} };
    };
    null
  };

  /// The command-variant name, used both for the permission lookup and by the
  /// audit. Exhaustive over `Command` by construction: a new variant without a
  /// case here does not compile.
  public func commandName(c : T.Command) : Text {
    switch (c) {
      case (#defineRole(_)) "defineRole";
      case (#grantRole(_)) "grantRole";
      case (#revokeRole(_)) "revokeRole";
      case (#setDualPolicy(_)) "setDualPolicy";
      case (#clearDualPolicy(_)) "clearDualPolicy";
      case (#openBook(_)) "openBook";
      case (#closeBook(_)) "closeBook";
      case (#transferBankAdmin(_)) "transferBankAdmin";
      case (#setFeatureActivation(_)) "setFeatureActivation";
      case (#journalRegisterCurrency(_)) "journalRegisterCurrency";
      case (#journalOpenAccount(_)) "journalOpenAccount";
      case (#journalCloseAccount(_)) "journalCloseAccount";
      case (#journalOpenPeriod(_)) "journalOpenPeriod";
      case (#journalClosePeriod(_)) "journalClosePeriod";
      case (#journalSetActivationHeight(_)) "journalSetActivationHeight";
      case (#journalSetLeadsheetSchema(_)) "journalSetLeadsheetSchema";
      case (#journalAddPoster(_)) "journalAddPoster";
      case (#journalRemovePoster(_)) "journalRemovePoster";
      case (#journalSetPosterScope(_)) "journalSetPosterScope";
      case (#journalRollBusinessDate(_)) "journalRollBusinessDate";
      case (#journalSetCalendar(_)) "journalSetCalendar";
      case (#journalSetCalendarAuthority(_)) "journalSetCalendarAuthority";
      case (#postManualEntry(_)) "postManualEntry";
      case (#reverseManualEntry(_)) "reverseManualEntry";
      case (#postManualEntryForParty(_)) "postManualEntryForParty";
      case (#createParty(_)) "createParty";
      case (#createCustomer(_)) "createCustomer";
      case (#amendParty(_)) "amendParty";
      case (#setPartyLifecycle(_)) "setPartyLifecycle";
      case (#setPartyCdd(_)) "setPartyCdd";
      case (#addPartyDocument(_)) "addPartyDocument";
      case (#addPartyRelationship(_)) "addPartyRelationship";
      case (#setPartyExtension(_)) "setPartyExtension";
      case (#issueIdentifier(_)) "issueIdentifier";
      case (#commitScreeningList(_)) "commitScreeningList";
      case (#proveScreeningClear(_)) "proveScreeningClear";
      case (#recordScreeningDecision(_)) "recordScreeningDecision";
      case (#registerSchema(_)) "registerSchema";
      case (#registerCollateral(_)) "registerCollateral";
      case (#revalueCollateral(_)) "revalueCollateral";
      case (#allocateCollateral(_)) "allocateCollateral";
      case (#releaseCollateral(_)) "releaseCollateral";
      case (#addStaff(_)) "addStaff";
      case (#removeStaff(_)) "removeStaff";
      case (#setAccountFormat(_)) "setAccountFormat";
      case (#setReviewGrace(_)) "setReviewGrace";
      case (#pinJwks(_)) "pinJwks";
      case (#registerCredential(_)) "registerCredential";
      case (#revokeCredential(_)) "revokeCredential";
      // ── the product engine ──
      case (#registerProduct(_)) "registerProduct";
      case (#amendProduct(_)) "amendProduct";
      case (#closeProductToNewAccounts(_)) "closeProductToNewAccounts";
      case (#openAccount(_)) "openAccount";
      case (#setAccountStatus(_)) "setAccountStatus";
      case (#migrateAccount(_)) "migrateAccount";
      case (#openTill(_)) "openTill";
      case (#closeTill(_)) "closeTill";
      case (#grantFacility(_)) "grantFacility";
      case (#depositToAccount(_)) "depositToAccount";
      case (#withdrawFromAccount(_)) "withdrawFromAccount";
      case (#transferBetweenAccounts(_)) "transferBetweenAccounts";
      case (#applyCharge(_)) "applyCharge";
      case (#waiveCharge(_)) "waiveCharge";
      case (#postAccrual(_)) "postAccrual";
      case (#capitaliseInterest(_)) "capitaliseInterest";
      case (#disburseLoan(_)) "disburseLoan";
      case (#repayLoan(_)) "repayLoan";
      case (#rescheduleLoan(_)) "rescheduleLoan";
      case (#setProvision(_)) "setProvision";
      case (#writeOffLoan(_)) "writeOffLoan";
      case (#recordRecovery(_)) "recordRecovery";
      case (#redeemTermDeposit(_)) "redeemTermDeposit";
      case (#allocateCashToTill(_)) "allocateCashToTill";
      case (#returnCashFromTill(_)) "returnCashFromTill";
      case (#settleTill(_)) "settleTill";
      // ── value dating, foreign currency and the close ──
      case (#setFunctionalCurrency(_)) "setFunctionalCurrency";
      case (#setFxPair(_)) "setFxPair";
      case (#setFxRate(_)) "setFxRate";
      case (#setBackValueWindow(_)) "setBackValueWindow";
      case (#approveBackValue(_)) "approveBackValue";
      case (#openDeferralSchedule(_)) "openDeferralSchedule";
      case (#bookFxDeal(_)) "bookFxDeal";
      case (#realiseFxPosition(_)) "realiseFxPosition";
      case (#adjustAccrual(_)) "adjustAccrual";
      case (#amortiseDeferral(_)) "amortiseDeferral";
      case (#openPeriodEnd(_)) "openPeriodEnd";
      case (#recordClosingRates(_)) "recordClosingRates";
      case (#markAccrualComplete(_)) "markAccrualComplete";
      case (#revaluePositions(_)) "revaluePositions";
      case (#amortisePeriodDeferrals(_)) "amortisePeriodDeferrals";
      case (#reconcilePeriod(_)) "reconcilePeriod";
      case (#closePeriodEnd(_)) "closePeriodEnd";
      case (#rollYearEnd(_)) "rollYearEnd";
      // ── the end-of-day batch ──
      case (#setRetryPolicy(_)) "setRetryPolicy";
      case (#defineStandingInstruction(_)) "defineStandingInstruction";
      case (#cancelStandingInstruction(_)) "cancelStandingInstruction";
      case (#openEndOfDay(_)) "openEndOfDay";
      case (#resolveBatchFailure(_)) "resolveBatchFailure";
      // ── reporting ──
      case (#registerReportDefinition(_)) "registerReportDefinition";
      case (#registerReturnTemplate(_)) "registerReturnTemplate";
      case (#setStatementMap(_)) "setStatementMap";
      case (#certifyReport(_)) "certifyReport";
      case (#certifyReturn(_)) "certifyReturn";
      case (#certifyExport(_)) "certifyExport";
      case (#issueStatement(_)) "issueStatement";
      case (#setFeedEndpoint(_)) "setFeedEndpoint";
      case (#recordFeedDeadLetter(_)) "recordFeedDeadLetter";
      case (#setCounterpartyClassDimension(_)) "setCounterpartyClassDimension";
      case (#pinArchiveImage(_)) "pinArchiveImage";
      case (#setArchiveControllers(_)) "setArchiveControllers";
      case (#spawnArchive(_)) "spawnArchive";
      case (#abandonArchiveSpawn(_)) "abandonArchiveSpawn";
      case (#attachArchiveChild(_)) "attachArchiveChild";
      case (#adoptArchiveChild(_)) "adoptArchiveChild";
      case (#defineMonitoringRule(_)) "defineMonitoringRule";
      case (#retireMonitoringRule(_)) "retireMonitoringRule";
      case (#clearAlert(_)) "clearAlert";
      case (#escalateAlert(_)) "escalateAlert";
      case (#setCollectionsPolicy(_)) "setCollectionsPolicy";
      case (#markUnlikelyToPay(_)) "markUnlikelyToPay";
      case (#recordCollectionAction(_)) "recordCollectionAction";
      case (#recordPromiseToPay(_)) "recordPromiseToPay";
      case (#assignCollector(_)) "assignCollector";
      case (#closeRecovery(_)) "closeRecovery";
      case (#setOriginationPolicy(_)) "setOriginationPolicy";
      case (#setAffordabilityModel(_)) "setAffordabilityModel";
      case (#setScorecard(_)) "setScorecard";
      case (#registerPasskey(_)) "registerPasskey";
      case (#openApplication(_)) "openApplication";
      case (#recordApplicationData(_)) "recordApplicationData";
      case (#assessAffordability(_)) "assessAffordability";
      case (#requestBureauReport(_)) "requestBureauReport";
      case (#scoreApplication(_)) "scoreApplication";
      case (#underwrite(_)) "underwrite";
      case (#issueOffer(_)) "issueOffer";
      case (#acceptOffer(_)) "acceptOffer";
      case (#declineOffer(_)) "declineOffer";
      case (#recordDocument(_)) "recordDocument";
      case (#recordConditionsMet(_)) "recordConditionsMet";
      case (#fulfilApplication(_)) "fulfilApplication";
      case (#withdrawApplication(_)) "withdrawApplication";
      case (#openFacility(_)) "openFacility";
      case (#drawdown(_)) "drawdown";
      case (#transferParticipation(_)) "transferParticipation";
      case (#distributeToParticipants(_)) "distributeToParticipants";
      case (#restructureFacility(_)) "restructureFacility";
      case (#recordCovenantTest(_)) "recordCovenantTest";
      case (#blockDrawdowns(_)) "blockDrawdowns";
      case (#unblockDrawdowns(_)) "unblockDrawdowns";
      case (#recordFacilityReview(_)) "recordFacilityReview";
      case (#recordRateFixing(_)) "recordRateFixing";
      case (#receiveRental(_)) "receiveRental";
      case (#remeasureResidual(_)) "remeasureResidual";
      case (#purchaseReceivables(_)) "purchaseReceivables";
      case (#collectReceivable(_)) "collectReceivable";
      case (#dishonourReceivable(_)) "dishonourReceivable";
      case (#writeOffReceivable(_)) "writeOffReceivable";
      case (#closeFacility(_)) "closeFacility";
      case (#setTellerPolicy(_)) "setTellerPolicy";
      case (#openTellerSession(_)) "openTellerSession";
      case (#closeTellerSession(_)) "closeTellerSession";
      case (#resolveTillDifference(_)) "resolveTillDifference";
      case (#cashDeposit(_)) "cashDeposit";
      case (#cashWithdrawal(_)) "cashWithdrawal";
      case (#vaultToTill(_)) "vaultToTill";
      case (#tillToVault(_)) "tillToVault";
      case (#dispatchCash(_)) "dispatchCash";
      case (#receiveCash(_)) "receiveCash";
      case (#vaultToCentralBank(_)) "vaultToCentralBank";
      case (#centralBankToVault(_)) "centralBankToVault";
      case (#issueChequebook(_)) "issueChequebook";
      case (#stopCheque(_)) "stopCheque";
      case (#presentCheque(_)) "presentCheque";
      case (#clearCheque(_)) "clearCheque";
      case (#returnCheque(_)) "returnCheque";
      case (#issueDraft(_)) "issueDraft";
      case (#payDraft(_)) "payDraft";
      case (#cancelDraft(_)) "cancelDraft";
      case (#openPacking(_)) "openPacking";
      case (#rollPackToArchive(_)) "rollPackToArchive";
      case (#declareShardRule(_)) "declareShardRule";
      case (#openShardTransfer(_)) "openShardTransfer";
      case (#declareScheme(_)) "declareScheme";
      case (#registerParticipant(_)) "registerParticipant";
      case (#deactivateParticipant(_)) "deactivateParticipant";
      case (#recordFunds(_)) "recordFunds";
      case (#prepareTransfer(_)) "prepareTransfer";
      case (#fulfilTransfer(_)) "fulfilTransfer";
      case (#rejectTransfer(_)) "rejectTransfer";
      case (#errorTransfer(_)) "errorTransfer";
      case (#openSettlementWindow(_)) "openSettlementWindow";
      case (#closeSettlementWindow(_)) "closeSettlementWindow";
      case (#openSettlement(_)) "openSettlement";
      case (#abortSettlement(_)) "abortSettlement";
      case (#receiveBulk(_)) "receiveBulk";
      case (#fulfilBulk(_)) "fulfilBulk";
      case (#rejectBulk(_)) "rejectBulk";
      case (#declareRail(_)) "declareRail";
      case (#registerConnectorKey(_)) "registerConnectorKey";
      case (#releaseHold(_)) "releaseHold";
      case (#rejectHold(_)) "rejectHold";
      case (#grantDebitAuthority(_)) "grantDebitAuthority";
      case (#revokeDebitAuthority(_)) "revokeDebitAuthority";
      case (#decideMandate(_)) "decideMandate";
      case (#declareFspiopParticipant(_)) "declareFspiopParticipant";
      case (#setTradePolicy(_)) "setTradePolicy";
      case (#issueLetterOfCredit(_)) "issueLetterOfCredit";
      case (#adviseLetterOfCredit(_)) "adviseLetterOfCredit";
      case (#amendLetterOfCredit(_)) "amendLetterOfCredit";
      case (#presentDocuments(_)) "presentDocuments";
      case (#examinePresentation(_)) "examinePresentation";
      case (#waiveDiscrepancies(_)) "waiveDiscrepancies";
      case (#honourPresentation(_)) "honourPresentation";
      case (#settleAcceptance(_)) "settleAcceptance";
      case (#closeLetterOfCredit(_)) "closeLetterOfCredit";
      case (#issueGuarantee(_)) "issueGuarantee";
      case (#amendGuarantee(_)) "amendGuarantee";
      case (#recordDemand(_)) "recordDemand";
      case (#examineDemand(_)) "examineDemand";
      case (#payDemand(_)) "payDemand";
      case (#reduceGuarantee(_)) "reduceGuarantee";
      case (#releaseGuarantee(_)) "releaseGuarantee";
      case (#registerCollection(_)) "registerCollection";
      case (#presentCollection(_)) "presentCollection";
      case (#acceptCollection(_)) "acceptCollection";
      case (#payCollection(_)) "payCollection";
      case (#protestCollection(_)) "protestCollection";
      case (#returnCollection(_)) "returnCollection";
      case (#discountBill(_)) "discountBill";
      case (#rediscountBill(_)) "rediscountBill";
      case (#settleBill(_)) "settleBill";
      case (#dishonourBill(_)) "dishonourBill";
      case (#recordTradeMessage(_)) "recordTradeMessage";
      case (#setIslamicPolicy(_)) "setIslamicPolicy";
      case (#approveShariaProduct(_)) "approveShariaProduct";
      case (#flagShariaBook(_)) "flagShariaBook";
      case (#openShariaContract(_)) "openShariaContract";
      case (#acquireMurabahaAsset(_)) "acquireMurabahaAsset";
      case (#sellMurabaha(_)) "sellMurabaha";
      case (#collectInstalment(_)) "collectInstalment";
      case (#grantRebate(_)) "grantRebate";
      case (#commenceIjarah(_)) "commenceIjarah";
      case (#collectRental(_)) "collectRental";
      case (#transferIjarahOwnership(_)) "transferIjarahOwnership";
      case (#contributeCapital(_)) "contributeCapital";
      case (#distributeMusharakahProfit(_)) "distributeMusharakahProfit";
      case (#allocateMusharakahLoss(_)) "allocateMusharakahLoss";
      case (#buyMusharakahUnit(_)) "buyMusharakahUnit";
      case (#recordMudarabahResult(_)) "recordMudarabahResult";
      case (#deliverSalam(_)) "deliverSalam";
      case (#sellSalamCommodity(_)) "sellSalamCommodity";
      case (#recordSalamFailure(_)) "recordSalamFailure";
      case (#recordIstisnaMilestone(_)) "recordIstisnaMilestone";
      case (#collectIstisnaBilling(_)) "collectIstisnaBilling";
      case (#settleShariaContract(_)) "settleShariaContract";
      case (#closeShariaContract(_)) "closeShariaContract";
      case (#recordNonCompliance(_)) "recordNonCompliance";
      case (#openInvestmentPool(_)) "openInvestmentPool";
      case (#updatePoolReserves(_)) "updatePoolReserves";
      case (#distributePool(_)) "distributePool";
      case (#setTreasuryPolicy(_)) "setTreasuryPolicy"; case (#registerSecurity(_)) "registerSecurity"; case (#publishCurve(_)) "publishCurve"; case (#setTreasuryLimit(_)) "setTreasuryLimit";
      case (#registerNostro(_)) "registerNostro"; case (#captureDeal(_)) "captureDeal"; case (#confirmDeal(_)) "confirmDeal"; case (#amendDeal(_)) "amendDeal"; case (#cancelDeal(_)) "cancelDeal";
      case (#settleDealLeg(_)) "settleDealLeg"; case (#markDeal(_)) "markDeal"; case (#recordNostroStatement(_)) "recordNostroStatement"; case (#resolveNostroBreak(_)) "resolveNostroBreak";
    }
  };

  /// The permission a command requires. Every `Command` variant has one; the
  /// catalogue is checked for totality by `tools/permission_audit.py` and by
  /// `test/Permissions.test.mo`, which walks one value of every variant.
  public func forCommand(c : T.Command) : ?T.Permission { byCommandName(commandName(c)) };

  public func ids() : [T.PermissionId] {
    Array.map<T.Permission, T.PermissionId>(catalogue(), func(x) { x.id })
  };
};
